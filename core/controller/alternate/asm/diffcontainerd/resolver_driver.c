// ============================================================================
// diffcontainerd/resolver_driver.c — REAL C-layer chainID resolver driver.
//
// This driver closes the Gate-3 coverage gap that left the shipped C-layer
// containerd chainID resolver (`cc_ctr_resolve_chainid` in
// core/controller/alternate/c/cc_ctr.c — its self-contained SHA-256, JSON path
// extractor, Images/Get + Content/Read request framing, and the
// identity.ChainID computation) unexecuted by the differential harness.
//
// Unlike the asm driver (driver.c), which STUBS cc_ctr_resolve_chainid and
// feeds the parent from stages.conf, this driver LINKS THE REAL shipped
// cc_ctr.c (via --gc-sections, so only the resolver and its static helpers
// are retained) and drives it end-to-end through a canned-but-faithful
// containerd:
//
//   * a test-only `cc_grpc_unary` TRANSPORT STUB (the h2c/gRPC layer is NOT
//     the surface under test) that, for every request the REAL C code sends,
//     (1) UNPACKS the request with the REAL vendored codecs — proving the
//     C layer's Images/Get and Content/Read request framing is byte-exact,
//     and (2) returns CANNED byte-exact protobuf responses (packed with the
//     REAL codecs) whose blob content is built from the REAL image diff_ids
//     in stages.conf (*_ROOTFS).
//   * the driver then prints `resolver_stage=<kind>` + `resolver_parent=<...>`
//     per stage, and the harness byte-compares resolver_parent against the Go
//     oracle's identity.ChainID (oracle.go --resolver).
//
// THE CANNED CONTENT (built from stages.conf *_ROOTFS, the REAL image
// configs):
//   config JSON   = {"architecture":"amd64","os":"linux","rootfs":
//                   {"type":"layers","diff_ids":[<REAL diff_ids>]}}
//   config digest = sha256(config_json), config size = len(config_json)
//   manifest JSON = OCI manifest whose config.digest/config.size point at
//                   the config blob above
//   manifest digest/size = sha256/size of the manifest JSON
//
// The stub behaves like a real containerd content store keyed by digest: a
// Content/Read request whose digest is unknown, or whose offset/size do not
// match the registered blob, FAILS LOUDLY (CC_GRPC_ERR_PROTO) — a request-
// framing bug in the C layer turns the differential RED instead of silently
// mis-reading.
//
// NEGATIVE CASE (fail-loud proof): two malformed config blobs —
// (a) truncated JSON and (b) config missing rootfs.diff_ids — must make the
// REAL resolver return a CC_CTR_ERR_* code (CC_CTR_ERR_STATE) and an empty
// parent, and must NOT crash.  The driver prints `resolver_negative=<rc>`
// for each; a wrong answer (OK + garbage parent) makes the driver exit
// non-zero so the harness reports RED.
//
// Output: per stage, `resolver_stage=<kind>` + `resolver_parent=<chainID>`;
// then `resolver_negative=<rc>` lines.  Usage: resolver_driver <stages.conf>.
// Exit: 0 when all 4 stages resolve AND both negative cases are rejected
// loudly; non-zero otherwise.
// ============================================================================

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../../c/cc_ctr.h"
#include "../../c/cc_grpc.h"

#include <services/content/v1/content.pb-c.h>
#include <services/images/v1/images.pb-c.h>

// ---------------------------------------------------------------------------
// Constants (mirrored from cc_ctr.h / stages.conf bounds).
// ---------------------------------------------------------------------------
#define RESOLVER_MAX_STAGES 4
#define RESOLVER_REF_MAX 128
#define RESOLVER_DIGEST_MAX 256
#define RESOLVER_PARENT_MAX CC_CTR_PARENT_MAX
#define RESOLVER_MAX_DIFFIDS CC_CTR_MAX_DIFFIDS
#define RESOLVER_MAX_BLOBS 16
#define RESOLVER_MAX_IMAGES 8
#define RESOLVER_JSON_MAX 2048

// gRPC status codes (cc_grpc.h) — the stub's fail-loud answers.
#define CC_GRPC_STATUS_NOT_FOUND 5

// ---------------------------------------------------------------------------
// SHA-256 (FIPS 180-4) — used ONLY to digest the CANNED blobs (the digest
// strings are content-addressing keys, exactly like containerd's content
// store).  The chainID itself is computed by the REAL cc_ctr.c SHA-256 under
// test, never here.
// ---------------------------------------------------------------------------
typedef struct {
    uint32_t h[8];
    uint64_t nbytes;
    uint8_t block[64];
    size_t block_len;
} rsha256_ctx;

static const uint32_t rsha256_k[64] = {
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

static uint32_t rsha256_rotr(uint32_t x, unsigned n) {
    return (x >> n) | (x << (32u - n));
}

static void rsha256_init(rsha256_ctx *c) {
    c->h[0] = 0x6a09e667; c->h[1] = 0xbb67ae85; c->h[2] = 0x3c6ef372;
    c->h[3] = 0xa54ff53a; c->h[4] = 0x510e527f; c->h[5] = 0x9b05688c;
    c->h[6] = 0x1f83d9ab; c->h[7] = 0x5be0cd19;
    c->nbytes = 0; c->block_len = 0;
}

static void rsha256_block(rsha256_ctx *c, const uint8_t *p) {
    uint32_t w[64];
    for (int i = 0; i < 16; i++) {
        w[i] = ((uint32_t)p[i * 4] << 24) | ((uint32_t)p[i * 4 + 1] << 16) |
               ((uint32_t)p[i * 4 + 2] << 8) | (uint32_t)p[i * 4 + 3];
    }
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = rsha256_rotr(w[i - 15], 7) ^ rsha256_rotr(w[i - 15], 18) ^
                      (w[i - 15] >> 3);
        uint32_t s1 = rsha256_rotr(w[i - 2], 17) ^ rsha256_rotr(w[i - 2], 19) ^
                      (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = c->h[0], b = c->h[1], cc = c->h[2], d = c->h[3];
    uint32_t e = c->h[4], f = c->h[5], g = c->h[6], h = c->h[7];
    for (int i = 0; i < 64; i++) {
        uint32_t s1 = rsha256_rotr(e, 6) ^ rsha256_rotr(e, 11) ^
                      rsha256_rotr(e, 25);
        uint32_t ch = (e & f) ^ (~e & g);
        uint32_t t1 = h + s1 + ch + rsha256_k[i] + w[i];
        uint32_t s0 = rsha256_rotr(a, 2) ^ rsha256_rotr(a, 13) ^
                      rsha256_rotr(a, 22);
        uint32_t maj = (a & b) ^ (a & cc) ^ (b & cc);
        uint32_t t2 = s0 + maj;
        h = g; g = f; f = e; e = d + t1;
        d = cc; cc = b; b = a; a = t1 + t2;
    }
    c->h[0] += a; c->h[1] += b; c->h[2] += cc; c->h[3] += d;
    c->h[4] += e; c->h[5] += f; c->h[6] += g; c->h[7] += h;
}

static void rsha256_update(rsha256_ctx *c, const void *data, size_t len) {
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
            rsha256_block(c, c->block);
            c->block_len = 0;
        }
    }
}

static void rsha256_final(rsha256_ctx *c, uint8_t out[32]) {
    uint64_t bits = c->nbytes * 8;
    uint8_t pad = 0x80;
    rsha256_update(c, &pad, 1);
    uint8_t zero = 0;
    while (c->block_len != 56)
        rsha256_update(c, &zero, 1);
    uint8_t lenbuf[8];
    for (int i = 0; i < 8; i++)
        lenbuf[i] = (uint8_t)(bits >> (56 - 8 * i));
    rsha256_update(c, lenbuf, 8);
    for (int i = 0; i < 8; i++) {
        out[i * 4]     = (uint8_t)(c->h[i] >> 24);
        out[i * 4 + 1] = (uint8_t)(c->h[i] >> 16);
        out[i * 4 + 2] = (uint8_t)(c->h[i] >> 8);
        out[i * 4 + 3] = (uint8_t)(c->h[i]);
    }
}

/* sha256_hex: out must hold 65+ bytes. */
static void rsha256_hex(const void *data, size_t len, char *out) {
    rsha256_ctx c;
    uint8_t d[32];
    static const char hexdig[] = "0123456789abcdef";
    rsha256_init(&c);
    rsha256_update(&c, data, len);
    rsha256_final(&c, d);
    memcpy(out, "sha256:", 7);
    for (int i = 0; i < 32; i++) {
        out[7 + i * 2]     = hexdig[d[i] >> 4];
        out[7 + i * 2 + 1] = hexdig[d[i] & 15];
    }
    out[71] = '\0';
}

// ---------------------------------------------------------------------------
// The canned content store + image table the transport stub serves.
// ---------------------------------------------------------------------------
struct content_blob {
    char digest[RESOLVER_DIGEST_MAX];
    const char *data;
    size_t len;
};

struct image_record {
    char name[RESOLVER_REF_MAX];
    char manifest_digest[RESOLVER_DIGEST_MAX];
    int64_t manifest_size;
};

static struct content_blob g_blobs[RESOLVER_MAX_BLOBS];
static size_t g_n_blobs = 0;
static struct image_record g_images[RESOLVER_MAX_IMAGES];
static size_t g_n_images = 0;

static const struct content_blob *blob_by_digest(const char *digest) {
    for (size_t i = 0; i < g_n_blobs; i++)
        if (strcmp(g_blobs[i].digest, digest) == 0)
            return &g_blobs[i];
    return NULL;
}

static const struct image_record *image_by_name(const char *name) {
    for (size_t i = 0; i < g_n_images; i++)
        if (strcmp(g_images[i].name, name) == 0)
            return &g_images[i];
    return NULL;
}

static int blob_register(const char *digest, const char *data, size_t len) {
    if (g_n_blobs >= RESOLVER_MAX_BLOBS)
        return -1;
    strncpy(g_blobs[g_n_blobs].digest, digest, sizeof(g_blobs[g_n_blobs].digest) - 1);
    g_blobs[g_n_blobs].digest[sizeof(g_blobs[g_n_blobs].digest) - 1] = '\0';
    g_blobs[g_n_blobs].data = data;
    g_blobs[g_n_blobs].len = len;
    g_n_blobs++;
    return 0;
}

static int image_register(const char *name, const char *manifest_digest,
                          int64_t manifest_size) {
    if (g_n_images >= RESOLVER_MAX_IMAGES)
        return -1;
    strncpy(g_images[g_n_images].name, name,
            sizeof(g_images[g_n_images].name) - 1);
    g_images[g_n_images].name[sizeof(g_images[g_n_images].name) - 1] = '\0';
    strncpy(g_images[g_n_images].manifest_digest, manifest_digest,
            sizeof(g_images[g_n_images].manifest_digest) - 1);
    g_images[g_n_images].manifest_digest
        [sizeof(g_images[g_n_images].manifest_digest) - 1] = '\0';
    g_images[g_n_images].manifest_size = manifest_size;
    g_n_images++;
    return 0;
}

// ---------------------------------------------------------------------------
// The transport STUB — the ONLY stubbed surface.  It unpack-checks every
// request the REAL C layer sends (proving request framing) and returns
// canned byte-exact responses (packed with the REAL codecs).
// ---------------------------------------------------------------------------
int cc_grpc_unary(int h, const char *method, const uint8_t *req,
                  uint32_t req_len, uint8_t *resp, uint32_t resp_cap,
                  uint32_t *resp_len) {
    (void)h;

    if (strcmp(method, "/containerd.services.images.v1.Images/Get") == 0) {
        Containerd__Services__Images__V1__GetImageRequest *q =
            containerd__services__images__v1__get_image_request__unpack(
                NULL, req_len, req);
        if (q == NULL)
            return CC_GRPC_ERR_PROTO;   /* request framing unparseable */
        const struct image_record *img = image_by_name(q->name);
        containerd__services__images__v1__get_image_request__free_unpacked(
            q, NULL);
        if (img == NULL)
            return CC_GRPC_STATUS_NOT_FOUND;

        Containerd__Services__Images__V1__GetImageResponse r =
            CONTAINERD__SERVICES__IMAGES__V1__GET_IMAGE_RESPONSE__INIT;
        Containerd__Services__Images__V1__Image im =
            CONTAINERD__SERVICES__IMAGES__V1__IMAGE__INIT;
        Containerd__Types__Descriptor desc = CONTAINERD__TYPES__DESCRIPTOR__INIT;
        desc.digest = (char *)img->manifest_digest;
        desc.size = img->manifest_size;
        im.name = (char *)img->name;
        im.target = &desc;
        r.image = &im;
        size_t n = containerd__services__images__v1__get_image_response__get_packed_size(&r);
        if (n > resp_cap)
            return CC_GRPC_ERR_TOOBIG;
        containerd__services__images__v1__get_image_response__pack(&r, resp);
        *resp_len = (uint32_t)n;
        return CC_GRPC_STATUS_OK;
    }

    if (strcmp(method, "/containerd.services.content.v1.Content/Read") == 0) {
        Containerd__Services__Content__V1__ReadContentRequest *q =
            containerd__services__content__v1__read_content_request__unpack(
                NULL, req_len, req);
        if (q == NULL)
            return CC_GRPC_ERR_PROTO;
        const struct content_blob *blob = blob_by_digest(q->digest);
        int64_t req_off = q->offset;
        int64_t req_size = q->size;
        containerd__services__content__v1__read_content_request__free_unpacked(
            q, NULL);
        if (blob == NULL)
            return CC_GRPC_STATUS_NOT_FOUND;
        /* The Go oracle's content reader sends offset=0, size=desc.Size; a
         * framing bug in the C layer (wrong digest/offset/size) must fail
         * loudly, not silently mis-read. */
        if (req_off != 0 || req_size != (int64_t)blob->len)
            return CC_GRPC_ERR_PROTO;

        Containerd__Services__Content__V1__ReadContentResponse r =
            CONTAINERD__SERVICES__CONTENT__V1__READ_CONTENT_RESPONSE__INIT;
        r.data.data = (uint8_t *)blob->data;
        r.data.len = blob->len;
        size_t n = containerd__services__content__v1__read_content_response__get_packed_size(&r);
        if (n > resp_cap)
            return CC_GRPC_ERR_TOOBIG;
        containerd__services__content__v1__read_content_response__pack(&r, resp);
        *resp_len = (uint32_t)n;
        return CC_GRPC_STATUS_OK;
    }

    /* Any other method is not part of the resolver surface; fail loud. */
    return CC_GRPC_ERR_PROTO;
}

// ---------------------------------------------------------------------------
// stages.conf loader (KEY=VALUE lines, '#' comments) + rootfs parser.
// ---------------------------------------------------------------------------
#define CONF_MAX_KEY 128
#define CONF_MAX_VAL 512
#define CONF_MAX_ENTRIES 64

struct conf_entry {
    char key[CONF_MAX_KEY];
    char val[CONF_MAX_VAL];
};

static int conf_load(const char *path, struct conf_entry *entries,
                     int *n_entries) {
    FILE *f = fopen(path, "r");
    if (!f) {
        fprintf(stderr, "resolver_driver: cannot open %s\n", path);
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
        if (*n_entries >= CONF_MAX_ENTRIES) {
            fprintf(stderr, "resolver_driver: too many conf entries\n");
            fclose(f);
            return -1;
        }
        size_t klen = (size_t)(eq - p);
        if (klen == 0 || klen >= CONF_MAX_KEY) continue;
        memcpy(entries[*n_entries].key, p, klen);
        entries[*n_entries].key[klen] = '\0';
        char *v = eq + 1;
        char *nl = strchr(v, '\n');
        if (nl) *nl = '\0';
        size_t vlen = strlen(v);
        if (vlen >= CONF_MAX_VAL) {
            fprintf(stderr, "resolver_driver: value too long for %s\n",
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
// Canned blob construction from the REAL diff_ids.
// ---------------------------------------------------------------------------
struct stage_input {
    const char *kind;
    const char *image_ref;
    const char *rootfs_val;
};

static int parse_diffids(const char *val, char (*diffs)[RESOLVER_DIGEST_MAX],
                         uint32_t *n) {
    *n = 0;
    const char *p = val;
    while (*p) {
        if (*n >= RESOLVER_MAX_DIFFIDS) return -1;
        const char *comma = strchr(p, ',');
        size_t len = comma ? (size_t)(comma - p) : strlen(p);
        if (len == 0 || len >= RESOLVER_DIGEST_MAX) return -1;
        memcpy(diffs[*n], p, len);
        diffs[*n][len] = '\0';
        (*n)++;
        p = comma ? comma + 1 : p + len;
    }
    return 0;
}

/* Register a full image (config blob + manifest blob + image record) whose
 * config JSON is the given string.  Used for the REAL stages and for the
 * malformed-config negative cases: the manifest always points at the config
 * blob's real digest/size, so the resolver reaches the config and only the
 * JSON content decides the outcome.  Returns 0 on success. */
static int register_image_with_config(const char *image_ref,
                                      const char *config_json,
                                      size_t config_len) {
    char manifest_json[RESOLVER_JSON_MAX];
    char config_digest[RESOLVER_DIGEST_MAX];
    char manifest_digest[RESOLVER_DIGEST_MAX];
    size_t manifest_len;
    int rc = -1;

    rsha256_hex(config_json, config_len, config_digest);
    if (blob_register(config_digest, config_json, config_len) != 0)
        goto out;

    /* manifest JSON: OCI manifest pointing at the config blob. */
    {
        size_t off = 0;
#define APPEND(...) do { int n = snprintf(manifest_json + off, sizeof(manifest_json) - off, __VA_ARGS__); if (n < 0 || (size_t)n >= sizeof(manifest_json) - off) goto out; off += (size_t)n; } while (0)
        APPEND("{\"schemaVersion\":2,\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",");
        APPEND("\"config\":{\"mediaType\":\"application/vnd.oci.image.config.v1+json\",");
        APPEND("\"digest\":\"%s\",\"size\":%zu},\"layers\":[]}",
               config_digest, config_len);
        manifest_len = off;
#undef APPEND
    }
    rsha256_hex(manifest_json, manifest_len, manifest_digest);
    if (blob_register(manifest_digest, manifest_json, manifest_len) != 0)
        goto out;
    if (image_register(image_ref, manifest_digest, (int64_t)manifest_len) != 0)
        goto out;
    rc = 0;

out:
    return rc;
}

/* Build the config + manifest JSON blobs for a stage from the REAL rootfs
 * diff_ids and register them in the content store + image table.  Returns 0
 * on success. */
static int register_image(const char *image_ref, const char *rootfs_val) {
    char diffids[RESOLVER_MAX_DIFFIDS][RESOLVER_DIGEST_MAX];
    uint32_t n_diffids = 0;
    char config_json[RESOLVER_JSON_MAX];
    size_t config_len;
    int rc = -1;

    if (parse_diffids(rootfs_val, diffids, &n_diffids) != 0) {
        fprintf(stderr, "resolver_driver: bad rootfs for %s\n", image_ref);
        return -1;
    }

    /* config JSON: the OCI image config, with the REAL diff_ids. */
    {
        size_t off = 0;
#define APPEND(...) do { int n = snprintf(config_json + off, sizeof(config_json) - off, __VA_ARGS__); if (n < 0 || (size_t)n >= sizeof(config_json) - off) goto out; off += (size_t)n; } while (0)
        APPEND("{\"architecture\":\"amd64\",\"os\":\"linux\",\"rootfs\":{\"type\":\"layers\",\"diff_ids\":[");
        for (uint32_t i = 0; i < n_diffids; i++) {
            if (i > 0) APPEND(",");
            APPEND("\"%s\"", diffids[i]);
        }
        APPEND("]}}");
        config_len = off;
#undef APPEND
    }
    rc = register_image_with_config(image_ref, config_json, config_len);

out:
    return rc;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <stages.conf>\n", argv[0]);
        return 2;
    }

    struct conf_entry entries[CONF_MAX_ENTRIES];
    int n_entries = 0;
    if (conf_load(argv[1], entries, &n_entries) != 0)
        return 1;

    /* The 4 stages, in the oracle's order. */
    const struct stage_input stages[RESOLVER_MAX_STAGES] = {
        {"mediamtx", conf_get(entries, n_entries, "MEDIAMTX_IMAGE"),
         conf_get(entries, n_entries, "MEDIAMTX_ROOTFS")},
        {"normalize", conf_get(entries, n_entries, "NORMALIZE_IMAGE"),
         conf_get(entries, n_entries, "NORMALIZE_ROOTFS")},
        {"scale-and-egress", conf_get(entries, n_entries, "SCALE_IMAGE"),
         conf_get(entries, n_entries, "SCALE_ROOTFS")},
        {"single-stage-egress", conf_get(entries, n_entries, "SINGLE_IMAGE"),
         conf_get(entries, n_entries, "SINGLE_ROOTFS")},
    };

    int fail = 0;

    /* 1. Register the canned content + run the REAL resolver per stage. */
    for (int i = 0; i < RESOLVER_MAX_STAGES; i++) {
        const struct stage_input *st = &stages[i];
        if (st->image_ref == NULL || st->rootfs_val == NULL) {
            fprintf(stderr, "resolver_driver: missing stage config for %s\n",
                    st->kind);
            return 1;
        }
        if (register_image(st->image_ref, st->rootfs_val) != 0)
            return 1;

        char parent[RESOLVER_PARENT_MAX];
        parent[0] = '\0';
        int rc = cc_ctr_resolve_chainid(1, st->image_ref, parent,
                                        sizeof(parent));
        printf("resolver_stage=%s\n", st->kind);
        if (rc != CC_GRPC_STATUS_OK) {
            fprintf(stderr, "resolver_driver: stage %s resolve failed: %d\n",
                    st->kind, rc);
            fail = 1;
            continue;
        }
        printf("resolver_parent=%s\n", parent);
    }

    /* 2. Negative cases: malformed config blobs must be REJECTED loudly
     *    (a CC_CTR_ERR_* code + empty parent), never a wrong/garbage parent,
     *    and must not crash. */
    {
        /* (a) truncated config JSON — cut mid-string. */
        static const char bad_config_trunc[] =
            "{\"architecture\":\"amd64\",\"rootfs\":{\"type\":\"layers\","
            "\"diff_ids\":[\"sha256:abc";
        if (register_image_with_config("malformed-trunc", bad_config_trunc,
                                       sizeof(bad_config_trunc) - 1) != 0)
            return 1;
        char parent[RESOLVER_PARENT_MAX];
        parent[0] = '\0';
        int rc = cc_ctr_resolve_chainid(1, "malformed-trunc", parent,
                                        sizeof(parent));
        if (rc <= -100 && parent[0] == '\0') {
            printf("resolver_negative=truncated-config:%d\n", rc);
        } else {
            fprintf(stderr,
                    "resolver_driver: FAIL — truncated config produced rc=%d parent='%s'\n",
                    rc, parent);
            printf("resolver_negative=truncated-config:WRONG-ANSWER\n");
            fail = 1;
        }

        /* (b) config with rootfs present but NO diff_ids. */
        static const char bad_config_nodiff[] =
            "{\"architecture\":\"amd64\",\"rootfs\":{\"type\":\"layers\"}}";
        if (register_image_with_config("malformed-nodiff", bad_config_nodiff,
                                       sizeof(bad_config_nodiff) - 1) != 0)
            return 1;
        parent[0] = '\0';
        rc = cc_ctr_resolve_chainid(1, "malformed-nodiff", parent,
                                    sizeof(parent));
        if (rc <= -100 && parent[0] == '\0') {
            printf("resolver_negative=missing-diffids:%d\n", rc);
        } else {
            fprintf(stderr,
                    "resolver_driver: FAIL — missing diff_ids produced rc=%d parent='%s'\n",
                    rc, parent);
            printf("resolver_negative=missing-diffids:WRONG-ANSWER\n");
            fail = 1;
        }
    }

    return fail ? 1 : 0;
}