FROM nvidia/cuda:13.0.2-devel-ubuntu24.04 AS ffmpeg_build

ARG FFMPEG_REPO="https://github.com/FFmpeg/FFmpeg.git"
ARG FFMPEG_VERSION="release/8.0"
# build aimed for g4dn.2xlarge
ARG NPROC=8

ARG FFMPEG_NV_CODEC_HEADERS_REPO="https://github.com/FFmpeg/nv-codec-headers.git"
ARG FFMPEG_NV_CODEC_HEADERS_VERSION="n13.0.19.0"


RUN apt-get update \
   && apt-get install -y --no-install-recommends \
      software-properties-common \
   && add-apt-repository -y universe \
   && apt-get install -y --no-install-recommends \
      build-essential pkgconf git \
      nasm yasm \
      zlib1g-dev \
      libssl-dev \
      libsrt-openssl-dev \
      libsrt1.5-openssl \
      libffmpeg-nvenc-dev \
      libfdk-aac-dev \
   && rm -rf /var/lib/apt/lists/*

ENV CUDA_HOME=/usr/local/cuda
ENV PATH=/usr/local/cuda/bin:${PATH}
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH}

RUN git clone --depth 1 --branch "$FFMPEG_NV_CODEC_HEADERS_VERSION" \
      "$FFMPEG_NV_CODEC_HEADERS_REPO" /opt/nv-codec-headers \
   && make -C /opt/nv-codec-headers install PREFIX=/usr \
   && git clone --depth 1 --branch "$FFMPEG_VERSION" "$FFMPEG_REPO" /opt/ffmpeg-src \
   && cd /opt/ffmpeg-src \
   && set -xeuo \
   && which nvcc && nvcc --version && gcc --version && echo $PATH \
   && echo "$(pwd)" && ls -la . \
   && ./configure \
      --prefix="/usr" \
      --disable-shared --enable-static \
      --extra-cflags="-I/usr/local/cuda/include" \
      --extra-ldflags="-L/usr/local/cuda/lib64" \
      --nvccflags="-gencode arch=compute_75,code=sm_75 -O2" \
      --extra-libs="-lpthread -lm" \
      --disable-doc --disable-debug \
      \
      --enable-nonfree \
      --enable-openssl \
      --enable-libsrt \
      --enable-libfdk_aac \
      \
      --enable-ffnvcodec \
      --enable-nvenc \
      --enable-cuda-nvcc \
      --enable-filter=scale_cuda \
      \
      --enable-protocol=rtmp \
      \
      --enable-muxer=flv \
      --enable-muxer=mpegts \
      --enable-demuxer=flv \
      --enable-demuxer=mpegts \
      \
      --enable-encoder=aac \
      --enable-encoder=pcm_s24le \
      --enable-decoder=aac \
      --enable-decoder=pcm_s24le || true \
   && make -C /opt/ffmpeg-src -j$NPROC

   # && cat /opt/ffmpeg-src/ffbuild/config.log \

RUN cd /opt/ffmpeg-src \
   && ls -la \
   && make install DESTDIR=/opt/ffmpeg-dist \
   && readelf -h /opt/ffmpeg-dist/usr/bin/ffmpeg \
   && readelf -d /opt/ffmpeg-dist/usr/bin/ffmpeg | grep NEEDED || true \
   && tar -cvf /opt/ffmpeg.tar -C /opt/ffmpeg-dist usr/bin


FROM debian:trixie-20260202-slim AS runtime

ARG FFMPEG_VERSION="8.0.1-r1"
ARG FISH_SHELL_VERSION="4.0.2-r0"
ARG ENVSUBST_VERSION="0.24.1-r1"
ARG MEDIAMTX_BIN_URL="https://github.com/bluenviron/mediamtx/releases/download/v1.17.0/mediamtx_v1.17.0_linux_amd64.tar.gz"
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility,video

COPY --from=ffmpeg_build /opt/ffmpeg.tar /opt/

RUN cat /etc/apt/sources.list.d/debian.sources \
   && sed -i -E 's/^Components:[[:space:]]*main[[:space:]]*$/Components: main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources \
   && apt-get update \
   && apt-get install -y --no-install-recommends \
      ca-certificates \
      fish \
      gettext-base \
      libsrt1.5-openssl \
      libfdk-aac2t64 \
      wget  \
   && rm -rf /var/lib/apt/lists/* \
   && tar -xvf /opt/ffmpeg.tar -C / \
   && rm -rf /opt/ffmpeg.tar \
   && echo "Hello from strimserver"

# COPY mediamtx.yaml.template /opt/mediamtx.yaml.template
COPY mediamtx-entrypoint.sh /opt/mediamtx-entrypoint.sh
# COPY transcodelib.sh /opt/transcodelib.sh

RUN mkdir -p /opt/mediamtx \
   && wget $MEDIAMTX_BIN_URL -O /opt/mediamtx/mediamtx.tar.gz \
   && cd /opt/mediamtx \
   && tar -xzvf mediamtx.tar.gz \
   && ls -la \
   && ldd mediamtx || true \
   && ./mediamtx --version \
   && ./mediamtx --help \
   && install /opt/mediamtx/mediamtx /usr/local/bin/ \
   && rm -rf /opt/mediamtx \
   && ffmpeg -version \
   && ffmpeg -h encoder=h264_nvenc \
   && ffmpeg -h encoder=hevc_nvenc \
   && chmod +x /opt/mediamtx-entrypoint.sh
   # && chmod +x /opt/transcodelib.sh

ENTRYPOINT [ "/opt/mediamtx-entrypoint.sh" ]



