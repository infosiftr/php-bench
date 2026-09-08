<?php
// Minimal endpoint for the apache(mod_php)/fpm concurrency-model comparison
// (https://github.com/docker-library/php/issues/681 and
// https://github.com/docker-library/php/issues/742). Deliberately does a small, fixed amount
// of real PHP work per request rather than serving a static "hello world" --
// worker/threading-model differences under concurrent load show up in how
// that per-request work gets scheduled, not in raw static-file throughput.

$items = [];
for ($i = 0; $i < 200; $i++) {
    $items[] = [
        'id' => $i,
        'hash' => hash('sha256', 'item-' . $i),
        'label' => strtoupper(substr(md5((string) $i), 0, 8)),
    ];
}

header('Content-Type: application/json');
echo json_encode([
    'pid' => getmypid(),
    'sapi' => PHP_SAPI,
    'items' => $items,
], JSON_THROW_ON_ERROR);
