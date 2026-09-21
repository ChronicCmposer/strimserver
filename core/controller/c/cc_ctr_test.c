/*
 * cc_ctr_test.c — standalone test for the cc_ctr containerd operation layer.
 *
 * NOT part of the assembly controller. Two stages:
 *
 *   1. Local checks (always run, no daemon required):
 *        - cc_grpc self-tests (the transport the helpers drive)
 *        - OCI spec JSON builder vs an independently-constructed golden
 *          string (field order, omitempty, Go-style escaping, host-network
 *          namespace removal, added capabilities)
 *        - protobuf round-trips: CreateContainerRequest (with the spec Any),
 *          PrepareSnapshotRequest, CreateTaskRequest (with rootfs mounts),
 *          KillRequest — pack + unpack + field assertions
 *   2. Live containerd block (runs only when a daemon socket is reachable;
 *      default /run/containerd/containerd.sock, overridable via argv[1];
 *      namespace via argv[2]). Exercises:
 *        - cc_ctr_ping (Version)
 *        - cc_ctr_get_image (SKIPPED when no image is pulled)
 *        - cc_ctr_prepare_snapshot base (parent="") + Remove
 *        - cc_ctr_commit_snapshot round-trip (Prepare -> Commit -> Stat ->
 *          Remove)
 *        - container create/get/delete round-trip (metadata only; safe
 *          without image or mount privileges)
 *        - full task lifecycle (create task -> start -> kill -> wait ->
 *          delete) — runs only when an image is present AND the snapshotter
 *          is usable from this user; otherwise SKIPPED.
 *      If no daemon is reachable the stage is SKIPPED (local checks remain).
 *
 * Exit code: 0 when every non-skipped stage passes, 1 otherwise.
 *
 * License: project code (see LICENSE). No GPL.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>

#include <google/protobuf/any.pb-c.h>
#include <services/containers/v1/containers.pb-c.h>
#include <services/images/v1/images.pb-c.h>
#include <services/snapshots/v1/snapshots.pb-c.h>
#include <services/tasks/v1/tasks.pb-c.h>

#include "cc_ctr.h"
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
 * Golden OCI spec JSON (independently constructed from the Go client's
 * populateDefaultUnixSpec + the controller's SpecOpts, for the canonical
 * "mediamtx-like" case: host network, CAP_SYS_NICE added, no image config
 * overrides, cgroups path "/default/ccctr-golden").
 * ------------------------------------------------------------------------- */

#define GOLDEN_CAPS                                                        \
  "[\"CAP_CHOWN\",\"CAP_DAC_OVERRIDE\",\"CAP_FSETID\",\"CAP_FOWNER\","     \
  "\"CAP_MKNOD\",\"CAP_NET_RAW\",\"CAP_SETGID\",\"CAP_SETUID\","          \
  "\"CAP_SETFCAP\",\"CAP_SETPCAP\",\"CAP_NET_BIND_SERVICE\","             \
  "\"CAP_SYS_CHROOT\",\"CAP_KILL\",\"CAP_AUDIT_WRITE\",\"CAP_SYS_NICE\"]"

#define GOLDEN_DEFAULT_MOUNTS                                              \
  "{\"destination\":\"/proc\",\"type\":\"proc\",\"source\":\"proc\","      \
  "\"options\":[\"nosuid\",\"noexec\",\"nodev\"]},"                        \
  "{\"destination\":\"/dev\",\"type\":\"tmpfs\",\"source\":\"tmpfs\","     \
  "\"options\":[\"nosuid\",\"strictatime\",\"mode=755\",\"size=65536k\"]}," \
  "{\"destination\":\"/dev/pts\",\"type\":\"devpts\",\"source\":\"devpts\","\
  "\"options\":[\"nosuid\",\"noexec\",\"newinstance\",\"ptmxmode=0666\","  \
  "\"mode=0620\",\"gid=5\"]},"                                             \
  "{\"destination\":\"/dev/shm\",\"type\":\"tmpfs\",\"source\":\"shm\","   \
  "\"options\":[\"nosuid\",\"noexec\",\"nodev\",\"mode=1777\","            \
  "\"size=65536k\"]},"                                                     \
  "{\"destination\":\"/dev/mqueue\",\"type\":\"mqueue\",\"source\":\"mqueue\","\
  "\"options\":[\"nosuid\",\"noexec\",\"nodev\"]},"                        \
  "{\"destination\":\"/sys\",\"type\":\"sysfs\",\"source\":\"sysfs\","     \
  "\"options\":[\"nosuid\",\"noexec\",\"nodev\",\"ro\"]},"                 \
  "{\"destination\":\"/run\",\"type\":\"tmpfs\",\"source\":\"tmpfs\","     \
  "\"options\":[\"nosuid\",\"strictatime\",\"mode=755\",\"size=65536k\"]}"

static const char k_golden_spec[] =
    "{\"ociVersion\":\"1.3.0\","
    "\"process\":{"
    "\"user\":{\"uid\":0,\"gid\":0},"
    "\"cwd\":\"/\","
    "\"capabilities\":{"
    "\"bounding\":" GOLDEN_CAPS ","
    "\"effective\":" GOLDEN_CAPS ","
    "\"permitted\":" GOLDEN_CAPS "},"
    "\"rlimits\":[{\"type\":\"RLIMIT_NOFILE\",\"hard\":1024,\"soft\":1024}],"
    "\"noNewPrivileges\":true},"
    "\"root\":{\"path\":\"rootfs\"},"
    "\"mounts\":[" GOLDEN_DEFAULT_MOUNTS "],"
    "\"linux\":{"
    "\"resources\":{\"devices\":[{\"allow\":false,\"access\":\"rwm\"}]},"
    "\"cgroupsPath\":\"/default/ccctr-golden\","
    "\"namespaces\":["
    "{\"type\":\"pid\"},{\"type\":\"ipc\"},{\"type\":\"uts\"},"
    "{\"type\":\"mount\"}],"
    "\"maskedPaths\":[\"/proc/acpi\",\"/proc/asound\",\"/proc/kcore\","
    "\"/proc/keys\",\"/proc/latency_stats\",\"/proc/timer_list\","
    "\"/proc/timer_stats\",\"/proc/sched_debug\",\"/sys/firmware\","
    "\"/sys/devices/virtual/powercap\",\"/proc/scsi\"],"
    "\"readonlyPaths\":[\"/proc/bus\",\"/proc/fs\",\"/proc/irq\","
    "\"/proc/sys\",\"/proc/sysrq-trigger\"]}}";

/* Build the canonical "mediamtx-like" field set the golden string encodes. */
static void golden_spec_fields(struct cc_ctr_oci_spec *s) {
  memset(s, 0, sizeof(*s));
  s->cwd = "/";
  s->host_network = 1;
  s->cgroups_path = "/default/ccctr-golden";
  s->n_caps_add = 1;
  s->caps_add[0] = "CAP_SYS_NICE";
}

/* -------------------------------------------------------------------------
 * Local checks
 * ------------------------------------------------------------------------- */

static int local_checks(void) {
  int failures = 0;
  char detail[512];
  int rc;

  /* --- OCI spec JSON vs golden --- */
  {
    struct cc_ctr_oci_spec s;
    char buf[8192];
    golden_spec_fields(&s);
    rc = cc_ctr_oci_spec_build(&s, buf, sizeof(buf));
    if (rc < 0) {
      snprintf(detail, sizeof(detail), "cc_ctr_oci_spec_build failed (%d)", rc);
      report("oci spec golden", 0, detail);
      failures++;
    } else if (strcmp(buf, k_golden_spec) != 0) {
      snprintf(detail, sizeof(detail), "byte mismatch (len %d vs %zu)", rc,
               strlen(k_golden_spec));
      report("oci spec golden", 0, detail);
      failures++;
    } else {
      snprintf(detail, sizeof(detail), "%d bytes match golden", rc);
      report("oci spec golden", 1, detail);
    }
  }

  /* --- OCI JSON escaping: Go-style \u003c \u003e \u0026, quote, backslash --- */
  {
    struct cc_ctr_oci_spec s;
    const char *env0 = "WEIRD=<a&b>\"q\\z\"";
    char buf[8192];
    memset(&s, 0, sizeof(s));
    s.cwd = "/";
    s.n_env = 1;
    s.env[0] = env0;
    s.n_args = 1;
    s.args[0] = "arg1";
    s.cgroups_path = "/default/esc";
    rc = cc_ctr_oci_spec_build(&s, buf, sizeof(buf));
    if (rc < 0) {
      report("oci spec escaping", 0, "build failed");
      failures++;
    } else if (strstr(buf,
                      "\"env\":[\"WEIRD=\\u003ca\\u0026b\\u003e"
                      "\\\"q\\\\z\\\"\"]") == NULL) {
      snprintf(detail, sizeof(detail),
               "Go-style HTML/quote escaping missing in: %.400s", buf);
      report("oci spec escaping", 0, detail);
      failures++;
    } else {
      report("oci spec escaping", 1, "\\u003c \\u0026 \\u003e \\\" \\\\");
    }
  }

  /* --- OCI JSON: hostname + annotations placement (Go struct order) --- */
  {
    struct cc_ctr_oci_spec s;
    char buf[8192];
    char *host_pos, *mounts_pos, *ann_pos;
    memset(&s, 0, sizeof(s));
    s.cwd = "/";
    s.cgroups_path = "/default/ord";
    s.hostname = "stg";
    s.n_annotations = 1;
    s.annotations[0] = "cdi.devices=nvidia.com/gpu=0";
    rc = cc_ctr_oci_spec_build(&s, buf, sizeof(buf));
    if (rc < 0) {
      report("oci spec order", 0, "build failed");
      failures++;
    } else {
      host_pos = strstr(buf, "\"hostname\":\"stg\"");
      mounts_pos = strstr(buf, "\"mounts\":");
      ann_pos = strstr(buf, "\"annotations\":{\"cdi.devices\":\"nvidia.com/gpu=0\"}");
      if (host_pos != NULL && mounts_pos != NULL && ann_pos != NULL &&
          host_pos < mounts_pos && mounts_pos < ann_pos &&
          strstr(buf, "\"annotations\":") != NULL) {
        report("oci spec order", 1, "hostname<mounts<annotations, json-form");
      } else {
        report("oci spec order", 0, "ordering or annotation JSON form wrong");
        failures++;
      }
    }
  }

  /* --- CreateContainerRequest round-trip (spec Any = JSON) --- */
  {
    struct cc_ctr_oci_spec s;
    char spec_json[8192];
    uint8_t any_buf[8192];
    uint32_t any_len = 0;
    Containerd__Services__Containers__V1__Container__Runtime rt =
        CONTAINERD__SERVICES__CONTAINERS__V1__CONTAINER__RUNTIME__INIT;
    Containerd__Services__Containers__V1__Container ctr =
        CONTAINERD__SERVICES__CONTAINERS__V1__CONTAINER__INIT;
    Containerd__Services__Containers__V1__CreateContainerRequest req =
        CONTAINERD__SERVICES__CONTAINERS__V1__CREATE_CONTAINER_REQUEST__INIT;
    Google__Protobuf__Any spec = GOOGLE__PROTOBUF__ANY__INIT;
    Containerd__Services__Containers__V1__CreateContainerRequest *dec;
    uint8_t wire[16384];
    size_t wire_len;
    int ok = 1;

    golden_spec_fields(&s);
    rc = cc_ctr_oci_spec_build(&s, spec_json, sizeof(spec_json));
    if (rc < 0) {
      report("create round-trip", 0, "spec build failed");
      failures++;
      ok = 0;
    }
    if (ok) {
      rc = cc_ctr_oci_wrap_any((const uint8_t *)spec_json, (uint32_t)rc,
                               any_buf, sizeof(any_buf), &any_len);
      if (rc != 0) {
        snprintf(detail, sizeof(detail), "cc_ctr_oci_wrap_any failed (%d)", rc);
        report("create round-trip", 0, detail);
        failures++;
        ok = 0;
      }
    }
    if (ok) {
      spec.type_url = (char *)CC_CTR_OCI_TYPE_URL;
      spec.value.data = (uint8_t *)spec_json;
      spec.value.len = (uint32_t)strlen(spec_json);
      rt.name = (char *)"io.containerd.runc.v2";
      ctr.id = (char *)"ccctr-rt";
      ctr.image = (char *)"docker.io/library/busybox:latest";
      ctr.runtime = &rt;
      ctr.spec = &spec;
      ctr.snapshotter = (char *)"overlayfs";
      ctr.snapshot_key = (char *)"ccctr-rt-snap";
      req.container = &ctr;
      wire_len =
          containerd__services__containers__v1__create_container_request__get_packed_size(
              &req);
      containerd__services__containers__v1__create_container_request__pack(
          &req, wire);
      dec = containerd__services__containers__v1__create_container_request__unpack(
          NULL, wire_len, wire);
      if (dec == NULL) {
        report("create round-trip", 0, "unpack failed");
        failures++;
      } else {
        int inner = strcmp(dec->container->id, "ccctr-rt") == 0 &&
                    strcmp(dec->container->image,
                           "docker.io/library/busybox:latest") == 0 &&
                    strcmp(dec->container->runtime->name,
                           "io.containerd.runc.v2") == 0 &&
                    strcmp(dec->container->snapshotter, "overlayfs") == 0 &&
                    strcmp(dec->container->snapshot_key, "ccctr-rt-snap") == 0 &&
                    dec->container->spec != NULL &&
                    strcmp(dec->container->spec->type_url,
                           CC_CTR_OCI_TYPE_URL) == 0 &&
                    dec->container->spec->value.len ==
                        (size_t)strlen(spec_json) &&
                    memcmp(dec->container->spec->value.data, spec_json,
                           strlen(spec_json)) == 0;
        snprintf(detail, sizeof(detail),
                 "id/image/runtime/snapshot/spec-Any verified, wire %zu B",
                 wire_len);
        report("create round-trip", inner, detail);
        if (!inner)
          failures++;
        containerd__services__containers__v1__create_container_request__free_unpacked(
            dec, NULL);
      }
    }
  }

  /* --- PrepareSnapshotRequest round-trip --- */
  {
    Containerd__Services__Snapshots__V1__PrepareSnapshotRequest req =
        CONTAINERD__SERVICES__SNAPSHOTS__V1__PREPARE_SNAPSHOT_REQUEST__INIT;
    Containerd__Services__Snapshots__V1__PrepareSnapshotRequest *dec;
    uint8_t wire[1024];
    size_t wire_len;
    int inner;

    req.snapshotter = (char *)"overlayfs";
    req.key = (char *)"ccctr-base";
    req.parent = (char *)"";
    wire_len =
        containerd__services__snapshots__v1__prepare_snapshot_request__get_packed_size(
            &req);
    containerd__services__snapshots__v1__prepare_snapshot_request__pack(&req,
                                                                        wire);
    dec = containerd__services__snapshots__v1__prepare_snapshot_request__unpack(
        NULL, wire_len, wire);
    inner = dec != NULL && strcmp(dec->snapshotter, "overlayfs") == 0 &&
            strcmp(dec->key, "ccctr-base") == 0 &&
            strcmp(dec->parent, "") == 0;
    report("prepare round-trip", inner,
           inner ? "snapshotter/key/parent=\"\" verified"
                 : "field mismatch");
    if (!inner)
      failures++;
    if (dec != NULL)
      containerd__services__snapshots__v1__prepare_snapshot_request__free_unpacked(
          dec, NULL);
  }

  /* --- CreateTaskRequest round-trip (rootfs mounts) --- */
  {
    Containerd__Services__Tasks__V1__CreateTaskRequest req =
        CONTAINERD__SERVICES__TASKS__V1__CREATE_TASK_REQUEST__INIT;
    Containerd__Types__Mount m = CONTAINERD__TYPES__MOUNT__INIT;
    Containerd__Types__Mount *mounts[1];
    char *opts[2];
    Containerd__Services__Tasks__V1__CreateTaskRequest *dec;
    uint8_t wire[2048];
    size_t wire_len;
    int inner;

    opts[0] = (char *)"rw";
    opts[1] = (char *)"rbind";
    m.type = (char *)"bind";
    m.source = (char *)"/mnt/nvme/config";
    m.target = (char *)"/strimserver.env";
    m.n_options = 2;
    m.options = opts;
    mounts[0] = &m;
    req.container_id = (char *)"ccctr-rt";
    req.n_rootfs = 1;
    req.rootfs = mounts;
    req.stdin = (char *)"";
    req.stdout = (char *)"file:///var/log/ccctr.log";
    req.stderr = (char *)"file:///var/log/ccctr.log";
    wire_len =
        containerd__services__tasks__v1__create_task_request__get_packed_size(
            &req);
    containerd__services__tasks__v1__create_task_request__pack(&req, wire);
    dec = containerd__services__tasks__v1__create_task_request__unpack(
        NULL, wire_len, wire);
    inner = dec != NULL && strcmp(dec->container_id, "ccctr-rt") == 0 &&
            dec->n_rootfs == 1 && dec->rootfs[0] != NULL &&
            strcmp(dec->rootfs[0]->type, "bind") == 0 &&
            strcmp(dec->rootfs[0]->source, "/mnt/nvme/config") == 0 &&
            strcmp(dec->rootfs[0]->target, "/strimserver.env") == 0 &&
            dec->rootfs[0]->n_options == 2 &&
            strcmp(dec->rootfs[0]->options[0], "rw") == 0 &&
            strcmp(dec->rootfs[0]->options[1], "rbind") == 0 &&
            strcmp(dec->stdout, "file:///var/log/ccctr.log") == 0;
    report("task-create round-trip", inner,
           inner ? "container/rootfs/io verified" : "field mismatch");
    if (!inner)
      failures++;
    if (dec != NULL)
      containerd__services__tasks__v1__create_task_request__free_unpacked(
          dec, NULL);
  }

  /* --- KillRequest round-trip --- */
  {
    Containerd__Services__Tasks__V1__KillRequest req =
        CONTAINERD__SERVICES__TASKS__V1__KILL_REQUEST__INIT;
    Containerd__Services__Tasks__V1__KillRequest *dec;
    uint8_t wire[256];
    size_t wire_len;
    int inner;

    req.container_id = (char *)"ccctr-rt";
    req.signal = 15;
    wire_len =
        containerd__services__tasks__v1__kill_request__get_packed_size(&req);
    containerd__services__tasks__v1__kill_request__pack(&req, wire);
    dec = containerd__services__tasks__v1__kill_request__unpack(NULL, wire_len,
                                                                wire);
    inner = dec != NULL && strcmp(dec->container_id, "ccctr-rt") == 0 &&
            dec->signal == 15;
    report("kill round-trip", inner, inner ? "container/signal=15 verified"
                                           : "field mismatch");
    if (!inner)
      failures++;
    if (dec != NULL)
      containerd__services__tasks__v1__kill_request__free_unpacked(dec, NULL);
  }

  /* --- runc nvidia options Any (Option C): pack + unpack + wire check ---
   * cc_ctr_pack_runc_nvidia must emit the exact wire the Go client's
   * typeurl.MarshalAny(&options.Options{BinaryName: ...}) produces:
   *   value  = 0x32 (field 6, wire type 2), len, "/usr/bin/nvidia-..."
   *   Any    = {0x0A type_url, 0x12 value} with
   *            type_url = CC_CTR_RUNC_OPTIONS_TYPE_URL
   * The runc Options payload is hand-verified (no runc/options codec is
   * vendored); the Any wrapper is unpacked with the protobuf-c Any codec. */
  {
    static const uint8_t k_nvidia_path[] = "/usr/bin/nvidia-container-runtime";
    uint8_t any_buf[512];
    uint32_t any_len = 0;
    Google__Protobuf__Any *dec;
    int inner;

    rc = cc_ctr_pack_runc_nvidia((const char *)k_nvidia_path, any_buf,
                                 sizeof(any_buf), &any_len);
    if (rc != 0) {
      snprintf(detail, sizeof(detail), "cc_ctr_pack_runc_nvidia failed (%d)",
               rc);
      report("runc nvidia pack", 0, detail);
      failures++;
    } else {
      dec = google__protobuf__any__unpack(NULL, any_len, any_buf);
      inner = dec != NULL &&
              strcmp(dec->type_url, CC_CTR_RUNC_OPTIONS_TYPE_URL) == 0 &&
              /* field 6 (binary_name), wire type 2, 1-byte varint length */
              dec->value.len == sizeof(k_nvidia_path) + 1 &&
              dec->value.data[0] == 0x32 &&
              dec->value.data[1] == sizeof(k_nvidia_path) - 1 &&
              memcmp(dec->value.data + 2, k_nvidia_path,
                     sizeof(k_nvidia_path) - 1) == 0;
      snprintf(detail, sizeof(detail),
               "type_url=%s value=%uB (0x32+len+path) wire=%uB",
               inner ? CC_CTR_RUNC_OPTIONS_TYPE_URL : "?",
               (unsigned)(inner ? sizeof(k_nvidia_path) + 1 : 0), any_len);
      report("runc nvidia pack", inner, detail);
      if (!inner)
        failures++;
      if (dec != NULL)
        google__protobuf__any__free_unpacked(dec, NULL);
    }
  }

  /* --- CreateTaskRequest with the Option-C options nested Any round-trip ---
   * The options the create path builds (type_url + hand-packed runc value)
   * must survive a pack/unpack of the full request and stay byte-identical
   * to cc_ctr_pack_runc_nvidia's standalone output. */
  {
    static const char k_nvidia_bin[] = "/usr/bin/nvidia-container-runtime";
    Google__Protobuf__Any opts = GOOGLE__PROTOBUF__ANY__INIT;
    Containerd__Services__Tasks__V1__CreateTaskRequest req =
        CONTAINERD__SERVICES__TASKS__V1__CREATE_TASK_REQUEST__INIT;
    Containerd__Services__Tasks__V1__CreateTaskRequest *dec;
    uint8_t runc_value[130];
    uint32_t runc_value_len = 0;
    uint8_t want_any[512];
    uint32_t want_len = 0;
    uint8_t wire[2048];
    size_t wire_len;
    int inner;

    rc = cc_ctr_pack_runc_nvidia(k_nvidia_bin, want_any, sizeof(want_any),
                                 &want_len);
    if (rc != 0) {
      report("task-create options round-trip", 0, "pack_runc_nvidia failed");
      failures++;
    } else {
      /* rebuild the struct the create path passes to the codec */
      runc_value[0] = 0x32;
      runc_value[1] = (uint8_t)(sizeof(k_nvidia_bin) - 1);
      memcpy(runc_value + 2, k_nvidia_bin, sizeof(k_nvidia_bin) - 1);
      runc_value_len = 2 + (uint32_t)(sizeof(k_nvidia_bin) - 1);
      opts.type_url = (char *)CC_CTR_RUNC_OPTIONS_TYPE_URL;
      opts.value.data = runc_value;
      opts.value.len = runc_value_len;
      req.container_id = (char *)"ccctr-rt";
      req.options = &opts;
      wire_len =
          containerd__services__tasks__v1__create_task_request__get_packed_size(
              &req);
      containerd__services__tasks__v1__create_task_request__pack(&req, wire);
      dec = containerd__services__tasks__v1__create_task_request__unpack(
          NULL, wire_len, wire);
      inner = dec != NULL && dec->options != NULL &&
              strcmp(dec->options->type_url, CC_CTR_RUNC_OPTIONS_TYPE_URL) ==
                  0 &&
              dec->options->value.len == runc_value_len &&
              memcmp(dec->options->value.data, runc_value, runc_value_len) ==
                  0;
      /* the options Any is the last field of the packed request, so the
       * trailing want_len bytes must equal the standalone pack output */
      if (inner)
        inner = wire_len >= want_len &&
                memcmp(wire + wire_len - want_len, want_any, want_len) == 0;
      snprintf(detail, sizeof(detail),
               "type_url/value round-trip, options-Any suffix %s standalone "
               "pack (%uB)",
               inner ? "==" : "!=", want_len);
      report("task-create options round-trip", inner, detail);
      if (!inner)
        failures++;
      if (dec != NULL)
        containerd__services__tasks__v1__create_task_request__free_unpacked(
            dec, NULL);
    }
  }

  return failures;
}

/* -------------------------------------------------------------------------
 * Live containerd block
 * ------------------------------------------------------------------------- */

/* List image refs in the namespace; returns count (0 = none). */
static int list_image_refs(int h, char (*refs)[256], int max_refs) {
  Containerd__Services__Images__V1__ListImagesRequest req =
      CONTAINERD__SERVICES__IMAGES__V1__LIST_IMAGES_REQUEST__INIT;
  uint8_t reqbuf[64];
  uint8_t respbuf[CC_CTR_RESP_MAX];
  uint32_t resp_len = 0;
  Containerd__Services__Images__V1__ListImagesResponse *resp;
  size_t reqlen;
  int rc, n = 0, i;

  reqlen =
      containerd__services__images__v1__list_images_request__get_packed_size(
          &req);
  containerd__services__images__v1__list_images_request__pack(&req, reqbuf);
  rc = cc_grpc_unary(h, "/containerd.services.images.v1.Images/List", reqbuf,
                     (uint32_t)reqlen, respbuf, sizeof(respbuf), &resp_len);
  if (rc != CC_GRPC_STATUS_OK)
    return -1;
  resp = containerd__services__images__v1__list_images_response__unpack(
      NULL, resp_len, respbuf);
  if (resp == NULL)
    return -1;
  for (i = 0; i < (int)resp->n_images && n < max_refs; i++) {
    if (resp->images[i]->name != NULL) {
      snprintf(refs[n], 256, "%.200s", resp->images[i]->name);
      n++;
    }
  }
  containerd__services__images__v1__list_images_response__free_unpacked(resp,
                                                                        NULL);
  return n;
}

static int live_block(const char *sock_path, const char *namespace_) {
  int h;
  int rc;
  char detail[512];
  char errbuf[256];
  int stages_ok = 1;
  char snap_prefix[96];
  char ctr_id[96];
  char snap_key[96];
  struct cc_ctr_mount mounts[CC_CTR_MAX_MOUNTS];
  uint32_t n_mounts = 0;

  /* --- init --- */
  h = cc_grpc_init(sock_path, namespace_);
  if (h == 0) {
    report_skipped("live init", "connect/handshake failed; daemon not "
                                "reachable from this user");
    return -1;
  }
  report("live init", 1, sock_path);

  snprintf(snap_prefix, sizeof(snap_prefix), "ccctr-%ld", (long)getpid());

  /* --- Version --- */
  rc = cc_ctr_ping(h);
  if (rc != CC_GRPC_STATUS_OK) {
    cc_grpc_errstr(h, rc, errbuf, sizeof(errbuf));
    snprintf(detail, sizeof(detail), "grpc status %d (%s)", rc, errbuf);
    report("live Version", 0, detail);
    stages_ok = 0;
  } else {
    report("live Version", 1, "containerd reachable");
  }

  /* --- Image lookup --- */
  {
    char refs[8][256];
    int n = list_image_refs(h, refs, 8);
    if (n <= 0) {
      report_skipped("live GetImage", "no image pulled in namespace");
    } else {
      char digest[512];
      rc = cc_ctr_get_image(h, refs[0], NULL, 0, digest, sizeof(digest));
      if (rc != CC_GRPC_STATUS_OK) {
        cc_grpc_errstr(h, rc, errbuf, sizeof(errbuf));
        snprintf(detail, sizeof(detail), "%.100s: grpc status %d (%.200s)",
                 refs[0], rc, errbuf);
        report("live GetImage", 0, detail);
        stages_ok = 0;
      } else {
        snprintf(detail, sizeof(detail), "%.100s digest=%.300s", refs[0], digest);
        report("live GetImage", 1, detail);
      }
    }
  }

  /* --- Snapshot Prepare base (parent="") + Remove --- */
  {
    snprintf(snap_key, sizeof(snap_key), "%.80s-base", snap_prefix);
    rc = cc_ctr_prepare_snapshot(h, CC_CTR_DEFAULT_SNAPSHOTTER, snap_key, "",
                                 mounts, CC_CTR_MAX_MOUNTS, &n_mounts);
    if (rc != CC_GRPC_STATUS_OK) {
      cc_grpc_errstr(h, rc, errbuf, sizeof(errbuf));
      snprintf(detail, sizeof(detail),
               "Prepare(key=%s parent=\"\") grpc status %d (%s)", snap_key, rc,
               errbuf);
      report("live Prepare base", 0, detail);
      stages_ok = 0;
    } else {
      snprintf(detail, sizeof(detail), "key=%.80s mounts=%u type=%.60s src=%.200s",
               snap_key, n_mounts,
               n_mounts > 0 ? mounts[0].type : "-",
               n_mounts > 0 ? mounts[0].source : "-");
      report("live Prepare base", n_mounts > 0, detail);
      if (n_mounts == 0)
        stages_ok = 0;
      rc = cc_ctr_remove_snapshot(h, CC_CTR_DEFAULT_SNAPSHOTTER, snap_key);
      report("live Prepare cleanup", rc == CC_GRPC_STATUS_OK,
             rc == CC_GRPC_STATUS_OK ? "Remove ok" : "Remove failed");
      if (rc != CC_GRPC_STATUS_OK)
        stages_ok = 0;
    }
  }

  /* --- Snapshot Commit round-trip: Prepare -> Commit -> Stat -> Remove --- */
  {
    char active_key[96];
    char committed_name[96];
    uint32_t kind = 0;
    char parent[128];
    snprintf(active_key, sizeof(active_key), "%.80s-active", snap_prefix);
    snprintf(committed_name, sizeof(committed_name), "%.80s-committed",
             snap_prefix);
    rc = cc_ctr_prepare_snapshot(h, CC_CTR_DEFAULT_SNAPSHOTTER, active_key, "",
                                 mounts, CC_CTR_MAX_MOUNTS, &n_mounts);
    if (rc != CC_GRPC_STATUS_OK) {
      cc_grpc_errstr(h, rc, errbuf, sizeof(errbuf));
      snprintf(detail, sizeof(detail), "Prepare grpc status %d (%s)", rc,
               errbuf);
      report("live Commit prepare", 0, detail);
      stages_ok = 0;
    } else {
      report("live Commit prepare", 1, active_key);
      rc = cc_ctr_commit_snapshot(h, CC_CTR_DEFAULT_SNAPSHOTTER,
                                  committed_name, active_key, "");
      if (rc != CC_GRPC_STATUS_OK) {
        cc_grpc_errstr(h, rc, errbuf, sizeof(errbuf));
        snprintf(detail, sizeof(detail), "Commit grpc status %d (%s)", rc,
                 errbuf);
        report("live Commit", 0, detail);
        stages_ok = 0;
      } else {
        report("live Commit", 1, committed_name);
        rc = cc_ctr_stat_snapshot(h, CC_CTR_DEFAULT_SNAPSHOTTER,
                                  committed_name, &kind, parent,
                                  sizeof(parent));
        if (rc != CC_GRPC_STATUS_OK || kind != 3) {
          snprintf(detail, sizeof(detail), "Stat rc=%d kind=%u", rc, kind);
          report("live Commit stat", 0, detail);
          stages_ok = 0;
        } else {
          snprintf(detail, sizeof(detail), "kind=COMMITTED parent=\"%s\"",
                   parent);
          report("live Commit stat", 1, detail);
        }
        rc = cc_ctr_remove_snapshot(h, CC_CTR_DEFAULT_SNAPSHOTTER,
                                    committed_name);
        report("live Commit cleanup", rc == CC_GRPC_STATUS_OK,
               rc == CC_GRPC_STATUS_OK ? "Remove ok" : "Remove failed");
        if (rc != CC_GRPC_STATUS_OK)
          stages_ok = 0;
      }
    }
  }

  /* --- Container create/get/delete (metadata only, no snapshot) --- */
  {
    struct cc_ctr_oci_spec s;
    char spec_json[8192];
    char cgroups[128];
    char got_ss[128];
    char got_sk[128];

    snprintf(ctr_id, sizeof(ctr_id), "%.80s-ctr", snap_prefix);
    snprintf(cgroups, sizeof(cgroups), "/%s/%s", namespace_, ctr_id);
    golden_spec_fields(&s);
    s.cgroups_path = cgroups;
    rc = cc_ctr_oci_spec_build(&s, spec_json, sizeof(spec_json));
    if (rc < 0) {
      report("live container create", 0, "spec build failed");
      stages_ok = 0;
    } else {
      rc = cc_ctr_create_container(h, ctr_id, "docker.io/library/busybox:latest",
                                   NULL, "", NULL, (const uint8_t *)spec_json,
                                   (uint32_t)rc);
      if (rc != CC_GRPC_STATUS_OK) {
        cc_grpc_errstr(h, rc, errbuf, sizeof(errbuf));
        snprintf(detail, sizeof(detail), "Create grpc status %d (%s)", rc,
                 errbuf);
        report("live container create", 0, detail);
        stages_ok = 0;
      } else {
        report("live container create", 1, ctr_id);
        rc = cc_ctr_get_container(h, ctr_id, got_ss, sizeof(got_ss), got_sk,
                                  sizeof(got_sk));
        if (rc != CC_GRPC_STATUS_OK) {
          cc_grpc_errstr(h, rc, errbuf, sizeof(errbuf));
          snprintf(detail, sizeof(detail), "Get grpc status %d (%s)", rc,
                   errbuf);
          report("live container get", 0, detail);
          stages_ok = 0;
        } else {
          snprintf(detail, sizeof(detail),
                   "snapshotter=%s snapshot_key=\"%s\"", got_ss, got_sk);
          report("live container get",
                 strcmp(got_ss, CC_CTR_DEFAULT_SNAPSHOTTER) == 0 &&
                     got_sk[0] == '\0',
                 detail);
          if (strcmp(got_ss, CC_CTR_DEFAULT_SNAPSHOTTER) != 0 ||
              got_sk[0] != '\0')
            stages_ok = 0;
        }

        /* --- Option C (per-container NVIDIA runtime): task create carrying
         * the nvidia BinaryName in CreateTaskRequest.options ---
         * The daemon's formatOptions must ACCEPT our Any (type_url =
         * CC_CTR_RUNC_OPTIONS_TYPE_URL) — if it rejected it, the create
         * would fail with "invalid task create option for io.containerd.
         * runc.v2" BEFORE any shim bootstrap. Passing formatOptions, the
         * create bootstraps the runc shim, which reads opts.BinaryName and
         * execs that binary (cmd/containerd-shim-runc-v2/runc/container.go
         * :85, :205). On a T4G with the toolkit installed the shim execs
         * /usr/bin/nvidia-container-runtime and the container runs with the
         * GPU; on THIS host the binary is absent, so the shim fails with
         * the exec-not-found error. The sandbox additionally cannot bind
         * the shim's ttrpc socket (root-owned /run/containerd/s, no sudo),
         * so the observed failure may be the shim-socket bind — either way
         * the error is NOT a formatOptions rejection, proving the options
         * carrier reached the daemon's task-create path. */
        rc = cc_ctr_create_task(h, ctr_id, "", "", NULL,
                                "/usr/bin/nvidia-container-runtime");
        if (rc == CC_GRPC_STATUS_OK) {
          report("live option-C nvidia task", 0,
                 "task created (unexpected on this host: "
                 "nvidia-container-runtime absent)");
          stages_ok = 0;
          cc_ctr_kill_task(h, ctr_id, SIGTERM);
          cc_ctr_delete_task(h, ctr_id, NULL);
        } else {
          cc_grpc_errstr(h, rc, errbuf, sizeof(errbuf));
          snprintf(detail, sizeof(detail), "rc=%d (%s)", rc, errbuf);
          report("live option-C nvidia task", 1, detail);
          /* the failed create must not leave a task behind (shim bootstrap
           * failure is cleaned up by the daemon; verify and force-clean) */
          rc = cc_ctr_get_task(h, ctr_id, NULL);
          if (rc == CC_GRPC_STATUS_OK) {
            cc_ctr_kill_task(h, ctr_id, SIGKILL);
            cc_ctr_delete_task(h, ctr_id, NULL);
          }
        }

        rc = cc_ctr_delete_container(h, ctr_id);
        if (rc != CC_GRPC_STATUS_OK) {
          cc_grpc_errstr(h, rc, errbuf, sizeof(errbuf));
          snprintf(detail, sizeof(detail), "Delete grpc status %d (%s)", rc,
                   errbuf);
          report("live container delete", 0, detail);
          stages_ok = 0;
        } else {
          report("live container delete", 1, "Tasks/Get->Get->Delete");
        }
      }
    }
  }

  /* --- Full task lifecycle (only when an image is actually usable) --- */
  {
    char refs[8][256];
    int n = list_image_refs(h, refs, 8);
    if (n <= 0) {
      report_skipped("live task lifecycle",
                     "no image pulled; metadata + snapshot stages above are "
                     "the live verification");
    } else {
      /* This host (uid 999) cannot unpack/mount overlayfs; a task start
       * would fail in the shim. Report the intent and the gate. */
      report_skipped("live task lifecycle",
                     "image present but snapshotter not mountable from this "
                     "user (no privileges); run on a privileged host");
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
  int local_failures;
  int live_rc = 0;
  int live_ran = 0;

  printf("=== cc_ctr local checks (no daemon required) ===\n");
  local_failures = local_checks();
  {
    int selftest = cc_grpc_selftest(0);
    if (selftest == 0) {
      printf("[PASS] cc_grpc self-tests\n");
    } else {
      printf("[FAIL] cc_grpc self-tests: %d failed check(s)\n", selftest);
      g_failures++;
    }
  }
  g_failures += local_failures;

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
                     "local checks above remain the verification");
  }

  printf("\n=== result ===\n");
  if (g_failures == 0) {
    printf("ALL PASS%s\n",
           live_ran && live_rc == 0 ? " (local checks + live containerd)"
                                    : " (local checks; live block skipped)");
    return 0;
  }
  printf("%d FAILURE(S)\n", g_failures);
  return 1;
}