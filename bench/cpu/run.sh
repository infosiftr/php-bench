#!/bin/sh
# Runs inside the target container. Benchmarks each script under three PHP
# configs: baseline (image defaults), opcache warm (matters because
# hyperfine re-execs the same file many times -- this is the opcache path
# implicated in https://github.com/docker-library/php/issues/493), and opcache+JIT (implicated in the
# unresolved 8.2.8-bookworm CPU regression, https://github.com/docker-library/php/issues/1431).
set -eu
cd "$(dirname "$0")"

TARGET_ID="${TARGET_ID:?TARGET_ID env var required}"
OUT_DIR="${RESULTS_DIR:-/results}"
mkdir -p "$OUT_DIR"

PHP_BIN="${PHP_BIN:-php}"

set -- # reset positional args; we'll build hyperfine's argv here
ARGS="--warmup 3 --min-runs 15 --export-json ${OUT_DIR}/cpu-${TARGET_ID}.json"

for script in scripts/*.php; do
	name="$(basename "$script" .php)"
	ARGS="$ARGS --command-name ${name}:baseline \"${PHP_BIN} ${script}\""
	ARGS="$ARGS --command-name ${name}:opcache \"${PHP_BIN} -d opcache.enable_cli=1 ${script}\""
	ARGS="$ARGS --command-name ${name}:jit \"${PHP_BIN} -d opcache.enable_cli=1 -d opcache.jit=1255 -d opcache.jit_buffer_size=64M ${script}\""
done

eval hyperfine "$ARGS"
