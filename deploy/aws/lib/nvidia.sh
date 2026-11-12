#!/usr/bin/env bash
# lib/nvidia.sh -- the NVIDIA driver-floor contract for the strimserver host.
#
# Sourced by deploy/aws/setup-gpu.sh (and exercised directly by
# deploy/aws/setup_driver_test.sh). It answers three questions:
#
#   1. what driver is installed?  (marker -> modinfo -> rpm -> nvidia-smi)
#   2. is it at least the floor? (numeric component compare)
#   3. if not, raise it safely (stage -> swap -> reload -> verify).
#
# Contract
# --------
#   NVIDIA_DRIVER_FLOOR   exact floor, 620.70.06 (CUDA 13.5 requires R620;
#                         there is zero headroom below it)
#   NVIDIA_OPEN_NEVRA     amd64 RPM identity, nvidia-open-3:620.70.06-1.el9
#   NVIDIA_ARM64_NEVRA    arm64 RPM identity, nvidia-open-620.70.06-1.amzn2023.noarch
#   NVIDIA_CUDA_REPO      NVIDIA CUDA repo (rhel9/x86_64) documenting the RPM
#
# 620 open modules support Turing (T4/T4G, sm_75) and require GSP firmware
# (gsp_tu10x.bin); never disable GSP with NVreg_EnableGpuFirmware=0.
#
# Failure-state table (each maps to a distinct `nvidia: ERROR [state]` message)
# --------------------------------------------------------------------------
#   [package]   `dnf download` failed / staged RPM missing / NEVRA or signature
#               mismatch. Nothing has been uninstalled yet. Recovery:
#                 sudo dnf download --destdir /mnt/nvme/nvidia-rpm <NEVRA>
#   [uninstall] `nvidia-uninstall -s` failed on a .run-managed host; the old
#               driver is still installed. Recovery: re-run nvidia-uninstall.
#   [install]   `dnf install --allowerasing` failed after staging. Recovery:
#                 sudo dnf install -y --allowerasing /mnt/nvme/nvidia-rpm/nvidia-open-*.rpm
#   [depmod]    `depmod -a` failed; the new module graph is incomplete.
#   [holders]   a process still holds /dev/nvidia* after the drain stops.
#               Recovery: `sudo fuser -v /dev/nvidia*`, stop the listed PIDs.
#   [rmmod]     a kernel module is still in use after the drain. Recovery:
#                 sudo fuser -v /dev/nvidia* ; sudo lsmod | grep nvidia
#   [modprobe]  the 620 module fails to load (firmware/ABI). Recovery:
#                 sudo depmod -a && sudo modprobe nvidia ; sudo dmesg | tail
#   [gsp]       gsp_tu10x.bin is missing under the 620 firmware dir; 620 open
#               modules cannot initialize Turing without GSP.
#   [verify]    after the swap the reported driver is still below the floor.
#
# The function never reboots: reboot-based resume belongs to the
# strimserver-driver-resume.service state machine, not this library.
#
# Privileged commands always go through "${SUDO:-sudo}" so tests can substitute
# the command itself (sudo's secure_path otherwise hides PATH shims).

# --- contract constants (literal assignments; a pins oracle greps them) ------
NVIDIA_DRIVER_FLOOR="620.70.06"
NVIDIA_OPEN_NEVRA="nvidia-open-3:620.70.06-1.el9"
NVIDIA_ARM64_NEVRA="nvidia-open-620.70.06-1.amzn2023.noarch"
# NVIDIA CUDA repo for RHEL9 / x86_64 (documents the pinned nvidia-open RPM):
# https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo
NVIDIA_CUDA_REPO="https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo"

# Overridable locations (tests redirect these into temp dirs).
NVIDIA_STAGE_DIR="${NVIDIA_STAGE_DIR:-/mnt/nvme/nvidia-rpm}"
NVIDIA_FIRMWARE_ROOT="${NVIDIA_FIRMWARE_ROOT:-/lib/firmware}"
NVIDIA_RESUME_MARKER="${NVIDIA_RESUME_MARKER:-/var/lib/strimserver/driver-upgrade.state}"

# --- helpers ----------------------------------------------------------------
nvidia__is_version() {
  [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)*$ ]]
}

nvidia__fail() {
  local state="$1"
  shift
  printf 'nvidia: ERROR [%s]: %s\n' "$state" "$*" >&2
}

# nvidia_driver_ge <installed> <minimum>
#   0 = installed >= minimum, 1 = installed < minimum, 2 = malformed input.
# Components are compared numerically; missing components are 0, and leading
# zeros are interpreted as decimal (not octal).
nvidia_driver_ge() {
  local installed="${1:-}" minimum="${2:-}"

  if ! nvidia__is_version "$installed"; then
    printf 'nvidia_driver_ge: not a version: %q\n' "$installed" >&2
    return 2
  fi
  if ! nvidia__is_version "$minimum"; then
    printf 'nvidia_driver_ge: not a version: %q\n' "$minimum" >&2
    return 2
  fi

  local -a have want
  IFS='.' read -r -a have <<<"$installed"
  IFS='.' read -r -a want <<<"$minimum"

  local count="${#have[@]}"
  (( ${#want[@]} > count )) && count="${#want[@]}"

  local i have_part want_part
  for ((i = 0; i < count; i++)); do
    have_part=$((10#${have[i]:-0}))
    want_part=$((10#${want[i]:-0}))
    (( have_part > want_part )) && return 0
    (( have_part < want_part )) && return 1
  done
  return 0
}

# Print the first version-looking token from nvidia-smi CSV output. An optional
# argument supplies the raw text (tests); otherwise nvidia-smi is queried.
# Headers, commas, spaces and "[N/A]" are all handled.
nvidia__first_version_token() {
  local raw="${1:-}"
  if [[ -z "$raw" ]]; then
    return 1
  fi

  local line token
  while IFS= read -r line; do
    line="${line//$'\r'/}"
    line="${line//,/ }"
    for token in $line; do
      if nvidia__is_version "$token"; then
        printf '%s\n' "$token"
        return 0
      fi
    done
  done <<<"$raw"
  return 1
}

nvidia_driver_of_smi() {
  local raw="${1:-}"
  if [[ -z "$raw" ]]; then
    raw="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null)" || return 1
  fi
  nvidia__first_version_token "$raw"
}

nvidia_compute_cap_of_smi() {
  local raw="${1:-}"
  if [[ -z "$raw" ]]; then
    raw="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null)" || return 1
  fi
  nvidia__first_version_token "$raw"
}

# --- detection precedence ---------------------------------------------------
nvidia__modinfo_version() {
  local out
  out="$(modinfo -F version nvidia 2>/dev/null)" || return 1
  nvidia__is_version "$out" || return 1
  printf '%s\n' "$out"
}

nvidia__rpm_version() {
  local out
  out="$(rpm -q --qf '%{VERSION}' nvidia-open 2>/dev/null)" || return 1
  nvidia__is_version "$out" || return 1
  printf '%s\n' "$out"
}

nvidia__rpm_installed() {
  rpm -q nvidia-open >/dev/null 2>&1
}

nvidia__detect_installed_version() {
  local version
  if version="$(nvidia__modinfo_version)"; then
    printf '%s\n' "$version"
    return 0
  fi
  if version="$(nvidia__rpm_version)"; then
    printf '%s\n' "$version"
    return 0
  fi
  if version="$(nvidia_driver_of_smi)"; then
    printf '%s\n' "$version"
    return 0
  fi
  return 1
}

# --- upgrade phases ---------------------------------------------------------
# Resolve the pinned nvidia-open NEVRA for a machine (default: uname -m).
# x86_64 (amd64) and aarch64 (arm64) select their architecture-specific RPM;
# any other machine is a hard failure so the wrong-arch package is never staged.
nvidia__pinned_nevra() {
  local machine="${1:-$(uname -m)}"

  case "$machine" in
    x86_64)
      printf '%s\n' "$NVIDIA_OPEN_NEVRA"
      ;;
    aarch64)
      printf 'nvidia: WARNING: AL2023 generic Arm64 is outside the vendor 620 support matrix; it requires the T4G acceptance run (Gate G2)\n' >&2
      printf '%s\n' "$NVIDIA_ARM64_NEVRA"
      ;;
    *)
      nvidia__fail package "unsupported machine '$machine': no pinned nvidia-open NEVRA (expected x86_64 or aarch64)"
      return 1
      ;;
  esac
}

# Stage the pinned RPM and verify it BEFORE anything is uninstalled. A failed
# stage leaves the host untouched.
nvidia__stage_rpm() {
  local sudo_cmd="$1" rpmfile nevra expected_nevra

  expected_nevra="$(nvidia__pinned_nevra)" || return 1

  "$sudo_cmd" mkdir -p "$NVIDIA_STAGE_DIR" || {
    nvidia__fail package "could not create staging dir $NVIDIA_STAGE_DIR"
    return 1
  }

  if ! "$sudo_cmd" dnf download --destdir "$NVIDIA_STAGE_DIR" "$expected_nevra"; then
    nvidia__fail package "could not download $expected_nevra (nothing was uninstalled)"
    return 1
  fi

  rpmfile="$(ls -1 "$NVIDIA_STAGE_DIR"/nvidia-open-*.rpm 2>/dev/null | head -n1)"
  if [[ -z "$rpmfile" ]]; then
    nvidia__fail package "no staged nvidia-open RPM in $NVIDIA_STAGE_DIR"
    return 1
  fi

  nevra="$("$sudo_cmd" rpm -qp --qf '%{NEVRA}' "$rpmfile" 2>/dev/null)" || {
    nvidia__fail package "could not read the staged RPM identity: $rpmfile"
    return 1
  }
  case "$nevra" in
    *"$expected_nevra"*) ;;
    *)
      nvidia__fail package "staged RPM is $nevra, expected $expected_nevra"
      return 1
      ;;
  esac

  if ! "$sudo_cmd" rpm -K "$rpmfile" >/dev/null; then
    nvidia__fail package "staged RPM signature/digest check failed: $rpmfile"
    return 1
  fi

  printf 'nvidia: staged %s\n' "$rpmfile"
  return 0
}

nvidia__unit_exists() {
  local sudo_cmd="$1" unit="$2"
  "$sudo_cmd" systemctl cat "$unit" >/dev/null 2>&1
}

# Stop every holder of /dev/nvidia* before unloading the modules.
nvidia__drain() {
  local sudo_cmd="$1"

  if "$sudo_cmd" systemctl is-active --quiet strimserver.service; then
    "$sudo_cmd" systemctl stop strimserver.service
  fi
  if nvidia__unit_exists "$sudo_cmd" nvidia-fabricmanager.service; then
    "$sudo_cmd" systemctl stop nvidia-fabricmanager.service
  fi
  "$sudo_cmd" systemctl stop nvidia-persistenced.service
  "$sudo_cmd" systemctl stop containerd.service
}

nvidia__check_holders() {
  local sudo_cmd="$1"
  if ! command -v fuser >/dev/null 2>&1; then
    return 0
  fi
  if "$sudo_cmd" fuser -v /dev/nvidia* >/dev/null 2>&1; then
    nvidia__fail holders "processes still hold /dev/nvidia*; inspect with '$sudo_cmd fuser -v /dev/nvidia*'"
    return 1
  fi
  return 0
}

nvidia__modules_loaded() {
  local sudo_cmd="$1"
  "$sudo_cmd" lsmod 2>/dev/null | grep -q '^nvidia'
}

nvidia__restore() {
  local sudo_cmd="$1"
  "$sudo_cmd" systemctl start nvidia-persistenced.service
  if nvidia__unit_exists "$sudo_cmd" nvidia-fabricmanager.service; then
    "$sudo_cmd" systemctl start nvidia-fabricmanager.service
  fi
  # containerd is deliberately NOT restarted here: deploy.sh:127 owns the single
  # containerd restart after all GPU wiring is in place.
}

# --- the entrypoint ---------------------------------------------------------
nvidia_ensure_driver_floor() {
  local sudo_cmd="${SUDO:-sudo}"
  local installed="" rc=0

  if [[ -e "$NVIDIA_RESUME_MARKER" ]]; then
    printf 'nvidia: resume marker %s present; completing the pending upgrade\n' "$NVIDIA_RESUME_MARKER"
  else
    installed="$(nvidia__detect_installed_version || true)"
    if [[ -n "$installed" ]] && nvidia_driver_ge "$installed" "$NVIDIA_DRIVER_FLOOR"; then
      printf 'nvidia: driver %s is at or above the %s floor; nothing to do\n' \
        "$installed" "$NVIDIA_DRIVER_FLOOR"
      return 0
    fi
    printf 'nvidia: driver %s is below the %s floor; upgrading\n' \
      "${installed:-unknown}" "$NVIDIA_DRIVER_FLOOR"
  fi

  nvidia__stage_rpm "$sudo_cmd" || return 1

  # Drain every GPU holder, then confirm none survived, BEFORE the uninstall and
  # install touch the modules. The order matters: uninstalling or replacing an
  # in-use module leaves the host with a broken driver graph.
  nvidia__drain "$sudo_cmd" || {
    nvidia__fail holders "draining GPU holders failed"
    return 1
  }
  nvidia__check_holders "$sudo_cmd" || return 1

  # A .run-managed host has no nvidia-open RPM; remove that payload before the
  # RPM install so the two do not fight over the same files.
  if ! nvidia__rpm_installed && command -v nvidia-uninstall >/dev/null 2>&1; then
    printf 'nvidia: removing the .run-managed driver before the RPM swap\n'
    if ! "$sudo_cmd" nvidia-uninstall -s; then
      nvidia__fail uninstall "nvidia-uninstall -s failed; the .run driver is still installed. Re-run: $sudo_cmd nvidia-uninstall -s"
      return 1
    fi
  fi

  if ! "$sudo_cmd" dnf install -y --allowerasing "$NVIDIA_STAGE_DIR"/nvidia-open-*.rpm; then
    nvidia__fail install "dnf install failed. Recovery: $sudo_cmd dnf install -y --allowerasing $NVIDIA_STAGE_DIR/nvidia-open-*.rpm"
    return 1
  fi

  if ! "$sudo_cmd" depmod -a; then
    nvidia__fail depmod "depmod -a failed; the new module dependency graph is incomplete"
    return 1
  fi

  if ! "$sudo_cmd" rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>/dev/null; then
    if nvidia__modules_loaded "$sudo_cmd"; then
      nvidia__fail rmmod "an nvidia module is still in use. Recovery: $sudo_cmd fuser -v /dev/nvidia* ; $sudo_cmd lsmod | grep nvidia"
      return 1
    fi
    printf 'nvidia: old modules were already unloaded\n'
  fi

  if ! "$sudo_cmd" modprobe nvidia; then
    nvidia__fail modprobe "the 620 module failed to load. Recovery: $sudo_cmd depmod -a && $sudo_cmd modprobe nvidia"
    return 1
  fi

  local gsp="$NVIDIA_FIRMWARE_ROOT/nvidia/$NVIDIA_DRIVER_FLOOR/gsp_tu10x.bin"
  if [[ ! -f "$gsp" ]]; then
    nvidia__fail gsp "GSP firmware missing at $gsp; 620 open modules need GSP for Turing"
    return 1
  fi

  installed="$(nvidia__detect_installed_version || true)"
  if ! nvidia_driver_ge "$installed" "$NVIDIA_DRIVER_FLOOR"; then
    nvidia__fail verify "driver is still ${installed:-unknown} (below $NVIDIA_DRIVER_FLOOR) after the swap"
    return 1
  fi

  nvidia__restore "$sudo_cmd" || {
    nvidia__fail verify "driver $installed is installed but restoring nvidia-persistenced/fabricmanager failed"
    return 1
  }

  if [[ -e "$NVIDIA_RESUME_MARKER" ]]; then
    "$sudo_cmd" rm -f "$NVIDIA_RESUME_MARKER"
  fi

  printf 'nvidia: driver %s is at or above the %s floor\n' "$installed" "$NVIDIA_DRIVER_FLOOR"
  return "$rc"
}
