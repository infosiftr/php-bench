<?php
// Repeated fresh-handle HTTPS requests to a local TLS endpoint, to isolate
// the cost of CA-bundle loading/parsing during certificate verification --
// the leading (never-confirmed) theory for the "30-40% CPU usage increase
// with 8.2.8-bookworm" regression, https://github.com/docker-library/php/issues/1431 (attributed
// there to the OpenSSL 1.1 -> 3.x change: https://github.com/openssl/openssl/issues/16871).
//
// Usage: php curl-loop.php <verify|noverify> [host] [port] [iterations]
//
// A fresh curl handle per iteration is deliberate: it mirrors a typical
// short-lived FPM worker doing one outbound request per web request, which
// is the pattern that would actually pay a per-request CA-parse cost
// instead of amortizing it across a long-lived process/handle.

$mode = $argv[1] ?? 'verify';
$host = $argv[2] ?? '127.0.0.1';
$port = (int) ($argv[3] ?? 8443);
$iterations = (int) ($argv[4] ?? 60);

if (!in_array($mode, ['verify', 'noverify'], true)) {
    fwrite(STDERR, "usage: php curl-loop.php <verify|noverify> [host] [port] [iterations]\n");
    exit(2);
}

$verify = $mode === 'verify';

// The whole point of "verify" mode is to force curl/OpenSSL to load and
// walk the *full* system CA bundle during the handshake, same as a normal
// outbound HTTPS call in an application would. The target cert is
// self-signed, so verification is expected to fail either way -- OpenSSL
// pays the bundle-parsing cost as part of the handshake's verify callback
// regardless of the eventual accept/reject outcome.
$caBundleCandidates = [
    '/etc/ssl/certs/ca-certificates.crt', // Debian/Alpine
    '/etc/pki/tls/certs/ca-bundle.crt',   // RHEL-family, just in case
];
$caBundle = null;
foreach ($caBundleCandidates as $candidate) {
    if (is_readable($candidate)) {
        $caBundle = $candidate;
        break;
    }
}
if ($verify && $caBundle === null) {
    fwrite(STDERR, "no system CA bundle found; can't run verify mode meaningfully\n");
    exit(1);
}

for ($i = 0; $i < $iterations; $i++) {
    $ch = curl_init("https://{$host}:{$port}/");
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_CONNECTTIMEOUT_MS => 2000,
        CURLOPT_TIMEOUT_MS => 2000,
        CURLOPT_SSL_VERIFYPEER => $verify,
        CURLOPT_SSL_VERIFYHOST => $verify ? 2 : 0,
    ]);
    if ($verify) {
        curl_setopt($ch, CURLOPT_CAINFO, $caBundle);
    }
    curl_exec($ch);
    // No curl_close() call: deprecated since PHP 8.5 (a no-op since PHP 8.0
    // -- curl handles are refcounted objects now, freed when $ch is
    // reassigned next iteration or the script ends).
}
