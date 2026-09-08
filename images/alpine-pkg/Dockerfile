ARG BASE_IMAGE=alpine
FROM ${BASE_IMAGE}

# Plain upstream Alpine, not our own php image -- see
# images/debian-pkg/Dockerfile for why.
#
# Alpine's own php packages are versioned (php83, php84, ...) rather than a
# stable "php" name, and which version(s) exist depends on the Alpine
# release. Resolve whatever's newest/available at build time instead of
# hardcoding a version that will go stale.
RUN set -eux; \
	apk update; \
	PHP_PKG="$(apk search --exact -q 'php[0-9]*' | grep -E '^php[0-9]+$' | sort -V | tail -1)"; \
	[ -n "$PHP_PKG" ] || PHP_PKG=php; \
	apk add --no-cache \
		"$PHP_PKG" \
		"${PHP_PKG}-cli" \
		"${PHP_PKG}-curl" \
		"${PHP_PKG}-pecl-imagick" \
		"${PHP_PKG}-openssl" \
		ca-certificates \
	; \
	# Alpine deliberately doesn't provide an unversioned "php" (its package
	# manager lets multiple PHP versions coexist), but our benchmark
	# scripts invoke a plain "php" -- symlink it so this image is a
	# drop-in match for the official images' PHP_BIN=php convention.
	ln -sf "/usr/bin/${PHP_PKG}" /usr/local/bin/php
