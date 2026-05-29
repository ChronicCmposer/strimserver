# strimserver

`strimserver` is a GPU-accelerated live-stream relay and transcoding appliance for running a cloud-side streaming endpoint. It accepts an encrypted SRT contribution feed, routes the feed through MediaMTX, normalizes video/audio timing and format with FFmpeg, records the normalized stream, and publishes a Twitch-compatible RTMP egress stream.

The project is designed around a local encoder plus an AWS GPU instance. A local OBS/FFmpeg workflow sends MPEG-TS over SRT to the EC2 host; the EC2 host uses NVIDIA CUDA/NVENC/NVDEC to normalize the input into low-latency HEVC Main10, scale it to an egress resolution, encode H.264/AAC, and forward the result to Twitch. Deployment scripts package the container image, configuration, transcode scripts, systemd service, and offline fallback media into an S3-hosted deployment bundle.

## Features and capabilities

- Encrypted SRT ingest on a configurable port, defaulting to `9000`.
- MediaMTX-based stream routing with separate `ingress0` and `normalized` paths.
- RTSP readback inside the container for FFmpeg processing, defaulting to port `8554`.
- Always-available fallback playback for `ingress0` using `strimserver-offline-2160p60.mp4` when the live source is not ready.
- Two-stage FFmpeg processing pipeline:
  - `normalize`: reads `ingress0`, forces 60 fps constant frame-rate timing, uploads frames to CUDA, encodes HEVC Main10 with `hevc_nvenc`, resamples audio to 48 kHz stereo, and writes MPEG-TS to a Unix socket.
  - `scale_and_egress`: reads `normalized`, decodes HEVC on CUDA, scales to the configured output height, encodes H.264 with `h264_nvenc`, encodes AAC audio with `libfdk_aac`, and pushes RTMP/FLV to Twitch.
- Low-latency FFmpeg settings, including small probe/analyze windows, no B-frames, NVENC ultra-low-latency tuning, constant bitrate control, direct I/O flags, and short GOPs.
- Configurable normalized and egress video bitrate, maxrate, minrate, buffer size, audio bitrate, output height, Twitch ingest server, and Twitch stream key.
- Optional Twitch bandwidth-test mode via the `BANDWIDTH_TEST` environment variable.
- MPEG-TS recording of the normalized stream through MediaMTX, with 10-second recording parts, one-hour segments, 50 MB max part size, and no automatic deletion by default.
- Runtime configuration rendering with `envsubst` from `core/mediamtx.yaml.template` and `core/strimserver.env`.
- Docker/containerd runtime with host networking, GPU access, `CAP_SYS_NICE`, elevated process priority, and bind-mounted config, logs, secrets, scripts, and video files.
- AWS deployment packaging through `make publish-strimserver`, producing a deployment tarball and uploading it to S3.
- EC2 setup automation for formatting and mounting NVMe ephemeral storage at `/mnt/nvme`, installing the systemd unit, importing the OCI image into containerd, generating the SRT passphrase, and preparing config/log/video directories.
- Local encoder helper scripts for configuring `/etc/hosts`, writing the SRT passphrase into a local env file, and streaming an OBS-provided FIFO to the EC2 ingest endpoint.
- Offline “be right back” screen generation helpers for 1080p60, 1440p60, and 2160p60 HEVC files.
- Optional `iperf3` bandwidth-test container and deployment scripts.
- Optional Haivision SRT build/test container for validating SRT dependencies.

## Build dependencies and versions

### Pinned or declared repository dependencies

| Component | Version / source | Where used |
| --- | --- | --- |
| NVIDIA CUDA build image | `nvidia/cuda:13.0.2-devel-ubuntu24.04` | FFmpeg build stage in `core/Dockerfile` |
| FFmpeg | Git branch `release/8.0` | Custom FFmpeg build with NVENC/NVDEC, CUDA filters, RTSP/SRT/RTMP-related muxing, and `libfdk_aac` |
| FFmpeg nv-codec-headers | `n13.0.19.0` | NVIDIA codec integration for FFmpeg |
| Runtime base image | `debian:trixie-20260202-slim` | Final strimserver container runtime |
| MediaMTX | `v1.17.0`, Linux amd64 release tarball | SRT ingest, RTSP routing, Unix MPEG-TS source, recording hooks, and process hooks |
| OBS Studio | `32.1.2` Ubuntu 24.04 `.deb` URL declared in `core/Dockerfile` | Runtime package included in the container image |
| `libfdk-aac` | `libfdk-aac-dev` in build stage; `libfdk-aac2t64` in runtime stage | AAC encode support through FFmpeg |
| iperf3 | `3.19.1-r1` | Bandwidth-test container |
| Fish shell | Declared as `4.0.2-r0`; installed from distro package repositories | Shell utilities and deployment helpers |
| gettext / `envsubst` | Declared as `0.24.1-r1`; `gettext-base` installed from distro package repositories | MediaMTX template rendering |

### Host build and deployment tools

These tools are required by the repository but are not pinned by the source tree:

- GNU Make.
- BuildKit / `buildctl`. The strimserver build target expects a BuildKit daemon reachable at `tcp://127.0.0.1:1234`.
- AWS CLI with credentials authorized to read and write the configured S3 bucket and launch/manage EC2 instances.
- `jq`, used by AWS helper scripts.
- Python 3, used by EC2 launch/setup/termination helpers.
- `tar`, `sudo`, OpenSSH client, and standard POSIX shell tooling.
- NVIDIA-capable build/runtime environment for validating GPU FFmpeg behavior.

## Build instructions

Clone the repository:

```bash
git clone https://github.com/ChronicCmposer/strimserver.git
cd strimserver
```

Create the runtime configuration file and fill in the Twitch and bitrate settings:

```bash
cp core/strimserver.env.example core/strimserver.env
$EDITOR core/strimserver.env
```

Prepare a local artifact output directory:

```bash
export OUTPUT_PATH="$HOME/local-dev/strimserver"
mkdir -p "$OUTPUT_PATH"
```

Create or provide the offline fallback segment expected by the deployment bundle. The default Makefile expects this file at `$OUTPUT_PATH/strimserver-offline-2160p60.mp4`:

```bash
# Option A: generate the default 2160p60 fallback clip on a machine with a compatible FFmpeg setup.
. tools/brb-screen/bslib.sh
generate2160p
cp ~/Downloads/strimserver-offline-2160p60.mp4 "$OUTPUT_PATH/"

# Option B: copy an already-created fallback file into place.
cp /path/to/strimserver-offline-2160p60.mp4 "$OUTPUT_PATH/"
```

Start or connect to a BuildKit daemon. For the default strimserver build, `buildctl` must be able to reach `tcp://127.0.0.1:1234`. The helper scripts in `tools/buildkit-scripts/` can be used to deploy and tunnel to a remote BuildKit daemon if desired.

Configure the S3 bucket where deployment artifacts will be published:

```bash
export S3_BUCKET="s3://your-bucket-name"
```

Build and publish the strimserver deployment bundle:

```bash
make publish-strimserver
```

The default target builds an OCI image named `docker.io/library/strimserver:latest`, writes `strimserver-container.tar` under `$OUTPUT_PATH`, packages the container image together with config/scripts/service files and the offline segment, uploads `strimserver-deployment.tar` to `$S3_BUCKET`, and removes the local deployment tarball after upload.

Optional build targets:

```bash
# Build the Haivision SRT test image.
make build-libsrt

# Build and publish the iperf3 bandwidth-test deployment bundle.
make publish-iperf3
```

## AWS EC2 deployment target

The intended deployment target is an AWS EC2 `g6.2xlarge` instance running the latest Amazon Linux 2023 Deep Learning AMI (DLAMI), with the instance's NVMe ephemeral storage mounted at `/mnt/nvme`.

Expected target characteristics:

- Instance type: `g6.2xlarge`.
- AMI family: latest Amazon Linux 2023 DLAMI.
- GPU/container runtime: NVIDIA driver and container tooling supplied by the DLAMI.
- Storage: NVMe ephemeral device formatted as `ext4` and mounted at `/mnt/nvme` by `deploy/aws/setup_strimserver`.
- Runtime: containerd with its root and state directories moved under `/mnt/nvme`.
- Network access:
  - inbound SSH from the operator machine;
  - inbound SRT ingest, default UDP port `9000`, from the local encoder;
  - outbound access to S3 for deployment artifact retrieval;
  - outbound RTMP to the configured Twitch ingest server.
- IAM permissions sufficient to read the deployment bundle from S3. The machine used for build/publish also needs permission to write that bundle to S3.

The EC2 launch helper currently references project-specific launch template names. Use it with the requested target instance type, or adapt the launch templates to use the latest Amazon Linux 2023 DLAMI and the security/IAM settings above:

```bash
cp deploy/aws/.env.example deploy/aws/.env
$EDITOR deploy/aws/.env
set -a
. deploy/aws/.env
set +a

# Launch through the configured launch template, overriding the instance type.
deploy/aws/launch --type g6.2xlarge
```

After the instance is reachable over SSH, run the setup script from the local machine:

```bash
deploy/aws/setup_strimserver
```

`setup_strimserver` will display the remote block devices and prompt for the NVMe device to format. The default is `/dev/nvme1n1`. This is destructive to the selected device.

When setup completes, it prints the generated SRT passphrase and a suggested local encoder configuration command. Start and stop the systemd service with:

```bash
deploy/aws/start_strimserver
deploy/aws/stop_strimserver
```

The service runs the imported `docker.io/library/strimserver:latest` image through `ctr`, with host networking, GPU access, elevated scheduling priority, and bind mounts rooted in `/mnt/nvme`.

## Local encoder setup

Create a local encoder env file:

```bash
cp tools/local-encoder/local-encoder.env.example ~/.strimserver-local-encoder.env
$EDITOR ~/.strimserver-local-encoder.env
export LOCAL_ENCODER_ENV="$HOME/.strimserver-local-encoder.env"
```

Make sure the env file contains a valid `FFMPEG_CMD`, `INPUT_FIFO`, `SRT_PASSPHRASE`, and `FFMPEG_NICE` value. The local encoder script validates `FFMPEG_NICE`; add it to the env file if it is not already present.

Use the command printed by the EC2 deploy script to set the remote host and generated passphrase:

```bash
configure-local-encoder.zsh --strimserver-host <public-ip> --passphrase <generated-passphrase>
```

Run the local encoder:

```bash
tools/local-encoder/local-encoder.zsh
```

The local encoder reads the configured OBS FIFO, copies video and audio without local re-encoding, wraps them as MPEG-TS, and publishes to `srt://<host>:9000` with `streamid=publish:ingress0`.

## Possible future enhancements

- Add first-class support for additional egress targets beyond Twitch, such as YouTube, Kick, custom RTMP endpoints, HLS, or SRT output.
- Add multi-destination simulcast with per-platform bitrate, resolution, and codec profiles.
- Add health checks, readiness checks, and automatic restart/backoff policies for FFmpeg subprocess failures.
- Add structured metrics and dashboards for ingest bitrate, dropped frames, encoder load, GPU utilization, RTMP reconnects, SRT latency, and recording status.
- Add alerting for missing ingest, failed Twitch egress, failed recordings, or full NVMe storage.
- Add automatic cleanup/retention policies for recorded segments, with configurable upload/archive to S3.
- Align the MediaMTX recording path with the deployed NVMe video-file mount, or make the recording output path configurable from `strimserver.env`.
- Add a local `docker compose` or containerd development profile for non-AWS smoke tests.
- Add automated CI for shell linting, Dockerfile builds, and basic FFmpeg/MediaMTX configuration validation.
- Add integration tests that emulate SRT ingest and verify normalized stream creation, recording, and RTMP egress behavior.
- Add explicit version pinning for host tooling and distro-installed runtime packages.
- Add support for newer/alternate NVIDIA architectures by parameterizing the FFmpeg CUDA `-gencode` target.
- Add safer secret handling for Twitch stream keys and SRT passphrases through AWS Secrets Manager or SSM Parameter Store.
- Add a documented path for updating MediaMTX, FFmpeg, CUDA, OBS, and nv-codec-headers versions together.
- Add Terraform, CloudFormation, or CDK infrastructure for reproducible EC2, IAM, S3, security group, and launch template setup.

## Contributing

Contributions are accepted through pull requests on GitHub: https://github.com/ChronicCmposer/strimserver

Recommended workflow:

1. Fork the repository on GitHub.
2. Create a feature branch from the default branch:

   ```bash
   git checkout -b feature/your-change
   ```

3. Make the change with focused commits.
4. Test the affected path. Examples include building the strimserver image, running shell scripts with a safe test configuration, validating the SRT test image, or testing EC2 deployment changes against a disposable instance.
5. Update documentation when behavior, configuration, deployment steps, or defaults change.
6. Open a pull request against `ChronicCmposer/strimserver` with:
   - a summary of the change;
   - the motivation for the change;
   - the test/build/deployment commands that were run;
   - any compatibility or migration notes.

Avoid committing secrets, Twitch stream keys, generated SRT passphrases, local `.env` files, deployment artifacts, container tarballs, or recorded video files.

## License

This project is licensed under the MIT License. See `LICENSE` for details.
