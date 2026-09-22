// ============================================================================
// cc_platform_x86_64.h — the platform layer for the strimserver controller
// (x86-64 port)
// ============================================================================
//
//  Every x86_64 cc_*.S module #includes this file first.  The assembly is
//  written in GNU as AT&T syntax for a Linux x86-64 (ELF) static build and
//  is preprocessed by the C compiler (`cc -c -x assembler-with-cpp`).  This
//  is the SysV AMD64 translation of the AArch64 cc_platform.h: the same
//  contract, the same fail-loud CPP-macro discipline (never .equ for a
//  shared value), one instruction per line, and no ';' separators (they are
//  a comment character in this project's dialect; `//` is the comment
//  marker, exactly as in the AArch64 modules).
//
//  ISA floor x86-64-v4, AVX2 cap (no zmm/k/AMX, no AVX-512), target
//  g4dn.xlarge.  Unlike AArch64 there is no in-source `.arch` directive for
//  x86 GAS (that is an ARM concept), so the floor/cap are enforced by the
//  BUILD copts (-march=x86-64-v4 -mno-avx512f -mno-avx512vl -mno-avx512bw
//  -mno-avx512dq -mno-avx512cd) and by check-isa-x86_64.sh scanning the
//  disassembly.  Modules must never use zmm/k/AMX registers or AVX-512
//  instructions.
//
//  What the macros hide, and why
//  -----------------------------
//    LEA reg, sym            `lea sym(%rip), %reg` — the RIP-relative address
//                            of a symbol in this image (the x86 form of the
//                            AArch64 adrp+add pair).  One line, one reg.
//    LEA_OFF reg, sym, off   the same with a constant offset folded in.
//    LOAD_EXTERN_DATA_ADDR   address of an external (libc) DATA symbol such
//                            as optarg: the same RIP-relative LEA (static
//                            ELF, so every symbol lives in this image).
//    RODATA                  `.section .rodata` — the read-only data section.
//    FUNC_TYPE(sym)          `.type sym, @function` on ELF.
//    PROLOGUE n / EPILOGUE n the frame macros; see below.
//    MOV_DIV10_MAGIC reg     movabs of the divide-by-10 magic constant.
//    MOV_NANOSEC reg         movabs of NANOSEC (fits in 32 bits, but the
//                            movabs form keeps every MOV_* macro uniform).
//    MOV_DUR_MIN / MOV_DUR_HOUR  movabs of the two duration-unit values that
//                            exceed 32 bits (60e9 / 3.6e12).
//
//  Macro register arguments are BARE names, never `%`-prefixed
//  (e.g. `MOV_DIV10_MAGIC rbx`, `LEA rdi, util_err_prefix`); the macros
//  supply the AT&T `%`.  `n` in PROLOGUE/EPILOGUE is the number of
//  callee-saved registers to preserve beyond the frame pointer.
//
//  SysV AMD64 notes (the rules every module must follow)
//  ----------------------------------------------------
//    * Arguments in %rdi, %rsi, %rdx, %rcx, %r8, %r9 (integer/pointer);
//      floats in %xmm0-%xmm7; additional args on the stack.  Return in %rax
//      (%rdx:%rax for 128-bit); composites via a hidden sret pointer in
//      %rdi.
//    * Callee-saved (must be preserved across any `call` we make): %rbx,
//      %rbp, %r12-%r15.  %rsp must stay 16-byte aligned at every call site.
//    * Never join statements with ';' — it is a comment character in this
//      project's dialect.  One instruction per line.
//
#ifndef CC_PLATFORM_X86_64_H
#define CC_PLATFORM_X86_64_H

// ----------------------------------------------------------------------------
// Linux x86-64 (ELF)
// ----------------------------------------------------------------------------
#define RODATA          .section .rodata
#define FUNC_TYPE(sym)  .type sym, @function

    .macro LOAD_EXTERN_DATA_ADDR reg, sym
    lea \sym(%rip), %\reg
    .endm

    .macro LEA reg, sym                 // reg = &sym
    lea \sym(%rip), %\reg
    .endm
    .macro LEA_OFF reg, sym, off        // reg = &sym + off
    lea \sym+\off(%rip), %\reg
    .endm

// ============================================================================
// Function frames
// ============================================================================
//  PROLOGUE n   pushes the frame record {%rbp}, points %rbp at it (so a
//               debugger can walk the chain), then pushes n callee-saved
//               registers in the fixed order %rbx, %r12, %r13, %r14, %r15
//               (n <= 5).  An odd count gets an 8-byte padding slot so the
//               pushes always total a multiple of 16: %rsp is 16-byte
//               aligned at every call site no matter what n is.
//  EPILOGUE n   undoes the padding, pops the same n registers in reverse,
//               then the frame record.  EPILOGUE n must match PROLOGUE n.
//  PROLOGUE 0   is the alignment-only form: just the {%rbp} frame record
//               (8 bytes, which brings entry %rsp — 8 mod 16 after `call` —
//               back to 16 alignment).  A function that needs stack locals
//               still does its own `sub $N, %rsp` after PROLOGUE (N a
//               multiple of 16) and `add $N, %rsp` before EPILOGUE.
//               Prefer these over hand-rolled push/pop chains.
    .macro PROLOGUE n=0
    push %rbp
    mov  %rsp, %rbp
    .if \n >= 1
    push %rbx
    .endif
    .if \n >= 2
    push %r12
    .endif
    .if \n >= 3
    push %r13
    .endif
    .if \n >= 4
    push %r14
    .endif
    .if \n >= 5
    push %r15
    .endif
    .if \n % 2 == 1
    sub  $8, %rsp
    .endif
    .endm
    .macro EPILOGUE n=0
    .if \n % 2 == 1
    add  $8, %rsp
    .endif
    .if \n >= 5
    pop %r15
    .endif
    .if \n >= 4
    pop %r14
    .endif
    .if \n >= 3
    pop %r13
    .endif
    .if \n >= 2
    pop %r12
    .endif
    .if \n >= 1
    pop %rbx
    .endif
    pop %rbp
    .endm

// ============================================================================
// libc struct layouts and OS constants
// ============================================================================
//  The descriptors and the clock ids the controller actually references:
//    STDOUT/STDERR are the descriptor numbers, not the stdio streams.
//    CLOCK_MONOTONIC (1) is what the controller's now()/inflight-timeout
//    logic reads via clock_gettime (timespec: tv_sec u64 @0, tv_nsec u64 @8).
//  All values are Linux facts, identical on x86-64 and AArch64.
#define EINTR           4
#define ENOENT          2
#define EEXIST          17
#define STDOUT          1
#define STDERR          2
#define SIGINT          2
#define SIGTERM         15
#define CLOCK_MONOTONIC 1

// ---- plain numeric constants every module needs ------------------------------
//  Defined here for the same fail-loud reason as the AArch64 header: a
//  module-local `.equ SECS_PER_DAY, 86400` would silently shadow a shared
//  value, whereas with the CPP macro in scope it fails to assemble.
#define SECS_PER_DAY    86400
// Nanoseconds per second: 1e9.  Loaded by the MOV_NANOSEC macro.
#define NANOSEC         1000000000

// ---- shared numeric constants loaded by instruction, not by literal pool -----
#define DIV10_MAGIC         0xCCCCCCCCCCCCCCCD   // divide-by-10 magic (mulhi >> 3)
#define SWAR_MASK_01        0x0101010101010101   // SWAR has-zero-byte low-bit mask
#define SWAR_MASK_80        0x8080808080808080   // SWAR detection mask (01 mask << 7)

// MOV_DIV10_MAGIC reg — load DIV10_MAGIC without a literal pool entry.  The
// value is not a 32-bit sign-extended immediate, so it is loaded with movabs
// (the AT&T name for the REX.W 64-bit-immediate mov).
    .macro MOV_DIV10_MAGIC reg
    movabs $0xCCCCCCCCCCCCCCCD, %\reg
    .endm

// MOV_NANOSEC reg — load NANOSEC (1000000000).  Fits in 32 bits, but the
// movabs form keeps the macro identical to the other MOV_* macros.
    .macro MOV_NANOSEC reg
    movabs $1000000000, %\reg
    .endm

// MOV_DUR_MIN reg — load CC_DUR_MIN (60000000000 ns = 60 s).  Exceeds 32
// bits, so movabs.  (The AArch64 cc_env.h carried these two as movz/movk
// macros; on x86-64 they live here so the cc_env.S translation includes
// exactly one definition.)
    .macro MOV_DUR_MIN reg
    movabs $60000000000, %\reg
    .endm

// MOV_DUR_HOUR reg — load CC_DUR_HOUR (3600000000000 ns = 3600 s).
    .macro MOV_DUR_HOUR reg
    movabs $3600000000000, %\reg
    .endm

#endif // CC_PLATFORM_X86_64_H