// ============================================================================
// cc_ctr.S — containerd ORCHESTRATION for the strimserver controller
// (x86-64 port)
// ============================================================================
//
//  Target:     x86-64 (SysV AMD64), little-endian — Linux (ELF, static);
//              cc_platform_x86_64.h is the only platform header (Linux-only).
//  Assembler:  GNU as AT&T syntax, preprocessed by the C compiler
//              (`cc -c -x assembler-with-cpp`).
//  ISA:        floor x86-64-v4, cap AVX2 (no zmm/k/AMX, no AVX-512);
//              target g4dn.xlarge.  There is no in-source .arch directive on
//              x86 GAS (that is an ARM concept); the floor/cap are enforced
//              by the BUILD copts and by check-isa-x86_64.sh scanning the
//              disassembly.
//
//  This module is Phase 4.4b: the OP ORCHESTRATION half of the `cc_ctr`
//  module — the x86-64 translation of the AArch64 cc_ctr.S.  The C
//  operation layer (core/controller/c/cc_ctr.c, Phase 4.4a) owns the
//  protocol/encoding; this module owns the SEQUENCES: given a stage's
//  target state, run the correct start/stop sequence by calling the C
//  helpers in the order the Go controller does.  The reconcile loop that
//  DECIDES target states is cc_state.S — it calls the exported functions
//  below; it is NOT built here.
//
//  Golden contract (Gate 0 — the op sequences and OCI field sets ported from
//  the Go controller; the full file:line evidence is in the AArch64 source):
//
//  START op:
//    1. stop() first
//    2. GetImage(imageName)
//    3. Snapshots/Prepare(key=snapshotID, parent="")
//    4. (C layer supplies the OCI fields; the assembly fills the struct)
//    5. Containers/Create(id, image, runtime=runc-v2, spec=Any(JSON),
//       snapshotter="overlayfs", snapshot_key=snapshotID)
//    6. NewTask: Containers/Get -> Snapshots/Mounts -> Containers/Get x2 ->
//       Tasks/Create(container_id, rootfs, stdin="", stdout="file://<log>",
//       stderr="file://<log>" [, options=runc Options{BinaryName:
//       nvidia-container-runtime}) for the GPU ffmpeg kinds — Option C])
//    7. Tasks/Start
//
//  STOP op:
//    1. LoadContainer(id) = Containers/Get; NotFound -> OK
//    2. container.Task(cio.Load) = Tasks/Get; NotFound -> delete container
//    3. task.Kill(SIGTERM)  (Kill-then-Wait, the C-layer ordering)
//    4. wait for exit, bounded by gracefulStopTimeout (STAGE_STOP_TIMEOUT)
//    5. exit -> Tasks/Delete; timeout/transport -> Kill(SIGKILL) + Delete
//    6. container.Delete(WithSnapshotCleanup)
//
//  OCI SPEC FIELD SET per stage (what cc_ctr_oci_spec_fill produces):
//    ALL stages: host_network = 1, caps_add = ["CAP_SYS_NICE"], cwd = NULL,
//      uid/gid = 0, n_add_gids = 0, hostname = none, annotations = none,
//      cgroups_path = "/<ContainerdNamespace>/<container-id>".
//    MediaMTX: env = [PATH=...defaultUnixEnv...],
//      args = ["/entrypoint.sh"], mounts (6) = Env/MediaMTXTmpl/Notify/
//      SrtPass (ro), VideoDir/Tmp (rw).
//    FFmpeg stages: env = [NVIDIA_VISIBLE_DEVICES=all,
//      NVIDIA_DRIVER_CAPABILITIES=compute,utility,video,
//      LD_LIBRARY_PATH=/usr/lib64 (the amd64 image env — the AArch64 image
//      uses /lib/aarch64-linux-gnu; this is the per-arch golden field set),
//      PATH=...], args = ["/transcode.sh", "<stage-name>"],
//      mounts (4) = Env/Transcode/ResolvConf (ro), Tmp (rw).
//    Option C: the ffmpeg-image stages pass
//      "/usr/bin/nvidia-container-runtime" as the task-options runtime;
//      MediaMTX passes NULL (plain runc).
//
//  C-layer deviations honored (from the Phase 4.4a contract):
//    1. OCI spec fields are CALLER-supplied (the assembly fills the struct
//       from the env-runtime block and the Layout mount sources).
//    2. Kill-then-Wait: cc_ctr_wait_task returns the stored exit status even
//       for an already-exited task.
//    3. chainID: Snapshots/Prepare(parent="") with key = the snapshotID.
//    4. Return mapping: ops return the first failing RPC's result — >= 0 is
//       a gRPC status (0 = OK), negative is a CC_CTR_ERR_*/CC_GRPC_ERR_*
//       client error.
//
//  Exported (all .global, SysV, RBX/RBP/R12-R15 preserved; <= 80 insns):
//    cc_ctr_init(rdi=layout, rsi=h, rdx=stop_timeout_ns)
//                        -> rax = 0; store the module state
//    cc_ctr_apply(rdi=stage, rsi=target CC_STATE_*)
//                        -> rax = 0 ok / op error code; the op dispatcher
//    cc_ctr_ops_for(rdi=stage_id) -> rax = the stage's ops table ptr / 0
//    cc_ctr_inflight_set(rdi=stage) -> rax = 0; InFlightSince = now()
//    cc_ctr_inflight_clear(rdi=stage) -> rax = 0; InFlightSince = 0
//    cc_ctr_inflight_active(rdi=stage) -> rax = 1/0
//    cc_ctr_inflight_timed_out(rdi=stage, rsi=timeout_ns) -> rax = 1/0
//    cc_ctr_oci_spec_fill(rdi=config, rsi=CTR_KIND_*, rdx=spec_out,
//                        rcx=mounts_out, r8=cgroups_scratch)
//                        -> rax = 0 / CC_CTR_ERR_BADARG
//    cc_ctr_mediamtx_start(rdi=stage) / cc_ctr_mediamtx_stop(rdi=stage)
//    cc_ctr_normalize_start(rdi=stage) / cc_ctr_normalize_stop(rdi=stage)
//    cc_ctr_scale_egress_start(rdi=stage) / cc_ctr_scale_egress_stop(rdi=stage)
//    cc_ctr_single_egress_start(rdi=stage) / cc_ctr_single_egress_stop(rdi=stage)
//                        -> rax = 0 / error code; tail calls into the shared
//                           helpers
//
//  Module-local helpers (ctr_*, full SysV obligations):
//    ctr_start(rdi=config, rsi=kind)    the shared start op sequence
//    ctr_start_create(rdi=config, rsi=kind, rdx=h, rcx=json_len)
//                                       the Containers/Create + NewTask half
//                                       (split from ctr_start at the spec-
//                                       JSON boundary to stay <= 80 insns)
//    ctr_stop(rdi=config)               the shared stop op sequence
//    ctr_stop_wait(rdi=config, rsi=h)   the bounded Wait + force + delete
//                                       half (split from ctr_stop to stay
//                                       <= 80 insns)
//    ctr_fill_mounts(rdi=mounts_out, rsi=desc_table, rdx=n)
//    ctr_build_cgroups(rdi=config, rsi=spec, rdx=scratch)
//    ctr_build_uri(rdi=config)          "file://"+logfile into ctr_scratch+512
//
//  SysV AMD64 notes (see cc_platform_x86_64.h for the full rules)
//  ----------------------------------------------------
//    * Arguments in %rdi, %rsi, %rdx, %rcx, %r8, %r9 (integer/pointer);
//      floats in %xmm0-%xmm7; return in %rax.  The 7th+ args go on the
//      stack at 0(%rsp), 8(%rsp), ... with %rsp 16-byte aligned at the call.
//    * Callee-saved (must be preserved across any `call`): %rbx, %rbp,
//      %r12-%r15.  %rsp is the return-address link: `call` pushes it, `ret`
//      pops it; net rsp displacement at every `ret` is zero (PROLOGUE n /
//      EPILOGUE n guarantee this).
//    * Never join statements with ';' — it is a statement separator on x86.
//      One instruction per line.  Comments are `//` (CPP strips them).
// ============================================================================

#include "cc_platform_x86_64.h"
#include "../cc_layout.inc"
#include "../cc_ctr.h"
#include "../cc_json.h"
    .text

// ============================================================================
// cc_ctr_init — store the module state.
//   in:  rdi = Layout ptr, rsi = containerd connection handle (int),
//        rdx = gracefulStopTimeout (u64 ns)
//   out: rax = 0
// ============================================================================
    .p2align 4
    .global cc_ctr_init
    FUNC_TYPE(cc_ctr_init)
cc_ctr_init:
    lea ctr_state(%rip), %rax
    mov %rdi, CTR_STATE_LAYOUT(%rax)
    mov %esi, CTR_STATE_H(%rax)         // w1 -> int (32-bit store)
    mov %rdx, CTR_STATE_STOP_TIMEOUT(%rax)
    xor %eax, %eax
    ret

// ============================================================================
// cc_ctr_ops_for — the Stage.ops table for a stage id.
//   in:  rdi = CC_STAGE_* id
//   out: rax = ptr to the two-fn-ptr ops table (indexed by CC_STATE_*), or 0
// ============================================================================
    .p2align 4
    .global cc_ctr_ops_for
    FUNC_TYPE(cc_ctr_ops_for)
cc_ctr_ops_for:
    cmp $CC_STAGE_COUNT, %edi
    jae .Lof_bad
    lea ctr_ops_table(%rip), %rax
    mov (%rax,%rdi,8), %rax             // table[stage_id]
    ret
.Lof_bad:
    xor %eax, %eax
    ret

// ============================================================================
// cc_ctr_inflight_set — mark a stage in flight.
//   in:  rdi = Stage ptr
//   out: rax = 0
//   Writes clock_gettime(CLOCK_MONOTONIC) into Stage.inflightSince.
// ============================================================================
    .p2align 4
    .global cc_ctr_inflight_set
    FUNC_TYPE(cc_ctr_inflight_set)
cc_ctr_inflight_set:
    PROLOGUE 1                          // rbx = stage across the call
    mov %rdi, %rbx
    sub $16, %rsp                       // struct timespec
    mov $CLOCK_MONOTONIC, %edi
    mov %rsp, %rsi
    call clock_gettime
    mov (%rsp), %rax                    // tv_sec
    mov 8(%rsp), %rcx                   // tv_nsec
    add $16, %rsp
    mov %rax, CC_STG_INFLIGHT_SINCE(%rbx)
    mov %rcx, CC_STG_INFLIGHT_SINCE+8(%rbx)
    xor %eax, %eax
    EPILOGUE 1
    ret

// ============================================================================
// cc_ctr_inflight_clear — mark a stage not in flight.
// ============================================================================
    .p2align 4
    .global cc_ctr_inflight_clear
    FUNC_TYPE(cc_ctr_inflight_clear)
cc_ctr_inflight_clear:
    movq $0, CC_STG_INFLIGHT_SINCE(%rdi)
    movq $0, CC_STG_INFLIGHT_SINCE+8(%rdi)
    xor %eax, %eax
    ret

// ============================================================================
// cc_ctr_inflight_active — is the stage currently in flight?
//   out: rax = 1 when inflightSince != 0, else 0
// ============================================================================
    .p2align 4
    .global cc_ctr_inflight_active
    FUNC_TYPE(cc_ctr_inflight_active)
cc_ctr_inflight_active:
    mov CC_STG_INFLIGHT_SINCE(%rdi), %rax
    or  CC_STG_INFLIGHT_SINCE+8(%rdi), %rax
    test %rax, %rax
    setne %al
    movzbl %al, %eax
    ret

// ============================================================================
// cc_ctr_inflight_timed_out — has the in-flight op exceeded its budget?
//   in:  rdi = Stage ptr, rsi = timeout (u64 ns)
//   out: rax = 1 when in flight AND now - inflightSince >= timeout, else 0
// ============================================================================
    .p2align 4
    .global cc_ctr_inflight_timed_out
    FUNC_TYPE(cc_ctr_inflight_timed_out)
cc_ctr_inflight_timed_out:
    PROLOGUE 4                          // rbx=stage r12=timeout r13=sec r14=nsec
    mov %rdi, %rbx
    mov %rsi, %r12
    mov CC_STG_INFLIGHT_SINCE(%rbx), %r13
    mov CC_STG_INFLIGHT_SINCE+8(%rbx), %r14
    mov %r13, %rax
    or  %r14, %rax                      // in flight when sec OR nsec != 0
    test %rax, %rax
    jz .Lit_no
    sub $16, %rsp                       // struct timespec
    mov $CLOCK_MONOTONIC, %edi
    mov %rsp, %rsi
    call clock_gettime
    mov (%rsp), %rcx                    // now.sec
    mov 8(%rsp), %rdx                   // now.nsec
    add $16, %rsp
    mov %rcx, %r8
    sub %r13, %r8                       // sec delta
    mov %rdx, %r9
    sub %r14, %r9                       // nsec delta (sets CF)
    jae .Lit_nb                         // b.hs: no borrow when nsec >= inflight nsec
    dec %r8                             // borrow a second
    MOV_NANOSEC r10
    add %r10, %r9
.Lit_nb:
    MOV_NANOSEC r10
    imul %r10, %r8                      // sec delta in ns (low 64)
    add %r9, %r8                        // total elapsed ns
    cmp %r12, %r8
    jae .Lit_yes
.Lit_no:
    xor %eax, %eax
    jmp .Lit_ret
.Lit_yes:
    mov $1, %eax
.Lit_ret:
    EPILOGUE 4
    ret

// ============================================================================
// cc_ctr_oci_spec_fill — build a struct cc_ctr_oci_spec for a stage.
//   in:  rdi = config ptr (env-runtime + CC_ER_* stage ContainerConfig),
//        rsi = CTR_KIND_*,
//        rdx = out struct cc_ctr_oci_spec (CC_OCI_SPEC_SIZE bytes, 8-aligned),
//        rcx = out cc_ctr_oci_mount array (CTR_SPEC_MOUNTS_MAX records),
//        r8  = cgroups-path scratch (>= 256 bytes)
//   out: rax = 0 / CC_CTR_ERR_BADARG
// ============================================================================
    .p2align 4
    .global cc_ctr_oci_spec_fill
    FUNC_TYPE(cc_ctr_oci_spec_fill)
cc_ctr_oci_spec_fill:
    PROLOGUE 5                          // rbx=config r12=kind r13=spec
    mov %rdi, %rbx                      //   r14=mounts r15=scratch
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    mov %r8, %r15
    cmp $CTR_KIND_COUNT, %r12d
    jae .Lfill_bad
    lea ctr_kind_info(%rip), %rax
    imul $CTR_KI_STRIDE, %r12, %rcx     // kind * 48
    add %rcx, %rax                      // rax = &ctr_kind_info[kind]
    // zero the fixed scalar fields the builder reads
    movq $0, CC_OCI_CWD(%r13)
    movq $0, CC_OCI_HOSTNAME(%r13)
    movl $0, CC_OCI_UID(%r13)
    movl $0, CC_OCI_GID(%r13)
    movl $0, CC_OCI_N_ADD_GIDS(%r13)
    movl $0, CC_OCI_N_ANN(%r13)
    // env (per-kind table)
    mov CTR_KI_ENV(%rax), %rcx          // env table ptr
    mov CTR_KI_N_ENV(%rax), %edx        // n_env
    mov %edx, CC_OCI_N_ENV(%r13)
    test %edx, %edx
    jz .Lfill_args
    lea CC_OCI_ENV(%r13), %rsi
.Lfill_env:
    mov (%rcx), %r8
    add $8, %rcx                        // post-index load
    mov %r8, (%rsi)
    add $8, %rsi
    dec %edx
    jnz .Lfill_env
    // args (per-kind table)
.Lfill_args:
    mov CTR_KI_ARGS(%rax), %rcx         // args table ptr
    mov CTR_KI_N_ARGS(%rax), %edx       // n_args
    mov %edx, CC_OCI_N_ARGS(%r13)
    test %edx, %edx
    jz .Lfill_caps
    lea CC_OCI_ARGS(%r13), %rsi
.Lfill_arg:
    mov (%rcx), %r8
    add $8, %rcx
    mov %r8, (%rsi)
    add $8, %rsi
    dec %edx
    jnz .Lfill_arg
    // caps_add = [CAP_SYS_NICE], host_network = 1
.Lfill_caps:
    movl $1, CC_OCI_N_CAPS_ADD(%r13)
    lea ctr_s_cap_sys_nice(%rip), %rcx
    mov %rcx, CC_OCI_CAPS_ADD(%r13)
    movl $1, CC_OCI_HOST_NETWORK(%r13)
    // mounts: wire the per-kind descriptor table into the out records
    mov CTR_KI_MOUNTS(%rax), %rsi       // desc table
    mov CTR_KI_N_MOUNTS(%rax), %edx     // n_mounts
    mov %edx, CC_OCI_N_MOUNTS(%r13)
    mov %r14, CC_OCI_MOUNTS(%r13)
    mov %r14, %rdi
    call ctr_fill_mounts
    // cgroups path = "/" + ns + "/" + container-id
    mov %rbx, %rdi
    mov %r13, %rsi
    mov %r15, %rdx
    call ctr_build_cgroups
    xor %eax, %eax
    jmp .Lfill_ret
.Lfill_bad:
    mov $-101, %eax                     // CC_CTR_ERR_BADARG
.Lfill_ret:
    EPILOGUE 5
    ret

// ============================================================================
// cc_ctr_apply — the op dispatcher.
//   in:  rdi = Stage ptr, rsi = target CC_STATE_*
//   out: rax = 0 (ok or no-op) / the op's error code
// ============================================================================
    .p2align 4
    .global cc_ctr_apply
    FUNC_TYPE(cc_ctr_apply)
cc_ctr_apply:
    PROLOGUE 3                          // rbx=stage r12=op fn r13=result
    mov %rdi, %rbx
    cmp $CC_STATE_COUNT, %esi
    jae .Lap_noop                       // NoTarget / bad id -> no-op
    mov CC_STG_OPS(%rbx), %rdx
    test %rdx, %rdx
    jz .Lap_noop
    mov (%rdx,%rsi,8), %r12             // ops[target]
    test %r12, %r12
    jz .Lap_noop
    mov %rbx, %rdi
    call cc_ctr_inflight_set
    mov %rbx, %rdi
    call *%r12                          // run the op (indirect call)
    mov %eax, %r13d
    test %r13d, %r13d
    jz .Lap_ok
    mov %rbx, %rdi
    call cc_ctr_inflight_clear
.Lap_ok:
    mov %r13d, %eax
    EPILOGUE 3
    ret
.Lap_noop:
    xor %eax, %eax
    EPILOGUE 3
    ret

// ============================================================================
// Per-stage op wrappers — each is a tail call into the shared start/stop
// helpers with its ContainerConfig (env-runtime + CC_ER_* offset) and kind.
// The rdi=stage argument the dispatcher passes is intentionally unused.
// ============================================================================
    .p2align 4
    .global cc_ctr_mediamtx_start
    FUNC_TYPE(cc_ctr_mediamtx_start)
cc_ctr_mediamtx_start:
    lea ctr_state(%rip), %rax
    mov CTR_STATE_LAYOUT(%rax), %rdi
    add $CC_LAY_SIZE, %rdi
    add $CC_ER_MEDIAMTX, %rdi
    mov $CTR_KIND_MEDIAMTX, %esi
    jmp ctr_start

    .p2align 4
    .global cc_ctr_mediamtx_stop
    FUNC_TYPE(cc_ctr_mediamtx_stop)
cc_ctr_mediamtx_stop:
    lea ctr_state(%rip), %rax
    mov CTR_STATE_LAYOUT(%rax), %rdi
    add $CC_LAY_SIZE, %rdi
    add $CC_ER_MEDIAMTX, %rdi
    jmp ctr_stop

    .p2align 4
    .global cc_ctr_normalize_start
    FUNC_TYPE(cc_ctr_normalize_start)
cc_ctr_normalize_start:
    lea ctr_state(%rip), %rax
    mov CTR_STATE_LAYOUT(%rax), %rdi
    add $CC_LAY_SIZE, %rdi
    add $CC_ER_NORMALIZE, %rdi
    mov $CTR_KIND_NORMALIZE, %esi
    jmp ctr_start

    .p2align 4
    .global cc_ctr_normalize_stop
    FUNC_TYPE(cc_ctr_normalize_stop)
cc_ctr_normalize_stop:
    lea ctr_state(%rip), %rax
    mov CTR_STATE_LAYOUT(%rax), %rdi
    add $CC_LAY_SIZE, %rdi
    add $CC_ER_NORMALIZE, %rdi
    jmp ctr_stop

    .p2align 4
    .global cc_ctr_scale_egress_start
    FUNC_TYPE(cc_ctr_scale_egress_start)
cc_ctr_scale_egress_start:
    lea ctr_state(%rip), %rax
    mov CTR_STATE_LAYOUT(%rax), %rdi
    add $CC_LAY_SIZE, %rdi
    add $CC_ER_SCALE_AND_EGRESS, %rdi
    mov $CTR_KIND_SCALE_EGRESS, %esi
    jmp ctr_start

    .p2align 4
    .global cc_ctr_scale_egress_stop
    FUNC_TYPE(cc_ctr_scale_egress_stop)
cc_ctr_scale_egress_stop:
    lea ctr_state(%rip), %rax
    mov CTR_STATE_LAYOUT(%rax), %rdi
    add $CC_LAY_SIZE, %rdi
    add $CC_ER_SCALE_AND_EGRESS, %rdi
    jmp ctr_stop

    .p2align 4
    .global cc_ctr_single_egress_start
    FUNC_TYPE(cc_ctr_single_egress_start)
cc_ctr_single_egress_start:
    lea ctr_state(%rip), %rax
    mov CTR_STATE_LAYOUT(%rax), %rdi
    add $CC_LAY_SIZE, %rdi
    add $CC_ER_SINGLE_STAGE_EGRESS, %rdi
    mov $CTR_KIND_SINGLE_EGRESS, %esi
    jmp ctr_start

    .p2align 4
    .global cc_ctr_single_egress_stop
    FUNC_TYPE(cc_ctr_single_egress_stop)
cc_ctr_single_egress_stop:
    lea ctr_state(%rip), %rax
    mov CTR_STATE_LAYOUT(%rax), %rdi
    add $CC_LAY_SIZE, %rdi
    add $CC_ER_SINGLE_STAGE_EGRESS, %rdi
    jmp ctr_stop

// ============================================================================
// ctr_fill_mounts — resolve a mount-descriptor table into cc_ctr_oci_mount
//   records.
//   in:  rdi = out cc_ctr_oci_mount array, rsi = desc table (CC_OCI_MOUNT_DESC
//        SIZE entries: dest ptr, opts ptr, CC_LAY_* offset, n_options),
//        rdx = n_mounts
//   out: rax = 0
//   No calls inside: only caller-saved registers are used.
// ============================================================================
    .p2align 4
ctr_fill_mounts:
    test %rdx, %rdx
    jz .Lfm_ret
    xor %r8d, %r8d                      // i = 0
.Lfm_loop:
    lea ctr_state(%rip), %rax
    mov CTR_STATE_LAYOUT(%rax), %rax    // layout
    imul $24, %r8, %r9                  // desc + 24*i
    add %rsi, %r9
    imul $96, %r8, %r10                 // rec + 96*i
    add %rdi, %r10
    mov (%r9), %r11                     // destination
    mov %r11, CC_OCI_M_DESTINATION(%r10)
    mov 16(%r9), %r11d                  // layout offset (u32)
    mov (%rax,%r11), %r11               // source = Layout[off] (byte offset)
    mov %r11, CC_OCI_M_SOURCE(%r10)
    lea ctr_s_mount_type(%rip), %r11
    mov %r11, CC_OCI_M_TYPE(%r10)
    mov 20(%r9), %r11d                  // n_options
    mov %r11d, CC_OCI_M_N_OPTIONS(%r10)
    mov 8(%r9), %rcx                    // option-string ptr array
    test %r11d, %r11d
    jz .Lfm_next
    xor %r9d, %r9d                      // j = 0 (desc+off dead in inner loop)
    lea CC_OCI_M_OPTIONS(%r10), %r10    // dest base (rec+off dead)
.Lfm_opt:
    mov (%rcx,%r9,8), %rax              // value (rax free: layout already used)
    mov %rax, (%r10,%r9,8)
    inc %r9
    cmp %r11d, %r9d                     // j < n_options
    jb .Lfm_opt
.Lfm_next:
    inc %r8
    cmp %rdx, %r8
    jb .Lfm_loop
.Lfm_ret:
    xor %eax, %eax
    ret

// ============================================================================
// ctr_build_cgroups — build the spec's linux.cgroupsPath.
//   in:  rdi = config ptr, rsi = struct cc_ctr_oci_spec, rdx = scratch
//   out: rax = 0; spec->cgroups_path = scratch, which now holds
//        "/" + ContainerdNamespace + "/" + container-id
// ============================================================================
    .p2align 4
ctr_build_cgroups:
    PROLOGUE 3                          // rbx=config r12=spec r13=scratch
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    movb $'/', (%r13)                   // strb '/', [scratch]
    lea 1(%r13), %rdi                   // dst = scratch+1
    lea ctr_state(%rip), %rax
    mov CTR_STATE_LAYOUT(%rax), %rax
    add $CC_LAY_SIZE, %rax
    mov CC_ER_CONTAINERD_NAMESPACE(%rax), %rsi
    call cc_cat_cstr                    // rax = NUL position
    movb $'/', (%rax)
    lea 1(%rax), %rdi
    mov CC_CC_CONTAINER_ID(%rbx), %rsi
    call cc_cat_cstr
    mov %r13, CC_OCI_CGROUPS_PATH(%r12)
    xor %eax, %eax
    EPILOGUE 3
    ret

// ============================================================================
// ctr_build_uri — build the task IO URI "file://" + logfile.
//   in:  rdi = config ptr
//   out: rax = 0; ctr_scratch + CTR_SCRATCH_URI holds the URI
// ============================================================================
    .p2align 4
ctr_build_uri:
    PROLOGUE 1                          // rbx = config
    mov %rdi, %rbx
    lea ctr_scratch(%rip), %rdi
    add $CTR_SCRATCH_URI, %rdi
    lea ctr_s_file_uri(%rip), %rsi
    call cc_cat_cstr                    // rax = NUL position
    mov CC_CC_LOGFILE(%rbx), %rsi
    mov %rax, %rdi                      // dst = the NUL position
    call cc_cat_cstr
    xor %eax, %eax
    EPILOGUE 1
    ret

// ============================================================================
// ctr_start — the shared start op, steps 1-5 (port of container_factory.go:
// 212-226).  Splits into ctr_start_create at the spec-JSON boundary.
//   in:  rdi = config ptr, rsi = CTR_KIND_*
//   out: rax = 0 / the first failing RPC's result
// ============================================================================
    .p2align 4
ctr_start:
    PROLOGUE 4                          // rbx=config r12=kind r13=h r14=json_len
    mov %rdi, %rbx
    mov %rsi, %r12
    // 1. stop() first — cleanup before (re)create (Go :213)
    call ctr_stop
    test %eax, %eax
    jnz .Lst_ret
    // 2. GetImage(imageName) (Go :75)
    lea ctr_state(%rip), %rax
    mov CTR_STATE_H(%rax), %r13d        // h (int)
    mov %r13d, %edi
    mov CC_CC_IMAGE_NAME(%rbx), %rsi
    xor %edx, %edx
    xor %ecx, %ecx
    xor %r8d, %r8d
    xor %r9d, %r9d
    call cc_ctr_get_image
    test %eax, %eax
    jnz .Lst_ret
    // 3. Snapshots/Prepare(key=snapshotID, parent="")
    mov %r13d, %edi
    lea ctr_s_overlayfs(%rip), %rsi
    mov CC_CC_SNAPSHOT_ID(%rbx), %rdx
    lea ctr_s_empty(%rip), %rcx
    lea ctr_prep_mounts(%rip), %r8
    mov $CTR_PREP_MOUNTS_MAX, %r9d
    lea ctr_n_mounts(%rip), %rax
    mov %rax, (%rsp)                    // 7th arg: out_n_mounts
    call cc_ctr_prepare_snapshot
    test %eax, %eax
    jnz .Lst_ret
    // 4. assemble the OCI spec struct (deviation 1: caller-supplied fields)
    mov %rbx, %rdi
    mov %r12, %rsi
    lea ctr_spec_buf(%rip), %rdx
    lea ctr_spec_mounts(%rip), %rcx
    lea ctr_scratch(%rip), %r8
    call cc_ctr_oci_spec_fill
    test %eax, %eax
    jnz .Lst_ret
    // 5. build the spec JSON
    lea ctr_spec_buf(%rip), %rdi
    lea ctr_json_buf(%rip), %rsi
    mov $CTR_OCI_JSON_CAP, %edx
    call cc_ctr_oci_spec_build
    test %eax, %eax
    js .Lst_ret                         // negative = CC_CTR_ERR_* (build failed)
    mov %eax, %r14d                     // json length
    // split: steps 6-8 (create + task) live in ctr_start_create
    mov %rbx, %rdi                      // config
    mov %r12, %rsi                      // kind
    mov %r13d, %edx                     // h
    mov %r14d, %ecx                     // json_len
    call ctr_start_create
.Lst_ret:
    EPILOGUE 4
    ret

// ============================================================================
// ctr_start_create — the shared start op, steps 6-8.
//   in:  rdi = config ptr, rsi = CTR_KIND_*, rdx = h, rcx = json_len
//   out: rax = 0 / the first failing RPC's result
// ============================================================================
    .p2align 4
ctr_start_create:
    PROLOGUE 4                          // rbx=config r12=kind r13=h r14=json_len
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %edx, %r13d
    mov %ecx, %r14d
    // 6. Containers/Create (Go NewContainer client.go:340-377)
    mov %r13d, %edi
    mov CC_CC_CONTAINER_ID(%rbx), %rsi
    mov CC_CC_IMAGE_NAME(%rbx), %rdx
    lea ctr_s_overlayfs(%rip), %rcx
    mov CC_CC_SNAPSHOT_ID(%rbx), %r8
    xor %r9d, %r9d                      // runtime NULL -> io.containerd.runc.v2
    lea ctr_json_buf(%rip), %rax
    mov %rax, (%rsp)                    // 7th arg: oci_spec_json
    mov %r14, 8(%rsp)                   // 8th arg: oci_len
    call cc_ctr_create_container
    test %eax, %eax
    jnz .Lsc_ret
    // 7. NewTask with cio.LogFile(logfile) (Go :130, :219)
    mov %rbx, %rdi
    call ctr_build_uri
    mov %r13d, %edi
    mov CC_CC_CONTAINER_ID(%rbx), %rsi
    lea ctr_scratch(%rip), %rdx
    add $CTR_SCRATCH_URI, %rdx
    mov %rdx, %rcx                      // stderr = the same file URI
    xor %r8d, %r8d                      // out_pid NULL
    xor %r9d, %r9d
    cmp $CTR_KIND_MEDIAMTX, %r12d
    je .Lsc_nt_runtime
    lea ctr_s_nvidia_runtime(%rip), %r9 // Option C: GPU stages
.Lsc_nt_runtime:
    call cc_ctr_create_task
    test %eax, %eax
    jnz .Lsc_ret
    // 8. Tasks/Start (Go :222)
    mov %r13d, %edi
    mov CC_CC_CONTAINER_ID(%rbx), %rsi
    xor %edx, %edx
    call cc_ctr_start_task
.Lsc_ret:
    EPILOGUE 4
    ret

// ============================================================================
// ctr_stop — the shared stop op, steps 1-3 (port of container_factory.go:
// 140-210).  Splits into ctr_stop_wait for the Wait + force + delete half.
//   in:  rdi = config ptr
//   out: rax = 0 / the first failing RPC's result
// ============================================================================
    .p2align 4
ctr_stop:
    PROLOGUE 3                          // rbx=config r12=h
    mov %rdi, %rbx
    lea ctr_state(%rip), %rax
    mov CTR_STATE_H(%rax), %r12d        // h (int)
    // 1. LoadContainer(id) (Go :141); NotFound -> already gone, OK
    mov %r12d, %edi
    mov CC_CC_CONTAINER_ID(%rbx), %rsi
    xor %edx, %edx
    xor %ecx, %ecx
    xor %r8d, %r8d
    xor %r9d, %r9d
    call cc_ctr_get_container
    cmp $CC_GRPC_STATUS_NOT_FOUND, %eax
    je .Lsp_done
    test %eax, %eax
    jnz .Lsp_ret
    // 2. container.Task(cio.Load) (Go :155); NotFound -> delete container
    mov %r12d, %edi
    mov CC_CC_CONTAINER_ID(%rbx), %rsi
    xor %edx, %edx
    call cc_ctr_get_task
    cmp $CC_GRPC_STATUS_NOT_FOUND, %eax
    je .Lsp_delete_container
    test %eax, %eax
    jnz .Lsp_ret
    // 3. Kill(SIGTERM) — Kill-then-Wait, the C-layer ordering (deviation 2)
    mov %r12d, %edi
    mov CC_CC_CONTAINER_ID(%rbx), %rsi
    mov $SIGTERM, %edx
    call cc_ctr_kill_task
    cmp $CC_GRPC_STATUS_NOT_FOUND, %eax
    je .Lsp_wait                        // already gone: Wait returns NotFound
    test %eax, %eax
    jnz .Lsp_ret
    // 4-6. bounded Wait + force + delete (split into ctr_stop_wait)
.Lsp_wait:
    mov %rbx, %rdi                      // config
    mov %r12d, %esi                     // h
    call ctr_stop_wait
    jmp .Lsp_ret
.Lsp_delete_container:
    mov %r12d, %edi
    mov CC_CC_CONTAINER_ID(%rbx), %rsi
    call cc_ctr_delete_container
.Lsp_ret:
    EPILOGUE 3
    ret
.Lsp_done:
    xor %eax, %eax
    EPILOGUE 3
    ret

// ============================================================================
// ctr_stop_wait — the shared stop op, steps 4-6.
//   in:  rdi = config ptr, rsi = h
//   out: rax = 0 / the first failing RPC's result
// ============================================================================
    .p2align 4
ctr_stop_wait:
    PROLOGUE 3                          // rbx=config r12=h r13=wait_result
    mov %rdi, %rbx
    mov %esi, %r12d
    // 4. Wait bounded by gracefulStopTimeout
    mov %r12d, %edi
    lea ctr_state(%rip), %rax
    mov CTR_STATE_STOP_TIMEOUT(%rax), %rsi
    call cc_grpc_set_unary_timeout
    mov %r12d, %edi
    mov CC_CC_CONTAINER_ID(%rbx), %rsi
    xor %edx, %edx                      // out_exit_status NULL
    call cc_ctr_wait_task
    mov %eax, %r13d                     // save the wait result
    mov %r12d, %edi                     // restore the default unary timeout
    xor %esi, %esi
    call cc_grpc_set_unary_timeout
    cmp $CC_GRPC_STATUS_OK, %r13d
    je .Lsw_delete_task                 // graceful exit -> Tasks/Delete
    cmp $CC_GRPC_STATUS_NOT_FOUND, %r13d
    je .Lsw_delete_container            // task already gone
    // 5. force: Kill(SIGKILL) + Tasks/Delete
    mov %r12d, %edi
    mov CC_CC_CONTAINER_ID(%rbx), %rsi
    mov $SIGKILL, %edx
    call cc_ctr_kill_task
    test %eax, %eax
    jnz .Lsw_ret
.Lsw_delete_task:
    mov %r12d, %edi
    mov CC_CC_CONTAINER_ID(%rbx), %rsi
    xor %edx, %edx
    call cc_ctr_delete_task
    cmp $CC_GRPC_STATUS_NOT_FOUND, %eax
    je .Lsw_delete_container
    test %eax, %eax
    jnz .Lsw_ret
    // 6. container.Delete(WithSnapshotCleanup)
.Lsw_delete_container:
    mov %r12d, %edi
    mov CC_CC_CONTAINER_ID(%rbx), %rsi
    call cc_ctr_delete_container
.Lsw_ret:
    EPILOGUE 3
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
    .asciz "/entrypoint.sh"         // mediamtx image entrypoint
ctr_s_transcode_arg:
    .asciz "/transcode.sh"
ctr_s_stage_normalize:
    .asciz JSON_S_NORMALIZE
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
    .asciz "LD_LIBRARY_PATH=/usr/lib64"   // amd64 image env (core/BUILD.bazel)

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
// NOTE: on x86 GNU as `.word` is 16-bit, but the AArch64 original's `.word`
// is 32-bit (u32 fields at +16/+20, read by the 32-bit loads in
// ctr_fill_mounts).  `.long` is the portable 32-bit directive and keeps the
// x86 table byte-identical to the AArch64 contract (cc_ctr.h:97-99).
    .macro CTR_MOUNT_DESC dest, layout_off, opts_ptr, n_opts
    .quad \dest
    .quad \opts_ptr
    .long \layout_off
    .long \n_opts
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
ctr_prep_mounts:
    .space 3140 * CTR_PREP_MOUNTS_MAX   // cc_ctr_mount records (prepare out)
ctr_n_mounts:
    .space 4                         // uint32_t out_n_mounts (prepare)

    .end