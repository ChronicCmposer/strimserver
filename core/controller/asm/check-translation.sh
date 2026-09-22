#!/usr/bin/env bash
#
# check-translation.sh -- x86-64 translation-bug scanner for the cc_*.S modules
#
# PURPOSE
#   Catches the mechanical AArch64 -> SysV x86-64 mis-translation classes that
#   the ISA/clobber checkers and the flag-path differential cannot see.  Each
#   class is a pattern that is cheap to grep but needs HUMAN CONFIRMATION
#   (this script is a guard, not a proof -- AGENTS.md).  The three classes:
#
#     A. SCALED-INDEX MEMORY OPERANDS (candidate)
#        An AArch64 `ldr x7,[x3,x7]` uses a BYTE offset index; its x86
#        translation must be `mov (%rax,%r11), %r11` (scale 1).  A scale-8
#        form `mov (%rax,%r11,8)` multiplies the offset by 8 and reads past
#        the field (the cc_ctr.S ctr_fill_mounts production bug).  EVERY
#        scale-2/4/8 indexed memory operand is reported; the auditor confirms
#        each one (element-array indexings such as `argv[i]`, `listeners[i]`
#        and `table[stage_id]` are legitimate and match an AArch64 `lsl #3`).
#
#     B. `ret` WITHOUT EVER WRITING %rax (candidate)
#        AArch64 x0 is both arg0 and the return register; SysV %rax is the
#        return register only.  A function that writes %rdi (its arg) but
#        never sets %rax returns garbage (the cc_state.S cc_state_status
#        production bug).  A function with a `ret` that contains NO `call`
#        (no pass-through return) and NO explicit %rax write is reported;
#        void leaf functions (e.g. a signal handler) are legitimate -- the
#        auditor confirms.  Tail-call `jmp` functions (no `ret`) are skipped
#        (their return value comes from the tail-called callee).
#
#     C. CHAINED `call` WITHOUT %rax -> %rdi RE-THREADING (error)
#        AArch64 `bl` chains because return(x0)==arg0; SysV needs a
#        `mov %rax,%rdi` between chained calls (the cc_main.S/cc_env.S
#        production bugs).  A `call` IMMEDIATELY followed by another `call`,
#        or by a `lea/mov ...,%rsi` second-arg setup and then a `call`,
#        without a %rdi reload in between, is reported as an ERROR (this
#        pattern is always wrong: the first call clobbered %rdi).
#
#   Runs on the RAW source (comment-stripped).  It is host-arch agnostic: no
#   assembler is invoked, so it works identically on aarch64 and amd64 hosts.
#   AArch64 modules (no x86 registers) are detected and skipped with a note,
#   so the script can be wired into BOTH the arm64 `phase5_checkers` suite
#   (where it skips every module) and the `phase5_checkers_x86_64` suite
#   (where it scans every module).
#
# PRECISION -- READ THIS (guard, not proof)
#   Class A and B findings are CANDIDATES: they are printed but do NOT fail
#   the run (the current tree legitimately contains element-array scale-8
#   indexings and void leaf functions; every one is verified in the audit
#   report).  Class C findings are ERRORS and fail the run (exit 1) -- a
#   chained call with a stale %rdi is never correct.  Human review applies
#   to every finding either way (AGENTS.md: "guards, not proofs").
#
# USAGE
#   ./check-translation.sh [-I <dir>] <file.S|dir> [...]
#     -I <dir>   accepted for compatibility with asm_checker_test.sh (the
#                scan is source-only; the include dir is unused)
#   Exit 0 = GREEN (no class-C errors; candidates may be printed).
#   Exit 1 = RED (a class-C chained-call error was found).
#   Exit 2 = usage error.
#
# EXAMPLES
#   ./check-translation.sh x86_64/cc_*.S
#   ./check-translation.sh core/controller/asm/x86_64
#   ./check-translation.sh core/controller/asm/cc_util.S   # AArch64 -> skipped
#
set -u

FILES=()

usage() {
  sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    -I) [ $# -ge 2 ] || usage; shift ;;   # accepted for asm_checker_test.sh; unused
    -h|--help) usage ;;
    -*) usage ;;
    *) FILES+=("$1") ;;
  esac
  shift
done
[ ${#FILES[@]} -gt 0 ] || usage

RC=0

check_module() {
  local f="$1"

  # --- AArch64 detection: an x86 module uses %-prefixed GPRs. ---------------
  if ! grep -qE '%(r[a-z0-9]+|e[a-d]x)' "$f"; then
    echo "$f: N/A -- AArch64 module (no x86 %-registers); translation checks apply to x86_64 only"
    return 0
  fi

  local out
  out="$(awk '
    # strip `#` and `//` comments outside double-quoted string literals
    function strip_comment(line) {
      out = ""; in_str = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (in_str) { if (c == "\"") in_str = 0; out = out c; continue }
        if (c == "\"") { in_str = 1; out = out c; continue }
        if (c == "#") break
        if (c == "/" && substr(line, i + 1, 1) == "/") break
        out = out c
      }
      return out
    }
    function is_label(t)   { return (t ~ /^[A-Za-z_.$][A-Za-z0-9_.$]*:[ \t]*$/) }
    function is_rax_write(t) {
      # the LAST comma-separated operand is the AT&T destination
      n = split(t, toks, ",")
      last = toks[n]
      if (n == 1) sub(/^[a-z][a-z0-9.]*[ \t]+/, "", last)   # single-operand form
      if (last ~ /%[re]?a[xlh]$/) return 1                    # %rax/%eax/%ax/%al/%ah
      # CPP macro forms whose FIRST operand is the destination (LEA reg,sym and
      # the MOV_* load macros) -- the raw source hides the AT&T operand order
      if (t ~ /^(LEA|LEA_OFF|MOV_DIV10_MAGIC|MOV_NANOSEC|MOV_DUR_MIN|MOV_DUR_HOUR|LOAD_EXTERN_DATA_ADDR)[ \t]+(r|e)?a[xlh]([, \t]|$)/) return 1
      # 1-operand implicit-rax mnemonics (rdx:rax forms)
      if (t ~ /^(mul|div|idiv)([ \t]+)/) return 1
      if (t ~ /^imul[ \t]+%[a-z0-9]+([ \t]*$|[ \t]+)/) return 1
      if (t ~ /^pop[ \t]+%(r|e)?ax([ \t]*$|[ \t]+)/) return 1
      return 0
    }
    function new_function(name, ln) {
      fn = name; fn_line = ln
      rets = 0; calls = 0; rax_write = 0; insns = 0
      prev_insn = ""; prev2_insn = ""; prev_ln = 0
    }
    function close_function() {
      if (fn != "" && rets > 0 && calls == 0 && rax_write == 0 && insns > 0) {
        print FILENAME ":" fn_line ": CANDIDATE(B): ret without ever writing %rax and no call (void leaf, or the return-register bug class): " fn
      }
    }
    {
      ln = NR
      t = strip_comment($0)
      gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (t == "") next
      if (t ~ /^\./) next                      # directives (incl. #define/./.macro)
      if (is_label(t)) {
        name = t; sub(/:$/, "", name)
        if (name !~ /^\.L/) { close_function(); new_function(name, ln) }
        next
      }
      if (fn == "") next                        # before the first function
      insns++
      # ---- class A: scale-2/4/8 indexed memory operand (base+index, disp+index)
      if (t ~ /\(%[a-z][a-z0-9]*,%[a-z][a-z0-9]*,[248]\)|\(,%[a-z][a-z0-9]*,[248]\)/) {
        print FILENAME ":" ln ": CANDIDATE(A): scaled-index memory operand (scale-2/4/8): " t
      }
      # ---- class C: chained call without %rdi re-thread
      if (t ~ /^call([ \t]+)/) {
        calls++
        if (prev_insn ~ /^call([ \t]+)/) {
          print FILENAME ":" ln ": ERROR(C): chained call -- previous call at line " prev_ln " left %rdi stale (need mov %rax,%rdi): " t
        } else if ((prev_insn ~ /^lea[ \t]+[^,]+,[ \t]*%rsi([ \t]*$|[ \t]+)/ ||
                    prev_insn ~ /^mov[ \t]+[^,]+,[ \t]*%rsi([ \t]*$|[ \t]+)/) &&
                   prev2_insn ~ /^call([ \t]+)/) {
          print FILENAME ":" ln ": ERROR(C): chained call -- %rdi not reloaded between the call at line " prev2_ln " and this one (only %rsi was set): " t
        }
      }
      # ---- class B bookkeeping
      if (t ~ /^ret([ \t]*$|[ \t]+)/) rets++
      if (is_rax_write(t)) rax_write = 1
      prev2_insn = prev_insn; prev2_ln = prev_ln
      prev_insn = t; prev_ln = ln
    }
    END { close_function() }
  ' "$f")"

  local cand=0 errs=0 mod_rc=0
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    cand=$(printf '%s\n' "$out" | grep -c 'CANDIDATE' || true)
    errs=$(printf '%s\n' "$out" | grep -c 'ERROR(C)' || true)
    [ "$errs" -eq 0 ] || mod_rc=1
  fi
  if [ "$mod_rc" -eq 0 ]; then
    echo "$f: GREEN (candidates=$cand errors=$errs)"
  else
    echo "$f: RED (class-C chained-call error)"
  fi
  return "$mod_rc"
}

for f in "${FILES[@]}"; do
  if [ -d "$f" ]; then
    while IFS= read -r -d '' mod; do
      check_module "$mod" || RC=1
    done < <(find "$f" -type f -name 'cc_*.S' -print0 | sort -z)
  elif [ -f "$f" ]; then
    check_module "$f" || RC=1
  else
    echo "$f: ERROR: not a file or directory" >&2
    RC=2
  fi
done

exit "$RC"