// ============================================================================
// cc_state.S — STATE MACHINE / reconcile / listener / event-routing for the
// strimserver controller
// ============================================================================
//
//  Target:     AArch64 (ARMv8.2-A), little-endian — Linux (ELF, static);
//              cc_platform.h is the only platform header (Linux-only).
//  Assembler:  GNU as syntax, preprocessed by the C compiler
//              (`cc -c -x assembler-with-cpp`).
//  ISA:        .arch armv8.2-a — exactly one in-source directive (below),
//              nothing higher, no .arch_extension, no .cpu (Graviton2 parity).
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
//  Exported (all .global, AAPCS64, x19-x28 preserved; <= 80 instructions):
//    cc_state_new(x0=layout)                  -> x0 = 0 / CC_STATE_ERR_*
//    cc_state_ctrl()                          -> x0 = &Controller (state_ctrl)
//    cc_state_stage(x0=stage_id)              -> x0 = Stage entry ptr / 0
//    cc_state_path(x0=path_id)                -> x0 = paths entry ptr / 0
//    cc_state_run(x0=ctrl)                    -> x0 = 0   (Run, :178-180)
//    cc_state_reconcile(x0=ctrl)              -> x0 = 0   (handleReconcile)
//    cc_state_handle_path_event(x0=ctrl, x1=PathEvent)   -> x0 = 0 / err
//    cc_state_handle_stage_event(x0=ctrl, x1=StageEvent) -> x0 = 0 / err
//    cc_state_handle_control(x0=ctrl, x1=ControlCommand)-> x0 = 0 / err
//    cc_state_add_listener(x0=ctrl, x1=fn)    -> x0 = 0 / err
//    cc_state_remove_listener(x0=ctrl, x1=fn) -> x0 = 0 / err
//    cc_state_status(x0=ctrl)                 -> x0 = &ControllerStatus
//    cc_state_teardown(x0=ctrl)               -> x0 = 0   (Teardown)
//    cc_state_close(x0=ctrl)                  -> x0 = 0   (Close, :350)
//
//  Module-local helpers (state_*, full AAPCS64 obligations):
//    state_reconcile_one(x0=ctrl, x1=stage, x2=timeout)      one stage
//    state_apply_target(x0=ctrl, x1=StageTarget)             applyDesiredStageTarget
//    state_route_lookup_path(x0=ctrl, x1=PathEvent) -> x0 = StageTarget / 0
//    state_route_lookup_cmd(x0=ctrl, x1=ControlCommand) -> x0 = StageTarget / 0
//    state_notify(x0=ctrl)                                  notifyListeners
//    state_stage_entry(x0=stage_id) -> x0 = Stage ptr / 0
//    state_path_entry(x0=path_id) -> x0 = paths entry ptr / 0
//    state_prereq_ingress0_ready(x0=ctrl) -> x0 = 0 / -1
//    state_new_paths(x0=layout)
//    state_new_stages(x0=layout)
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
#include "cc_json.h"
#include "cc_state.h"
    .arch armv8.2-a
    .text

// ============================================================================
// cc_state_new — construct and seed the Controller (NewController,
// controller.go:105-176 + the main.go:174-229 wiring).
//   in:  x0 = Layout ptr (the env-runtime block sits at Layout + CC_LAY_SIZE;
//        cc_env_load filled CC_ER_* there — cc_env.h/cc_layout.inc)
//   out: x0 = 0 / CC_STATE_ERR_TIMEOUT
//   Zeroes the Controller struct, points the paths/stages/listener fields at
//   the module's .bss tables, reads the inflight timeout and the
//   single-stage flag from the env block, selects the route tables, and
//   seeds the paths/stages tables (state_new_paths / state_new_stages).
// ============================================================================
    .p2align 2
    .global cc_state_new
    FUNC_TYPE(cc_state_new)
cc_state_new:
    PROLOGUE 3                      // x19=layout x20=ctrl x21-x23 temps
    mov x19, x0
    LEA x20, state_ctrl
    mov x21, #0
.Lnew_zero:                         // zero the Controller struct (idempotent
    str xzr, [x20, x21]             //   even though .bss starts zeroed)
    add x21, x21, #8
    cmp x21, #CC_CTR_SIZE
    b.lo .Lnew_zero
    LEA x21, state_paths
    str x21, [x20, #CC_CTR_PATHS]
    LEA x21, state_stages
    str x21, [x20, #CC_CTR_STAGES]
    LEA x21, state_listeners
    str x21, [x20, #CC_CTR_LISTENERS]
    mov x21, #STATE_LISTENERS_MAX
    str x21, [x20, #CC_CTR_LISTENERS + 16]
    add x21, x19, #CC_LAY_SIZE      // env-runtime block
    ldr x22, [x21, #CC_ER_INFLIGHT_TIMEOUT]
    cbz x22, .Lnew_bad_timeout      // controller.go:162-164
    str x22, [x20, #CC_CTR_INFLIGHT_TIMEOUT]
    ldrb w23, [x21, #CC_ER_ENABLE_SINGLE_STAGE]
    cbnz w23, .Lnew_single
    LEA x23, state_path_routes      // non-single routes (main.go:193-201)
    str x23, [x20, #CC_CTR_PATH_EVENT_ROUTES]
    LEA x23, state_command_routes
    str x23, [x20, #CC_CTR_COMMAND_ROUTES]
    b .Lnew_tables
.Lnew_single:
    LEA x23, state_path_routes_none // single-stage routes (main.go:186-191)
    str x23, [x20, #CC_CTR_PATH_EVENT_ROUTES]
    LEA x23, state_command_routes_single
    str x23, [x20, #CC_CTR_COMMAND_ROUTES]
.Lnew_tables:
    mov x0, x19
    bl state_new_paths
    mov x0, x19
    bl state_new_stages
    mov x0, #0
    b .Lnew_ret
.Lnew_bad_timeout:
    LEA x0, state_s_err_timeout
    bl cc_eputs
    mov x0, #CC_STATE_ERR_TIMEOUT
.Lnew_ret:
    EPILOGUE 3
    ret

// ============================================================================
// cc_state_ctrl — the Controller pointer accessor (the controller lives in
// .bss; the handler functions take it as x0, cc_http.S/cc_main.S obtain it
// here).
// ============================================================================
    .p2align 2
    .global cc_state_ctrl
    FUNC_TYPE(cc_state_ctrl)
cc_state_ctrl:
    LEA x0, state_ctrl
    ret

// ============================================================================
// cc_state_stage / cc_state_path — id -> table entry accessors.
// ============================================================================
    .p2align 2
    .global cc_state_stage
    FUNC_TYPE(cc_state_stage)
cc_state_stage:
    b state_stage_entry

    .p2align 2
    .global cc_state_path
    FUNC_TYPE(cc_state_path)
cc_state_path:
    b state_path_entry

// ============================================================================
// cc_state_run — port of Run (controller.go:178-180).
//   in:  x0 = ctrl   out: x0 = 0
//   Go drains the actions channel, running each submitted action on the
//   controller goroutine.  The single-threaded port has no channel: every
//   Submit* handler runs synchronously at its call site, so the drain loop
//   is empty.  Provided for API parity with main.go:315 (go controller.Run()).
// ============================================================================
    .p2align 2
    .global cc_state_run
    FUNC_TYPE(cc_state_run)
cc_state_run:
    mov x0, #0
    ret

// ============================================================================
// cc_state_close — port of Close (controller.go:350).
//   in:  x0 = ctrl   out: x0 = 0
//   Go closes the actions channel, terminating Run; there is no channel to
//   close in the synchronous port.
// ============================================================================
    .p2align 2
    .global cc_state_close
    FUNC_TYPE(cc_state_close)
cc_state_close:
    mov x0, #0
    ret

// ============================================================================
// cc_state_reconcile — the reconcile loop (handleReconcile,
// controller.go:287-314).  Iterates the stages table in id order (Go's map
// order is unspecified; the port fixes id order for determinism), delegating
// each stage to state_reconcile_one.
// ============================================================================
    .p2align 2
    .global cc_state_reconcile
    FUNC_TYPE(cc_state_reconcile)
cc_state_reconcile:
    PROLOGUE 2                      // x19=ctrl x20=timeout x21=stage x22=id
    mov x19, x0
    ldr x20, [x19, #CC_CTR_INFLIGHT_TIMEOUT]
    LEA x21, state_stages
    add x21, x21, #8                // first stage entry
    mov x22, #0
.Lrec_loop:
    cmp x22, #CC_STAGE_COUNT
    b.hs .Lrec_done
    mov x0, x19
    mov x1, x21
    mov x2, x20
    bl state_reconcile_one
    add x21, x21, #CC_STG_SIZE
    add x22, x22, #1
    b .Lrec_loop
.Lrec_done:
    mov x0, #0
    EPILOGUE 2
    ret

// ============================================================================
// state_reconcile_one — reconcile a single stage (handleReconcile
// controller.go:287-314 + planReconcile :316-320).
//   in:  x0 = ctrl, x1 = stage entry, x2 = inflight timeout
//   out: x0 = 0
//   Converged stages clear in-flight (:292).  Non-converged stages plan a
//   target: not in flight -> desired now; in flight and within the budget ->
//   NoTarget (skip); in flight and timed out -> desired again (retry).  The
//   op runs via cc_ctr_apply (sets in-flight on start, clears it on error —
//   cc_ctr.S).  Actual is folded from the op result (deviation, see header):
//   0 -> target, error -> Stopped; a transition fires notifyListeners.
// ============================================================================
state_reconcile_one:
    PROLOGUE 3                      // x19=ctrl x20=stage x21=timeout
    mov x19, x0                     //   x22=desired x23=actual
    mov x20, x1
    mov x21, x2
    ldr x22, [x20, #CC_SS_DESIRED]
    ldr x23, [x20, #CC_SS_ACTUAL]
    cmp x22, x23
    b.ne .Lro_plan
    mov x0, x20
    bl cc_ctr_inflight_clear        // converged (controller.go:292)
    mov x0, #0
    b .Lro_ret
.Lro_plan:
    mov x0, x20
    bl cc_ctr_inflight_active       // planReconcile (controller.go:316-320)
    cbz x0, .Lro_apply              // not in flight -> run now
    mov x0, x20
    mov x1, x21
    bl cc_ctr_inflight_timed_out
    cbnz x0, .Lro_timeout           // in flight AND timed out -> retry
    mov x0, #0
    b .Lro_ret                      // in flight, in budget -> NoTarget (:318)
.Lro_timeout:
    LEA x0, state_s_log_timeout
    bl cc_eputs                     // log (controller.go:296)
.Lro_apply:
    mov x0, x20
    mov x1, x22                     // target = desired
    bl cc_ctr_apply                 // the op (controller.go:298-312)
    cbnz x0, .Lro_failed
    mov x23, x22                    // success: Actual = target (deviation)
    b .Lro_store
.Lro_failed:
    LEA x0, state_s_log_failed
    bl cc_eputs                     // log (controller.go:309)
    mov x23, #CC_STATE_STOPPED      // failure: Actual = Stopped (deviation)
.Lro_store:
    ldr x0, [x20, #CC_SS_ACTUAL]
    cmp x0, x23
    b.eq .Lro_ret                   // no transition -> no notify
    str x23, [x20, #CC_SS_ACTUAL]
    mov x0, x19
    bl state_notify                 // fire on transitions (Go fires from the
    mov x0, #0                      //   stage event instead, :246 — deviation)
.Lro_ret:
    EPILOGUE 3
    ret

// ============================================================================
// cc_state_handle_path_event — handlePathEvent (controller.go:223-234).
//   in:  x0 = ctrl, x1 = PathEvent ptr {CC_PE_PATH, CC_PE_STATUS}
//   out: x0 = 0 / CC_STATE_ERR_BADPATH / CC_STATE_ERR_BADSTATUS
//   Unknown path id or invalid status id -> error (Go's map lookup + Valid);
//   otherwise store the status, route {path,status} -> StageTarget, and
//   apply the target (no route -> nil, like Go's `if !ok { return nil }`).
// ============================================================================
    .p2align 2
    .global cc_state_handle_path_event
    FUNC_TYPE(cc_state_handle_path_event)
cc_state_handle_path_event:
    PROLOGUE 2                      // x19=ctrl x20=event x21=entry x22=status
    mov x19, x0
    mov x20, x1
    ldr x0, [x20, #CC_PE_PATH]
    bl state_path_entry
    cbz x0, .Lhpe_badpath           // unknown path (controller.go:224-225)
    mov x21, x0
    ldr x22, [x20, #CC_PE_STATUS]
    cmp x22, #CC_STATUS_COUNT
    b.hs .Lhpe_badstatus            // invalid status (:226)
    str x22, [x21, #8]              // store the status (:230)
    mov x0, x19
    mov x1, x20
    bl state_route_lookup_path
    cbz x0, .Lhpe_ok                // no route -> nil (:232)
    mov x1, x0
    mov x0, x19
    bl state_apply_target           // (:233)
    b .Lhpe_ret
.Lhpe_badpath:
    LEA x0, state_s_err_badpath
    bl cc_eputs
    mov x0, #CC_STATE_ERR_BADPATH
    b .Lhpe_ret
.Lhpe_badstatus:
    LEA x0, state_s_err_badstatus
    bl cc_eputs
    mov x0, #CC_STATE_ERR_BADSTATUS
    b .Lhpe_ret
.Lhpe_ok:
    mov x0, #0
.Lhpe_ret:
    EPILOGUE 2
    ret

// ============================================================================
// cc_state_handle_stage_event — handleStageEvent (controller.go:236-248).
//   in:  x0 = ctrl, x1 = StageEvent ptr {CC_SE_STAGE, CC_SE_STATE}
//   out: x0 = 0 / CC_STATE_ERR_BADSTAGE / CC_STATE_ERR_BADSTATE
//   Unknown stage id or invalid state id -> error; otherwise store Actual,
//   clear InFlightSince ALWAYS (:245), and notify iff Actual changed (:246).
// ============================================================================
    .p2align 2
    .global cc_state_handle_stage_event
    FUNC_TYPE(cc_state_handle_stage_event)
cc_state_handle_stage_event:
    PROLOGUE 2                      // x19=ctrl x20=event x21=stage x22=state
    mov x19, x0
    mov x20, x1
    ldr x0, [x20, #CC_SE_STAGE]
    bl state_stage_entry
    cbz x0, .Lhse_badstage          // unknown stage (controller.go:237-238)
    mov x21, x0
    ldr x22, [x20, #CC_SE_STATE]
    cmp x22, #CC_STATE_COUNT
    b.hs .Lhse_badstate             // invalid state (:239)
    ldr x1, [x21, #CC_SS_ACTUAL]
    cmp x1, x22
    cset x2, ne                     // changed (:243)
    str x22, [x21, #CC_SS_ACTUAL]   // (:244)
    mov x0, x21
    bl cc_ctr_inflight_clear        // (:245)
    cbz x2, .Lhse_ok                // notify only on change (:246)
    mov x0, x19
    bl state_notify
.Lhse_ok:
    mov x0, #0
    b .Lhse_ret
.Lhse_badstage:
    LEA x0, state_s_err_badstage
    bl cc_eputs
    mov x0, #CC_STATE_ERR_BADSTAGE
    b .Lhse_ret
.Lhse_badstate:
    LEA x0, state_s_err_badstate
    bl cc_eputs
    mov x0, #CC_STATE_ERR_BADSTATE
.Lhse_ret:
    EPILOGUE 2
    ret

// ============================================================================
// cc_state_handle_control — handleControl (controller.go:216-221).
//   in:  x0 = ctrl, x1 = ControlCommand ptr {CC_CMD_COMPONENT, CC_CMD_ACTION}
//   out: x0 = 0 / CC_STATE_ERR_NOCTRL
//   Route lookup {component,action}; a miss is "control not implemented"
//   (:218-219) — Go never validates component/action, and an unrecognized id
//   (CC_JSON_ID_UNKNOWN) simply misses, exactly like Go's unrecognized
//   string key.
// ============================================================================
    .p2align 2
    .global cc_state_handle_control
    FUNC_TYPE(cc_state_handle_control)
cc_state_handle_control:
    PROLOGUE 1                      // x19=ctrl x20=cmd
    mov x19, x0
    mov x20, x1
    mov x0, x19
    mov x1, x20
    bl state_route_lookup_cmd
    cbz x0, .Lhc_miss               // controller.go:218-219
    mov x1, x0
    mov x0, x19
    bl state_apply_target
    b .Lhc_ret
.Lhc_miss:
    LEA x0, state_s_err_noctrl
    bl cc_eputs
    mov x0, #CC_STATE_ERR_NOCTRL
.Lhc_ret:
    EPILOGUE 1
    ret

// ============================================================================
// cc_state_add_listener — handleAddListener (controller.go:250-254).
//   in:  x0 = ctrl, x1 = listener fn ptr (ControllerListener port)
//   out: x0 = 0 / CC_STATE_ERR_NIL / CC_STATE_ERR_FULL
//   Appends the fn to the listener slice and fires it once with the current
//   status (:253).  Go's slice grows without bound; the fixed-cap port fails
//   loud at STATE_LISTENERS_MAX.
// ============================================================================
    .p2align 2
    .global cc_state_add_listener
    FUNC_TYPE(cc_state_add_listener)
cc_state_add_listener:
    PROLOGUE 3                      // x19=ctrl x20=fn x21=ptr x22=len x23=cap
    mov x19, x0
    mov x20, x1
    cbz x20, .Ladd_nil              // controller.go:251
    ldr x21, [x19, #CC_CTR_LISTENERS]
    ldr x22, [x19, #CC_CTR_LISTENERS + 8]
    ldr x23, [x19, #CC_CTR_LISTENERS + 16]
    cmp x22, x23
    b.hs .Ladd_full                 // fixed capacity — fail-loud
    str x20, [x21, x22, lsl #3]     // append (:252)
    add x22, x22, #1
    str x22, [x19, #CC_CTR_LISTENERS + 8]
    mov x0, x19
    bl cc_state_status              // f := *l; f(status) (:253)
    blr x20
    mov x0, #0
    b .Ladd_ret
.Ladd_nil:
    mov x0, #CC_STATE_ERR_NIL
    b .Ladd_ret
.Ladd_full:
    mov x0, #CC_STATE_ERR_FULL
.Ladd_ret:
    EPILOGUE 3
    ret

// ============================================================================
// cc_state_remove_listener — handleRemoveListener (controller.go:256-261).
//   in:  x0 = ctrl, x1 = listener fn ptr
//   out: x0 = 0 / CC_STATE_ERR_NOTREG
//   Scans by pointer, splices the slot (append(s[:i], s[i+1:]...), :258),
//   decrements len; a miss is "listener not registered" (:260).
// ============================================================================
    .p2align 2
    .global cc_state_remove_listener
    FUNC_TYPE(cc_state_remove_listener)
cc_state_remove_listener:
    PROLOGUE 3                      // x19=ctrl x20=fn x21=ptr x22=len x23=i
    mov x19, x0                     //   x24=tmp
    mov x20, x1
    ldr x21, [x19, #CC_CTR_LISTENERS]
    ldr x22, [x19, #CC_CTR_LISTENERS + 8]
    mov x23, #0
.Lrem_loop:
    cmp x23, x22
    b.hs .Lrem_notfound
    ldr x24, [x21, x23, lsl #3]
    cmp x24, x20
    b.eq .Lrem_found
    add x23, x23, #1
    b .Lrem_loop
.Lrem_found:
    add x1, x23, #1                 // src = i+1
    cmp x1, x22
    b.hs .Lrem_done                 // last slot: nothing to shift
.Lrem_shift:
    ldr x24, [x21, x1, lsl #3]
    str x24, [x21, x23, lsl #3]
    add x23, x23, #1
    add x1, x1, #1
    cmp x1, x22
    b.lo .Lrem_shift
.Lrem_done:
    sub x22, x22, #1
    str x22, [x19, #CC_CTR_LISTENERS + 8]
    mov x0, #0
    b .Lrem_ret
.Lrem_notfound:
    LEA x0, state_s_err_notreg
    bl cc_eputs
    mov x0, #CC_STATE_ERR_NOTREG    // controller.go:260
.Lrem_ret:
    EPILOGUE 3
    ret

// ============================================================================
// cc_state_status — handleStatus (controller.go:322-327).
//   in:  x0 = ctrl (unused — parity)
//   out: x0 = &ControllerStatus {paths, stages} in the cc_json_status wire
//   format (cc_json.h CC_JSON_PTBL_ENTRY / CC_JSON_STBL_ENTRY, ascending
//   name order).  Go clones the maps (async safety); the single-threaded
//   port shares the live paths table and rebuilds the stages wire table
//   from the internal Stage array + the rodata name table (deviation,
//   documented in the header).
// ============================================================================
    .p2align 2
    .global cc_state_status
    FUNC_TYPE(cc_state_status)
cc_state_status:
    LEA x0, state_status
    LEA x1, state_paths
    str x1, [x0, #CC_CS_PATHS]
    LEA x1, state_status_stages
    mov x2, #CC_STAGE_COUNT
    str x2, [x1]                    // wire count
    add x1, x1, #8
    LEA x3, state_stage_names       // name table (rodata, by stage id)
    LEA x4, state_stages
    add x4, x4, #8                  // internal Stage array
    mov x5, #0
.Lss_loop:
    cmp x5, #CC_STAGE_COUNT
    b.hs .Lss_done
    ldr x6, [x3, x5, lsl #3]
    str x6, [x1, #0]                // wire name
    ldr x6, [x4, #CC_SS_DESIRED]
    str x6, [x1, #8]
    ldr x6, [x4, #CC_SS_ACTUAL]
    str x6, [x1, #16]
    add x1, x1, #CC_JSON_STBL_ENTRY
    add x4, x4, #CC_STG_SIZE
    add x5, x5, #1
    b .Lss_loop
.Lss_done:
    LEA x1, state_status_stages
    str x1, [x0, #CC_CS_STAGES]
    ret

// ============================================================================
// cc_state_teardown — Teardown (controller.go:331-348).
//   in:  x0 = ctrl   out: x0 = 0
//   For every stage with Actual == Running: run ops[Stopped] (Go logs a stop
//   failure, :340), then set Desired = Actual = Stopped and clear
//   InFlightSince (:342-343).  Notify once (:345).
// ============================================================================
    .p2align 2
    .global cc_state_teardown
    FUNC_TYPE(cc_state_teardown)
cc_state_teardown:
    PROLOGUE 2                      // x19=ctrl x20=stage x21=id
    mov x19, x0
    LEA x20, state_stages
    add x20, x20, #8
    mov x21, #0
.Ltd_loop:
    cmp x21, #CC_STAGE_COUNT
    b.hs .Ltd_notify
    ldr x1, [x20, #CC_SS_ACTUAL]
    cmp x1, #CC_STATE_RUNNING
    b.ne .Ltd_next                  // only running stages (controller.go:335)
    ldr x2, [x20, #CC_STG_OPS]
    ldr x3, [x2, #CC_STATE_STOPPED * 8]  // ops[Stopped] (:336)
    cbz x3, .Ltd_force
    mov x0, x20
    blr x3                          // stop(stage) (:339)
.Ltd_force:
    mov x1, #CC_STATE_STOPPED
    str x1, [x20, #CC_SS_DESIRED]   // (:342)
    str x1, [x20, #CC_SS_ACTUAL]
    str xzr, [x20, #CC_STG_INFLIGHT_SINCE]       // (:343)
    str xzr, [x20, #CC_STG_INFLIGHT_SINCE + 8]
.Ltd_next:
    add x20, x20, #CC_STG_SIZE
    add x21, x21, #1
    b .Ltd_loop
.Ltd_notify:
    mov x0, x19
    bl state_notify                 // (:345)
    mov x0, #0
    EPILOGUE 2
    ret

// ============================================================================
// Module-local helpers
// ============================================================================

// ----------------------------------------------------------------------------
// state_apply_target — applyDesiredStageTarget (controller.go:269-285).
//   in:  x0 = ctrl, x1 = StageTarget ptr
//   out: x0 = 0 / CC_STATE_ERR_PREREQ
//   Already desired -> log, no-op (:271-274).  Prerequisite (non-nil) must
//   return 0 else error, desired unchanged (:277-280).  Set desired, notify
//   (:282-283).
// ----------------------------------------------------------------------------
state_apply_target:
    PROLOGUE 2                      // x19=ctrl x20=target x21=stage x22=state
    mov x19, x0
    mov x20, x1
    ldr x0, [x20, #CC_TGT_STAGE]
    bl state_stage_entry            // stage (route targets validated at new)
    mov x21, x0
    ldr x22, [x20, #CC_TGT_STATE]
    ldr x1, [x21, #CC_SS_DESIRED]
    cmp x1, x22
    b.eq .Lsat_already
    ldr x2, [x20, #CC_TGT_PREREQ]
    cbz x2, .Lsat_set
    mov x0, x19
    blr x2                          // prerequisite(c) (:277)
    cbnz x0, .Lsat_prereq
.Lsat_set:
    str x22, [x21, #CC_SS_DESIRED]  // (:282)
    mov x0, x19
    bl state_notify                 // (:283)
    mov x0, #0
    b .Lsat_ret
.Lsat_already:
    LEA x0, state_s_log_already
    bl cc_eputs                     // (:272)
    mov x0, #0
    b .Lsat_ret
.Lsat_prereq:
    LEA x0, state_s_err_prereq
    bl cc_eputs
    mov x0, #CC_STATE_ERR_PREREQ    // (:279)
.Lsat_ret:
    EPILOGUE 2
    ret

// ----------------------------------------------------------------------------
// state_route_lookup_path — path-event route lookup (controller.go:231).
//   in:  x0 = ctrl, x1 = PathEvent ptr
//   out: x0 = StageTarget ptr (entry + 16) / 0 on miss
//   Linear scan of the counted route table {count, {key0,key1,stage,state,
//   prereq} x count}; keys are trusted ids (parse-don't-validate).
// ----------------------------------------------------------------------------
state_route_lookup_path:
    PROLOGUE 3                      // x19=ctrl x20=event x21=table x22=count
    mov x19, x0                     //   x23=i
    mov x20, x1
    ldr x21, [x19, #CC_CTR_PATH_EVENT_ROUTES]
    ldr x22, [x21]
    add x21, x21, #8
    mov x23, #0
.Lrlp_loop:
    cmp x23, x22
    b.hs .Lrlp_miss
    ldr x2, [x21, #0]
    ldr x3, [x20, #CC_PE_PATH]
    cmp x2, x3
    b.ne .Lrlp_next
    ldr x2, [x21, #8]
    ldr x3, [x20, #CC_PE_STATUS]
    cmp x2, x3
    b.eq .Lrlp_hit
.Lrlp_next:
    add x21, x21, #STATE_ROUTE_STRIDE
    add x23, x23, #1
    b .Lrlp_loop
.Lrlp_hit:
    add x0, x21, #16                // &entry.StageTarget (CC_TGT_* offsets)
    b .Lrlp_ret
.Lrlp_miss:
    mov x0, #0
.Lrlp_ret:
    EPILOGUE 3
    ret

// ----------------------------------------------------------------------------
// state_route_lookup_cmd — control-command route lookup (controller.go:218).
//   in:  x0 = ctrl, x1 = ControlCommand ptr
//   out: x0 = StageTarget ptr (entry + 16) / 0 on miss
// ----------------------------------------------------------------------------
state_route_lookup_cmd:
    PROLOGUE 3                      // x19=ctrl x20=cmd x21=table x22=count
    mov x19, x0                     //   x23=i
    mov x20, x1
    ldr x21, [x19, #CC_CTR_COMMAND_ROUTES]
    ldr x22, [x21]
    add x21, x21, #8
    mov x23, #0
.Lrlc_loop:
    cmp x23, x22
    b.hs .Lrlc_miss
    ldr x2, [x21, #0]
    ldr x3, [x20, #CC_CMD_COMPONENT]
    cmp x2, x3
    b.ne .Lrlc_next
    ldr x2, [x21, #8]
    ldr x3, [x20, #CC_CMD_ACTION]
    cmp x2, x3
    b.eq .Lrlc_hit
.Lrlc_next:
    add x21, x21, #STATE_ROUTE_STRIDE
    add x23, x23, #1
    b .Lrlc_loop
.Lrlc_hit:
    add x0, x21, #16
    b .Lrlc_ret
.Lrlc_miss:
    mov x0, #0
.Lrlc_ret:
    EPILOGUE 3
    ret

// ----------------------------------------------------------------------------
// state_notify — notifyListeners (controller.go:263-267).
//   in:  x0 = ctrl
//   No listeners -> return (:264).  Snapshot via cc_state_status (:265),
//   then call every listener fn in slice order with the snapshot (:266).
// ----------------------------------------------------------------------------
state_notify:
    PROLOGUE 3                      // x19=ctrl x20=ptr x21=len x22=status
    mov x19, x0                     //   x23=i x24=fn
    ldr x20, [x19, #CC_CTR_LISTENERS]
    ldr x21, [x19, #CC_CTR_LISTENERS + 8]
    cbz x21, .Lnt_ret
    mov x0, x19
    bl cc_state_status
    mov x22, x0
    mov x23, #0
.Lnt_loop:
    cmp x23, x21
    b.hs .Lnt_ret
    ldr x24, [x20, x23, lsl #3]
    mov x0, x22
    blr x24                         // f(status) (:266)
    add x23, x23, #1
    b .Lnt_loop
.Lnt_ret:
    EPILOGUE 3
    ret

// ----------------------------------------------------------------------------
// state_stage_entry — stage id -> internal Stage entry ptr.
//   in:  x0 = CC_STAGE_* id   out: x0 = entry / 0
//   state_stages: +0 count, +8 entry[CC_STAGE_COUNT] (CC_STG_SIZE each).
// ----------------------------------------------------------------------------
state_stage_entry:
    cmp x0, #CC_STAGE_COUNT
    b.hs .Lsse_bad
    mov x2, x0
    lsl x1, x2, #3                  // id * 8
    lsl x2, x2, #5                  // id * 32
    add x2, x1, x2                  // id * 40 (CC_STG_SIZE)
    LEA x1, state_stages
    add x1, x1, #8
    add x0, x1, x2
    ret
.Lsse_bad:
    mov x0, #0
    ret

// ----------------------------------------------------------------------------
// state_path_entry — path id -> paths status entry ptr.
//   in:  x0 = CC_PATH_* id   out: x0 = entry / 0
//   state_paths: +0 count, +8 entry[CC_PATH_COUNT] ({name, status}, 16 each).
// ----------------------------------------------------------------------------
state_path_entry:
    cmp x0, #CC_PATH_COUNT
    b.hs .Lspe_bad
    LEA x1, state_paths
    add x1, x1, #8
    add x0, x1, x0, lsl #4          // base + id * 16
    ret
.Lspe_bad:
    mov x0, #0
    ret

// ----------------------------------------------------------------------------
// state_prereq_ingress0_ready — the egress start prerequisite
// (main.go:179-183 createPathReadyPrerequisite).
//   in:  x0 = ctrl   out: x0 = 0 (ready) / -1
//   c.paths[ingress0] must equal Ready.
// ----------------------------------------------------------------------------
state_prereq_ingress0_ready:
    LEA x1, state_paths
    ldr x1, [x1, #16]               // entry[0].status = ingress0 status
    cmp x1, #CC_STATUS_READY
    b.ne .Lpreq_fail
    mov x0, #0
    ret
.Lpreq_fail:
    mov x0, #-1
    ret

// ----------------------------------------------------------------------------
// state_new_paths — seed the paths status table (main.go:174).
// ----------------------------------------------------------------------------
state_new_paths:
    LEA x1, state_paths
    mov x2, #CC_PATH_COUNT
    str x2, [x1]
    LEA x2, state_s_ingress0
    str x2, [x1, #8]
    mov x2, #CC_STATUS_UNKNOWN
    str x2, [x1, #16]
    LEA x2, state_s_normalized
    str x2, [x1, #24]
    mov x2, #CC_STATUS_UNKNOWN
    str x2, [x1, #32]
    mov x0, #0
    ret

// ----------------------------------------------------------------------------
// state_new_stages — seed the internal stages table (main.go:204-220): per
// stage {desired, actual} from state_stage_seed, ops via cc_ctr_ops_for.
// ----------------------------------------------------------------------------
state_new_stages:
    PROLOGUE 1                      // x19=entry cursor x20=id
    LEA x1, state_stages
    mov x2, #CC_STAGE_COUNT
    str x2, [x1]
    add x19, x1, #8
    LEA x3, state_stage_seed
    mov x20, #0
.Lnss_loop:
    cmp x20, #CC_STAGE_COUNT
    b.hs .Lnss_ops
    ldr x4, [x3], #8
    str x4, [x19, #CC_SS_DESIRED]
    ldr x4, [x3], #8
    str x4, [x19, #CC_SS_ACTUAL]
    add x19, x19, #CC_STG_SIZE
    add x20, x20, #1
    b .Lnss_loop
.Lnss_ops:
    LEA x19, state_stages
    add x19, x19, #8
    mov x20, #0
.Lnss_op:
    cmp x20, #CC_STAGE_COUNT
    b.hs .Lnss_done
    mov x0, x20
    bl cc_ctr_ops_for
    str x0, [x19, #CC_STG_OPS]
    add x19, x19, #CC_STG_SIZE
    add x20, x20, #1
    b .Lnss_op
.Lnss_done:
    mov x0, #0
    EPILOGUE 1
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