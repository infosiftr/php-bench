<?php
// No external tools required (no curl CLI, no /dev/tcp bashism) -- just
// polls with fsockopen so this works identically on dash/busybox ash.
$host = $argv[1] ?? '127.0.0.1';
$port = (int) ($argv[2] ?? 8443);

$deadline = microtime(true) + 10;
while (microtime(true) < $deadline) {
    $fp = @fsockopen($host, $port, $errno, $errstr, 0.2);
    if ($fp) {
        fclose($fp);
        exit(0);
    }
    usleep(100000);
}

fwrite(STDERR, "server on {$host}:{$port} did not come up in time\n");
exit(1);
