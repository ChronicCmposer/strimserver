/*
 * spec.h — OCI runtime spec construction contract (C port).
 *
 * Wave 0-A foundation header. The container lane (containerd_client.h)
 * builds container specs from these structs; the HTTP/state lanes never touch
 * them. It mirrors the Go oracle (core/controller/container_factory.go +
 * paths.go) 1:1:
 *
 *   - Mount: {Src, Dst, ReadWrite} -> OCI "bind" mount with options
 *     {"rbind","rw"} or {"rbind","ro"} (toOCIMounts, container_factory.go:68).
 *   - Process: image-config env (or defaultUnixEnv fallback), args, cwd;
 *     capabilities append CAP_SYS_NICE to the image defaults
 *     (baseSpecOpts, container_factory.go:114).
 *   - Host networking: WithHostNamespace(NetworkNamespace) REMOVES the
 *     network namespace from the default spec (host_network = true).
 *   - cgroups path: containerd derives "/<namespace>/<container-id>" from the
 *     container id; the C port passes it through the container opts.
 *
 * The mount lists are the exact bind-mount decisions the Go code makes
 * (ffmpegMounts / mediamtxMounts, container_factory.go:88-109). Container
 * destinations are a contract with the mounted scripts (paths.go:12-21) —
 * do NOT change them.
 *
 * Style: fixed-arity C, caller-provided output buffers, no heap ownership
 * crossing the boundary. String arrays are NULL-terminated.
 *
 * License: project code (see LICENSE). No GPL.
 */
#ifndef STRIM_SPEC_H
#define STRIM_SPEC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* The stage-argv helper (strim_stage_table_entry / strim_stage_argv below)
 * maps container ids to strim_stage_name, so spec.h pulls in the controller
 * enums (same pattern as cdi.h including spec.h). Wave 1 (core lane)
 * additive addition. */
#include "controller.h"

#ifdef __cplusplus
extern "C" {
#endif

/* =========================================================================
 * Constants
 * ========================================================================= */

/* Bounds for the fixed-size mount lists / arrays (fixed-arity design; the
 * project images mount 4 (ffmpeg) or 6 (mediamtx) paths; CDI merges add the
 * device spec's mounts, so the bound also covers a full CDI edit set such as
 * the nvidia spec's 55 spec-level mounts). */
#define STRIM_SPEC_MAX_MOUNTS      256
#define STRIM_SPEC_MAX_ARGS        16
#define STRIM_SPEC_MAX_ENV         64
#define STRIM_SPEC_MAX_CAPS        32
#define STRIM_SPEC_MAX_HOOKS       32    /* createContainer hooks (a full CDI
                                          * edit set is bounded by
                                          * STRIM_CDI_MAX_DEVICES).            */

/* Error codes (negative; returned by the mount-list / stage-argv
 * constructors). Wave 1 (core lane) additive addition. */
#define STRIM_SPEC_ERR_BADARG      (-1) /* NULL/empty required argument        */
#define STRIM_SPEC_ERR_TOOSMALL    (-2) /* caller buffer too small             */

/* Container-internal mount destinations — a contract with the mounted
 * scripts (transcode.sh, notify.sh, entrypoint.mediamtx.sh). NOT
 * independently configurable (paths.go:12-21). */
#define STRIM_CTR_ENV          "/strimserver.env"
#define STRIM_CTR_TRANSCODE    "/transcode.sh"
#define STRIM_CTR_NOTIFY       "/notify.sh"
#define STRIM_CTR_MEDIAMTX_TMPL "/mediamtx.yaml.template"
#define STRIM_CTR_SRT_SECRET   "/run/secrets/srt-passphrase"
#define STRIM_CTR_VIDEO_DIR    "/video-files"
#define STRIM_CTR_RESOLV_CONF  "/etc/resolv.conf"
#define STRIM_CTR_TMP          "/tmp"

/* Host layout (paths.go: Layout + DefaultLayout). Every strimserver container
 * is created against these host paths. */
typedef struct strim_layout {
    const char *env;           /* <hostRoot>/config/strimserver.env          */
    const char *transcode;     /* <hostRoot>/bin/transcode.sh                */
    const char *notify;        /* <hostRoot>/bin/notify.sh                   */
    const char *mediamtx_tmpl; /* <hostRoot>/config/mediamtx.yaml.template   */
    const char *srt_pass;      /* <hostRoot>/srt-passphrase                  */
    const char *video_dir;     /* <hostRoot>/video-files                     */
    const char *resolv_conf;   /* /run/systemd/resolve/resolv.conf           */
    const char *tmp;           /* /tmp                                       */
} strim_layout;

/* Fill out with DefaultLayout (host_root == "" -> "/mnt/nvme"). */
void strim_default_layout(strim_layout *out, const char *host_root);

/* =========================================================================
 * OCI structs
 * ========================================================================= */

/* One bind mount: source -> destination, rw or ro. Becomes the OCI mount
 * {Type: "bind", Source, Destination, Options: {"rbind", "rw"|"ro"}}. */
typedef struct strim_mount {
    const char *source;       /* host path                                     */
    const char *destination;  /* container path (see STRIM_CTR_* constants)    */
    bool        read_write;   /* true -> {"rbind","rw"}; false -> {"rbind","ro"} */
} strim_mount;

/* One OCI createContainer hook (runtime-spec "hooks" section): an executable
 * run inside the container at create time. The NVIDIA CDI spec relies on
 * these (e.g. "nvidia-cdi-hook create-symlinks") to create libcuda.so.1 in
 * the container. Becomes the OCI hook object {"path", "args"[], "env"[],
 * "timeout"}. The CDI lane (cdi.c) exposes the resolved createContainer hooks
 * through strim_spec.hooks so the OCI builder emits them alongside the CDI
 * edit set's own hooks. */
typedef struct strim_hook {
    const char *path;         /* absolute path to the hook executable          */
    const char *const *args;  /* argv after argv[0]; NULL = no args            */
    size_t             n_args;
    const char *const *env;   /* "K=V" additions; NULL = inherit runtime env   */
    size_t             n_env;
    int32_t            timeout; /* seconds; 0 = omit (OCI "timeout" is int)    */
} strim_hook;

/* Process spec. env/args/capabilities are NULL-terminated arrays; cwd NULL
 * means the image WorkingDir (Go WithImageConfig). */
typedef struct strim_process {
    const char *const *args;          /* argv after the image entrypoint       */
    size_t             n_args;
    const char *const *env;           /* "K=V"; NULL = image env / defaultUnixEnv */
    size_t             n_env;
    const char        *cwd;           /* NULL = image WorkingDir               */
    const char *const *capabilities;  /* appended to image defaults; e.g.
                                       * {"CAP_SYS_NICE"} (WithAddedCapabilities) */
    size_t             n_capabilities;
} strim_process;

/* The complete OCI spec field set the controller builds. */
typedef struct strim_spec {
    strim_process process;
    const strim_mount *mounts;   /* STRIM_SPEC_MAX_MOUNTS entries, n_mounts    */
    size_t         n_mounts;
    bool           host_network; /* WithHostNamespace(NetworkNamespace): 1
                                  * REMOVES the netns from the default spec
                                  * (host networking).                        */
    const char    *cgroups_path; /* "/<namespace>/<container-id>" (NULL = the
                                  * implementation derives it from the
                                  * container id + namespace).                */
    const strim_hook *hooks;     /* createContainer hooks (STRIM_SPEC_MAX_HOOKS
                                  * entries, n_hooks); NULL = none.            */
    size_t         n_hooks;
} strim_spec;

/* =========================================================================
 * Default env fallback
 * ========================================================================= */

/* OCI's defaultUnixEnv: {"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "TERM=xterm"}.
 * The container lane uses this when the image config carries no env
 * (runtime-spec populateDefaultUnixSpec). NULL-terminated. */
extern const char *const strim_default_unix_env[];

/* =========================================================================
 * Mount list constructors
 * ========================================================================= */

/* Fill mounts[] with the ffmpeg-stage bind-mount list (env, transcode,
 * resolv.conf, writable /tmp). Returns the count (always <= 4); fails with a
 * negative error if cap is too small. */
int strim_ffmpeg_mounts(const strim_layout *layout, strim_mount *mounts,
                        size_t cap);

/* Fill mounts[] with the mediamtx bind-mount list (env, template, notify,
 * srt secret, writable video-files + /tmp). Returns the count (always <= 6);
 * fails with a negative error if cap is too small. */
int strim_mediamtx_mounts(const strim_layout *layout, strim_mount *mounts,
                          size_t cap);

/* =========================================================================
 * Added capability / stage argv (baseSpecOpts + stageArgv,
 * container_factory.go). Wave 1 (core lane) additive additions.
 * ========================================================================= */

/* The capability baseSpecOpts appends to the image's capability defaults
 * (container_factory.go:118): {"CAP_SYS_NICE", NULL}. The containerd lane
 * adds it to the containerd default baseline when materializing the spec.
 * NULL-terminated. */
extern const char *const strim_spec_added_capabilities[];

/* One container-id -> stage-name mapping (Go: containerIDtoStageName,
 * main.go:145-153). */
typedef struct strim_stage_table_entry {
    const char      *container_id;
    strim_stage_name stage;
} strim_stage_table_entry;

/* Fill argv[0..1] with the ffmpeg stage launch argv (stageArgv,
 * container_factory.go:273-277): argv0 = STRIM_CTR_TRANSCODE and argv1 = the
 * stage's wire name (strim_stage_name_to_string). A container id absent from
 * the table falls back to the id itself (Go: StageName(id)). Returns 0, or a
 * negative error (STRIM_SPEC_ERR_BADARG / STRIM_SPEC_ERR_TOOSMALL). */
int strim_stage_argv(const strim_stage_table_entry *table, size_t n_table,
                     const char *container_id,
                     char *argv0, size_t argv0_cap,
                     char *argv1, size_t argv1_cap);

#ifdef __cplusplus
}
#endif

#endif /* STRIM_SPEC_H */