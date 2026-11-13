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
#   [closure]   dnf could not stage the FULL 620 dependency closure, the stage
#               directory (leaf or any parent component) is missing, empty,
#               unreadable, or not traversable by the deploying user, a staged
#               RPM failed `rpm -K`, a required package is missing, or the
#               versionlock backup/filtered write failed. Nothing has been
#               uninstalled. The stage leaf is normalized to 0755; a missing
#               parent is created 0755, while an existing mount root is only
#               checked for traversal and never chmodded blindly. Recovery:
#               inspect `namei -l <dir>` and `stat -c '%a %U:%G' <dir>` as the
#               deploying user, fix traversal, then re-run.
#   [kernel-module] the staged payload cannot serve the RUNNING kernel: a kmod
#               has no nvidia.ko, a DKMS RPM has no dkms.conf (the factory
#               dkms.conf is authoritative for PACKAGE_NAME/PACKAGE_VERSION),
#               the staged source is not in an accepted nvidia-<floor> or
#               nvidia-open-<floor> layout, the staged stage
#               is unreadable, the running kernel's build tree is missing (no
#               /usr/src/kernels/<kernel>/Makefile or no
#               /lib/modules/<kernel>/build), the dkms tool is absent, the
#               staged DKMS source cannot build for `uname -r`, the installed
#               620 build is absent, or GSP firmware is missing. The old driver
#               is never removed first. The prerequisite is the build tree, not
#               a package name: AL2023 provides kernel6.12-devel/
#               kernel6.12-headers while RHEL-family hosts provide
#               kernel-devel/kernel-headers, and both install the same paths.
#               Recovery: verify `dkms status`, `modinfo -k $(uname -r) nvidia`,
#               the kernel build tree, and the 620 GSP firmware.
#   [optional]  an optional unit (fabricmanager/persistenced) was omitted or
#               its 620 package is unavailable. This is a warning, not a fatal
#               state; the required nvidia-open closure still installs.
#   [uninstall] `nvidia-uninstall -s` failed on a .run-managed host; the old
#               driver is still installed. Recovery: re-run nvidia-uninstall.
#   [install]   the offline `dnf install` failed after staging. Recovery:
#                 sudo dnf install -y --allowerasing --disableexcludes=all \
#                   --disablerepo='*' /mnt/nvme/nvidia-rpm/*.rpm
#   [depmod]    `depmod -a` failed; the new module graph is incomplete.
#   [dkms]      `dkms remove <package>/<old> --all` failed for an nvidia or
#               nvidia-open package; a stale 595 build may still shadow the new
#               module.
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
#   [resume]    the resume marker could not be written atomically, or it is
#               truncated/missing fields. A write failure aborts BEFORE the
#               drain; a malformed marker is treated conservatively (persistenced
#               is restored, never recaptured post-drain as inactive).
#   [rollback] / [resume] are not error states: on any post-marker failure the
#               resume marker is left in place and the operator is told to
#               re-run setup-gpu.sh (resume) or restore the previous driver
#               (rollback). The marker records whether fabricmanager and
#               persistenced were active before the drain, so a resumed run
#               never restores a unit that was inactive originally. A marker
#               whose strict /proc driver is already at the floor short-circuits
#               directly to restore/verify. No `strimserver-driver-resume.service`
#               exists; the marker is a plain file and resume is a manual re-run.
#
# Stage-only inspection
# ---------------------
#   NVIDIA_STAGE_ONLY=1 (or setup-gpu.sh --stage-only) runs repo setup + stage +
#   every validator and exits 0 BEFORE the resume marker, drain, uninstall, or
#   install. Use it to prove the stage dir is 0755 and every parent is
#   traversable by the deploying user without touching a running driver.
#
# Rollback assumptions: a successful swap removes the old driver. Keep a
# verified off-host artifact of the previous driver (or accept replacement-only
# rollback); never rely on the stage dir surviving an instance stop.
#
# Restore semantics: nvidia__restore starts fabricmanager only when it was
# active AND its 620 package was staged (a start failure is a loud warning on a
# T4/g4dn host) and starts persistenced only when it was active (a failure is
# fatal). It never restarts DCGM/exporter or containerd; deploy.sh owns the
# single containerd restart.
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

# Exact RPM header names intentionally versioned independently of the driver.
# Such a staged package may skip the 620 version assertion only when ALL hold:
#   - the %{NAME} header is exactly one of these names (never a prefix match);
#   - %{ARCH} is noarch (policy/meta package only);
#   - `rpm -qlp` lists no /lib/modules/**/*.ko and no /libnvidia*.so.
# nvidia-driver-selinux is the SELinux policy module; it ships policy/license
# files only and is pulled conditionally by nvidia-kmod-common.
NVIDIA_STAGED_VERSION_EXEMPT_PACKAGES="nvidia-driver-selinux"

# Overridable locations (tests redirect these into temp dirs).
NVIDIA_STAGE_DIR="${NVIDIA_STAGE_DIR:-/mnt/nvme/nvidia-rpm}"
# Where a staged DKMS source tree is extracted/registered before the pre-install
# build proof. The real DKMS tree lives in /usr/src; tests redirect it.
NVIDIA_DKMS_SRC_ROOT="${NVIDIA_DKMS_SRC_ROOT:-/usr/src}"
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

# On-disk version only (rpm then modinfo), never nvidia-smi. Used on resume to
# decide whether the 620 payload is already installed but merely unloaded.
nvidia__on_disk_version() {
  local version
  if version="$(nvidia__rpm_version)"; then
    printf '%s\n' "$version"
    return 0
  fi
  if version="$(nvidia__modinfo_version)"; then
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

# Print the value of a KEY=VALUE assignment from a DKMS dkms.conf. The factory
# dkms.conf is authoritative for the DKMS package identity, so a missing file,
# an absent key, or an empty value fails closed (no stdout, return 1) rather
# than inventing an identity from a directory name.
nvidia__dkms_conf_value() {
  local file="$1" key="$2" line value

  [[ -f "$file" ]] || return 1
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line#export }"
    [[ "$line" == "$key="* ]] || continue
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ ${#value} -ge 2 && "$value" == \"*\" ]]; then
      value="${value:1:${#value}-2}"
    elif [[ ${#value} -ge 2 && "$value" == \'*\' ]]; then
      value="${value:1:${#value}-2}"
    fi
    [[ -n "$value" ]] || return 1
    printf '%s\n' "$value"
    return 0
  done <"$file"
  return 1
}

# Print "<PACKAGE_NAME> <PACKAGE_VERSION>" derived from a DKMS source tree's
# factory dkms.conf. Fails closed when the tree or either identity value is
# absent or empty.
nvidia__dkms_identity() {
  local source_dir="$1" conf="$1/dkms.conf" name version

  [[ -f "$conf" ]] || return 1
  name="$(nvidia__dkms_conf_value "$conf" PACKAGE_NAME)" || return 1
  version="$(nvidia__dkms_conf_value "$conf" PACKAGE_VERSION)" || return 1
  printf '%s %s\n' "$name" "$version"
}

# Print the DKMS source directory for the pinned floor under a root, accepting
# either factory layout (`nvidia-<floor>` or `nvidia-open-<floor>`) with a
# dkms.conf at its root. A staged RPM extract lands under <root>/usr/src
# because cpio strips the leading slash, so check that payload layout too.
# Fails closed when neither layout is present.
nvidia__find_dkms_source_dir() {
  local root="$1" floor="$2" base candidate

  for base in "$root" "$root/usr/src"; do
    for candidate in "$base/nvidia-$floor" "$base/nvidia-open-$floor"; do
      if [[ -f "$candidate/dkms.conf" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  done
  return 1
}

# Detect the installed kernel-module flavour. DKMS wins: a host that has a DKMS
# package, or a live `dkms status` build, must be cleaned up through dkms even
# if a stale precompiled kmod RPM is also present.
nvidia__kernel_module_variant() {
  local sudo_cmd="$1" status

  if "$sudo_cmd" rpm -q kmod-nvidia-open-dkms >/dev/null 2>&1; then
    printf 'dkms\n'
    return 0
  fi
  if "$sudo_cmd" rpm -q nvidia-open-dkms >/dev/null 2>&1; then
    printf 'dkms\n'
    return 0
  fi
  # Only consult `dkms status` when the host actually has a DKMS tree; a plain
  # precompiled kmod host must never invoke dkms. A live DKMS build still wins
  # over a stale kmod RPM.
  # Accept both DKMS package names and both source-directory layouts:
  # `nvidia-<version>` (factory dkms.conf PACKAGE_NAME=nvidia) and the legacy
  # `nvidia-open-<version>`, under the DKMS source root or /var/lib/dkms.
  if command -v dkms >/dev/null 2>&1 \
      && { [[ -d /var/lib/dkms/nvidia ]] || [[ -d /var/lib/dkms/nvidia-open ]] \
           || compgen -G "$NVIDIA_DKMS_SRC_ROOT/nvidia-[0-9]*" >/dev/null \
           || compgen -G "$NVIDIA_DKMS_SRC_ROOT/nvidia-open-*" >/dev/null; }; then
    status="$("$sudo_cmd" dkms status 2>/dev/null || true)"
    if grep -qE 'nvidia(-open)?/' <<<"$status"; then
      printf 'dkms\n'
      return 0
    fi
  fi
  if "$sudo_cmd" rpm -q kmod-nvidia-open >/dev/null 2>&1; then
    printf 'kmod\n'
    return 0
  fi
  printf 'kmod\n'
}

# Map an optional unit to the base package that owns it when the unit file is
# not RPM-owned (e.g. a .run-managed install or a hand-written unit).
nvidia__optional_unit_base() {
  case "$1" in
    nvidia-fabricmanager.service) printf 'nvidia-fabricmanager\n' ;;
    nvidia-persistenced.service)  printf 'nvidia-persistenced\n' ;;
  esac
}

# Print the available 620 package token for each optional unit that exists on
# this host. Stdout is package-only; every omission is a warning on stderr.
# Nonexistent units are skipped before any rpm/repoquery call, and a transient
# repoquery failure simply omits the optional package rather than aborting.
nvidia__optional_unit_packages() {
  local sudo_cmd="$1" machine unit fragment owner base query rc
  local name verrel version arch row
  local -a rows
  machine="$(uname -m)"

  for unit in nvidia-fabricmanager.service nvidia-persistenced.service; do
    nvidia__unit_exists "$sudo_cmd" "$unit" || continue
    fragment="$("$sudo_cmd" systemctl show -p FragmentPath --value "$unit" 2>/dev/null || true)"
    [[ -n "$fragment" ]] || continue

    rc=0
    owner="$("$sudo_cmd" rpm -qf --qf '%{NAME}\n' "$fragment" 2>/dev/null)" || rc=$?
    if (( rc == 0 )) && [[ -n "$owner" ]]; then
      base="${owner%%[[:space:]]*}"
      base="${base%%-[0-9]*}"
    else
      # A non-zero rc means "not RPM-owned", never a fatal error.
      base="$(nvidia__optional_unit_base "$unit")"
    fi
    [[ -n "$base" ]] || continue

    rc=0
    query="$("$sudo_cmd" dnf -q --disableexcludes=all repoquery --available \
      --qf '%{name} %{version}-%{release} %{arch}\n' "${base}-${NVIDIA_DRIVER_FLOOR}" 2>/dev/null)" || rc=$?

    rows=()
    if (( rc == 0 )) && [[ -n "$query" ]]; then
      while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        read -r name verrel arch <<<"$row"
        [[ -n "$name" && -n "$verrel" ]] || continue
        if [[ "$arch" == "$machine" || "$arch" == "noarch" ]]; then
          rows+=("$name $verrel $arch")
        fi
      done <<<"$query"
    fi

    if (( ${#rows[@]} != 1 )); then
      printf 'nvidia: WARNING: optional package %s-%s is not available for %s; omitting it (unit %s)\n' \
        "$base" "$NVIDIA_DRIVER_FLOOR" "$machine" "$unit" >&2
      continue
    fi

    read -r name verrel arch <<<"${rows[0]}"
    version="${verrel%%-*}"
    if ! nvidia_driver_ge "$version" "$NVIDIA_DRIVER_FLOOR"; then
      printf 'nvidia: WARNING: optional package %s-%s is below the %s floor; omitting it (unit %s)\n' \
        "$base" "$verrel" "$NVIDIA_DRIVER_FLOOR" "$unit" >&2
      continue
    fi
    printf '%s-%s\n' "$base" "$verrel"
  done
}

# Validate that the staged directory contains the architecture-required 620
# closure. A meta-only download is insufficient and must fail before any
# uninstall.
nvidia__validate_closure() {
  local dir="$1" machine="${2:-$(uname -m)}"

  nvidia__assert_stage_readable "$dir" closure || return 1
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
  local -a rpms=()
  local had_nullglob=0

  nvidia__assert_stage_readable "$dir" closure || return 1
  shopt -q nullglob || had_nullglob=1
  shopt -s nullglob
  rpms=("$dir"/*.rpm)
  (( had_nullglob == 1 )) && shopt -u nullglob
  if (( ${#rpms[@]} == 0 )); then
    nvidia__fail closure "no staged RPMs in $dir for $(id -un) (empty or inaccessible); no driver action was taken"
    return 1
  fi
  for rpmfile in "${rpms[@]}"; do
    [[ -e "$rpmfile" ]] || continue
    if ! "$sudo_cmd" rpm -K "$rpmfile" >/dev/null 2>&1; then
      nvidia__fail closure "staged RPM signature/digest check failed: $rpmfile"
      return 1
    fi
  done
  return 0
}

# True when the staged closure contains a DKMS RPM that ships dkms.conf (i.e.
# the real source-only DKMS payload, not the legacy prebuilt-module variant).
nvidia__staged_dkms_has_conf() {
  local sudo_cmd="$1" dir="$2" rpmfile
  nvidia__assert_stage_readable "$dir" kernel-module || return 1
  for rpmfile in "$dir"/kmod-nvidia-open-dkms-*.rpm "$dir"/nvidia-open-dkms-*.rpm; do
    [[ -e "$rpmfile" ]] || continue
    if "$sudo_cmd" rpm -qlp "$rpmfile" 2>/dev/null | grep -q 'dkms\.conf'; then
      return 0
    fi
  done
  return 1
}

# Inspect the staged payload by filename. A DKMS RPM must carry dkms.conf (a
# prebuilt-module legacy payload is accepted as a fallback); a precompiled kmod
# must carry nvidia.ko for the RUNNING kernel; the nvidia-open metapackage has
# no kernel module and is exempt. This gate runs before any uninstall.
nvidia__staged_payload_has_running_module() {
  local sudo_cmd="$1" dir="$2" rpmfile base listing kernel
  local -a rpms=()
  local had_nullglob=0
  kernel="$(uname -r)"
  nvidia__assert_stage_readable "$dir" kernel-module || return 1
  shopt -q nullglob || had_nullglob=1
  shopt -s nullglob
  rpms=("$dir"/*.rpm)
  (( had_nullglob == 1 )) && shopt -u nullglob
  if (( ${#rpms[@]} == 0 )); then
    nvidia__fail kernel-module "no staged RPMs in $dir for $(id -un) (empty or inaccessible); no driver action was taken"
    return 1
  fi
  for rpmfile in "${rpms[@]}"; do
    [[ -e "$rpmfile" ]] || continue
    base="${rpmfile##*/}"
    case "$base" in
      kmod-nvidia-open-dkms-*|nvidia-open-dkms-*)
        listing="$("$sudo_cmd" rpm -qlp "$rpmfile" 2>/dev/null || true)"
        if grep -q 'dkms\.conf' <<<"$listing"; then
          continue
        fi
        if grep -qE "/$kernel/.*nvidia\\.ko" <<<"$listing"; then
          continue
        fi
        nvidia__fail kernel-module "staged DKMS RPM $base has no dkms.conf (nothing was uninstalled)"
        return 1
        ;;
      kmod-nvidia-open-*)
        listing="$("$sudo_cmd" rpm -qlp "$rpmfile" 2>/dev/null || true)"
        if ! grep -qE "/$kernel/.*nvidia\\.ko" <<<"$listing"; then
          nvidia__fail kernel-module "staged payload has no nvidia.ko for running kernel $kernel (nothing was uninstalled)"
          return 1
        fi
        ;;
      nvidia-open-*)
        # Meta RPM: carries no kernel module by design.
        ;;
    esac
  done
  return 0
}

# True when a glob matches at least one file in the staging directory.
nvidia__staged_has_glob() {
  local dir="$1" pattern="$2"
  nvidia__assert_stage_readable "$dir" closure || return 1
  compgen -G "$dir/$pattern" >/dev/null
}

# Print the first staged RPM matching a shell glob (e.g. dkms-*.rpm).
nvidia__staged_rpm() {
  local dir="$1" pattern="$2" rpmfile
  nvidia__assert_stage_readable "$dir" closure || return 1
  for rpmfile in "$dir"/$pattern; do
    [[ -e "$rpmfile" ]] || continue
    printf '%s\n' "$rpmfile"
    return 0
  done
  return 1
}

# Print the staged DKMS source RPM (the kmod-nvidia-open-dkms name preferred).
nvidia__staged_dkms_rpm() {
  local dir="$1" rpmfile
  nvidia__assert_stage_readable "$dir" kernel-module || return 1
  for rpmfile in "$dir"/kmod-nvidia-open-dkms-*.rpm "$dir"/nvidia-open-dkms-*.rpm; do
    [[ -e "$rpmfile" ]] || continue
    printf '%s\n' "$rpmfile"
    return 0
  done
  return 1
}

# The authoritative DKMS build prerequisite is the RUNNING kernel's build tree,
# not a package name. Both naming schemes install the same two paths:
#   RHEL-family  kernel-devel-$kernel / kernel-headers-$kernel
#   AL2023       kernel6.12-devel-$kernel / kernel6.12-headers-$kernel
# so test the tree itself and stay name-agnostic.
nvidia__kernel_build_prereq_present() {
  local sudo_cmd="$1" kernel="$2"
  "$sudo_cmd" test -f "/usr/src/kernels/$kernel/Makefile" 2>/dev/null \
    && "$sudo_cmd" test -e "/lib/modules/$kernel/build" 2>/dev/null
}

# Print repo-resolvable prerequisite specs for the RUNNING kernel, preferring
# the legacy RHEL-family name over the AL2023 kernel6.12-* name for each
# family. Prints nothing when the build tree already exists (nothing to stage).
nvidia__kernel_prereq_specs() {
  local sudo_cmd="$1" kernel="$2" family candidate result
  nvidia__kernel_build_prereq_present "$sudo_cmd" "$kernel" && return 0
  for family in devel headers; do
    for candidate in "kernel-${family}-${kernel}" "kernel6.12-${family}-${kernel}"; do
      result="$("$sudo_cmd" dnf -q repoquery --available \
        --qf '%{name}-%{version}-%{release}' "$candidate" 2>/dev/null || true)"
      if [[ -n "$result" ]]; then
        printf '%s\n' "$result"
        break
      fi
    done
  done
}

# A DKMS host needs a usable dkms tool plus the running kernel's build tree.
# Install any kernel-devel/headers supplied by the staged closure BEFORE the
# build proof; fail fast, before touching the host, when the tree is absent and
# cannot be completed. The staged globs are deliberately broad (kernel*-devel-*
# / kernel*-headers-*) so both the legacy and AL2023 package names match.
nvidia__ensure_dkms_prereqs() {
  local sudo_cmd="$1" dir="$2" kernel rpmfile
  local -a install_rpms=()
  kernel="$(uname -r)"

  nvidia__assert_stage_readable "$dir" kernel-module || return 1
  if ! command -v dkms >/dev/null 2>&1; then
    if rpmfile="$(nvidia__staged_rpm "$dir" 'dkms-*.rpm')"; then
      install_rpms+=("$rpmfile")
    else
      nvidia__fail kernel-module "the dkms tool is missing and is not present in the staged closure (nothing was uninstalled)"
      return 1
    fi
  fi
  # The build tree is the prerequisite: AL2023 can satisfy it with
  # kernel6.12-devel/kernel6.12-headers even when the legacy rpm -q names are
  # absent. Stage whichever kernel-devel/headers RPM the closure carries.
  if ! nvidia__kernel_build_prereq_present "$sudo_cmd" "$kernel"; then
    if rpmfile="$(nvidia__staged_rpm "$dir" 'kernel*-devel-*.rpm')"; then
      install_rpms+=("$rpmfile")
    fi
    if rpmfile="$(nvidia__staged_rpm "$dir" 'kernel*-headers-*.rpm')"; then
      install_rpms+=("$rpmfile")
    fi
  fi

  if (( ${#install_rpms[@]} > 0 )); then
    if ! "$sudo_cmd" dnf install -y --disableexcludes=all "${install_rpms[@]}"; then
      nvidia__fail kernel-module "could not install the staged kernel build prerequisites for $kernel (nothing was uninstalled)"
      return 1
    fi
  fi

  # Re-read the build tree: the staged RPMs (or a pre-existing tree) must now
  # provide both paths before the DKMS build proof runs.
  if ! nvidia__kernel_build_prereq_present "$sudo_cmd" "$kernel"; then
    nvidia__fail kernel-module "missing kernel build prerequisites for $kernel: kernel-devel-$kernel|kernel6.12-devel-$kernel kernel-headers-$kernel|kernel6.12-headers-$kernel (nothing was uninstalled)"
    return 1
  fi
  return 0
}

# Extract the staged DKMS source payload into the DKMS source root and register
# it so the pre-install build proof can run. The factory dkms.conf is
# authoritative: PACKAGE_NAME/PACKAGE_VERSION determine the DKMS identity used
# for the source-tree path, `dkms add`, and the build proof. Either accepted
# source layout (`nvidia-$FLOOR` or `nvidia-open-$FLOOR`) is honoured. This
# never installs the driver RPM and never touches the installed below-floor
# driver. On success, prints the derived "<name>/<version>" token.
nvidia__register_dkms_source() {
  local sudo_cmd="$1" dir="$2" rpmfile tmp source_dir
  local identity dkms_name dkms_version src_dir
  local extracted=0

  nvidia__assert_stage_readable "$dir" kernel-module || return 1

  if source_dir="$(nvidia__find_dkms_source_dir "$NVIDIA_DKMS_SRC_ROOT" "$NVIDIA_DRIVER_FLOOR")"; then
    # Reuse a pre-existing tree; only its factory dkms.conf defines identity.
    :
  else
    extracted=1
    if ! rpmfile="$(nvidia__staged_dkms_rpm "$dir")"; then
      nvidia__fail kernel-module "staged closure has no DKMS source RPM for nvidia/$NVIDIA_DRIVER_FLOOR or nvidia-open/$NVIDIA_DRIVER_FLOOR (nothing was uninstalled)"
      return 1
    fi
    if ! tmp="$(mktemp -d 2>/dev/null)"; then
      nvidia__fail kernel-module "could not create a temp dir to extract the staged DKMS source (nothing was uninstalled)"
      return 1
    fi
    if ! "$sudo_cmd" rpm2cpio "$rpmfile" \
        | ( cd "$tmp" && "$sudo_cmd" cpio -idm --quiet ); then
      "$sudo_cmd" rm -rf "$tmp"
      nvidia__fail kernel-module "could not extract the staged DKMS source $rpmfile (nothing was uninstalled)"
      return 1
    fi
    if ! source_dir="$(nvidia__find_dkms_source_dir "$tmp" "$NVIDIA_DRIVER_FLOOR")"; then
      "$sudo_cmd" rm -rf "$tmp"
      nvidia__fail kernel-module "staged DKMS source $rpmfile has no dkms.conf under nvidia-$NVIDIA_DRIVER_FLOOR/ or nvidia-open-$NVIDIA_DRIVER_FLOOR/ (nothing was uninstalled)"
      return 1
    fi
  fi

  if ! identity="$(nvidia__dkms_identity "$source_dir")"; then
    if [[ "$extracted" == "1" ]]; then
      "$sudo_cmd" rm -rf "$tmp"
    fi
    nvidia__fail kernel-module "DKMS source $source_dir/dkms.conf has no usable PACKAGE_NAME/PACKAGE_VERSION (nothing was uninstalled)"
    return 1
  fi
  dkms_name="${identity%% *}"
  dkms_version="${identity#* }"
  src_dir="$NVIDIA_DKMS_SRC_ROOT/$dkms_name-$dkms_version"

  if [[ "$extracted" == "1" ]]; then
    if ! "$sudo_cmd" mkdir -p "$src_dir"; then
      "$sudo_cmd" rm -rf "$tmp"
      nvidia__fail kernel-module "could not create the DKMS source tree $src_dir (nothing was uninstalled)"
      return 1
    fi
    if ! "$sudo_cmd" cp -a "$source_dir/." "$src_dir/"; then
      "$sudo_cmd" rm -rf "$tmp"
      nvidia__fail kernel-module "could not place the staged DKMS source under $src_dir (nothing was uninstalled)"
      return 1
    fi
    "$sudo_cmd" rm -rf "$tmp"
  fi

  # Register only a source tree that this proof just extracted; a pre-existing
  # tree is assumed already added by the package or a previous run. Consulting
  # `dkms status` here would run before the driver install and blur the
  # post-install verification ordering.
  if [[ "$extracted" == "1" ]]; then
    if ! "$sudo_cmd" dkms add "$dkms_name/$dkms_version"; then
      nvidia__fail kernel-module "dkms add $dkms_name/$dkms_version failed (nothing was uninstalled)"
      return 1
    fi
  fi
  printf '%s/%s\n' "$dkms_name" "$dkms_version"
  return 0
}

# Prove the staged DKMS source can build for the RUNNING kernel before removing
# the old driver. The identity is derived from dkms.conf by
# nvidia__register_dkms_source. A build failure means the old driver must stay
# installed.
nvidia__prove_dkms_build() {
  local sudo_cmd="$1" dkms_token="$2" kernel

  if [[ -z "$dkms_token" ]]; then
    nvidia__fail kernel-module "no DKMS package identity was derived from dkms.conf (nothing was uninstalled)"
    return 1
  fi
  kernel="$(uname -r)"
  if ! "$sudo_cmd" dkms build "$dkms_token" -k "$kernel" >/dev/null 2>&1; then
    nvidia__fail kernel-module "staged DKMS source cannot build $dkms_token for $kernel (nothing was uninstalled)"
    return 1
  fi
  return 0
}

# The staged closure (or the host) must provide GSP firmware for 620 Turing
# modules. Checked before the uninstall so the old driver is never removed when
# the new one provably cannot initialize a T4.
nvidia__staged_payload_has_gsp() {
  local sudo_cmd="$1" dir="$2" rpmfile firmware
  local -a rpms=()
  local had_nullglob=0
  firmware="$NVIDIA_FIRMWARE_ROOT/nvidia/$NVIDIA_DRIVER_FLOOR/gsp_tu10x.bin"
  [[ -f "$firmware" ]] && return 0
  # The host-firmware short-circuit above deliberately reads no stage; only now
  # must a missing/unreadable stage fail closed.
  nvidia__assert_stage_readable "$dir" kernel-module || return 1
  shopt -q nullglob || had_nullglob=1
  shopt -s nullglob
  rpms=("$dir"/*.rpm)
  (( had_nullglob == 1 )) && shopt -u nullglob
  if (( ${#rpms[@]} == 0 )); then
    nvidia__fail kernel-module "no staged RPMs in $dir for $(id -un) (empty or inaccessible); no driver action was taken"
    return 1
  fi
  for rpmfile in "${rpms[@]}"; do
    [[ -e "$rpmfile" ]] || continue
    if "$sudo_cmd" rpm -qlp "$rpmfile" 2>/dev/null | grep -q "/lib/firmware/nvidia/$NVIDIA_DRIVER_FLOOR/gsp_tu10x.bin"; then
      return 0
    fi
  done
  nvidia__fail kernel-module "staged closure has no gsp_tu10x.bin for $NVIDIA_DRIVER_FLOOR and $firmware is absent (nothing was uninstalled)"
  return 1
}

# nvidia__staged_version_exempt <header_name>
#   0 only for an EXACT match against NVIDIA_STAGED_VERSION_EXEMPT_PACKAGES.
#   Never a prefix match, so `nvidia-driver-selinux-devel` etc. stay asserted.
nvidia__staged_version_exempt() {
  local candidate="$1" exempt
  local -a exempt_packages=()
  read -r -a exempt_packages <<<"$NVIDIA_STAGED_VERSION_EXEMPT_PACKAGES"
  for exempt in "${exempt_packages[@]}"; do
    [[ "$candidate" == "$exempt" ]] && return 0
  done
  return 1
}

# Assert every staged driver payload reports the 620 version floor.
#
# Driver payloads are version-asserted: every staged nvidia-*.rpm,
# libnvidia-*.rpm, and kmod-nvidia-open*.rpm is read with `rpm -qp` from its own
# header and must report %{VERSION} == $NVIDIA_DRIVER_FLOOR.
# `nvidia-driver-selinux` is the single policy-only exemption: its header name
# must match exactly, it must be noarch, and `rpm -qlp` must list no
# /lib/modules/**/*.ko and no /libnvidia*.so. Only then is the 620 version
# assertion skipped. Release and epoch are intentionally NOT asserted; %{VERSION}
# is the whole contract for the floor. kmod-nvidia-open* is included so a non-620
# kernel-module RPM cannot slip through staging.
#
# Fails closed on: an unreadable/non-regular staged path, a nonzero `rpm` exit,
# empty/whitespace/(none)/malformed %{NAME}, empty/malformed %{VERSION}, an arch
# other than noarch/host/i686-on-x86_64, a non-620 driver version, an exempt
# name whose payload or arch fails the exemption checks, or a stage that yields
# zero asserted driver RPMs. Every diagnostic names the header and path and
# states that no driver action was taken.
nvidia__assert_staged_versions() {
  local sudo_cmd="$1" dir="$2" machine="${3:-$(uname -m)}"
  local rpmfile name version arch payload rc arch_ok=0
  local asserted_drivers=0
  local -a rpms=()
  local had_nullglob=0

  nvidia__assert_stage_readable "$dir" closure || return 1

  shopt -q nullglob || had_nullglob=1
  shopt -s nullglob
  rpms=("$dir"/nvidia-*.rpm "$dir"/libnvidia-*.rpm "$dir"/kmod-nvidia-*.rpm)
  (( had_nullglob == 1 )) && shopt -u nullglob

  if (( ${#rpms[@]} == 0 )); then
    nvidia__fail closure "no staged nvidia-*/libnvidia-*/kmod-nvidia-* RPMs in $dir for $(id -un) (empty or inaccessible); no driver action was taken"
    return 1
  fi

  for rpmfile in "${rpms[@]}"; do
    if [[ ! -f "$rpmfile" || ! -r "$rpmfile" ]]; then
      nvidia__fail closure "staged path $rpmfile is not a regular readable file (name=<unknown> version=<unknown> rpm_rc=n/a); no driver action was taken"
      return 1
    fi

    rc=0
    name="$("$sudo_cmd" rpm -qp --qf '%{NAME}' "$rpmfile" 2>/dev/null)" || rc=$?
    if (( rc != 0 )); then
      nvidia__fail closure "staged $rpmfile (name=<${name:-}> rpm_rc=$rc) failed the %{NAME} query; no driver action was taken"
      return 1
    fi
    if [[ -z "${name//[[:space:]]/}" || "$name" == "(none)" ]]; then
      nvidia__fail closure "staged $rpmfile has an empty/whitespace/(none) %{NAME} (name=$(printf '%q' "$name") rpm_rc=$rc); no driver action was taken"
      return 1
    fi
    if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
      nvidia__fail closure "staged $rpmfile has an invalid %{NAME} '$name' (rpm_rc=$rc); no driver action was taken"
      return 1
    fi

    rc=0
    version="$("$sudo_cmd" rpm -qp --qf '%{VERSION}' "$rpmfile" 2>/dev/null)" || rc=$?
    if (( rc != 0 )); then
      nvidia__fail closure "staged $rpmfile (name=$name version=<${version:-}> rpm_rc=$rc) failed the %{VERSION} query; no driver action was taken"
      return 1
    fi
    if [[ -z "${version//[[:space:]]/}" ]]; then
      nvidia__fail closure "staged $rpmfile (name=$name version=$(printf '%q' "$version") rpm_rc=$rc) has an empty/whitespace %{VERSION}; no driver action was taken"
      return 1
    fi
    if ! nvidia__is_version "$version"; then
      nvidia__fail closure "staged $rpmfile (name=$name version=$version rpm_rc=$rc) reports unrecognized version '$version'; no driver action was taken"
      return 1
    fi

    rc=0
    arch="$("$sudo_cmd" rpm -qp --qf '%{ARCH}' "$rpmfile" 2>/dev/null)" || rc=$?
    if (( rc != 0 )); then
      nvidia__fail closure "staged $rpmfile (name=$name version=$version arch=<${arch:-}> rpm_rc=$rc) failed the %{ARCH} query; no driver action was taken"
      return 1
    fi
    arch_ok=0
    [[ "$arch" == "noarch" || "$arch" == "$machine" ]] && arch_ok=1
    [[ "$machine" == "x86_64" && "$arch" == "i686" ]] && arch_ok=1
    if (( arch_ok == 0 )); then
      nvidia__fail closure "staged $rpmfile (name=$name version=$version arch=$arch rpm_rc=$rc) is not host-compatible (expected noarch or $machine); no driver action was taken"
      return 1
    fi

    if nvidia__staged_version_exempt "$name"; then
      if [[ "$arch" != "noarch" ]]; then
        nvidia__fail closure "staged $rpmfile (name=$name version=$version arch=$arch rpm_rc=$rc) is exempt by name but not noarch; no driver action was taken"
        return 1
      fi
      rc=0
      payload="$("$sudo_cmd" rpm -qlp "$rpmfile" 2>/dev/null)" || rc=$?
      if (( rc != 0 )); then
        nvidia__fail closure "staged $rpmfile (name=$name version=$version rpm_rc=$rc) failed the payload listing; no driver action was taken"
        return 1
      fi
      if grep -Eq '/lib/modules/.*\.ko|/libnvidia.*\.so' <<<"$payload"; then
        nvidia__fail closure "staged $rpmfile (name=$name version=$version rpm_rc=$rc) is exempt by name but ships a driver payload (.ko/libnvidia*.so); no driver action was taken"
        return 1
      fi
      continue
    fi

    if [[ "$version" != "$NVIDIA_DRIVER_FLOOR" ]]; then
      nvidia__fail closure "staged $rpmfile (name=$name version=$version arch=$arch rpm_rc=$rc) reports version $version, expected $NVIDIA_DRIVER_FLOOR; no driver action was taken"
      return 1
    fi
    (( asserted_drivers += 1 ))
  done

  if (( asserted_drivers == 0 )); then
    nvidia__fail closure "no staged driver payload was version-asserted in $dir (only exempt policy packages were present); no driver action was taken"
    return 1
  fi
  return 0
}

# Temporarily clear below-floor optional-package locks so the 620 optional
# package can be staged. The original file is restored from an EXIT trap with
# the sudo_cmd that created the backup. A backup or filtered-write failure is a
# hard [closure] error: continuing with a half-written versionlock file could
# change the resolver for the rest of the run.
nvidia__versionlock_restore() {
  [[ -n "${nvidia__versionlock_backup:-}" ]] || return 0
  local sudo_cmd="${nvidia__versionlock_sudo:-${SUDO:-sudo}}"
  # Restore the earlier backup BEFORE clearing our own backup marker.
  "$sudo_cmd" cp -p "${nvidia__versionlock_backup}" "${nvidia__versionlock_path}" 2>/dev/null || true
  "$sudo_cmd" rm -f "${nvidia__versionlock_backup}" 2>/dev/null || true
  nvidia__versionlock_backup=""
  nvidia__versionlock_path=""
  nvidia__versionlock_sudo=""
}

nvidia__versionlock_clear() {
  local sudo_cmd="$1" file="${NVIDIA_VERSIONLOCK_FILE:-/etc/dnf/plugins/versionlock.list}"
  local backup filtered="" rc=0
  [[ -f "$file" ]] || return 0

  # Restore any earlier backup before taking a new one, so repeated stage
  # attempts never stack backups.
  nvidia__versionlock_restore

  backup="$("$sudo_cmd" mktemp "${file}.nvidia-upgrade.XXXXXX" 2>/dev/null)" || {
    nvidia__fail closure "could not create a versionlock backup for $file (nothing was uninstalled)"
    return 1
  }
  if ! "$sudo_cmd" cp -p "$file" "$backup" 2>/dev/null; then
    "$sudo_cmd" rm -f "$backup" 2>/dev/null || true
    nvidia__fail closure "could not back up the versionlock file $file (nothing was uninstalled)"
    return 1
  fi
  nvidia__versionlock_backup="$backup"
  nvidia__versionlock_path="$file"
  nvidia__versionlock_sudo="$sudo_cmd"

  filtered="$("$sudo_cmd" grep -Ev 'nvidia-(fabricmanager|persistenced)-' "$file" 2>/dev/null)" || rc=$?
  if (( rc > 1 )); then
    "$sudo_cmd" cp -p "$backup" "$file" 2>/dev/null || true
    "$sudo_cmd" rm -f "$backup" 2>/dev/null || true
    nvidia__versionlock_backup=""
    nvidia__versionlock_path=""
    nvidia__versionlock_sudo=""
    nvidia__fail closure "could not filter the versionlock file $file; restored the backup (nothing was uninstalled)"
    return 1
  fi
  if ! printf '%s\n' "$filtered" | "$sudo_cmd" tee "$file" >/dev/null 2>&1; then
    "$sudo_cmd" cp -p "$backup" "$file" 2>/dev/null || true
    "$sudo_cmd" rm -f "$backup" 2>/dev/null || true
    nvidia__versionlock_backup=""
    nvidia__versionlock_path=""
    nvidia__versionlock_sudo=""
    nvidia__fail closure "could not write the filtered versionlock file $file; restored the backup (nothing was uninstalled)"
    return 1
  fi
  trap 'nvidia__versionlock_restore' EXIT
  return 0
}

# --- staging directory access ----------------------------------------------
# One diagnostic helper, used by every fail-closed stage guard. It names the
# failing component, its mode/owner when stat succeeds, the invoking user, and
# states explicitly that no driver action was taken.
nvidia__stage_access_error() {
  local dir="$1" mode_owner
  printf 'nvidia: staging path %s is not readable/traversable by %s (access denied/inaccessible)\n' \
    "$dir" "$(id -un)" >&2
  if mode_owner="$(stat -c '%a %U:%G' "$dir" 2>/dev/null)"; then
    printf 'nvidia: %s mode/owner: %s\n' "$dir" "$mode_owner" >&2
  fi
  if command -v namei >/dev/null 2>&1; then
    printf 'nvidia: path components for %s (namei -l):\n' "$dir" >&2
    namei -l "$dir" 2>/dev/null >&2 || true
  fi
  printf 'nvidia: no driver action was taken; make the stage and every parent component readable and traversable\n' >&2
}

# nvidia__assert_stage_readable <dir> [state=closure]
# Fail closed unless the directory and EVERY parent component are readable and
# traversable by the INVOKING user (never tested with sudo), and at least one
# staged RPM is visible. A non-expanded glob is never treated as success.
nvidia__assert_stage_readable() {
  local dir="$1" state="${2:-closure}"
  local comp
  local -a components=()
  local -a rpms=()
  local had_nullglob=0

  if [[ ! -e "$dir" ]]; then
    nvidia__fail "$state" "staging directory $dir does not exist for $(id -un); no driver action was taken"
    nvidia__stage_access_error "$dir"
    return 1
  fi
  if [[ ! -d "$dir" ]]; then
    nvidia__fail "$state" "staging path $dir is not a directory for $(id -un); no driver action was taken"
    nvidia__stage_access_error "$dir"
    return 1
  fi

  # Walk the leaf and every ancestor. Absolute paths terminate at "/"; guard
  # against a relative path or a bare "." so the loop cannot run forever.
  comp="$dir"
  while [[ -n "$comp" && "$comp" != "/" && "$comp" != "." ]]; do
    components+=("$comp")
    comp="$(dirname "$comp")"
  done
  [[ "$dir" == /* ]] && components+=(/)

  local c
  for c in "${components[@]}"; do
    if [[ ! -r "$c" || ! -x "$c" ]]; then
      nvidia__fail "$state" "staging path component $c is not readable/traversable by $(id -un); no driver action was taken"
      nvidia__stage_access_error "$c"
      return 1
    fi
  done

  shopt -q nullglob || had_nullglob=1
  shopt -s nullglob
  rpms=("$dir"/*.rpm)
  (( had_nullglob == 1 )) && shopt -u nullglob
  if (( ${#rpms[@]} == 0 )); then
    nvidia__fail "$state" "staging directory $dir is empty or inaccessible for $(id -un); no driver action was taken"
    nvidia__stage_access_error "$dir"
    return 1
  fi
  return 0
}

# Create a missing stage parent 0755, but NEVER chmod an existing mount root.
# An existing parent must already be traversable by the invoking user.
nvidia__stage_prepare_parent() {
  local sudo_cmd="$1" parent="$2"

  if [[ -d "$parent" ]]; then
    if [[ ! -x "$parent" ]]; then
      nvidia__fail closure "staging parent $parent is not traversable by $(id -un); refusing to chmod an existing mount root"
      nvidia__stage_access_error "$parent"
      return 1
    fi
    return 0
  fi
  if ! "$sudo_cmd" install -d -m 0755 "$parent"; then
    nvidia__fail closure "could not create staging parent $parent with mode 0755"
    return 1
  fi
  return 0
}

# nvidia__stage_make_readable <sudo_cmd> <dir>
# Normalize the leaf and its parent so the deploying user can read and traverse
# the staged closure. Staged RPMs are public package artifacts.
nvidia__stage_make_readable() {
  local sudo_cmd="$1" dir="$2"

  if ! nvidia__stage_prepare_parent "$sudo_cmd" "$(dirname "$dir")"; then
    return 1
  fi
  if ! "$sudo_cmd" chmod -R a+rX "$dir"; then
    nvidia__fail closure "could not make staging directory readable: $dir"
    return 1
  fi
  return 0
}

# --- staging ----------------------------------------------------------------
# Stage the FULL 620 dependency closure into a fresh temp dir, validate it, then
# atomically swap it into $NVIDIA_STAGE_DIR (backup -> rename -> drop backup).
# A failed stage leaves the host and the previous stage untouched.
nvidia__stage_closure() {
  local sudo_cmd="$1" machine="${2:-$(uname -m)}"
  local expected_nevra tmp parent backup variant extra optional_output err_file
  local dnf_err detail stage_base spec existing dkms_token
  local duplicate
  local -a extras=() required=()
  NVIDIA_OPTIONAL_PACKAGES_RESOLVED=""
  NVIDIA_OPTIONAL_PACKAGES_OMITTED=""

  expected_nevra="$(nvidia__pinned_nevra "$machine")" || return 1
  variant="$(nvidia__kernel_module_variant "$sudo_cmd")"

  # Resolve optionals in a captured subshell so their package-only stdout can
  # be read in this shell; keep their warnings on stderr.
  err_file="$(mktemp 2>/dev/null || true)"
  if [[ -n "$err_file" ]]; then
    optional_output="$(nvidia__optional_unit_packages "$sudo_cmd" 2>"$err_file")" || optional_output=""
    if [[ -s "$err_file" ]]; then
      cat "$err_file" >&2
    fi
    NVIDIA_OPTIONAL_PACKAGES_OMITTED="$(
      grep -oE 'nvidia-(fabricmanager|persistenced)-[0-9.]+' "$err_file" 2>/dev/null | sort -u | tr '\n' ' ' || true
    )"
    rm -f "$err_file"
  else
    optional_output="$(nvidia__optional_unit_packages "$sudo_cmd")" || optional_output=""
  fi
  while IFS= read -r extra; do
    [[ -n "$extra" ]] && extras+=("$extra")
  done <<<"$optional_output"
  if (( ${#extras[@]} > 0 )); then
    NVIDIA_OPTIONAL_PACKAGES_RESOLVED=" ${extras[*]}"
  fi

  parent="$(dirname "$NVIDIA_STAGE_DIR")"
  if ! nvidia__stage_prepare_parent "$sudo_cmd" "$parent"; then
    return 1
  fi
  if ! tmp="$("$sudo_cmd" mktemp -d "${NVIDIA_STAGE_DIR}.tmp.XXXXXX")"; then
    nvidia__fail closure "could not create a staging temp dir under $parent"
    return 1
  fi
  # A root-owned mktemp -d is 0700; the deploying user must be able to read and
  # traverse the stage before any validator runs.
  if ! nvidia__stage_make_readable "$sudo_cmd" "$tmp"; then
    "$sudo_cmd" rm -rf "$tmp"
    return 1
  fi

  nvidia__versionlock_clear "$sudo_cmd" || {
    "$sudo_cmd" rm -rf "$tmp"
    return 1
  }

  # The required closure is the pinned nvidia-open NEVRA plus, on a DKMS host
  # whose running kernel has no build tree, the distro kernel-devel/headers
  # specs. They must be downloaded now because the build proof runs before any
  # uninstall. nvidia__kernel_prereq_specs prints nothing when the tree already
  # exists and resolves the AL2023 kernel6.12-* names as well as the legacy
  # kernel-*-$kernel names. Skip any spec already required or queued optional.
  required=("$expected_nevra")
  if [[ "$variant" == "dkms" ]]; then
    while IFS= read -r spec; do
      [[ -n "$spec" ]] || continue
      duplicate=0
      for existing in "${required[@]}" ${extras[@]+"${extras[@]}"}; do
        if [[ "$existing" == "$spec" ]]; then
          duplicate=1
          break
        fi
      done
      if (( duplicate == 0 )); then
        required+=("$spec")
      fi
    done < <(nvidia__kernel_prereq_specs "$sudo_cmd" "$(uname -r)")
  fi

  dnf_err="$(mktemp 2>/dev/null || true)"
  # Stage the REQUIRED nvidia-open NEVRA (and any missing kernel build
  # prerequisites) in its own transaction first. An unavailable optional package
  # can never abort this stage.
  if ! "$sudo_cmd" dnf install -y --downloadonly --disableexcludes=all \
      --setopt=metadata_expire=0 --destdir "$tmp" "${required[@]}" \
      2>"${dnf_err:-/dev/stderr}"; then
    detail=""
    [[ -n "$dnf_err" && -s "$dnf_err" ]] && detail="$(cat "$dnf_err" 2>/dev/null || true)"
    [[ -n "$dnf_err" ]] && rm -f "$dnf_err"
    "$sudo_cmd" rm -rf "$tmp"
    if [[ -n "$detail" ]]; then
      printf 'nvidia: captured DNF stderr while staging the required closure:\n%s\n' "$detail" >&2
    fi
    if grep -qiE 'lock|metadata|repomd|synchroniz' <<<"$detail"; then
      nvidia__fail closure "could not stage the required 620 closure for $expected_nevra: DNF reported a lock or stale metadata (see captured stderr). Recovery: 'sudo dnf clean metadata' or release /var/cache/dnf/*.lock, then re-run (nothing was uninstalled)"
    else
      nvidia__fail closure "could not stage the required 620 closure for $expected_nevra (resolved optional:${NVIDIA_OPTIONAL_PACKAGES_RESOLVED:- none}; omitted optional:${NVIDIA_OPTIONAL_PACKAGES_OMITTED:- none}; nothing was uninstalled)"
    fi
    return 1
  fi
  if ! nvidia__stage_make_readable "$sudo_cmd" "$tmp"; then
    "$sudo_cmd" rm -rf "$tmp"
    return 1
  fi
  if ! nvidia__validate_closure "$tmp" "$machine"; then
    [[ -n "$dnf_err" ]] && rm -f "$dnf_err"
    "$sudo_cmd" rm -rf "$tmp"
    return 1
  fi
  if ! nvidia__validate_signatures "$sudo_cmd" "$tmp"; then
    [[ -n "$dnf_err" ]] && rm -f "$dnf_err"
    "$sudo_cmd" rm -rf "$tmp"
    return 1
  fi
  if ! nvidia__assert_staged_versions "$sudo_cmd" "$tmp" "$machine"; then
    nvidia__versionlock_restore
    [[ -n "$dnf_err" ]] && rm -f "$dnf_err"
    "$sudo_cmd" rm -rf "$tmp"
    return 1
  fi

  # Stage each optional package into the same directory in its own best-effort
  # transaction. A DOWNLOAD failure warns and keeps the required closure; a
  # chmod failure always aborts because an unreadable stage is unusable.
  for extra in ${extras[@]+"${extras[@]}"}; do
    if ! "$sudo_cmd" dnf install -y --downloadonly --disableexcludes=all \
        --setopt=metadata_expire=0 --destdir "$tmp" "$extra"; then
      printf 'nvidia: WARNING: could not stage optional package %s; omitting it and keeping the required 620 closure\n' "$extra" >&2
      NVIDIA_OPTIONAL_PACKAGES_RESOLVED="${NVIDIA_OPTIONAL_PACKAGES_RESOLVED// $extra/}"
      NVIDIA_OPTIONAL_PACKAGES_OMITTED+=" $extra"
      # Remove any partial artifacts from the failed optional transaction
      # before re-validation.
      stage_base="${extra%%-[0-9]*}"
      "$sudo_cmd" rm -f "$tmp/$stage_base"-*.rpm >/dev/null 2>&1 || true
    fi
    if ! nvidia__stage_make_readable "$sudo_cmd" "$tmp"; then
      [[ -n "$dnf_err" ]] && rm -f "$dnf_err"
      "$sudo_cmd" rm -rf "$tmp"
      return 1
    fi
  done
  [[ -n "$dnf_err" ]] && rm -f "$dnf_err"

  # Re-validate the combined closure after optional staging.
  if ! nvidia__validate_closure "$tmp" "$machine"; then
    "$sudo_cmd" rm -rf "$tmp"
    return 1
  fi
  if ! nvidia__validate_signatures "$sudo_cmd" "$tmp"; then
    "$sudo_cmd" rm -rf "$tmp"
    return 1
  fi
  if ! nvidia__assert_staged_versions "$sudo_cmd" "$tmp" "$machine"; then
    nvidia__versionlock_restore
    "$sudo_cmd" rm -rf "$tmp"
    return 1
  fi

  if ! nvidia__staged_payload_has_running_module "$sudo_cmd" "$tmp"; then
    "$sudo_cmd" rm -rf "$tmp"
    return 1
  fi
  if [[ "$variant" == "dkms" ]]; then
    if ! nvidia__ensure_dkms_prereqs "$sudo_cmd" "$tmp"; then
      "$sudo_cmd" rm -rf "$tmp"
      return 1
    fi
    # A legacy "dkms" payload that ships a prebuilt .ko has no source to build;
    # only a real dkms.conf payload needs extraction + registration + proof.
    if nvidia__staged_dkms_has_conf "$sudo_cmd" "$tmp"; then
      if ! dkms_token="$(nvidia__register_dkms_source "$sudo_cmd" "$tmp")"; then
        "$sudo_cmd" rm -rf "$tmp"
        return 1
      fi
      if ! nvidia__prove_dkms_build "$sudo_cmd" "$dkms_token"; then
        "$sudo_cmd" rm -rf "$tmp"
        return 1
      fi
    fi
  fi
  if ! nvidia__staged_payload_has_gsp "$sudo_cmd" "$tmp"; then
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

  # The temp dir was normalized before the rename; re-assert both the leaf mode
  # and the parent traversal after the swap so a mode change cannot slip in.
  if ! nvidia__stage_make_readable "$sudo_cmd" "$NVIDIA_STAGE_DIR"; then
    return 1
  fi

  local -a staged_rpms=()
  local had_nullglob=0
  shopt -q nullglob || had_nullglob=1
  shopt -s nullglob
  staged_rpms=("$NVIDIA_STAGE_DIR"/*.rpm)
  (( had_nullglob == 1 )) && shopt -u nullglob
  # Restore the versionlock file now that staging is complete; no
  # .nvidia-upgrade.* backup may survive a successful stage.
  nvidia__versionlock_restore
  # The diagnostic must never change the exit status: `|| true` guards the
  # printf, and the count comes from a nullglob array, never a pipeline.
  printf 'nvidia: staged %d RPMs (%s) in %s\n' \
    "${#staged_rpms[@]}" "$variant" "$NVIDIA_STAGE_DIR" || true
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
# Both helpers capture `lsmod` output before matching instead of piping it into
# `grep -q`. Under `set -o pipefail`, a grep that exits on the first match can
# SIGPIPE the producer, making the pipeline report 141 even though the module
# matched. The command-substitution form never closes a pipe early.
nvidia__modules_loaded() {
  local sudo_cmd="$1" listing
  listing="$("$sudo_cmd" lsmod 2>/dev/null || true)"
  grep -Eq '^(nvidia|gdrdrv|efa_nv_peermem)' <<<"$listing"
}

# Unload the nvidia module graph dependency-first. Optional modules are removed
# before nvidia_drm/nvidia_modeset, and nvidia is always last. `modprobe -r`
# handles the dependency graph dynamically; `rmmod` is the fallback.
nvidia__unload_modules() {
  local sudo_cmd="$1" module listing
  local -a order=($NVIDIA_UNLOAD_ORDER)

  for module in "${order[@]}"; do
    # Re-read each iteration: an earlier unload may have removed a dependent
    # module too. Capture, then match, to avoid SIGPIPE on a short listing.
    listing="$("$sudo_cmd" lsmod 2>/dev/null || true)"
    grep -Eq "^${module}([[:space:]]|$)" <<<"$listing" || continue
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

# Remove every stale DKMS build below the floor before depmod so none can
# shadow the new module. Never removes a build at/above the floor, and never
# runs on a kmod (precompiled) host.
nvidia__remove_stale_dkms() {
  local sudo_cmd="$1" variant status found version

  variant="$(nvidia__kernel_module_variant "$sudo_cmd")"
  [[ "$variant" == "dkms" ]] || return 0

  status="$("$sudo_cmd" dkms status 2>/dev/null || true)"
  while IFS= read -r found; do
    [[ -n "$found" ]] || continue
    version="${found#*/}"
    if nvidia_driver_ge "$version" "$NVIDIA_DRIVER_FLOOR"; then
      continue
    fi
    if ! "$sudo_cmd" dkms remove "$found" --all; then
      nvidia__fail dkms "dkms remove $found --all failed; a stale build may shadow 620"
      return 1
    fi
    printf 'nvidia: removed stale DKMS build %s\n' "$found"
  done < <(grep -oE '(nvidia|nvidia-open)/[0-9]+([.][0-9]+)*' <<<"$status" | sort -u)
  return 0
}

# Restore only the units that were active before the drain. Fabricmanager is
# optional on T4/g4dn: it starts only when it was active AND its 620 package was
# staged, and a start failure is a loud warning rather than a hard failure.
# Persistenced is part of the GPU runtime contract, so its failure is fatal.
# DCGM/exporter and containerd are deliberately NOT restarted here.
nvidia__restore() {
  local sudo_cmd="$1"
  local fabricmanager_was_active="${2:-0}"
  local fabricmanager_pkg_staged="${3:-0}"
  local persistenced_was_active="${4:-0}"
  local rc

  if [[ "$persistenced_was_active" == "1" ]] \
      && nvidia__unit_exists "$sudo_cmd" nvidia-persistenced.service; then
    if "$sudo_cmd" systemctl start nvidia-persistenced.service; then
      :
    else
      rc=$?
      nvidia__fail verify "nvidia-persistenced.service failed to start after the swap (rc=$rc)"
      return 1
    fi
  fi

  if [[ "$fabricmanager_was_active" == "1" && "$fabricmanager_pkg_staged" == "1" ]] \
      && nvidia__unit_exists "$sudo_cmd" nvidia-fabricmanager.service; then
    if "$sudo_cmd" systemctl start nvidia-fabricmanager.service; then
      :
    else
      rc=$?
      printf 'nvidia: WARNING: nvidia-fabricmanager.service failed to start after the swap (rc=%s); continuing (optional on T4/g4dn)\n' "$rc" >&2
    fi
  fi
  return 0
}

# --- resume marker ----------------------------------------------------------
# Persist the pre-drain unit state in a parseable form. The marker is written to
# a temp file and atomically renamed, so a crash never leaves a half-written
# marker. A marker that cannot be written must abort the upgrade BEFORE the
# destructive phase.
nvidia__write_marker() {
  local sudo_cmd="$1" reason="$2"
  local fabricmanager_was_active="${3:-0}"
  local fabricmanager_pkg_staged="${4:-0}"
  local persistenced_was_active="${5:-0}"
  local dir tmp
  dir="$(dirname "$NVIDIA_RESUME_MARKER")"

  if ! "$sudo_cmd" mkdir -p "$dir"; then
    nvidia__fail resume "could not create the resume-marker directory $dir; refusing to start the destructive phase"
    return 1
  fi
  if ! tmp="$("$sudo_cmd" mktemp "${NVIDIA_RESUME_MARKER}.tmp.XXXXXX" 2>/dev/null)"; then
    nvidia__fail resume "could not create a resume-marker temp file in $dir; refusing to start the destructive phase"
    return 1
  fi
  if ! printf 'driver upgrade in progress: %s\nfabricmanager_was_active=%s\nfabricmanager_pkg_staged=%s\npersistenced_was_active=%s\n' \
      "$reason" "$fabricmanager_was_active" "$fabricmanager_pkg_staged" "$persistenced_was_active" \
      | "$sudo_cmd" tee "$tmp" >/dev/null; then
    "$sudo_cmd" rm -f "$tmp" 2>/dev/null || true
    nvidia__fail resume "could not write the resume marker $NVIDIA_RESUME_MARKER; refusing to start the destructive phase"
    return 1
  fi
  if ! "$sudo_cmd" mv -f "$tmp" "$NVIDIA_RESUME_MARKER"; then
    "$sudo_cmd" rm -f "$tmp" 2>/dev/null || true
    nvidia__fail resume "could not atomically install the resume marker $NVIDIA_RESUME_MARKER; refusing to start the destructive phase"
    return 1
  fi
  return 0
}

# Read one boolean from the marker. Returns non-zero when absent or malformed so
# callers can fall back to capturing the current unit state.
nvidia__read_marker_bool() {
  local file="$1" key="$2" line value=""
  [[ -r "$file" ]] || return 1
  line="$(grep -m1 "^${key}=" "$file" 2>/dev/null || true)"
  [[ -n "$line" ]] || return 1
  value="${line#*=}"
  [[ "$value" == "0" || "$value" == "1" ]] || return 1
  printf '%s\n' "$value"
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
  local installed="" variant marker_active=0 marker_valid=0 resume_at_floor=0
  local fabricmanager_was_active=0 fabricmanager_pkg_staged=0 persistenced_was_active=0
  local saved_fm_active="" saved_fm_staged="" saved_persist="" on_disk=""

  # Stage-only inspection mode: repository + stage + every validator, then exit
  # 0 before the resume marker, drain, uninstall, or install.
  if [[ "${NVIDIA_STAGE_ONLY:-0}" == "1" ]]; then
    nvidia__ensure_repo "$sudo_cmd" || return 1
    nvidia__stage_closure "$sudo_cmd" || return 1
    printf 'nvidia: stage-only mode: closure staged and validated; no driver action taken\n'
    return 0
  fi

  if [[ -e "$NVIDIA_RESUME_MARKER" ]]; then
    marker_active=1
    printf 'nvidia: resume marker %s present; completing the pending upgrade\n' "$NVIDIA_RESUME_MARKER"
    saved_fm_active="$(nvidia__read_marker_bool "$NVIDIA_RESUME_MARKER" fabricmanager_was_active || true)"
    saved_fm_staged="$(nvidia__read_marker_bool "$NVIDIA_RESUME_MARKER" fabricmanager_pkg_staged || true)"
    saved_persist="$(nvidia__read_marker_bool "$NVIDIA_RESUME_MARKER" persistenced_was_active || true)"
    if [[ -n "$saved_fm_active" && -n "$saved_fm_staged" && -n "$saved_persist" ]]; then
      marker_valid=1
    else
      # A truncated/missing-field marker must never recapture post-drain state
      # as inactive. Restore persistenced conservatively; fabricmanager stays
      # optional and is not guessed active.
      printf 'nvidia: WARNING: resume marker %s is truncated or missing fields; restoring persistenced conservatively\n' \
        "$NVIDIA_RESUME_MARKER" >&2
      saved_fm_active=0
      saved_fm_staged=0
      saved_persist=1
    fi
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

  # Resume with 620 on disk but below-floor /proc: try to reload the installed
  # payload (depmod + modprobe) and re-verify BEFORE staging or reinstalling. A
  # successful reload must never trigger a second offline install.
  if [[ "$marker_active" == "1" ]] && ! nvidia__proc_at_floor; then
    on_disk="$(nvidia__on_disk_version || true)"
    if [[ -n "$on_disk" ]] && nvidia_driver_ge "$on_disk" "$NVIDIA_DRIVER_FLOOR"; then
      printf 'nvidia: resume: driver %s is on disk but not loaded; reloading before any re-stage\n' "$on_disk"
      if "$sudo_cmd" depmod -a && "$sudo_cmd" modprobe nvidia \
          && { nvidia__proc_at_floor || nvidia__smi_at_floor; }; then
        printf 'nvidia: resume: reloaded driver %s without re-staging\n' "$on_disk"
      else
        printf 'nvidia: resume: on-disk %s did not load; falling back to stage/install\n' "$on_disk" >&2
      fi
    fi
  fi

  # Resume short-circuit: the loaded driver is already at the floor, so the
  # stage/uninstall/install steps are unnecessary. Only restore + verify remain.
  if [[ "$marker_active" == "1" ]] && nvidia__proc_at_floor; then
    resume_at_floor=1
    printf 'nvidia: loaded driver is already at the %s floor; skipping stage/install and resuming at verification\n' "$NVIDIA_DRIVER_FLOOR"
    if [[ "$marker_valid" == "1" ]]; then
      fabricmanager_was_active="${saved_fm_active:-0}"
      fabricmanager_pkg_staged="${saved_fm_staged:-0}"
      persistenced_was_active="$saved_persist"
    else
      if nvidia__unit_active "$sudo_cmd" nvidia-fabricmanager.service; then
        fabricmanager_was_active=1
      fi
      persistenced_was_active="${saved_persist:-1}"
    fi
  fi

  if [[ "$resume_at_floor" == "0" ]]; then
    # Repo + key first: a stage without the signing key would fail later.
    nvidia__ensure_repo "$sudo_cmd" || return 1

    variant="$(nvidia__kernel_module_variant "$sudo_cmd")"

    nvidia__stage_closure "$sudo_cmd" || return 1

    # Capture the pre-drain state in THIS shell, immediately before the marker.
    # On resume, reuse the saved booleans instead of recapturing post-drain.
    if [[ "$marker_active" == "1" && -n "$saved_persist" ]]; then
      fabricmanager_was_active="${saved_fm_active:-0}"
      fabricmanager_pkg_staged="${saved_fm_staged:-0}"
      persistenced_was_active="$saved_persist"
    else
      if nvidia__unit_active "$sudo_cmd" nvidia-fabricmanager.service; then
        fabricmanager_was_active=1
      fi
      if nvidia__unit_active "$sudo_cmd" nvidia-persistenced.service; then
        persistenced_was_active=1
      fi
      if compgen -G "$NVIDIA_STAGE_DIR/nvidia-fabricmanager-*.rpm" >/dev/null \
          || grep -q 'nvidia-fabricmanager-' <<<"${NVIDIA_OPTIONAL_PACKAGES_RESOLVED:-}"; then
        fabricmanager_pkg_staged=1
      fi
    fi
    if [[ "$fabricmanager_was_active" == "1" && "$fabricmanager_pkg_staged" == "0" ]]; then
      printf 'nvidia: WARNING: fabricmanager was active but its 620 package was omitted; leaving it stopped (the previous 595 package stays installed)\n' >&2
    fi

    # First destructive action is next: persist a resume marker so an
    # interrupted swap can be completed on a re-run. A write failure aborts.
    if ! nvidia__write_marker "$sudo_cmd" "staged 620 closure; draining holders" \
        "$fabricmanager_was_active" "$fabricmanager_pkg_staged" "$persistenced_was_active"; then
      return 1
    fi
    marker_active=1

    # Drain every GPU holder, then confirm none survived, BEFORE the uninstall
    # and install touch the modules.
    if ! nvidia__drain "$sudo_cmd"; then
      nvidia__resume_hint holders "draining GPU holders failed" "$sudo_cmd"
      return 1
    fi
    if ! nvidia__check_holders "$sudo_cmd"; then
      nvidia__resume_hint holders "a GPU holder survived the drain" "$sudo_cmd"
      return 1
    fi

    # A .run-managed host has no nvidia-open RPM; remove that payload before
    # the RPM install so the two do not fight over the same files.
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

    # Prove the freshly installed 620 module serves the RUNNING kernel BEFORE
    # removing any old DKMS build or unloading the old module. `dnf` success
    # does not guarantee a DKMS build.
    local kernel module_file module_version dkms_status dkms_conf=0
    kernel="$(uname -r)"
    if [[ "$variant" == "dkms" ]] && nvidia__staged_dkms_has_conf "$sudo_cmd" "$NVIDIA_STAGE_DIR"; then
      dkms_conf=1
    fi
    if [[ "$dkms_conf" == "1" ]]; then
      dkms_status="$("$sudo_cmd" dkms status 2>/dev/null || true)"
      # The factory dkms.conf may identify the module as either `nvidia` or the
      # legacy `nvidia-open`; both are valid as long as the floor matches.
      if ! grep -qE "(nvidia|nvidia-open)/${NVIDIA_DRIVER_FLOOR}([^0-9.]|$)" <<<"$dkms_status" \
          || ! grep -qF "$kernel" <<<"$dkms_status"; then
        nvidia__resume_hint kernel-module "installed DKMS source did not produce nvidia/$NVIDIA_DRIVER_FLOOR or nvidia-open/$NVIDIA_DRIVER_FLOOR for $kernel; not unloading the old driver" "$sudo_cmd"
        return 1
      fi
    fi

    # Remove every stale below-floor DKMS build, then rebuild the module graph.
    if ! nvidia__remove_stale_dkms "$sudo_cmd"; then
      nvidia__resume_hint dkms "could not remove the stale DKMS build; 620 may be shadowed" "$sudo_cmd"
      return 1
    fi

    if ! "$sudo_cmd" depmod -a; then
      nvidia__resume_hint depmod "depmod -a failed; the new module dependency graph is incomplete" "$sudo_cmd"
      return 1
    fi

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

  if ! nvidia__restore "$sudo_cmd" "$fabricmanager_was_active" "$fabricmanager_pkg_staged" "$persistenced_was_active"; then
    nvidia__resume_hint verify "driver $loaded is installed but restoring nvidia-persistenced/fabricmanager failed" "$sudo_cmd"
    return 1
  fi

  if [[ "$marker_active" == "1" ]]; then
    nvidia__remove_marker "$sudo_cmd"
  fi

  printf 'nvidia: driver %s is at or above the %s floor\n' "$loaded" "$NVIDIA_DRIVER_FLOOR"
  return 0
}
