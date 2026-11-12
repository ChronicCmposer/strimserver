#!/usr/bin/env bash
# lib/nvidia.sh -- the NVIDIA driver-floor contract for the strimserver host.
#
# Sourced by deploy/aws/setup-gpu.sh (and exercised directly by
# deploy/aws/setup_driver_test.sh). It answers three questions:
#
#   1. what driver is installed?  (proc -> modinfo -> rpm -> nvidia-smi)
#   2. is it at least the floor? (numeric component compare)
#   3. if not, raise it safely (repo -> stage closure -> swap -> reload -> verify).
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
# Two version readers, deliberately separate
# -----------------------------------------
#   nvidia__proc_version              STRICT reader of the loaded-module version
#                                     from /proc/driver/nvidia/version. No
#                                     fallback: verification must never report an
#                                     unloaded on-disk module as healthy.
#   nvidia__detect_installed_version  pre-swap DETECTOR with precedence
#                                     proc -> modinfo -> rpm -> nvidia-smi. Used
#                                     only to decide no-op vs upgrade.
#
# Failure-state table (each maps to a distinct `nvidia: ERROR [state]` message)
# --------------------------------------------------------------------------
#   [repo]      per-arch CUDA repo could not be added or its signing key could
#               not be imported. Nothing has been uninstalled; `rpm -K` and the
#               offline install would fail without the key. Recovery: import the
#               key manually (`sudo rpm --import <url>`) then re-run.
#   [closure]   dnf could not stage the FULL 620 dependency closure, a staged
#               RPM failed `rpm -K`, or a required package is missing. Nothing
#               has been uninstalled. Recovery: `sudo dnf install -y
#               --downloadonly --disableexcludes=all --destdir <dir>
#               <NEVRA>` and inspect.
#   [kernel-module] the staged payload has no nvidia.ko for the RUNNING kernel,
#               or the installed module is not 620 for `uname -r`. The old
#               driver is never removed first. Recovery: verify
#               `modinfo -k $(uname -r) nvidia` and the kernel-devel match.
#   [uninstall] `nvidia-uninstall -s` failed on a .run-managed host; the old
#               driver is still installed. Recovery: re-run nvidia-uninstall.
#   [install]   the offline `dnf install` failed after staging. Recovery:
#                 sudo dnf install -y --allowerasing --disableexcludes=all \
#                   --disablerepo='*' /mnt/nvme/nvidia-rpm/*.rpm
#   [depmod]    `depmod -a` failed; the new module graph is incomplete.
#   [dkms]      `dkms remove nvidia-open/<old> --all` failed; a stale 595 build
#               may still shadow the new module.
#   [drain]     the DCGM units did not stop within the drain timeout.
#               Recovery: `sudo systemctl stop nvidia-dcgm-exporter nvidia-dcgm`.
#   [holders]   a process still holds /dev/nvidia* after the drain stops.
#               Recovery: `sudo fuser -v /dev/nvidia*`, stop the listed PIDs.
#   [rmmod]     a kernel module is still in use after the drain. Recovery:
#                 sudo fuser -v /dev/nvidia* ; sudo lsmod | grep nvidia
#   [modprobe]  the 620 module fails to load (firmware/ABI). Recovery:
#                 sudo depmod -a && sudo modprobe nvidia ; sudo dmesg | tail
#   [gsp]       gsp_tu10x.bin is missing under the 620 firmware dir; 620 open
#               modules cannot initialize Turing without GSP.
#   [verify]    after the swap the loaded driver is still below the floor, or
#               nvidia-smi / /dev/nvidia0 show the GPU did not initialize.
#   [rollback] / [resume] are not error states: on any post-marker failure the
#               resume marker is left in place and the operator is told to
#               re-run setup-gpu.sh (resume) or restore the previous driver
#               (rollback). No `strimserver-driver-resume.service` exists; the
#               marker is a plain file and resume is a manual re-run.
#
# The function never reboots.
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
NVIDIA_CUDA_REPO_ARM64="https://developer.download.nvidia.com/compute/cuda/repos/amzn2023/sbsa/cuda-amzn2023.repo"
# NVIDIA CUDA GPG signing keys (the repo's key; import before rpm -K/install).
NVIDIA_CUDA_KEY="https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/D42D0685.pub"
NVIDIA_CUDA_KEY_ARM64="https://developer.download.nvidia.com/compute/cuda/repos/amzn2023/sbsa/D42D0685.pub"

# Overridable locations (tests redirect these into temp dirs).
NVIDIA_STAGE_DIR="${NVIDIA_STAGE_DIR:-/mnt/nvme/nvidia-rpm}"
NVIDIA_FIRMWARE_ROOT="${NVIDIA_FIRMWARE_ROOT:-/lib/firmware}"
NVIDIA_RESUME_MARKER="${NVIDIA_RESUME_MARKER:-/var/lib/strimserver/driver-upgrade.state}"
# Strict loaded-version source; tests point this at a fake file.
NVIDIA_PROC_VERSION_FILE="${NVIDIA_PROC_VERSION_FILE:-/proc/driver/nvidia/version}"
# GPU device node checked at verification; tests point this at a fake file.
NVIDIA_DEVICE_NODE="${NVIDIA_DEVICE_NODE:-/dev/nvidia0}"
# Seconds to wait for the DCGM units to leave the active state (tests shorten).
NVIDIA_DRAIN_TIMEOUT="${NVIDIA_DRAIN_TIMEOUT:-15}"

# Dependency-first unload order: leaves (optionals, uvm/drm) before their
# dependents, with `nvidia` last.
NVIDIA_UNLOAD_ORDER="nvidia_uvm nvidia_fs gdrdrv efa_nv_peermem nvidia_drm nvidia_modeset nvidia"

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

# --- strict loaded-version reader (verification only) -----------------------
# Read the running-module version from /proc/driver/nvidia/version. A missing
# or unparseable file is a hard failure (return 1): the on-disk 620 module must
# never be mistaken for a loaded one.
nvidia__proc_version() {
  local file="${NVIDIA_PROC_VERSION_FILE:-/proc/driver/nvidia/version}"
  local version

  [[ -r "$file" ]] || return 1
  version="$(awk '/NVRM version:/ {
      for (i = 1; i <= NF; i++)
        if ($i ~ /^[0-9]+([.][0-9]+)+$/) { print $i; exit }
    }' "$file" 2>/dev/null)" || return 1
  nvidia__is_version "$version" || return 1
  printf '%s\n' "$version"
}

# --- detection precedence (pre-swap decision only) --------------------------
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
  if version="$(nvidia__proc_version)"; then
    printf '%s\n' "$version"
    return 0
  fi
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

# 0 when the LOADED driver (proc) is at/above the floor.
nvidia__proc_at_floor() {
  local version
  version="$(nvidia__proc_version)" || return 1
  nvidia_driver_ge "$version" "$NVIDIA_DRIVER_FLOOR"
}

# 0 when nvidia-smi itself reports a driver at/above the floor.
nvidia__smi_at_floor() {
  local version
  version="$(nvidia_driver_of_smi)" || return 1
  nvidia_driver_ge "$version" "$NVIDIA_DRIVER_FLOOR"
}

# --- architecture / repo ----------------------------------------------------
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

# Print the repo URL and signing-key URL for the given machine, one per line.
nvidia__repo_for_arch() {
  local machine="${1:-$(uname -m)}"
  case "$machine" in
    x86_64)  printf '%s\n%s\n' "$NVIDIA_CUDA_REPO" "$NVIDIA_CUDA_KEY" ;;
    aarch64) printf '%s\n%s\n' "$NVIDIA_CUDA_REPO_ARM64" "$NVIDIA_CUDA_KEY_ARM64" ;;
    *)
      nvidia__fail repo "no CUDA repository for machine '$machine' (expected x86_64 or aarch64)"
      return 1
      ;;
  esac
}

# Ensure the per-arch 620 CUDA repo is configured and its signing key imported
# BEFORE anything is staged or removed. A missing key makes `rpm -K` and the
# offline install fail, so this is a fail-fast gate.
nvidia__ensure_repo() {
  local sudo_cmd="$1"
  local repo_url key_url

  {
    IFS= read -r repo_url
    IFS= read -r key_url
  } < <(nvidia__repo_for_arch) || return 1

  if ! "$sudo_cmd" dnf config-manager --add-repo "$repo_url"; then
    nvidia__fail repo "could not add the CUDA repo $repo_url (nothing was uninstalled)"
    return 1
  fi
  if ! "$sudo_cmd" rpm --import "$key_url"; then
    nvidia__fail repo "could not import the CUDA signing key $key_url (nothing was uninstalled)"
    return 1
  fi
  printf 'nvidia: repo ready (%s)\n' "$repo_url"
  return 0
}

# Detect the installed kernel-module flavour: "dkms" when a DKMS build owns the
# module, otherwise "kmod" (precompiled). A DKMS host needs the stale 595 build
# removed; a kmod host must not touch dkms at all.
nvidia__kernel_module_variant() {
  local sudo_cmd="$1"
  if "$sudo_cmd" rpm -q kmod-nvidia-open-dkms >/dev/null 2>&1; then
    printf 'dkms\n'
    return 0
  fi
  if "$sudo_cmd" rpm -q kmod-nvidia-open >/dev/null 2>&1; then
    printf 'kmod\n'
    return 0
  fi
  if "$sudo_cmd" rpm -q nvidia-open-dkms >/dev/null 2>&1; then
    printf 'dkms\n'
    return 0
  fi
  printf 'kmod\n'
}

# Print the owning 620 RPM base names for fabricmanager/persistenced when those
# units exist and are RPM-managed. Passed to `dnf --downloadonly` so an
# --allowerasing offline install does not erase a needed unit (F08).
nvidia__optional_unit_packages() {
  local sudo_cmd="$1" unit fragment owner base
  for unit in nvidia-fabricmanager.service nvidia-persistenced.service; do
    nvidia__unit_exists "$sudo_cmd" "$unit" || continue
    fragment="$("$sudo_cmd" systemctl show -p FragmentPath --value "$unit" 2>/dev/null)" || continue
    [[ -n "$fragment" ]] || continue
    owner="$("$sudo_cmd" rpm -qf "$fragment" 2>/dev/null)" || continue
    [[ -n "$owner" ]] || continue
    # Strip the trailing -<version>-<release>.<arch> to keep the base name.
    base="${owner%%-[0-9]*}"
    [[ -n "$base" ]] && printf '%s-%s\n' "$base" "$NVIDIA_DRIVER_FLOOR"
  done
}

# Validate that the staged directory contains the architecture-required 620
# closure. A meta-only download is insufficient and must fail before any
# uninstall.
nvidia__validate_closure() {
  local dir="$1" machine="${2:-$(uname -m)}"

  if ! compgen -G "$dir/*.rpm" >/dev/null; then
    nvidia__fail closure "no RPMs were staged in $dir"
    return 1
  fi
  if ! compgen -G "$dir/nvidia-open-*.rpm" >/dev/null; then
    nvidia__fail closure "staged closure is missing nvidia-open-*.rpm"
    return 1
  fi
  if ! compgen -G "$dir/nvidia-driver-cuda-*.rpm" >/dev/null; then
    nvidia__fail closure "staged closure is missing nvidia-driver-cuda-*.rpm"
    return 1
  fi
  if ! compgen -G "$dir/kmod-nvidia-open-*.rpm" >/dev/null; then
    nvidia__fail closure "staged closure is missing a kmod-nvidia-open RPM (kmod or dkms)"
    return 1
  fi
  return 0
}

# Validate every staged RPM's signature/digest. Requires the repo key.
nvidia__validate_signatures() {
  local sudo_cmd="$1" dir="$2" rpmfile
  for rpmfile in "$dir"/*.rpm; do
    [[ -e "$rpmfile" ]] || continue
    if ! "$sudo_cmd" rpm -K "$rpmfile" >/dev/null 2>&1; then
      nvidia__fail closure "staged RPM signature/digest check failed: $rpmfile"
      return 1
    fi
  done
  return 0
}

# Inspect the staged payload for nvidia.ko matching the RUNNING kernel. This is
# the gate that prevents removing a working driver when the staged RPM cannot
# serve `uname -r` (e.g. a DKMS %post that will fail, or a mismatched kernel).
nvidia__staged_payload_has_running_module() {
  local sudo_cmd="$1" dir="$2" rpmfile kernel
  kernel="$(uname -r)"
  for rpmfile in "$dir"/nvidia-open-*.rpm "$dir"/kmod-nvidia-open-*.rpm; do
    [[ -e "$rpmfile" ]] || continue
    if "$sudo_cmd" rpm -qlp "$rpmfile" 2>/dev/null | grep -q "/$kernel/.*nvidia\\.ko"; then
      return 0
    fi
  done
  nvidia__fail kernel-module "staged payload has no nvidia.ko for running kernel $kernel (nothing was uninstalled)"
  return 1
}

# --- staging ----------------------------------------------------------------
# Stage the FULL 620 dependency closure into a fresh temp dir, validate it, then
# atomically swap it into $NVIDIA_STAGE_DIR (backup -> rename -> drop backup).
# A failed stage leaves the host and the previous stage untouched.
nvidia__stage_closure() {
  local sudo_cmd="$1" machine="${2:-$(uname -m)}"
  local expected_nevra tmp parent backup variant extra
  local -a extras=()

  expected_nevra="$(nvidia__pinned_nevra "$machine")" || return 1
  variant="$(nvidia__kernel_module_variant "$sudo_cmd")"
  while IFS= read -r extra; do
    [[ -n "$extra" ]] && extras+=("$extra")
  done < <(nvidia__optional_unit_packages "$sudo_cmd")

  parent="$(dirname "$NVIDIA_STAGE_DIR")"
  if ! "$sudo_cmd" mkdir -p "$parent"; then
    nvidia__fail closure "could not create staging parent $parent"
    return 1
  fi
  if ! tmp="$("$sudo_cmd" mktemp -d "${NVIDIA_STAGE_DIR}.tmp.XXXXXX")"; then
    nvidia__fail closure "could not create a staging temp dir under $parent"
    return 1
  fi

  if ! "$sudo_cmd" dnf install -y --downloadonly --disableexcludes=all \
      --destdir "$tmp" "$expected_nevra" ${extras[@]+"${extras[@]}"}; then
    "$sudo_cmd" rm -rf "$tmp"
    nvidia__fail closure "could not stage the 620 closure for $expected_nevra (nothing was uninstalled)"
    return 1
  fi
  if ! nvidia__validate_closure "$tmp" "$machine"; then
    "$sudo_cmd" rm -rf "$tmp"
    return 1
  fi
  if ! nvidia__validate_signatures "$sudo_cmd" "$tmp"; then
    "$sudo_cmd" rm -rf "$tmp"
    return 1
  fi
  if ! nvidia__staged_payload_has_running_module "$sudo_cmd" "$tmp"; then
    "$sudo_cmd" rm -rf "$tmp"
    return 1
  fi

  # Atomic swap: keep the old stage as a backup until the new one is in place.
  backup="${NVIDIA_STAGE_DIR}.bak"
  "$sudo_cmd" rm -rf "$backup"
  if [[ -d "$NVIDIA_STAGE_DIR" ]]; then
    if ! "$sudo_cmd" mv "$NVIDIA_STAGE_DIR" "$backup"; then
      "$sudo_cmd" rm -rf "$tmp"
      nvidia__fail closure "could not move the previous stage aside"
      return 1
    fi
  fi
  if ! "$sudo_cmd" mv "$tmp" "$NVIDIA_STAGE_DIR"; then
    # Restore the previous stage so a failed swap never strands the host.
    [[ -d "$backup" ]] && "$sudo_cmd" mv "$backup" "$NVIDIA_STAGE_DIR"
    "$sudo_cmd" rm -rf "$tmp"
    nvidia__fail closure "could not move the staged closure into $NVIDIA_STAGE_DIR"
    return 1
  fi
  "$sudo_cmd" rm -rf "$backup"

  printf 'nvidia: staged 620 closure (%s) in %s\n' "$variant" "$NVIDIA_STAGE_DIR"
  return 0
}

# --- holders / drain --------------------------------------------------------
nvidia__unit_exists() {
  local sudo_cmd="$1" unit="$2"
  "$sudo_cmd" systemctl cat "$unit" >/dev/null 2>&1
}

# Print 0 when the unit is active (used by the drain wait).
nvidia__unit_active() {
  local sudo_cmd="$1" unit="$2"
  "$sudo_cmd" systemctl is-active --quiet "$unit"
}

# Stop every GPU holder before removing the modules. The DCGM EXPORTER is
# stopped first (stopping only DCGM lets the exporter re-trigger it), then DCGM
# itself; both are left stopped because nv-hostengine otherwise holds
# /dev/nvidia* and strimserver never uses DCGM. Only then are persistenced and
# containerd stopped (existence-guarded, so a missing unit is not mislabelled a
# holder).
nvidia__drain() {
  local sudo_cmd="$1" unit active_unit
  local -a dcgm_units=()

  if nvidia__unit_active "$sudo_cmd" strimserver.service; then
    "$sudo_cmd" systemctl stop strimserver.service
  fi
  if nvidia__unit_exists "$sudo_cmd" nvidia-fabricmanager.service; then
    "$sudo_cmd" systemctl stop nvidia-fabricmanager.service
  fi

  if nvidia__unit_exists "$sudo_cmd" nvidia-dcgm-exporter.service; then
    "$sudo_cmd" systemctl stop nvidia-dcgm-exporter.service
    dcgm_units+=(nvidia-dcgm-exporter.service)
  fi
  if nvidia__unit_exists "$sudo_cmd" nvidia-dcgm.service; then
    "$sudo_cmd" systemctl stop nvidia-dcgm.service
    dcgm_units+=(nvidia-dcgm.service)
  fi

  if (( ${#dcgm_units[@]} > 0 )); then
    local waited=0 still_active=0
    while :; do
      still_active=0
      for unit in "${dcgm_units[@]}"; do
        nvidia__unit_active "$sudo_cmd" "$unit" && still_active=1
      done
      (( still_active == 0 )) && break
      if (( waited >= NVIDIA_DRAIN_TIMEOUT )); then
        nvidia__fail drain "DCGM units did not become inactive within ${NVIDIA_DRAIN_TIMEOUT}s: ${dcgm_units[*]}"
        return 1
      fi
      sleep 1
      waited=$((waited + 1))
    done
  fi

  if nvidia__unit_exists "$sudo_cmd" nvidia-persistenced.service; then
    "$sudo_cmd" systemctl stop nvidia-persistenced.service
  fi
  if nvidia__unit_exists "$sudo_cmd" containerd.service; then
    "$sudo_cmd" systemctl stop containerd.service
  fi
  return 0
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

# --- module unload / load ---------------------------------------------------
nvidia__modules_loaded() {
  local sudo_cmd="$1"
  "$sudo_cmd" lsmod 2>/dev/null | grep -Eq '^(nvidia|gdrdrv|efa_nv_peermem)'
}

# Unload the nvidia module graph dependency-first. Optional modules are removed
# before nvidia_drm/nvidia_modeset, and nvidia is always last. `modprobe -r`
# handles the dependency graph dynamically; `rmmod` is the fallback.
nvidia__unload_modules() {
  local sudo_cmd="$1" module
  local -a order=($NVIDIA_UNLOAD_ORDER)

  for module in "${order[@]}"; do
    "$sudo_cmd" lsmod 2>/dev/null | grep -Eq "^${module}([[:space:]]|$)" || continue
    if "$sudo_cmd" modprobe -r "$module" 2>/dev/null; then
      continue
    fi
    if "$sudo_cmd" rmmod "$module" 2>/dev/null; then
      continue
    fi
    nvidia__fail rmmod "module $module is still in use. Recovery: $sudo_cmd fuser -v /dev/nvidia* ; $sudo_cmd lsmod | grep nvidia"
    return 1
  done

  if nvidia__modules_loaded "$sudo_cmd"; then
    nvidia__fail rmmod "an nvidia module is still loaded after unload. Recovery: $sudo_cmd fuser -v /dev/nvidia* ; $sudo_cmd lsmod | grep nvidia"
    return 1
  fi
  return 0
}

# Remove the stale 595 DKMS build before depmod so it cannot shadow the new
# module. Never removes a build at/above the floor, and never runs on a kmod
# (precompiled) host.
nvidia__remove_stale_dkms() {
  local sudo_cmd="$1" old_version="${2:-}" variant status

  variant="$(nvidia__kernel_module_variant "$sudo_cmd")"
  [[ "$variant" == "dkms" ]] || return 0
  [[ -n "$old_version" ]] || return 0
  nvidia_driver_ge "$old_version" "$NVIDIA_DRIVER_FLOOR" && return 0

  status="$("$sudo_cmd" dkms status 2>/dev/null || true)"
  grep -q "nvidia-open/${old_version}" <<<"$status" || return 0
  if ! "$sudo_cmd" dkms remove "nvidia-open/${old_version}" --all; then
    nvidia__fail dkms "dkms remove nvidia-open/${old_version} --all failed; a stale 595 build may shadow 620"
    return 1
  fi
  printf 'nvidia: removed stale DKMS build nvidia-open/%s\n' "$old_version"
  return 0
}

nvidia__restore() {
  local sudo_cmd="$1"
  # DCGM/exporter are deliberately NOT restarted: strimserver never uses them,
  # and leaving them stopped keeps nv-hostengine off /dev/nvidia*.
  if nvidia__unit_exists "$sudo_cmd" nvidia-persistenced.service; then
    "$sudo_cmd" systemctl start nvidia-persistenced.service
  fi
  if nvidia__unit_exists "$sudo_cmd" nvidia-fabricmanager.service; then
    "$sudo_cmd" systemctl start nvidia-fabricmanager.service
  fi
  # containerd is deliberately NOT restarted here: deploy.sh owns the single
  # containerd restart after all GPU wiring is in place.
}

# --- resume marker ----------------------------------------------------------
nvidia__write_marker() {
  local sudo_cmd="$1" reason="$2"
  "$sudo_cmd" mkdir -p "$(dirname "$NVIDIA_RESUME_MARKER")" >/dev/null 2>&1 || true
  printf 'driver upgrade in progress: %s\n' "$reason" |
    "$sudo_cmd" tee "$NVIDIA_RESUME_MARKER" >/dev/null 2>&1 || true
}

nvidia__remove_marker() {
  local sudo_cmd="$1"
  "$sudo_cmd" rm -f "$NVIDIA_RESUME_MARKER" >/dev/null 2>&1 || true
}

# Print the operator recovery text after a post-marker failure. The marker is
# intentionally left in place so a re-run resumes; rollback restores the old
# driver explicitly.
nvidia__resume_hint() {
  local state="$1" message="$2" sudo_cmd="${3:-sudo}"
  nvidia__fail "$state" "$message"
  printf 'nvidia: [resume] leaving %s in place; re-run setup-gpu.sh to finish the swap\n' "$NVIDIA_RESUME_MARKER" >&2
  printf 'nvidia: [rollback] to abort: %s dnf install -y --allowerasing <previous nvidia-open>; %s depmod -a; %s modprobe nvidia\n' \
    "$sudo_cmd" "$sudo_cmd" "$sudo_cmd" >&2
}

# --- the entrypoint ---------------------------------------------------------
nvidia_ensure_driver_floor() {
  local sudo_cmd="${SUDO:-sudo}"
  local installed="" old_installed="" variant marker_active=0

  if [[ -e "$NVIDIA_RESUME_MARKER" ]]; then
    marker_active=1
    printf 'nvidia: resume marker %s present; completing the pending upgrade\n' "$NVIDIA_RESUME_MARKER"
  else
    installed="$(nvidia__detect_installed_version || true)"
    if [[ -n "$installed" ]] && nvidia_driver_ge "$installed" "$NVIDIA_DRIVER_FLOOR"; then
      # At/above the floor is only a no-op when the LOADED driver (proc) or a
      # working nvidia-smi confirms it. A 620 on disk with no loaded module must
      # be reloaded and re-verified, never silently accepted.
      if nvidia__proc_at_floor || nvidia__smi_at_floor; then
        printf 'nvidia: driver %s is at or above the %s floor; nothing to do\n' \
          "$installed" "$NVIDIA_DRIVER_FLOOR"
        return 0
      fi
      printf 'nvidia: driver %s is on disk but not loaded; reloading\n' "$installed"
      if ! "$sudo_cmd" depmod -a; then
        nvidia__fail depmod "depmod -a failed during reload; the module graph is incomplete"
        return 1
      fi
      if ! "$sudo_cmd" modprobe nvidia; then
        nvidia__fail verify "driver $installed is on disk but the module did not load. Recovery: $sudo_cmd depmod -a && $sudo_cmd modprobe nvidia"
        return 1
      fi
      if nvidia__proc_at_floor || nvidia__smi_at_floor; then
        printf 'nvidia: reloaded driver %s\n' "$installed"
        return 0
      fi
      nvidia__fail verify "driver $installed is on disk but did not become active after reload"
      return 1
    fi
    printf 'nvidia: driver %s is below the %s floor; upgrading\n' \
      "${installed:-unknown}" "$NVIDIA_DRIVER_FLOOR"
  fi

  # Repo + key first: a stage without the signing key would fail later.
  nvidia__ensure_repo "$sudo_cmd" || return 1

  # Capture the old installed version before anything changes; a DKMS host must
  # remove this exact stale build after the new RPM install.
  old_installed="$(nvidia__detect_installed_version || true)"
  variant="$(nvidia__kernel_module_variant "$sudo_cmd")"

  nvidia__stage_closure "$sudo_cmd" || return 1

  # First destructive action is next: persist a resume marker so an interrupted
  # swap can be completed on a re-run.
  nvidia__write_marker "$sudo_cmd" "staged 620 closure; draining holders"
  marker_active=1

  # Drain every GPU holder, then confirm none survived, BEFORE the uninstall and
  # install touch the modules.
  if ! nvidia__drain "$sudo_cmd"; then
    nvidia__resume_hint holders "draining GPU holders failed" "$sudo_cmd"
    return 1
  fi
  if ! nvidia__check_holders "$sudo_cmd"; then
    nvidia__resume_hint holders "a GPU holder survived the drain" "$sudo_cmd"
    return 1
  fi

  # A .run-managed host has no nvidia-open RPM; remove that payload before the
  # RPM install so the two do not fight over the same files.
  if ! nvidia__rpm_installed && command -v nvidia-uninstall >/dev/null 2>&1; then
    printf 'nvidia: removing the .run-managed driver before the RPM swap\n'
    if ! "$sudo_cmd" nvidia-uninstall -s; then
      nvidia__resume_hint uninstall "nvidia-uninstall -s failed; the .run driver is still installed. Re-run: $sudo_cmd nvidia-uninstall -s" "$sudo_cmd"
      return 1
    fi
  fi

  # Install offline from the validated closure. --disablerepo='*' and
  # --disableexcludes=all bypass the DLAMI excludes that otherwise filter the
  # required NVIDIA RPMs after the old driver is removed.
  if ! "$sudo_cmd" dnf install -y --allowerasing --disableexcludes=all \
      --disablerepo='*' "$NVIDIA_STAGE_DIR"/*.rpm; then
    nvidia__resume_hint install "offline dnf install failed. Recovery: $sudo_cmd dnf install -y --allowerasing --disableexcludes=all --disablerepo='*' $NVIDIA_STAGE_DIR/*.rpm" "$sudo_cmd"
    return 1
  fi

  # Verify the freshly installed module really serves the RUNNING kernel before
  # unloading the old one. `dnf` success does not guarantee a DKMS build.
  local kernel module_file module_version
  kernel="$(uname -r)"
  if ! module_version="$(modinfo -k "$kernel" -F version nvidia 2>/dev/null)" \
      || ! nvidia_driver_ge "$module_version" "$NVIDIA_DRIVER_FLOOR"; then
    nvidia__resume_hint kernel-module "installed module for $kernel is not $NVIDIA_DRIVER_FLOOR; not unloading the old driver" "$sudo_cmd"
    return 1
  fi
  module_file="$(modinfo -k "$kernel" -n nvidia 2>/dev/null || true)"
  if [[ -z "$module_file" || ! -f "$module_file" ]]; then
    nvidia__resume_hint kernel-module "no $NVIDIA_DRIVER_FLOOR nvidia.ko for $kernel on disk; not unloading the old driver" "$sudo_cmd"
    return 1
  fi

  # DKMS cleanup before depmod: remove the stale 595 build, keep 620.
  if ! nvidia__remove_stale_dkms "$sudo_cmd" "$old_installed"; then
    nvidia__resume_hint dkms "could not remove the stale DKMS build; 620 may be shadowed" "$sudo_cmd"
    return 1
  fi

  if ! "$sudo_cmd" depmod -a; then
    nvidia__resume_hint depmod "depmod -a failed; the new module dependency graph is incomplete" "$sudo_cmd"
    return 1
  fi

  if ! nvidia__unload_modules "$sudo_cmd"; then
    nvidia__resume_hint rmmod "could not unload the old module graph" "$sudo_cmd"
    return 1
  fi

  if ! "$sudo_cmd" modprobe nvidia; then
    nvidia__resume_hint modprobe "the 620 module failed to load. Recovery: $sudo_cmd depmod -a && $sudo_cmd modprobe nvidia" "$sudo_cmd"
    return 1
  fi
  if ! "$sudo_cmd" modprobe nvidia_uvm; then
    nvidia__resume_hint modprobe "nvidia_uvm failed to load after nvidia" "$sudo_cmd"
    return 1
  fi

  local gsp="$NVIDIA_FIRMWARE_ROOT/nvidia/$NVIDIA_DRIVER_FLOOR/gsp_tu10x.bin"
  if [[ ! -f "$gsp" ]]; then
    nvidia__resume_hint gsp "GSP firmware missing at $gsp; 620 open modules need GSP for Turing" "$sudo_cmd"
    return 1
  fi

  # Verification uses the STRICT proc reader: an on-disk 620 with a still-loaded
  # 595 must never be reported healthy.
  local loaded compute
  loaded="$(nvidia__proc_version || true)"
  if ! nvidia_driver_ge "$loaded" "$NVIDIA_DRIVER_FLOOR"; then
    nvidia__resume_hint verify "loaded driver is ${loaded:-unknown} (below $NVIDIA_DRIVER_FLOOR) after the swap" "$sudo_cmd"
    return 1
  fi
  compute="$(nvidia_compute_cap_of_smi || true)"
  if ! nvidia-smi --query-gpu=driver_version,compute_cap --format=csv,noheader >/dev/null 2>&1; then
    nvidia__resume_hint verify "nvidia-smi failed after the swap; the GPU did not initialize" "$sudo_cmd"
    return 1
  fi
  if [[ "$compute" != "7.5" ]]; then
    nvidia__resume_hint verify "compute capability is ${compute:-unknown}, expected 7.5 (T4/T4G)" "$sudo_cmd"
    return 1
  fi
  if [[ ! -e "$NVIDIA_DEVICE_NODE" ]]; then
    nvidia__resume_hint verify "GPU device node $NVIDIA_DEVICE_NODE is missing; the GPU did not initialize" "$sudo_cmd"
    return 1
  fi

  if ! nvidia__restore "$sudo_cmd"; then
    nvidia__resume_hint verify "driver $loaded is installed but restoring nvidia-persistenced/fabricmanager failed" "$sudo_cmd"
    return 1
  fi

  if [[ "$marker_active" == "1" ]]; then
    nvidia__remove_marker "$sudo_cmd"
  fi

  printf 'nvidia: driver %s is at or above the %s floor\n' "$loaded" "$NVIDIA_DRIVER_FLOOR"
  return 0
}
