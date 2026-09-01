#!/usr/bin/env bash
# scripts/upload-artifact.sh -- upload the built FFmpeg artifact to S3 so
# MODULE.bazel's s3_http_archive (name = "ffmpeg_dist") can fetch it. Usage:
# ./scripts/upload-artifact.sh [ARTIFACT] (default: the single ffmpeg-*.tar.gz
# under tools/ffmpeg-dist/).
# Env overrides (required): S3_BUCKET_NAME, S3_KEY_PREFIX (ffmpeg), AWS_REGION,
# EXPECTED_SHA256 (MODULE.bazel pin), SKIP_SHA_CHECK (unset; 1 = skip the sha256
# contract). Uploads without any ACL modification (objects get the bucket's default
# private ACL; the IP-scoped HTTPS-only bucket policy from scripts/bucket-cidr-policy.sh
# is the only access gate). Prints the path-style public URL
# (https://s3.<region>.amazonaws.com/<bucket>/<key>), with the region from $AWS_REGION.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S3_BUCKET_NAME="${S3_BUCKET_NAME:?S3_BUCKET_NAME is required (e.g. your-bucket-name)}"
S3_KEY_PREFIX="${S3_KEY_PREFIX:-ffmpeg}"
AWS_REGION="${AWS_REGION:?AWS_REGION is required}"
EXPECTED_SHA256="${EXPECTED_SHA256:-2df93667c7e12f2666be244772a41c653a02cab74880e685623770bd9c86ac34}"
SKIP_SHA_CHECK="${SKIP_SHA_CHECK:-}"

# --- guard: awscli must be installed and configured ---
if ! command -v aws >/dev/null 2>&1; then
  echo "error: 'aws' (awscli) not found; install it and run 'aws configure'." >&2
  exit 1
fi

# --- resolve the artifact: CLI arg wins; default is the single ffmpeg-*.tar.gz ---
artifact="${1:-}"
if [[ -z "$artifact" ]]; then
  shopt -s nullglob
  matches=( "$script_dir/tools/ffmpeg-dist"/ffmpeg-*.tar.gz )
  shopt -u nullglob
  if [[ "${#matches[@]}" -ne 1 ]]; then
    echo "error: expected exactly one ffmpeg-*.tar.gz under tools/ffmpeg-dist/, found ${#matches[@]}:" >&2
    printf '       %s\n' "${matches[@]}" >&2
    echo "       pass the artifact explicitly: ./scripts/upload-artifact.sh /path/to/artifact.tar.gz" >&2
    exit 1
  fi
  artifact="${matches[0]}"
fi
[[ -f "$artifact" ]] || { echo "error: artifact is not a regular file: $artifact" >&2; exit 1; }

# --- sha256 contract: must match the MODULE.bazel pin (skip with SKIP_SHA_CHECK=1) ---
actual_sha256="$(sha256sum "$artifact" | awk '{print $1}')"
if [[ "$SKIP_SHA_CHECK" != "1" && "$actual_sha256" != "$EXPECTED_SHA256" ]]; then
  echo "error: sha256 mismatch for $artifact" >&2
  echo "       expected: $EXPECTED_SHA256" >&2
  echo "       actual:   $actual_sha256" >&2
  echo "       set EXPECTED_SHA256 to the new hash, or SKIP_SHA_CHECK=1 to bypass" >&2
  exit 1
fi
[[ "$SKIP_SHA_CHECK" == "1" ]] && sha_note="(contract skipped)" || sha_note="(matches pin)"
echo "==> sha256: $actual_sha256 $sha_note"

# --- guard: valid AWS credentials (fail loud before any upload) ---
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "error: 'aws sts get-caller-identity' failed; run 'aws configure'." >&2
  exit 1
fi

# --- upload: no ACL modification (objects get the bucket's default private ACL; the IP-scoped bucket policy from scripts/bucket-cidr-policy.sh is the only access gate); region from $AWS_REGION ---
s3_key="${S3_KEY_PREFIX}/$(basename "$artifact")"
aws s3 cp "$artifact" "s3://${S3_BUCKET_NAME}/${s3_key}" --region "$AWS_REGION"

# --- done: public URL in the path-style form MODULE.bazel uses ---
public_url="https://s3.${AWS_REGION}.amazonaws.com/${S3_BUCKET_NAME}/${s3_key}"
echo "==> done: $public_url"
echo "==> sha256: $actual_sha256"
