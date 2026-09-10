#!/usr/bin/env -S jq -n -r -f
# Reads results/<suite>/<suite>-<target_id>.json files (pass them as
# arguments, e.g. `./summarize.jq results/*/*.json`) and prints a handful
# of fixed comparisons -- one per question this project was actually built
# to answer -- rather than a generic dump of every number. run.sh report
# <suite> still gets you the raw flattened CSV for anything this doesn't
# cover.
#
# Not wired into run.sh: that script runs benchmarks, this one only reads
# results that already exist. All of it -- multi-file reading, filename
# parsing, grouping -- is plain jq (input_filename/inputs, split/sub,
# group_by); no shell loop or repeated `echo | jq` round trip anywhere.
#
# `inputs` is one stateful stream over every file given on the command
# line, so it can only be drained once for the whole program -- all_raw
# below is called exactly once, and every report_* function takes its
# records as an argument instead of reading input itself.

# ---------- filename/target_id parsing ----------

def suite_of($path): $path | split("/") | .[-2];

def target_id_of($path; $suite):
	$path | split("/") | .[-1] | sub("\\.json$"; "") | sub("^" + $suite + "-"; "");

# "official-8.2-cli-bookworm" -> {kind,version,sapi,os}; "distro-pkg-bookworm" -> distro-pkg has no version/sapi
def parse_official_id($id):
	($id | split("-")) as $p
	| if $p[0] == "official" then
		{kind: "official", version: $p[1], sapi: $p[2], os: $p[3]}
	else
		{kind: "distro-pkg", version: null, sapi: null, os: $p[2]}
	end;

# "8.2-bookworm-apache-prefork" -> {version,os,mode} (mode can itself contain a hyphen)
def parse_throughput_id($id):
	($id | split("-")) as $p
	| {version: $p[0], os: $p[1], mode: ($p[2:] | join("-"))};

# ---------- single pass over every input file ----------

def all_raw:
	inputs as $doc
	| input_filename as $path
	| suite_of($path) as $suite
	| target_id_of($path; $suite) as $tid
	| if $suite == "cpu" then
		parse_official_id($tid) as $t
		| $doc.results[]
		| $t + {suite: $suite, script: (.command | split(":")[0]), variant: (.command | split(":")[1]), mean_ms: (.mean * 1000)}
	elif $suite == "tls" then
		parse_official_id($tid) as $t
		| $doc.results[]
		| $t + {suite: $suite, command: .command, mean_ms: (.mean * 1000)}
	elif $suite == "imagick" then
		parse_official_id($tid) as $t
		| $doc.results[]
		| $t + {suite: $suite, mean_ms: (.mean * 1000)}
	elif $suite == "throughput" then
		parse_throughput_id($tid | ltrimstr("throughput-")) as $t
		| $t + {suite: $suite, rps: $doc.median.rps, p50_ms: $doc.median.p50_ms, p95_ms: $doc.median.p95_ms, p99_ms: $doc.median.p99_ms}
	else
		empty
	end;

# ---------- tiny table formatter (column -t, in jq) ----------

# is_numeric_str is used to right-align numeric columns ("---:") and
# left-align everything else, auto-detected per column rather than
# declared by each call site.
def is_numeric_str: test("^-?[0-9]+(\\.[0-9]+)?$");

# table($headers; $rows) -> a GitHub-flavored markdown table, suitable for
# pasting straight into a $GITHUB_STEP_SUMMARY. Adapted from the
# markdown_table def in ../containerd-snapshotter-tarfs/e2e-tests.jq.
def table($headers; $rows):
	($headers | length) as $ncols
	| ([range(0; $ncols)] | map(. as $i | if ($rows | all(.[$i] | tostring | is_numeric_str)) then "---:" else "---" end)) as $aligns
	| ([$headers] + [$aligns] + $rows)
	| map(map(tostring | gsub("\\|"; "\\|")))
	| (transpose | map(map(length) | max)) as $widths
	| map(
		[$widths, $aligns, .] | transpose
		| map(.[0] as $w | .[1] as $align | (.[2] // "") as $cell
			| (" " * ([$w - ($cell | length), 0] | max)) as $fill
			| if $align == "---:" then $fill + $cell else $cell + $fill end)
		| "| " + join(" | ") + " |"
	)
	| join("\n");

def heading($title): "## " + $title;

# ---------- six comparisons ----------

def report_cpu_official_vs_distro($recs):
	heading("CPU: official vs distro-pkg (baseline, cli only) -- https://github.com/docker-library/php/issues/493"),
	(
		[$recs[] | select(.variant == "baseline") | select(.kind == "distro-pkg" or .sapi == "cli")]
		| group_by([.os, .script, .kind, .version])
		| map({os: .[0].os, script: .[0].script, kind: .[0].kind, version: .[0].version,
		       mean_ms: (map(.mean_ms) | add / length)})
		| group_by([.os, .script])
		| map(
			(map(select(.kind == "official")) | map(.mean_ms)) as $off_vms
			| {
				os: .[0].os, script: .[0].script,
				official_ms: ($off_vms | add / length),
				official_range_pct: (if ($off_vms | length) > 1
					then (($off_vms | max) - ($off_vms | min)) / ($off_vms | add / length) * 100
					else 0 end),
				distro_pkg_ms: (map(select(.kind == "distro-pkg")) | map(.mean_ms) | add / length)
			}
		)
		| map(. + {delta_pct: ((.official_ms - .distro_pkg_ms) / .distro_pkg_ms * 100)})
		| sort_by(.os, .script)
	) as $rows
	| table(["os", "script", "official_ms", "official_range_pct", "distro_pkg_ms", "delta_pct"];
		[$rows[] | [.os, .script, (.official_ms | round), (.official_range_pct | round), (.distro_pkg_ms | round), (.delta_pct | round)]]),
	"> official faster in \([$rows[] | select(.delta_pct < 0)] | length)/\($rows | length), "
		+ "distro-pkg faster in \([$rows[] | select(.delta_pct > 0)] | length)/\($rows | length) (os x script pairs)",
	([$rows[] | select(.official_range_pct > 15)]) as $inconsistent
	| if ($inconsistent | length) > 0 then
		"> official_range_pct > 15% (versions disagree, mean may be misleading): "
			+ ($inconsistent | map("\(.os)/\(.script) (\(.official_range_pct | round)%)") | join(", "))
	else
		"> official_range_pct stays under 15% everywhere; the 4 PHP versions agree closely"
	end;

def report_cpu_cli_vs_zts($recs):
	heading("CPU: cli vs zts -- https://github.com/docker-library/php/issues/742"),
	(
		[$recs[] | select(.sapi == "cli" or .sapi == "zts")]
		| group_by([.script, .variant, .version])
		| map({script: .[0].script, variant: .[0].variant, version: .[0].version,
		       cli_ms: (map(select(.sapi == "cli")) | map(.mean_ms) | add / length),
		       zts_ms: (map(select(.sapi == "zts")) | map(.mean_ms) | add / length)})
		| map(. + {delta_pct: ((.zts_ms - .cli_ms) / .cli_ms * 100)})
		| group_by([.script, .variant])
		| map({
			script: .[0].script, variant: .[0].variant,
			cli_ms: (map(.cli_ms) | add / length),
			zts_ms: (map(.zts_ms) | add / length),
			delta_pct: (map(.delta_pct) | add / length),
			delta_pct_min: (map(.delta_pct) | min),
			delta_pct_max: (map(.delta_pct) | max),
			by_version: (map({version, delta_pct}) | sort_by(.version))
		})
		| sort_by(.script, .variant)
	) as $rows
	| table(["script", "variant", "cli_ms", "zts_ms", "delta_pct", "delta_pct_min", "delta_pct_max"];
		[$rows[] | [.script, .variant, (.cli_ms | round), (.zts_ms | round), (.delta_pct | round), (.delta_pct_min | round), (.delta_pct_max | round)]]),
	([$rows[] | select(.delta_pct > 8)]) as $notable
	| ([$rows[] | select((.delta_pct_max - .delta_pct_min) > 15)]) as $inconsistent
	| (if ($notable | length) > 0 then
		"> notable zts cost (>8% avg): "
			+ ($notable | map("\(.script):\(.variant) (+\(.delta_pct | round)%, range \(.delta_pct_min | round)-\(.delta_pct_max | round)%)") | join(", "))
	else
		"> no zts delta over 8% anywhere; differences are noise-level"
	end),
	(if ($inconsistent | length) > 0 then
		"> versions disagree by >15 points on: "
			+ ($inconsistent | map("\(.script):\(.variant) (" + (.by_version | map("\(.version): \(.delta_pct | round)%") | join(", ")) + ")") | join("; "))
	else empty end);

def report_cpu_opcache_jit($recs):
	heading("CPU: opcache/JIT effect (official cli) -- JIT itself changed across 8.2-8.5, so this section is most likely to hide a version-specific story"),
	(
		[$recs[] | select(.kind == "official" and .sapi == "cli")]
		| group_by([.script, .version])
		| map({script: .[0].script, version: .[0].version,
		       baseline_ms: (map(select(.variant == "baseline")) | map(.mean_ms) | add / length),
		       opcache_ms: (map(select(.variant == "opcache")) | map(.mean_ms) | add / length),
		       jit_ms: (map(select(.variant == "jit")) | map(.mean_ms) | add / length)})
		| map(. + {
			opcache_delta_pct: ((.opcache_ms - .baseline_ms) / .baseline_ms * 100),
			jit_delta_pct: ((.jit_ms - .baseline_ms) / .baseline_ms * 100)
		})
		| group_by(.script)
		| map({
			script: .[0].script,
			baseline_ms: (map(.baseline_ms) | add / length),
			opcache_ms: (map(.opcache_ms) | add / length),
			jit_ms: (map(.jit_ms) | add / length),
			opcache_delta_pct: (map(.opcache_delta_pct) | add / length),
			jit_delta_pct: (map(.jit_delta_pct) | add / length),
			jit_delta_pct_min: (map(.jit_delta_pct) | min),
			jit_delta_pct_max: (map(.jit_delta_pct) | max),
			by_version: (map({version, jit_delta_pct}) | sort_by(.version))
		})
		| sort_by(.script)
	) as $rows
	| table(["script", "baseline_ms", "opcache_ms", "jit_ms", "opcache_delta_pct", "jit_delta_pct", "jit_delta_pct_min", "jit_delta_pct_max"];
		[$rows[] | [.script, (.baseline_ms | round), (.opcache_ms | round), (.jit_ms | round), (.opcache_delta_pct | round), (.jit_delta_pct | round), (.jit_delta_pct_min | round), (.jit_delta_pct_max | round)]]),
	([$rows[] | select(.jit_delta_pct < -10)]) as $helped
	| ([$rows[] | select(.opcache_delta_pct > 5)]) as $hurt
	| ([$rows[] | select((.jit_delta_pct_max - .jit_delta_pct_min) > 15)]) as $inconsistent
	| "> JIT >10% faster on: " + (if ($helped | length) > 0 then ($helped | map(.script) | join(", ")) else "(none)" end)
		+ " | opcache >5% slower on: " + (if ($hurt | length) > 0 then ($hurt | map(.script) | join(", ")) else "(none)" end),
	(if ($inconsistent | length) > 0 then
		"> JIT effect varies >15 points across versions on: "
			+ ($inconsistent | map("\(.script) (" + (.by_version | map("\(.version): \(.jit_delta_pct | round)%") | join(", ")) + ")") | join("; "))
	else
		"> JIT effect is consistent across all 4 versions everywhere"
	end);

def report_tls($recs):
	heading("TLS: verify cost by OS -- https://github.com/docker-library/php/issues/1431"),
	(
		$recs
		| group_by([.os, .kind, .version])
		| map({os: .[0].os, kind: .[0].kind, version: .[0].version,
		       verify_ms: (map(select(.command == "verify")) | map(.mean_ms) | add / length),
		       noverify_ms: (map(select(.command == "noverify")) | map(.mean_ms) | add / length)})
		| map(. + {overhead_x: (.verify_ms / .noverify_ms)})
		| group_by(.os)
		| map({
			os: .[0].os,
			verify_ms: (map(.verify_ms) | add / length),
			noverify_ms: (map(.noverify_ms) | add / length),
			overhead_x: (map(.overhead_x) | add / length),
			overhead_x_min: (map(.overhead_x) | min),
			overhead_x_max: (map(.overhead_x) | max)
		})
		| sort_by(.os)
	) as $rows
	| table(["os", "verify_ms", "noverify_ms", "overhead_x", "overhead_x_min", "overhead_x_max"];
		[$rows[] | [.os, (.verify_ms | round), (.noverify_ms | round), (.overhead_x * 100 | round / 100), (.overhead_x_min * 100 | round / 100), (.overhead_x_max * 100 | round / 100)]]),
	(($rows | sort_by(-.overhead_x) | .[0]) as $worst
	| ($rows | sort_by(.overhead_x) | .[0]) as $best
	| "> \($worst.os) has the worst verify overhead (\($worst.overhead_x * 100 | round / 100)x), "
		+ "\($best.os) the best (\($best.overhead_x * 100 | round / 100)x)"),
	([$rows[] | select((.overhead_x_max / .overhead_x_min) > 1.5)]) as $inconsistent
	| if ($inconsistent | length) > 0 then
		"> version/kind spread exceeds 1.5x on: "
			+ ($inconsistent | map("\(.os) (\(.overhead_x_min * 100 | round / 100)x-\(.overhead_x_max * 100 | round / 100)x)") | join(", "))
	else
		"> versions and distro-pkg agree closely within each OS"
	end;

def report_imagick($recs):
	heading("Imagick: resize by OS/kind -- https://github.com/docker-library/php/issues/1100"),
	(($recs | map(.mean_ms) | sort) as $all | $all[($all | length / 2 | floor)]) as $median
	| (
		$recs
		| group_by([.os, .kind, .version])
		| map({os: .[0].os, kind: .[0].kind, version: .[0].version, mean_ms: (map(.mean_ms) | add / length)})
		| group_by([.os, .kind])
		| map({
			os: .[0].os, kind: .[0].kind,
			mean_ms: (map(.mean_ms) | add / length),
			range_pct: (if length > 1
				then ((map(.mean_ms) | max) - (map(.mean_ms) | min)) / (map(.mean_ms) | add / length) * 100
				else 0 end)
		})
		| map(. + {outlier: (.mean_ms > ($median * 3))})
		| sort_by(.os, .kind)
	) as $rows
	| table(["os", "kind", "mean_ms", "range_pct", "outlier"];
		[$rows[] | [.os, .kind, (.mean_ms | round), (.range_pct | round), .outlier]]),
	([$rows[] | select(.outlier)]) as $flagged
	| ([$rows[] | select(.range_pct > 15)]) as $inconsistent
	| (if ($flagged | length) > 0 then
		"> \($flagged | length) outlier(s) flagged (>3x matrix median): " + ($flagged | map("\(.os)/\(.kind)") | join(", "))
	else
		"> no outliers; resize regression from #1100 stays fixed"
	end),
	(if ($inconsistent | length) > 0 then
		"> version spread exceeds 15% on: " + ($inconsistent | map("\(.os)/\(.kind) (\(.range_pct | round)%)") | join(", "))
	else
		"> versions agree within 15% everywhere official has 4 of them"
	end);

def report_throughput($recs):
	heading("Throughput: apache-prefork vs fpm-nginx -- https://github.com/docker-library/php/issues/681"),
	(
		$recs
		| group_by([.mode, .version])
		| map({mode: .[0].mode, version: .[0].version,
		       rps: (map(.rps) | add / length), p50_ms: (map(.p50_ms) | add / length),
		       p95_ms: (map(.p95_ms) | add / length), p99_ms: (map(.p99_ms) | add / length)})
		| group_by(.mode)
		| map({
			mode: .[0].mode,
			rps: (map(.rps) | add / length),
			rps_range_pct: (((map(.rps) | max) - (map(.rps) | min)) / (map(.rps) | add / length) * 100),
			p50_ms: (map(.p50_ms) | add / length),
			p95_ms: (map(.p95_ms) | add / length),
			p99_ms: (map(.p99_ms) | add / length)
		})
	) as $means
	| table(["mode", "rps", "rps_range_pct", "p50_ms", "p95_ms", "p99_ms"];
		[$means[] | [.mode, (.rps | round), (.rps_range_pct | round), (.p50_ms * 100 | round / 100), (.p95_ms * 100 | round / 100), (.p99_ms * 100 | round / 100)]]),
	(
		$recs
		| group_by([.version, .os])
		| map({apache: (map(select(.mode == "apache-prefork")) | .[0]), fpm: (map(select(.mode == "fpm-nginx")) | .[0])})
	) as $pairs
	| "> fpm-nginx wins rps in \([$pairs[] | select(.fpm.rps > .apache.rps)] | length)/\($pairs | length) version×os pairs, "
		+ "p50 in \([$pairs[] | select(.fpm.p50_ms < .apache.p50_ms)] | length)/\($pairs | length), "
		+ "p95 in \([$pairs[] | select(.fpm.p95_ms < .apache.p95_ms)] | length)/\($pairs | length), "
		+ "p99 in \([$pairs[] | select(.fpm.p99_ms < .apache.p99_ms)] | length)/\($pairs | length)";

# ---------- single pass, then dispatch ----------
#
# Every report_* is a stream of markdown blocks (a heading, a table, one or
# two "> " takeaway lines); [ ... ] flattens all six streams into one array
# of blocks, and join("\n\n") gives each block its own blank-line-separated
# paragraph -- valid GitHub-flavored markdown, pastable straight into
# $GITHUB_STEP_SUMMARY.

# run(f; $recs) -> f applied to $recs, or nothing at all if $recs is empty
# (a suite that never ran or produced no files -- e.g. it failed in CI
# while others succeeded -- shouldn't crash the rest of the report). f is a
# filter parameter (no $), not a value, so it's only evaluated once inside
# the `$recs | f` branch, with `.` bound to $recs at that point.
def run(f; $recs): if ($recs | length) == 0 then empty else $recs | f end;

[all_raw] as $all
| ($all | map(select(.suite == "cpu"))) as $cpu
| ($all | map(select(.suite == "tls"))) as $tls
| ($all | map(select(.suite == "imagick"))) as $imagick
| ($all | map(select(.suite == "throughput"))) as $throughput
| [
	"# php-bench results",
	run(report_cpu_official_vs_distro(.); $cpu),
	run(report_cpu_cli_vs_zts(.); $cpu),
	run(report_cpu_opcache_jit(.); $cpu),
	run(report_tls(.); $tls),
	run(report_imagick(.); $imagick),
	run(report_throughput(.); $throughput)
]
| join("\n\n")
