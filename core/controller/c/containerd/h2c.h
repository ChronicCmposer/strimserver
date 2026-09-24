/*
 * h2c.h — hand-rolled HTTP/2 prior-knowledge + gRPC framing layer.
 *
 * Wave 1 (containerd lane). A minimal HTTP/2 (h2c) client that speaks
 * containerd's gRPC API over a unix socket: connection preface, HPACK header
 * encoding (static + dynamic table, Huffman decode for responses), SETTINGS /
 * PING / WINDOW_UPDATE / DATA / HEADERS / CONTINUATION / RST_STREAM / GOAWAY
 * framing, flow control, unary RPCs, and server-streaming RPCs (used for
 * Events/Subscribe and Content/Read). No gRPC C-core, no C++, pure C.
 *
 * The design is the same proven envelope as the repo's alternate/c cc_grpc
 * client (which this lane's containerd_client drives):
 *
 *   - Unix socket, HTTP/2 prior-knowledge (h2c), plaintext, no TLS.
 *   - 24-byte connection preface "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"; the
 *     FIRST frame after the preface MUST be our SETTINGS (grpc-go rejects
 *     anything else). The server's SETTINGS is ACKed; every PING is answered
 *     with PING(ACK); GOAWAY is surfaced to the caller.
 *   - Flow control: connection + stream receive windows are tracked and
 *     WINDOW_UPDATE is sent as gRPC messages are CONSUMED from the stream
 *     queue (message-granularity backpressure: a slow consumer stalls the
 *     server at the initial 64 KiB window instead of buffering unboundedly).
 *     The client never exceeds the server's stream send window.
 *   - HPACK: integer coding, the 61-entry static table, a 4096-byte dynamic
 *     table with eviction, and the RFC 7541 Huffman table for response
 *     decoding. Requests are sent plain (H=0); responses (which grpc-go
 *     Huffman-compresses) are decoded. CONTINUATION frames are handled when
 *     assembling header blocks.
 *   - Request headers: :method POST, :scheme http, :path <full method>,
 *     :authority localhost, content-type application/grpc (exact), te
 *     trailers, user-agent grpc-c/1.0, and containerd-namespace <ns> on
 *     every call (the containerd namespace interceptor requires it).
 *   - gRPC framing: every DATA payload is a 1-byte compression flag (0 =
 *     identity) + 4-byte big-endian length + protobuf bytes. Identity only,
 *     no grpc-encoding.
 *
 * THREADING: one connection is driven from one thread at a time. A blocking
 * h2c_unary internally pumps the connection, so a subscribe stream opened on
 * the SAME connection would still receive messages while the unary blocks;
 * however the containerd client lane deliberately gives each event stream its
 * OWN connection so the event listener thread and the controller thread never
 * share an fd.
 *
 * Error model: h2c_unary / h2c_stream_next return 0 on success, a positive
 * gRPC status code when the server finished the RPC with an error, or a
 * negative H2C_ERR_* for client-side failures.
 *
 * License: project code (see LICENSE). No GPL.
 */
#ifndef STRIM_H2C_H
#define STRIM_H2C_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* =========================================================================
 * gRPC status codes (google.golang.org/grpc/codes)
 * ========================================================================= */
#define H2C_STATUS_OK                  0
#define H2C_STATUS_CANCELLED           1
#define H2C_STATUS_UNKNOWN             2
#define H2C_STATUS_INVALID_ARGUMENT    3
#define H2C_STATUS_DEADLINE_EXCEEDED   4
#define H2C_STATUS_NOT_FOUND           5
#define H2C_STATUS_ALREADY_EXISTS      6
#define H2C_STATUS_PERMISSION_DENIED   7
#define H2C_STATUS_RESOURCE_EXHAUSTED  8
#define H2C_STATUS_FAILED_PRECONDITION 9
#define H2C_STATUS_ABORTED             10
#define H2C_STATUS_OUT_OF_RANGE        11
#define H2C_STATUS_UNIMPLEMENTED       12
#define H2C_STATUS_INTERNAL            13
#define H2C_STATUS_UNAVAILABLE         14
#define H2C_STATUS_DATA_LOSS           15
#define H2C_STATUS_UNAUTHENTICATED     16

/* Client-side (negative) errors. */
#define H2C_ERR_TIMEOUT   (-1) /* local deadline expired                    */
#define H2C_ERR_IO        (-2) /* socket error or EOF                       */
#define H2C_ERR_PROTO     (-3) /* protocol violation (HPACK/framing/etc)    */
#define H2C_ERR_GOAWAY    (-4) /* server sent GOAWAY; connection is dead    */
#define H2C_ERR_NOSTREAM  (-5) /* no free stream slot                       */
#define H2C_ERR_TOOBIG    (-6) /* message exceeds caller buffer / limit     */
#define H2C_ERR_BADARG    (-7) /* invalid handle/argument                   */
#define H2C_ERR_CANCEL    (-8) /* stream cancelled (RST_STREAM CANCEL)      */
#define H2C_ERR_NOCONN    (-9) /* handle valid but connection is closed     */
#define H2C_ERR_CLOSED    (-10) /* stream closed by the caller               */
#define H2C_ERR_STREAM_END (-11) /* server ended the stream cleanly (status 0) */

/* Limits (fixed-arity design). */
#define H2C_MAX_SOCK_PATH  108     /* unix socket sun_path                  */
#define H2C_MAX_NAMESPACE  64
#define H2C_MAX_MSG        (16 * 1024 * 1024) /* containerd 16 MiB max msg  */
#define H2C_MAX_HDR_MSG    2048    /* grpc-message text we retain           */
#define H2C_HANDSHAKE_MS   5000

/* =========================================================================
 * Connection
 * ========================================================================= */
typedef struct strim_h2c strim_h2c;

/* Connect to a containerd gRPC server on a unix socket and fix the namespace
 * attached to every RPC. Performs the HTTP/2 handshake synchronously
 * (preface + SETTINGS, waits for and ACKs the server's SETTINGS) with a
 * 5-second guard. Returns 0 + *out, or a negative H2C_ERR_*. */
int h2c_connect(strim_h2c **out, const char *sock_path, const char *namespace_);

/* Close the connection, cancelling any live streams. The handle is freed. */
void h2c_close(strim_h2c *c);

/* =========================================================================
 * Unary RPC
 * ========================================================================= */

/* Perform a blocking unary RPC. method is the full gRPC method path, e.g.
 * "/containerd.services.images.v1.Images/Get". req is the raw protobuf
 * request (the gRPC frame header is added internally). The response protobuf
 * is copied into resp (resp_cap) with its length in *resp_len. timeout_ms
 * bounds the whole call (a wedged server never blocks forever); 0 means the
 * default 30 s cap. Returns 0, a positive gRPC status, or a negative
 * H2C_ERR_*. */
int h2c_unary(strim_h2c *c, const char *method,
              const uint8_t *req, uint32_t req_len,
              uint8_t *resp, uint32_t resp_cap, uint32_t *resp_len,
              int64_t timeout_ms);

/* =========================================================================
 * Server-streaming RPC (Events/Subscribe, Content/Read)
 * ========================================================================= */
typedef struct strim_h2c_stream strim_h2c_stream;

/* Open a server-streaming RPC: send the request headers + gRPC-framed DATA
 * and wait for the initial response headers. Returns 0 + *out. */
int h2c_stream_open(strim_h2c *c, const char *method,
                    const uint8_t *req, uint32_t req_len,
                    strim_h2c_stream **out);

/* Block for the next message on the stream. On success returns 0, sets *msg
 * to an internal buffer (valid until the next call) and *len to its length.
 * Returns H2C_ERR_TIMEOUT when timeout_ms elapses first (message untouched),
 * H2C_ERR_CLOSED when the stream was closed by the caller,
 * H2C_ERR_STREAM_END when the server ended the stream cleanly, a positive
 * gRPC status when the server ended the stream with an error status (the
 * message untouched), or a negative H2C_ERR_*. */
int h2c_stream_next(strim_h2c_stream *s, int64_t timeout_ms,
                    const uint8_t **msg, uint32_t *len);

/* Cancel the stream (RST_STREAM CANCEL) and release its resources. After
 * this, h2c_stream_next returns H2C_ERR_CLOSED. */
void h2c_stream_close(strim_h2c_stream *s);

/* Run the internal HPACK / HTTP/2 unit self-tests (RFC 7541 vectors for
 * Huffman, integer coding, static/dynamic tables, header-block encoding, and
 * frame I/O via socketpair). No daemon required. Returns the number of
 * failed checks (0 = all pass). `verbose` prints per-section results. */
int h2c_selftest(int verbose);

#ifdef __cplusplus
}
#endif

#endif /* STRIM_H2C_H */