#!/usr/bin/env bash
#
# Phase 0 read-only AWS inventory for the strimserver -> stackctl migration.
#
# The operator runs this locally with their own credentials before the migration
# window. It records the current live state (stacks, IAM, S3, SSM, security
# groups, EC2) so the cutover can be diffed against the new stackctl resources.
# See deploy/aws/STACKCTL_MIGRATION.md, Phase 0.
#
# This script is strictly read-only: it never mutates AWS state and never prints
# secret values (SSM SecureStrings are probed by name only).
#
# Usage:
#   bash deploy/aws/stackctl-phase0-inventory.sh [--region us-east-2]
#
# Region precedence: --region > AWS_REGION > us-east-2.

# JMESPath --query expressions are intentionally single-quoted: their backticks
# are JMESPath literals, not shell command substitutions.
# shellcheck disable=SC2016

set -euo pipefail

readonly DEFAULT_REGION="us-east-2"
readonly OLD_INFRA_STACK="strimserver"
readonly OLD_OPERATOR_STACK="strimserver-operator"
readonly OLD_BUCKET="strimserver.cvbn.cc"
readonly IAM_USER="strimserver"
readonly POLICY_OPERATOR="strimserver-operator"
readonly POLICY_BOUNDARY="strimserver-boundary"
readonly INSTANCE_ROLE="strimserver-instance-role"
readonly INSTANCE_PROFILE="strimserver-instance-profile"

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPORT="${repo_dir}/phase0-inventory.txt"

die() {
   printf 'phase0-inventory: ERROR: %s\n' "$*" >&2
   exit 1
}

usage() {
   cat <<'EOF'
Usage: stackctl-phase0-inventory.sh [--region REGION]

Read-only AWS inventory for the strimserver -> stackctl migration (Phase 0).

Options:
  --region REGION   AWS region to inventory (default: $AWS_REGION or us-east-2)
  -h, --help        Show this help and exit

Writes the report to deploy/aws/phase0-inventory.txt and echoes it to stdout.
Requires the AWS CLI v2 and working credentials.
EOF
}

parse_args() {
   REGION="${AWS_REGION:-${DEFAULT_REGION}}"
   while [ "$#" -gt 0 ]; do
      case "$1" in
         --region)
            [ "$#" -ge 2 ] || die "--region requires a value"
            REGION="$2"
            shift 2
            ;;
         --region=*)
            REGION="${1#*=}"
            shift
            ;;
         -h | --help)
            usage
            exit 0
            ;;
         *)
            die "unknown argument: $1 (try --help)"
            ;;
      esac
   done
   [ -n "$REGION" ] || die "region must not be empty"
   readonly REGION
}

preflight() {
   command -v aws >/dev/null 2>&1 || die "aws CLI not found on PATH (v2 required)"

   local version
   version="$(aws --version 2>&1)" || die "failed to run 'aws --version'"
   case "$version" in
      aws-cli/2.*) ;;
      *) die "AWS CLI v2 required (found: ${version})" ;;
   esac

   # Abort early if credentials are missing or unusable.
   IDENTITY_ARN="$(aws sts get-caller-identity --region "$REGION" --query Arn --output text 2>/dev/null)" \
      || die "AWS credentials unavailable (sts get-caller-identity failed)"
   ACCOUNT="$(aws sts get-caller-identity --region "$REGION" --query Account --output text 2>/dev/null)" \
      || die "could not resolve AWS account id"
   [ -n "$IDENTITY_ARN" ] && [ -n "$ACCOUNT" ] \
      || die "sts get-caller-identity returned empty identity"
   readonly IDENTITY_ARN ACCOUNT

   # Partition (aws / aws-us-gov / aws-cn) from the caller ARN.
   local rest="${IDENTITY_ARN#arn:}"
   PARTITION="${rest%%:*}"
   readonly PARTITION
}

section() {
   printf '\n===== %s @ %s UTC =====\n' "$*" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# Prints a stack's existence, status, creation time, outputs, parameters and
# tags. Missing stacks are reported, not fatal.
describe_stack() {
   local stack="$1" mapping_note="$2"
   printf '\n--- Stack: %s ---\n' "$stack"
   printf '  Mapping: %s\n' "$mapping_note"

   local status
   if ! status="$(aws cloudformation describe-stacks --stack-name "$stack" \
      --region "$REGION" --query 'Stacks[0].StackStatus' --output text 2>/dev/null)"; then
      printf '  Exists: NO (NoSuchEntity / stack not found)\n'
      return 0
   fi

   printf '  Exists: YES\n'
   printf '  Status: %s\n' "$status"
   printf '  CreationTime: %s\n' \
      "$(aws cloudformation describe-stacks --stack-name "$stack" --region "$REGION" \
         --query 'Stacks[0].CreationTime' --output text 2>/dev/null || true)"

   stack_list "Outputs" 'Stacks[0].Outputs[].[OutputKey,OutputValue]' "$stack"
   stack_list "Parameters" 'Stacks[0].Parameters[].[ParameterKey,ParameterValue]' "$stack"
   stack_list "Tags" 'Stacks[0].Tags[].[Key,Value]' "$stack"
}

# Prints a tab-separated query result for a stack, or "(none)".
stack_list() {
   local label="$1" query="$2" stack="$3"
   local data
   data="$(aws cloudformation describe-stacks --stack-name "$stack" --region "$REGION" \
      --query "$query" --output text 2>/dev/null || true)"
   printf '  %s (tab-separated name/value):\n' "$label"
   if [ -n "$data" ]; then
      printf '%s\n' "$data" | sed 's/^/    /'
   else
      printf '    (none)\n'
   fi
}

inventory_identity() {
   section "1. Caller identity"
   printf '  ARN:     %s\n' "$IDENTITY_ARN"
   printf '  Account: %s\n' "$ACCOUNT"
   printf '  Region:  %s\n' "$REGION"
}

inventory_stacks() {
   section "2. Old CloudFormation stacks"
   describe_stack "$OLD_INFRA_STACK" \
      'old infra stack maps to the NEW stack name strimserver-infra (no name collision)'
   describe_stack "$OLD_OPERATOR_STACK" \
      'COLLIDES with the stackctl default: same name, deleted and recreated in the Phase 4 window'
}

inventory_iam() {
   section "3. IAM"
   printf '\n--- IAM user: %s ---\n' "$IAM_USER"
   if aws iam get-user --user-name "$IAM_USER" >/dev/null 2>&1; then
      printf '  Exists: YES\n'
      printf '  Access keys (metadata only; never secrets):\n'
      local keys
      keys="$(aws iam list-access-keys --user-name "$IAM_USER" \
         --query 'AccessKeyMetadata[].[AccessKeyId,Status,CreateDate]' --output text 2>/dev/null || true)"
      if [ -n "$keys" ]; then
         printf '%s\n' "$keys" | sed 's/^/    /'
      else
         printf '    (none)\n'
      fi
   else
      printf '  Exists: NO (NoSuchEntity / user not found)\n'
   fi

   printf '\n--- Managed policies ---\n'
   local policy
   for policy in "$POLICY_OPERATOR" "$POLICY_BOUNDARY"; do
      local arn
      arn="$(aws iam get-policy --policy-arn "arn:${PARTITION}:iam::${ACCOUNT}:policy/${policy}" \
         --query 'Policy.Arn' --output text 2>/dev/null || true)"
      if [ -n "$arn" ]; then
         printf '  %s: EXISTS (%s)\n' "$policy" "$arn"
      else
         printf '  %s: NOT FOUND\n' "$policy"
      fi
   done

   printf '\n--- Instance role / profile ---\n'
   local role_arn
   role_arn="$(aws iam get-role --role-name "$INSTANCE_ROLE" \
      --query 'Role.Arn' --output text 2>/dev/null || true)"
   if [ -n "$role_arn" ]; then
      printf '  Role %s: EXISTS (%s)\n' "$INSTANCE_ROLE" "$role_arn"
   else
      printf '  Role %s: NOT FOUND\n' "$INSTANCE_ROLE"
   fi
   if aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE" >/dev/null 2>&1; then
      printf '  Instance profile %s: EXISTS\n' "$INSTANCE_PROFILE"
   else
      printf '  Instance profile %s: NOT FOUND\n' "$INSTANCE_PROFILE"
   fi
}

# Lists the top level of one bucket: a verbatim `aws s3 ls` plus a one-level
# object count per top-level prefix. Deliberately shallow; never recurses.
describe_bucket() {
   local bucket="$1"
   printf '\n--- S3 bucket: %s ---\n' "$bucket"
   if ! aws s3api head-bucket --bucket "$bucket" --region "$REGION" >/dev/null 2>&1; then
      printf '  Exists: NO (head-bucket failed)\n'
      return 0
   fi
   printf '  Exists: YES\n'
   printf '  Top-level listing (aws s3 ls, one level):\n'
   if ! aws s3 ls "s3://${bucket}/" --region "$REGION"; then
      printf '  (top-level listing unavailable or empty)\n'
   fi

   local prefixes prefix count
   prefixes="$(aws s3api list-objects-v2 --bucket "$bucket" --delimiter / \
      --region "$REGION" --query 'CommonPrefixes[].Prefix' --output text 2>/dev/null || true)"
   printf '  Top-level prefixes and object counts (one level deep):\n'
   if [ -z "$prefixes" ]; then
      printf '    (no top-level prefixes)\n'
      return 0
   fi
   # Word splitting is intended: prefixes arrive space/tab separated from --output text.
   for prefix in $prefixes; do
      count="$(aws s3api list-objects-v2 --bucket "$bucket" --prefix "$prefix" \
         --delimiter / --region "$REGION" \
         --query 'length(Contents || `[]`)' --output text 2>/dev/null || true)"
      [ -n "$count" ] || count=0
      printf '    %s -> %s top-level objects\n' "$prefix" "$count"
   done
}

inventory_s3() {
   section "4. S3"
   local buckets
   buckets="$(aws s3api list-buckets \
      --query "Buckets[?contains(Name, 'strimserver')].Name" --output text 2>/dev/null || true)"
   # Always include the known old bucket even if list-buckets is empty/denied.
   case " ${buckets} " in
      *" ${OLD_BUCKET} "*) ;;
      *) buckets="${buckets} ${OLD_BUCKET}" ;;
   esac
   local bucket
   for bucket in $buckets; do
      describe_bucket "$bucket"
   done
}

inventory_ssm() {
   section "5. SSM parameters (names/types only; values never read)"
   printf '  Parameters under /strimserver/:\n'
   local params
   params="$(aws ssm describe-parameters --region "$REGION" \
      --parameter-filters Key=Name,Option=BeginsWith,Values=/strimserver/ \
      --query 'Parameters[].[Name,Type,LastModifiedDate]' --output text 2>/dev/null || true)"
   if [ -n "$params" ]; then
      printf '%s\n' "$params" | sed 's/^/    /'
   else
      printf '    (none)\n'
   fi

   printf '\n  Required parameters (existence only):\n'
   local name found
   for name in \
      /strimserver/twitch-stream-key \
      /strimserver/ddns/password \
      /strimserver/ami/baked/latest; do
      found="$(aws ssm describe-parameters --region "$REGION" \
         --parameter-filters "Key=Name,Option=Equals,Values=${name}" \
         --query 'Parameters[0].Name' --output text 2>/dev/null || true)"
      if [ -n "$found" ] && [ "$found" != "None" ]; then
         printf '    EXISTS  %s\n' "$name"
      else
         printf '    MISSING %s\n' "$name"
      fi
   done
}

inventory_security_groups() {
   section "6. Security group ingress (from old infra stack output SecurityGroupId)"
   printf '  Expected after cutover: TCP 4000 + 2222 from operator CIDR, UDP 9000 world (0.0.0.0/0), SSH 22 from operator CIDR.\n'
   local sg
   sg="$(aws cloudformation describe-stacks --stack-name "$OLD_INFRA_STACK" \
      --region "$REGION" \
      --query 'Stacks[0].Outputs[?OutputKey==`SecurityGroupId`].OutputValue | [0]' \
      --output text 2>/dev/null || true)"
   if [ -z "$sg" ] || [ "$sg" = "None" ]; then
      printf '  Security group id: not available (stack missing or no SecurityGroupId output)\n'
      return 0
   fi
   printf '  Security group id: %s\n' "$sg"
   printf '  Protocol\tFrom\tTo\tIPv4 CIDR\tIPv6 CIDR\n'
   aws ec2 describe-security-groups --group-ids "$sg" --region "$REGION" \
      --query 'SecurityGroups[0].IpPermissions[].[IpProtocol, FromPort, ToPort, join(`,`, IpRanges[].CidrIp), join(`,`, Ipv6Ranges[].CidrIp)]' \
      --output text 2>/dev/null | sed 's/^/  /' \
      || printf '  (could not describe security group)\n'
}

inventory_ec2() {
   section "7. EC2 instances (running/stopped) matching strimserver"
   printf '  Columns: InstanceId State Type PublicIP LaunchTime NameTag AllTags\n'
   local instances matches
   instances="$(aws ec2 describe-instances --region "$REGION" \
      --filters Name=instance-state-name,Values=running,stopped \
      --query 'Reservations[].Instances[].[InstanceId, State.Name, InstanceType, PublicIpAddress, LaunchTime, Tags[?Key==`Name`].Value | [0], join(`,`, Tags[].Value)]' \
      --output text 2>/dev/null || true)"
   if [ -z "$instances" ]; then
      printf '  (no running/stopped instances found)\n'
      return 0
   fi
   matches="$(printf '%s\n' "$instances" | grep -i 'strimserver' || true)"
   if [ -n "$matches" ]; then
      printf '%s\n' "$matches" | sed 's/^/  /'
   else
      printf '  (no strimserver-tagged instance found)\n'
   fi
}

manual_next_steps() {
   section "Manual next steps (print only; nothing here was executed)"
   cat <<'EOF'
  1. Store the on-box Twitch stream key as an SSM SecureString (stackctl never writes SSM):
       aws ssm put-parameter \
         --name /strimserver/twitch-stream-key \
         --type SecureString \
         --value '<twitch key>'

  2. Keep or create the DDNS SecureString (launch/status fail closed without it):
       aws ssm put-parameter \
         --name /strimserver/ddns/password \
         --type SecureString \
         --value '<ddns password>'

  3. Lower the DDNS record TTL in Namecheap, then wait out the old TTL before the window.

  4. Freeze new releases on the old deploy pipeline (stop publishing vX.Y.Z tags to it).

  5. After the FIRST stackctl deploy creates the new hard-named artifact bucket
     (Phase 1), dry-run the copy before syncing:
       aws s3 sync s3://strimserver.cvbn.cc/ s3://<new-hard-named-bucket>/ --dry-run
     Then run the same command without --dry-run and treat the old bucket as read-only.

  6. Pick and announce the Phase 4 operator-stack maintenance window (the only
     step that removes/rebuilds the strimserver-operator IAM stack).

  Region for the commands above: us-east-2 (override only if you explicitly moved).
EOF
}

main() {
   parse_args "$@"
   preflight
   printf 'phase0-inventory: writing %s\n' "$REPORT" >&2
   # Tee everything below to the report file while still printing to stdout.
   exec > >(tee "$REPORT")

   printf 'strimserver stackctl Phase 0 inventory\n'
   printf 'Generated: %s UTC\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
   printf 'Region: %s\n' "$REGION"

   inventory_identity
   inventory_stacks
   inventory_iam
   inventory_s3
   inventory_ssm
   inventory_security_groups
   inventory_ec2
   manual_next_steps

   printf '\nphase0-inventory: done. Report written to %s\n' "$REPORT" >&2
}

main "$@"
