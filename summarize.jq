#!/usr/bin/env -S jq -n -r -f
# Reads results/<suite>/<suite>-<target_id>.json files (pass them as
# arguments, e.g. `./summarize.jq results/*/*.json`) and prints a handful
# of fixed comparisons -- one per question this project was actually built
# to answer -- rather than a generic dump of every number. run.sh report
# <suite> still gets you the raw flattened CSV for anything this doesn't
# cover.
#
# The output is written for someone who wants the answer, not the data:
# every question gets a one-line plain-language answer up top, and every
# comparison names a winner in words rather than leaving the reader to
# work out which sign of a percentage is the good one. Crucially, a winner
# is only named when the gap survives the measurement noise -- see
# "uncertainty" below.

# ---------- filename/target_id parsing ----------

def suite_of($path):
	$path | split("/") | .[-2]
;

def target_id_of($path; $suite):
	$path
	| split("/")
	| .[-1] | sub("\\.json$"; "") | sub("^" + $suite + "-"; "")
;

# "official-8.2-cli-bookworm" -> {kind,version,sapi,os}; "distro-pkg-bookworm" -> distro-pkg has no version/sapi
def parse_official_id($id):
	($id | split("-")) as $p
	| if $p[0] == "official" then
		{ kind: "official", version: $p[1], sapi: $p[2], os: $p[3] }
	else
		{ kind: "distro-pkg", version: null, sapi: null, os: $p[2] }
	end
;

# "8.2-bookworm-apache-prefork" -> {version,os,mode} (mode can itself contain a hyphen)
def parse_throughput_id($id):
	($id | split("-")) as $p
	| { version: $p[0], os: $p[1], mode: ($p[2:] | join("-")) }
;

# ---------- number formatting ----------
#
# jq has no printf, and `tostring` drops trailing zeros, so a column left
# to format itself renders 2.86, 2.70 and 3.00 as "2.86", "2.7" and "3" --
# three different apparent precisions for three equally precise numbers.
# Pad manually so every cell in a column carries the same decimal places.
def fixed($dp):
	(if . < 0 then "-" else "" end) as $sign
	| fabs
	| (pow(10; $dp) | round) as $scale
	| (. * $scale | round) as $n
	| ($n / $scale | floor) as $int
	| ($n - $int * $scale) as $frac
	| $sign + (
		if $dp <= 0 then
			($int | tostring)
		else
			"\($int)."
			+ (("0" * ($dp - ($frac | tostring | length))) // "")
			+ ($frac | tostring)
		end
	)
;

# ---------- uncertainty ----------
#
# hyperfine already measures how noisy each benchmark is (stddev over the
# `times` it collected), so we read it rather than `.mean` alone and use
# it to decide whether a gap is large enough to name a winner at all.
# Without it a 5% gap on `arrays`, whose run-to-run stddev is ~19%, would
# be indistinguishable in the output from a 5% gap on `hash`, whose
# stddev is ~1% -- the first is scatter, the second is a real result.

# standard error of one benchmark's mean
def se_of($stddev; $n):
	if $n > 0 then $stddev / ($n | sqrt) else 0 end
;

# sample standard deviation of a list of numbers (for the throughput
# suite, which reports its own repeat trials instead of hyperfine's)
def stddev_of:
	length as $n
	| if $n < 2 then
		0
	else
		(add / $n) as $mean
		| (map(. - $mean | . * .) | add / ($n - 1) | sqrt)
	end
;

# agg -> {ms, se} over a list of records shaped {mean_ms, se_ms}.
#
# Two things make an average here uncertain, and we have to respect the
# larger of them. Averaging k independent means shrinks their measurement
# error by k (se = sqrt(sum(se^2)) / k) -- but if those k means are four
# different PHP versions that genuinely disagree, that scatter is the real
# uncertainty in "official", and it can be far bigger. Taking only the
# first would let the report claim "official 3% faster" on a row where the
# footnote simultaneously warns the versions disagree by 25%.
def agg:
	length as $k
	| if $k == 0 then
		{ ms: null, se: null }
	else
		(map(.mean_ms)) as $means
		| ((map((.se_ms // 0) | . * .) | add | sqrt) / $k) as $within
		| (if $k > 1 then (($means | stddev_of) / ($k | sqrt)) else 0 end) as $between
		| {
			ms: ($means | add / $k),
			se: ([ $within, $between ] | max),
		}
	end
;

# Is the gap between two {ms,se} measurements bigger than the uncertainty
# in the measurements themselves? 1.96 standard errors of the difference
# is the ordinary 95% two-sample interval; inside it, we say so rather
# than printing a percentage the data cannot support.
def significant($a; $b):
	(($a.se * $a.se + $b.se * $b.se) | sqrt) as $se_d
	| (($a.ms - $b.ms) | fabs) > (1.96 * $se_d)
;

# A gap can clear the statistical test and still deserve nobody's
# attention: with ~100 samples of a benchmark as steady as `hash`, a 0.3%
# difference is genuinely measurable and completely meaningless -- and it
# renders as the self-evident nonsense "hash 0% faster". Require the gap
# to be both statistically real and at least this many percent.
def negligible_pct:
	1
;

# decided -> is there a difference worth telling the reader about at all?
def decided($a; $b):
	significant($a; $b)
	and (
		((($a.ms - $b.ms) | fabs) / ([ $a.ms, $b.ms ] | max) * 100) >= negligible_pct
	)
;

# "official 15% faster" / "too close to call", for metrics where lower wins
def verdict_lower($a; $b; $a_label; $b_label):
	if decided($a; $b) | not then
		"too close to call"
	elif $a.ms < $b.ms then
		"\($a_label) \(($b.ms - $a.ms) / $b.ms * 100 | fixed(0))% faster"
	else
		"\($b_label) \(($a.ms - $b.ms) / $a.ms * 100 | fixed(0))% faster"
	end
;

# same, for a metric where higher wins (requests/sec)
def verdict_higher($a; $b; $a_label; $b_label):
	if decided($a; $b) | not then
		"too close to call"
	elif $a.ms > $b.ms then
		"\($a_label) \(($a.ms - $b.ms) / $b.ms * 100 | fixed(0))% more"
	else
		"\($b_label) \(($b.ms - $a.ms) / $a.ms * 100 | fixed(0))% more"
	end
;

# effect of a treatment against its own baseline (opcache/JIT), where
# there is no "winner" to name -- just a direction and a size
def effect($treat; $base):
	if decided($treat; $base) | not then
		"no measurable change"
	elif $treat.ms < $base.ms then
		"\(($base.ms - $treat.ms) / $base.ms * 100 | fixed(0))% faster"
	else
		"\(($treat.ms - $base.ms) / $base.ms * 100 | fixed(0))% slower"
	end
;

# spread of a list of means, as a percentage of their average -- used to
# flag "the 4 PHP versions disagree, so this average blends genuinely
# different numbers". This is a different thing from the noise above:
# noise is one build measured repeatedly, spread is four builds disagreeing.
def spread_pct:
	if length > 1 then
		((max - min) / (add / length) * 100)
	else
		0
	end
;

# ---------- single pass over every input file ----------
def all_raw:
	inputs as $doc
	| input_filename as $path
	| suite_of($path) as $suite
	| target_id_of($path; $suite) as $tid
	| if $suite == "cpu" then
		parse_official_id($tid) as $t
		| $doc.results[]
		| $t + {
			$suite,
			script: (.command | split(":")[0]),
			variant: (.command | split(":")[1]),
			mean_ms: (.mean * 1000),
			se_ms: se_of(.stddev * 1000; (.times | length)),
		}
	elif $suite == "tls" then
		parse_official_id($tid) as $t
		| $doc.results[]
		| $t + {
			$suite,
			command,
			mean_ms: (.mean * 1000),
			se_ms: se_of(.stddev * 1000; (.times | length)),
		}
	elif $suite == "imagick" then
		parse_official_id($tid) as $t
		| $doc.results[]
		| $t + {
			$suite,
			mean_ms: (.mean * 1000),
			se_ms: se_of(.stddev * 1000; (.times | length)),
		}
	elif $suite == "throughput" then
		parse_throughput_id($tid | ltrimstr("throughput-")) as $t
		| ($doc.trials | map(.rps)) as $trial_rps
		| $t + {
			$suite,
			rps: $doc.median.rps,
			rps_se: se_of(($trial_rps | stddev_of); ($trial_rps | length)),
			# how much a single target's rps moves between repeat trials;
			# much larger than the version-to-version spread, and the
			# reason the rps table alone cannot settle this question
			rps_trial_spread_pct: (
				($doc.rps_max - $doc.rps_min) / $doc.median.rps * 100
			),
			p50_ms: $doc.median.p50_ms,
			p95_ms: $doc.median.p95_ms,
			p99_ms: $doc.median.p99_ms,
		}
	else empty end
;

# ---------- tiny table formatter (column -t, in jq) ----------
# is_numeric_str is used to right-align numeric columns ("---:") and
# left-align everything else, auto-detected per column rather than
# declared by each call site.
def is_numeric_str:
	test("^-?[0-9]+(\\.[0-9]+)?$")
;

# table($headers; $rows) -> a GitHub-flavored markdown table, suitable for
# pasting straight into a $GITHUB_STEP_SUMMARY. Adapted from the
# markdown_table def in ../containerd-snapshotter-tarfs/e2e-tests.jq.
def table($headers; $rows):
	($headers | length) as $ncols
	| (
		[ range(0; $ncols) ]
		| map(. as $i
		| if ($rows | all(.[$i] | tostring | is_numeric_str)) then
			"---:"
		else "---" end)
	) as $aligns
	| ([ $headers ] + [ $aligns ] + $rows)
	| map(map(tostring | gsub("\\|"; "\\|")))
	| (transpose | map(map(length) | max)) as $widths
	| map(
		[ $widths, $aligns, . ]
		| transpose
		| map(.[0] as $w
		| .[1] as $align
		| (.[2] // "") as $cell
		| (" " * ([ $w - ($cell | length), 0 ] | max)) as $fill
		| if $align == "---:" then
			$fill + $cell
		else $cell + $fill end)
		| "| " + join(" | ") + " |"
	)
	| join("\n")
;

def heading($title):
	"## " + $title
;

# ---------- how to read the report ----------

def glossary:
	heading("How to read this"),
	(
		[
			"- **official** is the `docker-library/php` image's own compiled PHP; **distro-pkg** is the same distro's packaged PHP (`php-cli` and friends).",
			"- **cli** and **zts** are the non-threaded and thread-safe PHP builds. **baseline**, **opcache** and **jit** are the same build run with no bytecode cache, with opcache, and with opcache plus the JIT compiler.",
			"- **p50/p95/p99 ms** mean half, 95% and 99% of requests finished at least that fast; p99 is roughly the worst case a real user hits.",
			"- **\"too close to call\"** means the gap between the two numbers is not big enough to believe: it is smaller than either the run-to-run scatter hyperfine measured, or the disagreement between the PHP versions being averaged, whichever is larger. The millisecond figures are still shown, but the difference between them is not something to act on. Anything under 1% is reported this way too, on the grounds that nobody should care.",
			"- Millisecond columns average across whichever PHP versions were benchmarked (8.2-8.5 in a full run) and, where relevant, the OSes. Where the versions disagree enough for that average to mislead on its own, it is also called out under the table.",
			empty
		]
		| join("\n")
	)
;

# complete_or_null($keys) -> drop rows where any of $keys has no data
# behind it, and collapse the whole section to null if nothing survives.
# `run.sh bench cpu --only 8.4` is a documented workflow, and it leaves
# results with no distro-pkg and no zts to compare against; a comparison
# with only one side present has nothing to say and must not take the rest
# of the report down with it.
def complete_or_null($keys):
	map(select([ $keys[] as $k | .[$k].ms ] | all(. != null)))
	| if length == 0 then null else . end
;

# ---------- six comparisons ----------
#
# Each one is split into rows_* (the computation), answer_* (a one-line
# plain-language verdict, collected into "Bottom line" at the top of the
# report) and report_* (the heading, table and footnotes). Splitting them
# means the top-of-report answer and the table below it can never drift
# apart -- they are the same numbers.

def rows_cpu_official_vs_distro($recs):
	[
		$recs[]
		| select(.variant == "baseline")
		| select(.kind == "distro-pkg" or .sapi == "cli")
	]
	| group_by([ .os, .script ])
	| map(
		(map(select(.kind == "official"))) as $off
		| {
			os: .[0].os,
			script: .[0].script,
			official: ($off | agg),
			distro: (map(select(.kind == "distro-pkg")) | agg),
			version_spread_pct: ($off | map(.mean_ms) | spread_pct),
			version_count: ($off | length),
		}
	)
	| complete_or_null([ "official", "distro" ])
	| if . == null then null else
		map(. + {
			verdict: verdict_lower(.official; .distro; "official"; "distro-pkg"),
		})
		| sort_by(.os, .script)
	end
;

def answer_cpu_official_vs_distro($rows):
	([ $rows[] | select(.verdict | startswith("official")) ]) as $off
	| ([ $rows[] | select(.verdict | startswith("distro-pkg")) ]) as $distro
	| ([ $rows[] | select(.verdict == "too close to call") ]) as $tie
	| (
		$off
		| sort_by(- ((.distro.ms - .official.ms) / .distro.ms))
		| .[0]
	) as $biggest
	| (
		if ($distro | length) == 0 then
			"**No** -- official is never measurably slower."
		elif ($off | length) > ($distro | length) then
			"**Mostly no** -- official wins far more often than it loses."
		else
			"**Mixed.**"
		end
	)
	+ " official faster in \($off | length) of \($rows | length) os/script pairs, "
	+ "distro-pkg faster in \($distro | length), too close to call in \($tie | length)"
	+ (
		if $biggest != null then
			" (biggest real gap: \($biggest.os)/\($biggest.script), \($biggest.verdict))"
		else "" end
	)
;

def report_cpu_official_vs_distro($rows):
	heading("CPU: is official slower than the distro's own PHP? -- https://github.com/docker-library/php/issues/493"),
	table([
		"os",
		"script",
		"official_ms",
		"distro_pkg_ms",
		"who wins",
		empty
	]; [
		$rows[]
		| [
			.os,
			.script,
			(.official.ms | fixed(0)),
			(.distro.ms | fixed(0)),
			.verdict,
			empty
		]
	]),
	"> " + answer_cpu_official_vs_distro($rows),
	($rows | map(.version_count) | max) as $nver
	| ([ $rows[] | select(.version_spread_pct > 15) ]) as $inconsistent
	| if $nver < 2 then
		"> only one PHP version is present here, so there is no cross-version check to make."
	elif ($inconsistent | length) > 0 then
		"> heads-up: the \($nver) PHP versions disagree by more than 15% on "
		+ (
			$inconsistent
			| map("\(.os)/\(.script) (\(.version_spread_pct | fixed(0))%)")
			| join(", ")
		)
		+ " -- that disagreement is already folded into the verdicts above, and it is why some of those rows read \"too close to call\" despite a visible gap in the milliseconds."
	else
		"> the \($nver) PHP versions agree within 15% on every row, so the official_ms averages are stable."
	end
;

def rows_cpu_cli_vs_zts($recs):
	[ $recs[] | select(.sapi == "cli" or .sapi == "zts") ]
	| group_by([ .script, .variant ])
	| map(
		. as $g
		| {
			script: .[0].script,
			variant: .[0].variant,
			cli: (map(select(.sapi == "cli")) | agg),
			zts: (map(select(.sapi == "zts")) | agg),
			by_version: (
				$g
				| group_by(.version)
				| map(
					(map(select(.sapi == "cli")) | agg) as $c
					| (map(select(.sapi == "zts")) | agg) as $z
					| if ($c.ms == null or $z.ms == null) then
						empty
					else
						{
							version: .[0].version,
							delta_pct: (($z.ms - $c.ms) / $c.ms * 100),
						}
					end
				)
				| sort_by(.version)
			),
		}
	)
	| complete_or_null([ "cli", "zts" ])
	| if . == null then null else
		map(. + {
			delta_pct: ((.zts.ms - .cli.ms) / .cli.ms * 100),
			verdict: verdict_lower(.cli; .zts; "cli"; "zts"),
		})
		| sort_by(.script, .variant)
	end
;

def answer_cpu_cli_vs_zts($rows):
	([ $rows[] | select(.verdict | startswith("cli")) ]) as $zts_slower
	| ([ $rows[] | select(.verdict | startswith("zts")) ]) as $zts_faster
	| ([ $rows[] | select(.verdict == "too close to call") ]) as $tie
	| if ($zts_slower | length) == 0 then
		"**No measurable cost** -- every one of the \($rows | length) script/variant pairs is too close to call."
	else
		($zts_slower | sort_by(- .delta_pct)) as $ranked
		| "**Up to +\($ranked[0].delta_pct | fixed(0))%, "
		+ (
			# "only on 15 of 21" would be an odd way to describe a majority
			if ($ranked | length) * 2 < ($rows | length) then "and only on " else "on " end
		)
		+ "\($ranked | length) of \($rows | length) workloads** -- zts is measurably slower on "
		+ (
			$ranked[0:3]
			| map("\(.script):\(.variant) (+\(.delta_pct | fixed(0))%)")
			| join(", ")
		)
		+ (
			if ($ranked | length) > 3 then
				" and \(($ranked | length) - 3) more, none above +\($ranked[3].delta_pct | fixed(0))%"
			else "" end
		)
		+ (
			if ($zts_faster | length) > 0 then
				". \($zts_faster | length) came out measurably faster under zts"
			else "" end
		)
		+ ". The other \($tie | length) are too close to call."
	end
;

def report_cpu_cli_vs_zts($rows):
	heading("CPU: what does the thread-safe (zts) build cost? -- https://github.com/docker-library/php/issues/742"),
	table([
		"script",
		"variant",
		"cli_ms",
		"zts_ms",
		"who wins",
		empty
	]; [
		$rows[]
		| [
			.script,
			.variant,
			(.cli.ms | fixed(0)),
			(.zts.ms | fixed(0)),
			.verdict,
			empty
		]
	]),
	"> " + answer_cpu_cli_vs_zts($rows),
	(
		[
			$rows[]
			| select((.by_version | length) > 1)
			| select(
				((.by_version | map(.delta_pct) | max)
				- (.by_version | map(.delta_pct) | min)) > 15
			)
		]
	) as $inconsistent
	| ($rows | map(.by_version | length) | max) as $nver
	| if $nver < 2 then
		"> only one PHP version is present here, so there is no cross-version check to make."
	elif ($inconsistent | length) > 0 then
		"> heads-up: the zts cost itself varies by more than 15 points across PHP versions on "
		+ (
			$inconsistent
			| map(
				"\(.script):\(.variant) ("
				+ (
					.by_version
					| map("\(.version): \(.delta_pct | fixed(0))%")
					| join(", ")
				)
				+ ")"
			)
			| join("; ")
		)
		+ " -- a single number for those hides a per-version story."
	else
		"> the zts cost is consistent across all \($nver) PHP versions."
	end
;

def rows_cpu_opcache_jit($recs):
	[ $recs[] | select(.kind == "official" and .sapi == "cli") ]
	| group_by(.script)
	| map(
		. as $g
		| {
			script: .[0].script,
			baseline: (map(select(.variant == "baseline")) | agg),
			opcache: (map(select(.variant == "opcache")) | agg),
			jit: (map(select(.variant == "jit")) | agg),
			by_version: (
				$g
				| group_by(.version)
				| map(
					(map(select(.variant == "baseline")) | agg) as $b
					| (map(select(.variant == "jit")) | agg) as $j
					| if ($b.ms == null or $j.ms == null) then
						empty
					else
						{
							version: .[0].version,
							jit_delta_pct: (($j.ms - $b.ms) / $b.ms * 100),
						}
					end
				)
				| sort_by(.version)
			),
		}
	)
	| complete_or_null([ "baseline", "opcache", "jit" ])
	| if . == null then null else
		map(. + {
			opcache_effect: effect(.opcache; .baseline),
			jit_effect: effect(.jit; .baseline),
			jit_delta_pct: ((.jit.ms - .baseline.ms) / .baseline.ms * 100),
		})
		| sort_by(.script)
	end
;

def answer_cpu_opcache_jit($rows):
	([ $rows[] | select(.jit_effect | endswith("faster")) ]) as $jit_helped
	| ([ $rows[] | select(.jit_effect | endswith("slower")) ]) as $jit_hurt
	| ([ $rows[] | select(.opcache_effect | endswith("slower")) ]) as $op_hurt
	| (
		if ($jit_helped | length) == 0 then
			"**JIT does nothing measurable here**"
		else
			"**Only for \($jit_helped | map(.script) | join(", "))** -- JIT speeds up \($jit_helped | length) of \($rows | length) scripts ("
			+ (
				$jit_helped
				| sort_by(.jit_delta_pct)
				| map("\(.script) \(.jit_effect)")
				| join(", ")
			)
			+ ")"
		end
	)
	+ (
		if ($jit_hurt | length) > 0 then
			" and slows down \($jit_hurt | length) (" + ($jit_hurt | map("\(.script) \(.jit_effect)") | join(", ")) + ")"
		else "" end
	)
	+ (
		if ($op_hurt | length) > 0 then
			". opcache alone is measurably slower on " + ($op_hurt | map(.script) | join(", ")) + "."
		else
			". opcache alone shows no measurable cost anywhere."
		end
	)
;

def report_cpu_opcache_jit($rows):
	heading("CPU: do opcache and JIT actually help? (official cli)"),
	table([
		"script",
		"baseline_ms",
		"opcache_ms",
		"jit_ms",
		"opcache vs baseline",
		"jit vs baseline",
		empty
	]; [
		$rows[]
		| [
			.script,
			(.baseline.ms | fixed(0)),
			(.opcache.ms | fixed(0)),
			(.jit.ms | fixed(0)),
			.opcache_effect,
			.jit_effect,
			empty
		]
	]),
	"> " + answer_cpu_opcache_jit($rows),
	(
		[
			$rows[]
			| select((.by_version | length) > 1)
			| select(
				((.by_version | map(.jit_delta_pct) | max)
				- (.by_version | map(.jit_delta_pct) | min)) > 15
			)
		]
	) as $inconsistent
	| ($rows | map(.by_version | length) | max) as $nver
	| if $nver < 2 then
		"> only one PHP version is present here, so there is no cross-version check to make -- worth repeating with the full matrix, since JIT itself changed across 8.2-8.5."
	elif ($inconsistent | length) > 0 then
		"> heads-up: JIT itself changed across 8.2-8.5, and its effect varies by more than 15 points across versions on "
		+ (
			$inconsistent
			| map(
				"\(.script) ("
				+ (
					.by_version
					| map("\(.version): \(.jit_delta_pct | fixed(0))%")
					| join(", ")
				)
				+ ")"
			)
			| join("; ")
		)
		+ " -- worth reading per-version rather than as one number."
	else
		"> the JIT effect is consistent across all \($nver) PHP versions, despite JIT itself changing over 8.2-8.5."
	end
;

def rows_tls($recs):
	$recs
	| group_by(.os)
	| map(
		. as $g
		| (map(select(.command == "verify")) | agg) as $v
		| (map(select(.command == "noverify")) | agg) as $nv
		| {
			os: .[0].os,
			verify: $v,
			noverify: $nv,
			cost_x: ($v.ms / $nv.ms),
			by_target: (
				$g
				| group_by([ .kind, .version ])
				| map(
					((map(select(.command == "verify")) | agg) | .ms) as $v
					| ((map(select(.command == "noverify")) | agg) | .ms) as $nv
					| if ($v == null or $nv == null) then empty else $v / $nv end
				)
			),
		}
	)
	| complete_or_null([ "verify", "noverify" ])
	| if . == null then null else
		map(. + {
			cost_x_min: (.by_target | min),
			cost_x_max: (.by_target | max),
		})
		| sort_by(.os)
	end
;

def answer_tls($rows):
	($rows | sort_by(- .cost_x) | .[0]) as $worst
	| ($rows | sort_by(.cost_x) | .[0]) as $best
	| "**Between \($best.cost_x | fixed(1))x and \($worst.cost_x | fixed(1))x the request time, depending entirely on the OS** -- "
	+ "\($worst.os) is the outlier at \($worst.cost_x | fixed(1))x (\($worst.verify.ms | fixed(0)) ms per request against "
	+ "\($worst.noverify.ms | fixed(0)) ms unverified), while \($best.os) pays only \($best.cost_x | fixed(1))x. "
	+ "Same PHP, same code: the cost is in the distro's CA store handling."
;

def report_tls($rows):
	heading("TLS: how much does certificate verification cost? -- https://github.com/docker-library/php/issues/1431"),
	table([
		"os",
		"verify_ms",
		"noverify_ms",
		"verify_cost_x",
		empty
	]; [
		$rows[]
		| [
			.os,
			(.verify.ms | fixed(0)),
			(.noverify.ms | fixed(0)),
			(.cost_x | fixed(2)),
			empty
		]
	]),
	"> verify_cost_x is a multiplier: 3.00 means verification makes the request take three times as long.",
	"> " + answer_tls($rows),
	([ $rows[] | select((.cost_x_max / .cost_x_min) > 1.5) ]) as $inconsistent
	| if ($inconsistent | length) > 0 then
		"> heads-up: versions/distro-pkg within one OS disagree by more than 1.5x on "
		+ (
			$inconsistent
			| map("\(.os) (\(.cost_x_min | fixed(2))x-\(.cost_x_max | fixed(2))x)")
			| join(", ")
		)
	else
		"> every PHP version and distro-pkg inside a given OS lands on much the same multiplier, so these are solid."
	end
;

def rows_imagick($recs):
	($recs | map(.mean_ms) | sort) as $sorted
	| ($sorted[($sorted | length / 2 | floor)]) as $median
	| $recs
	| group_by(.os)
	| map(
		. as $g
		| (map(select(.kind == "official"))) as $off
		| {
			os: .[0].os,
			official: ($off | agg),
			distro: (map(select(.kind == "distro-pkg")) | agg),
			version_spread_pct: ($off | map(.mean_ms) | spread_pct),
			version_count: ($off | length),
			# #1100 was a resize that got dramatically slower, so the
			# check that matters is "is anything wildly off the pace",
			# not "who wins by a few percent"
			outlier: (($g | map(.mean_ms) | max) > ($median * 3)),
		}
	)
	| complete_or_null([ "official", "distro" ])
	| if . == null then null else
		map(. + {
			verdict: verdict_lower(.official; .distro; "official"; "distro-pkg"),
		})
		| sort_by(.os)
	end
;

def answer_imagick($rows):
	([ $rows[] | select(.outlier) ]) as $flagged
	| if ($flagged | length) > 0 then
		"**Possibly back** -- \($flagged | length) of \($rows | length) OSes run more than 3x the matrix median: "
		+ ($flagged | map(.os) | join(", "))
		+ ". Worth investigating before shipping."
	else
		"**No** -- nothing is anywhere near the 3x-median outlier threshold; every OS resizes in a tight "
		+ "\($rows | map(.official.ms) | min | fixed(0))-\($rows | map(.official.ms) | max | fixed(0)) ms band."
	end
;

def report_imagick($rows):
	heading("Imagick: has the slow-resize regression come back? -- https://github.com/docker-library/php/issues/1100"),
	table([
		"os",
		"official_ms",
		"distro_pkg_ms",
		"who wins",
		empty
	]; [
		$rows[]
		| [
			.os,
			(.official.ms | fixed(0)),
			(.distro.ms | fixed(0)),
			.verdict,
			empty
		]
	]),
	"> " + answer_imagick($rows),
	($rows | map(.version_count) | max) as $nver
	| ([ $rows[] | select(.version_spread_pct > 15) ]) as $inconsistent
	| if $nver < 2 then
		"> only one PHP version is present here, so there is no cross-version check to make."
	elif ($inconsistent | length) > 0 then
		"> heads-up: the \($nver) PHP versions disagree by more than 15% on "
		+ (
			$inconsistent
			| map("\(.os) (\(.version_spread_pct | fixed(0))%)")
			| join(", ")
		)
		+ " -- still far below the outlier threshold, but the official_ms average there is not a stable figure."
	else
		"> the \($nver) PHP versions agree within 15% on every OS."
	end
;

def rows_throughput($recs):
	# Unlike the others this returns an object, not an array: the honest
	# answer to #681 comes from the pairwise sweep rather than from the
	# headline rps means, so both have to travel together.
	#
	# Nothing here names a specific mode. The matrix grows modes over time
	# (apache-prefork, fpm-nginx, fpm-httpd so far), and there is no
	# guarantee that one of them wins everything -- a server can serve more
	# requests per second *and* have the worse tail latency, which is
	# exactly what happens in practice. So each metric gets its own winner,
	# counted over the version/os pairs where the modes actually met.
	[
		{ key: "rps", label: "requests/sec", higher: true },
		{ key: "p50_ms", label: "median latency", higher: false },
		{ key: "p95_ms", label: "p95 latency", higher: false },
		{ key: "p99_ms", label: "p99 latency", higher: false },
		empty
	] as $metrics
	| (
		$recs
		| group_by([ .version, .os ])
		# a pair needs at least two modes present to have a winner at all
		| map(select(length > 1))
	) as $groups
	| if ($groups | length) == 0 then
		null
	else
		{
			modes: (
				$recs
				| group_by(.mode)
				| map({
					mode: .[0].mode,
					rps: (map({ mean_ms: .rps, se_ms: .rps_se }) | agg),
					p50_ms: (map(.p50_ms) | add / length),
					p95_ms: (map(.p95_ms) | add / length),
					p99_ms: (map(.p99_ms) | add / length),
				})
				| sort_by(- .rps.ms)
			),
			metrics: (
				$metrics
				| map(
					. as $m
					| (
						$groups
						| map(
							sort_by(.[$m.key])
							| (if $m.higher then last else first end)
							| .mode
						)
					) as $winners
					| $m + {
						total: ($winners | length),
						tally: (
							$winners
							| group_by(.)
							| map({ mode: .[0], wins: length })
							| sort_by(- .wins)
						),
					}
				)
			),
			worst_trial_spread_pct: ($recs | map(.rps_trial_spread_pct) | max),
		}
	end
;

# the mode that wins a metric, or null when the top two are tied -- a
# 4/8-4/8 metric has no winner, and naming the one that happened to sort
# first would be reporting a coin flip
def metric_winner:
	if (.tally | length) > 1 and (.tally[0].wins == .tally[1].wins) then
		null
	else
		.tally[0].mode
	end
;

def answer_throughput($tp):
	($tp.metrics | map(metric_winner)) as $per_metric
	| ($per_metric | unique) as $winners
	| ($tp.metrics[0]) as $rps
	| (
		if ($winners | length) == 1 and ($winners[0] != null) then
			"**\($winners[0]), on every measure** -- it wins requests/sec and all three latency percentiles"
		else
			"**It depends which you care about** -- "
			+ (
				$tp.metrics
				| map(
					if metric_winner == null then
						"\(.label): no clear winner (\(.tally | map("\(.mode) \(.wins)") | join(" vs ")))"
					else
						"\(.label): \(.tally[0].mode) (\(.tally[0].wins) of \(.total))"
					end
				)
				| join("; ")
			)
			+ ". Raw throughput and tail latency disagree here, so there is no single winner to name"
		end
	)
	+ ". A single target's rps moves by up to \($tp.worst_trial_spread_pct | fixed(0))% between repeat trials, "
	+ "so it is the consistency across \($rps.total) version/os pairs that carries this, not the size of the gaps in the table."
;

def report_throughput($tp):
	heading("Throughput: which server/SAPI combination handles load best? -- https://github.com/docker-library/php/issues/681"),
	table([
		"mode",
		"rps",
		"p50_ms",
		"p95_ms",
		"p99_ms",
		empty
	]; [
		$tp.modes[]
		| [
			.mode,
			(.rps.ms | fixed(0)),
			(.p50_ms | fixed(2)),
			(.p95_ms | fixed(2)),
			(.p99_ms | fixed(2)),
			empty
		]
	]),
	"> rps is requests/sec, so higher is better; the p-columns are latencies, so lower is better.",
	"> " + answer_throughput($tp),
	(
		if ($tp.metrics | any((.tally | length) > 1)) then
			"> full split per version/os pair: "
			+ (
				$tp.metrics
				| map(
					"\(.label) -- "
					+ (.tally | map("\(.mode) \(.wins)/\($tp.metrics[0].total)") | join(", "))
				)
				| join("; ")
			)
		else
			empty
		end
	)
;

# ---------- single pass, then dispatch ----------
#
# Every report_* is a stream of markdown blocks (a heading, a table, one or
# more "> " notes), and gets skipped entirely when its suite produced no
# files -- a suite that never ran, or failed in CI while others succeeded,
# shouldn't crash the rest of the report.

# rows(f; $recs) -> f applied to $recs, or null if $recs is empty
def rows(f; $recs):
	if ($recs | length) == 0 then null else $recs | f end
;

# report(f; $rows) -> f applied to $rows, or nothing at all if it is null.
# f is a filter parameter (no $), not a value, so it is only evaluated
# inside the `$rows | f` branch, with `.` bound to $rows at that point.
def report(f; $rows):
	if $rows == null then empty else $rows | f end
;

# bottom_line -> the answer to every question, before any table. Skips
# questions whose suite produced no results.
def bottom_line($items):
	heading("Bottom line"),
	(
		[ $items[] | select(.a != null) | "- **\(.q)** \(.a)" ]
		| join("\n")
	)
;

[ all_raw ] as $all
| ($all | map(select(.suite == "cpu"))) as $cpu
| ($all | map(select(.suite == "tls"))) as $tls
| ($all | map(select(.suite == "imagick"))) as $imagick
| ($all | map(select(.suite == "throughput"))) as $throughput
| rows(rows_cpu_official_vs_distro(.); $cpu) as $r_vs_distro
| rows(rows_cpu_cli_vs_zts(.); $cpu) as $r_zts
| rows(rows_cpu_opcache_jit(.); $cpu) as $r_jit
| rows(rows_tls(.); $tls) as $r_tls
| rows(rows_imagick(.); $imagick) as $r_imagick
| rows(rows_throughput(.); $throughput) as $r_throughput
| [
	"# php-bench results",
	bottom_line([
		{
			q: "Is our compiled PHP slower than the distro's?",
			a: report(answer_cpu_official_vs_distro(.); $r_vs_distro),
		},
		{
			q: "What does the thread-safe (zts) build cost?",
			a: report(answer_cpu_cli_vs_zts(.); $r_zts),
		},
		{
			q: "Do opcache and JIT actually help?",
			a: report(answer_cpu_opcache_jit(.); $r_jit),
		},
		{
			q: "How much does TLS certificate verification cost?",
			a: report(answer_tls(.); $r_tls),
		},
		{
			q: "Has the slow Imagick resize come back?",
			a: report(answer_imagick(.); $r_imagick),
		},
		{
			q: "Which server/SAPI combination handles load best?",
			a: report(answer_throughput(.); $r_throughput),
		},
		empty
	]),
	glossary,
	report(report_cpu_official_vs_distro(.); $r_vs_distro),
	report(report_cpu_cli_vs_zts(.); $r_zts),
	report(report_cpu_opcache_jit(.); $r_jit),
	report(report_tls(.); $r_tls),
	report(report_imagick(.); $r_imagick),
	report(report_throughput(.); $r_throughput),
	empty
]
| join("\n\n")
