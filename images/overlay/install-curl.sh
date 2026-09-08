#!/bin/sh
# For official (compiled) PHP images ONLY. Never run this against a
# distro-packaged PHP (images/*-pkg/Dockerfile) -- it uses
# docker-php-ext-install, which assumes our own build tooling, and Debian's
# php-curl/Alpine's phpNN-curl would be compiled against a *different* PHP's
# ABI. Distro-pkg images install their own curl binding directly (see
# images/debian-pkg/Dockerfile and images/alpine-pkg/Dockerfile).
set -eu

PHP_BIN="${1:-php}"

if "$PHP_BIN" -m 2>/dev/null | grep -qi '^curl$'; then
	exit 0
fi

if command -v apt-get >/dev/null 2>&1; then
	apt-get update
	apt-get install -y --no-install-recommends libcurl4-openssl-dev openssl ca-certificates
	rm -rf /var/lib/apt/lists/*
elif command -v apk >/dev/null 2>&1; then
	apk add --no-cache curl-dev openssl ca-certificates $PHPIZE_DEPS
else
	echo "no supported package manager found" >&2
	exit 1
fi

docker-php-ext-install curl
