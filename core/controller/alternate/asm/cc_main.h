// ============================================================================
// cc_main.h — ENTRY POINT module constants (CPP macros)
// ============================================================================
//  Shared constants for the cc_main.S module — Phase 4.7, the ENTRY POINT
//  (flag dispatch, run() orchestration, the containerd event callback, the
//  main loop, and shutdown) of the strimserver controller.  Everything here
//  is a CPP macro, never .equ: the fail-loud discipline (AGENTS.md hard rule
//  6) means a module-local `.equ CLOCK_REALTIME, 0` collides with the macro
//  and fails to assemble instead of silently shadowing it.
//
//  Golden contract (Gate 0 — core/controller/main.go + container_factory.go):
//    * flag dispatch ......... main.go:117-130  (main)
//    * run() orchestration ... main.go:132-366  (run)
//    * event decode + route .. container_factory.go:258-283
//    * shutdown order ........ main.go:344-365
//  See the cc_main.S header comment for the full behavior map.
//
//  FROZEN 4.6 cc_http CONTRACT — AUTHORITATIVE (the real Phase 4.6 module now
//  exists: core/controller/alternate/asm/cc_http.S + core/controller/alternate/c/cc_http.h).
//  DIFF from the phase-plan sketch: cc_http_init takes THREE args — the
//  controller pointer alone cannot reach the env block, so the caller passes
//  the parsed WEBSOCKET_WRITE_TIMEOUT (cc_http.S:81-91):
//    asm exports (what cc_main.S calls):
//      cc_http_init(x0=controller, x1=addr, x2=write_timeout_ns) -> 0 / err
//      cc_http_shutdown(x0=controller)      -> 0   (graceful close)
//    C wrapper (bounded pass inside the main loop; cc_http_serve loops
//    cc_http_service(-1) internally, so the interleaved loop calls the
//    bounded form):
//      cc_http_service(timeout_ms)          -> 0   (>= 0 = one service pass)
// ============================================================================
#ifndef CC_MAIN_H
#define CC_MAIN_H

// ----------------------------------------------------------------------------
// C-side declarations (the 4.7 exported functions; C callers include this)
// ----------------------------------------------------------------------------
// int  cc_main_entry(int argc, char **argv);        — the C main() equivalent
// int  cc_main_run(void *layout);                   — the run() flow
// void cc_main_event_cb(void *ctx, const uint8_t *env, uint32_t len);
// int  cc_main_flag_print_example(void);            — -print-env-example path
// int  cc_main_flag_print_ts(void);                 — -print-ts-types path
// int  cc_main_flag_check_env(void);                — -check-env path

// ----------------------------------------------------------------------------
// Clock / local-time formatting (verified by probe on this host, 2026-09:
// struct tm offsets are the aarch64 glibc layout).
// ----------------------------------------------------------------------------
#define CLOCK_REALTIME  0            // clock_gettime clockid (clock_gettime(2))
#define CC_TM_SEC       0            // struct tm offsets (offsetof probe)
#define CC_TM_MIN       4
#define CC_TM_HOUR      8
#define CC_TM_MDAY      12
#define CC_TM_MON       16
#define CC_TM_YEAR      20

// ----------------------------------------------------------------------------
// cc_grpc_poll event codes (mirrors core/controller/alternate/c/cc_grpc.h:97-105 — the
// frozen C-layer contract; the assembly tests these values).
// ----------------------------------------------------------------------------
#define CC_GRPC_EV_NONE       0   // timeout, no progress
#define CC_GRPC_EV_MSG        1   // a message was delivered (subscribe cb)
#define CC_GRPC_EV_STREAM_END 2   // a subscribe stream ended (trailers)
#define CC_GRPC_EV_GOAWAY     3   // GOAWAY received; connection must be rebuilt
#define CC_GRPC_EV_IO         4   // socket error / EOF; connection is dead
#define CC_GRPC_EV_PROTO      5   // protocol violation; connection is dead

// ----------------------------------------------------------------------------
// protobuf-c struct offsets (verified by offsetof probe against the vendored
// codecs, 2026-09; ProtobufCMessage base = 24 bytes):
//   types/event.pb-c.h  Containerd__Types__Envelope {base, timestamp,
//                                                     namespace_, topic, event}
//   any.pb-c.h          Google__Protobuf__Any      {base, type_url, value}
//                       ProtobufCBinaryData value  = {size_t len; uint8_t *data}
//   events/task.pb-c.h  TaskStart/TaskExit         {base, container_id, ...}
// ----------------------------------------------------------------------------
#define CC_PBC_ENV_EVENT       48   // Envelope.event (Google__Protobuf__Any*)
#define CC_PBC_ANY_TYPE_URL    24   // Any.type_url (char*)
#define CC_PBC_ANY_VALUE_LEN   32   // Any.value.len (size_t)
#define CC_PBC_ANY_VALUE_DATA  40   // Any.value.data (uint8_t*)
#define CC_PBC_TASK_CID        24   // TaskStart/TaskExit.container_id (char*)

// ----------------------------------------------------------------------------
// The containerd event type_url tails (the registered proto full names; the
// typeurl registry matches the suffix after the last '/' — typeurl/v2
// types.go getTypeByUrl -> protoregistry FindMessageByURL).  The strings
// live in cc_main.S rodata; these are only the lengths for any C-side use.
// ----------------------------------------------------------------------------
#define CC_MAIN_TS_START   "containerd.events.TaskStart"
#define CC_MAIN_TS_EXIT    "containerd.events.TaskExit"

// ----------------------------------------------------------------------------
// Fixed sizes for the module's .bss buffers
// ----------------------------------------------------------------------------
#define MAIN_STAGE_MAX      4      // stage container-id table entries
#define MAIN_REQUIRED_COUNT 43     // envspec.go Required:true entries
#define MAIN_ADDR_MAX       16     // ":" + port string
#define MAIN_LOGBUF_MAX     320    // Go-log line buffer
#define MAIN_LAY_STR_MAX    256    // one built Layout path string
#define MAIN_LAY_BUFS       2048   // 8 * MAIN_LAY_STR_MAX

#endif // CC_MAIN_H