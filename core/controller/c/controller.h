/*
 * controller.h — the strimserver controller state machine (C port contract).
 *
 * Wave 0-A foundation header. This is the CONTRACT every controller lane
 * (state machine, containerd event listener, HTTP lane) codes against; the
 * implementations land in later waves. It mirrors the Go oracle
 * (core/controller/controller.go, names.go, main.go) 1:1:
 *
 *   - Wire strings for the enums are FIXED (see the STRIM_*_STR macros):
 *     they are what the Go JSON endpoints emit ("ready", "not-ready",
 *     "running", "stopped", "egress", "start", ...). The HTTP lane and any
 *     JSON codec MUST use strim_*_from_string / strim_*_to_string and never
 *     invent their own spellings.
 *
 *   - The controller is SINGLE-THREADED: all state lives on the action-queue
 *     goroutine (Go: `for act := range c.actions { act(c) }`). Submit
 *     functions enqueue a closure and block until the controller has run it
 *     (Go's `submit`, controller.go:182-186); RequestReconcile enqueues
 *     WITHOUT blocking. WaitForOps drains the op WaitGroup; Close closes the
 *     queue. Teardown synchronously stops every running stage.
 *
 *   - Reconcile semantics (the exactly-once contract): each stage carries an
 *     InFlight flag + timestamp. planReconcile (controller.go:316-320) fires
 *     the desired-state op only when NOT in flight, or when the previous op
 *     exceeded inflight_timeout (a timed-out retry). An op is fired exactly
 *     once per inflight period; a failed op clears InFlight so the next
 *     reconcile retries. A timed-out retry carries a cancellation/deadline
 *     handle (strim_stage_op_cancel, the C analogue of Go's context) that
 *     supersedes the previous op: the old op aborts at its next safe point
 *     and bounds its RPCs by the remaining deadline, so a stage never runs
 *     two ops concurrently (Go cancels the old op's context at the timeout).
 *
 *   - Prerequisite gating: a route's StageTarget may carry a prerequisite
 *     callback (Go: `Prerequisite func(c *Controller) error`). It is checked
 *     BEFORE the desired state is committed (applyDesiredStageTarget,
 *     controller.go:269-285); a failing prerequisite leaves the stage's
 *     desired state untouched and returns an error.
 *
 * Style: fixed-arity C (matching the repo's alternate/c conventions),
 * stdint/stdbool/stddef only, pthread-compatible callbacks (plain function
 * pointers, no closures). No heap ownership crosses this boundary: every
 * out-parameter is caller-provided and length-bounded.
 *
 * License: project code (see LICENSE). No GPL.
 */
#ifndef STRIM_CONTROLLER_H
#define STRIM_CONTROLLER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* =========================================================================
 * Wire enums — strings are the JSON contract with the Go controller
 * ========================================================================= */

typedef enum strim_path_status {
    STRIM_PATH_UNKNOWN   = 0,   /* "unknown"    */
    STRIM_PATH_READY     = 1,   /* "ready"      */
    STRIM_PATH_NOT_READY = 2,   /* "not-ready"  */
    STRIM_PATH_STATUS_COUNT,
} strim_path_status;

typedef enum strim_stage_state {
    STRIM_STAGE_STOPPED  = 0,   /* "stopped"  */
    STRIM_STAGE_RUNNING  = 1,   /* "running"  */
    STRIM_STAGE_NO_TARGET = 2,  /* "" (Go: NoTarget, never sent on the wire) */
    STRIM_STAGE_STATE_COUNT,
} strim_stage_state;

/* Path names (names.go: PathIngress0 "ingress0", PathNormalized "normalized").
 * The stage names / control component / control action enums live with their
 * routes and config in this header too (they are part of the controller
 * contract, not of any single lane). */
typedef enum strim_path_name {
    STRIM_PATH_INGRESS0    = 0, /* "ingress0"   */
    STRIM_PATH_NORMALIZED  = 1, /* "normalized" */
    STRIM_PATH_NAME_COUNT,
} strim_path_name;

typedef enum strim_stage_name {
    STRIM_STAGE_MEDIA_MTX           = 0, /* "mediamtx"            */
    STRIM_STAGE_NORMALIZE           = 1, /* "normalize"           */
    STRIM_STAGE_SCALE_AND_EGRESS    = 2, /* "scale_and_egress"    */
    STRIM_STAGE_SINGLE_STAGE_EGRESS = 3, /* "single_stage_egress" */
    STRIM_STAGE_NAME_COUNT,
} strim_stage_name;

typedef enum strim_control_component {
    STRIM_COMPONENT_EGRESS = 0,  /* "egress" */
    STRIM_COMPONENT_COUNT,
} strim_control_component;

typedef enum strim_control_action {
    STRIM_ACTION_START = 0,      /* "start" */
    STRIM_ACTION_STOP  = 1,      /* "stop"  */
    STRIM_ACTION_COUNT,
} strim_control_action;

/* Wire strings (exact JSON spellings; never change these without changing the
 * Go controller and the Stream Deck plugin's generated TS types). */
#define STRIM_PATH_UNKNOWN_STR    "unknown"
#define STRIM_PATH_READY_STR      "ready"
#define STRIM_PATH_NOT_READY_STR  "not-ready"
#define STRIM_STAGE_STOPPED_STR   "stopped"
#define STRIM_STAGE_RUNNING_STR   "running"
#define STRIM_PATH_INGRESS0_STR   "ingress0"
#define STRIM_PATH_NORMALIZED_STR "normalized"
#define STRIM_STAGE_MEDIA_MTX_STR           "mediamtx"
#define STRIM_STAGE_NORMALIZE_STR           "normalize"
#define STRIM_STAGE_SCALE_AND_EGRESS_STR    "scale_and_egress"
#define STRIM_STAGE_SINGLE_STAGE_EGRESS_STR "single_stage_egress"
#define STRIM_COMPONENT_EGRESS_STR "egress"
#define STRIM_ACTION_START_STR     "start"
#define STRIM_ACTION_STOP_STR      "stop"

/* Enum <-> wire-string helpers. strim_*_from_string returns -1 on an unknown
 * string; strim_*_to_string never returns NULL for a valid enum value. */
int  strim_path_status_from_string(const char *s, strim_path_status *out);
const char *strim_path_status_to_string(strim_path_status v);
int  strim_stage_state_from_string(const char *s, strim_stage_state *out);
const char *strim_stage_state_to_string(strim_stage_state v);
int  strim_path_name_from_string(const char *s, strim_path_name *out);
const char *strim_path_name_to_string(strim_path_name v);
int  strim_stage_name_from_string(const char *s, strim_stage_name *out);
const char *strim_stage_name_to_string(strim_stage_name v);
int  strim_control_component_from_string(const char *s, strim_control_component *out);
const char *strim_control_component_to_string(strim_control_component v);
int  strim_control_action_from_string(const char *s, strim_control_action *out);
const char *strim_control_action_to_string(strim_control_action v);

/* =========================================================================
 * Controller data types (Go controller.go structs)
 * ========================================================================= */

/* StageStatus {desired, actual}. */
typedef struct strim_stage_status {
    strim_stage_state desired;
    strim_stage_state actual;
} strim_stage_status;

/* ControllerStatus — the object the HTTP lane serializes on /status and the
 * websocket lane pushes to subscribers. Fixed-size arrays (4 stages, 2 paths):
 * the JSON codec emits the "paths"/"stages" maps with exactly the Go keys. */
typedef struct strim_controller_status {
    strim_path_status  paths[STRIM_PATH_NAME_COUNT];
    strim_stage_status stages[STRIM_STAGE_NAME_COUNT];
} strim_controller_status;

/* PathEvent {path, status} — /event POST body. */
typedef struct strim_path_event {
    strim_path_name   path;
    strim_path_status status;
} strim_path_event;

/* StageEvent {stage, state} — internal; produced by the containerd listener. */
typedef struct strim_stage_event {
    strim_stage_name stage;
    strim_stage_state state;
} strim_stage_event;

/* ControlCommand {component, action} — /control POST body. */
typedef struct strim_control_command {
    strim_control_component component;
    strim_control_action    action;
} strim_control_command;

/* Opaque controller handle. All state is owned by the implementation; the
 * HTTP/containerd/JSON lanes only ever pass this pointer back in. */
typedef struct strim_controller strim_controller;

/* One fired op's cancellation/deadline handle — the C analogue of Go's
 * context.Context (the `operationCtx` handleReconcile builds with
 * context.WithTimeout, controller.go:299). The controller creates one per
 * fired op and passes it to the op as the third argument; the op MUST NOT
 * retain the pointer after returning. The handle carries the fire's
 * generation (bumped when a timed-out retry supersedes an older op) and its
 * absolute deadline. Ops check strim_stage_op_superseded() at safe points
 * and bound every RPC by strim_stage_op_remaining_ms(). */
typedef struct strim_stage_op_cancel strim_stage_op_cancel;

/* Non-zero when a newer op was fired for the same stage (a timed-out retry
 * superseded this one); the op should stop at its next safe point. A NULL
 * handle (the Teardown path, which runs with no cancellation — Go's
 * context.WithoutCancel) is never superseded. */
int strim_stage_op_superseded(const strim_stage_op_cancel *cancel);

/* The remaining budget in ms until the op's absolute deadline (0 or negative
 * when already expired). Ops bound every RPC by min(own timeout, this). A
 * NULL handle returns -1 (no deadline; the op falls back to its own
 * timeout). */
int64_t strim_stage_op_remaining_ms(const strim_stage_op_cancel *cancel);

/* Stage op — the "operation" the reconcile loop fires exactly once per
 * inflight period (Go: `Ops map[StageState]func(context.Context) error`).
 *   op_ctx:      the stage's userdata (container factory / HTTP lane).
 *   timeout_ms:  the inflight timeout; the op must bound its work by it
 *                (Go: context.WithTimeout(ctx, c.inflightTimeout)).
 *   cancel:      the fire's cancellation/deadline handle (Go: the context);
 *                NULL on the Teardown path (no cancellation). The op checks
 *                strim_stage_op_superseded() at safe points and bounds RPCs
 *                by strim_stage_op_remaining_ms().
 * Returns 0 on success, non-zero on failure (failure clears InFlight so the
 * next reconcile retries — the Go controller.go:304-312 contract). A
 * superseded op returns 0: the newer retry owns the stage, and clearing
 * InFlight would unblock a THIRD concurrent op. */
typedef int (*strim_stage_op)(void *op_ctx, int64_t timeout_ms,
                              const strim_stage_op_cancel *cancel);

/* Prerequisite gate for a route target (Go: `func(c *Controller) error`).
 * Called with the controller before the desired state is committed. Return 0
 * to allow the transition, non-zero to reject it (the stage's desired state
 * is then left unchanged and the submit returns an error). */
typedef int (*strim_prerequisite_fn)(strim_controller *c, void *userdata);

/* One route entry. Exactly one of {path_event, control} is active, chosen by
 * `kind` — mirroring the Go controller's two maps (pathEventRoutes /
 * commandRoutes). A route without a prerequisite passes prerequisite = NULL. */
typedef struct strim_route {
    /* Route key. */
    strim_path_name    path;         /* kind == STRIM_ROUTE_PATH_EVENT       */
    strim_path_status  path_status;  /* kind == STRIM_ROUTE_PATH_EVENT       */
    strim_control_component component; /* kind == STRIM_ROUTE_CONTROL        */
    strim_control_action    action;    /* kind == STRIM_ROUTE_CONTROL        */
    int kind; /* STRIM_ROUTE_PATH_EVENT or STRIM_ROUTE_CONTROL (below) */

    /* Target (StageTarget). */
    strim_stage_name   target_stage;
    strim_stage_state  target_state;
    strim_prerequisite_fn prerequisite;  /* NULL = none                      */
    void *prerequisite_userdata;
} strim_route;

#define STRIM_ROUTE_PATH_EVENT 0
#define STRIM_ROUTE_CONTROL    1

/* One stage (Go: `Stage{Status, Ops map[StageState]func, InFlightSince}`).
 * start_op/stop_op are the Ops for Running/Stopped; a stage without an op for
 * a target state simply cannot be driven there (the Go NewController rejects
 * such routes at construction; the C NewController must too). */
typedef struct strim_stage_config {
    strim_stage_name   name;
    strim_stage_status status;
    strim_stage_op     start_op;    /* target == STRIM_STAGE_RUNNING */
    strim_stage_op     stop_op;     /* target == STRIM_STAGE_STOPPED */
    void *op_ctx;                   /* passed to both ops            */
} strim_stage_config;

/* Controller listener (Go: `type ControllerListener func(*ControllerStatus)`).
 * Invoked on the action-queue thread whenever the status changes. The HTTP
 * lane wraps this in the 1-deep drop-oldest/latest-wins ws send queue. */
typedef void (*strim_controller_listener)(const strim_controller_status *status,
                                          void *userdata);

/* Construction parameters. Mirrors NewController's argument list:
 *   ctx            -> (the C port runs the queue on the calling thread)
 *   paths          -> initial_paths (by enum index)
 *   stages         -> stages[] (by enum index)
 *   pathEventRoutes -> path_routes[] entries with kind == PATH_EVENT
 *   commandRoutes  -> control_routes[] entries with kind == CONTROL
 *   now            -> now_ms (NULL = real clock)
 *   inflightTimeout -> inflight_timeout_ms (> 0, required)
 *   actionsBufferSize -> actions_buffer_size (> 0, required)
 */
typedef struct strim_controller_config {
    strim_path_status       initial_paths[STRIM_PATH_NAME_COUNT];
    strim_stage_config      stages[STRIM_STAGE_NAME_COUNT];
    const strim_route      *path_routes;
    size_t                  n_path_routes;
    const strim_route      *control_routes;
    size_t                  n_control_routes;
    int64_t               (*now_ms)(void);   /* NULL = wall clock */
    int64_t                 inflight_timeout_ms;
    size_t                  actions_buffer_size;
} strim_controller_config;

/* =========================================================================
 * API
 * ========================================================================= */

/* --- Construction / lifecycle -------------------------------------------
 * strim_controller_new: validate the config exactly like Go NewController
 * (controller.go:105-176): every route target must name a configured stage
 * that has an op for the target state; inflight timeout and buffer size must
 * be positive; seeded path statuses must be valid. Returns 0 + *out, or a
 * negative STRIM_CTRL_ERR_* code (see below). */
int strim_controller_new(const strim_controller_config *cfg,
                         strim_controller **out);

/* strim_controller_run: run the action queue until Close. Blocks the calling
 * thread (the C equivalent of `for act := range c.actions`). Call it on the
 * controller's own thread after construction; submits from any other thread
 * enqueue and (for the blocking submits) wait for their reply. */
void strim_controller_run(strim_controller *c);

/* strim_controller_close: close the queue; Run returns. No submits after
 * Close (same contract as Go's close(c.actions)). */
void strim_controller_close(strim_controller *c);

/* strim_controller_destroy: free the controller. Must be called after Run has
 * returned and WaitForOps/Teardown have completed. */
void strim_controller_destroy(strim_controller *c);

/* --- Action-queue submit surface -----------------------------------------
 * Blocking submits: enqueue the handler, wait for it to run, return its
 * error. Exactly the Go `submit` helper (controller.go:182-186). */

/* SubmitPathEvent: /event handler. Updates paths[] then applies the matching
 * path-event route (if any). */
int strim_controller_submit_path_event(strim_controller *c,
                                       const strim_path_event *e);

/* SubmitControl: /control handler. Applies the matching control route. */
int strim_controller_submit_control(strim_controller *c,
                                    const strim_control_command *cmd);

/* SubmitStageEvent: internal; the containerd listener calls this when a
 * TaskStart/TaskExit event maps to a stage (container_factory.go:330). */
int strim_controller_submit_stage_event(strim_controller *c,
                                        const strim_stage_event *e);

/* SubmitStatus: synchronous snapshot of the controller status (Go's
 * Status()). The HTTP lane's /status handler calls this. */
int strim_controller_submit_status(strim_controller *c,
                                   strim_controller_status *out);

/* SubmitAddListener / SubmitRemoveListener: register/unregister a status
 * listener (Go's SubmitAddListener/SubmitRemoveListener). The websocket lane
 * registers one per ws client. */
int strim_controller_submit_add_listener(strim_controller *c,
                                         strim_controller_listener listener,
                                         void *userdata);
int strim_controller_submit_remove_listener(strim_controller *c,
                                            strim_controller_listener listener,
                                            void *userdata);

/* RequestReconcile: non-blocking enqueue of a reconcile pass (Go's
 * RequestReconcile, controller.go:212-214). The HTTP lane calls it after a
 * successful /event or /control; the reconcile ticker calls it on its
 * interval. */
void strim_controller_request_reconcile(strim_controller *c);

/* WaitForOps: block until every in-flight stage op has finished (Go's
 * c.ops.Wait()). Used during shutdown before Teardown. */
void strim_controller_wait_for_ops(strim_controller *c);

/* Teardown: synchronously stop every stage whose actual state is Running
 * (Go's Teardown, controller.go:331-348): fire the stage's stop op with the
 * inflight timeout, then mark desired/actual == Stopped and notify. */
int strim_controller_teardown(strim_controller *c);

/* --- Internal handlers (exposed for tests and the action queue) ----------
 * The submit functions above are thin enqueue wrappers over these; the
 * handler implementations run on the action-queue thread only. A lane that
 * needs to run a handler WITHOUT the queue (e.g. the Teardown path, which
 * Go implements as a queued closure that runs inline) may call the handler
 * directly with c owned by the calling thread. */

/* handlePathEvent: validate + store the path status, apply the route.
 * Errors: invalid path name / invalid status / prerequisite failure. */
int strim_controller_handle_path_event(strim_controller *c,
                                       const strim_path_event *e);

/* handleControl: apply the control route. Errors: unknown command /
 * prerequisite failure. */
int strim_controller_handle_control(strim_controller *c,
                                    const strim_control_command *cmd);

/* handleStageEvent: validate + store actual state, clear InFlight, notify
 * listeners on change (Go controller.go:236-248). */
int strim_controller_handle_stage_event(strim_controller *c,
                                        const strim_stage_event *e);

/* handleReconcile: one reconcile pass over all stages — the exactly-once
 * firing contract (Go controller.go:287-314). Non-blocking: it launches ops
 * and returns immediately. */
void strim_controller_handle_reconcile(strim_controller *c);

/* handleStatus: fill out with the current snapshot. */
int strim_controller_handle_status(strim_controller *c,
                                   strim_controller_status *out);

/* =========================================================================
 * Error codes (negative; distinct from op/prerequisite returns)
 * ========================================================================= */

#define STRIM_CTRL_ERR_BADARG    (-1) /* NULL arg / invalid enum / bad config */
#define STRIM_CTRL_ERR_UNKNOWN   (-2) /* unknown path, stage, or command      */
#define STRIM_CTRL_ERR_PREREQ    (-3) /* prerequisite rejected the transition */
#define STRIM_CTRL_ERR_CLOSED    (-4) /* submit after Close                   */
#define STRIM_CTRL_ERR_NOMEM     (-5) /* internal allocation failed           */

#ifdef __cplusplus
}
#endif

#endif /* STRIM_CONTROLLER_H */