<?php
// Reproduces (at a more realistic scale) the pattern reported in
// https://github.com/docker-library/php/issues/493: many require/
// require_once/include calls in a single request. The original report
// used one of each on 3 trivial files; a maintainer's own investigation
// there (hyperfine against Debian's packaged PHP, opcache on/off) found
// only a 3-6% difference, not the 10x some reporters saw -- but that was a
// one-off comment on a closed issue, not something that re-runs on every
// new PHP/distro release the way this suite does. Commenters there also
// said the effect got much worse with "a huge lot" of includes in real
// codebases (e.g. a framework's autoload burst), hence 50 files here
// rather than 3.
$statements = ['require', 'require_once', 'include'];
for ($i = 1; $i <= 50; $i++) {
    $file = sprintf(__DIR__ . '/includes/file%02d.php', $i);
    switch ($statements[$i % 3]) {
        case 'require':
            require $file;
            break;
        case 'require_once':
            require_once $file;
            break;
        case 'include':
            include $file;
            break;
    }
}
