#!/usr/bin/env bash

set -euo pipefail
# Secrets are written below (SRT passphrase); make the default creation mode
# private and never rely on a later chmod alone.
umask 077

# Pure deploy helpers live beside this script in the bundle (lib/deploy.sh) and
# in the repo (deploy/aws/lib/deploy.sh). Resolve relative to this file so both
# layouts work.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/deploy.sh
source "$script_dir/lib/deploy.sh"

mkdir -p /mnt/nvme/deploy-tmp
export TMPDIR=/mnt/nvme/deploy-tmp


cleanup() { rm -rf $TMPDIR; }
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
source /mnt/nvme/imdslib.sh 
export PUBLIC_IP=$(get_public_ip)
export INSTANCE_TYPE=$(get_instance_type)

rm -f /mnt/nvme/imdslib.sh

# config/bin directories
mkdir -p /mnt/nvme/config
mkdir -p /mnt/nvme/bin

# --- install the bundled config + tools (idempotent on re-run) ---------------
# Only install the bundled env when no config is already present: a re-run (or
# a cutover) must never overwrite an operator-injected /mnt/nvme/config.
if [ ! -f /mnt/nvme/config/strimserver.env ] && [ -f /mnt/nvme/strimserver.env ]; then
   mv /mnt/nvme/strimserver.env /mnt/nvme/config/strimserver.env
fi
if [ -f /mnt/nvme/mediamtx.yaml.template ] && [ ! -f /mnt/nvme/config/mediamtx.yaml.template ]; then
   mv /mnt/nvme/mediamtx.yaml.template /mnt/nvme/config/mediamtx.yaml.template
fi
if [ -f /mnt/nvme/transcode.sh ]; then
   mv /mnt/nvme/transcode.sh /mnt/nvme/bin/transcode.sh
fi
if [ -f /mnt/nvme/notify ]; then
   mv /mnt/nvme/notify /mnt/nvme/bin/notify
fi

chmod +x /mnt/nvme/bin/transcode.sh
chmod +x /mnt/nvme/bin/notify

# --- inject Dynamic DNS settings (ENABLE_DDNS / DDNS_HOST / DDNS_DOMAIN) ------
# The operator's Dynamic DNS settings (root .env) are transferred as a 0600 file
# by setup_strimserver, mirroring the Twitch stream key. Merge them into the
# on-box strimserver.env BEFORE sourcing it below, so both deploy.sh's DDNS block
# and the strim-ddns unit's EnvironmentFile see the operator values. With no
# file, the bundled defaults (DDNS disabled) stay in effect.
ENV_FILE=/mnt/nvme/config/strimserver.env
DDNS_CONFIG_FILE=/mnt/nvme/ddns-config
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
source /mnt/nvme/config/strimserver.env
ENABLE_DDNS="${ENABLE_DDNS:-false}"
DDNS_HOST="${DDNS_HOST:-strim}"
DDNS_DOMAIN="${DDNS_DOMAIN:-}"

# --- inject Twitch stream key ------
ENV_FILE=/mnt/nvme/config/strimserver.env
KEY_FILE=/mnt/nvme/twitch-stream-key
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

# NVIDIA GPU runtime: arch-aware. setup-gpu.sh sources lib/nvidia.sh and
# enforces/upgrades the host driver floor (620.70.06) before wiring the
# container runtime; the DLAMI's bundled driver is only the starting point.
# Both controllers -- the Go controller (CONTROLLER_VARIANT=go-*) and the C
# controller (CONTROLLER_VARIANT=c-*, the musl-static Go-equivalent port) --
# inject CDI themselves from JSON specs in the bind-mounted /var/run/cdi
# (setup-gpu.sh generates /var/run/cdi/nvidia.json there; the C controller
# mirrors the Go cdi.WithCDIDevices behavior), so no runtime shim switch is
# needed on either arch. Runs BEFORE the containerd block below so the single
# restart picks up any GPU wiring together with the root/state config prepend.
# setup-gpu.sh is removed only in the success-only cleanup at the end, so a
# failed run can be retried.
bash ./setup-gpu.sh

# containerd
# A re-run must not prepend a second root/state pair: duplicate TOML keys make
# containerd fail with "toml: key root is already defined". The helper reads the
# existing config via `sudo cat` (failing closed when it is unreadable) and
# strips any existing root/state assignment before adding the canonical pair.
printf "configuring containerd...\n"
containerd_config_tmp="$(mktemp)"
deploy_prepend_containerd_root_state \
   /etc/containerd/config.toml "$containerd_config_tmp" sudo
sudo install -m 644 "$containerd_config_tmp" /etc/containerd/config.toml
rm -f "$containerd_config_tmp"
sudo systemctl restart containerd.service
printf "containerd configured!\n"


# systemd service file (ships inside the bundle as strimserver.service).
# Enabled but not started: the container images are imported further below, and
# the first start stays an explicit operator action (deploy/aws/start_strimserver).
printf "installing systemd service file...\n"

sudo install -D -m 644 /mnt/nvme/strimserver.service /etc/systemd/system/strimserver.service

rm -f /mnt/nvme/strimserver.service

sudo systemctl daemon-reload
sudo systemctl enable strimserver.service
printf "systemd service file installed and enabled!\n"

# import images
printf "importing images (%s)...\n" "$CONTROLLER_VARIANT"
CONTAINERD_NAMESPACE="strimserver"
sudo ctr -n $CONTAINERD_NAMESPACE i import controller-container.tar
sudo ctr -n $CONTAINERD_NAMESPACE i import ffmpeg-container.tar
sudo ctr -n $CONTAINERD_NAMESPACE i import mediamtx-container.tar
rm -f {controller,ffmpeg,mediamtx}-container.tar
printf "image import started!\n"

# Generate an SRT passphrase once (0600 root:root), never printing its value.
# On a re-run the helper keeps the existing passphrase so the operator's
# already-configured encoder keeps working.
SRT_PASSPHRASE_FILE=/mnt/nvme/srt-passphrase
printf "preparing SRT passphrase...\n"
deploy_write_srt_passphrase "$SRT_PASSPHRASE_FILE" sudo
SRT_READ_PASSPHRASE="$(sudo cat "$SRT_PASSPHRASE_FILE")"
export SRT_READ_PASSPHRASE
printf "srt passphrase file: %s (0600)\n" "$SRT_PASSPHRASE_FILE"

source /mnt/nvme/fish-deploy.sh
rm -f /mnt/nvme/fish-deploy.sh

printf "installing remaining tools...\n"
sudo dnf install -y htop

# The experimental OpenSSH RPM is always bundled (fetched from the pinned
# @openssh_dist artifact by the Bazel package build).
if [ -f /mnt/nvme/openssh-experimental.rpm ]; then
   sudo dnf install -y /mnt/nvme/openssh-experimental.rpm
   rm -f /mnt/nvme/openssh-experimental.rpm

   sudo /usr/local/bin/ssh-keygen -A
   sudo /usr/local/sbin/sshd
else
   printf "\n*** WARNING: openssh-experimental.rpm is not in this bundle; skipping. ***\n\n"
fi

# put other package installations here
printf "tool installation complete!\n"

printf "setting hostname...\n"
sudo hostnamectl set-hostname $TARGET_HOSTNAME
printf "hostname set to %s\n" $(hostname)

printf "creating video-files directory...\n"
VIDEO_FILES_DIRECTORY=/mnt/nvme/video-files
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
LOGS_DIRECTORY=/mnt/nvme/logs
deploy_prepare_logs_directory "$LOGS_DIRECTORY" sudo
printf "logs directory ready: %s\n" "$LOGS_DIRECTORY"

# printf "starting services...\n"
# set -x
# sudo systemctl start \
# 	strimserver.service
# set +x
# printf "services started!\n"

# --- Namecheap Dynamic DNS (gated by ENABLE_DDNS) -----------------------------
# Dynamic DNS is optional. When ENABLE_DDNS=true, the box is referenceable as
# $DDNS_HOST.$DDNS_DOMAIN; the record is refreshed on a 6-hour timer and once
# now so the hostname resolves to this box immediately. When disabled, the box
# is reachable by its public IP only.
if [ "$ENABLE_DDNS" = "true" ]; then
   if [ -z "$DDNS_DOMAIN" ]; then
      printf "\n*** ERROR: ENABLE_DDNS=true but DDNS_DOMAIN is not set. ***\n"
      printf "Set DDNS_DOMAIN in %s so the Dynamic DNS record can be refreshed.\n\n" "$ENV_FILE"
      exit 1
   fi
   DDNS_FQDN="$DDNS_HOST.$DDNS_DOMAIN"
   printf "configuring %s dynamic DNS...\n" "$DDNS_FQDN"

   # 1) install the DDNS password (root:root 0600) and scrub the transfer file
   DDNS_PASSWORD_SRC=/mnt/nvme/ddns-password
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
   sudo install -D -m 644 /mnt/nvme/strim-ddns.service /etc/systemd/system/strim-ddns.service
   sudo install -D -m 644 /mnt/nvme/strim-ddns.timer /etc/systemd/system/strim-ddns.timer
   rm -f /mnt/nvme/strim-ddns.service /mnt/nvme/strim-ddns.timer
   sudo systemctl daemon-reload
   sudo systemctl enable --now strim-ddns.timer
   printf "strim-ddns unit and timer installed and enabled!\n"

   # 3) import the strim-ddns image
   printf "importing strim-ddns image...\n"
   sudo ctr -n $CONTAINERD_NAMESPACE i import strim-ddns-container.tar
   rm -f strim-ddns-container.tar
   printf "strim-ddns image imported!\n"

   # 4) one-shot refresh now so $DDNS_FQDN points at this box immediately. The
   #    unit reads DDNS_HOST / DDNS_DOMAIN / DDNS_IP from
   #    /mnt/nvme/config/strimserver.env via EnvironmentFile; DDNS_IP is left
   #    empty so the client omits ip= and Namecheap uses the requester IP.
   printf "refreshing %s -> %s...\n" "$DDNS_FQDN" "$PUBLIC_IP"
   sudo systemctl start strim-ddns.service
   printf "%s refresh done!\n" "$DDNS_FQDN"

   # 5) verify the record resolves to this box (bounded: 24 retries with 5s
   #    slept between them, so an all-failures run takes ~120s worst case
   #    rather than unbounded time).
   #    Resolve via the strim-ddns container's `check` subcommand, which
   #    queries the authoritative NS directly (c-ares, no DoH): the lookup
   #    bypasses AL2023's systemd-resolved cache (stale TTLs and negative-cached
   #    NXDOMAIN would otherwise produce false failures). c-ares applies its
   #    own internal query timeout, so no per-query timeout env is needed.
   #    Invocation shape: the container command is `/strim-ddns check
   #    <host> <domain>` -- NOT a bare `check`. `ctr run` treats the first
   #    positional after the container name as the container command, which
   #    overrides the image ENTRYPOINT (/strim-ddns); a bare `check` would
   #    make runc exec a literal `check` binary that does not exist. The
   #    leading /strim-ddns is required.
   #    Per-iteration invocation: `check` needs no DDNS password, so no
   #    password bind-mount or DDNS_PASSWORD_FILE env is passed. The
   #    resolv.conf + hosts bind-mounts mirror the strim-ddns unit and are
   #    required: the FROM-scratch image ships neither file, so the container
   #    would otherwise have no resolver configuration.
   #    Stream contract: stdout carries only the resolved IPv4 (captured into
   #    DDNS_RESOLVED_IP for the comparison below); stderr carries the
   #    per-attempt diagnostic (e.g. `check strim.example.com -> 203.0.113.10
   #    (via ns1.example.com)`) and passes straight through to the deploy log.
   printf "verifying %s -> %s...\n" "$DDNS_FQDN" "$PUBLIC_IP"
   DDNS_VERIFIED=0
   for attempt in $(seq 1 24); do
      printf "attempt %s/24: resolving %s...\n" "$attempt" "$DDNS_FQDN"
      DDNS_RESOLVED_IP="$(sudo ctr -n "$CONTAINERD_NAMESPACE" run --rm --net-host \
         --mount type=bind,src=/etc/resolv.conf,dst=/etc/resolv.conf,options=rbind:ro \
         --mount type=bind,src=/etc/hosts,dst=/etc/hosts,options=rbind:ro \
         docker.io/library/strim-ddns:latest strim-ddns /strim-ddns check "$DDNS_HOST" "$DDNS_DOMAIN")" || DDNS_RESOLVED_IP=""
      if [ -n "$DDNS_RESOLVED_IP" ] && [ "$DDNS_RESOLVED_IP" = "$PUBLIC_IP" ]; then
         DDNS_VERIFIED=1
         break
      fi
      if [ "$attempt" -lt 24 ]; then
         sleep 5
      fi
   done
   if [ "$DDNS_VERIFIED" -ne 1 ]; then
      printf "\n*** ERROR: %s did not resolve to %s. ***\n" "$DDNS_FQDN" "$PUBLIC_IP"
      printf "Expected: %s   Actual: %s\n" "$PUBLIC_IP" "${DDNS_RESOLVED_IP:-<not resolved>}"
      exit 1
   fi
   printf "DDNS verified: %s -> %s\n" "$DDNS_FQDN" "$DDNS_RESOLVED_IP"

   # printf "Services running on %s: %s \n\n" "$INSTANCE_TYPE" "$PUBLIC_IP"
   printf "ssh %s \"sudo systemctl start strimserver.service\"\n\n" "$DDNS_FQDN"

   printf "SRT passphrase: read it on the host from %s (0600)\n\n" "$SRT_PASSPHRASE_FILE"
else
   printf "\nDDNS is disabled (ENABLE_DDNS is not \"true\" in %s).\n" "$ENV_FILE"
   printf "The box is reachable by public IP only; no Dynamic DNS record is refreshed.\n\n"
   printf "ssh %s \"sudo systemctl start strimserver.service\"\n\n" "$PUBLIC_IP"

   printf "SRT passphrase: read it on the host from %s (0600)\n\n" "$SRT_PASSPHRASE_FILE"
fi

# --- success-only cleanup ----------------------------------------------------
# Reached only after every deploy step above succeeded (including the DDNS
# verification when enabled), so a failed run keeps its payload for a retry.
printf "cleaning up deployment payloads...\n"
rm -f /mnt/nvme/setup-gpu.sh
rm -f /mnt/nvme/lib/nvidia.sh
rm -f /mnt/nvme/lib/deploy.sh
rmdir /mnt/nvme/lib 2>/dev/null || true
rm -f /mnt/nvme/deploy.sh

