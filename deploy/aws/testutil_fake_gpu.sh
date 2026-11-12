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
# version that the re-verify step observes:
#   driver_version  current reported driver version
#   rpm_installed   1 when `rpm -q nvidia-open` should succeed
#
# Response knobs (read at call time, so tests may change them mid-run):
#   FAKE_REPORTED_DRIVER      initial reported driver (default 620.70.06;
#                             set to "" for a host with no detectable driver)
#   FAKE_COMPUTE_CAP          compute_cap reported by nvidia-smi (default 7.5)
#   FAKE_DNF_RC               rc for `dnf download`/`dnf install` (default 0)
#   FAKE_PKG_AVAILABLE        0 -> `dnf download` fails (package missing)
#   FAKE_RMMOD_BUSY           1 -> `rmmod` fails as if a module were in use
#   FAKE_SMI_RC               rc for nvidia-smi (default 0)
#   FAKE_SMI_MISSING          1 -> do not install an nvidia-smi shim at all
#   FAKE_RPM_INSTALLED        1 -> `rpm -q nvidia-open` succeeds
#   FAKE_RUN_MANAGED          1 -> modinfo reports a version with no RPM
#   FAKE_UNINSTALL_RC         rc for `nvidia-uninstall` (default 0)
#   FAKE_MODPROBE_RC          rc for `modprobe` (default 0)
#   FAKE_DNF_UPGRADES_DRIVER  0 -> dnf install leaves the old driver in place
#   FAKE_HOLDER               1 -> `fuser` reports a /dev/nvidia* holder
#   FAKE_MODULE_LOADED        1 -> `lsmod` lists nvidia (default 1)
#   FAKE_STRIMSERVER_ACTIVE   1 -> `systemctl is-active strimserver.service`
#   FAKE_FABRICMANAGER_UNIT   1 -> `systemctl cat nvidia-fabricmanager.service`
#   FAKE_ARCH                 uname -m value (default x86_64)
#   FAKE_NEVRA                value printed by `rpm -qp --qf '%{NEVRA}'`
#
# Not intended to be executed directly.

fake_gpu_install() {
  # Resolve real tools before the shims shadow them; the shims and cleanup use
  # these absolute paths so they never recurse into themselves.
  FAKE_REAL_MKDIR="$(type -P mkdir)"
  FAKE_REAL_RM="$(type -P rm)"
  export FAKE_REAL_MKDIR FAKE_REAL_RM
  FAKE_GPU_BINDIR="$(mktemp -d)"
  FAKE_GPU_CALLS="$(mktemp)"
  FAKE_GPU_STATE="$(mktemp -d)"
  export FAKE_GPU_BINDIR FAKE_GPU_CALLS FAKE_GPU_STATE

  printf '%s' "${FAKE_REPORTED_DRIVER-620.70.06}" >"$FAKE_GPU_STATE/driver_version"
  printf '%s' "${FAKE_RPM_INSTALLED:-0}" >"$FAKE_GPU_STATE/rpm_installed"

  # --- nvidia-smi -----------------------------------------------------------
  cat >"$FAKE_GPU_BINDIR/nvidia-smi" <<'SHIM'
#!/usr/bin/env bash
printf 'nvidia-smi %s\n' "$*" >>"${FAKE_GPU_CALLS:-/dev/null}"
rc="${FAKE_SMI_RC:-0}"
[[ "$rc" == "0" ]] || exit "$rc"
v="$(cat "$FAKE_GPU_STATE/driver_version" 2>/dev/null)"
case "$*" in
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
  cat >"$FAKE_GPU_BINDIR/dnf" <<'SHIM'
#!/usr/bin/env bash
printf 'dnf %s\n' "$*" >>"${FAKE_GPU_CALLS:-/dev/null}"
args="$*"
case "$args" in
  *download*)
    [[ "${FAKE_PKG_AVAILABLE:-1}" == "1" ]] || exit 1
    dest=""
    prev=""
    for a in "$@"; do
      [[ "$prev" == "--destdir" ]] && dest="$a"
      prev="$a"
    done
    [[ -n "$dest" ]] || exit 1
    "$FAKE_REAL_MKDIR" -p "$dest"
    : >"$dest/nvidia-open-620.70.06-1.el9.x86_64.rpm"
    exit "${FAKE_DNF_RC:-0}"
    ;;
  *install*)
    rc="${FAKE_DNF_RC:-0}"
    if [[ "$rc" == "0" && "${FAKE_DNF_UPGRADES_DRIVER:-1}" != "0" ]]; then
      printf '620.70.06' >"$FAKE_GPU_STATE/driver_version"
      printf '1' >"$FAKE_GPU_STATE/rpm_installed"
    fi
    exit "$rc"
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
args="$*"
case "$args" in
  *'-qp'*|*'-q'*'--package'*)
    # querying a staged file
    case "$args" in
      *'%{NEVRA}'*) printf '%s\n' "${FAKE_NEVRA:-nvidia-open-3:620.70.06-1.el9.x86_64}" ;;
      *'%{VERSION}'*) printf '%s\n' "$version" ;;
      *) printf 'nvidia-open-%s\n' "$version" ;;
    esac
    exit 0
    ;;
  *'-K'*) exit 0 ;;
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
installed="$(cat "$FAKE_GPU_STATE/rpm_installed" 2>/dev/null)"
[[ "$installed" == "1" || "${FAKE_RUN_MANAGED:-0}" == "1" ]] || exit 1
v="$(cat "$FAKE_GPU_STATE/driver_version" 2>/dev/null)"
[[ -n "$v" ]] || exit 1
printf '%s\n' "$v"
SHIM

  # --- modprobe / rmmod / depmod / lsmod / fuser ----------------------------
  cat >"$FAKE_GPU_BINDIR/modprobe" <<'SHIM'
#!/usr/bin/env bash
printf 'modprobe %s\n' "$*" >>"${FAKE_GPU_CALLS:-/dev/null}"
exit "${FAKE_MODPROBE_RC:-0}"
SHIM

  cat >"$FAKE_GPU_BINDIR/rmmod" <<'SHIM'
#!/usr/bin/env bash
printf 'rmmod %s\n' "$*" >>"${FAKE_GPU_CALLS:-/dev/null}"
[[ "${FAKE_RMMOD_BUSY:-0}" == "1" ]] && exit 1
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
[[ "${FAKE_MODULE_LOADED:-1}" == "1" ]] && printf 'nvidia               123  0\n'
exit 0
SHIM

  cat >"$FAKE_GPU_BINDIR/fuser" <<'SHIM'
#!/usr/bin/env bash
printf 'fuser %s\n' "$*" >>"${FAKE_GPU_CALLS:-/dev/null}"
[[ "${FAKE_HOLDER:-0}" == "1" ]] && exit 0
exit 1
SHIM

  # --- systemctl ------------------------------------------------------------
  cat >"$FAKE_GPU_BINDIR/systemctl" <<'SHIM'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"${FAKE_GPU_CALLS:-/dev/null}"
case "$*" in
  *'is-active'*'strimserver.service'*)
    [[ "${FAKE_STRIMSERVER_ACTIVE:-1}" == "1" ]] && exit 0 || exit 3 ;;
  *'is-active'*'nvidia-fabricmanager.service'*)
    [[ "${FAKE_FABRICMANAGER_UNIT:-0}" == "1" ]] && exit 0 || exit 3 ;;
  *'cat'*'nvidia-fabricmanager.service'*|*'list-unit-files'*'nvidia-fabricmanager'*)
    [[ "${FAKE_FABRICMANAGER_UNIT:-0}" == "1" ]] && exit 0 || exit 1 ;;
  *) exit 0 ;;
esac
SHIM

  # --- uname / nvidia-ctk / filesystem no-ops ------------------------------
  # nvidia-ctk writes an absolute path under /var/run; the fs no-ops keep the
  # execution hermetic while still recording the argv the script used.
  cat >"$FAKE_GPU_BINDIR/uname" <<'SHIM'
#!/usr/bin/env bash
printf 'uname %s\n' "$*" >>"${FAKE_GPU_CALLS:-/dev/null}"
case "$*" in
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
exit 0
SHIM

  cat >"$FAKE_GPU_BINDIR/rm" <<'SHIM'
#!/usr/bin/env bash
printf 'rm %s\n' "$*" >>"${FAKE_GPU_CALLS:-/dev/null}"
exit 0
SHIM

  cat >"$FAKE_GPU_BINDIR/cp" <<'SHIM'
#!/usr/bin/env bash
printf 'cp %s\n' "$*" >>"${FAKE_GPU_CALLS:-/dev/null}"
exit 0
SHIM

  # --- fake-sudo ------------------------------------------------------------
  cat >"$FAKE_GPU_BINDIR/fake-sudo" <<'SHIM'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"${FAKE_GPU_CALLS:-/dev/null}"
exec "$@"
SHIM

  if [[ "${FAKE_SMI_MISSING:-0}" != "1" ]]; then
    : # nvidia-smi shim already written above
  else
    command rm -f "$FAKE_GPU_BINDIR/nvidia-smi"
  fi

  chmod +x "$FAKE_GPU_BINDIR"/*
  PATH="$FAKE_GPU_BINDIR:$PATH"
  export PATH
}

# Print the recorded calls (one per line).
fake_gpu_calls() {
  cat "${FAKE_GPU_CALLS:?fake_gpu_install must run first}"
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
  [[ -n "${FAKE_GPU_STATE:-}" ]] && "$rm_bin" -rf "$FAKE_GPU_STATE"
  return 0
}
