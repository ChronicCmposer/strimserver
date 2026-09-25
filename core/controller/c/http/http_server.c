/*
 * http_server.c — HTTP/1.1 + WebSocket control-plane serving (Wave 1 http
 * lane). Implements http_server.h with libmicrohttpd 1.0.10 (external event
 * loop mode: MHD_USE_EPOLL + caller-driven MHD_run_wait, no internal thread)
 * and wslay 1.1.1 (RFC 6455 framing after MHD's upgrade handoff).
 *
 * Wire contract (the Go controller, core/controller/main.go:235-400):
 *   /event    POST  -> 204 (then RequestReconcile) | 400 bad json | 500 err
 *   /control  POST  -> 204 (then RequestReconcile) | 400 bad json | 500 err
 *   /status   GET   -> 200 application/json (ControllerStatus JSON + '\n')
 *   /subscribe ws   -> per-connection listener, 1-deep drop-oldest/latest-
 *                      wins write queue, write-timeout close 1011, shutdown
 *                      close 1000, bounded-1s remove (main.go:243-291)
 *   /healthz  any   -> 200 "ok\n"
 *   unknown path    -> 404 "404 page not found\n"
 *   wrong method    -> 405 "method not allowed\n"
 *
 * Threading / WS-marshaling design (the CRITICAL part of this lane):
 *   The controller core is single-threaded, so the HTTP lane never touches
 *   controller state and never performs WS I/O from a controller-thread
 *   callback. Every status push is marshaled through the controller's action
 *   queue (the Go notifyListeners path): the controller lane serializes a
 *   status snapshot and calls back into ws_send (strim_http_ws_send) on the
 *   action-queue thread. ws_send stores the frame in the client's 1-deep
 *   slot (drop-oldest/latest-wins, main.go:251-259) under a small mutex;
 *   the HTTP service loop (its own thread) drains the slot into wslay and
 *   performs the socket I/O. At most one frame is in flight in wslay plus
 *   one pending in the slot — the exact Go sendChannel(1) semantics.
 *
 *   The server runs its event loop on the calling thread
 *   (strim_http_server_service) and spawns no threads; Wave 2's main() runs
 *   it on a thread of its choosing, separate from the controller queue.
 *
 * License: project code (see LICENSE). No GPL.
 */

#include "http_server.h"

#include "internal.h"
#include "ws_crypto.h"

#include <microhttpd.h>
#include <wslay/wslay.h>

#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

/* =========================================================================
 * Constants
 * ========================================================================= */

#define WS_GUID "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
#define WS_GUID_LEN 36u

/* Default WEBSOCKET_WRITE_TIMEOUT when the env var is absent/unparseable
 * (the Go controller requires the env var; a sane default keeps a
 * misconfigured binary usable instead of killing every write). */
#define WS_WRITE_TIMEOUT_DEFAULT_MS 5000u

/* Bound on the service-loop shutdown latency (MHD_run_wait per pass). */
#define SERVICE_PASS_MS 250

/* HTTP method / route enums (session-scoped). */
enum http_method { HTTP_M_NONE = 0, HTTP_M_GET, HTTP_M_POST, HTTP_M_OTHER };

enum http_route {
  ROUTE_NONE = 0,
  ROUTE_EVENT,
  ROUTE_CONTROL,
  ROUTE_STATUS,
  ROUTE_SUBSCRIBE,
  ROUTE_HEALTHZ,
  ROUTE_UNKNOWN,
};

/* =========================================================================
 * Per-request session (MHD con_cls; freed by MHD_OPTION_NOTIFY_COMPLETED)
 * ========================================================================= */

struct http_session {
  int method;
  int route;
  int body_overflow;   /* the request body exceeded STRIM_HTTP_BODY_MAX */
  int client_idx;      /* >= 0 once this request upgraded into a ws client */
  uint8_t body[STRIM_HTTP_BODY_MAX];
  size_t body_len;
};

/* =========================================================================
 * Per-ws-client state (STRIM_HTTP_MAX_WS_CLIENTS slots on the server)
 * ========================================================================= */

struct ws_client {
  int in_use;
  int idx;
  int closed;                       /* MHD_upgrade_action(CLOSE) issued */
  int closing;                      /* close handshake started; no more status */
  MHD_socket sock;                  /* raw socket handed over by MHD */
  struct MHD_UpgradeResponseHandle *urh;
  wslay_event_context_ptr wctx;
  struct http_session *session;     /* the request session (freed by MHD) */

  /* 1-deep outbound slot: latest-wins, guarded by slot_mutex. */
  pthread_mutex_t slot_mutex;
  int has_pending;
  uint8_t pending[STRIM_HTTP_STATUS_MAX];
  size_t pending_len;

  /* Frame currently handed to wslay + its write deadline (monotonic ms). */
  int frame_inflight;
  uint64_t frame_deadline_ms;

  /* Close-handshake deadline (monotonic ms). */
  uint64_t close_deadline_ms;

  /* Bytes MHD read past the HTTP headers (the client's first ws frames). */
  uint8_t *extra_in;
  size_t extra_in_len;
  size_t extra_in_off;
};

/* =========================================================================
 * Server
 * ========================================================================= */

struct strim_http_server {
  struct MHD_Daemon *daemon;
  int daemon_running;
  int port;                         /* bound port (for ":0" ephemeral binds) */
  uint64_t ws_write_timeout_ms;
  strim_http_callbacks cbs;
  void *userdata;
  volatile int shutdown_requested;  /* async-signal-safe flag */
  struct ws_client clients[STRIM_HTTP_MAX_WS_CLIENTS];
};

/* Singleton used by strim_http_ws_send (see internal.h): the controller runs
 * exactly one HTTP server; ws_send has no server parameter in the contract
 * and cannot derive it from userdata (start() receives userdata before the
 * server exists). Mirrors the alternate port's module globals. */
static struct strim_http_server *g_active_server = NULL;

/* =========================================================================
 * Small helpers
 * ========================================================================= */

static uint64_t mono_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t) ts.tv_sec * 1000u + (uint64_t) (ts.tv_nsec / 1000000);
}

/* Parse Go's ":port" address (main.go:332 addr = fmt.Sprintf(":%s", port)). */
static int parse_port(const char *addr) {
  const char *p;
  long v = 0;

  if (addr == NULL || addr[0] != ':')
    return -1;
  p = addr + 1;
  if (*p == '\0')
    return -1;
  if (*p == '0' && p[1] == '\0')
    return 0; /* ":0" -> ephemeral */
  for (; *p != '\0'; p++)
  {
    if (*p < '0' || *p > '9')
      return -1;
    v = v * 10 + (*p - '0');
    if (v > 65535)
      return -1;
  }
  return (int) v;
}

/* Case-insensitive token membership for a comma/space-separated header
 * value (Go's headerContainsToken, used by coder/websocket Accept). */
static int header_contains_token(const char *value, const char *token) {
  size_t token_len;
  const char *p;

  if (value == NULL || token == NULL)
    return 0;
  token_len = strlen(token);
  p = value;
  while (*p != '\0')
  {
    while (*p == ' ' || *p == '\t' || *p == ',')
      p++;
    if (*p == '\0')
      break;
    if (strncasecmp(p, token, token_len) == 0 &&
        (p[token_len] == '\0' || p[token_len] == ' ' || p[token_len] == '\t'
         || p[token_len] == ','))
      return 1;
    while (*p != '\0' && *p != ',')
      p++;
  }
  return 0;
}

static int method_kind(const char *method) {
  if (method == NULL)
    return HTTP_M_OTHER;
  if (strcmp(method, "GET") == 0)
    return HTTP_M_GET;
  if (strcmp(method, "POST") == 0)
    return HTTP_M_POST;
  return HTTP_M_OTHER;
}

static const char *method_name(int method) {
  switch (method)
  {
    case HTTP_M_GET:
      return "GET";
    case HTTP_M_POST:
      return "POST";
    default:
      return "?";
  }
}

/* Go's net/http mux matches whole paths. */
static int route_for(const char *url) {
  if (url == NULL)
    return ROUTE_UNKNOWN;
  if (strcmp(url, "/event") == 0)
    return ROUTE_EVENT;
  if (strcmp(url, "/control") == 0)
    return ROUTE_CONTROL;
  if (strcmp(url, "/status") == 0)
    return ROUTE_STATUS;
  if (strcmp(url, "/subscribe") == 0)
    return ROUTE_SUBSCRIBE;
  if (strcmp(url, "/healthz") == 0)
    return ROUTE_HEALTHZ;
  return ROUTE_UNKNOWN;
}

/* Weave a Go-style %q around a header value (or "(nil)"). */
static const char *quoted_value(const char *v, char *buf, size_t cap) {
  if (v == NULL)
  {
    snprintf(buf, cap, "%s", "(nil)");
    return buf;
  }
  snprintf(buf, cap, "\"%s\"", v);
  return buf;
}

/* -------------------------------------------------------------------------
 * Go duration parser (WEBSOCKET_WRITE_TIMEOUT, time.ParseDuration subset)
 * ------------------------------------------------------------------------- */

/* Parse Go's time.ParseDuration subset ("300ms", "5s", "1m30s", "1.5h")
 * into milliseconds. Returns 0 and fills *out_ms on success; non-zero on
 * malformed input. Accumulates nanoseconds first, then truncates to ms. */
static int parse_duration_ms(const char *s, uint64_t *out_ms) {
  const char *p = s;
  int neg = 0;
  uint64_t total_ns = 0;

  if (s == NULL || *s == '\0')
    return -1;
  if (*p == '-')
  {
    neg = 1;
    p++;
  }
  else if (*p == '+')
  {
    p++;
  }

  while (*p != '\0')
  {
    uint64_t whole = 0;
    uint64_t frac = 0;
    int frac_digits = 0;
    uint64_t unit_ns;
    int has_digits = 0;

    while (*p >= '0' && *p <= '9')
    {
      has_digits = 1;
      if (whole > (UINT64_MAX - 9u) / 10u)
        return -1;
      whole = whole * 10u + (uint64_t) (*p - '0');
      p++;
    }
    if (*p == '.')
    {
      p++;
      while (*p >= '0' && *p <= '9')
      {
        has_digits = 1;
        if (frac_digits < 9)
        {
          frac = frac * 10u + (uint64_t) (*p - '0');
          frac_digits++;
        }
        p++;
      }
    }
    if (!has_digits)
      return -1;

    if (p[0] == 'n' && p[1] == 's')
    {
      unit_ns = 1;
      p += 2;
    }
    else if (p[0] == 'u' && p[1] == 's')
    {
      unit_ns = 1000;
      p += 2;
    }
    else if ((uint8_t) p[0] == 0xc2 && (uint8_t) p[1] == 0xb5 && p[2] == 's')
    {
      unit_ns = 1000; /* "µs" */
      p += 3;
    }
    else if (p[0] == 'm' && p[1] == 's')
    {
      unit_ns = 1000000u;
      p += 2;
    }
    else if (*p == 's')
    {
      unit_ns = 1000000000u;
      p++;
    }
    else if (*p == 'm')
    {
      unit_ns = 60000000000u;
      p++;
    }
    else if (*p == 'h')
    {
      unit_ns = 3600000000000u;
      p++;
    }
    else
    {
      return -1;
    }

    if (whole > (UINT64_MAX - total_ns) / unit_ns)
      return -1;
    total_ns += whole * unit_ns;
    if (frac_digits > 0)
    {
      /* frac has frac_digits decimal digits; value = frac/10^d of unit. */
      uint64_t scale = 1;
      int i;
      for (i = 0; i < frac_digits; i++)
        scale *= 10u;
      if (frac <= UINT64_MAX / unit_ns)
        total_ns += (frac * unit_ns) / scale;
      else
        total_ns += (frac / scale) * unit_ns; /* coarse but bounded */
    }
  }

  *out_ms = neg ? 0u : total_ns / 1000000u;
  return 0;
}

static uint64_t ws_write_timeout_from_env(void) {
  const char *raw = getenv("WEBSOCKET_WRITE_TIMEOUT");
  uint64_t ms = 0;

  if (raw != NULL && parse_duration_ms(raw, &ms) == 0)
    return ms;
  return WS_WRITE_TIMEOUT_DEFAULT_MS;
}

/* =========================================================================
 * HTTP responses
 * ========================================================================= */

static enum MHD_Result respond(struct MHD_Connection *connection,
                               unsigned int status, const char *content_type,
                               int nosniff, const void *body, size_t body_len,
                               int close) {
  struct MHD_Response *resp = MHD_create_response_from_buffer(
      body_len, (body_len > 0) ? (void *) body : (void *) "",
      MHD_RESPMEM_MUST_COPY);

  if (resp == NULL)
    return MHD_NO;
  if (content_type != NULL)
    MHD_add_response_header(resp, MHD_HTTP_HEADER_CONTENT_TYPE, content_type);
  if (nosniff)
    MHD_add_response_header(resp, "X-Content-Type-Options", "nosniff");
  if (close)
    MHD_add_response_header(resp, MHD_HTTP_HEADER_CONNECTION, "close");
  {
    enum MHD_Result r = MHD_queue_response(connection, status, resp);
    MHD_destroy_response(resp);
    return r;
  }
}

static int conn_wants_close(struct MHD_Connection *connection) {
  const char *conn = MHD_lookup_connection_value(
      connection, MHD_HEADER_KIND, MHD_HTTP_HEADER_CONNECTION);
  return header_contains_token(conn, "close");
}

/* =========================================================================
 * WebSocket client plumbing
 * ========================================================================= */

/* wslay recv callback: serve MHD's leftover bytes first, then the socket. */
static ssize_t ws_recv_cb(wslay_event_context_ptr ctx, uint8_t *buf,
                          size_t len, int flags, void *user_data) {
  struct ws_client *c = user_data;
  size_t n;

  (void) ctx;
  (void) flags;

  if (c->extra_in_off < c->extra_in_len)
  {
    n = c->extra_in_len - c->extra_in_off;
    if (n > len)
      n = len;
    memcpy(buf, c->extra_in + c->extra_in_off, n);
    c->extra_in_off += n;
    return (ssize_t) n;
  }

  {
    ssize_t r = recv(c->sock, buf, len, 0);
    if (r == -1 && (errno == EAGAIN || errno == EWOULDBLOCK))
    {
      wslay_event_set_error(ctx, WSLAY_ERR_WOULDBLOCK);
      return -1;
    }
    if (r <= 0)
    {
      wslay_event_set_error(ctx, WSLAY_ERR_CALLBACK_FAILURE);
      return -1;
    }
    return r;
  }
}

static ssize_t ws_send_cb(wslay_event_context_ptr ctx, const uint8_t *data,
                          size_t len, int flags, void *user_data) {
  struct ws_client *c = user_data;
  ssize_t r;

  (void) ctx;
  (void) flags;

  r = send(c->sock, data, len, MSG_NOSIGNAL);
  if (r == -1 && (errno == EAGAIN || errno == EWOULDBLOCK))
  {
    wslay_event_set_error(ctx, WSLAY_ERR_WOULDBLOCK);
    return -1;
  }
  if (r <= 0)
  {
    wslay_event_set_error(ctx, WSLAY_ERR_CALLBACK_FAILURE);
    return -1;
  }
  return r;
}

/* Issue MHD_upgrade_action(CLOSE) — the only sanctioned way to close the
 * upgraded socket (MHD owns the fd). The slot stays reserved until MHD's
 * completion callback cleans it up. */
static void ws_close_socket(struct ws_client *c, uint16_t close_code) {
  if (c->closed)
    return;
  c->closed = 1;
  if (close_code != 0 && c->wctx != NULL
      && wslay_event_get_write_enabled(c->wctx)
      && !wslay_event_get_close_sent(c->wctx))
  {
    wslay_event_queue_close(c->wctx, close_code, NULL, 0);
    wslay_event_send(c->wctx); /* best-effort flush before closing */
  }
  MHD_upgrade_action(c->urh, MHD_UPGRADE_ACTION_CLOSE);
}

/* Start the close handshake: queue a close frame and arm its deadline.
 * Fail-loud: if wslay rejects the close (already closing), close now. */
static void ws_begin_close(struct ws_client *c, struct strim_http_server *srv,
                           uint16_t code, const uint8_t *reason,
                           size_t reason_len) {
  if (c->closing)
    return;
  if (wslay_event_queue_close(c->wctx, code, reason, reason_len) != 0)
  {
    ws_close_socket(c, 0);
    return;
  }
  c->closing = 1;
  c->close_deadline_ms = mono_ms() + srv->ws_write_timeout_ms;
}

/* Move the 1-deep slot frame into wslay (or start the 1000 close when
 * shutting down and nothing is pending). Runs only when no frame is
 * in flight, preserving the Go sendChannel(1) latest-wins semantics. */
static void ws_drain_slot(struct strim_http_server *srv, struct ws_client *c) {
  uint8_t *frame = NULL;
  size_t frame_len = 0;
  struct wslay_event_msg msg;

  pthread_mutex_lock(&c->slot_mutex);
  if (c->has_pending)
  {
    frame = c->pending;
    frame_len = c->pending_len;
    c->has_pending = 0;
  }
  pthread_mutex_unlock(&c->slot_mutex);

  if (frame == NULL)
  {
    if (srv->shutdown_requested && !c->closing)
      ws_begin_close(c, srv, WSLAY_CODE_NORMAL_CLOSURE, NULL, 0);
    return;
  }

  msg.opcode = WSLAY_TEXT_FRAME;
  msg.msg = frame;
  msg.msg_length = frame_len;
  if (wslay_event_queue_msg(c->wctx, &msg) != 0)
  {
    c->has_pending = 0; /* queue rejected (closing): drop the frame */
    return;
  }
  c->frame_inflight = 1;
  c->frame_deadline_ms = mono_ms() + srv->ws_write_timeout_ms;
}

/* One service pass over a live ws client: recv, slot->wslay, write-timeout,
 * send, close-handshake. Never blocks (the socket is non-blocking). */
static void ws_pump_client(struct strim_http_server *srv, struct ws_client *c) {
  int r;

  if (!c->in_use || c->closed)
    return;

  r = wslay_event_recv(c->wctx);
  if (r != 0)
  {
    ws_close_socket(c, WSLAY_CODE_ABNORMAL_CLOSURE);
    return;
  }
  if (wslay_event_get_close_received(c->wctx) && !c->closing)
  {
    /* Peer initiated close: Go's CloseRead cancels ctx and the writer
     * replies StatusNormalClosure (main.go:249,279-281). wslay already
     * queued the echo close; just drain it. */
    c->closing = 1;
    c->close_deadline_ms = mono_ms() + srv->ws_write_timeout_ms;
  }

  if (!c->closing && !c->frame_inflight)
    ws_drain_slot(srv, c);

  if (c->frame_inflight && !c->closing
      && mono_ms() >= c->frame_deadline_ms)
  {
    /* wsjson.Write ctx deadline (main.go:283-288) -> close 1011. */
    ws_begin_close(c, srv, WSLAY_CODE_INTERNAL_SERVER_ERROR,
                   (const uint8_t *) "write timeout", 13);
  }

  r = wslay_event_send(c->wctx);
  if (r != 0)
  {
    ws_close_socket(c, 0);
    return;
  }

  if (c->frame_inflight && !wslay_event_want_write(c->wctx))
    c->frame_inflight = 0;

  if (c->closing && wslay_event_get_close_sent(c->wctx))
  {
    ws_close_socket(c, 0);
    return;
  }
  if (c->closing && !wslay_event_get_close_sent(c->wctx)
      && mono_ms() >= c->close_deadline_ms)
  {
    ws_close_socket(c, 0);
    return;
  }
}

static void ws_pump_all(struct strim_http_server *srv) {
  int i;
  for (i = 0; i < STRIM_HTTP_MAX_WS_CLIENTS; i++)
    ws_pump_client(srv, &srv->clients[i]);
}

/* Free the slot's wslay context, leftover bytes, and unregister the client
 * listener. The session is NOT freed here (MHD's completion callback owns
 * it); session->client_idx is cleared so the callback only frees it.
 *
 * slot_mutex is deliberately NOT destroyed or memset: a ws_send from the
 * controller thread may be locking it concurrently. It is initialized once
 * at server start and reused by every client of the slot (Linux pthread
 * mutexes are plain structs, valid for the server's lifetime). */
static void ws_cleanup_slot(struct strim_http_server *srv, struct ws_client *c,
                            struct http_session *session) {
  if (!c->in_use || c->session != session)
    return; /* already cleaned, or the slot was reused */

  c->in_use = 0;
  c->closed = 1;
  if (session != NULL)
    session->client_idx = -1;
  if (c->wctx != NULL)
  {
    wslay_event_context_free(c->wctx);
    c->wctx = NULL;
  }
  free(c->extra_in);
  c->extra_in = NULL;
  c->extra_in_len = c->extra_in_off = 0;
  srv->cbs.ws_unsubscribe(srv->userdata, c->idx);

  /* Reset every field except slot_mutex (the next client reuses it). */
  c->idx = 0;
  c->sock = MHD_INVALID_SOCKET;
  c->urh = NULL;
  c->session = NULL;
  c->has_pending = 0;
  c->pending_len = 0;
  c->frame_inflight = 0;
  c->frame_deadline_ms = 0;
  c->close_deadline_ms = 0;
}

/* Flush pending writes best-effort, then close every ws client with 1000
 * (Go srv.Shutdown + StatusNormalClosure, main.go:279-281,348-355). */
static void ws_shutdown_all(struct strim_http_server *srv) {
  int pass;
  int i;

  for (pass = 0; pass < 256; pass++)
  {
    int live = 0;
    for (i = 0; i < STRIM_HTTP_MAX_WS_CLIENTS; i++)
    {
      struct ws_client *c = &srv->clients[i];
      if (!c->in_use || c->closed)
        continue;
      live++;
      if (!c->closing && !c->frame_inflight)
        ws_drain_slot(srv, c);
      if (c->frame_inflight && !c->closing)
      {
        wslay_event_send(c->wctx);
        if (wslay_event_want_write(c->wctx))
          continue; /* still flushing the pending frame */
        c->frame_inflight = 0;
      }
      if (!c->closing)
        ws_begin_close(c, srv, WSLAY_CODE_NORMAL_CLOSURE, NULL, 0);
      wslay_event_send(c->wctx);
      if (!wslay_event_get_close_sent(c->wctx))
        continue; /* close reply still flushing */
      ws_close_socket(c, 0);
    }
    if (live == 0)
      break;
  }

  /* Stragglers (unflushable sockets): close hard. */
  for (i = 0; i < STRIM_HTTP_MAX_WS_CLIENTS; i++)
  {
    struct ws_client *c = &srv->clients[i];
    if (c->in_use && !c->closed)
      ws_close_socket(c, WSLAY_CODE_NORMAL_CLOSURE);
  }
}

/* =========================================================================
 * The MHD upgrade handoff
 * ========================================================================= */

static void ws_upgrade_handler(void *cls, struct MHD_Connection *connection,
                               void *req_cls, const char *extra_in,
                               size_t extra_in_size, MHD_socket sock,
                               struct MHD_UpgradeResponseHandle *urh) {
  struct strim_http_server *srv = cls;
  struct http_session *session = req_cls;
  struct ws_client *c;
  struct wslay_event_callbacks wscb;
  int idx;
  int i;

  (void) connection;

  idx = -1;
  for (i = 0; i < STRIM_HTTP_MAX_WS_CLIENTS; i++)
  {
    if (!srv->clients[i].in_use)
    {
      idx = i;
      break;
    }
  }
  if (idx < 0)
  {
    /* Go grows the listener slice without bound; the C port caps at
     * STRIM_HTTP_MAX_WS_CLIENTS and fails loud beyond (documented
     * deviation, http_server.h). */
    MHD_upgrade_action(urh, MHD_UPGRADE_ACTION_CLOSE);
    return;
  }
  c = &srv->clients[idx];

  /* The slot's mutex is initialized once at server start and reused; do not
   * re-init or memset it here (a stale ws_send may be locking it). */
  c->in_use = 1; /* before ws_subscribe: the listener fires synchronously */
  c->idx = idx;
  c->closed = 0;
  c->closing = 0;
  c->sock = sock;
  c->urh = urh;
  c->session = session;
  c->has_pending = 0;
  c->pending_len = 0;
  c->frame_inflight = 0;
  c->frame_deadline_ms = 0;
  c->close_deadline_ms = 0;
  c->extra_in = NULL;
  c->extra_in_len = c->extra_in_off = 0;

  if (extra_in_size > 0)
  {
    c->extra_in = malloc(extra_in_size);
    if (c->extra_in == NULL)
    {
      ws_close_socket(c, 0);
      return;
    }
    memcpy(c->extra_in, extra_in, extra_in_size);
    c->extra_in_len = extra_in_size;
  }

  memset(&wscb, 0, sizeof(wscb));
  wscb.recv_callback = ws_recv_cb;
  wscb.send_callback = ws_send_cb;
  if (wslay_event_context_server_init(&c->wctx, &wscb, c) != 0)
  {
    ws_close_socket(c, 0);
    return;
  }
  wslay_event_config_set_max_recv_msg_length(c->wctx, STRIM_HTTP_BODY_MAX);

  session->client_idx = idx;

  if (srv->cbs.ws_subscribe(srv->userdata, idx) != 0)
  {
    /* Go: conn.Close(websocket.StatusInternalError, err.Error())
     * (main.go:264) — close 1011. */
    ws_begin_close(c, srv, WSLAY_CODE_INTERNAL_SERVER_ERROR,
                   (const uint8_t *) "could not add listener", 24);
    wslay_event_send(c->wctx);
    ws_close_socket(c, 0);
    return;
  }
}

/* =========================================================================
 * Request dispatch (the Go mux, main.go:235-299 + postJSON/getJSON :368-399)
 * ========================================================================= */

static enum MHD_Result dispatch_post(struct strim_http_server *srv,
                                     struct MHD_Connection *connection,
                                     struct http_session *s, int close) {
  char err[STRIM_HTTP_ERRBUF_MAX];
  char body[STRIM_HTTP_ERRBUF_MAX + 16];
  int rc;
  int bl;

  if (s->method != HTTP_M_POST)
  {
    return respond(connection, MHD_HTTP_METHOD_NOT_ALLOWED,
                   "text/plain; charset=utf-8", 1, "method not allowed\n", 19,
                   close);
  }
  if (s->body_overflow)
  {
    return respond(connection, MHD_HTTP_CONTENT_TOO_LARGE,
                   "text/plain; charset=utf-8", 1, NULL, 0, close);
  }

  err[0] = '\0';
  rc = (s->route == ROUTE_EVENT)
           ? srv->cbs.handle_event(srv->userdata, s->body, s->body_len, err,
                                   sizeof(err))
           : srv->cbs.handle_control(srv->userdata, s->body, s->body_len, err,
                                     sizeof(err));

  if (rc != 0)
  {
    if (rc == STRIM_HTTP_ERR_BADJSON)
    {
      /* Go: http.Error(w, fmt.Sprintf("bad json: %v", err), 400). */
      bl = snprintf(body, sizeof(body), "bad json: %s\n", err);
      return respond(connection, MHD_HTTP_BAD_REQUEST,
                     "text/plain; charset=utf-8", 1, body, (size_t) bl, close);
    }
    /* Go: http.Error(w, err.Error(), 500) — error text + trailing '\n'. */
    bl = (int) strlen(err);
    if (bl + 1 < (int) sizeof(err))
    {
      err[bl] = '\n';
      err[bl + 1] = '\0';
      bl++;
    }
    return respond(connection, MHD_HTTP_INTERNAL_SERVER_ERROR,
                   "text/plain; charset=utf-8", 1, err, (size_t) bl, close);
  }

  srv->cbs.request_reconcile(srv->userdata);
  return respond(connection, MHD_HTTP_NO_CONTENT, NULL, 0, NULL, 0, close);
}

static enum MHD_Result dispatch_subscribe(struct strim_http_server *srv,
                                          struct MHD_Connection *connection,
                                          struct http_session *s, int close) {
  const char *conn_hdr = MHD_lookup_connection_value(connection, MHD_HEADER_KIND,
                                                     MHD_HTTP_HEADER_CONNECTION);
  const char *upg_hdr = MHD_lookup_connection_value(connection, MHD_HEADER_KIND,
                                                    "Upgrade");
  const char *version_hdr =
      MHD_lookup_connection_value(connection, MHD_HEADER_KIND,
                                  "Sec-WebSocket-Version");
  const char *key_hdr = MHD_lookup_connection_value(connection, MHD_HEADER_KIND,
                                                    "Sec-WebSocket-Key");
  char qbuf[STRIM_HTTP_ERRBUF_MAX];
  char body[STRIM_HTTP_ERRBUF_MAX + 32];
  uint8_t key_bytes[16];
  uint8_t hb[128];
  uint8_t digest[20];
  char accept_buf[32];
  size_t hb_len;
  size_t key_len = 0;
  int bl;

  /* Go's coder/websocket Accept verification order (accept.go
   * verifyClientRequest), faithfully ported. */
  if (!header_contains_token(conn_hdr, "upgrade"))
  {
    bl = snprintf(body, sizeof(body),
                  "WebSocket protocol violation: Connection header %s does "
                  "not contain Upgrade\n",
                  quoted_value(conn_hdr, qbuf, sizeof(qbuf)));
    return respond(connection, MHD_HTTP_UPGRADE_REQUIRED,
                   "text/plain; charset=utf-8", 1, body, (size_t) bl, close);
  }
  if (!header_contains_token(upg_hdr, "websocket"))
  {
    bl = snprintf(body, sizeof(body),
                  "WebSocket protocol violation: Upgrade header %s does not "
                  "contain websocket\n",
                  quoted_value(upg_hdr, qbuf, sizeof(qbuf)));
    return respond(connection, MHD_HTTP_UPGRADE_REQUIRED,
                   "text/plain; charset=utf-8", 1, body, (size_t) bl, close);
  }
  if (s->method != HTTP_M_GET)
  {
    bl = snprintf(body, sizeof(body),
                  "WebSocket protocol violation: handshake request method is "
                  "not GET but \"%s\"\n",
                  method_name(s->method));
    return respond(connection, MHD_HTTP_METHOD_NOT_ALLOWED,
                   "text/plain; charset=utf-8", 1, body, (size_t) bl, close);
  }
  if (version_hdr == NULL || strcmp(version_hdr, "13") != 0)
  {
    bl = snprintf(body, sizeof(body),
                  "WebSocket protocol violation: unsupported WebSocket "
                  "version requested (only 13 is supported)\n");
    return respond(connection, MHD_HTTP_UPGRADE_REQUIRED,
                   "text/plain; charset=utf-8", 1, body, (size_t) bl, close);
  }
  if (key_hdr == NULL || key_hdr[0] == '\0')
  {
    return respond(connection, MHD_HTTP_BAD_REQUEST,
                   "text/plain; charset=utf-8", 1,
                   "WebSocket protocol violation: missing Sec-WebSocket-Key\n",
                   58, close);
  }
  if (strim_base64_decode(key_hdr, strlen(key_hdr), key_bytes,
                          sizeof(key_bytes), &key_len) != 0
      || key_len != 16)
  {
    return respond(connection, MHD_HTTP_BAD_REQUEST,
                   "text/plain; charset=utf-8", 1,
                   "WebSocket protocol violation: invalid Sec-WebSocket-Key\n",
                   59, close);
  }

  /* accept = base64(sha1(key + GUID)) (RFC 6455 section 4.2.2). */
  hb_len = strlen(key_hdr);
  memcpy(hb, key_hdr, hb_len);
  memcpy(hb + hb_len, WS_GUID, WS_GUID_LEN);
  hb_len += WS_GUID_LEN;
  strim_sha1(hb, hb_len, digest);
  if (strim_base64_encode(digest, sizeof(digest), accept_buf,
                          sizeof(accept_buf)) == 0)
    return MHD_NO;

  {
    struct MHD_Response *resp =
        MHD_create_response_for_upgrade(&ws_upgrade_handler, srv);
    enum MHD_Result r;

    if (resp == NULL)
      return MHD_NO;
    MHD_add_response_header(resp, "Upgrade", "websocket");
    /* MHD_create_response_for_upgrade already sets "Connection: Upgrade";
     * adding it again makes MHD emit "Connection: Upgrade, Upgrade", which
     * strict clients like undici reject with close code 1006. */
    MHD_add_response_header(resp, "Sec-WebSocket-Accept", accept_buf);
    r = MHD_queue_response(connection, MHD_HTTP_SWITCHING_PROTOCOLS, resp);
    MHD_destroy_response(resp);
    return r;
  }
}

static enum MHD_Result dispatch(struct strim_http_server *srv,
                                struct MHD_Connection *connection,
                                struct http_session *s) {
  int close = conn_wants_close(connection);
  uint8_t status_json[STRIM_HTTP_STATUS_MAX];
  size_t status_len = 0;
  int rc;

  switch (s->route)
  {
    case ROUTE_UNKNOWN:
      /* Go mux default NotFound: "404 page not found\n". */
      return respond(connection, MHD_HTTP_NOT_FOUND,
                     "text/plain; charset=utf-8", 1, "404 page not found\n",
                     19, close);

    case ROUTE_HEALTHZ:
      /* main.go:293-299: any method -> 200 "ok\n". */
      return respond(connection, MHD_HTTP_OK, "text/plain; charset=utf-8", 0,
                     "ok\n", 3, close);

    case ROUTE_STATUS:
      /* getJSON (main.go:387-399): GET only; application/json; the body is
       * the controller's serialized status (+ trailing '\n', Go's
       * json.NewEncoder). */
      if (s->method != HTTP_M_GET)
      {
        return respond(connection, MHD_HTTP_METHOD_NOT_ALLOWED,
                       "text/plain; charset=utf-8", 1, "method not allowed\n",
                       19, close);
      }
      rc = srv->cbs.handle_status(srv->userdata, status_json,
                                  sizeof(status_json), &status_len);
      if (rc != 0 || status_len == 0)
      {
        return respond(connection, MHD_HTTP_INTERNAL_SERVER_ERROR,
                       "text/plain; charset=utf-8", 1, NULL, 0, close);
      }
      return respond(connection, MHD_HTTP_OK, "application/json", 0,
                     status_json, status_len, close);

    case ROUTE_EVENT:
    case ROUTE_CONTROL:
      return dispatch_post(srv, connection, s, close);

    case ROUTE_SUBSCRIBE:
      return dispatch_subscribe(srv, connection, s, close);

    default:
      return MHD_NO;
  }
}

/* =========================================================================
 * The MHD access handler
 * ========================================================================= */

static enum MHD_Result answer_cb(void *cls, struct MHD_Connection *connection,
                                 const char *url, const char *method,
                                 const char *version, const char *upload_data,
                                 size_t *upload_data_size, void **con_cls) {
  struct strim_http_server *srv = cls;
  struct http_session *s = *con_cls;

  (void) version;

  if (s == NULL)
  {
    /* First call (MHD_CONNECTION_HEADERS_PROCESSED): the request body has
     * NOT arrived yet, so do not dispatch. MHD calls again with upload
     * chunks, then once more with *upload_data_size == 0 (the final call,
     * MHD_CONNECTION_FULL_REQ_RECEIVED) — that is where we respond. */
    s = calloc(1, sizeof(*s));
    if (s == NULL)
      return MHD_NO;
    s->method = method_kind(method);
    s->route = route_for(url);
    s->client_idx = -1;
    *con_cls = s;
    return MHD_YES;
  }

  if (*upload_data_size > 0)
  {
    /* Accumulate the request body (bounded; overflow fails loud). */
    if (s->body_len + *upload_data_size <= sizeof(s->body))
    {
      memcpy(s->body + s->body_len, upload_data, *upload_data_size);
      s->body_len += *upload_data_size;
    }
    else
    {
      s->body_overflow = 1;
    }
    *upload_data_size = 0;
    return MHD_YES;
  }

  return dispatch(srv, connection, s);
}

/* MHD_OPTION_NOTIFY_COMPLETED: free the per-request session and, for an
 * upgraded ws request, free the client slot + unregister the listener.
 * MHD fires this exactly once per request, including upgraded connections
 * (daemon.c resumes upgraded connections into cleanup after the app's
 * MHD_UPGRADE_ACTION_CLOSE). */
static void request_completed_cb(void *cls, struct MHD_Connection *connection,
                                 void **con_cls,
                                 enum MHD_RequestTerminationCode toe) {
  struct strim_http_server *srv = cls;
  struct http_session *s = *con_cls;

  (void) connection;
  (void) toe;

  if (s == NULL)
    return;
  if (s->client_idx >= 0)
    ws_cleanup_slot(srv, &srv->clients[s->client_idx], s);
  free(s);
  *con_cls = NULL;
}

/* =========================================================================
 * API — http_server.h
 * ========================================================================= */

int strim_http_server_start(strim_http_server **out, const char *addr,
                            const strim_http_callbacks *cbs, void *userdata) {
  struct strim_http_server *srv;
  const union MHD_DaemonInfo *info;
  int port;
  int i;

  if (out == NULL || addr == NULL || cbs == NULL)
    return -1;
  if (cbs->handle_event == NULL || cbs->handle_control == NULL
      || cbs->handle_status == NULL || cbs->request_reconcile == NULL
      || cbs->ws_subscribe == NULL || cbs->ws_unsubscribe == NULL
      || cbs->ws_send == NULL)
    return -1;
  if (g_active_server != NULL)
    return -1; /* singleton ws_send: one server at a time (see internal.h) */

  port = parse_port(addr);
  if (port < 0)
    return -1;

  srv = calloc(1, sizeof(*srv));
  if (srv == NULL)
    return -1;
  srv->cbs = *cbs;
  srv->userdata = userdata;
  srv->ws_write_timeout_ms = ws_write_timeout_from_env();
  srv->port = port;

  for (i = 0; i < STRIM_HTTP_MAX_WS_CLIENTS; i++)
    pthread_mutex_init(&srv->clients[i].slot_mutex, NULL);

  /* External event loop mode: no internal thread; the caller drives
   * strim_http_server_service (the single-threaded-core controller
   * pattern, verified in mhd_smoke_test scenario B). MHD_ALLOW_UPGRADE
   * is required for the /subscribe wslay handoff (MHD_create_response_
   * for_upgrade asserts it). */
  srv->daemon = MHD_start_daemon(MHD_USE_EPOLL | MHD_USE_ITC
                                     | MHD_USE_ERROR_LOG | MHD_ALLOW_UPGRADE,
                                 (unsigned int) port, NULL, NULL, &answer_cb,
                                 srv, MHD_OPTION_NOTIFY_COMPLETED,
                                 &request_completed_cb, srv, MHD_OPTION_END);
  if (srv->daemon == NULL)
  {
    for (i = 0; i < STRIM_HTTP_MAX_WS_CLIENTS; i++)
      pthread_mutex_destroy(&srv->clients[i].slot_mutex);
    free(srv);
    return -1;
  }

  info = MHD_get_daemon_info(srv->daemon, MHD_DAEMON_INFO_BIND_PORT);
  if (info != NULL)
    srv->port = (int) info->port;
  srv->daemon_running = 1;
  g_active_server = srv;

  *out = srv;
  return 0;
}

static void stop_daemon(struct strim_http_server *srv) {
  if (srv->daemon != NULL && srv->daemon_running)
  {
    MHD_stop_daemon(srv->daemon); /* fires completion callbacks (cleanup) */
    srv->daemon_running = 0;
  }
}

int strim_http_server_service(strim_http_server *server, int timeout_ms) {
  if (server == NULL || server->daemon == NULL)
    return -1;

  if (timeout_ms < 0)
  {
    /* Loop until shutdown_request (Go's ListenAndServe loop), then close
     * every ws client with 1000 and release (srv.Shutdown, main.go:348-355). */
    while (!server->shutdown_requested)
    {
      if (MHD_run_wait(server->daemon, SERVICE_PASS_MS) != MHD_YES)
        return -1;
      ws_pump_all(server);
    }
    ws_shutdown_all(server);
    ws_pump_all(server); /* final pass after the close frames */
    stop_daemon(server);
    return 0;
  }

  if (MHD_run_wait(server->daemon, timeout_ms) != MHD_YES)
    return -1;
  ws_pump_all(server);
  return 0;
}

void strim_http_server_shutdown_request(strim_http_server *server) {
  if (server == NULL)
    return;
  server->shutdown_requested = 1; /* volatile store: async-signal-safe */
}

void strim_http_server_destroy(strim_http_server *server) {
  int i;

  if (server == NULL)
    return;

  if (server->daemon_running)
  {
    ws_shutdown_all(server);
    stop_daemon(server);
  }

  /* Defensive: any slot the completion callbacks could not reach. */
  for (i = 0; i < STRIM_HTTP_MAX_WS_CLIENTS; i++)
  {
    struct ws_client *c = &server->clients[i];
    if (c->in_use)
      ws_cleanup_slot(server, c, c->session);
  }

  if (g_active_server == server)
    g_active_server = NULL;
  free(server);
}

/* =========================================================================
 * API — internal.h (the ws_send slot the controller lane calls)
 * ========================================================================= */

int strim_http_ws_send(void *userdata, int client_idx, const uint8_t *bytes,
                       size_t len) {
  struct strim_http_server *srv = g_active_server;
  struct ws_client *c;
  int ok;

  (void) userdata; /* the singleton resolves the server (see internal.h) */

  if (srv == NULL || bytes == NULL || len == 0 || len > STRIM_HTTP_STATUS_MAX)
    return -1;
  if (client_idx < 0 || client_idx >= STRIM_HTTP_MAX_WS_CLIENTS)
    return -1;

  c = &srv->clients[client_idx];
  pthread_mutex_lock(&c->slot_mutex);
  ok = c->in_use && !c->closed && !c->closing;
  if (ok)
  {
    /* 1-deep drop-oldest/latest-wins (main.go:251-259). */
    memcpy(c->pending, bytes, len);
    c->pending_len = len;
    c->has_pending = 1;
  }
  pthread_mutex_unlock(&c->slot_mutex);
  return ok ? 0 : -1;
}

int strim_http_server_bound_port(const strim_http_server *server) {
  if (server == NULL)
    return -1;
  return server->port;
}