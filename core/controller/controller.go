// strim-controller.go
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"sync"
	"time"
)

type Event struct {
	Path  string `json:"path"`
	State string `json:"state"`
}

type Stage struct {
	Name          string
	ContainerName string
   Command       []string
}

type Controller struct {
	mu sync.Mutex

	paths map[string]string
	desired map[string]string
	stages map[string]Stage

	image string
}

func env(name, fallback string) string {
	v := os.Getenv(name)
	if v == "" {
		return fallback
	}
	return v
}

func NewController() *Controller {
	return &Controller{
		paths: map[string]string{
			"ingress0":   "unknown",
			"normalized": "unknown",
		},
		desired: map[string]string{
			"normalize":        "stopped",
			"scale-and-egress": "stopped",
		},
		stages: map[string]Stage{
			"normalize": {
				Name:          "normalize",
				ContainerName: "strimserver-ffmpeg-normalize", //TODO: Do I need this ?
				Command:       []string{"/opt/strimserver/bin/run-ffmpeg-stage", "normalize"},
			},
			"scale-and-egress": {
				Name:          "scale-and-egress",
            ContainerName: "strimserver-ffmpeg-scale-egress", //TODO: Do I need this ?
				Command:       []string{"/opt/strimserver/bin/run-ffmpeg-stage", "scale-and-egress"},
			},
		},
      // TODO: find a different place for this
		image: env("STRIMSERVER_FFMPEG_IMAGE", "docker.io/library/strimserver-ffmpeg:latest"),
	}
}


// TODO: make this more extensible - how to add new paths without modifying
// function ?
func validEvent(e Event) bool {
	validPath := e.Path == "ingress0" || e.Path == "normalized"
	validState := e.State == "ready" || e.State == "not-ready"
	return validPath && validState
}

func (c *Controller) HandleEvent(e Event) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if !validEvent(e) {
		return fmt.Errorf("invalid event: path=%q state=%q", e.Path, e.State)
	}

	log.Printf("event path=%s state=%s", e.Path, e.State)
	c.paths[e.Path] = e.State

   // TODO: Consider implementing strategy pattern instead
	switch {
	case e.Path == "ingress0" && e.State == "ready":
		c.desired["normalize"] = "running"
		return c.reconcileLocked()

	case e.Path == "ingress0" && e.State == "not-ready":
      c.desired["normalize"] = "stopped" // TODO: correct this
		c.desired["scale-and-egress"] = "stopped"
		return c.reconcileLocked()

	case e.Path == "normalized" && e.State == "ready":
		c.desired["scale-and-egress"] = "running"
		return c.reconcileLocked()

	case e.Path == "normalized" && e.State == "not-ready":
      c.desired["scale-and-egress"] = "stopped" // TODO: correct this
		return c.reconcileLocked()
	}

	return nil
}

// TODO: write this better - DankReading, consider Strategy pattern
func (c *Controller) reconcileLocked() error {
	for stageName, desired := range c.desired {
		stage := c.stages[stageName]

		if desired == "running" {
			if !containerExists(stage.ContainerName) {
				if err := c.startStage(stage); err != nil {
					return err
				}
			}
		} else { // "stopped"
			if containerExists(stage.ContainerName) {
            if err := stopStage(stage); err != nil { // TODO: is this a bug ? need a controller reference ?
					return err
				}
			}
		}
	}
	return nil
}

// TODO: are all cases handled ? what error codes do we expect ?
// TODO: rename to stageIsRunning
func containerExists(name string) bool {
	cmd := exec.Command("ctr", "containers", "info", name)
	return cmd.Run() == nil
}

func ignoreRun(args ...string) {
	cmd := exec.Command(args[0], args[1:]...)
   _ = cmd.Run() // TODO: sus
}

func stopStage(stage Stage) error {
	log.Printf("stopping stage=%s container=%s", stage.Name, stage.ContainerName)

	ignoreRun("ctr", "tasks", "kill", "--signal", "SIGTERM", stage.ContainerName)
   time.Sleep(300 * time.Millisecond) // TODO: make this not hardcoded
	ignoreRun("ctr", "tasks", "kill", "--signal", "SIGKILL", stage.ContainerName)
	ignoreRun("ctr", "containers", "delete", stage.ContainerName)

	return nil
}

// TODO: remove controller implicit argument - inject the image name a different way
func (c *Controller) startStage(stage Stage) error {
	log.Printf("starting stage=%s container=%s", stage.Name, stage.ContainerName)

	_ = stopStage(stage)

	args := []string{
      "ctr",
		"run",
		"--net-host",
		"--gpus", "0",
		"--cap-add", "CAP_SYS_NICE",

      // TODO: is there a smarter way to inject this configuration ?
		"--mount", "type=bind,src=/mnt/nvme/config/strimserver.env,dst=/opt/strimserver/config/strimserver.env,options=rbind:ro",
		"--mount", "type=bind,src=/mnt/nvme/runtime,dst=/opt/strimserver/runtime,options=rbind:rw",
		"--mount", "type=bind,src=/mnt/nvme/logs,dst=/opt/strimserver/logs,options=rbind:rw",

      c.image, // TODO: inject this in a smarter way
		stage.ContainerName,
	}

	args = append(args, stage.Command...)

   cmd := exec.Command(args[0], args[1:]...) // TODO: confirm that this subprocess detaches from tty ?
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("ctr run failed for %s: %w: %s", stage.Name, err, string(out))
	}

	return nil
}

func (c *Controller) eventHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

   // method of request must be POST - therefore it must have a request body

	var e Event
	if err := json.NewDecoder(r.Body).Decode(&e); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}

   // var e Event is now populated with string values for each key in the datatype

	if err := c.HandleEvent(e); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

   // EZ Clap - event is handled

	w.WriteHeader(http.StatusNoContent)
}

func (c *Controller) healthHandler(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok\n"))
}

func (c *Controller) statusHandler(w http.ResponseWriter, r *http.Request) {
	c.mu.Lock()
	defer c.mu.Unlock()

	actual := map[string]bool{}
	for name, stage := range c.stages {
		actual[name] = containerExists(stage.ContainerName)
	}

   // TODO: this is a bug according to GPT's own specification
	body := map[string]any{
		"paths":   c.paths,
		"desired": c.desired,
		"actual":  actual,
	}

	w.Header().Set("Content-Type", "application/json")
   _ = json.NewEncoder(w).Encode(body) // TODO: Is this even real ?
}

