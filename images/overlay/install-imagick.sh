#!/bin/sh
# For official (compiled) PHP images ONLY -- see install-curl.sh for why.
# Always compiles imagick from pecl against *this* PHP's own headers/ABI
# (phpize/php-config), rather than ever installing Debian's php-imagick or
# Alpine's phpNN-imagick, which are built against that distro's own
# separately-packaged PHP and would not load correctly (or would silently
# load against the wrong interpreter) here.
set -eu

PHP_BIN="${1:-php}"

if "$PHP_BIN" -m 2>/dev/null | grep -qi '^imagick$'; then
	exit 0
fi

if command -v apt-get >/dev/null 2>&1; then
	apt-get update
	apt-get install -y --no-install-recommends libmagickwand-dev $PHPIZE_DEPS
	rm -rf /var/lib/apt/lists/*
elif command -v apk >/dev/null 2>&1; then
	apk add --no-cache imagemagick-dev libtool $PHPIZE_DEPS
else
	echo "no supported package manager found" >&2
	exit 1
fi

pecl install imagick
docker-php-ext-enable imagick
