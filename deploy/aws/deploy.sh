#!/usr/bin/env bash

set -euo pipefail
# Secrets are written below (SRT passphrase); make the default creation mode
# private and never rely on a later chmod alone.
umask 077

# Both milestones (M1/M2) are timed from this single origin: deploy.sh start.
DEPLOY_START_SECONDS=$SECONDS

# Payload root. The bundle lands in /mnt/nvme on the host; tests relocate it so
# the whole fast path can run without root or a real NVMe mount.
DEPLOY_ROOT="${DEPLOY_ROOT:-/mnt/nvme}"

# Non-blocking deploy lock. /run is root-owned and deploy.sh runs as ec2-user,
# so the file is created with sudo and then opened read-only (flock works on a
# read-only descriptor). DEPLOY_LOCK_FILE is a test relocation hook only.
LOCK_FILE="${DEPLOY_LOCK_FILE:-/run/strimserver-deploy.lock}"

# Pure deploy helpers live beside this script in the bundle (lib/deploy.sh) and
# in the repo (deploy/aws/lib/deploy.sh). Resolve relative to this file so both
# layouts work.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/deploy.sh
source "$script_dir/lib/deploy.sh"
# Read-only reuse of the driver-floor contract. The floor is baked into the
# AMI, so deploy.sh asserts it instead of running an upgrade.
# shellcheck source=lib/nvidia.sh
source "$script_dir/lib/nvidia.sh"

mkdir -p "$DEPLOY_ROOT/deploy-tmp"
export TMPDIR="$DEPLOY_ROOT/deploy-tmp"

# --- merged cleanup / interrupt trap -----------------------------------------
# State observed by the trap. The sequence below is pinned by the design:
#   1. ignore PIPE/HUP/INT/TERM so a signal during the handler cannot re-enter
#   2. stop an in-flight DDNS unit (bounded)
#   3. kill the journal follower, kill+wait tracked imports, release the flock
#   4. write the final rc to deploy-last.rc
#   5. close stdout/stderr (ends the tee's input)
#   6. wait for the tee process substitution
#   7. exit with the computed code (128+n for a signal)
tee_pid=""
follower_pid=""
import_pids=()
lock_held=0
ddns_inflight_unit=""
last_rc_file=""

deploy_finish() {
   local rc=$?
   trap '' PIPE HUP INT TERM

   if [ -n "$ddns_inflight_unit" ]; then
      sudo timeout -k 5 150 systemctl stop "$ddns_inflight_unit" || true
      ddns_inflight_unit=""
   fi

   if [ -n "$follower_pid" ]; then
      kill "$follower_pid" 2>/dev/null || true
      wait "$follower_pid" 2>/dev/null || true
      follower_pid=""
   fi
   if [ "${#import_pids[@]}" -gt 0 ]; then
      local import_pid
      for import_pid in "${import_pids[@]}"; do
         kill "$import_pid" 2>/dev/null || true
      done
      for import_pid in "${import_pids[@]}"; do
         wait "$import_pid" 2>/dev/null || true
      done
      import_pids=()
   fi
   if [ "$lock_held" = "1" ]; then
      flock -u 9 2>/dev/null || true
      exec 9<&-
      lock_held=0
   fi

   if [ -n "$last_rc_file" ]; then
      printf '%s\n' "$rc" >"$last_rc_file" 2>/dev/null || true
   fi

   exec 1>&- 2>&-

   if [ -n "$tee_pid" ]; then
      wait "$tee_pid" 2>/dev/null || true
   fi

   rm -rf "$TMPDIR" 2>/dev/null || true
   exit "$rc"
}
trap deploy_finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Parse, don't validate: only a strict dotted-quad IPv4 reaches PUBLIC_IP.
is_dotted_quad() {
   local ip="$1" octet
   local -a octets
   [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
   IFS=. read -r -a octets <<<"$ip"
   for octet in "${octets[@]}"; do
      ((octet >= 0 && octet <= 255)) || return 1
   done
}

# --- preamble step 1: acquire the non-blocking deploy lock -------------------
# Create the lock file root-owned and world-readable. On a rerun an earlier
# deploy may have left it 0600; chmod fixes the mode while preserving the inode,
# so flock mutual exclusion survives repeated deploys.
if [ -e "$LOCK_FILE" ]; then
   sudo chmod 0644 "$LOCK_FILE"
else
   sudo install -m 0644 -o root -g root /dev/null "$LOCK_FILE"
fi
exec 9<"$LOCK_FILE"
if ! flock -n 9; then
   printf 'another deploy is running\n'
   exit 5
fi
lock_held=1

# --- preamble step 1b: refuse while a SIGKILLed deploy's import is alive ------
# sudo closes fds >= 3, so an orphaned `ctr i import` does NOT inherit the lock
# descriptor. Detect it explicitly (bounded) so a rerun cannot race a
# half-finished import on the same containerd state.
# The `i[ ]import` character class is required: pgrep -f scans the argv of the
# `timeout` wrapper too, and that argv contains this pattern text (the shell
# strips the quotes). A literal ' i import' would therefore match the wrapper
# itself and fire on every run; `[ ]` still matches a real `ctr ... i import`.
if timeout -k 5 5 pgrep -f 'ctr .* i[ ]import' >/dev/null 2>&1; then
   printf 'another deploy is running\n'
   exit 5
fi

# --- preamble step 2: /mnt/nvme must be a mountpoint -------------------------
# stdout only: the deploy log is not open yet and lives on this volume.
if ! mountpoint -q /mnt/nvme; then
   printf 'ERROR: /mnt/nvme is not a mounted filesystem; refusing to deploy.\n'
   printf 'Run setup_strimserver to mount the NVMe volume, then rerun the deploy.\n'
   exit 1
fi

# --- preamble step 3: open the deploy log and tee ----------------------------
LOG_DIRECTORY="$DEPLOY_ROOT/logs"
DEPLOY_LOG="$LOG_DIRECTORY/deploy-$(date -u +%Y%m%dT%H%M%SZ).log"
DEPLOY_LAST_RC="$LOG_DIRECTORY/deploy-last.rc"
sudo install -d -m 0755 -o root -g root "$LOG_DIRECTORY"
sudo install -o ec2-user -g ec2-user -m 0640 /dev/null "$DEPLOY_LOG"
sudo install -o ec2-user -g ec2-user -m 0640 /dev/null "$DEPLOY_LAST_RC"
last_rc_file="$DEPLOY_LAST_RC"
# tee is a read-only observer of the deploy: it closes the lock descriptor
# (9<&-), ignores SIGHUP so a lost pty does not truncate the log, and warns
# instead of dying on a write error. $! is the bash process-substitution pid.
exec > >(trap '' HUP; exec 9<&-; exec tee -a --output-error=warn "$DEPLOY_LOG")
tee_pid=$!
printf 'deploy log: %s\n' "$DEPLOY_LOG"

# Retain the newest 10 deploy logs; prune older ones (pruning needs sudo).
old_logs=()
while IFS= read -r stale_log; do
   old_logs+=("$stale_log")
done < <(ls -1t "$LOG_DIRECTORY"/deploy-*.log 2>/dev/null | tail -n +11 || true)
if [ "${#old_logs[@]}" -gt 0 ]; then
   sudo rm -f -- "${old_logs[@]}"
fi

# --- install the bundled config + tools (idempotent on re-run) ---------------
# Only install the bundled env when no config is already present: a re-run (or
# a cutover) must never overwrite an operator-injected config.
mkdir -p "$DEPLOY_ROOT/config"
mkdir -p "$DEPLOY_ROOT/bin"
if [ ! -f "$DEPLOY_ROOT/config/strimserver.env" ] && [ -f "$DEPLOY_ROOT/strimserver.env" ]; then
   mv "$DEPLOY_ROOT/strimserver.env" "$DEPLOY_ROOT/config/strimserver.env"
fi
if [ -f "$DEPLOY_ROOT/mediamtx.yaml.template" ] && [ ! -f "$DEPLOY_ROOT/config/mediamtx.yaml.template" ]; then
   mv "$DEPLOY_ROOT/mediamtx.yaml.template" "$DEPLOY_ROOT/config/mediamtx.yaml.template"
fi
if [ -f "$DEPLOY_ROOT/transcode.sh" ]; then
   mv "$DEPLOY_ROOT/transcode.sh" "$DEPLOY_ROOT/bin/transcode.sh"
fi
if [ -f "$DEPLOY_ROOT/notify" ]; then
   mv "$DEPLOY_ROOT/notify" "$DEPLOY_ROOT/bin/notify"
fi
[ -f "$DEPLOY_ROOT/bin/transcode.sh" ] && chmod +x "$DEPLOY_ROOT/bin/transcode.sh"
[ -f "$DEPLOY_ROOT/bin/notify" ] && chmod +x "$DEPLOY_ROOT/bin/notify"

# --- inject Dynamic DNS settings (ENABLE_DDNS / DDNS_HOST / DDNS_DOMAIN) ------
# The operator's Dynamic DNS settings (root .env) are transferred as a 0600 file
# by setup_strimserver, mirroring the Twitch stream key. The lib helper merges
# them into the on-box strimserver.env atomically BEFORE the refresh timer is
# enabled, so every timer-triggered start sees the right operator values. It is
# fatal when strimserver.env is missing: this must never create a truncated env
# containing only the DDNS keys.
ENV_FILE="$DEPLOY_ROOT/config/strimserver.env"
DDNS_CONFIG_FILE="$DEPLOY_ROOT/ddns-config"
if [ -s "$DDNS_CONFIG_FILE" ]; then
   printf "injecting Dynamic DNS settings...\n"
   deploy_write_ddns_env_settings "$ENV_FILE" "$DDNS_CONFIG_FILE" || exit 1
   chmod 600 "$ENV_FILE"
   # scrub the transfer file
   if command -v shred >/dev/null 2>&1; then shred -u "$DDNS_CONFIG_FILE"; else rm -f "$DDNS_CONFIG_FILE"; fi
   printf "Dynamic DNS settings injected into %s\n" "$ENV_FILE"
else
   printf "\nNote: no Dynamic DNS settings transferred; using the bundled values in %s.\n" "$ENV_FILE"
fi

if [ ! -f "$ENV_FILE" ]; then
   printf '\n*** ERROR: %s is missing from the deploy bundle. ***\n' "$ENV_FILE"
   exit 1
fi

# --- preamble step 4: validate DDNS configuration before any deploy work -----
source "$ENV_FILE"
ENABLE_DDNS="${ENABLE_DDNS:-false}"
DDNS_HOST="${DDNS_HOST:-strim}"
DDNS_DOMAIN="${DDNS_DOMAIN:-}"
if [ "$ENABLE_DDNS" = "true" ]; then
   ddns_missing=""
   [ -n "$DDNS_HOST" ] || ddns_missing="DDNS_HOST"
   [ -n "$DDNS_DOMAIN" ] || ddns_missing="${ddns_missing:+$ddns_missing, }DDNS_DOMAIN"
   if [ ! -s "$DEPLOY_ROOT/ddns-password" ]; then
      ddns_missing="${ddns_missing:+$ddns_missing, }DDNS password file"
   fi
   if [ -n "$ddns_missing" ]; then
      printf '\n*** ERROR: ENABLE_DDNS=true but required Dynamic DNS configuration is missing: %s. ***\n' "$ddns_missing"
      printf 'Set it in %s (and transfer the DDNS password) before retrying.\n' "$ENV_FILE"
      exit 1
   fi
fi

# --- inject Twitch stream key ------
KEY_FILE="$DEPLOY_ROOT/twitch-stream-key"
if [ -s "$KEY_FILE" ]; then
   printf "injecting twitch stream key...\n"
   TWITCH_STREAM_KEY="$(tr -d '\r\n' < "$KEY_FILE")"
   tmp="$(mktemp)"
   # drop any existing assignment, then append the injected one
   grep -v '^[[:space:]]*TWITCH_STREAM_KEY=' "$ENV_FILE" > "$tmp" || true
   printf 'TWITCH_STREAM_KEY="%s"\n' "$TWITCH_STREAM_KEY" >> "$tmp"
   mv "$tmp" "$ENV_FILE"
   chmod 600 "$ENV_FILE"
   # scrub the transfer file
   if command -v shred >/dev/null 2>&1; then shred -u "$KEY_FILE"; else rm -f "$KEY_FILE"; fi
   printf "twitch stream key injected into %s\n" "$ENV_FILE"
else
   printf "\n*** WARNING: no Twitch stream key provided. ***\n"
   printf "Ingest, normalize, and the offline fallback will work, but egress to\n"
   printf "Twitch will fail when toggled until TWITCH_STREAM_KEY is set in\n"
   printf "%s.\n\n" "$ENV_FILE"
fi
# Enforce the env-file mode unconditionally, including the key-absent path.
chmod 600 "$ENV_FILE"

# Which controller image is inside controller-container.tar. Every release
# ships FOUR bundles (Go + C controllers x amd64 + arm64); the bundle the
# operator selected is recorded here (set CONTROLLER_VARIANT when deploying a
# C bundle: c-amd64 / c-arm64). Purely informational -- the import step below
# is variant-agnostic (the image tar keeps the same name in every bundle).
: "${S3_BUCKET:=<S3_BUCKET>}"
: "${TARGET_HOSTNAME:=strimserver}"
: "${CONTROLLER_VARIANT:=go-amd64}"
printf "controller variant: %s\n" "$CONTROLLER_VARIANT"

# --- preamble step 5: resolve and validate PUBLIC_IP from IMDS ---------------
source "$DEPLOY_ROOT/imdslib.sh"
PUBLIC_IP="$(get_public_ip 2>/dev/null || true)"
INSTANCE_TYPE="$(get_instance_type 2>/dev/null || echo "unknown")"
rm -f "$DEPLOY_ROOT/imdslib.sh"
if ! is_dotted_quad "$PUBLIC_IP"; then
   printf '\ncannot determine public IPv4 from IMDS (no public IP associated?)\n'
   exit 1
fi
export PUBLIC_IP INSTANCE_TYPE

# --- preamble step 6: ensure containerd is running ---------------------------
# A unit start skipped by a condition still returns 0, so re-check is-active.
if ! systemctl is-active --quiet containerd; then
   printf "containerd is inactive; starting it...\n"
   containerd_start_rc=0
   sudo timeout -k 5 30 systemctl start containerd || containerd_start_rc=$?
   if [ "$containerd_start_rc" -ne 0 ]; then
      printf '\n*** ERROR: failed to start containerd (rc %s). ***\n' "$containerd_start_rc"
      exit 1
   fi
   if ! systemctl is-active --quiet containerd; then
      printf '\n*** ERROR: containerd is still inactive after start. ***\n'
      exit 1
   fi
   printf "containerd started.\n"
fi

# --- preamble step 7: deploy work --------------------------------------------

# --- NVIDIA GPU runtime: assert the baked driver floor ------------------------
# The AMI bakes the driver, container toolkit and persistenced wiring, so the
# deploy never upgrades the driver. The gate requires the LOADED core module to
# be at the floor AND the on-disk nvidia AND nvidia-uvm modules for the running
# kernel to report that exact loaded version AND nvidia_uvm to be loaded. A
# loaded 620 core over a stale 595 nvidia-uvm.ko (the DLAMI boot-time tarball
# restore) satisfies a proc-only check but dies at cuInit with
# CUDA_ERROR_UNKNOWN, so proc-only is not enough.
if ! nvidia__loaded_graph_consistent "${SUDO:-sudo}"; then
   loaded_version="$(nvidia__proc_version 2>/dev/null || true)"
   kernel_release="$(uname -r)"
   on_disk_nvidia="$(nvidia__on_disk_kernel_version "${SUDO:-sudo}" nvidia 2>/dev/null || true)"
   on_disk_uvm="$(nvidia__on_disk_kernel_version "${SUDO:-sudo}" nvidia-uvm 2>/dev/null || true)"
   if nvidia__module_loaded "${SUDO:-sudo}" nvidia_uvm; then
      uvm_state="loaded"
   else
      uvm_state="not loaded"
   fi
   printf "\n*** ERROR: the NVIDIA driver is not consistent at the required %s floor. ***\n" "$NVIDIA_DRIVER_FLOOR"
   printf "loaded=%s on-disk nvidia=%s nvidia-uvm=%s (kernel %s); nvidia_uvm is %s.\n" \
      "${loaded_version:-<unreadable>}" "${on_disk_nvidia:-<missing>}" \
      "${on_disk_uvm:-<missing>}" "$kernel_release" "$uvm_state"
   printf "This fast path expects a baked AMI that already ships the GPU driver and\n"
   printf "container toolkit. Launch a current baked AMI (the image published at the\n"
   printf "SSM parameter /strimserver/ami/baked/latest in us-east-2) instead of an\n"
   printf "older image, or run setup-gpu.sh once on a legacy host to raise the driver.\n\n"
   exit 1
fi
printf "NVIDIA driver floor satisfied (%s)\n" "$NVIDIA_DRIVER_FLOOR"

MACHINE="$(uname -m)"
if [[ "$MACHINE" == "aarch64" ]]; then
   ARCH="arm64"
else
   ARCH="amd64"
fi

if [[ "$ARCH" == "amd64" ]]; then
   # The Go controller (cdi.WithCDIDevices) and the C controller (JSON-only CDI
   # scanner) read JSON specs from the bind-mounted /var/run/cdi. Generate that
   # spec here (the driver is already baked); keep the /etc/cdi copy for
   # host-side tooling. JSON only -- a stale YAML beside the JSON is a
   # same-directory duplicate conflict for the Go CDI cache.
   printf "generating the CDI device spec...\n"
   sudo mkdir -p /var/run/cdi /etc/cdi
   sudo rm -f /var/run/cdi/nvidia.yaml /var/run/cdi/nvidia.yml /var/run/cdi/nvidia.json
   sudo nvidia-ctk cdi generate --format=json --output=/var/run/cdi/nvidia.json
   sudo rm -f /etc/cdi/nvidia.yaml /etc/cdi/nvidia.yml
   sudo cp /var/run/cdi/nvidia.json /etc/cdi/nvidia.json
fi
# Persistenced is part of the baked GPU wiring; enabling it is idempotent and
# keeps the driver initialized between container starts.
sudo systemctl enable --now nvidia-persistenced

# containerd
# A baked AMI already ships the canonical root/state config. Compare first and
# restart containerd ONLY when the content changes, so the fast path does no
# needless service bounce.
printf "configuring containerd...\n"
containerd_config_tmp="$(mktemp)"
containerd_config_state="$(deploy_apply_containerd_config \
   /etc/containerd/config.toml "$containerd_config_tmp" sudo)"
rm -f "$containerd_config_tmp"
printf "containerd config %s\n" "$containerd_config_state"

# The NVMe drop-in is the condition that keeps a rebooted (unmounted) host from
# starting containerd against a missing volume. Compare-before-apply, then a
# daemon-reload only when it changed.
containerd_dropin=/etc/systemd/system/containerd.service.d/10-strimserver-nvme.conf
if ! sudo test -f "$containerd_dropin" \
      || ! sudo cmp -s "$DEPLOY_ROOT/containerd-nvme.conf" "$containerd_dropin"; then
   sudo install -D -m 644 "$DEPLOY_ROOT/containerd-nvme.conf" "$containerd_dropin"
   sudo systemctl daemon-reload
fi
printf "containerd configured!\n"

# import images
# Launch the imports as background jobs and join them with a single wait
# barrier, so the (independent) image tars stream concurrently instead of
# serially. The strim-ddns image joins the barrier when DDNS is enabled, so the
# post-M1 DDNS block performs no imports. A failure is collected per job and
# reported at the barrier with the failing image named; nothing downstream runs
# on a partial import.
printf "importing images (%s)...\n" "$CONTROLLER_VARIANT"
CONTAINERD_NAMESPACE="strimserver"
import_names=(controller ffmpeg mediamtx)
if [ "$ENABLE_DDNS" = "true" ]; then
   import_names+=(strim-ddns)
fi
import_pids=()
for import_name in "${import_names[@]}"; do
   sudo ctr -n "$CONTAINERD_NAMESPACE" i import "${import_name}-container.tar" &
   import_pids+=("$!")
done
import_failures=()
for import_index in "${!import_names[@]}"; do
   if ! wait "${import_pids[$import_index]}"; then
      import_failures+=("${import_names[$import_index]}")
   fi
done
import_pids=()
if [ "${#import_failures[@]}" -ne 0 ]; then
   printf "\n*** ERROR: failed to import image(s): %s ***\n" "${import_failures[*]}" >&2
   exit 1
fi
for import_name in "${import_names[@]}"; do
   rm -f "${import_name}-container.tar"
done
printf "images imported!\n"

# systemd service file (ships inside the bundle as strimserver.service).
printf "installing systemd service file...\n"
sudo install -D -m 644 "$DEPLOY_ROOT/strimserver.service" /etc/systemd/system/strimserver.service
rm -f "$DEPLOY_ROOT/strimserver.service"
sudo systemctl daemon-reload
sudo systemctl enable strimserver.service
printf "systemd service file installed and enabled!\n"

# Generate an SRT passphrase once (0600 root:root), never printing its value.
SRT_PASSPHRASE_FILE="$DEPLOY_ROOT/srt-passphrase"
printf "preparing SRT passphrase...\n"
deploy_write_srt_passphrase "$SRT_PASSPHRASE_FILE" sudo
SRT_READ_PASSPHRASE="$(sudo cat "$SRT_PASSPHRASE_FILE")"
export SRT_READ_PASSPHRASE
printf "srt passphrase file: %s (0600)\n" "$SRT_PASSPHRASE_FILE"

source "$DEPLOY_ROOT/fish-deploy.sh"
rm -f "$DEPLOY_ROOT/fish-deploy.sh"

# htop and the experimental OpenSSH RPM are baked into the AMI by Image
# Builder; the runtime path installs neither (no dnf on the fast path).
printf "host tools are baked into the AMI; skipping runtime package installs\n"

printf "setting hostname...\n"
sudo hostnamectl set-hostname "$TARGET_HOSTNAME"
printf "hostname set to %s\n" "$(hostname)"

printf "creating video-files directory...\n"
VIDEO_FILES_DIRECTORY="$DEPLOY_ROOT/video-files"
mkdir -p "$VIDEO_FILES_DIRECTORY"
printf "video-files directory created: %s\n" "$VIDEO_FILES_DIRECTORY"

printf "configuring offline segment...\n"
OFFLINE_SEGMENT_FILE_NAME=strimserver-offline-2160p60.mp4
# Re-runnable: the bundled clip is only moved when it is still present.
if [ -f "$OFFLINE_SEGMENT_FILE_NAME" ]; then
   mv "$OFFLINE_SEGMENT_FILE_NAME" "$VIDEO_FILES_DIRECTORY"
else
   printf "offline segment already installed; skipping the move\n"
fi
printf "offline segment configured: %s\n" "$OFFLINE_SEGMENT_FILE_NAME"

# Logs are created by the containerd shim, not by entrypoint.sh, so a process
# umask cannot set their modes on a fresh host. Pre-create the directory 0755
# (traversable by the deploy user, not writable) and the three logs 0640
# root:root, then normalize any file created later.
printf "preparing logs directory...\n"
LOGS_DIRECTORY="$DEPLOY_ROOT/logs"
deploy_prepare_logs_directory "$LOGS_DIRECTORY" sudo
printf "logs directory ready: %s\n" "$LOGS_DIRECTORY"

# --- pre-M1 DDNS setup --------------------------------------------------------
# Everything the DDNS stages need is installed/rendered/enabled BEFORE M1: the
# post-M1 DDNS block is only the two bounded starts. The operator env settings
# were written above, before the timer is enabled.
DDNS_FQDN=""
if [ "$ENABLE_DDNS" = "true" ]; then
   DDNS_FQDN="$DDNS_HOST.$DDNS_DOMAIN"
   printf "configuring %s dynamic DNS...\n" "$DDNS_FQDN"

   # 1) install the DDNS password (root:root 0600) and scrub the transfer file
   DDNS_PASSWORD_SRC="$DEPLOY_ROOT/ddns-password"
   DDNS_PASSWORD_DST=/etc/strim-ddns/password
   printf "installing DDNS password...\n"
   sudo install -D -m 600 -o root -g root "$DDNS_PASSWORD_SRC" "$DDNS_PASSWORD_DST"
   if command -v shred >/dev/null 2>&1; then shred -u "$DDNS_PASSWORD_SRC"; else rm -f "$DDNS_PASSWORD_SRC"; fi

   # 2) install the refresh unit + timer and the rendered verify unit
   printf "installing strim-ddns units...\n"
   sudo install -D -m 644 "$DEPLOY_ROOT/strim-ddns.service" /etc/systemd/system/strim-ddns.service
   sudo install -D -m 644 "$DEPLOY_ROOT/strim-ddns.timer" /etc/systemd/system/strim-ddns.timer
   rm -f "$DEPLOY_ROOT/strim-ddns.service" "$DEPLOY_ROOT/strim-ddns.timer"

   DDNS_VERIFY_TEMPLATE="$script_dir/strim-ddns-verify.service.template"
   DDNS_VERIFY_UNIT="$DEPLOY_ROOT/strim-ddns-verify.service"
   if [ ! -f "$DDNS_VERIFY_TEMPLATE" ]; then
      printf '\n*** ERROR: %s is missing from the deploy bundle. ***\n' "$DDNS_VERIFY_TEMPLATE"
      printf 'The strim-ddns-verify unit template must ship alongside deploy.sh.\n\n'
      exit 1
   fi
   sed "s|__EXPECTED_IP__|$PUBLIC_IP|g" "$DDNS_VERIFY_TEMPLATE" > "$DDNS_VERIFY_UNIT"
   sudo install -D -m 644 "$DDNS_VERIFY_UNIT" /etc/systemd/system/strim-ddns-verify.service
   rm -f "$DDNS_VERIFY_UNIT"
   sudo systemctl daemon-reload

   # 3) migrate hosts that enabled the old async verify unit: verify is
   #    deploy-invoked only, never enabled.
   sudo timeout -k 5 10 systemctl disable strim-ddns-verify.service || true

   # 4) arm the 6-hour refresh timer. The env file already holds the operator's
   #    DDNS settings, so a Persistent=true trigger sees the right values.
   sudo systemctl enable --now strim-ddns.timer
   printf "strim-ddns units installed and timer enabled!\n"
else
   # DDNS was disabled: remove enablement and any running units on a host that
   # previously enabled it. Bounded, idempotent, tolerant; the unit files stay on
   # disk so re-enabling needs no reinstall.
   printf "DDNS is disabled; removing any previous DDNS enablement...\n"
   sudo timeout -k 5 10 systemctl disable --now strim-ddns.timer \
      || printf "note: strim-ddns.timer was not enabled\n"
   sudo timeout -k 5 10 systemctl disable strim-ddns-verify.service \
      || printf "note: strim-ddns-verify.service was not enabled\n"
   sudo timeout -k 5 10 systemctl stop strim-ddns.service strim-ddns-verify.service \
      || printf "note: no running strim-ddns units to stop\n"
fi

# --- M1: service ready ------------------------------------------------------
# Everything except the two bounded DDNS starts and the success-only cleanup is
# done. The 60s target is warn-only; an overrun never changes the exit code.
M1_ELAPSED=$((SECONDS - DEPLOY_START_SECONDS))
if [ -n "${DEPLOY_M1_ELAPSED_OVERRIDE:-}" ]; then
   M1_ELAPSED="$DEPLOY_M1_ELAPSED_OVERRIDE"
fi
if [ "$M1_ELAPSED" -gt 60 ]; then
   printf 'M1: service ready (%ss, over 60s target)\n' "$M1_ELAPSED"
else
   printf 'M1: service ready (%ss)\n' "$M1_ELAPSED"
fi

# --- M2: blocking DDNS stages ------------------------------------------------
# This block contains ONLY the two bounded unit starts (plus their follower).
# No install, render, reload, enable, or disable runs here.
if [ "$ENABLE_DDNS" = "true" ]; then
   printf "refreshing %s -> %s...\n" "$DDNS_FQDN" "$PUBLIC_IP"
   ddns_rc=0
   ddns_inflight_unit="strim-ddns.service"
   sudo timeout -k 5 40 systemctl start strim-ddns.service || ddns_rc=$?
   if [ "$ddns_rc" -ne 0 ]; then
      if [ "$ddns_rc" -eq 124 ] || [ "$ddns_rc" -eq 137 ]; then
         printf '\n*** ERROR: DDNS refresh (strim-ddns.service) hit the backstop timeout (rc %s). ***\n' "$ddns_rc"
         if ! sudo timeout -k 5 150 systemctl stop strim-ddns.service; then
            printf '*** WARNING: unit may still be running; inspect systemctl status strim-ddns.service ***\n' >&2
         fi
         ddns_inflight_unit=""
         exit 4
      fi
      printf '\n*** ERROR: DDNS refresh failed (strim-ddns.service, rc %s). ***\n' "$ddns_rc"
      ddns_inflight_unit=""
      exit 3
   fi
   ddns_inflight_unit=""

   printf "verifying %s (blocking)...\n" "$DDNS_FQDN"
   cursor="$(sudo journalctl --show-cursor -n 0 | awk '/^-- cursor:/ {print $3}')"
   sudo journalctl --after-cursor "$cursor" -f -u strim-ddns-verify.service 9<&- &
   follower_pid=$!
   ddns_rc=0
   ddns_inflight_unit="strim-ddns-verify.service"
   sudo timeout -k 5 150 systemctl start strim-ddns-verify.service || ddns_rc=$?
   if [ "$ddns_rc" -ne 0 ]; then
      ddns_inflight_unit=""
      kill "$follower_pid" 2>/dev/null || true
      wait "$follower_pid" 2>/dev/null || true
      follower_pid=""
      if [ "$ddns_rc" -eq 124 ] || [ "$ddns_rc" -eq 137 ]; then
         printf '\n*** ERROR: DDNS verify (strim-ddns-verify.service) hit the backstop timeout (rc %s). ***\n' "$ddns_rc"
         if ! sudo timeout -k 5 150 systemctl stop strim-ddns-verify.service; then
            printf '*** WARNING: unit may still be running; inspect systemctl status strim-ddns-verify.service ***\n' >&2
         fi
         exit 4
      fi
      invocation_id="$(systemctl show -p InvocationID --value strim-ddns-verify.service 2>/dev/null || true)"
      printf '\n*** ERROR: DDNS verification failed (strim-ddns-verify.service, rc %s). ***\n' "$ddns_rc"
      if [ -n "$invocation_id" ]; then
         sudo journalctl _SYSTEMD_INVOCATION_ID="$invocation_id" -n 20 || true
      fi
      printf 'Inspect: sudo journalctl -u strim-ddns-verify\n'
      printf 'Fix the DDNS configuration, then rerun the deploy.\n'
      exit 3
   fi
   ddns_inflight_unit=""
   kill "$follower_pid" 2>/dev/null || true
   wait "$follower_pid" 2>/dev/null || true
   follower_pid=""
   printf "DDNS verified: %s -> %s\n" "$DDNS_FQDN" "$PUBLIC_IP"
   printf 'ssh %s "sudo systemctl start strimserver.service"\n' "$DDNS_FQDN"
else
   printf "DDNS disabled; the box is reachable by public IP only.\n"
   printf 'ssh %s "sudo systemctl start strimserver.service"\n' "$PUBLIC_IP"
fi
printf 'SRT passphrase: read it on the host from %s (0600)\n' "$SRT_PASSPHRASE_FILE"

# --- success-only cleanup ----------------------------------------------------
# Reached only after every deploy step above succeeded, so a failed run keeps
# its payload for a retry. Best-effort (cannot fail the deploy) but loud.
printf "cleaning up deployment payloads...\n"
for leftover in "$DEPLOY_ROOT/lib/nvidia.sh" "$DEPLOY_ROOT/lib/deploy.sh" "$DEPLOY_ROOT/deploy.sh"; do
   rm -f "$leftover" 2>/dev/null || printf '*** WARNING: could not remove %s ***\n' "$leftover" >&2
done
if [ -d "$DEPLOY_ROOT/lib" ] && ! rmdir "$DEPLOY_ROOT/lib" 2>/dev/null; then
   printf '*** WARNING: could not remove directory %s ***\n' "$DEPLOY_ROOT/lib" >&2
fi

# M2 is literally the last output line, followed only by exit 0.
if [ "$ENABLE_DDNS" = "true" ]; then
   printf 'M2: DDNS verified, deploy complete (%ss)\n' "$((SECONDS - DEPLOY_START_SECONDS))"
else
   printf 'M2: deploy complete (DDNS disabled)\n'
fi
exit 0
