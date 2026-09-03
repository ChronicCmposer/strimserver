# Thin facade over the Bazel build (see MODULE.bazel/BUILD.bazel). Kept for
# muscle memory; `bazel` is the real build system now -- run its targets
# directly for anything not covered here.
# Note: on non-x86_64 hosts, `make test-controller` requires qemu-user
# binfmt (`qemu-user` + `qemu-user-binfmt`) to be installed/registered.

S3_BUCKET ?=s3://<bucket-name>

.DEFAULT_GOAL := package

.PHONY: prepare generate check-generated controller test-controller package release \
	bump-version check-no-twitch-key check-deps check-deps-json \
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
	bazel build //core/controller:strimserver-controller

test-controller:
	bazel test //core/controller:all

check-no-twitch-key:
	bazel build //:check_no_twitch_key

# Phase 1 stub: list every pinned dependency in the repo (Bazel modules,
# toolchain versions, downloaded artifacts, CI actions, and script pins).
check-deps:
	bazel run //tools/check-deps:check-deps

# LLM/automation-readable form: JSON report to stdout (the console report and
# bazel INFO logs both go to stderr, so stdout stays pure JSON).
check-deps-json:
	bazel run //tools/check-deps:check-deps -- --json

package:
	bazel build //:package

# Attach the bundle + checksum to an existing tag's GitHub Release.
# Requires the GitHub CLI (`gh auth login`).
GIT_TAG ?= $(shell git describe --tags --exact-match 2>/dev/null)
release:
	GIT_TAG=$(GIT_TAG) bazel run //:release

# Bump the latest vX.Y.Z git tag and push it (tag-based versioning; git tags
# are the source of truth). Guards: clean tree, on `dev`, synced with
# origin/dev, and the tag must be on the origin/dev or origin/release/* line.
bump-version:
	@if [ -z "$(LEVEL)" ]; then \
	  echo "usage: make bump-version LEVEL=major|minor|patch" >&2; exit 1; \
	fi
	bazel run //:bump_version -- "$(LEVEL)"

# Publish everything to S3 in one bazel run: the strimserver deployment tar,
# the Stream Deck plugin bundle (.zip + .tar.gz), and the iperf3 bundle.
# Requires AWS credentials and S3_BUCKET. Runs a single bazel target rather
# than the individual publish-* targets (one server/analysis pass).
publish-all:
	S3_BUCKET=$(S3_BUCKET) bazel run //:publish_all

publish-strimserver:
# The offline fallback clip is bundled directly from MODULE.bazel's
# s3_http_file(offline_segment_dist); regenerate + republish a new clip via
# tools/brb-screen/publish.sh.
# Also uploads the Stream Deck plugin bundle (strimserver-streamdeck-plugin.zip
# and .tar.gz).
	S3_BUCKET=$(S3_BUCKET) bazel run //:publish_strimserver

publish-iperf3:
	S3_BUCKET=$(S3_BUCKET) bazel run //tools/bandwidth-test:publish_iperf3

# Publish ONLY the Stream Deck plugin bundle to S3 (same object keys as
# publish-strimserver). Publishes both the .zip and .tar.gz variants.
publish-streamdeck:
	S3_BUCKET=$(S3_BUCKET) bazel run //tools/streamdeck-plugin:publish_streamdeck

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
