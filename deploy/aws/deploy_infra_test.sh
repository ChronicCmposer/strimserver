#!/usr/bin/env bash
# deploy_infra_test.sh -- drive deploy/aws/deploy-infra against the fake aws.
#
# deploy-infra is the PROFILE-RUN stack deploy (provision-account owns the admin
# bootstrap and key rotation). These assertions pin the movienight parameter
# philosophy:
#   * only parameters the operator explicitly set are passed
#     (OPERATOR_CIDR, S3_BUCKET_NAME, VPC_ID, NVIDIA_DRIVER_FLOOR,
#     CREATE_NETWORK, ENABLE_EXPERIMENTAL_SSH), plus the ProjectName constant;
#   * unset parameters are ABSENT from the deploy line, so the template's
#     Default stays authoritative -- the describe-stacks live re-pass machinery
#     is gone;
#   * the stack name must equal ProjectName (the policy ARNs depend on it);
#   * the deploy runs under a bounded `timeout`;
#   * the identity gate, the first-create OPERATOR_CIDR requirement, the
#     client-side VPC guard, and the post-deploy verification (status, floor,
#     pipeline) all survive.
#
# The structural baked-AMI assertions at the bottom are retained from the old
# suite.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
deploy_infra="$script_dir/deploy-infra"
# shellcheck source=testutil_fake_aws.sh
source "$script_dir/testutil_fake_aws.sh"

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

fake_aws_install

work="$(mktemp -d)"
trap 'fake_aws_cleanup; rm -rf "$work"' EXIT

nvidia_floor="$(sed -n 's/^NVIDIA_DRIVER_FLOOR="\(.*\)"$/\1/p' "$script_dir/lib/nvidia.sh" | head -n1)"
[[ -n "$nvidia_floor" ]] || { echo "FAIL: could not read NVIDIA_DRIVER_FLOOR" >&2; exit 1; }

# run_deploy <state> <calls> <home> [args...]
# EXTRA_ENV holds extra KEY=VALUE assignments for this invocation.
EXTRA_ENV=()
run_deploy() {
  local state="$1" calls="$2" home="$3"; shift 3
  ( cd "$repo_root" && env -i \
      PATH="$PATH" HOME="$home" \
      AWS_SHARED_CREDENTIALS_FILE="$home/.aws/credentials" \
      AWS_CONFIG_FILE="$home/.aws/config" \
      FAKE_AWS_STATE="$state" \
      FAKE_AWS_CALLS="$calls" \
      FAKE_AWS_TEMPLATE_FLOOR="$nvidia_floor" \
      "${EXTRA_ENV[@]}" \
      bash "$deploy_infra" "$@" )
}

new_home() { # new_home <dir>: a fixture HOME with a pre-existing [default] profile
  local dir="$1"
  mkdir -p "$dir/.aws"
  printf '[default]\naws_access_key_id = ADMINKEY\naws_secret_access_key = ADMINSECRET\n' >"$dir/.aws/credentials"
  printf '[default]\nregion = eu-west-1\n' >"$dir/.aws/config"
}

# ---------------------------------------------------------------------------
# Case 1 -- first create: identity, explicit params only, no re-pass machinery
# ---------------------------------------------------------------------------
h1="$work/h1"; new_home "$h1"; mkdir -p "$work/s1"
creds_before="$(cat "$h1/.aws/credentials")"
EXTRA_ENV=(OPERATOR_CIDR=203.0.113.4/32 S3_BUCKET_NAME=bucket-1 VPC_ID=vpc-abc123 NVIDIA_DRIVER_FLOOR="$nvidia_floor")
run_deploy "$work/s1" "$work/c1" "$h1" >"$work/o1" 2>&1
rc=$?
EXTRA_ENV=()

check "first create exits 0" test "$rc" -eq 0
deploy_line="$(grep -m1 'cloudformation deploy' "$work/c1" || true)"
check "deploy runs as --profile strimserver" \
  bash -c '[[ "$1" == *"--profile strimserver"* ]]' _ "$deploy_line"
check "deploy uses the strimserver stack and named-IAM capability" \
  bash -c '[[ "$1" == *"--stack-name strimserver"* && "$1" == *"--capabilities CAPABILITY_NAMED_IAM"* ]]' _ "$deploy_line"
check "deploy always passes the ProjectName constant" \
  bash -c '[[ "$1" == *ProjectName=strimserver* ]]' _ "$deploy_line"
check "deploy passes the env operator CIDR to OperatorCidr and IngestCidr" \
  bash -c '[[ "$1" == *OperatorCidr=203.0.113.4/32* && "$1" == *IngestCidr=203.0.113.4/32* ]]' _ "$deploy_line"
check "deploy passes DeploymentBucketName when S3_BUCKET_NAME is set" \
  bash -c '[[ "$1" == *DeploymentBucketName=bucket-1* ]]' _ "$deploy_line"
check "deploy passes VpcId when VPC_ID is set" \
  bash -c '[[ "$1" == *VpcId=vpc-abc123* ]]' _ "$deploy_line"
check "deploy passes the explicit NvidiaDriverFloor override" \
  bash -c '[[ "$1" == *"NvidiaDriverFloor=$2"* ]]' _ "$deploy_line" "$nvidia_floor"
for absent in CreateNetwork= EnableExperimentalSsh= EnableSessionManager= \
  ControllerPort= SrtPort= ExperimentalSshPort= VpcCidr= SubnetCidr=; do
  check "unset parameter is omitted from the deploy line: $absent" \
    bash -c '[[ "$1" != *"$2"* ]]' _ "$deploy_line" "$absent"
done
check "no access key is created or deleted (rotation owns that)" \
  bash -c '! grep -Eq "iam (create|delete)-access-key" "$1"' _ "$work/c1"
check "the pre-existing credentials file is untouched" \
  test "$(cat "$h1/.aws/credentials")" = "$creds_before"
check "identity is asserted via the profile" \
  bash -c 'grep -Eq -- "--profile strimserver .*sts get-caller-identity" "$1"' _ "$work/c1"
check "post-deploy reads the stack status as CREATE_COMPLETE" \
  bash -c 'grep -Fq "cloudformation describe-stacks" "$1" && grep -Fq "CREATE_COMPLETE" "$2"' _ "$work/c1" "$work/o1"
check "post-deploy lists Image Builder pipelines" \
  bash -c 'grep -Fq "imagebuilder list-image-pipelines" "$1"' _ "$work/c1"

# ---------------------------------------------------------------------------
# Case 1b -- first create in existing-VPC mode: VPC_ID -> VpcId, no floor pass
# ---------------------------------------------------------------------------
h1b="$work/h1b"; new_home "$h1b"; mkdir -p "$work/s1b"
EXTRA_ENV=(OPERATOR_CIDR=203.0.113.4/32 VPC_ID=vpc-deadbeef)
run_deploy "$work/s1b" "$work/c1b" "$h1b" >"$work/o1b" 2>&1
rc=$?
EXTRA_ENV=()
check "first create with VPC_ID exits 0" test "$rc" -eq 0
deploy1b="$(grep -m1 'cloudformation deploy' "$work/c1b" || true)"
check "first create passes VPC_ID as VpcId" \
  bash -c '[[ "$1" == *VpcId=vpc-deadbeef* ]]' _ "$deploy1b"
check "an unset NvidiaDriverFloor is NOT passed (template default authoritative)" \
  bash -c '[[ "$1" != *"NvidiaDriverFloor="* ]]' _ "$deploy1b"
check "first create does not force CreateNetwork when VPC_ID is supplied" \
  bash -c '[[ "$1" != *"CreateNetwork="* ]]' _ "$deploy1b"

# ---------------------------------------------------------------------------
# Case 1c -- first create in created-network mode: CREATE_NETWORK=true, no VPC_ID
# ---------------------------------------------------------------------------
h1c="$work/h1c"; new_home "$h1c"; mkdir -p "$work/s1c"
EXTRA_ENV=(OPERATOR_CIDR=203.0.113.4/32 CREATE_NETWORK=true)
run_deploy "$work/s1c" "$work/c1c" "$h1c" >"$work/o1c" 2>&1
rc=$?
EXTRA_ENV=()
check "first create with CREATE_NETWORK=true exits 0" test "$rc" -eq 0
deploy1c="$(grep -m1 'cloudformation deploy' "$work/c1c" || true)"
check "first create passes CreateNetwork=true" \
  bash -c '[[ "$1" == *CreateNetwork=true* ]]' _ "$deploy1c"
check "first create passes no VpcId when CREATE_NETWORK=true" \
  bash -c '[[ "$1" != *"VpcId="* ]]' _ "$deploy1c"

# ---------------------------------------------------------------------------
# Case 1d -- first create with neither: fail fast before any AWS deploy call
# ---------------------------------------------------------------------------
h1d="$work/h1d"; new_home "$h1d"; mkdir -p "$work/s1d"
EXTRA_ENV=(OPERATOR_CIDR=203.0.113.4/32)
run_deploy "$work/s1d" "$work/c1d" "$h1d" >"$work/o1d" 2>&1
rc=$?
EXTRA_ENV=()
check "first create with neither CreateNetwork nor VpcId exits non-zero" test "$rc" -ne 0
check "fail-fast remediation names CREATE_NETWORK=true" grep -Fq 'CREATE_NETWORK=true' "$work/o1d"
check "fail-fast remediation names VPC_ID" grep -Fq 'VPC_ID' "$work/o1d"
check "fail-fast makes NO cloudformation deploy call" \
  bash -c '! grep -Fq "cloudformation deploy" "$1"' _ "$work/c1d"

# ---------------------------------------------------------------------------
# Case 1e -- first create without OPERATOR_CIDR dies before AWS
# ---------------------------------------------------------------------------
h1e="$work/h1e"; new_home "$h1e"; mkdir -p "$work/s1e"
run_deploy "$work/s1e" "$work/c1e" "$h1e" >"$work/o1e" 2>&1
rc=$?
check "first create without OPERATOR_CIDR exits non-zero" test "$rc" -ne 0
check "first-create error names OPERATOR_CIDR" grep -Fq 'OPERATOR_CIDR' "$work/o1e"
check "first-create OPERATOR_CIDR failure makes NO deploy call" \
  bash -c '! grep -Fq "cloudformation deploy" "$1"' _ "$work/c1e"

# ---------------------------------------------------------------------------
# Case 2 -- a non-operator identity is rejected before deploying
# ---------------------------------------------------------------------------
h2="$work/h2"; new_home "$h2"; mkdir -p "$work/s2"
EXTRA_ENV=(OPERATOR_CIDR=203.0.113.4/32 FAKE_AWS_STRIM_ARN=arn:aws:iam::183438553939:user/admin)
run_deploy "$work/s2" "$work/c2" "$h2" >"$work/o2" 2>&1
rc=$?
EXTRA_ENV=()
check "wrong identity exits non-zero" test "$rc" -ne 0
check "wrong identity names the expected :user/strimserver" grep -Fq -- ':user/strimserver' "$work/o2"
check "no deploy runs under a wrong identity" \
  bash -c '! grep -Fq "cloudformation deploy" "$1"' _ "$work/c2"

# ---------------------------------------------------------------------------
# Live-stack fixture: an existing stack with non-default values.
# ---------------------------------------------------------------------------
write_live_stack() { # write_live_stack <state> <floor>
  mkdir -p "$1"
  cat >"$1/stack-params" <<EOF
CreateNetwork=false
OperatorCidr=198.51.100.7/32
IngestCidr=0.0.0.0/0
EnableExperimentalSsh=true
EnableSessionManager=false
VpcId=vpc-abc123
VpcCidr=10.9.0.0/16
SubnetCidr=10.9.1.0/24
ControllerPort=4100
SrtPort=9100
DeploymentBucketName=live-bucket
ExperimentalSshPort=2200
NvidiaDriverFloor=$2
EOF
  printf 'UPDATE_COMPLETE' >"$1/stack-status"
}

# ---------------------------------------------------------------------------
# Case 3 -- an update does NOT re-pass live parameters (defaults authoritative)
# ---------------------------------------------------------------------------
h3="$work/h3"; new_home "$h3"; mkdir -p "$work/s3"
write_live_stack "$work/s3" "$nvidia_floor"
run_deploy "$work/s3" "$work/c3" "$h3" >"$work/o3" 2>&1
rc=$?
check "live-stack update exits 0" test "$rc" -eq 0
deploy3="$(grep -m1 'cloudformation deploy' "$work/c3" || true)"
for absent in CreateNetwork= EnableExperimentalSsh= EnableSessionManager= \
  VpcId= VpcCidr= SubnetCidr= ControllerPort= SrtPort= \
  DeploymentBucketName= ExperimentalSshPort= NvidiaDriverFloor=; do
  check "live parameter is NOT re-passed: $absent" \
    bash -c '[[ "$1" != *"$2"* ]]' _ "$deploy3" "$absent"
done
check "only ProjectName is passed on a no-override update" \
  bash -c '[[ "$1" == *ProjectName=strimserver* ]]' _ "$deploy3"
check "post-deploy sees UPDATE_COMPLETE" grep -Fq 'UPDATE_COMPLETE' "$work/o3"

# ---------------------------------------------------------------------------
# Case 4 -- explicit env overrides win, unset values stay unpassed
# ---------------------------------------------------------------------------
h4="$work/h4"; new_home "$h4"; mkdir -p "$work/s4"
write_live_stack "$work/s4" "$nvidia_floor"
EXTRA_ENV=(OPERATOR_CIDR=203.0.113.9/32 S3_BUCKET_NAME=new-bucket CREATE_NETWORK=true)
run_deploy "$work/s4" "$work/c4" "$h4" >"$work/o4" 2>&1
rc=$?
EXTRA_ENV=()
check "override run exits 0" test "$rc" -eq 0
deploy4="$(grep -m1 'cloudformation deploy' "$work/c4" || true)"
check "OPERATOR_CIDR maps to both CIDR parameters" \
  bash -c '[[ "$1" == *OperatorCidr=203.0.113.9/32* && "$1" == *IngestCidr=203.0.113.9/32* ]]' _ "$deploy4"
check "S3_BUCKET_NAME maps to DeploymentBucketName" \
  bash -c '[[ "$1" == *DeploymentBucketName=new-bucket* ]]' _ "$deploy4"
check "CREATE_NETWORK maps to CreateNetwork" \
  bash -c '[[ "$1" == *CreateNetwork=true* ]]' _ "$deploy4"
check "un-overridden live parameters are NOT force-fed" \
  bash -c '[[ "$1" != *ControllerPort=* && "$1" != *VpcId=* ]]' _ "$deploy4"

# ---------------------------------------------------------------------------
# Case 4b -- explicit VPC_ID is passed on update
# ---------------------------------------------------------------------------
h4b="$work/h4b"; new_home "$h4b"; mkdir -p "$work/s4b"
write_live_stack "$work/s4b" "$nvidia_floor"
EXTRA_ENV=(VPC_ID=vpc-override999)
run_deploy "$work/s4b" "$work/c4b" "$h4b" >"$work/o4b" 2>&1
rc=$?
EXTRA_ENV=()
check "update with VPC_ID override exits 0" test "$rc" -eq 0
deploy4b="$(grep -m1 'cloudformation deploy' "$work/c4b" || true)"
check "VPC_ID maps to VpcId" \
  bash -c '[[ "$1" == *VpcId=vpc-override999* ]]' _ "$deploy4b"

# ---------------------------------------------------------------------------
# Case 5 -- stack name must equal ProjectName (policy ARNs depend on it)
# ---------------------------------------------------------------------------
h5="$work/h5"; new_home "$h5"; mkdir -p "$work/s5"
run_deploy "$work/s5" "$work/c5" "$h5" --stack-name other-stack >"$work/o5" 2>&1
rc=$?
check "a stack name differing from the project exits non-zero" test "$rc" -ne 0
check "stack/project mismatch explains the ARN scoping" \
  bash -c 'grep -Fqi "must equal" "$1" && grep -Fqi "project" "$1"' _ "$work/o5"
check "stack/project mismatch makes NO deploy call" \
  bash -c '! grep -Fq "cloudformation deploy" "$1"' _ "$work/c5"

# ---------------------------------------------------------------------------
# Case 6 -- the deploy runs under a bounded timeout wrapper
# ---------------------------------------------------------------------------
check "deploy-infra defines a bounded deploy timeout (default 900s)" \
  bash -c 'grep -Fq "CFN_DEPLOY_TIMEOUT:-900" "$1"' _ "$deploy_infra"
check "deploy-infra wraps cloudformation deploy in timeout" \
  bash -c 'grep -Eq "timeout[[:space:]]+\"?\\\$\\{?CFN_DEPLOY_TIMEOUT" "$1"' _ "$deploy_infra"

# ---------------------------------------------------------------------------
# Case 7 -- NvidiaDriverFloor drift from lib/nvidia.sh fails loud
# ---------------------------------------------------------------------------
h7="$work/h7"; new_home "$h7"; mkdir -p "$work/s7"
write_live_stack "$work/s7" "$nvidia_floor"
EXTRA_ENV=(FAKE_AWS_DESCRIBE_FLOOR=999.0.0)
run_deploy "$work/s7" "$work/c7" "$h7" >"$work/o7" 2>&1
rc=$?
EXTRA_ENV=()
check "NvidiaDriverFloor drift exits non-zero" test "$rc" -ne 0
check "drift message names NvidiaDriverFloor and the lib floor" \
  bash -c 'grep -Fiq "NvidiaDriverFloor" "$1" && grep -Fq "$2" "$1"' _ "$work/o7" "$nvidia_floor"

# ---------------------------------------------------------------------------
# Case 8 -- the BakedImagePipeline must exist after deploy
# ---------------------------------------------------------------------------
h8="$work/h8"; new_home "$h8"; mkdir -p "$work/s8"
write_live_stack "$work/s8" "$nvidia_floor"
EXTRA_ENV=(FAKE_AWS_NO_PIPELINE=1)
run_deploy "$work/s8" "$work/c8" "$h8" >"$work/o8" 2>&1
rc=$?
EXTRA_ENV=()
check "a missing BakedImagePipeline exits non-zero" test "$rc" -ne 0
check "missing-pipeline message names BakedImagePipeline" grep -Fq 'BakedImagePipeline' "$work/o8"

# ---------------------------------------------------------------------------
# Structural baked-AMI assertions (retained from the old suite)
# ---------------------------------------------------------------------------
infra_template="$script_dir/strimserver-infra.yaml"
operator_template="$script_dir/strimserver-operator.yaml"

extract_template_resource() {
  awk -v name="$1" '
    $0 ~ "^  " name ":" {p=1; print; next}
    p && /^  [A-Za-z0-9]+:/ {p=0}
    p {print}
  ' "$infra_template"
}

# PyYAML is absent from the build image, so parse the resource's Properties
# block structurally: only 6-space keys are direct children of Properties;
# nested keys are deeper and therefore ignored. This is deliberately stricter
# than grepping raw tokens (the old RuleName guard passed on an invalid
# property that CFN silently ignored).
properties_keys() {
  awk '
    /^    Properties:[[:space:]]*$/ { inprops=1; next }
    inprops && /^    [^[:space:]]/ { inprops=0 }
    inprops && /^      [A-Za-z0-9]+:/ { key=$1; sub(/:$/, "", key); print key }
  ' <<<"$1"
}

property_value() { # property_value <resource-block> <key>
  awk -v want="$2" '
    /^    Properties:[[:space:]]*$/ { inprops=1; next }
    inprops && /^    [^[:space:]]/ { inprops=0 }
    inprops && index($0, "      " want ":") == 1 {
      sub("^      " want ":[[:space:]]*", "")
      print
      exit
    }
  ' <<<"$1"
}

# input_template_scalar <resource-block>: print the raw YAML scalar assigned to
# the target's InputTemplate. It is a single-quoted YAML string holding JSON, so
# the surrounding quotes are stripped to expose the JSON template EventBridge
# actually interpolates.
input_template_scalar() {
  awk '
    /^[[:space:]]*InputTemplate:[[:space:]]*/ {
      sub(/^[[:space:]]*InputTemplate:[[:space:]]*/, "")
      print
      exit
    }
  ' <<<"$1"
}

check "infra template exists" test -f "$infra_template"
check "operator template exists" test -f "$operator_template"

# --- split boundary ---------------------------------------------------------
check "infra template creates NO IAM resources (identity lives in the operator template)" \
  bash -c '! grep -Fq "AWS::IAM::" "$1"' _ "$infra_template"
check "infra template does not create the strimserver user or operator policy" \
  bash -c '! grep -Fq "StrimserverServiceUser" "$1" && ! grep -Fq "StrimserverOperatorPolicy" "$1"' _ "$infra_template"
check "operator template owns the IAM user/policy" \
  bash -c 'grep -Fq "StrimserverServiceUser:" "$1" && grep -Fq "StrimserverOperatorPolicy:" "$1"' _ "$operator_template"
check "infra references the operator's Image Builder instance profile by fixed name" \
  bash -c 'grep -Fq -- "-baked-imagebuilder-instance-profile" "$1"' _ "$infra_template"
check "infra references the operator's AMI-publish role by fixed name" \
  bash -c 'grep -Fq -- "-baked-publish-role" "$1"' _ "$infra_template"
check "every infra ImportValue has a matching operator Export" \
  bash -c '
    imports="$(grep -oE "!ImportValue[[:space:]]+[A-Za-z0-9_.:-]+" "$1" | awk "{print \$2}" || true)"
    for name in $imports; do grep -Fq "Name: ${name}" "$2" || exit 1; done
  ' _ "$infra_template" "$operator_template"

check "NvidiaDriverFloor parameter default equals the repo floor" \
  bash -c 'grep -A4 "^  NvidiaDriverFloor:" "$1" | grep -Fq "Default: \"$2\""' _ "$infra_template" "$nvidia_floor"

component_block="$(extract_template_resource BakedImageComponent)"
recipe_block="$(extract_template_resource BakedImageRecipe)"
infra_config_block="$(extract_template_resource BakedInfrastructureConfiguration)"
distribution_block="$(extract_template_resource BakedDistributionConfiguration)"
pipeline_block="$(extract_template_resource BakedImagePipeline)"
publish_rule_block="$(extract_template_resource BakedAmiPublishRule)"

check "Image Builder component exists (AWS::ImageBuilder::Component)" \
  bash -c 'grep -Fq "Type: AWS::ImageBuilder::Component" <<<"$1"' _ "$component_block"
check "component sources the repo NVIDIA floor machinery (lib/nvidia.sh)" \
  bash -c 'grep -Fq "deploy/aws/lib/nvidia.sh" <<<"$1"' _ "$component_block"
check "component invokes the repo floor function nvidia_ensure_driver_floor" \
  bash -c 'grep -Fq "nvidia_ensure_driver_floor" <<<"$1"' _ "$component_block"
check "component installs htop" \
  bash -c 'grep -Fq "htop" <<<"$1"' _ "$component_block"
check "component installs the bundled openssh-experimental RPM" \
  bash -c 'grep -Fq "openssh-experimental.rpm" <<<"$1"' _ "$component_block"
check "component writes the canonical containerd root" \
  bash -c 'grep -Fq "root='"'"'/mnt/nvme/containerd'"'"'" <<<"$1"' _ "$component_block"
check "component writes the canonical containerd state" \
  bash -c 'grep -Fq "state='"'"'/mnt/nvme/containerd-state'"'"'" <<<"$1"' _ "$component_block"
check "component enables nvidia-persistenced" \
  bash -c 'grep -Fq "systemctl enable nvidia-persistenced" <<<"$1"' _ "$component_block"

check "ImageRecipe exists (AWS::ImageBuilder::ImageRecipe)" \
  bash -c 'grep -Fq "Type: AWS::ImageBuilder::ImageRecipe" <<<"$1"' _ "$recipe_block"
check "recipe's base image is the pinned DLAMI ami-0198b63ccfac121e8" \
  bash -c 'grep -Fq "ParentImage: ami-0198b63ccfac121e8" <<<"$1"' _ "$recipe_block"
check "recipe carries the strimserver:nvidia-driver tag key" \
  bash -c 'grep -Fq "strimserver:nvidia-driver" <<<"$1"' _ "$recipe_block"
check "recipe tag value is wired to the NvidiaDriverFloor parameter (not a literal)" \
  bash -c 'grep -Fq "!Ref NvidiaDriverFloor" <<<"$1"' _ "$recipe_block"

check "InfrastructureConfiguration exists (AWS::ImageBuilder::InfrastructureConfiguration)" \
  bash -c 'grep -Fq "Type: AWS::ImageBuilder::InfrastructureConfiguration" <<<"$1"' _ "$infra_config_block"
check "DistributionConfiguration exists (AWS::ImageBuilder::DistributionConfiguration)" \
  bash -c 'grep -Fq "Type: AWS::ImageBuilder::DistributionConfiguration" <<<"$1"' _ "$distribution_block"
check "distribution publishes to us-east-2" \
  bash -c 'grep -Fq "Region: us-east-2" <<<"$1"' _ "$distribution_block"
check "distribution is us-east-2 ONLY (exactly one Region entry)" \
  bash -c '[ "$(grep -cE "^[[:space:]]*(- )?Region:" <<<"$1")" -eq 1 ]' _ "$distribution_block"

check "ImagePipeline exists (AWS::ImageBuilder::ImagePipeline)" \
  bash -c 'grep -Fq "Type: AWS::ImageBuilder::ImagePipeline" <<<"$1"' _ "$pipeline_block"
check "ImagePipeline wires the execution role" \
  bash -c 'grep -Fq "ExecutionRole:" <<<"$1" && grep -Fq -- "-baked-imagebuilder-execution-role" <<<"$1"' _ "$pipeline_block"
check "pipeline has NO schedule (manual trigger only)" \
  bash -c '! grep -Fq "Schedule:" <<<"$1"' _ "$pipeline_block"
check "pipeline documents the monthly-rebuild TODO" \
  bash -c 'grep -Fiq "monthly" "$1"' _ "$infra_template"
check "InfrastructureConfiguration references the operator's instance profile name" \
  bash -c 'grep -Fq -- "-baked-imagebuilder-instance-profile" <<<"$1"' _ "$infra_config_block"
# The account has no default VPC, so an InfrastructureConfiguration without a
# subnet fails at LaunchBuildInstance (VPCIdNotSpecified). The build instance
# must launch into the stack-managed public subnet with the stack SG.
check "InfrastructureConfiguration launches into the stack-managed subnet" \
  bash -c 'grep -Fq "SubnetId: !Ref ManagedSubnet" <<<"$1"' _ "$infra_config_block"
check "InfrastructureConfiguration attaches the stack instance security group" \
  bash -c 'grep -Fq "SecurityGroupIds: [!Ref InstanceSecurityGroup]" <<<"$1"' _ "$infra_config_block"
document_block="$(extract_template_resource BakedAmiPublishDocument)"
check "SSM publish document sets Properties.Name (valid AWS::SSM::Document property)" \
  test "$(property_value "$document_block" Name)" = '!Sub "${ProjectName}-baked-ami-publish"'

# The automation must ASSUME the operator-owned publish role. Without an
# assumeRole binding the steps run with no assumed identity, so the
# ssm:PutParameter step is denied even though EventBridge started the execution.
automation_role_param="$(awk '
  /^          AutomationAssumeRole:[[:space:]]*$/ {p=1; next}
  p && /^          [A-Za-z0-9]+:/ {p=0}
  p {print}
' <<<"$document_block")"
check "publish document declares the AutomationAssumeRole parameter" \
  bash -c 'grep -Fq "AutomationAssumeRole:" <<<"$1"' _ "$document_block"
check "AutomationAssumeRole parameter is a String" \
  bash -c 'grep -Fq "type: String" <<<"$1"' _ "$automation_role_param"
check "AutomationAssumeRole defaults to the ProjectName-derived publish role ARN" \
  bash -c 'grep -Fq -- "$2" <<<"$1"' _ "$automation_role_param" \
    'default: !Sub "arn:${AWS::Partition}:iam::${AWS::AccountId}:role/${ProjectName}-baked-publish-role"'
check "publish document binds the top-level assumeRole to AutomationAssumeRole" \
  bash -c 'grep -Fxq "        assumeRole: \"{{ AutomationAssumeRole }}\"" <<<"$1"' _ "$document_block"

# The role binding is additive: the parameter and step that actually publish
# the AMI id must survive unchanged.
check "publish document keeps the AmiId String parameter" \
  bash -c 'grep -Fq "AmiId:" <<<"$1"' _ "$document_block"
check "publish document keeps the executeAwsApi PutParameter step" \
  bash -c 'grep -Fq "name: putBakedAmiParameter" <<<"$1" && grep -Fq "Api: PutParameter" <<<"$1"' _ "$document_block"

publish_rule_name="$(property_value "$publish_rule_block" Name)"
publish_rule_keys="$(properties_keys "$publish_rule_block")"

check "BakedAmiPublishRule sets Properties.Name to the deterministic ProjectName-derived name" \
  test "$publish_rule_name" = '!Sub "${ProjectName}-baked-ami-publish"'
check "BakedAmiPublishRule has no invalid RuleName property (Events Rule property is Name)" \
  bash -c '! grep -Fxq "RuleName" <<<"$1"' _ "$publish_rule_keys"

# The target's InputTemplate is JSON with an EventBridge <ami> placeholder. An
# unquoted placeholder makes EventBridge emit {"AmiId": ami-...} (invalid JSON),
# so StartAutomationExecution fails at target invocation. Pin both the quoted
# placeholder and end-to-end JSON validity after substitution.
sample_ami="ami-0123456789abcdef0"
publish_input_template="$(input_template_scalar "$publish_rule_block")"
publish_input_template="${publish_input_template#\'}"
publish_input_template="${publish_input_template%\'}"
check "BakedAmiPublishRule InputTemplate contains the QUOTED <ami> placeholder" \
  bash -c 'grep -Fq -- "$2" <<<"$1"' _ "$publish_input_template" '"<ami>"'
check "BakedAmiPublishRule InputTemplate renders valid JSON once <ami> is substituted" \
  bash -c 'printf "%s" "$1" | sed "s/<ami>/$2/" | python3 -c "import json, sys; json.load(sys.stdin)"' \
    _ "$publish_input_template" "$sample_ami"

check "publish Name matches the operator policy's events rule scope" \
  bash -c 'grep -Fq "rule/\${ProjectName}-baked-ami-publish" "$1"' _ "$operator_template"

check "infra declares DeploymentBucketName" \
  bash -c 'grep -Eq "^  DeploymentBucketName:" "$1"' _ "$infra_template"
check "infra declares EnableSessionManager" \
  bash -c 'grep -Eq "^  EnableSessionManager:" "$1"' _ "$infra_template"
check "infra declares AvailabilityZone" \
  bash -c 'grep -Eq "^  AvailabilityZone:" "$1"' _ "$infra_template"
check "infra declares the HasAvailabilityZone condition" \
  bash -c 'grep -Fq "HasAvailabilityZone:" "$1"' _ "$infra_template"

check "produced AMI id is published to /strimserver/ami/baked/latest" \
  bash -c 'grep -Fq "/strimserver/ami/baked/latest" "$1"' _ "$infra_template"
check "an SSM automation document writes the baked AMI id (PutParameter)" \
  bash -c 'grep -Fq "AWS::SSM::Document" "$1" && grep -Fq "PutParameter" "$1"' _ "$infra_template"

if [[ "$failures" -eq 0 ]]; then
  echo "PASS: deploy-infra profile-run behaviour OK"
  exit 0
fi
echo "FAILED: $failures assertion(s)" >&2
exit 1
