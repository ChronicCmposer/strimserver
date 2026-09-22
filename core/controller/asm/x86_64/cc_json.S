// ============================================================================
// cc_json.S — JSON encode/decode for the strimserver controller (x86-64 port)
// ============================================================================
//
//  Target:     x86-64 (SysV AMD64), little-endian — Linux (ELF, static);
//              cc_platform_x86_64.h is the only platform header (Linux-only).
//  Assembler:  GNU as AT&T syntax, preprocessed by the C compiler
//              (`cc -c -x assembler-with-cpp`).
//  ISA:        floor x86-64-v4, cap AVX2 (no zmm/k/AMX, no AVX-512);
//              target g4dn.xlarge.  There is no in-source .arch directive on
//              x86 GAS (that is an ARM concept); the floor/cap are enforced
//              by the BUILD copts and by check-isa-x86_64.sh scanning the
//              disassembly.
//
//  This module is the x86-64 translation of the AArch64 cc_json.S: the L1
//  json layer porting Go's encoding/json (v1, the classic package) for the
//  controller's wire payloads.  It is byte-exact against the Go reference
//  for every payload the controller speaks, and its decoder matches
//  json.Decoder.Decode (the call site).  The JSON decisions are documented
//  in full in the AArch64 original (field order, sorted map keys,
//  escapeHTML = true, \u00XX lowercase hex, U+2028/U+2029, invalid-UTF-8 ->
//  the literal "\ufffd", Decoder.Decode leading-ws / trailing-garbage /
//  duplicate-key-last-wins / null-no-op semantics).  TRANSLATION ONLY: the
//  control flow and the emitted bytes are preserved exactly.
//
//  Exported (all .global, SysV, %rbx/%rbp/%r12-%r15 preserved):
//    cc_json_sep(rdi=buf, esi=first) -> rax = buf (first==1) or buf+1 (',')
//    cc_json_str(rdi=buf, rsi=s, rdx=len) -> rax = buf'  ("<escaped>")
//    cc_json_key_str(rdi=buf, rsi=key, rdx=len) -> rax = buf'  ("<escaped>":)
//    cc_json_u8(rdi=buf, esi=v) -> rax = buf'  (decimal digits, no leading 0)
//    cc_json_path_event(rdi=buf, rsi=CC_PE_* ptr)  -> rax = buf'
//    cc_json_stage_event(rdi=buf, rsi=CC_SE_* ptr) -> rax = buf'
//    cc_json_status(rdi=buf, rsi=CC_CS_* ptr, rdx=paths tbl, rcx=stages tbl)
//                                    -> rax = buf'
//    cc_json_control_cmd(rdi=buf, rsi=CC_CMD_* ptr) -> rax = buf'
//    cc_json_parse_control(rdi=json, rsi=len, rdx=CC_CMD_* out)
//                                    -> rax = 0 ok / -1 error
//    cc_json_parse_path_event(rdi=json, rsi=len, rdx=CC_PE_* out)
//                                    -> rax = 0 ok / -1 error
//
//  ABI mapping (AArch64 -> x86-64): x0->%rdi, x1->%rsi, x2->%rdx, x3->%rcx;
//  return %rax (%rdx for the second return of the multi-value helpers);
//  x19-x28/x29 -> %rbx/%rbp/%r12-%r15.  The AArch64 helpers held up to eight
//  callee-saved registers across `bl`s; SysV gives only five (%rbx, %r12-
//  %r15), so the excess state spills to the stack across `call`s:
//    * json_skip_value keeps depth/tstack/state in a 32-byte frame
//      (0(%rsp) depth, 8(%rsp) tstack, 16(%rsp) state); its sub-helpers
//      receive pointers to those slots and update them in place.
//    * json_parse_pair's value-loop state (vtbl/outoff/valstart) lives in
//      the json_parse_pair_value helper's own callee-saved set; the parent
//      passes field/vtbl/outoff as arguments to json_parse_pair_after_key.
//
//  Splits for the <= 80-instruction gate (each split is a FULL SysV
//  function at a natural .L boundary of the AArch64 original):
//    * json_skip_number   -> json_skip_number_frac, json_skip_number_exp
//                            (the digit loops, tail-jumped with p/end)
//    * json_scan_str      -> json_scan_str_escape (one escape sequence:
//                            \" \\ \/ \b \f \n \r \t \uXXXX -> decoded byte)
//    * json_skip_value    -> json_skip_value_value (byte dispatch),
//                            json_skip_value_lit (true/false/null),
//                            json_skip_value_key (states 1/2: skip_ws, key
//                            string, ':', or empty-object close),
//                            json_skip_value_after (state 3: comma/closer
//                            against the nesting bit-stack)
//    * json_parse_pair    -> json_parse_pair_after_key ('+'/':'/value
//                            dispatch), json_parse_pair_value (the vtbl
//                            match loop + unknown-id store)
//    * json_parse_obj     -> json_parse_obj_iter (one "key":value pair plus
//                            the ,/} separator check; returns rdx = 1
//                            continue / 0 ok / -1 err)
//    * json_escape        -> json_escape_ctrl, json_escape_quote,
//                            json_escape_u00xx, json_escape_ufffd,
//                            json_escape_utf8_3 (the U+2028/U+2029 and
//                            3-byte-valid sequence handling)
//
//  SysV AMD64 notes (the rules every module must follow)
//  ----------------------------------------------------
//    * Arguments in %rdi, %rsi, %rdx, %rcx, %r8, %r9; return in %rax
//      (%rdx for a second return value).  Callee-saved (must be preserved
//      across any `call`): %rbx, %rbp, %r12-%r15.  %rsp must stay 16-byte
//      aligned at every call site.
//    * `call` pushes the return address (the SysV link) and `ret` pops it;
//      only `jmp` is a tail call.  Never join statements with ';' — it is a
//      statement separator in GNU-as x86 syntax; this project's dialect uses
//      `//` comments and one instruction per line.
//
// ============================================================================

#include "cc_platform_x86_64.h"
#include "../cc_layout.inc"
#include "../cc_json.h"
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
// json_skip_ws(rdi=p, rsi=end) -> rax = p' (first non-space byte or end).
//   Go's Decoder skips space, \t, \n, \r (decode.go isSpace).
// ----------------------------------------------------------------------------
    .p2align 4
json_skip_ws:
.Ljsw_loop:
    cmp %rsi, %rdi
    jae .Ljsw_done
    movzbl (%rdi), %r8d
    cmp $' ', %r8d
    je .Ljsw_adv
    cmp $'\t', %r8d
    je .Ljsw_adv
    cmp $'\n', %r8d
    je .Ljsw_adv
    cmp $'\r', %r8d
    je .Ljsw_adv
    jmp .Ljsw_done
.Ljsw_adv:
    inc %rdi
    jmp .Ljsw_loop
.Ljsw_done:
    mov %rdi, %rax
    ret

// ----------------------------------------------------------------------------
// json_match_lit(rdi=p, rsi=end, rdx=lit, rcx=len) -> rax = p' past the
//   literal, or 0 on mismatch/truncation.  Matches the literal EXACTLY (the
//   byte after the literal is deliberately not inspected: Decoder.Decode
//   reads one value and never scans past it).
// ----------------------------------------------------------------------------
    .p2align 4
json_match_lit:
    mov %rsi, %r8
    sub %rdi, %r8                   // %r8 = end - p (available length)
    cmp %rcx, %r8
    jb .Ljml_err
    xor %r9d, %r9d                  // i = 0
.Ljml_loop:
    cmp %rcx, %r9
    je .Ljml_ok
    movzbl (%rdi,%r9), %r10d        // p[i]
    cmp %r10b, (%rdx,%r9)           // p[i] == lit[i]?
    jne .Ljml_err
    inc %r9
    jmp .Ljml_loop
.Ljml_ok:
    lea (%rdi,%rcx), %rax           // rax = p + len
    ret
.Ljml_err:
    xor %eax, %eax
    ret

// ----------------------------------------------------------------------------
// json_skip_number(rdi=p, rsi=end) -> rax = p' past the number, or 0 on
//   error.  JSON number grammar as the Go scanner accepts it:
//   -?(0|[1-9][0-9]*) (\. [0-9]+)? ([eE][+-]?[0-9]+)?  (scanner.go
//   stateInNumber).  The fraction/exponent digit loops are split into
//   json_skip_number_frac / json_skip_number_exp (tail-jumped, <= 80 gate).
// ----------------------------------------------------------------------------
    .p2align 4
json_skip_number:
    cmp %rsi, %rdi
    jae .Ljsn_err
    movzbl (%rdi), %r8d
    cmp $'-', %r8d
    jne .Ljsn_int
    inc %rdi
    cmp %rsi, %rdi
    jae .Ljsn_err
    movzbl (%rdi), %r8d
.Ljsn_int:
    cmp $'0', %r8d
    jb .Ljsn_err
    cmp $'9', %r8d
    ja .Ljsn_err
    inc %rdi
.Ljsn_int_loop:
    cmp %rsi, %rdi
    jae .Ljsn_frac
    movzbl (%rdi), %r8d
    cmp $'0', %r8d
    jb .Ljsn_frac
    cmp $'9', %r8d
    ja .Ljsn_frac
    inc %rdi
    jmp .Ljsn_int_loop
.Ljsn_frac:
    cmp %rsi, %rdi
    jae .Ljsn_done
    movzbl (%rdi), %r8d
    cmp $'.', %r8d
    jne .Ljsn_exp
    inc %rdi
    cmp %rsi, %rdi
    jae .Ljsn_err
    movzbl (%rdi), %r8d
    cmp $'0', %r8d
    jb .Ljsn_err
    cmp $'9', %r8d
    ja .Ljsn_err
    jmp json_skip_number_frac       // tail: rdi = first frac digit, rsi = end
.Ljsn_exp:
    cmp $'e', %r8d
    je .Ljsn_exp_start
    cmp $'E', %r8d
    je .Ljsn_exp_start
    jmp .Ljsn_done
.Ljsn_exp_start:
    inc %rdi
    cmp %rsi, %rdi
    jae .Ljsn_err
    movzbl (%rdi), %r8d
    cmp $'+', %r8d
    je .Ljsn_exp_sign
    cmp $'-', %r8d
    je .Ljsn_exp_sign
    jmp .Ljsn_exp_digit
.Ljsn_exp_sign:
    inc %rdi
    cmp %rsi, %rdi
    jae .Ljsn_err
    movzbl (%rdi), %r8d
.Ljsn_exp_digit:
    cmp $'0', %r8d
    jb .Ljsn_err
    cmp $'9', %r8d
    ja .Ljsn_err
    jmp json_skip_number_exp        // tail: rdi = first exp digit, rsi = end
.Ljsn_done:
    mov %rdi, %rax
    ret
.Ljsn_err:
    xor %eax, %eax
    ret

// json_skip_number_frac(rdi=p at the first fraction digit, rsi=end)
//   -> rax = p' past the fraction digits (the first digit is already
//   validated; the caller checked it exactly like .Ljsn_frac).
    .p2align 4
json_skip_number_frac:
.Ljsnf_loop:
    inc %rdi
    cmp %rsi, %rdi
    jae .Ljsnf_done
    movzbl (%rdi), %r8d
    cmp $'0', %r8d
    jb .Ljsnf_done
    cmp $'9', %r8d
    ja .Ljsnf_done
    jmp .Ljsnf_loop
.Ljsnf_done:
    mov %rdi, %rax
    ret

// json_skip_number_exp(rdi=p at the first exponent digit, rsi=end)
//   -> rax = p' past the exponent digits.
    .p2align 4
json_skip_number_exp:
.Ljsne_loop:
    inc %rdi
    cmp %rsi, %rdi
    jae .Ljsne_done
    movzbl (%rdi), %r8d
    cmp $'0', %r8d
    jb .Ljsne_done
    cmp $'9', %r8d
    ja .Ljsne_done
    jmp .Ljsne_loop
.Ljsne_done:
    mov %rdi, %rax
    ret

// ----------------------------------------------------------------------------
// json_scan_str(rdi=p, rsi=end, rdx=cand, rcx=clen) -> rax = p' past the
//   closing quote (0 on error), rdx = 1 if the decoded string EQUALS
//   cand[0..clen), else 0 (cand == 0 means "no candidate": scan/skip only).
//   Full Go string-literal rules: escapes \" \\ \/ \b \f \n \r \t \uXXXX
//   (lower- and upper-case hex), surrogate pairs decoded but never matched
//   (non-ASCII cannot equal an ASCII candidate), raw bytes >= 0x80 advance
//   one byte at a time (safe: can never skip a closing quote), raw bytes
//   < 0x20 are errors (scanner.go: "invalid character ... in string
//   literal").  Matching is streaming: no buffer, so arbitrarily long
//   strings are handled like Go.  The escape decode is split into
//   json_scan_str_escape (<= 80 gate).
// ----------------------------------------------------------------------------
    .p2align 4
json_scan_str:
    PROLOGUE 5                  // rbx=end, r12=cand, r13=clen, r14=i, r15=ok
    mov %rsi, %rbx
    mov %rdx, %r12
    mov %rcx, %r13
    cmp %rbx, %rdi
    jae .Ljss_err
    movzbl (%rdi), %r8d
    cmp $'"', %r8d
    jne .Ljss_err
    inc %rdi
    xor %r14d, %r14d            // i = 0 (position in the candidate)
    mov $1, %r15d               // ok = 1 (no mismatch yet)
.Ljss_loop:
    cmp %rbx, %rdi
    jae .Ljss_err               // unterminated string
    movzbl (%rdi), %r8d
    cmp $'"', %r8d
    je .Ljss_close
    cmp $'\\', %r8d
    je .Ljss_escape
    cmp $0x20, %r8d
    jb .Ljss_err                // raw control char in string
    cmp $0x80, %r8d
    jae .Ljss_utf8
    inc %rdi                    // advance past the byte
    jmp .Ljss_compare
.Ljss_escape:
    mov %rbx, %rsi              // json_scan_str_escape(p, end)
    call json_scan_str_escape   // -> rax = p' past the escape, rdx = decoded
    test %rax, %rax
    jz .Ljss_err
    mov %rax, %rdi
    mov %rdx, %r8               // decoded byte (zero-extended by the helper)
    cmp $0x80, %r8d
    jae .Ljss_nonascii          // decoded cp >= 0x80: never matches a candidate
    jmp .Ljss_compare
.Ljss_utf8:
    inc %rdi                    // one byte at a time (can never skip a quote)
    jmp .Ljss_nonascii
.Ljss_nonascii:
    xor %r15d, %r15d            // raw/decoded non-ASCII never matches
    jmp .Ljss_loop
.Ljss_compare:                  // r8d = decoded ASCII; rdi already advanced
    test %r15d, %r15d
    jz .Ljss_loop
    test %r12, %r12             // no candidate: keep scanning
    jz .Ljss_loop
    cmp %r13, %r14
    jae .Ljss_overlong
    movzbl (%r12,%r14), %r9d    // cand[i]
    cmp %r8d, %r9d
    jne .Ljss_mismatch
    inc %r14
    jmp .Ljss_loop
.Ljss_overlong:
.Ljss_mismatch:
    xor %r15d, %r15d
    jmp .Ljss_loop
.Ljss_close:
    inc %rdi                    // past the closing quote
    xor %edx, %edx              // matched = 0
    test %r15d, %r15d
    jz .Ljss_done
    test %r12, %r12
    jz .Ljss_done
    cmp %r13, %r14
    sete %dl                    // matched = (no mismatch && i == clen)
.Ljss_done:
    mov %rdi, %rax              // return p'
    jmp .Ljss_ret
.Ljss_err:
    xor %eax, %eax
    xor %edx, %edx
.Ljss_ret:
    EPILOGUE 5
    ret

// json_scan_str_escape(rdi=p at the backslash, rsi=end) -> rax = p' past
//   the escape sequence, rdx = the decoded byte; or rax = 0 on a bad escape
//   / bad \u hex / truncation.  Leaf (no calls); caller-saved only.
    .p2align 4
json_scan_str_escape:
    inc %rdi                    // past the backslash
    cmp %rsi, %rdi
    jae .Ljse_err
    movzbl (%rdi), %r8d
    cmp $'"', %r8d
    je .Ljse_plain
    cmp $'\\', %r8d
    je .Ljse_plain
    cmp $'/', %r8d
    je .Ljse_plain
    cmp $'b', %r8d
    je .Ljse_short
    cmp $'f', %r8d
    je .Ljse_short
    cmp $'n', %r8d
    je .Ljse_short
    cmp $'r', %r8d
    je .Ljse_short
    cmp $'t', %r8d
    je .Ljse_short
    cmp $'u', %r8d
    je .Ljse_unicode
    jmp .Ljse_err               // bad escape code
.Ljse_plain:
    inc %rdi                    // past the escaped char (decoded = r8d)
    mov %r8d, %r9d
    jmp .Ljse_ret
.Ljse_short:
    cmp $'b', %r8d
    je .Ljse_short_b
    cmp $'f', %r8d
    je .Ljse_short_f
    cmp $'n', %r8d
    je .Ljse_short_n
    cmp $'r', %r8d
    je .Ljse_short_r
    mov $9, %r9d                 // 't' -> \t
    jmp .Ljse_short_got
.Ljse_short_b:
    mov $8, %r9d
    jmp .Ljse_short_got
.Ljse_short_f:
    mov $12, %r9d
    jmp .Ljse_short_got
.Ljse_short_n:
    mov $10, %r9d
    jmp .Ljse_short_got
.Ljse_short_r:
    mov $13, %r9d
.Ljse_short_got:
    mov %r9d, %r8d              // decoded byte
    inc %rdi                    // past the escape letter
    jmp .Ljse_ret
.Ljse_unicode:
    inc %rdi                    // past the 'u'
    mov %rsi, %rax
    sub %rdi, %rax              // remaining = end - p
    cmp $4, %rax
    jb .Ljse_err
    xor %r9d, %r9d              // code point
    xor %r10d, %r10d            // digit index
.Ljse_hex_loop:
    movzbl (%rdi,%r10), %r11d
    cmp $'0', %r11d
    jb .Ljse_err
    cmp $'9', %r11d
    ja .Ljse_hex_upper
    sub $'0', %r11d
    jmp .Ljse_hex_got
.Ljse_hex_upper:
    cmp $'a', %r11d
    jb .Ljse_err
    cmp $'f', %r11d
    ja .Ljse_err
    sub $87, %r11d               // 'a' - 10
.Ljse_hex_got:
    shl $4, %r9d
    or %r11d, %r9d
    inc %r10d
    cmp $4, %r10d
    jb .Ljse_hex_loop
    add $4, %rdi                // past the 4 hex digits
    mov %r9d, %r8d              // decoded = code point (>= 0x80 -> caller no-match)
.Ljse_ret:
    mov %r8d, %edx              // return decoded byte
    mov %rdi, %rax              // return p'
    ret
.Ljse_err:
    xor %eax, %eax
    xor %edx, %edx
    ret

// ----------------------------------------------------------------------------
// json_skip_value(rdi=p, rsi=end) -> rax = p' past ONE JSON value (any
//   kind), or 0 on error.  Used to skip unknown-key values with full
//   validation.  State machine (state in the frame): 0 EXPECT_VALUE,
//   1 EXPECT_FIRST_KEY, 2 EXPECT_KEY, 3 AFTER_VALUE.  Container nesting is
//   tracked with a depth counter plus a bit-stack (bit i = level i is an
//   object), so nested objects/arrays need no recursion.  After a literal
//   the next byte is NOT inspected here (top-level trailing garbage is
//   accepted by Decoder.Decode); inside a container the caller's ,/closer
//   check catches stray bytes exactly like Go's scanner.  The state lives
//   in a 32-byte frame at 0(%rsp) depth / 8(%rsp) tstack / 16(%rsp) state;
//   the sub-helpers update it through pointers (<= 80 gate).
// ----------------------------------------------------------------------------
    .p2align 4
json_skip_value:
    PROLOGUE 2                  // rbx=p, r12=end
    sub $32, %rsp               // frame: 0 depth, 8 tstack, 16 state, 24 pad
    mov %rdi, %rbx
    mov %rsi, %r12
    xor %eax, %eax
    mov %rax, 0(%rsp)           // depth = 0
    mov %rax, 8(%rsp)           // tstack = 0
    mov %rax, 16(%rsp)          // state = 0 (EXPECT_VALUE)
.Ljsv_loop:
    mov 16(%rsp), %eax          // state (caller-saved scratch)
    test %eax, %eax
    jz .Ljsv_expect_value
    cmp $1, %eax
    je .Ljsv_expect_first
    cmp $2, %eax
    je .Ljsv_expect_key
    jmp .Ljsv_after_value
.Ljsv_expect_value:
    mov %rbx, %rdi
    mov %r12, %rsi
    lea 0(%rsp), %rdx           // &depth
    lea 8(%rsp), %rcx           // &tstack
    lea 16(%rsp), %r8           // &state
    call json_skip_value_value
    test %rax, %rax
    jz .Ljsv_err
    mov %rax, %rbx
    jmp .Ljsv_loop
.Ljsv_expect_first:
.Ljsv_expect_key:
    mov %rbx, %rdi
    mov %r12, %rsi
    lea 0(%rsp), %rdx           // &depth
    lea 8(%rsp), %rcx           // &tstack
    lea 16(%rsp), %r8           // &state
    call json_skip_value_key
    test %rax, %rax
    jz .Ljsv_err
    mov %rax, %rbx
    jmp .Ljsv_loop
.Ljsv_after_value:
    mov %rbx, %rdi
    mov %r12, %rsi
    lea 0(%rsp), %rdx           // &depth
    lea 8(%rsp), %rcx           // &tstack
    lea 16(%rsp), %r8           // &state
    call json_skip_value_after
    test %rax, %rax
    jz .Ljsv_err
    mov %rax, %rbx
    mov 0(%rsp), %eax           // depth (the AArch64 done test: cmp x21, #0)
    test %eax, %eax
    jz .Ljsv_done               // depth was 0: done, p unchanged
    jmp .Ljsv_loop
.Ljsv_done:
    mov %rbx, %rax              // return p'
    jmp .Ljsv_ret
.Ljsv_err:
    xor %eax, %eax
.Ljsv_ret:
    add $32, %rsp
    EPILOGUE 2
    ret

// json_skip_value_value(rdi=p, rsi=end, rdx=&depth, rcx=&tstack, r8=&state)
//   -> rax = p' (0 = error).  Dispatches on the byte at p: '"' -> string
//   (json_scan_str), '{' -> open-object (bit-stack + depth++, state 1),
//   '[' -> open-array (depth++, state 0), '-'/digit -> number
//   (json_skip_number), 't'/'f'/'n' -> json_skip_value_lit; anything else
//   is an error.  A scalar value sets state 3 in the frame.
    .p2align 4
json_skip_value_value:
    PROLOGUE 5                  // rbx=p, r12=end, r13=&depth, r14=&tstack, r15=&state
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    mov %r8, %r15
    cmp %r12, %rbx
    jae .Ljvv_err
    movzbl (%rbx), %r8d
    cmp $'"', %r8d
    je .Ljvv_string
    cmp $'{', %r8d
    je .Ljvv_open_obj
    cmp $'[', %r8d
    je .Ljvv_open_arr
    cmp $'-', %r8d
    je .Ljvv_number
    cmp $'0', %r8d
    jb .Ljvv_err
    cmp $'9', %r8d
    ja .Ljvv_lit                // 't','f','n' (and any > '9' byte) -> lit helper
    jmp .Ljvv_number
.Ljvv_string:
    mov %rbx, %rdi
    mov %r12, %rsi
    xor %edx, %edx              // no candidate: scan/skip only
    xor %ecx, %ecx
    call json_scan_str
    test %rax, %rax
    jz .Ljvv_err
    movq $3, 0(%r15)            // state = AFTER_VALUE
    jmp .Ljvv_ret
.Ljvv_open_obj:
    mov 0(%r13), %r8            // depth
    bts %r8, 0(%r14)            // tstack |= 1 << depth
    incq 0(%r13)                // depth++
    movq $1, 0(%r15)            // state = EXPECT_FIRST_KEY
    lea 1(%rbx), %rax
    jmp .Ljvv_ret
.Ljvv_open_arr:
    incq 0(%r13)                // depth++
    movq $0, 0(%r15)            // state = EXPECT_VALUE
    lea 1(%rbx), %rax
    jmp .Ljvv_ret
.Ljvv_lit:
    mov %rbx, %rdi
    mov %r12, %rsi
    mov %r15, %rdx              // &state
    call json_skip_value_lit
    test %rax, %rax
    jz .Ljvv_err
    jmp .Ljvv_ret
.Ljvv_number:
    mov %rbx, %rdi
    mov %r12, %rsi
    call json_skip_number
    test %rax, %rax
    jz .Ljvv_err
    movq $3, 0(%r15)            // state = AFTER_VALUE
    jmp .Ljvv_ret
.Ljvv_ret:
    EPILOGUE 5
    ret
.Ljvv_err:
    xor %eax, %eax
    EPILOGUE 5
    ret

// json_skip_value_lit(rdi=p, rsi=end, rdx=&state) -> rax = p' past the
//   matched literal (true/false/null), or 0 on mismatch/truncation/other.
//   Sets state 3 in the frame on success.
    .p2align 4
json_skip_value_lit:
    PROLOGUE 3                  // rbx=p, r12=end, r13=&state
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    movzbl (%rbx), %r8d
    cmp $'t', %r8d
    je .Ljvl_true
    cmp $'f', %r8d
    je .Ljvl_false
    cmp $'n', %r8d
    je .Ljvl_null
    jmp .Ljvl_err
.Ljvl_true:
    mov %rbx, %rdi
    mov %r12, %rsi
    LEA rdx, json_s_true
    mov $JSON_LIT_TRUE_LEN, %ecx
    call json_match_lit
    test %rax, %rax
    jz .Ljvl_err
    movq $3, 0(%r13)            // state = AFTER_VALUE
    jmp .Ljvl_ret
.Ljvl_false:
    mov %rbx, %rdi
    mov %r12, %rsi
    LEA rdx, json_s_false
    mov $JSON_LIT_FALSE_LEN, %ecx
    call json_match_lit
    test %rax, %rax
    jz .Ljvl_err
    movq $3, 0(%r13)
    jmp .Ljvl_ret
.Ljvl_null:
    mov %rbx, %rdi
    mov %r12, %rsi
    LEA rdx, json_s_null
    mov $JSON_LIT_NULL_LEN, %ecx
    call json_match_lit
    test %rax, %rax
    jz .Ljvl_err
    movq $3, 0(%r13)
    jmp .Ljvl_ret
.Ljvl_ret:
    EPILOGUE 3
    ret
.Ljvl_err:
    xor %eax, %eax
    EPILOGUE 3
    ret

// json_skip_value_key(rdi=p, rsi=end, rdx=&depth, rcx=&tstack, r8=&state)
//   -> rax = p' after the ':' (state 0 in the frame) or p' at the '}' of an
//   EMPTY object (state 3, depth-1, bit cleared); 0 on error.  Handles the
//   EXPECT_FIRST_KEY (1) and EXPECT_KEY (2) states: skip whitespace, then
//   for state 1 a '}' closes an empty object, for state 2 a '}' is Go's
//   trailing-comma error; the key must be a string, then ':'.
    .p2align 4
json_skip_value_key:
    PROLOGUE 5                  // rbx=p, r12=end, r13=&depth, r14=&tstack, r15=&state
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    mov %r8, %r15
    mov %rbx, %rdi              // json_skip_ws(p, end)
    mov %r12, %rsi
    call json_skip_ws
    mov %rax, %rbx
    cmp %r12, %rbx
    jae .Ljsk_err
    movzbl (%rbx), %r8d
    cmp $'}', %r8d
    jne .Ljsk_not_close
    mov 0(%r15), %r8            // state
    cmp $1, %r8
    jne .Ljsk_err               // state 2: '}' is Go's trailing-comma error
    inc %rbx                    // empty object: p+1, depth-1, clear bit, state 3
    decq 0(%r13)
    mov 0(%r13), %r8
    btr %r8, 0(%r14)            // clear bit (depth-1) in tstack
    movq $3, 0(%r15)
    mov %rbx, %rax
    jmp .Ljsk_ret
.Ljsk_not_close:
    cmp $'"', %r8d
    jne .Ljsk_err
.Ljsk_key:
    mov %rbx, %rdi              // json_scan_str(p, end, 0, 0)
    mov %r12, %rsi
    xor %edx, %edx
    xor %ecx, %ecx
    call json_scan_str
    test %rax, %rax
    jz .Ljsk_err
    mov %rax, %rbx
    mov %rbx, %rdi              // json_skip_ws(p', end)
    mov %r12, %rsi
    call json_skip_ws
    mov %rax, %rbx
    cmp %r12, %rbx
    jae .Ljsk_err
    movzbl (%rbx), %r8d
    cmp $':', %r8d
    jne .Ljsk_err
    inc %rbx                    // past the ':'
    movq $0, 0(%r15)            // state = EXPECT_VALUE
    mov %rbx, %rax
.Ljsk_ret:
    EPILOGUE 5
    ret
.Ljsk_err:
    xor %eax, %eax
    EPILOGUE 5
    ret

// json_skip_value_after(rdi=p, rsi=end, rdx=&depth, rcx=&tstack, r8=&state)
//   -> rax = p' (0 on error), and the frame state/depth/tstack updated:
//   depth 0 -> done (state 0, p unchanged); ',' -> advance and set state 2
//   (object level) or 0 (array level); the matching closer -> advance,
//   depth-1, clear the bit, state 3.  The level type is the bit at
//   (depth-1) of the tstack.
    .p2align 4
json_skip_value_after:
    PROLOGUE 5                  // rbx=p, r12=end, r13=&depth, r14=&tstack, r15=&state
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    mov %r8, %r15
    mov 0(%r13), %r8            // depth
    test %r8, %r8
    jz .Ljsa_done               // depth == 0 -> done
    mov %rbx, %rdi              // json_skip_ws(p, end)
    mov %r12, %rsi
    call json_skip_ws
    mov %rax, %rbx
    cmp %r12, %rbx
    jae .Ljsa_err
    movzbl (%rbx), %r8d
    cmp $',', %r8d
    je .Ljsa_comma
    mov 0(%r13), %r9            // depth
    dec %r9
    mov %r9, %rcx
    mov 0(%r14), %r9            // tstack
    shr %cl, %r9
    and $1, %r9
    jnz .Ljsa_obj               // bit set -> this level is an object
    cmp $']', %r8d              // array level: expect ']'
    je .Ljsa_close
    jmp .Ljsa_err
.Ljsa_obj:
    cmp $'}', %r8d
    je .Ljsa_close
    jmp .Ljsa_err
.Ljsa_comma:
    inc %rbx                    // past the ','
    mov 0(%r13), %r9
    dec %r9
    mov %r9, %rcx
    mov 0(%r14), %r9
    shr %cl, %r9
    and $1, %r9
    jnz .Ljsa_comma_obj
    movq $0, 0(%r15)            // array: state = EXPECT_VALUE
    jmp .Ljsa_ret_p
.Ljsa_comma_obj:
    movq $2, 0(%r15)            // object: state = EXPECT_KEY
    jmp .Ljsa_ret_p
.Ljsa_close:
    inc %rbx                    // past the closer
    decq 0(%r13)                // depth-1
    mov 0(%r13), %r8
    btr %r8, 0(%r14)            // clear bit (depth-1) in tstack
    movq $3, 0(%r15)            // state = AFTER_VALUE
    jmp .Ljsa_ret_p
.Ljsa_done:
    movq $0, 0(%r15)            // state = 0 (done)
    jmp .Ljsa_ret_p
.Ljsa_ret_p:
    mov %rbx, %rax
.Ljsa_ret:
    EPILOGUE 5
    ret
.Ljsa_err:
    xor %eax, %eax
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// json_parse_pair(rdi=p, rsi=end, rdx=out, rcx=spec) -> rax = p' at the
//   value end (the caller then handles ,/}), or 0 on error.  p is at the
//   key's opening quote.  Parses one "key":value pair: matches the key
//   against the spec's two entries, then stores the decoded value id (or
//   CC_JSON_ID_UNKNOWN) for a known key, no-ops on null, and fully skips
//   unknown keys.  Value strings are matched streaming against the entry's
//   value table.  Split at the natural ':' boundary: json_parse_pair does
//   the key match, json_parse_pair_after_key does the ':' + value dispatch,
//   json_parse_pair_value does the value-table loop (<= 80 gate).
// ----------------------------------------------------------------------------
    .p2align 4
json_parse_pair:
    PROLOGUE 4                  // rbx=out, r12=end, r13=p, r14=spec
    mov %rdx, %rbx
    mov %rsi, %r12
    mov %rdi, %r13
    mov %rcx, %r14
    mov %r13, %rdi              // try spec entry 0's key
    mov %r12, %rsi
    mov 0(%r14), %rdx
    mov 8(%r14), %rcx
    call json_scan_str
    test %rax, %rax
    jz .Ljpp_err
    test %rdx, %rdx
    jnz .Ljpp_field0
    mov %r13, %rdi              // try spec entry 1's key
    mov %r12, %rsi
    mov 32(%r14), %rdx
    mov 40(%r14), %rcx
    call json_scan_str
    test %rax, %rax
    jz .Ljpp_err
    test %rdx, %rdx
    jnz .Ljpp_field1
    mov %rax, %r13              // unknown key: p' past the key string
    mov $2, %r8d                // field = 2
    jmp .Ljpp_known
.Ljpp_field0:
    mov %rax, %r13
    xor %r8d, %r8d              // field = 0
    jmp .Ljpp_known
.Ljpp_field1:
    mov %rax, %r13
    mov $1, %r8d                // field = 1
.Ljpp_known:
    mov %r8, %r9                // entry base = spec + field*32
    shl $5, %r9
    add %r14, %r9
    mov 16(%r9), %r10           // out offset
    mov 24(%r9), %r9            // value table
    mov %r13, %rdi              // json_parse_pair_after_key(p, end, field,
    mov %r12, %rsi              //   out, vtbl, outoff)
    mov %r8d, %edx
    mov %rbx, %rcx
    mov %r9, %r8
    mov %r10, %r9
    call json_parse_pair_after_key
    test %rax, %rax
    jz .Ljpp_err
    EPILOGUE 4
    ret
.Ljpp_err:
    xor %eax, %eax
    EPILOGUE 4
    ret

// json_parse_pair_after_key(rdi=p, rsi=end, rdx=field, rcx=out, r8=vtbl,
//   r9=outoff) -> rax = p' at the value end (0 on error).  p is just past
//   the key's closing quote: skip whitespace, expect ':', skip whitespace,
//   then for a known field (field 0/1) a string value is matched against
//   the value table (json_parse_pair_value) and null is a no-op; for an
//   unknown field (field 2) the whole value is skipped with validation
//   (json_skip_value).  outoff is spilled in the PROLOGUE 5 padding slot.
    .p2align 4
json_parse_pair_after_key:
    PROLOGUE 5                  // rbx=p, r12=end, r13=field, r14=out, r15=vtbl
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    mov %r8, %r15
    mov %r9, 0(%rsp)            // outoff spill (the PROLOGUE 5 padding slot)
    mov %rbx, %rdi              // json_skip_ws(p, end)
    mov %r12, %rsi
    call json_skip_ws
    mov %rax, %rbx
    cmp %r12, %rbx
    jae .Ljpak_err
    movzbl (%rbx), %r8d
    cmp $':', %r8d
    jne .Ljpak_err
    inc %rbx
    mov %rbx, %rdi              // json_skip_ws(p', end)
    mov %r12, %rsi
    call json_skip_ws
    mov %rax, %rbx
    cmp %r12, %rbx
    jae .Ljpak_err
    cmp $2, %r13d
    je .Ljpak_unknown
    movzbl (%rbx), %r8d
    cmp $'"', %r8d
    je .Ljpak_val
    cmp $'n', %r8d
    je .Ljpak_null
    jmp .Ljpak_err              // Go: cannot unmarshal <kind> into the string field
.Ljpak_val:
    mov %rbx, %rdi              // json_parse_pair_value(p, end, vtbl, out, outoff)
    mov %r12, %rsi
    mov %r15, %rdx
    mov %r14, %rcx
    mov 0(%rsp), %r8
    call json_parse_pair_value
    test %rax, %rax
    jz .Ljpak_err
    jmp .Ljpak_ret
.Ljpak_null:
    mov %rbx, %rdi              // json_match_lit(p, end, null, 4)
    mov %r12, %rsi
    LEA rdx, json_s_null
    mov $JSON_LIT_NULL_LEN, %ecx
    call json_match_lit
    test %rax, %rax
    jz .Ljpak_err
    jmp .Ljpak_ret              // null for a string field: no-op (field unchanged)
.Ljpak_unknown:
    mov %rbx, %rdi              // json_skip_value(p, end)
    mov %r12, %rsi
    call json_skip_value
    test %rax, %rax
    jz .Ljpak_err
.Ljpak_ret:
    EPILOGUE 5
    ret
.Ljpak_err:
    xor %eax, %eax
    EPILOGUE 5
    ret

// json_parse_pair_value(rdi=valstart, rsi=end, rdx=vtbl, rcx=out, r8=outoff)
//   -> rax = p' past the value string (0 on error).  Matches the value
//   streamingly against the NULL-terminated {cand ptr, cand len, id}
//   value table; a match stores the id at out[outoff], no match stores
//   CC_JSON_ID_UNKNOWN (Go's zero string "" -> the route lookup misses).
    .p2align 4
json_parse_pair_value:
    PROLOGUE 5                  // rbx=valstart, r12=end, r13=vtbl, r14=out, r15=outoff
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    mov %r8, %r15
.Ljppv_loop:
    mov 0(%r13), %rdx           // cand (the NULL terminator has cand == 0)
    test %rdx, %rdx
    jz .Ljppv_unknown
    mov 8(%r13), %rcx           // clen
    mov %rbx, %rdi              // json_scan_str(valstart, end, cand, clen)
    mov %r12, %rsi
    call json_scan_str
    test %rax, %rax
    jz .Ljppv_err
    test %rdx, %rdx
    jnz .Ljppv_matched
    add $24, %r13               // next value-table entry
    jmp .Ljppv_loop
.Ljppv_matched:
    mov 16(%r13), %r8           // id
    mov %r8, (%r14,%r15)        // out[outoff] = id
    jmp .Ljppv_ret              // rax = p' past the value string
.Ljppv_unknown:
    mov %rbx, %rdi              // json_scan_str(valstart, end, 0, 0)
    mov %r12, %rsi
    xor %edx, %edx
    xor %ecx, %ecx
    call json_scan_str
    test %rax, %rax
    jz .Ljppv_err
    mov $CC_JSON_ID_UNKNOWN, %r8d
    mov %r8, (%r14,%r15)        // out[outoff] = CC_JSON_ID_UNKNOWN
.Ljppv_ret:
    EPILOGUE 5
    ret
.Ljppv_err:
    xor %eax, %eax
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// json_parse_obj(rdi=json, rsi=len, rdx=out, rcx=spec) -> rax = 0 ok / -1
//   error.  Port of json.Decoder.Decode into a two-field struct: leading
//   whitespace, top-level null -> ok (fields untouched), an object with
//   known/unknown keys, duplicate keys last-wins (each occurrence
//   overwrites the field), and trailing garbage after the object ACCEPTED
//   (Decode reads one value).  Both fields are pre-filled with
//   CC_JSON_ID_UNKNOWN (an absent key or a null value is Go's zero string
//   "", which matches no route); valid string values overwrite the field.
//   The caller passes the out struct without zeroing it.  The per-pair
//   loop body is split into json_parse_obj_iter (<= 80 gate).
// ----------------------------------------------------------------------------
    .p2align 4
json_parse_obj:
    PROLOGUE 5                  // rbx=out, r12=end, r13=p, r14=spec
    mov %rdx, %rbx
    mov %rcx, %r14
    // Pre-fill both fields with CC_JSON_ID_UNKNOWN: an absent key or a null
    // value leaves the field at this sentinel, exactly like Go's zero string
    // "" (which matches no route).  Valid string values overwrite it.
    mov 16(%r14), %r8           // spec[0].out offset
    movq $CC_JSON_ID_UNKNOWN, (%rbx,%r8)
    mov 48(%r14), %r8           // spec[1].out offset
    movq $CC_JSON_ID_UNKNOWN, (%rbx,%r8)
    lea (%rdi,%rsi), %r12       // end = json + len
    mov %rdi, %r13              // p
    test %rsi, %rsi
    jz .Ljpo_err                // empty input -> Go's EOF error
    mov %r13, %rdi              // json_skip_ws(p, end)
    mov %r12, %rsi
    call json_skip_ws
    mov %rax, %r13
    cmp %r12, %r13
    jae .Ljpo_err               // whitespace only -> EOF error
    movzbl (%r13), %r8d
    cmp $'n', %r8d
    je .Ljpo_null
    cmp $'{', %r8d
    jne .Ljpo_err               // Go: cannot unmarshal <kind> into the struct
    inc %r13
    movq $1, 0(%rsp)            // first = 1 (a '}' is allowed only before any pair)
.Ljpo_loop:
    mov %r13, %rdi              // json_parse_obj_iter(p, end, out, spec, &first)
    mov %r12, %rsi
    mov %rbx, %rdx
    mov %r14, %rcx
    lea 0(%rsp), %r8
    call json_parse_obj_iter
    test %rdx, %rdx
    jz .Ljpo_ok                 // rdx == 0: object closed cleanly
    js .Ljpo_err                // rdx == -1: error
    mov %rax, %r13              // rdx == 1: continue with p'
    jmp .Ljpo_loop
.Ljpo_null:
    mov %r13, %rdi              // json_match_lit(p, end, null, 4)
    mov %r12, %rsi
    LEA rdx, json_s_null
    mov $JSON_LIT_NULL_LEN, %ecx
    call json_match_lit
    test %rax, %rax
    jz .Ljpo_err
    xor %eax, %eax              // null -> ok, fields untouched, trailing ignored
    jmp .Ljpo_ret
.Ljpo_ok:
    xor %eax, %eax
    jmp .Ljpo_ret
.Ljpo_err:
    movq $-1, %rax              // 64-bit -1 (not the zero-extended 32-bit form)
.Ljpo_ret:
    EPILOGUE 5
    ret

// json_parse_obj_iter(rdi=p, rsi=end, rdx=out, rcx=spec, r8=&first)
//   -> rax = p' at the separator (rdx = 1 continue), or rax = 0 with
//   rdx = 0 (ok: '}' seen) / -1 (error).  One loop iteration: skip
//   whitespace; '}' closes only when first; the key must be a string;
//   json_parse_pair parses the pair; then skip whitespace and require ','
//   (clear first, continue) or '}' (ok).
    .p2align 4
json_parse_obj_iter:
    PROLOGUE 5                  // rbx=p, r12=end, r13=out, r14=spec, r15=&first
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    mov %r8, %r15
    mov %rbx, %rdi              // json_skip_ws(p, end)
    mov %r12, %rsi
    call json_skip_ws
    mov %rax, %rbx
    cmp %r12, %rbx
    jae .Ljpoi_err
    movzbl (%rbx), %r8d
    cmp $'}', %r8d
    jne .Ljpoi_key
    mov 0(%r15), %r8            // first
    test %r8, %r8
    jz .Ljpoi_err               // trailing comma (Go: '}' looking for key)
    xor %eax, %eax
    xor %edx, %edx              // ok
    jmp .Ljpoi_ret
.Ljpoi_key:
    cmp $'"', %r8d
    jne .Ljpoi_err
    mov %rbx, %rdi              // json_parse_pair(p, end, out, spec)
    mov %r12, %rsi
    mov %r13, %rdx
    mov %r14, %rcx
    call json_parse_pair
    mov %rax, %rbx
    test %rbx, %rbx
    jz .Ljpoi_err
    mov %rbx, %rdi              // json_skip_ws(p', end)
    mov %r12, %rsi
    call json_skip_ws
    mov %rax, %rbx
    cmp %r12, %rbx
    jae .Ljpoi_err
    movzbl (%rbx), %r8d
    cmp $',', %r8d
    je .Ljpoi_comma
    cmp $'}', %r8d
    je .Ljpoi_ok
    jmp .Ljpoi_err
.Ljpoi_comma:
    inc %rbx                    // past the ','
    movq $0, 0(%r15)            // first = 0
    mov %rbx, %rax
    mov $1, %edx                // continue
    jmp .Ljpoi_ret
.Ljpoi_ok:
    xor %eax, %eax
    xor %edx, %edx
    jmp .Ljpoi_ret
.Ljpoi_err:
    xor %eax, %eax
    movq $-1, %rdx              // 64-bit -1 (not the zero-extended 32-bit form)
.Ljpoi_ret:
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// json_utf8_copy(rdi=buf, rsi=s, rdx=len, rcx=seqlen) -> rax = buf' (0 if
//   the seqlen-byte sequence at s is not valid UTF-8), rsi = s+seqlen,
//   rdx = len-seqlen.  Validates the seqlen-1 continuation bytes
//   (0x80..0xbf) exactly as utf8.DecodeRune does, then copies the sequence
//   as-is.  Multi-value return: rax = buf', rsi = s', rdx = len'.
// ----------------------------------------------------------------------------
    .p2align 4
json_utf8_copy:
    cmp %rcx, %rdx              // len < seqlen -> bad
    jb .Ljuc_bad
    mov $1, %r8d                // i = 1
.Ljuc_cont_loop:
    cmp %rcx, %r8
    jae .Ljuc_valid
    movzbl (%rsi,%r8), %r9d
    cmp $0x80, %r9d
    jb .Ljuc_bad
    cmp $0xbf, %r9d
    ja .Ljuc_bad
    inc %r8
    jmp .Ljuc_cont_loop
.Ljuc_valid:
    xor %r8d, %r8d              // i = 0
.Ljuc_copy_loop:
    movzbl (%rsi,%r8), %r9d
    mov %r9b, (%rdi,%r8)
    inc %r8
    cmp %rcx, %r8
    jb .Ljuc_copy_loop
    lea (%rdi,%rcx), %rax       // buf + seqlen
    lea (%rsi,%rcx), %rsi       // s + seqlen
    sub %rcx, %rdx              // len - seqlen
    ret
.Ljuc_bad:
    xor %eax, %eax
    ret

// ----------------------------------------------------------------------------
// json_escape(rdi=buf, rsi=s, rdx=len) -> rax = buf'  (escaped content, NO
//   surrounding quotes).  Byte-exact port of Go's appendString with
//   escapeHTML = true (encode.go:999-1066): " -> \", \ -> \\, \b\f\n\r\t
//   short escapes, other < 0x20 and < > & -> \u00XX (lowercase hex), DEL
//   passed through, U+2028/U+2029 -> \u2028/\u2029, valid UTF-8 copied,
//   invalid bytes -> the literal "\ufffd" (one per invalid byte).
//   PROLOGUE 1: rbx holds the CURRENT buf across the utf8 `call`s (whose
//   rax return is 0 on an invalid sequence — the bad-UTF-8 path must still
//   write "\ufffd" to the original buf, not to 0).  The per-byte escape
//   writers and the 3-byte UTF-8 handler are split into leaf helpers
//   (<= 80 gate).
// ----------------------------------------------------------------------------
    .p2align 4
json_escape:
    PROLOGUE 1                  // rbx = current buf (across the utf8 calls)
    mov %rdi, %rbx
.Lje_loop:
    test %rdx, %rdx
    jz .Lje_done
    movzbl (%rsi), %r8d         // byte
    cmp $0x20, %r8d
    jb .Lje_ctrl
    cmp $0x80, %r8d
    jae .Lje_utf8
    cmp $'"', %r8d
    je .Lje_quote
    cmp $'\\', %r8d
    je .Lje_quote
    cmp $'&', %r8d
    je .Lje_u00xx
    cmp $'<', %r8d
    je .Lje_u00xx
    cmp $'>', %r8d
    je .Lje_u00xx
    mov %r8b, (%rdi)            // plain ASCII byte
    inc %rdi
    jmp .Lje_adv1
.Lje_ctrl:
    lea -8(%r8), %r9d           // r9d = byte - 8 (the short-map index); r8d keeps the byte
    cmp $6, %r9d
    jae .Lje_u00xx
    cmp $3, %r9d
    je .Lje_u00xx               // byte == 11 is a hole (\u000b)
    call json_escape_ctrl       // rdi=buf, r9d=index; rsi (the source) untouched
    mov %rax, %rdi
    jmp .Lje_adv1
.Lje_quote:
    call json_escape_quote      // rdi=buf, r8d=byte; rsi (the source) untouched
    mov %rax, %rdi
    jmp .Lje_adv1
.Lje_u00xx:
    call json_escape_u00xx      // rdi=buf, r8d=byte; rsi (the source) untouched
    mov %rax, %rdi
    jmp .Lje_adv1
.Lje_utf8:
    mov %rdi, %rbx              // current buf (for the bad-utf8 path)
    cmp $0xc2, %r8d
    jb .Lje_bad_utf8
    cmp $0xdf, %r8d
    jbe .Lje_utf8_2
    cmp $0xef, %r8d
    jbe .Lje_utf8_3
    cmp $0xf4, %r8d
    jbe .Lje_utf8_4
    jmp .Lje_bad_utf8
.Lje_utf8_2:
    mov $2, %ecx                // json_utf8_copy(buf, s, len, 2)
    jmp .Lje_utf8_call
.Lje_utf8_3:
    mov %r8d, %ecx              // json_escape_utf8_3(buf, s, len, lead)
    call json_escape_utf8_3
    test %rax, %rax
    jz .Lje_bad_utf8
    mov %rax, %rdi
    jmp .Lje_loop               // rsi/rdx already advanced by the helper
.Lje_utf8_4:
    mov $4, %ecx                // json_utf8_copy(buf, s, len, 4)
    jmp .Lje_utf8_call
.Lje_utf8_call:
    call json_utf8_copy
    test %rax, %rax
    jz .Lje_bad_utf8
    mov %rax, %rdi
    jmp .Lje_loop               // rsi/rdx already advanced by the helper
.Lje_bad_utf8:
    mov %rbx, %rdi              // restore buf: write "\ufffd" at the ORIGINAL position
    call json_escape_ufffd
    mov %rax, %rdi
    jmp .Lje_adv1
.Lje_adv1:                      // one source byte consumed
    inc %rsi
    dec %rdx
    jmp .Lje_loop
.Lje_done:
    mov %rdi, %rax              // return buf'
    EPILOGUE 1
    ret

// json_escape_ctrl(rdi=buf, r9d=short-map index (byte-8)) -> rax = buf+2.
    .p2align 4
json_escape_ctrl:
    LEA r8, json_short_map
    movzbl (%r8,%r9), %r8d      // the short escape letter
    movb $'\\', (%rdi)
    mov %r8b, 1(%rdi)
    lea 2(%rdi), %rax
    ret

// json_escape_quote(rdi=buf, r8d=byte) -> rax = buf+2  (" or \\ escaped).
    .p2align 4
json_escape_quote:
    movb $'\\', (%rdi)
    mov %r8b, 1(%rdi)
    lea 2(%rdi), %rax
    ret

// json_escape_u00xx(rdi=buf, r8d=byte) -> rax = buf+6  (\u00XX lowercase).
    .p2align 4
json_escape_u00xx:
    LEA r9, json_hex
    movb $'\\', (%rdi)
    movb $'u', 1(%rdi)
    movb $'0', 2(%rdi)
    movb $'0', 3(%rdi)
    mov %r8d, %r10d
    shr $4, %r10d
    movzbl (%r9,%r10), %r10d
    mov %r10b, 4(%rdi)
    mov %r8d, %r10d
    and $0xf, %r10d
    movzbl (%r9,%r10), %r10d
    mov %r10b, 5(%rdi)
    lea 6(%rdi), %rax
    ret

// json_escape_ufffd(rdi=buf) -> rax = buf+6  (the literal "\ufffd").
    .p2align 4
json_escape_ufffd:
    LEA r8, json_esc_ufffd
    mov (%r8), %r9d             // first 4 bytes: \ u f f
    mov %r9d, (%rdi)
    movzwl 4(%r8), %r9d         // last 2 bytes: f d
    mov %r9w, 4(%rdi)
    lea 6(%rdi), %rax
    ret

// json_escape_utf8_3(rdi=buf, rsi=s, rdx=len, ecx=lead) -> rax = buf'
//   (0 = invalid), rsi = s+3, rdx = len-3.  Validates the two continuation
//   bytes, then either copies the 3 bytes as-is or, for U+2028 (e2 80 a8) /
//   U+2029 (e2 80 a9), writes the unconditional \u2028 / \u2029 escape
//   (encode.go:1047-1060).  Leaf (no calls); caller-saved only.
    .p2align 4
json_escape_utf8_3:
    cmp $3, %rdx
    jb .Lje3_bad
    movzbl 1(%rsi), %r8d        // first continuation byte
    cmp $0x80, %r8d
    jb .Lje3_bad
    cmp $0xbf, %r8d
    ja .Lje3_bad
    movzbl 2(%rsi), %r9d        // second continuation byte
    cmp $0x80, %r9d
    jb .Lje3_bad
    cmp $0xbf, %r9d
    ja .Lje3_bad
    cmp $0xe2, %ecx
    jne .Lje3_copy
    cmp $0x80, %r8d
    jne .Lje3_copy
    cmp $0xa8, %r9d
    je .Lje3_u2028
    cmp $0xa9, %r9d
    je .Lje3_u2029
.Lje3_copy:
    movzbl (%rsi), %r8d
    mov %r8b, (%rdi)
    movzbl 1(%rsi), %r8d
    mov %r8b, 1(%rdi)
    movzbl 2(%rsi), %r8d
    mov %r8b, 2(%rdi)
    lea 3(%rdi), %rax
    lea 3(%rsi), %rsi
    sub $3, %rdx
    ret
.Lje3_u2028:
    mov $'8', %r8d
    jmp .Lje3_u202x
.Lje3_u2029:
    mov $'9', %r8d
.Lje3_u202x:
    movb $'\\', (%rdi)
    movb $'u', 1(%rdi)
    movb $'2', 2(%rdi)
    movb $'0', 3(%rdi)
    movb $'2', 4(%rdi)
    mov %r8b, 5(%rdi)
    lea 6(%rdi), %rax
    lea 3(%rsi), %rsi
    sub $3, %rdx
    ret
.Lje3_bad:
    xor %eax, %eax
    ret

// ----------------------------------------------------------------------------
// json_quote_escape(rdi=buf, rsi=s, rdx=len) -> rax = buf'  ("<escaped>")
//   PROLOGUE 0 preserves rsp alignment across the `call json_escape`: a
//   function that calls another via call and then rets MUST balance its
//   frame before the ret (SysV; the ret pops the call-pushed address).
// ----------------------------------------------------------------------------
    .p2align 4
json_quote_escape:
    PROLOGUE 0
    movb $'"', (%rdi)
    inc %rdi
    call json_escape
    movb $'"', (%rax)
    lea 1(%rax), %rax
    EPILOGUE 0
    ret

// ----------------------------------------------------------------------------
// json_id_str(rdi=buf, rsi=id, rdx=table) -> rax = buf'  (escaped string
//   for the id looked up in the {ptr,len} table; tail-calls cc_json_str).
// ----------------------------------------------------------------------------
    .p2align 4
json_id_str:
    mov %rsi, %r8
    shl $4, %r8                 // id * 16 (the {ptr,len} entry stride)
    add %rdx, %r8
    mov (%r8), %rsi             // string ptr
    mov 8(%r8), %rdx            // string len
    jmp cc_json_str

// ----------------------------------------------------------------------------
// json_obj_path_entry(rdi=buf, rsi=name, rdx=status, rcx=names tbl)
//   -> rax = buf'  Writes "name":<status-string> for one paths-map entry.
// ----------------------------------------------------------------------------
    .p2align 4
json_obj_path_entry:
    PROLOGUE 4                  // rbx=buf, r12=name, r13=status, r14=names
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    mov %r12, %rdi
    call cc_strlen              // rax = name length
    mov %rax, %rdx              // cc_json_str(buf, name, len)
    mov %rbx, %rdi
    mov %r12, %rsi
    call cc_json_str
    mov %rax, %rbx
    movb $':', (%rbx)
    inc %rbx
    mov %rbx, %rdi              // json_id_str(buf, status, names)
    mov %r13, %rsi
    mov %r14, %rdx
    call json_id_str
    mov %rax, %rbx
    mov %rbx, %rax
    EPILOGUE 4
    ret

// ----------------------------------------------------------------------------
// json_obj_stage_entry(rdi=buf, rsi=name, rdx=desired, rcx=actual)
//   -> rax = buf'  Writes "name":{"desired":<d>,"actual":<a>} for one
//   stages-map entry.
// ----------------------------------------------------------------------------
    .p2align 4
json_obj_stage_entry:
    PROLOGUE 4                  // rbx=buf, r12=name, r13=desired, r14=actual
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    mov %r12, %rdi
    call cc_strlen
    mov %rax, %rdx              // cc_json_str(buf, name, len)
    mov %rbx, %rdi
    mov %r12, %rsi
    call cc_json_str
    mov %rax, %rbx
    movb $':', (%rbx)
    inc %rbx
    movb $'{', (%rbx)
    inc %rbx
    mov %rbx, %rdi              // cc_json_key_str(buf, desired_key, len)
    LEA rsi, json_s_desired
    mov $JSON_KEY_DESIRED_LEN, %edx
    call cc_json_key_str
    mov %rax, %rbx
    mov %rbx, %rdi              // json_id_str(buf, desired, state_names)
    mov %r13, %rsi
    LEA rdx, json_state_names
    call json_id_str
    mov %rax, %rbx
    mov %rbx, %rdi              // cc_json_sep(buf, 0)
    xor %esi, %esi
    call cc_json_sep
    mov %rax, %rbx
    mov %rbx, %rdi              // cc_json_key_str(buf, actual_key, len)
    LEA rsi, json_s_actual
    mov $JSON_KEY_ACTUAL_LEN, %edx
    call cc_json_key_str
    mov %rax, %rbx
    mov %rbx, %rdi              // json_id_str(buf, actual, state_names)
    mov %r14, %rsi
    LEA rdx, json_state_names
    call json_id_str
    mov %rax, %rbx
    movb $'}', (%rbx)
    inc %rbx
    mov %rbx, %rax
    EPILOGUE 4
    ret

// ----------------------------------------------------------------------------
// json_obj_paths(rdi=buf, rsi=paths tbl) -> rax = buf'
//   Writes { "name":<status>, ... } — the paths map object, braces included.
// ----------------------------------------------------------------------------
    .p2align 4
json_obj_paths:
    PROLOGUE 5                  // rbx=buf, r12=tbl, r13=count, r14=entry, r15=first
    mov %rdi, %rbx
    mov %rsi, %r12
    movb $'{', (%rbx)
    inc %rbx
    mov (%r12), %r13            // count
    lea 8(%r12), %r14           // entry
    mov $1, %r15d               // first
.Ljop_loop:
    test %r13, %r13
    jz .Ljop_done
    mov %rbx, %rdi              // cc_json_sep(buf, first)
    mov %r15, %rsi
    call cc_json_sep
    mov %rax, %rbx
    xor %r15d, %r15d            // first = 0
    mov %rbx, %rdi              // json_obj_path_entry(buf, name, status, names)
    mov (%r14), %rsi
    mov 8(%r14), %rdx
    LEA rcx, json_status_names
    call json_obj_path_entry
    mov %rax, %rbx
    add $CC_JSON_PTBL_ENTRY, %r14
    dec %r13
    jmp .Ljop_loop
.Ljop_done:
    movb $'}', (%rbx)
    inc %rbx
    mov %rbx, %rax
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// json_obj_stages(rdi=buf, rsi=stages tbl) -> rax = buf'
//   Writes { "name":{"desired":<d>,"actual":<a>}, ... } — braces included.
// ----------------------------------------------------------------------------
    .p2align 4
json_obj_stages:
    PROLOGUE 5                  // rbx=buf, r12=tbl, r13=count, r14=entry, r15=first
    mov %rdi, %rbx
    mov %rsi, %r12
    movb $'{', (%rbx)
    inc %rbx
    mov (%r12), %r13            // count
    lea 8(%r12), %r14           // entry
    mov $1, %r15d               // first
.Ljos_loop:
    test %r13, %r13
    jz .Ljos_done
    mov %rbx, %rdi              // cc_json_sep(buf, first)
    mov %r15, %rsi
    call cc_json_sep
    mov %rax, %rbx
    xor %r15d, %r15d            // first = 0
    mov %rbx, %rdi              // json_obj_stage_entry(buf, name, desired, actual)
    mov (%r14), %rsi
    mov 8(%r14), %rdx
    mov 16(%r14), %rcx
    call json_obj_stage_entry
    mov %rax, %rbx
    add $CC_JSON_STBL_ENTRY, %r14
    dec %r13
    jmp .Ljos_loop
.Ljos_done:
    movb $'}', (%rbx)
    inc %rbx
    mov %rbx, %rax
    EPILOGUE 5
    ret

// ============================================================================
// Exported functions
// ============================================================================

// ----------------------------------------------------------------------------
// cc_json_str — write "s" with full Go escaping.
// ----------------------------------------------------------------------------
    .p2align 4
    .global cc_json_str
    FUNC_TYPE(cc_json_str)
cc_json_str:
    jmp json_quote_escape

// ----------------------------------------------------------------------------
// cc_json_key_str — write "key": with full Go escaping of the key.
//   PROLOGUE 0 keeps rsp aligned across the `call json_quote_escape`.
// ----------------------------------------------------------------------------
    .p2align 4
    .global cc_json_key_str
    FUNC_TYPE(cc_json_key_str)
cc_json_key_str:
    PROLOGUE 0
    call json_quote_escape
    movb $JSON_CH_COLON, (%rax)
    inc %rax
    EPILOGUE 0
    ret

// ----------------------------------------------------------------------------
// cc_json_u8 — write the decimal digits of v (0..255), no leading zeros,
//   no quotes (matches strconv.FormatUint(uint64(v), 10)).
// ----------------------------------------------------------------------------
    .p2align 4
    .global cc_json_u8
    FUNC_TYPE(cc_json_u8)
cc_json_u8:
    mov $100, %r8d
    mov %esi, %eax
    xor %edx, %edx
    div %r8d                    // eax = v/100, edx = v%100
    test %eax, %eax
    jz .Lcju_tens_skip
    add $'0', %eax
    mov %al, (%rdi)
    inc %rdi
    mov %edx, %esi              // v = v % 100
    jmp .Lcju_tens_write
.Lcju_tens_skip:
    cmp $10, %esi
    jb .Lcju_units
.Lcju_tens_write:
    mov %esi, %eax
    xor %edx, %edx
    mov $10, %r8d
    div %r8d                    // eax = v/10, edx = v%10
    add $'0', %eax
    mov %al, (%rdi)
    inc %rdi
    mov %edx, %esi              // v = v % 10
.Lcju_units:
    add $'0', %esi
    mov %sil, (%rdi)
    inc %rdi
    mov %rdi, %rax
    ret

// ----------------------------------------------------------------------------
// cc_json_sep — write ',' when first == 0 (buf + 1); leave buf untouched
//   when first == 1.  The caller's "first element" flag pattern.
// ----------------------------------------------------------------------------
    .p2align 4
    .global cc_json_sep
    FUNC_TYPE(cc_json_sep)
cc_json_sep:
    test %esi, %esi
    jnz .Lcjs_done
    movb $JSON_CH_COMMA, (%rdi)
    inc %rdi
.Lcjs_done:
    mov %rdi, %rax
    ret

// ----------------------------------------------------------------------------
// cc_json_path_event — {"path":<path-name>,"status":<status>}
// ----------------------------------------------------------------------------
    .p2align 4
    .global cc_json_path_event
    FUNC_TYPE(cc_json_path_event)
cc_json_path_event:
    PROLOGUE 2                  // rbx = buf, r12 = pe
    mov %rdi, %rbx
    mov %rsi, %r12
    movb $JSON_CH_OBJ_OPEN, (%rbx)
    inc %rbx
    mov %rbx, %rdi              // cc_json_key_str(buf, path_key, len)
    LEA rsi, json_s_path
    mov $JSON_KEY_PATH_LEN, %edx
    call cc_json_key_str
    mov %rax, %rbx
    mov %rbx, %rdi              // json_id_str(buf, pe->path, path_names)
    mov CC_PE_PATH(%r12), %rsi
    LEA rdx, json_path_names
    call json_id_str
    mov %rax, %rbx
    mov %rbx, %rdi              // cc_json_sep(buf, 0)
    xor %esi, %esi
    call cc_json_sep
    mov %rax, %rbx
    mov %rbx, %rdi              // cc_json_key_str(buf, status_key, len)
    LEA rsi, json_s_status
    mov $JSON_KEY_STATUS_LEN, %edx
    call cc_json_key_str
    mov %rax, %rbx
    mov %rbx, %rdi              // json_id_str(buf, pe->status, status_names)
    mov CC_PE_STATUS(%r12), %rsi
    LEA rdx, json_status_names
    call json_id_str
    mov %rax, %rbx
    movb $JSON_CH_OBJ_CLOSE, (%rbx)
    inc %rbx
    mov %rbx, %rax
    EPILOGUE 2
    ret

// ----------------------------------------------------------------------------
// cc_json_stage_event — {"stage":<stage-name>,"state":<state>}
// ----------------------------------------------------------------------------
    .p2align 4
    .global cc_json_stage_event
    FUNC_TYPE(cc_json_stage_event)
cc_json_stage_event:
    PROLOGUE 2                  // rbx = buf, r12 = se
    mov %rdi, %rbx
    mov %rsi, %r12
    movb $JSON_CH_OBJ_OPEN, (%rbx)
    inc %rbx
    mov %rbx, %rdi              // cc_json_key_str(buf, stage_key, len)
    LEA rsi, json_s_stage
    mov $JSON_KEY_STAGE_LEN, %edx
    call cc_json_key_str
    mov %rax, %rbx
    mov %rbx, %rdi              // json_id_str(buf, se->stage, stage_names)
    mov CC_SE_STAGE(%r12), %rsi
    LEA rdx, json_stage_names
    call json_id_str
    mov %rax, %rbx
    mov %rbx, %rdi              // cc_json_sep(buf, 0)
    xor %esi, %esi
    call cc_json_sep
    mov %rax, %rbx
    mov %rbx, %rdi              // cc_json_key_str(buf, state_key, len)
    LEA rsi, json_s_state
    mov $JSON_KEY_STATE_LEN, %edx
    call cc_json_key_str
    mov %rax, %rbx
    mov %rbx, %rdi              // json_id_str(buf, se->state, state_names)
    mov CC_SE_STATE(%r12), %rsi
    LEA rdx, json_state_names
    call json_id_str
    mov %rax, %rbx
    movb $JSON_CH_OBJ_CLOSE, (%rbx)
    inc %rbx
    mov %rbx, %rax
    EPILOGUE 2
    ret

// ----------------------------------------------------------------------------
// cc_json_control_cmd — {"component":<component>,"action":<action>}
// ----------------------------------------------------------------------------
    .p2align 4
    .global cc_json_control_cmd
    FUNC_TYPE(cc_json_control_cmd)
cc_json_control_cmd:
    PROLOGUE 2                  // rbx = buf, r12 = cmd
    mov %rdi, %rbx
    mov %rsi, %r12
    movb $JSON_CH_OBJ_OPEN, (%rbx)
    inc %rbx
    mov %rbx, %rdi              // cc_json_key_str(buf, component_key, len)
    LEA rsi, json_s_component
    mov $JSON_KEY_COMPONENT_LEN, %edx
    call cc_json_key_str
    mov %rax, %rbx
    mov %rbx, %rdi              // json_id_str(buf, cmd->component, component_names)
    mov CC_CMD_COMPONENT(%r12), %rsi
    LEA rdx, json_component_names
    call json_id_str
    mov %rax, %rbx
    mov %rbx, %rdi              // cc_json_sep(buf, 0)
    xor %esi, %esi
    call cc_json_sep
    mov %rax, %rbx
    mov %rbx, %rdi              // cc_json_key_str(buf, action_key, len)
    LEA rsi, json_s_action
    mov $JSON_KEY_ACTION_LEN, %edx
    call cc_json_key_str
    mov %rax, %rbx
    mov %rbx, %rdi              // json_id_str(buf, cmd->action, action_names)
    mov CC_CMD_ACTION(%r12), %rsi
    LEA rdx, json_action_names
    call json_id_str
    mov %rax, %rbx
    movb $JSON_CH_OBJ_CLOSE, (%rbx)
    inc %rbx
    mov %rbx, %rax
    EPILOGUE 2
    ret

// ----------------------------------------------------------------------------
// cc_json_status — {"paths":{...},"stages":{...}}
//   rdx/rcx: counted paths/stages tables (cc_json.h layout), entries in
//   ascending name order (Go's sorted-map output); count 0 emits "{}".
// ----------------------------------------------------------------------------
    .p2align 4
    .global cc_json_status
    FUNC_TYPE(cc_json_status)
cc_json_status:
    PROLOGUE 3                  // rbx = buf, r12 = paths tbl, r13 = stages tbl
    mov %rdi, %rbx
    mov %rdx, %r12
    mov %rcx, %r13
    movb $JSON_CH_OBJ_OPEN, (%rbx)
    inc %rbx
    mov %rbx, %rdi              // cc_json_key_str(buf, paths_key, len)
    LEA rsi, json_s_paths
    mov $JSON_KEY_PATHS_LEN, %edx
    call cc_json_key_str
    mov %rax, %rbx
    mov %rbx, %rdi              // json_obj_paths(buf, paths tbl)
    mov %r12, %rsi
    call json_obj_paths
    mov %rax, %rbx
    mov %rbx, %rdi              // cc_json_sep(buf, 0)
    xor %esi, %esi
    call cc_json_sep
    mov %rax, %rbx
    mov %rbx, %rdi              // cc_json_key_str(buf, stages_key, len)
    LEA rsi, json_s_stages
    mov $JSON_KEY_STAGES_LEN, %edx
    call cc_json_key_str
    mov %rax, %rbx
    mov %rbx, %rdi              // json_obj_stages(buf, stages tbl)
    mov %r13, %rsi
    call json_obj_stages
    mov %rax, %rbx
    movb $JSON_CH_OBJ_CLOSE, (%rbx)
    inc %rbx
    mov %rbx, %rax
    EPILOGUE 3
    ret

// ----------------------------------------------------------------------------
// cc_json_parse_control — decode a ControlCommand (POST /control).
//   rax = 0 ok / -1 error; out = {u64 component id, u64 action id}.
// ----------------------------------------------------------------------------
    .p2align 4
    .global cc_json_parse_control
    FUNC_TYPE(cc_json_parse_control)
cc_json_parse_control:
    LEA rcx, json_spec_control
    jmp json_parse_obj

// ----------------------------------------------------------------------------
// cc_json_parse_path_event — decode a PathEvent (POST /event).
//   rax = 0 ok / -1 error; out = {u64 path id, u64 status id}.
// ----------------------------------------------------------------------------
    .p2align 4
    .global cc_json_parse_path_event
    FUNC_TYPE(cc_json_parse_path_event)
cc_json_parse_path_event:
    LEA rcx, json_spec_path_event
    jmp json_parse_obj

    .text
    .end