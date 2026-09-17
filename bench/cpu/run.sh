#!/bin/sh
# Runs inside the target container. Benchmarks each script under three PHP
# configs: baseline (image defaults), opcache warm (matters because
# hyperfine re-execs the same file many times -- this is the opcache path
# implicated in https://github.com/docker-library/php/issues/493), and opcache+JIT (implicated in the
# unresolved 8.2.8-bookworm CPU regression, https://github.com/docker-library/php/issues/1431).
#
# One hyperfine invocation per command (not one for all 21 baseline/
# opcache/jit variants together) so a "Running: X" line can be printed
# right before each one starts -- otherwise there is no visible progress
# at all for the several minutes a target takes (dominated by the
# deliberately-slow hash script), only a burst of results at the very end.
set -eu
cd "$(dirname "$0")"

TARGET_ID="${TARGET_ID:?TARGET_ID env var required}"
OUT_DIR="${RESULTS_DIR:-/results}"
mkdir -p "$OUT_DIR"

PHP_BIN="${PHP_BIN:-php}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

part_files=""

for script in scripts/*.php; do
	name="$(basename "$script" .php)"

	for variant in baseline opcache jit; do
		case "$variant" in
			baseline) cmd="${PHP_BIN} ${script}" ;;
			opcache) cmd="${PHP_BIN} -d opcache.enable_cli=1 ${script}" ;;
			jit) cmd="${PHP_BIN} -d opcache.enable_cli=1 -d opcache.jit=1255 -d opcache.jit_buffer_size=64M ${script}" ;;
		esac
		label="${name}:${variant}"
		part="${TMP_DIR}/${name}_${variant}.json"

		echo "Running: ${label}" >&2
		hyperfine --warmup 3 --min-runs 15 --export-json "$part" --command-name "$label" "$cmd" >/dev/null
		php /summarize-hyperfine.php "$part"

		part_files="$part_files $part"
	done
done

# part_files is deliberately unquoted: a space-separated list of temp file
# paths we built ourselves above, safe to word-split.
php /merge-hyperfine.php "${OUT_DIR}/cpu-${TARGET_ID}.json" $part_files
