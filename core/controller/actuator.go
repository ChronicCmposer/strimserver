package main

import (
	"context"
	"errors"
	"fmt"
	"time"
)

type CommandRunner interface {
	Run(ctx context.Context, argv []string) error
}

type Command struct {
	Argv    []string
	Timeout time.Duration
}

type StageCommands struct {
	Start []Command // ordered launch commands; run fail-fast
	Stop  []Command // ordered teardown commands; run best-effort, ErrContainerNotFound benign
}

type Actuator struct { 
	context 			context.Context
	runner 			CommandRunner	
	commands			map[StageName]StageCommands
	defaultTimeout	time.Duration
}

func NewActuator(
	context 			context.Context, 
	runner 			CommandRunner, 
	commands 		map[StageName]StageCommands, 
	defaultTimeout time.Duration,
) (*Actuator, error) {

	var errs []error

	if context == nil {
		errs = append(errs, fmt.Errorf("error constructing actuator, context is nil"))
	}

	if runner == nil {
		errs = append(errs, fmt.Errorf("error constructing actuator, runner is nil"))
	}

	if defaultTimeout <= 0 {
		errs = append(errs, fmt.Errorf("error constructing actuator, defaultTimeout is not positive"))
	}

	for name, c := range commands {
		startCommands := c.Start
		if len(startCommands) == 0 {
			errs = append(errs, fmt.Errorf("error constructing actuator, stage %q has 0 start commands", name))
		} 
	}
	
	if len(errs) > 0 {
		return nil, errors.Join(errs...)
	}	

	return &Actuator{
		context: context,
		runner: runner,
		commands: commands,
		defaultTimeout: defaultTimeout,
	}, nil
}

func (a *Actuator) StartOp(stage StageName) func() error {
	return func() error { 
		for _, cmd := range a.commands[stage].Start {
			timeout := cmd.Timeout
			if cmd.Timeout <= 0 {
				timeout = a.defaultTimeout
			}
			startOpContext, cancel := context.WithTimeout(a.context, timeout)
			defer cancel()
			err := a.runner.Run(startOpContext, cmd.Argv)
			if err != nil {
				return fmt.Errorf("could not start stage %q: %w", stage, err)
			}
		}
		return nil
	}
}

func (a *Actuator) StopOp(stage StageName) func() error {
	return func() error { 

		var errs []error

		for _, cmd := range a.commands[stage].Stop {
			timeout := cmd.Timeout
			if cmd.Timeout <= 0 {
				timeout = a.defaultTimeout
			}
			stopOpContext, cancel := context.WithTimeout(a.context, timeout)
			defer cancel()
			err := a.runner.Run(stopOpContext, cmd.Argv)
			if err != nil {
				errs = append(errs, fmt.Errorf("could not stop stage %q: %w", stage, err))
			}
		}

		if len(errs) > 0 {
			return errors.Join(errs...)
		}

		return nil
	}
}

func (a *Actuator) Ops(stage StageName) map[StageState]func() error {
	return map[StageState]func() error {
		Running: a.StartOp(stage),
		Stopped: a.StopOp(stage),
	}
}

