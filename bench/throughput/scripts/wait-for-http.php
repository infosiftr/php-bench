<?php
// Polls with a real HTTP request (not just a TCP connect) until the server
// returns 200, so the load test doesn't start counting a burst of 502s
// while fpm's socket is still coming up behind nginx.
//
// Usage: php wait-for-http.php <url> [timeout-seconds]

$url = $argv[1] ?? null;
$timeout = (float) ($argv[2] ?? 10);

if ($url === null) {
    fwrite(STDERR, "usage: php wait-for-http.php <url> [timeout-seconds]\n");
    exit(2);
}

$deadline = microtime(true) + $timeout;
while (microtime(true) < $deadline) {
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT => 2,
    ]);
    curl_exec($ch);
    if (curl_getinfo($ch, CURLINFO_HTTP_CODE) === 200) {
        exit(0);
    }
    usleep(200000);
}

fwrite(STDERR, "server at {$url} never returned 200 in time\n");
exit(1);
