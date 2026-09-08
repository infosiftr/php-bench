<?php
// Generates a synthetic photo-like JPEG to resize-benchmark against, so the
// suite doesn't depend on fetching/vendoring an external test asset (the
// original https://github.com/docker-library/php/issues/1100 report used a real photo:
// https://github.com/docker-library/php/files/5654195/imgbench.zip).
//
// Plain noise compresses far better (and resizes faster) than a real photo,
// so we layer gradients + shapes + per-pixel noise to get something with
// realistic entropy for JPEG/ImageMagick purposes.
//
// Usage: php generate-image.php <output.jpg> [width] [height]

$out = $argv[1] ?? 'bench.jpg';
$width = (int) ($argv[2] ?? 4000);
$height = (int) ($argv[3] ?? 3000);

$im = imagecreatetruecolor($width, $height);

// Gradient background.
for ($y = 0; $y < $height; $y++) {
    $r = (int) (255 * $y / $height);
    $color = imagecolorallocate($im, $r, 128, 255 - $r);
    imageline($im, 0, $y, $width, $y, $color);
}

// Scattered shapes for edges/detail (stresses resampling filters more than
// a flat gradient would).
mt_srand(42); // reproducible across runs/hosts
for ($i = 0; $i < 400; $i++) {
    $color = imagecolorallocate($im, mt_rand(0, 255), mt_rand(0, 255), mt_rand(0, 255));
    $x = mt_rand(0, $width);
    $y = mt_rand(0, $height);
    $r = mt_rand(10, 150);
    imagefilledellipse($im, $x, $y, $r, $r, $color);
}

// Per-pixel noise on a subsample grid (full per-pixel would be far too slow
// to *generate*; this is only setup cost, not part of the timed benchmark).
for ($y = 0; $y < $height; $y += 3) {
    for ($x = 0; $x < $width; $x += 3) {
        if (mt_rand(0, 4) === 0) {
            $g = mt_rand(0, 255);
            imagesetpixel($im, $x, $y, imagecolorallocate($im, $g, $g, $g));
        }
    }
}

imagejpeg($im, $out, 90);
// No imagedestroy() call: deprecated since PHP 8.5 (a no-op since PHP 8.0 --
// GD images are refcounted objects, not resources, so it'd just warn).

fwrite(STDERR, "wrote {$out} ({$width}x{$height})\n");
