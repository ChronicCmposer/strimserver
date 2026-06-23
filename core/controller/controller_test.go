package main

import (
   "context"
   "fmt"
   "sync/atomic"
   "testing"
   "time"
)

// testInFlightTimeout is generous on purpose: the ops these tests register
// return immediately, so the value only needs to be large enough that
// planReconcile never spuriously reports a timeout between a stage going
// in-flight and the next reconcile check.
const testInFlightTimeout = time.Minute

// newTestController wires a Controller the same way main.go does. Each stage is a
// *Stage carrying both its StageStatus and its Ops table; NewController takes the
// stages map plus the path-event and command routing maps, a context, a clock, an
// in-flight timeout, and an actions buffer size.
//
// Each test supplies only the maps relevant to the behavior under test and passes
// nil for the dimensions it does not exercise. Both known stages are always
// seeded (with an empty Ops table when a test gives none) so that
// applyDesiredStageTarget's c.stages[...].Status access never hits a nil *Stage,
// regardless of which routes a given test drives.
//
// Unlike the public Submit* entry points, the tests below drive the unexported
// handlers (handlePathEvent / handleControl / handleReconcile) directly. Those
// handlers run serially on a single goroutine in production, so calling them
// from a single-threaded test preserves that invariant without having to start
// Run() and synchronize through the actions channel.
func newTestController(
   t *testing.T,
   paths map[PathName]PathStatus,
   ops map[StageName]map[StageState]func(context.Context) error,
   pathEventRoutes map[PathEvent]StageTarget,
   commandRoutes map[ControlCommand]StageTarget,
) *Controller {
   t.Helper()

   stages := map[StageName]*Stage{
      "normalize":        {Status: StageStatus{Desired: Stopped, Actual: Stopped}},
      "scale-and-egress": {Status: StageStatus{Desired: Stopped, Actual: Stopped}},
   }
   for name, stage := range stages {
      if stageOps, ok := ops[name]; ok {
         stage.Ops = stageOps
      } else {
         stage.Ops = map[StageState]func(context.Context) error{}
      }
   }
   if pathEventRoutes == nil {
      pathEventRoutes = map[PathEvent]StageTarget{}
   }
   if commandRoutes == nil {
      commandRoutes = map[ControlCommand]StageTarget{}
   }

   c, err := NewController(
      context.Background(),
      paths,
      stages,
      pathEventRoutes,
      commandRoutes,
      time.Now,
      testInFlightTimeout,
      16, // actions buffer; unused on the success path, sized for safety
   )
   if err != nil {
      t.Fatalf("NewController returned unexpected error: %v", err)
   }
   return c
}

// recordingOp builds an op for a stage's Ops table together with the machinery to
// observe it. handleReconcile launches ops in their own goroutine, so an op's
// effects are NOT visible the instant handleReconcile returns: tests must wait on
// fired before trusting calls, and calls is touched only through sync/atomic so
// the read in the test goroutine races neither the op goroutine nor the race
// detector. fired is buffered so the op never blocks even if a test chooses not
// to drain it.
func recordingOp() (op func(context.Context) error, calls *int32, fired chan struct{}) {
   var n int32
   f := make(chan struct{}, 8)
   op = func(context.Context) error {
      atomic.AddInt32(&n, 1)
      f <- struct{}{}
      return nil
   }
   return op, &n, f
}

// awaitFire fails the test unless an op signals within a short deadline.
func awaitFire(t *testing.T, fired <-chan struct{}) {
   t.Helper()
   select {
   case <-fired:
   case <-time.After(time.Second):
      t.Fatal("expected an op to run during reconcile, but none did within 1s")
   }
}

// expectNoFire fails the test if an op signals within the window. The window is a
// best-effort negative check: a launch we failed to prevent would almost always
// fire well inside it.
func expectNoFire(t *testing.T, fired <-chan struct{}, window time.Duration) {
   t.Helper()
   select {
   case <-fired:
      t.Fatal("an op ran during reconcile but none should have")
   case <-time.After(window):
   }
}

// State transitions happen in two phases. handlePathEvent / handleControl only
// record intent by setting a stage's Desired state (gated, for commands, by any
// Prerequisite). The Ops that perform the actual launch/teardown run later, in
// handleReconcile, for every stage whose Actual still differs from its Desired.
// Tests therefore drive the handler to record intent and then call handleReconcile
// to converge Actual toward Desired before asserting that the corresponding op
// fired.

func TestControllerReceivesIngress0Ready(t *testing.T) {
   op, calls, fired := recordingOp()

   paths := map[PathName]PathStatus{
      "ingress0": Unknown,
   }

   ops := map[StageName]map[StageState]func(context.Context) error{
      "normalize": {
         Running: op,
      },
   }

   pathEventRoutes := map[PathEvent]StageTarget{
      {Path: "ingress0", Status: Ready}: {Stage: "normalize", State: Running},
   }

   c := newTestController(t, paths, ops, pathEventRoutes, nil)

   // Phase 1: record intent. This sets normalize.Desired = running but does not
   // yet invoke any op.
   if err := c.handlePathEvent(PathEvent{Path: "ingress0", Status: Ready}); err != nil {
      t.Fatalf("handlePathEvent returned unexpected error: %v", err)
   }

   if got := c.stages["normalize"].Status.Desired; got != Running {
      t.Fatalf("normalize Desired = %q after event; want %q", got, Running)
   }

   if n := atomic.LoadInt32(calls); n != 0 {
      t.Fatalf("normalize launcher ran during handlePathEvent; want it deferred to reconcile (got %d calls)", n)
   }

   // Phase 2: converge. reconcile sees normalize.Actual (stopped) != Desired
   // (running) and launches the Running op. The launch is asynchronous, so wait
   // for the op to signal before asserting it ran exactly once.
   c.handleReconcile()
   awaitFire(t, fired)

   if n := atomic.LoadInt32(calls); n != 1 {
      t.Errorf("normalize launcher called %d times; want 1", n)
   }
}

func TestControllerLaunchesEgress(t *testing.T) {

   // egressRoutes mirrors the scale-and-egress "start" route defined in main.go:
   // launching egress is gated on the normalized path being ready. It is read,
   // never mutated, by both subtests, so a single shared value is fine.
   egressRoutes := map[ControlCommand]StageTarget{
      {Component: "scale-and-egress", Action: "start"}: {
         Stage: "scale-and-egress",
         State: Running,
         Prerequisite: func(c *Controller) error {
            if c.paths["normalized"] != Ready {
               return fmt.Errorf("normalized path is not ready")
            }
            return nil
         },
      },
   }

   t.Run("prerequisites satisfied", func(t *testing.T) {
      op, calls, fired := recordingOp()

      paths := map[PathName]PathStatus{
         "normalized": Ready,
      }

      ops := map[StageName]map[StageState]func(context.Context) error{
         "scale-and-egress": {
            Running: op,
         },
      }

      c := newTestController(t, paths, ops, nil, egressRoutes)

      // Phase 1: the prerequisite passes, so this records
      // scale-and-egress.Desired = running. The launcher has not run yet.
      err := c.handleControl(ControlCommand{
         Component: "scale-and-egress",
         Action:    "start",
      })

      if err != nil {
         t.Fatalf("handleControl returned unexpected error: %v", err)
      }

      if got := c.stages["scale-and-egress"].Status.Desired; got != Running {
         t.Fatalf("scale-and-egress Desired = %q after control; want %q", got, Running)
      }

      if n := atomic.LoadInt32(calls); n != 0 {
         t.Fatalf("scale-and-egress launcher ran during handleControl; want it deferred to reconcile (got %d calls)", n)
      }

      // Phase 2: converge and confirm the launcher fired exactly once.
      c.handleReconcile()
      awaitFire(t, fired)

      if n := atomic.LoadInt32(calls); n != 1 {
         t.Fatalf("scale-and-egress launcher called %d times; want 1", n)
      }
   })

   t.Run("prerequisites not satisfied", func(t *testing.T) {
      op, _, fired := recordingOp()

      paths := map[PathName]PathStatus{
         "normalized": Unknown,
      }

      ops := map[StageName]map[StageState]func(context.Context) error{
         "scale-and-egress": {
            Running: op,
         },
      }

      c := newTestController(t, paths, ops, nil, egressRoutes)

      // The prerequisite fails, so handleControl returns an error and leaves
      // scale-and-egress.Desired at its seeded "stopped" value.
      err := c.handleControl(ControlCommand{
         Component: "scale-and-egress",
         Action:    "start",
      })

      if err == nil {
         t.Fatal("handleControl - expected error, received nil")
      }

      if got := c.stages["scale-and-egress"].Status.Desired; got != Stopped {
         t.Fatalf("scale-and-egress Desired = %q after rejected control; want %q", got, Stopped)
      }

      // A reconcile here is a no-op guard: because Desired was never advanced to
      // running, Actual already matches Desired for every stage and no op runs.
      // This proves a rejected command leaves the system inert even across a
      // reconcile tick.
      c.handleReconcile()
      expectNoFire(t, fired, 100*time.Millisecond)
   })
}
