// ============================================================================
// cc_http.h — HTTP/websocket serving module constants (CPP macros)
// ============================================================================
//  Shared constants for the cc_http.S module — Phase 4.6, the HTTP/1.1 +
//  websocket SERVING layer of the ARM controller rewrite.  Everything here
//  is a CPP macro, never .equ: the fail-loud discipline (AGENTS.md hard
//  rule 6) means a module-local `.equ CC_HTTP_ERR_BADJSON, -1` collides
//  with the macro and fails to assemble instead of silently shadowing it.
//  The CC_* layout ids and offsets come from cc_layout.inc; this header adds
//  only what THIS module needs.
//
//  The C-layer contract this module calls is core/controller/alternate/c/cc_http.h —
//  the thin libwebsockets wrapper that owns the sockets, the HTTP parsing,
//  and the ws framing.  This module owns the WIRE LOGIC: the handlers that
//  serialize status JSON, parse and route /event and /control bodies,
//  reconcile, and the per-client listener trampolines the state module
//  invokes.  The two files share the handler error-code contract
//  (CC_HTTP_ERR_BADJSON = 400 "bad json: <err>", any other non-zero =
//  500 "<err>") and the client cap.
//
//  The wire contract (core/controller/main.go file:line):
//    /event  POST -> parse PathEvent, handle, reconcile, 204  (:237, :368-385)
//    /control POST -> parse ControlCommand, handle, reconcile, 204 (:239)
//    /status GET  -> cc_state_status + cc_json_status + '\n'   (:241, :387-399)
//    /subscribe   -> ws; per-client listener, 1-deep drop-oldest/latest-wins
//                    (:251-259), write-timeout 1011 (:283-288), shutdown 1000
//                    (:279-281), bounded-1s remove (:266-274)
//    /healthz     -> 200 "ok\n"  (:293-299)
//    unknown path -> 404 "404 page not found\n" (Go mux default)
//    wrong method -> 405 "method not allowed\n" (:371-373, :390-392)
//    bad json     -> 400 "bad json: <err>"      (:376-379)
//    handler err  -> 500 "<err>"                (:381-382)
//
//  The 400/500 body text is byte-exact against the Go controller for the
//  error classes this module formats (see the module header in cc_http.S
//  for the full message table and citations).
// ============================================================================
#ifndef CC_HTTP_H
#define CC_HTTP_H

// ----------------------------------------------------------------------------
// Handler result codes (shared with core/controller/alternate/c/cc_http.h).
// ----------------------------------------------------------------------------
#define CC_HTTP_ERR_BADJSON  (-100) // parse failed: 400 "bad json: <err>"
//  (-100 is outside the CC_STATE_ERR_* range -1..-10, so the C layer's 400-vs-500
//  mapping cannot confuse a state-handler error with a parse error.)

// ----------------------------------------------------------------------------
// The ws client cap and scratch sizes (mirrors the C header).
// ----------------------------------------------------------------------------
#define CC_HTTP_MAX_WS_CLIENTS 4
#define CC_HTTP_STATUS_MAX     4096  // one serialized ControllerStatus JSON
#define CC_HTTP_ERRBUF_MAX     256   // the 400/500 error body text

// ----------------------------------------------------------------------------
// Scratch buffer partition (http_scratch, .bss).  The parse out-structs are
// 16 bytes each (CC_PE_SIZE / CC_CMD_SIZE == 16) and never overlap the
// status JSON buffer.
// ----------------------------------------------------------------------------
#define HTTP_SCRATCH_PE        0     // PathEvent / ControlCommand out-struct
#define HTTP_SCRATCH_CMD       0     // (same 16-byte slot; never concurrent)
#define HTTP_SCRATCH_STATUS    16    // the serialized status JSON + '\n'
#define HTTP_SCRATCH_STR_A     16 + CC_HTTP_STATUS_MAX     // "path" extract
#define HTTP_SCRATCH_STR_B     HTTP_SCRATCH_STR_A + 64     // "status" extract
#define HTTP_SCRATCH_SIZE      HTTP_SCRATCH_STR_B + 64

// ----------------------------------------------------------------------------
// http_str_value key ids (which JSON member to extract for the %+v error
// messages, mirroring Go's fmt.Errorf("...%+v") of the parsed struct).
// ----------------------------------------------------------------------------
#define HTTP_KEY_PATH      0
#define HTTP_KEY_STATUS    1
#define HTTP_KEY_COMPONENT 2
#define HTTP_KEY_ACTION    3

// Struct-kind ids for the bad-json classifier (Go's "%T" of the target).
#define HTTP_STRUCT_PATH_EVENT 0
#define HTTP_STRUCT_COMMAND    1

// Path-event error message selectors (http_fmt_vevent).
#define HTTP_VEVENT_BADNAME  0   // "invalid path name: {Path:%s Status:%s}"
#define HTTP_VEVENT_BADSTATUS 1  // "invalid path status: {Path:%s Status:%s}"

// ----------------------------------------------------------------------------
// The 1-deep ws queue and listener-trampoline count: one listener per client,
// up to CC_HTTP_MAX_WS_CLIENTS.  cc_http_ws_listener is the client-0
// trampoline; http_listener_1..3 cover the rest.
// ----------------------------------------------------------------------------
#define HTTP_LISTENER_TABLE_SIZE (CC_HTTP_MAX_WS_CLIENTS * 8)

#endif // CC_HTTP_H