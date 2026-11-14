#!/usr/bin/env bash
# testutil_fake_aws.sh -- sourceable fake `aws` for offline tests.
#
# fake_aws_install puts a stub `aws` first on PATH and points the recorder at a
# temp file; the stub answers the handful of calls deploy/aws tooling makes and
# records every invocation (one per line) to $FAKE_AWS_CALLS.
#
# Response knobs (read at call time, so tests may change them mid-run):
#   FAKE_AWS_STRIM_ARN    ARN for `--profile strimserver` sts calls
#                         (default arn:aws:iam::183438553939:user/strimserver)
#   FAKE_AWS_DEFAULT_ARN  ARN for sts calls with no/other profile
#                         (default arn:aws:iam::183438553939:user/admin)
#   FAKE_AWS_STS_FAIL     when 1, every sts call fails (rc 255)
#   FAKE_AWS_STS_INVALID_TOKEN_FAILS  when set to N, the first N PROFILE sts
#                         calls fail with InvalidClientTokenId (IAM eventual
#                         consistency); the counter is persisted in FAKE_AWS_STATE
#   FAKE_AWS_EXISTING_KEYS  tab/space-separated key ids for iam list-access-keys
#                         (only used when FAKE_AWS_STATE is unset)
#   FAKE_AWS_ACCESS_KEY_ID / FAKE_AWS_SECRET_ACCESS_KEY  create-access-key output
#                         (only used when FAKE_AWS_STATE is unset)
#   FAKE_AWS_SSM_BAKED_AMI  value for `ssm get-parameter` (the baked-AMI param);
#                         unset/empty simulates ParameterNotFound (rc 254)
#   FAKE_AWS_INSTANCE_ID  instance id printed by `ec2 run-instances`
#                         (default i-0123456789abcdef0)
#   FAKE_AWS_DEPLOY_FAIL  when 1, cloudformation deploy fails
#   FAKE_AWS_NO_PIPELINE  when 1, imagebuilder list-image-pipelines is empty
#   FAKE_AWS_DESCRIBE_FLOOR  overrides the NvidiaDriverFloor value returned by
#                         cloudformation describe-stacks (drift simulation)
#   FAKE_AWS_TEMPLATE_FLOOR  when set, cloudformation deploy records it as the
#                         NvidiaDriverFloor stack parameter if the deploy did not
#                         pass one (models the template Default that real CFN
#                         applies); used by deploy_infra_test
#   FAKE_AWS_STATE        optional directory that turns on the tiny stateful
#                         models: IAM access keys per user, CloudFormation stack
#                         parameters/status, and the eventual-consistency counter.
#                         Unset keeps the original stateless responses.
#
# Not intended to be executed directly.

fake_aws_install() {
  FAKE_AWS_BINDIR="$(mktemp -d)"
  FAKE_AWS_CALLS="$(mktemp)"
  export FAKE_AWS_BINDIR FAKE_AWS_CALLS

  cat >"$FAKE_AWS_BINDIR/aws" <<'FAKE_AWS_EOF'
#!/usr/bin/env bash
# Stub aws: record argv, then answer the calls the strimserver tooling makes.
printf '%s\n' "$*" >>"${FAKE_AWS_CALLS:-/dev/null}"
args="$*"

profile=""
query=""
output=""
prev=""
for word in "$@"; do
  case "$prev" in
    --profile) profile="$word"; prev=""; continue ;;
    --query)   query="$word";   prev=""; continue ;;
    --output)  output="$word";  prev=""; continue ;;
  esac
  case "$word" in
    --profile=*) profile="${word#*=}" ;;
    --query=*)   query="${word#*=}" ;;
    --output=*)  output="${word#*=}" ;;
  esac
  prev="$word"
done
# The real aws CLI falls back to the ambient AWS_PROFILE/AWS_DEFAULT_PROFILE when
# no --profile is passed. Model that so an env -u / leaked profile is observable.
effective_profile="${profile:-${AWS_PROFILE:-${AWS_DEFAULT_PROFILE:-}}}"

state="${FAKE_AWS_STATE:-}"
state_file() { printf '%s/%s' "$state" "$1"; }

args_has() { [[ "$args" == *"$1"* ]]; }
arg_value() { # arg_value <flag> -> the following word, or empty
  local -a words=($args)
  local i
  for ((i = 0; i < ${#words[@]}; i++)); do
    if [[ "${words[i]}" == "$1" ]]; then printf '%s' "${words[i + 1]:-}"; return; fi
  done
}

if args_has "sts get-caller-identity"; then
  [[ "${FAKE_AWS_STS_FAIL:-}" == "1" ]] && exit 255
  [[ -z "$effective_profile" && "${FAKE_AWS_ADMIN_FAIL:-}" == "1" ]] && exit 255
  # A freshly minted key can be rejected by STS as not-yet-valid. Only profiled
  # calls model that (the admin gate runs without a profile).
  if [[ -n "$effective_profile" && -n "${FAKE_AWS_STS_INVALID_TOKEN_FAILS:-}" ]]; then
    mkdir -p "$state"
    remaining_file="$state/sts-invalid-remaining"
    remaining="$(cat "$remaining_file" 2>/dev/null || printf '%s' "$FAKE_AWS_STS_INVALID_TOKEN_FAILS")"
    if (( remaining > 0 )); then
      printf '%s' "$((remaining - 1))" >"$remaining_file"
      printf 'An error occurred (InvalidClientTokenId) when calling the GetCallerIdentity operation: The security token included in the request is invalid.\n' >&2
      exit 255
    fi
  fi
  # Any explicit profile resolves to the operator ARN; only the ambient
  # (no-profile) call is the admin. This matches how the real CLI selects an
  # identity from --profile (whatever that profile's key happens to be).
  case "$effective_profile" in
    ""|admin) arn="${FAKE_AWS_DEFAULT_ARN:-arn:aws:iam::183438553939:user/admin}" ;;
    *)        arn="${FAKE_AWS_STRIM_ARN:-arn:aws:iam::183438553939:user/strimserver}" ;;
  esac
  if [[ "$query" == *"Account"* ]]; then
    printf '183438553939\n'
  elif [[ "$query" == *"Arn"* ]]; then
    printf '%s\n' "$arn"
  else
    printf '{"UserId":"AIDAFake","Account":"183438553939","Arn":"%s"}\n' "$arn"
  fi
  exit 0
fi

if args_has "iam list-access-keys"; then
  user="$(arg_value --user-name)"
  if [[ -n "$state" ]]; then
    keys_file="$state/keys-${user:-unknown}"
    mkdir -p "$state"
    [[ -f "$keys_file" ]] || : >"$keys_file"
    if [[ "$output" == "text" || "$query" == *"AccessKeyId"* ]]; then
      paste -sd '\t' "$keys_file" 2>/dev/null || true
      printf '\n'
    else
      printf '%s' "${FAKE_AWS_EXISTING_KEYS:-}"
    fi
    exit 0
  fi
  printf '%s' "${FAKE_AWS_EXISTING_KEYS:-}"
  exit 0
fi

if args_has "iam create-access-key"; then
  user="$(arg_value --user-name)"
  if [[ -n "$state" ]]; then
    keys_file="$state/keys-${user:-unknown}"
    mkdir -p "$state"
    [[ -f "$keys_file" ]] || : >"$keys_file"
    existing_count="$(grep -c . "$keys_file" 2>/dev/null || true)"
    if (( existing_count >= 2 )); then
      printf 'An error occurred (LimitExceeded) when calling the CreateAccessKey operation: Cannot exceed quota for AccessKeysPerUser: 2\n' >&2
      exit 254
    fi
    n="$(cat "$state/counter" 2>/dev/null || printf '0')"
    n=$((n + 1))
    printf '%s' "$n" >"$state/counter"
    kid="$(printf 'AKIAFAKE%07d' "$n")"
    secret="$(printf 'fakesecret%07d' "$n")"
    printf '%s\n' "$kid" >>"$keys_file"
    printf '%s\t%s\n' "$kid" "$secret"
    exit 0
  fi
  printf '%s\t%s\n' \
    "${FAKE_AWS_ACCESS_KEY_ID:-AKIAFAKEFAKEFAKEFAKE}" \
    "${FAKE_AWS_SECRET_ACCESS_KEY:-wJalrFAKEsecretFAKEsecretFAKEsecretFAKEkey}"
  exit 0
fi

if args_has "iam delete-access-key"; then
  user="$(arg_value --user-name)"
  kid="$(arg_value --access-key-id)"
  if [[ -n "$state" ]]; then
    keys_file="$state/keys-${user:-unknown}"
    mkdir -p "$state"
    [[ -f "$keys_file" ]] || : >"$keys_file"
    grep -v -x -F "$kid" "$keys_file" >"$keys_file.tmp" 2>/dev/null || true
    mv "$keys_file.tmp" "$keys_file"
  fi
  exit 0
fi

if args_has "iam get-user"; then
  [[ "${FAKE_AWS_USER_MISSING:-}" == "1" ]] && exit 254
  printf '{"User":{"UserName":"%s"}}\n' "$(arg_value --user-name)"
  exit 0
fi

if args_has "cloudformation deploy"; then
  [[ "${FAKE_AWS_DEPLOY_FAIL:-}" == "1" ]] && { printf 'fake: deploy failed\n' >&2; exit 255; }
  if [[ -n "$state" ]]; then
    mkdir -p "$state"
    params_file="$state/stack-params"
    status_file="$state/stack-status"
    if [[ -f "$params_file" ]]; then
      printf 'UPDATE_COMPLETE' >"$status_file"
    else
      printf 'CREATE_COMPLETE' >"$status_file"
    fi
    [ -n "${FAKE_AWS_DEPLOY_FAIL:-}" ] || : >"$params_file"
    collecting=0
    for word in "$@"; do
      if [[ "$collecting" == "1" ]]; then
        case "$word" in
          Key=*) break ;;
          *=*) printf '%s\n' "$word" | sed 's/^"//; s/"$//' >>"$params_file" ;;
        esac
      fi
      [[ "$word" == "--parameter-overrides" ]] && collecting=1
    done
    # Model the template Default: real CloudFormation resolves NvidiaDriverFloor
    # even when the deploy line omits it, so post-deploy verification sees it.
    if ! grep -q '^NvidiaDriverFloor=' "$params_file" 2>/dev/null \
        && [[ -n "${FAKE_AWS_TEMPLATE_FLOOR:-}" ]]; then
      printf 'NvidiaDriverFloor=%s\n' "$FAKE_AWS_TEMPLATE_FLOOR" >>"$params_file"
    fi
  fi
  printf 'fake: deploy ok\n'
  exit 0
fi

if args_has "cloudformation describe-stacks"; then
  if [[ -n "$state" && ! -f "$state/stack-params" ]]; then
    printf 'An error occurred (ValidationError) when calling the DescribeStacks operation: Stack with id strimserver does not exist\n' >&2
    exit 254
  fi
  if [[ -n "$state" ]]; then
    status="$(cat "$state/stack-status" 2>/dev/null || printf 'CREATE_COMPLETE')"
    if [[ "$query" == *"StackStatus"* ]]; then
      printf '%s\n' "$status"
      exit 0
    fi
    if [[ "$query" == *"Parameters"* ]]; then
      if [[ "$output" == "text" ]]; then
        while IFS= read -r line; do
          key="${line%%=*}"
          value="${line#*=}"
          [[ "$key" == "NvidiaDriverFloor" && -n "${FAKE_AWS_DESCRIBE_FLOOR:-}" ]] && value="$FAKE_AWS_DESCRIBE_FLOOR"
          printf '%s\t%s\n' "$key" "$value"
        done <"$state/stack-params"
      else
        printf '"Parameters": ['
        sep=""
        while IFS= read -r line; do
          key="${line%%=*}"
          value="${line#*=}"
          [[ "$key" == "NvidiaDriverFloor" && -n "${FAKE_AWS_DESCRIBE_FLOOR:-}" ]] && value="$FAKE_AWS_DESCRIBE_FLOOR"
          printf '%s{"ParameterKey":"%s","ParameterValue":"%s"}' "$sep" "$key" "$value"
          sep=","
        done <"$state/stack-params"
        printf ']\n'
      fi
      exit 0
    fi
    printf '{"Stacks":[{"StackStatus":"%s","Parameters":[]}]}\n' "$status"
    exit 0
  fi
  printf '{"Stacks":[{"StackStatus":"%s","Parameters":[]}]}\n' "${FAKE_AWS_STACK_STATUS:-CREATE_COMPLETE}"
  exit 0
fi

if args_has "imagebuilder list-image-pipelines"; then
  if [[ "${FAKE_AWS_NO_PIPELINE:-}" == "1" ]]; then
    exit 0
  fi
  printf 'strimserver-baked\n'
  exit 0
fi

if args_has "ssm get-parameter"; then
  if [[ -z "${FAKE_AWS_SSM_BAKED_AMI:-}" ]]; then
    printf 'An error occurred (ParameterNotFound) when calling the GetParameter operation\n' >&2
    exit 254
  fi
  printf '%s\n' "$FAKE_AWS_SSM_BAKED_AMI"
  exit 0
fi

if args_has "ec2 run-instances"; then
  printf '%s\n' "${FAKE_AWS_INSTANCE_ID:-i-0123456789abcdef0}"
  exit 0
fi

exit "${FAKE_AWS_RC:-0}"
FAKE_AWS_EOF

  chmod +x "$FAKE_AWS_BINDIR/aws"
  PATH="$FAKE_AWS_BINDIR:$PATH"
  export PATH
}

# Print the recorded calls (one per line).
fake_aws_calls() {
  cat "${FAKE_AWS_CALLS:?fake_aws_install must run first}"
}

# Remove the fake bin + recorder.
fake_aws_cleanup() {
  [[ -n "${FAKE_AWS_BINDIR:-}" ]] && rm -rf "$FAKE_AWS_BINDIR"
  [[ -n "${FAKE_AWS_CALLS:-}" ]] && rm -f "$FAKE_AWS_CALLS"
}
