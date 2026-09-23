// ============================================================================
// cc_env.h — env-config module constants (CPP macros)
// ============================================================================
//  Shared constants for the cc_env.S env-config parsing module.  Everything
//  here is a CPP macro, never .equ: the fail-loud discipline (AGENTS.md hard
//  rule 6) means a module-local `.equ CC_ENVKIND_STRING, 0` collides with the
//  macro and fails to assemble instead of silently shadowing it.
//
//  The env-spec table (cc_env.S) is indexed by the CC_ENV_* ids from
//  cc_layout.inc; each entry is {name ptr, bind kind} and the bind kinds are
//  the constants below.  cc_env_load(x0=layout ptr) walks the table, parses
//  every var via getenv, and stores the typed values into the caller's
//  env-runtime block (CC_ER_* in cc_layout.inc) — a byte-for-byte port of
//  Go's LoadConfig (core/controller/main.go:99-115) driven by envSpec()
//  (core/controller/envspec.go).
// ============================================================================
#ifndef CC_ENV_H
#define CC_ENV_H

// Bind kinds — what a table entry's raw env string means, mirroring the Go
// Bind closures in envspec.go:
//   string   bindString  (envspec.go:29-31)  -> store the getenv() pointer
//   duration bindDuration (envspec.go:33-38) -> time.ParseDuration(s)
//   uint8    bindUint8   (envspec.go:40-45)  -> strconv.ParseUint(s, 10, 8)
//   bool     bindBool    (envspec.go:47-52)  -> strconv.ParseBool(s)
#define CC_ENVKIND_STRING   0
#define CC_ENVKIND_DURATION 1
#define CC_ENVKIND_U8       2
#define CC_ENVKIND_BOOL     3

// Store ops — how a parsed value maps onto the Config struct fields (the
// Go Bind closures that write more than one field, envspec.go:170-197).
#define CC_ENVSTORE_ONE         0
#define CC_ENVSTORE_SNAP_BOTH   1
#define CC_ENVSTORE_LOG_BOTH    2
#define CC_ENVSTORE_IMAGE_THREE 3

// Duration unit values in ns (time/format.go:1615-1624 unitMap)
#define CC_DUR_NS   1
#define CC_DUR_US   1000
#define CC_DUR_MS   1000000
#define CC_DUR_S    1000000000
#define CC_DUR_MIN  60000000000      // 60s  (unitMap "m")
#define CC_DUR_HOUR 3600000000000    // 3600s (unitMap "h")

// MOV_DUR_MIN / MOV_DUR_HOUR — load the two unit values that exceed 32 bits
// without a literal pool entry (movz/movk, like MOV_NANOSEC in cc_platform.h).
    .macro MOV_DUR_MIN reg
    movz \reg, #0x5800
    movk \reg, #0xF847, lsl #16
    movk \reg, #0x000D, lsl #32
    .endm
    .macro MOV_DUR_HOUR reg
    movz \reg, #0xA000
    movk \reg, #0x30B8, lsl #16
    movk \reg, #0x0346, lsl #32
    .endm

#endif // CC_ENV_H