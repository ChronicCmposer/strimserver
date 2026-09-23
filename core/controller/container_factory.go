// Package main implements the strimserver controller: it drives the
// mediamtx/normalize/scale-and-egress containerd containers and their
// lifecycle transitions, and exposes the HTTP/websocket control plane.
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
   "github.com/containerd/containerd/v2/core/events"
   "github.com/containerd/containerd/v2/pkg/cdi"
   "github.com/containerd/containerd/v2/pkg/cio"
   "github.com/containerd/containerd/v2/pkg/oci"
   "github.com/containerd/errdefs"
   "github.com/containerd/typeurl/v2"
   "github.com/opencontainers/runtime-spec/specs-go"
)

// containerClient is the subset of the containerd client the factory depends
// on. Keeping it an interface lets the unit tests drive the factory with a
// recording fake and assert the exact construction parameters (image name,
// container id, snapshot option, OCI spec) without a live containerd daemon.
// *containerd.Client satisfies it structurally.
type containerClient interface {
   GetImage(ctx context.Context, ref string) (containerd.Image, error)
   NewContainer(ctx context.Context, id string, opts ...containerd.NewContainerOpts) (containerd.Container, error)
   LoadContainer(ctx context.Context, id string) (containerd.Container, error)
   Subscribe(ctx context.Context, filters ...string) (ch <-chan *events.Envelope, errs <-chan error)
}

type ContainerFactory struct {
   client               containerClient
   stageNames           map[string]StageName
   gracefulStopTimeout  time.Duration
   layout               Layout
}

func NewContainerFactory(
   client *containerd.Client,
   stageNames map[string]StageName,
   gracefulStopTimeout time.Duration,
   layout Layout,
) (*ContainerFactory, error) {
   var errs []error
   if client == nil { errs = append(errs, fmt.Errorf("containerd client cannot be nil")) }
   for id, stageName := range stageNames {
      if stageName == "" { errs = append(errs, fmt.Errorf("empty stage name for container id %q", id)) }
   }
   err := layout.validate(); if err != nil { errs = append(errs, err) }
   if len(errs) > 0 { return nil, errors.Join(errs...) }
   return &ContainerFactory{
      client: client, stageNames: stageNames,
      gracefulStopTimeout: gracefulStopTimeout, layout: layout,
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

// ffmpegMounts is the bind-mount list every ffmpeg stage container (normalize,
// scale-and-egress, single-stage-egress) is created with. It is the pure
// construction decision the assembly ctr_fill_mounts must reproduce exactly:
// the env file, the transcode script, the host resolv.conf and a writable
// /tmp.
func ffmpegMounts(layout Layout) []Mount {
   return []Mount{
      { Src: layout.Env,          Dst: ctrEnv },
      { Src: layout.Transcode,    Dst: ctrTranscode },
      { Src: layout.ResolvConf,   Dst: ctrResolvConf },
      { Src: layout.Tmp,          Dst: ctrTmp, ReadWrite: true },
   }
}

// mediamtxMounts is the bind-mount list the mediamtx container is created
// with: the env file, the mediamtx template, the notify script, the SRT
// passphrase secret, plus writable video-files and /tmp.
func mediamtxMounts(layout Layout) []Mount {
   return []Mount{
      { Src: layout.Env,          Dst: ctrEnv },
      { Src: layout.MediaMTXTmpl, Dst: ctrMediaMTXTmpl },
      { Src: layout.Notify,       Dst: ctrNotify },
      { Src: layout.SrtPass,      Dst: ctrSrtSecret },
      { Src: layout.VideoDir,     Dst: ctrVideoDir, ReadWrite: true },
      { Src: layout.Tmp,          Dst: ctrTmp,      ReadWrite: true },
   }
}

// baseSpecOpts returns the OCI spec options every strimserver container
// shares: the image config (env/entrypoint/cmd/cwd/user from the image), host
// networking, the CAP_SYS_NICE capability, and the bind mounts.
func baseSpecOpts(image oci.Image, mounts []Mount) []oci.SpecOpts {
   return []oci.SpecOpts{
      oci.WithImageConfig(image),
      oci.WithHostNamespace(specs.NetworkNamespace),
      oci.WithAddedCapabilities([]string{"CAP_SYS_NICE"}),
      oci.WithMounts(toOCIMounts(mounts)),
   }
}

func (f *ContainerFactory) buildContainer(
   ctx context.Context, id, snapshotID, imageName string,
   mounts []Mount, extra ...oci.SpecOpts,
) (containerd.Container, error) {
   image, err := f.client.GetImage(ctx, imageName)
   if err != nil { return nil, fmt.Errorf("error obtaining reference to oci image %q: %w", imageName, err) }

   opts := baseSpecOpts(image, mounts)
   opts = append(opts, extra...)

   // The rootfs snapshot is created FROM the resolved image: WithNewSnapshot
   // derives the parent chain from the image's rootfs diff-ids, so the
   // container's rootfs contains the image content. This is the contract the
   // assembly port must reproduce — never create the snapshot empty-parented.
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
   container, err := f.buildContainer(ctx, id, snapshotID, imageName, ffmpegMounts(f.layout),
      oci.WithProcessArgs(argv...),
      cdi.WithCDIDevices("nvidia.com/gpu=0"))
   if err != nil { return nil, fmt.Errorf("could not create ffmpeg container with id %q: %w", id, err) }
   return container, nil
}

func (f *ContainerFactory) CreateMediaMTXContainer(
   ctx context.Context, id, snapshotID, imageName string,
) (containerd.Container, error) {
   container, err := f.buildContainer(ctx, id, snapshotID, imageName, mediamtxMounts(f.layout))
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

// stageArgv returns the argv the ffmpeg stages are launched with: the
// transcode script path followed by the stage NAME. The stage name differs
// from the container id — the container "scale-and-egress" runs as the stage
// "scale_and_egress" — and transcode.sh / the egress scripts switch on the
// stage name, while containerd derives the cgroups path from the container id.
func (f *ContainerFactory) stageArgv(containerConfig ContainerConfig) []string {
   stageName, ok := f.stageNames[containerConfig.ContainerID]
   if !ok { stageName = StageName(containerConfig.ContainerID) }
   return []string{ctrTranscode, string(stageName)}
}

func (f *ContainerFactory) CreateStageOps(containerConfig ContainerConfig) map[StageState]func(context.Context) error {
   stageName, ok := f.stageNames[containerConfig.ContainerID]
   if !ok { stageName = StageName(containerConfig.ContainerID) }

   createFunc := func(ctx context.Context) (containerd.Container, string, error) {
      container, err := f.CreateFFmpegContainer(
         ctx, containerConfig.ContainerID, containerConfig.SnapshotID, containerConfig.ImageName,
         f.stageArgv(containerConfig)...)
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
               taskEvent, ok := event.(TaskEvent)
               if !ok {
                  log.Printf("received %q event without a container id: %+v", eventName, event)
                  continue
               }
               target, ok := f.stageNames[taskEvent.GetContainerID()]
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
