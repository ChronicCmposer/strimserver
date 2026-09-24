/*
 * sha256.h — SHA-256 digest (compact, public-domain style implementation).
 *
 * Wave 1 (containerd lane). The container client computes the image rootfs
 * chain ID (identity.ChainID, opencontainers/image-spec/identity) which is a
 * SHA-256 over the diff-id chain. The static musl build has no libcrypto, so
 * this module provides the digest. The implementation is the classic compact
 * FIPS 180-4 SHA-256.
 *
 * License: project code (see LICENSE). No GPL.
 */
#ifndef STRIM_SHA256_H
#define STRIM_SHA256_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* One-shot: compute sha256(data) into out[32]. */
void strim_sha256(const uint8_t *data, size_t len, uint8_t out[32]);

/* Format a digest as "sha256:<64 lowercase hex>" into buf (must hold at
 * least 72 bytes: 7 + 64 + NUL). Returns buf. */
char *strim_sha256_format(const uint8_t digest[32], char buf[72]);

#ifdef __cplusplus
}
#endif

#endif /* STRIM_SHA256_H */