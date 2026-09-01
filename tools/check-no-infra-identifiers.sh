#!/usr/bin/env bash
# Guard: fail any commit/CI run that contains AWS-infra identifiers.
#
# The real identifier patterns are live infrastructure attributes (a domain,
# an AWS host IP prefix, an operator name, an S3 bucket), so they are
# intentionally NOT committed here -- a reader of the repo must not be able to
# fingerprint current infrastructure from it. Supply them at runtime via the
# STRIMSERVER_INFRA_IDENTIFIERS environment variable, as a pipe-separated
# extended regular expression. For a git hook, export the variable before the
# hook runs; in CI, pass a repository secret (see the
# no-infra-identifiers.yml workflow, secret INFRA_IDENTIFIERS). Example value
# (placeholders only -- never real identifiers):
#   STRIMSERVER_INFRA_IDENTIFIERS='example\.com|203\.0\.113\.|alice|s3://example-bucket'
#
# If STRIMSERVER_INFRA_IDENTIFIERS is unset/empty the guard REFUSES to run: a
# silently unconfigured guard would quietly skip infra-identifier detection, so
# it exits 1 with a clear error instead.
#
# The scan is limited to files git would actually commit: tracked files plus
# untracked non-ignored files (`git ls-files -c -o --exclude-standard`).
# Gitignored local files (.env, deploy/aws/__pycache__/, go/, tools/local-obs/,
# bazel-*, build artifacts like tools/ffmpeg-dist/out.log) hold real
# identifiers but can never be committed, so they must not block commits.
#
# Excluded path: the guard's own file (its pattern configuration must be able
# to mention example identifiers without tripping the scan it runs).
set -euo pipefail

# Refuse to run unconfigured: an unset STRIMSERVER_INFRA_IDENTIFIERS means the
# guard is not wired up and would silently detect nothing.
if [[ -z "${STRIMSERVER_INFRA_IDENTIFIERS:-}" ]]; then
  echo "error: STRIMSERVER_INFRA_IDENTIFIERS is unset; the infra-identifier guard would" >&2
  echo "       silently skip detection. Set it to the pipe-separated identifier regex." >&2
  echo "       For the git hook, export it before running the hook; in CI, pass it from" >&2
  echo "       the repository secret INFRA_IDENTIFIERS (see .github/workflows/no-infra-identifiers.yml)." >&2
  exit 1
fi

# Run from the repo root so the scan is location-independent.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

files="$(git ls-files -c -o --exclude-standard \
  ':(exclude)tools/check-no-infra-identifiers.sh')"
if [[ -z "$files" ]]; then
  echo "ok: no infra identifiers found"
  exit 0
fi

# -H forces the file:line prefix even when the file list is a single file
# (grep's default is to omit it for single-file searches).
hits="$(printf '%s\n' "$files" | xargs -r grep -nHE "$STRIMSERVER_INFRA_IDENTIFIERS" 2>/dev/null || true)"
if [[ -n "$hits" ]]; then
  printf '%s\n' "$hits"
  echo "error: infra identifiers found (see above)" >&2
  exit 1
fi

echo "ok: no infra identifiers found"
