package main

import (
	"fmt"
	"testing"
)

// newTestController wires a Controller for unit tests the same way main.go does
// under the merged data model: each stage is a *Stage carrying both its
// StageStatus and its Ops table, and NewController takes the stages map plus the
// event and command routing maps. Ops are no longer a separate argument to
// NewController; the per-stage ops a test supplies are folded into the matching
// *Stage here.
//
// Each test supplies only the maps relevant to the behavior under test and passes
// empty (nil) maps for the dimensions it does not exercise. Both known stages are
// always seeded (with an empty Ops table when a test gives none) so that
// applyStageTarget's c.stages[...].Status access never hits a nil *Stage,
// regardless of which routes a given test drives.
func newTestController(
	paths         map[PathName]PathStatus,
	ops           map[StageName]map[StageState]func() error,
	eventRoutes   map[Event]StageTarget,
	commandRoutes map[ControlCommand]StageTarget,
) *Controller {
	stages := map[StageName]*Stage{
		"normalize":        {Status: StageStatus{Desired: "stopped", Actual: "stopped"}},
		"scale-and-egress": {Status: StageStatus{Desired: "stopped", Actual: "stopped"}},
	}
	for name, stage := range stages {
		if stageOps, ok := ops[name]; ok {
			stage.Ops = stageOps
		} else {
			stage.Ops = map[StageState]func() error{}
		}
	}
	if eventRoutes == nil {
		eventRoutes = map[Event]StageTarget{}
	}
	if commandRoutes == nil {
		commandRoutes = map[ControlCommand]StageTarget{}
	}

	controller, _ := NewController(paths, stages, eventRoutes, commandRoutes)
	return controller
}

// State transitions happen in two phases under the current implementation:
// HandleEvent / HandleControl only record intent by setting a stage's Desired
// state (gated, for commands, by any Prerequisite). The Ops that perform the
// actual launch/teardown run later, in HandleReconcile, for every stage whose
// Actual still differs from its Desired. Tests therefore drive the handler to
// record intent and then call HandleReconcile to converge Actual toward Desired
// before asserting that the corresponding op fired.

func TestControllerReceivesIngress0Ready(t *testing.T) {
	correctCall := 0

	paths := map[PathName]PathStatus{
		"ingress0": "unknown",
	}

	ops := map[StageName]map[StageState]func() error{
		"normalize": {
			Running: func() error { correctCall++; return nil },
		},
	}

	eventRoutes := map[Event]StageTarget{
		{"ingress0", "ready"}: {Stage: "normalize", State: Running},
	}

	c := newTestController(paths, ops, eventRoutes, nil)

	// Phase 1: record intent. This sets normalize.Desired = running but does not
	// yet invoke any op.
	if err := c.HandleEvent(Event{Path: "ingress0", Status: "ready"}); err != nil {
		t.Fatalf("HandleEvent returned unexpected error: %v", err)
	}

	if correctCall != 0 {
		t.Fatalf("normalize launcher ran during HandleEvent; want it deferred to reconcile (got %d calls)", correctCall)
	}

	// Phase 2: converge. reconcile sees normalize.Actual (stopped) != Desired
	// (running) and runs the Running op.
	if err := c.HandleReconcile(); err != nil {
		t.Fatalf("HandleReconcile returned unexpected error: %v", err)
	}

	if correctCall != 1 {
		t.Errorf("normalize launcher called %d times; want 1", correctCall)
	}
}

func TestControllerLaunchesEgress(t *testing.T) {

	// egressRoutes mirrors the scale-and-egress "start" route defined in main.go:
	// launching egress is gated on the normalized path being ready. It is read,
	// never mutated, by both subtests, so a single shared value is fine.
	egressRoutes := map[ControlCommand]StageTarget{
		{"scale-and-egress", "start"}: {
			Stage: "scale-and-egress",
			State: Running,
			Prerequisite: func(c *Controller) error {
				if c.paths["normalized"] != "ready" {
					return fmt.Errorf("normalized path is not ready")
				}
				return nil
			},
		},
	}

	t.Run("prerequisites satisfied", func(t *testing.T) {
		correctCall := 0

		paths := map[PathName]PathStatus{
			"normalized": "ready",
		}

		ops := map[StageName]map[StageState]func() error{
			"scale-and-egress": {
				Running: func() error { correctCall++; return nil },
			},
		}

		c := newTestController(paths, ops, nil, egressRoutes)

		// Phase 1: the prerequisite passes, so this records
		// scale-and-egress.Desired = running. The launcher has not run yet.
		err := c.HandleControl(ControlCommand{
			Component: "scale-and-egress",
			Action:    "start",
		})

		if err != nil {
			t.Fatalf("HandleControl returned unexpected error: %v", err)
		}

		if correctCall != 0 {
			t.Fatalf("scale-and-egress launcher ran during HandleControl; want it deferred to reconcile (got %d calls)", correctCall)
		}

		// Phase 2: converge and confirm the launcher fired exactly once.
		if err := c.HandleReconcile(); err != nil {
			t.Fatalf("HandleReconcile returned unexpected error: %v", err)
		}

		if correctCall != 1 {
			t.Fatalf("scale-and-egress launcher called %d times; want 1", correctCall)
		}
	})

	t.Run("prerequisites not satisfied", func(t *testing.T) {
		incorrectCall := 0

		paths := map[PathName]PathStatus{
			"normalized": "unknown",
		}

		ops := map[StageName]map[StageState]func() error{
			"scale-and-egress": {
				Running: func() error { incorrectCall++; return nil },
			},
		}

		c := newTestController(paths, ops, nil, egressRoutes)

		// The prerequisite fails, so HandleControl returns an error and leaves
		// scale-and-egress.Desired at its seeded "stopped" value.
		err := c.HandleControl(ControlCommand{
			Component: "scale-and-egress",
			Action:    "start",
		})

		if err == nil {
			t.Fatal("HandleControl - expected error, received nil")
		}

		// A reconcile here is a no-op guard: because Desired was never advanced to
		// running, Actual already matches Desired for every stage and no op runs.
		// This proves a rejected command leaves the system inert even across a
		// reconcile tick.
		if err := c.HandleReconcile(); err != nil {
			t.Fatalf("HandleReconcile returned unexpected error: %v", err)
		}

		if incorrectCall != 0 {
			t.Errorf("scale-and-egress launcher should not have been called; got %d calls", incorrectCall)
		}
	})
}
