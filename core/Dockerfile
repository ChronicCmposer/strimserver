# =============================================================================
# strimserver - single Dockerfile, two independent "FROM scratch" targets:
#
#   --target ffmpeg    -> minimal image: ffmpeg w/ NVIDIA HW accel
#   --target mediamtx  -> minimal image: mediamtx media server only
#
# Runtime-injected (NOT baked into the images), per controller/container_factory:
#   ffmpeg:    transcode.sh        bind-mounted at /opt/strimserver/bin/transcode.sh
#              strimserver.env     bind-mounted at /opt/strimserver/config/strimserver.env
#              GPU                 attached via CDI (nvidia.com/gpu)
#   mediamtx:  mediamtx.template   bind-mounted at /opt/strimserver/config/mediamtx.yaml.template
#              strimserver.env     bind-mounted at /opt/strimserver/config/strimserver.env
#              srt-passphrase      bind-mounted at /run/secrets/srt-passphrase
#
# Stage graph:
#   build          (CUDA devel)  -> compiles ffmpeg, stages into /opt/ffmpeg-dist
#   mediamtx-fetch (debian slim) -> downloads + strips the mediamtx binary
#   libs           (debian slim) -> source of runtime libs + shell/coreutils
#   ffmpeg         (scratch)     -> TARGET A
#   mediamtx       (scratch)     -> TARGET B
# =============================================================================


# ----------------------------------------------------------------------------
# Stage: build  -- compile ffmpeg with NVENC/NVDEC/CUVID + libfdk_aac
# ----------------------------------------------------------------------------
FROM nvidia/cuda:13.0.2-devel-ubuntu24.04 AS build

ARG FFMPEG_REPO="https://github.com/FFmpeg/FFmpeg.git"
ARG FFMPEG_VERSION="release/8.0"
# build aimed for g4dn.2xlarge
ARG NPROC=8

ARG FFMPEG_NV_CODEC_HEADERS_REPO="https://github.com/FFmpeg/nv-codec-headers.git"
ARG FFMPEG_NV_CODEC_HEADERS_VERSION="n13.0.19.0"

RUN set -x \
   && apt-get update \
   && apt-get install -y --no-install-recommends \
      software-properties-common \
   && add-apt-repository -y universe \
   && apt-get install -y --no-install-recommends \
      build-essential pkgconf git \
      nasm yasm \
      libfdk-aac-dev \
      wget  \
      binutils \
   && rm -rf /var/lib/apt/lists/*

ENV CUDA_HOME=/usr/local/cuda
ENV PATH=/usr/local/cuda/bin:${PATH}
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH}
ENV LD_DEBUG=libs

RUN set -x \
   && git clone --depth 1 --branch "$FFMPEG_NV_CODEC_HEADERS_VERSION" \
      "$FFMPEG_NV_CODEC_HEADERS_REPO" /opt/nv-codec-headers \
   && make -C /opt/nv-codec-headers install PREFIX=/usr \
   && git clone --depth 1 --branch "$FFMPEG_VERSION" "$FFMPEG_REPO" /opt/ffmpeg-src \
   && cd /opt/ffmpeg-src \
   && set -xeu \
   && which nvcc && nvcc --version && gcc --version && echo $PATH \
   && echo "$(pwd)" && ls -la . \
   && ./configure \
      --prefix="/usr/local" \
      --extra-cflags="-I/usr/local/cuda/include" \
      --extra-ldflags="-L/usr/local/cuda/lib64" \
      --nvccflags="-gencode arch=compute_75,code=sm_75 -O2" \
      --extra-libs="-lpthread -lm" \
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
   && make -C /opt/ffmpeg-src -j$(nproc) \
   && cd /opt/ffmpeg-src \
   && ls -la \
   && make install DESTDIR=/opt/ffmpeg-dist \
   && readelf -h /opt/ffmpeg-dist/usr/local/bin/ffmpeg \
   && readelf -d /opt/ffmpeg-dist/usr/local/bin/ffmpeg | grep NEEDED || true


# ----------------------------------------------------------------------------
# Stage: mediamtx-fetch  -- download + strip the mediamtx binary
# ----------------------------------------------------------------------------
FROM debian:trixie-20260518-slim AS mediamtx-fetch

ARG MEDIAMTX_BIN_URL="https://github.com/bluenviron/mediamtx/releases/download/v1.17.0/mediamtx_v1.17.0_linux_amd64.tar.gz"

RUN set -x \
   && apt-get update \
   && apt-get install -y --no-install-recommends \
      wget ca-certificates binutils \
   && rm -rf /var/lib/apt/lists/* \
   && mkdir -p /opt/mediamtx \
   && wget "$MEDIAMTX_BIN_URL" -O /opt/mediamtx/mediamtx.tar.gz \
   && cd /opt/mediamtx \
   && tar -xzvf mediamtx.tar.gz \
   && ls -la \
   && strip mediamtx \
   # mediamtx releases are static (pure-Go); this should report
   # "not a dynamic executable". The `|| true` keeps the build going either way.
   && ldd mediamtx || true


# ----------------------------------------------------------------------------
# Stage: libs  -- source of runtime shared libs + shell/coreutils for scratch
# ----------------------------------------------------------------------------
FROM debian:trixie-20260518-slim AS libs

RUN set -x \
   && sed -i -E 's/^Components:[[:space:]]*main[[:space:]]*$/Components: main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources \
   && apt-get update \
   && apt-get install -y --no-install-recommends \
      busybox-static \
      gettext-base \
      libfdk-aac2t64 \
      ca-certificates \
   && rm -rf /var/lib/apt/lists/* \
   && mkdir -p /staging/usr/bin /staging/bin /staging/etc \
   && cp "$(command -v busybox)" /staging/usr/bin/busybox \
   && for app in sh cat rm ln mkdir wget nc; do \
         ln -s busybox /staging/usr/bin/"$app"; \
      done \
   && ln -s /usr/bin/busybox /staging/bin/sh \
   && printf 'hosts: files dns\n' > /staging/etc/nsswitch.conf


# ============================================================================
# TARGET A: ffmpeg  (FROM scratch)
#   - just the ffmpeg binary + the minimum to source/run a mounted transcode.sh
#   - lifecycle is controller-managed (single-shot, no auto-restart)
#   - NVIDIA driver libs + sonames are injected at RUNTIME via CDI
# ============================================================================
FROM scratch AS ffmpeg

ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility,video
ENV LD_LIBRARY_PATH=/usr/lib64
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# --- shell + nice: all transcode.sh needs (the controller captures logs) ---
COPY --from=libs /staging/       /
COPY --from=libs /usr/bin/nice   /usr/bin/nice
# --- dynamic linker + shared libs ffmpeg (NEEDED) links against ---
COPY --from=libs /lib64/ld-linux-x86-64.so.2                 /lib64/
COPY --from=libs /lib/x86_64-linux-gnu/libc.so.6             /lib/x86_64-linux-gnu/
COPY --from=libs /lib/x86_64-linux-gnu/libm.so.6             /lib/x86_64-linux-gnu/
COPY --from=libs /lib/x86_64-linux-gnu/libdl.so.2            /lib/x86_64-linux-gnu/
COPY --from=libs /lib/x86_64-linux-gnu/libpthread.so.0       /lib/x86_64-linux-gnu/
COPY --from=libs /lib/x86_64-linux-gnu/librt.so.1            /lib/x86_64-linux-gnu/
COPY --from=libs /lib/x86_64-linux-gnu/libresolv.so.2        /lib/x86_64-linux-gnu/
COPY --from=libs /lib/x86_64-linux-gnu/libnss_dns.so.2       /lib/x86_64-linux-gnu/
COPY --from=libs /lib/x86_64-linux-gnu/libnss_files.so.2     /lib/x86_64-linux-gnu/
COPY --from=libs /usr/lib/x86_64-linux-gnu/libfdk-aac.so.2   /usr/lib/x86_64-linux-gnu/

# misc

# --- ffmpeg binary only; transcode.sh is bind-mounted at runtime and IS the
#     entrypoint (see ENTRYPOINT below) -- there is no separate entrypoint script ---
COPY --from=build /opt/ffmpeg-dist/usr/local/bin/ffmpeg /ffmpeg

RUN set -x \
   && /ffmpeg -version \
   && /ffmpeg -h encoder=h264_nvenc \
   && /ffmpeg -h encoder=hevc_nvenc \
   && /bin/sh -c 'echo shell-ok' \
   && for a in cat rm ln nice mkdir wget; do command -v "$a"; done



# ============================================================================
# TARGET B: mediamtx  (FROM scratch)
#   - mediamtx server only (no ffmpeg, no CUDA, no GPU)
#   - mediamtx.yaml.template is bind-mounted at runtime, not baked in
# ============================================================================
FROM scratch AS mediamtx

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# --- shell + tools used by entrypoint.mediamtx.sh (render, secret, cleanup) ---
COPY --from=libs /staging/          /
COPY --from=libs /usr/bin/nice      /usr/bin/nice
COPY --from=libs /usr/bin/envsubst  /usr/bin/envsubst

# --- dynamic linker + libs (covers envsubst and a non-static mediamtx) ---
COPY --from=libs /lib64/ld-linux-x86-64.so.2           /lib64/
COPY --from=libs /lib/x86_64-linux-gnu/libc.so.6       /lib/x86_64-linux-gnu/
COPY --from=libs /lib/x86_64-linux-gnu/libm.so.6       /lib/x86_64-linux-gnu/
COPY --from=libs /lib/x86_64-linux-gnu/libpthread.so.0 /lib/x86_64-linux-gnu/
COPY --from=libs /lib/x86_64-linux-gnu/libresolv.so.2  /lib/x86_64-linux-gnu/
COPY --from=libs /etc/ssl/certs/ca-certificates.crt    /etc/ssl/certs/

# misc

# --- mediamtx binary + entrypoint (template is bind-mounted at runtime) ---
COPY --from=mediamtx-fetch /opt/mediamtx/mediamtx /mediamtx
COPY --chmod=755 entrypoint.mediamtx.sh /entrypoint.sh

RUN set -x \
   && /mediamtx --version \
   && busybox --list \
   && /bin/sh -c 'echo shell-ok' \
   && for a in cat rm ln nice mkdir wget; do command -v "$a"; done \
   && envsubst --version >/dev/null

ENTRYPOINT [ "/entrypoint.sh" ]

