#!/usr/bin/env bash

# TWITCH_STREAM_KEY='<STREAM_KEY>'

curl -sS -X POST 'https://ingest.twitch.tv/api/v3/GetClientConfiguration' \
  -H 'Content-Type: application/json' \
  --data-binary @- <<EOF
{
  "authentication": "${TWITCH_STREAM_KEY}",
  "capabilities": {
    "cpu": {
      "logical_cores": 16,
      "physical_cores": 8,
      "name": "AMD Ryzen 7 5800X 8-Core Processor",
      "speed": 3800
    },
    "gpu": [
      {
        "vendor_id": 4318,
        "device_id": 8712,
        "model": "NVIDIA GeForce RTX 3080 Ti",
        "driver_version": "31.0.15.5152",
        "dedicated_video_memory": 12673089536,
        "shared_system_memory": 17132537856
      }
    ],
    "memory": {
      "free": 15091892224,
      "total": 34265075712
    },
    "system": {
      "name": "Windows",
      "version": "10.0",
      "release": "23H2",
      "build": 22631,
      "revision": "3880",
      "bits": 64,
      "arm": false,
      "armEmulation": false
    },
    "gaming_features": {
      "game_bar_enabled": null,
      "game_dvr_allowed": null,
      "game_dvr_bg_recording": null,
      "game_dvr_enabled": true,
      "game_mode_enabled": null,
      "hags_enabled": false
    }
  },
  "client": {
    "name": "obs-studio",
    "version": "32.0.4",
    "supported_codecs": ["h264", "av1", "h265"]
  },
  "preferences": {
    "audio_channels": 2,
    "audio_fixed_buffering": false,
    "audio_max_buffering_ms": 960,
    "audio_samples_per_sec": 48000,
    "canvases": [
      {
        "canvas_width": 3840,
        "canvas_height": 2160,
        "width": 3840,
        "height": 2160,
        "framerate": {
          "numerator": 60,
          "denominator": 1
        }
      }
    ],
    "composition_gpu_index": 0,
    "maximum_aggregate_bitrate": null,
    "maximum_video_tracks": null,
    "vod_track_audio": true
  },
  "schema_version": "2025-01-25",
  "service": "IVS"
}
EOF
