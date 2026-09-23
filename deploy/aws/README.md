# strimserver dual-architecture deployment runbook

This runbook walks the staged cutover from the existing **amd64** deployment to
the **arm64** (`g5g.2xlarge`) deployment, and is the reference for anyone
re-deploying later. The build produces one self-contained deployment bundle per
architecture; `deploy/aws/launch` picks an architecture-aware AMI from the
instance type, so the operator's cutover decision is just **which bundle URL and
instance type to point at**. Section 7 lists blockers that gate the production
cutover — read it before any arm64 launch.

## 1. Architecture overview

| | amd64 (current) | arm64 (cutover target) |
|---|---|---|
| Instance | `g4dn.xlarge` (x86_64 + T4) / `g6.xlarge` (L4) | `g5g.2xlarge` (Graviton2 + T4G) |
| CPU ISA | x86_64 | arm64, armv8.2-a (Neoverse N1) |
| GPU / gencode | T4 `sm_75` (L4 `sm_89` on g6) | T4G `sm_75` — same gencode as T4 |
| AMI | Pinned x86_64 AL2023 NVIDIA DLAMI (`DEFAULT_AMI_ID`, us-east-2) | arm64 AL2023 NVIDIA DLAMI via the SSM float `.../arm64/base-oss-nvidia-driver-gpu-amazon-linux-2023/latest/ami-id` |
| Controller in image | Go controller (the oracle), pure-Go static `linux/amd64` | Go controller (the oracle), pure-Go static `linux/arm64`; the alternate asm build (`//core/controller/alternate/asm:controller_asm`) is explicit/manual |

The controller image is platform-selected in `core/controller/BUILD.bazel`:
both amd64 and arm64 ship the pure-Go controller binary (static, so it needs
no loader/libs on a scratch image), landing at `/strimserver-controller`.
The alternate assembly controller (`//core/controller/alternate/asm:controller_asm`)
is an explicit/manual build — it is no longer bundled in the arm64 image.

The deployment bundle is per-architecture: `--platforms` (or the arm64
platform transition) selects the controller binary, the image architectures,
and the multiarch lib paths (`lib/x86_64-linux-gnu` vs
`lib/aarch64-linux-gnu`). **amd64 keeps the unsuffixed
`strimserver-deployment.tar` (byte-identical to the pre-dual-arch assets);
arm64 ships `strimserver-deployment-arm64.tar`** — the distinct basename
avoids runfiles collisions and keeps the two bundles separate on one GitHub
release / S3.

## 2. Building the bundle

```sh
# Builds BOTH bundles (+ checksums) in ONE invocation:
bazel build //:package //:package_arm64
#   bazel-bin/strimserver-deployment.tar(.sha256)        amd64
#   bazel-bin/strimserver-deployment-arm64.tar(.sha256)  arm64
```

Or build each alone: `bazel build //:package` (amd64) /
`bazel build //:package_arm64` (arm64); the arm64 path runs the same unchecked
tar under `//tools/bazel:linux_arm64` via a platform transition
(`tools/bazel/platform_transition.bzl`). Bundle builds refuse to run while
`TWITCH_STREAM_KEY` is set in `core/strimserver.env` — the key is injected at
deploy time, never baked into the bundle.

Publish to GitHub (requires `gh auth login` and a pushed tag); `//:release`
uploads both tars and both `.sha256` assets:

```sh
GIT_TAG=v1.0.0 bazel run //:release
```

Verify the assembly controller against the Go oracle byte-for-byte — on an
aarch64 host with a host `go` toolchain on PATH:

```sh
core/controller/alternate/asm/differential.sh
```

It builds the Go oracle, then builds the alternate assembly controller
(`//core/controller/alternate/asm:controller_asm`, explicit/manual — only on
request) for arm64, and diffs `-print-env-example`, `-print-ts-types`, and
`-check-env` (stdout, stderr, exit codes). `DIFFERENTIAL: GREEN` means asm == Go.

## 3. Infrastructure (CloudFormation)

`deploy/aws/strimserver-infra.yaml` provisions the durable pieces once: the
security group, IAM instance profile, optional VPC/subnet/networking, and the
`strimserver` IAM service account. The service account's
`strimserver-ssm-dlami-readonly` policy grants `ssm:GetParameter` on **both**
the x86_64 and arm64 DLAMI SSM parameters, so the check-deps AMI resolver can
float the arm64 AMI in any region where it exists.

Deploy (or update) the stack with admin credentials:

```sh
# CreateNetwork=true, EnableExperimentalSsh=true, IngestCidr=OperatorCidr
OPERATOR_CIDR="203.0.113.4/32" \
S3_BUCKET_NAME="" \
deploy/aws/deploy-infra
```

| Parameter | Default | Notes |
|---|---|---|
| `OperatorCidr` | required | CIDR allowed to reach SSH (22) and the controller HTTP/WebSocket port; use your IP as a `/32` |
| `ControllerPort` | `4000` | Must match `CONTROLLER_HTTP_PORT` in `strimserver.env` |
| `SrtPort` | `9000` | SRT ingest UDP port; must match `STRIMSERVER_SRT_PORT` |
| `IngestCidr` | `0.0.0.0/0` | SRT is passphrase-encrypted; tighten to the encoder IP if static |
| `CreateNetwork` / `VpcId` | `false` / `""` | `true` creates a dedicated VPC + public subnet; otherwise supply an existing `VpcId` |
| `DeploymentBucketName` | `""` | Set only when the bundle is delivered via `s3://` |
| `EnableExperimentalSsh` / `ExperimentalSshPort` | `false` / `2222` | Open the experimental OpenSSH port to `OperatorCidr` |

`KEY_NAME` (the EC2 key pair) is **not** a stack parameter — it is set in
`deploy/aws/.env` and consumed by `launch`.

## 4. Launch — staged cutover

```sh
cp deploy/aws/.env.example deploy/aws/.env
$EDITOR deploy/aws/.env   # KEY_NAME, DEPLOYMENT_SRC, DEPLOYMENT_SHA256, TWITCH_STREAM_KEY, INSTANCE_TYPE
set -a; . deploy/aws/.env; set +a
```

### 4.1 arm64 pre-flight (required before cutover)

1. **The arm64 DLAMI SSM param exists in your region** — if it 404s, no arm64
   DLAMI is published there and `launch` fails on the AMI resolve:

   ```sh
   aws ssm get-parameter \
     --name /aws/service/deeplearning/ami/arm64/base-oss-nvidia-driver-gpu-amazon-linux-2023/latest/ami-id \
     --query Parameter.Value --output text
   ```

   If missing, set `AMI_ID` (stock AL2023 arm64 + manual NVIDIA install) or
   `DLAMI_SSM_PARAM` to a known-good arm64 SSM path.

2. **`g5g.2xlarge` service quota** — 8-vCPU type under "Running On-Demand G and
   VT instances":

   ```sh
   aws service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA
   ```

3. **Root volume ≥ 20 GiB** — driver + container-toolkit space. `launch` does
   not override the root block device; verify the AMI's default root size:

   ```sh
   aws ec2 describe-images --image-ids <arm64-ami-id> \
     --query 'Images[0].BlockDeviceMappings[*].Ebs.VolumeSize'
   ```

### 4.2 amd64 path — unchanged

```sh
deploy/aws/launch --type g4dn.xlarge --wait
# or: deploy/aws/launch --type g6.xlarge --wait
```

The amd64 AMI stays the pinned `DEFAULT_AMI_ID`
(`ami-0e383fef63b2191d4`, us-east-2 AL2023 NVIDIA DLAMI) so the containerd
runtime is deterministic across launches. For a non-us-east-2 region, set
`AMI_ID` or `DLAMI_SSM_PARAM` explicitly.

### 4.3 arm64 path

```sh
INSTANCE_TYPE=g5g.2xlarge deploy/aws/launch --wait
# ARCH is inferred from the type family; ARCH=arm64 is an explicit override
```

AMI selection order in `launch`: `AMI_ID` → explicit `DLAMI_SSM_PARAM` → the
architecture default. The arm64 default resolves the SSM float
(`resolve:ssm:<arm64 param>`), so no pin goes stale. `--wait` prints the public
IP, offers `/etc/hosts` upsert + stale host-key scrub, polls SSH, and hands off
to `setup_strimserver` (execve).

`launch` also defaults the **unset** deployment vars on arm64 (amd64 is
untouched): `DEPLOYMENT=strimserver-deployment-arm64.tar`, `DEPLOYMENT_SRC` to
the latest arm64 GitHub release asset
(`.../releases/latest/download/strimserver-deployment-arm64.tar`), and
`DEPLOYMENT_SHA256` from the arm64 `.sha256` asset. Explicit operator values in
`.env` always win. The legacy `$S3_BUCKET/$DEPLOYMENT` path still applies when
`DEPLOYMENT_SRC` is unset and `S3_BUCKET` is configured — with `DEPLOYMENT`
defaulting to the arm64 basename.

### 4.4 On-box setup (`setup_strimserver` → `deploy.sh`)

`setup_strimserver` lists the block devices and prompts for the NVMe device to
format (default `/dev/nvme1n1`; destructive). It formats ext4, mounts
`/mnt/nvme`, places the bundle from `DEPLOYMENT_SRC` (`s3://`, `https://`, or a
local file), optionally verifies `DEPLOYMENT_SHA256`, transfers the Twitch key
as a `0600` file, extracts the tar, and runs `deploy.sh`.

`deploy.sh` runs the same flow on both architectures; the arm64 rollout adds
the GPU-runtime step:

1. Inject `TWITCH_STREAM_KEY` into `config/strimserver.env` (then scrub the
   transfer file). No key → warning, egress disabled until one is set.
2. **NVIDIA runtime (new in the arm64 rollout): run `setup-gpu.sh` before the
   containerd restart** — configures the NVIDIA container runtime with
   `nvidia-ctk runtime configure --runtime=containerd --cdi.enabled --set-as-default`
   on arm64. This wires the T4G driver + the CDI spec the controller's
   `cdi.WithCDIDevices("nvidia.com/gpu=0")` requests consume, on the DLAMI's
   containerd 2.x (config v3).
3. Prepend `root='/mnt/nvme/containerd'` / `state='/mnt/nvme/containerd-state'`
   to `/etc/containerd/config.toml`, restart containerd.
4. Install the systemd unit to `/usr/local/lib/systemd/system`, `daemon-reload`.
5. Import the three images into the `strimserver` namespace:
   `ctr -n strimserver i import {controller,ffmpeg,mediamtx}-container.tar`.
6. Generate a 70-char SRT read passphrase → `/mnt/nvme/srt-passphrase`.
7. `fish-deploy.sh` — skipped loudly on aarch64 (pinned fish 4.3.1 is
   x86_64-only; fish is an operator convenience shell, not a dependency).
8. `dnf install htop`; install `openssh-experimental.rpm` when present — on
   arm64 expect the skip warning until an arm64 RPM is published (Section 7).
9. Set hostname, create `/mnt/nvme/{video-files,logs}`, move the offline
   segment into `video-files`.
10. Print the next-step commands (SSH service start, encoder configuration).

`deploy.sh` deliberately leaves the service stopped. Start it with
`deploy/aws/start_strimserver` or `ssh strimserver 'sudo systemctl start
strimserver.service'`.

## 5. Post-deploy verification (arm64)

**Host GPU / driver:**

```sh
nvidia-smi                            # T4G, driver ~595.x
cat /proc/driver/nvidia/version
ls -l /usr/lib64/libnvidia-encode.so.1   # NVENC userspace
sudo systemctl status nvidia-persistenced
```

**Controller:**

```sh
sudo journalctl -u strimserver -f
```

Lines use the `YYYY/MM/DD HH:MM:SS ...` format (Go stdlib). A healthy start
prints `starting control plane...` then `controller listening on :4000` (port
from `CONTROLLER_HTTP_PORT`).

**HTTP / WebSocket:**

```sh
curl -s http://localhost:4000/healthz    # -> ok
curl -s http://localhost:4000/status     # -> JSON status
```

WebSocket subscribe lives at `ws://localhost:4000/subscribe` (check with
`websocat`/`wscat`, or the Stream Deck plugin's Toggle Egress button, which
backs its state on this stream).

**In-container NVENC smoke** — Option A, run the ffmpeg image directly through
containerd and grep the encoder list:

```sh
sudo ctr -n strimserver run --rm \
  --env NVIDIA_VISIBLE_DEVICES=all \
  --env NVIDIA_DRIVER_CAPABILITIES=video,compute \
  docker.io/library/ffmpeg:latest nvenc-check \
  ffmpeg -hide_banner -encoders | grep -i nvenc
```

Expect `h264_nvenc` and `hevc_nvenc`. Option B — while a stage is live
(`normalize` / `scale_and_egress`), `nvidia-smi` shows the controller's ffmpeg
task attached to the GPU via CDI.

**Build-time gates on the arm64 build:**

```sh
bazel test //core/controller:image_smoke_test --platforms=//tools/bazel:linux_arm64
bazel test //core/controller/alternate/asm:phase5_checkers --platforms=//tools/bazel:linux_arm64
```

`phase5_checkers` (check-isa + check-clobbers) is arm64-native and gates the
assembly controller; `image_smoke_test` exercises the assembled image layout.

## 6. Monitoring and rollback

| Layer | What to watch | Command |
|---|---|---|
| Service | Running, restarting? | `sudo systemctl status strimserver` |
| Logs | reconcile/event lines, stage errors | `sudo journalctl -u strimserver -f` |
| Control plane | liveness + status | `curl -s localhost:4000/healthz`, `.../status`, `ws://.../subscribe` |
| Host GPU | driver, temps, ffmpeg attach | `nvidia-smi`; `sudo systemctl status nvidia-persistenced` |
| Containerd | containers / tasks in the namespace | `sudo ctr -n strimserver containers list`; `sudo ctr -n strimserver tasks list` |

**Rollback:** the deployment tar is fully self-contained — the three image tars
plus config/scripts live inside it, with no external runtime dependencies. To
revert, point `DEPLOYMENT_SRC` at the previously published bundle (keeping
`DEPLOYMENT_SHA256` authoritative), then relaunch the previous architecture,
e.g. `deploy/aws/launch --type g4dn.xlarge --wait`. Tear down the abandoned
instance with `deploy/aws/terminate -y` (matches the `Project` tag).

## 7. Known blockers / TODOs — CRITICAL

| # | Blocker | Impact | Resolution track |
|---|---|---|---|
| 1 | **arm64 ffmpeg artifact is NOT yet published** | **BLOCKED for production cutover** | Out-of-band `linux-sbsa` ffmpeg build (`tools/ffmpeg-dist/publish.sh`), then repoint the `@ffmpeg_dist` pin in `MODULE.bazel` |

The arm64 `ffmpeg_image` currently embeds the **amd64** ffmpeg binary; no script
change can fix it until an NVENC-capable arm64 ffmpeg artifact exists and is
repinned. Because T4G is `sm_75` with gencode identical to the T4, the rebuild
is architecture-only — no `-gencode` change. Treat this as the **hard gate** for
the cutover: do not run a full arm64 production rollout off the current bundle.

| # | Blocker | Impact | Resolution track |
|---|---|---|---|
| 2 | openssh arm64 RPM not published | Experimental sshd unavailable on arm64; deploy prints the skip warning | Out-of-band arm64 OpenSSH rebuild via `tools/openssh/publish.sh`; the bundled RPM is amd64-only today |
| 3 | Smoke-test scripts not arch-parameterized | `ffmpeg_smoke_test.sh` / `mediamtx_smoke_test.sh` hardcode the x86_64 loader + multiarch lib paths | Parameterize the `run_dynamic` loader/multiarch dirs; the arm64 tar is already verified runnable |

## 8. Architecture / migration rationale

- **Why arm64:** better cost / price-performance from Graviton2 CPUs plus the
  T4G GPU, versus the x86_64 GPU instances of the original deployment.
- **Why `g5g.2xlarge`:** an NVIDIA-validated configuration (the smallest
  `g5g.xlarge`, with 8 GiB RAM, fails this workload's controller + three-stage
  container + NVMe/deploy memory footprint).
- **Same gencode:** T4G is Turing `sm_75`, identical to the T4. The FFmpeg
  build's `-gencode arch=compute_75,code=sm_75` needs no change — only a new
  architecture build.
- **ISA floor:** the assembly controller targets armv8.2-a precisely (Neoverse
  N1 / Graviton2 parity); `check-isa.sh` rejects anything above it, so the
  binary is portable to production without recompiling.

Region note: arm64 NVIDIA DLAMIs are availability-dependent. If the SSM float
in your region comes up empty, fall back to a stock arm64 AL2023 AMI with the
NVIDIA driver + container toolkit installed manually (via `AMI_ID`).