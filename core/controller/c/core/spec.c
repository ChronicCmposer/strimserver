/*
 * spec.c — OCI runtime spec construction (C port).
 *
 * Wave 1 core lane. Implements the spec.h contract 1:1 from the Go oracle
 * (core/controller/container_factory.go + paths.go):
 *
 *   - strim_default_layout  <- DefaultLayout (paths.go:27-42)
 *   - strim_ffmpeg_mounts   <- ffmpegMounts  (container_factory.go:88-95)
 *   - strim_mediamtx_mounts <- mediamtxMounts (container_factory.go:100-109)
 *   - strim_default_unix_env<- containerd's defaultUnixEnv (pkg/oci/spec.go);
 *                             the oracle test pins PATH only
 *   - strim_stage_argv      <- stageArgv (container_factory.go:273-277)
 *   - strim_spec_added_capabilities <- baseSpecOpts' CAP_SYS_NICE append
 *                             (container_factory.go:118)
 *
 * The remaining baseSpecOpts decisions (image-config env/entrypoint/cwd
 * fallback, host-network removal, the {"rbind","rw"|"ro"} option strings,
 * cgroups path derivation) are carried structurally by strim_spec: the
 * containerd lane materializes them when it serializes the spec from the
 * resolved image. read_write on each strim_mount IS the toOCIMounts decision
 * (container_factory.go:68-81): rw -> {"rbind","rw"}, ro -> {"rbind","ro"}.
 *
 * Style: fixed-arity C, caller-provided output buffers, no heap ownership
 * crossing the boundary. String arrays are NULL-terminated.
 *
 * License: project code (see LICENSE). No GPL.
 */

#include "spec.h"

#include <stdio.h>
#include <string.h>

/* Bounds for the internal layout buffers (host paths are < PATH_MAX). */
#define STRIM_SPEC_PATH_MAX 4096

/* -------------------------------------------------------------------------
 * Error codes (spec.h documents negative returns; these are the values)
 * ------------------------------------------------------------------------- */
#define STRIM_SPEC_ERR_BADARG   (-1)
#define STRIM_SPEC_ERR_TOOSMALL (-2)

/* -------------------------------------------------------------------------
 * Default env fallback / added capability (NULL-terminated)
 * ------------------------------------------------------------------------- */

/* containerd's defaultUnixEnv (pkg/oci/spec.go) — the PATH-only baseline the
 * oracle test TestBaseSpecOptsDefaultUnixEnvFallback pins. The spec.h block
 * comment mentions OCI's runtime-spec default which also carries
 * TERM=xterm; the port follows the ORACLE (containerd), not that comment. */
const char *const strim_default_unix_env[] = {
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    NULL,
};

/* baseSpecOpts appends CAP_SYS_NICE to the image's capability defaults
 * (container_factory.go:118). */
const char *const strim_spec_added_capabilities[] = {
    "CAP_SYS_NICE",
    NULL,
};

/* -------------------------------------------------------------------------
 * Default layout
 * ------------------------------------------------------------------------- */

/* Static backing store for the pointer fields strim_default_layout hands
 * out. The controller builds one layout at boot (Go: DefaultLayout in
 * run()); a second call overwrites the previous strings. Documented in the
 * header as boot-time-only so this is not a re-entrancy hazard. */
static char g_layout_env[STRIM_SPEC_PATH_MAX];
static char g_layout_transcode[STRIM_SPEC_PATH_MAX];
static char g_layout_notify[STRIM_SPEC_PATH_MAX];
static char g_layout_mediamtx_tmpl[STRIM_SPEC_PATH_MAX];
static char g_layout_srt_pass[STRIM_SPEC_PATH_MAX];
static char g_layout_video_dir[STRIM_SPEC_PATH_MAX];

/* path.Join semantics: one "/" separator, no trailing slash, "/" stays "/". */
static void join_path(char *out, size_t cap, const char *base,
                      const char *suffix) {
    if (strcmp(base, "/") == 0) {
        snprintf(out, cap, "%s", suffix);
    } else {
        snprintf(out, cap, "%s/%s", base, suffix);
    }
}

void strim_default_layout(strim_layout *out, const char *host_root) {
    if (out == NULL) {
        return; /* caller bug; nothing to fill */
    }

    if (host_root == NULL || host_root[0] == '\0') {
        host_root = "/mnt/nvme";
    }

    char root[STRIM_SPEC_PATH_MAX];
    snprintf(root, sizeof root, "%s", host_root);
    /* path.Join collapses trailing slashes; keep at least "/". */
    size_t n = strlen(root);
    while (n > 1 && root[n - 1] == '/') {
        root[n - 1] = '\0';
        n--;
    }

    join_path(g_layout_env, sizeof g_layout_env, root, "config/strimserver.env");
    join_path(g_layout_transcode, sizeof g_layout_transcode, root, "bin/transcode.sh");
    join_path(g_layout_notify, sizeof g_layout_notify, root, "bin/notify.sh");
    join_path(g_layout_mediamtx_tmpl, sizeof g_layout_mediamtx_tmpl, root,
              "config/mediamtx.yaml.template");
    join_path(g_layout_srt_pass, sizeof g_layout_srt_pass, root, "srt-passphrase");
    join_path(g_layout_video_dir, sizeof g_layout_video_dir, root, "video-files");

    out->env = g_layout_env;
    out->transcode = g_layout_transcode;
    out->notify = g_layout_notify;
    out->mediamtx_tmpl = g_layout_mediamtx_tmpl;
    out->srt_pass = g_layout_srt_pass;
    out->video_dir = g_layout_video_dir;
    /* System paths, not under hostRoot (paths.go:39-40). */
    out->resolv_conf = "/run/systemd/resolve/resolv.conf";
    out->tmp = "/tmp";
}

/* -------------------------------------------------------------------------
 * Mount lists — the exact bind-mount decisions of the Go oracle
 * ------------------------------------------------------------------------- */

int strim_ffmpeg_mounts(const strim_layout *layout, strim_mount *mounts,
                        size_t cap) {
    if (layout == NULL || mounts == NULL) {
        return STRIM_SPEC_ERR_BADARG;
    }
    if (layout->env == NULL || layout->transcode == NULL ||
        layout->resolv_conf == NULL || layout->tmp == NULL) {
        return STRIM_SPEC_ERR_BADARG;
    }
    if (cap < 4) {
        return STRIM_SPEC_ERR_TOOSMALL;
    }

    mounts[0].source = layout->env;
    mounts[0].destination = STRIM_CTR_ENV;
    mounts[0].read_write = false;

    mounts[1].source = layout->transcode;
    mounts[1].destination = STRIM_CTR_TRANSCODE;
    mounts[1].read_write = false;

    mounts[2].source = layout->resolv_conf;
    mounts[2].destination = STRIM_CTR_RESOLV_CONF;
    mounts[2].read_write = false;

    mounts[3].source = layout->tmp;
    mounts[3].destination = STRIM_CTR_TMP;
    mounts[3].read_write = true;

    return 4;
}

int strim_mediamtx_mounts(const strim_layout *layout, strim_mount *mounts,
                          size_t cap) {
    if (layout == NULL || mounts == NULL) {
        return STRIM_SPEC_ERR_BADARG;
    }
    if (layout->env == NULL || layout->mediamtx_tmpl == NULL ||
        layout->notify == NULL || layout->srt_pass == NULL ||
        layout->video_dir == NULL || layout->tmp == NULL) {
        return STRIM_SPEC_ERR_BADARG;
    }
    if (cap < 6) {
        return STRIM_SPEC_ERR_TOOSMALL;
    }

    mounts[0].source = layout->env;
    mounts[0].destination = STRIM_CTR_ENV;
    mounts[0].read_write = false;

    mounts[1].source = layout->mediamtx_tmpl;
    mounts[1].destination = STRIM_CTR_MEDIAMTX_TMPL;
    mounts[1].read_write = false;

    mounts[2].source = layout->notify;
    mounts[2].destination = STRIM_CTR_NOTIFY;
    mounts[2].read_write = false;

    mounts[3].source = layout->srt_pass;
    mounts[3].destination = STRIM_CTR_SRT_SECRET;
    mounts[3].read_write = false;

    mounts[4].source = layout->video_dir;
    mounts[4].destination = STRIM_CTR_VIDEO_DIR;
    mounts[4].read_write = true;

    mounts[5].source = layout->tmp;
    mounts[5].destination = STRIM_CTR_TMP;
    mounts[5].read_write = true;

    return 6;
}

/* -------------------------------------------------------------------------
 * Stage argv — the ffmpeg stages launch as {transcode.sh, stage name}. The
 * stage name differs from the container id ("scale-and-egress" runs as the
 * stage "scale_and_egress"); transcode.sh switches on the stage name while
 * containerd derives the cgroups path from the container id.
 * ------------------------------------------------------------------------- */

int strim_stage_argv(const strim_stage_table_entry *table, size_t n_table,
                     const char *container_id,
                     char *argv0, size_t argv0_cap,
                     char *argv1, size_t argv1_cap) {
    if (container_id == NULL || argv0 == NULL || argv1 == NULL) {
        return STRIM_SPEC_ERR_BADARG;
    }
    if (argv0_cap == 0 || argv1_cap == 0) {
        return STRIM_SPEC_ERR_BADARG;
    }
    if (n_table > 0 && table == NULL) {
        return STRIM_SPEC_ERR_BADARG;
    }

    if (argv0_cap <= strlen(STRIM_CTR_TRANSCODE)) {
        return STRIM_SPEC_ERR_TOOSMALL;
    }
    strcpy(argv0, STRIM_CTR_TRANSCODE);

    /* Fallback: the container id itself (Go StageName(containerConfig.
     * ContainerID), container_factory.go:274-275). */
    const char *stage_str = container_id;
    for (size_t i = 0; i < n_table; i++) {
        if (table[i].container_id != NULL &&
            strcmp(table[i].container_id, container_id) == 0) {
            const char *wire = strim_stage_name_to_string(table[i].stage);
            if (wire != NULL) {
                stage_str = wire;
            }
            break;
        }
    }

    if (argv1_cap <= strlen(stage_str)) {
        return STRIM_SPEC_ERR_TOOSMALL;
    }
    strcpy(argv1, stage_str);
    return 0;
}