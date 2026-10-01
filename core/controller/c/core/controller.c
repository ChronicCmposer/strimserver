/*
 * controller.c — the strimserver controller state machine (C port).
 *
 * Implements the controller.h contract 1:1 from the Go oracle
 * (core/controller/controller.go + names.go); see controller.h for the wire
 * strings, lifecycle, reconcile, and teardown semantics.
 *
 * C-port-specific deviations from the Go oracle:
 *   - request_reconcile coalesces: at most one reconcile pass is queued,
 *     latest-wins (safe: reconciles are idempotent).
 *   - Teardown runs as a queued action (ACTION_TEARDOWN) so it serializes
 *     with every other handler on the single queue thread.
 *
 * License: project code (see LICENSE). No GPL.
 */

#include "controller.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Internal bounds (not part of the public contract; fail loud if exceeded).
 * The worker pool is sized one worker per stage: at most one op per stage can
 * be in flight, so one worker per stage suffices and the pool stays small. */
#define STRIM_CTRL_MAX_LISTENERS 16
#define STRIM_CTRL_WORKERS       STRIM_STAGE_NAME_COUNT

/* -------------------------------------------------------------------------
 * Action queue — the serialized single-writer core
 * ------------------------------------------------------------------------- */

typedef enum strim_action_kind {
    ACTION_PATH_EVENT,
    ACTION_CONTROL,
    ACTION_STAGE_EVENT,
    ACTION_STATUS,
    ACTION_ADD_LISTENER,
    ACTION_REMOVE_LISTENER,
    ACTION_RECONCILE,
    ACTION_CLEAR_INFLIGHT,
    ACTION_TEARDOWN,
} strim_action_kind;

typedef struct strim_action {
    strim_action_kind kind;
    struct strim_action *next;

    /* payload */
    strim_path_event         path_event;
    strim_control_command    control;
    strim_stage_event        stage_event;
    strim_controller_status *status_out;    /* ACTION_STATUS               */
    strim_controller_listener listener;     /* ACTION_ADD/REMOVE_LISTENER  */
    void                    *listener_userdata;
    strim_stage_name         clear_stage;   /* ACTION_CLEAR_INFLIGHT       */
    uint64_t clear_generation;  /* fire generation stamped at enqueue
                                 * (ACTION_CLEAR_INFLIGHT)               */

    /* blocking-reply handshake (all ACTION_* submits) */
    int  reply_result;
    bool reply_done;

    /* non-blocking actions (reconcile, clear-inflight) are freed by the
     * queue thread after processing; blocking submits own their action
     * (often stack-allocated) and free it after reply_done. */
    bool self_allocated;
} strim_action;

typedef struct strim_waitgroup {
    size_t count;
    pthread_mutex_t lock;
    pthread_cond_t  cond;
} strim_waitgroup;

typedef struct strim_worker_job {
    void (*fn)(void *arg);
    void *arg;
    struct strim_worker_job *next;
} strim_worker_job;

typedef struct strim_workerpool {
    pthread_t threads[STRIM_CTRL_WORKERS];
    size_t    n_threads;
    pthread_mutex_t lock;
    pthread_cond_t  cond;
    strim_worker_job *head;
    strim_worker_job *tail;
    bool shutting_down;
} strim_workerpool;

/* One stage (Go: Stage{Status, Ops map[StageState]func, InFlightSince}). */
typedef struct strim_stage {
    strim_stage_name   name;
    strim_stage_status status;
    strim_stage_op     start_op;    /* target == STRIM_STAGE_RUNNING */
    strim_stage_op     stop_op;     /* target == STRIM_STAGE_STOPPED */
    void              *op_ctx;
    int64_t            in_flight_since; /* 0 == not in flight (Go zero time) */
    /* The fire generation: bumped every time reconcile fires this stage's op.
     * A fired op records the generation it was launched with; a timed-out
     * retry bumps this counter, which supersedes the older op (its cancel
     * handle reads a generation mismatch and aborts at its next safe point).
     * Atomic: the queue thread bumps it and the worker threads (the running
     * ops) read it through their cancel handles. */
    _Atomic uint64_t   op_generation;
} strim_stage;

typedef struct strim_listener_entry {
    strim_controller_listener fn;
    void *userdata;
} strim_listener_entry;

struct strim_controller {
    strim_path_status paths[STRIM_PATH_NAME_COUNT];
    strim_stage       stages[STRIM_STAGE_NAME_COUNT];

    strim_route *path_routes;    /* copied + validated at construction */
    size_t       n_path_routes;
    strim_route *control_routes;
    size_t       n_control_routes;

    strim_listener_entry listeners[STRIM_CTRL_MAX_LISTENERS];
    size_t               n_listeners;

    int64_t (*now_ms)(void);
    int64_t  inflight_timeout_ms;
    size_t   actions_buffer_size;

    /* The action queue. All fields below are guarded by q_lock except the
     * handler-visible controller state (paths/stages/listeners), which is
     * only touched by handlers running on the queue thread (the Go
     * single-writer invariant). */
    pthread_mutex_t q_lock;
    pthread_cond_t  q_cond;
    strim_action   *q_head;
    strim_action   *q_tail;
    bool            q_closed;
    bool            reconcile_queued;

    /* Shutdown handshake. Set by begin_shutdown() UNDER q_lock — before
     * WaitForOps — so a reconcile that races shutdown either sees the flag in
     * its locked fire section and suppresses the fire, or acquired the lock
     * first and already completed its wg_add; WaitForOps can then only return
     * after every already-submitted op has finished. close() also sets it
     * (idempotent belt-and-suspenders for callers that skip begin_shutdown).
     * Enforced order: begin_shutdown (suppress fires) -> WaitForOps ->
     * Teardown -> Close (Run returns) -> Destroy. Atomic: written under
     * q_lock, read by reconcile on the queue thread. */
    _Atomic bool shutting_down;

    strim_waitgroup  ops_wg;
    strim_workerpool pool;
};

/* -------------------------------------------------------------------------
 * Small helpers
 * ------------------------------------------------------------------------- */

static bool valid_path_status(strim_path_status s) {
    return (unsigned)s < (unsigned)STRIM_PATH_STATUS_COUNT;
}

static bool valid_stage_state(strim_stage_state s) {
    /* A stored stage state is only ever STOPPED or RUNNING; NO_TARGET is a
     * reconcile sentinel, never a stored desired/actual state. */
    return (unsigned)s <= (unsigned)STRIM_STAGE_RUNNING;
}

static int64_t default_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* The op for a target state; target is always RUNNING or STOPPED after
 * validation (valid_stage_state rejects NO_TARGET). */
static strim_stage_op stage_op_for(const strim_stage *stage,
                                   strim_stage_state target) {
    return (target == STRIM_STAGE_RUNNING) ? stage->start_op : stage->stop_op;
}

/* Route keys are unique at construction; the first match is the only match. */
static bool route_keys_equal(const strim_route *a, const strim_route *b,
                             int kind_expected) {
    if (kind_expected == STRIM_ROUTE_PATH_EVENT) {
        return a->path == b->path && a->path_status == b->path_status;
    }
    return a->component == b->component && a->action == b->action;
}

static const strim_route *find_path_event_route(const strim_controller *c,
                                                strim_path_name path,
                                                strim_path_status status) {
    for (size_t i = 0; i < c->n_path_routes; i++) {
        const strim_route *r = &c->path_routes[i];
        if (r->path == path && r->path_status == status) {
            return r; /* first match is the only match (routes are unique) */
        }
    }
    return NULL;
}

static const strim_route *find_control_route(const strim_controller *c,
                                             strim_control_component component,
                                             strim_control_action action) {
    for (size_t i = 0; i < c->n_control_routes; i++) {
        const strim_route *r = &c->control_routes[i];
        if (r->component == component && r->action == action) {
            return r; /* first match is the only match (routes are unique) */
        }
    }
    return NULL;
}

/* -------------------------------------------------------------------------
 * Op cancellation/deadline handle (controller.h strim_stage_op_cancel) —
 * the C analogue of Go's context.Context. Opaque to the ops: the fields are
 * internal to the controller and the ops only go through the two helpers.
 * ------------------------------------------------------------------------- */

struct strim_stage_op_cancel {
    uint64_t  generation;             /* this fire's generation (fixed at fire) */
    int64_t   deadline_ms;            /* absolute deadline (now_ms epoch)       */
    _Atomic uint64_t *current_generation; /* the stage's live generation       */
    int64_t (*now_ms)(void);          /* the controller's clock                 */
};

int strim_stage_op_superseded(const strim_stage_op_cancel *cancel) {
    if (cancel == NULL) {
        return 0; /* no cancellation (Teardown); never superseded */
    }
    /* The stage generation is _Atomic: the queue thread bumps it while the
     * worker threads (running ops) read it. The read may lag a bump — the
     * op then aborts at its NEXT safe point, and the deadline bound limits
     * how long it can lag. */
    return atomic_load(cancel->current_generation) != cancel->generation;
}

int64_t strim_stage_op_remaining_ms(const strim_stage_op_cancel *cancel) {
    if (cancel == NULL || cancel->now_ms == NULL) {
        return -1; /* no deadline; the op falls back to its own timeout */
    }
    /* Raw difference: <= 0 means the deadline already passed. */
    return cancel->deadline_ms - cancel->now_ms();
}

/* -------------------------------------------------------------------------
 * WaitGroup (Go sync.WaitGroup)
 * ------------------------------------------------------------------------- */

static void wg_add(strim_waitgroup *wg, size_t n) {
    pthread_mutex_lock(&wg->lock);
    wg->count += n;
    pthread_mutex_unlock(&wg->lock);
}

static void wg_done(strim_waitgroup *wg) {
    pthread_mutex_lock(&wg->lock);
    if (wg->count > 0) {
        wg->count--;
        if (wg->count == 0) {
            pthread_cond_broadcast(&wg->cond);
        }
    }
    pthread_mutex_unlock(&wg->lock);
}

static void wg_wait(strim_waitgroup *wg) {
    pthread_mutex_lock(&wg->lock);
    while (wg->count > 0) {
        pthread_cond_wait(&wg->cond, &wg->lock);
    }
    pthread_mutex_unlock(&wg->lock);
}

/* -------------------------------------------------------------------------
 * Queue helpers
 * ------------------------------------------------------------------------- */

/* Append act to the queue and wake the queue thread. The caller holds
 * q_lock. */
static void enqueue_locked(strim_controller *c, strim_action *act) {
    act->next = NULL;
    if (c->q_tail == NULL) {
        c->q_head = c->q_tail = act;
    } else {
        c->q_tail->next = act;
        c->q_tail = act;
    }
    pthread_cond_signal(&c->q_cond);
}

/* Enqueue + wait for the queue thread to run act (Go `submit`). Returns the
 * handler's result, or STRIM_CTRL_ERR_CLOSED when the queue is closed. The
 * caller owns act (often stack-allocated); it must stay alive until
 * reply_done. Must not be called from the queue thread itself (Go would
 * deadlock the same way). */
static int queue_submit(strim_controller *c, strim_action *act) {
    act->reply_result = 0;
    act->reply_done = false;
    act->self_allocated = false;

    pthread_mutex_lock(&c->q_lock);
    if (c->q_closed) {
        pthread_mutex_unlock(&c->q_lock);
        return STRIM_CTRL_ERR_CLOSED;
    }
    enqueue_locked(c, act);
    while (!act->reply_done) {
        pthread_cond_wait(&c->q_cond, &c->q_lock);
    }
    int result = act->reply_result;
    pthread_mutex_unlock(&c->q_lock);
    return result;
}

/* -------------------------------------------------------------------------
 * Worker pool — long-running ops (create/start/kill) run off the queue
 * thread, exactly like the Go `go func()` launches in handleReconcile.
 * ------------------------------------------------------------------------- */

static void *worker_main(void *arg) {
    strim_workerpool *pool = arg;
    for (;;) {
        strim_worker_job *job = NULL;
        pthread_mutex_lock(&pool->lock);
        while (pool->head == NULL && !pool->shutting_down) {
            pthread_cond_wait(&pool->cond, &pool->lock);
        }
        if (pool->head != NULL) {
            job = pool->head;
            pool->head = job->next;
            if (pool->head == NULL) {
                pool->tail = NULL;
            }
        }
        pthread_mutex_unlock(&pool->lock);
        if (job == NULL) {
            break; /* shutting down and drained */
        }
        job->fn(job->arg);
        free(job);
    }
    return NULL;
}

static int workerpool_init(strim_workerpool *pool);

static void workerpool_shutdown(strim_workerpool *pool) {
    pthread_mutex_lock(&pool->lock);
    pool->shutting_down = true;
    pthread_cond_broadcast(&pool->cond);
    pthread_mutex_unlock(&pool->lock);
    for (size_t i = 0; i < pool->n_threads; i++) {
        pthread_join(pool->threads[i], NULL);
    }
    pthread_mutex_destroy(&pool->lock);
    pthread_cond_destroy(&pool->cond);
}

static int workerpool_init(strim_workerpool *pool) {
    pthread_mutex_init(&pool->lock, NULL);
    pthread_cond_init(&pool->cond, NULL);
    pool->head = pool->tail = NULL;
    pool->shutting_down = false;
    pool->n_threads = 0;
    for (size_t i = 0; i < STRIM_CTRL_WORKERS; i++) {
        if (pthread_create(&pool->threads[i], NULL, worker_main, pool) != 0) {
            /* Fail loud: shut down what we created and report OOM. */
            workerpool_shutdown(pool);
            return STRIM_CTRL_ERR_NOMEM;
        }
        pool->n_threads++;
    }
    return 0;
}

/* Enqueue one job. Returns 0 on success. On failure the caller still owns arg
 * (and must free/undo it); on success the worker thread frees it after fn
 * returns. Soft failure only — never aborts the process (the reconcile fire
 * path handles OOM and pool shutdown by retrying on the next reconcile). */
static int workerpool_submit(strim_workerpool *pool, void (*fn)(void *arg),
                             void *arg) {
    strim_worker_job *job = malloc(sizeof *job);
    if (job == NULL) {
        return STRIM_CTRL_ERR_NOMEM;
    }
    job->fn = fn;
    job->arg = arg;
    job->next = NULL;
    pthread_mutex_lock(&pool->lock);
    if (pool->shutting_down) {
        /* Defense-in-depth: reconcile suppresses new fires before close(), so
         * a submit after shutdown is a programming error. Refuse the job
         * (the caller undoes its wg/stage accounting) rather than leak it and
         * hang WaitForOps. */
        pthread_mutex_unlock(&pool->lock);
        free(job);
        return STRIM_CTRL_ERR_CLOSED;
    }
    if (pool->tail == NULL) {
        pool->head = pool->tail = job;
    } else {
        pool->tail->next = job;
        pool->tail = job;
    }
    pthread_cond_signal(&pool->cond);
    pthread_mutex_unlock(&pool->lock);
    return 0;
}

/* One fired stage op. The cancel handle is embedded (per-fire, valid for the
 * job's lifetime); the op receives a pointer to it and MUST NOT retain it
 * after returning. */
typedef struct strim_op_job {
    strim_controller *c;
    strim_stage_name  stage;
    strim_stage_op    op;
    void             *op_ctx;
    int64_t           timeout_ms;
    strim_stage_op_cancel cancel;
} strim_op_job;

static void run_stage_op(void *arg) {
    strim_op_job *job = arg;
    strim_controller *c = job->c;

    int err = job->op(job->op_ctx, job->timeout_ms, &job->cancel);
    if (err != 0 && !strim_stage_op_superseded(&job->cancel)) {
        /* Match Go controller.go:308-311: a failed op clears InFlight so the
         * next reconcile retries. The clear runs through the action queue
         * (single-writer invariant); it is dropped if the queue is already
         * closed (shutdown in progress — Teardown owns the stage now).
         * The clear is stamped with THIS fire's generation and only wipes
         * InFlight while it is still the live generation: a SUPERSEDED op's
         * clear must NOT fire — a newer retry owns the stage and its InFlight
         * marker, and a stale clear would let reconcile fire a third op
         * concurrently. */
        strim_action *act = malloc(sizeof *act);
        if (act != NULL) {
            *act = (strim_action){
                .kind = ACTION_CLEAR_INFLIGHT,
                .clear_stage = job->stage,
                .clear_generation = job->cancel.generation,
                .self_allocated = true,
            };
            pthread_mutex_lock(&c->q_lock);
            if (c->q_closed) {
                pthread_mutex_unlock(&c->q_lock);
                free(act);
            } else {
                enqueue_locked(c, act);
                pthread_mutex_unlock(&c->q_lock);
            }
        }
    }

    wg_done(&c->ops_wg);
    free(job);
}

/* -------------------------------------------------------------------------
 * Enum <-> wire-string helpers (controller.h contract; exact JSON spellings)
 * ------------------------------------------------------------------------- */

static const char *const k_path_status_strs[STRIM_PATH_STATUS_COUNT] = {
    [STRIM_PATH_UNKNOWN]   = STRIM_PATH_UNKNOWN_STR,
    [STRIM_PATH_READY]     = STRIM_PATH_READY_STR,
    [STRIM_PATH_NOT_READY] = STRIM_PATH_NOT_READY_STR,
};

static const char *const k_stage_state_strs[STRIM_STAGE_STATE_COUNT] = {
    [STRIM_STAGE_STOPPED]   = STRIM_STAGE_STOPPED_STR,
    [STRIM_STAGE_RUNNING]   = STRIM_STAGE_RUNNING_STR,
    [STRIM_STAGE_NO_TARGET] = "", /* Go NoTarget; never on the wire */
};

static const char *const k_path_name_strs[STRIM_PATH_NAME_COUNT] = {
    [STRIM_PATH_INGRESS0]   = STRIM_PATH_INGRESS0_STR,
    [STRIM_PATH_NORMALIZED] = STRIM_PATH_NORMALIZED_STR,
};

static const char *const k_stage_name_strs[STRIM_STAGE_NAME_COUNT] = {
    [STRIM_STAGE_MEDIA_MTX]           = STRIM_STAGE_MEDIA_MTX_STR,
    [STRIM_STAGE_NORMALIZE]           = STRIM_STAGE_NORMALIZE_STR,
    [STRIM_STAGE_SCALE_AND_EGRESS]    = STRIM_STAGE_SCALE_AND_EGRESS_STR,
    [STRIM_STAGE_SINGLE_STAGE_EGRESS] = STRIM_STAGE_SINGLE_STAGE_EGRESS_STR,
};

static const char *const k_control_component_strs[STRIM_COMPONENT_COUNT] = {
    [STRIM_COMPONENT_EGRESS] = STRIM_COMPONENT_EGRESS_STR,
};

static const char *const k_control_action_strs[STRIM_ACTION_COUNT] = {
    [STRIM_ACTION_START] = STRIM_ACTION_START_STR,
    [STRIM_ACTION_STOP]  = STRIM_ACTION_STOP_STR,
};

/* Generic lookup over the tables above. Returns the enum index, or -1 for an
 * unknown (or NULL) string. */
static int enum_from_string(const char *s, size_t count,
                            const char *const *strs) {
    if (s == NULL || strs == NULL) {
        return -1;
    }
    for (size_t i = 0; i < count; i++) {
        if (strs[i] != NULL && strcmp(s, strs[i]) == 0) {
            return (int)i;
        }
    }
    return -1;
}

/* Generic string lookup. Returns NULL for an out-of-range value. */
static const char *enum_to_string(int v, size_t count,
                                  const char *const *strs) {
    if ((unsigned)v >= (unsigned)count) {
        return NULL;
    }
    return strs[v];
}

int strim_path_status_from_string(const char *s, strim_path_status *out) {
    int v = enum_from_string(s, STRIM_PATH_STATUS_COUNT, k_path_status_strs);
    if (v < 0 || out == NULL) {
        return -1;
    }
    *out = (strim_path_status)v;
    return 0;
}

const char *strim_path_status_to_string(strim_path_status v) {
    return enum_to_string((int)v, STRIM_PATH_STATUS_COUNT, k_path_status_strs);
}

int strim_stage_state_from_string(const char *s, strim_stage_state *out) {
    int v = enum_from_string(s, STRIM_STAGE_STATE_COUNT, k_stage_state_strs);
    if (v < 0 || out == NULL) {
        return -1;
    }
    *out = (strim_stage_state)v;
    return 0;
}

const char *strim_stage_state_to_string(strim_stage_state v) {
    return enum_to_string((int)v, STRIM_STAGE_STATE_COUNT, k_stage_state_strs);
}

int strim_path_name_from_string(const char *s, strim_path_name *out) {
    int v = enum_from_string(s, STRIM_PATH_NAME_COUNT, k_path_name_strs);
    if (v < 0 || out == NULL) {
        return -1;
    }
    *out = (strim_path_name)v;
    return 0;
}

const char *strim_path_name_to_string(strim_path_name v) {
    return enum_to_string((int)v, STRIM_PATH_NAME_COUNT, k_path_name_strs);
}

int strim_stage_name_from_string(const char *s, strim_stage_name *out) {
    int v = enum_from_string(s, STRIM_STAGE_NAME_COUNT, k_stage_name_strs);
    if (v < 0 || out == NULL) {
        return -1;
    }
    *out = (strim_stage_name)v;
    return 0;
}

const char *strim_stage_name_to_string(strim_stage_name v) {
    return enum_to_string((int)v, STRIM_STAGE_NAME_COUNT, k_stage_name_strs);
}

int strim_control_component_from_string(const char *s,
                                        strim_control_component *out) {
    int v = enum_from_string(s, STRIM_COMPONENT_COUNT,
                             k_control_component_strs);
    if (v < 0 || out == NULL) {
        return -1;
    }
    *out = (strim_control_component)v;
    return 0;
}

const char *strim_control_component_to_string(strim_control_component v) {
    return enum_to_string((int)v, STRIM_COMPONENT_COUNT,
                          k_control_component_strs);
}

int strim_control_action_from_string(const char *s,
                                     strim_control_action *out) {
    int v = enum_from_string(s, STRIM_ACTION_COUNT, k_control_action_strs);
    if (v < 0 || out == NULL) {
        return -1;
    }
    *out = (strim_control_action)v;
    return 0;
}

const char *strim_control_action_to_string(strim_control_action v) {
    return enum_to_string((int)v, STRIM_ACTION_COUNT, k_control_action_strs);
}

/* -------------------------------------------------------------------------
 * Construction
 * ------------------------------------------------------------------------- */

/* Validate one route table, copy it into the controller, and enforce the
 * construction-time checks Go NewController makes (controller.go:138-158):
 * every route target must name a configured stage that has an op for the
 * target state. Route keys must be unique (a C array would otherwise be
 * ambiguous where the Go map silently dedups — reject it loud instead). */
static int validate_and_copy_routes(strim_controller *c,
                                    const strim_route *src, size_t n,
                                    int kind_expected, strim_route **out) {
    if (n > 0 && src == NULL) {
        return STRIM_CTRL_ERR_BADARG;
    }

    strim_route *copy = NULL;
    if (n > 0) {
        copy = malloc(n * sizeof *copy);
        if (copy == NULL) {
            return STRIM_CTRL_ERR_NOMEM;
        }
        memcpy(copy, src, n * sizeof *copy);
    }

    for (size_t i = 0; i < n; i++) {
        strim_route *r = &copy[i];

        if (r->kind != kind_expected) {
            free(copy);
            return STRIM_CTRL_ERR_BADARG;
        }
        if (kind_expected == STRIM_ROUTE_PATH_EVENT) {
            if ((unsigned)r->path >= (unsigned)STRIM_PATH_NAME_COUNT) {
                free(copy);
                return STRIM_CTRL_ERR_BADARG; /* Go: unknown path */
            }
            if (!valid_path_status(r->path_status)) {
                free(copy);
                return STRIM_CTRL_ERR_BADARG;
            }
        } else {
            if ((unsigned)r->component >= (unsigned)STRIM_COMPONENT_COUNT) {
                free(copy);
                return STRIM_CTRL_ERR_BADARG;
            }
            if ((unsigned)r->action >= (unsigned)STRIM_ACTION_COUNT) {
                free(copy);
                return STRIM_CTRL_ERR_BADARG;
            }
        }

        if ((unsigned)r->target_stage >= (unsigned)STRIM_STAGE_NAME_COUNT) {
            free(copy);
            return STRIM_CTRL_ERR_BADARG; /* Go: route targets unknown stage */
        }
        if (!valid_stage_state(r->target_state)) {
            free(copy);
            return STRIM_CTRL_ERR_BADARG;
        }
        strim_stage_op op = stage_op_for(&c->stages[r->target_stage],
                                         r->target_state);
        if (op == NULL) {
            free(copy);
            return STRIM_CTRL_ERR_BADARG; /* Go: no op for stage/state */
        }

        for (size_t j = 0; j < i; j++) {
            if (route_keys_equal(&copy[j], r, kind_expected)) {
                free(copy);
                return STRIM_CTRL_ERR_BADARG; /* duplicate route key */
            }
        }
    }

    *out = copy;
    return 0;
}

int strim_controller_new(const strim_controller_config *cfg,
                         strim_controller **out) {
    if (cfg == NULL || out == NULL) {
        return STRIM_CTRL_ERR_BADARG;
    }
    if (cfg->inflight_timeout_ms <= 0) {
        return STRIM_CTRL_ERR_BADARG; /* Go: must be > 0 */
    }
    if (cfg->actions_buffer_size == 0) {
        return STRIM_CTRL_ERR_BADARG; /* Go: must be > 0 */
    }
    for (size_t i = 0; i < STRIM_PATH_NAME_COUNT; i++) {
        if (!valid_path_status(cfg->initial_paths[i])) {
            return STRIM_CTRL_ERR_BADARG; /* Go: seeded invalid status */
        }
    }

    strim_controller *c = calloc(1, sizeof *c);
    if (c == NULL) {
        return STRIM_CTRL_ERR_NOMEM;
    }
    c->now_ms = (cfg->now_ms != NULL) ? cfg->now_ms : default_now_ms;
    c->inflight_timeout_ms = cfg->inflight_timeout_ms;
    c->actions_buffer_size = cfg->actions_buffer_size;
    memcpy(c->paths, cfg->initial_paths, sizeof c->paths);

    pthread_mutex_init(&c->q_lock, NULL);
    pthread_cond_init(&c->q_cond, NULL);
    pthread_mutex_init(&c->ops_wg.lock, NULL);
    pthread_cond_init(&c->ops_wg.cond, NULL);
    atomic_init(&c->shutting_down, false);

    int rc = 0;
    for (size_t i = 0; i < STRIM_STAGE_NAME_COUNT; i++) {
        const strim_stage_config *sc = &cfg->stages[i];
        if (sc->name != (strim_stage_name)i) {
            rc = STRIM_CTRL_ERR_BADARG; /* stages[] is indexed by enum */
            goto cleanup;
        }
        if (!valid_stage_state(sc->status.desired) ||
            !valid_stage_state(sc->status.actual)) {
            rc = STRIM_CTRL_ERR_BADARG; /* Go: seeded invalid state */
            goto cleanup;
        }
        c->stages[i].name = sc->name;
        c->stages[i].status = sc->status;
        c->stages[i].start_op = sc->start_op;
        c->stages[i].stop_op = sc->stop_op;
        c->stages[i].op_ctx = sc->op_ctx;
        c->stages[i].in_flight_since = 0; /* never seeded InFlight */
        atomic_init(&c->stages[i].op_generation, 0);
    }

    rc = validate_and_copy_routes(c, cfg->path_routes, cfg->n_path_routes,
                                  STRIM_ROUTE_PATH_EVENT, &c->path_routes);
    if (rc != 0) {
        goto cleanup;
    }
    c->n_path_routes = cfg->n_path_routes;

    rc = validate_and_copy_routes(c, cfg->control_routes, cfg->n_control_routes,
                                  STRIM_ROUTE_CONTROL, &c->control_routes);
    if (rc != 0) {
        goto cleanup;
    }
    c->n_control_routes = cfg->n_control_routes;

    rc = workerpool_init(&c->pool);
    if (rc != 0) {
        goto cleanup; /* workerpool_init self-cleans its own pool on failure */
    }

    *out = c;
    return 0;

cleanup:
    pthread_mutex_destroy(&c->q_lock);
    pthread_cond_destroy(&c->q_cond);
    pthread_mutex_destroy(&c->ops_wg.lock);
    pthread_cond_destroy(&c->ops_wg.cond);
    free(c->path_routes);
    free(c->control_routes);
    free(c);
    return rc;
}

/* -------------------------------------------------------------------------
 * Run / Close / Destroy
 * ------------------------------------------------------------------------- */

static void run_action(strim_controller *c, strim_action *act);

void strim_controller_run(strim_controller *c) {
    if (c == NULL) {
        return;
    }
    for (;;) {
        strim_action *act = NULL;
        pthread_mutex_lock(&c->q_lock);
        while (c->q_head == NULL && !c->q_closed) {
            pthread_cond_wait(&c->q_cond, &c->q_lock);
        }
        if (c->q_head != NULL) {
            act = c->q_head;
            c->q_head = act->next;
            if (c->q_head == NULL) {
                c->q_tail = NULL;
            }
            if (act->kind == ACTION_RECONCILE) {
                c->reconcile_queued = false;
            }
        }
        pthread_mutex_unlock(&c->q_lock);

        if (act == NULL) {
            break; /* closed and drained */
        }
        run_action(c, act);
    }
}

void strim_controller_begin_shutdown(strim_controller *c) {
    if (c == NULL) {
        return;
    }
    /* Shutdown step one: suppress new reconcile fires BEFORE WaitForOps runs.
     * The store happens UNDER q_lock so it serializes against a reconcile
     * fire in its q_lock critical section: either the fire's locked re-check
     * ran first and completed its wg_add (the op is then counted by
     * WaitForOps), or it runs after and skips the fire. Does NOT touch
     * q_closed — Teardown still needs the queue open. Idempotent. */
    pthread_mutex_lock(&c->q_lock);
    atomic_store(&c->shutting_down, true);
    pthread_mutex_unlock(&c->q_lock);
}

void strim_controller_close(strim_controller *c) {
    if (c == NULL) {
        return;
    }
    /* Close the action queue; Run returns. New-fire suppression is the job of
     * begin_shutdown (step one, before WaitForOps); setting shutting_down
     * here again is idempotent belt-and-suspenders for callers that skip
     * begin_shutdown (e.g. the tests / the emergency thread_fail path).
     * Enforced sequence: begin_shutdown -> WaitForOps -> Teardown -> Close
     * (Run returns) -> Destroy. */
    atomic_store(&c->shutting_down, true);
    pthread_mutex_lock(&c->q_lock);
    c->q_closed = true;
    pthread_cond_broadcast(&c->q_cond);
    pthread_mutex_unlock(&c->q_lock);
}

void strim_controller_destroy(strim_controller *c) {
    if (c == NULL) {
        return;
    }
    /* Contract: Run has returned and WaitForOps has been called, so no ops
     * are in flight and the pool threads are idle. */
    workerpool_shutdown(&c->pool);
    pthread_mutex_destroy(&c->q_lock);
    pthread_cond_destroy(&c->q_cond);
    pthread_mutex_destroy(&c->ops_wg.lock);
    pthread_cond_destroy(&c->ops_wg.cond);
    free(c->path_routes);
    free(c->control_routes);
    free(c);
}

/* -------------------------------------------------------------------------
 * Status snapshot + listener dispatch
 * ------------------------------------------------------------------------- */

int strim_controller_handle_status(strim_controller *c,
                                   strim_controller_status *out) {
    if (c == NULL || out == NULL) {
        return STRIM_CTRL_ERR_BADARG;
    }
    /* Clone, matching Go handleStatus (controller.go:322-327): the caller
     * owns a private snapshot. */
    memcpy(out->paths, c->paths, sizeof out->paths);
    for (size_t i = 0; i < STRIM_STAGE_NAME_COUNT; i++) {
        out->stages[i] = c->stages[i].status;
    }
    return 0;
}

static void notify_listeners(strim_controller *c) {
    if (c->n_listeners == 0) {
        return; /* Go controller.go:264 */
    }
    strim_controller_status snapshot;
    strim_controller_handle_status(c, &snapshot);
    for (size_t i = 0; i < c->n_listeners; i++) {
        c->listeners[i].fn(&snapshot, c->listeners[i].userdata);
    }
}

/* -------------------------------------------------------------------------
 * Handlers (run on the queue thread; also callable directly with c owned by
 * the calling thread — the tests and the Teardown path do exactly that)
 * ------------------------------------------------------------------------- */

static int apply_desired_stage_target(strim_controller *c,
                                      const strim_route *target) {
    strim_stage *stage = &c->stages[target->target_stage];

    if (stage->status.desired == target->target_state) {
        return 0; /* Go: already desired, no-op */
    }

    if (target->prerequisite != NULL) {
        int rc = target->prerequisite(c, target->prerequisite_userdata);
        if (rc != 0) {
            /* Go: desired state left untouched, error returned */
            return STRIM_CTRL_ERR_PREREQ;
        }
    }

    stage->status.desired = target->target_state;
    notify_listeners(c);
    return 0;
}

int strim_controller_handle_path_event(strim_controller *c,
                                       const strim_path_event *e) {
    if (c == NULL || e == NULL) {
        return STRIM_CTRL_ERR_BADARG;
    }
    if ((unsigned)e->path >= (unsigned)STRIM_PATH_NAME_COUNT) {
        return STRIM_CTRL_ERR_UNKNOWN; /* Go: invalid path name */
    }
    if (!valid_path_status(e->status)) {
        return STRIM_CTRL_ERR_BADARG; /* Go: invalid path status */
    }

    /* Record intent FIRST — the path status is stored even when no route
     * matches (controller.go:230-231). */
    c->paths[e->path] = e->status;

    /* Exact (path, status) route lookup; first match is the only match
     * (routes are unique at construction). */
    const strim_route *route = find_path_event_route(c, e->path, e->status);
    if (route == NULL) {
        return 0;
    }
    return apply_desired_stage_target(c, route);
}

int strim_controller_handle_control(strim_controller *c,
                                    const strim_control_command *cmd) {
    if (c == NULL || cmd == NULL) {
        return STRIM_CTRL_ERR_BADARG;
    }
    if ((unsigned)cmd->component >= (unsigned)STRIM_COMPONENT_COUNT) {
        return STRIM_CTRL_ERR_UNKNOWN; /* Go: control not implemented */
    }
    if ((unsigned)cmd->action >= (unsigned)STRIM_ACTION_COUNT) {
        return STRIM_CTRL_ERR_UNKNOWN;
    }

    const strim_route *route = find_control_route(c, cmd->component,
                                                  cmd->action);
    if (route == NULL) {
        return STRIM_CTRL_ERR_UNKNOWN; /* Go: control not implemented */
    }
    return apply_desired_stage_target(c, route);
}

int strim_controller_handle_stage_event(strim_controller *c,
                                        const strim_stage_event *e) {
    if (c == NULL || e == NULL) {
        return STRIM_CTRL_ERR_BADARG;
    }
    if ((unsigned)e->stage >= (unsigned)STRIM_STAGE_NAME_COUNT) {
        return STRIM_CTRL_ERR_UNKNOWN; /* Go: invalid stage name */
    }
    if (!valid_stage_state(e->state)) {
        return STRIM_CTRL_ERR_BADARG; /* Go: invalid stage state */
    }

    strim_stage *stage = &c->stages[e->stage];
    bool changed = (stage->status.actual != e->state);
    stage->status.actual = e->state;
    stage->in_flight_since = 0; /* Go: controller.go:245 */
    if (changed) {
        notify_listeners(c);
    }
    return 0;
}

void strim_controller_handle_reconcile(strim_controller *c) {
    if (c == NULL) {
        return;
    }
    /* Shutdown handshake (fast path): once begin_shutdown() has run, no new
     * fires. The authoritative check is repeated under q_lock inside the fire
     * section below — this early return is belt-and-suspenders. */
    if (atomic_load(&c->shutting_down)) {
        return;
    }
    for (size_t i = 0; i < STRIM_STAGE_NAME_COUNT; i++) {
        strim_stage *stage = &c->stages[i];

        /* Converged stages clear InFlight (controller.go:291-292). */
        if (stage->status.desired == stage->status.actual) {
            stage->in_flight_since = 0;
            continue;
        }

        /* planReconcile (controller.go:316-320): fire when not in flight, or
         * when the previous op exceeded inflight_timeout_ms (a timed-out
         * retry; the generation bump below supersedes the older op, whose
         * cancel handle then reports superseded at its next safe point). */
        bool fire = (stage->in_flight_since == 0) ||
                    (c->now_ms() - stage->in_flight_since >=
                     c->inflight_timeout_ms);
        if (!fire) {
            continue; /* in flight and not yet timed out */
        }
        strim_stage_state target = stage->status.desired;

        strim_stage_op op = stage_op_for(stage, target);
        if (op == NULL) {
            continue; /* unreachable after construction validation */
        }

        /* The fire is atomic w.r.t. begin_shutdown: the whole fire runs under
         * q_lock, and we re-check shutting_down AFTER acquiring it. A fire
         * that loses the race to begin_shutdown is skipped; a fire that wins
         * the lock completes its wg_add before begin_shutdown can store the
         * flag, so WaitForOps counts exactly the ops submitted before
         * suppression. This closes the Add-vs-Wait race deterministically.
         * Lock order: q_lock -> {pool->lock, wg->lock} — nothing takes
         * q_lock while holding pool->lock or wg->lock (verified: worker_main
         * releases pool->lock before running a job; run_stage_op takes
         * wg->lock and q_lock sequentially, never nested). */
        pthread_mutex_lock(&c->q_lock);
        if (atomic_load(&c->shutting_down)) {
            pthread_mutex_unlock(&c->q_lock);
            continue; /* begin_shutdown won the race: suppress this fire */
        }

        /* Allocate the op job BEFORE mutating in_flight_since/op_generation
         * so an OOM cannot wedge the stage (no op, no wg accounting): on
         * failure we leave the stage untouched and the next reconcile fires
         * again. */
        strim_op_job *job = malloc(sizeof *job);
        if (job == NULL) {
            fprintf(stderr,
                    "strim_controller: reconcile op allocation failed\n");
            pthread_mutex_unlock(&c->q_lock);
            continue;
        }

        int64_t now = c->now_ms();
        stage->in_flight_since = now;
        stage->op_generation++; /* the new fire supersedes any older one */
        *job = (strim_op_job){
            .c = c,
            .stage = (strim_stage_name)i,
            .op = op,
            .op_ctx = stage->op_ctx,
            .timeout_ms = c->inflight_timeout_ms,
            .cancel = {
                .generation = stage->op_generation,
                .deadline_ms = now + c->inflight_timeout_ms,
                .current_generation = &stage->op_generation,
                .now_ms = c->now_ms,
            },
        };

        wg_add(&c->ops_wg, 1);
        if (workerpool_submit(&c->pool, run_stage_op, job) != 0) {
            /* No op was launched: undo the wg add and the stage mutation so
             * WaitForOps never hangs on a phantom in-flight op. Rare OOM /
             * pool-shutdown case; the next reconcile retries. */
            wg_done(&c->ops_wg);
            stage->in_flight_since = 0;
            /* op_generation is _Atomic: this decrement is an atomic RMW. The
             * transient false-supersede window it could cause for another
             * in-flight op is acceptable on this rare OOM path — that op's
             * next safe point just aborts early and is retried. */
            stage->op_generation--;
            free(job);
            pthread_mutex_unlock(&c->q_lock);
            continue;
        }
        pthread_mutex_unlock(&c->q_lock);
    }
}

/* -------------------------------------------------------------------------
 * Listeners (internal; exposed only through the submit surface)
 * ------------------------------------------------------------------------- */

static int handle_add_listener(strim_controller *c,
                               strim_controller_listener listener,
                               void *userdata) {
    if (listener == NULL) {
        return STRIM_CTRL_ERR_BADARG; /* Go: listener must not be nil */
    }
    if (c->n_listeners >= STRIM_CTRL_MAX_LISTENERS) {
        return STRIM_CTRL_ERR_NOMEM;
    }
    c->listeners[c->n_listeners].fn = listener;
    c->listeners[c->n_listeners].userdata = userdata;
    c->n_listeners++;

    /* Immediate snapshot for the new listener (Go controller.go:253). */
    strim_controller_status snapshot;
    strim_controller_handle_status(c, &snapshot);
    listener(&snapshot, userdata);
    return 0;
}

static int handle_remove_listener(strim_controller *c,
                                  strim_controller_listener listener,
                                  void *userdata) {
    for (size_t i = 0; i < c->n_listeners; i++) {
        if (c->listeners[i].fn == listener &&
            c->listeners[i].userdata == userdata) {
            memmove(&c->listeners[i], &c->listeners[i + 1],
                    (c->n_listeners - i - 1) * sizeof c->listeners[0]);
            c->n_listeners--;
            return 0;
        }
    }
    return STRIM_CTRL_ERR_UNKNOWN; /* Go: listener not registered */
}

/* -------------------------------------------------------------------------
 * Teardown (controller.go:331-348): queued action that synchronously stops
 * every running stage, then marks desired/actual == Stopped and notifies.
 * ------------------------------------------------------------------------- */

static void teardown_inner(strim_controller *c) {
    for (size_t i = 0; i < STRIM_STAGE_NAME_COUNT; i++) {
        strim_stage *stage = &c->stages[i];
        if (stage->status.actual != STRIM_STAGE_RUNNING ||
            stage->stop_op == NULL) {
            continue;
        }
        /* Bump the fire generation first so any lingering reconcile-fired op
         * for this stage is superseded at its next safe point before we stop
         * it synchronously. */
        stage->op_generation++;
        /* Teardown runs with NO cancellation (Go: context.WithoutCancel
         * survives the signal); the ops fall back to their plain inflight
         * timeout and are never superseded. */
        int err = stage->stop_op(stage->op_ctx, c->inflight_timeout_ms, NULL);
        (void)err; /* Go logs and continues; the stage is marked stopped
                    * either way so the controller does not wedge. */
        stage->status.desired = STRIM_STAGE_STOPPED;
        stage->status.actual = STRIM_STAGE_STOPPED;
        stage->in_flight_since = 0;
    }
    notify_listeners(c);
}

/* -------------------------------------------------------------------------
 * Action dispatch
 * ------------------------------------------------------------------------- */

static void run_action(strim_controller *c, strim_action *act) {
    int result = 0;
    switch (act->kind) {
        case ACTION_PATH_EVENT:
            result = strim_controller_handle_path_event(c, &act->path_event);
            break;
        case ACTION_CONTROL:
            result = strim_controller_handle_control(c, &act->control);
            break;
        case ACTION_STAGE_EVENT:
            result = strim_controller_handle_stage_event(c, &act->stage_event);
            break;
        case ACTION_STATUS:
            result = strim_controller_handle_status(c, act->status_out);
            break;
        case ACTION_ADD_LISTENER:
            result = handle_add_listener(c, act->listener,
                                         act->listener_userdata);
            break;
        case ACTION_REMOVE_LISTENER:
            result = handle_remove_listener(c, act->listener,
                                            act->listener_userdata);
            break;
        case ACTION_RECONCILE:
            strim_controller_handle_reconcile(c);
            break;
        case ACTION_CLEAR_INFLIGHT: {
            strim_stage *stage = &c->stages[act->clear_stage];
            /* Generation-stamped clear: only the clear belonging to the
             * CURRENT fire may wipe in_flight_since. A stale clear (the queue
             * thread bumped op_generation and fired a retry after the failing
             * op enqueued it) must not wipe the new fire's marker, or a third
             * op could fire and two ops would run concurrently. */
            if (atomic_load(&stage->op_generation) == act->clear_generation) {
                stage->in_flight_since = 0;
            }
            break;
        }
        case ACTION_TEARDOWN:
            teardown_inner(c);
            break;
    }

    bool self_allocated = act->self_allocated;
    pthread_mutex_lock(&c->q_lock);
    if (!self_allocated) {
        act->reply_result = result;
        act->reply_done = true;
        pthread_cond_broadcast(&c->q_cond);
    }
    pthread_mutex_unlock(&c->q_lock);
    if (self_allocated) {
        free(act);
    }
}

/* -------------------------------------------------------------------------
 * Submit surface (blocking enqueue + wait, except RequestReconcile)
 * ------------------------------------------------------------------------- */

int strim_controller_submit_path_event(strim_controller *c,
                                       const strim_path_event *e) {
    if (c == NULL || e == NULL) {
        return STRIM_CTRL_ERR_BADARG;
    }
    strim_action act = {.kind = ACTION_PATH_EVENT, .path_event = *e};
    return queue_submit(c, &act);
}

int strim_controller_submit_control(strim_controller *c,
                                    const strim_control_command *cmd) {
    if (c == NULL || cmd == NULL) {
        return STRIM_CTRL_ERR_BADARG;
    }
    strim_action act = {.kind = ACTION_CONTROL, .control = *cmd};
    return queue_submit(c, &act);
}

int strim_controller_submit_stage_event(strim_controller *c,
                                        const strim_stage_event *e) {
    if (c == NULL || e == NULL) {
        return STRIM_CTRL_ERR_BADARG;
    }
    strim_action act = {.kind = ACTION_STAGE_EVENT, .stage_event = *e};
    return queue_submit(c, &act);
}

int strim_controller_submit_status(strim_controller *c,
                                   strim_controller_status *out) {
    if (c == NULL || out == NULL) {
        return STRIM_CTRL_ERR_BADARG;
    }
    strim_action act = {.kind = ACTION_STATUS, .status_out = out};
    return queue_submit(c, &act);
}

int strim_controller_submit_add_listener(strim_controller *c,
                                         strim_controller_listener listener,
                                         void *userdata) {
    if (c == NULL || listener == NULL) {
        return STRIM_CTRL_ERR_BADARG;
    }
    strim_action act = {
        .kind = ACTION_ADD_LISTENER,
        .listener = listener,
        .listener_userdata = userdata,
    };
    return queue_submit(c, &act);
}

int strim_controller_submit_remove_listener(strim_controller *c,
                                            strim_controller_listener listener,
                                            void *userdata) {
    if (c == NULL || listener == NULL) {
        return STRIM_CTRL_ERR_BADARG;
    }
    strim_action act = {
        .kind = ACTION_REMOVE_LISTENER,
        .listener = listener,
        .listener_userdata = userdata,
    };
    return queue_submit(c, &act);
}

void strim_controller_request_reconcile(strim_controller *c) {
    if (c == NULL) {
        return;
    }
    /* Non-blocking with coalescing: at most one reconcile pass is queued.
     * Dropping a request is safe — reconciles are idempotent and the
     * ticker/event handler re-requests on the next beat. */
    strim_action *act = malloc(sizeof *act);
    if (act == NULL) {
        return; /* drop this request (a hint, not a command) */
    }
    *act = (strim_action){
        .kind = ACTION_RECONCILE,
        .self_allocated = true,
    };

    pthread_mutex_lock(&c->q_lock);
    if (c->q_closed || c->reconcile_queued) {
        pthread_mutex_unlock(&c->q_lock);
        free(act);
        return;
    }
    c->reconcile_queued = true;
    enqueue_locked(c, act);
    pthread_mutex_unlock(&c->q_lock);
}

void strim_controller_wait_for_ops(strim_controller *c) {
    if (c == NULL) {
        return;
    }
    wg_wait(&c->ops_wg);
}

int strim_controller_teardown(strim_controller *c) {
    if (c == NULL) {
        return STRIM_CTRL_ERR_BADARG;
    }
    strim_action act = {.kind = ACTION_TEARDOWN};
    return queue_submit(c, &act);
}
