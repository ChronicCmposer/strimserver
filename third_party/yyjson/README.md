# third_party/yyjson: Vendored yyjson (v0.13.0, MIT)

yyjson (https://github.com/ibireme/yyjson) is the JSON library for the C
controller rewrite: fastest pure-C JSON, RFC 8259 strict. The single-file
(amalgamated) distribution is vendored here.

| Item | Value |
|------|-------|
| Version | 0.13.0 (release commit `6447536015f3d600f3d65323b10976103b337ca7`, published 2026-09-08) |
| Source | `https://github.com/ibireme/yyjson/archive/refs/tags/0.13.0.tar.gz` |
| Tarball sha256 | `34e0f62a2bc11ab20d601e8ca1cc2b2079503aa45119a19133d89d19b94a0fae` |
| `yyjson.c` sha256 | `d2d58ef0a3b2267862dc363832c4f3185fd375aea933d5d3419d1a940d6ece2e` |
| `yyjson.h` sha256 | `ef803cda5c06b8962face6dfa39c3284b3bcf3e73f4d7317664690cc779679ca` |
| `LICENSE` sha256 | `45e384d3d52c73cba3a64d6e6c25d47cd738cd8a55c30629e3201046eda62947` |
| License | MIT (`LICENSE`, upstream `LICENSE`) |

The upstream 0.13.0 release tarball ships the amalgamated files under `src/`;
the committed `yyjson.c` / `yyjson.h` are byte-identical copies (verified by
sha256 above). No patches are applied.

Targets:

- `//third_party/yyjson:yyjson` — `cc_library`, static, dual-arch
  (linux/amd64 + linux/arm64); consumers get `#include "yyjson.h"`.
- `//third_party/yyjson:yyjson_smoke_test` — `cc_test`, parse + read +
  mutable-build + write + re-parse round trip.