/*
 * h2c.c — hand-rolled HTTP/2 prior-knowledge + gRPC framing layer.
 *
 * Wave 1 (containerd lane). See h2c.h for the API and protocol envelope.
 *
 * Structure (read top to bottom):
 *   1. Constants and I/O utilities (blocking writes, monotonic time).
 *   2. HPACK: Huffman decode trie, integer coding, static table, dynamic
 *      table (4096 bytes, eviction), string coding, block decoder, block
 *      encoder.
 *   3. HTTP/2 framing: frame writer, incremental frame reader.
 *   4. Connection + stream state, flow control (message-granularity credit),
 *      the server-stream message queue.
 *   5. Request building (HPACK request headers + gRPC DATA framing).
 *   6. Frame dispatch (SETTINGS/PING/WINDOW_UPDATE/DATA/HEADERS/CONTINUATION/
 *      RST_STREAM/GOAWAY), response processing, the gRPC message
 *      reassembler.
 *   7. Public API.
 *
 * Philosophy (code-philosophy, 5 laws) as applied:
 *   - Early exit: every API function validates its arguments first.
 *   - Parse don't validate: socket bytes are parsed into typed frame /
 *     header / message state at the boundary; internal code touches trusted
 *     state only.
 *   - Atomic predictability: helpers are pure (buffer in, bytes out, counted
 *     returns); all mutable state is the explicitly owned per-connection /
 *     per-stream struct.
 *   - Fail fast: any protocol violation (bad HPACK, bad frame, window
 *     overflow, unknown stream) aborts the connection or stream with a
 *     descriptive H2C_ERR_* code — never a silent continuation.
 *   - Intentional naming: hpack_* / frame_* / stream_* / conn_* prefixes
 *     read like English.
 *
 * License: project code (see LICENSE). No GPL.
 */

#include "h2c.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

/* =========================================================================
 * Constants
 * ========================================================================= */

#define H2C_MAX_STREAMS     8
#define H2C_HDR_BLOCK_MAX   (64 * 1024)
#define H2C_UNARY_SLICE_MS  50
#define H2C_FRAME_BUDGET    128
#define H2C_HUFF_NODES      1024
#define H2C_MAX_FIELDS      32
#define H2C_REQ_HDR_BLOCK   1024
#define H2C_DATA_BUF        (16384 + 5)
#define H2C_DYN_MAX_ENTRIES 128      /* 4096 / minimum entry size 32       */
#define H2C_QUEUE_MAX_BYTES (4 * 1024 * 1024) /* safety cap; flow control
                                                 stalls the server far below */
#define H2C_DEFAULT_UNARY_TIMEOUT_MS 30000
/* How long h2c_stream_open polls for an immediate completion before handing
 * the stream back as open. A server-streaming RPC (Events/Subscribe,
 * Content/Read) is NOT required to send its response headers promptly:
 * grpc-go (containerd) sends them lazily with the first message, so an idle
 * daemon legitimately sends nothing here. The grace window exists only to
 * catch immediate trailers-only errors and connection death synchronously;
 * the per-read deadline lives in h2c_stream_next. */
#define H2C_STREAM_OPEN_GRACE_MS 250

#define H2_INIT_WINDOW 65535

/* Frame types. */
#define H2_DATA          0
#define H2_HEADERS       1
#define H2_PRIORITY      2
#define H2_RST_STREAM    3
#define H2_SETTINGS      4
#define H2_PUSH_PROMISE  5
#define H2_PING          6
#define H2_GOAWAY        7
#define H2_WINDOW_UPDATE 8
#define H2_CONTINUATION  9

/* Frame flags. */
#define H2_FLAG_ACK         0x1
#define H2_FLAG_END_STREAM  0x1
#define H2_FLAG_END_HEADERS 0x4
#define H2_FLAG_PADDED      0x8
#define H2_FLAG_PRIORITY    0x20

/* SETTINGS ids. */
#define H2_SETTINGS_HEADER_TABLE_SIZE      0x1
#define H2_SETTINGS_ENABLE_PUSH            0x2
#define H2_SETTINGS_MAX_CONCURRENT_STREAMS 0x3
#define H2_SETTINGS_INITIAL_WINDOW_SIZE    0x4
#define H2_SETTINGS_MAX_FRAME_SIZE         0x5
#define H2_SETTINGS_MAX_HEADER_LIST_SIZE   0x6

/* HTTP/2 error codes. */
#define H2_ERR_NO_ERROR       0
#define H2_ERR_PROTOCOL       1
#define H2_ERR_INTERNAL       2
#define H2_ERR_FLOW_CONTROL   3
#define H2_ERR_STREAM_CLOSED  5
#define H2_ERR_FRAME_SIZE     6
#define H2_ERR_REFUSED_STREAM 7
#define H2_ERR_CANCEL         8
#define H2_ERR_COMPRESSION    9

/* =========================================================================
 * I/O utilities
 * ========================================================================= */

static int write_all(int fd, const void *data, size_t len) {
  const uint8_t *p = (const uint8_t *)data;
  while (len > 0) {
    ssize_t n = send(fd, p, len, MSG_NOSIGNAL);
    if (n < 0) {
      if (errno == EINTR)
        continue;
      return -1;
    }
    p += n;
    len -= (size_t)n;
  }
  return 0;
}

static int64_t mono_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000 + (int64_t)(ts.tv_nsec / 1000000);
}

static int64_t time_left_ms(int64_t deadline) {
  int64_t left = deadline - mono_ms();
  return left > 0 ? left : 0;
}

/* =========================================================================
 * HPACK: Huffman decode trie (RFC 7541 Appendix B; entry 256 is EOS)
 * ========================================================================= */

struct huff_code {
  uint32_t code;
  uint8_t bits;
};

static const struct huff_code HUFF_TABLE[257] = {
#include "h2c_huff.inc"
};

struct huff_node {
  int16_t child0;
  int16_t child1;
  int16_t sym; /* -1 internal, 0..255 symbol, 256 EOS */
};

static struct huff_node g_huff_nodes[H2C_HUFF_NODES];
static int g_huff_nnodes;
static int g_huff_built;

/* Build the decode trie once. The controller is single-threaded per
 * connection, so a plain flag is the correct guard. */
static void huff_build(void) {
  int i;
  if (g_huff_built)
    return;
  g_huff_nnodes = 1;
  g_huff_nodes[0].child0 = -1;
  g_huff_nodes[0].child1 = -1;
  g_huff_nodes[0].sym = -1;
  for (i = 0; i < 257; i++) {
    uint32_t code = HUFF_TABLE[i].code;
    int bits = HUFF_TABLE[i].bits;
    int node = 0;
    int b;
    for (b = bits - 1; b >= 0; b--) {
      int bit = (int)((code >> b) & 1);
      int next = (bit == 0) ? g_huff_nodes[node].child0
                            : g_huff_nodes[node].child1;
      if (next < 0) {
        if (g_huff_nnodes >= H2C_HUFF_NODES) {
          g_huff_built = 2;
          return;
        }
        next = g_huff_nnodes++;
        g_huff_nodes[next].child0 = -1;
        g_huff_nodes[next].child1 = -1;
        g_huff_nodes[next].sym = -1;
        if (bit == 0)
          g_huff_nodes[node].child0 = (int16_t)next;
        else
          g_huff_nodes[node].child1 = (int16_t)next;
      }
      node = next;
    }
    g_huff_nodes[node].sym = (int16_t)i;
  }
  g_huff_built = 1;
}

/* Decode a Huffman-coded string. Returns 0 on success, -1 on a
 * COMPRESSION_ERROR (invalid code, EOS in stream, bad padding). */
static int huff_decode(const uint8_t *in, size_t in_len, uint8_t *out,
                       size_t out_cap, size_t *out_len) {
  int node = 0;
  size_t emitted = 0;
  size_t i;
  int pad_ones = 1; /* all bits since the last symbol are 1 (EOS padding) */
  int depth = 0;

  huff_build();
  if (g_huff_built != 1)
    return -1;

  for (i = 0; i < in_len; i++) {
    int b;
    for (b = 7; b >= 0; b--) {
      int bit = (in[i] >> b) & 1;
      int next = (bit == 0) ? g_huff_nodes[node].child0
                            : g_huff_nodes[node].child1;
      if (next < 0)
        return -1; /* invalid code */
      if (bit == 0)
        pad_ones = 0;
      depth++;
      node = next;
      if (g_huff_nodes[node].sym >= 0) {
        int sym = g_huff_nodes[node].sym;
        if (sym == 256)
          return -1; /* EOS in stream */
        if (emitted >= out_cap)
          return -1;
        out[emitted++] = (uint8_t)sym;
        node = 0;
        pad_ones = 1;
        depth = 0;
      }
    }
  }
  if (node != 0) {
    /* Trailing bits must be a prefix of EOS (all ones) of at most 7 bits. */
    if (!pad_ones || depth > 7)
      return -1;
  }
  *out_len = emitted;
  return 0;
}

/* =========================================================================
 * HPACK: integer coding (RFC 7541 §5.1)
 * ========================================================================= */

static int hpack_read_int(const uint8_t *in, size_t in_len, int prefix,
                          uint32_t *out) {
  size_t off = 0;
  uint32_t mask = (uint32_t)((1u << prefix) - 1u);
  uint64_t value;
  int shift = 0;

  if (in_len < 1)
    return -1;
  value = in[0] & mask;
  if (value < mask) {
    *out = (uint32_t)value;
    return 1;
  }
  off = 1;
  for (;;) {
    uint8_t b;
    if (off >= in_len)
      return -1;
    b = in[off++];
    value += (uint64_t)(b & 0x7f) << shift;
    if ((b & 0x80) == 0)
      break;
    shift += 7;
    if (shift > 28)
      return -1;
  }
  if (value > 0x7fffffffU)
    return -1;
  *out = (uint32_t)value;
  return (int)off;
}

static size_t hpack_write_int_ex(uint8_t *out, size_t cap, uint32_t value,
                                 int prefix, uint8_t pattern) {
  uint32_t mask = (uint32_t)((1u << prefix) - 1u);
  size_t n = 0;
  if (value < mask) {
    if (n >= cap)
      return 0;
    out[n++] = (uint8_t)(pattern | value);
    return n;
  }
  if (n >= cap)
    return 0;
  out[n++] = (uint8_t)(pattern | mask);
  value -= mask;
  while (value >= 0x80) {
    if (n >= cap)
      return 0;
    out[n++] = (uint8_t)((value & 0x7f) | 0x80);
    value >>= 7;
  }
  if (n >= cap)
    return 0;
  out[n++] = (uint8_t)value;
  return n;
}

static size_t hpack_write_int(uint8_t *out, size_t cap, uint32_t value,
                              int prefix) {
  return hpack_write_int_ex(out, cap, value, prefix, 0);
}

/* =========================================================================
 * HPACK: static table (RFC 7541 Appendix A, 61 entries)
 * ========================================================================= */

struct hpack_static {
  const char *name;
  const char *value;
};

static const struct hpack_static HPACK_STATIC[61] = {
    {":authority", ""},
    {":method", "GET"},
    {":method", "POST"},
    {":path", "/"},
    {":path", "/index.html"},
    {":scheme", "http"},
    {":scheme", "https"},
    {":status", "200"},
    {":status", "204"},
    {":status", "206"},
    {":status", "304"},
    {":status", "400"},
    {":status", "404"},
    {":status", "500"},
    {"accept-charset", ""},
    {"accept-encoding", "gzip, deflate"},
    {"accept-language", ""},
    {"accept-ranges", ""},
    {"accept", ""},
    {"access-control-allow-origin", ""},
    {"age", ""},
    {"allow", ""},
    {"authorization", ""},
    {"cache-control", ""},
    {"content-disposition", ""},
    {"content-encoding", ""},
    {"content-language", ""},
    {"content-length", ""},
    {"content-location", ""},
    {"content-range", ""},
    {"content-type", ""},
    {"cookie", ""},
    {"date", ""},
    {"etag", ""},
    {"expect", ""},
    {"expires", ""},
    {"from", ""},
    {"host", ""},
    {"if-match", ""},
    {"if-modified-since", ""},
    {"if-none-match", ""},
    {"if-range", ""},
    {"if-unmodified-since", ""},
    {"last-modified", ""},
    {"link", ""},
    {"location", ""},
    {"max-forwards", ""},
    {"proxy-authenticate", ""},
    {"proxy-authorization", ""},
    {"range", ""},
    {"referer", ""},
    {"refresh", ""},
    {"retry-after", ""},
    {"server", ""},
    {"set-cookie", ""},
    {"strict-transport-security", ""},
    {"transfer-encoding", ""},
    {"user-agent", ""},
    {"vary", ""},
    {"via", ""},
    {"www-authenticate", ""},
};

static int static_find_pair(const char *name, size_t name_len,
                            const char *value, size_t value_len) {
  int i;
  for (i = 0; i < 61; i++) {
    if (strlen(HPACK_STATIC[i].name) == name_len &&
        memcmp(HPACK_STATIC[i].name, name, name_len) == 0 &&
        strlen(HPACK_STATIC[i].value) == value_len &&
        memcmp(HPACK_STATIC[i].value, value, value_len) == 0)
      return i + 1;
  }
  return 0;
}

static int static_find_name(const char *name, size_t name_len) {
  int i;
  for (i = 0; i < 61; i++) {
    if (strlen(HPACK_STATIC[i].name) == name_len &&
        memcmp(HPACK_STATIC[i].name, name, name_len) == 0)
      return i + 1;
  }
  return 0;
}

/* =========================================================================
 * HPACK: dynamic table (RFC 7541 §4, 4096 bytes, eviction)
 * ========================================================================= */

struct hpack_dyn_entry {
  uint8_t *name;
  size_t name_len;
  uint8_t *value;
  size_t value_len;
  size_t size;
};

struct hpack_dyn {
  struct hpack_dyn_entry entries[H2C_DYN_MAX_ENTRIES];
  size_t count;
  size_t size;
  size_t max_size;
};

static void dyn_reset(struct hpack_dyn *dyn) {
  size_t i;
  for (i = 0; i < dyn->count; i++) {
    free(dyn->entries[i].name);
    free(dyn->entries[i].value);
  }
  dyn->count = 0;
  dyn->size = 0;
  dyn->max_size = 4096;
}

static struct hpack_dyn_entry *dyn_get(struct hpack_dyn *dyn, size_t index) {
  if (index == 0 || index > dyn->count)
    return NULL;
  return &dyn->entries[dyn->count - index];
}

static void dyn_evict_one(struct hpack_dyn *dyn) {
  if (dyn->count == 0)
    return;
  dyn->size -= dyn->entries[0].size;
  free(dyn->entries[0].name);
  free(dyn->entries[0].value);
  memmove(&dyn->entries[0], &dyn->entries[1],
          (dyn->count - 1) * sizeof(dyn->entries[0]));
  dyn->count--;
}

static void dyn_set_max(struct hpack_dyn *dyn, size_t max_size) {
  dyn->max_size = max_size;
  while (dyn->size > dyn->max_size && dyn->count > 0)
    dyn_evict_one(dyn);
}

static void dyn_add(struct hpack_dyn *dyn, const uint8_t *name, size_t name_len,
                    const uint8_t *value, size_t value_len) {
  size_t entry_size = name_len + value_len + 32;
  uint8_t *name_copy;
  uint8_t *value_copy;

  if (entry_size > dyn->max_size)
    return;
  while (dyn->size + entry_size > dyn->max_size || dyn->count >= H2C_DYN_MAX_ENTRIES) {
    if (dyn->count == 0)
      return;
    dyn_evict_one(dyn);
  }
  name_copy = (uint8_t *)malloc(name_len ? name_len : 1);
  value_copy = (uint8_t *)malloc(value_len ? value_len : 1);
  if (name_copy == NULL || value_copy == NULL) {
    free(name_copy);
    free(value_copy);
    return;
  }
  if (name_len)
    memcpy(name_copy, name, name_len);
  if (value_len)
    memcpy(value_copy, value, value_len);
  dyn->entries[dyn->count].name = name_copy;
  dyn->entries[dyn->count].name_len = name_len;
  dyn->entries[dyn->count].value = value_copy;
  dyn->entries[dyn->count].value_len = value_len;
  dyn->entries[dyn->count].size = entry_size;
  dyn->count++;
  dyn->size += entry_size;
}

static size_t dyn_find_pair(struct hpack_dyn *dyn, const uint8_t *name,
                            size_t name_len, const uint8_t *value,
                            size_t value_len) {
  size_t i;
  for (i = 1; i <= dyn->count; i++) {
    struct hpack_dyn_entry *e = dyn_get(dyn, i);
    if (e->name_len == name_len && memcmp(e->name, name, name_len) == 0 &&
        e->value_len == value_len && memcmp(e->value, value, value_len) == 0)
      return i;
  }
  return 0;
}

static size_t dyn_find_name(struct hpack_dyn *dyn, const uint8_t *name,
                            size_t name_len) {
  size_t i;
  for (i = 1; i <= dyn->count; i++) {
    struct hpack_dyn_entry *e = dyn_get(dyn, i);
    if (e->name_len == name_len && memcmp(e->name, name, name_len) == 0)
      return i;
  }
  return 0;
}

/* =========================================================================
 * HPACK: string coding (RFC 7541 §5.2)
 * ========================================================================= */

static int hpack_read_string(const uint8_t *in, size_t in_len, size_t off,
                             uint8_t **out, size_t *out_len) {
  uint32_t str_len;
  int len_bytes;
  int huffman;
  uint8_t *buf;

  if (off >= in_len)
    return -1;
  huffman = (in[off] & 0x80) != 0;
  len_bytes = hpack_read_int(in + off, in_len - off, 7, &str_len);
  if (len_bytes < 0)
    return -1;
  off += (size_t)len_bytes;
  if (str_len > in_len - off)
    return -1;
  if (huffman) {
    buf = (uint8_t *)malloc(str_len * 8 + 1);
    if (buf == NULL)
      return -1;
    if (huff_decode(in + off, str_len, buf, str_len * 8 + 1, out_len) < 0) {
      free(buf);
      return -1;
    }
  } else {
    buf = (uint8_t *)malloc(str_len ? str_len : 1);
    if (buf == NULL)
      return -1;
    if (str_len)
      memcpy(buf, in + off, str_len);
    *out_len = str_len;
  }
  *out = buf;
  return len_bytes + (int)str_len;
}

static size_t hpack_write_string(uint8_t *out, size_t cap, const uint8_t *s,
                                 size_t len) {
  size_t n = hpack_write_int(out, cap, (uint32_t)len, 7);
  if (n == 0 || n + len > cap)
    return 0;
  if (len)
    memcpy(out + n, s, len);
  return n + len;
}

/* =========================================================================
 * HPACK: block decoder
 * ========================================================================= */

struct hpack_field {
  uint8_t *name;
  size_t name_len;
  uint8_t *value;
  size_t value_len;
};

static void hpack_free_fields(struct hpack_field *fields, int n) {
  int i;
  for (i = 0; i < n; i++) {
    free(fields[i].name);
    free(fields[i].value);
  }
}

static int field_resolve_name(struct hpack_field *f, struct hpack_dyn *dyn,
                              uint32_t index) {
  if (index == 0)
    return 0;
  if (index <= 61) {
    const char *sname = HPACK_STATIC[index - 1].name;
    f->name = (uint8_t *)strdup(sname);
    f->name_len = strlen(sname);
  } else {
    struct hpack_dyn_entry *de = dyn_get(dyn, index - 61);
    if (de == NULL)
      return -1;
    f->name = (uint8_t *)malloc(de->name_len ? de->name_len : 1);
    if (f->name == NULL)
      return -1;
    memcpy(f->name, de->name, de->name_len);
    f->name_len = de->name_len;
  }
  return (f->name == NULL) ? -1 : 0;
}

static int hpack_decode_block(struct hpack_dyn *dyn, const uint8_t *in,
                              size_t in_len, struct hpack_field *fields,
                              int max_fields, int *n_fields) {
  size_t off = 0;
  int n = 0;

  while (off < in_len) {
    uint8_t b = in[off];
    uint32_t index;
    int consumed;
    struct hpack_field *f;

    if (n >= max_fields)
      return -1;
    f = &fields[n];

    if ((b & 0x80) != 0) {
      consumed = hpack_read_int(in + off, in_len - off, 7, &index);
      if (consumed < 0)
        return -1;
      off += (size_t)consumed;
      if (index >= 1 && index <= 61) {
        const struct hpack_static *s = &HPACK_STATIC[index - 1];
        f->name = (uint8_t *)strdup(s->name);
        f->value = (uint8_t *)strdup(s->value);
        f->name_len = strlen(s->name);
        f->value_len = strlen(s->value);
      } else {
        struct hpack_dyn_entry *de = dyn_get(dyn, index - 61);
        if (de == NULL)
          return -1;
        f->name = (uint8_t *)malloc(de->name_len ? de->name_len : 1);
        f->value = (uint8_t *)malloc(de->value_len ? de->value_len : 1);
        if (f->name == NULL || f->value == NULL)
          return -1;
        memcpy(f->name, de->name, de->name_len);
        memcpy(f->value, de->value, de->value_len);
        f->name_len = de->name_len;
        f->value_len = de->value_len;
      }
      n++;
      continue;
    }

    if ((b & 0xc0) == 0x40) {
      consumed = hpack_read_int(in + off, in_len - off, 6, &index);
      if (consumed < 0)
        return -1;
      off += (size_t)consumed;
      if (index == 0) {
        consumed = hpack_read_string(in, in_len, off, &f->name, &f->name_len);
        if (consumed < 0)
          return -1;
        off += (size_t)consumed;
      } else if (field_resolve_name(f, dyn, index) < 0) {
        return -1;
      }
      consumed = hpack_read_string(in, in_len, off, &f->value, &f->value_len);
      if (consumed < 0)
        return -1;
      off += (size_t)consumed;
      dyn_add(dyn, f->name, f->name_len, f->value, f->value_len);
      n++;
      continue;
    }

    if ((b & 0xe0) == 0x20) {
      uint32_t new_size;
      consumed = hpack_read_int(in + off, in_len - off, 5, &new_size);
      if (consumed < 0)
        return -1;
      off += (size_t)consumed;
      if (new_size > dyn->max_size)
        return -1;
      dyn_set_max(dyn, new_size);
      continue;
    }

    if ((b & 0xf0) == 0x00) {
      consumed = hpack_read_int(in + off, in_len - off, 4, &index);
      if (consumed < 0)
        return -1;
      off += (size_t)consumed;
      if (index == 0) {
        consumed = hpack_read_string(in, in_len, off, &f->name, &f->name_len);
        if (consumed < 0)
          return -1;
        off += (size_t)consumed;
      } else if (field_resolve_name(f, dyn, index) < 0) {
        return -1;
      }
      consumed = hpack_read_string(in, in_len, off, &f->value, &f->value_len);
      if (consumed < 0)
        return -1;
      off += (size_t)consumed;
      n++;
      continue;
    }

    if ((b & 0xf0) == 0x10) {
      consumed = hpack_read_int(in + off, in_len - off, 4, &index);
      if (consumed < 0)
        return -1;
      off += (size_t)consumed;
      if (index == 0) {
        consumed = hpack_read_string(in, in_len, off, &f->name, &f->name_len);
        if (consumed < 0)
          return -1;
        off += (size_t)consumed;
      } else if (field_resolve_name(f, dyn, index) < 0) {
        return -1;
      }
      consumed = hpack_read_string(in, in_len, off, &f->value, &f->value_len);
      if (consumed < 0)
        return -1;
      off += (size_t)consumed;
      n++;
      continue;
    }

    return -1; /* reserved pattern (unreachable) */
  }
  *n_fields = n;
  return 0;
}

/* =========================================================================
 * HPACK: request header encoder
 * ========================================================================= */

static size_t hpack_encode_field(struct hpack_dyn *dyn, uint8_t *out,
                                 size_t cap, const char *name,
                                 const char *value) {
  size_t name_len = strlen(name);
  size_t value_len = strlen(value);
  int pair_idx = static_find_pair(name, name_len, value, value_len);
  int name_idx;
  size_t n = 0;

  if (pair_idx == 0) {
    size_t d = dyn_find_pair(dyn, (const uint8_t *)name, name_len,
                             (const uint8_t *)value, value_len);
    if (d != 0)
      pair_idx = 61 + (int)d;
  }
  if (pair_idx != 0) {
    n = hpack_write_int_ex(out, cap, (uint32_t)pair_idx, 7, 0x80);
    return n;
  }

  name_idx = static_find_name(name, name_len);
  if (name_idx == 0) {
    size_t d = dyn_find_name(dyn, (const uint8_t *)name, name_len);
    if (d != 0)
      name_idx = 61 + (int)d;
  }

  if (name_idx != 0) {
    /* Literal with incremental indexing, indexed name. */
    n = hpack_write_int_ex(out, cap, (uint32_t)name_idx, 6, 0x40);
    if (n == 0)
      return 0;
    n += hpack_write_string(out + n, cap - n, (const uint8_t *)value, value_len);
    if (n == 0)
      return 0;
  } else {
    n = hpack_write_int_ex(out, cap, 0, 6, 0x40);
    if (n == 0)
      return 0;
    n += hpack_write_string(out + n, cap - n, (const uint8_t *)name, name_len);
    if (n == 0)
      return 0;
    n += hpack_write_string(out + n, cap - n, (const uint8_t *)value, value_len);
    if (n == 0)
      return 0;
  }
  dyn_add(dyn, (const uint8_t *)name, name_len, (const uint8_t *)value,
          value_len);
  return n;
}

/* =========================================================================
 * HTTP/2: frame writing and the incremental frame reader
 * ========================================================================= */

static int frame_write(int fd, uint8_t type, uint8_t flags, uint32_t sid,
                       const void *payload, size_t len) {
  uint8_t hdr[9];
  if (len > 0xffffff)
    return -1;
  hdr[0] = (uint8_t)(len >> 16);
  hdr[1] = (uint8_t)(len >> 8);
  hdr[2] = (uint8_t)len;
  hdr[3] = type;
  hdr[4] = flags;
  hdr[5] = (uint8_t)(sid >> 24);
  hdr[6] = (uint8_t)(sid >> 16);
  hdr[7] = (uint8_t)(sid >> 8);
  hdr[8] = (uint8_t)sid;
  if (write_all(fd, hdr, sizeof(hdr)) < 0)
    return -1;
  if (len > 0 && write_all(fd, payload, len) < 0)
    return -1;
  return 0;
}

static int frame_write_settings(int fd, uint8_t flags, const void *payload,
                                size_t len) {
  return frame_write(fd, H2_SETTINGS, flags, 0, payload, len);
}

static int frame_write_window_update(int fd, uint32_t sid, uint32_t inc) {
  uint8_t p[4];
  p[0] = (uint8_t)(inc >> 24);
  p[1] = (uint8_t)(inc >> 16);
  p[2] = (uint8_t)(inc >> 8);
  p[3] = (uint8_t)inc;
  return frame_write(fd, H2_WINDOW_UPDATE, 0, sid, p, 4);
}

static int frame_write_ping_ack(int fd, const uint8_t opaque[8]) {
  return frame_write(fd, H2_PING, H2_FLAG_ACK, 0, opaque, 8);
}

static int frame_write_rst(int fd, uint32_t sid, uint32_t code) {
  uint8_t p[4];
  p[0] = (uint8_t)(code >> 24);
  p[1] = (uint8_t)(code >> 16);
  p[2] = (uint8_t)(code >> 8);
  p[3] = (uint8_t)code;
  return frame_write(fd, H2_RST_STREAM, 0, sid, p, 4);
}

struct frame_reader {
  uint8_t hdr[9];
  int hdr_fill;
  uint8_t *payload;
  size_t payload_cap;
  size_t payload_len;
  size_t payload_fill;
  uint8_t type;
  uint8_t flags;
  uint32_t sid;
};

static void frame_reader_reset(struct frame_reader *r) {
  r->hdr_fill = 0;
  r->payload_fill = 0;
}

/* Returns 1 = complete frame ready, 0 = need more data, -1 = socket error. */
static int frame_reader_fill(struct frame_reader *r, int fd) {
  for (;;) {
    if (r->hdr_fill < 9) {
      ssize_t n = read(fd, r->hdr + r->hdr_fill, 9 - r->hdr_fill);
      if (n < 0) {
        if (errno == EINTR)
          continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK)
          return 0;
        return -1;
      }
      if (n == 0)
        return -1; /* peer closed */
      r->hdr_fill += (int)n;
      continue;
    }
    if (r->payload_fill == 0) {
      uint32_t len = ((uint32_t)r->hdr[0] << 16) | ((uint32_t)r->hdr[1] << 8) |
                     (uint32_t)r->hdr[2];
      r->type = r->hdr[3];
      r->flags = r->hdr[4];
      r->sid = ((uint32_t)r->hdr[5] << 24) | ((uint32_t)r->hdr[6] << 16) |
               ((uint32_t)r->hdr[7] << 8) | (uint32_t)r->hdr[8];
      r->payload_len = len;
      if (len > r->payload_cap) {
        uint8_t *np = (uint8_t *)realloc(r->payload, len ? len : 1);
        if (np == NULL)
          return -1;
        r->payload = np;
        r->payload_cap = len;
      }
      if (len == 0)
        return 1;
    }
    {
      ssize_t n = read(fd, r->payload + r->payload_fill,
                       r->payload_len - r->payload_fill);
      if (n < 0) {
        if (errno == EINTR)
          continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK)
          return 0;
        return -1;
      }
      if (n == 0)
        return -1;
      r->payload_fill += (size_t)n;
      if (r->payload_fill >= r->payload_len)
        return 1;
    }
  }
}

/* =========================================================================
 * Connection + stream state
 * ========================================================================= */

enum {
  ST_UNARY = 1,
  ST_SUBSCRIBE = 2,
};

enum stream_state {
  SS_SENT = 0,    /* request sent, waiting for response headers */
  SS_HEADERS = 1, /* initial response headers received          */
  SS_DONE = 2,    /* finished: trailers seen / failed / closed  */
};

/* One queued gRPC message for a server-streaming stream. */
struct h2c_msg {
  uint8_t *data;
  uint32_t len;
  struct h2c_msg *next;
};

struct strim_h2c_stream {
  struct strim_h2c *owner; /* the connection that owns this stream   */
  uint32_t id;
  int in_use;
  int type;
  int state;
  int saw_headers; /* initial response headers received on this stream */
  int status;  /* final gRPC status when state == SS_DONE (>= 0) */
  int err;     /* client-side H2C_ERR_* when we aborted locally   */
  int32_t recv_window; /* server -> client, we advertise          */
  int32_t send_window; /* client -> server, server advertises     */

  /* gRPC message reassembler. */
  int rasm_state;
  uint8_t rasm_hdr[5];
  int rasm_hdr_fill;
  uint32_t rasm_msglen;
  uint32_t rasm_got;
  uint8_t *rasm_buf;
  size_t rasm_buf_cap;

  /* Queue of complete messages awaiting h2c_stream_next. */
  struct h2c_msg *q_head;
  struct h2c_msg *q_tail;
  size_t q_bytes;
  int q_closed; /* stream finished; drain then report final status */

  /* The message most recently handed out by h2c_stream_next; valid until the
   * next call (contract) and freed on the next call or at stream_destroy. */
  uint8_t *last_msg;

  /* Unary destination (valid while the unary blocks). */
  uint8_t *resp;
  uint32_t resp_cap;
  uint32_t resp_len;
  int msg_count;
};

struct strim_h2c {
  int fd;
  int ready;
  int dead;
  int dead_code; /* H2C_ERR_* that killed the connection */

  char namespace_[H2C_MAX_NAMESPACE];

  uint32_t next_sid;
  struct strim_h2c_stream streams[H2C_MAX_STREAMS];

  int32_t conn_recv_window;
  int32_t conn_send_window;

  uint32_t srv_max_frame;
  uint32_t srv_max_streams;
  int32_t srv_initial_window;

  struct hpack_dyn dyn_enc;
  struct hpack_dyn dyn_dec;
  int enc_size_update; /* emit a table-size update in the next request */

  struct frame_reader rx;

  uint8_t *hdr_block;
  size_t hdr_block_len;
  size_t hdr_block_cap;
  uint32_t hdr_block_sid;
  uint8_t hdr_block_flags;
  int hdr_block_pending;

  int goaway_seen;
  uint32_t goaway_last_sid;

  char msg_ring[2][H2C_MAX_HDR_MSG];
  int msg_status[2];
  int msg_head;
};

/* =========================================================================
 * Internal helpers
 * ========================================================================= */

static void stream_destroy(struct strim_h2c *c, struct strim_h2c_stream *s);
static void stream_credit_message(struct strim_h2c *c, struct strim_h2c_stream *s,
                                  uint32_t total);

static struct strim_h2c_stream *stream_find(struct strim_h2c *c, uint32_t sid) {
  int i;
  for (i = 0; i < H2C_MAX_STREAMS; i++) {
    if (c->streams[i].in_use && c->streams[i].id == sid)
      return &c->streams[i];
  }
  return NULL;
}

static void queue_push(struct strim_h2c_stream *s, uint8_t *data, uint32_t len) {
  struct h2c_msg *m = (struct h2c_msg *)malloc(sizeof(*m));
  if (m == NULL)
    return;
  m->data = data;
  m->len = len;
  m->next = NULL;
  if (s->q_tail)
    s->q_tail->next = m;
  else
    s->q_head = m;
  s->q_tail = m;
  s->q_bytes += (size_t)len;
}

static void queue_drain(struct strim_h2c_stream *s) {
  struct h2c_msg *m = s->q_head;
  while (m) {
    struct h2c_msg *next = m->next;
    free(m->data);
    free(m);
    m = next;
  }
  s->q_head = NULL;
  s->q_tail = NULL;
  s->q_bytes = 0;
}

static void stream_destroy(struct strim_h2c *c, struct strim_h2c_stream *s) {
  free(s->rasm_buf);
  s->rasm_buf = NULL;
  s->rasm_buf_cap = 0;
  free(s->last_msg);
  s->last_msg = NULL;
  queue_drain(s);
  s->in_use = 0;
  (void)c;
}

/* Allocate a stream slot: prefer unused; otherwise reclaim the oldest
 * finished (SS_DONE) slot. Returns NULL if all slots are live. */
static struct strim_h2c_stream *stream_alloc(struct strim_h2c *c, int type) {
  int i;
  int done_slot = -1;
  for (i = 0; i < H2C_MAX_STREAMS; i++) {
    if (!c->streams[i].in_use) {
      struct strim_h2c_stream *s = &c->streams[i];
      memset(s, 0, sizeof(*s));
      s->owner = c;
      s->in_use = 1;
      s->type = type;
      s->id = c->next_sid;
      s->state = SS_SENT;
      s->recv_window = H2_INIT_WINDOW;
      s->send_window = c->srv_initial_window;
      c->next_sid += 2;
      return s;
    }
    if (c->streams[i].state == SS_DONE && done_slot < 0)
      done_slot = i;
  }
  if (done_slot >= 0) {
    struct strim_h2c_stream *s = &c->streams[done_slot];
    stream_destroy(c, s);
    return stream_alloc(c, type);
  }
  return NULL;
}

static void conn_store_message(struct strim_h2c *c, int status,
                               const char *msg) {
  if (msg == NULL || msg[0] == '\0')
    msg = "";
  c->msg_head = (c->msg_head + 1) % 2;
  c->msg_status[c->msg_head] = status;
  snprintf(c->msg_ring[c->msg_head], H2C_MAX_HDR_MSG, "%s", msg);
}

static void percent_decode(const char *in, size_t in_len, char *out,
                           size_t out_cap) {
  size_t o = 0;
  size_t i = 0;
  while (i < in_len && o + 1 < out_cap) {
    if (in[i] == '%' && i + 2 < in_len) {
      int hi = in[i + 1], lo = in[i + 2];
      int hv, lv;
      if (hi >= '0' && hi <= '9')
        hv = hi - '0';
      else if (hi >= 'a' && hi <= 'f')
        hv = hi - 'a' + 10;
      else if (hi >= 'A' && hi <= 'F')
        hv = hi - 'A' + 10;
      else {
        out[o++] = in[i++];
        continue;
      }
      if (lo >= '0' && lo <= '9')
        lv = lo - '0';
      else if (lo >= 'a' && lo <= 'f')
        lv = lo - 'a' + 10;
      else if (lo >= 'A' && lo <= 'F')
        lv = lo - 'A' + 10;
      else {
        out[o++] = in[i++];
        continue;
      }
      out[o++] = (char)((hv << 4) | lv);
      i += 3;
    } else {
      out[o++] = in[i++];
    }
  }
  out[o] = '\0';
}

/* =========================================================================
 * Frame dispatch
 * ========================================================================= */

static void complete_all_streams(struct strim_h2c *c, int status,
                                 const char *msg) {
  int i;
  for (i = 0; i < H2C_MAX_STREAMS; i++) {
    struct strim_h2c_stream *s = &c->streams[i];
    if (!s->in_use || s->state == SS_DONE)
      continue;
    s->state = SS_DONE;
    s->status = status;
    s->err = 0;
    free(s->rasm_buf);
    s->rasm_buf = NULL;
    s->rasm_buf_cap = 0;
  }
  conn_store_message(c, status, msg);
}

static void conn_fail(struct strim_h2c *c, int err_code) {
  if (c->dead)
    return;
  c->dead = 1;
  c->dead_code = err_code;
  complete_all_streams(c, H2C_STATUS_UNAVAILABLE, "connection failed");
}

/* Abort a stream with RST_STREAM and mark it finished (protocol error). */
static void stream_abort(struct strim_h2c *c, struct strim_h2c_stream *s,
                         uint32_t h2_code, int err_code) {
  frame_write_rst(c->fd, s->id, h2_code);
  s->state = SS_DONE;
  s->status = H2C_STATUS_INTERNAL;
  s->err = err_code;
  free(s->rasm_buf);
  s->rasm_buf = NULL;
  s->rasm_buf_cap = 0;
}

static int handle_settings(struct strim_h2c *c, const uint8_t *p, size_t len) {
  size_t i;
  if (len % 6 != 0)
    return -1;
  for (i = 0; i < len; i += 6) {
    uint16_t id = (uint16_t)((p[i] << 8) | p[i + 1]);
    uint32_t val = ((uint32_t)p[i + 2] << 24) | ((uint32_t)p[i + 3] << 16) |
                   ((uint32_t)p[i + 4] << 8) | (uint32_t)p[i + 5];
    switch (id) {
    case H2_SETTINGS_HEADER_TABLE_SIZE:
      /* The peer's advertised header-table size limits the size of the
       * dynamic table OUR ENCODER may use when compressing requests it will
       * decode (RFC 7541 §4.2 — the decoder's SETTINGS_HEADER_TABLE_SIZE
       * bounds the encoder's table, NOT our own decoder's table). A change
       * must be signalled with a table-size update at the start of the next
       * request header block (§4.2 / §6.3). */
      if ((size_t)val != c->dyn_enc.max_size) {
        dyn_set_max(&c->dyn_enc, val);
        c->enc_size_update = 1;
      }
      break;
    case H2_SETTINGS_INITIAL_WINDOW_SIZE: {
      int32_t delta = (int32_t)val - c->srv_initial_window;
      int s;
      c->srv_initial_window = (int32_t)val;
      for (s = 0; s < H2C_MAX_STREAMS; s++) {
        if (c->streams[s].in_use) {
          c->streams[s].send_window += delta;
          if (c->streams[s].send_window > 0x7fffffff)
            return -1;
        }
      }
      break;
    }
    case H2_SETTINGS_MAX_FRAME_SIZE:
      if (val < 16384 || val > 16777215)
        return -1;
      c->srv_max_frame = val;
      break;
    case H2_SETTINGS_MAX_CONCURRENT_STREAMS:
      c->srv_max_streams = val;
      break;
    default:
      break;
    }
  }
  if (frame_write_settings(c->fd, H2_FLAG_ACK, NULL, 0) < 0)
    return -1;
  c->ready = 1;
  return 0;
}

static int handle_header_block(struct strim_h2c *c, uint32_t sid,
                               const uint8_t *block, size_t len,
                               uint8_t flags);
static void stream_feed_data(struct strim_h2c *c, struct strim_h2c_stream *s,
                             const uint8_t *data, size_t len);

static int handle_headers_frame(struct strim_h2c *c, uint8_t flags,
                                uint32_t sid, const uint8_t *payload,
                                size_t len) {
  if (c->hdr_block_pending)
    return -1;
  if (flags & H2_FLAG_END_HEADERS)
    return handle_header_block(c, sid, payload, len, flags);
  if (len > H2C_HDR_BLOCK_MAX)
    return -1;
  if (len > c->hdr_block_cap) {
    uint8_t *nb = (uint8_t *)realloc(c->hdr_block, len ? len : 1);
    if (nb == NULL)
      return -1;
    c->hdr_block = nb;
    c->hdr_block_cap = len;
  }
  if (len)
    memcpy(c->hdr_block, payload, len);
  c->hdr_block_len = len;
  c->hdr_block_sid = sid;
  c->hdr_block_flags = flags;
  c->hdr_block_pending = 1;
  return 0;
}

static int handle_continuation_frame(struct strim_h2c *c, uint8_t flags,
                                     const uint8_t *payload, size_t len) {
  if (!c->hdr_block_pending)
    return -1;
  if (c->hdr_block_len + len > H2C_HDR_BLOCK_MAX)
    return -1;
  if (c->hdr_block_len + len > c->hdr_block_cap) {
    size_t ncap = c->hdr_block_len + len;
    uint8_t *nb = (uint8_t *)realloc(c->hdr_block, ncap ? ncap : 1);
    if (nb == NULL)
      return -1;
    c->hdr_block = nb;
    c->hdr_block_cap = ncap;
  }
  if (len)
    memcpy(c->hdr_block + c->hdr_block_len, payload, len);
  c->hdr_block_len += len;
  if (flags & H2_FLAG_END_HEADERS) {
    int rc = handle_header_block(c, c->hdr_block_sid, c->hdr_block,
                                 c->hdr_block_len, c->hdr_block_flags);
    c->hdr_block_pending = 0;
    return rc;
  }
  return 0;
}

static int headers_block_offset(const uint8_t *payload, size_t len,
                                uint8_t flags, size_t *block_len) {
  size_t off = 0;
  if (flags & H2_FLAG_PADDED) {
    if (len < 1)
      return -1;
    off = 1 + payload[0];
    if (off > len)
      return -1;
  }
  if (flags & H2_FLAG_PRIORITY) {
    off += 5;
    if (off > len)
      return -1;
  }
  *block_len = len - off;
  return (int)off;
}

static int header_name_eq(const struct hpack_field *f, const char *name) {
  return f->name_len == strlen(name) && memcmp(f->name, name, f->name_len) == 0;
}

static int header_value_eq(const struct hpack_field *f, const char *value) {
  return f->value_len == strlen(value) &&
         memcmp(f->value, value, f->value_len) == 0;
}

static int parse_status_int(const struct hpack_field *f) {
  int v = 0;
  size_t i;
  for (i = 0; i < f->value_len; i++) {
    if (f->value[i] < '0' || f->value[i] > '9')
      return -1;
    v = v * 10 + (f->value[i] - '0');
    if (v > 999)
      return -1;
  }
  return v;
}

static int handle_header_block(struct strim_h2c *c, uint32_t sid,
                               const uint8_t *block, size_t len,
                               uint8_t flags) {
  struct hpack_field fields[H2C_MAX_FIELDS];
  int n_fields = 0;
  size_t block_len;
  int off = headers_block_offset(block, len, flags, &block_len);
  struct strim_h2c_stream *s;
  int i;
  int status_value = 0;
  int has_status = 0;
  int status_ok = 0;
  int has_grpc_status = 0;
  int grpc_status = 0;
  int content_type_ok = 0;
  int encoding_ok = 1;
  char msg_buf[H2C_MAX_HDR_MSG];

  if (off < 0)
    return -1;
  /* The decoder owns the field array: zero it so every name/value pointer is
   * NULL until the decoder allocates it. On a decode error mid-block the
   * current field may be half-built (name allocated, value not, and not yet
   * counted in n_fields), so free the whole array — free(NULL) is a no-op. */
  memset(fields, 0, sizeof(fields));
  if (hpack_decode_block(&c->dyn_dec, block + off, block_len, fields,
                         H2C_MAX_FIELDS, &n_fields) < 0) {
    hpack_free_fields(fields, H2C_MAX_FIELDS);
    return -1;
  }

  s = stream_find(c, sid);
  if (s == NULL) {
    hpack_free_fields(fields, n_fields);
    return -1;
  }
  if (s->state == SS_DONE && s->err != 0) {
    hpack_free_fields(fields, n_fields);
    return 0; /* draining a client-aborted stream */
  }

  msg_buf[0] = '\0';
  for (i = 0; i < n_fields; i++) {
    const struct hpack_field *f = &fields[i];
    if (header_name_eq(f, ":status")) {
      has_status = 1;
      status_value = parse_status_int(f);
      status_ok = (status_value == 200);
    } else if (header_name_eq(f, "grpc-status")) {
      int v = parse_status_int(f);
      if (v < 0 || v > 99) {
        hpack_free_fields(fields, n_fields);
        return -1;
      }
      has_grpc_status = 1;
      grpc_status = v;
    } else if (header_name_eq(f, "grpc-message")) {
      percent_decode((const char *)f->value, f->value_len, msg_buf,
                     sizeof(msg_buf));
    } else if (header_name_eq(f, "content-type")) {
      content_type_ok = (f->value_len >= 16 &&
                         memcmp(f->value, "application/grpc", 16) == 0);
    } else if (header_name_eq(f, "grpc-encoding")) {
      if (!header_value_eq(f, "identity"))
        encoding_ok = 0;
    }
  }
  hpack_free_fields(fields, n_fields);

  if (has_status && !status_ok && !has_grpc_status) {
    grpc_status = (status_value == 404) ? H2C_STATUS_UNIMPLEMENTED
                                        : H2C_STATUS_INTERNAL;
    has_grpc_status = 1;
  }
  if (!has_grpc_status && !content_type_ok) {
    grpc_status = H2C_STATUS_INTERNAL;
    has_grpc_status = 1;
  }
  if (!encoding_ok) {
    grpc_status = H2C_STATUS_INTERNAL;
    has_grpc_status = 1;
  }

  if (has_grpc_status) {
    /* Trailing headers (or trailers-only) — the RPC is finished. */
    s->state = SS_DONE;
    s->status = grpc_status;
    s->err = 0;
    s->q_closed = 1;
    free(s->rasm_buf);
    s->rasm_buf = NULL;
    s->rasm_buf_cap = 0;
    if (grpc_status != 0 || msg_buf[0])
      conn_store_message(c, grpc_status, msg_buf);
    return 0;
  }

  if (s->state != SS_SENT)
    return -1; /* duplicate initial headers */
  s->state = SS_HEADERS;
  s->saw_headers = 1;
  return 0;
}

static int handle_data_frame(struct strim_h2c *c, uint8_t flags, uint32_t sid,
                             const uint8_t *payload, size_t len) {
  struct strim_h2c_stream *s = stream_find(c, sid);
  size_t data_off = 0;
  size_t data_len = len;
  int padded = (flags & H2_FLAG_PADDED) != 0;

  if (s == NULL)
    return -1;
  if (s->state == SS_DONE) {
    if (s->err != 0)
      return 0; /* draining a client-aborted stream */
    return -1;
  }
  if (c->conn_recv_window < (int32_t)len || s->recv_window < (int32_t)len)
    return -1; /* server exceeded our advertised window */
  if (padded) {
    if (len < 1 || payload[0] > len - 1)
      return -1;
    data_len = len - 1 - payload[0];
    data_off = 1;
  }
  c->conn_recv_window -= (int32_t)len;
  s->recv_window -= (int32_t)len;

  stream_feed_data(c, s, payload + data_off, data_len);

  if ((flags & H2_FLAG_END_STREAM) != 0) {
    if (s->rasm_state != 0) {
      stream_abort(c, s, H2_ERR_PROTOCOL, H2C_ERR_PROTO);
      return 0;
    }
  }
  return 0;
}

/* Feed DATA payload bytes into the stream's gRPC message reassembler. */
static void stream_feed_data(struct strim_h2c *c, struct strim_h2c_stream *s,
                             const uint8_t *data, size_t len) {
  size_t off = 0;
  while (off < len) {
    if (s->rasm_state == 0) {
      size_t need = 5 - (size_t)s->rasm_hdr_fill;
      size_t take = len - off < need ? len - off : need;
      memcpy(s->rasm_hdr + s->rasm_hdr_fill, data + off, take);
      s->rasm_hdr_fill += (int)take;
      off += take;
      if (s->rasm_hdr_fill < 5)
        return;
      if (s->rasm_hdr[0] != 0) {
        stream_abort(c, s, H2_ERR_INTERNAL, H2C_ERR_PROTO); /* compressed */
        return;
      }
      s->rasm_msglen = ((uint32_t)s->rasm_hdr[1] << 24) |
                       ((uint32_t)s->rasm_hdr[2] << 16) |
                       ((uint32_t)s->rasm_hdr[3] << 8) |
                       (uint32_t)s->rasm_hdr[4];
      if (s->rasm_msglen > H2C_MAX_MSG) {
        stream_abort(c, s, H2_ERR_FRAME_SIZE, H2C_ERR_TOOBIG);
        return;
      }
      s->rasm_got = 0;
      if (s->type == ST_SUBSCRIBE) {
        size_t cap = s->rasm_msglen ? s->rasm_msglen : 1;
        uint8_t *nb = (uint8_t *)realloc(s->rasm_buf, cap);
        if (nb == NULL) {
          stream_abort(c, s, H2_ERR_INTERNAL, H2C_ERR_IO);
          return;
        }
        s->rasm_buf = nb;
        s->rasm_buf_cap = cap;
      } else if (s->resp != NULL && s->rasm_msglen > s->resp_cap) {
        frame_write_rst(c->fd, s->id, H2_ERR_CANCEL);
        s->state = SS_DONE;
        s->err = H2C_ERR_TOOBIG;
        s->status = 0;
        s->q_closed = 1;
        return;
      }
      s->rasm_state = 1;
    }
    if (s->rasm_state == 1) {
      size_t need = (size_t)(s->rasm_msglen - s->rasm_got);
      size_t take = len - off < need ? len - off : need;
      if (s->type == ST_SUBSCRIBE) {
        memcpy(s->rasm_buf + s->rasm_got, data + off, take);
      } else if (s->resp != NULL) {
        memcpy(s->resp + s->rasm_got, data + off, take);
      }
      s->rasm_got += (uint32_t)take;
      off += take;
      if (s->rasm_got >= s->rasm_msglen) {
        if (s->type == ST_SUBSCRIBE) {
          if (s->q_bytes + s->rasm_msglen > H2C_QUEUE_MAX_BYTES) {
            stream_abort(c, s, H2_ERR_FLOW_CONTROL, H2C_ERR_PROTO);
            return;
          }
          queue_push(s, s->rasm_buf, s->rasm_msglen);
          s->rasm_buf = NULL; /* ownership moved to the queue */
          s->rasm_buf_cap = 0;
        } else {
          s->resp_len = s->rasm_got;
          s->msg_count++;
          if (s->msg_count > 1) {
            stream_abort(c, s, H2_ERR_PROTOCOL, H2C_ERR_PROTO);
            return;
          }
          /* The unary caller owns the response now; credit the receive
           * windows exactly like the stream-queue path, so a shared
           * connection never drains below the peer's advertised window.
           * A stream that aborts above is never credited (at most once). */
          stream_credit_message(c, s, s->rasm_got + 5);
        }
        s->rasm_state = 0;
        s->rasm_hdr_fill = 0;
      }
    }
  }
}

/* Credit flow control for one consumed gRPC message (5-byte header + body).
 * Atomic: the local windows and the peer-facing WINDOW_UPDATE frames move
 * together. The overflow guards run FIRST (RFC 7540 §6.9 — an update that
 * would push a window past 2^31-1 is a FLOW_CONTROL_ERROR): on overflow the
 * local counters are left untouched and no frames are written, so the peer
 * is never credited for credit we refuse to apply. */
static void stream_credit_message(struct strim_h2c *c, struct strim_h2c_stream *s,
                                  uint32_t total) {
  if (total == 0)
    return;
  if (s->recv_window > 0x7fffffff - (int32_t)total)
    return;
  if (c->conn_recv_window > 0x7fffffff - (int32_t)total)
    return;
  s->recv_window += (int32_t)total;
  c->conn_recv_window += (int32_t)total;
  frame_write_window_update(c->fd, s->id, total);
  frame_write_window_update(c->fd, 0, total);
}

static int handle_window_update(struct strim_h2c *c, uint32_t sid,
                                const uint8_t *payload, size_t len) {
  uint32_t inc;
  if (len != 4)
    return -1;
  inc = ((uint32_t)payload[0] << 24) | ((uint32_t)payload[1] << 16) |
        ((uint32_t)payload[2] << 8) | (uint32_t)payload[3];
  if (inc == 0)
    return -1;
  if (sid == 0) {
    c->conn_send_window += (int32_t)inc;
    if (c->conn_send_window > 0x7fffffff)
      return -1;
  } else {
    struct strim_h2c_stream *s = stream_find(c, sid);
    if (s == NULL)
      return 0; /* stream already finished; ignore */
    s->send_window += (int32_t)inc;
    if (s->send_window > 0x7fffffff)
      return -1;
  }
  return 0;
}

static int handle_goaway(struct strim_h2c *c, const uint8_t *payload,
                         size_t len) {
  uint32_t last_sid;
  if (len < 8)
    return -1;
  last_sid = ((uint32_t)payload[0] << 24) | ((uint32_t)payload[1] << 16) |
             ((uint32_t)payload[2] << 8) | (uint32_t)payload[3];
  c->goaway_seen = 1;
  c->goaway_last_sid = last_sid;
  complete_all_streams(c, H2C_STATUS_UNAVAILABLE, "server GOAWAY");
  c->dead = 1;
  c->dead_code = H2C_ERR_GOAWAY;
  return 0;
}

static int handle_rst_stream(struct strim_h2c *c, uint32_t sid,
                             const uint8_t *payload, size_t len) {
  struct strim_h2c_stream *s;
  if (len != 4)
    return -1;
  (void)payload;
  s = stream_find(c, sid);
  if (s == NULL)
    return 0; /* RST for a finished stream: ignore */
  if (s->state == SS_DONE) {
    stream_destroy(c, s); /* server acknowledged our cancel */
    return 0;
  }
  s->state = SS_DONE;
  s->status = H2C_STATUS_CANCELLED;
  s->err = 0;
  s->q_closed = 1;
  free(s->rasm_buf);
  s->rasm_buf = NULL;
  s->rasm_buf_cap = 0;
  return 0;
}

static int handle_ping(struct strim_h2c *c, uint8_t flags,
                       const uint8_t *payload, size_t len) {
  uint8_t opaque[8] = {0, 0, 0, 0, 0, 0, 0, 0};
  if (len != 8)
    return -1;
  if (flags & H2_FLAG_ACK)
    return 0;
  memcpy(opaque, payload, 8);
  if (frame_write_ping_ack(c->fd, opaque) < 0)
    return -1;
  return 0;
}

static int process_one_frame(struct strim_h2c *c) {
  struct frame_reader *r = &c->rx;
  int fr = frame_reader_fill(r, c->fd);
  int rc;

  if (fr < 0)
    return H2C_ERR_IO;
  if (fr == 0)
    return 0;

  switch (r->type) {
  case H2_SETTINGS:
    if (r->sid != 0)
      rc = -1;
    else if (r->flags & H2_FLAG_ACK)
      rc = (r->payload_fill == 0) ? 0 : -1;
    else
      rc = handle_settings(c, r->payload, r->payload_fill);
    break;
  case H2_PING:
    rc = handle_ping(c, r->flags, r->payload, r->payload_fill);
    break;
  case H2_WINDOW_UPDATE:
    rc = handle_window_update(c, r->sid, r->payload, r->payload_fill);
    break;
  case H2_DATA:
    rc = handle_data_frame(c, r->flags, r->sid, r->payload, r->payload_fill);
    break;
  case H2_HEADERS:
    rc = handle_headers_frame(c, r->flags, r->sid, r->payload, r->payload_fill);
    break;
  case H2_CONTINUATION:
    rc = handle_continuation_frame(c, r->flags, r->payload, r->payload_fill);
    break;
  case H2_RST_STREAM:
    rc = handle_rst_stream(c, r->sid, r->payload, r->payload_fill);
    break;
  case H2_GOAWAY:
    rc = handle_goaway(c, r->payload, r->payload_fill);
    break;
  case H2_PRIORITY:
    rc = (r->payload_fill == 5) ? 0 : -1;
    break;
  case H2_PUSH_PROMISE:
    rc = -1; /* we advertise ENABLE_PUSH=0 */
    break;
  default:
    rc = -1;
    break;
  }

  frame_reader_reset(r);
  if (rc < 0) {
    return H2C_ERR_PROTO;
  }
  return 1;
}

/* Poll the connection once. Returns 1 if at least one frame was processed,
 * 0 on timeout/no-progress, negative H2C_ERR_* on connection death. */
static int conn_poll_once(struct strim_h2c *c, int timeout_ms) {
  struct pollfd pfd;
  int pr;
  int budget = H2C_FRAME_BUDGET;

  if (c->dead)
    return c->dead_code;

  pfd.fd = c->fd;
  pfd.events = POLLIN;
  pfd.revents = 0;
  pr = poll(&pfd, 1, timeout_ms);
  if (pr < 0) {
    if (errno == EINTR)
      return 0;
    conn_fail(c, H2C_ERR_IO);
    return H2C_ERR_IO;
  }
  if (pr == 0)
    return 0;

  while (budget-- > 0) {
    int r = process_one_frame(c);
    if (r < 0) {
      conn_fail(c, r);
      return c->dead_code;
    }
    if (r == 0)
      break;
  }
  if (c->dead)
    return c->dead_code;
  return 1;
}

/* =========================================================================
 * Request sending
 * ========================================================================= */

static const uint8_t H2_PREFACE[24] = {
    'P', 'R', 'I', ' ', '*', ' ', 'H', 'T', 'T', 'P', '/', '2',
    '.', '0', '\r', '\n', '\r', '\n', 'S', 'M', '\r', '\n', '\r', '\n'};

static const char *DEFAULT_SOCK = "/run/containerd/containerd.sock";
static const char *DEFAULT_NS = "default";
static const char *H2_AUTHORITY = "localhost";
static const char *H2_USER_AGENT = "grpc-c/1.0";

static int build_request_headers(struct strim_h2c *c, const char *path,
                                 uint8_t *out, size_t cap, size_t *len) {
  size_t n = 0;
  size_t w;

  /* A dynamic table size update must precede every other field in the first
   * header block after the peer changed the advertised header-table size. */
  if (c->enc_size_update) {
    w = hpack_write_int_ex(out + n, cap - n, (uint32_t)c->dyn_enc.max_size, 5,
                           0x20);
    if (w == 0)
      return -1;
    n += w;
    c->enc_size_update = 0;
  }

  /* :method POST (static 3) and :scheme http (static 6) are fully indexed. */
  w = hpack_write_int_ex(out + n, cap - n, 3, 7, 0x80);
  if (w == 0)
    return -1;
  n += w;
  w = hpack_write_int_ex(out + n, cap - n, 6, 7, 0x80);
  if (w == 0)
    return -1;
  n += w;

  w = hpack_encode_field(&c->dyn_enc, out + n, cap - n, ":path", path);
  if (w == 0)
    return -1;
  n += w;
  w = hpack_encode_field(&c->dyn_enc, out + n, cap - n, ":authority", H2_AUTHORITY);
  if (w == 0)
    return -1;
  n += w;
  w = hpack_encode_field(&c->dyn_enc, out + n, cap - n, "content-type",
                         "application/grpc");
  if (w == 0)
    return -1;
  n += w;
  w = hpack_encode_field(&c->dyn_enc, out + n, cap - n, "te", "trailers");
  if (w == 0)
    return -1;
  n += w;
  w = hpack_encode_field(&c->dyn_enc, out + n, cap - n, "user-agent", H2_USER_AGENT);
  if (w == 0)
    return -1;
  n += w;
  w = hpack_encode_field(&c->dyn_enc, out + n, cap - n, "containerd-namespace",
                         c->namespace_);
  if (w == 0)
    return -1;
  n += w;
  *len = n;
  return 0;
}

/* Send a request: HEADERS(END_HEADERS) then gRPC-framed DATA frames with
 * END_STREAM on the last. req_len may be 0 (the 5-byte gRPC header is still
 * sent). Returns 0 or a negative H2C_ERR_*. */
static int send_request(struct strim_h2c *c, struct strim_h2c_stream *s,
                        const char *path, const uint8_t *req, uint32_t req_len) {
  uint8_t hdr_block[H2C_REQ_HDR_BLOCK];
  size_t hdr_len = 0;
  uint8_t grpc_hdr[5];
  uint32_t frame_max = c->srv_max_frame;
  uint32_t total = req_len + 5;
  uint32_t sent = 0;
  uint8_t buf[H2C_DATA_BUF];

  if (build_request_headers(c, path, hdr_block, sizeof(hdr_block), &hdr_len) < 0)
    return H2C_ERR_PROTO;
  if (frame_write(c->fd, H2_HEADERS, H2_FLAG_END_HEADERS, s->id, hdr_block,
                  hdr_len) < 0)
    return H2C_ERR_IO;

  grpc_hdr[0] = 0;
  grpc_hdr[1] = (uint8_t)(req_len >> 24);
  grpc_hdr[2] = (uint8_t)(req_len >> 16);
  grpc_hdr[3] = (uint8_t)(req_len >> 8);
  grpc_hdr[4] = (uint8_t)req_len;

  while (sent < total) {
    uint32_t chunk = total - sent;
    uint8_t flags = 0;
    uint32_t i;
    if (chunk > frame_max)
      chunk = frame_max;
    if (sent + chunk >= total)
      flags |= H2_FLAG_END_STREAM;
    for (i = 0; i < chunk; i++) {
      uint32_t pos = sent + i;
      buf[i] = (pos < 5) ? grpc_hdr[pos] : req[pos - 5];
    }
    /* Wait for flow-control credit: a request larger than the initial 64 KiB
     * window is written in pieces as the server consumes the earlier DATA
     * frames and grants WINDOW_UPDATEs. The connection is driven from one
     * thread at a time (the containerd client holds its mutex across the
     * call), so polling here is safe. */
    if (s->send_window < (int32_t)chunk ||
        c->conn_send_window < (int32_t)chunk) {
      int64_t win_deadline = mono_ms() + H2C_DEFAULT_UNARY_TIMEOUT_MS;
      while (s->send_window < (int32_t)chunk ||
             c->conn_send_window < (int32_t)chunk) {
        int wr;
        if (time_left_ms(win_deadline) <= 0)
          return H2C_ERR_TIMEOUT;
        wr = conn_poll_once(c, 50);
        if (wr < 0)
          return (c->dead_code == H2C_ERR_GOAWAY) ? H2C_ERR_GOAWAY : H2C_ERR_IO;
        if (s->state == SS_DONE)
          return H2C_ERR_PROTO; /* server ended the stream while we waited */
      }
    }
    s->send_window -= (int32_t)chunk;
    c->conn_send_window -= (int32_t)chunk;
    if (frame_write(c->fd, H2_DATA, flags, s->id, buf, chunk) < 0)
      return H2C_ERR_IO;
    sent += chunk;
  }
  return 0;
}

/* =========================================================================
 * Public API
 * ========================================================================= */

int h2c_connect(strim_h2c **out, const char *sock_path, const char *namespace_) {
  struct strim_h2c *c;
  int fd = -1;
  struct sockaddr_un addr;
  const char *path = sock_path && sock_path[0] ? sock_path : DEFAULT_SOCK;
  const char *ns = namespace_ && namespace_[0] ? namespace_ : DEFAULT_NS;
  uint8_t settings[30];
  size_t settings_len = 0;
  int64_t deadline;

  if (out == NULL)
    return H2C_ERR_BADARG;
  *out = NULL;
  if (strlen(path) >= H2C_MAX_SOCK_PATH)
    return H2C_ERR_BADARG;
  if (strlen(ns) >= H2C_MAX_NAMESPACE)
    return H2C_ERR_BADARG;

  c = (struct strim_h2c *)calloc(1, sizeof(*c));
  if (c == NULL)
    return H2C_ERR_IO;

  fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) {
    free(c);
    return H2C_ERR_IO;
  }
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
  if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    close(fd);
    free(c);
    return H2C_ERR_IO;
  }

  c->fd = fd;
  {
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl < 0 || fcntl(fd, F_SETFL, fl | O_NONBLOCK) < 0) {
      close(fd);
      free(c);
      return H2C_ERR_IO;
    }
  }
  c->next_sid = 1;
  c->conn_recv_window = H2_INIT_WINDOW;
  c->conn_send_window = H2_INIT_WINDOW;
  c->srv_max_frame = 16384;
  c->srv_max_streams = 100;
  c->srv_initial_window = H2_INIT_WINDOW;
  c->msg_head = -1;
  strncpy(c->namespace_, ns, H2C_MAX_NAMESPACE - 1);
  c->namespace_[H2C_MAX_NAMESPACE - 1] = '\0';
  dyn_reset(&c->dyn_enc);
  dyn_reset(&c->dyn_dec);

  /* Our SETTINGS: ENABLE_PUSH=0, MAX_CONCURRENT_STREAMS=100,
   * INITIAL_WINDOW_SIZE=65535, MAX_FRAME_SIZE=16384, HEADER_TABLE_SIZE=4096. */
  settings[settings_len++] = 0x00;
  settings[settings_len++] = H2_SETTINGS_ENABLE_PUSH;
  settings[settings_len++] = 0;
  settings[settings_len++] = 0;
  settings[settings_len++] = 0;
  settings[settings_len++] = 0;
  settings[settings_len++] = 0x00;
  settings[settings_len++] = H2_SETTINGS_MAX_CONCURRENT_STREAMS;
  settings[settings_len++] = 0;
  settings[settings_len++] = 0;
  settings[settings_len++] = 0;
  settings[settings_len++] = 100;
  settings[settings_len++] = 0x00;
  settings[settings_len++] = H2_SETTINGS_INITIAL_WINDOW_SIZE;
  settings[settings_len++] = 0;
  settings[settings_len++] = 0;
  settings[settings_len++] = 0xff;
  settings[settings_len++] = 0xff;
  settings[settings_len++] = 0x00;
  settings[settings_len++] = H2_SETTINGS_MAX_FRAME_SIZE;
  settings[settings_len++] = 0;
  settings[settings_len++] = 0;
  settings[settings_len++] = 0x40;
  settings[settings_len++] = 0x00;
  settings[settings_len++] = 0x00;
  settings[settings_len++] = H2_SETTINGS_HEADER_TABLE_SIZE;
  settings[settings_len++] = 0;
  settings[settings_len++] = 0;
  settings[settings_len++] = 0x10;
  settings[settings_len++] = 0x00;

  if (write_all(fd, H2_PREFACE, sizeof(H2_PREFACE)) < 0 ||
      frame_write_settings(fd, 0, settings, settings_len) < 0) {
    close(fd);
    free(c);
    return H2C_ERR_IO;
  }

  /* Wait for the server's SETTINGS; ACK it and absorb any PING /
   * WINDOW_UPDATE that arrive during the handshake. */
  deadline = mono_ms() + H2C_HANDSHAKE_MS;
  while (!c->ready && !c->dead) {
    int64_t left = time_left_ms(deadline);
    int r;
    if (left <= 0) {
      close(fd);
      free(c);
      return H2C_ERR_TIMEOUT;
    }
    r = conn_poll_once(c, (int)(left > 100 ? 100 : left));
    if (r < 0) {
      close(fd);
      free(c);
      return H2C_ERR_IO;
    }
  }

  *out = c;
  return 0;
}

void h2c_close(strim_h2c *c) {
  int i;
  if (c == NULL)
    return;
  for (i = 0; i < H2C_MAX_STREAMS; i++) {
    if (c->streams[i].in_use && c->streams[i].state != SS_DONE)
      frame_write_rst(c->fd, c->streams[i].id, H2_ERR_CANCEL);
    stream_destroy(c, &c->streams[i]);
  }
  if (c->fd >= 0)
    close(c->fd);
  dyn_reset(&c->dyn_enc);
  dyn_reset(&c->dyn_dec);
  free(c->hdr_block);
  free(c->rx.payload);
  free(c);
}

int h2c_unary(strim_h2c *c, const char *method, const uint8_t *req,
              uint32_t req_len, uint8_t *resp, uint32_t resp_cap,
              uint32_t *resp_len, int64_t timeout_ms) {
  struct strim_h2c_stream *s;
  int64_t deadline;
  uint32_t timeout;

  if (c == NULL || method == NULL || resp_len == NULL)
    return H2C_ERR_BADARG;
  if (c->dead)
    return (c->dead_code == H2C_ERR_GOAWAY) ? H2C_ERR_GOAWAY : H2C_ERR_IO;
  if (resp == NULL && resp_cap != 0)
    return H2C_ERR_BADARG;
  if (req_len > H2C_MAX_MSG)
    return H2C_ERR_TOOBIG;

  s = stream_alloc(c, ST_UNARY);
  if (s == NULL)
    return H2C_ERR_NOSTREAM;
  s->resp = resp;
  s->resp_cap = resp_cap;
  s->resp_len = 0;

  {
    int rc = send_request(c, s, method, req, req_len);
    if (rc < 0) {
      stream_destroy(c, s);
      return rc;
    }
  }

  timeout = (timeout_ms > 0) ? (uint32_t)timeout_ms
                             : H2C_DEFAULT_UNARY_TIMEOUT_MS;
  deadline = mono_ms() + (int64_t)timeout;

  while (s->state != SS_DONE) {
    int r;
    if (time_left_ms(deadline) <= 0) {
      frame_write_rst(c->fd, s->id, H2_ERR_CANCEL);
      stream_destroy(c, s);
      return H2C_ERR_TIMEOUT;
    }
    r = conn_poll_once(c, H2C_UNARY_SLICE_MS);
    if (r < 0) {
      if (s->state == SS_DONE)
        break; /* completed in the same frame batch before the death */
      stream_destroy(c, s);
      return (c->dead_code == H2C_ERR_GOAWAY) ? H2C_ERR_GOAWAY
             : (c->dead_code == H2C_ERR_PROTO) ? H2C_ERR_PROTO
                                               : H2C_ERR_IO;
    }
  }

  if (s->err != 0) {
    int e = s->err;
    stream_destroy(c, s);
    return e;
  }
  if (s->status == 0) {
    *resp_len = s->resp_len;
    stream_destroy(c, s);
    return 0;
  }
  {
    int st = s->status;
    stream_destroy(c, s);
    return st;
  }
}

int h2c_stream_open(strim_h2c *c, const char *method, const uint8_t *req,
                    uint32_t req_len, strim_h2c_stream **out) {
  struct strim_h2c_stream *s;
  int rc;

  if (out == NULL)
    return H2C_ERR_BADARG;
  *out = NULL;
  if (c == NULL || method == NULL)
    return H2C_ERR_BADARG;
  if (c->dead)
    return (c->dead_code == H2C_ERR_GOAWAY) ? H2C_ERR_GOAWAY : H2C_ERR_IO;
  if (req_len > H2C_MAX_MSG)
    return H2C_ERR_TOOBIG;

  s = stream_alloc(c, ST_SUBSCRIBE);
  if (s == NULL)
    return H2C_ERR_NOSTREAM;

  rc = send_request(c, s, method, req, req_len);
  if (rc < 0) {
    stream_destroy(c, s);
    return rc;
  }

  /* Grace window: a server-streaming RPC is NOT required to send its
   * response headers promptly — grpc-go (containerd) sends them lazily with
   * the FIRST message, so an idle daemon legitimately sends nothing here.
   * Poll briefly only to catch an immediate completion: a trailers-only
   * error (e.g. an invalid filter), a connection death, or a fast headers
   * burst. When nothing arrives, return the stream OPEN — the response
   * headers (and first message) arrive in a later h2c_stream_next poll,
   * whose caller deadline governs. */
  {
    int64_t grace = mono_ms() + H2C_STREAM_OPEN_GRACE_MS;
    while (s->state == SS_SENT && time_left_ms(grace) > 0) {
      int r;
      if (c->dead) {
        stream_destroy(c, s);
        return (c->dead_code == H2C_ERR_GOAWAY) ? H2C_ERR_GOAWAY
               : (c->dead_code == H2C_ERR_PROTO) ? H2C_ERR_PROTO
                                                 : H2C_ERR_IO;
      }
      r = conn_poll_once(c, H2C_UNARY_SLICE_MS);
      if (r < 0 && s->state == SS_SENT) {
        stream_destroy(c, s);
        return (c->dead_code == H2C_ERR_GOAWAY) ? H2C_ERR_GOAWAY
               : (c->dead_code == H2C_ERR_PROTO) ? H2C_ERR_PROTO
                                                 : H2C_ERR_IO;
      }
    }
  }

  if (s->err != 0) {
    int e = s->err;
    stream_destroy(c, s);
    return e;
  }
  if (s->state == SS_DONE && !s->saw_headers) {
    /* Trailers-only response: the RPC finished before any message. */
    int st = s->status;
    stream_destroy(c, s);
    return (st == 0) ? H2C_ERR_STREAM_END : st;
  }

  *out = s;
  return 0;
}

int h2c_stream_next(strim_h2c_stream *s, int64_t timeout_ms,
                    const uint8_t **msg, uint32_t *len) {
  struct strim_h2c *owner;
  int64_t deadline;

  if (s == NULL || msg == NULL || len == NULL)
    return H2C_ERR_BADARG;
  if (!s->in_use)
    return H2C_ERR_CLOSED;
  owner = s->owner;

  deadline = (timeout_ms < 0) ? INT64_MAX : mono_ms() + timeout_ms;

  for (;;) {
    /* Pop a queued message first (may be present from a previous poll). */
    if (s->q_head != NULL) {
      struct h2c_msg *m = s->q_head;
      uint8_t *mdata = m->data;
      uint32_t mlen = m->len;
      s->q_head = m->next;
      if (s->q_head == NULL)
        s->q_tail = NULL;
      s->q_bytes -= (size_t)mlen;
      *msg = mdata;
      *len = mlen;
      free(m);
      /* The data buffer stays valid until the next call (contract); release
       * the previously handed-out buffer now. */
      if (s->last_msg != NULL)
        free(s->last_msg);
      s->last_msg = mdata;
      /* Credit flow control now that the consumer owns the message. */
      stream_credit_message(owner, s, *len + 5);
      return 0;
    }

    if (s->state == SS_DONE) {
      if (s->err != 0)
        return s->err;
      return (s->status == 0) ? H2C_ERR_STREAM_END : s->status;
    }

    if (time_left_ms(deadline) <= 0)
      return H2C_ERR_TIMEOUT;
    {
      int r = conn_poll_once(owner, H2C_UNARY_SLICE_MS);
      if (r < 0) {
        /* One conn_poll_once budget pass can deliver frames AND hit the
         * socket death in the same batch: the peer's FIN lands right after
         * the last frames (daemon died mid-stream), so the poll queues
         * messages / processes the trailers and THEN reports EOF. Re-check
         * the queue and the stream state before erroring (the h2c_unary /
         * h2c_stream_open pattern): the loop's queue and SS_DONE checks
         * deliver the messages and report the finished state first. */
        if (s->q_head != NULL || s->state == SS_DONE)
          continue;
        return (owner->dead_code == H2C_ERR_GOAWAY) ? H2C_ERR_GOAWAY
               : (owner->dead_code == H2C_ERR_PROTO) ? H2C_ERR_PROTO
                                                     : H2C_ERR_IO;
      }
    }
  }
}

void h2c_stream_close(strim_h2c_stream *s) {
  if (s == NULL)
    return;
  if (s->in_use) {
    struct strim_h2c *owner = s->owner;
    if (!owner->dead && s->state != SS_DONE)
      frame_write_rst(owner->fd, s->id, H2_ERR_CANCEL);
    s->q_closed = 1;
    s->state = SS_DONE;
    s->err = H2C_ERR_CLOSED;
    s->status = 0;
    stream_destroy(owner, s);
  }
}

/* =========================================================================
 * Self-test: HPACK / HTTP2 unit vectors, runnable without a daemon.
 * Returns 0 on success, or the number of failed checks.
 * ========================================================================= */

static int check(int cond, const char *what, int *failures) {
  if (!cond) {
    fprintf(stderr, "H2C SELFTEST FAIL: %s\n", what);
    (*failures)++;
  }
  return cond;
}

static int selftest_huffman(void) {
  struct {
    const char *plain;
    const uint8_t hex[16];
    size_t hex_len;
  } vec[] = {
      {"www.example.com",
       {0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff},
       12},
      {"no-cache", {0xa8, 0xeb, 0x10, 0x64, 0x9c, 0xbf}, 6},
      {"custom-key", {0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xa9, 0x7d, 0x7f}, 8},
      {"custom-value",
       {0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xb8, 0xe8, 0xb4, 0xbf}, 9},
      {"trailers", {0x4d, 0x83, 0x35, 0x05, 0xb1, 0x1f}, 6},
      {"application/grpc",
       {0x1d, 0x75, 0xd0, 0x62, 0x0d, 0x26, 0x3d, 0x4c, 0x4d, 0x65, 0x64},
       11},
      /* grpc-go Huffman-compresses response headers; these are the exact
       * encodings grpc-go emits for a trailers-only error response. */
      {"grpc-status",
       {0x9a, 0xca, 0xc8, 0xb2, 0x12, 0x34, 0xda, 0x8f}, 8},
      {"grpc-message",
       {0x9a, 0xca, 0xc8, 0xb5, 0x25, 0x42, 0x07, 0x31, 0x7f}, 9},
  };
  int failures = 0;
  size_t i;
  for (i = 0; i < sizeof(vec) / sizeof(vec[0]); i++) {
    uint8_t out[128];
    size_t out_len = 0;
    if (huff_decode(vec[i].hex, vec[i].hex_len, out, sizeof(out), &out_len) <
        0) {
      check(0, "huffman decode failed", &failures);
      continue;
    }
    check(out_len == strlen(vec[i].plain) &&
              memcmp(out, vec[i].plain, out_len) == 0,
          "huffman decode mismatch", &failures);
  }
  {
    const uint8_t bad[] = {0xff, 0xff, 0xff};
    uint8_t out[8];
    size_t out_len = 0;
    check(huff_decode(bad, sizeof(bad), out, sizeof(out), &out_len) < 0,
          "huffman bad padding accepted", &failures);
  }
  return failures;
}

static int selftest_integer(void) {
  int failures = 0;
  uint8_t enc[16];
  size_t n;
  uint32_t v;
  int c;

  n = hpack_write_int(enc, sizeof(enc), 10, 5);
  check(n == 1 && enc[0] == 0x0a, "int encode 10/5", &failures);
  c = hpack_read_int(enc, n, 5, &v);
  check(c == 1 && v == 10, "int decode 10/5", &failures);

  n = hpack_write_int(enc, sizeof(enc), 1337, 5);
  check(n == 3 && enc[0] == 0x1f && enc[1] == 0x9a && enc[2] == 0x0a,
        "int encode 1337/5", &failures);
  c = hpack_read_int(enc, n, 5, &v);
  check(c == 3 && v == 1337, "int decode 1337/5", &failures);

  n = hpack_write_int(enc, sizeof(enc), 42, 8);
  check(n == 1 && enc[0] == 0x2a, "int encode 42/8", &failures);
  c = hpack_read_int(enc, n, 8, &v);
  check(c == 1 && v == 42, "int decode 42/8", &failures);

  return failures;
}

static int selftest_static(void) {
  int failures = 0;
  check(static_find_pair(":method", 7, "POST", 4) == 3, "static :method POST",
        &failures);
  check(static_find_pair(":scheme", 7, "http", 4) == 6, "static :scheme http",
        &failures);
  check(static_find_pair(":status", 7, "200", 3) == 8, "static :status 200",
        &failures);
  check(static_find_pair("content-type", 12, "", 0) == 31,
        "static content-type", &failures);
  check(static_find_pair("user-agent", 10, "", 0) == 58, "static user-agent",
        &failures);
  check(static_find_name("te", 2) == 0, "static no 'te'", &failures);
  return failures;
}

static int selftest_dynamic(void) {
  int failures = 0;
  struct hpack_dyn dyn;
  memset(&dyn, 0, sizeof(dyn));
  dyn_reset(&dyn);
  dyn_add(&dyn, (const uint8_t *)"custom-key", 10,
          (const uint8_t *)"custom-header", 13);
  check(dyn.count == 1, "dyn add count", &failures);
  check(dyn_find_pair(&dyn, (const uint8_t *)"custom-key", 10,
                      (const uint8_t *)"custom-header", 13) == 1,
        "dyn pair found", &failures);
  check(dyn_find_pair(&dyn, (const uint8_t *)"custom-key", 10,
                      (const uint8_t *)"other", 5) == 0,
        "dyn pair miss", &failures);
  {
    int i;
    for (i = 0; i < 100; i++) {
      char name[16], value[64];
      snprintf(name, sizeof(name), "k%d", i);
      snprintf(value, sizeof(value),
               "value-padding-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa%d", i);
      dyn_add(&dyn, (const uint8_t *)name, strlen(name),
              (const uint8_t *)value, strlen(value));
    }
    check(dyn.size <= 4096, "dyn size bounded", &failures);
    check(dyn_find_pair(&dyn, (const uint8_t *)"custom-key", 10,
                        (const uint8_t *)"custom-header", 13) == 0,
          "dyn oldest evicted", &failures);
    check(dyn.count <= H2C_DYN_MAX_ENTRIES, "dyn count bounded", &failures);
    check(dyn.count > 0, "dyn not empty after eviction", &failures);
  }
  {
    struct hpack_dyn small;
    memset(&small, 0, sizeof(small));
    dyn_reset(&small);
    dyn_add(&small, (const uint8_t *)"a", 1,
            (const uint8_t *)"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", 32);
    dyn_add(&small, (const uint8_t *)"c", 1,
            (const uint8_t *)"dddddddddddddddddddddddddddddddd", 32);
    check(small.count == 2, "dyn setmax pre", &failures);
    dyn_set_max(&small, 40);
    check(small.size <= 40, "dyn setmax bound", &failures);
    dyn_reset(&small);
  }
  dyn_reset(&dyn);
  return failures;
}

static int selftest_rfc_block(void) {
  int failures = 0;
  static const uint8_t block[] = {
      0x82, 0x86, 0x84, 0x41, 0x0f, 0x77, 0x77, 0x77, 0x2e, 0x65, 0x78,
      0x61, 0x6d, 0x70, 0x6c, 0x65, 0x2e, 0x63, 0x6f, 0x6d};
  struct hpack_dyn dyn;
  struct hpack_field fields[H2C_MAX_FIELDS];
  int n = 0;
  int i;
  memset(&dyn, 0, sizeof(dyn));
  dyn_reset(&dyn);
  if (hpack_decode_block(&dyn, block, sizeof(block), fields, H2C_MAX_FIELDS,
                         &n) < 0) {
    check(0, "rfc block decode", &failures);
    return failures;
  }
  check(n == 4, "rfc block field count", &failures);
  for (i = 0; i < n; i++) {
    if (header_name_eq(&fields[i], ":method"))
      check(header_value_eq(&fields[i], "GET"), "rfc :method GET", &failures);
    else if (header_name_eq(&fields[i], ":scheme"))
      check(header_value_eq(&fields[i], "http"), "rfc :scheme http",
            &failures);
    else if (header_name_eq(&fields[i], ":path"))
      check(header_value_eq(&fields[i], "/"), "rfc :path /", &failures);
    else if (header_name_eq(&fields[i], ":authority"))
      check(header_value_eq(&fields[i], "www.example.com"), "rfc :authority",
            &failures);
  }
  hpack_free_fields(fields, n);
  dyn_reset(&dyn);
  return failures;
}

static int selftest_frame_roundtrip(void) {
  int failures = 0;
  uint8_t payload[8] = {0, 1, 2, 3, 4, 5, 6, 7};
  uint8_t wire[64];
  struct frame_reader r;
  int sv[2];
  memset(&r, 0, sizeof(r));

  {
    uint8_t hdr[9];
    size_t len = 8;
    hdr[0] = (uint8_t)(len >> 16);
    hdr[1] = (uint8_t)(len >> 8);
    hdr[2] = (uint8_t)len;
    hdr[3] = H2_DATA;
    hdr[4] = H2_FLAG_END_STREAM;
    hdr[5] = 0;
    hdr[6] = 0;
    hdr[7] = 0;
    hdr[8] = 3;
    memcpy(wire, hdr, 9);
    memcpy(wire + 9, payload, 8);
  }
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) {
    check(0, "socketpair", &failures);
    return failures;
  }
  if (write_all(sv[0], wire, 17) < 0)
    check(0, "frame write", &failures);
  {
    int rc;
    int steps = 0;
    do {
      rc = frame_reader_fill(&r, sv[1]);
      steps++;
    } while (rc == 0 && steps < 64);
    check(rc == 1, "frame read completes", &failures);
    check(r.type == H2_DATA, "frame type", &failures);
    check(r.flags == H2_FLAG_END_STREAM, "frame flags", &failures);
    check(r.sid == 3, "frame sid", &failures);
    check(r.payload_fill == 8 && memcmp(r.payload, payload, 8) == 0,
          "frame payload", &failures);
  }
  free(r.payload);
  close(sv[0]);
  close(sv[1]);
  return failures;
}

int h2c_selftest(int verbose) {
  int failures = 0;
  int n;

  n = selftest_huffman();
  if (verbose)
    printf("H2C SELFTEST huffman: %s\n", n ? "FAIL" : "PASS");
  failures += n;

  n = selftest_integer();
  if (verbose)
    printf("H2C SELFTEST integer: %s\n", n ? "FAIL" : "PASS");
  failures += n;

  n = selftest_static();
  if (verbose)
    printf("H2C SELFTEST static-table: %s\n", n ? "FAIL" : "PASS");
  failures += n;

  n = selftest_dynamic();
  if (verbose)
    printf("H2C SELFTEST dynamic-table: %s\n", n ? "FAIL" : "PASS");
  failures += n;

  n = selftest_rfc_block();
  if (verbose)
    printf("H2C SELFTEST rfc7541-block: %s\n", n ? "FAIL" : "PASS");
  failures += n;

  n = selftest_frame_roundtrip();
  if (verbose)
    printf("H2C SELFTEST frame-io: %s\n", n ? "FAIL" : "PASS");
  failures += n;

  if (verbose)
    printf("H2C SELFTEST total: %d failures\n", failures);
  return failures;
}