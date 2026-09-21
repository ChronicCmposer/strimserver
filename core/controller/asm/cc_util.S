// ============================================================================
// cc_util.S — shared utilities for the strimserver controller
// ============================================================================
//
//  Target:     AArch64 (ARMv8.2-A), little-endian — Linux (ELF, static);
//              cc_platform.h is the only platform header (Linux-only).
//  Assembler:  GNU as syntax, preprocessed by the C compiler
//              (`cc -c -x assembler-with-cpp`).
//  ISA:        .arch armv8.2-a — exactly one in-source directive (below),
//              nothing higher, no .arch_extension, no .cpu (Graviton2 parity).
//
//  This module owns every .global utility the other cc_*.S modules share;
//  main() lives in cc_main.S.  It is the controller's equivalent of the
//  reference project's tc_util.S, Linux branch.
//
//  Exported (all .global, AAPCS64, x19-x28 preserved):
//    cc_strlen(x0=s)          -> x0 = byte length of a NUL-terminated string
//    cc_streq(x0=a, x1=b)     -> x0 = 1/0 (strings equal?)
//    cc_puts(x0=s)            print string to stdout (unbuffered write(2))
//    cc_eputs(x0=s)           print string to stderr (unbuffered)
//    cc_putu64(x0=v)          print unsigned 64-bit decimal to stdout, no commas
//    cc_fail(x0=msg)          print "error: <msg>\n" to stderr, exit 1 (noreturn)
//    cc_cat_cstr(x0=dst, x1=s)  -> x0 = position of the copied NUL
//    cc_fmt2(x0=dst, x1=0..99)  -> x0 = dst+2 (two zero-padded digits, no NUL)
//    cc_fmt4(x0=dst, x1=0..9999) -> x0 = dst+4 (four zero-padded digits, no NUL)
//    cc_env_int(x0=name)      -> x0 = int or 0 (port of tc_env_int)
//    cc_snprintf_i(x0=buf, x1=size, x2=fmt, x3=int)     -> x0 = snprintf() result
//    cc_snprintf_d(x0=buf, x1=size, x2=fmt, d0=double)  -> x0 = snprintf() result
//      (fixed-arity wrappers for the variadic libc calls; see below and
//      cc_platform.h — modules never call snprintf directly)
//
//  AAPCS64 notes (the rules every module must follow)
//  --------------------------------------------------
//    * Arguments in x0-x7 (integer) / v0-v7 (float); return in x0 (x1 for
//      128-bit); composites are returned in x0..x3 or via x8 (sret).
//    * Callee-saved (must be preserved across any `bl` we make):
//      x19-x28, x29 (FP).  x30 (LR) is saved by the callee that calls.
//      x18 is the platform register — never touch it.
//    * sp must stay 16-byte aligned at every call site.
//    * Never join statements with ';' — it is a comment character in this
//      project's dialect.  One instruction per line.
//
//  Deviations from the reference tc_util.S (documented, deliberate)
//  ---------------------------------------------------------------
//    * cc_puts / cc_fail do NOT fflush(NULL) first: the controller is a
//      fresh static binary that never touches stdio buffers, so raw
//      write(2) output is always correctly ordered.  (The reference
//      flushes because twitch-counts shares the process with libc stdio.)
//    * cc_fail restores its {x19, x30} frame before the noreturn exit(1):
//      this project's check-clobbers.sh requires every callee-saved save to
//      have a matching restore even on the noreturn path.
// ============================================================================

#include "cc_platform.h"
#include "cc_layout.inc"
    .arch armv8.2-a
    .text

// ----------------------------------------------------------------------------
// Constants
// ----------------------------------------------------------------------------
// DIV10_MAGIC, SWAR_MASK_01/SWAR_MASK_80, NANOSEC and the MOV_* load macros
// live in cc_platform.h (shared, fail-loud against module-local .equ copies).

// ----------------------------------------------------------------------------
// cc_strlen — length of a NUL-terminated string.
//   in:  x0 = pointer to the string
//   out: x0 = number of bytes before the NUL
//   Word-at-a-time: align to 8 with a byte walk (checking for the NUL as we
//   go), then scan 8-byte words with the has-zero-byte trick
//   ((w - 0x0101..01) & ~w & 0x8080..80); aligned 8-byte loads never cross a
//   page, so the scan cannot fault past the NUL.  x3/x4 are saved so the
//   clobber set stays exactly x0-x2, as the callers were written against.
// ----------------------------------------------------------------------------
    .p2align 2
    .global cc_strlen
    FUNC_TYPE(cc_strlen)
cc_strlen:
    stp x3, x4, [sp, #-16]!         // honor the x0-x2-only clobber contract
    mov x1, x0                      // x1 = scan pointer
    and x3, x1, #7                  // already 8-aligned?
    cbz x3, .Lslw_word
.Lslw_align:
    ldrb w2, [x1], #1               // byte walk until aligned
    cbz w2, .Lslw_nul_align         // NUL before the first word
    and x3, x1, #7
    cbnz x3, .Lslw_align
.Lslw_word:
    mov x2, #SWAR_MASK_01            // the 0x01..01 mask
.Lslw_loop:
    ldr x3, [x1]                    // next word
    sub x4, x3, x2                  // w - 0x01..01
    bic x4, x4, x3                  // & ~w
    and x4, x4, x2, lsl #7          // & 0x80..80: set bit 7 per zero byte
    cbnz x4, .Lslw_zero
    add x1, x1, #8
    b .Lslw_loop
.Lslw_zero:
    rbit x4, x4                     // lowest zero byte -> highest bit
    clz x4, x4
    lsr x4, x4, #3                  // byte index of the NUL in this word
    add x1, x1, x4                  // x1 = &NUL
    sub x0, x1, x0                  // length = NUL - start
    ldp x3, x4, [sp], #16
    ret
.Lslw_nul_align:
    sub x0, x1, x0                  // x1 = one past the NUL
    sub x0, x0, #1
    ldp x3, x4, [sp], #16
    ret

// ----------------------------------------------------------------------------
// cc_streq — string equality.
//   in:  x0 = pointer a, x1 = pointer b
//   out: x0 = 1 when the strings are equal (byte-identical up to and
//        including the NUL), else 0
// ----------------------------------------------------------------------------
    .p2align 2
    .global cc_streq
    FUNC_TYPE(cc_streq)
cc_streq:
    stp x2, x3, [sp, #-16]!
    stp x4, x5, [sp, #-16]!
    mov x2, x0
    mov x3, x1
.Lse_loop:
    ldrb w4, [x2], #1
    ldrb w5, [x3], #1
    cmp w4, w5
    b.ne .Lse_no
    cbnz w4, .Lse_loop
    mov x0, #1
    b .Lse_ret
.Lse_no:
    mov x0, #0
.Lse_ret:
    ldp x4, x5, [sp], #16
    ldp x2, x3, [sp], #16
    ret

// ----------------------------------------------------------------------------
// cc_puts — write a NUL-terminated string to stdout.
//   in:  x0 = pointer to the string
//   out: none
//   Unbuffered via write(2); no stdio flush (the controller never touches
//   stdio buffers).  Preserves x19-x28; sp stays 16-aligned.
// ----------------------------------------------------------------------------
    .p2align 2
    .global cc_puts
    FUNC_TYPE(cc_puts)
cc_puts:
    stp x19, x30, [sp, #-16]!       // save x19 (held string) + return address
    mov x19, x0                     // x19 = string (safe across calls)
    bl cc_strlen                    // x0 = length
    mov x2, x0                      // write(1, string, length)
    mov x0, #STDOUT
    mov x1, x19
    bl write
    ldp x19, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// cc_eputs — write a NUL-terminated string to stderr (unbuffered).
//   in:  x0 = pointer to the string
//   Preserves x19-x28; sp stays 16-aligned.
// ----------------------------------------------------------------------------
    .p2align 2
    .global cc_eputs
    FUNC_TYPE(cc_eputs)
cc_eputs:
    stp x19, x30, [sp, #-16]!
    mov x19, x0
    bl cc_strlen
    mov x2, x0                      // write(2, string, length)
    mov x0, #STDERR
    mov x1, x19
    bl write
    ldp x19, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// cc_putu64 — print an unsigned 64-bit value in decimal to stdout (no commas).
//   in:  x0 = the value
//   out: none
//   Digits are produced least-significant first into a 32-byte stack frame
//   (20 digits + NUL), then handed to cc_puts.  Preserves x19-x28.
// ----------------------------------------------------------------------------
    .p2align 2
    .global cc_putu64
    FUNC_TYPE(cc_putu64)
cc_putu64:
    stp x19, x30, [sp, #-16]!       // save x19 (running value) + return address
    sub sp, sp, #32                 // 21-byte digit buffer (32 keeps 16-aligned)
    mov x19, x0                     // x19 = value (safe across cc_puts)
    add x1, sp, #20                 // write digits downward from buf+20
    mov x2, #0                      // x2 = digit count
    MOV_DIV10_MAGIC x4              // divide-by-10 magic (umulh >> 3)
    cmp x19, #0
    b.ne .Lputu_digit_loop
    mov x3, #'0'                    // zero case: emit a single '0'
    strb w3, [x1, #-1]!
    mov x2, #1
    b .Lputu_done
.Lputu_digit_loop:
    umulh x5, x19, x4               // quotient = value / 10
    lsr x5, x5, #3
    mov x3, #10
    msub x6, x5, x3, x19            // remainder
    add x6, x6, #'0'                // remainder -> ASCII digit
    strb w6, [x1, #-1]!             // store digit, walk the pointer down
    add x2, x2, #1
    mov x19, x5                     // continue with the quotient
    cbnz x19, .Lputu_digit_loop
.Lputu_done:
    mov x0, #0
    strb w0, [x1, x2]               // NUL at buf+20 -> digits are a C string
    mov x0, x1                      // cc_puts(first_digit)
    bl cc_puts
    add sp, sp, #32
    ldp x19, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// cc_fail — print "error: <message>" to stderr and exit 1.
//   in:  x0 = NUL-terminated message
//   Never returns.  The {x19, x30} frame is restored before the noreturn
//   exit(1) so the callee-saved save stays balanced (check-clobbers.sh).
// ----------------------------------------------------------------------------
    .p2align 2
    .global cc_fail
    FUNC_TYPE(cc_fail)
cc_fail:
    stp x19, x30, [sp, #-16]!       // save x19 (held message) + return address
    mov x19, x0                     // x19 = message
    mov x0, #STDERR                 // write(2, "error: ", util_err_prefix_len)
    LEA x1, util_err_prefix
    mov x2, #util_err_prefix_len
    bl write
    mov x0, x19                     // cc_eputs(message)
    bl cc_eputs
    mov x0, #STDERR                 // write(2, "\n", util_err_newline_len)
    LEA x1, util_err_newline
    mov x2, #util_err_newline_len
    bl write
    ldp x19, x30, [sp], #16         // unwind before the noreturn call
    mov w0, #1                      // exit(1)
    b exit

// ----------------------------------------------------------------------------
// Fixed-arity wrappers for the variadic libc calls the modules make.
//
//   cc_snprintf_i(x0=buf, x1=size, x2=fmt, x3=int)     -> x0 = int
//   cc_snprintf_d(x0=buf, x1=size, x2=fmt, d0=double)  -> x0 = int
//
//   Call sites set the registers up exactly as for the libc function and
//   only differ in the `bl` target.  On Linux (AAPCS64) the one anonymous
//   argument is already where snprintf reads it, so the wrapper is a tail
//   call.  (The reference carries a Darwin body here; this project is
//   Linux-only, so there is only the tail call.)  Like the libc call they
//   wrap, the wrappers clobber x0-x17 and preserve x19-x28.
// ----------------------------------------------------------------------------
    .p2align 2
    .global cc_snprintf_i
    FUNC_TYPE(cc_snprintf_i)
cc_snprintf_i:
    b snprintf                      // x3 is already the first anonymous argument

    .p2align 2
    .global cc_snprintf_d
    FUNC_TYPE(cc_snprintf_d)
cc_snprintf_d:
    b snprintf                      // d0 is already the first anonymous argument

// ----------------------------------------------------------------------------
// cc_cat_cstr(x0=cursor, x1=s) -> x0 = the position of the terminating NUL
//   (the string is copied NUL and all; callers overwrite the NUL with the
//   next thing they append).
//   Word-at-a-time: align the source to 8 with a byte walk (copying as we
//   go), then copy 8-byte words whole until one contains a NUL, then finish
//   byte-by-byte at the NUL.  Aligned loads never cross a page, and the
//   destination is never written past the NUL.  x2-x7 are saved, so the
//   routine still clobbers only x0 (its documented contract).
// ----------------------------------------------------------------------------
    .p2align 2
    .global cc_cat_cstr
    FUNC_TYPE(cc_cat_cstr)
cc_cat_cstr:
    stp x2, x3, [sp, #-16]!
    stp x4, x5, [sp, #-16]!
    stp x6, x7, [sp, #-16]!
    mov x2, x0                      // dst (advances)
    mov x3, x1                      // src (advances)
    mov x7, #SWAR_MASK_01            // the 0x01..01 mask
    and x5, x3, #7                  // source already 8-aligned?
    cbz x5, .Lcc_word
.Lcc_align:
    ldrb w4, [x3], #1
    strb w4, [x2], #1
    cbz w4, .Lcc_done_align         // NUL during the byte walk
    and x5, x3, #7
    cbnz x5, .Lcc_align
.Lcc_word:
    ldr x4, [x3]                    // next word
    sub x6, x4, x7
    bic x6, x6, x4
    and x5, x6, x7, lsl #7          // zero-byte mask
    cbnz x5, .Lcc_zero
    str x4, [x2]                    // whole word has no NUL: store it all
    add x2, x2, #8
    add x3, x3, #8
    b .Lcc_word
.Lcc_zero:
    rbit x5, x5
    clz x5, x5
    lsr x5, x5, #3                  // byte index of the NUL in this word
    mov x6, #0
.Lcc_tail:
    cmp x6, x5
    b.gt .Lcc_done
    ldrb w4, [x3, x6]               // store up to and including the NUL
    strb w4, [x2, x6]
    add x6, x6, #1
    b .Lcc_tail
.Lcc_done:
    add x0, x2, x5                  // x0 = position of the NUL
    ldp x6, x7, [sp], #16
    ldp x4, x5, [sp], #16
    ldp x2, x3, [sp], #16
    ret
.Lcc_done_align:
    sub x0, x2, #1                  // x2 = one past the NUL
    ldp x6, x7, [sp], #16
    ldp x4, x5, [sp], #16
    ldp x2, x3, [sp], #16
    ret

// ----------------------------------------------------------------------------
// cc_fmt2(x0=dst, x1=0..99)   -> x0 = dst+2   two zero-padded digits, no NUL
// cc_fmt4(x0=dst, x1=0..9999) -> x0 = dst+4   four zero-padded digits, no NUL
// ----------------------------------------------------------------------------
    .p2align 2
    .global cc_fmt2
    FUNC_TYPE(cc_fmt2)
cc_fmt2:
    stp x2, x3, [sp, #-16]!
    stp x4, x5, [sp, #-16]!
    MOV_DIV10_MAGIC x2              // divide-by-10 magic (umulh >> 3)
    umulh x3, x1, x2
    lsr x3, x3, #3                  // tens digit
    mov x5, #10
    msub x4, x3, x5, x1             // ones digit
    add x3, x3, #'0'
    strb w3, [x0], #1
    add x4, x4, #'0'
    strb w4, [x0], #1
    ldp x4, x5, [sp], #16
    ldp x2, x3, [sp], #16
    ret

    .p2align 2
    .global cc_fmt4
    FUNC_TYPE(cc_fmt4)
cc_fmt4:
    PROLOGUE 2                      // x19/x20/x21 hold high/low/dst across the
    MOV_DIV10_MAGIC x2              // cc_fmt2 calls (cc_fmt2 may clobber x2-x5)
    umulh x3, x1, x2
    lsr x3, x3, #3                  // q1 = v/10
    umulh x3, x3, x2
    lsr x3, x3, #3                  // q2 = v/100  (thousands + hundreds)
    mov x6, #100
    msub x19, x3, x6, x1            // low = v % 100 (tens + ones)
    mov x20, x3                     // high
    mov x21, x0                     // dst
    mov x0, x21
    mov x1, x20
    bl cc_fmt2                      // high digits; x0 = dst+2
    mov x1, x19
    bl cc_fmt2                      // low digits; x0 = dst+4
    EPILOGUE 2
    ret

// ----------------------------------------------------------------------------
// cc_env_int(x0=name) -> x0 = int(os.environ[name]) when the variable is set
//   to a positive integer, else 0.  Port of tc_env_int (which mirrors
//   Python's int() grammar for what matters: surrounding whitespace, an
//   optional sign, digits with single '_' separators; anything else is a
//   ValueError, and a value <= 0 is treated the same way -- "ask the
//   terminal").  The controller uses it for its uint8 config envs; callers
//   validate the returned range (cc_env.S masks to 8 bits).  Preserves
//   x19-x28.
// ----------------------------------------------------------------------------
    .p2align 2
    .global cc_env_int
    FUNC_TYPE(cc_env_int)
cc_env_int:
    PROLOGUE 2
    bl getenv
    cbz x0, .Lei_none
    mov x19, x0
.Lei_lead:
    ldrb w0, [x19]
    bl util_ei_is_space
    cbz w0, .Lei_sign
    add x19, x19, #1
    b .Lei_lead
.Lei_sign:
    ldrb w0, [x19]
    cmp w0, #'-'
    b.eq .Lei_none                  // negative: "<= 0" -> the caller's default
    cmp w0, #'+'
    b.ne .Lei_digits
    add x19, x19, #1
.Lei_digits:
    mov x20, #0                     // value
    mov x21, #0                     // digits seen
    mov x22, #0                     // previous byte was '_'
.Lei_loop:
    ldrb w0, [x19]
    cmp w0, #'_'
    b.ne .Lei_not_us
    cbz x21, .Lei_none              // '_' before any digit
    cbnz x22, .Lei_none             // '__'
    mov x22, #1
    add x19, x19, #1
    b .Lei_loop
.Lei_not_us:
    cmp w0, #'0'
    b.lt .Lei_end
    cmp w0, #'9'
    b.gt .Lei_end
    sub w0, w0, #'0'
    mov x1, #10
    mul x20, x20, x1
    add x20, x20, x0
    mov x1, #0x7fffffff
    cmp x20, x1
    b.le .Lei_digit_ok
    mov x20, x1                     // saturate: large is large
.Lei_digit_ok:
    mov x21, #1
    mov x22, #0
    add x19, x19, #1
    b .Lei_loop
.Lei_end:
    cbz x21, .Lei_none              // no digits
    cbnz x22, .Lei_none             // trailing '_'
.Lei_trail:
    ldrb w0, [x19]
    cbz w0, .Lei_done
    bl util_ei_is_space
    cbz w0, .Lei_none               // junk after the number
    add x19, x19, #1
    b .Lei_trail
.Lei_done:
    mov x0, x20
    b .Lei_ret
.Lei_none:
    mov x0, #0
.Lei_ret:
    EPILOGUE 2
    ret

// util_ei_is_space(w0=byte) -> w0 = 1 for ASCII whitespace (space, \t\n\v\f\r)
    .p2align 2
util_ei_is_space:
    cmp w0, #' '
    b.eq .Leis_yes
    cmp w0, #9
    b.lt .Leis_no
    cmp w0, #13
    b.le .Leis_yes
.Leis_no:
    mov w0, #0
    ret
.Leis_yes:
    mov w0, #1
    ret

// ----------------------------------------------------------------------------
// Read-only message data.  Lengths are label differences so the writer and
// the length can never drift apart.
// ----------------------------------------------------------------------------
    RODATA
util_err_prefix:
    .ascii "error: "
util_err_prefix_end:
    .equ util_err_prefix_len, util_err_prefix_end - util_err_prefix
util_err_newline:
    .ascii "\n"
util_err_newline_end:
    .equ util_err_newline_len, util_err_newline_end - util_err_newline

    .text

    .end