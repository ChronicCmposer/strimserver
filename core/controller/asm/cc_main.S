// ============================================================================
// cc_main.S — the ENTRY POINT module for the strimserver controller
// ============================================================================
//
//  Target:     AArch64 (ARMv8.2-A), little-endian — Linux (ELF, static);
//              cc_platform.h is the only platform header (Linux-only).
//  Assembler:  GNU as syntax, preprocessed by the C compiler
//              (`cc -c -x assembler-with-cpp`).
//  ISA:        .arch armv8.2-a — exactly one in-source directive (below),
//              nothing higher, no .arch_extension, no .cpu (Graviton2 parity).
//
//  This module is Phase 4.7: the ENTRY POINT of the assembly controller — the
//  port of core/controller/main.go (main + run) and of the containerd event
//  listener (container_factory.go CreateContainerdEventListener).  It owns
//  the Layout buffer (the CC_LAY_* path strings + the CC_ER_* env-runtime
//  block), the flag dispatch, the run() orchestration, the synchronous main
//  loop (Go's 4 goroutines -> 1 loop), the event decode+route callback, and
//  the shutdown sequence.
//
//  Golden contract (Gate 0 — file:line evidence):
//
//  FLAG DISPATCH (main.go:117-130 main):
//    * argv scan (flag.Parse, :121): the three bool flags in Go's precedence
//      order; a first non-flag arg or "--" stops parsing (Go flag pkg); an
//      unknown "-flag" is fail-loud exit 2 (Go flag.ExitOnError, usage text
//      not ported — documented).
//    * -print-env-example -> cc_env_print_example(), exit 0 (:124)
//    * -print-ts-types    -> cc_env_print_ts_types(), exit 0 (:125)
//    * -check-env         -> every Required var present and non-empty:
//          good -> "env OK" to stdout, exit 0; else "missing or empty: <NAME>"
//          lines to stderr + exit 1 (checkEnv :41-50, log.Fatal :126)
//    * default -> cc_main_run(layout) (:127)
//
//  RUN (main.go:132-366 run):
//    (a) cc_env_load(layout)          LoadConfig (:133-134); fail-loud exit 1
//    (b) main_build_layout(layout)    DefaultLayout(hostRoot) (paths.go:27-42)
//    (c) cc_grpc_init(sock, ns)       containerd.New (:139-141); 0 -> exit 1
//    (d) cc_ctr_init(layout, h, stop) NewContainerFactory (:155-157)
//    (e) cc_state_new(layout)         NewController + wiring (:174-230); err ->
//        exit 1; ctrl = cc_state_ctrl() (:210-212)
//    (f) main_build_stage_table       container_id -> stage (main.go:145-153)
//    (g) cc_grpc_subscribe(h, `topic~="/tasks/.*"`, ctrl, cc_main_event_cb)
//                                      (:301-309, container_factory.go:249-256);
//        0 -> log stream error once, mark grpc dead (the Go listener
//        goroutine logs once and dies; the main loop continues)
//    (h) main_setup_http              addr = ":" + port (:332), signal
//        handlers (:136), cc_http_init (:334-335); "controller listening
//        on :<port>" (:336); failure -> "http server error" (:339) and
//        proceed to shutdown (ListenAndServe error calls stop(), :340)
//    (i) log "starting control plane..." (:311)
//    (j) main_loop — the synchronous 4-goroutine loop: cc_grpc_poll(h,
//        RECONCILE_INTERVAL_ms) is the central wait; poll timeout ->
//        cc_state_reconcile (ticker :324-329 + invokeReconcileEvery
//        :401-410); poll MSG -> events already routed by the callback;
//        STREAM_END/GOAWAY/IO/PROTO -> "containerd event stream error"
//        once + mark grpc dead (listener goroutine dies, :319-322);
//        cc_http_service(0) bounded pass each iteration (http goroutine
//        :334-342); exit when the shutdown flag is set
//    (k) main_shutdown — log "shutting down" (:346); cc_http_shutdown
//        (srv.Shutdown :348-355); bounded WaitForOps (controller.go:329);
//        cc_state_teardown (Teardown :361); cc_state_close (Close :362);
//        cc_grpc_close (defer client.Close :141); exit 0
//
//  EVENT DECODE + ROUTE (container_factory.go:258-283):
//    * unpack the Envelope (pb-c), nil envelope/event -> skip (:261)
//    * type_url suffix after the last '/' is matched (typeurl v2 semantics)
//      against "containerd.events.TaskStart" -> Running and
//      "containerd.events.TaskExit" -> Stopped (main.go:303-306); any other
//      type -> log "received \"<name>\" event, but not associated with any
//      stage" and skip (:273-277; DEVIATION: Go decodes the event then
//      checks the id — the asm skips the decode for non-TaskStart/TaskExit
//      events; the observable log text matches for every real-world case
//      because a stage container id never equals a TaskCreate id, etc.;
//      TaskIO has no container id -> "without a container id" (:270))
//    * container_id -> stage via the runtime table (f); unknown id -> the
//      not-associated log (:273-277); then cc_state_handle_stage_event
//      (:282); error -> "could not handle \"<name>\" event" (:283)
//    * decode errors -> "error decoding containerd event" (:264)
//
//  LOGGING (Go log.Printf -> stderr, `YYYY/MM/DD HH:MM:SS <msg>`):
//    local time via clock_gettime(CLOCK_REALTIME) + localtime_r (the Go log
//    package uses time.Now().Format("2006/01/02 15:04:05"), local time).
//    Message TEXTS match Go; Go's trailing ": <error>" detail strings are
//    replaced by the numeric code (DEVIATION, documented in cc_main.h and
//    below) because the C/Go error text is implementation-specific.
//
//  SIGNAL HANDLING (documented choice):
//    A flag-setting handler installed with libc signal(SIGINT/SIGTERM)
//    (main.go:136 signal.NotifyContext).  The handler only writes
//    main_shutdown (async-signal-safe).  The main loop is NEVER blocked
//    indefinitely: cc_grpc_poll is bounded by RECONCILE_INTERVAL, so
//    shutdown is detected within one interval — the same cadence as Go's
//    ticker.  No dedicated sigwait thread and no self-pipe are needed for a
//    single-threaded controller; libc signal() supplies the correct
//    sigreturn trampoline for a static binary (a raw rt_sigaction from
//    assembly would have to provide sa_restorer itself).
//
//  Exported (all .global, AAPCS64, x19-x28 preserved; <= 80 instructions):
//    main(argc, argv)                  the crt0 entry (tail-calls cc_main_entry)
//    cc_main_entry(x0=argc, x1=argv) -> int   the C main() equivalent
//    cc_main_run(x0=layout)          -> int   the run() flow
//    cc_main_event_cb(x0=ctx, x1=env_bytes, x2=len)   subscribe callback
//    cc_main_flag_print_example()    -> int   -print-env-example path
//    cc_main_flag_print_ts()         -> int   -print-ts-types path
//    cc_main_flag_check_env()        -> int   -check-env path (0 ok / 1)
//
//  Module-local helpers (main_*, full AAPCS64 obligations):
//    main_build_layout      DefaultLayout (paths.go:27-42)
//    main_build_stage_table the container_id -> stage table (main.go:145-153)
//    main_subscribe         Events/Subscribe + the fail-once path
//    main_setup_http        signals + addr + cc_http_init + the listening log
//    main_loop              the synchronous main loop
//    main_shutdown          the shutdown sequence (main.go:344-363)
//    main_wait_ops          WaitForOps port, bounded by SHUTDOWN_TIMEOUT
//    main_event_route       decode the Any + dispatch
//    main_route_submit      map cid -> stage, handle the StageEvent, log
//    main_route_unknown     log + skip a non-TaskStart/TaskExit event
//    main_lookup_stage      container_id -> stage table lookup
//    main_after_slash       ptr after the last '/' of a type_url
//    main_event_name        the Go reflect name (after the last '.')
//    main_ns_to_ms          ns / 1e6 (six div-by-10 steps)
//    main_sig_handler       sets main_shutdown (signal handler)
//    main_fmt_ts            "YYYY/MM/DD HH:MM:SS " into a buffer
//    main_fmt_u64           decimal u64 into a buffer
//    main_log / main_log2 / main_log_num / main_log_missing /
//    main_log_flag_unknown  the timestamped stderr writers
//    main_log_stream_err    "containerd event stream error" once
//
//  Calls into the OTHER modules (all fixed-arity):
//    cc_env_load, cc_env_str, cc_env_print_example, cc_env_print_ts_types
//    cc_state_new, cc_state_ctrl, cc_state_reconcile,
//    cc_state_handle_stage_event, cc_state_teardown, cc_state_close
//    cc_ctr_init, cc_ctr_inflight_active
//    cc_grpc_init, cc_grpc_subscribe, cc_grpc_poll, cc_grpc_stream_status,
//    cc_grpc_close
//    cc_http_init(x0=ctrl, x1=addr, x2=write_timeout_ns), cc_http_service(0),
//    cc_http_shutdown(x0=ctrl)   (the REAL Phase 4.6 contract — cc_http.S;
//                                 the frozen plan sketched a 2-arg init; the
//                                 real module needs the ws write timeout:
//                                 cc_http.S:81-91)
//    cc_strlen, cc_streq, cc_puts, cc_cat_cstr, cc_fmt2, cc_fmt4
//    containerd__types__envelope__unpack / _free_unpacked,
//    containerd__events__task_start__unpack / _free_unpacked,
//    containerd__events__task_exit__unpack / _free_unpacked   (vendored pb-c)
//    libc: signal, clock_gettime, localtime_r, write, poll, exit
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
#include "cc_state.h"
#include "cc_ctr.h"
#include "cc_main.h"
    .arch armv8.2-a
    .text

// ============================================================================
// main — the crt0 entry point.  4.8 links a standard crt0 that calls
// main(argc, argv); this is a tail call into cc_main_entry (Rule 0: `b` is a
// tail call, `bl` is never one — x30 is already the caller's return address).
// ============================================================================
    .p2align 2
    .global main
    FUNC_TYPE(main)
main:
    b cc_main_entry

// ============================================================================
// cc_main_entry — the C main() equivalent: flag parse + dispatch.
//   in:  x0 = argc, x1 = argv
//   out: x0 = exit code (0 = ok; 1 = fail-loud; 2 = usage error)
//   Port of main.go:117-130.
// ============================================================================
    .p2align 2
    .global cc_main_entry
    FUNC_TYPE(cc_main_entry)
cc_main_entry:
    PROLOGUE 4                      // x19=argc x20=argv x21=i x22=flags x23=arg
    mov x19, x0
    mov x20, x1
    mov x22, #0                     // flag bits: 1=example 2=ts 4=check-env
    mov x21, #1                     // argv[0] is the program name (:121)
.Lent_loop:
    cmp x21, x19
    b.hs .Lent_done
    ldr x23, [x20, x21, lsl #3]     // argv[i]
    ldrb w0, [x23]
    cmp w0, #'-'
    b.ne .Lent_done                 // first non-flag arg stops flag.Parse
    ldrb w0, [x23, #1]
    cbz w0, .Lent_done              // "--" terminates parsing (flag pkg)
    LEA x0, main_s_flag_example
    mov x1, x23
    bl cc_streq
    cbnz x0, .Lent_set_example
    LEA x0, main_s_flag_ts
    mov x1, x23
    bl cc_streq
    cbnz x0, .Lent_set_ts
    LEA x0, main_s_flag_checkenv
    mov x1, x23
    bl cc_streq
    cbnz x0, .Lent_set_checkenv
    mov x0, x23                     // unknown flag -> usage error, exit 2
    bl main_log_flag_unknown
.Lent_set_example:
    orr x22, x22, #1
    b .Lent_next
.Lent_set_ts:
    orr x22, x22, #2
    b .Lent_next
.Lent_set_checkenv:
    orr x22, x22, #4
.Lent_next:
    add x21, x21, #1
    b .Lent_loop
.Lent_done:
    tbz x22, #0, .Lent_no_example   // Go switch order (:123-128)
    bl cc_main_flag_print_example
    mov x0, #0
    b .Lent_ret
.Lent_no_example:
    tbz x22, #1, .Lent_no_ts
    bl cc_main_flag_print_ts
    mov x0, #0
    b .Lent_ret
.Lent_no_ts:
    tbz x22, #2, .Lent_no_check
    bl cc_main_flag_check_env
    b .Lent_ret
.Lent_no_check:
    LEA x0, main_layout
    bl cc_main_run
.Lent_ret:
    EPILOGUE 4
    ret

// ============================================================================
// cc_main_flag_print_example — the -print-env-example path (main.go:124).
// ============================================================================
    .p2align 2
    .global cc_main_flag_print_example
    FUNC_TYPE(cc_main_flag_print_example)
cc_main_flag_print_example:
    PROLOGUE 1
    bl cc_env_print_example         // cc_env.S, port of printEnvExample
    mov x0, #0
    EPILOGUE 1
    ret

// ============================================================================
// cc_main_flag_print_ts — the -print-ts-types path (main.go:125).
// ============================================================================
    .p2align 2
    .global cc_main_flag_print_ts
    FUNC_TYPE(cc_main_flag_print_ts)
cc_main_flag_print_ts:
    PROLOGUE 1
    bl cc_env_print_ts_types        // cc_env.S, port of printTSTypes
    mov x0, #0
    EPILOGUE 1
    ret

// ============================================================================
// cc_main_flag_check_env — the -check-env path (main.go:126 + checkEnv
// main.go:41-50): every Required env var present and non-empty -> "env OK" +
// 0; any missing/empty -> "missing or empty: <NAME>" per var + exit 1.
//   out: x0 = 0 (ok) / 1 (missing)
//   The required list is envspec.go Required:true in envSpec() order (43).
// ============================================================================
    .p2align 2
    .global cc_main_flag_check_env
    FUNC_TYPE(cc_main_flag_check_env)
cc_main_flag_check_env:
    PROLOGUE 3                      // x19=table x20=i x21=missing x22=name
    mov x21, #0
    mov x20, #0
    LEA x19, main_required_envs
.Lcke_loop:
    cmp x20, #MAIN_REQUIRED_COUNT
    b.hs .Lcke_done
    ldr x22, [x19, x20, lsl #3]
    mov x0, x22
    bl cc_env_str                   // absent/empty -> 0 (main.go:45)
    cbnz x0, .Lcke_next
    mov x0, x22
    bl main_log_missing             // "missing or empty: <NAME>" (main.go:46)
    mov x21, #1
.Lcke_next:
    add x20, x20, #1
    b .Lcke_loop
.Lcke_done:
    cbnz x21, .Lcke_fail
    LEA x0, main_s_env_ok           // "env OK\n" (main.go:126)
    bl cc_puts
    mov x0, #0
    b .Lcke_ret
.Lcke_fail:
    mov x0, #1                      // log.Fatal exit 1
.Lcke_ret:
    EPILOGUE 3
    ret

// ============================================================================
// cc_main_run — the run() flow (main.go:132-366).
//   in:  x0 = Layout ptr (CC_LAY_* at +0; the env-runtime block at
//        +CC_LAY_SIZE; cc_env_load fills it — cc_layout.inc)
//   out: x0 = exit code (0 ok / 1 fail-loud)
// ============================================================================
    .p2align 2
    .global cc_main_run
    FUNC_TYPE(cc_main_run)
cc_main_run:
    PROLOGUE 4                      // x19=layout x20=erbase x21=h x22=ctrl
    mov x19, x0
    // per-run state: a fresh run starts with a clean slate (the signal flag
    // may have been set by a previous invocation in the same process)
    LEA x23, main_shutdown_flag
    str xzr, [x23]
    LEA x23, main_grpc_dead
    str xzr, [x23]
    LEA x23, main_stream_logged
    str xzr, [x23]
    mov x0, x19
    bl cc_env_load                  // (a) LoadConfig (main.go:133-134)
    mov x0, x19
    bl main_build_layout            // (b) DefaultLayout (main.go:156)
    add x20, x19, #CC_LAY_SIZE
    ldr x0, [x20, #CC_ER_CONTAINERD_SOCKET]
    ldr x1, [x20, #CC_ER_CONTAINERD_NAMESPACE]
    bl cc_grpc_init                 // (c) containerd.New (main.go:139-141)
    cbz x0, .Lrun_grpc_fail
    mov x21, x0                     // h
    LEA x22, main_h
    str x21, [x22]
    mov x0, x19
    mov x1, x21
    ldr x2, [x20, #CC_ER_STAGE_STOP_TIMEOUT]
    bl cc_ctr_init                  // (d) NewContainerFactory (main.go:155-157)
    mov x0, x19
    bl cc_state_new                 // (e) NewController (main.go:174-230)
    cbnz x0, .Lrun_state_fail
    bl cc_state_ctrl
    mov x22, x0                     // ctrl
    mov x0, x19
    bl main_build_stage_table       // (f) main.go:145-153
    mov x0, x21
    mov x1, x22
    bl main_subscribe               // (g) container_factory.go:249-256
.Lrun_sub_next:
    mov x0, x22
    mov x1, x19
    bl main_setup_http              // (h) signals + http (main.go:332-342)
    mov x23, x0                     // http ok?
    LEA x0, main_s_starting
    bl main_log                     // (i) main.go:311
    cbz x23, .Lrun_loop
    b .Lrun_shutdown                // http failed -> skip loop (:338-341)
.Lrun_loop:
    mov x0, x22
    mov x1, x19
    bl main_loop                    // (j)
.Lrun_shutdown:
    mov x0, x22
    mov x1, x19
    bl main_shutdown                // (k) main.go:344-363
    LEA x0, main_h
    ldr x0, [x0]
    bl cc_grpc_close                // defer client.Close (main.go:141)
    mov x0, #0
    b .Lrun_ret
.Lrun_grpc_fail:
    LEA x0, main_s_grpc_init_fail   // "could not initialize containerd client"
    bl main_log                     //   (main.go:140)
    mov x0, #1
    b .Lrun_ret
.Lrun_state_fail:
    LEA x0, main_s_state_fail       // "error constructing controller" (:230)
    bl main_log
    mov x0, #1
.Lrun_ret:
    EPILOGUE 4
    ret

// ============================================================================
// cc_main_event_cb — the Events/Subscribe callback (C-called; full AAPCS64).
//   in:  x0 = cb_ctx (the controller ptr), x1 = Envelope bytes, x2 = len
//   The envelope pointer is only valid for the duration of the call, so the
//   decode + route happens here (container_factory.go:258-283).  The callback
//   must not re-enter the grpc library (cc_grpc.h calling rules) — it only
//   calls cc_state_* and the vendored pb-c codecs, which is allowed.
// ============================================================================
    .p2align 2
    .global cc_main_event_cb
    FUNC_TYPE(cc_main_event_cb)
cc_main_event_cb:
    PROLOGUE 4                      // x19=ctrl x20=env x21=len x22=envelope
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x0, #0                      // allocator NULL -> malloc
    mov x1, x21
    mov x2, x20
    bl containerd__types__envelope__unpack
    cbz x0, .Lcb_ret                // nil envelope -> skip (:261)
    mov x22, x0
    ldr x23, [x22, #CC_PBC_ENV_EVENT]
    cbz x23, .Lcb_free              // nil event -> skip (:261)
    mov x0, x23
    mov x1, x19                     // ctrl (the cb_ctx)
    bl main_event_route
.Lcb_free:
    mov x0, x22
    mov x1, #0
    bl containerd__types__envelope__free_unpacked
.Lcb_ret:
    EPILOGUE 4
    ret

// ============================================================================
// main_event_route — decode the Envelope's Any and dispatch.
//   in:  x0 = Google__Protobuf__Any ptr, x1 = controller ptr (the cb_ctx)
//   Matches the type_url tail (after the last '/', typeurl semantics) against
//   the two registered proto full names; unpacks TaskStart/TaskExit, routes
//   through main_route_submit, frees the unpacked event message.
// ============================================================================
    .p2align 2
main_event_route:
    PROLOGUE 4                      // x19=any x20=tail x21=msg x22=free-tag
    mov x19, x0
    mov x26, x1                     // ctrl (threaded to main_route_submit)
    ldr x20, [x19, #CC_PBC_ANY_TYPE_URL]
    cbz x20, .Ler_decode_fail       // no type_url -> decode error
    mov x0, x20
    bl main_after_slash
    mov x20, x0
    LEA x1, main_s_ts_start
    mov x0, x20
    bl cc_streq
    cbnz x0, .Ler_start
    LEA x1, main_s_ts_exit
    mov x0, x20
    bl cc_streq
    cbnz x0, .Ler_exit
    mov x0, x20
    bl main_route_unknown           // not TaskStart/TaskExit
    b .Ler_done
.Ler_start:
    ldr x1, [x19, #CC_PBC_ANY_VALUE_LEN]
    ldr x2, [x19, #CC_PBC_ANY_VALUE_DATA]
    mov x0, #0
    bl containerd__events__task_start__unpack
    cbz x0, .Ler_decode_fail
    mov x21, x0
    mov x22, #0                     // free tag: start
    ldr x0, [x21, #CC_PBC_TASK_CID]
    LEA x1, main_s_name_start       // "TaskStart"
    mov x2, #CC_STATE_RUNNING       // main.go:303-306
    mov x3, x26                     // ctrl
    bl main_route_submit
    b .Ler_free
.Ler_exit:
    ldr x1, [x19, #CC_PBC_ANY_VALUE_LEN]
    ldr x2, [x19, #CC_PBC_ANY_VALUE_DATA]
    mov x0, #0
    bl containerd__events__task_exit__unpack
    cbz x0, .Ler_decode_fail
    mov x21, x0
    mov x22, #1                     // free tag: exit
    ldr x0, [x21, #CC_PBC_TASK_CID]
    LEA x1, main_s_name_exit        // "TaskExit"
    mov x2, #CC_STATE_STOPPED
    mov x3, x26                     // ctrl
    bl main_route_submit
.Ler_free:
    cbnz x22, .Ler_free_exit
    mov x0, x21
    mov x1, #0
    bl containerd__events__task_start__free_unpacked
    b .Ler_done
.Ler_free_exit:
    mov x0, x21
    mov x1, #0
    bl containerd__events__task_exit__free_unpacked
    b .Ler_done
.Ler_decode_fail:
    LEA x0, main_s_decode_err       // container_factory.go:264
    bl main_log
.Ler_done:
    EPILOGUE 4
    ret

// ============================================================================
// main_route_submit — map a container_id to its stage and submit the
// StageEvent.
//   in:  x0 = container_id, x1 = event name ptr, x2 = target state,
//        x3 = controller ptr
//   Unknown id -> "received \"<name>\" event, but not associated with any
//   stage" (container_factory.go:273-277); submit via cc_state_handle_stage_
//   event (:282); error -> "could not handle \"<name>\" event" (:283).
// ============================================================================
    .p2align 2
main_route_submit:
    PROLOGUE 4                      // x19=cid x20=name x21=state x23=ctrl
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x23, x3
    bl main_lookup_stage
    cbz x0, .Lrs_unknown_stage
    mov x24, x0                     // stage entry ptr (0 = not found)
    LEA x22, main_se
    ldr x0, [x24, #8]               // the stage id
    str x0, [x22, #CC_SE_STAGE]
    str x21, [x22, #CC_SE_STATE]
    mov x0, x23
    mov x1, x22                     // &StageEvent (cc_layout.inc CC_SE_*)
    bl cc_state_handle_stage_event
    cbnz x0, .Lrs_handle_fail
    b .Lrs_ret
.Lrs_unknown_stage:
    LEA x0, main_s_recv_pre
    mov x1, x20
    LEA x2, main_s_recv_no_stage
    bl main_log2
    b .Lrs_ret
.Lrs_handle_fail:
    LEA x0, main_s_handle_pre
    mov x1, x20
    LEA x2, main_s_handle_suf
    bl main_log2
.Lrs_ret:
    EPILOGUE 4
    ret

// ============================================================================
// main_route_unknown — a non-TaskStart/TaskExit event: log + skip.
//   in:  x0 = type_url tail (after the last '/')
//   TaskIO has no container id -> "without a container id"
//   (container_factory.go:270); everything else -> "but not associated with
//   any stage" (:275).  DEVIATION (documented in the module header): Go
//   decodes the event first; the asm only needs the type name for the log.
// ============================================================================
    .p2align 2
main_route_unknown:
    PROLOGUE 2                      // x19=tail x20=name
    mov x19, x0
    bl main_event_name
    mov x20, x0
    LEA x1, main_s_name_io
    mov x0, x20
    bl cc_streq
    cbnz x0, .Lru_no_cid
    LEA x0, main_s_recv_pre
    mov x1, x20
    LEA x2, main_s_recv_no_stage
    bl main_log2
    b .Lru_done
.Lru_no_cid:
    LEA x0, main_s_recv_pre
    mov x1, x20
    LEA x2, main_s_recv_no_cid
    bl main_log2
.Lru_done:
    EPILOGUE 2
    ret

// ============================================================================
// main_lookup_stage — container_id -> stage table lookup.
//   in:  x0 = container_id string
//   out: x0 = stage table ENTRY ptr (read +8 for the CC_STAGE_* id), or 0
//        when no entry matches (the same ptr/0 contract as cc_state_stage;
//        CC_STAGE_MEDIAMTX == 0, so an id can never double as "not found")
//   The table (main_stage_tab, .bss) is filled by main_build_stage_table
//   (main.go:145-153); entry i = {container_id ptr, stage id}; a null id
//   pointer means the slot is unused (single-stage mode).
// ============================================================================
    .p2align 2
main_lookup_stage:
    PROLOGUE 2                      // x19=cid x20=table x21=idx x22=entry
    mov x19, x0
    LEA x20, main_stage_tab
    mov x21, #0
.Lls_loop:
    cmp x21, #MAIN_STAGE_MAX
    b.hs .Lls_none
    add x22, x20, x21, lsl #4
    ldr x0, [x22]
    cbz x0, .Lls_next
    mov x1, x19
    bl cc_streq
    cbnz x0, .Lls_found
.Lls_next:
    add x21, x21, #1
    b .Lls_loop
.Lls_found:
    mov x0, x22                     // the entry pointer
    b .Lls_ret
.Lls_none:
    mov x0, #0
.Lls_ret:
    EPILOGUE 2
    ret

// ============================================================================
// main_after_slash — pointer to the part of a type_url after the last '/'
// (the typeurl registry matches the suffix after the last '/' — typeurl/v2
// types.go getTypeByUrl -> protoregistry FindMessageByURL).  No '/': returns
// the string unchanged.
// ============================================================================
    .p2align 2
main_after_slash:
    mov x1, x0
    mov x2, x0                      // x2 = after the last '/'
.Las_loop:
    ldrb w3, [x1], #1
    cbz w3, .Las_done
    cmp w3, #'/'
    b.ne .Las_loop
    mov x2, x1
    b .Las_loop
.Las_done:
    mov x0, x2
    ret

// ============================================================================
// main_event_name — the Go reflect type name for the log ("TaskStart",
// "TaskCreate", ...): the tail after the last '.'.  For the registered
// names the suffix is the message name; for a bare "<name>" tail with no
// '.' the whole tail is returned.
// ============================================================================
    .p2align 2
main_event_name:
    mov x1, x0
    mov x2, x0                      // x2 = after the last '.'
.Len_loop:
    ldrb w3, [x1], #1
    cbz w3, .Len_done
    cmp w3, #'.'
    b.ne .Len_loop
    mov x2, x1
    b .Len_loop
.Len_done:
    mov x0, x2
    ret

// ============================================================================
// main_ns_to_ms — nanoseconds to milliseconds (u64 / 1e6, six div-by-10
// steps with the shared DIV10_MAGIC; cc_grpc_poll takes ms).
// ============================================================================
    .p2align 2
main_ns_to_ms:
    MOV_DIV10_MAGIC x1
    umulh x2, x0, x1
    lsr x2, x2, #3
    umulh x2, x2, x1
    lsr x2, x2, #3
    umulh x2, x2, x1
    lsr x2, x2, #3
    umulh x2, x2, x1
    lsr x2, x2, #3
    umulh x2, x2, x1
    lsr x2, x2, #3
    umulh x2, x2, x1
    lsr x2, x2, #3
    mov x0, x2
    ret

// ============================================================================
// main_sig_handler — the SIGINT/SIGTERM handler: set the shutdown flag.
// Async-signal-safe (a single store; only caller-saved regs are touched).
// The main loop is never blocked indefinitely (polls are bounded by
// RECONCILE_INTERVAL), so shutdown is noticed within one interval.
// ============================================================================
    .p2align 2
main_sig_handler:
    LEA x1, main_shutdown_flag
    mov w2, #1
    str w2, [x1]
    ret

// ============================================================================
// main_build_layout — fill the CC_LAY_* path strings from HostRoot
// (DefaultLayout, paths.go:27-42).
//   in:  x0 = Layout ptr
//   Strings are built into main_layout_bufs (.bss, 8 x MAIN_LAY_STR_MAX).
//   HostRoot == ""/absent -> "/mnt/nvme" (paths.go:28-30).
// ============================================================================
    .p2align 2
main_build_layout:
    PROLOGUE 4                      // x19=layout x20=erbase x21=root x22=buf
    mov x19, x0
    add x20, x0, #CC_LAY_SIZE
    ldr x21, [x20, #CC_ER_HOST_ROOT]
    cbnz x21, .Lbl_root_ok
    LEA x21, main_s_default_root
.Lbl_root_ok:
    LEA x22, main_layout_bufs
    // Env = <root>/config/strimserver.env (paths.go:33)
    mov x0, x22
    mov x1, x21
    bl cc_cat_cstr
    LEA x1, main_s_cfg_env
    bl cc_cat_cstr
    str x22, [x19, #CC_LAY_ENV]
    // Transcode = <root>/bin/transcode.sh (:34)
    add x22, x22, #MAIN_LAY_STR_MAX
    mov x0, x22
    mov x1, x21
    bl cc_cat_cstr
    LEA x1, main_s_bin_transcode
    bl cc_cat_cstr
    str x22, [x19, #CC_LAY_TRANSCODE]
    // Notify = <root>/bin/notify.sh (:35)
    add x22, x22, #MAIN_LAY_STR_MAX
    mov x0, x22
    mov x1, x21
    bl cc_cat_cstr
    LEA x1, main_s_bin_notify
    bl cc_cat_cstr
    str x22, [x19, #CC_LAY_NOTIFY]
    // MediaMTXTmpl = <root>/config/mediamtx.yaml.template (:36)
    add x22, x22, #MAIN_LAY_STR_MAX
    mov x0, x22
    mov x1, x21
    bl cc_cat_cstr
    LEA x1, main_s_cfg_tmpl
    bl cc_cat_cstr
    str x22, [x19, #CC_LAY_MEDIAMTX_TMPL]
    // SrtPass = <root>/srt-passphrase (:37)
    add x22, x22, #MAIN_LAY_STR_MAX
    mov x0, x22
    mov x1, x21
    bl cc_cat_cstr
    LEA x1, main_s_root_srt
    bl cc_cat_cstr
    str x22, [x19, #CC_LAY_SRT_PASS]
    // VideoDir = <root>/video-files (:38)
    add x22, x22, #MAIN_LAY_STR_MAX
    mov x0, x22
    mov x1, x21
    bl cc_cat_cstr
    LEA x1, main_s_root_video
    bl cc_cat_cstr
    str x22, [x19, #CC_LAY_VIDEO_DIR]
    // ResolvConf = /run/systemd/resolve/resolv.conf (:39, not under root)
    add x22, x22, #MAIN_LAY_STR_MAX
    mov x0, x22
    LEA x1, main_s_resolv
    bl cc_cat_cstr
    str x22, [x19, #CC_LAY_RESOLV_CONF]
    // Tmp = /tmp (:40)
    add x22, x22, #MAIN_LAY_STR_MAX
    mov x0, x22
    LEA x1, main_s_tmp
    bl cc_cat_cstr
    str x22, [x19, #CC_LAY_TMP]
    EPILOGUE 4
    ret

// ============================================================================
// main_build_stage_table — the runtime container_id -> stage table
// (main.go:145-153): mediamtx / normalize / scale-and-egress always; the
// single-stage-egress entry only when ENABLE_SINGLE_STAGE_PIPELINE.
//   in:  x0 = Layout ptr
// ============================================================================
    .p2align 2
main_build_stage_table:
    PROLOGUE 3                      // x19=erbase x20=table x21=tmp
    add x19, x0, #CC_LAY_SIZE
    LEA x20, main_stage_tab
    ldr x21, [x19, #CC_ER_MEDIAMTX + CC_CC_CONTAINER_ID]
    str x21, [x20, #0]              // main.go:146
    mov x21, #CC_STAGE_MEDIAMTX
    str x21, [x20, #8]
    ldr x21, [x19, #CC_ER_NORMALIZE + CC_CC_CONTAINER_ID]
    str x21, [x20, #16]             // main.go:147
    mov x21, #CC_STAGE_NORMALIZE
    str x21, [x20, #24]
    ldr x21, [x19, #CC_ER_SCALE_AND_EGRESS + CC_CC_CONTAINER_ID]
    str x21, [x20, #32]             // main.go:148
    mov x21, #CC_STAGE_SCALE_AND_EGRESS
    str x21, [x20, #40]
    ldrb w21, [x19, #CC_ER_ENABLE_SINGLE_STAGE]
    cbz w21, .Lbst_done
    ldr x21, [x19, #CC_ER_SINGLE_STAGE_EGRESS + CC_CC_CONTAINER_ID]
    str x21, [x20, #48]             // main.go:151-153
    mov x21, #CC_STAGE_SINGLE_STAGE_EGRESS
    str x21, [x20, #56]
.Lbst_done:
    EPILOGUE 3
    ret

// ============================================================================
// main_subscribe — open the Events/Subscribe stream (container_factory.go
// :249-256).  On failure: log "containerd event stream error" once and mark
// the grpc side dead (the Go listener goroutine logs once and dies, and is
// never restarted; the main loop continues and paces on the ticker).
//   in:  x0 = containerd handle, x1 = controller ptr
// ============================================================================
    .p2align 2
main_subscribe:
    PROLOGUE 3                      // x19=h x20=ctrl x21=tmp
    mov x19, x0
    mov x20, x1
    mov x0, x19
    LEA x1, main_s_filter           // `topic~="/tasks/.*"` (main.go:302)
    mov x2, x20
    LEA x3, cc_main_event_cb
    bl cc_grpc_subscribe
    cbnz x0, .Lsub_ok
    mov x0, #0
    bl main_log_stream_err          // container_factory.go:287
    LEA x21, main_grpc_dead
    mov x22, #1
    str x22, [x21]
    b .Lsub_ret
.Lsub_ok:
    LEA x21, main_sid
    str x0, [x21]
.Lsub_ret:
    EPILOGUE 3
    ret

// ============================================================================
// main_setup_http — signals + the HTTP listener.
//   in:  x0 = ctrl, x1 = layout
//   out: x0 = 0 ok / 1 (http init failed; Go logs and stops, main.go:338-341)
//   Builds addr = ":" + CONTROLLER_HTTP_PORT (main.go:332), installs the
//   SIGINT/SIGTERM handlers (main.go:136), cc_http_init(ctrl, addr,
//   WEBSOCKET_WRITE_TIMEOUT) (:334-335), logs "controller listening on
//   :<port>" (:336) or "http server error" (:339).
// ============================================================================
    .p2align 2
main_setup_http:
    PROLOGUE 4                      // x19=ctrl x20=layout x21=port x22=addr
    mov x19, x0
    mov x20, x1
    add x22, x20, #CC_LAY_SIZE
    ldr x21, [x22, #CC_ER_CONTROLLER_HTTP_PORT]
    LEA x22, main_addr
    mov w0, #':'
    strb w0, [x22]
    add x0, x22, #1
    mov x1, x21
    bl cc_cat_cstr
    mov x0, #SIGINT
    LEA x1, main_sig_handler
    bl signal
    mov x0, #SIGTERM
    LEA x1, main_sig_handler
    bl signal
mov x0, x19
    mov x1, x22
    add x24, x20, #CC_LAY_SIZE
    ldr x2, [x24, #CC_ER_WEBSOCKET_WRITE_TIMEOUT]
    bl cc_http_init                 // ListenAndServe (main.go:334-335)
    cbnz x0, .Lsetup_http_fail
    LEA x0, main_s_listening
    mov x1, x22
    LEA x2, main_s_empty
    bl main_log2
    mov x0, #0
    b .Lsetup_ret
.Lsetup_http_fail:
    LEA x0, main_s_http_err
    bl main_log
    mov x0, #1
.Lsetup_ret:
    EPILOGUE 4
    ret

// ============================================================================
// main_loop — the synchronous main loop (Go's 4 goroutines -> 1 loop).
//   in:  x0 = ctrl, x1 = layout
//   out: x0 = 0 (shutdown requested)
//   cc_grpc_poll(h, RECONCILE_INTERVAL_ms) is the central wait; a timeout
//   reconciles (Go ticker, main.go:324-329 + :401-410); an event was already
//   routed by the callback; a stream/connection error is logged once and the
//   grpc side is marked dead (the Go listener goroutine dies and is never
//   restarted, main.go:319-322) — the loop then paces on the ticker cadence;
//   cc_http_service(0) drains the ws writes each iteration (http goroutine,
//   main.go:334-342); the shutdown flag (set by main_sig_handler) exits.
// ============================================================================
    .p2align 2
main_loop:
    PROLOGUE 4                      // x19=ctrl x20=erbase x21=ms x22=ev
    mov x19, x0
    add x20, x1, #CC_LAY_SIZE
    ldr x0, [x20, #CC_ER_RECONCILE_INTERVAL]
    cbz x0, .Lloop_bad_interval
    bl main_ns_to_ms
    mov x21, x0
.Lloop_top:
    LEA x23, main_shutdown_flag
    ldr x23, [x23]
    cbnz x23, .Lloop_done
    LEA x23, main_grpc_dead
    ldr x23, [x23]
    cbnz x23, .Lloop_sleep
    LEA x0, main_h
    ldr x0, [x0]
    mov x1, x21
    bl cc_grpc_poll
    mov x22, x0
    cmp x22, #CC_GRPC_EV_NONE
    b.eq .Lloop_reconcile
    cmp x22, #CC_GRPC_EV_MSG
    b.eq .Lloop_http
    cmp x22, #CC_GRPC_EV_STREAM_END
    b.eq .Lloop_stream_end
    b .Lloop_stream_err
.Lloop_reconcile:
    mov x0, x19
    bl cc_state_reconcile
    b .Lloop_http
.Lloop_stream_end:
    LEA x0, main_h
    ldr x0, [x0]
    LEA x1, main_sid
    ldr w1, [x1]
    bl cc_grpc_stream_status
    mov x22, x0
.Lloop_stream_err:
    mov x0, x22
    bl main_log_stream_err          // log once (container_factory.go:287)
.Lloop_mark_dead:
    LEA x23, main_grpc_dead
    mov x24, #1
    str x24, [x23]
    b .Lloop_http
.Lloop_sleep:
    mov x0, #0                      // poll(NULL, 0, interval) — ticker cadence
    mov x1, #0
    mov x2, x21
    bl poll
    b .Lloop_reconcile
.Lloop_http:
    mov x0, #0
    bl cc_http_service              // bounded pass (main.go:334-342)
    b .Lloop_top
.Lloop_bad_interval:
    LEA x0, main_s_bad_interval
    bl main_log
    mov x0, #1
    b .Lloop_ret
.Lloop_done:
    mov x0, #0
.Lloop_ret:
    EPILOGUE 4
    ret

// ============================================================================
// main_shutdown — the shutdown sequence (main.go:344-363).
//   in:  x0 = ctrl, x1 = layout
//   "shutting down" (:346); cc_http_shutdown (srv.Shutdown :348-355) with a
//   failure log (:353); bounded WaitForOps (:360, controller.go:329); then
//   cc_state_teardown (Teardown :361, stops Actual==Running stages) and
//   cc_state_close (Close :362).  cc_grpc_close is done by cc_main_run.
// ============================================================================
    .p2align 2
main_shutdown:
    PROLOGUE 4                      // x19=ctrl x20=layout x21=erbase
    mov x19, x0
    mov x20, x1
    add x21, x20, #CC_LAY_SIZE
    LEA x0, main_s_shutting
    bl main_log
    mov x0, x19
    bl cc_http_shutdown
    cbz x0, .Lshut_http_ok
    LEA x0, main_s_shutdown_fail
    bl main_log
.Lshut_http_ok:
    ldr x1, [x21, #CC_ER_SHUTDOWN_TIMEOUT]
    mov x0, x19
    bl main_wait_ops
    mov x0, x19
    bl cc_state_teardown
    mov x0, x19
    bl cc_state_close
    mov x0, #0
    EPILOGUE 4
    ret

// ============================================================================
// main_wait_ops — the WaitForOps port (controller.go:329): poll until no
// stage has an op in flight, bounded by the shutdown timeout.  The
// synchronous design means no op can be in flight here; the loop is kept for
// the Go contract and is bounded (Go blocks indefinitely; the C ops are
// bounded by their own deadlines — documented deviation).
//   in:  x0 = ctrl, x1 = budget (u64 ns)
// ============================================================================
    .p2align 2
main_wait_ops:
    PROLOGUE 4                      // x19=ctrl x20=budget x21=deadline
    mov x19, x0
    mov x20, x1
    mov x0, #CLOCK_MONOTONIC
    LEA x1, main_ts
    bl clock_gettime
    LEA x22, main_ts
    ldr x23, [x22]                  // tv_sec
    MOV_NANOSEC x24
    mul x23, x23, x24
    ldr x24, [x22, #8]              // tv_nsec
    add x21, x23, x24               // now_ns
    add x21, x21, x20               // deadline
.Lwops_loop:
    mov x22, #0                     // stage id
    mov x23, #0                     // busy flag
.Lwops_check:
    cmp x22, #CC_STAGE_COUNT
    b.hs .Lwops_checked
    mov x0, x22
    bl cc_state_stage                // id -> Stage entry ptr (cc_state.S:106)
    cbz x0, .Lwops_clear             // defensive: a valid id never returns 0
    bl cc_ctr_inflight_active
    cbz x0, .Lwops_clear
    mov x23, #1
.Lwops_clear:
    add x22, x22, #1
    b .Lwops_check
.Lwops_checked:
    cbz x23, .Lwops_done
    mov x0, #CLOCK_MONOTONIC
    LEA x1, main_ts
    bl clock_gettime
    LEA x22, main_ts
    ldr x23, [x22]
    MOV_NANOSEC x24
    mul x23, x23, x24
    ldr x24, [x22, #8]
    add x23, x23, x24
    cmp x23, x21
    b.hs .Lwops_timeout
    mov x0, #0                      // poll(NULL, 0, 10ms) sleep
    mov x1, #0
    mov x2, #10
    bl poll
    b .Lwops_loop
.Lwops_timeout:
    LEA x0, main_s_ops_timeout
    bl main_log
.Lwops_done:
    mov x0, #0
    EPILOGUE 4
    ret

// ============================================================================
// main_fmt_ts — "YYYY/MM/DD HH:MM:SS " into a buffer (Go log format,
// "2006/01/02 15:04:05", local time via localtime_r).
//   in:  x0 = buffer (>= 20 bytes)   out: x0 = buffer + 20
// ============================================================================
    .p2align 2
main_fmt_ts:
    PROLOGUE 2                      // x19=buf x20=tm
    mov x19, x0
    mov x0, #CLOCK_REALTIME
    LEA x1, main_ts
    bl clock_gettime
    LEA x0, main_ts                 // time_t* (tv_sec at +0)
    LEA x1, main_tm
    bl localtime_r
    LEA x20, main_tm
    ldr w1, [x20, #CC_TM_YEAR]      // YYYY
    add w1, w1, #1900
    mov x0, x19
    bl cc_fmt4
    mov w1, #'/'
    strb w1, [x0], #1
    mov x19, x0
    ldr w1, [x20, #CC_TM_MON]       // MM
    add w1, w1, #1
    mov x0, x19
    bl cc_fmt2
    mov w1, #'/'
    strb w1, [x0], #1
    mov x19, x0
    ldr w1, [x20, #CC_TM_MDAY]      // DD
    mov x0, x19
    bl cc_fmt2
    mov w1, #' '
    strb w1, [x0], #1
    mov x19, x0
    ldr w1, [x20, #CC_TM_HOUR]      // HH
    mov x0, x19
    bl cc_fmt2
    mov w1, #':'
    strb w1, [x0], #1
    mov x19, x0
    ldr w1, [x20, #CC_TM_MIN]       // MM
    mov x0, x19
    bl cc_fmt2
    mov w1, #':'
    strb w1, [x0], #1
    mov x19, x0
    ldr w1, [x20, #CC_TM_SEC]       // SS
    mov x0, x19
    bl cc_fmt2
    mov w1, #' '
    strb w1, [x0], #1
    EPILOGUE 2
    ret

// ============================================================================
// main_fmt_u64 — decimal u64 into a buffer (no NUL, no sign).
//   in:  x0 = buffer, x1 = value   out: x0 = one past the last digit
// ============================================================================
    .p2align 2
main_fmt_u64:
    PROLOGUE 4                      // x19=buf x20=value x21=digit x22=count
    mov x19, x0
    mov x20, x1
    sub sp, sp, #32                 // 21-byte digit scratch (16-aligned)
    add x21, sp, #20
    mov x22, #0
    MOV_DIV10_MAGIC x23
    cmp x20, #0
    b.ne .Lfu_digits
    mov x3, #'0'
    strb w3, [x21, #-1]!
    mov x22, #1
    b .Lfu_copy
.Lfu_digits:
    umulh x4, x20, x23
    lsr x4, x4, #3                  // quotient
    mov x5, #10
    msub x6, x4, x5, x20            // remainder
    add w3, w6, #'0'
    strb w3, [x21, #-1]!
    mov x20, x4
    add x22, x22, #1
    cbnz x20, .Lfu_digits
.Lfu_copy:
    mov x0, x19
.Lfu_copy_loop:
    cbz x22, .Lfu_done
    ldrb w3, [x21], #1
    strb w3, [x0], #1
    sub x22, x22, #1
    b .Lfu_copy_loop
.Lfu_done:
    add sp, sp, #32
    EPILOGUE 4
    ret

// ============================================================================
// main_log — a Go-log line: "<ts> <msg>\n" to stderr (log.Printf format).
//   in:  x0 = NUL-terminated message (without the trailing newline)
// ============================================================================
    .p2align 2
main_log:
    PROLOGUE 3                      // x19=msg x20=cursor x21=buf
    mov x19, x0
    LEA x0, main_logbuf
    bl main_fmt_ts
    mov x20, x0
    mov x0, x20
    mov x1, x19
    bl cc_cat_cstr                  // x0 = position of the copied NUL
    mov x20, x0
    mov w1, #'\n'
    strb w1, [x20]                  // overwrite the NUL
    LEA x21, main_logbuf
    sub x0, x20, x21
    add x2, x0, #1                  // length incl '\n'
    mov x0, #STDERR
    mov x1, x21
    bl write
    EPILOGUE 3
    ret

// ============================================================================
// main_log2 — a composed Go-log line: "<ts> <prefix><name><suffix>\n".
//   in:  x0 = prefix, x1 = name, x2 = suffix (all NUL-terminated)
// ============================================================================
    .p2align 2
main_log2:
    PROLOGUE 4                      // x19=pre x20=name x21=suf x22=cursor
    mov x19, x0
    mov x20, x1
    mov x21, x2
    LEA x0, main_logbuf
    bl main_fmt_ts
    mov x22, x0
    mov x0, x22
    mov x1, x19
    bl cc_cat_cstr
    mov x22, x0
    mov x0, x22
    mov x1, x20
    bl cc_cat_cstr
    mov x22, x0
    mov x0, x22
    mov x1, x21
    bl cc_cat_cstr
    mov x22, x0
    mov w1, #'\n'
    strb w1, [x22]
    LEA x23, main_logbuf
    sub x0, x22, x23
    add x2, x0, #1
    mov x0, #STDERR
    mov x1, x23
    bl write
    EPILOGUE 4
    ret

// ============================================================================
// main_log_num — "<ts> <prefix><signed number>\n" to stderr.
//   in:  x0 = prefix, x1 = int64 value (negative prints a leading '-')
// ============================================================================
    .p2align 2
main_log_num:
    PROLOGUE 4                      // x19=pre x20=num x21=cursor x23=neg
    mov x19, x0
    mov x20, x1
    mov x23, #0
    cmp x20, #0
    b.ge .Lln_pos
    mov x23, #1
    neg x20, x20
.Lln_pos:
    LEA x0, main_logbuf
    bl main_fmt_ts
    mov x21, x0
    mov x0, x21
    mov x1, x19
    bl cc_cat_cstr
    mov x21, x0
    cbz x23, .Lln_digits
    mov w1, #'-'
    strb w1, [x21], #1
.Lln_digits:
    mov x0, x21
    mov x1, x20
    bl main_fmt_u64
    mov x21, x0
    mov w1, #'\n'
    strb w1, [x21]
    LEA x22, main_logbuf
    sub x0, x21, x22
    add x2, x0, #1
    mov x0, #STDERR
    mov x1, x22
    bl write
    EPILOGUE 4
    ret

// ============================================================================
// main_log_missing — "missing or empty: <NAME>" (checkEnv error text,
// main.go:46), timestamped like Go log.Fatal.
// ============================================================================
    .p2align 2
main_log_missing:
    PROLOGUE 3                      // x19=name x20=cursor x21=buf
    mov x19, x0
    LEA x0, main_logbuf
    bl main_fmt_ts
    mov x20, x0
    LEA x1, main_s_missing
    mov x0, x20
    bl cc_cat_cstr
    mov x20, x0
    mov x0, x20
    mov x1, x19
    bl cc_cat_cstr
    mov x20, x0
    mov w1, #'\n'
    strb w1, [x20]
    LEA x21, main_logbuf
    sub x0, x20, x21
    add x2, x0, #1
    mov x0, #STDERR
    mov x1, x21
    bl write
    EPILOGUE 3
    ret

// ============================================================================
// main_log_stream_err — "containerd event stream error: <code>" exactly once
// (container_factory.go:287; the Go listener goroutine logs once and dies).
//   in:  x0 = the numeric code (gRPC status / cc_grpc event / error)
// ============================================================================
    .p2align 2
main_log_stream_err:
    PROLOGUE 3                      // x19=code x20=flag
    mov x19, x0
    LEA x20, main_stream_logged
    ldr x20, [x20]
    cbnz x20, .Lse_done
    LEA x0, main_s_stream_err
    mov x1, x19
    bl main_log_num
    LEA x20, main_stream_logged
    mov x21, #1
    str x21, [x20]
.Lse_done:
    EPILOGUE 3
    ret

// ============================================================================
// main_log_flag_unknown — the Go flag package's unknown-flag error
// (flag provided but not defined: -xxx), timestamped, then exit 2
// (flag.ExitOnError; the usage dump is not ported — documented).
//   in:  x0 = the offending flag string (noreturn)
// ============================================================================
    .p2align 2
main_log_flag_unknown:
    PROLOGUE 3                      // x19=flag x20=cursor x21=buf
    mov x19, x0
    LEA x0, main_logbuf
    bl main_fmt_ts
    mov x20, x0
    LEA x1, main_s_flag_unknown
    mov x0, x20
    bl cc_cat_cstr
    mov x20, x0
    mov x0, x20
    mov x1, x19
    bl cc_cat_cstr
    mov x20, x0
    mov w1, #'\n'
    strb w1, [x20]
    LEA x21, main_logbuf
    sub x0, x20, x21
    add x2, x0, #1
    mov x0, #STDERR
    mov x1, x21
    bl write
    EPILOGUE 3
    mov w0, #2                      // flag.ExitOnError exit code
    b exit

// ============================================================================
// RODATA — the filter string, the type_url names, the log message texts,
// the Layout suffixes, and the -check-env required-var table.
// ============================================================================
    RODATA
    .p2align 3

// ---- the Events/Subscribe filter (main.go:302; the quotes are significant:
//      containerd 2.x treats '/' as a quote rune — cc_grpc.h) ----
main_s_filter:
    .asciz "topic~=\"/tasks/.*\""

// ---- event type_url tails (the registered proto full names) ----
main_s_ts_start:
    .asciz CC_MAIN_TS_START
main_s_ts_exit:
    .asciz CC_MAIN_TS_EXIT
main_s_name_start:
    .asciz "TaskStart"
main_s_name_exit:
    .asciz "TaskExit"
main_s_name_io:
    .asciz "TaskIO"

// ---- Go log message texts (main.go / container_factory.go citations) ----
main_s_empty:
    .asciz ""
main_s_starting:
    .asciz "starting control plane..."           // main.go:311
main_s_listening:
    .asciz "controller listening on "            // main.go:336 (+ addr)
main_s_shutting:
    .asciz "shutting down"                       // main.go:346
main_s_grpc_init_fail:
    .asciz "could not initialize containerd client"  // main.go:140
main_s_state_fail:
    .asciz "error constructing controller"       // main.go:230
main_s_http_err:
    .asciz "http server error"                   // main.go:339
main_s_shutdown_fail:
    .asciz "graceful http shutdown failed"       // main.go:353
main_s_stream_err:
    .asciz "containerd event stream error: "    // container_factory.go:287
main_s_decode_err:
    .asciz "error decoding containerd event"    // container_factory.go:264
main_s_recv_pre:
    .asciz "received \""                         // :270 / :275
main_s_recv_no_stage:
    .asciz "\" event, but not associated with any stage"
main_s_recv_no_cid:
    .asciz "\" event without a container id"
main_s_handle_pre:
    .asciz "could not handle \""
main_s_handle_suf:
    .asciz "\" event"
main_s_missing:
    .asciz "missing or empty: "                  // main.go:46
main_s_env_ok:
    .asciz "env OK\n"                            // main.go:126
main_s_bad_interval:
    .asciz "error: reconcile interval must be > 0"  // Go time.NewTicker(0) panic
main_s_ops_timeout:
    .asciz "error: waiting for operations timed out"
main_s_flag_example:
    .asciz "-print-env-example"
main_s_flag_ts:
    .asciz "-print-ts-types"
main_s_flag_checkenv:
    .asciz "-check-env"
main_s_flag_unknown:
    .asciz "flag provided but not defined: "

// ---- Layout path suffixes (DefaultLayout, paths.go:27-42) ----
main_s_default_root:
    .asciz "/mnt/nvme"                          // paths.go:28-30
main_s_cfg_env:
    .asciz "/config/strimserver.env"            // paths.go:33
main_s_bin_transcode:
    .asciz "/bin/transcode.sh"                  // paths.go:34
main_s_bin_notify:
    .asciz "/bin/notify.sh"                     // paths.go:35
main_s_cfg_tmpl:
    .asciz "/config/mediamtx.yaml.template"     // paths.go:36
main_s_root_srt:
    .asciz "/srt-passphrase"                    // paths.go:37
main_s_root_video:
    .asciz "/video-files"                       // paths.go:38
main_s_resolv:
    .asciz "/run/systemd/resolve/resolv.conf"   // paths.go:39
main_s_tmp:
    .asciz "/tmp"                               // paths.go:40

// ---- required env vars for -check-env (envspec.go Required:true, in
//      envSpec() order; the SAME order Go's checkEnv reports them) ----
    .p2align 3
main_required_envs:
    .quad main_req_01, main_req_02, main_req_03, main_req_04, main_req_05
    .quad main_req_06, main_req_07, main_req_08, main_req_09, main_req_10
    .quad main_req_11, main_req_12, main_req_13, main_req_14, main_req_15
    .quad main_req_16, main_req_17, main_req_18, main_req_19, main_req_20
    .quad main_req_21, main_req_22, main_req_23, main_req_24, main_req_25
    .quad main_req_26, main_req_27, main_req_28, main_req_29, main_req_30
    .quad main_req_31, main_req_32, main_req_33, main_req_34, main_req_35
    .quad main_req_36, main_req_37, main_req_38, main_req_39, main_req_40
    .quad main_req_41, main_req_42, main_req_43
main_req_01: .asciz "CONTAINERD_SOCKET"               // envspec.go:58
main_req_02: .asciz "CONTAINERD_NAMESPACE"            // :64
main_req_03: .asciz "CONTROLLER_HTTP_PORT"            // :69
main_req_04: .asciz "STRIMSERVER_HOST_ROOT"           // :75
main_req_05: .asciz "CONTROLLER_RECONCILE_INTERVAL"   // :81
main_req_06: .asciz "CONTROLLER_INFLIGHT_TIMEOUT"     // :87
main_req_07: .asciz "CONTROLLER_SHUTDOWN_TIMEOUT"     // :93
main_req_08: .asciz "STAGE_STOP_TIMEOUT"              // :99
main_req_09: .asciz "WEBSOCKET_WRITE_TIMEOUT"         // :105
main_req_10: .asciz "CONTROLLER_ACTIONS_BUFFER_SIZE"  // :111
main_req_11: .asciz "MEDIAMTX_CONTAINER_ID"           // :125
main_req_12: .asciz "MEDIAMTX_SNAPSHOT_ID"            // :130
main_req_13: .asciz "MEDIAMTX_IMAGE_NAME"             // :135
main_req_14: .asciz "MEDIAMTX_LOG_FILE"               // :140
main_req_15: .asciz "NORMALIZE_CONTAINER_ID"          // :145
main_req_16: .asciz "NORMALIZE_SNAPSHOT_ID"           // :150
main_req_17: .asciz "NORMALIZE_LOG_FILE"              // :155
main_req_18: .asciz "EGRESS_CONTAINER_ID"             // :160
main_req_19: .asciz "EGRESS_SNAPSHOT_ID"              // :170
main_req_20: .asciz "EGRESS_LOG_FILE"                 // :179
main_req_21: .asciz "FFMPEG_IMAGE_NAME"               // :188
main_req_22: .asciz "FFMPEG_NICE"                     // :203
main_req_23: .asciz "FFMPEG_LOG_LEVEL"                // :207
main_req_24: .asciz "MEDIAMTX_NICE"                   // :210
main_req_25: .asciz "MEDIAMTX_CONFIG_TEMPLATE"        // :213
main_req_26: .asciz "STRIMSERVER_SRT_PORT"            // :218
main_req_27: .asciz "STRIMSERVER_RTSP_PORT"           // :222
main_req_28: .asciz "NORMALIZED_MPEGTS_SOCKET"        // :226
main_req_29: .asciz "MEDIAMTX_READ_TIMEOUT_DURATION"  // :231
main_req_30: .asciz "NORMALIZED_VIDEO_BITRATE"        // :236
main_req_31: .asciz "NORMALIZED_VIDEO_MAXRATE"        // :239
main_req_32: .asciz "NORMALIZED_VIDEO_MINRATE"        // :242
main_req_33: .asciz "NORMALIZED_VIDEO_BUFSIZE"        // :245
main_req_34: .asciz "NORMALIZED_AUDIO_BITRATE"        // :248
main_req_35: .asciz "SCALED_VIDEO_HEIGHT_PIXELS"      // :251
main_req_36: .asciz "EGRESS_VIDEO_BITRATE"            // :255
main_req_37: .asciz "EGRESS_VIDEO_MAXRATE"            // :258
main_req_38: .asciz "EGRESS_VIDEO_MINRATE"            // :261
main_req_39: .asciz "EGRESS_VIDEO_BUFSIZE"            // :264
main_req_40: .asciz "EGRESS_AUDIO_BITRATE"            // :267
main_req_41: .asciz "TWITCH_INGEST_SERVER"            // :272
main_req_42: .asciz "TWITCH_STREAM_KEY"               // :276
main_req_43: .asciz "BANDWIDTH_TEST"                  // :281

// ============================================================================
// BSS — the Layout buffer (+ env-runtime block), the built path strings, the
// stage container-id table, and the module state.  (Single-threaded
// controller: one of everything.)
// ============================================================================
    .bss
    .p2align 3
main_layout:
    .space CC_LAY_SIZE + CC_ER_SIZE
main_layout_bufs:
    .space MAIN_LAY_BUFS
main_stage_tab:
    .space MAIN_STAGE_MAX * 16      // {container_id ptr, stage id} entries
main_h:
    .space 8                        // containerd connection handle
main_sid:
    .space 8                        // subscribe stream id
main_shutdown_flag:
    .space 8                        // 0/1, set by main_sig_handler
main_grpc_dead:
    .space 8                        // 0/1, listener goroutine died
main_stream_logged:
    .space 8                        // 0/1, stream error already logged
main_addr:
    .space MAIN_ADDR_MAX            // ":" + CONTROLLER_HTTP_PORT
main_logbuf:
    .space MAIN_LOGBUF_MAX
main_ts:
    .space 16                       // timespec {tv_sec u64, tv_nsec u64}
main_tm:
    .space 56                       // struct tm (aarch64 glibc)
main_se:
    .space CC_SE_SIZE               // the StageEvent {stage, state}

    .end