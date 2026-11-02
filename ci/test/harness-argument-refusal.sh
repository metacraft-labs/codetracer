#!/usr/bin/env bash
# harness-argument-refusal.sh — every mutation harness REFUSES an argument it
# does not know, before it touches a file.
#
# The harnesses under `src/**/run-plat*-mutations.py` edit the product's
# sources in place, one arm at a time, and restore them afterwards. Several of
# them used to DROP an unrecognised flag and carry on: `wanted = [a for a in
# argv if not a.startswith("-")]` turned `--only=A,B` or `--derive` into "no
# arm filter", i.e. a FULL grading run, and `run-plat16-mutations.py` did the
# same with `--needle-scan`. Twice that cost a review: a run nobody asked for,
# mutating files while other suites read them, and once leaving mutations
# behind when it was interrupted.
#
# The ARM IDS a run is narrowed to are the other half of the command line: an
# id no arm carries, or an empty `--only=` (which some harnesses read as "no
# filter" — every arm), is refused the same way, by the shared rule every
# harness applies first (`ci/lib/harness_guard.py`).
#
# For every harness this runs it with each of four refusable command lines —
# a flag no harness accepts, `--only=` naming an undeclared arm, a positional
# undeclared arm, and an empty `--only=` — and asserts:
#   * it exits 2 (argparse's own code for a usage error, which the hand-rolled
#     parsers now use too),
#   * it says so ("unknown argument", argparse's "unrecognized arguments", or
#     the guard's "no such arm"),
#   * it returns quickly (it refused rather than started a grading run), and
#   * the working tree is byte-for-byte what it was.
#
# The harness list is DISCOVERED, not written here, and its size is printed,
# so a new harness is covered the day it lands and a discovery that finds
# nothing fails rather than passing vacuously.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}" || exit 1

python3_bin="$(command -v python3 || true)"
[ -n "${python3_bin}" ] || {
	echo "FAIL: python3 is not on PATH" >&2
	exit 1
}

# THE GUARD'S OWN CONTRACT FIRST: a guard that let every arm id through would
# make the arm-id probes below pass for the wrong reason.
python3 ci/lib/harness_guard.py || {
	echo "FAIL: ci/lib/harness_guard.py does not refuse what it must" >&2
	exit 1
}

# THE DISCOVERY IS GENERAL, AND ANY EXEMPTION IS NAMED, COUNTED AND FROZEN.
#
# It was `run-plat*mutations*.py` alone, which was a statement about the only
# naming scheme that existed when it was written. The first harness named after
# anything else — `run-wd7-session-allocation-mutations.py` — was therefore
# exempt from this probe BY ACCIDENT, which is the shape this whole script
# exists to refuse.
#
# Naming a second prefix would have fixed that one case and left the accident
# in place for the next harness, so the rule is inverted instead: **discover
# every `run-*mutations*.py` and subtract an explicit list.** A new harness is
# now covered on the day it lands, whatever it is called, which is the property
# the narrow glob could not have.
#
# **An exemption is a real defect in that harness, not in this rule.**
# Widening the discovery brought in harnesses that did not satisfy this probe:
# they exited 1 rather than 2, or they invoked the compiler BEFORE parsing
# their command line, which is the very ordering this script exists to check.
# Those are theirs to fix — but a discovery rule that turns red for somebody
# else's defect gets reverted rather than fixed, so each one is listed here,
# with its issue, and the list's SIZE is asserted against a written constant.
#
# That constant is what makes this different from the glob it replaces: the
# list cannot grow silently. A newly landed harness that fails this probe makes
# the count assertion fail, and the only ways forward are to fix the harness or
# to add it here deliberately and say why.
#
# **THE LIST IS EMPTY, AND THAT IS WHY IT IS STILL HERE.** It held five
# harnesses — `run-edit-mode-toolbar-mutations.py`,
# `run-noir-edit-persistence-mutations.py`,
# `run-run-control-refusal-mutations.py`, `run-vnm5-mutations.py` and
# `run-vnm5-render-mutations.py`, all under
# `src/frontend/viewmodel/tests/unit/` — and all five now apply
# `ci/lib/harness_guard.py`'s rule before they compile, mutate or spawn
# anything, so every discovered harness is probed. The mechanism stays because
# the next harness that fails this probe has to be listed DELIBERATELY, with
# the constant moved by hand, rather than discovered to be exempt.
#
# Four of those five were the SECOND class and the dangerous one: they dropped
# the unrecognised argument and performed a full, mutating grading run.
# Measured 2026-10-27 in the repo dev shell at `5ab3ed923`,
# `run-run-control-refusal-mutations.py` answered `--no-such-harness-flag`
# with exit 0 after 51 s, printed `RESULT: 5/5 arms killed their own
# assertion`, and changed the working tree while doing it; the other three
# were killed by this probe's 60 s timeout mid-grade and each LEFT A REAL
# MUTATION behind — `run-vnm5-mutations.py` in
# `viewmodels/verification_payload.nim`, `run-vnm5-render-mutations.py` in
# `viewmodels/counterexample_session_vm.nim`, and
# `run-noir-edit-persistence-mutations.py` in `ui/web_project_store.nim`.
# Each harness is named with its own file rather than left to a
# "respectively", because the three files are each reachable from exactly one
# of the three harnesses and an ordering slip here would misattribute all
# three. That is the cost this script exists to refuse.
EXEMPT_EXPECTED=0
# `=()` and not a bare `declare -a`: under `set -u` an array declared without
# an initialiser is UNBOUND, so even `${#EXEMPT_HARNESSES[@]}` aborts.
declare -a EXEMPT_HARNESSES=()

mapfile -t discovered < <(find src ci scripts -name 'run-*mutations*.py' -type f | sort)
harnesses=()
exempted=0
for h in "${discovered[@]}"; do
	skip=0
	# `${arr[@]+"${arr[@]}"}`: expanding an EMPTY array as `"${arr[@]}"` is an
	# unbound-variable error under `set -u` before bash 4.4, and the list being
	# empty is the normal state now. The guarded form expands to nothing and the
	# loop body simply does not run.
	for e in ${EXEMPT_HARNESSES[@]+"${EXEMPT_HARNESSES[@]}"}; do
		[ "${h}" = "${e}" ] && skip=1 && break
	done
	if [ "${skip}" -eq 1 ]; then
		exempted=$((exempted + 1))
	else
		harnesses+=("${h}")
	fi
done
if [ "${exempted}" -ne "${EXEMPT_EXPECTED}" ]; then
	echo "FAIL: ${exempted} of the listed exemptions matched a discovered harness," \
		"expected ${EXEMPT_EXPECTED} — an exemption names a file that has moved or" \
		"gone, so this probe's coverage is not what the list says it is" >&2
	exit 1
fi
if [ "${#EXEMPT_HARNESSES[@]}" -ne "${EXEMPT_EXPECTED}" ]; then
	echo "FAIL: the exemption list holds ${#EXEMPT_HARNESSES[@]} entries but" \
		"EXEMPT_EXPECTED says ${EXEMPT_EXPECTED} — the list grew without the" \
		"constant being moved deliberately" >&2
	exit 1
fi
# AT ZERO EXEMPTIONS THE TWO ASSERTIONS ABOVE BOTH COMPARE 0 WITH 0, which is
# true however broken the subtraction above is — an accounting check that
# cannot fail is the shape this whole script exists to refuse. The property
# with content at ANY list size, zero included, is that every discovered
# harness is accounted for exactly once: probed or exempted, never both and
# never neither.
if [ $((${#harnesses[@]} + exempted)) -ne "${#discovered[@]}" ]; then
	echo "FAIL: ${#discovered[@]} harness(es) discovered, but ${#harnesses[@]} probed" \
		"+ ${exempted} exempted = $((${#harnesses[@]} + exempted)) — the subtraction" \
		"lost or duplicated a harness, so this probe's coverage is not what it" \
		"prints" >&2
	exit 1
fi
echo "discovered ${#discovered[@]} mutation harness(es); ${exempted} exempted by name," \
	"${#harnesses[@]} probed"
if [ "${#harnesses[@]}" -lt 30 ]; then
	echo "FAIL: found ${#harnesses[@]} mutation harnesses; expected at least 30 —" \
		"the discovery is broken, and a check over nothing is not a check" >&2
	exit 1
fi

tree_state() {
	# What a mutating run would change: tracked content and untracked names.
	{
		git diff --no-ext-diff 2>/dev/null
		git status --porcelain=v1 --untracked-files=all 2>/dev/null
	} | sha256sum
}

before="$(tree_state)"
failed=0
probes=(--no-such-harness-flag --only=NO_SUCH_ARM_ZZ NO_SUCH_ARM_ZZ --only=)
stop=0
for h in "${harnesses[@]}"; do
	for probe in "${probes[@]}"; do
		started=$(date +%s)
		out="$(timeout 60 "${python3_bin}" "${h}" "${probe}" 2>&1)"
		rc=$?
		took=$(($(date +%s) - started))
		if [ "${rc}" -ne 2 ]; then
			echo "FAIL: ${h} exited ${rc} on '${probe}' (want 2)"
			printf '%s\n' "${out}" | tail -5 | sed 's/^/      /'
			failed=$((failed + 1))
		elif ! printf '%s\n' "${out}" |
			grep -qiE 'unknown argument|unrecognized arguments|no such arm'; then
			echo "FAIL: ${h} exited 2 on '${probe}' without naming what it refused"
			printf '%s\n' "${out}" | tail -5 | sed 's/^/      /'
			failed=$((failed + 1))
		elif [ "${took}" -gt 30 ]; then
			echo "FAIL: ${h} took ${took}s to refuse '${probe}' (it did work before refusing)"
			failed=$((failed + 1))
		fi
		if [ "$(tree_state)" != "${before}" ]; then
			echo "FAIL: ${h} changed the working tree on '${probe}' before refusing"
			git status --porcelain=v1 | head -5 | sed 's/^/      /'
			failed=$((failed + 1))
			stop=1
			break
		fi
	done
	[ "${stop}" -eq 0 ] || break
done

if [ "${failed}" -ne 0 ]; then
	echo "harness-argument-refusal: ${failed} refusal(s) missing over ${#harnesses[@]} harnesses x ${#probes[@]} probes"
	exit 1
fi
echo "harness-argument-refusal: all ${#harnesses[@]} harnesses refuse an unknown flag, an undeclared arm id and an empty --only=, untouched tree"
