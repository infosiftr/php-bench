<?php
// String-heavy work representative of templating/formatting hot paths.
$out = '';
for ($i = 0; $i < 200000; $i++) {
    $s = sprintf('user-%d-%s', $i, md5((string) $i));
    $s = str_replace('user-', 'u_', $s);
    $s = strtoupper(substr($s, 0, 10)) . strtolower(substr($s, 10));
    $out = $s; // keep the optimizer honest without accumulating memory
}
