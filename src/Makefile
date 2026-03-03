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
LIBSRT_CONTAINER_OUTPUT 			:= $(OUTPUT_PATH)/$(LIBSRT_IMAGE_FILE_NAME)
IPERF3_CONTAINER_OUTPUT 			:= $(OUTPUT_PATH)/$(IPERF3_IMAGE_FILE_NAME)
STRIMSERVER_DEPLOYMENT_TAR			:= $(OUTPUT_PATH)/$(STRIMSERVER_DEPLOYMENT_FILE_NAME)
IPERF3_DEPLOYMENT_TAR				:= $(OUTPUT_PATH)/$(IPERF3_DEPLOYMENT_FILE_NAME)


.DEFAULT_GOAL := publish-strimserver


$(STRIMSERVER_CONTAINER_OUTPUT): \
	Dockerfile \
	mediamtx.yaml.template \
	mediamtx-entrypoint.sh \
	egress-ffmpeg.sh
	sudo buildctl build \
		--frontend=dockerfile.v0 \
		--opt platform=linux/amd64 \
		--local context=. \
		--local dockerfile=. \
		--opt filename=./Dockerfile \
		--progress=plain \
		--output type=oci,name=$(STRIMSERVER_IMAGE_NAME),dest=$@


$(LIBSRT_CONTAINER_OUTPUT): \
	Dockerfile-libsrt
	sudo buildctl build \
		--frontend=dockerfile.v0 \
		--opt platform=linux/amd64 \
		--local context=. \
		--local dockerfile=. \
		--opt filename=./Dockerfile-libsrt \
		--progress=plain \
		--output type=oci,name=$(LIBSRT_IMAGE_NAME),dest=$@

$(IPERF3_CONTAINER_OUTPUT): \
	Dockerfile-iperf3
	sudo buildctl build \
		--frontend=dockerfile.v0 \
		--opt platform=linux/amd64 \
		--local context=. \
		--local dockerfile=. \
		--opt filename=./Dockerfile-iperf3 \
		--progress=plain \
		--output type=oci,name=$(IPERF3_IMAGE_NAME),dest=$@

$(STRIMSERVER_DEPLOYMENT_TAR): \
   $(STRIMSERVER_CONTAINER_OUTPUT) \
   deploy.sh \
   fish-deploy.sh \
   imdslib.sh \
   prompt_login.fish \
   strimserver.service \
   strimserver.env
	tar -cvf $@ --warning=no-file-changed \
		deploy.sh \
		fish-deploy.sh \
		imdslib.sh \
		prompt_login.fish \
		strimserver.service \
		strimserver.env \
		-C $(OUTPUT_PATH) $(STRIMSERVER_IMAGE_FILE_NAME)

$(IPERF3_DEPLOYMENT_TAR): $(IPERF3_CONTAINER_OUTPUT) iperf-deploy.sh fish-deploy.sh imdslib.sh prompt_login.fish iperf3.service iperf3.env
	tar --ignore-failed-read --warning=all --show-transformed-names -cvf $@ --transform='s#iperf-deploy\.sh$$#deploy.sh#' iperf-deploy.sh fish-deploy.sh imdslib.sh prompt_login.fish iperf3.service iperf3.env -C $(OUTPUT_PATH) $(IPERF3_IMAGE_FILE_NAME)

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

