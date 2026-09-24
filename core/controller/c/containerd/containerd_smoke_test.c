/*
 * containerd_smoke_test.c — live-daemon smoke test for the containerd lane.
 *
 * Wave 3 verification (containerd lane). Two kinds of stages:
 *
 *   1. LAZY-CONNECT CONTRACT stage — ALWAYS runs, no daemon required. Proves
 *      the Wave 3 reconnect fix: strim_containerd_connect is lazy (matching
 *      Go's containerd.New), so connecting to a bogus socket must SUCCEED,
 *      and the first RPC must fail cleanly with STRIM_CTRD_ERR_CONNECT
 *      (pre-Wave-3 the connect itself failed and the caller was stuck with
 *      client == NULL forever).
 *
 *   2. LIVE CONTAINERD block — runs only when a real daemon socket is
 *      reachable (env CONTAINERD_SOCKET, else argv[1], else
 *      /run/containerd/containerd.sock). It exercises the minimal supported
 *      call: connect (lazy) + a GetImage round-trip against a known image.
 *      NO image pulls and NO container create/start/kill/wait/delete are
 *      attempted: a connect + round-trip RPC is sufficient to verify the
 *      lane's transport against a real daemon, and a full lifecycle needs
 *      image pulling, which the project's rootless-daemon CI environments
 *      cannot do (uid/gid unmappable in the user namespace, registry
 *      offline). If the socket file does not exist — or the daemon is not
 *      accepting connections — the block is reported SKIPPED and the test
 *      still exits 0, so CI without containerd stays green (modeled on
 *      //core/controller/alternate/c:cc_grpc_test).
 *
 * Exit code: 0 when every non-skipped stage passes, 1 otherwise.
 *
 * License: project code (see LICENSE). No GPL.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "containerd_client.h"

/* -------------------------------------------------------------------------
 * Stage reporting
 * ------------------------------------------------------------------------- */

static int g_failures = 0;

static void report(const char *stage, int ok, const char *detail) {
  printf("[%s] %s%s%s\n", ok ? "PASS" : "FAIL", stage,
         detail ? ": " : "", detail ? detail : "");
  if (!ok)
    g_failures++;
}

static void report_skipped(const char *stage, const char *reason) {
  printf("[SKIPPED] %s: %s\n", stage, reason);
}

/* -------------------------------------------------------------------------
 * Stage 1: lazy-connect contract (always runs, no daemon required)
 * ------------------------------------------------------------------------- */

static void lazy_connect_stage(void) {
  strim_containerd_client *client = NULL;
  strim_image *img = NULL;
  int rc;

  /* A bogus socket must NOT fail connect: Wave 3 made the connect lazy
   * (Go's containerd.New never dials). Pre-Wave-3 this returned
   * STRIM_CTRD_ERR_CONNECT and the controller kept client == NULL forever. */
  rc = strim_containerd_connect("/nonexistent/containerd.sock", "strimtest",
                                &client);
  if (rc != 0 || client == NULL) {
    report("lazy connect contract", 0,
           "connect to a bogus socket failed; Wave 3 lazy connect missing");
    return;
  }

  /* The first RPC must fail cleanly with STRIM_CTRD_ERR_CONNECT (never a
   * crash, never a hang), which is exactly the error the controller's
   * reconcile loop tolerates and retries. */
  rc = strim_containerd_get_image(client, "docker.io/library/busybox:latest",
                                  &img);
  report("lazy connect contract",
         rc == STRIM_CTRD_ERR_CONNECT && img == NULL,
         rc == STRIM_CTRD_ERR_CONNECT
             ? "bogus socket: connect ok, first RPC -> STRIM_CTRD_ERR_CONNECT"
             : "expected STRIM_CTRD_ERR_CONNECT on the first RPC");

  strim_containerd_close(client);
}

/* -------------------------------------------------------------------------
 * Stage 2: live containerd block
 * ------------------------------------------------------------------------- */

/* Returns 0 all stages pass, 1 on failure, -1 when the daemon is not
 * usable (the caller reports SKIPPED and keeps the run green). */
static int live_block(const char *sock_path, const char *namespace_,
                      const char *image) {
  strim_containerd_client *client = NULL;
  strim_image *img = NULL;
  int rc;

  /* Lazy connect always succeeds (it dials nothing); a daemon that is down
   * surfaces on the first RPC as STRIM_CTRD_ERR_CONNECT. */
  rc = strim_containerd_connect(sock_path, namespace_, &client);
  if (rc != 0 || client == NULL) {
    report("connect", 0, "connect failed");
    return 1;
  }
  report("connect", 1, sock_path);

  /* The minimal supported RPC: GetImage of a known image. A round-trip to
   * the daemon is proven by ANY response from the server:
   *   - 0            image present, full GetImage response decoded
   *   - NOTFOUND     the daemon answered (gRPC NotFound) — round-trip ok,
   *                  the image just is not imported
   *   - CONNECT      the socket exists but nothing is accepting — the
   *                  environment's daemon is not usable: SKIP
   */
  rc = strim_containerd_get_image(client, image, &img);
  if (rc == 0) {
    report("GetImage round-trip", 1, image);
  } else if (rc == STRIM_CTRD_ERR_NOTFOUND) {
    report("GetImage round-trip", 1,
           "daemon answered NotFound (image not imported)");
  } else if (rc == STRIM_CTRD_ERR_CONNECT) {
    strim_containerd_close(client);
    return -1;
  } else {
    char detail[64];
    snprintf(detail, sizeof(detail), "unexpected error (rc=%d)", rc);
    report("GetImage round-trip", 0, detail);
  }

  strim_containerd_close(client);
  return 0;
}

/* -------------------------------------------------------------------------
 * main
 * ------------------------------------------------------------------------- */

int main(int argc, char **argv) {
  const char *sock_path = getenv("CONTAINERD_SOCKET");
  const char *namespace_ = getenv("CONTAINERD_NAMESPACE");
  const char *image = getenv("CONTAINERD_IMAGE");
  int live_rc = 0;
  int live_ran = 0;

  if (sock_path == NULL || sock_path[0] == '\0')
    sock_path = (argc > 1 && argv[1][0]) ? argv[1]
                                         : "/run/containerd/containerd.sock";
  if (namespace_ == NULL || namespace_[0] == '\0')
    namespace_ = (argc > 2 && argv[2][0]) ? argv[2] : "default";
  if (image == NULL || image[0] == '\0')
    image = (argc > 3 && argv[3][0]) ? argv[3]
                                     : "docker.io/library/busybox:latest";

  printf("=== containerd lane smoke test ===\n");
  printf("socket: %s, namespace: %s, image: %s\n", sock_path, namespace_,
         image);

  lazy_connect_stage();

  printf("\n=== live containerd (%s, namespace %s) ===\n", sock_path,
         namespace_);
  if (access(sock_path, F_OK) != 0) {
    report_skipped("live containerd", "socket does not exist");
  } else {
    live_ran = 1;
    live_rc = live_block(sock_path, namespace_, image);
    if (live_rc < 0)
      report_skipped("live containerd",
                     "daemon socket present but not usable");
  }

  printf("\n=== result ===\n");
  if (g_failures == 0) {
    printf("ALL PASS%s\n", live_ran && live_rc == 0
                               ? " (lazy-connect contract + live containerd)"
                               : " (lazy-connect contract; live block skipped)");
    return 0;
  }
  printf("%d FAILURE(S)\n", g_failures);
  return 1;
}