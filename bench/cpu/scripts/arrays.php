<?php
// Array construction/sort/map/filter, representative of collection-heavy
// application code.
$data = [];
for ($i = 0; $i < 100000; $i++) {
    $data[] = ($i * 2654435761) % 1000003;
}

sort($data);

$doubled = array_map(static fn ($v) => $v * 2, $data);
$even = array_filter($doubled, static fn ($v) => $v % 4 === 0);
$sum = array_sum($even);
