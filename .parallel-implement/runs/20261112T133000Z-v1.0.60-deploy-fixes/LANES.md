# Lanes — 20261112T133000Z-v1.0.60-deploy-fixes

Globs are disjoint. Where a shared path is unavoidable, ownership is declared by file/anchor below and is not shared.

| Lane | Owner agent | Claimed globs |
| --- | --- | --- |
| `deploy-core` | coder | `deploy/aws/deploy.sh`, `deploy/aws/deploy_helpers_test.sh`, `deploy/aws/lib/deploy.sh`, `deploy/aws/lib/BUILD.bazel`, `deploy/aws/BUILD.bazel`, `deploy/aws/setup_strimserver`, `BUILD.bazel` (only `bundle_deploy_lib` additions and deployment tar target lists) |
| `driver-upgrade` | coder | `deploy/aws/lib/nvidia.sh`, `deploy/aws/setup-gpu.sh`, `deploy/aws/testutil_fake_gpu.sh`, `deploy/aws/nvidia_version_test.sh`, `deploy/aws/setup_driver_test.sh`, `deploy/aws/setup_gpu_test.sh`, `deploy/aws/gpu_acceptance_test.sh` |
| `secret-hygiene` | coder | `core/security_hygiene_test.sh`, `core/controller/entrypoint.sh`, `core/transcode.sh`, `core/entrypoint.c`, `core/controller/BUILD.bazel`, `core/BUILD.bazel`, `.github/workflows/controller-ci.yml` |
| `integration` | coder | `LANES-wave2.md`, `README.md`, `deploy/aws/README.md`, `deploy/aws/.env.example`, `Makefile`, and all cross-lane gate/package verification commands; may edit any file only after wave-1 lanes are no longer live |
| `orchestrator` | orchestrator | `inbox/orchestrator/` only |

## Disjointness notes

- `deploy/aws/BUILD.bazel` is owned exclusively by `deploy-core`; `driver-upgrade` must not edit it.
- `deploy/aws/lib/BUILD.bazel` and root `BUILD.bazel` are owned exclusively by `deploy-core`.
- `secret-hygiene` must send a `request` to `deploy-core` for any deploy-side log-permission or env-file hardening in `deploy/aws/deploy.sh`; it must not edit that file.
- Documentation and release-facing prose belong to `integration` in wave 2.
