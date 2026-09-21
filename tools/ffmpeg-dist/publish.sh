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
# Architecture (FFMPEG_ARCH): the guest runs natively whenever the host arch
# matches the target arch (amd64 on x86_64, arm64 on aarch64); otherwise the
# amd64 guest runs under the patched qemu-x86_64. Only amd64 guests can be
# emulated (the pipeline has no qemu-aarch64); building the arm64 artifact on
# an x86_64 host is rejected up front. The arm64 rootfs is the arm64 variant
# of the same pinned Debian snapshot, the CUDA components come from the
# manifest's linux-sbsa keys (build.sh derives that from FFMPEG_ARCH), and
# the artifact name gains an -arm64 discriminator so it never collides with
# the amd64 name.
#
# The resulting /out payload (ffmpeg + BUILD-INFO.txt) is tared as
#   ffmpeg-<FFMPEG_VERSION>-deb<YYYYMMDD>-cuda<X.Y.Z>-sm<N>-<shortsha>[-arm64].tar.gz
# (written into the current directory), uploaded to $S3_BUCKET/ffmpeg/ with
# no ACL modification (objects get the bucket's default private ACL; the
# IP-scoped HTTPS-only bucket policy from scripts/bucket-cidr-policy.sh is the only
# access gate), then the s3_http_archive block is printed for MODULE.bazel
# (name = "ffmpeg_dist", or "ffmpeg_dist_arm64" for FFMPEG_ARCH=arm64).
#
# Env vars (defaults mirror the build.sh pins):
#   FFMPEG_VERSION       default 8.1
#   FFMPEG_COMMIT        default 1a748fe2cd43e3ead22fafb1b5b7d77f153898a8
#   FFMPEG_ARCH          default amd64; amd64|arm64 selects the guest/rootfs
#                        arch, the CUDA manifest key (linux-x86_64 /
#                        linux-sbsa, derived in build.sh) and the -arm64
#                        artifact-name discriminator. Default amd64 is
#                        byte-identical to the pre-parameterization behavior.
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
#                        separate from openssh-dist's 9.2.4 pin. Only used
#                        when the guest arch differs from the host arch.
#   QEMU_BIN             default: unset. Explicit override for the patched qemu
#                        used on non-x86_64 hosts; must be a
#                        buildkit-direct-execve patched qemu (verified via the
#                        'safe_execve' marker), otherwise it is ignored with a
#                        warning. Resolution order: QEMU_BIN (validated) >
#                        cached patched qemu (re-validated) > self-heal source
#                        build via tools/qemu/build-qemu.sh. Native builds
#                        (host arch == FFMPEG_ARCH) run the guest natively
#                        with no qemu at all.
#   FFMPEG_DIST_ROOTFS   default unset; when set to an already-extracted rootfs
#                        the Docker Hub registry pull is skipped entirely.
#   FFMPEG_DIST_CACHE    default ${XDG_CACHE_HOME:-$HOME/.cache}/ffmpeg-dist;
#                        the persistent version-stamped rootfs cache. The rootfs
#                        is keyed by DEBIAN_SNAPSHOT + FFMPEG_COMMIT + CUDA
#                        version + NV_CODEC_HEADERS_COMMIT + SM target +
#                        QEMU_VERSION (+ -arm64 for the arm64 build, so the
#                        two arch rootfs caches never collide) and stamped
#                        with a .provisioned sentinel (provisioned into
#                        $rootfs.new then atomically mv'd into place), so an
#                        aborted build resumes from the cached rootfs on the
#                        next run. Determinism guardrail: the cache is never
#                        reused across a pin change (a different pin resolves to
#                        a different rootfs-<key> path).
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
FFMPEG_ARCH="${FFMPEG_ARCH:-amd64}"
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
FFMPEG_DIST_CACHE="${FFMPEG_DIST_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/ffmpeg-dist}"

# --- guard clauses: refuse to build with a malformed pin ---
if [[ ! "$FFMPEG_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: FFMPEG_COMMIT must be a 40-character git SHA, got '$FFMPEG_COMMIT'" >&2
  exit 1
fi

# --- derive the per-arch values from FFMPEG_ARCH (single source of truth) ---
# ROOTFS_ARCH selects the Debian image platform; ARTIFACT_ARCH_SUFFIX keeps the
# arm64 artifact name distinct from the amd64 one. CUDA_MANIFEST_KEY is derived
# in build.sh from the same FFMPEG_ARCH, so the two scripts cannot disagree.
case "$FFMPEG_ARCH" in
  amd64) ROOTFS_ARCH="amd64"; ARTIFACT_ARCH_SUFFIX="" ;;
  arm64) ROOTFS_ARCH="arm64"; ARTIFACT_ARCH_SUFFIX="-arm64" ;;
  *)
    echo "error: unsupported FFMPEG_ARCH '$FFMPEG_ARCH' (expected 'amd64' or 'arm64')" >&2
    exit 1
    ;;
esac

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
artifact="ffmpeg-${FFMPEG_VERSION}-deb${deb_date}-cuda${cuda_version}-${sm_suffix}-${FFMPEG_COMMIT:0:7}${ARTIFACT_ARCH_SUFFIX}.tar.gz"
# The MODULE.bazel repository name follows the same convention as the other
# dual-arch pins (@mediamtx_dist / @mediamtx_dist_arm64).
if [[ "$FFMPEG_ARCH" == "arm64" ]]; then
  stanza_name="ffmpeg_dist_arm64"
else
  stanza_name="ffmpeg_dist"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
# The privileged chroot harness bind-mounts the host's device nodes into
# $work/rootfs/dev, so cleanup cannot remove the busy mounts; without the guard
# that floods the log with 'Device or resource busy' lines and hides the real error.
trap 'rm -rf "$work" 2>/dev/null || true' EXIT
mkdir -p "$work/out"

host_arch="$(uname -m)"
case "$host_arch" in
  x86_64) host_arch="amd64" ;;
  aarch64) host_arch="arm64" ;;
esac
# This consumer pins qemu 8.2.2 (openssh-dist pins 9.2.4) and uses a
# version-stamped cache (tools/qemu/build-qemu.sh), so the two artifact
# pipelines never share a qemu binary.
qemu_cache_path="${XDG_CACHE_HOME:-$HOME/.cache}/qemu/qemu-x86_64-patched-${QEMU_VERSION}"

# qemu is only needed when the guest arch differs from the host arch (the
# amd64 guest emulated on a non-x86_64 host). Native builds (host arch ==
# FFMPEG_ARCH) run the guest directly with no qemu at all. Only amd64 guests
# can be emulated: the pipeline has no qemu-aarch64, so building the arm64
# artifact on an x86_64 host is rejected up front (fail fast) rather than
# attempted under an emulator that would change the artifact.
need_qemu=0
if [[ "$FFMPEG_ARCH" != "$host_arch" ]]; then
  if [[ "$FFMPEG_ARCH" == "arm64" ]]; then
    echo "error: cannot build the arm64 artifact on a $host_arch host: this pipeline has no qemu-aarch64 emulator." >&2
    echo "       Only amd64 guests are emulated (with the patched qemu-x86_64); build arm64 natively on an aarch64 host." >&2
    exit 1
  fi
  need_qemu=1
fi

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

if [[ "$need_qemu" == 1 ]]; then
  qemu=""
  if ! resolve_qemu || ! "$qemu" --version >/dev/null 2>&1; then
    echo "error: host arch is '$host_arch' and the amd64 guest needs qemu-x86_64, but no usable patched qemu-x86_64 was found." >&2
    echo "       Native builds (host arch == FFMPEG_ARCH) run the guest with no qemu at all." >&2
    echo "       Cross builds need the tonistiigi buildkit-direct-execve patched qemu" >&2
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
# Docker Hub registry (plain curl+jq), selects the $ROOTFS_ARCH image, and
# extracts its layers into <rootfs>. Returns non-zero on any failure; the
# caller prints the loud error with the FFMPEG_DIST_ROOTFS fallback hint.
provision_rootfs() {
  local rootfs="$1" tag="$2" token manifest_list arch_digest manifest layer_digests layer_digest
  token="$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/debian:pull" | jq -r '.token')" \
    || return 1
  manifest_list="$(curl -fsSL \
      -H "Authorization: Bearer $token" \
      -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.index.v1+json' \
      "https://registry-1.docker.io/v2/library/debian/manifests/$tag" \
    | jq -c .)" \
    || return 1
  arch_digest="$(printf '%s' "$manifest_list" | jq -r --arg a "$ROOTFS_ARCH" '.manifests[] | select(.platform.os=="linux" and .platform.architecture==$a) | .digest')" \
    || return 1
  [[ -n "$arch_digest" ]] || return 1
  manifest="$(curl -fsSL \
      -H "Authorization: Bearer $token" \
      -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
      "https://registry-1.docker.io/v2/library/debian/manifests/$arch_digest" \
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

rootfs_arch_tag=""
if [[ "$FFMPEG_ARCH" == "arm64" ]]; then
  rootfs_arch_tag="-arm64"
fi
rootfs="${FFMPEG_DIST_ROOTFS:-$FFMPEG_DIST_CACHE/rootfs-${DEBIAN_SNAPSHOT}-${FFMPEG_COMMIT}-cuda${cuda_version}-nv${NV_CODEC_HEADERS_COMMIT:0:7}-sm${sm_suffix}${rootfs_arch_tag}-${QEMU_VERSION}}"
if [[ -z "$FFMPEG_DIST_ROOTFS" ]]; then
  base_tag="debian:trixie-${deb_date}-slim"
  if [[ ! -f "$rootfs/.provisioned" ]]; then
    echo "==> provisioning $base_tag (linux/${ROOTFS_ARCH}) via the Docker Hub registry API"
    rm -rf "$rootfs" "$rootfs.new"
    mkdir -p "$rootfs.new"
    if ! provision_rootfs "$rootfs.new" "${base_tag#debian:}"; then
      rm -rf "$rootfs.new"
      echo "error: failed to pull '$base_tag' from Docker Hub via the registry API." >&2
      echo "       Reuse an already-extracted rootfs instead:" >&2
      echo "       FFMPEG_DIST_ROOTFS=$rootfs ./publish.sh" >&2
      exit 1
    fi
    touch "$rootfs.new/.provisioned"
    mv "$rootfs.new" "$rootfs"
  else
    echo "==> reusing cached rootfs $rootfs (pin $base_tag)"
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
if [[ "$need_qemu" == 1 ]]; then
  cp -f "$QEMU_BIN" "$rootfs/usr/local/bin/qemu-x86_64"
fi

# --- inner harness: mounts + chroot (+ qemu when the guest arch is emulated) ---
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
  for pin in FFMPEG_VERSION FFMPEG_COMMIT FFMPEG_ARCH NV_CODEC_HEADERS_TAG NV_CODEC_HEADERS_COMMIT \
             CUDA_MANIFEST_URL DEBIAN_SNAPSHOT CUDA_COMPONENTS GENCODE NPROC; do
    printf 'export %s=%s\n' "$pin" "$(printf %q "${!pin}")"
  done
  if [[ "$need_qemu" == 1 ]]; then
    printf 'chroot "$rootfs" /usr/local/bin/qemu-x86_64 /bin/bash -eux -o pipefail /build.sh\n'
  else
    printf 'chroot "$rootfs" /bin/bash -eux -o pipefail /build.sh\n'
  fi
} > "$work/inner.sh"
chmod +x "$work/inner.sh"

# The artifact is built for FFMPEG_ARCH (matching the .bazelrc
# --platforms=//tools/bazel:linux_<arch> selection); when the host arch
# differs, the amd64 guest runs under the patched qemu -- expected, and slow.
if [[ "$need_qemu" == 1 ]]; then
  echo "==> building $artifact (linux/${FFMPEG_ARCH}) via chroot+qemu (no docker)"
else
  echo "==> building $artifact (linux/${FFMPEG_ARCH}) via chroot natively (no docker)"
fi

# --- privilege wrapper: root, passwordless sudo, or a fresh user namespace ---
if [[ $EUID -eq 0 ]]; then
  unshare -m bash "$work/inner.sh"
elif sudo -n true 2>/dev/null; then
  sudo -n unshare -m bash "$work/inner.sh"
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
printf '    name = "%s",\n' "$stanza_name"
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