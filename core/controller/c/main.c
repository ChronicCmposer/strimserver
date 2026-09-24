/*
 * main.c — the strimserver controller entry point (C port of main.go).
 *
 * Wave 2 (integration lane). This file is the MAIN/INTEGRATION task of the
 * pure-C Go→C port: it wires the three Wave-1 lanes (core state machine,
 * containerd client, HTTP/websocket server) into the final
 * `strimserver-controller` binary, replicating core/controller/main.go's
 * run() lifecycle 1:1:
 *
 *   - env-var config loading from the env spec (envspec.go): containerd
 *     socket/namespace, HTTP port, host root, reconcile interval, inflight
 *     timeout, shutdown timeout, stage stop timeout, websocket write timeout,
 *     actions buffer size, single-stage-pipeline toggle, and the four
 *     container configs. The -check-env / -print-env-example /
 *     -print-ts-types flags replicate the Go flag surface byte-for-byte.
 *
 *   - the container factory + stage ops: mediamtx create/lookup and the
 *     ffmpeg normalize / scale-and-egress / single-stage-egress stage ops
 *     over the containerd client (container_factory.go CreateContainerOps).
 *
 *   - the controller: paths map (ingress0/normalized = unknown), path-event
 *     routes + command routes (egress start is gated on ingress0 ready),
 *     and the stages map (mediamtx always desired-running, others stopped).
 *
 *   - the HTTP callbacks (handle_event / handle_control / handle_status /
 *     request_reconcile / ws_subscribe / ws_unsubscribe / ws_send) with the
 *     per-client 1-deep ws listener queue (main.go:243-291).
 *
 *   - the containerd event listener (topic filter "/tasks/.*", TaskStart →
 *     Running, TaskExit → Stopped) calling submit_stage_event.
 *
 *   - the reconcile ticker calling request_reconcile every interval.
 *
 *   - graceful shutdown on SIGINT/SIGTERM: HTTP shutdown → ticker → listener
 *     → WaitForOps → Teardown → Close → join controller → destroy (the Go
 *     ordering in main.go:344-365).
 *
 * ENTRYPOINT CONTRACT: this binary IS the image entrypoint (no
 * /entrypoint.sh, no /bin/sh — the plan's design). main() sources
 * /strimserver.env when present (what entrypoint.sh's `set -a; . file;
 * set +a` did), then runs.
 *
 * Cross-lane notes honored here:
 *   - Core lane: strim_controller_new rejects bad configs; submit_status fills
 *     the fixed arrays; submit_add_listener fires the listener immediately on
 *     the controller thread; now_ms NULL = monotonic wall clock.
 *   - HTTP lane: ws_send = strim_http_ws_send (internal.h singleton).
 *     handle_event/handle_control return 0 → 204 + request_reconcile,
 *     STRIM_HTTP_ERR_BADJSON → 400, other non-zero → 500. handle_status must
 *     emit JSON plus a trailing '\n' (Go json.NewEncoder).
 *   - Containerd lane: task Wait + event streams use dedicated h2c
 *     connections; the stop path runs task_wait on its own thread while
 *     task_kill runs on the controller thread; graceful Kill(SIGTERM,
 *     All=false) then force-delete Kill(SIGKILL, All=true) → wait → Delete.
 *
 * License: project code (see LICENSE). No GPL.
 */

#include "cdi.h"
#include "containerd_client.h"
#include "controller.h"
#include "http_server.h"
#include "internal.h"   /* STRIM_HTTP_ERR_BADJSON + strim_http_ws_send */
#include "spec.h"
#include "yyjson.h"

#include <errno.h>
#include <inttypes.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* =========================================================================
 * Logging (Go's log.Printf to stderr, timestamped)
 * ========================================================================= */

static pthread_mutex_t g_log_lock = PTHREAD_MUTEX_INITIALIZER;

static void logmsg(const char *fmt, ...) {
    time_t now = time(NULL);
    struct tm tmv;
    char ts[32];
    va_list ap;

    /* Go's log package serializes writers; the controller's 4-thread worker
     * pool logs concurrently, so guard the stderr write. */
    pthread_mutex_lock(&g_log_lock);
    localtime_r(&now, &tmv);
    strftime(ts, sizeof ts, "%Y/%m/%d %H:%M:%S", &tmv);
    fprintf(stderr, "%s ", ts);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    pthread_mutex_unlock(&g_log_lock);
}

/* Log an RPC failure in the "could not <verb> %s <object>: %d" family. When
 * the failure is STRIM_CTRD_ERR_RPC and the client retains a daemon gRPC
 * status, append it so operators see WHY the daemon rejected the RPC (e.g. a
 * shim/runc error on Tasks/Create):
 *
 *   could not create scale-and-egress task: -9 (grpc status 13 (INTERNAL))
 */
static void log_rpc_failure(const char *fmt, const char *stage, int rc,
                            strim_containerd_client *client) {
    char reason[96];
    if (rc == STRIM_CTRD_ERR_RPC && client != NULL &&
        strim_containerd_last_error(client, reason, sizeof reason) > 0) {
        char full[256];
        snprintf(full, sizeof full, "%s (%%s)", fmt);
        logmsg(full, stage, rc, reason);
    } else {
        logmsg(fmt, stage, rc);
    }
}

/* =========================================================================
 * Config (envspec.go: Config + EnvVar)
 * ========================================================================= */

#define STRIM_CFG_ID_MAX    128
#define STRIM_CFG_SNAP_MAX  256
#define STRIM_CFG_IMAGE_MAX 512
#define STRIM_CFG_PATH_MAX  1024

typedef struct strim_container_config {
    char container_id[STRIM_CFG_ID_MAX];
    char snapshot_id[STRIM_CFG_SNAP_MAX];
    char image_name[STRIM_CFG_IMAGE_MAX];
    char logfile[STRIM_CFG_PATH_MAX];
} strim_container_config;

typedef struct strim_config {
    char  containerd_socket[256];
    char  containerd_namespace[128];
    char  controller_http_port[32];
    char  host_root[STRIM_CFG_PATH_MAX];
    int64_t reconcile_interval_ms;
    int64_t inflight_timeout_ms;
    int64_t shutdown_timeout_ms;
    int64_t stage_stop_timeout_ms;
    int64_t websocket_write_timeout_ms;
    uint8_t actions_buffer_size;
    bool    enable_single_stage_pipeline;

    strim_container_config mediamtx;
    strim_container_config normalize;
    strim_container_config scale_and_egress;
    strim_container_config single_stage_egress;
} strim_config;

/* Bound a string into a fixed field (fail loud on overflow — a malformed
 * env value must halt config load, matching Go's parse-error contract). */
static int bind_str(char *dst, size_t cap, const char *raw, char *err,
                    size_t err_cap) {
    if (raw == NULL || dst == NULL || cap == 0) {
        snprintf(err, err_cap, "empty value");
        return -1;
    }
    if (strlen(raw) >= cap) {
        snprintf(err, err_cap, "value too long (%zu bytes, cap %zu)",
                 strlen(raw), cap - 1);
        return -1;
    }
    strcpy(dst, raw);
    return 0;
}

/* Go time.ParseDuration subset: [sign] N[unit]... where N is a decimal
 * (integer or fraction) and unit is one of ns/us/µs/ms/s/m/h. At least one
 * unit is required (Go rejects "0"). Returns nanoseconds. */
static int parse_go_duration(const char *s, int64_t *out_ns) {
    const char *p;
    double total_ns = 0.0;
    int saw_unit = 0;
    int neg = 0;

    if (s == NULL || out_ns == NULL) {
        return -1;
    }
    p = s;
    if (*p == '+' || *p == '-') {
        neg = (*p == '-');
        p++;
    }
    if (*p == '\0') {
        return -1;
    }
    for (;;) {
        double value = 0.0;
        int digits = 0;
        double frac = 0.1;

        while (*p >= '0' && *p <= '9') {
            value = value * 10.0 + (double)(*p - '0');
            digits++;
            p++;
        }
        if (*p == '.') {
            p++;
            while (*p >= '0' && *p <= '9') {
                value += (double)(*p - '0') * frac;
                frac *= 0.1;
                digits++;
                p++;
            }
        }
        if (digits == 0) {
            return -1; /* no number before the unit */
        }

        /* Unit (longest match first; µs is the 2-byte UTF-8 sequence). */
        if (strncmp(p, "ns", 2) == 0) {
            total_ns += value * 1.0;
            p += 2;
        } else if (strncmp(p, "us", 2) == 0) {
            total_ns += value * 1000.0;
            p += 2;
        } else if ((unsigned char)p[0] == 0xC2 && (unsigned char)p[1] == 0xB5 &&
                   p[2] == 's') {
            total_ns += value * 1000.0;
            p += 3;
        } else if (strncmp(p, "ms", 2) == 0) {
            total_ns += value * 1000000.0;
            p += 2;
        } else if (*p == 's') {
            total_ns += value * 1000000000.0;
            p += 1;
        } else if (*p == 'm') {
            total_ns += value * 60000000000.0;
            p += 1;
        } else if (*p == 'h') {
            total_ns += value * 3600000000000.0;
            p += 1;
        } else {
            return -1; /* unknown / missing unit */
        }
        saw_unit = 1;

        if (*p == '\0') {
            break;
        }
    }
    if (!saw_unit) {
        return -1;
    }
    if (neg) {
        total_ns = -total_ns;
    }
    if (total_ns > (double)INT64_MAX || total_ns < (double)INT64_MIN) {
        return -1;
    }
    *out_ns = (int64_t)total_ns;
    return 0;
}

static int bind_duration_ms(int64_t *dst, const char *raw, char *err,
                            size_t err_cap) {
    int64_t ns;
    if (parse_go_duration(raw, &ns) != 0) {
        snprintf(err, err_cap, "invalid Go duration %s", raw);
        return -1;
    }
    /* The C controller works in milliseconds; round to the nearest ms. */
    if (ns < 0) {
        *dst = -((-ns + 500000) / 1000000);
    } else {
        *dst = (ns + 500000) / 1000000;
    }
    return 0;
}

static int bind_uint8(uint8_t *dst, const char *raw, char *err, size_t err_cap) {
    char *end = NULL;
    unsigned long v;

    if (raw == NULL || raw[0] == '\0') {
        snprintf(err, err_cap, "empty value");
        return -1;
    }
    errno = 0;
    v = strtoul(raw, &end, 10);
    if (errno != 0 || end == raw || *end != '\0' || v > 255) {
        snprintf(err, err_cap, "invalid uint8 %s", raw);
        return -1;
    }
    *dst = (uint8_t)v;
    return 0;
}

static int bind_bool(bool *dst, const char *raw, char *err, size_t err_cap) {
    if (raw == NULL) {
        snprintf(err, err_cap, "empty value");
        return -1;
    }
    if (strcmp(raw, "1") == 0 || strcmp(raw, "t") == 0 ||
        strcmp(raw, "T") == 0 || strcmp(raw, "true") == 0 ||
        strcmp(raw, "TRUE") == 0 || strcmp(raw, "True") == 0) {
        *dst = true;
        return 0;
    }
    if (strcmp(raw, "0") == 0 || strcmp(raw, "f") == 0 ||
        strcmp(raw, "F") == 0 || strcmp(raw, "false") == 0 ||
        strcmp(raw, "FALSE") == 0 || strcmp(raw, "False") == 0) {
        *dst = false;
        return 0;
    }
    snprintf(err, err_cap, "invalid bool %s", raw);
    return -1;
}

typedef struct strim_env_var {
    const char *name;
    const char *group;
    bool        required;
    const char *example;
    const char *comment;
    int (*bind)(strim_config *cfg, const char *raw, char *err, size_t err_cap);
} strim_env_var;

static int env_containerd_socket(strim_config *c, const char *raw, char *err,
                                 size_t err_cap) {
    return bind_str(c->containerd_socket, sizeof c->containerd_socket, raw,
                    err, err_cap);
}
static int env_containerd_namespace(strim_config *c, const char *raw, char *err,
                                    size_t err_cap) {
    return bind_str(c->containerd_namespace, sizeof c->containerd_namespace,
                    raw, err, err_cap);
}
static int env_http_port(strim_config *c, const char *raw, char *err,
                         size_t err_cap) {
    return bind_str(c->controller_http_port, sizeof c->controller_http_port,
                    raw, err, err_cap);
}
static int env_host_root(strim_config *c, const char *raw, char *err,
                         size_t err_cap) {
    return bind_str(c->host_root, sizeof c->host_root, raw, err, err_cap);
}
static int env_reconcile_interval(strim_config *c, const char *raw, char *err,
                                  size_t err_cap) {
    return bind_duration_ms(&c->reconcile_interval_ms, raw, err, err_cap);
}
static int env_inflight_timeout(strim_config *c, const char *raw, char *err,
                                size_t err_cap) {
    return bind_duration_ms(&c->inflight_timeout_ms, raw, err, err_cap);
}
static int env_shutdown_timeout(strim_config *c, const char *raw, char *err,
                                size_t err_cap) {
    return bind_duration_ms(&c->shutdown_timeout_ms, raw, err, err_cap);
}
static int env_stage_stop_timeout(strim_config *c, const char *raw, char *err,
                                  size_t err_cap) {
    return bind_duration_ms(&c->stage_stop_timeout_ms, raw, err, err_cap);
}
static int env_ws_write_timeout(strim_config *c, const char *raw, char *err,
                                size_t err_cap) {
    return bind_duration_ms(&c->websocket_write_timeout_ms, raw, err, err_cap);
}
static int env_actions_buffer(strim_config *c, const char *raw, char *err,
                              size_t err_cap) {
    return bind_uint8(&c->actions_buffer_size, raw, err, err_cap);
}
static int env_single_stage(strim_config *c, const char *raw, char *err,
                            size_t err_cap) {
    return bind_bool(&c->enable_single_stage_pipeline, raw, err, err_cap);
}
static int env_mediamtx_id(strim_config *c, const char *raw, char *err,
                           size_t err_cap) {
    return bind_str(c->mediamtx.container_id, sizeof c->mediamtx.container_id,
                    raw, err, err_cap);
}
static int env_mediamtx_snapshot(strim_config *c, const char *raw, char *err,
                                 size_t err_cap) {
    return bind_str(c->mediamtx.snapshot_id, sizeof c->mediamtx.snapshot_id,
                    raw, err, err_cap);
}
static int env_mediamtx_image(strim_config *c, const char *raw, char *err,
                              size_t err_cap) {
    return bind_str(c->mediamtx.image_name, sizeof c->mediamtx.image_name, raw,
                    err, err_cap);
}
static int env_mediamtx_log(strim_config *c, const char *raw, char *err,
                            size_t err_cap) {
    return bind_str(c->mediamtx.logfile, sizeof c->mediamtx.logfile, raw, err,
                    err_cap);
}
static int env_normalize_id(strim_config *c, const char *raw, char *err,
                            size_t err_cap) {
    return bind_str(c->normalize.container_id, sizeof c->normalize.container_id,
                    raw, err, err_cap);
}
static int env_normalize_snapshot(strim_config *c, const char *raw, char *err,
                                  size_t err_cap) {
    return bind_str(c->normalize.snapshot_id,
                    sizeof c->normalize.snapshot_id, raw, err, err_cap);
}
static int env_normalize_log(strim_config *c, const char *raw, char *err,
                             size_t err_cap) {
    return bind_str(c->normalize.logfile, sizeof c->normalize.logfile, raw,
                    err, err_cap);
}
static int env_egress_id(strim_config *c, const char *raw, char *err,
                         size_t err_cap) {
    return bind_str(c->scale_and_egress.container_id,
                    sizeof c->scale_and_egress.container_id, raw, err, err_cap);
}
static int env_single_egress_id(strim_config *c, const char *raw, char *err,
                                size_t err_cap) {
    return bind_str(c->single_stage_egress.container_id,
                    sizeof c->single_stage_egress.container_id, raw, err,
                    err_cap);
}
static int env_egress_snapshot(strim_config *c, const char *raw, char *err,
                               size_t err_cap) {
    int rc = bind_str(c->scale_and_egress.snapshot_id,
                      sizeof c->scale_and_egress.snapshot_id, raw, err, err_cap);
    if (rc != 0) {
        return rc;
    }
    return bind_str(c->single_stage_egress.snapshot_id,
                    sizeof c->single_stage_egress.snapshot_id, raw, err,
                    err_cap);
}
static int env_egress_log(strim_config *c, const char *raw, char *err,
                          size_t err_cap) {
    int rc = bind_str(c->scale_and_egress.logfile,
                      sizeof c->scale_and_egress.logfile, raw, err, err_cap);
    if (rc != 0) {
        return rc;
    }
    return bind_str(c->single_stage_egress.logfile,
                    sizeof c->single_stage_egress.logfile, raw, err, err_cap);
}
static int env_ffmpeg_image(strim_config *c, const char *raw, char *err,
                            size_t err_cap) {
    int rc = bind_str(c->normalize.image_name, sizeof c->normalize.image_name,
                      raw, err, err_cap);
    if (rc != 0) {
        return rc;
    }
    rc = bind_str(c->scale_and_egress.image_name,
                  sizeof c->scale_and_egress.image_name, raw, err, err_cap);
    if (rc != 0) {
        return rc;
    }
    return bind_str(c->single_stage_egress.image_name,
                    sizeof c->single_stage_egress.image_name, raw, err, err_cap);
}

/* The env spec, in envspec.go order (groups are emitted in this order by
 * -print-env-example). Vars with bind == NULL are present/required guards
 * only (consumed by the mounted scripts, never by the controller). */
static const strim_env_var g_env_spec[] = {
    /* ---------------- Controller */
    {"CONTAINERD_SOCKET", "Controller", true, "/containerd.sock",
     "containerd gRPC socket the controller drives", env_containerd_socket},
    {"CONTAINERD_NAMESPACE", "Controller", true, "strimserver", NULL,
     env_containerd_namespace},
    {"CONTROLLER_HTTP_PORT", "Controller", true, "4000",
     "must match the Stream Deck plugin's base URL port", env_http_port},
    {"STRIMSERVER_HOST_ROOT", "Controller", true, "/mnt/nvme",
     "host dir where deploy.sh stages config/bin/video-files", env_host_root},
    {"CONTROLLER_RECONCILE_INTERVAL", "Controller", true, "5s",
     "how often the reconcile ticker fires (Go duration)",
     env_reconcile_interval},
    {"CONTROLLER_INFLIGHT_TIMEOUT", "Controller", true, "30s",
     "per-op timeout; after this an in-flight stage op is re-issued",
     env_inflight_timeout},
    {"CONTROLLER_SHUTDOWN_TIMEOUT", "Controller", true, "30s",
     "graceful HTTP shutdown budget", env_shutdown_timeout},
    {"STAGE_STOP_TIMEOUT", "Controller", true, "10s",
     "grace period after SIGTERM before a task is force-killed",
     env_stage_stop_timeout},
    {"WEBSOCKET_WRITE_TIMEOUT", "Controller", true, "5s",
     "per-message write deadline on /subscribe", env_ws_write_timeout},
    {"CONTROLLER_ACTIONS_BUFFER_SIZE", "Controller", true, "16",
     "buffered capacity of the actions channel (0-255)", env_actions_buffer},
    {"ENABLE_SINGLE_STAGE_PIPELINE", "Controller", false, "false",
     "feature toggle to enable single_stage_egress", env_single_stage},

    /* ---------------- Stage containers */
    {"MEDIAMTX_CONTAINER_ID", "Stage containers", true, "mediamtx", NULL,
     env_mediamtx_id},
    {"MEDIAMTX_SNAPSHOT_ID", "Stage containers", true, "mediamtx-snapshot",
     NULL, env_mediamtx_snapshot},
    {"MEDIAMTX_IMAGE_NAME", "Stage containers", true,
     "docker.io/library/mediamtx:latest", NULL, env_mediamtx_image},
    {"MEDIAMTX_LOG_FILE", "Stage containers", true,
     "/mnt/nvme/logs/mediamtx.log", NULL, env_mediamtx_log},
    {"NORMALIZE_CONTAINER_ID", "Stage containers", true, "normalize", NULL,
     env_normalize_id},
    {"NORMALIZE_SNAPSHOT_ID", "Stage containers", true, "normalize-snapshot",
     NULL, env_normalize_snapshot},
    {"NORMALIZE_LOG_FILE", "Stage containers", true,
     "/mnt/nvme/logs/normalize.log", NULL, env_normalize_log},
    {"EGRESS_CONTAINER_ID", "Stage containers", true, "scale-and-egress", NULL,
     env_egress_id},
    {"SINGLE_STAGE_EGRESS_CONTAINER_ID", "Stage containers", false,
     "single-stage-egress", NULL, env_single_egress_id},
    {"EGRESS_SNAPSHOT_ID", "Stage containers", true, "egress-snapshot", NULL,
     env_egress_snapshot},
    {"EGRESS_LOG_FILE", "Stage containers", true, "/mnt/nvme/logs/egress.log",
     NULL, env_egress_log},
    {"FFMPEG_IMAGE_NAME", "Stage containers", true,
     "docker.io/library/ffmpeg:latest",
     "shared by the normalize and scale_and_egress stages", env_ffmpeg_image},

    /* ---------------- Media / ffmpeg (required guards only) */
    {"FFMPEG_NICE", "Media / ffmpeg", true, "-5",
     "nice(1) level for the ffmpeg stages", NULL},
    {"FFMPEG_LOG_LEVEL", "Media / ffmpeg", true, "info", NULL, NULL},
    {"MEDIAMTX_NICE", "Media / ffmpeg", true, "-10", NULL, NULL},
    {"MEDIAMTX_CONFIG_TEMPLATE", "Media / ffmpeg", true,
     "/mediamtx.yaml.template",
     "in-container path of the bind-mounted template (envsubst input)", NULL},
    {"STRIMSERVER_SRT_PORT", "Media / ffmpeg", true, "9000",
     "SRT ingest port; must match the local encoder", NULL},
    {"STRIMSERVER_RTSP_PORT", "Media / ffmpeg", true, "8554",
     "internal RTSP port the stages read from", NULL},
    {"NORMALIZED_MPEGTS_SOCKET", "Media / ffmpeg", true,
     "/tmp/strimserver-normalized.sock",
     "unix socket: mediamtx listens, normalize ffmpeg connects", NULL},
    {"MEDIAMTX_READ_TIMEOUT_DURATION", "Media / ffmpeg", true, "12s",
     ">= SRT latency + jitter + read gap", NULL},
    {"NORMALIZED_VIDEO_BITRATE", "Media / ffmpeg", true, "9000k", NULL, NULL},
    {"NORMALIZED_VIDEO_MAXRATE", "Media / ffmpeg", true, "9000k", NULL, NULL},
    {"NORMALIZED_VIDEO_MINRATE", "Media / ffmpeg", true, "9000k", NULL, NULL},
    {"NORMALIZED_VIDEO_BUFSIZE", "Media / ffmpeg", true, "9000k", NULL, NULL},
    {"NORMALIZED_AUDIO_BITRATE", "Media / ffmpeg", true, "320k", NULL, NULL},
    {"SCALED_VIDEO_HEIGHT_PIXELS", "Media / ffmpeg", true, "936",
     "egress output height; width is derived (-2)", NULL},
    {"EGRESS_VIDEO_BITRATE", "Media / ffmpeg", true, "2500k", NULL, NULL},
    {"EGRESS_VIDEO_MAXRATE", "Media / ffmpeg", true, "2500k", NULL, NULL},
    {"EGRESS_VIDEO_MINRATE", "Media / ffmpeg", true, "2500k", NULL, NULL},
    {"EGRESS_VIDEO_BUFSIZE", "Media / ffmpeg", true, "2500k", NULL, NULL},
    {"EGRESS_AUDIO_BITRATE", "Media / ffmpeg", true, "160k", NULL, NULL},

    /* ---------------- Twitch / egress */
    {"TWITCH_INGEST_SERVER", "Twitch / egress", true,
     "ingest.global-contribute.live-video.net", NULL, NULL},
    {"TWITCH_STREAM_KEY", "Twitch / egress", true, "",
     "secret; leave EMPTY in bundled builds - injected at deploy time by "
     "deploy.sh", NULL},
    {"BANDWIDTH_TEST", "Twitch / egress", true, "false",
     "true appends ?bandwidthtest=true to the RTMP URL", NULL},

    /* ---------------- Secrets */
    {"SRT_PUBLISH_PASSPHRASE", "Secrets", false, "",
     "optional; falls back to /run/secrets/srt-passphrase if unset", NULL},
};

#define G_ENV_SPEC_COUNT (sizeof g_env_spec / sizeof g_env_spec[0])

/* -------------------------------------------------------------------------
 * -check-env (Go checkEnv): presence of every required var, nothing else.
 * ------------------------------------------------------------------------- */

static int check_env(char *err, size_t err_cap) {
    int n_missing = 0;
    err[0] = '\0';
    for (size_t i = 0; i < G_ENV_SPEC_COUNT; i++) {
        const strim_env_var *v = &g_env_spec[i];
        if (!v->required) {
            continue;
        }
        const char *raw = getenv(v->name);
        if (raw == NULL || raw[0] == '\0') {
            snprintf(err + strlen(err), err_cap - strlen(err),
                     "missing or empty: %s\n", v->name);
            n_missing++;
        }
    }
    return n_missing == 0 ? 0 : -1;
}

/* -------------------------------------------------------------------------
 * -print-env-example (Go printEnvExample) — values are %q-quoted exactly
 * like Go's fmt.Fprintf(w, "%s=%q\n", ...).
 * ------------------------------------------------------------------------- */

/* strconv.Quote for the env-example values (ASCII-safe; escapes the C string
 * like Go %q for a string). */
static void go_quote(const char *s, char *out, size_t cap) {
    static const char hex[] = "0123456789abcdef";
    const unsigned char *p = (const unsigned char *)s;
    size_t o = 0;

    if (out == NULL || cap == 0) {
        return;
    }
    out[o++] = '"';
    while (*p != '\0' && o + 8 < cap) {
        unsigned char c = *p++;
        switch (c) {
        case '"':
            out[o++] = '\\';
            out[o++] = '"';
            break;
        case '\\':
            out[o++] = '\\';
            out[o++] = '\\';
            break;
        case '\n':
            out[o++] = '\\';
            out[o++] = 'n';
            break;
        case '\r':
            out[o++] = '\\';
            out[o++] = 'r';
            break;
        case '\t':
            out[o++] = '\\';
            out[o++] = 't';
            break;
        default:
            if (c < 0x20 || c >= 0x7f) {
                out[o++] = '\\';
                out[o++] = 'x';
                out[o++] = hex[(c >> 4) & 0xf];
                out[o++] = hex[c & 0xf];
            } else {
                out[o++] = (char)c;
            }
            break;
        }
    }
    out[o++] = '"';
    out[o] = '\0';
}

static void print_env_example(void) {
    const char *last_group = NULL;
    for (size_t i = 0; i < G_ENV_SPEC_COUNT; i++) {
        const strim_env_var *v = &g_env_spec[i];
        char quoted[256];

        if (last_group == NULL || strcmp(v->group, last_group) != 0) {
            printf("\n# --- %s ---\n", v->group);
            last_group = v->group;
        }
        if (v->comment != NULL && v->comment[0] != '\0') {
            printf("# %s\n", v->comment);
        }
        go_quote(v->example, quoted, sizeof quoted);
        printf("%s=%s\n", v->name, quoted);
    }
}

/* -------------------------------------------------------------------------
 * -print-ts-types (Go printTSTypes) — byte-identical wire types
 * ------------------------------------------------------------------------- */

static void print_ts_types(void) {
    printf("// CODE GENERATED by `strimserver-controller -print-ts-types`. "
           "DO NOT EDIT.\n");
    printf("// Source of truth: core/controller/names.go + controller.go\n");
    printf("\n");
    printf("export type PathStatus = \"%s\" | \"%s\" | \"%s\";\n",
           STRIM_PATH_UNKNOWN_STR, STRIM_PATH_READY_STR,
           STRIM_PATH_NOT_READY_STR);
    printf("export type StageState = \"%s\" | \"%s\" | \"\";\n",
           STRIM_STAGE_RUNNING_STR, STRIM_STAGE_STOPPED_STR);
    printf("export type PathName  = \"%s\" | \"%s\";\n",
           STRIM_PATH_INGRESS0_STR, STRIM_PATH_NORMALIZED_STR);
    printf("export type StageName = \"%s\" | \"%s\" | \"%s\" | \"%s\";\n",
           STRIM_STAGE_MEDIA_MTX_STR, STRIM_STAGE_NORMALIZE_STR,
           STRIM_STAGE_SCALE_AND_EGRESS_STR,
           STRIM_STAGE_SINGLE_STAGE_EGRESS_STR);
    printf("\n");
    printf("export interface StageStatus { desired: StageState; actual: "
           "StageState; }\n");
    printf("export interface ControllerStatus {\n");
    printf("   paths: Record<PathName, PathStatus>;\n");
    printf("   stages: Record<StageName, StageStatus>;\n");
    printf("}\n");
    printf("\n");
    printf("export const Stages = { MediaMTX: \"%s\", Normalize: \"%s\", "
           "ScaleAndEgress: \"%s\", SingleStageEgress: \"%s\" } as const;\n",
           STRIM_STAGE_MEDIA_MTX_STR, STRIM_STAGE_NORMALIZE_STR,
           STRIM_STAGE_SCALE_AND_EGRESS_STR,
           STRIM_STAGE_SINGLE_STAGE_EGRESS_STR);
    printf("export type ControlComponent = \"%s\";\n",
           STRIM_COMPONENT_EGRESS_STR);
    printf("export type ControlAction    = \"%s\" | \"%s\";\n",
           STRIM_ACTION_START_STR, STRIM_ACTION_STOP_STR);
}

/* -------------------------------------------------------------------------
 * LoadConfig (Go LoadConfig): read + bind every env var, fail loud on a
 * missing required var or a parse error.
 * ------------------------------------------------------------------------- */

static int load_config(strim_config *cfg, char *err, size_t err_cap) {
    int n_errors = 0;
    memset(cfg, 0, sizeof *cfg);
    err[0] = '\0';

    for (size_t i = 0; i < G_ENV_SPEC_COUNT; i++) {
        const strim_env_var *v = &g_env_spec[i];
        const char *raw = getenv(v->name);
        if (raw == NULL || raw[0] == '\0') {
            if (v->required) {
                snprintf(err + strlen(err), err_cap - strlen(err),
                         "missing required env var \"%s\"\n", v->name);
                n_errors++;
            }
            continue;
        }
        if (v->bind != NULL) {
            char bind_err[256];
            bind_err[0] = '\0';
            if (v->bind(cfg, raw, bind_err, sizeof bind_err) != 0) {
                snprintf(err + strlen(err), err_cap - strlen(err),
                         "could not parse \"%s\" = \"%s\": %s\n", v->name, raw,
                         bind_err);
                n_errors++;
            }
        }
    }
    return n_errors == 0 ? 0 : -1;
}

/* =========================================================================
 * Env-file sourcing (the old entrypoint.sh: `set -a; . /strimserver.env;
 * set +a`). The file is a KEY="value" listing generated from envspec.go's
 * %q; this parser handles comments, blanks, optional `export` prefixes, and
 * double-quoted values (no shell interpolation — values are plain).
 * ------------------------------------------------------------------------- */

#define STRIM_ENV_LINE_MAX 4096

static int source_env_file(const char *path, char *err, size_t err_cap) {
    FILE *f;
    char line[STRIM_ENV_LINE_MAX];

    f = fopen(path, "r");
    if (f == NULL) {
        return 0; /* absent: process env only (Go run() has no env file) */
    }
    while (fgets(line, sizeof line, f) != NULL) {
        char *p = line;
        char *eq;
        char *name;
        char *value;

        /* Trim leading whitespace. */
        while (*p == ' ' || *p == '\t') {
            p++;
        }
        if (*p == '\0' || *p == '\n' || *p == '\r' || *p == '#') {
            continue; /* blank or comment */
        }
        if (strncmp(p, "export ", 7) == 0) {
            p += 7;
            while (*p == ' ' || *p == '\t') {
                p++;
            }
        }
        name = p;
        eq = strchr(p, '=');
        if (eq == NULL) {
            snprintf(err, err_cap, "malformed line in %s: %s", path, line);
            fclose(f);
            return -1;
        }
        *eq = '\0';
        value = eq + 1;

        /* Trim trailing whitespace / newline from the name. */
        {
            char *q = name + strlen(name);
            while (q > name && (q[-1] == ' ' || q[-1] == '\t')) {
                *--q = '\0';
            }
        }
        /* Strip surrounding double quotes from the value. */
        {
            size_t vlen = strlen(value);
            while (vlen > 0 && (value[vlen - 1] == '\n' ||
                                value[vlen - 1] == '\r')) {
                value[--vlen] = '\0';
            }
            if (vlen >= 2 && value[0] == '"' && value[vlen - 1] == '"') {
                value[vlen - 1] = '\0';
                value++;
            }
        }
        if (name[0] == '\0') {
            snprintf(err, err_cap, "malformed line in %s: %s", path, line);
            fclose(f);
            return -1;
        }
        if (setenv(name, value, 1) != 0) {
            snprintf(err, err_cap, "setenv(%s) failed in %s", name, path);
            fclose(f);
            return -1;
        }
    }
    fclose(f);
    return 0;
}

/* =========================================================================
 * ControllerStatus serialization + the HTTP callback bundle
 * ========================================================================= */

/* Serialize the controller status the way Go's encoding/json emits the
 * ControllerStatus map (keys sorted: ingress0, normalized; mediamtx,
 * normalize, scale_and_egress, single_stage_egress). No trailing newline —
 * the caller decides (handle_status appends '\n' like json.NewEncoder; the
 * ws listener mirrors the HTTP lane's stub which pushes the same bytes). */
static int serialize_status(const strim_controller_status *st, char *buf,
                            size_t cap, size_t *out_len) {
    int n;

    if (st == NULL || buf == NULL || out_len == NULL) {
        return -1;
    }
    n = snprintf(
        buf, cap,
        "{\"paths\":{\"%s\":\"%s\",\"%s\":\"%s\"},"
        "\"stages\":{"
        "\"%s\":{\"desired\":\"%s\",\"actual\":\"%s\"},"
        "\"%s\":{\"desired\":\"%s\",\"actual\":\"%s\"},"
        "\"%s\":{\"desired\":\"%s\",\"actual\":\"%s\"},"
        "\"%s\":{\"desired\":\"%s\",\"actual\":\"%s\"}}}",
        STRIM_PATH_INGRESS0_STR,
        strim_path_status_to_string(st->paths[STRIM_PATH_INGRESS0]),
        STRIM_PATH_NORMALIZED_STR,
        strim_path_status_to_string(st->paths[STRIM_PATH_NORMALIZED]),
        STRIM_STAGE_MEDIA_MTX_STR,
        strim_stage_state_to_string(st->stages[STRIM_STAGE_MEDIA_MTX].desired),
        strim_stage_state_to_string(st->stages[STRIM_STAGE_MEDIA_MTX].actual),
        STRIM_STAGE_NORMALIZE_STR,
        strim_stage_state_to_string(st->stages[STRIM_STAGE_NORMALIZE].desired),
        strim_stage_state_to_string(st->stages[STRIM_STAGE_NORMALIZE].actual),
        STRIM_STAGE_SCALE_AND_EGRESS_STR,
        strim_stage_state_to_string(
            st->stages[STRIM_STAGE_SCALE_AND_EGRESS].desired),
        strim_stage_state_to_string(
            st->stages[STRIM_STAGE_SCALE_AND_EGRESS].actual),
        STRIM_STAGE_SINGLE_STAGE_EGRESS_STR,
        strim_stage_state_to_string(
            st->stages[STRIM_STAGE_SINGLE_STAGE_EGRESS].desired),
        strim_stage_state_to_string(
            st->stages[STRIM_STAGE_SINGLE_STAGE_EGRESS].actual));
    if (n < 0 || (size_t)n >= cap) {
        return -1;
    }
    *out_len = (size_t)n;
    return 0;
}

/* HTTP callback userdata: the controller handle. The server passes it to
 * every callback (http_server.c srv->userdata). */
typedef struct strim_http_ctx {
    strim_controller *controller;
} strim_http_ctx;

/* Fetch a required string member of the request object. Returns 1 + *out on
 * success; 0 when the member is missing (Go zero value → handler error, 500);
 * -1 when the member is present but not a string (Go json decode error →
 * 400). */
static int json_obj_string(yyjson_val *root, const char *key, const char **out) {
    yyjson_val *v = yyjson_obj_get(root, key);
    if (v == NULL) {
        return 0; /* missing */
    }
    if (!yyjson_is_str(v)) {
        return -1; /* wrong type → 400 (bad json) */
    }
    *out = yyjson_get_str(v);
    return 1;
}

/* Parse + apply a /event body (main.go postJSON SubmitPathEvent). Returns 0
 * on success, STRIM_HTTP_ERR_BADJSON on a JSON syntax/type error (400), or a
 * positive/negative handler error (500) with err text. */
static int http_handle_event(void *userdata, const uint8_t *body, size_t len,
                             char *err, size_t err_cap) {
    strim_http_ctx *hctx = userdata;
    yyjson_doc *doc = NULL;
    yyjson_val *root;
    const char *s;
    int have;
    strim_path_event ev;

    doc = yyjson_read((const char *)body, len, 0);
    if (doc == NULL) {
        snprintf(err, err_cap, "invalid JSON body");
        return STRIM_HTTP_ERR_BADJSON;
    }
    root = yyjson_doc_get_root(doc);
    if (!yyjson_is_obj(root)) {
        yyjson_doc_free(doc);
        snprintf(err, err_cap, "expected a JSON object");
        return STRIM_HTTP_ERR_BADJSON;
    }

    ev.path = (strim_path_name)(-1);
    ev.status = (strim_path_status)(-1);

    have = json_obj_string(root, "path", &s);
    if (have < 0) {
        yyjson_doc_free(doc);
        snprintf(err, err_cap, "path is not a string");
        return STRIM_HTTP_ERR_BADJSON;
    }
    if (have > 0 && strim_path_name_from_string(s, &ev.path) != 0) {
        yyjson_doc_free(doc);
        snprintf(err, err_cap, "invalid path name: %s", s);
        return -1;
    }

    have = json_obj_string(root, "status", &s);
    if (have < 0) {
        yyjson_doc_free(doc);
        snprintf(err, err_cap, "status is not a string");
        return STRIM_HTTP_ERR_BADJSON;
    }
    if (have > 0 && strim_path_status_from_string(s, &ev.status) != 0) {
        yyjson_doc_free(doc);
        snprintf(err, err_cap, "invalid path status: %s", s);
        return -1;
    }
    yyjson_doc_free(doc);

    {
        int rc = strim_controller_submit_path_event(hctx->controller, &ev);
        if (rc != 0) {
            snprintf(err, err_cap, "could not handle path event");
            return rc;
        }
    }
    return 0;
}

/* Parse + apply a /control body (main.go postJSON SubmitControl). */
static int http_handle_control(void *userdata, const uint8_t *body, size_t len,
                               char *err, size_t err_cap) {
    strim_http_ctx *hctx = userdata;
    yyjson_doc *doc = NULL;
    yyjson_val *root;
    const char *s;
    int have;
    strim_control_command cmd;

    doc = yyjson_read((const char *)body, len, 0);
    if (doc == NULL) {
        snprintf(err, err_cap, "invalid JSON body");
        return STRIM_HTTP_ERR_BADJSON;
    }
    root = yyjson_doc_get_root(doc);
    if (!yyjson_is_obj(root)) {
        yyjson_doc_free(doc);
        snprintf(err, err_cap, "expected a JSON object");
        return STRIM_HTTP_ERR_BADJSON;
    }

    cmd.component = (strim_control_component)(-1);
    cmd.action = (strim_control_action)(-1);

    have = json_obj_string(root, "component", &s);
    if (have < 0) {
        yyjson_doc_free(doc);
        snprintf(err, err_cap, "component is not a string");
        return STRIM_HTTP_ERR_BADJSON;
    }
    if (have > 0 && strim_control_component_from_string(s, &cmd.component) != 0) {
        yyjson_doc_free(doc);
        snprintf(err, err_cap, "unknown control component: %s", s);
        return -1;
    }

    have = json_obj_string(root, "action", &s);
    if (have < 0) {
        yyjson_doc_free(doc);
        snprintf(err, err_cap, "action is not a string");
        return STRIM_HTTP_ERR_BADJSON;
    }
    if (have > 0 && strim_control_action_from_string(s, &cmd.action) != 0) {
        yyjson_doc_free(doc);
        snprintf(err, err_cap, "unknown control action: %s", s);
        return -1;
    }
    yyjson_doc_free(doc);

    {
        int rc = strim_controller_submit_control(hctx->controller, &cmd);
        if (rc != 0) {
            snprintf(err, err_cap, "could not handle control");
            return rc;
        }
    }
    return 0;
}

/* /status: submit_status snapshot → JSON + trailing '\n' (Go json.NewEncoder,
 * http_server.c ROUTE_STATUS expects the same bytes as the lane stub). */
static int http_handle_status(void *userdata, uint8_t *out, size_t cap,
                              size_t *out_len) {
    strim_http_ctx *hctx = userdata;
    strim_controller_status st;
    size_t len;

    if (strim_controller_submit_status(hctx->controller, &st) != 0) {
        return -1;
    }
    if (serialize_status(&st, (char *)out, cap, &len) != 0) {
        return -1;
    }
    if (len + 1 >= cap) {
        return -1; /* no room for the trailing '\n' */
    }
    out[len++] = (uint8_t)'\n';
    *out_len = len;
    return 0;
}

/* request_reconcile after a successful /event or /control (main.go:383). */
static void http_request_reconcile(void *userdata) {
    strim_http_ctx *hctx = userdata;
    strim_controller_request_reconcile(hctx->controller);
}

/* The ws listener the controller invokes on status changes (main.go:251-259):
 * serialize + push through the HTTP lane's 1-deep slot (latest-wins). */
static void ws_status_listener(const strim_controller_status *status,
                               void *userdata) {
    int client_idx = (int)(intptr_t)userdata;
    char json[STRIM_HTTP_STATUS_MAX];
    size_t len;

    if (serialize_status(status, json, sizeof json, &len) != 0) {
        return;
    }
    if (len + 1 >= sizeof json) {
        return;
    }
    json[len++] = '\n';
    strim_http_ws_send(userdata, client_idx, (const uint8_t *)json, len);
}

/* ws_subscribe / ws_unsubscribe (main.go:261-274): register/remove the ws
 * client's listener on the controller action queue. The listener userdata is
 * the client index (opaque to the controller; cast back in the listener). */
static int http_ws_subscribe(void *userdata, int client_idx) {
    strim_http_ctx *hctx = userdata;
    return strim_controller_submit_add_listener(
        hctx->controller, ws_status_listener, (void *)(intptr_t)client_idx);
}

static int http_ws_unsubscribe(void *userdata, int client_idx) {
    strim_http_ctx *hctx = userdata;
    return strim_controller_submit_remove_listener(
        hctx->controller, ws_status_listener, (void *)(intptr_t)client_idx);
}

static void fill_http_callbacks(strim_http_callbacks *cbs) {
    memset(cbs, 0, sizeof *cbs);
    cbs->handle_event = http_handle_event;
    cbs->handle_control = http_handle_control;
    cbs->handle_status = http_handle_status;
    cbs->request_reconcile = http_request_reconcile;
    cbs->ws_subscribe = http_ws_subscribe;
    cbs->ws_unsubscribe = http_ws_unsubscribe;
    cbs->ws_send = strim_http_ws_send; /* the HTTP lane's slot (internal.h) */
}

/* =========================================================================
 * Container factory + stage ops (container_factory.go CreateContainerOps)
 * ========================================================================= */

/* The CDI device reference every ffmpeg stage is created with
 * (container_factory.go:151). */
#define STRIM_FFMPEG_CDI_DEVICE "nvidia.com/gpu=0"

/* One stage's op context — the fixed-arity stand-in for the Go closures
 * (createFunc / lookupFunc / stageNames / layout). Self-contained: strings
 * are copied in at init, so it outlives the config object. */
typedef struct strim_stage_ops {
    strim_containerd_client *client;
    char  container_id[STRIM_CFG_ID_MAX];
    char  snapshot_id[STRIM_CFG_SNAP_MAX];
    char  image_name[STRIM_CFG_IMAGE_MAX];
    char  logfile[STRIM_CFG_PATH_MAX];
    strim_stage_name stage;
    bool  ffmpeg; /* true: ffmpeg mounts + stage argv + CDI; false: mediamtx */
    strim_layout layout;
    const strim_stage_table_entry *stage_table;
    size_t n_stage_table;
    int64_t stage_stop_timeout_ms;
} strim_stage_ops;

static void init_stage_ops(strim_stage_ops *ops, strim_containerd_client *client,
                           const strim_container_config *cfg,
                           strim_stage_name stage, bool ffmpeg,
                           const strim_layout *layout,
                           const strim_stage_table_entry *table,
                           size_t n_table, int64_t stop_timeout_ms) {
    memset(ops, 0, sizeof *ops);
    ops->client = client;
    strncpy(ops->container_id, cfg->container_id, sizeof ops->container_id - 1);
    strncpy(ops->snapshot_id, cfg->snapshot_id, sizeof ops->snapshot_id - 1);
    strncpy(ops->image_name, cfg->image_name, sizeof ops->image_name - 1);
    strncpy(ops->logfile, cfg->logfile, sizeof ops->logfile - 1);
    ops->stage = stage;
    ops->ffmpeg = ffmpeg;
    ops->layout = *layout;
    ops->stage_table = table;
    ops->n_stage_table = n_table;
    ops->stage_stop_timeout_ms = stop_timeout_ms;
}

/* The op's RPC budget: the inflight timeout bounded by the fire's remaining
 * deadline (the Go select: the op's own time.After vs ctx.Done()). A NULL
 * cancel (the Teardown path) has no deadline — fall back to the plain
 * timeout. A non-positive budget means the deadline already passed; the op
 * must abort. */
static int64_t op_rpc_budget(const strim_stage_op_cancel *cancel,
                             int64_t timeout_ms) {
    int64_t remaining = strim_stage_op_remaining_ms(cancel);
    if (remaining < 0) {
        return timeout_ms; /* no deadline */
    }
    return remaining < timeout_ms ? remaining : timeout_ms;
}

/* Safe-point guard: a timed-out retry superseded this fire (its generation
 * token moved on). Log + abort as a no-op (return 0) — the newer op owns the
 * stage, and reporting failure would clear InFlight and unblock a third op. */
static int op_superseded_abort(const strim_stage_ops *ops,
                               const strim_stage_op_cancel *cancel) {
    if (strim_stage_op_superseded(cancel)) {
        logmsg("%s op superseded by a newer reconcile; aborting",
               strim_stage_name_to_string(ops->stage));
        return 1;
    }
    return 0;
}

/* The waiter thread for the stop path (container_factory.go:203-213): run
 * task_wait on its own thread while the controller thread sends Kill. */
typedef struct strim_task_waiter {
    strim_task *task;
    int64_t timeout_ms;
    int32_t exit_code;
    int rc;
} strim_task_waiter;

static void *task_wait_thread(void *arg) {
    strim_task_waiter *w = arg;
    w->rc = strim_containerd_task_wait(w->task, w->timeout_ms, &w->exit_code);
    return NULL;
}

/* The stop op (Go CreateContainerOps stop): load the container, then its
 * task; subscribe the exit BEFORE SIGTERM (graceful), force-delete on
 * timeout; finally delete the container with snapshot cleanup. The op aborts
 * as a no-op at safe points when a timed-out retry superseded it, and bounds
 * the grace period by the fire's remaining deadline. */
static int stage_stop_op(void *op_ctx, int64_t timeout_ms,
                         const strim_stage_op_cancel *cancel) {
    strim_stage_ops *ops = op_ctx;
    strim_container *container = NULL;
    strim_task *task = NULL;
    strim_task_waiter w;
    pthread_t waiter_tid;
    int64_t budget_ms;
    int64_t wait_ms;
    int rc;

    if (ops == NULL || ops->client == NULL) {
        return -1; /* containerd unavailable; fail fast, reconcile retries */
    }

    /* Safe point: a newer fire (timed-out retry) superseded this op. */
    if (op_superseded_abort(ops, cancel)) {
        return 0;
    }

    budget_ms = op_rpc_budget(cancel, timeout_ms);
    if (budget_ms <= 0) {
        logmsg("%s stop op deadline expired; aborting",
               strim_stage_name_to_string(ops->stage));
        return -1; /* failure clears InFlight; the next reconcile retries */
    }

    rc = strim_containerd_load_container(ops->client, ops->container_id,
                                         &container);
    if (rc == STRIM_CTRD_ERR_NOTFOUND) {
        logmsg("%s container not found, could not delete, continuing...",
               strim_stage_name_to_string(ops->stage));
        return 0;
    }
    if (rc != 0) {
        log_rpc_failure("could not load %s container for deletion: %d",
                        strim_stage_name_to_string(ops->stage), rc,
                        ops->client);
        return rc;
    }

    if (op_superseded_abort(ops, cancel)) {
        return 0;
    }

    rc = strim_containerd_load_task(container, &task);
    if (rc == STRIM_CTRD_ERR_NOTFOUND) {
        logmsg("%s task not found, could not delete, continuing...",
               strim_stage_name_to_string(ops->stage));
        rc = strim_containerd_delete_container(container, 1);
        if (rc != 0) {
            log_rpc_failure("could not delete %s container: %d",
                            strim_stage_name_to_string(ops->stage), rc,
                            ops->client);
        }
        return rc == 0 ? 0 : rc;
    }
    if (rc != 0) {
        log_rpc_failure("could not load %s task for deletion: %d",
                        strim_stage_name_to_string(ops->stage), rc,
                        ops->client);
        return rc;
    }

    if (op_superseded_abort(ops, cancel)) {
        return 0;
    }

    /* The grace period is the earlier of the stage-stop timeout and the op's
     * remaining budget (Go select: time.After(gracefulStopTimeout) vs
     * ctx.Done(); both paths force-delete). */
    wait_ms = ops->stage_stop_timeout_ms;
    if (budget_ms > 0 && budget_ms < wait_ms) {
        wait_ms = budget_ms;
    }

    memset(&w, 0, sizeof w);
    w.task = task;
    w.timeout_ms = wait_ms;
    if (pthread_create(&waiter_tid, NULL, task_wait_thread, &w) != 0) {
        return -1;
    }

    if (op_superseded_abort(ops, cancel)) {
        /* Superseded before signalling: a newer op owns the task — do NOT
         * kill. Join the waiter (bounded by wait_ms) so we never leak a
         * thread, then report a no-op. */
        pthread_join(waiter_tid, NULL);
        return 0;
    }

    rc = strim_containerd_task_kill(task, STRIM_CTRD_KILL_SIGTERM);
    if (rc != 0) {
        /* Go: Kill error (non-NotFound) → return; the exit subscription is
         * abandoned. Join the waiter so we never leak a thread. */
        pthread_join(waiter_tid, NULL);
        log_rpc_failure("could not signal %s task: %d",
                        strim_stage_name_to_string(ops->stage), rc,
                        ops->client);
        return rc;
    }

    pthread_join(waiter_tid, NULL);

    if (op_superseded_abort(ops, cancel)) {
        /* The task exited, but a newer op owns the stage — do not delete. */
        return 0;
    }

    if (w.rc == 0) {
        logmsg("%s task exited gracefully, exit code: %d",
               strim_stage_name_to_string(ops->stage), w.exit_code);
        rc = strim_containerd_task_delete(task, 0);
        if (rc != 0) {
            log_rpc_failure("could not delete %s task after graceful exit: %d",
                            strim_stage_name_to_string(ops->stage), rc,
                            ops->client);
            return rc;
        }
    } else if (w.rc == STRIM_CTRD_ERR_TIMEOUT) {
        logmsg("%s task did not exit within grace period, forcing kill",
               strim_stage_name_to_string(ops->stage));
        rc = strim_containerd_task_delete(task, 1);
        if (rc != 0) {
            log_rpc_failure("could not force-delete %s task: %d",
                            strim_stage_name_to_string(ops->stage), rc,
                            ops->client);
            return rc;
        }
    } else if (w.rc == STRIM_CTRD_ERR_NOTFOUND) {
        /* Already gone (Go Wait NotFound → nil); fall through to delete the
         * container. */
    } else {
        logmsg("could not wait on %s task: %d",
               strim_stage_name_to_string(ops->stage), w.rc);
        return w.rc;
    }

    if (op_superseded_abort(ops, cancel)) {
        return 0;
    }

    rc = strim_containerd_delete_container(container, 1);
    if (rc != 0) {
        log_rpc_failure("could not delete %s container: %d",
                        strim_stage_name_to_string(ops->stage), rc,
                        ops->client);
        return rc;
    }
    logmsg("%s container deleted", strim_stage_name_to_string(ops->stage));
    return 0;
}

/* Resolve + stage the ffmpeg CDI device so the NEXT new_container call picks
 * up the pending edits (cdi.WithCDIDevices, container_factory.go:151). */
static int prepare_ffmpeg_cdi(const strim_spec *spec) {
    strim_cdi_ref ref;
    uint32_t n_devices = 0;

    if (strim_cdi_ref_parse(STRIM_FFMPEG_CDI_DEVICE, &ref) != 0) {
        return -1;
    }
    if (strim_cdi_scan() != 0) {
        return -1;
    }
    if (strim_cdi_resolve(&ref, &n_devices) != 0) {
        return -1;
    }
    return strim_cdi_merge_edits((strim_spec *)spec);
}

/* The start op (Go CreateContainerOps start): stop first (cleanup), create
 * the container (ffmpeg: stage argv + CDI; mediamtx: image entrypoint), then
 * task + start. The op aborts as a no-op at safe points when a timed-out
 * retry superseded it, and bounds its RPCs by the fire's remaining deadline. */
static int stage_start_op(void *op_ctx, int64_t timeout_ms,
                          const strim_stage_op_cancel *cancel) {
    strim_stage_ops *ops = op_ctx;
    strim_container *container = NULL;
    strim_task *task = NULL;
    strim_spec spec;
    strim_mount mounts[STRIM_SPEC_MAX_MOUNTS];
    char argv0[64];
    char argv1[64];
    const char *args[2];
    int n_mounts;
    int64_t budget_ms;
    int rc;

    if (ops == NULL || ops->client == NULL) {
        logmsg("could not create %s container: containerd client unavailable",
               ops != NULL ? strim_stage_name_to_string(ops->stage)
                           : "stage");
        return -1; /* containerd unavailable; fail fast, reconcile retries */
    }

    /* Safe point: a newer fire (timed-out retry) superseded this op. */
    if (op_superseded_abort(ops, cancel)) {
        return 0;
    }

    budget_ms = op_rpc_budget(cancel, timeout_ms);
    if (budget_ms <= 0) {
        logmsg("%s start op deadline expired; aborting",
               strim_stage_name_to_string(ops->stage));
        return -1; /* failure clears InFlight; the next reconcile retries */
    }

    /* Go: start() begins with stop(ctx) — clean up any existing container
     * and task before recreating. The inner stop shares this fire's budget
     * and cancellation. */
    rc = stage_stop_op(ops, budget_ms, cancel);
    if (rc != 0) {
        logmsg("could not clean up %s before start: %d",
               strim_stage_name_to_string(ops->stage), rc);
        return rc;
    }

    if (op_superseded_abort(ops, cancel)) {
        return 0;
    }

    memset(&spec, 0, sizeof spec);
    spec.process.capabilities = strim_spec_added_capabilities;
    spec.process.n_capabilities = 1; /* CAP_SYS_NICE (baseSpecOpts) */
    spec.host_network = true;        /* WithHostNamespace(NetworkNamespace) */
    spec.cgroups_path = NULL;        /* derived: "/<ns>/<container-id>" */

    if (ops->ffmpeg) {
        if (strim_stage_argv(ops->stage_table, ops->n_stage_table,
                             ops->container_id, argv0, sizeof argv0, argv1,
                             sizeof argv1) != 0) {
            logmsg("could not build %s stage argv",
                   strim_stage_name_to_string(ops->stage));
            return -1;
        }
        args[0] = argv0; /* /transcode.sh */
        args[1] = argv1; /* the stage wire name */
        spec.process.args = args;
        spec.process.n_args = 2;

        n_mounts = strim_ffmpeg_mounts(&ops->layout, mounts,
                                       STRIM_SPEC_MAX_MOUNTS);
        if (prepare_ffmpeg_cdi(&spec) != 0) {
            logmsg("could not resolve %s for %s (CDI)",
                   STRIM_FFMPEG_CDI_DEVICE,
                   strim_stage_name_to_string(ops->stage));
            return -1;
        }
    } else {
        /* mediamtx: no args — the image entrypoint/cmd runs. */
        n_mounts = strim_mediamtx_mounts(&ops->layout, mounts,
                                         STRIM_SPEC_MAX_MOUNTS);
    }
    if (n_mounts < 0) {
        logmsg("could not build %s mount list: %d",
               strim_stage_name_to_string(ops->stage), n_mounts);
        return n_mounts;
    }
    spec.mounts = mounts;
    spec.n_mounts = (size_t)n_mounts;

    if (op_superseded_abort(ops, cancel)) {
        return 0;
    }

    rc = strim_containerd_new_container(ops->client, ops->container_id,
                                        ops->snapshot_id, ops->image_name,
                                        &spec, &container);
    if (rc != 0) {
        log_rpc_failure("could not create %s container: %d",
                        strim_stage_name_to_string(ops->stage), rc,
                        ops->client);
        return rc;
    }

    if (op_superseded_abort(ops, cancel)) {
        return 0;
    }

    rc = strim_containerd_new_task(container, ops->logfile, &task);
    if (rc != 0) {
        log_rpc_failure("could not create %s task: %d",
                        strim_stage_name_to_string(ops->stage), rc,
                        ops->client);
        return rc;
    }

    if (op_superseded_abort(ops, cancel)) {
        return 0;
    }

    rc = strim_containerd_task_start(task);
    if (rc != 0) {
        log_rpc_failure("could not start %s task: %d",
                        strim_stage_name_to_string(ops->stage), rc,
                        ops->client);
        return rc;
    }
    return 0;
}

/* =========================================================================
 * Routes — the prerequisite gate (main.go:179-202)
 * ========================================================================= */

/* createPathReadyPrerequisite(PathIngress0): the egress start command is
 * rejected until the ingress0 path is ready. Runs on the action-queue thread
 * (applyDesiredStageTarget), so handle_status is directly callable. */
static int prereq_ingress0_ready(strim_controller *c, void *userdata) {
    strim_controller_status st;
    (void)userdata;
    if (c == NULL || strim_controller_handle_status(c, &st) != 0) {
        return -1;
    }
    return st.paths[STRIM_PATH_INGRESS0] == STRIM_PATH_READY ? 0 : -1;
}

/* =========================================================================
 * Threads + shutdown (main.go:313-365)
 * ========================================================================= */

static volatile sig_atomic_t g_sig_flag = 0; /* set by the signal handler */
static volatile int g_http_fatal = 0;         /* set by the http service thread */

static void on_shutdown_signal(int signo) {
    (void)signo;
    g_sig_flag = 1; /* async-signal-safe */
}

static void install_signal_handlers(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_shutdown_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
}

static void sleep_ms(int64_t ms) {
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
}

static void *controller_thread_fn(void *arg) {
    strim_controller_run((strim_controller *)arg);
    return NULL;
}

/* The HTTP server service loop (main.go:335-342): runs until shutdown
 * requested; a fatal server error wakes main so it shuts everything down
 * (Go's stop() on ListenAndServe error). */
typedef struct strim_http_thread_arg {
    strim_http_server *server;
} strim_http_thread_arg;

static void *http_service_thread_fn(void *arg) {
    strim_http_thread_arg *ha = arg;
    int rc = strim_http_server_service(ha->server, -1);
    if (rc != 0) {
        logmsg("http server error: %d", rc);
        g_http_fatal = 1;
    }
    return NULL;
}

/* The containerd event listener (container_factory.go:297-341): subscribe to
 * topic~="/tasks/.*" and map TaskStart → Running / TaskExit → Stopped for the
 * configured stages. next() is polled with a bounded timeout so shutdown is
 * responsive (the Go select on ctx.Done). */
typedef struct strim_listener_arg {
    strim_containerd_client *client;
    strim_controller *controller;
    const strim_stage_table_entry *stage_table;
    size_t n_stage_table;
} strim_listener_arg;

static void *containerd_listener_thread_fn(void *arg) {
    strim_listener_arg *la = arg;
    const char *filters[] = { "topic~=\"/tasks/.*\"" };
    strim_event_stream *stream = NULL;
    int rc;

    if (la->client == NULL) {
        logmsg("containerd client unavailable; event listener not started");
        return NULL;
    }

    rc = strim_containerd_subscribe(la->client, filters, 1, &stream);
    if (rc != 0) {
        logmsg("could not subscribe to containerd events: %d", rc);
        return NULL;
    }

    while (!g_sig_flag) {
        strim_event_envelope *env = NULL;
        strim_event_kind kind;
        strim_stage_name stage;
        strim_stage_event sev;
        char cid[STRIM_CFG_ID_MAX];
        int n;
        size_t i;

        rc = strim_event_stream_next(stream, 250, &env);
        if (rc == STRIM_CTRD_ERR_TIMEOUT) {
            continue; /* poll slice; re-check shutdown */
        }
        if (rc == STRIM_CTRD_ERR_CLOSED) {
            break;
        }
        if (rc != 0) {
            /* STRIM_CTRD_ERR_IO and friends: the Go error channel — the
             * listener exits (container_factory.go:333-336). */
            logmsg("containerd event stream error: %d", rc);
            break;
        }

        kind = strim_event_get_kind(env);
        if (kind != STRIM_EVENT_TASK_START && kind != STRIM_EVENT_TASK_EXIT) {
            continue;
        }

        n = strim_event_container_id(env, cid, sizeof cid);
        if (n < 0) {
            logmsg("received %s event without a container id",
                   kind == STRIM_EVENT_TASK_START ? "TaskStart" : "TaskExit");
            continue;
        }

        stage = (strim_stage_name)(-1);
        for (i = 0; i < la->n_stage_table; i++) {
            if (strcmp(la->stage_table[i].container_id, cid) == 0) {
                stage = la->stage_table[i].stage;
                break;
            }
        }
        if (stage == (strim_stage_name)(-1)) {
            logmsg("received %s event, but not associated with any stage: %s",
                   kind == STRIM_EVENT_TASK_START ? "TaskStart" : "TaskExit",
                   cid);
            continue;
        }

        sev.stage = stage;
        sev.state = (kind == STRIM_EVENT_TASK_START) ? STRIM_STAGE_RUNNING
                                                     : STRIM_STAGE_STOPPED;
        {
            int src = strim_controller_submit_stage_event(la->controller, &sev);
            if (src != 0) {
                logmsg("could not handle %s event: %d",
                       kind == STRIM_EVENT_TASK_START ? "TaskStart"
                                                      : "TaskExit",
                       src);
            }
        }
    }

    strim_event_stream_close(stream);
    return NULL;
}

/* The reconcile ticker (main.go invokeReconcileEvery): request_reconcile
 * every interval; stops on shutdown. */
typedef struct strim_ticker_arg {
    strim_controller *controller;
    int64_t interval_ms;
} strim_ticker_arg;

static void *reconcile_ticker_thread_fn(void *arg) {
    strim_ticker_arg *ta = arg;

    while (!g_sig_flag) {
        int64_t waited = 0;
        while (waited < ta->interval_ms && !g_sig_flag) {
            sleep_ms(100);
            waited += 100;
        }
        if (!g_sig_flag) {
            strim_controller_request_reconcile(ta->controller);
        }
    }
    return NULL;
}

/* =========================================================================
 * run() — the Go run() lifecycle (main.go:132-366)
 * ========================================================================= */

static int run(void) {
    strim_config cfg;
    char err[1024];
    strim_containerd_client *client = NULL;
    strim_stage_table_entry stage_table[4];
    size_t n_stage_table = 0;
    strim_layout layout;
    strim_stage_ops mediamtx_ops;
    strim_stage_ops normalize_ops;
    strim_stage_ops egress_ops;
    strim_stage_ops single_ops;
    strim_route path_routes[2];
    strim_route control_routes[2];
    size_t n_path_routes = 0;
    size_t n_control_routes = 0;
    strim_controller_config cc;
    strim_controller *controller = NULL;
    strim_http_ctx hctx;
    strim_http_callbacks cbs;
    char addr[64];
    strim_http_server *server = NULL;
    pthread_t controller_tid;
    pthread_t http_tid;
    pthread_t listener_tid;
    pthread_t ticker_tid;
    strim_http_thread_arg http_arg;
    strim_listener_arg listener_arg;
    strim_ticker_arg ticker_arg;
    int rc;

    /* -- config ---------------------------------------------------------- */
    if (load_config(&cfg, err, sizeof err) != 0) {
        logmsg("could not load config:\n%s", err);
        return 1;
    }
    if (cfg.reconcile_interval_ms <= 0) {
        logmsg("could not load config: reconcile interval must be positive");
        return 1;
    }

    install_signal_handlers();

    /* -- containerd client (Go containerd.New). strim_containerd_connect is
     *    LAZY, exactly like Go: it never dials the socket, so a down daemon
     *    at boot is NOT fatal — the first RPC fails with
     *    STRIM_CTRD_ERR_CONNECT and every later RPC reconnects, so the stage
     *    ops recover when the daemon comes up. A non-zero return here is a
     *    config error (bad socket path → BADARG, OOM → NOMEM) that cannot
     *    recover at runtime: fail fast. */
    rc = strim_containerd_connect(cfg.containerd_socket,
                                  cfg.containerd_namespace, &client);
    if (rc != 0) {
        logmsg("could not initialize containerd client: %d", rc);
        return 1;
    }

    /* -- container factory: the container-id → stage table (main.go:145-153)
     *    and the per-stage op contexts. */
    stage_table[n_stage_table++] =
        (strim_stage_table_entry){ cfg.mediamtx.container_id,
                                   STRIM_STAGE_MEDIA_MTX };
    stage_table[n_stage_table++] =
        (strim_stage_table_entry){ cfg.normalize.container_id,
                                   STRIM_STAGE_NORMALIZE };
    stage_table[n_stage_table++] =
        (strim_stage_table_entry){ cfg.scale_and_egress.container_id,
                                   STRIM_STAGE_SCALE_AND_EGRESS };
    if (cfg.enable_single_stage_pipeline) {
        stage_table[n_stage_table++] =
            (strim_stage_table_entry){ cfg.single_stage_egress.container_id,
                                       STRIM_STAGE_SINGLE_STAGE_EGRESS };
    }

    strim_default_layout(&layout, cfg.host_root);

    init_stage_ops(&mediamtx_ops, client, &cfg.mediamtx,
                   STRIM_STAGE_MEDIA_MTX, false, &layout, stage_table,
                   n_stage_table, cfg.stage_stop_timeout_ms);
    init_stage_ops(&normalize_ops, client, &cfg.normalize,
                   STRIM_STAGE_NORMALIZE, true, &layout, stage_table,
                   n_stage_table, cfg.stage_stop_timeout_ms);
    init_stage_ops(&egress_ops, client, &cfg.scale_and_egress,
                   STRIM_STAGE_SCALE_AND_EGRESS, true, &layout, stage_table,
                   n_stage_table, cfg.stage_stop_timeout_ms);
    init_stage_ops(&single_ops, client, &cfg.single_stage_egress,
                   STRIM_STAGE_SINGLE_STAGE_EGRESS, true, &layout,
                   stage_table, n_stage_table, cfg.stage_stop_timeout_ms);

    /* -- routes (main.go:176-202): path-event routes in the two-stage
     *    pipeline; command routes in both. */
    if (!cfg.enable_single_stage_pipeline) {
        path_routes[n_path_routes].kind = STRIM_ROUTE_PATH_EVENT;
        path_routes[n_path_routes].path = STRIM_PATH_INGRESS0;
        path_routes[n_path_routes].path_status = STRIM_PATH_READY;
        path_routes[n_path_routes].target_stage = STRIM_STAGE_NORMALIZE;
        path_routes[n_path_routes].target_state = STRIM_STAGE_RUNNING;
        path_routes[n_path_routes].prerequisite = NULL;
        n_path_routes++;

        path_routes[n_path_routes].kind = STRIM_ROUTE_PATH_EVENT;
        path_routes[n_path_routes].path = STRIM_PATH_INGRESS0;
        path_routes[n_path_routes].path_status = STRIM_PATH_NOT_READY;
        path_routes[n_path_routes].target_stage = STRIM_STAGE_NORMALIZE;
        path_routes[n_path_routes].target_state = STRIM_STAGE_STOPPED;
        path_routes[n_path_routes].prerequisite = NULL;
        n_path_routes++;
    }

    control_routes[n_control_routes].kind = STRIM_ROUTE_CONTROL;
    control_routes[n_control_routes].component = STRIM_COMPONENT_EGRESS;
    control_routes[n_control_routes].action = STRIM_ACTION_START;
    control_routes[n_control_routes].target_stage =
        cfg.enable_single_stage_pipeline ? STRIM_STAGE_SINGLE_STAGE_EGRESS
                                         : STRIM_STAGE_SCALE_AND_EGRESS;
    control_routes[n_control_routes].target_state = STRIM_STAGE_RUNNING;
    control_routes[n_control_routes].prerequisite = prereq_ingress0_ready;
    control_routes[n_control_routes].prerequisite_userdata = NULL;
    n_control_routes++;

    control_routes[n_control_routes].kind = STRIM_ROUTE_CONTROL;
    control_routes[n_control_routes].component = STRIM_COMPONENT_EGRESS;
    control_routes[n_control_routes].action = STRIM_ACTION_STOP;
    control_routes[n_control_routes].target_stage =
        cfg.enable_single_stage_pipeline ? STRIM_STAGE_SINGLE_STAGE_EGRESS
                                         : STRIM_STAGE_SCALE_AND_EGRESS;
    control_routes[n_control_routes].target_state = STRIM_STAGE_STOPPED;
    control_routes[n_control_routes].prerequisite = NULL;
    n_control_routes++;

    /* -- controller (main.go:174-230) */
    memset(&cc, 0, sizeof cc);
    cc.initial_paths[STRIM_PATH_INGRESS0] = STRIM_PATH_UNKNOWN;
    cc.initial_paths[STRIM_PATH_NORMALIZED] = STRIM_PATH_UNKNOWN;

    cc.stages[STRIM_STAGE_MEDIA_MTX].name = STRIM_STAGE_MEDIA_MTX;
    cc.stages[STRIM_STAGE_MEDIA_MTX].status.desired = STRIM_STAGE_RUNNING;
    cc.stages[STRIM_STAGE_MEDIA_MTX].status.actual = STRIM_STAGE_STOPPED;
    cc.stages[STRIM_STAGE_MEDIA_MTX].start_op = stage_start_op;
    cc.stages[STRIM_STAGE_MEDIA_MTX].stop_op = stage_stop_op;
    cc.stages[STRIM_STAGE_MEDIA_MTX].op_ctx = &mediamtx_ops;

    cc.stages[STRIM_STAGE_NORMALIZE].name = STRIM_STAGE_NORMALIZE;
    cc.stages[STRIM_STAGE_NORMALIZE].status.desired = STRIM_STAGE_STOPPED;
    cc.stages[STRIM_STAGE_NORMALIZE].status.actual = STRIM_STAGE_STOPPED;
    cc.stages[STRIM_STAGE_NORMALIZE].start_op = stage_start_op;
    cc.stages[STRIM_STAGE_NORMALIZE].stop_op = stage_stop_op;
    cc.stages[STRIM_STAGE_NORMALIZE].op_ctx = &normalize_ops;

    cc.stages[STRIM_STAGE_SCALE_AND_EGRESS].name = STRIM_STAGE_SCALE_AND_EGRESS;
    cc.stages[STRIM_STAGE_SCALE_AND_EGRESS].status.desired =
        STRIM_STAGE_STOPPED;
    cc.stages[STRIM_STAGE_SCALE_AND_EGRESS].status.actual = STRIM_STAGE_STOPPED;
    cc.stages[STRIM_STAGE_SCALE_AND_EGRESS].start_op = stage_start_op;
    cc.stages[STRIM_STAGE_SCALE_AND_EGRESS].stop_op = stage_stop_op;
    cc.stages[STRIM_STAGE_SCALE_AND_EGRESS].op_ctx = &egress_ops;

    cc.stages[STRIM_STAGE_SINGLE_STAGE_EGRESS].name =
        STRIM_STAGE_SINGLE_STAGE_EGRESS;
    cc.stages[STRIM_STAGE_SINGLE_STAGE_EGRESS].status.desired =
        STRIM_STAGE_STOPPED;
    cc.stages[STRIM_STAGE_SINGLE_STAGE_EGRESS].status.actual =
        STRIM_STAGE_STOPPED;
    cc.stages[STRIM_STAGE_SINGLE_STAGE_EGRESS].start_op = stage_start_op;
    cc.stages[STRIM_STAGE_SINGLE_STAGE_EGRESS].stop_op = stage_stop_op;
    cc.stages[STRIM_STAGE_SINGLE_STAGE_EGRESS].op_ctx = &single_ops;

    cc.path_routes = path_routes;
    cc.n_path_routes = n_path_routes;
    cc.control_routes = control_routes;
    cc.n_control_routes = n_control_routes;
    cc.now_ms = NULL; /* wall clock */
    cc.inflight_timeout_ms = cfg.inflight_timeout_ms;
    cc.actions_buffer_size = cfg.actions_buffer_size;

    rc = strim_controller_new(&cc, &controller);
    if (rc != 0) {
        logmsg("error constructing controller: %d", rc);
        if (client != NULL) {
            strim_containerd_close(client);
        }
        return 1;
    }

    /* -- HTTP callbacks (main.go:235-299) */
    hctx.controller = controller;
    fill_http_callbacks(&cbs);
    snprintf(addr, sizeof addr, ":%s", cfg.controller_http_port);

    rc = strim_http_server_start(&server, addr, &cbs, &hctx);
    if (rc != 0) {
        logmsg("could not start http server on %s: %d", addr, rc);
        strim_controller_destroy(controller);
        if (client != NULL) {
            strim_containerd_close(client);
        }
        return 1;
    }

    /* -- spawn the threads (main.go:313-342) */
    logmsg("starting control plane...");

    {
        bool controller_up = false;
        bool listener_up = false;
        bool ticker_up = false;
        bool http_up = false;

        if (pthread_create(&controller_tid, NULL, controller_thread_fn,
                           controller) != 0) {
            goto thread_fail;
        }
        controller_up = true;

        listener_arg.client = client;
        listener_arg.controller = controller;
        listener_arg.stage_table = stage_table;
        listener_arg.n_stage_table = n_stage_table;
        if (pthread_create(&listener_tid, NULL, containerd_listener_thread_fn,
                           &listener_arg) != 0) {
            goto thread_fail;
        }
        listener_up = true;

        ticker_arg.controller = controller;
        ticker_arg.interval_ms = cfg.reconcile_interval_ms;
        if (pthread_create(&ticker_tid, NULL, reconcile_ticker_thread_fn,
                           &ticker_arg) != 0) {
            goto thread_fail;
        }
        ticker_up = true;

        http_arg.server = server;
        if (pthread_create(&http_tid, NULL, http_service_thread_fn,
                           &http_arg) != 0) {
            goto thread_fail;
        }
        http_up = true;

        logmsg("controller listening on %s", addr);

        /* -- wait for the shutdown signal or a fatal server error (Go:
         *    <-rootContext.Done()) */
        while (!g_sig_flag && !g_http_fatal) {
            sleep_ms(100);
        }
        logmsg("shutting down");

        /* -- graceful HTTP shutdown (main.go:348-355; the server's service
         *    loop flushes ws writes, closes clients with 1000, releases,
         *    returns). The server object stays ALIVE here: the controller
         *    thread below is still the ws_send producer, and destroying the
         *    server first would let a final notify_listeners dereference the
         *    freed singleton (strim_http_ws_send resolves g_active_server). */
        strim_http_server_shutdown_request(server);
        pthread_join(http_tid, NULL);

        /* -- stop the ticker + listener (Go <-tickerDone, <-listenerDone) */
        pthread_join(ticker_tid, NULL);
        pthread_join(listener_tid, NULL);

        /* -- controller teardown in Go order: WaitForOps → Teardown → Close
         *    → Run returns. The controller thread is the ONLY ws_send
         *    producer (notify_listeners runs on the action-queue thread), so
         *    it MUST be joined before the HTTP server is destroyed. */
        strim_controller_wait_for_ops(controller);
        strim_controller_teardown(controller);
        strim_controller_close(controller);
        pthread_join(controller_tid, NULL);

        /* -- destroy the HTTP server NOW: no thread can call ws_send any
         *    more (the controller thread is joined; the worker pool only
         *    runs the containerd ops, which never notify). */
        strim_http_server_destroy(server);

        strim_controller_destroy(controller);

        if (client != NULL) {
            strim_containerd_close(client);
        }
        return 0;

    thread_fail:
        /* A thread failed to spawn mid-way. Bring down everything that came
         * up in the safe order: stop the HTTP service loop (leaving the
         * server object alive), stop the listener/ticker, join the controller
         * thread (the only ws_send producer) BEFORE destroying the HTTP
         * server, and only then destroy the controller. Never destroy a
         * controller whose Run thread is still live. */
        logmsg("could not start a control-plane thread");
        g_sig_flag = 1; /* lets the listener/ticker threads exit */
        if (http_up) {
            strim_http_server_shutdown_request(server);
            pthread_join(http_tid, NULL);
        }
        if (ticker_up) {
            pthread_join(ticker_tid, NULL);
        }
        if (listener_up) {
            pthread_join(listener_tid, NULL);
        }
        if (controller_up) {
            strim_controller_close(controller);
            pthread_join(controller_tid, NULL);
        }
        strim_http_server_destroy(server);
        strim_controller_destroy(controller);
        if (client != NULL) {
            strim_containerd_close(client);
        }
        return 1;
    }
}

/* =========================================================================
 * main() — the entrypoint contract (no /entrypoint.sh, no /bin/sh)
 * ========================================================================= */

/* The Go flag surface: -check-env / -print-env-example / -print-ts-types
 * (bool flags; both -name and --name, with optional =true/false). */
static bool flag_match(const char *arg, const char *name, bool *out) {
    const char *p = arg;
    size_t n = strlen(name);

    if (strncmp(p, "--", 2) == 0) {
        p += 2;
    } else if (p[0] == '-') {
        p += 1;
    } else {
        return false;
    }
    if (strncmp(p, name, n) != 0) {
        return false;
    }
    if (p[n] == '\0') {
        *out = true;
        return true;
    }
    if (p[n] == '=') {
        const char *v = p + n + 1;
        if (strcmp(v, "true") == 0 || strcmp(v, "1") == 0) {
            *out = true;
            return true;
        }
        if (strcmp(v, "false") == 0 || strcmp(v, "0") == 0) {
            *out = false;
            return true;
        }
    }
    return false;
}

static void print_usage(FILE *f) {
    fprintf(f,
            "Usage of %s:\n"
            "  -check-env          validate required env vars and exit\n"
            "  -print-env-example  write .env.example to stdout and exit\n"
            "  -print-ts-types     write the TS wire types to stdout and exit\n",
            "strimserver-controller");
}

int main(int argc, char **argv) {
    char err[1024];
    bool check_env_flag = false;
    bool print_example = false;
    bool print_ts = false;

    /* The entrypoint contract: source /strimserver.env when present (what
     * entrypoint.sh's `set -a; . file; set +a` did), then run. */
    if (source_env_file("/strimserver.env", err, sizeof err) != 0) {
        logmsg("could not source /strimserver.env: %s", err);
        return 1;
    }

    for (int i = 1; i < argc; i++) {
        bool v = false;
        if (flag_match(argv[i], "check-env", &v)) {
            check_env_flag = v;
        } else if (flag_match(argv[i], "print-env-example", &v)) {
            print_example = v;
        } else if (flag_match(argv[i], "print-ts-types", &v)) {
            print_ts = v;
        } else {
            fprintf(stderr, "flag provided but not defined: %s\n", argv[i]);
            print_usage(stderr);
            return 2;
        }
    }

    if (print_example) {
        print_env_example();
        return 0;
    }
    if (print_ts) {
        print_ts_types();
        return 0;
    }
    if (check_env_flag) {
        if (check_env(err, sizeof err) != 0) {
            logmsg("%s", err);
            return 1;
        }
        printf("env OK\n");
        return 0;
    }

    return run();
}