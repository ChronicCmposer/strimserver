/*
 * Scratch smoke test for the vendored libmicrohttpd 1.0.10 build.
 *
 * Serves GET /healthz on an ephemeral port with two daemon modes and asserts
 * HTTP/1.1 200 + "hello" body on a raw-socket client:
 *
 *   A) MHD_USE_INTERNAL_POLLING_THREAD | MHD_USE_POLL | MHD_USE_ITC — the
 *      library's own polling thread runs the daemon.
 *   B) MHD_USE_EPOLL | MHD_USE_ITC — no internal thread; the caller folds
 *      MHD_run() into its own loop (the single-threaded-core controller
 *      pattern): connect -> send request -> MHD_run() -> read response.
 *
 * The client uses a bare TCP socket (no libcurl dependency) and the test
 * links -static -lpthread, matching //third_party/libwebsockets:lws_smoke_test.
 */

#include "microhttpd.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int failures = 0;

/* Counts GET requests; lets the test assert the handler ran. */
static unsigned int healthz_hits = 0;

static enum MHD_Result
answer_healthz(void *cls, struct MHD_Connection *connection, const char *url,
               const char *method, const char *version, const char *upload_data,
               size_t *upload_data_size, void **con_cls)
{
  (void) cls;
  (void) url;
  (void) version;
  (void) upload_data;
  (void) upload_data_size;
  (void) con_cls;

  if (0 != strcmp(method, "GET"))
    return MHD_NO;

  ++healthz_hits;

  const char *body = "hello";
  struct MHD_Response *resp =
      MHD_create_response_from_buffer(strlen(body), (void *) body,
                                      MHD_RESPMEM_PERSISTENT);
  if (NULL == resp)
    return MHD_NO;
  enum MHD_Result r = MHD_queue_response(connection, MHD_HTTP_OK, resp);
  MHD_destroy_response(resp);
  return r;
}

/* Raw-socket HTTP/1.1 client: returns 0 and fills resp_buf on success. */
static int
http_get(const char *host, uint16_t port, char *resp_buf, size_t resp_buf_size)
{
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0)
  {
    perror("socket");
    return -1;
  }

  struct sockaddr_in sa;
  memset(&sa, 0, sizeof(sa));
  sa.sin_family = AF_INET;
  sa.sin_port = htons(port);
  if (1 != inet_pton(AF_INET, host, &sa.sin_addr))
  {
    perror("inet_pton");
    close(fd);
    return -1;
  }

  if (0 != connect(fd, (struct sockaddr *) &sa, sizeof(sa)))
  {
    perror("connect");
    close(fd);
    return -1;
  }

  const char req[] = "GET /healthz HTTP/1.1\r\n"
                     "Host: localhost\r\n"
                     "Connection: close\r\n"
                     "\r\n";
  size_t off = 0;
  while (off < sizeof(req) - 1)
  {
    ssize_t n = send(fd, req + off, sizeof(req) - 1 - off, 0);
    if (n <= 0)
    {
      perror("send");
      close(fd);
      return -1;
    }
    off += (size_t) n;
  }

  size_t got = 0;
  while (got + 1 < resp_buf_size)
  {
    ssize_t n = recv(fd, resp_buf + got, resp_buf_size - 1 - got, 0);
    if (n <= 0)
      break; /* EOF or error: we have whatever arrived */
    got += (size_t) n;
  }
  resp_buf[got] = '\0';
  close(fd);
  return 0;
}

static void
check_response(const char *scenario, const char *resp)
{
  if (NULL == strstr(resp, "200 OK"))
  {
    fprintf(stderr, "[%s] FAIL: no '200 OK' in response:\n%s\n", scenario,
            resp);
    ++failures;
    return;
  }
  if (NULL == strstr(resp, "hello"))
  {
    fprintf(stderr, "[%s] FAIL: no 'hello' body in response:\n%s\n", scenario,
            resp);
    ++failures;
    return;
  }
  printf("[%s] PASS: got 200 OK + body\n", scenario);
}

/* Scenario A: internal polling thread. */
static void
test_internal_polling_thread(void)
{
  const char *scenario = "internal-polling-thread";
  struct MHD_Daemon *d = MHD_start_daemon(
      MHD_USE_INTERNAL_POLLING_THREAD | MHD_USE_POLL | MHD_USE_ITC |
          MHD_USE_ERROR_LOG,
      0 /* ephemeral port */,
      NULL, NULL, &answer_healthz, NULL,
      MHD_OPTION_END);
  if (NULL == d)
  {
    fprintf(stderr, "[%s] FAIL: MHD_start_daemon\n", scenario);
    ++failures;
    return;
  }

  const union MHD_DaemonInfo *info =
      MHD_get_daemon_info(d, MHD_DAEMON_INFO_BIND_PORT);
  if (NULL == info || 0 == info->port)
  {
    fprintf(stderr, "[%s] FAIL: BIND_PORT info\n", scenario);
    ++failures;
    MHD_stop_daemon(d);
    return;
  }

  char resp[4096];
  if (0 != http_get("127.0.0.1", info->port, resp, sizeof(resp)))
  {
    fprintf(stderr, "[%s] FAIL: http_get\n", scenario);
    ++failures;
    MHD_stop_daemon(d);
    return;
  }
  check_response(scenario, resp);
  MHD_stop_daemon(d);
}

/* Scenario B: external event loop — the caller folds MHD_run() into its own
 * single-threaded loop (connect -> MHD_run -> read). */
static void
test_external_event_loop(void)
{
  const char *scenario = "external-event-loop";
  struct MHD_Daemon *d = MHD_start_daemon(
      MHD_USE_EPOLL | MHD_USE_ITC | MHD_USE_ERROR_LOG,
      0 /* ephemeral port */,
      NULL, NULL, &answer_healthz, NULL,
      MHD_OPTION_END);
  if (NULL == d)
  {
    fprintf(stderr, "[%s] FAIL: MHD_start_daemon\n", scenario);
    ++failures;
    return;
  }

  const union MHD_DaemonInfo *info =
      MHD_get_daemon_info(d, MHD_DAEMON_INFO_BIND_PORT);
  if (NULL == info || 0 == info->port)
  {
    fprintf(stderr, "[%s] FAIL: BIND_PORT info\n", scenario);
    ++failures;
    MHD_stop_daemon(d);
    return;
  }

  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0)
  {
    perror("socket");
    ++failures;
    MHD_stop_daemon(d);
    return;
  }
  struct sockaddr_in sa;
  memset(&sa, 0, sizeof(sa));
  sa.sin_family = AF_INET;
  sa.sin_port = htons(info->port);
  if (1 != inet_pton(AF_INET, "127.0.0.1", &sa.sin_addr))
  {
    perror("inet_pton");
    close(fd);
    MHD_stop_daemon(d);
    ++failures;
    return;
  }
  if (0 != connect(fd, (struct sockaddr *) &sa, sizeof(sa)))
  {
    perror("connect");
    close(fd);
    MHD_stop_daemon(d);
    ++failures;
    return;
  }

  const char req[] = "GET /healthz HTTP/1.1\r\n"
                     "Host: localhost\r\n"
                     "Connection: close\r\n"
                     "\r\n";
  size_t off = 0;
  while (off < sizeof(req) - 1)
  {
    ssize_t n = send(fd, req + off, sizeof(req) - 1 - off, 0);
    if (n <= 0)
    {
      perror("send");
      close(fd);
      MHD_stop_daemon(d);
      ++failures;
      return;
    }
    off += (size_t) n;
  }

  /* Fold MHD into the caller's loop: process the pending connection,
   * request and response entirely from this thread. Note healthz_hits is a
   * global shared across scenarios, so compare against the value we start
   * with (scenario A may have already incremented it). */
  const unsigned int hits_before = healthz_hits;
  for (int i = 0; i < 10; ++i)
  {
    if (MHD_YES != MHD_run(d))
      break;
    if (healthz_hits > hits_before)
      break;
  }

  char resp[4096];
  size_t got = 0;
  while (got + 1 < sizeof(resp))
  {
    ssize_t n = recv(fd, resp + got, sizeof(resp) - 1 - got, 0);
    if (n <= 0)
      break;
    got += (size_t) n;
  }
  resp[got] = '\0';
  close(fd);

  if (healthz_hits == hits_before)
  {
    fprintf(stderr, "[%s] FAIL: answer callback never ran (response=%s)\n",
            scenario, resp);
    ++failures;
    MHD_stop_daemon(d);
    return;
  }
  check_response(scenario, resp);
  MHD_stop_daemon(d);
}

int
main(void)
{
  test_internal_polling_thread();
  test_external_event_loop();

  if (failures != 0)
  {
    fprintf(stderr, "mhd_smoke_test: %d failure(s)\n", failures);
    return 1;
  }
  printf("mhd_smoke_test: all scenarios passed\n");
  return 0;
}