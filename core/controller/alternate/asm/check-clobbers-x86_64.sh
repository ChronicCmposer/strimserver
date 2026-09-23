#!/usr/bin/env bash
#
# check-clobbers-x86_64.sh -- clobber-discipline checker for the x86-64 asm
# controller modules (System V AMD64 ABI, GNU-as AT&T syntax).
#
# PURPOSE
#   Flags SysV AMD64 callee-saved-register violations in hand-written x86-64
#   assembly (Linux-only, GNU-as AT&T, preprocessed by the C compiler):
#     (a) every write to RBX/RBP/R12-R15 that is not covered by a save/restore
#         window (PROLOGUE/EPILOGUE or a balanced push/pop pair) in the same
#         function, including writes that fall OUTSIDE the window (a write
#         before its save or after its restore would clobber the caller's
#         register across any intervening `call`);
#     (b) push/pop balance AND sub rsp/add rsp balance per function -- the net
#         rsp displacement at every `ret` must be 0.  This is the
#         wrong-return-address analog of the AArch64 x30 rule: an unmatched
#         push or a sub-without-add makes `ret` pop the wrong address;
#     (c) rsp is 16-byte aligned at every `call`.  SysV: rsp%16 == 8 at
#         function entry (the caller's call pushed the return address), so a
#         call instruction must see rsp%16 == 0.  One 8-byte push realigns
#         rsp to 0; two puts it back at %16 == 8 (RED); three realigns again.
#         The checker tracks the exact net displacement, so sub/add frames
#         and `and $-16, %rsp` fixups are judged too, not just push parity.
#     (d) leaf-only red zone: a -N(%rsp) (negative offset) access inside any
#         function that contains a `call`.  A callee's pushes clobber the red
#         zone, so only leaf functions may use it.  Offset 0 and positive
#         offsets are normal stack accesses, not red-zone accesses.
#     (e) xmm8-xmm15 write discipline: the SysV callee-saved SIMD registers
#         must be saved (stored from %xmmN to memory) before the first write
#         to %xmmN and restored (loaded from memory into %xmmN) before return,
#         with every write inside the save/restore window.  ymm8-15 writes
#         write xmm8-15's low bits and are tracked as xmm8-15.  xmm0-xmm7 are
#         caller-saved (like the AArch64 checker's v0-v7) and never flagged:
#         a callee that writes them may clobber them freely across its calls.
#
# FUNCTIONS
#   A function starts at ANY label that is not a `.L`-prefixed branch target
#   and not a directive/section marker.  Exported functions are `cc_*:`;
#   local helper functions are `module_*:` (json_*, util_*, env_*, ...).  Both
#   are FULL SysV functions with the SAME obligations and are analyzed the
#   same way.  Data/rodata labels (e.g. `util_err_prefix:`) form empty
#   functions (no instructions -> no findings); that is acceptable.
#
# AT&T WRITE DETECTION
#   In AT&T syntax the LAST operand is the destination: `mov %rax, %rbx`
#   writes rbx; `mov %reg, (mem)` writes memory; `lea` writes its last
#   operand; `cmp`/`test`/`call`/`ret`/`push`/`pop`/`jmp`/`jcc` are
#   special-cased (cmp/test/jmp/jcc read only; push writes memory and rsp;
#   pop writes its register operand and rsp; call/ret drive the alignment and
#   rsp-balance checks).  Size-qualified names -- %ebx, %bx, %bl, %bh, %r12d,
#   %r12w, %r12b, %r8b -- all write the same 64-bit register (a 32-bit write
#   zero-extends into the full register, so %ebx IS a write to rbx).
#   Implicit writes: `cpuid` clobbers rax/rbx/rcx/rdx (rbx is callee-saved,
#   so a cpuid without a save is caught); `xchg` writes both operands;
#   `leave` restores (writes) rbp.  mul/div write rax/rdx only (caller-saved)
#   and the string/repeat operations write only caller-saved registers, so
#   they need no callee-saved tracking.
#
# COMMENT / SEPARATOR HANDLING
#   `#` is the GNU-as x86 line comment and is stripped (outside string
#   literals).  `//` is this project's dialect comment (CPP strips it before
#   the assembler sees the file) and is stripped too.  `;` is a STATEMENT
#   SEPARATOR, not a comment: an accidental `;` silently assembles a second
#   instruction, so BOTH statements are analyzed (nothing is flagged about
#   the `;` itself, but a callee-saved write hidden in the second statement
#   is caught).
#
# PRECISION -- READ THIS (guard, not proof)
#   This is a pragmatic heuristic, NOT a register-liveness proof. Human review
#   still applies (AGENTS.md is the authority). Known limitations:
#     * The checker runs BOTH the raw source AND the macro-preprocessed text
#       (cc -E -P -x assembler-with-cpp) BY DEFAULT, so a register hidden
#       inside a CPP macro is still caught by the preprocessed pass. Findings
#       on the preprocessed stream are labeled "(preprocessed)" and their
#       line numbers refer to the EXPANDED stream, not the raw file. Review
#       macro bodies by hand either way. If preprocessing needs an include
#       dir, pass -I (the modules include their platform header; the gate
#       passes -I core/controller/alternate/asm).
#     * PROLOGUE n / EPILOGUE n are GNU-as .macro invocations; their bodies
#       are NOT visible in either stream (the .macro definition lives in the
#       platform header).  The PREPROCESSED pass parses the .macro body from
#       the stream and derives the exact saved registers, rsp displacement,
#       and frame-pointer behavior per n.  The RAW pass cannot see the
#       definition and falls back to a canonical model that MATCHES the
#       x86_64 macro in cc_platform_x86_64.h: PROLOGUE n pushes the frame
#       record {%rbp}, then n callee-saved registers in the fixed order
#       (rbx, r12, r13, r14, r15), padding with `sub $8, %rsp` when n is odd
#       so the pushes total a multiple of 16 (rsp displacement
#       -8*(1+n+(n%2)); frame base -8).  If the macro is ever changed, the
#       raw pass may disagree with the preprocessed pass; the preprocessed
#       pass is authoritative for macro effects.  The .macro bodies are the
#       contract -- review them by hand.
#     * rsp balance and alignment assume the call-entry invariant
#       rsp%16 == 8 at every function entry (SysV; `main` reached via crt0
#       qualifies).  A function entered only through a tail-call `jmp` would
#       be judged against the wrong invariant.  `mov %rbp, %rsp` /
#       `lea N(%rbp), %rsp` are tracked through a recorded rbp frame base;
#       a function that writes rsp from any other untracked source is RED
#       ("cannot verify rsp balance/alignment").
#     * `sub $N, %rsp` with a symbolic (macro) immediate leaves rsp
#       untracked for the remainder of the function and prints a note -- the
#       preprocessed pass adjudicates with the literal value.
#     * A function that never contains a `ret` is treated as noreturn: its
#       saves are not required to be restored (there is no `ret` that could
#       consume a wrong address). Restores WITHOUT a save are still flagged.
#       This keeps noreturn fail-loud helpers clean while still checking
#       every returning function.  A tail-call `jmp` (no `ret`) has the same
#       blind spot as the AArch64 checker's `b sym`.
#     * rsp is not tracked across `pop %rsp` (the value is untrackable); such
#       an instruction is counted as a plain pop for balance purposes.
#
# USAGE
#   ./check-clobbers-x86_64.sh [--preprocess] [-I <dir>] <file.S|dir> [...]
#     (no flag)     analyze the RAW source AND the preprocessed text (default)
#     --preprocess  accepted for compatibility (prints a one-line note); raw +
#                   preprocessed are always checked, so the flag is a no-op
#     -I <dir>      add an include dir for preprocessing (repeatable)
#   Exit 0 = GREEN (no findings). Exit 1 = RED (findings, printed file:line).
#   Exit 2 = usage error.
#
# EXAMPLES
#   ./check-clobbers-x86_64.sh cc_http_x86_64.S
#   ./check-clobbers-x86_64.sh -I core/controller/alternate/asm core/controller/alternate/asm/cc_*.S
#   ./check-clobbers-x86_64.sh -I core/controller/alternate/asm cc_json_x86_64.S
#
set -euo pipefail

PREPROCESS=0  # accepted for backward compatibility; the preprocessed pass is always run
INCLUDES=()
FILES=()

usage() {
  sed -n '2,122p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

# --- argument parsing ---
while [ $# -gt 0 ]; do
  case "$1" in
    --preprocess) PREPROCESS=1 ;;
    -I) [ $# -ge 2 ] || usage; INCLUDES+=("-I" "$2"); shift ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) FILES+=("$1") ;;
  esac
  shift
done
[ ${#FILES[@]} -gt 0 ] || usage

# --- --preprocess note (the flag is a behaviorally-no-op) ---
if [ "$PREPROCESS" -eq 1 ]; then
  echo "note: --preprocess is accepted for compatibility; raw + preprocessed are always checked"
fi

# --- materialize the analyzer once ---
ANALYZER="$(mktemp "${TMPDIR:-/tmp}/cc-clobber-x86-analyzer.XXXXXX.py")"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/cc-clobber-x86.XXXXXX")"
trap 'rm -rf "$TMPD" "$ANALYZER"' EXIT HUP INT TERM

cat > "$ANALYZER" <<'PY'
#!/usr/bin/env python3
"""Clobber-discipline analyzer for x86-64 SysV AMD64, embedded in
check-clobbers-x86_64.sh.

Usage: python3 analyzer.py <analyze-path> <display-path>
Analyzes a single assembly file (GNU-as AT&T). Prints file:line findings.
Exit 1 on any finding, 0 otherwise. See the .sh header for the precision
statement.
"""
import re
import sys

# --- SysV AMD64 register model ------------------------------------------------
# Callee-saved GPRs: rbx, rbp, r12-r15.  Callee-saved SIMD: xmm8-xmm15.
GPR_TO_INDEX = {
    "rax": 0, "eax": 0, "ax": 0, "al": 0, "ah": 0,
    "rcx": 1, "ecx": 1, "cx": 1, "cl": 1, "ch": 1,
    "rdx": 2, "edx": 2, "dx": 2, "dl": 2, "dh": 2,
    "rbx": 3, "ebx": 3, "bx": 3, "bl": 3, "bh": 3,
    "rsp": 4, "esp": 4, "sp": 4, "spl": 4,
    "rbp": 5, "ebp": 5, "bp": 5, "bpl": 5,
    "rsi": 6, "esi": 6, "si": 6, "sil": 6,
    "rdi": 7, "edi": 7, "di": 7, "dil": 7,
}
for _i in range(8, 16):
    for _s in ("", "d", "w", "b"):
        GPR_TO_INDEX["r%d%s" % (_i, _s)] = _i

CALLEE_SAVED = (3, 5, 12, 13, 14, 15)      # rbx, rbp, r12-r15
CALLEE_NAME = {3: "rbx", 5: "rbp", 12: "r12", 13: "r13", 14: "r14", 15: "r15"}
# The x86_64 PROLOGUE macro (cc_platform_x86_64.h) ALWAYS pushes the frame
# record {%rbp}, then n callee-saved registers in the fixed order
# rbx, r12, r13, r14, r15 (n <= 5), padding with `sub $8, %rsp` when n is odd
# so the pushes total a multiple of 16.  CALLEE_ORDER is that "n" list.
CALLEE_ORDER = (3, 12, 13, 14, 15)
XMM_SAVED = tuple(range(8, 16))            # xmm8-xmm15
MACRO_MAX_N = 8                            # largest PROLOGUE/EPILOGUE n


def prologue_regs(n):
    """The registers the x86_64 PROLOGUE macro saves for a given n:
    always the frame record {%rbp} plus the first n of CALLEE_ORDER."""
    return {5} | set(CALLEE_ORDER[:n])


def needed_n(reg):
    """The smallest PROLOGUE n whose register list covers `reg`."""
    if reg == 5:
        return 0                      # rbp is saved by every PROLOGUE n >= 0
    return CALLEE_ORDER.index(reg) + 1


def canonical_prologue(n):
    """Raw-pass fallback model for PROLOGUE n (matches the actual macro):
    saves prologue_regs(n), rsp displacement -8*(1+n+(n%2)), and the frame
    base -- the rsp displacement `mov %rbp, %rsp` restores -- is -8."""
    return (frozenset(prologue_regs(n)), -8 * (1 + n + (n % 2)), -8)


def canonical_epilogue(n):
    """Raw-pass fallback model for EPILOGUE n: restores prologue_regs(n),
    rsp displacement +8*(1+n+(n%2))."""
    return (frozenset(prologue_regs(n)), 8 * (1 + n + (n % 2)))

SPECIAL = {
    "call", "ret", "push", "pop", "cmp", "test", "jmp", "lea", "cpuid",
    "xchg", "leave", "enter", "sub", "add", "and", "or", "xor", "mov",
    "nop", "syscall", "movabs", "cmpxchg", "xadd",
}

PROLOGUE_RE = re.compile(r"^\s*PROLOGUE\s+([0-9]+)\b")
EPILOGUE_RE = re.compile(r"^\s*EPILOGUE\s+([0-9]+)\b")
LABEL_RE = re.compile(r"^\s*[A-Za-z_.$][A-Za-z0-9_.$]*\s*:")
DIRECTIVE_RE = re.compile(r"^\s*\.")
INSN_RE = re.compile(r"^\s*([a-zA-Z][a-zA-Z0-9_.]*)(?:\s+(.*))?$")
REDZONE_RE = re.compile(r"-\d+\(%rsp\)|-0[xX][0-9a-fA-F]+\(%rsp\)")
MACRO_RE = re.compile(r"^\s*\.macro\s+(PROLOGUE|EPILOGUE)(?:\s+(\w+))?")


def gpr_index(token):
    """Index of the 64-bit GPR named by an AT&T operand token (0-15), or None."""
    if not token.startswith("%"):
        return None
    return GPR_TO_INDEX.get(token[1:])


def vec_index(token):
    """Index of the vector register (xmm/ymm/zmm) named by a token, or None."""
    m = re.match(r"^%(?:x|y|z)mm([0-9]+)$", token)
    return int(m.group(1)) if m else None


def is_memory(token):
    return "(" in token


def is_rsp(token):
    return gpr_index(token) == 4


def parse_imm(token):
    """Parse an AT&T immediate ($N, $0xN, $-N) to int, or None."""
    t = token.strip()
    if not t.startswith("$"):
        return None
    t = t[1:].strip()
    if re.fullmatch(r"-?0[xX][0-9a-fA-F]+", t):
        return int(t, 16)
    if re.fullmatch(r"-?[0-9]+", t):
        return int(t, 10)
    return None


def mem_disp_base(token):
    """Parse a simple DISP(base) memory operand to (disp, base_index), or None."""
    m = re.match(r"^(-?[0-9]+|-?0[xX][0-9a-fA-F]+)?\(%([a-z0-9]+)\)$", token.strip())
    if not m:
        return None
    base = gpr_index("%" + m.group(2))
    if base is None:
        return None
    d = m.group(1)
    if d is None or d == "":
        disp = 0
    elif d.lower().startswith("0x"):
        disp = int(d, 16)
    elif d.lower().startswith("-0x"):
        disp = -int(d[1:], 16)
    else:
        disp = int(d, 10)
    return disp, base


def split_operands(s):
    """Split an AT&T operand list on commas at parenthesis depth 0."""
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch == "(":
            depth += 1
            cur += ch
        elif ch == ")":
            depth = max(0, depth - 1)
            cur += ch
        elif ch == "," and depth == 0:
            if cur.strip():
                out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def base_mnem(m):
    """Strip a size suffix from an AT&T mnemonic; classify branches."""
    if m in SPECIAL:
        return m
    if len(m) > 3 and m[-1] in "bwlqsd":
        b = m[:-1]
        if b in SPECIAL:
            return b
    if m.startswith("j") or m.startswith("loop"):
        return "jcc"
    return m


def written_regs(mnem, operands):
    """Return (gpr_indices_written, xmm_indices_written) heuristically.

    AT&T: the LAST operand is the destination; the special cases are the
    read-only and stack mnemonics from the checker header.
    """
    base = base_mnem(mnem)
    toks = split_operands(operands)
    if not toks:
        return set(), set()
    dst = toks[-1]
    if base == "push":
        return set(), set()                  # pushes memory; operand is the source
    if base == "pop":
        gi = gpr_index(dst)
        return ({gi}, set()) if gi is not None else (set(), set())
    if base == "leave":
        return {5}, set()                    # rbp := [rsp]
    if base == "cpuid":
        return {0, 1, 2, 3}, set()           # implicit rax rbx rcx rdx
    if base in ("call", "ret", "jmp", "jcc", "cmp", "test", "nop", "syscall"):
        return set(), set()
    if base == "xchg":
        g, v = set(), set()
        for t in toks:
            gi = gpr_index(t)
            if gi is not None:
                g.add(gi)
            vi = vec_index(t)
            if vi is not None:
                v.add(vi)
        return g, v
    if dst.startswith("*"):
        dst = dst[1:]                        # indirect forms: call *%rax / jmp *(%rax)
    gi = gpr_index(dst)
    if gi is not None:
        return {gi}, set()
    vi = vec_index(dst)
    if vi is not None:
        return set(), {vi}
    return set(), set()                      # memory or immediate destination


def strip_comments_x86(text):
    """Strip `#` and `//` comments and split `;` statement separators.

    `#` is the GNU-as x86 line comment; `//` is this project's dialect
    comment (CPP-stripped).  `;` is a STATEMENT SEPARATOR, not a comment --
    both statements are analyzed.  Directive lines (starting with `.`) are
    passed through whole so string literals in .ascii/.string are not
    mangled.  Returns a list of per-line statement texts.
    """
    out = []
    for line in text.split("\n"):
        if line.strip().startswith("."):
            out.append(line)
            continue
        cur, i, n = "", 0, len(line)
        in_str = False
        while i < n:
            ch = line[i]
            if in_str:
                cur += ch
                if ch == '"':
                    in_str = False
                i += 1
                continue
            if ch == '"':
                in_str = True
                cur += ch
                i += 1
                continue
            if ch == "#":
                break
            if ch == ";":
                out.append(cur)
                cur = ""
                i += 1
                continue
            if ch == "/" and i + 1 < n and line[i + 1] == "/":
                break
            cur += ch
            i += 1
        out.append(cur)
    return out


def eval_guard(cond, n, param):
    """Evaluate a GNU-as .if guard with \\param := n; None if unparseable."""
    expr = cond.replace("\\" + param, str(n))
    if not re.fullmatch(r"[0-9+\-*/().%<>=!&| \t]+", expr):
        return None
    try:
        return bool(eval(expr, {"__builtins__": {}}, {}))
    except Exception:
        return None


def extract_macro_models(lines):
    """Parse .macro PROLOGUE/EPILOGUE bodies from the stream.

    Returns {'PROLOGUE': {n: (frozenset(saved_regs), delta, rbp_delta_or_None)},
    'EPILOGUE': {n: (frozenset(restored_regs), delta)}}.  Empty when the
    macros are not defined in this stream (the raw pass; the canonical model
    applies instead).  `.elseif` and unparseable guards invalidate the whole
    macro model for that macro (canonical fallback; the caller prints a
    note).  rbp_delta is the frame-base displacement when the body contains
    an active `mov %rsp, %rbp` at that n, else None.
    """
    models = {"PROLOGUE": {}, "EPILOGUE": {}}
    i = 0
    while i < len(lines):
        m = MACRO_RE.match(lines[i])
        if not m:
            i += 1
            continue
        mname, param = m.group(1), m.group(2) or "n"
        body = []                            # (guard_path, text)
        stack = []                           # (cond, inverted)
        broken = False
        i += 1
        while i < len(lines):
            t = lines[i].strip()
            if t.startswith(".endm"):
                break
            if t.startswith(".elseif"):
                broken = True
                i += 1
                continue
            if t.startswith(".else"):
                if stack:
                    prev, inv = stack[-1]
                    stack[-1] = (prev, not inv)
                i += 1
                continue
            if t.startswith(".if"):
                stack.append((t[3:].strip(), False))
                i += 1
                continue
            if t.startswith(".endif"):
                if stack:
                    stack.pop()
                i += 1
                continue
            if not t.startswith(".") and t:
                body.append((tuple(stack), lines[i]))
            i += 1
        for n in range(0, MACRO_MAX_N + 1):
            regs, delta = set(), 0
            frame_base = None
            for guards, text in body:
                ok = True
                for cond, inv in guards:
                    v = eval_guard(cond, n, param)
                    if v is None:
                        broken = True
                        ok = False
                        break
                    if inv:
                        v = not v
                    if not v:
                        ok = False
                        break
                if not ok:
                    continue
                mm = re.match(r"^(push|pop|sub|add|mov|lea)\b(.*)$", text.strip())
                if not mm:
                    continue
                op, rest = mm.group(1), mm.group(2)
                toks = split_operands(rest)
                if not toks:
                    continue
                if op == "push":
                    gi = gpr_index(toks[-1])
                    if gi is not None:
                        regs.add(gi)
                    delta -= 8
                elif op == "pop":
                    gi = gpr_index(toks[-1])
                    if gi is not None:
                        regs.add(gi)
                    delta += 8
                elif op == "sub" and is_rsp(toks[-1]):
                    val = parse_imm(toks[0] if len(toks) > 0 else "")
                    if val is not None:
                        delta -= val
                    else:
                        broken = True
                elif op == "add" and is_rsp(toks[-1]):
                    val = parse_imm(toks[0] if len(toks) > 0 else "")
                    if val is not None:
                        delta += val
                    else:
                        broken = True
                elif op == "mov" and is_rsp(toks[-1]):
                    # mov %rbp, %rsp inside an epilogue restores the prologue
                    # frame; net zero for a matched PROLOGUE/EPILOGUE pair.
                    pass
                elif op == "mov" and is_rsp(toks[0] if len(toks) > 0 else "") and gpr_index(toks[-1]) == 5:
                    # mov %rsp, %rbp sets the frame base at the current delta.
                    if frame_base is None:
                        frame_base = delta
                elif op == "lea" and gpr_index(toks[-1]) == 5:
                    mb = mem_disp_base(toks[0] if len(toks) > 0 else "")
                    if mb and mb[1] == 4:
                        # lea DISP(%rsp), %rbp -> frame base = delta - DISP
                        if frame_base is None:
                            frame_base = delta - mb[0]
            rbp_delta = frame_base
            models[mname][n] = (frozenset(regs), delta, rbp_delta)
        if broken:
            models[mname] = {}
        i += 1
    return models


def new_function(name, lineno):
    return {
        "name": name, "start": lineno,
        "delta": 0, "rbp_delta": None, "epilogue_seen": False,
        "pushes": {}, "pops": {},
        "writes": {}, "first": {}, "last": {},
        "prologue": None, "prologue_line": None, "epilogue": None,
        "call_lines": [], "ret_lines": [], "ret_deltas": [], "call_deltas": [],
        "redzone_lines": [], "untracked_rsp": [],
        "xmm_writes": {}, "xmm_first": {}, "xmm_last": {},
        "xmm_saves": {}, "xmm_restores": {},
    }


def add_delta(fn, lineno, amt):
    if fn["delta"] is None:
        return None
    return fn["delta"] + amt


def note(fn, lineno, msg):
    fn.setdefault("notes", []).append((lineno, msg))


def process_instruction(fn, lineno, mnem, operands, findings):
    base = base_mnem(mnem)
    toks = split_operands(operands)
    dst = toks[-1] if toks else ""
    src = toks[0] if len(toks) > 0 else ""
    name = fn["name"]
    rsp_handled = False

    # --- stack / rsp effects (run before generic write tracking) ------------
    if base == "push":
        fn["delta"] = add_delta(fn, lineno, -8)
        gi = gpr_index(dst)
        if gi in CALLEE_SAVED:
            fn["pushes"].setdefault(gi, []).append(lineno)
    elif base == "pop":
        fn["delta"] = add_delta(fn, lineno, 8)
        rsp_handled = True
        gi = gpr_index(dst)
        if gi in CALLEE_SAVED:
            fn["pops"].setdefault(gi, []).append(lineno)
    elif base == "call":
        fn["call_lines"].append(lineno)
        # A call on an alternate path AFTER the first (linear) EPILOGUE sees a
        # reset delta of 0, which is NOT the real rsp on that path (the frame
        # is still pushed).  Its alignment cannot be verified linearly; skip
        # it with a note instead of false-REDing (multi-epilogue functions).
        if fn["epilogue_seen"] and fn["delta"] == 0:
            note(fn, lineno,
                 f"{name}: call on an alternate path after an EPILOGUE; "
                 f"rsp alignment unverifiable linearly (review by hand)")
        else:
            fn["call_deltas"].append((lineno, fn["delta"]))
    elif base == "ret":
        fn["ret_lines"].append(lineno)
        fn["ret_deltas"].append((lineno, fn["delta"]))
    elif base == "sub" and is_rsp(dst):
        rsp_handled = True
        val = parse_imm(src)
        if val is None:
            fn["delta"] = None
            note(fn, lineno,
                 f"{name}: sub rsp by an unparseable immediate; rsp balance/alignment unverifiable from here (preprocessed pass adjudicates)")
        else:
            fn["delta"] = add_delta(fn, lineno, -val)
    elif base == "add" and is_rsp(dst):
        rsp_handled = True
        val = parse_imm(src)
        if val is None:
            fn["delta"] = None
            note(fn, lineno,
                 f"{name}: add rsp by an unparseable immediate; rsp balance/alignment unverifiable from here (preprocessed pass adjudicates)")
        else:
            fn["delta"] = add_delta(fn, lineno, val)
    elif base == "and" and is_rsp(dst):
        rsp_handled = True
        if parse_imm(src) == -16 and fn["delta"] is not None and fn["delta"] % 8 == 0:
            if fn["delta"] % 16 == 0:
                fn["delta"] = fn["delta"] + 8
            # delta % 16 == 8: rsp already 0-mod-16; and is a no-op for delta
        else:
            fn["delta"] = None
            fn["untracked_rsp"].append(lineno)
    elif base == "mov" and is_rsp(dst):
        rsp_handled = True
        if gpr_index(src) == 5 and fn["rbp_delta"] is not None:
            fn["delta"] = fn["rbp_delta"]
        elif gpr_index(src) == 5:
            fn["delta"] = None
            note(fn, lineno,
                 f"{name}: mov %rbp, %rsp but no rbp frame base is recorded; rsp balance/alignment unverifiable from here (preprocessed pass adjudicates)")
        else:
            fn["delta"] = None
            fn["untracked_rsp"].append(lineno)
    elif base == "lea" and is_rsp(dst):
        rsp_handled = True
        mb = mem_disp_base(src)
        if mb is None:
            fn["delta"] = None
            fn["untracked_rsp"].append(lineno)
        else:
            disp, bidx = mb
            if bidx == 5 and fn["rbp_delta"] is not None:
                fn["delta"] = fn["rbp_delta"] - disp
            elif bidx == 5:
                fn["delta"] = None
                note(fn, lineno,
                     f"{name}: lea {disp}(%rbp), %rsp but no rbp frame base is recorded; rsp balance/alignment unverifiable from here")
            elif bidx == 4 and fn["delta"] is not None:
                fn["delta"] = fn["delta"] - disp
            else:
                fn["delta"] = None
                fn["untracked_rsp"].append(lineno)
    elif base == "leave":
        rsp_handled = True
        if fn["rbp_delta"] is not None:
            fn["delta"] = fn["rbp_delta"] + 8
        else:
            fn["delta"] = None
            note(fn, lineno,
                 f"{name}: leave but no rbp frame base is recorded; rsp balance/alignment unverifiable from here")
        fn["pops"].setdefault(5, []).append(lineno)   # leave restores rbp
    elif base == "enter":
        rsp_handled = True
        val = parse_imm(src)
        if val is None or fn["delta"] is None:
            fn["delta"] = None
            fn["untracked_rsp"].append(lineno)
        else:
            fn["rbp_delta"] = fn["delta"] + 8
            fn["delta"] = fn["delta"] - (8 + val)
        fn["pushes"].setdefault(5, []).append(lineno)  # enter saves rbp

    # --- frame-pointer base recording ---------------------------------------
    if base == "mov" and is_rsp(src) and gpr_index(dst) == 5:
        fn["rbp_delta"] = fn["delta"]
    elif base == "lea" and gpr_index(dst) == 5:
        mb = mem_disp_base(src)
        if mb is not None and mb[1] == 4 and fn["delta"] is not None:
            fn["rbp_delta"] = fn["delta"] - mb[0]

    # --- red-zone accesses (leaf-only) ---------------------------------------
    for m in REDZONE_RE.finditer(operands):
        fn["redzone_lines"].append((lineno, m.group(0)))

    # --- generic write tracking ----------------------------------------------
    g_w, v_w = written_regs(mnem, operands)
    if not rsp_handled and 4 in g_w:
        fn["untracked_rsp"].append(lineno)
    for gi in g_w:
        if gi in CALLEE_SAVED:
            fn["writes"].setdefault(gi, 0)
            fn["writes"][gi] += 1
            fn["first"].setdefault(gi, lineno)
            fn["last"][gi] = lineno
    for vi in v_w:
        fn["xmm_writes"].setdefault(vi, 0)
        fn["xmm_writes"][vi] += 1
        fn["xmm_first"].setdefault(vi, lineno)
        fn["xmm_last"][vi] = lineno
        if is_memory(src):
            fn["xmm_restores"].setdefault(vi, []).append(lineno)
    if is_memory(dst):
        vi = vec_index(src)
        if vi is not None:
            fn["xmm_saves"].setdefault(vi, []).append(lineno)


def check_function(fn, display, findings):
    name = fn["name"]
    writes = fn["writes"]
    pro = fn["prologue"]
    epi = fn["epilogue"]
    noreturn = not fn["ret_lines"]

    # --- PROLOGUE/EPILOGUE consistency ---------------------------------------
    if pro is not None:
        if epi is None:
            if not noreturn:
                findings.append((fn["prologue_line"], "ERROR",
                                 f"{name}: PROLOGUE {pro} without a matching EPILOGUE"))
        elif epi != pro:
            findings.append((fn["prologue_line"], "ERROR",
                             f"{name}: PROLOGUE {pro} / EPILOGUE {epi} mismatch"))
    elif epi is not None:
        findings.append((fn["start"], "ERROR",
                         f"{name}: EPILOGUE {epi} without a PROLOGUE"))

    # --- per-register write coverage and window ordering (GPR) ---------------
    for reg in sorted(writes):
        rname = CALLEE_NAME[reg]
        first = fn["first"][reg]
        last = fn["last"][reg]
        needed = needed_n(reg)
        pro_covers = pro is not None and reg in prologue_regs(pro)
        push_lines = fn["pushes"].get(reg, [])
        pop_lines = fn["pops"].get(reg, [])
        push_covers = bool(push_lines) and bool(pop_lines)

        if pro_covers:
            if pro < needed:
                findings.append((first, "ERROR",
                                 f"{name}: writes {rname} but PROLOGUE {pro} is too small "
                                 f"(needs >= {needed})"))
            continue
        if push_covers:
            save_line = min(push_lines)
            restore_line = max(pop_lines)
            if first < save_line:
                findings.append((first, "ERROR",
                                 f"{name}: writes {rname} at line {first} BEFORE its push save "
                                 f"at line {save_line} -- clobbered across any intervening call"))
            if last > restore_line:
                findings.append((last, "ERROR",
                                 f"{name}: writes {rname} at line {last} AFTER its pop restore "
                                 f"at line {restore_line} -- restore must be the last write"))
            continue
        if push_lines or pop_lines:
            if not noreturn:
                findings.append((first, "ERROR",
                                 f"{name}: writes {rname} but its push/pop pair is unbalanced "
                                 f"(saved without restore, or restored without save)"))
            continue
        if not noreturn:
            findings.append((first, "ERROR",
                             f"{name}: writes {rname} but never saves/restores it "
                             f"(add PROLOGUE >= {needed} or a balanced push/pop pair)"))

    # --- balanced push/pop of callee-saved registers -------------------------
    # One PROLOGUE with several return paths is the standard shape (s == 1
    # with many pop restores), so counts are compared only for the dangerous
    # directions: a restore with no save, a save with no restore, or strictly
    # MORE saves than restores (a double-pushed frame).
    for reg in sorted(set(fn["pushes"]) | set(fn["pops"])):
        s = len(fn["pushes"].get(reg, []))
        l = len(fn["pops"].get(reg, []))
        if s == 0:
            findings.append((fn["pops"][reg][0], "ERROR",
                             f"{name}: pop restores {CALLEE_NAME[reg]} but it was never saved by push"))
        elif l == 0:
            if not noreturn:
                findings.append((fn["pushes"][reg][0], "ERROR",
                                 f"{name}: push saves {CALLEE_NAME[reg]} but it is never restored by pop"))
        elif s > l:
            if not noreturn:
                findings.append((fn["pushes"][reg][0], "ERROR",
                                 f"{name}: unbalanced push/pop for {CALLEE_NAME[reg]} "
                                 f"({s} saves vs {l} restores)"))

    # --- net rsp displacement at every ret (the wrong-return-address rule) --
    for lineno, delta in fn["ret_deltas"]:
        if delta is None:
            continue
        if delta != 0:
            findings.append((lineno, "ERROR",
                             f"{name}: net rsp displacement at ret is {delta} (expected 0) "
                             f"-- an unbalanced push/sub makes ret pop the wrong return address"))

    # --- rsp 16-byte alignment at every call (SysV) --------------------------
    for lineno, delta in fn["call_deltas"]:
        if delta is None:
            continue
        rspmod = (8 - delta) % 16
        if rspmod != 0:
            findings.append((lineno, "ERROR",
                             f"{name}: rsp is not 16-byte aligned at call (rsp%16 = {rspmod}); "
                             f"SysV requires 0 at the call instruction"))

    # --- leaf-only red zone --------------------------------------------------
    if fn["call_lines"]:
        for lineno, op in fn["redzone_lines"]:
            findings.append((lineno, "ERROR",
                             f"{name}: {op} red-zone access in a function that calls; "
                             f"the callee's pushes clobber the red zone"))

    # --- xmm8-xmm15 write discipline -----------------------------------------
    # xmm8-xmm15 are callee-saved; xmm0-xmm7 are caller-saved and unchecked,
    # matching the AArch64 checker's v0-v7 vs d8-d15 split (a callee that
    # writes xmm0-7 may clobber them freely across its own calls).
    for vi in sorted(v for v in fn["xmm_writes"] if v in XMM_SAVED):
        xname = "xmm%d" % vi
        first = fn["xmm_first"][vi]
        last = fn["xmm_last"][vi]
        saves = fn["xmm_saves"].get(vi, [])
        restores = fn["xmm_restores"].get(vi, [])
        if saves and restores:
            save_line = min(saves)
            restore_line = max(restores)
            if first < save_line:
                findings.append((first, "ERROR",
                                 f"{name}: writes {xname} at line {first} BEFORE its save store "
                                 f"at line {save_line} -- clobbered across any intervening call"))
            if last > restore_line:
                findings.append((last, "ERROR",
                                 f"{name}: writes {xname} at line {last} AFTER its restore load "
                                 f"at line {restore_line} -- restore must be the last write"))
            continue
        if saves or restores:
            if not noreturn:
                findings.append((first, "ERROR",
                                 f"{name}: writes {xname} but its save/restore is unbalanced "
                                 f"(saved without restore, or restored without save)"))
            continue
        if not noreturn:
            findings.append((first, "ERROR",
                             f"{name}: writes {xname} but never saves/restores it "
                             f"(callee-saved per SysV)"))

    for vi in sorted(v for v in set(fn["xmm_saves"]) | set(fn["xmm_restores"])
                     if v in XMM_SAVED):
        s = len(fn["xmm_saves"].get(vi, []))
        l = len(fn["xmm_restores"].get(vi, []))
        xname = "xmm%d" % vi
        if s == 0:
            findings.append((fn["xmm_restores"][vi][0], "ERROR",
                             f"{name}: restores {xname} but it was never saved"))
        elif l == 0:
            if not noreturn:
                findings.append((fn["xmm_saves"][vi][0], "ERROR",
                                 f"{name}: saves {xname} but it is never restored"))
        elif s > l:
            if not noreturn:
                findings.append((fn["xmm_saves"][vi][0], "ERROR",
                                 f"{name}: unbalanced save/restore for {xname} "
                                 f"({s} saves vs {l} restores)"))

    # --- untracked rsp writes (fail-loud) ------------------------------------
    for lineno in fn["untracked_rsp"]:
        findings.append((lineno, "ERROR",
                         f"{name}: writes rsp from an untracked source; "
                         f"cannot verify rsp balance/alignment"))


def analyze(analyze_path, display):
    try:
        with open(analyze_path, "r", errors="replace") as fh:
            raw = fh.read()
    except OSError as exc:
        print(f"{display}: ERROR: cannot read: {exc}")
        return 1

    lines = strip_comments_x86(raw)
    models = extract_macro_models(lines)
    findings = []
    fn = None
    func_count = 0
    call_count = 0

    def close_function():
        nonlocal fn, func_count, call_count
        if fn is not None:
            func_count += 1
            call_count += len(fn["call_lines"])
            check_function(fn, display, findings)
        fn = None

    for lineno, code in enumerate(lines, 1):
        text = code.strip()
        if not text or text.startswith("#"):
            continue
        if is_function_label(text):
            close_function()
            name = text.rstrip(":").strip()
            fn = new_function(name, lineno)
            continue
        if fn is None:
            continue  # before the first function: headers, macros, rodata
        m = PROLOGUE_RE.match(text)
        if m:
            n = int(m.group(1))
            fn["prologue"] = n
            fn["prologue_line"] = lineno
            model = models["PROLOGUE"].get(n)
            if model is None:
                model = canonical_prologue(n)
                if models["PROLOGUE"]:
                    note(fn, lineno,
                         f"{fn['name']}: PROLOGUE {n} has no derived macro model; using the "
                         f"canonical model (frame record %rbp plus n pushes of "
                         f"[rbx, r12, r13, r14, r15], padded to 16 when n is odd)")
            regs, delta, rbp_delta = model
            fn["delta"] = add_delta(fn, lineno, delta)
            for gi in regs:
                fn["pushes"].setdefault(gi, []).append(lineno)
            if rbp_delta is not None:
                fn["rbp_delta"] = rbp_delta
            continue
        m = EPILOGUE_RE.match(text)
        if m:
            n = int(m.group(1))
            fn["epilogue"] = n
            model = models["EPILOGUE"].get(n)
            if model is None:
                model = canonical_epilogue(n)
                if models["EPILOGUE"]:
                    note(fn, lineno,
                         f"{fn['name']}: EPILOGUE {n} has no derived macro model; using the "
                         f"canonical model (frame record %rbp plus n pops of "
                         f"[rbx, r12, r13, r14, r15], padded to 16 when n is odd)")
            regs, edelta = model[0], model[1]
            depth = -edelta            # the frame depth this EPILOGUE unwinds
            # Multiple return paths share ONE prologue: the first (linear)
            # EPILOGUE sees delta == -depth; a second/alternate EPILOGUE sees
            # delta == 0 (already unwound by the linear scan).  Anything else
            # means the body left an unbalanced push/sub residue, which the
            # EPILOGUE cannot fix (the ret would pop the wrong address).
            if fn["delta"] is not None and fn["delta"] not in (depth, 0):
                findings.append((lineno, "ERROR",
                                 f"{fn['name']}: net rsp displacement before EPILOGUE {n} is "
                                 f"{fn['delta']} (expected the prologue depth {depth}, or 0 on "
                                 f"an alternate path) -- the body left an unbalanced "
                                 f"push/sub that ret would pop as the return address"))
            fn["delta"] = 0            # the frame is fully unwound here
            fn["epilogue_seen"] = True
            for gi in regs:
                fn["pops"].setdefault(gi, []).append(lineno)
            continue
        if DIRECTIVE_RE.match(text) or LABEL_RE.match(text):
            continue  # directives and .L branch targets stay inside the function
        m = INSN_RE.match(text)
        if not m:
            continue  # unknown shape; ignore (guard, not proof)
        mnem, operands = m.group(1), m.group(2) or ""
        process_instruction(fn, lineno, mnem, operands, findings)
    close_function()

    if findings:
        for lineno, sev, msg in findings:
            print(f"{display}:{lineno}: {sev}: {msg}")
        err_count = sum(1 for _l, sev, _m in findings if sev == "ERROR")
        print(f"{display}: summary: functions={func_count} calls={call_count} "
              f"findings={err_count} -- RED")
        return 1
    print(f"{display}: summary: functions={func_count} calls={call_count} "
          f"findings=0 -- GREEN")
    return 0


def is_function_label(text):
    """True when text is a label that starts a NEW function: any label whose
    name does not begin with '.L' (branch targets) and is not a directive or
    section marker. Exported (cc_*), local helpers (module_*), and
    data/rodata labels all match; data labels form empty functions."""
    m = LABEL_RE.match(text)
    if not m:
        return False
    name = m.group(0).strip()[:-1].strip()
    return not name.startswith(".L")


def main(argv):
    if len(argv) != 3:
        print(f"usage: {argv[0]} <analyze-path> <display-path>", file=sys.stderr)
        return 2
    return analyze(argv[1], argv[2])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
PY

# --- run the analyzer on each file: RAW + PREPROCESSED by default ---
RC=0

analyze_one() {
  local f="$1"
  # raw pass
  if ! python3 "$ANALYZER" "$f" "$f"; then RC=1; fi
  # preprocessed pass (always on: registers hidden inside CPP macros are the
  # documented blind spot; the raw scan alone would miss them)
  local tmp="$TMPD/$(basename "$f").pp.S"
  local err="$TMPD/$(basename "$f").pp.err"
  if ! cc -E -P -x assembler-with-cpp "${INCLUDES[@]}" -o "$tmp" "$f" 2>"$err"; then
    echo "$f: ERROR: preprocessing failed (non-ISA); cannot verify the macro-expanded form" >&2
    cat "$err" >&2
    RC=1
  else
    echo "$f: note: analyzing PREPROCESSED text; line numbers refer to the preprocessed stream"
    if ! python3 "$ANALYZER" "$tmp" "$f (preprocessed)"; then RC=1; fi
  fi
}

for f in "${FILES[@]}"; do
  if [ -d "$f" ]; then
    while IFS= read -r -d '' mod; do
      analyze_one "$mod"
    done < <(find "$f" -type f -name 'cc_*.S' -print0 | sort -z)
  elif [ -f "$f" ]; then
    analyze_one "$f"
  else
    echo "$f: ERROR: not a file or directory" >&2
    RC=2
  fi
done

exit "$RC"