/*
 * content.c — minimal containerd Content service client (blob reads).
 *
 * Hand-rolled protobuf wire encoding/decoding (minipb.h) for Content/Read.
 * See content.h.
 *
 * License: project code (see LICENSE). No GPL.
 */

#include "content.h"

#include <stdlib.h>
#include <string.h>

#include "minipb.h"

#define CONTENT_METHOD_READ "/containerd.services.content.v1.Content/Read"

/* Decode one ReadContentResponse {offset=1, data=2} and append its data. */
static int decode_read_response(const uint8_t *body, size_t body_len,
                                uint8_t **acc, size_t *acc_len, size_t *acc_cap,
                                size_t max_len) {
  mpb_rd r;
  r.data = body;
  r.len = body_len;
  r.off = 0;

  while (r.off < r.len) {
    int field, wiretype;
    if (mpb_rd_tag(&r, &field, &wiretype) < 0)
      return -1;
    if (field == 2 && wiretype == MPB_WT_LEN) {
      const uint8_t *p;
      size_t n;
      if (mpb_rd_len(&r, &p, &n) < 0)
        return -1;
      if (*acc_len + n > max_len)
        return -1; /* blob exceeds the caller's bound */
      if (*acc_len + n > *acc_cap) {
        size_t ncap = *acc_cap ? *acc_cap : 4096;
        uint8_t *np;
        while (ncap < *acc_len + n)
          ncap *= 2;
        np = (uint8_t *)realloc(*acc, ncap);
        if (np == NULL)
          return -1;
        *acc = np;
        *acc_cap = ncap;
      }
      memcpy(*acc + *acc_len, p, n);
      *acc_len += n;
    } else if (mpb_rd_skip(&r, wiretype) < 0) {
      return -1;
    }
  }
  return 0;
}

int content_read_blob(strim_h2c *c, const char *digest, size_t max_len,
                      uint8_t **out, size_t *out_len) {
  mpb_buf req;
  strim_h2c_stream *st = NULL;
  uint8_t *acc = NULL;
  size_t acc_len = 0;
  size_t acc_cap = 0;
  int rc;

  if (c == NULL || digest == NULL || out == NULL || out_len == NULL)
    return H2C_ERR_BADARG;
  *out = NULL;
  *out_len = 0;

  /* ReadContentRequest {digest=1, offset=2, size=3}; offset=size=0 reads all. */
  req.data = NULL;
  req.len = 0;
  req.cap = 0;
  mpb_put_string(&req, 1, digest);

  rc = h2c_stream_open(c, CONTENT_METHOD_READ, req.data, (uint32_t)req.len,
                       &st);
  mpb_buf_free(&req);
  if (rc != 0)
    return rc;

  for (;;) {
    const uint8_t *msg;
    uint32_t msg_len;
    rc = h2c_stream_next(st, 30000, &msg, &msg_len);
    if (rc == H2C_ERR_STREAM_END)
      break;
    if (rc != 0) {
      h2c_stream_close(st);
      free(acc);
      return (rc == H2C_ERR_TIMEOUT) ? H2C_ERR_TIMEOUT : rc;
    }
    if (decode_read_response(msg, msg_len, &acc, &acc_len, &acc_cap,
                             max_len) < 0) {
      h2c_stream_close(st);
      free(acc);
      return H2C_ERR_PROTO;
    }
  }
  h2c_stream_close(st);

  *out = acc;
  *out_len = acc_len;
  return 0;
}