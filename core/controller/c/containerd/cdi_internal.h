/*
 * cdi_internal.h — internal CDI state for the containerd client lane.
 *
 * The public contract (cdi.h) is implemented in cdi.c; this header exposes
 * the resolved device's containerEdits to the OCI spec builder inside the
 * same lane (containerd_client.c -> oci_spec.c). strim_spec's env/mounts
 * arrays are const, so the resolved edits cannot be physically written into
 * the strim_spec struct; instead strim_cdi_merge_edits validates and records
 * the pending merge, and strim_containerd_new_container applies the full
 * edit set (env, mounts, device nodes, hooks, additional GIDs) to the OCI
 * spec exactly like containerd's pkg/cdi applyEdits does.
 *
 * License: project code (see LICENSE). No GPL.
 */
#ifndef STRIM_CDI_INTERNAL_H
#define STRIM_CDI_INTERNAL_H

#include <stddef.h>
#include <stdint.h>

#include "oci_spec.h"

#ifdef __cplusplus
extern "C" {
#endif

/* The full containerEdits of the currently resolved CDI device (spec-level
 * edits merged with the device's own edits). All strings are owned by the
 * CDI module and stay valid until the next strim_cdi_scan / strim_cdi_resolve
 * call. */
typedef struct strim_cdi_edit_set {
  strim_oci_cdi_edits oci;
} strim_cdi_edit_set;

/* Fill *out with the pending resolved edit set (pointers into the CDI
 * module's state). Returns 0 when a device was resolved and merge_edits was
 * called, or a negative STRIM_CDI_ERR_* when nothing is pending. */
int strim_cdi_get_pending_edits(const strim_cdi_edit_set **out);

/* TEST HOOK: scan a single directory instead of the standard /etc/cdi +
 * /var/run/cdi pair (the public strim_cdi_scan paths are fixed by the
 * contract, so fixture-based tests use this to point the index at a temp
 * dir). Semantics are otherwise identical to strim_cdi_scan. */
int strim_cdi_test_scan_dir(const char *dir);

#ifdef __cplusplus
}
#endif

#endif /* STRIM_CDI_INTERNAL_H */