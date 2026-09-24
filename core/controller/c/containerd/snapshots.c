/*
 * snapshots.c — minimal containerd Snapshots service client.
 *
 * Hand-rolled protobuf wire encoding/decoding (minipb.h) for the three RPCs
 * the container client needs. See snapshots.h.
 *
 * License: project code (see LICENSE). No GPL.
 */

#include "snapshots.h"

#include <stdlib.h>
#include <string.h>

#include "minipb.h"

#define SNAP_METHOD_PREPARE "/containerd.services.snapshots.v1.Snapshots/Prepare"
#define SNAP_METHOD_REMOVE  "/containerd.services.snapshots.v1.Snapshots/Remove"
#define SNAP_METHOD_MOUNTS  "/containerd.services.snapshots.v1.Snapshots/Mounts"

#define SNAP_TIMEOUT_MS 30000

/* Forward declaration (defined below). */
int mpb_decode_mount(const uint8_t *data, size_t len,
                     containerd_types_Mount *out);

/* Decode a `repeated containerd.types.Mount mounts = 1` response body into a
 * malloc'd array of nanopb containerd_types_Mount structs. Returns 0 on
 * success, -1 on a wire-format error. */
static int decode_mounts_response(const uint8_t *body, size_t body_len,
                                  containerd_types_Mount **out_mounts,
                                  pb_size_t *out_n) {
  containerd_types_Mount *mounts = NULL;
  pb_size_t n = 0;
  pb_size_t cap = 0;
  mpb_rd r;
  int rc = 0;

  r.data = body;
  r.len = body_len;
  r.off = 0;

  while (r.off < r.len) {
    int field, wiretype;
    if (mpb_rd_tag(&r, &field, &wiretype) < 0) {
      rc = -1;
      goto done;
    }
    if (field == 1 && wiretype == MPB_WT_LEN) {
      const uint8_t *mdata;
      size_t mlen;
      containerd_types_Mount *m;
      if (mpb_rd_len(&r, &mdata, &mlen) < 0) {
        rc = -1;
        goto done;
      }
      if (n == cap) {
        pb_size_t ncap = cap ? (pb_size_t)(cap * 2) : 4;
        containerd_types_Mount *np =
            (containerd_types_Mount *)realloc(mounts, ncap * sizeof(*np));
        if (np == NULL) {
          rc = -1;
          goto done;
        }
        mounts = np;
        cap = ncap;
      }
      m = &mounts[n];
      memset(m, 0, sizeof(*m));
      if (mpb_decode_mount(mdata, mlen, m) < 0) {
        rc = -1;
        goto done;
      }
      n++;
    } else if (mpb_rd_skip(&r, wiretype) < 0) {
      rc = -1;
      goto done;
    }
  }

  *out_mounts = mounts;
  *out_n = n;
  return 0;

done:
  if (mounts != NULL) {
    snapshots_free_mounts(mounts, n);
    free(mounts);
  }
  return rc;
}

void snapshots_free_mounts(containerd_types_Mount *mounts, pb_size_t n) {
  pb_size_t i;
  if (mounts == NULL)
    return;
  for (i = 0; i < n; i++) {
    free(mounts[i].type);
    free(mounts[i].source);
    free(mounts[i].target);
    if (mounts[i].options != NULL) {
      pb_size_t j;
      for (j = 0; j < mounts[i].options_count; j++)
        free(mounts[i].options[j]);
      free(mounts[i].options);
    }
  }
  free(mounts);
}

/* Decode one containerd.types.Mount submessage into the nanopb struct. */
int mpb_decode_mount(const uint8_t *data, size_t len,
                     containerd_types_Mount *out) {
  mpb_rd r;
  r.data = data;
  r.len = len;
  r.off = 0;

  while (r.off < r.len) {
    int field, wiretype;
    if (mpb_rd_tag(&r, &field, &wiretype) < 0)
      return -1;
    switch (field) {
    case 1: { /* type */
      const uint8_t *p;
      size_t n;
      if (wiretype != MPB_WT_LEN || mpb_rd_len(&r, &p, &n) < 0)
        return -1;
      out->type = (char *)malloc(n + 1);
      if (out->type == NULL)
        return -1;
      memcpy(out->type, p, n);
      out->type[n] = '\0';
      break;
    }
    case 2: { /* source */
      const uint8_t *p;
      size_t n;
      if (wiretype != MPB_WT_LEN || mpb_rd_len(&r, &p, &n) < 0)
        return -1;
      out->source = (char *)malloc(n + 1);
      if (out->source == NULL)
        return -1;
      memcpy(out->source, p, n);
      out->source[n] = '\0';
      break;
    }
    case 3: { /* target */
      const uint8_t *p;
      size_t n;
      if (wiretype != MPB_WT_LEN || mpb_rd_len(&r, &p, &n) < 0)
        return -1;
      out->target = (char *)malloc(n + 1);
      if (out->target == NULL)
        return -1;
      memcpy(out->target, p, n);
      out->target[n] = '\0';
      break;
    }
    case 4: { /* options (repeated string) */
      const uint8_t *p;
      size_t n;
      char **np;
      if (wiretype != MPB_WT_LEN || mpb_rd_len(&r, &p, &n) < 0)
        return -1;
      np = (char **)realloc(out->options,
                            (out->options_count + 1) * sizeof(char *));
      if (np == NULL)
        return -1;
      out->options = np;
      out->options[out->options_count] = (char *)malloc(n + 1);
      if (out->options[out->options_count] == NULL)
        return -1;
      memcpy(out->options[out->options_count], p, n);
      out->options[out->options_count][n] = '\0';
      out->options_count++;
      break;
    }
    default:
      if (mpb_rd_skip(&r, wiretype) < 0)
        return -1;
      break;
    }
  }
  return 0;
}

/* Encode a SnapshotRequest {snapshotter=1, key=2, parent=3} (labels skipped:
 * the controller never sets snapshot labels). */
static int encode_snap_request(const char *snapshotter, const char *key,
                               const char *parent, mpb_buf *out) {
  out->data = NULL;
  out->len = 0;
  out->cap = 0;
  mpb_put_string(out, 1, snapshotter);
  mpb_put_string(out, 2, key);
  mpb_put_string(out, 3, parent);
  return 0;
}

static int snap_unary_mounts(strim_h2c *c, const char *method,
                             const char *snapshotter, const char *key,
                             const char *parent,
                             containerd_types_Mount **mounts,
                             pb_size_t *n_mounts) {
  mpb_buf req;
  uint8_t resp[16384];
  uint32_t resp_len = 0;
  int rc;

  if (c == NULL || snapshotter == NULL || key == NULL)
    return H2C_ERR_BADARG;

  encode_snap_request(snapshotter, key, parent, &req);
  rc = h2c_unary(c, method, req.data, (uint32_t)req.len, resp, sizeof(resp),
                 &resp_len, SNAP_TIMEOUT_MS);
  mpb_buf_free(&req);
  if (rc != 0)
    return rc;
  if (mounts != NULL && n_mounts != NULL) {
    if (decode_mounts_response(resp, resp_len, mounts, n_mounts) < 0)
      return H2C_ERR_PROTO;
  }
  return 0;
}

int snapshots_prepare(strim_h2c *c, const char *snapshotter, const char *key,
                      const char *parent, containerd_types_Mount **mounts,
                      pb_size_t *n_mounts) {
  return snap_unary_mounts(c, SNAP_METHOD_PREPARE, snapshotter, key, parent,
                           mounts, n_mounts);
}

int snapshots_mounts(strim_h2c *c, const char *snapshotter, const char *key,
                     containerd_types_Mount **mounts, pb_size_t *n_mounts) {
  return snap_unary_mounts(c, SNAP_METHOD_MOUNTS, snapshotter, key, NULL,
                           mounts, n_mounts);
}

int snapshots_remove(strim_h2c *c, const char *snapshotter, const char *key) {
  mpb_buf req;
  uint8_t resp[64];
  uint32_t resp_len = 0;
  int rc;

  if (c == NULL || snapshotter == NULL || key == NULL)
    return H2C_ERR_BADARG;

  encode_snap_request(snapshotter, key, NULL, &req);
  rc = h2c_unary(c, SNAP_METHOD_REMOVE, req.data, (uint32_t)req.len, resp,
                 sizeof(resp), &resp_len, SNAP_TIMEOUT_MS);
  mpb_buf_free(&req);
  return rc;
}