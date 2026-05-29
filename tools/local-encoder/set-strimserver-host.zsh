#!/usr/bin/env zsh
set -euo pipefail

if (( $# < 1 )); then
  print -u2 "usage: ${0:t} <new_ip>"
  exit 2
fi

new_ip="$1"

sudo -n sed -i '' -E \
  "s/^([0-9.]+)([[:space:]]+)strimserver([[:space:]]|$)/${new_ip}\\2strimserver\\3/" \
  "/etc/hosts"
