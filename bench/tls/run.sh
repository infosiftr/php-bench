#!/bin/sh
# Runs inside the target container. Starts a local self-signed TLS endpoint
# (openssl s_server -www, which speaks just enough HTTP to answer real
# requests) and times PHP curl requests against it with and without
# certificate verification, to isolate CA-bundle load/parse cost per
# request -- see bench/tls/scripts/curl-loop.php for why this matters
# (https://github.com/docker-library/php/issues/1431).
set -eu
cd "$(dirname "$0")"

TARGET_ID="${TARGET_ID:?TARGET_ID env var required}"
OUT_DIR="${RESULTS_DIR:-/results}"
PHP_BIN="${PHP_BIN:-php}"
mkdir -p "$OUT_DIR"

CERT_DIR="$(mktemp -d)"
TMP_DIR="$(mktemp -d)"
openssl req -x509 -newkey rsa:2048 -nodes \
	-keyout "${CERT_DIR}/key.pem" -out "${CERT_DIR}/cert.pem" \
	-days 1 -subj /CN=localhost 2>/dev/null

openssl s_server -accept 8443 -cert "${CERT_DIR}/cert.pem" -key "${CERT_DIR}/key.pem" -www -quiet &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$TMP_DIR"' EXIT

"${PHP_BIN}" scripts/wait-for-port.php 127.0.0.1 8443

# One hyperfine invocation per command -- see bench/cpu/run.sh's comment
# for why (a live "Running: X" line before each one starts).
part_files=""
for mode in verify noverify; do
	part="${TMP_DIR}/${mode}.json"
	echo "Running: ${mode}" >&2
	hyperfine --warmup 3 --min-runs 15 --export-json "$part" \
		--command-name "$mode" "${PHP_BIN} scripts/curl-loop.php ${mode} 127.0.0.1 8443 60" >/dev/null
	php /summarize-hyperfine.php "$part"
	part_files="$part_files $part"
done

# part_files is deliberately unquoted -- see bench/cpu/run.sh.
php /merge-hyperfine.php "${OUT_DIR}/tls-${TARGET_ID}.json" $part_files
