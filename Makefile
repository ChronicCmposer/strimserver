CORE_DIR 				:=core
CONTROLLER_DIR 		:=core/controller
AWS_DEPLOY_DIR 		:=deploy/aws
LOCAL_ENCODER_DIR 	:=tools/local-encoder
BANDWIDTH_TEST_DIR 	:=tools/bandwidth-test
SRT_TEST_DIR 			:=tools/srt-test
OPENSSH_DIR 			:=tools/openssh


S3_BUCKET	?=s3://<bucket-name>
OUTPUT_PATH	?=$(HOME)/local-dev/strimserver

CONTROLLER_IMAGE_NAME 	?=docker.io/library/strimserver-controller:latest
FFMPEG_IMAGE_NAME			?=docker.io/library/ffmpeg:latest
MEDIAMTX_IMAGE_NAME		?=docker.io/library/mediamtx:latest
LIBSRT_IMAGE_NAME			?=docker.io/library/libsrt:latest
IPERF3_IMAGE_NAME			?=docker.io/library/iperf3:latest

CONTROLLER_IMAGE_FILE_NAME	?=controller-container.tar
FFMPEG_IMAGE_FILE_NAME		?=ffmpeg-container.tar
MEDIAMTX_IMAGE_FILE_NAME	?=mediamtx-container.tar
LIBSRT_IMAGE_FILE_NAME		?=libsrt-container.tar
IPERF3_IMAGE_FILE_NAME		?=iperf3-container.tar
OFFLINE_SEGMENT_FILE_NAME	:=strimserver-offline-2160p60.mp4
OPENSSH_RPM_FILE_NAME		:=openssh-experimental.rpm

STRIMSERVER_DEPLOYMENT_FILE_NAME ?=strimserver-deployment.tar
IPERF3_DEPLOYMENT_FILE_NAME		?=iperf3-deployment.tar

CONTROLLER_CONTAINER_OUTPUT	?=$(OUTPUT_PATH)/$(CONTROLLER_IMAGE_FILE_NAME)
FFMPEG_CONTAINER_OUTPUT			?=$(OUTPUT_PATH)/$(FFMPEG_IMAGE_FILE_NAME)
MEDIAMTX_CONTAINER_OUTPUT		?=$(OUTPUT_PATH)/$(MEDIAMTX_IMAGE_FILE_NAME)
OFFLINE_SEGMENT_OUTPUT			:=$(OUTPUT_PATH)/$(OFFLINE_SEGMENT_FILE_NAME)
OPENSSH_RPM_OUTPUT				:=$(OUTPUT_PATH)/$(OPENSSH_RPM_FILE_NAME)
LIBSRT_CONTAINER_OUTPUT			:=$(OUTPUT_PATH)/$(LIBSRT_IMAGE_FILE_NAME)
IPERF3_CONTAINER_OUTPUT			:=$(OUTPUT_PATH)/$(IPERF3_IMAGE_FILE_NAME)
STRIMSERVER_DEPLOYMENT_TAR		:=$(OUTPUT_PATH)/$(STRIMSERVER_DEPLOYMENT_FILE_NAME)
IPERF3_DEPLOYMENT_TAR			:=$(OUTPUT_PATH)/$(IPERF3_DEPLOYMENT_FILE_NAME)


-include feature-toggles.env

ENABLE_EXPERIMENTAL_OPENSSH	?=false
ENABLE_LINT							?=true

.DEFAULT_GOAL := publish-strimserver

.PHONY := controller test-controller goroot

goroot:
	@test -n "$(PROJECT_GO_VERSION_TAG)" || { echo "PROJECT_GO_VERSION_TAG required"; exit 1; }
	@test -n "$(PROJECT_GO_ROOT)"		|| { echo "PROJECT_GO_ROOT required"; exit 1; }
	@test -n "$(GOROOT_BOOTSTRAP)"	|| { echo "GOROOT_BOOTSTRAP required"; exit 1; }
	set -x && rm -rf go && mkdir go
	set -x && cd go && git init \
		&& git remote add origin https://github.com/golang/go.git \
		&& git fetch --depth 1 origin refs/tags/$(PROJECT_GO_VERSION_TAG):refs/tags/$(PROJECT_GO_VERSION_TAG) \
		&& git checkout $(PROJECT_GO_VERSION_TAG)
	set -x && cd go/src \
		&& GOROOT_BOOTSTRAP=$(GOROOT_BOOTSTRAP) GOROOT_FINAL=$(PROJECT_GO_ROOT) ./make.bash -v

controller: \
	core/controller/Dockerfile \
	$(wildcard core/controller/*.go) \
	core/controller/go.mod \
	core/controller/go.sum
	sudo buildctl build \
		--frontend=dockerfile.v0 \
		--opt platform=linux/amd64 \
		--local context="$(CONTROLLER_DIR)" \
		--local dockerfile="$(CONTROLLER_DIR)" \
		--opt filename=./Dockerfile \
		--opt build-arg:CACHEBUST=$$(date +%s%3N) \
		--opt target=build \
		--progress=plain


test-controller: \
	core/controller/Dockerfile \
	$(wildcard core/controller/*.go) \
	core/controller/go.mod \
	core/controller/go.sum
	sudo buildctl build \
		--frontend=dockerfile.v0 \
		--opt platform=linux/amd64 \
		--local context=$(CONTROLLER_DIR) \
		--local dockerfile=$(CONTROLLER_DIR) \
		--opt filename=./Dockerfile \
		--opt build-arg:CACHEBUST=$$(date +%s%3N) \
		--opt build-arg:ENABLE_LINT=$(ENABLE_LINT) \
		--opt target=test \
		--progress=plain

BUILDCTL		?= sudo buildctl
CACHEBUST		= --opt build-arg:CACHEBUST=$$(date +%s%3N)

# $(call buildctl_oci, CONTEXT, IMAGE_NAME, EXTRA_OPTS)
define buildctl_oci
	$(BUILDCTL) build \
		--frontend=dockerfile.v0 \
		--opt platform=linux/amd64 \
		--local context=$(1) \
		--local dockerfile=$(1) \
		--opt filename=./Dockerfile \
		--progress=plain \
		$(3) \
		--output type=oci,name=$(2),dest=$@
endef

$(CONTROLLER_CONTAINER_OUTPUT): \
	core/controller/Dockerfile \
	core/controller/entrypoint.sh \
	$(wildcard core/controller/*.go) \
	core/controller/go.mod \
	core/controller/go.sum
	$(call buildctl_oci,$(CONTROLLER_DIR),$(CONTROLLER_IMAGE_NAME),--opt target=runtime $(CACHEBUST))

$(FFMPEG_CONTAINER_OUTPUT): BUILDCTL := sudo buildctl --addr tcp://127.0.0.1:1234
$(FFMPEG_CONTAINER_OUTPUT): \
	$(CORE_DIR)/Dockerfile
	$(call buildctl_oci,$(CORE_DIR),$(FFMPEG_IMAGE_NAME),--opt target=ffmpeg)

$(MEDIAMTX_CONTAINER_OUTPUT): \
	$(CORE_DIR)/Dockerfile \
	$(CORE_DIR)/entrypoint.mediamtx.sh
	$(call buildctl_oci,$(CORE_DIR),$(MEDIAMTX_IMAGE_NAME),--opt target=mediamtx)

$(OPENSSH_RPM_OUTPUT): \
	$(OPENSSH_DIR)/Dockerfile
	sudo buildctl build \
		--frontend=dockerfile.v0 \
		--opt platform=linux/amd64 \
		--local context=$(OPENSSH_DIR) \
		--local dockerfile=$(OPENSSH_DIR) \
		--opt filename=./Dockerfile \
		--opt target=artifact \
		--progress=plain \
		--output type=local,dest=$(OUTPUT_PATH)

$(LIBSRT_CONTAINER_OUTPUT): \
	$(SRT_TEST_DIR)/Dockerfile
	$(call buildctl_oci,$(SRT_TEST_DIR),$(LIBSRT_IMAGE_NAME),)

$(IPERF3_CONTAINER_OUTPUT): \
	$(BANDWIDTH_TEST_DIR)/Dockerfile
	$(call buildctl_oci,$(BANDWIDTH_TEST_DIR),$(IPERF3_IMAGE_NAME),)

core/strimserver.env:
	$(error Missing core/strimserver.env. Copy core/strimserver.env.example and fill in secrets)


STRIMSERVER_DEPLOYMENT_OUTPUT_PATH_DEPS := \
	$(CONTROLLER_CONTAINER_OUTPUT) \
	$(FFMPEG_CONTAINER_OUTPUT) \
	$(MEDIAMTX_CONTAINER_OUTPUT) \
	$(OFFLINE_SEGMENT_OUTPUT)

STRIMSERVER_DEPLOYMENT_OUTPUT_PATH_FILES := \
	$(CONTROLLER_IMAGE_FILE_NAME) \
	$(FFMPEG_IMAGE_FILE_NAME) \
	$(MEDIAMTX_IMAGE_FILE_NAME) \
	$(OFFLINE_SEGMENT_FILE_NAME)

ifeq ($(ENABLE_EXPERIMENTAL_OPENSSH),"true")
STRIMSERVER_DEPLOYMENT_OUTPUT_PATH_DEPS 	+= $(OPENSSH_RPM_OUTPUT)
STRIMSERVER_DEPLOYMENT_OUTPUT_PATH_FILES 	+= $(OPENSSH_RPM_FILE_NAME)
endif

$(STRIMSERVER_DEPLOYMENT_TAR): \
	feature-toggles.env \
	deploy/aws/deploy.sh \
	deploy/aws/fish-deploy.sh \
	deploy/aws/imdslib.sh \
	deploy/aws/prompt_login.fish \
	deploy/aws/strimserver.service \
	core/strimserver.env \
	core/mediamtx.yaml.template \
	core/transcode.sh \
	core/notify.sh \
	$(STRIMSERVER_DEPLOYMENT_OUTPUT_PATH_DEPS)
	tar -cvf $@ \
		--ignore-failed-read --warning=all --show-transformed-names \
		--transform='s#deploy/aws/##' \
		--transform='s#core/##' \
		feature-toggles.env \
		deploy/aws/deploy.sh \
		deploy/aws/fish-deploy.sh \
		deploy/aws/imdslib.sh \
		deploy/aws/prompt_login.fish \
		deploy/aws/strimserver.service \
		core/strimserver.env \
		core/mediamtx.yaml.template \
		core/transcode.sh \
		core/notify.sh \
		-C $(OUTPUT_PATH) $(STRIMSERVER_DEPLOYMENT_OUTPUT_PATH_FILES)

$(IPERF3_DEPLOYMENT_TAR): \
	$(IPERF3_CONTAINER_OUTPUT) \
	$(BANDWIDTH_TEST_DIR)/iperf-deploy.sh \
	$(BANDWIDTH_TEST_DIR)/fish-deploy.sh \
	$(BANDWIDTH_TEST_DIR)/imdslib.sh \
	$(BANDWIDTH_TEST_DIR)/prompt_login.fish \
	$(BANDWIDTH_TEST_DIR)/iperf3.service \
	$(BANDWIDTH_TEST_DIR)/iperf3.env
	tar --ignore-failed-read --warning=all --show-transformed-names -cvf $@ \
		--transform='s#iperf-deploy\.sh$$#deploy.sh#' \
		$(BANDWIDTH_TEST_DIR)/iperf-deploy.sh \
		$(BANDWIDTH_TEST_DIR)/fish-deploy.sh \
		$(BANDWIDTH_TEST_DIR)/imdslib.sh \
		$(BANDWIDTH_TEST_DIR)/prompt_login.fish \
		$(BANDWIDTH_TEST_DIR)/iperf3.service \
		$(BANDWIDTH_TEST_DIR)/iperf3.env \
		-C $(OUTPUT_PATH) $(IPERF3_IMAGE_FILE_NAME)

build-libsrt: $(LIBSRT_CONTAINER_OUTPUT)
	@echo "We built $(LIBSRT_CONTAINER_OUTPUT) EZ Clap"

publish-strimserver: $(STRIMSERVER_DEPLOYMENT_TAR)
	@echo "We built $(STRIMSERVER_DEPLOYMENT_TAR) EZ Clap"
	aws s3 cp $(STRIMSERVER_DEPLOYMENT_TAR) $(S3_BUCKET)/$(STRIMSERVER_DEPLOYMENT_FILE_NAME)
	rm -rf $(STRIMSERVER_DEPLOYMENT_TAR)

publish-iperf3: $(IPERF3_DEPLOYMENT_TAR)
	@echo "We built $(IPERF3_DEPLOYMENT_TAR) EZ Clap"
	aws s3 cp $(IPERF3_DEPLOYMENT_TAR) $(S3_BUCKET)/$(IPERF3_DEPLOYMENT_FILE_NAME)
	rm -rf $(IPERF3_DEPLOYMENT_TAR)

