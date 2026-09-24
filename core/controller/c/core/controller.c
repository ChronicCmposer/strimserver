/*
 * controller.c — the strimserver controller state machine (C port).
 *
 * Wave 1 core lane. Implements the controller.h contract 1:1 from the Go
 * oracle (core/controller/controller.go + names.go):
 *
 *   - The controller is SINGLE-THREADED: all state mutation happens on the
 *     action-queue thread (Go: `for act := range c.actions { act(c) }`).
 *     Every submit function enqueues an action and blocks until the queue
 *     thread has run it (Go's `submit`, controller.go:182-186);
 *     request_reconcile enqueues WITHOUT blocking and coalesces (at most one
 *     pending reconcile pass, latest-wins — a safe optimization: reconciles
 *     are idempotent).
 *
 *   - Reconcile semantics (the exactly-once contract): a stage whose
 *     Desired != Actual is converged by firing its op for the desired state.
 *     The op is fired only when the stage is NOT in flight, or when the
 *     previous op exceeded inflight_timeout_ms (a timed-out retry). The op
 *     runs on the worker pool with the inflight timeout; a failed op clears
 *     InFlight through the queue so the next reconcile retries
 *     (controller.go:287-314). The timed-out retry supersedes the previous
 *     op through a per-stage generation token (strim_stage_op_cancel): the
 *     old op aborts at its next safe point, and its RPCs are bounded by the
 *     remaining deadline, so two ops for one stage never run concurrently
 *     (the Go oracle cancels the old op's context at the same point).
 *
 *   - Prerequisite gating: a route's prerequisite is checked BEFORE the
 *     desired state is committed (applyDesiredStageTarget,
 *     controller.go:269-285); a failing prerequisite leaves the stage's
 *     desired state untouched and the submit returns STRIM_CTRL_ERR_PREREQ.
 *
 *   - Teardown (controller.go:331-348) runs as a queued action and
 *     synchronously stops every stage whose actual state is Running, then
 *     marks desired/actual == Stopped and notifies.
 *
 * Wire strings are fixed (controller.h STRIM_*_STR); the HTTP/JSON lanes must
 * go through the from_string/to_string helpers and never invent spellings.
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
 * The HTTP lane caps ws clients at STRIM_HTTP_MAX_WS_CLIENTS (4), well below
 * the listener cap. The worker pool is sized for the four stages: the Go
 * oracle launches one goroutine per op, and at most one op per stage can be
 * in flight. A timed-out retry supersedes the previous op through a
 * per-stage generation token (strim_stage_op_cancel), and every op bounds
 * its RPCs by the remaining deadline, so a hung op cannot outlive the
 * inflight timeout and two ops never run destructively on the same stage. */
#define STRIM_CTRL_MAX_LISTENERS 16
#define STRIM_CTRL_WORKERS       4

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

    /* blocking-reply handshake (all ACTION_* submits) */
    int  reply_result;
    bool reply_done;

    /* non-blocking actions (reconcile, clear-inflight) are freed by the
     * queue thread after processing; blocking submits own their action
     * (often stack-allocated) and free it after reply_done. */
    bool owns_self;
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

    strim_waitgroup  ops_wg;
    strim_workerpool pool;
};

/* -------------------------------------------------------------------------
 * Small helpers
 * ------------------------------------------------------------------------- */

static bool valid_path_status(strim_path_status s) {
    return s >= STRIM_PATH_UNKNOWN && s <= STRIM_PATH_NOT_READY;
}

static bool valid_stage_state(strim_stage_state s) {
    return s == STRIM_STAGE_RUNNING || s == STRIM_STAGE_STOPPED;
}

static int64_t default_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
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
    if (cancel == NULL || cancel->current_generation == NULL) {
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

static void workerpool_submit(strim_workerpool *pool, void (*fn)(void *arg),
                              void *arg) {
    strim_worker_job *job = malloc(sizeof *job);
    if (job == NULL) {
        fprintf(stderr, "strim_controller: worker pool allocation failed\n");
        abort();
    }
    job->fn = fn;
    job->arg = arg;
    job->next = NULL;
    pthread_mutex_lock(&pool->lock);
    if (pool->tail == NULL) {
        pool->head = pool->tail = job;
    } else {
        pool->tail->next = job;
        pool->tail = job;
    }
    pthread_cond_signal(&pool->cond);
    pthread_mutex_unlock(&pool->lock);
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
         * A SUPERSEDED op must NOT clear: a newer retry owns the stage and
         * its InFlight marker, and clearing it would let reconcile fire a
         * third op concurrently. */
        strim_action *act = malloc(sizeof *act);
        if (act != NULL) {
            memset(act, 0, sizeof *act);
            act->kind = ACTION_CLEAR_INFLIGHT;
            act->clear_stage = job->stage;
            act->owns_self = true;
            pthread_mutex_lock(&c->q_lock);
            if (c->q_closed) {
                pthread_mutex_unlock(&c->q_lock);
                free(act);
            } else {
                act->next = NULL;
                if (c->q_tail == NULL) {
                    c->q_head = c->q_tail = act;
                } else {
                    c->q_tail->next = act;
                    c->q_tail = act;
                }
                pthread_cond_signal(&c->q_cond);
                pthread_mutex_unlock(&c->q_lock);
            }
        }
    }

    wg_done(&c->ops_wg);
    free(job);
}

/* -------------------------------------------------------------------------
 * Queue helpers
 * ------------------------------------------------------------------------- */

/* Enqueue + wait for the queue thread to run act (Go `submit`). Returns the
 * handler's result, or STRIM_CTRL_ERR_CLOSED when the queue is closed. The
 * caller owns act (often stack-allocated); it must stay alive until
 * reply_done. Must not be called from the queue thread itself (Go would
 * deadlock the same way). */
static int queue_submit(strim_controller *c, strim_action *act) {
    act->reply_result = 0;
    act->reply_done = false;
    act->owns_self = false;

    pthread_mutex_lock(&c->q_lock);
    if (c->q_closed) {
        pthread_mutex_unlock(&c->q_lock);
        return STRIM_CTRL_ERR_CLOSED;
    }
    act->next = NULL;
    if (c->q_tail == NULL) {
        c->q_head = c->q_tail = act;
    } else {
        c->q_tail->next = act;
        c->q_tail = act;
    }
    pthread_cond_signal(&c->q_cond);
    while (!act->reply_done) {
        pthread_cond_wait(&c->q_cond, &c->q_lock);
    }
    int result = act->reply_result;
    pthread_mutex_unlock(&c->q_lock);
    return result;
}

/* -------------------------------------------------------------------------
 * Enum <-> wire-string helpers (controller.h contract; exact JSON spellings)
 * ------------------------------------------------------------------------- */

int strim_path_status_from_string(const char *s, strim_path_status *out) {
    if (s == NULL || out == NULL) {
        return -1;
    }
    if (strcmp(s, STRIM_PATH_UNKNOWN_STR) == 0) {
        *out = STRIM_PATH_UNKNOWN;
        return 0;
    }
    if (strcmp(s, STRIM_PATH_READY_STR) == 0) {
        *out = STRIM_PATH_READY;
        return 0;
    }
    if (strcmp(s, STRIM_PATH_NOT_READY_STR) == 0) {
        *out = STRIM_PATH_NOT_READY;
        return 0;
    }
    return -1;
}

const char *strim_path_status_to_string(strim_path_status v) {
    switch (v) {
        case STRIM_PATH_UNKNOWN:   return STRIM_PATH_UNKNOWN_STR;
        case STRIM_PATH_READY:     return STRIM_PATH_READY_STR;
        case STRIM_PATH_NOT_READY: return STRIM_PATH_NOT_READY_STR;
        default:                   return NULL;
    }
}

int strim_stage_state_from_string(const char *s, strim_stage_state *out) {
    if (s == NULL || out == NULL) {
        return -1;
    }
    if (strcmp(s, STRIM_STAGE_STOPPED_STR) == 0) {
        *out = STRIM_STAGE_STOPPED;
        return 0;
    }
    if (strcmp(s, STRIM_STAGE_RUNNING_STR) == 0) {
        *out = STRIM_STAGE_RUNNING;
        return 0;
    }
    if (s[0] == '\0') {
        /* NoTarget ("") is a valid enum value but never sent on the wire;
         * accepting it keeps to_string/from_string a clean round trip. */
        *out = STRIM_STAGE_NO_TARGET;
        return 0;
    }
    return -1;
}

const char *strim_stage_state_to_string(strim_stage_state v) {
    switch (v) {
        case STRIM_STAGE_STOPPED:  return STRIM_STAGE_STOPPED_STR;
        case STRIM_STAGE_RUNNING:  return STRIM_STAGE_RUNNING_STR;
        case STRIM_STAGE_NO_TARGET: return ""; /* Go NoTarget; never on wire */
        default:                   return NULL;
    }
}

int strim_path_name_from_string(const char *s, strim_path_name *out) {
    if (s == NULL || out == NULL) {
        return -1;
    }
    if (strcmp(s, STRIM_PATH_INGRESS0_STR) == 0) {
        *out = STRIM_PATH_INGRESS0;
        return 0;
    }
    if (strcmp(s, STRIM_PATH_NORMALIZED_STR) == 0) {
        *out = STRIM_PATH_NORMALIZED;
        return 0;
    }
    return -1;
}

const char *strim_path_name_to_string(strim_path_name v) {
    switch (v) {
        case STRIM_PATH_INGRESS0:   return STRIM_PATH_INGRESS0_STR;
        case STRIM_PATH_NORMALIZED: return STRIM_PATH_NORMALIZED_STR;
        default:                    return NULL;
    }
}

int strim_stage_name_from_string(const char *s, strim_stage_name *out) {
    if (s == NULL || out == NULL) {
        return -1;
    }
    if (strcmp(s, STRIM_STAGE_MEDIA_MTX_STR) == 0) {
        *out = STRIM_STAGE_MEDIA_MTX;
        return 0;
    }
    if (strcmp(s, STRIM_STAGE_NORMALIZE_STR) == 0) {
        *out = STRIM_STAGE_NORMALIZE;
        return 0;
    }
    if (strcmp(s, STRIM_STAGE_SCALE_AND_EGRESS_STR) == 0) {
        *out = STRIM_STAGE_SCALE_AND_EGRESS;
        return 0;
    }
    if (strcmp(s, STRIM_STAGE_SINGLE_STAGE_EGRESS_STR) == 0) {
        *out = STRIM_STAGE_SINGLE_STAGE_EGRESS;
        return 0;
    }
    return -1;
}

const char *strim_stage_name_to_string(strim_stage_name v) {
    switch (v) {
        case STRIM_STAGE_MEDIA_MTX:           return STRIM_STAGE_MEDIA_MTX_STR;
        case STRIM_STAGE_NORMALIZE:           return STRIM_STAGE_NORMALIZE_STR;
        case STRIM_STAGE_SCALE_AND_EGRESS:    return STRIM_STAGE_SCALE_AND_EGRESS_STR;
        case STRIM_STAGE_SINGLE_STAGE_EGRESS: return STRIM_STAGE_SINGLE_STAGE_EGRESS_STR;
        default:                              return NULL;
    }
}

int strim_control_component_from_string(const char *s, strim_control_component *out) {
    if (s == NULL || out == NULL) {
        return -1;
    }
    if (strcmp(s, STRIM_COMPONENT_EGRESS_STR) == 0) {
        *out = STRIM_COMPONENT_EGRESS;
        return 0;
    }
    return -1;
}

const char *strim_control_component_to_string(strim_control_component v) {
    switch (v) {
        case STRIM_COMPONENT_EGRESS: return STRIM_COMPONENT_EGRESS_STR;
        default:                     return NULL;
    }
}

int strim_control_action_from_string(const char *s, strim_control_action *out) {
    if (s == NULL || out == NULL) {
        return -1;
    }
    if (strcmp(s, STRIM_ACTION_START_STR) == 0) {
        *out = STRIM_ACTION_START;
        return 0;
    }
    if (strcmp(s, STRIM_ACTION_STOP_STR) == 0) {
        *out = STRIM_ACTION_STOP;
        return 0;
    }
    return -1;
}

const char *strim_control_action_to_string(strim_control_action v) {
    switch (v) {
        case STRIM_ACTION_START: return STRIM_ACTION_START_STR;
        case STRIM_ACTION_STOP:  return STRIM_ACTION_STOP_STR;
        default:                 return NULL;
    }
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
            goto badarg;
        }
        if (kind_expected == STRIM_ROUTE_PATH_EVENT) {
            if (r->path < 0 || r->path >= STRIM_PATH_NAME_COUNT) {
                goto badarg; /* Go: route references unknown path */
            }
            if (!valid_path_status(r->path_status)) {
                goto badarg;
            }
        } else {
            if (r->component < 0 || r->component >= STRIM_COMPONENT_COUNT) {
                goto badarg;
            }
            if (r->action < 0 || r->action >= STRIM_ACTION_COUNT) {
                goto badarg;
            }
        }

        if (r->target_stage < 0 || r->target_stage >= STRIM_STAGE_NAME_COUNT) {
            goto badarg; /* Go: route targets unknown stage */
        }
        if (!valid_stage_state(r->target_state)) {
            goto badarg;
        }
        strim_stage_op op = (r->target_state == STRIM_STAGE_RUNNING)
                                ? c->stages[r->target_stage].start_op
                                : c->stages[r->target_stage].stop_op;
        if (op == NULL) {
            goto badarg; /* Go: no op for stage/state */
        }

        for (size_t j = 0; j < i; j++) {
            bool same = (kind_expected == STRIM_ROUTE_PATH_EVENT)
                            ? (copy[j].path == r->path &&
                               copy[j].path_status == r->path_status)
                            : (copy[j].component == r->component &&
                               copy[j].action == r->action);
            if (same) {
                goto badarg; /* duplicate route key */
            }
        }
        continue;

badarg:
        free(copy);
        return STRIM_CTRL_ERR_BADARG;
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

    for (size_t i = 0; i < STRIM_STAGE_NAME_COUNT; i++) {
        const strim_stage_config *sc = &cfg->stages[i];
        if (sc->name != (strim_stage_name)i) {
            free(c);
            return STRIM_CTRL_ERR_BADARG; /* stages[] is indexed by enum */
        }
        if (!valid_stage_state(sc->status.desired) ||
            !valid_stage_state(sc->status.actual)) {
            free(c);
            return STRIM_CTRL_ERR_BADARG; /* Go: seeded invalid state */
        }
        c->stages[i].name = sc->name;
        c->stages[i].status = sc->status;
        c->stages[i].start_op = sc->start_op;
        c->stages[i].stop_op = sc->stop_op;
        c->stages[i].op_ctx = sc->op_ctx;
        c->stages[i].in_flight_since = 0; /* never seeded InFlight */
    }

    int rc = validate_and_copy_routes(c, cfg->path_routes,
                                      cfg->n_path_routes,
                                      STRIM_ROUTE_PATH_EVENT,
                                      &c->path_routes);
    if (rc != 0) {
        free(c);
        return rc;
    }
    c->n_path_routes = cfg->n_path_routes;

    rc = validate_and_copy_routes(c, cfg->control_routes,
                                  cfg->n_control_routes,
                                  STRIM_ROUTE_CONTROL,
                                  &c->control_routes);
    if (rc != 0) {
        free(c->path_routes);
        free(c);
        return rc;
    }
    c->n_control_routes = cfg->n_control_routes;

    pthread_mutex_init(&c->q_lock, NULL);
    pthread_cond_init(&c->q_cond, NULL);
    pthread_mutex_init(&c->ops_wg.lock, NULL);
    pthread_cond_init(&c->ops_wg.cond, NULL);
    c->ops_wg.count = 0;

    rc = workerpool_init(&c->pool);
    if (rc != 0) {
        pthread_mutex_destroy(&c->q_lock);
        pthread_cond_destroy(&c->q_cond);
        pthread_mutex_destroy(&c->ops_wg.lock);
        pthread_cond_destroy(&c->ops_wg.cond);
        free(c->path_routes);
        free(c->control_routes);
        free(c);
        return rc;
    }

    *out = c;
    return 0;
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

void strim_controller_close(strim_controller *c) {
    if (c == NULL) {
        return;
    }
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
    if (e->path < 0 || e->path >= STRIM_PATH_NAME_COUNT) {
        return STRIM_CTRL_ERR_UNKNOWN; /* Go: invalid path name */
    }
    if (!valid_path_status(e->status)) {
        return STRIM_CTRL_ERR_BADARG; /* Go: invalid path status */
    }

    /* Record intent FIRST — the path status is stored even when no route
     * matches (controller.go:230-231). */
    c->paths[e->path] = e->status;

    /* Exact (path, status) route lookup. Routes are unique at construction,
     * so the last match equals the only match. */
    const strim_route *route = NULL;
    for (size_t i = 0; i < c->n_path_routes; i++) {
        const strim_route *r = &c->path_routes[i];
        if (r->path == e->path && r->path_status == e->status) {
            route = r;
        }
    }
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
    if (cmd->component < 0 || cmd->component >= STRIM_COMPONENT_COUNT) {
        return STRIM_CTRL_ERR_UNKNOWN; /* Go: control not implemented */
    }
    if (cmd->action < 0 || cmd->action >= STRIM_ACTION_COUNT) {
        return STRIM_CTRL_ERR_UNKNOWN;
    }

    const strim_route *route = NULL;
    for (size_t i = 0; i < c->n_control_routes; i++) {
        const strim_route *r = &c->control_routes[i];
        if (r->component == cmd->component && r->action == cmd->action) {
            route = r;
        }
    }
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
    if (e->stage < 0 || e->stage >= STRIM_STAGE_NAME_COUNT) {
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
    for (size_t i = 0; i < STRIM_STAGE_NAME_COUNT; i++) {
        strim_stage *stage = &c->stages[i];

        /* Converged stages clear InFlight (controller.go:291-292). */
        if (stage->status.desired == stage->status.actual) {
            stage->in_flight_since = 0;
            continue;
        }

        /* planReconcile (controller.go:316-320). */
        strim_stage_state target = STRIM_STAGE_NO_TARGET;
        if (stage->in_flight_since == 0) {
            target = stage->status.desired;
        } else if (c->now_ms() - stage->in_flight_since >=
                   c->inflight_timeout_ms) {
            /* Timed-out retry: the previous op exceeded inflight_timeout_ms
             * (Go logs "reconcile %q -> %q timed out"). The generation bump
             * below supersedes the older op, whose cancel handle then
             * reports superseded at its next safe point. */
            target = stage->status.desired;
        }
        if (target == STRIM_STAGE_NO_TARGET) {
            continue; /* in flight and not yet timed out */
        }

        strim_stage_op op = (target == STRIM_STAGE_RUNNING) ? stage->start_op
                          : (target == STRIM_STAGE_STOPPED) ? stage->stop_op
                          : NULL;
        if (op == NULL) {
            continue; /* unreachable after construction validation */
        }

        int64_t now = c->now_ms();
        stage->in_flight_since = now;
        stage->op_generation++; /* the new fire supersedes any older one */
        strim_op_job *job = malloc(sizeof *job);
        if (job == NULL) {
            fprintf(stderr,
                    "strim_controller: reconcile op allocation failed\n");
            abort();
        }
        job->c = c;
        job->stage = (strim_stage_name)i;
        job->op = op;
        job->op_ctx = stage->op_ctx;
        job->timeout_ms = c->inflight_timeout_ms;
        job->cancel.generation = stage->op_generation;
        job->cancel.deadline_ms = now + c->inflight_timeout_ms;
        job->cancel.current_generation = &stage->op_generation;
        job->cancel.now_ms = c->now_ms;

        wg_add(&c->ops_wg, 1);
        workerpool_submit(&c->pool, run_stage_op, job);
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

static int teardown_inner(strim_controller *c) {
    for (size_t i = 0; i < STRIM_STAGE_NAME_COUNT; i++) {
        strim_stage *stage = &c->stages[i];
        if (stage->status.actual != STRIM_STAGE_RUNNING) {
            continue;
        }
        if (stage->stop_op == NULL) {
            continue;
        }
        /* Teardown runs with NO cancellation (Go: context.WithoutCancel
         * survives the signal); the ops fall back to their plain inflight
         * timeout and are never superseded. */
        int err = stage->stop_op(stage->op_ctx, c->inflight_timeout_ms, NULL);
        if (err != 0) {
            /* Go logs and continues; the stage is marked stopped either way
             * so the controller does not wedge on a half-stopped stage. */
        }
        stage->status.desired = STRIM_STAGE_STOPPED;
        stage->status.actual = STRIM_STAGE_STOPPED;
        stage->in_flight_since = 0;
    }
    notify_listeners(c);
    return 0;
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
        case ACTION_CLEAR_INFLIGHT:
            c->stages[act->clear_stage].in_flight_since = 0;
            break;
        case ACTION_TEARDOWN:
            result = teardown_inner(c);
            break;
    }

    bool owns_self = act->owns_self;
    bool has_waiter = !owns_self;
    pthread_mutex_lock(&c->q_lock);
    if (has_waiter) {
        act->reply_result = result;
        act->reply_done = true;
        pthread_cond_broadcast(&c->q_cond);
    }
    pthread_mutex_unlock(&c->q_lock);
    if (owns_self) {
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
    strim_action act;
    memset(&act, 0, sizeof act);
    act.kind = ACTION_PATH_EVENT;
    act.path_event = *e;
    return queue_submit(c, &act);
}

int strim_controller_submit_control(strim_controller *c,
                                    const strim_control_command *cmd) {
    if (c == NULL || cmd == NULL) {
        return STRIM_CTRL_ERR_BADARG;
    }
    strim_action act;
    memset(&act, 0, sizeof act);
    act.kind = ACTION_CONTROL;
    act.control = *cmd;
    return queue_submit(c, &act);
}

int strim_controller_submit_stage_event(strim_controller *c,
                                        const strim_stage_event *e) {
    if (c == NULL || e == NULL) {
        return STRIM_CTRL_ERR_BADARG;
    }
    strim_action act;
    memset(&act, 0, sizeof act);
    act.kind = ACTION_STAGE_EVENT;
    act.stage_event = *e;
    return queue_submit(c, &act);
}

int strim_controller_submit_status(strim_controller *c,
                                   strim_controller_status *out) {
    if (c == NULL || out == NULL) {
        return STRIM_CTRL_ERR_BADARG;
    }
    strim_action act;
    memset(&act, 0, sizeof act);
    act.kind = ACTION_STATUS;
    act.status_out = out;
    return queue_submit(c, &act);
}

int strim_controller_submit_add_listener(strim_controller *c,
                                         strim_controller_listener listener,
                                         void *userdata) {
    if (c == NULL || listener == NULL) {
        return STRIM_CTRL_ERR_BADARG;
    }
    strim_action act;
    memset(&act, 0, sizeof act);
    act.kind = ACTION_ADD_LISTENER;
    act.listener = listener;
    act.listener_userdata = userdata;
    return queue_submit(c, &act);
}

int strim_controller_submit_remove_listener(strim_controller *c,
                                            strim_controller_listener listener,
                                            void *userdata) {
    if (c == NULL || listener == NULL) {
        return STRIM_CTRL_ERR_BADARG;
    }
    strim_action act;
    memset(&act, 0, sizeof act);
    act.kind = ACTION_REMOVE_LISTENER;
    act.listener = listener;
    act.listener_userdata = userdata;
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
    memset(act, 0, sizeof *act);
    act->kind = ACTION_RECONCILE;
    act->owns_self = true;

    pthread_mutex_lock(&c->q_lock);
    if (c->q_closed || c->reconcile_queued) {
        pthread_mutex_unlock(&c->q_lock);
        free(act);
        return;
    }
    c->reconcile_queued = true;
    act->next = NULL;
    if (c->q_tail == NULL) {
        c->q_head = c->q_tail = act;
    } else {
        c->q_tail->next = act;
        c->q_tail = act;
    }
    pthread_cond_signal(&c->q_cond);
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
    strim_action act;
    memset(&act, 0, sizeof act);
    act.kind = ACTION_TEARDOWN;
    return queue_submit(c, &act);
}