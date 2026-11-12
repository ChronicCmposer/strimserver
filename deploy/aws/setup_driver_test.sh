#!/usr/bin/env bash
# setup_driver_test.sh -- behavioural tests for nvidia_ensure_driver_floor.
#
# Every case runs the function against testutil_fake_gpu.sh with
# NVIDIA_STAGE_DIR / NVIDIA_FIRMWARE_ROOT / NVIDIA_RESUME_MARKER /
# NVIDIA_PROC_VERSION_FILE / NVIDIA_DEVICE_NODE redirected into a temp dir and
# SUDO=fake-sudo. The recorded call log is then asserted for ordering and for
# the exact flags each dnf/systemctl/modprobe invocation uses.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/nvidia.sh
source "$script_dir/lib/nvidia.sh"
# shellcheck source=testutil_fake_gpu.sh
source "$script_dir/testutil_fake_gpu.sh"

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

case_tmp=""
case_path=""
begin_case() {
  # A knob that survived the previous case would make it pass or fail for the
  # wrong reason; the internal shim paths are the only allowed carry-overs.
  local leaked="" v
  for v in $(compgen -v FAKE_ 2>/dev/null); do
    case "$v" in
      FAKE_REAL_*|FAKE_GPU_*|FAKE_DNF_ARGV|FAKE_PROC_FILE) continue ;;
    esac
    leaked+=" $v"
  done
  if [[ -n "$leaked" ]]; then
    printf 'FAIL: leaked FAKE_* knobs from a previous case:%s\n' "$leaked" >&2
    failures=$((failures + 1))
  fi
  case_tmp="$(mktemp -d)"
  case_path="$PATH"
  command mkdir -p "$case_tmp/fw/nvidia/620.70.06"
  : >"$case_tmp/fw/nvidia/620.70.06/gsp_tu10x.bin"
  export NVIDIA_STAGE_DIR="$case_tmp/stage"
  export NVIDIA_FIRMWARE_ROOT="$case_tmp/fw"
  export NVIDIA_RESUME_MARKER="$case_tmp/driver-upgrade.state"
  export NVIDIA_PROC_VERSION_FILE="$case_tmp/proc-version"
  export NVIDIA_DEVICE_NODE="$case_tmp/nvidia0"
  export NVIDIA_DKMS_SRC_ROOT="$case_tmp/usr-src"
  export SUDO=fake-sudo
}

end_case() {
  fake_gpu_cleanup
  PATH="$case_path"
  command rm -rf "$case_tmp"
  unset NVIDIA_STAGE_DIR NVIDIA_FIRMWARE_ROOT NVIDIA_RESUME_MARKER \
    NVIDIA_PROC_VERSION_FILE NVIDIA_DEVICE_NODE NVIDIA_DKMS_SRC_ROOT SUDO \
    NVIDIA_DRAIN_TIMEOUT NVIDIA_VERSIONLOCK_FILE NVIDIA_STAGE_ONLY \
    FAKE_REPORTED_DRIVER FAKE_PROC_VERSION FAKE_PROC_VERSION_STUCK FAKE_RPM_INSTALLED \
    FAKE_RUN_MANAGED FAKE_UNINSTALL_RC FAKE_RMMOD_BUSY FAKE_DNF_RC \
    FAKE_DNF_DOWNLOADONLY_RC FAKE_DNF_CLOSURE_INCOMPLETE FAKE_DNF_KEY_MISSING \
    FAKE_DNF_UPGRADES_DRIVER FAKE_DNF_DKMS_INSTALL_REGISTERS \
    FAKE_PKG_AVAILABLE FAKE_SMI_RC FAKE_SMI_MISSING \
    FAKE_MODPROBE_RC FAKE_MODULE_LOADED FAKE_MODULES FAKE_STRIMSERVER_ACTIVE \
    FAKE_FABRICMANAGER_UNIT FAKE_FABRICMANAGER_ACTIVE FAKE_FABRICMANAGER_FRAGMENT \
    FAKE_FABRICMANAGER_WAS_ACTIVE FAKE_FABRICMANAGER_START_RC \
    FAKE_PERSISTENCED_UNIT FAKE_PERSISTENCED_ACTIVE FAKE_PERSISTENCED_FRAGMENT \
    FAKE_PERSISTENCED_WAS_ACTIVE FAKE_PERSISTENCED_START_RC \
    FAKE_UNIT_OWNER_FABRICMANAGER FAKE_UNIT_OWNER_PERSISTENCED \
    FAKE_REPOQUERY_FABRICMANAGER FAKE_REPOQUERY_PERSISTENCED FAKE_REPOQUERY_RC \
    FAKE_DCGM_UNIT FAKE_DCGM_EXPORTER_UNIT FAKE_DCGM_ACTIVE \
    FAKE_DCGM_EXPORTER_ACTIVE FAKE_DCGM_STUCK FAKE_DCGM_EXPORTER_STUCK \
    FAKE_ARCH FAKE_KERNEL_RELEASE FAKE_NEVRA FAKE_HOLDER FAKE_KERNEL_MODULE_VARIANT \
    FAKE_DKMS_STATUS FAKE_DKMS_RC FAKE_DKMS_STATUS_RC FAKE_DKMS_REMOVE_RC \
    FAKE_DKMS_RPM FAKE_DKMS_PAYLOAD FAKE_DKMS_CONF_MISSING FAKE_DKMS_TOOL_MISSING \
    FAKE_DKMS_BUILD_RC FAKE_STAGE_INCLUDE_DKMS FAKE_STAGE_INCLUDE_BUILD_PREREQS \
    FAKE_KERNEL_HEADERS_MISSING FAKE_KERNEL_DEVEL_MISSING \
    FAKE_PAYLOAD_MISSING_MODULE FAKE_MODINFO_MISSING \
    FAKE_DNF_EMPTY FAKE_OPTIONAL_DOWNLOAD_RC FAKE_DNF_DOWNLOADONLY_CHMOD \
    FAKE_CHMOD_RC FAKE_RPM_UNREADABLE \
    FAKE_VERSIONLOCK_CP_RC FAKE_VERSIONLOCK_TEE_RC FAKE_DNF_STAGE_STDERR
}

# First recorded line matching the ERE, or empty.
call_index() { fake_gpu_first_index "$1"; }
before() {
  local first second
  first="$(call_index "$1")"
  second="$(call_index "$2")"
  [[ -n "$first" && -n "$second" && "$first" -lt "$second" ]]
}
has_call() { grep -Eq "$1" "$FAKE_GPU_CALLS"; }
no_call() { ! grep -Eq "$1" "$FAKE_GPU_CALLS"; }
marker_present() { [[ -e "$NVIDIA_RESUME_MARKER" ]]; }
procs_620() { grep -q '620\.70\.06' "$NVIDIA_PROC_VERSION_FILE"; }

# Helper set shared with the Phase 3-5 cases (owned by the next wave).
count_calls() { grep -Ec "$1" "$FAKE_GPU_CALLS" 2>/dev/null || true; }
after() {
  local first second
  first="$(call_index "$1")"
  second="$(call_index "$2")"
  [[ -n "$first" && -n "$second" && "$first" -gt "$second" ]]
}
# Stage helpers inspect the recorded `dnf install ... --downloadonly` call, not
# the cumulative argv file (which mixes every dnf invocation).
stage_has_package() {
  grep -E '^dnf install .*--downloadonly' "$FAKE_GPU_CALLS" | grep -Fq -- "$1"
}
stage_omits_package() { ! stage_has_package "$1"; }
# The first recorded `dnf install ... --downloadonly` call line.
stage_line() { grep -E '^dnf install .*--downloadonly' "$FAKE_GPU_CALLS" | head -n1; }
state_flag() { [[ "$(cat "$FAKE_GPU_STATE/$1" 2>/dev/null)" == "1" ]]; }
stdout_has() { grep -Eq "$2" <<<"$1"; }
stderr_has() { grep -Eq "$2" <<<"$1"; }
unit_started() {
  grep -Eq "systemctl start .*${1%%.service}(\\.service)?\$" "$FAKE_GPU_CALLS"
}
unit_not_started() { ! unit_started "$1"; }

# --- stage-directory access helpers (Phase 2 staging-permissions contract) ---
fn_exists() { declare -F "$1" >/dev/null 2>&1; }
# Mode (no leading zero-pad surprises) of the final stage leaf.
stage_dir_mode() { stat -c '%a' "$NVIDIA_STAGE_DIR" 2>/dev/null; }
# Mode of the stage leaf's parent (the component a root-owned mktemp under
# umask 077 can leave root-only).
stage_parent_mode() { stat -c '%a' "$(dirname "$NVIDIA_STAGE_DIR")" 2>/dev/null; }
# True when the invoking user can read AND traverse the directory.
stage_dir_accessible() {
  local dir="${1:-$NVIDIA_STAGE_DIR}"
  [[ -d "$dir" && -r "$dir" && -x "$dir" ]]
}
# True when a required nvidia-open RPM is visible through the glob.
stage_has_visible_rpm() {
  local dir="${1:-$NVIDIA_STAGE_DIR}"
  compgen -G "$dir/nvidia-open-*.rpm" >/dev/null
}
# Print every ${NVIDIA_STAGE_DIR}.tmp.* leftover, one per line (empty when none).
stage_temp_dirs() {
  local -a dirs=()
  local had_nullglob=0
  shopt -q nullglob || had_nullglob=1
  shopt -s nullglob
  dirs=("${NVIDIA_STAGE_DIR}.tmp."*)
  (( had_nullglob == 1 )) && shopt -u nullglob
  (( ${#dirs[@]} > 0 )) && printf '%s\n' "${dirs[@]}"
  return 0
}
# Count staged RPMs with a nullglob array (never a pipeline under pipefail).
stage_rpm_count() {
  local -a files=()
  local had_nullglob=0
  shopt -q nullglob || had_nullglob=1
  shopt -s nullglob
  files=("$NVIDIA_STAGE_DIR"/*.rpm)
  (( had_nullglob == 1 )) && shopt -u nullglob
  printf '%s\n' "${#files[@]}"
}
# Run a probe as an unprivileged user: directly when non-root, else via setpriv
# or runuser. Returns 77 (and says so) when root has neither tool.
as_unprivileged() {
  if [[ "$(id -u)" -eq 0 ]]; then
    if command -v setpriv >/dev/null 2>&1; then
      setpriv --reuid=nobody --regid=nogroup --clear-groups "$@"
    elif command -v runuser >/dev/null 2>&1; then
      runuser -u nobody -- "$@"
    else
      printf 'SKIP (root, no setpriv)\n' >&2
      return 77
    fi
  else
    "$@"
  fi
}
# A chmod 000/0000 directory is not useful coverage under root when no facility
# exists to drop privileges; skip only in that case.
unreadable_probe_supported() {
  [[ "$(id -u)" -ne 0 ]] || command -v setpriv >/dev/null 2>&1 \
    || command -v runuser >/dev/null 2>&1
}

# --- 1. upgrade path (RPM installed, below floor) ----------------------------
case_upgrade() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_PERSISTENCED_UNIT=1 FAKE_PERSISTENCED_ACTIVE=1
  fake_gpu_install
  nvidia_ensure_driver_floor >/dev/null 2>&1; local rc=$?

  check "upgrade: exits 0" test "$rc" -eq 0
  check "upgrade: stages the pinned closure (install --downloadonly)" has_call '^dnf install .*--downloadonly'
  check "upgrade: installs the staged RPMs offline" has_call '^dnf install .*--allowerasing'
  check "upgrade: runs depmod -a" has_call 'depmod -a'
  check "upgrade: stops strimserver.service" has_call 'systemctl stop strimserver.service'
  check "upgrade: stops nvidia-persistenced" has_call 'systemctl stop nvidia-persistenced'
  check "upgrade: stops containerd.service" has_call 'systemctl stop containerd.service'
  check "upgrade: drains before unloading modules" before 'systemctl stop strimserver.service' 'modprobe -r nvidia$'
  check "upgrade: stages before installing" before '^dnf install .*--downloadonly' '^dnf install .*--allowerasing'
  check "upgrade: drains before installing" before 'systemctl stop strimserver.service' '^dnf install .*--allowerasing'
  check "upgrade: stops containerd before installing" before 'systemctl stop containerd.service' '^dnf install .*--allowerasing'
  check "upgrade: holder check runs before installing" before 'fuser -v /dev/nvidia' '^dnf install .*--allowerasing'
  check "upgrade: selects the amd64 NEVRA" has_call 'dnf install .*nvidia-open-3:620\.70\.06-1\.el9'
  check "upgrade: does not select the arm64 NEVRA" no_call 'nvidia-open-620.70.06-1.amzn2023.noarch'
  check "upgrade: depmod before unload" before 'depmod -a' 'modprobe -r nvidia$'
  check "upgrade: unload before load" before 'modprobe -r nvidia$' 'modprobe nvidia$'
  check "upgrade: restores nvidia-persistenced" has_call 'systemctl start nvidia-persistenced'
  check "upgrade: never restarts containerd itself" no_call 'systemctl restart containerd'
  check "upgrade: never runs reboot" bash -c '! grep -qi reboot "$1"' _ "$FAKE_GPU_CALLS"
  check "upgrade: verification reads the 620 proc version" procs_620
  end_case
}

# --- 2. no-op at the floor ---------------------------------------------------
case_noop() {
  begin_case
  export FAKE_REPORTED_DRIVER=620.70.06 FAKE_RPM_INSTALLED=1
  fake_gpu_install
  nvidia_ensure_driver_floor >/dev/null 2>&1; local rc=$?

  check "no-op: exits 0" test "$rc" -eq 0
  check "no-op: performs no stage" no_call '^dnf install .*--downloadonly'
  check "no-op: performs no unload" no_call 'modprobe -r'
  end_case
}

# --- 3. newer driver is never downgraded ------------------------------------
case_newer() {
  begin_case
  export FAKE_REPORTED_DRIVER=630.1.0 FAKE_RPM_INSTALLED=1
  fake_gpu_install
  nvidia_ensure_driver_floor >/dev/null 2>&1; local rc=$?

  check "newer: exits 0" test "$rc" -eq 0
  check "newer: performs no stage" no_call '^dnf install .*--downloadonly'
  check "newer: performs no install" no_call '^dnf install .*--allowerasing'
  end_case
}

# --- 4. package missing: stage fails before anything destructive ------------
case_package_missing() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_PKG_AVAILABLE=0
  fake_gpu_install
  out="$(nvidia_ensure_driver_floor 2>&1)"; local rc=$?

  check "package missing: fails" test "$rc" -ne 0
  check "package missing: message names the stage failure" bash -c 'grep -qi "closure\|download\|stage" <<<"$1"' _ "$out"
  check "package missing: no uninstall attempted" no_call 'nvidia-uninstall'
  check "package missing: no unload attempted" no_call 'modprobe -r'
  check "package missing: no marker left behind" bash -c '[[ ! -e "$1" ]]' _ "$NVIDIA_RESUME_MARKER"
  end_case
}

# --- 5. .run-managed host, uninstall fails ----------------------------------
case_uninstall_failure() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=0 FAKE_RUN_MANAGED=1 FAKE_UNINSTALL_RC=1
  fake_gpu_install
  out="$(nvidia_ensure_driver_floor 2>&1)"; local rc=$?

  check "uninstall failure: fails" test "$rc" -ne 0
  check "uninstall failure: message names uninstall" bash -c 'grep -qi "uninstall" <<<"$1"' _ "$out"
  check "uninstall failure: stage precedes uninstall" before '^dnf install .*--downloadonly' 'nvidia-uninstall'
  check "uninstall failure: no offline install after the failure" no_call '^dnf install .*--allowerasing'
  check "uninstall failure: resume marker left in place" marker_present
  end_case
}

# --- 6. rmmod busy (holder still present) -----------------------------------
case_rmmod_busy() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_RMMOD_BUSY=1
  fake_gpu_install
  out="$(nvidia_ensure_driver_floor 2>&1)"; local rc=$?

  check "rmmod busy: fails" test "$rc" -ne 0
  check "rmmod busy: message names unload/in-use" bash -c 'grep -Eqi "rmmod|in use|unload" <<<"$1"' _ "$out"
  check "rmmod busy: never loads the new module" no_call 'modprobe nvidia$'
  end_case
}

# --- 7. install did not actually raise the version --------------------------
case_still_below_floor() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_DNF_UPGRADES_DRIVER=0
  fake_gpu_install
  out="$(nvidia_ensure_driver_floor 2>&1)"; local rc=$?

  check "still-below-floor: fails" test "$rc" -ne 0
  check "still-below-floor: message names the floor" bash -c 'grep -qi "still\|below\|floor" <<<"$1"' _ "$out"
  end_case
}

# --- 8. nvidia-smi binary absent: GPU init cannot be confirmed --------------
# New contract: after the swap the GPU must initialize (nvidia-smi + device
# node). Without nvidia-smi the verification must fail, never report success.
case_no_smi_binary() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_SMI_MISSING=1
  fake_gpu_install
  out="$(nvidia_ensure_driver_floor 2>&1)"; local rc=$?

  check "no nvidia-smi: verification fails" test "$rc" -ne 0
  check "no nvidia-smi: still staged the closure" has_call '^dnf install .*--downloadonly'
  check "no nvidia-smi: message names verify/GPU init" bash -c 'grep -qi "verify\|nvidia-smi\|initial" <<<"$1"' _ "$out"
  end_case
}

# --- 9. nvidia-smi present but non-zero: GPU init fails verification --------
case_smi_nonzero() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_SMI_RC=1
  fake_gpu_install
  out="$(nvidia_ensure_driver_floor 2>&1)"; local rc=$?

  check "nvidia-smi rc!=0: verification fails" test "$rc" -ne 0
  check "nvidia-smi rc!=0: staged the closure" has_call '^dnf install .*--downloadonly'
  check "nvidia-smi rc!=0: message names verify/GPU init" bash -c 'grep -qi "verify\|nvidia-smi\|initial" <<<"$1"' _ "$out"
  end_case
}

# --- 10. .run-managed host upgrades successfully -----------------------------
case_run_managed_upgrade() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=0 FAKE_RUN_MANAGED=1
  export FAKE_NEVRA="nvidia-open-3:620.70.06-1.el9.x86_64"
  export FAKE_PERSISTENCED_UNIT=1 FAKE_PERSISTENCED_ACTIVE=1
  fake_gpu_install
  nvidia_ensure_driver_floor >/dev/null 2>&1; local rc=$?

  check "run-managed: exits 0" test "$rc" -eq 0
  check "run-managed: drains before uninstall" before 'systemctl stop strimserver.service' 'nvidia-uninstall'
  check "run-managed: stops containerd before uninstall" before 'systemctl stop containerd.service' 'nvidia-uninstall'
  check "run-managed: holder check before uninstall" before 'fuser -v /dev/nvidia' 'nvidia-uninstall'
  check "run-managed: drains before installing" before 'systemctl stop strimserver.service' '^dnf install .*--allowerasing'
  check "run-managed: uninstall before installing" before 'nvidia-uninstall' '^dnf install .*--allowerasing'
  end_case
}

# --- 11. arm64 host selects the arm64 NEVRA ---------------------------------
case_arm64_nevra() {
  begin_case
  export FAKE_ARCH=aarch64 FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_NEVRA="nvidia-open-620.70.06-1.amzn2023.noarch"
  fake_gpu_install
  nvidia_ensure_driver_floor >/dev/null 2>&1; local rc=$?

  check "arm64: exits 0" test "$rc" -eq 0
  check "arm64: selects the arm64 NEVRA" has_call 'dnf install .*nvidia-open-620\.70\.06-1\.amzn2023\.noarch'
  check "arm64: does not select the amd64 NEVRA" no_call 'nvidia-open-3:620.70.06-1.el9'
  end_case
}

# ===========================================================================
# Phase 3 -- DCGM drain
# ===========================================================================
case_dcgm_holder() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=0 FAKE_RUN_MANAGED=1
  export FAKE_NEVRA="nvidia-open-3:620.70.06-1.el9.x86_64"
  export FAKE_DCGM_UNIT=1 FAKE_DCGM_EXPORTER_UNIT=1
  export FAKE_DCGM_ACTIVE=1 FAKE_DCGM_EXPORTER_ACTIVE=1
  export FAKE_PERSISTENCED_UNIT=1 FAKE_PERSISTENCED_ACTIVE=1
  fake_gpu_install
  nvidia_ensure_driver_floor >/dev/null 2>&1; local rc=$?

  check "dcgm: exits 0" test "$rc" -eq 0
  check "dcgm: stops the exporter" has_call 'systemctl stop nvidia-dcgm-exporter.service'
  check "dcgm: stops nvidia-dcgm" has_call 'systemctl stop nvidia-dcgm.service'
  check "dcgm: exporter stop precedes dcgm stop" \
    before 'systemctl stop nvidia-dcgm-exporter.service' 'systemctl stop nvidia-dcgm.service'
  check "dcgm: both stops precede fuser" \
    before 'systemctl stop nvidia-dcgm.service' 'fuser -v /dev/nvidia'
  check "dcgm: both stops precede nvidia-uninstall" \
    before 'systemctl stop nvidia-dcgm-exporter.service' 'nvidia-uninstall'
  check "dcgm: both stops precede offline install" \
    before 'systemctl stop nvidia-dcgm.service' '^dnf install .*--allowerasing'
  check "dcgm: both stops precede module unload" \
    before 'systemctl stop nvidia-dcgm.service' 'modprobe -r nvidia$'
  check "dcgm: exporter left inactive" \
    bash -c '[[ "$(cat "$1/dcgm_exporter_active")" == 0 ]]' _ "$FAKE_GPU_STATE"
  check "dcgm: nvidia-dcgm left inactive" \
    bash -c '[[ "$(cat "$1/dcgm_active")" == 0 ]]' _ "$FAKE_GPU_STATE"
  check "dcgm: restore never starts the exporter" no_call 'systemctl start nvidia-dcgm-exporter'
  check "dcgm: restore never starts nvidia-dcgm" no_call 'systemctl start nvidia-dcgm'
  end_case
}

# ===========================================================================
# Phase 4 -- repo provisioning, closure staging, offline install
# ===========================================================================
case_repo_ready() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  fake_gpu_install
  nvidia_ensure_driver_floor >/dev/null 2>&1; local rc=$?

  check "repo: exits 0" test "$rc" -eq 0
  check "repo: adds the amd64 CUDA repo" has_call 'dnf config-manager --add-repo .*rhel9/x86_64/cuda-rhel9'
  check "repo: imports the CUDA signing key" has_call 'rpm --import .*D42D0685'
  check "repo: repo configured before staging" \
    before 'dnf config-manager --add-repo' '^dnf install .*--downloadonly'
  check "repo: key imported before staging" \
    before 'rpm --import' '^dnf install .*--downloadonly'
  end_case
}

case_repo_arm64() {
  begin_case
  export FAKE_ARCH=aarch64 FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_NEVRA="nvidia-open-620.70.06-1.amzn2023.noarch"
  fake_gpu_install
  nvidia_ensure_driver_floor >/dev/null 2>&1; local rc=$?

  check "repo arm64: exits 0" test "$rc" -eq 0
  check "repo arm64: adds the amzn2023/sbsa CUDA repo" \
    has_call 'dnf config-manager --add-repo .*amzn2023/sbsa/cuda-amzn2023'
  check "repo arm64: imports the sbsa signing key" has_call 'rpm --import .*amzn2023/sbsa/D42D0685'
  check "repo arm64: repo configured before staging" \
    before 'dnf config-manager --add-repo' '^dnf install .*--downloadonly'
  end_case
}

case_repo_missing_key() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=0 FAKE_RUN_MANAGED=1
  export FAKE_DNF_KEY_MISSING=1
  fake_gpu_install
  out="$(nvidia_ensure_driver_floor 2>&1)"; local rc=$?

  check "missing key: fails" test "$rc" -ne 0
  check "missing key: message names repo/key" bash -c 'grep -qi "repo\|key" <<<"$1"' _ "$out"
  check "missing key: no stage attempted" no_call '^dnf install .*--downloadonly'
  check "missing key: no uninstall attempted" no_call 'nvidia-uninstall'
  check "missing key: no marker left behind" bash -c '[[ ! -e "$1" ]]' _ "$NVIDIA_RESUME_MARKER"
  end_case
}

case_closure_stage() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  fake_gpu_install
  nvidia_ensure_driver_floor >/dev/null 2>&1; local rc=$?

  check "stage: exits 0" test "$rc" -eq 0
  check "stage: uses install --downloadonly" has_call '^dnf install .*--downloadonly'
  check "stage: uses --disableexcludes=all" has_call '^dnf install .*--downloadonly.*--disableexcludes=all'
  check "stage: uses --destdir" has_call '^dnf install .*--downloadonly.*--destdir'
  check "stage: never uses the legacy dnf download verb" no_call '^dnf download'
  check "stage: leaves the full closure in place" \
    bash -c 'compgen -G "$1/nvidia-driver-cuda-*.rpm" >/dev/null' _ "$NVIDIA_STAGE_DIR"
  end_case
}

case_closure_incomplete() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_DNF_CLOSURE_INCOMPLETE=1
  fake_gpu_install
  out="$(nvidia_ensure_driver_floor 2>&1)"; local rc=$?

  check "incomplete closure: fails" test "$rc" -ne 0
  check "incomplete closure: message names closure" bash -c 'grep -qi "closure" <<<"$1"' _ "$out"
  check "incomplete closure: no uninstall attempted" no_call 'nvidia-uninstall'
  check "incomplete closure: no offline install attempted" no_call '^dnf install .*--allowerasing'
  check "incomplete closure: no marker left behind" bash -c '[[ ! -e "$1" ]]' _ "$NVIDIA_RESUME_MARKER"
  end_case
}

case_offline_install() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  fake_gpu_install
  nvidia_ensure_driver_floor >/dev/null 2>&1; local rc=$?

  check "offline: exits 0" test "$rc" -eq 0
  check "offline: uses --allowerasing" has_call '^dnf install .*--allowerasing'
  check "offline: uses --disableexcludes=all" has_call '^dnf install .*--allowerasing.*--disableexcludes=all'
  check "offline: uses --disablerepo=*" has_call '^dnf install .*--disablerepo=\*'
  check "offline: installs staged RPM file paths" \
    bash -c 'grep -Eq "^dnf install .*--allowerasing.*stage.*\.rpm" "$1"' _ "$FAKE_GPU_CALLS"
  end_case
}

case_stage_before_swap() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=0 FAKE_RUN_MANAGED=1
  export FAKE_NEVRA="nvidia-open-3:620.70.06-1.el9.x86_64"
  fake_gpu_install
  nvidia_ensure_driver_floor >/dev/null 2>&1; local rc=$?

  check "stage-before-swap: exits 0" test "$rc" -eq 0
  check "stage-before-swap: closure staged before uninstall" \
    before '^dnf install .*--downloadonly' 'nvidia-uninstall'
  check "stage-before-swap: closure staged before offline install" \
    before '^dnf install .*--downloadonly' '^dnf install .*--allowerasing'
  end_case
}

case_arm64_closure() {
  begin_case
  export FAKE_ARCH=aarch64 FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_NEVRA="nvidia-open-620.70.06-1.amzn2023.noarch"
  fake_gpu_install
  nvidia_ensure_driver_floor >/dev/null 2>&1; local rc=$?

  check "arm64 closure: exits 0" test "$rc" -eq 0
  check "arm64 closure: stages the arm64 NEVRA" has_call 'dnf install .*nvidia-open-620\.70\.06-1\.amzn2023\.noarch'
  check "arm64 closure: does not stage the amd64 kmod" no_call 'el9\.x86_64\.rpm'
  check "arm64 closure: keeps the arm64 dkms RPM" \
    bash -c 'compgen -G "$1/kmod-nvidia-open-dkms-*.rpm" >/dev/null' _ "$NVIDIA_STAGE_DIR"
  end_case
}

# ===========================================================================
# Phase 5 -- proc reader, kmod-vs-DKMS, module reload, GPU init
# ===========================================================================
case_loaded_version_mismatch() {
  begin_case
  export FAKE_REPORTED_DRIVER=620.70.06 FAKE_PROC_VERSION=595.112.07 FAKE_RPM_INSTALLED=1
  fake_gpu_install
  nvidia_ensure_driver_floor >/dev/null 2>&1; local rc=$?

  check "loaded mismatch: exits 0" test "$rc" -eq 0
  check "loaded mismatch: proc updated to 620 after reload" procs_620
  end_case
}

case_verify_uses_proc() {
  begin_case
  export FAKE_REPORTED_DRIVER=620.70.06 FAKE_PROC_VERSION=595.112.07
  export FAKE_PROC_VERSION_STUCK=1 FAKE_SMI_RC=1 FAKE_RPM_INSTALLED=1
  fake_gpu_install
  out="$(nvidia_ensure_driver_floor 2>&1)"; local rc=$?

  check "verify-uses-proc: fails when proc stays below the floor" test "$rc" -ne 0
  check "verify-uses-proc: message names verify/below" bash -c 'grep -Eqi "verify|below|proc" <<<"$1"' _ "$out"
  check "verify-uses-proc: never prints a success line" \
    bash -c '! grep -qi "at or above the .* floor" <<<"$1"' _ "$out"
  end_case
}

case_disk_620_proc_absent() {
  begin_case
  export FAKE_REPORTED_DRIVER=620.70.06 FAKE_PROC_VERSION="" FAKE_SMI_RC=1
  export FAKE_MODPROBE_RC=1 FAKE_RPM_INSTALLED=1
  fake_gpu_install
  out="$(nvidia_ensure_driver_floor 2>&1)"; local rc=$?

  check "disk-620/proc-absent: fails (no silent no-op)" test "$rc" -ne 0
  check "disk-620/proc-absent: runs depmod" has_call 'depmod -a'
  check "disk-620/proc-absent: attempts to load the module" has_call 'modprobe nvidia$'
  check "disk-620/proc-absent: message names verify/load" bash -c 'grep -Eqi "verify|load" <<<"$1"' _ "$out"
  check "disk-620/proc-absent: does not take the no-op shortcut" \
    bash -c '! grep -qi "nothing to do" <<<"$1"' _ "$out"
  end_case
}

case_full_rmmod() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_MODULES="nvidia_uvm nvidia_fs gdrdrv efa_nv_peermem nvidia_drm nvidia_modeset nvidia"
  fake_gpu_install
  nvidia_ensure_driver_floor >/dev/null 2>&1; local rc=$?

  check "full rmmod: exits 0" test "$rc" -eq 0
  check "full rmmod: unloads nvidia_uvm first" before 'modprobe -r nvidia_uvm$' 'modprobe -r nvidia$'
  check "full rmmod: unloads nvidia_drm before nvidia_modeset" \
    before 'modprobe -r nvidia_drm$' 'modprobe -r nvidia_modeset$'
  check "full rmmod: unloads nvidia_modeset before nvidia" \
    before 'modprobe -r nvidia_modeset$' 'modprobe -r nvidia$'
  check "full rmmod: unloads optional nvidia_fs" has_call 'modprobe -r nvidia_fs$'
  check "full rmmod: unloads optional gdrdrv" has_call 'modprobe -r gdrdrv$'
  check "full rmmod: unloads optional efa_nv_peermem" has_call 'modprobe -r efa_nv_peermem$'
  check "full rmmod: every unload precedes load" \
    bash -c 'a=$(awk "/^modprobe nvidia\$/{print NR; exit}" "$1"); b=$(awk "/^modprobe -r /{print NR; exit}" "$1"); [[ -n "$a" && -n "$b" && "$b" -lt "$a" ]]' _ "$FAKE_GPU_CALLS"
  check "full rmmod: no stale module remains" \
    bash -c '! grep -qE "^(nvidia_drm|nvidia_modeset|nvidia_fs|gdrdrv|efa_nv_peermem)$" "$1/modules"' _ "$FAKE_GPU_STATE"
  check "full rmmod: reloads nvidia_uvm" has_call 'modprobe nvidia_uvm$'
  end_case
}

case_dkms_cleanup() {
  begin_case
  export FAKE_REPORTED_DRIVER=595.112.07 FAKE_PROC_VERSION=595.112.07
  export FAKE_RPM_INSTALLED=1 FAKE_KERNEL_MODULE_VARIANT=dkms
  export FAKE_DKMS_STATUS="nvidia-open/595.112.07, 5.10.240, x86_64: installed"
  fake_gpu_install
  nvidia_ensure_driver_floor >/dev/null 2>&1; local rc=$?

  check "dkms cleanup: exits 0" test "$rc" -eq 0
  check "dkms cleanup: removes the stale 595 build" has_call 'dkms remove nvidia-open/595\.112\.07 --all'
  check "dkms cleanup: never removes the 620 build" no_call 'dkms remove nvidia-open/620'
  check "dkms cleanup: runs after the RPM install" before '^dnf install .*--allowerasing' 'dkms remove nvidia-open/595'
  check "dkms cleanup: runs before depmod" before 'dkms remove nvidia-open/595' 'depmod -a'
  check "dkms cleanup: runs before module unload" before 'dkms remove nvidia-open/595' 'modprobe -r nvidia$'
  end_case
}

case_kmod_vs_dkms() {
  begin_case
  export FAKE_REPORTED_DRIVER=595.112.07 FAKE_PROC_VERSION=595.112.07
  export FAKE_RPM_INSTALLED=1 FAKE_KERNEL_MODULE_VARIANT=kmod
  fake_gpu_install
  nvidia_ensure_driver_floor >/dev/null 2>&1; local rc=$?

  check "kmod host: exits 0" test "$rc" -eq 0
  check "kmod host: never invokes dkms" no_call '^dkms '
  end_case
}

case_modprobe_uvm() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  fake_gpu_install
  nvidia_ensure_driver_floor >/dev/null 2>&1; local rc=$?

  check "modprobe uvm: exits 0" test "$rc" -eq 0
  check "modprobe uvm: loads nvidia_uvm" has_call 'modprobe nvidia_uvm$'
  check "modprobe uvm: loads nvidia_uvm after nvidia" \
    before 'modprobe nvidia$' 'modprobe nvidia_uvm$'
  end_case
}

case_gpu_init() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_SMI_RC=1
  fake_gpu_install
  out="$(nvidia_ensure_driver_floor 2>&1)"; local rc=$?

  check "gpu init: fails when nvidia-smi fails" test "$rc" -ne 0
  check "gpu init: message names verify/GPU init" bash -c 'grep -Eqi "verify|nvidia-smi|initial" <<<"$1"' _ "$out"
  check "gpu init: never prints a success line" \
    bash -c '! grep -qi "at or above the .* floor" <<<"$1"' _ "$out"
  end_case
}

case_resume_marker() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  : >"$NVIDIA_RESUME_MARKER"
  fake_gpu_install
  nvidia_ensure_driver_floor >/dev/null 2>&1; local rc=$?

  check "resume marker: exits 0" test "$rc" -eq 0
  check "resume marker: completes the upgrade" has_call '^dnf install .*--allowerasing'
  check "resume marker: removed on success" bash -c '[[ ! -e "$1" ]]' _ "$NVIDIA_RESUME_MARKER"
  end_case
}

# ===========================================================================
# Phase 3 (closure fix) -- availability-gate optional unit packages
# ===========================================================================
case_fabricmanager_absent_does_not_block() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_FABRICMANAGER_UNIT=1 FAKE_FABRICMANAGER_ACTIVE=0
  export FAKE_FABRICMANAGER_FRAGMENT=/usr/lib/systemd/system/nvidia-fabricmanager.service
  export FAKE_UNIT_OWNER_FABRICMANAGER=nvidia-fabricmanager-595.112.07-1.el9.x86_64
  export FAKE_REPOQUERY_FABRICMANAGER=""
  export FAKE_PERSISTENCED_UNIT=0
  fake_gpu_install
  local out="$case_tmp/out" err="$case_tmp/err" rc
  nvidia_ensure_driver_floor >"$out" 2>"$err"; rc=$?

  check "fm absent: exits 0 despite the missing optional unit" test "$rc" -eq 0
  check "fm absent: stages the required 620 NEVRA" \
    stage_has_package 'nvidia-open-3:620.70.06-1.el9'
  check "fm absent: omits nvidia-fabricmanager-620" stage_omits_package 'nvidia-fabricmanager-620'
  check "fm absent: warns about fabricmanager on stderr" \
    bash -c 'grep -Eqi "warn|omit|skip" "$1" && grep -qi fabricmanager "$1"' _ "$err"
  check "fm absent: stage precedes the offline install" \
    before '^dnf install .*--downloadonly' '^dnf install .*--allowerasing'
  check "fm absent: no resume marker left behind" bash -c '[[ ! -e "$1" ]]' _ "$NVIDIA_RESUME_MARKER"
  end_case
}

case_fabricmanager_available_is_included() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_FABRICMANAGER_UNIT=1 FAKE_FABRICMANAGER_ACTIVE=0
  export FAKE_FABRICMANAGER_FRAGMENT=/usr/lib/systemd/system/nvidia-fabricmanager.service
  export FAKE_UNIT_OWNER_FABRICMANAGER=nvidia-fabricmanager-595.112.07-1.el9.x86_64
  export FAKE_REPOQUERY_FABRICMANAGER=620.70.06-1.el9
  export FAKE_PERSISTENCED_UNIT=0
  fake_gpu_install
  local out="$case_tmp/out" err="$case_tmp/err" rc
  nvidia_ensure_driver_floor >"$out" 2>"$err"; rc=$?

  check "fm available: exits 0" test "$rc" -eq 0
  check "fm available: stages the exact resolved token" \
    stage_has_package 'nvidia-fabricmanager-620.70.06-1.el9'
  check "fm available: prints no omission warning" \
    bash -c '! grep -Eqi "omit|skip" "$1"' _ "$err"
  end_case
}

case_persistenced_non_rpm_available() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_FABRICMANAGER_UNIT=0
  export FAKE_PERSISTENCED_UNIT=1 FAKE_PERSISTENCED_ACTIVE=1
  export FAKE_UNIT_OWNER_PERSISTENCED=""
  export FAKE_REPOQUERY_PERSISTENCED=620.70.06-1.el9
  fake_gpu_install
  local rc
  nvidia_ensure_driver_floor >/dev/null 2>&1; rc=$?

  check "persistenced non-rpm available: exits 0" test "$rc" -eq 0
  check "persistenced non-rpm available: is staged" \
    stage_has_package 'nvidia-persistenced-620.70.06-1.el9'
  check "persistenced non-rpm available: is repoqueried" \
    has_call 'repoquery .*nvidia-persistenced-620\.70\.06'
  end_case
}

case_persistenced_non_rpm_absent() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_FABRICMANAGER_UNIT=0
  export FAKE_PERSISTENCED_UNIT=1 FAKE_PERSISTENCED_ACTIVE=1
  export FAKE_UNIT_OWNER_PERSISTENCED=""
  export FAKE_REPOQUERY_PERSISTENCED=""
  fake_gpu_install
  local out="$case_tmp/out" err="$case_tmp/err" rc
  nvidia_ensure_driver_floor >"$out" 2>"$err"; rc=$?

  check "persistenced non-rpm absent: exits 0" test "$rc" -eq 0
  check "persistenced non-rpm absent: warns about the omission" \
    bash -c 'grep -Eqi "warn|omit|skip" "$1" && grep -qi persistenced "$1"' _ "$err"
  check "persistenced non-rpm absent: does not fabricate the package" \
    stage_omits_package 'nvidia-persistenced-620.70.06'
  end_case
}

case_optional_repoquery_transient_failure() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_FABRICMANAGER_UNIT=1 FAKE_FABRICMANAGER_ACTIVE=0
  export FAKE_FABRICMANAGER_FRAGMENT=/usr/lib/systemd/system/nvidia-fabricmanager.service
  export FAKE_UNIT_OWNER_FABRICMANAGER=nvidia-fabricmanager-595.112.07-1.el9.x86_64
  export FAKE_REPOQUERY_FABRICMANAGER=620.70.06-1.el9
  export FAKE_REPOQUERY_RC=1
  export FAKE_PERSISTENCED_UNIT=0
  fake_gpu_install
  local out="$case_tmp/out" err="$case_tmp/err" rc
  nvidia_ensure_driver_floor >"$out" 2>"$err"; rc=$?

  check "repoquery failure: required stage still succeeds" test "$rc" -eq 0
  check "repoquery failure: required NEVRA is staged" \
    stage_has_package 'nvidia-open-3:620.70.06-1.el9'
  check "repoquery failure: optional package is omitted" stage_omits_package 'nvidia-fabricmanager-620'
  check "repoquery failure: warns about the omitted optional" \
    bash -c 'grep -Eqi "warn|omit|skip" "$1"' _ "$err"
  end_case
}

case_required_stage_failure() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_PKG_AVAILABLE=0
  export FAKE_FABRICMANAGER_UNIT=0 FAKE_PERSISTENCED_UNIT=0
  fake_gpu_install
  local out="$case_tmp/out" err="$case_tmp/err" rc
  nvidia_ensure_driver_floor >"$out" 2>"$err"; rc=$?

  check "required stage failure: fails" test "$rc" -ne 0
  check "required stage failure: names [closure]" bash -c 'grep -q "\[closure\]" "$1"' _ "$err"
  check "required stage failure: no uninstall attempted" no_call 'nvidia-uninstall'
  check "required stage failure: no offline install attempted" no_call '^dnf install .*--allowerasing'
  check "required stage failure: no marker left behind" bash -c '[[ ! -e "$1" ]]' _ "$NVIDIA_RESUME_MARKER"
  end_case
}

case_no_optional_units() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_FABRICMANAGER_UNIT=0 FAKE_PERSISTENCED_UNIT=0
  fake_gpu_install
  local rc
  nvidia_ensure_driver_floor >/dev/null 2>&1; rc=$?

  check "no optional units: exits 0" test "$rc" -eq 0
  check "no optional units: never queries rpm -qf" no_call '^rpm -qf'
  check "no optional units: never repoquery" no_call 'repoquery'
  check "no optional units: no optional package in the stage" \
    bash -c '! grep -E "^dnf install .*--downloadonly" "$1" | grep -Eq "fabricmanager|persistenced"' _ "$FAKE_GPU_CALLS"
  end_case
}

case_fabricmanager_unit_absent() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_FABRICMANAGER_UNIT=0 FAKE_PERSISTENCED_UNIT=0
  # Set the other knobs anyway: an absent unit must short-circuit before them.
  export FAKE_FABRICMANAGER_FRAGMENT=/usr/lib/systemd/system/nvidia-fabricmanager.service
  export FAKE_UNIT_OWNER_FABRICMANAGER=nvidia-fabricmanager-595.112.07-1.el9.x86_64
  export FAKE_REPOQUERY_FABRICMANAGER=620.70.06-1.el9
  fake_gpu_install
  local rc
  nvidia_ensure_driver_floor >/dev/null 2>&1; rc=$?

  check "fm unit absent: exits 0" test "$rc" -eq 0
  check "fm unit absent: never shows the fragment" no_call 'systemctl show .*fabricmanager'
  check "fm unit absent: never queries rpm -qf" no_call '^rpm -qf'
  check "fm unit absent: never repoquery" no_call 'repoquery'
  check "fm unit absent: no fabricmanager package staged" stage_omits_package 'nvidia-fabricmanager'
  end_case
}

case_failed_host_reproduction() {
  begin_case
  export FAKE_REPORTED_DRIVER=595.112.07 FAKE_PROC_VERSION=595.112.07
  export FAKE_RPM_INSTALLED=0 FAKE_RUN_MANAGED=1 FAKE_KERNEL_MODULE_VARIANT=dkms
  export FAKE_DKMS_RPM=1 FAKE_DKMS_PAYLOAD=1
  export FAKE_FABRICMANAGER_UNIT=1 FAKE_FABRICMANAGER_ACTIVE=0
  export FAKE_FABRICMANAGER_FRAGMENT=/usr/lib/systemd/system/nvidia-fabricmanager.service
  export FAKE_UNIT_OWNER_FABRICMANAGER=nvidia-fabricmanager-595.112.07-1.el9.x86_64
  export FAKE_REPOQUERY_FABRICMANAGER=""
  export FAKE_PERSISTENCED_UNIT=0
  fake_gpu_install
  local kernel="$("$(command -v uname)" -r)"
  export FAKE_DKMS_STATUS="nvidia-open/595.112.07, $kernel, x86_64: installed
nvidia-open/620.70.06, $kernel, x86_64: installed"
  local out="$case_tmp/out" err="$case_tmp/err" rc
  nvidia_ensure_driver_floor >"$out" 2>"$err"; rc=$?

  check "failed host: exits 0" test "$rc" -eq 0
  check "failed host: stages the required 620 NEVRA" \
    stage_has_package 'nvidia-open-3:620.70.06-1.el9'
  check "failed host: omits nvidia-fabricmanager-620" stage_omits_package 'nvidia-fabricmanager-620'
  check "failed host: warns about the omitted fabricmanager" \
    bash -c 'grep -Eqi "warn|omit|skip" "$1" && grep -qi fabricmanager "$1"' _ "$err"
  check "failed host: stage precedes nvidia-uninstall" \
    before '^dnf install .*--downloadonly' 'nvidia-uninstall'
  check "failed host: stage precedes the offline install" \
    before '^dnf install .*--downloadonly' '^dnf install .*--allowerasing'
  end_case
}

case_repoquery_multiple_or_below_floor() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_FABRICMANAGER_UNIT=1 FAKE_FABRICMANAGER_ACTIVE=0
  export FAKE_FABRICMANAGER_FRAGMENT=/usr/lib/systemd/system/nvidia-fabricmanager.service
  export FAKE_UNIT_OWNER_FABRICMANAGER=nvidia-fabricmanager-595.112.07-1.el9.x86_64
  # Two rows (one below the floor): ambiguous, so the package must be omitted.
  export FAKE_REPOQUERY_FABRICMANAGER="595.112.07-1.el9
620.70.06-1.el9"
  export FAKE_PERSISTENCED_UNIT=0
  fake_gpu_install
  local out="$case_tmp/out" err="$case_tmp/err" rc
  nvidia_ensure_driver_floor >"$out" 2>"$err"; rc=$?

  check "repoquery ambiguous: required stage still succeeds" test "$rc" -eq 0
  check "repoquery ambiguous: optional package is omitted" stage_omits_package 'nvidia-fabricmanager-620'
  check "repoquery ambiguous: warns about the omission" \
    bash -c 'grep -Eqi "warn|omit|skip" "$1"' _ "$err"
  end_case
}

case_stage_no_empty_extra_arg() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_FABRICMANAGER_UNIT=0 FAKE_PERSISTENCED_UNIT=0
  fake_gpu_install
  local rc stage
  nvidia_ensure_driver_floor >/dev/null 2>&1; rc=$?
  stage="$(stage_line)"

  check "no empty extra arg: exits 0" test "$rc" -eq 0
  check "no empty extra arg: stage line has no empty token" \
    bash -c '[[ -n "$1" && "$1" != *"  "* && "$1" != *" " ]]' _ "$stage"
  check "no empty extra arg: the required NEVRA appears exactly once" \
    bash -c '[[ "$(grep -o "nvidia-open-3:620.70.06-1.el9" <<<"$1" | wc -l)" -eq 1 ]]' _ "$stage"
  check "no empty extra arg: no optional package in the stage" \
    bash -c '! grep -Eq "fabricmanager|persistenced" <<<"$1"' _ "$stage"
  end_case
}

case_stdout_stderr_separation() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_FABRICMANAGER_UNIT=1 FAKE_FABRICMANAGER_ACTIVE=0
  export FAKE_FABRICMANAGER_FRAGMENT=/usr/lib/systemd/system/nvidia-fabricmanager.service
  export FAKE_UNIT_OWNER_FABRICMANAGER=nvidia-fabricmanager-595.112.07-1.el9.x86_64
  export FAKE_REPOQUERY_FABRICMANAGER=""
  export FAKE_PERSISTENCED_UNIT=0
  fake_gpu_install
  local sout="$case_tmp/stdout" serr="$case_tmp/stderr"
  nvidia__optional_unit_packages fake-sudo >"$sout" 2>"$serr"

  check "separate streams: stdout carries no warnings" \
    bash -c '! grep -Eqi "warn|omit|skip|nvidia:" "$1"' _ "$sout"
  check "separate streams: stdout is empty when no package is available" \
    bash -c '[[ ! -s "$1" ]]' _ "$sout"
  check "separate streams: stderr carries the omission warning" \
    bash -c 'grep -Eqi "warn|omit|skip" "$1"' _ "$serr"
  end_case
}

case_repoquery_flag_shape() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_FABRICMANAGER_UNIT=1 FAKE_FABRICMANAGER_ACTIVE=0
  export FAKE_FABRICMANAGER_FRAGMENT=/usr/lib/systemd/system/nvidia-fabricmanager.service
  export FAKE_UNIT_OWNER_FABRICMANAGER=nvidia-fabricmanager-595.112.07-1.el9.x86_64
  export FAKE_REPOQUERY_FABRICMANAGER=620.70.06-1.el9
  export FAKE_PERSISTENCED_UNIT=0
  fake_gpu_install
  nvidia__optional_unit_packages fake-sudo >/dev/null 2>&1

  local expected='dnf -q --disableexcludes=all repoquery --available --qf %{name} %{version}-%{release} %{arch}\n nvidia-fabricmanager-620.70.06'
  check "repoquery flag shape: uses the exact availability query" \
    grep -Fq -- "$expected" "$FAKE_GPU_CALLS"
  end_case
}

# ===========================================================================
# Phase 4 (closure fix) -- restore only active units, preserve resume state
# ===========================================================================
case_fabricmanager_inactive_not_restarted() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_FABRICMANAGER_UNIT=1 FAKE_FABRICMANAGER_ACTIVE=0
  export FAKE_FABRICMANAGER_FRAGMENT=/usr/lib/systemd/system/nvidia-fabricmanager.service
  export FAKE_UNIT_OWNER_FABRICMANAGER=nvidia-fabricmanager-595.112.07-1.el9.x86_64
  export FAKE_REPOQUERY_FABRICMANAGER=620.70.06-1.el9
  export FAKE_PERSISTENCED_UNIT=0
  fake_gpu_install
  local rc
  nvidia_ensure_driver_floor >/dev/null 2>&1; rc=$?

  check "fm inactive: exits 0" test "$rc" -eq 0
  check "fm inactive: never restarts fabricmanager" unit_not_started nvidia-fabricmanager.service
  end_case
}

case_fabricmanager_active_restored() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_FABRICMANAGER_UNIT=1 FAKE_FABRICMANAGER_ACTIVE=1
  export FAKE_FABRICMANAGER_FRAGMENT=/usr/lib/systemd/system/nvidia-fabricmanager.service
  export FAKE_UNIT_OWNER_FABRICMANAGER=nvidia-fabricmanager-595.112.07-1.el9.x86_64
  export FAKE_REPOQUERY_FABRICMANAGER=620.70.06-1.el9
  export FAKE_PERSISTENCED_UNIT=0
  fake_gpu_install
  local rc
  nvidia_ensure_driver_floor >/dev/null 2>&1; rc=$?

  check "fm active: exits 0" test "$rc" -eq 0
  check "fm active: restarts fabricmanager exactly once" \
    bash -c '[[ "$(grep -Ec "^systemctl start nvidia-fabricmanager\.service" "$1")" -eq 1 ]]' _ "$FAKE_GPU_CALLS"
  end_case
}

case_fabricmanager_start_failure_nonfatal() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_FABRICMANAGER_UNIT=1 FAKE_FABRICMANAGER_ACTIVE=1
  export FAKE_FABRICMANAGER_FRAGMENT=/usr/lib/systemd/system/nvidia-fabricmanager.service
  export FAKE_UNIT_OWNER_FABRICMANAGER=nvidia-fabricmanager-595.112.07-1.el9.x86_64
  export FAKE_REPOQUERY_FABRICMANAGER=620.70.06-1.el9
  export FAKE_FABRICMANAGER_START_RC=1
  export FAKE_PERSISTENCED_UNIT=0
  fake_gpu_install
  local out="$case_tmp/out" err="$case_tmp/err" rc
  nvidia_ensure_driver_floor >"$out" 2>"$err"; rc=$?

  check "fm start rc!=0: upgrade still succeeds" test "$rc" -eq 0
  check "fm start rc!=0: warns loudly about fabricmanager" \
    bash -c 'grep -Eqi "warn" "$1" && grep -qi fabricmanager "$1"' _ "$err"
  check "fm start rc!=0: prints the success line" \
    bash -c 'grep -qi "at or above the .* floor" "$1"' _ "$out"
  end_case
}

case_fabricmanager_active_but_pkg_not_staged() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_FABRICMANAGER_UNIT=1 FAKE_FABRICMANAGER_ACTIVE=1
  export FAKE_FABRICMANAGER_FRAGMENT=/usr/lib/systemd/system/nvidia-fabricmanager.service
  export FAKE_UNIT_OWNER_FABRICMANAGER=nvidia-fabricmanager-595.112.07-1.el9.x86_64
  export FAKE_REPOQUERY_FABRICMANAGER=""
  export FAKE_PERSISTENCED_UNIT=0
  fake_gpu_install
  local out="$case_tmp/out" err="$case_tmp/err" rc
  nvidia_ensure_driver_floor >"$out" 2>"$err"; rc=$?

  check "fm active but not staged: exits 0" test "$rc" -eq 0
  check "fm active but not staged: leaves fabricmanager stopped" \
    unit_not_started nvidia-fabricmanager.service
  check "fm active but not staged: warns about the omitted unit" \
    bash -c 'grep -Eqi "warn|omit|skip" "$1" && grep -qi fabricmanager "$1"' _ "$err"
  check "fm active but not staged: records the 595 package version" \
    bash -c 'grep -q "595" "$1"' _ "$err"
  end_case
}

case_persistenced_active_restored() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_FABRICMANAGER_UNIT=0
  export FAKE_PERSISTENCED_UNIT=1 FAKE_PERSISTENCED_ACTIVE=1
  fake_gpu_install
  local rc
  nvidia_ensure_driver_floor >/dev/null 2>&1; rc=$?

  check "persistenced active: exits 0" test "$rc" -eq 0
  check "persistenced active: restarts exactly once" \
    bash -c '[[ "$(grep -Ec "^systemctl start nvidia-persistenced\.service" "$1")" -eq 1 ]]' _ "$FAKE_GPU_CALLS"
  end_case
}

case_persistenced_inactive_not_restarted() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_FABRICMANAGER_UNIT=0
  export FAKE_PERSISTENCED_UNIT=1 FAKE_PERSISTENCED_ACTIVE=0
  fake_gpu_install
  local rc
  nvidia_ensure_driver_floor >/dev/null 2>&1; rc=$?

  check "persistenced inactive: exits 0" test "$rc" -eq 0
  check "persistenced inactive: never restarts it" unit_not_started nvidia-persistenced.service
  end_case
}

case_persistenced_start_failure_fatal() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_FABRICMANAGER_UNIT=0
  export FAKE_PERSISTENCED_UNIT=1 FAKE_PERSISTENCED_ACTIVE=1
  export FAKE_PERSISTENCED_START_RC=1
  fake_gpu_install
  local out="$case_tmp/out" err="$case_tmp/err" rc
  nvidia_ensure_driver_floor >"$out" 2>"$err"; rc=$?

  check "persistenced start rc!=0: upgrade fails" test "$rc" -ne 0
  check "persistenced start rc!=0: prints [verify]" bash -c 'grep -q "\[verify\]" "$1"' _ "$err"
  check "persistenced start rc!=0: never prints a success line" \
    bash -c '! grep -qi "at or above the .* floor" "$1"' _ "$out"
  end_case
}

case_resume_preserves_active_state() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_FABRICMANAGER_UNIT=1 FAKE_FABRICMANAGER_ACTIVE=1
  export FAKE_FABRICMANAGER_FRAGMENT=/usr/lib/systemd/system/nvidia-fabricmanager.service
  export FAKE_UNIT_OWNER_FABRICMANAGER=nvidia-fabricmanager-595.112.07-1.el9.x86_64
  export FAKE_REPOQUERY_FABRICMANAGER=620.70.06-1.el9
  export FAKE_PERSISTENCED_UNIT=1 FAKE_PERSISTENCED_ACTIVE=0
  fake_gpu_install
  local rc1 rc2

  export FAKE_DNF_RC=1
  nvidia_ensure_driver_floor >/dev/null 2>&1; rc1=$?
  check "resume: first run fails after the drain" test "$rc1" -ne 0
  check "resume: marker records the fabricmanager state" \
    bash -c 'grep -qi fabricmanager "$1"' _ "$NVIDIA_RESUME_MARKER"
  check "resume: marker records the persistenced state" \
    bash -c 'grep -qi persistenced "$1"' _ "$NVIDIA_RESUME_MARKER"

  export FAKE_DNF_RC=0
  nvidia_ensure_driver_floor >/dev/null 2>&1; rc2=$?
  check "resume: second run succeeds" test "$rc2" -eq 0
  check "resume: restores fabricmanager (active before the drain)" \
    unit_started nvidia-fabricmanager.service
  check "resume: never restarts persistenced (inactive before the drain)" \
    unit_not_started nvidia-persistenced.service
  end_case
}

case_marker_write_failure() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_FABRICMANAGER_UNIT=0
  export FAKE_PERSISTENCED_UNIT=1 FAKE_PERSISTENCED_ACTIVE=1
  # A regular file where the marker directory should be makes both mkdir and tee
  # fail, so the pre-drain marker cannot be written.
  : >"$case_tmp/blocked"
  export NVIDIA_RESUME_MARKER="$case_tmp/blocked/state"
  fake_gpu_install
  local out="$case_tmp/out" err="$case_tmp/err" rc
  nvidia_ensure_driver_floor >"$out" 2>"$err"; rc=$?

  check "marker write failure: upgrade fails" test "$rc" -ne 0
  check "marker write failure: no unit is stopped" no_call '^systemctl stop'
  check "marker write failure: no uninstall attempted" no_call 'nvidia-uninstall'
  check "marker write failure: no offline install attempted" no_call '^dnf install .*--allowerasing'
  end_case
}

case_resume_at_floor_short_circuit() {
  begin_case
  export FAKE_REPORTED_DRIVER=620.70.06 FAKE_PROC_VERSION=620.70.06 FAKE_RPM_INSTALLED=1
  export FAKE_FABRICMANAGER_UNIT=0
  export FAKE_PERSISTENCED_UNIT=1 FAKE_PERSISTENCED_ACTIVE=1
  : >"$NVIDIA_RESUME_MARKER"
  fake_gpu_install
  local rc
  nvidia_ensure_driver_floor >/dev/null 2>&1; rc=$?

  check "resume at floor: exits 0" test "$rc" -eq 0
  check "resume at floor: performs no stage" no_call '^dnf install .*--downloadonly'
  check "resume at floor: performs no offline install" no_call '^dnf install .*--allowerasing'
  check "resume at floor: performs no uninstall" no_call 'nvidia-uninstall'
  check "resume at floor: restores persistenced" unit_started nvidia-persistenced.service
  check "resume at floor: removes the marker" bash -c '[[ ! -e "$1" ]]' _ "$NVIDIA_RESUME_MARKER"
  end_case
}

# ===========================================================================
# Phase 5 (closure fix) -- DKMS-only 620 payload + safe ordering
# ===========================================================================
case_dkms_only_closure_succeeds() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_KERNEL_MODULE_VARIANT=dkms
  export FAKE_DKMS_RPM=1 FAKE_DKMS_PAYLOAD=1
  export FAKE_FABRICMANAGER_UNIT=0
  export FAKE_PERSISTENCED_UNIT=1 FAKE_PERSISTENCED_ACTIVE=1
  fake_gpu_install
  export FAKE_DKMS_STATUS="nvidia-open/620.70.06, $(uname -r), x86_64: installed"
  local rc
  nvidia_ensure_driver_floor >/dev/null 2>&1; rc=$?

  check "dkms-only: exits 0" test "$rc" -eq 0
  check "dkms-only: stages the DKMS closure" has_call '^dnf install .*--downloadonly'
  check "dkms-only: runs the offline install" has_call '^dnf install .*--allowerasing'
  check "dkms-only: runs depmod -a" has_call 'depmod -a'
  check "dkms-only: loads the nvidia module" has_call 'modprobe nvidia$'
  check "dkms-only: proc reports 620" procs_620
  end_case
}

case_dkms_payload_missing_dkms_conf() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_KERNEL_MODULE_VARIANT=dkms
  export FAKE_DKMS_RPM=1 FAKE_DKMS_PAYLOAD=1 FAKE_DKMS_CONF_MISSING=1
  export FAKE_FABRICMANAGER_UNIT=0 FAKE_PERSISTENCED_UNIT=0
  fake_gpu_install
  local out="$case_tmp/out" err="$case_tmp/err" rc
  nvidia_ensure_driver_floor >"$out" 2>"$err"; rc=$?

  check "missing dkms.conf: fails" test "$rc" -ne 0
  check "missing dkms.conf: names [kernel-module] and dkms.conf" \
    bash -c 'grep -q "\[kernel-module\]" "$1" && grep -q "dkms.conf" "$1"' _ "$err"
  check "missing dkms.conf: no uninstall attempted" no_call 'nvidia-uninstall'
  check "missing dkms.conf: no offline install attempted" no_call '^dnf install .*--allowerasing'
  check "missing dkms.conf: no marker left behind" bash -c '[[ ! -e "$1" ]]' _ "$NVIDIA_RESUME_MARKER"
  end_case
}

case_dkms_tool_missing() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_KERNEL_MODULE_VARIANT=dkms
  export FAKE_DKMS_RPM=1 FAKE_DKMS_PAYLOAD=1 FAKE_DKMS_TOOL_MISSING=1
  export FAKE_FABRICMANAGER_UNIT=0 FAKE_PERSISTENCED_UNIT=0
  fake_gpu_install
  local out="$case_tmp/out" err="$case_tmp/err" rc
  nvidia_ensure_driver_floor >"$out" 2>"$err"; rc=$?

  check "dkms tool missing: fails" test "$rc" -ne 0
  check "dkms tool missing: names [kernel-module] and the dkms tool" \
    bash -c 'grep -q "\[kernel-module\]" "$1" && grep -qi "dkms" "$1"' _ "$err"
  check "dkms tool missing: no uninstall attempted" no_call 'nvidia-uninstall'
  check "dkms tool missing: no offline install attempted" no_call '^dnf install .*--allowerasing'
  end_case
}

case_dkms_tool_staged() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_KERNEL_MODULE_VARIANT=dkms
  export FAKE_DKMS_RPM=1 FAKE_DKMS_PAYLOAD=1 FAKE_STAGE_INCLUDE_DKMS=1
  export FAKE_FABRICMANAGER_UNIT=0
  export FAKE_PERSISTENCED_UNIT=1 FAKE_PERSISTENCED_ACTIVE=1
  fake_gpu_install
  export FAKE_DKMS_STATUS="nvidia-open/620.70.06, $(uname -r), x86_64: installed"
  local rc
  nvidia_ensure_driver_floor >/dev/null 2>&1; rc=$?

  check "dkms tool staged: exits 0" test "$rc" -eq 0
  check "dkms tool staged: the stage is accepted" has_call '^dnf install .*--downloadonly'
  check "dkms tool staged: the dkms RPM is in the closure" \
    bash -c 'compgen -G "$1/dkms-*.rpm" >/dev/null' _ "$NVIDIA_STAGE_DIR"
  check "dkms tool staged: the offline install runs" has_call '^dnf install .*--allowerasing'
  check "dkms tool staged: post-install verification runs dkms status" \
    before '^dnf install .*--allowerasing' 'dkms status'
  end_case
}

case_dkms_kernel_headers_missing() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_KERNEL_MODULE_VARIANT=dkms
  export FAKE_DKMS_RPM=1 FAKE_DKMS_PAYLOAD=1 FAKE_KERNEL_HEADERS_MISSING=1
  export FAKE_FABRICMANAGER_UNIT=0 FAKE_PERSISTENCED_UNIT=0
  fake_gpu_install
  local out="$case_tmp/out" err="$case_tmp/err" rc
  nvidia_ensure_driver_floor >"$out" 2>"$err"; rc=$?

  check "kernel headers missing: fails" test "$rc" -ne 0
  check "kernel headers missing: names [kernel-module] and kernel-headers/devel" \
    bash -c 'grep -q "\[kernel-module\]" "$1" && grep -Eq "kernel-(headers|devel)" "$1"' _ "$err"
  check "kernel headers missing: no uninstall attempted" no_call 'nvidia-uninstall'
  check "kernel headers missing: no offline install attempted" no_call '^dnf install .*--allowerasing'
  end_case
}

case_dkms_build_proof_fails() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_KERNEL_MODULE_VARIANT=dkms
  export FAKE_DKMS_RPM=1 FAKE_DKMS_PAYLOAD=1 FAKE_DKMS_BUILD_RC=1
  export FAKE_FABRICMANAGER_UNIT=0 FAKE_PERSISTENCED_UNIT=0
  fake_gpu_install
  local out="$case_tmp/out" err="$case_tmp/err" rc
  nvidia_ensure_driver_floor >"$out" 2>"$err"; rc=$?

  check "dkms build proof fails: upgrade fails" test "$rc" -ne 0
  check "dkms build proof fails: a build was attempted" has_call '^dkms (build|install)'
  check "dkms build proof fails: names [kernel-module]" bash -c 'grep -q "\[kernel-module\]" "$1"' _ "$err"
  check "dkms build proof fails: no uninstall attempted" no_call 'nvidia-uninstall'
  check "dkms build proof fails: no offline install attempted" no_call '^dnf install .*--allowerasing'
  end_case
}

# --- DKMS pre-install proof: staged prerequisites + a registered source ------
# The fake `dkms build` refuses to run until the staged DKMS source has been
# extracted into NVIDIA_DKMS_SRC_ROOT and registered with `dkms add`, so this
# case fails if the library builds before source registration or skips the
# staged dkms/kernel-devel/kernel-headers installs.
case_dkms_source_registration_before_build() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_KERNEL_MODULE_VARIANT=dkms
  export FAKE_DKMS_RPM=1 FAKE_DKMS_PAYLOAD=1
  export FAKE_DKMS_TOOL_MISSING=1 FAKE_STAGE_INCLUDE_BUILD_PREREQS=1
  export FAKE_KERNEL_DEVEL_MISSING=1 FAKE_KERNEL_HEADERS_MISSING=1
  export FAKE_DNF_DKMS_INSTALL_REGISTERS=1
  export FAKE_FABRICMANAGER_UNIT=0
  export FAKE_PERSISTENCED_UNIT=1 FAKE_PERSISTENCED_ACTIVE=1
  fake_gpu_install
  local kernel="$("$(command -v uname)" -r)"
  local src_dir="$NVIDIA_DKMS_SRC_ROOT/nvidia-open-$NVIDIA_DRIVER_FLOOR"
  local rc pre_rc post_rc
  "$(command -v dkms)" build "nvidia-open/$NVIDIA_DRIVER_FLOOR" -k "$kernel" \
    >/dev/null 2>&1
  pre_rc=$?
  # Drop the deliberate pre-check from the ordering evidence.
  : >"$FAKE_GPU_CALLS"
  export FAKE_DKMS_STATUS="nvidia-open/595.112.07, $kernel, x86_64: installed"
  nvidia_ensure_driver_floor >/dev/null 2>&1; rc=$?
  "$(command -v dkms)" build "nvidia-open/$NVIDIA_DRIVER_FLOOR" -k "$kernel" \
    >/dev/null 2>&1
  post_rc=$?

  check "dkms source: an unregistered source cannot be built" test "$pre_rc" -ne 0
  check "dkms source: upgrade exits 0" test "$rc" -eq 0
  check "dkms source: installs the staged dkms tool" state_flag dkms_tool
  check "dkms source: installs staged kernel-devel" state_flag kernel_devel
  check "dkms source: installs staged kernel-headers" state_flag kernel_headers
  check "dkms source: dkms tool install precedes the build" \
    before '^dnf install .*dkms-' '^dkms build '
  check "dkms source: kernel-devel install precedes the build" \
    before '^dnf install .*kernel-devel-' '^dkms build '
  check "dkms source: kernel-headers install precedes the build" \
    before '^dnf install .*kernel-headers-' '^dkms build '
  check "dkms source: prerequisites install precedes the extraction" \
    before '^dnf install .*kernel-devel-' '^rpm2cpio '
  check "dkms source: source is extracted with rpm2cpio/cpio" \
    bash -c 'grep -q "^rpm2cpio " "$1" && grep -q "^cpio " "$1"' _ "$FAKE_GPU_CALLS"
  check "dkms source: dkms add registers nvidia-open/$NVIDIA_DRIVER_FLOOR" \
    has_call "^dkms add nvidia-open/$NVIDIA_DRIVER_FLOOR\$"
  check "dkms source: the build runs after dkms add" \
    before "^dkms add nvidia-open/$NVIDIA_DRIVER_FLOOR\$" '^dkms build nvidia-open/620\.70\.06'
  check "dkms source: the proof build precedes the offline driver install" \
    before '^dkms build ' '^dnf install .*--allowerasing'
  check "dkms source: the extracted source tree exists" \
    bash -c '[[ -f "$1/dkms.conf" ]]' _ "$src_dir"
  check "dkms source: a registered source builds" test "$post_rc" -eq 0
  end_case
}

case_run_managed_dkms_detected() {
  begin_case
  export FAKE_REPORTED_DRIVER=595.112.07 FAKE_PROC_VERSION=595.112.07
  export FAKE_RPM_INSTALLED=0 FAKE_RUN_MANAGED=1 FAKE_KERNEL_MODULE_VARIANT=dkms
  export FAKE_DKMS_RPM=1 FAKE_DKMS_PAYLOAD=1
  export FAKE_FABRICMANAGER_UNIT=0
  export FAKE_PERSISTENCED_UNIT=1 FAKE_PERSISTENCED_ACTIVE=1
  fake_gpu_install
  local kernel="$("$(command -v uname)" -r)"
  export FAKE_DKMS_STATUS="nvidia-open/595.112.07, $kernel, x86_64: installed
nvidia-open/620.70.06, $kernel, x86_64: installed"
  local variant rc
  variant="$(nvidia__kernel_module_variant fake-sudo 2>/dev/null)"
  check "run-managed dkms: variant detection reports dkms" test "$variant" = "dkms"
  nvidia_ensure_driver_floor >/dev/null 2>&1; rc=$?

  check "run-managed dkms: exits 0" test "$rc" -eq 0
  check "run-managed dkms: consults dkms status" has_call 'dkms status'
  check "run-managed dkms: removes the stale 595 build before depmod" \
    before 'dkms remove nvidia-open/595' 'depmod -a'
  end_case
}

case_run_managed_dkms_remove_failure() {
  begin_case
  export FAKE_REPORTED_DRIVER=595.112.07 FAKE_PROC_VERSION=595.112.07
  export FAKE_RPM_INSTALLED=0 FAKE_RUN_MANAGED=1 FAKE_KERNEL_MODULE_VARIANT=dkms
  export FAKE_DKMS_RPM=1 FAKE_DKMS_PAYLOAD=1
  export FAKE_DKMS_REMOVE_RC=1 FAKE_DKMS_STATUS_RC=0
  export FAKE_FABRICMANAGER_UNIT=0
  export FAKE_PERSISTENCED_UNIT=1 FAKE_PERSISTENCED_ACTIVE=1
  fake_gpu_install
  local kernel="$("$(command -v uname)" -r)"
  export FAKE_DKMS_STATUS="nvidia-open/595.112.07, $kernel, x86_64: installed
nvidia-open/620.70.06, $kernel, x86_64: installed"
  local out="$case_tmp/out" err="$case_tmp/err" rc
  nvidia_ensure_driver_floor >"$out" 2>"$err"; rc=$?

  check "dkms remove fails: upgrade fails" test "$rc" -ne 0
  check "dkms remove fails: names [dkms]" bash -c 'grep -q "\[dkms\]" "$1"' _ "$err"
  check "dkms remove fails: never runs depmod" no_call 'depmod -a'
  check "dkms remove fails: never unloads the module" no_call 'modprobe -r'
  check "dkms remove fails: never prints a success line" \
    bash -c '! grep -qi "at or above the .* floor" "$1"' _ "$out"
  end_case
}

case_kmod_host_no_dkms() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_KERNEL_MODULE_VARIANT=kmod
  export FAKE_FABRICMANAGER_UNIT=0
  export FAKE_PERSISTENCED_UNIT=1 FAKE_PERSISTENCED_ACTIVE=1
  fake_gpu_install
  local rc
  nvidia_ensure_driver_floor >/dev/null 2>&1; rc=$?

  check "kmod host: exits 0" test "$rc" -eq 0
  check "kmod host: never mutates dkms builds" no_call '^dkms (add|remove|build|install)'
  end_case
}

case_gsp_missing() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_KERNEL_MODULE_VARIANT=dkms
  export FAKE_DKMS_RPM=1 FAKE_DKMS_PAYLOAD=1
  export FAKE_FABRICMANAGER_UNIT=0
  export FAKE_PERSISTENCED_UNIT=1 FAKE_PERSISTENCED_ACTIVE=1
  command rm -f "$NVIDIA_FIRMWARE_ROOT/nvidia/620.70.06/gsp_tu10x.bin"
  fake_gpu_install
  export FAKE_DKMS_STATUS="nvidia-open/620.70.06, $(uname -r), x86_64: installed"
  local out="$case_tmp/out" err="$case_tmp/err" rc
  nvidia_ensure_driver_floor >"$out" 2>"$err"; rc=$?

  check "gsp missing: fails" test "$rc" -ne 0
  check "gsp missing: names [kernel-module]" bash -c 'grep -q "\[kernel-module\]" "$1"' _ "$err"
  check "gsp missing: checked before nvidia-uninstall" no_call 'nvidia-uninstall'
  end_case
}

case_stale_dkms_removed_before_modinfo_gate() {
  begin_case
  export FAKE_REPORTED_DRIVER=595.112.07 FAKE_PROC_VERSION=595.112.07
  export FAKE_RPM_INSTALLED=1 FAKE_KERNEL_MODULE_VARIANT=dkms
  export FAKE_DKMS_RPM=1 FAKE_DKMS_PAYLOAD=1
  export FAKE_FABRICMANAGER_UNIT=0
  export FAKE_PERSISTENCED_UNIT=1 FAKE_PERSISTENCED_ACTIVE=1
  fake_gpu_install
  local kernel="$("$(command -v uname)" -r)"
  export FAKE_DKMS_STATUS="nvidia-open/595.112.07, $kernel, x86_64: installed
nvidia-open/620.70.06, $kernel, x86_64: installed"
  local rc
  nvidia_ensure_driver_floor >/dev/null 2>&1; rc=$?

  check "stale dkms ordering: exits 0" test "$rc" -eq 0
  check "stale dkms ordering: consults dkms status" has_call 'dkms status'
  check "stale dkms ordering: removes 595 before the modinfo gate" \
    before 'dkms remove nvidia-open/595' 'modinfo -k'
  check "stale dkms ordering: depmod before the modinfo gate" \
    before 'depmod -a' 'modinfo -k'
  end_case
}

case_dkms_post_install_module_missing() {
  begin_case
  export FAKE_REPORTED_DRIVER=595.112.07 FAKE_PROC_VERSION=595.112.07
  export FAKE_RPM_INSTALLED=1 FAKE_KERNEL_MODULE_VARIANT=dkms
  export FAKE_DKMS_RPM=1 FAKE_DKMS_PAYLOAD=1
  export FAKE_FABRICMANAGER_UNIT=0
  export FAKE_PERSISTENCED_UNIT=1 FAKE_PERSISTENCED_ACTIVE=1
  fake_gpu_install
  local kernel="$("$(command -v uname)" -r)"
  export FAKE_DKMS_STATUS="nvidia-open/595.112.07, $kernel, x86_64: installed"
  local out="$case_tmp/out" err="$case_tmp/err" rc
  nvidia_ensure_driver_floor >"$out" 2>"$err"; rc=$?

  check "post-install 620 missing: upgrade fails" test "$rc" -ne 0
  check "post-install 620 missing: names [kernel-module]" bash -c 'grep -q "\[kernel-module\]" "$1"' _ "$err"
  check "post-install 620 missing: marker remains" marker_present
  check "post-install 620 missing: keeps the 595 DKMS build" no_call 'dkms remove nvidia-open/595'
  end_case
}

# ===========================================================================
# Phase 2 (staging-dir permissions) -- RED: stage access contract
# ===========================================================================
case_stage_dir_mode() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  fake_gpu_install
  local rc parent out
  # Mirror deploy.sh's umask 077 so a mkdir -p parent is root-only too.
  out="$(umask 077; nvidia_ensure_driver_floor 2>&1)"; rc=$?
  parent="$(dirname "$NVIDIA_STAGE_DIR")"

  check "stage dir mode: upgrade exits 0" test "$rc" -eq 0
  check "stage dir mode: leaf is 755" test "$(stage_dir_mode)" = "755"
  check "stage dir mode: parent is traversable" bash -c '[[ -x "$1" ]]' _ "$parent"
  check "stage dir mode: leaf is accessible to the invoking user" stage_dir_accessible
  if [[ "$(id -u)" -ne 0 ]]; then
    check "stage dir mode: required RPM is visible (non-root variant)" stage_has_visible_rpm
  else
    printf 'skip: stage visibility is non-discriminating under the same-uid fake when root\n'
  fi
  end_case
}

case_stage_make_readable_helper() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  local dir="$case_tmp/leaf" rc=0
  command mkdir -p "$dir"
  command chmod 700 "$dir"
  fake_gpu_install
  nvidia__stage_make_readable "$SUDO" "$dir" >/dev/null 2>&1 || rc=$?

  check "make-readable: helper exists" fn_exists nvidia__stage_make_readable
  check "make-readable: exits 0" test "$rc" -eq 0
  check "make-readable: leaf becomes 755" test "$(stat -c '%a' "$dir")" = "755"
  check "make-readable: forwards the sudo command" has_call '^sudo chmod -R a\+rX'
  end_case
}

case_optional_stage_keeps_dir_readable() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_PERSISTENCED_UNIT=1 FAKE_UNIT_OWNER_PERSISTENCED=""
  export FAKE_REPOQUERY_PERSISTENCED=620.70.06-1.el9 FAKE_FABRICMANAGER_UNIT=0
  # Model a downloadonly transaction that leaves the leaf root-only again.
  export FAKE_DNF_DOWNLOADONLY_CHMOD=700
  fake_gpu_install
  local rc
  nvidia_ensure_driver_floor >/dev/null 2>&1; rc=$?

  check "optional readability: exits 0" test "$rc" -eq 0
  check "optional readability: optional token staged" \
    stage_has_package 'nvidia-persistenced-620.70.06-1.el9'
  check "optional readability: leaf is 755 after the optional transaction" \
    test "$(stage_dir_mode)" = "755"
  check "optional readability: stage is accessible" stage_dir_accessible
  end_case
}

case_atomic_swap_preserves_mode() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  command mkdir -p "$NVIDIA_STAGE_DIR"
  : >"$NVIDIA_STAGE_DIR/sentinel"
  command chmod 700 "$NVIDIA_STAGE_DIR"
  fake_gpu_install
  local rc
  nvidia_ensure_driver_floor >/dev/null 2>&1; rc=$?

  check "atomic swap: exits 0" test "$rc" -eq 0
  check "atomic swap: new leaf is 755" test "$(stage_dir_mode)" = "755"
  check "atomic swap: sentinel is gone" bash -c '[[ ! -e "$1/sentinel" ]]' _ "$NVIDIA_STAGE_DIR"
  check "atomic swap: .bak is removed" bash -c '[[ ! -e "$1.bak" ]]' _ "$NVIDIA_STAGE_DIR"
  check "atomic swap: no .tmp.* remains" bash -c '[[ -z "$1" ]]' _ "$(stage_temp_dirs)"
  end_case
}

case_dnf_success_no_rpms() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_DNF_EMPTY=1
  fake_gpu_install
  local err rc
  err="$case_tmp/err"
  nvidia_ensure_driver_floor >/dev/null 2>"$err"; rc=$?

  check "dnf empty: fails" test "$rc" -ne 0
  check "dnf empty: names [closure]" bash -c 'grep -q "\[closure\]" "$1"' _ "$err"
  check "dnf empty: names the stage path" bash -c 'grep -Fq "$1" "$2"' _ "$NVIDIA_STAGE_DIR" "$err"
  check "dnf empty: names the invoking user" bash -c 'grep -Fq "$(id -un)" "$1"' _ "$err"
  check "dnf empty: says empty or inaccessible" bash -c 'grep -Eqi "empty|inaccessible" "$1"' _ "$err"
  check "dnf empty: no rpm -K" no_call '^rpm -K'
  check "dnf empty: no nvidia-uninstall" no_call 'nvidia-uninstall'
  check "dnf empty: no offline install" no_call '^dnf install .*--allowerasing'
  check "dnf empty: no resume marker" bash -c '[[ ! -e "$1" ]]' _ "$NVIDIA_RESUME_MARKER"
  end_case
}

case_chmod_failure_removes_temp() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_CHMOD_RC=1
  fake_gpu_install
  local err rc
  err="$case_tmp/err"
  nvidia_ensure_driver_floor >/dev/null 2>"$err"; rc=$?

  check "chmod failure: fails" test "$rc" -ne 0
  check "chmod failure: names [closure]" bash -c 'grep -q "\[closure\]" "$1"' _ "$err"
  check "chmod failure: temp dir removed" bash -c '[[ -z "$1" ]]' _ "$(stage_temp_dirs)"
  check "chmod failure: no offline install" no_call '^dnf install .*--allowerasing'
  check "chmod failure: no resume marker" bash -c '[[ ! -e "$1" ]]' _ "$NVIDIA_RESUME_MARKER"
  end_case
}

case_optional_download_failure_warns() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_PERSISTENCED_UNIT=1 FAKE_UNIT_OWNER_PERSISTENCED=""
  export FAKE_REPOQUERY_PERSISTENCED=620.70.06-1.el9 FAKE_FABRICMANAGER_UNIT=0
  export FAKE_OPTIONAL_DOWNLOAD_RC=1
  fake_gpu_install
  local err rc
  err="$case_tmp/err"
  nvidia_ensure_driver_floor >/dev/null 2>"$err"; rc=$?

  check "optional download failure: exits 0" test "$rc" -eq 0
  check "optional download failure: warns and names persistenced" \
    bash -c 'grep -Eqi "warn|omit|skip" "$1" && grep -qi persistenced "$1"' _ "$err"
  check "optional download failure: required closure present" \
    stage_has_package 'nvidia-open-3:620.70.06-1.el9'
  check "optional download failure: stage remains readable" test "$(stage_dir_mode)" = "755"
  check "optional download failure: no chmod abort" \
    bash -c '! grep -qi "could not make staging directory readable" "$1"' _ "$err"
  end_case
}

case_cross_uid_access() {
  begin_case
  if ! unreadable_probe_supported; then
    printf 'skip: cross-uid access needs setpriv/runuser under root\n'
    end_case
    return 0
  fi
  fake_gpu_install
  local dir="$case_tmp/x" out rc
  command mkdir -p "$dir"
  command chmod 000 "$dir"
  out="$(nvidia__assert_stage_readable "$dir" 2>&1)"; rc=$?
  check "cross-uid: assert helper exists" fn_exists nvidia__assert_stage_readable
  check "cross-uid: refuses an untraversable directory" test "$rc" -ne 0
  check "cross-uid: names readability/permissions" \
    bash -c 'grep -Eqi "not readable|not travers|permission|inaccessible|access denied" <<<"$1"' _ "$out"
  check "cross-uid: names the invoking user" bash -c 'grep -Fq "$(id -un)" <<<"$1"' _ "$out"
  rc=0
  as_unprivileged bash -c '[[ -r "$1" && -x "$1" ]]' _ "$dir" || rc=$?
  check "cross-uid: probe as an unprivileged user is denied" test "$rc" -ne 0
  command chmod 700 "$dir"
  end_case
}

# ===========================================================================
# Phase 3 (staging-dir permissions) -- RED: fail-closed stage consumers
# ===========================================================================
case_validate_closure_unreadable() {
  begin_case
  if ! unreadable_probe_supported; then
    printf 'skip: unreadable-dir coverage needs setpriv/runuser under root\n'
    end_case
    return 0
  fi
  fake_gpu_install
  local dir="$case_tmp/closure" out rc
  command mkdir -p "$dir"
  : >"$dir/nvidia-open-3:620.70.06-1.el9.x86_64.rpm"
  command chmod 000 "$dir"
  out="$(nvidia__validate_closure "$dir" 2>&1)"; rc=$?
  check "closure unreadable: fails" test "$rc" -ne 0
  check "closure unreadable: names readability/permissions" \
    bash -c 'grep -Eqi "not readable|not travers|permission|inaccessible|access denied" <<<"$1"' _ "$out"
  check "closure unreadable: names the path" bash -c 'grep -Fq "$1" <<<"$2"' _ "$dir" "$out"
  check "closure unreadable: names the invoking user" \
    bash -c 'grep -Fq "$(id -un)" <<<"$1"' _ "$out"
  command chmod 700 "$dir"
  end_case
}

case_validate_closure_empty() {
  begin_case
  fake_gpu_install
  local dir="$case_tmp/closure" out rc
  command mkdir -p "$dir"
  out="$(nvidia__validate_closure "$dir" 2>&1)"; rc=$?
  check "closure empty: fails" test "$rc" -ne 0
  check "closure empty: names [closure]" bash -c 'grep -q "\[closure\]" <<<"$1"' _ "$out"
  check "closure empty: names the path" bash -c 'grep -Fq "$1" <<<"$2"' _ "$dir" "$out"
  check "closure empty: names the invoking user" \
    bash -c 'grep -Fq "$(id -un)" <<<"$1"' _ "$out"
  check "closure empty: says empty or inaccessible" \
    bash -c 'grep -Eqi "empty|inaccessible" <<<"$1"' _ "$out"
  check "closure empty: no rpm -K" no_call '^rpm -K'
  end_case
}

case_validate_signatures_empty() {
  begin_case
  fake_gpu_install
  local dir="$case_tmp/sig" out rc
  command mkdir -p "$dir"
  out="$(nvidia__validate_signatures "$SUDO" "$dir" 2>&1)"; rc=$?
  check "signatures empty: fails closed" test "$rc" -ne 0
  check "signatures empty: names [closure]" bash -c 'grep -q "\[closure\]" <<<"$1"' _ "$out"
  check "signatures empty: no rpm -K" no_call '^rpm -K'
  end_case
}

case_assert_staged_versions_empty() {
  begin_case
  fake_gpu_install
  local dir="$case_tmp/ver" out rc
  command mkdir -p "$dir"
  out="$(nvidia__assert_staged_versions "$SUDO" "$dir" 2>&1)"; rc=$?
  check "staged versions empty: fails closed" test "$rc" -ne 0
  check "staged versions empty: no rpm -qp" no_call '^rpm -qp'
  end_case
}

case_payload_has_running_module_empty() {
  begin_case
  fake_gpu_install
  local dir="$case_tmp/mod" out rc
  command mkdir -p "$dir"
  out="$(nvidia__staged_payload_has_running_module "$SUDO" "$dir" 2>&1)"; rc=$?
  check "running module empty: fails closed" test "$rc" -ne 0
  check "running module empty: names [kernel-module]" \
    bash -c 'grep -q "\[kernel-module\]" <<<"$1"' _ "$out"
  end_case
}

case_payload_has_gsp_unreadable() {
  begin_case
  if ! unreadable_probe_supported; then
    printf 'skip: unreadable-dir coverage needs setpriv/runuser under root\n'
    end_case
    return 0
  fi
  command rm -f "$NVIDIA_FIRMWARE_ROOT/nvidia/620.70.06/gsp_tu10x.bin"
  fake_gpu_install
  local dir="$case_tmp/gsp" out rc
  command mkdir -p "$dir"
  : >"$dir/nvidia-open-3:620.70.06-1.el9.x86_64.rpm"
  command chmod 000 "$dir"
  out="$(nvidia__staged_payload_has_gsp "$SUDO" "$dir" 2>&1)"; rc=$?
  check "gsp unreadable: fails closed" test "$rc" -ne 0
  check "gsp unreadable: names [kernel-module] and access" \
    bash -c 'grep -q "\[kernel-module\]" <<<"$1" && grep -Eqi "not readable|not travers|permission|inaccessible|access denied" <<<"$1"' _ "$out"
  check "gsp unreadable: no rpm -qlp" no_call '^rpm -qlp'
  command chmod 700 "$dir"
  end_case
}

case_payload_has_gsp_host_firmware_short_circuit() {
  begin_case
  fake_gpu_install
  local dir="$case_tmp/gsp" out rc
  command mkdir -p "$dir"
  : >"$dir/nvidia-open-3:620.70.06-1.el9.x86_64.rpm"
  command chmod 000 "$dir"
  # begin_case seeded the host firmware; success must not read the stage.
  out="$(nvidia__staged_payload_has_gsp "$SUDO" "$dir" 2>&1)"; rc=$?
  check "gsp short-circuit: succeeds from host firmware" test "$rc" -eq 0
  check "gsp short-circuit: never queries the stage" no_call '^rpm -qlp'
  command chmod 700 "$dir"
  end_case
}

case_dkms_prereqs_unreadable() {
  begin_case
  if ! unreadable_probe_supported; then
    printf 'skip: unreadable-dir coverage needs setpriv/runuser under root\n'
    end_case
    return 0
  fi
  export FAKE_DKMS_TOOL_MISSING=1 FAKE_KERNEL_DEVEL_MISSING=1 FAKE_KERNEL_HEADERS_MISSING=1
  fake_gpu_install
  local dir="$case_tmp/dkms" out rc
  command mkdir -p "$dir"
  : >"$dir/nvidia-open-3:620.70.06-1.el9.x86_64.rpm"
  command chmod 000 "$dir"
  out="$(nvidia__ensure_dkms_prereqs "$SUDO" "$dir" 2>&1)"; rc=$?
  check "dkms prereqs unreadable: fails closed" test "$rc" -ne 0
  check "dkms prereqs unreadable: names [kernel-module] and access" \
    bash -c 'grep -q "\[kernel-module\]" <<<"$1" && grep -Eqi "not readable|not travers|permission|inaccessible|access denied" <<<"$1"' _ "$out"
  check "dkms prereqs unreadable: no package install" no_call '^dnf install'
  command chmod 700 "$dir"
  end_case
}

case_register_dkms_source_unreadable() {
  begin_case
  if ! unreadable_probe_supported; then
    printf 'skip: unreadable-dir coverage needs setpriv/runuser under root\n'
    end_case
    return 0
  fi
  fake_gpu_install
  local dir="$case_tmp/dkmssrc" out rc
  command mkdir -p "$dir"
  : >"$dir/nvidia-open-3:620.70.06-1.el9.x86_64.rpm"
  command rm -f "$NVIDIA_DKMS_SRC_ROOT/nvidia-open-620.70.06/dkms.conf"
  command chmod 000 "$dir"
  out="$(nvidia__register_dkms_source "$SUDO" "$dir" 2>&1)"; rc=$?
  check "register dkms source unreadable: fails closed" test "$rc" -ne 0
  check "register dkms source unreadable: names readability/access" \
    bash -c 'grep -Eqi "not readable|not travers|permission|inaccessible|access denied" <<<"$1"' _ "$out"
  check "register dkms source unreadable: no rpm2cpio/cpio" \
    bash -c '! grep -Eq "^(rpm2cpio|cpio) " "$1"' _ "$FAKE_GPU_CALLS"
  command chmod 700 "$dir"
  end_case
}

case_stage_consumer_matrix() {
  begin_case
  fake_gpu_install
  local state dir out rc fn tag spec
  for state in missing empty mode0400 unreadable; do
    dir="$case_tmp/state-$state/stage"
    command rm -rf "$case_tmp/state-$state"
    command mkdir -p "$case_tmp/state-$state"
    case "$state" in
      missing) ;;
      empty) command mkdir -p "$dir" ;;
      mode0400|unreadable)
        if ! unreadable_probe_supported; then
          printf 'skip: matrix %s needs setpriv/runuser under root\n' "$state"
          continue
        fi
        command mkdir -p "$dir"
        : >"$dir/nvidia-open-3:620.70.06-1.el9.x86_64.rpm"
        if [[ "$state" == "mode0400" ]]; then command chmod 0400 "$dir"; else command chmod 000 "$dir"; fi
        ;;
    esac
    for spec in \
      'nvidia__validate_closure:closure' \
      'nvidia__validate_signatures:closure' \
      'nvidia__assert_staged_versions:closure' \
      'nvidia__staged_payload_has_running_module:kernel-module'; do
      fn="${spec%%:*}"
      tag="${spec##*:}"
      case "$fn" in
        nvidia__validate_closure) out="$("$fn" "$dir" 2>&1)"; rc=$? ;;
        *) out="$("$fn" "$SUDO" "$dir" 2>&1)"; rc=$? ;;
      esac
      check "matrix($state): $fn fails closed" test "$rc" -ne 0
      check "matrix($state): $fn names [$tag]" \
        bash -c 'grep -Fq "$1" <<<"$2"' _ "[$tag]" "$out"
    done
    out="$(nvidia__assert_stage_readable "$dir" 2>&1)"; rc=$?
    check "matrix($state): assert-stage-readable refuses" test "$rc" -ne 0
    check "matrix($state): assert-stage-readable names access" \
      bash -c 'grep -Eqi "not readable|not travers|permission|inaccessible|access denied" <<<"$1"' _ "$out"
    command chmod 755 "$dir" 2>/dev/null || true
  done

  # Shared staging helpers must not report "no match" as usable on an
  # unreadable stage; live callers must be behind the guard above.
  dir="$case_tmp/generic"
  command mkdir -p "$dir"
  : >"$dir/nvidia-open-3:620.70.06-1.el9.x86_64.rpm"
  command chmod 000 "$dir"
  rc=0; nvidia__staged_dkms_has_conf "$SUDO" "$dir" >/dev/null 2>&1 || rc=$?
  check "matrix(unreadable): staged_dkms_has_conf does not succeed" test "$rc" -ne 0
  rc=0; nvidia__staged_rpm "$dir" '*.rpm' >/dev/null 2>&1 || rc=$?
  check "matrix(unreadable): staged_rpm does not succeed" test "$rc" -ne 0
  rc=0; nvidia__staged_dkms_rpm "$dir" >/dev/null 2>&1 || rc=$?
  check "matrix(unreadable): staged_dkms_rpm does not succeed" test "$rc" -ne 0
  rc=0; nvidia__staged_has_glob "$dir" '*.rpm' || rc=$?
  check "matrix(unreadable): staged_has_glob does not succeed" test "$rc" -ne 0
  command chmod 755 "$dir" 2>/dev/null || true
  end_case
}

case_failed_validation_no_destructive_actions() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_DNF_EMPTY=1
  fake_gpu_install
  local rc
  nvidia_ensure_driver_floor >/dev/null 2>&1; rc=$?

  check "no destructive on empty stage: fails" test "$rc" -ne 0
  check "no destructive on empty stage: no nvidia-uninstall" no_call 'nvidia-uninstall'
  check "no destructive on empty stage: no offline install" no_call '^dnf install .*--allowerasing'
  check "no destructive on empty stage: no resume marker" \
    bash -c '[[ ! -e "$1" ]]' _ "$NVIDIA_RESUME_MARKER"
  end_case
}

case_parent_ancestor_unreadable() {
  begin_case
  if ! unreadable_probe_supported; then
    printf 'skip: unreadable-parent coverage needs setpriv/runuser under root\n'
    end_case
    return 0
  fi
  fake_gpu_install
  local parent="$case_tmp/root-only" dir="$case_tmp/root-only/stage" out rc
  command mkdir -p "$dir"
  command chmod 755 "$dir"
  command chmod 0000 "$parent"
  out="$(nvidia__assert_stage_readable "$dir" 2>&1)"; rc=$?
  check "parent unreadable: fails closed" test "$rc" -ne 0
  check "parent unreadable: names the non-traversable component" \
    bash -c 'grep -Fq "$1" <<<"$2"' _ "$parent" "$out"
  check "parent unreadable: names readability/access" \
    bash -c 'grep -Eqi "not readable|not travers|permission|inaccessible|access denied" <<<"$1"' _ "$out"
  command chmod 755 "$parent"
  end_case
}

# ===========================================================================
# Phase 6 -- exact staging contract, errexit safety, resume, versionlock, DNF
# ===========================================================================
# The required NEVRA token must be requested exactly once (no duplicate token
# and no accidental second transaction for the required package).
case_stage_required_token_once() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  fake_gpu_install
  nvidia_ensure_driver_floor >/dev/null 2>&1; local rc=$?
  local line token='nvidia-open-3:620.70.06-1.el9'
  line="$(grep -E '^dnf install .*--downloadonly' "$FAKE_GPU_CALLS")"

  check "stage contract: exits 0" test "$rc" -eq 0
  check "stage contract: requires --downloadonly" bash -c 'grep -q -- "--downloadonly" <<<"$1"' _ "$line"
  check "stage contract: requires --destdir" bash -c 'grep -q -- "--destdir" <<<"$1"' _ "$line"
  check "stage contract: required NEVRA token appears exactly once" \
    bash -c '[[ "$(grep -oF "$1" <<<"$2" | wc -l | tr -d " ")" == "1" ]]' _ "$token" "$line"
  check "stage contract: never uses dnf download" no_call '^dnf download'
  end_case
}

# A failed stage must remove its tmp dir and, when no previous stage existed,
# leave no final stage directory behind.
case_failed_stage_no_previous() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_DNF_EMPTY=1
  fake_gpu_install
  local out="$case_tmp/out" err="$case_tmp/err" rc
  nvidia_ensure_driver_floor >"$out" 2>"$err"; rc=$?

  check "failed stage (no previous): fails" test "$rc" -ne 0
  check "failed stage (no previous): prints [closure]" bash -c 'grep -q "\[closure\]" "$1"' _ "$err"
  check "failed stage (no previous): removes temp dirs" \
    bash -c '[[ -z "$(compgen -G "$1.tmp.*")" ]]' _ "$NVIDIA_STAGE_DIR"
  check "failed stage (no previous): leaves no stage dir" bash -c '[[ ! -e "$1" ]]' _ "$NVIDIA_STAGE_DIR"
  check "failed stage (no previous): no uninstall" no_call 'nvidia-uninstall'
  check "failed stage (no previous): no offline install" no_call '^dnf install .*--allowerasing'
  end_case
}

# A failed stage must preserve a pre-existing stage directory and its contents.
case_failed_stage_preserves_previous() {
  begin_case
  command mkdir -p "$NVIDIA_STAGE_DIR"
  : >"$NVIDIA_STAGE_DIR/previous-rpm.txt"
  local evidence="$NVIDIA_STAGE_DIR/previous-rpm.txt"
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_DNF_EMPTY=1
  fake_gpu_install
  local out="$case_tmp/out" err="$case_tmp/err" rc
  nvidia_ensure_driver_floor >"$out" 2>"$err"; rc=$?

  check "failed stage (previous): fails" test "$rc" -ne 0
  check "failed stage (previous): prints [closure]" bash -c 'grep -q "\[closure\]" "$1"' _ "$err"
  check "failed stage (previous): preserves the pre-existing stage" test -f "$evidence"
  check "failed stage (previous): removes temp dirs" \
    bash -c '[[ -z "$(compgen -G "$1.tmp.*")" ]]' _ "$NVIDIA_STAGE_DIR"
  check "failed stage (previous): leaves no .bak" test ! -e "${NVIDIA_STAGE_DIR}.bak"
  end_case
}

# The stage-failure path must be safe under `set -euo pipefail`: cleanup must not
# abort before the intended [closure] diagnostic is printed.
case_stage_failure_under_errexit() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 FAKE_DNF_EMPTY=1
  fake_gpu_install
  local out="$case_tmp/out" err="$case_tmp/err" rc
  bash -euo pipefail -c '
    source "$1"
    nvidia__stage_closure "$SUDO"
  ' _ "$script_dir/lib/nvidia.sh" >"$out" 2>"$err"; rc=$?

  check "errexit: stage failure returns nonzero" test "$rc" -ne 0
  check "errexit: intended [closure] diagnostic is emitted" \
    bash -c 'grep -q "\[closure\]" "$1"' _ "$err"
  check "errexit: diagnostic is not masked by cleanup" \
    bash -c 'grep -Eqi "staged closure|empty or inaccessible|no staged" "$1"' _ "$err"
  check "errexit: no temp dirs left" \
    bash -c '[[ -z "$(compgen -G "$1.tmp.*")" ]]' _ "$NVIDIA_STAGE_DIR"
  end_case
}

# The resume marker is written to a temp file and atomically renamed; it records
# every field the resume path reads.
case_resume_marker_atomic_write() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_FABRICMANAGER_UNIT=0 FAKE_PERSISTENCED_UNIT=1 FAKE_PERSISTENCED_ACTIVE=1
  fake_gpu_install
  # Fail after the marker is written so it survives for inspection.
  export FAKE_DNF_RC=1
  nvidia_ensure_driver_floor >/dev/null 2>&1; local rc=$?

  check "marker atomic: post-drain failure keeps the marker" test "$rc" -ne 0
  check "marker atomic: written to a temp file first" \
    has_call 'mktemp .*driver-upgrade\.state\.tmp\.'
  check "marker atomic: installed with an atomic rename" \
    has_call '^sudo mv -f .*driver-upgrade\.state\.tmp\..* .*driver-upgrade\.state$'
  check "marker atomic: all fields recorded" \
    bash -c 'grep -q "^fabricmanager_was_active=" "$1" && grep -q "^fabricmanager_pkg_staged=" "$1" && grep -q "^persistenced_was_active=" "$1"' \
    _ "$NVIDIA_RESUME_MARKER"
  end_case
}

# A truncated/missing-field marker must not recapture post-drain state as
# inactive: it restores persistenced conservatively and warns.
case_resume_truncated_marker_restores_persistenced() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_FABRICMANAGER_UNIT=0 FAKE_PERSISTENCED_UNIT=1 FAKE_PERSISTENCED_ACTIVE=0
  printf 'driver upgrade in progress: partial\nfabricmanager_was_active=0\n' >"$NVIDIA_RESUME_MARKER"
  fake_gpu_install
  local out="$case_tmp/out" err="$case_tmp/err" rc
  nvidia_ensure_driver_floor >"$out" 2>"$err"; rc=$?

  check "truncated marker: upgrade completes" test "$rc" -eq 0
  check "truncated marker: warns about missing fields" \
    bash -c 'grep -Eqi "truncated|missing fields" "$1"' _ "$err"
  check "truncated marker: conservatively starts persistenced" \
    unit_started nvidia-persistenced.service
  check "truncated marker: marker removed after success" \
    bash -c '[[ ! -e "$1" ]]' _ "$NVIDIA_RESUME_MARKER"
  end_case
}

# Marker present, 620 on disk but below-floor /proc: reload and re-verify
# instead of a second stage/install.
case_resume_on_disk_620_reloads() {
  begin_case
  export FAKE_REPORTED_DRIVER=620.70.06 FAKE_RPM_INSTALLED=1 FAKE_PROC_VERSION=595.112.07
  export FAKE_FABRICMANAGER_UNIT=0 FAKE_PERSISTENCED_UNIT=1 FAKE_PERSISTENCED_ACTIVE=0
  printf 'driver upgrade in progress: test\nfabricmanager_was_active=0\nfabricmanager_pkg_staged=0\npersistenced_was_active=0\n' >"$NVIDIA_RESUME_MARKER"
  fake_gpu_install
  local out="$case_tmp/out" err="$case_tmp/err" rc
  nvidia_ensure_driver_floor >"$out" 2>"$err"; rc=$?

  check "resume on-disk 620: exits 0" test "$rc" -eq 0
  check "resume on-disk 620: runs depmod -a" has_call 'depmod -a'
  check "resume on-disk 620: loads the module" has_call 'modprobe nvidia$'
  check "resume on-disk 620: re-verifies the loaded version" procs_620
  check "resume on-disk 620: no re-stage" no_call '^dnf install .*--downloadonly'
  check "resume on-disk 620: no second offline install" no_call '^dnf install .*--allowerasing'
  check "resume on-disk 620: no uninstall" no_call 'nvidia-uninstall'
  check "resume on-disk 620: marker removed" bash -c '[[ ! -e "$1" ]]' _ "$NVIDIA_RESUME_MARKER"
  end_case
}

# Versionlock backup failure is a hard [closure] error and leaves nothing behind.
case_versionlock_backup_failure_aborts() {
  begin_case
  fake_gpu_install
  local vl="$case_tmp/versionlock.list" out="$case_tmp/out" err="$case_tmp/err" rc
  printf 'nvidia-fabricmanager-595.112.07-1.el9.x86_64\nkeep-this-package\n' >"$vl"
  export NVIDIA_VERSIONLOCK_FILE="$vl" FAKE_VERSIONLOCK_CP_RC=1
  nvidia__versionlock_clear "$SUDO" >"$out" 2>"$err"; rc=$?

  check "versionlock backup failure: aborts" test "$rc" -ne 0
  check "versionlock backup failure: prints [closure]" bash -c 'grep -q "\[closure\]" "$1"' _ "$err"
  check "versionlock backup failure: names the backup" \
    bash -c 'grep -Eqi "back up|backup" "$1"' _ "$err"
  check "versionlock backup failure: no .nvidia-upgrade.* survives" \
    bash -c '[[ -z "$(compgen -G "$1.nvidia-upgrade.*")" ]]' _ "$vl"
  end_case
}

# A failed filtered write restores the backup and aborts with [closure].
case_versionlock_write_failure_aborts() {
  begin_case
  fake_gpu_install
  local vl="$case_tmp/versionlock.list" out="$case_tmp/out" err="$case_tmp/err" rc
  printf 'nvidia-fabricmanager-595.112.07-1.el9.x86_64\nkeep-this-package\n' >"$vl"
  export NVIDIA_VERSIONLOCK_FILE="$vl" FAKE_VERSIONLOCK_TEE_RC=1
  nvidia__versionlock_clear "$SUDO" >"$out" 2>"$err"; rc=$?

  check "versionlock write failure: aborts" test "$rc" -ne 0
  check "versionlock write failure: prints [closure]" bash -c 'grep -q "\[closure\]" "$1"' _ "$err"
  check "versionlock write failure: names the filtered write" \
    bash -c 'grep -Eqi "filter|write" "$1"' _ "$err"
  check "versionlock write failure: original file restored" \
    bash -c 'grep -q "nvidia-fabricmanager-595" "$1"' _ "$vl"
  check "versionlock write failure: no .nvidia-upgrade.* survives" \
    bash -c '[[ -z "$(compgen -G "$1.nvidia-upgrade.*")" ]]' _ "$vl"
  end_case
}

# Restore uses the passed sudo_cmd, restores an earlier backup before taking a
# new one, and leaves no backup after the final restore.
case_versionlock_restore_semantics() {
  begin_case
  fake_gpu_install
  local vl="$case_tmp/versionlock.list" first_count second_count rc1 rc2 rc3
  printf 'nvidia-fabricmanager-595.112.07-1.el9.x86_64\nkeep-this-package\n' >"$vl"
  export NVIDIA_VERSIONLOCK_FILE="$vl"

  nvidia__versionlock_clear "$SUDO" >/dev/null 2>&1; rc1=$?
  first_count="$(compgen -G "$vl.nvidia-upgrade.*" | wc -l | tr -d ' ')"
  nvidia__versionlock_clear "$SUDO" >/dev/null 2>&1; rc2=$?
  second_count="$(compgen -G "$vl.nvidia-upgrade.*" | wc -l | tr -d ' ')"
  nvidia__versionlock_restore; rc3=$?

  check "versionlock restore: first clear succeeds" test "$rc1" -eq 0
  check "versionlock restore: first clear leaves one backup" test "$first_count" -eq 1
  check "versionlock restore: second clear succeeds" test "$rc2" -eq 0
  check "versionlock restore: earlier backup replaced, not stacked" test "$second_count" -eq 1
  check "versionlock restore: restore succeeds" test "$rc3" -eq 0
  check "versionlock restore: no backup survives restore" \
    bash -c '[[ -z "$(compgen -G "$1.nvidia-upgrade.*")" ]]' _ "$vl"
  check "versionlock restore: uses the passed sudo_cmd" \
    has_call '^sudo cp -p .*\.nvidia-upgrade\.'
  check "versionlock restore: original lock line restored" \
    bash -c 'grep -q "nvidia-fabricmanager-595" "$1"' _ "$vl"
  end_case
}

# A successful upgrade restores the versionlock file and leaves no backup.
case_versionlock_no_backup_left_on_success() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_FABRICMANAGER_UNIT=1 FAKE_FABRICMANAGER_ACTIVE=1
  export FAKE_FABRICMANAGER_FRAGMENT=/usr/lib/systemd/system/nvidia-fabricmanager.service
  export FAKE_UNIT_OWNER_FABRICMANAGER=nvidia-fabricmanager-595.112.07-1.el9.x86_64
  export FAKE_REPOQUERY_FABRICMANAGER=620.70.06-1.el9
  export FAKE_PERSISTENCED_UNIT=0
  local vl="$case_tmp/versionlock.list"
  printf 'nvidia-fabricmanager-595.112.07-1.el9.x86_64\nkeep-this-package\n' >"$vl"
  export NVIDIA_VERSIONLOCK_FILE="$vl"
  fake_gpu_install
  nvidia_ensure_driver_floor >/dev/null 2>&1; local rc=$?

  check "versionlock success: upgrade exits 0" test "$rc" -eq 0
  check "versionlock success: no .nvidia-upgrade.* survives" \
    bash -c '[[ -z "$(compgen -G "$1.nvidia-upgrade.*")" ]]' _ "$vl"
  check "versionlock success: original lock file restored" \
    bash -c 'grep -q "nvidia-fabricmanager-595" "$1"' _ "$vl"
  end_case
}

# A DNF lock/stale-metadata failure must surface the captured stderr plus
# actionable recovery guidance.
case_dnf_lock_metadata_diagnostic() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
  export FAKE_DNF_DOWNLOADONLY_RC=1
  export FAKE_DNF_STAGE_STDERR='Error: failed to synchronize cache for repo: /var/cache/dnf/x86_64.lock is held by another process'
  fake_gpu_install
  local out="$case_tmp/out" err="$case_tmp/err" rc
  nvidia_ensure_driver_floor >"$out" 2>"$err"; rc=$?

  check "dnf lock/metadata: fails" test "$rc" -ne 0
  check "dnf lock/metadata: prints [closure]" bash -c 'grep -q "\[closure\]" "$1"' _ "$err"
  check "dnf lock/metadata: includes captured DNF stderr" \
    bash -c 'grep -q "failed to synchronize cache" "$1"' _ "$err"
  check "dnf lock/metadata: gives lock/metadata guidance" \
    bash -c 'grep -Eqi "lock|metadata" "$1" && grep -Eq "dnf clean metadata|/var/cache/dnf" "$1"' _ "$err"
  check "dnf lock/metadata: forces a fresh metadata check" \
    bash -c 'grep -E "^dnf install .*--downloadonly" "$1" | grep -q -- "--setopt=metadata_expire=0"' _ "$FAKE_GPU_CALLS"
  check "dnf lock/metadata: no uninstall" no_call 'nvidia-uninstall'
  check "dnf lock/metadata: no offline install" no_call '^dnf install .*--allowerasing'
  check "dnf lock/metadata: no marker" bash -c '[[ ! -e "$1" ]]' _ "$NVIDIA_RESUME_MARKER"
  end_case
}

# Stage-only inspection must stop after staging + validation: no resume marker,
# no drain, no uninstall, and no offline install.
case_stage_only_no_driver_action() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1 NVIDIA_STAGE_ONLY=1
  fake_gpu_install
  local out="$case_tmp/out" err="$case_tmp/err" rc
  nvidia_ensure_driver_floor >"$out" 2>"$err"; rc=$?

  check "stage-only: exits 0" test "$rc" -eq 0
  check "stage-only: announces stage-only mode" bash -c 'grep -q "stage-only" "$1"' _ "$out"
  check "stage-only: stages the required closure" \
    stage_has_package 'nvidia-open-3:620.70.06-1.el9'
  check "stage-only: leaf is 755" test "$(stage_dir_mode)" = "755"
  check "stage-only: stage is accessible" stage_dir_accessible
  check "stage-only: no resume marker" bash -c '[[ ! -e "$1" ]]' _ "$NVIDIA_RESUME_MARKER"
  check "stage-only: no systemctl stop" no_call 'systemctl stop'
  check "stage-only: no nvidia-uninstall" no_call 'nvidia-uninstall'
  check "stage-only: no offline install" no_call '^dnf install .*--allowerasing'
  end_case
}

case_upgrade
case_noop
case_newer
case_package_missing
case_uninstall_failure
case_rmmod_busy
case_still_below_floor
case_no_smi_binary
case_smi_nonzero
case_run_managed_upgrade
case_arm64_nevra
case_dcgm_holder
case_repo_ready
case_repo_arm64
case_repo_missing_key
case_closure_stage
case_closure_incomplete
case_offline_install
case_stage_before_swap
case_arm64_closure
case_loaded_version_mismatch
case_verify_uses_proc
case_disk_620_proc_absent
case_full_rmmod
case_dkms_cleanup
case_kmod_vs_dkms
case_modprobe_uvm
case_gpu_init
case_resume_marker

# Phase 3 (closure fix) -- optional unit availability
case_fabricmanager_absent_does_not_block
case_fabricmanager_available_is_included
case_persistenced_non_rpm_available
case_persistenced_non_rpm_absent
case_optional_repoquery_transient_failure
case_required_stage_failure
case_no_optional_units
case_fabricmanager_unit_absent
case_failed_host_reproduction
case_repoquery_multiple_or_below_floor
case_stage_no_empty_extra_arg
case_stdout_stderr_separation
case_repoquery_flag_shape

# Phase 4 (closure fix) -- restore only active units, resume state
case_fabricmanager_inactive_not_restarted
case_fabricmanager_active_restored
case_fabricmanager_start_failure_nonfatal
case_fabricmanager_active_but_pkg_not_staged
case_persistenced_active_restored
case_persistenced_inactive_not_restarted
case_persistenced_start_failure_fatal
case_resume_preserves_active_state
case_marker_write_failure
case_resume_at_floor_short_circuit

# Phase 5 (closure fix) -- DKMS-only payload
case_dkms_only_closure_succeeds
case_dkms_payload_missing_dkms_conf
case_dkms_tool_missing
case_dkms_tool_staged
case_dkms_kernel_headers_missing
case_dkms_build_proof_fails
case_dkms_source_registration_before_build
case_run_managed_dkms_detected
case_run_managed_dkms_remove_failure
case_kmod_host_no_dkms
case_gsp_missing
case_stale_dkms_removed_before_modinfo_gate
case_dkms_post_install_module_missing

# Phase 2 (staging-dir permissions) -- stage access contract
case_stage_dir_mode
case_stage_make_readable_helper
case_optional_stage_keeps_dir_readable
case_atomic_swap_preserves_mode
case_dnf_success_no_rpms
case_chmod_failure_removes_temp
case_optional_download_failure_warns
case_cross_uid_access

# Phase 3 (staging-dir permissions) -- fail-closed stage consumers
case_validate_closure_unreadable
case_validate_closure_empty
case_validate_signatures_empty
case_assert_staged_versions_empty
case_payload_has_running_module_empty
case_payload_has_gsp_unreadable
case_payload_has_gsp_host_firmware_short_circuit
case_dkms_prereqs_unreadable
case_register_dkms_source_unreadable
case_stage_consumer_matrix
case_failed_validation_no_destructive_actions
case_parent_ancestor_unreadable
case_stage_required_token_once
case_failed_stage_no_previous
case_failed_stage_preserves_previous
case_stage_failure_under_errexit
case_resume_marker_atomic_write
case_resume_truncated_marker_restores_persistenced
case_resume_on_disk_620_reloads
case_versionlock_backup_failure_aborts
case_versionlock_write_failure_aborts
case_versionlock_restore_semantics
case_versionlock_no_backup_left_on_success
case_dnf_lock_metadata_diagnostic
case_stage_only_no_driver_action

if [[ "$failures" -ne 0 ]]; then
  printf '\n%d failure(s)\n' "$failures" >&2
  exit 1
fi
printf '\nall setup-driver tests passed\n'
