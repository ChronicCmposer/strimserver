package main

import (
   "context"
   "fmt"
   "log"
   "reflect"

   containerd "github.com/containerd/containerd/v2/client"
   "github.com/containerd/containerd/v2/pkg/cdi"
   "github.com/containerd/containerd/v2/pkg/cio"
   "github.com/containerd/containerd/v2/pkg/oci"
   "github.com/containerd/errdefs"
   "github.com/containerd/typeurl/v2"
   "github.com/opencontainers/runtime-spec/specs-go"
   "github.com/containerd/containerd/api/events"
)


type ContainerFactory struct {
   client         *containerd.Client
   stageNames     map[string]string
}

func (f *ContainerFactory) CreateFFmpegContainer(
   ctx context.Context, id, snapshotID, imageName string, argv ...string,
) (containerd.Container, error) {
   image, err := f.client.GetImage(ctx, imageName)
   if err != nil { return nil, fmt.Errorf("error obtaining reference to oci image %q: %w", imageName, err) }

   snapshot := containerd.WithNewSnapshot(snapshotID, image)

   rw := []string{"rbind", "rw"}
   const Bind = "bind"
   mapping := map[string]string {
      "/mnt/nvme/config/strimserver.env": "/opt/strimserver/config/strimserver.env",
      "/mnt/nvme/bin/transcode.sh": "/opt/strimserver/bin/transcode.sh",
   }


   mounts := make([]specs.Mount, 0, len(mapping))

   for src, dest := range mapping {
      mounts = append(mounts, specs.Mount{Type: Bind, Source: src, Destination: dest, Options: rw})
   }

   spec := containerd.WithNewSpec(
      oci.WithImageConfig(image),
      oci.WithHostNamespace(specs.NetworkNamespace),
      oci.WithAddedCapabilities([]string{"CAP_SYS_NICE"}),
      oci.WithMounts(mounts),
      oci.WithProcessArgs(argv...),
      cdi.WithCDIDevices("nvidia.com/gpu=0"),
   )

   container, err := f.client.NewContainer(ctx, id, snapshot, spec)
   if err != nil { return nil, fmt.Errorf("could not create ffmpeg container with id %q: %w", id, err) }

   return container, nil

}

func (f *ContainerFactory) CreateMediaMTXContainer(
   ctx context.Context, id, snapshotID, imageName string, argv ...string,
) (containerd.Container, error) {
   image, err := f.client.GetImage(ctx, imageName)
   if err != nil { return nil, fmt.Errorf("error obtaining reference to oci image %q: %w", imageName, err) }

   snapshot := containerd.WithNewSnapshot(snapshotID, image)

   rw := []string{"rbind", "rw"}
   const Bind = "bind"
   mapping := map[string]string {
      "/mnt/nvme/config/strimserver.env": "/opt/strimserver/config/strimserver.env",
      "/mnt/nvme/srt-passphrase": "/run/secrets/srt-passphrase",
      "/mnt/nvme/video-files": "/opt/strimserver/video-files",
   }

   mounts := make([]specs.Mount, 0, len(mapping))

   for src, dest := range mapping {
      mounts = append(mounts, specs.Mount{Type: Bind, Source: src, Destination: dest, Options: rw})
   }

   spec := containerd.WithNewSpec(
      oci.WithImageConfig(image),
      oci.WithHostNamespace(specs.NetworkNamespace),
      oci.WithAddedCapabilities([]string{"CAP_SYS_NICE"}),
      oci.WithMounts(mounts),
      oci.WithProcessArgs(argv...),
   )

   container, err := f.client.NewContainer(ctx, id, snapshot, spec)
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
   name        string,
   createFunc  func(context.Context) (containerd.Container, string, error),
   lookupFunc  func(context.Context) (containerd.Container, error),
) map[StageState]func(context.Context) error {
   start := func(ctx context.Context) error {
      container, logfile, err := createFunc(ctx)
      if err != nil { return fmt.Errorf("could not create %q container: %w", name, err) }

      task, err := f.CreateTask(ctx, container, logfile)
      if err != nil { return fmt.Errorf("could not create %q task: %w", name, err) }

      err = task.Start(ctx)
      if err != nil { return fmt.Errorf("could not start %q task: %w", name, err) }

      return nil
   }
   stop := func(ctx context.Context) error {
      // prerequisite - valid task
      deleteTask := func(task containerd.Task) error {
         exitStatus, err := task.Delete(ctx, containerd.WithProcessKill)
         if err == nil { log.Printf("deleted %q task, exit status: %+v", name, exitStatus); return nil }
         return fmt.Errorf("could not delete %q task: %w", name, err)
      }

      // prerequisite - valid container, no running tasks
      deleteContainer := func(container containerd.Container) error {
         err := container.Delete(ctx, containerd.WithSnapshotCleanup)
         if err != nil { return fmt.Errorf("could not delete %q container: %w", name, err) }
         log.Printf("%q container deleted", name); return nil
      }

      container, err := lookupFunc(ctx)

      if err != nil {
         if !errdefs.IsNotFound(err) { return fmt.Errorf("could not load %q container for deletion: %w", name, err) }
         log.Printf("%q container not found, could not delete, continuing...", name); return nil
      }

      // if we get to this point, container must be valid
      task, err := container.Task(ctx, cio.Load)
      if err != nil {
         if !errdefs.IsNotFound(err) { return fmt.Errorf("could not load %q task for deletion: %w", name, err) }
         log.Printf("%q task not found, could not delete, continuing...", name)
         if deleteError := deleteContainer(container); deleteError != nil { return deleteError }
         return nil
      }

      err = deleteTask(task)
      if err != nil { return err }
      err = deleteContainer(container)
      if err != nil { return err }
      return nil
   }
   return map[StageState]func(context.Context) error { Running: start, Stopped: stop }
}

func (f *ContainerFactory) CreateStageOps(containerConfig ContainerConfig) map[StageState]func(context.Context) error {
   stageName, ok := f.stageNames[containerConfig.ContainerID]
   if !ok { stageName = containerConfig.ContainerID }

   createFunc := func(ctx context.Context) (containerd.Container, string, error) {
      container, err := f.CreateFFmpegContainer(
         ctx, containerConfig.ContainerID, containerConfig.SnapshotID, containerConfig.ImageName,
         "/opt/strimserver/bin/transcode.sh", stageName)
      return container, containerConfig.Logfile, err
   }

   lookupFunc := func(ctx context.Context) (containerd.Container, error) {
      return f.client.LoadContainer(ctx, containerConfig.ContainerID)
   }

   return f.CreateContainerOps(stageName, createFunc, lookupFunc)
}

func (f *ContainerFactory) CreateEventHandlers(controller *Controller) map[string]func(any)error {
   return map[string]func(any) error{
      "TaskStart": func(e any) error {
         event := e.(*events.TaskStart)
         name, ok := f.stageNames[event.GetContainerID()]
         if !ok {
            log.Printf("received TaskStart event, but not associated with any stage: %+v", event)
            return nil
         }
         err := controller.SubmitStageEvent(StageEvent{ Stage: StageName(name), State: Running })
         if err != nil { return fmt.Errorf("could not handle TaskStart event: %w", err) }
         return nil
      },
      "TaskExit": func(e any) error {
         event := e.(*events.TaskExit)
         name, ok := f.stageNames[event.GetContainerID()]
         if !ok {
            log.Printf("received TaskExit event, but not associated with any stage: %+v", event)
            return nil
         }
         err := controller.SubmitStageEvent(StageEvent{ Stage: StageName(name), State: Stopped })
         if err != nil { return fmt.Errorf("could not handle TaskExit event: %w", err) }
         return nil
      },
   }
}

func (f ContainerFactory) CreateContainerdEventListener(
   filters []string, handlers map[string]func(any)error,
) func(context.Context) {
   return func(ctx context.Context) {
      eventChannel, errorChannel := f.client.Subscribe(ctx, filters...)

      for {
         select {
            case envelope := <-eventChannel:
               if envelope == nil || envelope.Event == nil { continue }
               event, err := typeurl.UnmarshalAny(envelope.Event)
               if err != nil { log.Printf("error decoding containerd event: %v", err); continue }

               // look up event handler
               eventName := reflect.TypeOf(event).Name()
               handle, ok := handlers[eventName]
               if !ok {
                  log.Printf("no containerd event handler for type %q, continuing...", eventName)
                  continue
               }

               err = handle(event)
               if err != nil { log.Printf("could not handle containerd event: %v", err) }
               continue

            case err := <-errorChannel:
               if ctx.Err() != nil { return }
               log.Printf("containerd event stream error: %v", err); return

            case <-ctx.Done(): return
         }
      }
   }
}
