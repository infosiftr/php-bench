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

PHP_VERSIONS=(8.2 8.3 8.4 8.5 8.6)
DEBIAN_OSES=(bookworm trixie)
ALPINE_OSES=(alpine3.23 alpine3.24)
OSES=("${DEBIAN_OSES[@]}" "${ALPINE_OSES[@]}")

# version_ge A B -- true if dotted version A >= B.
version_ge() {
	[ "$(printf '%s\n' "$1" "$2" | sort --version-sort | head --lines=1)" = "$2" ]
}

# Which published image is the NTS build and which the ZTS build is *not*
# written down here, on purpose: it has changed once already (8.6 made every
# tag ZTS and dropped the `zts` variant, see
# https://github.com/docker-library/php/issues/1719) and may again (an
# explicit `nts` tag, or `cli` going back to NTS with `zts` restored).
# https://github.com/docker-library/php/pull/1722 (open as of 2026-11-20, and
# not certain to be merged) proposes one such change: an 8.6-only `nts`
# variant, plus `zts` alias tags for `cli`.  The cpu suite works it out at
# run time instead -- resolve_cpu_pair in run.sh.

# 8.6+ images drop pecl/pear (no --with-pear), which install-imagick.sh
# needs; the imagick suite skips those versions.
NO_PECL_FROM=8.6
version_has_pecl() {
	! version_ge "$1" "$NO_PECL_FROM"
}

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

nts_built_image() {
	local version="$1" os="$2"
	echo "php-bench/nts:${version}-cli-${os}"
}

# Emits "id|image|version|os|sapi|label", one per line, for every official
# tag in the matrix that doesn't depend on which build is which (cli/fpm
# everywhere, +apache on Debian OSes). The cpu suite's nts/zts tags aren't
# here; see list_cpu_pairs.
list_official_targets() {
	local version os sapi
	for version in "${PHP_VERSIONS[@]}"; do
		for os in "${OSES[@]}"; do
			local sapis=(cli fpm)
			is_debian_os "$os" && sapis+=(apache)
			for sapi in "${sapis[@]}"; do
				local image; image="$(official_image "$version" "$sapi" "$os")"
				local id; id="$(official_id "$version" "$sapi" "$os")"
				echo "${id}|${image}|${version}|${os}|${sapi}|${image} (official)"
			done
		done
	done
}

# Same, but CLI-only -- the relevant subset for TLS/Imagick benchmarks
# (fpm/apache don't change the speed of `php script.php`; the CPU suite
# uses list_cpu_pairs below instead, since zts *does* change it and is
# exactly what that suite is for).
list_cpu_style_official_targets() {
	list_official_targets | awk -F'|' '$5 == "cli"'
}

# Same, but without the versions whose images have no pecl -- the imagick
# suite compiles its extension from pecl (images/overlay/install-imagick.sh).
list_imagick_targets() {
	local id image version os sapi label
	list_cpu_style_official_targets | while IFS='|' read -r id image version os sapi label; do
		if version_has_pecl "$version"; then
			echo "${id}|${image}|${version}|${os}|${sapi}|${label}"
		fi
	done
}

# The cpu suite's script variants (bench/cpu/run.sh defines what each means).
CPU_VARIANTS=(baseline opcache jit)

# Scripts that take seconds per run (hash is deliberately a bcrypt loop), and
# so get far fewer timed runs per interleaved round than the millisecond
# ones -- see bench_cpu_pair in run.sh.
CPU_SLOW_SCRIPTS=(hash)

# Emits "version|os", one per version/OS: the pairs the nts-vs-zts
# comparison runs on. TSRM (thread-safety bookkeeping) adds real per-access
# overhead to every global/static lookup even with a single thread running,
# which is the "non-negligible" cost flagged in
# https://github.com/docker-library/php/issues/742. Which images make up
# each side is resolved at run time (resolve_cpu_pair in run.sh), and the two
# sides are run interleaved (bench_cpu_pair) rather than one target after
# the other.
list_cpu_pairs() {
	local version os
	for version in "${PHP_VERSIONS[@]}"; do
		for os in "${OSES[@]}"; do
			echo "${version}|${os}"
		done
	done
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
# comparison. apache-prefork and fpm-nginx are here, plus fpm-httpd (the
# official httpd image fronting the same php-fpm backend via
# mod_proxy_fcgi, an apples-to-apples alternative to fpm-nginx rather than
# a third architecture). Not here: the mpm_event swap
# https://github.com/docker-library/php/issues/742 discusses: the official
# apache image is an NTS build, and Apache refuses to load a non-thread-safe
# PHP module under a threaded MPM (mpm_event/mpm_worker) -- confirmed by
# actually trying it (`a2enmod mpm_event` -> "Apache is running a threaded
# MPM, but your PHP Module is not compiled to be threadsafe"), and no
# official apache image through 8.5 is ZTS. That's a real, reproducible
# answer to #742, just not one hyperfine/a load test can put a number on.
# 8.6's apache image *is* ZTS (all of 8.6's are, per the note near the top
# of this file), though it still ships with `a2dismod mpm_event && a2enmod
# mpm_prefork`, so the 8.6 apache targets below are still prefork; whether
# mpm_event now loads there is untested.
list_throughput_targets() {
	local version os mode
	for version in "${PHP_VERSIONS[@]}"; do
		for os in "${DEBIAN_OSES[@]}"; do  # apache variant is Debian-only
			for mode in apache-prefork fpm-nginx fpm-httpd; do
				local sapi=fpm
				[[ "$mode" == apache-prefork ]] && sapi=apache
				echo "throughput-${version}-${os}-${mode}|${version}|${os}|${mode}|php:${version}-${sapi}-${os} [${mode}]"
			done
		done
	done
}
