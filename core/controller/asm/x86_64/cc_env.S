// ============================================================================
// cc_env.S — env-config parsing for the strimserver controller (x86-64 port)
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
//  This module is the L1 env layer of the x86-64 port: it translates the
//  AArch64 cc_env.S (the port of core/controller/envspec.go + main.go
//  LoadConfig) instruction by instruction.  It owns the env-spec table
//  (indexed by the CC_ENV_* ids from cc_layout.inc), the typed parse
//  helpers, and the two codegen emitters the controller exposes
//  (`-print-env-example`, `-print-ts-types`).
//
//  Exported (all .global, SysV, %rbx/%rbp/%r12-%r15 preserved):
//    cc_env_load(rdi=layout ptr)      parse every env var in the table into
//                                     the caller's env-runtime block
//                                     (rdi + CC_LAY_SIZE + CC_ER_*); fail-loud
//                                     (exit 1) on a missing required var or an
//                                     invalid value
//    cc_env_u8(rdi=name)    -> rax = u8 value (0 on absent), ParseUint(s,10,8)
//    cc_env_dur(rdi=name)   -> rax = u64 ns (0 on absent), time.ParseDuration
//    cc_env_bool(rdi=name)  -> rax = 0/1 (0 on absent), strconv.ParseBool
//    cc_env_str(rdi=name)   -> rax = ptr to the raw value or null (absent)
//    cc_env_print_example()    print the -print-env-example output
//    cc_env_print_ts_types()   print the -print-ts-types output
//
//  MOV_DUR_MIN / MOV_DUR_HOUR resolution (the known AArch64/x86 conflict)
//  ----------------------------------------------------------------------
//  The shared AArch64 header cc_env.h still carries the AArch64 movz/movk
//  definitions of the MOV_DUR_MIN/MOV_DUR_HOUR .macro (GAS errors on a
//  duplicate .macro definition), so this module deliberately does NOT
//  #include cc_env.h.  The x86-64 movabs definitions live in
//  cc_platform_x86_64.h (included below) and are the single source used
//  here; the CC_ENVKIND_* / CC_ENVSTORE_* ids this module needs are
//  re-declared as local CPP macros below (identical values, fail-loud
//  against an accidental .equ copy).
//
//  Multi-value return convention (module-internal helpers)
//  ------------------------------------------------------
//  The AArch64 helpers return in x0/x1/x2/x3; the x86-64 port returns in
//  %rax, %rdx, %rcx, %rsi (all caller-saved).  Arguments stay in the SysV
//  registers (rdi/rsi/rdx), exactly the AArch64 x0/x1/x2 mapping.
//
//  SysV AMD64 notes (see cc_util.S for the full rules)
//  --------------------------------------------------
//    * Arguments in %rdi, %rsi, %rdx, %rcx, %r8, %r9; floats in
//      %xmm0-%xmm7; return in %rax.  Callee-saved: %rbx, %rbp, %r12-%r15.
//    * %rsp stays 16-byte aligned at every call site.
//    * Never join statements with ';' — it is a statement separator on x86.
//      One instruction per line.  Comments are `//` (this project's dialect).
//
// ============================================================================

#include "cc_platform_x86_64.h"
#include "../cc_layout.inc"

// ----------------------------------------------------------------------------
// Module-local CPP constants (cc_env.h is NOT included — see the MOV_DUR
// note above; these mirror its values exactly).
// ----------------------------------------------------------------------------
#define CC_ENVKIND_STRING   0
#define CC_ENVKIND_DURATION 1
#define CC_ENVKIND_U8       2
#define CC_ENVKIND_BOOL     3

#define CC_ENVSTORE_ONE         0
#define CC_ENVSTORE_SNAP_BOTH   1
#define CC_ENVSTORE_LOG_BOTH    2
#define CC_ENVSTORE_IMAGE_THREE 3

// 1<<63 — the ParseDuration overflow bound (time/format.go), loaded by
// movabs (no literal pool).  Not a 32-bit sign-extended immediate.
#define CC_DUR_1SHL63 0x8000000000000000

// ----------------------------------------------------------------------------
// Env-spec table (envspec.go envSpec(), the 23 controller-consumed vars).
//
//  Entry (16 bytes), indexed by CC_ENV_*:
//    +0  name ptr             (8)
//    +8  bind kind            (1)  CC_ENVKIND_*
//    +9  required             (1)  0/1  (Go EnvVar.Required)
//    +10 store op             (1)  CC_ENVSTORE_* (how many config fields)
//    +11 pad                  (1)
//    +12 target offset        (4)  CC_ER_* offset of the primary field
//
//  The store ops mirror the Go Bind closures that write MORE than one Config
//  field (envspec.go:170-197):
//    CC_ENVSTORE_ONE         single target
//    CC_ENVSTORE_SNAP_BOTH   EGRESS_SNAPSHOT_ID -> ScaleAndEgress.SnapshotID
//                            + SingleStageEgress.SnapshotID
//    CC_ENVSTORE_LOG_BOTH    EGRESS_LOG_FILE -> ScaleAndEgress.Logfile
//                            + SingleStageEgress.Logfile
//    CC_ENVSTORE_IMAGE_THREE FFMPEG_IMAGE_NAME -> Normalize.ImageName,
//                            ScaleAndEgress.ImageName, SingleStageEgress.ImageName
// ----------------------------------------------------------------------------
    .macro ENV_ENTRY name, kind, required, store_op, target
    .balign 8                       // explicit 8-align for the name pointer:
                                    // GAS auto-aligns a relocated .quad,
                                    // LLVM MC (clang) does not — the explicit
                                    // .balign keeps the 16-byte entry stride
                                    // identical on both assemblers
                                    // (cc_env_load indexes by id*16).  The
                                    // trailing .balign pads EVERY entry,
                                    // including the last, to 16 bytes.
    .quad \name
    .byte \kind
    .byte \required
    .byte \store_op
    .byte 0
    .word \target
    .balign 8
    .endm

    RODATA
env_spec:
    ENV_ENTRY env_s_containerd_socket, CC_ENVKIND_STRING,    1, CC_ENVSTORE_ONE,        CC_ER_CONTAINERD_SOCKET
    ENV_ENTRY env_s_containerd_namespace, CC_ENVKIND_STRING, 1, CC_ENVSTORE_ONE,        CC_ER_CONTAINERD_NAMESPACE
    ENV_ENTRY env_s_controller_http_port, CC_ENVKIND_STRING, 1, CC_ENVSTORE_ONE,        CC_ER_CONTROLLER_HTTP_PORT
    ENV_ENTRY env_s_strimserver_host_root, CC_ENVKIND_STRING, 1, CC_ENVSTORE_ONE,       CC_ER_HOST_ROOT
    ENV_ENTRY env_s_reconcile_interval, CC_ENVKIND_DURATION, 1, CC_ENVSTORE_ONE,        CC_ER_RECONCILE_INTERVAL
    ENV_ENTRY env_s_inflight_timeout, CC_ENVKIND_DURATION,   1, CC_ENVSTORE_ONE,        CC_ER_INFLIGHT_TIMEOUT
    ENV_ENTRY env_s_shutdown_timeout, CC_ENVKIND_DURATION,   1, CC_ENVSTORE_ONE,        CC_ER_SHUTDOWN_TIMEOUT
    ENV_ENTRY env_s_stage_stop_timeout, CC_ENVKIND_DURATION, 1, CC_ENVSTORE_ONE,        CC_ER_STAGE_STOP_TIMEOUT
    ENV_ENTRY env_s_websocket_write_timeout, CC_ENVKIND_DURATION, 1, CC_ENVSTORE_ONE,   CC_ER_WEBSOCKET_WRITE_TIMEOUT
    ENV_ENTRY env_s_actions_buffer_size, CC_ENVKIND_U8,      1, CC_ENVSTORE_ONE,        CC_ER_ACTIONS_BUFFER_SIZE
    ENV_ENTRY env_s_enable_single_stage, CC_ENVKIND_BOOL,    0, CC_ENVSTORE_ONE,        CC_ER_ENABLE_SINGLE_STAGE
    ENV_ENTRY env_s_mediamtx_container_id, CC_ENVKIND_STRING, 1, CC_ENVSTORE_ONE,       CC_ER_MEDIAMTX + CC_CC_CONTAINER_ID
    ENV_ENTRY env_s_mediamtx_snapshot_id, CC_ENVKIND_STRING, 1, CC_ENVSTORE_ONE,        CC_ER_MEDIAMTX + CC_CC_SNAPSHOT_ID
    ENV_ENTRY env_s_mediamtx_image_name, CC_ENVKIND_STRING,  1, CC_ENVSTORE_ONE,        CC_ER_MEDIAMTX + CC_CC_IMAGE_NAME
    ENV_ENTRY env_s_mediamtx_log_file, CC_ENVKIND_STRING,    1, CC_ENVSTORE_ONE,        CC_ER_MEDIAMTX + CC_CC_LOGFILE
    ENV_ENTRY env_s_normalize_container_id, CC_ENVKIND_STRING, 1, CC_ENVSTORE_ONE,      CC_ER_NORMALIZE + CC_CC_CONTAINER_ID
    ENV_ENTRY env_s_normalize_snapshot_id, CC_ENVKIND_STRING, 1, CC_ENVSTORE_ONE,       CC_ER_NORMALIZE + CC_CC_SNAPSHOT_ID
    ENV_ENTRY env_s_normalize_log_file, CC_ENVKIND_STRING,   1, CC_ENVSTORE_ONE,        CC_ER_NORMALIZE + CC_CC_LOGFILE
    ENV_ENTRY env_s_egress_container_id, CC_ENVKIND_STRING,  1, CC_ENVSTORE_ONE,        CC_ER_SCALE_AND_EGRESS + CC_CC_CONTAINER_ID
    ENV_ENTRY env_s_single_stage_egress_cid, CC_ENVKIND_STRING, 0, CC_ENVSTORE_ONE,     CC_ER_SINGLE_STAGE_EGRESS + CC_CC_CONTAINER_ID
    ENV_ENTRY env_s_egress_snapshot_id, CC_ENVKIND_STRING,   1, CC_ENVSTORE_SNAP_BOTH,  CC_ER_SCALE_AND_EGRESS + CC_CC_SNAPSHOT_ID
    ENV_ENTRY env_s_egress_log_file, CC_ENVKIND_STRING,      1, CC_ENVSTORE_LOG_BOTH,   CC_ER_SCALE_AND_EGRESS + CC_CC_LOGFILE
    ENV_ENTRY env_s_ffmpeg_image_name, CC_ENVKIND_STRING,    1, CC_ENVSTORE_IMAGE_THREE, CC_ER_NORMALIZE + CC_CC_IMAGE_NAME

// Env var names (envspec.go Name fields)
env_s_containerd_socket:
    .asciz "CONTAINERD_SOCKET"
env_s_containerd_namespace:
    .asciz "CONTAINERD_NAMESPACE"
env_s_controller_http_port:
    .asciz "CONTROLLER_HTTP_PORT"
env_s_strimserver_host_root:
    .asciz "STRIMSERVER_HOST_ROOT"
env_s_reconcile_interval:
    .asciz "CONTROLLER_RECONCILE_INTERVAL"
env_s_inflight_timeout:
    .asciz "CONTROLLER_INFLIGHT_TIMEOUT"
env_s_shutdown_timeout:
    .asciz "CONTROLLER_SHUTDOWN_TIMEOUT"
env_s_stage_stop_timeout:
    .asciz "STAGE_STOP_TIMEOUT"
env_s_websocket_write_timeout:
    .asciz "WEBSOCKET_WRITE_TIMEOUT"
env_s_actions_buffer_size:
    .asciz "CONTROLLER_ACTIONS_BUFFER_SIZE"
env_s_enable_single_stage:
    .asciz "ENABLE_SINGLE_STAGE_PIPELINE"
env_s_mediamtx_container_id:
    .asciz "MEDIAMTX_CONTAINER_ID"
env_s_mediamtx_snapshot_id:
    .asciz "MEDIAMTX_SNAPSHOT_ID"
env_s_mediamtx_image_name:
    .asciz "MEDIAMTX_IMAGE_NAME"
env_s_mediamtx_log_file:
    .asciz "MEDIAMTX_LOG_FILE"
env_s_normalize_container_id:
    .asciz "NORMALIZE_CONTAINER_ID"
env_s_normalize_snapshot_id:
    .asciz "NORMALIZE_SNAPSHOT_ID"
env_s_normalize_log_file:
    .asciz "NORMALIZE_LOG_FILE"
env_s_egress_container_id:
    .asciz "EGRESS_CONTAINER_ID"
env_s_single_stage_egress_cid:
    .asciz "SINGLE_STAGE_EGRESS_CONTAINER_ID"
env_s_egress_snapshot_id:
    .asciz "EGRESS_SNAPSHOT_ID"
env_s_egress_log_file:
    .asciz "EGRESS_LOG_FILE"
env_s_ffmpeg_image_name:
    .asciz "FFMPEG_IMAGE_NAME"

// Fail-loud message fragments (see the module header for the format)
env_msg_invalid_value_for:
    .asciz "invalid value for "
env_msg_sep:
    .asciz ": "
env_msg_missing_required:
    .asciz "missing required env var "
env_msg_invalid_duration:
    .asciz "invalid duration"
env_msg_missing_unit:
    .asciz "missing unit in duration"
env_msg_unknown_unit:
    .asciz "unknown unit in duration"
env_msg_invalid_bool:
    .asciz "invalid bool value"
env_msg_invalid_u8:
    .asciz "invalid uint8 value"
env_msg_u8_range:
    .asciz "value out of range"

// ParseBool accepted strings (internal/strconv/atob.go:12-15)
env_bool_true_1:
    .asciz "1"
env_bool_true_t:
    .asciz "t"
env_bool_true_T:
    .asciz "T"
env_bool_true_true:
    .asciz "true"
env_bool_true_TRUE:
    .asciz "TRUE"
env_bool_true_True:
    .asciz "True"
env_bool_false_0:
    .asciz "0"
env_bool_false_f:
    .asciz "f"
env_bool_false_F:
    .asciz "F"
env_bool_false_false:
    .asciz "false"
env_bool_false_FALSE:
    .asciz "FALSE"
env_bool_false_False:
    .asciz "False"

// ----------------------------------------------------------------------------
// printEnvExample table (main.go:52-59).  46 entries, the FULL envSpec()
// including the media/twitch/secrets vars the controller never parses.
//  Entry (32 bytes):
//    +0  group id     (1)  CC_GRP_*
//    +8  comment      (8)  ptr or 0 (Go EnvVar.Comment)
//    +16 name         (8)  ptr (Go EnvVar.Name)
//    +24 example      (8)  ptr (Go EnvVar.Example)
//  The emitter reproduces Go's %q on Example: every example in envspec.go is
//  printable ASCII without quotes or backslashes, so %q is literal `"..."`.
// ----------------------------------------------------------------------------
#define CC_GRP_CONTROLLER 0
#define CC_GRP_STAGE      1
#define CC_GRP_MEDIA      2
#define CC_GRP_TWITCH     3
#define CC_GRP_SECRETS    4
#define CC_ENV_EXAMPLE_COUNT 46

    .macro ENV_EX_ENTRY group, comment, name, example
    .byte \group
    .zero 7
    .quad \comment
    .quad \name
    .quad \example
    .endm

env_example_table:
    // ---------------------------------------------------------- Controller
    ENV_EX_ENTRY CC_GRP_CONTROLLER, env_ex_c_socket, env_ex_n_socket, env_ex_e_socket
    ENV_EX_ENTRY CC_GRP_CONTROLLER, 0, env_ex_n_namespace, env_ex_e_namespace
    ENV_EX_ENTRY CC_GRP_CONTROLLER, env_ex_c_http_port, env_ex_n_http_port, env_ex_e_http_port
    ENV_EX_ENTRY CC_GRP_CONTROLLER, env_ex_c_host_root, env_ex_n_host_root, env_ex_e_host_root
    ENV_EX_ENTRY CC_GRP_CONTROLLER, env_ex_c_reconcile, env_ex_n_reconcile, env_ex_e_reconcile
    ENV_EX_ENTRY CC_GRP_CONTROLLER, env_ex_c_inflight, env_ex_n_inflight, env_ex_e_inflight
    ENV_EX_ENTRY CC_GRP_CONTROLLER, env_ex_c_shutdown, env_ex_n_shutdown, env_ex_e_shutdown
    ENV_EX_ENTRY CC_GRP_CONTROLLER, env_ex_c_stage_stop, env_ex_n_stage_stop, env_ex_e_stage_stop
    ENV_EX_ENTRY CC_GRP_CONTROLLER, env_ex_c_ws_write, env_ex_n_ws_write, env_ex_e_ws_write
    ENV_EX_ENTRY CC_GRP_CONTROLLER, env_ex_c_actions_buf, env_ex_n_actions_buf, env_ex_e_actions_buf
    ENV_EX_ENTRY CC_GRP_CONTROLLER, env_ex_c_single_stage, env_ex_n_single_stage, env_ex_e_single_stage
    // -------------------------------------------------------- Stage containers
    ENV_EX_ENTRY CC_GRP_STAGE, 0, env_ex_n_mtx_cid, env_ex_e_mtx_cid
    ENV_EX_ENTRY CC_GRP_STAGE, 0, env_ex_n_mtx_sid, env_ex_e_mtx_sid
    ENV_EX_ENTRY CC_GRP_STAGE, 0, env_ex_n_mtx_img, env_ex_e_mtx_img
    ENV_EX_ENTRY CC_GRP_STAGE, 0, env_ex_n_mtx_log, env_ex_e_mtx_log
    ENV_EX_ENTRY CC_GRP_STAGE, 0, env_ex_n_norm_cid, env_ex_e_norm_cid
    ENV_EX_ENTRY CC_GRP_STAGE, 0, env_ex_n_norm_sid, env_ex_e_norm_sid
    ENV_EX_ENTRY CC_GRP_STAGE, 0, env_ex_n_norm_log, env_ex_e_norm_log
    ENV_EX_ENTRY CC_GRP_STAGE, 0, env_ex_n_egress_cid, env_ex_e_egress_cid
    ENV_EX_ENTRY CC_GRP_STAGE, 0, env_ex_n_single_egress_cid, env_ex_e_single_egress_cid
    ENV_EX_ENTRY CC_GRP_STAGE, 0, env_ex_n_egress_sid, env_ex_e_egress_sid
    ENV_EX_ENTRY CC_GRP_STAGE, 0, env_ex_n_egress_log, env_ex_e_egress_log
    ENV_EX_ENTRY CC_GRP_STAGE, env_ex_c_ffmpeg_img, env_ex_n_ffmpeg_img, env_ex_e_ffmpeg_img
    // ---------------------------------------------------------- Media / ffmpeg
    ENV_EX_ENTRY CC_GRP_MEDIA, env_ex_c_ffmpeg_nice, env_ex_n_ffmpeg_nice, env_ex_e_ffmpeg_nice
    ENV_EX_ENTRY CC_GRP_MEDIA, 0, env_ex_n_ffmpeg_loglevel, env_ex_e_ffmpeg_loglevel
    ENV_EX_ENTRY CC_GRP_MEDIA, 0, env_ex_n_mtx_nice, env_ex_e_mtx_nice
    ENV_EX_ENTRY CC_GRP_MEDIA, env_ex_c_mtx_tmpl, env_ex_n_mtx_tmpl, env_ex_e_mtx_tmpl
    ENV_EX_ENTRY CC_GRP_MEDIA, env_ex_c_srt_port, env_ex_n_srt_port, env_ex_e_srt_port
    ENV_EX_ENTRY CC_GRP_MEDIA, env_ex_c_rtsp_port, env_ex_n_rtsp_port, env_ex_e_rtsp_port
    ENV_EX_ENTRY CC_GRP_MEDIA, env_ex_c_mpegts_sock, env_ex_n_mpegts_sock, env_ex_e_mpegts_sock
    ENV_EX_ENTRY CC_GRP_MEDIA, env_ex_c_mtx_read_to, env_ex_n_mtx_read_to, env_ex_e_mtx_read_to
    ENV_EX_ENTRY CC_GRP_MEDIA, 0, env_ex_n_video_bitrate, env_ex_e_video_bitrate
    ENV_EX_ENTRY CC_GRP_MEDIA, 0, env_ex_n_video_maxrate, env_ex_e_video_maxrate
    ENV_EX_ENTRY CC_GRP_MEDIA, 0, env_ex_n_video_minrate, env_ex_e_video_minrate
    ENV_EX_ENTRY CC_GRP_MEDIA, 0, env_ex_n_video_bufsize, env_ex_e_video_bufsize
    ENV_EX_ENTRY CC_GRP_MEDIA, 0, env_ex_n_audio_bitrate, env_ex_e_audio_bitrate
    ENV_EX_ENTRY CC_GRP_MEDIA, env_ex_c_scaled_height, env_ex_n_scaled_height, env_ex_e_scaled_height
    ENV_EX_ENTRY CC_GRP_MEDIA, 0, env_ex_n_egress_vbitrate, env_ex_e_egress_vbitrate
    ENV_EX_ENTRY CC_GRP_MEDIA, 0, env_ex_n_egress_vmaxrate, env_ex_e_egress_vmaxrate
    ENV_EX_ENTRY CC_GRP_MEDIA, 0, env_ex_n_egress_vminrate, env_ex_e_egress_vminrate
    ENV_EX_ENTRY CC_GRP_MEDIA, 0, env_ex_n_egress_vbufsize, env_ex_e_egress_vbufsize
    ENV_EX_ENTRY CC_GRP_MEDIA, 0, env_ex_n_egress_abitrate, env_ex_e_egress_abitrate
    // --------------------------------------------------------- Twitch / egress
    ENV_EX_ENTRY CC_GRP_TWITCH, 0, env_ex_n_twitch_ingest, env_ex_e_twitch_ingest
    ENV_EX_ENTRY CC_GRP_TWITCH, env_ex_c_twitch_key, env_ex_n_twitch_key, env_ex_e_twitch_key
    ENV_EX_ENTRY CC_GRP_TWITCH, env_ex_c_bandwidth, env_ex_n_bandwidth, env_ex_e_bandwidth
    // ---------------------------------------------------------------- Secrets
    ENV_EX_ENTRY CC_GRP_SECRETS, env_ex_c_srt_pass, env_ex_n_srt_pass, env_ex_e_srt_pass

env_group_names:
    .quad env_grp_controller
    .quad env_grp_stage
    .quad env_grp_media
    .quad env_grp_twitch
    .quad env_grp_secrets

env_grp_controller:
    .asciz "Controller"
env_grp_stage:
    .asciz "Stage containers"
env_grp_media:
    .asciz "Media / ffmpeg"
env_grp_twitch:
    .asciz "Twitch / egress"
env_grp_secrets:
    .asciz "Secrets"

env_group_header_prefix:
    .asciz "\n# --- "
env_group_header_suffix:
    .asciz " ---\n"
env_comment_prefix:
    .asciz "# "
env_newline:
    .asciz "\n"
env_eq_quote:
    .asciz "=\""
env_quote_newline:
    .asciz "\"\n"

// printEnvExample names (envspec.go Name fields)
env_ex_n_socket:
    .asciz "CONTAINERD_SOCKET"
env_ex_n_namespace:
    .asciz "CONTAINERD_NAMESPACE"
env_ex_n_http_port:
    .asciz "CONTROLLER_HTTP_PORT"
env_ex_n_host_root:
    .asciz "STRIMSERVER_HOST_ROOT"
env_ex_n_reconcile:
    .asciz "CONTROLLER_RECONCILE_INTERVAL"
env_ex_n_inflight:
    .asciz "CONTROLLER_INFLIGHT_TIMEOUT"
env_ex_n_shutdown:
    .asciz "CONTROLLER_SHUTDOWN_TIMEOUT"
env_ex_n_stage_stop:
    .asciz "STAGE_STOP_TIMEOUT"
env_ex_n_ws_write:
    .asciz "WEBSOCKET_WRITE_TIMEOUT"
env_ex_n_actions_buf:
    .asciz "CONTROLLER_ACTIONS_BUFFER_SIZE"
env_ex_n_single_stage:
    .asciz "ENABLE_SINGLE_STAGE_PIPELINE"
env_ex_n_mtx_cid:
    .asciz "MEDIAMTX_CONTAINER_ID"
env_ex_n_mtx_sid:
    .asciz "MEDIAMTX_SNAPSHOT_ID"
env_ex_n_mtx_img:
    .asciz "MEDIAMTX_IMAGE_NAME"
env_ex_n_mtx_log:
    .asciz "MEDIAMTX_LOG_FILE"
env_ex_n_norm_cid:
    .asciz "NORMALIZE_CONTAINER_ID"
env_ex_n_norm_sid:
    .asciz "NORMALIZE_SNAPSHOT_ID"
env_ex_n_norm_log:
    .asciz "NORMALIZE_LOG_FILE"
env_ex_n_egress_cid:
    .asciz "EGRESS_CONTAINER_ID"
env_ex_n_single_egress_cid:
    .asciz "SINGLE_STAGE_EGRESS_CONTAINER_ID"
env_ex_n_egress_sid:
    .asciz "EGRESS_SNAPSHOT_ID"
env_ex_n_egress_log:
    .asciz "EGRESS_LOG_FILE"
env_ex_n_ffmpeg_img:
    .asciz "FFMPEG_IMAGE_NAME"
env_ex_n_ffmpeg_nice:
    .asciz "FFMPEG_NICE"
env_ex_n_ffmpeg_loglevel:
    .asciz "FFMPEG_LOG_LEVEL"
env_ex_n_mtx_nice:
    .asciz "MEDIAMTX_NICE"
env_ex_n_mtx_tmpl:
    .asciz "MEDIAMTX_CONFIG_TEMPLATE"
env_ex_n_srt_port:
    .asciz "STRIMSERVER_SRT_PORT"
env_ex_n_rtsp_port:
    .asciz "STRIMSERVER_RTSP_PORT"
env_ex_n_mpegts_sock:
    .asciz "NORMALIZED_MPEGTS_SOCKET"
env_ex_n_mtx_read_to:
    .asciz "MEDIAMTX_READ_TIMEOUT_DURATION"
env_ex_n_video_bitrate:
    .asciz "NORMALIZED_VIDEO_BITRATE"
env_ex_n_video_maxrate:
    .asciz "NORMALIZED_VIDEO_MAXRATE"
env_ex_n_video_minrate:
    .asciz "NORMALIZED_VIDEO_MINRATE"
env_ex_n_video_bufsize:
    .asciz "NORMALIZED_VIDEO_BUFSIZE"
env_ex_n_audio_bitrate:
    .asciz "NORMALIZED_AUDIO_BITRATE"
env_ex_n_scaled_height:
    .asciz "SCALED_VIDEO_HEIGHT_PIXELS"
env_ex_n_egress_vbitrate:
    .asciz "EGRESS_VIDEO_BITRATE"
env_ex_n_egress_vmaxrate:
    .asciz "EGRESS_VIDEO_MAXRATE"
env_ex_n_egress_vminrate:
    .asciz "EGRESS_VIDEO_MINRATE"
env_ex_n_egress_vbufsize:
    .asciz "EGRESS_VIDEO_BUFSIZE"
env_ex_n_egress_abitrate:
    .asciz "EGRESS_AUDIO_BITRATE"
env_ex_n_twitch_ingest:
    .asciz "TWITCH_INGEST_SERVER"
env_ex_n_twitch_key:
    .asciz "TWITCH_STREAM_KEY"
env_ex_n_bandwidth:
    .asciz "BANDWIDTH_TEST"
env_ex_n_srt_pass:
    .asciz "SRT_PUBLISH_PASSPHRASE"

// printEnvExample examples (envspec.go Example fields)
env_ex_e_socket:
    .asciz "/containerd.sock"
env_ex_e_namespace:
    .asciz "strimserver"
env_ex_e_http_port:
    .asciz "4000"
env_ex_e_host_root:
    .asciz "/mnt/nvme"
env_ex_e_reconcile:
    .asciz "5s"
env_ex_e_inflight:
    .asciz "30s"
env_ex_e_shutdown:
    .asciz "30s"
env_ex_e_stage_stop:
    .asciz "10s"
env_ex_e_ws_write:
    .asciz "5s"
env_ex_e_actions_buf:
    .asciz "16"
env_ex_e_single_stage:
    .asciz "false"
env_ex_e_mtx_cid:
    .asciz "mediamtx"
env_ex_e_mtx_sid:
    .asciz "mediamtx-snapshot"
env_ex_e_mtx_img:
    .asciz "docker.io/library/mediamtx:latest"
env_ex_e_mtx_log:
    .asciz "/mnt/nvme/logs/mediamtx.log"
env_ex_e_norm_cid:
    .asciz "normalize"
env_ex_e_norm_sid:
    .asciz "normalize-snapshot"
env_ex_e_norm_log:
    .asciz "/mnt/nvme/logs/normalize.log"
env_ex_e_egress_cid:
    .asciz "scale-and-egress"
env_ex_e_single_egress_cid:
    .asciz "single-stage-egress"
env_ex_e_egress_sid:
    .asciz "egress-snapshot"
env_ex_e_egress_log:
    .asciz "/mnt/nvme/logs/egress.log"
env_ex_e_ffmpeg_img:
    .asciz "docker.io/library/ffmpeg:latest"
env_ex_e_ffmpeg_nice:
    .asciz "-5"
env_ex_e_ffmpeg_loglevel:
    .asciz "info"
env_ex_e_mtx_nice:
    .asciz "-10"
env_ex_e_mtx_tmpl:
    .asciz "/mediamtx.yaml.template"
env_ex_e_srt_port:
    .asciz "9000"
env_ex_e_rtsp_port:
    .asciz "8554"
env_ex_e_mpegts_sock:
    .asciz "/tmp/strimserver-normalized.sock"
env_ex_e_mtx_read_to:
    .asciz "12s"
env_ex_e_video_bitrate:
    .asciz "9000k"
env_ex_e_video_maxrate:
    .asciz "9000k"
env_ex_e_video_minrate:
    .asciz "9000k"
env_ex_e_video_bufsize:
    .asciz "9000k"
env_ex_e_audio_bitrate:
    .asciz "320k"
env_ex_e_scaled_height:
    .asciz "936"
env_ex_e_egress_vbitrate:
    .asciz "2500k"
env_ex_e_egress_vmaxrate:
    .asciz "2500k"
env_ex_e_egress_vminrate:
    .asciz "2500k"
env_ex_e_egress_vbufsize:
    .asciz "2500k"
env_ex_e_egress_abitrate:
    .asciz "160k"
env_ex_e_twitch_ingest:
    .asciz "ingest.global-contribute.live-video.net"
env_ex_e_twitch_key:
    .asciz ""
env_ex_e_bandwidth:
    .asciz "false"
env_ex_e_srt_pass:
    .asciz ""

// printEnvExample comments (envspec.go Comment fields)
env_ex_c_socket:
    .asciz "containerd gRPC socket the controller drives"
env_ex_c_http_port:
    .asciz "must match the Stream Deck plugin's base URL port"
env_ex_c_host_root:
    .asciz "host dir where deploy.sh stages config/bin/video-files"
env_ex_c_reconcile:
    .asciz "how often the reconcile ticker fires (Go duration)"
env_ex_c_inflight:
    .asciz "per-op timeout; after this an in-flight stage op is re-issued"
env_ex_c_shutdown:
    .asciz "graceful HTTP shutdown budget"
env_ex_c_stage_stop:
    .asciz "grace period after SIGTERM before a task is force-killed"
env_ex_c_ws_write:
    .asciz "per-message write deadline on /subscribe"
env_ex_c_actions_buf:
    .asciz "buffered capacity of the actions channel (0-255)"
env_ex_c_single_stage:
    .asciz "feature toggle to enable single_stage_egress"
env_ex_c_ffmpeg_img:
    .asciz "shared by the normalize and scale_and_egress stages"
env_ex_c_ffmpeg_nice:
    .asciz "nice(1) level for the ffmpeg stages"
env_ex_c_mtx_tmpl:
    .asciz "in-container path of the bind-mounted template (envsubst input)"
env_ex_c_srt_port:
    .asciz "SRT ingest port; must match the local encoder"
env_ex_c_rtsp_port:
    .asciz "internal RTSP port the stages read from"
env_ex_c_mpegts_sock:
    .asciz "unix socket: mediamtx listens, normalize ffmpeg connects"
env_ex_c_mtx_read_to:
    .asciz ">= SRT latency + jitter + read gap"
env_ex_c_scaled_height:
    .asciz "egress output height; width is derived (-2)"
env_ex_c_twitch_key:
    .asciz "secret; leave EMPTY in bundled builds - injected at deploy time by deploy.sh"
env_ex_c_bandwidth:
    .asciz "true appends ?bandwidthtest=true to the RTMP URL"
env_ex_c_srt_pass:
    .asciz "optional; falls back to /run/secrets/srt-passphrase if unset"

// ----------------------------------------------------------------------------
// printTSTypes output (main.go:61-97 printTSTypes).  The unions over the
// All* arrays (names.go:23-30) are compile-time constants, so the whole
// output is emitted as one static blob, byte-for-byte.
// ----------------------------------------------------------------------------
env_ts_types_blob:
    .ascii "// CODE GENERATED by `strimserver-controller -print-ts-types`. DO NOT EDIT.\n"
    .ascii "// Source of truth: core/controller/names.go + controller.go\n"
    .ascii "\n"
    .ascii "export type PathStatus = \"unknown\" | \"ready\" | \"not-ready\";\n"
    .ascii "export type StageState = \"running\" | \"stopped\" | \"\";\n"
    .ascii "export type PathName  = \"ingress0\" | \"normalized\";\n"
    .ascii "export type StageName = \"mediamtx\" | \"normalize\" | \"scale_and_egress\" | \"single_stage_egress\";\n"
    .ascii "\n"
    .ascii "export interface StageStatus { desired: StageState; actual: StageState; }\n"
    .ascii "export interface ControllerStatus {\n"
    .ascii "   paths: Record<PathName, PathStatus>;\n"
    .ascii "   stages: Record<StageName, StageStatus>;\n"
    .ascii "}\n"
    .ascii "\n"
    .ascii "export const Stages = { MediaMTX: \"mediamtx\", Normalize: \"normalize\", ScaleAndEgress: \"scale_and_egress\", SingleStageEgress: \"single_stage_egress\" } as const;\n"
    .ascii "export type ControlComponent = \"egress\";\n"
    .asciz "export type ControlAction    = \"start\" | \"stop\";\n"

// ============================================================================
// Typed parse helpers (module-local; preserve %rbx/%rbp/%r12-%r15; clobber
// only caller-saved registers and %xmm0-%xmm7; may be called only by this
// module).  Multi-value returns are %rax, %rdx, %rcx, %rsi.
// ============================================================================
    .text

// ----------------------------------------------------------------------------
// env_parse_bool(x0=s) -> x0 = 0/1, x1 = 0 ok / 1 error
//   strconv.ParseBool (internal/strconv/atob.go:10-18): exact match against
//   the twelve accepted strings; no trimming, no case folding.  Split from
//   the ~12-call AArch64 original: the six "true" and six "false" string
//   chains live in env_pb_true / env_pb_false so every function stays well
//   under 80 instructions.
// ----------------------------------------------------------------------------
    .p2align 4
env_parse_bool:
    PROLOGUE 1                      // %rbx = s across the two chain helpers
    mov %rdi, %rbx
    mov %rbx, %rdi
    call env_pb_true                // %rax = 1 matched a "true" string
    test %rax, %rax
    jnz .Lpb_true
    mov %rbx, %rdi
    call env_pb_false               // %rax = 1 matched a "false" string
    test %rax, %rax
    jnz .Lpb_false
    xor %eax, %eax
    mov $1, %edx                    // err = 1: no accepted string
    jmp .Lpb_ret
.Lpb_true:
    mov $1, %eax
    xor %edx, %edx
    jmp .Lpb_ret
.Lpb_false:
    xor %eax, %eax
    xor %edx, %edx
.Lpb_ret:
    EPILOGUE 1
    ret

// ----------------------------------------------------------------------------
// env_pb_true(x0=s) -> x0 = 1 when s equals one of the six "true" strings
//   (the first half of the ParseBool dispatch, split to stay <= 80 insns).
// ----------------------------------------------------------------------------
    .p2align 4
env_pb_true:
    PROLOGUE 1                      // %rbx = s across the cc_streq calls
    mov %rdi, %rbx
    mov %rbx, %rdi
    LEA rsi, env_bool_true_1
    call cc_streq
    test %rax, %rax
    jnz .Lpbt_match
    mov %rbx, %rdi
    LEA rsi, env_bool_true_t
    call cc_streq
    test %rax, %rax
    jnz .Lpbt_match
    mov %rbx, %rdi
    LEA rsi, env_bool_true_T
    call cc_streq
    test %rax, %rax
    jnz .Lpbt_match
    mov %rbx, %rdi
    LEA rsi, env_bool_true_true
    call cc_streq
    test %rax, %rax
    jnz .Lpbt_match
    mov %rbx, %rdi
    LEA rsi, env_bool_true_TRUE
    call cc_streq
    test %rax, %rax
    jnz .Lpbt_match
    mov %rbx, %rdi
    LEA rsi, env_bool_true_True
    call cc_streq
    test %rax, %rax
    jnz .Lpbt_match
    xor %eax, %eax
    jmp .Lpbt_ret
.Lpbt_match:
    mov $1, %eax
.Lpbt_ret:
    EPILOGUE 1
    ret

// ----------------------------------------------------------------------------
// env_pb_false(x0=s) -> x0 = 1 when s equals one of the six "false" strings
//   (the second half of the ParseBool dispatch, split to stay <= 80 insns).
// ----------------------------------------------------------------------------
    .p2align 4
env_pb_false:
    PROLOGUE 1                      // %rbx = s across the cc_streq calls
    mov %rdi, %rbx
    mov %rbx, %rdi
    LEA rsi, env_bool_false_0
    call cc_streq
    test %rax, %rax
    jnz .Lpbf_match
    mov %rbx, %rdi
    LEA rsi, env_bool_false_f
    call cc_streq
    test %rax, %rax
    jnz .Lpbf_match
    mov %rbx, %rdi
    LEA rsi, env_bool_false_F
    call cc_streq
    test %rax, %rax
    jnz .Lpbf_match
    mov %rbx, %rdi
    LEA rsi, env_bool_false_false
    call cc_streq
    test %rax, %rax
    jnz .Lpbf_match
    mov %rbx, %rdi
    LEA rsi, env_bool_false_FALSE
    call cc_streq
    test %rax, %rax
    jnz .Lpbf_match
    mov %rbx, %rdi
    LEA rsi, env_bool_false_False
    call cc_streq
    test %rax, %rax
    jnz .Lpbf_match
    xor %eax, %eax
    jmp .Lpbf_ret
.Lpbf_match:
    mov $1, %eax
.Lpbf_ret:
    EPILOGUE 1
    ret

// ----------------------------------------------------------------------------
// env_parse_u8(x0=s) -> x0 = value, x1 = 0 ok / 1 syntax error / 2 range error
//   strconv.ParseUint(s, 10, 8) (internal/strconv/atoi.go:47-144):
//     * empty string -> syntax error (atoi.go:50-52)
//     * no sign prefix (atoi.go:46) — '+' and '-' fall to the default
//       case -> syntax error (atoi.go:117-119)
//     * underscores are only legal when base==0 (atoi.go:110); base 10 here,
//       so '_' is a syntax error
//     * letters map to 10..35 and fail d >= base (atoi.go:115-123)
//     * n1 > maxVal(255) -> range error (atoi.go:131-135)
//   Observable behavior for u8: digits only, value 0..255, anything else is
//   an error.  Leaf; no callee-saved state.
// ----------------------------------------------------------------------------
    .p2align 4
env_parse_u8:
    movzbl (%rdi), %esi
    test %esi, %esi
    jz .Lpu8_err_syntax             // "" -> ErrSyntax (atoi.go:50)
    xor %edx, %edx                  // n = 0
.Lpu8_loop:
    movzbl (%rdi), %esi
    test %esi, %esi
    jz .Lpu8_done
    cmp $'0', %esi
    jl .Lpu8_err_syntax
    cmp $'9', %esi
    jg .Lpu8_err_syntax
    sub $'0', %esi
    imul $10, %rdx, %rdx            // n *= 10
    add %rsi, %rdx                  // n += digit
    cmp $255, %rdx
    ja .Lpu8_err_range              // n1 > maxVal (atoi.go:132)
    inc %rdi
    jmp .Lpu8_loop
.Lpu8_done:
    mov %rdx, %rax                  // x0 = value
    xor %edx, %edx                  // x1 = ok
    ret
.Lpu8_err_syntax:
    xor %eax, %eax
    mov $1, %edx
    ret
.Lpu8_err_range:
    xor %eax, %eax
    mov $2, %edx
    ret

// ----------------------------------------------------------------------------
// env_dur_leading_int(x0=s) -> x0 = v, x1 = s', x2 = pre(0/1), x3 = err(0/1)
//   Port of time.leadingInt (time/format.go:1554-1572).  Overflow (x >
//   1<<63/10 before, or x > 1<<63 after the multiply-add) is an error,
//   exactly as Go propagates errLeadingInt -> "time: invalid duration".
//   Leaf; uses only caller-saved registers.  The caller (env_dur_component)
//   keeps its live state in %r9/%r10 (and callee-saved), so this helper
//   touches none of them.
// ----------------------------------------------------------------------------
    .p2align 4
env_dur_leading_int:
    movabs $CC_DUR_1SHL63, %r8      // 1<<63
    mov %r8, %rax
    xor %edx, %edx
    mov $10, %ecx
    div %rcx                        // %rax = 1<<63/10
    xor %ecx, %ecx                  // pre = 0
    xor %edx, %edx                  // v = 0
.Lpdli_loop:
    movzbl (%rdi), %r11d
    cmp $'0', %r11d
    jl .Lpdli_done
    cmp $'9', %r11d
    jg .Lpdli_done
    cmp %rax, %rdx                  // v > 1<<63/10 ?
    ja .Lpdli_ovf
    sub $'0', %r11d
    imul $10, %rdx, %rdx            // v *= 10
    add %r11, %rdx                  // v += digit
    cmp %r8, %rdx                   // v > 1<<63 ?
    ja .Lpdli_ovf
    mov $1, %ecx                    // pre = 1
    inc %rdi
    jmp .Lpdli_loop
.Lpdli_done:
    mov %rdx, %rax                  // x0 = v
    mov %rdi, %rdx                  // x1 = s'
    // x2 = pre already in %rcx
    xor %esi, %esi                  // x3 = no error
    ret
.Lpdli_ovf:
    xor %eax, %eax
    xor %edx, %edx
    xor %ecx, %ecx
    mov $1, %esi                    // x3 = err
    ret

// ----------------------------------------------------------------------------
// env_dur_leading_frac(x0=s, x1=1<<63) -> x0 = f, x1 = scale, x2 = s',
//   x3 = post(0/1)
//   Port of time.leadingFraction (time/format.go:1577-1603).  Unlike the
//   integer part, overflow does NOT error: it stops accumulating x and scale
//   (the `overflow` flag) while still consuming the remaining digits.
//   scale stays an integer 10^k, which equals Go's float64 accumulation for
//   every k the digit loop can reach (10^k is exactly representable as a
//   double for k <= 22, and the digit count is bounded by the overflow flag
//   far below that).  The caller keeps live state in %r9/%r10/%r11/%rbx, so
//   this helper moves its working set into the callee-saved %rbx/%r12/%r13
//   it preserves (PROLOGUE 3).
// ----------------------------------------------------------------------------
    .p2align 4
env_dur_leading_frac:
    PROLOGUE 3                      // %rbx = 1<<63, %r12 = threshold, %r13 = s
    mov %rsi, %rbx                  // 1<<63
    mov %rbx, %rax
    xor %edx, %edx
    mov $10, %ecx
    div %rcx                        // %rax = (1<<63-1)/10 == floor(1<<63/10)
    mov %rax, %r12                  // threshold
    xor %eax, %eax                  // f = 0
    mov $1, %edx                    // scale = 1
    xor %ecx, %ecx                  // overflow flag
    xor %r8d, %r8d                  // post = 0
    mov %rdi, %r13                  // s (advances)
.Lpd_f_loop:
    movzbl (%r13), %esi
    cmp $'0', %esi
    jl .Lpd_f_done
    cmp $'9', %esi
    jg .Lpd_f_done
    mov $1, %r8d                    // a digit was consumed
    test %rcx, %rcx
    jnz .Lpd_f_skip
    cmp %r12, %rax                  // f > (1<<63-1)/10 ?
    ja .Lpd_f_ovf
    sub $'0', %esi
    imul $10, %rax, %rax            // f *= 10
    add %rsi, %rax                  // f += digit
    cmp %rbx, %rax                  // f > 1<<63 ?
    ja .Lpd_f_ovf
    imul $10, %rdx, %rdx            // scale *= 10
    jmp .Lpd_f_skip
.Lpd_f_ovf:
    mov $1, %ecx
.Lpd_f_skip:
    inc %r13
    jmp .Lpd_f_loop
.Lpd_f_done:
    mov %r13, %rcx                  // x2 = s'
    mov %r8, %rsi                   // x3 = post
    EPILOGUE 3
    ret

// ----------------------------------------------------------------------------
// env_dur_unit(x0=unit ptr, x1=len) -> x0 = unit value in ns, or 0 unknown
//   time/format.go:1615-1624 unitMap.  The unit scan (ParseDuration's
//   `for ; i < len(s); i++` at format.go:1686-1692) already stopped at '.'
//   or a digit, so the unit here is exactly one of the eight map keys; the
//   length disambiguates (e.g. "m" minute vs "ms" millisecond).
//   Leaf; uses only caller-saved registers (the caller keeps its whole live
//   state in %rbx/%r8-%r15 across this call).
// ----------------------------------------------------------------------------
    .p2align 4
env_dur_unit:
    movzbl (%rdi), %ecx             // b0
    cmp $1, %rsi
    je .Lpdu_len1
    cmp $2, %rsi
    je .Lpdu_len2
    cmp $3, %rsi
    je .Lpdu_len3
    jmp .Lpdu_unknown
.Lpdu_len1:
    cmp $'s', %ecx
    je .Lpdu_s
    cmp $'m', %ecx
    je .Lpdu_m
    cmp $'h', %ecx
    je .Lpdu_h
    jmp .Lpdu_unknown
.Lpdu_len2:
    movzbl 1(%rdi), %edx            // b1
    cmp $'n', %ecx
    jne .Lpdu_2_not_n
    cmp $'s', %edx
    je .Lpdu_ns
    jmp .Lpdu_unknown
.Lpdu_2_not_n:
    cmp $'u', %ecx
    jne .Lpdu_2_not_u
    cmp $'s', %edx
    je .Lpdu_us
    jmp .Lpdu_unknown
.Lpdu_2_not_u:
    cmp $'m', %ecx
    jne .Lpdu_unknown
    cmp $'s', %edx
    je .Lpdu_ms
    jmp .Lpdu_unknown
.Lpdu_len3:
    movzbl 1(%rdi), %edx            // b1
    movzbl 2(%rdi), %esi            // b2 (len is dead once the dispatch is here)
    cmp $'s', %esi
    jne .Lpdu_unknown
    cmp $0xC2, %ecx                 // U+00B5 micro sign (C2 B5)
    jne .Lpdu_3_not_b5
    cmp $0xB5, %edx
    je .Lpdu_us
    jmp .Lpdu_unknown
.Lpdu_3_not_b5:
    cmp $0xCE, %ecx                 // U+03BC Greek small letter mu (CE BC)
    jne .Lpdu_unknown
    cmp $0xBC, %edx
    je .Lpdu_us
    jmp .Lpdu_unknown
.Lpdu_ns:
    mov $1, %eax
    ret
.Lpdu_us:
    mov $1000, %eax
    ret
.Lpdu_ms:
    mov $1000000, %eax
    ret
.Lpdu_s:
    MOV_NANOSEC rax                 // 1000000000 (s)
    ret
.Lpdu_m:
    MOV_DUR_MIN rax                 // 60000000000 (m) — platform-header macro
    ret
.Lpdu_h:
    MOV_DUR_HOUR rax                // 3600000000000 (h) — platform-header macro
    ret
.Lpdu_unknown:
    xor %eax, %eax
    ret

// ----------------------------------------------------------------------------
// env_dur_unit_scan(x0=s) -> x0 = s (unchanged), x1 = len
//   The ParseDuration unit-scan loop (format.go:1686-1692): consume every
//   byte that is NOT '.' and NOT a digit; the resulting length is the unit
//   length.  Split out of env_dur_component (with env_dur_frac_add) to keep
//   the accumulator under 80 instructions.  Leaf; the caller's whole live
//   state (%rbx/%r8-%r15) is untouched.
// ----------------------------------------------------------------------------
    .p2align 4
env_dur_unit_scan:
    xor %edx, %edx                  // len = 0
.Lpdus_loop:
    movzbl (%rdi,%rdx), %ecx        // s[len]
    test %ecx, %ecx
    jz .Lpdus_done
    cmp $'.', %ecx
    je .Lpdus_done
    cmp $'0', %ecx
    jl .Lpdus_inc
    cmp $'9', %ecx
    jle .Lpdus_done
.Lpdus_inc:
    inc %rdx
    jmp .Lpdus_loop
.Lpdus_done:
    mov %rdi, %rax                  // x0 = s (unchanged)
    ret

// ----------------------------------------------------------------------------
// env_dur_frac_add(x0=f, x1=unit, x2=scale) -> x0 = uint64 frac
//   The single float-arithmetic site in the port (cc_env.S:966-971 AArch64):
//   ucvtf/fdiv/fmul/fcvtzu become cvtsi2sd (64-bit form; every source is
//   < 2^63, so the signed conversion equals the AArch64 unsigned ucvtf
//   bit-for-bit), divsd, mulsd, cvttsd2si (truncate toward zero, matching
//   fcvtzu).  Split out of env_dur_component so the exact float sequence is
//   one self-contained helper.  Leaf; %xmm0-%xmm2 are caller-saved per SysV
//   (the clobber checker tracks only the callee-saved %xmm8-%xmm15, never
//   xmm0-7), so neither the ABI nor the checker requires preserving them;
//   they are still parked in this leaf's red zone (legal: no calls here) and
//   restored before the return so the helper is inert against the caller's
//   entire xmm state, not just the callee-saved set.
// ----------------------------------------------------------------------------
    .p2align 4
env_dur_frac_add:
    movsd %xmm0, -24(%rsp)          // park caller-saved %xmm0-2 (red zone)
    movsd %xmm1, -16(%rsp)
    movsd %xmm2, -8(%rsp)
    cvtsi2sdq %rdi, %xmm0           // float64(f)
    cvtsi2sdq %rsi, %xmm1           // float64(unit)
    cvtsi2sdq %rdx, %xmm2           // float64(scale)
    divsd %xmm2, %xmm1              // float64(unit) / scale
    mulsd %xmm1, %xmm0              // float64(f) * that
    cvttsd2siq %xmm0, %rax          // uint64(...), truncate toward zero
    movsd -24(%rsp), %xmm0
    movsd -16(%rsp), %xmm1
    movsd -8(%rsp), %xmm2
    ret

// ----------------------------------------------------------------------------
// env_dur_component(x0=s, x1=d, x2=1<<63) -> x0 = s', x1 = d', x2 = err
//   Parses ONE "number (fraction)? unit" component of a duration string and
//   accumulates it into d — the body of Go's ParseDuration loop
//   (time/format.go:1652-1720).  Error codes: 1 invalid duration, 2 missing
//   unit, 3 unknown unit.  Live state (%r8-%r11 + callee-saved) is kept in
//   registers the sub-helpers promise not to touch, exactly the AArch64
//   x8-x17 design; the overflow-accumulation checks and the 1<<63/unit
//   division (udiv -> div %r11) map 1:1.
// ----------------------------------------------------------------------------
    .p2align 4
env_dur_component:
    PROLOGUE 5                      // %rbx = v, %r12 = scale, %r13 = post,
                                    // %r14 = f, %r15 = unit length
    mov %rdi, %r8                   // s (advances)
    mov %rsi, %r9                   // d (accumulator)
    mov %rdx, %r10                  // 1<<63
    mov %r8, %rdi
    call env_dur_leading_int        // %rax=v, %rdx=s', %rcx=pre, %rsi=err
    test %rsi, %rsi
    jnz .Lpdc_err_invalid
    mov %rcx, %r11                  // pre
    mov %rax, %rbx                  // v
    mov %rdx, %r8                   // s
    movzbl (%r8), %ecx
    cmp $'.', %ecx
    jne .Lpdc_no_frac
    inc %r8
    mov %r8, %rdi                   // arg: s
    mov %r10, %rsi                  // arg: 1<<63
    call env_dur_leading_frac       // %rax=f, %rdx=scale, %rcx=s', %rsi=post
    mov %rax, %r14                  // f
    mov %rdx, %r12                  // scale
    mov %rsi, %r13                  // post
    mov %rcx, %r8                   // s
    jmp .Lpdc_have_digits
.Lpdc_no_frac:
    xor %r14d, %r14d                // f = 0
    mov $1, %r12d                   // scale = 1 (unused: f == 0)
    xor %r13d, %r13d                // post = false
.Lpdc_have_digits:
    test %r11, %r11                 // pre || post, else no digits (".s")
    jnz .Lpdc_unit_scan
    test %r13, %r13
    jnz .Lpdc_unit_scan
    jmp .Lpdc_err_invalid
.Lpdc_unit_scan:
    mov %r8, %rdi                   // arg: s
    call env_dur_unit_scan          // %rax=s (unchanged), %rdx=len
    test %rdx, %rdx
    jz .Lpdc_err_missing_unit
    mov %rdx, %r15                  // unit length
    mov %r8, %rdi                   // arg: unit ptr
    mov %r15, %rsi                  // arg: len
    call env_dur_unit               // %rax = unit value or 0
    test %rax, %rax
    jz .Lpdc_err_unknown_unit
    mov %rax, %r11                  // unit value (pre is dead here)
    mov %r10, %rax                  // 1<<63
    xor %edx, %edx
    div %r11                        // %rax = 1<<63/unit (udiv)
    cmp %rax, %rbx                  // v > 1<<63/unit ?
    ja .Lpdc_err_invalid
    imul %r11, %rbx                 // v *= unit
    test %r14, %r14                 // f == 0 ?
    jz .Lpdc_no_frac_add
    mov %r14, %rdi                  // arg: f
    mov %r11, %rsi                  // arg: unit
    mov %r12, %rdx                  // arg: scale
    call env_dur_frac_add           // %rax = uint64(f * unit/scale)
    add %rax, %rbx                  // v += frac
    cmp %r10, %rbx                  // v > 1<<63 ?
    ja .Lpdc_err_invalid
.Lpdc_no_frac_add:
    add %rbx, %r9                   // d += v
    cmp %r10, %r9                   // d > 1<<63 ?
    ja .Lpdc_err_invalid
    add %r15, %r8                   // s += unit length
    mov %r8, %rax                   // x0 = s'
    mov %r9, %rdx                   // x1 = d'
    xor %ecx, %ecx                  // x2 = err 0
    jmp .Lpdc_epilogue
.Lpdc_err_invalid:
    xor %eax, %eax
    xor %edx, %edx
    mov $1, %ecx
    jmp .Lpdc_epilogue
.Lpdc_err_missing_unit:
    xor %eax, %eax
    xor %edx, %edx
    mov $2, %ecx
    jmp .Lpdc_epilogue
.Lpdc_err_unknown_unit:
    xor %eax, %eax
    xor %edx, %edx
    mov $3, %ecx
.Lpdc_epilogue:
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// env_pd_finish(x0=d, x1=neg, x2=1<<63) -> x0 = u64 ns, x1 = 0 ok / 1 invalid
//   The result assembly of ParseDuration (format.go:1721-1726): a negative
//   result is the two's-complement of d (-Duration(d)); a positive result
//   must satisfy d <= 1<<63-1.  Split out of env_parse_duration to keep it
//   under 80 instructions.
// ----------------------------------------------------------------------------
    .p2align 4
env_pd_finish:
    test %rsi, %rsi
    jz .Lpdf_pos
    mov %rdi, %rax
    neg %rax                        // -Duration(d) (two's complement)
    xor %edx, %edx
    ret
.Lpdf_pos:
    lea -1(%rdx), %rcx              // 1<<63 - 1
    cmp %rcx, %rdi
    ja .Lpdf_invalid
    mov %rdi, %rax
    xor %edx, %edx
    ret
.Lpdf_invalid:
    xor %eax, %eax
    mov $1, %edx
    ret

// ----------------------------------------------------------------------------
// env_parse_duration(x0=s) -> x0 = u64 ns, x1 = 0 ok / 1 invalid / 2 missing
//   unit / 3 unknown unit
//   Port of time.ParseDuration (time/format.go:1631-1728):
//     * optional sign; "-0"/"+0" are the "0" special case (format.go:1645-1648)
//     * empty after the sign -> error (format.go:1649-1651)
//     * per component: leadingInt (overflow = error), optional fraction
//       (overflow = stop accumulating), unit (unknown = error), then
//       v > 1<<63/unit, v += uint64(float64(f)*(float64(unit)/scale)),
//       d += v, each with the > 1<<63 overflow checks (format.go:1702-1719)
//     * negative result is the two's-complement of d (Go returns
//       -Duration(d), format.go:1721-1723) — handled by env_pd_finish
//     * positive d > 1<<63-1 -> error (format.go:1724-1726)
// ----------------------------------------------------------------------------
    .p2align 4
env_parse_duration:
    PROLOGUE 4                      // %rbx = neg, %r12 = 1<<63, %r13 = d,
                                    // %r14 = s
    xor %ebx, %ebx                  // neg = 0
    movzbl (%rdi), %esi
    cmp $'-', %esi
    jne .Lpd_plus
    mov $1, %ebx
    inc %rdi
    jmp .Lpd_signed
.Lpd_plus:
    cmp $'+', %esi
    jne .Lpd_signed
    inc %rdi
.Lpd_signed:
    mov %rdi, %r14                  // s
    movzbl (%rdi), %esi
    cmp $'0', %esi
    jne .Lpd_not_zero
    movzbl 1(%rdi), %edx
    test %edx, %edx
    jz .Lpd_zero                    // s == "0"
.Lpd_not_zero:
    test %esi, %esi
    jz .Lpd_err_invalid             // s == "" after the sign
    movabs $CC_DUR_1SHL63, %r12     // 1<<63
    xor %r13d, %r13d                // d = 0
.Lpd_loop:
    movzbl (%r14), %esi
    test %esi, %esi
    jz .Lpd_loop_done
    mov %r14, %rdi                  // arg: s
    mov %r13, %rsi                  // arg: d
    mov %r12, %rdx                  // arg: 1<<63
    call env_dur_component          // %rax=s', %rdx=d', %rcx=err
    test %rcx, %rcx
    jnz .Lpd_comp_err
    mov %rax, %r14
    mov %rdx, %r13
    jmp .Lpd_loop
.Lpd_loop_done:
    mov %r13, %rdi                  // arg: d
    mov %rbx, %rsi                  // arg: neg
    mov %r12, %rdx                  // arg: 1<<63
    call env_pd_finish              // %rax = ns, %rdx = err
    jmp .Lpd_ret
.Lpd_zero:
    xor %eax, %eax
    xor %edx, %edx
    jmp .Lpd_ret
.Lpd_comp_err:
    xor %eax, %eax
    mov %rcx, %rdx                  // err from the component
    jmp .Lpd_ret
.Lpd_err_invalid:
    xor %eax, %eax
    mov $1, %edx
.Lpd_ret:
    EPILOGUE 4
    ret

// ============================================================================
// Fail-loud helpers (module-local, noreturn; cc_fail never returns).
// ============================================================================

// ----------------------------------------------------------------------------
// env_fail_invalid(x0=name, x1=msg) -> cc_fail("invalid value for NAME: msg")
// ----------------------------------------------------------------------------
    .p2align 4
env_fail_invalid:
    PROLOGUE 2                      // %rbx = name, %r12 = msg (across cc_cat_cstr)
    mov %rdi, %rbx
    mov %rsi, %r12
    sub $256, %rsp                  // message scratch (16-aligned)
    mov %rsp, %rdi
    LEA rsi, env_msg_invalid_value_for
    call cc_cat_cstr                // %rax = NUL position
    mov %rax, %rdi                  // re-thread the cursor (SysV: ret != arg0)
    mov %rbx, %rsi
    call cc_cat_cstr
    mov %rax, %rdi                  // re-thread the cursor
    LEA rsi, env_msg_sep
    call cc_cat_cstr
    mov %rax, %rdi                  // re-thread the cursor
    mov %r12, %rsi
    call cc_cat_cstr
    mov %rsp, %rdi
    call cc_fail                    // noreturn

// ----------------------------------------------------------------------------
// env_fail_missing(x0=name) -> cc_fail("missing required env var NAME")
// ----------------------------------------------------------------------------
    .p2align 4
env_fail_missing:
    PROLOGUE 1                      // %rbx = name (across cc_cat_cstr)
    mov %rdi, %rbx
    sub $256, %rsp                  // message scratch (16-aligned)
    mov %rsp, %rdi
    LEA rsi, env_msg_missing_required
    call cc_cat_cstr
    mov %rax, %rdi                  // re-thread the cursor (SysV: ret != arg0)
    mov %rbx, %rsi
    call cc_cat_cstr
    mov %rsp, %rdi
    call cc_fail                    // noreturn

// ============================================================================
// Store helpers (module-local; preserve %rbx/%rbp/%r12-%r15).
// ============================================================================

// ----------------------------------------------------------------------------
// env_store_string(x0=erbase, x1=raw, x2=entry)
//   Stores the raw pointer at the entry's target; the store op extends it to
//   the multi-field binds (envspec.go:170-197).  Leaf.
// ----------------------------------------------------------------------------
    .p2align 4
env_store_string:
    mov 12(%rdx), %ecx              // target offset
    lea (%rdi,%rcx), %rcx           // target = erbase + offset
    mov %rsi, (%rcx)                // store the raw pointer
    movzbl 10(%rdx), %ecx           // store op
    cmp $CC_ENVSTORE_SNAP_BOTH, %ecx
    je .Les_snap
    cmp $CC_ENVSTORE_LOG_BOTH, %ecx
    je .Les_log
    cmp $CC_ENVSTORE_IMAGE_THREE, %ecx
    je .Les_image
    ret
.Les_snap:
    lea CC_ER_SINGLE_STAGE_EGRESS + CC_CC_SNAPSHOT_ID(%rdi), %rcx
    mov %rsi, (%rcx)
    ret
.Les_log:
    lea CC_ER_SINGLE_STAGE_EGRESS + CC_CC_LOGFILE(%rdi), %rcx
    mov %rsi, (%rcx)
    ret
.Les_image:
    lea CC_ER_SCALE_AND_EGRESS + CC_CC_IMAGE_NAME(%rdi), %rcx
    mov %rsi, (%rcx)
    lea CC_ER_SINGLE_STAGE_EGRESS + CC_CC_IMAGE_NAME(%rdi), %rcx
    mov %rsi, (%rcx)
    ret

// ----------------------------------------------------------------------------
// env_store_duration(x0=erbase, x1=raw, x2=entry)
// ----------------------------------------------------------------------------
    .p2align 4
env_store_duration:
    PROLOGUE 2                      // %rbx = erbase, %r12 = entry
    mov %rdi, %rbx
    mov %rdx, %r12
    mov %rsi, %rdi                  // arg: raw
    call env_parse_duration         // %rax = ns, %rdx = err
    test %rdx, %rdx
    jz .Lesd_ok
    // The fail path is placed BEFORE the success-path EPILOGUE so the
    // noreturn env_fail_invalid call keeps the frame delta the checker sees
    // (a call after the EPILOGUE would be judged against the wrong rsp).
    mov (%r12), %rdi                // name
    cmp $2, %rdx
    je .Lesd_missing
    cmp $3, %rdx
    je .Lesd_unknown
    LEA rsi, env_msg_invalid_duration
    jmp .Lesd_fail
.Lesd_missing:
    LEA rsi, env_msg_missing_unit
    jmp .Lesd_fail
.Lesd_unknown:
    LEA rsi, env_msg_unknown_unit
.Lesd_fail:
    call env_fail_invalid           // noreturn
.Lesd_ok:
    mov 12(%r12), %ecx
    lea (%rbx,%rcx), %rcx
    mov %rax, (%rcx)                // store u64 ns
    EPILOGUE 2
    ret

// ----------------------------------------------------------------------------
// env_store_u8(x0=erbase, x1=raw, x2=entry)
// ----------------------------------------------------------------------------
    .p2align 4
env_store_u8:
    PROLOGUE 2                      // %rbx = erbase, %r12 = entry
    mov %rdi, %rbx
    mov %rdx, %r12
    mov %rsi, %rdi                  // arg: raw
    call env_parse_u8               // %rax = value, %rdx = err
    test %rdx, %rdx
    jz .Lesu_ok
    // Fail path first (see env_store_duration for the ordering reason).
    mov (%r12), %rdi                // name
    cmp $2, %rdx
    je .Lesu_range
    LEA rsi, env_msg_invalid_u8
    jmp .Lesu_fail
.Lesu_range:
    LEA rsi, env_msg_u8_range
.Lesu_fail:
    call env_fail_invalid           // noreturn
.Lesu_ok:
    mov 12(%r12), %ecx
    lea (%rbx,%rcx), %rcx
    mov %al, (%rcx)                 // store u8 byte
    EPILOGUE 2
    ret

// ----------------------------------------------------------------------------
// env_store_bool(x0=erbase, x1=raw, x2=entry)
// ----------------------------------------------------------------------------
    .p2align 4
env_store_bool:
    PROLOGUE 2                      // %rbx = erbase, %r12 = entry
    mov %rdi, %rbx
    mov %rdx, %r12
    mov %rsi, %rdi                  // arg: raw
    call env_parse_bool             // %rax = 0/1, %rdx = err
    test %rdx, %rdx
    jz .Lesb_ok
    // Fail path first (see env_store_duration for the ordering reason).
    mov (%r12), %rdi                // name
    LEA rsi, env_msg_invalid_bool
    call env_fail_invalid           // noreturn
.Lesb_ok:
    mov 12(%r12), %ecx
    lea (%rbx,%rcx), %rcx
    mov %al, (%rcx)                 // store bool byte
    EPILOGUE 2
    ret

// ============================================================================
// cc_env_load — parse every env var in the table into the caller's
// env-runtime block.
//   in:  rdi = layout ptr (base of the caller's combined struct; the Layout's
//        CC_LAY_* offsets are kept as-is at +0, the env-runtime block the
//        module writes sits at +CC_LAY_SIZE).
//   out: none; fail-loud (exit 1) on a missing required var or an invalid
//        value.
//   Port of main.go LoadConfig (main.go:99-115) over envSpec().
// ----------------------------------------------------------------------------
    .p2align 4
    .global cc_env_load
    FUNC_TYPE(cc_env_load)
cc_env_load:
    PROLOGUE 4                      // %rbx = raw, %r12 = erbase, %r13 = entry,
                                    // %r14 = end of table
    mov %rdi, %r12
    add $CC_LAY_SIZE, %r12          // erbase = layout + CC_LAY_SIZE
    // Zero the env-runtime block first: LoadConfig starts from a zero Config
    // (main.go:100 `var cfg Config`), so absent/empty vars keep the Go zero
    // value (0 / false / null).
    mov %r12, %rdi
    lea CC_ER_SIZE(%r12), %rsi
.Lel_zero:
    movq $0, (%rdi)
    movq $0, 8(%rdi)
    add $16, %rdi
    cmp %rsi, %rdi
    jb .Lel_zero
    LEA r13, env_spec               // entry = env_spec
    LEA_OFF r14, env_spec, CC_ENV_COUNT*16   // end = env_spec + count*16
.Lel_loop:
    cmp %r14, %r13
    jae .Lel_done
    mov (%r13), %rdi                // name
    call getenv
    test %rax, %rax
    jz .Lel_absent
    movzbl (%rax), %ecx
    test %ecx, %ecx
    jz .Lel_absent                  // empty == absent (main.go:104)
    mov %rax, %rbx                  // raw (preserve across the dispatch)
    movzbl 8(%r13), %ecx            // bind kind
    cmp $CC_ENVKIND_STRING, %ecx
    je .Lel_string
    cmp $CC_ENVKIND_DURATION, %ecx
    je .Lel_duration
    cmp $CC_ENVKIND_U8, %ecx
    je .Lel_u8
    mov %r12, %rdi                  // env_store_bool(erbase, raw, entry)
    mov %rbx, %rsi
    mov %r13, %rdx
    call env_store_bool
    jmp .Lel_next
.Lel_string:
    mov %r12, %rdi
    mov %rbx, %rsi
    mov %r13, %rdx
    call env_store_string
    jmp .Lel_next
.Lel_duration:
    mov %r12, %rdi
    mov %rbx, %rsi
    mov %r13, %rdx
    call env_store_duration
    jmp .Lel_next
.Lel_u8:
    mov %r12, %rdi
    mov %rbx, %rsi
    mov %r13, %rdx
    call env_store_u8
    jmp .Lel_next
.Lel_absent:
    movzbl 9(%r13), %ecx            // required
    test %ecx, %ecx
    jz .Lel_next
    mov (%r13), %rdi                // name
    call env_fail_missing           // noreturn
.Lel_next:
    add $16, %r13
    jmp .Lel_loop
.Lel_done:
    EPILOGUE 4
    ret

// ============================================================================
// Typed accessors for the other modules.  Each takes an env NAME (like the
// existing cc_env_int in cc_util.S), mirrors the Go LoadConfig behavior:
// absent OR empty -> the Go default (0 / false / null), present -> the Go
// parse function; invalid -> fail-loud (exit 1).
// ============================================================================

// ----------------------------------------------------------------------------
// cc_env_u8(rdi=name) -> rax = u8 value (0 on absent)
// ----------------------------------------------------------------------------
    .p2align 4
    .global cc_env_u8
    FUNC_TYPE(cc_env_u8)
cc_env_u8:
    PROLOGUE 1                      // %rbx = name
    mov %rdi, %rbx
    call getenv
    test %rax, %rax
    jz .Lu8_none
    movzbl (%rax), %ecx
    test %ecx, %ecx
    jz .Lu8_none
    mov %rax, %rdi                  // arg: raw
    call env_parse_u8               // %rax = value, %rdx = err
    test %rdx, %rdx
    jnz .Lu8_bad
    jmp .Lu8_ret
.Lu8_none:
    xor %eax, %eax
    jmp .Lu8_ret
.Lu8_bad:
    mov %rbx, %rdi                  // name
    cmp $2, %rdx
    je .Lu8_range
    LEA rsi, env_msg_invalid_u8
    jmp .Lu8_fail
.Lu8_range:
    LEA rsi, env_msg_u8_range
.Lu8_fail:
    call env_fail_invalid           // noreturn
.Lu8_ret:
    EPILOGUE 1
    ret

// ----------------------------------------------------------------------------
// cc_env_dur(rdi=name) -> rax = u64 ns (0 on absent)
// ----------------------------------------------------------------------------
    .p2align 4
    .global cc_env_dur
    FUNC_TYPE(cc_env_dur)
cc_env_dur:
    PROLOGUE 1                      // %rbx = name
    mov %rdi, %rbx
    call getenv
    test %rax, %rax
    jz .Ldur_none
    movzbl (%rax), %ecx
    test %ecx, %ecx
    jz .Ldur_none
    mov %rax, %rdi                  // arg: raw
    call env_parse_duration         // %rax = ns, %rdx = err
    test %rdx, %rdx
    jnz .Ldur_bad
    jmp .Ldur_ret
.Ldur_none:
    xor %eax, %eax
    jmp .Ldur_ret
.Ldur_bad:
    mov %rbx, %rdi                  // name
    cmp $2, %rdx
    je .Ldur_missing
    cmp $3, %rdx
    je .Ldur_unknown
    LEA rsi, env_msg_invalid_duration
    jmp .Ldur_fail
.Ldur_missing:
    LEA rsi, env_msg_missing_unit
    jmp .Ldur_fail
.Ldur_unknown:
    LEA rsi, env_msg_unknown_unit
.Ldur_fail:
    call env_fail_invalid           // noreturn
.Ldur_ret:
    EPILOGUE 1
    ret

// ----------------------------------------------------------------------------
// cc_env_bool(rdi=name) -> rax = 0/1 (0 on absent)
// ----------------------------------------------------------------------------
    .p2align 4
    .global cc_env_bool
    FUNC_TYPE(cc_env_bool)
cc_env_bool:
    PROLOGUE 1                      // %rbx = name
    mov %rdi, %rbx
    call getenv
    test %rax, %rax
    jz .Lbool_none
    movzbl (%rax), %ecx
    test %ecx, %ecx
    jz .Lbool_none
    mov %rax, %rdi                  // arg: raw
    call env_parse_bool             // %rax = 0/1, %rdx = err
    test %rdx, %rdx
    jnz .Lbool_bad
    jmp .Lbool_ret
.Lbool_none:
    xor %eax, %eax
    jmp .Lbool_ret
.Lbool_bad:
    mov %rbx, %rdi                  // name
    LEA rsi, env_msg_invalid_bool
    call env_fail_invalid           // noreturn
.Lbool_ret:
    EPILOGUE 1
    ret

// ----------------------------------------------------------------------------
// cc_env_str(rdi=name) -> rax = ptr to the raw value, or null (absent/empty)
// ----------------------------------------------------------------------------
    .p2align 4
    .global cc_env_str
    FUNC_TYPE(cc_env_str)
cc_env_str:
    PROLOGUE 0                      // alignment-only frame for the getenv call
    call getenv
    test %rax, %rax
    jz .Lstr_none
    movzbl (%rax), %ecx
    test %ecx, %ecx
    jnz .Lstr_have
.Lstr_none:
    xor %eax, %eax
.Lstr_have:
    EPILOGUE 0
    ret

// ============================================================================
// Codegen emitters.
// ============================================================================

// ----------------------------------------------------------------------------
// cc_env_print_example — print the -print-env-example output.
//   Port of main.go printEnvExample (main.go:52-59) over the full 46-entry
//   envSpec(): group headers on change (with the leading newline), comments,
//   NAME=%q lines.
// ----------------------------------------------------------------------------
    .p2align 4
    .global cc_env_print_example
    FUNC_TYPE(cc_env_print_example)
cc_env_print_example:
    PROLOGUE 5                      // rbx=last group r12=entry r13=end r14=comment
                                    // r15=group (callee-saved: survives the cc_puts
                                    // calls between the lookup and the ebx update)
    mov $-1, %ebx                   // last group = -1
    LEA r12, env_example_table      // entry
    LEA_OFF r13, env_example_table, CC_ENV_EXAMPLE_COUNT*32   // end
.Lpe_loop:
    cmp %r13, %r12
    jae .Lpe_done
    movzbl (%r12), %r15d            // group
    cmp %ebx, %r15d
    je .Lpe_same_group
    LEA rdi, env_group_header_prefix
    call cc_puts
    LEA rdi, env_group_names
    mov (%rdi,%r15,8), %rdi         // env_group_names[group]
    call cc_puts
    LEA rdi, env_group_header_suffix
    call cc_puts
    mov %r15d, %ebx                 // last group = group
.Lpe_same_group:
    mov 8(%r12), %rax               // comment
    test %rax, %rax
    jz .Lpe_no_comment
    mov %rax, %r14
    LEA rdi, env_comment_prefix
    call cc_puts
    mov %r14, %rdi
    call cc_puts
    LEA rdi, env_newline
    call cc_puts
.Lpe_no_comment:
    mov 16(%r12), %rdi              // name
    call cc_puts
    LEA rdi, env_eq_quote
    call cc_puts
    mov 24(%r12), %rdi              // example
    call cc_puts
    LEA rdi, env_quote_newline
    call cc_puts
    add $32, %r12
    jmp .Lpe_loop
.Lpe_done:
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// cc_env_print_ts_types — print the -print-ts-types output (one static blob;
// the unions over the All* arrays are compile-time constants).
//   Port of main.go printTSTypes (main.go:61-97).
// ----------------------------------------------------------------------------
    .p2align 4
    .global cc_env_print_ts_types
    FUNC_TYPE(cc_env_print_ts_types)
cc_env_print_ts_types:
    PROLOGUE 0                      // alignment-only frame for the cc_puts call
    LEA rdi, env_ts_types_blob
    call cc_puts
    EPILOGUE 0
    ret

    .end