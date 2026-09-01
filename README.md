# strimserver

`strimserver` is a GPU-accelerated live-stream relay and
transcoding appliance for running a cloud-side streaming
endpoint. It accepts an encrypted SRT contribution feed,
routes it through MediaMTX, normalizes video/audio timing
and format with FFmpeg, records the normalized stream, and
publishes a Twitch-compatible RTMP egress stream.

A small Go **controller** (`strimserver-controller`)
orchestrates the whole pipeline. Rather than baking
everything into one container, the controller drives the
containerd API directly to create, start, stop, and
supervise the individual pipeline stages, reconciling their
actual state toward a desired state and exposing an
HTTP/WebSocket API for status and control.

The project is designed around a local encoder plus an AWS
GPU instance. A local OBS/FFmpeg workflow sends MPEG-TS over
SRT to the EC2 host; the EC2 host uses NVIDIA
CUDA/NVENC/NVDEC to normalize the input into low-latency
HEVC Main10, scale it to an egress resolution, encode
H.264/AAC, and forward the result to Twitch. Deployment
scripts package the container images, configuration,
transcode scripts, systemd service, and offline fallback
media into a deployment bundle that can be attached to a
GitHub release, uploaded to S3, or used directly as a local
file.

## Architecture

> **strimserver depends directly on
> [containerd](https://github.com/containerd/containerd).**
> There is no Docker, Kubernetes, or higher-level orchestrator
> in the loop. The controller links the `containerd/v2` client
> library and drives the containerd API directly to create,
> snapshot, start, stop, and supervise stage containers.
> containerd is a hard requirement on the EC2 runtime host,
> which the controller drives directly. Every OCI image is
> assembled by Bazel (`rules_oci`) from pinned inputs.

The runtime is split across three independent OCI images,
all managed by the controller:

| Image | Source target | Role |
| --- | --- | --- |
| `strimserver-controller:latest` | `core/controller/BUILD.bazel` (rules_oci from `debian:trixie` snapshot apt packages via the `@trixie` apt extension in `MODULE.bazel`) | Go control plane: drives containerd, reconciles stages, serves the HTTP/WebSocket API |
| `mediamtx:latest` | `core/BUILD.bazel` (rules_oci from `@mediamtx_dist` + `debian:trixie` snapshot apt packages) | MediaMTX media server: SRT ingest, RTSP routing, Unix MPEG-TS source, recording |
| `ffmpeg:latest` | `core/BUILD.bazel` (rules_oci from the pinned `@ffmpeg_dist` S3 artifact, `s3_http_archive`) | FFmpeg + NVIDIA HW accel; the same image backs both ffmpeg stages |

The controller supervises **three pipeline stages**, each a
container whose desired/actual state it reconciles:

- `mediamtx` — the MediaMTX server (the `ffmpeg` image is *not* used here).
- `normalize` — the `ffmpeg` image running `transcode.sh normalize`.
- `scale_and_egress` — the `ffmpeg` image running `transcode.sh scale_and_egress`.

Both runtime images for the media plane are built `FROM
scratch` (busybox + a minimal set of copied shared
libraries); Debian and the CUDA toolchain appear only in
intermediate build stages. NVIDIA driver libraries and the
GPU are injected into the ffmpeg stages at runtime via CDI
(`nvidia.com/gpu`), not baked into the image.

### NVIDIA GPU access via CDI

The ffmpeg images deliberately ship **without** any NVIDIA
driver libraries. Instead, the GPU is attached at
container-creation time using the **Container Device
Interface (CDI)** — a runtime-agnostic specification
(originally modeled on CNI) that lets a device vendor
describe, in a JSON/YAML spec under `/etc/cdi` or
`/var/run/cdi`, exactly which device nodes, host driver
libraries/sonames, and environment edits a container needs
in order to use a device. The NVIDIA container toolkit
generates that spec from the host's installed driver, and
containerd applies it when the controller requests
`nvidia.com/gpu=0`. This keeps the image
driver-version-agnostic, smaller, and decoupled from
whatever driver the DLAMI happens to ship. For more on CDI,
see the specification at
<https://github.com/cncf-tags/container-device-interface>.

### Controller API and behavior

The controller listens on `CONTROLLER_HTTP_PORT` (default
`4000`) and exposes:

- `POST /event` — path-readiness events
  (`ingress0`/`normalized` becoming `ready`/`not-ready`),
  posted by MediaMTX hooks through `notify.sh`.
- `POST /control` — start/stop commands for controllable
  components (currently `scale_and_egress`).
- `GET /status` — current paths and per-stage desired/actual
  state as JSON.
- `GET /subscribe` — WebSocket stream of controller status,
  consumed by the Stream Deck plugin.
- `GET /healthz` — liveness probe.

Internally the controller serializes all state changes
through a single actions channel, learns actual stage state
from containerd `TaskStart`/`TaskExit` events, runs a
periodic reconcile ticker, re-issues stage operations that
exceed an in-flight timeout, and tears down running stages
gracefully on shutdown.

## Features and capabilities

- Encrypted SRT ingest on a configurable port, defaulting to
  `9000`.
- MediaMTX-based stream routing with separate `ingress0` and
  `normalized` paths.
- RTSP readback inside the media plane for FFmpeg
  processing, defaulting to port `8554`.
- Always-available fallback playback for `ingress0` using
  `strimserver-offline-2160p60.mp4` when the live source is
  not ready.
- Controller-managed, three-stage pipeline with
  desired/actual reconciliation:
  - `normalize`: reads `ingress0`, forces 60 fps constant
    frame-rate timing, uploads frames to CUDA, encodes HEVC
    Main10 with `hevc_nvenc`, resamples audio to 48 kHz
    stereo, and writes MPEG-TS to a Unix socket.
  - `scale_and_egress`: reads `normalized`, decodes HEVC on
    CUDA, scales to the configured output height, encodes
    H.264 with `h264_nvenc`, encodes AAC audio with
    `libfdk_aac`, and pushes RTMP/FLV to Twitch.
- HTTP/WebSocket control surface for live status and manual
  egress start/stop, including a `/healthz` endpoint and
  path-readiness eventing.
- Stream Deck plugin providing a "Toggle Egress" button
  backed by the controller's status stream.
- Low-latency FFmpeg settings, including small probe/analyze
  windows, no B-frames, NVENC ultra-low-latency tuning,
  constant bitrate control, direct I/O flags, and short
  GOPs.
- Configurable normalized and egress video bitrate, maxrate,
  minrate, buffer size, audio bitrate, output height, Twitch
  ingest server, and Twitch stream key.
- Optional Twitch bandwidth-test mode via the
  `BANDWIDTH_TEST` environment variable.
- MPEG-TS recording of the normalized stream through
  MediaMTX, with 10-second recording parts, one-hour
  segments, 50 MB max part size, and no automatic deletion
  by default.
- Runtime configuration rendering with `envsubst` from
  `core/mediamtx.yaml.template` and `core/strimserver.env`.
- containerd runtime: the controller container runs with
  host networking and `CAP_SYS_ADMIN`; the stage containers
  it creates run with host networking, `CAP_SYS_NICE`,
  elevated scheduling priority, GPU access via CDI (ffmpeg
  stages), and bind-mounted config, scripts, secrets, and
  video files.
- Deployment packaging through `make package` (build a
  redistributable bundle plus SHA-256 checksum locally),
  `make release` (attach the bundle and checksum to a GitHub
  release via the GitHub CLI), and `make publish-strimserver`
  (build and upload a single-tenant bundle to S3). The Stream
  Deck plugin is published alongside the deployment tar as its
  own distributable: `make release` uploads
  `com.chroniccmposer.strimserver.sdPlugin.zip` and its
  `com.chroniccmposer.strimserver.sdPlugin.tar.gz` variant
  (+ checksums) to the GitHub release, and `make publish-strimserver` /
  `make publish-streamdeck` upload them to
  `strimserver-streamdeck-plugin.zip` and
  `strimserver-streamdeck-plugin.tar.gz` on S3. It is a separate
  artifact — `make package` never includes it inside
  `strimserver-deployment.tar`.
- EC2 setup automation for formatting and mounting NVMe
  ephemeral storage at `/mnt/nvme`, installing the systemd
  unit, importing the OCI images into containerd, generating
  the SRT passphrase, and preparing config/log/video
  directories.
- Local encoder helper scripts for configuring `/etc/hosts`,
  writing the SRT passphrase into a local env file, and
  streaming an OBS-provided Unix socket to the EC2 ingest
  endpoint.
- Offline "be right back" screen generation helpers for
  1080p60, 1440p60, and 2160p60 HEVC files.
- Optional `iperf3` bandwidth-test container and deployment
  scripts.
- Experimental OpenSSH RPM, always bundled: built
  out-of-band by `tools/openssh/publish.sh` and fetched
  from the pinned `@openssh_dist` artifact.

## Build dependencies and versions

### Pinned or declared repository dependencies

| Component | Version / source | Where used |
| --- | --- | --- |
| NVIDIA CUDA redistributables | `13.0.2` (`cuda_nvcc`, `cuda_cudart`, `cuda_crt`, `libnvvm`; per-component sha256 pinned via the `redistrib_13.0.2.json` manifest) | Compile the FFmpeg artifact in `tools/ffmpeg-dist` (producer-only; not needed for a normal package build) |
| Prebuilt FFmpeg artifact | `ffmpeg-8.0-deb20260824-cuda13.0.2-sm75-281c902.tar.gz` (sha256 pinned in `MODULE.bazel` via `s3_http_archive(name = "ffmpeg_dist", ...)`) | The single `ffmpeg` binary the image ships; fetched once and assembled by rules_oci |
| [FFmpeg](https://github.com/FFmpeg/FFmpeg) | `8.0` at commit `281c902` (tip of `release/8.0`, 2026-08-14; pinned and baked into the prebuilt artifact) | Custom FFmpeg build with NVENC/NVDEC, CUDA filters, RTSP/SRT/RTMP-related muxing, and `libfdk_aac` |
| [nv-codec-headers](https://github.com/FFmpeg/nv-codec-headers) | `n13.0.19.0` at commit `e844e5b2` (pinned in the artifact build) | NVIDIA codec integration for FFmpeg |
| FFmpeg CUDA `-gencode` | `arch=compute_75,code=sm_75` (Turing / T4 class) | Baked into the prebuilt artifact; see the EC2 note below |
| Intermediate Debian image | `debian:trixie` snapshot `20260824T082821Z` | Base for the artifact producer (`tools/ffmpeg-dist`: pulled via the Docker Hub registry API into a rootfs by `publish.sh`); the same snapshot supplies the scratch-image runtime libs via the `@trixie` rules_distroless apt extension |
| Go toolchain | `go 1.26.4` (rules_go `go_sdk` from `core/controller/go.mod`) | Controller build and test targets |
| [MediaMTX](https://github.com/bluenviron/mediamtx) | `v1.17.0`, Linux amd64 release tarball (`@mediamtx_dist` http_archive) | SRT ingest, RTSP routing, Unix MPEG-TS source, recording hooks, and process hooks |
| `libfdk-aac` | `libfdk-aac2t64` (Debian trixie package from `@trixie`) | AAC encode support through FFmpeg (`libfdk-aac.so.2` in the ffmpeg image) |
| busybox / `gettext-base` (`envsubst`) | Debian trixie packages from `@trixie` | Shell + tools for the scratch runtime images and MediaMTX template rendering |
| iperf3 | `3.19.1-r1` `.apk` (`@iperf3_apk` http_file) on alpine `3.23.3` (digest-pinned `@alpine_linux_amd64` oci.pull) | Optional bandwidth-test image |
| Node.js | `24.13.0` (from `tools/streamdeck-plugin/.nvmrc` via rules_nodejs `node_version_from_nvmrc`) | Stream Deck plugin build |

> Note: the FFmpeg build currently compiles for `sm_75`
> (Turing, e.g. the T4 in `g4dn` instances). To run the
> ffmpeg stages on a different GPU family — for example the
> L4 (`sm_89`) in `g6` instances — adjust the `-gencode`
> target (`GENCODE`) in `tools/ffmpeg-dist` when rebuilding
> the artifact, or run on a matching instance type.

> **Architecture: x86_64 only.** Every image is built
> exclusively for the `linux/amd64` (x86_64) architecture,
> and the deployment target is the **AMD EPYC 7R13**
> processor used in current-generation AWS GPU instances.
> The scratch images copy shared libraries from
> `x86_64-linux-gnu` paths, the Fish and MediaMTX binaries
> are `linux-x86_64`/`linux_amd64` releases, and Bazel
> (`--platforms=//tools/bazel:linux_amd64`) builds the
> `linux/amd64` platform. On non-x86_64 development hosts
> (e.g. aarch64), the Bazel test suite can still be run:
> `.bazelrc` sets `--use_target_platform_for_tests=true`,
> which runs test actions on the target platform via
> qemu-user binfmt (install `qemu-user` and
> `qemu-user-binfmt`) while compile/genrule actions stay
> native; this does not add arm64 build support. Building
> artifacts for `arm64`/`aarch64` is still unsupported
> today; building for ARM (e.g. AWS Graviton with NVIDIA,
> or the `g5g` family) or other architectures would require
> parameterizing the build platform, the FFmpeg `-gencode`
> target, the library copy paths, and the upstream binary
> URLs (see *Possible future enhancements*).

### Host build and deployment tools

These tools are required by the repository but are not
pinned by the source tree:

- **Bazel** (via [Bazelisk](https://github.com/bazelbuild/bazelisk);
  see `.bazelversion`) — the build system. It downloads and
  pins the Go and Node.js toolchains itself (see
  `MODULE.bazel`); you don't need either installed separately
  just to build. `make` is kept as a thin facade over `bazel`
  for muscle memory — see `Makefile`.
- **containerd** — runs on the EC2 runtime host, which the
  controller drives directly. All bundled OCI images are
  assembled natively by Bazel (`rules_oci`) from pinned
  inputs.
- AWS CLI with credentials authorized to read and write the
  configured S3 bucket and launch/manage EC2 instances.
- `jq`, used by AWS helper scripts.
- Python 3, used by EC2 launch/setup helpers.
- `tar`, `sudo`, OpenSSH client, and standard POSIX shell
  tooling.
- On non-x86_64 hosts (e.g. aarch64), `qemu-user` and
  `qemu-user-binfmt` (Debian/Ubuntu) must be installed and
  registered so the test suite (`make test-controller` /
  `bazel test //core/controller:all`) can run the
  linux/amd64 test binaries under emulation; on x86_64 hosts
  this is unnecessary.
- An NVIDIA-capable build environment (CUDA toolchain) is
  required only when **rebuilding** the GPU FFmpeg artifact
  via `tools/ffmpeg-dist`; a normal `make package` /
  `bazel build //:package` consumes the prebuilt artifact and
  needs no CUDA toolchain.

### Helper scripts (`scripts/`)

- `scripts/bucket-cidr-policy.sh` — scope HTTPS-only read
  access to the S3 bucket to an operator CIDR (the IP-scoped
  bucket policy that gates the published artifacts).
- `scripts/upload-artifact.sh` — upload a built FFmpeg
  artifact to S3 with no ACL modification (objects get the
  bucket's default private ACL; the policy above is the only
  access gate).

The old `check-env.sh` helper is gone (the controller image is
built by Bazel now), but the controller binary keeps the same
self-check as a flag: build it with `bazel build
//core/controller:strimserver-controller` and run
`./strimserver-controller -check-env` to validate the required
env vars and exit.

### Bazel S3 fetch rules (`STRIMSERVER_S3_BUCKET` / `STRIMSERVER_S3_REGION`)

`MODULE.bazel` fetches the two large artifacts through
`tools/bazel/s3_download.bzl`: the pinned FFmpeg tarball
(`@ffmpeg_dist`, via `s3_http_archive`) and the offline
fallback clip (`@offline_segment_dist`, via `s3_http_file`).
When **both** `STRIMSERVER_S3_BUCKET` and
`STRIMSERVER_S3_REGION` are set, the S3 URL is used as the
primary download source; when either is unset, the rules fall
back to the GitHub Release mirror URLs (the same blobs, hosted
on GitHub), so a plain `make package` / `bazel build //:package`
works with no AWS configuration:

```bash
export STRIMSERVER_S3_BUCKET="your-bucket-name"   # no s3:// prefix
export STRIMSERVER_S3_REGION="<your-region>"
```

Setting exactly one of the two is an error (a half-configured
bucket must not silently resolve to the mirror). Caveat: Bazel
repo rules read these variables only when the Bazel server
starts. If you change them after a build, run `bazel shutdown`
and re-run, or pass them explicitly, e.g.
`bazel build //:package --repo_env=STRIMSERVER_S3_BUCKET=your-bucket-name --repo_env=STRIMSERVER_S3_REGION=<your-region>`.

## Build instructions

Clone the repository:

```bash
git clone https://github.com/ChronicCmposer/strimserver.git
cd strimserver
```

Create the runtime configuration file and fill in the
bitrate and media settings:

```bash
make prepare          # bootstrap: cp core/strimserver.env.example core/strimserver.env
                      # (only when core/strimserver.env doesn't exist yet -- never overwrites)
$EDITOR core/strimserver.env
```

Leave `TWITCH_STREAM_KEY` **empty** for any bundle you intend
to redistribute (via `make package` / `make release`): the
key is a secret injected at deploy time by
`setup_strimserver` / `deploy.sh`, not baked into the bundle,
and `make package` / `make release` refuse to build if it is
non-empty. A private, single-tenant S3 build (`make
publish-strimserver`) may bake your own key instead.

`core/strimserver.env.example` is generated from the
controller's environment spec. If you change that spec,
regenerate the example (and the Stream Deck wire types)
with:

```bash
make generate          # rewrites the .env.example and types.generated.ts
make check-generated   # fails if those generated files are stale in git
```

The deployment bundle's offline fallback segment
(`strimserver-offline-2160p60.mp4`) is fetched by default: Bazel
pulls it through `MODULE.bazel`'s `s3_http_file(name =
"offline_segment_dist")` (S3, with a GitHub Release mirror) and
bundles the downloaded artifact into the deployment tar directly.
The clip is a 2160p60 HEVC/AAC encode produced out-of-band on
macOS — the `hevc_videotoolbox` + `aac_at` codecs are
VideoToolbox/AudioToolbox-only and cannot run inside the Bazel
graph. Publishing is a two-phase flow — generation needs macOS, upload
needs a Linux host with AWS credentials configured:

**Phase 1 — generate on macOS** (no AWS needed):

```bash
cd tools/brb-screen
./publish.sh generate
```

`publish.sh generate` sources `bslib.sh`'s `generate2160p` (the same
encode `bslib.sh` documents), writes
`~/Downloads/strimserver-offline-2160p60.mp4`, and prints its sha256.

**Phase 2 — upload from a Linux host with AWS credentials.** Copy the
clip to the host (e.g. `scp`), then:

```bash
cd tools/brb-screen
S3_BUCKET="s3://your-bucket-name" AWS_REGION="<your-region>" \
  ./publish.sh upload /path/to/strimserver-offline-2160p60.mp4
```

`AWS_REGION` is your bucket's own region — set it to your
value; there is no baked-in default. `publish.sh upload`
computes the sha256, uploads the mp4 to
`$S3_BUCKET/offline/`, and prints the `s3_http_file` stanza to paste
into `MODULE.bazel` — the sha256 there is the integrity pin. It also
prints the `gh release upload` command for the GitHub Release mirror
(tag `offline-segment`).

On a Mac that also has AWS credentials configured, running
`./publish.sh` with no subcommand generates and uploads in one flow.

The pinned clip is bundled directly into the deployment tar as
`strimserver-offline-2160p60.mp4` (no local override flag); to ship a
new clip, regenerate and republish it via `tools/brb-screen/publish.sh`
and update the `s3_http_file` pin in `MODULE.bazel`.

No daemon or SSH tunnel is needed for any build: the
experimental OpenSSH RPM is a pinned, checksummed artifact
fetched through `@openssh_dist` (built out-of-band by
`tools/openssh/publish.sh`), and the `iperf3` bandwidth-test
image is assembled by rules_oci from the digest-pinned alpine
base plus the pinned `@iperf3_apk` layer. The main
`make package` / `bazel build //:package` path — including
the `ffmpeg` image, which is assembled by rules_oci from the
pinned `@ffmpeg_dist` artifact — needs no daemon and no
`sudo`.

## FFmpeg reproducibility and artifact pipeline

The `ffmpeg` image's binary is a pinned, checksummed prebuilt
artifact fetched by Bazel through `MODULE.bazel`'s
`s3_http_archive(name = "ffmpeg_dist", ...)`. The FFmpeg compile
does not run in the Bazel graph — it happens out-of-band, once
per version bump, in `tools/ffmpeg-dist/`, and **the sha256 in
`MODULE.bazel` is the integrity guarantee**.

To rebuild and publish a new artifact:

```bash
cd tools/ffmpeg-dist
S3_BUCKET="s3://your-bucket-name" AWS_REGION="<your-region>" ./publish.sh
```

`AWS_REGION` is your bucket's own region — set it to your
value; there is no baked-in default (`SKIP_UPLOAD=1` rebuilds
and checksums without either variable).

`publish.sh` needs no docker daemon. It pulls
the pinned `debian:trixie-20260824-slim` base image via the
Docker Hub **registry API** (plain `curl` + `jq`), extracts it
into a rootfs, copies in the shared build script
`tools/ffmpeg-dist/build.sh`, and runs it inside a chroot. On
non-amd64 hosts the chroot invokes the tonistiigi
buildkit-direct-execve **patched qemu-x86_64** explicitly — upstream
qemu cannot intercept the guest's `execve` without binfmt_misc, and
the qemu bundled in the tonistiigi/binfmt images segfaults on
NVIDIA's `cicc`; amd64 hosts
run the guest natively with no qemu. All build steps (apt snapshot
pinning, CUDA redistributables, nv-codec-headers, FFmpeg) live in
the shared `tools/ffmpeg-dist/build.sh`, which is the single source
of truth (the sha256 in `MODULE.bazel` is the contract).

On non-amd64 hosts, `publish.sh` builds the patched qemu-x86_64
emulator from source when no valid one is available, via the shared
`tools/qemu/build-qemu.sh`. Qemu is pinned **per consumer**, with an
env-overridable default `QEMU_VERSION="${QEMU_VERSION:-8.2.2}"`; the
builder verifies the source tarball's sha256 for the pinned version
(8.2.2 and 9.2.4 are both mapped) and caches the built binary at a
version-stamped path,
`${XDG_CACHE_HOME:-$HOME/.cache}/ffmpeg-dist/qemu-x86_64-patched-${QEMU_VERSION}`,
so the two consumers never share a qemu binary:
`tools/ffmpeg-dist/publish.sh` pins **qemu 8.2.2** for byte-identical
reproducibility (qemu 8.1.5 exposes a different guest CPUID — leaf
0x07 EBX bit 29, AVX512_BF16 — which changes compiler/nvcc codegen
and so yields a different ffmpeg binary), and
`tools/openssh/publish.sh` pins **qemu 9.2.4** (the linux-user
`open_self_maps` MAPERR SIGSEGV fix, needed because amazonlinux's
glibc grep/awk/m4 crash under 8.2.2 when reading `/proc/self/maps`).
The `buildkit-direct-execve` patch series is version-specific too:
qemu 8.2.2 uses the hand-ported v8.1 series committed at
`tools/qemu/qemu-patches-8.2.2/` (patches 0004 and 0005 were
hand-ported to 8.2.2's `ImageSource` API because no upstream v8.2
patch set exists — tonistiigi/binfmt jumps from v8.1 to v9.2), and
qemu 9.2.4 uses the v9.2 series at `tools/qemu/qemu-patches/`. Host
build dependencies — meson, ninja, python3, pkg-config, gcc, and
libglib2.0-dev — are required only on non-amd64 hosts;
`tools/qemu/build-qemu.sh` fails loudly with the exact `apt-get
install` command if any are missing. To build the non-default pin,
run `QEMU_VERSION=9.2.4 tools/qemu/build-qemu.sh` (set `QEMU_VERSION`
whenever a consumer's pin differs from the 8.2.2 default). `QEMU_BIN`
may still be used to override with a pre-built patched qemu; it is
validated (must contain the buildkit-direct-execve marker
`safe_execve` and report the pinned version) and ignored with a
warning if it is not a patched emulator at that version.
The previous registry auto-fetch (`QEMU_IMAGE`, e.g.
`tonistiigi/binfmt:qemu-v8.1.5`) was removed because every registry tag
ships an **unpatched** emulator that cannot execute guest child
processes (ENOEXEC — the exact bug this replaces); amd64 hosts need no
qemu. An already-extracted rootfs can be reused by setting
`FFMPEG_DIST_ROOTFS`. `publish.sh` then extracts the stripped
`ffmpeg` binary plus its `BUILD-INFO.txt` provenance record, writes
`ffmpeg-<ffver>-deb<date>-cuda<ver>-sm<N>-<shortsha>.tar.gz`
(e.g. `ffmpeg-8.0-deb20260824-cuda13.0.2-sm75-281c902.tar.gz`),
uploads it to the `s3://<bucket>/ffmpeg/` prefix with no ACL
modification (objects get the bucket's default private ACL; the
IP-scoped HTTPS-only bucket policy from `scripts/bucket-cidr-policy.sh` is
the only access gate), and prints the `s3_http_archive` stanza to
paste into `MODULE.bazel`. `BUILD-INFO.txt` records the FFmpeg commit,
nv-codec-headers tag, Debian snapshot, CUDA component sha256s,
`-gencode` target, the full `configure` line, and `readelf -d`
output, so the blob always stays reproducible.

A weekly canary (`.github/workflows/ffmpeg-reproducibility.yml`)
rebuilds the artifact on an ordinary GitHub runner and compares
the rebuilt sha256 against the pin in `MODULE.bazel` — Tier 1,
bit-identical. A mismatch opens an issue rather than only going
red. The Tier 2 fallback compares a semantic fingerprint instead
(`ffmpeg -buildconf`, the `readelf -d` NEEDED set, and the
`-encoders` / `-filters` lists): weaker, but it still catches a
pin drift that silently drops `libfdk_aac`.

Build the deployment bundle. There are three ways to produce
and publish `strimserver-deployment.tar`, depending on how
you want consumers to fetch it (each shown as the `make`
facade and the underlying `bazel` command it runs):

```bash
# A) Build a redistributable bundle + SHA-256 locally (no upload).
#    Output: bazel-bin/strimserver-deployment.tar(.sha256)
make package
bazel build //:package

# B) Build, then attach the bundle + checksum to an existing GitHub
#    release. Requires the GitHub CLI (`gh auth login`) and a pushed tag.
make release GIT_TAG=v1.0.0
bazel run //:release   # reads GIT_TAG from the environment

# C) Build and upload a single-tenant bundle to S3 (the default goal).
export S3_BUCKET="s3://your-bucket-name"
make publish-strimserver
bazel run //:publish_strimserver   # reads S3_BUCKET from the environment
```

The Stream Deck plugin ships as its own distributable,
published **alongside** `strimserver-deployment.tar` — never
inside it:

- `make release` / `bazel run //:release` also attach
  `com.chroniccmposer.strimserver.sdPlugin.zip`, its
  `com.chroniccmposer.strimserver.sdPlugin.tar.gz` variant, and
  both `.sha256` files to the GitHub release (in addition to the
  deployment tar + checksum).
- `make publish-strimserver` / `bazel run
  //:publish_strimserver` also upload the plugin bundles to
  `$S3_BUCKET/strimserver-streamdeck-plugin.zip` and
  `$S3_BUCKET/strimserver-streamdeck-plugin.tar.gz` (the tar's
  sha256 is not uploaded to S3, and neither is the plugin's —
  parity with the existing convention).
- `make publish-all` / `bazel run //:publish_all` publishes
  **everything** to S3 in a single bazel run (one
  server/analysis pass): the strimserver deployment tar
  (`strimserver-deployment.tar`), the Stream Deck plugin bundles
  (both `strimserver-streamdeck-plugin.zip` and
  `.tar.gz`), and the iperf3 bundle
  (`iperf3-deployment.tar`). Requires AWS credentials and
  `S3_BUCKET`.
- `make publish-streamdeck` / `bazel run
  //tools/streamdeck-plugin:publish_streamdeck` upload **only**
  the plugin bundles (both .zip and .tar.gz), to the same
  `strimserver-streamdeck-plugin.zip` / `.tar.gz` keys. This
  mirrors `make publish-iperf3`.
- `make package` / `bazel build //:package` builds only the
  deployment tar (+ checksum); the plugin bundles are a separate
  artifact produced by `bazel build
  //tools/streamdeck-plugin:streamdeck_plugin_bundle` and
  `//tools/streamdeck-plugin:streamdeck_plugin_tar_gz`.

All three deployment paths build the same three OCI images —
`strimserver-controller:latest`, `ffmpeg:latest`, and
`mediamtx:latest` — all assembled natively by Bazel
(`rules_oci`) from pinned inputs — then package those images
together with
the configuration, scripts, systemd service, and the offline
segment into `strimserver-deployment.tar`.
`make package` and `make release` also produce a `.sha256`
checksum for the tar (consumers verify it via
`DEPLOYMENT_SHA256`; see *AWS EC2 deployment target*) and
require `TWITCH_STREAM_KEY` to be empty in
`core/strimserver.env`; `make publish-strimserver` does not,
and bakes whatever key is present. The experimental OpenSSH
RPM is always included: it is fetched from the pinned
`@openssh_dist` artifact (built out-of-band by
`tools/openssh/publish.sh`).

Thanks to the `FROM scratch` images (no base OS, no bundled
NVIDIA driver — the driver is injected at runtime via CDI)
and statically/minimally linked binaries, the bundle stays
small. This keeps download/transfer and EC2 setup fast and
makes the bundle cheap to rebuild and redeploy.

The deployment bundle contains:

- `controller-container.tar`, `ffmpeg-container.tar`, `mediamtx-container.tar`
- `strimserver-offline-2160p60.mp4`
- `deploy.sh`, `fish-deploy.sh`, `imdslib.sh`, `prompt_login.fish`
- `strimserver.service`
- `strimserver.env`, `mediamtx.yaml.template`, `transcode.sh`, `notify.sh`
- `openssh-experimental.rpm` (always included; from the pinned `@openssh_dist` artifact)

Other useful targets:

```bash
make controller        # bazel build //core/controller:strimserver-controller
make test-controller   # bazel test //core/controller:all (go test, lint, codegen staleness)
make generate          # bazel run //core/controller:generate -- regenerate strimserver.env.example + Stream Deck wire types
make check-generated   # bazel test //core/controller:generate_test -- fail if those files are stale in git
make publish-iperf3    # bazel run //tools/bandwidth-test:publish_iperf3 -- build and publish the iperf3 bandwidth-test bundle to S3
```

On non-x86_64 hosts, `make test-controller` additionally
requires `qemu-user`/`qemu-user-binfmt` to be installed and
registered, as described in *Host build and deployment
tools*.

`bazel test //...` runs every test in the repo: controller unit tests,
lint, generated-file staleness, and the image smoke tests
(`//core/controller:image_smoke_test`, `//core:mediamtx_smoke_test`,
and `//core:ffmpeg_smoke_test` — the latter also asserts every
`DT_NEEDED` library is packaged in the image).

## AWS EC2 deployment target

The intended deployment target is an AWS EC2 GPU instance
running the latest Amazon Linux 2023 Deep Learning AMI
(DLAMI), with the instance's NVMe ephemeral storage mounted
at `/mnt/nvme`. The `launch` helper defaults to `g6.xlarge`;
pick an instance whose GPU matches the FFmpeg `-gencode`
target (see the build note above) or adjust the target
accordingly.

Expected target characteristics:

- AMI family: latest Amazon Linux 2023 DLAMI.
- GPU/container runtime: NVIDIA driver and container tooling
  supplied by the DLAMI.
- Storage: NVMe ephemeral device formatted as `ext4` and
  mounted at `/mnt/nvme` by `deploy/aws/setup_strimserver`.
- Runtime: containerd with its root and state directories
  moved under `/mnt/nvme`.
- Network access:
  - inbound SSH from the operator machine;
  - inbound SRT ingest, default UDP port `9000`, from the
    local encoder;
  - inbound controller HTTP/WebSocket, default TCP port
    `4000`, from the operator machine (used by `/control`,
    `/status`, and the Stream Deck `/subscribe` stream);
  - outbound access to wherever the bundle is hosted (a
    GitHub release over HTTPS, or S3) for artifact
    retrieval;
  - outbound RTMP to the configured Twitch ingest server.
- IAM permissions to read the deployment bundle from S3
  **only when** it is delivered via an `s3://` source; an
  HTTPS release asset or a locally uploaded file needs no
  instance IAM for retrieval. The machine used for `make
  publish-strimserver` needs S3 write permission; `make
  package` / `make release` do not.

Durable infrastructure — a security group and an IAM
instance profile, with an optional self-contained
VPC/subnet/internet gateway — is provisioned once from the
CloudFormation template at
`deploy/aws/strimserver-infra.yaml`. The `launch` helper
reads that stack's outputs and creates instances
imperatively with `ec2 run-instances`; there is **no EC2
launch template**. `terminate` tears down instances by their
`Project` tag.

Deploy (or update) the infrastructure stack first.
`deploy/aws/deploy-template` shows the call; at minimum
supply your operator CIDR (set `DeploymentBucketName` only
when you deliver the bundle from S3 — omit it for an HTTPS
release asset or a local file):

```bash
OPERATOR_CIDR="203.0.113.4/32" \
S3_BUCKET_NAME="" \
deploy/aws/deploy-template
```

Then configure `.env` and launch. `launch` resolves the
security group, instance profile, and (when the stack
manages networking) the public subnet from the stack
outputs, forces a public IP, enforces IMDSv2, and uses a
spot instance by default (`--no-spot` for on-demand):

```bash
cp deploy/aws/.env.example deploy/aws/.env
$EDITOR deploy/aws/.env          # set KEY_NAME, DEPLOYMENT_SRC, TWITCH_STREAM_KEY, etc.
set -a
. deploy/aws/.env
set +a

# Launch, overriding the instance type. --wait prints the public IP + next steps.
deploy/aws/launch --type g6.xlarge --wait
```

`DEPLOYMENT_SRC` in `.env` selects where the box fetches the
bundle from: an `https://` URL (e.g. a GitHub release asset
— no AWS credentials needed), an `s3://` URI (the instance
role needs S3 read), or a local path (uploaded over scp).
Set `DEPLOYMENT_SHA256` to verify the download against the
checksum produced by `make package` / `make release`. Your
Twitch stream key is supplied here via `TWITCH_STREAM_KEY`
(or `TWITCH_STREAM_KEY_FILE`) and transferred to the
instance as a `0600` file at deploy time — it is never baked
into the bundle.

After the instance is reachable over SSH, run the setup
script from the local machine:

```bash
deploy/aws/setup_strimserver
```

`setup_strimserver` will display the remote block devices
and prompt for the NVMe device to format. The default is
`/dev/nvme1n1`. This is destructive to the selected device.
It then places the deployment bundle on the box (HTTPS
download, S3 pull, or scp upload, per `DEPLOYMENT_SRC`),
unpacks it, and runs `deploy.sh`, which stages config/bin/video-file directories
under `/mnt/nvme`, configures and restarts containerd,
installs the systemd unit, **imports all three OCI images**
(`controller-container.tar`, `ffmpeg-container.tar`,
`mediamtx-container.tar`) into the `strimserver` containerd
namespace, generates the SRT passphrase, and creates the
logs and video-files directories.

When setup completes, it prints the generated SRT passphrase
and a suggested local encoder configuration command. Start
and stop the systemd service with:

```bash
deploy/aws/start_strimserver
deploy/aws/stop_strimserver
```

The systemd unit runs the imported
`docker.io/library/strimserver-controller:latest` image
through `ctr` in the `strimserver` namespace, with host
networking and `CAP_SYS_ADMIN`, and bind-mounts the
containerd socket, `/tmp`, the containerd root under
`/mnt/nvme`, the CDI directory, `/dev`, and
`strimserver.env`. The controller then creates and
supervises the `mediamtx`, `normalize`, and
`scale_and_egress` stage containers, attaching the GPU to
the ffmpeg stages via CDI.

## Local encoder setup

Create a local encoder env file:

```bash
cp tools/local-encoder/local-encoder.env.example ~/.strimserver-local-encoder.env
$EDITOR ~/.strimserver-local-encoder.env
export LOCAL_ENCODER_ENV="$HOME/.strimserver-local-encoder.env"
```

Make sure the env file contains valid `FFMPEG_CMD`,
`INPUT_SOCKET`, `SRT_PASSPHRASE`, and `FFMPEG_NICE` values,
along with the SRT tuning and bitrate settings shown in the
example (`SRT_LATENCY_US`, `SRT_INPUT_BW_BYTES_PER_SEC`,
`SRT_PB_KEY_LEN`, `VIDEO_BITRATE`, `AUDIO_BITRATE`, and so
on). The local encoder script validates these and fails fast
if any are missing.

Use the command printed by the EC2 deploy script to set the
remote host and generated passphrase:

```bash
configure-local-encoder.zsh --strimserver-host <public-ip> --passphrase <generated-passphrase>
```

This invokes `set-strimserver-host.zsh` (updates
`/etc/hosts`) and `set-srt-passphrase.zsh` (writes the
passphrase into the local env file).

Run the local encoder:

```bash
tools/local-encoder/local-encoder.zsh
```

The local encoder reads the OBS-provided Unix socket at
`INPUT_SOCKET` (for example `obs.nut.sock`), copies video
and audio without local re-encoding, wraps them as MPEG-TS,
and publishes to `srt://<host>:9000` in caller mode with
`streamid=publish:ingress0`.

## Stream Deck control

`tools/streamdeck-plugin/` is a TypeScript Stream Deck
plugin (`@elgato/streamdeck` v2, Node >= 24, built with
Rollup) that adds a **Toggle Egress** action. The action
subscribes to the controller's WebSocket status stream and
sends start/stop control commands, reflecting live stage
state on the button. By default it targets
`http://strimserver:4000`, overridable via the
`STRIMSERVER_URL` environment variable; the port must match
`CONTROLLER_HTTP_PORT`. The plugin's wire types in
`src/client/types.generated.ts` are produced by `make
generate` from the controller's Go definitions.

## Possible future enhancements

- Wire up the automatic `normalized → scale_and_egress`
  route so egress can start without manual control, with the
  existing readiness prerequisite.
- Add first-class support for additional egress targets
  beyond Twitch, such as YouTube, Kick, custom RTMP
  endpoints, HLS, or SRT output.
- Add multi-destination simulcast with per-platform bitrate,
  resolution, and codec profiles.
- Record a separate VOD audio track alongside the live mix
  (e.g. a music-free or alternately-mixed AAC track) so
  archives/VODs can avoid muted segments and copyright
  strikes without affecting the live broadcast.
- Extend the controller's reconciliation with
  restart/backoff policies for repeated stage failures,
  building on the existing in-flight timeouts and `/healthz`
  probe.
- Add structured metrics and dashboards for ingest bitrate,
  dropped frames, encoder load, GPU utilization, RTMP
  reconnects, SRT latency, and recording status.
- Add alerting for missing ingest, failed Twitch egress,
  failed recordings, or full NVMe storage.
- Add automatic cleanup/retention policies for recorded
  segments, with configurable upload/archive to S3.
- Make the MediaMTX recording path configurable from
  `strimserver.env`.
- Add a local `docker compose` or containerd development
  profile for non-AWS smoke tests.
- Add integration tests that emulate SRT ingest and verify
  normalized stream creation, recording, and RTMP egress
  behavior.
- Add explicit version pinning for host tooling and
  distro-installed runtime packages.
- Parameterize the FFmpeg CUDA `-gencode` target to support
  additional NVIDIA architectures (e.g. `sm_89` for `g6`).
- Support building for `arm64`/`aarch64` (e.g. AWS Graviton
  with NVIDIA, such as the `g5g` family) and other
  architectures by parameterizing the Bazel build platform,
  the library copy paths, the `-gencode` target, and the
  upstream binary download URLs (MediaMTX, etc.).
- Add safer secret handling for Twitch stream keys and SRT
  passphrases through AWS Secrets Manager or SSM Parameter
  Store.
- Add a documented path for updating MediaMTX, FFmpeg, CUDA,
  nv-codec-headers, and Go versions together.
- Extend the existing CloudFormation infrastructure
  (`deploy/aws/strimserver-infra.yaml`, which already
  provisions the security group, IAM instance profile, and
  optional VPC/subnet) toward a fuller end-to-end provision —
  or provide equivalent Terraform/CDK — covering S3, the
  instance lifecycle, and on-box configuration.
- Provide a packaged deployment for orchestrated
  environments — e.g. a Helm chart running the stages as
  Kubernetes pods with the NVIDIA device plugin / CDI.

## Contributing

Contributions are accepted through pull requests on GitHub:
https://github.com/ChronicCmposer/strimserver

Recommended workflow:

1. Fork the repository on GitHub.
2. Create a feature branch from the default branch:

   ```bash git checkout -b feature/your-change ```

3. Make the change with focused commits.
4. Test the affected path. Examples include building the
   controller/ffmpeg/mediamtx images, running `make
   test-controller` and `make check-generated`, running
   shell scripts with a safe test configuration, validating
   the SRT test image, or testing EC2 deployment changes
   against a disposable instance.
5. Update documentation when behavior, configuration,
   deployment steps, or defaults change.
6. Open a pull request against `ChronicCmposer/strimserver`
with:
   - a summary of the change;
   - the motivation for the change;
   - the test/build/deployment commands that were run;
   - any compatibility or migration notes.

The repository ships a pre-commit guard (`.githooks/pre-commit`,
backed by `tools/check-no-infra-identifiers.sh`) that rejects
commits containing AWS-infra identifiers (a domain, an AWS host
IP prefix, an operator name, or an S3 bucket). The identifier
patterns are live infrastructure attributes and are intentionally
NOT committed; they are injected at runtime via the
`STRIMSERVER_INFRA_IDENTIFIERS` env var for the git hook and via
the `INFRA_IDENTIFIERS` repository secret in CI. Enable the hook
with:

```bash
git config core.hooksPath .githooks
```

Avoid committing secrets, Twitch stream keys, generated SRT
passphrases, local `.env` files, deployment artifacts,
container tarballs, or recorded video files.

## Related projects

Core dependencies:

- [MediaMTX](https://github.com/bluenviron/mediamtx) — the
  media server used for SRT ingest, RTSP routing, the Unix
  MPEG-TS source, and recording.
- [FFmpeg](https://github.com/FFmpeg/FFmpeg) — the normalize
  and scale/egress stages run a pinned prebuilt FFmpeg 8.0
  artifact (see *FFmpeg reproducibility and artifact
  pipeline*).
- [nv-codec-headers](https://github.com/FFmpeg/nv-codec-headers)
  — NVIDIA codec headers enabling NVENC/NVDEC/CUVID in the
  FFmpeg build.
- [containerd](https://github.com/containerd/containerd) —
  the container runtime the controller drives directly via
  the `containerd/v2` client.
- [Container Device Interface
  (CDI)](https://github.com/cncf-tags/container-device-interface)
  — the specification used to inject the NVIDIA GPU and
  driver libraries into the ffmpeg stages at runtime.

Related / prior art:

- [OHMEED/stable-streaming](https://github.com/OHMEED/stable-streaming)
  — an all-in-one IRL streaming solution (Go backend + React
  frontend) covering multi-destination streaming,
  bitrate-based automatic scene switching, and real-time
  monitoring. A useful reference point for the broader
  "self-hosted streaming relay" problem space.

## License

This project is licensed under the MIT License. See
`LICENSE` for details.
