# Thin facade over the Bazel build (see MODULE.bazel/BUILD.bazel). Kept for
# muscle memory; `bazel` is the real build system now -- run its targets
# directly for anything not covered here.
# Note: on non-x86_64 hosts, `make test-controller` requires qemu-user
# binfmt (`qemu-user` + `qemu-user-binfmt`) to be installed/registered.

S3_BUCKET ?=s3://<bucket-name>

.DEFAULT_GOAL := package

# Build provenance stamped into the controller binaries: the full commit SHA
# (GIT_TAG, the release tag, is resolved next to `release` below). Both reach
# the Bazel actions via --action_env.
GIT_COMMIT ?= $(shell git rev-parse HEAD)

.PHONY: prepare generate check-generated controller test-controller package package-arm64 package-all release \
	bump-version require-build-info check-no-twitch-key check-deps check-deps-json \
	check-ffmpeg-dist-deps check-openssh-dist-deps \
	publish-all publish-strimserver publish-iperf3 publish-streamdeck publish-ffmpeg-dist publish-openssh-dist

# Bootstrap: copy the example env into place for the first local checkout
# (never overwrite an existing, possibly customized, core/strimserver.env).
prepare:
	if [ ! -f core/strimserver.env ]; then cp core/strimserver.env.example core/strimserver.env; fi

generate:
	bazel run //core/controller:generate

check-generated:
	bazel test //core/controller:generate_test

controller:
	bazel build --action_env=GIT_TAG=$(GIT_TAG) --action_env=GIT_COMMIT=$(GIT_COMMIT) //core/controller:strimserver-controller

test-controller:
	bazel test --action_env=GIT_TAG=$(GIT_TAG) --action_env=GIT_COMMIT=$(GIT_COMMIT) //core/controller:all

check-no-twitch-key:
	bazel build //:check_no_twitch_key

# Phase 1 stub: list every pinned dependency in the repo (Bazel modules,
# toolchain versions, downloaded artifacts, CI actions, and script pins).
check-deps:
	bazel run //tools/check-deps:check-deps -- --ignore

# LLM/automation-readable form: JSON report to stdout (the console report and
# bazel INFO logs both go to stderr, so stdout stays pure JSON).
check-deps-json:
	@bazel run //tools/check-deps:check-deps -- --json --ignore

package:
	bazel build --action_env=GIT_TAG=$(GIT_TAG) --action_env=GIT_COMMIT=$(GIT_COMMIT) //:package

# The arm64 bundle alone (the same tar graph rebuilt under
# //tools/bazel:linux_arm64 via a platform transition).
package-arm64:
	bazel build --action_env=GIT_TAG=$(GIT_TAG) --action_env=GIT_COMMIT=$(GIT_COMMIT) //:package_arm64

# ALL FOUR deployment bundles (+ checksums): Go + C controllers, amd64 +
# arm64. Equivalent to `bazel build //:package_all` (a single analysis pass
# produces all four).
package-all:
	bazel build --action_env=GIT_TAG=$(GIT_TAG) --action_env=GIT_COMMIT=$(GIT_COMMIT) //:package_all

# Attach the bundles + checksums to an existing tag's GitHub Release.
# Requires the GitHub CLI (`gh auth login`).
# NOTE: the release/publish targets wrap the Bazel targets, which now produce
# ALL FOUR bundles (strimserver-deployment-{go,c}-{amd64,arm64}.tar, each with
# its .sha256) in one invocation -- no Makefile logic change was needed.
# Release/publish builds must be stamped with real provenance: a vX.Y.Z tag
# (GIT_TAG) and a commit SHA (GIT_COMMIT). Shared prerequisite for release and
# every publish-* target.
require-build-info:
	@if [ -z "$(GIT_TAG)" ]; then \
	  echo "ERROR: GIT_TAG is empty; release/publish requires a vX.Y.Z tag." >&2; \
	  echo "Run from the tagged commit (git describe --tags --exact-match)." >&2; \
	  exit 1; \
	fi
	@if [ -z "$(GIT_COMMIT)" ]; then \
	  echo "ERROR: GIT_COMMIT is empty; release/publish requires a commit SHA." >&2; \
	  exit 1; \
	fi

GIT_TAG ?= $(shell git describe --tags --exact-match 2>/dev/null)
release: require-build-info
	GIT_TAG=$(GIT_TAG) GIT_COMMIT=$(GIT_COMMIT) bazel run --action_env=GIT_TAG --action_env=GIT_COMMIT //:release

# Bump the latest vX.Y.Z git tag and push it (tag-based versioning; git tags
# are the source of truth). Guards: clean tree, on `dev`, synced with
# origin/dev, and the tag must be on the origin/dev or origin/release/* line.
bump-version:
	@if [ -z "$(LEVEL)" ]; then \
	  echo "usage: make bump-version LEVEL=major|minor|patch" >&2; exit 1; \
	fi
	bazel run //:bump_version -- "$(LEVEL)"

# Publish everything to S3 in one bazel run: ALL FOUR strimserver deployment
# tars (Go + C, amd64 + arm64, each with its .sha256), the Stream Deck plugin
# bundle (.zip + .tar.gz), and the iperf3 bundle. Requires AWS credentials and
# S3_BUCKET. Runs a single bazel target rather than the individual publish-*
# targets (one server/analysis pass).
publish-all: require-build-info
	GIT_TAG=$(GIT_TAG) GIT_COMMIT=$(GIT_COMMIT) S3_BUCKET=$(S3_BUCKET) bazel run --action_env=GIT_TAG --action_env=GIT_COMMIT //:publish_all

publish-strimserver: require-build-info
# The offline fallback clip is bundled directly from MODULE.bazel's
# s3_http_file(offline_segment_dist); regenerate + republish a new clip via
# tools/brb-screen/publish.sh.
# Also uploads ALL FOUR deployment tars (strimserver-deployment-{go,c}-{amd64,arm64}.tar
# + .sha256) and the Stream Deck plugin bundle (strimserver-streamdeck-plugin.zip
# and .tar.gz).
	GIT_TAG=$(GIT_TAG) GIT_COMMIT=$(GIT_COMMIT) S3_BUCKET=$(S3_BUCKET) bazel run --action_env=GIT_TAG --action_env=GIT_COMMIT //:publish_strimserver

publish-iperf3:
	S3_BUCKET=$(S3_BUCKET) bazel run //tools/bandwidth-test:publish_iperf3

# Publish ONLY the Stream Deck plugin bundle to S3 (same object keys as
# publish-strimserver). Publishes both the .zip and .tar.gz variants.
publish-streamdeck: require-build-info
	GIT_TAG=$(GIT_TAG) GIT_COMMIT=$(GIT_COMMIT) S3_BUCKET=$(S3_BUCKET) bazel run --action_env=GIT_TAG --action_env=GIT_COMMIT //tools/streamdeck-plugin:publish_streamdeck

check-ffmpeg-dist-deps:
	./tools/ffmpeg-dist/check-deps.sh

check-openssh-dist-deps:
	./tools/openssh/check-deps.sh

# Builds + uploads the pinned FFmpeg artifact (chroot+qemu), printing the MODULE.bazel s3_http_archive stanza.
publish-ffmpeg-dist: check-ffmpeg-dist-deps
	S3_BUCKET=$(S3_BUCKET) ./tools/ffmpeg-dist/publish.sh

# Builds + uploads the pinned OpenSSH RPM (chroot+qemu), printing the MODULE.bazel s3_http_file stanza.
publish-openssh-dist: check-openssh-dist-deps
	S3_BUCKET=$(S3_BUCKET) ./tools/openssh/publish.sh
