#!/bin/sh
# Runs inside the target container. Times Imagick::resizeImage() against a
# pre-generated test asset (see generate-asset.sh -- generated once, on the
# host, and reused byte-for-byte across every target so no target's GD/JPEG
# encoder version can bias the input). Reproduces https://github.com/docker-library/php/issues/1100.
set -eu
cd "$(dirname "$0")"

TARGET_ID="${TARGET_ID:?TARGET_ID env var required}"
OUT_DIR="${RESULTS_DIR:-/results}"
PHP_BIN="${PHP_BIN:-php}"
ASSET="${ASSET:-assets/bench.jpg}"
mkdir -p "$OUT_DIR"

if [ ! -r "$ASSET" ]; then
	echo "missing test asset: $ASSET (run generate-asset.sh first)" >&2
	exit 1
fi

echo "Running: resize" >&2
hyperfine \
	--warmup 2 --min-runs 15 \
	--export-json "${OUT_DIR}/imagick-${TARGET_ID}.json" \
	--command-name resize "${PHP_BIN} scripts/resize.php ${ASSET} 4000 --quiet" \
	>/dev/null
php /summarize-hyperfine.php "${OUT_DIR}/imagick-${TARGET_ID}.json"
