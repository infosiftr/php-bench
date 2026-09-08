ARG BASE_IMAGE=debian
FROM ${BASE_IMAGE}

# Plain upstream Debian, not our own php image: the whole point of this
# target is "what a user gets from `apt-get install php` on vanilla
# Debian", with none of our image's own customization (entrypoint,
# docker-php-ext-* helpers, env vars, etc.) anywhere in the picture. See
# https://github.com/docker-library/php/issues/493, where this comparison first showed up.
RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		php-cli \
		php-curl \
		php-imagick \
		openssl \
		ca-certificates \
	; \
	rm -rf /var/lib/apt/lists/*
