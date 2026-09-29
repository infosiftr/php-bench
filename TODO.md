<!-- remove from file when complete; keep a double space between TODO entries so they're more readable / digestible -->
<!-- sub-bullets (2-space indent, `-`, cuddled -- no blank line between parent and sub-bullets, nor between sibling sub-bullets) are for related side notes subordinate to the main item but distinct enough to stand alone -- use a semicolon continuation for the same thought, a sub-bullet for a related angle, and a new top-level entry for a separate concern -->

- rename "official" and "distro-pkg" to "doi" and "distro" ("DOI" and "distro package(s)" in prose, as appropriate/trivial)

- scrape supported PHP versions/variants from https://github.com/docker-library/official-images/raw/HEAD/library/php, but fail early and loudly if scraping them fails
  - make sure GHA scrapes those exactly once so they stay consistent throughout (maybe download it to a directory and set/use `BASHBREW_LIBRARY` to point to the directory like we do in many scripts elsewhere to have "default to scraping GitHub but use local files if told to do so" behavior)

- split the "benchmark" GHA from the "summary" GHA, so that we only re-run benchmarks when they actually change (or on schedule slash manual trigger)
  - does it make sense to have the "summary" job commit the summary, if it's running from our main branch?
  - does it make sense to commit the *results* somewhere?

- the results should probably embed full PHP version information / image references / host architecture data too?
  - even distro package PHP versions?  that's useful data (both the reported PHP version *and* the distro package version, probably, since the latter will often encode more useful hints like `deb13u4`)

- related to the prior, maybe we should *also* benchmark on GHA's arm workers?
