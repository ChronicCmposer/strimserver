#!/usr/bin/env bash

set -euo pipefail
# Secrets are written below (SRT passphrase); make the default creation mode
# private and never rely on a later chmod alone.
umask 077

# Payload root. The bundle lands in /mnt/nvme on the host; tests relocate it so
# the whole fast path can run without root or a real NVMe mount.
DEPLOY_ROOT="${DEPLOY_ROOT:-/mnt/nvme}"

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


cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT INT TERM


# Env variables
: "${S3_BUCKET:=<S3_BUCKET>}"
: "${TARGET_HOSTNAME:=strimserver}"

# Which controller image is inside controller-container.tar. Every release
# ships FOUR bundles (Go + C controllers x amd64 + arm64); the bundle the
# operator selected is recorded here (set CONTROLLER_VARIANT when deploying a
# C bundle: c-amd64 / c-arm64). Purely informational -- the import step below
# is variant-agnostic (the image tar keeps the same name in every bundle).
: "${CONTROLLER_VARIANT:=go-amd64}"
printf "controller variant: %s\n" "$CONTROLLER_VARIANT"

# metadata / diagnostics
source "$DEPLOY_ROOT/imdslib.sh"
export PUBLIC_IP=$(get_public_ip)
export INSTANCE_TYPE=$(get_instance_type)

rm -f "$DEPLOY_ROOT/imdslib.sh"

# config/bin directories
mkdir -p "$DEPLOY_ROOT/config"
mkdir -p "$DEPLOY_ROOT/bin"

# --- install the bundled config + tools (idempotent on re-run) ---------------
# Only install the bundled env when no config is already present: a re-run (or
# a cutover) must never overwrite an operator-injected config.
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

chmod +x "$DEPLOY_ROOT/bin/transcode.sh"
chmod +x "$DEPLOY_ROOT/bin/notify"

# --- inject Dynamic DNS settings (ENABLE_DDNS / DDNS_HOST / DDNS_DOMAIN) ------
# The operator's Dynamic DNS settings (root .env) are transferred as a 0600 file
# by setup_strimserver, mirroring the Twitch stream key. Merge them into the
# on-box strimserver.env BEFORE sourcing it below, so both deploy.sh's DDNS block
# and the strim-ddns unit's EnvironmentFile see the operator values. With no
# file, the bundled defaults (DDNS disabled) stay in effect.
ENV_FILE="$DEPLOY_ROOT/config/strimserver.env"
DDNS_CONFIG_FILE="$DEPLOY_ROOT/ddns-config"
if [ -s "$DDNS_CONFIG_FILE" ]; then
   printf "injecting Dynamic DNS settings...\n"
   for ddns_key in ENABLE_DDNS DDNS_HOST DDNS_DOMAIN; do
      ddns_assignment="$(grep -m1 "^${ddns_key}=" "$DDNS_CONFIG_FILE" || true)"
      if [ -n "$ddns_assignment" ]; then
         tmp="$(mktemp)"
         # drop any existing assignment, then append the injected one
         grep -v "^[[:space:]]*${ddns_key}=" "$ENV_FILE" > "$tmp" || true
         printf '%s\n' "$ddns_assignment" >> "$tmp"
         mv "$tmp" "$ENV_FILE"
      fi
   done
   chmod 600 "$ENV_FILE"
   # scrub the transfer file
   if command -v shred >/dev/null 2>&1; then shred -u "$DDNS_CONFIG_FILE"; else rm -f "$DDNS_CONFIG_FILE"; fi
   printf "Dynamic DNS settings injected into %s\n" "$ENV_FILE"
else
   printf "\nNote: no Dynamic DNS settings transferred; using the bundled values in %s.\n" "$ENV_FILE"
fi
# ------------------------------------------------------------------------------

# --- Dynamic DNS config (from the on-box strimserver.env) ---------------------
# The operator controls Dynamic DNS via ENABLE_DDNS (toggle), DDNS_HOST (default
# "strim"), and DDNS_DOMAIN (the domain the record is registered under). Source
# the config env file here so the DDNS block below reads the exact values the
# strim-ddns unit will read at runtime via its EnvironmentFile.
source "$ENV_FILE"
ENABLE_DDNS="${ENABLE_DDNS:-false}"
DDNS_HOST="${DDNS_HOST:-strim}"
DDNS_DOMAIN="${DDNS_DOMAIN:-}"

# --- inject Twitch stream key ------
ENV_FILE="$DEPLOY_ROOT/config/strimserver.env"
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
# ------------------------------------------------------------------------------

# --- NVIDIA GPU runtime: assert the baked driver floor ------------------------
# The AMI bakes the driver, container toolkit and persistenced wiring, so the
# deploy never upgrades the driver. It only asserts the LOADED module is at the
# floor (a strict /proc read; an unloaded or below-floor driver is fatal) and
# generates the amd64 CDI spec the controllers read from /var/run/cdi.
if ! nvidia__proc_at_floor; then
   printf "\n*** ERROR: the loaded NVIDIA driver is below the required %s floor. ***\n" "$NVIDIA_DRIVER_FLOOR"
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
# needless service bounce. The helper reads the existing config via `sudo cat`
# (failing closed when unreadable) and prints changed|unchanged.
printf "configuring containerd...\n"
containerd_config_tmp="$(mktemp)"
containerd_config_state="$(deploy_apply_containerd_config \
   /etc/containerd/config.toml "$containerd_config_tmp" sudo)"
rm -f "$containerd_config_tmp"
printf "containerd config %s\n" "$containerd_config_state"
printf "containerd configured!\n"

# import images
# Launch the three imports as background jobs and join them with a single wait
# barrier, so the (independent) image tars stream concurrently instead of
# serially. A failure is collected per job and reported at the barrier with the
# failing image named; nothing downstream runs on a partial import.
printf "importing images (%s)...\n" "$CONTROLLER_VARIANT"
CONTAINERD_NAMESPACE="strimserver"
import_names=(controller ffmpeg mediamtx)
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
if [ "${#import_failures[@]}" -ne 0 ]; then
   printf "\n*** ERROR: failed to import image(s): %s ***\n" "${import_failures[*]}" >&2
   exit 1
fi
rm -f controller-container.tar ffmpeg-container.tar mediamtx-container.tar
printf "images imported!\n"

# systemd service file (ships inside the bundle as strimserver.service).
# Enabled but not started: the first start stays an explicit operator action
# (deploy/aws/start_strimserver).
printf "installing systemd service file...\n"

sudo install -D -m 644 "$DEPLOY_ROOT/strimserver.service" /etc/systemd/system/strimserver.service

rm -f "$DEPLOY_ROOT/strimserver.service"

sudo systemctl daemon-reload
sudo systemctl enable strimserver.service
printf "systemd service file installed and enabled!\n"

# Generate an SRT passphrase once (0600 root:root), never printing its value.
# On a re-run the helper keeps the existing passphrase so the operator's
# already-configured encoder keeps working.
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
sudo hostnamectl set-hostname $TARGET_HOSTNAME
printf "hostname set to %s\n" $(hostname)

printf "creating video-files directory...\n"
VIDEO_FILES_DIRECTORY="$DEPLOY_ROOT/video-files"
mkdir -p $VIDEO_FILES_DIRECTORY
printf "video-files directory created: %s\n" "$VIDEO_FILES_DIRECTORY"

printf "configuring offline segment...\n"
OFFLINE_SEGMENT_FILE_NAME=strimserver-offline-2160p60.mp4
# Re-runnable: the bundled clip is only moved when it is still present (a
# re-run, or a volume that already holds it, must not fail here).
if [ -f "$OFFLINE_SEGMENT_FILE_NAME" ]; then
   mv "$OFFLINE_SEGMENT_FILE_NAME" "$VIDEO_FILES_DIRECTORY"
else
   printf "offline segment already installed; skipping the move\n"
fi
printf "offline segment configured: %s\n" "$OFFLINE_SEGMENT_FILE_NAME"

# Logs are created by the containerd shim, not by entrypoint.sh, so a process
# umask cannot set their modes on a fresh host. Pre-create the directory 0750
# and the three logs 0640 root:root, then normalize any file created later.
printf "preparing logs directory...\n"
LOGS_DIRECTORY="$DEPLOY_ROOT/logs"
deploy_prepare_logs_directory "$LOGS_DIRECTORY" sudo
printf "logs directory ready: %s\n" "$LOGS_DIRECTORY"

# --- Namecheap Dynamic DNS (gated by ENABLE_DDNS) -----------------------------
# Dynamic DNS is optional. When ENABLE_DDNS=true, the box is referenceable as
# $DDNS_HOST.$DDNS_DOMAIN; the record is refreshed on a 6-hour timer and once
# now so the hostname resolves to this box immediately. Verification runs in a
# separate oneshot unit (armed, not awaited) so a slow DNS answer never blocks
# the deploy. When disabled, the box is reachable by its public IP only.
if [ "$ENABLE_DDNS" = "true" ]; then
   if [ -z "$DDNS_DOMAIN" ]; then
      printf "\n*** ERROR: ENABLE_DDNS=true but DDNS_DOMAIN is not set. ***\n"
      printf "Set DDNS_DOMAIN in %s so the Dynamic DNS record can be refreshed.\n\n" "$ENV_FILE"
      exit 1
   fi
   DDNS_FQDN="$DDNS_HOST.$DDNS_DOMAIN"
   printf "configuring %s dynamic DNS...\n" "$DDNS_FQDN"

   # 1) install the DDNS password (root:root 0600) and scrub the transfer file
   DDNS_PASSWORD_SRC="$DEPLOY_ROOT/ddns-password"
   DDNS_PASSWORD_DST=/etc/strim-ddns/password
   if [ -s "$DDNS_PASSWORD_SRC" ]; then
      printf "installing DDNS password...\n"
      sudo install -D -m 600 -o root -g root "$DDNS_PASSWORD_SRC" "$DDNS_PASSWORD_DST"
      # scrub the transfer file
      if command -v shred >/dev/null 2>&1; then shred -u "$DDNS_PASSWORD_SRC"; else rm -f "$DDNS_PASSWORD_SRC"; fi
      printf "DDNS password installed to %s\n" "$DDNS_PASSWORD_DST"
   else
      printf "\n*** ERROR: no DDNS password provided. ***\n"
      printf "%s cannot be refreshed without the Namecheap Dynamic DNS\n" "$DDNS_FQDN"
      printf "password in %s.\n\n" "$DDNS_PASSWORD_SRC"
      exit 1
   fi

   # 2) install the strim-ddns unit + timer and arm the 6-hour refresh
   printf "installing strim-ddns unit and timer...\n"
   sudo install -D -m 644 "$DEPLOY_ROOT/strim-ddns.service" /etc/systemd/system/strim-ddns.service
   sudo install -D -m 644 "$DEPLOY_ROOT/strim-ddns.timer" /etc/systemd/system/strim-ddns.timer
   rm -f "$DEPLOY_ROOT/strim-ddns.service" "$DEPLOY_ROOT/strim-ddns.timer"
   sudo systemctl daemon-reload
   sudo systemctl enable --now strim-ddns.timer
   printf "strim-ddns unit and timer installed and enabled!\n"

   # 3) import the strim-ddns image
   printf "importing strim-ddns image...\n"
   sudo ctr -n "$CONTAINERD_NAMESPACE" i import strim-ddns-container.tar
   rm -f strim-ddns-container.tar
   printf "strim-ddns image imported!\n"

   # 4) one-shot refresh now so $DDNS_FQDN points at this box immediately. The
   #    unit reads DDNS_HOST / DDNS_DOMAIN / DDNS_IP from
   #    $ENV_FILE via EnvironmentFile; DDNS_IP is left empty so the client omits
   #    ip= and Namecheap uses the requester IP. This is a fast start, not a
   #    verification wait.
   printf "refreshing %s -> %s...\n" "$DDNS_FQDN" "$PUBLIC_IP"
   sudo systemctl start strim-ddns.service
   printf "%s refresh requested.\n" "$DDNS_FQDN"

   # 5) arm an ASYNC verification unit. The bounded retry loop lives inside the
   #    unit; deploy.sh neither sleeps nor waits for it, so a record that has not
   #    propagated yet cannot add ~120s to the deploy.
   printf "arming asynchronous DDNS verification...\n"
   DDNS_VERIFY_TEMPLATE="$script_dir/strim-ddns-verify.service.template"
   DDNS_VERIFY_UNIT="$DEPLOY_ROOT/strim-ddns-verify.service"
   if [ ! -f "$DDNS_VERIFY_TEMPLATE" ]; then
      printf "\n*** ERROR: %s is missing from the deploy bundle. ***\n" "$DDNS_VERIFY_TEMPLATE"
      printf "The strim-ddns-verify unit template must ship alongside deploy.sh.\n\n"
      exit 1
   fi
   sed "s|__EXPECTED_IP__|$PUBLIC_IP|g" "$DDNS_VERIFY_TEMPLATE" > "$DDNS_VERIFY_UNIT"
   sudo install -D -m 644 "$DDNS_VERIFY_UNIT" /etc/systemd/system/strim-ddns-verify.service
   rm -f "$DDNS_VERIFY_UNIT"
   sudo systemctl daemon-reload
   sudo systemctl enable strim-ddns-verify.service
   printf "DDNS verification is running in the background; it does not block this deploy.\n"
   printf "Check the result on the host with: systemctl status strim-ddns-verify\n\n"

   printf "ssh %s \"sudo systemctl start strimserver.service\"\n\n" "$DDNS_FQDN"

   printf "SRT passphrase: read it on the host from %s (0600)\n\n" "$SRT_PASSPHRASE_FILE"
else
   printf "\nDDNS is disabled (ENABLE_DDNS is not \"true\" in %s).\n" "$ENV_FILE"
   printf "The box is reachable by public IP only; no Dynamic DNS record is refreshed.\n\n"
   printf "ssh %s \"sudo systemctl start strimserver.service\"\n\n" "$PUBLIC_IP"

   printf "SRT passphrase: read it on the host from %s (0600)\n\n" "$SRT_PASSPHRASE_FILE"
fi

# --- success-only cleanup ----------------------------------------------------
# Reached only after every deploy step above succeeded, so a failed run keeps
# its payload for a retry.
printf "cleaning up deployment payloads...\n"
rm -f "$DEPLOY_ROOT/lib/nvidia.sh"
rm -f "$DEPLOY_ROOT/lib/deploy.sh"
rmdir "$DEPLOY_ROOT/lib" 2>/dev/null || true
rm -f "$DEPLOY_ROOT/deploy.sh"
