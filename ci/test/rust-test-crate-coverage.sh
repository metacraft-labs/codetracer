#!/usr/bin/env bash
#
# rust-test-crate-coverage.sh — fail, BY NAME, on any Rust crate that contains
# test code which no `cargo test` / `cargo nextest` invocation in this
# repository can reach.
#
# WHY THIS EXISTS
# ---------------
# `ci/test/test-lane-coverage.sh` is this repo's orphan detector, and its own
# first line scopes it to "any test-shaped **Nim** file". `ci/test/
# shell-gate-coverage.sh` is the same guard for shell gates. Rust had neither,
# and the assumption that filled the gap — "the lanes enumerate the tests, so a
# test outside a lane is dark" — is not merely untrue for Rust, it is not even
# expressible: Rust tests are never enumerated. They are selected WHOLESALE by
# `cargo test` / `cargo nextest run --test '*'`, with the CRATE as the unit.
#
# That makes the Rust failure mode a different SHAPE from the Nim one, and it is
# invisible to any per-file lane check:
#
#   A CRATE THAT NOTHING EVER RUNS `cargo test` IN IS ENTIRELY DARK, however
#   many #[test] functions it holds, and no per-file rule can see it because
#   the file is never the unit of selection.
#
# Measured on this tree when this gate was written, four crates were in exactly
# that position — 60 `#[test]`/`#[tokio::test]` functions that never execute:
#
#   libs/origin-classifier   20   tests/m1_verification.rs + inline
#   src/codetracer-bench     27   five tests/*.rs; the justfile only ever
#                                 `cargo run`s its ct-bench binary
#   libs/ct-dap-client       10   inline #[cfg(test)]
#   libs/ct-lang              3   inline #[cfg(test)]
#
# None is a Cargo workspace member — each is a plain `path = "..."` dependency —
# so `cargo test` in src/db-backend never reaches them. The crates compile,
# their tests are run by nothing, and every report about them is green by
# omission. That is the same sentence the Nim guard's header opens with, about a
# different language, which is the whole argument for this file existing.
#
# THE RULE
# --------
# A crate is IN SCOPE when its directory holds a `Cargo.toml` and at least one
# `.rs` file carrying `#[test]`, `#[tokio::test]` or `#[cfg(test)]`.
#
# A crate is COVERED when some line in `justfile`, `ci/**`, `scripts/**` or
# `.github/workflows/**` invokes `cargo test` or `cargo nextest run` with that
# crate's directory as the working directory — established by a `cd <dir>` at or
# before the invocation, or a `working-directory: <dir>` in the same step.
#
# A crate this repository deliberately does not test declares it in its own
# `Cargo.toml`, in a comment, within the first ${MARKER_SCAN_LINES} lines:
#
#     # NOT-A-TEST-CRATE: <reason>
#
# The marker lives in Cargo.toml rather than reusing the `.not-a-test-lane`
# directory marker deliberately: that marker is read by the Nim guard, and
# planting one on `examples/` or `test-programs/` to satisfy THIS gate would
# silently change what THAT one sees. A gate must not quiet its own report by
# moving another gate's goalposts.
#
# WHAT THIS CANNOT SEE, STATED PLAINLY
# ------------------------------------
# Coverage here is MENTION of an invocation, not REACHABILITY of the script
# holding it. A `cargo test` in a justfile recipe no CI lane calls counts as
# covered. That is deliberate: reachability is `ci/test/shell-gate-coverage.sh`'s
# question, it already walks workflows -> `just` recipes -> scripts
# transitively, and a weaker second copy of that walk here would give a second,
# disagreeing answer to a question already owned elsewhere. The residue is
# exactly "a crate whose only test invocation sits in an unreachable script",
# and it is bounded by that other gate.
#
# It also cannot see test SELECTION inside a covered crate. `cargo nextest run
# --test '*' -E 'test(~dap)'` (codetracer.yml:1625) builds every integration
# target and then runs 75 of 611 tests. The crate is covered; most of its tests
# are not run by THAT job. Filter-narrowing is real and is NOT this gate's
# question — it is recorded in codetracer-specs/Testing/Known-Test-Failures.md.
#
# SELF-TEST: this gate's contract suite is STEP 0 INSIDE IT, the same shape
# ci/test/grep-q-pipefail-gate.sh uses — the recognition rules are run against
# ci/test/rust-test-crate-coverage.fixture.txt, and the gate refuses to scan the
# tree if any HIT is missed, any MISS fires, any DIR resolves wrong, or the
# fixture is too thin to discriminate. There is deliberately no separate
# `-test.sh`: a self-test that lives in another file is a self-test that can be
# left unrun, which is the failure this whole family of gates exists to catch.
#
# Usage:
#   ci/test/rust-test-crate-coverage.sh
#   ci/test/rust-test-crate-coverage.sh --root DIR   (scan another checkout)

set -uo pipefail

MARKER_SCAN_LINES=40
MARKER_RE='^[[:space:]]*#+[^"]*NOT-A-TEST-CRATE:[[:space:]]*[^[:space:]]'

FIXTURE="ci/test/rust-test-crate-coverage.fixture.txt"
BASELINE="ci/test/rust-test-crate-coverage.known-dark.txt"

# A tree this small cannot be this repository. Scanning it and reporting a clean
# result would be the exact false green this gate exists to prevent.
MIN_CRATES=5
MIN_INVOCATIONS=10

root=""
while [ $# -gt 0 ]; do
	case "$1" in
	--root)
		root="$2"
		shift 2
		;;
	-h | --help)
		sed -n '2,80p' "${BASH_SOURCE[0]}"
		exit 0
		;;
	*)
		echo "rust-test-crate-coverage.sh: unknown argument '$1'" >&2
		exit 2
		;;
	esac
done
if [ -z "${root}" ]; then
	root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
cd "${root}" || exit 2

# ---------------------------------------------------------------------------
# THE TWO RECOGNITION RULES, WRITTEN ONCE.
#
# Both the fixture check and the tree scan run THIS awk source and nothing else.
# An earlier draft implemented them once in bash for the fixture and once in awk
# for the scan; two implementations of one rule drift, and the fixture then
# certifies a detector that is not the one doing the work.
# ---------------------------------------------------------------------------
read -r -d '' AWK_RULES <<'AWKEOF'
# The runner is not always spelled `cargo`: scripts/test-origin-dap.sh and
# scripts/test-cross-process.sh resolve it into a variable and invoke
# `"$cargo_bin" test`. Matching only the literal missed both, and the FIXTURE is
# what said so. `[A-Za-z0-9_]*[}"]?` absorbs the rest of a `"$cargo_bin"` token.
# `cargo run` and `cargo nextest list` must NOT match -- see the MISS rows.
function is_invocation(line) {
  return line ~ /[Cc]argo[A-Za-z0-9_]*[}"]?[ \t]+(\+[^ \t]+[ \t]+)?(test|nextest[ \t]+run)([ \t]|$)/
}

# Returns the working directory a line establishes, or "" for none.
function dir_of_line(line,   s) {
  if (match(line, /working-directory:[ \t]*"?[^"[:space:]]+/)) {
    s = substr(line, RSTART, RLENGTH)
    sub(/^working-directory:[ \t]*"?/, "", s)
  } else if (match(line, /(^|[;&|(]|[ \t])cd[ \t]+"?[^"[:space:]&|;]+/)) {
    s = substr(line, RSTART, RLENGTH)
    sub(/^[;&|( \t]*/, "", s)
    sub(/^cd[ \t]+"?/, "", s)
  } else {
    return ""
  }
  # Normalise the shapes this repo actually writes.
  sub(/^\$REPO_ROOT\//, "", s)
  sub(/^\$\{REPO_ROOT\}\//, "", s)
  sub(/^\$root\//, "", s)
  sub(/^\.\//, "", s)
  return s
}

# A comment that MENTIONS `cargo test` is not a wire. Several gates under
# ci/test/ discuss it at length; counting their prose would invent coverage.
function is_comment(line,   t) {
  t = line
  sub(/^[ \t]+/, "", t)
  return t ~ /^#/
}
AWKEOF

status=0

# ---------------------------------------------------------------------------
# STEP 0 — run both rules against the fixture BEFORE scanning the tree.
# A detector that stopped matching finds no invocations and reports every crate
# dark (loud), or finds no crates and reports a clean tree (silent). The silent
# one is the same class of defect this gate exists to catch.
# ---------------------------------------------------------------------------
if [ ! -f "${FIXTURE}" ]; then
	echo "ERROR: fixture ${FIXTURE} is missing; refusing to scan." >&2
	exit 2
fi

fixture_report="$(awk "${AWK_RULES}"'
BEGIN { FS = "\t"; hit = 0; miss = 0; dir = 0; bad = 0 }
/^[ \t]*#/ { next }
/^[ \t]*$/ { next }
$1 == "HIT" {
  hit++
  if (!is_invocation($2)) { bad++; print "  fixture HIT not detected: " $2 }
  next
}
$1 == "MISS" {
  miss++
  if (is_invocation($2)) { bad++; print "  fixture MISS wrongly detected: " $2 }
  next
}
$1 == "DIR" {
  dir++
  got = dir_of_line($3)
  if (got == "") got = "-"
  if (got != $2) { bad++; print "  fixture DIR mismatch: expected [" $2 "] got [" got "] for: " $3 }
  next
}
END { print "@@FX\t" hit "\t" miss "\t" dir "\t" bad }
' "${FIXTURE}")"

fx_line="$(printf '%s\n' "${fixture_report}" | grep '^@@FX')"
fx_hit="$(printf '%s' "${fx_line}" | cut -f2)"
fx_miss="$(printf '%s' "${fx_line}" | cut -f3)"
fx_dir="$(printf '%s' "${fx_line}" | cut -f4)"
fx_bad="$(printf '%s' "${fx_line}" | cut -f5)"

printf '%s\n' "${fixture_report}" | grep -v '^@@FX' || true

if [ "${fx_hit}" -lt 3 ] || [ "${fx_miss}" -lt 3 ] || [ "${fx_dir}" -lt 4 ]; then
	echo "ERROR: fixture is too thin (${fx_hit} HIT / ${fx_miss} MISS / ${fx_dir} DIR)." >&2
	echo "       Every rule needs a positive AND a negative case." >&2
	exit 2
fi
if [ "${fx_bad}" -gt 0 ]; then
	echo "ERROR: the detector disagrees with ${fx_bad} fixture case(s) above." >&2
	exit 2
fi
echo "fixture: ${fx_hit} HIT / ${fx_miss} MISS / ${fx_dir} DIR cases, all as expected"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# ---------------------------------------------------------------------------
# Input 1 — every crate that contains test code
# ---------------------------------------------------------------------------
: >"${work}/crates"
: >"${work}/declared"
while read -r toml; do
	[ -n "${toml}" ] || continue
	d="$(dirname "${toml}")"
	if ! grep -rlE '#\[(tokio::)?test\]|#\[cfg\(test\)\]' "$d" --include='*.rs' >/dev/null 2>&1; then
		continue
	fi
	reason="$(head -n "${MARKER_SCAN_LINES}" "${toml}" 2>/dev/null | grep -E -m1 "${MARKER_RE}")"
	if [ -n "${reason}" ]; then
		printf '%s\t%s\n' "$d" \
			"$(printf '%s' "${reason#*NOT-A-TEST-CRATE:}" | sed 's/^[[:space:]]*//')" \
			>>"${work}/declared"
	else
		printf '%s\n' "$d" >>"${work}/crates"
	fi
done < <(git ls-files '*Cargo.toml')

crate_n=$(grep -c . <"${work}/crates")
declared_n=$(grep -c . <"${work}/declared")

if [ "${crate_n}" -lt "${MIN_CRATES}" ]; then
	echo "ERROR: found only ${crate_n} in-scope crate(s); expected >= ${MIN_CRATES}." >&2
	echo "       The enumeration broke; a clean report from it would be a lie." >&2
	exit 2
fi

# ---------------------------------------------------------------------------
# Input 2 — every directory some cargo test/nextest invocation runs in
#
# This script and its fixture are themselves under ci/ and both contain
# real-looking `cargo test` text. Scanning them would invent invocations and,
# worse, invent COVERAGE for whichever directory a nearby `cd` named — a false
# green of exactly the kind this gate exists to prevent. Same reason
# ci/test/grep-q-pipefail-gate.fixture.txt is excluded from its own gate.
# ---------------------------------------------------------------------------
git ls-files 'justfile' 'ci/*' 'ci/**/*' 'scripts/*' 'scripts/**/*' '.github/workflows/*' |
	grep -vxF "${FIXTURE}" |
	grep -vxF 'ci/test/rust-test-crate-coverage.sh' >"${work}/scanfiles"

# Read into an array rather than splitting a $(cat ...): a path with a space in
# it would otherwise become two arguments, and awk would report both as missing
# rather than scanning the file -- fewer invocations found, more crates dark.
mapfile -t scanfiles <"${work}/scanfiles"
if [ "${#scanfiles[@]}" -eq 0 ]; then
	echo "ERROR: no files to scan; the enumeration broke." >&2
	exit 2
fi

awk "${AWK_RULES}"'
FNR == 1 { pending = "" }
{
  if (is_comment($0)) next
  d = dir_of_line($0)
  if (d != "") pending = d
  if (is_invocation($0)) {
    n++
    if (pending != "") print "DIR\t" pending
    else print "UNRESOLVED\t" FILENAME "\t" $0
  }
}
END { print "@@N\t" n+0 }
' "${scanfiles[@]}" >"${work}/scan" 2>/dev/null

invocations="$(grep '^@@N' "${work}/scan" | cut -f2)"
grep '^DIR' "${work}/scan" | cut -f2 | sort -u >"${work}/covered"
unresolved="$(grep -c '^UNRESOLVED' "${work}/scan")"

if [ "${invocations}" -lt "${MIN_INVOCATIONS}" ]; then
	echo "ERROR: found only ${invocations} cargo test invocation(s); expected >= ${MIN_INVOCATIONS}." >&2
	echo "       Rule 1 stopped matching; every crate would report dark." >&2
	exit 2
fi

# ---------------------------------------------------------------------------
# Check — crates with test code that nothing runs
# ---------------------------------------------------------------------------
: >"${work}/dark"
while read -r c; do
	[ -n "$c" ] || continue
	if ! grep -qxF -- "$c" "${work}/covered"; then
		printf '%s\n' "$c" >>"${work}/dark"
	fi
done <"${work}/crates"

if [ ! -f "${BASELINE}" ]; then
	echo "ERROR: baseline ${BASELINE} is missing." >&2
	exit 2
fi
recorded="$(grep -vE '^[[:space:]]*(#|$)' "${BASELINE}" | cut -f1 | sort -u)"
actual="$(sort -u <"${work}/dark")"

echo ""
echo "=== Rust test-crate coverage ==="
echo "crates with test code:  ${crate_n}"
echo "declared not-a-crate:   ${declared_n}"
echo "cargo test invocations: ${invocations} (${unresolved} with no resolvable working directory)"
echo "dark crates:            $(printf '%s\n' "${actual}" | grep -c .)"
echo ""

if [ "${declared_n}" -gt 0 ]; then
	echo "Declared exclusions (each crate's Cargo.toml says so itself):"
	while IFS=$'\t' read -r c reason; do
		printf '  %s\n      %s\n' "$c" "$reason"
	done <"${work}/declared"
	echo ""
fi

if [ "${actual}" = "${recorded}" ]; then
	echo "OK: the dark-crate set matches the recorded baseline ($(printf '%s\n' "${recorded}" | grep -c .) entr(y/ies))."
else
	status=1
	echo "ERROR: the dark-crate set does not match ${BASELINE}"
	diff <(printf '%s\n' "${recorded}") <(printf '%s\n' "${actual}") |
		sed -n 's/^< /  NOW COVERED — delete it from the baseline: /p;s/^> /  NEWLY DARK crate: /p'
	cat <<-'EOF'

		  A crate nothing runs the Rust test runner in contributes zero coverage,
		  however many #[test] functions it holds. Fix by either:
		    * adding a `cargo test` / `cargo nextest run` for it to a justfile recipe
		      or CI job (and confirm that recipe is itself reachable —
		      ci/test/shell-gate-coverage.sh is what answers that); or
		    * declaring, in the crate's own Cargo.toml, that it is not tested here:
		          # NOT-A-TEST-CRATE: <why>
		    * or, for one that is genuinely still dark, recording it in the baseline
		      with a reason and an owner.

	EOF
fi

exit "${status}"
