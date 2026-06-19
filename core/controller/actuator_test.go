package main

import (
	"context"
	"errors"
	"slices"
	"testing"
	"time"
)

// This file is a spec. It defines the behavior of a *yet-unwritten*
// actuator.go in package main.
//
// SCOPE. The actuator implements the side of the Ops table boundary the
// controller does not: turning a desired stage state into a real lifecycle
// action by running a command. It is deliberately runtime-agnostic. It does
// NOT build, know, or validate `ctr` (or docker/podman/...) commands. The
// exact launch/teardown commands for each stage are INJECTED as configuration
// by a higher-level module, which owns their correctness. The actuator only:
//
//   1. selects the configured command for a given (stage, state), and
//   2. applies the two lifecycle semantics it is responsible for:
//        - Start: run the configured launch command(s) in order, FAIL-FAST —
//          abort on the first error and return it. Completing the whole
//          sequence is what "creation confirmed" means here, so any failure
//          propagates and the controller will not advance Actual;
//        - Stop:  run the configured teardown command(s) in order, BEST-EFFORT
//          — attempt every command even past a failure, treat
//          ErrContainerNotFound as success, and return any other error(s) so
//          tearing down an already-absent container converges cleanly.
//
// Start and Stop are symmetric in shape (both are ordered command sequences);
// they differ only in error policy (fail-fast vs best-effort). Neither assumes
// anything about how many commands a given runtime needs for either action.
//
// CONTEXT & TIMEOUT. The actuator is built with a root context (supplied by
// main and canceled on shutdown) and a default command timeout. Every command
// runs under its own context, derived from the root via WithTimeout using THAT
// COMMAND'S timeout (Command.Timeout, falling back to the injected default when
// non-positive), so (a) a stuck command fails after its own timeout instead of
// blocking the controller's single goroutine, and (b) canceling the root aborts
// whatever command is in flight. Per-command timeouts are injected via
// StageCommands; the fallback default is injected via NewActuator. The actuator
// hardcodes no duration of its own.
//
// Surface that actuator.go must provide for this file to compile:
//
//	// CommandRunner executes a command described by argv. The real
//	// implementation shells out to the container runtime; it translates a
//	// "no such task/container" condition into ErrContainerNotFound.
//	type CommandRunner interface {
//		Run(ctx context.Context, argv []string) error
//	}
//
//	// ErrContainerNotFound reports that a teardown target does not exist.
//	var ErrContainerNotFound error
//
//	// Command is one injected command: an opaque argv plus the timeout that
//	// bounds it. Contents of Argv are opaque to the actuator; a non-positive
//	// Timeout falls back to the actuator's injected default timeout.
//	type Command struct {
//		Argv    []string
//		Timeout time.Duration
//	}
//
//	// StageCommands is the injected, runtime-agnostic configuration for one stage.
//	type StageCommands struct {
//		Start []Command // ordered launch commands; run fail-fast
//		Stop  []Command // ordered teardown commands; run best-effort, ErrContainerNotFound benign
//	}
//
//	// Actuator's fields are unexported; build one with NewActuator (mirroring
//	// the Controller / NewController convention in this package).
//	type Actuator struct { /* ctx; runner; commands */ }
//
//	// NewActuator validates and constructs an Actuator. ctx is the root context
//	// (derived in main, canceled on shutdown); every command runs under a
//	// context derived from it via WithTimeout(ctx, command's timeout), so
//	// canceling ctx aborts in-flight commands. defaultTimeout is the fallback
//	// applied to any command whose Command.Timeout is non-positive, and must
//	// itself be positive so no command ever runs unbounded. Like NewController,
//	// it reports configuration that cannot work, joining all problems:
//	//   - a nil ctx or nil runner,
//	//   - a non-positive defaultTimeout, and
//	//   - any stage whose Start sequence is empty (a stage that can never be
//	//     launched). An empty Stop sequence is permitted: teardown for that
//	//     stage becomes a no-op that returns nil.
//	func NewActuator(ctx context.Context, runner CommandRunner, commands map[StageName]StageCommands, defaultTimeout time.Duration) (*Actuator, error)
//
//	// StartOp returns the launch closure for a stage, for the Running slot of
//	// a Stage's Ops table.
//	func (a *Actuator) StartOp(stage StageName) func() error
//
//	// StopOp returns the teardown closure for a stage, for the Stopped slot.
//	func (a *Actuator) StopOp(stage StageName) func() error
//
//	// Ops bundles StartOp and StopOp into the map shape Stage.Ops expects:
//	//   map[StageState]func() error{Running: a.StartOp(s), Stopped: a.StopOp(s)}
//	func (a *Actuator) Ops(stage StageName) map[StageState]func() error

// recordingRunner is a fake CommandRunner. It records every argv and the
// context it ran under, and returns a scripted result per call, so a test can
// drive the success / error / not-found paths and inspect the per-command
// context without invoking any real container runtime. Like a real exec-based
// runner, it fails immediately if handed an already-canceled context.
type recordingRunner struct {
	calls [][]string
	ctxs  []context.Context
	// result, when set, decides the error for the call at the given zero-based
	// index. nil result (or out-of-range index) means success.
	result func(callIndex int, argv []string) error
}

func (r *recordingRunner) Run(ctx context.Context, argv []string) error {
	idx := len(r.calls)
	r.calls = append(r.calls, slices.Clone(argv)) // callers must not retain argv
	r.ctxs = append(r.ctxs, ctx)
	if err := ctx.Err(); err != nil {
		return err // a real exec runner can't start a command under a dead context
	}
	if r.result == nil {
		return nil
	}
	return r.result(idx, argv)
}

// cmds is a small helper to build a Command sequence from plain argvs (default
// timeout). Tests that care about timeouts construct Command literals directly.
func cmds(argvs ...[]string) []Command {
	out := make([]Command, len(argvs))
	for i, a := range argvs {
		out[i] = Command{Argv: a}
	}
	return out
}

// newTestActuator builds an Actuator through the production constructor and
// fails the test if construction is rejected, so every test exercises the real
// NewActuator path (mirroring newTestController in controller_test.go). Tests
// that don't care about cancellation or timeouts get a Background root and a
// fixed positive default; tests that exercise those call NewActuator directly.
func newTestActuator(t *testing.T, runner CommandRunner, commands map[StageName]StageCommands) *Actuator {
	t.Helper()
	a, err := NewActuator(context.Background(), runner, 5*time.Second, commands)
	if err != nil {
		t.Fatalf("NewActuator returned unexpected error: %v", err)
	}
	return a
}

// assertDeadlineNear checks a context carries a deadline ~want from start.
// Deadline() is stable after the per-command cancel fires, so reading it
// post-Run is valid. Tolerance is generous (±1s) since commands run instantly
// under the fake; it still cleanly distinguishes e.g. 2s from 8s.
func assertDeadlineNear(t *testing.T, ctx context.Context, start time.Time, want time.Duration) { //nolint:revive
	t.Helper()
	deadline, ok := ctx.Deadline()
	if !ok {
		t.Fatalf("command context has no deadline; want ~%v", want)
	}
	if d := deadline.Sub(start); d < want-time.Second || d > want+time.Second {
		t.Errorf("command deadline is %v from start; want ~%v", d, want)
	}
}

// TestNewActuatorValidatesConfig pins the constructor's validation contract,
// the analog of NewController rejecting routes with no backing op: NewActuator
// rejects a configuration that cannot work, and accepts a valid one.
func TestNewActuatorValidatesConfig(t *testing.T) {
	const okTimeout = 5 * time.Second
	valid := map[StageName]StageCommands{
		"normalize": {
			Start: cmds([]string{"start", "normalize"}),
			Stop:  cmds([]string{"stop", "normalize"}),
		},
	}

	t.Run("nil context rejected", func(t *testing.T) {
		if _, err := NewActuator(nil, &recordingRunner{}, okTimeout, valid); err == nil { //nolint:staticcheck
			t.Error("NewActuator accepted a nil context; want an error")
		}
	})

	t.Run("nil runner rejected", func(t *testing.T) {
		if _, err := NewActuator(context.Background(), nil, okTimeout, valid); err == nil {
			t.Error("NewActuator accepted a nil runner; want an error")
		}
	})

	t.Run("non-positive default timeout rejected", func(t *testing.T) {
		if _, err := NewActuator(context.Background(), &recordingRunner{}, 0, valid); err == nil {
			t.Error("NewActuator accepted a non-positive default timeout; want an error")
		}
	})

	t.Run("stage without a Start rejected", func(t *testing.T) {
		_, err := NewActuator(context.Background(), &recordingRunner{}, okTimeout, map[StageName]StageCommands{
			"normalize": {Stop: cmds([]string{"stop", "normalize"})}, // no Start
		})
		if err == nil {
			t.Error("NewActuator accepted a stage with no Start command; want an error")
		}
	})

	t.Run("empty Stop permitted", func(t *testing.T) {
		a, err := NewActuator(context.Background(), &recordingRunner{}, okTimeout, map[StageName]StageCommands{
			"normalize": {Start: cmds([]string{"start", "normalize"})}, // no Stop
		})
		if err != nil {
			t.Fatalf("NewActuator rejected a stage with no Stop; want it permitted: %v", err)
		}
		// Teardown for a stage with no Stop commands is a no-op that succeeds.
		if err := a.StopOp("normalize")(); err != nil {
			t.Errorf("StopOp for a stage with no Stop commands returned %v; want nil", err)
		}
	})

	t.Run("valid config accepted", func(t *testing.T) {
		if _, err := NewActuator(context.Background(), &recordingRunner{}, okTimeout, valid); err != nil {
			t.Errorf("NewActuator rejected a valid config: %v", err)
		}
	})
}

// --- command selection ----------------------------------------------------

// TestStartOpRunsConfiguredStartCommandsInOrder: the Running closure runs each
// injected Start command verbatim, in the configured order.
func TestStartOpRunsConfiguredStartCommandsInOrder(t *testing.T) {
	first := []string{"launch-step-1", "normalize", "--opaque-flag"}
	second := []string{"launch-step-2", "normalize"}
	runner := &recordingRunner{}
	a := newTestActuator(t, runner, map[StageName]StageCommands{
		"normalize": {Start: cmds(first, second)},
	})

	if err := a.StartOp("normalize")(); err != nil {
		t.Fatalf("StartOp returned unexpected error: %v", err)
	}
	if len(runner.calls) != 2 {
		t.Fatalf("StartOp issued %d commands; want exactly 2", len(runner.calls))
	}
	if !slices.Equal(runner.calls[0], first) || !slices.Equal(runner.calls[1], second) {
		t.Errorf("StartOp ran %v; want injected Start commands [%v %v] in order", runner.calls, first, second)
	}
}

// TestStopOpRunsConfiguredStopCommandsInOrder: the Stopped closure runs each
// injected Stop command verbatim, in the configured order.
func TestStopOpRunsConfiguredStopCommandsInOrder(t *testing.T) {
	first := []string{"teardown-step-1", "normalize"}
	second := []string{"teardown-step-2", "normalize"}
	runner := &recordingRunner{}
	a := newTestActuator(t, runner, map[StageName]StageCommands{
		"normalize": {
			Start: cmds([]string{"start", "normalize"}), // present so NewActuator accepts the stage
			Stop:  cmds(first, second),
		},
	})

	if err := a.StopOp("normalize")(); err != nil {
		t.Fatalf("StopOp returned unexpected error: %v", err)
	}
	if len(runner.calls) != 2 {
		t.Fatalf("StopOp issued %d commands; want exactly 2", len(runner.calls))
	}
	if !slices.Equal(runner.calls[0], first) || !slices.Equal(runner.calls[1], second) {
		t.Errorf("StopOp ran %v; want injected Stop commands [%v %v] in order", runner.calls, first, second)
	}
}

// TestActuatorDispatchesPerStageAndState: the actuator selects strictly by
// (stage, state). Each stage's op runs that stage's own configured command,
// never another stage's, and Running/Stopped pick Start/Stop respectively.
func TestActuatorDispatchesPerStageAndState(t *testing.T) {
	runner := &recordingRunner{}
	a := newTestActuator(t, runner, map[StageName]StageCommands{
		"normalize": {
			Start: cmds([]string{"start", "normalize"}),
			Stop:  cmds([]string{"stop", "normalize"}),
		},
		"scale-and-egress": {
			Start: cmds([]string{"start", "scale-and-egress"}),
			Stop:  cmds([]string{"stop", "scale-and-egress"}),
		},
	})

	cases := []struct {
		name string
		op   func() error
		want []string
	}{
		{"normalize start", a.StartOp("normalize"), []string{"start", "normalize"}},
		{"normalize stop", a.StopOp("normalize"), []string{"stop", "normalize"}},
		{"egress start", a.StartOp("scale-and-egress"), []string{"start", "scale-and-egress"}},
		{"egress stop", a.StopOp("scale-and-egress"), []string{"stop", "scale-and-egress"}},
	}

	for _, c := range cases {
		runner.calls = nil
		if err := c.op(); err != nil {
			t.Fatalf("%s: unexpected error: %v", c.name, err)
		}
		if len(runner.calls) != 1 || !slices.Equal(runner.calls[0], c.want) {
			t.Errorf("%s ran %v; want %v", c.name, runner.calls, c.want)
		}
	}
}

// --- start lifecycle semantics --------------------------------------------

// TestStartReturnsRunnerOutcome: Start returns nil only when the launch
// command succeeds, and propagates a failure (wrapped) so the controller's
// reconcile loop will not record the stage as running.
func TestStartReturnsRunnerOutcome(t *testing.T) {
	commands := map[StageName]StageCommands{
		"normalize": {Start: cmds([]string{"launch", "normalize"})},
	}

	t.Run("success", func(t *testing.T) {
		a := newTestActuator(t, &recordingRunner{}, commands)
		if err := a.StartOp("normalize")(); err != nil {
			t.Fatalf("StartOp returned error on a successful launch: %v", err)
		}
	})

	t.Run("failure propagates", func(t *testing.T) {
		boom := errors.New("runner: launch failed")
		a := newTestActuator(t, &recordingRunner{
			result: func(int, []string) error { return boom },
		}, commands)

		err := a.StartOp("normalize")()
		if err == nil {
			t.Fatal("StartOp returned nil despite a failed launch; want an error")
		}
		if !errors.Is(err, boom) {
			t.Errorf("StartOp error %v does not wrap the runner error", err)
		}
	})
}

// TestStartIsFailFast pins the policy that distinguishes Start from Stop: Start
// runs its commands in order and ABORTS on the first failure. A failed step
// means the launch cannot proceed, so subsequent steps must not run. (Contrast
// TestStopPropagatesRealError, where Stop attempts every command regardless.)
func TestStartIsFailFast(t *testing.T) {
	boom := errors.New("runner: launch step 1 failed")
	runner := &recordingRunner{
		result: func(callIndex int, _ []string) error {
			if callIndex == 0 {
				return boom
			}
			return nil
		},
	}
	a := newTestActuator(t, runner, map[StageName]StageCommands{
		"normalize": {Start: cmds([]string{"step-1", "normalize"}, []string{"step-2", "normalize"})},
	})

	err := a.StartOp("normalize")()
	if err == nil {
		t.Fatal("StartOp returned nil despite a failed step; want an error")
	}
	if !errors.Is(err, boom) {
		t.Errorf("StartOp error %v does not wrap the runner error", err)
	}
	if len(runner.calls) != 1 {
		t.Errorf("StartOp issued %d commands; want 1 (fail-fast must not run step-2 after step-1 failed)", len(runner.calls))
	}
}

// --- stop lifecycle semantics ---------------------------------------------

// TestStopIsIdempotentWhenNotFound: ErrContainerNotFound from teardown is
// success. Stop still issues every configured command (best-effort).
func TestStopIsIdempotentWhenNotFound(t *testing.T) {
	var ErrContainerNotFound error
	runner := &recordingRunner{
		result: func(int, []string) error { return ErrContainerNotFound }, 
	}
	a := newTestActuator(t, runner, map[StageName]StageCommands{
		"normalize": {
			Start: cmds([]string{"start", "normalize"}),
			Stop:  cmds([]string{"kill", "normalize"}, []string{"rm", "normalize"}),
		},
	})

	if err := a.StopOp("normalize")(); err != nil {
		t.Fatalf("StopOp returned error for an absent container; want nil: %v", err)
	}
	if len(runner.calls) != 2 {
		t.Errorf("StopOp issued %d commands; want 2 even when not found", len(runner.calls))
	}
}

// TestStopPropagatesRealError: a non-not-found failure is surfaced, and Stop
// still attempts the remaining teardown commands (best-effort convergence).
func TestStopPropagatesRealError(t *testing.T) {
	boom := errors.New("runner: runtime unreachable")
	runner := &recordingRunner{
		result: func(callIndex int, _ []string) error {
			if callIndex == 0 {
				return boom
			}
			return nil
		},
	}
	a := newTestActuator(t, runner, map[StageName]StageCommands{
		"normalize": {
			Start: cmds([]string{"start", "normalize"}), // present so NewActuator accepts the stage
			Stop:  cmds([]string{"kill", "normalize"}, []string{"rm", "normalize"}),
		},
	})

	err := a.StopOp("normalize")()
	if err == nil {
		t.Fatal("StopOp returned nil despite a real teardown failure; want an error")
	}
	if !errors.Is(err, boom) {
		t.Errorf("StopOp error %v does not wrap the runner error", err)
	}
	if len(runner.calls) != 2 {
		t.Errorf("StopOp issued %d commands; want 2 (best-effort continues past a failure)", len(runner.calls))
	}
}

// --- context & timeout: per-command, shutdown path ------------------------

// TestActuatorAppliesPerCommandTimeout: each command runs under a context whose
// deadline is bounded by THAT command's injected Command.Timeout, and a
// non-positive Command.Timeout falls back to the constructor's injected default.
// The two-command subtest proves the timeout is genuinely per command — distinct
// commands in one sequence get distinct deadlines (and therefore distinct
// contexts).
func TestActuatorAppliesPerCommandTimeout(t *testing.T) {
	t.Run("distinct per-command timeouts honored", func(t *testing.T) {
		runner := &recordingRunner{}
		a, err := NewActuator(context.Background(), runner, 5*time.Second, map[StageName]StageCommands{
			"normalize": {Start: []Command{
				{Argv: []string{"step-1", "normalize"}, Timeout: 2 * time.Second},
				{Argv: []string{"step-2", "normalize"}, Timeout: 8 * time.Second},
			}},
		}) // default unused: both commands carry their own timeout
		if err != nil {
			t.Fatalf("NewActuator: %v", err)
		}

		start := time.Now()
		if err := a.StartOp("normalize")(); err != nil {
			t.Fatalf("StartOp: %v", err)
		}
		if len(runner.ctxs) != 2 {
			t.Fatalf("recorded %d contexts; want 2", len(runner.ctxs))
		}
		assertDeadlineNear(t, runner.ctxs[0], start, 2*time.Second)
		assertDeadlineNear(t, runner.ctxs[1], start, 8*time.Second)
	})

	t.Run("injected default applies when command timeout unset", func(t *testing.T) {
		const injectedDefault = 3 * time.Second // distinctive, to prove it's the injected value
		runner := &recordingRunner{}
		a, err := NewActuator(context.Background(), runner, injectedDefault, map[StageName]StageCommands{
			"normalize": {Start: []Command{{Argv: []string{"start", "normalize"}}}}, // Timeout 0
		})
		if err != nil {
			t.Fatalf("NewActuator: %v", err)
		}

		start := time.Now()
		if err := a.StartOp("normalize")(); err != nil {
			t.Fatalf("StartOp: %v", err)
		}
		assertDeadlineNear(t, runner.ctxs[0], start, injectedDefault)
	})
}

// TestActuatorAbortsCommandsWhenRootCanceled is the shutdown property: when the
// root context (the SIGTERM-canceled context from main) is canceled, the
// per-command context derived from it is canceled too. The runner — like a real
// exec runner under a dead context — fails immediately, and Start fails fast.
func TestActuatorAbortsCommandsWhenRootCanceled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // simulate shutdown before the op runs

	runner := &recordingRunner{}
	a, err := NewActuator(ctx, runner, 5*time.Second, map[StageName]StageCommands{
		"normalize": {Start: cmds([]string{"step-1", "normalize"}, []string{"step-2", "normalize"})},
	})
	if err != nil {
		t.Fatalf("NewActuator: %v", err)
	}

	err = a.StartOp("normalize")()
	if err == nil {
		t.Fatal("StartOp returned nil under a canceled root; want an error")
	}
	if !errors.Is(err, context.Canceled) {
		t.Errorf("StartOp error %v is not a context cancellation", err)
	}
	if len(runner.calls) != 1 {
		t.Errorf("ran %d commands under a canceled root; want 1 (fail-fast)", len(runner.calls))
	}
	if runner.ctxs[0].Err() == nil {
		t.Error("command context was not canceled though the root was")
	}
}

// --- boundary wiring: Actuator -> Stage.Ops -> Controller -----------------

// TestOpsBundlesStartAndStopForStage: Ops(stage) returns the map shape that
// Stage.Ops expects — non-nil closures keyed by exactly Running and Stopped,
// where Running is the StartOp and Stopped is the StopOp.
func TestOpsBundlesStartAndStopForStage(t *testing.T) {
	runner := &recordingRunner{}
	a := newTestActuator(t, runner, map[StageName]StageCommands{
		"normalize": {
			Start: cmds([]string{"start", "normalize"}),
			Stop:  cmds([]string{"stop", "normalize"}),
		},
	})

	ops := a.Ops("normalize")
	if ops[Running] == nil || ops[Stopped] == nil {
		t.Fatalf("Ops missing Running and/or Stopped op: %#v", ops)
	}
	for state := range ops {
		if state != Running && state != Stopped {
			t.Errorf("Ops contains unexpected state %q", state)
		}
	}

	// Running slot dispatches to the Start command...
	if err := ops[Running](); err != nil {
		t.Fatalf("Ops[Running] error: %v", err)
	}
	if got := runner.calls[len(runner.calls)-1]; !slices.Equal(got, []string{"start", "normalize"}) {
		t.Errorf("Ops[Running] ran %v; want the Start command", got)
	}
	// ...and the Stopped slot dispatches to the Stop command.
	if err := ops[Stopped](); err != nil {
		t.Fatalf("Ops[Stopped] error: %v", err)
	}
	if got := runner.calls[len(runner.calls)-1]; !slices.Equal(got, []string{"stop", "normalize"}) {
		t.Errorf("Ops[Stopped] ran %v; want the Stop command", got)
	}
}

