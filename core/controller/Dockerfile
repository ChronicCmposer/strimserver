

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

COPY *.go go.mod .golangci.yml /opt/strimserver-controller/
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

