# Lanes — run 20261111T213500Z-dep-updates

Lane IDs are allocated before fan-out and are binding. Central pin files cannot be split at file level, so ownership below is declared by **anchor/section**; every other claimed path is file-level exclusive.

## Lane table

| Lane | Owner agent | Claimed globs / anchors |
| --- | --- | --- |
| `toolchain` | coder | `.bazelversion`; `.env`; `core/controller/go.mod` — anchor: the single `^go ` directive line only; `tools/check-deps/go.mod`; `.github/workflows/deps-check.yml`; `.github/workflows/deps-strict.yml`; `MODULE.bazel` — anchor: the `rules_cc` comment block + `bazel_dep(name = "rules_cc", ...)` line only; `MODULE.bazel.lock` — **sole writer for wave 1**; `tools/deps-pins/pins_test.go` — anchors: the Bazel and Go assertion blocks only; `README.md` — anchors: dependency-table rows for Bazel and Go only; `tools/check-deps/testdata/expected-pins.json` + `.md` — anchors: entries for Bazel and Go only |
| `plugin` | coder | `tools/streamdeck-plugin/**` (incl. `package.json`, `.nvmrc`, `pnpm-lock.yaml`); `MODULE.bazel` — anchors: `bazel_dep(name = "aspect_rules_js", ...)` line and the `single_version_override(module_name = "bazel_lib", ...)` block only; `tools/deps-pins/pins_test.go` — anchors: aspect_rules_js / Node / pnpm assertions only; `README.md` — anchors: Node/pnpm table rows only. Must pass `--lockfile_mode=off` to all Bazel invocations. |
| `go-deps` | coder | `core/controller/go.mod` — anchor: the `require (...)` lines for `Microsoft/go-winio`, `klauspost/compress`, `moby/sys/capability`, `moby/sys/mountinfo` only; `core/controller/go.sum`; `deps-ignore.json` — anchor: two new rules appended after the final existing rule only; `tools/deps-pins/pins_test.go` — anchors: go-winio and klauspost assertions only. Must pass `--lockfile_mode=off`. |
| `ami` | coder | `deploy/aws/launch`; `deploy/aws/README.md`; `README.md` — anchor: the EC2/DLAMI paragraph only; `tools/deps-pins/pins_test.go` — anchor: the `aws-launch-ami` assertion only. Must pass `--lockfile_mode=off`. |
| `ffmpeg-artifact` | coder | `tools/ffmpeg-dist/build.sh`; `tools/ffmpeg-dist/publish.sh`; `scripts/upload-artifact.sh`; `MODULE.bazel` — anchors: the apt extension block, the legal comment, the `ffmpeg_dist`/`ffmpeg_dist_arm64` blocks, the `deb_extract` protobuf blocks, and the `amd64_sysroot` block only; `README.md` — anchor: the ffmpeg dependency-table rows and the "FFmpeg reproducibility and artifact pipeline" section only; `tools/deps-pins/ffmpeg_dist_test.go`; `tools/deps-pins/pins_test.go` — anchors: the Debian-snapshot needles only; `deps-ignore.json` — anchor: deletion of the CUDA x2 and nv-codec-headers x2 rules only. Must pass `--lockfile_mode=off`. |
| `openssh-rpm` | coder | `tools/openssh/build.sh`; `tools/openssh/publish.sh`; `MODULE.bazel` — anchor: the two `s3_http_file` blocks named `openssh_dist` and `openssh_dist_arm64` only; `tools/deps-pins/pins_test.go` — anchor: the openssh assertions only. Must pass `--lockfile_mode=off`. |
| `integration` | coder | `MODULE.bazel.lock` — **sole writer for the final regeneration**; read-only everywhere else. Runs the terminal gates and reports. |
| `orchestrator` | orchestrator | none (inbox only) |

## Disjointness statement

All file-level globs above are disjoint **except** for `MODULE.bazel`, `tools/deps-pins/pins_test.go`, `README.md`, `deps-ignore.json`, and `core/controller/go.mod`, where file-level disjointness is impossible. For those files, ownership is declared by the anchors in the table: no two lanes may edit the same anchor, and no lane may edit text outside its declared anchors. `MODULE.bazel.lock` has exactly one writer per phase: `toolchain` in wave 1, `integration` in the final phase; every other lane must invoke Bazel with `--lockfile_mode=off`.

## Scheduling

- Wave 1 (parallel): `toolchain`, `plugin`, `go-deps`, `ami`.
- Wave 2 (parallel): `ffmpeg-artifact`, `openssh-rpm` — allocated up front, spawned after wave 1 audits.
- Final (alone): `integration`.
