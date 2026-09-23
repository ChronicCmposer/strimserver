/*
 * cc_grpc.h — hand-written HTTP/2 (h2c) + gRPC client for containerd.
 *
 * Phase 3b of the ARM controller rewrite. This is the C protocol layer that
 * the assembly controller (core/controller/alternate/asm/) drives for all containerd
 * gRPC work: unary RPCs and the long-lived Events/Subscribe server stream.
 *
 * Protocol envelope (verified against containerd's grpc-go server):
 *   - Unix socket, HTTP/2 prior-knowledge (h2c), plaintext, no TLS, no HTTP/1.1.
 *   - 24-byte connection preface: "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".
 *   - The FIRST frame after the preface MUST be SETTINGS (grpc-go rejects
 *     anything else); the server's SETTINGS is ACKed; every PING is answered
 *     with PING(ACK); GOAWAY is surfaced to the caller.
 *   - Flow control: connection + stream receive windows are tracked and
 *     WINDOW_UPDATE is sent as DATA is consumed. Windows are MUTABLE
 *     (grpc-go BDP estimation): every WINDOW_UPDATE frame is applied, and the
 *     client never exceeds the server's stream send window.
 *   - Full HPACK: integer coding, the 61-entry static table, the 257-entry
 *     Huffman table, and the 4096-byte dynamic table with eviction.
 *     CONTINUATION frames are handled when assembling header blocks.
 *   - Request headers: :method POST, :scheme http, :path <full method>,
 *     :authority localhost (exactly one), content-type application/grpc
 *     (exact), te trailers, user-agent grpc-c/1.0, and
 *     containerd-namespace <ns> on EVERY call (the containerd plugin
 *     interceptor returns FailedPrecondition without it).
 *   - gRPC framing: every DATA carries 1 flag byte (0 = identity) + 4-byte
 *     big-endian length + protobuf bytes. Identity encoding only, never
 *     grpc-encoding, no compression.
 *
 * DESIGN: the client owns HPACK state and flow control per connection.
 * cc_grpc_poll drives the connection: it reads frames, ACKs settings/pings,
 * dispatches stream envelopes through the subscribe callback, and enforces
 * timeouts. cc_grpc_unary submits a request and BLOCKS until that RPC
 * completes (it internally pumps the connection, so subscription envelopes
 * still arrive while a unary call is in flight); cc_grpc_subscribe submits a
 * server-streaming request and returns immediately — the caller then drives
 * cc_grpc_poll.
 *
 * CALLING RULES (assembly author, read carefully):
 *   - All functions are fixed-arity, AAPCS64-friendly (no varargs; int
 *     returns; caller-provided buffers). The library never allocates on the
 *     caller's behalf beyond internal scratch.
 *   - A subscribe callback runs from inside cc_grpc_poll (or from inside a
 *     blocking cc_grpc_unary). It MUST NOT call back into this library, and
 *     the envelope pointer is only valid for the duration of the callback.
 *   - The library is single-threaded per connection. It is not re-entrant.
 *
 * License: project code (see LICENSE). No GPL.
 */
#ifndef CC_GRPC_H
#define CC_GRPC_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* =========================================================================
 * Constants
 * ========================================================================= */

/* gRPC status codes (google.golang.org/grpc/codes). cc_grpc_unary returns
 * these directly on RPC completion. */
#define CC_GRPC_STATUS_OK                  0
#define CC_GRPC_STATUS_CANCELLED           1
#define CC_GRPC_STATUS_UNKNOWN             2
#define CC_GRPC_STATUS_INVALID_ARGUMENT    3
#define CC_GRPC_STATUS_DEADLINE_EXCEEDED   4
#define CC_GRPC_STATUS_NOT_FOUND           5
#define CC_GRPC_STATUS_ALREADY_EXISTS      6
#define CC_GRPC_STATUS_PERMISSION_DENIED   7
#define CC_GRPC_STATUS_RESOURCE_EXHAUSTED  8
#define CC_GRPC_STATUS_FAILED_PRECONDITION 9
#define CC_GRPC_STATUS_ABORTED             10
#define CC_GRPC_STATUS_OUT_OF_RANGE        11
#define CC_GRPC_STATUS_UNIMPLEMENTED       12
#define CC_GRPC_STATUS_INTERNAL            13
#define CC_GRPC_STATUS_UNAVAILABLE         14
#define CC_GRPC_STATUS_DATA_LOSS           15
#define CC_GRPC_STATUS_UNAUTHENTICATED     16

/* Client-side (negative) error codes returned by cc_grpc_unary /
 * cc_grpc_stream_status. Positive values are gRPC status codes. */
#define CC_GRPC_ERR_TIMEOUT   (-1) /* local deadline expired while waiting   */
#define CC_GRPC_ERR_IO        (-2) /* socket error or EOF                    */
#define CC_GRPC_ERR_PROTO     (-3) /* protocol violation (HPACK/framing/etc) */
#define CC_GRPC_ERR_GOAWAY    (-4) /* server sent GOAWAY; connection is dead */
#define CC_GRPC_ERR_NOSTREAM  (-5) /* no free stream slot / conn busy        */
#define CC_GRPC_ERR_TOOBIG    (-6) /* response exceeds the caller's buffer   */
#define CC_GRPC_ERR_BADARG    (-7) /* invalid handle/argument                */
#define CC_GRPC_ERR_CANCEL    (-8) /* stream cancelled (RST_STREAM CANCEL)   */
#define CC_GRPC_ERR_NOCONN    (-9) /* handle valid but connection is closed  */

/* Event codes returned by cc_grpc_poll. */
#define CC_GRPC_EV_NONE       0  /* timeout, no progress                     */
#define CC_GRPC_EV_MSG        1  /* a message was delivered (subscribe cb or
                                    unary completion)                        */
#define CC_GRPC_EV_STREAM_END 2  /* a subscribe stream ended (trailers seen);
                                    query cc_grpc_stream_status              */
#define CC_GRPC_EV_GOAWAY     3  /* GOAWAY received; connection must be
                                    recreated by the caller                  */
#define CC_GRPC_EV_IO         4  /* socket error / EOF; connection is dead   */
#define CC_GRPC_EV_PROTO      5  /* protocol violation; connection is dead   */

/* Limits (fixed-arity design: no unbounded caller buffers). */
#define CC_GRPC_MAX_SOCK_PATH 108     /* unix socket path (sun_path)         */
#define CC_GRPC_MAX_NAMESPACE 64
#define CC_GRPC_MAX_MSG       16777215 /* gRPC 4-byte length max (2^24-1)     */
#define CC_GRPC_MAX_HDR_MSG   2048     /* grpc-message text we retain         */

/* Default local deadline for cc_grpc_unary when no timeout was configured.
 * The server's own grpc-timeout (if the assembly sets one via
 * cc_grpc_set_unary_timeout) also bounds the call; this is the hard local
 * cap so a wedged server never blocks the controller forever. */
#define CC_GRPC_DEFAULT_UNARY_TIMEOUT_MS 30000

/* =========================================================================
 * API (fixed arity; all handles are small positive ints)
 * ========================================================================= */

/* Open a connection to containerd's gRPC server on a unix socket.
 *
 *   sock_path:  unix socket path (e.g. "/run/containerd/containerd.sock").
 *               NULL or "" defaults to "/run/containerd/containerd.sock".
 *   namespace:  containerd namespace sent on EVERY RPC (mandatory header).
 *               NULL or "" defaults to "default".
 *
 * Performs the HTTP/2 handshake synchronously (preface + SETTINGS, waits for
 * and ACKs the server's SETTINGS) with a 5s guard. Returns a connection
 * handle > 0 on success, or 0 on failure (socket connect, handshake
 * timeout, protocol error). The returned handle is an index into an
 * internal fixed table (CC_GRPC_MAX_CONNS); close it with cc_grpc_close. */
int cc_grpc_init(const char *sock_path, const char *namespace_);

/* Perform a blocking unary RPC.
 *
 *   h:         connection handle from cc_grpc_init.
 *   method:    full gRPC method path, e.g.
 *              "/containerd.services.version.v1.Version/Version".
 *   req/req_len:   request message bytes (raw protobuf, NO gRPC frame
 *              header — the library adds it).
 *   resp/resp_cap: caller-provided response buffer. The protobuf message
 *              bytes are copied here on success (resp_len set).
 *   resp_len:  on success, the number of bytes written to resp.
 *
 * Returns the gRPC status code (>= 0) on RPC completion, or a negative
 * CC_GRPC_ERR_* code for client-side failures. On non-zero status the
 * server's grpc-message is retained for cc_grpc_errstr. This call blocks
 * until the RPC completes, the local deadline expires, or the connection
 * dies; subscription envelopes still dispatch during the block. */
int cc_grpc_unary(int h, const char *method,
                  const uint8_t *req, uint32_t req_len,
                  uint8_t *resp, uint32_t resp_cap, uint32_t *resp_len);

/* Open a server-streaming subscription (Events/Subscribe) on the connection.
 *
 *   h:       connection handle.
 *   filter:  containerd event filter, e.g. `topic~="/tasks/.*"` (regex).
 *            NOTE: containerd 2.x treats `/` as a quote rune, so topic
 *            values must be quoted; a bare `/tasks/.*` is rejected by the
 *            server's filter parser. The string is forwarded verbatim as
 *            one SubscribeRequest filter element.
 *   cb_ctx:  opaque pointer passed back to the callback.
 *   cb:      invoked for every envelope: cb(cb_ctx, envelope_bytes, len)
 *            with the raw protobuf of containerd.types.Envelope. The pointer
 *            is only valid for the duration of the call; the callback must
 *            not re-enter the library.
 *
 * Returns the stream id (> 0) on success, or 0 on failure. The stream is
 * driven by cc_grpc_poll; when the server ends it (trailers) or it fails,
 * cc_grpc_poll returns CC_GRPC_EV_STREAM_END / an error and
 * cc_grpc_stream_status reports the outcome. The caller re-subscribes on
 * stream loss (no replay). */
int cc_grpc_subscribe(int h, const char *filter, void *cb_ctx,
                      void (*cb)(void *cb_ctx, const uint8_t *env,
                                 uint32_t len));

/* Drive the connection: read and process frames until the timeout expires.
 * Dispatches subscribe envelopes, completes unary calls, ACKs server
 * SETTINGS/PING, applies flow control, and detects GOAWAY/errors.
 *
 *   h:         connection handle.
 *   timeout_ms: poll timeout in milliseconds (0 = non-blocking probe,
 *               < 0 = block until an event).
 *
 * Returns one of the CC_GRPC_EV_* codes. CC_GRPC_EV_MSG means at least one
 * message was delivered; CC_GRPC_EV_STREAM_END means a subscription stream
 * ended (check cc_grpc_stream_status); CC_GRPC_EV_GOAWAY/IO/PROTO mean the
 * connection can no longer be used. */
int cc_grpc_poll(int h, int timeout_ms);

/* Cancel a stream (send RST_STREAM CANCEL) and free its slot.
 * 0 on success, negative CC_GRPC_ERR_* otherwise. The connection stays up. */
int cc_grpc_cancel(int h, int stream_id);

/* Query the state of a stream created by cc_grpc_subscribe:
 *   0          stream is active
 *   > 0        gRPC status code, stream finished
 *   < 0        CC_GRPC_ERR_* (stream was cancelled / connection died)
 *   CC_GRPC_ERR_NOSTREAM if the stream id is not allocated. */
int cc_grpc_stream_status(int h, int stream_id);

/* Copy the last server-provided grpc-message text into buf (NUL-terminated,
 * at most cap-1 bytes, percent-decoded). grpc_status selects which stored
 * message to return: > 0 matches the most recent message with that status,
 * 0 returns the most recent message of any status. Returns the gRPC status
 * the message belongs to, or CC_GRPC_ERR_NOCONN / -1 when nothing is
 * stored. */
int cc_grpc_errstr(int h, int grpc_status, char *buf, uint32_t cap);

/* Configure the local deadline and the grpc-timeout header for subsequent
 * cc_grpc_unary calls on this connection.
 *
 *   timeout_ns: 0 disables the grpc-timeout header (the server default
 *               applies) but keeps the local CC_GRPC_DEFAULT_UNARY_TIMEOUT_MS
 *               cap. A positive value is sent as grpc-timeout (1-8 digits +
 *               unit, per the gRPC spec) AND enforced locally.
 *
 * Returns 0 on success, negative on bad handle. */
int cc_grpc_set_unary_timeout(int h, uint64_t timeout_ns);

/* Tear down the connection: RST_STREAM(CANCEL) any active streams, close the
 * socket, release HPACK state. The handle becomes invalid. */
void cc_grpc_close(int h);

/* Version/API info for the assembly author and diagnostics. */
const char *cc_grpc_version(void);

/* Run the internal HPACK / HTTP/2 unit self-tests (known RFC 7541 vectors
 * for Huffman, integer coding, the static/dynamic tables, header-block
 * encoding, and frame I/O). No daemon required. Returns the number of
 * failed checks (0 = all pass). `verbose` prints per-section results. */
int cc_grpc_selftest(int verbose);

#ifdef __cplusplus
}
#endif

#endif /* CC_GRPC_H */