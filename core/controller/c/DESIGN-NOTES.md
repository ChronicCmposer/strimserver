# cc_ctr chainID design-around — contract for the assembly author

Phase 3.5 of the ARM controller rewrite. This is the contract the `cc_ctr.S`
author codes against for container/snapshot lifecycle. It replaces the Go
controller's snapshot chainID plumbing (which walks the Content service and
computes `sha256` digests of the layer chain) with a design that avoids
content addressing entirely.

## Why

The Go controller derives snapshot chain IDs by unpacking image layers
through the Content service and chaining digests (`docker save`-style
`sha256:<digest>` chain IDs). In the ARM rewrite we want the assembly to do
the same lifecycle without reimplementing content-addressing over the
Content gRPC service. The snapshotter itself already does the heavy lifting:
it names snapshots and tracks their parent relationships internally. The
design-around makes the assembly rely on **snapshot names we choose** instead
of content digests we compute.

## The contract (what cc_ctr.S must do)

### RPCs the assembly uses (all via the cc_grpc client, `core/controller/c/`)

| Purpose | Method path | Messages (raw protobuf, caller-encoded with the `.pb-c` codecs) |
|---|---|---|
| Snapshot `Prepare` (mountable view) | `/containerd.services.snapshots.v1.Snapshots/Prepare` | `snapshots/v1.PrepareRequest` |
| Snapshot `Commit` (finalize an active view) | `/containerd.services.snapshots.v1.Snapshots/Commit` | `snapshots/v1.CommitRequest` |
| Snapshot `Mounts` (read back mount config) | `/containerd.services.snapshots.v1.Snapshots/Mounts` | `snapshots/v1.MountsRequest` |
| Snapshot `Remove` (teardown) | `/containerd.services.snapshots.v1.Snapshots/Remove` | `snapshots/v1.RemoveRequest` |
| Snapshot `Stat` (metadata sanity) | `/containerd.services.snapshots.v1.Snapshots/Stat` | `snapshots/v1.StatRequest` |
| Container `Create` / `Get` | `/containerd.services.containers.v1.Containers/Create` (+`/Get`) | `containers/v1.CreateContainerRequest` |
| Task `Create` (wire the rootfs mounts) | `/containerd.services.tasks.v1.Tasks/Create` | `tasks/v1.CreateTaskRequest` |

All calls carry the `containerd-namespace: <ns>` header automatically (set
once at `cc_grpc_init`). Response message types come from the same codec
headers (`snapshots/v1.snapshots.pb-c.h`, etc.).

### ChainID rules (the design-around)

1. **Base layer**: snapshot `Prepare` is called with `parent=""` (empty
   string). The snapshotter creates a root snapshot; no parent chain is
   involved. This is the replacement for the Go code's "base chain ID from
   the first layer digest".

2. **Child layers**: for each subsequent layer, `Prepare` is called with
   `parent=<the previous snapshot's ID>` — i.e. the string returned in the
   *previous* `PrepareResponse.snapshot.key` (or `CommitResponse`, for
   committed views). The assembly must **not** compute any digest; it only
   threads the previous snapshot's key through.

3. **What the Prepare response gives you**: `PrepareResponse.snapshot.key`
   is the snapshot key the assembly must keep and pass to the next layer's
   `PrepareRequest.parent` and to the container's `snapshot_key` field. Treat
   it as an opaque string (it is a `sha256`-ish key on the snapshotter side,
   but the assembly never recomputes it).

4. **The container's rootfs**: when creating the task, the rootfs mounts
   come from `Snapshots/Mounts` for the final snapshot key, and go into
   `CreateTaskRequest.rootfs` (`types.Mount`, `type/mount.pb-c.h`). The
   container's `Snapshotter` field is the snapshotter name (e.g.
   `overlayfs`) and `SnapshotKey` is the final snapshot key.

5. **No Content service calls** in the controller path. If the assembly
   needs to verify what a snapshot's ID means, it uses `Stat` (returns the
   `Kind`, `Parent`, and key) — never the Content service.

### Failure semantics

- `Prepare`/`Commit` return gRPC status codes through `cc_grpc_unary`
  (0 = OK; 5 = NotFound; 3 = InvalidArgument; 13 = Internal; 14 =
  Unavailable). A non-zero status means the snapshot operation failed; the
  assembly should not proceed to the next layer.
- The snapshot lifecycle is the same as the Go controller: `Prepare` →
  (unpack/apply) → `Commit` for committed views, or `Prepare` → use → leak
  cleanup via `Remove` for mount-only views.

### Conventions

- The gRPC method paths above are the exact strings to pass to
  `cc_grpc_unary` (full `/pkg.Service/Method` form).
- Request/response messages are packed/unpacked with the vendored codecs
  (`//third_party/containerd-api:codecs`); the cc_grpc layer only transports
  raw bytes.
- All snapshot operations are unary (blocking) RPCs — safe to call in
  sequence from the assembly.