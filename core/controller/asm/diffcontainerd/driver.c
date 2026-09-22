// ============================================================================
// diffcontainerd/driver.c — freestanding x86-64 driver for the containerd
// OCI spec-fill differential harness.
//
// This driver is the ASM side of differential-containerd.sh.  It links the
// REAL x86-64 cc_ctr.S + cc_util.S objects (the fixed tree versions; the
// scale-8 fix is A1's) and drives ONLY the mount/spec-fill path:
//
//     cc_ctr_init(layout, h, stop_timeout)          (sets ctr_state.layout)
//     cc_ctr_oci_spec_fill(config, kind, spec_out, mounts_out, scratch)
//         -> ctr_fill_mounts(mounts_out, desc_table, n)
//            (the crash site: mediamtx mount records from the Layout's
//             byte-offset descriptor table)
//         -> ctr_build_cgroups(config, spec, scratch)
//
// It does NOT call any C-layer RPC (cc_ctr_get_image & friends) — those are
// stubbed below (they are never reached on this path) so the driver links
// the cc_ctr.o object without the protobuf/gRPC C layer.
//
// The driver:
//   1. reads the shared stage config (stages.conf) — the SAME file the Go
//      oracle reads;
//   2. builds the Layout struct + env-runtime block + per-stage
//      ContainerConfigs in memory (byte offsets from cc_layout.inc);
//   3. for each CTR_KIND_* (mediamtx, normalize, scale-and-egress,
//      single-stage-egress), calls cc_ctr_oci_spec_fill with the stage's
//      ContainerConfig and dumps the resulting OCI records in a canonical
//      byte-comparable format.
//
// The dump format is the byte-for-byte comparison surface: the Go oracle
// emits the identical lines.
//
// Usage: driver <stages.conf>
// Exit:  0 on success; non-zero on any parse/fill/dump error.
// ============================================================================

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../c/cc_ctr.h"   // struct cc_ctr_oci_spec / cc_ctr_oci_mount

// ---------------------------------------------------------------------------
// Constants mirrored from cc_layout.inc (frozen; see the header include).
// ---------------------------------------------------------------------------
#define CC_LAY_SIZE          64
#define CC_ER_CONTAINERD_NAMESPACE  8
#define CC_ER_MEDIAMTX       80
#define CC_ER_NORMALIZE      112
#define CC_ER_SCALE_AND_EGRESS  144
#define CC_ER_SINGLE_STAGE_EGRESS 176
#define CC_ER_SIZE           208

// CTR_KIND_* ids (asm/cc_ctr.h)
#define CTR_KIND_MEDIAMTX      0
#define CTR_KIND_NORMALIZE     1
#define CTR_KIND_SCALE_EGRESS  2
#define CTR_KIND_SINGLE_EGRESS 3
#define CTR_KIND_COUNT         4

// Max cc_ctr_oci_mount records the driver hands the asm (== the asm module's
// CTR_SPEC_MOUNTS_MAX, 8; the mediamtx table uses 6, ffmpeg uses 4).
#define DRIVER_MOUNTS_MAX 8

// The kind -> CC_ER_* ContainerConfig offset mapping (cc_ctr.S wrappers).
static const int k_kind_cc_er[CTR_KIND_COUNT] = {
    [CTR_KIND_MEDIAMTX]      = CC_ER_MEDIAMTX,
    [CTR_KIND_NORMALIZE]     = CC_ER_NORMALIZE,
    [CTR_KIND_SCALE_EGRESS]  = CC_ER_SCALE_AND_EGRESS,
    [CTR_KIND_SINGLE_EGRESS] = CC_ER_SINGLE_STAGE_EGRESS,
};

static const char *k_kind_name[CTR_KIND_COUNT] = {
    [CTR_KIND_MEDIAMTX]      = "mediamtx",
    [CTR_KIND_NORMALIZE]     = "normalize",
    [CTR_KIND_SCALE_EGRESS]  = "scale-and-egress",
    [CTR_KIND_SINGLE_EGRESS] = "single-stage-egress",
};

// ---------------------------------------------------------------------------
// The C-layer functions cc_ctr.S references that the spec-fill path NEVER
// calls.  They exist only so the linker can resolve the object; if any is
// ever reached the harness must fail loud (it would mean the driver is now
// exercising a live-RPC path, which needs the real C layer).
// ---------------------------------------------------------------------------
#define STUB_UNREACHABLE() do { \
    fprintf(stderr, "driver: UNREACHABLE C-layer stub %s called\n", __func__); \
    exit(2); \
} while (0)

int cc_ctr_get_image(int h, const char *image_ref,
                     char *out_name, uint32_t name_cap,
                     char *out_digest, uint32_t digest_cap) {
    (void)h; (void)image_ref; (void)out_name; (void)name_cap;
    (void)out_digest; (void)digest_cap;
    STUB_UNREACHABLE();
}

int cc_ctr_prepare_snapshot(int h, const char *snapshotter, const char *key,
                            const char *parent,
                            struct cc_ctr_mount *out_mounts,
                            uint32_t mounts_cap, uint32_t *out_n_mounts) {
    (void)h; (void)snapshotter; (void)key; (void)parent;
    (void)out_mounts; (void)mounts_cap; (void)out_n_mounts;
    STUB_UNREACHABLE();
}

int cc_ctr_oci_spec_build(const struct cc_ctr_oci_spec *spec, char *out,
                          uint32_t cap) {
    (void)spec; (void)out; (void)cap;
    STUB_UNREACHABLE();
}

int cc_ctr_create_container(int h, const char *id, const char *image_ref,
                            const char *snapshotter, const char *snapshot_key,
                            const char *runtime, const uint8_t *oci_spec_json,
                            uint32_t oci_len) {
    (void)h; (void)id; (void)image_ref; (void)snapshotter;
    (void)snapshot_key; (void)runtime; (void)oci_spec_json; (void)oci_len;
    STUB_UNREACHABLE();
}

int cc_ctr_create_task(int h, const char *container_id,
                       const char *stdout_uri, const char *stderr_uri,
                       uint32_t *out_pid, const char *nvidia_bin) {
    (void)h; (void)container_id; (void)stdout_uri; (void)stderr_uri;
    (void)out_pid; (void)nvidia_bin;
    STUB_UNREACHABLE();
}

int cc_ctr_start_task(int h, const char *container_id, uint32_t *out_pid) {
    (void)h; (void)container_id; (void)out_pid;
    STUB_UNREACHABLE();
}

int cc_ctr_get_container(int h, const char *id,
                         char *out_snapshotter, uint32_t ss_cap,
                         char *out_snapshot_key, uint32_t sk_cap) {
    (void)h; (void)id; (void)out_snapshotter; (void)ss_cap;
    (void)out_snapshot_key; (void)sk_cap;
    STUB_UNREACHABLE();
}

int cc_ctr_get_task(int h, const char *container_id, uint32_t *out_pid) {
    (void)h; (void)container_id; (void)out_pid;
    STUB_UNREACHABLE();
}

int cc_ctr_kill_task(int h, const char *container_id, uint32_t signal) {
    (void)h; (void)container_id; (void)signal;
    STUB_UNREACHABLE();
}

int cc_ctr_wait_task(int h, const char *container_id,
                     uint32_t *out_exit_status) {
    (void)h; (void)container_id; (void)out_exit_status;
    STUB_UNREACHABLE();
}

int cc_ctr_delete_task(int h, const char *container_id,
                       uint32_t *out_exit_status) {
    (void)h; (void)container_id; (void)out_exit_status;
    STUB_UNREACHABLE();
}

int cc_ctr_delete_container(int h, const char *id) {
    (void)h; (void)id;
    STUB_UNREACHABLE();
}

int cc_grpc_set_unary_timeout(int h, uint64_t timeout_ns) {
    (void)h; (void)timeout_ns;
    STUB_UNREACHABLE();
}

// ---------------------------------------------------------------------------
// The asm exports this driver actually uses.
// ---------------------------------------------------------------------------
extern int cc_ctr_init(const void *layout, int h, uint64_t stop_timeout_ns);
extern int cc_ctr_oci_spec_fill(const void *config, int kind,
                                struct cc_ctr_oci_spec *spec_out,
                                struct cc_ctr_oci_mount *mounts_out,
                                char *cgroups_scratch);

// ---------------------------------------------------------------------------
// Tiny stages.conf parser (KEY=VALUE lines, '#' comments).
// ---------------------------------------------------------------------------
#define MAX_KEY 128
#define MAX_VAL 512
#define MAX_ENTRIES 64

struct conf_entry {
    char key[MAX_KEY];
    char val[MAX_VAL];
};

static int conf_load(const char *path, struct conf_entry *entries,
                     int *n_entries) {
    FILE *f = fopen(path, "r");
    if (!f) {
        fprintf(stderr, "driver: cannot open %s\n", path);
        return -1;
    }
    char line[1024];
    *n_entries = 0;
    while (fgets(line, sizeof(line), f)) {
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\n' || *p == '\0') continue;
        char *eq = strchr(p, '=');
        if (!eq) continue;
        if (*n_entries >= MAX_ENTRIES) {
            fprintf(stderr, "driver: too many conf entries\n");
            fclose(f);
            return -1;
        }
        size_t klen = (size_t)(eq - p);
        if (klen == 0 || klen >= MAX_KEY) continue;
        memcpy(entries[*n_entries].key, p, klen);
        entries[*n_entries].key[klen] = '\0';
        char *v = eq + 1;
        char *nl = strchr(v, '\n');
        if (nl) *nl = '\0';
        size_t vlen = strlen(v);
        if (vlen >= MAX_VAL) {
            fprintf(stderr, "driver: value too long for %s\n",
                    entries[*n_entries].key);
            fclose(f);
            return -1;
        }
        memcpy(entries[*n_entries].val, v, vlen + 1);
        (*n_entries)++;
    }
    fclose(f);
    return 0;
}

static const char *conf_get(const struct conf_entry *entries, int n,
                            const char *key) {
    for (int i = 0; i < n; i++)
        if (strcmp(entries[i].key, key) == 0)
            return entries[i].val;
    return NULL;
}

// ---------------------------------------------------------------------------
// Canonical dump (byte-for-byte comparison surface with the Go oracle).
// ---------------------------------------------------------------------------
static void dump_spec(const char *kind, const struct cc_ctr_oci_spec *spec,
                      const struct cc_ctr_oci_mount *mounts) {
    printf("kind=%s\n", kind);
    printf("n_env=%u\n", spec->n_env);
    for (uint32_t i = 0; i < spec->n_env; i++)
        printf("env[%u]=%s\n", i, spec->env[i] ? spec->env[i] : "");
    printf("n_args=%u\n", spec->n_args);
    for (uint32_t i = 0; i < spec->n_args; i++)
        printf("args[%u]=%s\n", i, spec->args[i] ? spec->args[i] : "");
    printf("cwd=%s\n", spec->cwd ? spec->cwd : "/");
    printf("uid=%u\n", spec->uid);
    printf("gid=%u\n", spec->gid);
    printf("n_gids=%u\n", spec->n_additional_gids);
    for (uint32_t i = 0; i < spec->n_additional_gids; i++)
        printf("gids[%u]=%u\n", i, spec->additional_gids[i]);
    printf("n_caps=%u\n", spec->n_caps_add);
    for (uint32_t i = 0; i < spec->n_caps_add; i++)
        printf("caps[%u]=%s\n", i, spec->caps_add[i] ? spec->caps_add[i] : "");
    printf("host_network=%d\n", spec->host_network);
    printf("cgroups=%s\n", spec->cgroups_path ? spec->cgroups_path : "");
    printf("n_mounts=%u\n", spec->n_mounts);
    for (uint32_t i = 0; i < spec->n_mounts; i++) {
        const struct cc_ctr_oci_mount *m = &mounts[i];
        printf("mount[%u].destination=%s\n", i,
               m->destination ? m->destination : "");
        printf("mount[%u].source=%s\n", i, m->source ? m->source : "");
        printf("mount[%u].type=%s\n", i, m->type ? m->type : "");
        printf("mount[%u].n_options=%u\n", i, m->n_options);
        for (uint32_t j = 0; j < m->n_options; j++)
            printf("mount[%u].options[%u]=%s\n", i, j,
                   m->options[j] ? m->options[j] : "");
    }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <stages.conf>\n", argv[0]);
        return 2;
    }

    struct conf_entry entries[MAX_ENTRIES];
    int n_entries = 0;
    if (conf_load(argv[1], entries, &n_entries) != 0)
        return 1;

    const char *layout_paths[8];
    const char *layout_keys[8] = {
        "LAYOUT_ENV", "LAYOUT_TRANSCODE", "LAYOUT_NOTIFY",
        "LAYOUT_MEDIAMTX_TMPL", "LAYOUT_SRT_PASS", "LAYOUT_VIDEO_DIR",
        "LAYOUT_RESOLV_CONF", "LAYOUT_TMP",
    };
    for (int i = 0; i < 8; i++) {
        layout_paths[i] = conf_get(entries, n_entries, layout_keys[i]);
        if (!layout_paths[i]) {
            fprintf(stderr, "driver: missing %s\n", layout_keys[i]);
            return 1;
        }
    }

    const char *ns = conf_get(entries, n_entries, "NAMESPACE");
    if (!ns) {
        fprintf(stderr, "driver: missing NAMESPACE\n");
        return 1;
    }

    // Stage ContainerConfigs (4 strings each: container_id, snapshot_id,
    // image_name, logfile at CC_CC_* offsets).
    const char *stage_ids[CTR_KIND_COUNT];
    const char *stage_keys[CTR_KIND_COUNT][4] = {
        { "MEDIAMTX_ID", "MEDIAMTX_SNAPSHOT", "MEDIAMTX_IMAGE", "MEDIAMTX_LOG" },
        { "NORMALIZE_ID", "NORMALIZE_SNAPSHOT", "NORMALIZE_IMAGE", "NORMALIZE_LOG" },
        { "SCALE_ID", "SCALE_SNAPSHOT", "SCALE_IMAGE", "SCALE_LOG" },
        { "SINGLE_ID", "SINGLE_SNAPSHOT", "SINGLE_IMAGE", "SINGLE_LOG" },
    };
    for (int k = 0; k < CTR_KIND_COUNT; k++) {
        stage_ids[k] = conf_get(entries, n_entries, stage_keys[k][0]);
        if (!stage_ids[k]) {
            fprintf(stderr, "driver: missing %s\n", stage_keys[k][0]);
            return 1;
        }
    }

    // ---- Build the Layout + env-runtime block in one heap region. -------
    // [0, CC_LAY_SIZE)             = Layout: 8 string pointers (CC_LAY_*)
    // [CC_LAY_SIZE, +CC_ER_SIZE)   = env-runtime block: namespace ptr at
    //                               CC_ER_CONTAINERD_NAMESPACE, stage
    //                               ContainerConfigs at CC_ER_<stage>.
    //
    // Slack beyond the env-runtime block is filled with a valid string
    // pointer.  This mirrors production, where the Layout sits inside a
    // larger structure, so an out-of-bounds descriptor read (the OLD
    // scale-8 ctr_fill_mounts bug: Layout[off*8] instead of Layout[off])
    // lands on VALID memory and surfaces as a WRONG mount source — a byte
    // diff vs the oracle — rather than a crash.  That is exactly how the
    // bug reached production (wrong mount paths sent to containerd).
    size_t block_size = CC_LAY_SIZE + CC_ER_SIZE;
    size_t slack_size = 4096;   // enough for the farthest scale-8 read
    unsigned char *block = calloc(1, block_size + slack_size);
    if (!block) {
        fprintf(stderr, "driver: calloc failed\n");
        return 1;
    }

    const char **layout = (const char **)block;
    for (int i = 0; i < 8; i++)
        layout[i] = layout_paths[i];

    // Fill the slack region with the LAYOUT_ENV pointer so any OOB read
    // yields a valid (wrong) string instead of unmapped memory.
    for (size_t off = block_size; off < block_size + slack_size; off += 8)
        memcpy(block + off, &layout_paths[0], sizeof(const char *));

    unsigned char *er = block + CC_LAY_SIZE;
    *(const char **)(er + CC_ER_CONTAINERD_NAMESPACE) = ns;

    for (int k = 0; k < CTR_KIND_COUNT; k++) {
        unsigned char *cfg = er + k_kind_cc_er[k];
        for (int f = 0; f < 4; f++) {
            const char *v = conf_get(entries, n_entries, stage_keys[k][f]);
            if (!v) {
                fprintf(stderr, "driver: missing %s\n", stage_keys[k][f]);
                return 1;
            }
            *(const char **)(cfg + (size_t)f * 8) = v;
        }
    }

    // ---- Module state: ctr_state.layout must be set before spec fill. ----
    if (cc_ctr_init(block, 0, 0) != 0) {
        fprintf(stderr, "driver: cc_ctr_init failed\n");
        return 1;
    }

    // ---- Spec-fill per kind (the comparison surface). --------------------
    struct cc_ctr_oci_spec spec;
    struct cc_ctr_oci_mount mounts[DRIVER_MOUNTS_MAX];
    char scratch[1024];

    for (int kind = 0; kind < CTR_KIND_COUNT; kind++) {
        memset(&spec, 0, sizeof(spec));
        memset(mounts, 0, sizeof(mounts));
        memset(scratch, 0, sizeof(scratch));

        const void *config = er + k_kind_cc_er[kind];
        int rc = cc_ctr_oci_spec_fill(config, kind, &spec, mounts, scratch);
        if (rc != 0) {
            fprintf(stderr, "driver: cc_ctr_oci_spec_fill(kind=%d) -> %d\n",
                    kind, rc);
            return 1;
        }
        dump_spec(k_kind_name[kind], &spec, mounts);
    }

    free(block);
    return 0;
}