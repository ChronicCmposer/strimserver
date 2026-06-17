package main

import (
	"fmt"
	"testing"
)

// newTestController wires a Controller for unit tests the same way main.go does:
// by passing the ops table plus the event and command routing maps into
// NewController. Each test supplies only the maps relevant to the behavior under
// test and passes empty (nil) maps for the dimensions it does not exercise.
//
// The stages map is seeded here with both known stages so that setStage's
// c.stages[...].Actual access never hits a nil *StageStatus, regardless of which
// routes a given test drives.
func newTestController(
	paths         map[Path]PathStatus,
	ops           map[Stage]map[StageState]func() error,
	eventRoutes   map[EventKey]StageTarget,
	commandRoutes map[ControlCommandKey]StageTarget,
) *Controller {
	stages := map[Stage]*StageStatus{
		"normalize":        {Desired: "stopped", Actual: "stopped"},
		"scale-and-egress": {Desired: "stopped", Actual: "stopped"},
	}
	if ops == nil {
		ops = map[Stage]map[StageState]func() error{}
	}
	if eventRoutes == nil {
		eventRoutes = map[EventKey]StageTarget{}
	}
	if commandRoutes == nil {
		commandRoutes = map[ControlCommandKey]StageTarget{}
	}
	return NewController(paths, stages, ops, eventRoutes, commandRoutes)
}

func TestControllerReceivesIngress0Ready(t *testing.T) {
	correctCall := 0

	paths := map[Path]PathStatus{
		"ingress0": "unknown",
	}

	ops := map[Stage]map[StageState]func() error{
		"normalize": {
			Running: func() error { correctCall++; return nil },
		},
	}

	eventRoutes := map[EventKey]StageTarget{
		{"ingress0", "ready"}: {Stage: "normalize", State: Running},
	}

	c := newTestController(paths, ops, eventRoutes, nil)

	if err := c.HandleEvent(Event{Path: "ingress0", Status: "ready"}); err != nil {
		t.Fatalf("HandleEvent returned unexpected error: %v", err)
	}

	if correctCall != 1 {
		t.Errorf("normalize launcher called %d times; want 1", correctCall)
	}
}

func TestControllerLaunchesEgress(t *testing.T) {

	// egressRoutes mirrors the scale-and-egress "start" route defined in main.go:
	// launching egress is gated on the normalized path being ready. It is read,
	// never mutated, by both subtests, so a single shared value is fine.
	egressRoutes := map[ControlCommandKey]StageTarget{
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

		paths := map[Path]PathStatus{
			"normalized": "ready",
		}

		ops := map[Stage]map[StageState]func() error{
			"scale-and-egress": {
				Running: func() error { correctCall++; return nil },
			},
		}

		c := newTestController(paths, ops, nil, egressRoutes)

		err := c.HandleControl(ControlCommand{
			Component: "scale-and-egress",
			Action:    "start",
		})

		if err != nil {
			t.Fatalf("HandleControl returned unexpected error: %v", err)
		}

		if correctCall != 1 {
			t.Fatalf("scale-and-egress launcher called %d times; want 1", correctCall)
		}
	})

	t.Run("prerequisites not satisfied", func(t *testing.T) {
		incorrectCall := 0

		paths := map[Path]PathStatus{
			"normalized": "unknown",
		}

		ops := map[Stage]map[StageState]func() error{
			"scale-and-egress": {
				Running: func() error { incorrectCall++; return nil },
			},
		}

		c := newTestController(paths, ops, nil, egressRoutes)

		err := c.HandleControl(ControlCommand{
			Component: "scale-and-egress",
			Action:    "start",
		})

		if err == nil {
			t.Fatal("HandleControl - expected error, received nil")
		}

		if incorrectCall != 0 {
			t.Errorf("scale-and-egress launcher should not have been called; got %d calls", incorrectCall)
		}
	})
}
