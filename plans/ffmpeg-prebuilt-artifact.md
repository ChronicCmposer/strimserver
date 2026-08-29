# Prebuilt FFmpeg artifact: remove BuildKit from the default build path

> **Status:** proposed — nothing implemented yet.
> **Base:** `feature/buildkit-to-bazel` (PR #2). This plan extends that
> migration and is meaningless without it.
> **Verification:** repository claims below — line numbers, pins, and the
> controller's process-args behavior — were checked against the tree at
> `246c575` before this file was written; they are marked *verified* where
> confirmed. External claims (NVIDIA's CUDA redistributable manifests, the
> `debian13` repo, and CUDA's supported host-compiler range) were checked
> against NVIDIA's published index and installation guide. Nothing here is
> recalled from memory.

## Context

`strimserver`'s Bazel migration (PR #2, `feature/buildkit-to-bazel`) left three
targets on `sudo buildctl` against a remote BuildKit daemon, because `rules_oci`
has no `RUN` equivalent. The costly one is `//core:ffmpeg_image_tarball`, which
compiles FFmpeg against a CUDA devel image — and it sits on the critical path of
`//:package`, so **every bundle build requires a daemon, an SSH tunnel, and
passwordless `sudo`.**

Worse, that build is not reproducible today. Three inputs are unpinned:

| Input | Location | Problem |
| --- | --- | --- |
| `--branch "release/8.0"` | `core/Dockerfile:30`, cloned at `:59` | a **moving maintenance branch**, not a tag — accumulates 8.0.x point releases silently |
| `nvidia/cuda:13.0.2-devel-ubuntu24.04` | `core/Dockerfile:27` | mutable tag |
| `apt-get install … libfdk-aac-dev` | `core/Dockerfile:38-48` | unpinned, and from **Ubuntu** while the runtime `.so` comes from **Debian trixie** |

Two builds a month apart differ, with no signal. There is no golden baseline to
regress from, so any pinning is a strict improvement.

**Goal:** make the FFmpeg binary a pinned, checksummed input fetched from S3, and
port the ffmpeg image to the same `rules_oci` machinery the mediamtx image
already uses. The FFmpeg compile moves out-of-band — once per version bump —
with a checksum as the contract.

**Payoff:** `//tools/openssh:openssh_rpm` is behind a default-off `select()`, and
`//tools/bandwidth-test:iperf3_image_tarball` is not in the bundle at all. So
after this change **`make package` needs no daemon, no tunnel, no `sudo`**, even
though `buildctl.bzl` remains in the tree for those two off-path targets.

## Decisions taken

- **Hermetic-by-pinning**, not hermetic-from-source. Building FFmpeg inside Bazel
  (`rules_foreign_cc` + `rules_cuda`) stays a separable future project.
- **Build the artifact on Debian trixie, not Ubuntu 24.04**, so the build-time and
  runtime glibc / `libfdk-aac` come from the same pinned Debian snapshot.
- **Add a reproducibility canary** so the pinning cannot quietly decay.
- CUDA arrives via NVIDIA's **redistributable tarballs**, not an apt repo
  (rationale in Phase 1).
- Single GPU target (`sm_75`) as today; the artifact naming leaves room for more.

## Phase 1 — Producer: `tools/ffmpeg-dist/`

Move `core/Dockerfile`'s `build` stage (`:27-133`) out of the Bazel graph into
`tools/ffmpeg-dist/Dockerfile`. Leaving a Dockerfile in `core/` beside
Bazel-built images invites "which is authoritative?" — the answer is now
"neither; it's a release tool."

**Rebase onto Debian.** `FROM debian:trixie-20260518-slim`, with apt pointed at
`https://snapshot.debian.org/archive/debian/20260518T203109Z` — the *same*
snapshot `MODULE.bazel:110` already pins. Build deps (`build-essential`,
`pkgconf`, `git`, `nasm`, `yasm`, `binutils`, `libfdk-aac-dev`) come from there.
`libfdk-aac-dev` is in `non-free`, so the sources need
`main contrib non-free non-free-firmware` — same components `MODULE.bazel:112`
already declares.

**CUDA via redistributables.** NVIDIA ships CUDA for Ubuntu and RHEL, not Debian,
so install from `https://developer.download.nvidia.com/compute/cuda/redist/`
(verified: `redistrib_13.0.2.json` exists, matching the current pin; components
`cuda_nvcc` and `cuda_cudart` are what FFmpeg's `--enable-cuda-nvcc` needs —
FFmpeg `dlopen`s the driver at runtime, so nothing links against libcuda).

Chosen over the `debian13/` apt repo (which also exists) because the tarballs are
distro-independent, carry per-component sha256 in the manifest, and are the same
artifacts `rules_cuda` consumes — keeping the future in-Bazel path open rather
than dead-ending it.

**Pin the remaining inputs:** FFmpeg to an exact commit SHA or an
`https://ffmpeg.org/releases/ffmpeg-8.0.N.tar.xz` tarball (a deliberate semantic
change from tracking the branch); `nv-codec-headers` stays at tag `n13.0.19.0`
(`core/Dockerfile:35`, already pinned); the Debian base by snapshot timestamp.

The `./configure` invocation (`core/Dockerfile:64-128`) and
`-gencode arch=compute_75,code=sm_75` (`:68`) carry over **unchanged**.

**Output** — `ffmpeg-<ffver>-deb20260518-cuda13.0.2-sm75-<shortsha>.tar.gz`
(`.tar.gz` for consistency with `@mediamtx_dist`), containing:

```
ffmpeg            # stripped binary
BUILD-INFO.txt    # provenance manifest
```

`BUILD-INFO.txt` records the FFmpeg commit, nv-codec-headers tag, Debian
snapshot, CUDA version + component sha256s, `-gencode` target, the full
`configure` line, `libfdk-aac-dev` version, and `readelf -d` output. Without it,
in eighteen months nobody can say what is in the blob.

**`tools/ffmpeg-dist/publish.sh`** — build → extract → tar → `sha256sum` →
`aws s3 cp` → print the `http_archive` stanza to paste into `MODULE.bazel`.

**Bucket layout — immutable, checksum in the name:**
`s3://<bucket>/ffmpeg/ffmpeg-<...>-<shortsha>.tar.gz`. A bump is always a new
URL, so nothing already fetched can change underneath. Public-read on that
prefix: the sha256 in `MODULE.bazel` is the integrity guarantee, FFmpeg binaries
are not secret, and a private bucket would mean `--credential_helper` plumbing in
every developer and CI environment for no security gain.

## Phase 2 — Consumer

### `MODULE.bazel`

Two edits:

1. New `http_archive(name = "ffmpeg_dist", url = …, sha256 = …,
   build_file_content = 'exports_files(["ffmpeg", "BUILD-INFO.txt"])')`, beside
   `@mediamtx_dist` (`:141-146`), same shape. List the S3 URL first and a GitHub
   Release asset second in `urls` as a free mirror — `release.sh` already uses
   `gh release upload`.
2. Add `libfdk-aac2t64` to `apt.install`'s package list (`:119-133`). It resolves
   with no further work because `:112` already declares the `non-free` component.

### `core/BUILD.bazel`

Port `TARGET A` (`core/Dockerfile:184-222`) alongside the existing mediamtx
target, reusing `//tools/bazel:deb_file.bzl` and the existing `:nsswitch_conf`
genrule.

Five new `deb_file` targets — four from `@trixie//libc6` that mediamtx does not
need (`libdl.so.2`, `librt.so.1`, `libnss_dns.so.2`, `libnss_files.so.2`), plus
`libfdk-aac.so.2` from `@trixie//libfdk-aac2t64/amd64:data`.

**Destination paths matter.** A scratch image has no `/lib` → `/usr/lib` merge,
so these are genuinely different directories and `core/Dockerfile` distinguishes
them:

- glibc set → `/lib/x86_64-linux-gnu/` (same prefix as `:mediamtx_libs`)
- **`libfdk-aac.so.2` → `/usr/lib/x86_64-linux-gnu/`** (`core/Dockerfile:209`) —
  needs its own `pkg_files`

Then, mirroring `:mediamtx_*` almost line for line: `pkg_files` for `/usr/bin`
(busybox + `nice` — **no `envsubst`**, that is mediamtx-only), `/lib64`, the two
lib dirs, `/etc`; `pkg_files` placing `@ffmpeg_dist//:ffmpeg` at `/ffmpeg` mode
0755; `pkg_tar` with the same 8 busybox symlinks. **No `cacerts()`** — TARGET A
ships no CA bundle, only TARGET B does.

`oci_image` needs two things the mediamtx one did not:

- **No `entrypoint`.** Verified: the controller supplies process args itself via
  `oci.WithProcessArgs(ctrTranscode, stageName)`
  (`core/controller/container_factory.go:104-106`), and TARGET A declares no
  `ENTRYPOINT`. Matching today means omitting it.
- **`env`** carrying all four of `core/Dockerfile:191-194`:
  `NVIDIA_VISIBLE_DEVICES=all`, `NVIDIA_DRIVER_CAPABILITIES=compute,utility,video`,
  `LD_LIBRARY_PATH=/usr/lib64`, `PATH=…`. These are load-bearing — CDI GPU
  injection keys off the NVIDIA vars and the injected driver libs land in
  `/usr/lib64`. Dropping them breaks GPU access at runtime with no build-time
  signal.

Then `oci_load` with `repo_tags = ["docker.io/library/ffmpeg:latest"]` — must
match exactly; resolved by name at `container_factory.go:72` and hardcoded again
in `core/strimserver.env.example`. Finally a `filegroup` promoting the `tarball`
output group, as the other two images do.

**Delete** the `buildctl_build(name = "ffmpeg_image_tarball")` call
(`core/BUILD.bazel:211-221`).

### `core/ffmpeg_smoke_test.sh` (new)

Modeled on `core/mediamtx_smoke_test.sh`, recovering the checks currently living
in the `RUN` layer at `core/Dockerfile:217-222`: `/ffmpeg -version`,
`-h encoder=h264_nvenc`, `-h encoder=hevc_nvenc`, the `/bin/sh` → busybox
symlink, and the `command -v` loop. These need no GPU — `-h encoder=` reads the
static registry and NVENC is `dlopen`'d, which is why they worked as a build
layer. Invoke through `ld-linux --library-path` as the mediamtx test does.

**Add one check the Dockerfile lacks:** assert `readelf -d` lists no `NEEDED`
entry that is not packaged. That converts "the hand-picked `.so` set is easy to
get subtly wrong" — the migration plan's own top risk — from a runtime discovery
on a `g4dn` into a build-time failure. It also settles whether `libdl`/`librt`
are still needed at all (empty compat stubs on glibc ≥ 2.34).

## Phase 3 — Reproducibility canary

**First, measure.** Build the artifact twice from identical pins and compare. Do
not assume FFmpeg is bit-reproducible — build paths, `ar` ordering, and nvcc
determinism are all unverified here. The measurement decides the tier:

- **Tier 1 (if bit-identical):** weekly GitHub Action rebuilds and asserts the
  sha256 still matches the pin in `MODULE.bazel`.
- **Tier 2 (if not):** compare a semantic fingerprint instead — `ffmpeg
  -buildconf`, the `NEEDED` set from `readelf -d`, and the `-encoders` /
  `-filters` lists. Weaker, but still catches "a pin drifted and `libfdk_aac`
  silently vanished."

Runs on an ordinary runner — compiling needs `nvcc`, not a GPU. On mismatch it
should open an issue rather than only going red, so it is actually noticed.

## Phase 4 — Docs

- README *Build instructions*: the "Start or connect to a BuildKit daemon"
  paragraph becomes conditional — only for `publish-iperf3` and the OpenSSH toggle.
- README build-dependencies table (`:180-192`): add the pinned artifact; the
  FFmpeg / nv-codec-headers / gencode rows change meaning from "built here" to
  "baked into the pinned artifact."
- New README section: *Rebuilding the FFmpeg artifact* — when, how to run
  `publish.sh`, how to bump the sha256.
- Write `plans/ffmpeg-prebuilt-artifact.md` in the repo, matching the style of
  `plans/buildkit-to-bazel-migration.md`.
- `Makefile` needs no change; nothing there names ffmpeg.
- Keep `core/Dockerfile` one more cycle. Once `build` and `ffmpeg` leave, it is
  dead code — but it is still the only human-readable spec of the image contents,
  and the Bazel files cite its line numbers throughout. Delete it when mediamtx's
  port is confirmed on hardware.

## Verification

1. **Byte equality.** Build the artifact pinned to the same FFmpeg commit
   currently at the tip of `release/8.0`; extract the binary from today's
   `ffmpeg-container.tar` and compare. A difference here means something is
   nondeterministic — worth knowing before Phase 3.
2. **Image equality.** `tar -tv` diff of old vs. new `ffmpeg-container.tar`:
   file list, modes, symlink targets. Expect only timestamp / layer-digest
   differences (Bazel zeroes timestamps; BuildKit does not).
3. `bazel test //core:ffmpeg_smoke_test`, including the new `readelf` assertion.
4. `bazel build //:package` **with no BuildKit daemon running and without
   `sudo`** — the headline claim; it must succeed.
5. **Runtime, the real gate.** `ctr -n strimserver image import` on a `g4dn`/`g6`,
   then SRT ingest → transcode → egress, confirming `hevc_cuvid`, `hevc_nvenc`,
   `h264_nvenc`, `libfdk_aac`, `scale_cuda`, and CDI injection.
6. **Incrementality.** Touch `core/Dockerfile` → nothing rebuilds. That is the
   change working.

## Risks

| Risk | Mitigation |
| --- | --- |
| CUDA 13.0.2 redistributables unproven on Debian trixie | Debian 13 is an officially supported CUDA distro (GCC 14.2 / glibc 2.41, inside the supported 6.x–15.x range) — verified against NVIDIA's install guide. If 13.0.2 specifically balks, bump the pin to 13.3, which lists Debian 13 explicitly. Not a reason to abandon the Debian switch. |
| FFmpeg build is not bit-reproducible | Phase 3 measures this before depending on it; Tier 2 fingerprint is the fallback. |
| Hand-picked `.so` set subtly wrong | The new `readelf -d` assertion in the smoke test makes it a build-time failure. Runtime GPU test still mandatory. |
| The artifact is a blob nobody can rebuild | `BUILD-INFO.txt` + the Dockerfile stays in-repo + the canary proves the recipe still works. |
| Switching FFmpeg from branch to pinned release changes the binary | Intended. Verification step 1 compares against today's tip so the delta is known, not discovered. |

## Open items

- **Branch.** This work builds on `feature/buildkit-to-bazel`; `main` has no
  Bazel migration, so branching from it would make this incoherent.
- **Bucket name / region / AWS profile** for the artifact prefix.
- Exact FFmpeg point release to pin (`8.0`, `8.0.1`, …).
