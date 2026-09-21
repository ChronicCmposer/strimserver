/*
 * cc_ctr.h — containerd operation layer for the ARM controller rewrite.
 *
 * Phase 4.4a. This is the protocol/encoding half of the `cc_ctr` module:
 * it builds containerd gRPC requests with the vendored protobuf-c codecs
 * (//third_party/containerd-api:codecs), calls the h2c/gRPC client
 * (cc_grpc, Phase 3b) for the unary RPCs, and parses the responses. The
 * orchestration/state-machine half (`core/controller/asm/cc_ctr.S`) calls
 * these helpers; it owns the RPC *sequence* (the create→start→kill→delete
 * lifecycle) and the chainID threading.
 *
 * DESIGN CONTRACT (read before calling):
 *
 *   - Every function is FIXED-ARITY and AAPCS64-friendly: int returns,
 *     caller-provided buffers, no varargs. All string arguments are
 *     NUL-terminated C strings; byte buffers carry explicit lengths.
 *   - Return value semantics are uniform:
 *         >= 0            gRPC status code of the completed RPC
 *                         (0 = OK; 3 = InvalidArgument; 5 = NotFound; …)
 *         -1 .. -9        cc_grpc transport failure (see cc_grpc.h
 *                         CC_GRPC_ERR_*: timeout, socket error, protocol…)
 *         <= -100         cc_ctr local failure (see CC_CTR_ERR_* below)
 *   - The library is single-threaded per connection, exactly like cc_grpc;
 *     it is not re-entrant and never allocates on the caller's behalf.
 *   - The connection handle `h` comes from cc_grpc_init; the namespace is
 *     attached to every RPC by cc_grpc itself.
 *
 * THE CHAINID DESIGN-AROUND (snapshot threading):
 *
 * The Go controller derives snapshot chain IDs by walking the image's layer
 * digests through the Content service. This C layer does NOT do that: the
 * snapshotter already tracks parent relationships by the keys we choose.
 *   - Base layer:   Prepare(parent="") creates a root snapshot.
 *   - Child layers: Prepare(parent=<the previous snapshot's KEY>) threads
 *                   the chain. The "key" is the string the caller passed to
 *                   the previous Prepare request — the v1.12.0
 *                   PrepareSnapshotResponse contains ONLY mounts (no
 *                   snapshot.key field), so the caller keeps its own key.
 *   - The container's snapshot_key is the FINAL key; Tasks/Create resolves
 *     the rootfs mounts via Snapshots/Mounts(snapshot_key).
 * No Content service call ever appears on the controller path.
 *
 * THE OCI SPEC (Q13 contract):
 *
 * containerd stores Container.spec as a google.protobuf.Any whose value is
 * the OCI runtime spec serialized as JSON. The Go client registers the OCI
 * spec under "types.containerd.io/opencontainers/runtime-spec/1/Spec" and
 * the shim writes the Any's value bytes verbatim as the bundle's
 * config.json. This module provides:
 *   - cc_ctr_oci_spec_build(): emit the spec JSON from the fields the
 *     controller actually sets (env, args, cwd, mounts, capabilities,
 *     host-network, annotations…), replicating the deterministic skeleton
 *     the Go code produces (populateDefaultUnixSpec + the applied
 *     SpecOpts), including Go's json.Marshal field order and HTML escaping.
 *   - cc_ctr_oci_wrap_any(): wrap the JSON bytes in the Any protobuf with
 *     the exact type URL above.
 *   - cc_ctr_create_container(): takes the raw JSON and wraps it internally.
 *
 * License: project code (see LICENSE). No GPL.
 */
#ifndef CC_CTR_H
#define CC_CTR_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* =========================================================================
 * Constants
 * ========================================================================= */

/* Local (cc_ctr) error codes. Negative, distinct from the cc_grpc transport
 * errors (-1..-9) and from gRPC statuses (>= 0). */
#define CC_CTR_ERR_BADARG  (-101) /* NULL/empty required argument, bad cap    */
#define CC_CTR_ERR_TOOBIG  (-102) /* response/JSON exceeds caller buffer      */
#define CC_CTR_ERR_JSON    (-103) /* OCI spec field set is inconsistent       */
#define CC_CTR_ERR_NOMEM   (-104) /* internal scratch exhausted (never)       */
#define CC_CTR_ERR_STATE   (-105) /* RPC returned OK but response unparseable */

/* The exact type URL the Go client registers for the OCI runtime spec
 * (client/client.go: typeurl.Register(&specs.Spec{}, "types.containerd.io",
 * "opencontainers/runtime-spec", "1", "Spec")). */
#define CC_CTR_OCI_TYPE_URL "types.containerd.io/opencontainers/runtime-spec/1/Spec"

/* The exact type URL for runc task options (runc/options.Options). The runc
 * shim's typeurl.UnmarshalAny resolves this through the protobuf global
 * registry, so it MUST be the proto message's full name — NOT the
 * "types.containerd.io/..." style registered by typeurl.Register. Verified
 * empirically against the pinned containerd modules (typeurl/v2 + containerd/
 * api): typeurl.MarshalAny(&options.Options{}) emits
 * "containerd.runc.v1.Options" (options.ProtoReflect().Descriptor().FullName()
 * == "containerd.runc.v1.Options"; see types/runc/options/oci.proto package
 * containerd.runc.v1), and UnmarshalAny round-trips it. The daemon's tasks
 * service formatOptions (plugins/services/tasks/local.go) and the runc shim
 * (cmd/containerd-shim-runc-v2/runc/container.go) both unmarshal with the
 * same registry, so this string is the single contract. */
#define CC_CTR_RUNC_OPTIONS_TYPE_URL "containerd.runc.v1.Options"

/* The default runtime name containerd uses for tasks
 * (defaults/defaults_linux.go: DefaultRuntime = "io.containerd.runc.v2"). */
#define CC_CTR_DEFAULT_RUNTIME "io.containerd.runc.v2"

/* The default snapshotter name (defaults/defaults_linux.go: "overlayfs"). */
#define CC_CTR_DEFAULT_SNAPSHOTTER "overlayfs"

/* OCI spec version emitted into "ociVersion" (runtime-spec v1.3.0:
 * VersionMajor=1, VersionMinor=3, VersionPatch=0). */
#define CC_CTR_OCI_VERSION "1.3.0"

/* Bounds for the fixed-size output structures (fixed-arity design). */
#define CC_CTR_MAX_MOUNTS        8
#define CC_CTR_MOUNT_TYPE_MAX    64
#define CC_CTR_MOUNT_SRC_MAX     512
#define CC_CTR_MOUNT_TGT_MAX     512
#define CC_CTR_MOUNT_OPT_MAX     8
#define CC_CTR_MOUNT_OPT_LEN_MAX 256

#define CC_CTR_OCI_ENV_MAX  64
#define CC_CTR_OCI_ARGS_MAX 64
#define CC_CTR_OCI_CAPS_MAX 32
#define CC_CTR_OCI_GIDS_MAX 32
#define CC_CTR_OCI_ANN_MAX  16
#define CC_CTR_OCI_MOUNT_OPTS_MAX 8
#define CC_CTR_OCI_MOUNTS_MAX     64

/* Scratch sizes used internally to build requests/responses. Requests
 * (CreateContainerRequest with a full spec JSON) fit comfortably in 16 KiB;
 * responses are capped at 64 KiB like the rest of the C layer. */
#define CC_CTR_REQ_MAX  16384
#define CC_CTR_RESP_MAX 65536

/* =========================================================================
 * Mount record (the fixed-arity form of containerd.types.Mount)
 * =========================================================================
 *
 * cc_ctr_prepare_snapshot / cc_ctr_mounts copy the snapshotter's mounts into
 * caller-provided arrays of these. Options are copied into a fixed table so
 * the assembly can hold mounts across calls without owning protobuf-c
 * allocations. */
struct cc_ctr_mount {
  char type[CC_CTR_MOUNT_TYPE_MAX];
  char source[CC_CTR_MOUNT_SRC_MAX];
  char target[CC_CTR_MOUNT_TGT_MAX];
  uint32_t n_options;
  char options[CC_CTR_MOUNT_OPT_MAX][CC_CTR_MOUNT_OPT_LEN_MAX];
};

/* =========================================================================
 * OCI spec field set (input to cc_ctr_oci_spec_build)
 * ========================================================================= */

struct cc_ctr_oci_mount {
  const char *destination; /* container path, e.g. "/tmp"                     */
  const char *source;      /* host path, e.g. "/mnt/nvme/config/x.env"        */
  const char *type;        /* "bind" for controller mounts                    */
  uint32_t n_options;      /* e.g. 2                                          */
  const char *options[CC_CTR_OCI_MOUNT_OPTS_MAX]; /* e.g. "rbind","rw"        */
};

struct cc_ctr_oci_spec {
  /* Process (mirrors oci.WithImageConfig + oci.WithProcessArgs). */
  uint32_t n_env;                       /* image config env, or default PATH */
  const char *env[CC_CTR_OCI_ENV_MAX];
  uint32_t n_args;                      /* image entrypoint+cmd, or the      */
  const char *args[CC_CTR_OCI_ARGS_MAX];/* WithProcessArgs override          */
  const char *cwd;                      /* NULL -> "/" (image WorkingDir)    */
  uint32_t uid;                         /* image config user; 0 = root       */
  uint32_t gid;                         /* image config user; 0 = root       */
  uint32_t n_additional_gids;           /* from the rootfs /etc/group lookup */
  uint32_t additional_gids[CC_CTR_OCI_GIDS_MAX];

  /* Capabilities to APPEND to bounding/effective/permitted, e.g.
   * oci.WithAddedCapabilities([]string{"CAP_SYS_NICE"}). */
  uint32_t n_caps_add;
  const char *caps_add[CC_CTR_OCI_CAPS_MAX];

  /* Bind mounts appended AFTER the 7 default mounts
   * (oci.WithMounts(toOCIMounts(mounts))). */
  uint32_t n_mounts;
  const struct cc_ctr_oci_mount *mounts; /* CC_CTR_OCI_MOUNTS_MAX entries */

  /* oci.WithHostNamespace(specs.NetworkNamespace): 1 removes the network
   * namespace from the default list (host networking). */
  int host_network;

  /* Optional container hostname (oci.WithHostname), emitted after root and
   * before mounts per Go struct order. NULL/"" -> omitted. */
  const char *hostname;

  /* linux.cgroupsPath: "/<namespace>/<container-id>". The Go code computes
   * filepath.Join("/", ns, id); pass the same string for byte parity. */
  const char *cgroups_path;

  /* Optional spec annotations ("k=v" strings), emitted after mounts,
   * before linux (Go struct order). The controller's CDI injection is
   * host-dependent; the assembly can carry the deterministic parts here. */
  uint32_t n_annotations;
  const char *annotations[CC_CTR_OCI_ANN_MAX];
};

/* =========================================================================
 * API
 * ========================================================================= */

/* --- Version -------------------------------------------------------------
 * cc_ctr_ping: call the Version service (request: google.protobuf.Empty).
 * Returns 0 on OK, the gRPC status otherwise. Use to verify connectivity
 * and namespace/daemon health. */
int cc_ctr_ping(int h);

/* --- Images --------------------------------------------------------------
 * cc_ctr_get_image: Images/Get for image_ref. On OK, copies the image's
 * stored name (== the ref) and target digest ("sha256:…") into the caller
 * buffers. Either out buffer may be NULL with cap 0 to skip it.
 * Returns 0 + outputs, or gRPC status (NotFound when the ref is unknown). */
int cc_ctr_get_image(int h, const char *image_ref,
                     char *out_name, uint32_t name_cap,
                     char *out_digest, uint32_t digest_cap);

/* --- Snapshots (chainID design-around) -----------------------------------
 * cc_ctr_prepare_snapshot: Snapshots/Prepare.
 *   key:    the snapshot key (== the container's snapshot id for a single
 *           layer; the assembly CHOOSES it and keeps it).
 *   parent: "" for the base layer; the previous snapshot's key for a child.
 * On OK copies the returned mounts into out_mounts (at most mounts_cap
 * entries; out_n_mounts receives the count). The snapshot key the assembly
 * must thread is the `key` argument itself: PrepareSnapshotResponse in
 * containerd v1.12.0 carries ONLY mounts. */
int cc_ctr_prepare_snapshot(int h, const char *snapshotter, const char *key,
                            const char *parent,
                            struct cc_ctr_mount *out_mounts,
                            uint32_t mounts_cap, uint32_t *out_n_mounts);

/* cc_ctr_commit_snapshot: Snapshots/Commit — finalize an active snapshot
 * under a stable name. parent is threaded like Prepare ("" for a base
 * commit). Returns 0 or gRPC status. */
int cc_ctr_commit_snapshot(int h, const char *snapshotter, const char *name,
                           const char *key, const char *parent);

/* cc_ctr_mounts: Snapshots/Mounts — read back the mount config for a
 * snapshot key (the task's rootfs). Same output contract as Prepare. */
int cc_ctr_mounts(int h, const char *snapshotter, const char *key,
                  struct cc_ctr_mount *out_mounts, uint32_t mounts_cap,
                  uint32_t *out_n_mounts);

/* cc_ctr_remove_snapshot: Snapshots/Remove — teardown (container.Delete's
 * WithSnapshotCleanup path). Returns 0 or gRPC status. */
int cc_ctr_remove_snapshot(int h, const char *snapshotter, const char *key);

/* cc_ctr_stat_snapshot: Snapshots/Stat — metadata sanity check. out_kind
 * receives the Kind enum (0 unknown, 1 view, 2 active, 3 committed);
 * out_parent receives the parent key ("" for a base snapshot). */
int cc_ctr_stat_snapshot(int h, const char *snapshotter, const char *key,
                         uint32_t *out_kind, char *out_parent,
                         uint32_t parent_cap);

/* --- Containers ----------------------------------------------------------
 * cc_ctr_create_container: Containers/Create. Replicates the Go client's
 * NewContainer record: id, image = image_ref, runtime = {runtime}, spec =
 * Any(type_url CC_CTR_OCI_TYPE_URL, value = oci_spec_json), snapshotter,
 * snapshot_key. `runtime` NULL -> CC_CTR_DEFAULT_RUNTIME. `snapshotter`
 * NULL -> CC_CTR_DEFAULT_SNAPSHOTTER; `snapshot_key` NULL/"" -> no rootfs.
 * Returns 0 or gRPC status (AlreadyExists, InvalidArgument…). */
int cc_ctr_create_container(int h, const char *id, const char *image_ref,
                            const char *snapshotter, const char *snapshot_key,
                            const char *runtime, const uint8_t *oci_spec_json,
                            uint32_t oci_len);

/* cc_ctr_get_container: Containers/Get — fetch the stored snapshotter and
 * snapshot_key (needed for cleanup). Either out buffer may be NULL. */
int cc_ctr_get_container(int h, const char *id,
                         char *out_snapshotter, uint32_t ss_cap,
                         char *out_snapshot_key, uint32_t sk_cap);

/* cc_ctr_delete_container: container.Delete(WithSnapshotCleanup) — the Go
 * client's full delete wire sequence:
 *   Tasks/Get(id)        (if the task exists -> FailedPrecondition, exactly
 *                         like the client's "cannot delete running task")
 *   Containers/Get(id)   (fetch the record)
 *   Snapshots/Remove(record.snapshot_key)   when non-empty
 *   Containers/Delete(id)
 * Returns 0 on OK, FailedPrecondition (9) when a task is still present, or
 * the failing RPC's status. */
int cc_ctr_delete_container(int h, const char *id);

/* --- Tasks ---------------------------------------------------------------
 * cc_ctr_create_task: Tasks/Create. Replicates the Go client's
 * container.NewTask wire sequence:
 *   Containers/Get(container_id) → Snapshots/Mounts(record.snapshot_key) →
 *   Containers/Get (spec; for the mount-label check — our specs have no
 *   mount label, kept for wire parity) → Containers/Get (runtime name) →
 *   Tasks/Create(container_id, rootfs=mounts, stdin="", stdout=stdout_uri,
 *   stderr=stderr_uri, terminal=false).
 * The snapshotter/key are read from the container record (like the client's
 * handleMounts), so the assembly only passes the container id and the IO
 * URIs. stdout_uri/stderr_uri are the cio URIs the Go client sends; the
 * controller uses cio.LogFile, i.e. "file://<abs path>". Pass "" for none.
 * On OK, out_pid receives the task pid.
 *
 * nvidia_bin (Option C, per-container NVIDIA runtime): NULL/"" means plain
 * runc — CreateTaskRequest.options is left ABSENT, byte-identical to the
 * pre-Option-C wire. Non-NULL points the runc shim at an alternate OCI
 * runtime binary (the assembly passes "/usr/bin/nvidia-container-runtime"
 * for the GPU ffmpeg stages): the shim's runc/options.Options{BinaryName}
 * is packed (hand-packed; no runc/options codec is vendored) and carried as
 * CreateTaskRequest.options wrapped in a google.protobuf.Any with type_url
 * CC_CTR_RUNC_OPTIONS_TYPE_URL — exactly what the Go client's
 * NewTask(WithRuntimeOptions(&options.Options{BinaryName: ...})) sends
 * (client/container.go:275-280). The shim execs that binary instead of plain
 * runc; nvidia-container-runtime is a drop-in runc wrapper that injects the
 * GPU from the NVIDIA_VISIBLE_DEVICES env var already in the OCI env set.
 * The tasks service formatOptions validates that task options for
 * io.containerd.runc.v2 are exactly runc/options.Options, so the carrier is
 * ONLY set for GPU tasks (never for MediaMTX). */
int cc_ctr_create_task(int h, const char *container_id,
                       const char *stdout_uri, const char *stderr_uri,
                       uint32_t *out_pid, const char *nvidia_bin);

/* cc_ctr_start_task: Tasks/Start. On OK, out_pid receives the started pid
 * (may be NULL). */
int cc_ctr_start_task(int h, const char *container_id, uint32_t *out_pid);

/* cc_ctr_kill_task: Tasks/Kill(container_id, signal). The controller uses
 * SIGTERM (15) for graceful stop. */
int cc_ctr_kill_task(int h, const char *container_id, uint32_t signal);

/* cc_ctr_delete_task: Tasks/Delete. On OK, out_exit_status receives the
 * task's exit status (may be NULL). */
int cc_ctr_delete_task(int h, const char *container_id,
                       uint32_t *out_exit_status);

/* cc_ctr_get_task: Tasks/Get — presence check used by the stop path before
 * signalling. On OK, out_pid receives the task pid (may be NULL); returns
 * gRPC NotFound when the task does not exist. */
int cc_ctr_get_task(int h, const char *container_id, uint32_t *out_pid);

/* cc_ctr_wait_task: Tasks/Wait — BLOCKING unary call that completes when
 * the task exits; the server returns the stored exit status even for a task
 * that already exited, so signalling before waiting is safe. On OK,
 * out_exit_status receives the exit code. NOTE: the Go controller calls
 * task.Wait() in a goroutine BEFORE task.Kill() (so a fast exit is never
 * missed); this single-threaded client cannot hold a blocking Wait in
 * flight, so the assembly should Kill() first, then Wait(). The RPC set is
 * identical; only the order differs (documented deviation). */
int cc_ctr_wait_task(int h, const char *container_id,
                     uint32_t *out_exit_status);

/* --- Events --------------------------------------------------------------
 * cc_ctr_subscribe: Events/Subscribe server stream, thin wrapper over
 * cc_grpc_subscribe. filter is forwarded verbatim (containerd 2.x requires
 * quoted regexes: `topic~="/tasks/.*"`). Returns the stream id (> 0) or 0.
 * Drive with cc_grpc_poll; the callback receives raw Envelope protobuf. */
int cc_ctr_subscribe(int h, const char *filter, void *cb_ctx,
                     void (*cb)(void *cb_ctx, const uint8_t *env,
                                uint32_t len));

/* --- OCI spec JSON + Any (Q13 contract) ----------------------------------
 * cc_ctr_oci_spec_build: emit the OCI runtime spec JSON for the given field
 * set. Replicates the deterministic skeleton of the Go client's
 * GenerateSpecWithPlatform + the applied SpecOpts, with Go's
 * json.Marshal field order, omitempty behavior, number formatting, and
 * HTML escaping (\u003c \u003e \u0026). Returns the JSON length on success
 * (>= 0) or a negative CC_CTR_ERR_* code. out must hold cap bytes. */
int cc_ctr_oci_spec_build(const struct cc_ctr_oci_spec *spec, char *out,
                          uint32_t cap);

/* cc_ctr_oci_wrap_any: wrap OCI spec JSON bytes in a google.protobuf.Any
 * protobuf (type_url = CC_CTR_OCI_TYPE_URL, value = the JSON), packed into
 * out_any. Returns 0 on success (out_any_len set), negative on error. */
int cc_ctr_oci_wrap_any(const uint8_t *spec_json, uint32_t json_len,
                        uint8_t *out_any, uint32_t any_cap,
                        uint32_t *out_any_len);

/* cc_ctr_pack_runc_nvidia: pack the task-options Any for Option C
 * (per-container NVIDIA runtime) into out_any:
 *   google.protobuf.Any{
 *     type_url = CC_CTR_RUNC_OPTIONS_TYPE_URL,
 *     value    = runc/options.Options{ binary_name = nvidia_bin }   // field 6
 *   }
 * The runc Options payload is hand-packed (tag 0x32 = field 6, wire type 2;
 * varint length; string bytes) because no runc/options codec exists in
 * //third_party/containerd-api:codecs; the Any wrapper uses the vendored
 * google.protobuf.Any codec. Byte-identical to the Go client's
 * typeurl.MarshalAny(&options.Options{BinaryName: ...}) output. Returns 0
 * on success (out_any_len set), negative CC_CTR_ERR_* on error. */
int cc_ctr_pack_runc_nvidia(const char *nvidia_bin, uint8_t *out_any,
                            uint32_t any_cap, uint32_t *out_any_len);

#ifdef __cplusplus
}
#endif

#endif /* CC_CTR_H */