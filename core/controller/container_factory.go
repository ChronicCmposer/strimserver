package main

import (
   "context"
   "errors"
   "fmt"
   "log"
   "reflect"
   "syscall"
   "time"

   containerd "github.com/containerd/containerd/v2/client"
   "github.com/containerd/containerd/v2/pkg/cdi"
   "github.com/containerd/containerd/v2/pkg/cio"
   "github.com/containerd/containerd/v2/pkg/oci"
   "github.com/containerd/errdefs"
   "github.com/containerd/typeurl/v2"
   "github.com/opencontainers/runtime-spec/specs-go"
)


type ContainerFactory struct {
   client      *containerd.Client
   stageNames  map[string]StageName
   gracefulStopTimeout  time.Duration
}

func NewContainerFactory(
   client *containerd.Client,
   stageNames map[string]StageName,
   gracefulStopTimeout time.Duration,
) (*ContainerFactory, error) {
   var errs []error
   if client == nil { errs = append(errs, fmt.Errorf("containerd client cannot be nil")) }
   for id, stageName := range stageNames {
      if stageName == "" { errs = append(errs, fmt.Errorf("empty stage name for container id %q", id)) }
   }
   if len(errs) > 0 { return nil, errors.Join(errs...) }
   return &ContainerFactory{
      client: client, stageNames: stageNames,
      gracefulStopTimeout: gracefulStopTimeout,
   }, nil
}

type Mount struct {
   Src, Dst string
   ReadWrite bool
}

func toOCIMounts(mounts []Mount) []specs.Mount {
   out := make([]specs.Mount, 0, len(mounts))
   rw, ro := []string{"rbind", "rw"}, []string{"rbind", "ro"}
   for _, mount := range mounts {
      opts := ro; if mount.ReadWrite { opts = rw }
      out = append(out, specs.Mount{
         Type:          "bind",
         Source:        mount.Src,
         Destination:   mount.Dst,
         Options:       opts,
      })
   }
   return out
}

func (f *ContainerFactory) buildContainer(
   ctx context.Context, id, snapshotID, imageName string,
   mounts []Mount, extra ...oci.SpecOpts,
) (containerd.Container, error) {
   image, err := f.client.GetImage(ctx, imageName)
   if err != nil { return nil, fmt.Errorf("error obtaining reference to oci image %q: %w", imageName, err) }

   opts := []oci.SpecOpts{
      oci.WithImageConfig(image),
      oci.WithHostNamespace(specs.NetworkNamespace),
      oci.WithAddedCapabilities([]string{"CAP_SYS_NICE"}),
      oci.WithMounts(toOCIMounts(mounts)),
   }
   opts = append(opts, extra...)

   container, err := f.client.NewContainer(ctx, id,
      containerd.WithNewSnapshot(snapshotID, image),
      containerd.WithNewSpec(opts...),
   )
   if err != nil { return nil, fmt.Errorf("could not create container with id %q: %w", id, err) }
   return container, nil
}


func (f *ContainerFactory) CreateFFmpegContainer(
   ctx context.Context, id, snapshotID, imageName string, argv ...string,
) (containerd.Container, error) {
   mounts := []Mount {
      { Src: "/mnt/nvme/config/strimserver.env",   Dst: "/strimserver.env" },
      { Src: "/mnt/nvme/bin/transcode.sh",         Dst: "/transcode.sh" },
      { Src: "/run/systemd/resolve/resolv.conf",   Dst: "/etc/resolv.conf" },
      { Src: "/tmp",                               Dst: "/tmp", ReadWrite: true },
   }
   container, err := f.buildContainer(ctx, id, snapshotID, imageName, mounts,
      oci.WithProcessArgs(argv...),
      cdi.WithCDIDevices("nvidia.com/gpu=0"))
   if err != nil { return nil, fmt.Errorf("could not create ffmpeg container with id %q: %w", id, err) }
   return container, nil
}

func (f *ContainerFactory) CreateMediaMTXContainer(
   ctx context.Context, id, snapshotID, imageName string,
) (containerd.Container, error) {
   mounts := []Mount {
      { Src: "/mnt/nvme/config/strimserver.env",          Dst: "/strimserver.env" },
      { Src: "/mnt/nvme/config/mediamtx.yaml.template",   Dst: "/mediamtx.yaml.template" },
      { Src: "/mnt/nvme/bin/notify.sh",                   Dst: "/notify.sh" },
      { Src: "/mnt/nvme/srt-passphrase",                  Dst: "/run/secrets/srt-passphrase" },
      { Src: "/mnt/nvme/video-files",                     Dst: "/video-files", ReadWrite: true },
      { Src: "/tmp",                                      Dst: "/tmp",         ReadWrite: true },
   }
   container, err := f.buildContainer(ctx, id, snapshotID, imageName, mounts)
   if err != nil { return nil, fmt.Errorf("could not create mediamtx container with id %q: %w", id, err) }
   return container, nil
}

func (f *ContainerFactory) CreateTask(
   ctx context.Context, container containerd.Container, logfile string,
) (containerd.Task, error) {
   task, err := container.NewTask(ctx, cio.LogFile(logfile))
   if err != nil { return nil, fmt.Errorf("could not create task: %w", err) }
   return task, nil
}

func (f *ContainerFactory) CreateContainerOps(
   name        StageName,
   createFunc  func(context.Context) (containerd.Container, string, error),
   lookupFunc  func(context.Context) (containerd.Container, error),
) map[StageState]func(context.Context) error {
   stop := func(ctx context.Context) error {
      container, err := lookupFunc(ctx)
      if err != nil {
         if !errdefs.IsNotFound(err) { return fmt.Errorf("could not load %q container for deletion: %w", name, err) }
         log.Printf("%q container not found, could not delete, continuing...", name); return nil
      }

      // prerequisite - valid container, no running tasks
      deleteContainer := func(container containerd.Container) error {
         err := container.Delete(ctx, containerd.WithSnapshotCleanup)
         if err != nil { return fmt.Errorf("could not delete %q container: %w", name, err) }
         log.Printf("%q container deleted", name); return nil
      }

      // if we get to this point, container must be valid
      task, err := container.Task(ctx, cio.Load)
      if err != nil {
         if !errdefs.IsNotFound(err) { return fmt.Errorf("could not load %q task for deletion: %w", name, err) }
         log.Printf("%q task not found, could not delete, continuing...", name)
         if deleteError := deleteContainer(container); deleteError != nil { return deleteError }
         return nil
      }

      // prerequisite - valid task
      deleteTask := func(task containerd.Task) error {
         // Subscribe to the exit event BEFORE signalling; a fast-exiting task
         // can fire its exit before we start waiting otherwise.
         exitCh, err := task.Wait(ctx)
         if err != nil {
            if errdefs.IsNotFound(err) { return nil } // already gone
            return fmt.Errorf("could not wait on %q task: %w", name, err)
         }

         if err := task.Kill(ctx, syscall.SIGTERM); err != nil && !errdefs.IsNotFound(err) {
            return fmt.Errorf("could not signal %q task: %w", name, err)
         }

         select {
            case status := <-exitCh:
               code, _, _ := status.Result()
               log.Printf("%q task exited gracefully, exit code: %d", name, code)
               if _, err := task.Delete(ctx); err != nil && !errdefs.IsNotFound(err) {
                  return fmt.Errorf("could not delete %q task after graceful exit: %w", name, err)
               }
               return nil

            case <-time.After(f.gracefulStopTimeout):
               log.Printf("%q task did not exit within %s, forcing kill", name, f.gracefulStopTimeout)
               if _, err := task.Delete(ctx, containerd.WithProcessKill); err != nil && !errdefs.IsNotFound(err) {
                  return fmt.Errorf("could not force-delete %q task: %w", name, err)
               }
               return nil

            case <-ctx.Done():
               // Stop context cancelled mid-wait; ensure the task is reaped anyway
               // (use WithoutCancel so the force-delete itself can complete) so the
               // subsequent container.Delete won't fail on a lingering task.
               log.Printf("%q stop context cancelled, forcing kill", name)
               if _, err := task.Delete(context.WithoutCancel(ctx), containerd.WithProcessKill); err != nil && !errdefs.IsNotFound(err) {
                  return fmt.Errorf("could not force-delete %q task on cancel: %w", name, err)
               }
               return nil
         }
      }

      err = deleteTask(task)
      if err != nil { return err }
      err = deleteContainer(container)
      if err != nil { return err }
      return nil
   }

   start := func(ctx context.Context) error {
      err := stop(ctx)
      if err != nil { return fmt.Errorf("could not clean up %q before start: %w", name, err) }

      container, logfile, err := createFunc(ctx)
      if err != nil { return fmt.Errorf("could not create %q container: %w", name, err) }

      task, err := f.CreateTask(ctx, container, logfile)
      if err != nil { return fmt.Errorf("could not create %q task: %w", name, err) }

      err = task.Start(ctx)
      if err != nil { return fmt.Errorf("could not start %q task: %w", name, err) }

      return nil
   }

   return map[StageState]func(context.Context) error { Running: start, Stopped: stop }
}

func (f *ContainerFactory) CreateStageOps(containerConfig ContainerConfig) map[StageState]func(context.Context) error {
   stageName, ok := f.stageNames[containerConfig.ContainerID]
   if !ok { stageName = StageName(containerConfig.ContainerID) }

   createFunc := func(ctx context.Context) (containerd.Container, string, error) {
      container, err := f.CreateFFmpegContainer(
         ctx, containerConfig.ContainerID, containerConfig.SnapshotID, containerConfig.ImageName,
         "/transcode.sh", string(stageName))
      return container, containerConfig.Logfile, err
   }

   lookupFunc := func(ctx context.Context) (containerd.Container, error) {
      return f.client.LoadContainer(ctx, containerConfig.ContainerID)
   }

   return f.CreateContainerOps(stageName, createFunc, lookupFunc)
}

func (f ContainerFactory) CreateContainerdEventListener(
   filters []string, stageStates map[reflect.Type]StageState,
) func(context.Context, *Controller) {

   type TaskEvent interface { GetContainerID() string }

   return func(ctx context.Context, controller *Controller) {
      eventChannel, errorChannel := f.client.Subscribe(ctx, filters...)

      for {
         select {
            case envelope := <-eventChannel:
               if envelope == nil || envelope.Event == nil { continue }

               event, err := typeurl.UnmarshalAny(envelope.Event)
               if err != nil { log.Printf("error decoding containerd event: %v", err); continue }

               eventType := reflect.TypeOf(event)
               eventName := eventType.Name()
               target, ok := f.stageNames[event.(TaskEvent).GetContainerID()]
               if !ok {
                  log.Printf("received %q event, but not associated with any stage: %+v", eventName, event)
                  continue
               }

               targetState, ok := stageStates[eventType]
               if !ok { continue }

               err = controller.SubmitStageEvent(StageEvent{ Stage: target, State: targetState })
               if err != nil { log.Printf("could not handle %q event: %v", eventName, err) }

            case err := <-errorChannel:
               if ctx.Err() != nil { return }
               log.Printf("containerd event stream error: %v", err); return

            case <-ctx.Done(): return
         }
      }
   }
}
