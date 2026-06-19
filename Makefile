CORE_DIR := core
AWS_DEPLOY_DIR := deploy/aws
LOCAL_ENCODER_DIR := tools/local-encoder
BANDWIDTH_TEST_DIR := tools/bandwidth-test
SRT_TEST_DIR := tools/srt-test
OPENSSH_DIR := tools/openssh


S3_BUCKET 								?= s3://<bucket-name>
OUTPUT_PATH								?= $(HOME)/local-dev/strimserver
STRIMSERVER_IMAGE_NAME 				?= docker.io/library/strimserver:latest
LIBSRT_IMAGE_NAME 					?= docker.io/library/libsrt:latest
IPERF3_IMAGE_NAME 					?= docker.io/library/iperf3:latest
STRIMSERVER_IMAGE_FILE_NAME 		?= strimserver-container.tar
LIBSRT_IMAGE_FILE_NAME 				?= libsrt-container.tar
IPERF3_IMAGE_FILE_NAME 				?= iperf3-container.tar
STRIMSERVER_DEPLOYMENT_FILE_NAME ?= strimserver-deployment.tar
IPERF3_DEPLOYMENT_FILE_NAME 		?= iperf3-deployment.tar
STRIMSERVER_CONTAINER_OUTPUT 		:= $(OUTPUT_PATH)/$(STRIMSERVER_IMAGE_FILE_NAME)
OFFLINE_SEGMENT_FILE_NAME			:= strimserver-offline-2160p60.mp4
OFFLINE_SEGMENT_OUTPUT				:= $(OUTPUT_PATH)/$(OFFLINE_SEGMENT_FILE_NAME)
OPENSSH_RPM_FILE_NAME				:= openssh-experimental.rpm
OPENSSH_RPM_OUTPUT					:= $(OUTPUT_PATH)/$(OPENSSH_RPM_FILE_NAME)
LIBSRT_CONTAINER_OUTPUT 			:= $(OUTPUT_PATH)/$(LIBSRT_IMAGE_FILE_NAME)
IPERF3_CONTAINER_OUTPUT 			:= $(OUTPUT_PATH)/$(IPERF3_IMAGE_FILE_NAME)
STRIMSERVER_DEPLOYMENT_TAR			:= $(OUTPUT_PATH)/$(STRIMSERVER_DEPLOYMENT_FILE_NAME)
IPERF3_DEPLOYMENT_TAR				:= $(OUTPUT_PATH)/$(IPERF3_DEPLOYMENT_FILE_NAME)


-include feature-toggles.env

ENABLE_EXPERIMENTAL_OPENSSH		?= false
ENABLE_LINT								?= true

.DEFAULT_GOAL := publish-strimserver

.PHONY := controller test-controller

controller: \
	core/controller/dockerfile
	sudo buildctl build \
		--frontend=dockerfile.v0 \
		--opt platform=linux/amd64 \
		--local context=core/controller \
		--local dockerfile=core/controller \
		--opt filename=./Dockerfile \
      --opt build-arg:CACHEBUST=$$(date +%s%3N) \
		--opt target=build \
		--progress=plain


test-controller: \
	core/controller/dockerfile
	sudo buildctl build \
		--frontend=dockerfile.v0 \
		--opt platform=linux/amd64 \
		--local context=core/controller \
		--local dockerfile=core/controller \
		--opt filename=./Dockerfile \
      --opt build-arg:CACHEBUST=$$(date +%s%3N) \
		--opt build-arg:ENABLE_LINT=$(ENABLE_LINT) \
		--opt target=test \
		--progress=plain

$(STRIMSERVER_CONTAINER_OUTPUT): \
	$(CORE_DIR)/Dockerfile \
	$(CORE_DIR)/entrypoint.sh
	sudo buildctl --addr tcp://127.0.0.1:1234 build \
		--frontend=dockerfile.v0 \
		--opt platform=linux/amd64 \
		--local context=$(CORE_DIR) \
		--local dockerfile=$(CORE_DIR) \
		--opt filename=./Dockerfile \
		--opt build-arg:ENABLE_OBS=$(ENABLE_OBS) \
		--opt build-arg:ENABLE_EMBEDDED_FISH_SHELL=$(ENABLE_EMBEDDED_FISH_SHELL) \
		--opt target=runtime \
		--progress=plain \
		--output type=oci,name=$(STRIMSERVER_IMAGE_NAME),dest=$@

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
	sudo buildctl build \
		--frontend=dockerfile.v0 \
		--opt platform=linux/amd64 \
		--local context=$(SRT_TEST_DIR) \
		--local dockerfile=$(SRT_TEST_DIR) \
		--opt filename=./Dockerfile \
		--progress=plain \
		--output type=oci,name=$(LIBSRT_IMAGE_NAME),dest=$@

$(IPERF3_CONTAINER_OUTPUT): \
	$(BANDWIDTH_TEST_DIR)/Dockerfile
	sudo buildctl build \
		--frontend=dockerfile.v0 \
		--opt platform=linux/amd64 \
		--local context=$(BANDWIDTH_TEST_DIR) \
		--local dockerfile=$(BANDWIDTH_TEST_DIR) \
		--opt filename=./Dockerfile \
		--progress=plain \
		--output type=oci,name=$(IPERF3_IMAGE_NAME),dest=$@

core/strimserver.env:
	$(error Missing core/strimserver.env. Copy core/strimserver.env.example and fill in secrets)


STRIMSERVER_DEPLOYMENT_OUTPUT_PATH_DEPS := \
   $(STRIMSERVER_CONTAINER_OUTPUT) \
   $(OFFLINE_SEGMENT_OUTPUT)

STRIMSERVER_DEPLOYMENT_OUTPUT_PATH_FILES := \
	$(STRIMSERVER_IMAGE_FILE_NAME) \
	$(OFFLINE_SEGMENT_FILE_NAME)

ifeq ($(ENABLE_EXPERIMENTAL_OPENSSH),"true")
STRIMSERVER_DEPLOYMENT_OUTPUT_PATH_DEPS += $(OPENSSH_RPM_OUTPUT)
STRIMSERVER_DEPLOYMENT_OUTPUT_PATH_FILES += $(OPENSSH_RPM_FILE_NAME)
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

