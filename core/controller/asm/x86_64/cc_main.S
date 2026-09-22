// ============================================================================
// cc_main.S — the ENTRY POINT module for the strimserver controller
// (x86-64 port)
// ============================================================================
//
//  Target:     x86-64 (SysV AMD64), little-endian — Linux (ELF, static);
//              cc_platform_x86_64.h is the only platform header (Linux-only).
//  Assembler:  GNU as AT&T syntax, preprocessed by the C compiler
//              (`cc -c -x assembler-with-cpp`).
//  ISA:        floor x86-64-v4, cap AVX2 (no zmm/k/AMX, no AVX-512);
//              target g4dn.xlarge.  No in-source .arch directive on x86 GAS
//              (that is an ARM concept); the floor/cap are enforced by the
//              BUILD copts and by check-isa-x86_64.sh.
//
//  This module is the x86-64 translation of the AArch64 cc_main.S (Phase
//  4.7): the ENTRY POINT of the assembly controller — the port of
//  core/controller/main.go (main + run) and of the containerd event
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
//  EVENT DECODE + ROUTE (container_factory.go:258-283): see the AArch64
//  module header for the full behavior map — this translation is 1:1.
//
//  LOGGING (Go log.Printf -> stderr, `YYYY/MM/DD HH:MM:SS <msg>`):
//    local time via clock_gettime(CLOCK_REALTIME) + localtime_r (the Go log
//    package uses time.Now().Format("2006/01/02 15:04:05"), local time).
//    Message TEXTS match Go; Go's trailing ": <error>" detail strings are
//    replaced by the numeric code (DEVIATION, documented in cc_main.h).
//
//  SIGNAL HANDLING (documented choice): a flag-setting handler installed
//  with libc signal(SIGINT/SIGTERM) (main.go:136 signal.NotifyContext).
//  The handler only writes main_shutdown (async-signal-safe).  The main
//  loop is never blocked indefinitely (cc_grpc_poll is bounded by
//  RECONCILE_INTERVAL), so shutdown is detected within one interval.
//
//  Exported (all .global, SysV, %rbx/%rbp/%r12-%r15 preserved; <= 80
//  instructions):
//    main(argc, argv)                  the crt0 entry (tail-calls cc_main_entry)
//    cc_main_entry(rdi=argc, rsi=argv) -> int   the C main() equivalent
//    cc_main_run(rdi=layout)          -> int   the run() flow
//    cc_main_event_cb(rdi=ctx, rsi=env_bytes, rdx=len)   subscribe callback
//    cc_main_flag_print_example()    -> int   -print-env-example path
//    cc_main_flag_print_ts()         -> int   -print-ts-types path
//    cc_main_flag_check_env()        -> int   -check-env path (0 ok / 1)
//
//  Module-local helpers (main_*, full SysV obligations): the same list as
//  the AArch64 module (main_build_layout, main_build_stage_table,
//  main_subscribe, main_setup_http, main_loop, main_shutdown, main_wait_ops,
//  main_event_route, main_route_submit, main_route_unknown,
//  main_lookup_stage, main_after_slash, main_event_name, main_ns_to_ms,
//  main_sig_handler, main_fmt_ts, main_fmt_u64, main_log, main_log2,
//  main_log_num, main_log_missing, main_log_stream_err,
//  main_log_flag_unknown).
//
//  SysV AMD64 notes (see cc_util.S for the full rules)
//  --------------------------------------------------
//    * Arguments in %rdi, %rsi, %rdx, %rcx, %r8, %r9; return in %rax.
//    * Callee-saved (must be preserved across any `call`): %rbx, %rbp,
//      %r12-%r15.  %rsp stays 16-byte aligned at every call site.
//    * Register mapping used throughout (the AArch64 x19-x26 -> the 5
//      x86 callee-saved slots, spilling what does not fit; per-function
//      maps are annotated on each PROLOGUE):
//        x19->rbx, x20->r12, x21->r13, x22->r14, x23->r15.
//    * Never join statements with ';' — one instruction per line.
//
//  Includes: cc_layout.inc is carried over UNCHANGED (byte-identical on
//  x86-64).  cc_env.h is NOT included: it carries the AArch64 movz/movk
//  MOV_DUR_MIN/MOV_DUR_HOUR macro definitions, which would collide with the
//  x86_64 movabs versions in cc_platform_x86_64.h (GAS rejects a duplicate
//  .macro), and this module uses no cc_env.h constant (verified).
//
// ============================================================================

#include "cc_platform_x86_64.h"
#include "../cc_layout.inc"
#include "../cc_state.h"
#include "../cc_ctr.h"
#include "../cc_main.h"
    .text

// ============================================================================
// main — the crt0 entry point.  4.8 links a standard crt0 that calls
// main(argc, argv); this is a tail call into cc_main_entry (Rule 0: `jmp` is
// a tail call, `call` is never one — the ret inside cc_main_entry pops the
// return address crt0 pushed for main, so the stack is untouched by the jmp).
// ============================================================================
    .p2align 4
    .global main
    FUNC_TYPE(main)
main:
    jmp cc_main_entry

// ============================================================================
// cc_main_entry — the C main() equivalent: flag parse + dispatch.
//   in:  %rdi = argc, %rsi = argv
//   out: %rax = exit code (0 = ok; 1 = fail-loud; 2 = usage error)
//   Port of main.go:117-130.
// ============================================================================
    .p2align 4
    .global cc_main_entry
    FUNC_TYPE(cc_main_entry)
cc_main_entry:
    PROLOGUE 5                      // rbx=argc r12=argv r13=i r14=flags r15=arg
    mov %rdi, %rbx
    mov %rsi, %r12
    xor %r14d, %r14d                // flag bits: 1=example 2=ts 4=check-env
    mov $1, %r13d                   // argv[0] is the program name (:121)
.Lent_loop:
    cmp %rbx, %r13
    jae .Lent_done
    mov (%r12,%r13,8), %r15         // argv[i]
    movzbl (%r15), %eax
    cmp $'-', %al
    jne .Lent_done                  // first non-flag arg stops flag.Parse
    movzbl 1(%r15), %eax
    test %eax, %eax
    jz .Lent_done                   // "--" terminates parsing (flag pkg)
    LEA rdi, main_s_flag_example
    mov %r15, %rsi
    call cc_streq
    test %rax, %rax
    jnz .Lent_set_example
    LEA rdi, main_s_flag_ts
    mov %r15, %rsi
    call cc_streq
    test %rax, %rax
    jnz .Lent_set_ts
    LEA rdi, main_s_flag_checkenv
    mov %r15, %rsi
    call cc_streq
    test %rax, %rax
    jnz .Lent_set_checkenv
    mov %r15, %rdi                  // unknown flag -> usage error, exit 2
    call main_log_flag_unknown
.Lent_set_example:
    orl $1, %r14d
    jmp .Lent_next
.Lent_set_ts:
    orl $2, %r14d
    jmp .Lent_next
.Lent_set_checkenv:
    orl $4, %r14d
.Lent_next:
    inc %r13d
    jmp .Lent_loop
.Lent_done:
    testb $1, %r14b                 // Go switch order (:123-128)
    jz .Lent_no_example
    call cc_main_flag_print_example
    xor %eax, %eax
    jmp .Lent_ret
.Lent_no_example:
    testb $2, %r14b
    jz .Lent_no_ts
    call cc_main_flag_print_ts
    xor %eax, %eax
    jmp .Lent_ret
.Lent_no_ts:
    testb $4, %r14b
    jz .Lent_no_check
    call cc_main_flag_check_env
    jmp .Lent_ret
.Lent_no_check:
    LEA rdi, main_layout
    call cc_main_run
.Lent_ret:
    EPILOGUE 5
    ret

// ============================================================================
// cc_main_flag_print_example — the -print-env-example path (main.go:124).
// ============================================================================
    .p2align 4
    .global cc_main_flag_print_example
    FUNC_TYPE(cc_main_flag_print_example)
cc_main_flag_print_example:
    PROLOGUE 0
    call cc_env_print_example       // cc_env.S, port of printEnvExample
    xor %eax, %eax
    EPILOGUE 0
    ret

// ============================================================================
// cc_main_flag_print_ts — the -print-ts-types path (main.go:125).
// ============================================================================
    .p2align 4
    .global cc_main_flag_print_ts
    FUNC_TYPE(cc_main_flag_print_ts)
cc_main_flag_print_ts:
    PROLOGUE 0
    call cc_env_print_ts_types      // cc_env.S, port of printTSTypes
    xor %eax, %eax
    EPILOGUE 0
    ret

// ============================================================================
// cc_main_flag_check_env — the -check-env path (main.go:126 + checkEnv
// main.go:41-50): every Required env var present and non-empty -> "env OK" +
// 0; any missing/empty -> "missing or empty: <NAME>" per var + exit 1.
//   out: %rax = 0 (ok) / 1 (missing)
//   The required list is envspec.go Required:true in envSpec() order (43).
// ============================================================================
    .p2align 4
    .global cc_main_flag_check_env
    FUNC_TYPE(cc_main_flag_check_env)
cc_main_flag_check_env:
    PROLOGUE 4                      // rbx=table r12=i r13=missing r14=name
    xor %r13d, %r13d
    xor %r12d, %r12d
    LEA rbx, main_required_envs
.Lcke_loop:
    cmp $MAIN_REQUIRED_COUNT, %r12d
    jae .Lcke_done
    mov (%rbx,%r12,8), %r14
    mov %r14, %rdi
    call cc_env_str                 // absent/empty -> 0 (main.go:45)
    test %rax, %rax
    jnz .Lcke_next
    mov %r14, %rdi
    call main_log_missing           // "missing or empty: <NAME>" (main.go:46)
    mov $1, %r13d
.Lcke_next:
    inc %r12d
    jmp .Lcke_loop
.Lcke_done:
    test %r13d, %r13d
    jnz .Lcke_fail
    LEA rdi, main_s_env_ok         // "env OK\n" (main.go:126)
    call cc_puts
    xor %eax, %eax
    jmp .Lcke_ret
.Lcke_fail:
    mov $1, %eax                    // log.Fatal exit 1
.Lcke_ret:
    EPILOGUE 4
    ret

// ============================================================================
// cc_main_run — the run() flow (main.go:132-366).
//   in:  %rdi = Layout ptr (CC_LAY_* at +0; the env-runtime block at
//        +CC_LAY_SIZE; cc_env_load fills it — cc_layout.inc)
//   out: %rax = exit code (0 ok / 1 fail-loud)
// ============================================================================
    .p2align 4
    .global cc_main_run
    FUNC_TYPE(cc_main_run)
cc_main_run:
    PROLOGUE 5                      // rbx=layout r12=erbase r13=h r14=ctrl r15=http_ok
    mov %rdi, %rbx
    // per-run state: a fresh run starts with a clean slate (the signal flag
    // may have been set by a previous invocation in the same process)
    movq $0, main_shutdown_flag(%rip)
    movq $0, main_grpc_dead(%rip)
    movq $0, main_stream_logged(%rip)
    mov %rbx, %rdi
    call cc_env_load                // (a) LoadConfig (main.go:133-134)
    mov %rbx, %rdi
    call main_build_layout          // (b) DefaultLayout (main.go:156)
    lea CC_LAY_SIZE(%rbx), %r12
    mov CC_ER_CONTAINERD_SOCKET(%r12), %rdi
    mov CC_ER_CONTAINERD_NAMESPACE(%r12), %rsi
    call cc_grpc_init               // (c) containerd.New (main.go:139-141)
    test %rax, %rax
    jz .Lrun_grpc_fail
    mov %rax, %r13                  // h
    movq %r13, main_h(%rip)
    mov %rbx, %rdi
    mov %r13, %rsi
    mov CC_ER_STAGE_STOP_TIMEOUT(%r12), %rdx
    call cc_ctr_init                // (d) NewContainerFactory (main.go:155-157)
    mov %rbx, %rdi
    call cc_state_new               // (e) NewController (main.go:174-230)
    test %rax, %rax
    jnz .Lrun_state_fail
    call cc_state_ctrl
    mov %rax, %r14                  // ctrl
    mov %rbx, %rdi
    call main_build_stage_table     // (f) main.go:145-153
    mov %r13, %rdi
    mov %r14, %rsi
    call main_subscribe             // (g) container_factory.go:249-256
.Lrun_sub_next:
    mov %r14, %rdi
    mov %rbx, %rsi
    call main_setup_http            // (h) signals + http (main.go:332-342)
    mov %rax, %r15                  // http ok?
    LEA rdi, main_s_starting
    call main_log                   // (i) main.go:311
    test %r15, %r15
    jz .Lrun_loop
    jmp .Lrun_shutdown              // http failed -> skip loop (:338-341)
.Lrun_loop:
    mov %r14, %rdi
    mov %rbx, %rsi
    call main_loop                  // (j)
.Lrun_shutdown:
    mov %r14, %rdi
    mov %rbx, %rsi
    call main_shutdown              // (k) main.go:344-363
    movq main_h(%rip), %rdi
    call cc_grpc_close              // defer client.Close (main.go:141)
    xor %eax, %eax
    jmp .Lrun_ret
.Lrun_grpc_fail:
    LEA rdi, main_s_grpc_init_fail // "could not initialize containerd client"
    call main_log                   //   (main.go:140)
    mov $1, %eax
    jmp .Lrun_ret
.Lrun_state_fail:
    LEA rdi, main_s_state_fail     // "error constructing controller" (:230)
    call main_log
    mov $1, %eax
.Lrun_ret:
    EPILOGUE 5
    ret

// ============================================================================
// cc_main_event_cb — the Events/Subscribe callback (C-called; full SysV).
//   in:  %rdi = cb_ctx (the controller ptr), %rsi = Envelope bytes,
//        %rdx = len
//   The envelope pointer is only valid for the duration of the call, so the
//   decode + route happens here (container_factory.go:258-283).  The callback
//   must not re-enter the grpc library (cc_grpc.h calling rules) — it only
//   calls cc_state_* and the vendored pb-c codecs, which is allowed.
// ============================================================================
    .p2align 4
    .global cc_main_event_cb
    FUNC_TYPE(cc_main_event_cb)
cc_main_event_cb:
    PROLOGUE 4                      // rbx=ctrl r12=env r13=len r14=envelope
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    xor %edi, %edi                  // allocator NULL -> malloc
    mov %r13, %rsi
    mov %r12, %rdx
    call containerd__types__envelope__unpack
    test %rax, %rax
    jz .Lcb_ret                     // nil envelope -> skip (:261)
    mov %rax, %r14
    mov CC_PBC_ENV_EVENT(%r14), %rax
    test %rax, %rax
    jz .Lcb_free                    // nil event -> skip (:261)
    mov %rax, %rdi
    mov %rbx, %rsi                  // ctrl (the cb_ctx)
    call main_event_route
.Lcb_free:
    mov %r14, %rdi
    xor %esi, %esi
    call containerd__types__envelope__free_unpacked
.Lcb_ret:
    EPILOGUE 4
    ret

// ============================================================================
// main_event_route — decode the Envelope's Any and dispatch.
//   in:  %rdi = Google__Protobuf__Any ptr, %rsi = controller ptr (the cb_ctx)
//   Matches the type_url tail (after the last '/', typeurl semantics) against
//   the two registered proto full names; unpacks TaskStart/TaskExit, routes
//   through main_route_submit, frees the unpacked event message.
// ============================================================================
    .p2align 4
main_event_route:
    PROLOGUE 5                      // rbx=any r12=tail r13=msg r14=free-tag r15=ctrl
    mov %rdi, %rbx
    mov %rsi, %r15                  // ctrl (threaded to main_route_submit)
    mov CC_PBC_ANY_TYPE_URL(%rbx), %r12
    test %r12, %r12
    jz .Ler_decode_fail             // no type_url -> decode error
    mov %r12, %rdi
    call main_after_slash
    mov %rax, %r12
    LEA rsi, main_s_ts_start
    mov %r12, %rdi
    call cc_streq
    test %rax, %rax
    jnz .Ler_start
    LEA rsi, main_s_ts_exit
    mov %r12, %rdi
    call cc_streq
    test %rax, %rax
    jnz .Ler_exit
    mov %r12, %rdi
    call main_route_unknown         // not TaskStart/TaskExit
    jmp .Ler_done
.Ler_start:
    xor %edi, %edi
    mov CC_PBC_ANY_VALUE_LEN(%rbx), %rsi
    mov CC_PBC_ANY_VALUE_DATA(%rbx), %rdx
    call containerd__events__task_start__unpack
    test %rax, %rax
    jz .Ler_decode_fail
    mov %rax, %r13
    xor %r14d, %r14d                // free tag: start
    mov CC_PBC_TASK_CID(%r13), %rdi
    LEA rsi, main_s_name_start     // "TaskStart"
    mov $CC_STATE_RUNNING, %edx     // main.go:303-306
    mov %r15, %rcx                  // ctrl
    call main_route_submit
    jmp .Ler_free
.Ler_exit:
    xor %edi, %edi
    mov CC_PBC_ANY_VALUE_LEN(%rbx), %rsi
    mov CC_PBC_ANY_VALUE_DATA(%rbx), %rdx
    call containerd__events__task_exit__unpack
    test %rax, %rax
    jz .Ler_decode_fail
    mov %rax, %r13
    mov $1, %r14d                   // free tag: exit
    mov CC_PBC_TASK_CID(%r13), %rdi
    LEA rsi, main_s_name_exit      // "TaskExit"
    mov $CC_STATE_STOPPED, %edx
    mov %r15, %rcx                  // ctrl
    call main_route_submit
.Ler_free:
    test %r14d, %r14d
    jnz .Ler_free_exit
    mov %r13, %rdi
    xor %esi, %esi
    call containerd__events__task_start__free_unpacked
    jmp .Ler_done
.Ler_free_exit:
    mov %r13, %rdi
    xor %esi, %esi
    call containerd__events__task_exit__free_unpacked
    jmp .Ler_done
.Ler_decode_fail:
    LEA rdi, main_s_decode_err     // container_factory.go:264
    call main_log
.Ler_done:
    EPILOGUE 5
    ret

// ============================================================================
// main_route_submit — map a container_id to its stage and submit the
// StageEvent.
//   in:  %rdi = container_id, %rsi = event name ptr, %rdx = target state,
//        %rcx = controller ptr
//   Unknown id -> "received \"<name>\" event, but not associated with any
//   stage" (container_factory.go:273-277); submit via cc_state_handle_stage_
//   event (:282); error -> "could not handle \"<name>\" event" (:283).
// ============================================================================
    .p2align 4
main_route_submit:
    PROLOGUE 4                      // rbx=cid r12=name r13=state r14=ctrl
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    mov %rcx, %r14
    call main_lookup_stage
    test %rax, %rax
    jz .Lrs_unknown_stage
    // %rax = stage entry ptr (0 = not found); no call between here and use
    LEA rsi, main_se
    mov 8(%rax), %rdx               // the stage id
    mov %rdx, CC_SE_STAGE(%rsi)
    mov %r13, CC_SE_STATE(%rsi)
    mov %r14, %rdi
    // %rsi already = &StageEvent (cc_layout.inc CC_SE_*)
    call cc_state_handle_stage_event
    test %rax, %rax
    jnz .Lrs_handle_fail
    jmp .Lrs_ret
.Lrs_unknown_stage:
    LEA rdi, main_s_recv_pre
    mov %r12, %rsi
    LEA rdx, main_s_recv_no_stage
    call main_log2
    jmp .Lrs_ret
.Lrs_handle_fail:
    LEA rdi, main_s_handle_pre
    mov %r12, %rsi
    LEA rdx, main_s_handle_suf
    call main_log2
.Lrs_ret:
    EPILOGUE 4
    ret

// ============================================================================
// main_route_unknown — a non-TaskStart/TaskExit event: log + skip.
//   in:  %rdi = type_url tail (after the last '/')
//   TaskIO has no container id -> "without a container id"
//   (container_factory.go:270); everything else -> "but not associated with
//   any stage" (:275).  DEVIATION (documented in the module header): Go
//   decodes the event first; the asm only needs the type name for the log.
// ============================================================================
    .p2align 4
main_route_unknown:
    PROLOGUE 2                      // rbx=tail r12=name
    mov %rdi, %rbx
    call main_event_name
    mov %rax, %r12
    LEA rsi, main_s_name_io
    mov %r12, %rdi
    call cc_streq
    test %rax, %rax
    jnz .Lru_no_cid
    LEA rdi, main_s_recv_pre
    mov %r12, %rsi
    LEA rdx, main_s_recv_no_stage
    call main_log2
    jmp .Lru_done
.Lru_no_cid:
    LEA rdi, main_s_recv_pre
    mov %r12, %rsi
    LEA rdx, main_s_recv_no_cid
    call main_log2
.Lru_done:
    EPILOGUE 2
    ret

// ============================================================================
// main_lookup_stage — container_id -> stage table lookup.
//   in:  %rdi = container_id string
//   out: %rax = stage table ENTRY ptr (read +8 for the CC_STAGE_* id), or 0
//        when no entry matches (the same ptr/0 contract as cc_state_stage;
//        CC_STAGE_MEDIAMTX == 0, so an id can never double as "not found")
//   The table (main_stage_tab, .bss) is filled by main_build_stage_table
//   (main.go:145-153); entry i = {container_id ptr, stage id}; a null id
//   pointer means the slot is unused (single-stage mode).
// ============================================================================
    .p2align 4
main_lookup_stage:
    PROLOGUE 4                      // rbx=cid r12=table r13=idx r14=entry
    mov %rdi, %rbx
    LEA r12, main_stage_tab
    xor %r13d, %r13d
.Lls_loop:
    cmp $MAIN_STAGE_MAX, %r13d
    jae .Lls_none
    mov %r13, %r14
    shl $4, %r14
    add %r12, %r14
    mov (%r14), %rdi
    test %rdi, %rdi
    jz .Lls_next
    mov %rbx, %rsi
    call cc_streq
    test %rax, %rax
    jnz .Lls_found
.Lls_next:
    inc %r13d
    jmp .Lls_loop
.Lls_found:
    mov %r14, %rax                  // the entry pointer
    jmp .Lls_ret
.Lls_none:
    xor %eax, %eax
.Lls_ret:
    EPILOGUE 4
    ret

// ============================================================================
// main_after_slash — pointer to the part of a type_url after the last '/'
// (the typeurl registry matches the suffix after the last '/' — typeurl/v2
// types.go getTypeByUrl -> protoregistry FindMessageByURL).  No '/': returns
// the string unchanged.  Leaf: caller-saved only.
// ============================================================================
    .p2align 4
main_after_slash:
    mov %rdi, %rsi                  // %rsi = scan pointer
    mov %rdi, %rdx                  // %rdx = after the last '/'
.Las_loop:
    movzbl (%rsi), %ecx
    test %ecx, %ecx
    jz .Las_done
    cmp $'/', %cl
    jne .Las_next
    lea 1(%rsi), %rdx               // one past the '/'
.Las_next:
    inc %rsi
    jmp .Las_loop
.Las_done:
    mov %rdx, %rax
    ret

// ============================================================================
// main_event_name — the Go reflect type name for the log ("TaskStart",
// "TaskCreate", ...): the tail after the last '.'.  For the registered
// names the suffix is the message name; for a bare "<name>" tail with no
// '.' the whole tail is returned.  Leaf: caller-saved only.
// ============================================================================
    .p2align 4
main_event_name:
    mov %rdi, %rsi                  // %rsi = scan pointer
    mov %rdi, %rdx                  // %rdx = after the last '.'
.Len_loop:
    movzbl (%rsi), %ecx
    test %ecx, %ecx
    jz .Len_done
    cmp $'.', %cl
    jne .Len_next
    lea 1(%rsi), %rdx               // one past the '.'
.Len_next:
    inc %rsi
    jmp .Len_loop
.Len_done:
    mov %rdx, %rax
    ret

// ============================================================================
// main_ns_to_ms — nanoseconds to milliseconds (u64 / 1e6, six div-by-10
// steps with the shared DIV10_MAGIC; cc_grpc_poll takes ms).  Leaf.
//   in:  %rdi = value (ns)   out: %rax = value / 1e6
//   mul %rsi computes rdx:rax = rax * rsi; rdx is the high half, the
//   AArch64 umulh analogue.
// ============================================================================
    .p2align 4
main_ns_to_ms:
    MOV_DIV10_MAGIC rsi
    mov %rdi, %rax
    mul %rsi
    mov %rdx, %rax
    shr $3, %rax
    mul %rsi
    mov %rdx, %rax
    shr $3, %rax
    mul %rsi
    mov %rdx, %rax
    shr $3, %rax
    mul %rsi
    mov %rdx, %rax
    shr $3, %rax
    mul %rsi
    mov %rdx, %rax
    shr $3, %rax
    mul %rsi
    mov %rdx, %rax
    shr $3, %rax
    ret

// ============================================================================
// main_sig_handler — the SIGINT/SIGTERM handler: set the shutdown flag.
// Async-signal-safe (a single 4-byte store; only caller-saved regs are
// touched).  The main loop is never blocked indefinitely (polls are bounded
// by RECONCILE_INTERVAL), so shutdown is noticed within one interval.
// ============================================================================
    .p2align 4
main_sig_handler:
    movl $1, main_shutdown_flag(%rip)
    ret

// ============================================================================
// main_build_layout — fill the CC_LAY_* path strings from HostRoot
// (DefaultLayout, paths.go:27-42).
//   in:  %rdi = Layout ptr
//   Strings are built into main_layout_bufs (.bss, 8 x MAIN_LAY_STR_MAX).
//   HostRoot == ""/absent -> "/mnt/nvme" (paths.go:28-30).
// ============================================================================
    .p2align 4
main_build_layout:
    PROLOGUE 4                      // rbx=layout r12=erbase r13=root r14=buf
    mov %rdi, %rbx
    lea CC_LAY_SIZE(%rbx), %r12
    mov CC_ER_HOST_ROOT(%r12), %r13
    test %r13, %r13
    jnz .Lbl_root_ok
    LEA r13, main_s_default_root
.Lbl_root_ok:
    LEA r14, main_layout_bufs
    // Env = <root>/config/strimserver.env (paths.go:33)
    mov %r14, %rdi
    mov %r13, %rsi
    call cc_cat_cstr
    LEA rsi, main_s_cfg_env
    call cc_cat_cstr
    mov %r14, CC_LAY_ENV(%rbx)
    // Transcode = <root>/bin/transcode.sh (:34)
    add $MAIN_LAY_STR_MAX, %r14
    mov %r14, %rdi
    mov %r13, %rsi
    call cc_cat_cstr
    LEA rsi, main_s_bin_transcode
    call cc_cat_cstr
    mov %r14, CC_LAY_TRANSCODE(%rbx)
    // Notify = <root>/bin/notify.sh (:35)
    add $MAIN_LAY_STR_MAX, %r14
    mov %r14, %rdi
    mov %r13, %rsi
    call cc_cat_cstr
    LEA rsi, main_s_bin_notify
    call cc_cat_cstr
    mov %r14, CC_LAY_NOTIFY(%rbx)
    // MediaMTXTmpl = <root>/config/mediamtx.yaml.template (:36)
    add $MAIN_LAY_STR_MAX, %r14
    mov %r14, %rdi
    mov %r13, %rsi
    call cc_cat_cstr
    LEA rsi, main_s_cfg_tmpl
    call cc_cat_cstr
    mov %r14, CC_LAY_MEDIAMTX_TMPL(%rbx)
    // SrtPass = <root>/srt-passphrase (:37)
    add $MAIN_LAY_STR_MAX, %r14
    mov %r14, %rdi
    mov %r13, %rsi
    call cc_cat_cstr
    LEA rsi, main_s_root_srt
    call cc_cat_cstr
    mov %r14, CC_LAY_SRT_PASS(%rbx)
    // VideoDir = <root>/video-files (:38)
    add $MAIN_LAY_STR_MAX, %r14
    mov %r14, %rdi
    mov %r13, %rsi
    call cc_cat_cstr
    LEA rsi, main_s_root_video
    call cc_cat_cstr
    mov %r14, CC_LAY_VIDEO_DIR(%rbx)
    // ResolvConf = /run/systemd/resolve/resolv.conf (:39, not under root)
    add $MAIN_LAY_STR_MAX, %r14
    mov %r14, %rdi
    LEA rsi, main_s_resolv
    call cc_cat_cstr
    mov %r14, CC_LAY_RESOLV_CONF(%rbx)
    // Tmp = /tmp (:40)
    add $MAIN_LAY_STR_MAX, %r14
    mov %r14, %rdi
    LEA rsi, main_s_tmp
    call cc_cat_cstr
    mov %r14, CC_LAY_TMP(%rbx)
    EPILOGUE 4
    ret

// ============================================================================
// main_build_stage_table — the runtime container_id -> stage table
// (main.go:145-153): mediamtx / normalize / scale-and-egress always; the
// single-stage-egress entry only when ENABLE_SINGLE_STAGE_PIPELINE.
//   in:  %rdi = Layout ptr
//   Leaf: no calls, caller-saved registers only (no PROLOGUE needed).
// ============================================================================
    .p2align 4
main_build_stage_table:
    add $CC_LAY_SIZE, %rdi          // %rdi = erbase (no calls in this function)
    LEA rsi, main_stage_tab
    mov CC_ER_MEDIAMTX + CC_CC_CONTAINER_ID(%rdi), %rax
    mov %rax, 0(%rsi)               // main.go:146
    mov $CC_STAGE_MEDIAMTX, %rax
    mov %rax, 8(%rsi)
    mov CC_ER_NORMALIZE + CC_CC_CONTAINER_ID(%rdi), %rax
    mov %rax, 16(%rsi)              // main.go:147
    mov $CC_STAGE_NORMALIZE, %rax
    mov %rax, 24(%rsi)
    mov CC_ER_SCALE_AND_EGRESS + CC_CC_CONTAINER_ID(%rdi), %rax
    mov %rax, 32(%rsi)              // main.go:148
    mov $CC_STAGE_SCALE_AND_EGRESS, %rax
    mov %rax, 40(%rsi)
    movzbl CC_ER_ENABLE_SINGLE_STAGE(%rdi), %eax
    test %eax, %eax
    jz .Lbst_done
    mov CC_ER_SINGLE_STAGE_EGRESS + CC_CC_CONTAINER_ID(%rdi), %rax
    mov %rax, 48(%rsi)              // main.go:151-153
    mov $CC_STAGE_SINGLE_STAGE_EGRESS, %rax
    mov %rax, 56(%rsi)
.Lbst_done:
    ret

// ============================================================================
// main_subscribe — open the Events/Subscribe stream (container_factory.go
// :249-256).  On failure: log "containerd event stream error" once and mark
// the grpc side dead (the Go listener goroutine logs once and dies, and is
// never restarted; the main loop continues and paces on the ticker).
//   in:  %rdi = containerd handle, %rsi = controller ptr
// ============================================================================
    .p2align 4
main_subscribe:
    PROLOGUE 2                      // rbx=h r12=ctrl
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rbx, %rdi
    LEA rsi, main_s_filter         // `topic~="/tasks/.*"` (main.go:302)
    mov %r12, %rdx
    LEA rcx, cc_main_event_cb
    call cc_grpc_subscribe
    test %rax, %rax
    jnz .Lsub_ok
    xor %edi, %edi
    call main_log_stream_err        // container_factory.go:287
    movq $1, main_grpc_dead(%rip)
    jmp .Lsub_ret
.Lsub_ok:
    movq %rax, main_sid(%rip)
.Lsub_ret:
    EPILOGUE 2
    ret

// ============================================================================
// main_setup_http — signals + the HTTP listener.
//   in:  %rdi = ctrl, %rsi = layout
//   out: %rax = 0 ok / 1 (http init failed; Go logs and stops, main.go:338-341)
//   Builds addr = ":" + CONTROLLER_HTTP_PORT (main.go:332), installs the
//   SIGINT/SIGTERM handlers (main.go:136), cc_http_init(ctrl, addr,
//   WEBSOCKET_WRITE_TIMEOUT) (:334-335), logs "controller listening on
//   :<port>" (:336) or "http server error" (:339).
// ============================================================================
    .p2align 4
main_setup_http:
    PROLOGUE 4                      // rbx=ctrl r12=layout r13=port r14=addr
    mov %rdi, %rbx
    mov %rsi, %r12
    mov CC_LAY_SIZE + CC_ER_CONTROLLER_HTTP_PORT(%r12), %r13
    LEA r14, main_addr
    movb $':', (%r14)
    lea 1(%r14), %rdi
    mov %r13, %rsi
    call cc_cat_cstr
    mov $SIGINT, %edi
    LEA rsi, main_sig_handler
    call signal
    mov $SIGTERM, %edi
    LEA rsi, main_sig_handler
    call signal
    mov %rbx, %rdi
    mov %r14, %rsi
    mov CC_LAY_SIZE + CC_ER_WEBSOCKET_WRITE_TIMEOUT(%r12), %rdx
    call cc_http_init                // ListenAndServe (main.go:334-335)
    test %rax, %rax
    jnz .Lsetup_http_fail
    LEA rdi, main_s_listening
    mov %r14, %rsi
    LEA rdx, main_s_empty
    call main_log2
    xor %eax, %eax
    jmp .Lsetup_ret
.Lsetup_http_fail:
    LEA rdi, main_s_http_err
    call main_log
    mov $1, %eax
.Lsetup_ret:
    EPILOGUE 4
    ret

// ============================================================================
// main_loop — the synchronous main loop (Go's 4 goroutines -> 1 loop).
//   in:  %rdi = ctrl, %rsi = layout
//   out: %rax = 0 (shutdown requested)
//   cc_grpc_poll(h, RECONCILE_INTERVAL_ms) is the central wait; a timeout
//   reconciles (Go ticker, main.go:324-329 + :401-410); an event was already
//   routed by the callback; a stream/connection error is logged once and the
//   grpc side is marked dead (the Go listener goroutine dies and is never
//   restarted, main.go:319-322) — the loop then paces on the ticker cadence;
//   cc_http_service(0) drains the ws writes each iteration (http goroutine,
//   main.go:334-342); the shutdown flag (set by main_sig_handler) exits.
// ============================================================================
    .p2align 4
main_loop:
    PROLOGUE 4                      // rbx=ctrl r12=erbase r13=ms r14=ev
    mov %rdi, %rbx
    lea CC_LAY_SIZE(%rsi), %r12
    mov CC_ER_RECONCILE_INTERVAL(%r12), %rdi
    test %rdi, %rdi
    jz .Lloop_bad_interval
    call main_ns_to_ms
    mov %rax, %r13
.Lloop_top:
    movq main_shutdown_flag(%rip), %rax
    test %rax, %rax
    jnz .Lloop_done
    movq main_grpc_dead(%rip), %rax
    test %rax, %rax
    jnz .Lloop_sleep
    movq main_h(%rip), %rdi
    mov %r13, %rsi
    call cc_grpc_poll
    mov %rax, %r14
    cmp $CC_GRPC_EV_NONE, %r14d
    je .Lloop_reconcile
    cmp $CC_GRPC_EV_MSG, %r14d
    je .Lloop_http
    cmp $CC_GRPC_EV_STREAM_END, %r14d
    je .Lloop_stream_end
    jmp .Lloop_stream_err
.Lloop_reconcile:
    mov %rbx, %rdi
    call cc_state_reconcile
    jmp .Lloop_http
.Lloop_stream_end:
    movq main_h(%rip), %rdi
    movl main_sid(%rip), %esi
    call cc_grpc_stream_status
    mov %rax, %r14
.Lloop_stream_err:
    mov %r14, %rdi
    call main_log_stream_err        // log once (container_factory.go:287)
.Lloop_mark_dead:
    movq $1, main_grpc_dead(%rip)
    jmp .Lloop_http
.Lloop_sleep:
    xor %edi, %edi                  // poll(NULL, 0, interval) — ticker cadence
    xor %esi, %esi
    mov %r13, %rdx
    call poll
    jmp .Lloop_reconcile
.Lloop_http:
    xor %edi, %edi
    call cc_http_service            // bounded pass (main.go:334-342)
    jmp .Lloop_top
.Lloop_bad_interval:
    LEA rdi, main_s_bad_interval
    call main_log
    mov $1, %eax
    jmp .Lloop_ret
.Lloop_done:
    xor %eax, %eax
.Lloop_ret:
    EPILOGUE 4
    ret

// ============================================================================
// main_shutdown — the shutdown sequence (main.go:344-363).
//   in:  %rdi = ctrl, %rsi = layout
//   "shutting down" (:346); cc_http_shutdown (srv.Shutdown :348-355) with a
//   failure log (:353); bounded WaitForOps (:360, controller.go:329); then
//   cc_state_teardown (Teardown :361, stops Actual==Running stages) and
//   cc_state_close (Close :362).  cc_grpc_close is done by cc_main_run.
// ============================================================================
    .p2align 4
main_shutdown:
    PROLOGUE 3                      // rbx=ctrl r12=layout r13=erbase
    mov %rdi, %rbx
    mov %rsi, %r12
    lea CC_LAY_SIZE(%r12), %r13
    LEA rdi, main_s_shutting
    call main_log
    mov %rbx, %rdi
    call cc_http_shutdown
    test %rax, %rax
    jz .Lshut_http_ok
    LEA rdi, main_s_shutdown_fail
    call main_log
.Lshut_http_ok:
    mov CC_ER_SHUTDOWN_TIMEOUT(%r13), %rsi
    mov %rbx, %rdi
    call main_wait_ops
    mov %rbx, %rdi
    call cc_state_teardown
    mov %rbx, %rdi
    call cc_state_close
    xor %eax, %eax
    EPILOGUE 3
    ret

// ============================================================================
// main_wait_ops — the WaitForOps port (controller.go:329): poll until no
// stage has an op in flight, bounded by the shutdown timeout.  The
// synchronous design means no op can be in flight here; the loop is kept for
// the Go contract and is bounded (Go blocks indefinitely; the C ops are
// bounded by their own deadlines — documented deviation).
//   in:  %rdi = ctrl, %rsi = budget (u64 ns)
// ============================================================================
    .p2align 4
main_wait_ops:
    PROLOGUE 5                      // rbx=ctrl r12=budget r13=deadline r14=stage r15=busy
    mov %rdi, %rbx
    mov %rsi, %r12
    mov $CLOCK_MONOTONIC, %edi
    LEA rsi, main_ts
    call clock_gettime
    movq main_ts(%rip), %rax        // tv_sec
    MOV_NANOSEC rcx
    imul %rcx, %rax
    movq main_ts+8(%rip), %rdx      // tv_nsec
    add %rdx, %rax                  // now_ns
    add %r12, %rax                  // deadline
    mov %rax, %r13
.Lwops_loop:
    xor %r14d, %r14d                // stage id
    xor %r15d, %r15d                // busy flag
.Lwops_check:
    cmp $CC_STAGE_COUNT, %r14d
    jae .Lwops_checked
    mov %r14, %rdi
    call cc_state_stage             // id -> Stage entry ptr (cc_state.S:106)
    test %rax, %rax
    jz .Lwops_clear                 // defensive: a valid id never returns 0
    mov %rax, %rdi
    call cc_ctr_inflight_active
    test %rax, %rax
    jz .Lwops_clear
    mov $1, %r15d
.Lwops_clear:
    inc %r14d
    jmp .Lwops_check
.Lwops_checked:
    test %r15d, %r15d
    jz .Lwops_done
    mov $CLOCK_MONOTONIC, %edi
    LEA rsi, main_ts
    call clock_gettime
    movq main_ts(%rip), %rax
    MOV_NANOSEC rcx
    imul %rcx, %rax
    movq main_ts+8(%rip), %rdx
    add %rdx, %rax
    cmp %r13, %rax
    jae .Lwops_timeout
    xor %edi, %edi                  // poll(NULL, 0, 10ms) sleep
    xor %esi, %esi
    mov $10, %edx
    call poll
    jmp .Lwops_loop
.Lwops_timeout:
    LEA rdi, main_s_ops_timeout
    call main_log
.Lwops_done:
    xor %eax, %eax
    EPILOGUE 5
    ret

// ============================================================================
// main_fmt_ts — "YYYY/MM/DD HH:MM:SS " into a buffer (Go log format,
// "2006/01/02 15:04:05", local time via localtime_r).
//   in:  %rdi = buffer (>= 20 bytes)   out: %rax = buffer + 20
// ============================================================================
    .p2align 4
main_fmt_ts:
    PROLOGUE 2                      // rbx=buf r12=tm
    mov %rdi, %rbx
    mov $CLOCK_REALTIME, %edi
    LEA rsi, main_ts
    call clock_gettime
    LEA rdi, main_ts               // time_t* (tv_sec at +0)
    LEA rsi, main_tm
    call localtime_r
    LEA r12, main_tm
    movl CC_TM_YEAR(%r12), %esi     // YYYY
    add $1900, %esi
    mov %rbx, %rdi
    call cc_fmt4
    movb $'/', (%rax)
    lea 1(%rax), %rbx
    movl CC_TM_MON(%r12), %esi      // MM
    inc %esi
    mov %rbx, %rdi
    call cc_fmt2
    movb $'/', (%rax)
    lea 1(%rax), %rbx
    movl CC_TM_MDAY(%r12), %esi     // DD
    mov %rbx, %rdi
    call cc_fmt2
    movb $' ', (%rax)
    lea 1(%rax), %rbx
    movl CC_TM_HOUR(%r12), %esi     // HH
    mov %rbx, %rdi
    call cc_fmt2
    movb $':', (%rax)
    lea 1(%rax), %rbx
    movl CC_TM_MIN(%r12), %esi      // MM
    mov %rbx, %rdi
    call cc_fmt2
    movb $':', (%rax)
    lea 1(%rax), %rbx
    movl CC_TM_SEC(%r12), %esi      // SS
    mov %rbx, %rdi
    call cc_fmt2
    movb $' ', (%rax)
    lea 1(%rax), %rax
    EPILOGUE 2
    ret

// ============================================================================
// main_fmt_u64 — decimal u64 into a buffer (no NUL, no sign).  Leaf.
//   in:  %rdi = buffer, %rsi = value   out: %rax = one past the last digit
// ============================================================================
    .p2align 4
main_fmt_u64:
    sub $32, %rsp                   // 21-byte digit scratch (32 keeps 16-aligned)
    lea 20(%rsp), %r8               // write digits downward from buf+20
    xor %r9d, %r9d                  // %r9d = digit count
    MOV_DIV10_MAGIC r10
    test %rsi, %rsi
    jnz .Lfu_digits
    movb $'0', -1(%r8)
    dec %r8
    mov $1, %r9d
    jmp .Lfu_copy
.Lfu_digits:
    mov %rsi, %rax
    mul %r10                        // rdx:rax = value * magic
    mov %rdx, %rax
    shr $3, %rax                    // quotient = value / 10
    imul $10, %rax, %rdx            // quotient * 10
    mov %rsi, %rcx
    sub %rdx, %rcx                  // remainder
    add $'0', %ecx                  // remainder -> ASCII digit
    movb %cl, -1(%r8)               // store digit, walk the pointer down
    dec %r8
    inc %r9d
    mov %rax, %rsi                  // continue with the quotient
    test %rsi, %rsi
    jnz .Lfu_digits
.Lfu_copy:
    mov %rdi, %rax                  // %rax = dst
.Lfu_copy_loop:
    test %r9d, %r9d
    jz .Lfu_done
    movzbl (%r8), %ecx
    movb %cl, (%rax)
    inc %r8
    inc %rax
    dec %r9d
    jmp .Lfu_copy_loop
.Lfu_done:
    add $32, %rsp
    ret

// ============================================================================
// main_log — a Go-log line: "<ts> <msg>\n" to stderr (log.Printf format).
//   in:  %rdi = NUL-terminated message (without the trailing newline)
// ============================================================================
    .p2align 4
main_log:
    PROLOGUE 2                      // rbx=msg r12=cursor
    mov %rdi, %rbx
    LEA rdi, main_logbuf
    call main_fmt_ts
    mov %rax, %r12
    mov %r12, %rdi
    mov %rbx, %rsi
    call cc_cat_cstr                // %rax = position of the copied NUL
    mov %rax, %r12
    movb $'\n', (%r12)              // overwrite the NUL
    LEA rsi, main_logbuf
    mov %r12, %rax
    sub %rsi, %rax
    inc %rax                        // length incl '\n'
    mov $STDERR, %edi
    mov %rax, %rdx
    call write
    EPILOGUE 2
    ret

// ============================================================================
// main_log2 — a composed Go-log line: "<ts> <prefix><name><suffix>\n".
//   in:  %rdi = prefix, %rsi = name, %rdx = suffix (all NUL-terminated)
// ============================================================================
    .p2align 4
main_log2:
    PROLOGUE 4                      // rbx=pre r12=name r13=suf r14=cursor
    mov %rdi, %rbx
    mov %rsi, %r12
    mov %rdx, %r13
    LEA rdi, main_logbuf
    call main_fmt_ts
    mov %rax, %r14
    mov %r14, %rdi
    mov %rbx, %rsi
    call cc_cat_cstr
    mov %rax, %r14
    mov %r14, %rdi
    mov %r12, %rsi
    call cc_cat_cstr
    mov %rax, %r14
    mov %r14, %rdi
    mov %r13, %rsi
    call cc_cat_cstr
    mov %rax, %r14
    movb $'\n', (%r14)
    LEA rsi, main_logbuf
    mov %r14, %rax
    sub %rsi, %rax
    inc %rax
    mov $STDERR, %edi
    mov %rax, %rdx
    call write
    EPILOGUE 4
    ret

// ============================================================================
// main_log_num — "<ts> <prefix><signed number>\n" to stderr.
//   in:  %rdi = prefix, %rsi = int64 value (negative prints a leading '-')
// ============================================================================
    .p2align 4
main_log_num:
    PROLOGUE 4                      // rbx=pre r12=num r13=cursor r14=neg
    mov %rdi, %rbx
    mov %rsi, %r12
    xor %r14d, %r14d
    test %r12, %r12
    jge .Lln_pos
    mov $1, %r14d
    neg %r12
.Lln_pos:
    LEA rdi, main_logbuf
    call main_fmt_ts
    mov %rax, %r13
    mov %r13, %rdi
    mov %rbx, %rsi
    call cc_cat_cstr
    mov %rax, %r13
    test %r14d, %r14d
    jz .Lln_digits
    movb $'-', (%r13)
    inc %r13
.Lln_digits:
    mov %r13, %rdi
    mov %r12, %rsi
    call main_fmt_u64
    mov %rax, %r13
    movb $'\n', (%r13)
    LEA rsi, main_logbuf
    mov %r13, %rax
    sub %rsi, %rax
    inc %rax
    mov $STDERR, %edi
    mov %rax, %rdx
    call write
    EPILOGUE 4
    ret

// ============================================================================
// main_log_missing — "missing or empty: <NAME>" (checkEnv error text,
// main.go:46), timestamped like Go log.Fatal.
// ============================================================================
    .p2align 4
main_log_missing:
    PROLOGUE 2                      // rbx=name r12=cursor
    mov %rdi, %rbx
    LEA rdi, main_logbuf
    call main_fmt_ts
    mov %rax, %r12
    mov %r12, %rdi
    LEA rsi, main_s_missing
    call cc_cat_cstr
    mov %rax, %r12
    mov %r12, %rdi
    mov %rbx, %rsi
    call cc_cat_cstr
    mov %rax, %r12
    movb $'\n', (%r12)
    LEA rsi, main_logbuf
    mov %r12, %rax
    sub %rsi, %rax
    inc %rax
    mov $STDERR, %edi
    mov %rax, %rdx
    call write
    EPILOGUE 2
    ret

// ============================================================================
// main_log_stream_err — "containerd event stream error: <code>" exactly once
// (container_factory.go:287; the Go listener goroutine logs once and dies).
//   in:  %rdi = the numeric code (gRPC status / cc_grpc event / error)
// ============================================================================
    .p2align 4
main_log_stream_err:
    PROLOGUE 1                      // rbx=code
    mov %rdi, %rbx
    movq main_stream_logged(%rip), %rax
    test %rax, %rax
    jnz .Lse_done
    LEA rdi, main_s_stream_err
    mov %rbx, %rsi
    call main_log_num
    movq $1, main_stream_logged(%rip)
.Lse_done:
    EPILOGUE 1
    ret

// ============================================================================
// main_log_flag_unknown — the Go flag package's unknown-flag error
// (flag provided but not defined: -xxx), timestamped, then exit 2
// (flag.ExitOnError; the usage dump is not ported — documented).
//   in:  %rdi = the offending flag string (noreturn)
// ============================================================================
    .p2align 4
main_log_flag_unknown:
    PROLOGUE 2                      // rbx=flag r12=cursor
    mov %rdi, %rbx
    LEA rdi, main_logbuf
    call main_fmt_ts
    mov %rax, %r12
    mov %r12, %rdi
    LEA rsi, main_s_flag_unknown
    call cc_cat_cstr
    mov %rax, %r12
    mov %r12, %rdi
    mov %rbx, %rsi
    call cc_cat_cstr
    mov %rax, %r12
    movb $'\n', (%r12)
    LEA rsi, main_logbuf
    mov %r12, %rax
    sub %rsi, %rax
    inc %rax
    mov $STDERR, %edi
    mov %rax, %rdx
    call write
    EPILOGUE 2
    mov $2, %edi                    // flag.ExitOnError exit code
    jmp exit

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
    .space 56                       // struct tm (glibc, LP64: x86-64 == aarch64)
main_se:
    .space CC_SE_SIZE               // the StageEvent {stage, state}

    .end