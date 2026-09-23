// ============================================================================
// cc_state.h — state-machine / reconcile / listener / event-routing module
// constants (CPP macros)
// ============================================================================
//  Shared constants for the cc_state.S module — Phase 4.5, the STATE MACHINE
//  / reconcile / listener / event-routing port of core/controller/controller.go.
//  Everything here is a CPP macro, never .equ: the fail-loud discipline
//  (AGENTS.md hard rule 6) means a module-local `.equ CC_STATE_ERR_BADPATH,
//  -1` collides with the macro and fails to assemble instead of silently
//  shadowing it.  The CC_STAGE_* / CC_STATE_* / CC_PATH_* / CC_STATUS_* /
//  CC_COMPONENT_* / CC_ACTION_* ids and the CC_CTR_* / CC_STG_* / CC_PE_* /
//  CC_SE_* / CC_CMD_* / CC_TGT_* / CC_CS_* / CC_ER_* offsets come from
//  cc_layout.inc; the JSON wire-table entry sizes come from cc_json.h; this
//  header adds only what THIS module needs.
// ============================================================================
#ifndef CC_STATE_H
#define CC_STATE_H

// ----------------------------------------------------------------------------
// Handler error codes.  The Go controller returns error objects carrying a
// descriptive message; the port returns small negative codes (fail-loud, the
// message is written to stderr at the point of failure) and the HTTP layer
// (4.6) may map a code back to the Go error text for its 500 responses.
// Each code cites the controller.go line that produces the Go error.
// ----------------------------------------------------------------------------
#define CC_STATE_ERR_BADPATH   (-1)   // handlePathEvent: unknown path  (controller.go:225)
#define CC_STATE_ERR_BADSTATUS (-2)   // handlePathEvent: invalid status (:226)
#define CC_STATE_ERR_BADSTAGE  (-3)   // handleStageEvent: unknown stage (:238)
#define CC_STATE_ERR_BADSTATE  (-4)   // handleStageEvent: invalid state (:239)
#define CC_STATE_ERR_NOCTRL    (-5)   // handleControl: route miss      (:219)
#define CC_STATE_ERR_PREREQ    (-6)   // applyDesiredStageTarget: prereq failed (:279)
#define CC_STATE_ERR_NIL       (-7)   // handleAddListener: nil listener (:251)
#define CC_STATE_ERR_NOTREG    (-8)   // handleRemoveListener: not registered (:260)
#define CC_STATE_ERR_TIMEOUT   (-9)   // NewController: inflight timeout <= 0 (:162-164)
#define CC_STATE_ERR_FULL      (-10)  // listener cap exceeded (Go grows the slice;
                                      // the port fails loud at STATE_LISTENERS_MAX)

// ----------------------------------------------------------------------------
// Listener slice capacity — the fixed cap of the listeners slice port.
// Go's make([]*ControllerListener, 0, 1) (controller.go:169) grows without
// bound on append (:252); the single-threaded port backs the slice with a
// fixed array and fails loud at STATE_LISTENERS_MAX.
// ----------------------------------------------------------------------------
#define STATE_LISTENERS_MAX     8

// ----------------------------------------------------------------------------
// Route-table entry stride: the {key0, key1} key (16 bytes) followed by the
// StageTarget (CC_TGT_SIZE = 24 bytes) = 40 bytes per entry.  The route
// tables live in cc_state.S rodata: .quad count, then count entries.
// ----------------------------------------------------------------------------
#define STATE_ROUTE_STRIDE      40

#endif // CC_STATE_H