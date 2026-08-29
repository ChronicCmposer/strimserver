# Thin facade over the Bazel build (see plans/buildkit-to-bazel-migration.md
# and MODULE.bazel/BUILD.bazel). Kept for muscle memory; `bazel` is the real
# build system now -- run its targets directly for anything not covered here.

S3_BUCKET ?=s3://<bucket-name>

-include feature-toggles.env

ENABLE_EXPERIMENTAL_OPENSSH	?=false
BAZEL_OPENSSH_FLAG := --//:enable_experimental_openssh=$(subst ",,$(ENABLE_EXPERIMENTAL_OPENSSH))

.DEFAULT_GOAL := package

.PHONY: generate check-generated controller test-controller package release \
	check-no-twitch-key publish-strimserver publish-iperf3

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
	bazel build $(BAZEL_OPENSSH_FLAG) //:package

# Attach the bundle + checksum to an existing tag's GitHub Release.
# Requires the GitHub CLI (`gh auth login`).
GIT_TAG ?= $(shell git describe --tags --exact-match 2>/dev/null)
release:
	GIT_TAG=$(GIT_TAG) bazel run $(BAZEL_OPENSSH_FLAG) //:release

publish-strimserver:
	S3_BUCKET=$(S3_BUCKET) bazel run $(BAZEL_OPENSSH_FLAG) //:publish_strimserver

publish-iperf3:
	S3_BUCKET=$(S3_BUCKET) bazel run //tools/bandwidth-test:publish_iperf3
