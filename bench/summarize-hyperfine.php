<?php
// Reads a hyperfine --export-json file and prints one compact line per
// benchmark result. See run.sh's run_in_target, which mounts this and
// redirects hyperfine's own (much more verbose, multi-line-per-benchmark)
// stdout to /dev/null in favor of it. Reading the JSON hyperfine already
// writes is more robust than parsing its human-readable text would be --
// the JSON schema is a real, intentional interface (the same one
// summarize.jq and `run.sh report` already rely on), not something coupled
// to the exact wording of a pinned hyperfine version.

$file = $argv[1] ?? null;
if ($file === null || !is_readable($file)) {
    fwrite(STDERR, "usage: php summarize-hyperfine.php <export.json>\n");
    exit(2);
}

$data = json_decode(file_get_contents($file), true, 512, JSON_THROW_ON_ERROR);

foreach ($data['results'] as $r) {
    printf(
        "  %-20s %8.1f ms +/- %6.1f ms   range %8.1f - %8.1f ms  (%d runs)\n",
        $r['command'],
        $r['mean'] * 1000,
        $r['stddev'] * 1000,
        $r['min'] * 1000,
        $r['max'] * 1000,
        count($r['times'])
    );
}
