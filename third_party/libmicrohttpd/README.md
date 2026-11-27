# third_party/libmicrohttpd: libmicrohttpd (v1.0.10, LGPL 2.1+)

libmicrohttpd (https://www.gnu.org/software/libmicrohttpd/) is the HTTP/1.1
REST server for the C controller rewrite. The controller is
single-threaded-core, so MHD runs in external event loop mode (no internal
thread; `MHD_run()`/`MHD_run_wait()` folded into the controller's main loop)
or with `MHD_USE_INTERNAL_POLLING_THREAD`. `MHD_ALLOW_UPGRADE` (enabled
below) hands the accepted socket to wslay for WebSocket framing.

| Item | Value |
|------|-------|
| Version | 1.0.10 (released 2025-08-07, the latest 1.0.x) |
| Source | `https://ftp.gnu.org/gnu/libmicrohttpd/libmicrohttpd-1.0.10.tar.gz` |
| Tarball sha256 | `04bfe8ef75db7d629a33de767599765cecadc56274a39822d5d081030d577685` |
| License | GNU LGPL 2.1+ (`COPYING`, upstream `COPYING`) |

The library sources are no longer vendored in-tree: they are fetched from the
pinned upstream release tarball by `MODULE.bazel`'s `http_archive` and built in
the external `@libmicrohttpd` repo by `BUILD.libmicrohttpd`. `MHD_config.h` is
the configure-generated feature header overlaid into that repo (see
`BUILD.libmicrohttpd` and the header comment for the two documented patches:
`HAVE_STDBOOL_H` and `_GNU_SOURCE`).

Feature set (upstream configure flags):
`--disable-https --disable-bauth --disable-dauth --disable-postprocessor
--disable-curl --enable-httpupgrade --enable-epoll`. That yields no TLS, no
auth, no postprocessor, HTTP Upgrade support (MHD_ALLOW_UPGRADE),
`EPOLL_SUPPORT`, `MHD_USE_POSIX_THREADS`, `MHD_USE_SYS_TSEARCH`. Only the 14
enabled-feature `.c` files are compiled; the feature-disabled sources are not
in the overlay's `srcs` list.

Targets:

- `@libmicrohttpd//:libmicrohttpd` — `cc_library`, static, dual-arch
  (linux/amd64 + linux/arm64); consumers get `#include <microhttpd.h>` and
  link `-lpthread`.
- `//third_party/libmicrohttpd:mhd_smoke_test` — `cc_test`, GET /healthz via
  internal polling thread + external event loop.

## Source availability (LGPL-2.1-or-later)

This library is used under **LGPL-2.1-or-later**. The complete corresponding
source is the pinned upstream tarball identified by URL and `sha256` above (and
in `pin.json`); the build definitions are `MODULE.bazel` plus
`third_party/libmicrohttpd/BUILD.libmicrohttpd`; the license text is `COPYING`.
