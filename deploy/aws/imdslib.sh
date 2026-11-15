#!/usr/bin/env bash

set -euo pipefail

: "${IMDS:=http://169.254.169.254}"

# Every IMDS request is bounded: --connect-timeout guards a dead link and
# --max-time bounds the whole exchange, so a stalled metadata service can never
# hang a deploy indefinitely.
imds_curl() {
   curl -sS --connect-timeout 2 --max-time 5 "$@"
}

get_token() {
   echo "$(imds_curl -X PUT "$IMDS/latest/api/token" \
      -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)"
}

# Parse, don't validate: return success only for a strict dotted-quad IPv4 with
# each octet in 0..255. Anything else (empty, garbage, IPv6, a stalled IMDS
# response) is rejected here, at the boundary.
imds__is_dotted_quad() {
   local ip="$1" octet
   local -a octets
   [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
   IFS=. read -r -a octets <<<"$ip"
   for octet in "${octets[@]}"; do
      ((octet >= 0 && octet <= 255)) || return 1
   done
}

get_public_ip() {
   # Get IMDSv2 token
   local TOKEN IP
   TOKEN="$(get_token)"

   if [[ -n "$TOKEN" ]]; then
      IP="$(imds_curl -H "X-aws-ec2-metadata-token: $TOKEN" \
        "$IMDS/latest/meta-data/public-ipv4" || true)"
   else
      IP="$(imds_curl "$IMDS/latest/meta-data/public-ipv4" || true)"
   fi

   if ! imds__is_dotted_quad "${IP:-}"; then
      printf 'cannot determine public IPv4 from IMDS (no public IP associated?)\n' >&2
      exit 1
   fi
   printf '%s\n' "$IP"
}


get_instance_type() {
   # Get IMDSv2 token
   local TOKEN INSTANCE_TYPE
   TOKEN="$(get_token)"

   if [[ -n "$TOKEN" ]]; then
      INSTANCE_TYPE="$(imds_curl -H "X-aws-ec2-metadata-token: $TOKEN" \
        "$IMDS/latest/meta-data/instance-type" || echo "unknown")"
   else
      INSTANCE_TYPE="$(imds_curl "$IMDS/latest/meta-data/instance-type" || echo "unknown")"
   fi

   # Print the INSTANCE_TYPE (exit non-zero if not available)
   if [[ -n "${INSTANCE_TYPE:-}" ]]; then
      echo "$INSTANCE_TYPE"
   else
      exit 1
   fi
}
