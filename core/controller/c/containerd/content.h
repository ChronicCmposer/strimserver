/*
 * content.h — minimal containerd Content service client (blob reads).
 *
 * Wave 1 (containerd lane). The container client needs the image's config
 * blob to compute the rootfs chain ID (container_factory.go:133-137: the
 * snapshot parent is identity.ChainID of the image's rootfs diff-ids, which
 * live in the OCI image config JSON). The Content service is NOT covered by
 * the Wave 0-D nanopb codecs, so this module hand-rolls the one RPC it needs:
 *
 *   Read — server-streaming blob read by digest.
 *
 * Method path (containerd api v1.12.0):
 *   /containerd.services.content.v1.Content/Read
 *
 * License: project code (see LICENSE). No GPL.
 */
#ifndef STRIM_CONTENT_H
#define STRIM_CONTENT_H

#include <stddef.h>
#include <stdint.h>

#include "h2c.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Read the entire blob identified by `digest` (e.g. "sha256:..."). Returns
 * 0 + a malloc.d out/out_len, a positive gRPC status, or a negative
 * H2C_ERR_*. The caller frees *out. max_len bounds the blob (fail loud
 * beyond it). */
int content_read_blob(strim_h2c *c, const char *digest, size_t max_len,
                      uint8_t **out, size_t *out_len);

#ifdef __cplusplus
}
#endif

#endif /* STRIM_CONTENT_H */