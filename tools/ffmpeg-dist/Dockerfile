# syntax=docker/dockerfile:1
# =============================================================================
# tools/ffmpeg-dist/Dockerfile -- thin wrapper around the shared build.sh
#
# The single source of truth for the pinned FFmpeg artifact build is
# tools/ffmpeg-dist/build.sh. This Dockerfile only supplies the base image,
# forwards the pin ARGs as env vars, and exposes the two artifact files via the
# scratch `out` stage. It is kept as an equivalent alternative for hosts that
# do have docker; the default path is tools/ffmpeg-dist/publish.sh, which
# builds the same artifact directly via chroot+qemu with no docker. The sha256
# of the resulting tarball is the contract MODULE.bazel
# pins against -- both paths must (and do) produce identical output.
#
# Pinned inputs (all overridable as --build-arg / env):
#   FFMPEG_VERSION       8.0
#   FFMPEG_COMMIT        281c902aa1a83fe759011097cb005b555034c151
#   NV_CODEC_HEADERS_TAG n13.0.19.0
#   NV_CODEC_HEADERS_COMMIT e844e5b26f46bb77479f063029595293aa8f812d
#   CUDA_MANIFEST_URL    redistrib_13.0.2.json
#   CUDA_COMPONENTS      cuda_nvcc cuda_cudart cuda_crt libnvvm
#   DEBIAN_SNAPSHOT      20260824T082821Z
#   GENCODE              arch=compute_75,code=sm_75
#   NPROC                host nproc (empty ARG default; build.sh derives it)
#
# Output (stage `out`): /out/ffmpeg (stripped) + /out/BUILD-INFO.txt
# =============================================================================

FROM debian:trixie-20260824-slim AS build

# bash: the configure flag array (--nvccflags / --extra-libs carry spaces) and
# pipefail need bash; dash (the image default shell) has neither.
SHELL ["/bin/bash", "-eux", "-o", "pipefail", "-c"]

ARG FFMPEG_VERSION="8.0"
ARG FFMPEG_COMMIT="281c902aa1a83fe759011097cb005b555034c151"
ARG NV_CODEC_HEADERS_TAG="n13.0.19.0"
ARG NV_CODEC_HEADERS_COMMIT="e844e5b26f46bb77479f063029595293aa8f812d"
ARG CUDA_MANIFEST_URL="https://developer.download.nvidia.com/compute/cuda/redist/redistrib_13.0.2.json"
ARG DEBIAN_SNAPSHOT="20260824T082821Z"
ARG CUDA_COMPONENTS="cuda_nvcc cuda_cudart cuda_crt libnvvm"
ARG GENCODE="arch=compute_75,code=sm_75"
ARG NPROC=""

# Forward every pin as an env var so the shared build.sh sees them; build.sh
# applies the same defaults when an ARG is left unset. (Legacy ENV form: the
# whole rest of the line is the value, so CUDA_COMPONENTS' spaces survive.)
ENV FFMPEG_VERSION $FFMPEG_VERSION
ENV FFMPEG_COMMIT $FFMPEG_COMMIT
ENV NV_CODEC_HEADERS_TAG $NV_CODEC_HEADERS_TAG
ENV NV_CODEC_HEADERS_COMMIT $NV_CODEC_HEADERS_COMMIT
ENV CUDA_MANIFEST_URL $CUDA_MANIFEST_URL
ENV DEBIAN_SNAPSHOT $DEBIAN_SNAPSHOT
ENV CUDA_COMPONENTS $CUDA_COMPONENTS
ENV GENCODE $GENCODE
ENV NPROC $NPROC

# The entire build (apt snapshot pinning, CUDA, nv-codec-headers, FFmpeg) lives
# in build.sh; the context must be the repository root so the COPY resolves.
COPY tools/ffmpeg-dist/build.sh /build.sh
RUN chmod +x /build.sh && /build.sh

# --- out: the artifact payload (exactly two files) ---
FROM scratch AS out
COPY --from=build /opt/ffmpeg-dist/usr/local/bin/ffmpeg /out/ffmpeg
COPY --from=build /opt/ffmpeg-dist/BUILD-INFO.txt /out/BUILD-INFO.txt