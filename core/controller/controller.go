package main

import (
	"fmt"
	"iter"
	"log"
	"maps"
	"slices"
)

type Path string
type Stage string

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

type ControllerStatus struct {
	Paths 	map[Path]PathStatus 		`json:"paths"`
	Stages	map[Stage]StageStatus 	`json:"stages"`
}

type StatusRequest struct {
	Reply 	chan ControllerStatus
}

type Event struct {
	Path  	string 		`json:"path"`
	Status 	string 		`json:"status"`
	Reply 	chan error
}

type ControlCommand struct {
	Component 	string `json:"component"`
	Action 		string `json:"action"`
	Reply			chan error
}

type EventKey struct {
	Path 		Path
	Status	PathStatus
}

type ControlCommandKey struct {
	Component	string
	Action		string
}

type StageTarget struct {
	Stage				Stage
	State				StageState
	Prerequisite	func(c *Controller) error
}

type Controller struct {

	paths 			map[Path]PathStatus
	stages			map[Stage]*StageStatus
	ops				map[Stage]map[StageState]func() error
	eventRoutes		map[EventKey]StageTarget
	commandRoutes	map[ControlCommandKey]StageTarget

	events 				chan Event
	controlCommands 	chan ControlCommand
	statusRequests 	chan StatusRequest

	validPathNames			[]string
	validStageNames		[]string
	validComponentNames 	[]string
	validActionNames		[]string

}

func components(keys iter.Seq[ControlCommandKey]) iter.Seq[string] {
	return func(yield func(string) bool) {
		for key := range keys { if !yield(key.Component) { return } }
	}
}

func actions(keys iter.Seq[ControlCommandKey]) iter.Seq[string] {
	return func(yield func(string) bool) {
		for key := range keys { if !yield(key.Action) { return } }
	}
}

func asStrings[T ~string](keys iter.Seq[T]) iter.Seq[string] {
	return func(yield func(string) bool) {
		for key := range keys { if !yield(string(key)) { return } }
	}
}

func oneOf[T comparable](allowed []T, v T) bool {
	return slices.Contains(allowed, v)
}

var validPathStatusNames = slices.Collect(asStrings(slices.Values([]PathStatus { Unknown, Ready, NotReady })))
// var validStageStateNames 	= slices.Collect(asStrings(slices.Values([]StageState { Running, Stopped })))

func NewController(
	paths 			map[Path]PathStatus,
	stages 			map[Stage]*StageStatus,
	ops				map[Stage]map[StageState]func() error,
	eventRoutes		map[EventKey]StageTarget,
	commandRoutes	map[ControlCommandKey]StageTarget,
) *Controller {
	return &Controller{
		paths: paths,
		stages: stages,
		ops:	ops,
		eventRoutes: eventRoutes,
		commandRoutes: commandRoutes,
		events: make(chan Event),
		controlCommands: make(chan ControlCommand),
		statusRequests: make(chan StatusRequest),
		validPathNames: slices.Collect(asStrings(maps.Keys(paths))),
		validStageNames: slices.Collect(asStrings(maps.Keys(stages))),
		validComponentNames: slices.Compact(slices.Sorted(components(maps.Keys(commandRoutes)))),
		validActionNames: slices.Compact(slices.Sorted(actions(maps.Keys(commandRoutes)))),
	}
}

func (c *Controller) run() {
	for {
		select {

			case e 	:= <-c.events:
				e.Reply 		<- c.HandleEvent(e)

			case cmd := <-c.controlCommands:
				cmd.Reply 	<- c.HandleControl(cmd)

			case sr 	:= <-c.statusRequests:
				sr.Reply 	<- c.HandleStatus()

		}
	}
}

// prerequisite is allowed to be nil 
func (c *Controller) setStage(
	s Stage, 
	target StageState, 
	action func() error, 
	prerequisite func(c *Controller) error,
) error {

	c.stages[s].Desired = target

	if c.stages[s].Actual == target {
		log.Printf("stage `%s` already %s", s, target)
		return nil
	}

	var err error
	if prerequisite != nil {
		err = prerequisite(c)
	}
	if err != nil {
		return fmt.Errorf("cannot set stage `%s` to %s, prerequisite not satisfied: %w", s, target, err)
	}

	err = action()
	if err != nil {
		return fmt.Errorf("cannot set stage `%s` to %s: %w", s, target, err)
	}

	c.stages[s].Actual = target
	return nil
}


func (c *Controller) HandleControl(cmd ControlCommand) error {

	if !oneOf(c.validComponentNames, cmd.Component) {
		return fmt.Errorf("invalid component: %+v", cmd)
	}

	if !oneOf(c.validActionNames, cmd.Action) {
		return fmt.Errorf("invalid action: %+v", cmd)
	}
	
	log.Printf("controlCommand component=%s action=%s", cmd.Component, cmd.Action)

	key := ControlCommandKey{cmd.Component, cmd.Action}
	target, ok := c.commandRoutes[key]

	if !ok {
		return fmt.Errorf("control not implemented: %+v", cmd)
	}

	return c.setStage(
		target.Stage, 
		target.State, 
		c.ops[target.Stage][target.State], 
		target.Prerequisite,
	)

}


func (c *Controller) HandleEvent(e Event) error {

	if !oneOf(c.validPathNames, e.Path) {
		return fmt.Errorf("invalid path: %+v", e)
	}

	if !oneOf(validPathStatusNames, e.Status) {
		return fmt.Errorf("invalid path status: %+v", e)
	}

	path 		  := Path(e.Path)
	pathStatus := PathStatus(e.Status)

	log.Printf("event path=%s state=%s", e.Path, e.Status)

	c.paths[path] = pathStatus

	key := EventKey{path, pathStatus}
	target, ok := c.eventRoutes[key]

	if !ok {
		return fmt.Errorf("event not implemented: %+v", e)
	}

	return c.setStage(
		target.Stage, 
		target.State, 
		c.ops[target.Stage][target.State], 
		target.Prerequisite,
	)

}

func (c *Controller) HandleStatus() ControllerStatus {
	outPaths := maps.Clone(c.paths)
	outStages := make(map[Stage]StageStatus, len(c.stages))
	for name, stageStatus := range c.stages {
		outStages[name] = *stageStatus
	}
	return ControllerStatus{
		Paths: 	outPaths,
		Stages: 	outStages,
	}
}


