<?php
// Fixed-duration, fixed-concurrency HTTP load driver using curl_multi, so
// this suite doesn't need an external tool (hey/wrk/ab) -- consistent with
// the rest of this project depending on nothing but PHP + hyperfine.
//
// Usage: php load.php <url> [concurrency] [duration-seconds]

$url = $argv[1] ?? null;
$concurrency = (int) ($argv[2] ?? 20);
$durationSeconds = (float) ($argv[3] ?? 8);

if ($url === null) {
    fwrite(STDERR, "usage: php load.php <url> [concurrency] [duration-seconds]\n");
    exit(2);
}

function startRequest($multi, string $url, array &$startTimes): void {
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT => 5,
    ]);
    curl_multi_add_handle($multi, $ch);
    $startTimes[spl_object_id($ch)] = microtime(true);
}

$multi = curl_multi_init();
$startTimes = [];
$latenciesMs = [];
$errors = 0;
$completed = 0;
$refilling = true;
$active = 0;

$started = microtime(true);
$stopAt = $started + $durationSeconds;

for ($i = 0; $i < $concurrency; $i++) {
    startRequest($multi, $url, $startTimes);
}

do {
    do {
        $status = curl_multi_exec($multi, $active);
    } while ($status === CURLM_CALL_MULTI_PERFORM);

    while ($info = curl_multi_info_read($multi)) {
        $ch = $info['handle'];
        $id = spl_object_id($ch);
        $elapsedMs = (microtime(true) - $startTimes[$id]) * 1000;
        unset($startTimes[$id]);
        $completed++;

        if ($info['result'] === CURLE_OK && curl_getinfo($ch, CURLINFO_HTTP_CODE) === 200) {
            $latenciesMs[] = $elapsedMs;
        } else {
            $errors++;
        }

        curl_multi_remove_handle($multi, $ch);

        if ($refilling) {
            startRequest($multi, $url, $startTimes);
        }
    }

    if (microtime(true) >= $stopAt) {
        $refilling = false;
    }

    if ($active) {
        curl_multi_select($multi, 0.1);
    }
} while ($active || $refilling);

sort($latenciesMs);
$n = count($latenciesMs);
$percentile = static function (float $p) use ($latenciesMs, $n): float {
    if ($n === 0) {
        return 0.0;
    }
    return $latenciesMs[(int) floor($p * ($n - 1))];
};

$totalTime = microtime(true) - $started;

echo json_encode([
    'requests' => $completed,
    'errors' => $errors,
    'duration_s' => round($totalTime, 3),
    'rps' => $totalTime > 0 ? round($completed / $totalTime, 2) : 0,
    'p50_ms' => round($percentile(0.50), 2),
    'p95_ms' => round($percentile(0.95), 2),
    'p99_ms' => round($percentile(0.99), 2),
], JSON_PRETTY_PRINT) . "\n";
