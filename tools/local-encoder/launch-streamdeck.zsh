#!/usr/bin/env zsh
# Launch Elgato Stream Deck with the local-encoder environment exported.
#
# The Stream Deck plugin is a Node child of the Elgato Stream Deck app, so it
# inherits the app's environment. If the app starts without STRIMSERVER_URL the
# plugin silently falls back to http://localhost:4000; this wrapper sources
# $LOCAL_ENCODER_ENV (with every variable exported) and then
# `open -a "Elgato Stream Deck"`, so the app and its plugin see the right URL.
#
# Invocable both from the LaunchAgent (com.chroniccmposer.strimserver.streamdeck)
# at login and manually for an on-demand relaunch:
#   LOCAL_ENCODER_ENV="$HOME/.strimserver-local-encoder.env" launch-streamdeck.zsh
set -euo pipefail


: "${LOCAL_ENCODER_ENV:?LOCAL_ENCODER_ENV is not set}"

if [[ ! -f "$LOCAL_ENCODER_ENV" ]]; then
  print -u2 "error: LOCAL_ENCODER_ENV file not found: $LOCAL_ENCODER_ENV"
  exit 1
fi

if [[ ! -r "$LOCAL_ENCODER_ENV" ]]; then
  print -u2 "error: LOCAL_ENCODER_ENV file is not readable: $LOCAL_ENCODER_ENV"
  exit 1
fi

set -a
. "$LOCAL_ENCODER_ENV"
set +a

if [[ -z "${STRIMSERVER_URL:-}" ]]; then
  print -u2 "error: STRIMSERVER_URL is empty in $LOCAL_ENCODER_ENV; the plugin would fall back to http://localhost:4000"
  exit 1
fi

if ! open -a "Elgato Stream Deck"; then
  print -u2 "error: failed to launch Elgato Stream Deck ('open -a' exited non-zero)"
  exit 1
fi