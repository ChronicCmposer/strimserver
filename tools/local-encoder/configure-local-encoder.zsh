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

write_strimserver_host() {
  : "${LOCAL_ENCODER_ENV:?LOCAL_ENCODER_ENV is not set}"
  sed -i '' -E "s/STRIMSERVER_HOST=.*/STRIMSERVER_HOST=${1}/" "$LOCAL_ENCODER_ENV"
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
set-srt-passphrase.zsh "$passphrase_value"
