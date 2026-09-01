#!/usr/bin/env bash
# Guard: fail any commit/CI run that contains AWS-infra identifiers.
#
# Identifiers that must never reach a committed tree:
#   - <bucket-name>   (the strimserver domain)
#   - 104.218.148           (the AWS host IP prefix)
#   - connor                (an operator name)
#   - s3://strimserver      (the AWS S3 bucket)
#
# The scan is limited to files git would actually commit: tracked files plus
# untracked non-ignored files (`git ls-files -c -o --exclude-standard`).
# Gitignored local files (.env, deploy/aws/__pycache__/, go/, tools/local-obs/,
# bazel-*, build artifacts like tools/ffmpeg-dist/out.log) hold real
# identifiers but can never be committed, so they must not block commits.
#
# Excluded paths: plans/ (holds an untracked working-plan doc that
# legitimately discusses the identifiers being scrubbed) and the guard's own
# file (its pattern definitions must contain the very strings it detects;
# otherwise it could never pass).
set -euo pipefail

# Run from the repo root so the scan is location-independent.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

identifier_pattern='strimserver\.cvbn\.cc|104\.218\.148|\bconnor\b|s3://strimserver'

files="$(git ls-files -c -o --exclude-standard \
  ':(exclude)plans' \
  ':(exclude)tools/check-no-infra-identifiers.sh')"
if [[ -z "$files" ]]; then
  echo "ok: no infra identifiers found"
  exit 0
fi

# -H forces the file:line prefix even when the file list is a single file
# (grep's default is to omit it for single-file searches).
hits="$(printf '%s\n' "$files" | xargs -r grep -nHE "$identifier_pattern" 2>/dev/null || true)"
if [[ -n "$hits" ]]; then
  printf '%s\n' "$hits"
  echo "error: infra identifiers found (see above)" >&2
  exit 1
fi

echo "ok: no infra identifiers found"