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
  refuses to load it under a threaded MPM; see .targets.sh)

## Use

```
./run.sh list                  # show the target matrix
./run.sh ensure-images         # build/pull every image up front (its own step in CI)
./run.sh bench cpu             # or tls, imagick, throughput
./run.sh bench cpu --only 8.4  # filter targets by substring
./run.sh report cpu            # results/cpu/*.json -> CSV on stdout
./run.sh summarize             # fixed comparisons + version-consistency checks
```

`--pull[=never|missing|always]` and `--build[=never|missing|always]` are global
flags (valid anywhere in argv, for any command, e.g. `run.sh bench cpu --pull`)
controlling whether third-party base images and our own overlay/distro-pkg
images get refreshed or trusted as-is; a bare `--pull`/`--build` means
`always`. Also settable via `PHP_BENCH_PULL_POLICY`/`PHP_BENCH_BUILD_POLICY`
in the environment. They default differently, on purpose: `--pull` defaults
to `missing`, since `docker pull` is a mandatory registry round-trip on
*every* call (even when already current) multiplied across dozens of
targets, for freshness we rarely need mid-session. `--build` defaults to
`always`, since `docker build` has a real local cache-hit path (near-free
once warm) and it's the only thing that catches *our own* Dockerfile changes
-- editing `install-imagick.sh` doesn't touch any base tag, so `--pull`
alone would never rebuild the overlay that actually needs it. See
`PULL_POLICY`'s comment in `run.sh` for the full reasoning.

Requires Docker. First run of `bench imagick` renders the fixed test image
(`bench/imagick/assets/bench.jpg`) if it isn't already there.

## Layout

- `.targets.sh` -- the version/OS/SAPI matrix.
- `images/` -- Dockerfiles: `debian-pkg`/`alpine-pkg` (vanilla distro + its
  own packaged PHP), `overlay` (adds hyperfine, and curl/imagick compiled
  against *our* PHP when needed), `asset-gen` (one-off, for the Imagick
  test image).
- `bench/<suite>/` -- the PHP scripts being timed. cpu/tls/imagick each have
  a `run.sh` that hyperfine-invokes them inside the target container,
  redirecting hyperfine's own verbose per-benchmark output and printing a
  compact one-line-per-result summary instead via `bench/summarize-hyperfine.php`
  (reads the same `--export-json` file, rather than parsing hyperfine's
  human-readable text); throughput is multi-container (server + nginx/fpm +
  a curl_multi load driver), so its orchestration lives in `run.sh` at the
  repo root instead.
- `results/<suite>/*.json` -- one file per target: hyperfine's
  `--export-json` output for cpu/tls/imagick, `load.php`'s own JSON for
  throughput.
- `summarize.jq` -- reads all of the above and prints six fixed comparisons
  (one per question above), each collapsed across PHP version with a
  spread/consistency check rather than silently averaging it away. Runnable
  directly (`./summarize.jq results/*/*.json`) or via `run.sh summarize`.
