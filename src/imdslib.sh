#!/usr/bin/env bash

set -euo pipefail

: "${IMDS:=http://169.254.169.254}"

get_token() {
   echo "$(curl -sS --connect-timeout 2 -X PUT "$IMDS/latest/api/token" \
      -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)"
}

get_public_ip() {
   # Get IMDSv2 token 
   local TOKEN="$(get_token)"

   if [[ -n "$TOKEN" ]]; then
     IP="$(curl -sS --connect-timeout 2 -H "X-aws-ec2-metadata-token: $TOKEN" \
       "$IMDS/latest/meta-data/public-ipv4" || true)"
   else
     IP="$(curl -sS --connect-timeout 2 "$IMDS/latest/meta-data/public-ipv4" || true)"
   fi

   # Print the IP (exit non-zero if not available)
   if [[ -n "${IP:-}" ]]; then
      echo "$IP"
   else
      exit 1
   fi
}


get_instance_type() {
   # Get IMDSv2 token 
   local TOKEN="$(get_token)"

   if [[ -n "$TOKEN" ]]; then
     INSTANCE_TYPE="$(curl -sS --connect-timeout 2 -H "X-aws-ec2-metadata-token: $TOKEN" \
       "$IMDS/latest/meta-data/instance-type" || echo "unknown")"
   else
     INSTANCE_TYPE="$(curl -sS --connect-timeout 2 "$IMDS/latest/meta-data/instance-type" || echo "unknown")"
   fi

   # Print the INSTANCE_TYPE (exit non-zero if not available)
   if [[ -n "${INSTANCE_TYPE:-}" ]]; then
     echo "$INSTANCE_TYPE"
   else
     exit 1
   fi
}
