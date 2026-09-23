// ============================================================================
// diffcontainerd/driver.c — freestanding x86-64 driver for the containerd
// differential harness.
//
// This driver is the ASM side of differential-containerd.sh.  It links the
// REAL x86-64 cc_ctr.S + cc_util.S objects (the fixed tree versions) and
// drives BOTH comparison surfaces:
//
//   A. mount/spec-fill:
//        cc_ctr_init(layout, h, stop_timeout)          (sets ctr_state.layout)
//        cc_ctr_oci_spec_fill(config, kind, spec_out, mounts_out, scratch)
//            -> ctr_fill_mounts(mounts_out, desc_table, n)
//            -> ctr_build_cgroups(config, spec, scratch)
//
//   B. snapshot / parent-chain (the B2 surface):
//        cc_ctr_apply(stage, CC_STATE_RUNNING)
//            -> ctr_start(config, kind)
//                1. stop() first                        (no-op: NOT_FOUND)
//                2. cc_ctr_get_image(image_ref)         (stub, OK)
//                3. cc_ctr_resolve_chainid(image_ref)   (stub: the image
//                   rootfs diff_ids -> identity.ChainID — B1's parent)
//                4. cc_ctr_prepare_snapshot(snapshotter, key, parent, ...)
//                   (recording stub: captures the asm's actual key + parent)
//                5. cc_ctr_oci_spec_fill / oci_spec_build (real asm)
//                6. cc_ctr_create_container(...)        (stub, OK)
//                7. cc_ctr_create_task / cc_ctr_start_task (stubs, OK)
//
// The driver does NOT link the real C RPC layer (cc_ctr.c / cc_grpc.c); every
// C-layer function the asm references is stubbed below.  The stubs are not
// dead weight: they are the observation surface.  cc_ctr_prepare_snapshot
// RECORDS the (key, parent) the asm actually passes — the exact bytes that
// decide GREEN (parent == the oracle's ChainID) vs RED (parent == "", the
// empty-rootfs bug).  cc_ctr_resolve_chainid supplies the image rootfs
// diff_ids (from stages.conf *_ROOTFS, the REAL image configs) and computes
// the containerd identity.ChainID so B1's fixed asm receives the correct
// parent from the C boundary — exactly as the real C layer would.
//
// The stop-path lookups (get_container/get_task/kill_task/wait_task/...)
// report NOT_FOUND so ctr_stop() no-ops (no container exists at start time),
// mirroring the Go controller's stop-then-start flow.
//
// Output: per kind, the canonical spec block (existing) followed by the
// canonical snapshot block (B2), byte-for-byte comparable with the Go oracle
// (oracle/oracle.go).  Usage: driver <stages.conf>.  Exit: 0 on success;
// non-zero on any parse/fill/start/dump error.
//
// Build with -DDRIVER_INJECT_EMPTY_PARENT to make cc_ctr_resolve_chainid
// return "" — the empty-parent bug class — for the harness's RED
// demonstration (differential-containerd.sh --inject-empty-parent).
// ============================================================================

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../c/cc_ctr.h"   // struct cc_ctr_oci_spec / cc_ctr_oci_mount /
                              // cc_ctr_resolve_chainid declaration

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

// Stage struct / state constants (cc_layout.inc)
#define CC_STATE_RUNNING    0
#define CC_STATE_STOPPED    1
#define CC_STATE_COUNT      2
#define CC_STG_OPS          16
#define CC_STG_SIZE         40

// gRPC status codes (cc_grpc.h) — the stop path treats NotFound as no-op.
#define CC_GRPC_STATUS_NOT_FOUND  5

// Rootfs / snapshot capture bounds.
#define DRIVER_MAX_DIFFIDS   16
#define DRIVER_DIGEST_MAX    256   // "sha512:" + 128 hex = 131, slack
#define DRIVER_REF_MAX       128
#define DRIVER_SNAP_KEY_MAX  128
#define DRIVER_PARENT_MAX    CC_CTR_PARENT_MAX

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
// SHA-256 (FIPS 180-4) — used to compute the image rootfs chainID exactly the
// way containerd's identity.ChainID (opencontainers/image-spec/identity)
// does: chain[0] = diff_ids[0]; chain[i] = sha256(chain[i-1] + " " +
// diff_ids[i]).  The driver emits the chain so the C-side computation is
// byte-compared with the Go oracle (a bug here shows as a RED layer record).
// ---------------------------------------------------------------------------
typedef struct {
    uint32_t h[8];
    uint64_t nbytes;
    uint8_t block[64];
    size_t block_len;
} sha256_ctx;

static const uint32_t sha256_k[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

static uint32_t sha256_rotr(uint32_t x, unsigned n) {
    return (x >> n) | (x << (32u - n));
}

static void sha256_init(sha256_ctx *c) {
    c->h[0] = 0x6a09e667; c->h[1] = 0xbb67ae85; c->h[2] = 0x3c6ef372;
    c->h[3] = 0xa54ff53a; c->h[4] = 0x510e527f; c->h[5] = 0x9b05688c;
    c->h[6] = 0x1f83d9ab; c->h[7] = 0x5be0cd19;
    c->nbytes = 0; c->block_len = 0;
}

static void sha256_process_block(sha256_ctx *c, const uint8_t *p) {
    uint32_t w[64];
    for (int i = 0; i < 16; i++) {
        w[i] = ((uint32_t)p[i * 4] << 24) | ((uint32_t)p[i * 4 + 1] << 16) |
               ((uint32_t)p[i * 4 + 2] << 8) | (uint32_t)p[i * 4 + 3];
    }
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = sha256_rotr(w[i - 15], 7) ^ sha256_rotr(w[i - 15], 18) ^
                      (w[i - 15] >> 3);
        uint32_t s1 = sha256_rotr(w[i - 2], 17) ^ sha256_rotr(w[i - 2], 19) ^
                      (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = c->h[0], b = c->h[1], cc = c->h[2], d = c->h[3];
    uint32_t e = c->h[4], f = c->h[5], g = c->h[6], h = c->h[7];
    for (int i = 0; i < 64; i++) {
        uint32_t s1 = sha256_rotr(e, 6) ^ sha256_rotr(e, 11) ^
                      sha256_rotr(e, 25);
        uint32_t ch = (e & f) ^ (~e & g);
        uint32_t t1 = h + s1 + ch + sha256_k[i] + w[i];
        uint32_t s0 = sha256_rotr(a, 2) ^ sha256_rotr(a, 13) ^
                      sha256_rotr(a, 22);
        uint32_t maj = (a & b) ^ (a & cc) ^ (b & cc);
        uint32_t t2 = s0 + maj;
        h = g; g = f; f = e; e = d + t1;
        d = cc; cc = b; b = a; a = t1 + t2;
    }
    c->h[0] += a; c->h[1] += b; c->h[2] += cc; c->h[3] += d;
    c->h[4] += e; c->h[5] += f; c->h[6] += g; c->h[7] += h;
}

static void sha256_update(sha256_ctx *c, const void *data, size_t len) {
    const uint8_t *p = data;
    c->nbytes += len;
    while (len > 0) {
        size_t take = 64 - c->block_len;
        if (take > len) take = len;
        memcpy(c->block + c->block_len, p, take);
        c->block_len += take;
        p += take;
        len -= take;
        if (c->block_len == 64) {
            sha256_process_block(c, c->block);
            c->block_len = 0;
        }
    }
}

static void sha256_final(sha256_ctx *c, uint8_t out[32]) {
    uint64_t bits = c->nbytes * 8;
    uint8_t pad = 0x80;
    sha256_update(c, &pad, 1);
    uint8_t zero = 0;
    while (c->block_len != 56)
        sha256_update(c, &zero, 1);
    uint8_t lenbuf[8];
    for (int i = 0; i < 8; i++)
        lenbuf[i] = (uint8_t)(bits >> (56 - 8 * i));
    sha256_update(c, lenbuf, 8);
    for (int i = 0; i < 8; i++) {
        out[i * 4]     = (uint8_t)(c->h[i] >> 24);
        out[i * 4 + 1] = (uint8_t)(c->h[i] >> 16);
        out[i * 4 + 2] = (uint8_t)(c->h[i] >> 8);
        out[i * 4 + 3] = (uint8_t)(c->h[i]);
    }
}

// chainid_next: out = "sha256:" + hex(sha256(prev + " " + diff)).
static void chainid_next(const char *prev, const char *diff, char *out,
                         size_t out_cap) {
    sha256_ctx c;
    sha256_init(&c);
    sha256_update(&c, prev, strlen(prev));
    sha256_update(&c, " ", 1);
    sha256_update(&c, diff, strlen(diff));
    uint8_t d[32];
    sha256_final(&c, d);
    static const char hexdig[] = "0123456789abcdef";
    if (out_cap < 72) return;  // 7 + 64 hex + NUL; guarded by caller caps
    memcpy(out, "sha256:", 7);
    for (int i = 0; i < 32; i++) {
        out[7 + i * 2]     = hexdig[d[i] >> 4];
        out[7 + i * 2 + 1] = hexdig[d[i] & 15];
    }
    out[71] = '\0';
}

// ---------------------------------------------------------------------------
// Image rootfs state (the shared input the oracle and the driver both derive
// the parent chain from).  Parsed from stages.conf *_ROOTFS.
// ---------------------------------------------------------------------------
struct stage_rootfs {
    char image_ref[DRIVER_REF_MAX];
    char diffs[DRIVER_MAX_DIFFIDS][DRIVER_DIGEST_MAX];
    char chain[DRIVER_MAX_DIFFIDS][DRIVER_DIGEST_MAX];
    int n_diffs;
};

static struct stage_rootfs g_rootfs[CTR_KIND_COUNT];

#ifndef DRIVER_INJECT_EMPTY_PARENT
static const struct stage_rootfs *rootfs_by_ref(const char *image_ref) {
    if (!image_ref) return NULL;
    for (int k = 0; k < CTR_KIND_COUNT; k++)
        if (strcmp(g_rootfs[k].image_ref, image_ref) == 0)
            return &g_rootfs[k];
    return NULL;
}
#endif

// str_copy_bounded: copy src into dst, always NUL-terminated, never overflow.
static void str_copy_bounded(char *dst, size_t dst_cap, const char *src) {
    if (!src || dst_cap == 0) {
        if (dst_cap > 0) dst[0] = '\0';
        return;
    }
    size_t n = strlen(src);
    if (n >= dst_cap) n = dst_cap - 1;
    memcpy(dst, src, n);
    dst[n] = '\0';
}

static int parse_rootfs(const char *val, struct stage_rootfs *rf,
                        const char *image_ref) {
    str_copy_bounded(rf->image_ref, sizeof(rf->image_ref), image_ref);
    rf->n_diffs = 0;
    const char *p = val;
    while (*p) {
        if (rf->n_diffs >= DRIVER_MAX_DIFFIDS) {
            fprintf(stderr, "driver: too many diff_ids in %s\n", image_ref);
            return -1;
        }
        const char *comma = strchr(p, ',');
        size_t n = comma ? (size_t)(comma - p) : strlen(p);
        if (n == 0 || n >= DRIVER_DIGEST_MAX) {
            fprintf(stderr, "driver: bad diff_id in %s\n", image_ref);
            return -1;
        }
        memcpy(rf->diffs[rf->n_diffs], p, n);
        rf->diffs[rf->n_diffs][n] = '\0';
        rf->n_diffs++;
        p = comma ? comma + 1 : p + n;
    }
    for (int i = 0; i < rf->n_diffs; i++) {
        if (i == 0) {
            str_copy_bounded(rf->chain[0], DRIVER_DIGEST_MAX, rf->diffs[0]);
        } else {
            chainid_next(rf->chain[i - 1], rf->diffs[i], rf->chain[i],
                         DRIVER_DIGEST_MAX);
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Snapshot capture (the observation surface of the B2 comparison).
// ---------------------------------------------------------------------------
struct snapshot_capture {
    int captured;                       // cc_ctr_prepare_snapshot was called
    char key[DRIVER_SNAP_KEY_MAX];      // the asm's Prepare key arg
    char parent[DRIVER_PARENT_MAX];     // the asm's Prepare parent arg
};

static struct snapshot_capture g_snap;

// ---------------------------------------------------------------------------
// The C-layer functions cc_ctr.S references.  The start/stop path now reaches
// every one of them (unlike the old spec-fill-only driver), so each stub
// either records (prepare/get) or returns the status the asm's sequence
// expects (get_container = NotFound -> stop() no-ops; task ops = OK).
// ---------------------------------------------------------------------------
int cc_ctr_get_image(int h, const char *image_ref,
                     char *out_name, uint32_t name_cap,
                     char *out_digest, uint32_t digest_cap) {
    (void)h; (void)image_ref;
    if (out_name && name_cap > 0) out_name[0] = '\0';
    if (out_digest && digest_cap > 0) out_digest[0] = '\0';
    return 0;   // Images/Get OK; the rootfs travels via resolve_chainid
}

int cc_ctr_resolve_chainid(int h, const char *image_ref,
                           char *out_parent, uint32_t parent_cap) {
    (void)h;
    if (!out_parent || parent_cap == 0)
        return CC_CTR_ERR_BADARG;
#ifdef DRIVER_INJECT_EMPTY_PARENT
    // The empty-parent bug class: the container snapshot is prepared with NO
    // parent, so the rootfs contains no image layers (exec /entrypoint.sh
    // not-found).  The oracle's snapshot_parent is the real ChainID, so the
    // differential turns RED — proving the harness catches this bug.
    (void)image_ref;
    out_parent[0] = '\0';
    return 0;
#else
    const struct stage_rootfs *rf = rootfs_by_ref(image_ref);
    if (!rf || rf->n_diffs <= 0) {
        out_parent[0] = '\0';
        return 0;                       // unknown/no-layer image: base parent
    }
    const char *parent = rf->chain[rf->n_diffs - 1];
    if (strlen(parent) + 1 > parent_cap)
        return CC_CTR_ERR_TOOBIG;
    memcpy(out_parent, parent, strlen(parent) + 1);
    return 0;
#endif
}

int cc_ctr_prepare_snapshot(int h, const char *snapshotter, const char *key,
                            const char *parent,
                            struct cc_ctr_mount *out_mounts,
                            uint32_t mounts_cap, uint32_t *out_n_mounts) {
    (void)h; (void)snapshotter; (void)out_mounts; (void)mounts_cap;
    g_snap.captured = 1;
    str_copy_bounded(g_snap.key, sizeof(g_snap.key), key);
    str_copy_bounded(g_snap.parent, sizeof(g_snap.parent), parent);
    if (out_n_mounts) *out_n_mounts = 0;
    return 0;                           // Snapshots/Prepare OK, no mounts
}

int cc_ctr_oci_spec_build(const struct cc_ctr_oci_spec *spec, char *out,
                          uint32_t cap) {
    (void)spec; (void)out; (void)cap;
    return 0;                           // empty spec JSON; len 0 (>= 0 = OK)
}

int cc_ctr_create_container(int h, const char *id, const char *image_ref,
                            const char *snapshotter, const char *snapshot_key,
                            const char *runtime, const uint8_t *oci_spec_json,
                            uint32_t oci_len) {
    (void)h; (void)id; (void)image_ref; (void)snapshotter;
    (void)snapshot_key; (void)runtime; (void)oci_spec_json; (void)oci_len;
    return 0;                           // Containers/Create OK
}

int cc_ctr_create_task(int h, const char *container_id,
                       const char *stdout_uri, const char *stderr_uri,
                       uint32_t *out_pid, const char *nvidia_bin) {
    (void)h; (void)container_id; (void)stdout_uri; (void)stderr_uri;
    (void)out_pid; (void)nvidia_bin;
    return 0;                           // Tasks/Create OK
}

int cc_ctr_start_task(int h, const char *container_id, uint32_t *out_pid) {
    (void)h; (void)container_id; (void)out_pid;
    return 0;                           // Tasks/Start OK
}

int cc_ctr_get_container(int h, const char *id,
                         char *out_snapshotter, uint32_t ss_cap,
                         char *out_snapshot_key, uint32_t sk_cap) {
    (void)h; (void)id;
    if (out_snapshotter && ss_cap > 0) out_snapshotter[0] = '\0';
    if (out_snapshot_key && sk_cap > 0) out_snapshot_key[0] = '\0';
    return CC_GRPC_STATUS_NOT_FOUND;    // stop() no-op: no container yet
}

int cc_ctr_get_task(int h, const char *container_id, uint32_t *out_pid) {
    (void)h; (void)container_id; (void)out_pid;
    return CC_GRPC_STATUS_NOT_FOUND;
}

int cc_ctr_kill_task(int h, const char *container_id, uint32_t signal) {
    (void)h; (void)container_id; (void)signal;
    return CC_GRPC_STATUS_NOT_FOUND;
}

int cc_ctr_wait_task(int h, const char *container_id,
                     uint32_t *out_exit_status) {
    (void)h; (void)container_id; (void)out_exit_status;
    return CC_GRPC_STATUS_NOT_FOUND;
}

int cc_ctr_delete_task(int h, const char *container_id,
                       uint32_t *out_exit_status) {
    (void)h; (void)container_id; (void)out_exit_status;
    return CC_GRPC_STATUS_NOT_FOUND;
}

int cc_ctr_delete_container(int h, const char *id) {
    (void)h; (void)id;
    return CC_GRPC_STATUS_NOT_FOUND;
}

int cc_grpc_set_unary_timeout(int h, uint64_t timeout_ns) {
    (void)h; (void)timeout_ns;
    return 0;
}

// ---------------------------------------------------------------------------
// The asm exports this driver actually uses.
// ---------------------------------------------------------------------------
extern int cc_ctr_init(const void *layout, int h, uint64_t stop_timeout_ns);
extern int cc_ctr_oci_spec_fill(const void *config, int kind,
                                struct cc_ctr_oci_spec *spec_out,
                                struct cc_ctr_oci_mount *mounts_out,
                                char *cgroups_scratch);
extern int cc_ctr_apply(void *stage, int target);
extern int cc_ctr_mediamtx_start(void *stage);
extern int cc_ctr_mediamtx_stop(void *stage);
extern int cc_ctr_normalize_start(void *stage);
extern int cc_ctr_normalize_stop(void *stage);
extern int cc_ctr_scale_egress_start(void *stage);
extern int cc_ctr_scale_egress_stop(void *stage);
extern int cc_ctr_single_egress_start(void *stage);
extern int cc_ctr_single_egress_stop(void *stage);

typedef int (*driver_op_fn)(void *stage);

static const driver_op_fn k_kind_start[CTR_KIND_COUNT] = {
    [CTR_KIND_MEDIAMTX]      = cc_ctr_mediamtx_start,
    [CTR_KIND_NORMALIZE]     = cc_ctr_normalize_start,
    [CTR_KIND_SCALE_EGRESS]  = cc_ctr_scale_egress_start,
    [CTR_KIND_SINGLE_EGRESS] = cc_ctr_single_egress_start,
};

static const driver_op_fn k_kind_stop[CTR_KIND_COUNT] = {
    [CTR_KIND_MEDIAMTX]      = cc_ctr_mediamtx_stop,
    [CTR_KIND_NORMALIZE]     = cc_ctr_normalize_stop,
    [CTR_KIND_SCALE_EGRESS]  = cc_ctr_scale_egress_stop,
    [CTR_KIND_SINGLE_EGRESS] = cc_ctr_single_egress_stop,
};

// Minimal Stage (cc_layout.inc): status {desired, actual}, ops TABLE POINTER
// at CC_STG_OPS (the table holds one fn ptr per CC_STATE_* index),
// inflightSince timespec at +24.
struct driver_stage {
    uint64_t status_desired;            // +0  (CC_STG_STATUS)
    uint64_t status_actual;             // +8
    driver_op_fn *ops_table;            // +16 (CC_STG_OPS): pointer
    uint64_t inflight[2];               // +24 (CC_STG_INFLIGHT_SINCE)
};                                      // 40 bytes == CC_STG_SIZE

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

// dump_snapshot: the B2 record block.  snapshot_key/snapshot_parent come from
// what the ASM actually passed to cc_ctr_prepare_snapshot (the observation
// surface); n_layers + the per-layer diff/key/parent records come from the
// driver's C chainID computation over the supplied image rootfs (a
// byte-for-byte cross-check of the C chain math vs the Go oracle).
static void dump_snapshot(const struct stage_rootfs *rf) {
    printf("snapshot_key=%s\n", g_snap.captured ? g_snap.key : "");
    printf("snapshot_parent=%s\n", g_snap.captured ? g_snap.parent : "");
    printf("n_layers=%d\n", rf->n_diffs);
    for (int i = 0; i < rf->n_diffs; i++) {
        printf("layer[%d].diff=%s\n", i, rf->diffs[i]);
        printf("layer[%d].key=%s\n", i, rf->chain[i]);
        printf("layer[%d].parent=%s\n", i, i > 0 ? rf->chain[i - 1] : "");
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

    // Image rootfs diff_ids (stages.conf *_ROOTFS) — the shared B2 input.
    const char *stage_rootfs_keys[CTR_KIND_COUNT] = {
        "MEDIAMTX_ROOTFS", "NORMALIZE_ROOTFS", "SCALE_ROOTFS", "SINGLE_ROOTFS",
    };
    for (int k = 0; k < CTR_KIND_COUNT; k++) {
        const char *image_ref = conf_get(entries, n_entries, stage_keys[k][2]);
        const char *rootfs_val = conf_get(entries, n_entries,
                                          stage_rootfs_keys[k]);
        if (!image_ref || !rootfs_val) {
            fprintf(stderr, "driver: missing %s\n", stage_rootfs_keys[k]);
            return 1;
        }
        if (parse_rootfs(rootfs_val, &g_rootfs[k], image_ref) != 0)
            return 1;
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
                free(block);
                return 1;
            }
            *(const char **)(cfg + (size_t)f * 8) = v;
        }
    }

    // ---- Module state: ctr_state.layout must be set before spec fill. ----
    if (cc_ctr_init(block, 0, 0) != 0) {
        fprintf(stderr, "driver: cc_ctr_init failed\n");
        free(block);
        return 1;
    }

    // ---- Per kind: spec-fill records + snapshot records. -----------------
    struct cc_ctr_oci_spec spec;
    struct cc_ctr_oci_mount mounts[DRIVER_MOUNTS_MAX];
    char scratch[1024];

    for (int kind = 0; kind < CTR_KIND_COUNT; kind++) {
        memset(&spec, 0, sizeof(spec));
        memset(mounts, 0, sizeof(mounts));
        memset(scratch, 0, sizeof(scratch));

        // Pass A: the mount/spec-fill surface (existing).
        const void *config = er + k_kind_cc_er[kind];
        int rc = cc_ctr_oci_spec_fill(config, kind, &spec, mounts, scratch);
        if (rc != 0) {
            fprintf(stderr, "driver: cc_ctr_oci_spec_fill(kind=%d) -> %d\n",
                    kind, rc);
            free(block);
            return 1;
        }
        dump_spec(k_kind_name[kind], &spec, mounts);

        // Pass B: drive the start op (Images/Get -> resolve chainID ->
        // Snapshots/Prepare -> Mounts) and dump the snapshot records.  The
        // recording prepare stub captures what the asm ACTUALLY passed.
        driver_op_fn ops_table[CC_STATE_COUNT];
        ops_table[CC_STATE_RUNNING] = k_kind_start[kind];
        ops_table[CC_STATE_STOPPED] = k_kind_stop[kind];
        struct driver_stage stage;
        memset(&stage, 0, sizeof(stage));
        stage.ops_table = ops_table;
        memset(&g_snap, 0, sizeof(g_snap));

        int src = cc_ctr_apply(&stage, CC_STATE_RUNNING);
        if (src != 0) {
            fprintf(stderr, "driver: cc_ctr_apply(kind=%d) -> %d\n", kind, src);
            free(block);
            return 1;
        }
        if (!g_snap.captured) {
            fprintf(stderr,
                    "driver: asm did not call Snapshots/Prepare (kind=%d) — "
                    "the start path diverged\n", kind);
            free(block);
            return 1;
        }
        dump_snapshot(&g_rootfs[kind]);
    }

    free(block);
    return 0;
}