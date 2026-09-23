#!/usr/bin/env bash
#
# check-translation.sh -- x86-64 translation-bug scanner for the cc_*.S modules
#
# PURPOSE
#   Catches the mechanical AArch64 -> SysV x86-64 mis-translation classes that
#   the ISA/clobber checkers and the flag-path differential cannot see.  Each
#   class is a pattern that is cheap to grep but needs HUMAN CONFIRMATION
#   (this script is a guard, not a proof -- AGENTS.md).  The classes:
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
#     D. MISSING IMAGE/SNAPSHOT PARENT-CHAIN (candidate)
#        The container-create path must mirror the Go oracle's
#        `containerd.WithNewSnapshot(snapshotID, image)`: Images/Get the
#        image ref, resolve the image's layer chain through the Content
#        service (Content/Info + manifest walk -> diffID -> chainID), then
#        Snapshots/Prepare(key, parent=<chainID>) and Containers/Create with
#        snapshot_key=<snapshotID>.  A Prepare with an EMPTY parent (or no
#        Content-service resolution anywhere) creates a BARE rootfs with no
#        image content -- the image layers are never unpacked.  This is an
#        RPC-sequence/data-flow omission (cc_ctr.c + cc_ctr.S), NOT a
#        translation error, so every finding is a CANDIDATE.  Four mechanical
#        proxies, each cheap and low-false-positive:
#
#        D1. C layer: a `Snapshots/Prepare` invocation whose request parent
#            can be "" (`req.parent = ... : ""` or `= ""`) -- the current
#            cc_ctr_prepare_snapshot boundary default.  The Go oracle always
#            passes the computed chainID, never "".
#        D2. asm: a `call cc_ctr_prepare_snapshot` whose parent arg (%rcx,
#            4th SysV arg) is loaded from an EMPTY-STRING label (`.asciz ""`)
#            or zeroed (NULL -> the C boundary maps NULL to "").  The check
#            is deferred to END because the RODATA `.asciz ""` label is
#            defined AFTER the call site in the file.
#        D3. asm: a `Snapshots/Prepare` call with NO prior image-resolution
#            (cc_ctr_get_image / a content/chainid resolver call) in the same
#            function -- a "Prepare without image" regression guard (does not
#            fire on the current tree, where ctr_start calls GetImage first).
#        D4. file/set: a module or C file that invokes Snapshots/Prepare but
#            contains NO Content-service image-resolution step (the
#            `services.content.v1.Content/` RPC path, a cc_ctr_get_content /
#            cc_ctr_resolve_chainid / cc_ctr_content_* helper) -- the
#            structural miss: without a Content RPC the parent chainID cannot
#            be derived, so the Prepare must be passing an empty parent.
#
#   Runs on the RAW source (comment-stripped).  It is host-arch agnostic: no
#   assembler is invoked, so it works identically on aarch64 and amd64 hosts.
#   AArch64 modules (no x86 registers) are detected and skipped with a note,
#   so the script can be wired into BOTH the arm64 `phase5_checkers` suite
#   (where it skips every module) and the `phase5_checkers_x86_64` suite
#   (where it scans every module).  The C layer files (cc_*.c) are scanned
#   for the class-D RPC-sequence checks on BOTH hosts -- the bug lives in the
#   shared C layer, so the class-D candidates must surface regardless of the
#   host arch.  Once the fix lands (B1: compute the image chainID via a
#   Content-service walk and pass it as the Prepare parent), every class-D
#   candidate clears: D1 sees `req.parent = <chainid>;`, D2 sees a non-empty
#   buffer label in %rcx, D3 never fires, and D4 sees the Content RPC.
#
# PRECISION -- READ THIS (guard, not proof)
#   Class A, B and D findings are CANDIDATES: they are printed but do NOT
#   fail the run (the current tree legitimately contains element-array
#   scale-8 indexings and void leaf functions, and the class-D empty-parent
#   Prepare IS the production bug being tracked -- candidates are how CI
#   surfaces it without false-RED).  Class C findings are ERRORS and fail the
#   run (exit 1) -- a chained call with a stale %rdi is never correct.
#   Human review applies to every finding either way (AGENTS.md: "guards,
#   not proofs").
#
# USAGE
#   ./check-translation.sh [-I <dir>] <file.S|file.c|dir> [...]
#     -I <dir>   accepted for compatibility with asm_checker_test.sh (the
#                scan is source-only; the include dir is unused)
#   Exit 0 = GREEN (no class-C errors; candidates may be printed).
#   Exit 1 = RED (a class-C chained-call error was found).
#   Exit 2 = usage error.
#
# EXAMPLES
#   ./check-translation.sh x86_64/cc_*.S
#   ./check-translation.sh core/controller/alternate/asm/x86_64
#   ./check-translation.sh core/controller/alternate/asm/cc_util.S   # AArch64 -> skipped
#   ./check-translation.sh core/controller/alternate/c/cc_ctr.c      # C-layer class D
#
set -u

FILES=()

usage() {
  sed -n '2,107p' "$0" | sed 's/^# \{0,1\}//'
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
      rcx_src = ""; rcx_ln = 0
      fn_seen_get_image = 0; fn_seen_resolver = 0
    }
    function close_function() {
      if (fn != "" && rets > 0 && calls == 0 && rax_write == 0 && insns > 0) {
        print FILENAME ":" fn_line ": CANDIDATE(B): ret without ever writing %rax and no call (void leaf, or the return-register bug class): " fn
      }
    }
    BEGIN {
      file_has_prepare = 0; file_has_create = 0
      file_has_nonempty_prepare = 0; file_content_signal = 0
      last_label = ""; prep_count = 0
    }
    {
      ln = NR
      t = strip_comment($0)
      gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (t == "") next
      # empty-string RODATA labels: `.asciz ""` marks the preceding label as
      # an empty-parent source (class D2); recorded here, checked at END
      if (t ~ /^\.asciz[ \t]+""([ \t]*$|[ \t]+)/) {
        if (last_label != "") empty_labels[last_label] = 1
        next
      }
      if (t ~ /^\./) next                      # directives (incl. #define/./.macro)
      if (is_label(t)) {
        name = t; sub(/:$/, "", name)
        last_label = name
        if (name !~ /^\.L/) { close_function(); new_function(name, ln) }
        next
      }
      if (fn == "") next                        # before the first function
      insns++
      # ---- class D: Content-service / chainid resolver signal (D4)
      if (t ~ /cc_ctr_(get_content|resolve_chainid|content_[a-z_]+)/ ||
          t ~ /services\.content\.v1\.Content\//) {
        file_content_signal = 1
        fn_seen_resolver = 1
      }
      # ---- class A: scale-2/4/8 indexed memory operand (base+index, disp+index)
      if (t ~ /\(%[a-z][a-z0-9]*,%[a-z][a-z0-9]*,[248]\)|\(,%[a-z][a-z0-9]*,[248]\)/) {
        print FILENAME ":" ln ": CANDIDATE(A): scaled-index memory operand (scale-2/4/8): " t
      }
      # ---- class D2 bookkeeping: track the most recent %rcx write (the
      #      parent argument of the next call; %rcx is caller-saved so any
      #      intervening call resets it).  Only definite writes count.
      if (t ~ /^lea[ \t]+[^,]+\(%rip\),[ \t]*%rcx([ \t]*$|[ \t]+)/) {
        rcx_src = t; sub(/^lea[ \t]+/, "", rcx_src); sub(/\(%rip\).*$/, "", rcx_src)
        rcx_src = "sym:" rcx_src; rcx_ln = ln
      } else if (t ~ /^mov[ \t]+\$[^,]+,%[re]?cx([ \t]*$|[ \t]+)/) {
        rcx_src = "const"; rcx_ln = ln
      } else if (t ~ /^xor[ \t]+%[re]?cx,[ \t]*%[re]?cx/) {
        rcx_src = "zero"; rcx_ln = ln
      } else if (t ~ /%[re]?cx/) {
        n = split(t, toks, ","); last = toks[n]
        if (last ~ /%[re]?cx$/ || t ~ /^pop[ \t]+%[re]?cx/) { rcx_src = "other"; rcx_ln = ln }
      }
      # ---- class C: chained call without %rdi re-thread
      if (t ~ /^call([ \t]+)/) {
        calls++
        if (t ~ /^call[ \t]+cc_ctr_get_image([ \t]*$|[ \t]+)/) fn_seen_get_image = 1
        if (t ~ /^call[ \t]+cc_ctr_prepare_snapshot([ \t]*$|[ \t]+)/) {
          file_has_prepare = 1
          prep_count++
          prep_line[prep_count] = ln
          prep_insn[prep_count] = t
          prep_rcx[prep_count] = rcx_src
          prep_rcx_ln[prep_count] = rcx_ln
          prep_img_ok[prep_count] = (fn_seen_get_image || fn_seen_resolver) ? 1 : 0
          # ---- class D3: Prepare without prior image-resolution in this fn
          if (prep_img_ok[prep_count] == 0) {
            print FILENAME ":" ln ": CANDIDATE(D): Snapshots/Prepare with NO prior image-resolution (Images/Get or content/chainid resolver) in the same function: " t
          }
        }
        if (t ~ /^call[ \t]+cc_ctr_create_container([ \t]*$|[ \t]+)/) file_has_create = 1
        if (prev_insn ~ /^call([ \t]+)/) {
          print FILENAME ":" ln ": ERROR(C): chained call -- previous call at line " prev_ln " left %rdi stale (need mov %rax,%rdi): " t
        } else if ((prev_insn ~ /^lea[ \t]+[^,]+,[ \t]*%rsi([ \t]*$|[ \t]+)/ ||
                    prev_insn ~ /^mov[ \t]+[^,]+,[ \t]*%rsi([ \t]*$|[ \t]+)/) &&
                   prev2_insn ~ /^call([ \t]+)/) {
          print FILENAME ":" ln ": ERROR(C): chained call -- %rdi not reloaded between the call at line " prev2_ln " and this one (only %rsi was set): " t
        }
        rcx_src = ""; rcx_ln = 0                 # a call clobbers %rcx (caller-saved)
      }
      # ---- class B bookkeeping
      if (t ~ /^ret([ \t]*$|[ \t]+)/) rets++
      if (is_rax_write(t)) rax_write = 1
      prev2_insn = prev_insn; prev2_ln = prev_ln
      prev_insn = t; prev_ln = ln
    }
    END {
      close_function()
      # ---- class D2: empty-parent Prepare call sites (deferred: the
      #      `.asciz ""` label definitions live AFTER the call site)
      file_has_nonempty_prepare = 0
      for (i = 1; i <= prep_count; i++) {
        empty = 0
        if (prep_rcx[i] == "zero") {
          empty = 1
          print FILENAME ":" prep_line[i] ": CANDIDATE(D): Snapshots/Prepare passes a NULL/zero parent (image-layer parent chain missing; Go WithNewSnapshot prepares with the computed chainID, never \"\"): " prep_insn[i]
        } else if (prep_rcx[i] ~ /^sym:/) {
          sym = prep_rcx[i]; sub(/^sym:/, "", sym)
          if (sym in empty_labels) {
            empty = 1
            print FILENAME ":" prep_line[i] ": CANDIDATE(D): Snapshots/Prepare passes the EMPTY parent " sym " (loaded at " prep_rcx_ln[i] ") -- image-layer parent chain missing; Go WithNewSnapshot prepares with the computed chainID: " prep_insn[i]
          }
        }
        if (empty == 0) file_has_nonempty_prepare = 1
      }
      # ---- class D4: Prepare present but no Content-service resolution
      if (file_has_prepare == 1 && file_content_signal == 0) {
        print FILENAME ": CANDIDATE(D): Snapshots/Prepare is present but NO Content-service image-resolution/unpack step (Content/ RPC, chainid/diffID resolver) exists anywhere in this module -- the image-layer parent chain cannot be derived"
      }
      # ---- create without a non-empty-parent Prepare (the create path must
      #      consume a snapshot prepared FROM the image chain)
      if (file_has_create == 1 && file_has_prepare == 1 && file_has_nonempty_prepare == 0) {
        print FILENAME ": CANDIDATE(D): Containers/Create is called but every Snapshots/Prepare in this module passes an EMPTY parent -- the container rootfs is a bare snapshot, not the image"
      }
    }
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

# --- C-layer class-D scan (cc_*.c): RPC-sequence/data-flow omissions live in
# the shared C layer, so this runs on BOTH host arches (no AArch64 skip).
check_cfile() {
  local f="$1"
  local out
  out="$(awk '
    # strip C comments (// and /* */, including multi-line blocks) outside
    # double-quoted string literals
    function strip_c_comment(line,   out, i, c) {
      out = ""
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (in_block) {
          if (c == "*" && substr(line, i + 1, 1) == "/") { in_block = 0; i++ }
          continue
        }
        if (in_str) {
          if (c == "\"" && substr(line, i - 1, 1) != "\\") in_str = 0
          out = out c
          continue
        }
        if (c == "\"") { in_str = 1; out = out c; continue }
        if (c == "/" && substr(line, i + 1, 1) == "/") break
        if (c == "/" && substr(line, i + 1, 1) == "*") { in_block = 1; i++; continue }
        out = out c
      }
      return out
    }
    BEGIN {
      in_block = 0; in_str = 0
      file_has_prepare = 0; file_content_signal = 0
      cfn = ""; cfn_empty_parent = ""; cfn_empty_parent_ln = 0
    }
    {
      ln = NR
      t = strip_c_comment($0)
      gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (t == "") next
      # C function start: "int cc_ctr_prepare_snapshot(" etc.
      if (t ~ /^[A-Za-z_][A-Za-z0-9_ ]*[ *]cc_ctr_[a-z_]+\(/) {
        match(t, /cc_ctr_[a-z_]+\(/)
        cfn = substr(t, RSTART, RLENGTH - 1)
      }
      # ---- class D1: a request parent that can be "" (empty-parent default)
      if (t ~ /req\.parent[ \t]*=[^;]*""/) {
        cfn_empty_parent = cfn
        cfn_empty_parent_ln = ln
      }
      # ---- the Snapshots/Prepare RPC invocation
      if (t ~ /Snapshots\/Prepare/) {
        file_has_prepare = 1
        if (cfn != "" && cfn_empty_parent == cfn) {
          print FILENAME ":" cfn_empty_parent_ln ": CANDIDATE(D): " cfn " can pass an EMPTY parent to Snapshots/Prepare (image-layer parent chain missing; the Go oracle containerd.WithNewSnapshot prepares with the image chainID, never \"\"): req.parent set to \"\" at " cfn_empty_parent_ln
        }
      }
      # ---- class D4: Content-service image-resolution signal
      if (t ~ /services\.content\.v1\.Content\// ||
          t ~ /cc_ctr_(get_content|resolve_chainid|content_[a-z_]+)/) {
        file_content_signal = 1
      }
    }
    END {
      if (file_has_prepare == 1 && file_content_signal == 0) {
        print FILENAME ": CANDIDATE(D): Snapshots/Prepare is present in the C layer but NO Content-service image-resolution/unpack step (Content/ RPC or chainid/diffID resolver) exists in this file -- the image-layer parent chain cannot be derived"
      }
    }
  ' "$f")"

  local cand=0 mod_rc=0
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    cand=$(printf '%s\n' "$out" | grep -c 'CANDIDATE' || true)
  fi
  echo "$f: GREEN (candidates=$cand errors=0)"
  return 0
}

for f in "${FILES[@]}"; do
  if [ -d "$f" ]; then
    while IFS= read -r -d '' mod; do
      case "$mod" in
        *.c) check_cfile "$mod" || RC=1 ;;
        *)   check_module "$mod" || RC=1 ;;
      esac
    done < <(find "$f" -type f \( -name 'cc_*.S' -o -name 'cc_*.c' \) -print0 | sort -z)
  elif [ -f "$f" ]; then
    case "$f" in
      *.c) check_cfile "$f" || RC=1 ;;
      *)   check_module "$f" || RC=1 ;;
    esac
  else
    echo "$f: ERROR: not a file or directory" >&2
    RC=2
  fi
done

exit "$RC"