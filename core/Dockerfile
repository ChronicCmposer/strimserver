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
   && make -C /opt/ffmpeg-src -j$NPROC

   # && cat /opt/ffmpeg-src/ffbuild/config.log \

RUN cd /opt/ffmpeg-src \
   && ls -la \
   && make install DESTDIR=/opt/ffmpeg-dist \
   && readelf -h /opt/ffmpeg-dist/usr/local/bin/ffmpeg \
   && readelf -d /opt/ffmpeg-dist/usr/local/bin/ffmpeg | grep NEEDED || true \
   && tar -cvf /opt/ffmpeg.tar -C /opt/ffmpeg-dist . 

# --------------------------------------------

FROM debian:trixie-20260202-slim AS runtime

# ARG FFMPEG_VERSION="8.0.1-r1"
ARG FISH_SHELL_VERSION="4.0.2-r0"
ARG ENVSUBST_VERSION="0.24.1-r1"
ARG MEDIAMTX_BIN_URL="https://github.com/bluenviron/mediamtx/releases/download/v1.17.0/mediamtx_v1.17.0_linux_amd64.tar.gz"
ARG OBS_BIN_URL="https://github.com/obsproject/obs-studio/releases/download/32.1.2/OBS-Studio-32.1.2-Ubuntu-24.04-x86_64.deb"
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
      libfdk-aac2t64 \
      wget  \
      obs-studio \
   && rm -rf /var/lib/apt/lists/* \
   && tar -xvf /opt/ffmpeg.tar -C / \
   && rm -rf /opt/ffmpeg.tar \
   && echo "/usr/local/lib/x86_64-linux-gnu" > /etc/ld.so.conf.d/usr-local-x86_64-linux-gnu.conf \
   && ldconfig

COPY entrypoint.sh /opt/strimserver/entrypoint.sh

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
   && obs --version \
   && ffmpeg -version \
   && ffmpeg -h encoder=h264_nvenc \
   && ffmpeg -h encoder=hevc_nvenc \
   && chmod +x /opt/strimserver/entrypoint.sh

ENTRYPOINT [ "/opt/strimserver/entrypoint.sh" ]



