// ============================================================================
// cc_ctr.h — containerd orchestration module constants (CPP macros)
// ============================================================================
//  Shared constants for the cc_ctr.S containerd ORCHESTRATION module — the
//  assembly half of Phase 4.4 (the C operation layer cc_ctr.c is Phase 4.4a
//  and provides the protocol/encoding; this module owns the OP
//  ORCHESTRATION: given a stage's desired state, run the correct start/stop
//  sequence by calling the C helpers).
//
//  Everything here is a CPP macro, never .equ: the fail-loud discipline
//  (AGENTS.md hard rule 6) means a module-local `.equ CC_OCI_N_ENV, 4`
//  collides with the macro and fails to assemble instead of silently
//  shadowing it.  The CC_STAGE_* / CC_STATE_* / CC_ENV_* / CC_LAY_* /
//  CC_ER_* / CC_CC_* ids and the CC_CTR_* mount-content strings come from
//  cc_layout.inc; this header adds only what THIS module needs.
//
//  The C-layer contract this module calls is core/controller/alternate/c/cc_ctr.h —
//  fixed-arity helpers returning gRPC status (>= 0, 0 = OK) or negative
//  CC_CTR_ERR_*.  The two files share the layout of struct cc_ctr_oci_spec
//  and struct cc_ctr_oci_mount: the byte offsets below were VERIFIED with a
//  `cc` offsetof probe against the real structs (aarch64, gcc 15.3) — the
//  assembly must build those structs byte-identically, so the offsets are a
//  frozen contract with the C layer.
//
//  gRPC status / transport codes the module must interpret (mirrors
//  cc_grpc.h): the module only distinguishes OK, NotFound, and
//  DEADLINE_EXCEEDED, plus the local CC_GRPC_ERR_TIMEOUT from the bounded
//  Wait RPC — everything else is propagated untouched (fail-loud).
//
//  The per-stage OCI field set (env/args/cwd/uid/gid/caps/mounts/network/
//  cgroups-path) is the assembly's port of container_factory.go's
//  buildContainer/CreateMediaMTXContainer/CreateFFmpegContainer +
//  containerd's oci package (see the module header in cc_ctr.S for the full
//  source-line contract).  The CTR_KIND_* ids select the per-kind rodata
//  tables (mount descriptors, env, args) in cc_ctr.S.
// ============================================================================
#ifndef CC_CTR_H
#define CC_CTR_H

// ----------------------------------------------------------------------------
// gRPC status codes the module tests (mirrors cc_grpc.h; values are the
// google.golang.org/grpc/codes wire values and the cc_grpc client's local
// error range).
// ----------------------------------------------------------------------------
#define CC_GRPC_STATUS_OK                0
#define CC_GRPC_STATUS_DEADLINE_EXCEEDED 4
#define CC_GRPC_STATUS_NOT_FOUND         5
#define CC_GRPC_ERR_TIMEOUT              (-1)   // cc_grpc local deadline expiry

// cc_ctr local error codes (mirror cc_ctr.h) — the module returns these for
// its own argument errors; C-helper results are propagated unchanged.
#define CC_CTR_ERR_BADARG  (-101)

// Signals the stop path uses (kill-then-wait, C-layer ordering):
// SIGTERM = graceful stop, SIGKILL = force-kill after the grace period.
// (SIGTERM is in cc_platform.h; SIGKILL is defined here.)
#define SIGKILL  9

// The default snapshotter name passed to every snapshot RPC.  Mirrors
// cc_ctr.h's CC_CTR_DEFAULT_SNAPSHOTTER ("overlayfs", the containerd
// default); the C header is C-only, so this module carries its own copy.
#define CC_CTR_SNAPSHOTTER_DEFAULT "overlayfs"

// ----------------------------------------------------------------------------
// struct cc_ctr_oci_spec byte offsets (offsetof, verified by probe; the
// assembly builds this struct in memory for cc_ctr_oci_spec_build).
// ----------------------------------------------------------------------------
#define CC_OCI_N_ENV          0
#define CC_OCI_ENV            8        // const char *env[CC_CTR_OCI_ENV_MAX]
#define CC_OCI_N_ARGS         520
#define CC_OCI_ARGS           528      // const char *args[CC_CTR_OCI_ARGS_MAX]
#define CC_OCI_CWD            1040
#define CC_OCI_UID            1048
#define CC_OCI_GID            1052
#define CC_OCI_N_ADD_GIDS     1056
#define CC_OCI_ADD_GIDS       1060      // uint32_t additional_gids[32]
#define CC_OCI_N_CAPS_ADD     1188
#define CC_OCI_CAPS_ADD       1192      // const char *caps_add[32]
#define CC_OCI_N_MOUNTS       1448
#define CC_OCI_MOUNTS         1456      // const struct cc_ctr_oci_mount *
#define CC_OCI_HOST_NETWORK   1464      // int
#define CC_OCI_HOSTNAME       1472
#define CC_OCI_CGROUPS_PATH   1480
#define CC_OCI_N_ANN          1488
#define CC_OCI_ANN            1496      // const char *annotations[16]
#define CC_OCI_SPEC_SIZE      1624

// struct cc_ctr_oci_mount byte offsets (96 bytes) — the records the spec's
// `mounts` pointer references (controller bind mounts, "bind" type).
#define CC_OCI_M_DESTINATION  0
#define CC_OCI_M_SOURCE       8
#define CC_OCI_M_TYPE         16
#define CC_OCI_M_N_OPTIONS    24
#define CC_OCI_M_OPTIONS      32       // const char *options[8]
#define CC_OCI_M_SIZE         96

// RODATA mount-descriptor entry size in cc_ctr.S (24 bytes):
//   +0  destination ptr, +8  options-array ptr,
//   +16 CC_LAY_* source offset (.word), +20 n_options (.word)
#define CC_OCI_MOUNT_DESC_SIZE 24

// ----------------------------------------------------------------------------
// Per-stage OCI kinds — select the rodata tables (mounts/env/args) that
// cc_ctr_oci_spec_fill uses.  One kind per stage; the four ffmpeg-image
// stages (normalize / scale-and-egress / single-stage-egress) differ only in
// the argv stage-name and the CC_ER_* config offset.
// ----------------------------------------------------------------------------
#define CTR_KIND_MEDIAMTX      0
#define CTR_KIND_NORMALIZE     1
#define CTR_KIND_SCALE_EGRESS  2
#define CTR_KIND_SINGLE_EGRESS 3
#define CTR_KIND_COUNT         4

// ctr_kind_info entry offsets (rodata, CTR_KI_STRIDE bytes per kind):
//   mounts table ptr, n_mounts, env table ptr, n_env, args table ptr, n_args
#define CTR_KI_MOUNTS   0
#define CTR_KI_N_MOUNTS 8
#define CTR_KI_ENV      16
#define CTR_KI_N_ENV    24
#define CTR_KI_ARGS     32
#define CTR_KI_N_ARGS   40
#define CTR_KI_STRIDE   48

// ----------------------------------------------------------------------------
// Module state block (ctr_state, .bss; set by cc_ctr_init).
// ----------------------------------------------------------------------------
#define CTR_STATE_LAYOUT       0      // 8   Layout ptr (mount sources + env-runtime)
#define CTR_STATE_H            8      // 4   containerd connection handle (int)
#define CTR_STATE_STOP_TIMEOUT 16     // 8   gracefulStopTimeout (u64 ns)
#define CTR_STATE_SIZE         24

// Scratch buffer partition (ctr_scratch, .bss): the cgroups path lives in
// [0,512) and the "file://" log URI in [512,1024) — they never overlap.
#define CTR_SCRATCH_SIZE     1024
#define CTR_SCRATCH_CGROUPS  0
#define CTR_SCRATCH_URI      512

// Fixed scratch sizes the module owns (all .bss).
#define CTR_OCI_JSON_CAP     4096     // OCI spec JSON output buffer
#define CTR_SPEC_MOUNTS_MAX  8        // cc_ctr_oci_mount records (6 used max)
#define CTR_PREP_MOUNTS_MAX  8        // == CC_CTR_MAX_MOUNTS (cc_ctr.h)

// The image rootfs chainID buffer (ctr_parent_buf): cc_ctr_resolve_chainid
// writes the WithNewSnapshot parent here ("sha256:" digest, 71 bytes; "" for
// a no-layer image).  Mirrors CC_CTR_PARENT_MAX in core/controller/alternate/c/
// cc_ctr.h (the C header is C-only, so this module carries its own copy).
#define CC_CTR_PARENT_MAX 256

#endif // CC_CTR_H