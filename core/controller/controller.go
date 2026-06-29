package main

import (
   "context"
   "errors"
   "fmt"
   "iter"
   "log"
   "maps"
   "sync"
   "time"
)

type PathName string
type StageName string

type PathStatus string
const (
   Unknown  PathStatus = "unknown"
   Ready    PathStatus = "ready"
   NotReady PathStatus = "not-ready"
)

type StageState string
const (
   Running  StageState = "running"
   Stopped  StageState = "stopped"
   NoTarget StageState = ""
)

type ControlComponent string
type ControlAction    string


type StageStatus struct {
   Desired  StageState `json:"desired"`
   Actual   StageState `json:"actual"`
}

type Stage struct {
   Status         StageStatus
   Ops            map[StageState]func(context.Context) error
   InFlightSince  time.Time // zero value == not in flight
}

type ControllerStatus struct {
   Paths    map[PathName]PathStatus    `json:"paths"`
   Stages   map[StageName]StageStatus  `json:"stages"`
}

type PathEvent struct {
   Path     PathName    `json:"path"`
   Status   PathStatus  `json:"status"`
}

type StageEvent struct {
   Stage    StageName   `json:"stage"`
   State    StageState  `json:"state"`
}

type ControlCommand struct {
   Component   ControlComponent `json:"component"`
   Action      ControlAction    `json:"action"`
}

type StageTarget struct {
   Stage          StageName
   State          StageState
   Prerequisite   func(c *Controller) error
}

type ControllerListener func(*ControllerStatus)

func concat[V any](seqs ...iter.Seq[V]) iter.Seq[V] {
    return func(yield func(V) bool) {
        for _, s := range seqs { for v := range s { if !yield(v) { return } } }
    }
}

func (s *Stage) InFlight() bool { return !s.InFlightSince.IsZero() }

func (s PathStatus) Valid() bool {
   switch s { case Unknown, Ready, NotReady: return true }
   return false
}

func (s StageState) Valid() bool {
   switch s { case Running, Stopped: return true }
   return false
}

type Controller struct {
   ctx               context.Context
   paths             map[PathName]PathStatus
   stages            map[StageName]*Stage
   pathEventRoutes   map[PathEvent]StageTarget
   commandRoutes     map[ControlCommand]StageTarget
   listeners         []*ControllerListener
   now               func() time.Time
   inflightTimeout   time.Duration
   actions           chan func(*Controller)
   ops               sync.WaitGroup
}

func NewController(
   ctx               context.Context,
   paths             map[PathName]PathStatus,
   stages            map[StageName]*Stage,
   pathEventRoutes   map[PathEvent]StageTarget,
   commandRoutes     map[ControlCommand]StageTarget,
   now               func() time.Time,
   inflightTimeout   time.Duration,
   actionsBufferSize uint8,
) (*Controller, error) {

   var errs []error

   if ctx == nil { errs = append(errs, fmt.Errorf("controller.ctx must not be nil")) }

   for name, status := range paths {
      if !status.Valid() {
          errs = append(errs, fmt.Errorf("path %q seeded with invalid status %q", name, status))
      }
   }

   for name, stage := range stages {
      if stage.InFlight() {
         errs = append(errs, fmt.Errorf("stage %q seeded as InFlight", name))
      }
      if !stage.Status.Desired.Valid() {
         errs = append(errs, fmt.Errorf("stage %q seeded with invalid desired state %q", name, stage.Status.Desired))
      }
      if !stage.Status.Actual.Valid() {
         errs = append(errs, fmt.Errorf("stage %q seeded with invalid actual state %q", name, stage.Status.Actual))
      }
   }

   for pathEvent := range pathEventRoutes {
      if _, ok := paths[pathEvent.Path]; !ok {
          errs = append(errs, fmt.Errorf("path event route references unknown path %q", pathEvent.Path))
      }
      if !pathEvent.Status.Valid() {
          errs = append(errs, fmt.Errorf("path event route has invalid status: %+v", pathEvent))
      }
   }

   for target := range concat(
      maps.Values(pathEventRoutes),
      maps.Values(commandRoutes),
   ) {
      if stages[target.Stage] == nil {
          errs = append(errs, fmt.Errorf("route targets unknown stage %q", target.Stage))
          continue
      }
      if stages[target.Stage].Ops[target.State] == nil {
          errs = append(errs, fmt.Errorf("no op for stage %q state %q", target.Stage, target.State))
      }
   }

   if now == nil { errs = append(errs, fmt.Errorf("controller.now must not be nil")) }

   if inflightTimeout <= 0 {
      errs = append(errs, fmt.Errorf("inflight timeout must be > 0, got %v", inflightTimeout))
   }

   if len(errs) > 0 { return nil, errors.Join(errs...) }

   actions     := make(chan func(*Controller), actionsBufferSize)
   listeners   := make([]*ControllerListener, 0, 1)

   return &Controller{
      ctx: ctx, paths: paths, stages: stages, listeners: listeners,
      pathEventRoutes: pathEventRoutes, commandRoutes: commandRoutes,
      now: now, inflightTimeout: inflightTimeout, actions: actions,
   }, nil
}

func (c *Controller) Run() {
   for act := range c.actions { act(c) }
}

func submit[T any](c *Controller, fn func(*Controller) T) T {
   reply := make(chan T, 1)
   c.actions <- func(c *Controller) { reply <- fn(c) }
   return <-reply
}

func (c *Controller) SubmitPathEvent(e PathEvent) error {
   return submit(c, func(c *Controller) error { return c.handlePathEvent(e) })
}

func (c *Controller) SubmitStageEvent(e StageEvent) error {
   return submit(c, func(c *Controller) error { return c.handleStageEvent(e) })
}

func (c *Controller) SubmitControl(cmd ControlCommand) error {
   return submit(c, func(c *Controller) error { return c.handleControl(cmd) })
}

func (c *Controller) SubmitAddListener(l *ControllerListener) error {
   return submit(c, func(c *Controller) error { return c.handleAddListener(l) })
}

func (c *Controller) SubmitRemoveListener(l *ControllerListener) error {
   return submit(c, func(c *Controller) error { return c.handleRemoveListener(l) })
}

func (c *Controller) Status() *ControllerStatus {
   return submit(c, (*Controller).handleStatus)
}

func (c *Controller) RequestReconcile() {
   c.actions <- func(c *Controller) { c.handleReconcile() }
}

func (c *Controller) handleControl(cmd ControlCommand) error {
   log.Printf("controlCommand %+v", cmd)
   target, ok := c.commandRoutes[cmd]
   if !ok { return fmt.Errorf("control not implemented: %+v", cmd) }
   return c.applyDesiredStageTarget(target)
}

func (c *Controller) handlePathEvent(e PathEvent) error {
   _, ok := c.paths[e.Path]
   if !ok { return fmt.Errorf("invalid path name: %+v", e) }
   if !e.Status.Valid() { return fmt.Errorf("invalid path status: %+v", e) }

   log.Printf("path event %+v", e)

   c.paths[e.Path] = e.Status
   target, ok := c.pathEventRoutes[e]
   if !ok { return nil }
   return c.applyDesiredStageTarget(target)
}

func (c *Controller) handleStageEvent(e StageEvent) error {
   stage, ok := c.stages[e.Stage]
   if !ok { return fmt.Errorf("invalid stage name: %+v", e) }
   if !e.State.Valid() { return fmt.Errorf("invalid stage state: %+v", e) }

   log.Printf("stage event %+v", e)

   changed := stage.Status.Actual != e.State
   stage.Status.Actual = e.State
   stage.InFlightSince = time.Time{}
   if changed { c.notifyListeners() }
   return nil
}

func (c *Controller) handleAddListener(l *ControllerListener) error {
   if l == nil { return fmt.Errorf("listener must not be nil") }
   c.listeners = append(c.listeners, l)
   f := *l; f(c.handleStatus()); return nil
}

func (c *Controller) handleRemoveListener(l *ControllerListener) error {
   for i, existing := range c.listeners {
      if existing == l { c.listeners = append(c.listeners[:i], c.listeners[i+1:]...); return nil }
   }
   return fmt.Errorf("listener not registered")
}

func (c *Controller) notifyListeners() {
   if len(c.listeners) == 0 { return }
   controllerStatus := c.handleStatus()
   for _, l := range c.listeners { f := *l; f(controllerStatus) }
}

func (c *Controller) applyDesiredStageTarget(target StageTarget) error {
   stage := c.stages[target.Stage]
   if stage.Status.Desired == target.State {
      log.Printf("stage %q already desired %q", target.Stage, target.State)
      return nil
   }

   var err error
   if target.Prerequisite != nil { err = target.Prerequisite(c) }
   if err != nil {
      return fmt.Errorf("cannot set stage %q desired state to %q, prerequisite not satisfied: %w", target.Stage, target.State, err)
   }

   stage.Status.Desired = target.State
   c.notifyListeners()
   return nil
}

func (c *Controller) handleReconcile() {

   for name, stage := range c.stages {

      converged := stage.Status.Desired == stage.Status.Actual
      if converged { stage.InFlightSince = time.Time{}; continue }

      target, timedOut := c.planReconcile(stage)
      if target == NoTarget { continue }
      if timedOut { log.Printf("reconcile %q -> %q timed out", name, stage.Status.Desired) }

      operation, ok := stage.Ops[target]
      if !ok { log.Printf("reconcile %q: no op registered for %q", name, target); continue }

      operationCtx, cancel := context.WithTimeout(context.WithoutCancel(c.ctx), c.inflightTimeout)
      stage.InFlightSince = c.now()
      c.ops.Add(1)
      go func() {
         defer c.ops.Done()
         defer cancel()
         err := operation(operationCtx)
         if err != nil {
            log.Printf("reconcile %q -> %q failed: %v", name, target, err)
            c.actions <- func(c *Controller) { c.stages[name].InFlightSince = time.Time{} }
         }
      }()
   }
}

func (c *Controller) planReconcile(stage *Stage) (target StageState, timedOut bool) {
   if !stage.InFlight() { return stage.Status.Desired, false }
   if c.now().Sub(stage.InFlightSince) < c.inflightTimeout { return NoTarget, false }
   return stage.Status.Desired, true
}

func (c *Controller) handleStatus() *ControllerStatus {
   outPaths := maps.Clone(c.paths)
   outStages := make(map[StageName]StageStatus, len(c.stages))
   for name, stage := range c.stages { outStages[name] = stage.Status }
   return &ControllerStatus{ Paths: outPaths, Stages: outStages }
}

func (c *Controller) WaitForOps() { c.ops.Wait() }

func (c *Controller) Teardown() {
   submit(c, func(c *Controller) struct{} {
      base := context.WithoutCancel(c.ctx) // survives the signal
      for name, stage := range c.stages {
         if stage.Status.Actual != Running { continue }
         stop, ok := stage.Ops[Stopped]
         if !ok { continue }
         opCtx, cancel := context.WithTimeout(base, c.inflightTimeout)
         err := stop(opCtx)
         if err != nil { log.Printf("shutdown: stopping %q failed: %v", name, err) }
         cancel()
         stage.Status.Desired, stage.Status.Actual = Stopped, Stopped
         stage.InFlightSince = time.Time{}
      }
      c.notifyListeners()
      return struct{}{}
   })
}

func (c *Controller) Close() { close(c.actions) }
