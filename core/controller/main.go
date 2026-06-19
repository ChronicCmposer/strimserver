package main

import (
	"cmp"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"
)

type CommandRunnerFunc func(context.Context, []string) error 

func (r CommandRunnerFunc) Run(ctx context.Context, argv []string) error { return r(ctx,argv) } 

func main() {

	rootContext := context.Background()

	var runner CommandRunner = CommandRunnerFunc(func(_ context.Context, argv []string) error {
		fmt.Printf("running command: %v\n", argv); return nil
	})
	
	defaultCommandTimeout := 5 * time.Second

	commands := map[StageName]StageCommands{
		"normalize": {
			Start: 	[]Command{{ Argv: []string{"/usr/bin/echo", "normalize is running" }}},
			Stop: 	[]Command{{ Argv: []string{"/usr/bin/echo", "normalize is stopped" }}},
		},
		"scale-and-egress": {
			Start: 	[]Command{{ Argv: []string{"/usr/bin/echo", "scale-and-egress is running" }}},
			Stop: 	[]Command{{ Argv: []string{"/usr/bin/echo", "scale-and-egress is stopped" }}},
		},
	}

	actuator, err := NewActuator(rootContext, runner, defaultCommandTimeout, commands)

	if err != nil {
		log.Fatalf("error constructing actuator: %v", err)
	}

	paths := map[PathName]PathStatus { "ingress0": Unknown, "normalized": Unknown, }

	stages := map[StageName]*Stage{
		"normalize": {
			Status: StageStatus{ Desired: Stopped, Actual: Stopped},
			Ops: actuator.Ops("normalize"),
		},
		"scale-and-egress": {
			Status: StageStatus{ Desired: Stopped, Actual: Stopped},
			Ops: actuator.Ops("scale-and-egress"),
		},

	}
	eventRoutes := map[Event]StageTarget {
		{ Path: "ingress0", Status: Ready }: 			{ Stage: "normalize", State: Running },
		{ Path: "ingress0", Status: NotReady }: 		{ Stage: "normalize", State: Stopped },
		{ Path: "normalized", Status: Ready }: 		{ Stage: "scale-and-egress", State: Running },
		{ Path: "normalized", Status: NotReady }: 	{ Stage: "scale-and-egress", State: Stopped },
	}	
	commandRoutes := map[ControlCommand]StageTarget {
		{ Component: "scale-and-egress", Action: "start" }: { Stage: "scale-and-egress", State: Running,
			Prerequisite: func(c *Controller) error {
				if c.paths["normalized"] != Ready {
					return fmt.Errorf("normalize path is not ready")
				}
				return nil
			}, 
		},
		{ Component: "scale-and-egress", Action: "stop" }: { Stage: "scale-and-egress", State: Stopped },
	}	

	controller, err := NewController(paths, stages, eventRoutes, commandRoutes)

	if err != nil {
		log.Fatalf("error constructing controller: %v", err)
	}

   log.Printf("%+v", controller)

	mux := http.NewServeMux()

	mux.HandleFunc("/event", postJSON(controller, (*Controller).SubmitEvent))

	mux.HandleFunc("/control", postJSON(controller, (*Controller).SubmitControl))

	mux.HandleFunc("/status", getJSON(controller, (*Controller).Status))

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, err = w.Write([]byte("ok\n"))
		if err != nil {
			log.Printf("healthz endpoint error: %+v", err.Error())
		}
	})

	// Start the controller loop
	go controller.run()

	// Start the reconcile loop
	go invokeReconcileEvery(controller, 5 * time.Second)

	addr := cmp.Or(os.Getenv("STRIMSERVER_CONTROLLER_ADDR"), "127.0.0.1:9177")
	log.Printf("controller listening on %s", addr)

	err = http.ListenAndServe(addr, mux)
	if err != nil {
		log.Fatal(err)
	}

}

func postJSON[T any](c *Controller, handle func(*Controller, T) error) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {

		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		var message T
		err := json.NewDecoder(r.Body).Decode(&message)
		if err != nil {
			http.Error(w, fmt.Sprintf("bad json: %v", err), http.StatusBadRequest)
			return
		}

		err = handle(c, message) 
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		c.RequestReconcile()
		w.WriteHeader(http.StatusNoContent)
	}
}

func getJSON[T any](c *Controller, handle func(*Controller) T) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {

		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		w.Header().Set("Content-Type", "application/json")

		err := json.NewEncoder(w).Encode(handle(c))
		if err != nil {
			log.Printf("json serialization error: %v", err)
		}
	}
}

func invokeReconcileEvery(c *Controller, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for range ticker.C { c.RequestReconcile() }
}

