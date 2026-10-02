#!/usr/bin/env zsh
set -euo pipefail

usage() {
  print -u2 "usage: ${0:t} --strimserver-host <hostname> --passphrase <passphrase_value>"
  print -u2 "  --strimserver-host <hostname>   strim server hostname (required)"
  print -u2 "  --passphrase <passphrase_value> SRT passphrase (required)"
  exit 2
}

is_valid_hostname() {
  [[ "$1" =~ '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$' ]]
}

# Replaces the KEY=... line if present, else appends it. Env files that
# predate a given key (e.g. STRIMSERVER_URL) would otherwise be silently
# left unchanged by a plain `sed s/KEY=.../` with no match.
set_env_key() {
  local key="$1" value="$2"
  if grep -q -E "^${key}=" "$LOCAL_ENCODER_ENV"; then
    sed -i '' -E "s|^${key}=.*|${key}=${value}|" "$LOCAL_ENCODER_ENV"
  else
    print -r -- "${key}=${value}" >> "$LOCAL_ENCODER_ENV"
  fi
}

write_strimserver_host() {
  : "${LOCAL_ENCODER_ENV:?LOCAL_ENCODER_ENV is not set}"
  set_env_key STRIMSERVER_HOST "$1"
}

write_strimserver_url() {
  : "${LOCAL_ENCODER_ENV:?LOCAL_ENCODER_ENV is not set}"
  set_env_key STRIMSERVER_URL "http://${1}:4000"
}

# Prefer the repo-independent /usr/local/bin install (the LaunchAgent's
# ProgramArguments) so configure and launchctl agree; fall back to the
# checkout copy so configure still works before the wrapper is installed.
if [[ -x /usr/local/bin/launch-streamdeck.zsh ]]; then
  streamdeck_wrapper=/usr/local/bin/launch-streamdeck.zsh
else
  streamdeck_wrapper="${0:A:h}/launch-streamdeck.zsh"
fi

can_detect_streamdeck() {
  command -v pgrep >/dev/null 2>&1
}

is_streamdeck_running() {
  # Elgato's process is named "Stream Deck"; also match the app bundle path so
  # version differences in the executable name don't cause a false negative.
  pgrep -x "Stream Deck" >/dev/null 2>&1 || pgrep -f "Elgato Stream Deck" >/dev/null 2>&1
}

launch_streamdeck() {
  if [[ ! -x "$streamdeck_wrapper" ]]; then
    print -u2 "error: cannot relaunch Stream Deck: wrapper not found or not executable: ${streamdeck_wrapper}"
    return 1
  fi
  "$streamdeck_wrapper"
}

maybe_relaunch_streamdeck() {
  # Non-interactive: never block; just print the manual relaunch command.
  if [[ ! -t 0 ]]; then
    print -u2 "relaunch Elgato Stream Deck manually: ${streamdeck_wrapper}"
    return 0
  fi

  # App not running: launch directly instead of asking for a restart.
  # Without pgrep we cannot detect it, so fall back to prompting.
  if can_detect_streamdeck && ! is_streamdeck_running; then
    launch_streamdeck
    return 0
  fi

  print -u2 ""
  print -u2 "press enter to relaunch Elgato Stream Deck, or type 'skip' to skip:"
  local response=""
  read -r response || true
  if [[ -z "$response" ]]; then
    launch_streamdeck
  else
    print -u2 "relaunch Elgato Stream Deck manually: ${streamdeck_wrapper}"
  fi
}

strimserver_host=""
passphrase_value=""

while (( $# > 0 )); do
  case "$1" in
    --strimserver-host|--host|-s)
      (( $# >= 2 )) || usage
      strimserver_host="$2"
      shift 2
      ;;
    --passphrase|--pass|-p)
      (( $# >= 2 )) || usage
      passphrase_value="$2"
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    --)
      shift
      break
      ;;
    *)
      print -u2 "error: unknown option: $1"
      usage
      ;;
  esac
done

if [[ -z "$passphrase_value" ]]; then
  print -u2 "error: --passphrase is required"
  usage
fi

if [[ -z "$strimserver_host" ]]; then
  print -u2 "error: --strimserver-host is required"
  usage
fi

if ! is_valid_hostname "$strimserver_host"; then
  print -u2 "error: invalid --strimserver-host '${strimserver_host}': expected a valid DNS hostname"
  exit 2
fi

write_strimserver_host "$strimserver_host"
write_strimserver_url "$strimserver_host"
set-srt-passphrase.zsh "$passphrase_value"
maybe_relaunch_streamdeck
