package main

import (
	"testing"
)

// newTestController wires a Controller for unit tests. It seeds the stages map
// with both known stages (so HandleEvent's c.stages[...].Actual access never
// hits a nil *StageStatus), and tolerates a nil terminators map for tests that
// only exercise launch paths.
func newTestController(
	paths 		map[Path]PathStatus,
	launchers 	map[Stage]func() error,
	terminators map[Stage]func() error,
) *Controller {
	stages := map[Stage]*StageStatus{
		"normalize":        {Desired: "stopped", Actual: "stopped"},
		"scale-and-egress": {Desired: "stopped", Actual: "stopped"},
	}
	if launchers == nil {
		launchers = map[Stage]func() error{}
	}
	if terminators == nil {
		terminators = map[Stage]func() error{}
	}
	return NewController(paths, stages, launchers, terminators)
}

func TestControllerReceivesIngress0Ready(t *testing.T) {
	correctCall := 0

	launchers := map[Stage]func() error {
		"normalize":        func() error { correctCall++; return nil },
		"scale-and-egress": func() error { return nil },
	}

	c := newTestController(map[Path]PathStatus{}, launchers, nil)

	if err := c.HandleEvent(Event{Path: "ingress0", Status: "ready"}); err != nil {
		t.Fatalf("HandleEvent returned unexpected error: %v", err)
	}

	if correctCall != 1 {
		t.Errorf("normalize launcher called %d times; want 1", correctCall)
	}
}

func TestControllerLaunchesEgress(t *testing.T) {

	t.Run("prerequisites satisfied", func(t *testing.T) {
		correctCall := 0

		paths := map[Path]PathStatus{
			"normalized": "ready",
		}

		launchers := map[Stage]func() error {
			"normalize":        func() error { return nil },
			"scale-and-egress": func() error { correctCall++; return nil },
		}

		c := newTestController(paths, launchers, nil)

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

		launchers := map[Stage]func() error {
			"normalize":        func() error { return nil },
			"scale-and-egress": func() error { incorrectCall++; return nil },
		}

		c := newTestController(paths, launchers, nil)

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



