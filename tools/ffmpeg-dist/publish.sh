#!/usr/bin/env bash
# =============================================================================
# tools/ffmpeg-dist/publish.sh -- build, checksum, upload, and print the
# MODULE.bazel stanza for the pinned FFmpeg artifact.
#
# Builds tools/ffmpeg-dist/Dockerfile (docker if present, else buildctl),
# extracts the /out payload, tars it as
#   ffmpeg-<FFMPEG_VERSION>-deb<YYYYMMDD>-cuda<X.Y.Z>-sm<N>-<shortsha>.tar.gz
# (written into the current directory), uploads it to
# $S3_BUCKET/ffmpeg/ with --acl public-read, then prints the http_archive
# block to paste into MODULE.bazel (name = "ffmpeg_dist").
#
# Env vars (defaults mirror the Dockerfile ARGs):
#   FFMPEG_VERSION      default 8.0
#   FFMPEG_COMMIT       default 281c902aa1a83fe759011097cb005b555034c151
#   NV_CODEC_HEADERS_TAG default n13.0.19.0
#   NV_CODEC_HEADERS_COMMIT default e844e5b26f46bb77479f063029595293aa8f812d
#   CUDA_MANIFEST_URL   default .../redistrib_13.0.2.json
#   DEBIAN_SNAPSHOT     default 20260824T082821Z
#   CUDA_COMPONENTS     default "cuda_nvcc cuda_cudart cuda_crt libnvvm"
#   GENCODE             default arch=compute_75,code=sm_75
#   NPROC               default 8
#   S3_BUCKET           default s3://<bucket-name>  (same placeholder as the root Makefile)
#   AWS_REGION          default us-east-1
#   GITHUB_REPOSITORY   owner/repo; when set, a GitHub Release mirror URL is
#                       added to the stanza's urls list.
#   SKIP_UPLOAD         default unset; 1 = build + checksum only, print the
#                       stanza with a SKIP_UPLOAD note, exit 0 (used by the
#                       reproducibility canary, which only compares sha256s).
#
# If AWS credentials are missing the upload is skipped (loudly, exit 1) but the
# stanza is still printed, so the artifact can be published later.
# =============================================================================
set -euo pipefail

# --- inputs (defaults mirror the Dockerfile ARGs) ---
FFMPEG_VERSION="${FFMPEG_VERSION:-8.0}"
FFMPEG_COMMIT="${FFMPEG_COMMIT:-281c902aa1a83fe759011097cb005b555034c151}"
NV_CODEC_HEADERS_TAG="${NV_CODEC_HEADERS_TAG:-n13.0.19.0}"
NV_CODEC_HEADERS_COMMIT="${NV_CODEC_HEADERS_COMMIT:-e844e5b26f46bb77479f063029595293aa8f812d}"
CUDA_MANIFEST_URL="${CUDA_MANIFEST_URL:-https://developer.download.nvidia.com/compute/cuda/redist/redistrib_13.0.2.json}"
DEBIAN_SNAPSHOT="${DEBIAN_SNAPSHOT:-20260824T082821Z}"
CUDA_COMPONENTS="${CUDA_COMPONENTS:-cuda_nvcc cuda_cudart cuda_crt libnvvm}"
GENCODE="${GENCODE:-arch=compute_75,code=sm_75}"
NPROC="${NPROC:-8}"
S3_BUCKET="${S3_BUCKET:-s3://<bucket-name>}"
AWS_REGION="${AWS_REGION:-us-east-1}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
SKIP_UPLOAD="${SKIP_UPLOAD:-}"

# --- guard clauses: refuse to build with a malformed pin ---
if [[ ! "$FFMPEG_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: FFMPEG_COMMIT must be a 40-character git SHA, got '$FFMPEG_COMMIT'" >&2
  exit 1
fi

# --- derive the artifact name from the pins (single source of truth) ---
cuda_version="$(basename "$CUDA_MANIFEST_URL" | sed -E 's/^redistrib_([0-9.]+)\.json$/\1/')"
deb_date="${DEBIAN_SNAPSHOT%%T*}"
sm_suffix="$(printf '%s' "$GENCODE" | sed -E 's/.*code=(sm_[0-9]+).*/\1/' | tr -d '_')"
if [[ ! "$cuda_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: cannot derive the CUDA version from CUDA_MANIFEST_URL='$CUDA_MANIFEST_URL'" >&2
  exit 1
fi
if [[ ! "$deb_date" =~ ^[0-9]{8}$ ]]; then
  echo "error: cannot derive the Debian date from DEBIAN_SNAPSHOT='$DEBIAN_SNAPSHOT'" >&2
  exit 1
fi
if [[ ! "$sm_suffix" =~ ^sm[0-9]+$ ]]; then
  echo "error: cannot derive the sm target from GENCODE='$GENCODE' (expected e.g. 'arch=compute_75,code=sm_75')" >&2
  exit 1
fi
artifact="ffmpeg-${FFMPEG_VERSION}-deb${deb_date}-cuda${cuda_version}-${sm_suffix}-${FFMPEG_COMMIT:0:7}.tar.gz"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/out" "$work/rootfs"

# --- builder detection: docker preferred, buildctl fallback ---
if command -v docker >/dev/null 2>&1; then
  builder="docker"
elif command -v buildctl >/dev/null 2>&1; then
  builder="buildctl"
else
  echo "error: neither docker nor buildctl found on PATH" >&2
  exit 1
fi

common_build_args=(
  "FFMPEG_VERSION=$FFMPEG_VERSION"
  "FFMPEG_COMMIT=$FFMPEG_COMMIT"
  "NV_CODEC_HEADERS_TAG=$NV_CODEC_HEADERS_TAG"
  "NV_CODEC_HEADERS_COMMIT=$NV_CODEC_HEADERS_COMMIT"
  "CUDA_MANIFEST_URL=$CUDA_MANIFEST_URL"
  "DEBIAN_SNAPSHOT=$DEBIAN_SNAPSHOT"
  "CUDA_COMPONENTS=$CUDA_COMPONENTS"
  "GENCODE=$GENCODE"
  "NPROC=$NPROC"
)

# The artifact is always linux/amd64 (matches .bazelrc's
# --platforms=//tools/bazel:linux_amd64), so on arm64 hosts this is a
# cross-arch build through QEMU -- expected, and slow.
echo "==> building $artifact (linux/amd64) with $builder"

if [[ "$builder" == "docker" ]]; then
  docker_build_args=()
  for arg in "${common_build_args[@]}"; do docker_build_args+=(--build-arg "$arg"); done
  docker build --platform linux/amd64 --progress plain \
    -f "$repo_root/tools/ffmpeg-dist/Dockerfile" \
    --target out \
    "${docker_build_args[@]}" \
    -t "ffmpeg-dist:$artifact" \
    "$repo_root"
  # the out stage is FROM scratch (no CMD); a dummy command satisfies docker
  # create's "No command specified" validation -- nothing is ever executed.
  container="$(docker create "ffmpeg-dist:$artifact" /bin/true)"
  docker cp "$container:/out/." "$work/out/"
  docker rm "$container" >/dev/null
else
  buildctl_build_args=()
  for arg in "${common_build_args[@]}"; do buildctl_build_args+=(--opt "build-arg:$arg"); done
  buildctl build --progress=plain \
    --frontend dockerfile.v0 \
    --local context="$repo_root" \
    --local dockerfile="$repo_root" \
    --opt filename=tools/ffmpeg-dist/Dockerfile \
    --opt platform=linux/amd64 \
    --opt target=out \
    "${buildctl_build_args[@]}" \
    --output type=local,dest="$work/rootfs"
  cp -a "$work/rootfs/out/." "$work/out/"
fi

if [[ ! -f "$work/out/ffmpeg" || ! -f "$work/out/BUILD-INFO.txt" ]]; then
  echo "error: build produced no /out/ffmpeg or /out/BUILD-INFO.txt" >&2
  exit 1
fi

# --- checksum + tar (deterministic member order; PAX atime/ctime stripped) ---
tar --format=posix --sort=name --mtime=@0 --pax-option=delete=atime,delete=ctime --owner=0 --group=0 --numeric-owner \
  -cf - -C "$work/out" ffmpeg BUILD-INFO.txt \
  | gzip -n > "$artifact"
sha256="$(sha256sum "$artifact" | awk '{print $1}')"
echo "==> artifact: $artifact"
echo "==> sha256:   $sha256"

# --- upload (skip loudly when AWS creds are missing, or by SKIP_UPLOAD=1) ---
if [[ "$SKIP_UPLOAD" == "1" ]]; then
  echo "==> SKIP_UPLOAD=1: skipping upload; artifact remains local."
  upload_ok=0
elif ! aws --region "$AWS_REGION" sts get-caller-identity >/dev/null 2>&1; then
  echo "!! AWS credentials not found (aws sts get-caller-identity failed)." >&2
  echo "!! Skipping upload; $artifact remains local." >&2
  echo "!! Re-run with valid credentials to publish, or upload manually:" >&2
  echo "!!   aws --region $AWS_REGION s3 cp --acl public-read $artifact $S3_BUCKET/ffmpeg/$artifact" >&2
  upload_ok=0
else
  aws --region "$AWS_REGION" s3 cp --acl public-read "$artifact" "$S3_BUCKET/ffmpeg/$artifact"
  upload_ok=1
fi

# --- MODULE.bazel stanza ---
bucket="${S3_BUCKET#s3://}"
s3_url="https://${bucket}.s3.${AWS_REGION}.amazonaws.com/ffmpeg/${artifact}"
if [[ -n "$GITHUB_REPOSITORY" ]]; then
  mirror_url="https://github.com/${GITHUB_REPOSITORY}/releases/download/ffmpeg-artifacts/${artifact}"
fi

printf '\n# --- MODULE.bazel: paste this block into MODULE.bazel ---\n'
printf 'http_archive(\n'
printf '    name = "ffmpeg_dist",\n'
if [[ -n "$GITHUB_REPOSITORY" ]]; then
  printf '    urls = [\n'
  printf '        "%s",\n' "$s3_url"
  printf '        "%s",\n' "$mirror_url"
  printf '    ],\n'
else
  printf '    url = "%s",\n' "$s3_url"
fi
printf '    sha256 = "%s",\n' "$sha256"
printf '    build_file_content = "exports_files([\\"ffmpeg\\", \\"BUILD-INFO.txt\\"])",\n'
printf ')\n'
if [[ "$upload_ok" == 0 ]]; then
  if [[ "$SKIP_UPLOAD" == "1" ]]; then
    printf '# NOTE: upload skipped (SKIP_UPLOAD=1).\n'
  else
    printf '# NOTE: upload skipped (AWS credentials missing); artifact is local only.\n'
  fi
fi

# exit non-zero when the upload was skipped so callers know publish didn't finish;
# SKIP_UPLOAD=1 (the reproducibility canary) treats a successful local build as success.
if [[ "$SKIP_UPLOAD" != "1" ]]; then
  [[ "$upload_ok" == 1 ]]
fi