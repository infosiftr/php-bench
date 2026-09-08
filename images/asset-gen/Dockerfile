FROM php:cli-alpine

# Only used once, on the host, to render bench/imagick/assets/bench.jpg.
# Never part of the benchmarked matrix itself.
RUN set -eux; \
	apk add --no-cache libpng-dev libjpeg-turbo-dev $PHPIZE_DEPS; \
	docker-php-ext-configure gd --with-jpeg; \
	docker-php-ext-install gd
