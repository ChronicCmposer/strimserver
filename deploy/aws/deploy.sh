#!/usr/bin/env bash

set -euo pipefail


mkdir -p /mnt/nvme/deploy-tmp
export TMPDIR=/mnt/nvme/deploy-tmp


cleanup() { rm -rf $TMPDIR; }
trap cleanup EXIT INT TERM


# Env variables
: "${S3_BUCKET:=s3://strimserver.cvbn.cc}"
: "${TARGET_HOSTNAME:=strimserver}"

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


# systemd service files
printf "installing systemd service files...\n"
SERVICE_FILES_TARGET=/usr/local/lib/systemd/system
set -x

sudo install -D -t $SERVICE_FILES_TARGET \
	/mnt/nvme/strimserver.service

rm -f /mnt/nvme/strimserver.service

sudo systemctl daemon-reload
set +x
printf "systemd service files installed!\n"

# import images
printf "importing images...\n"
set -x
sudo ctr i import strimserver-container.tar
rm -f strimserver-container.tar
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

aws s3 cp s3://strimserver.cvbn.cc/openssh-connor-10.3p1-1.amzn2023.x86_64.rpm /mnt/nvme/openssh.rpm

sudo dnf install -y /mnt/nvme/openssh.rpm
rm -f /mnt/nvme/openssh.rpm

sudo /usr/local/bin/ssh-keygen -A
sudo /usr/local/sbin/sshd

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

# printf "Services running on %s: %s \n\n" "$INSTANCE_TYPE" "$PUBLIC_IP"
printf "ssh strimserver \"sudo systemctl start strimserver.service\"\n\n"

printf "configure-local-encoder.zsh --strimserver-host %s --passphrase %s\n\n" "$PUBLIC_IP" "$SRT_READ_PASSPHRASE"

rm -f /mnt/nvme/deploy.sh

