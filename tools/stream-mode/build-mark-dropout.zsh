#!/bin/zsh
# build-mark-dropout.zsh — compile mark-dropout.applescript into
# ~/Applications/Mark Dropout.app (the .app is a build product; not committed).
set -euo pipefail
STREAM_MODE_DIR=${0:A:h}
out="$HOME/Applications/Mark Dropout.app"
mkdir -p "$HOME/Applications"
rm -rf "$out"
osacompile -o "$out" "$STREAM_MODE_DIR/mark-dropout.applescript"
print -r -- "built: $out"
print -r -- "Stream Deck: add a 'System → Open' action pointing at it."
