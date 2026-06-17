package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"fmt"
)

func main() {
	paths  := map[Path]PathStatus {
		"ingress0": "unknown", "normalized": "unknown",
	}
	stages := map[Stage]*StageStatus {
		"normalize": 			{ Desired: "stopped", Actual: "stopped", },
		"scale-and-egress": 	{ Desired: "stopped", Actual: "stopped", },
	}
	ops := map[Stage]map[StageState]func() error {
		"normalize": {
			Running: func() error { fmt.Println("launched normalize stage"); return nil }, 
			Stopped: func() error { fmt.Println("terminated normalize stage"); return nil },
		},
		"scale-and-egress": {
			Running:	func() error { fmt.Println("launched scale-and-egress stage"); return nil },
			Stopped: func() error { fmt.Println("terminated scale-and-egress stage"); return nil },
		},
	}
	eventRoutes 	:= map[EventKey]StageTarget {
		{ "ingress0", "ready" }: 			{ "normalize", Running, nil }, 
		{ "ingress0", "not-ready" }: 		{ "normalize", Stopped, nil }, 
		{ "normalized", "ready" }: 		{ "scale-and-egress", Running, nil }, 
		{ "normalized", "not-ready" }: 	{ "scale-and-egress", Stopped, nil }, 
	}	
	commandRoutes 	:= map[ControlCommandKey]StageTarget {
		{ "scale-and-egress", "start" }: 	{ 
			"scale-and-egress", 
			Running, 
			func(c *Controller) error {
				if c.paths["normalized"] != "ready" {
					return fmt.Errorf("normalize path is not ready")
				}
				return nil
			}, 
		},
		{ "scale-and-egress", "stop" }: 	{ "scale-and-egress", Stopped, nil },
	}	

	controller := NewController(
		paths, 
		stages, 
		ops,
		eventRoutes,
		commandRoutes,
	)

   log.Printf("%+v", controller)


	mux := http.NewServeMux()

	mux.HandleFunc("/event", postJSON(
			controller.events, 
			func(e *Event, reply chan error) { e.Reply = reply },
		),
	)

	mux.HandleFunc("/control", postJSON(
			controller.controlCommands, 
			func(c *ControlCommand, reply chan error) { c.Reply = reply },
		),
	)

	mux.HandleFunc("/status", func(w http.ResponseWriter, r *http.Request) {
				
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		sr := StatusRequest{
			Reply: make(chan ControllerStatus),
		}

		controller.statusRequests <- sr
		controllerStatus := <-sr.Reply

		
		w.Header().Set("Content-Type", "application/json")
		err := json.NewEncoder(w).Encode(controllerStatus)
		if err != nil {
			log.Printf("status endpoint error: %+v", err.Error())	
		}

	})

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, err := w.Write([]byte("ok\n"))
		if err != nil {
			log.Printf("healthz endpoint error: %+v", err.Error())
		}
	})

	// Start the controller loop
	go controller.run()

	addr := env("STRIMSERVER_CONTROLLER_ADDR", "127.0.0.1:9177")
	log.Printf("controller listening on %s", addr)

	err := http.ListenAndServe(addr, mux)
	if err != nil {
		log.Fatal(err)
	}

}

func postJSON[T any](toController chan<- T, setReplyChannel func(*T, chan error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {

		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		var message T
		err := json.NewDecoder(r.Body).Decode(&message)
		if err != nil {
			http.Error(w, "bad json", http.StatusBadRequest)
			return
		}

		fromController := make(chan error)
		setReplyChannel(&message, fromController)
		toController <- message

		err = <-fromController
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}

		w.WriteHeader(http.StatusNoContent)
	}
}

func env(name, fallback string) string {
	v := os.Getenv(name)
	if v == "" {
		return fallback
	}
	return v
}


// TODO: write this better - DankReading, consider Strategy pattern
// func (c *Controller) reconcileLocked() error {
// 	for stageName, desired := range c.desired {
// 		stage := c.stages[stageName]
//
// 		if desired == "running" {
// 			if !containerExists(stage.ContainerName) {
// 				if err := c.startStage(stage); err != nil {
// 					return err
// 				}
// 			}
// 		} else { // "stopped"
// 			if containerExists(stage.ContainerName) {
//             if err := stopStage(stage); err != nil { // TODO: is this a bug ? need a controller reference ?
// 					return err
// 				}
// 			}
// 		}
// 	}
// 	return nil
// }

// TODO: are all cases handled ? what error codes do we expect ?
// TODO: rename to stageIsRunning
// func containerExists(name string) bool {
// 	cmd := exec.Command("ctr", "containers", "info", name)
// 	return cmd.Run() == nil
// }

// func ignoreRun(args ...string) {
// 	cmd := exec.Command(args[0], args[1:]...)
//    _ = cmd.Run() // TODO: sus
// }

// func stopStage(stage Stage) error {
// 	log.Printf("stopping stage=%s container=%s", stage.Name, stage.ContainerName)
//
// 	ignoreRun("ctr", "tasks", "kill", "--signal", "SIGTERM", stage.ContainerName)
//    time.Sleep(300 * time.Millisecond) // TODO: make this not hardcoded
// 	ignoreRun("ctr", "tasks", "kill", "--signal", "SIGKILL", stage.ContainerName)
// 	ignoreRun("ctr", "containers", "delete", stage.ContainerName)
//
// 	return nil
// }

// TODO: remove controller implicit argument - inject the image name a different way
// func (c *Controller) startStage(stage Stage) error {
// 	log.Printf("starting stage=%s container=%s", stage.Name, stage.ContainerName)
//
// 	_ = stopStage(stage)
//
// 	args := []string{
//       "ctr",
// 		"run",
// 		"--net-host",
// 		"--gpus", "0",
// 		"--cap-add", "CAP_SYS_NICE",
//
//       // TODO: is there a smarter way to inject this configuration ?
// 		"--mount", "type=bind,src=/mnt/nvme/config/strimserver.env,dst=/opt/strimserver/config/strimserver.env,options=rbind:ro",
// 		"--mount", "type=bind,src=/mnt/nvme/runtime,dst=/opt/strimserver/runtime,options=rbind:rw",
// 		"--mount", "type=bind,src=/mnt/nvme/logs,dst=/opt/strimserver/logs,options=rbind:rw",
//
//       c.image, // TODO: inject this in a smarter way
// 		stage.ContainerName,
// 	}
//
// 	args = append(args, stage.Command...)
//
//    cmd := exec.Command(args[0], args[1:]...) // TODO: confirm that this subprocess detaches from tty ?
// 	out, err := cmd.CombinedOutput()
// 	if err != nil {
// 		return fmt.Errorf("ctr run failed for %s: %w: %s", stage.Name, err, string(out))
// 	}
//
// 	return nil
// }
