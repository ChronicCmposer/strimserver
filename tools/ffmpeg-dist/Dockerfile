# syntax=docker/dockerfile:1
# =============================================================================
# tools/ffmpeg-dist/Dockerfile -- pinned FFmpeg artifact producer (release tool)
#
# Builds the single `ffmpeg` binary the strimserver core image consumes via
# MODULE.bazel's `@ffmpeg_dist` http_archive. This stage graph is NOT part of
# the app's Bazel build graph -- it runs out-of-band, once per version bump,
# through tools/ffmpeg-dist/publish.sh, and the artifact's sha256 is the
# contract the Bazel side pins against.
#
# Pinned inputs (all overridable as --build-arg / --opt build-arg:):
#   FFMPEG_VERSION      8.0                       (release-branch label)
#   FFMPEG_COMMIT       281c902aa1a83fe759011097cb005b555034c151
#                                                (tip of release/8.0, 2026-08-14)
#   NV_CODEC_HEADERS_TAG n13.0.19.0               (documentation; see the
#   NV_CODEC_HEADERS_COMMIT e844e5b26f46bb77479f063029595293aa8f812d
#                                                commit below -- the tag moved
#                                                between an earlier check and
#                                                the build, so the commit is
#                                                the reproducible pin)
#   CUDA_MANIFEST_URL   redistrib_13.0.2.json     (NVIDIA redistrib manifest;
#                       per-component sha256s are read FROM it, never hardcoded)
#   CUDA_COMPONENTS     cuda_nvcc cuda_cudart cuda_crt libnvvm
#                                                (nvcc 13.0.2 needs all four:
#                       cuda_crt provides include/crt/host_config.h and libnvvm
#                       provides nvvm/bin/cicc -- verified during the build)
#   DEBIAN_SNAPSHOT     20260824T082821Z          (same snapshot MODULE.bazel pins)
#   GENCODE             arch=compute_75,code=sm_75 (g4dn.2xlarge)
#   NPROC               8
#
# Output (stage `out`): /out/ffmpeg (stripped) + /out/BUILD-INFO.txt
# =============================================================================

FROM debian:trixie-20260824-slim AS build

# bash: the configure flag array (--nvccflags / --extra-libs carry spaces) and
# pipefail need bash; dash (the image default shell) has neither.
SHELL ["/bin/bash", "-eux", "-o", "pipefail", "-c"]

ARG FFMPEG_VERSION="8.0"
ARG FFMPEG_COMMIT="281c902aa1a83fe759011097cb005b555034c151"
ARG NV_CODEC_HEADERS_TAG="n13.0.19.0"
ARG NV_CODEC_HEADERS_COMMIT="e844e5b26f46bb77479f063029595293aa8f812d"
ARG CUDA_MANIFEST_URL="https://developer.download.nvidia.com/compute/cuda/redist/redistrib_13.0.2.json"
ARG DEBIAN_SNAPSHOT="20260824T082821Z"
ARG CUDA_COMPONENTS="cuda_nvcc cuda_cudart cuda_crt libnvvm"
ARG GENCODE="arch=compute_75,code=sm_75"
ARG NPROC=8

# --- 1) apt: pin the sources to the same Debian snapshot MODULE.bazel uses ---
# libfdk-aac-dev lives in non-free, hence the four components. The deb822
# sources file is written from scratch (deterministic) and the legacy one-line
# file is removed so nothing can silently fall back to rolling deb.debian.org.
RUN set -eux \
    && rm -f /etc/apt/sources.list \
    && printf '%s\n' \
        'Types: deb' \
        "URIs: https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}" \
        'Suites: trixie' \
        'Components: main contrib non-free non-free-firmware' \
        'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' \
        > /etc/apt/sources.list.d/debian.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential pkgconf git curl ca-certificates jq xz-utils \
        nasm yasm binutils libfdk-aac-dev \
    && rm -rf /var/lib/apt/lists/*

# --- 2) CUDA: NVIDIA redistributable tarballs, verified against the manifest ---
# Each component's relative_path + sha256 is read from the manifest at build
# time (single source of truth). Each tarball has a single top dir; the
# components ship include/ and lib/ (cudart), include/crt/ (crt), and
# nvvm/ (libnvvm) -- extract with --strip-components=1, merge, and expose the
# conventional lib64 path via a symlink.
RUN set -eux \
    && cuda_redist_base="$(dirname "$CUDA_MANIFEST_URL")" \
    && mkdir -p /opt/cuda/downloads /opt/cuda/merged /usr/local/cuda \
    && curl -fsSL "$CUDA_MANIFEST_URL" -o /opt/cuda/manifest.json \
    && for component in $CUDA_COMPONENTS; do \
         relative_path="$(jq -r --arg c "$component" '.[$c]["linux-x86_64"].relative_path' /opt/cuda/manifest.json)" \
         && sha256="$(jq -r --arg c "$component" '.[$c]["linux-x86_64"].sha256' /opt/cuda/manifest.json)" \
         && curl -fsSL "$cuda_redist_base/$relative_path" -o "/opt/cuda/downloads/${component}.tar.xz" \
         && printf '%s  %s\n' "$sha256" "/opt/cuda/downloads/${component}.tar.xz" | sha256sum -c - \
         && tar -xJf "/opt/cuda/downloads/${component}.tar.xz" -C /opt/cuda/merged --strip-components=1; \
       done \
    && cp -a /opt/cuda/merged/. /usr/local/cuda/ \
    && ln -s lib /usr/local/cuda/lib64 \
    && test -x /usr/local/cuda/bin/nvcc \
    && test -f /usr/local/cuda/include/cuda_runtime.h \
    && test -f /usr/local/cuda/include/cuda.h \
    && test -L /usr/local/cuda/lib64 \
    && /usr/local/cuda/bin/nvcc --version

# Mirror core/Dockerfile:50-53 -- CUDA env for the FFmpeg build.
ENV CUDA_HOME=/usr/local/cuda
ENV PATH=/usr/local/cuda/bin:${PATH}
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH}
ENV LD_DEBUG=libs

# --- 3) nv-codec-headers (tag for documentation, exact commit as the pin) ---
# The n13.0.19.0 tag moved between an earlier check and the build that this
# recipe reproduces, so the clone uses the tag for readability and then checks
# out the exact commit. BUILD-INFO.txt records both.
RUN set -eux \
    && git clone --depth 1 --branch "$NV_CODEC_HEADERS_TAG" \
        https://github.com/FFmpeg/nv-codec-headers.git /opt/nv-codec-headers \
    && git -C /opt/nv-codec-headers checkout "$NV_CODEC_HEADERS_COMMIT" \
    && make -C /opt/nv-codec-headers install PREFIX=/usr

# --- 4) FFmpeg at the exact pinned commit (blobless clone), build, record ---
# The ./configure flags are copied verbatim from core/Dockerfile:64-128.
RUN set -eux \
    && git clone --filter=blob:none --no-checkout \
        https://github.com/FFmpeg/FFmpeg.git /opt/ffmpeg-src \
    && git -C /opt/ffmpeg-src checkout "$FFMPEG_COMMIT" \
    && cd /opt/ffmpeg-src \
    && nvccflags="--nvccflags=-gencode ${GENCODE} -O2" \
    && configure_flags=( \
        --prefix=/usr/local \
        --extra-cflags=-I/usr/local/cuda/include \
        --extra-ldflags=-L/usr/local/cuda/lib64 \
        "$nvccflags" \
        "--extra-libs=-lpthread -lm" \
        \
        --disable-everything \
        --disable-autodetect \
        --disable-doc \
        --disable-debug \
        --disable-ffplay \
        --disable-ffprobe \
        --disable-avdevice \
        --disable-indevs \
        --disable-outdevs \
        \
        --enable-ffmpeg \
        --enable-network \
        --enable-pthreads \
        --enable-swresample \
        --enable-swscale \
        \
        --enable-nonfree \
        --enable-libfdk_aac \
        \
        --enable-ffnvcodec \
        --enable-nvenc \
        --enable-nvdec \
        --enable-cuda-nvcc \
        --enable-cuvid \
        --enable-decoder=hevc_cuvid \
        --enable-hwaccel=hevc_cuda \
        --enable-filter=hwupload_cuda \
        --enable-filter=scale_cuda \
        \
        --enable-protocol=tcp \
        --enable-protocol=unix \
        --enable-protocol=rtmp \
        \
        --enable-demuxer=rtsp \
        --enable-demuxer=rtp \
        --enable-demuxer=mpegts \
        \
        --enable-muxer=flv \
        --enable-muxer=mpegts \
        \
        --enable-decoder=hevc \
        --enable-decoder=aac \
        \
        --enable-encoder=hevc_nvenc \
        --enable-encoder=h264_nvenc \
        --enable-encoder=libfdk_aac \
        \
        --enable-parser=hevc \
        --enable-parser=aac \
        \
        --enable-bsf=hevc_mp4toannexb \
        --enable-bsf=aac_adtstoasc \
        \
        --enable-filter=fps \
        --enable-filter=setpts \
        --enable-filter=format \
        --enable-filter=scale \
        --enable-filter=aresample \
    ) \
    && ./configure "${configure_flags[@]}" \
    && make -j"${NPROC}" \
    && make install DESTDIR=/opt/ffmpeg-dist \
    && strip /opt/ffmpeg-dist/usr/local/bin/ffmpeg \
    && /opt/ffmpeg-dist/usr/local/bin/ffmpeg -version >/dev/null \
    && cuda_version="$(basename "$CUDA_MANIFEST_URL" | sed -E 's/^redistrib_([0-9.]+)\.json$/\1/')" \
    && { \
         printf 'ffmpeg_commit: %s\n' "$(git rev-parse HEAD)"; \
         printf 'ffmpeg_version: %s\n' "$FFMPEG_VERSION"; \
         printf 'nv_codec_headers_tag: %s\n' "$NV_CODEC_HEADERS_TAG"; \
         printf 'nv_codec_headers_commit: %s\n' "$(git -C /opt/nv-codec-headers rev-parse HEAD)"; \
         printf 'debian_snapshot: %s\n' "$DEBIAN_SNAPSHOT"; \
         printf 'debian_version: %s\n' "$(cat /etc/debian_version)"; \
         printf 'cuda_version: %s\n' "$cuda_version"; \
         printf 'cuda_manifest_url: %s\n' "$CUDA_MANIFEST_URL"; \
         for component in $CUDA_COMPONENTS; do \
           printf 'cuda_component %s sha256: %s\n' "$component" \
             "$(jq -r --arg c "$component" '.[$c]["linux-x86_64"].sha256' /opt/cuda/manifest.json)"; \
         done; \
         printf 'gencode: %s\n' "$GENCODE"; \
         printf 'libfdk_aac_dev_version: %s\n' "$(dpkg-query -W -f='${Version}' libfdk-aac-dev)"; \
         printf 'configure: ./configure %s\n' "${configure_flags[*]}"; \
         printf 'readelf_d:\n'; \
         readelf -d /opt/ffmpeg-dist/usr/local/bin/ffmpeg; \
       } > /opt/ffmpeg-dist/BUILD-INFO.txt \
    && ls -la /opt/ffmpeg-dist /opt/ffmpeg-dist/usr/local/bin

# --- 5) out: the artifact payload (exactly two files) ---
FROM scratch AS out
COPY --from=build /opt/ffmpeg-dist/usr/local/bin/ffmpeg /out/ffmpeg
COPY --from=build /opt/ffmpeg-dist/BUILD-INFO.txt /out/BUILD-INFO.txt