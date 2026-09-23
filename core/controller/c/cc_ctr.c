/*
 * cc_ctr.c — containerd operation layer for the ARM controller rewrite.
 *
 * Phase 4.4a. Thin containerd operation helpers: build requests with the
 * vendored protobuf-c codecs, call cc_grpc_unary, parse responses. See
 * cc_ctr.h for the design contract (fixed-arity API, chainID design-around,
 * OCI spec Any mechanism) and cc_grpc.h for the transport layer.
 *
 * License: project code (see LICENSE). No GPL.
 */

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include <google/protobuf/any.pb-c.h>
#include <google/protobuf/empty.pb-c.h>
#include <services/containers/v1/containers.pb-c.h>
#include <services/content/v1/content.pb-c.h>
#include <services/images/v1/images.pb-c.h>
#include <services/snapshots/v1/snapshots.pb-c.h>
#include <services/tasks/v1/tasks.pb-c.h>

#include "cc_ctr.h"
#include "cc_grpc.h"

/* =========================================================================
 * Internal helpers
 * ========================================================================= */

/* Copy a NUL-terminated string into a fixed buffer; FAIL LOUDLY on
 * truncation (a silently cut snapshot key or digest would corrupt the
 * chainID threading). A NULL destination means the output is optional and
 * is skipped (all cc_ctr out-buffers are optional). Returns 0 or -1. */
static int copy_str(char *dst, uint32_t dst_cap, const char *src) {
  size_t len;

  if (src == NULL)
    src = "";
  if (dst == NULL)
    return 0; /* optional output */
  if (dst_cap == 0)
    return -1; /* output requested but no space */
  len = strlen(src);
  if (len + 1 > dst_cap)
    return -1;
  memcpy(dst, src, len + 1);
  return 0;
}

/* Copy a containerd.types.Mount into the fixed-arity cc_ctr_mount record. */
static int copy_mount(const Containerd__Types__Mount *m,
                      struct cc_ctr_mount *out) {
  uint32_t i;

  if (m == NULL || out == NULL)
    return -1;
  memset(out, 0, sizeof(*out));
  if (copy_str(out->type, sizeof(out->type), m->type) < 0)
    return -1;
  if (copy_str(out->source, sizeof(out->source), m->source) < 0)
    return -1;
  if (copy_str(out->target, sizeof(out->target), m->target) < 0)
    return -1;
  if (m->n_options > CC_CTR_MOUNT_OPT_MAX)
    return -1;
  out->n_options = (uint32_t)m->n_options;
  for (i = 0; i < out->n_options; i++) {
    if (m->options[i] == NULL)
      return -1;
    if (copy_str(out->options[i], CC_CTR_MOUNT_OPT_LEN_MAX, m->options[i]) < 0)
      return -1;
  }
  return 0;
}

/* Convert a codec mount array into caller-provided cc_ctr_mount records.
 * Returns 0 on success (out_n_mounts set), or CC_CTR_ERR_* on failure. */
static int mounts_to_c(Containerd__Types__Mount **mounts, size_t n_mounts,
                       struct cc_ctr_mount *out, uint32_t mounts_cap,
                       uint32_t *out_n_mounts) {
  size_t i;

  if (out_n_mounts == NULL)
    return CC_CTR_ERR_BADARG;
  *out_n_mounts = 0;
  if (mounts_cap != 0 && out == NULL)
    return CC_CTR_ERR_BADARG;
  if (n_mounts > mounts_cap)
    return CC_CTR_ERR_TOOBIG;
  for (i = 0; i < n_mounts; i++) {
    if (copy_mount(mounts[i], &out[i]) < 0)
      return CC_CTR_ERR_TOOBIG;
  }
  *out_n_mounts = (uint32_t)n_mounts;
  return 0;
}

/* Containers/Get returning the snapshotter + snapshot_key of the record.
 * The internal form both cc_ctr_get_container and the task/delete helpers
 * use. Returns 0 (buffers set) or the RPC result. */
static int get_container_info(int h, const char *id,
                              char *out_snapshotter, uint32_t ss_cap,
                              char *out_snapshot_key, uint32_t sk_cap) {
  Containerd__Services__Containers__V1__GetContainerRequest req =
      CONTAINERD__SERVICES__CONTAINERS__V1__GET_CONTAINER_REQUEST__INIT;
  uint8_t reqbuf[256];
  uint8_t respbuf[CC_CTR_RESP_MAX];
  uint32_t resp_len = 0;
  Containerd__Services__Containers__V1__GetContainerResponse *resp;
  size_t reqlen;
  int rc;

  req.id = (char *)id;
  reqlen =
      containerd__services__containers__v1__get_container_request__get_packed_size(
          &req);
  containerd__services__containers__v1__get_container_request__pack(&req,
                                                                    reqbuf);
  rc = cc_grpc_unary(h, "/containerd.services.containers.v1.Containers/Get",
                     reqbuf, (uint32_t)reqlen, respbuf, sizeof(respbuf),
                     &resp_len);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  resp = containerd__services__containers__v1__get_container_response__unpack(
      NULL, resp_len, respbuf);
  if (resp == NULL || resp->container == NULL)
    return CC_CTR_ERR_STATE;
  rc = 0;
  if (copy_str(out_snapshotter, ss_cap, resp->container->snapshotter) < 0)
    rc = CC_CTR_ERR_TOOBIG;
  if (copy_str(out_snapshot_key, sk_cap, resp->container->snapshot_key) < 0)
    rc = CC_CTR_ERR_TOOBIG;
  containerd__services__containers__v1__get_container_response__free_unpacked(
      resp, NULL);
  return rc;
}

/* Hand-pack runc/options.Options{BinaryName: bin} into out: a single field
 * 6 (binary_name), wire type 2 — tag byte (6<<3)|2 = 0x32, a varint length,
 * then the string bytes. There is NO generated runc/options codec in
 * //third_party/containerd-api:codecs, so the payload is packed by hand;
 * the wire must match what the Go client's protobuf encoder emits for the
 * same message (verified byte-for-byte). The fixed binary path is 47 bytes,
 * so a 1-byte varint length always suffices; lengths beyond 127 are rejected
 * loudly (this field set never needs them). Returns 0 with out_len set, or a
 * negative CC_CTR_ERR_*. */
static int ctr_pack_runc_value(const char *bin, uint8_t *out, uint32_t cap,
                               uint32_t *out_len) {
  size_t len;

  if (bin == NULL || bin[0] == '\0' || out == NULL || out_len == NULL)
    return CC_CTR_ERR_BADARG;
  len = strlen(bin);
  if (len > 127)
    return CC_CTR_ERR_TOOBIG; /* 1-byte varint length only */
  if (cap < 2 + (uint32_t)len)
    return CC_CTR_ERR_TOOBIG;
  out[0] = 0x32; /* field 6 (binary_name), wire type 2 */
  out[1] = (uint8_t)len;
  memcpy(out + 2, bin, len);
  *out_len = 2 + (uint32_t)len;
  return CC_GRPC_STATUS_OK;
}

/* =========================================================================
 * Version
 * ========================================================================= */

int cc_ctr_ping(int h) {
  Google__Protobuf__Empty req = GOOGLE__PROTOBUF__EMPTY__INIT;
  uint8_t reqbuf[16];
  uint8_t respbuf[1024];
  uint32_t resp_len = 0;
  size_t reqlen;

  if (h <= 0)
    return CC_CTR_ERR_BADARG;
  reqlen = google__protobuf__empty__get_packed_size(&req);
  google__protobuf__empty__pack(&req, reqbuf);
  return cc_grpc_unary(h, "/containerd.services.version.v1.Version/Version",
                       reqbuf, (uint32_t)reqlen, respbuf, sizeof(respbuf),
                       &resp_len);
}

/* =========================================================================
 * Images
 * ========================================================================= */

int cc_ctr_get_image(int h, const char *image_ref,
                     char *out_name, uint32_t name_cap,
                     char *out_digest, uint32_t digest_cap) {
  Containerd__Services__Images__V1__GetImageRequest req =
      CONTAINERD__SERVICES__IMAGES__V1__GET_IMAGE_REQUEST__INIT;
  uint8_t reqbuf[1024];
  uint8_t respbuf[CC_CTR_RESP_MAX];
  uint32_t resp_len = 0;
  Containerd__Services__Images__V1__GetImageResponse *resp;
  size_t reqlen;
  int rc;

  if (h <= 0 || image_ref == NULL || image_ref[0] == '\0')
    return CC_CTR_ERR_BADARG;
  req.name = (char *)image_ref;
  reqlen =
      containerd__services__images__v1__get_image_request__get_packed_size(
          &req);
  containerd__services__images__v1__get_image_request__pack(&req, reqbuf);
  rc = cc_grpc_unary(h, "/containerd.services.images.v1.Images/Get", reqbuf,
                     (uint32_t)reqlen, respbuf, sizeof(respbuf), &resp_len);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  resp = containerd__services__images__v1__get_image_response__unpack(
      NULL, resp_len, respbuf);
  if (resp == NULL || resp->image == NULL)
    return CC_CTR_ERR_STATE;
  rc = 0;
  if (copy_str(out_name, name_cap, resp->image->name) < 0)
    rc = CC_CTR_ERR_TOOBIG;
  if (resp->image->target != NULL &&
      copy_str(out_digest, digest_cap, resp->image->target->digest) < 0)
    rc = CC_CTR_ERR_TOOBIG;
  containerd__services__images__v1__get_image_response__free_unpacked(resp,
                                                                      NULL);
  return rc;
}

/* =========================================================================
 * SHA-256 (FIPS 180-4) — self-contained, used to compute the image rootfs
 * chainID the same way containerd's identity.ChainID does
 * (github.com/opencontainers/image-spec/identity: digest.FromBytes). No
 * external crypto dependency; the chainID path needs only sha256.
 * ========================================================================= */

#define CC_SHA256_BLOCK 64

struct cc_sha256 {
  uint32_t h[8];
  uint64_t total;
  uint32_t buf_fill;
  uint8_t buf[CC_SHA256_BLOCK];
};

static const uint32_t cc_sha256_k[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu,
    0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u, 0xd807aa98u, 0x12835b01u,
    0x243185beu, 0x550c7dc3u, 0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u,
    0xc19bf174u, 0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
    0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau, 0x983e5152u,
    0xa831c66du, 0xb00327c8u, 0xbf597fc7u, 0xc6e00bf3u, 0xd5a79147u,
    0x06ca6351u, 0x14292967u, 0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu,
    0x53380d13u, 0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u, 0xd192e819u,
    0xd6990624u, 0xf40e3585u, 0x106aa070u, 0x19a4c116u, 0x1e376c08u,
    0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu,
    0x682e6ff3u, 0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u,
};

static uint32_t cc_sha256_rotr(uint32_t x, unsigned n) {
  return (x >> n) | (x << (32u - n));
}

static void cc_sha256_init(struct cc_sha256 *s) {
  s->h[0] = 0x6a09e667u;
  s->h[1] = 0xbb67ae85u;
  s->h[2] = 0x3c6ef372u;
  s->h[3] = 0xa54ff53au;
  s->h[4] = 0x510e527fu;
  s->h[5] = 0x9b05688cu;
  s->h[6] = 0x1f83d9abu;
  s->h[7] = 0x5be0cd19u;
  s->total = 0;
  s->buf_fill = 0;
}

static void cc_sha256_block(struct cc_sha256 *s, const uint8_t *p) {
  uint32_t w[64];
  uint32_t a, b, c, d, e, f, g, h;
  uint32_t t1, t2;
  int i;

  for (i = 0; i < 16; i++)
    w[i] = ((uint32_t)p[i * 4] << 24) | ((uint32_t)p[i * 4 + 1] << 16) |
           ((uint32_t)p[i * 4 + 2] << 8) | (uint32_t)p[i * 4 + 3];
  for (i = 16; i < 64; i++) {
    uint32_t s0 = cc_sha256_rotr(w[i - 15], 7) ^ cc_sha256_rotr(w[i - 15], 18) ^
                  (w[i - 15] >> 3);
    uint32_t s1 = cc_sha256_rotr(w[i - 2], 17) ^ cc_sha256_rotr(w[i - 2], 19) ^
                  (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }
  a = s->h[0];
  b = s->h[1];
  c = s->h[2];
  d = s->h[3];
  e = s->h[4];
  f = s->h[5];
  g = s->h[6];
  h = s->h[7];
  for (i = 0; i < 64; i++) {
    uint32_t S1 = cc_sha256_rotr(e, 6) ^ cc_sha256_rotr(e, 11) ^
                  cc_sha256_rotr(e, 25);
    uint32_t ch = (e & f) ^ (~e & g);
    uint32_t S0 = cc_sha256_rotr(a, 2) ^ cc_sha256_rotr(a, 13) ^
                  cc_sha256_rotr(a, 22);
    uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
    t1 = h + S1 + ch + cc_sha256_k[i] + w[i];
    t2 = S0 + maj;
    h = g;
    g = f;
    f = e;
    e = d + t1;
    d = c;
    c = b;
    b = a;
    a = t1 + t2;
  }
  s->h[0] += a;
  s->h[1] += b;
  s->h[2] += c;
  s->h[3] += d;
  s->h[4] += e;
  s->h[5] += f;
  s->h[6] += g;
  s->h[7] += h;
}

static void cc_sha256_update(struct cc_sha256 *s, const void *data,
                             size_t len) {
  const uint8_t *p = (const uint8_t *)data;

  s->total += len;
  while (len > 0) {
    size_t take = CC_SHA256_BLOCK - s->buf_fill;
    if (take > len)
      take = len;
    memcpy(s->buf + s->buf_fill, p, take);
    s->buf_fill += (uint32_t)take;
    p += take;
    len -= take;
    if (s->buf_fill == CC_SHA256_BLOCK) {
      cc_sha256_block(s, s->buf);
      s->buf_fill = 0;
    }
  }
}

static void cc_sha256_final(struct cc_sha256 *s, uint8_t out[32]) {
  uint64_t bits = s->total * 8;
  uint8_t pad = 0x80;
  uint8_t zero = 0;
  uint8_t lenb[8];
  int i;

  cc_sha256_update(s, &pad, 1);
  while (s->buf_fill != 56)
    cc_sha256_update(s, &zero, 1);
  for (i = 0; i < 8; i++)
    lenb[i] = (uint8_t)(bits >> (56 - i * 8));
  cc_sha256_update(s, lenb, 8);
  for (i = 0; i < 8; i++) {
    out[i * 4] = (uint8_t)(s->h[i] >> 24);
    out[i * 4 + 1] = (uint8_t)(s->h[i] >> 16);
    out[i * 4 + 2] = (uint8_t)(s->h[i] >> 8);
    out[i * 4 + 3] = (uint8_t)(s->h[i]);
  }
}

/* =========================================================================
 * Minimal JSON path extractor — for the two blobs the chainID resolution
 * reads (the OCI manifest and the image config).  Parses a JSON document
 * and captures values by dot-separated key path:
 *     json_path_str(json, len, "config.digest", out, cap)         string
 *     json_path_int(json, len, "config.size", &out)               integer
 *     json_path_strs(json, len, "rootfs.diff_ids", out, max, &n)  string array
 * Returns 0 (found), 1 (not found), or -1 (parse error).  Fail-loud on
 * malformed JSON: the blobs come from containerd's content store (trusted),
 * but a truncated or unexpected document must never be misparsed into a
 * wrong chainID.
 * ========================================================================= */

#define CC_JSON_PATH_MAX 128

struct json_ctx {
  const char *s;
  size_t len;
  size_t pos;
  char path[CC_JSON_PATH_MAX]; /* current dot-joined key path */
  uint32_t path_len;
  int err;
  int captured; /* a target value was captured */
  /* string capture target */
  const char *tstr;
  char *out;
  uint32_t out_cap;
  /* integer capture target */
  const char *tint;
  int64_t *out_int;
  /* string-array capture target */
  const char *tarr;
  char (*out_arr)[CC_CTR_DIGEST_MAX];
  uint32_t arr_max;
  uint32_t *arr_n;
};

static int j_path_set(struct json_ctx *c, const char *key, size_t keylen,
                      uint32_t parent_len) {
  size_t need;

  need = (parent_len > 0 ? (size_t)parent_len + 1 : 0) + keylen;
  if (need + 1 > sizeof(c->path)) {
    c->err = -1;
    return -1;
  }
  if (parent_len > 0) {
    c->path[parent_len] = '.';
    memcpy(c->path + parent_len + 1, key, keylen);
    c->path_len = parent_len + 1 + (uint32_t)keylen;
  } else {
    memcpy(c->path, key, keylen);
    c->path_len = (uint32_t)keylen;
  }
  c->path[c->path_len] = '\0';
  return 0;
}

static int j_path_matches(const struct json_ctx *c, const char *target) {
  return target != NULL && c->path_len == strlen(target) &&
         memcmp(c->path, target, c->path_len) == 0;
}

static void j_skip_ws(struct json_ctx *c) {
  while (c->pos < c->len) {
    char ch = c->s[c->pos];
    if (ch != ' ' && ch != '\t' && ch != '\n' && ch != '\r')
      break;
    c->pos++;
  }
}

static int j_parse_string(struct json_ctx *c, char *out, uint32_t cap) {
  uint32_t olen = 0;

  if (c->pos >= c->len || c->s[c->pos] != '"') {
    c->err = -1;
    return -1;
  }
  c->pos++;
  while (c->pos < c->len) {
    unsigned char ch = (unsigned char)c->s[c->pos++];
    if (ch == '"')
      break;
    if (ch == '\\') {
      if (c->pos >= c->len) {
        c->err = -1;
        return -1;
      }
      ch = (unsigned char)c->s[c->pos++];
      switch (ch) {
        case '"': ch = '"'; break;
        case '\\': ch = '\\'; break;
        case '/': ch = '/'; break;
        case 'b': ch = '\b'; break;
        case 'f': ch = '\f'; break;
        case 'n': ch = '\n'; break;
        case 'r': ch = '\r'; break;
        case 't': ch = '\t'; break;
        case 'u': {
          uint32_t cp = 0;
          int i;
          if (c->pos + 4 > c->len) {
            c->err = -1;
            return -1;
          }
          for (i = 0; i < 4; i++) {
            char hc = c->s[c->pos++];
            uint32_t v;
            if (hc >= '0' && hc <= '9')
              v = (uint32_t)(hc - '0');
            else if (hc >= 'a' && hc <= 'f')
              v = (uint32_t)(hc - 'a' + 10);
            else if (hc >= 'A' && hc <= 'F')
              v = (uint32_t)(hc - 'A' + 10);
            else {
              c->err = -1;
              return -1;
            }
            cp = (cp << 4) | v;
          }
          /* UTF-16 code unit: encode surrogate pairs as two 3-byte UTF-8
           * sequences (the blobs we read contain no escapes, so this is
           * best-effort; plain BMP code units encode below). */
          if (cp >= 0xD800 && cp <= 0xDBFF) {
            /* lone high surrogate: emit U+FFFD and keep parsing */
            if (olen + 3 >= cap) {
              c->err = -1;
              return -1;
            }
            out[olen++] = (char)0xEF;
            out[olen++] = (char)0xBF;
            out[olen++] = (char)0xBD;
          } else if (cp >= 0x800) {
            if (olen + 3 >= cap) {
              c->err = -1;
              return -1;
            }
            out[olen++] = (char)(0xE0 | (cp >> 12));
            out[olen++] = (char)(0x80 | ((cp >> 6) & 0x3F));
            out[olen++] = (char)(0x80 | (cp & 0x3F));
          } else if (cp >= 0x80) {
            if (olen + 2 >= cap) {
              c->err = -1;
              return -1;
            }
            out[olen++] = (char)(0xC0 | (cp >> 6));
            out[olen++] = (char)(0x80 | (cp & 0x3F));
          } else {
            if (olen + 1 >= cap) {
              c->err = -1;
              return -1;
            }
            out[olen++] = (char)cp;
          }
          continue;
        }
        default:
          c->err = -1;
          return -1;
      }
    }
    if (olen + 1 >= cap) {
      c->err = -1;
      return -1;
    }
    out[olen++] = (char)ch;
  }
  if (olen + 1 > cap) {
    c->err = -1;
    return -1;
  }
  out[olen] = '\0';
  return 0;
}

static int j_parse_number(struct json_ctx *c, int64_t *out) {
  int64_t v = 0;
  int neg = 0;

  if (c->pos < c->len && c->s[c->pos] == '-') {
    neg = 1;
    c->pos++;
  }
  while (c->pos < c->len && c->s[c->pos] >= '0' && c->s[c->pos] <= '9') {
    int digit = c->s[c->pos] - '0';
    if (v > (INT64_MAX - digit) / 10) {
      c->err = -1;
      return -1;
    }
    v = v * 10 + digit;
    c->pos++;
  }
  *out = neg ? -v : v;
  return 0;
}

static int j_parse_value(struct json_ctx *c, uint32_t parent_len);

static int j_parse_object(struct json_ctx *c) {
  if (c->pos >= c->len || c->s[c->pos] != '{') {
    c->err = -1;
    return -1;
  }
  c->pos++;
  j_skip_ws(c);
  if (c->pos < c->len && c->s[c->pos] == '}')
    return 0; /* empty object */
  for (;;) {
    char key[CC_JSON_PATH_MAX];
    uint32_t parent = c->path_len;

    j_skip_ws(c);
    if (j_parse_string(c, key, sizeof(key)) < 0)
      return -1;
    j_skip_ws(c);
    if (c->pos >= c->len || c->s[c->pos] != ':') {
      c->err = -1;
      return -1;
    }
    c->pos++;
    if (j_path_set(c, key, strlen(key), parent) < 0)
      return -1;
    if (j_parse_value(c, parent) < 0)
      return -1;
    /* the value parser restores path_len to parent on its way out */
    c->path_len = parent;
    c->path[parent] = '\0';
    j_skip_ws(c);
    if (c->pos >= c->len) {
      c->err = -1;
      return -1;
    }
    if (c->s[c->pos] == ',') {
      c->pos++;
      continue;
    }
    if (c->s[c->pos] == '}') {
      c->pos++;
      return 0;
    }
    c->err = -1;
    return -1;
  }
}

static int j_parse_array(struct json_ctx *c, uint32_t parent_len) {
  int capture = j_path_matches(c, c->tarr);

  if (c->pos >= c->len || c->s[c->pos] != '[') {
    c->err = -1;
    return -1;
  }
  if (capture)
    c->captured = 1; /* a matched array is a found target, even if empty */
  c->pos++;
  j_skip_ws(c);
  if (c->pos < c->len && c->s[c->pos] == ']') {
    c->pos++;
    return 0; /* empty array */
  }
  for (;;) {
    j_skip_ws(c);
    if (capture) {
      /* only string elements are expected in a diff_ids array; capture each
       * into out_arr and count them. */
      char elem[CC_CTR_DIGEST_MAX];
      if (j_parse_string(c, elem, sizeof(elem)) < 0)
        return -1;
      if (*c->arr_n >= c->arr_max) {
        c->err = -1;
        return -1;
      }
      memcpy(c->out_arr[*c->arr_n], elem, strlen(elem) + 1);
      (*c->arr_n)++;
    } else {
      if (j_parse_value(c, parent_len) < 0)
        return -1;
      c->path_len = parent_len;
      c->path[parent_len] = '\0';
    }
    j_skip_ws(c);
    if (c->pos >= c->len) {
      c->err = -1;
      return -1;
    }
    if (c->s[c->pos] == ',') {
      c->pos++;
      continue;
    }
    if (c->s[c->pos] == ']') {
      c->pos++;
      return 0;
    }
    c->err = -1;
    return -1;
  }
}

static int j_parse_value(struct json_ctx *c, uint32_t parent_len) {
  char ch;

  (void)parent_len;
  j_skip_ws(c);
  if (c->pos >= c->len) {
    c->err = -1;
    return -1;
  }
  ch = c->s[c->pos];
  if (ch == '{')
    return j_parse_object(c);
  if (ch == '[')
    return j_parse_array(c, c->path_len);
  if (ch == '"') {
    char v[CC_JSON_PATH_MAX];
    if (j_parse_string(c, v, sizeof(v)) < 0)
      return -1;
    if (j_path_matches(c, c->tstr)) {
      if (copy_str(c->out, c->out_cap, v) < 0) {
        c->err = -1;
        return -1;
      }
      c->captured = 1;
    }
    return 0;
  }
  if (ch == '-' || (ch >= '0' && ch <= '9')) {
    int64_t v = 0;
    if (j_parse_number(c, &v) < 0)
      return -1;
    if (j_path_matches(c, c->tint)) {
      *c->out_int = v;
      c->captured = 1;
    }
    return 0;
  }
  /* literals true/false/null — skip them */
  if (ch == 't' && c->len - c->pos >= 4 && memcmp(c->s + c->pos, "true", 4) == 0) {
    c->pos += 4;
    return 0;
  }
  if (ch == 'f' && c->len - c->pos >= 5 && memcmp(c->s + c->pos, "false", 5) == 0) {
    c->pos += 5;
    return 0;
  }
  if (ch == 'n' && c->len - c->pos >= 4 && memcmp(c->s + c->pos, "null", 4) == 0) {
    c->pos += 4;
    return 0;
  }
  c->err = -1;
  return -1;
}

static int json_path_str(const char *json, size_t len, const char *path,
                         char *out, uint32_t cap) {
  struct json_ctx c;
  int rc;

  memset(&c, 0, sizeof(c));
  c.s = json;
  c.len = len;
  c.tstr = path;
  c.out = out;
  c.out_cap = cap;
  rc = j_parse_value(&c, 0);
  if (c.err != 0 || rc < 0)
    return -1;
  return c.captured ? 0 : 1; /* 0 found, 1 not-found */
}

static int json_path_int(const char *json, size_t len, const char *path,
                         int64_t *out) {
  struct json_ctx c;
  int rc;

  memset(&c, 0, sizeof(c));
  c.s = json;
  c.len = len;
  c.tint = path;
  c.out_int = out;
  rc = j_parse_value(&c, 0);
  if (c.err != 0 || rc < 0)
    return -1;
  return c.captured ? 0 : 1; /* 0 found, 1 not-found */
}

static int json_path_strs(const char *json, size_t len, const char *path,
                          char (*out)[CC_CTR_DIGEST_MAX], uint32_t max,
                          uint32_t *n) {
  struct json_ctx c;
  int rc;

  *n = 0;
  memset(&c, 0, sizeof(c));
  c.s = json;
  c.len = len;
  c.tarr = path;
  c.out_arr = out;
  c.arr_max = max;
  c.arr_n = n;
  rc = j_parse_value(&c, 0);
  if (c.err != 0 || rc < 0)
    return -1;
  return c.captured ? 0 : 1; /* 0 found, 1 not-found */
}

/* =========================================================================
 * Content service read (chainID resolution)
 * ========================================================================= */

/* Read one content blob via the Content/Read server stream.  The Go oracle
 * (core/content/proxy/content_reader.go ReadAt) sends
 * ReadContentRequest{digest, offset=0, size=desc.Size}; containerd's
 * contentserver answers with ReadContentResponse messages chunked by a
 * 32 KiB pool buffer, so any blob at or below 32 KiB arrives as ONE
 * message — which is what cc_grpc_unary's single-message reassembler
 * supports.  The project images' manifest/config blobs are a few KiB, so
 * this bound is safe; a bigger blob fails loudly (CC_GRPC_ERR_PROTO from
 * the multi-message path) rather than silently mis-reading. */
static int ctr_read_content(int h, const char *digest, int64_t size,
                            uint8_t *out, uint32_t out_cap,
                            uint32_t *out_len) {
  Containerd__Services__Content__V1__ReadContentRequest req =
      CONTAINERD__SERVICES__CONTENT__V1__READ_CONTENT_REQUEST__INIT;
  uint8_t reqbuf[1024];
  uint8_t respbuf[CC_CTR_CONTENT_BLOB_MAX + 64];
  uint32_t resp_len = 0;
  Containerd__Services__Content__V1__ReadContentResponse *resp;
  size_t reqlen;
  int rc;

  if (h <= 0 || digest == NULL || digest[0] == '\0' || out == NULL ||
      out_cap == 0 || out_len == NULL)
    return CC_CTR_ERR_BADARG;
  *out_len = 0;
  req.digest = (char *)digest;
  req.offset = 0;
  req.size = (size > 0) ? size : 0;
  reqlen =
      containerd__services__content__v1__read_content_request__get_packed_size(
          &req);
  containerd__services__content__v1__read_content_request__pack(&req, reqbuf);
  rc = cc_grpc_unary(h, "/containerd.services.content.v1.Content/Read", reqbuf,
                     (uint32_t)reqlen, respbuf, sizeof(respbuf), &resp_len);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  resp = containerd__services__content__v1__read_content_response__unpack(
      NULL, resp_len, respbuf);
  if (resp == NULL)
    return CC_CTR_ERR_STATE;
  if (resp->data.len > out_cap) {
    containerd__services__content__v1__read_content_response__free_unpacked(
        resp, NULL);
    return CC_CTR_ERR_TOOBIG;
  }
  memcpy(out, resp->data.data, resp->data.len);
  *out_len = (uint32_t)resp->data.len;
  containerd__services__content__v1__read_content_response__free_unpacked(
      resp, NULL);
  return CC_GRPC_STATUS_OK;
}

/* =========================================================================
 * cc_ctr_resolve_chainid — the WithNewSnapshot parent computation
 * ========================================================================= */

int cc_ctr_resolve_chainid(int h, const char *image_ref, char *out_parent,
                           uint32_t parent_cap) {
  Containerd__Services__Images__V1__GetImageRequest ireq =
      CONTAINERD__SERVICES__IMAGES__V1__GET_IMAGE_REQUEST__INIT;
  uint8_t reqbuf[1024];
  uint8_t respbuf[CC_CTR_RESP_MAX];
  uint32_t resp_len = 0;
  Containerd__Services__Images__V1__GetImageResponse *iresp;
  uint8_t manifest[CC_CTR_CONTENT_BLOB_MAX];
  uint8_t config[CC_CTR_CONTENT_BLOB_MAX];
  uint32_t manifest_len = 0;
  uint32_t config_len = 0;
  char config_digest[CC_CTR_DIGEST_MAX];
  int64_t manifest_size = 0;
  int64_t config_size = 0;
  char diffids[CC_CTR_MAX_DIFFIDS][CC_CTR_DIGEST_MAX];
  uint32_t n_diffids = 0;
  char chain[CC_CTR_DIGEST_MAX];
  char tmp[CC_CTR_DIGEST_MAX];
  size_t reqlen;
  uint32_t i;
  int rc;

  if (h <= 0 || image_ref == NULL || image_ref[0] == '\0' ||
      out_parent == NULL || parent_cap == 0)
    return CC_CTR_ERR_BADARG;
  if (out_parent != NULL)
    out_parent[0] = '\0';

  /* 1. Images/Get(image_ref) — the manifest descriptor (Go buildContainer
   *    :75 f.client.GetImage; withNewSnapshot's image.RootFS walks it). */
  ireq.name = (char *)image_ref;
  reqlen =
      containerd__services__images__v1__get_image_request__get_packed_size(
          &ireq);
  containerd__services__images__v1__get_image_request__pack(&ireq, reqbuf);
  rc = cc_grpc_unary(h, "/containerd.services.images.v1.Images/Get", reqbuf,
                     (uint32_t)reqlen, respbuf, sizeof(respbuf), &resp_len);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  iresp = containerd__services__images__v1__get_image_response__unpack(
      NULL, resp_len, respbuf);
  if (iresp == NULL || iresp->image == NULL || iresp->image->target == NULL) {
    if (iresp != NULL)
      containerd__services__images__v1__get_image_response__free_unpacked(
          iresp, NULL);
    return CC_CTR_ERR_STATE;
  }
  if (copy_str(config_digest, sizeof(config_digest),
               iresp->image->target->digest) < 0) {
    containerd__services__images__v1__get_image_response__free_unpacked(
        iresp, NULL);
    return CC_CTR_ERR_TOOBIG;
  }
  manifest_size = iresp->image->target->size;
  containerd__services__images__v1__get_image_response__free_unpacked(iresp,
                                                                      NULL);

  /* 2. Content/Read(manifest) — extract the config descriptor
   *    (core/images/image.go Manifest -> Config).  Only the plain-manifest
   *    shape is supported: an image index ("manifests" array) is rejected
   *    loudly — the project images are single-platform manifests. */
  rc = ctr_read_content(h, config_digest, manifest_size, manifest,
                        sizeof(manifest), &manifest_len);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  if (json_path_str((const char *)manifest, manifest_len, "config.digest",
                    config_digest, sizeof(config_digest)) != 0 ||
      config_digest[0] == '\0')
    return CC_CTR_ERR_STATE;
  if (json_path_int((const char *)manifest, manifest_len, "config.size",
                    &config_size) != 0)
    return CC_CTR_ERR_STATE;

  /* 3. Content/Read(config) — extract rootfs.diff_ids
   *    (core/images/image.go RootFS). */
  rc = ctr_read_content(h, config_digest, config_size, config, sizeof(config),
                        &config_len);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  if (json_path_strs((const char *)config, config_len, "rootfs.diff_ids",
                     diffids, CC_CTR_MAX_DIFFIDS, &n_diffids) != 0)
    return CC_CTR_ERR_STATE;

  /* 4. chainID = identity.ChainID(diff_ids) (opencontainers/image-spec
   *    identity.ChainIDs): the recursive digest of
   *    prevChainID + " " + diffID, starting from diff_ids[0].  A 0-layer
   *    image yields "" (base Prepare); a 1-layer image yields the diffID
   *    itself. */
  if (n_diffids == 0) {
    if (copy_str(out_parent, parent_cap, "") < 0)
      return CC_CTR_ERR_TOOBIG;
    return CC_GRPC_STATUS_OK;
  }
  if (copy_str(chain, sizeof(chain), diffids[0]) < 0)
    return CC_CTR_ERR_TOOBIG;
  for (i = 1; i < n_diffids; i++) {
    struct cc_sha256 sh;
    uint8_t digest[32];
    static const char hex[] = "0123456789abcdef";
    size_t clen = strlen(chain);
    size_t dlen = strlen(diffids[i]);
    uint32_t j;

    if (clen + 1 + dlen > sizeof(tmp)) {
      tmp[0] = '\0';
      return CC_CTR_ERR_TOOBIG;
    }
    memcpy(tmp, chain, clen);
    tmp[clen] = ' ';
    memcpy(tmp + clen + 1, diffids[i], dlen + 1);
    cc_sha256_init(&sh);
    cc_sha256_update(&sh, tmp, clen + 1 + dlen);
    cc_sha256_final(&sh, digest);
    if (copy_str(chain, sizeof(chain), "sha256:") < 0)
      return CC_CTR_ERR_TOOBIG;
    {
      size_t off = strlen(chain);
      for (j = 0; j < 32; j++) {
        if (off + 2 >= sizeof(chain)) {
          chain[0] = '\0';
          return CC_CTR_ERR_TOOBIG;
        }
        chain[off++] = hex[digest[j] >> 4];
        chain[off++] = hex[digest[j] & 0xF];
      }
      chain[off] = '\0';
    }
  }
  return copy_str(out_parent, parent_cap, chain);
}

/* =========================================================================
 * Snapshots (chainID design-around)
 * ========================================================================= */

int cc_ctr_prepare_snapshot(int h, const char *snapshotter, const char *key,
                            const char *parent,
                            struct cc_ctr_mount *out_mounts,
                            uint32_t mounts_cap, uint32_t *out_n_mounts) {
  Containerd__Services__Snapshots__V1__PrepareSnapshotRequest req =
      CONTAINERD__SERVICES__SNAPSHOTS__V1__PREPARE_SNAPSHOT_REQUEST__INIT;
  uint8_t reqbuf[2048];
  uint8_t respbuf[CC_CTR_RESP_MAX];
  uint32_t resp_len = 0;
  Containerd__Services__Snapshots__V1__PrepareSnapshotResponse *resp;
  size_t reqlen;
  int rc;

  if (h <= 0 || snapshotter == NULL || snapshotter[0] == '\0' ||
      key == NULL || key[0] == '\0' || parent == NULL)
    return CC_CTR_ERR_BADARG;
  req.snapshotter = (char *)snapshotter;
  req.key = (char *)key;
  /* The parent is passed through verbatim — NEVER defaulted to "": the
   * container-create path must chain the snapshot onto the image's
   * chainID (cc_ctr_resolve_chainid); an empty parent yields a bare
   * rootfs with no image layers (the exec /entrypoint.sh not-found bug). */
  req.parent = (char *)parent;
  reqlen = containerd__services__snapshots__v1__prepare_snapshot_request__get_packed_size(
      &req);
  containerd__services__snapshots__v1__prepare_snapshot_request__pack(&req,
                                                                      reqbuf);
  rc = cc_grpc_unary(h, "/containerd.services.snapshots.v1.Snapshots/Prepare",
                     reqbuf, (uint32_t)reqlen, respbuf, sizeof(respbuf),
                     &resp_len);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  resp = containerd__services__snapshots__v1__prepare_snapshot_response__unpack(
      NULL, resp_len, respbuf);
  if (resp == NULL)
    return CC_CTR_ERR_STATE;
  rc = mounts_to_c(resp->mounts, resp->n_mounts, out_mounts, mounts_cap,
                   out_n_mounts);
  containerd__services__snapshots__v1__prepare_snapshot_response__free_unpacked(
      resp, NULL);
  return rc;
}

int cc_ctr_commit_snapshot(int h, const char *snapshotter, const char *name,
                           const char *key, const char *parent) {
  Containerd__Services__Snapshots__V1__CommitSnapshotRequest req =
      CONTAINERD__SERVICES__SNAPSHOTS__V1__COMMIT_SNAPSHOT_REQUEST__INIT;
  uint8_t reqbuf[2048];
  uint8_t respbuf[1024];
  uint32_t resp_len = 0;
  size_t reqlen;

  if (h <= 0 || snapshotter == NULL || snapshotter[0] == '\0' ||
      name == NULL || name[0] == '\0' || key == NULL || key[0] == '\0')
    return CC_CTR_ERR_BADARG;
  req.snapshotter = (char *)snapshotter;
  req.name = (char *)name;
  req.key = (char *)key;
  req.parent = (char *)(parent != NULL ? parent : "");
  reqlen =
      containerd__services__snapshots__v1__commit_snapshot_request__get_packed_size(
          &req);
  containerd__services__snapshots__v1__commit_snapshot_request__pack(&req,
                                                                     reqbuf);
  return cc_grpc_unary(h, "/containerd.services.snapshots.v1.Snapshots/Commit",
                       reqbuf, (uint32_t)reqlen, respbuf, sizeof(respbuf),
                       &resp_len);
}

int cc_ctr_mounts(int h, const char *snapshotter, const char *key,
                  struct cc_ctr_mount *out_mounts, uint32_t mounts_cap,
                  uint32_t *out_n_mounts) {
  Containerd__Services__Snapshots__V1__MountsRequest req =
      CONTAINERD__SERVICES__SNAPSHOTS__V1__MOUNTS_REQUEST__INIT;
  uint8_t reqbuf[1024];
  uint8_t respbuf[CC_CTR_RESP_MAX];
  uint32_t resp_len = 0;
  Containerd__Services__Snapshots__V1__MountsResponse *resp;
  size_t reqlen;
  int rc;

  if (h <= 0 || snapshotter == NULL || snapshotter[0] == '\0' ||
      key == NULL || key[0] == '\0')
    return CC_CTR_ERR_BADARG;
  req.snapshotter = (char *)snapshotter;
  req.key = (char *)key;
  reqlen = containerd__services__snapshots__v1__mounts_request__get_packed_size(
      &req);
  containerd__services__snapshots__v1__mounts_request__pack(&req, reqbuf);
  rc = cc_grpc_unary(h, "/containerd.services.snapshots.v1.Snapshots/Mounts",
                     reqbuf, (uint32_t)reqlen, respbuf, sizeof(respbuf),
                     &resp_len);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  resp = containerd__services__snapshots__v1__mounts_response__unpack(
      NULL, resp_len, respbuf);
  if (resp == NULL)
    return CC_CTR_ERR_STATE;
  rc = mounts_to_c(resp->mounts, resp->n_mounts, out_mounts, mounts_cap,
                   out_n_mounts);
  containerd__services__snapshots__v1__mounts_response__free_unpacked(resp,
                                                                      NULL);
  return rc;
}

int cc_ctr_remove_snapshot(int h, const char *snapshotter, const char *key) {
  Containerd__Services__Snapshots__V1__RemoveSnapshotRequest req =
      CONTAINERD__SERVICES__SNAPSHOTS__V1__REMOVE_SNAPSHOT_REQUEST__INIT;
  uint8_t reqbuf[1024];
  uint8_t respbuf[1024];
  uint32_t resp_len = 0;
  size_t reqlen;

  if (h <= 0 || snapshotter == NULL || snapshotter[0] == '\0' ||
      key == NULL || key[0] == '\0')
    return CC_CTR_ERR_BADARG;
  req.snapshotter = (char *)snapshotter;
  req.key = (char *)key;
  reqlen = containerd__services__snapshots__v1__remove_snapshot_request__get_packed_size(
      &req);
  containerd__services__snapshots__v1__remove_snapshot_request__pack(&req,
                                                                     reqbuf);
  return cc_grpc_unary(h, "/containerd.services.snapshots.v1.Snapshots/Remove",
                       reqbuf, (uint32_t)reqlen, respbuf, sizeof(respbuf),
                       &resp_len);
}

int cc_ctr_stat_snapshot(int h, const char *snapshotter, const char *key,
                         uint32_t *out_kind, char *out_parent,
                         uint32_t parent_cap) {
  Containerd__Services__Snapshots__V1__StatSnapshotRequest req =
      CONTAINERD__SERVICES__SNAPSHOTS__V1__STAT_SNAPSHOT_REQUEST__INIT;
  uint8_t reqbuf[1024];
  uint8_t respbuf[CC_CTR_RESP_MAX];
  uint32_t resp_len = 0;
  Containerd__Services__Snapshots__V1__StatSnapshotResponse *resp;
  size_t reqlen;
  int rc;

  if (h <= 0 || snapshotter == NULL || snapshotter[0] == '\0' ||
      key == NULL || key[0] == '\0')
    return CC_CTR_ERR_BADARG;
  if (out_kind != NULL)
    *out_kind = 0;
  req.snapshotter = (char *)snapshotter;
  req.key = (char *)key;
  reqlen = containerd__services__snapshots__v1__stat_snapshot_request__get_packed_size(
      &req);
  containerd__services__snapshots__v1__stat_snapshot_request__pack(&req,
                                                                   reqbuf);
  rc = cc_grpc_unary(h, "/containerd.services.snapshots.v1.Snapshots/Stat",
                     reqbuf, (uint32_t)reqlen, respbuf, sizeof(respbuf),
                     &resp_len);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  resp = containerd__services__snapshots__v1__stat_snapshot_response__unpack(
      NULL, resp_len, respbuf);
  if (resp == NULL || resp->info == NULL)
    return CC_CTR_ERR_STATE;
  rc = 0;
  if (out_kind != NULL)
    *out_kind = (uint32_t)resp->info->kind;
  if (copy_str(out_parent, parent_cap, resp->info->parent) < 0)
    rc = CC_CTR_ERR_TOOBIG;
  containerd__services__snapshots__v1__stat_snapshot_response__free_unpacked(
      resp, NULL);
  return rc;
}

/* =========================================================================
 * Containers
 * ========================================================================= */

int cc_ctr_create_container(int h, const char *id, const char *image_ref,
                            const char *snapshotter, const char *snapshot_key,
                            const char *runtime, const uint8_t *oci_spec_json,
                            uint32_t oci_len) {
  Containerd__Services__Containers__V1__Container__Runtime rt =
      CONTAINERD__SERVICES__CONTAINERS__V1__CONTAINER__RUNTIME__INIT;
  Containerd__Services__Containers__V1__Container ctr =
      CONTAINERD__SERVICES__CONTAINERS__V1__CONTAINER__INIT;
  Containerd__Services__Containers__V1__CreateContainerRequest req =
      CONTAINERD__SERVICES__CONTAINERS__V1__CREATE_CONTAINER_REQUEST__INIT;
  Google__Protobuf__Any spec = GOOGLE__PROTOBUF__ANY__INIT;
  uint8_t reqbuf[CC_CTR_REQ_MAX];
  uint8_t respbuf[CC_CTR_RESP_MAX];
  uint32_t resp_len = 0;
  size_t reqlen;

  if (h <= 0 || id == NULL || id[0] == '\0' || image_ref == NULL ||
      image_ref[0] == '\0' || oci_spec_json == NULL || oci_len == 0)
    return CC_CTR_ERR_BADARG;

  spec.type_url = (char *)CC_CTR_OCI_TYPE_URL;
  spec.value.data = (uint8_t *)oci_spec_json;
  spec.value.len = oci_len;

  rt.name = (char *)(runtime != NULL && runtime[0] != '\0'
                         ? runtime
                         : CC_CTR_DEFAULT_RUNTIME);

  ctr.id = (char *)id;
  ctr.image = (char *)image_ref;
  ctr.runtime = &rt;
  ctr.spec = &spec;
  ctr.snapshotter = (char *)(snapshotter != NULL && snapshotter[0] != '\0'
                                 ? snapshotter
                                 : CC_CTR_DEFAULT_SNAPSHOTTER);
  ctr.snapshot_key = (char *)(snapshot_key != NULL ? snapshot_key : "");

  req.container = &ctr;
  reqlen = containerd__services__containers__v1__create_container_request__get_packed_size(
      &req);
  if (reqlen > sizeof(reqbuf))
    return CC_CTR_ERR_TOOBIG;
  containerd__services__containers__v1__create_container_request__pack(&req,
                                                                       reqbuf);
  return cc_grpc_unary(h, "/containerd.services.containers.v1.Containers/Create",
                       reqbuf, (uint32_t)reqlen, respbuf, sizeof(respbuf),
                       &resp_len);
}

int cc_ctr_get_container(int h, const char *id,
                         char *out_snapshotter, uint32_t ss_cap,
                         char *out_snapshot_key, uint32_t sk_cap) {
  if (h <= 0 || id == NULL || id[0] == '\0')
    return CC_CTR_ERR_BADARG;
  return get_container_info(h, id, out_snapshotter, ss_cap, out_snapshot_key,
                            sk_cap);
}

int cc_ctr_delete_container(int h, const char *id) {
  Containerd__Services__Containers__V1__DeleteContainerRequest req =
      CONTAINERD__SERVICES__CONTAINERS__V1__DELETE_CONTAINER_REQUEST__INIT;
  char snapshotter[CC_CTR_MOUNT_SRC_MAX];
  char snapshot_key[CC_CTR_MOUNT_SRC_MAX];
  uint8_t reqbuf[1024];
  uint8_t respbuf[1024];
  uint32_t resp_len = 0;
  size_t reqlen;
  int rc;

  if (h <= 0 || id == NULL || id[0] == '\0')
    return CC_CTR_ERR_BADARG;

  /* container.Delete() first refuses to delete a container with a task. */
  rc = cc_ctr_get_task(h, id, NULL);
  if (rc == CC_GRPC_STATUS_OK)
    return CC_GRPC_STATUS_FAILED_PRECONDITION;
  if (rc != CC_GRPC_STATUS_NOT_FOUND)
    return rc;

  /* Fetch the record (client: c.get), then WithSnapshotCleanup. */
  rc = get_container_info(h, id, snapshotter, sizeof(snapshotter),
                          snapshot_key, sizeof(snapshot_key));
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  if (snapshot_key[0] != '\0') {
    if (snapshotter[0] == '\0')
      return CC_CTR_ERR_STATE;
    rc = cc_ctr_remove_snapshot(h, snapshotter, snapshot_key);
    if (rc != CC_GRPC_STATUS_OK)
      return rc;
  }

  req.id = (char *)id;
  reqlen =
      containerd__services__containers__v1__delete_container_request__get_packed_size(
          &req);
  containerd__services__containers__v1__delete_container_request__pack(&req,
                                                                       reqbuf);
  return cc_grpc_unary(h,
                       "/containerd.services.containers.v1.Containers/Delete",
                       reqbuf, (uint32_t)reqlen, respbuf, sizeof(respbuf),
                       &resp_len);
}

/* =========================================================================
 * Tasks
 * ========================================================================= */

int cc_ctr_create_task(int h, const char *container_id,
                       const char *stdout_uri, const char *stderr_uri,
                       uint32_t *out_pid, const char *nvidia_bin) {
  Containerd__Services__Tasks__V1__CreateTaskRequest req =
      CONTAINERD__SERVICES__TASKS__V1__CREATE_TASK_REQUEST__INIT;
  Google__Protobuf__Any task_opts = GOOGLE__PROTOBUF__ANY__INIT;
  uint8_t runc_value[130];
  uint32_t runc_value_len = 0;
  char snapshotter[CC_CTR_MOUNT_SRC_MAX];
  char snapshot_key[CC_CTR_MOUNT_SRC_MAX];
  struct cc_ctr_mount mounts[CC_CTR_MAX_MOUNTS];
  uint32_t n_mounts = 0;
  Containerd__Types__Mount rootfs[CC_CTR_MAX_MOUNTS];
  Containerd__Types__Mount *rootfs_ptrs[CC_CTR_MAX_MOUNTS];
  char *rootfs_opts[CC_CTR_MAX_MOUNTS][CC_CTR_MOUNT_OPT_MAX];
  uint8_t reqbuf[CC_CTR_REQ_MAX];
  uint8_t respbuf[CC_CTR_RESP_MAX];
  uint32_t resp_len = 0;
  Containerd__Services__Tasks__V1__CreateTaskResponse *resp;
  size_t reqlen;
  uint32_t i, j;
  int rc;

  if (h <= 0 || container_id == NULL || container_id[0] == '\0')
    return CC_CTR_ERR_BADARG;
  if (out_pid != NULL)
    *out_pid = 0;

  /* Go client sequence part 1: Containers/Get + Snapshots/Mounts (the
   * client's handleMounts), reading the record's snapshotter/key. */
  rc = get_container_info(h, container_id, snapshotter, sizeof(snapshotter),
                          snapshot_key, sizeof(snapshot_key));
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  if (snapshot_key[0] != '\0') {
    if (snapshotter[0] == '\0')
      return CC_CTR_ERR_STATE;
    rc = cc_ctr_mounts(h, snapshotter, snapshot_key, mounts,
                       CC_CTR_MAX_MOUNTS, &n_mounts);
    if (rc != CC_GRPC_STATUS_OK)
      return rc;
  }

  /* Go client sequence part 2: two more Containers/Get calls (the client's
   * Spec() mount-label check and its runtime-name fetch) — kept for wire
   * parity; our specs carry no mount label. */
  rc = get_container_info(h, container_id, NULL, 0, NULL, 0);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  rc = get_container_info(h, container_id, NULL, 0, NULL, 0);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;

  /* Rebuild the codec rootfs from the fixed-arity mount records. */
  for (i = 0; i < n_mounts; i++) {
    containerd__types__mount__init(&rootfs[i]);
    rootfs[i].type = mounts[i].type;
    rootfs[i].source = mounts[i].source;
    rootfs[i].target = mounts[i].target;
    rootfs[i].n_options = mounts[i].n_options;
    for (j = 0; j < mounts[i].n_options; j++)
      rootfs_opts[i][j] = mounts[i].options[j];
    rootfs[i].options = rootfs_opts[i];
    rootfs_ptrs[i] = &rootfs[i];
  }

  /* Option C (per-container NVIDIA runtime): when nvidia_bin is set, carry
   * runc/options.Options{BinaryName: nvidia_bin} in CreateTaskRequest.options
   * so the runc shim execs that runtime binary instead of plain runc (the Go
   * client's NewTask(WithRuntimeOptions) wire, client/container.go:275-280).
   * NULL keeps the pre-Option-C wire (options absent -> plain runc). The
   * tasks service formatOptions requires task options for io.containerd.runc
   * .v2 to be exactly runc/options.Options, so the carrier is only added for
   * GPU tasks. */
  if (nvidia_bin != NULL && nvidia_bin[0] != '\0') {
    rc = ctr_pack_runc_value(nvidia_bin, runc_value, sizeof(runc_value),
                             &runc_value_len);
    if (rc != CC_GRPC_STATUS_OK)
      return rc;
    task_opts.type_url = (char *)CC_CTR_RUNC_OPTIONS_TYPE_URL;
    task_opts.value.data = runc_value;
    task_opts.value.len = runc_value_len;
    req.options = &task_opts;
  }

  req.container_id = (char *)container_id;
  req.n_rootfs = n_mounts;
  req.rootfs = rootfs_ptrs;
  req.stdin = (char *)"";
  req.stdout = (char *)(stdout_uri != NULL ? stdout_uri : "");
  req.stderr = (char *)(stderr_uri != NULL ? stderr_uri : "");
  reqlen =
      containerd__services__tasks__v1__create_task_request__get_packed_size(
          &req);
  if (reqlen > sizeof(reqbuf))
    return CC_CTR_ERR_TOOBIG;
  containerd__services__tasks__v1__create_task_request__pack(&req, reqbuf);
  rc = cc_grpc_unary(h, "/containerd.services.tasks.v1.Tasks/Create", reqbuf,
                     (uint32_t)reqlen, respbuf, sizeof(respbuf), &resp_len);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  resp = containerd__services__tasks__v1__create_task_response__unpack(
      NULL, resp_len, respbuf);
  if (resp == NULL)
    return CC_CTR_ERR_STATE;
  if (out_pid != NULL)
    *out_pid = resp->pid;
  containerd__services__tasks__v1__create_task_response__free_unpacked(resp,
                                                                       NULL);
  return CC_GRPC_STATUS_OK;
}

int cc_ctr_start_task(int h, const char *container_id, uint32_t *out_pid) {
  Containerd__Services__Tasks__V1__StartRequest req =
      CONTAINERD__SERVICES__TASKS__V1__START_REQUEST__INIT;
  uint8_t reqbuf[1024];
  uint8_t respbuf[1024];
  uint32_t resp_len = 0;
  Containerd__Services__Tasks__V1__StartResponse *resp;
  size_t reqlen;
  int rc;

  if (h <= 0 || container_id == NULL || container_id[0] == '\0')
    return CC_CTR_ERR_BADARG;
  if (out_pid != NULL)
    *out_pid = 0;
  req.container_id = (char *)container_id;
  reqlen = containerd__services__tasks__v1__start_request__get_packed_size(
      &req);
  containerd__services__tasks__v1__start_request__pack(&req, reqbuf);
  rc = cc_grpc_unary(h, "/containerd.services.tasks.v1.Tasks/Start", reqbuf,
                     (uint32_t)reqlen, respbuf, sizeof(respbuf), &resp_len);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  resp = containerd__services__tasks__v1__start_response__unpack(
      NULL, resp_len, respbuf);
  if (resp == NULL)
    return CC_CTR_ERR_STATE;
  if (out_pid != NULL)
    *out_pid = resp->pid;
  containerd__services__tasks__v1__start_response__free_unpacked(resp, NULL);
  return CC_GRPC_STATUS_OK;
}

int cc_ctr_kill_task(int h, const char *container_id, uint32_t signal) {
  Containerd__Services__Tasks__V1__KillRequest req =
      CONTAINERD__SERVICES__TASKS__V1__KILL_REQUEST__INIT;
  uint8_t reqbuf[1024];
  uint8_t respbuf[1024];
  uint32_t resp_len = 0;
  size_t reqlen;

  if (h <= 0 || container_id == NULL || container_id[0] == '\0')
    return CC_CTR_ERR_BADARG;
  req.container_id = (char *)container_id;
  req.signal = signal;
  reqlen = containerd__services__tasks__v1__kill_request__get_packed_size(
      &req);
  containerd__services__tasks__v1__kill_request__pack(&req, reqbuf);
  return cc_grpc_unary(h, "/containerd.services.tasks.v1.Tasks/Kill", reqbuf,
                       (uint32_t)reqlen, respbuf, sizeof(respbuf), &resp_len);
}

int cc_ctr_delete_task(int h, const char *container_id,
                       uint32_t *out_exit_status) {
  Containerd__Services__Tasks__V1__DeleteTaskRequest req =
      CONTAINERD__SERVICES__TASKS__V1__DELETE_TASK_REQUEST__INIT;
  uint8_t reqbuf[1024];
  uint8_t respbuf[1024];
  uint32_t resp_len = 0;
  Containerd__Services__Tasks__V1__DeleteResponse *resp;
  size_t reqlen;
  int rc;

  if (h <= 0 || container_id == NULL || container_id[0] == '\0')
    return CC_CTR_ERR_BADARG;
  if (out_exit_status != NULL)
    *out_exit_status = 0;
  req.container_id = (char *)container_id;
  reqlen = containerd__services__tasks__v1__delete_task_request__get_packed_size(
      &req);
  containerd__services__tasks__v1__delete_task_request__pack(&req, reqbuf);
  rc = cc_grpc_unary(h, "/containerd.services.tasks.v1.Tasks/Delete", reqbuf,
                     (uint32_t)reqlen, respbuf, sizeof(respbuf), &resp_len);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  resp = containerd__services__tasks__v1__delete_response__unpack(
      NULL, resp_len, respbuf);
  if (resp == NULL)
    return CC_CTR_ERR_STATE;
  if (out_exit_status != NULL)
    *out_exit_status = resp->exit_status;
  containerd__services__tasks__v1__delete_response__free_unpacked(resp, NULL);
  return CC_GRPC_STATUS_OK;
}

int cc_ctr_get_task(int h, const char *container_id, uint32_t *out_pid) {
  Containerd__Services__Tasks__V1__GetRequest req =
      CONTAINERD__SERVICES__TASKS__V1__GET_REQUEST__INIT;
  uint8_t reqbuf[1024];
  uint8_t respbuf[CC_CTR_RESP_MAX];
  uint32_t resp_len = 0;
  Containerd__Services__Tasks__V1__GetResponse *resp;
  size_t reqlen;
  int rc;

  if (h <= 0 || container_id == NULL || container_id[0] == '\0')
    return CC_CTR_ERR_BADARG;
  if (out_pid != NULL)
    *out_pid = 0;
  req.container_id = (char *)container_id;
  reqlen = containerd__services__tasks__v1__get_request__get_packed_size(&req);
  containerd__services__tasks__v1__get_request__pack(&req, reqbuf);
  rc = cc_grpc_unary(h, "/containerd.services.tasks.v1.Tasks/Get", reqbuf,
                     (uint32_t)reqlen, respbuf, sizeof(respbuf), &resp_len);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  resp = containerd__services__tasks__v1__get_response__unpack(
      NULL, resp_len, respbuf);
  if (resp == NULL || resp->process == NULL)
    return CC_CTR_ERR_STATE;
  if (out_pid != NULL)
    *out_pid = resp->process->pid;
  containerd__services__tasks__v1__get_response__free_unpacked(resp, NULL);
  return CC_GRPC_STATUS_OK;
}

int cc_ctr_wait_task(int h, const char *container_id,
                     uint32_t *out_exit_status) {
  Containerd__Services__Tasks__V1__WaitRequest req =
      CONTAINERD__SERVICES__TASKS__V1__WAIT_REQUEST__INIT;
  uint8_t reqbuf[1024];
  uint8_t respbuf[1024];
  uint32_t resp_len = 0;
  Containerd__Services__Tasks__V1__WaitResponse *resp;
  size_t reqlen;
  int rc;

  if (h <= 0 || container_id == NULL || container_id[0] == '\0')
    return CC_CTR_ERR_BADARG;
  if (out_exit_status != NULL)
    *out_exit_status = 0;
  req.container_id = (char *)container_id;
  reqlen = containerd__services__tasks__v1__wait_request__get_packed_size(
      &req);
  containerd__services__tasks__v1__wait_request__pack(&req, reqbuf);
  rc = cc_grpc_unary(h, "/containerd.services.tasks.v1.Tasks/Wait", reqbuf,
                     (uint32_t)reqlen, respbuf, sizeof(respbuf), &resp_len);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  resp = containerd__services__tasks__v1__wait_response__unpack(
      NULL, resp_len, respbuf);
  if (resp == NULL)
    return CC_CTR_ERR_STATE;
  if (out_exit_status != NULL)
    *out_exit_status = resp->exit_status;
  containerd__services__tasks__v1__wait_response__free_unpacked(resp, NULL);
  return CC_GRPC_STATUS_OK;
}

/* =========================================================================
 * Events
 * ========================================================================= */

int cc_ctr_subscribe(int h, const char *filter, void *cb_ctx,
                     void (*cb)(void *cb_ctx, const uint8_t *env,
                                uint32_t len)) {
  if (h <= 0 || filter == NULL || cb == NULL)
    return 0;
  return cc_grpc_subscribe(h, filter, cb_ctx, cb);
}

/* =========================================================================
 * OCI spec JSON builder + Any wrapper (Q13 contract)
 * ========================================================================= */

/* --- tiny JSON writer (Go json.Marshal-compatible) --- */

struct json_out {
  char *buf;
  uint32_t cap;
  uint32_t len;
};

static void jout_raw(struct json_out *o, const char *s) {
  size_t n = strlen(s);
  if (o->len + n >= o->cap)
    n = (o->cap > o->len) ? o->cap - o->len : 0;
  memcpy(o->buf + o->len, s, n);
  o->len += (uint32_t)n;
}

static void jout_ch(struct json_out *o, char c) {
  if (o->len + 1 >= o->cap)
    return;
  o->buf[o->len++] = c;
}

static void jout_uint(struct json_out *o, uint32_t v) {
  char tmp[16];
  int n = 0;
  do {
    tmp[n++] = (char)('0' + v % 10);
    v /= 10;
  } while (v > 0);
  while (n > 0)
    jout_ch(o, tmp[--n]);
}

/* Emit a JSON string with Go's encoding/json escaping: quote, backslash,
 * \t \r \n, control chars as \u00xx, and HTML escapes \u003c \u003e \u0026
 * (all lowercase hex, matching Go's SetEscapeHTML(true) default). */
static void jout_str(struct json_out *o, const char *s) {
  static const char hex[] = "0123456789abcdef";
  const unsigned char *p;

  if (s == NULL)
    s = ""; /* boundary parse: NULL string -> empty */
  p = (const unsigned char *)s;
  jout_ch(o, '"');
  while (*p != 0) {
    unsigned char c = *p++;
    switch (c) {
      case '"':
        jout_raw(o, "\\\"");
        break;
      case '\\':
        jout_raw(o, "\\\\");
        break;
      case '\n':
        jout_raw(o, "\\n");
        break;
      case '\r':
        jout_raw(o, "\\r");
        break;
      case '\t':
        jout_raw(o, "\\t");
        break;
      case '<':
        jout_raw(o, "\\u003c");
        break;
      case '>':
        jout_raw(o, "\\u003e");
        break;
      case '&':
        jout_raw(o, "\\u0026");
        break;
      default:
        if (c < 0x20) {
          jout_raw(o, "\\u00");
          jout_ch(o, hex[c >> 4]);
          jout_ch(o, hex[c & 0xF]);
        } else {
          jout_ch(o, (char)c);
        }
        break;
    }
  }
  jout_ch(o, '"');
}

static void jout_str_array(struct json_out *o, const char *const *strs,
                           uint32_t n) {
  uint32_t i;
  jout_ch(o, '[');
  for (i = 0; i < n; i++) {
    if (i > 0)
      jout_ch(o, ',');
    jout_str(o, strs[i]);
  }
  jout_ch(o, ']');
}

/* --- the fixed skeleton constants (from the Go client) --- */

static const char *const k_default_caps[] = {
    "CAP_CHOWN",        "CAP_DAC_OVERRIDE", "CAP_FSETID",
    "CAP_FOWNER",       "CAP_MKNOD",        "CAP_NET_RAW",
    "CAP_SETGID",       "CAP_SETUID",       "CAP_SETFCAP",
    "CAP_SETPCAP",      "CAP_NET_BIND_SERVICE", "CAP_SYS_CHROOT",
    "CAP_KILL",         "CAP_AUDIT_WRITE",
};

static const char *const k_default_namespaces[] = {"pid", "ipc", "uts",
                                                   "mount"};
static const char *const k_default_namespaces_net[] = {"pid", "ipc", "uts",
                                                       "mount", "network"};

static const char *const k_masked_paths[] = {
    "/proc/acpi",
    "/proc/asound",
    "/proc/kcore",
    "/proc/keys",
    "/proc/latency_stats",
    "/proc/timer_list",
    "/proc/timer_stats",
    "/proc/sched_debug",
    "/sys/firmware",
    "/sys/devices/virtual/powercap",
    "/proc/scsi",
};

static const char *const k_readonly_paths[] = {
    "/proc/bus",
    "/proc/fs",
    "/proc/irq",
    "/proc/sys",
    "/proc/sysrq-trigger",
};

/* The seven default mounts (oci.defaultMounts), in order. Each entry is
 * destination, type, source, then up to 8 options. */
struct default_mount {
  const char *destination;
  const char *type;
  const char *source;
  uint32_t n_options;
  const char *options[8];
};

static const struct default_mount k_default_mounts[] = {
    {"/proc", "proc", "proc", 3,
     {"nosuid", "noexec", "nodev"}},
    {"/dev", "tmpfs", "tmpfs", 4,
     {"nosuid", "strictatime", "mode=755", "size=65536k"}},
    {"/dev/pts", "devpts", "devpts", 6,
     {"nosuid", "noexec", "newinstance", "ptmxmode=0666", "mode=0620",
      "gid=5"}},
    {"/dev/shm", "tmpfs", "shm", 5,
     {"nosuid", "noexec", "nodev", "mode=1777", "size=65536k"}},
    {"/dev/mqueue", "mqueue", "mqueue", 3,
     {"nosuid", "noexec", "nodev"}},
    {"/sys", "sysfs", "sysfs", 4,
     {"nosuid", "noexec", "nodev", "ro"}},
    {"/run", "tmpfs", "tmpfs", 4,
     {"nosuid", "strictatime", "mode=755", "size=65536k"}},
};

static void jout_mount_json(struct json_out *o, const char *destination,
                            const char *type, const char *source,
                            const char *const *options, uint32_t n_options) {
  jout_ch(o, '{');
  jout_raw(o, "\"destination\":");
  jout_str(o, destination);
  if (type != NULL && type[0] != '\0') {
    jout_raw(o, ",\"type\":");
    jout_str(o, type);
  }
  if (source != NULL && source[0] != '\0') {
    jout_raw(o, ",\"source\":");
    jout_str(o, source);
  }
  if (n_options > 0) {
    jout_raw(o, ",\"options\":");
    jout_str_array(o, options, n_options);
  }
  jout_ch(o, '}');
}

int cc_ctr_oci_spec_build(const struct cc_ctr_oci_spec *spec, char *out,
                          uint32_t cap) {
  struct json_out o;
  uint32_t i;

  if (spec == NULL || out == NULL || cap == 0)
    return CC_CTR_ERR_BADARG;
  /* Boundary validation: the fixed-size field tables cannot overflow; fail
   * loudly instead of silently dropping entries. */
  if (spec->n_env > CC_CTR_OCI_ENV_MAX || spec->n_args > CC_CTR_OCI_ARGS_MAX ||
      spec->n_caps_add > CC_CTR_OCI_CAPS_MAX ||
      spec->n_additional_gids > CC_CTR_OCI_GIDS_MAX ||
      spec->n_mounts > CC_CTR_OCI_MOUNTS_MAX ||
      spec->n_annotations > CC_CTR_OCI_ANN_MAX)
    return CC_CTR_ERR_BADARG;
  o.buf = out;
  o.cap = cap;
  o.len = 0;

  /* Spec struct order: ociVersion, process, root, hostname, domainname,
   * mounts, hooks, annotations, linux. */
  jout_raw(&o, "{\"ociVersion\":");
  jout_str(&o, CC_CTR_OCI_VERSION);

  /* process */
  jout_raw(&o, ",\"process\":{\"user\":{\"uid\":");
  jout_uint(&o, spec->uid);
  jout_raw(&o, ",\"gid\":");
  jout_uint(&o, spec->gid);
  if (spec->n_additional_gids > 0) {
    jout_raw(&o, ",\"additionalGids\":[");
    for (i = 0; i < spec->n_additional_gids; i++) {
      if (i > 0)
        jout_ch(&o, ',');
      jout_uint(&o, spec->additional_gids[i]);
    }
    jout_ch(&o, ']');
  }
  jout_ch(&o, '}');
  if (spec->n_args > 0) {
    jout_raw(&o, ",\"args\":");
    jout_str_array(&o, spec->args, spec->n_args);
  }
  if (spec->n_env > 0) {
    jout_raw(&o, ",\"env\":");
    jout_str_array(&o, spec->env, spec->n_env);
  }
  jout_raw(&o, ",\"cwd\":");
  jout_str(&o, spec->cwd != NULL ? spec->cwd : "/");

  /* capabilities: bounding/effective/permitted = default + adds */
  jout_raw(&o, ",\"capabilities\":{\"bounding\":");
  {
    const char *caps[CC_CTR_OCI_CAPS_MAX + 16];
    uint32_t n_caps = 0;
    for (i = 0; i < 14 && n_caps < (CC_CTR_OCI_CAPS_MAX + 16); i++)
      caps[n_caps++] = k_default_caps[i];
    for (i = 0; i < spec->n_caps_add && n_caps < (CC_CTR_OCI_CAPS_MAX + 16);
         i++)
      caps[n_caps++] = spec->caps_add[i];
    jout_str_array(&o, caps, n_caps);
  }
  jout_raw(&o, ",\"effective\":");
  {
    const char *caps[CC_CTR_OCI_CAPS_MAX + 16];
    uint32_t n_caps = 0;
    for (i = 0; i < 14 && n_caps < (CC_CTR_OCI_CAPS_MAX + 16); i++)
      caps[n_caps++] = k_default_caps[i];
    for (i = 0; i < spec->n_caps_add && n_caps < (CC_CTR_OCI_CAPS_MAX + 16);
         i++)
      caps[n_caps++] = spec->caps_add[i];
    jout_str_array(&o, caps, n_caps);
  }
  jout_raw(&o, ",\"permitted\":");
  {
    const char *caps[CC_CTR_OCI_CAPS_MAX + 16];
    uint32_t n_caps = 0;
    for (i = 0; i < 14 && n_caps < (CC_CTR_OCI_CAPS_MAX + 16); i++)
      caps[n_caps++] = k_default_caps[i];
    for (i = 0; i < spec->n_caps_add && n_caps < (CC_CTR_OCI_CAPS_MAX + 16);
         i++)
      caps[n_caps++] = spec->caps_add[i];
    jout_str_array(&o, caps, n_caps);
  }
  jout_ch(&o, '}');

  jout_raw(&o, ",\"rlimits\":[{\"type\":\"RLIMIT_NOFILE\",\"hard\":1024,\"soft\":1024}]");
  jout_raw(&o, ",\"noNewPrivileges\":true");

  /* root */
  jout_raw(&o, "},\"root\":{\"path\":\"rootfs\"}");

  /* hostname (Spec struct order: root, hostname, domainname, mounts) */
  if (spec->hostname != NULL && spec->hostname[0] != '\0') {
    jout_raw(&o, ",\"hostname\":");
    jout_str(&o, spec->hostname);
  }

  /* mounts: 7 defaults + controller bind mounts */
  jout_raw(&o, ",\"mounts\":[");
  for (i = 0; i < 7; i++) {
    if (i > 0)
      jout_ch(&o, ',');
    jout_mount_json(&o, k_default_mounts[i].destination,
                    k_default_mounts[i].type, k_default_mounts[i].source,
                    k_default_mounts[i].options,
                    k_default_mounts[i].n_options);
  }
  for (i = 0; i < spec->n_mounts; i++) {
    jout_ch(&o, ',');
    jout_mount_json(&o, spec->mounts[i].destination, spec->mounts[i].type,
                    spec->mounts[i].source, spec->mounts[i].options,
                    spec->mounts[i].n_options);
  }
  jout_ch(&o, ']');

  /* annotations (before linux, per Spec struct order); entries are
   "key=value" strings emitted as JSON members. */
  if (spec->n_annotations > 0) {
    jout_raw(&o, ",\"annotations\":{");
    for (i = 0; i < spec->n_annotations; i++) {
      const char *eq;
      if (i > 0)
        jout_ch(&o, ',');
      if (spec->annotations[i] == NULL)
        return CC_CTR_ERR_JSON;
      eq = strchr(spec->annotations[i], '=');
      /* Emit the key with its own NUL-terminated copy (the writer only
       * reads; a temporary character swap is safe here). */
      {
        char keybuf[512];
        size_t keylen = (size_t)(eq - spec->annotations[i]);
        if (keylen >= sizeof(keybuf))
          return CC_CTR_ERR_JSON;
        memcpy(keybuf, spec->annotations[i], keylen);
        keybuf[keylen] = '\0';
        jout_str(&o, keybuf);
      }
      jout_ch(&o, ':');
      jout_str(&o, eq + 1);
    }
    jout_ch(&o, '}');
  }

  /* linux */
  jout_raw(&o, ",\"linux\":{\"resources\":{\"devices\":[{\"allow\":false,\"access\":\"rwm\"}]}");
  if (spec->cgroups_path != NULL && spec->cgroups_path[0] != '\0') {
    jout_raw(&o, ",\"cgroupsPath\":");
    jout_str(&o, spec->cgroups_path);
  }
  jout_raw(&o, ",\"namespaces\":[");
  if (spec->host_network) {
    for (i = 0; i < 4; i++) {
      if (i > 0)
        jout_ch(&o, ',');
      jout_raw(&o, "{\"type\":");
      jout_str(&o, k_default_namespaces[i]);
      jout_ch(&o, '}');
    }
  } else {
    for (i = 0; i < 5; i++) {
      if (i > 0)
        jout_ch(&o, ',');
      jout_raw(&o, "{\"type\":");
      jout_str(&o, k_default_namespaces_net[i]);
      jout_ch(&o, '}');
    }
  }
  jout_ch(&o, ']');
  jout_raw(&o, ",\"maskedPaths\":");
  jout_str_array(&o, k_masked_paths, 11);
  jout_raw(&o, ",\"readonlyPaths\":");
  jout_str_array(&o, k_readonly_paths, 5);
  jout_raw(&o, "}}");

  if (o.len >= o.cap) {
    /* The writer truncates silently at cap; report overflow loudly. */
    return CC_CTR_ERR_TOOBIG;
  }
  o.buf[o.len] = '\0';
  return (int)o.len;
}

int cc_ctr_oci_wrap_any(const uint8_t *spec_json, uint32_t json_len,
                        uint8_t *out_any, uint32_t any_cap,
                        uint32_t *out_any_len) {
  Google__Protobuf__Any any = GOOGLE__PROTOBUF__ANY__INIT;
  size_t len;

  if (spec_json == NULL || json_len == 0 || out_any == NULL || any_cap == 0 ||
      out_any_len == NULL)
    return CC_CTR_ERR_BADARG;
  any.type_url = (char *)CC_CTR_OCI_TYPE_URL;
  any.value.data = (uint8_t *)spec_json;
  any.value.len = json_len;
  len = google__protobuf__any__get_packed_size(&any);
  if (len > any_cap)
    return CC_CTR_ERR_TOOBIG;
  google__protobuf__any__pack(&any, out_any);
  *out_any_len = (uint32_t)len;
  return CC_GRPC_STATUS_OK;
}

int cc_ctr_pack_runc_nvidia(const char *nvidia_bin, uint8_t *out_any,
                            uint32_t any_cap, uint32_t *out_any_len) {
  uint8_t runc_value[130];
  uint32_t runc_value_len = 0;
  Google__Protobuf__Any any = GOOGLE__PROTOBUF__ANY__INIT;
  size_t len;
  int rc;

  if (out_any == NULL || any_cap == 0 || out_any_len == NULL)
    return CC_CTR_ERR_BADARG;
  rc = ctr_pack_runc_value(nvidia_bin, runc_value, sizeof(runc_value),
                           &runc_value_len);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  any.type_url = (char *)CC_CTR_RUNC_OPTIONS_TYPE_URL;
  any.value.data = runc_value;
  any.value.len = runc_value_len;
  len = google__protobuf__any__get_packed_size(&any);
  if (len > any_cap)
    return CC_CTR_ERR_TOOBIG;
  google__protobuf__any__pack(&any, out_any);
  *out_any_len = (uint32_t)len;
  return CC_GRPC_STATUS_OK;
}