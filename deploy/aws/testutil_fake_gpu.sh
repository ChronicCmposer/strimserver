#!/usr/bin/env bash
# testutil_fake_gpu.sh -- sourceable fake NVIDIA/dnf/systemctl toolchain for
# offline tests of deploy/aws/lib/nvidia.sh and setup-gpu.sh.
#
# fake_gpu_install puts stubs first on PATH and points the recorder at a temp
# file; every stub records its argv (one call per line) to $FAKE_GPU_CALLS and
# answers the handful of commands the driver-upgrade path uses. A `sudo` shim
# is installed as `fake-sudo`: it records the argv and then `exec "$@"`, so the
# real PATH shims still answer (this is why callers pass SUDO=fake-sudo).
#
# State lives in $FAKE_GPU_STATE so a fake `dnf install` can change the driver
# version that the re-verify step observes, a fake `modprobe`/`rmmod` can move
# modules in/out of the loaded set, and a fake `systemctl stop` can flip the
# DCGM units inactive:
#   driver_version  on-disk/rpm/modinfo version (what a package install writes)
#   rpm_installed   1 when `rpm -q nvidia-open` should succeed
#   modules         newline list of loaded nvidia modules
#   dcgm_active / dcgm_exporter_active   1 when the unit is active
#   kmod_variant    "kmod" or "dkms"
#
# The loaded driver is modelled separately from the on-disk driver: the proc
# version file ($FAKE_PROC_FILE) is rewritten by `modprobe` from driver_version
# and removed by `rmmod`. That is what lets tests distinguish "disk is 620 but
# the running kernel still has 595" from "the kernel actually reloaded".
#
# Response knobs (read at call time, so tests may change them mid-run):
#   FAKE_REPORTED_DRIVER      initial on-disk driver (default 620.70.06;
#                             set to "" for a host with no detectable driver)
#   FAKE_PROC_VERSION         initial loaded version. When the variable is SET
#                             and empty, no proc file exists (unloaded host).
#                             When unset, the proc file starts at
#                             FAKE_REPORTED_DRIVER (a loaded host).
#   FAKE_PROC_VERSION_STUCK   1 -> modprobe/rmmod never touch the proc file
#   FAKE_COMPUTE_CAP          compute_cap reported by nvidia-smi (default 7.5)
#   FAKE_DNF_RC               rc for `dnf install` (offline) (default 0)
#   FAKE_DNF_DOWNLOADONLY_RC  rc for `dnf install --downloadonly` (default 0)
#   FAKE_DNF_CLOSURE_INCOMPLETE 1 -> stage writes only the nvidia-open meta RPM
#   FAKE_DNF_KEY_MISSING      1 -> `rpm --import` and `rpm -K` fail
#   FAKE_PKG_AVAILABLE        0 -> `dnf install --downloadonly` fails
#   FAKE_RMMOD_BUSY           1 -> `rmmod`/`modprobe -r` fail (module in use)
#   FAKE_SMI_RC               rc for nvidia-smi (default 0)
#   FAKE_SMI_MISSING          1 -> do not install an nvidia-smi shim at all
#   FAKE_RPM_INSTALLED        1 -> `rpm -q nvidia-open` succeeds
#   FAKE_RUN_MANAGED          1 -> modinfo reports a version with no RPM
#   FAKE_UNINSTALL_RC         rc for `nvidia-uninstall` (default 0)
#   FAKE_MODPROBE_RC          rc for `modprobe` (default 0)
#   FAKE_DNF_UPGRADES_DRIVER  0 -> offline install leaves the on-disk driver
#   FAKE_HOLDER               1 -> `fuser` reports a /dev/nvidia* holder
#   FAKE_MODULE_LOADED        1 -> initial module set includes nvidia (default 1)
#   FAKE_MODULES              explicit space-separated initial module set
#   FAKE_STRIMSERVER_ACTIVE   1 -> `systemctl is-active strimserver.service`
#   FAKE_FABRICMANAGER_UNIT   1 -> `systemctl cat nvidia-fabricmanager.service`
#   FAKE_DCGM_UNIT            1 -> `nvidia-dcgm.service` exists
#   FAKE_DCGM_EXPORTER_UNIT   1 -> `nvidia-dcgm-exporter.service` exists
#   FAKE_DCGM_ACTIVE          1 -> nvidia-dcgm active initially
#   FAKE_DCGM_EXPORTER_ACTIVE 1 -> nvidia-dcgm-exporter active initially
#   FAKE_DCGM_STUCK           1 -> stop leaves nvidia-dcgm active
#   FAKE_DCGM_EXPORTER_STUCK  1 -> stop leaves nvidia-dcgm-exporter active
#   FAKE_ARCH                 uname -m value (default x86_64)
#   FAKE_KERNEL_RELEASE       uname -r value
#   FAKE_NEVRA                value printed by `rpm -qp --qf '%{NEVRA}'`
#   FAKE_KERNEL_MODULE_VARIANT  "kmod" (default) or "dkms"
#   FAKE_DKMS_STATUS          `dkms status` output
#   FAKE_DKMS_RC              rc for `dkms` (default 0)
#   FAKE_PAYLOAD_MISSING_MODULE 1 -> `rpm -qlp` omits the running-kernel .ko
#
# Not intended to be executed directly.

# Write a realistic /proc/driver/nvidia/version payload for a loaded driver.
fake_gpu_write_proc() {
  local version="$1" file="${FAKE_PROC_FILE:?fake_gpu_install must run first}"
  printf 'NVRM version: NVIDIA UNIX Open Kernel Module for x86_64  %s  Release Build\n' \
    "$version" >"$file"
}

fake_gpu_install() {
  # Resolve real tools before the shims shadow them; the shims and cleanup use
  # these absolute paths so they never recurse into themselves.
  FAKE_REAL_MKDIR="$(type -P mkdir)"
  FAKE_REAL_RM="$(type -P rm)"
  FAKE_REAL_CP="$(type -P cp)"
  export FAKE_REAL_MKDIR FAKE_REAL_RM FAKE_REAL_CP
  FAKE_GPU_BINDIR="$(mktemp -d)"
  FAKE_GPU_CALLS="$(mktemp)"
  FAKE_DNF_ARGV="$(mktemp)"
  FAKE_GPU_STATE="$(mktemp -d)"
  export FAKE_GPU_BINDIR FAKE_GPU_CALLS FAKE_DNF_ARGV FAKE_GPU_STATE \
    FAKE_REAL_MKDIR FAKE_REAL_RM FAKE_REAL_CP

  # The proc file and device node are always redirected into the state dir
  # unless a test chose its own. This keeps the library hermetic.
  if [[ -z "${NVIDIA_PROC_VERSION_FILE:-}" ]]; then
    NVIDIA_PROC_VERSION_FILE="$FAKE_GPU_STATE/proc_version"
    export NVIDIA_PROC_VERSION_FILE
  fi
  FAKE_PROC_FILE="$NVIDIA_PROC_VERSION_FILE"
  export FAKE_PROC_FILE
  if [[ -z "${NVIDIA_DEVICE_NODE:-}" ]]; then
    NVIDIA_DEVICE_NODE="$FAKE_GPU_STATE/nvidia0"
    export NVIDIA_DEVICE_NODE
  fi

  printf '%s' "${FAKE_REPORTED_DRIVER-620.70.06}" >"$FAKE_GPU_STATE/driver_version"
  printf '%s' "${FAKE_RPM_INSTALLED:-0}" >"$FAKE_GPU_STATE/rpm_installed"
  printf '%s' "${FAKE_KERNEL_MODULE_VARIANT:-kmod}" >"$FAKE_GPU_STATE/kmod_variant"
  printf '0' >"$FAKE_GPU_STATE/dcgm_active"
  printf '0' >"$FAKE_GPU_STATE/dcgm_exporter_active"
  [[ "${FAKE_DCGM_ACTIVE:-0}" == "1" ]] && printf '1' >"$FAKE_GPU_STATE/dcgm_active"
  [[ "${FAKE_DCGM_EXPORTER_ACTIVE:-0}" == "1" ]] && printf '1' >"$FAKE_GPU_STATE/dcgm_exporter_active"
  : >"$FAKE_GPU_STATE/modules"
  if [[ -n "${FAKE_MODULES:-}" ]]; then
    for m in $FAKE_MODULES; do printf '%s\n' "$m" >>"$FAKE_GPU_STATE/modules"; done
  elif [[ "${FAKE_MODULE_LOADED:-1}" == "1" ]]; then
    printf 'nvidia\n' >>"$FAKE_GPU_STATE/modules"
  fi
  : >"$NVIDIA_DEVICE_NODE"

  if [[ -n "${FAKE_PROC_VERSION+x}" ]]; then
    if [[ -n "$FAKE_PROC_VERSION" ]]; then
      fake_gpu_write_proc "$FAKE_PROC_VERSION"
    else
      "$FAKE_REAL_RM" -f "$FAKE_PROC_FILE"
    fi
  else
    fake_gpu_write_proc "$(cat "$FAKE_GPU_STATE/driver_version" 2>/dev/null)"
  fi

  # --- nvidia-smi -----------------------------------------------------------
  cat >"$FAKE_GPU_BINDIR/nvidia-smi" <<'SHIM'
#!/usr/bin/env bash
printf 'nvidia-smi %s\n' "$*" >>"${FAKE_GPU_CALLS:-/dev/null}"
rc="${FAKE_SMI_RC:-0}"
[[ "$rc" == "0" ]] || exit "$rc"
v="$(cat "$FAKE_GPU_STATE/driver_version" 2>/dev/null)"
case "$*" in
  *driver_version*compute_cap*|*compute_cap*driver_version*)
                    [[ -n "$v" ]] || exit 1
                    printf '%s, %s\n' "$v" "${FAKE_COMPUTE_CAP:-7.5}" ;;
  *driver_version*) [[ -n "$v" ]] || exit 1; printf '%s\n' "$v" ;;
  *compute_cap*)    printf '%s\n' "${FAKE_COMPUTE_CAP:-7.5}" ;;
  *)                [[ -n "$v" ]] || exit 1
                    printf 'Fake NVIDIA-SMI\nDriver Version: %s\n' "$v" ;;
esac
SHIM

  # --- nvidia-uninstall -----------------------------------------------------
  cat >"$FAKE_GPU_BINDIR/nvidia-uninstall" <<'SHIM'
#!/usr/bin/env bash
printf 'nvidia-uninstall %s\n' "$*" >>"${FAKE_GPU_CALLS:-/dev/null}"
exit "${FAKE_UNINSTALL_RC:-0}"
SHIM

  # --- dnf ------------------------------------------------------------------
  # Dispatch on the SUBCOMMAND TOKEN, never substring order: `install
  # --downloadonly` is the stage, `install` is the offline install, and the
  # legacy `download` verb is still answered for old call sites. The full argv
  # is also recorded one token per line in $FAKE_DNF_ARGV for exact flag checks.
  cat >"$FAKE_GPU_BINDIR/dnf" <<'SHIM'
#!/usr/bin/env bash
printf 'dnf %s\n' "$*" >>"${FAKE_GPU_CALLS:-/dev/null}"
for a in "$@"; do printf '%s\n' "$a" >>"${FAKE_DNF_ARGV:-/dev/null}"; done

stage_dest=""
has_downloadonly=0
subcmd=""
prev=""
for a in "$@"; do
  [[ "$a" == "--downloadonly" ]] && has_downloadonly=1
  [[ "$prev" == "--destdir" ]] && stage_dest="$a"
  [[ -z "$subcmd" && "$a" != -* ]] && subcmd="$a"
  prev="$a"
done

closure_dest() {
  local dest="$1" arch="$2" incomplete="$3" variant="$4"
  "$FAKE_REAL_MKDIR" -p "$dest"
  if [[ "$arch" == "aarch64" ]]; then
    : >"$dest/nvidia-open-620.70.06-1.amzn2023.noarch.rpm"
    [[ "$incomplete" == "1" ]] && return 0
    : >"$dest/nvidia-driver-cuda-620.70.06-1.amzn2023.aarch64.rpm"
    : >"$dest/nvidia-kmod-common-620.70.06-1.amzn2023.noarch.rpm"
    : >"$dest/kmod-nvidia-open-dkms-620.70.06-1.amzn2023.aarch64.rpm"
  else
    : >"$dest/nvidia-open-3:620.70.06-1.el9.x86_64.rpm"
    [[ "$incomplete" == "1" ]] && return 0
    : >"$dest/nvidia-driver-620.70.06-1.el9.x86_64.rpm"
    : >"$dest/nvidia-driver-cuda-620.70.06-1.el9.x86_64.rpm"
    : >"$dest/nvidia-kmod-common-620.70.06-1.el9.x86_64.rpm"
    if [[ "$variant" == "dkms" ]]; then
      : >"$dest/kmod-nvidia-open-dkms-620.70.06-1.el9.x86_64.rpm"
    else
      : >"$dest/kmod-nvidia-open-620.70.06-1.el9.x86_64.rpm"
    fi
  fi
}

case "$subcmd" in
  install)
    if [[ "$has_downloadonly" == "1" ]]; then
      [[ "${FAKE_PKG_AVAILABLE:-1}" == "1" ]] || exit 1
      [[ -n "$stage_dest" ]] || exit 1
      closure_dest "$stage_dest" "${FAKE_ARCH:-x86_64}" \
        "${FAKE_DNF_CLOSURE_INCOMPLETE:-0}" \
        "$(cat "$FAKE_GPU_STATE/kmod_variant" 2>/dev/null || echo kmod)"
      exit "${FAKE_DNF_DOWNLOADONLY_RC:-0}"
    fi
    rc="${FAKE_DNF_RC:-0}"
    if [[ "$rc" == "0" && "${FAKE_DNF_UPGRADES_DRIVER:-1}" != "0" ]]; then
      printf '620.70.06' >"$FAKE_GPU_STATE/driver_version"
      printf '1' >"$FAKE_GPU_STATE/rpm_installed"
    fi
    exit "$rc"
    ;;
  config-manager)
    exit 0
    ;;
  list)
    [[ "${FAKE_PKG_AVAILABLE:-1}" == "1" ]] && exit 0 || exit 1
    ;;
  download)
    # legacy path (must no longer be used by lib/nvidia.sh)
    [[ "${FAKE_PKG_AVAILABLE:-1}" == "1" ]] || exit 1
    [[ -n "$stage_dest" ]] || exit 1
    closure_dest "$stage_dest" "${FAKE_ARCH:-x86_64}" 0 kmod
    exit "${FAKE_DNF_RC:-0}"
    ;;
  *) exit 0 ;;
esac
SHIM

  # --- rpm ------------------------------------------------------------------
  cat >"$FAKE_GPU_BINDIR/rpm" <<'SHIM'
#!/usr/bin/env bash
printf 'rpm %s\n' "$*" >>"${FAKE_GPU_CALLS:-/dev/null}"
installed="$(cat "$FAKE_GPU_STATE/rpm_installed" 2>/dev/null)"
version="$(cat "$FAKE_GPU_STATE/driver_version" 2>/dev/null)"
variant="$(cat "$FAKE_GPU_STATE/kmod_variant" 2>/dev/null)"
args="$*"
case "$args" in
  *'--import'*)
    [[ "${FAKE_DNF_KEY_MISSING:-0}" == "1" ]] && exit 1
    exit 0
    ;;
  *'-qlp'*|*'-q'*'-p'*'-l'*)
    [[ "${FAKE_PAYLOAD_MISSING_MODULE:-0}" == "1" ]] && exit 0
    printf '/lib/modules/%s/kernel/drivers/video/nvidia.ko\n' "${FAKE_KERNEL_RELEASE:-5.10.240-217.935.amzn2.x86_64}"
    exit 0
    ;;
  *'-qp'*|*'-q'*'--package'*)
    case "$args" in
      *'%{NEVRA}'*) printf '%s\n' "${FAKE_NEVRA:-nvidia-open-3:620.70.06-1.el9.x86_64}" ;;
      *'%{VERSION}'*) printf '%s\n' "$version" ;;
      *) printf 'nvidia-open-%s\n' "$version" ;;
    esac
    exit 0
    ;;
  *'-K'*)
    [[ "${FAKE_DNF_KEY_MISSING:-0}" == "1" ]] && exit 1
    exit 0
    ;;
  *'kmod-nvidia-open-dkms'*)
    [[ "$variant" == "dkms" && "$installed" == "1" ]] && exit 0 || exit 1
    ;;
  *'kmod-nvidia-open'*)
    [[ "$variant" == "kmod" && "$installed" == "1" ]] && exit 0 || exit 1
    ;;
  *'-q'*)
    [[ "$installed" == "1" ]] || { printf 'package nvidia-open is not installed\n'; exit 1; }
    case "$args" in
      *'%{VERSION}'*) printf '%s\n' "$version" ;;
      *) printf 'nvidia-open-3:%s-1.el9\n' "$version" ;;
    esac
    exit 0
    ;;
  *) exit 0 ;;
esac
SHIM

  # --- modinfo --------------------------------------------------------------
  cat >"$FAKE_GPU_BINDIR/modinfo" <<'SHIM'
#!/usr/bin/env bash
printf 'modinfo %s\n' "$*" >>"${FAKE_GPU_CALLS:-/dev/null}"
[[ "${FAKE_MODINFO_MISSING:-0}" == "1" ]] && exit 1
installed="$(cat "$FAKE_GPU_STATE/rpm_installed" 2>/dev/null)"
[[ "$installed" == "1" || "${FAKE_RUN_MANAGED:-0}" == "1" ]] || exit 1
v="$(cat "$FAKE_GPU_STATE/driver_version" 2>/dev/null)"
[[ -n "$v" ]] || exit 1
case " $* " in
  *" -n "*|*" --filename "*)
    d="$FAKE_GPU_STATE/lib/modules/${FAKE_KERNEL_RELEASE:-5.10.240-217.935.amzn2.x86_64}/kernel/drivers/video"
    "$FAKE_REAL_MKDIR" -p "$d"
    : >"$d/nvidia.ko"
    printf '%s\n' "$d/nvidia.ko"
    ;;
  *)
    printf '%s\n' "$v"
    ;;
esac
SHIM

  # --- modprobe / rmmod / depmod / lsmod / fuser ----------------------------
  cat >"$FAKE_GPU_BINDIR/modprobe" <<'SHIM'
#!/usr/bin/env bash
printf 'modprobe %s\n' "$*" >>"${FAKE_GPU_CALLS:-/dev/null}"
remove=0
mod=""
for a in "$@"; do
  case "$a" in
    -r|--remove) remove=1 ;;
    -*) ;;
    *) [[ -z "$mod" ]] && mod="$a" ;;
  esac
done
if [[ "$remove" == "1" ]]; then
  [[ "${FAKE_RMMOD_BUSY:-0}" == "1" ]] && exit 1
  if [[ -n "$mod" ]] && grep -qx "$mod" "$FAKE_GPU_STATE/modules" 2>/dev/null; then
    grep -vx "$mod" "$FAKE_GPU_STATE/modules" >"$FAKE_GPU_STATE/modules.new" || true
    mv "$FAKE_GPU_STATE/modules.new" "$FAKE_GPU_STATE/modules"
  fi
  if [[ "$mod" == "nvidia" && "${FAKE_PROC_VERSION_STUCK:-0}" != "1" ]]; then
    "$FAKE_REAL_RM" -f "$NVIDIA_PROC_VERSION_FILE"
  fi
  exit 0
fi
rc="${FAKE_MODPROBE_RC:-0}"
[[ "$rc" == "0" ]] || exit "$rc"
if [[ "$mod" == "nvidia" ]]; then
  grep -qx nvidia "$FAKE_GPU_STATE/modules" 2>/dev/null || printf 'nvidia\n' >>"$FAKE_GPU_STATE/modules"
  if [[ "${FAKE_PROC_VERSION_STUCK:-0}" != "1" ]]; then
    v="$(cat "$FAKE_GPU_STATE/driver_version" 2>/dev/null)"
    [[ -n "$v" ]] && printf 'NVRM version: NVIDIA UNIX Open Kernel Module for x86_64  %s  Release Build\n' "$v" >"$NVIDIA_PROC_VERSION_FILE"
  fi
else
  grep -qx "$mod" "$FAKE_GPU_STATE/modules" 2>/dev/null || printf '%s\n' "$mod" >>"$FAKE_GPU_STATE/modules"
fi
exit 0
SHIM

  cat >"$FAKE_GPU_BINDIR/rmmod" <<'SHIM'
#!/usr/bin/env bash
printf 'rmmod %s\n' "$*" >>"${FAKE_GPU_CALLS:-/dev/null}"
[[ "${FAKE_RMMOD_BUSY:-0}" == "1" ]] && exit 1
for mod in "$@"; do
  if grep -qx "$mod" "$FAKE_GPU_STATE/modules" 2>/dev/null; then
    grep -vx "$mod" "$FAKE_GPU_STATE/modules" >"$FAKE_GPU_STATE/modules.new" || true
    mv "$FAKE_GPU_STATE/modules.new" "$FAKE_GPU_STATE/modules"
  fi
  if [[ "$mod" == "nvidia" && "${FAKE_PROC_VERSION_STUCK:-0}" != "1" ]]; then
    "$FAKE_REAL_RM" -f "$NVIDIA_PROC_VERSION_FILE"
  fi
done
exit 0
SHIM

  cat >"$FAKE_GPU_BINDIR/depmod" <<'SHIM'
#!/usr/bin/env bash
printf 'depmod %s\n' "$*" >>"${FAKE_GPU_CALLS:-/dev/null}"
exit 0
SHIM

  cat >"$FAKE_GPU_BINDIR/lsmod" <<'SHIM'
#!/usr/bin/env bash
printf 'lsmod %s\n' "$*" >>"${FAKE_GPU_CALLS:-/dev/null}"
while IFS= read -r m; do
  [[ -n "$m" ]] && printf '%-20s 123  0\n' "$m"
done <"$FAKE_GPU_STATE/modules"
exit 0
SHIM

  cat >"$FAKE_GPU_BINDIR/fuser" <<'SHIM'
#!/usr/bin/env bash
printf 'fuser %s\n' "$*" >>"${FAKE_GPU_CALLS:-/dev/null}"
[[ "${FAKE_HOLDER:-0}" == "1" ]] && exit 0
exit 1
SHIM

  # --- dkms -----------------------------------------------------------------
  cat >"$FAKE_GPU_BINDIR/dkms" <<'SHIM'
#!/usr/bin/env bash
printf 'dkms %s\n' "$*" >>"${FAKE_GPU_CALLS:-/dev/null}"
case "$*" in
  status*) [[ -n "${FAKE_DKMS_STATUS:-}" ]] && printf '%s\n' "$FAKE_DKMS_STATUS" ;;
  *)       ;;
esac
exit "${FAKE_DKMS_RC:-0}"
SHIM

  # --- systemctl ------------------------------------------------------------
  # is-active reads the per-unit state files so a stop flips them and a
  # subsequent is-active observes the transition (used by the drain wait).
  cat >"$FAKE_GPU_BINDIR/systemctl" <<'SHIM'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"${FAKE_GPU_CALLS:-/dev/null}"
active_file() {
  case "$1" in
    nvidia-dcgm-exporter.service) printf '%s' "$FAKE_GPU_STATE/dcgm_exporter_active" ;;
    nvidia-dcgm.service)          printf '%s' "$FAKE_GPU_STATE/dcgm_active" ;;
    *) printf '' ;;
  esac
}
case "$*" in
  *'is-active'*'strimserver.service'*)
    [[ "${FAKE_STRIMSERVER_ACTIVE:-1}" == "1" ]] && exit 0 || exit 3 ;;
  *'is-active'*'nvidia-fabricmanager.service'*)
    [[ "${FAKE_FABRICMANAGER_UNIT:-0}" == "1" ]] && exit 0 || exit 3 ;;
  *'is-active'*'nvidia-dcgm-exporter.service'*)
    f="$(active_file nvidia-dcgm-exporter.service)"
    [[ -n "$f" && "$(cat "$f" 2>/dev/null)" == "1" ]] && exit 0 || exit 3 ;;
  *'is-active'*'nvidia-dcgm.service'*)
    f="$(active_file nvidia-dcgm.service)"
    [[ -n "$f" && "$(cat "$f" 2>/dev/null)" == "1" ]] && exit 0 || exit 3 ;;
  *'stop'*'nvidia-dcgm-exporter.service'*)
    [[ "${FAKE_DCGM_EXPORTER_STUCK:-0}" == "1" ]] || printf '0' >"$FAKE_GPU_STATE/dcgm_exporter_active"
    exit 0 ;;
  *'stop'*'nvidia-dcgm.service'*)
    [[ "${FAKE_DCGM_STUCK:-0}" == "1" ]] || printf '0' >"$FAKE_GPU_STATE/dcgm_active"
    exit 0 ;;
  *'cat'*'nvidia-dcgm-exporter.service'*|*'list-unit-files'*'nvidia-dcgm-exporter'*)
    [[ "${FAKE_DCGM_EXPORTER_UNIT:-0}" == "1" ]] && exit 0 || exit 1 ;;
  *'cat'*'nvidia-dcgm.service'*|*'list-unit-files'*'nvidia-dcgm.service'*)
    [[ "${FAKE_DCGM_UNIT:-0}" == "1" ]] && exit 0 || exit 1 ;;
  *'cat'*'nvidia-fabricmanager.service'*|*'list-unit-files'*'nvidia-fabricmanager'*)
    [[ "${FAKE_FABRICMANAGER_UNIT:-0}" == "1" ]] && exit 0 || exit 1 ;;
  *'cat'*)
    exit 0 ;;
  *) exit 0 ;;
esac
SHIM

  # --- uname / nvidia-ctk / filesystem --------------------------------------
  # nvidia-ctk writes an absolute path under /var/run; the fs no-op keeps the
  # execution hermetic while still recording the argv the script used. mkdir,
  # rm and cp are real so the atomic stage swap can be exercised for real.
  cat >"$FAKE_GPU_BINDIR/uname" <<'SHIM'
#!/usr/bin/env bash
printf 'uname %s\n' "$*" >>"${FAKE_GPU_CALLS:-/dev/null}"
case "$*" in
  *-r*) printf '%s\n' "${FAKE_KERNEL_RELEASE:-5.10.240-217.935.amzn2.x86_64}" ;;
  *-m*) printf '%s\n' "${FAKE_ARCH:-x86_64}" ;;
  *)    printf '%s\n' "${FAKE_ARCH:-x86_64}" ;;
esac
SHIM

  cat >"$FAKE_GPU_BINDIR/nvidia-ctk" <<'SHIM'
#!/usr/bin/env bash
printf 'nvidia-ctk %s\n' "$*" >>"${FAKE_GPU_CALLS:-/dev/null}"
exit 0
SHIM

  cat >"$FAKE_GPU_BINDIR/mkdir" <<'SHIM'
#!/usr/bin/env bash
printf 'mkdir %s\n' "$*" >>"${FAKE_GPU_CALLS:-/dev/null}"
# Create the directory when the sandbox allows it; emulate a privileged success
# for absolute system paths (e.g. /var/run/cdi) so the harness stays hermetic.
"$FAKE_REAL_MKDIR" "$@" 2>/dev/null && exit 0
exit 0
SHIM

  cat >"$FAKE_GPU_BINDIR/rm" <<'SHIM'
#!/usr/bin/env bash
printf 'rm %s\n' "$*" >>"${FAKE_GPU_CALLS:-/dev/null}"
exec "$FAKE_REAL_RM" "$@"
SHIM

  cat >"$FAKE_GPU_BINDIR/cp" <<'SHIM'
#!/usr/bin/env bash
printf 'cp %s\n' "$*" >>"${FAKE_GPU_CALLS:-/dev/null}"
"$FAKE_REAL_CP" "$@" 2>/dev/null && exit 0
exit 0
SHIM

  # --- fake-sudo ------------------------------------------------------------
  cat >"$FAKE_GPU_BINDIR/fake-sudo" <<'SHIM'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"${FAKE_GPU_CALLS:-/dev/null}"
exec "$@"
SHIM

  if [[ "${FAKE_SMI_MISSING:-0}" == "1" ]]; then
    "$FAKE_REAL_RM" -f "$FAKE_GPU_BINDIR/nvidia-smi"
  fi

  chmod +x "$FAKE_GPU_BINDIR"/*
  PATH="$FAKE_GPU_BINDIR:$PATH"
  export PATH
}

# Print the recorded calls (one per line).
fake_gpu_calls() {
  cat "${FAKE_GPU_CALLS:?fake_gpu_install must run first}"
}

# Print the recorded dnf argv tokens (one per line).
fake_dnf_argv() {
  cat "${FAKE_DNF_ARGV:?fake_gpu_install must run first}"
}

# Index of the first recorded call matching the ERE, or empty when absent.
fake_gpu_first_index() {
  local pattern="$1"
  awk -v pat="$pattern" '$0 ~ pat { print NR; exit }' "${FAKE_GPU_CALLS:?fake_gpu_install must run first}"
}

# Overwrite the reported driver version inside a live fake state dir.
fake_gpu_set_driver() {
  printf '%s' "$1" >"${FAKE_GPU_STATE:?fake_gpu_install must run first}/driver_version"
}

# Remove the fake bin + recorder + state.
fake_gpu_cleanup() {
  local rm_bin="${FAKE_REAL_RM:-rm}"
  [[ -n "${FAKE_GPU_BINDIR:-}" ]] && "$rm_bin" -rf "$FAKE_GPU_BINDIR"
  [[ -n "${FAKE_GPU_CALLS:-}" ]] && "$rm_bin" -f "$FAKE_GPU_CALLS"
  [[ -n "${FAKE_DNF_ARGV:-}" ]] && "$rm_bin" -f "$FAKE_DNF_ARGV"
  [[ -n "${FAKE_GPU_STATE:-}" ]] && "$rm_bin" -rf "$FAKE_GPU_STATE"
  return 0
}
