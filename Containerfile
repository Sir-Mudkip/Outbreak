# Outbreak — see docs/build-stages.md
ARG FEDORA_VERSION=44

FROM scratch AS ctx
COPY build /build
COPY system /system

FROM quay.io/fedora/fedora-bootc:${FEDORA_VERSION}

ARG FEDORA_VERSION=44
ARG IMAGE_NAME="outbreak"
ARG IMAGE_VENDOR="sir-mudkip"
ARG VERSION="local"

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build/build.sh

RUN bootc container lint
