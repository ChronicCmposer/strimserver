#!/usr/bin/env bash

set -euo pipefail


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

mv /mnt/nvme/strimserver.env /mnt/nvme/config/strimserver.env
mv /mnt/nvme/mediamtx.yaml.template /mnt/nvme/config/mediamtx.yaml.template
mv /mnt/nvme/transcode.sh /mnt/nvme/bin/transcode.sh
mv /mnt/nvme/notify /mnt/nvme/bin/notify

chmod +x /mnt/nvme/bin/transcode.sh
chmod +x /mnt/nvme/bin/notify

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
# ------------------------------------------------------------------------------

# NVIDIA GPU runtime: arch-aware (the DLAMI carries the driver + container
# toolkit). Both controllers -- the Go controller (CONTROLLER_VARIANT=go-*)
# and the C controller (CONTROLLER_VARIANT=c-*, the musl-static Go-equivalent
# port) -- inject CDI themselves from JSON specs in the bind-mounted
# /var/run/cdi (setup-gpu.sh generates /var/run/cdi/nvidia.json there; the C
# controller mirrors the Go cdi.WithCDIDevices behavior), so no runtime shim
# switch is needed on either arch. Runs BEFORE the containerd block below so
# the single restart picks up any GPU wiring together with the root/state
# config prepend.
bash ./setup-gpu.sh
rm -f /mnt/nvme/setup-gpu.sh

# containerd
printf "configuring containerd...\n"
set -x
{
   printf "root='/mnt/nvme/containerd'\n"
   printf "state='/mnt/nvme/containerd-state'\n\n"

} | cat - /etc/containerd/config.toml | sudo tee /etc/containerd/config.toml
sudo systemctl restart containerd.service
set +x
printf "containerd configured!\n"


# systemd service file (ships inside the bundle as strimserver.service).
# Enabled but not started: the container images are imported further below, and
# the first start stays an explicit operator action (deploy/aws/start_strimserver).
printf "installing systemd service file...\n"
set -x

sudo install -D -m 644 /mnt/nvme/strimserver.service /etc/systemd/system/strimserver.service

rm -f /mnt/nvme/strimserver.service

sudo systemctl daemon-reload
sudo systemctl enable strimserver.service
set +x
printf "systemd service file installed and enabled!\n"

# import images
printf "importing images (%s)...\n" "$CONTROLLER_VARIANT"
CONTAINERD_NAMESPACE="strimserver"
set -x
sudo ctr -n $CONTAINERD_NAMESPACE i import controller-container.tar
sudo ctr -n $CONTAINERD_NAMESPACE i import ffmpeg-container.tar
sudo ctr -n $CONTAINERD_NAMESPACE i import mediamtx-container.tar
rm -f {controller,ffmpeg,mediamtx}-container.tar
set +x
printf "image import started!\n"

# Generate SRT passphrase
printf "generating SRT passphrase...\n"
SRT_READ_PASSPHRASE_FILE=/mnt/nvme/srt-passphrase
export SRT_READ_PASSPHRASE="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 70)"
printf "%s\n" "$SRT_READ_PASSPHRASE" > $SRT_READ_PASSPHRASE_FILE
printf "srt passphrase generated!\n"

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
set -x
sudo hostnamectl set-hostname $TARGET_HOSTNAME
set +x
printf "hostname set to %s\n" $(hostname)

printf "creating video-files directory...\n"
set -x
VIDEO_FILES_DIRECTORY=/mnt/nvme/video-files
mkdir -p $VIDEO_FILES_DIRECTORY
set +x
printf "video-files directory created: %s\n" "$VIDEO_FILES_DIRECTORY"

printf "configuring offline segment...\n"
set -x
OFFLINE_SEGMENT_FILE_NAME=strimserver-offline-2160p60.mp4
mv "$OFFLINE_SEGMENT_FILE_NAME" "$VIDEO_FILES_DIRECTORY"
set +x
printf "offline segment configured: %s\n" "$OFFLINE_SEGMENT_FILE_NAME"

printf "creating logs directory...\n"
set -x
LOGS_DIRECTORY=/mnt/nvme/logs
sudo mkdir -p $LOGS_DIRECTORY
set +x
printf "logs directory created: %s\n" "$LOGS_DIRECTORY"

# printf "starting services...\n"
# set -x
# sudo systemctl start \
# 	strimserver.service
# set +x
# printf "services started!\n"

printf "srt passphrase: %s\n\n" "$SRT_READ_PASSPHRASE"

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
   set -x
   sudo install -D -m 644 /mnt/nvme/strim-ddns.service /etc/systemd/system/strim-ddns.service
   sudo install -D -m 644 /mnt/nvme/strim-ddns.timer /etc/systemd/system/strim-ddns.timer
   rm -f /mnt/nvme/strim-ddns.service /mnt/nvme/strim-ddns.timer
   sudo systemctl daemon-reload
   sudo systemctl enable --now strim-ddns.timer
   set +x
   printf "strim-ddns unit and timer installed and enabled!\n"

   # 3) import the strim-ddns image
   printf "importing strim-ddns image...\n"
   set -x
   sudo ctr -n $CONTAINERD_NAMESPACE i import strim-ddns-container.tar
   rm -f strim-ddns-container.tar
   set +x
   printf "strim-ddns image imported!\n"

   # 4) one-shot refresh now so $DDNS_FQDN points at this box immediately. The
   #    unit reads DDNS_HOST / DDNS_DOMAIN / DDNS_IP from
   #    /mnt/nvme/config/strimserver.env via EnvironmentFile; DDNS_IP is left
   #    empty so the client omits ip= and Namecheap uses the requester IP.
   printf "refreshing %s -> %s...\n" "$DDNS_FQDN" "$PUBLIC_IP"
   set -x
   sudo systemctl start strim-ddns.service
   set +x
   printf "%s refresh done!\n" "$DDNS_FQDN"

   # 5) verify the record resolves to this box (120s budget: ~24 x 5s retries)
   printf "verifying %s -> %s...\n" "$DDNS_FQDN" "$PUBLIC_IP"
   DDNS_VERIFIED=0
   for attempt in $(seq 1 24); do
      DDNS_RESOLVED_IP="$(getent ahostsv4 "$DDNS_FQDN" 2>/dev/null | awk 'NR==1 {print $1}')" || DDNS_RESOLVED_IP=""
      if [ -n "$DDNS_RESOLVED_IP" ] && [ "$DDNS_RESOLVED_IP" = "$PUBLIC_IP" ]; then
         DDNS_VERIFIED=1
         break
      fi
      sleep 5
   done
   if [ "$DDNS_VERIFIED" -ne 1 ]; then
      printf "\n*** ERROR: %s did not resolve to %s. ***\n" "$DDNS_FQDN" "$PUBLIC_IP"
      printf "Expected: %s   Actual: %s\n" "$PUBLIC_IP" "${DDNS_RESOLVED_IP:-<not resolved>}"
      exit 1
   fi
   printf "DDNS verified: %s -> %s\n" "$DDNS_FQDN" "$DDNS_RESOLVED_IP"

   # printf "Services running on %s: %s \n\n" "$INSTANCE_TYPE" "$PUBLIC_IP"
   printf "ssh %s \"sudo systemctl start strimserver.service\"\n\n" "$DDNS_FQDN"

   printf "configure-local-encoder.zsh --strimserver-host %s --passphrase %s\n\n" "$DDNS_FQDN" "$SRT_READ_PASSPHRASE"
else
   printf "\nDDNS is disabled (ENABLE_DDNS is not \"true\" in %s).\n" "$ENV_FILE"
   printf "The box is reachable by public IP only; no Dynamic DNS record is refreshed.\n\n"
   printf "ssh %s \"sudo systemctl start strimserver.service\"\n\n" "$PUBLIC_IP"

   printf "configure-local-encoder.zsh --strimserver-host %s --passphrase %s\n\n" "$PUBLIC_IP" "$SRT_READ_PASSPHRASE"
fi

rm -f /mnt/nvme/deploy.sh

