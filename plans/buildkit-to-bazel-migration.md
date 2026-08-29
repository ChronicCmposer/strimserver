# Migrate strimserver from Make + BuildKit to Bazel + rules_oci

> **Status:** implemented, all 7 phases (see `MODULE.bazel` / `BUILD.bazel` /
> `*/BUILD.bazel` throughout the tree). Runtime verification on GPU hardware
> per the *Verification plan* below is still outstanding -- everything else in
> that section was checked in this sandbox (no buildctl, containerd, or GPU
> available here). Several implementation details below were superseded by
> what was actually needed to get the graph to build; see the git history on
> this branch for what changed and why (in particular: `oci_tarball` is
> `oci_load` in the pinned rules_oci; the ffmpeg/openssh buildctl wrapper
> covers iperf3 too, since `apk add` has the same RUN-in-rules_oci problem;
> the native images use per-file `deb_file` extraction rather than whole apt
> packages; and the Stream Deck plugin ended up on a generated
> `pnpm-lock.yaml` instead of `npm_translate_lock`'s `npm_package_lock` path,
> which has real bugs in the pinned aspect_rules_js release).
> **Branch:** `claude/list-branches-local-remote-dlgvnz` (this plan was
> written on `feature/buildkit-to-bazel`, based on `origin/dev` @ `a97c2e4`;
> the implementation landed on the branch this task was assigned).
> **Verification:** every code claim below — line numbers, version pins, and all
> eight bugs — was checked against the tree at `a97c2e4` before this file was
> written. Claims are marked *verified* where confirmed. Nothing here is
> recalled from memory.

## Context

`strimserver` builds five OCI images with `sudo buildctl` driven by a 260-line
`Makefile`, exports them as **OCI tarballs** (never pushes to a registry), and
bundles them into `strimserver-deployment.tar` for S3 / GitHub Releases. On the
EC2 host, `deploy.sh` does `ctr -n strimserver image import`.

The build has no correct notion of "up to date" — all four verified:

- `CACHEBUST=$$(date +%s%3N)` is passed to every controller build
  (`Makefile:84`, `:100`, `:132`, consumed at `core/controller/Dockerfile:6`,
  `:21`), deliberately invalidating the Go compile on **every invocation**.
- `controller` (`Makefile:73`) and `test-controller` (`Makefile:89`) declare no
  `--output`, so they produce no file. Named as file targets, they can never be
  "up to date" and re-run always.
- Dependencies are `$(wildcard core/controller/*.go)` (`Makefile:150`) —
  file-glob granularity, no knowledge of the actual Go import graph.
- `.PHONY := ...` on `Makefile:49` uses **`:=` (variable assignment), not `:`**,
  so *zero* targets are registered phony. Confirmed via `make -p`: the string
  appears in make's *variable* database, and no `.PHONY` target rule exists.

**Goal: correct incremental rebuilds.** Scope is everything — all five images,
the bundle, publish paths, and the Stream Deck plugin. FFmpeg stays on BuildKit,
wrapped by Bazel (decision below).

## The constraint that shapes the whole design

`rules_oci` has **no `RUN` equivalent** and will not get one — it treats a
container as an archive format, not a build environment, because `RUN` is
non-hermetic by construction. `container_run_and_commit` does not exist there.

Two of the five images are *defined* by compilation steps:

| Image | Build step | rules_oci path |
| --- | --- | --- |
| ffmpeg | Compiles FFmpeg `release/8.0` + nv-codec-headers `n13.0.19.0` from source against `nvidia/cuda:13.0.2-devel-ubuntu24.04`, `-gencode arch=compute_75,code=sm_75` (`core/Dockerfile:27-68`) | none |
| openssh RPM | `autoreconf` + `./configure` + `make` + `rpmbuild` on `amazonlinux:2023` (`tools/openssh/Dockerfile`) | none |

So a "complete replacement" of BuildKit is not achievable at sane cost. This
plan keeps BuildKit for exactly those two targets and wraps them in a Bazel
rule, so `bazel build //...` remains the single entry point.

The other three images are `FROM scratch` + hand-picked files. They map cleanly.

## Current inventory (what has to keep working)

| Make target | Produces | Migration |
| --- | --- | --- |
| `package` (default goal) | `strimserver-deployment.tar` + `.sha256` | `pkg_tar` + genrule |
| `release` | `gh release upload` | `sh_binary`, `bazel run` |
| `publish-strimserver` | `aws s3 cp` | `sh_binary`, `bazel run` |
| `controller` | nothing (build smoke test) | `go_binary` — now a real artifact |
| `test-controller` | nothing (go test + golangci-lint) | `go_test` + lint target |
| `generate` | `strimserver.env.example`, `types.generated.ts` | `write_source_files` |
| `check-generated` | staleness gate | becomes a real `bazel test` |
| `$(CONTROLLER_CONTAINER_OUTPUT)` | `controller-container.tar` | `oci_image` + `oci_tarball` |
| `$(MEDIAMTX_CONTAINER_OUTPUT)` | `mediamtx-container.tar` | `oci_image` + `oci_tarball` |
| `$(FFMPEG_CONTAINER_OUTPUT)` | `ffmpeg-container.tar` | **buildctl wrapper rule** |
| `$(OPENSSH_RPM_OUTPUT)` | `openssh-experimental.rpm` | **buildctl wrapper rule** |
| `$(IPERF3_CONTAINER_OUTPUT)` | `iperf3-container.tar` | `oci_image` + `oci_tarball` |
| `$(IPERF3_DEPLOYMENT_TAR)` | `iperf3-deployment.tar` | `pkg_tar` (**currently broken** — Bug 4) |
| `goroot` | bootstraps Go from source into `./go` | **delete** — Bazel owns the toolchain |

Non-negotiable behaviors to preserve (all verified):

- Image names stay `docker.io/library/{strimserver-controller,ffmpeg,mediamtx,iperf3}:latest`
  (`Makefile:13-16`). The controller resolves these from the containerd store via
  `client.GetImage` (`core/controller/container_factory.go:72`), and
  `core/strimserver.env.example` independently hardcodes two of them
  (`MEDIAMTX_IMAGE_NAME` at `:26`, `FFMPEG_IMAGE_NAME` at `:35`) — so the names
  are pinned in two places that must not drift.
- `linux/amd64` only.
- Bundle paths stay flattened (`tar --transform`).
- `check-no-twitch-key` still gates `package` / `release` but **not**
  `publish-strimserver` (verified: `package` calls it at `Makefile:106`,
  `release: package` inherits it, `publish-strimserver` does not).

## Target layout

```
MODULE.bazel  .bazelrc  .bazelversion  BUILD.bazel
tools/bazel/
  buildctl.bzl          # the hybrid escape hatch
  apt.lock.json         # rules_distroless deb pins
core/BUILD.bazel                    # mediamtx image, ffmpeg via buildctl
core/controller/BUILD.bazel         # go_binary, go_test, lint, codegen, image
tools/openssh/BUILD.bazel           # RPM via buildctl
tools/bandwidth-test/BUILD.bazel    # iperf3 image + bundle
tools/streamdeck-plugin/BUILD.bazel # rules_js + rollup
```

MODULE.bazel deps: `rules_go` + `gazelle` (Go 1.26.4 via `go_sdk.download`),
`rules_oci`, `rules_pkg`, `rules_distroless`, `aspect_bazel_lib`
(`write_source_files`), `aspect_rules_js` + `aspect_rules_ts`.

## Phase 1 — Scaffolding

`MODULE.bazel`, `.bazelrc`, `.bazelversion`. Gazelle configured with
`# gazelle:prefix strimserver-controller` — the module path in
`core/controller/go.mod` is a **bare name, not a domain**, so gazelle needs this
set explicitly. Pull deps with
`go_deps.from_file(go_mod = "//core/controller:go.mod")`.

Purely additive. `make` keeps working untouched.

## Phase 2 — Controller (the entire incrementality win lives here)

`core/controller/BUILD.bazel`:

```python
go_binary(
    name = "strimserver-controller",
    embed = [":controller_lib"],          # gazelle-generated
    goos = "linux", goarch = "amd64",
    pure = "on",                          # matches CGO_ENABLED=0
    gc_linkopts = ["-s", "-w"],           # matches -ldflags='-s -w'
)
go_test(name = "controller_test", embed = [":controller_lib"])
```

Current flags, verified at `core/controller/Dockerfile:14`:
`CGO_ENABLED=0 GOOS=linux go build -v -trimpath -ldflags='-s -w'`.
`-trimpath` is Bazel's default. The binary is genuinely pure — verified no
`import "C"` and no `os/user` anywhere in `core/controller/*.go` — so
`pure = "on"` is exact, not an approximation.

**Codegen.** The controller binary generates two checked-in files
(`Makefile:53-55` shells out to `go run . -print-env-example` / `-print-ts-types`):

```python
genrule(name = "env_example_gen", tools = [":strimserver-controller"],
        outs = ["strimserver.env.example.gen"],
        cmd = "$(location :strimserver-controller) -print-env-example > $@")
# ...same for -print-ts-types

write_source_files(name = "generate", files = {
    "//core:strimserver.env.example": ":env_example_gen",
    "//tools/streamdeck-plugin/src/client:types.generated.ts": ":ts_types_gen",
})
```

`bazel run //core/controller:generate` replaces `make generate`;
`bazel test //core/controller:generate_test` replaces `make check-generated`.

This fixes two verified defects in `check-generated` (`Makefile:57-59`): it
declares `generate` as a prerequisite, so **it mutates the worktree in order to
check it**, and it has **no caller at all** — the only other reference to it in
the whole Makefile is the broken `.PHONY :=` line. Under Bazel it becomes a real
test in the default set that never writes to the source tree.

**Lint.** `.golangci.yml` exists and is tracked. Today `golangci-lint@v1.64.8`
is `go install`ed over the network inside the image build on every lint-enabled
run (`core/controller/Dockerfile:29`). Pin it as a Bazel-managed tool and expose
`//core/controller:lint` so it is cached.

After this phase the Go build is genuinely incremental: no CACHEBUST, real
import-graph dependencies, and `bazel test //...` covers tests + lint +
generated-file staleness.

## Phase 3 — Native images (controller, mediamtx)

Both are `FROM scratch` plus a hand-picked file set. The Debian donor stages
(`core/Dockerfile:163`, `core/controller/Dockerfile:35`, both
`debian:trixie-20260518-slim AS libs`) become `rules_distroless` deb imports
pinned in `tools/bazel/apt.lock.json`, layered with `pkg_tar`.

- **controller**: `dash` → `/bin/sh`, `ld-linux-x86-64.so.2`, `libc.so.6`, the
  Go binary, `entrypoint.sh` (mode 755), `ENTRYPOINT ["/entrypoint.sh"]`.
- **mediamtx**: MediaMTX v1.17.0 via `http_archive` (**add the SHA-256 the
  current `wget` lacks** — `core/Dockerfile:142,150`), busybox-static + its
  applet symlinks (`sh cat rm ln mkdir wget nc`, `core/Dockerfile:176`),
  `envsubst`, `nice`, `nsswitch.conf`, ca-certificates, the glibc set,
  `entrypoint.mediamtx.sh`.

`oci_tarball` writes `controller-container.tar` / `mediamtx-container.tar` with
`repo_tags` matching today's `--output type=oci,name=...`.

**Note:** the Dockerfiles run smoke tests as `RUN` layers inside the scratch
images (`/ffmpeg -version`, `/mediamtx --version`, `busybox --list`,
`envsubst --version`, and the `command -v` loops at `core/Dockerfile:222,258`).
These cannot be layers in rules_oci. Reproduce them as `sh_test` targets over
the built tarball so the coverage is kept, not dropped.

## Phase 4 — Hybrid: ffmpeg + openssh via buildctl

`tools/bazel/buildctl.bzl` — a rule that shells out to the existing toolchain:

```python
ctx.actions.run_shell(
    outputs = [out],
    inputs = ctx.files.context,           # real Bazel inputs => real caching
    command = "sudo buildctl {addr} build --frontend=dockerfile.v0 " +
              "--opt platform=linux/amd64 --local context={ctx} " +
              "--local dockerfile={ctx} --opt filename=./Dockerfile " +
              "{target} --output {output_spec}",
    execution_requirements = {
        "no-sandbox": "1", "no-remote": "1", "requires-network": "1",
    },
)
```

`ffmpeg` keeps `--addr tcp://127.0.0.1:1234` (verified `Makefile:155`; the SSH
tunnel from `tools/buildkit-scripts/`); `openssh` uses `--output type=local` and
the default address. The FFmpeg artifact is **byte-identical** to today — same
Dockerfile, same daemon, same `sm_75` build.

Even here incrementality improves: today the tar rebuilds whenever it is
missing; under Bazel it rebuilds when `core/Dockerfile` actually changes.

Caveat to document: the action is not hermetic. Bazel keys the cache on declared
inputs and cannot see remote daemon state or upstream git/apt drift. `bazel
clean` is the escape hatch.

## Phase 5 — iperf3, bundle, publish

- **iperf3**: single-stage `alpine:3.23.3` + `apk add`
  (`tools/bandwidth-test/Dockerfile:3,8`). `oci_pull` the base, layer
  `entrypoint.sh` / `iperf3.env` via `pkg_tar`. Fix Bug 4 first.
- **Bundle**: `pkg_tar` with `remap_paths` replacing GNU `tar --transform`.
  Drop `--ignore-failed-read` — Bazel fails loudly on a missing input, which is
  what you want (and is exactly what would have surfaced Bug 4 years ago).
- **Offline segment**: `$(OFFLINE_SEGMENT_OUTPUT)` has **no rule** — verified: it
  appears only as a variable (`Makefile:31`), a bundle prerequisite (`:189`), and
  a tar argument (`:195`). It is hand-placed in `$OUTPUT_PATH`. Model it as a
  `label_flag` so it becomes an explicit, overridable graph input with a clear
  error when unset.
- **OpenSSH toggle**: replace the `ifeq` with a `bool_flag` + `config_setting` +
  `select()`. This also fixes Bug 3.
- **sha256 / publish**: genrule for the checksum; `sh_binary` targets for
  `aws s3 cp` (`Makefile:254`) and `gh release upload` (`Makefile:116`), invoked
  via `bazel run`. Keep `check-no-twitch-key` gating `package` / `release` only.

## Phase 6 — Stream Deck plugin

`aspect_rules_js` + `aspect_rules_ts`, `npm_translate_lock` over the committed
`package-lock.json`, rollup as an `npm_package_bin` producing
`com.chroniccmposer.strimserver.sdPlugin/bin/plugin.js`. Newly wired into the
graph, so `types.generated.ts` staleness now actually fails a build.

## Phase 7 — Cut over

Reduce the `Makefile` to a thin facade so muscle memory and the README survive:

```make
package:            ; bazel build //:strimserver-deployment
test-controller:    ; bazel test //core/controller:all
generate:           ; bazel run //core/controller:generate
```

Delete `goroot` (`Makefile:61-69`; Bazel owns the toolchain — also drop `go`
from `.gitignore`). Delete the dangling `SRT_TEST_DIR`, `AWS_DEPLOY_DIR`,
`LOCAL_ENCODER_DIR` vars — verified each has exactly **one** occurrence in the
Makefile, its own definition. Update README's "Build instructions" and "Host
build and deployment tools".

## Bugs found during analysis — all verified, fix as part of this work

1. **`core/Dockerfile:128` — FFmpeg `./configure` ends in `|| true`.**
   The line is `--enable-filter=aresample || true \` followed by
   `&& make -C /opt/ffmpeg-src`. Shell parses this as `(configure || true) && make`,
   so the guard always succeeds and `make` runs regardless of whether configure
   worked. The build does still fail downstream (FFmpeg's shipped top-level
   Makefile needs the `config.mak` configure would have written), but it fails
   with a confusing error far from the real cause. Highest-value fix; independent
   of the migration. *(The other two `|| true` uses — `:134` on a `readelf | grep`
   and `:157` on `ldd`, the latter carrying an explanatory comment — are
   deliberate and fine.)*
2. **`Makefile:49` — `.PHONY := ` is a variable assignment, not a target rule.**
   No target is phony. Confirmed via `make -p`. Moot after Phase 7, but confirm
   nothing depended on the broken behavior before removing it.
3. **`Makefile:197` — `ifeq ($(ENABLE_EXPERIMENTAL_OPENSSH),"true")` compares
   against a *quoted* literal.** So `make ENABLE_EXPERIMENTAL_OPENSSH=true` does
   nothing. Only the value from `feature-toggles.env:7`
   (`ENABLE_EXPERIMENTAL_OPENSSH="false"`, quotes included) can ever match.
   Compounding it, the in-Makefile default at `:41` is unquoted (`?=false`) — so
   the two sources of the same flag use different quoting conventions.
4. **`make publish-iperf3` is unbuildable.** `$(IPERF3_DEPLOYMENT_TAR)`
   (`Makefile:234-241`) requires `tools/bandwidth-test/{fish-deploy.sh,imdslib.sh,prompt_login.fish}`,
   none of which exist — they live in `deploy/aws/`. Verified by dry run:
   `make: *** No rule to make target 'tools/bandwidth-test/fish-deploy.sh'`.
   Note `--ignore-failed-read` on the `tar` cannot save it; make refuses before
   tar ever runs.
5. **`core/Dockerfile:61` and `core/controller/entrypoint.sh:3` — `set -xeuo`
   with no operand for `-o`.** `-o` consumes the next argument as an option
   name; with none present bash just prints the option list. `pipefail` is
   therefore silently **not** enabled, despite the obvious intent.
6. **`core/controller/container_factory.go:265` — unchecked type assertion.**
   `f.stageNames[event.(TaskEvent).GetContainerID()]` — the `, ok` on that line
   guards the *map lookup*, not the assertion. A matching containerd event whose
   type lacks `GetContainerID` panics the listener goroutine.
7. **No `.dockerignore` anywhere in the repo.** `--local context=core` uploads
   all of `core/controller/` plus any local gitignored `core/strimserver.env` for
   a build that consumes one file. Disappears for natively-built images; still
   applies to the buildctl-wrapped ones.
8. **Unverified downloads.** MediaMTX is `wget`ed with no checksum
   (`core/Dockerfile:150`); there is no `sha256` verification anywhere in the
   file. `http_archive` requires one, closing this for MediaMTX.

## Verification plan

Correctness is "same artifacts, same bytes where achievable":

1. **Baseline.** On `dev`, `make package`; keep `$OUTPUT_PATH` and record
   `sha256sum` of all three container tars and the bundle.
2. **Per image.** `bazel build //core/controller:image_tarball`, then compare
   against the Make output with `diffoscope`, or `tar -tvf` + per-file sha256.
   Expect layer-digest differences (Bazel sets deterministic timestamps where
   BuildKit does not) — verify **file content and mode equality**, not digest
   equality. The controller Go binary should be bit-identical (`-trimpath`,
   `-s -w`, `CGO_ENABLED=0`).
3. **Runtime — the real gate.** `ctr -n strimserver image import` each Bazel tar
   on a `g4dn`/`g6` instance and run the stack: SRT ingest → normalize →
   scale-and-egress. Confirm `/transcode.sh` finds `hevc_cuvid`, `hevc_nvenc`,
   `h264_nvenc`, `libfdk_aac`, `scale_cuda`, and that CDI GPU injection works.
   The scratch images have no package manager — a missing `.so` only surfaces here.
4. **Incrementality (the actual objective).**
   - `bazel build //core/controller:strimserver-controller` twice → second is a
     no-op. Today this always recompiles.
   - Touch a comment in `paths.go` → only the controller rebuilds, not mediamtx
     or ffmpeg.
   - Touch `core/Dockerfile` → ffmpeg rebuilds; controller does not.
5. **Codegen.** Edit `envspec.go`, run `bazel test //core/controller:generate_test`
   → fails. `bazel run //core/controller:generate` → passes, and the diff matches
   what `make generate` produces.
6. **End to end.** `bazel build //:strimserver-deployment`, then
   `DEPLOYMENT_SRC=<path> deploy/aws/setup_strimserver` against a live instance.
   The bundle must stay under 50 MB and its `.sha256` must validate.

## Risks

| Risk | Mitigation |
| --- | --- |
| rules_go may not yet support Go **1.26.4** (pinned in `core/controller/go.mod:3` and both `golang:1.26.4-alpine3.24` stages) | Verify in Phase 1 before anything else — it gates the whole plan. Fallback: pin the toolchain one minor back; the code uses no 1.26-specific features. |
| Hand-picked `.so` set is easy to get subtly wrong | Phase 3 is the risky one. Diff the extracted file list against the Docker image tree before trusting it; runtime test on GPU hardware is mandatory. |
| buildctl wrapper caches a stale ffmpeg | Inputs are declared, but upstream git/apt drift is invisible. Document `bazel clean` and keep the ffmpeg tar reproducible on demand. |
| Team unfamiliar with Bazel | Makefile facade in Phase 7 keeps every existing command working. |

Phases 1–2 are additive and reversible — `make` keeps working throughout. The
first irreversible step is Phase 7.
