#!/usr/bin/env zsh
set -euo pipefail

usage() {
  print -u2 "usage: ${0:t} --strimserver-host <ip_address> --passphrase <passphrase_value>"
  exit 2
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

[[ -n "$strimserver_host" && -n "$passphrase_value" ]] || usage

set-strimserver-host.zsh "$strimserver_host"
set-srt-passphrase.zsh "$passphrase_value"

