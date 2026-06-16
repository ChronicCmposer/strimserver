package main

import (
	"fmt"
	"log"
	"maps"
	"slices"
)

type Path string
type Stage string

type PathStatus string
type StageStatus struct {
	Desired	string `json:"desired"`
	Actual	string `json:"actual"`
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


type Controller struct {

	paths 	map[Path]PathStatus
	stages	map[Stage]*StageStatus

	events 				chan Event
	controlCommands 	chan ControlCommand
	statusRequests 	chan StatusRequest

	stageLaunchers 	map[Stage]func() error
	stageTerminators 	map[Stage]func() error

}


func NewController(
	paths 				map[Path]PathStatus,
	stages 				map[Stage]*StageStatus,
	stageLaunchers 	map[Stage]func() error,
	stageTerminators 	map[Stage]func() error,
) *Controller {
	return &Controller{
		paths: paths,
		stages: stages,
		events: make(chan Event),
		controlCommands: make(chan ControlCommand),
		statusRequests: make(chan StatusRequest),
		stageLaunchers: stageLaunchers,
		stageTerminators: stageTerminators,
	}
}

func (c *Controller) run() {
	for {
		select {
			case e := <-c.events:
				e.Reply <- c.HandleEvent(e)
			case cmd := <-c.controlCommands:
				cmd.Reply <- c.HandleControl(cmd)
			case sr := <-c.statusRequests:
				sr.Reply <- c.HandleStatus()

		}
	}
}

var validComponents 	= [...]string { "scale-and-egress", }
var validActions 		= [...]string { "start", "stop", }

var isValidComponent = func(component string) bool {
	return slices.Contains(validComponents[:], component)
}

var isValidAction = func(action string) bool {
	return slices.Contains(validActions[:], action)
}

func (c *Controller) HandleControl(cmd ControlCommand) error {

	if !isValidComponent(cmd.Component) || !isValidAction(cmd.Action) {
		return fmt.Errorf("invalid control command: +%v", cmd)
	}
	
	log.Printf("controlCommand component=%s action=%s", cmd.Component, cmd.Action)

	switch {
		case cmd.Component == "scale-and-egress" && cmd.Action == "start":
			c.stages["scale-and-egress"].Desired = "running"
			if c.stages["scale-and-egress"].Actual == "running" {
				log.Print("cannot start scale-and-egress stage, it is already running")
				return nil 
			}
			if c.paths["normalized"] != "ready" {
				return fmt.Errorf("cannot start scale-and-egress stage, normalize path not yet ready: %s", c.paths["normalize"])
			}
			err := c.stageLaunchers["scale-and-egress"]() 
			if err != nil {
				return fmt.Errorf("could not start scale-and-egress stage: %v", err)
			}
			c.stages["scale-and-egress"].Actual = "running"
			return nil

		case cmd.Component == "scale-and-egress" && cmd.Action == "stop":
			c.stages["scale-and-egress"].Desired = "stopped"
			if c.stages["scale-and-egress"].Actual != "running" {
				log.Print("cannot stop scale-and-egress stage, it is not running")
				return nil 
			}
			err := c.stageTerminators["scale-and-egress"]()
			if err != nil {
				return fmt.Errorf("could not stop scale-and-egress stage: %v", err)
			}
			c.stages["scale-and-egress"].Actual = "stopped"
			return nil

		default:
			return fmt.Errorf("control not implemented: %v", cmd)
	}
}


var validPaths = [...]string { "ingress0", "normalized", }

var validPathStatuses = [...]string { "ready", "not-ready", "unknown" }

var isValidPath = func(path string) bool {
	return slices.Contains(validPaths[:], path)
}

var isValidPathStatus = func(pathStatus string) bool {
	return slices.Contains(validPathStatuses[:], pathStatus)
}

func (c *Controller) HandleEvent(e Event) error {

	if !isValidPath(e.Path) || !isValidPathStatus(e.Status) {
		return fmt.Errorf("invalid event: %v", e)
	}

	path 		  := Path(e.Path)
	pathStatus := PathStatus(e.Status)

	log.Printf("event path=%s state=%s", e.Path, e.Status)
	c.paths[path] = pathStatus

	switch {
		case e.Path == "ingress0" && e.Status == "ready":

			c.stages["normalize"].Desired = "running"

			if c.stages["normalize"].Actual == "running" {
				log.Printf("normalize stage already running")
				return nil
			}

			err := c.stageLaunchers["normalize"]()
			if err != nil {
				return fmt.Errorf("error launching normalize stage: %v", err)
			}

			c.stages["normalize"].Actual = "running"
			return nil

		case e.Path == "ingress0" && e.Status == "not-ready":
			c.stages["normalize"].Desired = "stopped" 
			if c.stages["normalize"].Actual != "running" {
				log.Printf("normalize stage already not running")
				return nil
			}
			err := c.stageTerminators["normalize"]()
			if err != nil {
				return fmt.Errorf("error terminating normalize stage: %v", err)
			}

			c.stages["normalize"].Actual = "stopped"
			return nil

		case e.Path == "normalized" && e.Status == "ready":
			c.stages["scale-and-egress"].Desired = "running"
			if c.stages["scale-and-egress"].Actual == "running" {
				log.Printf("scale-and-egress stage already running")
				return nil
			}
			err := c.stageLaunchers["scale-and-egress"]()
			if err != nil {
				return fmt.Errorf("error launching scale-and-egres stage: %v", err)
			}
			c.stages["scale-and-egress"].Actual = "running"
			return nil

		case e.Path == "normalized" && e.Status == "not-ready":
			c.stages["scale-and-egress"].Desired = "stopped"
			if c.stages["scale-and-egress"].Actual != "running" {
				log.Printf("scale-and-egress stage already not running")
				return nil
			}
			err := c.stageTerminators["scale-and-egress"]()
			if err != nil {
				return fmt.Errorf("error terminating scale-and-egress stage: %v", err)
			}

			c.stages["scale-and-egress"].Actual = "stopped"
			return nil
		
		default:
			return fmt.Errorf("event not implemented: %v", e)
	}
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


