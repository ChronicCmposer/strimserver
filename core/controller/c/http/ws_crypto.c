/*
 * ws_crypto.c — SHA-1 (RFC 3174) + base64 (RFC 4648) for the RFC 6455
 * WebSocket handshake. Two small self-contained primitives; verified against
 * the RFC test vectors in http_server_test.c.
 *
 * License: project code (see LICENSE). No GPL.
 */

#include "ws_crypto.h"

#include <string.h>

/* =========================================================================
 * SHA-1
 * ========================================================================= */

static uint32_t rol32(uint32_t v, unsigned int n) {
  return (v << n) | (v >> (32u - n));
}

static uint32_t sha1_f(unsigned int t, uint32_t b, uint32_t c, uint32_t d) {
  if (t < 20)
    return (b & c) | ((~b) & d);
  if (t < 40)
    return b ^ c ^ d;
  if (t < 60)
    return (b & c) | (b & d) | (c & d);
  return b ^ c ^ d;
}

static uint32_t sha1_k(unsigned int t) {
  if (t < 20)
    return 0x5a827999u;
  if (t < 40)
    return 0x6ed9eba1u;
  if (t < 60)
    return 0x8f1bbcdcu;
  return 0xca62c1d6u;
}

/* One 64-byte block of the message schedule + compression. */
static void sha1_block(uint32_t h[5], const uint8_t block[64]) {
  uint32_t w[80];
  unsigned int t;

  for (t = 0; t < 16; t++)
  {
    w[t] = ((uint32_t) block[t * 4] << 24) | ((uint32_t) block[t * 4 + 1] << 16)
           | ((uint32_t) block[t * 4 + 2] << 8) | (uint32_t) block[t * 4 + 3];
  }
  for (t = 16; t < 80; t++)
  {
    w[t] = rol32(w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16], 1);
  }

  uint32_t a = h[0];
  uint32_t b = h[1];
  uint32_t c = h[2];
  uint32_t d = h[3];
  uint32_t e = h[4];
  for (t = 0; t < 80; t++)
  {
    uint32_t tmp = rol32(a, 5) + sha1_f(t, b, c, d) + e + w[t] + sha1_k(t);
    e = d;
    d = c;
    c = rol32(b, 30);
    b = a;
    a = tmp;
  }

  h[0] += a;
  h[1] += b;
  h[2] += c;
  h[3] += d;
  h[4] += e;
}

void strim_sha1(const uint8_t *data, size_t len, uint8_t digest[20]) {
  uint32_t h[5] = { 0x67452301u, 0xefcdab89u, 0x98badcfeu,
                    0x10325476u, 0xc3d2e1f0u };
  uint8_t block[64];
  size_t off = 0;
  size_t rem;
  uint64_t bits;
  int i;

  while (len - off >= 64)
  {
    sha1_block(h, data + off);
    off += 64;
  }

  /* Final block: remainder, 0x80 pad, 64-bit bit length (big-endian). */
  rem = len - off;
  memset(block, 0, sizeof(block));
  memcpy(block, data + off, rem);
  block[rem] = 0x80u;
  bits = (uint64_t) len * 8u;
  if (rem >= 56)
  {
    sha1_block(h, block); /* length field does not fit; pad another block */
    memset(block, 0, sizeof(block));
  }
  for (i = 0; i < 8; i++)
    block[63 - i] = (uint8_t) (bits >> (8u * (unsigned int) i));
  sha1_block(h, block);

  for (i = 0; i < 5; i++)
  {
    digest[i * 4] = (uint8_t) (h[i] >> 24);
    digest[i * 4 + 1] = (uint8_t) (h[i] >> 16);
    digest[i * 4 + 2] = (uint8_t) (h[i] >> 8);
    digest[i * 4 + 3] = (uint8_t) h[i];
  }
}

/* =========================================================================
 * Base64
 * ========================================================================= */

static const char b64_alphabet[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

size_t strim_base64_encode(const uint8_t *src, size_t src_len, char *out,
                           size_t out_cap) {
  size_t need;
  size_t i;
  size_t o;

  if (src == NULL || out == NULL)
    return 0;
  need = 4u * ((src_len + 2u) / 3u) + 1u;
  if (out_cap < need)
    return 0;

  o = 0;
  i = 0;
  while (i + 3u <= src_len)
  {
    uint32_t v = ((uint32_t) src[i] << 16) | ((uint32_t) src[i + 1] << 8)
                 | (uint32_t) src[i + 2];
    out[o++] = b64_alphabet[(v >> 18) & 0x3fu];
    out[o++] = b64_alphabet[(v >> 12) & 0x3fu];
    out[o++] = b64_alphabet[(v >> 6) & 0x3fu];
    out[o++] = b64_alphabet[v & 0x3fu];
    i += 3;
  }

  {
    size_t rem = src_len - i;
    if (rem == 1)
    {
      uint32_t v = (uint32_t) src[i] << 16;
      out[o++] = b64_alphabet[(v >> 18) & 0x3fu];
      out[o++] = b64_alphabet[(v >> 12) & 0x3fu];
      out[o++] = '=';
      out[o++] = '=';
    }
    else if (rem == 2)
    {
      uint32_t v = ((uint32_t) src[i] << 16) | ((uint32_t) src[i + 1] << 8);
      out[o++] = b64_alphabet[(v >> 18) & 0x3fu];
      out[o++] = b64_alphabet[(v >> 12) & 0x3fu];
      out[o++] = b64_alphabet[(v >> 6) & 0x3fu];
      out[o++] = '=';
    }
  }

  out[o] = '\0';
  return o;
}

static int b64_value(char c) {
  if (c >= 'A' && c <= 'Z')
    return c - 'A';
  if (c >= 'a' && c <= 'z')
    return c - 'a' + 26;
  if (c >= '0' && c <= '9')
    return c - '0' + 52;
  if (c == '+')
    return 62;
  if (c == '/')
    return 63;
  return -1;
}

int strim_base64_decode(const char *in, size_t in_len, uint8_t *out,
                        size_t out_cap, size_t *out_len) {
  size_t i;
  size_t o;

  if (in == NULL || out == NULL || out_len == NULL)
    return -1;
  if (in_len == 0 || in_len % 4u != 0)
    return -1;

  o = 0;
  for (i = 0; i < in_len; i += 4)
  {
    int v0 = b64_value(in[i]);
    int v1 = b64_value(in[i + 1]);
    int v2 = (in[i + 2] == '=') ? 0 : b64_value(in[i + 2]);
    int v3 = (in[i + 3] == '=') ? 0 : b64_value(in[i + 3]);
    if (v0 < 0 || v1 < 0 || v2 < 0 || v3 < 0)
      return -1;
    if (in[i + 2] == '=' && in[i + 3] != '=')
      return -1; /* '=' only allowed in the last two positions */

    if (o + 1u > out_cap)
      return -1;
    out[o++] = (uint8_t) ((v0 << 2) | (v1 >> 4));
    if (in[i + 2] != '=')
    {
      if (o + 1u > out_cap)
        return -1;
      out[o++] = (uint8_t) ((v1 << 4) | (v2 >> 2));
    }
    if (in[i + 3] != '=')
    {
      if (o + 1u > out_cap)
        return -1;
      out[o++] = (uint8_t) ((v2 << 6) | v3);
    }
  }

  *out_len = o;
  return 0;
}