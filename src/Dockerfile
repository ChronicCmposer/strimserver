FROM nvidia/cuda:13.1.0-devel-ubuntu24.04 AS ffmpeg_build

ARG FFMPEG_REPO="https://github.com/FFmpeg/FFmpeg.git"
ARG FFMPEG_VERSION="2f547c4022786ef985992e6d534f761909afefd5"
ARG NPROC=6



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


RUN git clone --depth 1 --no-checkout $FFMPEG_REPO /opt/ffmpeg-src \
   && cd /opt/ffmpeg-src \
   && git fetch --depth 1 origin $FFMPEG_VERSION \
   && git checkout $FFMPEG_VERSION \
   && set -xeuo \
   && ./configure \
      --prefix="/usr" \
      --disable-shared --enable-static \
      --pkg-config-flags="--static" \
      --extra-libs="-lpthread -lm" \
      --disable-doc --disable-debug \
      \
      --enable-openssl \
      --enable-libsrt \
      --enable-nvenc \
      --enable-libfdk_aac \
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
   && grep -n -A20 -B20 'srt' ffbuild/config.log \
   && make -j$NPROC


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
ARG MEDIAMTX_BIN_URL="https://github.com/bluenviron/mediamtx/releases/download/v1.16.1/mediamtx_v1.16.1_linux_amd64.tar.gz"
ENV NVIDIA_DRIVER_CAPABILITIES="video"

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

COPY mediamtx.yaml.template /opt/mediamtx.yaml.template
COPY mediamtx-entrypoint.sh /opt/mediamtx-entrypoint.sh
COPY egress-ffmpeg.sh /opt/egress-ffmpeg.sh

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
   && ffmpeg -h encoder=libfdk_aac \
   && chmod +x /opt/mediamtx-entrypoint.sh \
   && chmod +x /opt/egress-ffmpeg.sh

ENTRYPOINT [ "/opt/mediamtx-entrypoint.sh" ]



