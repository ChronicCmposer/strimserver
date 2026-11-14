#!/usr/bin/env bash
# operator_template_test.sh -- structural assertions on
# deploy/aws/strimserver-infra.yaml (decision 11b).
#
# The durable stack must KEEP the read-only service user and carry a SINGLE
# project-scoped operator managed policy `strimserver-operator` (attached to that
# user) covering only the inventoried AWS surface, including the DLAMI read
# grants the check-deps resolver uses. This test enshrines
# LEAST PRIVILEGE: the operator policy must grant exactly the actions the
# strimserver tooling actually calls (derived from the `aws` CLI calls in
# deploy/aws/launch, deploy/aws/terminate and the publish/bucket scripts), must
# NOT carry account-wide IAM administration, must scope S3 to the deployment
# bucket and iam:PassRole to ec2, and must not mention route53.
#
# PyYAML is not available in the build image, so this test uses a structural
# extractor (awk) + grep, matching the sibling repo's fallback style.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The template path is overridable so the mutation check below can re-run this
# test against a throwaway copy; it defaults to the sibling template (Bazel
# runfiles keep the template adjacent to the test).
template="${STRIMSERVER_INFRA_TEMPLATE:-$script_dir/strimserver-infra.yaml}"

failures=0
check() {
  local desc="$1"
  shift
  if "$@"; then
    printf 'ok: %s\n' "$desc"
  else
    printf 'FAIL: %s\n' "$desc" >&2
    failures=$((failures + 1))
  fi
}

[[ -f "$template" ]] || { echo "FAIL: template not found: $template" >&2; exit 1; }

# extract_resource <Name>: print the YAML block for a top-level (2-space) resource.
extract_resource() {
  awk -v name="$1" '
    $0 ~ "^  " name ":" {p=1; print; next}
    p && /^  [A-Za-z0-9]+:/ {p=0}
    p {print}
  ' "$template"
}

service_user="$(extract_resource StrimserverServiceUser)"
operator_policy="$(extract_resource StrimserverOperatorPolicy)"

# extract_statement <Sid>: the `- Sid: <Sid>` block within the operator policy,
# up to the next `- Sid:` (or the end of the policy).
extract_statement() {
  awk -v sid="$1" '
    $0 ~ ("- Sid: " sid "$") {p=1; print; next}
    p && /- Sid: / {p=0}
    p {print}
  ' <<<"$operator_policy"
}

contains() { grep -Fq -- "$2" <<<"$1"; }

# --- preserved resources ------------------------------------------------------
check "service user exists (AWS::IAM::User, UserName strimserver)" \
  bash -c 'grep -Fq "StrimserverServiceUser:" "$1" && grep -Fq "Type: AWS::IAM::User" <<<"$2" && grep -Fq "UserName: strimserver" <<<"$2"' _ "$template" "$service_user"
check "standalone DLAMI read policy name is gone (strimserver-ssm-dlami-readonly)" \
  bash -c '! grep -Fq "strimserver-ssm-dlami-readonly" "$1"' _ "$template"
check "standalone DLAMI read policy resource is gone (StrimserverDlamiReadPolicy)" \
  bash -c '! grep -Fq "StrimserverDlamiReadPolicy:" "$1"' _ "$template"
check "operator policy covers both x86_64 + arm64 DLAMI SSM params" \
  bash -c 'grep -Fq "deeplearning/ami/x86_64/" <<<"$1" && grep -Fq "deeplearning/ami/arm64/" <<<"$1"' _ "$operator_policy"
check "operator policy grants ec2:DescribeImages (check-deps DLAMI metadata)" \
  bash -c 'grep -Fq "ec2:DescribeImages" <<<"$1"' _ "$operator_policy"
# launch reads the baked-AMI SSM parameter BEFORE falling back to the DLAMI, so
# the operator identity (the only identity that runs launch) must be granted
# ssm:GetParameter on it or the lookup returns AccessDenied and the baked image
# is never used.
check "operator policy covers the baked-AMI SSM parameter /strimserver/ami/baked/latest" \
  bash -c 'grep -Fq "/strimserver/ami/baked/latest" <<<"$1"' _ "$operator_policy"
check "exactly ONE managed policy attaches to the user (Users: appears once)" \
  bash -c '[ "$(grep -c "Users:" "$1")" -eq 1 ]' _ "$template"

# --- operator policy identity -------------------------------------------------
check "operator policy exists (AWS::IAM::ManagedPolicy)" \
  bash -c 'grep -Fq "Type: AWS::IAM::ManagedPolicy" <<<"$1"' _ "$operator_policy"
check "operator policy has fixed name strimserver-operator" \
  bash -c 'grep -Fq "ManagedPolicyName: strimserver-operator" <<<"$1"' _ "$operator_policy"
check "operator policy attached to the service user" \
  bash -c 'grep -Fq "StrimserverServiceUser" <<<"$1"' _ "$operator_policy"

# Regression: the IAM CreatePolicy Description regex
# [\p{L}\p{M}\p{Z}\p{S}\p{N}\p{P}]* rejects control chars, and a YAML folded
# scalar `>` (clip chomping) appends a trailing newline -> CloudFormation fails
# with "Value at 'description' failed to satisfy constraint". Use strip
# chomping `>-` (matching the movienight operator policy) so the parsed value
# has no trailing newline.
check "operator policy Description uses strip chomping '>-' (no trailing newline)" \
  bash -c 'grep -Eq "^[[:space:]]*Description: >-[[:space:]]*$" <<<"$1"' _ "$operator_policy"
check "operator policy has no bare clip-chomping '>' Description" \
  bash -c '! grep -Eq "^[[:space:]]*Description: >[[:space:]]*$" <<<"$1"' _ "$operator_policy"

# --- required (minimal) surface: exactly what the tooling calls --------------
# Derived from the `aws` CLI calls in deploy/aws/launch, deploy/aws/terminate,
# scripts/*.sh and tools/*/publish*.sh:
#   launch/terminate : ec2 run/terminate/describe-*, cloudformation describe-stacks
#   publish + bucket : s3 cp (PutObject), s3api get-bucket-location / get- /
#                      put-bucket-policy / list-objects-v2
#   launch           : iam:PassRole (--iam-instance-profile), ssm:GetParameter
#                      (--image-id resolve:ssm:...)
#   deploy-infra     : self key rotation (iam *AccessKey on user/strimserver)
for action in \
  s3:ListBucket s3:GetBucketLocation s3:GetBucketPolicy s3:PutBucketPolicy \
  s3:GetObject s3:PutObject s3:PutObjectAcl s3:DeleteObject \
  ec2:DescribeInstances ec2:DescribeSecurityGroups ec2:DescribeSubnets \
  ec2:DescribeImages \
  ec2:RunInstances ec2:TerminateInstances ec2:CreateTags \
  cloudformation:DescribeStacks \
  ssm:GetParameter \
  iam:PassRole iam:CreateAccessKey iam:ListAccessKeys iam:DeleteAccessKey; do
  check "operator policy grants $action" \
    bash -c 'grep -Fq -- "$2" <<<"$1"' _ "$operator_policy" "$action"
done

# --- deploy-infra + AMI-rebuild surface the operator now owns -----------------
# deploy-infra is no longer admin-run: the same [strimserver] operator runs the
# stack deploy and watches an Image Builder rebuild, so the policy must cover
# the CloudFormation deploy lifecycle (scoped to this stack), iam:PassRole for
# the roles the template wires, the Image Builder pipeline trigger + reads, and
# ec2:DescribeImages (already covered above for the check-deps drift gate).
cfn_deploy_stmt="$(extract_statement CloudFormationDeployStack)"
cfn_validate_stmt="$(extract_statement CloudFormationValidateTemplate)"
cfn_read_stmt="$(extract_statement CloudFormationReadStack)"
pass_ib_stmt="$(extract_statement PassImageBuilderRoles)"
ib_rebuild_stmt="$(extract_statement ImageBuilderRebuild)"
ib_read_stmt="$(extract_statement ImageBuilderRead)"

check "CloudFormation deploy statement exists" \
  bash -c 'grep -Fq "cloudformation:CreateStack" <<<"$1" && grep -Fq "cloudformation:UpdateStack" <<<"$1"' _ "$cfn_deploy_stmt"
check "CloudFormation deploy is scoped to stack/strimserver/*" \
  bash -c 'grep -Fq "stack/strimserver/*" <<<"$1" && ! grep -Fq "Resource: \"*\"" <<<"$1"' _ "$cfn_deploy_stmt"
check "CloudFormation deploy carries the change-set actions aws deploy needs" \
  bash -c 'for a in CreateChangeSet DescribeChangeSet ExecuteChangeSet DeleteChangeSet; do grep -Fq "cloudformation:$a" <<<"$1" || exit 1; done' _ "$cfn_deploy_stmt"
check "CloudFormation ValidateTemplate is granted on Resource \"*\"" \
  bash -c 'grep -Fq "cloudformation:ValidateTemplate" <<<"$1" && grep -Fq "Resource: \"*\"" <<<"$1"' _ "$cfn_validate_stmt"
check "CloudFormation read statement covers DescribeStacks/DescribeStackEvents/GetTemplate" \
  bash -c 'for a in DescribeStacks DescribeStackEvents GetTemplate; do grep -Fq "cloudformation:$a" <<<"$1" || exit 1; done' _ "$cfn_read_stmt"
check "the operator policy grants no DeleteStack (deploy does not need it)" \
  bash -c '! grep -Fq "cloudformation:DeleteStack" <<<"$1"' _ "$operator_policy"

check "iam:PassRole covers both Image Builder roles" \
  bash -c 'grep -Fq "iam:PassRole" <<<"$1" && grep -Fq "BakedImageBuilderInstanceRole" <<<"$1" && grep -Fq "BakedImageBuilderExecutionRole" <<<"$1"' _ "$pass_ib_stmt"
check "ImageBuilder rebuild statement triggers the BakedImagePipeline" \
  bash -c 'grep -Fq "imagebuilder:StartPipelineExecution" <<<"$1"' _ "$ib_rebuild_stmt"
check "ImageBuilder rebuild is scoped to the pipeline ARN" \
  bash -c 'grep -Fq "image-pipeline/strimserver-baked" <<<"$1" && ! grep -Fq "Resource: \"*\"" <<<"$1"' _ "$ib_rebuild_stmt"
check "ImageBuilder read statement covers the rebuild-watch surface" \
  bash -c 'for a in GetImagePipeline ListImagePipelines GetImage ListImages GetImageRecipe; do grep -Fq "imagebuilder:$a" <<<"$1" || exit 1; done' _ "$ib_read_stmt"

# --- least privilege: no unused admin grants ---------------------------------
# StackIamManagement (C1) granted account-wide IAM administration the operator
# never uses (deploy-infra is admin-run). None of these may reappear.
for action in \
  iam:AttachUserPolicy iam:DetachUserPolicy iam:CreatePolicy \
  iam:CreatePolicyVersion iam:CreateUser iam:CreateRole iam:PutRolePolicy \
  iam:UpdateAssumeRolePolicy iam:AttachRolePolicy iam:DetachRolePolicy \
  iam:DeleteRole iam:DeletePolicy iam:DeleteUser iam:CreateInstanceProfile \
  iam:DeleteInstanceProfile iam:AddRoleToInstanceProfile; do
  check "operator policy does NOT grant admin $action" \
    bash -c '! grep -Fq -- "$2" <<<"$1"' _ "$operator_policy" "$action"
done
# scripts/bucket-cidr-policy.sh (MAKE_PRIVATE=1) calls `s3api put-object-acl`
# to flip pre-existing public-read objects private, so the operator legitimately
# needs s3:PutObjectAcl -- but ONLY on the deployment bucket's objects, never
# account-wide. S3Objects is separately asserted scoped/not Resource "*" below.
check "s3:PutObjectAcl is scoped to the deployment bucket objects statement" \
  bash -c 'grep -Fq "s3:PutObjectAcl" <<<"$1"' _ "$(extract_statement S3Objects)"
check "no account-wide s3:PutObjectAcl (Describe Ec2 statement is clean)" \
  bash -c '! grep -Fq "s3:PutObjectAcl" <<<"$1"' _ "$(extract_statement Ec2Describe)"

# --- M2: EC2 lifecycle statements are split and gated by tag/type ------------
# The former single Ec2LaunchTerminate statement granted RunInstances /
# TerminateInstances / CreateTags on Resource "*" with NO conditions, so the
# operator could terminate ANY instance in the account. Mirror movienight:
#   - Run    : gated by aws:RequestTag/Project + an ec2:InstanceType allowlist,
#     scoped to instance/* (the referenced key-pair/SG/subnet/image/volume/ENI
#     get their own unconditioned RunInstancesDependencies grant)
#   - Term   : gated by aws:ResourceTag/Project
#   - Tags   : gated by aws:RequestTag/Project, scoped to instance ARNs
#   - Describe* : MUST stay WITHOUT conditions. EC2 Describe actions do not
#     support resource-level permissions, so a ResourceTag condition would
#     evaluate false and DENY the call, breaking terminate's lookup. AWS:
#     "the Describe actions do not support resource-level permissions, so you
#     must specify them in a separate statement without conditions."
run_stmt="$(extract_statement Ec2RunInstances)"
run_deps_stmt="$(extract_statement Ec2RunInstancesDependencies)"
terminate_stmt="$(extract_statement Ec2TerminateInstances)"
tags_stmt="$(extract_statement Ec2CreateTags)"
describe_stmt="$(extract_statement Ec2Describe)"

check "RunInstances statement exists" \
  bash -c 'grep -Fq "ec2:RunInstances" <<<"$1"' _ "$run_stmt"
check "RunInstances is gated by aws:RequestTag/Project" \
  bash -c 'grep -Fq "aws:RequestTag/Project" <<<"$1"' _ "$run_stmt"
check "RunInstances condition uses the ProjectName parameter" \
  bash -c 'grep -Fq "!Ref ProjectName" <<<"$1"' _ "$run_stmt"
check "RunInstances restricts ec2:InstanceType to the documented GPU families" \
  bash -c 'grep -Fq "ec2:InstanceType" <<<"$1" && grep -Fq "g4dn.*" <<<"$1" && grep -Fq "g6.*" <<<"$1" && grep -Fq "g5g.*" <<<"$1"' _ "$run_stmt"
# RunInstances is authorized against EVERY resource the request references, but
# only the instance carries the RequestTag/InstanceType gates (launch tags the
# instance alone). The statement must therefore be scoped to instance/* rather
# than Resource:"*", with the referenced resources in a separate statement.
check "RunInstances instance statement is scoped to instance/* (not Resource \"*\")" \
  bash -c 'grep -Fq "instance/*" <<<"$1" && ! grep -Fq "Resource: \"*\"" <<<"$1"' _ "$run_stmt"
check "RunInstancesDependencies statement exists and grants ec2:RunInstances" \
  bash -c 'grep -Fq "ec2:RunInstances" <<<"$1"' _ "$run_deps_stmt"
check "RunInstancesDependencies covers volume/ENI/key-pair/SG/subnet" \
  bash -c 'for r in "volume/*" "network-interface/*" "key-pair/*" "security-group/*" "subnet/*"; do grep -Fq "$r" <<<"$1" || exit 1; done' _ "$run_deps_stmt"
check "RunInstancesDependencies covers the empty-account public image ARN" \
  bash -c 'grep -Fq "arn:aws:ec2:\${AWS::Region}::image/*" <<<"$1"' _ "$run_deps_stmt"
check "RunInstancesDependencies is UNCONDITIONED (no RequestTag / InstanceType)" \
  bash -c '! grep -Fq "aws:RequestTag" <<<"$1" && ! grep -Fq "ec2:InstanceType" <<<"$1"' _ "$run_deps_stmt"

check "TerminateInstances statement exists" \
  bash -c 'grep -Fq "ec2:TerminateInstances" <<<"$1"' _ "$terminate_stmt"
check "TerminateInstances is gated by aws:ResourceTag/Project" \
  bash -c 'grep -Fq "aws:ResourceTag/Project" <<<"$1"' _ "$terminate_stmt"
check "TerminateInstances condition uses the ProjectName parameter" \
  bash -c 'grep -Fq "!Ref ProjectName" <<<"$1"' _ "$terminate_stmt"

check "CreateTags statement exists" \
  bash -c 'grep -Fq "ec2:CreateTags" <<<"$1"' _ "$tags_stmt"
check "CreateTags is gated by aws:RequestTag/Project" \
  bash -c 'grep -Fq "aws:RequestTag/Project" <<<"$1"' _ "$tags_stmt"
check "CreateTags is scoped to instance ARNs (not Resource \"*\")" \
  bash -c '! grep -Fq "Resource: \"*\"" <<<"$1"' _ "$tags_stmt"
# fix3: an aws:TagKeys allowlist stops the operator stamping an arbitrary key
# (e.g. a future terminate-gating tag) onto a foreign instance. It must keep
# ForAllValues:StringEquals and exactly the keys launch applies via
# --tag-specifications (Project, Name). The RequestTag/Project condition stays.
check "CreateTags carries an aws:TagKeys allowlist (ForAllValues:StringEquals)" \
  bash -c 'grep -Fq "ForAllValues:StringEquals" <<<"$1" && grep -Fq "aws:TagKeys" <<<"$1"' _ "$tags_stmt"
check "CreateTags aws:TagKeys allowlist is exactly the launch keys (Project, Name)" \
  bash -c 'grep -Fq -- "- Project" <<<"$1" && grep -Fq -- "- Name" <<<"$1"' _ "$tags_stmt"

check "Describe statement exists" \
  bash -c 'grep -Fq "ec2:DescribeInstances" <<<"$1"' _ "$describe_stmt"
check "Describe statement stays Resource \"*\" and unconditioned" \
  bash -c 'grep -Fq "Resource: \"*\"" <<<"$1" && ! grep -Fq "aws:RequestTag" <<<"$1" && ! grep -Fq "aws:ResourceTag" <<<"$1"' _ "$describe_stmt"

check "the old unscoped Ec2LaunchTerminate statement is gone" \
  bash -c '! grep -Fq "Ec2LaunchTerminate" "$1"' _ "$template"
check "RunInstances and TerminateInstances are separate statements" \
  bash -c '! grep -Fq "ec2:TerminateInstances" <<<"$1"' _ "$run_stmt"

# --- scoping: S3 + IAM statements must not be Resource "*" -------------------
for sid in S3BucketConfig S3Objects SelfKeyRotation PassStrimserverRole; do
  block="$(extract_statement "$sid")"
  check "$sid statement present" bash -c '[[ -n "$1" ]]' _ "$block"
  check "$sid is scoped (not Resource \"*\")" \
    bash -c '! grep -Fq "Resource: \"*\"" <<<"$1"' _ "$block"
done
check "S3 bucket statement scoped to the deployment bucket" \
  bash -c 'grep -Fq "arn:aws:s3:::\${DeploymentBucketName}" <<<"$1"' _ "$(extract_statement S3BucketConfig)"
check "S3 object statement scoped to the deployment bucket prefix" \
  bash -c 'grep -Fq "arn:aws:s3:::\${DeploymentBucketName}/*" <<<"$1"' _ "$(extract_statement S3Objects)"
check "SelfKeyRotation scoped to user/strimserver" \
  bash -c 'grep -Fq "user/strimserver" <<<"$1"' _ "$(extract_statement SelfKeyRotation)"

# --- C2: iam:PassRole constrained to EC2 -------------------------------------
pass_role="$(extract_statement PassStrimserverRole)"
check "iam:PassRole scoped to role/strimserver*" \
  bash -c 'grep -Fq "role/strimserver*" <<<"$1"' _ "$pass_role"
check "iam:PassRole carries the ec2.amazonaws.com condition" \
  bash -c 'grep -Fq "iam:PassedToService" <<<"$1" && grep -Fq "ec2.amazonaws.com" <<<"$1"' _ "$pass_role"

check "CloudFormation scoped to stack/strimserver/*" \
  bash -c 'grep -Fq "stack/strimserver/*" <<<"$1"' _ "$operator_policy"
check "no route53 anywhere in the template" \
  bash -c '! grep -qi "route53" "$1"' _ "$template"

# --- regression: instance plumbing still present ------------------------------
check "InstanceRole still present" bash -c 'grep -Fq "InstanceRole:" "$1"' _ "$template"
check "InstanceProfile still present" bash -c 'grep -Fq "InstanceProfile:" "$1"' _ "$template"

# --- baked-AMI read grant on the instance role -------------------------------
# The instance role already carries only scoped grants; the baked-AMI lookup
# must stay scoped to the single parameter, never a wildcard ssm:GetParameter.
instance_role="$(extract_resource InstanceRole)"
check "instance role can read the baked-AMI SSM parameter" \
  bash -c 'grep -Fq "/strimserver/ami/baked/latest" <<<"$1"' _ "$instance_role"
check "instance role baked-AMI read is scoped (no parameter/* wildcard)" \
  bash -c '! grep -Fq "parameter/*" <<<"$1"' _ "$instance_role"

# --- baked-AMI Image Builder execution role (least privilege) ----------------
execution_role="$(extract_resource BakedImageBuilderExecutionRole)"
check "baked-AMI pipeline execution role exists (AWS::IAM::Role)" \
  bash -c 'grep -Fq "Type: AWS::IAM::Role" <<<"$1"' _ "$execution_role"
check "pipeline execution role is assumable by imagebuilder.amazonaws.com" \
  bash -c 'grep -Fq "imagebuilder.amazonaws.com" <<<"$1"' _ "$execution_role"
check "pipeline execution role grants imagebuilder actions" \
  bash -c 'grep -Fq "imagebuilder:" <<<"$1"' _ "$execution_role"
check "pipeline execution role grants ssm:PutParameter on the baked AMI parameter" \
  bash -c 'grep -Fq "ssm:PutParameter" <<<"$1" && grep -Fq "/strimserver/ami/baked/latest" <<<"$1"' _ "$execution_role"
check "pipeline execution role grants ec2:CreateTags (AMI tagging)" \
  bash -c 'grep -Fq "ec2:CreateTags" <<<"$1"' _ "$execution_role"
check "pipeline execution role passes only the Image Builder instance role" \
  bash -c 'grep -Fq "iam:PassRole" <<<"$1" && grep -Fq "ec2.amazonaws.com" <<<"$1"' _ "$execution_role"

# --- no hardcoded AMI ids beyond the recipe base + launch fallback -----------
# The ImageRecipe base and launch's DEFAULT_AMI_ID are the only two places the
# pinned DLAMI id may appear. Any other literal would be a stale bake target.
pinned_ami="ami-0198b63ccfac121e8"
check "template hardcodes only the pinned recipe-base AMI id" \
  bash -c 'ids="$(grep -o "ami-[0-9a-f]\{8,\}" "$1" | sort -u)"; [ "$ids" = "$2" ]' _ "$template" "$pinned_ami"
check "launch keeps only the pinned fallback AMI constant" \
  bash -c 'ids="$(grep -o "ami-[0-9a-f]\{8,\}" "$1" | sort -u)"; [ "$ids" = "$2" ]' _ "$script_dir/launch" "$pinned_ami"


# --- mutation check: CreateTags without aws:TagKeys must FAIL ------------------
# Guard against the fix3 assertion silently rotting: strip the
# ForAllValues:StringEquals aws:TagKeys block from a throwaway copy and confirm
# this very test rejects it. Skipped during the re-invoked (mutated) run.
if [[ -z "${STRIMSERVER_OPERATOR_TEST_MUTATED_RUN:-}" ]]; then
  mutation_dir="$(mktemp -d)"
  trap 'rm -rf "$mutation_dir"' EXIT
  awk '
    /- Sid: Ec2CreateTags/ { in_stmt=1; print; next }
    in_stmt && /ForAllValues:StringEquals:/ { drop=1; next }
    drop && /^                / { next }
    drop { drop=0 }
    { print }
  ' "$template" > "$mutation_dir/strimserver-infra.yaml"
  if STRIMSERVER_INFRA_TEMPLATE="$mutation_dir/strimserver-infra.yaml" \
      STRIMSERVER_OPERATOR_TEST_MUTATED_RUN=1 \
      bash "$0" >/dev/null 2>&1; then
    echo "FAIL: mutation check: CreateTags without aws:TagKeys passed" >&2
    failures=$((failures + 1))
  else
    printf 'ok: mutation check: CreateTags without aws:TagKeys is rejected\n'
  fi
fi

if [[ "$failures" -eq 0 ]]; then
  echo "PASS: operator template structure OK"
  exit 0
fi
echo "FAILED: $failures assertion(s)" >&2
exit 1
