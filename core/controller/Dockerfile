

FROM golang:1.26.4-alpine3.24 AS build

COPY *.go go.mod /opt/strimserver-controller/
ARG CACHEBUST=0

RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
   set -x && go version \
   && echo "cachebust=$CACHEBUST" \
   && cd /opt/strimserver-controller \
   && go build -v -o strimserver-controller .

# -------------------------------------------------

FROM golang:1.26.4-alpine3.24 AS test

COPY *.go go.mod /opt/strimserver-controller/
ARG CACHEBUST=0

RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
   set -x && go version \
   && echo "cachebust=$CACHEBUST" \
   && cd /opt/strimserver-controller \
   && go test -v .

