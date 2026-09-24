/*
 * controller_test.c — state-machine regression suite (C port of
 * core/controller/controller_test.go, plus the inflight-timeout retry and
 * the queue/submit surface).
 *
 * The Go oracle drives the unexported handlers directly on a single
 * goroutine; this suite does the same through the public handle_* functions
 * (controller.h exposes them for exactly this reason). Reconcile fires ops on
 * the worker pool, so the recording op signals a condvar and the tests wait
 * on it — the C analogue of the Go tests' `fired` channel + awaitFire.
 *
 * These tests become the Wave-3 regression suite; keep them clean.
 *
 * License: project code (see LICENSE). No GPL.
 */

#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "controller.h"

static int g_failures = 0;

#define CHECK(cond)                                                       \
    do {                                                                  \
        if (!(cond)) {                                                    \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            g_failures++;                                                 \
        }                                                                 \
    } while (0)

/* testInFlightTimeout is generous on purpose (Go: time.Minute). */
#define TEST_INFLIGHT_TIMEOUT_MS (60 * 1000)

/* -------------------------------------------------------------------------
 * Fake clock
 * ------------------------------------------------------------------------- */

static int64_t g_now_ms = 0;

static int64_t fake_now_ms(void) {
    return g_now_ms;
}

/* -------------------------------------------------------------------------
 * Recording op — increments calls and signals `cond` each invocation
 * (Go: recordingOp + the `fired` channel).
 * ------------------------------------------------------------------------- */

typedef struct recording_op {
    int calls;
    pthread_mutex_t lock;
    pthread_cond_t  cond;
} recording_op;

static void recording_op_init(recording_op *r) {
    r->calls = 0;
    pthread_mutex_init(&r->lock, NULL);
    pthread_cond_init(&r->cond, NULL);
}

static void recording_op_destroy(recording_op *r) {
    pthread_mutex_destroy(&r->lock);
    pthread_cond_destroy(&r->cond);
}

static int recording_op_fn(void *ctx, int64_t timeout_ms,
                           const strim_stage_op_cancel *cancel) {
    recording_op *r = ctx;
    (void)timeout_ms;
    (void)cancel;
    pthread_mutex_lock(&r->lock);
    r->calls++;
    pthread_cond_broadcast(&r->cond);
    pthread_mutex_unlock(&r->lock);
    return 0;
}

static int recording_op_calls(recording_op *r) {
    int n;
    pthread_mutex_lock(&r->lock);
    n = r->calls;
    pthread_mutex_unlock(&r->lock);
    return n;
}

/* awaitFire: block until the op has run at least once (Go: awaitFire). */
static void await_fire(recording_op *r) {
    pthread_mutex_lock(&r->lock);
    while (r->calls < 1) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += 1;
        int rc = pthread_cond_timedwait(&r->cond, &r->lock, &ts);
        if (rc == ETIMEDOUT) {
            pthread_mutex_unlock(&r->lock);
            fprintf(stderr,
                    "FAIL: expected an op to run during reconcile, but none "
                    "did within 1s\n");
            g_failures++;
            return;
        }
    }
    pthread_mutex_unlock(&r->lock);
}

/* awaitCalls: block until the op has run at least `want` times. */
static void await_calls(recording_op *r, int want) {
    pthread_mutex_lock(&r->lock);
    while (r->calls < want) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += 1;
        int rc = pthread_cond_timedwait(&r->cond, &r->lock, &ts);
        if (rc == ETIMEDOUT) {
            pthread_mutex_unlock(&r->lock);
            fprintf(stderr, "FAIL: expected %d op runs, saw only %d\n",
                    want, r->calls);
            g_failures++;
            return;
        }
    }
    pthread_mutex_unlock(&r->lock);
}

/* -------------------------------------------------------------------------
 * Test controller construction (mirrors newTestController + main.go wiring)
 * ------------------------------------------------------------------------- */

typedef struct test_setup {
    strim_controller_config cfg;
    strim_route path_routes[4];
    strim_route control_routes[4];
} test_setup;

static void base_setup(test_setup *s) {
    memset(s, 0, sizeof *s);
    for (size_t i = 0; i < STRIM_PATH_NAME_COUNT; i++) {
        s->cfg.initial_paths[i] = STRIM_PATH_UNKNOWN;
    }
    for (size_t i = 0; i < STRIM_STAGE_NAME_COUNT; i++) {
        s->cfg.stages[i].name = (strim_stage_name)i;
        s->cfg.stages[i].status.desired = STRIM_STAGE_STOPPED;
        s->cfg.stages[i].status.actual = STRIM_STAGE_STOPPED;
    }
    /* Every route slot starts as the end sentinel so unset tables count 0. */
    for (size_t i = 0; i < sizeof(s->path_routes) / sizeof(s->path_routes[0]); i++) {
        s->path_routes[i] = (strim_route){ .kind = 0xFFFF };
        s->control_routes[i] = (strim_route){ .kind = 0xFFFF };
    }
    s->cfg.now_ms = fake_now_ms;
    s->cfg.inflight_timeout_ms = TEST_INFLIGHT_TIMEOUT_MS;
    s->cfg.actions_buffer_size = 16;
    s->cfg.path_routes = s->path_routes;
    s->cfg.control_routes = s->control_routes;
}

/* Sentinel for "no more routes" in the fixed route arrays. */
#define ROUTE_END (strim_route){ .kind = 0xFFFF }

static size_t count_routes(const strim_route *routes, size_t cap) {
    size_t n = 0;
    while (n < cap && routes[n].kind != 0xFFFF) {
        n++;
    }
    return n;
}

static strim_controller *build_controller(test_setup *s) {
    s->cfg.n_path_routes = count_routes(s->path_routes,
                                        sizeof(s->path_routes) /
                                            sizeof(s->path_routes[0]));
    s->cfg.n_control_routes = count_routes(s->control_routes,
                                           sizeof(s->control_routes) /
                                               sizeof(s->control_routes[0]));

    strim_controller *c = NULL;
    int rc = strim_controller_new(&s->cfg, &c);
    if (rc != 0) {
        fprintf(stderr, "FAIL: strim_controller_new returned %d\n", rc);
        g_failures++;
        return NULL;
    }
    return c;
}

/* -------------------------------------------------------------------------
 * Prerequisite gate (Go createPathReadyPrerequisite)
 * ------------------------------------------------------------------------- */

typedef struct prereq_data {
    strim_path_name  path;
    strim_path_status want;
} prereq_data;

static int path_ready_prerequisite(strim_controller *c, void *userdata) {
    prereq_data *p = userdata;
    strim_controller_status st;
    if (strim_controller_handle_status(c, &st) != 0) {
        return -1;
    }
    return (st.paths[p->path] == p->want) ? 0 : -1;
}

/* -------------------------------------------------------------------------
 * Test cases
 * ------------------------------------------------------------------------- */

/* Go TestControllerReceivesIngress0Ready: a path event only records intent;
 * the op is deferred to reconcile, which fires it exactly once. */
static void test_path_event_intent_then_reconcile_fires_once(void) {
    recording_op op;
    recording_op_init(&op);

    test_setup s;
    base_setup(&s);
    s.cfg.initial_paths[STRIM_PATH_INGRESS0] = STRIM_PATH_UNKNOWN;
    s.cfg.stages[STRIM_STAGE_NORMALIZE].start_op = recording_op_fn;
    s.cfg.stages[STRIM_STAGE_NORMALIZE].op_ctx = &op;
    s.path_routes[0] = (strim_route){
        .kind = STRIM_ROUTE_PATH_EVENT,
        .path = STRIM_PATH_INGRESS0,
        .path_status = STRIM_PATH_READY,
        .target_stage = STRIM_STAGE_NORMALIZE,
        .target_state = STRIM_STAGE_RUNNING,
    };
    s.path_routes[1] = ROUTE_END;

    strim_controller *c = build_controller(&s);
    CHECK(c != NULL);
    if (c == NULL) {
        recording_op_destroy(&op);
        return;
    }

    /* Phase 1: record intent. Desired = running, op NOT yet run. */
    strim_path_event e = {STRIM_PATH_INGRESS0, STRIM_PATH_READY};
    CHECK(strim_controller_handle_path_event(c, &e) == 0);

    strim_controller_status st;
    CHECK(strim_controller_handle_status(c, &st) == 0);
    CHECK(st.stages[STRIM_STAGE_NORMALIZE].desired == STRIM_STAGE_RUNNING);
    CHECK(recording_op_calls(&op) == 0);

    /* Phase 2: converge. The Running op fires exactly once. */
    strim_controller_handle_reconcile(c);
    await_fire(&op);
    CHECK(recording_op_calls(&op) == 1);

    strim_controller_wait_for_ops(c);
    strim_controller_destroy(c);
    recording_op_destroy(&op);
}

/* Go TestControllerLaunchesEgress / "prerequisites satisfied". */
static void test_control_prerequisite_satisfied(void) {
    recording_op op;
    recording_op_init(&op);
    prereq_data prereq = {STRIM_PATH_NORMALIZED, STRIM_PATH_READY};

    test_setup s;
    base_setup(&s);
    s.cfg.initial_paths[STRIM_PATH_NORMALIZED] = STRIM_PATH_READY;
    s.cfg.stages[STRIM_STAGE_SCALE_AND_EGRESS].start_op = recording_op_fn;
    s.cfg.stages[STRIM_STAGE_SCALE_AND_EGRESS].op_ctx = &op;
    s.control_routes[0] = (strim_route){
        .kind = STRIM_ROUTE_CONTROL,
        .component = STRIM_COMPONENT_EGRESS,
        .action = STRIM_ACTION_START,
        .target_stage = STRIM_STAGE_SCALE_AND_EGRESS,
        .target_state = STRIM_STAGE_RUNNING,
        .prerequisite = path_ready_prerequisite,
        .prerequisite_userdata = &prereq,
    };
    s.control_routes[1] = ROUTE_END;

    strim_controller *c = build_controller(&s);
    CHECK(c != NULL);
    if (c == NULL) {
        recording_op_destroy(&op);
        return;
    }

    /* Phase 1: the prerequisite passes, so this records intent only. */
    strim_control_command cmd = {STRIM_COMPONENT_EGRESS, STRIM_ACTION_START};
    CHECK(strim_controller_handle_control(c, &cmd) == 0);

    strim_controller_status st;
    CHECK(strim_controller_handle_status(c, &st) == 0);
    CHECK(st.stages[STRIM_STAGE_SCALE_AND_EGRESS].desired ==
          STRIM_STAGE_RUNNING);
    CHECK(recording_op_calls(&op) == 0);

    /* Phase 2: converge; the launcher fires exactly once. */
    strim_controller_handle_reconcile(c);
    await_fire(&op);
    CHECK(recording_op_calls(&op) == 1);

    strim_controller_wait_for_ops(c);
    strim_controller_destroy(c);
    recording_op_destroy(&op);
}

/* Go TestControllerLaunchesEgress / "prerequisites not satisfied". */
static void test_control_prerequisite_rejected(void) {
    recording_op op;
    recording_op_init(&op);
    prereq_data prereq = {STRIM_PATH_NORMALIZED, STRIM_PATH_READY};

    test_setup s;
    base_setup(&s);
    s.cfg.initial_paths[STRIM_PATH_NORMALIZED] = STRIM_PATH_UNKNOWN;
    s.cfg.stages[STRIM_STAGE_SCALE_AND_EGRESS].start_op = recording_op_fn;
    s.cfg.stages[STRIM_STAGE_SCALE_AND_EGRESS].op_ctx = &op;
    s.control_routes[0] = (strim_route){
        .kind = STRIM_ROUTE_CONTROL,
        .component = STRIM_COMPONENT_EGRESS,
        .action = STRIM_ACTION_START,
        .target_stage = STRIM_STAGE_SCALE_AND_EGRESS,
        .target_state = STRIM_STAGE_RUNNING,
        .prerequisite = path_ready_prerequisite,
        .prerequisite_userdata = &prereq,
    };
    s.control_routes[1] = ROUTE_END;

    strim_controller *c = build_controller(&s);
    CHECK(c != NULL);
    if (c == NULL) {
        recording_op_destroy(&op);
        return;
    }

    /* The prerequisite fails: the control returns an error and Desired is
     * left at its seeded "stopped" value. */
    strim_control_command cmd = {STRIM_COMPONENT_EGRESS, STRIM_ACTION_START};
    CHECK(strim_controller_handle_control(c, &cmd) == STRIM_CTRL_ERR_PREREQ);

    strim_controller_status st;
    CHECK(strim_controller_handle_status(c, &st) == 0);
    CHECK(st.stages[STRIM_STAGE_SCALE_AND_EGRESS].desired ==
          STRIM_STAGE_STOPPED);

    /* A reconcile here is a no-op guard (Go expectNoFire): every stage is
     * already converged, so no op runs. Wait a short window to prove the op
     * never signals. */
    strim_controller_handle_reconcile(c);
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_nsec += 100 * 1000 * 1000; /* 100ms */
    if (ts.tv_nsec >= 1000000000) {
        ts.tv_sec++;
        ts.tv_nsec -= 1000000000;
    }
    pthread_mutex_lock(&op.lock);
    int rc = pthread_cond_timedwait(&op.cond, &op.lock, &ts);
    pthread_mutex_unlock(&op.lock);
    CHECK(rc == ETIMEDOUT); /* no fire within the window */
    CHECK(recording_op_calls(&op) == 0);

    strim_controller_destroy(c);
    recording_op_destroy(&op);
}

/* Inflight-timeout retry (the exactly-once + timed-out retry contract,
 * controller.go:316-320): a fired op suppresses re-firing until its
 * inflight period elapses, then a timed-out reconcile re-issues it. */
static void test_inflight_timeout_retry(void) {
    recording_op op;
    recording_op_init(&op);

    test_setup s;
    base_setup(&s);
    g_now_ms = 1000;
    s.cfg.initial_paths[STRIM_PATH_INGRESS0] = STRIM_PATH_UNKNOWN;
    s.cfg.stages[STRIM_STAGE_NORMALIZE].start_op = recording_op_fn;
    s.cfg.stages[STRIM_STAGE_NORMALIZE].op_ctx = &op;
    s.path_routes[0] = (strim_route){
        .kind = STRIM_ROUTE_PATH_EVENT,
        .path = STRIM_PATH_INGRESS0,
        .path_status = STRIM_PATH_READY,
        .target_stage = STRIM_STAGE_NORMALIZE,
        .target_state = STRIM_STAGE_RUNNING,
    };
    s.path_routes[1] = ROUTE_END;

    strim_controller *c = build_controller(&s);
    CHECK(c != NULL);
    if (c == NULL) {
        recording_op_destroy(&op);
        return;
    }

    /* Record intent + first reconcile: fires once, sets InFlightSince. */
    strim_path_event e = {STRIM_PATH_INGRESS0, STRIM_PATH_READY};
    CHECK(strim_controller_handle_path_event(c, &e) == 0);
    strim_controller_handle_reconcile(c);
    await_fire(&op);
    CHECK(recording_op_calls(&op) == 1);

    /* Second reconcile before the timeout: still in flight, no re-fire. */
    strim_controller_handle_reconcile(c);
    CHECK(recording_op_calls(&op) == 1);

    /* Advance past the inflight timeout: the next reconcile re-issues the
     * desired-state op exactly once (the timed-out retry). */
    g_now_ms += TEST_INFLIGHT_TIMEOUT_MS + 1;
    strim_controller_handle_reconcile(c);
    await_calls(&op, 2);
    CHECK(recording_op_calls(&op) == 2);

    strim_controller_wait_for_ops(c);
    strim_controller_destroy(c);
    recording_op_destroy(&op);
}

/* -------------------------------------------------------------------------
 * M1 regression: a timed-out retry must never run concurrently with the
 * still-running first op (the create-vs-delete race). The fix combines a
 * per-stage generation token (strim_stage_op_cancel: a retry supersedes the
 * older op, which aborts at its next safe point) with an absolute deadline
 * (the op bounds its RPCs by the remaining budget, so it cannot outlive the
 * inflight timeout). These tests drive a slow op that simulates a hung RPC.
 * ------------------------------------------------------------------------- */

typedef struct slow_op {
    pthread_mutex_t lock;
    pthread_cond_t  cond;
    int calls;       /* op invocations started */
    int active;      /* ops currently inside the critical section */
    int max_active;  /* high-water mark of active */
    int completed;   /* ops that finished the critical section normally */
    int superseded;  /* ops that aborted because a retry superseded them */
    int deadline;    /* ops that aborted because the deadline expired */
    int release;     /* 1 = let blocked ops finish normally */
} slow_op;

static void slow_op_init(slow_op *s) {
    memset(s, 0, sizeof *s);
    pthread_mutex_init(&s->lock, NULL);
    pthread_cond_init(&s->cond, NULL);
}

static void slow_op_destroy(slow_op *s) {
    pthread_mutex_destroy(&s->lock);
    pthread_cond_destroy(&s->cond);
}

/* A slow op that simulates a hung RPC: it enters a critical section (the
 * "RPC step"), records concurrent execution, and blocks until the test
 * releases it, its deadline expires (the remaining-budget bound), or a newer
 * fire supersedes it (the generation token). Returns 0 in every case — a
 * superseded op is a no-op, exactly like the real ops. */
static int slow_op_fn(void *ctx, int64_t timeout_ms,
                      const strim_stage_op_cancel *cancel) {
    slow_op *s = ctx;
    (void)timeout_ms;
    pthread_mutex_lock(&s->lock);
    s->calls++;
    pthread_cond_broadcast(&s->cond);

    /* Safe point before the RPC step. */
    if (strim_stage_op_superseded(cancel)) {
        s->superseded++;
        pthread_mutex_unlock(&s->lock);
        return 0;
    }

    s->active++;
    if (s->active > s->max_active) {
        s->max_active = s->active;
    }
    pthread_cond_broadcast(&s->cond);

    for (;;) {
        if (s->release) {
            s->completed++;
            break;
        }
        if (strim_stage_op_superseded(cancel)) {
            s->superseded++;
            break;
        }
        int64_t remaining = strim_stage_op_remaining_ms(cancel);
        if (remaining <= 0) {
            s->deadline++;
            break;
        }
        /* Wait until the (fake-clock) deadline in real time; the test wakes
         * us early with a broadcast. */
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += remaining / 1000;
        ts.tv_nsec += (remaining % 1000) * 1000000L;
        if (ts.tv_nsec >= 1000000000) {
            ts.tv_sec++;
            ts.tv_nsec -= 1000000000;
        }
        pthread_cond_timedwait(&s->cond, &s->lock, &ts);
    }
    s->active--;
    pthread_cond_broadcast(&s->cond);
    pthread_mutex_unlock(&s->lock);
    return 0;
}

static void await_active(slow_op *s, int want) {
    pthread_mutex_lock(&s->lock);
    while (s->active < want) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += 1;
        int rc = pthread_cond_timedwait(&s->cond, &s->lock, &ts);
        if (rc == ETIMEDOUT) {
            pthread_mutex_unlock(&s->lock);
            fprintf(stderr, "FAIL: expected %d active op(s), saw %d\n",
                    want, s->active);
            g_failures++;
            return;
        }
    }
    pthread_mutex_unlock(&s->lock);
}

static void await_inactive(slow_op *s) {
    pthread_mutex_lock(&s->lock);
    while (s->active > 0) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += 1;
        int rc = pthread_cond_timedwait(&s->cond, &s->lock, &ts);
        if (rc == ETIMEDOUT) {
            pthread_mutex_unlock(&s->lock);
            fprintf(stderr,
                    "FAIL: expected the op to leave its critical section "
                    "within 1s\n");
            g_failures++;
            return;
        }
    }
    pthread_mutex_unlock(&s->lock);
}

static void slow_op_await_calls(slow_op *s, int want) {
    pthread_mutex_lock(&s->lock);
    while (s->calls < want) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += 1;
        int rc = pthread_cond_timedwait(&s->cond, &s->lock, &ts);
        if (rc == ETIMEDOUT) {
            pthread_mutex_unlock(&s->lock);
            fprintf(stderr, "FAIL: expected %d op runs, saw only %d\n",
                    want, s->calls);
            g_failures++;
            return;
        }
    }
    pthread_mutex_unlock(&s->lock);
}

static void await_superseded(slow_op *s) {
    pthread_mutex_lock(&s->lock);
    while (s->superseded < 1) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += 1;
        int rc = pthread_cond_timedwait(&s->cond, &s->lock, &ts);
        if (rc == ETIMEDOUT) {
            pthread_mutex_unlock(&s->lock);
            fprintf(stderr, "FAIL: expected the first op to abort via the "
                            "generation token within 1s\n");
            g_failures++;
            return;
        }
    }
    pthread_mutex_unlock(&s->lock);
}

/* Test 1 (the deadline bound, design b): an op that overruns the inflight
 * timeout is bounded by its absolute deadline — the timed-out retry fires
 * only AFTER the first op has left its critical section, so at most one op
 * executes per stage at any moment. */
static void test_inflight_timeout_no_concurrent_ops(void) {
    slow_op op;
    slow_op_init(&op);

    test_setup s;
    base_setup(&s);
    g_now_ms = 1000;
    s.cfg.initial_paths[STRIM_PATH_INGRESS0] = STRIM_PATH_UNKNOWN;
    s.cfg.stages[STRIM_STAGE_NORMALIZE].start_op = slow_op_fn;
    s.cfg.stages[STRIM_STAGE_NORMALIZE].op_ctx = &op;
    s.path_routes[0] = (strim_route){
        .kind = STRIM_ROUTE_PATH_EVENT,
        .path = STRIM_PATH_INGRESS0,
        .path_status = STRIM_PATH_READY,
        .target_stage = STRIM_STAGE_NORMALIZE,
        .target_state = STRIM_STAGE_RUNNING,
    };
    s.path_routes[1] = ROUTE_END;

    strim_controller *c = build_controller(&s);
    CHECK(c != NULL);
    if (c == NULL) {
        slow_op_destroy(&op);
        return;
    }

    /* Record intent + first reconcile: fires op #1, which enters its RPC
     * step and blocks (it will overrun the inflight timeout). */
    strim_path_event e = {STRIM_PATH_INGRESS0, STRIM_PATH_READY};
    CHECK(strim_controller_handle_path_event(c, &e) == 0);
    strim_controller_handle_reconcile(c);
    await_active(&op, 1);
    CHECK(op.calls == 1);
    CHECK(op.max_active == 1);

    /* Advance past the deadline and wake op #1: bounded by its remaining
     * budget, it aborts (deadline, NOT completed) and leaves the critical
     * section. */
    g_now_ms += TEST_INFLIGHT_TIMEOUT_MS + 1;
    pthread_mutex_lock(&op.lock);
    pthread_cond_broadcast(&op.cond);
    pthread_mutex_unlock(&op.lock);
    await_inactive(&op);
    CHECK(op.deadline == 1);
    CHECK(op.completed == 0);
    CHECK(op.superseded == 0);

    /* The timed-out retry now fires op #2; it runs alone (release is set, so
     * it completes immediately). At no point were two ops in the critical
     * section together. */
    pthread_mutex_lock(&op.lock);
    op.release = 1;
    pthread_cond_broadcast(&op.cond);
    pthread_mutex_unlock(&op.lock);
    strim_controller_handle_reconcile(c);
    slow_op_await_calls(&op, 2);
    await_inactive(&op);
    CHECK(op.calls == 2);
    CHECK(op.max_active == 1); /* the retry never overlapped the first op */
    CHECK(op.completed == 1);
    CHECK(op.deadline == 1);
    CHECK(op.superseded == 0);

    strim_controller_wait_for_ops(c);
    strim_controller_destroy(c);
    slow_op_destroy(&op);
}

/* Test 2 (the generation token, design a): when the timed-out retry fires
 * while the first op is still blocked, the retry SUPERSEDES it — the first
 * op aborts at its next safe point and never completes its destructive step.
 * Only the retry completes the step (exactly-once destructive execution).
 * (The residual overlap window — the first op still unwinding while the
 * retry enters — is bounded by the deadline tested above.) */
static void test_inflight_timeout_supersedes_previous_op(void) {
    slow_op op;
    slow_op_init(&op);

    test_setup s;
    base_setup(&s);
    g_now_ms = 1000;
    s.cfg.initial_paths[STRIM_PATH_INGRESS0] = STRIM_PATH_UNKNOWN;
    s.cfg.stages[STRIM_STAGE_NORMALIZE].start_op = slow_op_fn;
    s.cfg.stages[STRIM_STAGE_NORMALIZE].op_ctx = &op;
    s.path_routes[0] = (strim_route){
        .kind = STRIM_ROUTE_PATH_EVENT,
        .path = STRIM_PATH_INGRESS0,
        .path_status = STRIM_PATH_READY,
        .target_stage = STRIM_STAGE_NORMALIZE,
        .target_state = STRIM_STAGE_RUNNING,
    };
    s.path_routes[1] = ROUTE_END;

    strim_controller *c = build_controller(&s);
    CHECK(c != NULL);
    if (c == NULL) {
        slow_op_destroy(&op);
        return;
    }

    /* Fire op #1; it blocks inside its RPC step. */
    strim_path_event e = {STRIM_PATH_INGRESS0, STRIM_PATH_READY};
    CHECK(strim_controller_handle_path_event(c, &e) == 0);
    strim_controller_handle_reconcile(c);
    await_active(&op, 1);
    CHECK(op.calls == 1);

    /* Advance past the timeout and reconcile: the retry fires op #2, which
     * bumps the stage generation and supersedes op #1. */
    g_now_ms += TEST_INFLIGHT_TIMEOUT_MS + 1;
    strim_controller_handle_reconcile(c);

    /* Wake op #1: it sees the generation mismatch and aborts via the token
     * (not the deadline, not a normal completion). */
    pthread_mutex_lock(&op.lock);
    pthread_cond_broadcast(&op.cond);
    pthread_mutex_unlock(&op.lock);
    slow_op_await_calls(&op, 2);
    await_superseded(&op);
    CHECK(op.superseded == 1);
    CHECK(op.deadline == 0);
    CHECK(op.completed == 0);

    /* Release op #2: the retry is the only op that completes its step. */
    pthread_mutex_lock(&op.lock);
    op.release = 1;
    pthread_cond_broadcast(&op.cond);
    pthread_mutex_unlock(&op.lock);
    await_inactive(&op);
    CHECK(op.completed == 1);
    CHECK(op.calls == 2);

    strim_controller_wait_for_ops(c);
    strim_controller_destroy(c);
    slow_op_destroy(&op);
}

/* Stage events update Actual and clear InFlight; NoTarget is rejected on
 * the wire (controller.go:236-248). */
static void test_stage_event_updates_actual(void) {
    test_setup s;
    base_setup(&s);

    strim_controller *c = build_controller(&s);
    CHECK(c != NULL);
    if (c == NULL) {
        return;
    }

    strim_stage_event ev = {STRIM_STAGE_MEDIA_MTX, STRIM_STAGE_RUNNING};
    CHECK(strim_controller_handle_stage_event(c, &ev) == 0);

    strim_controller_status st;
    CHECK(strim_controller_handle_status(c, &st) == 0);
    CHECK(st.stages[STRIM_STAGE_MEDIA_MTX].actual == STRIM_STAGE_RUNNING);

    /* Invalid state (NoTarget never arrives on the wire) is rejected. */
    strim_stage_event bad = {STRIM_STAGE_MEDIA_MTX, STRIM_STAGE_NO_TARGET};
    CHECK(strim_controller_handle_stage_event(c, &bad) ==
          STRIM_CTRL_ERR_BADARG);

    strim_controller_destroy(c);
}

/* Listeners: add receives an immediate snapshot and is notified on change;
 * remove stops notifications (Go controller.go:250-267). Uses the submit
 * surface, so it runs the full queue. */
typedef struct counter_listener {
    int calls;
} counter_listener;

static void count_listener(const strim_controller_status *status,
                           void *userdata) {
    (void)status;
    counter_listener *cl = userdata;
    cl->calls++;
}

static void *run_thread(void *arg) {
    strim_controller_run(arg);
    return NULL;
}

static void test_listeners(void) {
    counter_listener l1 = {0};
    counter_listener l2 = {0};

    test_setup s;
    base_setup(&s);

    strim_controller *c = build_controller(&s);
    CHECK(c != NULL);
    if (c == NULL) {
        return;
    }

    pthread_t tid;
    CHECK(pthread_create(&tid, NULL, run_thread, c) == 0);

    /* Adding a listener delivers the immediate snapshot (Go: f(handleStatus)). */
    CHECK(strim_controller_submit_add_listener(c, count_listener, &l1) == 0);
    CHECK(l1.calls == 1);

    CHECK(strim_controller_submit_add_listener(c, count_listener, &l2) == 0);
    CHECK(l2.calls == 1);

    /* A stage-state change notifies every listener exactly once. */
    strim_stage_event ev = {STRIM_STAGE_MEDIA_MTX, STRIM_STAGE_RUNNING};
    CHECK(strim_controller_submit_stage_event(c, &ev) == 0);
    CHECK(l1.calls == 2);
    CHECK(l2.calls == 2);

    /* Removing a listener stops its notifications. */
    CHECK(strim_controller_submit_remove_listener(c, count_listener, &l1) == 0);
    strim_stage_event ev2 = {STRIM_STAGE_MEDIA_MTX, STRIM_STAGE_STOPPED};
    CHECK(strim_controller_submit_stage_event(c, &ev2) == 0);
    CHECK(l1.calls == 2); /* unchanged */
    CHECK(l2.calls == 3);

    /* Removing an unknown listener is an error. */
    CHECK(strim_controller_submit_remove_listener(c, count_listener, &l1) ==
          STRIM_CTRL_ERR_UNKNOWN);

    strim_controller_close(c);
    pthread_join(tid, NULL);
    strim_controller_destroy(c);
}

/* -------------------------------------------------------------------------
 * Wire-string helpers (the JSON contract the HTTP lane serializes)
 * ------------------------------------------------------------------------- */

static void test_wire_strings(void) {
    CHECK(strcmp(strim_path_status_to_string(STRIM_PATH_READY), "ready") == 0);
    CHECK(strcmp(strim_path_status_to_string(STRIM_PATH_NOT_READY),
                 "not-ready") == 0);
    CHECK(strcmp(strim_path_status_to_string(STRIM_PATH_UNKNOWN), "unknown") == 0);
    CHECK(strim_path_status_to_string((strim_path_status)99) == NULL);

    CHECK(strcmp(strim_stage_state_to_string(STRIM_STAGE_RUNNING), "running") == 0);
    CHECK(strcmp(strim_stage_state_to_string(STRIM_STAGE_STOPPED), "stopped") == 0);
    CHECK(strcmp(strim_stage_state_to_string(STRIM_STAGE_NO_TARGET), "") == 0);

    CHECK(strcmp(strim_path_name_to_string(STRIM_PATH_INGRESS0), "ingress0") == 0);
    CHECK(strcmp(strim_path_name_to_string(STRIM_PATH_NORMALIZED),
                 "normalized") == 0);

    CHECK(strcmp(strim_stage_name_to_string(STRIM_STAGE_MEDIA_MTX),
                 "mediamtx") == 0);
    CHECK(strcmp(strim_stage_name_to_string(STRIM_STAGE_NORMALIZE),
                 "normalize") == 0);
    CHECK(strcmp(strim_stage_name_to_string(STRIM_STAGE_SCALE_AND_EGRESS),
                 "scale_and_egress") == 0);
    CHECK(strcmp(strim_stage_name_to_string(STRIM_STAGE_SINGLE_STAGE_EGRESS),
                 "single_stage_egress") == 0);

    CHECK(strcmp(strim_control_component_to_string(STRIM_COMPONENT_EGRESS),
                 "egress") == 0);
    CHECK(strcmp(strim_control_action_to_string(STRIM_ACTION_START),
                 "start") == 0);
    CHECK(strcmp(strim_control_action_to_string(STRIM_ACTION_STOP), "stop") == 0);

    strim_path_status ps;
    CHECK(strim_path_status_from_string("ready", &ps) == 0 &&
          ps == STRIM_PATH_READY);
    CHECK(strim_path_status_from_string("bogus", &ps) == -1);

    strim_stage_name sn;
    CHECK(strim_stage_name_from_string("scale_and_egress", &sn) == 0 &&
          sn == STRIM_STAGE_SCALE_AND_EGRESS);
    CHECK(strim_stage_name_from_string("scale-and-egress", &sn) == -1);

    /* Round trips for every enum value. */
    for (int i = 0; i < STRIM_PATH_STATUS_COUNT; i++) {
        strim_path_status v = (strim_path_status)i;
        const char *s = strim_path_status_to_string(v);
        strim_path_status back;
        CHECK(s != NULL &&
              strim_path_status_from_string(s, &back) == 0 && back == v);
    }
    for (int i = 0; i < STRIM_STAGE_STATE_COUNT; i++) {
        strim_stage_state v = (strim_stage_state)i;
        const char *s = strim_stage_state_to_string(v);
        strim_stage_state back;
        CHECK(s != NULL &&
              strim_stage_state_from_string(s, &back) == 0 && back == v);
    }
    for (int i = 0; i < STRIM_STAGE_NAME_COUNT; i++) {
        strim_stage_name v = (strim_stage_name)i;
        const char *s = strim_stage_name_to_string(v);
        strim_stage_name back;
        CHECK(s != NULL &&
              strim_stage_name_from_string(s, &back) == 0 && back == v);
    }
}

/* -------------------------------------------------------------------------
 * Queue + submit surface (the blocking enqueue + Run loop)
 * ------------------------------------------------------------------------- */

static void test_submit_surface(void) {
    recording_op op;
    recording_op_init(&op);

    test_setup s;
    base_setup(&s);
    s.cfg.initial_paths[STRIM_PATH_INGRESS0] = STRIM_PATH_UNKNOWN;
    s.cfg.stages[STRIM_STAGE_NORMALIZE].start_op = recording_op_fn;
    s.cfg.stages[STRIM_STAGE_NORMALIZE].op_ctx = &op;
    s.path_routes[0] = (strim_route){
        .kind = STRIM_ROUTE_PATH_EVENT,
        .path = STRIM_PATH_INGRESS0,
        .path_status = STRIM_PATH_READY,
        .target_stage = STRIM_STAGE_NORMALIZE,
        .target_state = STRIM_STAGE_RUNNING,
    };
    s.path_routes[1] = ROUTE_END;

    strim_controller *c = build_controller(&s);
    CHECK(c != NULL);
    if (c == NULL) {
        recording_op_destroy(&op);
        return;
    }

    pthread_t tid;
    CHECK(pthread_create(&tid, NULL, run_thread, c) == 0);

    /* Blocking submit: enqueues, the queue thread runs it, returns the
     * handler's result. */
    strim_path_event e = {STRIM_PATH_INGRESS0, STRIM_PATH_READY};
    CHECK(strim_controller_submit_path_event(c, &e) == 0);

    strim_controller_status st;
    CHECK(strim_controller_submit_status(c, &st) == 0);
    CHECK(st.paths[STRIM_PATH_INGRESS0] == STRIM_PATH_READY);
    CHECK(st.stages[STRIM_STAGE_NORMALIZE].desired == STRIM_STAGE_RUNNING);

    /* Non-blocking reconcile; the op fires on the worker pool. */
    strim_controller_request_reconcile(c);
    await_fire(&op);
    CHECK(recording_op_calls(&op) == 1);

    strim_controller_wait_for_ops(c);

    strim_controller_close(c);
    pthread_join(tid, NULL);

    /* Submitting after Close fails with STRIM_CTRL_ERR_CLOSED. */
    CHECK(strim_controller_submit_status(c, &st) == STRIM_CTRL_ERR_CLOSED);

    strim_controller_destroy(c);
    recording_op_destroy(&op);
}

/* Construction validation (Go NewController's error paths). */
static void test_construction_validation(void) {
    test_setup s;
    base_setup(&s);
    strim_controller *c = NULL;

    /* Zero inflight timeout is rejected. */
    s.cfg.inflight_timeout_ms = 0;
    CHECK(strim_controller_new(&s.cfg, &c) == STRIM_CTRL_ERR_BADARG);
    s.cfg.inflight_timeout_ms = TEST_INFLIGHT_TIMEOUT_MS;

    /* A route targeting a state the stage has no op for is rejected. */
    s.cfg.path_routes = s.path_routes;
    s.path_routes[0] = (strim_route){
        .kind = STRIM_ROUTE_PATH_EVENT,
        .path = STRIM_PATH_INGRESS0,
        .path_status = STRIM_PATH_READY,
        .target_stage = STRIM_STAGE_NORMALIZE,
        .target_state = STRIM_STAGE_RUNNING,
    };
    s.cfg.n_path_routes = 1; /* no op on normalize -> rejected */
    CHECK(strim_controller_new(&s.cfg, &c) == STRIM_CTRL_ERR_BADARG);

    /* An out-of-range stage name is rejected. */
    s.cfg.n_path_routes = 0;
    s.cfg.stages[0].name = STRIM_STAGE_NORMALIZE; /* index 0 wants MEDIA_MTX */
    CHECK(strim_controller_new(&s.cfg, &c) == STRIM_CTRL_ERR_BADARG);
}

/* -------------------------------------------------------------------------
 * main
 * ------------------------------------------------------------------------- */

int main(void) {
    printf("=== core controller state machine ===\n");

    test_wire_strings();
    printf("[ok] test_wire_strings\n");
    test_path_event_intent_then_reconcile_fires_once();
    printf("[ok] test_path_event_intent_then_reconcile_fires_once\n");
    test_control_prerequisite_satisfied();
    printf("[ok] test_control_prerequisite_satisfied\n");
    test_control_prerequisite_rejected();
    printf("[ok] test_control_prerequisite_rejected\n");
    test_inflight_timeout_retry();
    printf("[ok] test_inflight_timeout_retry\n");
    test_inflight_timeout_no_concurrent_ops();
    printf("[ok] test_inflight_timeout_no_concurrent_ops\n");
    test_inflight_timeout_supersedes_previous_op();
    printf("[ok] test_inflight_timeout_supersedes_previous_op\n");
    test_stage_event_updates_actual();
    printf("[ok] test_stage_event_updates_actual\n");
    test_listeners();
    printf("[ok] test_listeners\n");
    test_submit_surface();
    printf("[ok] test_submit_surface\n");
    test_construction_validation();
    printf("[ok] test_construction_validation\n");

    if (g_failures == 0) {
        printf("ALL PASS\n");
        return 0;
    }
    printf("%d FAILURE(S)\n", g_failures);
    return 1;
}