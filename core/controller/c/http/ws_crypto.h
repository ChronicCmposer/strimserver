/*
 * ws_crypto.h — SHA-1 + base64 for the RFC 6455 WebSocket handshake.
 *
 * The handshake accept value is base64(SHA-1(Sec-WebSocket-Key + GUID));
 * libmicrohttpd (no TLS/auth build) and wslay (framing only) do not provide
 * either primitive, so the HTTP lane carries these two small primitives.
 * They are the only crypto in the HTTP lane: no TLS, no external deps.
 *
 * License: project code (see LICENSE). No GPL.
 */
#ifndef STRIM_WS_CRYPTO_H
#define STRIM_WS_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* RFC 3174 SHA-1. Writes the 20-byte digest of data[0..len). */
void strim_sha1(const uint8_t *data, size_t len, uint8_t digest[20]);

/* RFC 4648 base64. Encodes src[0..src_len) into out (NUL-terminated).
 * Returns the encoded length (excluding the NUL), or 0 when out is too
 * small (needs 4*ceil(src_len/3)+1 bytes). */
size_t strim_base64_encode(const uint8_t *src, size_t src_len, char *out,
                           size_t out_cap);

/* RFC 4648 base64. Decodes in[0..in_len) (in_len % 4 == 0) into out;
 * *out_len receives the decoded length. Returns 0 on success, -1 on bad
 * input (invalid alphabet, bad padding, or out too small). */
int strim_base64_decode(const char *in, size_t in_len, uint8_t *out,
                        size_t out_cap, size_t *out_len);

#ifdef __cplusplus
}
#endif

#endif /* STRIM_WS_CRYPTO_H */