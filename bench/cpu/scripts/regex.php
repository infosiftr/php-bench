<?php
// Regex-heavy work, representative of routing/validation/log-parsing.
$lines = [];
for ($i = 0; $i < 2000; $i++) {
    $lines[] = "127.0.0.$i - - [01/Jan/2024:00:00:00 +0000] \"GET /path/$i?x=1 HTTP/1.1\" 200 " . ($i * 7);
}

$pattern = '/^(?<ip>\d+\.\d+\.\d+\.\d+) - - \[(?<time>[^\]]+)\] "(?<method>\w+) (?<path>[^\s]+) [^"]+" (?<status>\d+) (?<size>\d+)$/';

for ($pass = 0; $pass < 30; $pass++) {
    foreach ($lines as $line) {
        preg_match($pattern, $line, $m);
        preg_replace('/\d+/', 'N', $line);
    }
}
