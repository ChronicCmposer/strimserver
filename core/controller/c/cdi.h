/*
 * cdi.h — CDI (Container Device Interface) resolution contract.
 *
 * Wave 0-A foundation header — STUB: the interface is fixed now, the
 * implementation lands in a later wave. The Go oracle uses CDI exactly once
 * (core/controller/container_factory.go:151):
 *
 *     cdi.WithCDIDevices("nvidia.com/gpu=0")   // appended to the ffmpeg spec
 *
 * so the container lane must be able to resolve a "vendor/class=id" device
 * reference into the OCI containerEdits (device nodes, mounts, env, hooks)
 * and merge them into the spec the same way containerd's pkg/cdi does.
 *
 * Resolution order (containerd/pkg/cdi cache behavior): scan the host's CDI
 * spec directories, parse the JSON spec files, index devices by
 * vendor/class, and look up the requested instance. The standard scan paths
 * are /etc/cdi and /var/run/cdi; spec files are *.json (and, when enabled,
 * *.yaml).
 *
 * The merged edits must be applied to the strim_spec BEFORE the container is
 * created (GetImage -> NewContainer carries the final spec). Device nodes and
 * mounts from containerEdits take effect in the container's rootfs; env and
 * hooks are merged into the process/spec.
 *
 * Style: fixed-arity C, caller-provided output buffers. All functions are
 * safe to call before any container is created (a one-time resolve per boot).
 *
 * License: project code (see LICENSE). No GPL.
 */
#ifndef STRIM_CDI_H
#define STRIM_CDI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#include "spec.h"   /* strim_spec — the containerEdits merge target       */

/* =========================================================================
 * Constants
 * ========================================================================= */

/* Standard CDI spec directories, in scan order (containerd/pkg/cdi
 * defaults). */
#define STRIM_CDI_DIR_ETC        "/etc/cdi"
#define STRIM_CDI_DIR_VAR_RUN    "/var/run/cdi"

/* Bounds for the fixed-size device lookup (fixed-arity design). */
#define STRIM_CDI_VENDOR_MAX     128   /* e.g. "nvidia.com"                  */
#define STRIM_CDI_CLASS_MAX      128   /* e.g. "gpu"                          */
#define STRIM_CDI_ID_MAX         128   /* e.g. "0" (the instance id)          */
#define STRIM_CDI_MAX_DEVICES    32    /* devices a single resolve can yield  */

/* Error codes (negative). */
#define STRIM_CDI_ERR_BADARG    (-1) /* NULL/empty required argument          */
#define STRIM_CDI_ERR_NODIR     (-2) /* neither scan directory exists         */
#define STRIM_CDI_ERR_PARSE     (-3) /* a spec file failed to parse           */
#define STRIM_CDI_ERR_NOTFOUND  (-4) /* the vendor/class=id device is unknown */
#define STRIM_CDI_ERR_NOMEM     (-5) /* internal allocation failed            */

/* =========================================================================
 * Device reference
 * ========================================================================= */

/* A resolved CDI device reference, e.g. "nvidia.com/gpu=0":
 *   vendor = "nvidia.com", device_class = "gpu", id = "0". */
typedef struct strim_cdi_ref {
    char vendor[STRIM_CDI_VENDOR_MAX];
    char device_class[STRIM_CDI_CLASS_MAX];
    char id[STRIM_CDI_ID_MAX];
} strim_cdi_ref;

/* Parse a "vendor/class=id" string into a ref. Returns 0, or a negative
 * error on malformed input. */
int strim_cdi_ref_parse(const char *dev, strim_cdi_ref *out);

/* =========================================================================
 * API
 * ========================================================================= */

/* Scan the host's CDI spec directories (both STRIM_CDI_DIR_ETC and
 * STRIM_CDI_DIR_VAR_RUN; a missing directory is not an error, but both
 * missing is STRIM_CDI_ERR_NODIR). Idempotent: a second call rescans and
 * replaces the previous index. The result feeds Resolve + MergeEdits. */
int strim_cdi_scan(void);

/* Resolve a parsed device reference: look up the vendor/class device set in
 * the scanned index and select the instance `id`. Returns 0, filling
 * *out_n_devices with the number of merged device entries the spec will get
 * (STRIM_CDI_MAX_DEVICES bound), or STRIM_CDI_ERR_NOTFOUND. */
int strim_cdi_resolve(const strim_cdi_ref *ref, uint32_t *out_n_devices);

/* Merge the resolved device's containerEdits into `spec` (device nodes,
 * mounts, env, hooks — everything the Go cdi.WithCDIDevices applies). Must be
 * called after Resolve and before the spec is passed to
 * strim_containerd_new_container. Returns 0, or a negative error (e.g. no
 * device was resolved yet). */
int strim_cdi_merge_edits(strim_spec *spec);

#ifdef __cplusplus
}
#endif

#endif /* STRIM_CDI_H */