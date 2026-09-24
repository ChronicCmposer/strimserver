/*
 * spec_test.c — OCI spec construction regression suite (C port of
 * core/controller/container_factory_test.go's mount/spec cases:
 * TestFFmpegMounts, TestMediaMTXMounts, TestToOCIMounts, TestStageArgv,
 * TestBaseSpecOptsDefaultUnixEnvFallback, plus the DefaultLayout pin).
 *
 * The containerd lane materializes the full OCI spec from the resolved image
 * config; this suite pins the pure construction decisions the core lane
 * owns — the exact mount lists, the rw/ro flags (toOCIMounts), the layout
 * paths, the defaultUnixEnv fallback, the CAP_SYS_NICE addition, and the
 * stage argv mapping.
 *
 * These tests become the Wave-3 regression suite; keep them clean.
 *
 * License: project code (see LICENSE). No GPL.
 */

#include <stdio.h>
#include <string.h>

#include "controller.h" /* strim_stage_name_to_string (spec.h includes it) */
#include "spec.h"

static int g_failures = 0;

#define CHECK(cond)                                                       \
    do {                                                                  \
        if (!(cond)) {                                                    \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            g_failures++;                                                 \
        }                                                                 \
    } while (0)

/* -------------------------------------------------------------------------
 * Go TestFFmpegMounts + TestMediaMTXMounts
 * ------------------------------------------------------------------------- */

static void test_ffmpeg_mounts(void) {
    strim_layout layout;
    strim_default_layout(&layout, "/mnt/nvme");

    strim_mount mounts[STRIM_SPEC_MAX_MOUNTS];
    int n = strim_ffmpeg_mounts(&layout, mounts, STRIM_SPEC_MAX_MOUNTS);
    CHECK(n == 4);

    CHECK(strcmp(mounts[0].source, "/mnt/nvme/config/strimserver.env") == 0);
    CHECK(strcmp(mounts[0].destination, STRIM_CTR_ENV) == 0);
    CHECK(mounts[0].read_write == false);

    CHECK(strcmp(mounts[1].source, "/mnt/nvme/bin/transcode.sh") == 0);
    CHECK(strcmp(mounts[1].destination, STRIM_CTR_TRANSCODE) == 0);
    CHECK(mounts[1].read_write == false);

    CHECK(strcmp(mounts[2].source, "/run/systemd/resolve/resolv.conf") == 0);
    CHECK(strcmp(mounts[2].destination, STRIM_CTR_RESOLV_CONF) == 0);
    CHECK(mounts[2].read_write == false);

    CHECK(strcmp(mounts[3].source, "/tmp") == 0);
    CHECK(strcmp(mounts[3].destination, STRIM_CTR_TMP) == 0);
    CHECK(mounts[3].read_write == true);

    /* Small-cap buffer fails loud. */
    CHECK(strim_ffmpeg_mounts(&layout, mounts, 3) < 0);
}

static void test_mediamtx_mounts(void) {
    strim_layout layout;
    strim_default_layout(&layout, "/mnt/nvme");

    strim_mount mounts[STRIM_SPEC_MAX_MOUNTS];
    int n = strim_mediamtx_mounts(&layout, mounts, STRIM_SPEC_MAX_MOUNTS);
    CHECK(n == 6);

    CHECK(strcmp(mounts[0].source, "/mnt/nvme/config/strimserver.env") == 0);
    CHECK(strcmp(mounts[0].destination, STRIM_CTR_ENV) == 0);
    CHECK(mounts[0].read_write == false);

    CHECK(strcmp(mounts[1].source, "/mnt/nvme/config/mediamtx.yaml.template") == 0);
    CHECK(strcmp(mounts[1].destination, STRIM_CTR_MEDIAMTX_TMPL) == 0);
    CHECK(mounts[1].read_write == false);

    CHECK(strcmp(mounts[2].source, "/mnt/nvme/bin/notify.sh") == 0);
    CHECK(strcmp(mounts[2].destination, STRIM_CTR_NOTIFY) == 0);
    CHECK(mounts[2].read_write == false);

    CHECK(strcmp(mounts[3].source, "/mnt/nvme/srt-passphrase") == 0);
    CHECK(strcmp(mounts[3].destination, STRIM_CTR_SRT_SECRET) == 0);
    CHECK(mounts[3].read_write == false);

    CHECK(strcmp(mounts[4].source, "/mnt/nvme/video-files") == 0);
    CHECK(strcmp(mounts[4].destination, STRIM_CTR_VIDEO_DIR) == 0);
    CHECK(mounts[4].read_write == true);

    CHECK(strcmp(mounts[5].source, "/tmp") == 0);
    CHECK(strcmp(mounts[5].destination, STRIM_CTR_TMP) == 0);
    CHECK(mounts[5].read_write == true);

    /* Small-cap buffer fails loud. */
    CHECK(strim_mediamtx_mounts(&layout, mounts, 5) < 0);
}

/* -------------------------------------------------------------------------
 * Go TestToOCIMounts — the rw/ro flag IS the toOCIMounts option decision:
 * read_write -> {"rbind","rw"}, else {"rbind","ro"}. The option strings are
 * a pure function the containerd lane applies when serializing.
 * ------------------------------------------------------------------------- */

static void test_to_oci_mount_flags(void) {
    strim_layout layout;
    strim_default_layout(&layout, "/mnt/nvme");

    strim_mount mounts[STRIM_SPEC_MAX_MOUNTS];
    int n = strim_ffmpeg_mounts(&layout, mounts, STRIM_SPEC_MAX_MOUNTS);
    CHECK(n == 4);
    CHECK(mounts[0].read_write == false); /* env       -> rbind,ro */
    CHECK(mounts[1].read_write == false); /* transcode -> rbind,ro */
    CHECK(mounts[2].read_write == false); /* resolv    -> rbind,ro */
    CHECK(mounts[3].read_write == true);  /* /tmp      -> rbind,rw */

    n = strim_mediamtx_mounts(&layout, mounts, STRIM_SPEC_MAX_MOUNTS);
    CHECK(n == 6);
    CHECK(mounts[0].read_write == false); /* env        -> rbind,ro */
    CHECK(mounts[1].read_write == false); /* template   -> rbind,ro */
    CHECK(mounts[2].read_write == false); /* notify     -> rbind,ro */
    CHECK(mounts[3].read_write == false); /* srt secret -> rbind,ro */
    CHECK(mounts[4].read_write == true);  /* video-files-> rbind,rw */
    CHECK(mounts[5].read_write == true);  /* /tmp       -> rbind,rw */
}

/* -------------------------------------------------------------------------
 * Go DefaultLayout (paths.go:27-42)
 * ------------------------------------------------------------------------- */

static void test_default_layout(void) {
    strim_layout layout;

    strim_default_layout(&layout, "/mnt/nvme");
    CHECK(strcmp(layout.env, "/mnt/nvme/config/strimserver.env") == 0);
    CHECK(strcmp(layout.transcode, "/mnt/nvme/bin/transcode.sh") == 0);
    CHECK(strcmp(layout.notify, "/mnt/nvme/bin/notify.sh") == 0);
    CHECK(strcmp(layout.mediamtx_tmpl,
                 "/mnt/nvme/config/mediamtx.yaml.template") == 0);
    CHECK(strcmp(layout.srt_pass, "/mnt/nvme/srt-passphrase") == 0);
    CHECK(strcmp(layout.video_dir, "/mnt/nvme/video-files") == 0);
    CHECK(strcmp(layout.resolv_conf, "/run/systemd/resolve/resolv.conf") == 0);
    CHECK(strcmp(layout.tmp, "/tmp") == 0);

    /* Empty host root -> "/mnt/nvme" (Go: DefaultLayout("")). */
    strim_default_layout(&layout, "");
    CHECK(strcmp(layout.env, "/mnt/nvme/config/strimserver.env") == 0);
    CHECK(strcmp(layout.transcode, "/mnt/nvme/bin/transcode.sh") == 0);
    CHECK(strcmp(layout.video_dir, "/mnt/nvme/video-files") == 0);

    /* NULL host root is treated like "" (guard; Go has no NULL). */
    strim_default_layout(&layout, NULL);
    CHECK(strcmp(layout.env, "/mnt/nvme/config/strimserver.env") == 0);
}

/* -------------------------------------------------------------------------
 * Go TestBaseSpecOptsDefaultUnixEnvFallback — the env fallback when the
 * image config carries no env. The oracle test pins containerd's
 * defaultUnixEnv (PATH only; NOT runtime-spec's TERM=xterm variant).
 * ------------------------------------------------------------------------- */

static void test_default_unix_env(void) {
    CHECK(strim_default_unix_env[0] != NULL);
    CHECK(strcmp(strim_default_unix_env[0],
                 "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin") == 0);
    CHECK(strim_default_unix_env[1] == NULL); /* NULL-terminated */
}

/* -------------------------------------------------------------------------
 * Go baseSpecOpts' CAP_SYS_NICE append (container_factory.go:118)
 * ------------------------------------------------------------------------- */

static void test_added_capabilities(void) {
    CHECK(strim_spec_added_capabilities[0] != NULL);
    CHECK(strcmp(strim_spec_added_capabilities[0], "CAP_SYS_NICE") == 0);
    CHECK(strim_spec_added_capabilities[1] == NULL);
}

/* -------------------------------------------------------------------------
 * Go TestStageArgv (container_factory.go:273-277) — the table maps a
 * container id to a stage; the stage's wire name becomes argv[1]. A missing
 * id falls back to the id itself.
 * ------------------------------------------------------------------------- */

static void test_stage_argv(void) {
    strim_stage_table_entry table[4];
    size_t n = 0;

    table[n].container_id = "mediamtx";
    table[n].stage = STRIM_STAGE_MEDIA_MTX;
    n++;
    table[n].container_id = "normalize";
    table[n].stage = STRIM_STAGE_NORMALIZE;
    n++;
    table[n].container_id = "scale-and-egress";
    table[n].stage = STRIM_STAGE_SCALE_AND_EGRESS;
    n++;
    table[n].container_id = "single-stage-egress";
    table[n].stage = STRIM_STAGE_SINGLE_STAGE_EGRESS;
    n++;

    char argv0[64];
    char argv1[64];

    /* "scale-and-egress" maps to the underscore stage name. */
    CHECK(strim_stage_argv(table, n, "scale-and-egress",
                           argv0, sizeof argv0, argv1, sizeof argv1) == 0);
    CHECK(strcmp(argv0, STRIM_CTR_TRANSCODE) == 0);
    CHECK(strcmp(argv1, "scale_and_egress") == 0);

    /* "single-stage-egress" maps to the underscore stage name. */
    CHECK(strim_stage_argv(table, n, "single-stage-egress",
                           argv0, sizeof argv0, argv1, sizeof argv1) == 0);
    CHECK(strcmp(argv1, "single_stage_egress") == 0);

    /* "normalize" stage name equals container id. */
    CHECK(strim_stage_argv(table, n, "normalize",
                           argv0, sizeof argv0, argv1, sizeof argv1) == 0);
    CHECK(strcmp(argv1, "normalize") == 0);

    /* Unknown container id falls back to the id itself. */
    CHECK(strim_stage_argv(table, n, "unknown-stage",
                           argv0, sizeof argv0, argv1, sizeof argv1) == 0);
    CHECK(strcmp(argv1, "unknown-stage") == 0);

    /* An empty table also falls back (Go: stageNames empty/absent). */
    CHECK(strim_stage_argv(NULL, 0, "whatever",
                           argv0, sizeof argv0, argv1, sizeof argv1) == 0);
    CHECK(strcmp(argv1, "whatever") == 0);

    /* Buffer too small fails loud. */
    CHECK(strim_stage_argv(table, n, "scale-and-egress",
                           argv0, sizeof argv0, argv1, 8) < 0);
}

int main(void) {
    printf("=== core OCI spec construction ===\n");

    test_ffmpeg_mounts();
    test_mediamtx_mounts();
    test_to_oci_mount_flags();
    test_default_layout();
    test_default_unix_env();
    test_added_capabilities();
    test_stage_argv();

    if (g_failures == 0) {
        printf("ALL PASS\n");
        return 0;
    }
    printf("%d FAILURE(S)\n", g_failures);
    return 1;
}