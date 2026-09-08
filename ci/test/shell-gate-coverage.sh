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

# WHERE THE LIBRARY IS, AS OPPOSED TO WHAT IS BEING SCANNED. `root` is the tree
# under examination and `--root` moves it; this is the checkout THIS SCRIPT
# lives in, and nothing moves it. They are the same path in CI and different
# whenever ci/test/shell-gate-coverage-test.sh drives the guard against one of
# its synthetic fixture trees -- which contain a `.github/workflows` and some
# `ci/*.sh` decoys and no `ci/lib` at all. Sourcing the library through `root`
# worked in the repo and made every one of the 22 mutation arms abort with
# `found 0 CI root(s)`, because the failed `source` left `ci_reach_roots`
# undefined and the guard carried on with an empty root list.
gate_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

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
#
# AND THE SUBJECT IS NO LONGER ONLY SHELL, since 2026-09-04. `-name '*.sh'` was
# the third instance of this file's own recurring defect — a dark-gate finder
# that cannot see most of its subject reports a clean sweep of the part it can.
# 43 gates under `ci/` are Node or Python: browser probes driven by Playwright
# (`mode_layout_probe.mjs`, `chord_double_fire_probe.mjs`), guards in pure
# python3 (`frontend-reachability-guard.py`, `macho-closure.py`), and the
# `noir-wasm-worker/` harness. Twelve of the 43 were reachable from nothing, and
# three of those were referenced NOWHERE IN THE REPOSITORY at all — not by a
# workflow, not by a recipe, not by another script, not even by a dark one.
#
# `mode_layout_probe.mjs` is the one worth naming: it measures rendered
# `.lm_title` geometry, which is the exact quantity that went to zero in the
# defect it covers, and nothing has ever run it.
gate_dirs="ci scripts"
gate_exts="sh mjs py"
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
# FILTERED WITH `grep`, NOT WITH `find -name`, AND THIS IS A BUG THAT BIT.
#
# The obvious form builds `-name *.sh -o -name *.mjs` into a string and expands
# it unquoted. `*.sh` IS THEN A GLOB, and this repository has `.sh` files at its
# root — `env.sh`, `build_for_extension.sh`, `install-on-distributions.sh` — so
# the shell expanded the pattern before `find` ever saw it and the whole
# expression became `-name build_for_extension.sh env.sh ...`. `find` rejected
# it, the scan returned ZERO gates, and only Step 0's non-vacuity floor turned
# that into a visible failure rather than a clean sweep of nothing.
#
# Which is Step 0 earning its place: without it this would have printed
# "0 found, 0 reachable, 0 UNRECORDED dark" and exited 0.
#
# `node_modules` is pruned because `ci/test/noir-wasm-worker/` carries one, and a
# vendored dependency is not this repository's gate.
ext_re="$(printf '%s' "${gate_exts}" | tr ' ' '|')"
# shellcheck disable=SC2086
gates="$(find ${gate_find_dirs} \( -name node_modules -o -name .git \) -prune -o \
	-type f -print 2>/dev/null |
	sed 's#^\./##' | grep -E "\.(${ext_re})\$" | sort)"
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

# THIS FLOOR IS THE REASON THE REST OF THIS FILE CAN BE TRUSTED, AND IT HAS NOW
# BEEN PAID FOR ONCE.
#
# It reads like boilerplate. It is not. On 2026-09-04, widening the subject past
# `*.sh` was written as `find_ext_args="-name *.sh"` built into a string and
# expanded unquoted — and `*.sh` IS A GLOB, which this repository matches at its
# root (`env.sh`, `build_for_extension.sh`, `install-on-distributions.sh`). The
# shell expanded the pattern before `find` saw it, the expression became
# `-name build_for_extension.sh env.sh ...`, `find` rejected it, and the scan
# returned ZERO gates.
#
# Zero gates satisfies every check below. Without this floor the run would have
# printed
#
#     gates: 0 found, 0 reachable, 0 declared not-a-gate,
#            0 recorded dark, 0 UNRECORDED dark
#     RESULT: OK
#
# — a perfect score from an instrument that had measured nothing, which is the
# exact defect this whole file exists to report, arriving through its own front
# door. Every "must not contain" check in this script is vacuously true over an
# empty subject.
#
# A guard that can report on nothing will eventually be handed nothing. Keep
# this first, keep it a hard `exit 1`, and do not let its threshold drift down
# to zero. See Verification-Harness-Traps.md trap 6.
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
# The roots, the reference scanner and the reachability walk: ci/lib/ci-reachability.sh
# ---------------------------------------------------------------------------
# They used to be 600 lines of THIS file. They moved out when
# ci/test/test-lane-job-coverage.sh started asking the same question about test
# LANES that this guard asks about shell scripts -- "can a CI lane actually
# reach it?" -- because a second copy of this walk would have agreed with this
# one on the day it was written and drifted from it by the first bugfix applied
# to only one of the two. That is the same failure mode ci/lib/test-lane-files.sh
# exists to have ended for lane FILE selection, one question over.
#
# Nothing about the walk changed in the move, INCLUDING the doctrine that used
# to be written here at length: the workflow files are the only roots, the
# justfile is not a root (seeding from it credited fourteen gates that run in no
# lane), and the ci/lint/*.sh dispatchers are not roots either (they are
# reachable the ordinary way, and if a day comes when no workflow names one,
# this guard should say so rather than assume it). That text moved with the
# code it governs. The 22 checks in ci/test/shell-gate-coverage-test.sh are what
# hold the move honest.
# ---------------------------------------------------------------------------
# Spelled `"${gate_repo_root}/ci/lib/ci-reachability.sh"`, matching the idiom
# ci/lib/run-nim-test-lane.sh already uses, and BOTH halves of that are
# load-bearing.
#
#   * The variable, not `cd`-relative: `--root` repoints the scan at a synthetic
#     tree that has no ci/lib (see gate_repo_root above).
#
#   * The literal `ci/lib/...` tail, not `$(dirname "${BASH_SOURCE[0]}")/../lib/`:
#     this guard's OWN reference scanner resolves a token by basename plus
#     directory suffix, and `../lib/ci-reachability.sh` is not a suffix of
#     `ci/lib/ci-reachability.sh`. Written that way, the refactor's first run
#     reported the new library as a gate reachable from nothing — this guard
#     failing on the file it had just been split into.
# shellcheck source=ci/lib/ci-reachability.sh
# shellcheck disable=SC1091 # resolved at runtime through gate_repo_root
source "${gate_repo_root}/ci/lib/ci-reachability.sh"

roots="$(ci_reach_roots)"
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

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
ci_reach_parse_justfile

# ---------------------------------------------------------------------------
echo "Step 2: reachability from the roots, through recipes and script-to-script"
# ---------------------------------------------------------------------------
note "the justfile defines ${recipe_count} recipe(s); a recipe counts only once a lane calls it"
ci_reach_walk
# What the workflows name DIRECTLY, snapshotted by `ci_reach_walk` between its
# seed and its transitive loop. Reading `${tmp}/reached` here instead would now
# report the post-walk totals, because the seed and the loop are one call.
seeded="$(cat "${tmp}/seeded-scripts")"
seeded_recipes="$(cat "${tmp}/seeded-recipes")"

if [ "${seeded}" -ge 1 ]; then
	ok "the workflows name ${seeded} script(s) and ${seeded_recipes} recipe(s) directly"
else
	bad "no workflow names any script under ${gate_dirs} — either CI runs none of them, or this scan cannot see them"
fi

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
	# THE RULE, STATED WHERE IT REACHES THE PERSON WHO IS WRONG. A gate lands
	# with its recipe and its workflow step, or it does not land. Recording it
	# instead is only legitimate when the gate CANNOT be wired today, and then
	# the entry must name the missing capability rather than say "dark".
	cat >&2 <<-GUIDANCE

		           A gate lands WIRED, or it does not land. Two things are
		           needed and neither is optional:

		             1. a \`just\` recipe that runs it, and
		             2. a step in .github/workflows/codetracer.yml that calls
		                that recipe in a lane which actually runs.

		           Adding it to ${known_dark_file} is NOT the fix, and is
		           only honest in one case: the gate CANNOT be wired today
		           because the capability it needs does not exist in CI yet.
		           Then the entry must NAME that capability and say what
		           would make it green -- as the wasm entries do ("no CI job
		           builds the wasm engine"). "Nobody wired it yet" is not a
		           reason; it is the defect this check reports.

		           If you record it, the ceiling in that file must move up in
		           the SAME diff, where a reviewer sees it.

	GUIDANCE
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
echo '    workflow runs, and a step behind an `if:` may not for months.'
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
	ci/*.sh | scripts/*.sh | ci/*.mjs | scripts/*.mjs | ci/*.py | scripts/*.py) ;;
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
echo '  RUN — a step behind a false `if:` is reachable and never executes. This'
echo "  guard measures the graph, which is strictly less than the schedule."
echo "RESULT: OK"
