// ============================================================================
// diffcontainerd/oracle.go — the Go oracle for the containerd differential
// harness (differential-containerd.sh).
//
// This is the GO side of the harness.  It reads the same shared stage
// config (stages.conf) as the x86-64 asm driver (driver.c) and emits the
// OCI records the Go controller's container_factory.go would build for each
// stage — byte-for-byte in the same canonical format as the driver:
//
//	kind=mediamtx
//	n_env=1
//	env[0]=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
//	n_args=1
//	args[0]=/entrypoint.sh
//	cwd=/
//	uid=0
//	gid=0
//	n_gids=0
//	n_caps=1
//	caps[0]=CAP_SYS_NICE
//	host_network=1
//	cgroups=/strimserver/mediamtx
//	n_mounts=6
//	mount[0].destination=/strimserver.env
//	mount[0].source=/mnt/nvme/config/strimserver.env
//	mount[0].type=bind
//	mount[0].n_options=2
//	mount[0].options[0]=rbind
//	mount[0].options[1]=ro
//	...
//
// WHAT IT REPLICATES (the exact Go controller construction, see
// core/controller/container_factory.go + the containerd oci package):
//
//   - mounts: toOCIMounts(mounts) — Type="bind", Options=["rbind","ro"] or
//     ["rbind","rw"], one record per controller bind mount in the SAME
//     order as CreateMediaMTXContainer / CreateFFmpegContainer build them.
//   - env:    oci.WithImageConfig — the image config env, or defaultUnixEnv
//     (oci/spec.go:42-44) when the image config carries no env.  The
//     mediamtx image sets no env (core/BUILD.bazel), so it gets
//     defaultUnixEnv = [PATH=...]; the ffmpeg image env is the amd64
//     genrule env (core/BUILD.bazel:580): NVIDIA_VISIBLE_DEVICES=all,
//     NVIDIA_DRIVER_CAPABILITIES=compute,utility,video,
//     LD_LIBRARY_PATH=/usr/lib64, PATH=...
//   - args:   mediamtx = image entrypoint ["/entrypoint.sh"] (no cmd);
//     ffmpeg stages = oci.WithProcessArgs("/transcode.sh", "<stage>") —
//     the CreateStageOps argv (container_factory.go:235-240).
//   - cwd:    image WorkingDir, or "/" when unset.
//   - uid/gid: image config user; 0/0 when unset (both images set none).
//   - caps:   oci.WithAddedCapabilities(["CAP_SYS_NICE"]) → the added cap.
//   - host_network: oci.WithHostNamespace(specs.NetworkNamespace) → 1.
//   - cgroups: filepath.Join("/", ns, containerID) (populateDefaultUnixSpec).
//
// The oracle intentionally uses the same spec.Mount structure (Go field
// order: Type, Source, Destination, Options) the Go controller's
// toOCIMounts produces, and prints the same field order as the asm dump so
// any asm-vs-Go field-ORDER divergence shows up as a byte diff.
//
// Usage: oracle <stages.conf>
// Exit:  0 on success; non-zero on parse/config error.
// ============================================================================
package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// ---- container-internal mount destinations (paths.go) ---------------------
const (
	ctrEnv          = "/strimserver.env"
	ctrTranscode    = "/transcode.sh"
	ctrNotify       = "/notify.sh"
	ctrMediaMTXTmpl = "/mediamtx.yaml.template"
	ctrSrtSecret    = "/run/secrets/srt-passphrase"
	ctrVideoDir     = "/video-files"
	ctrResolvConf   = "/etc/resolv.conf"
	ctrTmp          = "/tmp"
)

// The amd64 ffmpeg image env (core/BUILD.bazel:580).  This is the env the
// x86-64 asm port targets (ctr_env_ffmpeg rodata in x86_64/cc_ctr.S).
var ffmpegImageEnv = []string{
	"NVIDIA_VISIBLE_DEVICES=all",
	"NVIDIA_DRIVER_CAPABILITIES=compute,utility,video",
	"LD_LIBRARY_PATH=/usr/lib64",
	"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
}

// defaultUnixEnv (containerd oci/spec.go:42-44) — used when the image config
// carries no env (the mediamtx image sets none in core/BUILD.bazel).
var defaultUnixEnv = []string{
	"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
}

// ---- Mount (container_factory.go:51-54) + toOCIMounts (:56-69) ------------
type Mount struct {
	Src, Dst  string
	ReadWrite bool
}

func toOCIMounts(mounts []Mount) []specsMount {
	out := make([]specsMount, 0, len(mounts))
	rw, ro := []string{"rbind", "rw"}, []string{"rbind", "ro"}
	for _, mount := range mounts {
		opts := ro
		if mount.ReadWrite {
			opts = rw
		}
		out = append(out, specsMount{
			Type:        "bind",
			Source:      mount.Src,
			Destination: mount.Dst,
			Options:     opts,
		})
	}
	return out
}

// specsMount mirrors the parts of specs.Mount the controller sets, in the
// Go struct field order (Type, Source, Destination, Options).
type specsMount struct {
	Type        string
	Source      string
	Destination string
	Options     []string
}

// ---- stage config (from stages.conf) --------------------------------------
type layoutPaths struct {
	Env, Transcode, Notify, MediaMTXTmpl, SrtPass, VideoDir, ResolvConf, Tmp string
}

type containerConfig struct {
	ID, Snapshot, Image, Logfile string
}

type stageConfig struct {
	Kind      string // dump label: mediamtx | normalize | scale-and-egress | single-stage-egress
	CC        containerConfig
	StageName string // names.go StageName for the argv (underscore form:
	// "scale_and_egress" vs the container id "scale-and-egress")
}

// ---- record dump (byte-for-byte comparison surface) -----------------------
func dumpSpec(kind string, mounts []specsMount, env, args []string,
	cwd string, uid, gid uint32, nGids int, caps []string,
	hostNetwork int, cgroups string) {
	fmt.Printf("kind=%s\n", kind)
	fmt.Printf("n_env=%d\n", len(env))
	for i, e := range env {
		fmt.Printf("env[%d]=%s\n", i, e)
	}
	fmt.Printf("n_args=%d\n", len(args))
	for i, a := range args {
		fmt.Printf("args[%d]=%s\n", i, a)
	}
	fmt.Printf("cwd=%s\n", cwd)
	fmt.Printf("uid=%d\n", uid)
	fmt.Printf("gid=%d\n", gid)
	fmt.Printf("n_gids=%d\n", nGids)
	fmt.Printf("n_caps=%d\n", len(caps))
	for i, c := range caps {
		fmt.Printf("caps[%d]=%s\n", i, c)
	}
	fmt.Printf("host_network=%d\n", hostNetwork)
	fmt.Printf("cgroups=%s\n", cgroups)
	fmt.Printf("n_mounts=%d\n", len(mounts))
	for i, m := range mounts {
		fmt.Printf("mount[%d].destination=%s\n", i, m.Destination)
		fmt.Printf("mount[%d].source=%s\n", i, m.Source)
		fmt.Printf("mount[%d].type=%s\n", i, m.Type)
		fmt.Printf("mount[%d].n_options=%d\n", i, len(m.Options))
		for j, o := range m.Options {
			fmt.Printf("mount[%d].options[%d]=%s\n", i, j, o)
		}
	}
}

// ---- main ------------------------------------------------------------------
func main() {
	if len(os.Args) != 2 {
		fmt.Fprintf(os.Stderr, "usage: %s <stages.conf>\n", os.Args[0])
		os.Exit(2)
	}
	conf, err := loadConf(os.Args[1])
	if err != nil {
		fmt.Fprintf(os.Stderr, "oracle: %v\n", err)
		os.Exit(1)
	}

	layout := layoutPaths{
		Env:          conf["LAYOUT_ENV"],
		Transcode:    conf["LAYOUT_TRANSCODE"],
		Notify:       conf["LAYOUT_NOTIFY"],
		MediaMTXTmpl: conf["LAYOUT_MEDIAMTX_TMPL"],
		SrtPass:      conf["LAYOUT_SRT_PASS"],
		VideoDir:     conf["LAYOUT_VIDEO_DIR"],
		ResolvConf:   conf["LAYOUT_RESOLV_CONF"],
		Tmp:          conf["LAYOUT_TMP"],
	}
	ns := conf["NAMESPACE"]

	mediamtx := containerConfig{ID: conf["MEDIAMTX_ID"], Snapshot: conf["MEDIAMTX_SNAPSHOT"], Image: conf["MEDIAMTX_IMAGE"], Logfile: conf["MEDIAMTX_LOG"]}
	normalize := containerConfig{ID: conf["NORMALIZE_ID"], Snapshot: conf["NORMALIZE_SNAPSHOT"], Image: conf["NORMALIZE_IMAGE"], Logfile: conf["NORMALIZE_LOG"]}
	scale := containerConfig{ID: conf["SCALE_ID"], Snapshot: conf["SCALE_SNAPSHOT"], Image: conf["SCALE_IMAGE"], Logfile: conf["SCALE_LOG"]}
	single := containerConfig{ID: conf["SINGLE_ID"], Snapshot: conf["SINGLE_SNAPSHOT"], Image: conf["SINGLE_IMAGE"], Logfile: conf["SINGLE_LOG"]}

	stages := []stageConfig{
		{Kind: "mediamtx", CC: mediamtx, StageName: "mediamtx"},
		{Kind: "normalize", CC: normalize, StageName: "normalize"},
		{Kind: "scale-and-egress", CC: scale, StageName: "scale_and_egress"},
		{Kind: "single-stage-egress", CC: single, StageName: "single_stage_egress"},
	}

	for _, st := range stages {
		var mounts []Mount
		var args []string
		var env []string
		switch st.Kind {
		case "mediamtx":
			// CreateMediaMTXContainer (container_factory.go:111-125)
			mounts = []Mount{
				{Src: layout.Env, Dst: ctrEnv},
				{Src: layout.MediaMTXTmpl, Dst: ctrMediaMTXTmpl},
				{Src: layout.Notify, Dst: ctrNotify},
				{Src: layout.SrtPass, Dst: ctrSrtSecret},
				{Src: layout.VideoDir, Dst: ctrVideoDir, ReadWrite: true},
				{Src: layout.Tmp, Dst: ctrTmp, ReadWrite: true},
			}
			env = defaultUnixEnv              // mediamtx image sets no env -> defaultUnixEnv
			args = []string{"/entrypoint.sh"} // image entrypoint, no cmd
		case "normalize", "scale-and-egress", "single-stage-egress":
			// CreateFFmpegContainer (container_factory.go:95-109)
			mounts = []Mount{
				{Src: layout.Env, Dst: ctrEnv},
				{Src: layout.Transcode, Dst: ctrTranscode},
				{Src: layout.ResolvConf, Dst: ctrResolvConf},
				{Src: layout.Tmp, Dst: ctrTmp, ReadWrite: true},
			}
			env = ffmpegImageEnv // the amd64 ffmpeg image env
			// CreateStageOps argv: WithProcessArgs("/transcode.sh",
			// string(stageName)) — names.go StageName, NOT the container id.
			args = []string{ctrTranscode, st.StageName}
		}

		oci := toOCIMounts(mounts)
		cwd := "/" // both images set no WorkingDir
		cgroups := filepath.Join("/", ns, st.CC.ID)
		caps := []string{"CAP_SYS_NICE"} // oci.WithAddedCapabilities
		hostNetwork := 1                 // oci.WithHostNamespace(NetworkNamespace)

		dumpSpec(st.Kind, oci, env, args, cwd, 0, 0, 0, caps, hostNetwork, cgroups)
	}
}

// ---- stages.conf loader ----------------------------------------------------
func loadConf(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	conf := map[string]string{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			continue
		}
		k := strings.TrimSpace(line[:eq])
		v := strings.TrimSpace(line[eq+1:])
		if k != "" {
			conf[k] = v
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	required := []string{
		"LAYOUT_ENV", "LAYOUT_TRANSCODE", "LAYOUT_NOTIFY", "LAYOUT_MEDIAMTX_TMPL",
		"LAYOUT_SRT_PASS", "LAYOUT_VIDEO_DIR", "LAYOUT_RESOLV_CONF", "LAYOUT_TMP",
		"NAMESPACE",
		"MEDIAMTX_ID", "MEDIAMTX_SNAPSHOT", "MEDIAMTX_IMAGE", "MEDIAMTX_LOG",
		"NORMALIZE_ID", "NORMALIZE_SNAPSHOT", "NORMALIZE_IMAGE", "NORMALIZE_LOG",
		"SCALE_ID", "SCALE_SNAPSHOT", "SCALE_IMAGE", "SCALE_LOG",
		"SINGLE_ID", "SINGLE_SNAPSHOT", "SINGLE_IMAGE", "SINGLE_LOG",
	}
	for _, k := range required {
		if _, ok := conf[k]; !ok || conf[k] == "" {
			return nil, fmt.Errorf("missing required stage config %q", k)
		}
	}
	return conf, nil
}
