# Lane allocation — wave 2 — 20261112T004500Z-nvidia-driver-620

| lane | owner agent | claimed globs |
|------|-------------|---------------|
| integration | coder | all files changed by wave 1: `deploy/aws/lib/nvidia.sh`; `deploy/aws/lib/BUILD.bazel`; `deploy/aws/testutil_fake_gpu.sh`; `deploy/aws/nvidia_version_test.sh`; `deploy/aws/setup_driver_test.sh`; `deploy/aws/setup_gpu_test.sh`; `deploy/aws/gpu_acceptance_test.sh`; `deploy/aws/BUILD.bazel`; `deploy/aws/setup-gpu.sh`; `deploy/aws/deploy.sh`; `deploy/aws/setup_strimserver`; `BUILD.bazel`; `deploy/aws/README.md`; `deploy/aws/.env.example`; `README.md`; `deploy/aws/launch`; `tools/deps-pins/pins_test.go`; `tools/check-deps/testdata/expected-pins.json`; `tools/check-deps/testdata/expected-pins.md`; `.github/workflows/controller-ci.yml` |
| integration (run dir) | coder | `runs/20261112T004500Z-nvidia-driver-620/LANES-wave2.md`; `runs/20261112T004500Z-nvidia-driver-620/logs/integration.md`; `runs/20261112T004500Z-nvidia-driver-620/inbox/integration/**`; `runs/20261112T004500Z-nvidia-driver-620/inbox/deploy-wiring/deploy-wiring-20261112T005839Z-exports-files-subpackage.reply.md` |

## Disjointness

No wave-1 lane is still live: `driver-core`, `deploy-wiring` and `docs-pins-ci`
have all finished (journals end with `INBOX: empty`). Per PROTOCOL,
`LANES-wave2.md` must be disjoint only against LANES THAT ARE STILL LIVE, so
overlap with the finished wave-1 lanes is legitimate. This lane exists solely
for cross-lane integration fixes and verification.

## Build policy

The repository declares NO `build-policy` block. Raw commands only; every claim
carries the exact command and its exit code.
