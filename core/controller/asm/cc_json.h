// ============================================================================
// cc_json.h — JSON encode/decode module constants (CPP macros)
// ============================================================================
//  Shared constants for the cc_json.S JSON module — the byte-exact port of
//  Go's encoding/json (v1, the classic package) for the controller's wire
//  payloads.  Everything here is a CPP macro, never .equ: the fail-loud
//  discipline (AGENTS.md hard rule 6) means a module-local `.equ
//  JSON_KEY_PATH_LEN, 4` collides with the macro and fails to assemble
//  instead of silently shadowing it.
//
//  The module mirrors the Go controller's json call sites (main.go):
//    * ENCODE: json.NewEncoder(w).Encode(status)   (main.go:396 /status)
//              wsjson.Write(wctx, conn, status)    (main.go:284, wsjson.go:57
//              -> json.NewEncoder(...).Encode)     Encoder appends '\n'
//    * DECODE: json.NewDecoder(r.Body).Decode(&m)  (main.go:376 /event,
//              /control)                           Decoder.Decode semantics
//
//  JSON-encoding decisions resolved from the Go source (encoding/json v1,
//  Go 1.26, all file:line evidence in the module header):
//    * Field order = Go struct field order (controller.go:46-64).
//    * Map keys sorted lexicographically (encode.go:794 strings.Compare).
//    * escapeHTML = true (Encoder default, stream.go:195) -> <, >, & are
//      escaped as \u003c \u003e \u0026; U+2028/U+2029 as \u2028/\u2029.
//    * Control chars < 0x20 -> \b \f \n \r \t short escapes, else \u00XX.
//    * DEL (0x7f) NOT escaped; valid UTF-8 passed through; invalid bytes
//      -> the literal "\ufffd" (encode.go:999-1066, tables.go:123).
//    * The payload builders emit the COMPACT object WITHOUT the trailing
//      '\n' that Encoder.Encode appends (stream.go:223): the newline is the
//      HTTP/websocket layer's job, exactly as Encoder adds it.
//    * DECODER = json.Decoder.Decode semantics (decode.go): leading
//      whitespace skipped; top-level null -> ok, fields untouched; unknown
//      keys ignored (their values fully validated and skipped); trailing
//      garbage AFTER the top-level value is ACCEPTED (Decode reads one
//      value and never scans past it — verified empirically, probe lines
//      "obj trailing x" -> ok); trailing garbage INSIDE the object (e.g.
//      {"a":1x}) is an error; null for a known key is a no-op; a known
//      key with a non-string value is an error ("cannot unmarshal").
//
//  String/id tables (documented rodata contract — see cc_json.S):
//    json_path_names        CC_PATH_* id      -> path name string
//    json_status_names      CC_STATUS_* id    -> status string
//    json_state_names       CC_STATE_* id     -> state string (incl. "" for
//                            CC_STATE_NOTARGET, mirroring NoTarget)
//    json_component_names   CC_COMPONENT_* id -> component string
//    json_action_names      CC_ACTION_* id    -> action string
//    json_stage_names       CC_STAGE_* id     -> stage name string
//  Every id outside the table's range (a bad id) is a caller error; the
//  module does not bounds-check id->string lookups (fail-fast contract:
//  ids are trusted, typed values — parse-don't-validate).
// ============================================================================
#ifndef CC_JSON_H
#define CC_JSON_H

// ----------------------------------------------------------------------------
// JSON syntax constants (chars)
// ----------------------------------------------------------------------------
#define JSON_CH_OBJ_OPEN     '{'
#define JSON_CH_OBJ_CLOSE    '}'
#define JSON_CH_ARR_OPEN     '['
#define JSON_CH_ARR_CLOSE    ']'
#define JSON_CH_COLON        ':'
#define JSON_CH_COMMA        ','
#define JSON_CH_QUOTE        '"'
#define JSON_CH_BACKSLASH    '\\'
#define JSON_CH_LOWERCASE_U  'u'
#define JSON_CH_HEX_PREFIX   '0'

// ----------------------------------------------------------------------------
// Wire key names (Go struct field names from controller.go json tags) and
// their byte lengths.  The .S emits these exact bytes; the *_LEN macros are
// the fail-loud companions (a stale length fails the driver's golden check).
// ----------------------------------------------------------------------------
#define JSON_KEY_PATH        "path"
#define JSON_KEY_PATH_LEN    4
#define JSON_KEY_STATUS      "status"
#define JSON_KEY_STATUS_LEN  6
#define JSON_KEY_STAGE       "stage"
#define JSON_KEY_STAGE_LEN   5
#define JSON_KEY_STATE       "state"
#define JSON_KEY_STATE_LEN   5
#define JSON_KEY_PATHS       "paths"
#define JSON_KEY_PATHS_LEN   5
#define JSON_KEY_STAGES      "stages"
#define JSON_KEY_STAGES_LEN  6
#define JSON_KEY_DESIRED     "desired"
#define JSON_KEY_DESIRED_LEN 7
#define JSON_KEY_ACTUAL      "actual"
#define JSON_KEY_ACTUAL_LEN  6
#define JSON_KEY_COMPONENT   "component"
#define JSON_KEY_COMPONENT_LEN 9
#define JSON_KEY_ACTION      "action"
#define JSON_KEY_ACTION_LEN  6

// ----------------------------------------------------------------------------
// Wire value strings (names.go) — the byte content the encoders emit and the
// decoders match against.  Single source of truth; cc_json.S asciz-emits
// these exact bytes.
// ----------------------------------------------------------------------------
#define JSON_S_INGRESS0            "ingress0"
#define JSON_S_NORMALIZED          "normalized"
#define JSON_S_UNKNOWN             "unknown"
#define JSON_S_READY               "ready"
#define JSON_S_NOTREADY            "not-ready"
#define JSON_S_RUNNING             "running"
#define JSON_S_STOPPED             "stopped"
#define JSON_S_EMPTY               ""
#define JSON_S_MEDIAMTX            "mediamtx"
#define JSON_S_NORMALIZE           "normalize"
#define JSON_S_SCALE_AND_EGRESS    "scale_and_egress"
#define JSON_S_SINGLE_STAGE_EGRESS "single_stage_egress"
#define JSON_S_EGRESS              "egress"
#define JSON_S_START               "start"
#define JSON_S_STOP                "stop"

// JSON literals (decoder)
#define JSON_LIT_NULL      "null"
#define JSON_LIT_NULL_LEN  4
#define JSON_LIT_TRUE      "true"
#define JSON_LIT_TRUE_LEN  4
#define JSON_LIT_FALSE     "false"
#define JSON_LIT_FALSE_LEN 5

// The escaped form Go writes for invalid UTF-8 and for U+FFFD (encode.go:1042):
// the SIX ASCII bytes  \ u f f f d   (no quotes).
#define JSON_ESC_UFFFD     "\\ufffd"
#define JSON_ESC_UFFFD_LEN 6

// The lowercase hex digits Go's \uXXXX uses (encode.go:1028 hex[]).
#define JSON_HEX_DIGITS    "0123456789abcdef"

// ----------------------------------------------------------------------------
// Decoder sentinel for an unrecognized string value
// ----------------------------------------------------------------------------
//  Go stores the raw string in the ControlComponent/ControlAction field and
//  the route lookup fails later ("control not implemented: %+v",
//  controller.go:219).  The asm out struct holds CC_* ids, so an
//  unrecognized value cannot be represented as a string: the decoder stores
//  CC_JSON_ID_UNKNOWN (0xff), and the ctr_ layer treats it exactly like Go
//  treats an unrecognized string — the route lookup misses.  Valid ids are
//  all < 0xff, so the sentinel cannot collide.
#define CC_JSON_ID_UNKNOWN 0xff

// ----------------------------------------------------------------------------
// Status table layouts (the data the cc_json_status encoder consumes)
// ----------------------------------------------------------------------------
//  Paths status table (x2 of cc_json_status).  Entries MUST be in ascending
//  name order: Go marshals map keys sorted lexicographically (encode.go:794),
//  and the encoder emits entries in table order.
//    +0   u64 count
//    +8   entry[count], each 16 bytes:
//         +0  const char *name        (NUL-terminated; the map key)
//         +8  u64 status              (CC_STATUS_* id)
//  Stages status table (x3 of cc_json_status), same sort contract:
//    +0   u64 count
//    +8   entry[count], each 24 bytes:
//         +0  const char *name        (NUL-terminated; the map key)
//         +8  u64 desired             (CC_STATE_* id)
//         +16 u64 actual              (CC_STATE_* id)
//  count == 0 emits "{}" — matching Go's handleStatus (controller.go:322-327)
//  which always returns non-nil maps (Clone/make), never "null".
#define CC_JSON_PTBL_ENTRY  16
#define CC_JSON_STBL_ENTRY  24

#endif // CC_JSON_H