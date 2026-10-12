#!/usr/bin/env bash
# =============================================================================
# tools/ffmpeg-dist/check-deps.sh -- pre-flight dependency check for
# tools/ffmpeg-dist/publish.sh (build + upload the pinned FFmpeg artifact).
#
# Sweeps every required CLI tool in ONE pass and reports ALL missing ones
# (no set -e: we collect everything, then fail at the end). When an upload is
# planned (SKIP_UPLOAD unset/empty), also gates on AWS_REGION, valid AWS
# credentials, and a real S3_BUCKET. Version-pin validation is NOT done here;
# publish.sh owns that. On non-x86_64 hosts a qemu self-heal notice is printed
# (informational only, never gating).
# =============================================================================
set -uo pipefail

# --- project-scoped operator profile (decision 11b) ---------------------------
# The aws-profile contract (pin [strimserver], reject other identities) lives in
# ONE shared library so no call site re-implements it. Find the repo root the
# same way the Go tooling does: BUILD_WORKSPACE_DIRECTORY when `bazel run` set
# it, otherwise walk up from this script's directory.
_ss_root="${BUILD_WORKSPACE_DIRECTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
while [[ ! -f "$_ss_root/deploy/aws/lib/aws_profile.sh" && "$_ss_root" != "/" ]]; do
  _ss_root="$(dirname "$_ss_root")"
done
. "$_ss_root/deploy/aws/lib/aws_profile.sh"
unset _ss_root
# ------------------------------------------------------------------------------

# --- dependency sweep (aggregate): every missing tool, one pass, fail at end --
required_tools=(curl jq tar gzip sha256sum awk sed grep tr file strings uname mktemp nproc sudo aws)
missing=()
for tool in "${required_tools[@]}"; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done

failed=0
if [[ ${#missing[@]} -gt 0 ]]; then
  failed=1
  echo "error: missing required tools for ffmpeg-dist publish:" >&2
  echo "       ${missing[*]}" >&2
  echo "       Install them with:" >&2
  echo "         apt-get install -y ${missing[*]}" >&2
  echo "       macOS users: install the equivalents with Homebrew (brew install ...)." >&2
fi

# --- upload gates: only when an upload is planned (SKIP_UPLOAD=1 skips them) --
if [[ -z "${SKIP_UPLOAD:-}" ]]; then
  if [[ -z "${AWS_REGION:-}" ]]; then
    failed=1
    echo "error: AWS_REGION is required for upload (no default)." >&2
    echo "       Set it (e.g. AWS_REGION=us-east-1) or run with SKIP_UPLOAD=1." >&2
  fi
  # A missing aws binary is already reported by the sweep; verify the pinned
  # strimserver identity only when aws exists and AWS_REGION is set.
  if command -v aws >/dev/null 2>&1 && [[ -n "${AWS_REGION:-}" ]]; then
    require_strimserver_identity || failed=1
  fi
  # Make's '?=' default (s3://<bucket-name>) is not exported to recipe shells,
  # so unset here == user never set it == the placeholder.
  if [[ -z "${S3_BUCKET:-}" || "$S3_BUCKET" == "s3://<bucket-name>" ]]; then
    failed=1
    echo "error: S3_BUCKET is required for upload; set S3_BUCKET to your real bucket" >&2
    echo "       (e.g. S3_BUCKET=s3://your-bucket-name) or run with SKIP_UPLOAD=1." >&2
  fi
fi

# --- qemu notice (informational, never gating) -------------------------------
host_arch="$(uname -m 2>/dev/null)"
if [[ -n "$host_arch" && "$host_arch" != "x86_64" ]]; then
  echo "==> note: host arch is '$host_arch' (not x86_64); publish.sh will self-heal"
  echo "       the patched qemu-x86_64 via tools/qemu/build-qemu.sh."
fi

# --- verdict ------------------------------------------------------------------
if [[ "$failed" == 0 ]]; then
  printf '\033[32m==> ffmpeg-dist publish dependencies OK.\033[0m\n'
fi
exit "$failed"
