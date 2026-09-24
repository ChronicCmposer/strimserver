/*
 * http_server.h — HTTP/1.1 + WebSocket serving contract for the C controller.
 *
 * Wave 0-A foundation header. The HTTP lane implements this (the wire-level
 * serving; the existing alternate/c/cc_http.c wraps libwebsockets for exactly
 * this job); the state lane provides the callbacks. The wire contract is the
 * Go controller (core/controller/main.go:235-299) — do not deviate:
 *
 *   /event    POST  -> 204 (then RequestReconcile) | 400 bad json | 500 err
 *   /control  POST  -> 204 (then RequestReconcile) | 400 bad json | 500 err
 *   /status   GET   -> 200 application/json (the serialized ControllerStatus)
 *   /subscribe ws   -> per-connection listener, 1-deep drop-oldest/latest-wins
 *                      write queue, write-timeout close 1011, shutdown close
 *                      1000, bounded-1s remove (main.go:243-291)
 *   /healthz  any   -> 200 "ok\n"
 *   unknown path    -> 404 "404 page not found\n"
 *   wrong method    -> 405 "method not allowed\n"
 *
 * CALLBACK MODEL: the HTTP lane is a passive server. It calls back into the
 * controller lane through strim_http_callbacks for every wire event:
 *   - /event /control bodies arrive in handle_event/handle_control.
 *   - /status is served from handle_status (the controller's
 *     SubmitStatus snapshot).
 *   - The controller's status listeners (ws subscribers) are
 *     registered/unregistered via ws_subscribe/ws_unsubscribe when a
 *     websocket client connects/closes.
 *   - ws_send marshals a status JSON frame to a client THROUGH the
 *     controller action queue: the controller lane (not the HTTP thread)
 *     owns the 1-deep per-client queue, exactly like the Go
 *     sendChannel/listener pairing (main.go:251-291).
 *
 * The controller lane calls strim_http_server_broadcast after every status
 * change; the server invokes the registered listener callbacks in the order
 * they subscribed (same as Go's notifyListeners, controller.go:263-267).
 *
 * Style: fixed-arity C, pthread-compatible callbacks. The server runs its own
 * event loop on the calling thread (strim_http_server_service) — no internal
 * threads in the foundation contract.
 *
 * License: project code (see LICENSE). No GPL.
 */
#ifndef STRIM_HTTP_SERVER_H
#define STRIM_HTTP_SERVER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* =========================================================================
 * Constants
 * ========================================================================= */

/* Bounded buffers (fixed-arity design; fail loud on overflow). */
#define STRIM_HTTP_STATUS_MAX 4096  /* one serialized ControllerStatus JSON */
#define STRIM_HTTP_ERRBUF_MAX 256   /* the 400/500 error body text          */
#define STRIM_HTTP_BODY_MAX   16384 /* an /event or /control request body   */
#define STRIM_HTTP_URI_MAX    128

/* Client cap: the Go controller grows the listener slice without bound; the
 * single-threaded C port caps ws clients and fails loud beyond (the same
 * documented deviation as alternate/c/cc_http.h). */
#define STRIM_HTTP_MAX_WS_CLIENTS 4

/* =========================================================================
 * Callbacks (the controller lane implements these)
 * ========================================================================= */

/* handle_event / handle_control: parse+validate the request body and apply
 * it to the controller (SubmitPathEvent / SubmitControl). On success return
 * 0 (the server then calls request_reconcile and replies 204). On failure
 * fill err (the 400/500 body text) and return non-zero; the server replies
 * 400 "bad json: <err>" for a parse failure, else 500 "<err>" (the same
 * mapping as the Go postJSON wrapper, main.go:368-385). */
typedef int (*strim_http_handle_event_fn)(void *userdata,
                                          const uint8_t *body, size_t len,
                                          char *err, size_t err_cap);
typedef int (*strim_http_handle_control_fn)(void *userdata,
                                            const uint8_t *body, size_t len,
                                            char *err, size_t err_cap);

/* handle_status: serialize the controller status snapshot (SubmitStatus)
 * into out; *out_len receives the length. Return 0 or non-zero. */
typedef int (*strim_http_handle_status_fn)(void *userdata,
                                           uint8_t *out, size_t cap,
                                           size_t *out_len);

/* request_reconcile: non-blocking RequestReconcile after a successful
 * /event or /control (main.go:383). */
typedef void (*strim_http_request_reconcile_fn)(void *userdata);

/* ws_subscribe / ws_unsubscribe: register/remove the ws client's status
 * listener when a websocket connects/closes (main.go:261-274; the remove is
 * the bounded-1s variant). Return 0 on success. */
typedef int (*strim_http_ws_subscribe_fn)(void *userdata, int client_idx);
typedef int (*strim_http_ws_unsubscribe_fn)(void *userdata, int client_idx);

/* ws_send: queue a status JSON frame for the ws client with the 1-deep
 * drop-oldest/latest-wins semantics (main.go:251-259). Called by the
 * controller lane on its own thread (the notify path); the HTTP lane must be
 * safe to receive this from the controller thread (a lock-free slot or a
 * small mutex — pthread-compatible). Return 0 on success, non-zero when the
 * client index is invalid or the frame is too big. */
typedef int (*strim_http_ws_send_fn)(void *userdata, int client_idx,
                                     const uint8_t *bytes, size_t len);

/* The full callback bundle. Every function pointer must be non-NULL. */
typedef struct strim_http_callbacks {
    strim_http_handle_event_fn     handle_event;
    strim_http_handle_control_fn   handle_control;
    strim_http_handle_status_fn    handle_status;
    strim_http_request_reconcile_fn request_reconcile;
    strim_http_ws_subscribe_fn     ws_subscribe;
    strim_http_ws_unsubscribe_fn   ws_unsubscribe;
    strim_http_ws_send_fn          ws_send;
} strim_http_callbacks;

/* =========================================================================
 * API
 * ========================================================================= */

typedef struct strim_http_server strim_http_server;

/* Start the server: bind addr (Go's ":port" form, e.g. ":4000") and register
 * the callbacks. Returns 0 + *out, or a negative error. */
int strim_http_server_start(strim_http_server **out, const char *addr,
                            const strim_http_callbacks *cbs, void *userdata);

/* Run the event loop.
 *   timeout_ms < 0: loop until shutdown_request, then close every ws client
 *                   with 1000, release, return 0.
 *   timeout_ms >= 0: one service pass; return 0.
 * Returns non-zero on a fatal server error. */
int strim_http_server_service(strim_http_server *server, int timeout_ms);

/* Request a graceful shutdown (Go srv.Shutdown equivalent): pending ws
 * writes are flushed best-effort, then each ws client is closed with a
 * StatusNormalClosure (1000) frame. Safe to call from a signal handler. */
void strim_http_server_shutdown_request(strim_http_server *server);

/* Destroy the server (after service returned). */
void strim_http_server_destroy(strim_http_server *server);

#ifdef __cplusplus
}
#endif

#endif /* STRIM_HTTP_SERVER_H */