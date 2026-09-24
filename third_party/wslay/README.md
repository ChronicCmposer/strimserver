# third_party/wslay: Vendored wslay (v1.1.1, MIT)

wslay (https://github.com/tatsuhiro-t/wslay) provides RFC 6455 WebSocket
framing for the C controller rewrite. It does not do the HTTP/1.1 Upgrade
handshake — that is the application's job (here: libmicrohttpd with
`MHD_ALLOW_UPGRADE` hands the accepted socket to wslay). No TLS.

| Item | Value |
|------|-------|
| Version | 1.1.1 (latest release, 2021-06-01) |
| Source | `https://github.com/tatsuhiro-t/wslay/releases/download/release-1.1.1/wslay-1.1.1.tar.gz` |
| Tarball sha256 | `90ce68c6dfd614722d44fbb14563a3f6dacc68b548b20ae382ac4f4952c55268` |
| License | MIT (`LICENSE`, upstream `COPYING`) |

The vendored sources are byte-identical copies from the release tarball
(`lib/wslay_{net,frame,queue,event}.c` + the `lib/*.h` internal headers and
the `lib/includes/wslay/wslay.h` public header). `config.h` is committed
(same pattern as libmicrohttpd's `MHD_config.h`): upstream's autotools
configure generates it; the sources gate on `HAVE_ARPA_INET_H` /
`HAVE_NETINET_IN_H` (both present on glibc) and `WORDS_BIGENDIAN`
(undefined: both target arches are little-endian). It is pulled in via
`#include <config.h>` guarded by `HAVE_CONFIG_H`, defined on the compile
command line. No patches beyond that.

Note: the compiled sources are `wslay_net.c`, `wslay_frame.c`,
`wslay_queue.c`, `wslay_event.c` — wslay 1.1.1 ships `wslay_net.c` (socket
helpers), not the `wslay.c` of older releases.

Targets:

- `//third_party/wslay:wslay` — `cc_library`, static, dual-arch
  (linux/amd64 + linux/arm64); consumers get `#include <wslay/wslay.h>`.
- `//third_party/wslay:wslay_smoke_test` — `cc_test`, client + server echo
  over a socketpair using the event API.