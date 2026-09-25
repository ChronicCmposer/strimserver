/*
 * containerd_client_test.c — scratch tests for the containerd lane.
 *
 * Wave 1 (containerd lane). Daemon-free tests that exercise:
 *
 *   1. h2c_selftest: HPACK (Huffman, integer coding, static/dynamic tables,
 *      the RFC 7541 request block) and frame I/O unit vectors.
 *   2. A fake h2c/grpc server over a unix socketpair: a full unary RPC
 *      (request headers + gRPC-framed DATA out, response HEADERS with
 *      Huffman-coded content-type + DATA + trailers in) and a full
 *      server-streaming RPC (two gRPC-framed event envelopes + clean end).
 *   3. The end-to-end event pipeline: strim_containerd_connect +
 *      strim_containerd_subscribe against the fake server, envelope decode,
 *      and typeurl dispatch (TaskStart -> Running / TaskExit -> Stopped +
 *      container id extraction).
 *   4. Nanopb service-call round-trips: GetImageRequest, CreateContainer
 *      with the OCI-spec Any, CreateTaskRequest with rootfs mounts,
 *      SubscribeRequest, WaitResponse, and the TaskExit envelope.
 *   5. The OCI spec JSON builder (oci.GenerateSpec reproduction).
 *   6. The image rootfs chain-ID computation (identity.ChainID vectors).
 *   7. The Task-18 lifecycle ops: a scripted fake server walks the start
 *      sequence (GetImage -> Content/Read -> Snapshots/Prepare ->
 *      Containers/Create -> Snapshots/Mounts -> Tasks/Create -> Tasks/Start)
 *      and the stop sequence (Containers/Get -> Tasks/Get -> Tasks/Wait on a
 *      dedicated connection -> Tasks/Kill -> Tasks/Delete ->
 *      Snapshots/Remove -> Containers/Delete), plus the force-delete path
 *      (Kill SIGKILL All=true -> Wait -> Delete).
 *   8. The client's internal mutex: K worker threads call GetImage on the
 *      SAME client concurrently; the fake server sees K clean sequential
 *      requests and every thread decodes its own response.
 *
 * strim_default_unix_env / strim_default_layout are declared by spec.h and
 * DEFINED by the core lane (//core/controller/c/core:core_lib); this TU
 * never redefines them (the pre-core stall did — duplicate symbol).
 *
 * License: project code (see LICENSE). No GPL.
 */

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "containerd_client.h"
#include "cdi.h"
#include "h2c.h"
#include "oci_spec.h"
#include "sha256.h"
#include "minipb.h"

#include <yyjson.h>

#include <pb.h>
#include <pb_decode.h>
#include <pb_encode.h>

#include <google/protobuf/any.pb.h>
#include <google/protobuf/timestamp.pb.h>
#include <services/containers/v1/containers.pb.h>
#include <services/events/v1/events.pb.h>
#include <services/images/v1/images.pb.h>
#include <services/tasks/v1/tasks.pb.h>
#include <types/event.pb.h>
#include <types/mount.pb.h>
#include <events/task.pb.h>

/* stdio.h defines stdout/stderr as macros (musl, unconditional); they clash
 * with the nanopb CreateTaskRequest.stdout/.stderr fields used below. */
#undef stdout
#undef stderr

static int failures = 0;

#define CHECK(cond)                                                       \
    do {                                                                  \
        if (!(cond)) {                                                    \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            failures++;                                                   \
        }                                                                 \
    } while (0)

/* =========================================================================
 * Fake h2c/grpc server
 * ========================================================================= */

static int read_exact(int fd, void *buf, size_t len) {
  uint8_t *p = (uint8_t *)buf;
  while (len > 0) {
    ssize_t n = read(fd, p, len);
    if (n <= 0)
      return -1;
    p += n;
    len -= (size_t)n;
  }
  return 0;
}

static int write_exact(int fd, const void *buf, size_t len) {
  const uint8_t *p = (const uint8_t *)buf;
  while (len > 0) {
    ssize_t n = write(fd, p, len);
    if (n <= 0)
      return -1;
    p += n;
    len -= (size_t)n;
  }
  return 0;
}

static void frame_write_fake(int fd, uint8_t type, uint8_t flags, uint32_t sid,
                             const void *payload, size_t len) {
  uint8_t hdr[9];
  hdr[0] = (uint8_t)(len >> 16);
  hdr[1] = (uint8_t)(len >> 8);
  hdr[2] = (uint8_t)len;
  hdr[3] = type;
  hdr[4] = flags;
  hdr[5] = (uint8_t)(sid >> 24);
  hdr[6] = (uint8_t)(sid >> 16);
  hdr[7] = (uint8_t)(sid >> 8);
  hdr[8] = (uint8_t)sid;
  write_exact(fd, hdr, 9);
  if (len)
    write_exact(fd, payload, len);
}

struct fake_conn {
  int fd;             /* first accepted connection */
  int listener_fd;    /* the listening socket (for connection 2) */
  int stream_id;
  const uint8_t *envelopes[4];
  size_t envelope_lens[4];
  int n_envelopes;
};

static void fake_read_preface(int fd) {
  uint8_t buf[24];
  CHECK(read_exact(fd, buf, 24) == 0);
  CHECK(memcmp(buf, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", 24) == 0);
}

static void fake_handshake(int fd, int *peer_stream_id) {
  uint8_t hdr[9];
  uint32_t len;
  uint8_t type;
  uint8_t flags;
  uint32_t sid;
  uint8_t payload[256];
  int saw_settings = 0;

  fake_read_preface(fd);
  /* Read the client's SETTINGS frame(s). */
  for (int i = 0; i < 8; i++) {
    CHECK(read_exact(fd, hdr, 9) == 0);
    len = ((uint32_t)hdr[0] << 16) | ((uint32_t)hdr[1] << 8) | hdr[2];
    type = hdr[3];
    flags = hdr[4];
    sid = ((uint32_t)hdr[5] << 24) | ((uint32_t)hdr[6] << 16) |
          ((uint32_t)hdr[7] << 8) | hdr[8];
    (void)sid;
    if (len)
      CHECK(read_exact(fd, payload, len > sizeof(payload) ? sizeof(payload) : len) == 0);
    if (type == 4 && (flags & 0x1) == 0) { /* SETTINGS, not ACK */
      saw_settings = 1;
      /* ACK the client's SETTINGS and send our own. */
      frame_write_fake(fd, 4, 0x1, 0, NULL, 0);
      frame_write_fake(fd, 4, 0, 0, NULL, 0);
      break;
    }
  }
  CHECK(saw_settings);
  (void)peer_stream_id; /* the caller keeps its own stream id */
}

/* Read a HEADERS + DATA request; returns the DATA payload length and the
 * request's stream id. */
static size_t fake_read_request_sid(int fd, uint8_t *req, size_t req_cap,
                                    uint32_t *req_sid) {
  uint8_t hdr[9];
  size_t total = 0;
  for (;;) {
    uint32_t len;
    uint8_t type;
    uint8_t flags;
    uint32_t sid;
    uint8_t payload[4096];
    if (read_exact(fd, hdr, 9) != 0)
      return (size_t)-1; /* client closed the connection */
    len = ((uint32_t)hdr[0] << 16) | ((uint32_t)hdr[1] << 8) | hdr[2];
    type = hdr[3];
    flags = hdr[4];
    sid = ((uint32_t)hdr[5] << 24) | ((uint32_t)hdr[6] << 16) |
          ((uint32_t)hdr[7] << 8) | hdr[8];
    if (req_sid != NULL)
      *req_sid = sid;
    if (len > sizeof(payload))
      CHECK(0 && "fake server payload too big");
    if (len && read_exact(fd, payload, len) != 0)
      return (size_t)-1;
    if (type == 0) { /* DATA: skip the 5-byte gRPC header */
      size_t data = len > 5 ? len - 5 : 0;
      if (total + data <= req_cap)
        memcpy(req + total, payload + 5, data);
      total += data;
      if (flags & 0x1)
        break;
    } else if (type == 8) { /* WINDOW_UPDATE */
      /* ignore */
    }
  }
  return total;
}

/* A response HEADERS block: :status 200 (indexed 8) + content-type
 * application/grpc (literal indexed name 31, Huffman value). */
static const uint8_t RESP_HEADERS[] = {
    0x88, 0x5f, 0x8b, 0x1d, 0x75, 0xd0, 0x62, 0x0d, 0x26, 0x3d, 0x4c, 0x4d,
    0x65, 0x64};

/* Trailers block: grpc-status "0" (literal without indexing, new Huffman
 * name "grpc-status", plain value "0"). */
static const uint8_t TRAILERS_OK[] = {
    0x00, 0x88, 0x9a, 0xca, 0xc8, 0xb2, 0x12, 0x34, 0xda, 0x8f, 0x01, 0x30};

/* grpc-status Huffman code for "grpc-status" (RFC 7541 Appendix C). */
static const uint8_t HUFF_GRPC_STATUS[] = {0x9a, 0xca, 0xc8, 0xb2,
                                           0x12, 0x34, 0xda, 0x8f};

/* grpc-message Huffman code for "grpc-message" (9 bytes; the exact encoding
 * grpc-go emits — h2c.c's selftest_huffman vector proves it decodes). */
static const uint8_t HUFF_GRPC_MESSAGE[] = {0x9a, 0xca, 0xc8, 0xb5, 0x25,
                                            0x42, 0x07, 0x31, 0x7f};

/* Build a trailers-only block carrying a single grpc-status (any 0..99). */
static void build_trailers_status(uint8_t *out, size_t *len, int status) {
  char sval[8];
  size_t slen;
  snprintf(sval, sizeof sval, "%d", status);
  slen = strlen(sval);
  out[0] = 0x00; /* literal without indexing, new name */
  out[1] = 0x88; /* Huffman, 8 bytes */
  memcpy(out + 2, HUFF_GRPC_STATUS, 8);
  out[10] = (uint8_t)slen; /* plain value */
  memcpy(out + 11, sval, slen);
  *len = 11 + slen;
}

/* Build a trailers-only block carrying grpc-status (any 0..99) and a plain
 * grpc-message. Both names are Huffman-coded (the encodings grpc-go emits
 * for a trailers-only error response). */
static void build_trailers_status_msg(uint8_t *out, size_t *len, int status,
                                      const char *msg) {
  char sval[8];
  size_t slen;
  size_t msglen = strlen(msg);
  snprintf(sval, sizeof sval, "%d", status);
  slen = strlen(sval);
  out[0] = 0x00; /* literal without indexing, new name */
  out[1] = 0x88; /* Huffman, 8 bytes */
  memcpy(out + 2, HUFF_GRPC_STATUS, 8);
  out[10] = (uint8_t)slen; /* plain value */
  memcpy(out + 11, sval, slen);
  out[11 + slen] = 0x00; /* literal without indexing, new name */
  out[12 + slen] = 0x89; /* Huffman, 9 bytes */
  memcpy(out + 13 + slen, HUFF_GRPC_MESSAGE, 9);
  out[22 + slen] = (uint8_t)msglen; /* plain value */
  memcpy(out + 23 + slen, msg, msglen);
  *len = 23 + slen + msglen;
}

static void fake_grpc_frame(uint8_t *out, const uint8_t *msg, uint32_t len) {
  out[0] = 0;
  out[1] = (uint8_t)(len >> 24);
  out[2] = (uint8_t)(len >> 16);
  out[3] = (uint8_t)(len >> 8);
  out[4] = (uint8_t)len;
  if (len)
    memcpy(out + 5, msg, len);
}

/* Serve a unary RPC on a fresh accepted connection: request in -> response
 * (0xAA 0xBB 0xCC) -> trailers. */
static void *fake_server_unary(void *arg) {
  struct fake_conn *fc = (struct fake_conn *)arg;
  struct sockaddr_un addr;
  socklen_t alen = sizeof(addr);
  int fd = accept(fc->listener_fd, (struct sockaddr *)&addr, &alen);
  uint8_t req[512];
  uint8_t frame[64];
  uint32_t req_sid = 1;

  CHECK(fd >= 0);
  if (fd < 0)
    return NULL;
  fake_handshake(fd, &fc->stream_id);
  fake_read_request_sid(fd, req, sizeof(req), &req_sid);

  frame_write_fake(fd, 1, 0x4, req_sid, RESP_HEADERS, sizeof(RESP_HEADERS));
  {
    uint8_t body[] = {0xAA, 0xBB, 0xCC};
    fake_grpc_frame(frame, body, 3);
    frame_write_fake(fd, 0, 0, req_sid, frame, 8);
  }
  frame_write_fake(fd, 1, 0x5, req_sid, TRAILERS_OK, sizeof(TRAILERS_OK));
  close(fd);
  return NULL;
}

/* Serve a streaming RPC on a fresh accepted connection: request in ->
 * headers -> n_envelopes DATA frames -> clean trailers. */
static void *fake_server_stream(void *arg) {
  struct fake_conn *fc = (struct fake_conn *)arg;
  struct sockaddr_un addr;
  socklen_t alen = sizeof(addr);
  int fd = accept(fc->listener_fd, (struct sockaddr *)&addr, &alen);
  uint8_t req[512];
  uint32_t req_sid = 1;
  int i;

  CHECK(fd >= 0);
  if (fd < 0)
    return NULL;
  fake_handshake(fd, &fc->stream_id);
  fake_read_request_sid(fd, req, sizeof(req), &req_sid);

  frame_write_fake(fd, 1, 0x4, req_sid, RESP_HEADERS, sizeof(RESP_HEADERS));
  for (i = 0; i < fc->n_envelopes; i++) {
    uint8_t frame[512];
    fake_grpc_frame(frame, fc->envelopes[i], fc->envelope_lens[i]);
    frame_write_fake(fd, 0, 0, req_sid, frame, 5 + fc->envelope_lens[i]);
  }
  frame_write_fake(fd, 1, 0x5, req_sid, TRAILERS_OK, sizeof(TRAILERS_OK));
  /* A real daemon keeps the event-stream connection open until the client
   * cancels it. Hold the socket open (drain frames until EOF) instead of
   * closing right after the trailers: an immediate FIN races the client's
   * frame reader, which can report the queued messages as a spurious IO
   * error (h2c_stream_next surfaces the connection death before draining
   * messages already read in the same poll). */
  {
    uint8_t discard[64];
    while (read(fd, discard, sizeof(discard)) > 0)
      ;
  }
  close(fd);
  return NULL;
}

/* The subscribe test (test_event_pipeline) uses fake_server_stream above:
 * under the Wave 3 lazy-connect contract the connect never dials, so the
 * event stream's own per-call connection is the FIRST connection the client
 * opens. The old eager-connect ordering (conn 1 = eager dial at connect,
 * conn 2 = event stream) no longer exists. */

/* =========================================================================
 * Bug A fixture: a server-streaming peer that delivers N messages and then
 * closes IMMEDIATELY (trailers + FIN in the same poll). This is exactly what
 * a dying containerd daemon does: the client's conn_poll_once budget pass
 * queues the DATA messages, processes the trailers, then hits EOF and
 * reports a negative result. h2c_stream_next must drain the queued messages
 * and report the finished stream BEFORE surfacing the IO error.
 *
 * Unlike fake_server_stream (which deliberately holds the socket open to
 * dodge this race), this fixture waits for a go signal so the response is
 * never absorbed by h2c_stream_open's grace poll, writes the whole response,
 * then closes and signals done. The test waits for done before the first
 * h2c_stream_next, so the client's FIRST poll provably sees every frame AND
 * the EOF in one conn_poll_once budget pass — the bug, made deterministic.
 * ========================================================================= */

struct fake_conn_fin {
  int listener_fd;
  int stream_id;
  const uint8_t *envelopes[8];
  size_t envelope_lens[8];
  int n_envelopes;
  pthread_mutex_t mu;
  pthread_cond_t cv;
  int go;   /* test -> server: write the response and close now */
  int done; /* server -> test: response written and socket closed */
};

static void *fake_server_stream_fin(void *arg) {
  struct fake_conn_fin *fc = (struct fake_conn_fin *)arg;
  struct sockaddr_un addr;
  socklen_t alen = sizeof(addr);
  int fd = accept(fc->listener_fd, (struct sockaddr *)&addr, &alen);
  uint8_t req[512];
  uint32_t req_sid = 1;
  int i;

  CHECK(fd >= 0);
  if (fd < 0)
    return NULL;
  fake_handshake(fd, &fc->stream_id);
  fake_read_request_sid(fd, req, sizeof(req), &req_sid);

  /* Hold the response until the test has finished h2c_stream_open's grace
   * window: if the frames arrived during that poll, stream_open would absorb
   * the death and the queue-drain path would hide the bug. */
  pthread_mutex_lock(&fc->mu);
  while (!fc->go)
    pthread_cond_wait(&fc->cv, &fc->mu);
  pthread_mutex_unlock(&fc->mu);

  frame_write_fake(fd, 1, 0x4, req_sid, RESP_HEADERS, sizeof(RESP_HEADERS));
  for (i = 0; i < fc->n_envelopes; i++) {
    uint8_t frame[512];
    fake_grpc_frame(frame, fc->envelopes[i], fc->envelope_lens[i]);
    frame_write_fake(fd, 0, 0, req_sid, frame, 5 + fc->envelope_lens[i]);
  }
  frame_write_fake(fd, 1, 0x5, req_sid, TRAILERS_OK, sizeof(TRAILERS_OK));
  /* Close right after the trailers: the client's next poll sees every frame
   * AND the EOF in one budget pass (the Bug A death). */
  close(fd);

  pthread_mutex_lock(&fc->mu);
  fc->done = 1;
  pthread_cond_signal(&fc->cv);
  pthread_mutex_unlock(&fc->mu);
  return NULL;
}

/* =========================================================================
 * Scripted fake server (lifecycle tests): serves a scripted sequence of
 * RPCs. FS_UNARY / FS_STREAM steps are served on the current connection;
 * FS_NEWCONN accepts a fresh connection (a dedicated Task Wait) for that one
 * step. FS_ERR sends trailers-only with a grpc-status.
 * ========================================================================= */

enum fstep_kind {
  FS_UNARY,   /* HEADERS + DATA(body) + TRAILERS(0)              */
  FS_STREAM,  /* HEADERS + n DATA msgs + TRAILERS(0)             */
  FS_NEWCONN, /* accept a fresh connection; serve this step there */
  FS_ERR,     /* trailers-only with grpc-status                  */
};

struct fstep {
  enum fstep_kind kind;
  const uint8_t *body;       /* FS_UNARY / FS_NEWCONN: gRPC message body   */
  uint32_t body_len;
  const uint8_t *const *msgs; /* FS_STREAM: gRPC message bodies             */
  size_t n_msgs;
  uint32_t *msg_lens;
  int grpc_status;           /* FS_ERR                                      */
  const char *grpc_message;  /* FS_ERR: optional grpc-message               */
};

struct script_arg {
  int listener_fd;
  const struct fstep *script;
  size_t n_steps;
  int *request_count; /* optional; incremented per request served */
  /* Optional: copy the request body of one step (e.g. Containers/Create, to
   * inspect the OCI spec JSON it carries) into the caller's buffer. */
  size_t capture_step;   /* step index whose request body is copied */
  uint8_t *capture_body; /* caller-owned buffer                     */
  size_t *capture_len;   /* caller-owned length out (bytes copied)  */
  size_t capture_cap;    /* capture_body capacity                   */
};

/* Largest gRPC message body a single scripted step frames in one DATA frame
 * (the frame buffer must hold the 5-byte gRPC header plus the body). The
 * flow-control test feeds 16 KiB responses (the old 4 KiB stack buffer
 * overflowed) and the oversized-response tests feed ~17-20 KiB responses
 * that echo a CDI-sized OCI spec / oversized image. */
#define SCRIPT_MAX_BODY (32 * 1024)

static void *scripted_server(void *arg) {
  struct script_arg *sa = (struct script_arg *)arg;
  struct sockaddr_un addr;
  socklen_t alen = sizeof(addr);
  int main_fd;
  int cur_fd;
  int cur_is_main = 1;
  size_t i;

  main_fd = accept(sa->listener_fd, (struct sockaddr *)&addr, &alen);
  CHECK(main_fd >= 0);
  if (main_fd < 0)
    return NULL;
  fake_handshake(main_fd, NULL);
  cur_fd = main_fd;

  for (i = 0; i < sa->n_steps; i++) {
    const struct fstep *st = &sa->script[i];
    uint8_t req[4096];
    uint32_t req_sid = 1;
    size_t j;

    if (st->kind == FS_NEWCONN) {
      cur_fd = accept(sa->listener_fd, (struct sockaddr *)&addr, &alen);
      CHECK(cur_fd >= 0);
      if (cur_fd < 0)
        return NULL;
      fake_handshake(cur_fd, NULL);
      cur_is_main = 0;
    }

    {
      size_t rlen = fake_read_request_sid(cur_fd, req, sizeof(req), &req_sid);
      if (rlen == (size_t)-1)
        break; /* the client went away (e.g. a flow-control stall); stop */
      if (sa->request_count != NULL)
        (*sa->request_count)++;
      if (sa->capture_body != NULL && i == sa->capture_step) {
        size_t copied = rlen < sa->capture_cap ? rlen : sa->capture_cap;
        if (copied > sizeof(req))
          copied = sizeof(req); /* the read buffer caps what was copied */
        memcpy(sa->capture_body, req, copied);
        if (sa->capture_len != NULL)
          *sa->capture_len = copied;
      }
    }

    switch (st->kind) {
    case FS_UNARY:
    case FS_NEWCONN: {
      uint8_t frame[SCRIPT_MAX_BODY + 8];
      frame_write_fake(cur_fd, 1, 0x4, req_sid, RESP_HEADERS,
                       sizeof(RESP_HEADERS));
      fake_grpc_frame(frame, st->body, st->body_len);
      frame_write_fake(cur_fd, 0, 0, req_sid, frame, 5 + st->body_len);
      frame_write_fake(cur_fd, 1, 0x5, req_sid, TRAILERS_OK,
                       sizeof(TRAILERS_OK));
      if (!cur_is_main) {
        close(cur_fd);
        cur_fd = main_fd;
        cur_is_main = 1;
      }
      break;
    }
    case FS_STREAM: {
      uint8_t frame[SCRIPT_MAX_BODY + 8];
      frame_write_fake(cur_fd, 1, 0x4, req_sid, RESP_HEADERS,
                       sizeof(RESP_HEADERS));
      for (j = 0; j < st->n_msgs; j++) {
        fake_grpc_frame(frame, st->msgs[j], st->msg_lens[j]);
        frame_write_fake(cur_fd, 0, 0, req_sid, frame, 5 + st->msg_lens[j]);
      }
      frame_write_fake(cur_fd, 1, 0x5, req_sid, TRAILERS_OK,
                       sizeof(TRAILERS_OK));
      break;
    }
    case FS_ERR: {
      uint8_t trailers[256];
      size_t tlen;
      if (st->grpc_message != NULL)
        build_trailers_status_msg(trailers, &tlen, st->grpc_status,
                                  st->grpc_message);
      else
        build_trailers_status(trailers, &tlen, st->grpc_status);
      frame_write_fake(cur_fd, 1, 0x5, req_sid, trailers, tlen);
      break;
    }
    }
  }

  close(main_fd);
  return NULL;
}

/* Bind a unix listener at a temp path; returns the listening fd and the
 * path (the caller unlinks it after). */
static int temp_listen(char *path, size_t path_cap) {
  char tmpl[] = "/tmp/strim-ctrd-test-XXXXXX";
  int lfd;
  int mfd = mkstemp(tmpl);
  struct sockaddr_un addr;
  if (mfd < 0)
    return -1;
  close(mfd);
  unlink(tmpl);
  lfd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (lfd < 0)
    return -1;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, tmpl, sizeof(addr.sun_path) - 1);
  if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) < 0 ||
      listen(lfd, 4) < 0) {
    close(lfd);
    return -1;
  }
  snprintf(path, path_cap, "%s", tmpl);
  return lfd;
}

/* =========================================================================
 * Nanopb / minipb response builders for the scripted server
 * ========================================================================= */

static void build_image_get_resp(uint8_t *buf, size_t cap, size_t *len) {
  containerd_services_images_v1_GetImageResponse r =
      containerd_services_images_v1_GetImageResponse_init_zero;
  pb_ostream_t os;
  r.has_image = true;
  r.image.name = (char *)"docker.io/library/ffmpeg:latest";
  r.image.has_target = true;
  r.image.target.digest = (char *)"sha256:manifest";
  r.image.target.media_type =
      (char *)"application/vnd.oci.image.manifest.v1+json";
  r.image.target.size = 300;
  os = pb_ostream_from_buffer(buf, cap);
  CHECK(pb_encode(&os, containerd_services_images_v1_GetImageResponse_fields,
                  &r));
  *len = os.bytes_written;
}

static void build_read_resp(uint8_t *buf, size_t cap, size_t *len,
                            const void *data, size_t data_len) {
  mpb_buf b = {0};
  mpb_put_bytes(&b, 2, data, data_len);
  CHECK(b.len <= cap);
  if (b.len > cap) {
    mpb_buf_free(&b);
    *len = 0;
    return;
  }
  memcpy(buf, b.data, b.len);
  *len = b.len;
  mpb_buf_free(&b);
}

static void build_mounts_resp(uint8_t *buf, size_t cap, size_t *len) {
  mpb_buf m = {0}, b = {0};
  mpb_put_string(&m, 1, "overlay");
  mpb_put_string(&m, 2, "overlay");
  mpb_put_string(&m, 3, "/");
  mpb_put_string(&m, 4, "lowerdir=/x");
  mpb_put_string(&m, 4, "upperdir=/y");
  mpb_put_string(&m, 4, "workdir=/z");
  mpb_put_message(&b, 1, &m);
  CHECK(b.len <= cap);
  if (b.len <= cap) {
    memcpy(buf, b.data, b.len);
    *len = b.len;
  } else {
    *len = 0;
  }
  mpb_buf_free(&m);
  mpb_buf_free(&b);
}

static void build_create_container_resp(uint8_t *buf, size_t cap, size_t *len) {
  containerd_services_containers_v1_CreateContainerResponse r =
      containerd_services_containers_v1_CreateContainerResponse_init_zero;
  pb_ostream_t os;
  r.has_container = true;
  r.container.id = (char *)"ctr-1";
  os = pb_ostream_from_buffer(buf, cap);
  CHECK(pb_encode(
      &os, containerd_services_containers_v1_CreateContainerResponse_fields,
      &r));
  *len = os.bytes_written;
}

static void build_get_container_resp(uint8_t *buf, size_t cap, size_t *len) {
  containerd_services_containers_v1_GetContainerResponse r =
      containerd_services_containers_v1_GetContainerResponse_init_zero;
  pb_ostream_t os;
  r.has_container = true;
  r.container.id = (char *)"ctr-1";
  r.container.image = (char *)"docker.io/library/ffmpeg:latest";
  r.container.has_runtime = true;
  r.container.runtime.name = (char *)"io.containerd.runc.v2";
  r.container.snapshotter = (char *)"overlayfs";
  r.container.snapshot_key = (char *)"snap-ctr-1";
  os = pb_ostream_from_buffer(buf, cap);
  CHECK(pb_encode(&os,
                  containerd_services_containers_v1_GetContainerResponse_fields,
                  &r));
  *len = os.bytes_written;
}

static void build_get_task_resp(uint8_t *buf, size_t cap, size_t *len) {
  containerd_services_tasks_v1_GetResponse r =
      containerd_services_tasks_v1_GetResponse_init_zero;
  pb_ostream_t os;
  r.has_process = true;
  r.process.pid = 42;
  os = pb_ostream_from_buffer(buf, cap);
  CHECK(pb_encode(&os, containerd_services_tasks_v1_GetResponse_fields, &r));
  *len = os.bytes_written;
}

static void build_wait_resp(uint8_t *buf, size_t cap, size_t *len,
                            uint32_t code) {
  containerd_services_tasks_v1_WaitResponse r =
      containerd_services_tasks_v1_WaitResponse_init_zero;
  pb_ostream_t os;
  r.exit_status = code;
  os = pb_ostream_from_buffer(buf, cap);
  CHECK(pb_encode(&os, containerd_services_tasks_v1_WaitResponse_fields, &r));
  *len = os.bytes_written;
}

static void build_task_create_resp(uint8_t *buf, size_t cap, size_t *len) {
  containerd_services_tasks_v1_CreateTaskResponse r =
      containerd_services_tasks_v1_CreateTaskResponse_init_zero;
  pb_ostream_t os;
  r.container_id = (char *)"ctr-1";
  r.pid = 42;
  os = pb_ostream_from_buffer(buf, cap);
  CHECK(pb_encode(&os, containerd_services_tasks_v1_CreateTaskResponse_fields,
                  &r));
  *len = os.bytes_written;
}

static void build_start_resp(uint8_t *buf, size_t cap, size_t *len) {
  containerd_services_tasks_v1_StartResponse r =
      containerd_services_tasks_v1_StartResponse_init_zero;
  pb_ostream_t os;
  r.pid = 42;
  os = pb_ostream_from_buffer(buf, cap);
  CHECK(pb_encode(&os, containerd_services_tasks_v1_StartResponse_fields, &r));
  *len = os.bytes_written;
}

static void build_delete_task_resp(uint8_t *buf, size_t cap, size_t *len) {
  containerd_services_tasks_v1_DeleteResponse r =
      containerd_services_tasks_v1_DeleteResponse_init_zero;
  pb_ostream_t os;
  r.id = (char *)"ctr-1";
  r.pid = 42;
  r.exit_status = 0;
  os = pb_ostream_from_buffer(buf, cap);
  CHECK(pb_encode(&os, containerd_services_tasks_v1_DeleteResponse_fields, &r));
  *len = os.bytes_written;
}

/* =========================================================================
 * Oversized-response fixtures (the v1.0.36 CDI createContainer-hook bug)
 *
 * After containerd v1.0.36's CDI createContainer hooks, a container's stored
 * OCI spec grows to ~17.4 KB (55 CDI mounts + 4 device nodes + 6
 * nvidia-cdi-hook hooks), so the Containers/Create RESPONSE — which echoes
 * the full stored spec back as an Any — exceeds the client's old fixed
 * 16 KiB buffer and h2c aborts with H2C_ERR_TOOBIG (folded to
 * STRIM_CTRD_ERR_PROTO by map_grpc_err). The builders below reproduce a
 * CDI-sized spec and the oversized responses that carry it.
 * ========================================================================= */

/* Build a large OCI spec JSON (the post-v1.0.36 nvidia CDI shape: a long
 * bind-mount list plus a createContainer hook and device nodes), sized so a
 * Containers/Create response echoing it exceeds 16 KiB. Returns a malloc'd
 * NUL-terminated string with *out_len set, or NULL. */
static char *build_large_spec_json(size_t *out_len) {
  char *json;
  size_t off = 0;
  size_t cap = 32 * 1024;
  int i;

  *out_len = 0;
  json = (char *)malloc(cap);
  if (json == NULL)
    return NULL;
  off += (size_t)snprintf(
      json + off, cap - off,
      "{\"ociVersion\":\"1.0.2\",\"process\":{"
      "\"args\":[\"/entrypoint.sh\"],\"cwd\":\"/\","
      "\"env\":[\"PATH=/usr/bin\",\"NVIDIA_VISIBLE_DEVICES=all\"]},"
      "\"root\":{\"path\":\"rootfs\"},\"mounts\":[");
  for (i = 0; i < 160; i++) {
    off += (size_t)snprintf(
        json + off, cap - off,
        "%s{\"destination\":\"/var/run/nvidia/device%d\","
        "\"type\":\"bind\",\"source\":\"/dev/nvidia%d\","
        "\"options\":[\"rbind\",\"ro\",\"nosuid\",\"nodev\"]}",
        i ? "," : "", i, i);
  }
  off += (size_t)snprintf(
      json + off, cap - off,
      "],\"hooks\":{\"createContainer\":["
      "{\"path\":\"/usr/bin/nvidia-cdi-hook\","
      "\"args\":[\"nvidia-cdi-hook\",\"create-symlinks\","
      "\"--link\",\"libcuda.so.1\"]}]},"
      "\"linux\":{\"devices\":["
      "{\"path\":\"/dev/nvidia0\",\"type\":\"c\","
      "\"major\":195,\"minor\":0}]}}");
  if (off >= cap) {
    free(json);
    return NULL;
  }
  *out_len = off;
  return json;
}

/* Build a Containers/Create response that echoes a LARGE OCI spec back (the
 * real daemon's Create response carries the full stored container spec as an
 * Any). The encoded response exceeds 16 KiB — the old new_container_locked
 * buffer — so h2c aborted the read with H2C_ERR_TOOBIG even though the
 * daemon accepted the create. */
static void build_create_container_resp_large(uint8_t *buf, size_t cap,
                                              size_t *len) {
  containerd_services_containers_v1_CreateContainerResponse r =
      containerd_services_containers_v1_CreateContainerResponse_init_zero;
  pb_ostream_t os;
  pb_bytes_array_t *spec;
  char *json;
  size_t json_len = 0;

  json = build_large_spec_json(&json_len);
  CHECK(json != NULL && json_len > 16384);
  if (json == NULL) {
    *len = 0;
    return;
  }
  spec = (pb_bytes_array_t *)malloc(PB_BYTES_ARRAY_T_ALLOCSIZE(json_len));
  CHECK(spec != NULL);
  if (spec == NULL) {
    free(json);
    *len = 0;
    return;
  }
  spec->size = (pb_size_t)json_len;
  memcpy(spec->bytes, json, json_len);
  free(json);

  r.has_container = true;
  r.container.id = (char *)"ctr-1";
  r.container.has_spec = true;
  r.container.spec.type_url =
      (char *)"types.containerd.io/opencontainers/runtime-spec/1/Spec";
  r.container.spec.value = spec;
  os = pb_ostream_from_buffer(buf, cap);
  CHECK(pb_encode(
      &os, containerd_services_containers_v1_CreateContainerResponse_fields,
      &r));
  *len = os.bytes_written;
  free(spec);
}

/* Build a GetImageResponse whose image NAME alone exceeds 16 KiB, so the
 * encoded response overruns the client's 16 KiB GetImage buffer and h2c
 * aborts with H2C_ERR_TOOBIG. */
static void build_image_get_resp_large(uint8_t *buf, size_t cap, size_t *len) {
  containerd_services_images_v1_GetImageResponse r =
      containerd_services_images_v1_GetImageResponse_init_zero;
  pb_ostream_t os;
  static char long_name[17001];
  size_t i;

  for (i = 0; i + 1 < sizeof(long_name); i++)
    long_name[i] = (char)('a' + (i % 26));
  long_name[sizeof(long_name) - 1] = '\0';

  r.has_image = true;
  r.image.name = long_name;
  r.image.has_target = true;
  r.image.target.digest = (char *)"sha256:manifest";
  r.image.target.media_type =
      (char *)"application/vnd.oci.image.manifest.v1+json";
  r.image.target.size = 300;
  os = pb_ostream_from_buffer(buf, cap);
  CHECK(pb_encode(&os, containerd_services_images_v1_GetImageResponse_fields,
                  &r));
  *len = os.bytes_written;
}

/* The OCI image manifest (Content/Read #1) and config (Content/Read #2)
 * blobs the start sequence's image-config resolution consumes. */
static const char MANIFEST_JSON[] =
    "{\"schemaVersion\":2,"
    "\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\","
    "\"config\":{\"digest\":\"sha256:cfg\","
    "\"mediaType\":\"application/vnd.oci.image.config.v1+json\",\"size\":200}}";

static const char CONFIG_JSON[] =
    "{\"config\":{\"env\":[\"PATH=/usr/bin\"],"
    "\"entrypoint\":[\"/transcode.sh\"],\"workingdir\":\"/\"},"
    "\"rootfs\":{\"type\":\"layers\","
    "\"diff_ids\":[\"sha256:aaa\",\"sha256:bbb\"]}}";

/* The OCI/Docker image config uses CAPITALIZED keys ("Entrypoint", "Cmd",
 * "Env", "WorkingDir", "User") — the exact shape of the mediamtx image that
 * failed ("Entrypoint":["/entrypoint.sh"], no lowercase spelling). The C
 * parser must read these like the Go oracle's case-insensitive
 * json.Unmarshal. */
static const char CONFIG_JSON_CAPS[] =
    "{\"config\":{\"Env\":[\"PATH=/usr/bin\"],"
    "\"Entrypoint\":[\"/entrypoint.sh\"],"
    "\"Cmd\":[\"--flag\"],"
    "\"WorkingDir\":\"/\","
    "\"User\":\"1000\"},"
    "\"rootfs\":{\"type\":\"layers\","
    "\"diff_ids\":[\"sha256:aaa\",\"sha256:bbb\"]}}";

/* =========================================================================
 * Test 1: h2c self-tests
 * ========================================================================= */
static void test_h2c_selftest(void) {
  int n = h2c_selftest(0);
  CHECK(n == 0);
}

/* =========================================================================
 * Test 2: full unary RPC over the fake server
 * ========================================================================= */
static void test_unary_rpc(void) {
  char path[128];
  int lfd = temp_listen(path, sizeof(path));
  struct fake_conn fc;
  pthread_t th;
  strim_h2c *c = NULL;
  uint8_t req[] = {1, 2, 3};
  uint8_t resp[64];
  uint32_t resp_len = 0;
  int rc;

  CHECK(lfd >= 0);
  if (lfd < 0)
    return;

  memset(&fc, 0, sizeof(fc));
  fc.listener_fd = lfd;
  pthread_create(&th, NULL, fake_server_unary, &fc);

  rc = h2c_connect(&c, path, "test-ns");
  CHECK(rc == 0 && c != NULL);
  if (rc != 0)
    return;
  rc = h2c_unary(c, "/test.Service/Call", req, sizeof(req), resp,
                 sizeof(resp), &resp_len, 5000);
  CHECK(rc == 0);
  CHECK(resp_len == 3 && memcmp(resp, "\xAA\xBB\xCC", 3) == 0);

  h2c_close(c);
  pthread_join(th, NULL);
  close(lfd);
  unlink(path);
}

/* =========================================================================
 * Test 2b (issue m2): a peer that answers with a malformed HPACK header
 * block. The block decodes one field (":status 200" via the static table,
 * which allocates its name and value), then fails mid-field: a literal with
 * an allocated Huffman-decoded name ("grpc-status") but a value string whose
 * declared Huffman length overruns the block. The client must reject the
 * block (protocol violation) and free every partially-decoded buffer —
 * the regression is that handle_header_block returned -1 from the decode
 * path WITHOUT calling hpack_free_fields, leaking the allocations.
 * The leak is asserted by running this test under ASan/LSan.
 * ========================================================================= */

static const uint8_t MALFORMED_HDR_BLOCK[] = {
    0x88,                                        /* indexed 8: ":status 200" */
    0x00,                                        /* literal without indexing */
    0x88, 0x9a, 0xca, 0xc8, 0xb2, 0x12, 0x34, 0xda, 0x8f, /* name "grpc-status" */
    0x88, 0xaa, 0xbb, 0xcc                       /* value: Huffman len 8, only 3 present */
};

static void *fake_server_malformed_hpack(void *arg) {
  struct fake_conn *fc = (struct fake_conn *)arg;
  struct sockaddr_un addr;
  socklen_t alen = sizeof(addr);
  int fd = accept(fc->listener_fd, (struct sockaddr *)&addr, &alen);
  uint8_t req[512];
  uint32_t req_sid = 1;

  CHECK(fd >= 0);
  if (fd < 0)
    return NULL;
  fake_handshake(fd, &fc->stream_id);
  fake_read_request_sid(fd, req, sizeof(req), &req_sid);
  frame_write_fake(fd, 1, 0x4, req_sid, MALFORMED_HDR_BLOCK,
                   sizeof(MALFORMED_HDR_BLOCK));
  close(fd);
  return NULL;
}

static void test_malformed_hpack_no_leak(void) {
  char path[128];
  int lfd = temp_listen(path, sizeof(path));
  struct fake_conn fc;
  pthread_t th;
  strim_h2c *c = NULL;
  uint8_t req[] = {1, 2, 3};
  uint8_t resp[64];
  uint32_t resp_len = 0;
  int rc;

  CHECK(lfd >= 0);
  if (lfd < 0)
    return;

  memset(&fc, 0, sizeof(fc));
  fc.listener_fd = lfd;
  pthread_create(&th, NULL, fake_server_malformed_hpack, &fc);

  rc = h2c_connect(&c, path, "test-ns");
  CHECK(rc == 0 && c != NULL);
  if (rc != 0)
    return;
  rc = h2c_unary(c, "/test.Service/Call", req, sizeof(req), resp,
                 sizeof(resp), &resp_len, 5000);
  /* The malformed response block kills the connection: conn_fail marks the
   * stream done with gRPC UNAVAILABLE and surfaces H2C_ERR_PROTO internally,
   * which h2c_unary reports as the stream's final status. The interesting
   * assertion here is the ABSENCE of a leak on this decode-error path —
   * verified by an ASan/LSan run. */
  CHECK(rc == H2C_STATUS_UNAVAILABLE);

  h2c_close(c);
  pthread_join(th, NULL);
  close(lfd);
  unlink(path);
}

/* =========================================================================
 * Test 3: server-streaming RPC over the fake server
 * ========================================================================= */
static void test_stream_rpc(void) {
  char path[128];
  int lfd = temp_listen(path, sizeof(path));
  struct fake_conn fc;
  pthread_t th;
  strim_h2c *c = NULL;
  strim_h2c_stream *st = NULL;
  const uint8_t *msg;
  uint32_t len;
  int rc;

  CHECK(lfd >= 0);
  if (lfd < 0)
    return;

  /* Build two envelope messages with nanopb. */
  {
    containerd_events_TaskStart ts = containerd_events_TaskStart_init_zero;
    uint8_t tsbuf[64];
    pb_ostream_t os = pb_ostream_from_buffer(tsbuf, sizeof(tsbuf));
    ts.container_id = "ctr-1";
    ts.pid = 42;
    CHECK(pb_encode(&os, containerd_events_TaskStart_fields, &ts));

    containerd_types_Envelope env = containerd_types_Envelope_init_zero;
    static uint8_t envbuf[128];
    pb_ostream_t eos = pb_ostream_from_buffer(envbuf, sizeof(envbuf));
    env.has_event = true;
    env.event.type_url = "containerd.events.TaskStart";
    PB_BYTES_ARRAY_T(64) ev;
    ev.size = (pb_size_t)os.bytes_written;
    memcpy(ev.bytes, tsbuf, os.bytes_written);
    env.event.value = (pb_bytes_array_t *)&ev;
    CHECK(pb_encode(&eos, containerd_types_Envelope_fields, &env));

    fc.envelopes[0] = envbuf;
    fc.envelope_lens[0] = eos.bytes_written;
    fc.n_envelopes = 1;
  }

  fc.listener_fd = lfd;
  pthread_create(&th, NULL, fake_server_stream, &fc);

  rc = h2c_connect(&c, path, "test-ns");
  CHECK(rc == 0 && c != NULL);
  if (rc != 0)
    return;
  rc = h2c_stream_open(c, "/containerd.services.events.v1.Events/Subscribe",
                       NULL, 0, &st);
  CHECK(rc == 0 && st != NULL);

  rc = h2c_stream_next(st, 5000, &msg, &len);
  CHECK(rc == 0 && len == fc.envelope_lens[0]);
  rc = h2c_stream_next(st, 5000, &msg, &len);
  CHECK(rc == H2C_ERR_STREAM_END);

  h2c_stream_close(st);
  h2c_close(c);
  pthread_join(th, NULL);
  close(lfd);
  unlink(path);
}

/* =========================================================================
 * Test 3b (Bug A): a peer that delivers N messages and then closes right
 * after the trailers (trailers + FIN in the same poll) must deliver all N
 * queued messages BEFORE reporting the terminal state — never a stranding
 * IO error on the first read.
 *
 * Regression: h2c_stream_next returned H2C_ERR_IO on the negative
 * conn_poll_once result without re-checking s->q_head / s->state, so a
 * daemon dying mid-stream lost the last queued events (observed next1 -> IO,
 * next2 -> TaskStart, next3 -> TaskExit).
 * ========================================================================= */
static void test_stream_next_after_peer_fin(void) {
  char path[128];
  int lfd = temp_listen(path, sizeof(path));
  struct fake_conn_fin fc;
  pthread_t th;
  strim_h2c *c = NULL;
  strim_h2c_stream *st = NULL;
  const uint8_t *msg;
  uint32_t len;
  int rc;
  int i;

  CHECK(lfd >= 0);
  if (lfd < 0)
    return;

  memset(&fc, 0, sizeof(fc));
  fc.listener_fd = lfd;
  pthread_mutex_init(&fc.mu, NULL);
  pthread_cond_init(&fc.cv, NULL);

  /* Three distinct envelopes so every delivered message is verifiable. */
  {
    containerd_events_TaskStart ts = containerd_events_TaskStart_init_zero;
    containerd_events_TaskExit te = containerd_events_TaskExit_init_zero;
    containerd_events_TaskStart ts2 = containerd_events_TaskStart_init_zero;
    uint8_t tsbuf[64], tebuf[64], ts2buf[64];
    pb_ostream_t os;
    size_t ts_len, te_len, ts2_len;
    static uint8_t b1[128], b2[128], b3[128];
    pb_ostream_t eos;

    ts.container_id = "ctr-1";
    ts.pid = 42;
    os = pb_ostream_from_buffer(tsbuf, sizeof(tsbuf));
    CHECK(pb_encode(&os, containerd_events_TaskStart_fields, &ts));
    ts_len = os.bytes_written;

    te.container_id = "ctr-1";
    te.pid = 42;
    te.exit_status = 0;
    os = pb_ostream_from_buffer(tebuf, sizeof(tebuf));
    CHECK(pb_encode(&os, containerd_events_TaskExit_fields, &te));
    te_len = os.bytes_written;

    ts2.container_id = "ctr-2";
    ts2.pid = 43;
    os = pb_ostream_from_buffer(ts2buf, sizeof(ts2buf));
    CHECK(pb_encode(&os, containerd_events_TaskStart_fields, &ts2));
    ts2_len = os.bytes_written;

    {
      containerd_types_Envelope env = containerd_types_Envelope_init_zero;
      PB_BYTES_ARRAY_T(64) v1;
      env.namespace = "strimserver";
      env.topic = "/tasks/start";
      env.has_event = true;
      env.event.type_url = "containerd.events.TaskStart";
      v1.size = (pb_size_t)ts_len;
      memcpy(v1.bytes, tsbuf, ts_len);
      env.event.value = (pb_bytes_array_t *)&v1;
      eos = pb_ostream_from_buffer(b1, sizeof(b1));
      CHECK(pb_encode(&eos, containerd_types_Envelope_fields, &env));
      fc.envelopes[0] = b1;
      fc.envelope_lens[0] = eos.bytes_written;
    }

    {
      containerd_types_Envelope env = containerd_types_Envelope_init_zero;
      PB_BYTES_ARRAY_T(64) v2;
      env.namespace = "strimserver";
      env.topic = "/tasks/exit";
      env.has_event = true;
      env.event.type_url = "containerd.events.TaskExit";
      v2.size = (pb_size_t)te_len;
      memcpy(v2.bytes, tebuf, te_len);
      env.event.value = (pb_bytes_array_t *)&v2;
      eos = pb_ostream_from_buffer(b2, sizeof(b2));
      CHECK(pb_encode(&eos, containerd_types_Envelope_fields, &env));
      fc.envelopes[1] = b2;
      fc.envelope_lens[1] = eos.bytes_written;
    }

    {
      containerd_types_Envelope env = containerd_types_Envelope_init_zero;
      PB_BYTES_ARRAY_T(64) v3;
      env.namespace = "strimserver";
      env.topic = "/tasks/start";
      env.has_event = true;
      env.event.type_url = "containerd.events.TaskStart";
      v3.size = (pb_size_t)ts2_len;
      memcpy(v3.bytes, ts2buf, ts2_len);
      env.event.value = (pb_bytes_array_t *)&v3;
      eos = pb_ostream_from_buffer(b3, sizeof(b3));
      CHECK(pb_encode(&eos, containerd_types_Envelope_fields, &env));
      fc.envelopes[2] = b3;
      fc.envelope_lens[2] = eos.bytes_written;
    }
    fc.n_envelopes = 3;
  }

  pthread_create(&th, NULL, fake_server_stream_fin, &fc);

  rc = h2c_connect(&c, path, "test-ns");
  CHECK(rc == 0 && c != NULL);
  if (rc != 0)
    return;
  rc = h2c_stream_open(c, "/containerd.services.events.v1.Events/Subscribe",
                       NULL, 0, &st);
  CHECK(rc == 0 && st != NULL);
  if (rc != 0)
    return;

  /* Release the server; it writes everything and closes. Wait for the close
   * so the client's first h2c_stream_next poll provably sees all frames AND
   * the EOF together (the Bug A death, made deterministic). */
  pthread_mutex_lock(&fc.mu);
  fc.go = 1;
  pthread_cond_signal(&fc.cv);
  while (!fc.done)
    pthread_cond_wait(&fc.cv, &fc.mu);
  pthread_mutex_unlock(&fc.mu);

  /* All N messages must arrive BEFORE the terminal STREAM_END. Bug A
   * returned H2C_ERR_IO on the first call and stranded the queue. */
  for (i = 0; i < fc.n_envelopes; i++) {
    rc = h2c_stream_next(st, 5000, &msg, &len);
    CHECK(rc == 0);
    CHECK(len == fc.envelope_lens[i]);
    CHECK(memcmp(msg, fc.envelopes[i], len) == 0);
  }
  rc = h2c_stream_next(st, 5000, &msg, &len);
  CHECK(rc == H2C_ERR_STREAM_END);

  h2c_stream_close(st);
  h2c_close(c);
  pthread_join(th, NULL);
  close(lfd);
  unlink(path);
  pthread_cond_destroy(&fc.cv);
  pthread_mutex_destroy(&fc.mu);
}

/* =========================================================================
 * Test 4: end-to-end event pipeline (lazy connect + subscribe + typeurl
 * dispatch). The connect never dials (Wave 3 lazy contract); the event
 * stream's own per-call connection is the first connection the client opens,
 * and fake_server_stream serves the subscribe on it.
 * ========================================================================= */
static void test_event_pipeline(void) {
  char path[128];
  int lfd = temp_listen(path, sizeof(path));
  struct fake_conn fc;
  pthread_t th;
  strim_containerd_client *client = NULL;
  strim_event_stream *stream = NULL;
  strim_event_envelope *env;
  const char *filters[] = {"topic~=\"/tasks/.*\""};
  int rc;

  CHECK(lfd >= 0);
  if (lfd < 0)
    return;

  /* Two envelopes: TaskStart then TaskExit. */
  {
    containerd_events_TaskStart ts = containerd_events_TaskStart_init_zero;
    containerd_events_TaskExit te = containerd_events_TaskExit_init_zero;
    uint8_t tsbuf[64], tebuf[64];
    pb_ostream_t os;
    size_t ts_len, te_len;

    ts.container_id = "scale-and-egress";
    ts.pid = 100;
    os = pb_ostream_from_buffer(tsbuf, sizeof(tsbuf));
    CHECK(pb_encode(&os, containerd_events_TaskStart_fields, &ts));
    ts_len = os.bytes_written;

    te.container_id = "scale-and-egress";
    te.pid = 100;
    te.exit_status = 0;
    os = pb_ostream_from_buffer(tebuf, sizeof(tebuf));
    CHECK(pb_encode(&os, containerd_events_TaskExit_fields, &te));
    te_len = os.bytes_written;

    {
      containerd_types_Envelope env1 = containerd_types_Envelope_init_zero;
      containerd_types_Envelope env2 = containerd_types_Envelope_init_zero;
      static uint8_t b1[128], b2[128];
      pb_ostream_t eos;
      size_t l1, l2;

      env1.namespace = "strimserver";
      env1.topic = "/tasks/start";
      env1.has_event = true;
      env1.event.type_url = "containerd.events.TaskStart";
      PB_BYTES_ARRAY_T(64) v1;
      v1.size = (pb_size_t)ts_len;
      memcpy(v1.bytes, tsbuf, ts_len);
      env1.event.value = (pb_bytes_array_t *)&v1;
      eos = pb_ostream_from_buffer(b1, sizeof(b1));
      CHECK(pb_encode(&eos, containerd_types_Envelope_fields, &env1));
      l1 = eos.bytes_written;

      env2.namespace = "strimserver";
      env2.topic = "/tasks/exit";
      env2.has_event = true;
      env2.event.type_url = "containerd.events.TaskExit";
      PB_BYTES_ARRAY_T(64) v2;
      v2.size = (pb_size_t)te_len;
      memcpy(v2.bytes, tebuf, te_len);
      env2.event.value = (pb_bytes_array_t *)&v2;
      eos = pb_ostream_from_buffer(b2, sizeof(b2));
      CHECK(pb_encode(&eos, containerd_types_Envelope_fields, &env2));
      l2 = eos.bytes_written;

      fc.envelopes[0] = b1;
      fc.envelope_lens[0] = l1;
      fc.envelopes[1] = b2;
      fc.envelope_lens[1] = l2;
      fc.n_envelopes = 2;
    }
  }

  fc.listener_fd = lfd;
  /* The subscribe stream is the client's FIRST connection: lazy connect
   * means strim_containerd_connect dialed nothing, so the single-connection
   * stream server is the exact peer. */
  pthread_create(&th, NULL, fake_server_stream, &fc);

  rc = strim_containerd_connect(path, "strimserver", &client);
  CHECK(rc == 0 && client != NULL);
  if (rc != 0)
    return;
  rc = strim_containerd_subscribe(client, filters, 1, &stream);
  CHECK(rc == 0 && stream != NULL);

  rc = strim_event_stream_next(stream, 5000, &env);
  CHECK(rc == 0 && env != NULL);
  CHECK(strim_event_get_kind(env) == STRIM_EVENT_TASK_START);
  {
    char cid[64];
    int n = strim_event_container_id(env, cid, sizeof(cid));
    CHECK(n == (int)strlen("scale-and-egress"));
    CHECK(strcmp(cid, "scale-and-egress") == 0);
  }

  rc = strim_event_stream_next(stream, 5000, &env);
  CHECK(rc == 0 && env != NULL);
  CHECK(strim_event_get_kind(env) == STRIM_EVENT_TASK_EXIT);
  {
    char cid[64];
    int n = strim_event_container_id(env, cid, sizeof(cid));
    CHECK(n == (int)strlen("scale-and-egress"));
    CHECK(strcmp(cid, "scale-and-egress") == 0);
  }

  rc = strim_event_stream_next(stream, 2000, &env);
  CHECK(rc == STRIM_CTRD_ERR_IO); /* clean stream end -> listener exits */

  strim_event_stream_close(stream);
  strim_containerd_close(client);
  pthread_join(th, NULL);
  close(lfd);
  unlink(path);
}

/* =========================================================================
 * Test 5: nanopb service-call round-trips
 * ========================================================================= */
static void test_service_roundtrips(void) {
  /* GetImageRequest. */
  {
    containerd_services_images_v1_GetImageRequest req =
        containerd_services_images_v1_GetImageRequest_init_zero;
    uint8_t buf[256];
    pb_ostream_t os;
    req.name = "docker.io/library/ffmpeg:latest";
    os = pb_ostream_from_buffer(buf, sizeof(buf));
    CHECK(pb_encode(&os, containerd_services_images_v1_GetImageRequest_fields,
                    &req));

    containerd_services_images_v1_GetImageRequest dec =
        containerd_services_images_v1_GetImageRequest_init_zero;
    pb_istream_t is = pb_istream_from_buffer(buf, os.bytes_written);
    CHECK(pb_decode(&is, containerd_services_images_v1_GetImageRequest_fields,
                    &dec));
    CHECK(dec.name != NULL && strcmp(dec.name, "docker.io/library/ffmpeg:latest") == 0);
    pb_release(containerd_services_images_v1_GetImageRequest_fields, &dec);
  }

  /* CreateContainerRequest with the OCI-spec Any (the exact fields the
   * containerd client sends). */
  {
    containerd_services_containers_v1_CreateContainerRequest req =
        containerd_services_containers_v1_CreateContainerRequest_init_zero;
    uint8_t buf[1024];
    pb_ostream_t os;
    PB_BYTES_ARRAY_T(32) spec;
    static const char *spec_json = "{\"ociVersion\":\"1.0.2\"}";
    req.has_container = true;
    req.container.id = "scale-and-egress";
    req.container.image = "docker.io/library/ffmpeg:latest";
    req.container.has_runtime = true;
    req.container.runtime.name = "io.containerd.runc.v2";
    req.container.has_spec = true;
    req.container.spec.type_url =
        "types.containerd.io/opencontainers/runtime-spec/1/Spec";
    spec.size = (pb_size_t)strlen(spec_json);
    memcpy(spec.bytes, spec_json, spec.size);
    req.container.spec.value = (pb_bytes_array_t *)&spec;
    req.container.snapshotter = "overlayfs";
    req.container.snapshot_key = "snap-scale-and-egress";
    os = pb_ostream_from_buffer(buf, sizeof(buf));
    CHECK(pb_encode(
        &os, containerd_services_containers_v1_CreateContainerRequest_fields,
        &req));

    containerd_services_containers_v1_CreateContainerRequest dec =
        containerd_services_containers_v1_CreateContainerRequest_init_zero;
    pb_istream_t is = pb_istream_from_buffer(buf, os.bytes_written);
    CHECK(pb_decode(
        &is, containerd_services_containers_v1_CreateContainerRequest_fields,
        &dec));
    CHECK(dec.has_container);
    CHECK(dec.container.id != NULL &&
          strcmp(dec.container.id, "scale-and-egress") == 0);
    CHECK(dec.container.has_runtime &&
          dec.container.runtime.name != NULL &&
          strcmp(dec.container.runtime.name, "io.containerd.runc.v2") == 0);
    CHECK(dec.container.has_spec &&
          dec.container.spec.type_url != NULL &&
          strcmp(dec.container.spec.type_url,
                 "types.containerd.io/opencontainers/runtime-spec/1/Spec") == 0);
    CHECK(dec.container.spec.value != NULL &&
          dec.container.spec.value->size == strlen(spec_json));
    CHECK(dec.container.snapshot_key != NULL &&
          strcmp(dec.container.snapshot_key, "snap-scale-and-egress") == 0);
    pb_release(
        containerd_services_containers_v1_CreateContainerRequest_fields, &dec);
  }

  /* CreateTaskRequest with rootfs mounts + log stdio. */
  {
    containerd_services_tasks_v1_CreateTaskRequest req =
        containerd_services_tasks_v1_CreateTaskRequest_init_zero;
    containerd_types_Mount mounts[1];
    uint8_t buf[1024];
    pb_ostream_t os;
    mounts[0].type = "overlay";
    mounts[0].source = "overlay";
    mounts[0].target = "/";
    {
      static char *opts[] = {"lowerdir=/x", "upperdir=/y", "workdir=/z"};
      mounts[0].options = opts;
      mounts[0].options_count = 3;
    }
    req.container_id = "scale-and-egress";
    req.rootfs = mounts;
    req.rootfs_count = 1;
    req.stdout = "file:///var/log/scale-and-egress.log";
    req.stderr = "file:///var/log/scale-and-egress.log";
    os = pb_ostream_from_buffer(buf, sizeof(buf));
    CHECK(pb_encode(&os, containerd_services_tasks_v1_CreateTaskRequest_fields,
                    &req));

    containerd_services_tasks_v1_CreateTaskRequest dec =
        containerd_services_tasks_v1_CreateTaskRequest_init_zero;
    pb_istream_t is = pb_istream_from_buffer(buf, os.bytes_written);
    CHECK(pb_decode(&is, containerd_services_tasks_v1_CreateTaskRequest_fields,
                    &dec));
    CHECK(dec.container_id != NULL &&
          strcmp(dec.container_id, "scale-and-egress") == 0);
    CHECK(dec.rootfs_count == 1 && dec.rootfs != NULL);
    CHECK(dec.rootfs[0].type != NULL && strcmp(dec.rootfs[0].type, "overlay") == 0);
    CHECK(dec.rootfs[0].options_count == 3);
    CHECK(dec.stdout != NULL &&
          strcmp(dec.stdout, "file:///var/log/scale-and-egress.log") == 0);
    CHECK(dec.stderr != NULL && strcmp(dec.stderr, dec.stdout) == 0);
    pb_release(containerd_services_tasks_v1_CreateTaskRequest_fields, &dec);
  }

  /* SubscribeRequest with the controller's task filter. */
  {
    containerd_services_events_v1_SubscribeRequest req =
        containerd_services_events_v1_SubscribeRequest_init_zero;
    uint8_t buf[256];
    pb_ostream_t os;
    static char *filters[] = {"topic~=\"/tasks/.*\""};
    req.filters = filters;
    req.filters_count = 1;
    os = pb_ostream_from_buffer(buf, sizeof(buf));
    CHECK(pb_encode(&os, containerd_services_events_v1_SubscribeRequest_fields,
                    &req));

    containerd_services_events_v1_SubscribeRequest dec =
        containerd_services_events_v1_SubscribeRequest_init_zero;
    pb_istream_t is = pb_istream_from_buffer(buf, os.bytes_written);
    CHECK(pb_decode(&is, containerd_services_events_v1_SubscribeRequest_fields,
                    &dec));
    CHECK(dec.filters_count == 1 && dec.filters != NULL);
    CHECK(strcmp(dec.filters[0], "topic~=\"/tasks/.*\"") == 0);
    pb_release(containerd_services_events_v1_SubscribeRequest_fields, &dec);
  }

  /* WaitResponse. */
  {
    containerd_services_tasks_v1_WaitResponse resp =
        containerd_services_tasks_v1_WaitResponse_init_zero;
    uint8_t buf[64];
    pb_ostream_t os;
    resp.exit_status = 137;
    resp.has_exited_at = true;
    resp.exited_at.seconds = 1700000000;
    os = pb_ostream_from_buffer(buf, sizeof(buf));
    CHECK(pb_encode(&os, containerd_services_tasks_v1_WaitResponse_fields,
                    &resp));

    containerd_services_tasks_v1_WaitResponse dec =
        containerd_services_tasks_v1_WaitResponse_init_zero;
    pb_istream_t is = pb_istream_from_buffer(buf, os.bytes_written);
    CHECK(pb_decode(&is, containerd_services_tasks_v1_WaitResponse_fields,
                    &dec));
    CHECK(dec.exit_status == 137);
    CHECK(dec.has_exited_at && dec.exited_at.seconds == 1700000000);
    pb_release(containerd_services_tasks_v1_WaitResponse_fields, &dec);
  }
}

/* =========================================================================
 * Test 6: OCI spec JSON builder
 * ========================================================================= */
static void test_oci_spec_builder(void) {
  strim_spec spec;
  strim_oci_image_config image;
  strim_mount mounts[2];
  char *json = NULL;
  size_t json_len = 0;
  int rc;

  memset(&spec, 0, sizeof(spec));
  mounts[0].source = "/mnt/nvme/config/strimserver.env";
  mounts[0].destination = "/strimserver.env";
  mounts[0].read_write = false;
  mounts[1].source = "/tmp";
  mounts[1].destination = "/tmp";
  mounts[1].read_write = true;
  spec.mounts = mounts;
  spec.n_mounts = 2;
  spec.host_network = true; /* WithHostNamespace(NetworkNamespace) */

  static const char *args[] = {"/transcode.sh", "scale_and_egress"};
  static const char *env[] = {"A=1", "B=2"};
  static const char *caps[] = {"CAP_SYS_NICE"};
  spec.process.args = args;
  spec.process.n_args = 2;
  spec.process.env = env;
  spec.process.n_env = 2;
  spec.process.capabilities = caps;
  spec.process.n_capabilities = 1;

  static const char *img_env[] = {"PATH=/usr/bin", "C=3"};
  static const char *img_entrypoint[] = {"/entrypoint"};
  static const char *img_cmd[] = {"--flag"};
  memset(&image, 0, sizeof(image));
  image.env = img_env;
  image.n_env = 2;
  image.entrypoint = img_entrypoint;
  image.n_entrypoint = 1;
  image.cmd = img_cmd;
  image.n_cmd = 1;
  image.working_dir = "/workspace";
  image.user = NULL; /* root */

  rc = strim_oci_build_spec(&spec, &image, "strimserver", "scale-and-egress",
                            NULL, &json, &json_len);
  CHECK(rc == 0 && json != NULL);
  if (rc == 0) {
    /* The explicit strim env wins (WithImageConfig env is replaced). */
    CHECK(strstr(json, "\"A=1\"") != NULL);
    CHECK(strstr(json, "\"B=2\"") != NULL);
    CHECK(strstr(json, "\"PATH=/usr/bin\"") == NULL);
    /* Args = image entrypoint + strim args (the WithProcessArgs contract). */
    CHECK(strstr(json, "\"/entrypoint\"") != NULL);
    CHECK(strstr(json, "\"/transcode.sh\"") != NULL);
    CHECK(strstr(json, "\"scale_and_egress\"") != NULL);
    CHECK(strstr(json, "\"--flag\"") == NULL);
    /* Cwd from the image config. */
    CHECK(strstr(json, "\"cwd\":\"/workspace\"") != NULL);
    /* Host networking: no network namespace. */
    CHECK(strstr(json, "\"network\"") == NULL);
    /* cgroups path from namespace + container id. */
    CHECK(strstr(json, "\"cgroupsPath\":\"/strimserver/scale-and-egress\"") != NULL);
    /* Default caps + CAP_SYS_NICE, in all three sets. */
    CHECK(strstr(json, "\"CAP_SYS_NICE\"") != NULL);
    /* Bind mounts with the rw/ro options. */
    CHECK(strstr(json, "\"rbind\",\"ro\"") != NULL);
    CHECK(strstr(json, "\"rbind\",\"rw\"") != NULL);
    /* Default rootfs. */
    CHECK(strstr(json, "\"root\":{\"path\":\"rootfs\"}") != NULL);
    free(json);
  }
}

/* =========================================================================
 * Test 6b: CDI createContainer hooks flow into the emitted OCI spec, and
 * the emit-time env dedup drops a CDI env var whose key the base/image env
 * already sets (the production gap: NVIDIA_VISIBLE_DEVICES=all reaches the
 * builder via image->env — NOT spec->process.env — so the merge-time dedup
 * in strim_cdi_merge_edits never fires for it).
 * ========================================================================= */
static void test_oci_spec_cdi_hooks_and_env_dedup(void) {
  strim_spec spec;
  strim_oci_image_config image;
  strim_oci_cdi_edits cdi;
  strim_oci_cdi_hook hook;
  char *json = NULL;
  size_t json_len = 0;
  const char *p;
  int nvd_count = 0;
  int rc;

  memset(&spec, 0, sizeof(spec));
  spec.host_network = true;

  /* Production shape: the base NVIDIA_VISIBLE_DEVICES=all arrives via the
   * IMAGE config env (containerd_client.c parse_image_config -> ic.cfg), not
   * spec.process.env — the controller's factory spec (main.c
   * stage_start_op) only sets capabilities/args/mounts. */
  static const char *img_env[] = {"NVIDIA_VISIBLE_DEVICES=all",
                                  "PATH=/usr/bin"};
  static const char *img_entrypoint[] = {"/entrypoint"};
  static const char *img_cmd[] = {"--flag"};
  memset(&image, 0, sizeof(image));
  image.env = img_env;
  image.n_env = 2;
  image.entrypoint = img_entrypoint;
  image.n_entrypoint = 1;
  image.cmd = img_cmd;
  image.n_cmd = 1;
  image.working_dir = "/";
  image.user = NULL; /* root */

  /* The resolved CDI edit set (strim_cdi_get_pending_edits view): the nvidia
   * spec's containerEdits append NVIDIA_VISIBLE_DEVICES=void plus the
   * nvidia-cdi-hook create-symlinks createContainer hook. */
  static const char *cdi_env[] = {"NVIDIA_VISIBLE_DEVICES=void",
                                  "NVIDIA_DRIVER_CAPABILITIES=compute,utility,video"};
  static const char *hook_args[] = {"nvidia-cdi-hook", "create-symlinks",
                                    "--link", "libcuda.so.1"};
  static const char *hook_env[] = {"LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu"};
  memset(&cdi, 0, sizeof(cdi));
  cdi.env = cdi_env;
  cdi.n_env = 2;
  memset(&hook, 0, sizeof(hook));
  hook.path = "/usr/bin/nvidia-cdi-hook";
  hook.args = hook_args;
  hook.n_args = 4;
  hook.env = hook_env;
  hook.n_env = 1;
  hook.timeout = 30;
  cdi.hooks = &hook;
  cdi.n_hooks = 1;

  rc = strim_oci_build_spec(&spec, &image, "strimserver", "scale-and-egress",
                            &cdi, &json, &json_len);
  CHECK(rc == 0 && json != NULL);
  if (rc != 0 || json == NULL)
    return;

  /* Hooks: the top-level "hooks" object with a createContainer array carrying
   * the CDI hook (path/args/env/timeout) — never "hooks":null. */
  CHECK(strstr(json, "\"hooks\":{\"createContainer\":[") != NULL);
  CHECK(strstr(json, "\"path\":\"/usr/bin/nvidia-cdi-hook\"") != NULL);
  CHECK(strstr(json, "\"create-symlinks\"") != NULL);
  CHECK(strstr(json, "\"--link\"") != NULL);
  CHECK(strstr(json, "\"libcuda.so.1\"") != NULL);
  CHECK(strstr(json, "\"LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu\"") != NULL);
  CHECK(strstr(json, "\"timeout\":30") != NULL);
  CHECK(strstr(json, "\"hooks\":null") == NULL);

  /* Emit-time env dedup: the base/image NVIDIA_VISIBLE_DEVICES=all wins; the
   * CDI =void is dropped, so the key appears exactly once in the env array. */
  CHECK(strstr(json, "NVIDIA_VISIBLE_DEVICES=all") != NULL);
  CHECK(strstr(json, "NVIDIA_VISIBLE_DEVICES=void") == NULL);
  for (p = json; (p = strstr(p, "NVIDIA_VISIBLE_DEVICES")) != NULL;
       p += strlen("NVIDIA_VISIBLE_DEVICES"))
    nvd_count++;
  CHECK(nvd_count == 1);

  free(json);

  /* Intra-CDI duplicates must survive the emit-time dedup (the cdi_test
   * contract: spec-level + device-level env edits with the same key are both
   * appended — the dedup only guards the base/image env, never within the
   * CDI set itself). */
  {
    char *json2 = NULL;
    size_t json2_len = 0;
    static const char *img_env2[] = {"PATH=/usr/bin"};
    static const char *cdi_dup_env[] = {"NVIDIA_VISIBLE_DEVICES=0",
                                        "NVIDIA_VISIBLE_DEVICES=1"};
    strim_oci_image_config image2;
    strim_oci_cdi_edits cdi2;
    memset(&image2, 0, sizeof(image2));
    image2.env = img_env2;
    image2.n_env = 1;
    image2.working_dir = "/";
    memset(&cdi2, 0, sizeof(cdi2));
    cdi2.env = cdi_dup_env;
    cdi2.n_env = 2;
    rc = strim_oci_build_spec(&spec, &image2, "strimserver", "scale-and-egress",
                              &cdi2, &json2, &json2_len);
    CHECK(rc == 0 && json2 != NULL);
    if (rc == 0 && json2 != NULL) {
      CHECK(strstr(json2, "\"NVIDIA_VISIBLE_DEVICES=0\"") != NULL);
      CHECK(strstr(json2, "\"NVIDIA_VISIBLE_DEVICES=1\"") != NULL);
      free(json2);
    }
  }
}

/* =========================================================================
 * Test 6c: CDI device nodes emit matching allow rules in resources.devices
 * AFTER the base deny-all. cgroup v2 installs the array as a device eBPF
 * program with last-match-wins semantics, so a deny-all-only spec (the
 * deployed bug) made open(/dev/nvidia0) fail with EPERM and the egress
 * ffmpeg container exit 187 — the allows MUST follow the deny, exactly like
 * Go's cdi.WithCDIDevices. Nodes without a valid char-device identity
 * (major/minor < 0 or type != "c") get NO allow rule; linux.devices still
 * carries every node.
 * ========================================================================= */
static void test_oci_spec_cdi_device_cgroup_rules(void) {
  strim_spec spec;
  strim_oci_image_config image;
  strim_oci_cdi_edits cdi;
  strim_oci_cdi_device devices[8];
  char *json = NULL;
  size_t json_len = 0;
  yyjson_doc *doc = NULL;
  yyjson_val *root, *linux_obj, *resources, *devices_arr, *rule,
      *linux_devices;
  size_t i;
  int rc;
  /* The nvidia char devices (the deployed set) in emission order. */
  static const struct {
    int64_t major;
    int64_t minor;
  } EXPECTED_ALLOWS[] = {{195, 0}, {195, 255}, {237, 0}, {237, 1}, {1, 3}};

  memset(&spec, 0, sizeof(spec));
  spec.host_network = true;

  static const char *img_entrypoint[] = {"/entrypoint"};
  static const char *img_cmd[] = {"--flag"};
  memset(&image, 0, sizeof(image));
  image.entrypoint = img_entrypoint;
  image.n_entrypoint = 1;
  image.cmd = img_cmd;
  image.n_cmd = 1;
  image.working_dir = "/";
  image.user = NULL; /* root */

  /* Four nvidia nodes + one NULL-type node (defaults to "c", like cdi.c)
   * must get allow rules; a negative-major node, a negative-minor node and
   * a block node must NOT. */
  memset(devices, 0, sizeof(devices));
  devices[0].path = "/dev/nvidia0";
  devices[0].type = "c";
  devices[0].major = 195;
  devices[0].minor = 0;
  devices[1].path = "/dev/nvidiactl";
  devices[1].type = "c";
  devices[1].major = 195;
  devices[1].minor = 255;
  devices[2].path = "/dev/nvidia-uvm";
  devices[2].type = "c";
  devices[2].major = 237;
  devices[2].minor = 0;
  devices[3].path = "/dev/nvidia-uvm-tools";
  devices[3].type = "c";
  devices[3].major = 237;
  devices[3].minor = 1;
  devices[4].path = "/dev/bad-negative-major";
  devices[4].type = "c";
  devices[4].major = -1;
  devices[4].minor = 0;
  devices[5].path = "/dev/bad-negative-minor";
  devices[5].type = "c";
  devices[5].major = 195;
  devices[5].minor = -1;
  devices[6].path = "/dev/sda";
  devices[6].type = "b";
  devices[6].major = 8;
  devices[6].minor = 0;
  devices[7].path = "/dev/nulltype";
  devices[7].type = NULL;
  devices[7].major = 1;
  devices[7].minor = 3;

  memset(&cdi, 0, sizeof(cdi));
  cdi.devices = devices;
  cdi.n_devices = sizeof(devices) / sizeof(devices[0]);

  rc = strim_oci_build_spec(&spec, &image, "strimserver", "scale-and-egress",
                            &cdi, &json, &json_len);
  CHECK(rc == 0 && json != NULL);
  if (rc != 0 || json == NULL)
    return;

  /* The deny-all must be the FIRST element of the devices array (raw text),
   * before any allow rule. */
  CHECK(strstr(json, "\"resources\":{\"devices\":[{\"allow\":false,\"access\":\"rwm\"}") != NULL);

  /* The emitted JSON must parse — well-formed, and navigable. */
  doc = yyjson_read(json, json_len, 0);
  CHECK(doc != NULL);
  if (doc == NULL) {
    free(json);
    return;
  }
  root = yyjson_doc_get_root(doc);
  linux_obj = yyjson_obj_get(root, "linux");
  CHECK(linux_obj != NULL);
  resources = yyjson_obj_get(linux_obj, "resources");
  CHECK(resources != NULL);
  devices_arr = yyjson_obj_get(resources, "devices");
  CHECK(devices_arr != NULL);
  /* deny-all + 5 valid char nodes; the negative-major/minor and block nodes
   * are skipped. */
  CHECK(yyjson_arr_size(devices_arr) == 1 + 5);
  if (yyjson_arr_size(devices_arr) == 1 + 5) {
    /* [0]: the deny-all first, with the access string and no device identity. */
    rule = yyjson_arr_get(devices_arr, 0);
    CHECK(rule != NULL);
    CHECK(yyjson_get_bool(yyjson_obj_get(rule, "allow")) == false);
    CHECK(yyjson_get_str(yyjson_obj_get(rule, "access")) != NULL &&
          strcmp(yyjson_get_str(yyjson_obj_get(rule, "access")), "rwm") == 0);
    CHECK(yyjson_obj_get(rule, "type") == NULL);
    CHECK(yyjson_obj_get(rule, "major") == NULL);
    CHECK(yyjson_obj_get(rule, "minor") == NULL);

    /* [1..5]: one allow rule per valid char node, in device order. */
    for (i = 0; i < sizeof(EXPECTED_ALLOWS) / sizeof(EXPECTED_ALLOWS[0]); i++) {
      rule = yyjson_arr_get(devices_arr, 1 + i);
      CHECK(rule != NULL);
      CHECK(yyjson_get_bool(yyjson_obj_get(rule, "allow")) == true);
      CHECK(yyjson_get_str(yyjson_obj_get(rule, "type")) != NULL &&
            strcmp(yyjson_get_str(yyjson_obj_get(rule, "type")), "c") == 0);
      CHECK(yyjson_get_sint(yyjson_obj_get(rule, "major")) == EXPECTED_ALLOWS[i].major);
      CHECK(yyjson_get_sint(yyjson_obj_get(rule, "minor")) == EXPECTED_ALLOWS[i].minor);
      CHECK(yyjson_get_str(yyjson_obj_get(rule, "access")) != NULL &&
            strcmp(yyjson_get_str(yyjson_obj_get(rule, "access")), "rwm") == 0);
    }
  }

  /* linux.devices still carries ALL nodes (emission unchanged). */
  linux_devices = yyjson_obj_get(linux_obj, "devices");
  CHECK(linux_devices != NULL);
  CHECK(yyjson_arr_size(linux_devices) == 8);
  for (i = 0; i < 8; i++) {
    rule = yyjson_arr_get(linux_devices, i);
    CHECK(rule != NULL &&
          yyjson_get_str(yyjson_obj_get(rule, "path")) != NULL);
  }

  yyjson_doc_free(doc);
  free(json);

  /* No-CDI baseline: the array is still just the deny-all. */
  {
    char *json2 = NULL;
    size_t json2_len = 0;
    yyjson_doc *doc2 = NULL;
    yyjson_val *arr2 = NULL;
    rc = strim_oci_build_spec(&spec, &image, "strimserver", "scale-and-egress",
                              NULL, &json2, &json2_len);
    CHECK(rc == 0 && json2 != NULL);
    if (rc != 0 || json2 == NULL)
      return;
    doc2 = yyjson_read(json2, json2_len, 0);
    CHECK(doc2 != NULL);
    if (doc2 != NULL) {
      yyjson_val *linux2 = yyjson_obj_get(yyjson_doc_get_root(doc2), "linux");
      yyjson_val *resources2 =
          linux2 != NULL ? yyjson_obj_get(linux2, "resources") : NULL;
      arr2 = resources2 != NULL ? yyjson_obj_get(resources2, "devices") : NULL;
      CHECK(arr2 != NULL && yyjson_arr_size(arr2) == 1);
      CHECK(arr2 != NULL &&
            yyjson_get_bool(yyjson_obj_get(yyjson_arr_get(arr2, 0), "allow")) == false);
      yyjson_doc_free(doc2);
    }
    free(json2);
  }
}

/* =========================================================================
 * Test 7: image rootfs chain ID (identity.ChainID vectors)
 * ========================================================================= */
static void test_chain_id(void) {
  /* Direct sha256 checks. */
  {
    uint8_t d[32];
    char fmt[72];
    strim_sha256((const uint8_t *)"abc", 3, d);
    strim_sha256_format(d, fmt);
    CHECK(strcmp(fmt, "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") == 0);
    strim_sha256((const uint8_t *)"", 0, d);
    strim_sha256_format(d, fmt);
    CHECK(strcmp(fmt, "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") == 0);
  }
  /* identity.ChainID over diff-ids. */
  {
    char *diffs[] = {(char *)"sha256:aaa", (char *)"sha256:bbb"};
    /* compute via the same algorithm the client uses */
    uint8_t digest[32];
    char fmt[72];
    const char *joined = "sha256:aaa sha256:bbb";
    strim_sha256((const uint8_t *)joined, strlen(joined), digest);
    strim_sha256_format(digest, fmt);
    CHECK(strcmp(fmt,
                 "sha256:56efb1d4f6c79b745d37d6eff87e3ed8dd2be28104e124ba73fd6e6c4892c792") == 0);
    (void)diffs;
  }
}

/* =========================================================================
 * Test 8: Task-18 lifecycle — start sequence over the scripted fake server
 * ========================================================================= */
static void test_lifecycle_start(void) {
  char path[128];
  int lfd = temp_listen(path, sizeof(path));
  uint8_t image_resp[512], create_ctr_resp[256], mounts_resp[256];
  uint8_t task_create_resp[128], start_resp[64];
  uint8_t read_manifest[512], read_config[512];
  size_t image_len, create_ctr_len, mounts_len, task_create_len, start_len;
  size_t read_manifest_len, read_config_len;
  const uint8_t *manifest_msgs[1], *config_msgs[1];
  uint32_t manifest_lens[1], config_lens[1];
  struct script_arg sa;
  struct fstep script[8];
  pthread_t th;
  strim_containerd_client *client = NULL;
  strim_container *ctr = NULL;
  strim_task *task = NULL;
  strim_spec spec;
  strim_mount mounts[1];
  int rc;

  CHECK(lfd >= 0);
  if (lfd < 0)
    return;

  build_image_get_resp(image_resp, sizeof(image_resp), &image_len);
  build_create_container_resp(create_ctr_resp, sizeof(create_ctr_resp),
                              &create_ctr_len);
  build_mounts_resp(mounts_resp, sizeof(mounts_resp), &mounts_len);
  build_task_create_resp(task_create_resp, sizeof(task_create_resp),
                         &task_create_len);
  build_start_resp(start_resp, sizeof(start_resp), &start_len);
  build_read_resp(read_manifest, sizeof(read_manifest), &read_manifest_len,
                  MANIFEST_JSON, strlen(MANIFEST_JSON));
  build_read_resp(read_config, sizeof(read_config), &read_config_len,
                  CONFIG_JSON, strlen(CONFIG_JSON));

  manifest_msgs[0] = read_manifest;
  manifest_lens[0] = (uint32_t)read_manifest_len;
  config_msgs[0] = read_config;
  config_lens[0] = (uint32_t)read_config_len;

  memset(script, 0, sizeof(script));
  script[0].kind = FS_UNARY;
  script[0].body = image_resp;
  script[0].body_len = (uint32_t)image_len;
  script[1].kind = FS_STREAM; /* Content/Read: the image manifest */
  script[1].msgs = manifest_msgs;
  script[1].n_msgs = 1;
  script[1].msg_lens = manifest_lens;
  script[2].kind = FS_STREAM; /* Content/Read: the image config */
  script[2].msgs = config_msgs;
  script[2].n_msgs = 1;
  script[2].msg_lens = config_lens;
  script[3].kind = FS_UNARY; /* Snapshots/Prepare (body ignored) */
  script[3].body = NULL;
  script[3].body_len = 0;
  script[4].kind = FS_UNARY;
  script[4].body = create_ctr_resp;
  script[4].body_len = (uint32_t)create_ctr_len;
  script[5].kind = FS_UNARY; /* Snapshots/Mounts */
  script[5].body = mounts_resp;
  script[5].body_len = (uint32_t)mounts_len;
  script[6].kind = FS_UNARY; /* Tasks/Create */
  script[6].body = task_create_resp;
  script[6].body_len = (uint32_t)task_create_len;
  script[7].kind = FS_UNARY; /* Tasks/Start */
  script[7].body = start_resp;
  script[7].body_len = (uint32_t)start_len;

  memset(&sa, 0, sizeof(sa));
  sa.listener_fd = lfd;
  sa.script = script;
  sa.n_steps = sizeof(script) / sizeof(script[0]);
  pthread_create(&th, NULL, scripted_server, &sa);

  rc = strim_containerd_connect(path, "strimserver", &client);
  CHECK(rc == 0 && client != NULL);
  if (rc != 0)
    return;

  /* The OCI spec (no CDI resolution in this test). */
  memset(&spec, 0, sizeof(spec));
  mounts[0].source = "/mnt/nvme/config/strimserver.env";
  mounts[0].destination = "/strimserver.env";
  mounts[0].read_write = false;
  spec.mounts = mounts;
  spec.n_mounts = 1;
  spec.host_network = true;

  rc = strim_containerd_new_container(client, "ctr-1", "snap-ctr-1",
                                      "docker.io/library/ffmpeg:latest",
                                      &spec, &ctr);
  /* rc == 0 proves the whole wire sequence decoded: GetImage carried a
   * target digest, the manifest/config blobs yielded a chain ID, Prepare
   * and Create succeeded (the handles are opaque by contract). */
  CHECK(rc == 0 && ctr != NULL);
  if (rc != 0)
    return;

  rc = strim_containerd_new_task(ctr, "/var/log/ctr-1.log", &task);
  CHECK(rc == 0 && task != NULL);
  if (rc != 0)
    return;

  rc = strim_containerd_task_start(task);
  CHECK(rc == 0);

  strim_containerd_close(client);
  pthread_join(th, NULL);
  close(lfd);
  unlink(path);
}

/* =========================================================================
 * Test 8b: image config parsing — the OCI/Docker config blob uses
 * CAPITALIZED keys ("Entrypoint", "Cmd", "Env", "WorkingDir", "User"). The
 * C parser must read them (the Go oracle's json.Unmarshal matches struct
 * fields case-insensitively), and the lowercase spelling must keep working.
 *
 * parse_image_config is static, so the observable is the OCI spec the
 * client builds from it: entrypoint+cmd -> process.args, env ->
 * process.env, working_dir -> cwd, user -> uid. The fake server captures
 * the Containers/Create request body and the test decodes the spec JSON it
 * carried.
 * ========================================================================= */

/* Run the new-container sequence with the given image-config blob and check
 * the built OCI spec's process fields. expect_user == NULL means the config
 * carries no user (root: no "uid" is emitted). */
static void test_image_config_keys_case(const char *config_json,
                                        const char *expect_args,
                                        const char *expect_user,
                                        const char *expect_cwd) {
  char path[128];
  int lfd = temp_listen(path, sizeof(path));
  uint8_t image_resp[512], create_ctr_resp[256];
  uint8_t read_manifest[512], read_config[512];
  uint8_t captured[4096];
  size_t image_len, create_ctr_len, read_manifest_len, read_config_len;
  size_t captured_len = 0;
  const uint8_t *manifest_msgs[1], *config_msgs[1];
  uint32_t manifest_lens[1], config_lens[1];
  struct script_arg sa;
  struct fstep script[5];
  pthread_t th;
  strim_containerd_client *client = NULL;
  strim_container *ctr = NULL;
  strim_spec spec;
  strim_mount mounts[1];
  containerd_services_containers_v1_CreateContainerRequest req =
      containerd_services_containers_v1_CreateContainerRequest_init_zero;
  pb_istream_t is;
  char spec_json[4096];
  int rc;

  CHECK(lfd >= 0);
  if (lfd < 0)
    return;

  build_image_get_resp(image_resp, sizeof(image_resp), &image_len);
  build_create_container_resp(create_ctr_resp, sizeof(create_ctr_resp),
                              &create_ctr_len);
  build_read_resp(read_manifest, sizeof(read_manifest), &read_manifest_len,
                  MANIFEST_JSON, strlen(MANIFEST_JSON));
  build_read_resp(read_config, sizeof(read_config), &read_config_len,
                  config_json, strlen(config_json));

  manifest_msgs[0] = read_manifest;
  manifest_lens[0] = (uint32_t)read_manifest_len;
  config_msgs[0] = read_config;
  config_lens[0] = (uint32_t)read_config_len;

  memset(script, 0, sizeof(script));
  script[0].kind = FS_UNARY;
  script[0].body = image_resp;
  script[0].body_len = (uint32_t)image_len;
  script[1].kind = FS_STREAM; /* Content/Read: the image manifest */
  script[1].msgs = manifest_msgs;
  script[1].n_msgs = 1;
  script[1].msg_lens = manifest_lens;
  script[2].kind = FS_STREAM; /* Content/Read: the image config */
  script[2].msgs = config_msgs;
  script[2].n_msgs = 1;
  script[2].msg_lens = config_lens;
  script[3].kind = FS_UNARY; /* Snapshots/Prepare (body ignored) */
  script[3].body = NULL;
  script[3].body_len = 0;
  script[4].kind = FS_UNARY; /* Containers/Create */
  script[4].body = create_ctr_resp;
  script[4].body_len = (uint32_t)create_ctr_len;

  memset(&sa, 0, sizeof(sa));
  sa.listener_fd = lfd;
  sa.script = script;
  sa.n_steps = sizeof(script) / sizeof(script[0]);
  sa.capture_step = 4;
  sa.capture_body = captured;
  sa.capture_len = &captured_len;
  sa.capture_cap = sizeof(captured);
  pthread_create(&th, NULL, scripted_server, &sa);

  rc = strim_containerd_connect(path, "strimserver", &client);
  CHECK(rc == 0 && client != NULL);
  if (rc != 0)
    return;

  /* The OCI spec (no CDI resolution in this test). */
  memset(&spec, 0, sizeof(spec));
  mounts[0].source = "/mnt/nvme/config/strimserver.env";
  mounts[0].destination = "/strimserver.env";
  mounts[0].read_write = false;
  spec.mounts = mounts;
  spec.n_mounts = 1;
  spec.host_network = true;

  rc = strim_containerd_new_container(client, "ctr-1", "snap-ctr-1",
                                      "docker.io/library/ffmpeg:latest",
                                      &spec, &ctr);
  CHECK(rc == 0 && ctr != NULL);
  if (rc != 0) {
    strim_containerd_close(client);
    pthread_join(th, NULL);
    close(lfd);
    unlink(path);
    return;
  }

  /* Decode the captured Containers/Create request and inspect the OCI spec
   * JSON it carried. */
  is = pb_istream_from_buffer(captured, captured_len);
  CHECK(pb_decode(
      &is, containerd_services_containers_v1_CreateContainerRequest_fields,
      &req));
  CHECK(req.has_container && req.container.has_spec &&
        req.container.spec.value != NULL);
  if (req.has_container && req.container.has_spec &&
      req.container.spec.value != NULL) {
    size_t json_len = req.container.spec.value->size;
    if (json_len >= sizeof(spec_json))
      json_len = sizeof(spec_json) - 1;
    memcpy(spec_json, req.container.spec.value->bytes, json_len);
    spec_json[json_len] = '\0';
    CHECK(expect_args == NULL ||
          strstr(spec_json, expect_args) != NULL);
    CHECK(expect_user == NULL ||
          strstr(spec_json, expect_user) != NULL);
    CHECK(expect_cwd == NULL ||
          strstr(spec_json, expect_cwd) != NULL);
    /* The image config env must land in process.env. */
    CHECK(strstr(spec_json, "\"PATH=/usr/bin\"") != NULL);
  }
  pb_release(containerd_services_containers_v1_CreateContainerRequest_fields,
             &req);

  strim_containerd_close(client);
  pthread_join(th, NULL);
  close(lfd);
  unlink(path);
}

static void test_image_config_case_insensitive(void) {
  /* Capitalized keys (OCI canonical — the exact mediamtx case that failed):
   * Entrypoint lands in args, Cmd follows it, WorkingDir -> cwd, User ->
   * uid. */
  test_image_config_keys_case(CONFIG_JSON_CAPS,
                              "\"args\":[\"/entrypoint.sh\",\"--flag\"]",
                              "\"uid\":1000", "\"cwd\":\"/\"");
  /* Lowercase keys (the parser's historical input) must keep working. */
  test_image_config_keys_case(CONFIG_JSON, "\"args\":[\"/transcode.sh\"]",
                              NULL, "\"cwd\":\"/\"");
}

/* =========================================================================
 * Test 9: Task-18 lifecycle — stop sequence (graceful) over the fake server
 * ========================================================================= */
static void test_lifecycle_stop(void) {
  char path[128];
  int lfd = temp_listen(path, sizeof(path));
  uint8_t get_ctr_resp[512], get_task_resp[128], wait_resp[64];
  uint8_t del_task_resp[128];
  size_t get_ctr_len, get_task_len, wait_len, del_task_len;
  struct script_arg sa;
  struct fstep script[7];
  pthread_t th;
  strim_containerd_client *client = NULL;
  strim_container *ctr = NULL;
  strim_task *task = NULL;
  int32_t code = -1;
  int rc;

  CHECK(lfd >= 0);
  if (lfd < 0)
    return;

  build_get_container_resp(get_ctr_resp, sizeof(get_ctr_resp), &get_ctr_len);
  build_get_task_resp(get_task_resp, sizeof(get_task_resp), &get_task_len);
  build_wait_resp(wait_resp, sizeof(wait_resp), &wait_len, 0);
  build_delete_task_resp(del_task_resp, sizeof(del_task_resp), &del_task_len);

  memset(script, 0, sizeof(script));
  script[0].kind = FS_UNARY; /* Containers/Get */
  script[0].body = get_ctr_resp;
  script[0].body_len = (uint32_t)get_ctr_len;
  script[1].kind = FS_UNARY; /* Tasks/Get */
  script[1].body = get_task_resp;
  script[1].body_len = (uint32_t)get_task_len;
  script[2].kind = FS_NEWCONN; /* Tasks/Wait on a dedicated connection */
  script[2].body = wait_resp;
  script[2].body_len = (uint32_t)wait_len;
  script[3].kind = FS_UNARY; /* Tasks/Kill(SIGTERM) */
  script[3].body = NULL;
  script[3].body_len = 0;
  script[4].kind = FS_UNARY; /* Tasks/Delete */
  script[4].body = del_task_resp;
  script[4].body_len = (uint32_t)del_task_len;
  script[5].kind = FS_UNARY; /* Snapshots/Remove (WithSnapshotCleanup) */
  script[5].body = NULL;
  script[5].body_len = 0;
  script[6].kind = FS_UNARY; /* Containers/Delete */
  script[6].body = NULL;
  script[6].body_len = 0;

  memset(&sa, 0, sizeof(sa));
  sa.listener_fd = lfd;
  sa.script = script;
  sa.n_steps = sizeof(script) / sizeof(script[0]);
  pthread_create(&th, NULL, scripted_server, &sa);

  rc = strim_containerd_connect(path, "strimserver", &client);
  CHECK(rc == 0 && client != NULL);
  if (rc != 0)
    return;

  /* stop = LoadContainer -> LoadTask -> Wait -> Kill(SIGTERM) -> Delete
   * task -> Delete container (snapshot cleanup). */
  rc = strim_containerd_load_container(client, "ctr-1", &ctr);
  CHECK(rc == 0 && ctr != NULL);
  if (rc != 0)
    return;

  rc = strim_containerd_load_task(ctr, &task);
  CHECK(rc == 0 && task != NULL);
  if (rc != 0)
    return;

  rc = strim_containerd_task_wait(task, 5000, &code);
  CHECK(rc == 0 && code == 0);

  rc = strim_containerd_task_kill(task, STRIM_CTRD_KILL_SIGTERM);
  CHECK(rc == 0);

  rc = strim_containerd_task_delete(task, 0);
  CHECK(rc == 0);

  rc = strim_containerd_delete_container(ctr, 1);
  CHECK(rc == 0);

  strim_containerd_close(client);
  pthread_join(th, NULL);
  close(lfd);
  unlink(path);
}

/* =========================================================================
 * Test 10: Task-18 lifecycle — force-delete path (WithProcessKill: SIGKILL
 * All=true, wait, then Delete)
 * ========================================================================= */
static void test_force_delete(void) {
  char path[128];
  int lfd = temp_listen(path, sizeof(path));
  uint8_t get_ctr_resp[512], get_task_resp[128], wait_resp[64];
  uint8_t del_task_resp[128];
  size_t get_ctr_len, get_task_len, wait_len, del_task_len;
  struct script_arg sa;
  struct fstep script[5];
  pthread_t th;
  strim_containerd_client *client = NULL;
  strim_container *ctr = NULL;
  strim_task *task = NULL;
  int rc;

  CHECK(lfd >= 0);
  if (lfd < 0)
    return;

  build_get_container_resp(get_ctr_resp, sizeof(get_ctr_resp), &get_ctr_len);
  build_get_task_resp(get_task_resp, sizeof(get_task_resp), &get_task_len);
  build_wait_resp(wait_resp, sizeof(wait_resp), &wait_len, 137);
  build_delete_task_resp(del_task_resp, sizeof(del_task_resp), &del_task_len);

  memset(script, 0, sizeof(script));
  script[0].kind = FS_UNARY; /* Containers/Get */
  script[0].body = get_ctr_resp;
  script[0].body_len = (uint32_t)get_ctr_len;
  script[1].kind = FS_UNARY; /* Tasks/Get */
  script[1].body = get_task_resp;
  script[1].body_len = (uint32_t)get_task_len;
  script[2].kind = FS_UNARY; /* Tasks/Kill(SIGKILL, All=true) */
  script[2].body = NULL;
  script[2].body_len = 0;
  script[3].kind = FS_NEWCONN; /* Tasks/Wait on a dedicated connection */
  script[3].body = wait_resp;
  script[3].body_len = (uint32_t)wait_len;
  script[4].kind = FS_UNARY; /* Tasks/Delete */
  script[4].body = del_task_resp;
  script[4].body_len = (uint32_t)del_task_len;

  memset(&sa, 0, sizeof(sa));
  sa.listener_fd = lfd;
  sa.script = script;
  sa.n_steps = sizeof(script) / sizeof(script[0]);
  pthread_create(&th, NULL, scripted_server, &sa);

  rc = strim_containerd_connect(path, "strimserver", &client);
  CHECK(rc == 0 && client != NULL);
  if (rc != 0)
    return;

  rc = strim_containerd_load_container(client, "ctr-1", &ctr);
  CHECK(rc == 0 && ctr != NULL);
  if (rc != 0)
    return;
  rc = strim_containerd_load_task(ctr, &task);
  CHECK(rc == 0 && task != NULL);
  if (rc != 0)
    return;

  rc = strim_containerd_task_delete(task, 1); /* force */
  CHECK(rc == 0);

  strim_containerd_close(client);
  pthread_join(th, NULL);
  close(lfd);
  unlink(path);
}

/* =========================================================================
 * Test 11: the client's internal mutex — K worker threads call GetImage on
 * the SAME client concurrently; the fake server serves K clean requests.
 * ========================================================================= */

#define CONC_THREADS 8

struct conc_arg {
  strim_containerd_client *client;
  const char *ref;
  strim_image *img;
  int rc;
};

static void *conc_worker(void *a) {
  struct conc_arg *ca = (struct conc_arg *)a;
  ca->rc = strim_containerd_get_image(ca->client, ca->ref, &ca->img);
  return NULL;
}

static void test_concurrent_client(void) {
  char path[128];
  int lfd = temp_listen(path, sizeof(path));
  uint8_t image_resp[512];
  size_t image_len;
  struct script_arg sa;
  struct fstep script[CONC_THREADS];
  pthread_t server_th;
  pthread_t threads[CONC_THREADS];
  struct conc_arg args[CONC_THREADS];
  strim_containerd_client *client = NULL;
  int served = 0;
  int i;
  int rc;

  CHECK(lfd >= 0);
  if (lfd < 0)
    return;

  build_image_get_resp(image_resp, sizeof(image_resp), &image_len);
  memset(script, 0, sizeof(script));
  for (i = 0; i < CONC_THREADS; i++) {
    script[i].kind = FS_UNARY;
    script[i].body = image_resp;
    script[i].body_len = (uint32_t)image_len;
  }

  memset(&sa, 0, sizeof(sa));
  sa.listener_fd = lfd;
  sa.script = script;
  sa.n_steps = CONC_THREADS;
  sa.request_count = &served;
  pthread_create(&server_th, NULL, scripted_server, &sa);

  rc = strim_containerd_connect(path, "strimserver", &client);
  CHECK(rc == 0 && client != NULL);
  if (rc != 0)
    return;

  /* Fire CONC_THREADS worker threads at the SAME client; the internal mutex
   * serializes their RPCs on the shared connection. */
  for (i = 0; i < CONC_THREADS; i++) {
    args[i].client = client;
    args[i].ref = "docker.io/library/ffmpeg:latest";
    args[i].img = NULL;
    args[i].rc = -1;
    pthread_create(&threads[i], NULL, conc_worker, &args[i]);
  }
  for (i = 0; i < CONC_THREADS; i++)
    pthread_join(threads[i], NULL);

  for (i = 0; i < CONC_THREADS; i++) {
    /* rc == 0 proves each thread's GetImage decoded the response on the
     * shared connection (the mutex serialized the RPCs). */
    CHECK(args[i].rc == 0);
    CHECK(args[i].img != NULL);
  }
  CHECK(served == CONC_THREADS);

  strim_containerd_close(client);
  pthread_join(server_th, NULL);
  close(lfd);
  unlink(path);
}

/* =========================================================================
 * Test 12: unary flow-control credit — many sequential unary RPCs on ONE
 * shared connection, each returning a ~16 KiB response. The unary path must
 * credit the receive windows exactly like the stream-queue path: without
 * that, the 64 KiB connection window drains after ~4 responses, the next
 * DATA frame is rejected and the connection dies (or, against a
 * window-respecting peer, every later RPC times out). All 24 must succeed.
 * ========================================================================= */

#define FC_UNARY_RPCS 24
#define FC_UNARY_BODY (16 * 1024)

static void test_unary_flow_control_credit(void) {
  char path[128];
  int lfd = temp_listen(path, sizeof(path));
  uint8_t big_body[FC_UNARY_BODY];
  struct script_arg sa;
  struct fstep script[FC_UNARY_RPCS];
  pthread_t th;
  strim_h2c *c = NULL;
  uint8_t req[] = {1, 2, 3};
  uint8_t resp[FC_UNARY_BODY];
  uint32_t resp_len = 0;
  int served = 0;
  int i;
  int rc;

  CHECK(lfd >= 0);
  if (lfd < 0)
    return;

  for (i = 0; i < (int)sizeof(big_body); i++)
    big_body[i] = (uint8_t)(0xA0 + (i % 16));

  memset(script, 0, sizeof(script));
  for (i = 0; i < FC_UNARY_RPCS; i++) {
    script[i].kind = FS_UNARY;
    script[i].body = big_body;
    script[i].body_len = FC_UNARY_BODY;
  }

  memset(&sa, 0, sizeof(sa));
  sa.listener_fd = lfd;
  sa.script = script;
  sa.n_steps = FC_UNARY_RPCS;
  sa.request_count = &served;
  pthread_create(&th, NULL, scripted_server, &sa);

  rc = h2c_connect(&c, path, "test-ns");
  CHECK(rc == 0 && c != NULL);
  if (rc != 0)
    return;

  for (i = 0; i < FC_UNARY_RPCS; i++) {
    rc = h2c_unary(c, "/test.Service/Call", req, sizeof(req), resp,
                   sizeof(resp), &resp_len, 5000);
    /* Every RPC must succeed: a receive window that is never re-credited
     * stalls the shared connection after ~4 responses (rejected DATA ->
     * H2C_ERR_PROTO, or an H2C_ERR_TIMEOUT against a compliant peer). */
    CHECK(rc == 0);
    CHECK(resp_len == FC_UNARY_BODY);
    CHECK(memcmp(resp, big_body, FC_UNARY_BODY) == 0);
  }
  CHECK(served == FC_UNARY_RPCS);

  h2c_close(c);
  pthread_join(th, NULL);
  close(lfd);
  unlink(path);
}

/* =========================================================================
 * Test 13: gRPC error diagnosability — a daemon that finishes a unary RPC
 * with a trailers-only non-OK gRPC status (INTERNAL, the code a shim/runc
 * failure surfaces on Tasks/Create) must fold to STRIM_CTRD_ERR_RPC, never
 * the old blanket STRIM_CTRD_ERR_IO, and strim_containerd_last_error must
 * explain it. A follow-up RPC on the same connection must then succeed (a
 * daemon-returned status is an RPC-level answer, NOT a transport death) and
 * must clear the retained status.
 * ========================================================================= */
static void test_grpc_status_error(void) {
  char path[128];
  int lfd = temp_listen(path, sizeof(path));
  uint8_t image_resp[512];
  size_t image_len;
  struct script_arg sa;
  struct fstep script[2];
  pthread_t th;
  strim_containerd_client *client = NULL;
  strim_image *img = NULL;
  char reason[96];
  int served = 0;
  int n;
  int rc;

  CHECK(lfd >= 0);
  if (lfd < 0)
    return;

  build_image_get_resp(image_resp, sizeof(image_resp), &image_len);

  memset(script, 0, sizeof(script));
  /* Step 0: the daemon rejects the RPC with trailers-only grpc-status 13
   * (INTERNAL) plus a grpc-message — exactly what a shim/runc failure on
   * Tasks/Create produces. The message text is decoded and retained inside
   * the h2c layer; the public getter surfaces the status + canonical name. */
  script[0].kind = FS_ERR;
  script[0].grpc_status = H2C_STATUS_INTERNAL;
  script[0].grpc_message =
      "runc create failed: unable to start container process";
  /* Step 1: a healthy GetImage response on the SAME connection, proving the
   * daemon-returned error did not tear the shared transport down. */
  script[1].kind = FS_UNARY;
  script[1].body = image_resp;
  script[1].body_len = (uint32_t)image_len;

  memset(&sa, 0, sizeof(sa));
  sa.listener_fd = lfd;
  sa.script = script;
  sa.n_steps = sizeof(script) / sizeof(script[0]);
  sa.request_count = &served;
  pthread_create(&th, NULL, scripted_server, &sa);

  rc = strim_containerd_connect(path, "strimserver", &client);
  CHECK(rc == 0 && client != NULL);
  if (rc != 0)
    return;

  /* Before any RPC no daemon status has been observed. */
  n = strim_containerd_last_error(client, reason, sizeof(reason));
  CHECK(n == 0);

  rc = strim_containerd_get_image(client, "docker.io/library/ffmpeg:latest",
                                  &img);
  /* A daemon-returned INTERNAL must map to STRIM_CTRD_ERR_RPC (-9), NOT the
   * old blanket STRIM_CTRD_ERR_IO — that distinction is what makes a shim
   * failure diagnosable instead of a generic IO error. */
  CHECK(rc == STRIM_CTRD_ERR_RPC);

  /* The getter explains WHY: the retained daemon status + canonical name. */
  n = strim_containerd_last_error(client, reason, sizeof(reason));
  CHECK(n == (int)strlen("grpc status 13 (INTERNAL)"));
  CHECK(strcmp(reason, "grpc status 13 (INTERNAL)") == 0);

  /* The same connection survives a daemon-returned status (only transport
   * errors reset it), and the next successful RPC clears the retained
   * status — so a later STRIM_CTRD_ERR_RPC always reflects the LAST RPC. */
  rc = strim_containerd_get_image(client, "docker.io/library/ffmpeg:latest",
                                  &img);
  CHECK(rc == 0 && img != NULL);
  n = strim_containerd_last_error(client, reason, sizeof(reason));
  CHECK(n == 0);
  CHECK(served == 2);

  strim_containerd_close(client);
  pthread_join(th, NULL);
  close(lfd);
  unlink(path);
}

/* =========================================================================
 * Test 14: Containers/Create with an OVERSIZED response (the v1.0.36 CDI
 * createContainer-hook bug). The daemon's Create response echoes the full
 * stored OCI spec as an Any; after CDI hooks it is ~17-18 KiB, over the
 * client's old fixed 16 KiB buffer, so h2c aborted with H2C_ERR_TOOBIG and
 * the create folded to STRIM_CTRD_ERR_PROTO (-6) every 5 s — even though
 * the daemon accepted the create. The fix enlarged the response buffer to
 * 64 KiB; this test drives the full new-container sequence against a fake
 * daemon that returns a CDI-sized Create response and asserts success.
 * ========================================================================= */
static void test_new_container_large_spec(void) {
  char path[128];
  int lfd = temp_listen(path, sizeof(path));
  uint8_t image_resp[512], create_ctr_resp[32768];
  uint8_t read_manifest[512], read_config[512];
  size_t image_len, create_ctr_len, read_manifest_len, read_config_len;
  const uint8_t *manifest_msgs[1], *config_msgs[1];
  uint32_t manifest_lens[1], config_lens[1];
  struct script_arg sa;
  struct fstep script[5];
  pthread_t th;
  strim_containerd_client *client = NULL;
  strim_container *ctr = NULL;
  strim_spec spec;
  strim_mount mounts[1];
  int rc;

  CHECK(lfd >= 0);
  if (lfd < 0)
    return;

  build_image_get_resp(image_resp, sizeof(image_resp), &image_len);
  build_create_container_resp_large(create_ctr_resp,
                                    sizeof(create_ctr_resp),
                                    &create_ctr_len);
  /* The fixture must actually overrun the OLD 16 KiB client buffer: that is
   * the bug this test guards against. */
  CHECK(create_ctr_len > 16384);
  build_read_resp(read_manifest, sizeof(read_manifest), &read_manifest_len,
                  MANIFEST_JSON, strlen(MANIFEST_JSON));
  build_read_resp(read_config, sizeof(read_config), &read_config_len,
                  CONFIG_JSON, strlen(CONFIG_JSON));

  manifest_msgs[0] = read_manifest;
  manifest_lens[0] = (uint32_t)read_manifest_len;
  config_msgs[0] = read_config;
  config_lens[0] = (uint32_t)read_config_len;

  memset(script, 0, sizeof(script));
  script[0].kind = FS_UNARY;
  script[0].body = image_resp;
  script[0].body_len = (uint32_t)image_len;
  script[1].kind = FS_STREAM; /* Content/Read: the image manifest */
  script[1].msgs = manifest_msgs;
  script[1].n_msgs = 1;
  script[1].msg_lens = manifest_lens;
  script[2].kind = FS_STREAM; /* Content/Read: the image config */
  script[2].msgs = config_msgs;
  script[2].n_msgs = 1;
  script[2].msg_lens = config_lens;
  script[3].kind = FS_UNARY; /* Snapshots/Prepare (body ignored) */
  script[3].body = NULL;
  script[3].body_len = 0;
  script[4].kind = FS_UNARY; /* Containers/Create — OVERSIZED response */
  script[4].body = create_ctr_resp;
  script[4].body_len = (uint32_t)create_ctr_len;

  memset(&sa, 0, sizeof(sa));
  sa.listener_fd = lfd;
  sa.script = script;
  sa.n_steps = sizeof(script) / sizeof(script[0]);
  pthread_create(&th, NULL, scripted_server, &sa);

  rc = strim_containerd_connect(path, "strimserver", &client);
  CHECK(rc == 0 && client != NULL);
  if (rc != 0)
    return;

  /* The OCI spec (no CDI resolution in this test). */
  memset(&spec, 0, sizeof(spec));
  mounts[0].source = "/mnt/nvme/config/strimserver.env";
  mounts[0].destination = "/strimserver.env";
  mounts[0].read_write = false;
  spec.mounts = mounts;
  spec.n_mounts = 1;
  spec.host_network = true;

  /* The CDI-sized Create response must decode: with the old 16 KiB buffer
   * h2c aborted TOOBIG and this folded to STRIM_CTRD_ERR_PROTO (-6) even
   * though the fake daemon accepted the create. */
  rc = strim_containerd_new_container(client, "ctr-1", "snap-ctr-1",
                                      "docker.io/library/ffmpeg:latest",
                                      &spec, &ctr);
  CHECK(rc == 0 && ctr != NULL);

  strim_containerd_close(client);
  pthread_join(th, NULL);
  close(lfd);
  unlink(path);
}

/* =========================================================================
 * Test 15: an H2C_ERR_TOOBIG response tears down + redials the shared
 * connection instead of wedging it. The h2c abort path does NOT credit the
 * flow-control windows the oversized message consumed, so a retained
 * connection would stall every later RPC (-4 timeout) — the production -4
 * cascade after the -6 Create. transport_is_dead must treat TOOBIG as a
 * transport death: this test drives a GetImage whose response exceeds the
 * client's 16 KiB GetImage buffer (TOOBIG -> STRIM_CTRD_ERR_PROTO + reset),
 * then a second GetImage which must redial on a FRESH connection and
 * succeed.
 * ========================================================================= */
static void test_toobig_resets_shared_conn(void) {
  char path[128];
  int lfd = temp_listen(path, sizeof(path));
  uint8_t image_resp[512], big_image_resp[32768];
  size_t image_len, big_image_len;
  struct script_arg sa;
  struct fstep script[2];
  pthread_t th;
  strim_containerd_client *client = NULL;
  strim_image *img = NULL;
  int served = 0;
  int rc;

  CHECK(lfd >= 0);
  if (lfd < 0)
    return;

  build_image_get_resp(image_resp, sizeof(image_resp), &image_len);
  build_image_get_resp_large(big_image_resp, sizeof(big_image_resp),
                             &big_image_len);
  /* The oversized GetImage response must actually overrun the client's 16
   * KiB GetImage buffer — the TOOBIG trigger. */
  CHECK(big_image_len > 16384);

  memset(script, 0, sizeof(script));
  script[0].kind = FS_UNARY; /* step 0: oversized GetImage -> TOOBIG */
  script[0].body = big_image_resp;
  script[0].body_len = (uint32_t)big_image_len;
  script[1].kind = FS_NEWCONN; /* step 1: served on the REDIALED connection */
  script[1].body = image_resp;
  script[1].body_len = (uint32_t)image_len;

  memset(&sa, 0, sizeof(sa));
  sa.listener_fd = lfd;
  sa.script = script;
  sa.n_steps = sizeof(script) / sizeof(script[0]);
  sa.request_count = &served;
  pthread_create(&th, NULL, scripted_server, &sa);

  rc = strim_containerd_connect(path, "strimserver", &client);
  CHECK(rc == 0 && client != NULL);
  if (rc != 0)
    return;

  /* The oversized GetImage response overruns the client's 16 KiB buffer:
   * h2c aborts TOOBIG (-6) and the client maps it to STRIM_CTRD_ERR_PROTO.
   * With the transport_is_dead fix, the TOOBIG is a transport death: the
   * shared connection is discarded so the next RPC redials. */
  rc = strim_containerd_get_image(client, "docker.io/library/ffmpeg:latest",
                                  &img);
  CHECK(rc == STRIM_CTRD_ERR_PROTO);

  /* The second RPC must reach the server on a FRESH connection (FS_NEWCONN)
   * and succeed. Without the fix, the wedged connection would be reused, the
   * server would wait forever on accept(), and this RPC would time out (-4)
   * — the production cascade that blocked even loading the container to
   * delete it. */
  rc = strim_containerd_get_image(client, "docker.io/library/ffmpeg:latest",
                                  &img);
  CHECK(rc == 0 && img != NULL);
  CHECK(served == 2);

  strim_containerd_close(client);
  pthread_join(th, NULL);
  close(lfd);
  unlink(path);
}

int main(void) {
  test_h2c_selftest();
  test_unary_rpc();
  test_malformed_hpack_no_leak();
  test_stream_rpc();
  test_stream_next_after_peer_fin();
  test_event_pipeline();
  test_service_roundtrips();
  test_oci_spec_builder();
  test_oci_spec_cdi_hooks_and_env_dedup();
  test_oci_spec_cdi_device_cgroup_rules();
  test_chain_id();
  test_lifecycle_start();
  test_image_config_case_insensitive();
  test_lifecycle_stop();
  test_force_delete();
  test_concurrent_client();
  test_unary_flow_control_credit();
  test_grpc_status_error();
  test_new_container_large_spec();
  test_toobig_resets_shared_conn();

  if (failures == 0) {
    printf("containerd lane tests: OK\n");
    return 0;
  }
  fprintf(stderr, "containerd lane tests: %d FAILURE(S)\n", failures);
  return 1;
}