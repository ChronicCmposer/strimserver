package main

import (
	"log"
	"net/http"
)


func main() {
	controller := NewController()

   log.Printf("Hello, World!")
   log.Printf("%+v", controller)

	// Conservative startup cleanup. The controller owns FFmpeg lifecycle.
	for _, stage := range controller.stages {
		_ = stopStage(stage)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/events", controller.eventHandler)
	mux.HandleFunc("/healthz", controller.healthHandler)
	mux.HandleFunc("/status", controller.statusHandler)

	addr := env("STRIMSERVER_CONTROLLER_ADDR", "127.0.0.1:9177")
	log.Printf("strim-controller listening on %s", addr)

	  // TODO: does http.ListenAndServe(addr, mux) block indefinitely
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}
