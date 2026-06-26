package main

import (
   "context"
   "encoding/json"
   "errors"
   "fmt"
   "log"
   "net/http"
   "os/signal"
   "reflect"
   "strconv"
   "syscall"
   "time"

   "github.com/coder/websocket"
   "github.com/coder/websocket/wsjson"

   containerd "github.com/containerd/containerd/v2/client"
   "github.com/containerd/containerd/v2/pkg/namespaces"
   "github.com/containerd/containerd/api/events"
)

type ContainerConfig struct{ ContainerID, SnapshotID, ImageName, Logfile string }
type Config struct {
   ContainerdSocket, ContainerdNamespace, ControllerHTTPPort string
   ControllerReconcileInterval time.Duration
   ControllerInFlightTimeout time.Duration
   ControllerShutdownTimeout time.Duration
   StageStopTimeout time.Duration
   WebsocketWriteTimeout time.Duration
   ControllerActionsBufferSize uint8
   MediaMTX, Normalize, ScaleAndEgress ContainerConfig
}

func LoadConfig() (Config, error) {
   var errs []error
   require := createRequireParsed(&errs, func(s string) (string, error) { return s, nil })
   requireUInt8 := createRequireParsed(&errs, func (s string) (uint8, error) {
      i, err := strconv.ParseUint(s, 10, 8); return uint8(i), err
   })
   requireDuration := createRequireParsed(&errs, func (s string) (time.Duration, error) {
      return time.ParseDuration(s)
   })

   cfg := Config{
      ContainerdSocket:             require("CONTAINERD_SOCKET"),
      ContainerdNamespace:          require("CONTAINERD_NAMESPACE"),
      ControllerReconcileInterval:  requireDuration("CONTROLLER_RECONCILE_INTERVAL"),
      ControllerInFlightTimeout:    requireDuration("CONTROLLER_INFLIGHT_TIMEOUT"),
      ControllerShutdownTimeout:    requireDuration("CONTROLLER_SHUTDOWN_TIMEOUT"),
      StageStopTimeout:             requireDuration("STAGE_STOP_TIMEOUT"),
      WebsocketWriteTimeout:        requireDuration("WEBSOCKET_WRITE_TIMEOUT"),
      ControllerActionsBufferSize:  requireUInt8("CONTROLLER_ACTIONS_BUFFER_SIZE"),
      ControllerHTTPPort:           require("CONTROLLER_HTTP_PORT"),

      MediaMTX: ContainerConfig{
         ContainerID:   require("MEDIAMTX_CONTAINER_ID"),
         SnapshotID:    require("MEDIAMTX_SNAPSHOT_ID"),
         ImageName:     require("MEDIAMTX_IMAGE_NAME"),
         Logfile:       require("MEDIAMTX_LOG_FILE"),
      },

      Normalize: ContainerConfig{
         ContainerID:   require("NORMALIZE_CONTAINER_ID"),
         SnapshotID:    require("NORMALIZE_SNAPSHOT_ID"),
         ImageName:     require("FFMPEG_IMAGE_NAME"),
         Logfile:       require("NORMALIZE_LOG_FILE"),
      },

      ScaleAndEgress: ContainerConfig{
         ContainerID:   require("EGRESS_CONTAINER_ID"),
         SnapshotID:    require("EGRESS_SNAPSHOT_ID"),
         ImageName:     require("FFMPEG_IMAGE_NAME"),
         Logfile:       require("EGRESS_LOG_FILE"),
      },
   }

   if len(errs) > 0 {
      return Config{}, errors.Join(errs...)
   }
   return cfg, nil
}

func createRequireParsed[T any](errs *[]error, parse func(string) (T, error)) func(string) T {
   return func(key string) T {
      s, found := syscall.Getenv(key)
      if !found || s == "" {
         *errs = append(*errs, fmt.Errorf("missing required env var %q", key))
         var zero T; return zero
      }
      v, err := parse(s)
      if err != nil { *errs = append(*errs, fmt.Errorf("could not parse %q = %q: %w", key, s, err)) }
      return v
   }
}

func main() {
   err := run()
   if err != nil { log.Fatal(err) }
}

func run() error {
   config, err := LoadConfig()
   if err != nil { return fmt.Errorf("could not load config: %w", err) }

   rootContext, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
   nsCtx := namespaces.WithNamespace(rootContext, config.ContainerdNamespace)

   client, err := containerd.New(config.ContainerdSocket)
   if err != nil { return fmt.Errorf("could not initialize containerd client: %w", err) }
   defer client.Close()

   // path names
   const Ingress0    = "ingress0"
   const Normalized  = "normalized"

   // stage names
   const MediaMTX       = "mediamtx"
   const Normalize      = "normalize"
   const ScaleAndEgress = "scale_and_egress"

   // build the container factory

   containerIDtoStageName := map[string]StageName {
      config.MediaMTX.ContainerID:        MediaMTX,
      config.Normalize.ContainerID:       Normalize,
      config.ScaleAndEgress.ContainerID:  ScaleAndEgress,
   }

   containerFactory, err := NewContainerFactory(
      client, containerIDtoStageName, config.StageStopTimeout)
   if err != nil { return fmt.Errorf("could not create container factory: %w", err) }

   // build the mediamtx operations
   createFunc := func(ctx context.Context) (containerd.Container, string, error) {
      cfg := config.MediaMTX
      container, err := containerFactory.CreateMediaMTXContainer(
         ctx, cfg.ContainerID, cfg.SnapshotID, cfg.ImageName)
      return container, cfg.Logfile, err
   }

   lookupFunc := func(ctx context.Context) (containerd.Container, error) {
      return containerFactory.client.LoadContainer(ctx, config.MediaMTX.ContainerID)
   }

   mediamtxOps := containerFactory.CreateContainerOps("mediamtx", createFunc, lookupFunc)

   // build the controller
   paths := map[PathName]PathStatus { Ingress0: Unknown, Normalized: Unknown }

   pathEventRoutes := map[PathEvent]StageTarget {
      { Path: Ingress0,    Status: Ready     }: { Stage: Normalize,        State: Running },
      { Path: Ingress0,    Status: NotReady  }: { Stage: Normalize,        State: Stopped },
      // { Path: Normalized,  Status: Ready     }: { Stage: ScaleAndEgress,   State: Running },
      // { Path: Normalized,  Status: NotReady  }: { Stage: ScaleAndEgress,   State: Stopped },
   }

   commandRoutes := map[ControlCommand]StageTarget {
      { Component: "scale_and_egress", Action: "start" }: { Stage: ScaleAndEgress, State: Running,
         Prerequisite: func(c *Controller) error {
            if c.paths[Normalized] != Ready { return fmt.Errorf("normalized path is not ready") }
            return nil
         },
      },
      { Component: "scale_and_egress", Action: "stop" }: { Stage: ScaleAndEgress, State: Stopped },
   }

   stages := map[StageName]*Stage{
      MediaMTX: {
         Status: StageStatus{ Desired: Running, Actual: Stopped },
         Ops: mediamtxOps,
      },
      Normalize: {
         Status: StageStatus{ Desired: Stopped, Actual: Stopped },
         Ops: containerFactory.CreateStageOps(config.Normalize),
      },
      ScaleAndEgress: {
         Status: StageStatus{ Desired: Stopped, Actual: Stopped },
         Ops: containerFactory.CreateStageOps(config.ScaleAndEgress),
      },
   }

   now := time.Now // function pointer - not a time value
   inflightTimeout := config.ControllerInFlightTimeout
   actionsBufferSize := config.ControllerActionsBufferSize

   controller, err := NewController(
      nsCtx, paths, stages, pathEventRoutes, commandRoutes,
      now, inflightTimeout, actionsBufferSize,
   )
   if err != nil { return fmt.Errorf("error constructing controller: %w", err) }

   log.Printf("%+v", controller)

   // wire up HTTP listener
   mux := http.NewServeMux()

   mux.HandleFunc("/event", postJSON(controller, (*Controller).SubmitPathEvent))

   mux.HandleFunc("/control", postJSON(controller, (*Controller).SubmitControl))

   mux.HandleFunc("/status", getJSON(controller, (*Controller).Status))

   mux.HandleFunc("/subscribe", func(w http.ResponseWriter, r *http.Request) {
      conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{ InsecureSkipVerify: true })
      if err != nil { log.Printf("ws accept error: %v", err); return }

      ctx, cancel := context.WithCancel(rootContext)
      defer cancel()
      ctx = conn.CloseRead(ctx)

      sendChannel := make(chan *ControllerStatus, 1)
      listener := ControllerListener(func(status *ControllerStatus) {
         select {
            case sendChannel <- status:
            default:
               select { case <-sendChannel: default: }
               select { case sendChannel <- status: default: }
         }
      })

      err = controller.SubmitAddListener(&listener)
      if err != nil {
         log.Printf("could not add ControllerListener for ws client %q: %v", r.RemoteAddr, err)
         conn.Close(websocket.StatusInternalError, err.Error()); return
      }
      defer func() {
         done := make(chan struct{})
         go func() {
            defer close(done)
            err := controller.SubmitRemoveListener(&listener)
            if err != nil { log.Printf("could not remove ControllerListener for ws client %q: %v", r.RemoteAddr, err) }
         }()
         select { case <-done: case <-time.After(time.Second): }
      }()

      // writer
      for {
         select {
            case <-ctx.Done():
               conn.Close(websocket.StatusNormalClosure, "")
               return
            case status := <-sendChannel:
               wctx, cancel := context.WithTimeout(ctx, config.WebsocketWriteTimeout)
               err := wsjson.Write(wctx, conn, status); cancel()
               if err != nil {
                  log.Printf("ws write error: %v", err)
                  conn.Close(websocket.StatusInternalError, err.Error()); return
               }
         }
      }
   })

   mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
      w.WriteHeader(http.StatusOK)
      _, err := w.Write([]byte("ok\n"))
      if err != nil {
         log.Printf("healthz endpoint error: %+v", err)
      }
   })

   // wire up containerd listener
   topicFilters := []string { `topic~="/tasks/.*"` }
   eventTypeToStageState := map[reflect.Type]StageState {
      reflect.TypeFor[*events.TaskStart]():   Running,
      reflect.TypeFor[*events.TaskExit]():    Stopped,
   }

   listenForContainerdEvents := containerFactory.CreateContainerdEventListener(
      topicFilters, eventTypeToStageState)

   log.Printf("starting control plane...")

   // Start the controller loop
   runDone := make(chan struct{})
   go func() { controller.Run(); close(runDone) }()

   // Start the containerd loop
   listenerDone := make(chan struct{})
   go func() {
      listenForContainerdEvents(nsCtx, controller)
      close(listenerDone)
   }()

   // Start the reconcile loop
   tickerDone := make(chan struct{})
   go func() {
      invokeReconcileEvery(nsCtx, controller, config.ControllerReconcileInterval)
      close(tickerDone)
   }()

   // Start the HTTP server loop
   addr := fmt.Sprintf(":%s", config.ControllerHTTPPort)

   srv := &http.Server{ Addr: addr, Handler: mux }
   go func() {
      log.Printf("controller listening on %s", addr)
      err := srv.ListenAndServe()
      if err != nil && !errors.Is(err, http.ErrServerClosed) {
         log.Printf("http server error: %v", err)
         stop()
      }
   }()

   <-rootContext.Done()
   stop()
   log.Printf("shutting down")

   shutdownCtx, cancel := context.WithTimeout(context.Background(), config.ControllerShutdownTimeout)
   defer cancel()

   err = srv.Shutdown(shutdownCtx)
   if err != nil {
      log.Printf("graceful http shutdown failed: %v", err)
      _ = srv.Close()
   }

   <-tickerDone
   <-listenerDone

   controller.WaitForOps()
   controller.Teardown()
   controller.Close()
   <-runDone

   return nil
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
      if err != nil { http.Error(w, err.Error(), http.StatusInternalServerError); return }
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
      if err != nil { log.Printf("json serialization error: %v", err) }
   }
}

func invokeReconcileEvery(ctx context.Context, c *Controller, interval time.Duration) {
   ticker := time.NewTicker(interval)
   defer ticker.Stop()
   for {
      select {
         case <-ctx.Done(): return
         case <-ticker.C:
            if ctx.Err() != nil { return }
            c.RequestReconcile()
      }
   }
}

