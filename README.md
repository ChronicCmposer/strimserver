

# Okay... what do we want?

* livestreaming server
* maximize audio and video quality given twitch constraints
* use sensible, modern streaming protocols
* easily deployable via container infrastructure
* secure stream transmission and anti-leak design
* server records stream to s3 (audio unmuted)
* easy go-live
* easy end-stream

## Nice to have
* automatic stream remux?


## Misc Notes
* SRT is usually used to transfer media streams encoded with
  MPEG-TS

## ideal streaming protocol configuration

* Local OBS --[SRT]--> strimserver
    * Protocol and Container: MPEG-TS over SRT
    * Video
        * Apple VideoToolbox Hardware Encoded H.265 
        * 1080p 60fps
        * something > 6000kbps - Constant Bit Rate
    * Audio
        * ideally pcm_s24le or pcm_s16le
        * otherwise AAC-LC @ 320kbps

* strimserver --[RTMP]--> twitch
    * Protocol and Container
        * FLV over RTMP
        * 1080p 60fps
        * 6000kbps - Constant Bit Rate
    * Video
        * H.265 NVIDIA NVENC
        * https://www.nvidia.com/en-us/geforce/guides/broadcasting-guide/
    * Audio 
        * AAC-LC @ 196kbps


---

Below is a working **OBS “Custom Output (FFmpeg)”**
configuration to publish **MPEG-TS over SRT** into a
**MediaMTX** SRT listener (e.g., `:8890`) using **Apple
VideoToolbox HEVC** at **1080p60** with a bitrate >6000
kbps, and either **PCM** audio (best quality, least
interoperable) or **AAC-LC 320 kbps** (most interoperable).

The SRT publish URL form MediaMTX expects is
`srt://host:8890?streamid=publish:<name>&pkt_size=1316`.
([GitHub][1])

---

## 1) OBS UI: where to put this

**OBS → Settings → Output → Output Mode: Advanced →
Recording tab**

* **Type:** `Custom Output (FFmpeg)`
* **FFmpeg Output Type:** `Output to URL`
* **URL:** (use one of the SRT URLs below)
* **Container Format:** `mpegts`
* **Video Encoder:** `hevc_videotoolbox`
* **Audio Encoder:** `pcm_s24le` (option A) or `aac` (option
  B)
* **Video Bitrate / Audio Bitrate:** set per option below
* **Muxer Settings / Encoder Settings:** set per option
  below

This produces a live output to the URL (even though it’s
under “Recording”).

---

## 2) SRT URL to MediaMTX (caller mode publish)

Use this as the **URL**:

```text
srt://strimserver:8890?mode=caller&streamid=publish:live&pkt_size=1316&latency=400000
```

* `streamid=publish:live` publishes to the MediaMTX path
  `/live`. ([GitHub][1])
* `pkt_size=1316` is the common MPEG-TS payload sizing
  (7×188B TS packets). ([GitHub][1])
* `latency=400000` is commonly used in OBS→MediaMTX SRT
  URLs; it controls SRT buffering/reorder tolerance (higher
  = more loss recovery headroom, more delay). ([GitHub][2])

If you want SRT encryption (shared secret, not
certificates):

```text
srt://strimserver:8890?mode=caller&streamid=publish:live&pkt_size=1316&latency=400000&passphrase=YOUR_LONG_SECRET&pbkeylen=32
```

---

## 3) Video: HEVC VideoToolbox, 1080p60, “CBR-ish” > 6000
kbps

VideoToolbox hardware encoders don’t always behave like a
textbook CBR, but the standard FFmpeg “CBR constraint”
pattern is:

* `b:v = minrate = maxrate`
* set a `bufsize` (VBV buffer) ([FFmpeg][3])

### Recommended OBS fields

* **Video Bitrate:** `8000` (kbps) (or `9000`/`10000` if you
  want more headroom internally)
* **Video Encoder Settings:** put these (colon-separated
  key=val style is what OBS expects in this field):

```text minrate=8000k:maxrate=8000k:bufsize=16000k:g=120 ```

Notes:

* `g=120` gives a 2-second GOP at 60 fps (good general
  streaming behavior).
* You can raise `bufsize` (e.g., `20000k`) if you want
  smoother rate shaping.

If OBS rejects any key in that field (it can be picky), keep
only:

```text minrate=8000k:maxrate=8000k:bufsize=16000k ```

---

## 4) Audio option A: PCM (highest quality, least
interoperable)

### OBS fields

* **Audio Encoder:** `pcm_s24le` (or `pcm_s16le`)
* **Audio Bitrate:** ignored for PCM (leave blank or 0 if
  OBS requires a value)
* **Audio Encoder Settings:** usually leave empty unless you
  need to force format; you can add:

```text ar=48000:ac=2 ```

### Important caveat

PCM in MPEG-TS is *not* consistently supported across
streaming toolchains (mux/demux/playback). Even if MediaMTX
accepts it, a downstream restream/transcode step might not.
If your chain includes other components later, expect AAC to
be the safer choice.

---

## 5) Audio option B: AAC-LC @ 320 kbps (recommended for
interoperability)

### OBS fields

* **Audio Encoder:** `aac`
* **Audio Bitrate:** `320`
* **Audio Encoder Settings:**

```text profile=aac_low:ar=48000:ac=2 ```

AAC-LC is the “works everywhere” choice for TS-based
contribution workflows.

---

## 6) Muxer settings (mpegts)

Set this in **Muxer Settings**:

```text mpegts_flags=+resend_headers ```

This helps late-joiners and some receivers by periodically
repeating headers/tables in TS (useful in live TS
pipelines).

---

## 7) What MediaMTX will see

With the URL above, MediaMTX will expose:

<!--* RTMP read (if enabled): `rtmp://strimserver/live`-->
* SRT read:
  `srt://strimserver:8890?streamid=read:live&pkt_size=1316`
  …and it can record or forward as needed.

---

## Practical recommendation

* Use **AAC-LC 320k** unless you have a hard requirement for
  PCM and you’ve verified every hop can handle PCM-in-TS.
* Use **8000–10000 kbps** for 1080p60 HEVC contribution if
  you’re prioritizing quality over bandwidth (this is
  internal to your MediaMTX ingest; it does not need to
  match Twitch limits).

If you share the exact MediaMTX version and whether you plan
to **copy** audio/video downstream or **transcode** (e.g.,
to Twitch), I can tune the SRT `latency` and the GOP/bitrate
buffer parameters to minimize “reordered frames” and
dropouts in practice.

[1]: https://github.com/dm-dma/mediamtx_srt?utm_source=chatgpt.com
"dm-dma/mediamtx_srt: Ready-to-use SRT ..." 

[2]: https://github.com/bluenviron/mediamtx/issues/3091?utm_source=chatgpt.com
"SRT stream closing due to \"too many reordered frames\""

[3]: https://ffmpeg.org/ffmpeg.html?utm_source=chatgpt.com
"ffmpeg Documentation"

---

# Container Design
* Included Software
    * ffmpeg
    * ffnvcodec-headers
    * mediamtx
    * fish shell
    * other dependencies
* Base Image
    * ideally alpine ?
    * otherwise debian or amazon linux 2023 ?

## Notes
* alpine linux container image works if no included
  components depend on glibc (i.e. have musl libc versions,
  or can be compiled against musl libc)

## Questions
* Can we use alpine linux base image - given musl libc
  dependency requirement? *NO* - nvidia nvenc libraries
  require glibc 

* Where can we get the latest versions of the required
  software?
    * ffmpeg - debian apt repository
    * fish shell - debian apt repository
    * mediamtx - github releases

* How to specify software version to download from alpine
  linux apk repository?
    * apk add --no-cache ffmpeg="$FFMPEG_VERSION"

* Onto which hardware must we deploy the container if we
  want to take advantage of NVIDIA NVENC H.264 hardware
  encoding vs. x.264 software encoding?
    * Hardware encoding: g4dn.xlarge (T4 GPU)
        * approximate hourly rate: 0.526
    * Software encoding: c7i.xlarge
        * approximate hourly rate: 0.1785

* How to give alpine linux ffmpeg access to NVIDIA GPU for
  NVENC H.265 encoding - assuming containerd runtime?
    * Prerequisite: Your FFmpeg binary must be built with
      NVENC enabled
        * `ffmpeg -hide_banner -encoders | grep -E 'hevc_nvenc|h264_nvenc'`
        * `ctr run --gpus 0` 


---

## Intermediate Steps
* [x] Hello World alpine linux container (linux/amd64)
* [x] apk install fish shell && wget install mediamtx
  binaries
* [ ] create script to scoop MPEG-TS segments to s3
* [x] apk install ffmpeg and see if it has nvenc encoders?
* [x] if not, apk install build deps and build ffmpeg with
  nvenc encoders
* [x] determine host dependencies: filesystem mounts, ports,
  gpus
* [x] extract mediamtx default configuration, customize it,
  and bundle it in deployment
* [x] create aws ec2 launch template and vpc security groups
* [x] write systemd service file for strimserver container
* [x] write egress-ffmpeg.sh script to invoke ffmpeg - this
  is the one that we use to "go live" 
* [x] write deploy script 
* [x] bundle all new files in deployment
* [ ] create alwaysAvailableTrack loopable .mp4
* [ ] test alwaysAvailable configuration
* [ ] test record to disk configuration
* [x] test stream to twitch happy path
* [x] test stream to twitch fallback
* [x] tune OBS --[SRT]--> strimserver bitrate (>6000kbps)
* [x] test strimserver --[RTMP]--> twitch resilience at
  6000kbps
* [ ] maybe also consider gstreamer? 

## Out of scope
* create script to remux MPEG-TS segments to mkv (or maybe
  mp4?)

---

2026-02-10

* Recapping
    * We discovered last time that we had to build ffmpeg
      from source in order to add the h264_nvenc and
      hevc_nvenc hardware encoder support for NVIDIA GPU on
      g4dn.xlarge instance
    * Building ffmpeg from source is challenging because the
      default configuration requires a lot of build-time
      dependencies
    * We sort of made a mistake by compiling with all of the
      default flags from the ffmpeg package provided by the
      alpine linux package manager - there are a gagillion
      flags, and we spent a long time adding a gagillion dev
      dependencies

* Current problem - we build ffmpeg lib dependencies as
  dynamically-linked libraries, but when we copy those libs
  over to new alpine linux base image, the build-time libs
  are not present.
    * Solution 1: figure out how to apk add all of the
      dependencies in the runtime alpine environment ?
    * Solution 2: make ffmpeg statically-linked single
      executable ?
    * Potential improvement: disable all of the ffmpeg flags
      that won't be needed for strimserver
        * This will drastically reduce the compile time
          because we don't need most of default feature set

* Plan for today: Get ffmpeg to compile and run as a static
  executable in a minimal alpine linux container environment
    * [ ] determine set of necessary features and dev
      dependencies
    * [ ] eliminate unnecessary ones from build
    * [ ] build statically linked executable
    * [ ] copy to clean environment and test

* What do we expect this ffmpeg to be able to do?
    * accept MPEG-TS over SRT as input
        * video: Apple VideoToolbox H.264 or H.265
        * audio: AAC or LPCM pcm_s24le 
    * transcode to twitch-compatible format: FLV over RTMP
        * video: NVIDIA NVENC H.264 or H.265
        * audio: AAC @ 320kbps 

* What features need to be enabled?
    * SRT
    * MPEG-TS
    * NVIDIA NVENC hw encoders
    * AAC
    * pcm_s24le
    * FLV
    * RTMP

* What is the associated configure command to enable these
  features?

```
./configure \
  --prefix="$PWD/ffmpeg-install" \
  --disable-shared --enable-static \
  --pkg-config-flags="--static" \
  --extra-libs="-lpthread -lm" \
  --disable-doc --disable-debug \
  \
  --enable-openssl \
  --enable-libsrt \
  --enable-nvenc \
  --enable-librtmp \
  \
  --enable-protocol=rtmp \
  --enable-protocol=srt \
  \
  --enable-muxer=flv \
  --enable-muxer=mpegts \
  --enable-demuxer=flv \
  --enable-demuxer=mpegts \
  \
  --enable-encoder=aac \
  --enable-encoder=pcm_s24le \
  --enable-decoder=aac \
  --enable-decoder=pcm_s24le
```

* Okay, so what did we learn?
    * ffmpeg already has an rtmp implementation - we don't
      need to use librtmp 
    * librtmp is useful for rtmps, but twitch does not
      require rtmps
    * libsrt does not have a static library package
      available for alpine linux - so we install the .so in
      the runtime container image 

---

2026-02-13
* Use NUT container format for locally piping rawvideo and
  pcm_s24le 
* use local fifo named pipe to pass frames from OBS to
  separate ffmpeg
* MPEG-TS can't handle arbitrary encoding formats
* twitch ingest uses Amazon IVF (Interactive Video Service)
    * https://docs.aws.amazon.com/ivs/latest/LowLatencyUserGuide/streaming-config.html
    * https://help.twitch.tv/s/twitch-ingest-recommendation

---

2026-02-17
* ffmpeg 8.0+ includes "enhanced FLV v2" behavior - which
  allows multiple audio tracks in flv muxer
* obs flv muxing logic is fully independent from ffmpeg
* OBS --[Local FIFO/NUT]--> egress ffmpeg
    * 1 rawvideo 1080p60 track
    * 1 pcm_s24le live audio track ~2300 kbps
    * 1 pcm_s24le vod audio track ~2300 kbps
* local encoder ffmpeg --[SRT/MKV]--> egress ffmpeg
    * 1 HEVC 1080p60 track
    * 1 FLAC live audio track 
    * 1 FLAC vod audio track 
* egress ffmpeg --[RTMP/flv]--> twitch
    * 1 H264 1080p60 track
    * 1 AAC-LC 320 kbps live audio track
    * 1 AAC-LC 320 kbps vod audio track
* caveat: 
    * mediamtx on transcode server requires SRT/MPEG-TS
* backup idea:
    * egress ffmpeg uses SRT/MPEG-TS
    * egress ffmpeg outputs AAC-LC 320kbps instead of
      FLAC/ALAC

---

You can do this with **one FFmpeg process** that has **two
outputs**:

* Output A: **archive** the incoming MKV “as received” (no
  re-encode, keeps both audio tracks if present)
* Output B: **transcode** to Twitch ingest format (**H.264 +
  AAC in FLV over RTMP**)

Key point: options in FFmpeg are **per-output** based on
where you place them.


## 1) Single-file archive MKV + Twitch stream (common setup)

```bash 
ffmpeg -hide_banner -loglevel info \ -i
"srt://0.0.0.0:9000?mode=listener" \ \ -map 0 -c copy \ -f
matroska -strftime 1 "/recordings/raw_%Y-%m-%d_%H-%M-%S.mkv"
\ \ -map 0:v:0 -map 0:a:0 \ -c:v libx264 -preset veryfast
-profile:v high -level 4.1 -pix_fmt yuv420p \ -b:v 6000k
-maxrate 6000k -bufsize 12000k \ -g 120 -keyint_min 120 \
-c:a aac -b:a 160k -ar 48000 -ac 2 \ -f flv
"rtmp://live.twitch.tv/app/YOUR_STREAM_KEY" 
```

### What this does

* **Archive output** (first output):

  * `-map 0 -c copy` copies *everything* from the input
    (HEVC + both FLAC/ALAC tracks + metadata) into MKV.
* **Twitch output** (second output):

  * Picks **video 0** and **audio 0** only (`-map 0:v:0 -map
    0:a:0`)
  * Transcodes to **H.264/AAC** and pushes to Twitch via
    RTMP.

Notes:

* Twitch ingest does **not** accept HEVC or FLAC/ALAC, and
  doesn’t want multiple audio tracks in FLV. You must pick
  one track or mix them.
* `-g 120` assumes ~60 fps (2-second GOP). If 30 fps, use
  `-g 60`. (Or set `-r` explicitly if your input rate is
  unstable.)


## 2) Hourly (or N-minute) segmented MKV archive
(recommended for long runs)

Avoid a single giant file; segment the archive while still
streaming to Twitch:

```bash 
ffmpeg -hide_banner -loglevel info \ -i
"srt://0.0.0.0:9000?mode=listener" \ \ -map 0 -c copy \ -f
segment -segment_time 3600 -reset_timestamps 1 \
-segment_format matroska -strftime 1 \
"/recordings/raw_%Y-%m-%d_%H-00-00.mkv" \ \ -map 0:v:0 -map
0:a:0 \ -c:v libx264 -preset veryfast -profile:v high -level
4.1 -pix_fmt yuv420p \ -b:v 6000k -maxrate 6000k -bufsize
12000k \ -g 120 -keyint_min 120 \ -c:a aac -b:a 160k -ar
48000 -ac 2 \ -f flv
"rtmp://live.twitch.tv/app/YOUR_STREAM_KEY"
```


## 3) If you need to choose the “other” audio track for
Twitch

Change `-map 0:a:0` to `-map 0:a:1` on the Twitch output.

If you need to **mix** both stereo tracks into one stereo
track for Twitch (common if they’re different languages or
mixes), you can do:

```bash 
-filter_complex
"[0:a:0][0:a:1]amix=inputs=2:normalize=0[aout]" \ -map 0:v:0
-map "[aout]" 
```

(Keep archive output as `-map 0 -c copy` unchanged.)


## 4) Operational tips

* Put the **archive output first** so even if the Twitch
  RTMP handshake stalls/reconnects, your archival copy is
  still being written (FFmpeg still can stop on output
  failure depending on errors; if RTMP instability is
  expected, consider `-reconnect 1 -reconnect_streamed 1
  -reconnect_delay_max 5` on the RTMP URL in some builds, or
  supervise FFmpeg with a service manager).
* Ensure your disk can handle sustained writes (MKV copy is
  basically “input bitrate to disk”).
* If the input sometimes has timestamp issues, try adding
  `-fflags +genpts` right after ffmpeg and before `-i`.
---


2026-02-20

Okay, so where are we...? so far we have:

* Local OBS Configuration configured to output in formats
  that are as 'raw' as possible
    * Color Format: BGRA (8-bit)
    * Color Space: Rec. 709 (bt709)
    * Color Range: Full / PC
    * Video Resolution/FR: 1080p60
    * Video Codec: None (rawvideo)
    * Audio Codec: None (pcm_s24le)
    * Container Format: NUT (ffmpeg-native format)
    * Output to URL: local macos FIFO / named pipe
        * The FIFO is created *FIRST* - before OBS begins to
          write to it
        * The FIFO isn't a real file on the file system
        * It just helps to facilitate passing data between
          programs through memory 

* Local ffmpeg encoder service configured to compress raw
  OBS audio and video AND to stream directly to twitch
  ingest over RTMP
    * Input: local macos FIFO / named pipe - populated by
      OBS realtime raw output
    * Output Color Format: yuv420p
    * Output Color Space: Rec. 709 (bt709)
    * Output Color Range: Limited / TV
    * Output Resolution/FR: 1080p60
    * Video Codec: h264_videotoolbox (Apple HW Accel H.264)
        * update to hevc_videotoolbox
    * Video Bitrate: 5667kbps (constant)
        * update to 12000kbps (constant)
    * Video Encoder Profile: main (H.264)
        * update to main (H.265/HEVC)
    * Video Encoder Level: 4.2 (H.264)
        * update to 4.1 (H.265/HEVC)
    * Video Coder: CABAC - Context-Adaptive Binary Arithmetic Coding 
    * Video Keyframe Interval: 120 (2 seconds @ 60fps)
    * Audio Codec: AAC-LC 
    * Audio Bitrate: 320kbps (constant)
    * Audio Sample Rate: 48kHz
    * Audio Channel Configuration: 1 Stereo Pair
    * Container Format: FLV (possibly Extended FLV v2) 
    * Transmission Protocol: RTMP
    * Target Endpoint: IVS USE2 (Amazon Interactive Video
      Service)


## Intermediate Steps
* [x] Hello World alpine linux container (linux/amd64)
* [x] apk install fish shell && wget install mediamtx
  binaries
* [ ] create script to scoop MPEG-TS segments to s3
* [x] apk install ffmpeg and see if it has nvenc encoders?
* [x] if not, apk install build deps and build ffmpeg with
  nvenc encoders
* [x] determine host dependencies: filesystem mounts, ports,
  gpus
* [ ] extract mediamtx default configuration, customize it,
  and bundle it in deployment
* [ ] create aws ec2 launch template and vpc security groups
* [ ] write systemd service file for strimserver container
* [ ] write systemd service file for ffmpeg twitch relay -
  this one is the one that we use to "go live" 
* [ ] write deploy script 
* [ ] bundle all new files in deployment
* [ ] create alwaysAvailableTrack loopable .mp4
* [ ] test alwaysAvailable configuration
* [ ] test record to disk configuration
* [ ] test stream to twitch happy path
* [ ] test stream to twitch fallback
* [ ] tune OBS --[SRT]--> strimserver bitrate (>6000kbps)
* [ ] test strimserver --[RTMP]--> twitch resilience at
  6000kbps
* [ ] maybe also consider gstreamer? 

Host Dependencies:

* Running on g4dn.xlarge (T4 GPU)
    * Tell container runtime to provide GPU within container
        * Hardware encoding: --gpus 0, --device nvidia.com/gpu=0 
    * Expose port 9000
        * ctr: --net-host
        * Security Group: allow inbound UDP 9000 (for SRT)
    * filesystem mounts:
        * need mount for video output from mediamtx
        * see mediamtx configuration: https://mediamtx.org/docs/usage/record 
        * maybe ask the AI to figure this out
          (configuration)
        * need to mount host /mnt/nvme/video_files to
          container /opt/video_files
        * --mount type=bind,src=/mnt/nvme/video_files,dst=/opt/video_files,options=rbind:rw \

----

MediaMTX configuration
* [ ] listen and ingest SRT stream
    * latency, and other SRT params  
* [ ] recordings
    * segmented
    * saved to /opt/video_files
    * MPEG-TS or MKV
* [ ] always available configuration
* [ ] global configs

----

Rust (+ I get to use an LLM to build it)
* Handle ingest (SRT Stream)
* Save stream segments
* Host remuxed stream (always available)
* Transcode (hardware accelerated) and output egress to
  twitch (RTMP)

(honorable mention: C)

----

In SRT, the stream ID is a string that is sent to the remote
part in order to advertise what action the caller is gonna
do (publish or read), the path and the credentials
* action (publish or read)
* path
* credentials
* latency
* pkt_size

srt://host:8890?streamid=publish:<name>&pkt_size=1316
srt://strimserver:9000?streamid=read:live&pkt_size=1316
srt://strimserver:8890?mode=caller&streamid=publish:live&pkt_size=1316&latency=400000

---

Local Encoder SRT URL
* srt://<MEDIAMTX_IP_ADDRESS>:9000?streamid=publish:live&pkt_size=<PKT_SIZE>&latency=<LATENCY>

MediaMTX


---

NOTE: Latency units are different based on the
implementation:


Usually **milliseconds** for native SRT/libSRT URL
parameters (`srt://...?...&latency=...`).

* SRT ecosystem docs and parameter references commonly
  describe `latency` as **milliseconds** (default often
  cited as `120 ms`). ([GitHub][1])

### Important gotcha (FFmpeg / OBS syntax)

If you are setting SRT options through **FFmpeg-based
tools** (including many OBS workflows), the `latency` option
is often interpreted as **microseconds** (`μs`) in the URL
layer used by FFmpeg wrappers, so:

* `120 ms` = `120000`
* `1 s` = `1000000` This is a common source of confusion in
  guides. ([kindlivecast.com][2])

## Quick rule

* **MediaMTX / libSRT-native style params** → assume
  **milliseconds**
* **FFmpeg/OBS custom URL options** → verify, often
  **microseconds**

If you want, I can map your exact URL (MediaMTX
reader/publisher, ffmpeg command, or OBS field) and tell you
the correct unit for that specific case.

[1]:
https://github.com/ossrs/srs/wiki/migrate_v5_EN_srt-params?utm_source=chatgpt.com
"migrate_v5_EN_srt params · ossrs/srs Wiki" [2]:
https://www.kindlivecast.com/news/streaming-with-srt-or-rist-protocols/?utm_source=chatgpt.com
"News - Streaming With SRT Or RIST Protocols"



When you feed these 1316-byte units into SRT it will send
them to the other side, applying a configurable delay known
as "latency". This is an extra amount of time that a packet
will have to spend in the "anteroom" on the receiving side
before it is delivered to the output. This time should cover
both any unexpected transmission delays for a UDP packet, as
well as allowing extra time for the case where a packet is
lost and has to be retransmitted. Every UDP packet carrying
an SRT packet has a timestamp, which is grabbed at the time
when the packet is passed to SRT for sending. Using that
timestamp the appropriate delay is applied before delivering
to the output. This ensures that the time intervals between
two consecutive packets at the delivery application are
identical to the intervals between these same packets at the
moment they were passed to SRT for streaming.


---


For **same-host (local) handoff from MediaMTX → ffmpeg
egress**, **RTSP is usually the better option for fastest
turnaround**.

## Why RTSP is usually better locally

MediaMTX explicitly notes that **RTSP itself does not
introduce latency**; latency is usually added by the
**client buffer** (e.g., VLC/FFmpeg tuning), not the
protocol itself. ([MediaMTX][1])

By contrast, SRT is designed for unreliable networks and
includes **retransmission + receiver buffering / negotiated
latency**, which is exactly what you want over the public
internet—but often unnecessary on localhost. MediaMTX also
describes SRT as providing retransmission/integrity and
commonly carrying MPEG-TS. ([MediaMTX][1])

## SRT vs RTSP for your specific egress ffmpeg-on-same-host
case

### Read via **SRT**
(`srt://127.0.0.1:8890?streamid=read:mystream`)

**Pros**

* Robust on lossy/jittery links (retransmissions, negotiated
  latency). ([MediaMTX][1])
* Good if you want a consistent SRT-only operational model
  end-to-end.
* Natural fit if your downstream tooling expects MPEG-TS
  over SRT. MediaMTX documents SRT read URLs and notes SRT
  is usually used with MPEG-TS. ([MediaMTX][1])

**Cons (for localhost)**

* Adds complexity you probably don’t need (latency settings,
  SRT negotiation).
* Can add buffering / delay depending on `latency` settings
  and negotiation behavior. ([srtlab.github.io][2])
* Typically narrower codec/container path than RTSP in
  practice (MediaMTX’s compatibility matrix shows RTSP
  supports a broader set of codecs/transport variants).
  ([MediaMTX][1])

### Read via **RTSP** (`rtsp://127.0.0.1:8554/mystream`)

**Pros**

* Very low-latency locally; protocol itself doesn’t add
  latency. ([MediaMTX][1])
* Broad codec and transport compatibility in MediaMTX (UDP,
  TCP, multicast, RTSPS). ([MediaMTX][1])
* Easy to control ffmpeg behavior (`-rtsp_transport tcp` or
  `udp`); FFmpeg supports both for RTSP demuxing.
  ([FFmpeg][3])

**Cons**

* If using RTSP/UDP, more sockets/ports and possible packet
  reordering behavior (less of an issue on localhost);
  FFmpeg RTSP demuxer has UDP reordering/buffering behavior
  to manage network issues. ([FFmpeg][3])
* RTSP/TCP can suffer head-of-line blocking on bad networks
  (not usually relevant on loopback/local host).

## Best option for **fast local turnaround**

**Use RTSP, typically with TCP transport** for simplicity
and predictable behavior on the same host:

```bash 
ffmpeg -rtsp_transport tcp -i
rtsp://127.0.0.1:8554/mystream ... 
```

FFmpeg documents `rtsp_transport` with `tcp` and `udp`
options for RTSP. ([FFmpeg][3])

### Why `tcp` on localhost

* Single connection, no UDP port juggling
* Negligible downside on loopback
* Easy to deploy in containers/VMs/firewalled hosts

### When I’d choose SRT instead (even locally)

* You specifically want to test/validate the **same protocol
  path** used remotely
* You rely on SRT-specific options/behavior in your egress
  stack
* Your ffmpeg pipeline is already tuned around SRT MPEG-TS
  and changing it adds risk

---

## Practical recommendation for your architecture

* **Ingress (public internet):** SRT from encoder → MediaMTX
  (good choice)
* **Internal local handoff (same box):** RTSP (preferred for
  low-latency/simple)
* **Egress to Twitch:** ffmpeg transcode + RTMP/RTMPS to
  Twitch

If you want, I can give you the exact **ffmpeg egress
command** for both variants (RTSP input vs SRT input) with
low-latency flags and Twitch output settings.

[1]: https://mediamtx.org/docs/usage/read "Read a stream |
MediaMTX" [2]:
https://srtlab.github.io/srt-cookbook/protocol/tsbpd/latency-negotiation.html
"Latency Negotiation - SRT CookBook" [3]:
https://ffmpeg.org/ffmpeg-protocols.html "      FFmpeg
Protocols Documentation "


---

2026-02-21 

Yesterday we accomplished the following:
* determined host dependencies: filesystem mounts, ports,
  gpus
* extract mediamtx default configuration and begin to
  customize
* researched SRT protocol and parameters for publishers and
  readers

---

## Intermediate Steps
* [x] Hello World alpine linux container (linux/amd64)
* [x] apk install fish shell && wget install mediamtx
  binaries
* [ ] create script to scoop MPEG-TS segments to s3
* [x] apk install ffmpeg and see if it has nvenc encoders?
* [x] if not, apk install build deps and build ffmpeg with
  nvenc encoders
* [x] determine host dependencies: filesystem mounts, ports,
  gpus
* [ ] extract mediamtx default configuration, customize it,
  and bundle it in deployment
* [ ] create aws ec2 launch template and vpc security groups
* [ ] write systemd service file for strimserver container
* [ ] write systemd service file for ffmpeg twitch relay -
  this one is the one that we use to "go live" 
* [ ] write deploy script 
* [ ] bundle all new files in deployment
* [ ] create alwaysAvailableTrack loopable .mp4
* [ ] test alwaysAvailable configuration
* [ ] test record to disk configuration
* [ ] test stream to twitch happy path
* [ ] test stream to twitch fallback
* [ ] tune OBS --[SRT]--> strimserver bitrate (>6000kbps)
* [ ] test strimserver --[RTMP]--> twitch resilience at
  6000kbps
* [ ] maybe also consider gstreamer? 

---

To finish mediamtx configuration:
* move mediamtx.yml to mediamtx.yml.template
* determine passphrase requirements for srt stream
    * ChatGPT told us srt password requirement is "string
      between 10 and 70 characters"
    * we choose to make them alphnumeric characters
* create strimserver_setup.py that reformats the
  /dev/nvme1n1 and mounts at /mnt/nvme
* create deploy.sh for strimserver deployment
* determine how to generate passphrase on strimserver
  deployment and add it to deploy.sh
    * `tr -dc 'A-Za-z0-9' </dev/urandom | head -c 70`
* write passphrase to /mnt/nvme/srt-passphrase
* write mediamtx.service to mount the following
    * /mnt/nvme/srt-passphrase (host) to /run/secrets
      (container dir)
    * /mnt/nvme/video-files (host dir) to /opt/video-files
      (container dir)
* write mediamtx-entrypoint.sh such that it uses
  gettext-envsubst to read /run/secrets/srt-passphrase and
  substitute mediamtx.yml.template > mediamtx.yml


---

After the break:
* How do we glue this deployment together?
* Goal: strimserver.tar.gz
* Bundle everything together in makefile: becomes
  strimserver-deployment.tar
    /local-dev/strimserver-container.tar
    deploy.sh
    fish-deploy.sh
    imdslib.sh
    prompt_login.fish
    strimserver.service
* Upload to s3 bucket
* Profit $$$

---

2022-02-22 WE *almost* DID IT

* Full pipeline integration test
    * OBS
    * local encoder
    * mediamtx
    * egress encoder
    * twitch inspector

* Note: can't matroska/srt mux pcm_s24le - looks to be a
  muxer issue? muxer compatibility with SRT ?

---

* investigate HLS streaming ladder ? need to enable ?
  (quomitter has 480 360 and 160 ha)

---

Twitch “quality options” (the full HLS ladder:
1080p60/720p/480p/…) exist only when Twitch (or your
encoder) produces additional renditions besides “Source”.

### Why you only see “Source” as a non-Affiliate

Transcoding capacity is finite and expensive. Twitch
guarantees transcodes to **Partners**; everyone else gets
them only **when capacity is available at the moment you go
live**, with **Affiliates prioritized above
non-Affiliates**. If there’s no spare capacity, your channel
will show only the single source rendition. ([Twitch][1])

So what you’re observing is expected behavior: partnered
channels always have a ladder; non-affiliated channels may
not.

### What you can do to enable a ladder for viewers

#### Option A: Earn priority/guarantee (Affiliate/Partner)

* **Affiliate**: higher priority for transcodes than
  non-Affiliate, but still not guaranteed. ([Twitch][1])
* **Partner**: guaranteed transcodes. ([Twitch][1])

#### Option B: Use “Enhanced Broadcasting / Multiple Encodes” (client-side ladder)

Twitch has been rolling out “Enhanced Broadcasting” where
your streaming PC/GPU generates multiple encodes (multiple
resolutions) and sends them so viewers can pick qualities
even if Twitch’s cloud transcode capacity is constrained.
([blog.twitch.tv][2]) Practical steps:

* Ensure you’re on a supported streaming app/version (e.g.,
  newer OBS/Streamlabs versions that expose the feature).
  ([Streamlabs][3])
* In Twitch Creator Dashboard, look for Enhanced
  Broadcasting / Multiple Encodes under streaming settings
  (availability can be account/region/hardware dependent).
  ([blog.twitch.tv][2])
* You’ll need enough **upload bandwidth** and **encoder
  headroom** to produce several renditions concurrently.
  ([Streamlabs][3])

(If you don’t see the toggle/option, it likely isn’t enabled
for your account yet, or your setup doesn’t meet
    requirements.)

#### Option C: Make “Source-only” more watchable when you
don’t get transcodes

If you’re often source-only, consider:

* Lowering output to **720p60 or 720p30**, and/or lowering
  bitrate.
* This improves accessibility for mobile/low-bandwidth
  viewers who otherwise can’t downshift.

### What you cannot do

You generally can’t “request” or force Twitch to allocate
cloud transcodes for a non-partner channel for every stream;
it’s capacity-based. ([Twitch][1])

If you tell me what software you’re using (OBS/Streamlabs +
version) and your upload bandwidth, I can suggest a concrete
config that maximizes the chance of (a) Enhanced
Broadcasting working, or (b) a better “source-only”
experience.

[1]: https://www.twitch.tv/p/en/partners/faq/ "Twitch.tv - Partnership FAQ" 
[2]: https://blog.twitch.tv/en/2024/01/08/introducing-the-enhanced-broadcasting-beta/ "Introducing the Enhanced Broadcasting Beta" 
[3]: https://streamlabs.com/content-hub/post/twitch-multiple-encodes-streamlabs-desktop?srsltid=AfmBOopgYrV-n9gzfUAp7nJppEHClWmiAgT2cQ3GLr0owyRP5hhsA82j&utm_source=chatgpt.com "How to Enable Multiple Encodes for Twitch in ..."


---


2026-03-27 

* Okay, so after having used this streaming configuration
  for several piano streams in a row, it's clearer now that
      we need to modify mediamtx configuration and local
      encoder configuration to handle dropouts

* Sometimes when macbook is running too many programs and
  doing VideoToolbox encoding, the memory pressure causes
  local encoder speed to drop below 1x (like to 0.95x or
  0.9x)

* This means that - even before video is packetized and
  transferred over the internet to the transcode server via
  SRT protocol - the local encoder is not keeping up with
  the 60fps fifo being populated by OBS.

* On the server side, this looks like packet dropout - or
  increased transmission latency - so as long as there is
  enough buffer to counteract the temporary loss of
  transmitted frames, life is good and everything peachy EZ
  Clap.

* On the other hand... the server has to make a decision
  about "when is the stream done?" so it can terminate the
  egress ffmpeg process that is sending frames to twitch.

* The line between "when is the stream done?" vs. "when is
  the local encoder not keeping up?" is not well-defined.
  And so what happens is that twitch tells us we have
  "bitrate issues" or that our stream is "unstable." omgBruh

* In the worst case, stream goes down completely and we lose
  our viewers and stream metadata. Sadge :/

* In an effort to mitigate these issues, we aim to add
  mediamtx "alwaysAvailable" configuration. That's our aim
  for today.

Modifications to be made:
* [ ] create simple loopable video with same bitrate and
  encoding format as the ingest stream
* [ ] add alwaysAvailable configuration to
  mediamtx.yml.template
* [ ] modify alwaysAvailable configuration to read video
  contents and inject into the stream when we encounter a
  dropout
* [ ] test and tweak configuration iteratively as needed


Concept for loopable video:
* Single 7tv emote centered (choose animated one)
* Purple -> black gradient background

Things we don't know:

* What options do we have for mediamtx alwaysAvailable
  configuration?

* Is it more efficient/flexible to generate the video loop
  on the fly within the stream server? or create the looping
  video of arbitrary length (2s? 2x num frames in
  animation?)

* How do we expect our needs for alwaysAvailable stream to
  change in the future ? 

* How best to end stream - given added alwaysAvailable
  configuration ?

---

* What options do we have for mediamtx alwaysAvailable
  configuration?

    * alwaysAvailableFile
        * what are the constraints on format of data
          included within the video file?

    * alwaysAvailableTracks
        video-only placeholder:        
            alwaysAvailableTracks:
              - codec: H265

alwaysAvailableTracks:
  - codec: H265


---

2026-03-28

* Last time we investigated the mediamtx alwaysAvailable
  configuration parameters


Design for standby stream switching:

2 Independent ingest streams:
1. standby
2. macbook_encoder

1 egress stream:
* goes to twitch


---

```bash
ffmpeg \
  -thread_queue_size 8192 \
  -i "srt://MEDIAMTX_HOST:8890?streamid=read:macbook_encoder&mode=caller&latency=120" \
  -stream_loop -1 -re -i "/path/to/standby.mp4" \
  -filter_complex "\
    [0:v]setpts=PTS-STARTPTS[v0]; \
    [1:v]setpts=PTS-STARTPTS[v1]; \
    [0:a]asetpts=PTS-STARTPTS[a0]; \
    [1:a]asetpts=PTS-STARTPTS[a1]; \
    [v0][v1]streamselect@vsel=inputs=2:map=1,zmq=b=tcp\\://127.0.0.1\\:5555[vout]; \
    [a0][a1]astreamselect@asel=inputs=2:map=1[aout]" \
  -map "[vout]" \
  -map "[aout]" \
  -c:v libx264 \
  -preset veryfast \
  -tune zerolatency \
  -pix_fmt yuv420p \
  -g 120 \
  -keyint_min 120 \
  -sc_threshold 0 \
  -b:v 12M \
  -maxrate 12M \
  -bufsize 24M \
  -c:a aac \
  -b:a 160k \
  -ar 48000 \
  -ac 2 \
  -f flv "rtmp://live.twitch.tv/app/TWITCH_STREAM_KEY"
```

We're mostly interested in this part:

  -filter_complex "\
    [0:v]setpts=PTS-STARTPTS[v0]; \
    [1:v]setpts=PTS-STARTPTS[v1]; \
    [0:a]asetpts=PTS-STARTPTS[a0]; \
    [1:a]asetpts=PTS-STARTPTS[a1]; \
    [v0][v1]streamselect@vsel=inputs=2:map=1,zmq=b=tcp\\://127.0.0.1\\:5555[vout]; \
    [a0][a1]astreamselect@asel=inputs=2:map=1[aout]" \

* [x] NOTE: FFmpeg must be built with --enable-libzmq for
  these filters to exist.
    * DON'T TRY TO STATICALLY LINK YOUR LIBS!! (use .so, not
      .a)

1. Best practical design: separate “normalizer” from
   “egress”

A separate process does one of these at any given moment:

* if macbook_encoder is live: read it, transcode to fixed
    output, publish to macbook_normalized 

* if macbook_encoder is absent: generate slate/silence with
  the same output settings, publish to macbook_normalized

This process can be restarted independently if needed. That
is a big operational advantage over having one monolithic
egress process trying to survive everything


Relevant zmq commands:

echo "streamselect@vsel map 0" | tools/zmqsend
echo "astreamselect@asel map 0" | tools/zmqsend

echo "streamselect@vsel map 1" | tools/zmqsend
echo "astreamselect@asel map 1" | tools/zmqsend

---

2026-03-29 

What we discovered last time

* mediamtx + ffmpeg may not be sufficient to handle stream
  standby (i.e. remote srt stream disconnect) when combined
  with NVIDIA CUDA decode, CUDA scale, and NVENC

* we didn't thoroughly test a software-only filter graph -
  this may still be a viable option

* basically, when our stream disconnects from mediamtx with
  alwaysAvailable true, mediamtx pipes alwaysAvailable file
  contents into egress ffmpeg stream

* this transition triggers ffmpeg to rebuild the filter
  graph to handle the transition (even if it may not
  strictly be necessary to rebuild) - and the NVIDIA CUDA
  scale filter part of the pipeline is sensitive to this
  rebuild/reinit

* rather than spend more time trying to solve this problem
  with ffmpeg and mediamtx alone - we elect to research a
  new component: gstreamer

* our hope is that gstreamer will help us to manage stream
  disconnection transition gracefully - such that gstreamer
  outputs constant video stream to egress ffmpeg even if
  remote srt stream is disconnected


What do we need to know?

* what options does gstreamer provide for handling stream
  multiplexing and fallback?

* how to launch and manage gstreamer process within
  strimserver container ?

* do we need to build gstreamer from scratch? does gstreamer
  support NVIDIA hardware acceleration?

* how to connect gstreamer -> mediamtx -> egress ffmpeg?


---

On second thought, maybe let's just try to add extra
normalization step with ffmpeg - no rescale

Gstreamer too complicated for rn - it might be the right
solution, but if we have to write an entireley new app in
python or in C, then we ought to try software ffmpeg
normalization first

---

2026-03-30

Another day another tech stream! POGSLIDE

What have we learned from trying to implement
standby-stream?
    
* Standby stream can be tricky to set up with nvidia HW
  acceleration

* sometimes challenging for ffmpeg process to survive the
  always-available transition when ingest goes offline

* this is especially true if we intend to use only one
  ffmpeg process on the stream server - in retrospect this
  is a case of doing too much at the same time

* so: new concept - let's split the ffmpeg responsibilities
  into multiple processes and tie them together with
  mediamtx

* as strimserver project becomes more complex over time,
  it's likely that we'll want to add more stages to the
  transcode pipeline - so splitting ffmpeg responsibilities
  while the pipeline is still small/manageable is a good
      idea

What stages will we want our pipeline to have?

1. primary_ingress 
    * receives remote contribution stream over srt
    * dimensions: 3840x2160
    * frame rate: 59.98 / 60 fps
    * hardware acceleration:
        * hevc_videotoolbox (macbook)
        * aac_at (macbook)
    * codec: hevc_videotoolbox
    * expected video bitrate: 9000kbps
    * audio processing? pcm_s24le 24bit @ 48000Hz -> aac @
      320kbps
    * protocol: srt
    * reliable? no
    * record to disk? no
    * secure? yes - publish passphrase (generated at deploy
      time)
    * components:
        * local encoder (macbook)
        * mediamtx (server)

2. normalize (happ)
    * inserts offline slate into stream when ingest is down
    * dimensions: 3840x2160
    * frame rate: 59.98 / 60 fps
    * hardware acceleration:
        * CUDA hevc decode
        * hevc_nvenc
    * codec: hevc_nvenc
    * expected video bitrate: 9000kbps
    * audio processing? libfdk_aac 320kbps
    * protocol: srt
    * reliable? yes
    * record to disk? yes - sync to s3 object storage ? 
    * secure? localhost only 
    * components:
        * normalizer ffmpeg (server)
        * mediamtx (server)

3. scale
    * uses HW accelerated CUDA scaling to rescale stream
      dimensions for egress
    * dimensions: 3840x2160 -> 1920x1080p
    * frame rate: 59.98 / 60 fps
    * hardware acceleration:
        * CUDA hevc decode
        * scale_cuda video filter
        * hevc_nvenc
    * codec: hevc_nvenc
    * expected video bitrate: 9000kbps
    * audio processing? passthrough 
    * protocol: srt
    * reliable? yes
    * record to disk? no 
    * secure? localhost only 
    * components:
        * scaler ffmpeg (server)
        * mediamtx (server)

4. egress
    * encode for twitch ingest and send to twitch ingest
    * dimensions: 1920x1080p
    * frame rate: 59.98 / 60 fps
    * hardware acceleration:
        * CUDA hevc decode
        * h264_nvenc
    * codec: hevc  -> h264_nvenc
    * expected video video bitrate: 9000kbps -> 1000kbps (or maybe 2k)
    * audio processing? libfdk_aac 320kbps -> 160kbps
    * protocol: srt -> rtmp
    * reliable? yes
    * record to disk? no 
    * secure? twitch stream key 
    * components:
        * egress ffmpeg (server)
        * twitch (amazon interactive video service)

---

* Okay, so we have an idea of what each stage needs to do
  and also which components use each stage.

* The next idea is to encode this information into a
  domain-specific language (built in python) which will
  generate the following files prior to strimserver build:
    * strimserver.env
    * transcodelib.sh
    * mediamtx.yml.template

* transcodelib.sh will be a source-able bash script which
  defines ffmpeg entrypoint functions for: normalize, scale,
  egress

* Then - at runtime, mediamtx will invoke these ffmpeg
  entrypoint functions via:
    * ``` source transcodelib.sh && (funcname) ```

---

```
$(OFFLINE_SEGMENT_OUTPUT):
	ffmpeg \
	  -f lavfi -i "color=c=0x1a21ff:s=3840x2160:r=60,format=gbrp,geq=r='r(X,Y)*(1-Y/H)':g='g(X,Y)*(1-Y/H)':b='b(X,Y)*(1-Y/H)',format=nv12" \
	  -f lavfi -i anullsrc=r=48000:cl=stereo \
	  -c:v hevc_videotoolbox -pix_fmt nv12 -r 60 \
	  -c:a aac -ar 48000 -ac 2 \
	  -shortest -t 5 $@
```

















