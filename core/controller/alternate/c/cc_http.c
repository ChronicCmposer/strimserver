/*
 * cc_http.c — HTTP/1.1 + WebSocket serving layer (Phase 4.6).
 *
 * Thin C wrapper over the vendored libwebsockets v5.0.0 (server-only, H1+WS).
 * Owns every libwebsockets call; delegates JSON/state/routing to the asm
 * module (core/controller/alternate/asm/cc_http.S) through the handler pointers passed
 * to cc_http_init. The wire contract is ported byte-for-byte from the Go
 * controller (core/controller/main.go:235-400) — see cc_http.h and the
 * assembly module header for the per-route citations.
 *
 * License: project code (see LICENSE). No GPL.
 */

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <libwebsockets.h>

#include "cc_http.h"

/* =========================================================================
 * Module state (single-threaded: one context, one controller, 4 ws clients)
 * ========================================================================= */

static struct lws_context *g_ctx = NULL;
static void *g_controller = NULL;
static uint64_t g_write_timeout_ns = 0;
static volatile int g_shutdown = 0;
/* Set while cc_http_service(-1) owns the event loop: then cc_http_shutdown_
 * request only raises the flag (the loop flushes and destroys on exit), so
 * two threads never call lws_service concurrently. */
static volatile int g_service_loop = 0;

/* The asm handlers (cc_http.S) — linked directly, no registration. */
extern int cc_http_handle_status(void *, uint8_t *, uint32_t, uint32_t *);
extern int cc_http_handle_control(void *, const uint8_t *, uint32_t, char *,
                                  uint32_t);
extern int cc_http_handle_event(void *, const uint8_t *, uint32_t, char *,
                                uint32_t);
extern int cc_http_ws_connect(void *, int);
extern int cc_http_ws_disconnect(void *, int);
extern uint64_t cc_env_dur(const char *name); /* time.ParseDuration (asm) */

/* ---- per-client ws state ------------------------------------------------ */

struct cc_http_client {
  struct lws *wsi; /* NULL = slot free */
  int client_idx;
  uint8_t has_pending;              /* 1-deep queue occupancy */
  unsigned char pending[LWS_PRE + CC_HTTP_STATUS_MAX]; /* the queued frame */
  uint32_t pending_len;
  uint64_t deadline_ns;             /* write attempt deadline (monotonic) */
};

static struct cc_http_client g_clients[CC_HTTP_MAX_WS_CLIENTS];

/* ---- per-connection session (LWS user space) ---------------------------- */

enum {
  HTTP_M_NONE = 0,
  HTTP_M_GET,
  HTTP_M_POST,
  HTTP_M_OTHER,
};

enum {
  ROUTE_NONE = 0,
  ROUTE_EVENT,
  ROUTE_CONTROL,
  ROUTE_STATUS,
  ROUTE_SUBSCRIBE,
  ROUTE_HEALTHZ,
  ROUTE_UNKNOWN,
};

struct http_session {
  int client_idx; /* ws client slot, -1 = not a ws client */
  int method;
  int route;
  int handled;    /* the request was dispatched once */
  char uri[CC_HTTP_URI_MAX];
  int uri_len;
  uint8_t body[CC_HTTP_BODY_MAX];
  uint32_t body_len;
};

/* =========================================================================
 * Small helpers
 * ========================================================================= */

static uint64_t mono_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

/* Match an exact route path (Go's net/http mux matches whole paths). */
static int route_for(const char *uri, int len) {
  if (len == 6 && memcmp(uri, "/event", 6) == 0)
    return ROUTE_EVENT;
  if (len == 8 && memcmp(uri, "/control", 8) == 0)
    return ROUTE_CONTROL;
  if (len == 7 && memcmp(uri, "/status", 7) == 0)
    return ROUTE_STATUS;
  if (len == 10 && memcmp(uri, "/subscribe", 10) == 0)
    return ROUTE_SUBSCRIBE;
  if (len == 8 && memcmp(uri, "/healthz", 8) == 0)
    return ROUTE_HEALTHZ;
  return ROUTE_UNKNOWN;
}

static int conn_wants_close(struct lws *wsi) {
  char buf[128];
  int n = lws_hdr_copy(wsi, buf, sizeof(buf) - 1, WSI_TOKEN_CONNECTION);
  if (n <= 0)
    return 0;
  buf[n] = '\0';
  return strcasestr(buf, "close") != NULL;
}

/* =========================================================================
 * Response writer
 * =========================================================================
 * Writes a complete HTTP response as a manual header block + body, the way
 * Go's net/http does: status line, the caller's headers, Content-Length,
 * Connection: close iff the request asked for it, then the body. Header
 * ORDER is not part of the wire contract (Go's own order varies by handler
 * and includes a Date header that changes every second); the status line,
 * the semantic headers, Content-Length, and the body bytes match Go.
 */

static int http_respond(struct lws *wsi, int status, const char *extra_headers,
                        const char *content_type, int nosniff,
                        const uint8_t *body, int body_len, int close) {
  char hdr[512];
  int n = 0;

  n += snprintf(hdr + n, sizeof(hdr) - (size_t)n, "HTTP/1.1 %d ", status);
  switch (status) {
    case 200: n += snprintf(hdr + n, sizeof(hdr) - (size_t)n, "OK"); break;
    case 204: n += snprintf(hdr + n, sizeof(hdr) - (size_t)n, "No Content"); break;
    case 400: n += snprintf(hdr + n, sizeof(hdr) - (size_t)n, "Bad Request"); break;
    case 404: n += snprintf(hdr + n, sizeof(hdr) - (size_t)n, "Not Found"); break;
    case 405: n += snprintf(hdr + n, sizeof(hdr) - (size_t)n, "Method Not Allowed"); break;
    case 413: n += snprintf(hdr + n, sizeof(hdr) - (size_t)n, "Request Entity Too Large"); break;
    case 426: n += snprintf(hdr + n, sizeof(hdr) - (size_t)n, "Upgrade Required"); break;
    case 500: n += snprintf(hdr + n, sizeof(hdr) - (size_t)n, "Internal Server Error"); break;
    default:  n += snprintf(hdr + n, sizeof(hdr) - (size_t)n, "Unknown"); break;
  }
  n += snprintf(hdr + n, sizeof(hdr) - (size_t)n, "\r\n");
  if (extra_headers != NULL)
    n += snprintf(hdr + n, sizeof(hdr) - (size_t)n, "%s", extra_headers);
  if (content_type != NULL)
    n += snprintf(hdr + n, sizeof(hdr) - (size_t)n, "Content-Type: %s\r\n",
                  content_type);
  if (nosniff)
    n += snprintf(hdr + n, sizeof(hdr) - (size_t)n,
                  "X-Content-Type-Options: nosniff\r\n");
  if (status != 204)
    n += snprintf(hdr + n, sizeof(hdr) - (size_t)n, "Content-Length: %d\r\n",
                  body_len);
  if (close)
    n += snprintf(hdr + n, sizeof(hdr) - (size_t)n, "Connection: close\r\n");
  n += snprintf(hdr + n, sizeof(hdr) - (size_t)n, "\r\n");

  if (lws_write(wsi, (unsigned char *)hdr, (size_t)n, LWS_WRITE_HTTP_HEADERS) != n)
    return -1;
  if (body_len > 0 &&
      lws_write(wsi, (unsigned char *)body, (size_t)body_len, LWS_WRITE_HTTP) != body_len)
    return -1;
  return 0;
}

/* =========================================================================
 * HTTP request dispatch (the Go mux, main.go:235-242 + 293-299 + postJSON/
 * getJSON :368-399)
 * ========================================================================= */

static int http_dispatch(struct lws *wsi, struct http_session *s) {
  char errbuf[CC_HTTP_ERRBUF_MAX];
  char scratch[CC_HTTP_STATUS_MAX];
  uint32_t out_len = 0;
  int close = conn_wants_close(wsi);
  int rc;

  if (s->handled)
    return 0;
  s->handled = 1;

  switch (s->route) {
    case ROUTE_UNKNOWN:
      /* Go mux default NotFound (http.NewServeMux): "404 page not found\n". */
      if (http_respond(wsi, 404, NULL, "text/plain; charset=utf-8", 1,
                       (const uint8_t *)"404 page not found\n", 19, close) < 0)
        return -1;
      return lws_http_transaction_completed(wsi);

    case ROUTE_HEALTHZ:
      /* main.go:293-299: any method -> 200 "ok\n" (Go sniffs text/plain). */
      if (http_respond(wsi, 200, NULL, "text/plain; charset=utf-8", 0,
                       (const uint8_t *)"ok\n", 3, close) < 0)
        return -1;
      return lws_http_transaction_completed(wsi);

    case ROUTE_STATUS:
      /* getJSON (main.go:387-399): GET only; Content-Type application/json;
       * body = json.NewEncoder(w).Encode(status) (Marshal bytes + '\n'). */
      if (s->method != HTTP_M_GET) {
        if (http_respond(wsi, 405, NULL, "text/plain; charset=utf-8", 1,
                         (const uint8_t *)"method not allowed\n", 19, close) < 0)
          return -1;
        return lws_http_transaction_completed(wsi);
      }
      rc = cc_http_handle_status(g_controller, (uint8_t *)scratch,
                           (uint32_t)sizeof(scratch), &out_len);
      if (rc != 0) {
        if (http_respond(wsi, 500, NULL, "text/plain; charset=utf-8", 1, NULL, 0, close) < 0)
          return -1;
        return lws_http_transaction_completed(wsi);
      }
      if (http_respond(wsi, 200, NULL, "application/json", 0,
                       (const uint8_t *)scratch, (int)out_len, close) < 0)
        return -1;
      return lws_http_transaction_completed(wsi);

    case ROUTE_EVENT:
    case ROUTE_CONTROL: {
      /* postJSON (main.go:368-385): POST only; Decode; handler; reconcile;
       * 204. 400 bad json / 500 handler error use Go's http.Error body. */
      if (s->method != HTTP_M_POST) {
        if (http_respond(wsi, 405, NULL, "text/plain; charset=utf-8", 1,
                         (const uint8_t *)"method not allowed\n", 19, close) < 0)
          return -1;
        return lws_http_transaction_completed(wsi);
      }
      if (s->body_len > CC_HTTP_BODY_MAX) {
        if (http_respond(wsi, 413, NULL, "text/plain; charset=utf-8", 1, NULL, 0, close) < 0)
          return -1;
        return lws_http_transaction_completed(wsi);
      }
      if (s->route == ROUTE_EVENT)
        rc = cc_http_handle_event(g_controller, s->body, s->body_len, errbuf,
                            (uint32_t)sizeof(errbuf));
      else
        rc = cc_http_handle_control(g_controller, s->body, s->body_len, errbuf,
                              (uint32_t)sizeof(errbuf));
      if (rc == CC_HTTP_ERR_BADJSON) {
        /* Go: http.Error(w, fmt.Sprintf("bad json: %v", err), 400) — the
         * error text plus http.Error's trailing newline. */
        char body[CC_HTTP_ERRBUF_MAX + 16];
        int bl = snprintf(body, sizeof(body), "bad json: %s\n", errbuf);
        if (http_respond(wsi, 400, NULL, "text/plain; charset=utf-8", 1, (const uint8_t *)body,
                         bl, close) < 0)
          return -1;
        return lws_http_transaction_completed(wsi);
      }
      if (rc != 0) {
        /* Go: http.Error(w, err.Error(), 500) — err.Error() plus the
         * trailing newline (appended in place; no overlapping snprintf). */
        int bl = (int)strlen(errbuf);
        if (bl + 1 < (int)sizeof(errbuf)) {
          errbuf[bl] = '\n';
          errbuf[bl + 1] = '\0';
          bl++;
        }
        if (http_respond(wsi, 500, NULL, "text/plain; charset=utf-8", 1,
                         (const uint8_t *)errbuf, bl, close) < 0)
          return -1;
        return lws_http_transaction_completed(wsi);
      }
      if (http_respond(wsi, 204, NULL, NULL, 0, NULL, 0, close) < 0)
        return -1;
      return lws_http_transaction_completed(wsi);
    }

    case ROUTE_SUBSCRIBE:
      /* A plain (non-upgrade) request to /subscribe: Go's websocket.Accept
       * rejects it (accept.go verifyClientRequest) with 426 and the exact
       * coder/websocket message quoting the request's Connection header. */
      {
        char conn[128];
        char body[256];
        int cl;
        int n = lws_hdr_copy(wsi, conn, sizeof(conn) - 1, WSI_TOKEN_CONNECTION);
        if (n < 0)
          n = 0;
        conn[n] = '\0';
        /* Go's http.Error appends the trailing newline. */
        cl = snprintf(body, sizeof(body),
                      "WebSocket protocol violation: Connection header \"%s\" "
                      "does not contain Upgrade\n", conn);
        /* verifyClientRequest also sets Upgrade: websocket on the response. */
        if (http_respond(wsi, 426, "Upgrade: websocket\r\n", "text/plain; charset=utf-8", 1,
                         (const uint8_t *)body, cl, close) < 0)
          return -1;
        return lws_http_transaction_completed(wsi);
      }

    default:
      return 0;
  }
}

/* =========================================================================
 * The LWS protocol callback
 * ========================================================================= */

static int http_cb(struct lws *wsi, enum lws_callback_reasons reason,
                   void *user, void *in, size_t len) {
  struct http_session *s = (struct http_session *)user;

  switch (reason) {
    case LWS_CALLBACK_HTTP:
      /* Headers parsed. Record the method/URI; a POST body arrives in
       * LWS_CALLBACK_HTTP_BODY + HTTP_BODY_COMPLETION; everything else can
       * be dispatched now. */
      {
        char *uri_ptr = NULL;
        int uri_len = 0;
        int m = lws_http_get_uri_and_method(wsi, &uri_ptr, &uri_len);
        s->method = (m == LWSHUMETH_GET) ? HTTP_M_GET
                  : (m == LWSHUMETH_POST) ? HTTP_M_POST : HTTP_M_OTHER;
        s->client_idx = -1;
        s->handled = 0;
        s->body_len = 0;
        if (uri_len > (int)sizeof(s->uri) - 1)
          uri_len = (int)sizeof(s->uri) - 1;
        if (uri_ptr != NULL && uri_len > 0) {
          memcpy(s->uri, uri_ptr, (size_t)uri_len);
          s->uri[uri_len] = '\0';
          s->uri_len = uri_len;
        } else {
          s->uri[0] = '\0';
          s->uri_len = 0;
        }
        s->route = route_for(s->uri, s->uri_len);
        if (s->method != HTTP_M_POST)
          return http_dispatch(wsi, s);
      }
      return 0;

    case LWS_CALLBACK_HTTP_BODY:
      /* Accumulate the request body (bounded; overflow fails loud). */
      if (s->body_len + (uint32_t)len <= CC_HTTP_BODY_MAX) {
        memcpy(s->body + s->body_len, in, len);
        s->body_len += (uint32_t)len;
      } else {
        s->body_len = CC_HTTP_BODY_MAX + 1; /* overflow marker */
      }
      return 0;

    case LWS_CALLBACK_HTTP_BODY_COMPLETION:
      return http_dispatch(wsi, s);

    case LWS_CALLBACK_HTTP_CONFIRM_UPGRADE:
      /* Go's mux only upgrades /subscribe; an upgrade request to any other
       * path gets the normal HTTP handler (e.g. GET /status with Upgrade
       * headers still returns 200 JSON). Return >0 = "responded; complete
       * the transaction without upgrading". Return 0 = upgrade allowed. */
      {
        char *uri_ptr = NULL;
        int uri_len = 0;
        int m = lws_http_get_uri_and_method(wsi, &uri_ptr, &uri_len);
        if (uri_len != 10 || memcmp(uri_ptr, "/subscribe", 10) != 0) {
          struct http_session tmp;
          memset(&tmp, 0, sizeof(tmp));
          tmp.method = (m == LWSHUMETH_GET) ? HTTP_M_GET
                      : (m == LWSHUMETH_POST) ? HTTP_M_POST : HTTP_M_OTHER;
          tmp.client_idx = -1;
          tmp.route = route_for(uri_ptr, uri_len);
          if (uri_len > (int)sizeof(tmp.uri) - 1)
            uri_len = (int)sizeof(tmp.uri) - 1;
          memcpy(tmp.uri, uri_ptr, (size_t)uri_len);
          tmp.uri[uri_len] = '\0';
          tmp.uri_len = uri_len;
          if (http_dispatch(wsi, &tmp) < 0)
            return -1;
          return 1; /* responded; LWS completes the transaction */
        }
        /* Go's Accept requires GET (accept.go verifyClientRequest). */
        if (m != LWSHUMETH_GET) {
          char body[128];
          int bl = snprintf(body, sizeof(body),
                            "WebSocket protocol violation: handshake request "
                            "method is not GET but \"%s\"",
                            m == LWSHUMETH_POST ? "POST" : "?");
          int close = conn_wants_close(wsi);
          if (http_respond(wsi, 405, NULL, "text/plain; charset=utf-8", 1, (const uint8_t *)body,
                           bl, close) < 0)
            return -1;
          return 1;
        }
      }
      return 0; /* upgrade to /subscribe proceeds */

    case LWS_CALLBACK_ESTABLISHED: {
      /* The ws handshake completed. Assign a client slot and register the
       * listener (asm fn) — cc_state_add_listener fires it immediately, so
       * the client receives the current status right after connecting
       * (controller.go:253). Go supports N clients; the port caps at
       * CC_HTTP_MAX_WS_CLIENTS and fails loud beyond. */
      int i;
      for (i = 0; i < CC_HTTP_MAX_WS_CLIENTS; i++) {
        if (g_clients[i].wsi == NULL)
          break;
      }
      if (i == CC_HTTP_MAX_WS_CLIENTS) {
        lws_close_reason(wsi, LWS_CLOSE_STATUS_POLICY_VIOLATION,
                         (unsigned char *)"too many ws clients", 18);
        return -1;
      }
      s->client_idx = i;
      g_clients[i].wsi = wsi;
      g_clients[i].client_idx = i;
      g_clients[i].has_pending = 0;
      g_clients[i].pending_len = 0;
      g_clients[i].deadline_ns = 0;
      if (cc_http_ws_connect(g_controller, i) != 0) {
        /* Go: conn.Close(StatusInternalError, err.Error()) :264. */
        lws_close_reason(wsi, LWS_CLOSE_STATUS_UNEXPECTED_CONDITION,
                         (unsigned char *)"could not add listener", 22);
        return -1;
      }
      return 0;
    }

    case LWS_CALLBACK_SERVER_WRITEABLE:
      if (s->client_idx >= 0 && g_clients[s->client_idx].wsi == wsi) {
        struct cc_http_client *c = &g_clients[s->client_idx];
        if (c->has_pending) {
          uint64_t now = mono_ns();
          c->deadline_ns = now + g_write_timeout_ns;
          if (g_write_timeout_ns == 0 || now >= c->deadline_ns) {
            /* wsjson.Write ctx deadline (main.go:283-288) -> 1011. */
            lws_close_reason(wsi, LWS_CLOSE_STATUS_UNEXPECTED_CONDITION,
                             NULL, 0);
            return -1;
          }
          if (lws_write(wsi, c->pending + LWS_PRE, c->pending_len,
                        LWS_WRITE_TEXT) != (int)c->pending_len) {
            lws_close_reason(wsi, LWS_CLOSE_STATUS_UNEXPECTED_CONDITION,
                             NULL, 0);
            return -1;
          }
          c->has_pending = 0;
          if (g_shutdown)
            lws_set_timeout(wsi, NO_PENDING_TIMEOUT, 0);
        } else if (g_shutdown) {
          /* Shutdown flush done: StatusNormalClosure (main.go:279-281). */
          lws_close_reason(wsi, LWS_CLOSE_STATUS_NORMAL, NULL, 0);
          return -1;
        }
      }
      return 0;

    case LWS_CALLBACK_RECEIVE:
      /* Go calls conn.CloseRead (main.go:249) and never reads application
       * data; control frames are answered by LWS itself. */
      return 0;

    case LWS_CALLBACK_WS_PEER_INITIATED_CLOSE:
      /* Go's CloseRead cancels ctx on a peer close; the writer replies with
       * StatusNormalClosure (1000) (main.go:279-281). */
      lws_close_reason(wsi, LWS_CLOSE_STATUS_NORMAL, NULL, 0);
      return 1;

    case LWS_CALLBACK_CLOSED:
      if (s->client_idx >= 0) {
        int idx = s->client_idx;
        /* Go bounds RemoveListener with 1s (main.go:266-274); the
         * single-threaded port's cc_state_remove_listener is synchronous and
         * trivially within the bound. */
        cc_http_ws_disconnect(g_controller, idx);
        g_clients[idx].wsi = NULL;
        g_clients[idx].has_pending = 0;
        g_clients[idx].pending_len = 0;
        s->client_idx = -1;
      }
      return 0;

    default:
      return 0;
  }
}

static struct lws_protocols protocols[] = {
    {"strimserver", http_cb, sizeof(struct http_session), 4096, 0, NULL, 0},
    LWS_PROTOCOL_LIST_TERM,
};

/* =========================================================================
 * API
 * ========================================================================= */

int cc_http_server_init(const char *addr, void *controller) {
  struct lws_context_creation_info info;
  struct lws_vhost *vhost;
  uint64_t write_timeout_ns;
  int port = 0;
  const char *p;

  if (addr == NULL || controller == NULL)
    return -1;

  /* The write deadline is WEBSOCKET_WRITE_TIMEOUT (envspec.go:105-109); the
   * parsed value comes from the assembly's time.ParseDuration port
   * (cc_env_dur, cc_env.S). 0 = every write immediately times out, exactly
   * like Go's context.WithTimeout(ctx, 0). */
  write_timeout_ns = cc_env_dur("WEBSOCKET_WRITE_TIMEOUT");

  /* addr is Go's ":<port>"; parse the port after ':'. */
  p = addr;
  while (*p != '\0' && *p != ':')
    p++;
  if (*p == ':')
    p++;
  while (*p >= '0' && *p <= '9') {
    if (port > 65535 / 10)
      return -1;
    port = port * 10 + (*p - '0');
    p++;
  }
  if (port <= 0 || port > 65535)
    return -1;

  memset(&info, 0, sizeof(info));
  info.port = port;
  info.protocols = protocols;
  info.options = 0; /* dual-stack like Go's ":port" */
  lws_set_log_level(0, NULL);

  g_ctx = lws_create_context(&info);
  if (g_ctx == NULL)
    return -1;
  vhost = lws_get_vhost_by_name(g_ctx, "default");
  if (vhost == NULL) {
    lws_context_destroy(g_ctx);
    g_ctx = NULL;
    return -1;
  }

  g_controller = controller;
  g_write_timeout_ns = write_timeout_ns;
  g_shutdown = 0;
  memset(g_clients, 0, sizeof(g_clients));
  return 0;
}

void cc_http_shutdown_request(void) {
  g_shutdown = 1;
  if (g_ctx == NULL)
    return;
  lws_cancel_service(g_ctx);

  /* If cc_http_service(-1) is running, it owns the flush (it is the thread
   * inside lws_service); just raise the flag. Otherwise flush here (the
   * cc_main.S flow calls this after the loop exited — srv.Shutdown,
   * main.go:348-355). */
  if (!g_service_loop) {
    int i, pass, live;
    for (i = 0; i < CC_HTTP_MAX_WS_CLIENTS; i++) {
      if (g_clients[i].wsi != NULL)
        lws_callback_on_writable(g_clients[i].wsi);
    }
    for (pass = 0; pass < 256; pass++) {
      live = 0;
      for (i = 0; i < CC_HTTP_MAX_WS_CLIENTS; i++) {
        if (g_clients[i].wsi != NULL)
          live++;
      }
      if (live == 0)
        break;
      lws_service(g_ctx, 0); /* only service while clients remain */
    }
    lws_context_destroy(g_ctx);
    g_ctx = NULL;
  }
}

int cc_http_service(int timeout_ms) {
  if (g_ctx == NULL)
    return -1;

  if (timeout_ms >= 0)
    return lws_service(g_ctx, timeout_ms);

  /* Serve until shutdown requested (Go's srv.ListenAndServe loop, then
   * srv.Shutdown, main.go:332-355). This thread owns the flush + destroy:
   * cc_http_shutdown_request only raised the flag. */
  g_service_loop = 1;
  while (!g_shutdown) {
    if (lws_service(g_ctx, 0) < 0) {
      g_service_loop = 0;
      return -1;
    }
  }
  {
    int i, pass, live;
    for (i = 0; i < CC_HTTP_MAX_WS_CLIENTS; i++) {
      if (g_clients[i].wsi != NULL)
        lws_callback_on_writable(g_clients[i].wsi);
    }
    for (pass = 0; pass < 256; pass++) {
      live = 0;
      for (i = 0; i < CC_HTTP_MAX_WS_CLIENTS; i++) {
        if (g_clients[i].wsi != NULL)
          live++;
      }
      if (live == 0)
        break;
      lws_service(g_ctx, 0); /* only service while clients remain */
    }
    lws_context_destroy(g_ctx);
    g_ctx = NULL;
  }
  g_service_loop = 0;
  return 0;
}

int cc_http_ws_send_text(int client, const uint8_t *bytes, uint32_t len) {
  struct cc_http_client *c;

  if (bytes == NULL || len == 0 || len > CC_HTTP_STATUS_MAX)
    return -1;
  if (client < 0 || client >= CC_HTTP_MAX_WS_CLIENTS)
    return -1;
  c = &g_clients[client];
  if (c->wsi == NULL)
    return -1;

  /* 1-deep drop-oldest/latest-wins (main.go:251-259): if the slot is empty
   * store; else drop the old frame and store the new one. */
  memcpy(c->pending + LWS_PRE, bytes, len);
  c->pending_len = len;
  c->has_pending = 1;
  lws_callback_on_writable(c->wsi);
  return 0;
}

int cc_http_ws_client_count(void) {
  int i, n = 0;
  for (i = 0; i < CC_HTTP_MAX_WS_CLIENTS; i++) {
    if (g_clients[i].wsi != NULL)
      n++;
  }
  return n;
}