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
  case_tmp="$(mktemp -d)"
  case_path="$PATH"
  command mkdir -p "$case_tmp/fw/nvidia/620.70.06"
  : >"$case_tmp/fw/nvidia/620.70.06/gsp_tu10x.bin"
  export NVIDIA_STAGE_DIR="$case_tmp/stage"
  export NVIDIA_FIRMWARE_ROOT="$case_tmp/fw"
  export NVIDIA_RESUME_MARKER="$case_tmp/driver-upgrade.state"
  export NVIDIA_PROC_VERSION_FILE="$case_tmp/proc-version"
  export NVIDIA_DEVICE_NODE="$case_tmp/nvidia0"
  export SUDO=fake-sudo
}

end_case() {
  fake_gpu_cleanup
  PATH="$case_path"
  command rm -rf "$case_tmp"
  unset NVIDIA_STAGE_DIR NVIDIA_FIRMWARE_ROOT NVIDIA_RESUME_MARKER \
    NVIDIA_PROC_VERSION_FILE NVIDIA_DEVICE_NODE SUDO NVIDIA_DRAIN_TIMEOUT \
    FAKE_REPORTED_DRIVER FAKE_PROC_VERSION FAKE_PROC_VERSION_STUCK FAKE_RPM_INSTALLED \
    FAKE_RUN_MANAGED FAKE_UNINSTALL_RC FAKE_RMMOD_BUSY FAKE_DNF_RC \
    FAKE_DNF_DOWNLOADONLY_RC FAKE_DNF_CLOSURE_INCOMPLETE FAKE_DNF_KEY_MISSING \
    FAKE_DNF_UPGRADES_DRIVER FAKE_PKG_AVAILABLE FAKE_SMI_RC FAKE_SMI_MISSING \
    FAKE_MODPROBE_RC FAKE_MODULE_LOADED FAKE_MODULES FAKE_STRIMSERVER_ACTIVE \
    FAKE_FABRICMANAGER_UNIT FAKE_DCGM_UNIT FAKE_DCGM_EXPORTER_UNIT FAKE_DCGM_ACTIVE \
    FAKE_DCGM_EXPORTER_ACTIVE FAKE_DCGM_STUCK FAKE_DCGM_EXPORTER_STUCK \
    FAKE_ARCH FAKE_KERNEL_RELEASE FAKE_NEVRA FAKE_HOLDER FAKE_KERNEL_MODULE_VARIANT \
    FAKE_DKMS_STATUS FAKE_DKMS_RC FAKE_PAYLOAD_MISSING_MODULE
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

# --- 1. upgrade path (RPM installed, below floor) ----------------------------
case_upgrade() {
  begin_case
  export FAKE_REPORTED_DRIVER=610.0.0 FAKE_RPM_INSTALLED=1
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

if [[ "$failures" -ne 0 ]]; then
  printf '\n%d failure(s)\n' "$failures" >&2
  exit 1
fi
printf '\nall setup-driver tests passed\n'
