#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

source .targets.sh

RESULTS_DIR="${PROJECT_DIR}/results"

image_exists() {
	docker image inspect "$1" >/dev/null 2>&1
}

# docker_build TAG DOCKERFILE CONTEXT [BUILD_ARG=VALUE ...]
docker_build() {
	local tag="$1" dockerfile="$2" context="$3"
	shift 3
	local args=(docker build -t "$tag" -f "$dockerfile")
	local kv
	for kv in "$@"; do
		args+=(--build-arg "$kv")
	done
	args+=("$context")
	echo "+ ${args[*]}" >&2
	"${args[@]}"
}

# ensure_distro_pkg OS -> builds/reuses php-bench/distro-pkg:$OS from plain
# upstream debian/alpine (never from our own php image -- see
# images/debian-pkg/Dockerfile for why), echoes the resulting tag.
ensure_distro_pkg() {
	local os="$1"
	local base; base="$(distro_pkg_base_image "$os")"
	local tag; tag="$(distro_pkg_built_image "$os")"
	local dockerfile
	if is_debian_os "$os"; then
		dockerfile="${PROJECT_DIR}/images/debian-pkg/Dockerfile"
	else
		dockerfile="${PROJECT_DIR}/images/alpine-pkg/Dockerfile"
	fi
	if ! image_exists "$tag"; then
		docker_build "$tag" "$dockerfile" "$(dirname "$dockerfile")" "BASE_IMAGE=${base}" >&2
	fi
	echo "$tag"
}

# ensure_pulled TAG -- pulls if not already present locally
ensure_pulled() {
	local tag="$1"
	if ! image_exists "$tag"; then
		echo "+ docker pull $tag" >&2
		docker pull "$tag" >&2
	fi
}

# ensure_overlay BASE_IMAGE NEED_CURL NEED_IMAGICK -> builds/reuses the
# hyperfine(+curl/imagick) overlay on top of BASE_IMAGE, echoes the
# resulting tag. NEED_CURL/NEED_IMAGICK must be 0 for any base image that
# already has its own curl/imagick (i.e. distro-pkg images) -- see
# images/overlay/Dockerfile.
ensure_overlay() {
	local base_image="$1" need_curl="$2" need_imagick="$3"
	local safe_base; safe_base="$(echo "$base_image" | tr '/:' '__')"
	local tag="php-bench/overlay:${safe_base}-c${need_curl}-i${need_imagick}"
	if ! image_exists "$tag"; then
		ensure_pulled "$base_image"
		docker_build "$tag" "${PROJECT_DIR}/images/overlay/Dockerfile" "${PROJECT_DIR}/images/overlay" \
			"BASE_IMAGE=${base_image}" "NEED_CURL=${need_curl}" "NEED_IMAGICK=${need_imagick}" >&2
	fi
	echo "$tag"
}

usage() {
	cat <<'EOF'
Usage: run.sh <command> [args]

Commands:
  list                                Show the full target matrix
  build-distro-pkg [os...]            Build distro-pkg images (default: all)
  bench cpu        [--only PATTERN]   Run the CPU microbenchmark suite
  bench tls        [--only PATTERN]   Run the TLS/CA-verification suite
  bench imagick    [--only PATTERN]   Run the Imagick resize suite
  bench throughput [--only PATTERN]   Run the apache/fpm throughput suite
  report <suite>                      Print results/<suite>/*.json as CSV
  summarize                           Print the fixed cross-suite comparisons (summarize.jq)
EOF
}

# run_in_target SUITE TARGET_ID IMAGE PHP_BIN -- executes bench/<suite>/run.sh
# inside IMAGE, with bench/<suite> mounted read-only and results/<suite>
# mounted for output.
run_in_target() {
	local suite="$1" target_id="$2" image="$3" php_bin="$4"
	local out_dir="${RESULTS_DIR}/${suite}"
	mkdir -p "$out_dir"
	echo "=== ${suite}: ${target_id} (${image}, php_bin=${php_bin}) ===" >&2
	docker run --rm \
		-v "${PROJECT_DIR}/bench/${suite}:/bench:ro" \
		-v "${out_dir}:/results" \
		-e "TARGET_ID=${target_id}" \
		-e "RESULTS_DIR=/results" \
		-e "PHP_BIN=${php_bin}" \
		-w /bench \
		"$image" \
		sh run.sh
}

cmd_list() {
	echo "-- official targets --"
	list_official_targets | awk -F'|' '{printf "%-40s %s\n", $1, $2}'
	echo
	echo "-- distro-pkg targets --"
	list_distro_pkg_targets | awk -F'|' '{printf "%-40s %s (from %s)\n", $1, $5, $2}'
	echo
	echo "-- throughput targets --"
	list_throughput_targets | awk -F'|' '{printf "%-40s %s\n", $1, $5}'
}

cmd_build_distro_pkg() {
	local oses=("$@")
	[ ${#oses[@]} -eq 0 ] && oses=("${OSES[@]}")
	local os
	for os in "${oses[@]}"; do
		ensure_distro_pkg "$os" >/dev/null
		echo "built: $(distro_pkg_built_image "$os")"
	done
}

# bench_script_suite SUITE NEED_CURL NEED_IMAGICK TARGET_FN [--only PATTERN]
# Shared driver for cpu/tls/imagick: all three run one script (or a fixed
# script list) via bench/<suite>/run.sh against every target TARGET_FN
# lists (a .targets.sh list_*_targets function) plus every distro-pkg target.
bench_script_suite() {
	local suite="$1" need_curl="$2" need_imagick="$3" target_fn="$4"
	shift 4
	local only=""
	if [ "${1:-}" = "--only" ]; then
		only="$2"
	fi

	local line id image version os sapi label overlay
	"$target_fn" | while IFS='|' read -r id image version os sapi label; do
		[ -n "$only" ] && [[ "$id" != *"$only"* ]] && continue
		overlay="$(ensure_overlay "$image" "$need_curl" "$need_imagick")"
		run_in_target "$suite" "$id" "$overlay" php
	done

	local base_image built_image
	list_distro_pkg_targets | while IFS='|' read -r id base_image built_image os label; do
		[ -n "$only" ] && [[ "$id" != *"$only"* ]] && continue
		built_image="$(ensure_distro_pkg "$os")"
		# NEED_CURL/NEED_IMAGICK are always 0 here: distro-pkg images bake
		# their own curl/imagick in at build time (images/*-pkg/Dockerfile).
		overlay="$(ensure_overlay "$built_image" 0 0)"
		run_in_target "$suite" "$id" "$overlay" php
	done
}

THROUGHPUT_NETWORK="php-bench-throughput"
THROUGHPUT_SERVER="php-bench-throughput-server"
THROUGHPUT_FPM="php-bench-throughput-fpm"
THROUGHPUT_SOCK_VOLUME="php-bench-throughput-sock"

# bench_throughput_target ID VERSION OS MODE -- starts the server (apache
# mpm_prefork, or fpm+nginx talking over a Unix socket -- the way fpm+nginx
# is actually deployed in practice, not a cross-container TCP hop) on a
# private docker network, waits for it to serve real 200s, points
# bench/throughput/scripts/load.php at it, and tears the containers down
# again. See bench/throughput/app/index.php and
# https://github.com/docker-library/php/issues/681 for what this compares
# (and .targets.sh for why mpm_event isn't one of the modes).
bench_throughput_target() {
	local id="$1" version="$2" os="$3" mode="$4"
	echo "=== throughput: ${id} ===" >&2

	docker rm -f "$THROUGHPUT_SERVER" "$THROUGHPUT_FPM" >/dev/null 2>&1 || true

	local app_dir="${PROJECT_DIR}/bench/throughput/app"
	case "$mode" in
		apache-prefork)
			local image; image="$(official_image "$version" apache "$os")"
			ensure_pulled "$image"
			docker run -d --rm --name "$THROUGHPUT_SERVER" --network "$THROUGHPUT_NETWORK" \
				-v "${app_dir}:/var/www/html:ro" \
				"$image" >/dev/null
			;;
		fpm-nginx)
			local fpm_image; fpm_image="$(official_image "$version" fpm "$os")"
			ensure_pulled "$fpm_image"
			ensure_pulled nginx:stable
			docker volume inspect "$THROUGHPUT_SOCK_VOLUME" >/dev/null 2>&1 || docker volume create "$THROUGHPUT_SOCK_VOLUME" >/dev/null
			docker run -d --rm --name "$THROUGHPUT_FPM" --network "$THROUGHPUT_NETWORK" \
				-v "${app_dir}:/var/www/html:ro" \
				-v "${PROJECT_DIR}/bench/throughput/fpm/zz-socket.conf:/usr/local/etc/php-fpm.d/zz-socket.conf:ro" \
				-v "${THROUGHPUT_SOCK_VOLUME}:/run/php" \
				"$fpm_image" >/dev/null
			docker run -d --rm --name "$THROUGHPUT_SERVER" --network "$THROUGHPUT_NETWORK" \
				-v "${app_dir}:/var/www/html:ro" \
				-v "${PROJECT_DIR}/bench/throughput/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
				-v "${THROUGHPUT_SOCK_VOLUME}:/run/php" \
				nginx:stable >/dev/null
			;;
		*)
			echo "unknown throughput mode: $mode" >&2
			return 2
			;;
	esac

	local scripts_dir="${PROJECT_DIR}/bench/throughput/scripts"
	docker run --rm --network "$THROUGHPUT_NETWORK" \
		-v "${scripts_dir}:/scripts:ro" \
		php:cli php /scripts/wait-for-http.php "http://${THROUGHPUT_SERVER}/"

	# Multiple trials against the same already-warm server, not one sample:
	# a single load.php run is as susceptible to host noise as any one
	# hyperfine sample would be, and unlike the other suites (where
	# hyperfine itself takes ~15-20 samples), nothing here averages that
	# out unless we do it ourselves.
	local out_dir="${RESULTS_DIR}/throughput"
	mkdir -p "$out_dir"
	local trials=() trial_json n
	for n in $(seq 1 "${LOAD_TRIALS:-3}"); do
		trial_json="$(docker run --rm --network "$THROUGHPUT_NETWORK" \
			-v "${scripts_dir}:/scripts:ro" \
			php:cli \
			php /scripts/load.php "http://${THROUGHPUT_SERVER}/" "${LOAD_CONCURRENCY:-20}" "${LOAD_DURATION:-8}")"
		trials+=("$trial_json")
	done
	printf '%s\n' "${trials[@]}" | jq -s '{
		trials: .,
		median: {
			requests: (map(.requests) | sort | .[length/2 | floor]),
			errors: (map(.errors) | add),
			rps: (map(.rps) | sort | .[length/2 | floor]),
			p50_ms: (map(.p50_ms) | sort | .[length/2 | floor]),
			p95_ms: (map(.p95_ms) | sort | .[length/2 | floor]),
			p99_ms: (map(.p99_ms) | sort | .[length/2 | floor])
		},
		rps_min: (map(.rps) | min),
		rps_max: (map(.rps) | max)
	}' > "${out_dir}/throughput-${id}.json"

	docker rm -f "$THROUGHPUT_SERVER" "$THROUGHPUT_FPM" >/dev/null 2>&1 || true
}

bench_throughput_suite() {
	local only=""
	if [ "${1:-}" = "--only" ]; then
		only="$2"
	fi

	docker network inspect "$THROUGHPUT_NETWORK" >/dev/null 2>&1 || docker network create "$THROUGHPUT_NETWORK" >/dev/null
	trap 'docker rm -f "$THROUGHPUT_SERVER" "$THROUGHPUT_FPM" >/dev/null 2>&1 || true' EXIT

	local id version os mode label
	list_throughput_targets | while IFS='|' read -r id version os mode label; do
		[ -n "$only" ] && [[ "$id" != *"$only"* ]] && continue
		bench_throughput_target "$id" "$version" "$os" "$mode"
	done
}

cmd_bench() {
	local suite="$1"
	shift
	case "$suite" in
		cpu) bench_script_suite cpu 0 0 list_cpu_bench_targets "$@" ;;
		tls) bench_script_suite tls 1 0 list_cpu_style_official_targets "$@" ;;
		imagick)
			if [ ! -f "${PROJECT_DIR}/bench/imagick/assets/bench.jpg" ]; then
				bash "${PROJECT_DIR}/bench/imagick/generate-asset.sh"
			fi
			bench_script_suite imagick 0 1 list_cpu_style_official_targets "$@"
			;;
		throughput) bench_throughput_suite "$@" ;;
		*)
			echo "unknown suite: $suite (expected cpu|tls|imagick|throughput)" >&2
			exit 2
			;;
	esac
}

# Flattens a suite's per-target JSON into one CSV on stdout. Deliberately
# just CSV, not a bespoke table format -- pipe it into a spreadsheet,
# `column -s, -t`, or further jq/awk as needed.
#
# cpu/tls/imagick use hyperfine's --export-json schema (one file can hold
# several named commands); throughput's files are a single JSON object
# (bench/throughput/scripts/load.php's output), so it gets its own header
# and jq filter.
cmd_report() {
	local suite="$1"
	local dir="${RESULTS_DIR}/${suite}"
	if [ ! -d "$dir" ]; then
		echo "no results directory: $dir" >&2
		return 1
	fi

	local file base target_id
	if [ "$suite" = throughput ]; then
		echo "target_id,requests,errors,rps,p50_ms,p95_ms,p99_ms,rps_min,rps_max"
		for file in "$dir"/"${suite}"-*.json; do
			[ -e "$file" ] || continue
			base="$(basename "$file" .json)"
			target_id="${base#"${suite}"-}"
			jq -r --arg tid "$target_id" '
				[$tid, .median.requests, .median.errors, .median.rps, .median.p50_ms, .median.p95_ms, .median.p99_ms, .rps_min, .rps_max] | @csv
			' "$file"
		done
	else
		echo "target_id,command,mean_ms,stddev_ms,min_ms,max_ms"
		for file in "$dir"/"${suite}"-*.json; do
			[ -e "$file" ] || continue
			base="$(basename "$file" .json)"
			target_id="${base#"${suite}"-}"
			jq -r --arg tid "$target_id" '
				.results[] | [$tid, .command, (.mean*1000), (.stddev*1000), (.min*1000), (.max*1000)] | @csv
			' "$file"
		done
	fi
}

cmd_summarize() {
	"${PROJECT_DIR}/summarize.jq" "${RESULTS_DIR}"/*/*.json
}

main() {
	local command="${1:-}"
	[ -z "$command" ] && { usage; exit 1; }
	shift || true
	case "$command" in
		list) cmd_list "$@" ;;
		build-distro-pkg) cmd_build_distro_pkg "$@" ;;
		bench) cmd_bench "$@" ;;
		report) cmd_report "$@" ;;
		summarize) cmd_summarize "$@" ;;
		-h|--help|help) usage ;;
		*) echo "unknown command: $command" >&2; usage; exit 2 ;;
	esac
}

main "$@"
