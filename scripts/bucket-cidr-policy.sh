#!/usr/bin/env bash
# scripts/bucket-cidr-policy.sh -- scope HTTPS-only read access to the S3 bucket
# S3_BUCKET_NAME (required) to a single IPv4 CIDR by applying a
# BUCKET POLICY (aws s3api put-bucket-policy) -- deliberately NOT a bucket ACL.
#
# Why a bucket policy and not an ACL? S3 ACLs are identity-based: a grantee is a
# canonical user id, an AWS account, or the special Everyone / AnyAuthenticatedUser
# group, and an ACL cannot express an IP range. IP-scoped access is expressible
# only in a bucket policy, via an "IpAddress" condition on "aws:SourceIp". We pair
# that with a "Bool" condition on "aws:SecureTransport" = "true" so the scoped
# access is HTTPS-only, and add an "OwnerFullAccess" statement so the bucket owner
# keeps full control even though the CIDR statement uses Principal "*".
#
# Usage: ./scripts/bucket-cidr-policy.sh [CIDR]
#   CIDR: CLI arg wins over $ALLOWED_CIDR. Env (required): S3_BUCKET_NAME,
#   ALLOWED_CIDR, AWS_REGION (used only as a fallback when get-bucket-location
#   reports no region), APPLY (unset = DRY-RUN; 1 = put), MAKE_PRIVATE (unset;
#   1 = private ACLs).
#
# CRITICAL CAVEAT: applies to PRE-EXISTING objects only. Objects uploaded EARLIER
# with an object-level PUBLIC-READ ACL still grant Everyone READ and OVERRIDE this
# IP-scoped bucket policy -- the policy alone will NOT revoke that public access.
# Rerun with MAKE_PRIVATE=1 to flip every object to a private ACL so the bucket
# policy becomes the only gate. New uploads (tools/ffmpeg-dist/publish.sh and
# scripts/upload-artifact.sh) set no object ACL.
set -euo pipefail

# --- env-override reads (required; mirror scripts/upload-artifact.sh style) ---
S3_BUCKET_NAME="${S3_BUCKET_NAME:?S3_BUCKET_NAME is required (e.g. your-bucket-name)}"
ALLOWED_CIDR="${ALLOWED_CIDR:?ALLOWED_CIDR is required (your home IP CIDR)}"
AWS_REGION="${AWS_REGION:?AWS_REGION is required}"
APPLY="${APPLY:-}"
MAKE_PRIVATE="${MAKE_PRIVATE:-}"

# CLI arg wins over ALLOWED_CIDR
allowed_cidr="${1:-$ALLOWED_CIDR}"

# --- guard: awscli must be installed and configured ---
if ! command -v aws >/dev/null 2>&1; then
  echo "error: 'aws' (awscli) not found; install it and run 'aws configure'." >&2
  exit 1
fi

# --- guard: python3 is required to validate the generated policy JSON ---
if ! command -v python3 >/dev/null 2>&1; then
  echo "error: 'python3' not found; needed to validate the bucket policy JSON." >&2
  exit 1
fi

# --- parse + validate the CIDR at the boundary (parse, don't validate) ---
# Robust check: require a single '/', an integer prefix 0-32, then an IP of
# exactly four integer octets each 0-255. A regex alone is never trusted because
# it cannot enforce numeric ranges, so each part is checked numerically.
validate_ipv4_cidr() {
  local cidr="$1" ip="${1%/*}" prefix="${1#*/}" octet
  local -a octets
  [[ "$cidr" == */* ]] || return 1
  [[ -n "$ip" ]] || return 1
  [[ "$prefix" =~ ^[0-9]{1,2}$ ]] || return 1
  (( 10#$prefix <= 32 )) || return 1
  IFS='.' read -r -a octets <<<"$ip"
  ((${#octets[@]} == 4)) || return 1
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#$octet <= 255 )) || return 1
  done
  return 0
}
if ! validate_ipv4_cidr "$allowed_cidr"; then
  echo "error: invalid CIDR: '$allowed_cidr'" >&2
  echo "       expected IPv4 CIDR: <4 octets each 0-255>/<prefix 0-32>, e.g. 203.0.113.0/24" >&2
  exit 1
fi

# --- guard: valid AWS identity; capture the owner Account ID ---
account_id="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" || {
  echo "error: 'aws sts get-caller-identity' failed; run 'aws configure'." >&2
  exit 1
}

# --- guard: the bucket must exist; resolve its region for the regional API call ---
reported_region="$(aws s3api get-bucket-location --bucket "$S3_BUCKET_NAME" --output text 2>/dev/null)" || {
  echo "error: bucket '$S3_BUCKET_NAME' not found or not accessible (get-bucket-location failed)." >&2
  echo "       check the bucket name and that your credentials can read its location." >&2
  exit 1
}
reported_region="${reported_region#None}"   # older CLIs print "None" when no region is reported
resolved_region="${reported_region:-$AWS_REGION}"

# --- build the policy JSON; validated at the boundary before any use ---
build_policy_json() {
  local bucket="$1" cidr="$2" account="$3"
  cat <<POLICY_EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowHTTPSFromCIDR",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${bucket}/*",
      "Condition": {
        "IpAddress": {
          "aws:SourceIp": "${cidr}"
        },
        "Bool": {
          "aws:SecureTransport": "true"
        }
      }
    },
    {
      "Sid": "OwnerFullAccess",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${account}:root"
      },
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::${bucket}",
        "arn:aws:s3:::${bucket}/*"
      ]
    }
  ]
}
POLICY_EOF
}
policy="$(build_policy_json "$S3_BUCKET_NAME" "$allowed_cidr" "$account_id")"
if ! printf '%s' "$policy" | python3 -m json.tool >/dev/null 2>&1; then
  echo "error: generated bucket policy failed JSON validation; aborting." >&2
  exit 1
fi

echo "==> bucket:        $S3_BUCKET_NAME"
echo "==> allowed CIDR:  $allowed_cidr (HTTPS-only)"
echo "==> owner account: $account_id"
echo "==> region:        $resolved_region"

# --- loud caveat: PRE-EXISTING PUBLIC-READ ACLs override this policy ---
cat >&2 <<'WARN'
!!
!! WARNING: applies to PRE-EXISTING objects only. Objects uploaded EARLIER with
!! an object-level PUBLIC-READ ACL still grant Everyone READ and OVERRIDE this
!! IP-scoped bucket policy -- the policy alone will NOT revoke that public
!! access. Rerun with MAKE_PRIVATE=1 to flip every object to a private ACL so
!! the bucket policy becomes the only gate. New uploads (publish.sh and
!! scripts/upload-artifact.sh) set no object ACL.
!!
WARN

put_command=(aws s3api put-bucket-policy --bucket "$S3_BUCKET_NAME" --policy "$policy" --region "$resolved_region")

if [[ "$APPLY" != "1" ]]; then
  mode="dry-run"
  echo "==> DRY-RUN (APPLY unset): printing policy and the command that would run"
  printf '%s\n' "$policy"
  printf '==> would run: %s\n' "${put_command[*]}"
else
  mode="applied"
  echo "==> APPLY=1: putting bucket policy on $S3_BUCKET_NAME (region $resolved_region)"
  "${put_command[@]}" || {
    echo "error: aws s3api put-bucket-policy failed for $S3_BUCKET_NAME." >&2
    exit 1
  }
  echo "==> verifying applied policy still contains $allowed_cidr"
  applied_policy="$(aws s3api get-bucket-policy --bucket "$S3_BUCKET_NAME" --query Policy --output text 2>/dev/null)" || {
    echo "error: aws s3api get-bucket-policy failed for $S3_BUCKET_NAME; cannot verify." >&2
    exit 1
  }
  if [[ "$applied_policy" != *"$allowed_cidr"* ]]; then
    echo "error: get-bucket-policy does not contain '$allowed_cidr'; policy was not applied as intended." >&2
    exit 1
  fi
fi

# --- optional enforcement: MAKE_PRIVATE=1 flips PRE-EXISTING objects to a private ACL ---
if [[ "$MAKE_PRIVATE" == "1" ]]; then
  echo "==> MAKE_PRIVATE=1: listing objects to enforce private ACLs"
  keys_text="$(aws s3api list-objects-v2 --bucket "$S3_BUCKET_NAME" --query 'Contents[].Key' --output text 2>/dev/null)" || {
    echo "error: aws s3api list-objects-v2 failed for $S3_BUCKET_NAME." >&2
    exit 1
  }
  object_keys=()
  if [[ -n "$keys_text" ]]; then
    while IFS= read -r key; do
      object_keys+=("$key")
    done <<<"$keys_text"
  fi
  object_count="${#object_keys[@]}"
  if [[ "$APPLY" != "1" ]]; then
    echo "==> dry-run: would set --acl private on $object_count object(s)"
    if (( object_count > 0 )); then
      printf '==> first few keys: %s\n' "${object_keys[*]:0:3}"
    fi
  else
    echo "==> setting --acl private on $object_count object(s)"
    for key in "${object_keys[@]}"; do
      [[ -n "$key" ]] || continue
      aws s3api put-object-acl --bucket "$S3_BUCKET_NAME" --key "$key" --acl private || {
        echo "error: aws s3api put-object-acl failed for '$key'." >&2
        exit 1
      }
    done
    echo "==> private ACLs enforced on $object_count object(s)"
  fi
else
  echo "!! MAKE_PRIVATE unset: pre-existing PUBLIC-READ ACLs are left in place (new uploads set no object ACL)" >&2
fi

# --- done: summary ---
echo "==> done:"
echo "==>   bucket:       $S3_BUCKET_NAME"
echo "==>   allowed CIDR: $allowed_cidr"
echo "==>   HTTPS-only:   enforced via aws:SecureTransport=true condition"
echo "==>   region:       $resolved_region"
echo "==>   mode:         $mode"
if [[ "$MAKE_PRIVATE" != "1" ]]; then
  echo "==>   REMINDER: pre-existing PUBLIC-READ ACLs still allow anonymous access;" >&2
  echo "==>   rerun with MAKE_PRIVATE=1 to make the bucket policy the only gate." >&2
fi
exit 0
