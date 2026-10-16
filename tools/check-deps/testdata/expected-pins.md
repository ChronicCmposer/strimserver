# expected-pins.md — RED oracle for the check-deps extractor wave

Human-readable companion to `expected-pins.json`. It enumerates every pin token
the **new extractors** are expected to surface, grouped by source and derived
from the **actual working tree** (no invented values).

## How to read this

- `kind=version` → `version` holds a version / tag / commit / date / AMI-id /
  epoch.
- `kind=integrity` → `version` holds a sha256/sha digest (names of digest rows
  carry a `:sha256` suffix so `(source,file,name)` stays unique).
- `tracked_now=yes` → the **current committed-baseline** check-deps pipeline
  already surfaces this pin (the `extractorimpl` extractors plus the native
  `go list -u` / `pnpm outdated` batch resolver in `main.go`).
- `tracked_now=no` → a new extractor must surface it (MODULE.bazel custom rules,
  extra shell-script pins, `.env`, Stream Deck manifest fields, CI `with:`
  inputs, lockfile-transitive inventory, `third_party/*/pin.json`).

> Secrets in `.env` (Twitch keys, DDNS password) are deliberately **not**
> enumerated.

## Summary counts

| Metric | Count |
|---|---|
| Total pin tokens | **195** |
| Currently tracked (`tracked_now=yes`) | **86** |
| Newly to track (`tracked_now=no`) | **109** |
| Distinct sources | **31** |

### Counts by source

| Source | Entries |
|---|---|
| MODULE.bazel:http_archive | 22 |
| MODULE.bazel:http_file | 4 |
| MODULE.bazel:bazel_dep | 14 |
| MODULE.bazel:single_version_override | 2 |
| MODULE.bazel:apt.sources_list | 1 |
| MODULE.bazel:apt.install | 13 |
| MODULE.bazel:oci.pull | 1 |
| MODULE.bazel:tarball_strip_symlinks | 2 |
| MODULE.bazel:deb_extract | 6 |
| MODULE.bazel:amd64_sysroot | 6 |
| MODULE.bazel:s3_http_archive | 4 |
| MODULE.bazel:s3_http_file | 6 |
| MODULE.bazel:qemu_x86_64 repo rule | 1 |
| tools/qemu/build-qemu.sh | 7 |
| tools/bazel/qemu_x86_64.bzl | 1 |
| tools/openssh/build.sh | 5 |
| tools/openssh/publish.sh | 4 |
| tools/ffmpeg-dist/build.sh | 7 |
| tools/ffmpeg-dist/publish.sh | 8 |
| scripts/upload-artifact.sh | 1 |
| deploy/aws/fish-deploy.sh | 2 |
| deploy/aws/launch | 3 |
| third_party/pin.json | 18 |
| .env | 14 |
| streamdeck manifest | 4 |
| package.json | 10 |
| CI with inputs | 6 |
| CI uses | 8 |
| toolchain | 3 |
| core/controller/go.mod require | 8 |
| lockfile transitive inventory | 4 |

## Full inventory

| source | file | name | version | kind | tracked_now |
|---|---|---|---|---|---|
| MODULE.bazel:http_archive | `MODULE.bazel` | golangci_lint_linux_amd64 | 2.14.0 | version | yes |
| MODULE.bazel:http_archive | `MODULE.bazel` | golangci_lint_linux_amd64:sha256 | ab90aeb7b066f92a33415b638a50fe5344bbb75a0d32ad30cc248d88f81032ab | integrity | yes |
| MODULE.bazel:http_archive | `MODULE.bazel` | golangci_lint_linux_arm64 | 2.14.0 | version | yes |
| MODULE.bazel:http_archive | `MODULE.bazel` | golangci_lint_linux_arm64:sha256 | ee7ec5f3453d15ddf106fae5a4d6c71737712348a979d1fe9cd52ec7ea299bae | integrity | yes |
| MODULE.bazel:http_archive | `MODULE.bazel` | protobuf_c | 1.5.2 | version | yes |
| MODULE.bazel:http_archive | `MODULE.bazel` | protobuf_c:sha256 | e2c86271873a79c92b58fef7ebf8de1aa0df4738347a8bd5d4e65a80a16d0d24 | integrity | yes |
| MODULE.bazel:http_archive | `MODULE.bazel` | protoc_linux_aarch64 | 36.2 | version | no |
| MODULE.bazel:http_archive | `MODULE.bazel` | protoc_linux_aarch64:sha256 | 8b8f18bd2b30346efbc698dd5a73dd7c805f3ef8380f6dfc95c768f3f1852f6a | integrity | no |
| MODULE.bazel:http_archive | `MODULE.bazel` | protoc_linux_x86_64 | 36.2 | version | no |
| MODULE.bazel:http_archive | `MODULE.bazel` | protoc_linux_x86_64:sha256 | 121f6c7afe1d4d0e3ea6aab9432038599250134cbf4474cb1167d2c7decd4278 | integrity | no |
| MODULE.bazel:http_archive | `MODULE.bazel` | containerd_api | 1.12.0 | version | yes |
| MODULE.bazel:http_archive | `MODULE.bazel` | containerd_api:sha256 | 6978892e8ab09b36f5c09311f856ae07411cd9efd76a5213d125a733f08753fa | integrity | yes |
| MODULE.bazel:http_archive | `MODULE.bazel` | curl | 8.23.0 | version | yes |
| MODULE.bazel:http_archive | `MODULE.bazel` | curl:sha256 | e3de77cfa6367083c776a26647fc9f633b538c06c3baa73d931a252ac8f72b49 | integrity | yes |
| MODULE.bazel:http_archive | `MODULE.bazel` | mbedtls | 3.6.7 | version | yes |
| MODULE.bazel:http_archive | `MODULE.bazel` | mbedtls:sha256 | a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6 | integrity | yes |
| MODULE.bazel:http_archive | `MODULE.bazel` | cares | 1.34.8 | version | yes |
| MODULE.bazel:http_archive | `MODULE.bazel` | cares:sha256 | c222b6d681096f9444d2c4863d2c1174019e27cacca0a4a5c114d36dd7d7bf78 | integrity | yes |
| MODULE.bazel:http_archive | `MODULE.bazel` | mediamtx_dist | 1.21.2 | version | yes |
| MODULE.bazel:http_archive | `MODULE.bazel` | mediamtx_dist:sha256 | 121be6e00397e473a95d83c75f4fcd3819a6af3b0e1a50889cba43ab4fab6a27 | integrity | yes |
| MODULE.bazel:http_archive | `MODULE.bazel` | mediamtx_dist_arm64 | 1.21.2 | version | yes |
| MODULE.bazel:http_archive | `MODULE.bazel` | mediamtx_dist_arm64:sha256 | 180a235374a548d9133cdd5e20f5dbd8b01317be1c86e0d7e66df585dc42ed6f | integrity | yes |
| MODULE.bazel:http_file | `MODULE.bazel` | iperf3_apk | 3.19.1-r1 | version | yes |
| MODULE.bazel:http_file | `MODULE.bazel` | iperf3_apk:sha256 | c8fa78ac30761d2dc47d5db7b9056a3b5cfdd565af173a4be1e4449a6b7fd664 | integrity | yes |
| MODULE.bazel:http_file | `MODULE.bazel` | iperf3_apk_arm64 | 3.19.1-r1 | version | yes |
| MODULE.bazel:http_file | `MODULE.bazel` | iperf3_apk_arm64:sha256 | da2a7b7eaaa0fc1427897999578cef7deb9b283fe220ac0ae38f80e1fc584199 | integrity | yes |
| MODULE.bazel:bazel_dep | `MODULE.bazel` | platforms | 1.1.0 | version | yes |
| MODULE.bazel:bazel_dep | `MODULE.bazel` | bazel_skylib | 1.9.2 | version | yes |
| MODULE.bazel:bazel_dep | `MODULE.bazel` | rules_shell | 0.8.0 | version | yes |
| MODULE.bazel:bazel_dep | `MODULE.bazel` | rules_cc | 0.2.26 | version | yes |
| MODULE.bazel:bazel_dep | `MODULE.bazel` | hermetic_cc_toolchain | 4.3.0 | version | yes |
| MODULE.bazel:bazel_dep | `MODULE.bazel` | rules_go | 0.64.2 | version | yes |
| MODULE.bazel:bazel_dep | `MODULE.bazel` | gazelle | 0.54.0 | version | yes |
| MODULE.bazel:bazel_dep | `MODULE.bazel` | aspect_bazel_lib | 2.22.5 | version | yes |
| MODULE.bazel:bazel_dep | `MODULE.bazel` | rules_distroless | 0.9.4 | version | yes |
| MODULE.bazel:bazel_dep | `MODULE.bazel` | rules_oci | 2.3.0 | version | yes |
| MODULE.bazel:bazel_dep | `MODULE.bazel` | rules_pkg | 1.3.0 | version | yes |
| MODULE.bazel:bazel_dep | `MODULE.bazel` | aspect_rules_js | 3.5.1 | version | yes |
| MODULE.bazel:bazel_dep | `MODULE.bazel` | aspect_rules_ts | 3.10.1 | version | yes |
| MODULE.bazel:bazel_dep | `MODULE.bazel` | rules_nodejs | 6.7.6 | version | yes |
| MODULE.bazel:single_version_override | `MODULE.bazel` | aspect_bazel_lib | 2.22.5 | version | yes |
| MODULE.bazel:single_version_override | `MODULE.bazel` | bazel_lib | 3.7.2 | version | yes |
| MODULE.bazel:apt.sources_list | `MODULE.bazel` | debian | 20261005T000000Z | version | yes |
| MODULE.bazel:apt.install | `MODULE.bazel` | dash | — | version | no |
| MODULE.bazel:apt.install | `MODULE.bazel` | busybox-static | — | version | no |
| MODULE.bazel:apt.install | `MODULE.bazel` | gettext-base | — | version | no |
| MODULE.bazel:apt.install | `MODULE.bazel` | ca-certificates | — | version | no |
| MODULE.bazel:apt.install | `MODULE.bazel` | libfdk-aac2t64 | — | version | no |
| MODULE.bazel:apt.install | `MODULE.bazel` | libc6 | — | version | no |
| MODULE.bazel:apt.install | `MODULE.bazel` | coreutils | — | version | no |
| MODULE.bazel:apt.install | `MODULE.bazel` | libbinutils | — | version | no |
| MODULE.bazel:apt.install | `MODULE.bazel` | libsframe1 | — | version | no |
| MODULE.bazel:apt.install | `MODULE.bazel` | zlib1g | — | version | no |
| MODULE.bazel:apt.install | `MODULE.bazel` | libzstd1 | — | version | no |
| MODULE.bazel:apt.install | `MODULE.bazel` | libgcc-s1 | — | version | no |
| MODULE.bazel:apt.install | `MODULE.bazel` | binutils-x86-64-linux-gnu | — | version | no |
| MODULE.bazel:oci.pull | `MODULE.bazel` | alpine | sha256:25109184c71bdad752c8312a8623239686a9a2071e8825f20acb8f2198c3f659 | integrity | yes |
| MODULE.bazel:tarball_strip_symlinks | `MODULE.bazel` | libwebsockets | 5.0.0 | version | no |
| MODULE.bazel:tarball_strip_symlinks | `MODULE.bazel` | libwebsockets:sha256 | f853c6582101cfcee3a5a9e28ae92ab19d9735c5f31f0bb2e9794b5106123962 | integrity | no |
| MODULE.bazel:deb_extract | `MODULE.bazel` | libprotobuf_dev_arm64 | 3.21.12-11+deb13u1 | version | no |
| MODULE.bazel:deb_extract | `MODULE.bazel` | libprotobuf_dev_arm64:sha256 | 26e311a867ef831d2378a33e772b1f21924261eedcefe08f7ce852c6176c2836 | integrity | no |
| MODULE.bazel:deb_extract | `MODULE.bazel` | libprotoc_dev_arm64 | 3.21.12-11+deb13u1 | version | no |
| MODULE.bazel:deb_extract | `MODULE.bazel` | libprotoc_dev_arm64:sha256 | 405ec6e7b5dd99b73a84f4671af03b0b0d94b4a372c36a49c0f94457f40b36a9 | integrity | no |
| MODULE.bazel:deb_extract | `MODULE.bazel` | protobuf_compiler_arm64 | 3.21.12-11+deb13u1 | version | no |
| MODULE.bazel:deb_extract | `MODULE.bazel` | protobuf_compiler_arm64:sha256 | a873f75cbdf8054a23687e7c9b39ca1a93545edd22a581f4caa560756678f658 | integrity | no |
| MODULE.bazel:amd64_sysroot | `MODULE.bazel` | amd64_sysroot:libc6 | 2.41-11cross1 | version | no |
| MODULE.bazel:amd64_sysroot | `MODULE.bazel` | amd64_sysroot:libc6:sha256 | 54ef8425cbc7c45888981e6ef23529df4d056688a6c71a415fcc95a404522b9f | integrity | no |
| MODULE.bazel:amd64_sysroot | `MODULE.bazel` | amd64_sysroot:libgcc | 14.2.0-19cross1 | version | no |
| MODULE.bazel:amd64_sysroot | `MODULE.bazel` | amd64_sysroot:libgcc:sha256 | c6642e5d83ad232573c2a45efb5b407b06eb61af2220eb1c922d0380dd446286 | integrity | no |
| MODULE.bazel:amd64_sysroot | `MODULE.bazel` | amd64_sysroot:linux_libc | 6.12.38-1cross1 | version | no |
| MODULE.bazel:amd64_sysroot | `MODULE.bazel` | amd64_sysroot:linux_libc:sha256 | da463ddd3ee96b37c33f16da99c47b03b4e514888d3d853e73253ee73bd0d7d8 | integrity | no |
| MODULE.bazel:s3_http_archive | `MODULE.bazel` | ffmpeg_dist | 8.1 | version | no |
| MODULE.bazel:s3_http_archive | `MODULE.bazel` | ffmpeg_dist:sha256 | 44021ca11d9c5a3f1921b57150dfe68562cb291658afbef40b231a3554a82120 | integrity | no |
| MODULE.bazel:s3_http_archive | `MODULE.bazel` | ffmpeg_dist_arm64 | 8.1 | version | no |
| MODULE.bazel:s3_http_archive | `MODULE.bazel` | ffmpeg_dist_arm64:sha256 | ba285eba5bd32fa2095a59dcf5c16822c02c964889de58478569ba93e34c910c | integrity | no |
| MODULE.bazel:s3_http_file | `MODULE.bazel` | offline_segment_dist | — | version | no |
| MODULE.bazel:s3_http_file | `MODULE.bazel` | offline_segment_dist:sha256 | 05ff15e41a61e9478b005135699a130e21a7efab21b6a1bcae1aa30bd3182f7d | integrity | no |
| MODULE.bazel:s3_http_file | `MODULE.bazel` | openssh_dist | — | version | no |
| MODULE.bazel:s3_http_file | `MODULE.bazel` | openssh_dist:sha256 | 05a2869d27c59c22aaccbad738a91b08f397a82a066c2d6ade4ed68ac00cc8fd | integrity | no |
| MODULE.bazel:s3_http_file | `MODULE.bazel` | openssh_dist_arm64 | — | version | no |
| MODULE.bazel:s3_http_file | `MODULE.bazel` | openssh_dist_arm64:sha256 | 613a9a8366beb76b8299b5d077e611b7acc7ed46deecab73b9ccf5ea56e1423d | integrity | no |
| MODULE.bazel:qemu_x86_64 repo rule | `MODULE.bazel` | qemu_x86_64_patched | 11.0.4 | version | yes |
| tools/qemu/build-qemu.sh | `tools/qemu/build-qemu.sh` | distlib | 0.4.3 | version | yes |
| tools/qemu/build-qemu.sh | `tools/qemu/build-qemu.sh` | distlib-0.4.3-py2.py3-none-any.whl:sha256 | 4b0ce306c966eb73bc3a7b6abad017c556dadd92c44701562cd528ac7fde4d5b | integrity | no |
| tools/qemu/build-qemu.sh | `tools/qemu/build-qemu.sh` | qemu | 8.2.2 | version | no |
| tools/qemu/build-qemu.sh | `tools/qemu/build-qemu.sh` | qemu-8.2.2.tar.xz:sha256 | 847346c1b82c1a54b2c38f6edbd85549edeb17430b7d4d3da12620e2962bc4f3 | integrity | no |
| tools/qemu/build-qemu.sh | `tools/qemu/build-qemu.sh` | qemu-9.2.4.tar.xz:sha256 | f3cc1c4eabfdb288218ac3e33763dbe9e276d8bc890b867a2335d58de2ddd39a | integrity | no |
| tools/qemu/build-qemu.sh | `tools/qemu/build-qemu.sh` | qemu-11.0.2.tar.xz:sha256 | 3745f6ea88e2e87fe0dc838b2b1d4e0a770bf48e01a1d5a186842a1fff76ccf5 | integrity | no |
| tools/qemu/build-qemu.sh | `tools/qemu/build-qemu.sh` | qemu-11.0.4.tar.xz:sha256 | b099a10abe4a98ac1a53a4f52cb2367651ad9fcd1c0531beb14921f1524ca9ae | integrity | no |
| tools/bazel/qemu_x86_64.bzl | `tools/bazel/qemu_x86_64.bzl` | qemu | 11.0.4 | version | yes |
| tools/openssh/build.sh | `tools/openssh/build.sh` | openssh-portable | 10.6p1 | version | yes |
| tools/openssh/build.sh | `tools/openssh/build.sh` | OPENSSH_TAG | V_10_6_P1 | version | no |
| tools/openssh/build.sh | `tools/openssh/build.sh` | GNU m4 | 1.4.21 | version | yes |
| tools/openssh/build.sh | `tools/openssh/build.sh` | m4-1.4.21.tar.gz:sha256 | 38ae59f7a30bf9c108193cc5c25fbb06014f21e230c7ede2eff614f7b7c37ed8 | integrity | no |
| tools/openssh/build.sh | `tools/openssh/build.sh` | SOURCE_DATE_EPOCH | 1786924800 | version | no |
| tools/openssh/publish.sh | `tools/openssh/publish.sh` | openssh-portable | 10.6p1 | version | yes |
| tools/openssh/publish.sh | `tools/openssh/publish.sh` | OPENSSH_TAG | V_10_6_P1 | version | no |
| tools/openssh/publish.sh | `tools/openssh/publish.sh` | amazonlinux | 2023.12.20260817.0 | version | yes |
| tools/openssh/publish.sh | `tools/openssh/publish.sh` | qemu | 9.2.4 | version | yes |
| tools/ffmpeg-dist/build.sh | `tools/ffmpeg-dist/build.sh` | ffmpeg | 8.1 | version | yes |
| tools/ffmpeg-dist/build.sh | `tools/ffmpeg-dist/build.sh` | FFMPEG_COMMIT | 1a748fe2cd43e3ead22fafb1b5b7d77f153898a8 | version | no |
| tools/ffmpeg-dist/build.sh | `tools/ffmpeg-dist/build.sh` | nv-codec-headers | n13.0.19.1 | version | yes |
| tools/ffmpeg-dist/build.sh | `tools/ffmpeg-dist/build.sh` | NV_CODEC_HEADERS_COMMIT | 88fee5c37318c991a8762d423530f91681e32e3a | version | no |
| tools/ffmpeg-dist/build.sh | `tools/ffmpeg-dist/build.sh` | CUDA | 13.2.2 | version | yes |
| tools/ffmpeg-dist/build.sh | `tools/ffmpeg-dist/build.sh` | debian | 20261005T000000Z | version | yes |
| tools/ffmpeg-dist/build.sh | `tools/ffmpeg-dist/build.sh` | GENCODE | arch=compute_75,code=sm_75 | version | no |
| tools/ffmpeg-dist/publish.sh | `tools/ffmpeg-dist/publish.sh` | ffmpeg | 8.1 | version | yes |
| tools/ffmpeg-dist/publish.sh | `tools/ffmpeg-dist/publish.sh` | FFMPEG_COMMIT | 1a748fe2cd43e3ead22fafb1b5b7d77f153898a8 | version | no |
| tools/ffmpeg-dist/publish.sh | `tools/ffmpeg-dist/publish.sh` | nv-codec-headers | n13.0.19.1 | version | yes |
| tools/ffmpeg-dist/publish.sh | `tools/ffmpeg-dist/publish.sh` | NV_CODEC_HEADERS_COMMIT | 88fee5c37318c991a8762d423530f91681e32e3a | version | no |
| tools/ffmpeg-dist/publish.sh | `tools/ffmpeg-dist/publish.sh` | CUDA | 13.2.2 | version | yes |
| tools/ffmpeg-dist/publish.sh | `tools/ffmpeg-dist/publish.sh` | debian | 20261005T000000Z | version | yes |
| tools/ffmpeg-dist/publish.sh | `tools/ffmpeg-dist/publish.sh` | GENCODE | arch=compute_75,code=sm_75 | version | no |
| tools/ffmpeg-dist/publish.sh | `tools/ffmpeg-dist/publish.sh` | qemu | 8.2.2 | version | yes |
| scripts/upload-artifact.sh | `scripts/upload-artifact.sh` | EXPECTED_SHA256 | 2df93667c7e12f2666be244772a41c653a02cab74880e685623770bd9c86ac34 | integrity | no |
| deploy/aws/fish-deploy.sh | `deploy/aws/fish-deploy.sh` | fish | 4.9.3 | version | no |
| deploy/aws/fish-deploy.sh | `deploy/aws/fish-deploy.sh` | fish-4.9.3-linux-x86_64.tar.xz:sha256 | 8f643d10ad1abb0ef7072764c01ceb5cf61b2d373fda400cf60f0bad69b7e095 | integrity | no |
| deploy/aws/launch | `deploy/aws/launch` | dlami | ami-0b1794752c0d4fa6c | version | yes |
| deploy/aws/launch | `deploy/aws/launch` | DEPLOYMENT_TAR_GO_ARM64 | strimserver-deployment-go-arm64.tar | version | no |
| deploy/aws/launch | `deploy/aws/launch` | RELEASE_DOWNLOAD_URL | https://github.com/ChronicCmposer/strimserver/releases/latest/download/{asset} | version | no |
| third_party/pin.json | `third_party/libmicrohttpd/pin.json` | libmicrohttpd | 1.0.10 | version | no |
| third_party/pin.json | `third_party/libmicrohttpd/pin.json` | libmicrohttpd:sha256 | 04bfe8ef75db7d629a33de767599765cecadc56274a39822d5d081030d577685 | integrity | no |
| third_party/pin.json | `third_party/wslay/pin.json` | wslay | 1.1.1 | version | no |
| third_party/pin.json | `third_party/wslay/pin.json` | wslay:sha256 | 90ce68c6dfd614722d44fbb14563a3f6dacc68b548b20ae382ac4f4952c55268 | integrity | no |
| third_party/pin.json | `third_party/yyjson/pin.json` | yyjson | 0.13.0 | version | no |
| third_party/pin.json | `third_party/yyjson/pin.json` | yyjson:sha256 | 34e0f62a2bc11ab20d601e8ca1cc2b2079503aa45119a19133d89d19b94a0fae | integrity | no |
| third_party/pin.json | `third_party/cares/pin.json` | c-ares | 1.34.8 | version | no |
| third_party/pin.json | `third_party/cares/pin.json` | c-ares:sha256 | c222b6d681096f9444d2c4863d2c1174019e27cacca0a4a5c114d36dd7d7bf78 | integrity | no |
| third_party/pin.json | `third_party/containerd-api/pin.json` | containerd-api | 1.12.0 | version | no |
| third_party/pin.json | `third_party/containerd-api/pin.json` | containerd-api:sha256 | 6978892e8ab09b36f5c09311f856ae07411cd9efd76a5213d125a733f08753fa | integrity | no |
| third_party/pin.json | `third_party/curl/pin.json` | curl | 8.23.0 | version | no |
| third_party/pin.json | `third_party/curl/pin.json` | curl:sha256 | e3de77cfa6367083c776a26647fc9f633b538c06c3baa73d931a252ac8f72b49 | integrity | no |
| third_party/pin.json | `third_party/libwebsockets/pin.json` | libwebsockets | 5.0.0 | version | no |
| third_party/pin.json | `third_party/libwebsockets/pin.json` | libwebsockets:sha256 | f853c6582101cfcee3a5a9e28ae92ab19d9735c5f31f0bb2e9794b5106123962 | integrity | no |
| third_party/pin.json | `third_party/mbedtls/pin.json` | mbedtls | 3.6.7 | version | no |
| third_party/pin.json | `third_party/mbedtls/pin.json` | mbedtls:sha256 | a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6 | integrity | no |
| third_party/pin.json | `third_party/protobuf-c/pin.json` | protobuf-c | 1.5.2 | version | no |
| third_party/pin.json | `third_party/protobuf-c/pin.json` | protobuf-c:sha256 | e2c86271873a79c92b58fef7ebf8de1aa0df4738347a8bd5d4e65a80a16d0d24 | integrity | no |
| .env | `.env` | PROJECT_GO_VERSION_TAG | go1.27.2 | version | no |
| .env | `.env` | S3_BUCKET_NAME | strimserver.cvbn.cc | version | no |
| .env | `.env` | DEPLOYMENT_SRC | s3://strimserver.cvbn.cc/${STRIMSERVER_C_X86_64_DEPLOYMENT_FILE_NAME} | version | no |
| .env | `.env` | STRIMSERVER_GO_X86_64_DEPLOYMENT_FILE_NAME | strimserver-deployment-go-amd64.tar | version | no |
| .env | `.env` | STRIMSERVER_GO_ARM64_DEPLOYMENT_FILE_NAME | strimserver-deployment-go-arm64.tar | version | no |
| .env | `.env` | STRIMSERVER_C_X86_64_DEPLOYMENT_FILE_NAME | strimserver-deployment-c-amd64.tar | version | no |
| .env | `.env` | STRIMSERVER_C_ARM64_DEPLOYMENT_FILE_NAME | strimserver-deployment-c-arm64.tar | version | no |
| .env | `.env` | IPERF3_DEPLOYMENT_FILE_NAME | iperf3-deployment.tar | version | no |
| .env | `.env` | VPC_ID | vpc-0ac0b7b5d05c5d55c | version | no |
| .env | `.env` | OPERATOR_CIDR | 104.218.148.0/24 | version | no |
| .env | `.env` | INSTANCE_TYPE | g4dn.xlarge | version | no |
| .env | `.env` | CFN_STACK_NAME | strimserver | version | no |
| .env | `.env` | KEY_NAME | sd-experiment-key | version | no |
| .env | `.env` | ENABLE_DDNS | true | version | no |
| streamdeck manifest | `tools/streamdeck-plugin/com.chroniccmposer.strimserver.sdPlugin/manifest.json.tpl` | SDKVersion | 2 | version | no |
| streamdeck manifest | `tools/streamdeck-plugin/com.chroniccmposer.strimserver.sdPlugin/manifest.json.tpl` | Software.MinimumVersion | 6.6 | version | no |
| streamdeck manifest | `tools/streamdeck-plugin/com.chroniccmposer.strimserver.sdPlugin/manifest.json.tpl` | Nodejs.Version | 24 | version | no |
| streamdeck manifest | `tools/streamdeck-plugin/com.chroniccmposer.strimserver.sdPlugin/manifest.json.tpl` | OS.mac.MinimumVersion | 13 | version | no |
| package.json | `tools/streamdeck-plugin/package.json` | packageManager | pnpm@9.15.9 | version | yes |
| package.json | `tools/streamdeck-plugin/package.json` | engines.node | >=24 | version | no |
| package.json | `tools/streamdeck-plugin/package.json` | dependencies:@elgato/streamdeck | ^2 | version | yes |
| package.json | `tools/streamdeck-plugin/package.json` | devDependencies:@rollup/plugin-commonjs | 29.0.3 | version | yes |
| package.json | `tools/streamdeck-plugin/package.json` | devDependencies:@rollup/plugin-node-resolve | ^16 | version | yes |
| package.json | `tools/streamdeck-plugin/package.json` | devDependencies:@rollup/plugin-typescript | ^12 | version | yes |
| package.json | `tools/streamdeck-plugin/package.json` | devDependencies:@types/node | 24.13.3 | version | yes |
| package.json | `tools/streamdeck-plugin/package.json` | devDependencies:rollup | 4.64.5 | version | yes |
| package.json | `tools/streamdeck-plugin/package.json` | devDependencies:tslib | ^2 | version | yes |
| package.json | `tools/streamdeck-plugin/package.json` | devDependencies:typescript | 6.0.3 | version | yes |
| CI with inputs | `.github/workflows/deps-check.yml` | actions/setup-go:go-version | 1.27.2 | version | no |
| CI with inputs | `.github/workflows/deps-check.yml` | actions/setup-node:node-version-file | tools/streamdeck-plugin/.nvmrc | version | no |
| CI with inputs | `.github/workflows/deps-check.yml` | actions/setup-node:cache | pnpm | version | no |
| CI with inputs | `.github/workflows/deps-check.yml` | actions/setup-node:cache-dependency-path | tools/streamdeck-plugin/pnpm-lock.yaml | version | no |
| CI with inputs | `.github/workflows/deps-check.yml` | actions/upload-artifact:name | deps-check | version | no |
| CI with inputs | `.github/workflows/deps-check.yml` | actions/upload-artifact:if-no-files-found | error | version | no |
| CI uses | `.github/workflows/controller-ci.yml` | actions/checkout | v7.0.1 | version | yes |
| CI uses | `.github/workflows/no-infra-identifiers.yml` | actions/checkout | v7.0.1 | version | yes |
| CI uses | `.github/workflows/ffmpeg-reproducibility.yml` | actions/checkout | v7.0.1 | version | yes |
| CI uses | `.github/workflows/deps-check.yml` | actions/checkout | v7.0.1 | version | yes |
| CI uses | `.github/workflows/deps-check.yml` | actions/setup-go | v7.0.0 | version | yes |
| CI uses | `.github/workflows/deps-check.yml` | actions/setup-node | v7.0.0 | version | yes |
| CI uses | `.github/workflows/deps-check.yml` | bazelbuild/setup-bazelisk | v3 | version | yes |
| CI uses | `.github/workflows/controller-ci.yml` | bazelbuild/setup-bazelisk | v3 | version | yes |
| toolchain | `.bazelversion` | Bazel | 9.3.0 | version | yes |
| toolchain | `tools/streamdeck-plugin/.nvmrc` | Node | 24.21.0 | version | yes |
| toolchain | `core/controller/go.mod` | Go | 1.27.2 | version | yes |
| core/controller/go.mod require | `core/controller/go.mod` | github.com/coder/websocket | v1.8.15 | version | yes |
| core/controller/go.mod require | `core/controller/go.mod` | github.com/containerd/containerd/api | v1.11.1 | version | yes |
| core/controller/go.mod require | `core/controller/go.mod` | github.com/containerd/containerd/v2 | v2.3.6 | version | yes |
| core/controller/go.mod require | `core/controller/go.mod` | github.com/containerd/errdefs | v1.0.0 | version | yes |
| core/controller/go.mod require | `core/controller/go.mod` | github.com/containerd/typeurl/v2 | v2.2.3 | version | yes |
| core/controller/go.mod require | `core/controller/go.mod` | github.com/opencontainers/image-spec | v1.1.1 | version | yes |
| core/controller/go.mod require | `core/controller/go.mod` | github.com/opencontainers/runtime-spec | v1.3.0 | version | yes |
| core/controller/go.mod require | `core/controller/go.mod` | google.golang.org/protobuf | v1.36.12-0.20260120151049-f2248ac996af | version | yes |
| lockfile transitive inventory | `core/controller/go.sum` | go.sum:transitive-module-pairs | 132 | version | no |
| lockfile transitive inventory | `tools/streamdeck-plugin/pnpm-lock.yaml` | pnpm-lock:transitive-packages | 53 | version | no |
| lockfile transitive inventory | `MODULE.bazel.lock` | MODULE.bazel.lock:bcr-registry-modules | 49 | version | no |
| lockfile transitive inventory | `MODULE.bazel.lock` | MODULE.bazel.lock:bcr-registry-file-hashes | 281 | version | no |

## Notes / caveats

- **Transitive inventory counts are approximate** (as specified): `go.sum`
  yields 132 unique `(module,version)` pairs not covered by a `require`;
  `pnpm-lock.yaml` yields 53 package instances not declared by an importer;
  `MODULE.bazel.lock` records 49 distinct BCR modules across 281 registry file
  hashes. The wave extractors (`gosum.go`, `pnpmlock.go`) emit these as
  `inventory:transitive` records.
- `protoc_linux_{aarch64,x86_64}` currently surface only as extraction
  unknowns (version lives solely in the URL, `36.2` has no third component);
  the oracle expects the new extractor to resolve them.
- `openssh_dist` / `openssh_dist_arm64` are bare-file (`s3_http_file`) pins: no
  version token is encoded in the name, so only their sha256 is enumerated.
- `third_party/*/pin.json` covers all 9 vendored libs; the 6 that are also
  fetched via `MODULE.bazel` `http_archive` (§http_archive) are listed under
  both sources because dedupe keys on file.
