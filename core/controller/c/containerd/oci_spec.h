/*
 * oci_spec.h — OCI runtime-spec JSON builder for the containerd client.
 *
 * Wave 1 (containerd lane). containerd's Go client stores the container's OCI
 * runtime spec as a google.protobuf.Any whose value is the JSON-serialized
 * spec (typeurl.MarshalAny of a specs.Spec; the JSON is what runc consumes).
 * This module reproduces the spec containerd's oci.GenerateSpec produces for
 * the strimserver factory (pkg/oci/spec.go + spec_opts.go), serialized with
 * Go's json.Marshal field-elision rules:
 *
 *   - Default unix spec: ociVersion 1.0.2, root{path:"rootfs"}, process{cwd:"/",
 *     noNewPrivileges:true, user, capabilities {bounding/effective/permitted =
 *     defaultUnixCaps}, rlimits [{RLIMIT_NOFILE 1024}], maskedPaths,
 *     readonlyPaths, cgroupsPath "/<namespace>/<id>", resources.devices
 *     [{allow:false,access:"rwm"}], namespaces [pid,ipc,uts,mount,network],
 *     and the 7 default mounts (/proc /dev /dev/pts /dev/shm /dev/mqueue
 *     /sys /run).
 *   - WithImageConfig: process.env = image env (or strim_default_unix_env),
 *     process.args = image entrypoint + cmd, cwd = image working dir (or
 *     "/"), user from the image config user.
 *   - WithHostNamespace(NetworkNamespace): the network namespace is REMOVED
 *     when host_network is set.
 *   - WithAddedCapabilities: strim_process.capabilities are appended (dedup)
 *     to the three capability sets.
 *   - WithMounts: strim_spec.mounts become bind mounts
 *     {"rbind","rw"|"ro"} appended after the default mounts.
 *   - CDI containerEdits (device nodes -> linux.devices, hooks -> hooks,
 *     additional GIDs -> process.user.additionalGids) are merged when the
 *     caller passes a non-NULL cdi edit set.
 *
 * The output is a malloc'd JSON buffer; the caller frees it.
 *
 * License: project code (see LICENSE). No GPL.
 */
#ifndef STRIM_OCI_SPEC_H
#define STRIM_OCI_SPEC_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#include "spec.h" /* strim_spec */

/* The OCI image config fields the spec builder consumes (parsed from the
 * image config JSON blob by the containerd client). All pointers are
 * caller-owned and remain valid for the build call. */
typedef struct strim_oci_image_config {
  const char *const *env;
  size_t n_env;
  const char *const *entrypoint;
  size_t n_entrypoint;
  const char *const *cmd;
  size_t n_cmd;
  const char *working_dir; /* NULL = "/" */
  const char *user;        /* image config User string; NULL = root */
} strim_oci_image_config;

/* CDI containerEdits that do NOT fit in strim_spec's fixed arrays (the
 * strim_spec env/mounts arrays are const, so the OCI builder receives the
 * full edit set here and appends every kind — env, mounts, device nodes,
 * hooks, additional GIDs — the same way containerd's pkg/cdi applyEdits
 * does). NULL means no CDI device was resolved. */
typedef struct strim_oci_cdi_mount {
  const char *host_path;
  const char *container_path;
  const char *const *options;
  size_t n_options;
} strim_oci_cdi_mount;

typedef struct strim_oci_cdi_device {
  const char *path;
  const char *type; /* "c" / "b" / "p" / "u" */
  int64_t major;
  int64_t minor;
  uint32_t file_mode; /* 0 = omit */
  uint32_t uid;       /* 0 = omit */
  uint32_t gid;       /* 0 = omit */
} strim_oci_cdi_device;

typedef struct strim_oci_cdi_hook {
  const char *path;
  const char *const *args;
  size_t n_args;
  const char *const *env;
  size_t n_env;
  int32_t timeout; /* 0 = omit */
} strim_oci_cdi_hook;

typedef struct strim_oci_cdi_edits {
  const char *const *env;
  size_t n_env;

  strim_oci_cdi_mount *mounts;
  size_t n_mounts;

  strim_oci_cdi_device *devices;
  size_t n_devices;

  strim_oci_cdi_hook *hooks;
  size_t n_hooks;

  const uint32_t *additional_gids;
  size_t n_additional_gids;
} strim_oci_cdi_edits;

/* Build the OCI spec JSON. Returns 0 + a malloc.d out_json/out_len, or a
 * negative STRIM_CDI_ERR_*-style error. container_id feeds the cgroups path
 * ("/<namespace>/<container-id>") unless strim_spec.cgroups_path overrides
 * it. */
int strim_oci_build_spec(const strim_spec *spec,
                         const strim_oci_image_config *image,
                         const char *namespace_, const char *container_id,
                         const strim_oci_cdi_edits *cdi, char **out_json,
                         size_t *out_len);

#ifdef __cplusplus
}
#endif

#endif /* STRIM_OCI_SPEC_H */