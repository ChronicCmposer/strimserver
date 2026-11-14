#!/usr/bin/env bash
# operator_template_test.sh -- structural assertions on the template split.
#
# The durable identity surface lives in strimserver-operator.yaml (deployed once
# by provision-account with ADMIN credentials); the regional resources live in
# strimserver-infra.yaml (deployed by deploy-infra as the operator). This test
# enshrines the split AND the operator policy's LEAST PRIVILEGE:
#
#   * the operator template owns the service user, the single project-scoped
#     operator managed policy, the EC2 instance role/profile and every Image
#     Builder role the policy passes to its services;
#   * the operator policy grants exactly the actions the strimserver tooling
#     actually calls (derived from the `aws` CLI calls in deploy/aws/launch,
#     deploy/aws/terminate, deploy-infra and the publish/bucket scripts), must
#     NOT carry account-wide IAM administration, must scope S3 to the deployment
#     bucket, and must not mention route53;
#   * every ARN and resource name derives from ${ProjectName}; no policy ARN
#     hardcodes "strimserver" or pins ${AWS::Region};
#   * the account-global InstanceRole carries the <ProjectName>-boundary
#     permissions boundary;
#   * the infra template owns only regional resources and creates NO IAM, wires
#     the Image Builder execution role into the pipeline, and supports an
#     optional AvailabilityZone.
#
# PyYAML is not available in the build image, so this test uses a structural
# extractor (awk) + grep, matching the sibling repo's fallback style.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The paths are overridable so the mutation check below can re-run this test
# against a throwaway copy; they default to the sibling templates (Bazel
# runfiles keep the templates adjacent to the test).
operator_template="${STRIMSERVER_OPERATOR_TEMPLATE:-$script_dir/strimserver-operator.yaml}"
infra_template="${STRIMSERVER_INFRA_TEMPLATE:-$script_dir/strimserver-infra.yaml}"

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

[[ -f "$operator_template" ]] || { echo "FAIL: operator template not found: $operator_template" >&2; exit 1; }
[[ -f "$infra_template" ]] || { echo "FAIL: infra template not found: $infra_template" >&2; exit 1; }

# extract_resource <file> <Name>: print the YAML block for a top-level (2-space)
# resource.
extract_resource() {
  awk -v name="$2" '
    $0 ~ "^  " name ":" {p=1; print; next}
    p && /^  [A-Za-z0-9]+:/ {p=0}
    p {print}
  ' "$1"
}

# Properties parsing without PyYAML: only 6-space keys are direct children of
# Properties; nested keys are deeper and ignored. This catches an invalid
# property that a raw token grep would happily accept (the live RuleName bug).
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

service_user="$(extract_resource "$operator_template" StrimserverServiceUser)"
operator_policy_block="$(extract_resource "$operator_template" StrimserverOperatorPolicy)"
infra_lifecycle_policy_block="$(extract_resource "$operator_template" StrimserverOperatorInfraLifecyclePolicy)"
# The identity/deploy/launch and infra-lifecycle policies are two halves of the
# operator's effective permissions. Every action/allowlist assertion below runs
# against BOTH merged documents so the split cannot silently drop a grant.
operator_policy="$operator_policy_block
$infra_lifecycle_policy_block"
instance_role="$(extract_resource "$operator_template" InstanceRole)"
boundary_policy="$(extract_resource "$operator_template" StrimserverOperatorBoundary)"

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

# managed_policy_names: print every top-level resource whose Type is
# AWS::IAM::ManagedPolicy (the policy-size quota applies to each one).
managed_policy_names() {
  awk '
    /^  [A-Za-z0-9]+:/ { name=$1; sub(/:$/, "", name) }
    /^    Type: AWS::IAM::ManagedPolicy[[:space:]]*$/ { print name }
  ' "$operator_template"
}

# policy_document_size: JSON-serialize a resource block'"'"'s PolicyDocument the
# way IAM stores it (compact, no whitespace) and print the byte length. PyYAML
# is not available in the build image, so this is a stdlib-only YAML subset
# parser covering the constructs the templates use (block mappings/sequences,
# quoted/plain scalars and CloudFormation intrinsic tags). Fn::If branches that
# resolve to AWS::NoValue are dropped and the remaining branch is measured, so
# the result matches the deployed (conditional) document.
policy_document_size() {
  python3 - "$1" <<'PY'
import json
import sys


def parse_scalar(token):
    token = token.strip()
    for tag in ("!Sub", "!Ref", "!GetAtt", "!GetAZs", "!ImportValue",
                "!Base64", "!Select", "!Split", "!Join"):
        if token == tag:
            return token
        if token.startswith(tag + " "):
            token = token[len(tag) + 1:].strip()
            break
    if len(token) >= 2 and token[0] == token[-1] and token[0] in "\"'":
        token = token[1:-1]
    if token in ("true", "false", "True", "False"):
        return token.lower() == "true"
    if token in ("null", "~", "Null"):
        return None
    return token


def parse_nodes(lines, index):
    if index >= len(lines):
        return None, index
    indent, text = lines[index]
    if text.startswith("- "):
        return parse_sequence(lines, index, indent)
    return parse_mapping(lines, index, indent)


def parse_mapping(lines, index, indent):
    result = {}
    while index < len(lines):
        line_indent, text = lines[index]
        if line_indent != indent or text.startswith("- "):
            break
        key, separator, value = text.partition(":")
        if not separator:
            raise SystemExit("not a mapping entry: %r" % text)
        index += 1
        if value.strip() == "":
            if index < len(lines) and lines[index][0] > indent:
                parsed, index = parse_nodes(lines, index)
            else:
                parsed = None
        else:
            parsed = parse_scalar(value)
        result[key.strip()] = parsed
    return result, index


def parse_sequence(lines, index, indent):
    result = []
    while index < len(lines):
        line_indent, text = lines[index]
        if line_indent != indent or not text.startswith("- "):
            break
        item = text[2:].strip()
        if item == "":
            parsed, index = parse_nodes(lines, index + 1)
            result.append(parsed)
            continue
        if item == "!If":
            parsed, index = parse_nodes(lines, index + 1)
            result.append({"!If": parsed})
            continue
        if ":" in item and not item.startswith(("!", "\"", "'")):
            map_indent = line_indent + 2
            virtual = [(map_indent, item)]
            following = index + 1
            while following < len(lines) and lines[following][0] > line_indent:
                virtual.append(lines[following])
                following += 1
            parsed, _ = parse_mapping(virtual, 0, map_indent)
            result.append(parsed)
            index = following
            continue
        result.append(parse_scalar(item))
        index += 1
    return result, index


def is_no_value(node):
    if node is None:
        return True
    if isinstance(node, str) and node in ("AWS::NoValue", "!Ref AWS::NoValue"):
        return True
    return isinstance(node, dict) and node.get("!Ref") == "AWS::NoValue"


def resolve(node):
    if isinstance(node, list):
        return [resolve(item) for item in node if not is_no_value(item)]
    if isinstance(node, dict):
        if list(node.keys()) == ["!If"]:
            branch = node["!If"]
            if not isinstance(branch, list) or len(branch) < 2:
                return resolve(branch)
            if len(branch) >= 3 and not is_no_value(branch[2]):
                # Both branches exist: measure the larger (safe upper bound).
                candidates = [resolve(branch[1]), resolve(branch[2])]
                return max(candidates,
                           key=lambda c: len(json.dumps(c, separators=(",", ":"))))
            return resolve(branch[1])
        return {key: resolve(value) for key, value in node.items()
                if not is_no_value(value)}
    return node


def measure(block):
    raw_lines = block.splitlines()
    start = None
    base_indent = None
    for number, line in enumerate(raw_lines):
        if line.strip() == "PolicyDocument:":
            start = number
            base_indent = len(line) - len(line.lstrip())
            break
    if start is None:
        raise SystemExit("no PolicyDocument in resource block")

    document_lines = []
    for line in raw_lines[start + 1:]:
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        if indent <= base_indent:
            break
        text = line.strip()
        if text.startswith("#"):
            continue
        document_lines.append((indent, text))
    if not document_lines:
        raise SystemExit("empty PolicyDocument")

    document, _ = parse_nodes(document_lines, 0)
    print(len(json.dumps(resolve(document), separators=(",", ":"))))


measure(sys.argv[1])
PY
}

# --- split boundary -----------------------------------------------------------
check "operator template owns the service user named after ProjectName" \
  bash -c 'grep -Fq "Type: AWS::IAM::User" "$1" && grep -Fq "UserName: !Ref ProjectName" <<<"$2"' _ "$operator_template" "$service_user"
check "operator template owns the EC2 instance role + profile" \
  bash -c 'grep -Fq "InstanceRole:" "$1" && grep -Fq "InstanceProfile:" "$1"' _ "$operator_template"
check "operator template owns the Image Builder roles" \
  bash -c 'for r in BakedImageBuilderInstanceRole BakedImageBuilderInstanceProfile BakedImageBuilderExecutionRole BakedAmiPublishRole; do grep -Fq "$r:" "$1" || exit 1; done' _ "$operator_template"
check "operator template is account identity only (no VPC/subnet/security group)" \
  bash -c '! grep -Eq "AWS::EC2::(VPC|Subnet|SecurityGroup|InternetGateway|RouteTable|Route)" "$1"' _ "$operator_template"
check "operator template has no Image Builder build resources" \
  bash -c '! grep -Fq "AWS::ImageBuilder::" "$1"' _ "$operator_template"
check "operator template has no SSM automation document" \
  bash -c '! grep -Fq "AWS::SSM::Document" "$1"' _ "$operator_template"
check "operator template has no EventBridge rule" \
  bash -c '! grep -Fq "AWS::Events::Rule" "$1"' _ "$operator_template"

check "infra template creates NO IAM resources" \
  bash -c '! grep -Fq "AWS::IAM::" "$1"' _ "$infra_template"
check "infra template does not create the service user or operator policy" \
  bash -c '! grep -Fq "StrimserverServiceUser" "$1" && ! grep -Fq "StrimserverOperatorPolicy" "$1"' _ "$infra_template"
check "infra template owns the network security group" \
  bash -c 'grep -Fq "AWS::EC2::SecurityGroup" "$1"' _ "$infra_template"
check "infra template owns the Image Builder pipeline" \
  bash -c 'grep -Fq "AWS::ImageBuilder::ImagePipeline" "$1"' _ "$infra_template"

# The infra stack references the operator-owned identity by deterministic names
# (movienight convention: no cross-stack ImportValue for IAM).
check "infra references the operator's Image Builder instance profile by fixed name" \
  bash -c 'grep -Fq -- "-baked-imagebuilder-instance-profile" "$1"' _ "$infra_template"
check "infra references the operator's AMI-publish role by fixed name" \
  bash -c 'grep -Fq -- "-baked-publish-role" "$1"' _ "$infra_template"
check "operator declares the same Image Builder instance profile name" \
  bash -c 'grep -Fq -- "-baked-imagebuilder-instance-profile" "$1"' _ "$operator_template"
check "operator declares the same AMI-publish role name" \
  bash -c 'grep -Fq -- "-baked-publish-role" "$1"' _ "$operator_template"
check "every infra ImportValue has a matching operator Export" \
  bash -c '
    imports="$(grep -oE "!ImportValue[[:space:]]+[A-Za-z0-9_.:-]+" "$1" | awk "{print \$2}" || true)"
    for name in $imports; do grep -Fq "Name: ${name}" "$2" || exit 1; done
  ' _ "$infra_template" "$operator_template"

# --- preserved policy/code invariants ----------------------------------------
check "standalone DLAMI read policy name is gone (strimserver-ssm-dlami-readonly)" \
  bash -c '! grep -Fq "strimserver-ssm-dlami-readonly" "$1"' _ "$operator_template"
check "standalone DLAMI read policy resource is gone (StrimserverDlamiReadPolicy)" \
  bash -c '! grep -Fq "StrimserverDlamiReadPolicy:" "$1"' _ "$operator_template"
check "operator policy covers both x86_64 + arm64 DLAMI SSM params" \
  bash -c 'grep -Fq "deeplearning/ami/x86_64/" <<<"$1" && grep -Fq "deeplearning/ami/arm64/" <<<"$1"' _ "$operator_policy"
check "operator policy grants ec2:Describe* (covers check-deps DLAMI metadata)" \
  bash -c 'grep -Fq "ec2:Describe*" <<<"$1"' _ "$operator_policy"
check "operator policy covers the ProjectName-derived baked-AMI SSM parameter" \
  bash -c 'grep -Fq "parameter/\${ProjectName}/ami/baked/latest" <<<"$1"' _ "$operator_policy"
check "exactly TWO managed policies attach to the user (Users: appears twice)" \
  bash -c '[ "$(grep -c "Users:" "$1")" -eq 2 ]' _ "$operator_template"
# Two AWS::IAM::ManagedPolicy resources attached to one user: each must name
# the service user, otherwise only half of the operator surface is granted.
check "both operator policies attach to the service user" \
  bash -c 'grep -Fq "Users:" <<<"$1" && grep -Fq "StrimserverServiceUser" <<<"$1"' _ "$operator_policy_block"
check "infra-lifecycle policy attaches to the service user" \
  bash -c 'grep -Fq "Users:" <<<"$1" && grep -Fq "StrimserverServiceUser" <<<"$1"' _ "$infra_lifecycle_policy_block"

# --- operator policy identity -------------------------------------------------
check "operator policy exists (AWS::IAM::ManagedPolicy)" \
  bash -c 'grep -Fq "Type: AWS::IAM::ManagedPolicy" <<<"$1"' _ "$operator_policy_block"
check "operator policy name derives from ProjectName" \
  bash -c 'grep -Fq "ManagedPolicyName: !Sub \"\${ProjectName}-operator\"" <<<"$1"' _ "$operator_policy_block"
check "operator policy attached to the service user" \
  bash -c 'grep -Fq "StrimserverServiceUser" <<<"$1"' _ "$operator_policy_block"
check "infra-lifecycle policy exists (AWS::IAM::ManagedPolicy)" \
  bash -c 'grep -Fq "Type: AWS::IAM::ManagedPolicy" <<<"$1"' _ "$infra_lifecycle_policy_block"
check "infra-lifecycle policy name derives from ProjectName" \
  bash -c 'grep -Fq "ManagedPolicyName: !Sub \"\${ProjectName}-operator-infra-lifecycle\"" <<<"$1"' _ "$infra_lifecycle_policy_block"

# --- policy split: statements live in exactly one of the two policies --------
deploy_launch_sids="CloudFormationReadStack CloudFormationGetTemplateSummary \
CloudFormationDeployStack SsmDlamiLookup SelfKeyRotation PassStrimserverRole \
PassImageBuilderRoles GetImageBuilderInstanceProfile ImageBuilderServiceLinkedRole \
Ec2Describe Ec2RunInstances Ec2RunInstancesDependencies Ec2CreateTags \
Ec2TerminateInstances S3BucketConfig S3Objects"
infra_lifecycle_sids="Ec2VpcLifecycle ImageBuilderRead ImageBuilderLifecycle \
ImageBuilderRebuild BakedAmiEventsLifecycle SsmDocumentLifecycle"
for sid in $deploy_launch_sids; do
  check "$sid stays in the identity/deploy/launch policy" \
    bash -c 'grep -Fq -- "- Sid: $2" <<<"$1"' _ "$operator_policy_block" "$sid"
done
for sid in $infra_lifecycle_sids; do
  check "$sid moved to the infra-lifecycle policy" \
    bash -c 'grep -Fq -- "- Sid: $2" <<<"$1"' _ "$infra_lifecycle_policy_block" "$sid"
  check "$sid is not duplicated in the identity/deploy/launch policy" \
    bash -c '! grep -Fq -- "- Sid: $2" <<<"$1"' _ "$operator_policy_block" "$sid"
done

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
for action in \
  s3:ListBucket s3:GetBucketLocation s3:GetBucketPolicy s3:PutBucketPolicy \
  s3:GetObject s3:PutObject s3:PutObjectAcl s3:DeleteObject \
  'ec2:Describe*' \
  ec2:RunInstances ec2:TerminateInstances ec2:CreateTags \
  cloudformation:DescribeStacks \
  ssm:GetParameter \
  iam:PassRole iam:CreateAccessKey iam:ListAccessKeys iam:DeleteAccessKey; do
  check "operator policy grants $action" \
    bash -c 'grep -Fq -- "$2" <<<"$1"' _ "$operator_policy" "$action"
done

# --- deploy-infra + AMI-rebuild surface the operator owns ---------------------
cfn_deploy_stmt="$(extract_statement CloudFormationDeployStack)"
cfn_gtm_stmt="$(extract_statement CloudFormationGetTemplateSummary)"
cfn_read_stmt="$(extract_statement CloudFormationReadStack)"
pass_ib_stmt="$(extract_statement PassImageBuilderRoles)"
ib_rebuild_stmt="$(extract_statement ImageBuilderRebuild)"
ib_read_stmt="$(extract_statement ImageBuilderRead)"
vpc_stmt="$(extract_statement Ec2VpcLifecycle)"
ib_lifecycle_stmt="$(extract_statement ImageBuilderLifecycle)"
events_stmt="$(extract_statement BakedAmiEventsLifecycle)"
ssm_doc_stmt="$(extract_statement SsmDocumentLifecycle)"
get_instance_profile_stmt="$(extract_statement GetImageBuilderInstanceProfile)"
create_slr_stmt="$(extract_statement ImageBuilderServiceLinkedRole)"
publish_rule_block="$(extract_resource "$infra_template" BakedAmiPublishRule)"

check "CloudFormation deploy statement exists" \
  bash -c 'grep -Fq "cloudformation:CreateStack" <<<"$1" && grep -Fq "cloudformation:UpdateStack" <<<"$1"' _ "$cfn_deploy_stmt"
check "CloudFormation deploy is scoped to stack/\${ProjectName}/*" \
  bash -c 'grep -Fq "stack/\${ProjectName}/*" <<<"$1" && ! grep -Fq "Resource: \"*\"" <<<"$1"' _ "$cfn_deploy_stmt"
check "CloudFormation deploy carries the change-set actions aws deploy needs" \
  bash -c 'for a in CreateChangeSet DescribeChangeSet ExecuteChangeSet DeleteChangeSet; do grep -Fq "cloudformation:$a" <<<"$1" || exit 1; done' _ "$cfn_deploy_stmt"
check "CloudFormation deploy grants DeleteStack on the project stack only" \
  bash -c 'grep -Fq "cloudformation:DeleteStack" <<<"$1" && grep -Fq "stack/\${ProjectName}/*" <<<"$1"' _ "$cfn_deploy_stmt"
check "CloudFormation deploy uses a region wildcard" \
  bash -c 'grep -Fq "cloudformation:*:\${AWS::AccountId}:stack/" <<<"$1"' _ "$cfn_deploy_stmt"
check "GetTemplateSummary is granted on Resource \"*\"" \
  bash -c 'grep -Fq "cloudformation:GetTemplateSummary" <<<"$1" && grep -Fq "Resource: \"*\"" <<<"$1"' _ "$cfn_gtm_stmt"
check "the unused ValidateTemplate grant is gone" \
  bash -c '! grep -Fq "cloudformation:ValidateTemplate" <<<"$1"' _ "$operator_policy"
check "CloudFormation read statement covers DescribeStacks/DescribeStackEvents/GetTemplate" \
  bash -c 'for a in DescribeStacks DescribeStackEvents GetTemplate; do grep -Fq "cloudformation:$a" <<<"$1" || exit 1; done' _ "$cfn_read_stmt"

check "iam:PassRole covers both Image Builder roles" \
  bash -c 'grep -Fq "iam:PassRole" <<<"$1" && grep -Fq "baked-imagebuilder-instance-role" <<<"$1" && grep -Fq "baked-imagebuilder-execution-role" <<<"$1"' _ "$pass_ib_stmt"
check "iam:PassRole covers the AMI-publish role" \
  bash -c 'grep -Fq "baked-publish-role" <<<"$1"' _ "$pass_ib_stmt"
check "iam:PassRole uses deterministic !Sub role ARNs" \
  bash -c 'grep -Fq "arn:\${AWS::Partition}:iam::\${AWS::AccountId}:role/" <<<"$1"' _ "$pass_ib_stmt"
# Image Builder's distribution-configuration handler may pass a role to the
# VM Import/Export service, so vmie.amazonaws.com joins the PassedToService set.
check "iam:PassRole condition includes vmie.amazonaws.com (distribution handler)" \
  bash -c 'grep -Fq "vmie.amazonaws.com" <<<"$1"' _ "$pass_ib_stmt"
# CreateInfrastructureConfiguration/Update read the instance profile under the
# caller's identity, so the operator needs iam:GetInstanceProfile scoped to the
# one baked Image Builder profile.
check "operator policy grants iam:GetInstanceProfile for the baked Image Builder profile" \
  bash -c 'grep -Fq "iam:GetInstanceProfile" <<<"$1"' _ "$get_instance_profile_stmt"
check "iam:GetInstanceProfile is scoped to the exact baked instance-profile ARN" \
  bash -c 'grep -Fq "arn:\${AWS::Partition}:iam::\${AWS::AccountId}:instance-profile/\${ProjectName}-baked-imagebuilder-instance-profile" <<<"$1" && ! grep -Fq "Resource: \"*\"" <<<"$1"' _ "$get_instance_profile_stmt"
# Image Builder's first-ever use in an account must create its service-linked
# role; tightly scoped to exactly that SLR ARN.
check "operator policy grants iam:CreateServiceLinkedRole for Image Builder" \
  bash -c 'grep -Fq "iam:CreateServiceLinkedRole" <<<"$1"' _ "$create_slr_stmt"
check "iam:CreateServiceLinkedRole is scoped to the imagebuilder SLR role ARN" \
  bash -c 'grep -Fq "arn:\${AWS::Partition}:iam::\${AWS::AccountId}:role/aws-service-role/imagebuilder.amazonaws.com/AWSServiceRoleForImageBuilder" <<<"$1" && ! grep -Fq "Resource: \"*\"" <<<"$1"' _ "$create_slr_stmt"
check "ImageBuilder rebuild statement triggers the BakedImagePipeline" \
  bash -c 'grep -Fq "imagebuilder:StartImagePipelineExecution" <<<"$1"' _ "$ib_rebuild_stmt"
check "ImageBuilder rebuild is scoped to the ProjectName pipeline ARN" \
  bash -c 'grep -Fq "image-pipeline/\${ProjectName}-baked" <<<"$1" && ! grep -Fq "Resource: \"*\"" <<<"$1"' _ "$ib_rebuild_stmt"
# CloudFormation's ImageBuilder resource handlers perform read calls
# (GetComponent while creating an ImageRecipe, etc.) under the caller's
# identity; enumerated reads kept missing them. The read surface is the
# Get*/List* wildcard pair, scoped to the account's imagebuilder ARNs.
check "ImageBuilder read statement grants imagebuilder:Get*/List* wildcards" \
  bash -c 'grep -Fq "imagebuilder:Get*" <<<"$1" && grep -Fq "imagebuilder:List*" <<<"$1"' _ "$ib_read_stmt"
check "ImageBuilder read statement is scoped to the account's imagebuilder ARN" \
  bash -c 'grep -Fq "arn:aws:imagebuilder:*:\${AWS::AccountId}:" <<<"$1" && ! grep -Fq "Resource: \"*\"" <<<"$1"' _ "$ib_read_stmt"

# --- D.3: Image Builder / Events / SSM document lifecycle --------------------
check "Image Builder lifecycle statement covers Component CRUD" \
  bash -c 'for a in CreateComponent DeleteComponent; do grep -Fq "imagebuilder:$a" <<<"$1" || exit 1; done' _ "$ib_lifecycle_stmt"
check "Image Builder lifecycle statement covers the other resource types" \
  bash -c 'for a in CreateImageRecipe DeleteImageRecipe CreateInfrastructureConfiguration CreateDistributionConfiguration CreateImagePipeline UpdateImagePipeline DeleteImagePipeline; do grep -Fq "imagebuilder:$a" <<<"$1" || exit 1; done' _ "$ib_lifecycle_stmt"
check "Image Builder lifecycle is scoped to the account's imagebuilder resources" \
  bash -c 'grep -Fq "arn:aws:imagebuilder:*:\${AWS::AccountId}:" <<<"$1"' _ "$ib_lifecycle_stmt"
check "Image Builder lifecycle grants TagResource/UntagResource (CFN tags on create)" \
  bash -c 'for a in TagResource UntagResource; do grep -Fq "imagebuilder:$a" <<<"$1" || exit 1; done' _ "$ib_lifecycle_stmt"
check "Image Builder TagResource/UntagResource stay on the imagebuilder ARN scope" \
  bash -c 'grep -Fq "arn:aws:imagebuilder:*:\${AWS::AccountId}:" <<<"$1"' _ "$ib_lifecycle_stmt"
check "Image Builder lifecycle keeps its enumerated Create/Delete/Tag actions" \
  bash -c 'for a in CreateComponent DeleteComponent CreateImageRecipe DeleteImageRecipe CreateImagePipeline DeleteImagePipeline TagResource UntagResource; do grep -Fq "imagebuilder:$a" <<<"$1" || exit 1; done' _ "$ib_lifecycle_stmt"
check "Events lifecycle is scoped to the baked-AMI publish rule" \
  bash -c 'for a in PutRule PutTargets RemoveTargets DeleteRule DescribeRule ListTargetsByRule EnableRule DisableRule; do grep -Fq "events:$a" <<<"$1" || exit 1; done; grep -Fq "rule/\${ProjectName}-baked-ami-publish" <<<"$1"' _ "$events_stmt"
check "Events rule scope still matches the deterministic publish rule name" \
  bash -c 'grep -Fq "rule/\${ProjectName}-baked-ami-publish" <<<"$1"' _ "$events_stmt"
check "infra publish rule sets Properties.Name (Events Rule property is Name, not RuleName)" \
  test "$(property_value "$publish_rule_block" Name)" = '!Sub "${ProjectName}-baked-ami-publish"'
check "infra publish rule has no invalid RuleName property" \
  bash -c '! grep -Fxq "RuleName" <<<"$1"' _ "$(properties_keys "$publish_rule_block")"
check "SSM document lifecycle is granted (CreateDocument has no resource scope)" \
  bash -c 'for a in CreateDocument UpdateDocument DeleteDocument DescribeDocument GetDocument; do grep -Fq "ssm:$a" <<<"$1" || exit 1; done; grep -Fq "Resource: \"*\"" <<<"$1"' _ "$ssm_doc_stmt"
# CloudFormation's SSM document UpdateHandler calls UpdateDocumentDefaultVersion
# when the document content changes.
check "SSM document lifecycle grants UpdateDocumentDefaultVersion (CFN UpdateHandler)" \
  bash -c 'grep -Fq "ssm:UpdateDocumentDefaultVersion" <<<"$1"' _ "$ssm_doc_stmt"

# --- EC2 network lifecycle (the infra stack creates the VPC) ------------------
check "VPC lifecycle statement grants the full self-contained network action set" \
  bash -c 'for a in CreateVpc DeleteVpc ModifyVpcAttribute CreateSubnet DeleteSubnet ModifySubnetAttribute CreateInternetGateway DeleteInternetGateway AttachInternetGateway DetachInternetGateway CreateRouteTable DeleteRouteTable AssociateRouteTable DisassociateRouteTable CreateRoute DeleteRoute CreateSecurityGroup DeleteSecurityGroup AuthorizeSecurityGroupIngress RevokeSecurityGroupIngress CreateTags DeleteTags; do grep -Fq "ec2:$a" <<<"$1" || exit 1; done' _ "$vpc_stmt"
# The GPU security group declares explicit egress rules; the infra stack's
# route wiring updates associations and routes in place. All target resources
# are already in this statement's ARN scope (security-group/*, route-table/*).
check "VPC lifecycle grants SG egress + route/association update actions" \
  bash -c 'for a in AuthorizeSecurityGroupEgress RevokeSecurityGroupEgress ReplaceRouteTableAssociation ReplaceRoute UpdateSecurityGroupRuleDescriptionsIngress UpdateSecurityGroupRuleDescriptionsEgress; do grep -Fq "ec2:$a" <<<"$1" || exit 1; done' _ "$vpc_stmt"
check "VPC lifecycle scopes the network resource types with a region wildcard" \
  bash -c 'for r in "vpc/*" "subnet/*" "internet-gateway/*" "route-table/*" "security-group/*"; do grep -Fq "$r" <<<"$1" || exit 1; done; grep -Fq "arn:aws:ec2:*:\${AWS::AccountId}:" <<<"$1"' _ "$vpc_stmt"
check "VPC lifecycle CreateTags/DeleteTags stay UNCONDITIONED (CFN reserved keys)" \
  bash -c '! grep -Fq "aws:TagKeys" <<<"$1" && ! grep -Fq "ec2:CreateAction" <<<"$1"' _ "$vpc_stmt"
check "VPC lifecycle keeps its enumerated create/delete actions (no Describe wildcard)" \
  bash -c 'for a in CreateVpc DeleteVpc CreateSubnet DeleteSubnet CreateSecurityGroup DeleteSecurityGroup; do grep -Fq "ec2:$a" <<<"$1" || exit 1; done; ! grep -Fq "ec2:Describe*" <<<"$1"' _ "$vpc_stmt"

# --- least privilege: no unused admin grants ---------------------------------
for action in \
  iam:AttachUserPolicy iam:DetachUserPolicy iam:CreatePolicy \
  iam:CreatePolicyVersion iam:CreateUser iam:CreateRole iam:PutRolePolicy \
  iam:UpdateAssumeRolePolicy iam:AttachRolePolicy iam:DetachRolePolicy \
  iam:DeleteRole iam:DeletePolicy iam:DeleteUser iam:CreateInstanceProfile \
  iam:DeleteInstanceProfile iam:AddRoleToInstanceProfile; do
  check "operator policy does NOT grant admin $action" \
    bash -c '! grep -Fq -- "$2" <<<"$1"' _ "$operator_policy" "$action"
done
check "s3:PutObjectAcl is scoped to the deployment bucket objects statement" \
  bash -c 'grep -Fq "s3:PutObjectAcl" <<<"$1"' _ "$(extract_statement S3Objects)"
check "no account-wide s3:PutObjectAcl (Describe Ec2 statement is clean)" \
  bash -c '! grep -Fq "s3:PutObjectAcl" <<<"$1"' _ "$(extract_statement Ec2Describe)"

# --- M2: EC2 lifecycle statements are split and gated by tag/type ------------
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
check "RunInstances instance statement is scoped to instance/* (not Resource \"*\")" \
  bash -c 'grep -Fq "instance/*" <<<"$1" && ! grep -Fq "Resource: \"*\"" <<<"$1"' _ "$run_stmt"
check "RunInstances instance ARN uses a region wildcard" \
  bash -c 'grep -Fq "arn:aws:ec2:*:\${AWS::AccountId}:instance/*" <<<"$1"' _ "$run_stmt"
check "RunInstancesDependencies statement exists and grants ec2:RunInstances" \
  bash -c 'grep -Fq "ec2:RunInstances" <<<"$1"' _ "$run_deps_stmt"
check "RunInstancesDependencies covers volume/ENI/key-pair/SG/subnet" \
  bash -c 'for r in "volume/*" "network-interface/*" "key-pair/*" "security-group/*" "subnet/*"; do grep -Fq "$r" <<<"$1" || exit 1; done' _ "$run_deps_stmt"
check "RunInstancesDependencies covers the empty-account public image ARN (region wildcard)" \
  bash -c 'grep -Fq "arn:aws:ec2:*::image/*" <<<"$1"' _ "$run_deps_stmt"
# The baked AMI is private to this account, so its ARN carries the account id.
# The public-AMI grant (empty account) cannot authorize it: both must be present.
check "RunInstancesDependencies covers the account-owned baked image ARN" \
  bash -c 'grep -Fq "arn:aws:ec2:*:\${AWS::AccountId}:image/*" <<<"$1"' _ "$run_deps_stmt"
check "RunInstancesDependencies keeps BOTH public and account-owned image ARNs" \
  bash -c 'grep -Fq "arn:aws:ec2:*::image/*" <<<"$1" && grep -Fq "arn:aws:ec2:*:\${AWS::AccountId}:image/*" <<<"$1"' _ "$run_deps_stmt"
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
check "CreateTags also grants ec2:DeleteTags on instance ARNs" \
  bash -c 'grep -Fq "ec2:DeleteTags" <<<"$1" && grep -Fq "instance/*" <<<"$1"' _ "$tags_stmt"
check "CreateTags is bound to tag-on-create via ec2:CreateAction = RunInstances" \
  bash -c 'grep -Fq "ec2:CreateAction" <<<"$1" && grep -Fq "RunInstances" <<<"$1"' _ "$tags_stmt"
check "CreateTags is scoped to instance ARNs (not Resource \"*\")" \
  bash -c '! grep -Fq "Resource: \"*\"" <<<"$1"' _ "$tags_stmt"
check "CreateTags carries an aws:TagKeys allowlist (ForAllValues:StringEquals)" \
  bash -c 'grep -Fq "ForAllValues:StringEquals" <<<"$1" && grep -Fq "aws:TagKeys" <<<"$1"' _ "$tags_stmt"
check "CreateTags aws:TagKeys allowlist is exactly the launch keys (Project, Name)" \
  bash -c 'grep -Fq -- "- Project" <<<"$1" && grep -Fq -- "- Name" <<<"$1"' _ "$tags_stmt"

check "Describe statement exists" \
  bash -c 'grep -Fq "ec2:Describe*" <<<"$1"' _ "$describe_stmt"
# CloudFormation EC2 handlers issue assorted Describe* calls under the caller's
# identity (DescribeAvailabilityZones for subnets, etc.). Enumerating them has
# missed handler reads twice, so the operator read surface is the wildcard; ec2
# Describe actions have no resource-level support, hence Resource:"*".
check "Describe statement grants the ec2:Describe* wildcard" \
  bash -c 'grep -Fq "ec2:Describe*" <<<"$1"' _ "$describe_stmt"
check "Describe statement no longer enumerates individual ec2 Describe actions" \
  bash -c '! grep -Eq -- "- ec2:Describe[A-Za-z]+$" <<<"$1"' _ "$describe_stmt"
check "Describe statement stays Resource \"*\" and unconditioned" \
  bash -c 'grep -Fq "Resource: \"*\"" <<<"$1" && ! grep -Fq "aws:RequestTag" <<<"$1" && ! grep -Fq "aws:ResourceTag" <<<"$1"' _ "$describe_stmt"

# The build-instance role's EC2 list (the identity the permissions boundary is
# derived from) stays enumerated: it is a separate, least-privilege surface from
# the operator user's handler-driven reads.
check "build-instance/permissions-boundary EC2 describe list stays enumerated" \
  bash -c 'for a in DescribeInstances DescribeImages DescribeInstanceStatus DescribeInstanceTypes DescribeSubnets DescribeSecurityGroups DescribeVpcs; do grep -Fq -- "- ec2:$a" "$1" || exit 1; done' _ "$operator_template"

check "the old unscoped Ec2LaunchTerminate statement is gone" \
  bash -c '! grep -Fq "Ec2LaunchTerminate" "$1"' _ "$operator_template"
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
check "SelfKeyRotation scoped to user/\${ProjectName}" \
  bash -c 'grep -Fq "user/\${ProjectName}" <<<"$1"' _ "$(extract_statement SelfKeyRotation)"

# --- C2: iam:PassRole constrained to EC2 -------------------------------------
pass_role="$(extract_statement PassStrimserverRole)"
check "iam:PassRole scoped to the ProjectName instance role" \
  bash -c 'grep -Fq "role/\${ProjectName}-instance-role" <<<"$1"' _ "$pass_role"
check "iam:PassRole carries the ec2.amazonaws.com condition" \
  bash -c 'grep -Fq "iam:PassedToService" <<<"$1" && grep -Fq "ec2.amazonaws.com" <<<"$1"' _ "$pass_role"

check "CloudFormation scoped to stack/\${ProjectName}/*" \
  bash -c 'grep -Fq "stack/\${ProjectName}/*" <<<"$1"' _ "$operator_policy"
check "no route53 anywhere in the operator template" \
  bash -c '! grep -qi "route53" "$1"' _ "$operator_template"

# --- ProjectName parameterization + region wildcards -------------------------
arn_lines="$(grep -E 'arn:' <<<"$operator_policy" || true)"
check "no operator-policy ARN hardcodes the project literal 'strimserver'" \
  bash -c '! grep -qi "strimserver" <<<"$1"' _ "$arn_lines"
check "the operator policy carries no \${AWS::Region} region pin" \
  bash -c '! grep -Fq "\${AWS::Region}" <<<"$1"' _ "$operator_policy"
check "the operator template carries no \${AWS::Region} region pin" \
  bash -c '! grep -Fq "\${AWS::Region}" "$1"' _ "$operator_template"

# --- CI identity must NOT exist (explicit user decision) --------------------
check "no CI user is created" \
  bash -c '! grep -Eq "CiUser|ArtifactReader" "$1"' _ "$operator_template"
check "no artifact-reader policy is created" \
  bash -c '! grep -Fq -- "artifact-reader" "$1"' _ "$operator_template"

# --- baked-AMI read grant on the instance role -------------------------------
check "instance role can read the baked-AMI SSM parameter" \
  bash -c 'grep -Fq "parameter/\${ProjectName}/ami/baked/latest" <<<"$1"' _ "$instance_role"
check "instance role baked-AMI read is scoped (no parameter/* wildcard)" \
  bash -c '! grep -Fq "parameter/*" <<<"$1"' _ "$instance_role"

# --- permissions boundary ----------------------------------------------------
check "boundary policy exists (AWS::IAM::ManagedPolicy)" \
  bash -c 'grep -Fq "Type: AWS::IAM::ManagedPolicy" <<<"$1"' _ "$boundary_policy"
check "boundary policy name derives from ProjectName" \
  bash -c 'grep -Fq "ManagedPolicyName: !Sub \"\${ProjectName}-boundary\"" <<<"$1"' _ "$boundary_policy"
check "boundary grants the SSM agent action set (no wildcard ssm)" \
  bash -c 'grep -Fq "ssmmessages:OpenDataChannel" <<<"$1" && grep -Fq "ec2messages:GetMessages" <<<"$1" && ! grep -Fq "ssm:\*" <<<"$1"' _ "$boundary_policy"
check "boundary scopes parameter reads to the project namespace" \
  bash -c 'grep -Fq "parameter/\${ProjectName}/*" <<<"$1"' _ "$boundary_policy"
check "boundary is never attached to the operator user (no Users:)" \
  bash -c '! grep -Fq "Users:" <<<"$1"' _ "$boundary_policy"
check "InstanceRole carries the boundary" \
  bash -c 'grep -Fq "PermissionsBoundary: !Sub \"arn:\${AWS::Partition}:iam::\${AWS::AccountId}:policy/\${ProjectName}-boundary\"" <<<"$1"' _ "$instance_role"
check "InstanceRole depends on the boundary resource" \
  bash -c 'grep -Fq "DependsOn: StrimserverOperatorBoundary" <<<"$1"' _ "$instance_role"

# --- baked-AMI Image Builder execution role (least privilege) ----------------
execution_role="$(extract_resource "$operator_template" BakedImageBuilderExecutionRole)"
check "baked-AMI pipeline execution role exists (AWS::IAM::Role)" \
  bash -c 'grep -Fq "Type: AWS::IAM::Role" <<<"$1"' _ "$execution_role"
check "pipeline execution role is assumable by imagebuilder.amazonaws.com" \
  bash -c 'grep -Fq "imagebuilder.amazonaws.com" <<<"$1"' _ "$execution_role"
check "pipeline execution role grants imagebuilder actions" \
  bash -c 'grep -Fq "imagebuilder:" <<<"$1"' _ "$execution_role"
check "pipeline execution role grants ssm:PutParameter on the baked AMI parameter" \
  bash -c 'grep -Fq "ssm:PutParameter" <<<"$1" && grep -Fq "parameter/\${ProjectName}/ami/baked/latest" <<<"$1"' _ "$execution_role"
check "pipeline execution role grants ec2:CreateTags (AMI tagging)" \
  bash -c 'grep -Fq "ec2:CreateTags" <<<"$1"' _ "$execution_role"
check "pipeline execution role passes only the Image Builder instance role" \
  bash -c 'grep -Fq "iam:PassRole" <<<"$1" && grep -Fq "ec2.amazonaws.com" <<<"$1"' _ "$execution_role"
# The bake workflow (SSM SendCommand, EC2 CreateImage/RegisterImage/DeregisterImage,
# snapshots, workflow reads) relies on AWS's documented execution policy; the
# inline statements remain for the project-scoped extras.
check "pipeline execution role attaches the EC2ImageBuilderExecutionPolicy managed policy" \
  bash -c 'grep -Fq "arn:aws:iam::aws:policy/EC2ImageBuilderExecutionPolicy" <<<"$1"' _ "$execution_role"
check "pipeline execution role keeps its inline policy alongside the managed policy" \
  bash -c 'grep -Fq "Policies:" <<<"$1" && grep -Fq "ssm:PutParameter" <<<"$1"' _ "$execution_role"

# --- infra template: ExecutionRole wiring + AvailabilityZone -----------------
pipeline_block="$(extract_resource "$infra_template" BakedImagePipeline)"
check "ImagePipeline wires the Image Builder execution role" \
  bash -c 'grep -Fq "ExecutionRole:" <<<"$1" && grep -Fq -- "-baked-imagebuilder-execution-role" <<<"$1"' _ "$pipeline_block"
check "infra declares the AvailabilityZone parameter" \
  bash -c 'grep -Eq "^  AvailabilityZone:" "$1"' _ "$infra_template"
check "infra declares the HasAvailabilityZone condition" \
  bash -c 'grep -Fq "HasAvailabilityZone:" "$1"' _ "$infra_template"
check "subnet AZ honours the parameter with an AZ fallback" \
  bash -c 'grep -Fq "HasAvailabilityZone" <<<"$1" && grep -Fq "!GetAZs" <<<"$1"' _ "$(extract_resource "$infra_template" ManagedSubnet)"
# No default VPC exists in the account; the bake must launch into the stack's
# public subnet (MapPublicIpOnLaunch=true) with the stack SG (open egress).
infra_config="$(extract_resource "$infra_template" BakedInfrastructureConfiguration)"
check "build instance launches into the stack-managed subnet" \
  bash -c 'grep -Fq "SubnetId: !Ref ManagedSubnet" <<<"$1"' _ "$infra_config"
check "build instance attaches the stack instance security group" \
  bash -c 'grep -Fq "SecurityGroupIds: [!Ref InstanceSecurityGroup]" <<<"$1"' _ "$infra_config"

# --- no hardcoded AMI ids beyond the recipe base + launch fallback -----------
pinned_ami="ami-0198b63ccfac121e8"
check "infra template hardcodes only the pinned recipe-base AMI id" \
  bash -c 'ids="$(grep -o "ami-[0-9a-f]\{8,\}" "$1" | sort -u)"; [ "$ids" = "$2" ]' _ "$infra_template" "$pinned_ami"
check "operator template hardcodes no AMI id" \
  bash -c '! grep -q "ami-[0-9a-f]\{8,\}" "$1"' _ "$operator_template"
check "launch keeps only the pinned fallback AMI constant" \
  bash -c 'ids="$(grep -o "ami-[0-9a-f]\{8,\}" "$1" | sort -u)"; [ "$ids" = "$2" ]' _ "$script_dir/launch" "$pinned_ami"

# --- IAM managed-policy size quota (6144 chars) ------------------------------
# AWS rejects a managed policy whose JSON document exceeds 6144 characters.
# Keep every managed policy in this template comfortably under that ceiling;
# 6000 leaves headroom for IAM's own serialization quirks.
while read -r policy_name; do
  [[ -n "$policy_name" ]] || continue
  policy_block="$(extract_resource "$operator_template" "$policy_name")"
  policy_size="$(policy_document_size "$policy_block")"
  check "managed policy $policy_name PolicyDocument is under 6000 chars (measured ${policy_size})" \
    bash -c '[ "$1" -lt 6000 ] || { echo "  $2 PolicyDocument size=$1 >= 6000" >&2; exit 1; }' _ "$policy_size" "$policy_name"
done < <(managed_policy_names)

# --- mutation check: CreateTags without aws:TagKeys must FAIL ------------------
# Guard against the allowlist assertion silently rotting: strip the
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
  ' "$operator_template" > "$mutation_dir/strimserver-operator.yaml"
  if STRIMSERVER_OPERATOR_TEMPLATE="$mutation_dir/strimserver-operator.yaml" \
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
