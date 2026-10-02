#!/usr/bin/env zsh
set -euo pipefail


: "${LOCAL_ENCODER_ENV:?LOCAL_ENCODER_ENV is not set}"

if (( $# < 1 )); then
  print -u2 "usage: ${0:t} <passphrase_value>"
  exit 2
fi

passphrase_value="$1"
env_file="$LOCAL_ENCODER_ENV"

# Escape sed's replacement metacharacters (\, &, and the s/// delimiter) so an
# arbitrary passphrase can't corrupt the substitution or the env file.
escaped_passphrase="${passphrase_value//\\/\\\\}"
escaped_passphrase="${escaped_passphrase//&/\\&}"
escaped_passphrase="${escaped_passphrase//\//\\/}"

sed -i '' -E "s/SRT_PASSPHRASE=.*/SRT_PASSPHRASE=${escaped_passphrase}/" "$env_file"

