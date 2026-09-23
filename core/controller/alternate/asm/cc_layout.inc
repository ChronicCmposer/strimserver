// ============================================================================
// cc_layout.inc — the shared data contract for the strimserver controller
// ============================================================================
//
//  This file defines the byte layout of the controller's data structures and
//  the id space (path names, stage names, statuses, states, components,
//  actions, env vars); every cc_*.S module includes it.  Its offsets and ids
//  are what the modules and the test drivers compile against, so a change
//  here rebuilds everything.
//
//  FREEZE DISCIPLINE (frozen — do not break)
//  ----------------------------------------
//    * Add new fields at the END of a structure and bump its *_SIZE; never
//      renumber an existing offset.
//    * Never renumber an id (CC_PATH_*, CC_STATUS_*, CC_STATE_*,
//      CC_STAGE_*, CC_COMPONENT_*, CC_ACTION_*, CC_ENV_*).  New ids append
//      before the corresponding *_COUNT / CC_ENV_COUNT and bump it.
//    * The name/status/state/component/action ids are CPP macros (#define),
//      NOT .equ, per the fail-loud discipline: a module-local
//      `.equ CC_STATUS_READY, 9` then fails to assemble instead of silently
//      shadowing the shared value.  Struct offsets are .equ (positional
//      layout facts, like the reference tc_layout.inc).
//
//  Data model
//  ----------
//    All offsets are byte offsets from the base of their structure; all u64
//    fields are naturally 8-byte aligned (sizes are rounded up so the next
//    field stays aligned).  Strings are NUL-terminated byte arrays.
//    Pointers are 8-byte AArch64 addresses; 0 is the null pointer.
//
//  Conventions shared by every module
//  ----------------------------------
//    * Arguments in x0-x7 per AAPCS64; returns in x0 (x1/x2 for multi-value).
//    * Callee-saved registers x19-x28 are preserved by every exported helper.
//    * sp stays 16-byte aligned at every call site.
//    * Naming: cc_* is reserved for exported (.global) symbols.  Everything
//      file-local -- routines and data -- carries its module's prefix (util_,
//      env_, ctr_, ...); branch targets are .L labels.
//
//  Error/exit conventions (frozen)
//  -------------------------------
//    * Config/environment errors: "error: <message>" to stderr, exit 1.
//    * Runtime errors: "error: <message>" + exit 1.
//    * cc_fail(x0=msg) is the single exit-1 path (see cc_util.S).
//
#ifndef CC_LAYOUT_INC
#define CC_LAYOUT_INC

// ----------------------------------------------------------------------------
// Enum-ish ids (CPP macros — fail-loud).  Frozen numbering: never renumber.
// The order mirrors the Go All* arrays in names.go (AllPathNames,
// AllPathStatuses, AllStageStates, AllStageNames, AllControlComponents,
// AllControlActions) so status/JSON output order stays identical.
// ----------------------------------------------------------------------------
// Path names (names.go PathIngress0/PathNormalized)
#define CC_PATH_INGRESS0    0
#define CC_PATH_NORMALIZED  1
#define CC_PATH_COUNT       2

// Path statuses (controller.go Unknown/Ready/NotReady)
#define CC_STATUS_UNKNOWN   0
#define CC_STATUS_READY     1
#define CC_STATUS_NOTREADY  2
#define CC_STATUS_COUNT     3

// Stage states (controller.go Running/Stopped; NoTarget is the empty string).
// CC_STATE_COUNT is the number of VALID, routable states (Running, Stopped);
// NoTarget is excluded by intent, mirroring names.go's comment on
// AllStageStates.  It exists as a sentinel for "no target / converged".
#define CC_STATE_RUNNING    0
#define CC_STATE_STOPPED    1
#define CC_STATE_NOTARGET   2
#define CC_STATE_COUNT      2

// Stage names (names.go StageMediaMTX/StageNormalize/StageScaleAndEgress/
// StageSingleStageEgress)
#define CC_STAGE_MEDIAMTX           0
#define CC_STAGE_NORMALIZE          1
#define CC_STAGE_SCALE_AND_EGRESS   2
#define CC_STAGE_SINGLE_STAGE_EGRESS 3
#define CC_STAGE_COUNT              4

// Control components (names.go ComponentEgress)
#define CC_COMPONENT_EGRESS 0
#define CC_COMPONENT_COUNT  1

// Control actions (names.go ActionStart/ActionStop)
#define CC_ACTION_START     0
#define CC_ACTION_STOP      1
#define CC_ACTION_COUNT     2

// ----------------------------------------------------------------------------
// StageStatus {desired, actual} — controller.go
// ----------------------------------------------------------------------------
    .equ CC_SS_DESIRED,     0          // 8   CC_STATE_* (desired state id)
    .equ CC_SS_ACTUAL,      8          // 8   CC_STATE_* (actual state id)
    .equ CC_SS_SIZE,        16

// ----------------------------------------------------------------------------
// Stage — controller.go (map values are *Stage)
// ----------------------------------------------------------------------------
    .equ CC_STG_STATUS,         0      // 16  StageStatus {desired, actual}
    .equ CC_STG_OPS,            16     // 8   ptr to the ops table: one fn ptr
                                       //     per CC_STATE_* index (0 = no op)
    .equ CC_STG_INFLIGHT_SINCE, 24     // 16  monotonic timespec {tv_sec u64,
                                       //     tv_nsec u64}; both zero = not in
                                       //     flight (Go time.Time zero value)
    .equ CC_STG_SIZE,           40

// ----------------------------------------------------------------------------
// ControllerStatus {paths, stages} — controller.go (JSON wire type)
// ----------------------------------------------------------------------------
    .equ CC_CS_PATHS,   0              // 8   ptr to the paths status table
    .equ CC_CS_STAGES,  8              // 8   ptr to the stages status table
    .equ CC_CS_SIZE,    16

// ----------------------------------------------------------------------------
// PathEvent {path, status} — controller.go (the /event JSON message)
// ----------------------------------------------------------------------------
    .equ CC_PE_PATH,    0              // 8   CC_PATH_* id
    .equ CC_PE_STATUS,  8              // 8   CC_STATUS_* id
    .equ CC_PE_SIZE,    16

// ----------------------------------------------------------------------------
// StageEvent {stage, state} — controller.go
// ----------------------------------------------------------------------------
    .equ CC_SE_STAGE,   0              // 8   CC_STAGE_* id
    .equ CC_SE_STATE,   8              // 8   CC_STATE_* id
    .equ CC_SE_SIZE,    16

// ----------------------------------------------------------------------------
// ControlCommand {component, action} — controller.go (the /control message)
// ----------------------------------------------------------------------------
    .equ CC_CMD_COMPONENT,  0          // 8   CC_COMPONENT_* id
    .equ CC_CMD_ACTION,     8          // 8   CC_ACTION_* id
    .equ CC_CMD_SIZE,       16

// ----------------------------------------------------------------------------
// StageTarget {stage, state, prerequisite} — controller.go (route values)
// ----------------------------------------------------------------------------
    .equ CC_TGT_STAGE,   0             // 8   CC_STAGE_* id
    .equ CC_TGT_STATE,   8             // 8   CC_STATE_* id
    .equ CC_TGT_PREREQ,  16            // 8   prerequisite fn ptr (c)->err; 0 = none
    .equ CC_TGT_SIZE,    24

// ----------------------------------------------------------------------------
// Controller — controller.go (the big struct the ctr_ module owns)
// ----------------------------------------------------------------------------
//  ctx is the Go context.Context interface pair {type ptr, data ptr} = 16
//  bytes.  listeners is a Go slice {ptr, len, cap} = 24 bytes of
//  ControllerListener fn ptrs.  inflightTimeout is a time.Duration = u64
//  nanoseconds.  ops is the sync.WaitGroup port = an 8-byte active-op count.
    .equ CC_CTR_CTX,                 0  // 16  context {type ptr, data ptr}
    .equ CC_CTR_PATHS,               16 // 8   ptr to the paths status table
    .equ CC_CTR_STAGES,              24 // 8   ptr to the stages table
    .equ CC_CTR_PATH_EVENT_ROUTES,   32 // 8   ptr to the PathEvent route table
    .equ CC_CTR_COMMAND_ROUTES,      40 // 8   ptr to the ControlCommand route table
    .equ CC_CTR_LISTENERS,           48 // 24  slice {ptr, len, cap} of listener fn ptrs
    .equ CC_CTR_NOW,                 72 // 8   now() fn ptr -> monotonic timespec
    .equ CC_CTR_INFLIGHT_TIMEOUT,    80 // 8   u64 nanoseconds
    .equ CC_CTR_ACTIONS,             88 // 8   actions chan ptr
    .equ CC_CTR_OPS,                 96 // 8   active-ops counter (WaitGroup port)
    .equ CC_CTR_SIZE,                104

// ----------------------------------------------------------------------------
// Layout — paths.go (8 string pointers, one per path field)
// ----------------------------------------------------------------------------
    .equ CC_LAY_ENV,          0        // 8   ptr to the strimserver.env path
    .equ CC_LAY_TRANSCODE,    8        // 8   ptr to the transcode.sh path
    .equ CC_LAY_NOTIFY,       16       // 8   ptr to the notify.sh path
    .equ CC_LAY_MEDIAMTX_TMPL, 24      // 8   ptr to the mediamtx template path
    .equ CC_LAY_SRT_PASS,     32       // 8   ptr to the srt-passphrase path
    .equ CC_LAY_VIDEO_DIR,    40       // 8   ptr to the video-files dir path
    .equ CC_LAY_RESOLV_CONF,  48       // 8   ptr to the resolv.conf path
    .equ CC_LAY_TMP,          56       // 8   ptr to the temp dir path
    .equ CC_LAY_SIZE,         64

// Container-internal mount destinations (paths.go ctr* constants).  These are
// a contract with the mounted scripts (transcode.sh, notify.sh,
// entrypoint.mediamtx.sh); changing one means changing that script too.  The
// string CONTENT lives here as a CPP macro (fail-loud, single source of
// truth); the rodata labels are defined in the module that needs them:
//     RODATA
// cc_s_ctr_env:   .asciz CC_CTR_ENV
#define CC_CTR_ENV          "/strimserver.env"
#define CC_CTR_TRANSCODE    "/transcode.sh"
#define CC_CTR_NOTIFY       "/notify.sh"
#define CC_CTR_MEDIAMTX_TMPL "/mediamtx.yaml.template"  // == MEDIAMTX_CONFIG_TEMPLATE
#define CC_CTR_SRT_SECRET   "/run/secrets/srt-passphrase"
#define CC_CTR_VIDEO_DIR    "/video-files"
#define CC_CTR_RESOLV_CONF  "/etc/resolv.conf"
#define CC_CTR_TMP          "/tmp"

// ----------------------------------------------------------------------------
// Env spec ids (envspec.go — the env vars the controller CONSUMES; the
// nil-Bind media vars are consumed by the mounted scripts, never by the
// controller, so they are intentionally not here).  CPP macros (#define)
// index into the cc_env.S env-spec table (name ptr + bind kind),
// CC_ENV_COUNT sizes it.  Frozen numbering; append at the end and bump
// CC_ENV_COUNT.  (CPP macros, not .equ, per the fail-loud discipline: a
// module-local `.equ CC_ENV_X, N` then fails to assemble instead of silently
// shadowing the shared value.)
// ----------------------------------------------------------------------------
#define CC_ENV_CONTAINERD_SOCKET         0
#define CC_ENV_CONTAINERD_NAMESPACE      1
#define CC_ENV_CONTROLLER_HTTP_PORT      2
#define CC_ENV_STRIMSERVER_HOST_ROOT     3
#define CC_ENV_CONTROLLER_RECONCILE_INTERVAL  4
#define CC_ENV_CONTROLLER_INFLIGHT_TIMEOUT    5
#define CC_ENV_CONTROLLER_SHUTDOWN_TIMEOUT    6
#define CC_ENV_STAGE_STOP_TIMEOUT             7
#define CC_ENV_WEBSOCKET_WRITE_TIMEOUT        8
#define CC_ENV_CONTROLLER_ACTIONS_BUFFER_SIZE 9
#define CC_ENV_ENABLE_SINGLE_STAGE_PIPELINE   10
#define CC_ENV_MEDIAMTX_CONTAINER_ID          11
#define CC_ENV_MEDIAMTX_SNAPSHOT_ID           12
#define CC_ENV_MEDIAMTX_IMAGE_NAME            13
#define CC_ENV_MEDIAMTX_LOG_FILE              14
#define CC_ENV_NORMALIZE_CONTAINER_ID         15
#define CC_ENV_NORMALIZE_SNAPSHOT_ID          16
#define CC_ENV_NORMALIZE_LOG_FILE             17
#define CC_ENV_EGRESS_CONTAINER_ID            18
#define CC_ENV_SINGLE_STAGE_EGRESS_CONTAINER_ID 19
#define CC_ENV_EGRESS_SNAPSHOT_ID             20
#define CC_ENV_EGRESS_LOG_FILE                21
#define CC_ENV_FFMPEG_IMAGE_NAME              22
#define CC_ENV_COUNT                          23

// ----------------------------------------------------------------------------
// Env-runtime block (cc_env.S) — appended at the END of the Layout struct per
// the freeze discipline (never renumber CC_LAY_*; new fields go here).
//
//  The Go controller's LoadConfig (main.go:99-115) parses every env var in
//  envSpec() into a Config struct whose string fields are Go strings (data
//  pointer + length).  The assembly port stores the same typed values:
//    * strings  -> 8-byte pointers to the getenv() result (process-lifetime
//                  stable; 0 = absent/empty = Go's "" default)
//    * duration -> u64 nanoseconds (time.Duration is int64 ns; negative
//                  values are stored as two's-complement u64, exactly the
//                  Go int64 bit pattern)
//    * uint8 / bool -> 1 byte (0 = absent/empty = Go's zero value)
//  Offsets are relative to the base of the env-runtime block, which sits at
//  CC_LAY_SIZE from the Layout base: cc_env_load(x0=layout ptr) writes at
//  x0 + CC_LAY_SIZE + CC_ER_*.
// ----------------------------------------------------------------------------
    .equ CC_ER_CONTAINERD_SOCKET,          0      // 8   ptr
    .equ CC_ER_CONTAINERD_NAMESPACE,       8      // 8   ptr
    .equ CC_ER_CONTROLLER_HTTP_PORT,       16     // 8   ptr
    .equ CC_ER_HOST_ROOT,                  24     // 8   ptr
    .equ CC_ER_RECONCILE_INTERVAL,         32     // 8   u64 ns
    .equ CC_ER_INFLIGHT_TIMEOUT,           40     // 8   u64 ns
    .equ CC_ER_SHUTDOWN_TIMEOUT,           48     // 8   u64 ns
    .equ CC_ER_STAGE_STOP_TIMEOUT,         56     // 8   u64 ns
    .equ CC_ER_WEBSOCKET_WRITE_TIMEOUT,    64     // 8   u64 ns
    .equ CC_ER_ACTIONS_BUFFER_SIZE,        72     // 1   u8
    .equ CC_ER_ENABLE_SINGLE_STAGE,        73     // 1   u8 (bool)
    .equ CC_ER_MEDIAMTX,                   80     // 32  ContainerConfig
    .equ CC_ER_NORMALIZE,                  112    // 32  ContainerConfig
    .equ CC_ER_SCALE_AND_EGRESS,           144    // 32  ContainerConfig
    .equ CC_ER_SINGLE_STAGE_EGRESS,        176    // 32  ContainerConfig
    .equ CC_ER_SIZE,                       208

// ContainerConfig sub-offsets (main.go:28 ContainerConfig struct: 4 strings)
    .equ CC_CC_CONTAINER_ID,  0
    .equ CC_CC_SNAPSHOT_ID,   8
    .equ CC_CC_IMAGE_NAME,    16
    .equ CC_CC_LOGFILE,       24
    .equ CC_CC_SIZE,          32

// ============================================================================
// Exported symbol contracts (see each module's header for the full text)
// ============================================================================
//
// cc_util.S
//   cc_strlen(x0=s)                       -> x0 = length (no NUL)
//   cc_streq(x0=a, x1=b)                  -> x0 = 1/0
//   cc_puts(x0=s)                         print s to stdout (unbuffered write(2))
//   cc_eputs(x0=s)                        print s to stderr (unbuffered)
//   cc_putu64(x0=v)                       print u64 decimal to stdout
//   cc_fail(x0=msg)                       "error: <msg>\n" stderr, exit 1
//   cc_cat_cstr(x0=dst, x1=s)             -> x0 = position of the copied NUL
//   cc_fmt2(x0=dst, x1=v)                 -> x0 = dst+2 (zero-padded digits)
//   cc_fmt4(x0=dst, x1=v)                 -> x0 = dst+4 (zero-padded digits)
//   cc_env_int(x0=name)                   -> x0 = int or 0 (port of tc_env_int)
//   cc_snprintf_i(x0=buf, x1=size, x2=fmt, x3=int)   -> x0 = snprintf() result
//   cc_snprintf_d(x0=buf, x1=size, x2=fmt, d0=double) -> x0 = snprintf() result
//
// ============================================================================

#endif // CC_LAYOUT_INC