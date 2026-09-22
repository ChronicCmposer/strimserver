// ============================================================================
// cc_util.S — shared utilities for the strimserver controller (x86-64 port)
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
//  This module owns every .global utility the other cc_*.S modules share;
//  main() lives in cc_main.S.  It is the x86-64 translation of the AArch64
//  cc_util.S.
//
//  Exported (all .global, SysV, %rbx/%rbp/%r12-%r15 preserved):
//    cc_strlen(rdi=s)            -> rax = byte length of a NUL-terminated string
//    cc_streq(rdi=a, rsi=b)      -> rax = 1/0 (strings equal?)
//    cc_puts(rdi=s)              print string to stdout (unbuffered write(2))
//    cc_eputs(rdi=s)             print string to stderr (unbuffered)
//    cc_putu64(rdi=v)            print unsigned 64-bit decimal to stdout, no commas
//    cc_fail(rdi=msg)            print "error: <msg>\n" to stderr, exit 1 (noreturn)
//    cc_cat_cstr(rdi=dst, rsi=s) -> rax = position of the copied NUL
//    cc_fmt2(rdi=dst, rsi=0..99) -> rax = dst+2 (two zero-padded digits, no NUL)
//    cc_fmt4(rdi=dst, rsi=0..9999) -> rax = dst+4 (four zero-padded digits, no NUL)
//    cc_env_int(rdi=name)        -> rax = int or 0 (port of tc_env_int)
//    cc_snprintf_i(rdi=buf, rsi=size, rdx=fmt, rcx=int)     -> rax = snprintf() result
//    cc_snprintf_d(rdi=buf, rsi=size, rdx=fmt, xmm0=double) -> rax = snprintf() result
//      (fixed-arity wrappers for the variadic libc calls; see below and
//      cc_platform_x86_64.h — modules never call snprintf directly)
//
//  SysV AMD64 notes (the rules every module must follow)
//  ----------------------------------------------------
//    * Arguments in %rdi, %rsi, %rdx, %rcx, %r8, %r9 (integer/pointer);
//      floats in %xmm0-%xmm7; return in %rax (%rdx:%rax for 128-bit);
//      composites via a hidden sret pointer in %rdi.
//    * Callee-saved (must be preserved across any `call`): %rbx, %rbp,
//      %r12-%r15.  %rsp must stay 16-byte aligned at every call site.
//    * `call` pushes the return address (the SysV link) and `ret` pops it;
//      only `jmp` is a tail call.  Never join statements with ';' — it is a
//      statement separator in GNU-as x86 syntax; this project's dialect uses
//      `//` comments and one instruction per line.
//
//  Translation notes (deviations from the AArch64 original, deliberate)
//  --------------------------------------------------------------------
//    * cc_strlen and cc_cat_cstr both use the scalar SWAR word-at-a-time
//      scan (8-byte stride), byte-identical to the AArch64 SWAR result.  An
//      AVX2 32-byte scan (vmovdqu + vpcmpeqb + vpmovmskb + tzcnt) was
//      evaluated for the cc_strlen hot path and is byte-identical too, but
//      the scalar form keeps the module free of SIMD writes.
//    * cc_puts / cc_fail do NOT fflush(NULL) first: the controller is a
//      fresh static binary that never touches stdio buffers, so raw write(2)
//      output is always correctly ordered.
//    * cc_fail restores its frame before the noreturn exit(1): this
//      project's check-clobbers-x86_64.sh requires every callee-saved save
//      to have a matching restore even on the noreturn path.
// ============================================================================

#include "cc_platform_x86_64.h"
#include "../cc_layout.inc"
    .text

// ----------------------------------------------------------------------------
// Constants
// ----------------------------------------------------------------------------
// DIV10_MAGIC, SWAR_MASK_01/SWAR_MASK_80, NANOSEC and the MOV_* load macros
// live in cc_platform_x86_64.h (shared, fail-loud against module-local .equ
// copies).

// ----------------------------------------------------------------------------
// cc_strlen — length of a NUL-terminated string.
//   in:  %rdi = pointer to the string
//   out: %rax = number of bytes before the NUL
//   SWAR word-at-a-time: align to 8 with a byte walk (checking for the NUL
//   as we go), then scan 8-byte words with the has-zero-byte trick
//   ((w - 0x0101..01) & ~w & 0x8080..80); aligned 8-byte loads never cross a
//   page, so the scan cannot fault past the NUL.  (An AVX2 32-byte variant
//   was evaluated — vmovdqu + vpcmpeqb + vpmovmskb + tzcnt — and is
//   byte-identical, but this form keeps the module free of SIMD writes.)
//   Clobbers only caller-saved registers (%rax/%rcx/%rdx/%rsi), the SysV
//   analogue of the AArch64 original's x0-x2-only clobber contract.
// ----------------------------------------------------------------------------
    .p2align 4
    .global cc_strlen
    FUNC_TYPE(cc_strlen)
cc_strlen:
    mov %rdi, %rsi                  // %rsi = scan pointer
    test $7, %rsi                   // already 8-aligned?
    jz .Lslw_word
.Lslw_align:
    movzbl (%rsi), %eax             // byte walk until aligned
    test %eax, %eax
    jz .Lslw_nul                    // NUL before the first word
    inc %rsi
    test $7, %rsi
    jnz .Lslw_align
.Lslw_word:
    movabs $SWAR_MASK_01, %rdx      // the 0x01..01 mask
.Lslw_loop:
    mov (%rsi), %rax                // next word
    mov %rax, %rcx
    sub %rdx, %rcx                  // w - 0x01..01
    not %rax                        // ~w
    and %rax, %rcx
    movabs $SWAR_MASK_80, %rax      // & 0x80..80: bit 7 set per zero byte
    and %rax, %rcx
    jnz .Lslw_zero
    add $8, %rsi
    jmp .Lslw_loop
.Lslw_zero:
    bsf %rcx, %rcx                  // lowest zero byte -> lowest set bit
    shr $3, %rcx                    // byte index of the NUL in this word
    add %rcx, %rsi                  // %rsi = &NUL
    mov %rsi, %rax
    sub %rdi, %rax                  // length = NUL - start
    ret
.Lslw_nul:
    mov %rsi, %rax                  // %rsi = &NUL (byte walk never passed it)
    sub %rdi, %rax                  // length = NUL - start
    ret

// ----------------------------------------------------------------------------
// cc_streq — string equality.
//   in:  %rdi = pointer a, %rsi = pointer b
//   out: %rax = 1 when the strings are equal (byte-identical up to and
//        including the NUL), else 0
// ----------------------------------------------------------------------------
    .p2align 4
    .global cc_streq
    FUNC_TYPE(cc_streq)
cc_streq:
.Lse_loop:
    movzbl (%rdi), %eax
    movzbl (%rsi), %ecx
    cmp %eax, %ecx
    jne .Lse_no
    test %eax, %eax
    jz .Lse_yes
    inc %rdi
    inc %rsi
    jmp .Lse_loop
.Lse_no:
    xor %eax, %eax
    ret
.Lse_yes:
    mov $1, %eax
    ret

// ----------------------------------------------------------------------------
// cc_puts — write a NUL-terminated string to stdout.
//   in:  %rdi = pointer to the string
//   out: none
//   Unbuffered via write(2); no stdio flush (the controller never touches
//   stdio buffers).  Preserves %rbx/%rbp/%r12-%r15; %rsp stays 16-aligned.
// ----------------------------------------------------------------------------
    .p2align 4
    .global cc_puts
    FUNC_TYPE(cc_puts)
cc_puts:
    PROLOGUE 1                      // %rbx holds the string across the calls
    mov %rdi, %rbx
    call cc_strlen                  // %rax = length (%rdi still = string)
    mov %rax, %rdx                  // write(1, string, length)
    mov $STDOUT, %edi
    mov %rbx, %rsi
    call write
    EPILOGUE 1
    ret

// ----------------------------------------------------------------------------
// cc_eputs — write a NUL-terminated string to stderr (unbuffered).
//   in:  %rdi = pointer to the string
//   Preserves %rbx/%rbp/%r12-%r15; %rsp stays 16-aligned.
// ----------------------------------------------------------------------------
    .p2align 4
    .global cc_eputs
    FUNC_TYPE(cc_eputs)
cc_eputs:
    PROLOGUE 1                      // %rbx holds the string across the calls
    mov %rdi, %rbx
    call cc_strlen                  // %rax = length (%rdi still = string)
    mov %rax, %rdx                  // write(2, string, length)
    mov $STDERR, %edi
    mov %rbx, %rsi
    call write
    EPILOGUE 1
    ret

// ----------------------------------------------------------------------------
// cc_putu64 — print an unsigned 64-bit value in decimal to stdout (no commas).
//   in:  %rdi = the value
//   out: none
//   Digits are produced least-significant first into a 32-byte stack frame
//   (20 digits + NUL), then handed to cc_puts.  Preserves %rbx/%rbp/%r12-%r15.
// ----------------------------------------------------------------------------
    .p2align 4
    .global cc_putu64
    FUNC_TYPE(cc_putu64)
cc_putu64:
    PROLOGUE 1                      // %rbx holds the running value
    sub $32, %rsp                   // 21-byte digit buffer (32 keeps 16-aligned)
    mov %rdi, %rbx                  // %rbx = value (safe across cc_puts)
    lea 20(%rsp), %rsi              // write digits downward from buf+20
    xor %r9d, %r9d                  // %r9d = digit count
    MOV_DIV10_MAGIC rcx             // divide-by-10 magic (mulhi >> 3)
    test %rbx, %rbx
    jnz .Lputu_digit_loop
    mov $'0', %eax                  // zero case: emit a single '0'
    dec %rsi
    mov %al, (%rsi)
    mov $1, %r9d
    jmp .Lputu_done
.Lputu_digit_loop:
    mov %rbx, %rax
    mul %rcx                        // rdx:rax = value * magic
    shr $3, %rdx                    // quotient = value / 10
    imul $10, %rdx, %r8             // %r8 = quotient * 10
    mov %rbx, %rax
    sub %r8, %rax                   // remainder = value - quotient*10
    add $'0', %eax                  // remainder -> ASCII digit
    dec %rsi
    mov %al, (%rsi)                 // store digit, walk the pointer down
    inc %r9d
    mov %rdx, %rbx                  // continue with the quotient
    test %rbx, %rbx
    jnz .Lputu_digit_loop
.Lputu_done:
    mov %r9d, %eax                  // %rax = digit count (index of the NUL)
    movb $0, (%rsi,%rax)            // NUL at buf+20 -> digits are a C string
    mov %rsi, %rdi                  // cc_puts(first_digit)
    call cc_puts
    add $32, %rsp
    EPILOGUE 1
    ret

// ----------------------------------------------------------------------------
// cc_fail — print "error: <message>" to stderr and exit 1.
//   in:  %rdi = NUL-terminated message
//   Never returns.  The frame is restored before the noreturn exit(1) so the
//   callee-saved save stays balanced (check-clobbers-x86_64.sh).
// ----------------------------------------------------------------------------
    .p2align 4
    .global cc_fail
    FUNC_TYPE(cc_fail)
cc_fail:
    PROLOGUE 1                      // %rbx holds the message across the calls
    mov %rdi, %rbx
    mov $STDERR, %edi               // write(2, "error: ", util_err_prefix_len)
    LEA rsi, util_err_prefix
    mov $util_err_prefix_len, %edx
    call write
    mov %rbx, %rdi                  // cc_eputs(message)
    call cc_eputs
    mov $STDERR, %edi               // write(2, "\n", util_err_newline_len)
    LEA rsi, util_err_newline
    mov $util_err_newline_len, %edx
    call write
    EPILOGUE 1                      // unwind before the noreturn call
    mov $1, %edi                    // exit(1)
    jmp exit

// ----------------------------------------------------------------------------
// Fixed-arity wrappers for the variadic libc calls the modules make.
//
//   cc_snprintf_i(rdi=buf, rsi=size, rdx=fmt, rcx=int)     -> rax = int
//   cc_snprintf_d(rdi=buf, rsi=size, rdx=fmt, xmm0=double) -> rax = int
//
//   Call sites set the registers up exactly as for the libc function and
//   only differ in the call target.  On SysV the one anonymous argument is
//   already where snprintf reads it, so the wrapper is a tail call — but
//   SysV also carries the number of vector arguments in %al, which the
//   wrapper must set before the tail jump (1 for the double, 0 for the int).
// ----------------------------------------------------------------------------
    .p2align 4
    .global cc_snprintf_i
    FUNC_TYPE(cc_snprintf_i)
cc_snprintf_i:
    xor %eax, %eax                  // %al = 0 vector registers (int variadic)
    jmp snprintf                    // %rcx is already the first anonymous argument

    .p2align 4
    .global cc_snprintf_d
    FUNC_TYPE(cc_snprintf_d)
cc_snprintf_d:
    mov $1, %al                     // %al = 1 vector register (double variadic)
    jmp snprintf                    // %xmm0 is already the first anonymous argument

// ----------------------------------------------------------------------------
// cc_cat_cstr(rdi=cursor, rsi=s) -> rax = the position of the terminating NUL
//   (the string is copied NUL and all; callers overwrite the NUL with the
//   next thing they append).
//   Scalar SWAR word-at-a-time: align the source to 8 with a byte walk
//   (copying as we go), then copy 8-byte words whole until one contains a
//   NUL, then finish byte-by-byte at the NUL.  Aligned loads never cross a
//   page, and the destination is never written past the NUL.  Clobbers only
//   caller-saved registers (%rax/%rcx/%rdx/%rsi/%rdi/%r8-%r11).
// ----------------------------------------------------------------------------
    .p2align 4
    .global cc_cat_cstr
    FUNC_TYPE(cc_cat_cstr)
cc_cat_cstr:
    mov %rsi, %r8                   // %r8 = src (advances)
    mov %rdi, %r9                   // %r9 = dst (advances)
    test $7, %r8                    // source already 8-aligned?
    jz .Lcc_word
.Lcc_align:
    movzbl (%r8), %eax
    mov %al, (%r9)
    inc %r8
    inc %r9
    test %eax, %eax
    jz .Lcc_done_align              // NUL during the byte walk
    mov %r8, %rcx
    and $7, %rcx
    jnz .Lcc_align
.Lcc_word:
    movabs $SWAR_MASK_01, %rcx      // the 0x01..01 mask
.Lcc_loop:
    mov (%r8), %r10                 // next word
    mov %r10, %rax
    sub %rcx, %rax                  // w - 0x01..01
    mov %r10, %rdx
    not %rdx                        // ~w
    and %rdx, %rax
    movabs $SWAR_MASK_80, %rdx      // & 0x80..80: bit 7 set per zero byte
    and %rdx, %rax
    jnz .Lcc_zero
    mov %r10, (%r9)                 // whole word has no NUL: store it all
    add $8, %r8
    add $8, %r9
    jmp .Lcc_loop
.Lcc_zero:
    bsf %rax, %rax                  // lowest zero byte -> lowest set bit
    shr $3, %rax                    // byte index of the NUL in this word
    xor %r11d, %r11d                // %r11 = byte index
.Lcc_tail:
    cmp %rax, %r11
    jg .Lcc_done
    movzbl (%r8,%r11), %edx         // store up to and including the NUL
    mov %dl, (%r9,%r11)
    inc %r11
    jmp .Lcc_tail
.Lcc_done:
    lea (%r9,%rax), %rax            // %rax = position of the NUL
    ret
.Lcc_done_align:
    lea -1(%r9), %rax               // %r9 = one past the NUL
    ret

// ----------------------------------------------------------------------------
// cc_fmt2(rdi=dst, rsi=0..99)   -> rax = dst+2   two zero-padded digits, no NUL
// cc_fmt4(rdi=dst, rsi=0..9999) -> rax = dst+4   four zero-padded digits, no NUL
// ----------------------------------------------------------------------------
    .p2align 4
    .global cc_fmt2
    FUNC_TYPE(cc_fmt2)
cc_fmt2:
    MOV_DIV10_MAGIC rcx             // divide-by-10 magic (mulhi >> 3)
    mov %rsi, %rax
    mul %rcx                        // rdx:rax = value * magic
    shr $3, %rdx                    // tens digit
    imul $10, %rdx, %rax            // %rax = tens * 10
    mov %rsi, %rcx
    sub %rax, %rcx                  // ones digit
    add $'0', %edx
    mov %dl, (%rdi)
    inc %rdi
    add $'0', %ecx
    mov %cl, (%rdi)
    inc %rdi
    mov %rdi, %rax                  // return dst+2
    ret

    .p2align 4
    .global cc_fmt4
    FUNC_TYPE(cc_fmt4)
cc_fmt4:
    PROLOGUE 1                      // %rbx holds the low digits across the call
    MOV_DIV10_MAGIC rcx
    mov %rsi, %rax
    mul %rcx                        // rdx:rax = value * magic
    shr $3, %rdx                    // q1 = value/10
    mov %rdx, %rax
    mul %rcx                        // rdx:rax = q1 * magic
    shr $3, %rdx                    // q2 = value/100 (thousands + hundreds)
    imul $100, %rdx, %rax           // %rax = q2 * 100
    mov %rsi, %rcx
    sub %rax, %rcx                  // low = value % 100 (tens + ones)
    mov %rcx, %rbx                  // %rbx = low (safe across cc_fmt2)
    mov %rdx, %rsi                  // cc_fmt2(dst, high)
    call cc_fmt2                    // high digits; %rax = dst+2
    mov %rax, %rdi
    mov %rbx, %rsi                  // cc_fmt2(dst+2, low)
    call cc_fmt2                    // low digits; %rax = dst+4
    EPILOGUE 1
    ret

// ----------------------------------------------------------------------------
// cc_env_int(rdi=name) -> rax = int(os.environ[name]) when the variable is
//   set to a positive integer, else 0.  Port of tc_env_int (which mirrors
//   Python's int() grammar for what matters: surrounding whitespace, an
//   optional sign, digits with single '_' separators; anything else is a
//   ValueError, and a value <= 0 is treated the same way -- "ask the
//   terminal").  The controller uses it for its uint8 config envs; callers
//   validate the returned range (cc_env.S masks to 8 bits).  Preserves
//   %rbx/%rbp/%r12-%r15.
// ----------------------------------------------------------------------------
    .p2align 4
    .global cc_env_int
    FUNC_TYPE(cc_env_int)
cc_env_int:
    PROLOGUE 4                      // rbx=ptr r12=value r13=digits r14=underscore
    call getenv
    test %rax, %rax
    jz .Lei_none
    mov %rax, %rbx
.Lei_lead:
    movzbl (%rbx), %edi
    call util_ei_is_space
    test %eax, %eax
    jz .Lei_sign
    inc %rbx
    jmp .Lei_lead
.Lei_sign:
    movzbl (%rbx), %eax
    cmp $'-', %eax
    je .Lei_none                    // negative: "<= 0" -> the caller's default
    cmp $'+', %eax
    jne .Lei_digits
    inc %rbx
.Lei_digits:
    xor %r12d, %r12d                // value
    xor %r13d, %r13d                // digits seen
    xor %r14d, %r14d                // previous byte was '_'
.Lei_loop:
    movzbl (%rbx), %eax
    cmp $'_', %eax
    jne .Lei_not_us
    test %r13d, %r13d
    jz .Lei_none                    // '_' before any digit
    test %r14d, %r14d
    jnz .Lei_none                   // '__'
    mov $1, %r14d
    inc %rbx
    jmp .Lei_loop
.Lei_not_us:
    cmp $'0', %eax
    jl .Lei_end
    cmp $'9', %eax
    jg .Lei_end
    sub $'0', %eax
    imul $10, %r12, %r12            // value *= 10
    add %rax, %r12                  // value += digit
    mov $0x7fffffff, %eax
    cmp %r12, %rax
    jge .Lei_digit_ok
    mov %rax, %r12                  // saturate: large is large
.Lei_digit_ok:
    mov $1, %r13d
    xor %r14d, %r14d
    inc %rbx
    jmp .Lei_loop
.Lei_end:
    test %r13d, %r13d
    jz .Lei_none                    // no digits
    test %r14d, %r14d
    jnz .Lei_none                   // trailing '_'
.Lei_trail:
    movzbl (%rbx), %edi
    test %edi, %edi
    jz .Lei_done
    call util_ei_is_space
    test %eax, %eax
    jz .Lei_none                    // junk after the number
    inc %rbx
    jmp .Lei_trail
.Lei_done:
    mov %r12, %rax
    jmp .Lei_ret
.Lei_none:
    xor %eax, %eax
.Lei_ret:
    EPILOGUE 4
    ret

// util_ei_is_space(edi=byte) -> eax = 1 for ASCII whitespace (space, \t\n\v\f\r)
    .p2align 4
util_ei_is_space:
    cmp $' ', %edi
    je .Leis_yes
    cmp $9, %edi
    jl .Leis_no
    cmp $13, %edi
    jle .Leis_yes
.Leis_no:
    xor %eax, %eax
    ret
.Leis_yes:
    mov $1, %eax
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