#!/usr/bin/env bash
#
# check-isa-x86_64.sh -- ISA-compliance checker for x86_64 cc_*.S modules
#
# PURPOSE
#   Verifies that a cc_*.S module (hand-written x86-64, Linux-only, GNU-as
#   AT&T syntax, preprocessed by the C compiler) stays inside the ISA
#   envelope: FLOOR = x86-64-v4 (the build's -march), CAP = AVX2 (no
#   zmm/k/AVX-512, no AMX). This protects g4dn.xlarge (Cascade Lake)
#   parity: the dev host is newer and its toolchain would silently run an
#   AVX-512/AMX instruction. "It assembled on my machine" must not mean
#   "it runs on the target".
#
# HOST-ARCH GUARD (the assembly gate runs `cc -c -x assembler-with-cpp
# -march=x86-64-v4`; on a NON-x86_64 host the native cc rejects the x86
# flag and the checker would be falsely RED):
#   1. x86_64 host            -> native cc / objdump / addr2line (strict).
#   2. x86_64-linux-gnu-gcc   -> cross GCC + cross binutils (if the cross
#      objdump/addr2line are missing, llvm-objdump/llvm-addr2line fall back).
#   3. clang --target=x86_64-linux-gnu -> clang cross + llvm-objdump /
#      llvm-addr2line (clang's integrated assembler accepts AT&T GNU-as
#      syntax; verified on clang 21).
#   4. none                    -> print "SKIPPED (no x86_64 assembler on this
#      host)" and exit 0 (NOT red): translators get correct local feedback
#      and CI is still strict where a real x86_64 cc exists.
#   The strict-blacklist-update self-check probes with GNU `as` from PATH
#   (or $CC_ISA_AS); when no GNU x86 assembler exists it skips non-blocking,
#   matching check-isa.sh's conservative behavior.
#
# METHOD (documented; empirically verified on binutils 2.44 x86_64,
# Debian trixie, 2026-09 -- see Task 1 findings)
#   x86 GNU as has NO in-source ISA directive (.arch/.cpu/.arch_extension
#   are unknown pseudo-ops and cannot assemble), and `as -march=x86-64-v4`
#   is itself invalid -- x86-64-vN are GCC-level -march values, not gas
#   -march values. With NO -march the x86 assembler accepts EVERYTHING
#   (zmm/k/AMX all assemble silently). The three gates are therefore:
#   1. DIRECTIVE SCAN (convention guard): reject any in-source `.arch`,
#      `.cpu`, `.arch_extension` (RED, file:line). On x86 these can never
#      assemble anyway; the scan is the project-convention gate -- the
#      floor is the build's -march, never an in-source directive.
#   2. ASSEMBLY GATE (floor proof): assemble the module through the C
#      compiler (`cc -c -x assembler-with-cpp -march=x86-64-v4`, matching
#      production). The module MUST build under the floor -march; any
#      assembly failure is RED (fail-loud, non-zero exit). Because gas
#      does not gate, this proves the build command works, not the cap --
#      the cap is gate 3.
#   3. DISASSEMBLY GATE (authoritative cap gate on x86): objdump -d the
#      object and scan the instruction stream for zmm/k/tmm registers,
#      AVX-512-only mnemonics (curated blacklist), EVEX-encoded scalar
#      forms (objdump prints `{evex}`), and AMX (tdp*/tile*/ldtilecfg +
#      tmm regs). Each hit is mapped back to file:line via addr2line
#      (assembled with -g).
#
# PRECISION
#   The mnemonic blacklist is curated from the AVX-512/AMX feature sets
#   and is not guaranteed exhaustive; human review applies (AGENTS.md).
#   This script is a guard, not a proof. It reports file:line for every
#   violation. An assembly failure under the floor -march is RED, not a
#   warning: the module does not build and the build gate must fail
#   (fail-loud).
#
# USAGE
#   ./check-isa-x86_64.sh [--floor x86-64-v4] [--cap avx2]
#                         [--strict-blacklist-update]
#                         [--blacklist-arch <gas-march>] [-I <dir>]
#                         <file.S|dir> [...]
#     --floor <x>     GCC-level -march floor for the assembly gate
#                     (default x86-64-v4)
#     --cap <x>       enforcement cap: avx2 (default; reject zmm/k/AVX-512
#                     AND AMX) or avx512 (reject AMX only). The settled
#                     project cap is avx2.
#     --strict-blacklist-update
#                     self-check: probe every mnemonic in the curated
#                     blacklist under a HIGH gas -march (--blacklist-arch,
#                     default the AVX-512+AMX bundle) and fail if one does
#                     not assemble -- a dead blacklist entry is a typo.
#                     Conservative: skipped (non-blocking) when the host
#                     assembler does not know the high arch.
#     --blacklist-arch <x>
#                     gas -march used by the blacklist self-check
#                     (default generic64+avx512f+avx512bw+avx512vl+
#                     avx512dq+avx512vbmi+avx512_vbmi2+avx512_vnni+
#                     avx512_bitalg+amx_int8+amx_tile)
#     -I <dir>        add an include dir for assembly (repeatable)
#   Exit 0 = GREEN (verified). Exit 1 = RED (violations, file:line).
#   Exit 2 = usage error.
#
# EXAMPLES
#   ./check-isa-x86_64.sh x86_64/cc_http.S
#   ./check-isa-x86_64.sh -I core/controller/alternate/asm/x86_64 core/controller/alternate/asm/x86_64
#   ASM_INCLUDES=core/controller/alternate/asm/x86_64 ./check-isa-x86_64.sh cc_json.S
#   ./check-isa-x86_64.sh --strict-blacklist-update x86_64
#
set -euo pipefail

FLOOR="x86-64-v4"
CAP="avx2"
INCLUDES=()
FILES=()
EXTRA_INC=()
STRICT_BL=0
BL_ARCH="generic64+avx512f+avx512bw+avx512vl+avx512dq+avx512vbmi+avx512_vbmi2+avx512_vnni+avx512_bitalg+amx_int8+amx_tile"
if [ -n "${ASM_INCLUDES:-}" ]; then
  for d in ${ASM_INCLUDES//:/ }; do
    [ -n "$d" ] && EXTRA_INC+=("-I" "$d")
  done
fi

usage() {
  sed -n '2,64p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --floor) [ $# -ge 2 ] || usage; FLOOR="$2"; shift ;;
    --cap) [ $# -ge 2 ] || usage; CAP="$2"; shift ;;
    --strict-blacklist-update) STRICT_BL=1 ;;
    --blacklist-arch) [ $# -ge 2 ] || usage; BL_ARCH="$2"; shift ;;
    -I) [ $# -ge 2 ] || usage; INCLUDES+=("-I" "$2"); shift ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) FILES+=("$1") ;;
  esac
  shift
done
[ ${#FILES[@]} -gt 0 ] || usage
case "$CAP" in
  avx2|avx512) ;;
  *) echo "check-isa-x86_64.sh: ERROR: unsupported --cap '$CAP' (avx2 or avx512)" >&2; usage ;;
esac

# --- host-arch guard: resolve an x86_64-capable toolchain ----------------
# The assembly gate invokes `cc -march=x86-64-v4`.  On a non-x86_64 host the
# native cc rejects the x86 flag (aarch64 gcc: "unknown value 'x86-64-v4'"),
# so the checker would be falsely RED.  Resolve in order:
#   (a) native cc/objdump/addr2line on an x86_64 host;
#   (b) x86_64-linux-gnu-gcc + x86_64-linux-gnu-binutils (cross, from PATH);
#   (c) clang --target=x86_64-linux-gnu + llvm-objdump/llvm-addr2line;
#   (d) none -> SKIPPED, exit 0 (translators get correct local feedback).
HOST_ARCH="$(uname -m 2>/dev/null || true)"
CC_X86=()
OBJDUMP_X86=()
ADDR2LINE_X86=()

resolve_x86_toolchain() {
  # Export the resolved disassembler/line-mapper so the embedded analyzer
  # uses the SAME x86_64-capable tools (a host aarch64 addr2line cannot read
  # x86-64 DWARF and would print a bogus file:line).
  unset CC_ISA_X86_ADDR2LINE
  case "$HOST_ARCH" in
    x86_64|amd64|i?86)
      CC_X86=(cc)
      OBJDUMP_X86=(objdump)
      ADDR2LINE_X86=(addr2line)
      export CC_ISA_X86_ADDR2LINE=addr2line
      return 0
      ;;
  esac
  # non-x86_64 host: prefer a GNU cross toolchain
  if command -v x86_64-linux-gnu-gcc >/dev/null 2>&1; then
    CC_X86=(x86_64-linux-gnu-gcc)
    if command -v x86_64-linux-gnu-objdump >/dev/null 2>&1; then
      OBJDUMP_X86=(x86_64-linux-gnu-objdump)
    elif command -v llvm-objdump >/dev/null 2>&1; then
      OBJDUMP_X86=(llvm-objdump)
    fi
    if command -v x86_64-linux-gnu-addr2line >/dev/null 2>&1; then
      ADDR2LINE_X86=(x86_64-linux-gnu-addr2line)
      export CC_ISA_X86_ADDR2LINE=x86_64-linux-gnu-addr2line
    elif command -v llvm-addr2line >/dev/null 2>&1; then
      ADDR2LINE_X86=(llvm-addr2line)
      export CC_ISA_X86_ADDR2LINE=llvm-addr2line
    fi
    return 0
  fi
  # clang cross (clang's integrated assembler accepts AT&T GNU-as syntax)
  if command -v clang >/dev/null 2>&1; then
    CC_X86=(clang --target=x86_64-linux-gnu)
    OBJDUMP_X86=(llvm-objdump)
    ADDR2LINE_X86=(llvm-addr2line)
    export CC_ISA_X86_ADDR2LINE=llvm-addr2line
    return 0
  fi
  return 1
}

# materialize the analyzer once
ANALYZER="$(mktemp "${TMPDIR:-/tmp}/cc-isa-x86-analyzer.XXXXXX.py")"
trap 'rm -f "$ANALYZER"' EXIT HUP INT TERM

cat > "$ANALYZER" <<'PY'
#!/usr/bin/env python3
"""ISA-compliance analyzer, embedded in check-isa-x86_64.sh.

Modes:
  directives <file>              -- scan source for .arch/.cpu/.arch_extension
  disasm <objdump-text-file> <obj> <display> <cap> -- scan disassembly;
                                    addr2line hits; cap in {avx2, avx512}
  probe-blacklist <gas-march> <cap> -- strict blacklist self-check

Exit 1 on any violation, 0 otherwise.
"""
import os
import re
import subprocess
import sys

# ---------------------------------------------------------------------------
# Curated blacklist: AVX-512 / AMX mnemonics (the AVX2 cap forbids all of
# these). Verified on GNU as 2.44 (x86_64) 2026-09: every entry assembles
# under the high arch bundle (see PROBE_OPERANDS). Word-boundary anchored
# so SSE/AVX/AVX2 neighbors (vpcmpeqd, vpcmpgtd, vptest, vpmovsxbd, ...)
# are NOT flagged.
# ---------------------------------------------------------------------------
MNE_AVX512 = (
    # AVX-512 permutations / ternary / moves
    r"vpermb|vpermi2[bwdq]|vpermt2[bwdq]|"
    r"vpternlog[qd]|vmovdqa3[24]|vmovdqa64|"
    # AVX-512 mask (k) register family
    r"kmov[bwdq]|kand[bwdq]|kxor[bwdq]|kor[bwdq]|kadd[bwdq]|"
    r"ktest[bwdq]|kortest[bwdq]|kunpck[bwdq]{2}|kxnor[bwdq]|kshift[lr][bwdq]|"
    # mask <-> vector conversions
    r"vpmovm2[bdwq]|vpmov[bwdq]2m|"
    # compress / expand
    r"vpcompress[bdwq]|vpexpand[bdwq]|"
    # compare / test to mask (vpcmp[bwdq], vpcmpu[bwdq], vptestm*, vptestnm*)
    r"vpcmp[bwdq]|vpcmpu[bwdq]|vptestm[bwdq]|vptestnm[bwdq]|"
    # narrow / signed-saturate / unsigned-saturate down-converts
    r"vpmov(?:d[bwqd]|q[bwd]|w[bq]|usd[bwqd]|usq[bwd]|usw[bq])|"
    # integer dot-product (VNNI), bit-gather
    r"vpdpbusd[s]?|vpdpwssd[s]?|vpshufbitqmb"
)
MNE_AMX = (
    r"tdp[a-z0-9]*|tile[a-z0-9]*|ldtilecfg"
)

def mne_re(part):
    return re.compile(r"\b(?:" + part + r")\b")

MNE_AVX512_RE = mne_re(MNE_AVX512)
MNE_AMX_RE = mne_re(MNE_AMX)

ZMM_RE = re.compile(r"%zmm[0-9]+")     # AVX-512 vector registers
KREG_RE = re.compile(r"%k[0-9]+")      # AVX-512 mask registers
TMM_RE = re.compile(r"%tmm[0-9]+")     # AMX tile registers
EVEX_RE = re.compile(r"\{evex\}")      # EVEX-encoded scalar (e.g. vaddsd)

# Operand templates for the blacklisted mnemonics that require operands
# (bare mnemonics are probed with no operands). Verified on GNU as 2.44
# (x86_64) 2026-09: each assembles under the high arch bundle.
# The {evex} scalar entries are probed with the {evex} pseudo-prefix.
PROBE_OPERANDS = {
    "vpermb": "%zmm0,%zmm1,%zmm2",
    "vpermi2b": "%zmm0,%zmm1,%zmm2",
    "vpermi2w": "%zmm0,%zmm1,%zmm2",
    "vpermi2d": "%zmm0,%zmm1,%zmm2",
    "vpermi2q": "%zmm0,%zmm1,%zmm2",
    "vpermt2b": "%zmm0,%zmm1,%zmm2",
    "vpermt2w": "%zmm0,%zmm1,%zmm2",
    "vpermt2d": "%zmm0,%zmm1,%zmm2",
    "vpermt2q": "%zmm0,%zmm1,%zmm2",
    "vpternlogd": "$0x96,%zmm0,%zmm1,%zmm2",
    "vpternlogq": "$0x96,%zmm0,%zmm1,%zmm2",
    "vmovdqa32": "%zmm0,%zmm1",
    "vmovdqa64": "%zmm0,%zmm1",
    "kmovb": "%k0,%eax",
    "kmovw": "%k0,%eax",
    "kmovd": "%k0,%eax",
    "kmovq": "%k0,%rax",
    "kandb": "%k0,%k1,%k2",
    "kandw": "%k0,%k1,%k2",
    "kandd": "%k0,%k1,%k2",
    "kandq": "%k0,%k1,%k2",
    "kxorb": "%k0,%k1,%k2",
    "kxorw": "%k0,%k1,%k2",
    "kxord": "%k0,%k1,%k2",
    "kxorq": "%k0,%k1,%k2",
    "korb": "%k0,%k1,%k2",
    "korw": "%k0,%k1,%k2",
    "kord": "%k0,%k1,%k2",
    "korq": "%k0,%k1,%k2",
    "kaddb": "%k0,%k1,%k2",
    "kaddw": "%k0,%k1,%k2",
    "kaddd": "%k0,%k1,%k2",
    "kaddq": "%k0,%k1,%k2",
    "ktestb": "%k0,%k1",
    "ktestw": "%k0,%k1",
    "ktestd": "%k0,%k1",
    "ktestq": "%k0,%k1",
    "kortestb": "%k0,%k1",
    "kortestw": "%k0,%k1",
    "kortestd": "%k0,%k1",
    "kortestq": "%k0,%k1",
    "kunpckbw": "%k0,%k1,%k2",
    "kunpckwd": "%k0,%k1,%k2",
    "kunpckdq": "%k0,%k1,%k2",
    "kxnorb": "%k0,%k1,%k2",
    "kxnorw": "%k0,%k1,%k2",
    "kxnord": "%k0,%k1,%k2",
    "kxnorq": "%k0,%k1,%k2",
    "kshiftlb": "$1,%k1,%k2",
    "kshiftlw": "$1,%k1,%k2",
    "kshiftld": "$1,%k1,%k2",
    "kshiftlq": "$1,%k1,%k2",
    "kshiftrb": "$1,%k1,%k2",
    "kshiftrw": "$1,%k1,%k2",
    "kshiftrd": "$1,%k1,%k2",
    "kshiftrq": "$1,%k1,%k2",
    "vpmovm2b": "%k1,%zmm0",
    "vpmovm2w": "%k1,%zmm0",
    "vpmovm2d": "%k1,%zmm0",
    "vpmovm2q": "%k1,%zmm0",
    "vpmovb2m": "%zmm0,%k1",
    "vpmovw2m": "%zmm0,%k1",
    "vpmovd2m": "%zmm0,%k1",
    "vpmovq2m": "%zmm0,%k1",
    "vpcompressb": "%zmm0,%zmm1",
    "vpcompressw": "%zmm0,%zmm1",
    "vpcompressd": "%zmm0,%zmm1",
    "vpcompressq": "%zmm0,%zmm1",
    "vpexpandb": "%zmm0,%zmm1",
    "vpexpandw": "%zmm0,%zmm1",
    "vpexpandd": "%zmm0,%zmm1",
    "vpexpandq": "%zmm0,%zmm1",
    "vpcmpb": "$0,%zmm0,%zmm1,%k1",
    "vpcmpw": "$0,%zmm0,%zmm1,%k1",
    "vpcmpd": "$0,%zmm0,%zmm1,%k1",
    "vpcmpq": "$0,%zmm0,%zmm1,%k1",
    "vpcmpub": "$0,%zmm0,%zmm1,%k1",
    "vpcmpuw": "$0,%zmm0,%zmm1,%k1",
    "vpcmpud": "$0,%zmm0,%zmm1,%k1",
    "vpcmpuq": "$0,%zmm0,%zmm1,%k1",
    "vptestmb": "%zmm0,%zmm1,%k1",
    "vptestmw": "%zmm0,%zmm1,%k1",
    "vptestmd": "%zmm0,%zmm1,%k1",
    "vptestmq": "%zmm0,%zmm1,%k1",
    "vptestnmb": "%zmm0,%zmm1,%k1",
    "vptestnmw": "%zmm0,%zmm1,%k1",
    "vptestnmd": "%zmm0,%zmm1,%k1",
    "vptestnmq": "%zmm0,%zmm1,%k1",
    "vpmovdb": "%zmm0,%xmm1",
    "vpmovdw": "%zmm0,%ymm1",
    "vpmovqb": "%zmm0,%xmm1",
    "vpmovqd": "%zmm0,%ymm1",
    "vpmovqw": "%zmm0,%xmm1",
    "vpmovwb": "%zmm0,%ymm1",
    "vpmovusdb": "%zmm0,%xmm1",
    "vpmovusdw": "%zmm0,%ymm1",
    "vpmovusqb": "%zmm0,%xmm1",
    "vpmovusqd": "%zmm0,%ymm1",
    "vpmovusqw": "%zmm0,%xmm1",
    "vpmovuswb": "%zmm0,%ymm1",
    "vpdpbusd": "%zmm0,%zmm1,%zmm2",
    "vpdpwssd": "%zmm0,%zmm1,%zmm2",
    "vpdpbusds": "%zmm0,%zmm1,%zmm2",
    "vpdpwssds": "%zmm0,%zmm1,%zmm2",
    "vpshufbitqmb": "%zmm0,%zmm1,%k1",
    "tdpbssd": "%tmm0,%tmm1,%tmm2",
    "tileloadd": "(%rax),%tmm0",
    "tileloaddt1": "(%rax),%tmm0",
    "tilestored": "%tmm0,(%rax)",
    "tilezero": "%tmm0",
    "ldtilecfg": "(%rax)",
}
# {evex} scalar probes: "vaddsd"/"vaddss" with the EVEX pseudo-prefix.
EVEX_SCALAR_PROBES = {
    "vaddsd": "{evex} vaddsd %xmm0,%xmm1,%xmm2",
    "vaddss": "{evex} vaddss %xmm0,%xmm1,%xmm2",
    "vmovsd": "{evex} vmovsd %xmm0,%xmm1,%xmm2",
    "vmovss": "{evex} vmovss %xmm0,%xmm1,%xmm2",
}


def scan_directives(path):
    findings = []
    try:
        with open(path, "r", errors="replace") as fh:
            lines = fh.read().split("\n")
    except OSError as exc:
        print(f"{path}: ERROR: cannot read: {exc}")
        return 1
    for lineno, raw in enumerate(lines, 1):
        line = raw.strip()
        if re.match(r"^\.arch\b", line):
            findings.append((lineno, ".arch directive -- forbidden on x86: "
                                     "the floor is the build's -march (x86-64-v4); "
                                     "GNU as has no in-source ISA directive"))
        elif re.match(r"^\.cpu\b", line):
            findings.append((lineno, ".cpu directive -- forbidden on x86: "
                                     "unknown pseudo-op on x86; the floor is the build's -march"))
        elif re.match(r"^\.arch_extension\b", line):
            findings.append((lineno, ".arch_extension directive -- forbidden on x86: "
                                     "unknown pseudo-op on x86; the floor is the build's -march"))
    if findings:
        for lineno, msg in findings:
            print(f"{path}:{lineno}: ERROR: {msg}")
        print(f"{path}: directive scan -- RED")
        return 1
    print(f"{path}: directive scan -- OK (no in-source ISA directive)")
    return 0


def scan_disasm(disasm_path, obj_path, src_display, cap):
    findings = []
    try:
        with open(disasm_path, "r", errors="replace") as fh:
            lines = fh.read().split("\n")
    except OSError as exc:
        print(f"{src_display}: ERROR: cannot read disassembly: {exc}")
        return 1
    for line in lines:
        # objdump x86-64 line shape:
        #   "<addr>:\t<hex bytes>\t<mnemonic> <operands>"
        m = re.match(r"^\s*([0-9a-f]+):\s+[0-9a-f ]+\s+(.*)$", line)
        if not m:
            continue
        addr, insn = m.group(1), m.group(2)
        why = None
        if TMM_RE.search(insn) or MNE_AMX_RE.search(insn):
            why = "AMX instruction/tile register -- above the AVX2 cap"
        elif cap == "avx2":
            if ZMM_RE.search(insn):
                why = "AVX-512 zmm register -- above the AVX2 cap"
            elif KREG_RE.search(insn):
                why = "AVX-512 mask (k) register -- above the AVX2 cap"
            elif EVEX_RE.search(insn):
                why = "EVEX-encoded scalar (AVX-512) -- above the AVX2 cap"
            elif MNE_AVX512_RE.search(insn):
                why = "AVX-512-only mnemonic -- above the AVX2 cap"
        if why:
            loc = f"{src_display}:0"
            addr2line_cmd = os.environ.get("CC_ISA_X86_ADDR2LINE", "addr2line").split()
            try:
                out = subprocess.run(
                    addr2line_cmd + ["-e", obj_path, "0x" + addr],
                    capture_output=True, text=True, check=True).stdout.strip()
                if out and "??" not in out:
                    loc = out
            except (subprocess.CalledProcessError, OSError):
                pass
            findings.append((loc, f"{insn.strip()} -- {why}"))
    if findings:
        for loc, msg in findings:
            print(f"{loc}: ERROR: {msg}")
        print(f"{src_display}: disassembly scan -- RED")
        return 1
    print(f"{src_display}: disassembly scan -- OK (no >{cap} instructions)")
    return 0


def probe_blacklist(gas_march, cap):
    import os
    import subprocess
    import tempfile

    def assembles(body):
        with tempfile.NamedTemporaryFile("w", suffix=".S", delete=False) as fh:
            fh.write(body)
            src = fh.name
        try:
            as_cmd = os.environ.get("CC_ISA_X86_AS", "as").split()
            r = subprocess.run(
                as_cmd + ["--64", "-march=" + gas_march, "-o", "/dev/null", src],
                capture_output=True, text=True)
            return r.returncode == 0
        finally:
            os.unlink(src)

    # probe list: every mnemonic blacklisted under this cap.  avx2 mode
    # blacklists AVX-512 mnemonics AND AMX; avx512 mode blacklists AMX only.
    if cap == "avx2":
        probe_set = list(PROBE_OPERANDS.keys()) + list(EVEX_SCALAR_PROBES.keys())
    else:  # avx512 mode: AMX-only blacklist (the AVX-512 entries are legal)
        probe_set = [m for m in PROBE_OPERANDS
                     if re.fullmatch(r"tdp[a-z0-9]*|tile[a-z0-9]*|ldtilecfg", m)]

    if not assembles(".text\n.global p\np:\n    nop\n    ret\n"):
        print(f"blacklist self-check: SKIPPED -- host assembler does not accept "
              f"-march={gas_march} (non-blocking); use --blacklist-arch to override")
        return 0

    failed = []
    for mnem in probe_set:
        if mnem in EVEX_SCALAR_PROBES:
            insn = "    " + EVEX_SCALAR_PROBES[mnem] + "\n"
            disp = "{evex} " + mnem
        else:
            operands = PROBE_OPERANDS.get(mnem, "")
            insn = "    %s%s\n" % (mnem, " " + operands if operands else "")
            disp = mnem + (f" {operands}" if operands else "")
        if assembles(".text\n.global p\np:\n" + insn + "    ret\n"):
            print(f"blacklist self-check: OK {disp}")
        else:
            failed.append(disp)
    if failed:
        for disp in failed:
            print(f"blacklist self-check: FAIL {disp} -- does not assemble under "
                  f"-march={gas_march}; dead blacklist entry (typo?)")
        print(f"blacklist self-check: RED -- {len(failed)} dead blacklist "
              f"entr{'y' if len(failed) == 1 else 'ies'}")
        return 1
    print(f"blacklist self-check: GREEN -- all {len(probe_set)} probeable "
          f"blacklisted mnemonics assemble under -march={gas_march}")
    return 0


def main(argv):
    if len(argv) >= 3 and argv[1] == "directives":
        return scan_directives(argv[2])
    if len(argv) >= 5 and argv[1] == "disasm":
        return scan_disasm(argv[2], argv[3], argv[4], argv[5])
    if len(argv) >= 4 and argv[1] == "probe-blacklist":
        return probe_blacklist(argv[2], argv[3])
    print(f"usage: {argv[0]} directives <file> | "
          f"disasm <objdump> <obj> <display> <cap> | probe-blacklist <gas-march> <cap>",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
PY

# --- run the checks per module ---
RC=0
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/cc-isa-x86.XXXXXX")"
trap 'rm -rf "$TMPD" "$ANALYZER"' EXIT HUP INT TERM

# --- host-arch guard: if no COMPLETE x86_64 toolchain, SKIP -----------------
if ! resolve_x86_toolchain || [ ${#CC_X86[@]} -eq 0 ] || \
     [ ${#OBJDUMP_X86[@]} -eq 0 ] || [ ${#ADDR2LINE_X86[@]} -eq 0 ]; then
  echo "check-isa-x86_64.sh: SKIPPED (no complete x86_64 assembler on this host)"
  echo "  host arch: ${HOST_ARCH:-unknown}; tried x86_64-linux-gnu-gcc and clang --target=x86_64-linux-gnu"
  echo "  (an incomplete cross toolchain is treated as unavailable: the checker must"
  echo "   be strict in CI/amd64 where a real x86_64 cc exists)"
  rm -rf "$TMPD" "$ANALYZER"
  exit 0
fi

check_module() {
  local f="$1"
  local obj="$TMPD/$(basename "$f").o"
  local dis="$TMPD/$(basename "$f").dis"
  local asm_err="$TMPD/$(basename "$f").err"
  local mod_rc=0

  # 1. directive scan (convention guard)
  python3 "$ANALYZER" directives "$f" || mod_rc=1

  # 2+3. assembly gate (floor proof), then disassembly scan (cap gate)
  if "${CC_X86[@]}" -g -c -x assembler-with-cpp "${EXTRA_INC[@]}" "${INCLUDES[@]}" \
       -march="$FLOOR" -o "$obj" "$f" 2> "$asm_err"; then
    "${OBJDUMP_X86[@]}" -d "$obj" > "$dis"
    python3 "$ANALYZER" disasm "$dis" "$obj" "$f" "$CAP" || mod_rc=1
  else
    if grep -qE "unknown value|invalid -march|unrecognized|does not support|not supported|selected processor" "$asm_err"; then
      # The toolchain rejected the floor -march, or gas rejected an
      # instruction under it: the module does not build at the floor.
      # "A warning is not green" -- fail loud (RED) so an exit-code-gated
      # CI loop keyed on $? cannot pass.
      echo "$f: ERROR: assembler/toolchain rejected the module under the $FLOOR floor -- the module does not build; a warning is not green (RED, fail-loud):"
      sed 's/^/    /' "$asm_err"
      mod_rc=1
    else
      echo "$f: ERROR: could not verify ISA compliance -- assembly failed for a non-ISA reason:"
      sed 's/^/    /' "$asm_err"
      mod_rc=1
    fi
  fi

  if [ "$mod_rc" -eq 0 ]; then
    echo "$f: GREEN (verified $FLOOR floor, $CAP cap)"
  else
    echo "$f: RED"
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

# --- optional blacklist self-check (keeps the curated blacklist honest) ---
if [ "$STRICT_BL" -eq 1 ]; then
  if ! python3 "$ANALYZER" probe-blacklist "$BL_ARCH" "$CAP"; then RC=1; fi
fi

exit "$RC"