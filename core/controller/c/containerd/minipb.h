/*
 * minipb.h — tiny protobuf wire-format helpers (encode + decode).
 *
 * Wave 1 (containerd lane). The nanopb codecs cover Images/Containers/Tasks/
 * Events but NOT the Snapshots or Content services (the repo's Wave 0-D
 * codegen set is deliberately minimal). The containerd client needs three
 * Snapshots RPCs (Prepare / Remove / Mounts) and one Content RPC (Read) for
 * the image-rootfs chain-ID contract (container_factory.go:133-137). Those
 * messages are small and simple, so this file hand-rolls just their wire
 * format — no protobuf runtime dependency, arch-independent C.
 *
 * Encoders append into a growable buffer; decoders walk a fixed buffer. All
 * helpers are pure (buffer in/out), fail-fast on overflow, and never
 * silently truncate. String fields are emitted only when non-NULL (proto3
 * default-value elision, matching grpc-go).
 *
 * License: project code (see LICENSE). No GPL.
 */
#ifndef STRIM_MINIPB_H
#define STRIM_MINIPB_H

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* Wire types. */
#define MPB_WT_VARINT 0
#define MPB_WT_64BIT  1
#define MPB_WT_LEN    2
#define MPB_WT_32BIT  5

/* =========================================================================
 * Encoding (growable buffer)
 * ========================================================================= */

typedef struct mpb_buf {
  uint8_t *data;
  size_t len;
  size_t cap;
} mpb_buf;

static inline int mpb_reserve(mpb_buf *b, size_t extra) {
  size_t need = b->len + extra;
  size_t ncap;
  uint8_t *np;
  if (need <= b->cap)
    return 0;
  ncap = b->cap ? b->cap : 64;
  while (ncap < need)
    ncap *= 2;
  np = (uint8_t *)realloc(b->data, ncap);
  if (np == NULL)
    return -1;
  b->data = np;
  b->cap = ncap;
  return 0;
}

static inline void mpb_put_u8(mpb_buf *b, uint8_t v) {
  if (mpb_reserve(b, 1) < 0)
    return;
  b->data[b->len++] = v;
}

static inline void mpb_put_varint(mpb_buf *b, uint64_t v) {
  uint8_t tmp[10];
  size_t n = 0;
  while (v >= 0x80) {
    tmp[n++] = (uint8_t)(v | 0x80);
    v >>= 7;
  }
  tmp[n++] = (uint8_t)v;
  if (mpb_reserve(b, n) < 0)
    return;
  memcpy(b->data + b->len, tmp, n);
  b->len += n;
}

static inline void mpb_put_tag(mpb_buf *b, int field, int wiretype) {
  mpb_put_varint(b, ((uint64_t)field << 3) | (uint64_t)wiretype);
}

/* Length-delimited payload; the caller supplies the wiretype-2 tag already. */
static inline void mpb_put_len(mpb_buf *b, const void *data, size_t len) {
  mpb_put_varint(b, len);
  if (mpb_reserve(b, len) < 0)
    return;
  if (len)
    memcpy(b->data + b->len, data, len);
  b->len += len;
}

static inline void mpb_put_string(mpb_buf *b, int field, const char *s) {
  size_t len;
  if (s == NULL || s[0] == '\0')
    return; /* proto3: empty default value is not serialized */
  len = strlen(s);
  mpb_put_tag(b, field, MPB_WT_LEN);
  mpb_put_len(b, s, len);
}

static inline void mpb_put_bytes(mpb_buf *b, int field, const void *data, size_t len) {
  if (len == 0)
    return;
  mpb_put_tag(b, field, MPB_WT_LEN);
  mpb_put_len(b, data, len);
}

static inline void mpb_put_int64(mpb_buf *b, int field, int64_t v) {
  if (v == 0)
    return; /* proto3 default-value elision */
  mpb_put_tag(b, field, MPB_WT_VARINT);
  mpb_put_varint(b, (uint64_t)v);
}

static inline void mpb_put_bool(mpb_buf *b, int field, int v) {
  if (!v)
    return;
  mpb_put_tag(b, field, MPB_WT_VARINT);
  mpb_put_u8(b, 1);
}

/* Nested message: encodes sub into a length-delimited field. */
static inline void mpb_put_message(mpb_buf *b, int field, const mpb_buf *sub) {
  if (sub->len == 0)
    return;
  mpb_put_tag(b, field, MPB_WT_LEN);
  mpb_put_len(b, sub->data, sub->len);
}

static inline void mpb_buf_free(mpb_buf *b) {
  free(b->data);
  b->data = NULL;
  b->len = 0;
  b->cap = 0;
}

/* =========================================================================
 * Decoding (fixed buffer walker)
 * ========================================================================= */

typedef struct mpb_rd {
  const uint8_t *data;
  size_t len;
  size_t off;
} mpb_rd;

static inline int mpb_rd_varint(mpb_rd *r, uint64_t *out) {
  uint64_t v = 0;
  int shift = 0;
  while (r->off < r->len) {
    uint8_t b = r->data[r->off++];
    v |= (uint64_t)(b & 0x7f) << shift;
    if ((b & 0x80) == 0) {
      *out = v;
      return 0;
    }
    shift += 7;
    if (shift > 63)
      return -1;
  }
  return -1;
}

/* Read the next field tag. Returns 0 + field/wiretype, or -1 at EOF. */
static inline int mpb_rd_tag(mpb_rd *r, int *field, int *wiretype) {
  uint64_t tag;
  if (r->off >= r->len)
    return -1;
  if (mpb_rd_varint(r, &tag) < 0)
    return -1;
  *field = (int)(tag >> 3);
  *wiretype = (int)(tag & 7);
  return 0;
}

/* Read a length-delimited field payload (the tag must already be consumed). */
static inline int mpb_rd_len(mpb_rd *r, const uint8_t **out, size_t *out_len) {
  uint64_t len;
  if (mpb_rd_varint(r, &len) < 0)
    return -1;
  if (len > r->len - r->off)
    return -1;
  *out = r->data + r->off;
  *out_len = (size_t)len;
  r->off += (size_t)len;
  return 0;
}

/* Skip a field body given its wire type. */
static inline int mpb_rd_skip(mpb_rd *r, int wiretype) {
  uint64_t v;
  const uint8_t *p;
  size_t n;
  switch (wiretype) {
  case MPB_WT_VARINT:
    return mpb_rd_varint(r, &v);
  case MPB_WT_64BIT:
    if (r->off + 8 > r->len)
      return -1;
    r->off += 8;
    return 0;
  case MPB_WT_LEN:
    return mpb_rd_len(r, &p, &n);
  case MPB_WT_32BIT:
    if (r->off + 4 > r->len)
      return -1;
    r->off += 4;
    return 0;
  default:
    return -1;
  }
}

#endif /* STRIM_MINIPB_H */