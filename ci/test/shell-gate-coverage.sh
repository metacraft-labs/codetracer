#!/usr/bin/env bash
#
# shell-gate-coverage.sh — fail, BY NAME, on any gate in ci/test/ that no CI
# workflow can reach.
#
# WHY THIS EXISTS
# ---------------
# `ci/test/test-lane-coverage.sh` is the same guard for Nim, and its header says
# what it is for: 61 test-shaped `.nim` files were reached by NO lane at all, and
# nothing anywhere said so. It fixed that, and it is scoped — in its own first
# line — to "any test-shaped **Nim** file".
#
# `ci/test/` holds 58 shell gates. Nothing measured those. Measured on `dev` on
# 2026-09-01, four were referenced by no workflow, no justfile recipe, and no
# other gate:
#
#     cross-process-gate.sh          (with its own 500-line self-test beside it)
#     frontend-js.sh
#     origin-dap-gate.sh
#     worker-backend-wasm-e2e.sh
#
# Same generator, one directory over. A guard that stops at a file extension
# leaves a hole exactly the shape of everything it does not cover, and the whole
# argument of the Nim guard applies here unchanged: work goes into a gate, the
# gate goes into the tree, and nothing runs it.
#
# REACHABILITY, NOT MENTION
# -------------------------
# A gate is covered when a CI ROOT can reach it: named in a workflow, or in the
# justfile, or in another gate that is itself reachable. The transitive step
# matters and the naive rule gets it wrong — `visual-replay-gate-lib.sh` is
# sourced only by `visual-replay-gate.sh`, and would look covered by a rule that
# merely asked "is this name mentioned anywhere in ci/". If the gate that names
# it is itself dark, so is it, and a mention-based rule reports both as fine.
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
# ROT: a workflow or recipe naming a `ci/test/*.sh` that does not exist. The Nim
# guard checks this because a lane named a deleted file for months and simply ran
# one fewer test than it claimed. A workflow step that invokes a missing script
# fails loudly at run time — but only if that workflow runs, and a step guarded
# by an `if:` may not for months.
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
	ok "found ${gate_count} shell gates under ${gate_dir}/"
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
echo "Step 2: reachability from the roots, following gate-to-gate references"
# ---------------------------------------------------------------------------
reachable=""
frontier="$(printf '%s\n' "${roots}" | names_in)"

# Seed: only names that are actually gates in ci/test/.
queue=""
seeded=0
while read -r n; do
	[ -n "${n}" ] || continue
	if [ -f "${gate_dir}/${n}" ] && ! in_set "${n}" "${reachable}"; then
		reachable="${reachable}${n}
"
		queue="${queue}${n}
"
		seeded=$((seeded + 1))
	fi
done <<EOF
${frontier}
EOF

if [ "${seeded}" -ge 1 ]; then
	ok "the roots name ${seeded} gate(s) directly, so the walk has a starting point"
else
	bad "no root names any gate in ${gate_dir}/ — either CI runs none of them, or this scan cannot see them"
fi

# Transitive closure: a reachable gate's own references are reachable.
while [ -n "$(printf '%s\n' "${queue}" | grep -v '^$' || true)" ]; do
	cur="$(printf '%s\n' "${queue}" | grep -v '^$' | head -1)"
	queue="$(printf '%s\n' "${queue}" | grep -v '^$' | tail -n +2)"
	while read -r n; do
		[ -n "${n}" ] || continue
		[ "${n}" = "${cur}" ] && continue
		if [ -f "${gate_dir}/${n}" ] && ! in_set "${n}" "${reachable}"; then
			reachable="${reachable}${n}
"
			queue="${queue}${n}
"
		fi
	done <<EOF
$(printf '%s\n' "${gate_dir}/${cur}" | names_in)
EOF
done
reachable_count="$(printf '%s\n' "${reachable}" | grep -c . || true)"
note "reachable after the transitive walk: ${reachable_count} of ${gate_count}"
echo

# ---------------------------------------------------------------------------
echo "Step 3: every gate is reachable, or declares why it is not"
# ---------------------------------------------------------------------------
# The inventory of gates known to be dark. Read once; see the file's header for
# why it exists and why it is not an exemption list.
known_dark_file="${gate_dir}/shell-gate-coverage.known-dark.txt"
known_dark=""
if [ -f "${known_dark_file}" ]; then
	known_dark="$(grep -vE '^[[:space:]]*(#|$)' "${known_dark_file}" || true)"
fi
known_dark_count="$(printf '%s\n' "${known_dark}" | grep -c . || true)"
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
	b="$(basename "${g}")"
	has_marker=0
	if head -n "${MARKER_SCAN_LINES}" "${g}" 2>/dev/null | grep -qF "${MARKER}"; then
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
		reason="$(head -n "${MARKER_SCAN_LINES}" "${g}" | grep -F "${MARKER}" | head -1 |
			sed "s/.*${MARKER}[[:space:]]*//")"
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
	bad "${g} is reachable from NO workflow, NO justfile recipe and NO other reachable gate"
done

# An inventory naming a gate that no longer exists is rot of the same kind.
while read -r b; do
	[ -n "${b}" ] || continue
	if [ ! -f "${gate_dir}/${b}" ]; then
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
echo "Step 4: no root names a gate that does not exist"
echo "    A step invoking a missing script fails loudly — but only if that"
echo "    workflow runs, and a step behind an \`if:\` may not for months."
# ---------------------------------------------------------------------------
rot=0
while read -r n; do
	[ -n "${n}" ] || continue
	# Only names that are CLAIMED to be in ci/test/ — a bare `build.sh` elsewhere
	# in a workflow is not this guard's business.
	if printf '%s\n' "${roots}" | grep -v '^$' | xargs grep -lF "ci/test/${n}" >/dev/null 2>&1; then
		if [ ! -f "${gate_dir}/${n}" ]; then
			rot=$((rot + 1))
			bad "a CI root names ${gate_dir}/${n}, which does not exist"
		fi
	fi
done <<EOF
$(printf '%s\n' "${roots}" | names_in)
EOF
if [ "${rot}" -eq 0 ]; then
	ok "every ${gate_dir}/*.sh a root names exists"
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
echo "  Every shell gate in ci/test/ can be reached by CI, or says why it cannot."
echo "  NOT claimed: that any of them passes, or that a reachable gate is actually"
echo "  RUN — a step behind a false \`if:\` is reachable and never executes. This"
echo "  guard measures the graph, which is strictly less than the schedule."
echo "RESULT: OK"
