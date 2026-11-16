#!/usr/bin/env bash
#
# stackctl on-box setup entrypoint for strimserver.
#
# stackctl downloads the sha-verified release bundle, extracts it to a staging
# directory under /run, and runs this script from the bundle root as root with
# the STACKCTL_* environment contract. This script does only what stackctl no
# longer does from the operator side: mount the instance store, stage the
# bundle on it, fetch the Twitch stream key from SSM, render the runtime env,
# then hand off to the unchanged deploy.sh as ec2-user.
#
# A non-zero exit here is the launch rc sentinel; every failure prints a
# diagnostic to stderr and exits non-zero.

set -euo pipefail
umask 077

readonly PROJECT="${STACKCTL_PROJECT:-strimserver}"
readonly NVME_MOUNT="/mnt/nvme"
readonly INSTANCE_STORE_MODEL="Amazon EC2 NVMe Instance Storage"
readonly SERVICE_USER="${STRIMSERVER_SERVICE_USER:-ec2-user}"
readonly TWITCH_PARAM="/${PROJECT}/twitch-stream-key"
readonly IMDS_BASE="${IMDS:-http://169.254.169.254}"

log() {
   printf 'stackctl-setup: %s\n' "$*" >&2
}

die() {
   printf 'stackctl-setup: ERROR: %s\n' "$*" >&2
   exit 1
}

require_cmd() {
   command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# --- IMDSv2 ----------------------------------------------------------------
imds_get() {
   local token path="$1"
   token="$(curl -fsS --connect-timeout 2 --max-time 5 -X PUT \
      -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600' \
      "${IMDS_BASE}/latest/api/token")" || return 1
   [ -n "$token" ] || return 1
   curl -fsS --connect-timeout 2 --max-time 5 \
      -H "X-aws-ec2-metadata-token: ${token}" \
      "${IMDS_BASE}/latest/${path}"
}

resolve_region() {
   if [ -n "${STACKCTL_REGION:-}" ]; then
      printf '%s' "$STACKCTL_REGION"
      return 0
   fi
   if [ -n "${AWS_REGION:-}" ]; then
      printf '%s' "$AWS_REGION"
      return 0
   fi
   imds_get meta-data/placement/region
}

# --- SigV4 SSM GetParameter (curl + openssl only; no aws CLI) --------------
sha256_hex() {
   printf '%s' "$1" | openssl dgst -sha256 -r | cut -d' ' -f1
}

hmac_sha256_hex() {
   # $1 is the key as lowercase hex, $2 is the message.
   printf '%s' "$2" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$1" -r \
      | cut -d' ' -f1
}

fetch_ssm_securestring() {
   local param="$1" region="$2"
   local role creds_json akid secret_key session_token
   local date_stamp amz_date host body payload_hash
   local canonical_headers canonical_request signed_headers
   local credential_scope string_to_sign secret_hex
   local k_date k_region k_service k_signing signature authorization
   local response value nl=$'\n'

   [ -n "$region" ] || die "cannot determine the AWS region for SSM"

   role="$(imds_get meta-data/iam/security-credentials/)" \
      || die "IMDS instance-role credentials are unavailable"
   role="${role%%$'\n'*}"
   [ -n "$role" ] || die "IMDS returned an empty instance-role name"

   creds_json="$(imds_get "meta-data/iam/security-credentials/${role}")" \
      || die "IMDS instance-role credentials could not be read"
   akid="$(printf '%s' "$creds_json" | sed -n 's/.*"AccessKeyId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
   secret_key="$(printf '%s' "$creds_json" | sed -n 's/.*"SecretAccessKey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
   session_token="$(printf '%s' "$creds_json" | sed -n 's/.*"Token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
   if [ -z "$akid" ] || [ -z "$secret_key" ] || [ -z "$session_token" ]; then
      die "could not parse instance-role credentials from IMDS"
   fi

   date_stamp="$(date -u +%Y%m%d)"
   amz_date="$(date -u +%Y%m%dT%H%M%SZ)"
   host="ssm.${region}.amazonaws.com"
   body="{\"Name\":\"${param}\",\"WithDecryption\":true}"
   payload_hash="$(sha256_hex "$body")"

   canonical_headers="content-type:application/x-amz-json-1.1${nl}host:${host}${nl}x-amz-date:${amz_date}${nl}x-amz-security-token:${session_token}${nl}x-amz-target:AmazonSSM.GetParameter${nl}"
   signed_headers="content-type;host;x-amz-date;x-amz-security-token;x-amz-target"
   canonical_request="POST${nl}/${nl}${nl}${canonical_headers}${signed_headers}${nl}${payload_hash}"

   credential_scope="${date_stamp}/${region}/ssm/aws4_request"
   string_to_sign="AWS4-HMAC-SHA256${nl}${amz_date}${nl}${credential_scope}${nl}$(sha256_hex "$canonical_request")"

   secret_hex="$(printf '%s' "AWS4${secret_key}" | od -An -v -tx1 | tr -d ' \n')"
   k_date="$(hmac_sha256_hex "$secret_hex" "$date_stamp")"
   k_region="$(hmac_sha256_hex "$k_date" "$region")"
   k_service="$(hmac_sha256_hex "$k_region" "ssm")"
   k_signing="$(hmac_sha256_hex "$k_service" "aws4_request")"
   signature="$(hmac_sha256_hex "$k_signing" "$string_to_sign")"
   authorization="AWS4-HMAC-SHA256 Credential=${akid}/${credential_scope}, SignedHeaders=${signed_headers}, Signature=${signature}"

   response="$(curl -fsS --connect-timeout 3 --max-time 20 \
      -X POST "https://${host}/" \
      -H "Content-Type: application/x-amz-json-1.1" \
      -H "X-Amz-Target: AmazonSSM.GetParameter" \
      -H "X-Amz-Date: ${amz_date}" \
      -H "X-Amz-Security-Token: ${session_token}" \
      -H "Authorization: ${authorization}" \
      --data "$body")" \
      || die "SSM GetParameter failed for ${param} (store it as a SecureString first)"

   value="$(printf '%s' "$response" | sed -n 's/.*"Value"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
   [ -n "$value" ] || die "SSM returned no Value for ${param}"
   printf '%s' "$value"
}

# --- NVMe instance store ---------------------------------------------------
normalize_model() {
   printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' \
      | sed -e 's/^ //' -e 's/ $//'
}

# True when the device is an EC2 instance-store NVMe disk. lsblk's MODEL
# column can be empty or truncated on some util-linux builds (observed on
# the baked AL2023 DLAMI), so fall back to the sysfs model exactly like the
# predecessor setup_strimserver's proven-live detection chain did.
is_instance_store() {
   local name="$1" model="$2" sysfs_model wanted
   wanted="$(normalize_model "$INSTANCE_STORE_MODEL")"
   [ "$(normalize_model "$model")" = "$wanted" ] && return 0
   sysfs_model="$(cat "/sys/block/${name}/device/model" 2>/dev/null || true)"
   [ "$(normalize_model "$sysfs_model")" = "$wanted" ]
}

select_instance_store() {
   local listing name type model best="" best_key=""
   local key
   listing="$(lsblk -dnrno NAME,TYPE,MODEL)" \
      || die "could not enumerate block devices (lsblk failed)"
   while read -r name type model; do
      [ "$type" = "disk" ] || continue
      case "$name" in
         nvme[0-9]*n[0-9]*) ;;
         *) continue ;;
      esac
      is_instance_store "$name" "$model" || continue
      key="${name#nvme}"
      key="${key%%n*}"
      if [ -z "$best" ] || [ "$key" -lt "$best_key" ]; then
         best="$name"
         best_key="$key"
      fi
   done <<<"$listing"
   printf '%s' "$best"
}

root_disk_names() {
   local source
   source="$(findmnt -n -o SOURCE --mountpoint /)" \
      || die "could not resolve the root filesystem source"
   source="${source%%\[*}"
   source="$(realpath -e "$source" 2>/dev/null || printf '%s' "$source")"
   printf '%s\n' "$(basename "$source")"
   lsblk -P -s -n -o NAME,PKNAME "$source" 2>/dev/null \
      | grep -oE '(NAME|PKNAME)="[^"]+"' | cut -d'"' -f2 || true
}

assert_safe_target() {
   local dev="$1" names target children name
   [ -b "$dev" ] || die "${dev} is not a block device"

   names=" $(root_disk_names | tr '\n' ' ') "
   case "$names" in
      *" $(basename "$dev") "*) die "${dev} backs the root filesystem" ;;
   esac

   target="$(findmnt -n -o TARGET --source "$dev" 2>/dev/null || true)"
   [ -z "$target" ] || die "${dev} is already mounted at ${target}"

   children="$(lsblk -nrno NAME "$dev" 2>/dev/null | tail -n +2 || true)"
   [ -z "$children" ] || die "${dev} has partitions/children: $(printf '%s' "$children" | tr '\n' ' ')"

   if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$dev"; then
      die "${dev} is in use as swap"
   fi
}

mount_instance_store() {
   if mountpoint -q "$NVME_MOUNT"; then
      log "${NVME_MOUNT} is already mounted; keeping it"
      return 0
   fi

   local dev fstype
   if [ -n "${NVME_DEVICE:-}" ]; then
      dev="$NVME_DEVICE"
   else
      dev="$(select_instance_store)"
   fi
   [ -n "$dev" ] \
      || die "no Amazon EC2 NVMe Instance Storage device found (set NVME_DEVICE to override)"
   log "selected instance-store device: ${dev}"
   assert_safe_target "$dev"

   mkdir -p "$NVME_MOUNT"
   fstype="$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)"
   if [ -z "$fstype" ]; then
      log "no filesystem on ${dev}; creating ext4"
      mkfs.ext4 -F "$dev" >/dev/null || die "mkfs.ext4 failed on ${dev}"
   else
      log "reusing existing ${fstype} filesystem on ${dev}"
   fi
   mount "$dev" "$NVME_MOUNT" || die "failed to mount ${dev} at ${NVME_MOUNT}"
   if id "$SERVICE_USER" >/dev/null 2>&1; then
      chown "${SERVICE_USER}:${SERVICE_USER}" "$NVME_MOUNT" \
         || die "failed to chown ${NVME_MOUNT}"
   fi
}

# --- Stage the bundle ------------------------------------------------------
stage_bundle() {
   local bundle_root
   bundle_root="$(pwd)"
   [ -f "${bundle_root}/deploy.sh" ] \
      || die "deploy.sh is missing from the release bundle"
   [ -f "${bundle_root}/strimserver.env.template" ] \
      || die "strimserver.env.template is missing from the release bundle"

   # Never let a stale helper from a previous bundle shadow the new one.
   rm -f "${NVME_MOUNT}/lib/deploy.sh" "${NVME_MOUNT}/lib/nvidia.sh"
   cp -a "${bundle_root}/." "$NVME_MOUNT/" \
      || die "failed to stage the bundle into ${NVME_MOUNT}"

   local f
   for f in deploy.sh setup-gpu.sh lib/nvidia.sh lib/deploy.sh stackctl-setup.sh; do
      if [ -f "${NVME_MOUNT}/${f}" ]; then
         chmod +x "${NVME_MOUNT}/${f}" || die "failed to chmod ${f}"
      fi
   done

   if id "$SERVICE_USER" >/dev/null 2>&1; then
      chown -R "${SERVICE_USER}:${SERVICE_USER}" "$NVME_MOUNT" \
         || die "failed to chown ${NVME_MOUNT}"
   fi
}

# --- Render the runtime env ------------------------------------------------
render_env() {
   local template="${NVME_MOUNT}/strimserver.env.template"
   local target="${NVME_MOUNT}/config/strimserver.env"
   local key escaped_key tmp

   key="$(fetch_ssm_securestring "$TWITCH_PARAM" "$(resolve_region)")"
   [ -n "$key" ] || die "empty Twitch stream key returned by SSM"

   escaped_key="$(printf '%s' "$key" | sed -e 's/[\\|&]/\\&/g')"
   mkdir -p "${NVME_MOUNT}/config"
   if id "$SERVICE_USER" >/dev/null 2>&1; then
      chown "${SERVICE_USER}:${SERVICE_USER}" "${NVME_MOUNT}/config" \
         || die "failed to chown ${NVME_MOUNT}/config"
   fi

   tmp="$(mktemp "${NVME_MOUNT}/config/.strimserver.env.XXXXXX")" \
      || die "could not create a temp env file"
   sed -e "s|__TWITCH_STREAM_KEY__|${escaped_key}|g" "$template" >"$tmp" \
      || { rm -f "$tmp"; die "failed to render ${target}"; }

   mv "$tmp" "$target" || { rm -f "$tmp"; die "failed to install ${target}"; }
   chmod 600 "$target" || die "failed to chmod 600 ${target}"
   if id "$SERVICE_USER" >/dev/null 2>&1; then
      chown "${SERVICE_USER}:${SERVICE_USER}" "$target" \
         || die "failed to chown ${target}"
   fi
   # Do not leave the template (or any transfer copy) holding a secret.
   unset key escaped_key
}

# --- Main ------------------------------------------------------------------
main() {
   require_cmd mountpoint
   require_cmd lsblk
   require_cmd findmnt
   require_cmd blkid
   require_cmd mkfs.ext4
   require_cmd curl
   require_cmd openssl
   require_cmd od

   mount_instance_store
   stage_bundle
   render_env

   cd "$NVME_MOUNT"
   log "handing off to deploy.sh as ${SERVICE_USER}"
   if [ "$(id -u)" -eq 0 ] && id "$SERVICE_USER" >/dev/null 2>&1 \
      && command -v sudo >/dev/null 2>&1; then
      exec sudo -H -u "$SERVICE_USER" -- ./deploy.sh
   fi
   exec ./deploy.sh
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
   main "$@"
fi
