/*
 * containerd_client.h — containerd client contract for the C controller.
 *
 * Wave 0-A foundation header. This is the interface the container lane
 * implements (likely on top of the existing h2c/gRPC client in
 * core/controller/alternate/c) and the state lane drives. It mirrors the Go
 * oracle's containerClient interface + task lifecycle
 * (core/controller/container_factory.go):
 *
 *   - Every call is NAMESPACE-SCOPED: the namespace is fixed at connect time
 *     and attached to every RPC (Go: namespaces.WithNamespace + the
 *     "containerd-namespace: <ns>" header; the alternate cc_grpc client does
 *     the same).
 *
 *   - NewContainer replicates the Go construction contract:
 *       GetImage(image_name)
 *       NewContainer(id,
 *           WithNewSnapshot(snapshot_id, image),   // rootfs FROM the image
 *           WithNewSpec(spec_opts...))             // the built OCI spec
 *     The snapshot parent chain MUST come from the image (never an
 *     empty-parented snapshot) — the exact contract documented in
 *     container_factory.go:133-137 and the alternate/c DESIGN-NOTES.md.
 *
 *   - Task lifecycle (the Go CreateTask + CreateContainerOps sequence):
 *       NewTask(logfile) -> Start
 *       stop: LoadContainer -> task.Task -> Wait (BEFORE Kill) -> Kill(SIGTERM)
 *             -> wait-exit -> Delete; timeout -> Delete(WithProcessKill).
 *
 *   - Subscribe returns an event stream; the controller lane dispatches
 *     envelopes by typeurl (TaskStart -> Running, TaskExit -> Stopped) and
 *     maps GetContainerID() -> stage (container_factory.go:297-341).
 *
 * Handles are opaque and owned by the implementation. Output buffers are
 * caller-provided. All functions are fixed-arity and thread-compatible with
 * pthreads (a client may be used from one thread at a time, matching the
 * single-threaded controller model).
 *
 * License: project code (see LICENSE). No GPL.
 */
#ifndef STRIM_CONTAINERD_CLIENT_H
#define STRIM_CONTAINERD_CLIENT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#include "spec.h"   /* strim_spec — the container's OCI spec              */

/* =========================================================================
 * Handles
 * ========================================================================= */

typedef struct strim_containerd_client strim_containerd_client;
typedef struct strim_image             strim_image;
typedef struct strim_container         strim_container;
typedef struct strim_task              strim_task;
typedef struct strim_event_stream      strim_event_stream;
typedef struct strim_event_envelope    strim_event_envelope;

/* =========================================================================
 * Constants
 * ========================================================================= */

/* The default snapshotter / runtime names (containerd defaults; the Go
 * client's WithNewSnapshot uses the default snapshotter, and Tasks/Create
 * uses the default runtime). */
#define STRIM_CTRD_DEFAULT_SNAPSHOTTER "overlayfs"
#define STRIM_CTRD_DEFAULT_RUNTIME     "io.containerd.runc.v2"

/* The signal the Go stop path sends (syscall.SIGTERM). */
#define STRIM_CTRD_KILL_SIGTERM 15

/* Error codes (negative; distinct from gRPC statuses which are >= 0). */
#define STRIM_CTRD_ERR_BADARG    (-1) /* NULL/empty required argument        */
#define STRIM_CTRD_ERR_CONNECT   (-2) /* could not connect to the daemon     */
#define STRIM_CTRD_ERR_NOTFOUND  (-3) /* object not found (Go errdefs NotFound) */
#define STRIM_CTRD_ERR_TIMEOUT   (-4) /* blocking call exceeded its timeout  */
#define STRIM_CTRD_ERR_IO        (-5) /* transport / socket error            */
#define STRIM_CTRD_ERR_PROTO     (-6) /* protocol / parse error              */
#define STRIM_CTRD_ERR_CLOSED    (-7) /* use after Close                     */
#define STRIM_CTRD_ERR_NOMEM     (-8) /* internal allocation failed          */
#define STRIM_CTRD_ERR_RPC       (-9) /* daemon returned a non-OK gRPC status */

/* =========================================================================
 * Error diagnostics
 * ========================================================================= */

/* LastError(client, buf, cap): copy a description of the most recent
 * daemon-returned gRPC error status observed on the shared connection into
 * buf (e.g. "grpc status 13 (INTERNAL)"). This is how a caller tells WHY an
 * RPC failed once a strim_containerd_* call returned STRIM_CTRD_ERR_RPC: the
 * folded code alone cannot distinguish a shim/runc error on Tasks/Create
 * (INTERNAL) from a bad argument (INVALID_ARGUMENT). Returns the number of
 * chars copied, 0 when no daemon error has been observed since connect, or
 * STRIM_CTRD_ERR_BADARG.
 *
 * NOTE: the daemon's grpc-message TEXT is decoded and retained inside the h2c
 * layer but is not yet exposed through a public accessor; this surfaces the
 * status code + canonical name. Thread-safe: reads under the client lock. */
int strim_containerd_last_error(const strim_containerd_client *client,
                                char *buf, size_t cap);

/* =========================================================================
 * Client lifecycle
 * ========================================================================= */

/* Connect to the daemon socket path and fix the namespace for every RPC (the
 * Go client is created with `containerd.New(socket)` and every context
 * carries namespaces.WithNamespace). Returns 0 + *out, or a negative error.
 *
 * CONNECTION LIFECYCLE (Wave 3 — lazy connect + reconnect, matching Go):
 * strim_containerd_connect is LAZY, exactly like Go's containerd.New: it
 * never dials the socket. The shared connection is established by the first
 * RPC and re-established by the next RPC after any transport-level failure
 * tears it down. Consequences, identical to Go:
 *
 *   - A containerd daemon that is down at boot is NOT fatal: connect returns
 *     a valid client, the first RPC fails with STRIM_CTRD_ERR_CONNECT, and
 *     every later RPC retries the connection, so the caller recovers when the
 *     daemon comes up (no `client == NULL` state to get stuck in).
 *   - A daemon that dies mid-flight is recovered the same way: the failed RPC
 *     returns STRIM_CTRD_ERR_IO (or the server's gRPC status), the dead
 *     connection is discarded, and the next RPC dials afresh.
 *
 * Task Wait and event Subscribe open their own per-call connections, so they
 * are inherently lazy and reconnect per call; only the shared connection
 * needs the explicit lifecycle above. */
int strim_containerd_connect(const char *socket_path, const char *ns,
                             strim_containerd_client **out);

/* Close the client; invalidates all handles derived from it. */
void strim_containerd_close(strim_containerd_client *client);

/* =========================================================================
 * Images
 * ========================================================================= */

/* GetImage(ref): resolve image_name to a handle (Go: client.GetImage).
 * The returned image is owned by the client and stays valid until close. */
int strim_containerd_get_image(strim_containerd_client *client,
                               const char *ref, strim_image **out);

/* =========================================================================
 * Containers
 * ========================================================================= */

/* NewContainer(id, snapshot_id, image_name, spec): replicate the Go
 * construction contract — the rootfs snapshot is created FROM the resolved
 * image (WithNewSnapshot), and the OCI spec is built from `spec`. The
 * implementation must internally: GetImage(image_name), create the snapshot
 * parented on the image's chain (NEVER empty-parented), and create the
 * container. */
int strim_containerd_new_container(strim_containerd_client *client,
                                   const char *id,
                                   const char *snapshot_id,
                                   const char *image_name,
                                   const strim_spec *spec,
                                   strim_container **out);

/* LoadContainer(id): open an existing container (Go: client.LoadContainer). */
int strim_containerd_load_container(strim_containerd_client *client,
                                    const char *id, strim_container **out);

/* Delete(container, cleanup_snapshot): remove the container; with
 * cleanup_snapshot != 0 also remove its snapshot (Go:
 * container.Delete(ctx, containerd.WithSnapshotCleanup)). Only valid when no
 * task is running. */
int strim_containerd_delete_container(strim_container *container,
                                      int cleanup_snapshot);

/* =========================================================================
 * Tasks
 * ========================================================================= */

/* NewTask(container, logfile): create the task with the given log file as its
 * stdio (Go: container.NewTask(ctx, cio.LogFile(logfile))). logfile == NULL
 * means no log capture. Returns 0 + *out, or a negative error (NotFound when
 * the task was already deleted). */
int strim_containerd_new_task(strim_container *container, const char *logfile,
                              strim_task **out);

/* LoadTask(container): open the container's existing task (Go:
 * container.Task(ctx, cio.Load)). NotFound when no task exists. */
int strim_containerd_load_task(strim_container *container, strim_task **out);

/* Start: task.Start — launch the task process. */
int strim_containerd_task_start(strim_task *task);

/* Kill(task, signum): send a signal (use STRIM_CTRD_KILL_SIGTERM). NotFound
 * is tolerated (task already gone). */
int strim_containerd_task_kill(strim_task *task, int signum);

/* Wait(task, timeout_ms, *exit_code): subscribe to the task's exit BEFORE it
 * is signalled (the Go stop path subscribes with task.Wait then kills —
 * container_factory.go:203-213; a fast-exiting task can fire its exit before
 * the wait otherwise). Blocks until the task exits (0 + exit code), the
 * timeout elapses (STRIM_CTRD_ERR_TIMEOUT), or an error occurs. May be called
 * at most once per task. */
int strim_containerd_task_wait(strim_task *task, int64_t timeout_ms,
                               int32_t *exit_code);

/* Delete(task, force): reap the task. force != 0 kills first (Go:
 * task.Delete(ctx, containerd.WithProcessKill)); force == 0 requires the
 * task to have exited. */
int strim_containerd_task_delete(strim_task *task, int force);

/* =========================================================================
 * Event subscription (typeurl dispatch)
 * ========================================================================= */

/* Subscribe(filters, n_filters): open an event stream for the given containerd
 * filters (Go: client.Subscribe(ctx, filters...); the controller uses
 * `topic~="/tasks/.*"`). The stream yields envelopes in order until closed or
 * the daemon errors. */
int strim_containerd_subscribe(strim_containerd_client *client,
                               const char *const *filters, size_t n_filters,
                               strim_event_stream **out);

/* EventStreamNext(stream, timeout_ms, **envelope): block for the next
 * envelope. Returns 0 + a non-NULL *envelope; STRIM_CTRD_ERR_TIMEOUT when
 * timeout_ms elapses first; STRIM_CTRD_ERR_CLOSED when the stream is closed
 * (caller cancelled); STRIM_CTRD_ERR_IO when the daemon stream errors (the
 * Go error channel — the listener exits, container_factory.go:333-336). */
int strim_event_stream_next(strim_event_stream *stream, int64_t timeout_ms,
                            strim_event_envelope **out);

/* EventStreamClose: close the stream and release its resources. */
void strim_event_stream_close(strim_event_stream *stream);

/* Event kind (typeurl dispatch). The controller maps TaskStart -> Running
 * and TaskExit -> Stopped (main.go:303-306). */
typedef enum strim_event_kind {
    STRIM_EVENT_TASK_START = 0,  /* events.TaskStart  */
    STRIM_EVENT_TASK_EXIT  = 1,  /* events.TaskExit   */
    STRIM_EVENT_OTHER      = 2,  /* any other type    */
} strim_event_kind;

/* EventGetKind(envelope): classify the envelope by its typeurl payload.
 * Envelopes that fail to unmarshal are STRIM_EVENT_OTHER (the Go listener
 * logs and continues, container_factory.go:312-314). */
strim_event_kind strim_event_get_kind(const strim_event_envelope *envelope);

/* EventContainerID(envelope, buf, cap): the envelope's GetContainerID()
 * (the TaskEvent interface, container_factory.go:301). Returns the string
 * length, or a negative error if the payload has no container id. The
 * controller maps it to a stage name via its container-id table. */
int strim_event_container_id(const strim_event_envelope *envelope,
                             char *buf, size_t cap);

#ifdef __cplusplus
}
#endif

#endif /* STRIM_CONTAINERD_CLIENT_H */