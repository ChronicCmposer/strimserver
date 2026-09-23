package main

// Unit tests for the container-factory construction path. These pin down the
// exact mounts, snapshot selection, and OCI spec the factory produces for the
// four stage configs, so they act as the tested oracle for the byte-exact
// assembly port (ctr_fill_mounts / ctr_fill_spec / the containerd client
// calls). They run without a live containerd daemon: the pure construction
// decisions (mounts, spec opts, stage argv) are exercised directly, and the
// client surface (GetImage/NewContainer) is driven through a recording fake.

import (
   "bytes"
   "context"
   "encoding/json"
   "path/filepath"
   "reflect"
   "slices"
   "testing"
   "time"

   containerd "github.com/containerd/containerd/v2/client"
   "github.com/containerd/containerd/v2/core/content"
   "github.com/containerd/containerd/v2/core/containers"
   "github.com/containerd/containerd/v2/core/events"
   "github.com/containerd/containerd/v2/core/snapshots"
   "github.com/containerd/containerd/v2/pkg/oci"
   ocispec "github.com/opencontainers/image-spec/specs-go/v1"
   "github.com/opencontainers/runtime-spec/specs-go"
)

// ---------------------------------------------------------------------------
// Fakes (no containerd daemon involved)
// ---------------------------------------------------------------------------

// recordingClient is a containerClient fake that records the construction
// parameters the factory hands to containerd. GetImage returns a nil image on
// purpose: buildContainer only closes over the image in the NewContainer opts
// (it never dereferences it), so the recording test can assert the image is
// referenced BY NAME without materializing a containerd.Image.
type recordingClient struct {
   getImageNames      []string
   newContainerIDs    []string
   newContainerOptCnt []int
}

func (r *recordingClient) GetImage(_ context.Context, ref string) (containerd.Image, error) {
   r.getImageNames = append(r.getImageNames, ref)
   return nil, nil
}

func (r *recordingClient) NewContainer(_ context.Context, id string, opts ...containerd.NewContainerOpts) (containerd.Container, error) {
   r.newContainerIDs = append(r.newContainerIDs, id)
   r.newContainerOptCnt = append(r.newContainerOptCnt, len(opts))
   return nil, nil
}

func (r *recordingClient) LoadContainer(_ context.Context, _ string) (containerd.Container, error) {
   return nil, nil
}

func (r *recordingClient) Subscribe(_ context.Context, _ ...string) (<-chan *events.Envelope, <-chan error) {
   return nil, nil
}

// fakeImage implements the two-method oci.Image interface (Config +
// ContentStore) used by oci.WithImageConfig. Config returns a descriptor whose
// blob, when read back through the fake content store, is the JSON-serialized
// ocispec.Image the test wants the spec to be seeded from.
type fakeImage struct {
   config ocispec.Descriptor
   blob   []byte
}

func (i *fakeImage) Config(context.Context) (ocispec.Descriptor, error) { return i.config, nil }
func (i *fakeImage) ContentStore() content.Store                        { return &fakeContentStore{blob: i.blob} }

func imageWithConfig(t *testing.T, img ocispec.Image) *fakeImage {
   t.Helper()
   blob, err := json.Marshal(img)
   if err != nil {
      t.Fatalf("marshalling fake image config: %v", err)
   }
   return &fakeImage{
      config: ocispec.Descriptor{
         MediaType: ocispec.MediaTypeImageConfig,
         Size:      int64(len(blob)),
      },
      blob: blob,
   }
}

// fakeContentStore satisfies content.Store by embedding a nil Store and
// overriding only ReaderAt — the one method oci.WithImageConfig exercises
// (via content.ReadBlob) to read the image config blob.
type fakeContentStore struct {
   content.Store
   blob []byte
}

func (s *fakeContentStore) ReaderAt(context.Context, ocispec.Descriptor) (content.ReaderAt, error) {
   return &bytesReaderAt{Reader: bytes.NewReader(s.blob), size: int64(len(s.blob))}, nil
}

type bytesReaderAt struct {
   *bytes.Reader
   size int64
}

func (r *bytesReaderAt) Size() int64         { return r.size }
func (r *bytesReaderAt) Close() error        { return nil }

// fakeOCIClient satisfies oci.Client. WithImageConfig's user/GID handling
// only calls SnapshotService when the container has a snapshotter set; the
// tests pass a container without one, so a nil snapshotter is never reached.
type fakeOCIClient struct{}

func (fakeOCIClient) SnapshotService(string) snapshots.Snapshotter { return nil }

// newTestFactory wires a ContainerFactory exactly as main.go does, but with a
// pluggable client so tests can record or fake the containerd surface.
func newTestFactory(client containerClient) *ContainerFactory {
   return &ContainerFactory{
      client: client,
      stageNames: map[string]StageName{
         "normalize":           StageNormalize,
         "scale-and-egress":    StageScaleAndEgress,
         "single-stage-egress": StageSingleStageEgress,
      },
      gracefulStopTimeout: time.Minute,
      layout:              DefaultLayout("/mnt/nvme"),
   }
}

// containerdDefaultUnixCaps mirrors containerd's defaultUnixCaps
// (pkg/oci/spec.go). A generated spec starts from these before the factory's
// CAP_SYS_NICE is added; the assembly ctr_fill_spec must reproduce the same
// baseline plus the addition.
var containerdDefaultUnixCaps = []string{
   "CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_FSETID", "CAP_FOWNER", "CAP_MKNOD",
   "CAP_NET_RAW", "CAP_SETGID", "CAP_SETUID", "CAP_SETFCAP", "CAP_SETPCAP",
   "CAP_NET_BIND_SERVICE", "CAP_SYS_CHROOT", "CAP_KILL", "CAP_AUDIT_WRITE",
}

// defaultSpecWithCgroups seeds the OCI spec the way containerd's
// oci.GenerateSpec would before the factory's spec opts are applied: default
// caps, a PID/IPC/UTS/Mount/Network namespace set, and
// Linux.CgroupsPath = filepath.Join("/", namespace, containerID). Root points
// at an existing absolute directory (t.TempDir()) so WithImageConfig's
// additional-GID lookup can read a rootfs without an /etc/group.
func defaultSpecWithCgroups(t *testing.T, containerID string) *specs.Spec {
   t.Helper()
   return &specs.Spec{
      Version: specs.Version,
      Root:    &specs.Root{Path: t.TempDir()},
      Process: &specs.Process{
         Cwd: "/",
         Capabilities: &specs.LinuxCapabilities{
            Bounding:  slices.Clone(containerdDefaultUnixCaps),
            Permitted: slices.Clone(containerdDefaultUnixCaps),
            Effective: slices.Clone(containerdDefaultUnixCaps),
         },
      },
      Linux: &specs.Linux{
         CgroupsPath: filepath.Join("/", "strimserver", containerID),
         Namespaces: []specs.LinuxNamespace{
            {Type: specs.PIDNamespace},
            {Type: specs.IPCNamespace},
            {Type: specs.UTSNamespace},
            {Type: specs.MountNamespace},
            {Type: specs.NetworkNamespace},
         },
      },
   }
}

// ---------------------------------------------------------------------------
// Mount lists — the ctr_fill_mounts oracle
// ---------------------------------------------------------------------------

func TestFFmpegMounts(t *testing.T) {
   layout := DefaultLayout("/mnt/nvme")
   want := []Mount{
      {Src: "/mnt/nvme/config/strimserver.env", Dst: ctrEnv},
      {Src: "/mnt/nvme/bin/transcode.sh", Dst: ctrTranscode},
      {Src: "/run/systemd/resolve/resolv.conf", Dst: ctrResolvConf},
      {Src: "/tmp", Dst: ctrTmp, ReadWrite: true},
   }
   got := ffmpegMounts(layout)
   if !reflect.DeepEqual(got, want) {
      t.Errorf("ffmpegMounts:\n got %#v\nwant %#v", got, want)
   }
}

func TestMediaMTXMounts(t *testing.T) {
   layout := DefaultLayout("/mnt/nvme")
   want := []Mount{
      {Src: "/mnt/nvme/config/strimserver.env", Dst: ctrEnv},
      {Src: "/mnt/nvme/config/mediamtx.yaml.template", Dst: ctrMediaMTXTmpl},
      {Src: "/mnt/nvme/bin/notify.sh", Dst: ctrNotify},
      {Src: "/mnt/nvme/srt-passphrase", Dst: ctrSrtSecret},
      {Src: "/mnt/nvme/video-files", Dst: ctrVideoDir, ReadWrite: true},
      {Src: "/tmp", Dst: ctrTmp, ReadWrite: true},
   }
   got := mediamtxMounts(layout)
   if !reflect.DeepEqual(got, want) {
      t.Errorf("mediamtxMounts:\n got %#v\nwant %#v", got, want)
   }
}

func TestToOCIMounts(t *testing.T) {
   got := toOCIMounts([]Mount{
      {Src: "/a", Dst: "/b"},
      {Src: "/c", Dst: "/d", ReadWrite: true},
   })
   want := []specs.Mount{
      {Type: "bind", Source: "/a", Destination: "/b", Options: []string{"rbind", "ro"}},
      {Type: "bind", Source: "/c", Destination: "/d", Options: []string{"rbind", "rw"}},
   }
   if !reflect.DeepEqual(got, want) {
      t.Errorf("toOCIMounts:\n got %#v\nwant %#v", got, want)
   }
}

// ---------------------------------------------------------------------------
// Stage argv — stage name vs container id (cgroups path derives from the
// container id; transcode.sh switches on the stage name)
// ---------------------------------------------------------------------------

func TestStageArgv(t *testing.T) {
   f := newTestFactory(nil)
   cases := []struct {
      name string
      cfg  ContainerConfig
      want []string
   }{
      {
         name: "scale-and-egress maps to underscore stage name",
         cfg:  ContainerConfig{ContainerID: "scale-and-egress"},
         want: []string{ctrTranscode, "scale_and_egress"},
      },
      {
         name: "single-stage-egress maps to underscore stage name",
         cfg:  ContainerConfig{ContainerID: "single-stage-egress"},
         want: []string{ctrTranscode, "single_stage_egress"},
      },
      {
         name: "normalize stage name equals container id",
         cfg:  ContainerConfig{ContainerID: "normalize"},
         want: []string{ctrTranscode, "normalize"},
      },
      {
         name: "unknown container id falls back to the id itself",
         cfg:  ContainerConfig{ContainerID: "unknown-stage"},
         want: []string{ctrTranscode, "unknown-stage"},
      },
   }
   for _, tc := range cases {
      t.Run(tc.name, func(t *testing.T) {
         got := f.stageArgv(tc.cfg)
         if !slices.Equal(got, tc.want) {
            t.Errorf("stageArgv(%q) = %q; want %q", tc.cfg.ContainerID, got, tc.want)
         }
      })
   }
}

// ---------------------------------------------------------------------------
// OCI spec — the ctr_fill_spec oracle (env, args, host network, caps, mounts,
// cgroups path)
// ---------------------------------------------------------------------------

func TestBaseSpecOptsMediaMTXSpec(t *testing.T) {
   layout := DefaultLayout("/mnt/nvme")
   img := imageWithConfig(t, ocispec.Image{
      Config: ocispec.ImageConfig{
         Env:        []string{"STRIMSERVER_SRT_PORT=9000", "STRIMSERVER_RTSP_PORT=8554"},
         Entrypoint: []string{"/mediamtx"},
         Cmd:        []string{"--api", "yes"},
         WorkingDir: "/workspace",
      },
   })

   spec := defaultSpecWithCgroups(t, "mediamtx")
   if err := oci.ApplyOpts(context.Background(), fakeOCIClient{},
      &containers.Container{ID: "mediamtx"}, spec,
      baseSpecOpts(img, mediamtxMounts(layout))...); err != nil {
      t.Fatalf("applying factory spec opts: %v", err)
   }

   // Env comes exactly from the image config (WithImageConfig).
   wantEnv := []string{"STRIMSERVER_SRT_PORT=9000", "STRIMSERVER_RTSP_PORT=8554"}
   if !slices.Equal(spec.Process.Env, wantEnv) {
      t.Errorf("Process.Env = %q; want %q", spec.Process.Env, wantEnv)
   }

   // Args = image Entrypoint + Cmd; mediamtx gets no WithProcessArgs.
   if !slices.Equal(spec.Process.Args, []string{"/mediamtx", "--api", "yes"}) {
      t.Errorf("Process.Args = %q; want [\"/mediamtx\" \"--api\" \"yes\"]", spec.Process.Args)
   }

   // Cwd from the image config.
   if spec.Process.Cwd != "/workspace" {
      t.Errorf("Process.Cwd = %q; want \"/workspace\"", spec.Process.Cwd)
   }

   // Host networking: the network namespace is removed from the spec.
   for _, ns := range spec.Linux.Namespaces {
      if ns.Type == specs.NetworkNamespace {
         t.Errorf("spec still contains %q namespace; WithHostNamespace must remove it (host network)", ns.Type)
      }
   }

   // CAP_SYS_NICE added on top of the containerd default baseline.
   for _, set := range []struct{ name string; caps []string }{
      {"Bounding", spec.Process.Capabilities.Bounding},
      {"Permitted", spec.Process.Capabilities.Permitted},
      {"Effective", spec.Process.Capabilities.Effective},
   } {
      if !slices.Contains(set.caps, "CAP_SYS_NICE") {
         t.Errorf("Capabilities.%s missing CAP_SYS_NICE: %q", set.name, set.caps)
      }
   }

   // The full bind-mount list, exactly as ctr_fill_mounts must emit it.
   wantMounts := []specs.Mount{
      {Type: "bind", Source: layout.Env, Destination: ctrEnv, Options: []string{"rbind", "ro"}},
      {Type: "bind", Source: layout.MediaMTXTmpl, Destination: ctrMediaMTXTmpl, Options: []string{"rbind", "ro"}},
      {Type: "bind", Source: layout.Notify, Destination: ctrNotify, Options: []string{"rbind", "ro"}},
      {Type: "bind", Source: layout.SrtPass, Destination: ctrSrtSecret, Options: []string{"rbind", "ro"}},
      {Type: "bind", Source: layout.VideoDir, Destination: ctrVideoDir, Options: []string{"rbind", "rw"}},
      {Type: "bind", Source: layout.Tmp, Destination: ctrTmp, Options: []string{"rbind", "rw"}},
   }
   if !reflect.DeepEqual(spec.Mounts, wantMounts) {
      t.Errorf("spec.Mounts:\n got %#v\nwant %#v", spec.Mounts, wantMounts)
   }

   // Cgroups path is derived from the container ID (mediamtx) by containerd's
   // GenerateSpec: filepath.Join("/", namespace, containerID).
   wantCgroups := filepath.Join("/", "strimserver", "mediamtx")
   if spec.Linux.CgroupsPath != wantCgroups {
      t.Errorf("Linux.CgroupsPath = %q; want %q", spec.Linux.CgroupsPath, wantCgroups)
   }
}

func TestBaseSpecOptsFFmpegSpec(t *testing.T) {
   layout := DefaultLayout("/mnt/nvme")
   img := imageWithConfig(t, ocispec.Image{
      Config: ocispec.ImageConfig{Env: []string{"FFMPEG_LOG_LEVEL=info"}},
   })

   // The container id is "scale-and-egress" (cgroups path) while the argv
   // carries the stage name "scale_and_egress" — the exact distinction the
   // assembly port must preserve.
   spec := defaultSpecWithCgroups(t, "scale-and-egress")
   opts := append(baseSpecOpts(img, ffmpegMounts(layout)),
      oci.WithProcessArgs(ctrTranscode, "scale_and_egress"))
   if err := oci.ApplyOpts(context.Background(), fakeOCIClient{},
      &containers.Container{ID: "scale-and-egress"}, spec, opts...); err != nil {
      t.Fatalf("applying factory spec opts: %v", err)
   }

   if !slices.Equal(spec.Process.Args, []string{ctrTranscode, "scale_and_egress"}) {
      t.Errorf("Process.Args = %q; want [%q \"scale_and_egress\"]", spec.Process.Args, ctrTranscode)
   }
   if spec.Linux.CgroupsPath != filepath.Join("/", "strimserver", "scale-and-egress") {
      t.Errorf("Linux.CgroupsPath = %q; want %q (container id, not stage name)",
         spec.Linux.CgroupsPath, filepath.Join("/", "strimserver", "scale-and-egress"))
   }

   wantMounts := []specs.Mount{
      {Type: "bind", Source: layout.Env, Destination: ctrEnv, Options: []string{"rbind", "ro"}},
      {Type: "bind", Source: layout.Transcode, Destination: ctrTranscode, Options: []string{"rbind", "ro"}},
      {Type: "bind", Source: layout.ResolvConf, Destination: ctrResolvConf, Options: []string{"rbind", "ro"}},
      {Type: "bind", Source: layout.Tmp, Destination: ctrTmp, Options: []string{"rbind", "rw"}},
   }
   if !reflect.DeepEqual(spec.Mounts, wantMounts) {
      t.Errorf("spec.Mounts:\n got %#v\nwant %#v", spec.Mounts, wantMounts)
   }
}

func TestBaseSpecOptsDefaultUnixEnvFallback(t *testing.T) {
   // An image config with no Env falls back to containerd's defaultUnixEnv
   // (pkg/oci/spec.go) inside WithImageConfig.
   img := imageWithConfig(t, ocispec.Image{Config: ocispec.ImageConfig{}})
   spec := defaultSpecWithCgroups(t, "normalize")
   if err := oci.ApplyOpts(context.Background(), fakeOCIClient{},
      &containers.Container{ID: "normalize"}, spec,
      baseSpecOpts(img, ffmpegMounts(DefaultLayout("/mnt/nvme")))...); err != nil {
      t.Fatalf("applying factory spec opts: %v", err)
   }
   want := []string{"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"}
   if !slices.Equal(spec.Process.Env, want) {
      t.Errorf("Process.Env = %q; want defaultUnixEnv %q", spec.Process.Env, want)
   }
}

// ---------------------------------------------------------------------------
// Snapshot selection + client construction — the factory must resolve the
// image by name and create the container against an image-populated snapshot
// (never an empty parent), with the env-spec snapshot id and container id.
// ---------------------------------------------------------------------------

func TestCreateMediaMTXContainerConstruction(t *testing.T) {
   fake := &recordingClient{}
   f := newTestFactory(fake)

   if _, err := f.CreateMediaMTXContainer(
      context.Background(), "mediamtx", "mediamtx-snapshot", "docker.io/library/mediamtx:latest"); err != nil {
      t.Fatalf("CreateMediaMTXContainer: %v", err)
   }

   if !slices.Equal(fake.getImageNames, []string{"docker.io/library/mediamtx:latest"}) {
      t.Errorf("GetImage called with %q; want [%q]", fake.getImageNames, "docker.io/library/mediamtx:latest")
   }
   if !slices.Equal(fake.newContainerIDs, []string{"mediamtx"}) {
      t.Errorf("NewContainer called with ids %q; want [\"mediamtx\"]", fake.newContainerIDs)
   }
   if !slices.Equal(fake.newContainerOptCnt, []int{2}) {
      t.Errorf("NewContainer received %v opts; want 2 per call (WithNewSnapshot + WithNewSpec)", fake.newContainerOptCnt)
   }
}

func TestCreateFFmpegContainerConstruction(t *testing.T) {
   fake := &recordingClient{}
   f := newTestFactory(fake)

   if _, err := f.CreateFFmpegContainer(
      context.Background(), "normalize", "normalize-snapshot", "docker.io/library/ffmpeg:latest",
      ctrTranscode, string(StageNormalize)); err != nil {
      t.Fatalf("CreateFFmpegContainer: %v", err)
   }

   if !slices.Equal(fake.getImageNames, []string{"docker.io/library/ffmpeg:latest"}) {
      t.Errorf("GetImage called with %q; want [%q]", fake.getImageNames, "docker.io/library/ffmpeg:latest")
   }
   if !slices.Equal(fake.newContainerIDs, []string{"normalize"}) {
      t.Errorf("NewContainer called with ids %q; want [\"normalize\"]", fake.newContainerIDs)
   }
   if !slices.Equal(fake.newContainerOptCnt, []int{2}) {
      t.Errorf("NewContainer received %v opts; want 2 per call (WithNewSnapshot + WithNewSpec)", fake.newContainerOptCnt)
   }
}

func TestCreateMediaMTXContainerSnapshotReferencesImage(t *testing.T) {
   // The rootfs snapshot must be populated FROM the image, never empty: the
   // factory has to resolve the image by name before NewContainer can build
   // the WithNewSnapshot(snapshotID, image) parent chain. This is the exact
   // property that was broken in the assembly port (empty parent): a factory
   // that stopped referencing the image would stop calling GetImage and this
   // test would fail.
   fake := &recordingClient{}
   f := newTestFactory(fake)

   if _, err := f.CreateMediaMTXContainer(
      context.Background(), "mediamtx", "mediamtx-snapshot", "docker.io/library/mediamtx:latest"); err != nil {
      t.Fatalf("CreateMediaMTXContainer: %v", err)
   }

   if len(fake.getImageNames) != 1 {
      t.Fatalf("factory did not resolve the image before NewContainer (snapshot would be empty-parented); GetImage calls = %v", fake.getImageNames)
   }
   if fake.getImageNames[0] != "docker.io/library/mediamtx:latest" {
      t.Errorf("GetImage called with %q; want %q", fake.getImageNames[0], "docker.io/library/mediamtx:latest")
   }
}

func TestNewContainerFactoryValidation(t *testing.T) {
   if _, err := NewContainerFactory(nil, nil, time.Minute, DefaultLayout("/mnt/nvme")); err == nil {
      t.Error("NewContainerFactory with nil client: expected error, got nil")
   }
   if _, err := NewContainerFactory(
      &containerd.Client{}, map[string]StageName{"id": ""}, time.Minute, DefaultLayout("/mnt/nvme")); err == nil {
      t.Error("NewContainerFactory with empty stage name: expected error, got nil")
   }
}