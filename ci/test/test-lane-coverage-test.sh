#!/usr/bin/env bash
#
# test-lane-coverage-test.sh — the contract suite for ci/test/test-lane-coverage.sh.
#
# WHY THIS EXISTS
# ---------------
# The coverage guard's entire value is that it goes RED when a test-shaped file
# matches no lane. A guard nobody has watched fail is not evidence — it is a
# script that has only ever been observed printing "OK", which is precisely the
# shape of the bug it exists to catch one level down. So this suite drives it
# against synthetic inputs and asserts, by name, that each of its three checks
# fires:
#
#   1. DARK       — a test-shaped file no lane claims must be named and must
#                   fail the run.
#   2. ROT        — a lane entry with no file on disk must be named and must
#                   fail the run.
#   3. CONTRADICTION — a file that is both in a lane and marked not-a-test must
#                   be named and must fail the run.
#
# and that the two exclusion mechanisms actually silence a file:
#
#   4. per-file `## NOT-A-TEST-LANE-FILE: <reason>` header marker
#   5. per-directory `.not-a-test-lane` marker
#   6. an EMPTY marker must NOT silence anything — a reason is mandatory.
#
# It runs in seconds, needs no Nim toolchain and no sibling repos, so it lives
# in the lint stage next to the guard itself.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="${repo_root}/ci/test/test-lane-coverage.sh"

failures=0
checks=0

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# run_guard ROOT FILES_LIST LANE_LIST — runs the guard against a synthetic
# tree; prints its combined output; returns the guard's exit status.
run_guard() {
	local root="$1" files="$2" lanes="$3"
	bash "${guard}" --root "${root}" --files-from "${files}" \
		--lane-files-from "${lanes}" 2>&1
}

# expect NAME EXPECTED_STATUS ACTUAL_STATUS OUTPUT [MUST_CONTAIN...]
expect() {
	local name="$1" want_status="$2" got_status="$3" output="$4"
	shift 4
	checks=$((checks + 1))
	local ok=1
	if [ "${got_status}" != "${want_status}" ]; then
		ok=0
		echo "  [FAILED] ${name}: expected exit ${want_status}, got ${got_status}"
	fi
	local needle
	for needle in "$@"; do
		if ! grep -qF -- "${needle}" <<<"${output}"; then
			ok=0
			echo "  [FAILED] ${name}: output did not mention '${needle}'"
		fi
	done
	if [ "${ok}" -eq 1 ]; then
		echo "  [OK] ${name}"
	else
		failures=$((failures + 1))
		printf '%s\n' "${output}" | sed 's/^/        | /'
	fi
}

echo "=== ci/test/test-lane-coverage.sh contract suite ==="

# ---------------------------------------------------------------------------
# Fixture tree
# ---------------------------------------------------------------------------
tree="${work}/tree"
mkdir -p "${tree}/src/covered" "${tree}/src/dark" "${tree}/src/marked" \
	"${tree}/src/fixtures/deep" "${tree}/src/empty-marker"

echo 'discard' >"${tree}/src/covered/wired_test.nim"
echo 'discard' >"${tree}/src/dark/forgotten_test.nim"

cat >"${tree}/src/marked/helper_test.nim" <<'EOF'
## NOT-A-TEST-LANE-FILE: a fixture, kept for the reason spelled out here.
discard
EOF

echo 'discard' >"${tree}/src/fixtures/deep/test_sample.nim"
echo 'sample projects the discovery suite points at' \
	>"${tree}/src/fixtures/.not-a-test-lane"

echo 'discard' >"${tree}/src/empty-marker/test_thing.nim"
: >"${tree}/src/empty-marker/.not-a-test-lane"

# ---------------------------------------------------------------------------
# 1. DARK — the headline case, and the red-before this suite exists to show
# ---------------------------------------------------------------------------
printf '%s\n' src/covered/wired_test.nim src/dark/forgotten_test.nim >"${work}/files"
printf '%s\n' src/covered/wired_test.nim >"${work}/lanes"
out="$(run_guard "${tree}" "${work}/files" "${work}/lanes")"
status=$?
expect "a test-shaped file in no lane fails the guard, by name" \
	1 "${status}" "${out}" \
	"src/dark/forgotten_test.nim" \
	"are run by NO lane"

# ---------------------------------------------------------------------------
# 2. ROT — a lane entry whose file was deleted or renamed
# ---------------------------------------------------------------------------
printf '%s\n' src/covered/wired_test.nim >"${work}/files"
printf '%s\n' src/covered/wired_test.nim src/covered/renamed_away_test.nim >"${work}/lanes"
out="$(run_guard "${tree}" "${work}/files" "${work}/lanes")"
status=$?
expect "a lane entry with no file on disk fails the guard, by name" \
	1 "${status}" "${out}" \
	"src/covered/renamed_away_test.nim" \
	"named by a lane do not exist"

# ---------------------------------------------------------------------------
# 3. CONTRADICTION — in a lane AND declared not-a-test
# ---------------------------------------------------------------------------
printf '%s\n' src/marked/helper_test.nim >"${work}/files"
printf '%s\n' src/marked/helper_test.nim >"${work}/lanes"
out="$(run_guard "${tree}" "${work}/files" "${work}/lanes")"
status=$?
expect "a file both in a lane and marked not-a-test fails the guard" \
	1 "${status}" "${out}" \
	"src/marked/helper_test.nim" \
	"BOTH in a lane and declared not-a-test"

# ---------------------------------------------------------------------------
# 4. per-file marker silences a file
# ---------------------------------------------------------------------------
printf '%s\n' src/covered/wired_test.nim src/marked/helper_test.nim >"${work}/files"
printf '%s\n' src/covered/wired_test.nim >"${work}/lanes"
out="$(run_guard "${tree}" "${work}/files" "${work}/lanes")"
status=$?
expect "a per-file NOT-A-TEST-LANE-FILE marker is accepted, with its reason" \
	0 "${status}" "${out}" \
	"a fixture, kept for the reason spelled out here" \
	"declares why it is not"

# ---------------------------------------------------------------------------
# 5. per-directory marker silences a whole tree
# ---------------------------------------------------------------------------
printf '%s\n' src/covered/wired_test.nim src/fixtures/deep/test_sample.nim >"${work}/files"
printf '%s\n' src/covered/wired_test.nim >"${work}/lanes"
out="$(run_guard "${tree}" "${work}/files" "${work}/lanes")"
status=$?
expect "a .not-a-test-lane directory marker covers files below it" \
	0 "${status}" "${out}" \
	"src/fixtures/.not-a-test-lane"

# ---------------------------------------------------------------------------
# 6. an EMPTY marker silences nothing — the reason is the point
# ---------------------------------------------------------------------------
printf '%s\n' src/covered/wired_test.nim src/empty-marker/test_thing.nim >"${work}/files"
printf '%s\n' src/covered/wired_test.nim >"${work}/lanes"
out="$(run_guard "${tree}" "${work}/files" "${work}/lanes")"
status=$?
expect "a .not-a-test-lane with no reason does NOT silence a file" \
	1 "${status}" "${out}" \
	"src/empty-marker/test_thing.nim"

# ---------------------------------------------------------------------------
# 7. the CONTENT arm: a real suite whose name hides it
# ---------------------------------------------------------------------------
mkdir -p "${tree}/src/misnamed"
cat >"${tree}/src/misnamed/verify_foo.nim" <<'EOF'
import std/unittest
suite "named nothing like a test":
  test "and therefore invisible to a name-only rule":
    check true
EOF
# The content arm only runs on the git-backed enumeration path (there is no
# file list to take it from otherwise), so this fixture must be a real repo.
git -C "${tree}" init -q 2>/dev/null
git -C "${tree}" add -A 2>/dev/null
printf '%s\n' src/covered/wired_test.nim >"${work}/lanes"
out="$(bash "${guard}" --root "${tree}" --lane-files-from "${work}/lanes" 2>&1)"
status=$?
expect "a unittest suite whose NAME hides it is still caught" \
	1 "${status}" "${out}" \
	"src/misnamed/verify_foo.nim"

# ...and a .nim file that merely mentions the words is NOT swept in.
cat >"${tree}/src/misnamed/helper.nim" <<'EOF'
## Talks about unittest, suite and test, but declares none.
proc describe*(): string = "suite \"x\": test \"y\""
EOF
git -C "${tree}" add -A 2>/dev/null
out="$(bash "${guard}" --root "${tree}" --lane-files-from "${work}/lanes" 2>&1)"
expect "a helper that only mentions the words is not swept in" \
	1 1 "${out}"
if grep -qF 'src/misnamed/helper.nim' <<<"${out}"; then
	echo "  [FAILED] helper.nim was wrongly classified as a test"
	failures=$((failures + 1))
fi
rm -rf "${tree}/src/misnamed"

# ---------------------------------------------------------------------------
# 8. a repo-root directory marker is refused outright
# ---------------------------------------------------------------------------
: >"${tree}/${DIR_MARKER:-.not-a-test-lane}"
printf '%s\n' src/covered/wired_test.nim src/dark/forgotten_test.nim >"${work}/files"
printf '%s\n' src/covered/wired_test.nim >"${work}/lanes"
out="$(run_guard "${tree}" "${work}/files" "${work}/lanes")"
status=$?
expect "a repo-root .not-a-test-lane is refused, not honoured" \
	2 "${status}" "${out}" \
	"would exempt the whole"
rm -f "${tree}/.not-a-test-lane"

# ---------------------------------------------------------------------------
# 9. the all-green case still reports green
# ---------------------------------------------------------------------------
printf '%s\n' src/covered/wired_test.nim >"${work}/files"
printf '%s\n' src/covered/wired_test.nim >"${work}/lanes"
out="$(run_guard "${tree}" "${work}/files" "${work}/lanes")"
status=$?
expect "a fully covered tree passes" \
	0 "${status}" "${out}" \
	"OK: every test-shaped Nim file"

echo ""
if [ "${failures}" -eq 0 ]; then
	echo "test-lane-coverage contract: ${checks} check(s) passed"
	exit 0
fi
echo "test-lane-coverage contract: ${failures} of ${checks} check(s) FAILED" >&2
exit 1
