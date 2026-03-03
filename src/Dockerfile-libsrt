# vim: set ft=dockerfile :

FROM debian:trixie-20260202-slim AS build 

ARG LIBSRT_REPO="https://github.com/Haivision/srt.git"
ARG LIBSRT_VERSION="v1.5.4" 


RUN apt-get update -y \
   && apt-get install -y \
      ca-certificates \
      build-essential \
      pkg-config \
      cmake \
      git \
      libssl-dev

RUN mkdir -p /opt/libsrt-src \
   && git clone --depth 1 --no-checkout $LIBSRT_REPO /opt/libsrt-src \
   && cd /opt/libsrt-src \
   && git fetch --depth 1 origin tag $LIBSRT_VERSION \
   && git checkout "tags/$LIBSRT_VERSION" \
   && mkdir _build && cd _build \
   && cmake .. -DENABLE_UNITTESTS=ON \
   && cmake --build ./


RUN cd /opt/libsrt-src/_build \
  && ls -la . \
  && ./test-srt
