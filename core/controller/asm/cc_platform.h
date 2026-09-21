// ============================================================================
// cc_platform.h — the platform layer for the strimserver controller (asm)
// ============================================================================
//
//  Every cc_*.S module #includes this file first.  The assembly is written in
//  GNU as syntax for a Linux AArch64 (ELF) static build and is preprocessed
//  by the C compiler (`cc -c -x assembler-with-cpp`).  This is the Linux
//  AArch64 branch of the reference project's tc_platform.h, copied verbatim
//  and stripped to the Linux-only subset: no Apple/Mach-O code here, no
//  symbol-rename table, no per-platform #ifdef.  Everything below is
//  unconditional.
//
//  .arch — every module spells `.arch armv8.2-a` AFTER including this file
//  (exactly one in-source directive, nothing higher, no .arch_extension, no
//  .cpu — see AGENTS.md and check-isa.sh).  This header deliberately does
//  NOT set .arch, so a module that forgets the directive fails the ISA
//  checker's directive scan loudly instead of silently assembling at the
//  assembler's default level.
//
//  What the macros hide, and why
//  -----------------------------
//    PAGE(sym) / LO12(sym)   adrp+add/ldr page-relative addressing:
//                            `adrp x0, sym` / `add x0, x0, :lo12:sym`.
//                            PAGE is the absolute-address placeholder kept
//                            for parity with the reference macro set; the
//                            load-through form is
//                            `adrp xN, PAGE(sym)` / `ldr xM, [xN, LO12(sym)]`.
//    LEA reg, sym            the adrp+add pair above as one line (reg = &sym);
//    LEA_OFF reg, sym, off   the same plus `add reg, reg, #off`.  Modules use
//                            these for every symbol address.
//    RODATA                  `.section .rodata` — the read-only data section.
//    FUNC_TYPE(sym)          `.type sym, %function` on ELF.
//    LOAD_EXTERN_DATA_ADDR   address of an external (libc) DATA symbol such
//                            as optarg: direct adrp+add on a static ELF.
//    PROLOGUE n / EPILOGUE n the frame macros; see below.
//    MOV_DIV10_MAGIC reg     materialize DIV10_MAGIC with movz/movk (the
//                            value is not a valid mov immediate).
//    MOV_NANOSEC reg         materialize NANOSEC with movz/movk.
//
//  Rules for adding platform-dependent code (Linux AArch64 only)
//  ------------------------------------------------------------
//    * Numeric ABI facts (struct offsets, ioctl requests, clock ids) belong
//      here, never in a module, and every value must be derived from the
//      platform headers, not remembered.
//    * A behavioural difference (variadic call marshalling, a syscall) is a
//      fixed-arity wrapper in cc_util.S, never an #ifdef sprinkled through a
//      routine.
//    * Never use x18: it is the platform register, reserved on Linux.
//    * Never join statements with ';': it is a comment character in this
//      project's dialect.  One instruction per line.
//
#ifndef CC_PLATFORM_H
#define CC_PLATFORM_H

// ----------------------------------------------------------------------------
// Linux AArch64 (ELF)
// ----------------------------------------------------------------------------
#define PAGE(sym)       sym
#define LO12(sym)       :lo12:sym
#define RODATA          .section .rodata
#define FUNC_TYPE(sym)  .type sym, %function

    .macro LOAD_EXTERN_DATA_ADDR reg, sym
    adrp \reg, \sym
    add  \reg, \reg, :lo12:\sym
    .endm

    .macro LEA reg, sym                 // reg = &sym
    adrp \reg, \sym
    add  \reg, \reg, :lo12:\sym
    .endm
    .macro LEA_OFF reg, sym, off        // reg = &sym + off
    adrp \reg, \sym
    add  \reg, \reg, :lo12:\sym
    add  \reg, \reg, #\off
    .endm

// ============================================================================
// Function frames
// ============================================================================
//  PROLOGUE n   pushes the frame record {x29, x30}, points x29 at it (so a
//               debugger can walk the chain), then pushes n callee-saved
//               pairs in order: x19/x20, x21/x22, ... up to x27/x28 (n <= 5).
//  EPILOGUE n   pops the same n pairs in reverse, then the frame record.
//  Both keep sp 16-byte aligned; a function that needs stack locals still
//  does its own `sub sp, sp, #N` after PROLOGUE and `add sp, sp, #N` before
//  EPILOGUE.  EPILOGUE n must match PROLOGUE n.  Prefer these over
//  hand-rolled stp/ldp chains.
    .macro PROLOGUE n=0
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    .if \n >= 1
    stp x19, x20, [sp, #-16]!
    .endif
    .if \n >= 2
    stp x21, x22, [sp, #-16]!
    .endif
    .if \n >= 3
    stp x23, x24, [sp, #-16]!
    .endif
    .if \n >= 4
    stp x25, x26, [sp, #-16]!
    .endif
    .if \n >= 5
    stp x27, x28, [sp, #-16]!
    .endif
    .endm
    .macro EPILOGUE n=0
    .if \n >= 5
    ldp x27, x28, [sp], #16
    .endif
    .if \n >= 4
    ldp x25, x26, [sp], #16
    .endif
    .if \n >= 3
    ldp x23, x24, [sp], #16
    .endif
    .if \n >= 2
    ldp x21, x22, [sp], #16
    .endif
    .if \n >= 1
    ldp x19, x20, [sp], #16
    .endif
    ldp x29, x30, [sp], #16
    .endm

// ============================================================================
// libc struct layouts and OS constants
// ============================================================================
//  Every value below was derived by compiling a probe against the platform's
//  own headers (Linux musl/glibc aarch64), never from memory.  They are cpp
//  macros rather than .equ so that a stale module-local `.equ ST_MODE, 16`
//  becomes an assembler error instead of silently overriding the platform
//  value.
//
//  The descriptors and the clock ids the controller actually references:
//    STDOUT/STDERR are the descriptor numbers, not the stdio streams.
//    CLOCK_MONOTONIC (1) is what the controller's now()/inflight-timeout
//    logic reads via clock_gettime (timespec: tv_sec u64 @0, tv_nsec u64 @8).
#define EINTR           4
#define ENOENT          2
#define EEXIST          17
#define STDOUT          1
#define STDERR          2
#define SIGINT          2
#define SIGTERM         15
#define CLOCK_MONOTONIC 1

// ---- plain numeric constants every module needs ------------------------------
//  Not platform facts, but defined here for the same fail-loud reason: a
//  module-local `.equ SECS_PER_DAY, 86400` would silently shadow a shared
//  value, whereas with the cpp macro in scope it fails to assemble.
#define SECS_PER_DAY    86400
// Nanoseconds per second: 1e9.  The two-instruction load is the shared
// MOV_NANOSEC macro below (movz/movk of the low 32 bits; NANOSEC fits in
// 32 bits, so the high 32 are zero by construction).
#define NANOSEC         1000000000

// ---- shared numeric constants loaded by instruction, not by literal pool -----
//  These are constants the modules load into registers (some in hot loops),
//  defined once here so every module assembles the same value.  They are
//  cpp macros -- like SECS_PER_DAY above -- so a stale module-local `.equ`
//  of the same name fails to assemble instead of silently shadowing.
#define DIV10_MAGIC         0xCCCCCCCCCCCCCCCD   // divide-by-10 magic (umulh >> 3)
#define SWAR_MASK_01        0x0101010101010101   // SWAR has-zero-byte low-bit mask
#define SWAR_MASK_80        0x8080808080808080   // SWAR detection mask (01 mask << 7)

// MOV_DIV10_MAGIC reg — load DIV10_MAGIC without a literal pool entry
// (the value is not a valid mov immediate, so it is built with movz/movk).
    .macro MOV_DIV10_MAGIC reg
    movz \reg, #0xCCCD
    movk \reg, #0xCCCC, lsl #16
    movk \reg, #0xCCCC, lsl #32
    movk \reg, #0xCCCC, lsl #48
    .endm

// MOV_NANOSEC reg — load NANOSEC (1000000000) without a literal pool entry:
//   movz xN, #0xCA00 ; movk xN, #0x3B9A, lsl #16
    .macro MOV_NANOSEC reg
    movz \reg, #0xCA00, lsl #0
    movk \reg, #0x3B9A, lsl #16         // 1000000000
    .endm

// ============================================================================
// AAPCS64 — the rules every module must follow
// ============================================================================
//    * Arguments in x0-x7 (integer) / v0-v7 (float); return in x0 (x1 for
//      128-bit); composites are returned in x0..x3 or via x8 (sret).
//    * Callee-saved (must be preserved across any `bl` we make):
//      x19-x28, x29 (FP).  x30 (LR) is saved by the callee that calls.
//      x18 is the platform register — never touch it.
//    * sp must stay 16-byte aligned at every call site.
//    * Never join statements with ';' — it is a comment character in this
//      project's dialect.  One instruction per line.

#endif // CC_PLATFORM_H