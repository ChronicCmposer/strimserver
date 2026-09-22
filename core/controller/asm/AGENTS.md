# Assembly Authoring Playbook — `core/controller/asm/`

> **Read this file before writing, reviewing, or modifying any assembly in
> this directory.** It is the contract for every `cc_*.S` module, for the
> shared macro header, and for the two checker scripts that live beside it.
> It is self-contained: an agent dropped into this directory with no other
> context can follow it.

## Mandate (Gate 0.0)

This directory holds a hand-written **ARMv8.2-A** AArch64 assembly controller —
a port of the Go containerd/HTTP/websocket controller, in the style of the
reference project (`shirley-asm`), but **Linux-only** and **aarch64-only**.

- **Before ANY backend-logic work** — assembly, checker edits, BUILD wiring,
  plan updates — load the **`code-philosophy`** skill (Gate 0.0). Every law
  applies to assembly: guard clauses become branch-first control flow;
  parse-don't-validate means untrusted input is converted to trusted
  invariants at the function boundary; atomic predictability means a function
  never surprises its caller; fail-fast means an invalid state halts with a
  loud error return (never a silent continuation); intentional naming means
  `cc_` / module-prefix / `.L` names that read like English.
- **Never** write assembly that "probably works". A function that has not been
  proven (Gate 3) is not built (hard rule 9).

## Execution environment

- Linux-only, aarch64, **GNU-as syntax**, preprocessed by the **C compiler**
  (`gcc -x assembler-with-cpp`). CPP is the macro engine; the assembler is the
  final consumer.
- **ISA: `.arch armv8.2-a`** — exactly one in-source directive. No `-march`
  flag reaches the assembler. Nothing higher. No `.arch_extension`.
- Why: production targets **Graviton2 parity** (armv8.2-a). The dev host is a
  newer VM (see `plans/arm64-host-facts.md`) and its assembler **silently
  accepts** some armv8.3–8.5 instructions (`paciasp`, `bti`, `ssbb`, `pssbb`,
  `xpaclri`) and will happily assemble `.arch armv9-a` SVE2 code. "It
  assembled on my machine" must never mean "it runs on Graviton2" — that is
  precisely what `check-isa.sh` exists to prevent.

## Hard rules

> **Rule 0 — x30 is preserved across every call.** A `bl` (direct) AND a
> `blr` (indirect) both clobber x30 (the link register); the two are treated
> identically by the x30 rule. Any function that calls MUST save x30 before
> the call — `PROLOGUE n` always does (`stp x29,x30`), or an explicit
> `stp x30,...` (e.g. `stp x19,x30,[sp,#-16]!`) — and restore it before its
> own `ret`. Only `b sym` is a tail call; `bl` and `blr` are never one. A
> `ret` after a `bl`/`blr` without restoring x30 returns to the call's
> RETURN ADDRESS and loops back into the function — the #1 silent-wrongness
> source in this codebase (the `cc_json.S` runaway-writes bug).
> `check-clobbers.sh` now enforces this, and local (`module_*:`) functions
> are covered too.

1. **ISA**: `.arch armv8.2-a` exactly; no higher `.arch`, no
   `.arch_extension` (in particular never `sve`, `sve2`, `i8mm`, `bf16`).
2. **Callee-saved registers**: preserve **x19–x28 and x29** across every
   `bl` (AAPCS64; x30 is Rule 0). A function may use them but must restore
   them before `ret`.
3. **Stack alignment**: `sp` is 16-byte aligned at every call site.
4. **Never use x18** (platform register).
5. **Never join statements with `;`** — it is a comment character in this
   project's dialect. One instruction per line.
6. **Constants are CPP macros**, not `.equ` — module-local `.equ` collisions
   fail to assemble. Every constant lives in the shared macro header or a
   module header.
7. **`PROLOGUE n` / `EPILOGUE n`** — assembler macros (`.if \n >= k` chains)
   that keep `sp` aligned and preserve callee-saved registers in pairs
   x19/x20, x21/x22, …, x27/x28 (`n <= 5`). `EPILOGUE n` must match
   `PROLOGUE n`. Prefer them over hand-rolled `stp`/`ldp` pairs.
8. **Fixed-arity wrappers for variadic libc calls** — AAPCS64 variadic rules
   (register save area / `x8` indirect forms as required). Never `bl` a
   variadic C function directly from assembly; call a fixed-arity wrapper.
9. **Never build on an unverified function** — a function that has not passed
   Gate 3 is not wired into a build target.

## Function shape (every exported function)

```
    .p2align 2
    .global cc_name
    FUNC_TYPE(cc_name)            # CPP macro -> .type cc_name,%function
cc_name:
    ... body ...
    ret
```

The file ends with `.end`.

Local helpers (`module_*:`) follow the SAME shape — `PROLOGUE n` (or an
explicit save that includes x30) before their `bl`s, `EPILOGUE n` before
`ret` — and carry the SAME AAPCS64 obligations as exported functions.

## Naming rules

- Exported symbols: **`cc_`** prefix (e.g. `cc_json_parse`, `cc_http_read`).
- Module-local symbols: **module prefix** — `env_`, `json_`, `state_`,
  `util_`, `ctr_`, `http_`, `main_` (matching the module's purpose).
- Branch targets and local labels: **`.L`** prefix (e.g. `.Lret`, `.Lloop`).
- Never use `cc_` for a non-exported label and never branch to a bare
  non-`.L` label.
- **Local helpers are FULL AAPCS64 functions.** A `module_*:` function has
  the SAME obligations as an exported one: preserve x19–x28 AND x30 across
  its own `bl`s (save x30 before every call, restore before `ret`), keep sp
  16-byte aligned at its call sites, and restore its callee-saved saves
  before returning. `check-clobbers.sh` now analyzes local helpers as their
  own functions — a helper that clobbers x19 or x30 is a RED finding, never
  attributed to the enclosing `cc_*` function.

## Linux AArch64 macro set (shared header)

| Macro | Expansion / purpose |
|---|---|
| `PAGE(sym)` | `sym` (absolute-address placeholder, kept for parity) |
| `LO12(sym)` | `:lo12:sym` |
| `RODATA` | `.section .rodata` |
| `FUNC_TYPE(sym)` | `.type sym,%function` |
| `LEA reg,sym` | `adrp reg,sym` + `add reg,reg,:lo12:sym` |
| `LEA_OFF reg,sym,off` | `LEA` plus an offset |
| `LOAD_EXTERN_DATA_ADDR` | load the address of an external data symbol |
| `MOV_DIV10_MAGIC` | materialize the divide-by-10 magic constant |
| `MOV_NANOSEC` | materialize the nanoseconds constant |

## The 5 gates

Work proceeds one gate at a time. A gate is complete only when its exit
criteria are met.

- **Gate 0 — Scope / contract & test-first.** One function per task. Write
  the contract (inputs, outputs, invariants, failure modes) and the
  differential Go harness *before* the assembly. The harness is the oracle:
  build it FIRST (test-first), because retrofitting it after the assembly is
  what made debugging slow (see "Debugging-time discipline"). Load
  `code-philosophy` (Gate 0.0).
- **Gate 1 — Module skeleton.** Create `cc_<module>.S`, the module header,
  the shared macro header (PROLOGUE/EPILOGUE + the Linux AArch64 macro set),
  the BUILD wiring, and the checker invocation. The skeleton must pass both
  checkers green.
- **Gate 2 — Implement ONE function, ≤ 80 instructions.** One function per
  commit-sized step. If a function exceeds 80 instructions, split it.
- **Gate 3 — Prove the function.** (a) the differential harness built at
  Gate 0 runs the function and passes; (b) a differential test compares its
  output byte-for-byte against the Go reference; (c) the disassembly is
  reviewed; (d) `check-clobbers.sh` is GREEN on the raw AND the preprocessed
  form; (e) `check-isa.sh` is GREEN. A function is "unverified" until Gate 3
  passes. Build the differential harness at Gate 0, BEFORE the assembly —
  retrofitting it afterwards is what made debugging slow.
- **Gate 4 — Module complete.** Every function in the module is proven; the
  module passes both checkers green.
- **Gate 5 — Integration.** The module is wired into the controller build,
  linked, and smoke-tested end to end.

## Checkers

Both scripts live in this directory. They are **guards, not proofs** — human
review always applies. Run them after every edit to a `cc_*.S` module.

### `check-isa.sh` — ISA compliance (Graviton2 parity)

```sh
./check-isa.sh core/controller/asm/cc_*.S        # files or a directory
./check-isa.sh -I core/controller/asm cc_http.S  # add include dirs
```

What it does: (1) rejects any `.arch` above `armv8.2-a` and any
`.arch_extension` (and any `.cpu`); (2) assembles the module under armv8.2-a
and disassembles the object; (3) scans the disassembly for instructions or
registers that require a higher ISA (pointer-auth, `bti`, `ssbb`/`pssbb`,
SVE/SVE2 `z`/`p` registers, bf16/i8mm/dotprod, memtag).

**Green** = directive scan clean, object assembles, disassembly scan clean.
**Red** (non-zero exit, `file:line` printed) = a `.arch`/`.arch_extension`
violation, a >armv8.2-a instruction present in the object, OR an instruction
the assembler *rejects* under armv8.2-a (e.g. `bfdot`). Rejections are
fail-loud (RED, exit non-zero): the module does not build and "a warning is
not green" — an exit-code-gated CI loop keyed on `$?` must not pass.

Optional self-check: `--strict-blacklist-update` probes every mnemonic in
the curated blacklist under a high arch (default `armv9-a`) and fails if one
does not assemble — a dead blacklist entry is a typo. Conservative: skipped
when the host assembler does not know the high arch, and the probe-fragile
mnemonics (st2g/stz2g/cosp) are skipped, not failed.

### `check-clobbers.sh` — clobber discipline (AAPCS64 callee-saved)

```sh
./check-clobbers.sh core/controller/asm/cc_*.S
./check-clobbers.sh -I core/controller/asm cc_http.S
```

What it does: for EVERY function — exported `cc_*:` and local helper
`module_*:` alike (any non-`.L` label starts a function) — it checks
(a) every write to x19–x28 is covered by `PROLOGUE n`/`EPILOGUE n` or a
balanced `stp`/`ldp` pair, and each write lies inside its save/restore
window; (b) `stp`/`ldp` of callee-saved registers are balanced; (c) writes
to x29 have a matching `stp x29,x30` frame record; (d) **x30**: any function
that calls (`bl` or `blr` — direct and indirect calls both clobber x30) must
save x30 before the call and restore it before its own `ret` (a `bl`/`blr`
after the restore followed by a `ret` is the wrong-link bug); bonus: any use
of x18 is flagged.

It analyzes the RAW source AND the macro-preprocessed text by default, so a
register hidden inside a CPP macro is still caught (preprocessed findings
are labeled `(preprocessed)`; their line numbers refer to the expanded
stream). Data/rodata labels form empty functions (no findings). A function
that never `ret`s (a noreturn fail-loud helper) is not required to restore
its saves.

**Green** = no findings. **Red** (non-zero exit, `file:line` printed) = one
or more findings. Review macro bodies by hand either way. See the comment
header in the script for a full precision statement.

## Debugging-time discipline (why it is slow, and how to make it fast)

The debugging hours on `cc_json.S` came from three structural gaps (now
fixed in this playbook and the tooling): local helpers were not analyzed as
functions, x30 was not checked, and the ISA checker exited 0 on a warning.
The second-order cause was discipline: gdb was reached before the checkers
and before the differential harness. Failure-mode map — symptom → cause →
prevention:

- **"Garbage x0 / runaway writes past a buffer"** → clobbered x30 (`ret`
  used the bl's link and looped back into the function) OR a clobbered
  pointer held in a caller-saved register across a call. Prevention: run
  `check-clobbers.sh` (now catches x30 and local functions) BEFORE touching
  gdb; build the differential harness first (Gate 0), never after.
- **Byte-exact JSON/format/escape mismatch** → never guess Go's
  encoding/json behavior. Read the exact call site (Encoder vs Marshal,
  escapeHTML default ON, trailing `\n`, key order, invalid-UTF-8 `\ufffd`,
  U+2028/U+2029) and byte-diff against the real Go binary. The differential
  harness is the oracle.
- **Off-by-one string-length / NUL-included constant errors** → derive
  lengths from the macro / label difference, don't hand-type; the
  differential catches it.
- **Silent >armv8.2-a instruction** → run `check-isa.sh` (Graviton2
  parity); never trust "it assembled on my machine".
- **Macro-hidden register write invisible to the raw scan** → the checker
  now scans the preprocessed text too; still review macro bodies by hand.
- **C-layer note: wire-protocol heisenbugs (HPACK/gRPC)** → per-direction
  HPACK state, non-blocking sockets, length-delimited strings, incremental
  validation against a real containerd, run valgrind/sanitizers. The C
  client shares the differential-first discipline.

**Never debug a clobber by reading gdb first.** The clobber/x30 checker is
faster and deterministic: run both checkers and the differential harness
BEFORE gdb. gdb only after those are green and a real logic bug remains.

## What "green" means

- `check-isa.sh`: every module printed `GREEN` and the script exited 0.
- `check-clobbers.sh`: every module printed `GREEN` and the script exited 0.
- A module is "green" only when **both** scripts exit 0 on it. Anything else
  — any red finding — means the module must be fixed.

## Module layout (created in Gate 1, one per module)

- `cc_<module>.S` — the assembly module (what the checkers inspect).
- `cc_<module>.h` — C-side declarations and constants (CPP macros).
- Shared header (`asm_common.h`/`.inc`) — PROLOGUE/EPILOGUE macros and the
  Linux AArch64 macro set (first created in Gate 1).
- BUILD target — compiles the module through the C compiler preprocessor
  (`-x assembler-with-cpp` style) and runs both checkers in CI.

## Human code-review checklist (the real gate)

- [ ] `code-philosophy` loaded and applied (Gate 0.0)
- [ ] `.arch armv8.2-a` exactly once; no `.arch_extension`, no `.cpu`
- [ ] x19–x28, x29, and x30 preserved across every `bl`; restored before `ret`
- [ ] `sp` 16-byte aligned at every call site
- [ ] no x18, no `;`, no `.equ`
- [ ] constants are CPP macros; `PROLOGUE n`/`EPILOGUE n` matched
- [ ] naming: `cc_` / module prefix / `.L` labels
- [ ] ≤ 80 instructions per function
- [ ] `check-isa.sh` green; `check-clobbers.sh` green on raw AND preprocessed
- [ ] differential harness (built at Gate 0) passing; disasm proof exists (Gate 3)
---

# x86_64 translation — `core/controller/asm/x86_64/`

> This section governs the **x86-64 port** of the controller: the AArch64
> modules above are being **translated** (not re-imagined) to GNU-as AT&T
> syntax, System V AMD64 ABI, Linux-only. Byte-exact parity with the Go
> oracle is the contract, exactly as on AArch64. **Read the AArch64 section
> first** — every AArch64 law (Rule 0, naming, gates, green-means-verified)
> carries over with the register/ABI substitutions in the table below.

## Mandate (Gate 0.0)

- **Before ANY x86-64 backend-logic work** — assembly, checker edits, BUILD
  wiring, plan updates — load the **`code-philosophy`** skill (Gate 0.0).
  The five laws map 1:1 onto x86-64 assembly: guard clauses become
  branch-first control flow; parse-don't-validate means untrusted input is
  converted to trusted invariants at the function boundary; atomic
  predictability means a function never surprises its caller; fail-fast
  means an invalid state halts with a loud error return; intentional naming
  means `cc_` / module-prefix / `.L` names that read like English.
- The port is **translation, not rewrite**: a translated function must keep
  the same inputs, outputs, invariants, failure modes, and clobber contract
  as its AArch64 original, and must pass the same differential harness.
- **Never** write assembly that "probably works". A function that has not
  been proven (Gate 3) is not built.

## Execution environment

- Linux-only, **x86-64** (SysV AMD64, little-endian), **GNU-as AT&T syntax**,
  preprocessed by the **C compiler** (`cc -c -x assembler-with-cpp`). CPP is
  the macro engine; the assembler is the final consumer.
- **ISA floor: `-march=x86-64-v4` on the build command. Cap: AVX2.** No
  zmm/k registers, no AVX-512 mnemonics, no AMX — ever. Target hardware:
  g4dn.xlarge (Cascade Lake).
- **No in-source `.arch`/`.cpu`/`.arch_extension`** — they do not exist on
  x86 GNU as (they are ARM concepts: `.arch x86-64-v4` fails to assemble).
  The floor is the build's `-march=x86-64-v4`; `check-isa-x86_64.sh`
  REJECTS any such directive and, because the x86 assembler accepts
  **everything** by default (zmm/k/AMX all assemble silently), the
  **disassembly scan is the authoritative cap gate** — never trust "it
  assembled on my machine".

## SysV-vs-AAPCS64 translation table

| AArch64 (AAPCS64) | x86-64 (SysV) | Notes |
|---|---|---|
| `x0`–`x7` (args) | `%rdi,%rsi,%rdx,%rcx,%r8,%r9` + stack | Integer/pointer args |
| floats | `%xmm0`–`%xmm7` | SysV SIMD arg regs |
| `x0` return | `%rax` (`%rdx:%rax` for 128-bit) | Return register |
| `x30` (link) | **`%rsp`** | **`call` pushes the return address; `ret` pops it.** `%rsp` is the return-address link — see hard rule 0 |
| `x19`–`x28` callee-saved | `%rbx, %rbp, %r12`–`%r15` | Integer callee-saved |
| `d8`–`d15` callee-saved | `%xmm8`–`%xmm15` | SIMD callee-saved |
| `sp` 16-aligned at calls | `%rsp` 16-aligned at calls | Entry: `%rsp%16 == 8` (after `call`) |
| `bl`/`blr` call | `call` | Direct and indirect |
| `b` tail call | `jmp` | Only tail call |
| `ret` return | `ret` | Returns to the `call`-pushed address |
| `adrp`+`add` (LEA) | `lea sym(%rip), %reg` | RIP-relative addressing |
| `.arch armv8.2-a` | (none — build `-march=x86-64-v4`) | x86 has no in-source arch directive |
| `stp x29,x30` frame record | `push %rbp; mov %rsp, %rbp` | PROLOGUE 0 |

## Hard rules

> **Rule 0 — RSP is the return-address link.** `call` pushes the return
> address onto `%rsp`; `ret` pops it. The wrong-link bug in x86 terms is a
> `ret` after an unbalanced push/sub — it pops the WRONG address and loops
> back into the function. `check-clobbers-x86_64.sh` enforces this: net rsp
> displacement must be **zero** at every `ret`, and every `call` must see
> `%rsp` 16-aligned. Any function that calls MUST balance its pushes/subs
> before its own `ret` — `PROLOGUE n` always does. Only `jmp` is a tail
> call; `call` is never one.

1. **ISA**: floor `-march=x86-64-v4`; **AVX2 cap** — no `zmm`/`k`/`tmm`, no
   AVX-512 mnemonics (vpermb, vpermi2*, vpternlog*, vmovdqa32/64, kmov*,
   kand*, kshift*, vpmovm2*, vpmov*2m, vpcompress*, vpexpand*, EVEX scalar
   forms), no AMX (tdp*, tile*, ldtilecfg). No in-source `.arch`/`.cpu`/
   `.arch_extension`.
2. **Callee-saved registers**: preserve **`%rbx, %rbp, %r12`–`%r15` and
   `%xmm8`–`%xmm15`** across every `call` (SysV). A function may use them
   but must restore them before `ret`. (`%rsp` is Rule 0.)
3. **Stack alignment**: `%rsp` is 16-byte aligned at every call site.
   SysV entry `%rsp%16 == 8`; `PROLOGUE n` restores 16-alignment.
4. **Never use `%rbx`/`%rbp`/`%r12`–`%r15` as scratch across a call.**
   (x86 has no platform register like x18; the callee-saved set is the
   discipline.)
5. **Never join statements with `;`** — on x86 `;` is a STATEMENT SEPARATOR,
   not a comment. An accidental `;` silently assembles a second instruction.
   Comments are `#` (GNU as) and `//` (this project's dialect; CPP strips it).
   One instruction per line.
6. **Constants are CPP macros**, not `.equ` — module-local `.equ`
   collisions fail to assemble. Every constant lives in
   `cc_platform_x86_64.h` or a module header.
7. **`PROLOGUE n` / `EPILOGUE n`** — the x86 frame macros (push `%rbp`;
   `mov %rsp,%rbp`; push `%rbx,%r12,%r13,%r14,%r15` per `n`, `n <= 5`;
   odd `n` gets an 8-byte padding slot so pushes total a multiple of 16).
   `EPILOGUE n` must match `PROLOGUE n`. Prefer them over hand-rolled
   push/pop chains.
8. **Fixed-arity wrappers for variadic libc calls** — SysV variadic rules:
   `%al` holds the number of vector arguments. Never `call` a variadic C
   function directly from assembly; call a fixed-arity wrapper.
9. **Never build on an unverified function** — a function that has not
   passed Gate 3 is not wired into a build target.
10. **Leaf-only red zone** — a `-N(%rsp)` (negative offset) access is only
    legal inside a function with no `call` (a callee's pushes clobber the
    red zone). Non-leaf functions must allocate via `sub $N, %rsp`.

## Function shape (every exported function)

```
    .p2align 4
    .global cc_name
    FUNC_TYPE(cc_name)            # CPP macro -> .type cc_name,@function
cc_name:
    ... body ...
    ret
```

The file ends with `.end`.

Local helpers (`module_*:`) follow the SAME shape — `PROLOGUE n` before
their `call`s, `EPILOGUE n` before `ret` — and carry the SAME SysV
obligations as exported functions.

## Naming rules

- Exported symbols: **`cc_`** prefix (e.g. `cc_json_parse`, `cc_http_read`).
- Module-local symbols: **module prefix** — `util_`, `env_`, `json_`,
  `ctr_`, `state_`, `http_`, `main_`.
- Branch targets and local labels: **`.L`** prefix (e.g. `.Lret`, `.Lloop`).
- Never use `cc_` for a non-exported label and never branch to a bare
  non-`.L` label.
- **Local helpers are FULL SysV functions.** A `module_*:` function has the
  SAME obligations as an exported one: preserve `%rbx/%rbp/%r12-%r15` +
  `%xmm8-%xmm15` across its own `call`s, keep `%rsp` 16-aligned, and
  balance every push/sub before `ret`. `check-clobbers-x86_64.sh` analyzes
  local helpers as their own functions.

## Linux x86-64 macro set (shared header `x86_64/cc_platform_x86_64.h`)

| Macro | Expansion / purpose |
|---|---|
| `LEA reg,sym` | `lea sym(%rip), %reg` (RIP-relative; the x86 adrp+add) |
| `LEA_OFF reg,sym,off` | `lea sym+off(%rip), %reg` |
| `RODATA` | `.section .rodata` |
| `FUNC_TYPE(sym)` | `.type sym,@function` |
| `LOAD_EXTERN_DATA_ADDR` | load the address of an external data symbol |
| `PROLOGUE n` / `EPILOGUE n` | the x86 frame macros (rule 7) |
| `MOV_DIV10_MAGIC` | `movabs` of the divide-by-10 magic constant |
| `MOV_NANOSEC` | `movabs` of NANOSEC |
| `MOV_DUR_MIN` / `MOV_DUR_HOUR` | `movabs` of 60e9 / 3.6e12 |

## The 5 gates (x86 exit criteria)

Work proceeds one gate at a time. A gate is complete only when its exit
criteria are met.

- **Gate 0 — Scope / contract & test-first.** One function per task. Write
  the contract (inputs, outputs, invariants, failure modes) and the
  differential Go harness *before* the assembly. The harness is the oracle:
  build it FIRST (test-first). Load `code-philosophy` (Gate 0.0).
- **Gate 1 — Module skeleton.** Create `x86_64/cc_<module>.S`, the module
  header, the shared `cc_platform_x86_64.h`, the BUILD wiring, and the
  checker invocation. The skeleton must pass both checkers green.
- **Gate 2 — Implement ONE function, ≤ 80 instructions.** One function per
  commit-sized step. If a function exceeds 80 instructions, split it.
- **Gate 3 — Prove the function.** (a) the differential harness built at
  Gate 0 runs the function and passes; (b) a differential test compares its
  output byte-for-byte against the Go reference; (c) the disassembly is
  reviewed; (d) `check-clobbers-x86_64.sh` is GREEN on the raw AND the
  preprocessed form; (e) `check-isa-x86_64.sh` is GREEN. A function is
  "unverified" until Gate 3 passes.
- **Gate 4 — Module complete.** Every function in the module is proven; the
  module passes both checkers green.
- **Gate 5 — Integration.** The module is wired into the controller build,
  linked, and smoke-tested end to end.

## Module inventory (all to live in `core/controller/asm/x86_64/`)

The seven modules mirror the AArch64 tree. `cc_util.S` exists today; the
rest land one Gate-2 step at a time.

| Module | Purpose (same as AArch64 original) |
|---|---|
| `x86_64/cc_util.S` | shared utilities (strlen, puts, div10, ...) |
| `x86_64/cc_env.S` | environment/configuration |
| `x86_64/cc_json.S` | JSON parsing/formatting (byte-exact Go parity) |
| `x86_64/cc_ctr.S` | controller core |
| `x86_64/cc_state.S` | state machine |
| `x86_64/cc_http.S` | HTTP/websocket framing |
| `x86_64/cc_main.S` | main() and lifecycle |

## Checkers

Both x86 checkers live beside this file. They are **guards, not proofs** —
human review always applies. Run them after every edit to a `cc_*.S`
module.

### `check-isa-x86_64.sh` — ISA floor + AVX2 cap

```sh
./check-isa-x86_64.sh x86_64/cc_*.S                    # files or a directory
./check-isa-x86_64.sh -I core/controller/asm/x86_64 cc_util.S
./check-isa-x86_64.sh --strict-blacklist-update x86_64 # self-check
```

What it does: (1) REJECTS any in-source `.arch`/`.cpu`/`.arch_extension`
(RED, file:line — the floor is the build's `-march`, never in-source);
(2) assembles the module via `cc -c -x assembler-with-cpp -march=x86-64-v4`
(the floor proof; any assembly failure is RED, fail-loud); (3) `objdump -d`
the object and scans for zmm/k/tmm registers, AVX-512-only mnemonics
(curated blacklist), `{evex}` scalar forms, and AMX — mapping each hit back
to file:line via `addr2line`.

**Green** = directive scan clean, object assembles at the floor,
disassembly scan clean. **Red** (non-zero exit, `file:line` printed) = any
of the above. Because x86 gas does not gate, the disassembly scan is the
authoritative cap gate. Optional self-check: `--strict-blacklist-update`
probes every blacklisted mnemonic under a high gas `-march` (default the
AVX-512+AMX bundle) and fails if one does not assemble — a dead blacklist
entry is a typo.

### `check-clobbers-x86_64.sh` — SysV callee-saved discipline

```sh
./check-clobbers-x86_64.sh x86_64/cc_*.S
./check-clobbers-x86_64.sh -I core/controller/asm/x86_64 cc_util.S
```

What it does: for EVERY function — exported `cc_*:` and local helper
`module_*:` alike — it checks (a) every write to RBX/RBP/R12–R15 is
covered by `PROLOGUE n`/`EPILOGUE n` or a balanced push/pop pair, inside its
save/restore window; (b) push/pop and sub/add are balanced, so the net rsp
displacement at every `ret` is **0** (the wrong-return-address bug); (c) rsp
is 16-byte aligned at every `call`; (d) **leaf-only red zone** — a `-N(%rsp)`
access inside any function that contains a `call` is RED; (e) xmm8–xmm15
writes are covered by save/restore windows. It analyzes the RAW source AND
the macro-preprocessed text by default.

**Green** = no findings. **Red** (non-zero exit, `file:line` printed) = one
or more findings.

## Differential harness

```sh
# built at Gate 0, per function; the Go binary is the oracle
./core/controller/asm/differential.sh <function> <x86_64/cc_<module>.S> ...
```

A function is unverified until the harness passes byte-for-byte against the
Go reference AND both checkers are green.

## Debugging-time discipline (x86)

The AArch64 failure-mode map carries over with x86 spellings:

- **"Garbage rax / runaway writes past a buffer"** → unbalanced push/sub
  (`ret` popped the wrong address and looped back into the function) OR a
  clobbered pointer held in a caller-saved register across a call.
  Prevention: run `check-clobbers-x86_64.sh` BEFORE touching gdb; build the
  differential harness first (Gate 0), never after.
- **Byte-exact JSON/format/escape mismatch** → never guess Go's
  encoding/json behavior; byte-diff against the real Go binary. The
  differential harness is the oracle.
- **Off-by-one string-length / NUL-included constant errors** → derive
  lengths from the macro / label difference, don't hand-type.
- **Silent AVX-512/AMX instruction** → x86 gas accepts everything by
  default; run `check-isa-x86_64.sh` (never trust "it assembled on my
  machine").
- **Macro-hidden register write invisible to the raw scan** → run the
  checker's preprocessed pass too; still review macro bodies by hand.
- **Variadic libc call clobbering `%al`** → SysV uses `%al` as the vector
  count; always call a fixed-arity wrapper (rule 8).

**Never debug a clobber by reading gdb first.** The clobber/rsp checker is
faster and deterministic: run both checkers and the differential harness
BEFORE gdb. gdb only after those are green and a real logic bug remains.

## What "green" means (x86)

- `check-isa-x86_64.sh`: every module printed `GREEN` and exited 0.
- `check-clobbers-x86_64.sh`: every module printed `GREEN` and exited 0.
- A module is "green" only when **both** scripts exit 0 on it. Anything
  else — any red finding — means the module must be fixed.

## Human review checklist (x86) — the real gate

- [ ] `code-philosophy` loaded (Gate 0.0)
- [ ] no in-source `.arch`/`.cpu`; assembles at `-march=x86-64-v4`
- [ ] no `zmm`/`k`/AVX-512/AMX (AVX2 cap)
- [ ] RBX/RBP/R12–R15 + xmm8–xmm15 preserved across every `call`
- [ ] RSP 16-aligned at every `call`; net RSP displacement zero at `ret`
- [ ] no `;` (statement separator), no `.equ`
- [ ] constants CPP macros; PROLOGUE/EPILOGUE matched
- [ ] naming: `cc_` / module prefix / `.L`
- [ ] ≤ 80 insns per function (preprocessed stream)
- [ ] check-isa + check-clobbers green (raw AND preprocessed)
- [ ] differential harness passing; disasm proof (Gate 3)
- [ ] no `endbr64`/CET unless explicitly targeted
