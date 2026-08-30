#!/usr/bin/env bash
# =============================================================================
# tools/ffmpeg-dist/build.sh -- single source of truth for the pinned FFmpeg
# artifact build.
#
# Runs identically in both supported contexts:
#   * inside a docker build (tools/ffmpeg-dist/Dockerfile is a thin wrapper
#     that COPYs this file to /build.sh and executes it), and
#   * inside the chroot that tools/ffmpeg-dist/publish.sh provisions from the
#     Docker Hub registry API (no docker, no buildctl): the guest executes
#     /build.sh via chroot (+ qemu-x86_64 when the host is not amd64).
#
# Every pin is an env var with the same default as the Dockerfile ARG, so a
# bare run and an --build-arg run behave identically. The script is
# idempotent: each phase removes its previous state before rebuilding, and no
# host-absolute path is referenced (every path is a guest path).
#
# Pinned inputs (env, defaults mirror tools/ffmpeg-dist/Dockerfile ARGs):
#   FFMPEG_VERSION         8.0
#   FFMPEG_COMMIT          281c902aa1a83fe759011097cb005b555034c151
#   NV_CODEC_HEADERS_TAG   n13.0.19.0
#   NV_CODEC_HEADERS_COMMIT e844e5b26f46bb77479f063029595293aa8f812d
#   CUDA_MANIFEST_URL      https://developer.download.nvidia.com/compute/cuda/redist/redistrib_13.0.2.json
#   DEBIAN_SNAPSHOT        20260824T082821Z
#   CUDA_COMPONENTS        cuda_nvcc cuda_cudart cuda_crt libnvvm
#   GENCODE                arch=compute_75,code=sm_75
#   NPROC                  8
#
# Output: /opt/ffmpeg-dist/usr/local/bin/ffmpeg (stripped) +
#         /opt/ffmpeg-dist/BUILD-INFO.txt
#
# Deviations from a naive translation of the old Dockerfile RUN steps (all
# artifact-transparent; inherited from the reference harness that produced the
# pinned artifact):
#   * Phase 0 bootstraps ca-certificates over the stock http://deb.debian.org
#     sources because debian:trixie-*-slim ships NO CA bundle, so the snapshot
#     https step cannot work on a fresh rootfs.
#   * Phase 0 also forces apt's gpgv method. The slim image ships sqv as its
#     default verifier but no gpgv, and sqv cannot validate the stock InRelease
#     files under the patched qemu ("No good signature"), so the plain-http
#     stock sources are used ONCE, unauthenticated, to bootstrap gpgv +
#     ca-certificates; every later apt step (the pinned snapshot) verifies
#     with gpgv. (The reference harness hand-copied a gpgv binary into its
#     rootfs; this bootstrap makes that step reproducible. Both produce the
#     identical gpgv package.)
#   * CUDA_COMPONENTS includes cuda_crt and libnvvm (nvcc 13.0.2 needs both).
#   * LD_DEBUG is never set (runtime-only noise that slows qemu).
# =============================================================================
set -eux -o pipefail

# --- execve-interception probe (fail fast on an unpatched qemu) --------------
# Under a patched (buildkit-direct-execve) qemu the guest's /bin/sh re-execs
# via qemu itself; an unpatched qemu ENOEXECs the first guest child. Probe the
# capability up front so the failure is a clear message, not a mid-build
# surprise. Passes trivially on the native docker path (safe under set -e
# because the guard is inside `if !`).
if ! /bin/sh -c 'exit 0' >/dev/null 2>&1; then
    echo "error: the qemu emulator cannot execute guest children (missing the buildkit-direct-execve patch)." >&2
    echo "       Provide QEMU_BIN=/var/tmp/ffmpeg-build/qemu-x86_64-patched or rebuild via build-qemu.sh." >&2
    exit 1
fi

# --- pins (env, defaults identical to the Dockerfile ARGs) -------------------
: "${FFMPEG_VERSION:=8.0}"
: "${FFMPEG_COMMIT:=281c902aa1a83fe759011097cb005b555034c151}"
: "${NV_CODEC_HEADERS_TAG:=n13.0.19.0}"
: "${NV_CODEC_HEADERS_COMMIT:=e844e5b26f46bb77479f063029595293aa8f812d}"
: "${CUDA_MANIFEST_URL:=https://developer.download.nvidia.com/compute/cuda/redist/redistrib_13.0.2.json}"
: "${DEBIAN_SNAPSHOT:=20260824T082821Z}"
: "${CUDA_COMPONENTS:=cuda_nvcc cuda_cudart cuda_crt libnvvm}"
: "${GENCODE:=arch=compute_75,code=sm_75}"
: "${NPROC:=8}"

# --- build env (mirrors core/Dockerfile:50-52, minus LD_DEBUG) ---------------
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export CUDA_HOME=/usr/local/cuda
export PATH=/usr/local/cuda/bin:${PATH}
export LD_LIBRARY_PATH=/usr/local/cuda/lib64

# --- Phase 0: bootstrap apt on a fresh slim rootfs ---------------------------
# apt runs its download method sandboxed as uid 42 (_apt); in a user namespace
# uid 42 is unmapped, so seteuid(42) fails with EINVAL. Running the sandbox as
# root (uid 0, mapped) fixes apt without changing any package.
printf '%s\n' 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/99sandboxroot
# The slim image ships no CA bundle and no gpgv, and its sqv verifier cannot
# validate the stock InRelease files under the patched qemu ("No good
# signature"). Bootstrap gpgv + ca-certificates over the plain-http stock
# sources (unauthenticated, once); every later apt step verifies with gpgv.
apt-get -o Acquire::AllowInsecureRepositories=true update
apt-get install -y --no-install-recommends --allow-unauthenticated gpgv ca-certificates
printf '%s\n' 'APT::Key::gpgvcommand "/usr/bin/gpgv";' > /etc/apt/apt.conf.d/99usegpgv

# --- Phase 1: pin apt to the same Debian snapshot MODULE.bazel uses ----------
# libfdk-aac-dev lives in non-free, hence the four components. The deb822
# sources file is written from scratch (deterministic) and the legacy one-line
# file is removed so nothing can silently fall back to rolling deb.debian.org.
rm -f /etc/apt/sources.list
printf '%s\n' \
    'Types: deb' \
    "URIs: https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}" \
    'Suites: trixie' \
    'Components: main contrib non-free non-free-firmware' \
    'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' \
    > /etc/apt/sources.list.d/debian.sources
apt-get update
apt-get install -y --no-install-recommends \
    build-essential pkgconf git curl jq xz-utils \
    nasm yasm binutils libfdk-aac-dev
rm -rf /var/lib/apt/lists/*

# --- Phase 2: CUDA from the NVIDIA redistrib manifest ------------------------
# Each component's relative_path + sha256 is read from the manifest at build
# time (single source of truth) and verified before extraction. The components
# ship include/ and lib/ (cudart), include/crt/ (crt), and nvvm/ (libnvvm) --
# extract with --strip-components=1, merge, and expose the conventional lib64
# path via a symlink.
cuda_redist_base="$(dirname "$CUDA_MANIFEST_URL")"
rm -rf /opt/cuda/merged /usr/local/cuda
mkdir -p /opt/cuda/downloads /opt/cuda/merged /usr/local/cuda
curl -fsSL "$CUDA_MANIFEST_URL" -o /opt/cuda/manifest.json
for component in $CUDA_COMPONENTS; do
    relative_path="$(jq -r --arg c "$component" '.[$c]["linux-x86_64"].relative_path' /opt/cuda/manifest.json)"
    sha256="$(jq -r --arg c "$component" '.[$c]["linux-x86_64"].sha256' /opt/cuda/manifest.json)"
    curl -fsSL "$cuda_redist_base/$relative_path" -o "/opt/cuda/downloads/${component}.tar.xz"
    printf '%s  %s\n' "$sha256" "/opt/cuda/downloads/${component}.tar.xz" | sha256sum -c -
    tar -xJf "/opt/cuda/downloads/${component}.tar.xz" -C /opt/cuda/merged --strip-components=1 --no-same-owner
done
cp -a /opt/cuda/merged/. /usr/local/cuda/
if [[ ! -L /usr/local/cuda/lib64 ]]; then
    ln -s lib /usr/local/cuda/lib64
fi
test -x /usr/local/cuda/bin/nvcc
test -f /usr/local/cuda/include/cuda_runtime.h
test -f /usr/local/cuda/include/cuda.h
test -L /usr/local/cuda/lib64
/usr/local/cuda/bin/nvcc --version

# --- Phase 3: nv-codec-headers (tag for readability, exact commit as pin) ----
# The n13.0.19.0 tag is annotated and currently resolves to the pinned commit;
# the explicit checkout guards determinism if the tag is ever force-moved.
rm -rf /opt/nv-codec-headers
git clone --depth 1 --branch "$NV_CODEC_HEADERS_TAG" \
    https://github.com/FFmpeg/nv-codec-headers.git /opt/nv-codec-headers
git -C /opt/nv-codec-headers checkout "$NV_CODEC_HEADERS_COMMIT"
make -C /opt/nv-codec-headers install PREFIX=/usr

# --- Phase 4: FFmpeg at the exact pinned commit (blobless clone), build ------
# The ./configure flags are copied verbatim from core/Dockerfile:64-128.
rm -rf /opt/ffmpeg-src /opt/ffmpeg-dist
git clone --filter=blob:none --no-checkout \
    https://github.com/FFmpeg/FFmpeg.git /opt/ffmpeg-src
git -C /opt/ffmpeg-src checkout "$FFMPEG_COMMIT"
cd /opt/ffmpeg-src
nvccflags="--nvccflags=-gencode ${GENCODE} -O2"
configure_flags=(
    --prefix=/usr/local
    --extra-cflags=-I/usr/local/cuda/include
    --extra-ldflags=-L/usr/local/cuda/lib64
    "$nvccflags"
    "--extra-libs=-lpthread -lm"
    \
    --disable-everything
    --disable-autodetect
    --disable-doc
    --disable-debug
    --disable-ffplay
    --disable-ffprobe
    --disable-avdevice
    --disable-indevs
    --disable-outdevs
    \
    --enable-ffmpeg
    --enable-network
    --enable-pthreads
    --enable-swresample
    --enable-swscale
    \
    --enable-nonfree
    --enable-libfdk_aac
    \
    --enable-ffnvcodec
    --enable-nvenc
    --enable-nvdec
    --enable-cuda-nvcc
    --enable-cuvid
    --enable-decoder=hevc_cuvid
    --enable-hwaccel=hevc_cuda
    --enable-filter=hwupload_cuda
    --enable-filter=scale_cuda
    \
    --enable-protocol=tcp
    --enable-protocol=unix
    --enable-protocol=rtmp
    \
    --enable-demuxer=rtsp
    --enable-demuxer=rtp
    --enable-demuxer=mpegts
    \
    --enable-muxer=flv
    --enable-muxer=mpegts
    \
    --enable-decoder=hevc
    --enable-decoder=aac
    \
    --enable-encoder=hevc_nvenc
    --enable-encoder=h264_nvenc
    --enable-encoder=libfdk_aac
    \
    --enable-parser=hevc
    --enable-parser=aac
    \
    --enable-bsf=hevc_mp4toannexb
    --enable-bsf=aac_adtstoasc
    \
    --enable-filter=fps
    --enable-filter=setpts
    --enable-filter=format
    --enable-filter=scale
    --enable-filter=aresample
)
./configure "${configure_flags[@]}"
make -j"${NPROC}"
make install DESTDIR=/opt/ffmpeg-dist
strip /opt/ffmpeg-dist/usr/local/bin/ffmpeg
/opt/ffmpeg-dist/usr/local/bin/ffmpeg -version >/dev/null

# --- record the exact build inputs for reproducibility -----------------------
cuda_version="$(basename "$CUDA_MANIFEST_URL" | sed -E 's/^redistrib_([0-9.]+)\.json$/\1/')"
{
    printf 'ffmpeg_commit: %s\n' "$(git rev-parse HEAD)"
    printf 'ffmpeg_version: %s\n' "$FFMPEG_VERSION"
    printf 'nv_codec_headers_tag: %s\n' "$NV_CODEC_HEADERS_TAG"
    printf 'nv_codec_headers_commit: %s\n' "$(git -C /opt/nv-codec-headers rev-parse HEAD)"
    printf 'debian_snapshot: %s\n' "$DEBIAN_SNAPSHOT"
    printf 'debian_version: %s\n' "$(cat /etc/debian_version)"
    printf 'cuda_version: %s\n' "$cuda_version"
    printf 'cuda_manifest_url: %s\n' "$CUDA_MANIFEST_URL"
    for component in $CUDA_COMPONENTS; do
        printf 'cuda_component %s sha256: %s\n' "$component" \
            "$(jq -r --arg c "$component" '.[$c]["linux-x86_64"].sha256' /opt/cuda/manifest.json)"
    done
    printf 'gencode: %s\n' "$GENCODE"
    printf 'libfdk_aac_dev_version: %s\n' "$(dpkg-query -W -f='${Version}' libfdk-aac-dev)"
    printf 'configure: ./configure %s\n' "${configure_flags[*]}"
    printf 'readelf_d:\n'
    readelf -d /opt/ffmpeg-dist/usr/local/bin/ffmpeg
} > /opt/ffmpeg-dist/BUILD-INFO.txt
ls -la /opt/ffmpeg-dist /opt/ffmpeg-dist/usr/local/bin
echo "=== BUILD COMPLETE ==="