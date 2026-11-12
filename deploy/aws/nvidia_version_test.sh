#!/usr/bin/env bash
# nvidia_version_test.sh -- unit tests for the version comparison + nvidia-smi
# CSV parsing helpers in deploy/aws/lib/nvidia.sh.
#
# The driver floor is 620.70.06. `nvidia_driver_ge` compares numeric dot
# components (zero-padded, missing components are 0) and returns:
#   0  installed >= minimum
#   1  installed <  minimum
#   2  malformed input (usage error)
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$script_dir/lib/nvidia.sh"
# shellcheck source=lib/nvidia.sh
source "$lib"

failures=0
check() {
  local desc="$1"
  shift
  if "$@"; then
    printf 'ok: %s\n' "$desc"
  else
    printf 'FAIL: %s\n' "$desc" >&2
    failures=$((failures + 1))
  fi
}

ge()  { nvidia_driver_ge "$1" "$2"; }
lt()  { ! nvidia_driver_ge "$1" "$2"; }
usage_error() {
  local rc
  nvidia_driver_ge "$1" "$2"
  rc=$?
  [[ "$rc" -eq 2 ]]
}
driver_equals()  { [[ "$(nvidia_driver_of_smi "$2")" == "$1" ]]; }
compute_equals() { [[ "$(nvidia_compute_cap_of_smi "$2")" == "$1" ]]; }
fails() { ! "$@" >/dev/null 2>&1; }
pinned_nevra_equals() {
  [[ "$(nvidia__pinned_nevra "$2" 2>/dev/null)" == "$1" ]]
}
arm64_pinned_nevra_warns() {
  local err
  err="$(nvidia__pinned_nevra aarch64 2>&1 >/dev/null)"
  [[ "$err" == *"Gate G2"* ]]
}

# --- numeric comparison ------------------------------------------------------
check "595.112.07 < 610"            lt 595.112.07 610
check "609.99.99 < 610"             lt 609.99.99 610
check "610 == 610"                  ge 610 610
check "610.0.1 >= 610"              ge 610.0.1 610
check "620.70.06 >= 610"            ge 620.70.06 610
check "620.70.06 >= 620.70.06"      ge 620.70.06 620.70.06
check "two-component 609.5 < 610"   lt 609.5 610
check "two-component 610.0 == 610"  ge 610.0 610
check "leading zeros 0610.070.006 >= 610.70.6" ge 0610.070.006 610.70.6
check "leading zeros 0609.099.099 < 610" lt 0609.099.099 610

check "garbage installed -> usage error (rc 2)" usage_error "not-a-version" 610
check "garbage minimum -> usage error (rc 2)"   usage_error 610 "six-ten"
check "empty installed -> usage error (rc 2)"   usage_error "" 610

# --- architecture-specific pinned NEVRA --------------------------------------
check "pinned nevra x86_64 -> amd64 NEVRA" \
  pinned_nevra_equals "$NVIDIA_OPEN_NEVRA" x86_64
check "pinned nevra aarch64 -> arm64 NEVRA" \
  pinned_nevra_equals "$NVIDIA_ARM64_NEVRA" aarch64
check "pinned nevra aarch64 warns about the T4G Gate G2 run" \
  arm64_pinned_nevra_warns
check "pinned nevra unknown machine -> non-zero" \
  fails nvidia__pinned_nevra riscv64

# --- nvidia-smi CSV parsing --------------------------------------------------
check "CSV header + spaces: 'driver_version, 620.70.06' -> 620.70.06" \
  driver_equals 620.70.06 "driver_version, 620.70.06"
check "padded CSV value: '  620.70.06  ' -> 620.70.06" \
  driver_equals 620.70.06 "  620.70.06  "
check "multi-line CSV header + value -> 620.70.06" \
  driver_equals 620.70.06 "$(printf 'driver_version\n620.70.06')"
check "N/A driver -> non-zero" fails nvidia_driver_of_smi "[N/A]"
check "CSV compute_cap with spaces -> 7.5" \
  compute_equals 7.5 "compute_cap, 7.5"
check "N/A compute_cap -> non-zero" fails nvidia_compute_cap_of_smi "[N/A]"

if [[ "$failures" -ne 0 ]]; then
  printf '\n%d failure(s)\n' "$failures" >&2
  exit 1
fi
printf '\nall version tests passed\n'
