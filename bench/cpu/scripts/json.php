<?php
// json_encode/decode of a moderately nested structure, representative of
// API request/response handling.
$record = [
    'id' => 1,
    'name' => 'widget',
    'tags' => ['a', 'b', 'c', 'd', 'e'],
    'meta' => ['created' => '2024-01-01', 'active' => true, 'score' => 3.14159],
    'children' => array_fill(0, 20, ['x' => 1, 'y' => 2, 'z' => 'value']),
];

for ($i = 0; $i < 20000; $i++) {
    $json = json_encode($record, JSON_THROW_ON_ERROR);
    $decoded = json_decode($json, true, 512, JSON_THROW_ON_ERROR);
}
