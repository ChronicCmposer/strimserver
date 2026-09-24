/*
 * internal.h — HTTP lane private contract (not part of http_server.h).
 *
 * Two things the Wave 0-A header did not pin down but the implementation
 * needs (flagged in the Wave-1 http-lane report for the Core lane and the
 * header owner):
 *
 *   1. STRIM_HTTP_ERR_BADJSON — the sentinel the controller lane's
 *      handle_event/handle_control return when the request body failed JSON
 *      parse. The http_server.h callback has only the return value to
 *      distinguish "400 bad json" from "500 handler error"; this repo's
 *      alternate port established -100 for exactly this (cc_http.h
 *      CC_HTTP_ERR_BADJSON, outside the controller error range -1..-5).
 *      The Core lane MUST return this value for parse failures.
 *
 *   2. strim_http_ws_send + strim_http_server_bound_port — the HTTP lane's
 *      ws_send slot queue is the function Wave 2's main() puts into
 *      callbacks.ws_send (http_server.h did not declare it, so it lives
 *      here). It resolves the server from the module singleton (see
 *      http_server.c), matching the alternate port's globals.
 *
 * License: project code (see LICENSE). No GPL.
 */
#ifndef STRIM_HTTP_INTERNAL_H
#define STRIM_HTTP_INTERNAL_H

#include <stddef.h>
#include <stdint.h>

#include "http_server.h"

#ifdef __cplusplus
extern "C" {
#endif

#define STRIM_HTTP_ERR_BADJSON (-100)

/* The 1-deep drop-oldest/latest-wins ws outbound slot (main.go:251-259).
 * Called by the controller lane's notify path, possibly from another thread.
 * See strim_http_ws_send_fn in http_server.h for the semantics. */
int strim_http_ws_send(void *userdata, int client_idx, const uint8_t *bytes,
                       size_t len);

/* Test support: the actual bound port (useful for ":0" ephemeral binds). */
int strim_http_server_bound_port(const strim_http_server *server);

#ifdef __cplusplus
}
#endif

#endif /* STRIM_HTTP_INTERNAL_H */