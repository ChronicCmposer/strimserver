# Local encoder tooling

`tools/local-encoder/` holds the operator-side scripts that
wire a local OBS/FFmpeg encoder to a `strimserver` EC2 host
and point the Stream Deck plugin at the controller. They run
on the operator's macOS workstation — the same machine that
runs OBS and the Elgato Stream Deck app.

## 1. What's here

| File | Purpose |
| --- | --- |
| `configure-local-encoder.zsh` | Writes `STRIMSERVER_HOST`, `STRIMSERVER_URL`, and the SRT passphrase into the local env file |
| `local-encoder.zsh` | The encoder: reads the OBS Unix socket, wraps video/audio as MPEG-TS, publishes over SRT to `srt://<host>:9000` |
| `set-srt-passphrase.zsh` | Writes `SRT_PASSPHRASE` into the env file (invoked by `configure-local-encoder.zsh`) |
| `obs-client-config.sh` | OBS client configuration helper |
| `local-encoder.env.example` | Template for the env file |
| `launch-streamdeck.zsh` | Sources the env file and launches the Elgato Stream Deck app with `STRIMSERVER_URL` exported |
| `com.chroniccmposer.strimserver.streamdeck.plist` | Login LaunchAgent that keeps the Stream Deck app started with the URL set |

## 2. Environment file

All scripts read and write a single env file referenced via
`$LOCAL_ENCODER_ENV` — the operator sets it, conventionally to
`$HOME/.config/local-encoder/local-encoder.env` (gitignored). Copy the
example and export the variable before running anything:

```bash
cp tools/local-encoder/local-encoder.env.example ~/.config/local-encoder/local-encoder.env
$EDITOR ~/.config/local-encoder/local-encoder.env
export LOCAL_ENCODER_ENV="$HOME/.config/local-encoder/local-encoder.env"
```

## 3. Configuring the encoder and Stream Deck URL

`configure-local-encoder.zsh` writes three values into
`$LOCAL_ENCODER_ENV`:

- `STRIMSERVER_HOST` — the operator's Dynamic DNS hostname
  (e.g. `strim.example.com`), which resolves the box through
  public DNS.
- `STRIMSERVER_URL` — derived as `http://$STRIMSERVER_HOST:4000`
  from the controller HTTP port (`CONTROLLER_HTTP_PORT`). This
  is **not** the SRT ingest port, which is 9000.
- `SRT_PASSPHRASE` — written via `set-srt-passphrase.zsh`.

```bash
configure-local-encoder.zsh --strimserver-host strim.example.com --passphrase <generated-passphrase>
```

After writing the env file the script offers an interactive
relaunch prompt: press **Enter** to relaunch the Elgato Stream
Deck app (launching it directly if it isn't already running),
or **skip** to print the manual relaunch command instead.

## 4. Launching the Stream Deck app with the controller URL

`launch-streamdeck.zsh` sources `$LOCAL_ENCODER_ENV` and
launches the Elgato Stream Deck app with `STRIMSERVER_URL`
exported. Install it to `/usr/local/bin` — the location the
LaunchAgent and `configure-local-encoder.zsh` expect:

```bash
install -m 0755 tools/local-encoder/launch-streamdeck.zsh /usr/local/bin/
```

Then run it manually to pick up a changed URL:

```bash
/usr/local/bin/launch-streamdeck.zsh
```

The wrapper reads `LOCAL_ENCODER_ENV` from its own environment
(`export LOCAL_ENCODER_ENV="$HOME/.config/local-encoder/local-encoder.env"`
first, or prefix the command with it).

## 5. LaunchAgent: start the Stream Deck app with the URL set

`com.chroniccmposer.strimserver.streamdeck.plist` is a login
LaunchAgent that runs the wrapper at login, so the Stream Deck
app always starts with `STRIMSERVER_URL` set — including after
a reboot, with no manual step. The plist's `ProgramArguments`
points at `/usr/local/bin/launch-streamdeck.zsh`, so install
the wrapper first, then the plist:

```bash
install -m 0755 tools/local-encoder/launch-streamdeck.zsh /usr/local/bin/
sed "s/USERNAME/$USER/g" tools/local-encoder/com.chroniccmposer.strimserver.streamdeck.plist \
  > ~/Library/LaunchAgents/com.chroniccmposer.strimserver.streamdeck.plist
plutil -lint ~/Library/LaunchAgents/com.chroniccmposer.strimserver.streamdeck.plist
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.chroniccmposer.strimserver.streamdeck.plist
```

(The plist's `LOCAL_ENCODER_ENV` and log paths contain a
`USERNAME` placeholder; the `sed` above substitutes your macOS
username from `$USER`.)

Because the plist references the `/usr/local/bin` install, it
needs no repo-specific path. Uninstall with:

```bash
launchctl bootout gui/$UID/com.chroniccmposer.strimserver.streamdeck
```

## 6. Why this exists

The Stream Deck plugin reads `process.env.STRIMSERVER_URL` at
runtime, falling back to `http://localhost:4000` when it is
unset. The plugin inherits its environment from the Elgato
Stream Deck app process, so it can only see the URL if the app
itself was started with `STRIMSERVER_URL` exported. The
wrapper plus the login LaunchAgent are how the operator's real
hostname (e.g. `strim.example.com`) reaches the plugin at
runtime. The plugin code is unchanged — it still reads
`process.env` only.