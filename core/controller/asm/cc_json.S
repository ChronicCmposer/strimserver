// ============================================================================
// cc_json.S — JSON encode/decode for the strimserver controller
// ============================================================================
//
//  Target:     AArch64 (ARMv8.2-A), little-endian — Linux (ELF, static);
//              cc_platform.h is the only platform header (Linux-only).
//  Assembler:  GNU as syntax, preprocessed by the C compiler
//              (`cc -c -x assembler-with-cpp`).
//  ISA:        .arch armv8.2-a — exactly one in-source directive (below),
//              nothing higher, no .arch_extension, no .cpu (Graviton2 parity).
//
//  This module is the L1 json layer: it ports Go's encoding/json (v1, the
//  classic package) for the controller's wire payloads to assembly.  It is
//  byte-exact against the Go reference for every payload the controller
//  speaks, and its decoder matches json.Decoder.Decode (the call site).
//
//  Go call sites ported (core/controller):
//    * /status  GET : getJSON -> json.NewEncoder(w).Encode(status)
//                    (main.go:396; Encoder appends '\n', stream.go:223)
//    * /subscribe  : wsjson.Write(wctx, conn, status)
//                    (main.go:284; wsjson.go:57-63 -> json.NewEncoder(...)
//                    .Encode, same newline + HTML escaping)
//    * /event, /control POST : json.NewDecoder(r.Body).Decode(&m)
//                    (main.go:376; Decoder.Decode semantics)
//
//  JSON decisions resolved from the Go source (file:line evidence):
//    * Field order == Go struct field order:
//        ControllerStatus{Paths,Stages}   controller.go:46-49
//        PathEvent{Path,Status}           controller.go:51-54
//        StageEvent{Stage,State}          controller.go:56-59
//        ControlCommand{Component,Action} controller.go:61-64
//        StageStatus{Desired,Actual}      controller.go:35-38
//    * Map keys sorted lexicographically: encode.go:794
//        (strings.Compare(i.ks, j.ks)); the status tables the encoder
//        consumes must therefore be in ascending name order.
//    * escapeHTML = true (Encoder default, stream.go:195; the controller
//        never calls SetEscapeHTML(false)) -> < > & become \u003c \u003e
//        \u0026 (tables.go:123 htmlSafeSet; encode.go:1022-1028).
//    * String escaping (encode.go:999-1066):
//        " -> \", \ -> \\, \b\f\n\r\t short escapes, other < 0x20 -> \u00XX
//        (lowercase hex), DEL (0x7f) NOT escaped, U+2028/U+2029 -> \u2028/
//        \u2029, valid UTF-8 passed through, invalid bytes -> literal
//        "\ufffd" (one per invalid byte).
//    * The payload builders emit the COMPACT object WITHOUT the trailing
//        '\n' that Encoder.Encode appends (stream.go:223): the newline is
//        the HTTP/websocket layer's addition, exactly as Encoder does it.
//    * DECODER = Decoder.Decode (decode.go): leading whitespace skipped
//        (space \t \n \r only); top-level null -> ok, fields untouched;
//        unknown keys ignored (their values fully validated and skipped);
//        trailing garbage AFTER the top-level value is ACCEPTED (Decode
//        reads one value and never scans past it — verified empirically
//        with a Go probe on go1.26.5); trailing garbage INSIDE the object
//        (e.g. {"a":1x}) is an error; a known key with a non-string value
//        is an error ("cannot unmarshal ... into string field"); a known
//        key with null is a no-op (field unchanged); duplicate keys: last
//        wins; raw control chars (< 0x20) inside strings are errors; bad
//        escapes / bad \u hex / unterminated strings are errors.
//    * Decoded string VALUES are mapped to CC_* ids; a value that matches
//        no known id stores CC_JSON_ID_UNKNOWN (0xff) — the caller treats
//        it exactly like Go treats an unrecognized string (the route
//        lookup misses, controller.go:219 "control not implemented").
//
//  Exported (all .global, AAPCS64, x19-x28 preserved):
//    cc_json_sep(x0=buf, x1=first)      -> x0 = buf (first==1) or buf+1
//                                         (writes ',')
//    cc_json_str(x0=buf, x1=s, x2=len)  -> x0 = buf'  ("<escaped>")
//    cc_json_key_str(x0=buf, x1=key, x2=len) -> x0 = buf'  ("<escaped>":)
//    cc_json_u8(x0=buf, x1=v)           -> x0 = buf'  (decimal digits)
//    cc_json_path_event(x0=buf, x1=CC_PE_* ptr)  -> x0 = buf'
//    cc_json_stage_event(x0=buf, x1=CC_SE_* ptr) -> x0 = buf'
//    cc_json_status(x0=buf, x1=CC_CS_* ptr, x2=paths tbl, x3=stages tbl)
//                                       -> x0 = buf'
//    cc_json_control_cmd(x0=buf, x1=CC_CMD_* ptr) -> x0 = buf'
//    cc_json_parse_control(x0=json, x1=len, x2=CC_CMD_* out)
//                                       -> x0 = 0 ok / -1 error
//    cc_json_parse_path_event(x0=json, x1=len, x2=CC_PE_* out)
//                                       -> x0 = 0 ok / -1 error
//
//  cc_json_status table contracts (see cc_json.h): x2/x3 point to counted
//  tables {u64 count, entries} whose entries MUST be in ascending name
//  order (Go's sorted-map output).  x1 must point to a valid ControllerStatus
//  whose PATHS/STAGES pointers match x2/x3 (the ctr_ module owns it).
//
//  Module-local routines (json_ prefix) live BEFORE the first cc_ function
//  (the clobber checker now analyzes every non-.L function, local helpers
//  included, enforces x30 preservation across `bl`s, and checks both the
//  raw and preprocessed text by default).
//  Every one of them preserves x19-x28 and x30 across its own `bl`s via
//  PROLOGUE/EPILOGUE, exactly as the checker requires.
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
    .arch armv8.2-a
#include "cc_layout.inc"
#include "cc_json.h"
    .text

// ----------------------------------------------------------------------------
// RoData — every wire string (single source of truth via the cc_json.h
// macros), the escape tables, the id->string tables, and the parse specs.
// ----------------------------------------------------------------------------
    .macro JSON_S label, str
json_s_\label:
    .ascii "\str"                   // no NUL from .ascii
.Ljson_s_\label\()_end:             // end BEFORE the terminator: length = strlen
    .byte 0                         // NUL terminator (for cc_strlen)
    .endm

    RODATA

    JSON_S path, JSON_KEY_PATH
    JSON_S status, JSON_KEY_STATUS
    JSON_S stage, JSON_KEY_STAGE
    JSON_S state, JSON_KEY_STATE
    JSON_S paths, JSON_KEY_PATHS
    JSON_S stages, JSON_KEY_STAGES
    JSON_S desired, JSON_KEY_DESIRED
    JSON_S actual, JSON_KEY_ACTUAL
    JSON_S component, JSON_KEY_COMPONENT
    JSON_S action, JSON_KEY_ACTION

    JSON_S ingress0, JSON_S_INGRESS0
    JSON_S normalized, JSON_S_NORMALIZED
    JSON_S unknown, JSON_S_UNKNOWN
    JSON_S ready, JSON_S_READY
    JSON_S notready, JSON_S_NOTREADY
    JSON_S running, JSON_S_RUNNING
    JSON_S stopped, JSON_S_STOPPED
    JSON_S empty, JSON_S_EMPTY
    JSON_S mediamtx, JSON_S_MEDIAMTX
    JSON_S normalize, JSON_S_NORMALIZE
    JSON_S scale_and_egress, JSON_S_SCALE_AND_EGRESS
    JSON_S single_stage_egress, JSON_S_SINGLE_STAGE_EGRESS
    JSON_S egress, JSON_S_EGRESS
    JSON_S start, JSON_S_START
    JSON_S stop, JSON_S_STOP

    JSON_S null, JSON_LIT_NULL
    JSON_S true, JSON_LIT_TRUE
    JSON_S false, JSON_LIT_FALSE

// Short-escape map indexed by (byte - 8): 8->'b', 9->'t', 10->'n',
// 11 (0x0b) is a hole (it is \u000b, not a short escape), 12->'f', 13->'r'.
json_short_map:
    .byte 'b', 't', 'n', 0, 'f', 'r'

json_hex:
    .asciz JSON_HEX_DIGITS

// The literal Go writes for invalid UTF-8 (encode.go:1042): \ u f f f d
json_esc_ufffd:
    .byte '\\', 'u', 'f', 'f', 'f', 'd'

// ----------------------------------------------------------------------------
// Id -> string tables (indexed by CC_* id; entry = {.quad ptr, .quad len}).
// json_state_names includes the empty string at CC_STATE_NOTARGET, matching
// Go's NoTarget StageState "" (controller.go:28).
// ----------------------------------------------------------------------------
json_path_names:
    .quad json_s_ingress0, .Ljson_s_ingress0_end - json_s_ingress0
    .quad json_s_normalized, .Ljson_s_normalized_end - json_s_normalized

json_status_names:
    .quad json_s_unknown, .Ljson_s_unknown_end - json_s_unknown
    .quad json_s_ready, .Ljson_s_ready_end - json_s_ready
    .quad json_s_notready, .Ljson_s_notready_end - json_s_notready

json_state_names:
    .quad json_s_running, .Ljson_s_running_end - json_s_running
    .quad json_s_stopped, .Ljson_s_stopped_end - json_s_stopped
    .quad json_s_empty, .Ljson_s_empty_end - json_s_empty

json_component_names:
    .quad json_s_egress, .Ljson_s_egress_end - json_s_egress

json_action_names:
    .quad json_s_start, .Ljson_s_start_end - json_s_start
    .quad json_s_stop, .Ljson_s_stop_end - json_s_stop

json_stage_names:
    .quad json_s_mediamtx, .Ljson_s_mediamtx_end - json_s_mediamtx
    .quad json_s_normalize, .Ljson_s_normalize_end - json_s_normalize
    .quad json_s_scale_and_egress, .Ljson_s_scale_and_egress_end - json_s_scale_and_egress
    .quad json_s_single_stage_egress, .Ljson_s_single_stage_egress_end - json_s_single_stage_egress

// ----------------------------------------------------------------------------
// Parse specs for cc_json_parse_control / cc_json_parse_path_event.
// A spec is two 32-byte entries: {key ptr, key len, out offset, value table}.
// A value table is NULL-terminated entries of {cand ptr, cand len, id}.
// ----------------------------------------------------------------------------
json_spec_control:
    .quad json_s_component, .Ljson_s_component_end - json_s_component, CC_CMD_COMPONENT, json_component_vals
    .quad json_s_action, .Ljson_s_action_end - json_s_action, CC_CMD_ACTION, json_action_vals

json_component_vals:
    .quad json_s_egress, .Ljson_s_egress_end - json_s_egress, CC_COMPONENT_EGRESS
    .quad 0, 0, 0

json_action_vals:
    .quad json_s_start, .Ljson_s_start_end - json_s_start, CC_ACTION_START
    .quad json_s_stop, .Ljson_s_stop_end - json_s_stop, CC_ACTION_STOP
    .quad 0, 0, 0

json_spec_path_event:
    .quad json_s_path, .Ljson_s_path_end - json_s_path, CC_PE_PATH, json_path_vals
    .quad json_s_status, .Ljson_s_status_end - json_s_status, CC_PE_STATUS, json_status_vals

json_path_vals:
    .quad json_s_ingress0, .Ljson_s_ingress0_end - json_s_ingress0, CC_PATH_INGRESS0
    .quad json_s_normalized, .Ljson_s_normalized_end - json_s_normalized, CC_PATH_NORMALIZED
    .quad 0, 0, 0

json_status_vals:
    .quad json_s_unknown, .Ljson_s_unknown_end - json_s_unknown, CC_STATUS_UNKNOWN
    .quad json_s_ready, .Ljson_s_ready_end - json_s_ready, CC_STATUS_READY
    .quad json_s_notready, .Ljson_s_notready_end - json_s_notready, CC_STATUS_NOTREADY
    .quad 0, 0, 0

    .text

// ============================================================================
// Local helpers (json_ prefix — placed before the first cc_ function,
// matching cc_env.S; the clobber checker analyzes every non-.L function, so
// placement does not affect coverage).
// ============================================================================

// ----------------------------------------------------------------------------
// json_skip_ws(x0=p, x1=end) -> x0 = p' (first non-space byte or end).
//   Go's Decoder skips space, \t, \n, \r (decode.go isSpace).
// ----------------------------------------------------------------------------
    .p2align 2
json_skip_ws:
.Ljsw_loop:
    cmp x0, x1
    b.hs .Ljsw_done
    ldrb w5, [x0]
    cmp w5, #' '
    b.eq .Ljsw_adv
    cmp w5, #'\t'
    b.eq .Ljsw_adv
    cmp w5, #'\n'
    b.eq .Ljsw_adv
    cmp w5, #'\r'
    b.eq .Ljsw_adv
    b .Ljsw_done
.Ljsw_adv:
    add x0, x0, #1
    b .Ljsw_loop
.Ljsw_done:
    ret

// ----------------------------------------------------------------------------
// json_match_lit(x0=p, x1=end, x2=lit, x3=len) -> x0 = p' past the literal,
//   or 0 on mismatch/truncation.  Matches the literal EXACTLY (the byte
//   after the literal is deliberately not inspected: Decoder.Decode reads
//   one value and never scans past it).
// ----------------------------------------------------------------------------
    .p2align 2
json_match_lit:
    sub x4, x1, x0
    cmp x4, x3
    b.lo .Ljml_err
    mov x5, #0
.Ljml_loop:
    cmp x5, x3
    b.eq .Ljml_ok
    ldrb w6, [x0, x5]
    ldrb w7, [x2, x5]
    cmp w6, w7
    b.ne .Ljml_err
    add x5, x5, #1
    b .Ljml_loop
.Ljml_ok:
    add x0, x0, x3
    ret
.Ljml_err:
    mov x0, #0
    ret

// ----------------------------------------------------------------------------
// json_skip_number(x0=p, x1=end) -> x0 = p' past the number, or 0 on error.
//   JSON number grammar as the Go scanner accepts it: -?(0|[1-9][0-9]*)
//   (\. [0-9]+)? ([eE][+-]?[0-9]+)?  (scanner.go stateInNumber).
// ----------------------------------------------------------------------------
    .p2align 2
json_skip_number:
    cmp x0, x1
    b.hs .Ljsn_err
    ldrb w5, [x0]
    cmp w5, #'-'
    b.ne .Ljsn_int
    add x0, x0, #1
    cmp x0, x1
    b.hs .Ljsn_err
    ldrb w5, [x0]
.Ljsn_int:
    cmp w5, #'0'
    b.lo .Ljsn_err
    cmp w5, #'9'
    b.hi .Ljsn_err
    add x0, x0, #1
.Ljsn_int_loop:
    cmp x0, x1
    b.hs .Ljsn_frac
    ldrb w5, [x0]
    cmp w5, #'0'
    b.lo .Ljsn_frac
    cmp w5, #'9'
    b.hi .Ljsn_frac
    add x0, x0, #1
    b .Ljsn_int_loop
.Ljsn_frac:
    cmp x0, x1
    b.hs .Ljsn_done
    ldrb w5, [x0]
    cmp w5, #'.'
    b.ne .Ljsn_exp
    add x0, x0, #1
    cmp x0, x1
    b.hs .Ljsn_err
    ldrb w5, [x0]
    cmp w5, #'0'
    b.lo .Ljsn_err
    cmp w5, #'9'
    b.hi .Ljsn_err
.Ljsn_frac_loop:
    add x0, x0, #1
    cmp x0, x1
    b.hs .Ljsn_done
    ldrb w5, [x0]
    cmp w5, #'0'
    b.lo .Ljsn_done
    cmp w5, #'9'
    b.hi .Ljsn_done
    b .Ljsn_frac_loop
.Ljsn_exp:
    cmp w5, #'e'
    b.eq .Ljsn_exp_start
    cmp w5, #'E'
    b.eq .Ljsn_exp_start
    b .Ljsn_done
.Ljsn_exp_start:
    add x0, x0, #1
    cmp x0, x1
    b.hs .Ljsn_err
    ldrb w5, [x0]
    cmp w5, #'+'
    b.eq .Ljsn_exp_sign
    cmp w5, #'-'
    b.eq .Ljsn_exp_sign
    b .Ljsn_exp_digit
.Ljsn_exp_sign:
    add x0, x0, #1
    cmp x0, x1
    b.hs .Ljsn_err
    ldrb w5, [x0]
.Ljsn_exp_digit:
    cmp w5, #'0'
    b.lo .Ljsn_err
    cmp w5, #'9'
    b.hi .Ljsn_err
.Ljsn_exp_loop:
    add x0, x0, #1
    cmp x0, x1
    b.hs .Ljsn_done
    ldrb w5, [x0]
    cmp w5, #'0'
    b.lo .Ljsn_done
    cmp w5, #'9'
    b.hi .Ljsn_done
    b .Ljsn_exp_loop
.Ljsn_done:
    ret
.Ljsn_err:
    mov x0, #0
    ret

// ----------------------------------------------------------------------------
// json_scan_str(x0=p, x1=end, x2=cand, x3=clen) -> x0 = p' past the closing
//   quote (0 on error), x1 = 1 if the decoded string EQUALS cand[0..clen),
//   else 0 (cand == 0 means "no candidate": scan/skip only).
//   Full Go string-literal rules: escapes \" \\ \/ \b \f \n \r \t \uXXXX
//   (lower- and upper-case hex), surrogate pairs decoded but never matched
//   (non-ASCII cannot equal an ASCII candidate), raw bytes >= 0x80 advance
//   one byte at a time (safe: can never skip a closing quote), raw bytes
//   < 0x20 are errors (scanner.go: "invalid character ... in string
//   literal").  Matching is streaming: no buffer, so arbitrarily long
//   strings are handled like Go.
// ----------------------------------------------------------------------------
    .p2align 2
json_scan_str:
    cmp x0, x1
    b.hs .Ljss_err
    ldrb w6, [x0]
    cmp w6, #'"'
    b.ne .Ljss_err
    add x0, x0, #1
    mov x4, #0                  // i: position in the candidate
    mov x5, #1                  // ok: no mismatch yet
.Ljss_loop:
    cmp x0, x1
    b.hs .Ljss_err              // unterminated string
    ldrb w6, [x0]
    cmp w6, #'"'
    b.eq .Ljss_close
    cmp w6, #'\\'
    b.eq .Ljss_escape
    cmp w6, #0x20
    b.lo .Ljss_err              // raw control char in string
    cmp w6, #0x80
    b.hs .Ljss_utf8
    add x0, x0, #1              // advance past the byte
    b .Ljss_compare
.Ljss_escape:
    add x0, x0, #1              // past the backslash
    cmp x0, x1
    b.hs .Ljss_err
    ldrb w6, [x0]
    cmp w6, #'"'
    b.eq .Ljss_esc_plain
    cmp w6, #'\\'
    b.eq .Ljss_esc_plain
    cmp w6, #'/'
    b.eq .Ljss_esc_plain
    cmp w6, #'b'
    b.eq .Ljss_esc_short
    cmp w6, #'f'
    b.eq .Ljss_esc_short
    cmp w6, #'n'
    b.eq .Ljss_esc_short
    cmp w6, #'r'
    b.eq .Ljss_esc_short
    cmp w6, #'t'
    b.eq .Ljss_esc_short
    cmp w6, #'u'
    b.eq .Ljss_esc_unicode
    b .Ljss_err                 // bad escape code
.Ljss_esc_plain:
    add x0, x0, #1              // past the escaped char (decoded = w6)
    b .Ljss_compare
.Ljss_esc_short:
    cmp w6, #'b'
    b.eq .Ljss_short_b
    cmp w6, #'f'
    b.eq .Ljss_short_f
    cmp w6, #'n'
    b.eq .Ljss_short_n
    cmp w6, #'r'
    b.eq .Ljss_short_r
    mov w7, #9                  // 't' -> \t
    b .Ljss_short_got
.Ljss_short_b:
    mov w7, #8
    b .Ljss_short_got
.Ljss_short_f:
    mov w7, #12
    b .Ljss_short_got
.Ljss_short_n:
    mov w7, #10
    b .Ljss_short_got
.Ljss_short_r:
    mov w7, #13
.Ljss_short_got:
    mov w6, w7
    add x0, x0, #1              // past the escape letter
    b .Ljss_compare
.Ljss_esc_unicode:
    add x0, x0, #1              // past the 'u'
    sub x7, x1, x0
    cmp x7, #4
    b.lo .Ljss_err
    mov w6, #0                  // code point
    mov x7, #0                  // digit index
.Ljss_hex_loop:
    ldrb w8, [x0, x7]
    cmp w8, #'0'
    b.lo .Ljss_err
    cmp w8, #'9'
    b.hi .Ljss_hex_upper
    sub w8, w8, #'0'
    b .Ljss_hex_got
.Ljss_hex_upper:
    cmp w8, #'a'
    b.lo .Ljss_err
    cmp w8, #'f'
    b.hi .Ljss_err
    sub w8, w8, #('a' - 10)
.Ljss_hex_got:
    lsl w6, w6, #4
    orr w6, w6, w8
    add x7, x7, #1
    cmp x7, #4
    b.lo .Ljss_hex_loop
    add x0, x0, #4              // past the 4 hex digits
    cmp w6, #0x80
    b.hs .Ljss_nonascii         // decoded cp >= 0x80 cannot match an ASCII candidate
    b .Ljss_compare
.Ljss_utf8:
    mov x5, #0                  // raw non-ASCII never matches a candidate
    add x0, x0, #1              // one byte at a time (can never skip a quote)
    b .Ljss_loop
.Ljss_nonascii:
    mov x5, #0
    b .Ljss_loop
.Ljss_compare:                  // w6 = decoded ASCII; x0 already advanced
    cmp x5, #0
    b.eq .Ljss_loop
    cbz x2, .Ljss_loop          // no candidate: keep scanning
    cmp x4, x3
    b.hs .Ljss_overlong
    ldrb w7, [x2, x4]
    cmp w6, w7
    b.ne .Ljss_mismatch
    add x4, x4, #1
    b .Ljss_loop
.Ljss_overlong:
    mov x5, #0
    b .Ljss_loop
.Ljss_mismatch:
    mov x5, #0
    b .Ljss_loop
.Ljss_close:
    add x0, x0, #1              // past the closing quote
    mov x1, #0
    cbz x5, .Ljss_done
    cbz x2, .Ljss_done
    cmp x4, x3
    cset x1, eq                 // matched = (no mismatch && i == clen)
.Ljss_done:
    ret
.Ljss_err:
    mov x0, #0
    mov x1, #0
    ret

// ----------------------------------------------------------------------------
// json_skip_value(x0=p, x1=end) -> x0 = p' past ONE JSON value (any kind),
//   or 0 on error.  Used to skip unknown-key values with full validation.
//   State machine (state in x23): 0 EXPECT_VALUE, 1 EXPECT_FIRST_KEY,
//   2 EXPECT_KEY, 3 AFTER_VALUE.  Container nesting is tracked with a
//   depth counter (x21) plus a bit-stack (x22, bit i = level i is an
//   object), so nested objects/arrays need no recursion.  After a literal
//   the next byte is NOT inspected here (top-level trailing garbage is
//   accepted by Decoder.Decode); inside a container the caller's
//   ,/closer check catches stray bytes exactly like Go's scanner.
// ----------------------------------------------------------------------------
    .p2align 2
json_skip_value:
    PROLOGUE 3                  // x19 = p, x20 = end, x21 = depth, x22 = tstack, x23 = state
    mov x19, x0
    mov x20, x1
    mov x21, #0
    mov x22, #0
    mov x23, #0
.Ljsv_loop:
    cmp x23, #0
    b.eq .Ljsv_expect_value
    cmp x23, #1
    b.eq .Ljsv_expect_first
    cmp x23, #2
    b.eq .Ljsv_expect_key
    b .Ljsv_after_value
.Ljsv_expect_value:
    cmp x19, x20
    b.hs .Ljsv_err
    ldrb w5, [x19]
    cmp w5, #'"'
    b.eq .Ljsv_string
    cmp w5, #'{'
    b.eq .Ljsv_open_obj
    cmp w5, #'['
    b.eq .Ljsv_open_arr
    cmp w5, #'t'
    b.eq .Ljsv_true
    cmp w5, #'f'
    b.eq .Ljsv_false
    cmp w5, #'n'
    b.eq .Ljsv_null
    cmp w5, #'-'
    b.eq .Ljsv_number
    cmp w5, #'0'
    b.lo .Ljsv_err
    cmp w5, #'9'
    b.hi .Ljsv_err
    b .Ljsv_number
.Ljsv_string:
    mov x0, x19
    mov x1, x20
    mov x2, #0
    mov x3, #0
    bl json_scan_str
    cbz x0, .Ljsv_err
    mov x19, x0
    mov x23, #3
    b .Ljsv_loop
.Ljsv_open_obj:
    mov x6, #1
    lslv x6, x6, x21
    orr x22, x22, x6
    add x21, x21, #1
    add x19, x19, #1
    mov x23, #1
    b .Ljsv_loop
.Ljsv_open_arr:
    add x21, x21, #1
    add x19, x19, #1
    mov x23, #0
    b .Ljsv_loop
.Ljsv_true:
    mov x0, x19
    mov x1, x20
    LEA x2, json_s_true
    mov x3, #JSON_LIT_TRUE_LEN
    bl json_match_lit
    cbz x0, .Ljsv_err
    mov x19, x0
    mov x23, #3
    b .Ljsv_loop
.Ljsv_false:
    mov x0, x19
    mov x1, x20
    LEA x2, json_s_false
    mov x3, #JSON_LIT_FALSE_LEN
    bl json_match_lit
    cbz x0, .Ljsv_err
    mov x19, x0
    mov x23, #3
    b .Ljsv_loop
.Ljsv_null:
    mov x0, x19
    mov x1, x20
    LEA x2, json_s_null
    mov x3, #JSON_LIT_NULL_LEN
    bl json_match_lit
    cbz x0, .Ljsv_err
    mov x19, x0
    mov x23, #3
    b .Ljsv_loop
.Ljsv_number:
    mov x0, x19
    mov x1, x20
    bl json_skip_number
    cbz x0, .Ljsv_err
    mov x19, x0
    mov x23, #3
    b .Ljsv_loop
.Ljsv_expect_first:
    mov x0, x19
    mov x1, x20
    bl json_skip_ws
    mov x19, x0
    cmp x19, x20
    b.hs .Ljsv_err
    ldrb w5, [x19]
    cmp w5, #'}'
    b.eq .Ljsv_close
    b .Ljsv_key
.Ljsv_expect_key:
    mov x0, x19
    mov x1, x20
    bl json_skip_ws
    mov x19, x0
    cmp x19, x20
    b.hs .Ljsv_err
    ldrb w5, [x19]
    cmp w5, #'"'
    b.ne .Ljsv_err              // a '}' here is Go's trailing-comma error
.Ljsv_key:
    mov x0, x19
    mov x1, x20
    mov x2, #0
    mov x3, #0
    bl json_scan_str
    cbz x0, .Ljsv_err
    mov x19, x0
    mov x0, x19
    mov x1, x20
    bl json_skip_ws
    mov x19, x0
    cmp x19, x20
    b.hs .Ljsv_err
    ldrb w5, [x19]
    cmp w5, #':'
    b.ne .Ljsv_err
    add x19, x19, #1
    mov x23, #0
    b .Ljsv_loop
.Ljsv_close:
    add x19, x19, #1
    sub x21, x21, #1
    mov x6, #1
    lslv x6, x6, x21
    bic x22, x22, x6
    mov x23, #3
    b .Ljsv_loop
.Ljsv_after_value:
    cmp x21, #0
    b.eq .Ljsv_done
    mov x0, x19
    mov x1, x20
    bl json_skip_ws
    mov x19, x0
    cmp x19, x20
    b.hs .Ljsv_err
    ldrb w5, [x19]
    cmp w5, #','
    b.eq .Ljsv_comma
    sub x7, x21, #1
    lsrv x6, x22, x7
    and x6, x6, #1
    cbnz x6, .Ljsv_top_obj
    cmp w5, #']'
    b.eq .Ljsv_close
    b .Ljsv_err
.Ljsv_top_obj:
    cmp w5, #'}'
    b.eq .Ljsv_close
    b .Ljsv_err
.Ljsv_comma:
    add x19, x19, #1
    sub x7, x21, #1
    lsrv x6, x22, x7
    and x6, x6, #1
    cbnz x6, .Ljsv_comma_obj
    mov x23, #0
    b .Ljsv_loop
.Ljsv_comma_obj:
    mov x23, #2
    b .Ljsv_loop
.Ljsv_done:
    mov x0, x19
    EPILOGUE 3
    ret
.Ljsv_err:
    mov x0, #0
    EPILOGUE 3
    ret

// ----------------------------------------------------------------------------
// json_parse_pair(x0=p, x1=end, x2=out, x3=spec) -> x0 = p' at the value end
//   (the caller then handles ,/}), or 0 on error.  p is at the key's opening
//   quote.  Parses one "key":value pair: matches the key against the spec's
//   two entries, then stores the decoded value id (or CC_JSON_ID_UNKNOWN)
//   for a known key, no-ops on null, and fully skips unknown keys.  Value
//   strings are matched streaming against the entry's value table.
// ----------------------------------------------------------------------------
    .p2align 2
json_parse_pair:
    PROLOGUE 4                  // x19=out, x20=end, x21=p, x22=spec, x23=field, x24=vtbl, x25=outoff, x26=valstart
    mov x19, x2
    mov x20, x1
    mov x21, x0
    mov x22, x3
    mov x0, x21
    mov x1, x20
    ldr x2, [x22]
    ldr x3, [x22, #8]
    bl json_scan_str            // try spec entry 0's key
    cbz x0, .Ljpp_err
    cbnz x1, .Ljpp_field0
    mov x0, x21
    mov x1, x20
    ldr x2, [x22, #32]
    ldr x3, [x22, #40]
    bl json_scan_str            // try spec entry 1's key
    cbz x0, .Ljpp_err
    cbnz x1, .Ljpp_field1
    mov x21, x0                // unknown key: x0 = p' past the key string
    mov x23, #2
    b .Ljpp_after_key
.Ljpp_field0:
    mov x21, x0
    mov x23, #0
    b .Ljpp_known
.Ljpp_field1:
    mov x21, x0
    mov x23, #1
.Ljpp_known:
    add x6, x22, x23, lsl #5
    ldr x25, [x6, #16]          // out offset
    ldr x24, [x6, #24]          // value table
.Ljpp_after_key:
    mov x0, x21
    mov x1, x20
    bl json_skip_ws
    mov x21, x0
    cmp x21, x20
    b.hs .Ljpp_err
    ldrb w5, [x21]
    cmp w5, #':'
    b.ne .Ljpp_err
    add x21, x21, #1
    mov x0, x21
    mov x1, x20
    bl json_skip_ws
    mov x21, x0
    cmp x21, x20
    b.hs .Ljpp_err
    cmp x23, #2
    b.eq .Ljpp_unknown_val
    ldrb w5, [x21]
    cmp w5, #'"'
    b.eq .Ljpp_val_str
    cmp w5, #'n'
    b.eq .Ljpp_val_null
    b .Ljpp_err                 // Go: cannot unmarshal <kind> into the string field
.Ljpp_val_str:
    mov x26, x21                // value start (for rescans)
.Ljpp_val_loop:
    ldr x2, [x24]
    cbz x2, .Ljpp_val_unknown
    ldr x3, [x24, #8]
    mov x0, x26
    mov x1, x20
    bl json_scan_str
    cbz x0, .Ljpp_err
    cbnz x1, .Ljpp_val_matched
    add x24, x24, #24
    b .Ljpp_val_loop
.Ljpp_val_matched:
    ldr x7, [x24, #16]          // id
    str x7, [x19, x25]
    mov x21, x0
    b .Ljpp_done
.Ljpp_val_unknown:
    mov x0, x26
    mov x1, x20
    mov x2, #0
    mov x3, #0
    bl json_scan_str
    cbz x0, .Ljpp_err
    mov x7, #CC_JSON_ID_UNKNOWN
    str x7, [x19, x25]
    mov x21, x0
    b .Ljpp_done
.Ljpp_val_null:
    mov x0, x21
    mov x1, x20
    LEA x2, json_s_null
    mov x3, #JSON_LIT_NULL_LEN
    bl json_match_lit
    cbz x0, .Ljpp_err
    mov x21, x0                // null for a string field: no-op (field unchanged)
    b .Ljpp_done
.Ljpp_unknown_val:
    mov x0, x21
    mov x1, x20
    bl json_skip_value
    mov x21, x0
    cbz x21, .Ljpp_err
.Ljpp_done:
    mov x0, x21
    EPILOGUE 4
    ret
.Ljpp_err:
    mov x0, #0
    EPILOGUE 4
    ret

// ----------------------------------------------------------------------------
// json_parse_obj(x0=json, x1=len, x2=out, x3=spec) -> x0 = 0 ok / -1 error.
//   Port of json.Decoder.Decode into a two-field struct: leading whitespace,
//   top-level null -> ok (fields untouched), an object with known/unknown
//   keys, duplicate keys last-wins (each occurrence overwrites the field),
//   and trailing garbage after the object ACCEPTED (Decode reads one value).
//   Both fields are pre-filled with CC_JSON_ID_UNKNOWN (an absent key or a
//   null value is Go's zero string "", which matches no route); valid string
//   values overwrite the field.  The caller passes the out struct without
//   zeroing it.
// ----------------------------------------------------------------------------
    .p2align 2
json_parse_obj:
    PROLOGUE 3                  // x19=out, x20=end, x21=p, x22=spec, x23=first
    mov x19, x2
    mov x22, x3
    // Pre-fill both fields with CC_JSON_ID_UNKNOWN: an absent key or a null
    // value leaves the field at this sentinel, exactly like Go's zero string
    // "" (which matches no route).  Valid string values overwrite it.
    ldr x7, [x22, #16]          // spec[0].out offset
    mov x8, #CC_JSON_ID_UNKNOWN
    str x8, [x19, x7]
    ldr x7, [x22, #48]          // spec[1].out offset
    str x8, [x19, x7]
    add x20, x0, x1
    mov x21, x0
    cbz x1, .Ljpo_err           // empty input -> Go's EOF error
    mov x0, x21
    mov x1, x20
    bl json_skip_ws
    mov x21, x0
    cmp x21, x20
    b.hs .Ljpo_err              // whitespace only -> EOF error
    ldrb w5, [x21]
    cmp w5, #'n'
    b.eq .Ljpo_null
    cmp w5, #'{'
    b.ne .Ljpo_err              // Go: cannot unmarshal <kind> into the struct
    add x21, x21, #1
    mov x23, #1                 // first: a '}' is allowed only before any pair
.Ljpo_loop:
    mov x0, x21
    mov x1, x20
    bl json_skip_ws
    mov x21, x0
    cmp x21, x20
    b.hs .Ljpo_err
    ldrb w5, [x21]
    cmp w5, #'}'
    b.ne .Ljpo_key
    cbnz x23, .Ljpo_ok          // empty object
    b .Ljpo_err                 // trailing comma (Go: '}' looking for key)
.Ljpo_key:
    cmp w5, #'"'
    b.ne .Ljpo_err
    mov x0, x21
    mov x1, x20
    mov x2, x19
    mov x3, x22
    bl json_parse_pair
    mov x21, x0
    cbz x21, .Ljpo_err
    mov x0, x21
    mov x1, x20
    bl json_skip_ws
    mov x21, x0
    cmp x21, x20
    b.hs .Ljpo_err
    ldrb w5, [x21]
    cmp w5, #','
    b.eq .Ljpo_comma
    cmp w5, #'}'
    b.eq .Ljpo_ok
    b .Ljpo_err
.Ljpo_comma:
    add x21, x21, #1
    mov x23, #0
    b .Ljpo_loop
.Ljpo_null:
    mov x0, x21
    mov x1, x20
    LEA x2, json_s_null
    mov x3, #JSON_LIT_NULL_LEN
    bl json_match_lit
    cbz x0, .Ljpo_err
    mov x0, #0                  // null -> ok, fields untouched, trailing ignored
    EPILOGUE 3
    ret
.Ljpo_ok:
    mov x0, #0
    EPILOGUE 3
    ret
.Ljpo_err:
    mov x0, #-1
    EPILOGUE 3
    ret

// ----------------------------------------------------------------------------
// json_utf8_copy(x0=buf, x1=s, x2=len, x3=seqlen) -> x0 = buf' (0 if the
//   seqlen-byte sequence at s is not valid UTF-8), x1 = s+seqlen,
//   x2 = len-seqlen.  Validates the seqlen-1 continuation bytes (0x80..0xbf)
//   exactly as utf8.DecodeRune does, then copies the sequence as-is.
// ----------------------------------------------------------------------------
    .p2align 2
json_utf8_copy:
    cmp x2, x3
    b.lo .Ljuc_bad
    mov x4, #1
.Ljuc_cont_loop:
    cmp x4, x3
    b.hs .Ljuc_valid
    ldrb w5, [x1, x4]
    cmp w5, #0x80
    b.lo .Ljuc_bad
    cmp w5, #0xbf
    b.hi .Ljuc_bad
    add x4, x4, #1
    b .Ljuc_cont_loop
.Ljuc_valid:
    mov x4, #0
.Ljuc_copy_loop:
    cmp x4, x3
    b.hs .Ljuc_done
    ldrb w5, [x1, x4]
    strb w5, [x0, x4]
    add x4, x4, #1
    b .Ljuc_copy_loop
.Ljuc_done:
    add x0, x0, x3
    add x1, x1, x3
    sub x2, x2, x3
    ret
.Ljuc_bad:
    mov x0, #0
    ret

// ----------------------------------------------------------------------------
// json_escape(x0=buf, x1=s, x2=len) -> x0 = buf'  (escaped content, NO
//   surrounding quotes).  Byte-exact port of Go's appendString with
//   escapeHTML = true (encode.go:999-1066): " -> \", \ -> \\, \b\f\n\r\t
//   short escapes, other < 0x20 and < > & -> \u00XX (lowercase hex), DEL
//   passed through, U+2028/U+2029 -> \u2028/\u2029, valid UTF-8 copied,
//   invalid bytes -> the literal "\ufffd" (one per invalid byte).
//   PROLOGUE 1: x19 holds the CURRENT buf across the `bl json_utf8_copy`
//   (whose x0 return is 0 on an invalid sequence — the bad-UTF-8 path must
//   still write "\ufffd" to the original buf, not to 0).  x30 is preserved
//   by PROLOGUE 1 as well (json_escape rets at the done label long after
//   the utf8-path bl, so the link register must be restored, not left as
//   the bl's return address).
// ----------------------------------------------------------------------------
    .p2align 2
json_escape:
    PROLOGUE 1                  // x19 = buf (across the utf8_copy bl)
.Lje_loop:
    cbz x2, .Lje_done
    ldrb w4, [x1]
    cmp w4, #0x20
    b.lo .Lje_ctrl
    cmp w4, #0x80
    b.hs .Lje_utf8
    cmp w4, #'"'
    b.eq .Lje_quote
    cmp w4, #'\\'
    b.eq .Lje_quote
    cmp w4, #'&'
    b.eq .Lje_u00xx
    cmp w4, #'<'
    b.eq .Lje_u00xx
    cmp w4, #'>'
    b.eq .Lje_u00xx
    strb w4, [x0]
    add x0, x0, #1
    add x1, x1, #1
    sub x2, x2, #1
    b .Lje_loop
.Lje_ctrl:
    sub w5, w4, #8
    cmp w5, #6
    b.hs .Lje_u00xx
    cmp w4, #11
    b.eq .Lje_u00xx
    LEA x6, json_short_map
    ldrb w5, [x6, x5]
    mov w6, #'\\'
    strb w6, [x0]
    strb w5, [x0, #1]
    add x0, x0, #2
    add x1, x1, #1
    sub x2, x2, #1
    b .Lje_loop
.Lje_quote:
    mov w5, #'\\'
    strb w5, [x0]
    strb w4, [x0, #1]
    add x0, x0, #2
    add x1, x1, #1
    sub x2, x2, #1
    b .Lje_loop
.Lje_u00xx:
    LEA x5, json_hex
    mov w6, #'\\'
    strb w6, [x0]
    mov w6, #'u'
    strb w6, [x0, #1]
    mov w6, #'0'
    strb w6, [x0, #2]
    strb w6, [x0, #3]
    lsr w6, w4, #4
    ldrb w6, [x5, x6]
    strb w6, [x0, #4]
    and w6, w4, #0xf
    ldrb w6, [x5, x6]
    strb w6, [x0, #5]
    add x0, x0, #6
    add x1, x1, #1
    sub x2, x2, #1
    b .Lje_loop
.Lje_utf8:
    mov x19, x0                 // current buf for the bad-utf8 path
    cmp w4, #0xc2
    b.lo .Lje_bad_utf8
    cmp w4, #0xdf
    b.ls .Lje_utf8_2
    cmp w4, #0xef
    b.ls .Lje_utf8_3
    cmp w4, #0xf4
    b.ls .Lje_utf8_4
    b .Lje_bad_utf8
.Lje_utf8_2:
    mov x3, #2
    b .Lje_utf8_call
.Lje_utf8_3:
    cmp x2, #3
    b.lo .Lje_bad_utf8
    ldrb w5, [x1, #1]
    cmp w5, #0x80
    b.lo .Lje_bad_utf8
    cmp w5, #0xbf
    b.hi .Lje_bad_utf8
    ldrb w6, [x1, #2]
    cmp w6, #0x80
    b.lo .Lje_bad_utf8
    cmp w6, #0xbf
    b.hi .Lje_bad_utf8
    // U+2028 (e2 80 a8) / U+2029 (e2 80 a9) are escaped unconditionally
    // (encode.go:1047-1060) — write \u2028 / \u2029 instead of the bytes.
    cmp w4, #0xe2
    b.ne .Lje_u3_copy
    cmp w5, #0x80
    b.ne .Lje_u3_copy
    cmp w6, #0xa8
    b.eq .Lje_u2028
    cmp w6, #0xa9
    b.eq .Lje_u2029
.Lje_u3_copy:
    ldrb w5, [x1]
    strb w5, [x0]
    ldrb w5, [x1, #1]
    strb w5, [x0, #1]
    ldrb w5, [x1, #2]
    strb w5, [x0, #2]
    add x0, x0, #3
    add x1, x1, #3
    sub x2, x2, #3
    b .Lje_loop
.Lje_u2028:
    mov w5, #'8'
    b .Lje_u202x
.Lje_u2029:
    mov w5, #'9'
.Lje_u202x:
    mov w6, #'\\'
    strb w6, [x0]
    mov w6, #'u'
    strb w6, [x0, #1]
    mov w6, #'2'
    strb w6, [x0, #2]
    mov w6, #'0'
    strb w6, [x0, #3]
    mov w6, #'2'
    strb w6, [x0, #4]
    strb w5, [x0, #5]
    add x0, x0, #6
    add x1, x1, #3
    sub x2, x2, #3
    b .Lje_loop
.Lje_utf8_4:
    mov x3, #4
.Lje_utf8_call:
    mov x19, x0                 // current buf (json_utf8_copy returns 0 on invalid)
    bl json_utf8_copy           // x0=buf, x1=s, x2=len, x3=seqlen
    cbz x0, .Lje_bad_utf8
    b .Lje_loop
.Lje_bad_utf8:
    mov x0, x19                 // restore buf: write "\ufffd" at the ORIGINAL position
    LEA x5, json_esc_ufffd
    ldr w6, [x5]
    str w6, [x0]
    ldrh w6, [x5, #4]
    strh w6, [x0, #4]
    add x0, x0, #6
    add x1, x1, #1
    sub x2, x2, #1
    b .Lje_loop
.Lje_done:
    EPILOGUE 1
    ret

// ----------------------------------------------------------------------------
// json_quote_escape(x0=buf, x1=s, x2=len) -> x0 = buf'  ("<escaped>")
//   PROLOGUE 0 preserves x30 across the `bl json_escape`: a function that
//   calls another via bl and then rets MUST restore x30 before the ret
//   (AAPCS64; a bare ret would use the bl's return address and loop).
// ----------------------------------------------------------------------------
    .p2align 2
json_quote_escape:
    PROLOGUE 0
    mov w5, #'"'
    strb w5, [x0]
    add x0, x0, #1
    bl json_escape
    mov w5, #'"'
    strb w5, [x0]
    add x0, x0, #1
    EPILOGUE 0
    ret

// ----------------------------------------------------------------------------
// json_id_str(x0=buf, x1=id, x2=table) -> x0 = buf'  (escaped string for the
//   id looked up in the {ptr,len} table; tail-calls cc_json_str).
// ----------------------------------------------------------------------------
    .p2align 2
json_id_str:
    add x3, x2, x1, lsl #4
    ldr x1, [x3]
    ldr x2, [x3, #8]
    b cc_json_str

// ----------------------------------------------------------------------------
// json_obj_path_entry(x0=buf, x1=name, x2=status, x3=names tbl) -> x0 = buf'
//   Writes "name":<status-string> for one paths-map entry.
// ----------------------------------------------------------------------------
    .p2align 2
json_obj_path_entry:
    PROLOGUE 3                  // x19=buf, x20=name, x21=status, x22=names tbl
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x0, x20
    bl cc_strlen                // x0 = name length
    mov x2, x0
    mov x0, x19
    mov x1, x20
    bl cc_json_str
    mov x19, x0
    mov w5, #':'
    strb w5, [x19]
    add x19, x19, #1
    mov x0, x19
    mov x1, x21
    mov x2, x22
    bl json_id_str
    mov x19, x0
    mov x0, x19
    EPILOGUE 3
    ret

// ----------------------------------------------------------------------------
// json_obj_stage_entry(x0=buf, x1=name, x2=desired, x3=actual) -> x0 = buf'
//   Writes "name":{"desired":<d>,"actual":<a>} for one stages-map entry.
// ----------------------------------------------------------------------------
    .p2align 2
json_obj_stage_entry:
    PROLOGUE 4                  // x19=buf, x20=name, x21=desired, x22=actual
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x0, x20
    bl cc_strlen
    mov x2, x0
    mov x0, x19
    mov x1, x20
    bl cc_json_str
    mov x19, x0
    mov w5, #':'
    strb w5, [x19]
    add x19, x19, #1
    mov w5, #'{'
    strb w5, [x19]
    add x19, x19, #1
    mov x0, x19
    LEA x1, json_s_desired
    mov x2, #JSON_KEY_DESIRED_LEN
    bl cc_json_key_str
    mov x19, x0
    mov x0, x19
    mov x1, x21
    LEA x2, json_state_names
    bl json_id_str
    mov x19, x0
    mov x0, x19
    mov x1, #0
    bl cc_json_sep
    mov x19, x0
    mov x0, x19
    LEA x1, json_s_actual
    mov x2, #JSON_KEY_ACTUAL_LEN
    bl cc_json_key_str
    mov x19, x0
    mov x0, x19
    mov x1, x22
    LEA x2, json_state_names
    bl json_id_str
    mov x19, x0
    mov w5, #'}'
    strb w5, [x19]
    add x19, x19, #1
    mov x0, x19
    EPILOGUE 4
    ret

// ----------------------------------------------------------------------------
// json_obj_paths(x0=buf, x1=paths tbl) -> x0 = buf'
//   Writes { "name":<status>, ... } — the paths map object, braces included.
// ----------------------------------------------------------------------------
    .p2align 2
json_obj_paths:
    PROLOGUE 4                  // x19=buf, x20=tbl, x21=count, x22=entry, x23=first
    mov x19, x0
    mov x20, x1
    mov w5, #'{'
    strb w5, [x19]
    add x19, x19, #1
    ldr x21, [x20]
    add x22, x20, #8
    mov x23, #1
.Ljop_loop:
    cbz x21, .Ljop_done
    mov x0, x19
    mov x1, x23
    bl cc_json_sep
    mov x19, x0
    mov x23, #0
    mov x0, x19
    ldr x1, [x22]
    ldr x2, [x22, #8]
    LEA x3, json_status_names
    bl json_obj_path_entry
    mov x19, x0
    add x22, x22, #CC_JSON_PTBL_ENTRY
    sub x21, x21, #1
    b .Ljop_loop
.Ljop_done:
    mov w5, #'}'
    strb w5, [x19]
    add x19, x19, #1
    mov x0, x19
    EPILOGUE 4
    ret

// ----------------------------------------------------------------------------
// json_obj_stages(x0=buf, x1=stages tbl) -> x0 = buf'
//   Writes { "name":{"desired":<d>,"actual":<a>}, ... } — braces included.
// ----------------------------------------------------------------------------
    .p2align 2
json_obj_stages:
    PROLOGUE 4                  // x19=buf, x20=tbl, x21=count, x22=entry, x23=first
    mov x19, x0
    mov x20, x1
    mov w5, #'{'
    strb w5, [x19]
    add x19, x19, #1
    ldr x21, [x20]
    add x22, x20, #8
    mov x23, #1
.Ljos_loop:
    cbz x21, .Ljos_done
    mov x0, x19
    mov x1, x23
    bl cc_json_sep
    mov x19, x0
    mov x23, #0
    mov x0, x19
    ldr x1, [x22]
    ldr x2, [x22, #8]
    ldr x3, [x22, #16]
    bl json_obj_stage_entry
    mov x19, x0
    add x22, x22, #CC_JSON_STBL_ENTRY
    sub x21, x21, #1
    b .Ljos_loop
.Ljos_done:
    mov w5, #'}'
    strb w5, [x19]
    add x19, x19, #1
    mov x0, x19
    EPILOGUE 4
    ret

// ============================================================================
// Exported functions
// ============================================================================

// ----------------------------------------------------------------------------
// cc_json_str — write "s" with full Go escaping.
// ----------------------------------------------------------------------------
    .p2align 2
    .global cc_json_str
    FUNC_TYPE(cc_json_str)
cc_json_str:
    b json_quote_escape

// ----------------------------------------------------------------------------
// cc_json_key_str — write "key": with full Go escaping of the key.
//   PROLOGUE 0 preserves x30 across the `bl json_quote_escape`.
// ----------------------------------------------------------------------------
    .p2align 2
    .global cc_json_key_str
    FUNC_TYPE(cc_json_key_str)
cc_json_key_str:
    PROLOGUE 0
    bl json_quote_escape
    mov w5, #JSON_CH_COLON
    strb w5, [x0]
    add x0, x0, #1
    EPILOGUE 0
    ret

// ----------------------------------------------------------------------------
// cc_json_u8 — write the decimal digits of v (0..255), no leading zeros,
//   no quotes (matches strconv.FormatUint(uint64(v), 10)).
// ----------------------------------------------------------------------------
    .p2align 2
    .global cc_json_u8
    FUNC_TYPE(cc_json_u8)
cc_json_u8:
    mov w5, #100
    udiv w6, w1, w5
    cbz w6, .Lcju_tens_skip
    add w7, w6, #'0'
    strb w7, [x0]
    add x0, x0, #1
    msub w1, w6, w5, w1
    b .Lcju_tens_write
.Lcju_tens_skip:
    cmp w1, #10
    b.lo .Lcju_units
.Lcju_tens_write:
    mov w5, #10
    udiv w6, w1, w5
    add w7, w6, #'0'
    strb w7, [x0]
    add x0, x0, #1
    msub w1, w6, w5, w1
.Lcju_units:
    add w7, w1, #'0'
    strb w7, [x0]
    add x0, x0, #1
    ret

// ----------------------------------------------------------------------------
// cc_json_sep — write ',' when first == 0 (buf + 1); leave buf untouched
//   when first == 1.  The caller's "first element" flag pattern.
// ----------------------------------------------------------------------------
    .p2align 2
    .global cc_json_sep
    FUNC_TYPE(cc_json_sep)
cc_json_sep:
    cbnz x1, .Lcjs_done
    mov w5, #JSON_CH_COMMA
    strb w5, [x0]
    add x0, x0, #1
.Lcjs_done:
    ret

// ----------------------------------------------------------------------------
// cc_json_path_event — {"path":<path-name>,"status":<status>}
// ----------------------------------------------------------------------------
    .p2align 2
    .global cc_json_path_event
    FUNC_TYPE(cc_json_path_event)
cc_json_path_event:
    PROLOGUE 2                  // x19 = buf, x20 = pe
    mov x19, x0
    mov x20, x1
    mov w5, #JSON_CH_OBJ_OPEN
    strb w5, [x19]
    add x19, x19, #1
    mov x0, x19
    LEA x1, json_s_path
    mov x2, #JSON_KEY_PATH_LEN
    bl cc_json_key_str
    mov x19, x0
    mov x0, x19
    ldr x1, [x20, CC_PE_PATH]
    LEA x2, json_path_names
    bl json_id_str
    mov x19, x0
    mov x0, x19
    mov x1, #0
    bl cc_json_sep
    mov x19, x0
    mov x0, x19
    LEA x1, json_s_status
    mov x2, #JSON_KEY_STATUS_LEN
    bl cc_json_key_str
    mov x19, x0
    mov x0, x19
    ldr x1, [x20, CC_PE_STATUS]
    LEA x2, json_status_names
    bl json_id_str
    mov x19, x0
    mov w5, #JSON_CH_OBJ_CLOSE
    strb w5, [x19]
    add x19, x19, #1
    mov x0, x19
    EPILOGUE 2
    ret

// ----------------------------------------------------------------------------
// cc_json_stage_event — {"stage":<stage-name>,"state":<state>}
// ----------------------------------------------------------------------------
    .p2align 2
    .global cc_json_stage_event
    FUNC_TYPE(cc_json_stage_event)
cc_json_stage_event:
    PROLOGUE 2                  // x19 = buf, x20 = se
    mov x19, x0
    mov x20, x1
    mov w5, #JSON_CH_OBJ_OPEN
    strb w5, [x19]
    add x19, x19, #1
    mov x0, x19
    LEA x1, json_s_stage
    mov x2, #JSON_KEY_STAGE_LEN
    bl cc_json_key_str
    mov x19, x0
    mov x0, x19
    ldr x1, [x20, CC_SE_STAGE]
    LEA x2, json_stage_names
    bl json_id_str
    mov x19, x0
    mov x0, x19
    mov x1, #0
    bl cc_json_sep
    mov x19, x0
    mov x0, x19
    LEA x1, json_s_state
    mov x2, #JSON_KEY_STATE_LEN
    bl cc_json_key_str
    mov x19, x0
    mov x0, x19
    ldr x1, [x20, CC_SE_STATE]
    LEA x2, json_state_names
    bl json_id_str
    mov x19, x0
    mov w5, #JSON_CH_OBJ_CLOSE
    strb w5, [x19]
    add x19, x19, #1
    mov x0, x19
    EPILOGUE 2
    ret

// ----------------------------------------------------------------------------
// cc_json_control_cmd — {"component":<component>,"action":<action>}
// ----------------------------------------------------------------------------
    .p2align 2
    .global cc_json_control_cmd
    FUNC_TYPE(cc_json_control_cmd)
cc_json_control_cmd:
    PROLOGUE 2                  // x19 = buf, x20 = cmd
    mov x19, x0
    mov x20, x1
    mov w5, #JSON_CH_OBJ_OPEN
    strb w5, [x19]
    add x19, x19, #1
    mov x0, x19
    LEA x1, json_s_component
    mov x2, #JSON_KEY_COMPONENT_LEN
    bl cc_json_key_str
    mov x19, x0
    mov x0, x19
    ldr x1, [x20, CC_CMD_COMPONENT]
    LEA x2, json_component_names
    bl json_id_str
    mov x19, x0
    mov x0, x19
    mov x1, #0
    bl cc_json_sep
    mov x19, x0
    mov x0, x19
    LEA x1, json_s_action
    mov x2, #JSON_KEY_ACTION_LEN
    bl cc_json_key_str
    mov x19, x0
    mov x0, x19
    ldr x1, [x20, CC_CMD_ACTION]
    LEA x2, json_action_names
    bl json_id_str
    mov x19, x0
    mov w5, #JSON_CH_OBJ_CLOSE
    strb w5, [x19]
    add x19, x19, #1
    mov x0, x19
    EPILOGUE 2
    ret

// ----------------------------------------------------------------------------
// cc_json_status — {"paths":{...},"stages":{...}}
//   x2/x3: counted paths/stages tables (cc_json.h layout), entries in
//   ascending name order (Go's sorted-map output); count 0 emits "{}".
// ----------------------------------------------------------------------------
    .p2align 2
    .global cc_json_status
    FUNC_TYPE(cc_json_status)
cc_json_status:
    PROLOGUE 3                  // x19 = buf, x20 = paths tbl, x21 = stages tbl
    mov x19, x0
    mov x20, x2
    mov x21, x3
    mov w5, #JSON_CH_OBJ_OPEN
    strb w5, [x19]
    add x19, x19, #1
    mov x0, x19
    LEA x1, json_s_paths
    mov x2, #JSON_KEY_PATHS_LEN
    bl cc_json_key_str
    mov x19, x0
    mov x0, x19
    mov x1, x20
    bl json_obj_paths
    mov x19, x0
    mov x0, x19
    mov x1, #0
    bl cc_json_sep
    mov x19, x0
    mov x0, x19
    LEA x1, json_s_stages
    mov x2, #JSON_KEY_STAGES_LEN
    bl cc_json_key_str
    mov x19, x0
    mov x0, x19
    mov x1, x21
    bl json_obj_stages
    mov x19, x0
    mov w5, #JSON_CH_OBJ_CLOSE
    strb w5, [x19]
    add x19, x19, #1
    mov x0, x19
    EPILOGUE 3
    ret

// ----------------------------------------------------------------------------
// cc_json_parse_control — decode a ControlCommand (POST /control).
//   x0 = 0 ok / -1 error; out = {u64 component id, u64 action id}.
// ----------------------------------------------------------------------------
    .p2align 2
    .global cc_json_parse_control
    FUNC_TYPE(cc_json_parse_control)
cc_json_parse_control:
    LEA x3, json_spec_control
    b json_parse_obj

// ----------------------------------------------------------------------------
// cc_json_parse_path_event — decode a PathEvent (POST /event).
//   x0 = 0 ok / -1 error; out = {u64 path id, u64 status id}.
// ----------------------------------------------------------------------------
    .p2align 2
    .global cc_json_parse_path_event
    FUNC_TYPE(cc_json_parse_path_event)
cc_json_parse_path_event:
    LEA x3, json_spec_path_event
    b json_parse_obj

    .text
    .end