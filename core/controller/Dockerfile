

FROM golang:1.26.4-alpine3.24 AS build

COPY *.go go.mod go.sum /opt/strimserver-controller/
ARG CACHEBUST=0

RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
   set -x && go version \
   && echo "cachebust=$CACHEBUST" \
   && cd /opt/strimserver-controller \
   && CGO_ENABLED=0 GOOS=linux \
      go build -v -trimpath -ldflags='-s -w' -o strimserver-controller .

# -------------------------------------------------

FROM golang:1.26.4-alpine3.24 AS test

COPY *.go go.mod go.sum .golangci.yml /opt/strimserver-controller/
ARG CACHEBUST=0
ARG ENABLE_LINT=0

RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
   set -x && go version \
   && echo "cachebust=$CACHEBUST" \
   && cd /opt/strimserver-controller \
   && if [ "$ENABLE_LINT" = "true" ]; then go install github.com/golangci/golangci-lint/cmd/golangci-lint@v1.64.8; fi \
   && if [ "$ENABLE_LINT" = "true" ]; then golangci-lint run; fi \
   && go test -v .

# -------------------------------------------------

FROM debian:trixie-20260518-slim AS libs

RUN set -x \
   && apt-get update \
   && apt-get install -y --no-install-recommends dash \
   && rm -rf /var/lib/apt/lists/*

# -------------------------------------------------

FROM scratch AS runtime

COPY --from=libs  /bin/dash   /bin/sh
COPY --from=libs  /lib64/ld-linux-x86-64.so.2   /lib64/
COPY --from=libs  /lib/x86_64-linux-gnu/libc.so.6  /lib/x86_64-linux-gnu/


COPY --from=build /opt/strimserver-controller/strimserver-controller /strimserver-controller

COPY --chmod=755 entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
