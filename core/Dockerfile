FROM nvidia/cuda:13.0.2-devel-ubuntu24.04 AS build

ARG FFMPEG_REPO="https://github.com/FFmpeg/FFmpeg.git"
ARG FFMPEG_VERSION="release/8.0"
# build aimed for g4dn.2xlarge
ARG NPROC=8

ARG FFMPEG_NV_CODEC_HEADERS_REPO="https://github.com/FFmpeg/nv-codec-headers.git"
ARG FFMPEG_NV_CODEC_HEADERS_VERSION="n13.0.19.0"
ARG MEDIAMTX_BIN_URL="https://github.com/bluenviron/mediamtx/releases/download/v1.17.0/mediamtx_v1.17.0_linux_amd64.tar.gz"


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
   && set -xeuo \
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
      --enable-filter=aresample || true \
   && make -C /opt/ffmpeg-src -j$(nproc) \
   && cd /opt/ffmpeg-src \
   && ls -la \
   && make install DESTDIR=/opt/ffmpeg-dist \
   && readelf -h /opt/ffmpeg-dist/usr/local/bin/ffmpeg \
   && readelf -d /opt/ffmpeg-dist/usr/local/bin/ffmpeg | grep NEEDED || true \
   && mkdir -p /opt/mediamtx \
   && wget $MEDIAMTX_BIN_URL -O /opt/mediamtx/mediamtx.tar.gz \
   && cd /opt/mediamtx \
   && tar -xzvf mediamtx.tar.gz \
   && ls -la \
   && strip mediamtx \
   && ldd mediamtx || true

# && cat /opt/ffmpeg-src/ffbuild/config.log \

# --------------------------------------------

FROM debian:trixie-20260518-slim AS download

# ARG FISH_SHELL_VERSION="4.0.2-r0"
ARG ENABLE_OBS="false"
ARG ENABLE_EMBEDDED_FISH_SHELL="false"
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility,video

RUN sed -i -E 's/^Components:[[:space:]]*main[[:space:]]*$/Components: main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      dash \
      gettext-base \
      libfdk-aac2t64 \
      ca-certificates \
      coreutils \
 && rm -rf /var/lib/apt/lists/*

# && if [ "$ENABLE_EMBEDDED_FISH_SHELL" = "true" ]; then apt-get install -y --no-install-recommends fish; fi \
# && if [ "$ENABLE_OBS" = "true" ]; then apt-get install -y --no-install-recommends obs-studio; fi \


FROM scratch AS runtime


ARG ENABLE_OBS="false"
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility,video
ENV LD_LIBRARY_PATH=/usr/lib64

COPY --from=download /bin/dash /bin/sh
COPY --from=download /usr/bin/envsubst /usr/bin/envsubst
COPY --from=download /usr/bin/cat /usr/bin/cat
COPY --from=download /usr/bin/ln /usr/bin/ln
COPY --from=download /usr/bin/rm /usr/bin/rm
COPY --from=download /usr/bin/nice /usr/bin/nice
COPY --from=download /usr/bin/tee /usr/bin/tee

COPY --from=download /lib64/ld-linux-x86-64.so.2 /lib64/
COPY --from=download /lib/x86_64-linux-gnu/libc.so.6 /lib/x86_64-linux-gnu/
COPY --from=download /lib/x86_64-linux-gnu/libm.so.6 /lib/x86_64-linux-gnu/
COPY --from=download /lib/x86_64-linux-gnu/libdl.so.2 /lib/x86_64-linux-gnu/
COPY --from=download /lib/x86_64-linux-gnu/libpthread.so.0 /lib/x86_64-linux-gnu/
COPY --from=download /lib/x86_64-linux-gnu/librt.so.1 /lib/x86_64-linux-gnu/
COPY --from=download /lib/x86_64-linux-gnu/libresolv.so.2 /lib/x86_64-linux-gnu/
COPY --from=download /usr/lib/x86_64-linux-gnu/libfdk-aac.so.2 /usr/lib/x86_64-linux-gnu/
COPY --from=download /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/


COPY --from=build /opt/ffmpeg-dist/usr/local/bin/ffmpeg /usr/local/bin/ffmpeg
COPY --from=build /opt/mediamtx/mediamtx /usr/local/bin

COPY --chmod=755 entrypoint.sh /opt/strimserver/entrypoint.sh

RUN set -x \
   && mediamtx --version \
   && mediamtx --help \
   && if [ "$ENABLE_OBS" = "true" ]; then obs --version; fi \
   && ffmpeg -version \
   && ffmpeg -h encoder=h264_nvenc \
   && ffmpeg -h encoder=hevc_nvenc

ENTRYPOINT [ "/opt/strimserver/entrypoint.sh" ]



