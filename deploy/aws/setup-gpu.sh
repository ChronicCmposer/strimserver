#!/usr/bin/env bash
#
# setup-gpu.sh - arch-aware NVIDIA GPU + containerd runtime setup for the
# strimserver deployment bundle.
#
# Runs as the deploy user (uses sudo), is idempotent and safe to re-run, and is
# invoked by deploy.sh BEFORE the containerd block so that deploy.sh's single
# `sudo systemctl restart containerd.service` happens after all GPU wiring here.
# This script deliberately does NOT restart containerd itself (see the ordering
# note below).
#
# Background
# ----------
# The deployment enforces a host NVIDIA driver floor of 620.70.06 (the exact
# R620 release CUDA 13.5 requires). This script sources lib/nvidia.sh and calls
# nvidia_ensure_driver_floor BEFORE any nvidia-smi guard, so a host whose
# driver is missing, below the floor, or left mid-swap is upgraded/recovered
# here instead of failing the deploy. The NVIDIA GPU DLAMI for AL2023 remains
# the normal source of the driver + container toolkit; PATH B below is now only
# a fallback for hosts that cannot upgrade via the pinned RPM. For the
# arm64 target (g5g.*, T4G) deploy/aws/launch selects the arm64 NVIDIA DLAMI
# via the SSM parameter
#   /aws/service/deeplearning/ami/arm64/
#     base-oss-nvidia-driver-gpu-amazon-linux-2023/latest/ami-id
# (or AMI_ID can point at one explicitly). It ships the driver (raised to the
# floor here when older), nvidia-container-toolkit (>= 1.15, so the nvidia
# runtime wrapper comes from the toolkit package - there is no separate
# nvidia-container-runtime package), and containerd 2.x. The amd64 path keeps
# the existing x86_64 DLAMI behavior.
#
# Option C (arm64) vs CDI injection (amd64)
# -----------------------------------------
# The assembly controller (arm64) creates containers on the RAW containerd
# API, where CDI annotation emission and containerd's default_runtime_name are
# INERT (CRI-only). Its GPU stages (normalize / scale-and-egress /
# single-stage-egress) therefore get the GPU per-container: the runc shim is
# pointed at nvidia-container-runtime via runc/options.Options{BinaryName} in
# the task options (Option C). nvidia-container-runtime is the toolkit's
# drop-in runc wrapper: when the bundle's process env carries
# NVIDIA_VISIBLE_DEVICES (which the FFmpeg image already sets) it injects the
# GPU via nvidia-container-cli, then execs real runc. So on arm64 the
# containerd default runtime is deliberately left UNCHANGED and no CDI files
# are generated: /usr/bin/nvidia-container-runtime just has to exist.
#
# The controllers (amd64) inject CDI themselves (the Go controller via
# cdi.WithCDIDevices, the C controller via its JSON-only CDI scanner), reading
# JSON specs from the bind-mounted /var/run/cdi (strimserver.service mounts
# /var/run/cdi into the controller container), so the amd64 branch generates
# that spec; the default runtime is also left unchanged (behavior-preserving).
#
# Ordering note
# -------------
# deploy.sh runs this script, then prepends root/state to /etc/containerd/
# config.toml and restarts containerd exactly once. Under Option C this script
# no longer writes a containerd drop-in (no nvidia-ctk runtime configure), so
# the single restart only picks up deploy.sh's root/state config prepend. Do
# not restart containerd here.
#
# PATH B - manual driver install on a stock AL2023 arm64 AMI (FALLBACK ONLY)
# -------------------------------------------------------------------------
# The amazonlinux-nvidia repo is x86_64-only, so an arm64 manual install MUST
# use NVIDIA's CUDA repo with the sbsa (NOT aarch64) architecture token. The
# pinned-RPM upgrade above is the normal path; the commands below are a
# last-resort fallback for operators who deliberately launch from a stock
# AL2023 arm64 AMI instead of the arm64 DLAMI; this script never executes them.
# Re-run this script afterwards to enforce the 620.70.06 floor.
#
#   dnf config-manager --add-repo \
#     https://developer.download.nvidia.com/compute/cuda/repos/amzn2023/sbsa/cuda-amzn2023.repo
#   dnf install -y --allowerasing \
#     kernel6.12-devel-$(uname -r) kernel6.12-headers-$(uname -r) \
#     kernel6.12-modules-extra-$(uname -r) dkms
#   dnf module enable -y nvidia-driver:open-dkms
#   dnf install -y nvidia-open nvidia-xconfig nvidia-persistenced nvidia-modprobe
#   curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
#     -o /etc/yum.repos.d/nvidia-container-toolkit.repo
#   dnf install -y nvidia-container-toolkit
#   sudo reboot   # DKMS builds and loads the nvidia kernel modules
#
# Then re-run this script for the GPU runtime/persistenced wiring.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/nvidia.sh
source "$script_dir/lib/nvidia.sh"
SUDO="${SUDO:-sudo}"

# --stage-only: stage + validate the 620 closure and exit before any driver
# action (no marker, drain, uninstall, or install). NVIDIA_STAGE_ONLY=1 is the
# equivalent environment form.
for arg in "$@"; do
   case "$arg" in
      --stage-only) export NVIDIA_STAGE_ONLY=1 ;;
      *)
         printf 'setup-gpu.sh: unknown argument: %s\n' "$arg" >&2
         exit 2
         ;;
   esac
done

# --- arch detection ----------------------------------------------------------
MACHINE="$(uname -m)"
if [[ "$MACHINE" == "aarch64" ]]; then
   ARCH="arm64"
else
   ARCH="amd64"
fi

printf "configuring NVIDIA GPU runtime (%s)...\n" "$ARCH"

# Can a missing nvidia-smi still be recovered? A pending resume marker or an
# installable pinned package means yes; otherwise the guard below fails closed.
nvidia_recovery_possible() {
   [[ -e "${NVIDIA_RESUME_MARKER:-/var/lib/strimserver/driver-upgrade.state}" ]] && return 0
   command -v dnf >/dev/null 2>&1 || return 1
   local nevra
   nevra="$(nvidia__pinned_nevra "$MACHINE")" || return 1
   "$SUDO" dnf --quiet list --available "$nevra" >/dev/null 2>&1
}

# --- driver floor: upgrade/recovery runs BEFORE the nvidia-smi guard ----------
# nvidia_ensure_driver_floor detects the installed driver, upgrades to the floor
# when needed and finishes a half-completed swap. It MUST run before the guard,
# because after a failed swap the nvidia-smi binary may be temporarily absent.
if ! nvidia_ensure_driver_floor; then
   printf "\n*** ERROR: the NVIDIA driver is below the %s floor and could not be upgraded/recovered. ***\n" "$NVIDIA_DRIVER_FLOOR"
   printf "Inspect the nvidia: ERROR lines above for the failing state and its recovery command.\n\n"
   exit 1
fi

# Stage-only mode stops here: the closure has been staged and validated, and no
# driver action (marker, drain, uninstall, install) was taken.
if [[ "${NVIDIA_STAGE_ONLY:-0}" == "1" ]]; then
   printf "stage-only: staged and validated the %s closure; no driver action taken\n" "$NVIDIA_DRIVER_FLOOR"
   exit 0
fi

# --- fail-loud guard: no driver AND nothing left to install ------------------
if ! command -v nvidia-smi >/dev/null 2>&1; then
   if ! nvidia_recovery_possible; then
      printf "\n*** ERROR: NVIDIA driver not found on this %s instance. ***\n" "$ARCH"
      if [[ "$ARCH" == "arm64" ]]; then
         printf "The arm64 strimserver target (g5g.*) MUST run on the arm64 NVIDIA DLAMI\n"
         printf "for AL2023 - the amazonlinux-nvidia repo is x86_64-only. deploy/aws/launch\n"
         printf "selects this AMI automatically for g5g* via the SSM parameter\n"
         printf "  /aws/service/deeplearning/ami/arm64/\n"
         printf "    base-oss-nvidia-driver-gpu-amazon-linux-2023/latest/ami-id\n"
         printf "(or set AMI_ID to an arm64 NVIDIA DLAMI explicitly). A stock AL2023 arm64\n"
         printf "AMI requires the manual driver install (PATH B) documented at the top of\n"
         printf "deploy/aws/setup-gpu.sh; that path is reference only and is NOT run here.\n\n"
      else
         printf "The amd64 strimserver target relies on the x86_64 NVIDIA DLAMI for the\n"
         printf "driver and container toolkit. Relaunch from the AL2023 GPU DLAMI\n"
         printf "(deploy/aws/launch's default for amd64 instance types).\n\n"
      fi
      exit 1
   fi
   printf "nvidia-smi is not on PATH yet; the module-load step below will recover it.\n"
fi

# --- verify the driver actually initializes (T4G visible on g5g) --------------
# A failing nvidia-smi means the module is not loaded (not that the driver is
# absent): reload the module graph and re-check the floor before failing.
printf "verifying NVIDIA driver...\n"
if ! nvidia-smi; then
   printf "nvidia-smi failed; treating the driver module as unloaded and reloading...\n"
   "$SUDO" depmod -a
   "$SUDO" modprobe nvidia
   "$SUDO" modprobe nvidia_uvm
   if ! nvidia_ensure_driver_floor; then
      printf "\n*** ERROR: the NVIDIA driver did not reach the %s floor after reloading. ***\n\n" "$NVIDIA_DRIVER_FLOOR"
      exit 1
   fi
   if ! nvidia-smi; then
      printf "\n*** ERROR: the NVIDIA driver is installed but nvidia-smi still fails. ***\n"
      printf "Inspect: dmesg | tail ; modinfo nvidia ; lsmod | grep nvidia\n\n"
      exit 1
   fi
fi

# --- Option C / CDI wiring ----------------------------------------------------
# The driver floor is already verified (and the module loaded) above, so any
# CDI spec generated below reflects a working 620.70.06 driver.
# containerd is restarted exactly once by deploy.sh AFTER this script, so any
# containerd config change below is picked up together with deploy.sh's
# root/state config prepend. Do not restart containerd here.
if [[ "$ARCH" == "arm64" ]]; then
   # arm64 (Option C): the assembly controller speaks the RAW containerd API,
   # where CDI annotations and default_runtime_name are INERT. GPU stages get
   # the GPU per-container: the runc shim execs nvidia-container-runtime
   # (runc/options.Options{BinaryName} in the task options). That binary is
   # shipped by nvidia-container-toolkit; it MUST exist on the host.
   printf "verifying the Option C runtime binary...\n"
   if [[ ! -x /usr/bin/nvidia-container-runtime ]]; then
      printf "\n*** ERROR: /usr/bin/nvidia-container-runtime not found. ***\n"
      printf "The arm64 assembly controller points the runc shim at this binary for\n"
      printf "the GPU (ffmpeg) stages; it is provided by the nvidia-container-toolkit\n"
      printf "package. Launch from the arm64 NVIDIA DLAMI for AL2023 (which ships the\n"
      printf "toolkit; deploy/aws/launch selects it for g5g* automatically), or install\n"
      printf "the toolkit manually on a stock AMI (PATH B at the top of this script),\n"
      printf "then re-run this setup.\n\n"
      exit 1
   fi
   # NOTE: no runtime configure (--set-as-default or otherwise) and no CDI
   # generation here - both are CRI-only / unused by the raw-API assembly
   # controller. The default runtime stays plain runc.
   "$SUDO" systemctl enable --now nvidia-persistenced
else
   # amd64: the controllers inject CDI themselves (the Go controller via
   # cdi.WithCDIDevices, the C controller via its JSON-only CDI scanner), so
   # generate a JSON spec into /var/run/cdi, the directory bind-mounted into
   # the controller container (strimserver.service). A copy is also kept in
   # /etc/cdi for host-side tooling. The default runtime is deliberately left
   # unchanged (behavior-preserving; no --set-as-default).
   printf "generating the CDI device spec for the controllers...\n"
   "$SUDO" mkdir -p /var/run/cdi /etc/cdi
   # Remove stale YAML (and any old JSON) from the dynamic dir first: the Go
   # CDI cache hard-fails when the same device appears in both nvidia.yaml and
   # nvidia.json in the same directory ("unresolvable CDI devices"). We ship
   # JSON only (canonical CDI format; both the C and Go controllers read it).
   "$SUDO" rm -f /var/run/cdi/nvidia.yaml /var/run/cdi/nvidia.yml /var/run/cdi/nvidia.json
   "$SUDO" nvidia-ctk cdi generate --format=json --output=/var/run/cdi/nvidia.json
   # Same hygiene for the /etc/cdi copy: a stale YAML beside the JSON we copy
   # would be a same-dir duplicate conflict for host-side Go CDI tooling.
   "$SUDO" rm -f /etc/cdi/nvidia.yaml /etc/cdi/nvidia.yml
   "$SUDO" cp /var/run/cdi/nvidia.json /etc/cdi/nvidia.json
   "$SUDO" systemctl enable --now nvidia-persistenced
fi
printf "NVIDIA runtime wiring done!\n"

# --- NVENC userspace check (arm64 only; amd64 behavior unchanged) --------------
if [[ "$ARCH" == "arm64" ]]; then
   printf "verifying NVENC userspace...\n"
   if [[ -e /usr/lib64/libnvidia-encode.so.1 ]]; then
      printf "NVENC userspace present: /usr/lib64/libnvidia-encode.so.1\n"
   else
      printf "\n*** WARNING: /usr/lib64/libnvidia-encode.so.1 not found. ***\n"
      printf "NVENC will fail inside the FFmpeg container. Reinstall the driver or\n"
      printf "launch from a current arm64 NVIDIA DLAMI, then re-run this setup.\n\n"
   fi
fi

printf "NVIDIA GPU runtime configured (%s)!\n" "$ARCH"