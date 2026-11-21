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

Which published image is the NTS build and which the ZTS build isn't written
down anywhere, because it has changed once already: 8.6 made every
`docker-library/php` tag ZTS (no `zts` variant, no NTS build; see
https://github.com/docker-library/php/issues/1719) and could change again.
`resolve_cpu_pair` in `run.sh` works it out at run time by running `php` in
the image, not by trusting tag names or version numbers. `cli` is always one
side. If it is NTS (through 8.5), the other side is the `zts` tag. If it is
ZTS (8.6), the other side is the `nts` tag *if docker-library has published
one* (checked against the registry, so one appearing is picked up
automatically; https://github.com/docker-library/php/pull/1722 proposes one,
which is open and may not land, and as described would skip `--enable-embed`,
so it wouldn't be quite our rebuild); otherwise
`ensure_nts` builds it here: it takes the published
`<version>/<os>/cli/Dockerfile` from a shallow clone of `docker-library/php`
(in `.cache/`, or your own checkout via `PHP_BENCH_DOCKER_PHP_DIR`), strips
`--enable-zts` and `--disable-zend-signals` into a scratch build context, and
builds that as `php-bench/nts:<version>-cli-<os>`. Nothing of upstream's is
copied into this repo; the build fails if the flags aren't where it expects,
or if the result's `PHP_VERSION` differs from the published ZTS image's (a
checkout ahead of or behind the published images). Every side is verified by
running it before use, so a tag that isn't what it claims fails loudly, and
the resolved threading is recorded in each cpu result file. 8.6 images also
have no `pecl`, so the imagick suite skips 8.6.

Requires Docker and git. First run of `bench imagick` renders the fixed test
image (`bench/imagick/assets/bench.jpg`) if it isn't already there.

## Layout

- `.targets.sh` -- the version/OS/SAPI matrix (plus the 8.6+ NTS rebuild
  targets).
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
  throughput. The cpu targets that make up an nts/zts pair are the exception
  to "one hyperfine run": `bench cpu` runs the two sides of each pair
  interleaved (`bench_cpu_pair` in `run.sh`) -- `CPU_ROUNDS` rounds (default 5)
  in which, workload by workload, nts and zts run back to back in alternating
  order, instead of one whole target and then the other. Comparing two means
  taken minutes apart on a shared runner mistakes the runner's own drift for a
  difference (hyperfine's stddev only sees scatter within a run), which is how
  the first 8.6 numbers had zts "measurably faster" on several workloads. Each
  such result file pools every round's `times` and also keeps a `rounds` array
  of per-round means, and `summarize.jq` judges nts-vs-zts on the paired
  per-round ratio. `CPU_ROUND_RUNS`/`CPU_ROUND_WARMUP` (defaults 10/1) set the
  timed runs and warmups per workload per round, `CPU_SLOW_ROUND_RUNS`/
  `CPU_SLOW_ROUND_WARMUP` (3/0) the same for the multi-second `hash` script.
- `summarize.jq` -- reads all of the above and prints six fixed comparisons
  (one per question above), each collapsed across PHP version with a
  spread/consistency check rather than silently averaging it away. Runnable
  directly (`./summarize.jq results/*/*.json`) or via `run.sh summarize`.
  The report leads with a plain-language answer to each of the six
  questions, and every comparison names its winner in words ("official 15%
  faster") rather than leaving a signed percentage to be interpreted.
  A winner is named only when the gap beats the uncertainty: hyperfine's
  per-benchmark `stddev` and the disagreement between PHP versions are
  both carried through the aggregation, and the gap has to clear whichever
  of the two is larger, plus a 1% floor for effects too small to act on.
  Everything else reads "too close to call". That discards more than it
  might sound like: `arrays` carries ~19% run-to-run stddev, so any
  single-digit delta on it is scatter rather than a result.
