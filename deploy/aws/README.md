# strimserver dual-architecture deployment runbook

This runbook walks the staged cutover from the existing **amd64** deployment to
the **arm64** (`g5g.2xlarge`) deployment, and is the reference for anyone
re-deploying later. The build produces one self-contained deployment bundle per
controller language and architecture (the Go controller and the C controller,
each for amd64 and arm64); `deploy/aws/launch` picks an architecture-aware AMI
from the instance type, so the operator's cutover decision is just **which
bundle URL and instance type to point at**. Section 7 lists blockers that gate
the production cutover — read it before any arm64 launch.

## 1. Architecture overview

| | amd64 (current) | arm64 (cutover target) |
|---|---|---|
| Instance | `g4dn.xlarge` (x86_64 + T4) / `g6.xlarge` (L4) | `g5g.2xlarge` (Graviton2 + T4G) |
| CPU ISA | x86_64 | arm64, armv8.2-a (Neoverse N1) |
| GPU / gencode | T4 `sm_75` (L4 `sm_89` on g6) | T4G `sm_75` — same gencode as T4 |
| AMI | Pinned x86_64 AL2023 NVIDIA DLAMI 20261106 (`DEFAULT_AMI_ID`, us-east-2) — **pins the AMI, not the installed driver** (see §1.1) | arm64 AL2023 NVIDIA DLAMI via the SSM float `.../arm64/base-oss-nvidia-driver-gpu-amazon-linux-2023/latest/ami-id` — also does not pin the installed driver |
| Driver (installed) | `nvidia-open 620.70.06` floor, enforced by `setup-gpu.sh`; the staged-version validator covers `kmod-nvidia-open*` and exempts only the policy-only `nvidia-driver-selinux` (see §1.1) | same `620.70.06` floor via `nvidia-open-620.70.06-1.amzn2023.noarch` (arm64 caveat in §1.1) |
| Controller in image | Go controller (the oracle), pure-Go static `linux/amd64` | Go controller (the oracle), pure-Go static `linux/arm64`; the alternate asm build (`//core/controller/alternate/asm:controller_asm`) is explicit/manual |

### 1.1 GPU driver floor contract

The host GPU driver is a **versioned contract**, not an incidental AMI
property. Both architectures require driver **620.70.06** with CUDA 13.5:

| Item | Contract |
|---|---|
| Driver floor | `620.70.06` exactly (CUDA 13.5 requires R620 with zero headroom; never a floating `>=620`) |
| amd64 RPM | `nvidia-open-3:620.70.06-1.el9` |
| arm64 RPM | `nvidia-open-620.70.06-1.amzn2023.noarch` (published in `amzn2023/sbsa`; see caveat below) |
| CUDA | 13.5 |
| GPU / gencode | `sm_75` (T4 and T4G) |
| GSP firmware | **required** — `gsp_tu10x.bin`; never set `NVreg_EnableGpuFirmware=0` |

The AMI is pinned for **determinism** (`DEFAULT_AMI_ID`,
`ami-0198b63ccfac121e8`), but the AMI pin does **not** pin the installed driver:
the DLAMI ships whatever driver its build carried, and the arm64 `/latest`
float likewise does not pin it. `setup-gpu.sh` (via `lib/nvidia.sh`) enforces the
floor: it detects the installed driver, upgrades to the pinned NEVRA when below
the floor, never downgrades, confirms `gsp_tu10x.bin`, and **fails closed** if
the floor cannot be met.

#### Driver upgrade mechanics (`lib/nvidia.sh`)

`deploy/aws/setup-gpu.sh` sources `deploy/aws/lib/nvidia.sh` (bundled as
`lib/nvidia.sh`) and calls `nvidia_ensure_driver_floor` before any `nvidia-smi`
guard. The upgrade path is offline-staged and ordered so a failure never leaves
the host without a usable driver:

1. **Detect** the installed version with precedence `proc -> modinfo -> rpm ->
   nvidia-smi`. The *verification* path is stricter: it reads only
   `/proc/driver/nvidia/version` so an on-disk 620 with a still-loaded 595 can
   never be reported healthy.
2. **At/above the floor but not loaded** (module on disk, nothing serving the
   GPU): run `depmod -a` + `modprobe nvidia`, then re-verify. Nothing is
   reinstalled.
3. **Below the floor:** add the per-arch CUDA repo and import its signing key,
   then stage the full 620 dependency closure with `dnf install --downloadonly`
   into `/mnt/nvme/nvidia-rpm`. The stage leaf is created under a root-owned
   `mktemp -d` and normalized to `0755`; a missing parent is created `0755`,
   while an existing mount root such as `/mnt/nvme` is only checked for
   traversal and never chmodded blindly (see *Staging directory access* below).
   The required `nvidia-open` NEVRA is staged first
   in its own transaction; any RPM-managed fabricmanager/persistenced unit
   package is **availability-gated** (matching arch, exactly one version
   at/above `620.70.06`) and staged separately. An unavailable or failed
   optional package is omitted with a warning and never aborts the required
   closure. The staged RPMs must include `nvidia-open`, `nvidia-driver-cuda`,
   and a kmod/DKMS kernel module, must pass `rpm -K`, and must satisfy the
   payload gate before the old driver is touched:
   - a staged prebuilt `kmod-nvidia-open` RPM must contain `nvidia.ko` for the
     running kernel;
   - a staged `kmod-nvidia-open-dkms` (or `nvidia-open-dkms`) RPM must contain
     `dkms.conf`, and the `dkms` tool plus the running kernel's build tree must
     already be present or supplied by the staged closure (see *Kernel build
     prerequisites* below); the DKMS source must also prove it can build for
     `uname -r`;
   - the `nvidia-open` metapackage carries no kernel module and is exempt.

   The staged closure must contain the 620 `gsp_tu10x.bin` (or the host must
   already have it). The new stage is swapped in atomically
   (backup -> rename -> drop backup).
4. **Versionlock caveat:** `/etc/dnf/plugins/versionlock.list` commonly pins
   `nvidia-fabricmanager`/`libnvidia-nscq` at the old branch. Before staging,
   `lib/nvidia.sh` backs the file up and temporarily removes the
   `nvidia-fabricmanager`/`nvidia-persistenced` locks. The staged-version
   validator (below) then asserts every staged driver payload — `nvidia-*`,
   `libnvidia-*`, and `kmod-nvidia-open*` — reports `%{VERSION}` `620.70.06`,
   exempting only the policy-only `nvidia-driver-selinux`. The original file is
   restored from an EXIT trap and explicitly on validator failure; do not
   hand-edit the lock file during an upgrade.
5. **Resume marker:** the first destructive action writes
   `/var/lib/strimserver/driver-upgrade.state`. The marker records whether
   fabricmanager and persistenced were active before the drain (and whether the
   fabricmanager 620 package was staged), so a resumed run never restores a
   unit that was originally inactive. If the marker cannot be written the
   upgrade aborts before the drain. On any later failure the marker is left in
   place so re-running `setup-gpu.sh` resumes the same upgrade; a marker whose
   loaded `/proc` driver is already at the floor short-circuits straight to
   restore/verify. There is no reboot and no auto-rollback service.
6. **Drain holders:** stop `strimserver`, fabricmanager, the DCGM *exporter*
   before `nvidia-dcgm`, then persistenced and containerd; wait (bounded) for
   the DCGM units to go inactive and fail if any `/dev/nvidia*` holder survives.
   DCGM/exporter stay stopped afterwards — strimserver never uses them.
7. **Swap:** remove a `.run`-managed payload when present, install the validated
   closure offline (`--allowerasing --disableexcludes=all --disablerepo='*'`),
   confirm the module for the running kernel is 620 (for DKMS, `dkms status`
   must show `nvidia-open/620.70.06` for `uname -r`; a successful `dnf install`
   alone is not success), remove only stale below-floor DKMS builds,
   `depmod -a`, unload the old module graph dependency-first, then
   `modprobe nvidia` + `nvidia_uvm`.
8. **Verify:** proc driver at/above the floor, `nvidia-smi` compute capability
   `7.5`, `/dev/nvidia0`, and the GSP firmware file; then restore **only the
   units that were active before the drain**. Fabricmanager is optional on
   T4/g4dn: it starts only when it was active *and* its 620 package was staged,
   and a start failure is a loud warning, not a failure. Persistenced failure is
   fatal. DCGM/exporter and containerd are never restarted here. Finally remove
   the marker.

#### Kernel build prerequisites (AL2023)

A DKMS build needs the **running kernel's build tree**, not a particular package
name. Before any driver uninstall/install, `nvidia__ensure_dkms_prereqs` treats
the actual tree as authoritative and checks both
`/usr/src/kernels/$(uname -r)/Makefile` and
`/lib/modules/$(uname -r)/build`.

- On AL2023 6.12 hosts those paths are installed by `kernel6.12-devel` and
  `kernel6.12-headers`; the legacy `kernel-devel` / `kernel-headers` names are
  not the versioned packages for the running kernel.
- If the build tree is absent, the staged `kernel*-devel-*.rpm` /
  `kernel*-headers-*.rpm` are installed. During staging,
  `nvidia__kernel_prereq_specs` resolves the correct repo package names for the
  running kernel, including the AL2023 `kernel6.12-*` names, and adds them to
  the required closure.
- A missing prerequisite still fails closed (`nvidia: ERROR [kernel-module]`)
  before any driver uninstall/install; the old driver is never removed first.

The host failure that prompted this check was a **false negative**: the required
packages were already installed under the `kernel6.12-*` names, so no host
package install is required for that case. Verify the tree, not the package
name.

The upgrade therefore needs outbound access to the NVIDIA CUDA repository at
deploy time; the RPM payload itself is staged locally before removal so an
interrupted install is recoverable from `/mnt/nvme/nvidia-rpm`. A stage that
fails validation **before the swap** leaves the host on its existing driver
(595 on the reference host); the old driver is never uninstalled first.

#### Staged-version validation

Before the swap, `nvidia__assert_staged_versions` reads each staged RPM's
`%{NAME}`, `%{VERSION}`, and `%{ARCH}` from its own header and enforces the
driver-version contract:

- **Coverage.** The validator globs `nvidia-*.rpm`, `libnvidia-*.rpm`, and
  `kmod-nvidia-*.rpm` (which includes `kmod-nvidia-open*`), so
  `kmod-nvidia-open*` is version-checked and a non-620 kernel-module RPM cannot
  slip through staging.
- **Floor.** Every staged driver payload must report `%{VERSION}` exactly
  `620.70.06`. Release and epoch are intentionally **not** asserted; a
  same-version, different-release RPM passes.
- **Single exemption.** `nvidia-driver-selinux` (the SELinux policy module) is
  the only exact-name exemption. It must be `noarch`, policy-only, and its
  `rpm -qlp` listing must
  contain no `/lib/modules/**/*.ko` and no `/libnvidia*.so`. Near-miss names
  (`nvidia-driver-selinux-devel`, `nvidia-driver-selinux-extra`,
  `nvidia-driver-selinux.x86_64`) are **not** exempt and are asserted against
  the floor.
- **Zero-driver stage.** A stage with no asserted driver RPM fails, even when an
  exempt policy package is present.
- **Fail closed.** Unreadable or non-regular staged paths, nonzero `rpm` exits,
  and empty/`(none)`/malformed header fields fail closed with an
  `nvidia: ERROR [closure]` line naming the path and stating that no driver
  action was taken.

On any validator failure inside `nvidia__stage_closure`, the original
`/etc/dnf/plugins/versionlock.list` is restored explicitly (the EXIT trap is
defense in depth), and no `*.nvidia-upgrade.*` backup should remain.

#### Staging directory access

`lib/nvidia.sh` stages into a root-owned `mktemp -d`, so the leaf starts at
`0700 root:root`. Every validator (`rpm -K`, staged-version, kernel-module,
GSP, and DKMS checks) runs as the **deploying user**, which must therefore be
able to read and traverse the stage leaf **and every parent component** down to
the mount root. A `0755` leaf under a `0700` parent is still inaccessible.

- **Parent policy.** A missing stage parent is created `0755` (with `install -d
  -m 0755`). An **existing** parent — in particular the mount root `/mnt/nvme`,
  which also holds the SRT passphrase and other deploy state — is only checked
  for traversal; it is never `chmod`ed blindly. If an existing parent is not
  traversable, the run fails with `[closure]` guidance to fix it.
- **DNF success is not staging success.** `dnf install --downloadonly` can exit
  `0` and write every RPM while the deploying user still cannot see the files.
  Staging succeeds only when the staged RPM set passes the access guard and all
  validators; a stage that is missing, empty, unreadable, or non-traversable
  fails closed.
- **Failure diagnostics.** An access failure prints an `nvidia: ERROR [closure]`
  (or `[kernel-module]` for a kernel-module consumer) line naming the caller
  (`$(id -un)`), the failing directory or path component, its mode/owner when
  `stat` succeeds, and an explicit statement that no driver action was taken.
  It also prints `namei -l <dir>` when available so the operator can see which
  component denies traversal.

Inspect the stage without taking any driver action using the read-only
stage-only mode (`NVIDIA_STAGE_ONLY=1` or `setup-gpu.sh --stage-only`). It runs
repo setup, stages the closure, runs every validator, and exits `0` **before**
the resume marker, drain, uninstall, or install:

```sh
NVIDIA_STAGE_ONLY=1 ./setup-gpu.sh      # or: ./setup-gpu.sh --stage-only
namei -l /mnt/nvme/nvidia-rpm           # every component must be traversable
```

Run stage-only as the **deploying user** — the same unprivileged account that
runs `deploy.sh`, which uses `sudo` internally. Do **not** prefix it with
`sudo`: as root the readability assertions pass trivially and stop proving that
the deploy user can traverse the stage. Then confirm the printed stage directory
is `0755` and `namei -l` shows no permission denial. The failure text from a bad
stage is the same one DNF-success misdiagnosis produced in the field; treat it
as a permissions/path problem, not a DNF/`--destdir` problem.

**Acceptance runs on the host, from an extracted bundle.** For release or
cutover acceptance, upload and extract the candidate bundle on the host and run
stage-only there. Do **not** export `NVIDIA_STAGE_ONLY=1` locally before
`setup_strimserver`: `setup_strimserver` runs `deploy.sh`, which invokes
`setup-gpu.sh` with no arguments, so the variable is not forwarded and the run
would perform the full destructive upgrade instead of a stage-only probe.

**Rollback artifact requirement:** because the 595 branch is not in the CUDA
repository, an in-place rollback needs a **preserved pre-upgrade artifact** — the
original 595 `.run` installer or the previous `nvidia-rpm` closure — archived
off-host before the first destructive step. The reference host is `.run`-managed
and the stage closure lives on instance-store `/mnt/nvme`, so stopping or
terminating the instance **loses the stage closure**; a stage kept only on the
host is not a rollback artifact. Without a verified off-host 595 artifact,
rollback is **replacement-only**: replace the instance from the pinned AMI.
`setup-gpu.sh` never downgrades and the deployment bundle contains no driver.
Preserve and verify the 595 artifact before upgrading (see §6).

**arm64 caveat:** `nvidia-open-620.70.06-1.amzn2023.noarch` is published in
`amzn2023/sbsa`, but AL2023 **generic Arm64 is outside the vendor's 620 support
matrix** (and `sbsa` `cuda-drivers` tops out at 610.57.04). The arm64 RPM epoch
is unverified, so a T4G acceptance run (Phase 8) is required before treating
arm64 as supported.

The controller image is platform-selected in `core/controller/BUILD.bazel`:
both amd64 and arm64 ship the pure-Go controller binary (static, so it needs
no loader/libs on a scratch image), landing at `/strimserver-controller`.
The alternate assembly controller (`//core/controller/alternate/asm:controller_asm`)
is an explicit/manual build — it is no longer bundled in the arm64 image.

The deployment bundle is per-controller and per-architecture: `--platforms`
(or the arm64 platform transition) selects the controller binary, the image
architectures, and the multiarch lib paths (`lib/x86_64-linux-gnu` vs
`lib/aarch64-linux-gnu`). Every release publishes **four bundles under
fully-explicit names — `strimserver-deployment-{go,c}-{amd64,arm64}.tar`**
(the Go controller and the C controller, each for amd64 and arm64, all with
`.sha256`) — the explicit basenames avoid runfiles collisions and keep all
four bundles separate on one GitHub release / S3.

## 2. Building the bundle

```sh
# Builds ALL FOUR bundles (+ checksums) in ONE invocation:
bazel build //:package_all
#   bazel-bin/strimserver-deployment-go-amd64.tar(.sha256)  Go amd64
#   bazel-bin/strimserver-deployment-go-arm64.tar(.sha256)  Go arm64
#   bazel-bin/strimserver-deployment-c-amd64.tar(.sha256)   C amd64
#   bazel-bin/strimserver-deployment-c-arm64.tar(.sha256)   C arm64
```

Or build the Go bundles alone: `bazel build //:package` (Go amd64, the
default) / `bazel build //:package_arm64` (Go arm64); the arm64 path runs the
same unchecked tar under `//tools/bazel:linux_arm64` via a platform transition
(`tools/bazel/platform_transition.bzl`). The C bundles are built only through
`//:package_all` (they need the zig musl transition
`//:c_controller_transition`). Bundle builds refuse to run while
`TWITCH_STREAM_KEY` is set, `ENABLE_DDNS` is `true`, or `DDNS_DOMAIN` is
non-empty in `core/strimserver.env` — the key and the Dynamic DNS settings are
injected at deploy time, never baked into the bundle (the redistributable
bundle ships DDNS disabled).

Publish to GitHub (requires `gh auth login` and a pushed tag); `//:release`
uploads all four tars and all four `.sha256` assets:

```sh
GIT_TAG=v1.0.0 bazel run //:release
```

Each bundle carries a generated `strimserver.service` systemd unit (expanded by
Bazel from `deploy/aws/strimserver.service.template`) matching its controller:
Go bundles ship the unit referencing the image
`docker.io/library/strimserver-controller-go:latest` and the container
`strimserver-controller-go`; C bundles reference
`docker.io/library/strimserver-controller-c:latest` and the container
`strimserver-controller-c`. There is no static unit file anymore — each bundle
contains exactly one unit for its controller.

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
`strimserver` IAM service account. A single project-scoped `strimserver-operator`
policy is attached to that account — a single managed policy because
CloudFormation cannot reliably manage two `AWS::IAM::ManagedPolicy` resources
attached to the same user. It grants only the inventoried operator surface: S3
read/write and object-ACL on the deployment bucket, EC2 describe (including
`DescribeImages` for the check-deps DLAMI metadata resolver)/run/terminate plus
`CreateTags`, `cloudformation:DescribeStacks` on `stack/strimserver/*`
(read-only — the stack lifecycle is admin-run), both DLAMI SSM parameters
(`ssm:GetParameter` on the x86_64 and arm64 families, so the check-deps AMI
resolver can float the arm64 AMI in any region where it exists), self access-key
rotation, and `iam:PassRole` on `role/strimserver*` conditioned on
`iam:PassedToService` = `ec2.amazonaws.com`. It carries no account-wide IAM
administration and no DNS-zone access.

Deploy (or update) the stack with admin credentials. `deploy-infra` is
admin-run: it deploys the stack (the operator policy cannot manage the stack —
it only calls `cloudformation:DescribeStacks`), then rotates the service
account's access key into the local `[strimserver]` profile (never
`[default]`), backing up
`~/.aws/credentials` first with a timestamp, writes `[profile strimserver]`
with the resolved region into `~/.aws/config` (backed up, other sections
preserved), and asserts the fresh key authenticates as
`arn:...:user/strimserver` before reporting success:

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

Every strimserver tool that talks to AWS (`deploy-infra` excepted — it is
admin-run) selects this account through the `[strimserver]` profile by pinning
`--profile "${AWS_PROFILE:-strimserver}"`, and refuses to run unless
`aws sts get-caller-identity` reports an ARN ending `:user/strimserver` (the
identity guard). Set `AWS_PROFILE` to point at a different profile only when
that profile is also the strimserver operator.

`KEY_NAME` (the EC2 key pair) is **not** a stack parameter — it is set in
`deploy/aws/.env` and consumed by `launch`.

`SSH_IDENTITY` — also set in `deploy/aws/.env` — holds the full path to the
operator's SSH private key. `launch`'s SSH probe, `setup_strimserver`, and the
`scp` uploads append it to their ssh/scp invocations as `-i <path>`; when it is
empty they omit `-i` entirely and rely on the agent / default keys, exactly as
before. `SSH_CMD` stays a plain `ssh` — key selection is `SSH_IDENTITY`, not
flags in `SSH_CMD`. The path is an operator secret: it lives only in your
gitignored `deploy/aws/.env`, never in committed files.

## 4. Launch — staged cutover

```sh
cp deploy/aws/.env.example deploy/aws/.env
$EDITOR deploy/aws/.env   # KEY_NAME, SSH_IDENTITY, DEPLOYMENT_SRC, DEPLOYMENT_SHA256, TWITCH_STREAM_KEY, DDNS_PASSWORD, ENABLE_DDNS, DDNS_HOST, DDNS_DOMAIN, INSTANCE_TYPE
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
(`ami-0198b63ccfac121e8`, us-east-2 AL2023 NVIDIA DLAMI 20261106) so the containerd
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
IP, cleans up stale `/etc/hosts` entries left by pre-DDNS launches (the old
`/etc/hosts` upsert is gone — the box is bootstrapped by its raw public IP
because `strim.example.com` doesn't resolve until `deploy.sh` registers it),
polls SSH, and hands off to `setup_strimserver` (execve).

`DEPLOYMENT_SRC` is the primary source selector (`s3://`, `http(s)://`, or a
local path). When `DEPLOYMENT` is unset, `setup_strimserver` derives the on-box
artifact filename from the **basename** of `DEPLOYMENT_SRC`, so
`.../strimserver-deployment-c-amd64.tar` lands as
`/mnt/nvme/strimserver-deployment-c-amd64.tar` — never as a Go-named file.
`DEPLOYMENT` is an explicit override of that on-box filename; it is required
only for the legacy `$S3_BUCKET/$DEPLOYMENT` path, which defaults to the
go-amd64 basename (`strimserver-deployment-go-amd64.tar`).

`launch` defaults the **unset** deployment vars on arm64 (amd64 is untouched):
when neither `DEPLOYMENT_SRC` nor `S3_BUCKET` is provided, it sets
`DEPLOYMENT=strimserver-deployment-go-arm64.tar` (the Go controller bundle),
`DEPLOYMENT_SRC` to the latest arm64 Go GitHub release asset
(`.../releases/latest/download/strimserver-deployment-go-arm64.tar`), and
`DEPLOYMENT_SHA256` from the arm64 Go `.sha256` asset. When `DEPLOYMENT_SRC` is
provided, `launch` leaves `DEPLOYMENT` unset so `setup_strimserver` derives it
from the source's basename. An explicit `DEPLOYMENT` selects the matching
default asset/sha when no source is provided. Explicit operator values in
`.env` always win.

### 4.4 On-box setup (`setup_strimserver` → `deploy.sh`)

`setup_strimserver` selects the NVMe instance-store device automatically and
never assumes a device index. It reads `lsblk -dnrno NAME,TYPE,MODEL`, keeps
whole disks (`TYPE=disk`) whose model normalizes (whitespace-collapsed,
case-folded) to `Amazon EC2 NVMe Instance Storage`, and falls back to
`nvme id-ctrl` / `/sys/block/<dev>/device/model` when the model is missing from
`lsblk`. If more than one instance-store disk is present it sorts candidates
numerically (`nvme2n1` before `nvme10n1`) and uses the lowest one, warning that
the others remain unmounted and that `NVME_DEVICE` can pick one explicitly.
`/dev/nvme1n1` is **not** a default; on the reference host it is the root EBS
disk.

`NVME_DEVICE` is an optional override:

- An absolute path is preferred (`NVME_DEVICE=/dev/nvme0n1`).
- A bare name is normalized to `/dev/<name>` (`NVME_DEVICE=nvme0n1`).
- Empty or whitespace-only means "unset" and re-enables model selection.
- The override wins over model selection but is still canonicalized
  (`realpath -e`), required to be an existing whole NVMe disk, and passed
  through the same safety check. Overrides are not model-verified.

The default (auto) path is non-destructive: it reuses an existing ext4
filesystem and mounts it, formatting ext4 only when the selected device has no
filesystem. Only `--format` prompts and is destructive; `--no-format` reuses
only and fails if the device has no filesystem. `--select-only` (alias
`--dry-run`) resolves and safety-checks the device, prints `selected device:`,
`model:`, `size:`, and a `safety:` verdict, then exits before any download,
secret transfer, mount, or `mkfs`. It does not require `DEPLOYMENT_SRC`.

Before any `blkid`, `mount`, or `mkfs`, `setup_strimserver` refuses to touch a
target that:

- backs the root filesystem (resolved through partitions/LVM/RAID/btrfs);
- is already mounted, or has any mounted child;
- has any partition or child device, or a non-empty partition table;
- is in use as swap;
- is not an existing block device.

Safety probes are fail-closed: a probe transport/parse failure is a refusal,
not a pass. Representative exact failure texts:

| Condition | Message |
|---|---|
| No instance store found | `no Amazon EC2 NVMe Instance Storage device found; set NVME_DEVICE=/dev/nvmeXn1 explicitly` |
| Root disk | `refusing to format <dev>: it backs the root filesystem` |
| Mounted | `refusing to format <dev>: it is mounted at <mountpoint>` |
| Partitioned | `refusing to format <dev>: it has partitions (<names>)` |
| Swap | `refusing to format <dev>: it is in use as swap` |
| Not a block device | `refusing: <dev> is not an existing block device` |
| Partition passed | `refusing: <dev> is a partition; pass the whole disk` |
| Probe failure | `refusing: could not verify <dev> (<probe> failed)` |
| Malformed override | `refusing: <path> is not a valid device path` |

`/mnt/nvme` handling:

- Already mounted ext4 from a non-root source: kept untouched (`NVME_DEVICE` is
  ignored, no `mkfs`, no `mount`), with a warning when the source is not the
  instance store. A mounted EBS-backed `/mnt/nvme` is therefore kept; migration
  is explicit (see §6).
- Mounted non-ext4: refused, naming the occupying source.
- Unmounted but non-empty directory: refused; back up or move the contents.

`--format` refuses when `/mnt/nvme` is already mounted, requires an interactive
terminal, prints the selected device and a `WIPING` banner, and requires an
explicit confirmation before `mkfs.ext4`. `--format` and `--no-format` are
mutually exclusive. It then places the bundle from `DEPLOYMENT_SRC` (`s3://`,
`https://`, or a local file), optionally verifies `DEPLOYMENT_SHA256`, transfers
the Twitch key,
the Namecheap Dynamic DNS password (`DDNS_PASSWORD` / `DDNS_PASSWORD_FILE` in
`.env`, mirroring the Twitch key flow), and the Dynamic DNS settings
(`ENABLE_DDNS` / `DDNS_HOST` / `DDNS_DOMAIN` in `.env`) as `0600` files,
extracts the tar, and runs `deploy.sh`. The redistributable bundle ships DDNS
disabled; the operator's settings are propagated to the box at deploy time and
written into the on-box `strimserver.env`, exactly like the Twitch key.

`deploy.sh` runs the same flow on both architectures; the arm64 rollout adds
the GPU-runtime step. The script sources pure helpers from `lib/deploy.sh`
(bundled beside it) for the passphrase, containerd root/state rewrite, and
logs-directory preparation; those helpers take the privilege prefix from the
call site and are unit-tested by `deploy_helpers_test.sh`.

Before sourcing the on-box config, `deploy.sh` merges the transferred
`ENABLE_DDNS` / `DDNS_HOST` / `DDNS_DOMAIN` (from `/mnt/nvme/ddns-config`) into
`config/strimserver.env`, so both its own DDNS block and the `strim-ddns`
unit's `EnvironmentFile` see the operator values; with no transfer file the
bundled defaults (DDNS disabled) stay in effect.

1. Inject `TWITCH_STREAM_KEY` into `config/strimserver.env` (then scrub the
   transfer file). No key → warning, egress disabled until one is set.
2. **NVIDIA runtime: run `setup-gpu.sh` before the containerd restart** — it
   enforces the `620.70.06` driver floor first (upgrade/recovery before the
   `nvidia-smi` guard, failing closed if the floor is unmet), then on amd64
   generates the JSON CDI spec the controller's
   `cdi.WithCDIDevices("nvidia.com/gpu=0")` request consumes (containerd 2.x,
   config v3). It does **not** run `nvidia-ctk runtime configure --set-as-default`:
   the default runtime stays plain `runc`, and on arm64 the raw-API assembly
   controller produces no CDI spec at all. It also enables
   `nvidia-persistenced`.
3. Prepend `root='/mnt/nvme/containerd'` / `state='/mnt/nvme/containerd-state'`
   to `/etc/containerd/config.toml`, restart containerd.
4. Install the bundle's generated systemd unit to
   `/etc/systemd/system/strimserver.service` (`install -D -m 644`), then
   `systemctl daemon-reload` and `systemctl enable strimserver.service`. The
   first start stays an explicit operator action (the container images are
   imported in the next step).
5. Import the three images into the `strimserver` namespace:
   `ctr -n strimserver i import {controller,ffmpeg,mediamtx}-container.tar`.
6. Generate a 70-char SRT read passphrase into `/mnt/nvme/srt-passphrase`
   (root:root `0600`, created once and kept on re-run). The value is **never
   printed**: the deploy log names the file only, and the operator reads it on
   the host with `sudo cat /mnt/nvme/srt-passphrase`.
7. `fish-deploy.sh` — skipped loudly on aarch64 (pinned fish 4.3.1 is
   x86_64-only; fish is an operator convenience shell, not a dependency).
8. `dnf install htop`; install `openssh-experimental.rpm` when present — on
   arm64 expect the skip warning until an arm64 RPM is published (Section 7).
9. Set hostname, create `/mnt/nvme/{video-files,logs}`, move the offline
   segment into `video-files`. The logs directory is prepared as `0750`
   root:root with the three expected log files pre-created `0640`
   (containerd's shim creates them, so a process umask cannot set their mode),
   and any existing regular file under it is normalized to `0640` root:root.
10. Configure Namecheap Dynamic DNS (`$DDNS_HOST.$DDNS_DOMAIN`, from the
    operator settings injected above): install the transferred password to
    `/etc/strim-ddns/password` (root:root `0600`, transfer file scrubbed),
    install + enable the `strim-ddns.timer` (6h,
    `Persistent=true`), import `strim-ddns-container.tar`, run a one-shot
    refresh passing `ip=$PUBLIC_IP`, then verify — retrying ~24 times with 5s
    sleeps, up to a few minutes worst-case, failing loudly on mismatch —
    that `strim.example.com` resolves to the box's public IP. Each check is a
    direct authoritative query to the domain's nameservers, run **inside** the
    `strim-ddns` container via its `check` subcommand (the container's c-ares
    DNS client discovers the NS via the resolver, then queries the
    authoritative NS directly for the A record; there is no per-query timeout
    env — the DNS client has its own internal timeout), so it is immune to the
    box's local resolver cache and needs no bind-utils/dnsutils on the box.
11. Print the next-step commands (SSH service start, encoder configuration).

`deploy.sh` deliberately leaves the service stopped — the unit is installed and
enabled, but the first start stays an explicit operator action. Start it with
`deploy/aws/start_strimserver` or `ssh ec2-user@strim.example.com 'sudo
systemctl start strimserver.service'`.

After `deploy.sh` completes, the box is reachable as `strim.example.com` (DDNS):
SSH, the local encoder (`STRIMSERVER_HOST=strim.example.com`), and the Stream
Deck plugin all use the hostname. The one-time Namecheap `strim` host +
dedicated password setup is in `deploy/aws/ddns-setup.md`; supply the password
at deploy time via `DDNS_PASSWORD` / `DDNS_PASSWORD_FILE`.

**Tag/upgrade note:** the Go controller image tag gained the `-go` suffix —
`strimserver-controller-go:latest` replaces the previous bare
`strimserver-controller` tag (the C controller has always shipped as
`strimserver-controller-c:latest`). Hosts deployed under the previous scheme
imported the old tag and must re-import the new one — running `deploy.sh` with
a fresh bundle re-imports `controller-container.tar` under the new `-go` tag
and installs the matching generated unit.

## 5. Post-deploy verification (arm64)

**Host GPU / driver** — expect `620.70.06, 7.5` (T4/T4G `sm_75`):

```sh
nvidia-smi --query-gpu=driver_version,compute_cap --format=csv,noheader
rpm -q nvidia-open                    # amd64: nvidia-open-3:620.70.06-1.el9
rpm -qa 'kmod-nvidia-open*' 'nvidia-driver-selinux'   # validator-covered / exempt
cat /proc/driver/nvidia/version
ls -l /usr/lib64/libnvidia-encode.so.1   # NVENC userspace
sudo test -f /lib/firmware/nvidia/620.70.06/gsp_tu10x.bin   # GSP firmware present
ls -l /usr/src/kernels/$(uname -r)/Makefile /lib/modules/$(uname -r)/build   # DKMS build tree
sudo systemctl status nvidia-persistenced
```

`kmod-nvidia-open*` is covered by the staged-version validator and must report
`620.70.06`; `nvidia-driver-selinux` is the one exemption, expected `noarch` and
policy-only (see §1.1, *Staged-version validation*).

On a DKMS host, confirm the running kernel's build tree directly rather than
`rpm -q kernel-devel`/`kernel-headers`: AL2023 6.12 satisfies it with
`kernel6.12-devel`/`kernel6.12-headers`, so the legacy package-name check is a
false negative on those hosts (see §1.1, *Kernel build prerequisites*).

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

**DNS (DDNS):**

```sh
sudo ctr -n strimserver run --rm --net-host \
  --mount type=bind,src=/etc/resolv.conf,dst=/etc/resolv.conf,options=rbind:ro \
  --mount type=bind,src=/etc/hosts,dst=/etc/hosts,options=rbind:ro \
  docker.io/library/strim-ddns:latest strim-ddns /strim-ddns check strim example.com
```

`deploy.sh` verified the record at deploy time the same way — in-container,
a direct authoritative query to the domain's nameservers (via the
container's c-ares DNS client) — so the box needs no bind-utils/dnsutils.

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
| NVMe scratch | mount source, free space | `findmnt -n -o SOURCE,FSTYPE /mnt/nvme`; `df -h /mnt/nvme` |
| Driver stage | leaf/parent readable and traversable | `sudo namei -l /mnt/nvme/nvidia-rpm`; `sudo stat -c '%a %U:%G' /mnt/nvme/nvidia-rpm` |
| Driver version | staged validator contract (`%{VERSION}` = `620.70.06`; `kmod-nvidia-open*` covered; `nvidia-driver-selinux` exempt) | `rpm -q nvidia-open`; `rpm -qa 'kmod-nvidia-open*' 'nvidia-driver-selinux'` |

**NVMe / instance store:** `/mnt/nvme` is instance-store scratch and the
containerd root/state. Everything under it — containerd root/state,
`video-files`, logs, the staged `nvidia-rpm` closure, the deployment bundle, and
the SRT passphrase — is lost when the instance is stopped or terminated. A new
host generates a new SRT passphrase, so the encoder must be reconfigured (see
§4.4). The auto setup path is non-destructive and never migrates data; a mounted
EBS-backed `/mnt/nvme` is kept unless the operator explicitly migrates it (stop
services, back up `config/strimserver.env`, the SRT passphrase, logs, and any
video files, unmount, then re-run with `--format`). `setup_strimserver` is an
operator-side script obtained from the git tag, not a member of the deployment
tar. Stopping the instance therefore also **loses the staged `nvidia-rpm`
closure** (the stage lives under `/mnt/nvme`); a stage that exists only on the
host is never a durable rollback artifact.

**Staging preflight:** before any drain/uninstall/install, run the read-only
stage-only mode as the deploying user (`NVIDIA_STAGE_ONLY=1 ./setup-gpu.sh` or
`./setup-gpu.sh --stage-only`, **not** under `sudo`) and confirm the stage leaf
is `0755` and `namei -l /mnt/nvme/nvidia-rpm` shows no permission denial. For
acceptance, run it **on the host** from an extracted candidate bundle — not by
exporting `NVIDIA_STAGE_ONLY=1` locally before `setup_strimserver`, which does
not forward the variable (see §1.1, *Staging directory access*). The validator
covers `kmod-nvidia-open*`, exempts only the `noarch`, policy-only
`nvidia-driver-selinux`, and fails closed on a zero-driver stage or any
unreadable path or nonzero `rpm` exit; on failure it restores the original
versionlock and leaves no `.nvidia-upgrade.*` backup. A stage that fails
validation **before the swap** leaves the host on its existing driver (595 on
the reference host); do not manually uninstall or reboot to "retry". DNF exiting
`0` alone does not prove staging succeeded — the fail-closed access guard is
what proves it (see §1.1, *Staging directory access*).

On a DKMS host the kernel prerequisite is the running kernel's **build tree**
(`/usr/src/kernels/$(uname -r)/Makefile` and
`/lib/modules/$(uname -r)/build`), not the legacy package names: AL2023 6.12
hosts satisfy it with `kernel6.12-devel`/`kernel6.12-headers`. A missing tree
fails closed before any drain/uninstall/install, so a rollback is never needed
for that case; do not pre-install `kernel-devel`/`kernel-headers` by name (see
§1.1, *Kernel build prerequisites*).

**Rollback:** the deployment tar is fully self-contained — the three image tars
plus config/scripts live inside it, with no external runtime dependencies. To
revert, point `DEPLOYMENT_SRC` at the previously published bundle (keeping
`DEPLOYMENT_SHA256` authoritative), then relaunch the previous architecture,
e.g. `deploy/aws/launch --type g4dn.xlarge --wait`. Tear down the abandoned
instance with `deploy/aws/terminate -y` (matches the `Project` tag). This
reverts the application only; driver rollback has a separate artifact
requirement, covered next.

**Host-driver caveat:** the bundle contains no driver. Reverting
`DEPLOYMENT_SRC` reverts the application, **not** the host driver — a host that
already runs `620.70.06` keeps it. Because `setup-gpu.sh` never downgrades, there
is no automated driver rollback. An in-place rollback requires a **verified
artifact preserved off-host before the upgrade** — the original 595 `.run`
installer or the previous 595 RPM closure — not a stage left on the host: the
reference host is `.run`-managed and its stage lives on instance-store
`/mnt/nvme`, so stopping or terminating the instance loses the stage closure.
Without a verified off-host 595 artifact, rollback is **replacement-only**:
replace the instance from the pinned AMI (Tier B) rather than reinstalling in
place. Those artifacts are not bundled, so a manual `nvidia-uninstall` +
preserved-595 reinstall is a last-resort operator action only when the artifact
has been verified (see §1.1).

**Status:** this staged-version fix has not undergone live host acceptance and
no release containing it has been published; the reference host remains on
`595.112.07`. The 595 rollback-artifact requirement in §1.1 (*Rollback artifact
requirement*) remains in force before any destructive swap.

## 7. Known blockers / TODOs — CRITICAL

The former arm64 **artifact** blockers are resolved and no longer gate the
cutover: the arm64 ffmpeg artifact is published (`@ffmpeg_dist_arm64`,
`ffmpeg-8.1-deb20261104-cuda13.5.0-sm75-1a748fe-arm64.tar.gz`) and the arm64
OpenSSH RPM is published (`openssh-experimental-aarch64.rpm`), so the arm64
image no longer embeds an amd64 ffmpeg binary and experimental sshd no longer
warns "not published".

| # | Blocker | Impact | Resolution track |
|---|---|---|---|
| 1 | **arm64 T4G driver is outside the vendor's 620 support matrix** | Production arm64 cutover is gated on a hardware acceptance run, not on artifacts | Phase 8 T4G acceptance on `g5g.2xlarge`; if sm_75/NVENC/GSP fails, split per-arch driver pins (plan Phase 6.8-6.14) |
| 2 | arm64 RPM epoch unverified | Installability of `nvidia-open-620.70.06-1.amzn2023.noarch` on a T4G DLAMI is unproven | Capture `rpm -qp --qf '%{EPOCH}'` during acceptance, then pin the exact NEVRA |

Do not run a full arm64 production rollout until the T4G acceptance run
(Phase 8, `deploy/aws/gpu_acceptance_test.sh`) passes.

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