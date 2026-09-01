#!/usr/bin/env bash
# =============================================================================
# tools/brb-screen/publish.sh -- two-phase publish for the offline fallback
# segment: generate on macOS, upload on a Linux host with AWS credentials.
#
# The clip (2160p60 HEVC/AAC MP4) is encoded with the macOS-only
# hevc_videotoolbox + aac_at FFmpeg codecs (VideoToolbox/AudioToolbox), so it
# cannot be built inside the Bazel graph -- it is produced out-of-band on a
# Mac, uploaded to S3, and fetched by MODULE.bazel's
# s3_http_file(name = "offline_segment_dist"), mirroring the @ffmpeg_dist
# pattern. Generation and upload are deliberately decoupled:
#
#   Phase 1 (macOS):   ./publish.sh generate
#                      encodes the clip and prints its sha256; no AWS needed.
#   Phase 2 (Linux):   copy the clip to the Linux host (e.g. scp) and run
#                      ./publish.sh upload <path> there, where AWS credentials
#                      are configured; it checksums, uploads to S3, and prints
#                      the MODULE.bazel s3_http_file stanza.
#   Combined:          ./publish.sh
#                      generate then upload in one flow (macOS with AWS creds;
#                      the original single-machine behavior).
#
# The mp4 is uploaded to $S3_BUCKET/offline/ with no ACL modification
# (objects get the bucket's default private ACL; the IP-scoped HTTPS-only
# bucket policy from scripts/bucket-cidr-policy.sh is the only access gate), then the
# s3_http_file block is printed for MODULE.bazel (name = "offline_segment_dist")
# along with the `gh release upload` command for the GitHub Release mirror.
#
# Env vars:
#   OUTPUT_PATH   default ~/Downloads/strimserver-offline-2160p60.mp4
#                 (generate2160p writes there; if you override OUTPUT_PATH,
#                 move the produced clip yourself before upload/checksum)
#   S3_BUCKET     required for upload (e.g. s3://<bucket-name>; same placeholder as the root Makefile)
#   AWS_REGION    required for upload (no default)
#   GITHUB_REPOSITORY default ChronicCmposer/strimserver; owner/repo used for
#                 the GitHub Release mirror URL
#   BUILD_HOST_USER / BUILD_HOST  default user / host; used only in the printed
#                 scp hint (no real hostname is baked in)
#   SKIP_UPLOAD   default unset; 1 = checksum only, print the stanza with a
#                 SKIP_UPLOAD note, exit 0.
#
# Generation requires macOS (VideoToolbox/AudioToolbox); upload requires
# working AWS credentials. If AWS credentials are missing the upload is
# skipped (loudly, exit 1) but the stanza is still printed, so the artifact
# can be published later.
# =============================================================================
set -euo pipefail

# --- inputs (defaults) ---
OUTPUT_PATH="${OUTPUT_PATH:-$HOME/Downloads/strimserver-offline-2160p60.mp4}"
S3_BUCKET="${S3_BUCKET:-s3://<bucket-name>}"
AWS_REGION="${AWS_REGION:-}"
SKIP_UPLOAD="${SKIP_UPLOAD:-}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- shared helpers ----------------------------------------------------------

print_usage() {
  echo "usage: tools/brb-screen/publish.sh [generate|upload [PATH]]" >&2
  echo "  generate         encode the offline clip on macOS (hevc_videotoolbox +" >&2
  echo "                   aac_at); prints the sha256, does not upload." >&2
  echo "  upload [PATH]    checksum + upload a clip to S3 from a Linux host with" >&2
  echo "                   AWS credentials; PATH defaults to OUTPUT_PATH." >&2
  echo "  (no subcommand)  generate then upload (macOS with AWS credentials)." >&2
}

# Guard: generation requires macOS (hevc_videotoolbox + aac_at) and ffmpeg.
require_macos_ffmpeg() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: tools/brb-screen/publish.sh generation must run on macOS; the" >&2
    echo "       offline clip uses hevc_videotoolbox + aac_at, which exist only" >&2
    echo "       in FFmpeg builds with VideoToolbox/AudioToolbox support." >&2
    echo "       to publish an existing clip from a Linux host, run:" >&2
    echo "         tools/brb-screen/publish.sh upload <clip-path>" >&2
    exit 1
  fi
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "error: 'ffmpeg' (with hevc_videotoolbox + aac_at) not found on PATH." >&2
    echo "       install an FFmpeg build with VideoToolbox/AudioToolbox support" >&2
    echo "       (e.g. 'brew install ffmpeg')." >&2
    exit 1
  fi
}

# Print the sha256 of a clip file (shasum -a 256 is native on macOS).
clip_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

# Upload a clip to S3. Prints progress/error messages; returns 0 on success,
# 1 when the upload was skipped (SKIP_UPLOAD=1, no aws CLI, or no creds);
# exits 1 when AWS_REGION is unset (a config error, not a skip).
upload_clip() {
  local clip="$1"

  if [[ "$SKIP_UPLOAD" == "1" ]]; then
    echo "==> SKIP_UPLOAD=1: skipping upload; clip remains local."
    return 1
  fi
  if ! command -v aws >/dev/null 2>&1; then
    echo "error: 'aws' (awscli) not found; install it and run 'aws configure'." >&2
    return 1
  fi
  if [[ -z "$AWS_REGION" ]]; then
    echo "error: AWS_REGION is required for upload (no default)." >&2
    exit 1
  fi
  if ! aws --region "$AWS_REGION" sts get-caller-identity >/dev/null 2>&1; then
    echo "!! AWS credentials not found (aws sts get-caller-identity failed)." >&2
    echo "!! Skipping upload; $clip remains local." >&2
    echo "!! Re-run with valid credentials to publish, or upload manually:" >&2
    echo "!!   aws --region $AWS_REGION s3 cp $clip $S3_BUCKET/offline/strimserver-offline-2160p60.mp4" >&2
    return 1
  fi

  echo "==> uploading to $S3_BUCKET/offline/ (no ACL modification; the bucket policy gates access)"
  aws --region "$AWS_REGION" s3 cp "$clip" "$S3_BUCKET/offline/strimserver-offline-2160p60.mp4"
}

# Print the MODULE.bazel s3_http_file stanza for a clip and its sha256, plus
# the gh release upload command for the GitHub Release mirror. $3 is a human
# skip reason (empty when the upload succeeded).
print_publish_stanza() {
  local clip="$1"
  local sha256="$2"
  local skip_note="$3"

  local mirror_url="https://github.com/${GITHUB_REPOSITORY:-ChronicCmposer/strimserver}/releases/download/offline-segment/strimserver-offline-2160p60.mp4"

  printf '\n# --- MODULE.bazel: paste this s3_http_file block into MODULE.bazel ---\n'
  printf 's3_http_file(\n'
  printf '    name = "offline_segment_dist",\n'
  printf '    s3_key = "offline/strimserver-offline-2160p60.mp4",\n'
  printf '    sha256 = "%s",\n' "$sha256"
  printf '    mirror_urls = ["%s"],\n' "$mirror_url"
  printf '    downloaded_file_name = "strimserver-offline-2160p60.mp4",\n'
  printf ')\n'
  if [[ -n "$skip_note" ]]; then
    printf '# NOTE: upload skipped (%s).\n' "$skip_note"
  fi

  printf '\n# --- GitHub Release mirror (upload the same clip to the offline-segment release) ---\n'
  printf 'gh release upload offline-segment %s\n' "$clip"
}

# --- modes ------------------------------------------------------------------

# generate: macOS-only encode; checksum only, no upload, no AWS required.
generate_mode() {
  require_macos_ffmpeg

  # shellcheck source=bslib.sh
  source "$script_dir/bslib.sh"
  echo "==> generating the offline fallback clip (2160p60 HEVC/AAC) via generate2160p ..."
  generate2160p
  if [[ ! -f "$OUTPUT_PATH" ]]; then
    echo "error: generate2160p did not produce $OUTPUT_PATH." >&2
    echo "       generate2160p writes to ~/Downloads/strimserver-offline-2160p60.mp4;" >&2
    echo "       move the clip to OUTPUT_PATH, or set OUTPUT_PATH to that location." >&2
    exit 1
  fi

  local sha256
  sha256="$(clip_sha256 "$OUTPUT_PATH")"
  echo "==> artifact: $OUTPUT_PATH"
  echo "==> sha256:   $sha256"
  echo "==> generation complete; upload is a separate phase. Copy the clip to"
  echo "    the Linux host with AWS credentials, e.g.:"
  echo "      scp $OUTPUT_PATH ${BUILD_HOST_USER:-user}@${BUILD_HOST:-host}:/tmp/strimserver-offline-2160p60.mp4"
  echo "    then run there:"
  echo "      tools/brb-screen/publish.sh upload /tmp/strimserver-offline-2160p60.mp4"
}

# upload: checksum + S3 publish of an existing clip (any OS; intended for a
# Linux host with AWS credentials).
upload_mode() {
  local clip="${1:-$OUTPUT_PATH}"
  if [[ ! -f "$clip" ]]; then
    echo "error: clip not found: $clip" >&2
    echo "       pass the clip path as an argument, or set OUTPUT_PATH." >&2
    exit 1
  fi

  local sha256
  sha256="$(clip_sha256 "$clip")"
  echo "==> artifact: $clip"
  echo "==> sha256:   $sha256"

  local upload_ok=0
  if upload_clip "$clip"; then
    upload_ok=1
  fi

  local skip_note=""
  if [[ "$upload_ok" == "0" ]]; then
    if [[ "$SKIP_UPLOAD" == "1" ]]; then
      skip_note="SKIP_UPLOAD=1"
    else
      skip_note="AWS credentials missing; clip is local only"
    fi
  fi

  print_publish_stanza "$clip" "$sha256" "$skip_note"

  # exit non-zero when the upload was skipped so callers know publish didn't
  # finish; SKIP_UPLOAD=1 treats a successful local checksum as success.
  if [[ "$SKIP_UPLOAD" != "1" ]]; then
    [[ "$upload_ok" == 1 ]]
  fi
}

# --- dispatch ----------------------------------------------------------------
case "${1:-}" in
  generate)
    generate_mode
    ;;
  upload)
    upload_mode "${2:-$OUTPUT_PATH}"
    ;;
  "")
    generate_mode
    upload_mode "$OUTPUT_PATH"
    ;;
  *)
    print_usage
    exit 1
    ;;
esac