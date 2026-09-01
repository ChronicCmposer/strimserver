# Thin facade over the Bazel build (see MODULE.bazel/BUILD.bazel). Kept for
# muscle memory; `bazel` is the real build system now -- run its targets
# directly for anything not covered here.
# Note: on non-x86_64 hosts, `make test-controller` requires qemu-user
# binfmt (`qemu-user` + `qemu-user-binfmt`) to be installed/registered.

S3_BUCKET ?=s3://<bucket-name>

.DEFAULT_GOAL := package

.PHONY: prepare generate check-generated controller test-controller package release \
	check-no-twitch-key publish-strimserver publish-iperf3 publish-streamdeck

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

package:
	bazel build //:package

# Attach the bundle + checksum to an existing tag's GitHub Release.
# Requires the GitHub CLI (`gh auth login`).
GIT_TAG ?= $(shell git describe --tags --exact-match 2>/dev/null)
release:
	GIT_TAG=$(GIT_TAG) bazel run //:release

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