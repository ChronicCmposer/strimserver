package main

import (
   "strconv"
   "time"
)

type Group string

const (
   GroupController Group = "Controller"
   GroupStage      Group = "Stage containers"
   GroupMedia      Group = "Media / ffmpeg"
   GroupTwitch     Group = "Twitch / egress"
   GroupSecret     Group = "Secrets"
)

type EnvVar struct {
   Name     string // the environment variable name
   Group    Group  // grouping for the rendered .env.example
   Required bool   // presence-checked by -check-env
   Example  string // value written into .env.example
   Comment  string // optional one-line note above the example entry

   Bind func(cfg *Config, raw string) error
}


func bindString(field func(*Config) *string) func(*Config, string) error {
   return func(c *Config, s string) error { *field(c) = s; return nil }
}

func bindDuration(field func(*Config) *time.Duration) func(*Config, string) error {
   return func(c *Config, s string) error {
      d, err := time.ParseDuration(s)
      if err != nil {
         return err
      }
      *field(c) = d
      return nil
   }
}

func bindUint8(field func(*Config) *uint8) func(*Config, string) error {
   return func(c *Config, s string) error {
      v, err := strconv.ParseUint(s, 10, 8)
      if err != nil {
         return err
      }
      *field(c) = uint8(v)
      return nil
   }
}

func envSpec() []EnvVar {
   return []EnvVar{
      // ---------------------------------------------------------------- Controller
      {
         Name: "CONTAINERD_SOCKET", Group: GroupController, Required: true,
         Example: "/containerd.sock",
         Comment: "containerd gRPC socket the controller drives",
         Bind:    bindString(func(c *Config) *string { return &c.ContainerdSocket }),
      },
      {
         Name: "CONTAINERD_NAMESPACE", Group: GroupController, Required: true,
         Example: "strimserver",
         Bind:    bindString(func(c *Config) *string { return &c.ContainerdNamespace }),
      },
      {
         Name: "CONTROLLER_HTTP_PORT", Group: GroupController, Required: true,
         Example: "4000",
         Comment: "must match the Stream Deck plugin's base URL port",
         Bind:    bindString(func(c *Config) *string { return &c.ControllerHTTPPort }),
      },
      {
         Name: "STRIMSERVER_HOST_ROOT", Group: GroupController, Required: true,
         Example: "/mnt/nvme",
         Comment: "host dir where deploy.sh stages config/bin/video-files",
         Bind:    bindString(func(c *Config) *string { return &c.HostRoot }),
      },
      {
         Name: "CONTROLLER_RECONCILE_INTERVAL", Group: GroupController, Required: true,
         Example: "5s",
         Comment: "how often the reconcile ticker fires (Go duration)",
         Bind:    bindDuration(func(c *Config) *time.Duration { return &c.ControllerReconcileInterval }),
      },
      {
         Name: "CONTROLLER_INFLIGHT_TIMEOUT", Group: GroupController, Required: true,
         Example: "30s",
         Comment: "per-op timeout; after this an in-flight stage op is re-issued",
         Bind:    bindDuration(func(c *Config) *time.Duration { return &c.ControllerInFlightTimeout }),
      },
      {
         Name: "CONTROLLER_SHUTDOWN_TIMEOUT", Group: GroupController, Required: true,
         Example: "30s",
         Comment: "graceful HTTP shutdown budget",
         Bind:    bindDuration(func(c *Config) *time.Duration { return &c.ControllerShutdownTimeout }),
      },
      {
         Name: "STAGE_STOP_TIMEOUT", Group: GroupController, Required: true,
         Example: "10s",
         Comment: "grace period after SIGTERM before a task is force-killed",
         Bind:    bindDuration(func(c *Config) *time.Duration { return &c.StageStopTimeout }),
      },
      {
         Name: "WEBSOCKET_WRITE_TIMEOUT", Group: GroupController, Required: true,
         Example: "5s",
         Comment: "per-message write deadline on /subscribe",
         Bind:    bindDuration(func(c *Config) *time.Duration { return &c.WebsocketWriteTimeout }),
      },
      {
         Name: "CONTROLLER_ACTIONS_BUFFER_SIZE", Group: GroupController, Required: true,
         Example: "16",
         Comment: "buffered capacity of the actions channel (0-255)",
         Bind:    bindUint8(func(c *Config) *uint8 { return &c.ControllerActionsBufferSize }),
      },

      // ----------------------------------------------------------- Stage containers
      {
         Name: "MEDIAMTX_CONTAINER_ID", Group: GroupStage, Required: true,
         Example: "mediamtx",
         Bind:    bindString(func(c *Config) *string { return &c.MediaMTX.ContainerID }),
      },
      {
         Name: "MEDIAMTX_SNAPSHOT_ID", Group: GroupStage, Required: true,
         Example: "mediamtx-snapshot",
         Bind:    bindString(func(c *Config) *string { return &c.MediaMTX.SnapshotID }),
      },
      {
         Name: "MEDIAMTX_IMAGE_NAME", Group: GroupStage, Required: true,
         Example: "docker.io/library/mediamtx:latest",
         Bind:    bindString(func(c *Config) *string { return &c.MediaMTX.ImageName }),
      },
      {
         Name: "MEDIAMTX_LOG_FILE", Group: GroupStage, Required: true,
         Example: "/mnt/nvme/logs/mediamtx.log",
         Bind:    bindString(func(c *Config) *string { return &c.MediaMTX.Logfile }),
      },
      {
         Name: "NORMALIZE_CONTAINER_ID", Group: GroupStage, Required: true,
         Example: "normalize",
         Bind:    bindString(func(c *Config) *string { return &c.Normalize.ContainerID }),
      },
      {
         Name: "NORMALIZE_SNAPSHOT_ID", Group: GroupStage, Required: true,
         Example: "normalize-snapshot",
         Bind:    bindString(func(c *Config) *string { return &c.Normalize.SnapshotID }),
      },
      {
         Name: "NORMALIZE_LOG_FILE", Group: GroupStage, Required: true,
         Example: "/mnt/nvme/logs/normalize.log",
         Bind:    bindString(func(c *Config) *string { return &c.Normalize.Logfile }),
      },
      {
         Name: "EGRESS_CONTAINER_ID", Group: GroupStage, Required: true,
         Example: "scale-and-egress",
         Bind:    bindString(func(c *Config) *string { return &c.ScaleAndEgress.ContainerID }),
      },
      {
         Name: "EGRESS_SNAPSHOT_ID", Group: GroupStage, Required: true,
         Example: "scale-and-egress-snapshot",
         Bind:    bindString(func(c *Config) *string { return &c.ScaleAndEgress.SnapshotID }),
      },
      {
         Name: "EGRESS_LOG_FILE", Group: GroupStage, Required: true,
         Example: "/mnt/nvme/logs/scale-and-egress.log",
         Bind:    bindString(func(c *Config) *string { return &c.ScaleAndEgress.Logfile }),
      },
      {
         // One variable, two destinations: normalize and scale_and_egress share
         // the ffmpeg image. A struct tag could not express this; the closure can.
         Name: "FFMPEG_IMAGE_NAME", Group: GroupStage, Required: true,
         Example: "docker.io/library/ffmpeg:latest",
         Comment: "shared by the normalize and scale_and_egress stages",
         Bind: func(c *Config, s string) error {
            c.Normalize.ImageName = s
            c.ScaleAndEgress.ImageName = s
            return nil
         },
      },

      // ------------------------------------------------------------- Media / ffmpeg
      // Consumed by transcode.sh / mediamtx / the entrypoints — never by the
      // controller — so Bind is nil. Required so -check-env still guards them.
      {
         Name: "FFMPEG_NICE", Group: GroupMedia, Required: true, Example: "-5",
         Comment: "nice(1) level for the ffmpeg stages",
      },
      {
         Name: "FFMPEG_LOG_LEVEL", Group: GroupMedia, Required: true, Example: "info",
      },
      {
         Name: "MEDIAMTX_NICE", Group: GroupMedia, Required: true, Example: "-10",
      },
      {
         Name: "MEDIAMTX_CONFIG_TEMPLATE", Group: GroupMedia, Required: true,
         Example: "/mediamtx.yaml.template",
         Comment: "in-container path of the bind-mounted template (envsubst input)",
      },
      {
         Name: "STRIMSERVER_SRT_PORT", Group: GroupMedia, Required: true, Example: "9000",
         Comment: "SRT ingest port; must match the local encoder",
      },
      {
         Name: "STRIMSERVER_RTSP_PORT", Group: GroupMedia, Required: true, Example: "8554",
         Comment: "internal RTSP port the stages read from",
      },
      {
         Name: "NORMALIZED_MPEGTS_SOCKET", Group: GroupMedia, Required: true,
         Example: "/tmp/strimserver-normalized.sock",
         Comment: "unix socket: mediamtx listens, normalize ffmpeg connects",
      },
      {
         Name: "MEDIAMTX_READ_TIMEOUT_DURATION", Group: GroupMedia, Required: true,
         Example: "12s",
         Comment: ">= SRT latency + jitter + read gap",
      },
      {
         Name: "NORMALIZED_VIDEO_BITRATE", Group: GroupMedia, Required: true, Example: "9000k",
      },
      {
         Name: "NORMALIZED_VIDEO_MAXRATE", Group: GroupMedia, Required: true, Example: "9000k",
      },
      {
         Name: "NORMALIZED_VIDEO_MINRATE", Group: GroupMedia, Required: true, Example: "9000k",
      },
      {
         Name: "NORMALIZED_VIDEO_BUFSIZE", Group: GroupMedia, Required: true, Example: "9000k",
      },
      {
         Name: "NORMALIZED_AUDIO_BITRATE", Group: GroupMedia, Required: true, Example: "320k",
      },
      {
         Name: "SCALED_VIDEO_HEIGHT_PIXELS", Group: GroupMedia, Required: true, Example: "936",
         Comment: "egress output height; width is derived (-2)",
      },
      {
         Name: "EGRESS_VIDEO_BITRATE", Group: GroupMedia, Required: true, Example: "2500k",
      },
      {
         Name: "EGRESS_VIDEO_MAXRATE", Group: GroupMedia, Required: true, Example: "2500k",
      },
      {
         Name: "EGRESS_VIDEO_MINRATE", Group: GroupMedia, Required: true, Example: "2500k",
      },
      {
         Name: "EGRESS_VIDEO_BUFSIZE", Group: GroupMedia, Required: true, Example: "2500k",
      },
      {
         Name: "EGRESS_AUDIO_BITRATE", Group: GroupMedia, Required: true, Example: "160k",
      },

      // ------------------------------------------------------------- Twitch / egress
      {
         Name: "TWITCH_INGEST_SERVER", Group: GroupTwitch, Required: true,
         Example: "ingest.global-contribute.live-video.net",
      },
      {
         Name: "TWITCH_STREAM_KEY", Group: GroupTwitch, Required: true,
         Example: "live_xxxxxxxxxxxxxxxx",
         Comment: "get this from Twitch; treat as a secret",
      },
      {
         Name: "BANDWIDTH_TEST", Group: GroupTwitch, Required: true, Example: "false",
         Comment: "true appends ?bandwidthtest=true to the RTMP URL",
      },

      // -------------------------------------------------------------------- Secrets
      {
         // Not Required: the mediamtx container can instead read it from the
         // /run/secrets/srt-passphrase bind mount (see entrypoint.mediamtx.sh).
         Name: "SRT_PUBLISH_PASSPHRASE", Group: GroupSecret, Required: false,
         Example: "",
         Comment: "optional; falls back to /run/secrets/srt-passphrase if unset",
      },
   }
}
