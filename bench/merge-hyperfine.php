<?php
// Merges N hyperfine --export-json files (each from a single-command
// invocation) into one combined {results: [...]} file -- the same shape
// hyperfine itself produces for a multi-command invocation, so nothing
// downstream (summarize.jq, `run.sh report`) needs to know whether a
// target's results came from one hyperfine call or many. See run.sh
// (cpu/tls), which now invoke hyperfine once per command instead of once
// per target, specifically so a "Running: X" line can be printed before
// each one starts -- see summarize-hyperfine.php for why.
//
// Usage: php merge-hyperfine.php <output.json> <input1.json> [input2.json ...]

$output = $argv[1] ?? null;
$inputs = array_slice($argv, 2);
if ($output === null || count($inputs) === 0) {
    fwrite(STDERR, "usage: php merge-hyperfine.php <output.json> <input1.json> [input2.json ...]\n");
    exit(2);
}

$results = [];
foreach ($inputs as $input) {
    $data = json_decode(file_get_contents($input), true, 512, JSON_THROW_ON_ERROR);
    foreach ($data['results'] as $r) {
        $results[] = $r;
    }
}

file_put_contents($output, json_encode(['results' => $results], JSON_PRETTY_PRINT));
