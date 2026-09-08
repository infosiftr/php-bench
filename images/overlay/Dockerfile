# Layers hyperfine (safe on any target) and, optionally, curl/imagick
# compiled against the base image's own PHP.
#
# NEED_CURL=1 / NEED_IMAGICK=1 must only be used on official (compiled) PHP
# base images -- see images/overlay/install-curl.sh and install-imagick.sh
# for why. distro-pkg base images (images/*-pkg/Dockerfile) already bake in
# their own curl/imagick and should always be built with NEED_CURL=0
# NEED_IMAGICK=0 here (the scripts also no-op if the extension is already
# present, as defense in depth, but the orchestrator must not rely on that).
ARG BASE_IMAGE=php:cli
FROM ${BASE_IMAGE}

ARG NEED_IMAGICK=0
ARG NEED_CURL=0
ARG PHP_BIN=php

COPY install-hyperfine.sh install-imagick.sh install-curl.sh /tmp/overlay/

RUN sh /tmp/overlay/install-hyperfine.sh
RUN if [ "$NEED_CURL" = "1" ]; then sh /tmp/overlay/install-curl.sh "$PHP_BIN"; fi
RUN if [ "$NEED_IMAGICK" = "1" ]; then sh /tmp/overlay/install-imagick.sh "$PHP_BIN"; fi
RUN rm -rf /tmp/overlay
