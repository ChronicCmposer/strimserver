

FROM alpine:3.23.4 AS build

RUN set -x && apk add --no-cache go git ca-certificates

RUN set -x && go version \
   && mkdir -p /opt/strimserver-controller \
   && cd /opt/strimserver-controller \
   && go mod init chroniccmposer/strimserver-controller \
   && date +%s%3N > /foo.txt

COPY controller.go /opt/strimserver-controller/main.go

RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
   set -x \
   && cd /opt/strimserver-controller \
   && go build -v -o strimserver-controller . \
   && ls -la
   # && ./strimserver-controller

FROM scratch AS output 

COPY --from=build /foo.txt /foo.txt 


