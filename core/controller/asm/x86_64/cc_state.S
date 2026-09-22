// ============================================================================
// cc_state.S — STATE MACHINE / reconcile / listener / event-routing for the
// strimserver controller (x86-64 port)
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
//  This module is Phase 4.5: the STATE MACHINE half of the controller.  It
//  owns the paths status table and the stages table (the Controller struct's
//  data; cc_layout.inc CC_CTR_* / CC_STG_*), the path-event and control-
//  command route tables, and the reconcile loop that decides WHEN to run an
//  op.  The op itself is cc_ctr_apply (Phase 4.4, cc_ctr.S); the wire JSON
//  (un)marshalling is cc_json.S; the HTTP/websocket layers are Phases 4.6
//  and 4.7 — NOT built here.  The C operation layer and the BUILD files are
//  out of scope for this phase.
//
//  Golden contract (Gate 0 — core/controller/controller.go file:line):
//
//  RECONCILE (handleReconcile, controller.go:287-314):
//    For every stage:
//      converged := desired == actual                 :291
//      if converged { InFlightSince = 0; continue }   :292
//      target, timedOut := planReconcile(stage)       :294
//        (planReconcile, controller.go:316-320):
//          !in-flight           -> (desired, false)   :317
//          in-flight, in budget -> (NoTarget, false)  :318
//          in-flight, timed out -> (desired, true)    :319
//      if target == NoTarget { continue }             :295
//      if timedOut { log }                            :296
//      run ops[target] via cc_ctr_apply               :298-312
//      DEVIATION (documented): the Go op goroutine never writes Actual; the
//      containerd event listener does (handleStageEvent :236-248).  The
//      single-threaded port folds the op result into Actual so the loop
//      converges: success -> Actual = target; failure -> Actual = Stopped.
//      Actual = Stopped on failure matches the only other op-result->Actual
//      mapping in Go, Teardown (:342 sets both Stopped after the stop
//      attempt).  The transition fires notifyListeners; Go fires it from
//      handleStageEvent (:246) instead — same observable contract, different
//      trigger site (deviation).
//
//  LISTENERS (controller.go:250-267):
//    add:    nil -> error; append; fire the NEW listener with the current
//            status (:250-254)
//    remove: scan by pointer, splice on match, else "listener not
//            registered" (:256-261)
//    notify: no listeners -> return; build a status snapshot; call each
//            listener in slice order (:263-267)
//
//  EVENT ROUTING (handlePathEvent :223-234, handleStageEvent :236-248):
//    path event:  unknown path id -> error; invalid status id -> error;
//            store the status; route lookup {path,status} -> StageTarget;
//            no route -> nil; apply the target (:230-233)
//    stage event: unknown stage id -> error; invalid state id -> error;
//            store Actual; clear InFlightSince ALWAYS; notify iff Actual
//            changed (:243-246)
//
//  CONTROL ROUTING (handleControl :216-221):
//    route lookup {component,action} -> StageTarget; miss -> "control not
//    implemented" (:218-219); apply the target (:220)
//
//  TARGET APPLICATION (applyDesiredStageTarget :269-285):
//    desired == target state -> log "already desired", no-op (:271-274)
//    prerequisite fn (non-nil) must return 0, else error and desired stays
//    unchanged (:277-280)
//    set desired; notify (:282-283)
//
//  STATUS (handleStatus :322-327): Go clones the maps (async safety).  The
//  single-threaded port returns the live paths table and a freshly rebuilt
//  stages wire table (deviation, documented: the snapshot is consumed
//  synchronously before any mutation, so the clone is unobservable).
//
//  TEARDOWN (controller.go:331-348): for every stage with Actual == Running,
//  run ops[Stopped]; then set Desired = Actual = Stopped, clear
//  InFlightSince (:342-343); notify once (:345).  Go bounds the stop op with
//  a timeout ctx (:338); the C layer bounds its own RPCs (cc_ctr.S), so the
//  ctx is not ported.
//
//  CONSTRUCTION (NewController controller.go:105-176; wiring main.go:174-229):
//    paths  seeded {ingress0: Unknown, normalized: Unknown} (main.go:174)
//    stages seeded mediamtx {R,S}, normalize {S,S}, scale {S,S}, single
//           {S,S} (main.go:204-220); each stage's ops table via
//           cc_ctr_ops_for (main.go:171 CreateContainerOps /
//           container_factory.go CreateStageOps)
//    routes selected by the single-stage flag (main.go:185-202):
//      non-single: path events ingress0 Ready->normalize Running, NotReady
//                  ->normalize Stopped (:193-194); commands egress start->
//                  scale Running (prereq ingress0 ready), stop->scale Stopped
//                  (:196-201)
//      single:     no path-event routes; commands egress start->single
//                  Running (same prereq), stop->single Stopped (:186-191)
//    validation (controller.go:118-166): the fixed tables make the route/
//    status validations unreachable; the inflight-timeout > 0 guard (:162-164)
//    is kept (fail-loud; the env var is required — envspec.go:87).
//    The Controller.now field (CC_CTR_NOW) is kept for struct parity and
//    unused: the monotonic clock and in-flight bookkeeping live in cc_ctr.S
//    (cc_ctr_inflight_*), which planReconcile calls.
//
//  Exported (all .global, SysV AMD64, %rbx/%rbp/%r12-%r15 preserved;
//            <= 80 instructions):
//    cc_state_new(rdi=layout)                 -> rax = 0 / CC_STATE_ERR_*
//    cc_state_ctrl()                          -> rax = &Controller (state_ctrl)
//    cc_state_stage(rdi=stage_id)             -> rax = Stage entry ptr / 0
//    cc_state_path(rdi=path_id)               -> rax = paths entry ptr / 0
//    cc_state_run(rdi=ctrl)                   -> rax = 0   (Run, :178-180)
//    cc_state_reconcile(rdi=ctrl)             -> rax = 0   (handleReconcile)
//    cc_state_handle_path_event(rdi=ctrl, rsi=PathEvent)   -> rax = 0 / err
//    cc_state_handle_stage_event(rdi=ctrl, rsi=StageEvent) -> rax = 0 / err
//    cc_state_handle_control(rdi=ctrl, rsi=ControlCommand)-> rax = 0 / err
//    cc_state_add_listener(rdi=ctrl, rsi=fn)  -> rax = 0 / err
//    cc_state_remove_listener(rdi=ctrl, rsi=fn) -> rax = 0 / err
//    cc_state_status(rdi=ctrl)                -> rax = &ControllerStatus
//    cc_state_teardown(rdi=ctrl)              -> rax = 0   (Teardown)
//    cc_state_close(rdi=ctrl)                 -> rax = 0   (Close, :350)
//
//  Module-local helpers (state_*, full SysV obligations):
//    state_reconcile_one(rdi=ctrl, rsi=stage, rdx=timeout)   one stage
//    state_apply_target(rdi=ctrl, rsi=StageTarget)            applyDesiredStageTarget
//    state_route_lookup_path(rdi=ctrl, rsi=PathEvent) -> rax = StageTarget / 0
//    state_route_lookup_cmd(rdi=ctrl, rsi=ControlCommand) -> rax = StageTarget / 0
//    state_notify(rdi=ctrl)                                 notifyListeners
//    state_stage_entry(rdi=stage_id) -> rax = Stage ptr / 0
//    state_path_entry(rdi=path_id) -> rax = paths entry ptr / 0
//    state_prereq_ingress0_ready(rdi=ctrl) -> rax = 0 / -1
//    state_new_paths(rdi=layout)
//    state_new_stages(rdi=layout)
//
//  SysV AMD64 notes (the rules every module must follow; see cc_util.S)
//  ----------------------------------------------------
//    * Arguments in %rdi, %rsi, %rdx, %rcx, %r8, %r9 (integer/pointer);
//      floats in %xmm0-%xmm7; return in %rax (%rdx:%rax for 128-bit);
//      composites via a hidden sret pointer in %rdi.
//    * Callee-saved (must be preserved across any `call` we make): %rbx,
//      %rbp, %r12-%r15.  %rsp must stay 16-byte aligned at every call site.
//    * `call` pushes the return address; `ret` pops it.  Only `jmp` is a
//      tail call.  Never join statements with ';' — one instruction per line.
//    * Register mapping from the AArch64 original (x0-x7 -> rdi,rsi,rdx,
//      rcx,r8,r9; x19-x28 -> rbx/r12/r13/r14 + caller-saved temps; x23 and
//      beyond are caller-saved in this port wherever their value is dead at
//      every call boundary — the control flow is byte-identical).
//
// ============================================================================

#include "cc_platform_x86_64.h"
#include "../cc_layout.inc"
#include "../cc_json.h"
#include "../cc_state.h"
    .text

// ============================================================================
// cc_state_new — construct and seed the Controller (NewController,
// controller.go:105-176 + the main.go:174-229 wiring).
//   in:  rdi = Layout ptr (the env-runtime block sits at Layout + CC_LAY_SIZE;
//        cc_env_load filled CC_ER_* there — cc_env.h/cc_layout.inc)
//   out: rax = 0 / CC_STATE_ERR_TIMEOUT
//   Zeroes the Controller struct, points the paths/stages/listener fields at
//   the module's .bss tables, reads the inflight timeout and the
//   single-stage flag from the env block, selects the route tables, and
//   seeds the paths/stages tables (state_new_paths / state_new_stages).
//   %rbx holds the layout across the two seeding calls; the ctrl pointer and
//   all temps live in caller-saved registers (their values are dead at every
//   call site).
// ============================================================================
    .p2align 4
    .global cc_state_new
    FUNC_TYPE(cc_state_new)
cc_state_new:
    PROLOGUE 1                      // %rbx=layout; %r10=ctrl, %r11/%r8/%r9 temps
    mov %rdi, %rbx
    LEA r10, state_ctrl
    xor %r11d, %r11d
.Lnew_zero:                         // zero the Controller struct (idempotent
    movq $0, (%r10,%r11)            //   even though .bss starts zeroed)
    add $8, %r11
    cmp $CC_CTR_SIZE, %r11
    jb .Lnew_zero
    LEA r11, state_paths
    mov %r11, CC_CTR_PATHS(%r10)
    LEA r11, state_stages
    mov %r11, CC_CTR_STAGES(%r10)
    LEA r11, state_listeners
    mov %r11, CC_CTR_LISTENERS(%r10)
    mov $STATE_LISTENERS_MAX, %r11d
    mov %r11, CC_CTR_LISTENERS+16(%r10)
    lea CC_LAY_SIZE(%rbx), %r11     // env-runtime block
    mov CC_ER_INFLIGHT_TIMEOUT(%r11), %r8
    test %r8, %r8
    jz .Lnew_bad_timeout            // controller.go:162-164
    mov %r8, CC_CTR_INFLIGHT_TIMEOUT(%r10)
    movzbl CC_ER_ENABLE_SINGLE_STAGE(%r11), %r9d
    test %r9d, %r9d
    jnz .Lnew_single
    LEA r9, state_path_routes       // non-single routes (main.go:193-201)
    mov %r9, CC_CTR_PATH_EVENT_ROUTES(%r10)
    LEA r9, state_command_routes
    mov %r9, CC_CTR_COMMAND_ROUTES(%r10)
    jmp .Lnew_tables
.Lnew_single:
    LEA r9, state_path_routes_none  // single-stage routes (main.go:186-191)
    mov %r9, CC_CTR_PATH_EVENT_ROUTES(%r10)
    LEA r9, state_command_routes_single
    mov %r9, CC_CTR_COMMAND_ROUTES(%r10)
.Lnew_tables:
    mov %rbx, %rdi
    call state_new_paths
    mov %rbx, %rdi
    call state_new_stages
    xor %eax, %eax
    jmp .Lnew_ret
.Lnew_bad_timeout:
    LEA rdi, state_s_err_timeout
    call cc_eputs
    mov $-9, %eax                   // CC_STATE_ERR_TIMEOUT
.Lnew_ret:
    EPILOGUE 1
    ret

// ============================================================================
// cc_state_ctrl — the Controller pointer accessor (the controller lives in
// .bss; the handler functions take it as %rdi, cc_http.S/cc_main.S obtain it
// here).
// ============================================================================
    .p2align 4
    .global cc_state_ctrl
    FUNC_TYPE(cc_state_ctrl)
cc_state_ctrl:
    LEA rax, state_ctrl
    ret

// ============================================================================
// cc_state_stage / cc_state_path — id -> table entry accessors.
// ============================================================================
    .p2align 4
    .global cc_state_stage
    FUNC_TYPE(cc_state_stage)
cc_state_stage:
    jmp state_stage_entry

    .p2align 4
    .global cc_state_path
    FUNC_TYPE(cc_state_path)
cc_state_path:
    jmp state_path_entry

// ============================================================================
// cc_state_run — port of Run (controller.go:178-180).
//   in:  rdi = ctrl   out: rax = 0
//   Go drains the actions channel, running each submitted action on the
//   controller goroutine.  The single-threaded port has no channel: every
//   Submit* handler runs synchronously at its call site, so the drain loop
//   is empty.  Provided for API parity with main.go:315 (go controller.Run()).
// ============================================================================
    .p2align 4
    .global cc_state_run
    FUNC_TYPE(cc_state_run)
cc_state_run:
    xor %eax, %eax
    ret

// ============================================================================
// cc_state_close — port of Close (controller.go:350).
//   in:  rdi = ctrl   out: rax = 0
//   Go closes the actions channel, terminating Run; there is no channel to
//   close in the synchronous port.
// ============================================================================
    .p2align 4
    .global cc_state_close
    FUNC_TYPE(cc_state_close)
cc_state_close:
    xor %eax, %eax
    ret

// ============================================================================
// cc_state_reconcile — the reconcile loop (handleReconcile,
// controller.go:287-314).  Iterates the stages table in id order (Go's map
// order is unspecified; the port fixes id order for determinism), delegating
// each stage to state_reconcile_one.
// ============================================================================
    .p2align 4
    .global cc_state_reconcile
    FUNC_TYPE(cc_state_reconcile)
cc_state_reconcile:
    PROLOGUE 5                      // %rbx=ctrl %r12=timeout %r13=stage %r14=id
    mov %rdi, %rbx
    mov CC_CTR_INFLIGHT_TIMEOUT(%rbx), %r12
    LEA r13, state_stages
    add $8, %r13                    // first stage entry
    xor %r14d, %r14d
.Lrec_loop:
    cmp $CC_STAGE_COUNT, %r14d
    jae .Lrec_done
    mov %rbx, %rdi
    mov %r13, %rsi
    mov %r12, %rdx
    call state_reconcile_one
    add $CC_STG_SIZE, %r13
    inc %r14d
    jmp .Lrec_loop
.Lrec_done:
    xor %eax, %eax
    EPILOGUE 5
    ret

// ============================================================================
// state_reconcile_one — reconcile a single stage (handleReconcile
// controller.go:287-314 + planReconcile :316-320).
//   in:  rdi = ctrl, rsi = stage entry, rdx = inflight timeout
//   out: rax = 0
//   Converged stages clear in-flight (:292).  Non-converged stages plan a
//   target: not in flight -> desired now; in flight and within the budget ->
//   NoTarget (skip); in flight and timed out -> desired again (retry).  The
//   op runs via cc_ctr_apply (sets in-flight on start, clears it on error —
//   cc_ctr.S).  Actual is folded from the op result (deviation, see header):
//   0 -> target, error -> Stopped; a transition fires notifyListeners.
//   %rbx=ctrl, %r12=stage, %r13=timeout, %r14=desired; actual lives in %r8
//   (caller-saved — its value is dead at every call site).
// ============================================================================
    .p2align 4
state_reconcile_one:
    PROLOGUE 5                      // %rbx=ctrl %r12=stage %r13=timeout
    mov %rdi, %rbx                  //   %r14=desired %r8=actual
    mov %rsi, %r12
    mov %rdx, %r13
    mov CC_SS_DESIRED(%r12), %r14
    mov CC_SS_ACTUAL(%r12), %r8
    cmp %r8, %r14
    jne .Lro_plan
    mov %r12, %rdi
    call cc_ctr_inflight_clear      // converged (controller.go:292)
    xor %eax, %eax
    jmp .Lro_ret
.Lro_plan:
    mov %r12, %rdi
    call cc_ctr_inflight_active     // planReconcile (controller.go:316-320)
    test %rax, %rax
    jz .Lro_apply                   // not in flight -> run now
    mov %r12, %rdi
    mov %r13, %rsi
    call cc_ctr_inflight_timed_out
    test %rax, %rax
    jnz .Lro_timeout                // in flight AND timed out -> retry
    xor %eax, %eax
    jmp .Lro_ret                    // in flight, in budget -> NoTarget (:318)
.Lro_timeout:
    LEA rdi, state_s_log_timeout
    call cc_eputs                   // log (controller.go:296)
.Lro_apply:
    mov %r12, %rdi
    mov %r14, %rsi                  // target = desired
    call cc_ctr_apply               // the op (controller.go:298-312)
    test %rax, %rax
    jnz .Lro_failed
    mov %r14, %r8                   // success: Actual = target (deviation)
    jmp .Lro_store
.Lro_failed:
    LEA rdi, state_s_log_failed
    call cc_eputs                   // log (controller.go:309)
    mov $CC_STATE_STOPPED, %r8d     // failure: Actual = Stopped (deviation)
.Lro_store:
    mov CC_SS_ACTUAL(%r12), %rax
    cmp %r8, %rax
    je .Lro_ret                     // no transition -> no notify
    mov %r8, CC_SS_ACTUAL(%r12)
    mov %rbx, %rdi
    call state_notify               // fire on transitions (Go fires from the
    xor %eax, %eax                  //   stage event instead, :246 — deviation)
.Lro_ret:
    EPILOGUE 5
    ret

// ============================================================================
// cc_state_handle_path_event — handlePathEvent (controller.go:223-234).
//   in:  rdi = ctrl, rsi = PathEvent ptr {CC_PE_PATH, CC_PE_STATUS}
//   out: rax = 0 / CC_STATE_ERR_BADPATH / CC_STATE_ERR_BADSTATUS
//   Unknown path id or invalid status id -> error (Go's map lookup + Valid);
//   otherwise store the status, route {path,status} -> StageTarget, and
//   apply the target (no route -> nil, like Go's `if !ok { return nil }`).
// ============================================================================
    .p2align 4
    .global cc_state_handle_path_event
    FUNC_TYPE(cc_state_handle_path_event)
cc_state_handle_path_event:
    PROLOGUE 3                      // %rbx=ctrl %r12=event %r8=entry %r9=status
    mov %rdi, %rbx
    mov %rsi, %r12
    mov CC_PE_PATH(%r12), %rdi
    call state_path_entry
    test %rax, %rax
    jz .Lhpe_badpath                // unknown path (controller.go:224-225)
    mov %rax, %r8
    mov CC_PE_STATUS(%r12), %r9
    cmp $CC_STATUS_COUNT, %r9
    jae .Lhpe_badstatus             // invalid status (:226)
    mov %r9, 8(%r8)                 // store the status (:230)
    mov %rbx, %rdi
    mov %r12, %rsi
    call state_route_lookup_path
    test %rax, %rax
    jz .Lhpe_ok                     // no route -> nil (:232)
    mov %rax, %rsi
    mov %rbx, %rdi
    call state_apply_target         // (:233)
    jmp .Lhpe_ret
.Lhpe_badpath:
    LEA rdi, state_s_err_badpath
    call cc_eputs
    mov $-1, %eax                   // CC_STATE_ERR_BADPATH
    jmp .Lhpe_ret
.Lhpe_badstatus:
    LEA rdi, state_s_err_badstatus
    call cc_eputs
    mov $-2, %eax                   // CC_STATE_ERR_BADSTATUS
    jmp .Lhpe_ret
.Lhpe_ok:
    xor %eax, %eax
.Lhpe_ret:
    EPILOGUE 3
    ret

// ============================================================================
// cc_state_handle_stage_event — handleStageEvent (controller.go:236-248).
//   in:  rdi = ctrl, rsi = StageEvent ptr {CC_SE_STAGE, CC_SE_STATE}
//   out: rax = 0 / CC_STATE_ERR_BADSTAGE / CC_STATE_ERR_BADSTATE
//   Unknown stage id or invalid state id -> error; otherwise store Actual,
//   clear InFlightSince ALWAYS (:245), and notify iff Actual changed (:246).
//   The "changed" flag must survive the inflight_clear call, so it lives in
//   %r13 (callee-saved), not the AArch64 original's caller-saved x2.
// ============================================================================
    .p2align 4
    .global cc_state_handle_stage_event
    FUNC_TYPE(cc_state_handle_stage_event)
cc_state_handle_stage_event:
    PROLOGUE 5                      // %rbx=ctrl %r12=event %r8=stage %r9=state
    mov %rdi, %rbx                  //   %r13=changed
    mov %rsi, %r12
    mov CC_SE_STAGE(%r12), %rdi
    call state_stage_entry
    test %rax, %rax
    jz .Lhse_badstage               // unknown stage (controller.go:237-238)
    mov %rax, %r8
    mov CC_SE_STATE(%r12), %r9
    cmp $CC_STATE_COUNT, %r9
    jae .Lhse_badstate              // invalid state (:239)
    mov CC_SS_ACTUAL(%r8), %rsi
    cmp %r9, %rsi
    setne %r13b                     // changed (:243)
    movzbl %r13b, %r13d
    mov %r9, CC_SS_ACTUAL(%r8)      // (:244)
    mov %r8, %rdi
    call cc_ctr_inflight_clear      // (:245)
    test %r13d, %r13d
    jz .Lhse_ok                     // notify only on change (:246)
    mov %rbx, %rdi
    call state_notify
.Lhse_ok:
    xor %eax, %eax
    jmp .Lhse_ret
.Lhse_badstage:
    LEA rdi, state_s_err_badstage
    call cc_eputs
    mov $-3, %eax                   // CC_STATE_ERR_BADSTAGE
    jmp .Lhse_ret
.Lhse_badstate:
    LEA rdi, state_s_err_badstate
    call cc_eputs
    mov $-4, %eax                   // CC_STATE_ERR_BADSTATE
.Lhse_ret:
    EPILOGUE 5
    ret

// ============================================================================
// cc_state_handle_control — handleControl (controller.go:216-221).
//   in:  rdi = ctrl, rsi = ControlCommand ptr {CC_CMD_COMPONENT, CC_CMD_ACTION}
//   out: rax = 0 / CC_STATE_ERR_NOCTRL
//   Route lookup {component,action}; a miss is "control not implemented"
//   (:218-219) — Go never validates component/action, and an unrecognized id
//   (CC_JSON_ID_UNKNOWN) simply misses, exactly like Go's unrecognized
//   string key.
// ============================================================================
    .p2align 4
    .global cc_state_handle_control
    FUNC_TYPE(cc_state_handle_control)
cc_state_handle_control:
    PROLOGUE 1                      // %rbx=ctrl; cmd stays in %rsi
    mov %rdi, %rbx
    mov %rbx, %rdi
    call state_route_lookup_cmd
    test %rax, %rax
    jz .Lhc_miss                    // controller.go:218-219
    mov %rax, %rsi
    mov %rbx, %rdi
    call state_apply_target
    jmp .Lhc_ret
.Lhc_miss:
    LEA rdi, state_s_err_noctrl
    call cc_eputs
    mov $-5, %eax                   // CC_STATE_ERR_NOCTRL
.Lhc_ret:
    EPILOGUE 1
    ret

// ============================================================================
// cc_state_add_listener — handleAddListener (controller.go:250-254).
//   in:  rdi = ctrl, rsi = listener fn ptr (ControllerListener port)
//   out: rax = 0 / CC_STATE_ERR_NIL / CC_STATE_ERR_FULL
//   Appends the fn to the listener slice and fires it once with the current
//   status (:253).  Go's slice grows without bound; the fixed-cap port fails
//   loud at STATE_LISTENERS_MAX.
// ============================================================================
    .p2align 4
    .global cc_state_add_listener
    FUNC_TYPE(cc_state_add_listener)
cc_state_add_listener:
    PROLOGUE 3                      // %rbx=ctrl %r12=fn %r8=ptr %r9=len
    mov %rdi, %rbx                  //   %r10=cap
    mov %rsi, %r12
    test %r12, %r12
    jz .Ladd_nil                    // controller.go:251
    mov CC_CTR_LISTENERS(%rbx), %r8
    mov CC_CTR_LISTENERS+8(%rbx), %r9
    mov CC_CTR_LISTENERS+16(%rbx), %r10
    cmp %r10, %r9
    jae .Ladd_full                  // fixed capacity — fail-loud
    mov %r12, (%r8,%r9,8)           // append (:252)
    inc %r9
    mov %r9, CC_CTR_LISTENERS+8(%rbx)
    mov %rbx, %rdi
    call cc_state_status            // f := *l; f(status) (:253)
    mov %rax, %rdi
    call *%r12
    xor %eax, %eax
    jmp .Ladd_ret
.Ladd_nil:
    mov $-7, %eax                   // CC_STATE_ERR_NIL
    jmp .Ladd_ret
.Ladd_full:
    mov $-10, %eax                  // CC_STATE_ERR_FULL
.Ladd_ret:
    EPILOGUE 3
    ret

// ============================================================================
// cc_state_remove_listener — handleRemoveListener (controller.go:256-261).
//   in:  rdi = ctrl, rsi = listener fn ptr
//   out: rax = 0 / CC_STATE_ERR_NOTREG
//   Scans by pointer, splices the slot (append(s[:i], s[i+1:]...), :258),
//   decrements len; a miss is "listener not registered" (:260).
//   The loop and shift contain no calls, so the scan index and the shift
//   temp live in caller-saved registers (%r8/%r9).
// ============================================================================
    .p2align 4
    .global cc_state_remove_listener
    FUNC_TYPE(cc_state_remove_listener)
cc_state_remove_listener:
    PROLOGUE 5                      // %rbx=ctrl %r12=fn %r13=ptr %r14=len
    mov %rdi, %rbx                  //   %r8=i %r9=tmp
    mov %rsi, %r12
    mov CC_CTR_LISTENERS(%rbx), %r13
    mov CC_CTR_LISTENERS+8(%rbx), %r14
    xor %r8d, %r8d
.Lrem_loop:
    cmp %r14, %r8
    jae .Lrem_notfound
    mov (%r13,%r8,8), %r9
    cmp %r12, %r9
    je .Lrem_found
    inc %r8
    jmp .Lrem_loop
.Lrem_found:
    lea 1(%r8), %rsi                // src = i+1
    cmp %r14, %rsi
    jae .Lrem_done                  // last slot: nothing to shift
.Lrem_shift:
    mov (%r13,%rsi,8), %r9
    mov %r9, (%r13,%r8,8)
    inc %r8
    inc %rsi
    cmp %r14, %rsi
    jb .Lrem_shift
.Lrem_done:
    dec %r14
    mov %r14, CC_CTR_LISTENERS+8(%rbx)
    xor %eax, %eax
    jmp .Lrem_ret
.Lrem_notfound:
    LEA rdi, state_s_err_notreg
    call cc_eputs
    mov $-8, %eax                   // CC_STATE_ERR_NOTREG    (controller.go:260)
.Lrem_ret:
    EPILOGUE 5
    ret

// ============================================================================
// cc_state_status — handleStatus (controller.go:322-327).
//   in:  rdi = ctrl (unused — parity)
//   out: rax = &ControllerStatus {paths, stages} in the cc_json_status wire
//   format (cc_json.h CC_JSON_PTBL_ENTRY / CC_JSON_STBL_ENTRY, ascending
//   name order).  Go clones the maps (async safety); the single-threaded
//   port shares the live paths table and rebuilds the stages wire table
//   from the internal Stage array + the rodata name table (deviation,
//   documented in the header).
// ============================================================================
    .p2align 4
    .global cc_state_status
    FUNC_TYPE(cc_state_status)
cc_state_status:
    LEA rdi, state_status
    LEA rsi, state_paths
    mov %rsi, CC_CS_PATHS(%rdi)
    LEA rsi, state_status_stages
    mov $CC_STAGE_COUNT, %edx
    mov %rdx, (%rsi)                // wire count
    add $8, %rsi
    LEA rcx, state_stage_names      // name table (rodata, by stage id)
    LEA r8, state_stages
    add $8, %r8                     // internal Stage array
    xor %r9d, %r9d
.Lss_loop:
    cmp $CC_STAGE_COUNT, %r9d
    jae .Lss_done
    mov (%rcx,%r9,8), %r10
    mov %r10, (%rsi)                // wire name
    mov CC_SS_DESIRED(%r8), %r10
    mov %r10, 8(%rsi)
    mov CC_SS_ACTUAL(%r8), %r10
    mov %r10, 16(%rsi)
    add $CC_JSON_STBL_ENTRY, %rsi
    add $CC_STG_SIZE, %r8
    inc %r9d
    jmp .Lss_loop
.Lss_done:
    LEA rsi, state_status_stages
    mov %rsi, CC_CS_STAGES(%rdi)
    ret

// ============================================================================
// cc_state_teardown — Teardown (controller.go:331-348).
//   in:  rdi = ctrl   out: rax = 0
//   For every stage with Actual == Running: run ops[Stopped] (Go logs a stop
//   failure, :340), then set Desired = Actual = Stopped and clear
//   InFlightSince (:342-343).  Notify once (:345).
// ============================================================================
    .p2align 4
    .global cc_state_teardown
    FUNC_TYPE(cc_state_teardown)
cc_state_teardown:
    PROLOGUE 5                      // %rbx=ctrl %r12=stage %r13=id
    mov %rdi, %rbx
    LEA r12, state_stages
    add $8, %r12
    xor %r13d, %r13d
.Ltd_loop:
    cmp $CC_STAGE_COUNT, %r13d
    jae .Ltd_notify
    mov CC_SS_ACTUAL(%r12), %rsi
    cmp $CC_STATE_RUNNING, %rsi
    jne .Ltd_next                   // only running stages (controller.go:335)
    mov CC_STG_OPS(%r12), %rdx
    mov CC_STATE_STOPPED*8(%rdx), %rcx   // ops[Stopped] (:336)
    test %rcx, %rcx
    jz .Ltd_force
    mov %r12, %rdi
    call *%rcx                      // stop(stage) (:339)
.Ltd_force:
    mov $CC_STATE_STOPPED, %esi
    mov %rsi, CC_SS_DESIRED(%r12)   // (:342)
    mov %rsi, CC_SS_ACTUAL(%r12)
    movq $0, CC_STG_INFLIGHT_SINCE(%r12)       // (:343)
    movq $0, CC_STG_INFLIGHT_SINCE+8(%r12)
.Ltd_next:
    add $CC_STG_SIZE, %r12
    inc %r13d
    jmp .Ltd_loop
.Ltd_notify:
    mov %rbx, %rdi
    call state_notify               // (:345)
    xor %eax, %eax
    EPILOGUE 5
    ret

// ============================================================================
// Module-local helpers
// ============================================================================

// ----------------------------------------------------------------------------
// state_apply_target — applyDesiredStageTarget (controller.go:269-285).
//   in:  rdi = ctrl, rsi = StageTarget ptr
//   out: rax = 0 / CC_STATE_ERR_PREREQ
//   Already desired -> log, no-op (:271-274).  Prerequisite (non-nil) must
//   return 0 else error, desired unchanged (:277-280).  Set desired, notify
//   (:282-283).
// ----------------------------------------------------------------------------
    .p2align 4
state_apply_target:
    PROLOGUE 5                      // %rbx=ctrl %r12=target %r13=stage
    mov %rdi, %rbx                  //   %r14=state
    mov %rsi, %r12
    mov CC_TGT_STAGE(%r12), %rdi
    call state_stage_entry          // stage (route targets validated at new)
    mov %rax, %r13
    mov CC_TGT_STATE(%r12), %r14
    mov CC_SS_DESIRED(%r13), %rsi
    cmp %r14, %rsi
    je .Lsat_already
    mov CC_TGT_PREREQ(%r12), %rdx
    test %rdx, %rdx
    jz .Lsat_set
    mov %rbx, %rdi
    call *%rdx                      // prerequisite(c) (:277)
    test %rax, %rax
    jnz .Lsat_prereq
.Lsat_set:
    mov %r14, CC_SS_DESIRED(%r13)   // (:282)
    mov %rbx, %rdi
    call state_notify               // (:283)
    xor %eax, %eax
    jmp .Lsat_ret
.Lsat_already:
    LEA rdi, state_s_log_already
    call cc_eputs                   // (:272)
    xor %eax, %eax
    jmp .Lsat_ret
.Lsat_prereq:
    LEA rdi, state_s_err_prereq
    call cc_eputs
    mov $-6, %eax                   // CC_STATE_ERR_PREREQ    (:279)
.Lsat_ret:
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// state_route_lookup_path — path-event route lookup (controller.go:231).
//   in:  rdi = ctrl, rsi = PathEvent ptr
//   out: rax = StageTarget ptr (entry + 16) / 0 on miss
//   Linear scan of the counted route table {count, {key0,key1,stage,state,
//   prereq} x count}; keys are trusted ids (parse-don't-validate).  Leaf:
//   no calls, so every register is caller-saved.
// ----------------------------------------------------------------------------
    .p2align 4
state_route_lookup_path:
    mov CC_CTR_PATH_EVENT_ROUTES(%rdi), %rdx   // %rdx=table %rcx=count %r8=i
    mov (%rdx), %rcx
    add $8, %rdx
    xor %r8d, %r8d
.Lrlp_loop:
    cmp %rcx, %r8
    jae .Lrlp_miss
    mov (%rdx), %r9                 // key0
    mov CC_PE_PATH(%rsi), %r10
    cmp %r10, %r9
    jne .Lrlp_next
    mov 8(%rdx), %r9                // key1
    mov CC_PE_STATUS(%rsi), %r10
    cmp %r10, %r9
    je .Lrlp_hit
.Lrlp_next:
    add $STATE_ROUTE_STRIDE, %rdx
    inc %r8
    jmp .Lrlp_loop
.Lrlp_hit:
    lea 16(%rdx), %rax              // &entry.StageTarget (CC_TGT_* offsets)
    jmp .Lrlp_ret
.Lrlp_miss:
    xor %eax, %eax
.Lrlp_ret:
    ret

// ----------------------------------------------------------------------------
// state_route_lookup_cmd — control-command route lookup (controller.go:218).
//   in:  rdi = ctrl, rsi = ControlCommand ptr
//   out: rax = StageTarget ptr (entry + 16) / 0 on miss
// ----------------------------------------------------------------------------
    .p2align 4
state_route_lookup_cmd:
    mov CC_CTR_COMMAND_ROUTES(%rdi), %rdx     // %rdx=table %rcx=count %r8=i
    mov (%rdx), %rcx
    add $8, %rdx
    xor %r8d, %r8d
.Lrlc_loop:
    cmp %rcx, %r8
    jae .Lrlc_miss
    mov (%rdx), %r9                 // key0
    mov CC_CMD_COMPONENT(%rsi), %r10
    cmp %r10, %r9
    jne .Lrlc_next
    mov 8(%rdx), %r9                // key1
    mov CC_CMD_ACTION(%rsi), %r10
    cmp %r10, %r9
    je .Lrlc_hit
.Lrlc_next:
    add $STATE_ROUTE_STRIDE, %rdx
    inc %r8
    jmp .Lrlc_loop
.Lrlc_hit:
    lea 16(%rdx), %rax
    jmp .Lrlc_ret
.Lrlc_miss:
    xor %eax, %eax
.Lrlc_ret:
    ret

// ----------------------------------------------------------------------------
// state_notify — notifyListeners (controller.go:263-267).
//   in:  rdi = ctrl
//   No listeners -> return (:264).  Snapshot via cc_state_status (:265),
//   then call every listener fn in slice order with the snapshot (:266).
// ----------------------------------------------------------------------------
    .p2align 4
state_notify:
    PROLOGUE 5                      // %rbx=ptr %r12=len %r13=status %r14=i
    mov CC_CTR_LISTENERS(%rdi), %rbx
    mov CC_CTR_LISTENERS+8(%rdi), %r12
    test %r12, %r12
    jz .Lnt_ret
    call cc_state_status            // %rdi = ctrl still (the snapshot)
    mov %rax, %r13
    xor %r14d, %r14d
.Lnt_loop:
    cmp %r12, %r14
    jae .Lnt_ret
    mov (%rbx,%r14,8), %r8          // %r8 = listener fn
    mov %r13, %rdi
    call *%r8                       // f(status) (:266)
    inc %r14
    jmp .Lnt_loop
.Lnt_ret:
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// state_stage_entry — stage id -> internal Stage entry ptr.
//   in:  rdi = CC_STAGE_* id   out: rax = entry / 0
//   state_stages: +0 count, +8 entry[CC_STAGE_COUNT] (CC_STG_SIZE each).
// ----------------------------------------------------------------------------
    .p2align 4
state_stage_entry:
    cmp $CC_STAGE_COUNT, %rdi
    jae .Lsse_bad
    mov %rdi, %rdx                  // id * 8 + id * 32 = id * 40 (CC_STG_SIZE)
    mov %rdx, %rsi
    shl $3, %rsi
    shl $5, %rdx
    add %rsi, %rdx
    LEA rsi, state_stages
    add $8, %rsi
    lea (%rsi,%rdx), %rax
    ret
.Lsse_bad:
    xor %eax, %eax
    ret

// ----------------------------------------------------------------------------
// state_path_entry — path id -> paths status entry ptr.
//   in:  rdi = CC_PATH_* id   out: rax = entry / 0
//   state_paths: +0 count, +8 entry[CC_PATH_COUNT] ({name, status}, 16 each).
//   (x86 scaled indexing tops out at *8, so id * 16 is a shift, not a scale.)
// ----------------------------------------------------------------------------
    .p2align 4
state_path_entry:
    cmp $CC_PATH_COUNT, %rdi
    jae .Lspe_bad
    LEA rsi, state_paths
    add $8, %rsi
    shl $4, %rdi                    // id * 16
    lea (%rsi,%rdi), %rax
    ret
.Lspe_bad:
    xor %eax, %eax
    ret

// ----------------------------------------------------------------------------
// state_prereq_ingress0_ready — the egress start prerequisite
// (main.go:179-183 createPathReadyPrerequisite).
//   in:  rdi = ctrl   out: rax = 0 (ready) / -1
//   c.paths[ingress0] must equal Ready.
// ----------------------------------------------------------------------------
    .p2align 4
state_prereq_ingress0_ready:
    LEA rsi, state_paths
    mov 16(%rsi), %rsi              // entry[0].status = ingress0 status
    cmp $CC_STATUS_READY, %rsi
    jne .Lpreq_fail
    xor %eax, %eax
    ret
.Lpreq_fail:
    mov $-1, %eax
    ret

// ----------------------------------------------------------------------------
// state_new_paths — seed the paths status table (main.go:174).
// ----------------------------------------------------------------------------
    .p2align 4
state_new_paths:
    LEA rsi, state_paths
    mov $CC_PATH_COUNT, %edx
    mov %rdx, (%rsi)
    LEA rdx, state_s_ingress0
    mov %rdx, 8(%rsi)
    mov $CC_STATUS_UNKNOWN, %edx
    mov %rdx, 16(%rsi)
    LEA rdx, state_s_normalized
    mov %rdx, 24(%rsi)
    mov $CC_STATUS_UNKNOWN, %edx
    mov %rdx, 32(%rsi)
    xor %eax, %eax
    ret

// ----------------------------------------------------------------------------
// state_new_stages — seed the internal stages table (main.go:204-220): per
// stage {desired, actual} from state_stage_seed, ops via cc_ctr_ops_for.
// ----------------------------------------------------------------------------
    .p2align 4
state_new_stages:
    PROLOGUE 3                      // %rbx=entry cursor %r12=id; temps in
    LEA rsi, state_stages           //   caller-saved regs
    mov $CC_STAGE_COUNT, %edx
    mov %rdx, (%rsi)
    lea 8(%rsi), %rbx
    LEA r8, state_stage_seed
    xor %r12d, %r12d
.Lnss_loop:
    cmp $CC_STAGE_COUNT, %r12d
    jae .Lnss_ops
    mov (%r8), %r9                  // ldr x4, [x3], #8
    add $8, %r8
    mov %r9, CC_SS_DESIRED(%rbx)
    mov (%r8), %r9
    add $8, %r8
    mov %r9, CC_SS_ACTUAL(%rbx)
    add $CC_STG_SIZE, %rbx
    inc %r12d
    jmp .Lnss_loop
.Lnss_ops:
    LEA rbx, state_stages
    add $8, %rbx
    xor %r12d, %r12d
.Lnss_op:
    cmp $CC_STAGE_COUNT, %r12d
    jae .Lnss_done
    mov %r12, %rdi
    call cc_ctr_ops_for
    mov %rax, CC_STG_OPS(%rbx)
    add $CC_STG_SIZE, %rbx
    inc %r12d
    jmp .Lnss_op
.Lnss_done:
    xor %eax, %eax
    EPILOGUE 3
    ret

// ============================================================================
// RODATA — name strings, seed data, route tables, log/error strings.
// ============================================================================
    RODATA

// ---- status table name strings (the map keys; JSON_S_* = single source) ----
state_s_ingress0:
    .asciz JSON_S_INGRESS0
state_s_normalized:
    .asciz JSON_S_NORMALIZED
state_s_mediamtx:
    .asciz JSON_S_MEDIAMTX
state_s_normalize:
    .asciz JSON_S_NORMALIZE
state_s_scale:
    .asciz JSON_S_SCALE_AND_EGRESS
state_s_single:
    .asciz JSON_S_SINGLE_STAGE_EGRESS

// ---- stage-name table (stage id -> name; cc_state_status's wire names) ----
state_stage_names:
    .quad state_s_mediamtx          // CC_STAGE_MEDIAMTX
    .quad state_s_normalize         // CC_STAGE_NORMALIZE
    .quad state_s_scale             // CC_STAGE_SCALE_AND_EGRESS
    .quad state_s_single            // CC_STAGE_SINGLE_STAGE_EGRESS

// ---- per-stage {desired, actual} seeds (main.go:204-220) ----
state_stage_seed:
    .quad CC_STATE_RUNNING, CC_STATE_STOPPED    // mediamtx (main.go:205-207)
    .quad CC_STATE_STOPPED, CC_STATE_STOPPED    // normalize (:208-211)
    .quad CC_STATE_STOPPED, CC_STATE_STOPPED    // scale_and_egress (:212-215)
    .quad CC_STATE_STOPPED, CC_STATE_STOPPED    // single_stage_egress (:216-219)

// ---- route tables: .quad count, then STATE_ROUTE_STRIDE-byte entries
//      {key0, key1, target.stage, target.state, target.prereq} ----
    .macro STATE_ROUTE key0, key1, stage, state, prereq
    .quad \key0
    .quad \key1
    .quad \stage
    .quad \state
    .quad \prereq
    .endm
state_path_routes:                  // non-single-stage (main.go:193-194)
    .quad 2
    STATE_ROUTE CC_PATH_INGRESS0, CC_STATUS_READY,    CC_STAGE_NORMALIZE, CC_STATE_RUNNING, 0
    STATE_ROUTE CC_PATH_INGRESS0, CC_STATUS_NOTREADY, CC_STAGE_NORMALIZE, CC_STATE_STOPPED, 0
state_path_routes_none:             // single-stage mode: no path-event routes
    .quad 0
state_command_routes:               // non-single-stage (main.go:196-201)
    .quad 2
    STATE_ROUTE CC_COMPONENT_EGRESS, CC_ACTION_START, CC_STAGE_SCALE_AND_EGRESS, CC_STATE_RUNNING, state_prereq_ingress0_ready
    STATE_ROUTE CC_COMPONENT_EGRESS, CC_ACTION_STOP,  CC_STAGE_SCALE_AND_EGRESS, CC_STATE_STOPPED, 0
state_command_routes_single:        // single-stage mode (main.go:186-191)
    .quad 2
    STATE_ROUTE CC_COMPONENT_EGRESS, CC_ACTION_START, CC_STAGE_SINGLE_STAGE_EGRESS, CC_STATE_RUNNING, state_prereq_ingress0_ready
    STATE_ROUTE CC_COMPONENT_EGRESS, CC_ACTION_STOP,  CC_STAGE_SINGLE_STAGE_EGRESS, CC_STATE_STOPPED, 0

// ---- log / error strings (stderr via cc_eputs; fail-loud) ----
state_s_log_timeout:
    .asciz "reconcile: op timed out\n"          // controller.go:296
state_s_log_failed:
    .asciz "reconcile: op failed\n"             // controller.go:309
state_s_log_already:
    .asciz "stage already desired\n"            // controller.go:272
state_s_err_badpath:
    .asciz "error: invalid path name\n"         // controller.go:225
state_s_err_badstatus:
    .asciz "error: invalid path status\n"       // controller.go:226
state_s_err_badstage:
    .asciz "error: invalid stage name\n"        // controller.go:238
state_s_err_badstate:
    .asciz "error: invalid stage state\n"       // controller.go:239
state_s_err_noctrl:
    .asciz "error: control not implemented\n"   // controller.go:219
state_s_err_prereq:
    .asciz "error: prerequisite not satisfied\n" // controller.go:279
state_s_err_notreg:
    .asciz "error: listener not registered\n"   // controller.go:260
state_s_err_timeout:
    .asciz "error: inflight timeout must be > 0\n" // controller.go:162-164

// ============================================================================
// BSS — the Controller struct, the state tables, listener storage.
// (Single-threaded controller: one set of tables, one Controller.)
// ============================================================================
    .bss
    .p2align 3
state_ctrl:
    .space CC_CTR_SIZE
state_paths:
    .space 8 + CC_PATH_COUNT * 16          // count + {name, status} entries
state_stages:
    .space 8 + CC_STAGE_COUNT * CC_STG_SIZE
state_status:
    .space CC_CS_SIZE
state_status_stages:
    .space 8 + CC_STAGE_COUNT * CC_JSON_STBL_ENTRY
state_listeners:
    .space 8 * STATE_LISTENERS_MAX

    .end