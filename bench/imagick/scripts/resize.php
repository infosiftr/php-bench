<?php
// Reproduces the https://github.com/docker-library/php/issues/1100 report ("Very bad ImageMagick
// resizing performance with PHP 7.1 and newer in Docker"), where
// Imagick::resizeImage() was ~10x slower on some Debian-based images than
// on Alpine/PHP 7.0, root-caused there to a specific Debian-packaged
// ImageMagick version (6.9.10-23), not PHP or Docker itself.
//
// Usage: php resize.php <input.jpg> [target-size] [--quiet]

$input = $argv[1] ?? null;
$targetSize = (int) ($argv[2] ?? 4000);
$quiet = in_array('--quiet', $argv, true);

if ($input === null || !is_readable($input)) {
    fwrite(STDERR, "usage: php resize.php <input.jpg> [target-size] [--quiet]\n");
    exit(2);
}

$start = $step = microtime(true);

function bench(string $msg, bool $quiet): void {
    global $start, $step;
    $now = microtime(true);
    if (!$quiet) {
        fwrite(STDERR, number_format($now - $step, 3) . " seconds - {$msg}\n");
    }
    $step = $now;
}

$image = new Imagick();
bench('init', $quiet);

$image->readImage($input);
bench('read', $quiet);

$image->stripImage();
bench('strip', $quiet);

$image->resizeImage($targetSize, $targetSize, Imagick::FILTER_LANCZOS, 1, true);
bench('resize', $quiet);

$image->setImageCompressionQuality(85);
bench('compress', $quiet);

$image->setInterlaceScheme(Imagick::INTERLACE_JPEG);
bench('interlace', $quiet);

$blob = $image->getImageBlob();
bench('blob', $quiet);

if (!$quiet) {
    fwrite(STDERR, number_format(microtime(true) - $start, 3) . " seconds - TOTAL\n");
}
