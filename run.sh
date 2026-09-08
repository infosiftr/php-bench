#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

source targets.sh

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
		if ! image_exists "$base_image"; then
			echo "+ docker pull $base_image" >&2
			docker pull "$base_image" >&2
		fi
		docker_build "$tag" "${PROJECT_DIR}/images/overlay/Dockerfile" "${PROJECT_DIR}/images/overlay" \
			"BASE_IMAGE=${base_image}" "NEED_CURL=${need_curl}" "NEED_IMAGICK=${need_imagick}" >&2
	fi
	echo "$tag"
}

usage() {
	cat <<'EOF'
Usage: run.sh <command> [args]

Commands:
  list                              Show the full target matrix
  build-distro-pkg [os...]          Build distro-pkg images (default: all)
  bench cpu     [--only PATTERN]    Run the CPU microbenchmark suite
  bench tls     [--only PATTERN]    Run the TLS/CA-verification suite
  bench imagick [--only PATTERN]    Run the Imagick resize suite
  report <suite>                    Print results/<suite>/*.json as CSV
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

# bench_script_suite SUITE NEED_CURL NEED_IMAGICK [--only PATTERN]
# Shared driver for cpu/tls/imagick: all three run one script (or a fixed
# script list) via bench/<suite>/run.sh against every CLI-official target
# plus every distro-pkg target.
bench_script_suite() {
	local suite="$1" need_curl="$2" need_imagick="$3"
	shift 3
	local only=""
	if [ "${1:-}" = "--only" ]; then
		only="$2"
	fi

	local line id image version os sapi label overlay
	list_cpu_style_official_targets | while IFS='|' read -r id image version os sapi label; do
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

cmd_bench() {
	local suite="$1"
	shift
	case "$suite" in
		cpu) bench_script_suite cpu 0 0 "$@" ;;
		tls) bench_script_suite tls 1 0 "$@" ;;
		imagick)
			if [ ! -f "${PROJECT_DIR}/bench/imagick/assets/bench.jpg" ]; then
				bash "${PROJECT_DIR}/bench/imagick/generate-asset.sh"
			fi
			bench_script_suite imagick 0 1 "$@"
			;;
		*)
			echo "unknown suite: $suite (expected cpu|tls|imagick)" >&2
			exit 2
			;;
	esac
}

# Flattens hyperfine's --export-json output across all targets in a suite
# into one CSV on stdout (target_id,command,mean_ms,stddev_ms,min_ms,max_ms).
# Deliberately just CSV, not a bespoke table format -- pipe it into a
# spreadsheet, `column -s, -t`, or further jq/awk as needed.
cmd_report() {
	local suite="$1"
	local dir="${RESULTS_DIR}/${suite}"
	if [ ! -d "$dir" ]; then
		echo "no results directory: $dir" >&2
		return 1
	fi

	echo "target_id,command,mean_ms,stddev_ms,min_ms,max_ms"
	local file base target_id
	for file in "$dir"/"${suite}"-*.json; do
		[ -e "$file" ] || continue
		base="$(basename "$file" .json)"
		target_id="${base#"${suite}"-}"
		jq -r --arg tid "$target_id" '
			.results[] | [$tid, .command, (.mean*1000), (.stddev*1000), (.min*1000), (.max*1000)] | @csv
		' "$file"
	done
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
		-h|--help|help) usage ;;
		*) echo "unknown command: $command" >&2; usage; exit 2 ;;
	esac
}

main "$@"
