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
# The deployment relies entirely on the NVIDIA GPU DLAMI for AL2023 for the
# driver + NVIDIA container toolkit; nothing here installs a driver. For the
# arm64 target (g5g.*, T4G) deploy/aws/launch selects the arm64 NVIDIA DLAMI
# via the SSM parameter
#   /aws/service/deeplearning/ami/arm64/
#     base-oss-nvidia-driver-gpu-amazon-linux-2023/latest/ami-id
# (or AMI_ID can point at one explicitly). It ships the driver (595.x),
# nvidia-container-toolkit (>= 1.15, so the nvidia runtime wrapper comes from
# the toolkit package - there is no separate nvidia-container-runtime package),
# and containerd 2.x. The amd64 path keeps the existing x86_64 DLAMI behavior.
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
# PATH B - manual driver install on a stock AL2023 arm64 AMI (REFERENCE ONLY)
# ---------------------------------------------------------------------------
# The amazonlinux-nvidia repo is x86_64-only, so an arm64 manual install MUST
# use NVIDIA's CUDA repo with the sbsa (NOT aarch64) architecture token. The
# commands below are for operators who deliberately launch from a stock AL2023
# arm64 AMI instead of the arm64 DLAMI; this script never executes them.
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

# --- arch detection ----------------------------------------------------------
MACHINE="$(uname -m)"
if [[ "$MACHINE" == "aarch64" ]]; then
   ARCH="arm64"
else
   ARCH="amd64"
fi

printf "configuring NVIDIA GPU runtime (%s)...\n" "$ARCH"

# --- fail-loud guard: the DLAMI carries the driver, stock AL2023 does not -----
if ! command -v nvidia-smi >/dev/null 2>&1; then
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

# --- verify the driver actually initializes (T4G visible on g5g) --------------
printf "verifying NVIDIA driver...\n"
nvidia-smi

# --- Option C / CDI wiring ----------------------------------------------------
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
   # NOTE: no nvidia-ctk runtime configure (--set-as-default or otherwise) and
   # no nvidia-ctk cdi generate here - both are CRI-only / unused by the raw-API
   # assembly controller. The default runtime stays plain runc.
   sudo systemctl enable --now nvidia-persistenced
else
   # amd64: the controllers inject CDI themselves (the Go controller via
   # cdi.WithCDIDevices, the C controller via its JSON-only CDI scanner), so
   # generate a JSON spec into /var/run/cdi, the directory bind-mounted into
   # the controller container (strimserver.service). A copy is also kept in
   # /etc/cdi for host-side tooling. The default runtime is deliberately left
   # unchanged (behavior-preserving; no --set-as-default).
   printf "generating the CDI device spec for the controllers...\n"
   sudo mkdir -p /var/run/cdi /etc/cdi
   # Remove stale YAML (and any old JSON) from the dynamic dir first: the Go
   # CDI cache hard-fails when the same device appears in both nvidia.yaml and
   # nvidia.json in the same directory ("unresolvable CDI devices"). We ship
   # JSON only (canonical CDI format; both the C and Go controllers read it).
   sudo rm -f /var/run/cdi/nvidia.yaml /var/run/cdi/nvidia.yml /var/run/cdi/nvidia.json
   sudo nvidia-ctk cdi generate --format=json --output=/var/run/cdi/nvidia.json
   # Same hygiene for the /etc/cdi copy: a stale YAML beside the JSON we copy
   # would be a same-dir duplicate conflict for host-side Go CDI tooling.
   sudo rm -f /etc/cdi/nvidia.yaml /etc/cdi/nvidia.yml
   sudo cp /var/run/cdi/nvidia.json /etc/cdi/nvidia.json
   sudo systemctl enable --now nvidia-persistenced
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