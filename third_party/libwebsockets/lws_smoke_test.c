// libwebsockets smoke test: starts the vendored server-only libwebsockets.a
// (H1 + WS roles) on an ephemeral port, then:
//   (a) hits GET /healthz over plain HTTP and checks for 200 + "ok",
//   (b) opens a WebSocket, sends a text frame, and checks the echo.
//
// The server runs in this process (lws_context + lws_service in the main
// loop); the client side is raw POSIX sockets so the test has no dependency
// on curl/websocat. Under STANDALONE_SERVER it runs forever (for manual
// probing with curl); as a cc_test it auto-probes and exits 0 on success.

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <libwebsockets.h>

/* Set a 5s receive timeout on a socket so probes never hang the test. */
static void set_recv_timeout(int fd) {
  struct timeval tv;
  tv.tv_sec = 5;
  tv.tv_usec = 0;
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

static int g_port = 0;
static int g_failed = 0;

/* ------------------------------------------------------------------ */
/* HTTP callback: GET /healthz -> 200 "ok", everything else -> 404.    */
/* ------------------------------------------------------------------ */
static int http_cb(struct lws *wsi, enum lws_callback_reasons reason,
                   void *user, void *in, size_t len) {
  (void)user;
  char buf[96];
  switch (reason) {
  case LWS_CALLBACK_HTTP:
    if (in && len > 0 && strncmp((const char *)in, "/healthz", 8) == 0) {
      int n = snprintf(buf, sizeof(buf),
                       "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n"
                       "Connection: close\r\n\r\nok");
      lws_write(wsi, (unsigned char *)buf, (size_t)n, LWS_WRITE_HTTP_HEADERS);
      lws_write(wsi, (unsigned char *)"ok", 2, LWS_WRITE_HTTP);
      return lws_http_transaction_completed(wsi);
    }
    {
      int n = snprintf(buf, sizeof(buf),
                       "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n"
                       "Connection: close\r\n\r\n");
      lws_write(wsi, (unsigned char *)buf, (size_t)n, LWS_WRITE_HTTP_HEADERS);
      return lws_http_transaction_completed(wsi);
    }
  default:
    break;
  }
  return 0;
}

/* ------------------------------------------------------------------ */
/* WS callback: echo every text frame back.                            */
/* ------------------------------------------------------------------ */
static int echo_cb(struct lws *wsi, enum lws_callback_reasons reason,
                   void *user, void *in, size_t len) {
  (void)user;
  switch (reason) {
  case LWS_CALLBACK_RECEIVE: {
    unsigned char *buf = (unsigned char *)malloc(LWS_PRE + len);
    if (!buf)
      return -1;
    memcpy(buf + LWS_PRE, in, len);
    lws_write(wsi, buf + LWS_PRE, len, LWS_WRITE_TEXT);
    free(buf);
    break;
  }
  default:
    break;
  }
  return 0;
}

static struct lws_protocols protocols[] = {
    {"http", http_cb, 0, 0, 0, NULL, 0},
    {"echo", echo_cb, 0, 4096, 0, NULL, 0},
    LWS_PROTOCOL_LIST_TERM,
};

/* ------------------------------------------------------------------ */
/* Raw-socket HTTP client: GET path, return 1 if response starts 200.  */
/* ------------------------------------------------------------------ */
static int http_get(int port, const char *path) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in addr;
  char req[256], buf[512];
  int n, total = 0;
  if (fd < 0)
    return 0;
  set_recv_timeout(fd);
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons((uint16_t)port);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    close(fd);
    return 0;
  }
  snprintf(req, sizeof(req),
           "GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
           path);
  (void)send(fd, req, strlen(req), 0);
  while ((n = (int)recv(fd, buf + total, (size_t)(sizeof(buf) - 1 - total), 0)) > 0) {
    total += n;
    if (total >= (int)sizeof(buf) - 1)
      break;
  }
  buf[total] = '\0';
  close(fd);
  return total >= 12 && strncmp(buf, "HTTP/1.1 200", 12) == 0;
}

/* ------------------------------------------------------------------ */
/* Raw-socket WebSocket client: handshake + one masked text frame,     */
/* return 1 if the echo matches.                                       */
/* ------------------------------------------------------------------ */
static int ws_echo(int port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in addr;
  const char *payload = "hello from strimserver phase3a";
  size_t plen = strlen(payload);
  unsigned char frame[128];
  unsigned char resp[512];
  int total = 0, n;
  if (fd < 0)
    return 0;
  set_recv_timeout(fd);
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons((uint16_t)port);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    close(fd);
    return 0;
  }
  /* Handshake (Sec-WebSocket-Key is arbitrary; the server must accept). */
  const char *hs = "GET / HTTP/1.1\r\n"
                   "Host: 127.0.0.1\r\n"
                   "Upgrade: websocket\r\n"
                   "Connection: Upgrade\r\n"
                   "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
                   "Sec-WebSocket-Version: 13\r\n"
                   "Sec-WebSocket-Protocol: echo\r\n"
                   "\r\n";
  (void)send(fd, hs, strlen(hs), 0);
  while ((n = (int)recv(fd, resp + total, (size_t)(sizeof(resp) - 1 - total), 0)) > 0) {
    total += n;
    if (total >= 4 && memmem(resp, (size_t)total, "\r\n\r\n", 4))
      break;
    if (total >= (int)sizeof(resp) - 1)
      break;
  }
  if (total < 12 || strncmp((const char *)resp, "HTTP/1.1 101", 12) != 0) {
    close(fd);
    return 0;
  }
  /* Send one masked text frame. */
  size_t off = 0;
  frame[off++] = 0x81;
  if (plen < 126) {
    frame[off++] = (unsigned char)(0x80 | plen);
  } else {
    frame[off++] = 0x80 | 126;
    frame[off++] = (unsigned char)(plen >> 8);
    frame[off++] = (unsigned char)(plen & 0xff);
  }
  frame[off++] = 0x00;
  frame[off++] = 0x01;
  frame[off++] = 0x02;
  frame[off++] = 0x03;
  for (size_t i = 0; i < plen; i++)
    frame[off++] = (unsigned char)(payload[i] ^ (i % 4));
  (void)send(fd, frame, off, 0);
  /* Read the echo frame header + payload. */
  total = 0;
  while (total < 2) {
    n = (int)recv(fd, resp + total, (size_t)(2 - total), 0);
    if (n <= 0) {
      close(fd);
      return 0;
    }
    total += n;
  }
  size_t rlen = resp[1] & 0x7f;
  size_t hlen = 2;
  if (rlen == 126) {
    while (total < 4) {
      n = (int)recv(fd, resp + total, (size_t)(4 - total), 0);
      if (n <= 0) {
        close(fd);
        return 0;
      }
      total += n;
    }
    rlen = ((size_t)resp[2] << 8) | resp[3];
    hlen = 4;
  }
  while (total < (int)(hlen + rlen)) {
    n = (int)recv(fd, resp + total, (size_t)(hlen + rlen - (size_t)total), 0);
    if (n <= 0) {
      close(fd);
      return 0;
    }
    total += n;
  }
  close(fd);
  if ((resp[0] & 0x0f) != 1) /* text opcode */
    return 0;
  return (rlen == plen) && memcmp(resp + hlen, payload, plen) == 0;
}

static struct lws_context *g_ctx = NULL;

/* lws_service() sleeps until an event (its timeout is ignored since LWS
 * 3.2), so this thread runs it in a tight loop; the socket-probe threads
 * below wake it with lws_cancel_service() whenever they need a service
 * pass. */
static void *service_thread(void *arg) {
  (void)arg;
  for (;;)
    lws_service(g_ctx, 0);
  return NULL;
}

static void wake_service(void) {
  lws_cancel_service(g_ctx);
  usleep(50000);
}

int main(void) {
  struct lws_context_creation_info info;
  struct lws_vhost *vhost;
  pthread_t tid;

  memset(&info, 0, sizeof(info));
  info.port = 0; /* ephemeral */
  info.protocols = protocols;
  info.options = LWS_SERVER_OPTION_DISABLE_IPV6;

  lws_set_log_level(0, NULL);
  g_ctx = lws_create_context(&info);
  if (!g_ctx) {
    fprintf(stderr, "lws_create_context failed\n");
    return 1;
  }
  vhost = lws_get_vhost_by_name(g_ctx, "default");
  if (!vhost) {
    fprintf(stderr, "no default vhost\n");
    lws_context_destroy(g_ctx);
    return 1;
  }
  /* Let the listener come up and learn the ephemeral port. The service loop
   * only wakes on events, so cancel-service pulses drive the initial accept
   * setup; the listener is armed once the vhost reports a port. */
  for (int i = 0; i < 200 && g_port == 0; i++) {
    lws_cancel_service(g_ctx);
    lws_service(g_ctx, 0);
    usleep(10000);
  }
  g_port = lws_get_vhost_listen_port(vhost);
  if (g_port == 0) {
    fprintf(stderr, "listener did not come up\n");
    lws_context_destroy(g_ctx);
    return 1;
  }
  printf("LWS listening on 127.0.0.1:%d\n", g_port);

#ifdef STANDALONE_SERVER
  /* Manual probe mode: serve until killed. */
  for (;;)
    lws_service(g_ctx, 0);
#else
  /* Service loop in a dedicated thread so the blocking socket probes below
   * don't starve the event loop (lws_service must run concurrently). */
  pthread_create(&tid, NULL, service_thread, NULL);
  sleep(1); /* let the listener fully arm */

  {
    int probe_ok = 1;
    wake_service();
    if (!http_get(g_port, "/healthz")) {
      fprintf(stderr, "FAIL: GET /healthz did not return 200\n");
      probe_ok = 0;
    } else {
      printf("PASS: GET /healthz -> 200 ok\n");
    }
    wake_service();
    if (probe_ok && http_get(g_port, "/other")) {
      fprintf(stderr, "FAIL: GET /other should not return 200\n");
      probe_ok = 0;
    } else if (probe_ok) {
      printf("PASS: GET /other -> 404\n");
    }
    wake_service();
    if (probe_ok && !ws_echo(g_port)) {
      fprintf(stderr, "FAIL: WS echo did not round-trip\n");
      probe_ok = 0;
    } else if (probe_ok) {
      printf("PASS: WS echo round-trip\n");
    }
    if (probe_ok)
      printf("LWS SMOKE TEST PASS\n");
    else
      g_failed = 1;
  }
#endif

  lws_context_destroy(g_ctx);
  return g_failed ? 1 : 0;
}