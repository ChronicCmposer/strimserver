#!/usr/bin/env bash
#
# check-clobbers.sh -- clobber-discipline checker for cc_*.S modules
#
# PURPOSE
#   Flags AAPCS64 callee-saved-register violations in hand-written ARMv8.2-A
#   assembly (Linux-only, GNU-as, preprocessed by the C compiler):
#     (a) any write to x19-x28 that is not covered by a PROLOGUE n /
#         EPILOGUE n pair (or a balanced explicit stp/ldp pair) in the same
#         function, including writes that fall OUTSIDE the save/restore
#         window (a write before its save or after its restore would clobber
#         the caller's register across a `bl`);
#     (b) unbalanced stp/ldp of callee-saved registers (saved but never
#         restored, restored but never saved, or unequal counts);
#     (c) writes to x29 without a matching `stp x29,x30` frame record
#         (and stp x29,x30 without a matching ldp x29,x30);
#     (d) x30, the link register: any function that calls MUST save x30
#         before the call -- PROLOGUE n always does (`stp x29,x30`), or an
#         explicit stp that names x30 (e.g. `stp x19,x30,[sp,#-16]!`) -- and
#         restore it before its own `ret`.  BOTH `bl` (direct) and `blr`
#         (indirect) clobber x30 and are treated identically by the x30
#         rule.  A `ret` after a `bl`/`blr` without a restore returns to the
#         call's RETURN ADDRESS and loops back into the function (the #1
#         silent-wrongness bug in this codebase).  Neither `bl` nor `blr` is
#         EVER a tail call; only `b sym` is.
#     bonus: any use of x18 (the platform register; hard rule 4 in AGENTS.md).
#
# FUNCTIONS
#   A function starts at ANY label that is not a `.L`-prefixed branch target
#   and not a directive/section marker.  Exported functions are `cc_*:`;
#   local helper functions are `module_*:` (json_*, util_*, env_*, ...).  Both
#   are FULL AAPCS64 functions with the SAME obligations and are analyzed the
#   same way.  Data/rodata labels (e.g. `util_err_prefix:`) form empty
#   functions (no instructions -> no findings); that is acceptable.
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
#       dir, pass -I (the modules include cc_platform.h/cc_layout.inc; the
#       gate passes -I core/controller/asm).
#     * Write-detection classifies mnemonics by family: loads write the GPR
#       operand(s) before the first '['; stores write nothing; swp/ld<op>
#       atomics write the second operand (Rt); casp writes the first two
#       operands; cmp/tst/branch/br/blr/msr read only; everything else writes
#       the first operand. Exotic mnemonics outside these families may be
#       misclassified (rare in this codebase; the families are exhaustive for
#       the GPR instructions the playbook uses).
#     * It treats the function as the analysis unit: a register written
#       anywhere in a function must be covered by that function's save/restore
#       and each write must lie between the save and the restore. Because
#       every `bl` sits inside that window, this subsumes the per-call-site
#       rule ("every callee-saved register written between entry and the call
#       must be preserved") for ordinary entry/exit saves. It is still not a
#       full liveness analysis: e.g. it does not prove that a value actually
#       REMAINS live across a specific `bl`.
#     * x30 is checked at the function level: a function that calls (`bl` or
#       `blr`) but never saves x30 is RED; a `bl`/`blr` AFTER the x30 restore
#       that is followed by a `ret` is RED (the wrong-link bug). A
#       `bl`/`blr` to a noreturn helper (no `ret` reachable after the call)
#       is exempt from the ordering rule.
#     * A function that never contains a `ret` is treated as noreturn: its
#       saves are not required to be restored (there is no `ret` that could
#       consume a wrong value). Restores WITHOUT a save are still flagged.
#       This keeps noreturn fail-loud helpers (e.g. env_fail_*) clean while
#       still checking every returning function.
#     * SIMD instructions are not tracked (v-registers are caller-saved and
#       not in scope), but GPR operands of SIMD instructions ARE classified
#       by the default first-operand-written rule; verify exotic SIMD/GPR
#       mixes by hand.
#
# USAGE
#   ./check-clobbers.sh [--preprocess] [-I <dir>] <file.S|dir> [...]
#     (no flag)     analyze the RAW source AND the preprocessed text (default)
#     --preprocess  accepted for compatibility (prints a one-line note); raw +
#                   preprocessed are always checked, so the flag is a no-op
#     -I <dir>      add an include dir for preprocessing (repeatable)
#   Exit 0 = GREEN (no findings). Exit 1 = RED (findings, printed file:line).
#   Exit 2 = usage error.
#
# EXAMPLES
#   ./check-clobbers.sh cc_http.S
#   ./check-clobbers.sh -I core/controller/asm core/controller/asm/cc_*.S
#   ./check-clobbers.sh -I core/controller/asm cc_json.S
#
set -euo pipefail

PREPROCESS=0  # accepted for backward compatibility; the preprocessed pass is always run
INCLUDES=()
FILES=()

usage() {
  sed -n '2,89p' "$0" | sed 's/^# \{0,1\}//'
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
ANALYZER="$(mktemp "${TMPDIR:-/tmp}/cc-clobber-analyzer.XXXXXX.py")"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/cc-clobber.XXXXXX")"
trap 'rm -rf "$TMPD" "$ANALYZER"' EXIT HUP INT TERM

cat > "$ANALYZER" <<'PY'
#!/usr/bin/env python3
"""Clobber-discipline analyzer, embedded in check-clobbers.sh.

Usage: python3 analyzer.py <analyze-path> <display-path>
Analyzes a single assembly file. Prints file:line findings. Exit 1 on any
finding, 0 otherwise. See the .sh header for the precision statement.
"""
import re
import sys

CALLEE_SAVED = tuple(range(19, 29))  # x19..x28

# --- mnemonic classification (see precision note in the .sh header) ---
STORE_RE = re.compile(
    r"^(str|stur|stp|stnp|sttr|stxr|stlxr|stxp|stlxp|stllr|stlr|stlurb|stlurh|stlur|stg|st2g|stzg|stz2g|stgm|stgp)\b")
LOAD_RE = re.compile(
    r"^(ldr|ldur|ldp|ldnp|ldar|ldaxr|ldxr|ldaxp|ldxp|ldrb|ldrh|ldrsw|ldrsb|ldrsh|ldtr|ldtrb|ldtrh|ldtrsb|ldtrsh|ldtrsw|ldapr|ldurh|ldurb|ldursb|ldursh|ldursw|ldgm|ldraa|ldrab)\b")
READONLY_FIRST_RE = re.compile(
    r"^(cmp|cmn|tst|ccmp|ccmn|cbz|cbnz|tbz|tbnz|br|blr|msr|prfm|dc|ic|at|tlbi|cfp|dvp|cosp)\b")
SWP_LDOP_RE = re.compile(r"^(swp|ldadd|ldclr|ldeor|ldset|ldsmax|ldsmin|ldumax|ldumin)(al|a|l)?\b")
CASP_RE = re.compile(r"^casp(al|a|l)?\b")

XREG_RE = re.compile(r"\b(x(?:19|20|21|22|23|24|25|26|27|28))\b")
X29_RE = re.compile(r"\bx29\b")
X30_RE = re.compile(r"\bx30\b")
X18_RE = re.compile(r"\bx18\b")

PROLOGUE_RE = re.compile(r"^\s*PROLOGUE\s+([0-9]+)\b")
EPILOGUE_RE = re.compile(r"^\s*EPILOGUE\s+([0-9]+)\b")
LABEL_RE = re.compile(r"^\s*[A-Za-z_.$][A-Za-z0-9_.$]*\s*:")
DIRECTIVE_RE = re.compile(r"^\s*\.")
INSN_RE = re.compile(r"^\s*([a-z][a-z0-9_.]*)(?:\s+(.*))?$")


def strip_comments(text):
    """Remove /* */ (spanning lines), then // and ';' to end of line."""
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    out = []
    for line in text.split("\n"):
        for marker in ("//", ";"):
            idx = line.find(marker)
            if idx >= 0:
                line = line[:idx]
        out.append(line)
    return out


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


def written_regs(mnem, operands):
    """Return the set of GPR indices this instruction WRITES (heuristic)."""
    if STORE_RE.match(mnem):
        return set()
    if READONLY_FIRST_RE.match(mnem):
        return set()
    if SWP_LDOP_RE.match(mnem):
        # swp Rs, Rt, [Rn]; ld<op> Rs, Rt, [Rn] -> Rt (2nd operand) is written
        toks = [t.strip() for t in operands.split(",")]
        m = re.match(r"^x([0-9]+)$", toks[1]) if len(toks) >= 2 else None
        return {int(m.group(1))} if m else set()
    if CASP_RE.match(mnem):
        toks = [t.strip() for t in operands.split(",")]
        out = set()
        for t in toks[:2]:
            m = re.match(r"^x([0-9]+)$", t)
            if m:
                out.add(int(m.group(1)))
        return out
    if LOAD_RE.match(mnem):
        # destination GPRs are the register operands before the first '['
        pre = operands.split("[")[0]
        out = set()
        for t in (x.strip() for x in pre.split(",") if x.strip()):
            m = re.match(r"^x([0-9]+)$", t)
            if m:
                out.add(int(m.group(1)))
        return out
    # default: first operand is the destination
    m = re.match(r"^x([0-9]+)\b", operands.strip())
    return {int(m.group(1))} if m else set()


def required_prologue_n(max_reg):
    """Smallest n such that PROLOGUE n covers x19..x(max_reg) (pairs)."""
    return (max_reg - 18 + 1) // 2


def new_function(name, lineno):
    return {
        "name": name, "start": lineno,
        "writes": {}, "first": {}, "last": {},
        "stp": {}, "ldp": {}, "stp_x29": 0, "ldp_x29": 0,
        "writes29": [], "x18": [],
        "prologue": None, "prologue_line": None,
        "epilogue": None,
        "bl_lines": [], "x30_save": [], "x30_restore": [], "ret_lines": [],
    }


def check_function(fn, display, findings):
    name = fn["name"]
    writes = fn["writes"]
    pro = fn["prologue"]
    epi = fn["epilogue"]
    # A function with no `ret` at all is treated as noreturn: no `ret` exists
    # that could consume a wrong register value, so its saves need no restore.
    noreturn = not fn["ret_lines"]

    # --- PROLOGUE/EPILOGUE consistency ---
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

    # --- per-register write coverage and window ordering ---
    for reg in sorted(writes):
        rname = f"x{reg}"
        first = fn["first"][reg]
        last = fn["last"][reg]
        pro_covers = pro is not None and reg <= 18 + 2 * pro
        stp_lines = fn["stp"].get(reg, [])
        ldp_lines = fn["ldp"].get(reg, [])
        stp_covers = bool(stp_lines) and bool(ldp_lines)

        if pro_covers:
            # PROLOGUE saves at entry, EPILOGUE restores at exit; the
            # prologue/epilogue consistency check above guarantees the pair.
            if pro < required_prologue_n(reg):
                findings.append((first, "ERROR",
                                 f"{name}: writes {rname} but PROLOGUE {pro} is too small "
                                 f"(needs >= {required_prologue_n(reg)})"))
            continue
        if stp_covers:
            save_line = min(stp_lines)
            restore_line = max(ldp_lines)
            if save_line >= first:
                findings.append((first, "ERROR",
                                 f"{name}: writes {rname} at line {first} BEFORE its stp save "
                                 f"at line {save_line} -- clobbered across any intervening bl"))
            if last > restore_line:
                findings.append((last, "ERROR",
                                 f"{name}: writes {rname} at line {last} AFTER its ldp restore "
                                 f"at line {restore_line} -- restore must be the last write"))
            continue
        if stp_lines or ldp_lines:
            if not noreturn:
                findings.append((first, "ERROR",
                                 f"{name}: writes {rname} but its stp/ldp pair is unbalanced "
                                 f"(saved without restore, or restored without save)"))
            continue
        if not noreturn:
            findings.append((first, "ERROR",
                             f"{name}: writes {rname} but never saves/restores it "
                             f"(add PROLOGUE >= {required_prologue_n(reg)} or a balanced stp/ldp pair)"))

    # --- balanced stp/ldp of callee-saved registers ---
    # One PROLOGUE with several return paths is the codebase's standard shape
    # (s == 1 with many ldp restores), so counts are compared only for the
    # dangerous directions: a restore with no save, a save with no restore,
    # or strictly MORE saves than restores (a double-pushed frame).
    for reg in sorted(set(fn["stp"]) | set(fn["ldp"])):
        s = len(fn["stp"].get(reg, []))
        l = len(fn["ldp"].get(reg, []))
        if s == 0:
            findings.append((fn["ldp"][reg][0], "ERROR",
                             f"{name}: ldp restores x{reg} but it was never saved by stp"))
        elif l == 0:
            if not noreturn:
                findings.append((fn["stp"][reg][0], "ERROR",
                                 f"{name}: stp saves x{reg} but it is never restored by ldp"))
        elif s > l:
            if not noreturn:
                findings.append((fn["stp"][reg][0], "ERROR",
                                 f"{name}: unbalanced stp/ldp for x{reg} "
                                 f"({s} saves vs {l} restores)"))

    # --- x29 frame record ---
    if fn["writes29"]:
        if fn["stp_x29"] == 0:
            findings.append((fn["writes29"][0], "ERROR",
                             f"{name}: writes x29 without a matching `stp x29,x30` frame record"))
    if fn["stp_x29"] > 0 and fn["ldp_x29"] == 0:
        findings.append((fn["start"], "ERROR",
                         f"{name}: saves x29/x30 but never restores them"))
    if fn["ldp_x29"] > 0 and fn["stp_x29"] == 0:
        findings.append((fn["start"], "ERROR",
                         f"{name}: restores x29/x30 without a matching `stp x29,x30` save"))

    # --- x30 (the link register) ---
    bl_lines = fn["bl_lines"]
    if bl_lines:
        if not fn["x30_save"]:
            findings.append((bl_lines[0], "ERROR",
                             f"{name}: calls (bl) but never saves x30; bl clobbers x30 "
                             f"and a later ret would return to the bl's caller, not "
                             f"this function's caller"))
        elif fn["x30_restore"]:
            last_restore = max(fn["x30_restore"])
            for bl_line in bl_lines:
                if bl_line > last_restore and any(r > bl_line for r in fn["ret_lines"]):
                    findings.append((bl_line, "ERROR",
                                     f"{name}: bl at line {bl_line} after x30 was restored "
                                     f"at line {last_restore} -- ret would use the wrong link"))
        else:
            # x30 saved but never restored: a ret after a bl would use the bl's link.
            for bl_line in bl_lines:
                if any(r > bl_line for r in fn["ret_lines"]):
                    findings.append((bl_line, "ERROR",
                                     f"{name}: bl at line {bl_line} after x30 was saved at "
                                     f"line {fn['x30_save'][0]} but never restored -- ret "
                                     f"would use the wrong link"))

    # --- x18 (hard rule 4) ---
    for lineno in fn["x18"]:
        findings.append((lineno, "ERROR",
                         f"{name}: uses x18 (platform register; never use x18)"))


def analyze(analyze_path, display):
    try:
        with open(analyze_path, "r", errors="replace") as fh:
            raw = fh.read()
    except OSError as exc:
        print(f"{display}: ERROR: cannot read: {exc}")
        return 1

    lines = strip_comments(raw)  # already a list of per-line code text
    findings = []
    fn = None
    func_count = 0
    bl_count = 0

    def close_function():
        nonlocal fn, func_count, bl_count
        if fn is not None:
            func_count += 1
            bl_count += len(fn["bl_lines"])
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
            fn["prologue"] = int(m.group(1))
            fn["prologue_line"] = lineno
            fn["x30_save"].append(lineno)   # PROLOGUE always does stp x29,x30
            continue
        m = EPILOGUE_RE.match(text)
        if m:
            fn["epilogue"] = int(m.group(1))
            fn["x30_restore"].append(lineno)  # EPILOGUE always does ldp x29,x30
            continue
        if DIRECTIVE_RE.match(text) or LABEL_RE.match(text):
            # .L branch targets and directives stay inside the current function
            continue
        m = INSN_RE.match(text)
        if not m:
            continue  # unknown shape; ignore (guard, not proof)
        mnem, operands = m.group(1), m.group(2) or ""
        if mnem == "bl" or mnem == "blr":
            fn["bl_lines"].append(lineno)
        if mnem == "ret":
            fn["ret_lines"].append(lineno)
        if X18_RE.search(text):
            fn["x18"].append(lineno)

        if mnem.startswith("stp"):
            pre = operands.split("[")[0]
            for r in XREG_RE.findall(pre):
                fn["stp"].setdefault(int(r[1:]), []).append(lineno)
            if X29_RE.search(pre):
                fn["stp_x29"] += 1
            if X30_RE.search(pre):
                fn["x30_save"].append(lineno)  # e.g. stp x19,x30 / stp x30,xzr
        elif mnem.startswith("ldp"):
            pre = operands.split("[")[0]
            for r in XREG_RE.findall(pre):
                fn["ldp"].setdefault(int(r[1:]), []).append(lineno)
            if X29_RE.search(pre):
                fn["ldp_x29"] += 1
            if X30_RE.search(pre):
                fn["x30_restore"].append(lineno)

        for rn in written_regs(mnem, operands):
            if rn in CALLEE_SAVED:
                fn["writes"].setdefault(rn, 0)
                fn["writes"][rn] += 1
                fn["first"].setdefault(rn, lineno)
                fn["last"][rn] = lineno
            elif rn == 29:
                fn["writes29"].append(lineno)
    close_function()

    if findings:
        for lineno, sev, msg in findings:
            print(f"{display}:{lineno}: {sev}: {msg}")
        print(f"{display}: summary: functions={func_count} bl_calls={bl_count} "
              f"findings={len(findings)} -- RED")
        return 1
    print(f"{display}: summary: functions={func_count} bl_calls={bl_count} "
          f"findings=0 -- GREEN")
    return 0


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