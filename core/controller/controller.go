package main

import (
	"errors"
	"fmt"
	"iter"
	"log"
	"maps"
)

type PathName string
type StageName string

type PathStatus string 
const (
	Unknown  PathStatus = "unknown"
	Ready		PathStatus = "ready"
	NotReady	PathStatus = "not-ready"
)

type StageState string 
const (
	Running StageState = "running"
	Stopped StageState = "stopped"
)


type StageStatus struct {
	Desired	StageState `json:"desired"`
	Actual	StageState `json:"actual"`
}

type Stage struct {
	Status 	StageStatus
	Ops		map[StageState]func() error
	InFlight	bool
}

type ControllerStatus struct {
	Paths 	map[PathName]PathStatus		`json:"paths"`
	Stages	map[StageName]StageStatus 	`json:"stages"`
}

type Event struct {
	Path 		PathName 	`json:"path"`
	Status 	PathStatus 	`json:"status"`
}

type ControlCommand struct {
	Component 	string `json:"component"`
	Action 		string `json:"action"`
}

type StageTarget struct {
	Stage				StageName
	State				StageState
	Prerequisite	func(c *Controller) error
}

type Controller struct {
	paths 			map[PathName]PathStatus
	stages			map[StageName]*Stage
	eventRoutes		map[Event]StageTarget
	commandRoutes	map[ControlCommand]StageTarget
	actions 			chan func(*Controller)
}

func concat[V any](seqs ...iter.Seq[V]) iter.Seq[V] {
    return func(yield func(V) bool) {
        for _, s := range seqs { for v := range s { if !yield(v) { return } } }
    }
}

func (s PathStatus) Valid() bool {
	switch s { case Unknown, Ready, NotReady: return true }
	return false
}

func NewController(
	paths 			map[PathName]PathStatus,
	stages 			map[StageName]*Stage,
	eventRoutes		map[Event]StageTarget,
	commandRoutes	map[ControlCommand]StageTarget,
) (*Controller, error) {

	var errs []error

   for target := range concat(maps.Values(eventRoutes), maps.Values(commandRoutes)) {
      if stages[target.Stage] == nil {
          errs = append(errs, fmt.Errorf("route targets unknown stage %q", target.Stage))
			 continue
      }
      if stages[target.Stage].Ops[target.State] == nil {
          errs = append(errs, fmt.Errorf("no op for stage %q state %q", target.Stage, target.State))
      }
   }

	for status := range maps.Values(paths) {
		 if !status.Valid() {
			  errs = append(errs, fmt.Errorf("path seeded with invalid status %q", status))
		 }
	}
	for ev := range maps.Keys(eventRoutes) {
		 if _, ok := paths[ev.Path]; !ok {
			  errs = append(errs, fmt.Errorf("event route references unknown path %q", ev.Path))
		 }
		 if !ev.Status.Valid() {
			  errs = append(errs, fmt.Errorf("event route %+v has invalid status", ev))
		 }
	}
	
	if len(errs) > 0 { return nil, errors.Join(errs...) }

	return &Controller{
		paths: paths,
		stages: stages,
		eventRoutes: eventRoutes,
		commandRoutes: commandRoutes,
		actions: make(chan func(*Controller), 64),
	}, nil
}

func (c *Controller) run() {
	for act := range c.actions { act(c) }
}

func submit[T any](c *Controller, fn func(*Controller) T) T {
	reply := make(chan T, 1)
	c.actions <- func(c *Controller) { reply <- fn(c) }
	return <-reply
}

func (c *Controller) SubmitEvent(e Event) error {
	return submit(c, func(c *Controller) error { return c.handleEvent(e) })
}

func (c *Controller) SubmitControl(cmd ControlCommand) error {
	return submit(c, func(c *Controller) error { return c.handleControl(cmd) })
}

func (c *Controller) Status() ControllerStatus {
	return submit(c, (*Controller).handleStatus)
}

func (c *Controller) RequestReconcile() {
	c.actions <- func(c *Controller) { c.handleReconcile() }
}

func (c *Controller) handleControl(cmd ControlCommand) error {
	log.Printf("controlCommand %+v", cmd)
	target, ok := c.commandRoutes[cmd]
	if !ok { return fmt.Errorf("control not implemented: %+v", cmd) }
	return c.applyStageTarget(target)
}

func (c *Controller) handleEvent(e Event) error {
	_, ok := c.paths[e.Path]
	if !ok { return fmt.Errorf("invalid path: %+v", e) }
	if !e.Status.Valid() { return fmt.Errorf("invalid path status: %+v", e) }

	log.Printf("event %+v", e)

	c.paths[e.Path] = e.Status
	target, ok := c.eventRoutes[e]
	if !ok { return nil }
	return c.applyStageTarget(target)
}

func (c *Controller) applyStageTarget(target StageTarget) error {
	stage := c.stages[target.Stage]
	if stage.Status.Desired == target.State {
		log.Printf("stage %q already %q", target.Stage, target.State)
		return nil
	}

	var err error
	if target.Prerequisite != nil { err = target.Prerequisite(c) }
	if err != nil {
		return fmt.Errorf("cannot set stage %q to %q, prerequisite not satisfied: %w", target.Stage, target.State, err)
	}

	stage.Status.Desired = target.State
	return nil
}

func (c *Controller) handleReconcile() {
	for name, stage := range c.stages {
		if stage.Status.Actual == stage.Status.Desired || stage.InFlight {
			continue
		}
	  	stage.InFlight = true
	  	target := stage.Status.Desired
	  	operation := stage.Ops[target]

		// closes over loop variables per-iteration: name, stage, target
		go func() {
			err := operation()
			c.actions <- func(c *Controller) {
				c.stages[name].InFlight = false 
				if err != nil {
					log.Printf("reconcile %q->%q failed: %v", name, target, err)
					return
				}
				c.stages[name].Status.Actual = target 
			}
		}()
	}
}

func (c *Controller) handleStatus() ControllerStatus {
	outPaths := maps.Clone(c.paths)
	outStages := make(map[StageName]StageStatus, len(c.stages))
	for name, stage := range c.stages { outStages[name] = stage.Status }
	return ControllerStatus{ Paths: outPaths, Stages: outStages, }
}

