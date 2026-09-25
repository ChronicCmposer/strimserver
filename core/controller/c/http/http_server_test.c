/*
 * http_server_test.c — scratch regression test for the Wave 1 http lane.
 *
 * Drives the real server (libmicrohttpd external event loop + wslay) against
 * a STUB controller that implements strim_http_callbacks the way the Core
 * lane will (per http_server.h): it owns all JSON (yyjson), validates wire
 * strings via the controller.h macros, keeps a status snapshot, and pushes
 * status JSON to subscribers through cbs->ws_send (the HTTP lane's slot).
 *
 * NOTE: the stub deliberately does NOT call the Core lane's enum<->string
 * functions (they land in Wave 1 core_lib, still empty); it maps the fixed
 * STRIM_*_STR contract macros directly, so this test links only the headers.
 *
 * Scenarios (all against one server on an ephemeral port, driven by
 * strim_http_server_service on the test thread):
 *   - SHA-1 / base64 RFC vectors (ws_crypto)
 *   - /healthz -> 200 "ok\n"
 *   - unknown route -> 404 "404 page not found\n"
 *   - /status GET -> 200 application/json, exact Go wire bytes
 *   - /status wrong method -> 405
 *   - /event POST 204 + reconcile; /event bad JSON -> 400 "bad json: ...";
 *     /event bad path -> 500; /event wrong method -> 405
 *   - /control POST 204
 *   - /subscribe websocket: handshake accept, initial status push,
 *     notify push, client close -> server close 1000, unsubscribe
 *   - /subscribe non-upgrade GET -> 426; wrong method -> 405
 *
 * License: project code (see LICENSE). No GPL.
 */

#include "controller.h"
#include "http_server.h"
#include "internal.h"
#include "ws_crypto.h"

#include <wslay/wslay.h>

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include <yyjson.h>

/* =========================================================================
 * Test harness
 * ========================================================================= */

static int failures = 0;

#define CHECK(cond, ...)                                                \
  do                                                                    \
  {                                                                     \
    if (!(cond))                                                        \
    {                                                                   \
      fprintf(stderr, "FAIL %s:%d: ", __func__, __LINE__);              \
      fprintf(stderr, __VA_ARGS__);                                     \
      fprintf(stderr, "\n");                                            \
      failures++;                                                       \
    }                                                                   \
  } while (0)

#define CHECK_STREQ(a, b, ...)                                          \
  do                                                                    \
  {                                                                     \
    if ((a) == NULL || (b) == NULL || strcmp((a), (b)) != 0)            \
    {                                                                   \
      fprintf(stderr, "FAIL %s:%d: ", __func__, __LINE__);              \
      fprintf(stderr, __VA_ARGS__);                                     \
      fprintf(stderr, " (got \"%s\", want \"%s\")\n",                   \
              (a) ? (a) : "(null)", (b) ? (b) : "(null)");              \
      failures++;                                                       \
    }                                                                   \
  } while (0)

/* =========================================================================
 * Wire-string helpers (contract macros only; the Core lane's functions are
 * not linked yet — they live in the parallel Wave 1 core_lib)
 * ========================================================================= */

static const char *path_status_str(strim_path_status v) {
  switch (v)
  {
    case STRIM_PATH_UNKNOWN:
      return STRIM_PATH_UNKNOWN_STR;
    case STRIM_PATH_READY:
      return STRIM_PATH_READY_STR;
    case STRIM_PATH_NOT_READY:
      return STRIM_PATH_NOT_READY_STR;
    default:
      return NULL;
  }
}

static int path_status_from_str(const char *s, strim_path_status *out) {
  if (s == NULL || out == NULL)
    return -1;
  if (strcmp(s, STRIM_PATH_UNKNOWN_STR) == 0)
    *out = STRIM_PATH_UNKNOWN;
  else if (strcmp(s, STRIM_PATH_READY_STR) == 0)
    *out = STRIM_PATH_READY;
  else if (strcmp(s, STRIM_PATH_NOT_READY_STR) == 0)
    *out = STRIM_PATH_NOT_READY;
  else
    return -1;
  return 0;
}

static const char *path_name_str(strim_path_name v) {
  switch (v)
  {
    case STRIM_PATH_INGRESS0:
      return STRIM_PATH_INGRESS0_STR;
    case STRIM_PATH_NORMALIZED:
      return STRIM_PATH_NORMALIZED_STR;
    default:
      return NULL;
  }
}

static int path_name_from_str(const char *s, strim_path_name *out) {
  if (s == NULL || out == NULL)
    return -1;
  if (strcmp(s, STRIM_PATH_INGRESS0_STR) == 0)
    *out = STRIM_PATH_INGRESS0;
  else if (strcmp(s, STRIM_PATH_NORMALIZED_STR) == 0)
    *out = STRIM_PATH_NORMALIZED;
  else
    return -1;
  return 0;
}

static const char *stage_state_str(strim_stage_state v) {
  switch (v)
  {
    case STRIM_STAGE_STOPPED:
      return STRIM_STAGE_STOPPED_STR;
    case STRIM_STAGE_RUNNING:
      return STRIM_STAGE_RUNNING_STR;
    case STRIM_STAGE_NO_TARGET:
      return ""; /* never sent on the wire */
    default:
      return NULL;
  }
}

static const char *stage_name_str(strim_stage_name v) {
  switch (v)
  {
    case STRIM_STAGE_MEDIA_MTX:
      return STRIM_STAGE_MEDIA_MTX_STR;
    case STRIM_STAGE_NORMALIZE:
      return STRIM_STAGE_NORMALIZE_STR;
    case STRIM_STAGE_SCALE_AND_EGRESS:
      return STRIM_STAGE_SCALE_AND_EGRESS_STR;
    case STRIM_STAGE_SINGLE_STAGE_EGRESS:
      return STRIM_STAGE_SINGLE_STAGE_EGRESS_STR;
    default:
      return NULL;
  }
}

static int component_from_str(const char *s, strim_control_component *out) {
  if (s == NULL || out == NULL)
    return -1;
  if (strcmp(s, STRIM_COMPONENT_EGRESS_STR) == 0)
    *out = STRIM_COMPONENT_EGRESS;
  else
    return -1;
  return 0;
}

static int action_from_str(const char *s, strim_control_action *out) {
  if (s == NULL || out == NULL)
    return -1;
  if (strcmp(s, STRIM_ACTION_START_STR) == 0)
    *out = STRIM_ACTION_START;
  else if (strcmp(s, STRIM_ACTION_STOP_STR) == 0)
    *out = STRIM_ACTION_STOP;
  else
    return -1;
  return 0;
}

/* =========================================================================
 * Stub controller (plays the Core lane: parses/serializes JSON via yyjson)
 * ========================================================================= */

struct stub_controller {
  strim_path_status paths[STRIM_PATH_NAME_COUNT];
  strim_stage_status stages[STRIM_STAGE_NAME_COUNT];
  const strim_http_callbacks *cbs;
  void *userdata;
  int reconcile_calls;
  int subscribed[STRIM_HTTP_MAX_WS_CLIENTS];
  int subscribe_calls;
  int unsubscribe_calls;
};

static struct stub_controller g_stub;

static void stub_reset(struct stub_controller *stub) {
  memset(stub, 0, sizeof(*stub));
  stub->paths[STRIM_PATH_INGRESS0] = STRIM_PATH_UNKNOWN;
  stub->paths[STRIM_PATH_NORMALIZED] = STRIM_PATH_UNKNOWN;
  stub->stages[STRIM_STAGE_MEDIA_MTX].desired = STRIM_STAGE_RUNNING;
  stub->stages[STRIM_STAGE_MEDIA_MTX].actual = STRIM_STAGE_STOPPED;
}

/* Serialize the stub snapshot exactly like Go's json.NewEncoder(ControllerStatus)
 * (controller.go:46-49): {"paths":{...},"stages":{...}} + '\n'. */
static void stub_serialize(struct stub_controller *stub, uint8_t *out,
                           size_t cap, size_t *out_len) {
  yyjson_mut_doc *doc;
  yyjson_mut_val *root;
  yyjson_mut_val *paths;
  yyjson_mut_val *stages;
  size_t len;
  char *json;
  int i;

  doc = yyjson_mut_doc_new(NULL);
  root = yyjson_mut_obj(doc);
  yyjson_mut_doc_set_root(doc, root);
  paths = yyjson_mut_obj_add_obj(doc, root, "paths");
  stages = yyjson_mut_obj_add_obj(doc, root, "stages");

  for (i = 0; i < STRIM_PATH_NAME_COUNT; i++)
    yyjson_mut_obj_add_str(doc, paths, path_name_str((strim_path_name) i),
                           path_status_str(stub->paths[i]));
  for (i = 0; i < STRIM_STAGE_NAME_COUNT; i++)
  {
    yyjson_mut_val *ss = yyjson_mut_obj_add_obj(
        doc, stages, stage_name_str((strim_stage_name) i));
    yyjson_mut_obj_add_str(doc, ss, "desired",
                           stage_state_str(stub->stages[i].desired));
    yyjson_mut_obj_add_str(doc, ss, "actual",
                           stage_state_str(stub->stages[i].actual));
  }

  json = yyjson_mut_write(doc, 0, &len);
  *out_len = 0;
  if (json != NULL)
  {
    if (len + 1 <= cap) /* Go's Encoder.Encode appends '\n' */
    {
      memcpy(out, json, len);
      out[len] = '\n';
      *out_len = len + 1;
    }
    free(json);
  }
  yyjson_mut_doc_free(doc);
}

static void stub_push_all(struct stub_controller *stub) {
  uint8_t json[STRIM_HTTP_STATUS_MAX];
  size_t json_len = 0;
  int i;

  stub_serialize(stub, json, sizeof(json), &json_len);
  for (i = 0; i < STRIM_HTTP_MAX_WS_CLIENTS; i++)
  {
    if (stub->subscribed[i])
      stub->cbs->ws_send(stub->userdata, i, json, json_len);
  }
}

/* --- the seven callbacks ----------------------------------------------- */

static int stub_handle_event(void *userdata, const uint8_t *body, size_t len,
                             char *err, size_t err_cap) {
  struct stub_controller *stub = userdata;
  yyjson_doc *doc;
  yyjson_val *root;
  const char *path_s;
  const char *status_s;
  char path_buf[64];
  char status_buf[64];
  strim_path_name path;
  strim_path_status status;

  doc = yyjson_read_opts((char *) (void *) (size_t) body, len, 0, NULL, NULL);
  if (doc == NULL)
  {
    snprintf(err, err_cap, "invalid JSON");
    return STRIM_HTTP_ERR_BADJSON;
  }
  root = yyjson_doc_get_root(doc);
  path_s = yyjson_get_str(yyjson_obj_get(root, "path"));
  status_s = yyjson_get_str(yyjson_obj_get(root, "status"));
  if (path_s == NULL || status_s == NULL)
  {
    /* Wrong shape (missing / non-string field): json.Decode would fail ->
     * 400 bad json (Go postJSON main.go:376-379). */
    yyjson_doc_free(doc);
    snprintf(err, err_cap, "invalid path event");
    return STRIM_HTTP_ERR_BADJSON;
  }
  /* Copy before freeing the doc: the strings point into its allocation. */
  snprintf(path_buf, sizeof(path_buf), "%s", path_s);
  snprintf(status_buf, sizeof(status_buf), "%s", status_s);
  yyjson_doc_free(doc);

  if (path_name_from_str(path_buf, &path) != 0
      || path_status_from_str(status_buf, &status) != 0)
  {
    /* Decodes fine but the handler rejects it: handlePathEvent's
     * validation -> 500 (Go postJSON main.go:381-382). */
    snprintf(err, err_cap, "invalid path name: %s", path_buf);
    return -1;
  }
  stub->paths[path] = status;
  return 0;
}

static int stub_handle_control(void *userdata, const uint8_t *body, size_t len,
                               char *err, size_t err_cap) {
  yyjson_doc *doc;
  yyjson_val *root;
  const char *component_s;
  const char *action_s;
  char component_buf[64];
  char action_buf[64];
  strim_control_component component;
  strim_control_action action;

  (void) userdata;

  doc = yyjson_read_opts((char *) (void *) (size_t) body, len, 0, NULL, NULL);
  if (doc == NULL)
  {
    snprintf(err, err_cap, "invalid JSON");
    return STRIM_HTTP_ERR_BADJSON;
  }
  root = yyjson_doc_get_root(doc);
  component_s = yyjson_get_str(yyjson_obj_get(root, "component"));
  action_s = yyjson_get_str(yyjson_obj_get(root, "action"));
  if (component_s == NULL || action_s == NULL)
  {
    yyjson_doc_free(doc);
    snprintf(err, err_cap, "invalid control command");
    return STRIM_HTTP_ERR_BADJSON;
  }
  /* Copy before freeing the doc: the strings point into its allocation. */
  snprintf(component_buf, sizeof(component_buf), "%s", component_s);
  snprintf(action_buf, sizeof(action_buf), "%s", action_s);
  yyjson_doc_free(doc);

  if (component_from_str(component_buf, &component) != 0
      || action_from_str(action_buf, &action) != 0)
  {
    /* Decodes fine but no such command: handleControl's lookup ->
     * 500 (Go postJSON main.go:381-382). */
    snprintf(err, err_cap, "control not implemented: %s", component_buf);
    return -1;
  }
  return 0;
}

static int stub_handle_status(void *userdata, uint8_t *out, size_t cap,
                              size_t *out_len) {
  struct stub_controller *stub = userdata;
  stub_serialize(stub, out, cap, out_len);
  return (*out_len > 0) ? 0 : -1;
}

static void stub_request_reconcile(void *userdata) {
  struct stub_controller *stub = userdata;
  stub->reconcile_calls++;
}

static int stub_ws_subscribe(void *userdata, int client_idx) {
  struct stub_controller *stub = userdata;
  uint8_t json[STRIM_HTTP_STATUS_MAX];
  size_t json_len = 0;

  if (client_idx < 0 || client_idx >= STRIM_HTTP_MAX_WS_CLIENTS)
    return -1;
  stub->subscribed[client_idx] = 1;
  stub->subscribe_calls++;
  /* Go's handleAddListener fires the listener immediately with the current
   * status (controller.go:253) — the client receives it right after
   * connecting. */
  stub_serialize(stub, json, sizeof(json), &json_len);
  stub->cbs->ws_send(stub->userdata, client_idx, json, json_len);
  return 0;
}

static int stub_ws_unsubscribe(void *userdata, int client_idx) {
  struct stub_controller *stub = userdata;

  if (client_idx < 0 || client_idx >= STRIM_HTTP_MAX_WS_CLIENTS)
    return -1;
  stub->subscribed[client_idx] = 0;
  stub->unsubscribe_calls++;
  return 0;
}

static void stub_fill_callbacks(strim_http_callbacks *cbs) {
  memset(cbs, 0, sizeof(*cbs));
  cbs->handle_event = stub_handle_event;
  cbs->handle_control = stub_handle_control;
  cbs->handle_status = stub_handle_status;
  cbs->request_reconcile = stub_request_reconcile;
  cbs->ws_subscribe = stub_ws_subscribe;
  cbs->ws_unsubscribe = stub_ws_unsubscribe;
  cbs->ws_send = strim_http_ws_send; /* the HTTP lane's slot (internal.h) */
}

/* =========================================================================
 * Raw-socket HTTP client
 * ========================================================================= */

static int set_nonblocking(int fd);

static int tcp_connect(uint16_t port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in sa;

  if (fd < 0)
    return -1;
  memset(&sa, 0, sizeof(sa));
  sa.sin_family = AF_INET;
  sa.sin_port = htons(port);
  if (inet_pton(AF_INET, "127.0.0.1", &sa.sin_addr) != 1
      || connect(fd, (struct sockaddr *) &sa, sizeof(sa)) != 0)
  {
    close(fd);
    return -1;
  }
  return fd;
}

/* One non-blocking server pass (the server runs on the test thread in
 * external event-loop mode; nothing is served without these calls). */
static void drive(struct strim_http_server *srv) {
  if (srv != NULL)
    strim_http_server_service(srv, 0);
}

/* Send one HTTP/1.1 request (Connection: close) and read the full response,
 * pumping the server's external event loop between socket operations.
 * Returns 0 + resp on success. */
static int http_exchange(struct strim_http_server *srv, uint16_t port,
                         const char *method, const char *path,
                         const char *extra_headers, const char *body,
                         char *resp, size_t resp_cap) {
  int fd;
  char req[4096];
  int req_len;
  size_t off;
  size_t got;
  int i;

  fd = tcp_connect(port);
  if (fd < 0)
    return -1;
  if (set_nonblocking(fd) != 0)
  {
    close(fd);
    return -1;
  }

  req_len = snprintf(req, sizeof(req),
                     "%s %s HTTP/1.1\r\n"
                     "Host: localhost\r\n"
                     "%s"
                     "Connection: close\r\n"
                     "Content-Length: %zu\r\n"
                     "\r\n"
                     "%s",
                     method, path, extra_headers != NULL ? extra_headers : "",
                     body != NULL ? strlen(body) : 0u,
                     body != NULL ? body : "");

  off = 0;
  while (off < (size_t) req_len)
  {
    ssize_t n = send(fd, req + off, (size_t) req_len - off, 0);
    if (n > 0)
      off += (size_t) n;
    else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
    {
      drive(srv);
      usleep(1000);
    }
    else
    {
      close(fd);
      return -1;
    }
  }

  got = 0;
  for (i = 0; i < 2000 && got + 1 < resp_cap; i++)
  {
    struct pollfd pfd;
    int pr;

    drive(srv);
    pfd.fd = fd;
    pfd.events = POLLIN;
    pr = poll(&pfd, 1, 5);
    if (pr > 0 && (pfd.revents & (POLLIN | POLLHUP | POLLERR)))
    {
      ssize_t n = recv(fd, resp + got, resp_cap - 1 - got, 0);
      if (n <= 0)
        break; /* EOF (Connection: close) or error: response complete */
      got += (size_t) n;
    }
    usleep(1000);
  }
  resp[got] = '\0';
  close(fd);
  return 0;
}

/* Parse the status code from an HTTP/1.1 response. */
static int resp_status(const char *resp) {
  int code = 0;
  if (resp == NULL || sscanf(resp, "HTTP/1.1 %d", &code) != 1)
    return 0;
  return code;
}

static const char *resp_body(const char *resp, char *buf, size_t cap) {
  const char *p = strstr(resp, "\r\n\r\n");
  size_t n;

  if (p == NULL)
  {
    buf[0] = '\0';
    return buf;
  }
  p += 4;
  n = strlen(p);
  if (n >= cap)
    n = cap - 1;
  memcpy(buf, p, n);
  buf[n] = '\0';
  return buf;
}

static int resp_has_header(const char *resp, const char *name,
                           const char *value) {
  char pat[512];
  const char *body_start;
  const char *p;

  body_start = strstr(resp, "\r\n\r\n");
  if (body_start == NULL)
    return 0;
  snprintf(pat, sizeof(pat), "%s: %s", name, value);
  p = strstr(resp, pat); /* the headers we add are exact-case */
  return p != NULL && p < body_start;
}

/* Assert the raw response's Connection header is exactly one line whose
 * trimmed value is exactly "Upgrade" (single token, no duplicate).
 *
 * MHD_create_response_for_upgrade() already emits "Connection: Upgrade";
 * dispatch_subscribe() used to add its own copy, which MHD merged into
 * "Connection: Upgrade, Upgrade" on the wire. This parses the raw bytes
 * (resp_has_header is a substring match and would let that slip through)
 * and returns 1 only for the exact single-token form: absent, duplicated
 * (one line with two values or two header lines), or any other value all
 * return 0. */
static int resp_connection_is_upgrade(const char *resp) {
  const char *body_start;
  const char *p;
  int found = 0;

  body_start = strstr(resp, "\r\n\r\n");
  if (body_start == NULL)
    return 0;

  p = resp;
  while (p < body_start)
  {
    const char *line_end = strstr(p, "\r\n");
    const char *colon;

    if (line_end == NULL || line_end > body_start)
      line_end = body_start;
    if (line_end == p) /* skip the blank line (never reached normally) */
    {
      p = line_end + 2;
      continue;
    }

    colon = memchr(p, ':', (size_t) (line_end - p));
    if (colon != NULL && (size_t) (colon - p) == sizeof("Connection") - 1
        && memcmp(p, "Connection", sizeof("Connection") - 1) == 0)
    {
      const char *val = colon + 1;
      size_t val_len;

      while (val < line_end && (*val == ' ' || *val == '\t'))
        val++;
      val_len = (size_t) (line_end - val);
      while (val_len > 0
             && (val[val_len - 1] == ' ' || val[val_len - 1] == '\t'))
        val_len--;

      found++;
      if (val_len != sizeof("Upgrade") - 1
          || memcmp(val, "Upgrade", sizeof("Upgrade") - 1) != 0)
        return 0; /* present, but not exactly "Upgrade" */
    }
    p = line_end + 2;
  }
  return found == 1;
}

/* =========================================================================
 * WebSocket client (wslay client context over the upgraded socket)
 * ========================================================================= */

struct ws_client_ctx {
  int fd;
  wslay_event_context_ptr wctx;
  int status_frames;
  int close_received;
  uint8_t last_msg[STRIM_HTTP_STATUS_MAX];
  size_t last_msg_len;
};

static ssize_t ws_cli_recv_cb(wslay_event_context_ptr ctx, uint8_t *buf,
                              size_t len, int flags, void *user_data) {
  struct ws_client_ctx *cl = user_data;
  ssize_t r;

  (void) ctx;
  (void) flags;

  r = recv(cl->fd, buf, len, 0);
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

static ssize_t ws_cli_send_cb(wslay_event_context_ptr ctx, const uint8_t *data,
                              size_t len, int flags, void *user_data) {
  struct ws_client_ctx *cl = user_data;
  ssize_t r;

  (void) ctx;
  (void) flags;

  r = send(cl->fd, data, len, MSG_NOSIGNAL);
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

static int ws_cli_genmask_cb(wslay_event_context_ptr ctx, uint8_t *buf,
                             size_t len, void *user_data) {
  static unsigned int seed = 0x20260923u;
  size_t i;

  (void) ctx;
  (void) user_data;
  for (i = 0; i < len; i++)
  {
    seed = seed * 1103515245u + 12345u;
    buf[i] = (uint8_t) (seed >> 16);
  }
  return 0;
}

static void ws_cli_on_msg_recv(wslay_event_context_ptr ctx,
                               const struct wslay_event_on_msg_recv_arg *arg,
                               void *user_data) {
  struct ws_client_ctx *cl = user_data;

  (void) ctx;
  if (arg->opcode == WSLAY_TEXT_FRAME)
  {
    cl->status_frames++;
    cl->last_msg_len = arg->msg_length < sizeof(cl->last_msg)
                           ? arg->msg_length
                           : sizeof(cl->last_msg);
    memcpy(cl->last_msg, arg->msg, cl->last_msg_len);
  }
  else if (arg->opcode == WSLAY_CONNECTION_CLOSE)
  {
    cl->close_received = 1;
  }
}

static int set_nonblocking(int fd) {
  int fl = fcntl(fd, F_GETFL, 0);
  if (fl == -1)
    return -1;
  return fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

/* Read the server's 101 response headers (until the blank line), pumping
 * the server's event loop. The fd must be non-blocking. */
static int ws_read_handshake_response(struct strim_http_server *srv, int fd,
                                      char *buf, size_t cap) {
  size_t got = 0;
  int i;

  for (i = 0; i < 2000 && got + 1 < cap; i++)
  {
    struct pollfd pfd;
    int pr;

    drive(srv);
    pfd.fd = fd;
    pfd.events = POLLIN;
    pr = poll(&pfd, 1, 5);
    if (pr > 0 && (pfd.revents & (POLLIN | POLLHUP | POLLERR)))
    {
      ssize_t n = recv(fd, buf + got, 1, 0);
      if (n <= 0)
        break;
      got += (size_t) n;
      if (got >= 4 && memcmp(buf + got - 4, "\r\n\r\n", 4) == 0)
      {
        buf[got] = '\0';
        return 1;
      }
    }
    usleep(1000);
  }
  buf[got] = '\0';
  return 0;
}

/* Connect + handshake + wslay client init. Returns 0 on success. */
static int ws_client_open(struct ws_client_ctx *cl,
                          struct strim_http_server *srv, uint16_t port) {
  char req[1024];
  char resp[4096];
  struct wslay_event_callbacks wscb;
  int fd;

  memset(cl, 0, sizeof(*cl));

  fd = tcp_connect(port);
  if (fd < 0)
    return -1;
  cl->fd = fd;
  if (set_nonblocking(fd) != 0)
    goto fail;

  snprintf(req, sizeof(req),
           "GET /subscribe HTTP/1.1\r\n"
           "Host: localhost\r\n"
           "Upgrade: websocket\r\n"
           "Connection: Upgrade\r\n"
           "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
           "Sec-WebSocket-Version: 13\r\n"
           "\r\n");
  {
    size_t off = 0;
    while (off < strlen(req))
    {
      ssize_t n = send(fd, req + off, strlen(req) - off, 0);
      if (n > 0)
        off += (size_t) n;
      else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
      {
        drive(srv);
        usleep(1000);
      }
      else
        goto fail;
    }
  }

  if (!ws_read_handshake_response(srv, fd, resp, sizeof(resp)))
    goto fail;

  /* RFC 6455 example: this key yields exactly this accept value. */
  {
    int before = failures;

    CHECK(resp_status(resp) == 101, "ws handshake status (resp:\n%s\n)", resp);
    /* MHD_create_response_for_upgrade already emits "Connection: Upgrade";
     * dispatch_subscribe() must not add a second copy (the wire would read
     * "Connection: Upgrade, Upgrade"). Assert the exact raw header. */
    CHECK(resp_connection_is_upgrade(resp),
          "ws handshake Connection header must be exactly one "
          "\"Connection: Upgrade\" (resp:\n%s\n)", resp);
    CHECK(resp_has_header(resp, "Sec-WebSocket-Accept",
                          "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="),
          "ws handshake Sec-WebSocket-Accept (resp:\n%s\n)", resp);
    if (failures != before)
    {
      fprintf(stderr, "ws handshake response:\n%s\n", resp);
      goto fail;
    }
  }

  memset(&wscb, 0, sizeof(wscb));
  wscb.recv_callback = ws_cli_recv_cb;
  wscb.send_callback = ws_cli_send_cb;
  wscb.genmask_callback = ws_cli_genmask_cb;
  wscb.on_msg_recv_callback = ws_cli_on_msg_recv;
  if (wslay_event_context_client_init(&cl->wctx, &wscb, cl) != 0)
    goto fail;
  return 0;

fail:
  close(fd);
  cl->fd = -1;
  cl->wctx = NULL;
  return -1;
}

/* Pump until the server closes the TCP connection (recv returns 0). */
static int wait_eof(struct strim_http_server *srv, int fd) {
  int i;
  for (i = 0; i < 2000; i++)
  {
    struct pollfd pfd;
    int pr;

    drive(srv);
    pfd.fd = fd;
    pfd.events = POLLIN;
    pr = poll(&pfd, 1, 5);
    if (pr > 0 && (pfd.revents & (POLLIN | POLLHUP | POLLERR)))
    {
      char tmp[16];
      ssize_t n = recv(fd, tmp, sizeof(tmp), 0);
      if (n == 0)
        return 1; /* EOF */
      if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK)
        return 1; /* socket error: treat as closed */
    }
    usleep(1000);
  }
  return 0;
}

static void ws_client_close(struct ws_client_ctx *cl) {
  if (cl->wctx != NULL)
    wslay_event_context_free(cl->wctx);
  if (cl->fd >= 0)
    close(cl->fd);
  cl->fd = -1;
  cl->wctx = NULL;
}

/* Pump the server (one non-blocking pass) and the client's wslay context. */
static void pump(struct strim_http_server *srv, struct ws_client_ctx *cl,
                 int rounds) {
  int i;
  for (i = 0; i < rounds; i++)
  {
    if (srv != NULL)
      strim_http_server_service(srv, 0);
    if (cl != NULL && cl->wctx != NULL)
    {
      (void) wslay_event_recv(cl->wctx);
      (void) wslay_event_send(cl->wctx);
    }
    usleep(1000);
  }
}

/* =========================================================================
 * ws_crypto unit vectors
 * ========================================================================= */

static void test_sha1(void) {
  static const struct
  {
    const char *in;
    const char *hex;
  } vectors[] = {
    { "", "da39a3ee5e6b4b0d3255bfef95601890afd80709" },
    { "abc", "a9993e364706816aba3e25717850c26c9cd0d89d" },
    { "The quick brown fox jumps over the lazy dog",
      "2fd4e1c67a2d28fced849ee1bb76e7391b93eb12" },
  };
  static const char hexdig[] = "0123456789abcdef";
  size_t i;

  for (i = 0; i < sizeof(vectors) / sizeof(vectors[0]); i++)
  {
    uint8_t digest[20];
    char got[41];
    int j;

    strim_sha1((const uint8_t *) vectors[i].in, strlen(vectors[i].in), digest);
    for (j = 0; j < 20; j++)
    {
      got[j * 2] = hexdig[digest[j] >> 4];
      got[j * 2 + 1] = hexdig[digest[j] & 0x0f];
    }
    got[40] = '\0';
    CHECK_STREQ(got, vectors[i].hex, "sha1(%s)", vectors[i].in);
  }
}

static void test_base64(void) {
  static const struct
  {
    const uint8_t *in;
    size_t in_len;
    const char *out;
  } vectors[] = {
    { (const uint8_t *) "abc", 3, "YWJj" },
    { (const uint8_t *) "", 0, "" },
    { (const uint8_t *) "\xff\xff", 2, "//8=" },
    { (const uint8_t *) "\x00\x00", 2, "AAA=" },
    { (const uint8_t *) "foobar", 6, "Zm9vYmFy" },
  };
  size_t i;

  for (i = 0; i < sizeof(vectors) / sizeof(vectors[0]); i++)
  {
    char got[64];
    size_t got_len = strim_base64_encode(vectors[i].in, vectors[i].in_len, got,
                                         sizeof(got));
    CHECK(got_len == strlen(vectors[i].out), "b64 encode len %zu != %zu",
          got_len, strlen(vectors[i].out));
    CHECK_STREQ(got, vectors[i].out, "b64 encode");
  }

  {
    /* RFC 6455 accept = base64(sha1(key + GUID)). */
    const char key[] = "dGhlIHNhbXBsZSBub25jZQ==";
    const char guid[] = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    uint8_t hb[128];
    size_t hb_len = strlen(key);
    uint8_t digest[20];
    char accept[32];

    memcpy(hb, key, hb_len);
    memcpy(hb + hb_len, guid, sizeof(guid) - 1);
    hb_len += sizeof(guid) - 1;
    strim_sha1(hb, hb_len, digest);
    strim_base64_encode(digest, 20, accept, sizeof(accept));
    CHECK_STREQ(accept, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "rfc6455 accept");
  }

  {
    /* Key validation path: decode must yield exactly 16 bytes. */
    uint8_t out[16];
    size_t out_len = 0;
    CHECK(strim_base64_decode("dGhlIHNhbXBsZSBub25jZQ==", 24, out, sizeof(out),
                              &out_len) == 0
              && out_len == 16,
          "b64 decode 16-byte key");
    CHECK(strim_base64_decode("!!!!", 4, out, sizeof(out), &out_len) != 0,
          "b64 decode rejects bad alphabet");
    /* A 1-byte key decodes to 1 byte, proving the 16-byte requirement
     * would reject it. */
    CHECK(strim_base64_decode("AA==", 4, out, sizeof(out), &out_len) == 0
              && out_len == 1,
          "b64 decode 1-byte key (got %zu)", out_len);
  }
}

/* =========================================================================
 * HTTP endpoint scenarios
 * ========================================================================= */

static void test_healthz(struct strim_http_server *srv) {
  char resp[2048];
  char body[1024];

  CHECK(http_exchange(srv, strim_http_server_bound_port(srv), "GET", "/healthz", NULL,
                      NULL, resp, sizeof(resp)) == 0,
        "healthz exchange");
  CHECK(resp_status(resp) == 200, "healthz status");
  CHECK_STREQ(resp_body(resp, body, sizeof(body)), "ok\n", "healthz body");
}

static void test_unknown_route(struct strim_http_server *srv) {
  char resp[2048];
  char body[1024];

  CHECK(http_exchange(srv, strim_http_server_bound_port(srv), "GET", "/nope", NULL,
                      NULL, resp, sizeof(resp)) == 0,
        "unknown exchange");
  CHECK(resp_status(resp) == 404, "unknown status");
  CHECK_STREQ(resp_body(resp, body, sizeof(body)), "404 page not found\n",
              "unknown body");
}

static void test_status(struct strim_http_server *srv) {
  char resp[4096];
  char body[2048];
  static const char expected[] =
      "{\"paths\":{\"ingress0\":\"unknown\",\"normalized\":\"unknown\"},"
      "\"stages\":{\"mediamtx\":{\"desired\":\"running\","
      "\"actual\":\"stopped\"},\"normalize\":{\"desired\":\"stopped\","
      "\"actual\":\"stopped\"},\"scale_and_egress\":{\"desired\":\"stopped\","
      "\"actual\":\"stopped\"},\"single_stage_egress\":"
      "{\"desired\":\"stopped\",\"actual\":\"stopped\"}}}\n";

  CHECK(http_exchange(srv, strim_http_server_bound_port(srv), "GET", "/status", NULL,
                      NULL, resp, sizeof(resp)) == 0,
        "status exchange");
  CHECK(resp_status(resp) == 200, "status status");
  CHECK(resp_has_header(resp, "Content-Type", "application/json"),
        "status content-type");
  CHECK_STREQ(resp_body(resp, body, sizeof(body)), expected, "status body");
}

static void test_status_wrong_method(struct strim_http_server *srv) {
  char resp[2048];
  char body[1024];

  CHECK(http_exchange(srv, strim_http_server_bound_port(srv), "POST", "/status", NULL,
                      NULL, resp, sizeof(resp)) == 0,
        "status POST exchange");
  CHECK(resp_status(resp) == 405, "status POST status");
  CHECK_STREQ(resp_body(resp, body, sizeof(body)), "method not allowed\n",
              "status POST body");
}

static void test_event_ok(struct strim_http_server *srv,
                          struct stub_controller *stub) {
  char resp[2048];
  int rc_before = stub->reconcile_calls;

  CHECK(http_exchange(srv, strim_http_server_bound_port(srv), "POST", "/event", NULL,
                      "{\"path\":\"ingress0\",\"status\":\"ready\"}", resp,
                      sizeof(resp)) == 0,
        "event exchange");
  CHECK(resp_status(resp) == 204, "event status");
  CHECK(stub->reconcile_calls == rc_before + 1, "event reconcile fired");
  CHECK(stub->paths[STRIM_PATH_INGRESS0] == STRIM_PATH_READY,
        "event applied to stub");
}

static void test_event_bad_json(struct strim_http_server *srv) {
  char resp[2048];
  char body[1024];

  CHECK(http_exchange(srv, strim_http_server_bound_port(srv), "POST", "/event", NULL,
                      "{not json", resp, sizeof(resp)) == 0,
        "event bad-json exchange");
  CHECK(resp_status(resp) == 400, "event bad-json status");
  CHECK(strncmp(resp_body(resp, body, sizeof(body)), "bad json: ", 10) == 0,
        "event bad-json body prefix: %s", body);
}

static void test_event_bad_path(struct strim_http_server *srv) {
  char resp[2048];
  char body[1024];

  CHECK(http_exchange(srv, strim_http_server_bound_port(srv), "POST", "/event", NULL,
                      "{\"path\":\"bogus\",\"status\":\"ready\"}", resp,
                      sizeof(resp)) == 0,
        "event bad-path exchange");
  CHECK(resp_status(resp) == 500, "event bad-path status");
  CHECK(strstr(resp_body(resp, body, sizeof(body)), "invalid path name") != NULL,
        "event bad-path body: %s", body);
}

static void test_event_wrong_method(struct strim_http_server *srv) {
  char resp[2048];
  char body[1024];

  CHECK(http_exchange(srv, strim_http_server_bound_port(srv), "GET", "/event", NULL,
                      NULL, resp, sizeof(resp)) == 0,
        "event GET exchange");
  CHECK(resp_status(resp) == 405, "event GET status");
  CHECK_STREQ(resp_body(resp, body, sizeof(body)), "method not allowed\n",
              "event GET body");
}

static void test_control_ok(struct strim_http_server *srv,
                            struct stub_controller *stub) {
  char resp[2048];
  int rc_before = stub->reconcile_calls;

  CHECK(http_exchange(srv, strim_http_server_bound_port(srv), "POST", "/control",
                      NULL, "{\"component\":\"egress\",\"action\":\"stop\"}",
                      resp, sizeof(resp)) == 0,
        "control exchange");
  CHECK(resp_status(resp) == 204, "control status (resp:\n%s\n)", resp);
  CHECK(stub->reconcile_calls == rc_before + 1,
        "control reconcile fired (reconcile=%d before=%d)",
        stub->reconcile_calls, rc_before);
}

static void test_status_after_event(struct strim_http_server *srv) {
  char resp[4096];
  char body[2048];

  /* The stub stored ingress0=ready in test_event_ok. */
  CHECK(http_exchange(srv, strim_http_server_bound_port(srv), "GET", "/status", NULL,
                      NULL, resp, sizeof(resp)) == 0,
        "status-after-event exchange");
  CHECK(strstr(resp_body(resp, body, sizeof(body)),
               "\"ingress0\":\"ready\"") != NULL,
        "status reflects event: %s", body);
}

/* =========================================================================
 * WebSocket scenarios
 * ========================================================================= */

static void test_ws_cycle(struct strim_http_server *srv,
                          struct stub_controller *stub) {
  struct ws_client_ctx cl;
  int subs_before = stub->subscribe_calls;

  CHECK(ws_client_open(&cl, srv, (uint16_t) strim_http_server_bound_port(srv))
            == 0,
        "ws open");
  if (cl.fd < 0)
    return;

  /* Frame 1: the initial status pushed synchronously by ws_subscribe
   * (Go handleAddListener controller.go:253). */
  pump(srv, &cl, 200);
  CHECK(cl.status_frames >= 1, "ws initial status frame");
  CHECK(cl.last_msg_len > 0 && strstr((char *) cl.last_msg, "\"paths\"") != NULL,
        "ws initial frame is status JSON");

  /* Change the stub state and push (Go notifyListeners on a status change). */
  stub->paths[STRIM_PATH_INGRESS0] = STRIM_PATH_READY;
  stub_push_all(stub);
  pump(srv, &cl, 200);
  CHECK(cl.status_frames >= 2, "ws notify status frame");
  CHECK(strstr((char *) cl.last_msg, "\"ingress0\":\"ready\"") != NULL,
        "ws notified frame reflects change");

  /* Client-initiated close: Go's writer replies 1000 and the connection
   * closes (main.go:279-281). */
  wslay_event_queue_close(cl.wctx, WSLAY_CODE_NORMAL_CLOSURE, NULL, 0);
  pump(srv, &cl, 200);
  CHECK(cl.close_received, "ws close echo received");

  /* The server must unregister the listener after the close handshake
   * (Go's bounded-1s RemoveListener, main.go:266-274). */
  pump(srv, &cl, 200);
  CHECK(stub->unsubscribe_calls >= subs_before + 1, "ws unsubscribe called");
  CHECK(stub->subscribed[0] == 0, "ws listener removed");

  /* The server closes the TCP connection (EOF). */
  CHECK(wait_eof(srv, cl.fd), "ws EOF after close");

  ws_client_close(&cl);
}

static void test_ws_reject_no_upgrade(struct strim_http_server *srv) {
  char resp[2048];
  char body[1024];

  CHECK(http_exchange(srv, strim_http_server_bound_port(srv), "GET", "/subscribe",
                      NULL, NULL, resp, sizeof(resp)) == 0,
        "subscribe plain exchange");
  CHECK(resp_status(resp) == 426, "subscribe plain status");
  CHECK(strstr(resp_body(resp, body, sizeof(body)), "does not contain Upgrade")
            != NULL,
        "subscribe plain body: %s", body);
}

static void test_ws_reject_bad_method(struct strim_http_server *srv) {
  char resp[2048];
  char body[1024];
  static const char hdrs[] =
      "Upgrade: websocket\r\n"
      "Connection: Upgrade\r\n"
      "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
      "Sec-WebSocket-Version: 13\r\n";

  CHECK(http_exchange(srv, strim_http_server_bound_port(srv), "POST", "/subscribe",
                      hdrs, NULL, resp, sizeof(resp)) == 0,
        "subscribe POST exchange");
  CHECK(resp_status(resp) == 405, "subscribe POST status");
  CHECK(strstr(resp_body(resp, body, sizeof(body)), "method is not GET")
            != NULL,
        "subscribe POST body: %s", body);
}

/* =========================================================================
 * Graceful shutdown (service(-1) loop + shutdown_request)
 * ========================================================================= */

static void *shutdown_loop_thread(void *arg) {
  strim_http_server *s = arg;
  int rc = strim_http_server_service(s, -1);
  return (void *) (intptr_t) rc;
}

static void test_shutdown_loop(void) {
  strim_http_callbacks cbs;
  strim_http_server *srv = NULL;
  pthread_t th;
  void *ret = NULL;

  stub_reset(&g_stub);
  g_stub.cbs = &cbs;
  g_stub.userdata = &g_stub;
  stub_fill_callbacks(&cbs);

  CHECK(strim_http_server_start(&srv, ":0", &cbs, &g_stub) == 0,
        "shutdown-loop start");
  if (srv == NULL)
    return;

  if (pthread_create(&th, NULL, shutdown_loop_thread, srv) != 0)
  {
    strim_http_server_destroy(srv);
    return;
  }
  usleep(100000); /* let the loop start */
  strim_http_server_shutdown_request(srv);
  if (pthread_join(th, &ret) != 0)
    CHECK(0, "shutdown-loop join");
  else
    CHECK((int) (intptr_t) ret == 0, "service(-1) returned 0 (got %d)",
          (int) (intptr_t) ret);
  strim_http_server_destroy(srv);
}

/* =========================================================================
 * main
 * ========================================================================= */

/* Run one scenario; report PASS only when it added no failures. */
#define RUN(fn, tag, ...)                                       \
  do                                                            \
  {                                                             \
    int before = failures;                                      \
    fn(__VA_ARGS__);                                            \
    if (failures == before)                                     \
      printf("[%s] PASS\n", tag);                               \
    else                                                        \
      printf("[%s] FAILED\n", tag);                             \
  } while (0)

int main(void) {
  strim_http_callbacks cbs;
  strim_http_server *srv = NULL;

  RUN(test_sha1, "sha1");
  RUN(test_base64, "base64");

  stub_reset(&g_stub);
  g_stub.cbs = &cbs;
  g_stub.userdata = &g_stub;
  stub_fill_callbacks(&cbs);

  /* The env var is the Go controller's WEBSOCKET_WRITE_TIMEOUT (envspec.go);
   * a 2s budget keeps the ws write-timeout from interfering with the test. */
  setenv("WEBSOCKET_WRITE_TIMEOUT", "2s", 1);

  if (strim_http_server_start(&srv, ":0", &cbs, &g_stub) != 0)
  {
    fprintf(stderr, "FAIL: strim_http_server_start\n");
    return 1;
  }
  CHECK(strim_http_server_bound_port(srv) > 0, "bound port");
  printf("server on port %d\n", strim_http_server_bound_port(srv));

  RUN(test_healthz, "healthz", srv);
  RUN(test_unknown_route, "unknown-route", srv);
  RUN(test_status, "status", srv);
  RUN(test_status_wrong_method, "status-405", srv);
  RUN(test_event_ok, "event-204", srv, &g_stub);
  RUN(test_event_bad_json, "event-400", srv);
  RUN(test_event_bad_path, "event-500", srv);
  RUN(test_event_wrong_method, "event-405", srv);
  RUN(test_control_ok, "control-204", srv, &g_stub);
  RUN(test_status_after_event, "status-after-event", srv);
  RUN(test_ws_reject_no_upgrade, "subscribe-426", srv);
  RUN(test_ws_reject_bad_method, "subscribe-405", srv);
  RUN(test_ws_cycle, "ws-subscribe-push-close", srv, &g_stub);

  strim_http_server_destroy(srv);

  RUN(test_shutdown_loop, "shutdown-loop");

  if (failures != 0)
  {
    fprintf(stderr, "http_lib_test: %d failure(s)\n", failures);
    return 1;
  }
  printf("http_lib_test: all scenarios passed\n");
  return 0;
}