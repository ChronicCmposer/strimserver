# Lane allocation — 20261112T004500Z-nvidia-driver-620

| lane | owner agent | claimed globs |
|------|-------------|---------------|
| orchestrator | orchestrator | `runs/20261112T004500Z-nvidia-driver-620/inbox/orchestrator/**` (inbox only; no repo files) |
| driver-core | coder | `deploy/aws/lib/nvidia.sh`; `deploy/aws/lib/BUILD.bazel`; `deploy/aws/testutil_fake_gpu.sh`; `deploy/aws/nvidia_version_test.sh`; `deploy/aws/setup_driver_test.sh`; `deploy/aws/setup_gpu_test.sh`; `deploy/aws/gpu_acceptance_test.sh`; `deploy/aws/BUILD.bazel` (ANCHOR: new `sh_test` targets only) |
| deploy-wiring | coder | `deploy/aws/setup-gpu.sh`; `deploy/aws/deploy.sh`; `deploy/aws/setup_strimserver`; `deploy/aws/BUILD.bazel` (ANCHOR: `exports_files` block only); `BUILD.bazel` (ANCHOR: bundle `pkg_files`/`pkg_tar` members only) |
| docs-pins-ci | coder | `deploy/aws/README.md`; `deploy/aws/.env.example`; `README.md`; `deploy/aws/launch`; `tools/deps-pins/pins_test.go`; `tools/check-deps/testdata/expected-pins.json`; `tools/check-deps/testdata/expected-pins.md`; `.github/workflows/controller-ci.yml` |

## Disjointness

Every file above is owned by exactly one lane, with ONE declared exception: `deploy/aws/BUILD.bazel` is shared by `driver-core` and `deploy-wiring` under **section ownership by anchor**:
- `driver-core` may edit ONLY the package's new `sh_test` target block(s); it must not touch `exports_files`.
- `deploy-wiring` may edit ONLY the `exports_files([...])` list; it must not touch any `sh_test` target.
They must not reorder or reformat each other's sections. `driver-core` owns `deploy/aws/lib/BUILD.bazel` outright.

`tools/deps-pins/BUILD.bazel` is NOT owned by any lane; `pins_test.go` is already listed in its `srcs`, so no BUILD edit is expected.

## Build policy

The repository declares NO `build-policy` block. There is no wrapper, slot, preflight or terminal verify lane. Lanes run raw `bazel test` / `bazel build` / `make` and must report the exact command and its exit code.

## Wave plan

Wave 1 (3 lanes, concurrent): `driver-core`, `deploy-wiring`, `docs-pins-ci`.
Wave 2: unowned work and cross-lane integration fixes only; no new lanes.
