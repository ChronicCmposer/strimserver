/*
 * snapshots.h — minimal containerd Snapshots service client.
 *
 * Wave 1 (containerd lane). The Snapshots service is NOT covered by the Wave
 * 0-D nanopb codecs, so this module hand-rolls the three RPCs the container
 * client needs (snapshots.pb wire format, see minipb.h):
 *
 *   Prepare  — create a new (active) snapshot whose parent is the image's
 *              rootfs chain (the Go WithNewSnapshot contract).
 *   Remove   — delete a snapshot (the WithSnapshotCleanup contract).
 *   Mounts   — read back the snapshot's mounts (the Tasks/Create rootfs
 *              contract, container.go:handleMounts in the v2 client).
 *
 * Mounts are returned as a malloc'd array of nanopb containerd_types_Mount
 * with malloc'd string fields; free them with snapshots_free_mounts.
 *
 * Method paths (containerd api v1.12.0):
 *   /containerd.services.snapshots.v1.Snapshots/{Prepare,Remove,Mounts}
 *
 * License: project code (see LICENSE). No GPL.
 */
#ifndef STRIM_SNAPSHOTS_H
#define STRIM_SNAPSHOTS_H

#include <stddef.h>
#include <stdint.h>

#include "h2c.h"

#ifdef __cplusplus
extern "C" {
#endif

#include <services/tasks/v1/tasks.pb.h> /* containerd_types_Mount via types/mount */

/* Create an active snapshot `key` parented on `parent` (the image's rootfs
 * chain ID). Returns 0, a positive gRPC status, or a negative H2C_ERR_*.
 * mounts and n_mounts are set only on success (may be NULL to ignore). */
int snapshots_prepare(strim_h2c *c, const char *snapshotter, const char *key,
                      const char *parent, containerd_types_Mount **mounts,
                      pb_size_t *n_mounts);

/* Remove a snapshot. Returns 0, a positive gRPC status, or a negative
 * H2C_ERR_*. NotFound (status 5) is returned to the caller for tolerance. */
int snapshots_remove(strim_h2c *c, const char *snapshotter, const char *key);

/* Read a snapshot.s mounts. Returns 0 + mounts and n_mounts, a positive gRPC
 * status, or a negative H2C_ERR_*. */
int snapshots_mounts(strim_h2c *c, const char *snapshotter, const char *key,
                     containerd_types_Mount **mounts, pb_size_t *n_mounts);

/* Free an array of mounts returned by snapshots_prepare / snapshots_mounts. */
void snapshots_free_mounts(containerd_types_Mount *mounts, pb_size_t n);

#ifdef __cplusplus
}
#endif

#endif /* STRIM_SNAPSHOTS_H */