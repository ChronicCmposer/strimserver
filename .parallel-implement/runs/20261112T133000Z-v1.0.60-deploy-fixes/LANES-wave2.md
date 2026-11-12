# Lanes — wave 2 — 20261112T133000Z-v1.0.60-deploy-fixes

Wave 1 (`deploy-core`, `driver-upgrade`, `secret-hygiene`) is complete and **no
wave-1 lane is live**. Per PROTOCOL.md §Lanes and ownership, wave-2 lanes must
be disjoint from lanes that are still live only; overlap with a finished lane is
legitimate.

| Lane | Owner agent | Claimed globs |
| --- | --- | --- |
| `integration` | coder | `LANES-wave2.md`, `README.md`, `deploy/aws/README.md`, `deploy/aws/.env.example`, `Makefile`, and any repository file needed for integration fixes now that no wave-1 lane is live |
| `orchestrator` | orchestrator | `inbox/orchestrator/` only |

## Lane count

One worker lane in wave 2: `integration`.

## Disjointness notes

- No wave-1 lane is live, so `integration` may overlap and edit files formerly
  owned by `deploy-core`, `driver-upgrade`, and `secret-hygiene` when needed for
  integration fixes.
- `integration` owns the cross-lane gate matrix, four-tar packaging
  verification, the code-review pass over the complete working-tree diff, and
  all documentation/release-facing prose updates.
- The orchestrator inbox remains owned by the orchestrator; `integration`
  writes replies to senders only.
