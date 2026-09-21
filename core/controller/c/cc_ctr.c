/*
 * cc_ctr.c — containerd operation layer for the ARM controller rewrite.
 *
 * Phase 4.4a. Thin containerd operation helpers: build requests with the
 * vendored protobuf-c codecs, call cc_grpc_unary, parse responses. See
 * cc_ctr.h for the design contract (fixed-arity API, chainID design-around,
 * OCI spec Any mechanism) and cc_grpc.h for the transport layer.
 *
 * License: project code (see LICENSE). No GPL.
 */

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include <google/protobuf/any.pb-c.h>
#include <google/protobuf/empty.pb-c.h>
#include <services/containers/v1/containers.pb-c.h>
#include <services/images/v1/images.pb-c.h>
#include <services/snapshots/v1/snapshots.pb-c.h>
#include <services/tasks/v1/tasks.pb-c.h>

#include "cc_ctr.h"
#include "cc_grpc.h"

/* =========================================================================
 * Internal helpers
 * ========================================================================= */

/* Copy a NUL-terminated string into a fixed buffer; FAIL LOUDLY on
 * truncation (a silently cut snapshot key or digest would corrupt the
 * chainID threading). A NULL destination means the output is optional and
 * is skipped (all cc_ctr out-buffers are optional). Returns 0 or -1. */
static int copy_str(char *dst, uint32_t dst_cap, const char *src) {
  size_t len;

  if (src == NULL)
    src = "";
  if (dst == NULL)
    return 0; /* optional output */
  if (dst_cap == 0)
    return -1; /* output requested but no space */
  len = strlen(src);
  if (len + 1 > dst_cap)
    return -1;
  memcpy(dst, src, len + 1);
  return 0;
}

/* Copy a containerd.types.Mount into the fixed-arity cc_ctr_mount record. */
static int copy_mount(const Containerd__Types__Mount *m,
                      struct cc_ctr_mount *out) {
  uint32_t i;

  if (m == NULL || out == NULL)
    return -1;
  memset(out, 0, sizeof(*out));
  if (copy_str(out->type, sizeof(out->type), m->type) < 0)
    return -1;
  if (copy_str(out->source, sizeof(out->source), m->source) < 0)
    return -1;
  if (copy_str(out->target, sizeof(out->target), m->target) < 0)
    return -1;
  if (m->n_options > CC_CTR_MOUNT_OPT_MAX)
    return -1;
  out->n_options = (uint32_t)m->n_options;
  for (i = 0; i < out->n_options; i++) {
    if (m->options[i] == NULL)
      return -1;
    if (copy_str(out->options[i], CC_CTR_MOUNT_OPT_LEN_MAX, m->options[i]) < 0)
      return -1;
  }
  return 0;
}

/* Convert a codec mount array into caller-provided cc_ctr_mount records.
 * Returns 0 on success (out_n_mounts set), or CC_CTR_ERR_* on failure. */
static int mounts_to_c(Containerd__Types__Mount **mounts, size_t n_mounts,
                       struct cc_ctr_mount *out, uint32_t mounts_cap,
                       uint32_t *out_n_mounts) {
  size_t i;

  if (out_n_mounts == NULL)
    return CC_CTR_ERR_BADARG;
  *out_n_mounts = 0;
  if (mounts_cap != 0 && out == NULL)
    return CC_CTR_ERR_BADARG;
  if (n_mounts > mounts_cap)
    return CC_CTR_ERR_TOOBIG;
  for (i = 0; i < n_mounts; i++) {
    if (copy_mount(mounts[i], &out[i]) < 0)
      return CC_CTR_ERR_TOOBIG;
  }
  *out_n_mounts = (uint32_t)n_mounts;
  return 0;
}

/* Containers/Get returning the snapshotter + snapshot_key of the record.
 * The internal form both cc_ctr_get_container and the task/delete helpers
 * use. Returns 0 (buffers set) or the RPC result. */
static int get_container_info(int h, const char *id,
                              char *out_snapshotter, uint32_t ss_cap,
                              char *out_snapshot_key, uint32_t sk_cap) {
  Containerd__Services__Containers__V1__GetContainerRequest req =
      CONTAINERD__SERVICES__CONTAINERS__V1__GET_CONTAINER_REQUEST__INIT;
  uint8_t reqbuf[256];
  uint8_t respbuf[CC_CTR_RESP_MAX];
  uint32_t resp_len = 0;
  Containerd__Services__Containers__V1__GetContainerResponse *resp;
  size_t reqlen;
  int rc;

  req.id = (char *)id;
  reqlen =
      containerd__services__containers__v1__get_container_request__get_packed_size(
          &req);
  containerd__services__containers__v1__get_container_request__pack(&req,
                                                                    reqbuf);
  rc = cc_grpc_unary(h, "/containerd.services.containers.v1.Containers/Get",
                     reqbuf, (uint32_t)reqlen, respbuf, sizeof(respbuf),
                     &resp_len);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  resp = containerd__services__containers__v1__get_container_response__unpack(
      NULL, resp_len, respbuf);
  if (resp == NULL || resp->container == NULL)
    return CC_CTR_ERR_STATE;
  rc = 0;
  if (copy_str(out_snapshotter, ss_cap, resp->container->snapshotter) < 0)
    rc = CC_CTR_ERR_TOOBIG;
  if (copy_str(out_snapshot_key, sk_cap, resp->container->snapshot_key) < 0)
    rc = CC_CTR_ERR_TOOBIG;
  containerd__services__containers__v1__get_container_response__free_unpacked(
      resp, NULL);
  return rc;
}

/* Hand-pack runc/options.Options{BinaryName: bin} into out: a single field
 * 6 (binary_name), wire type 2 — tag byte (6<<3)|2 = 0x32, a varint length,
 * then the string bytes. There is NO generated runc/options codec in
 * //third_party/containerd-api:codecs, so the payload is packed by hand;
 * the wire must match what the Go client's protobuf encoder emits for the
 * same message (verified byte-for-byte). The fixed binary path is 47 bytes,
 * so a 1-byte varint length always suffices; lengths beyond 127 are rejected
 * loudly (this field set never needs them). Returns 0 with out_len set, or a
 * negative CC_CTR_ERR_*. */
static int ctr_pack_runc_value(const char *bin, uint8_t *out, uint32_t cap,
                               uint32_t *out_len) {
  size_t len;

  if (bin == NULL || bin[0] == '\0' || out == NULL || out_len == NULL)
    return CC_CTR_ERR_BADARG;
  len = strlen(bin);
  if (len > 127)
    return CC_CTR_ERR_TOOBIG; /* 1-byte varint length only */
  if (cap < 2 + (uint32_t)len)
    return CC_CTR_ERR_TOOBIG;
  out[0] = 0x32; /* field 6 (binary_name), wire type 2 */
  out[1] = (uint8_t)len;
  memcpy(out + 2, bin, len);
  *out_len = 2 + (uint32_t)len;
  return CC_GRPC_STATUS_OK;
}

/* =========================================================================
 * Version
 * ========================================================================= */

int cc_ctr_ping(int h) {
  Google__Protobuf__Empty req = GOOGLE__PROTOBUF__EMPTY__INIT;
  uint8_t reqbuf[16];
  uint8_t respbuf[1024];
  uint32_t resp_len = 0;
  size_t reqlen;

  if (h <= 0)
    return CC_CTR_ERR_BADARG;
  reqlen = google__protobuf__empty__get_packed_size(&req);
  google__protobuf__empty__pack(&req, reqbuf);
  return cc_grpc_unary(h, "/containerd.services.version.v1.Version/Version",
                       reqbuf, (uint32_t)reqlen, respbuf, sizeof(respbuf),
                       &resp_len);
}

/* =========================================================================
 * Images
 * ========================================================================= */

int cc_ctr_get_image(int h, const char *image_ref,
                     char *out_name, uint32_t name_cap,
                     char *out_digest, uint32_t digest_cap) {
  Containerd__Services__Images__V1__GetImageRequest req =
      CONTAINERD__SERVICES__IMAGES__V1__GET_IMAGE_REQUEST__INIT;
  uint8_t reqbuf[1024];
  uint8_t respbuf[CC_CTR_RESP_MAX];
  uint32_t resp_len = 0;
  Containerd__Services__Images__V1__GetImageResponse *resp;
  size_t reqlen;
  int rc;

  if (h <= 0 || image_ref == NULL || image_ref[0] == '\0')
    return CC_CTR_ERR_BADARG;
  req.name = (char *)image_ref;
  reqlen =
      containerd__services__images__v1__get_image_request__get_packed_size(
          &req);
  containerd__services__images__v1__get_image_request__pack(&req, reqbuf);
  rc = cc_grpc_unary(h, "/containerd.services.images.v1.Images/Get", reqbuf,
                     (uint32_t)reqlen, respbuf, sizeof(respbuf), &resp_len);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  resp = containerd__services__images__v1__get_image_response__unpack(
      NULL, resp_len, respbuf);
  if (resp == NULL || resp->image == NULL)
    return CC_CTR_ERR_STATE;
  rc = 0;
  if (copy_str(out_name, name_cap, resp->image->name) < 0)
    rc = CC_CTR_ERR_TOOBIG;
  if (resp->image->target != NULL &&
      copy_str(out_digest, digest_cap, resp->image->target->digest) < 0)
    rc = CC_CTR_ERR_TOOBIG;
  containerd__services__images__v1__get_image_response__free_unpacked(resp,
                                                                      NULL);
  return rc;
}

/* =========================================================================
 * Snapshots (chainID design-around)
 * ========================================================================= */

int cc_ctr_prepare_snapshot(int h, const char *snapshotter, const char *key,
                            const char *parent,
                            struct cc_ctr_mount *out_mounts,
                            uint32_t mounts_cap, uint32_t *out_n_mounts) {
  Containerd__Services__Snapshots__V1__PrepareSnapshotRequest req =
      CONTAINERD__SERVICES__SNAPSHOTS__V1__PREPARE_SNAPSHOT_REQUEST__INIT;
  uint8_t reqbuf[2048];
  uint8_t respbuf[CC_CTR_RESP_MAX];
  uint32_t resp_len = 0;
  Containerd__Services__Snapshots__V1__PrepareSnapshotResponse *resp;
  size_t reqlen;
  int rc;

  if (h <= 0 || snapshotter == NULL || snapshotter[0] == '\0' ||
      key == NULL || key[0] == '\0')
    return CC_CTR_ERR_BADARG;
  req.snapshotter = (char *)snapshotter;
  req.key = (char *)key;
  req.parent = (char *)(parent != NULL ? parent : "");
  reqlen = containerd__services__snapshots__v1__prepare_snapshot_request__get_packed_size(
      &req);
  containerd__services__snapshots__v1__prepare_snapshot_request__pack(&req,
                                                                      reqbuf);
  rc = cc_grpc_unary(h, "/containerd.services.snapshots.v1.Snapshots/Prepare",
                     reqbuf, (uint32_t)reqlen, respbuf, sizeof(respbuf),
                     &resp_len);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  resp = containerd__services__snapshots__v1__prepare_snapshot_response__unpack(
      NULL, resp_len, respbuf);
  if (resp == NULL)
    return CC_CTR_ERR_STATE;
  rc = mounts_to_c(resp->mounts, resp->n_mounts, out_mounts, mounts_cap,
                   out_n_mounts);
  containerd__services__snapshots__v1__prepare_snapshot_response__free_unpacked(
      resp, NULL);
  return rc;
}

int cc_ctr_commit_snapshot(int h, const char *snapshotter, const char *name,
                           const char *key, const char *parent) {
  Containerd__Services__Snapshots__V1__CommitSnapshotRequest req =
      CONTAINERD__SERVICES__SNAPSHOTS__V1__COMMIT_SNAPSHOT_REQUEST__INIT;
  uint8_t reqbuf[2048];
  uint8_t respbuf[1024];
  uint32_t resp_len = 0;
  size_t reqlen;

  if (h <= 0 || snapshotter == NULL || snapshotter[0] == '\0' ||
      name == NULL || name[0] == '\0' || key == NULL || key[0] == '\0')
    return CC_CTR_ERR_BADARG;
  req.snapshotter = (char *)snapshotter;
  req.name = (char *)name;
  req.key = (char *)key;
  req.parent = (char *)(parent != NULL ? parent : "");
  reqlen =
      containerd__services__snapshots__v1__commit_snapshot_request__get_packed_size(
          &req);
  containerd__services__snapshots__v1__commit_snapshot_request__pack(&req,
                                                                     reqbuf);
  return cc_grpc_unary(h, "/containerd.services.snapshots.v1.Snapshots/Commit",
                       reqbuf, (uint32_t)reqlen, respbuf, sizeof(respbuf),
                       &resp_len);
}

int cc_ctr_mounts(int h, const char *snapshotter, const char *key,
                  struct cc_ctr_mount *out_mounts, uint32_t mounts_cap,
                  uint32_t *out_n_mounts) {
  Containerd__Services__Snapshots__V1__MountsRequest req =
      CONTAINERD__SERVICES__SNAPSHOTS__V1__MOUNTS_REQUEST__INIT;
  uint8_t reqbuf[1024];
  uint8_t respbuf[CC_CTR_RESP_MAX];
  uint32_t resp_len = 0;
  Containerd__Services__Snapshots__V1__MountsResponse *resp;
  size_t reqlen;
  int rc;

  if (h <= 0 || snapshotter == NULL || snapshotter[0] == '\0' ||
      key == NULL || key[0] == '\0')
    return CC_CTR_ERR_BADARG;
  req.snapshotter = (char *)snapshotter;
  req.key = (char *)key;
  reqlen = containerd__services__snapshots__v1__mounts_request__get_packed_size(
      &req);
  containerd__services__snapshots__v1__mounts_request__pack(&req, reqbuf);
  rc = cc_grpc_unary(h, "/containerd.services.snapshots.v1.Snapshots/Mounts",
                     reqbuf, (uint32_t)reqlen, respbuf, sizeof(respbuf),
                     &resp_len);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  resp = containerd__services__snapshots__v1__mounts_response__unpack(
      NULL, resp_len, respbuf);
  if (resp == NULL)
    return CC_CTR_ERR_STATE;
  rc = mounts_to_c(resp->mounts, resp->n_mounts, out_mounts, mounts_cap,
                   out_n_mounts);
  containerd__services__snapshots__v1__mounts_response__free_unpacked(resp,
                                                                      NULL);
  return rc;
}

int cc_ctr_remove_snapshot(int h, const char *snapshotter, const char *key) {
  Containerd__Services__Snapshots__V1__RemoveSnapshotRequest req =
      CONTAINERD__SERVICES__SNAPSHOTS__V1__REMOVE_SNAPSHOT_REQUEST__INIT;
  uint8_t reqbuf[1024];
  uint8_t respbuf[1024];
  uint32_t resp_len = 0;
  size_t reqlen;

  if (h <= 0 || snapshotter == NULL || snapshotter[0] == '\0' ||
      key == NULL || key[0] == '\0')
    return CC_CTR_ERR_BADARG;
  req.snapshotter = (char *)snapshotter;
  req.key = (char *)key;
  reqlen = containerd__services__snapshots__v1__remove_snapshot_request__get_packed_size(
      &req);
  containerd__services__snapshots__v1__remove_snapshot_request__pack(&req,
                                                                     reqbuf);
  return cc_grpc_unary(h, "/containerd.services.snapshots.v1.Snapshots/Remove",
                       reqbuf, (uint32_t)reqlen, respbuf, sizeof(respbuf),
                       &resp_len);
}

int cc_ctr_stat_snapshot(int h, const char *snapshotter, const char *key,
                         uint32_t *out_kind, char *out_parent,
                         uint32_t parent_cap) {
  Containerd__Services__Snapshots__V1__StatSnapshotRequest req =
      CONTAINERD__SERVICES__SNAPSHOTS__V1__STAT_SNAPSHOT_REQUEST__INIT;
  uint8_t reqbuf[1024];
  uint8_t respbuf[CC_CTR_RESP_MAX];
  uint32_t resp_len = 0;
  Containerd__Services__Snapshots__V1__StatSnapshotResponse *resp;
  size_t reqlen;
  int rc;

  if (h <= 0 || snapshotter == NULL || snapshotter[0] == '\0' ||
      key == NULL || key[0] == '\0')
    return CC_CTR_ERR_BADARG;
  if (out_kind != NULL)
    *out_kind = 0;
  req.snapshotter = (char *)snapshotter;
  req.key = (char *)key;
  reqlen = containerd__services__snapshots__v1__stat_snapshot_request__get_packed_size(
      &req);
  containerd__services__snapshots__v1__stat_snapshot_request__pack(&req,
                                                                   reqbuf);
  rc = cc_grpc_unary(h, "/containerd.services.snapshots.v1.Snapshots/Stat",
                     reqbuf, (uint32_t)reqlen, respbuf, sizeof(respbuf),
                     &resp_len);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  resp = containerd__services__snapshots__v1__stat_snapshot_response__unpack(
      NULL, resp_len, respbuf);
  if (resp == NULL || resp->info == NULL)
    return CC_CTR_ERR_STATE;
  rc = 0;
  if (out_kind != NULL)
    *out_kind = (uint32_t)resp->info->kind;
  if (copy_str(out_parent, parent_cap, resp->info->parent) < 0)
    rc = CC_CTR_ERR_TOOBIG;
  containerd__services__snapshots__v1__stat_snapshot_response__free_unpacked(
      resp, NULL);
  return rc;
}

/* =========================================================================
 * Containers
 * ========================================================================= */

int cc_ctr_create_container(int h, const char *id, const char *image_ref,
                            const char *snapshotter, const char *snapshot_key,
                            const char *runtime, const uint8_t *oci_spec_json,
                            uint32_t oci_len) {
  Containerd__Services__Containers__V1__Container__Runtime rt =
      CONTAINERD__SERVICES__CONTAINERS__V1__CONTAINER__RUNTIME__INIT;
  Containerd__Services__Containers__V1__Container ctr =
      CONTAINERD__SERVICES__CONTAINERS__V1__CONTAINER__INIT;
  Containerd__Services__Containers__V1__CreateContainerRequest req =
      CONTAINERD__SERVICES__CONTAINERS__V1__CREATE_CONTAINER_REQUEST__INIT;
  Google__Protobuf__Any spec = GOOGLE__PROTOBUF__ANY__INIT;
  uint8_t reqbuf[CC_CTR_REQ_MAX];
  uint8_t respbuf[CC_CTR_RESP_MAX];
  uint32_t resp_len = 0;
  size_t reqlen;

  if (h <= 0 || id == NULL || id[0] == '\0' || image_ref == NULL ||
      image_ref[0] == '\0' || oci_spec_json == NULL || oci_len == 0)
    return CC_CTR_ERR_BADARG;

  spec.type_url = (char *)CC_CTR_OCI_TYPE_URL;
  spec.value.data = (uint8_t *)oci_spec_json;
  spec.value.len = oci_len;

  rt.name = (char *)(runtime != NULL && runtime[0] != '\0'
                         ? runtime
                         : CC_CTR_DEFAULT_RUNTIME);

  ctr.id = (char *)id;
  ctr.image = (char *)image_ref;
  ctr.runtime = &rt;
  ctr.spec = &spec;
  ctr.snapshotter = (char *)(snapshotter != NULL && snapshotter[0] != '\0'
                                 ? snapshotter
                                 : CC_CTR_DEFAULT_SNAPSHOTTER);
  ctr.snapshot_key = (char *)(snapshot_key != NULL ? snapshot_key : "");

  req.container = &ctr;
  reqlen = containerd__services__containers__v1__create_container_request__get_packed_size(
      &req);
  if (reqlen > sizeof(reqbuf))
    return CC_CTR_ERR_TOOBIG;
  containerd__services__containers__v1__create_container_request__pack(&req,
                                                                       reqbuf);
  return cc_grpc_unary(h, "/containerd.services.containers.v1.Containers/Create",
                       reqbuf, (uint32_t)reqlen, respbuf, sizeof(respbuf),
                       &resp_len);
}

int cc_ctr_get_container(int h, const char *id,
                         char *out_snapshotter, uint32_t ss_cap,
                         char *out_snapshot_key, uint32_t sk_cap) {
  if (h <= 0 || id == NULL || id[0] == '\0')
    return CC_CTR_ERR_BADARG;
  return get_container_info(h, id, out_snapshotter, ss_cap, out_snapshot_key,
                            sk_cap);
}

int cc_ctr_delete_container(int h, const char *id) {
  Containerd__Services__Containers__V1__DeleteContainerRequest req =
      CONTAINERD__SERVICES__CONTAINERS__V1__DELETE_CONTAINER_REQUEST__INIT;
  char snapshotter[CC_CTR_MOUNT_SRC_MAX];
  char snapshot_key[CC_CTR_MOUNT_SRC_MAX];
  uint8_t reqbuf[1024];
  uint8_t respbuf[1024];
  uint32_t resp_len = 0;
  size_t reqlen;
  int rc;

  if (h <= 0 || id == NULL || id[0] == '\0')
    return CC_CTR_ERR_BADARG;

  /* container.Delete() first refuses to delete a container with a task. */
  rc = cc_ctr_get_task(h, id, NULL);
  if (rc == CC_GRPC_STATUS_OK)
    return CC_GRPC_STATUS_FAILED_PRECONDITION;
  if (rc != CC_GRPC_STATUS_NOT_FOUND)
    return rc;

  /* Fetch the record (client: c.get), then WithSnapshotCleanup. */
  rc = get_container_info(h, id, snapshotter, sizeof(snapshotter),
                          snapshot_key, sizeof(snapshot_key));
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  if (snapshot_key[0] != '\0') {
    if (snapshotter[0] == '\0')
      return CC_CTR_ERR_STATE;
    rc = cc_ctr_remove_snapshot(h, snapshotter, snapshot_key);
    if (rc != CC_GRPC_STATUS_OK)
      return rc;
  }

  req.id = (char *)id;
  reqlen =
      containerd__services__containers__v1__delete_container_request__get_packed_size(
          &req);
  containerd__services__containers__v1__delete_container_request__pack(&req,
                                                                       reqbuf);
  return cc_grpc_unary(h,
                       "/containerd.services.containers.v1.Containers/Delete",
                       reqbuf, (uint32_t)reqlen, respbuf, sizeof(respbuf),
                       &resp_len);
}

/* =========================================================================
 * Tasks
 * ========================================================================= */

int cc_ctr_create_task(int h, const char *container_id,
                       const char *stdout_uri, const char *stderr_uri,
                       uint32_t *out_pid, const char *nvidia_bin) {
  Containerd__Services__Tasks__V1__CreateTaskRequest req =
      CONTAINERD__SERVICES__TASKS__V1__CREATE_TASK_REQUEST__INIT;
  Google__Protobuf__Any task_opts = GOOGLE__PROTOBUF__ANY__INIT;
  uint8_t runc_value[130];
  uint32_t runc_value_len = 0;
  char snapshotter[CC_CTR_MOUNT_SRC_MAX];
  char snapshot_key[CC_CTR_MOUNT_SRC_MAX];
  struct cc_ctr_mount mounts[CC_CTR_MAX_MOUNTS];
  uint32_t n_mounts = 0;
  Containerd__Types__Mount rootfs[CC_CTR_MAX_MOUNTS];
  Containerd__Types__Mount *rootfs_ptrs[CC_CTR_MAX_MOUNTS];
  char *rootfs_opts[CC_CTR_MAX_MOUNTS][CC_CTR_MOUNT_OPT_MAX];
  uint8_t reqbuf[CC_CTR_REQ_MAX];
  uint8_t respbuf[CC_CTR_RESP_MAX];
  uint32_t resp_len = 0;
  Containerd__Services__Tasks__V1__CreateTaskResponse *resp;
  size_t reqlen;
  uint32_t i, j;
  int rc;

  if (h <= 0 || container_id == NULL || container_id[0] == '\0')
    return CC_CTR_ERR_BADARG;
  if (out_pid != NULL)
    *out_pid = 0;

  /* Go client sequence part 1: Containers/Get + Snapshots/Mounts (the
   * client's handleMounts), reading the record's snapshotter/key. */
  rc = get_container_info(h, container_id, snapshotter, sizeof(snapshotter),
                          snapshot_key, sizeof(snapshot_key));
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  if (snapshot_key[0] != '\0') {
    if (snapshotter[0] == '\0')
      return CC_CTR_ERR_STATE;
    rc = cc_ctr_mounts(h, snapshotter, snapshot_key, mounts,
                       CC_CTR_MAX_MOUNTS, &n_mounts);
    if (rc != CC_GRPC_STATUS_OK)
      return rc;
  }

  /* Go client sequence part 2: two more Containers/Get calls (the client's
   * Spec() mount-label check and its runtime-name fetch) — kept for wire
   * parity; our specs carry no mount label. */
  rc = get_container_info(h, container_id, NULL, 0, NULL, 0);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  rc = get_container_info(h, container_id, NULL, 0, NULL, 0);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;

  /* Rebuild the codec rootfs from the fixed-arity mount records. */
  for (i = 0; i < n_mounts; i++) {
    containerd__types__mount__init(&rootfs[i]);
    rootfs[i].type = mounts[i].type;
    rootfs[i].source = mounts[i].source;
    rootfs[i].target = mounts[i].target;
    rootfs[i].n_options = mounts[i].n_options;
    for (j = 0; j < mounts[i].n_options; j++)
      rootfs_opts[i][j] = mounts[i].options[j];
    rootfs[i].options = rootfs_opts[i];
    rootfs_ptrs[i] = &rootfs[i];
  }

  /* Option C (per-container NVIDIA runtime): when nvidia_bin is set, carry
   * runc/options.Options{BinaryName: nvidia_bin} in CreateTaskRequest.options
   * so the runc shim execs that runtime binary instead of plain runc (the Go
   * client's NewTask(WithRuntimeOptions) wire, client/container.go:275-280).
   * NULL keeps the pre-Option-C wire (options absent -> plain runc). The
   * tasks service formatOptions requires task options for io.containerd.runc
   * .v2 to be exactly runc/options.Options, so the carrier is only added for
   * GPU tasks. */
  if (nvidia_bin != NULL && nvidia_bin[0] != '\0') {
    rc = ctr_pack_runc_value(nvidia_bin, runc_value, sizeof(runc_value),
                             &runc_value_len);
    if (rc != CC_GRPC_STATUS_OK)
      return rc;
    task_opts.type_url = (char *)CC_CTR_RUNC_OPTIONS_TYPE_URL;
    task_opts.value.data = runc_value;
    task_opts.value.len = runc_value_len;
    req.options = &task_opts;
  }

  req.container_id = (char *)container_id;
  req.n_rootfs = n_mounts;
  req.rootfs = rootfs_ptrs;
  req.stdin = (char *)"";
  req.stdout = (char *)(stdout_uri != NULL ? stdout_uri : "");
  req.stderr = (char *)(stderr_uri != NULL ? stderr_uri : "");
  reqlen =
      containerd__services__tasks__v1__create_task_request__get_packed_size(
          &req);
  if (reqlen > sizeof(reqbuf))
    return CC_CTR_ERR_TOOBIG;
  containerd__services__tasks__v1__create_task_request__pack(&req, reqbuf);
  rc = cc_grpc_unary(h, "/containerd.services.tasks.v1.Tasks/Create", reqbuf,
                     (uint32_t)reqlen, respbuf, sizeof(respbuf), &resp_len);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  resp = containerd__services__tasks__v1__create_task_response__unpack(
      NULL, resp_len, respbuf);
  if (resp == NULL)
    return CC_CTR_ERR_STATE;
  if (out_pid != NULL)
    *out_pid = resp->pid;
  containerd__services__tasks__v1__create_task_response__free_unpacked(resp,
                                                                       NULL);
  return CC_GRPC_STATUS_OK;
}

int cc_ctr_start_task(int h, const char *container_id, uint32_t *out_pid) {
  Containerd__Services__Tasks__V1__StartRequest req =
      CONTAINERD__SERVICES__TASKS__V1__START_REQUEST__INIT;
  uint8_t reqbuf[1024];
  uint8_t respbuf[1024];
  uint32_t resp_len = 0;
  Containerd__Services__Tasks__V1__StartResponse *resp;
  size_t reqlen;
  int rc;

  if (h <= 0 || container_id == NULL || container_id[0] == '\0')
    return CC_CTR_ERR_BADARG;
  if (out_pid != NULL)
    *out_pid = 0;
  req.container_id = (char *)container_id;
  reqlen = containerd__services__tasks__v1__start_request__get_packed_size(
      &req);
  containerd__services__tasks__v1__start_request__pack(&req, reqbuf);
  rc = cc_grpc_unary(h, "/containerd.services.tasks.v1.Tasks/Start", reqbuf,
                     (uint32_t)reqlen, respbuf, sizeof(respbuf), &resp_len);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  resp = containerd__services__tasks__v1__start_response__unpack(
      NULL, resp_len, respbuf);
  if (resp == NULL)
    return CC_CTR_ERR_STATE;
  if (out_pid != NULL)
    *out_pid = resp->pid;
  containerd__services__tasks__v1__start_response__free_unpacked(resp, NULL);
  return CC_GRPC_STATUS_OK;
}

int cc_ctr_kill_task(int h, const char *container_id, uint32_t signal) {
  Containerd__Services__Tasks__V1__KillRequest req =
      CONTAINERD__SERVICES__TASKS__V1__KILL_REQUEST__INIT;
  uint8_t reqbuf[1024];
  uint8_t respbuf[1024];
  uint32_t resp_len = 0;
  size_t reqlen;

  if (h <= 0 || container_id == NULL || container_id[0] == '\0')
    return CC_CTR_ERR_BADARG;
  req.container_id = (char *)container_id;
  req.signal = signal;
  reqlen = containerd__services__tasks__v1__kill_request__get_packed_size(
      &req);
  containerd__services__tasks__v1__kill_request__pack(&req, reqbuf);
  return cc_grpc_unary(h, "/containerd.services.tasks.v1.Tasks/Kill", reqbuf,
                       (uint32_t)reqlen, respbuf, sizeof(respbuf), &resp_len);
}

int cc_ctr_delete_task(int h, const char *container_id,
                       uint32_t *out_exit_status) {
  Containerd__Services__Tasks__V1__DeleteTaskRequest req =
      CONTAINERD__SERVICES__TASKS__V1__DELETE_TASK_REQUEST__INIT;
  uint8_t reqbuf[1024];
  uint8_t respbuf[1024];
  uint32_t resp_len = 0;
  Containerd__Services__Tasks__V1__DeleteResponse *resp;
  size_t reqlen;
  int rc;

  if (h <= 0 || container_id == NULL || container_id[0] == '\0')
    return CC_CTR_ERR_BADARG;
  if (out_exit_status != NULL)
    *out_exit_status = 0;
  req.container_id = (char *)container_id;
  reqlen = containerd__services__tasks__v1__delete_task_request__get_packed_size(
      &req);
  containerd__services__tasks__v1__delete_task_request__pack(&req, reqbuf);
  rc = cc_grpc_unary(h, "/containerd.services.tasks.v1.Tasks/Delete", reqbuf,
                     (uint32_t)reqlen, respbuf, sizeof(respbuf), &resp_len);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  resp = containerd__services__tasks__v1__delete_response__unpack(
      NULL, resp_len, respbuf);
  if (resp == NULL)
    return CC_CTR_ERR_STATE;
  if (out_exit_status != NULL)
    *out_exit_status = resp->exit_status;
  containerd__services__tasks__v1__delete_response__free_unpacked(resp, NULL);
  return CC_GRPC_STATUS_OK;
}

int cc_ctr_get_task(int h, const char *container_id, uint32_t *out_pid) {
  Containerd__Services__Tasks__V1__GetRequest req =
      CONTAINERD__SERVICES__TASKS__V1__GET_REQUEST__INIT;
  uint8_t reqbuf[1024];
  uint8_t respbuf[CC_CTR_RESP_MAX];
  uint32_t resp_len = 0;
  Containerd__Services__Tasks__V1__GetResponse *resp;
  size_t reqlen;
  int rc;

  if (h <= 0 || container_id == NULL || container_id[0] == '\0')
    return CC_CTR_ERR_BADARG;
  if (out_pid != NULL)
    *out_pid = 0;
  req.container_id = (char *)container_id;
  reqlen = containerd__services__tasks__v1__get_request__get_packed_size(&req);
  containerd__services__tasks__v1__get_request__pack(&req, reqbuf);
  rc = cc_grpc_unary(h, "/containerd.services.tasks.v1.Tasks/Get", reqbuf,
                     (uint32_t)reqlen, respbuf, sizeof(respbuf), &resp_len);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  resp = containerd__services__tasks__v1__get_response__unpack(
      NULL, resp_len, respbuf);
  if (resp == NULL || resp->process == NULL)
    return CC_CTR_ERR_STATE;
  if (out_pid != NULL)
    *out_pid = resp->process->pid;
  containerd__services__tasks__v1__get_response__free_unpacked(resp, NULL);
  return CC_GRPC_STATUS_OK;
}

int cc_ctr_wait_task(int h, const char *container_id,
                     uint32_t *out_exit_status) {
  Containerd__Services__Tasks__V1__WaitRequest req =
      CONTAINERD__SERVICES__TASKS__V1__WAIT_REQUEST__INIT;
  uint8_t reqbuf[1024];
  uint8_t respbuf[1024];
  uint32_t resp_len = 0;
  Containerd__Services__Tasks__V1__WaitResponse *resp;
  size_t reqlen;
  int rc;

  if (h <= 0 || container_id == NULL || container_id[0] == '\0')
    return CC_CTR_ERR_BADARG;
  if (out_exit_status != NULL)
    *out_exit_status = 0;
  req.container_id = (char *)container_id;
  reqlen = containerd__services__tasks__v1__wait_request__get_packed_size(
      &req);
  containerd__services__tasks__v1__wait_request__pack(&req, reqbuf);
  rc = cc_grpc_unary(h, "/containerd.services.tasks.v1.Tasks/Wait", reqbuf,
                     (uint32_t)reqlen, respbuf, sizeof(respbuf), &resp_len);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  resp = containerd__services__tasks__v1__wait_response__unpack(
      NULL, resp_len, respbuf);
  if (resp == NULL)
    return CC_CTR_ERR_STATE;
  if (out_exit_status != NULL)
    *out_exit_status = resp->exit_status;
  containerd__services__tasks__v1__wait_response__free_unpacked(resp, NULL);
  return CC_GRPC_STATUS_OK;
}

/* =========================================================================
 * Events
 * ========================================================================= */

int cc_ctr_subscribe(int h, const char *filter, void *cb_ctx,
                     void (*cb)(void *cb_ctx, const uint8_t *env,
                                uint32_t len)) {
  if (h <= 0 || filter == NULL || cb == NULL)
    return 0;
  return cc_grpc_subscribe(h, filter, cb_ctx, cb);
}

/* =========================================================================
 * OCI spec JSON builder + Any wrapper (Q13 contract)
 * ========================================================================= */

/* --- tiny JSON writer (Go json.Marshal-compatible) --- */

struct json_out {
  char *buf;
  uint32_t cap;
  uint32_t len;
};

static void jout_raw(struct json_out *o, const char *s) {
  size_t n = strlen(s);
  if (o->len + n >= o->cap)
    n = (o->cap > o->len) ? o->cap - o->len : 0;
  memcpy(o->buf + o->len, s, n);
  o->len += (uint32_t)n;
}

static void jout_ch(struct json_out *o, char c) {
  if (o->len + 1 >= o->cap)
    return;
  o->buf[o->len++] = c;
}

static void jout_uint(struct json_out *o, uint32_t v) {
  char tmp[16];
  int n = 0;
  do {
    tmp[n++] = (char)('0' + v % 10);
    v /= 10;
  } while (v > 0);
  while (n > 0)
    jout_ch(o, tmp[--n]);
}

/* Emit a JSON string with Go's encoding/json escaping: quote, backslash,
 * \t \r \n, control chars as \u00xx, and HTML escapes \u003c \u003e \u0026
 * (all lowercase hex, matching Go's SetEscapeHTML(true) default). */
static void jout_str(struct json_out *o, const char *s) {
  static const char hex[] = "0123456789abcdef";
  const unsigned char *p;

  if (s == NULL)
    s = ""; /* boundary parse: NULL string -> empty */
  p = (const unsigned char *)s;
  jout_ch(o, '"');
  while (*p != 0) {
    unsigned char c = *p++;
    switch (c) {
      case '"':
        jout_raw(o, "\\\"");
        break;
      case '\\':
        jout_raw(o, "\\\\");
        break;
      case '\n':
        jout_raw(o, "\\n");
        break;
      case '\r':
        jout_raw(o, "\\r");
        break;
      case '\t':
        jout_raw(o, "\\t");
        break;
      case '<':
        jout_raw(o, "\\u003c");
        break;
      case '>':
        jout_raw(o, "\\u003e");
        break;
      case '&':
        jout_raw(o, "\\u0026");
        break;
      default:
        if (c < 0x20) {
          jout_raw(o, "\\u00");
          jout_ch(o, hex[c >> 4]);
          jout_ch(o, hex[c & 0xF]);
        } else {
          jout_ch(o, (char)c);
        }
        break;
    }
  }
  jout_ch(o, '"');
}

static void jout_str_array(struct json_out *o, const char *const *strs,
                           uint32_t n) {
  uint32_t i;
  jout_ch(o, '[');
  for (i = 0; i < n; i++) {
    if (i > 0)
      jout_ch(o, ',');
    jout_str(o, strs[i]);
  }
  jout_ch(o, ']');
}

/* --- the fixed skeleton constants (from the Go client) --- */

static const char *const k_default_caps[] = {
    "CAP_CHOWN",        "CAP_DAC_OVERRIDE", "CAP_FSETID",
    "CAP_FOWNER",       "CAP_MKNOD",        "CAP_NET_RAW",
    "CAP_SETGID",       "CAP_SETUID",       "CAP_SETFCAP",
    "CAP_SETPCAP",      "CAP_NET_BIND_SERVICE", "CAP_SYS_CHROOT",
    "CAP_KILL",         "CAP_AUDIT_WRITE",
};

static const char *const k_default_namespaces[] = {"pid", "ipc", "uts",
                                                   "mount"};
static const char *const k_default_namespaces_net[] = {"pid", "ipc", "uts",
                                                       "mount", "network"};

static const char *const k_masked_paths[] = {
    "/proc/acpi",
    "/proc/asound",
    "/proc/kcore",
    "/proc/keys",
    "/proc/latency_stats",
    "/proc/timer_list",
    "/proc/timer_stats",
    "/proc/sched_debug",
    "/sys/firmware",
    "/sys/devices/virtual/powercap",
    "/proc/scsi",
};

static const char *const k_readonly_paths[] = {
    "/proc/bus",
    "/proc/fs",
    "/proc/irq",
    "/proc/sys",
    "/proc/sysrq-trigger",
};

/* The seven default mounts (oci.defaultMounts), in order. Each entry is
 * destination, type, source, then up to 8 options. */
struct default_mount {
  const char *destination;
  const char *type;
  const char *source;
  uint32_t n_options;
  const char *options[8];
};

static const struct default_mount k_default_mounts[] = {
    {"/proc", "proc", "proc", 3,
     {"nosuid", "noexec", "nodev"}},
    {"/dev", "tmpfs", "tmpfs", 4,
     {"nosuid", "strictatime", "mode=755", "size=65536k"}},
    {"/dev/pts", "devpts", "devpts", 6,
     {"nosuid", "noexec", "newinstance", "ptmxmode=0666", "mode=0620",
      "gid=5"}},
    {"/dev/shm", "tmpfs", "shm", 5,
     {"nosuid", "noexec", "nodev", "mode=1777", "size=65536k"}},
    {"/dev/mqueue", "mqueue", "mqueue", 3,
     {"nosuid", "noexec", "nodev"}},
    {"/sys", "sysfs", "sysfs", 4,
     {"nosuid", "noexec", "nodev", "ro"}},
    {"/run", "tmpfs", "tmpfs", 4,
     {"nosuid", "strictatime", "mode=755", "size=65536k"}},
};

static void jout_mount_json(struct json_out *o, const char *destination,
                            const char *type, const char *source,
                            const char *const *options, uint32_t n_options) {
  jout_ch(o, '{');
  jout_raw(o, "\"destination\":");
  jout_str(o, destination);
  if (type != NULL && type[0] != '\0') {
    jout_raw(o, ",\"type\":");
    jout_str(o, type);
  }
  if (source != NULL && source[0] != '\0') {
    jout_raw(o, ",\"source\":");
    jout_str(o, source);
  }
  if (n_options > 0) {
    jout_raw(o, ",\"options\":");
    jout_str_array(o, options, n_options);
  }
  jout_ch(o, '}');
}

int cc_ctr_oci_spec_build(const struct cc_ctr_oci_spec *spec, char *out,
                          uint32_t cap) {
  struct json_out o;
  uint32_t i;

  if (spec == NULL || out == NULL || cap == 0)
    return CC_CTR_ERR_BADARG;
  /* Boundary validation: the fixed-size field tables cannot overflow; fail
   * loudly instead of silently dropping entries. */
  if (spec->n_env > CC_CTR_OCI_ENV_MAX || spec->n_args > CC_CTR_OCI_ARGS_MAX ||
      spec->n_caps_add > CC_CTR_OCI_CAPS_MAX ||
      spec->n_additional_gids > CC_CTR_OCI_GIDS_MAX ||
      spec->n_mounts > CC_CTR_OCI_MOUNTS_MAX ||
      spec->n_annotations > CC_CTR_OCI_ANN_MAX)
    return CC_CTR_ERR_BADARG;
  o.buf = out;
  o.cap = cap;
  o.len = 0;

  /* Spec struct order: ociVersion, process, root, hostname, domainname,
   * mounts, hooks, annotations, linux. */
  jout_raw(&o, "{\"ociVersion\":");
  jout_str(&o, CC_CTR_OCI_VERSION);

  /* process */
  jout_raw(&o, ",\"process\":{\"user\":{\"uid\":");
  jout_uint(&o, spec->uid);
  jout_raw(&o, ",\"gid\":");
  jout_uint(&o, spec->gid);
  if (spec->n_additional_gids > 0) {
    jout_raw(&o, ",\"additionalGids\":[");
    for (i = 0; i < spec->n_additional_gids; i++) {
      if (i > 0)
        jout_ch(&o, ',');
      jout_uint(&o, spec->additional_gids[i]);
    }
    jout_ch(&o, ']');
  }
  jout_ch(&o, '}');
  if (spec->n_args > 0) {
    jout_raw(&o, ",\"args\":");
    jout_str_array(&o, spec->args, spec->n_args);
  }
  if (spec->n_env > 0) {
    jout_raw(&o, ",\"env\":");
    jout_str_array(&o, spec->env, spec->n_env);
  }
  jout_raw(&o, ",\"cwd\":");
  jout_str(&o, spec->cwd != NULL ? spec->cwd : "/");

  /* capabilities: bounding/effective/permitted = default + adds */
  jout_raw(&o, ",\"capabilities\":{\"bounding\":");
  {
    const char *caps[CC_CTR_OCI_CAPS_MAX + 16];
    uint32_t n_caps = 0;
    for (i = 0; i < 14 && n_caps < (CC_CTR_OCI_CAPS_MAX + 16); i++)
      caps[n_caps++] = k_default_caps[i];
    for (i = 0; i < spec->n_caps_add && n_caps < (CC_CTR_OCI_CAPS_MAX + 16);
         i++)
      caps[n_caps++] = spec->caps_add[i];
    jout_str_array(&o, caps, n_caps);
  }
  jout_raw(&o, ",\"effective\":");
  {
    const char *caps[CC_CTR_OCI_CAPS_MAX + 16];
    uint32_t n_caps = 0;
    for (i = 0; i < 14 && n_caps < (CC_CTR_OCI_CAPS_MAX + 16); i++)
      caps[n_caps++] = k_default_caps[i];
    for (i = 0; i < spec->n_caps_add && n_caps < (CC_CTR_OCI_CAPS_MAX + 16);
         i++)
      caps[n_caps++] = spec->caps_add[i];
    jout_str_array(&o, caps, n_caps);
  }
  jout_raw(&o, ",\"permitted\":");
  {
    const char *caps[CC_CTR_OCI_CAPS_MAX + 16];
    uint32_t n_caps = 0;
    for (i = 0; i < 14 && n_caps < (CC_CTR_OCI_CAPS_MAX + 16); i++)
      caps[n_caps++] = k_default_caps[i];
    for (i = 0; i < spec->n_caps_add && n_caps < (CC_CTR_OCI_CAPS_MAX + 16);
         i++)
      caps[n_caps++] = spec->caps_add[i];
    jout_str_array(&o, caps, n_caps);
  }
  jout_ch(&o, '}');

  jout_raw(&o, ",\"rlimits\":[{\"type\":\"RLIMIT_NOFILE\",\"hard\":1024,\"soft\":1024}]");
  jout_raw(&o, ",\"noNewPrivileges\":true");

  /* root */
  jout_raw(&o, "},\"root\":{\"path\":\"rootfs\"}");

  /* hostname (Spec struct order: root, hostname, domainname, mounts) */
  if (spec->hostname != NULL && spec->hostname[0] != '\0') {
    jout_raw(&o, ",\"hostname\":");
    jout_str(&o, spec->hostname);
  }

  /* mounts: 7 defaults + controller bind mounts */
  jout_raw(&o, ",\"mounts\":[");
  for (i = 0; i < 7; i++) {
    if (i > 0)
      jout_ch(&o, ',');
    jout_mount_json(&o, k_default_mounts[i].destination,
                    k_default_mounts[i].type, k_default_mounts[i].source,
                    k_default_mounts[i].options,
                    k_default_mounts[i].n_options);
  }
  for (i = 0; i < spec->n_mounts; i++) {
    jout_ch(&o, ',');
    jout_mount_json(&o, spec->mounts[i].destination, spec->mounts[i].type,
                    spec->mounts[i].source, spec->mounts[i].options,
                    spec->mounts[i].n_options);
  }
  jout_ch(&o, ']');

  /* annotations (before linux, per Spec struct order); entries are
   "key=value" strings emitted as JSON members. */
  if (spec->n_annotations > 0) {
    jout_raw(&o, ",\"annotations\":{");
    for (i = 0; i < spec->n_annotations; i++) {
      const char *eq;
      if (i > 0)
        jout_ch(&o, ',');
      if (spec->annotations[i] == NULL)
        return CC_CTR_ERR_JSON;
      eq = strchr(spec->annotations[i], '=');
      /* Emit the key with its own NUL-terminated copy (the writer only
       * reads; a temporary character swap is safe here). */
      {
        char keybuf[512];
        size_t keylen = (size_t)(eq - spec->annotations[i]);
        if (keylen >= sizeof(keybuf))
          return CC_CTR_ERR_JSON;
        memcpy(keybuf, spec->annotations[i], keylen);
        keybuf[keylen] = '\0';
        jout_str(&o, keybuf);
      }
      jout_ch(&o, ':');
      jout_str(&o, eq + 1);
    }
    jout_ch(&o, '}');
  }

  /* linux */
  jout_raw(&o, ",\"linux\":{\"resources\":{\"devices\":[{\"allow\":false,\"access\":\"rwm\"}]}");
  if (spec->cgroups_path != NULL && spec->cgroups_path[0] != '\0') {
    jout_raw(&o, ",\"cgroupsPath\":");
    jout_str(&o, spec->cgroups_path);
  }
  jout_raw(&o, ",\"namespaces\":[");
  if (spec->host_network) {
    for (i = 0; i < 4; i++) {
      if (i > 0)
        jout_ch(&o, ',');
      jout_raw(&o, "{\"type\":");
      jout_str(&o, k_default_namespaces[i]);
      jout_ch(&o, '}');
    }
  } else {
    for (i = 0; i < 5; i++) {
      if (i > 0)
        jout_ch(&o, ',');
      jout_raw(&o, "{\"type\":");
      jout_str(&o, k_default_namespaces_net[i]);
      jout_ch(&o, '}');
    }
  }
  jout_ch(&o, ']');
  jout_raw(&o, ",\"maskedPaths\":");
  jout_str_array(&o, k_masked_paths, 11);
  jout_raw(&o, ",\"readonlyPaths\":");
  jout_str_array(&o, k_readonly_paths, 5);
  jout_raw(&o, "}}");

  if (o.len >= o.cap) {
    /* The writer truncates silently at cap; report overflow loudly. */
    return CC_CTR_ERR_TOOBIG;
  }
  o.buf[o.len] = '\0';
  return (int)o.len;
}

int cc_ctr_oci_wrap_any(const uint8_t *spec_json, uint32_t json_len,
                        uint8_t *out_any, uint32_t any_cap,
                        uint32_t *out_any_len) {
  Google__Protobuf__Any any = GOOGLE__PROTOBUF__ANY__INIT;
  size_t len;

  if (spec_json == NULL || json_len == 0 || out_any == NULL || any_cap == 0 ||
      out_any_len == NULL)
    return CC_CTR_ERR_BADARG;
  any.type_url = (char *)CC_CTR_OCI_TYPE_URL;
  any.value.data = (uint8_t *)spec_json;
  any.value.len = json_len;
  len = google__protobuf__any__get_packed_size(&any);
  if (len > any_cap)
    return CC_CTR_ERR_TOOBIG;
  google__protobuf__any__pack(&any, out_any);
  *out_any_len = (uint32_t)len;
  return CC_GRPC_STATUS_OK;
}

int cc_ctr_pack_runc_nvidia(const char *nvidia_bin, uint8_t *out_any,
                            uint32_t any_cap, uint32_t *out_any_len) {
  uint8_t runc_value[130];
  uint32_t runc_value_len = 0;
  Google__Protobuf__Any any = GOOGLE__PROTOBUF__ANY__INIT;
  size_t len;
  int rc;

  if (out_any == NULL || any_cap == 0 || out_any_len == NULL)
    return CC_CTR_ERR_BADARG;
  rc = ctr_pack_runc_value(nvidia_bin, runc_value, sizeof(runc_value),
                           &runc_value_len);
  if (rc != CC_GRPC_STATUS_OK)
    return rc;
  any.type_url = (char *)CC_CTR_RUNC_OPTIONS_TYPE_URL;
  any.value.data = runc_value;
  any.value.len = runc_value_len;
  len = google__protobuf__any__get_packed_size(&any);
  if (len > any_cap)
    return CC_CTR_ERR_TOOBIG;
  google__protobuf__any__pack(&any, out_any);
  *out_any_len = (uint32_t)len;
  return CC_GRPC_STATUS_OK;
}