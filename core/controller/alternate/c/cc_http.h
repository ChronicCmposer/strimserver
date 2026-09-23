/*
 * cc_http.h — HTTP/1.1 + WebSocket serving layer (Phase 4.6).
 *
 * Thin, fixed-arity C wrapper over the vendored libwebsockets v5.0.0
 * (server-only, H1 + WS roles — no SSL, no HTTP/2, no client). This file
 * owns ALL libwebsockets calls: context/vhost lifecycle, HTTP request
 * parsing (method/path/body), the protocol callback switch, ws handshake/
 * read/write/framing, and the per-client 1-slot queue with write-timeout
 * semantics. It must NOT do JSON, state, or routing logic — the assembly
 * module core/controller/alternate/asm/cc_http.S owns those and is invoked through the
 * handler function pointers passed to cc_http_init.
 *
 * The wire contract is the Go controller (core/controller/main.go:235-400):
 *   /event, /control  POST  -> 204 (reconcile) | 400 bad json | 500 err
 *   /status            GET  -> 200 application/json + json.NewEncoder body
 *                              (the JSON plus a trailing '\n')
 *   /subscribe        ws    -> per-connection listener, 1-deep drop-oldest/
 *                              latest-wins queue, write-timeout close 1011,
 *                              shutdown close 1000, bounded-1s remove
 *   /healthz          any   -> 200 "ok\n"
 *   unknown path            -> 404 "404 page not found\n" (Go mux default)
 *   wrong method            -> 405 "method not allowed\n"
 *
 * CALLING RULES (assembly author, read carefully):
 *   - All functions are fixed-arity, AAPCS64-friendly (int returns,
 *     caller-provided buffers, no varargs).
 *   - cc_http_init stores the asm handler pointers; the C layer calls them
 *     from inside the LWS callback (a full AAPCS64 call — the asm fns save
 *     x19-x28/x30 themselves).
 *   - The library is single-threaded per context and is not re-entrant: the
 *     asm handlers may call cc_http_ws_send_text (which only marks the ws
 *     wsi writable), but must never call back into cc_http_service.
 *   - The ws listener fn is invoked BY THE STATE MODULE (cc_state.S) with
 *     x0 = &ControllerStatus, never by this C layer; it is stored here only
 *     for the API contract.
 *
 * License: project code (see LICENSE). No GPL.
 */
#ifndef CC_HTTP_H
#define CC_HTTP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* =========================================================================
 * Constants
 * ========================================================================= */

/* Shared C <-> asm handler result codes. */
#define CC_HTTP_ERR_BADJSON (-100) /* parse failed: 400 "bad json: <err>"     */
/* NOTE: -100 is OUTSIDE the cc_state error range (-1..-10, cc_state.h) so the   */
/* 400-vs-500 mapping cannot confuse a state-handler error with a parse error.   */
/* any other non-zero handler return -> 500 "<err>"                           */

/* Client cap: the Go controller grows the listener slice without bound; the
 * single-threaded port caps ws clients and fails loud beyond (deviation,
 * documented in cc_http.S). */
#define CC_HTTP_MAX_WS_CLIENTS 4

/* Bounded buffers (fixed-arity design; fail loud on overflow). */
#define CC_HTTP_STATUS_MAX 4096 /* one serialized ControllerStatus JSON      */
#define CC_HTTP_ERRBUF_MAX 256  /* the 400/500 error body text               */
#define CC_HTTP_BODY_MAX 16384  /* an /event or /control request body        */
#define CC_HTTP_URI_MAX 128

/* =========================================================================
 * asm handler functions (cc_http.S implements these; the C layer references
 * them as externs — the linker binds them, so no registration is needed)
 * ========================================================================= */

/* /status GET: serialize via cc_state_status + cc_json_status + '\n' into
 * out (cap bytes); *out_len receives the length. Return 0 or error. */
int cc_http_handle_status(void *controller, uint8_t *out, uint32_t cap,
                          uint32_t *out_len);

/* /control POST: cc_json_parse_control -> cc_state_handle_control ->
 * cc_state_reconcile. On error fill err_buf (the 400/500 body text). */
int cc_http_handle_control(void *controller, const uint8_t *body, uint32_t len,
                           char *err_buf, uint32_t err_cap);

/* /event POST: cc_json_parse_path_event -> cc_state_handle_path_event ->
 * cc_state_reconcile. On error fill err_buf. */
int cc_http_handle_event(void *controller, const uint8_t *body, uint32_t len,
                         char *err_buf, uint32_t err_cap);

/* Register the listener for a new ws client (cc_state_add_listener). */
int cc_http_ws_connect(void *controller, int client_idx);

/* Remove the listener for a closing ws client (cc_state_remove_listener,
 * bounded 1s — a synchronous call in the single-threaded port). */
int cc_http_ws_disconnect(void *controller, int client_idx);

/* The parsed WEBSOCKET_WRITE_TIMEOUT (time.ParseDuration, cc_env.S). */
uint64_t cc_env_dur(const char *name);

/* =========================================================================
 * API (fixed arity)
 * ========================================================================= */

/* Create the LWS context/vhost, register the protocol, store the controller
 * and read WEBSOCKET_WRITE_TIMEOUT (via cc_env_dur; 0 makes every write
 * immediately time out and close 1011, exactly like Go's
 * context.WithTimeout(ctx, 0)).
 *
 *   addr:  listen address in Go's ":port" form (":4000").
 *   controller: the Controller pointer (cc_state_ctrl()).
 *
 * NOTE ON THE NAME: the assembly module's exported cc_http_init
 * (x0=ctrl, x1=addr) owns the frozen cc_http_init symbol (cc_main.h, called
 * by cc_main.S main_setup_http); this C bootstrap is the function it calls,
 * so it is cc_http_server_init. The rest of the API keeps the cc_http_
 * prefix.
 *
 * Returns 0 on success, -1 on failure. The caller then drives the event
 * loop with cc_http_service. */
int cc_http_server_init(const char *addr, void *controller);

/* Request a graceful shutdown (Go srv.Shutdown equivalent): pending ws
 * writes are flushed best-effort, then each ws client is closed with a
 * StatusNormalClosure (1000) frame. Safe to call from a signal handler. */
void cc_http_shutdown_request(void);

/* Run the LWS event loop.
 *   timeout_ms < 0: loop until cc_http_shutdown_request, then flush pending
 *                   ws writes, close every ws client with 1000, destroy the
 *                   context, return 0.
 *   timeout_ms >= 0: one service pass (the timeout is ignored by LWS since
 *                   v3.2; it sleeps until an event). Return 0.
 * Returns -1 on a fatal LWS error. */
int cc_http_service(int timeout_ms);

/* Queue a ws TEXT frame for client (index 0..CC_HTTP_MAX_WS_CLIENTS-1) with
 * the 1-deep drop-oldest/latest-wins semantics (Go main.go:251-259): if the
 * slot is empty store; else drop the old frame and store the new one. The
 * frame is written on the next writable event, subject to the write timeout
 * (on timeout the client is closed with StatusInternalError, 1011). Returns
 * 0 on success, -1 when the client index is invalid or the frame is too
 * big. */
int cc_http_ws_send_text(int client, const uint8_t *bytes, uint32_t len);

/* Number of live ws clients (diagnostics / cap accounting). */
int cc_http_ws_client_count(void);

#ifdef __cplusplus
}
#endif

#endif /* CC_HTTP_H */