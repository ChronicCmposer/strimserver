// ============================================================================
// cc_ctr.S — containerd ORCHESTRATION for the strimserver controller
// ============================================================================
//
//  Target:     AArch64 (ARMv8.2-A), little-endian — Linux (ELF, static);
//              cc_platform.h is the only platform header (Linux-only).
//  Assembler:  GNU as syntax, preprocessed by the C compiler
//              (`cc -c -x assembler-with-cpp`).
//  ISA:        .arch armv8.2-a — exactly one in-source directive (below),
//              nothing higher, no .arch_extension, no .cpu (Graviton2 parity).
//
//  This module is Phase 4.4b: the OP ORCHESTRATION half of the `cc_ctr`
//  module.  The C operation layer (core/controller/alternate/c/cc_ctr.c, Phase 4.4a)
//  owns the protocol/encoding — building the containerd gRPC requests and
//  parsing the responses.  This module owns the SEQUENCES: given a stage's
//  target state, run the correct start/stop sequence by calling the C
//  helpers in the order the Go controller does.  The reconcile/state-machine
//  loop that DECIDES target states is Phase 4.5 (cc_state.S) — it calls the
//  exported functions below; it is NOT built here.
//
//  Golden contract (Gate 0 — the op sequences and OCI field sets ported from
//  the Go controller; file:line evidence):
//
//  START op (container_factory.go:212-226 `start`, :71-92 `buildContainer`,
//  :95-109 `CreateFFmpegContainer`, :111-125 `CreateMediaMTXContainer`,
//  :231-247 `CreateStageOps`):
//    1. stop() first ................................ :213
//    2. resolve the image rootfs chainID: Images/Get -> Content/Read
//       (manifest) -> Content/Read (config) -> identity.ChainID(diff_ids)
//       (the exact parent containerd's WithNewSnapshot computes,
//       client/container_opts.go:242-285; cc_ctr_resolve_chainid)
//    3. Snapshots/Prepare(key=snapshotID, parent=<image chainID>)
//       (WithNewSnapshot — a NON-EMPTY parent chains the container's active
//       snapshot onto the image's unpacked layers, so the rootfs carries
//       /entrypoint.sh)
//    4. (Go reads the image config via the Content service — the C layer
//       does NOT; the assembly supplies the OCI fields itself, deviation 1)
//    5. Containers/Create(id, image=imageName, runtime=runc-v2,
//       spec=Any(JSON), snapshotter="overlayfs", snapshot_key=snapshotID)
//       (client/client.go:340-377 NewContainer)
//    6. NewTask: Containers/Get -> Snapshots/Mounts -> Containers/Get x2 ->
//       Tasks/Create(container_id, rootfs, stdin="", stdout="file://<log>",
//       stderr="file://<log>" [, options=Any(runc Options{BinaryName:
//       nvidia-container-runtime}) for the GPU ffmpeg kinds — Option C])
//       (cc_ctr_create_task; cio.LogFile sets BOTH
//       streams to the same file:// URI, pkg/cio/io.go:276-291)
//    7. Tasks/Start ................................ :222-223
//
//  STOP op (container_factory.go:140-210 `stop`, :148-152 deleteContainer):
//    1. LoadContainer(id) = Containers/Get ....... :141; NotFound -> OK
//    2. container.Task(cio.Load) = Tasks/Get ..... :155; NotFound -> step 6
//    3. task.Kill(SIGTERM) ........................ :173 (Kill-then-Wait is
//       the C-layer ordering — cc_ctr.h note on cc_ctr_wait_task; Go starts
//       Wait in a goroutine BEFORE Kill, deviation 2)
//    4. wait for exit, bounded by gracefulStopTimeout (STAGE_STOP_TIMEOUT):
//       the assembly sets the connection unary timeout to the grace period
//       for the blocking Wait RPC (Go's time.After select branch)
//    5. exit -> Tasks/Delete ...................... :181; timeout/transport
//       -> Kill(SIGKILL) + Tasks/Delete (Go Delete(WithProcessKill), :188;
//       the ctx.Done branch :198 collapses into the same force path for the
//       single-threaded port)
//    6. container.Delete(WithSnapshotCleanup) = [Tasks/Get (must be
//       NotFound), Containers/Get, Snapshots/Remove(snapshot_key),
//       Containers/Delete] ........................ :148-152 (cc_ctr_delete_
//       container does this wire sequence internally)
//
//  OCI SPEC FIELD SET per stage (what cc_ctr_oci_spec_fill produces; the
//  struct cc_ctr_oci_spec fields the C layer's cc_ctr_oci_spec_build reads):
//
//    ALL stages (buildContainer container_factory.go:78-83):
//      host_network  = 1   (WithHostNamespace(NetworkNamespace), :80)
//      caps_add      = ["CAP_SYS_NICE"]            (:81)
//      cwd           = NULL (Go: "/" — image WorkingDir empty -> "/",
//                      pkg/oci/spec_opts.go:411-414; C NULL -> "/")
//      uid/gid       = 0   (image user empty)
//      n_add_gids    = 0   (Go runs WithAdditionalGIDs("root"), spec_opts.go
//                      :424 — reads the image /etc/group from the rootfs;
//                      image-content-dependent, NOT replicable: deviation 3)
//      hostname      = none (no WithHostname)
//      annotations   = none (GPU injection is NOT CDI: the arm64 assembly
//                      controller uses Option C — the NewTask call below
//                      carries runc/options.Options{BinaryName: nvidia-
//                      container-runtime} in the task options for the four
//                      ffmpeg-image kinds, and the NVIDIA_* env vars in the
//                      env set above drive the toolkit's injection. The Go
//                      controller's cdi.WithCDIDevices annotation path is
//                      amd64-only and CRI-inert on the raw API, so the C
//                      layer emits no CDI annotations: deviation 4.)
//      cgroups_path  = "/<ContainerdNamespace>/<container-id>" (filepath.
//                      Join("/", ns, id), pkg/oci/spec.go:209 + :158 where
//                      ns = namespaces.NamespaceRequired(ctx) = the CONFIGURED
//                      namespace, main.go:137)
//
//    MediaMTX (CreateMediaMTXContainer :111-125; image core/BUILD.bazel:
//    367-379 entrypoint ["/entrypoint.sh"], no env):
//      env           = ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:
//                       /usr/bin:/sbin:/bin"]  (defaultUnixEnv, pkg/oci/
//                      spec.go:42-44 — image env empty)
//      args          = ["/entrypoint.sh"]  (image entrypoint, no
//                      WithProcessArgs override)
//      mounts (6)    = /strimserver.env<-Env(ro),
//                      /mediamtx.yaml.template<-MediaMTXTmpl(ro),
//                      /notify.sh<-Notify(ro), /run/secrets/srt-passphrase
//                      <-SrtPass(ro), /video-files<-VideoDir(rw),
//                      /tmp<-Tmp(rw)  (:114-121)
//
//    FFmpeg stages (CreateFFmpegContainer :95-109, CreateStageOps :231-247;
//    image env core/BUILD.bazel:557-558 arm64 variant):
//      env           = ["NVIDIA_VISIBLE_DEVICES=all",
//                       "NVIDIA_DRIVER_CAPABILITIES=compute,utility,video",
//                       "LD_LIBRARY_PATH=/lib/aarch64-linux-gnu",
//                       "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:
//                       /usr/bin:/sbin:/bin"]  (the image config env,
//                      non-empty -> used as-is, spec_opts.go:400-404)
//      args          = ["/transcode.sh", "<stage-name>"]  (:105, :238;
//                      stage-name = names.go StageNormalize / StageScaleAnd
//                      Egress / StageSingleStageEgress)
//      mounts (4)    = /strimserver.env<-Env(ro), /transcode.sh<-
//                      Transcode(ro), /etc/resolv.conf<-ResolvConf(ro),
//                      /tmp<-Tmp(rw)  (:98-103)
//
//  C-layer deviations honored (from the Phase 4.4a contract):
//    1. OCI spec fields are CALLER-supplied: the assembly fills the struct
//       from the env-runtime block (CC_ER_*/CC_CC_*, cc_layout.inc), the
//       Layout mount sources (CC_LAY_*), and the fixed per-stage tables
//       below — the Go image-config reads are replaced by the fixed field
//       set above (which IS what the project's images produce).
//    2. Kill-then-Wait: cc_ctr_wait_task returns the stored exit status even
//       for an already-exited task, so Kill() then Wait() is safe and the
//       RPC set is identical to Go.
//    3. chainID: Snapshots/Prepare(parent=<image chainID>) with key = the
//       snapshotID — the parent is computed by cc_ctr_resolve_chainid
//       (Images/Get + Content/Read x2 + identity.ChainID), mirroring the Go
//       oracle's containerd.WithNewSnapshot exactly (B1: the old design-
//       around passed parent="" and produced a bare rootfs with no image
//       layers — the exec /entrypoint.sh not-found bug).
//    4. Return mapping: ops return the first failing RPC's result — >= 0 is
//       a gRPC status (0 = OK), negative is a CC_CTR_ERR_*/CC_GRPC_ERR_*
//       client error; the NotFound-continue cases mirror Go's
//       errdefs.IsNotFound handling exactly (fail-loud, no silent partial
//       success).
//
//  In-flight tracking (controller.go:287-320): the op runner sets
//  Stage.InFlightSince at op start and clears it on op ERROR; on success it
//  stays set until the containerd stage event clears it (handleStageEvent,
//  controller.go:236-248) or the reconcile loop observes convergence.
//  cc_state.S (4.5) implements planReconcile with cc_ctr_inflight_active /
//  cc_ctr_inflight_timed_out.
//
//  Exported (all .global, AAPCS64, x19-x28 preserved; <= 80 instructions):
//    cc_ctr_init(x0=layout, x1=h, x2=stop_timeout_ns)
//                        -> x0 = 0; store the module state (called once at
//                           startup before any op)
//    cc_ctr_apply(x0=stage, x1=target CC_STATE_*)
//                        -> x0 = 0 ok / op error code; the op dispatcher:
//                           ops[target] from Stage.ops, set in-flight, run
//                           the op, clear in-flight on error; NoTarget /
//                           missing op / no ops table -> no-op (0)
//    cc_ctr_ops_for(x0=stage_id)   -> x0 = the stage's ops table ptr (the
//                           fn-ptr array indexed by CC_STATE_*; 0 = bad id)
//    cc_ctr_inflight_set(x0=stage) -> x0 = 0; InFlightSince = now()
//    cc_ctr_inflight_clear(x0=stage) -> x0 = 0; InFlightSince = 0
//    cc_ctr_inflight_active(x0=stage) -> x0 = 1/0 (in flight?)
//    cc_ctr_inflight_timed_out(x0=stage, x1=timeout_ns) -> x0 = 1/0
//    cc_ctr_oci_spec_fill(x0=config, x1=CTR_KIND_*, x2=spec_out,
//                        x3=mounts_out, x4=cgroups_scratch)
//                        -> x0 = 0 / CC_CTR_ERR_BADARG; fills a caller
//                           struct cc_ctr_oci_spec (+ its mount records)
//                           for the stage — the golden field set above
//    cc_ctr_mediamtx_start(x0=stage) / cc_ctr_mediamtx_stop(x0=stage)
//    cc_ctr_normalize_start(x0=stage) / cc_ctr_normalize_stop(x0=stage)
//    cc_ctr_scale_egress_start(x0=stage) / cc_ctr_scale_egress_stop(x0=stage)
//    cc_ctr_single_egress_start(x0=stage) / cc_ctr_single_egress_stop(x0=stage)
//                        -> x0 = 0 / error code; the per-stage start/stop
//                           ops (tail calls into ctr_start/ctr_stop; the
//                           x0=stage argument is passed for signature
//                           uniformity with the dispatcher and is unused —
//                           the ops are closures over their ContainerConfig)
//
//  Module-local helpers (ctr_*, full AAPCS64 obligations):
//    ctr_start(x0=config, x1=kind)    the shared start op sequence
//    ctr_stop(x0=config)              the shared stop op sequence
//    ctr_fill_mounts(x0=mounts_out, x1=desc_table, x2=n)
//    ctr_build_cgroups(x0=config, x1=spec, x2=scratch)
//    ctr_build_uri(x0=config)         "file://"+logfile into ctr_scratch+512
//
//  AAPCS64 notes (see cc_util.S for the full rules)
//  --------------------------------------------------
//    * Callee-saved (must be preserved across any `bl`): x19-x28, x29.
//    * sp stays 16-byte aligned at every call site.
//    * Never join statements with ';' — one instruction per line.
//
// ============================================================================

#include "cc_platform.h"
#include "cc_layout.inc"
#include "cc_env.h"
#include "cc_ctr.h"
#include "cc_json.h"
    .arch armv8.2-a
    .text

// ============================================================================
// cc_ctr_init — store the module state.
//   in:  x0 = Layout ptr, x1 = containerd connection handle (int),
//        x2 = gracefulStopTimeout (u64 ns)
//   out: x0 = 0
//   The Layout ptr gives the mount sources (CC_LAY_*) and the env-runtime
//   block at Layout + CC_LAY_SIZE (CC_ER_*/CC_CC_*); the connection handle
//   is attached to every RPC; the stop timeout bounds the Wait RPC.
// ============================================================================
    .p2align 2
    .global cc_ctr_init
    FUNC_TYPE(cc_ctr_init)
cc_ctr_init:
    LEA x3, ctr_state
    str x0, [x3, #CTR_STATE_LAYOUT]
    str w1, [x3, #CTR_STATE_H]
    str x2, [x3, #CTR_STATE_STOP_TIMEOUT]
    mov x0, #0
    ret

// ============================================================================
// cc_ctr_ops_for — the Stage.ops table for a stage id.
//   in:  x0 = CC_STAGE_* id
//   out: x0 = ptr to the two-fn-ptr ops table (indexed by CC_STATE_*), or 0
// ============================================================================
    .p2align 2
    .global cc_ctr_ops_for
    FUNC_TYPE(cc_ctr_ops_for)
cc_ctr_ops_for:
    cmp x0, #CC_STAGE_COUNT
    b.hs .Lof_bad
    LEA x1, ctr_ops_table
    ldr x0, [x1, x0, lsl #3]
    ret
.Lof_bad:
    mov x0, #0
    ret

// ============================================================================
// cc_ctr_inflight_set — mark a stage in flight.
//   in:  x0 = Stage ptr
//   out: x0 = 0
//   Writes clock_gettime(CLOCK_MONOTONIC) into Stage.inflightSince (the
//   timespec the layout declares; Go uses the injectable time.Now — the
//   assembly reads the monotonic clock directly, a documented deviation).
// ============================================================================
    .p2align 2
    .global cc_ctr_inflight_set
    FUNC_TYPE(cc_ctr_inflight_set)
cc_ctr_inflight_set:
    stp x19, x30, [sp, #-16]!       // x19 = stage across the clock_gettime bl
    mov x19, x0
    sub sp, sp, #16                 // struct timespec
    mov x0, #CLOCK_MONOTONIC
    mov x1, sp
    bl clock_gettime
    ldr x2, [sp]                    // tv_sec
    ldr x3, [sp, #8]                // tv_nsec
    add sp, sp, #16
    str x2, [x19, #CC_STG_INFLIGHT_SINCE]
    str x3, [x19, #CC_STG_INFLIGHT_SINCE + 8]
    mov x0, #0
    ldp x19, x30, [sp], #16
    ret

// ============================================================================
// cc_ctr_inflight_clear — mark a stage not in flight.
// ============================================================================
    .p2align 2
    .global cc_ctr_inflight_clear
    FUNC_TYPE(cc_ctr_inflight_clear)
cc_ctr_inflight_clear:
    str xzr, [x0, #CC_STG_INFLIGHT_SINCE]
    str xzr, [x0, #CC_STG_INFLIGHT_SINCE + 8]
    mov x0, #0
    ret

// ============================================================================
// cc_ctr_inflight_active — is the stage currently in flight?
//   out: x0 = 1 when inflightSince != 0, else 0
// ============================================================================
    .p2align 2
    .global cc_ctr_inflight_active
    FUNC_TYPE(cc_ctr_inflight_active)
cc_ctr_inflight_active:
    ldr x1, [x0, #CC_STG_INFLIGHT_SINCE]
    ldr x2, [x0, #CC_STG_INFLIGHT_SINCE + 8]
    orr x1, x1, x2
    cmp x1, #0
    cset x0, ne
    ret

// ============================================================================
// cc_ctr_inflight_timed_out — has the in-flight op exceeded its budget?
//   in:  x0 = Stage ptr, x1 = timeout (u64 ns)
//   out: x0 = 1 when in flight AND now - inflightSince >= timeout, else 0
//   Port of planReconcile's timeout test (controller.go:316-320).
// ============================================================================
    .p2align 2
    .global cc_ctr_inflight_timed_out
    FUNC_TYPE(cc_ctr_inflight_timed_out)
cc_ctr_inflight_timed_out:
    PROLOGUE 2                      // x19 = stage, x20 = timeout
    mov x19, x0
    mov x20, x1
    ldr x21, [x19, #CC_STG_INFLIGHT_SINCE]
    ldr x22, [x19, #CC_STG_INFLIGHT_SINCE + 8]
    orr x0, x21, x22                // in flight when sec OR nsec != 0
    cbz x0, .Lit_no
    sub sp, sp, #16                 // struct timespec
    mov x0, #CLOCK_MONOTONIC
    mov x1, sp
    bl clock_gettime
    ldr x2, [sp]                    // now.sec
    ldr x3, [sp, #8]                // now.nsec
    add sp, sp, #16
    sub x4, x2, x21                 // sec delta
    subs x5, x3, x22                // nsec delta
    b.hs .Lit_nb
    sub x4, x4, #1                  // borrow a second
    MOV_NANOSEC x6
    add x5, x5, x6
.Lit_nb:
    MOV_NANOSEC x6
    mul x7, x4, x6                  // sec delta in ns
    add x7, x7, x5                  // total elapsed ns
    cmp x7, x20
    b.hs .Lit_yes
.Lit_no:
    mov x0, #0
    b .Lit_ret
.Lit_yes:
    mov x0, #1
.Lit_ret:
    EPILOGUE 2
    ret

// ============================================================================
// cc_ctr_oci_spec_fill — build a struct cc_ctr_oci_spec for a stage.
//   in:  x0 = config ptr (env-runtime + CC_ER_* stage ContainerConfig),
//        x1 = CTR_KIND_*,
//        x2 = out struct cc_ctr_oci_spec (CC_OCI_SPEC_SIZE bytes, 8-aligned),
//        x3 = out cc_ctr_oci_mount array (CTR_SPEC_MOUNTS_MAX records),
//        x4 = cgroups-path scratch (>= 256 bytes)
//   out: x0 = 0 / CC_CTR_ERR_BADARG
//   Produces the golden OCI field set (see the module header): env/args from
//   the per-kind rodata tables, caps_add = CAP_SYS_NICE, host_network = 1,
//   cwd/hostname/uid/gid/additional-gids/annotations zeroed, the bind mounts
//   resolved against the Layout (ctr_state), and cgroups_path = "/" + ns +
//   "/" + container-id built into the scratch.  Every field the C builder
//   reads is set explicitly (the counts gate how many array entries it
//   reads, so the unset tails are never touched).
// ============================================================================
    .p2align 2
    .global cc_ctr_oci_spec_fill
    FUNC_TYPE(cc_ctr_oci_spec_fill)
cc_ctr_oci_spec_fill:
    PROLOGUE 5                      // x19=config x20=kind x21=spec
    mov x19, x0                     //   x22=mounts x23=scratch
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x23, x4
    cmp x20, #CTR_KIND_COUNT
    b.hs .Lfill_bad
    LEA x24, ctr_kind_info
    add x24, x24, x20, lsl #4       // kind * 16
    add x24, x24, x20, lsl #5       // kind * 48 (CTR_KI_STRIDE)
    // zero the fixed scalar fields the builder reads (the array tails past
    // the n_* counts are never read, so a full memset is unnecessary)
    str xzr, [x21, #CC_OCI_CWD]
    str xzr, [x21, #CC_OCI_HOSTNAME]
    str wzr, [x21, #CC_OCI_UID]
    str wzr, [x21, #CC_OCI_GID]
    str wzr, [x21, #CC_OCI_N_ADD_GIDS]
    str wzr, [x21, #CC_OCI_N_ANN]
    // env (per-kind table)
    ldr x25, [x24, #CTR_KI_ENV]
    ldr x26, [x24, #CTR_KI_N_ENV]
    str w26, [x21, #CC_OCI_N_ENV]
    cbz x26, .Lfill_args
    add x27, x21, #CC_OCI_ENV
.Lfill_env:
    ldr x28, [x25], #8
    str x28, [x27], #8
    subs x26, x26, #1
    b.ne .Lfill_env
    // args (per-kind table)
.Lfill_args:
    ldr x25, [x24, #CTR_KI_ARGS]
    ldr x26, [x24, #CTR_KI_N_ARGS]
    str w26, [x21, #CC_OCI_N_ARGS]
    cbz x26, .Lfill_caps
    add x27, x21, #CC_OCI_ARGS
.Lfill_arg:
    ldr x28, [x25], #8
    str x28, [x27], #8
    subs x26, x26, #1
    b.ne .Lfill_arg
    // caps_add = [CAP_SYS_NICE], host_network = 1
.Lfill_caps:
    mov x25, #1
    str w25, [x21, #CC_OCI_N_CAPS_ADD]
    LEA x25, ctr_s_cap_sys_nice
    str x25, [x21, #CC_OCI_CAPS_ADD]
    mov x25, #1
    str w25, [x21, #CC_OCI_HOST_NETWORK]
    // mounts: wire the per-kind descriptor table into the out records
    ldr x25, [x24, #CTR_KI_MOUNTS]
    ldr x26, [x24, #CTR_KI_N_MOUNTS]
    str w26, [x21, #CC_OCI_N_MOUNTS]
    str x22, [x21, #CC_OCI_MOUNTS]
    mov x0, x22
    mov x1, x25
    mov x2, x26
    bl ctr_fill_mounts
    // cgroups path = "/" + ns + "/" + container-id
    mov x0, x19
    mov x1, x21
    mov x2, x23
    bl ctr_build_cgroups
    mov x0, #0
    b .Lfill_ret
.Lfill_bad:
    mov x0, #CC_CTR_ERR_BADARG
.Lfill_ret:
    EPILOGUE 5
    ret

// ============================================================================
// cc_ctr_apply — the op dispatcher.
//   in:  x0 = Stage ptr, x1 = target CC_STATE_*
//   out: x0 = 0 (ok or no-op) / the op's error code
//   Port of the Controller dispatch (controller.go:298-312): NoTarget (any
//   id >= CC_STATE_COUNT) and a missing ops table / missing op are no-ops;
//   otherwise set in-flight, run ops[target] (via blr), and clear in-flight
//   on error.  On success in-flight stays set until the stage event clears
//   it (handleStageEvent, controller.go:245) — matching Go, where the op
//   goroutine only clears on failure.
// ============================================================================
    .p2align 2
    .global cc_ctr_apply
    FUNC_TYPE(cc_ctr_apply)
cc_ctr_apply:
    PROLOGUE 3                      // x19=stage, x20=op fn, x21=result
    mov x19, x0
    cmp x1, #CC_STATE_COUNT
    b.hs .Lap_noop                  // NoTarget / bad id -> no-op
    ldr x2, [x19, #CC_STG_OPS]
    cbz x2, .Lap_noop
    ldr x20, [x2, x1, lsl #3]       // ops[target]
    cbz x20, .Lap_noop
    mov x0, x19
    bl cc_ctr_inflight_set
    mov x0, x19
    blr x20                         // run the op (indirect call; x30 saved
    mov x21, x0                     //   by PROLOGUE, restored by EPILOGUE)
    cbz x21, .Lap_ok
    mov x0, x19
    bl cc_ctr_inflight_clear
.Lap_ok:
    mov x0, x21
    EPILOGUE 3
    ret
.Lap_noop:
    mov x0, #0
    EPILOGUE 3
    ret

// ============================================================================
// Per-stage op wrappers — each is a tail call into the shared start/stop
// helpers with its ContainerConfig (env-runtime + CC_ER_* offset) and kind.
// The x0=stage argument the dispatcher passes is intentionally unused (the
// ops are closures over their config, exactly like the Go closures).
// ============================================================================
    .p2align 2
    .global cc_ctr_mediamtx_start
    FUNC_TYPE(cc_ctr_mediamtx_start)
cc_ctr_mediamtx_start:
    LEA x0, ctr_state
    ldr x0, [x0, #CTR_STATE_LAYOUT]
    add x0, x0, #CC_LAY_SIZE
    add x0, x0, #CC_ER_MEDIAMTX
    mov x1, #CTR_KIND_MEDIAMTX
    b ctr_start

    .p2align 2
    .global cc_ctr_mediamtx_stop
    FUNC_TYPE(cc_ctr_mediamtx_stop)
cc_ctr_mediamtx_stop:
    LEA x0, ctr_state
    ldr x0, [x0, #CTR_STATE_LAYOUT]
    add x0, x0, #CC_LAY_SIZE
    add x0, x0, #CC_ER_MEDIAMTX
    b ctr_stop

    .p2align 2
    .global cc_ctr_normalize_start
    FUNC_TYPE(cc_ctr_normalize_start)
cc_ctr_normalize_start:
    LEA x0, ctr_state
    ldr x0, [x0, #CTR_STATE_LAYOUT]
    add x0, x0, #CC_LAY_SIZE
    add x0, x0, #CC_ER_NORMALIZE
    mov x1, #CTR_KIND_NORMALIZE
    b ctr_start

    .p2align 2
    .global cc_ctr_normalize_stop
    FUNC_TYPE(cc_ctr_normalize_stop)
cc_ctr_normalize_stop:
    LEA x0, ctr_state
    ldr x0, [x0, #CTR_STATE_LAYOUT]
    add x0, x0, #CC_LAY_SIZE
    add x0, x0, #CC_ER_NORMALIZE
    b ctr_stop

    .p2align 2
    .global cc_ctr_scale_egress_start
    FUNC_TYPE(cc_ctr_scale_egress_start)
cc_ctr_scale_egress_start:
    LEA x0, ctr_state
    ldr x0, [x0, #CTR_STATE_LAYOUT]
    add x0, x0, #CC_LAY_SIZE
    add x0, x0, #CC_ER_SCALE_AND_EGRESS
    mov x1, #CTR_KIND_SCALE_EGRESS
    b ctr_start

    .p2align 2
    .global cc_ctr_scale_egress_stop
    FUNC_TYPE(cc_ctr_scale_egress_stop)
cc_ctr_scale_egress_stop:
    LEA x0, ctr_state
    ldr x0, [x0, #CTR_STATE_LAYOUT]
    add x0, x0, #CC_LAY_SIZE
    add x0, x0, #CC_ER_SCALE_AND_EGRESS
    b ctr_stop

    .p2align 2
    .global cc_ctr_single_egress_start
    FUNC_TYPE(cc_ctr_single_egress_start)
cc_ctr_single_egress_start:
    LEA x0, ctr_state
    ldr x0, [x0, #CTR_STATE_LAYOUT]
    add x0, x0, #CC_LAY_SIZE
    add x0, x0, #CC_ER_SINGLE_STAGE_EGRESS
    mov x1, #CTR_KIND_SINGLE_EGRESS
    b ctr_start

    .p2align 2
    .global cc_ctr_single_egress_stop
    FUNC_TYPE(cc_ctr_single_egress_stop)
cc_ctr_single_egress_stop:
    LEA x0, ctr_state
    ldr x0, [x0, #CTR_STATE_LAYOUT]
    add x0, x0, #CC_LAY_SIZE
    add x0, x0, #CC_ER_SINGLE_STAGE_EGRESS
    b ctr_stop

// ============================================================================
// ctr_fill_mounts — resolve a mount-descriptor table into cc_ctr_oci_mount
//   records.
//   in:  x0 = out cc_ctr_oci_mount array, x1 = desc table (CC_OCI_MOUNT_DESC
//        SIZE entries: dest ptr, opts ptr, CC_LAY_* offset, n_options),
//        x2 = n_mounts
//   out: x0 = 0
//   The source of each record is Layout[layout_off] (from ctr_state); the
//   type is always "bind"; the options are the descriptor's option-string
//   ptrs copied into the record.
// ============================================================================
    .p2align 2
ctr_fill_mounts:
    cbz x2, .Lfm_ret
    LEA x3, ctr_state
    ldr x3, [x3, #CTR_STATE_LAYOUT]
    mov x4, #0                      // i
.Lfm_loop:
    add x5, x1, x4, lsl #4          // desc + 16*i
    add x5, x5, x4, lsl #3          // desc + 24*i
    add x6, x0, x4, lsl #5          // rec + 32*i
    add x6, x6, x4, lsl #6          // rec + 96*i
    ldr x7, [x5]                    // destination
    str x7, [x6, #CC_OCI_M_DESTINATION]
    ldr w7, [x5, #16]               // layout offset
    ldr x7, [x3, x7]                // source = Layout[off]
    str x7, [x6, #CC_OCI_M_SOURCE]
    LEA x7, ctr_s_mount_type
    str x7, [x6, #CC_OCI_M_TYPE]
    ldr w7, [x5, #20]               // n_options
    str w7, [x6, #CC_OCI_M_N_OPTIONS]
    ldr x8, [x5, #8]                // option-string ptr array
    cbz w7, .Lfm_next
    mov x9, #0                      // j
    add x10, x6, #CC_OCI_M_OPTIONS
.Lfm_opt:
    ldr x11, [x8, x9, lsl #3]
    str x11, [x10, x9, lsl #3]
    add x9, x9, #1
    cmp w9, w7
    b.lo .Lfm_opt
.Lfm_next:
    add x4, x4, #1
    cmp x4, x2
    b.lo .Lfm_loop
.Lfm_ret:
    mov x0, #0
    ret

// ============================================================================
// ctr_build_cgroups — build the spec's linux.cgroupsPath.
//   in:  x0 = config ptr, x1 = struct cc_ctr_oci_spec, x2 = scratch
//   out: x0 = 0; spec->cgroups_path = scratch, which now holds
//        "/" + ContainerdNamespace + "/" + container-id
//        (filepath.Join("/", ns, id), pkg/oci/spec.go:209).
// ============================================================================
    .p2align 2
ctr_build_cgroups:
    PROLOGUE 2                      // x19=config, x20=spec, x21=scratch
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x3, #'/'
    strb w3, [x21]
    add x0, x21, #1
    LEA x4, ctr_state
    ldr x4, [x4, #CTR_STATE_LAYOUT]
    add x4, x4, #CC_LAY_SIZE
    ldr x1, [x4, #CC_ER_CONTAINERD_NAMESPACE]
    bl cc_cat_cstr                  // x0 = NUL position
    mov x3, #'/'
    strb w3, [x0]
    add x0, x0, #1
    ldr x1, [x19, #CC_CC_CONTAINER_ID]
    bl cc_cat_cstr
    str x21, [x20, #CC_OCI_CGROUPS_PATH]
    mov x0, #0
    EPILOGUE 2
    ret

// ============================================================================
// ctr_build_uri — build the task IO URI "file://" + logfile.
//   in:  x0 = config ptr
//   out: x0 = 0; ctr_scratch + CTR_SCRATCH_URI holds the URI (both stdout
//        and stderr use it, cio.LogFile pkg/cio/io.go:276-291).
// ============================================================================
    .p2align 2
ctr_build_uri:
    PROLOGUE 1                      // x19 = config
    mov x19, x0
    LEA x0, ctr_scratch
    add x0, x0, #CTR_SCRATCH_URI
    LEA x1, ctr_s_file_uri
    bl cc_cat_cstr                  // x0 = NUL position
    ldr x1, [x19, #CC_CC_LOGFILE]
    bl cc_cat_cstr
    mov x0, #0
    EPILOGUE 1
    ret

// ============================================================================
// ctr_start — the shared start op (port of container_factory.go:212-226).
//   in:  x0 = config ptr, x1 = CTR_KIND_*
//   out: x0 = 0 / the first failing RPC's result (>= 0 gRPC status, < 0
//        client error)
// ============================================================================
    .p2align 2
ctr_start:
    PROLOGUE 3                      // x19=config, x20=kind, x21=h, x22=len
    mov x19, x0
    mov x20, x1
    // 1. stop() first — cleanup before (re)create (Go :213)
    bl ctr_stop
    cbnz x0, .Lst_ret
    // 2-3a. Resolve the image rootfs chainID: Images/Get + Content/Read
    // (manifest + config blobs) + identity.ChainID(rootfs.diff_ids) — the
    // exact parent containerd's WithNewSnapshot computes and passes to
    // Snapshots/Prepare (client/container_opts.go:242-285 withNewSnapshot;
    // i.RootFS walks the manifest/config through the Content service). The
    // chainID lands in ctr_parent_buf ("" for a no-layer image).
    LEA x21, ctr_state
    ldr w21, [x21, #CTR_STATE_H]
    mov x0, x21
    ldr x1, [x19, #CC_CC_IMAGE_NAME]
    LEA x2, ctr_parent_buf
    mov x3, #CC_CTR_PARENT_MAX
    bl cc_ctr_resolve_chainid
    cbnz x0, .Lst_ret
    // 3b. Snapshots/Prepare(key=snapshotID, parent=<image chainID>)
    // (Go WithNewSnapshot -> Snapshots/Prepare; a NON-EMPTY parent chains
    // the container's active snapshot onto the image's unpacked layers, so
    // the rootfs carries /entrypoint.sh)
    mov x0, x21
    LEA x1, ctr_s_overlayfs
    ldr x2, [x19, #CC_CC_SNAPSHOT_ID]
    LEA x3, ctr_parent_buf
    LEA x4, ctr_prep_mounts
    mov x5, #CTR_PREP_MOUNTS_MAX
    LEA x6, ctr_n_mounts
    bl cc_ctr_prepare_snapshot
    cbnz x0, .Lst_ret
    // 4. assemble the OCI spec struct (deviation 1: caller-supplied fields)
    mov x0, x19
    mov x1, x20
    LEA x2, ctr_spec_buf
    LEA x3, ctr_spec_mounts
    LEA x4, ctr_scratch
    bl cc_ctr_oci_spec_fill
    cbnz x0, .Lst_ret
    // 5. build the spec JSON
    LEA x0, ctr_spec_buf
    LEA x1, ctr_json_buf
    mov x2, #CTR_OCI_JSON_CAP
    bl cc_ctr_oci_spec_build
    cmp x0, #0
    b.lt .Lst_ret                   // negative = CC_CTR_ERR_* (build failed)
    mov x22, x0                     // json length
    // 6. Containers/Create (Go NewContainer client.go:340-377)
    mov x0, x21
    ldr x1, [x19, #CC_CC_CONTAINER_ID]
    ldr x2, [x19, #CC_CC_IMAGE_NAME]
    LEA x3, ctr_s_overlayfs
    ldr x4, [x19, #CC_CC_SNAPSHOT_ID]
    mov x5, #0                      // runtime NULL -> io.containerd.runc.v2
    LEA x6, ctr_json_buf
    mov x7, x22
    bl cc_ctr_create_container
    cbnz x0, .Lst_ret
    // 7. NewTask with cio.LogFile(logfile) (Go :130, :219)
    mov x0, x19
    bl ctr_build_uri
    mov x0, x21
    ldr x1, [x19, #CC_CC_CONTAINER_ID]
    LEA x2, ctr_scratch
    add x2, x2, #CTR_SCRATCH_URI
    mov x3, x2                      // stderr = the same file URI
    mov x4, #0                      // out_pid NULL
    // Option C (per-container NVIDIA runtime): the ffmpeg-image stages carry
    // the NVIDIA_* env vars and need NVENC, so their task options point the
    // runc shim at nvidia-container-runtime (it injects the GPU from
    // NVIDIA_VISIBLE_DEVICES then execs plain runc). MediaMTX is non-GPU:
    // options absent -> plain runc, byte-identical to the pre-Option-C wire.
    mov x5, #0
    cmp x20, #CTR_KIND_MEDIAMTX
    b.eq .Lst_nt_runtime
    LEA x5, ctr_s_nvidia_runtime
.Lst_nt_runtime:
    bl cc_ctr_create_task
    cbnz x0, .Lst_ret
    // 8. Tasks/Start (Go :222)
    mov x0, x21
    ldr x1, [x19, #CC_CC_CONTAINER_ID]
    mov x2, #0
    bl cc_ctr_start_task
.Lst_ret:
    EPILOGUE 3
    ret

// ============================================================================
// ctr_stop — the shared stop op (port of container_factory.go:140-210).
//   in:  x0 = config ptr
//   out: x0 = 0 / the first failing RPC's result
// ============================================================================
    .p2align 2
ctr_stop:
    PROLOGUE 2                      // x19=config, x20=h
    mov x19, x0
    LEA x20, ctr_state
    ldr w20, [x20, #CTR_STATE_H]
    // 1. LoadContainer(id) (Go :141); NotFound -> already gone, OK
    mov x0, x20
    ldr x1, [x19, #CC_CC_CONTAINER_ID]
    mov x2, #0
    mov x3, #0
    mov x4, #0
    mov x5, #0
    bl cc_ctr_get_container
    cmp x0, #CC_GRPC_STATUS_NOT_FOUND
    b.eq .Lsp_done
    cbnz x0, .Lsp_ret
    // 2. container.Task(cio.Load) (Go :155); NotFound -> delete container
    mov x0, x20
    ldr x1, [x19, #CC_CC_CONTAINER_ID]
    mov x2, #0
    bl cc_ctr_get_task
    cmp x0, #CC_GRPC_STATUS_NOT_FOUND
    b.eq .Lsp_delete_container
    cbnz x0, .Lsp_ret
    // 3. Kill(SIGTERM) — Kill-then-Wait, the C-layer ordering (deviation 2)
    mov x0, x20
    ldr x1, [x19, #CC_CC_CONTAINER_ID]
    mov x2, #SIGTERM
    bl cc_ctr_kill_task
    cmp x0, #CC_GRPC_STATUS_NOT_FOUND
    b.eq .Lsp_wait                  // already gone: Wait returns NotFound
    cbnz x0, .Lsp_ret
    // 4. Wait bounded by gracefulStopTimeout (Go :177-186 select timeout)
.Lsp_wait:
    mov x0, x20
    LEA x1, ctr_state
    ldr x1, [x1, #CTR_STATE_STOP_TIMEOUT]
    bl cc_grpc_set_unary_timeout
    mov x0, x20
    ldr x1, [x19, #CC_CC_CONTAINER_ID]
    mov x2, #0                      // out_exit_status NULL
    bl cc_ctr_wait_task
    mov x21, x0                     // save the wait result (x21 is
    //                                callee-saved across the restore call)
    // restore the connection's default unary timeout
    mov x0, x20
    mov x1, #0
    bl cc_grpc_set_unary_timeout
    cmp x21, #CC_GRPC_STATUS_OK
    b.eq .Lsp_delete_task           // graceful exit -> Tasks/Delete
    cmp x21, #CC_GRPC_STATUS_NOT_FOUND
    b.eq .Lsp_delete_container      // task already gone
    // 5. force: Kill(SIGKILL) + Tasks/Delete (Go Delete(WithProcessKill) :188)
    mov x0, x20
    ldr x1, [x19, #CC_CC_CONTAINER_ID]
    mov x2, #SIGKILL
    bl cc_ctr_kill_task
    cbnz x0, .Lsp_ret
    // fall through to delete the task
.Lsp_delete_task:
    mov x0, x20
    ldr x1, [x19, #CC_CC_CONTAINER_ID]
    mov x2, #0
    bl cc_ctr_delete_task
    cmp x0, #CC_GRPC_STATUS_NOT_FOUND
    b.eq .Lsp_delete_container
    cbnz x0, .Lsp_ret
    // 6. container.Delete(WithSnapshotCleanup) (Go :148-152)
.Lsp_delete_container:
    mov x0, x20
    ldr x1, [x19, #CC_CC_CONTAINER_ID]
    bl cc_ctr_delete_container
.Lsp_ret:
    EPILOGUE 2
    ret
.Lsp_done:
    mov x0, #0
    EPILOGUE 2
    ret

// ============================================================================
// RODATA — the fixed strings and per-kind tables (single source of truth for
// the golden OCI field set).  Lengths derive from the .asciz strings; the
// mount destinations reuse the CC_CTR_* macros from cc_layout.inc.
// ============================================================================
    RODATA

// ---- container-internal mount destinations (cc_layout.inc CC_CTR_*) ----
ctr_s_ctr_env:
    .asciz CC_CTR_ENV
ctr_s_ctr_transcode:
    .asciz CC_CTR_TRANSCODE
ctr_s_ctr_notify:
    .asciz CC_CTR_NOTIFY
ctr_s_ctr_mediamtx_tmpl:
    .asciz CC_CTR_MEDIAMTX_TMPL
ctr_s_ctr_srt_secret:
    .asciz CC_CTR_SRT_SECRET
ctr_s_ctr_video_dir:
    .asciz CC_CTR_VIDEO_DIR
ctr_s_ctr_resolv_conf:
    .asciz CC_CTR_RESOLV_CONF
ctr_s_ctr_tmp:
    .asciz CC_CTR_TMP

// ---- mount type / options ----
ctr_s_mount_type:
    .asciz "bind"
ctr_s_rbind:
    .asciz "rbind"
ctr_s_ro:
    .asciz "ro"
ctr_s_rw:
    .asciz "rw"

// ---- process fields ----
ctr_s_cap_sys_nice:
    .asciz "CAP_SYS_NICE"
ctr_s_entrypoint_arg:
    .asciz "/entrypoint.sh"         // mediamtx image entrypoint (core/BUILD.bazel:373)
ctr_s_transcode_arg:
    .asciz "/transcode.sh"          // container_factory.go:238 ctrTranscode
ctr_s_stage_normalize:
    .asciz JSON_S_NORMALIZE         // names.go StageNormalize
ctr_s_stage_scale:
    .asciz JSON_S_SCALE_AND_EGRESS
ctr_s_stage_single:
    .asciz JSON_S_SINGLE_STAGE_EGRESS
ctr_s_path:
    .asciz "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ctr_s_nvidia_visible:
    .asciz "NVIDIA_VISIBLE_DEVICES=all"
ctr_s_nvidia_caps:
    .asciz "NVIDIA_DRIVER_CAPABILITIES=compute,utility,video"
ctr_s_ld_library_path:
    .asciz "LD_LIBRARY_PATH=/lib/aarch64-linux-gnu"   // arm64 build (core/BUILD.bazel:558)

// ---- Option C: the runtime binary the runc shim execs for GPU stages ----
ctr_s_nvidia_runtime:
    .asciz "/usr/bin/nvidia-container-runtime"

// ---- snapshotter / IO ----
ctr_s_overlayfs:
    .asciz CC_CTR_SNAPSHOTTER_DEFAULT
ctr_s_file_uri:
    .asciz "file://"
ctr_s_empty:
    .asciz ""

// ---- mount option arrays ----
ctr_mount_opts_ro:
    .quad ctr_s_rbind
    .quad ctr_s_ro
ctr_mount_opts_rw:
    .quad ctr_s_rbind
    .quad ctr_s_rw

// ---- env / args tables (per kind) ----
ctr_env_mediamtx:
    .quad ctr_s_path                // defaultUnixEnv (spec.go:42-44)
ctr_env_ffmpeg:
    .quad ctr_s_nvidia_visible
    .quad ctr_s_nvidia_caps
    .quad ctr_s_ld_library_path
    .quad ctr_s_path
ctr_args_mediamtx:
    .quad ctr_s_entrypoint_arg
ctr_args_normalize:
    .quad ctr_s_transcode_arg
    .quad ctr_s_stage_normalize
ctr_args_scale:
    .quad ctr_s_transcode_arg
    .quad ctr_s_stage_scale
ctr_args_single:
    .quad ctr_s_transcode_arg
    .quad ctr_s_stage_single

// ---- mount descriptor tables (CC_OCI_MOUNT_DESC_SIZE entries) ----
    .macro CTR_MOUNT_DESC dest, layout_off, opts_ptr, n_opts
    .quad \dest
    .quad \opts_ptr
    .word \layout_off
    .word \n_opts
    .endm
ctr_mounts_mediamtx:
    CTR_MOUNT_DESC ctr_s_ctr_env, CC_LAY_ENV, ctr_mount_opts_ro, 2
    CTR_MOUNT_DESC ctr_s_ctr_mediamtx_tmpl, CC_LAY_MEDIAMTX_TMPL, ctr_mount_opts_ro, 2
    CTR_MOUNT_DESC ctr_s_ctr_notify, CC_LAY_NOTIFY, ctr_mount_opts_ro, 2
    CTR_MOUNT_DESC ctr_s_ctr_srt_secret, CC_LAY_SRT_PASS, ctr_mount_opts_ro, 2
    CTR_MOUNT_DESC ctr_s_ctr_video_dir, CC_LAY_VIDEO_DIR, ctr_mount_opts_rw, 2
    CTR_MOUNT_DESC ctr_s_ctr_tmp, CC_LAY_TMP, ctr_mount_opts_rw, 2
ctr_mounts_ffmpeg:
    CTR_MOUNT_DESC ctr_s_ctr_env, CC_LAY_ENV, ctr_mount_opts_ro, 2
    CTR_MOUNT_DESC ctr_s_ctr_transcode, CC_LAY_TRANSCODE, ctr_mount_opts_ro, 2
    CTR_MOUNT_DESC ctr_s_ctr_resolv_conf, CC_LAY_RESOLV_CONF, ctr_mount_opts_ro, 2
    CTR_MOUNT_DESC ctr_s_ctr_tmp, CC_LAY_TMP, ctr_mount_opts_rw, 2

// ---- per-kind info (CTR_KI_STRIDE bytes; indexed by CTR_KIND_*) ----
ctr_kind_info:
    .quad ctr_mounts_mediamtx
    .quad 6
    .quad ctr_env_mediamtx
    .quad 1
    .quad ctr_args_mediamtx
    .quad 1
    .quad ctr_mounts_ffmpeg
    .quad 4
    .quad ctr_env_ffmpeg
    .quad 4
    .quad ctr_args_normalize
    .quad 2
    .quad ctr_mounts_ffmpeg
    .quad 4
    .quad ctr_env_ffmpeg
    .quad 4
    .quad ctr_args_scale
    .quad 2
    .quad ctr_mounts_ffmpeg
    .quad 4
    .quad ctr_env_ffmpeg
    .quad 4
    .quad ctr_args_single
    .quad 2

// ---- Stage.ops tables (fn ptr per CC_STATE_* index) ----
ctr_ops_mediamtx:
    .quad cc_ctr_mediamtx_start      // CC_STATE_RUNNING
    .quad cc_ctr_mediamtx_stop       // CC_STATE_STOPPED
ctr_ops_normalize:
    .quad cc_ctr_normalize_start
    .quad cc_ctr_normalize_stop
ctr_ops_scale:
    .quad cc_ctr_scale_egress_start
    .quad cc_ctr_scale_egress_stop
ctr_ops_single:
    .quad cc_ctr_single_egress_start
    .quad cc_ctr_single_egress_stop

// stage id -> ops table (cc_ctr_ops_for)
ctr_ops_table:
    .quad ctr_ops_mediamtx           // CC_STAGE_MEDIAMTX
    .quad ctr_ops_normalize          // CC_STAGE_NORMALIZE
    .quad ctr_ops_scale              // CC_STAGE_SCALE_AND_EGRESS
    .quad ctr_ops_single             // CC_STAGE_SINGLE_STAGE_EGRESS

// ============================================================================
// BSS — module state and op scratch (single-threaded controller; the C layer
// is single-threaded per connection, so one scratch set is safe).
// ============================================================================
    .bss
    .p2align 3
ctr_state:
    .space CTR_STATE_SIZE
ctr_spec_buf:
    .space CC_OCI_SPEC_SIZE          // struct cc_ctr_oci_spec
ctr_spec_mounts:
    .space CC_OCI_M_SIZE * CTR_SPEC_MOUNTS_MAX   // cc_ctr_oci_mount records
ctr_scratch:
    .space CTR_SCRATCH_SIZE          // cgroups path + file:// URI
ctr_json_buf:
    .space CTR_OCI_JSON_CAP          // OCI spec JSON output
ctr_parent_buf:
    .space CC_CTR_PARENT_MAX         // image rootfs chainID (resolve_chainid out)
ctr_prep_mounts:
    .space 3140 * CTR_PREP_MOUNTS_MAX   // cc_ctr_mount records (prepare out)
ctr_n_mounts:
    .space 4                         // uint32_t out_n_mounts (prepare)

    .end