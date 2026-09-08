#!/usr/bin/env bash
# Renders bench/imagick/assets/bench.jpg -- the fixed input every Imagick
# target resizes (see bench/imagick/run.sh). Run this deliberately, not as
# part of every benchmark invocation.
#
# Provenance / how it's made: bench/imagick/scripts/generate-image.php,
# executed here inside a one-off GD-enabled image (images/asset-gen) that
# is otherwise unrelated to the benchmark matrix. GD (not a real photo) is
# used so the suite doesn't need to fetch/vendor an external asset -- see
# that script for how the synthetic image is constructed.
#
# Requirements the asset must meet: large enough and detailed enough that
# Imagick::resizeImage() does real, measurable work (the original report at
# https://github.com/docker-library/php/issues/1100 used a ~2MB real photo
# resized to 4000x4000); a JPEG, since that's what the reports were about.
#
# Should it be committed? Yes. This script is deliberately idempotent (it
# no-ops if the file already exists) precisely so that, once generated and
# committed, `bench.jpg` is a fixed, version-controlled input -- every
# target resizes byte-identical data forever after, not a freshly rendered
# image whose exact bytes (and therefore exact resize cost) could shift
# with GD/libjpeg version drift in images/asset-gen. Comparisons across
# targets (and across time, if you re-run this suite months apart) are
# only meaningful if the input never changed out from under them.
#
# If you ever do need to regenerate it (e.g. deliberately changing the
# image size/content): run with FORCE=1, and treat it as a breaking change
# to this benchmark -- old results and new results are no longer
# comparable, so say so explicitly in whatever commit changes the asset.
set -Eeuo pipefail
cd "$(dirname "$0")/../.."

ASSET_DIR="bench/imagick/assets"
ASSET="${ASSET_DIR}/bench.jpg"

if [[ -f "$ASSET" && "${FORCE:-0}" != "1" ]]; then
	echo "already exists: ${ASSET} (set FORCE=1 to regenerate)" >&2
	exit 0
fi

mkdir -p "$ASSET_DIR"

docker build -t php-bench/asset-gen -f images/asset-gen/Dockerfile images/asset-gen

docker run --rm \
	-v "$PWD/bench/imagick/scripts:/scripts:ro" \
	-v "$PWD/${ASSET_DIR}:/out" \
	php-bench/asset-gen \
	php /scripts/generate-image.php /out/bench.jpg 4000 3000

echo "wrote ${ASSET}" >&2
