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

mapfile -t harnesses < <(find src ci scripts -name 'run-plat*mutations*.py' -type f | sort)
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
