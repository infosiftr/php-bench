<?php
// Hashing: cheap sha256 in bulk (session tokens, ETags, ...) plus a small
// number of bcrypt password_hash calls (auth hot path; deliberately few
// iterations since bcrypt is intentionally expensive per call).
for ($i = 0; $i < 200000; $i++) {
    hash('sha256', 'payload-' . $i);
}

for ($i = 0; $i < 30; $i++) {
    $hash = password_hash('correct horse battery staple ' . $i, PASSWORD_BCRYPT, ['cost' => 10]);
    password_verify('correct horse battery staple ' . $i, $hash);
}
