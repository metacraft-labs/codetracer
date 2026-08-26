#!/usr/bin/env bash
#
# test-lane-coverage.sh — fail, BY NAME, on any test-shaped Nim file that no
# test lane runs.
#
# WHY THIS EXISTS
# ---------------
# This repo's test lanes used to answer "which files do I run?" with
# hand-written lists of paths. A hand-written list omits silently. Measured on
# this tree before this guard existed, 61 test-shaped `.nim` files carrying real
# `suite`/`test` blocks ran in NO lane — including all five
# `src/common/*_test.nim`, among them `trace_index_test.nim`, the M-REC-8
# recording-id identity suite that the artifact store's id decision rests on.
# `src/ct/online_sharing/online_sharing_test.nim` had rotted into a
# non-compiling state, which is exactly what happens to code nothing runs.
#
# Converting lanes to discovery (see ci/lib/test-lane-files.sh) fixes the 61.
# It does not fix the generator: the next test file lands in a directory no
# lane globs, or gets left out of one of the lists that legitimately must stay
# a list, and the class reopens. THIS script is what closes it. It is cheap
# (pure bash + git, no Nim toolchain, no compilation) and it is meant to run in
# CI's lint stage, so the answer arrives in seconds rather than after a build.
#
# THE RULE
# --------
# A file is TEST-SHAPED if it is a `.nim` file tracked by (or newly added to)
# this repository that satisfies EITHER arm:
#
#   NAME  its basename matches one of
#             test_*.nim   *_test.nim   *_tests.nim   tests_*.nim
#
#   CONTENT it imports `unittest` AND declares a top-level `suite` or `test`
#           block, whatever it is called.
#
# The CONTENT arm is not decoration and not a fuzzy heuristic — "imports the
# test framework and declares a case" is what a test IS, and the name is only a
# convention people follow most of the time. Without it the guard shipped a
# hole it could not see: five suites, 72 cases and 176 assertions, in no lane
# and invisible, among them
# `src/tests/gui/tests/integration/real_backend.nim` — a 30-diff-line unrun
# TWIN of `real_backend_test.nim` sitting in the same directory, each holding a
# fix the other never got. A name-only rule cannot find that, because the twin's
# whole problem is its name. `src/frontend/tests/agentic_coding_test_plan.nim`
# (25 cases, edited three days before this guard was written) and the three
# `src/ct_test/**/e2e_*.nim` are the same shape.
#
# The CONTENT arm deliberately looks for a top-level (column-0) `suite`/`test`,
# so a helper module that merely mentions the words, or a provider whose own
# tests live elsewhere, is not swept in.
#
# Enumeration goes through `git ls-files`, which is deliberate on three counts:
# it excludes the vendored third-party sources under `libs/` (git submodules,
# each with its own upstream test runner — their files never appear in this
# repo's index), it excludes recorded example traces that happen to contain
# copies of user source, and it excludes build output. `git ls-files --others
# --exclude-standard` is unioned in so a brand-new file is caught before it is
# staged, not after.
#
# Every test-shaped file must satisfy exactly one of:
#
#   1. It is in a lane — it appears in `test_lane_files <id>` for some lane id
#      declared by ci/lib/test-lane-files.sh.
#
#   2. It DECLARES that it is not a test of this repo, and says why. Two
#      spellings, both committed and both visible in review:
#
#        a. a header comment in the file itself, within its first
#           ${MARKER_SCAN_LINES} lines, of the form
#
#               ## NOT-A-TEST-LANE-FILE: <reason>
#
#        b. a `.not-a-test-lane` file in the file's directory (or in any
#           ancestor directory up to the repo root) whose contents are the
#           reason. This is for whole trees of fixtures, where editing each
#           fixture would change the very thing it is a fixture for.
#
# A fuzzy heuristic was deliberately NOT used. "Looks like a fixture" is how a
# real suite gets skipped by accident; an exclusion has to be written down by a
# human, with a reason a reviewer can disagree with.
#
# The guard also runs two checks in the other direction, because a lane can be
# wrong without any file being dark:
#
#   * ROT: every path a lane names must exist. `scripts/test-codetracer-agentic
#     -headless.sh` named `agent_activity_deepreview_vm_test.nim` for months
#     after that file was deleted and renamed; the lane simply ran one fewer
#     test than it claimed. This check is what makes that loud.
#
#   * CONTRADICTION: a file must not both be in a lane and declare itself not a
#     test. That means someone marked a live suite as excluded, or wired an
#     excluded file into a lane, and either way one of the two statements is a
#     lie.
#
# Usage:
#   ci/test/test-lane-coverage.sh
#   ci/test/test-lane-coverage.sh --root DIR --files-from FILE --lane-files-from FILE
#
# The three overrides exist so ci/test/test-lane-coverage-test.sh can drive the
# checks against synthetic trees without a repo full of real tests. They are not
# used in CI.

set -euo pipefail

# How far into a file the header marker may appear. Deep enough for a real
# module docstring plus a licence header, shallow enough that the marker cannot
# hide in the middle of the file.
MARKER_SCAN_LINES=40

# The one place the "test-shaped" naming rule is written down, as a POSIX ERE
# over the whole repo-relative path. Anchored on `/` or start-of-string so a
# directory named `my_test/` does not make its contents test-shaped.
# Case-insensitive, and `.nims` as well as `.nim`: `Foo_Test.nim` and
# `foo_test.nims` are as invisible to a runner as `foo_test.nim` is, and a rule
# that a rename can slip past is not a rule.  Applied with `grep -Ei`.
TEST_SHAPED_RE='(^|/)(test_[^/]*|[^/]*_test|[^/]*_tests|tests_[^/]*)\.nims?$'

# The CONTENT arm. `looks_like_a_test FILE` returns 0 when the file imports
# unittest and declares a case at column 0 (inside `suite "..."` bodies the
# `test` is indented, so the suite line is what a suite-using file matches).
looks_like_a_test() {
	local f="$1"
	[ -f "${f}" ] || return 1
	case "${f}" in *.nim | *.nims) ;; *) return 1 ;; esac
	grep -qE '^[[:space:]]*import.*\bunittest\b|^[[:space:]]*import[[:space:]]+unittest' "${f}" || return 1
	grep -qE '^(suite|test)[[:space:]]+"' "${f}"
}

# Anchored to a COMMENT line. Without the `^[[:space:]]*#+` an ordinary string
# literal mentioning the marker -- a test ABOUT this guard, say, or a docstring
# quoting it -- would silence the file it appears in. An exclusion has to be a
# statement by the author, not a substring.
MARKER_RE='^[[:space:]]*#+[^"]*NOT-A-TEST-LANE-FILE:[[:space:]]*[^[:space:]]'
DIR_MARKER_NAME='.not-a-test-lane'

root=""
files_from=""
lane_files_from=""

while [ $# -gt 0 ]; do
	case "$1" in
	--root)
		root="$2"
		shift 2
		;;
	--files-from)
		files_from="$2"
		shift 2
		;;
	--lane-files-from)
		lane_files_from="$2"
		shift 2
		;;
	-h | --help)
		sed -n '2,80p' "${BASH_SOURCE[0]}"
		exit 0
		;;
	*)
		echo "test-lane-coverage.sh: unknown argument '$1'" >&2
		exit 2
		;;
	esac
done

if [ -z "${root}" ]; then
	root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
cd "${root}"

# A directory marker AT the repo root is refused, deliberately and loudly: one
# such file would exempt every test in the repository from every check this
# guard makes, from a single line, and no reviewer looking at a diff that adds
# one dotfile would necessarily see that. Scope an exclusion to the tree it is
# about. Checked here, at the top level, because inside the per-file helper it
# would run in a $(...) subshell where `exit` cannot stop the run.
if [ -f "./${DIR_MARKER_NAME}" ]; then
	echo "ERROR: a repo-root ./${DIR_MARKER_NAME} would exempt the whole" \
		"repository from this guard. Put the marker on the specific" \
		"directory it is about instead." >&2
	exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# ---------------------------------------------------------------------------
# Input 1: every test-shaped file
# ---------------------------------------------------------------------------
if [ -n "${files_from}" ]; then
	sort -u "${files_from}" >"${work}/shaped"
else
	{
		git ls-files
		# Untracked-but-not-ignored: a test file written five minutes ago is
		# still a test file that runs nowhere, and waiting for it to be staged
		# before saying so wastes the round trip.
		git ls-files --others --exclude-standard
	} | sort -u >"${work}/tracked"

	# Arm 1: the name.
	grep -Ei "${TEST_SHAPED_RE}" <"${work}/tracked" >"${work}/shaped.name" || true
	# Arm 2: the content. Only .nim files are opened, and only those the name
	# arm did not already claim, so this costs one grep over a few hundred
	# files rather than over the tree.
	: >"${work}/shaped.content"
	while read -r candidate; do
		case "${candidate}" in *.nim | *.nims) ;; *) continue ;; esac
		grep -qxF -- "${candidate}" "${work}/shaped.name" && continue
		if looks_like_a_test "${candidate}"; then
			printf '%s\n' "${candidate}" >>"${work}/shaped.content"
		fi
	done <"${work}/tracked"

	cat "${work}/shaped.name" "${work}/shaped.content" | sort -u >"${work}/shaped"
fi

# ---------------------------------------------------------------------------
# Input 2: every file some lane claims
# ---------------------------------------------------------------------------
if [ -n "${lane_files_from}" ]; then
	sort -u "${lane_files_from}" >"${work}/claimed"
	: >"${work}/lane-report"
else
	# shellcheck source=ci/lib/test-lane-files.sh
	# shellcheck disable=SC1091 # sourced through $root, resolved at runtime
	source "${root}/ci/lib/test-lane-files.sh"
	: >"${work}/lane-report"
	: >"${work}/claimed.raw"
	while read -r lane; do
		[ -n "${lane}" ] || continue
		test_lane_files "${lane}" >"${work}/lane.${lane}"
		printf '%-26s %3d file(s)  %s\n' \
			"${lane}" \
			"$(grep -c . <"${work}/lane.${lane}" || true)" \
			"$(test_lane_description "${lane}")" >>"${work}/lane-report"
		cat "${work}/lane.${lane}" >>"${work}/claimed.raw"
	done < <(test_lane_ids)
	grep -v '^$' <"${work}/claimed.raw" | sort -u >"${work}/claimed"
fi

# ---------------------------------------------------------------------------
# has_exclusion_marker PATH — prints the declared reason, or returns 1
# ---------------------------------------------------------------------------
has_exclusion_marker() {
	local path="$1" dir reason

	if [ -f "${path}" ]; then
		reason="$(head -n "${MARKER_SCAN_LINES}" "${path}" 2>/dev/null |
			grep -E -m1 "${MARKER_RE}" || true)"
		if [ -n "${reason}" ]; then
			# Strip everything up to and including the marker keyword so the
			# report shows the reason rather than the comment syntax.
			printf '%s\n' "${reason#*NOT-A-TEST-LANE-FILE:}" |
				sed 's/^[[:space:]]*//'
			return 0
		fi
	fi

	# Walk up to the repo root looking for a directory marker. (A marker AT
	# the root is refused before we get here — see the top-level check.)
	dir="$(dirname "${path}")"
	while :; do
		if [ -f "${dir}/${DIR_MARKER_NAME}" ]; then
			reason="$(grep -v '^[[:space:]]*$' "${dir}/${DIR_MARKER_NAME}" |
				head -n1 || true)"
			if [ -n "${reason}" ]; then
				printf '%s (declared by %s)\n' "${reason}" \
					"${dir}/${DIR_MARKER_NAME}"
				return 0
			fi
			# A marker file with no reason is not an exclusion. Falling through
			# to "dark" is the point: an empty marker must not silence anything.
			return 1
		fi
		[ "${dir}" = "." ] || [ "${dir}" = "/" ] && break
		dir="$(dirname "${dir}")"
	done
	return 1
}

# ---------------------------------------------------------------------------
# Check A — test-shaped files no lane runs
# ---------------------------------------------------------------------------
: >"${work}/dark"
: >"${work}/excluded"
: >"${work}/contradiction"

while read -r f; do
	[ -n "${f}" ] || continue
	claimed=0
	grep -qxF -- "${f}" "${work}/claimed" && claimed=1
	if reason="$(has_exclusion_marker "${f}")"; then
		if [ "${claimed}" -eq 1 ]; then
			printf '%s\t%s\n' "${f}" "${reason}" >>"${work}/contradiction"
		else
			printf '%s\t%s\n' "${f}" "${reason}" >>"${work}/excluded"
		fi
	elif [ "${claimed}" -eq 0 ]; then
		printf '%s\n' "${f}" >>"${work}/dark"
	fi
done <"${work}/shaped"

# ---------------------------------------------------------------------------
# Check B — paths a lane names that are not on disk
# ---------------------------------------------------------------------------
: >"${work}/rot"
while read -r f; do
	[ -n "${f}" ] || continue
	[ -f "${f}" ] || printf '%s\n' "${f}" >>"${work}/rot"
done <"${work}/claimed"

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
shaped_n=$(grep -c . <"${work}/shaped" || true)
claimed_n=$(grep -c . <"${work}/claimed" || true)
excluded_n=$(grep -c . <"${work}/excluded" || true)
dark_n=$(grep -c . <"${work}/dark" || true)
rot_n=$(grep -c . <"${work}/rot" || true)
contradiction_n=$(grep -c . <"${work}/contradiction" || true)

echo "=== Nim test-lane coverage ==="
if [ -s "${work}/lane-report" ]; then
	cat "${work}/lane-report"
	echo ""
fi
echo "test-shaped files:      ${shaped_n}"
echo "claimed by a lane:      ${claimed_n}"
echo "declared not-a-test:    ${excluded_n}"
echo ""

if [ "${excluded_n}" -gt 0 ]; then
	echo "Declared exclusions (each file says so itself):"
	while IFS=$'\t' read -r f reason; do
		printf '  %s\n      %s\n' "${f}" "${reason}"
	done <"${work}/excluded"
	echo ""
fi

status=0

if [ "${dark_n}" -gt 0 ]; then
	status=1
	echo "ERROR: ${dark_n} test-shaped file(s) are run by NO lane:"
	sed 's/^/  /' <"${work}/dark"
	cat <<EOF

  Every one of these compiles assertions that cannot fail a build. Fix by
  either:
    * putting the file in a lane — preferably by making an existing lane's
      glob in ci/lib/test-lane-files.sh reach it, so the NEXT file is covered
      too; or
    * declaring, in the file itself, that it is not a test of this repo:
          ## NOT-A-TEST-LANE-FILE: <why this is not a test>
      (or a '${DIR_MARKER_NAME}' file in its directory, for a whole fixture tree).

EOF
fi

if [ "${rot_n}" -gt 0 ]; then
	status=1
	echo "ERROR: ${rot_n} path(s) named by a lane do not exist:"
	sed 's/^/  /' <"${work}/rot"
	cat <<'EOF'

  A lane that names a missing file runs one fewer test than it claims to, and
  says nothing about it. Update ci/lib/test-lane-files.sh (and the script that
  mirrors it) to the file's new name, or drop the entry.

EOF
fi

if [ "${contradiction_n}" -gt 0 ]; then
	status=1
	echo "ERROR: ${contradiction_n} file(s) are BOTH in a lane and declared not-a-test:"
	while IFS=$'\t' read -r f reason; do
		printf '  %s\n      declared: %s\n' "${f}" "${reason}"
	done <"${work}/contradiction"
	cat <<'EOF'

  One of the two statements is wrong. Either the file is a real suite (remove
  the marker) or it is not (remove it from the lane).

EOF
fi

if [ "${status}" -eq 0 ]; then
	echo "OK: every test-shaped Nim file is either run by a lane or declares why it is not."
fi

exit "${status}"
