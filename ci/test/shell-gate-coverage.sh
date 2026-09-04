#!/usr/bin/env bash
#
# shell-gate-coverage.sh — fail, BY NAME, on any shell gate under ci/ or
# scripts/ that no CI WORKFLOW LANE can reach.
#
# WHAT WAS WRONG WITH THIS FILE ON 2026-09-04, WHICH IS THE SHORT VERSION OF
# EVERYTHING BELOW
# -----------------------------------------------------------------------
# It printed `96 found, 88 reachable, 8 recorded dark, 0 UNRECORDED dark` and
# exited 0, and the green WAS the finding. Two blind spots:
#
#   (a) THE JUSTFILE WAS A ROOT. A gate named by any `just` recipe counted as
#       reached — including the 151 of 208 recipes that no lane calls. Thirteen
#       gates were covered by nothing but a recipe a person types.
#   (b) THE SCAN WAS `ci/test` AT `-maxdepth 1`. `ci/verdict/`, `ci/runner/`,
#       `ci/lib/`, `ci/build/`, `ci/deploy/`, `ci/reprobuild/` and all of
#       `scripts/` were outside the universe of the check that exists to find
#       dark gates.
#
# Same tree, same day, honestly measured: 161 found, 130 reachable, 9 declared
# not-a-gate, 22 recorded dark. Nothing was fixed to get from 88/96 to 130/161;
# the earlier number was simply about a smaller question than it claimed.
#
# WHY THIS EXISTS
# ---------------
# `ci/test/test-lane-coverage.sh` is the same guard for Nim, and its header says
# what it is for: 61 test-shaped `.nim` files were reached by NO lane at all, and
# nothing anywhere said so. It fixed that, and it is scoped — in its own first
# line — to "any test-shaped **Nim** file".
#
# The shell gates were measured by nothing until this file, and its own first
# run on 2026-09-01 named four that no workflow, no recipe and no other gate
# referenced. A guard that stops at a file extension leaves a hole exactly the
# shape of everything it does not cover, and the whole argument of the Nim guard
# applies here unchanged: work goes into a gate, the gate goes into the tree, and
# nothing runs it. The same sentence turned out to apply to this file's own
# scope, twice over, which is what (a) and (b) above record.
#
# REACHABILITY, NOT MENTION — AND A LANE, NOT AN ENTRY POINT
# -----------------------------------------------------------
# A gate is covered when a CI WORKFLOW LANE can reach it: named in a workflow, or
# in a `just` recipe SOME LANE CALLS, or in another script that is itself
# reachable. Three distinctions, each of which the naive rule gets wrong:
#
#   * TRANSITIVITY. `visual-replay-gate-lib.sh` is sourced only by
#     `visual-replay-gate.sh`, and would look covered by a rule that merely asked
#     "is this name mentioned anywhere in ci/". If the gate that names it is
#     itself dark, so is it. `ci/lib/published-asset.sh` is the live instance:
#     five scripts source it and all five are dark.
#   * DIRECTION. Transitivity has to be walked from the ROOTS OUTWARD, not
#     assumed from a file's presence. Seeding from the justfile is the version of
#     this error that was here: it credits the whole justfile at once.
#   * PROSE. A comment naming a gate is not a wire. See `refs_in`.
#
# The walk therefore has TWO KINDS OF NODE — scripts and `just` recipes — and
# crosses between them in both directions. That is not over-engineering; it is
# the only thing that gets `ci/test/sibling-backend-path-test.sh` right, which is
# reached as `codetracer.yml` -> `ci/test/non-gui.sh` -> `just test` ->
# `test-sibling-backend-path`, four hops alternating between the two.
#
# THE ESCAPE HATCH IS THE NIM GUARD'S, SPELLED THE SAME WAY
# ---------------------------------------------------------
# A gate that is deliberately not wired declares it, in its own first
# ${MARKER_SCAN_LINES} lines:
#
#     # NOT-A-CI-GATE: <reason>
#
# A reason a reviewer can disagree with, written down, in the file. No fuzzy
# heuristic: "looks like a helper" is how a real gate gets skipped by accident.
#
# AND THE OTHER DIRECTION
# -----------------------
# ROT: a workflow or lint dispatcher naming a `ci/` or `scripts/` script that
# does not exist. The Nim guard checks this because a lane named a deleted file
# for months and simply ran one fewer test than it claimed. A workflow step that
# invokes a missing script fails loudly at run time — but only if that workflow
# runs, and a step guarded by an `if:` may not for months.
#
# AND A THIRD DIRECTION, ADDED 2026-09-04
# ---------------------------------------
# The recorded-dark inventory declares its own length, and this guard fails
# unless the number of entries EQUALS it. An exception list that can grow quietly
# stops being read, and appending a line was always the cheapest way to make this
# file green. See the inventory's header for why it is an equality and not a
# ceiling with slack.
#
# Usage:
#   ci/test/shell-gate-coverage.sh
#   ci/test/shell-gate-coverage.sh --root DIR      (for the self-test)

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
while [ $# -gt 0 ]; do
	case "$1" in
	--root)
		root="$(cd "$2" && pwd)"
		shift 2
		;;
	*)
		echo "unknown argument: $1" >&2
		exit 2
		;;
	esac
done
cd "${root}" || exit 2

MARKER_SCAN_LINES=40
MARKER='NOT-A-CI-GATE:'

checks=0
failures=0
note() { printf '  %s\n' "$*"; }
ok() {
	checks=$((checks + 1))
	printf '  [OK]     %s\n' "$*"
}
bad() {
	checks=$((checks + 1))
	failures=$((failures + 1))
	printf '  [FAILED] %s\n' "$*"
}

# WHERE THE GATES LIVE — AND WHY THIS IS NO LONGER ONE DIRECTORY.
#
# This was `gate_dir="ci/test"` with `find -maxdepth 1`, which put `ci/verdict/`,
# `ci/runner/`, `ci/lib/`, `ci/build/`, `ci/deploy/`, `ci/reprobuild/` and the
# whole of `scripts/` OUTSIDE the universe of the check whose entire job is to
# find gates nothing runs. A dark-gate finder that cannot see most of the
# repository's shell reports a clean sweep of the corner it was pointed at, and
# `scripts/require-tup-globs.sh` — a build prerequisite that only ever gets
# SHELLCHECKED, never run — sat outside it the whole time.
#
# `gate_home` is still `ci/test`, because that is where this guard and its
# inventory file live. It is no longer where the subject lives.
gate_dirs="ci scripts"
gate_home="ci/test"
if [ ! -d "${gate_home}" ]; then
	echo "no ${gate_home} under ${root}; this guard has no subject" >&2
	exit 2
fi

# ---------------------------------------------------------------------------
# The subject: every shell gate. Discovered, never listed.
# ---------------------------------------------------------------------------
# Newline-delimited strings and `grep -Fxq` for membership, not arrays and not
# `declare -A`. The host toolchain here is bash 3.2, which has neither
# `mapfile` nor associative arrays — `ci/test/test-lane-coverage.sh` is written
# the same way for the same reason. A guard that only runs on the CI box cannot
# be checked before it is pushed.
#
# IDENTITY IS THE REPO-RELATIVE PATH, NOT THE BASENAME. Widening the scan made
# basenames ambiguous — `nix.sh` is both `ci/build/nix.sh` and `ci/lint/nix.sh`,
# `rust.sh` is both `ci/lint/rust.sh` and `ci/test/rust.sh` — and a set keyed by
# basename would have reported the dark one of each pair as covered by the
# reachable one.
gate_find_dirs=""
for d in ${gate_dirs}; do
	[ -d "${d}" ] && gate_find_dirs="${gate_find_dirs} ${d}"
done
# shellcheck disable=SC2086
gates="$(find ${gate_find_dirs} -type f -name '*.sh' 2>/dev/null | sed 's#^\./##' | sort)"
gate_count="$(printf '%s\n' "${gates}" | grep -c . || true)"

# A HERE-STRING, NOT A PIPE, AND THIS IS A CORRECTNESS FIX RATHER THAN STYLE.
#
# This was `printf '%s\n' "$2" | grep -Fxq -- "$1"`, and under the `set -uo
# pipefail` on line 58 that construction reports FALSE FOR ITEMS THAT ARE
# PRESENT. `grep -q` exits the instant it matches; if the haystack is larger
# than a pipe buffer, `printf` is still writing, takes EPIPE, and fails. With
# `pipefail` the pipeline adopts printf's failure, so a successful match is
# returned as "not in set".
#
# Measured, not theorised: with a 200k-line haystack and an item that is
# present by construction, the old form returned false 40 times out of 40. The
# tell is in the CI log, immediately above each spurious result:
#
#     ci/test/shell-gate-coverage.sh: line 108: printf: write error: Broken pipe
#     [FAILED] ci/test/origin-dap-gate.sh is reachable from NO workflow ...
#
# Because it depends on whether printf finishes before grep exits, it is a
# race: run 33784363822 reported THREE unreachable gates on `dev` while the
# same tree reported ONE locally. Two of those three were reachable all along.
# That made `lint-nim` fail, and `lint-nim` gates every build job in the repo.
#
# The here-string has no pipe to break, so there is no EPIPE and no pipefail
# interaction. It is bash 3.2 compatible, which the note above requires.
in_set() { grep -Fxq -- "$1" <<<"$2"; }

echo "=== shell gate coverage — can CI reach every gate in ci/test/? ==="
echo

echo "Step 0: the subject list is non-empty"
echo "    A scan that found nothing reports perfect coverage of nothing."
if [ "${gate_count}" -ge 10 ]; then
	ok "found ${gate_count} shell script(s) under${gate_find_dirs}/"
else
	bad "found only ${gate_count} gate(s) — the scan is broken, and every check below would be vacuous"
	echo
	echo "RESULT: FAILED"
	exit 1
fi
echo

# ---------------------------------------------------------------------------
# The roots: what CI can start from.
# ---------------------------------------------------------------------------
# THE WORKFLOWS, AND NOTHING ELSE. THIS IS THE OTHER HALF OF THE FIX.
#
# This list used to include the justfile and the `ci/lint/*.sh` dispatchers as
# roots in their own right, and the justfile is the one that made the number a
# fiction: EVERY gate any `just` recipe mentioned was seeded as reachable,
# whether or not any lane runs that recipe. `just` is a developer entry point.
# Most of its 200-odd recipes are things a person types; a handful are things CI
# types. Seeding from the file rather than from the recipes CI actually calls
# credited fourteen gates — the `noir-*` family, the `desktop-*` family,
# `cli-record-smoke.sh`, `python-recorder-smoke.sh` and the rest — as covered
# while they ran in no lane at all.
#
# The dispatchers do not need to be roots either, and making them roots hid the
# same class of error one level down. `ci/lint/nim.sh` IS reachable — four
# workflow steps name it — so the walk below reaches it the ordinary way, and if
# a day comes when no workflow names it, this guard should say so rather than
# assume it.
#
# NOT A ROOT, DELIBERATELY: `.gitlab-ci.yml`. It exists, it is 120 lines, and it
# names `just test` and `ci/test/ui-tests.sh`. Counting it would credit
# `ui-tests.sh` and everything under `just test` — and this repository's CI is
# GitHub Actions: the inventory beside this file has recorded `ui-tests.sh` as
# dark since 2026-09-01 with `ui-tests-db.sh is wired and this is not` as the
# reason, which is a statement about the GitHub lanes. Treating the GitLab file
# as a lane would silently retire that finding and five more. If somebody
# revives that pipeline, add it here and watch six entries evict themselves.
roots="$(find .github/workflows -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort)"
root_count="$(printf '%s\n' "${roots}" | grep -c . || true)"

echo "Step 1: the CI roots are readable"
if [ "${root_count}" -ge 2 ]; then
	ok "${root_count} CI root(s): the workflow files, and only those"
else
	bad "found ${root_count} CI root(s) — reachability below would be measured from nothing"
	echo
	echo "RESULT: FAILED"
	exit 1
fi
echo

# `refs_in` — reads file paths on STDIN, prints one reference per line:
#
#     S <token>     a `*.sh` path or basename this file INVOKES
#     J <recipe>    a `just <recipe>` this file CALLS
#
# THREE THINGS ARE DROPPED, AND EACH OF THEM CREDITED A DARK SCRIPT AS LIVE.
#
# 1. COMMENT LINES, for the reason spelled out at length below.
#
# 2. LINE CONTINUATIONS ARE JOINED FIRST. `ci/lint/bash.sh` writes every step as
#    `lint_step "..." \` followed by indented arguments, so the command and its
#    arguments are on different physical lines. Reading them separately makes
#    rule 3 unenforceable: the arguments look like a bare invocation.
#
# 3. `shellcheck` AND `shfmt` LINES, WHOLESALE. This is the widened scan's
#    version of "mention is not reachability", and without it the widening finds
#    almost nothing. `ci/lint/bash.sh` shellchecks eleven scripts it never runs —
#    `scripts/require-tup-globs.sh`, `scripts/require-siblings.sh`,
#    `scripts/require-fuse-mount-helper.sh`, `scripts/sibling-pins.sh`,
#    `scripts/toolchain-pins.sh` among them. A linter READS a file. Counting that
#    as CI reaching it is the same error as counting a doc comment, one tool
#    further along: `require-tup-globs.sh` would be reported covered by the lane
#    that proves only that it parses.
refs_in() {
	# Reads paths on STDIN, one per line, so the caller need not expand a list
	# into positional arguments — bash 3.2 has no array to expand.
	#
	# COMMENT LINES ARE DROPPED BEFORE NAMES ARE EXTRACTED, and this file is the
	# reason. Its own header lists the gates it found dark. Once it was wired
	# into `ci/lint/nim.sh` it became reachable, the transitive walk followed it,
	# and every gate NAMED IN ITS PROSE was credited as reachable — so the guard
	# reported 63 of 63 covered while four of them were referenced by nothing at
	# all. A scanner that reads its own documentation is satisfied by anything
	# that documentation says.
	#
	# Verification-Harness-Traps.md §4d, and the third instance found in this
	# session: `ci-coverage.sh` in the sibling repository read a step's doc
	# comment instead of the step, and its selftest's mutation arms rewrote a
	# comment about a trigger instead of the trigger. Each time a control caught
	# it; none of the three would have been visible in the transcript.
	local f
	while read -r f; do
		[ -n "${f}" ] || continue
		[ -f "${f}" ] || continue
		refs_of_text <"${f}"
	done | grep -v '^$' | sort -u || true
}

# The extractor itself, over one file's text on stdin. `awk`, because joining
# continuations and then tokenising is a two-state job and `grep` has one state.
# POSIX awk only: no `gensub`, no `asort`, no `[[:space:]]` outside brackets.
refs_of_text() {
	awk '
	{
		cur = cur $0
		if (cur ~ /\\$/) { sub(/\\$/, " ", cur); next }
		emit(cur); cur = ""
	}
	END { if (cur != "") emit(cur) }

	function emit(line,   n, i, j, t, u, rest, arr) {
		if (line ~ /^[ \t]*#/) return
		# A linter reads; it does not run. See rule 3 in the header above.
		if (line ~ /(^|[^A-Za-z0-9_-])(shellcheck|shfmt)([^A-Za-z0-9_-]|$)/) return

		n = split(line, arr, /[ \t]+/)
		for (i = 1; i <= n; i++) {
			t = arr[i]
			gsub(/^[^A-Za-z0-9_.\/-]+/, "", t)
			gsub(/[^A-Za-z0-9_.\/-]+$/, "", t)
			if (t != "just") continue
			# Skip flags, and the VALUE of a flag that takes one — otherwise
			# `just --justfile X recipe` reports the recipe as `--justfile`.
			j = i + 1
			while (j <= n) {
				u = arr[j]
				gsub(/^[^A-Za-z0-9_.\/=-]+/, "", u)
				gsub(/[^A-Za-z0-9_.\/=-]+$/, "", u)
				if (u !~ /^-/) break
				if (u == "-f" || u == "--justfile" || u == "-d" ||
					u == "--working-directory" || u == "--set") j++
				j++
			}
			if (j > n) continue
			u = arr[j]
			gsub(/^[^A-Za-z0-9_-]+/, "", u)
			gsub(/[^A-Za-z0-9_-]+$/, "", u)
			if (u ~ /^[A-Za-z0-9_][A-Za-z0-9_-]*$/) print "J " u
		}

		rest = line
		while (match(rest, /[A-Za-z0-9_.\/-]*[A-Za-z0-9_-]\.sh/)) {
			print "S " substr(rest, RSTART, RLENGTH)
			rest = substr(rest, RSTART + RLENGTH)
		}
	}
	'
}

# ---------------------------------------------------------------------------
# The justfile, read as a GRAPH rather than as a root.
# ---------------------------------------------------------------------------
# A recipe is reached when a workflow calls it, or when a reached recipe depends
# on it, or when a reached script calls it. Only THEN does what it invokes count.
#
# Emitted as two flat, tab-separated tables rather than shell variables, because
# bash 3.2 has no associative array and `just` has 208 recipes here.
#
#     ${tmp}/bodies   NAME <tab> one body line
#     ${tmp}/deps     NAME <tab> one dependency name
#
# The header grammar this reads: an unindented line whose first token is the
# recipe name, optional parameters, then `:` and optional dependencies. `:=` is
# an assignment, not a recipe, and dependencies may carry `(args)` or be joined
# by `&&` for post-dependencies — all stripped. The body is every following line
# that is indented or blank, up to the next unindented non-blank line.
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
: >"${tmp}/bodies"
: >"${tmp}/deps"
justfile=""
[ -f justfile ] && justfile="justfile"
[ -z "${justfile}" ] && [ -f Justfile ] && justfile="Justfile"
recipe_count=0
if [ -n "${justfile}" ]; then
	awk -v bodies="${tmp}/bodies" -v deps="${tmp}/deps" '
	/^[ \t]/  { if (name != "") print name "\t" $0 >> bodies; next }
	/^[ \t]*$/ { next }
	{
		name = ""
		if ($0 !~ /:=/ && $0 ~ /^@?[A-Za-z0-9_][A-Za-z0-9_-]*([ \t][^:]*)?:/) {
			hdr = $0
			sub(/^@/, "", hdr)
			split(hdr, h, ":")
			split(h[1], hn, /[ \t]/)
			name = hn[1]
			if (name == "set" || name == "alias" || name == "export" ||
				name == "import" || name == "mod") { name = ""; next }
			d = substr(hdr, index(hdr, ":") + 1)
			gsub(/\(/, " ", d); gsub(/\)/, " ", d); gsub(/&&/, " ", d)
			gsub(/{{[^}]*}}/, " ", d)
			nd = split(d, da, /[ \t]+/)
			for (i = 1; i <= nd; i++)
				if (da[i] ~ /^[A-Za-z0-9_][A-Za-z0-9_-]*$/)
					print name "\t" da[i] >> deps
			print name "\t" >> bodies
		}
	}
	' "${justfile}"
	recipe_count="$(cut -f1 "${tmp}/bodies" | sort -u | grep -c . || true)"
fi

# ---------------------------------------------------------------------------
echo "Step 2: reachability from the roots, through recipes and script-to-script"
# ---------------------------------------------------------------------------
note "the justfile defines ${recipe_count} recipe(s); a recipe counts only once a lane calls it"
printf '%s\n' "${gates}" >"${tmp}/universe"
# basename <tab> path, so a reference can be resolved without an assoc array.
awk -F/ '{ print $NF "\t" $0 }' "${tmp}/universe" >"${tmp}/index"

# `resolve` — reference tokens on stdin, universe paths on stdout.
#
# A token carrying a directory wins over a bare basename: `ci/lint/nix.sh`
# resolves to that file alone, while a bare `nix.sh` cannot tell `ci/build/nix.sh`
# from `ci/lint/nix.sh` and credits both. That is the false-POSITIVE direction
# for exactly two basenames in this tree, and it is the safe one — a guard that
# invents dark gates gets switched off.
resolve() {
	awk -F'\t' '
	NR == FNR { n[$1]++; p[$1, n[$1]] = $2; next }
	{
		tok = $0; sub(/^\.\//, "", tok)
		b = tok; sub(/.*\//, "", b)
		if (!(b in n)) next
		found = 0
		if (tok ~ /\//)
			for (i = 1; i <= n[b]; i++) {
				q = p[b, i]
				if (q == tok || index(q, "/" tok) == length(q) - length(tok)) {
					print q; found = 1
				}
			}
		if (!found) for (i = 1; i <= n[b]; i++) print p[b, i]
	}
	' "${tmp}/index" -
}

# `body_of RECIPE` / `deps_of RECIPE` — the two tables, read back.
body_of() { awk -F'\t' -v r="$1" '$1 == r { print substr($0, length(r) + 2) }' "${tmp}/bodies"; }
deps_of() { awk -F'\t' -v r="$1" '$1 == r { print $2 }' "${tmp}/deps"; }

# TWO WORKLISTS, because the graph has two kinds of node. Files and recipes are
# not interchangeable: a recipe's outgoing edges come from its body AND its
# dependency list, a file's only from its text.
: >"${tmp}/reached"
: >"${tmp}/rreached"
: >"${tmp}/fq"
: >"${tmp}/rq"

: >"${tmp}/missing-recipes"
cut -f1 "${tmp}/bodies" | sort -u >"${tmp}/recipe-names"

# `absorb` — reference lines (`S tok` / `J recipe`) on stdin; enqueue what is new.
# One `resolve` per CALLER, not per token: resolving token-at-a-time made this a
# few thousand awk processes and thirty seconds.
absorb() {
	local r
	cat >"${tmp}/refs"
	grep '^S ' "${tmp}/refs" | cut -c3- | resolve | sort -u >"${tmp}/refs.s"
	grep '^J ' "${tmp}/refs" | cut -c3- | sort -u >"${tmp}/refs.j"
	while read -r r; do
		[ -n "${r}" ] || continue
		grep -Fxq -- "${r}" "${tmp}/reached" && continue
		printf '%s\n' "${r}" >>"${tmp}/reached"
		printf '%s\n' "${r}" >>"${tmp}/fq"
	done <"${tmp}/refs.s"
	while read -r r; do
		[ -n "${r}" ] || continue
		if grep -Fxq -- "${r}" "${tmp}/recipe-names"; then
			grep -Fxq -- "${r}" "${tmp}/rreached" && continue
			printf '%s\n' "${r}" >>"${tmp}/rreached"
			printf '%s\n' "${r}" >>"${tmp}/rq"
		else
			# `just <name>` for a recipe THIS justfile does not define. Recorded
			# but not reported: see step 4 for why it cannot be treated as rot.
			# What matters here is that it confers no reachability.
			printf '%s\n' "${r}" >>"${tmp}/missing-recipes"
		fi
	done <"${tmp}/refs.j"
}

printf '%s\n' "${roots}" | grep -v '^$' | refs_in | absorb
seeded="$(grep -c . "${tmp}/reached" || true)"
seeded_recipes="$(grep -c . "${tmp}/rreached" || true)"

if [ "${seeded}" -ge 1 ]; then
	ok "the workflows name ${seeded} script(s) and ${seeded_recipes} recipe(s) directly"
else
	bad "no workflow names any script under ${gate_dirs} — either CI runs none of them, or this scan cannot see them"
fi

# Alternate between the two queues until both are empty.
while [ -s "${tmp}/fq" ] || [ -s "${tmp}/rq" ]; do
	if [ -s "${tmp}/fq" ]; then
		cur="$(head -1 "${tmp}/fq")"
		tail -n +2 "${tmp}/fq" >"${tmp}/fq.next" && mv "${tmp}/fq.next" "${tmp}/fq"
		printf '%s\n' "${cur}" | refs_in | absorb
	else
		cur="$(head -1 "${tmp}/rq")"
		tail -n +2 "${tmp}/rq" >"${tmp}/rq.next" && mv "${tmp}/rq.next" "${tmp}/rq"
		{
			body_of "${cur}" | refs_of_text
			deps_of "${cur}" | sed 's/^/J /'
		} | absorb
	fi
done

reachable="$(sort -u "${tmp}/reached")"
reachable_count="$(printf '%s\n' "${reachable}" | grep -c . || true)"
reached_recipes="$(sort -u "${tmp}/rreached" | grep -c . || true)"
note "a CI lane reaches ${reached_recipes} of ${recipe_count} recipe(s)"
note "reachable after the transitive walk: ${reachable_count} of ${gate_count}"
echo

# ---------------------------------------------------------------------------
echo "Step 3: every gate is reachable, or declares why it is not"
# ---------------------------------------------------------------------------
# The inventory of gates known to be dark. Read once; see the file's header for
# why it exists and why it is not an exemption list.
known_dark_file="${gate_home}/shell-gate-coverage.known-dark.txt"
known_dark=""
if [ -f "${known_dark_file}" ]; then
	known_dark="$(grep -vE '^[[:space:]]*(#|$)' "${known_dark_file}" || true)"
fi
known_dark_count="$(printf '%s\n' "${known_dark}" | grep -c . || true)"

# THE CEILING, AND WHY IT IS AN EQUALITY.
#
# The inventory below is an exception list, and an exception list that can grow
# quietly stops being read: the cheapest way to make this guard green has always
# been to append a line, and nothing objected. The file now carries its own
# length as a directive:
#
#     # RECORDED-DARK-CEILING: <n>
#
# and this guard fails unless the number of entries EQUALS it. Not `<=`. A
# ceiling with slack under it is a budget for new dark gates, and the whole
# argument for this file is that a hole must be impossible to add silently.
#
# Both directions are deliberate. Recording a NEW dark gate means editing the
# ceiling upward in the same diff, where a reviewer sees it. WIRING one up means
# editing it downward — and the resurrection check below already forces the line
# to be deleted, so the ratchet tightens itself and cannot be left slack.
ceiling=""
if [ -f "${known_dark_file}" ]; then
	ceiling="$(grep -E '^[[:space:]]*#[[:space:]]*RECORDED-DARK-CEILING:' "${known_dark_file}" |
		head -1 | sed 's/.*RECORDED-DARK-CEILING:[[:space:]]*//' | tr -dc '0-9')"
fi
if [ -z "${ceiling}" ]; then
	bad "${known_dark_file} declares no '# RECORDED-DARK-CEILING: <n>' — the list could grow unwatched"
elif [ "${known_dark_count}" -gt "${ceiling}" ]; then
	bad "${known_dark_file} records ${known_dark_count} gate(s), ceiling is ${ceiling} — a NEW dark gate was recorded; raise the ceiling in the same diff, deliberately"
elif [ "${known_dark_count}" -lt "${ceiling}" ]; then
	bad "${known_dark_file} records ${known_dark_count} gate(s), ceiling is still ${ceiling} — lower it to ${known_dark_count}; a ratchet with slack is a budget"
else
	ok "the recorded-dark inventory is at its ceiling of ${ceiling}: it can only shrink"
fi
# PRINTED, because it is not the same number as `listed_dark` below and the
# difference is the interesting part: this counts INVENTORY LINES, while
# `listed_dark` counts gates that are actually dark and recorded. They diverge
# when a line names a gate that no longer exists, or names one that has since
# been wired up — the two rots the checks below catch by name. It was computed
# and dropped on the floor, which made that divergence invisible in the log.
note "${known_dark_file} records ${known_dark_count} gate(s)"

dark=0
listed_dark=0
resurrected=0
declared=0
for g in ${gates}; do
	# The repo-relative path IS the identity, in the inventory as in the walk.
	b="${g}"
	has_marker=0
	# A HERE-STRING, FOR THE REASON THIS FILE ALREADY SPELLS OUT AT `in_set`.
	# `producer | grep -q` under `set -uo pipefail` reports FALSE FOR A MATCH
	# THAT IS PRESENT: `grep -q` exits at the first hit, the producer takes
	# EPIPE, and pipefail hands the pipeline the producer's failure. Forty
	# lines of `head` will rarely fill a pipe buffer, so this site would have
	# lied only occasionally — which is worse than always, not better.
	head_lines="$(head -n "${MARKER_SCAN_LINES}" "${g}" 2>/dev/null)"
	if grep -qF -- "${MARKER}" <<<"${head_lines}"; then
		has_marker=1
	fi
	is_known_dark=0
	if in_set "${b}" "${known_dark}"; then is_known_dark=1; fi

	if in_set "${b}" "${reachable}"; then
		if [ "${has_marker}" -eq 1 ]; then
			# CONTRADICTION, the same one the Nim guard checks: a file cannot both
			# be wired up and declare that it is not a gate. One of the two
			# statements is a lie, and which one is a decision, not a default.
			bad "${g} is reachable from CI AND declares '${MARKER}' — one of the two is wrong"
		fi
		if [ "${is_known_dark}" -eq 1 ]; then
			# THE OTHER DIRECTION. Somebody wired this gate up; the inventory now
			# describes a hole that has been filled, and an inventory that only
			# fails upward quietly comes to describe a repository that no longer
			# exists.
			resurrected=$((resurrected + 1))
			bad "${b} is listed in ${known_dark_file} and IS now reachable — delete that line"
		fi
		continue
	fi

	if [ "${has_marker}" -eq 1 ]; then
		declared=$((declared + 1))
		# Same shape, same fix: the trailing `head -1` closes the pipe on
		# `grep`, so a file declaring the marker twice would EPIPE here.
		# `${head_lines}` is already in hand from the marker test above.
		reason="$(grep -F -- "${MARKER}" <<<"${head_lines}" |
			sed -e '1!d' -e "s/.*${MARKER}[[:space:]]*//")"
		if [ -n "${reason}" ]; then
			note "${g}: not a CI gate — ${reason}"
		else
			bad "${g} declares '${MARKER}' with no reason after it"
		fi
		continue
	fi

	if [ "${is_known_dark}" -eq 1 ]; then
		listed_dark=$((listed_dark + 1))
		note "${g}: DARK, and recorded in ${known_dark_file}"
		continue
	fi

	dark=$((dark + 1))
	bad "${g} is reachable from NO workflow lane, NO recipe a lane calls, and NO other reachable script"
done

# An inventory naming a gate that no longer exists is rot of the same kind.
while read -r b; do
	[ -n "${b}" ] || continue
	if [ ! -f "${b}" ]; then
		bad "${known_dark_file} names ${b}, which does not exist"
	fi
done <<EOF
${known_dark}
EOF

if [ "${dark}" -eq 0 ] && [ "${resurrected}" -eq 0 ]; then
	ok "every gate is reachable, declared not-a-gate, or recorded as dark (${listed_dark} recorded)"
fi
echo

# ---------------------------------------------------------------------------
echo "Step 4: nothing CI reaches names a script or a recipe that does not exist"
echo "    A step invoking a missing script fails loudly — but only if that"
echo "    workflow runs, and a step behind an \`if:\` may not for months."
# ---------------------------------------------------------------------------
# THE SUBJECT IS THE WORKFLOWS AND THE LINT DISPATCHERS, AND NOT EVERY REACHABLE
# SCRIPT. Widening it to the whole reachable set was tried and produced five
# findings, all five false, in two flavours that are worth naming because both
# look exactly like rot:
#
#   * CONTRACT SUITES STAGE SYNTHETIC TREES. `shell-gate-coverage-test.sh`
#     writes `ci/test/gate11.sh` and `ci/lint/sh.sh` into a mktemp directory;
#     `python-version-alignment-test.sh` writes `ci/test/some-smoke.sh`. Reading
#     a fixture's filename as CI's step list is the same category error this
#     whole guard exists to name, one directory further in.
#   * SIBLING REPOSITORIES HAVE THE SAME LAYOUT. `visual-replay-gate.sh` runs
#     `./scripts/install-native-replay-companion.sh` inside a heredoc, after
#     `cd "$VISUAL_REPLAY_REPO"`. The path is real; it is just not ours.
#
# `.github/workflows/*` and `ci/lint/*.sh` are where CI's step list is actually
# written, and neither writes fixtures. That is the whole of the subject.
#
# NOT CHECKED, DELIBERATELY: `just <recipe>` against the recipes this justfile
# defines. It was tried and every one of its twenty-odd findings was false. Half
# were English — `just the`, `just an`, `just for`, `just continue` — and the
# other half were siblings' recipes called after a `cd`: `just build-ct-mcr` and
# `just build-extension` are codetracer-native-recorder's and
# codetracer-ruby-recorder's. There is no way to tell those from a typo without
# knowing which repository the shell is standing in, so this guard does not
# pretend to. Unknown recipe names still do not confer reachability, which is
# the half that can be answered.
rot=0
while read -r n; do
	[ -n "${n}" ] || continue
	# Only tokens that CLAIM a path under the scanned trees: a bare `build.sh`
	# in a workflow may be some other repository's, and is not this guard's
	# business.
	case "${n}" in
	ci/*.sh | scripts/*.sh) ;;
	*) continue ;;
	esac
	if [ ! -f "${n}" ]; then
		rot=$((rot + 1))
		bad "a CI-reachable file names ${n}, which does not exist"
	fi
done <<EOF
$({
	printf '%s\n' "${roots}" | grep -v '^$'
	printf '%s\n' "${reachable}" | grep -v '^$' | grep '^ci/lint/'
} | refs_in | grep '^S ' | cut -c3- | sed 's#^\./##' | sort -u)
EOF

if [ "${rot}" -eq 0 ]; then
	ok "every ci/ and scripts/ path a workflow or a lint dispatcher names exists"
fi
echo

# ---------------------------------------------------------------------------
echo "${checks} check(s), ${failures} failure(s)"
echo "  gates: ${gate_count} found, ${reachable_count} reachable, ${declared} declared not-a-gate,"
echo "         ${listed_dark} recorded dark, ${dark} UNRECORDED dark"
if [ "${failures}" -gt 0 ]; then
	echo "RESULT: FAILED — ${failures} check(s)"
	exit 1
fi
echo "  Every shell script under ci/ and scripts/ is reached by a workflow lane,"
echo "  declares in its own header that it is not a gate, or is recorded as dark"
echo "  with a reason, in a list that can only shrink."
echo "  NOT claimed: that any of them passes, or that a reachable gate is actually"
echo "  RUN — a step behind a false \`if:\` is reachable and never executes. This"
echo "  guard measures the graph, which is strictly less than the schedule."
echo "RESULT: OK"
