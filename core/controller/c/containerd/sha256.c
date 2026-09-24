/*
 * sha256.c — SHA-256 digest (compact FIPS 180-4 implementation).
 *
 * Classic compact SHA-256 (public-domain algorithm; independent clean-room
 * implementation). See sha256.h.
 *
 * License: project code (see LICENSE). No GPL.
 */

#include "sha256.h"

#include <stdio.h>
#include <string.h>

#define ROTR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
#define CH(x, y, z) (((x) & (y)) ^ (~(x) & (z)))
#define MAJ(x, y, z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))
#define SIG0(x) (ROTR(x, 2) ^ ROTR(x, 13) ^ ROTR(x, 22))
#define SIG1(x) (ROTR(x, 6) ^ ROTR(x, 11) ^ ROTR(x, 25))
#define SIG2(x) (ROTR(x, 7) ^ ROTR(x, 18) ^ ((x) >> 3))
#define SIG3(x) (ROTR(x, 17) ^ ROTR(x, 19) ^ ((x) >> 10))

static const uint32_t K[64] = {
    0x428a2f98UL, 0x71374491UL, 0xb5c0fbcfUL, 0xe9b5dba5UL,
    0x3956c25bUL, 0x59f111f1UL, 0x923f82a4UL, 0xab1c5ed5UL,
    0xd807aa98UL, 0x12835b01UL, 0x243185beUL, 0x550c7dc3UL,
    0x72be5d74UL, 0x80deb1feUL, 0x9bdc06a7UL, 0xc19bf174UL,
    0xe49b69c1UL, 0xefbe4786UL, 0x0fc19dc6UL, 0x240ca1ccUL,
    0x2de92c6fUL, 0x4a7484aaUL, 0x5cb0a9dcUL, 0x76f988daUL,
    0x983e5152UL, 0xa831c66dUL, 0xb00327c8UL, 0xbf597fc7UL,
    0xc6e00bf3UL, 0xd5a79147UL, 0x06ca6351UL, 0x14292967UL,
    0x27b70a85UL, 0x2e1b2138UL, 0x4d2c6dfcUL, 0x53380d13UL,
    0x650a7354UL, 0x766a0abbUL, 0x81c2c92eUL, 0x92722c85UL,
    0xa2bfe8a1UL, 0xa81a664bUL, 0xc24b8b70UL, 0xc76c51a3UL,
    0xd192e819UL, 0xd6990624UL, 0xf40e3585UL, 0x106aa070UL,
    0x19a4c116UL, 0x1e376c08UL, 0x2748774cUL, 0x34b0bcb5UL,
    0x391c0cb3UL, 0x4ed8aa4aUL, 0x5b9cca4fUL, 0x682e6ff3UL,
    0x748f82eeUL, 0x78a5636fUL, 0x84c87814UL, 0x8cc70208UL,
    0x90befffaUL, 0xa4506cebUL, 0xbef9a3f7UL, 0xc67178f2UL};

static uint32_t be32_load(const uint8_t *p) {
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
         ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static void sha256_block(uint32_t h[8], const uint8_t block[64]) {
  uint32_t w[64];
  uint32_t a, b, c, d, e, f, g, hh;
  int i;

  for (i = 0; i < 16; i++)
    w[i] = be32_load(block + 4 * i);
  for (i = 16; i < 64; i++)
    w[i] = SIG3(w[i - 2]) + w[i - 7] + SIG2(w[i - 15]) + w[i - 16];

  a = h[0]; b = h[1]; c = h[2]; d = h[3];
  e = h[4]; f = h[5]; g = h[6]; hh = h[7];

  for (i = 0; i < 64; i++) {
    uint32_t t1 = hh + SIG1(e) + CH(e, f, g) + K[i] + w[i];
    uint32_t t2 = SIG0(a) + MAJ(a, b, c);
    hh = g; g = f; f = e;
    e = d + t1;
    d = c; c = b; b = a;
    a = t1 + t2;
  }

  h[0] += a; h[1] += b; h[2] += c; h[3] += d;
  h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

void strim_sha256(const uint8_t *data, size_t len, uint8_t out[32]) {
  uint32_t h[8] = {0x6a09e667UL, 0xbb67ae85UL, 0x3c6ef372UL, 0xa54ff53aUL,
                   0x510e527fUL, 0x9b05688cUL, 0x1f83d9abUL, 0x5be0cd19UL};
  uint64_t bitlen = (uint64_t)len * 8;
  size_t full = len / 64;
  size_t rem = len % 64;
  uint8_t pad[128];
  size_t i;

  for (i = 0; i < full; i++)
    sha256_block(h, data + 64 * i);

  memset(pad, 0, sizeof(pad));
  if (rem)
    memcpy(pad, data + 64 * full, rem);
  pad[rem] = 0x80;
  if (rem < 56) {
    for (i = 0; i < 8; i++)
      pad[56 + i] = (uint8_t)(bitlen >> (56 - 8 * i));
    sha256_block(h, pad);
  } else {
    for (i = 0; i < 8; i++)
      pad[120 + i] = (uint8_t)(bitlen >> (56 - 8 * i));
    sha256_block(h, pad);
    sha256_block(h, pad + 64);
  }

  for (i = 0; i < 8; i++) {
    out[4 * i] = (uint8_t)(h[i] >> 24);
    out[4 * i + 1] = (uint8_t)(h[i] >> 16);
    out[4 * i + 2] = (uint8_t)(h[i] >> 8);
    out[4 * i + 3] = (uint8_t)h[i];
  }
}

char *strim_sha256_format(const uint8_t digest[32], char buf[72]) {
  static const char hex[] = "0123456789abcdef";
  size_t i;
  buf[0] = 's';
  buf[1] = 'h';
  buf[2] = 'a';
  buf[3] = '2';
  buf[4] = '5';
  buf[5] = '6';
  buf[6] = ':';
  for (i = 0; i < 32; i++) {
    buf[7 + 2 * i] = hex[digest[i] >> 4];
    buf[8 + 2 * i] = hex[digest[i] & 0xf];
  }
  buf[71] = '\0';
  return buf;
}