/*
 * Scratch smoke test for the vendored wslay 1.1.1 build.
 *
 * WebSocket echo over a socketpair using the wslay event API (the API the
 * controller uses after libmicrohttpd hands over the upgraded socket):
 * client queues a text frame, server's on_msg_recv callback echoes it, client
 * verifies the round trip. No HTTP handshake is needed — wslay only does
 * RFC 6455 framing, and both ends are in-process wslay contexts.
 *
 * Both socketpair ends are non-blocking; the test pumps both contexts in a
 * loop (send/recv each iteration) until the echo arrives or the cap hits.
 * The static link needs nothing beyond -static: wslay pulls in no libm,
 * libdl, or pthread symbols.
 */

#include <wslay/wslay.h>

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int failures = 0;

struct endpoint
{
  int fd;
  int got_echo;
  const uint8_t *expected;
  size_t expected_len;
};

static ssize_t
send_cb(wslay_event_context_ptr ctx, const uint8_t *data, size_t len, int flags,
        void *user_data)
{
  (void) ctx;
  (void) flags;
  struct endpoint *ep = (struct endpoint *) user_data;
  ssize_t r = send(ep->fd, data, len, 0);
  if (r == -1 && (errno == EAGAIN || errno == EWOULDBLOCK))
    return WSLAY_ERR_WOULDBLOCK;
  return r;
}

static ssize_t
recv_cb(wslay_event_context_ptr ctx, uint8_t *buf, size_t len, int flags,
        void *user_data)
{
  (void) ctx;
  (void) flags;
  struct endpoint *ep = (struct endpoint *) user_data;
  ssize_t r = recv(ep->fd, buf, len, 0);
  if (r == -1 && (errno == EAGAIN || errno == EWOULDBLOCK))
    return WSLAY_ERR_WOULDBLOCK;
  if (r == 0)
    return WSLAY_ERR_CALLBACK_FAILURE; /* unexpected EOF */
  return r;
}

/* Client-side masking key generator: deterministic LCG (masking value is
 * protocol-internal, so cryptographic quality is irrelevant here). */
static int
genmask_cb(wslay_event_context_ptr ctx, uint8_t *buf, size_t len,
           void *user_data)
{
  (void) ctx;
  (void) user_data;
  static unsigned int seed = 0x20260923u;
  for (size_t i = 0; i < len; ++i)
  {
    seed = seed * 1103515245u + 12345u;
    buf[i] = (uint8_t) (seed >> 16);
  }
  return 0;
}

/* Server side: echo every received text message back. */
static void
echo_on_msg_recv(wslay_event_context_ptr ctx,
                 const struct wslay_event_on_msg_recv_arg *arg, void *user_data)
{
  (void) user_data;
  struct wslay_event_msg msg;
  msg.opcode = arg->opcode;
  msg.msg = arg->msg;
  msg.msg_length = arg->msg_length;
  wslay_event_queue_msg(ctx, &msg);
}

/* Client side: verify the echoed message matches what we sent. */
static void
client_on_msg_recv(wslay_event_context_ptr ctx,
                   const struct wslay_event_on_msg_recv_arg *arg,
                   void *user_data)
{
  (void) ctx;
  struct endpoint *ep = (struct endpoint *) user_data;
  if (arg->msg_length == ep->expected_len &&
      0 == memcmp(arg->msg, ep->expected, ep->expected_len))
  {
    ep->got_echo = 1;
  }
  else
  {
    fprintf(stderr, "wslay_smoke_test: echo mismatch (got %zu bytes)\n",
            arg->msg_length);
    ++failures;
  }
}

static int
set_nonblocking(int fd)
{
  int fl = fcntl(fd, F_GETFL, 0);
  if (fl == -1)
    return -1;
  return fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

int
main(void)
{
  const uint8_t payload[] = "hello from wslay";

  struct endpoint client_ep;
  struct endpoint server_ep;
  memset(&client_ep, 0, sizeof(client_ep));
  memset(&server_ep, 0, sizeof(server_ep));
  client_ep.expected = payload;
  client_ep.expected_len = sizeof(payload) - 1;

  int sv[2];
  if (0 != socketpair(AF_UNIX, SOCK_STREAM, 0, sv))
  {
    perror("socketpair");
    return 1;
  }
  client_ep.fd = sv[0];
  server_ep.fd = sv[1];
  if (0 != set_nonblocking(sv[0]) || 0 != set_nonblocking(sv[1]))
  {
    perror("fcntl");
    return 1;
  }

  struct wslay_event_callbacks client_cbs;
  struct wslay_event_callbacks server_cbs;
  memset(&client_cbs, 0, sizeof(client_cbs));
  memset(&server_cbs, 0, sizeof(server_cbs));
  client_cbs.recv_callback = recv_cb;
  client_cbs.send_callback = send_cb;
  client_cbs.genmask_callback = genmask_cb;
  client_cbs.on_msg_recv_callback = client_on_msg_recv;
  server_cbs.recv_callback = recv_cb;
  server_cbs.send_callback = send_cb;
  server_cbs.on_msg_recv_callback = echo_on_msg_recv;

  wslay_event_context_ptr cctx = NULL;
  wslay_event_context_ptr sctx = NULL;
  if (0 != wslay_event_context_client_init(&cctx, &client_cbs, &client_ep))
  {
    fprintf(stderr, "wslay_smoke_test: client init failed\n");
    return 1;
  }
  if (0 != wslay_event_context_server_init(&sctx, &server_cbs, &server_ep))
  {
    fprintf(stderr, "wslay_smoke_test: server init failed\n");
    return 1;
  }

  struct wslay_event_msg msg;
  msg.opcode = WSLAY_TEXT_FRAME;
  msg.msg = payload;
  msg.msg_length = sizeof(payload) - 1;
  if (0 != wslay_event_queue_msg(cctx, &msg))
  {
    fprintf(stderr, "wslay_smoke_test: queue_msg failed\n");
    return 1;
  }

  /* Pump both contexts until the echo comes back (or the cap hits). */
  int iter;
  for (iter = 0; iter < 10000 && 0 == client_ep.got_echo; ++iter)
  {
    (void) wslay_event_send(cctx);
    (void) wslay_event_recv(cctx);
    (void) wslay_event_send(sctx);
    (void) wslay_event_recv(sctx);
  }

  wslay_event_context_free(cctx);
  wslay_event_context_free(sctx);
  close(sv[0]);
  close(sv[1]);

  if (0 == client_ep.got_echo)
  {
    fprintf(stderr, "wslay_smoke_test: FAIL: echo never arrived\n");
    ++failures;
  }
  else
  {
    printf("wslay_smoke_test: PASS: client->server->client echo in %d "
           "pump iterations\n", iter);
  }

  if (failures != 0)
  {
    fprintf(stderr, "wslay_smoke_test: %d failure(s)\n", failures);
    return 1;
  }
  return 0;
}