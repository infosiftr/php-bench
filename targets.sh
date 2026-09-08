#!/usr/bin/env bash
# The benchmark matrix. Edit the arrays below to change what gets benchmarked.
#
# Two kinds of targets:
#   - "official": a tag from docker-library/php (what we ship).
#   - "distro-pkg": the *same base OS image* (e.g. php:8.4-cli-bookworm minus
#     our compiled PHP) with that distro's own native PHP package installed
#     instead. This mirrors the trick used in https://github.com/docker-library/php/issues/493 to
#     compare our compiled PHP against Debian's/Alpine's packaged PHP on
#     identical userland. There's one distro-pkg target per OS (not per
#     version), since a distro ships one native PHP version per release;
#     reports pair it against whichever official version(s) match.
set -Eeuo pipefail

PHP_VERSIONS=(8.2 8.3 8.4 8.5)
DEBIAN_OSES=(bookworm trixie)
ALPINE_OSES=(alpine3.23 alpine3.24)
OSES=("${DEBIAN_OSES[@]}" "${ALPINE_OSES[@]}")
SAPIS=(cli fpm zts)

is_debian_os() {
	local os="$1" d
	for d in "${DEBIAN_OSES[@]}"; do
		[[ "$os" == "$d" ]] && return 0
	done
	return 1
}

official_image() {
	local version="$1" sapi="$2" os="$3"
	echo "php:${version}-${sapi}-${os}"
}

official_id() {
	local version="$1" sapi="$2" os="$3"
	echo "official-${version}-${sapi}-${os}"
}

# Emits "id|image|version|os|sapi|label", one per line, for every official
# tag in the matrix (cli/fpm/zts everywhere, +apache on Debian OSes).
list_official_targets() {
	local version os sapi
	for version in "${PHP_VERSIONS[@]}"; do
		for os in "${OSES[@]}"; do
			local sapis=("${SAPIS[@]}")
			is_debian_os "$os" && sapis+=(apache)
			for sapi in "${sapis[@]}"; do
				local image; image="$(official_image "$version" "$sapi" "$os")"
				local id; id="$(official_id "$version" "$sapi" "$os")"
				echo "${id}|${image}|${version}|${os}|${sapi}|${image} (official)"
			done
		done
	done
}

# Same, but CLI-only -- the relevant subset for per-script CPU/TLS/Imagick
# benchmarks (fpm/apache/zts don't change the speed of `php script.php`).
list_cpu_style_official_targets() {
	list_official_targets | awk -F'|' '$5 == "cli"'
}

distro_pkg_base_image() {
	local os="$1"
	if is_debian_os "$os"; then
		echo "debian:${os}"
	else
		# "alpine3.23" -> "alpine:3.23"
		echo "alpine:${os#alpine}"
	fi
}

distro_pkg_built_image() {
	local os="$1"
	echo "php-bench/distro-pkg:${os}"
}

distro_pkg_id() {
	local os="$1"
	echo "distro-pkg-${os}"
}

# Emits "id|base_image|built_image|os|label", one per line.
list_distro_pkg_targets() {
	local os
	for os in "${OSES[@]}"; do
		echo "$(distro_pkg_id "$os")|$(distro_pkg_base_image "$os")|$(distro_pkg_built_image "$os")|${os}|${os} native package (distro-pkg)"
	done
}

# Emits "id|version|os|mode|label" for the apache/fpm architecture
# comparison. Only prefork and fpm-nginx are here, not the mpm_event swap
# https://github.com/docker-library/php/issues/742 discusses: the official
# apache image is an NTS build, and Apache refuses to load a non-thread-safe
# PHP module under a threaded MPM (mpm_event/mpm_worker) -- confirmed by
# actually trying it (`a2enmod mpm_event` -> "Apache is running a threaded
# MPM, but your PHP Module is not compiled to be threadsafe"), and there is
# no official image today that combines ZTS with Apache to work around it.
# That's a real, reproducible answer to #742, just not one hyperfine/a load
# test can put a number on.
list_throughput_targets() {
	local version os mode
	for version in "${PHP_VERSIONS[@]}"; do
		for os in "${DEBIAN_OSES[@]}"; do  # apache variant is Debian-only
			for mode in apache-prefork fpm-nginx; do
				local sapi=apache
				[[ "$mode" == fpm-nginx ]] && sapi=fpm
				echo "throughput-${version}-${os}-${mode}|${version}|${os}|${mode}|php:${version}-${sapi}-${os} [${mode}]"
			done
		done
	done
}
