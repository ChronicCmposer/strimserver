package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"
)

func main() {

	// actuator := nil

	paths := map[PathName]PathStatus { "ingress0": Unknown, "normalized": Unknown, }
	stages := map[StageName]*Stage {
		"normalize": {
			Status: StageStatus{ Desired: Stopped, Actual: Stopped, },
			Ops: map[StageState]func() error{
				Running: func() error { fmt.Println("launched normalize stage"); return nil },
				Stopped: func() error { fmt.Println("terminated normalize stage"); return nil },
			},
		},
		"scale-and-egress": {
			Status: StageStatus{ Desired: Stopped, Actual: Stopped, },
			Ops: map[StageState]func() error{
				Running:	func() error { fmt.Println("launched scale-and-egress stage"); return nil },
				Stopped: func() error { fmt.Println("terminated scale-and-egress stage"); return nil },
			},
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

	mux.HandleFunc("/event", postJSON(controller, (*Controller).HandleEvent))

	mux.HandleFunc("/control", postJSON(controller, (*Controller).HandleControl))

	mux.HandleFunc("/status", getJSON(controller, (*Controller).HandleStatus))

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

	addr := env("STRIMSERVER_CONTROLLER_ADDR", "127.0.0.1:9177")
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

		err = submit(c, func(c *Controller) error { return handle(c, message) } )
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

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

		err := json.NewEncoder(w).Encode(submit(c, handle))
		if err != nil {
			log.Printf("json serialization error: %v", err)
		}
	}
}

func submit[T any](c *Controller, fn func(*Controller) T) T {
	reply := make(chan T, 1)
	c.actions <- func(c *Controller) { reply <- fn(c) }
	return <-reply
}

func invokeReconcileEvery(c *Controller, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for range ticker.C {
		err := submit(c, (*Controller).HandleReconcile)
		if err != nil {
			log.Printf("reconcile error: %v", err)
		}
	}
}

func env(name, fallback string) string {
	v := os.Getenv(name)
	if v == "" {
		return fallback
	}
	return v
}

