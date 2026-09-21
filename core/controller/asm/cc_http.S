// ============================================================================
// cc_http.S — HTTP/1.1 + websocket SERVING LOGIC for the strimserver controller
// ============================================================================
//
//  Target:     AArch64 (ARMv8.2-A), little-endian — Linux (ELF, static);
//              cc_platform.h is the only platform header (Linux-only).
//  Assembler:  GNU as syntax, preprocessed by the C compiler
//              (`cc -c -x assembler-with-cpp`).
//  ISA:        .arch armv8.2-a — exactly one in-source directive (below),
//              nothing higher, no .arch_extension, no .cpu (Graviton2 parity).
//
//  This module is Phase 4.6: the HTTP/websocket LAYER.  It is the WIRE LOGIC
//  half of the serving stack — the handlers that serialize the /status JSON,
//  parse and route the /event and /control bodies, run reconcile, and the
//  per-client listener trampolines the state module invokes.  The C layer
//  (core/controller/c/cc_http.c) owns ALL libwebsockets calls — sockets,
//  HTTP request parsing, ws handshake/framing, the per-client 1-slot queue
//  and its write-timeout — and invokes the exported functions below through
//  the handler pointers passed at cc_http_init.  cc_state.S owns the state
//  machine; cc_json.S owns JSON; this module owns neither.
//
//  Wire contract (Gate 0 — core/controller/main.go file:line; the 400/500
//  body text is byte-exact against the Go controller for every error class
//  this module formats):
//
//  /event, /control POST (postJSON, :368-385):
//    method != POST                 -> 405 "method not allowed\n" (:371-373)
//    bad json                       -> 400 "bad json: <err>"      (:376-379)
//    handler error                  -> 500 "<err>"                (:381-382)
//    success                        -> cc_state_reconcile + 204   (:383)
//    The 400 <err> is Go's json.Decoder message (decode.go):
//      ""            -> "EOF"
//      "notjson"     -> "invalid character 'o' in literal null (expecting 'u')"
//      "[]"          -> "json: cannot unmarshal array into Go value of type
//                       main.PathEvent / main.ControlCommand"
//      "1"           -> "json: cannot unmarshal number into Go value of type ..."
//      "true"        -> "json: cannot unmarshal bool into Go value of type ..."
//      "{\"path\":1}"-> "json: cannot unmarshal number into Go struct field
//                       PathEvent.path of type main.PathName" (+ status/
//                       component/action with their Go type names)
//      "{x"          -> "invalid character 'x' looking for beginning of
//                       object key string"
//      "{\"path\" x}"-> "invalid character 'x' after object key"
//      "{\"path\":\"ingress0\"" -> "unexpected EOF"
//    The 500 <err> is the controller error (controller.go):
//      unknown path  -> "invalid path name: {Path:%s Status:%s}" (:225)
//      bad status    -> "invalid path status: {Path:%s Status:%s}" (:226)
//      route miss    -> "control not implemented: {Component:%s Action:%s}"
//                       (:219; the %+v format includes the field names)
//      prereq fail   -> "cannot set stage \"scale_and_egress\" desired state
//                       to \"running\", prerequisite not satisfied:
//                       \"ingress0\" path is not ready" (:279 + :179-183)
//    A top-level `null` body decodes to a zero-value struct in Go (fields
//    stay ""), so the handlers below reproduce Go's 500 for the zero
//    PathEvent / ControlCommand instead of routing the port's zeroed ids
//    (deviation from cc_json.S's "null -> fields untouched": the ids 0 map
//    to ingress0/unknown and would otherwise route).
//
//  /status GET (getJSON, :387-399):
//    method != GET -> 405 "method not allowed\n" (:390-392)
//    else cc_state_status -> cc_json_status -> append '\n' (Go Encoder,
//    stream.go:223).  The body is Marshal bytes + '\n' exactly.
//
//  /subscribe (the ws listener path; the C layer owns the socket):
//    cc_http_ws_connect(ctrl, idx): register the per-client listener
//    trampoline via cc_state_add_listener (controller.go:250-254; the add
//    fires the listener immediately, so the client receives the current
//    status right after the handshake, :253).
//    http_listener_N: on every transition cc_state calls it with
//    x0 = &ControllerStatus (:266); serialize JSON + '\n' and hand to C
//    cc_http_ws_send_text for client N (the 1-deep drop-oldest/latest-wins
//    queue and the WEBSOCKET_WRITE_TIMEOUT close-1011 semantics are C-side,
//    :251-259, :283-288).  cc_http_ws_disconnect removes the listener
//    (bounded 1s — synchronous in the single-threaded port, :266-274).
//    The client cap (4) is C-side; the port fails loud beyond (deviation:
//    Go grows without bound).
//
//  /healthz and the 404/426 responses are C-side (http_dispatch).
//
//  Exported (all .global, AAPCS64, x19-x28 preserved; <= 80 instructions):
//    cc_http_init(x0=ctrl, x1=addr)
//                        -> x0 = 0 / err; call C cc_http_init.  FROZEN 4.6
//                           contract (cc_main.h/cc_main.S): exactly two
//                           arguments; the C layer binds this module's
//                           handlers as linked externs and resolves the
//                           WEBSOCKET_WRITE_TIMEOUT via cc_env_dur.
//    cc_http_handle_status(x0=ctrl, x1=out_buf, x2=cap, x3=out_len_ptr)
//                        -> x0 = 0 / err   (/status handler)
//    cc_http_handle_control(x0=ctrl, x1=body, x2=len, x3=err_buf, x4=err_cap)
//                        -> x0 = 0 / CC_HTTP_ERR_BADJSON / CC_STATE_ERR_*
//    cc_http_handle_event(x0=ctrl, x1=body, x2=len, x3=err_buf, x4=err_cap)
//                        -> x0 = 0 / CC_HTTP_ERR_BADJSON / CC_STATE_ERR_*
//    cc_http_ws_listener(x0=status)   the ControllerListener for client 0
//                        (x0 = &ControllerStatus, per cc_state's call sites)
//    cc_http_ws_connect(x0=ctrl, x1=client_idx) -> x0 = 0 / err
//    cc_http_ws_disconnect(x0=ctrl, x1=client_idx) -> x0 = 0 / err
//    cc_http_serve(x0=ctrl)          -> x0 = 0   (loop C cc_http_service(-1))
//    cc_http_shutdown(x0=ctrl)       -> x0 = 0   (request graceful shutdown)
//
//  Module-local helpers (http_*, full AAPCS64 obligations):
//    http_listener_core(x0=status, x1=client_idx)   serialize + send
//    http_listener_1/2/3                            per-client trampolines
//    http_is_null(x0=body, x1=len) -> x0 = 1/0      top-level `null` body?
//    http_str_value(x0=body, x1=len, x2=key, x3=key_len, x4=dst, x5=cap)
//                        -> x0 = copied len / 0     extract "key":"str"
//    http_fmt_vevent(x0=err_buf, x1=cap, x2=body, x3=len, x4=which)
//    http_fmt_cmd(x0=err_buf, x1=cap, x2=body, x3=len)
//    http_fmt_null_vevent / http_fmt_null_cmd / http_fmt_prereq
//    http_badjson_msg(x0=body, x1=len, x2=struct_kind, x3=dst, x4=cap)
//    http_badjson_obj / http_bjo_value / http_badjson_lit
//    http_badjson_topmsg / http_badjson_fieldmsg / http_key_lookup
//    http_skip_string(x0=p, x1=end) -> x0 = after the closing quote
//    http_emit_char_msg(x0=dst, x1=char, x2=tail)   "invalid character 'c'<tail>"
//
//  AAPCS64 notes (see cc_util.S for the full rules)
//  --------------------------------------------------
//    * Callee-saved (must be preserved across any `bl`): x19-x28, x29.
//    * sp stays 16-byte aligned at every call site.
//    * Never join statements with ';' — one instruction per line.
//    * Never use x18.
//
// ============================================================================

#include "cc_platform.h"
#include "cc_layout.inc"
#include "cc_json.h"
#include "cc_state.h"
#include "cc_http.h"
    .arch armv8.2-a
    .text

// ============================================================================
// cc_http_init — call the C serving-layer init.
//   in:  x0 = ctrl, x1 = addr (":<port>")
//   out: x0 = C cc_http_init's result
//   FROZEN 4.6 contract (cc_main.h, cc_main.S main_setup_http :334-335):
//   exactly two arguments.  The C layer references this module's handler
//   functions as linked externs and resolves WEBSOCKET_WRITE_TIMEOUT itself
//   via cc_env_dur (time.ParseDuration, cc_env.S) — no third argument.  The
//   C bootstrap it calls is cc_http_server_init (the asm owns the frozen
//   cc_http_init name).
// ============================================================================
    .p2align 2
    .global cc_http_init
    FUNC_TYPE(cc_http_init)
cc_http_init:
    PROLOGUE 2                      // x19=ctrl x20=addr
    mov x19, x0
    mov x20, x1
    mov x0, x20                     // addr
    mov x1, x19                     // controller
    bl cc_http_server_init
    EPILOGUE 2
    ret

// ============================================================================
// cc_http_handle_status — the /status handler (getJSON, main.go:387-399).
//   in:  x0 = ctrl, x1 = out_buf, x2 = cap, x3 = out_len_ptr
//   out: x0 = 0 / err
//   Serializes via cc_state_status + cc_json_status, appends the trailing
//   '\n' Go's Encoder adds (stream.go:223), and stores the length.
// ============================================================================
    .p2align 2
    .global cc_http_handle_status
    FUNC_TYPE(cc_http_handle_status)
cc_http_handle_status:
    PROLOGUE 4                      // x19=out_buf x20=cap x21=len_ptr
    mov x19, x1                     //   x22=status x23=len
    mov x20, x2
    mov x21, x3
    bl cc_state_status              // x0 = &ControllerStatus
    mov x22, x0
    ldr x2, [x22, #CC_CS_PATHS]
    ldr x3, [x22, #CC_CS_STAGES]
    mov x1, x22
    mov x0, x19
    bl cc_json_status               // x0 = end ptr (Marshal bytes, no '\n')
    sub x23, x0, x19                // length
    cmp x23, x20
    b.hs .Lhs_toobig                // fail-loud: JSON > caller cap (never)
    mov w1, #10                     // '\n' (Go Encoder appends it)
    strb w1, [x0]
    add x23, x23, #1
    str w23, [x21]                  // 32-bit store: out_len is uint32_t
    mov x0, #0
    b .Lhs_ret
.Lhs_toobig:
    mov x0, #-2
.Lhs_ret:
    EPILOGUE 4
    ret

// ============================================================================
// cc_http_handle_control — the /control handler (postJSON, main.go:368-385).
//   in:  x0 = ctrl, x1 = body, x2 = len, x3 = err_buf, x4 = err_cap
//   out: x0 = 0 / CC_HTTP_ERR_BADJSON / CC_STATE_ERR_NOCTRL|PREREQ
//   Top-level null -> Go's zero ControlCommand -> route miss 500 (:219).
//   Parse (cc_json_parse_control) -> handle (cc_state_handle_control) ->
//   reconcile (main.go:383).  On error fill err_buf with the Go body text.
// ============================================================================
    .p2align 2
    .global cc_http_handle_control
    FUNC_TYPE(cc_http_handle_control)
cc_http_handle_control:
    PROLOGUE 4                      // x19=ctrl x20=body x21=len x22=err_buf
    mov x19, x0                     //   x23=err_cap x24=rc
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x23, x4
    mov x0, x20
    mov x1, x21
    bl http_is_null
    cbnz x0, .Lhc_null
    mov x0, x20
    mov x1, x21
    LEA x2, http_scratch + HTTP_SCRATCH_CMD
    bl cc_json_parse_control
    cbnz x0, .Lhc_badjson
    mov x0, x19
    LEA x1, http_scratch + HTTP_SCRATCH_CMD
    bl cc_state_handle_control
    mov x24, x0
    cbnz x24, .Lhc_err
    mov x0, x19
    bl cc_state_reconcile           // main.go:383
    mov x0, #0
    b .Lhc_ret
.Lhc_badjson:
    mov x0, x20
    mov x1, x21
    mov x2, #HTTP_STRUCT_COMMAND
    mov x3, x22
    mov x4, x23
    bl http_badjson_msg
    mov x0, #CC_HTTP_ERR_BADJSON
    b .Lhc_ret
.Lhc_null:
    mov x0, x22
    mov x1, x23
    bl http_fmt_null_cmd
    mov x0, #CC_STATE_ERR_NOCTRL    // zero cmd misses the route (controller.go:218)
    b .Lhc_ret
.Lhc_err:
    cmp x24, #CC_STATE_ERR_PREREQ
    b.eq .Lhc_prereq
    mov x0, x22                     // NOCTRL: {Component:%s Action:%s} (:219)
    mov x1, x23
    mov x2, x20
    mov x3, x21
    bl http_fmt_cmd
    mov x0, x24
    b .Lhc_ret
.Lhc_prereq:
    mov x0, x22
    mov x1, x23
    bl http_fmt_prereq
    mov x0, #CC_STATE_ERR_PREREQ
.Lhc_ret:
    EPILOGUE 4
    ret

// ============================================================================
// cc_http_handle_event — the /event handler (postJSON, main.go:368-385).
//   in:  x0 = ctrl, x1 = body, x2 = len, x3 = err_buf, x4 = err_cap
//   out: x0 = 0 / CC_HTTP_ERR_BADJSON / CC_STATE_ERR_BADPATH|BADSTATUS
//   Top-level null -> Go's zero PathEvent -> invalid path name 500 (:225).
// ============================================================================
    .p2align 2
    .global cc_http_handle_event
    FUNC_TYPE(cc_http_handle_event)
cc_http_handle_event:
    PROLOGUE 4                      // x19=ctrl x20=body x21=len x22=err_buf
    mov x19, x0                     //   x23=err_cap x24=rc
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x23, x4
    mov x0, x20
    mov x1, x21
    bl http_is_null
    cbnz x0, .Lhe_null
    mov x0, x20
    mov x1, x21
    LEA x2, http_scratch + HTTP_SCRATCH_PE
    bl cc_json_parse_path_event
    cbnz x0, .Lhe_badjson
    mov x0, x19
    LEA x1, http_scratch + HTTP_SCRATCH_PE
    bl cc_state_handle_path_event
    mov x24, x0
    cbnz x24, .Lhe_err
    mov x0, x19
    bl cc_state_reconcile           // main.go:383
    mov x0, #0
    b .Lhe_ret
.Lhe_badjson:
    mov x0, x20
    mov x1, x21
    mov x2, #HTTP_STRUCT_PATH_EVENT
    mov x3, x22
    mov x4, x23
    bl http_badjson_msg
    mov x0, #CC_HTTP_ERR_BADJSON
    b .Lhe_ret
.Lhe_null:
    mov x0, x22
    mov x1, x23
    bl http_fmt_null_vevent
    mov x0, #CC_STATE_ERR_BADPATH    // zero path misses the map (:224-225)
    b .Lhe_ret
.Lhe_err:
    cmp x24, #CC_STATE_ERR_BADSTATUS
    b.eq .Lhe_badstatus
    mov x0, x22                     // BADPATH: {Path:%s Status:%s} (:225)
    mov x1, x23
    mov x2, x20
    mov x3, x21
    mov x4, #HTTP_VEVENT_BADNAME
    bl http_fmt_vevent
    mov x0, x24
    b .Lhe_ret
.Lhe_badstatus:
    mov x0, x22                     // BADSTATUS (:226)
    mov x1, x23
    mov x2, x20
    mov x3, x21
    mov x4, #HTTP_VEVENT_BADSTATUS
    bl http_fmt_vevent
    mov x0, x24
.Lhe_ret:
    EPILOGUE 4
    ret

// ============================================================================
// cc_http_ws_listener — the ControllerListener for client 0.  cc_state calls
// every listener with x0 = &ControllerStatus (state_notify, cc_state.S:266
// and the immediate fire at add, controller.go:253).  Each client registers
// its own trampoline (http_listener_1..3 below); the shared core does the
// serialize + send.
// ============================================================================
    .p2align 2
    .global cc_http_ws_listener
    FUNC_TYPE(cc_http_ws_listener)
cc_http_ws_listener:
    mov x1, #0
    b http_listener_core

    .p2align 2
http_listener_1:
    mov x1, #1
    b http_listener_core

    .p2align 2
http_listener_2:
    mov x1, #2
    b http_listener_core

    .p2align 2
http_listener_3:
    mov x1, #3
    b http_listener_core

// ============================================================================
// cc_http_ws_connect — register the listener for a new ws client.
//   in:  x0 = ctrl, x1 = client_idx
//   out: x0 = 0 / CC_STATE_ERR_*
//   The per-client listener trampoline is selected from the rodata table and
//   registered via cc_state_add_listener (controller.go:250-254), which fires
//   it immediately with the current status (:253).
// ============================================================================
    .p2align 2
    .global cc_http_ws_connect
    FUNC_TYPE(cc_http_ws_connect)
cc_http_ws_connect:
    PROLOGUE 2                      // x19=ctrl x20=idx x21=fn
    mov x19, x0
    mov x20, x1
    cmp x20, #CC_HTTP_MAX_WS_CLIENTS
    b.hs .Lwsc_bad
    LEA x21, http_listener_table
    ldr x21, [x21, x20, lsl #3]
    mov x0, x19
    mov x1, x21
    bl cc_state_add_listener
    b .Lwsc_ret
.Lwsc_bad:
    mov x0, #CC_STATE_ERR_FULL
.Lwsc_ret:
    EPILOGUE 2
    ret

// ============================================================================
// cc_http_ws_disconnect — remove the listener for a closing ws client
// (controller.go:256-261; Go bounds the remove with 1s, :266-274 — the
// single-threaded cc_state_remove_listener is synchronous and trivially
// within the bound).
// ============================================================================
    .p2align 2
    .global cc_http_ws_disconnect
    FUNC_TYPE(cc_http_ws_disconnect)
cc_http_ws_disconnect:
    PROLOGUE 2                      // x19=ctrl x20=idx x21=fn
    mov x19, x0
    mov x20, x1
    cmp x20, #CC_HTTP_MAX_WS_CLIENTS
    b.hs .Lwsd_bad
    LEA x21, http_listener_table
    ldr x21, [x21, x20, lsl #3]
    mov x0, x19
    mov x1, x21
    bl cc_state_remove_listener
    b .Lwsd_ret
.Lwsd_bad:
    mov x0, #-1
.Lwsd_ret:
    EPILOGUE 2
    ret

// ============================================================================
// cc_http_serve — run the service loop until shutdown requested.
//   in:  x0 = ctrl (parity)   out: x0 = 0
// ============================================================================
    .p2align 2
    .global cc_http_serve
    FUNC_TYPE(cc_http_serve)
cc_http_serve:
    PROLOGUE 1
    mov w0, #-1
    bl cc_http_service              // loop until cc_http_shutdown_request
    mov x0, #0
    EPILOGUE 1
    ret

// ============================================================================
// cc_http_shutdown — request a graceful shutdown (Go srv.Shutdown, main.go:351).
// ============================================================================
    .p2align 2
    .global cc_http_shutdown
    FUNC_TYPE(cc_http_shutdown)
cc_http_shutdown:
    PROLOGUE 1
    bl cc_http_shutdown_request
    mov x0, #0
    EPILOGUE 1
    ret

// ============================================================================
// Module-local helpers
// ============================================================================

// ----------------------------------------------------------------------------
// http_listener_core — the shared ControllerListener body.
//   in:  x0 = &ControllerStatus, x1 = client_idx
//   Serializes JSON + '\n' (Go Encoder, stream.go:223) and hands the bytes to
//   C cc_http_ws_send_text for the owning client (the 1-deep drop-oldest/
//   latest-wins queue and write-timeout close are C-side, main.go:251-259,
//   :283-288).
// ----------------------------------------------------------------------------
http_listener_core:
    PROLOGUE 3                      // x19=status x20=client x21=buf x22=end
    mov x19, x0
    mov x20, x1
    LEA x21, http_scratch + HTTP_SCRATCH_STATUS
    ldr x2, [x19, #CC_CS_PATHS]
    ldr x3, [x19, #CC_CS_STAGES]
    mov x1, x19
    mov x0, x21
    bl cc_json_status               // x0 = end ptr
    mov x22, x0
    mov w1, #10
    strb w1, [x22]                  // '\n' (Encoder appends it)
    add x22, x22, #1
    sub x2, x22, x21                // length
    mov x0, x20
    mov x1, x21
    bl cc_http_ws_send_text
    mov x0, #0
    EPILOGUE 3
    ret

// ----------------------------------------------------------------------------
// http_is_null — does the body decode to a top-level JSON null?
//   in:  x0 = body, x1 = len   out: x0 = 1/0
//   Skips leading whitespace (Go's decoder) and checks for the literal
//   "null".  Go's Decode("null") succeeds with a zero-value struct (:376-379);
//   the handlers above reproduce the zero-value 500 instead of routing the
//   port's zeroed ids (see the module header deviation note).
// ----------------------------------------------------------------------------
http_is_null:
    mov x2, x0
    add x3, x0, x1
.Lin_ws:
    cmp x2, x3
    b.hs .Lin_no
    ldrb w4, [x2]
    cmp w4, #' '
    b.eq .Lin_skip
    cmp w4, #'\t'
    b.eq .Lin_skip
    cmp w4, #'\n'
    b.eq .Lin_skip
    cmp w4, #'\r'
    b.eq .Lin_skip
    b .Lin_have
.Lin_skip:
    add x2, x2, #1
    b .Lin_ws
.Lin_have:
    cmp w4, #'n'
    b.ne .Lin_no
    add x5, x2, #4
    cmp x5, x3
    b.hi .Lin_no
    ldrb w5, [x2, #1]
    cmp w5, #'u'
    b.ne .Lin_no
    ldrb w5, [x2, #2]
    cmp w5, #'l'
    b.ne .Lin_no
    ldrb w5, [x2, #3]
    cmp w5, #'l'
    b.ne .Lin_no
    mov x0, #1
    b .Lin_ret
.Lin_no:
    mov x0, #0
.Lin_ret:
    ret

// ----------------------------------------------------------------------------
// http_str_value — extract a JSON string member's raw value from the body.
//   in:  x0 = body, x1 = len, x2 = key, x3 = key_len, x4 = dst, x5 = dst_cap
//   out: x0 = copied length (NUL-terminated) / 0 when the key is absent or
//        its value is not a string
//   Scans for `"key"` then `:` then ws then `"` and copies until the closing
//   quote (stopping at a backslash: the %+v messages print the DECODED value
//   in Go; escapes are out of the tested error classes).  Used to build the
//   500 bodies Go formats with %+v of the parsed struct (controller.go:219,
//   :225-226) — the parser discards raw strings for unknown ids, so the raw
//   bytes are recovered here.
// ----------------------------------------------------------------------------
http_str_value:
    PROLOGUE 5                      // x19=body x20=end x21=key x22=key_len
    mov x19, x0                     //   x23=dst x24=dst_cap x25=p x26=tmp
    add x20, x0, x1                 //   x27=tmp x28=copied
    mov x21, x2
    mov x22, x3
    mov x23, x4
    mov x24, x5
    mov x25, x19
.Lsv_loop:
    cmp x25, x20
    b.hs .Lsv_miss
    ldrb w26, [x25]
    cmp w26, #'"'
    b.ne .Lsv_next
    add x27, x25, #1                // candidate key start
    add x28, x27, x22               // after the key
    cmp x28, x20
    b.hi .Lsv_next
    mov x0, x27
    mov x1, x21
    mov x2, x22
    bl memcmp
    cbnz x0, .Lsv_next
    ldrb w26, [x28]
    cmp w26, #'"'
    b.ne .Lsv_next
    add x27, x28, #1                // after '"key"': expect ':'
    cmp x27, x20
    b.hs .Lsv_miss
    ldrb w26, [x27]
    cmp w26, #':'
    b.ne .Lsv_next
    add x27, x27, #1
    mov x0, x27
    mov x1, x20
    bl http_skip_ws
    mov x27, x0
    cmp x27, x20
    b.hs .Lsv_miss
    ldrb w26, [x27]
    cmp w26, #'"'
    b.ne .Lsv_next
    add x27, x27, #1                // value start
    mov x28, #0
.Lsv_copy:
    cmp x27, x20
    b.hs .Lsv_done
    ldrb w26, [x27]
    cmp w26, #'"'
    b.eq .Lsv_done
    cmp w26, #'\\'
    b.eq .Lsv_done
    cmp x28, x24
    b.hs .Lsv_done
    strb w26, [x23, x28]
    add x28, x28, #1
    add x27, x27, #1
    b .Lsv_copy
.Lsv_done:
    strb wzr, [x23, x28]
    mov x0, x28
    b .Lsv_ret
.Lsv_next:
    add x25, x25, #1
    b .Lsv_loop
.Lsv_miss:
    mov x0, #0
.Lsv_ret:
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// http_fmt_vevent — the /event 500 body (controller.go:225-226).
//   in:  x0 = err_buf, x1 = cap, x2 = body, x3 = len, x4 = which
//   which 0 -> "invalid path name: {Path:%s Status:%s}"   (:225)
//   which 1 -> "invalid path status: {Path:%s Status:%s}" (:226)
// ----------------------------------------------------------------------------
http_fmt_vevent:
    PROLOGUE 4                      // x19=err_buf x20=cap x21=body x22=len
    mov x19, x0                     //   x23=which
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x23, x4
    mov x0, x21
    mov x1, x22
    LEA x2, http_s_key_path
    mov x3, #JSON_KEY_PATH_LEN
    LEA x4, http_scratch + HTTP_SCRATCH_STR_A
    mov x5, #64
    bl http_str_value
    mov x0, x21
    mov x1, x22
    LEA x2, http_s_key_status
    mov x3, #JSON_KEY_STATUS_LEN
    LEA x4, http_scratch + HTTP_SCRATCH_STR_B
    mov x5, #64
    bl http_str_value
    mov x0, x19
    cbnz x23, .Lfve_status
    LEA x1, http_s_invalid_path_name
    b .Lfve_have
.Lfve_status:
    LEA x1, http_s_invalid_path_status
.Lfve_have:
    bl cc_cat_cstr
    LEA x1, http_s_fmt_path_open
    bl cc_cat_cstr
    LEA x1, http_scratch + HTTP_SCRATCH_STR_A
    bl cc_cat_cstr
    LEA x1, http_s_fmt_status_open
    bl cc_cat_cstr
    LEA x1, http_scratch + HTTP_SCRATCH_STR_B
    bl cc_cat_cstr
    LEA x1, http_s_fmt_close
    bl cc_cat_cstr
    mov x0, #0
    EPILOGUE 4
    ret

// ----------------------------------------------------------------------------
// http_fmt_cmd — the /control 500 body (controller.go:219).
//   in:  x0 = err_buf, x1 = cap, x2 = body, x3 = len
//   "control not implemented: {Component:%s Action:%s}" — the %+v format
//   includes the exported field names.
// ----------------------------------------------------------------------------
http_fmt_cmd:
    PROLOGUE 3                      // x19=err_buf x20=cap x21=body x22=len
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x0, x21
    mov x1, x22
    LEA x2, http_s_key_component
    mov x3, #JSON_KEY_COMPONENT_LEN
    LEA x4, http_scratch + HTTP_SCRATCH_STR_A
    mov x5, #64
    bl http_str_value
    mov x0, x21
    mov x1, x22
    LEA x2, http_s_key_action
    mov x3, #JSON_KEY_ACTION_LEN
    LEA x4, http_scratch + HTTP_SCRATCH_STR_B
    mov x5, #64
    bl http_str_value
    mov x0, x19
    LEA x1, http_s_control_not_impl
    bl cc_cat_cstr
    LEA x1, http_s_fmt_comp_open
    bl cc_cat_cstr
    LEA x1, http_scratch + HTTP_SCRATCH_STR_A
    bl cc_cat_cstr
    LEA x1, http_s_fmt_action_open
    bl cc_cat_cstr
    LEA x1, http_scratch + HTTP_SCRATCH_STR_B
    bl cc_cat_cstr
    LEA x1, http_s_fmt_close
    bl cc_cat_cstr
    mov x0, #0
    EPILOGUE 3
    ret

// ----------------------------------------------------------------------------
// http_fmt_null_vevent / http_fmt_null_cmd / http_fmt_prereq — the fixed
// 500 bodies for the top-level-null decode (Go's zero-value struct) and the
// egress-start prerequisite failure.  The prereq string is constant because
// the port's route table is fixed (egress start -> scale_and_egress/running,
// prereq ingress0 ready, main.go:196-201 + :179-183); if the routes change
// this string must be regenerated.
// ----------------------------------------------------------------------------
http_fmt_null_vevent:
    PROLOGUE 1
    mov x19, x0
    mov x0, x19
    LEA x1, http_s_null_vevent
    bl cc_cat_cstr
    mov x0, #0
    EPILOGUE 1
    ret

http_fmt_null_cmd:
    PROLOGUE 1
    mov x19, x0
    mov x0, x19
    LEA x1, http_s_null_cmd
    bl cc_cat_cstr
    mov x0, #0
    EPILOGUE 1
    ret

http_fmt_prereq:
    PROLOGUE 1
    mov x19, x0
    mov x0, x19
    LEA x1, http_s_prereq
    bl cc_cat_cstr
    mov x0, #0
    EPILOGUE 1
    ret

// ----------------------------------------------------------------------------
// http_skip_ws — advance past leading JSON whitespace (space \t \n \r).
//   in:  x0 = p, x1 = end   out: x0 = first non-whitespace position
// ----------------------------------------------------------------------------
http_skip_ws:
    mov x2, x0
.Lsw_loop:
    cmp x0, x1
    b.hs .Lsw_done
    ldrb w2, [x0]
    cmp w2, #' '
    b.eq .Lsw_skip
    cmp w2, #'\t'
    b.eq .Lsw_skip
    cmp w2, #'\n'
    b.eq .Lsw_skip
    cmp w2, #'\r'
    b.eq .Lsw_skip
    b .Lsw_done
.Lsw_skip:
    add x0, x0, #1
    b .Lsw_loop
.Lsw_done:
    ret

// ----------------------------------------------------------------------------
// http_badjson_msg — the 400 "bad json: <err>" message (json.Decoder, main.go
// :376-379): classify the body's decode failure into Go's exact error text.
//   in:  x0 = body, x1 = len, x2 = struct_kind, x3 = dst, x4 = cap
//   out: x0 = 0 (dst filled; the C layer prepends "bad json: ")
//   struct_kind: HTTP_STRUCT_PATH_EVENT / HTTP_STRUCT_COMMAND (Go's %T).
// ----------------------------------------------------------------------------
http_badjson_msg:
    PROLOGUE 4                      // x19=body x20=end x21=kind x22=dst
    mov x19, x0                     //   x23=cap x24=p x25=c
    add x20, x0, x1
    mov x21, x2
    mov x22, x3
    mov x23, x4
    mov x0, x19
    mov x1, x20
    bl http_skip_ws
    mov x24, x0
    cmp x24, x20
    b.hs .Lbj_eof
    ldrb w25, [x24]
    cmp w25, #'{'
    b.eq .Lbj_obj
    cmp w25, #'t'
    b.eq .Lbj_true
    cmp w25, #'f'
    b.eq .Lbj_false
    cmp w25, #'n'
    b.eq .Lbj_null
    mov x0, x25                     // any other first char: scalar helper
    mov x1, x21
    mov x2, x22
    bl http_badjson_scalar
    b .Lbj_ret
.Lbj_eof:
    mov x0, x22
    LEA x1, http_s_eof
    bl cc_cat_cstr
    mov x0, #0
    b .Lbj_ret
.Lbj_true:
    mov x0, x24
    mov x2, #0
    mov x3, x22
    mov x4, x21
    bl http_badjson_lit_top         // x1 = x20 (end)
    b .Lbj_ret
.Lbj_false:
    mov x0, x24
    mov x2, #1
    mov x3, x22
    mov x4, x21
    bl http_badjson_lit_top
    b .Lbj_ret
.Lbj_null:
    mov x0, x24                     // a complete null never reaches here
    mov x2, #2                      //   (http_is_null pre-checks it); a
    mov x3, x22                     //   malformed one gets the literal error
    mov x4, x21
    bl http_badjson_lit_top
    b .Lbj_ret
.Lbj_obj:
    mov x0, x19
    mov x2, x21                     // http_skip_ws clobbered x2; set it fresh
    mov x4, x23
    bl http_badjson_obj             // x1 = x20, x3 = x22
.Lbj_ret:
    EPILOGUE 4
    ret

// ----------------------------------------------------------------------------
// http_badjson_scalar — the top-level message for a non-object, non-literal
// first character: array/string/bool/number decode (decode.go), or the
// "invalid character '<c>' looking for beginning of value" syntax error.
//   in:  x0 = first char, x1 = struct_kind, x2 = dst
// ----------------------------------------------------------------------------
http_badjson_scalar:
    PROLOGUE 3                      // x19=char x20=kind x21=dst x22=tmp
    mov x19, x0
    mov x20, x1
    mov x21, x2
    cmp w19, #'['
    b.eq .Lbs_arr
    cmp w19, #'"'
    b.eq .Lbs_str
    cmp w19, #'-'
    b.eq .Lbs_num
    sub w22, w19, #'0'
    cmp w22, #9
    b.ls .Lbs_num
    cmp w19, #'t'
    b.eq .Lbs_bool
    cmp w19, #'f'
    b.eq .Lbs_bool
    mov x0, x21                     // invalid character '<c>' looking for
    mov x1, x19                     //   beginning of value
    LEA x2, http_s_look_begin
    bl http_emit_char_msg
    mov x0, #0
    b .Lbs_ret
.Lbs_arr:
    LEA x1, http_s_kind_array
    b .Lbs_have
.Lbs_str:
    LEA x1, http_s_kind_string
    b .Lbs_have
.Lbs_num:
    LEA x1, http_s_kind_number
    b .Lbs_have
.Lbs_bool:
    LEA x1, http_s_kind_bool
.Lbs_have:
    mov x0, x21
    mov x2, x20
    bl http_badjson_topmsg
    mov x0, #0
.Lbs_ret:
    EPILOGUE 3
    ret

// ----------------------------------------------------------------------------
// http_badjson_lit_top — a top-level true/false/null literal: on a complete
// literal emit Go's "cannot unmarshal bool into Go value of type main.<T>",
// else http_badjson_lit already emitted the literal-mismatch error.
//   in:  x0 = p, x1 = end, x2 = lit (0 true, 1 false, 2 null), x3 = dst,
//        x4 = struct_kind
// ----------------------------------------------------------------------------
http_badjson_lit_top:
    PROLOGUE 3                      // x19=p x20=end x21=lit x22=dst x23=kind
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x23, x4
    mov x0, x19
    mov x1, x20
    mov x2, x21
    mov x3, x22
    bl http_badjson_lit
    cbz x0, .Lblt_ret
    mov x0, x22
    LEA x1, http_s_kind_bool
    mov x2, x23
    bl http_badjson_topmsg
.Lblt_ret:
    mov x0, #0
    EPILOGUE 3
    ret

// ----------------------------------------------------------------------------
// http_badjson_lit — validate/skip a JSON literal (true/false/null) at p.
//   in:  x0 = p, x1 = end, x2 = lit (0 true, 1 false, 2 null), x3 = dst
//   out: x0 = 1 when the literal is COMPLETE (caller emits the bool message)
//        x0 = 0 after emitting Go's literal-mismatch error into dst
//   The mismatch error reports the FIRST differing byte and the expected one
//   (Go decode.go literal parsing): "invalid character '<actual>' in literal
//   <name> (expecting '<expected>')".
// ----------------------------------------------------------------------------
http_badjson_lit:
    PROLOGUE 5                      // x19=p x20=end x21=lit x22=dst x23=len
    mov x19, x0                     //   x24=litptr x25=i x26=actual x27=exp
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x23, #4
    cmp x21, #1
    b.ne .Lbl_len
    mov x23, #5                     // "false"
.Lbl_len:
    add x24, x19, x23
    cmp x24, x20
    b.hi .Lbl_trunc
    LEA x24, http_lit_names
    ldr x24, [x24, x21, lsl #3]
    mov x25, #0
.Lbl_loop:
    cmp x25, x23
    b.hs .Lbl_ok
    ldrb w26, [x19, x25]
    ldrb w27, [x24, x25]
    cmp w26, w27
    b.ne .Lbl_mismatch
    add x25, x25, #1
    b .Lbl_loop
.Lbl_ok:
    mov x0, #1
    b .Lbl_ret
.Lbl_mismatch:
    mov x0, x22                     // "invalid character '<c>' in literal "
    mov x1, x26
    LEA x2, http_s_lit_mid
    bl http_emit_char_msg
    mov x28, x0                     // cursor (PROLOGUE 5 covers x28)
    mov x0, x28
    LEA x1, http_lit_names
    ldr x1, [x1, x21, lsl #3]
    bl cc_cat_cstr
    mov x28, x0
    mov x0, x28
    LEA x1, http_s_lit_expect
    bl cc_cat_cstr
    strb w27, [x0]                  // the expected char
    add x0, x0, #1
    mov x28, x0
    mov x0, x28
    LEA x1, http_s_lit_close
    bl cc_cat_cstr
    mov x0, #0
    b .Lbl_ret
.Lbl_trunc:
    mov x0, x22
    LEA x1, http_s_unexpected_eof
    bl cc_cat_cstr
    mov x0, #0
.Lbl_ret:
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// http_badjson_topmsg — "json: cannot unmarshal <kind> into Go value of type
// main.<Struct>" (the top-level non-object decode, decode.go).
// ----------------------------------------------------------------------------
http_badjson_topmsg:
    PROLOGUE 3                      // x19=dst x20=kind x21=struct x24=cursor
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x24, x19
    mov x0, x24
    LEA x1, http_s_json_prefix
    bl cc_cat_cstr
    mov x24, x0
    mov x0, x24
    mov x1, x20
    bl cc_cat_cstr
    mov x24, x0
    mov x0, x24
    LEA x1, http_s_into_value
    bl cc_cat_cstr
    mov x24, x0
    mov x0, x24
    cbnz x21, .Lbjt_cmd
    LEA x1, http_s_struct_path_event
    b .Lbjt_have
.Lbjt_cmd:
    LEA x1, http_s_struct_cmd
.Lbjt_have:
    bl cc_cat_cstr
    mov x0, #0
    EPILOGUE 3
    ret

// ----------------------------------------------------------------------------
// http_key_lookup — does the parsed key match one of the target struct's
// known JSON members?
//   in:  x0 = key ptr, x1 = key len, x2 = struct_kind
//   out: x0 = 1 (first member) / 2 (second) / 0 (no match)
//   The per-struct key/field/type table is http_key_spec (see RODATA).
// ----------------------------------------------------------------------------
http_key_lookup:
    PROLOGUE 4                      // x19=key x20=len x21=struct x22=spec
    mov x19, x0                     //   x23=spec base temp
    mov x20, x1
    mov x21, x2
    LEA x22, http_key_spec
    mov x23, x21
    lsl x23, x23, #6                // struct * 64 (2 entries * 32 bytes)
    add x22, x22, x23
    ldr x1, [x22, #0]
    ldr x2, [x22, #8]
    cmp x20, x2
    b.ne .Lkl_second
    mov x0, x19
    bl memcmp
    cbnz x0, .Lkl_second
    mov x0, #1
    b .Lkl_ret
.Lkl_second:
    ldr x1, [x22, #32]
    ldr x2, [x22, #40]
    cmp x20, x2
    b.ne .Lkl_none
    mov x0, x19
    bl memcmp
    cbnz x0, .Lkl_none
    mov x0, #2
    b .Lkl_ret
.Lkl_none:
    mov x0, #0
.Lkl_ret:
    EPILOGUE 4
    ret

// ----------------------------------------------------------------------------
// http_badjson_fieldmsg — "json: cannot unmarshal <kind> into Go struct field
// <Struct>.<field> of type main.<Type>" (a known key with a non-string value,
// decode.go "cannot unmarshal ... into Go struct field ...").
//   in:  x0 = dst, x1 = kind ptr, x2 = struct_kind, x3 = field_idx (1/2)
// ----------------------------------------------------------------------------
http_badjson_fieldmsg:
    PROLOGUE 4                      // x19=dst x20=kind x21=struct x22=field
    mov x19, x0                     //   x23=spec x24=spec base temp
    mov x20, x1
    mov x21, x2
    mov x22, x3
    LEA x23, http_key_spec
    mov x24, x21
    lsl x24, x24, #6
    add x23, x23, x24
    sub x22, x22, #1
    lsl x22, x22, #5                // (field_idx-1) * 32
    add x23, x23, x22
    mov x24, x19                    // cursor
    mov x0, x24
    LEA x1, http_s_json_prefix
    bl cc_cat_cstr
    mov x24, x0
    mov x0, x24
    mov x1, x20
    bl cc_cat_cstr
    mov x24, x0
    mov x0, x24
    LEA x1, http_s_into_field
    bl cc_cat_cstr
    mov x24, x0
    mov x0, x24
    cbnz x21, .Lbf_cmd
    LEA x1, http_s_struct_path_event
    b .Lbf_have
.Lbf_cmd:
    LEA x1, http_s_struct_cmd
.Lbf_have:
    bl cc_cat_cstr
    mov x24, x0
    mov w1, #'.'                    // Struct.field separator (Go's %T)
    strb w1, [x24]
    add x24, x24, #1
    mov x0, x24
    ldr x1, [x23, #16]              // the field name
    bl cc_cat_cstr
    mov x24, x0
    mov x0, x24
    LEA x1, http_s_of_type
    bl cc_cat_cstr
    mov x24, x0
    mov x0, x24
    ldr x1, [x23, #24]              // the Go type name
    bl cc_cat_cstr
    mov x0, #0
    EPILOGUE 4
    ret

// ----------------------------------------------------------------------------
// http_badjson_obj — scan a '{' object for the decode failure (the port
// parser already rejected it; find the Go error text).  Handles the harness
// classes: bad object-key start, a known key with a non-string value, and a
// truncated object.  The per-key work (closing quote, ':', value) is
// delegated to http_bjo_key.
// ----------------------------------------------------------------------------
http_badjson_obj:
    PROLOGUE 4                      // x19=body x20=end x21=kind x22=dst
    mov x19, x0                     //   x23=cap x24=p x25=c
    mov x20, x1                     //   x1 = END (not len), like the helpers
    mov x21, x2
    mov x22, x3
    mov x23, x4
    add x24, x19, #1                // past '{'
.Lbjo_loop:
    cmp x24, x20
    b.hs .Lbjo_unexp
    ldrb w25, [x24]
    cmp w25, #' '
    b.eq .Lbjo_skip
    cmp w25, #'\t'
    b.eq .Lbjo_skip
    cmp w25, #'\n'
    b.eq .Lbjo_skip
    cmp w25, #'\r'
    b.eq .Lbjo_skip
    b .Lbjo_have
.Lbjo_skip:
    add x24, x24, #1
    b .Lbjo_loop
.Lbjo_have:
    cmp w25, #'"'
    b.eq .Lbjo_key
    cmp w25, #','
    b.eq .Lbjo_skip
    cmp w25, #'}'
    b.eq .Lbjo_unexp               // clean close: the parser would have
                                   //   accepted it — unreachable fallback
    mov x0, x22                     // invalid character '<c>' looking for
    mov x1, x25                     //   beginning of object key string
    LEA x2, http_s_look_objkey
    bl http_emit_char_msg
    b .Lbjo_ret_ok
.Lbjo_key:
    mov x0, x24
    mov x1, x20
    mov x2, x21
    mov x3, x22
    bl http_bjo_key
    cbz x0, .Lbjo_ret_ok            // a message was emitted
    mov x24, x0                     // continue after the value
    b .Lbjo_loop
.Lbjo_unexp:
    mov x0, x22
    LEA x1, http_s_unexpected_eof
    bl cc_cat_cstr
    mov x0, #0
    b .Lbjo_ret
.Lbjo_ret_ok:
    mov x0, #0
.Lbjo_ret:
    EPILOGUE 4
    ret

// ----------------------------------------------------------------------------
// http_bjo_key — handle one '"key"' inside a '{' object: find the closing
// quote, expect ':', then delegate the value to http_bjo_value.
//   in:  x0 = p (at the opening quote), x1 = end, x2 = struct_kind, x3 = dst
//   out: x0 = 0 (a message was emitted) / pointer past the value
// ----------------------------------------------------------------------------
http_bjo_key:
    PROLOGUE 5                      // x19=key_open x20=end x21=kind x22=dst
    mov x19, x0                     //   x23=key_end x24=p x25=c
    mov x20, x1
    mov x21, x2
    mov x22, x3
    add x23, x19, #1
.Lbk_kq:
    cmp x23, x20
    b.hs .Lbk_unexp
    ldrb w24, [x23]
    cmp w24, #'"'
    b.eq .Lbk_have_key
    add x23, x23, #1
    b .Lbk_kq
.Lbk_have_key:
    add x24, x23, #1                // after the key: skip ws, expect ':'
    mov x0, x24
    mov x1, x20
    bl http_skip_ws
    mov x24, x0
    cmp x24, x20
    b.hs .Lbk_unexp
    ldrb w25, [x24]
    cmp w25, #':'
    b.eq .Lbk_value
    mov x0, x22                     // invalid character '<c>' after object key
    mov x1, x25
    LEA x2, http_s_after_key
    bl http_emit_char_msg
    mov x0, #0
    b .Lbk_ret
.Lbk_value:
    add x24, x24, #1                // skip ws before the value
    mov x0, x24
    mov x1, x20
    bl http_skip_ws
    mov x24, x0
    cmp x24, x20
    b.hs .Lbk_unexp
    b .Lbk_have_value
.Lbk_have_value:
    mov x0, x24                     // the value start
    mov x1, x20
    mov x2, x21
    mov x3, x22
    add x4, x19, #1                 // key bytes start
    sub x5, x23, x19                // key_len + 1 (quotes)
    sub x5, x5, #1                  // key_len
    bl http_bjo_value
.Lbk_ret:
    EPILOGUE 5
    ret
.Lbk_unexp:
    mov x0, x22
    LEA x1, http_s_unexpected_eof
    bl cc_cat_cstr
    mov x0, #0
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// http_bjo_value — classify the value that starts at p (after ':').
//   in:  x0 = p, x1 = end, x2 = struct_kind, x3 = dst,
//        x4 = key ptr, x5 = key len
//   out: x0 = 0 (a 400 message was emitted into dst; done)
//        x0 = pointer past the value (continue scanning)
// ----------------------------------------------------------------------------
http_bjo_value:
    PROLOGUE 5                      // x19=p x20=end x21=kind x22=dst x23=key
    mov x19, x0                     //   x24=key_len x25=vc x26=field x27=kindp
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x23, x4
    mov x24, x5
    ldrb w25, [x19]
    cmp w25, #'"'
    b.eq .Lbv_str
    cmp w25, #'n'
    b.eq .Lbv_lit
    cmp w25, #'t'
    b.eq .Lbv_lit
    cmp w25, #'f'
    b.eq .Lbv_lit
    mov x0, x19                     // non-string value: delegate
    mov x1, x20
    mov x2, x21
    mov x3, x22
    mov x4, x23
    mov x5, x24
    bl http_bjo_nonstring
    b .Lbv_ret
.Lbv_str:
    mov x0, x19
    mov x1, x20
    bl http_skip_string
    b .Lbv_ret
.Lbv_lit:
    mov x0, x23
    mov x1, x24
    mov x2, x21
    bl http_key_lookup
    cbz x0, .Lbv_lit_skip
    mov x26, x0
    cmp w25, #'n'                   // null at a known key is a no-op in Go;
    b.eq .Lbv_lit_skip              //   the parser accepts -> unreachable
    LEA x27, http_s_kind_bool
    mov x0, x22
    mov x1, x27
    mov x2, x21
    mov x3, x26
    bl http_badjson_fieldmsg
    mov x0, #0
    b .Lbv_ret
.Lbv_lit_skip:
    add x0, x19, #4                 // "true"/"null" = 4 bytes
    cmp w25, #'f'
    b.ne .Lbv_ret
    add x0, x0, #1                  // "false" = 5
.Lbv_ret:
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// http_bjo_nonstring — a non-string, non-literal value inside an object: a
// known key gets Go's "cannot unmarshal <kind> into Go struct field ..."
// (decode.go); an unknown key gets the "looking for beginning of value"
// syntax error.
//   in:  x0 = p, x1 = end, x2 = struct_kind, x3 = dst, x4 = key ptr,
//        x5 = key len
//   out: x0 = 0 (a message was emitted)
// ----------------------------------------------------------------------------
http_bjo_nonstring:
    PROLOGUE 4                      // x19=p x20=end x21=kind x22=dst x23=key
    mov x19, x0                     //   x24=key_len x25=vc x26=field x27=kindp
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x23, x4
    mov x24, x5
    ldrb w25, [x19]
    mov x0, x23
    mov x1, x24
    mov x2, x21
    bl http_key_lookup
    cbz x0, .Lbn_unknown
    mov x26, x0
    LEA x27, http_s_kind_number
    cmp w25, #'-'
    b.eq .Lbn_field
    sub w28, w25, #'0'
    cmp w28, #9
    b.ls .Lbn_field
    LEA x27, http_s_kind_array
    cmp w25, #'['
    b.eq .Lbn_field
    LEA x27, http_s_kind_object
    cmp w25, #'{'
    b.eq .Lbn_field
    LEA x27, http_s_kind_bool
.Lbn_field:
    mov x0, x22
    mov x1, x27
    mov x2, x21
    mov x3, x26
    bl http_badjson_fieldmsg
    mov x0, #0
    b .Lbn_ret
.Lbn_unknown:
    mov x0, x22                     // invalid character '<c>' looking for
    mov x1, x25                     //   beginning of value
    LEA x2, http_s_look_begin
    bl http_emit_char_msg
    mov x0, #0
.Lbn_ret:
    EPILOGUE 4
    ret

// ----------------------------------------------------------------------------
// http_skip_string — advance past a '"'-delimited string (honoring '\').
//   in:  x0 = p (at the opening quote), x1 = end
//   out: x0 = pointer just past the closing quote
// ----------------------------------------------------------------------------
http_skip_string:
    mov x2, x0
    add x3, x0, #1
.Lss_loop:
    cmp x3, x1
    b.hs .Lss_done
    ldrb w4, [x3]
    cmp w4, #'\\'
    b.eq .Lss_esc
    cmp w4, #'"'
    b.eq .Lss_done
    add x3, x3, #1
    b .Lss_loop
.Lss_esc:
    add x3, x3, #2
    b .Lss_loop
.Lss_done:
    add x0, x3, #1
    ret

// ----------------------------------------------------------------------------
// http_emit_char_msg — "invalid character '<c>'<tail>" (the shared syntax-
// error shape of Go's decoder messages).
//   in:  x0 = dst, x1 = char, x2 = tail ptr (e.g. "' looking for beginning...")
// ----------------------------------------------------------------------------
http_emit_char_msg:
    PROLOGUE 2                      // x19=dst x20=cursor x21=char x22=tail
    mov x19, x0
    mov x21, x1
    mov x22, x2
    mov x20, x19
    mov x0, x20
    LEA x1, http_s_invchar
    bl cc_cat_cstr
    mov x20, x0
    strb w21, [x20]
    add x20, x20, #1
    mov x0, x20
    mov x1, x22
    bl cc_cat_cstr
    EPILOGUE 2
    ret

// ============================================================================
// RODATA — message strings, the literal names, the key/field/type spec, the
// listener table.  The strings are the byte-exact Go messages (see the
// module header); JSON_S_*/JSON_KEY_* from cc_json.h are the single source
// for the wire strings.
// ============================================================================
    RODATA

// ---- decoder messages (bad json) ----
http_s_eof:
    .asciz "EOF"
http_s_unexpected_eof:
    .asciz "unexpected EOF"
http_s_json_prefix:
    .asciz "json: cannot unmarshal "
http_s_into_value:
    .asciz " into Go value of type main."
http_s_into_field:
    .asciz " into Go struct field "
http_s_of_type:
    .asciz " of type main."
http_s_kind_array:
    .asciz "array"
http_s_kind_string:
    .asciz "string"
http_s_kind_bool:
    .asciz "bool"
http_s_kind_number:
    .asciz "number"
http_s_kind_object:
    .asciz "object"
http_s_struct_path_event:
    .asciz "PathEvent"
http_s_struct_cmd:
    .asciz "ControlCommand"
http_s_invchar:
    .asciz "invalid character '"
http_s_look_begin:
    .asciz "' looking for beginning of value"
http_s_look_objkey:
    .asciz "' looking for beginning of object key string"
http_s_after_key:
    .asciz "' after object key"
http_s_lit_mid:
    .asciz "' in literal "
http_s_lit_prefix:
    .asciz " in literal "
http_s_lit_expect:
    .asciz " (expecting '"
http_s_lit_close:
    .asciz "')"

// ---- literal names (http_badjson_lit) ----
http_lit_names:
    .quad http_s_lit_true
    .quad http_s_lit_false
    .quad http_s_lit_null
http_s_lit_true:
    .asciz "true"
http_s_lit_false:
    .asciz "false"
http_s_lit_null:
    .asciz "null"

// ---- JSON member keys (the wire keys; lengths from cc_json.h) ----
http_s_key_path:
    .asciz JSON_KEY_PATH
http_s_key_status:
    .asciz JSON_KEY_STATUS
http_s_key_component:
    .asciz JSON_KEY_COMPONENT
http_s_key_action:
    .asciz JSON_KEY_ACTION

// ---- key/field/type spec (http_key_lookup / http_badjson_fieldmsg) ----
//  Per struct: two 32-byte entries {key ptr, key len, field name ptr,
//  Go type name ptr}.  The field name equals the key (Go struct field names
//  match the json tags here); the type names are Go's %T of the fields.
http_key_spec:
    .quad http_s_key_path, JSON_KEY_PATH_LEN, http_s_key_path, http_s_type_pathname
    .quad http_s_key_status, JSON_KEY_STATUS_LEN, http_s_key_status, http_s_type_pathstatus
    .quad http_s_key_component, JSON_KEY_COMPONENT_LEN, http_s_key_component, http_s_type_component
    .quad http_s_key_action, JSON_KEY_ACTION_LEN, http_s_key_action, http_s_type_action
http_s_type_pathname:
    .asciz "PathName"
http_s_type_pathstatus:
    .asciz "PathStatus"
http_s_type_component:
    .asciz "ControlComponent"
http_s_type_action:
    .asciz "ControlAction"

// ---- the 500 error bodies (controller.go) ----
http_s_invalid_path_name:
    .asciz "invalid path name: "
http_s_invalid_path_status:
    .asciz "invalid path status: "
http_s_control_not_impl:
    .asciz "control not implemented: "
http_s_fmt_path_open:
    .asciz "{Path:"
http_s_fmt_status_open:
    .asciz " Status:"
http_s_fmt_close:
    .asciz "}"
http_s_fmt_comp_open:
    .asciz "{Component:"
http_s_fmt_action_open:
    .asciz " Action:"
http_s_null_vevent:
    .asciz "invalid path name: {Path: Status:}"
http_s_null_cmd:
    .asciz "control not implemented: {Component: Action:}"
http_s_prereq:
    .asciz "cannot set stage \"scale_and_egress\" desired state to \"running\", prerequisite not satisfied: \"ingress0\" path is not ready"

// ---- the per-client listener trampolines (cc_http_ws_connect) ----
http_listener_table:
    .quad cc_http_ws_listener
    .quad http_listener_1
    .quad http_listener_2
    .quad http_listener_3

// ============================================================================
// BSS — the scratch buffer (status JSON + the %+v extraction slots + the
// parse out-struct; see cc_http.h HTTP_SCRATCH_* partition).
// ============================================================================
    .bss
    .p2align 3
http_scratch:
    .space HTTP_SCRATCH_SIZE

    .end