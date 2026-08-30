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
> [containerd](https://github.com/containerd/containerd) and
> [BuildKit](https://github.com/moby/buildkit).** There is
> no Docker, Kubernetes, or higher-level orchestrator in the
> loop. The controller links the `containerd/v2` client
> library and drives the containerd API directly to create,
> snapshot, start, stop, and supervise stage containers.
> containerd is a hard requirement on the EC2 runtime host,
> which the controller drives directly. The OCI images are
> assembled by Bazel (`rules_oci`) from pinned inputs;
> BuildKit/`buildctl` is needed only for two optional,
> off-path build targets (the experimental OpenSSH RPM and
> the iperf3 bandwidth-test image).

The runtime is split across three independent OCI images,
all managed by the controller:

| Image | Source target | Role |
| --- | --- | --- |
| `strimserver-controller:latest` | `core/controller/Dockerfile` (`runtime`) | Go control plane: drives containerd, reconciles stages, serves the HTTP/WebSocket API |
| `mediamtx:latest` | `core/Dockerfile` (`--target mediamtx`) | MediaMTX media server: SRT ingest, RTSP routing, Unix MPEG-TS source, recording |
| `ffmpeg:latest` | `core/BUILD.bazel` (rules_oci) from the pinned `@ffmpeg_dist` artifact | FFmpeg + NVIDIA HW accel; the same image backs both ffmpeg stages |

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
  (build and upload a single-tenant bundle to S3).
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
- Optional experimental OpenSSH RPM build, gated by
  `ENABLE_EXPERIMENTAL_OPENSSH` in `feature-toggles.env`.

## Build dependencies and versions

### Pinned or declared repository dependencies

| Component | Version / source | Where used |
| --- | --- | --- |
| NVIDIA CUDA redistributables | `13.0.2` (`cuda_nvcc`, `cuda_cudart`, `cuda_crt`, `libnvvm`; per-component sha256 pinned via the `redistrib_13.0.2.json` manifest) | Compile the FFmpeg artifact in `tools/ffmpeg-dist` (producer-only; not needed for a normal package build) |
| Prebuilt FFmpeg artifact | `ffmpeg-8.0-deb20260824-cuda13.0.2-sm75-281c902.tar.gz` (sha256 pinned in `MODULE.bazel` via `http_archive(name = "ffmpeg_dist", ...)`) | The single `ffmpeg` binary the image ships; fetched once and assembled by rules_oci |
| [FFmpeg](https://github.com/FFmpeg/FFmpeg) | `8.0` at commit `281c902` (tip of `release/8.0`, 2026-08-14; pinned and baked into the prebuilt artifact) | Custom FFmpeg build with NVENC/NVDEC, CUDA filters, RTSP/SRT/RTMP-related muxing, and `libfdk_aac` |
| [nv-codec-headers](https://github.com/FFmpeg/nv-codec-headers) | `n13.0.19.0` at commit `e844e5b2` (pinned in the artifact build) | NVIDIA codec integration for FFmpeg |
| FFmpeg CUDA `-gencode` | `arch=compute_75,code=sm_75` (Turing / T4 class) | Baked into the prebuilt artifact; see the EC2 note below |
| Intermediate Debian image | `debian:trixie-20260824-slim` (snapshot `20260824T082821Z`) | Base image for the artifact producer (`tools/ffmpeg-dist`: pulled via the Docker Hub registry API into a rootfs by `publish.sh`, or `FROM` the thin `Dockerfile` wrapper); the same snapshot supplies the scratch-image runtime libs via `@trixie` (rules_distroless) |
| Go toolchain | `golang:1.26.4-alpine3.24` | Controller build and test stages (`core/controller/Dockerfile`); module declares `go 1.26.4` |
| [MediaMTX](https://github.com/bluenviron/mediamtx) | `v1.17.0`, Linux amd64 release tarball | SRT ingest, RTSP routing, Unix MPEG-TS source, recording hooks, and process hooks |
| `libfdk-aac` | `libfdk-aac-dev` in build stage; `libfdk-aac2t64` in runtime-libs stage | AAC encode support through FFmpeg |
| busybox / `gettext-base` (`envsubst`) | Debian packages copied into the scratch images | Shell + tools for the scratch runtime images and MediaMTX template rendering |
| iperf3 | `3.19.1-r1` | Optional bandwidth-test container |
| [Fish shell](https://github.com/fish-shell/fish-shell) | `4.3.1` `linux-x86_64` release tarball (SHA-256 verified) | Downloaded and installed on the EC2 host by `fish-deploy.sh` (not from distro repositories); used for the operator login shell and deployment helpers |

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
> are `linux-x86_64`/`linux_amd64` releases, and BuildKit
> builds the `linux/amd64` platform. There is no
> `arm64`/`aarch64` support today; building for ARM (e.g.
> AWS Graviton with NVIDIA, or the `g5g` family) or other
> architectures would require parameterizing the build
> platform, the FFmpeg `-gencode` target, the library copy
> paths, and the upstream binary URLs (see *Possible future
> enhancements*).

### Host build and deployment tools

These tools are required by the repository but are not
pinned by the source tree:

- **Bazel** (via [Bazelisk](https://github.com/bazelbuild/bazelisk);
  see `.bazelversion`) — the build system. It downloads and
  pins the Go and Node.js toolchains itself (see
  `MODULE.bazel`); you don't need either installed separately
  just to build. `make` is kept as a thin facade over `bazel`
  for muscle memory — see `Makefile`.
- **containerd** and **BuildKit / `buildctl`** — containerd
  runs on the EC2 runtime host, which the controller drives
  directly. BuildKit/`buildctl` is required only for the two
  off-path targets Bazel cannot express as a pure OCI archive
  assembly, because they're defined by compilation steps (`RUN`
  a compiler, a package manager) that `rules_oci` deliberately
  has no equivalent for: the experimental OpenSSH RPM
  (autoreconf/configure/make/rpmbuild) and the `iperf3`
  bandwidth-test image (`apk add`). The helper scripts in
  `tools/buildkit-scripts/` can deploy and tunnel a BuildKit
  daemon if one is needed. The three bundled images
  (`strimserver-controller`, `mediamtx`, and `ffmpeg`) are all
  assembled natively by Bazel and need neither.
- AWS CLI with credentials authorized to read and write the
  configured S3 bucket and launch/manage EC2 instances.
- `jq`, used by AWS helper scripts.
- Python 3, used by EC2 launch/setup helpers.
- `tar`, `sudo`, OpenSSH client, and standard POSIX shell
  tooling.
- An NVIDIA-capable build environment (CUDA toolchain) is
  required only when **rebuilding** the GPU FFmpeg artifact
  via `tools/ffmpeg-dist`; a normal `make package` /
  `bazel build //:package` consumes the prebuilt artifact and
  needs no CUDA toolchain.

## Build instructions

Clone the repository:

```bash
git clone https://github.com/ChronicCmposer/strimserver.git
cd strimserver
```

Create the runtime configuration file and fill in the
bitrate and media settings:

```bash
cp core/strimserver.env.example core/strimserver.env
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

Point Bazel at the offline fallback segment expected by the
deployment bundle. Unlike the rest of the bundle's inputs,
this file isn't checked in or fetched — wrap wherever you've
placed it in a one-line `BUILD.bazel` and pass it as a build
flag:

```bash
# Option A: generate the default 2160p60 fallback clip on a machine with a compatible FFmpeg setup.
. tools/brb-screen/bslib.sh
generate2160p
mkdir -p local/video
cp ~/Downloads/strimserver-offline-2160p60.mp4 local/video/
echo 'exports_files(["strimserver-offline-2160p60.mp4"])' > local/video/BUILD.bazel

# Option B: point it at an already-created fallback file the same way.
```

Then pass `--//:offline_segment=//local/video:strimserver-offline-2160p60.mp4`
to any `bazel build`/`bazel run` invocation below (or add it to a
`.bazelrc.local` as `build --//:offline_segment=...` so you don't have to
repeat it). Building without it fails with a clear message telling you to
set the flag.

Start or connect to a BuildKit daemon only when building one
of the two off-path targets: the experimental OpenSSH RPM
(`ENABLE_EXPERIMENTAL_OPENSSH="true"`) or the `iperf3`
bandwidth-test image (`make publish-iperf3`). The main
`make package` / `bazel build //:package` path — including
the `ffmpeg` image, which is assembled by rules_oci from the
pinned `@ffmpeg_dist` artifact — needs no daemon, no SSH
tunnel, and no `sudo`.

## Rebuilding the FFmpeg artifact

The `ffmpeg` image's binary is a pinned, checksummed prebuilt
artifact fetched by Bazel through `MODULE.bazel`'s
`http_archive(name = "ffmpeg_dist", ...)`. The FFmpeg compile
does not run in the Bazel graph — it happens out-of-band, once
per version bump, in `tools/ffmpeg-dist/`, and **the sha256 in
`MODULE.bazel` is the integrity guarantee**.

To rebuild and publish a new artifact:

```bash
cd tools/ffmpeg-dist
S3_BUCKET="s3://your-bucket-name" AWS_REGION="us-east-1" ./publish.sh
```

`publish.sh` needs no docker daemon and no `buildctl`. It pulls
the pinned `debian:trixie-20260824-slim` base image via the
Docker Hub **registry API** (plain `curl` + `jq`), extracts it
into a rootfs, copies in the shared build script
`tools/ffmpeg-dist/build.sh`, and runs it inside a chroot. On
non-amd64 hosts the chroot invokes the tonistiigi
buildkit-direct-execve **patched qemu-x86_64** explicitly — upstream
qemu cannot intercept the guest's `execve` without binfmt_misc, and
BuildKit's bundled qemu segfaults on NVIDIA's `cicc`; amd64 hosts
run the guest natively with no qemu. All build steps (apt snapshot
pinning, CUDA redistributables, nv-codec-headers, FFmpeg) live in
the shared `tools/ffmpeg-dist/build.sh`, which is the single source
of truth; the thin `tools/ffmpeg-dist/Dockerfile` wrapper runs the
same script, so the docker path and the chroot+qemu path produce
byte-identical output (the sha256 in `MODULE.bazel` is the contract).

On non-amd64 hosts, `publish.sh` now builds the patched qemu-x86_64
emulator from source when no valid one is available: qemu 8.2.2 with a
hand-ported version of the tonistiigi `buildkit-direct-execve` patch
set (7 patches committed at `tools/ffmpeg-dist/qemu-patches/`; patches
0004 and 0005 were hand-ported to 8.2.2's `ImageSource` API because no
upstream v8.2 patch set exists — tonistiigi/binfmt jumps from v8.1 to
v9.2). qemu 8.2.2 is required for byte-identical reproducibility: qemu
8.1.5 exposes a different guest CPUID (leaf 0x07 EBX bit 29,
AVX512_BF16), which changes compiler/nvcc codegen and so yields a
different ffmpeg binary. The result is cached at
`${XDG_CACHE_HOME:-$HOME/.cache}/ffmpeg-dist/qemu-x86_64-patched` and
reused across runs (rebuilt on demand when missing or invalid). Host
build dependencies — meson, ninja, python3, pkg-config, gcc, and
libglib2.0-dev — are required only on non-amd64 hosts; `build-qemu.sh`
fails loudly with the exact `apt-get install` command if any are
missing. `QEMU_BIN` may still be used to override with a pre-built
patched qemu; it is validated (must contain the buildkit-direct-execve
marker `safe_execve` and report the pinned version, qemu 8.2.2) and
ignored with a warning if it is not a patched emulator at that version.
The previous registry auto-fetch (`QEMU_IMAGE`, e.g.
`tonistiigi/binfmt:qemu-v8.1.5`) was removed because every registry tag
ships an **unpatched** emulator that cannot execute guest child
processes (ENOEXEC — the exact bug this replaces); amd64 hosts need no
qemu. An already-extracted rootfs can be reused by setting
`FFMPEG_DIST_ROOTFS`. `publish.sh` then extracts the stripped
`ffmpeg` binary plus its `BUILD-INFO.txt` provenance record, writes
`ffmpeg-<ffver>-deb<date>-cuda<ver>-sm<N>-<shortsha>.tar.gz`
(e.g. `ffmpeg-8.0-deb20260824-cuda13.0.2-sm75-281c902.tar.gz`),
uploads it to the immutable `s3://<bucket>/ffmpeg/` prefix with
`--acl public-read`, and prints the `http_archive` stanza to paste
into `MODULE.bazel`. `BUILD-INFO.txt` records the FFmpeg commit,
nv-codec-headers tag, Debian snapshot, CUDA component sha256s,
`-gencode` target, the full `configure` line, and `readelf -d`
output, so the blob always stays reproducible.

A weekly canary (`.github/workflows/ffmpeg-reproducibility.yml`)
rebuilds the artifact on an ordinary GitHub runner and opens an
issue if the sha256 drifts from the pin. Bucket name, region,
and AWS profile remain open items; the `MODULE.bazel` URLs are
placeholders until the first publish.

Build the deployment bundle. There are three ways to produce
and publish `strimserver-deployment.tar`, depending on how
you want consumers to fetch it (each shown as the `make`
facade and the underlying `bazel` command it runs):

```bash
# A) Build a redistributable bundle + SHA-256 locally (no upload).
#    Output: bazel-bin/strimserver-deployment.checked.tar(.sha256)
make package
bazel build --//:offline_segment=//local/video:strimserver-offline-2160p60.mp4 //:package

# B) Build, then attach the bundle + checksum to an existing GitHub
#    release. Requires the GitHub CLI (`gh auth login`) and a pushed tag.
make release GIT_TAG=v1.0.0
bazel run --//:offline_segment=... //:release   # reads GIT_TAG from the environment

# C) Build and upload a single-tenant bundle to S3 (the default goal).
export S3_BUCKET="s3://your-bucket-name"
make publish-strimserver
bazel run --//:offline_segment=... //:publish_strimserver   # reads S3_BUCKET from the environment
```

All three build the same three OCI images —
`strimserver-controller:latest`, `ffmpeg:latest`, and
`mediamtx:latest` — all assembled natively by Bazel
(`rules_oci`) from pinned inputs — then package those images
together with
the configuration, scripts, systemd service, feature toggles,
and the offline segment into `strimserver-deployment.tar`.
`make package` and `make release` also produce a `.sha256`
checksum for the tar (consumers verify it via
`DEPLOYMENT_SHA256`; see *AWS EC2 deployment target*) and
require `TWITCH_STREAM_KEY` to be empty in
`core/strimserver.env`; `make publish-strimserver` does not,
and bakes whatever key is present. When
`ENABLE_EXPERIMENTAL_OPENSSH="true"` in `feature-toggles.env`
(or `--//:enable_experimental_openssh=true` passed directly),
the experimental OpenSSH RPM is built and added to the
bundle.

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
- `feature-toggles.env`
- `openssh-experimental.rpm` (only when the OpenSSH toggle is enabled)

Other useful targets:

```bash
make controller        # bazel build //core/controller:strimserver-controller
make test-controller   # bazel test //core/controller:all (go test, lint, codegen staleness)
make generate          # bazel run //core/controller:generate -- regenerate strimserver.env.example + Stream Deck wire types
make check-generated   # bazel test //core/controller:generate_test -- fail if those files are stale in git
make publish-iperf3    # bazel run //tools/bandwidth-test:publish_iperf3 -- build and publish the iperf3 bandwidth-test bundle to S3
```

`bazel test //...` runs every test in the repo (controller unit tests,
lint, generated-file staleness, and the image smoke tests that replaced
the Dockerfiles' `RUN`-layer checks — including `//core:ffmpeg_smoke_test`,
which also asserts every `DT_NEEDED` library is packaged in the image)
except the two remaining off-path targets that still require a real
BuildKit daemon (the experimental OpenSSH RPM and the `iperf3`
bandwidth-test image).

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
- Add automated CI for shell linting, Dockerfile builds,
  controller tests/lint, and `make check-generated`. (The pinned
  FFmpeg artifact already has a weekly reproducibility canary —
  `.github/workflows/ffmpeg-reproducibility.yml`.)
- Add integration tests that emulate SRT ingest and verify
  normalized stream creation, recording, and RTMP egress
  behavior.
- Add explicit version pinning for host tooling and
  distro-installed runtime packages.
- Parameterize the FFmpeg CUDA `-gencode` target to support
  additional NVIDIA architectures (e.g. `sm_89` for `g6`).
- Support building for `arm64`/`aarch64` (e.g. AWS Graviton
  with NVIDIA, such as the `g5g` family) and other
  architectures by parameterizing the BuildKit target
  platform, the library copy paths, the `-gencode` target,
  and the upstream binary download URLs (MediaMTX, Fish,
  etc.).
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
  artifact (see *Rebuilding the FFmpeg artifact*).
- [nv-codec-headers](https://github.com/FFmpeg/nv-codec-headers)
  — NVIDIA codec headers enabling NVENC/NVDEC/CUVID in the
  FFmpeg build.
- [containerd](https://github.com/containerd/containerd) —
  the container runtime the controller drives directly via
  the `containerd/v2` client.
- [BuildKit](https://github.com/moby/buildkit) — used through
  `buildctl` only for the two off-path targets rules_oci cannot
  express (the experimental OpenSSH RPM and the iperf3
  bandwidth-test image); the bundled OCI images are assembled by
  Bazel (`rules_oci`).
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
