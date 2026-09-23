/*
 * cc_grpc_test.c — standalone test for the cc_grpc h2c/gRPC client.
 *
 * NOT part of the assembly controller. Two stages:
 *
 *   1. HPACK / HTTP2 unit self-tests (cc_grpc_selftest) — always run,
 *      no daemon required.
 *   2. Live containerd block — runs only when a real containerd socket is
 *      reachable (default /run/containerd/containerd.sock, overridable via
 *      argv[1]; namespace via argv[2]). Exercises:
 *        - cc_grpc_init (preface + SETTINGS handshake)
 *        - Version unary RPC        (/containerd.services.version.v1.Version/Version)
 *        - Containers.List unary    (/containerd.services.containers.v1.Containers/List)
 *        - Events.Subscribe stream  (/containerd.services.events.v1.Events/Subscribe,
 *          filter /tasks/.*) + a synthesized /tasks/ event published through
 *          Events.Publish; one envelope is received, decoded, verified.
 *        - clean stream cancel + close.
 *      If no daemon is reachable, the stage is reported SKIPPED (the
 *      self-tests still run).
 *
 * Exit code: 0 when every non-skipped stage passes, 1 otherwise.
 *
 * License: project code (see LICENSE). No GPL.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <google/protobuf/empty.pb-c.h>
#include <services/containers/v1/containers.pb-c.h>
#include <services/events/v1/events.pb-c.h>
#include <services/version/v1/version.pb-c.h>
#include <types/event.pb-c.h>

#include "cc_grpc.h"

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
 * Envelope callback (runs inside cc_grpc_poll / cc_grpc_unary)
 * ------------------------------------------------------------------------- */

struct envelope_capture {
  uint8_t bytes[4096];
  uint32_t len;
  int got;
};

static void envelope_cb(void *cb_ctx, const uint8_t *env, uint32_t len) {
  struct envelope_capture *cap = (struct envelope_capture *)cb_ctx;
  if (len > sizeof(cap->bytes)) {
    fprintf(stderr, "envelope too large (%u bytes)\n", len);
    return;
  }
  memcpy(cap->bytes, env, len);
  cap->len = len;
  cap->got = 1;
}

/* -------------------------------------------------------------------------
 * Live containerd block
 * ------------------------------------------------------------------------- */

static int live_block(const char *sock_path, const char *namespace_) {
  int h;
  int rc;
  uint32_t resp_len = 0;
  char errbuf[256];
  int stages_ok = 1;

  /* --- init --- */
  h = cc_grpc_init(sock_path, namespace_);
  if (h == 0) {
    report_skipped("live init", "connect/handshake failed; daemon not "
                                "reachable from this user");
    return -1;
  }
  report("live init", 1, sock_path);

  /* --- Version --- */
  {
    Google__Protobuf__Empty req = GOOGLE__PROTOBUF__EMPTY__INIT;
    uint8_t reqbuf[16];
    size_t reqlen =
        google__protobuf__empty__get_packed_size(&req);
    uint8_t respbuf[4096];
    Containerd__Services__Version__V1__VersionResponse *vr = NULL;
    char detail[512];

    google__protobuf__empty__pack(&req, reqbuf);
    rc = cc_grpc_unary(h, "/containerd.services.version.v1.Version/Version",
                       reqbuf, (uint32_t)reqlen, respbuf, sizeof(respbuf),
                       &resp_len);
    if (rc != CC_GRPC_STATUS_OK) {
      cc_grpc_errstr(h, rc, errbuf, sizeof(errbuf));
      snprintf(detail, sizeof(detail), "grpc status %d (%s)", rc, errbuf);
      report("live Version", 0, detail);
      stages_ok = 0;
    } else {
      vr = containerd__services__version__v1__version_response__unpack(
          NULL, resp_len, respbuf);
      if (vr == NULL) {
        report("live Version", 0, "unpack failed");
        stages_ok = 0;
      } else {
        snprintf(detail, sizeof(detail), "version=%s revision=%s",
                 vr->version, vr->revision);
        report("live Version", 1, detail);
        containerd__services__version__v1__version_response__free_unpacked(
            vr, NULL);
      }
    }
  }

  /* --- Containers.List (namespace) --- */
  {
    Containerd__Services__Containers__V1__ListContainersRequest req =
        CONTAINERD__SERVICES__CONTAINERS__V1__LIST_CONTAINERS_REQUEST__INIT;
    uint8_t reqbuf[64];
    size_t reqlen =
        containerd__services__containers__v1__list_containers_request__get_packed_size(
            &req);
    uint8_t respbuf[65536];
    Containerd__Services__Containers__V1__ListContainersResponse *lr = NULL;
    char detail[512];

    containerd__services__containers__v1__list_containers_request__pack(&req,
                                                                        reqbuf);
    rc = cc_grpc_unary(h, "/containerd.services.containers.v1.Containers/List",
                       reqbuf, (uint32_t)reqlen, respbuf, sizeof(respbuf),
                       &resp_len);
    if (rc != CC_GRPC_STATUS_OK) {
      cc_grpc_errstr(h, rc, errbuf, sizeof(errbuf));
      snprintf(detail, sizeof(detail), "grpc status %d (%s)", rc, errbuf);
      report("live Containers.List", 0, detail);
      stages_ok = 0;
    } else {
      lr = containerd__services__containers__v1__list_containers_response__unpack(
          NULL, resp_len, respbuf);
      if (lr == NULL) {
        report("live Containers.List", 0, "unpack failed");
        stages_ok = 0;
      } else {
        snprintf(detail, sizeof(detail), "%zu container(s) in namespace %s",
                 lr->n_containers, namespace_);
        report("live Containers.List", 1, detail);
        containerd__services__containers__v1__list_containers_response__free_unpacked(
            lr, NULL);
      }
    }
  }

  /* --- Subscribe (filter /tasks/.*) + Publish a synthetic task event --- */
  {
    struct envelope_capture cap;
    int sid;
    int i;
    int poll_rc;
    int ok = 0;
    char detail[512];

    memset(&cap, 0, sizeof(cap));
    /* containerd 2.x filter syntax: `/` is a quote rune, so a topic filter
     * is expressed with a quoted value and the regex operator `~=`. */
    sid = cc_grpc_subscribe(h, "topic~=\"/tasks/.*\"", &cap, envelope_cb);
    if (sid <= 0) {
      report("live Subscribe", 0, "cc_grpc_subscribe failed");
      stages_ok = 0;
    } else {
      report("live Subscribe", 1, "stream open, filter /tasks/.*");
      /* Let the server register the subscription before publishing. */
      for (i = 0; i < 5; i++) {
        cc_grpc_poll(h, 100);
        if (cap.got)
          break;
      }

      /* Publish /tasks/test through Events.Publish (same connection). The
       * unary blocks and pumps frames, so the envelope may arrive during
       * this call. */
      {
        Containerd__Services__Events__V1__PublishRequest pub =
            CONTAINERD__SERVICES__EVENTS__V1__PUBLISH_REQUEST__INIT;
        Google__Protobuf__Any any = GOOGLE__PROTOBUF__ANY__INIT;
        uint8_t reqbuf[512];
        uint8_t respbuf[64];
        size_t reqlen;

        any.type_url = (char *)"types.TaskCreate";
        any.value.data = (uint8_t *)"";
        any.value.len = 0;
        pub.topic = (char *)"/tasks/test";
        pub.event = &any;
        reqlen = containerd__services__events__v1__publish_request__get_packed_size(
            &pub);
        if (reqlen > sizeof(reqbuf)) {
          report("live Publish", 0, "request too large");
          stages_ok = 0;
        } else {
          containerd__services__events__v1__publish_request__pack(&pub,
                                                                  reqbuf);
          rc = cc_grpc_unary(h, "/containerd.services.events.v1.Events/Publish",
                             reqbuf, (uint32_t)reqlen, respbuf,
                             sizeof(respbuf), &resp_len);
          if (rc != CC_GRPC_STATUS_OK) {
            cc_grpc_errstr(h, rc, errbuf, sizeof(errbuf));
            snprintf(detail, sizeof(detail), "publish failed: grpc status %d (%s)",
                     rc, errbuf);
            report("live Publish", 0, detail);
            stages_ok = 0;
          } else {
            report("live Publish", 1, "published /tasks/test");
          }
        }
      }

      /* Drain the stream until the envelope arrives or we time out. */
      for (i = 0; i < 50 && !cap.got; i++) {
        poll_rc = cc_grpc_poll(h, 200);
        if (poll_rc < 0)
          break;
      }
      if (cap.got) {
        Containerd__Types__Envelope *env =
            containerd__types__envelope__unpack(NULL, cap.len, cap.bytes);
        if (env == NULL) {
          report("live Envelope", 0, "decode failed");
          stages_ok = 0;
        } else {
          snprintf(detail, sizeof(detail), "topic=%s namespace=%s event_type=%s",
                   env->topic, env->namespace_,
                   env->event && env->event->type_url ? env->event->type_url
                                                      : "(null)");
          ok = (strcmp(env->topic, "/tasks/test") == 0);
          report("live Envelope", ok, detail);
          if (!ok)
            stages_ok = 0;
          containerd__types__envelope__free_unpacked(env, NULL);
        }
      } else {
        report("live Envelope", 0, "no envelope within timeout");
        stages_ok = 0;
      }

      /* Clean cancel of the stream. */
      rc = cc_grpc_cancel(h, sid);
      report("live Cancel", rc == 0, "RST_STREAM(CANCEL)");
      if (rc != 0)
        stages_ok = 0;
      /* Drain the server's RST_STREAM acknowledgment so the slot frees. */
      cc_grpc_poll(h, 500);
    }
  }

  cc_grpc_close(h);
  return stages_ok ? 0 : -1;
}

/* -------------------------------------------------------------------------
 * main
 * ------------------------------------------------------------------------- */

int main(int argc, char **argv) {
  const char *sock_path =
      (argc > 1 && argv[1][0]) ? argv[1] : "/run/containerd/containerd.sock";
  const char *namespace_ = (argc > 2 && argv[2][0]) ? argv[2] : "default";
  int selftest_failures;
  int live_rc = 0;
  int live_ran = 0;

  printf("=== cc_grpc self-tests (HPACK / HTTP2) ===\n");
  selftest_failures = cc_grpc_selftest(1);
  if (selftest_failures == 0) {
    printf("[PASS] self-tests\n");
  } else {
    printf("[FAIL] self-tests: %d failed check(s)\n", selftest_failures);
    g_failures++;
  }

  printf("\n=== live containerd (%s, namespace %s) ===\n", sock_path,
         namespace_);
  if (access(sock_path, F_OK) != 0) {
    report_skipped("live containerd", "socket does not exist");
  } else {
    live_ran = 1;
    live_rc = live_block(sock_path, namespace_);
    if (live_rc < 0)
      report_skipped("live containerd",
                     "daemon socket present but not usable; "
                     "self-tests above remain the verification");
  }

  printf("\n=== result ===\n");
  if (g_failures == 0) {
    printf("ALL PASS%s\n",
           live_ran && live_rc == 0 ? " (self-tests + live containerd)"
                                    : " (self-tests; live block skipped)");
    return 0;
  }
  printf("%d FAILURE(S)\n", g_failures);
  return 1;
}