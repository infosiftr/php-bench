# php-bench

Benchmarks for the `docker-library/php` official image: our compiled PHP
vs. the same distro's own packaged PHP, across versions/OSes, targeting the
specific "PHP is slow" complaints on file there:

- CPU: https://github.com/docker-library/php/issues/493, https://github.com/docker-library/php/issues/1431
- Imagick resize: https://github.com/docker-library/php/issues/1100
- TLS/CA-verification cost: https://github.com/docker-library/php/issues/1431
- apache vs fpm throughput: https://github.com/docker-library/php/issues/681
  (mpm_event, discussed in https://github.com/docker-library/php/issues/742,
  isn't one of the modes -- the official apache image is NTS and Apache
  refuses to load it under a threaded MPM; see targets.sh)

## Use

```
./run.sh list                  # show the target matrix
./run.sh bench cpu             # or tls, imagick, throughput
./run.sh bench cpu --only 8.4  # filter targets by substring
./run.sh report cpu            # results/cpu/*.json -> CSV on stdout
```

Requires Docker. First run of `bench imagick` renders the fixed test image
(`bench/imagick/assets/bench.jpg`) if it isn't already there.

## Layout

- `targets.sh` -- the version/OS/SAPI matrix.
- `images/` -- Dockerfiles: `debian-pkg`/`alpine-pkg` (vanilla distro + its
  own packaged PHP), `overlay` (adds hyperfine, and curl/imagick compiled
  against *our* PHP when needed), `asset-gen` (one-off, for the Imagick
  test image).
- `bench/<suite>/` -- the PHP scripts being timed. cpu/tls/imagick each have
  a `run.sh` that hyperfine-invokes them inside the target container;
  throughput is multi-container (server + nginx/fpm + a curl_multi load
  driver), so its orchestration lives in `run.sh` at the repo root instead.
- `results/<suite>/*.json` -- one file per target: hyperfine's
  `--export-json` output for cpu/tls/imagick, `load.php`'s own JSON for
  throughput.
