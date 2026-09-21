// ============================================================================
// cc_env.S — env-config parsing for the strimserver controller
// ============================================================================
//
//  Target:     AArch64 (ARMv8.2-A), little-endian — Linux (ELF, static);
//              cc_platform.h is the only platform header (Linux-only).
//  Assembler:  GNU as syntax, preprocessed by the C compiler
//              (`cc -c -x assembler-with-cpp`).
//  ISA:        .arch armv8.2-a — exactly one in-source directive (below),
//              nothing higher, no .arch_extension, no .cpu (Graviton2 parity).
//
//  This module is the L1 env layer: it ports the Go controller's env
//  consumption (core/controller/envspec.go + main.go LoadConfig) to
//  assembly.  It owns the env-spec table (indexed by the CC_ENV_* ids from
//  cc_layout.inc), the typed parse helpers, and the two codegen emitters the
//  controller exposes (`-print-env-example`, `-print-ts-types`).
//
//  Exported (all .global, AAPCS64, x19-x28 preserved):
//    cc_env_load(x0=layout ptr)      parse every env var in the table into
//                                    the caller's env-runtime block
//                                    (x0 + CC_LAY_SIZE + CC_ER_*); fail-loud
//                                    (exit 1) on a missing required var or an
//                                    invalid value
//    cc_env_u8(x0=name)    -> x0 = u8 value (0 on absent), ParseUint(s,10,8)
//    cc_env_dur(x0=name)   -> x0 = u64 ns (0 on absent), time.ParseDuration
//    cc_env_bool(x0=name)  -> x0 = 0/1 (0 on absent), strconv.ParseBool
//    cc_env_str(x0=name)   -> x0 = ptr to the raw value or null (absent)
//    cc_env_print_example()   print the -print-env-example output
//    cc_env_print_ts_types()  print the -print-ts-types output
//
//  Go source references (differential-tested behaviors)
//  ----------------------------------------------------
//    * env table order and bind kinds: envspec.go:54-294 (envSpec())
//    * absent/empty == Go default:     main.go:99-115 (LoadConfig): a var
//      that is unset OR "" is skipped; a Required var that is skipped is an
//      error ("missing required env var"), the others keep the Go zero value.
//    * uint8: strconv.ParseUint(s,10,8) — envspec.go:40-45 (bindUint8);
//      digits only, no sign, no '_', value 0..255 else "value out of range"
//      (internal/strconv/atoi.go:47-144).
//    * duration: time.ParseDuration — envspec.go:33-38 (bindDuration);
//      time/format.go:1631-1728 + leadingInt/leadingFraction
//      (format.go:1554-1603); units ns/us/µs/μs/ms/s/m/h
//      (format.go:1615-1624); overflow is an error, NOT a saturate.
//    * bool: strconv.ParseBool — envspec.go:47-52 (bindBool);
//      internal/strconv/atob.go:10-18: exactly "1","t","T","true","TRUE",
//      "True" -> true; "0","f","F","false","FALSE","False" -> false; any
//      other value (including whitespace-padded) is an error.
//    * codegen: main.go:52-59 (printEnvExample), main.go:61-97
//      (printTSTypes), names.go All* arrays.
//
//  Fail-loud contract (cc_layout.inc error conventions)
//  ----------------------------------------------------
//    "error: invalid value for <NAME>: <msg>" via cc_fail -> exit 1.  The
//    <msg> is a short reason ("invalid duration", "missing unit in
//    duration", "unknown unit in duration", "invalid bool value",
//    "invalid uint8 value", "value out of range").  The exact Go error
//    strings (with %q of the raw value) are intentionally NOT replicated:
//    the task contract fixes the asm error format, and only the parsed
//    VALUES are differential-tested.
//
//  AAPCS64 notes (see cc_util.S for the full rules)
//  --------------------------------------------------
//    * Callee-saved (must be preserved across any `bl`): x19-x28, x29.
//    * d8-d15 are callee-saved; only d0-d7 are used here.
//    * sp stays 16-byte aligned at every call site.
//    * Never join statements with ';' — one instruction per line.
//
// ============================================================================

#include "cc_platform.h"
    .arch armv8.2-a
#include "cc_layout.inc"
#include "cc_env.h"
    .text

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
    .quad \name
    .byte \kind
    .byte \required
    .byte \store_op
    .byte 0
    .word \target
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
// Typed parse helpers (module-local; preserve x19-x28; clobber x0-x17 and
// d0-d7 only; may be called only by this module).
// ============================================================================
    .text

// ----------------------------------------------------------------------------
// env_parse_bool(x0=s) -> x0 = 0/1, x1 = 0 ok / 1 error
//   strconv.ParseBool (internal/strconv/atob.go:10-18): exact match against
//   the twelve accepted strings; no trimming, no case folding.
// ----------------------------------------------------------------------------
    .p2align 2
env_parse_bool:
    stp x19, x30, [sp, #-16]!       // x19 = string across the cc_streq calls
    mov x19, x0
    mov x0, x19
    LEA x1, env_bool_true_1
    bl cc_streq
    cbnz x0, .Lpb_true
    mov x0, x19
    LEA x1, env_bool_true_t
    bl cc_streq
    cbnz x0, .Lpb_true
    mov x0, x19
    LEA x1, env_bool_true_T
    bl cc_streq
    cbnz x0, .Lpb_true
    mov x0, x19
    LEA x1, env_bool_true_true
    bl cc_streq
    cbnz x0, .Lpb_true
    mov x0, x19
    LEA x1, env_bool_true_TRUE
    bl cc_streq
    cbnz x0, .Lpb_true
    mov x0, x19
    LEA x1, env_bool_true_True
    bl cc_streq
    cbnz x0, .Lpb_true
    mov x0, x19
    LEA x1, env_bool_false_0
    bl cc_streq
    cbnz x0, .Lpb_false
    mov x0, x19
    LEA x1, env_bool_false_f
    bl cc_streq
    cbnz x0, .Lpb_false
    mov x0, x19
    LEA x1, env_bool_false_F
    bl cc_streq
    cbnz x0, .Lpb_false
    mov x0, x19
    LEA x1, env_bool_false_false
    bl cc_streq
    cbnz x0, .Lpb_false
    mov x0, x19
    LEA x1, env_bool_false_FALSE
    bl cc_streq
    cbnz x0, .Lpb_false
    mov x0, x19
    LEA x1, env_bool_false_False
    bl cc_streq
    cbnz x0, .Lpb_false
    mov x0, #0
    mov x1, #1
    ldp x19, x30, [sp], #16
    ret
.Lpb_true:
    mov x0, #1
    mov x1, #0
    ldp x19, x30, [sp], #16
    ret
.Lpb_false:
    mov x0, #0
    mov x1, #0
    ldp x19, x30, [sp], #16
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
//   an error.  (Go returns maxVal=255 on range error; bindUint8 discards it,
//   so the caller sees only the error.)
// ----------------------------------------------------------------------------
    .p2align 2
env_parse_u8:
    ldrb w1, [x0]
    cbz w1, .Lpu8_err_syntax        // "" -> ErrSyntax (atoi.go:50)
    mov x2, #0                      // n
.Lpu8_loop:
    ldrb w1, [x0]
    cbz w1, .Lpu8_done
    cmp w1, #'0'
    b.lt .Lpu8_err_syntax
    cmp w1, #'9'
    b.gt .Lpu8_err_syntax
    sub w1, w1, #'0'
    mov x3, #10
    mul x2, x2, x3
    add x2, x2, x1
    cmp x2, #255
    b.hi .Lpu8_err_range            // n1 > maxVal (atoi.go:132)
    add x0, x0, #1
    b .Lpu8_loop
.Lpu8_done:
    mov x0, x2
    mov x1, #0
    ret
.Lpu8_err_syntax:
    mov x0, #0
    mov x1, #1
    ret
.Lpu8_err_range:
    mov x0, #0
    mov x1, #2
    ret

// ----------------------------------------------------------------------------
// env_dur_leading_int(x0=s) -> x0 = v, x1 = s', x2 = pre(0/1), x3 = err(0/1)
//   Port of time.leadingInt (time/format.go:1554-1572).  Overflow (x >
//   1<<63/10 before, or x > 1<<63 after the multiply-add) is an error,
//   exactly as Go propagates errLeadingInt -> "time: invalid duration".
//   Uses x4-x7; preserves x8-x28.
// ----------------------------------------------------------------------------
    .p2align 2
env_dur_leading_int:
    mov x2, #0                      // v
    mov x3, #0                      // pre
    movz x4, #0x8000, lsl #48       // 1<<63
    mov x5, #10
    udiv x5, x4, x5                 // 1<<63/10
.Lpdli_loop:
    ldrb w6, [x0]
    cmp w6, #'0'
    b.lt .Lpdli_done
    cmp w6, #'9'
    b.gt .Lpdli_done
    cmp x2, x5                      // x > 1<<63/10 ?
    b.hi .Lpdli_ovf
    sub w6, w6, #'0'
    mov x7, #10
    mul x2, x2, x7
    add x2, x2, x6
    cmp x2, x4                      // x > 1<<63 ?
    b.hi .Lpdli_ovf
    mov x3, #1
    add x0, x0, #1
    b .Lpdli_loop
.Lpdli_done:
    mov x1, x0                      // x1 = s'
    mov x0, x2                      // x0 = v
    mov x2, x3                      // x2 = pre
    mov x3, #0                      // x3 = no error
    ret
.Lpdli_ovf:
    mov x0, #0
    mov x1, #0
    mov x2, #0
    mov x3, #1
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
//   far below that).  PROLOGUE 2 gives x19-x22 as scratch so x0-x17 (the
//   caller's live registers) are left untouched.
// ----------------------------------------------------------------------------
    .p2align 2
env_dur_leading_frac:
    PROLOGUE 2                      // x19 = s, x20 = digit scratch
    mov x2, #0                      // f
    mov x3, #1                      // scale
    mov x4, #0                      // overflow flag
    mov x5, #0                      // post
    mov x6, #10
    mov x7, #10
    udiv x7, x1, x7                 // (1<<63-1)/10 == floor(1<<63/10)
    mov x19, x0                     // s (advances)
.Lpd_f_loop:
    ldrb w20, [x19]
    cmp w20, #'0'
    b.lt .Lpd_f_done
    cmp w20, #'9'
    b.gt .Lpd_f_done
    mov x5, #1                      // a digit was consumed
    cbnz x4, .Lpd_f_skip
    cmp x2, x7                      // f > (1<<63-1)/10 ?
    b.hi .Lpd_f_ovf
    sub w20, w20, #'0'
    mul x2, x2, x6
    add x2, x2, x20
    cmp x2, x1                      // y > 1<<63 ?
    b.hi .Lpd_f_ovf
    mul x3, x3, x6                  // scale *= 10
    b .Lpd_f_skip
.Lpd_f_ovf:
    mov x4, #1
.Lpd_f_skip:
    add x19, x19, #1
    b .Lpd_f_loop
.Lpd_f_done:
    mov x0, x2                      // x0 = f
    mov x1, x3                      // x1 = scale
    mov x2, x19                     // x2 = s'
    mov x3, x5                      // x3 = post
    EPILOGUE 2
    ret

// ----------------------------------------------------------------------------
// env_dur_unit(x0=unit ptr, x1=len) -> x0 = unit value in ns, or 0 unknown
//   time/format.go:1615-1624 unitMap.  The unit scan (ParseDuration's
//   `for ; i < len(s); i++` at format.go:1686-1692) already stopped at '.'
//   or a digit, so the unit here is exactly one of the eight map keys; the
//   length disambiguates (e.g. "m" minute vs "ms" millisecond).
//   Uses x2-x7; preserves x8-x28.
// ----------------------------------------------------------------------------
    .p2align 2
env_dur_unit:
    ldrb w2, [x0]                   // b0
    cmp x1, #1
    b.eq .Lpdu_len1
    cmp x1, #2
    b.eq .Lpdu_len2
    cmp x1, #3
    b.eq .Lpdu_len3
    b .Lpdu_unknown
.Lpdu_len1:
    cmp w2, #'s'
    b.eq .Lpdu_s
    cmp w2, #'m'
    b.eq .Lpdu_m
    cmp w2, #'h'
    b.eq .Lpdu_h
    b .Lpdu_unknown
.Lpdu_len2:
    ldrb w3, [x0, #1]               // b1
    cmp w2, #'n'
    b.ne .Lpdu_2_not_n
    cmp w3, #'s'
    b.eq .Lpdu_ns
    b .Lpdu_unknown
.Lpdu_2_not_n:
    cmp w2, #'u'
    b.ne .Lpdu_2_not_u
    cmp w3, #'s'
    b.eq .Lpdu_us
    b .Lpdu_unknown
.Lpdu_2_not_u:
    cmp w2, #'m'
    b.ne .Lpdu_unknown
    cmp w3, #'s'
    b.eq .Lpdu_ms
    b .Lpdu_unknown
.Lpdu_len3:
    ldrb w3, [x0, #1]               // b1
    ldrb w4, [x0, #2]               // b2
    cmp w4, #'s'
    b.ne .Lpdu_unknown
    cmp w2, #0xC2                   // U+00B5 micro sign (C2 B5)
    b.ne .Lpdu_3_not_b5
    cmp w3, #0xB5
    b.eq .Lpdu_us
    b .Lpdu_unknown
.Lpdu_3_not_b5:
    cmp w2, #0xCE                   // U+03BC Greek small letter mu (CE BC)
    b.ne .Lpdu_unknown
    cmp w3, #0xBC
    b.eq .Lpdu_us
    b .Lpdu_unknown
.Lpdu_ns:
    mov x0, #1
    ret
.Lpdu_us:
    mov x0, #1000
    ret
.Lpdu_ms:
    movz x0, #0x4240
    movk x0, #0x000F, lsl #16       // 1000000 (ms)
    ret
.Lpdu_s:
    MOV_NANOSEC x0                  // 1000000000 (s)
    ret
.Lpdu_m:
    MOV_DUR_MIN x0
    ret
.Lpdu_h:
    MOV_DUR_HOUR x0
    ret
.Lpdu_unknown:
    mov x0, #0
    ret

// ----------------------------------------------------------------------------
// env_dur_component(x0=s, x1=d, x2=1<<63) -> x0 = s', x1 = d', x2 = err
//   Parses ONE "number (fraction)? unit" component of a duration string and
//   accumulates it into d — the body of Go's ParseDuration loop
//   (time/format.go:1652-1720).  Error codes: 1 invalid duration, 2 missing
//   unit, 3 unknown unit.  Uses x4-x17 and d0-d7; preserves x19-x28.
//   Live state (x8-x17) is kept in caller-saved registers the sub-helpers
//   promise not to touch, so x30 is the only register that must be saved
//   across the three `bl`s.
// ----------------------------------------------------------------------------
    .p2align 2
env_dur_component:
    stp x30, xzr, [sp, #-16]!       // save x30 (x19-x28 untouched by design)
    mov x8, x0                      // s (advances)
    mov x9, x1                      // d (accumulator)
    mov x10, x2                     // 1<<63
    bl env_dur_leading_int          // x0=v, x1=s', x2=pre, x3=err
    cbnz x3, .Lpdc_err_invalid
    mov x11, x2                     // pre
    mov x14, x0                     // v
    mov x8, x1                      // s
    ldrb w3, [x8]
    cmp w3, #'.'
    b.ne .Lpdc_no_frac
    add x8, x8, #1
    mov x0, x8
    mov x1, x10
    bl env_dur_leading_frac         // x0=f, x1=scale, x2=s', x3=post
    mov x15, x0                     // f
    mov x16, x1                     // scale
    mov x12, x3                     // post
    mov x8, x2                      // s
    b .Lpdc_have_digits
.Lpdc_no_frac:
    mov x15, #0                     // f = 0
    mov x16, #1                     // scale = 1 (unused: f == 0)
    mov x12, #0                     // post = false
.Lpdc_have_digits:
    cbnz x11, .Lpdc_unit_scan       // pre || post, else no digits (".s")
    cbnz x12, .Lpdc_unit_scan
    b .Lpdc_err_invalid
.Lpdc_unit_scan:
    mov x13, #0                     // unit length
.Lpdc_us_loop:
    add x3, x8, x13
    ldrb w4, [x3]
    cbz w4, .Lpdc_us_done
    cmp w4, #'.'
    b.eq .Lpdc_us_done
    cmp w4, #'0'
    b.lt .Lpdc_us_inc
    cmp w4, #'9'
    b.le .Lpdc_us_done
.Lpdc_us_inc:
    add x13, x13, #1
    b .Lpdc_us_loop
.Lpdc_us_done:
    cbz x13, .Lpdc_err_missing_unit
    mov x0, x8
    mov x1, x13
    bl env_dur_unit                 // x0 = unit value or 0
    cbz x0, .Lpdc_err_unknown_unit
    mov x17, x0                     // unit value
    udiv x3, x10, x17               // 1<<63/unit
    cmp x14, x3                     // v > 1<<63/unit ?
    b.hi .Lpdc_err_invalid
    mul x14, x14, x17               // v *= unit
    cbz x15, .Lpdc_no_frac_add
    ucvtf d0, x15                   // float64(f)
    ucvtf d1, x17                   // float64(unit)
    ucvtf d2, x16                   // float64(scale)
    fdiv d3, d1, d2                 // float64(unit) / scale
    fmul d0, d0, d3                 // float64(f) * that
    fcvtzu x3, d0                   // uint64(...), truncate toward zero
    add x14, x14, x3
    cmp x14, x10                    // v > 1<<63 ?
    b.hi .Lpdc_err_invalid
.Lpdc_no_frac_add:
    add x9, x9, x14                 // d += v
    cmp x9, x10                     // d > 1<<63 ?
    b.hi .Lpdc_err_invalid
    add x8, x8, x13                 // s += unit length
    mov x0, x8
    mov x1, x9
    mov x2, #0
    ldp x30, xzr, [sp], #16
    ret
.Lpdc_err_invalid:
    mov x0, #0
    mov x1, #0
    mov x2, #1
    ldp x30, xzr, [sp], #16
    ret
.Lpdc_err_missing_unit:
    mov x0, #0
    mov x1, #0
    mov x2, #2
    ldp x30, xzr, [sp], #16
    ret
.Lpdc_err_unknown_unit:
    mov x0, #0
    mov x1, #0
    mov x2, #3
    ldp x30, xzr, [sp], #16
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
//       -Duration(d), format.go:1721-1723)
//     * positive d > 1<<63-1 -> error (format.go:1724-1726)
// ----------------------------------------------------------------------------
    .p2align 2
env_parse_duration:
    PROLOGUE 3                      // x19 = neg, x20 = 1<<63, x21 = d
    mov x19, #0
    ldrb w1, [x0]
    cmp w1, #'-'
    b.ne .Lpd_plus
    mov x19, #1
    add x0, x0, #1
    b .Lpd_signed
.Lpd_plus:
    cmp w1, #'+'
    b.ne .Lpd_signed
    add x0, x0, #1
.Lpd_signed:
    mov x22, x0                     // x22 = s
    ldrb w1, [x0]
    cmp w1, #'0'
    b.ne .Lpd_not_zero
    ldrb w2, [x0, #1]
    cbz w2, .Lpd_zero               // s == "0"
.Lpd_not_zero:
    cbz w1, .Lpd_err_invalid        // s == "" after the sign
    movz x20, #0x8000, lsl #48       // 1<<63
    mov x21, #0                     // d = 0
.Lpd_loop:
    ldrb w1, [x22]
    cbz w1, .Lpd_loop_done
    mov x0, x22
    mov x1, x21
    mov x2, x20
    bl env_dur_component            // x0 = s', x1 = d', x2 = err
    cbnz x2, .Lpd_comp_err
    mov x22, x0
    mov x21, x1
    b .Lpd_loop
.Lpd_loop_done:
    cbz x19, .Lpd_pos
    neg x0, x21                     // -Duration(d) (two's complement)
    mov x1, #0
    b .Lpd_ret
.Lpd_pos:
    sub x1, x20, #1                 // 1<<63 - 1
    cmp x21, x1
    b.hi .Lpd_err_invalid
    mov x0, x21
    mov x1, #0
    b .Lpd_ret
.Lpd_zero:
    mov x0, #0
    mov x1, #0
    b .Lpd_ret
.Lpd_comp_err:
    mov x0, #0
    mov x1, x2
    b .Lpd_ret
.Lpd_err_invalid:
    mov x0, #0
    mov x1, #1
    b .Lpd_ret
.Lpd_ret:
    EPILOGUE 3
    ret

// ============================================================================
// Fail-loud helpers (module-local, noreturn; cc_fail never returns).
// ============================================================================

// ----------------------------------------------------------------------------
// env_fail_invalid(x0=name, x1=msg) -> cc_fail("invalid value for NAME: msg")
// ----------------------------------------------------------------------------
    .p2align 2
env_fail_invalid:
    stp x19, x20, [sp, #-16]!
    stp x21, x30, [sp, #-16]!
    mov x19, x0                     // name
    mov x20, x1                     // msg
    sub sp, sp, #256
    mov x0, sp
    LEA x1, env_msg_invalid_value_for
    bl cc_cat_cstr                  // x0 = NUL position
    mov x1, x19
    bl cc_cat_cstr
    LEA x1, env_msg_sep
    bl cc_cat_cstr
    mov x1, x20
    bl cc_cat_cstr
    mov x0, sp
    bl cc_fail                      // noreturn

// ----------------------------------------------------------------------------
// env_fail_missing(x0=name) -> cc_fail("missing required env var NAME")
// ----------------------------------------------------------------------------
    .p2align 2
env_fail_missing:
    stp x19, x30, [sp, #-16]!
    mov x19, x0                     // name
    sub sp, sp, #256
    mov x0, sp
    LEA x1, env_msg_missing_required
    bl cc_cat_cstr
    mov x1, x19
    bl cc_cat_cstr
    mov x0, sp
    bl cc_fail                      // noreturn

// ============================================================================
// Store helpers (module-local; preserve x19-x28).
// ============================================================================

// ----------------------------------------------------------------------------
// env_store_string(x0=erbase, x1=raw, x2=entry)
//   Stores the raw pointer at the entry's target; the store op extends it to
//   the multi-field binds (envspec.go:170-197).
// ----------------------------------------------------------------------------
    .p2align 2
env_store_string:
    ldr w3, [x2, #12]
    add x3, x0, x3
    str x1, [x3]
    ldrb w3, [x2, #10]              // store op
    cmp w3, #CC_ENVSTORE_SNAP_BOTH
    b.eq .Les_snap
    cmp w3, #CC_ENVSTORE_LOG_BOTH
    b.eq .Les_log
    cmp w3, #CC_ENVSTORE_IMAGE_THREE
    b.eq .Les_image
    ret
.Les_snap:
    add x3, x0, #(CC_ER_SINGLE_STAGE_EGRESS + CC_CC_SNAPSHOT_ID)
    str x1, [x3]
    ret
.Les_log:
    add x3, x0, #(CC_ER_SINGLE_STAGE_EGRESS + CC_CC_LOGFILE)
    str x1, [x3]
    ret
.Les_image:
    add x3, x0, #(CC_ER_SCALE_AND_EGRESS + CC_CC_IMAGE_NAME)
    str x1, [x3]
    add x3, x0, #(CC_ER_SINGLE_STAGE_EGRESS + CC_CC_IMAGE_NAME)
    str x1, [x3]
    ret

// ----------------------------------------------------------------------------
// env_store_duration(x0=erbase, x1=raw, x2=entry)
// ----------------------------------------------------------------------------
    .p2align 2
env_store_duration:
    PROLOGUE 2                      // x19 = erbase, x20 = entry
    mov x19, x0
    mov x20, x2
    mov x0, x1
    bl env_parse_duration           // x0 = ns, x1 = err
    cbnz x1, .Lesd_bad
    ldr w3, [x20, #12]
    add x3, x19, x3
    str x0, [x3]
    EPILOGUE 2
    ret
.Lesd_bad:
    ldr x0, [x20]                   // name
    cmp x1, #2
    b.eq .Lesd_missing
    cmp x1, #3
    b.eq .Lesd_unknown
    LEA x1, env_msg_invalid_duration
    b .Lesd_fail
.Lesd_missing:
    LEA x1, env_msg_missing_unit
    b .Lesd_fail
.Lesd_unknown:
    LEA x1, env_msg_unknown_unit
.Lesd_fail:
    bl env_fail_invalid              // noreturn

// ----------------------------------------------------------------------------
// env_store_u8(x0=erbase, x1=raw, x2=entry)
// ----------------------------------------------------------------------------
    .p2align 2
env_store_u8:
    PROLOGUE 2                      // x19 = erbase, x20 = entry
    mov x19, x0
    mov x20, x2
    mov x0, x1
    bl env_parse_u8                 // x0 = value, x1 = err
    cbnz x1, .Lesu_bad
    ldr w3, [x20, #12]
    add x3, x19, x3
    strb w0, [x3]
    EPILOGUE 2
    ret
.Lesu_bad:
    ldr x0, [x20]                   // name
    cmp x1, #2
    b.eq .Lesu_range
    LEA x1, env_msg_invalid_u8
    b .Lesu_fail
.Lesu_range:
    LEA x1, env_msg_u8_range
.Lesu_fail:
    bl env_fail_invalid              // noreturn

// ----------------------------------------------------------------------------
// env_store_bool(x0=erbase, x1=raw, x2=entry)
// ----------------------------------------------------------------------------
    .p2align 2
env_store_bool:
    PROLOGUE 2                      // x19 = erbase, x20 = entry
    mov x19, x0
    mov x20, x2
    mov x0, x1
    bl env_parse_bool               // x0 = 0/1, x1 = err
    cbnz x1, .Lesb_bad
    ldr w3, [x20, #12]
    add x3, x19, x3
    strb w0, [x3]
    EPILOGUE 2
    ret
.Lesb_bad:
    ldr x0, [x20]                   // name
    LEA x1, env_msg_invalid_bool
    bl env_fail_invalid              // noreturn

// ============================================================================
// cc_env_load — parse every env var in the table into the caller's
// env-runtime block.
//   in:  x0 = layout ptr (base of the caller's combined struct; the Layout's
//        CC_LAY_* offsets are kept as-is at +0, the env-runtime block the
//        module writes sits at +CC_LAY_SIZE).
//   out: none; fail-loud (exit 1) on a missing required var or an invalid
//        value.
//   Port of main.go LoadConfig (main.go:99-115) over envSpec().
// ----------------------------------------------------------------------------
    .p2align 2
    .global cc_env_load
    FUNC_TYPE(cc_env_load)
cc_env_load:
    PROLOGUE 4                      // x19 = base, x20 = erbase, x21 = id, x22 = table
    mov x19, x0
    add x20, x0, #CC_LAY_SIZE
    // Zero the env-runtime block first: LoadConfig starts from a zero Config
    // (main.go:100 `var cfg Config`), so absent/empty vars keep the Go zero
    // value (0 / false / null).
    mov x0, x20
    add x1, x20, #CC_ER_SIZE
.Lel_zero:
    stp xzr, xzr, [x0], #16
    cmp x0, x1
    b.lo .Lel_zero
    mov x21, #0
    LEA x22, env_spec
.Lel_loop:
    cmp x21, #CC_ENV_COUNT
    b.hs .Lel_done
    add x23, x22, x21, lsl #4       // entry = env_spec + id*16
    ldr x0, [x23]                   // name
    bl getenv
    cbz x0, .Lel_absent
    ldrb w1, [x0]
    cbz w1, .Lel_absent             // empty == absent (main.go:104)
    mov x25, x0                     // raw (preserve across the dispatch)
    ldrb w24, [x23, #8]             // bind kind
    cmp w24, #CC_ENVKIND_STRING
    b.eq .Lel_string
    cmp w24, #CC_ENVKIND_DURATION
    b.eq .Lel_duration
    cmp w24, #CC_ENVKIND_U8
    b.eq .Lel_u8
    mov x0, x20
    mov x1, x25
    mov x2, x23
    bl env_store_bool               // x0=erbase, x1=raw, x2=entry
    b .Lel_next
.Lel_string:
    mov x0, x20
    mov x1, x25
    mov x2, x23
    bl env_store_string
    b .Lel_next
.Lel_duration:
    mov x0, x20
    mov x1, x25
    mov x2, x23
    bl env_store_duration
    b .Lel_next
.Lel_u8:
    mov x0, x20
    mov x1, x25
    mov x2, x23
    bl env_store_u8
    b .Lel_next
.Lel_absent:
    ldrb w24, [x23, #9]             // required
    cbz w24, .Lel_next
    ldr x0, [x23]                   // name
    bl env_fail_missing              // noreturn
.Lel_next:
    add x21, x21, #1
    b .Lel_loop
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
// cc_env_u8(x0=name) -> x0 = u8 value (0 on absent)
// ----------------------------------------------------------------------------
    .p2align 2
    .global cc_env_u8
    FUNC_TYPE(cc_env_u8)
cc_env_u8:
    PROLOGUE 1                      // x19 = name
    mov x19, x0
    bl getenv
    cbz x0, .Lu8_none
    ldrb w1, [x0]
    cbz w1, .Lu8_none
    bl env_parse_u8
    cbnz x1, .Lu8_bad
    EPILOGUE 1
    ret
.Lu8_none:
    mov x0, #0
    EPILOGUE 1
    ret
.Lu8_bad:
    mov x0, x19
    cmp x1, #2
    b.eq .Lu8_range
    LEA x1, env_msg_invalid_u8
    b .Lu8_fail
.Lu8_range:
    LEA x1, env_msg_u8_range
.Lu8_fail:
    bl env_fail_invalid              // noreturn

// ----------------------------------------------------------------------------
// cc_env_dur(x0=name) -> x0 = u64 ns (0 on absent)
// ----------------------------------------------------------------------------
    .p2align 2
    .global cc_env_dur
    FUNC_TYPE(cc_env_dur)
cc_env_dur:
    PROLOGUE 1                      // x19 = name
    mov x19, x0
    bl getenv
    cbz x0, .Ldur_none
    ldrb w1, [x0]
    cbz w1, .Ldur_none
    bl env_parse_duration
    cbnz x1, .Ldur_bad
    EPILOGUE 1
    ret
.Ldur_none:
    mov x0, #0
    EPILOGUE 1
    ret
.Ldur_bad:
    mov x0, x19
    cmp x1, #2
    b.eq .Ldur_missing
    cmp x1, #3
    b.eq .Ldur_unknown
    LEA x1, env_msg_invalid_duration
    b .Ldur_fail
.Ldur_missing:
    LEA x1, env_msg_missing_unit
    b .Ldur_fail
.Ldur_unknown:
    LEA x1, env_msg_unknown_unit
.Ldur_fail:
    bl env_fail_invalid              // noreturn

// ----------------------------------------------------------------------------
// cc_env_bool(x0=name) -> x0 = 0/1 (0 on absent)
// ----------------------------------------------------------------------------
    .p2align 2
    .global cc_env_bool
    FUNC_TYPE(cc_env_bool)
cc_env_bool:
    PROLOGUE 1                      // x19 = name
    mov x19, x0
    bl getenv
    cbz x0, .Lbool_none
    ldrb w1, [x0]
    cbz w1, .Lbool_none
    bl env_parse_bool
    cbnz x1, .Lbool_bad
    EPILOGUE 1
    ret
.Lbool_none:
    mov x0, #0
    EPILOGUE 1
    ret
.Lbool_bad:
    mov x0, x19
    LEA x1, env_msg_invalid_bool
    bl env_fail_invalid              // noreturn

// ----------------------------------------------------------------------------
// cc_env_str(x0=name) -> x0 = ptr to the raw value, or null (absent/empty)
// ----------------------------------------------------------------------------
    .p2align 2
    .global cc_env_str
    FUNC_TYPE(cc_env_str)
cc_env_str:
    stp x19, x30, [sp, #-16]!       // preserve x30 across the getenv bl
    bl getenv
    cbz x0, .Lstr_none
    ldrb w1, [x0]
    cbnz w1, .Lstr_have
.Lstr_none:
    mov x0, #0
.Lstr_have:
    ldp x19, x30, [sp], #16
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
    .p2align 2
    .global cc_env_print_example
    FUNC_TYPE(cc_env_print_example)
cc_env_print_example:
    PROLOGUE 3                      // x19 = last group, x20 = index, x21 = table
    mov x19, #-1
    mov x20, #0
    LEA x21, env_example_table
.Lpe_loop:
    cmp x20, #CC_ENV_EXAMPLE_COUNT
    b.hs .Lpe_done
    add x22, x21, x20, lsl #5       // entry = table + index*32
    ldrb w23, [x22]                 // group
    cmp w23, w19
    b.eq .Lpe_same_group
    LEA x0, env_group_header_prefix
    bl cc_puts
    LEA x0, env_group_names
    add x0, x0, w23, uxtw #3
    ldr x0, [x0]
    bl cc_puts
    LEA x0, env_group_header_suffix
    bl cc_puts
    mov w19, w23
.Lpe_same_group:
    ldr x0, [x22, #8]               // comment
    cbz x0, .Lpe_no_comment
    mov x23, x0
    LEA x0, env_comment_prefix
    bl cc_puts
    mov x0, x23
    bl cc_puts
    LEA x0, env_newline
    bl cc_puts
.Lpe_no_comment:
    ldr x0, [x22, #16]              // name
    bl cc_puts
    LEA x0, env_eq_quote
    bl cc_puts
    ldr x0, [x22, #24]              // example
    bl cc_puts
    LEA x0, env_quote_newline
    bl cc_puts
    add x20, x20, #1
    b .Lpe_loop
.Lpe_done:
    EPILOGUE 3
    ret

// ----------------------------------------------------------------------------
// cc_env_print_ts_types — print the -print-ts-types output (one static blob;
// the unions over the All* arrays are compile-time constants).
//   Port of main.go printTSTypes (main.go:61-97).
// ----------------------------------------------------------------------------
    .p2align 2
    .global cc_env_print_ts_types
    FUNC_TYPE(cc_env_print_ts_types)
cc_env_print_ts_types:
    stp x19, x30, [sp, #-16]!
    LEA x0, env_ts_types_blob
    bl cc_puts
    ldp x19, x30, [sp], #16
    ret

    .text
    .end