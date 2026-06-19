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
	defaultTimeout time.Duration,
	commands 		map[StageName]StageCommands, 
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
		if len(c.Start) == 0 {
			errs = append(errs, fmt.Errorf("error constructing actuator, stage %q has 0 start commands", name))
		} 
	}
	
	if len(errs) > 0 {
		return nil, errors.Join(errs...)
	}	

	return &Actuator{
		context: context,
		runner: runner,
		defaultTimeout: defaultTimeout,
		commands: commands,
	}, nil
}

func (a *Actuator) runCommand(cmd Command) error {
	timeout := cmd.Timeout
	if timeout <= 0 {
		 timeout = a.defaultTimeout
	}
	ctx, cancel := context.WithTimeout(a.context, timeout)
	defer cancel()
	return a.runner.Run(ctx, cmd.Argv)
}

func (a *Actuator) StartOp(stage StageName) func() error {
	return func() error { 
		for _, cmd := range a.commands[stage].Start {
			err := a.runCommand(cmd)
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
			err := a.runCommand(cmd)
			if err != nil {
				errs = append(errs, fmt.Errorf("could not stop stage %q: %w", stage, err))
			}
		}

		// nil if no errors
		return errors.Join(errs...)
	}
}

func (a *Actuator) Ops(stage StageName) map[StageState]func() error {
	return map[StageState]func() error {
		Running: a.StartOp(stage),
		Stopped: a.StopOp(stage),
	}
}

