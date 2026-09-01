#!/usr/bin/env bash
# =============================================================================
# tools/openssh/publish.sh -- build, checksum, upload, and print the
# MODULE.bazel stanza for the pinned OpenSSH RPM artifact.
#
# qemu-direct flow (no docker): the script pulls the pinned
# amazonlinux:2023 base image via the Docker Hub registry API (plain curl+jq
# -- no docker daemon), extracts it into a rootfs, copies the shared build
# script (tools/openssh/build.sh) + the tuned sshd_config in, and runs it
# inside a chroot -- invoking the patched qemu-x86_64 explicitly for the amd64
# guest when the host is not x86_64. The build itself is the shared build.sh,
# the single source of truth for the pinned artifact.
#
# The resulting /out/openssh-experimental.rpm is copied into the current
# directory as openssh-experimental.rpm, uploaded to $S3_BUCKET/openssh/ with
# no ACL modification (objects get the bucket's default private ACL; the
# IP-scoped HTTPS-only bucket policy from scripts/bucket-cidr-policy.sh is the only
# access gate), then the s3_http_file block (with build_file_content =
# exports_files for the root-addressable @openssh_dist//:openssh-experimental.rpm
# label) is printed for MODULE.bazel (name = "openssh_dist") along with the
# `gh release upload` command for the GitHub Release mirror (tag openssh-dist).
#
# Env vars (defaults mirror the build.sh pins):
#   OPENSSH_TAG        default V_10_3_P1
#   OPENSSH_VERSION    default 10.3p1
#   AMAZONLINUX_TAG    default 2023 (the Docker Hub tag pulled for the rootfs)
#   QEMU_VERSION       default 9.2.4 (this consumer's qemu pin; fixes the
#                      linux-user open_self_maps SIGSEGV that crashed
#                      amazonlinux:2023 grep/awk/m4). Passed to
#                      tools/qemu/build-qemu.sh on self-heal; the
#                      version-stamped cache keeps it separate from
#                      ffmpeg-dist's 8.2.2 pin.
#   QEMU_BIN           default: unset. Explicit override for the patched qemu
#                      used on non-x86_64 hosts; must be a
#                      buildkit-direct-execve patched qemu (verified via the
#                      'safe_execve' marker), otherwise it is ignored with a
#                      warning. Resolution order: QEMU_BIN (validated) >
#                      cached patched qemu (re-validated) > self-heal source
#                      build via tools/qemu/build-qemu.sh. amd64 hosts
#                      run the guest natively with no qemu at all.
#   OPENSSH_DIST_ROOTFS default unset; when set to an already-extracted rootfs
#                      the Docker Hub registry pull is skipped entirely.
#   S3_BUCKET          required for upload (e.g. s3://<bucket-name>; SKIP_UPLOAD=1 works without it)
#   AWS_REGION         required for upload (no default; SKIP_UPLOAD=1 works without it)
#   GITHUB_REPOSITORY  owner/repo; default ChronicCmposer/strimserver; used for
#                      the GitHub Release mirror URL in the stanza's mirror_urls.
#   SKIP_UPLOAD        default unset; 1 = build + checksum only, print the
#                      stanza with a SKIP_UPLOAD note, exit 0.
#
# If AWS credentials are missing the upload is skipped (loudly, exit 1) but the
# stanza is still printed, so the artifact can be published later.
# =============================================================================
set -euo pipefail

# --- inputs (defaults mirror the build.sh pins) ---
OPENSSH_TAG="${OPENSSH_TAG:-V_10_3_P1}"
OPENSSH_VERSION="${OPENSSH_VERSION:-10.3p1}"
AMAZONLINUX_TAG="${AMAZONLINUX_TAG:-2023}"
S3_BUCKET="${S3_BUCKET:-s3://<bucket-name>}"
AWS_REGION="${AWS_REGION:-}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
SKIP_UPLOAD="${SKIP_UPLOAD:-}"
QEMU_BIN="${QEMU_BIN:-}"
QEMU_VERSION="${QEMU_VERSION:-9.2.4}"
OPENSSH_DIST_ROOTFS="${OPENSSH_DIST_ROOTFS:-}"

# --- guard clauses: refuse to build with a malformed pin ---
if [[ -z "$OPENSSH_TAG" ]]; then
  echo "error: OPENSSH_TAG must be a git tag/branch (e.g. V_10_3_P1), got ''" >&2
  exit 1
fi
if [[ -z "$OPENSSH_VERSION" ]]; then
  echo "error: OPENSSH_VERSION must be a version string (e.g. 10.3p1), got ''" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
# The rootfs inside $work is populated by the privileged chroot harness, so an
# unprivileged rm cannot delete its root-owned files; without the guard that
# floods the log with ~10^5 'Permission denied' lines and hides the real error.
trap 'rm -rf "$work" 2>/dev/null || true' EXIT
mkdir -p "$work/out"

host_arch="$(uname -m)"
# Each consumer pins its own qemu (openssh-dist: 9.2.4, ffmpeg-dist: 8.2.2)
# and uses a version-stamped cache (tools/qemu/build-qemu.sh), so the two
# artifact pipelines never share a qemu binary.
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
# <path>'s --version (e.g. "9.2.4"), or empty when the binary cannot report one.
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
# (e.g. an 8.2.2 cache when openssh-dist pins 9.2.4) still passes the
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
    echo "       (upstream qemu cannot intercept the guest's execve)." >&2
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
# provision_rootfs <rootfs> <repo> <tag> -- pulls the <tag> manifest list from
# the Docker Hub registry (plain curl+jq), selects the linux/amd64 image, and
# extracts its layers into <rootfs>. Returns non-zero on any failure; the
# caller prints the loud error with the OPENSSH_DIST_ROOTFS fallback hint.
provision_rootfs() {
  local rootfs="$1" repo="$2" tag="$3" token manifest_list amd64_digest manifest layer_digests layer_digest
  token="$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" | jq -r '.token')" \
    || return 1
  manifest_list="$(curl -fsSL \
      -H "Authorization: Bearer $token" \
      -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.index.v1+json' \
      "https://registry-1.docker.io/v2/${repo}/manifests/$tag" \
    | jq -c .)" \
    || return 1
  amd64_digest="$(printf '%s' "$manifest_list" | jq -r '.manifests[] | select(.platform.os=="linux" and .platform.architecture=="amd64") | .digest')" \
    || return 1
  [[ -n "$amd64_digest" ]] || return 1
  manifest="$(curl -fsSL \
      -H "Authorization: Bearer $token" \
      -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
      "https://registry-1.docker.io/v2/${repo}/manifests/$amd64_digest" \
    | jq -c .)" \
    || return 1
  layer_digests="$(printf '%s' "$manifest" | jq -r '.layers[].digest')" \
    || return 1
  [[ -n "$layer_digests" ]] || return 1
  mkdir -p "$rootfs"
  for layer_digest in $layer_digests; do
    # amazonlinux:2023's layer carries device nodes (dev/null, dev/random, ...)
    # that only root can mknod; an unprivileged tar reports them as errors.
    # They are irrelevant -- the chroot harness bind-mounts the host's device
    # nodes over them -- so tolerate tar's non-zero exit here and let the
    # base-binaries check below catch a real download/extraction failure.
    curl -fsSL -H "Authorization: Bearer $token" \
      "https://registry-1.docker.io/v2/${repo}/blobs/$layer_digest" \
      | tar -xzf - -C "$rootfs" 2>/dev/null \
      || true
  done
  # Fail loud if the extraction actually failed, not just skipped the image's
  # baked-in device nodes.
  if [[ ! -x "$rootfs/usr/bin/dnf" || ! -x "$rootfs/bin/bash" ]]; then
    return 1
  fi
  return 0
}

rootfs="${OPENSSH_DIST_ROOTFS:-$work/rootfs}"
if [[ -z "$OPENSSH_DIST_ROOTFS" ]]; then
  echo "==> pulling amazonlinux:${AMAZONLINUX_TAG} (linux/amd64) via the Docker Hub registry API"
  if ! provision_rootfs "$rootfs" "library/amazonlinux" "$AMAZONLINUX_TAG"; then
    echo "error: failed to pull 'amazonlinux:${AMAZONLINUX_TAG}' from Docker Hub via the registry API." >&2
    echo "       Reuse an already-extracted rootfs instead:" >&2
    echo "       OPENSSH_DIST_ROOTFS=/var/tmp/amazonlinux-rootfs-2023 ./publish.sh" >&2
    exit 1
  fi
fi

# --- post-provisioning: guest DNS, the shared build script + config, qemu ---
cp -a /etc/resolv.conf "$rootfs/etc/resolv.conf"
# The host resolv.conf is often a symlink into /run (systemd-resolved), which
# has no target inside the guest; materialize a regular file in that case.
if [[ -L "$rootfs/etc/resolv.conf" ]]; then
  rm -f "$rootfs/etc/resolv.conf"
  cp -fL /etc/resolv.conf "$rootfs/etc/resolv.conf"
fi
cp "$repo_root/tools/openssh/build.sh" "$rootfs/build.sh"
chmod +x "$rootfs/build.sh"
# build.sh reads /sshd_config (inside the chroot) to overwrite the stock one.
cp "$repo_root/tools/openssh/sshd_config" "$rootfs/sshd_config"
# The guest /out mount point (build.sh's artifact lands there) and the qemu
# install dir are not guaranteed to exist in a fresh rootfs.
mkdir -p "$rootfs/out"
if [[ "$host_arch" != "x86_64" ]]; then
  mkdir -p "$rootfs/usr/local/bin"
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
  # The host out/ dir is bind-mounted at the guest /out so build.sh's artifact
  # lands on the host filesystem directly (no post-hoc copy out of the chroot).
  printf 'mount --bind %s "$rootfs/out"\n' "$(printf %q "$work/out")"
  for pin in OPENSSH_TAG OPENSSH_VERSION; do
    printf 'export %s=%s\n' "$pin" "$(printf %q "${!pin}")"
  done
  if [[ "$host_arch" != "x86_64" ]]; then
    printf 'chroot "$rootfs" /usr/local/bin/qemu-x86_64 /bin/bash -eux -o pipefail /build.sh\n'
    printf 'chroot "$rootfs" /usr/local/bin/qemu-x86_64 /bin/bash -eux -o pipefail -c '\''test -s /out/openssh-experimental.rpm && rpm -qip /out/openssh-experimental.rpm'\''\n'
  else
    printf 'chroot "$rootfs" /bin/bash -eux -o pipefail /build.sh\n'
    printf 'chroot "$rootfs" /bin/bash -eux -o pipefail -c '\''test -s /out/openssh-experimental.rpm && rpm -qip /out/openssh-experimental.rpm'\''\n'
  fi
} > "$work/inner.sh"
chmod +x "$work/inner.sh"

# The artifact is always linux/amd64 (matches .bazelrc's
# --platforms=//tools/bazel:linux_amd64), so on arm64 hosts this is a
# cross-arch build through QEMU -- expected, and slow.
echo "==> building openssh-experimental.rpm (linux/amd64) via chroot+qemu (no docker)"

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

# --- verify the artifact (in-chroot rpm -qip ran inside the harness) ----------
if [[ ! -f "$work/out/openssh-experimental.rpm" || ! -s "$work/out/openssh-experimental.rpm" ]]; then
  echo "error: build produced no non-empty /out/openssh-experimental.rpm" >&2
  exit 1
fi
rpm_type="$(file -b "$work/out/openssh-experimental.rpm")"
echo "==> rpm: $rpm_type"

# --- checksum -----------------------------------------------------------------
artifact="openssh-experimental.rpm"
cp -f "$work/out/openssh-experimental.rpm" "$artifact"
sha256="$(sha256sum "$artifact" | awk '{print $1}')"
echo "==> artifact: $artifact"
echo "==> sha256:   $sha256"

# --- upload (skip loudly when AWS creds are missing, or by SKIP_UPLOAD=1) -----
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
  echo "!!   aws --region $AWS_REGION s3 cp $artifact $S3_BUCKET/openssh/openssh-experimental.rpm" >&2
  upload_ok=0
else
  if [[ -z "$S3_BUCKET" || "$S3_BUCKET" == "s3://<bucket-name>" ]]; then
    echo "error: S3_BUCKET is required for upload; set S3_BUCKET to your real bucket (e.g. S3_BUCKET=s3://your-bucket-name)." >&2
    exit 1
  fi
  aws --region "$AWS_REGION" s3 cp "$artifact" "$S3_BUCKET/openssh/openssh-experimental.rpm"
  upload_ok=1
fi

# --- MODULE.bazel stanza ---
# The S3 URL is derived from STRIMSERVER_S3_BUCKET / STRIMSERVER_S3_REGION at
# fetch time (not printed); mirror_urls is mandatory, so always emit it.
mirror_url="https://github.com/${GITHUB_REPOSITORY:-ChronicCmposer/strimserver}/releases/download/openssh-dist/openssh-experimental.rpm"

printf '\n# --- MODULE.bazel: paste this s3_http_file block into MODULE.bazel ---\n'
printf 's3_http_file(\n'
printf '    name = "openssh_dist",\n'
printf '    downloaded_file_name = "openssh-experimental.rpm",\n'
printf '    build_file_content = "exports_files([\\"openssh-experimental.rpm\\"])",\n'
printf '    s3_key = "openssh/openssh-experimental.rpm",\n'
printf '    sha256 = "%s",\n' "$sha256"
printf '    mirror_urls = ["%s"],\n' "$mirror_url"
printf ')\n'
if [[ "$upload_ok" == 0 ]]; then
  if [[ "$SKIP_UPLOAD" == "1" ]]; then
    printf '# NOTE: upload skipped (SKIP_UPLOAD=1).\n'
  else
    printf '# NOTE: upload skipped (AWS credentials missing); artifact is local only.\n'
  fi
fi

printf '\n# --- GitHub Release mirror (upload the same RPM to the openssh-dist release) ---\n'
printf 'gh release upload openssh-dist %s\n' "$artifact"

# exit non-zero when the upload was skipped so callers know publish didn't finish;
# SKIP_UPLOAD=1 (local build) treats a successful build as success.
if [[ "$SKIP_UPLOAD" != "1" ]]; then
  [[ "$upload_ok" == 1 ]]
fi