#!/usr/bin/env bash
# =============================================================================
# tools/ffmpeg-dist/publish.sh -- build, checksum, upload, and print the
# MODULE.bazel stanza for the pinned FFmpeg artifact.
#
# qemu-direct flow (no docker): the script pulls the pinned
# debian:trixie-<date>-slim base image via the Docker Hub registry API (plain
# curl+jq -- no docker daemon), extracts it into a rootfs, copies the shared
# build script (tools/ffmpeg-dist/build.sh) in, and runs it inside a chroot --
# invoking the patched qemu-x86_64 explicitly for the amd64 guest when the
# host is not x86_64. The build itself is the shared build.sh, the same single
# source of truth for the pinned artifact.
#
# The resulting /out payload (ffmpeg + BUILD-INFO.txt) is tared as
#   ffmpeg-<FFMPEG_VERSION>-deb<YYYYMMDD>-cuda<X.Y.Z>-sm<N>-<shortsha>.tar.gz
# (written into the current directory), uploaded to $S3_BUCKET/ffmpeg/ with
# no ACL modification (objects get the bucket's default private ACL; the
# IP-scoped HTTPS-only bucket policy from scripts/bucket-cidr-policy.sh is the only
# access gate), then the s3_http_archive block is printed for MODULE.bazel
# (name = "ffmpeg_dist").
#
# Env vars (defaults mirror the build.sh pins):
#   FFMPEG_VERSION       default 8.1
#   FFMPEG_COMMIT        default 1a748fe2cd43e3ead22fafb1b5b7d77f153898a8
#   NV_CODEC_HEADERS_TAG default n13.0.19.1
#   NV_CODEC_HEADERS_COMMIT default 88fee5c37318c991a8762d423530f91681e32e3a
#   CUDA_MANIFEST_URL    default .../redistrib_13.2.2.json
#   DEBIAN_SNAPSHOT      default 20260824T082821Z
#   CUDA_COMPONENTS      default "cuda_nvcc cuda_cudart cuda_crt libnvvm"
#   GENCODE              default arch=compute_75,code=sm_75
#   NPROC                host nproc (env-overridable)
#   QEMU_VERSION         default 8.2.2 (this consumer's qemu pin, the
#                        byte-identity pin: a different qemu exposes different
#                        guest CPUID leaves, which changes codegen and so the
#                        ffmpeg artifact). Passed to tools/qemu/build-qemu.sh
#                        on self-heal; the version-stamped cache keeps it
#                        separate from openssh-dist's 9.2.4 pin.
#   QEMU_BIN             default: unset. Explicit override for the patched qemu
#                        used on non-x86_64 hosts; must be a
#                        buildkit-direct-execve patched qemu (verified via the
#                        'safe_execve' marker), otherwise it is ignored with a
#                        warning. Resolution order: QEMU_BIN (validated) >
#                        cached patched qemu (re-validated) > self-heal source
#                        build via tools/qemu/build-qemu.sh. amd64 hosts
#                        run the guest natively with no qemu at all.
#   FFMPEG_DIST_ROOTFS   default unset; when set to an already-extracted rootfs
#                        the Docker Hub registry pull is skipped entirely.
#   S3_BUCKET            required for upload (e.g. s3://<bucket-name>; SKIP_UPLOAD=1 works without it)
#   AWS_REGION           required for upload (no default; SKIP_UPLOAD=1 works without it)
#   GITHUB_REPOSITORY    owner/repo; default ChronicCmposer/strimserver; used for
#                        the GitHub Release mirror URL in the stanza's mirror_urls.
#   SKIP_UPLOAD          default unset; 1 = build + checksum only, print the
#                        stanza with a SKIP_UPLOAD note, exit 0 (used by the
#                        reproducibility canary, which only compares sha256s).
#
# If AWS credentials are missing the upload is skipped (loudly, exit 1) but the
# stanza is still printed, so the artifact can be published later.
# =============================================================================
set -euo pipefail

# --- inputs (defaults mirror the build.sh pins) ---
FFMPEG_VERSION="${FFMPEG_VERSION:-8.1}"
FFMPEG_COMMIT="${FFMPEG_COMMIT:-1a748fe2cd43e3ead22fafb1b5b7d77f153898a8}"
NV_CODEC_HEADERS_TAG="${NV_CODEC_HEADERS_TAG:-n13.0.19.1}"
NV_CODEC_HEADERS_COMMIT="${NV_CODEC_HEADERS_COMMIT:-88fee5c37318c991a8762d423530f91681e32e3a}"
CUDA_MANIFEST_URL="${CUDA_MANIFEST_URL:-https://developer.download.nvidia.com/compute/cuda/redist/redistrib_13.2.2.json}"
DEBIAN_SNAPSHOT="${DEBIAN_SNAPSHOT:-20260824T082821Z}"
CUDA_COMPONENTS="${CUDA_COMPONENTS:-cuda_nvcc cuda_cudart cuda_crt libnvvm}"
GENCODE="${GENCODE:-arch=compute_75,code=sm_75}"
NPROC="${NPROC:-$(nproc)}"
S3_BUCKET="${S3_BUCKET:-s3://<bucket-name>}"
AWS_REGION="${AWS_REGION:-}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
SKIP_UPLOAD="${SKIP_UPLOAD:-}"
QEMU_BIN="${QEMU_BIN:-}"
QEMU_VERSION="${QEMU_VERSION:-8.2.2}"
FFMPEG_DIST_ROOTFS="${FFMPEG_DIST_ROOTFS:-}"

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
# The privileged chroot harness bind-mounts the host's device nodes into
# $work/rootfs/dev, so cleanup cannot remove the busy mounts; without the guard
# that floods the log with 'Device or resource busy' lines and hides the real error.
trap 'rm -rf "$work" 2>/dev/null || true' EXIT
mkdir -p "$work/out"

host_arch="$(uname -m)"
# This consumer pins qemu 8.2.2 (openssh-dist pins 9.2.4) and uses a
# version-stamped cache (tools/qemu/build-qemu.sh), so the two artifact
# pipelines never share a qemu binary.
qemu_cache_path="${XDG_CACHE_HOME:-$HOME/.cache}/ffmpeg-dist/qemu-x86_64-patched-${QEMU_VERSION}"

# --- resolve the qemu emulator (only needed on non-x86_64 hosts) ---
# qemu_is_patched <path> -- true iff <path> is a usable buildkit-direct-execve
# patched qemu: non-empty and executable, statically linked ELF ('file' matches
# static-pie / statically linked), carries the 'safe_execve' marker, and runs
# (--version exits 0). Same checks as tools/qemu/build-qemu.sh.
qemu_is_patched() {
  local path="$1"
  [[ -n "$path" ]] || return 1
  [[ -x "$path" ]] || return 1
  # NB: no grep -q in these pipelines -- under `set -o pipefail` grep -q exits
  # early on a match, strings/file die with SIGPIPE (141), and the pipeline
  # reports failure despite the match. grep reads all input instead.
  file "$path" | grep -iE 'static' >/dev/null || return 1
  strings "$path" | grep safe_execve >/dev/null || return 1
  "$path" --version >/dev/null 2>&1 || return 1
  return 0
}

# qemu_reported_version <path> -- prints the numeric version string reported by
# <path>'s --version (e.g. "8.2.2"), or empty when the binary cannot report one.
# Reads all of --version's output (no grep -q, which under `set -o pipefail`
# SIGPIPEs the producer on an early exit and makes the pipeline fail).
qemu_reported_version() {
  local path="$1"
  "$path" --version 2>/dev/null | sed -n '1s/.*version \([0-9][0-9.]*\).*/\1/p'
}

# resolve_qemu -- sets $qemu to a working patched qemu-x86_64 absolute path.
# Priority: QEMU_BIN override (validated + version-gated) > cached patched qemu
# (re-validated + version-gated) > self-heal source build via
# tools/qemu/build-qemu.sh > loud error. The version gate protects the
# byte-identity contract: a stale cache built against a different qemu pin
# (e.g. a 9.2.4 cache when ffmpeg-dist pins 8.2.2) still passes the
# static/safe_execve/runs checks, but a different qemu exposes different guest
# CPUID leaves, which changes the guest toolchain's codegen and therefore the
# final artifact -- so any cached qemu whose reported version differs from the
# pinned QEMU_VERSION is treated as invalid and rebuilt.
resolve_qemu() {
  local qemu_version="$QEMU_VERSION" reported_version
  if [[ -n "$QEMU_BIN" ]]; then
    if qemu_is_patched "$QEMU_BIN"; then
      reported_version="$(qemu_reported_version "$QEMU_BIN")"
      if [[ "$reported_version" == "$qemu_version" ]]; then
        qemu="$(readlink -m "$QEMU_BIN")"
        return 0
      fi
      echo "==> warning: QEMU_BIN=$QEMU_BIN is a patched qemu but reports qemu ${reported_version}; the pinned artifact requires qemu ${qemu_version}; ignoring it" >&2
    else
      echo "==> warning: QEMU_BIN=$QEMU_BIN is not a buildkit-direct-execve patched qemu (no 'safe_execve' marker); ignoring it" >&2
    fi
  fi
  if qemu_is_patched "$qemu_cache_path"; then
    reported_version="$(qemu_reported_version "$qemu_cache_path")"
    if [[ "$reported_version" == "$qemu_version" ]]; then
      qemu="$qemu_cache_path"
      return 0
    fi
    echo "==> warning: cached qemu ($qemu_cache_path) is patched but reports qemu ${reported_version}; the pinned artifact requires qemu ${qemu_version}; rebuilding it" >&2
  fi
  echo "==> building patched qemu-x86_64 from source (qemu-${qemu_version}) ..."
  if QEMU_VERSION="$QEMU_VERSION" "$repo_root/tools/qemu/build-qemu.sh" && qemu_is_patched "$qemu_cache_path"; then
    qemu="$qemu_cache_path"
    return 0
  fi
  echo "error: no usable buildkit-direct-execve patched qemu-x86_64 was found." >&2
  echo "       The self-heal source build failed; it needs host build deps:" >&2
  echo "         apt-get install -y meson ninja-build python3 pkg-config gcc libglib2.0-dev" >&2
  echo "       or provide the known-good binary via" >&2
  echo "       QEMU_BIN=/var/tmp/ffmpeg-build/qemu-x86_64-patched" >&2
  exit 1
}

if [[ "$host_arch" != "x86_64" ]]; then
  qemu=""
  if ! resolve_qemu || ! "$qemu" --version >/dev/null 2>&1; then
    echo "error: host arch is '$host_arch' (not x86_64) and no usable qemu-x86_64 was found." >&2
    echo "       publish.sh runs natively on amd64 hosts with no qemu at all." >&2
    echo "       arm64 hosts need the tonistiigi buildkit-direct-execve patched qemu" >&2
    echo "       (upstream qemu cannot intercept the guest's execve and the" >&2
    echo "       buildkit-bundled qemu segfaults on NVIDIA's cicc)." >&2
    echo "       publish.sh self-heals by building it from source (build-qemu.sh);" >&2
    echo "       that needs host deps: apt-get install -y meson ninja-build" >&2
    echo "       python3 pkg-config gcc libglib2.0-dev, or point QEMU_BIN at a" >&2
    echo "       known-good binary: QEMU_BIN=/var/tmp/ffmpeg-build/qemu-x86_64-patched." >&2
    exit 1
  fi
  QEMU_BIN="$qemu"
  echo "==> qemu: $QEMU_BIN"
fi

# --- rootfs provisioning: pull the pinned base image via the registry API ---
# provision_rootfs <rootfs> <tag> -- pulls the <tag> manifest list from the
# Docker Hub registry (plain curl+jq), selects the linux/amd64 image, and
# extracts its layers into <rootfs>. Returns non-zero on any failure; the
# caller prints the loud error with the FFMPEG_DIST_ROOTFS fallback hint.
provision_rootfs() {
  local rootfs="$1" tag="$2" token manifest_list amd64_digest manifest layer_digests layer_digest
  token="$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/debian:pull" | jq -r '.token')" \
    || return 1
  manifest_list="$(curl -fsSL \
      -H "Authorization: Bearer $token" \
      -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.index.v1+json' \
      "https://registry-1.docker.io/v2/library/debian/manifests/$tag" \
    | jq -c .)" \
    || return 1
  amd64_digest="$(printf '%s' "$manifest_list" | jq -r '.manifests[] | select(.platform.os=="linux" and .platform.architecture=="amd64") | .digest')" \
    || return 1
  [[ -n "$amd64_digest" ]] || return 1
  manifest="$(curl -fsSL \
      -H "Authorization: Bearer $token" \
      -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
      "https://registry-1.docker.io/v2/library/debian/manifests/$amd64_digest" \
    | jq -c .)" \
    || return 1
  layer_digests="$(printf '%s' "$manifest" | jq -r '.layers[].digest')" \
    || return 1
  [[ -n "$layer_digests" ]] || return 1
  mkdir -p "$rootfs"
  for layer_digest in $layer_digests; do
    curl -fsSL -H "Authorization: Bearer $token" \
      "https://registry-1.docker.io/v2/library/debian/blobs/$layer_digest" \
      | tar -xzf - -C "$rootfs" \
      || return 1
  done
  return 0
}

rootfs="${FFMPEG_DIST_ROOTFS:-$work/rootfs}"
if [[ -z "$FFMPEG_DIST_ROOTFS" ]]; then
  base_tag="debian:trixie-${deb_date}-slim"
  echo "==> pulling $base_tag (linux/amd64) via the Docker Hub registry API"
  if ! provision_rootfs "$rootfs" "${base_tag#debian:}"; then
    echo "error: failed to pull '$base_tag' from Docker Hub via the registry API." >&2
    echo "       Reuse an already-extracted rootfs instead:" >&2
    echo "       FFMPEG_DIST_ROOTFS=/var/tmp/debian-rootfs-20260824 ./publish.sh" >&2
    exit 1
  fi
fi

# --- post-provisioning: guest DNS, the shared build script, qemu ---
cp -a /etc/resolv.conf "$rootfs/etc/resolv.conf"
# The host resolv.conf is often a symlink into /run (systemd-resolved), which
# has no target inside the guest; materialize a regular file in that case.
if [[ -L "$rootfs/etc/resolv.conf" ]]; then
  rm -f "$rootfs/etc/resolv.conf"
  cp -fL /etc/resolv.conf "$rootfs/etc/resolv.conf"
fi
cp "$repo_root/tools/ffmpeg-dist/build.sh" "$rootfs/build.sh"
chmod +x "$rootfs/build.sh"
if [[ "$host_arch" != "x86_64" ]]; then
  cp -f "$QEMU_BIN" "$rootfs/usr/local/bin/qemu-x86_64"
fi

# --- inner harness: mounts + chroot (+ qemu when the host is not amd64) ---
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -euo pipefail\n'
  printf 'rootfs=%s\n' "$(printf %q "$rootfs")"
  printf 'mount -t proc proc "$rootfs/proc"\n'
  printf 'for n in null zero full random urandom tty; do\n'
  printf '  touch "$rootfs/dev/$n"\n'
  printf '  mount --bind "/dev/$n" "$rootfs/dev/$n"\n'
  printf 'done\n'
  printf 'mount --bind "$rootfs/etc/resolv.conf" "$rootfs/etc/resolv.conf"\n'
  for pin in FFMPEG_VERSION FFMPEG_COMMIT NV_CODEC_HEADERS_TAG NV_CODEC_HEADERS_COMMIT \
             CUDA_MANIFEST_URL DEBIAN_SNAPSHOT CUDA_COMPONENTS GENCODE NPROC; do
    printf 'export %s=%s\n' "$pin" "$(printf %q "${!pin}")"
  done
  if [[ "$host_arch" != "x86_64" ]]; then
    printf 'chroot "$rootfs" /usr/local/bin/qemu-x86_64 /bin/bash -eux -o pipefail /build.sh\n'
  else
    printf 'chroot "$rootfs" /bin/bash -eux -o pipefail /build.sh\n'
  fi
} > "$work/inner.sh"
chmod +x "$work/inner.sh"

# The artifact is always linux/amd64 (matches .bazelrc's
# --platforms=//tools/bazel:linux_amd64), so on arm64 hosts this is a
# cross-arch build through QEMU -- expected, and slow.
echo "==> building $artifact (linux/amd64) via chroot+qemu (no docker)"

# --- privilege wrapper: root, passwordless sudo, or a fresh user namespace ---
if [[ $EUID -eq 0 ]]; then
  bash "$work/inner.sh"
elif sudo -n true 2>/dev/null; then
  sudo -n bash "$work/inner.sh"
elif unshare -Urmpf true 2>/dev/null; then
  unshare -Urmpf bash "$work/inner.sh"
else
  echo "error: need root to mount proc and bind device nodes for the chroot;" >&2
  echo "       run as root, with passwordless sudo, or where 'unshare -Urmpf true' works." >&2
  exit 1
fi

if [[ ! -f "$rootfs/opt/ffmpeg-dist/usr/local/bin/ffmpeg" || ! -f "$rootfs/opt/ffmpeg-dist/BUILD-INFO.txt" ]]; then
  echo "error: build produced no /opt/ffmpeg-dist/usr/local/bin/ffmpeg or /opt/ffmpeg-dist/BUILD-INFO.txt" >&2
  exit 1
fi
cp -f "$rootfs/opt/ffmpeg-dist/usr/local/bin/ffmpeg" "$work/out/ffmpeg"
cp -f "$rootfs/opt/ffmpeg-dist/BUILD-INFO.txt" "$work/out/BUILD-INFO.txt"

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
elif [[ -z "$AWS_REGION" ]]; then
  # Config error (not a skip): fail loud before the sts call, which would
  # otherwise report a misleading "credentials not found" for an empty region.
  echo "error: AWS_REGION is required for upload (no default)." >&2
  exit 1
elif ! aws --region "$AWS_REGION" sts get-caller-identity >/dev/null 2>&1; then
  echo "!! AWS credentials not found (aws sts get-caller-identity failed)." >&2
  echo "!! Skipping upload; $artifact remains local." >&2
  echo "!! Re-run with valid credentials to publish, or upload manually:" >&2
  echo "!!   aws --region $AWS_REGION s3 cp $artifact $S3_BUCKET/ffmpeg/$artifact" >&2
  upload_ok=0
else
  [[ -n "${S3_BUCKET#s3://}" ]] || { echo "error: S3_BUCKET is required for upload (e.g. S3_BUCKET=s3://your-bucket-name)" >&2; exit 1; }
  aws --region "$AWS_REGION" s3 cp "$artifact" "$S3_BUCKET/ffmpeg/$artifact"
  upload_ok=1
fi

# --- MODULE.bazel stanza ---
# The S3 URL is derived from STRIMSERVER_S3_BUCKET / STRIMSERVER_S3_REGION at
# fetch time (not printed); mirror_urls is mandatory, so always emit it.
mirror_url="https://github.com/${GITHUB_REPOSITORY:-ChronicCmposer/strimserver}/releases/download/ffmpeg-artifacts/${artifact}"

printf '\n# --- MODULE.bazel: paste this s3_http_archive block into MODULE.bazel ---\n'
printf 's3_http_archive(\n'
printf '    name = "ffmpeg_dist",\n'
printf '    s3_key = "ffmpeg/%s",\n' "$artifact"
printf '    sha256 = "%s",\n' "$sha256"
printf '    mirror_urls = ["%s"],\n' "$mirror_url"
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