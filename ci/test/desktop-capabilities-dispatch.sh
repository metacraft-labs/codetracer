#!/usr/bin/env bash
# =============================================================================
# Automated verification that `resources/codetracer-desktop-capabilities`
# declares exactly the file extensions the CodeTracer core can record.
#
# WHAT THIS TESTS
#   The launcher routes `ct record foo.py` to a component purely from that
#   component's capability file — it never asks the component whether it can
#   handle the request (CodeTracer-Launcher.md §2.3/§2.5). So the capability
#   file is a promise, and a wrong promise fails silently in both directions:
#
#     * an extension declared that the core cannot record  -> `ct record`
#       execs codetracer-desktop, which then refuses the file;
#     * an extension the core CAN record but does not declare -> the launcher
#       never routes it at all and prints "no handler for `record`". That is
#       the real, shipped `.js` bug this milestone exists to fix.
#
#   The scenarios below therefore check the declaration against the core's own
#   dispatch tables in BOTH directions, and then prove the check has teeth by
#   mutating the capability file and requiring each mutation to fail.
#
#     1. The checked-in capability file conforms.
#     2..6. Mutation scenarios — a bogus extension, the removed `.js`, the
#        removed `.styl`, the removed `record-test .rb`/`.nr`, and a `project`
#        marker must EACH produce a non-zero exit naming the offending token.
#        These are the mutation tests, wired in permanently rather than run
#        once by hand.
#     7. The help delegate agrees with the capability file: the built core's
#        `ct-describe-commands` `file-types` lines (which drive `ct --help`
#        and `ct record <TAB>` completion, spec §2.6) declare the same
#        extensions the capability file routes on.  If the core binary is
#        older than the sources that decide that output, the scenario fails
#        with an explicit "CORE IS STALE / rebuild" diagnostic instead of
#        four assertion failures that look like a capability-file bug.
#
# DESIGN DOC
#   codetracer-specs/Testing/Launcher-Recorder-Compatibility-Tests.md §5.1
#   deliverable D2 and §7, milestone LRC-1 in
#   codetracer-specs/Testing/Launcher-Recorder-Compatibility-Tests.milestones.org.
#
# MOCKING POLICY
#   (metacraft-dev-guidelines/policies/documentation-conventions.md,
#    "Mocking Policy in Integration Tests")
#   This test mocks NOTHING. The expected extension set is computed by the
#   production code itself (ci/test/desktop_capabilities_dispatch_check.nim
#   imports src/ct/utilities/language_detection.nim and
#   src/ct/trace/recorder_dispatch.nim and evaluates their real tables), and
#   scenario 7 asks the real built `ct` binary what it declares. No component
#   is stubbed and no fixture capability string is used: the mutation
#   scenarios operate on byte-copies of the real resource with exactly one
#   line edited, which are the inputs under test rather than stand-ins for
#   anything's behaviour.
#
# NO SKIPS
#   Every prerequisite is a hard failure with a remedy: no `nim` on PATH, no
#   built core, and a STALE built core all fail the run with a non-zero exit
#   and a named remedy. Nothing here downgrades to a skip, because each of
#   those states is also a state in which a genuine mismatch could hide.
#   There is a zero-assertion guard at the end so a harness that silently ran
#   nothing cannot report PASS.
#
# Usage:
#   ci/test/desktop-capabilities-dispatch.sh
#
# Environment:
#   CODETRACER_CORE_BIN      override the built core binary used by scenario 7
#   CODETRACER_E2E_CT_PATH   same, shared with the other ci/test scripts
#   CODETRACER_BUILD_DIR     build tree to probe (default src/build-debug)
#   CT_CAPS_CHECK_VERBOSE=1  echo every one of the checker's ~340 individual
#                            assertions instead of just the per-command sets
#                            (a FAILING assertion is always printed in full)
# =============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CAPS_SRC="$ROOT_DIR/resources/codetracer-desktop-capabilities"
CHECKER="$ROOT_DIR/ci/test/desktop_capabilities_dispatch_check.nim"

case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN* | *_NT*) EXE_SUFFIX=".exe" ;;
*) EXE_SUFFIX="" ;;
esac

PASSED=0
FAILED=0
SCENARIOS=0
FAILURES=""

ok() {
	PASSED=$((PASSED + 1))
	echo "  ok   $1"
}

bad() {
	FAILED=$((FAILED + 1))
	FAILURES="$FAILURES"$'\n'"  - $1"
	echo "  FAIL $1"
}

assert_true() {
	local desc="$1"
	shift
	if "$@"; then ok "$desc"; else bad "$desc"; fi
}

assert_eq() {
	local desc="$1" expected="$2" actual="$3"
	if [[ $expected == "$actual" ]]; then
		ok "$desc"
	else
		bad "$desc (expected '$expected', got '$actual')"
	fi
}

die() {
	echo "error: $*" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# Prerequisites — all hard failures.
# ---------------------------------------------------------------------------
[[ -f $CAPS_SRC ]] || die "capability resource not found: $CAPS_SRC"
[[ -f $CHECKER ]] || die "dispatch checker not found: $CHECKER"

command -v nim >/dev/null 2>&1 ||
	die "nim not found on PATH — run this from the codetracer dev shell (direnv exec . ...)"

CORE_BIN="${CODETRACER_CORE_BIN:-${CODETRACER_E2E_CT_PATH:-}}"
if [[ -z $CORE_BIN ]]; then
	for candidate in \
		"${CODETRACER_BUILD_DIR:-$ROOT_DIR/src/build-debug}/bin/ct$EXE_SUFFIX" \
		"$ROOT_DIR/src/build-debug/bin/ct$EXE_SUFFIX" \
		"$ROOT_DIR/src/build-debug-repro/bin/ct$EXE_SUFFIX" \
		"$ROOT_DIR/src/build-release/bin/ct$EXE_SUFFIX" \
		"$ROOT_DIR/src/build-release-repro/bin/ct$EXE_SUFFIX"; do
		if [[ -x $candidate ]]; then
			CORE_BIN="$candidate"
			break
		fi
	done
fi
if [[ -z $CORE_BIN || ! -x $CORE_BIN ]]; then
	die "the CodeTracer core binary has not been built.
  Build it with:  just build-once
  Or set CODETRACER_CORE_BIN to a prebuilt binary.
  (This is deliberately NOT a skip: scenario 7 asks the REAL binary what
   file types it advertises to the launcher's help/completion protocol.)"
fi
CORE_BIN="$(cd "$(dirname "$CORE_BIN")" && pwd)/$(basename "$CORE_BIN")"

WORK_DIR="$(mktemp -d -t ct-caps-dispatch-XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "codetracer-desktop capability/dispatch conformance test"
echo "  repo: $ROOT_DIR"
echo "  caps: $CAPS_SRC"
echo "  core: $CORE_BIN"
echo

# ---------------------------------------------------------------------------
# Build the checker once, against the real production modules.
# ---------------------------------------------------------------------------
CHECK_BIN="$WORK_DIR/desktop_capabilities_dispatch_check"
echo "compiling the dispatch checker against the core's own tables"
if ! nim c --hints:off --warnings:off --nimcache:"$WORK_DIR/nimcache" \
	--out:"$CHECK_BIN" "$CHECKER" >"$WORK_DIR/build.log" 2>&1; then
	sed -n '1,80p' "$WORK_DIR/build.log" >&2
	die "the dispatch checker failed to compile against src/ct/... — the
  capability file cannot be validated without it."
fi
echo "  ok   checker compiles against src/ct/utilities/language_detection.nim + src/ct/trace/recorder_dispatch.nim"
PASSED=$((PASSED + 1))
echo

# `run_checker <capability-file>` -> prints output, returns the checker's code.
run_checker() {
	set +e
	CHECK_OUT="$("$CHECK_BIN" "$1" 2>&1)"
	CHECK_RC=$?
	set -e
}

# ---------------------------------------------------------------------------
# Scenario 1 — the checked-in capability file conforms in both directions.
# ---------------------------------------------------------------------------
SCENARIOS=$((SCENARIOS + 1))
echo "scenario 1: the checked-in capability file matches the core's dispatch tables"

run_checker "$CAPS_SRC"
echo "$CHECK_OUT" | sed 's/^/    /'
assert_eq "checker exits 0 for resources/codetracer-desktop-capabilities" "0" "$CHECK_RC"
assert_true "checker reported a PASS line with a non-zero assertion count" \
	grep -qE '^PASS: [1-9][0-9]* capability/dispatch assertions' <<<"$CHECK_OUT"

# The extension this whole milestone exists for, pinned explicitly so a future
# rewrite of the derivation cannot quietly drop it again.
assert_true "the capability file declares 'record .js'" \
	grep -qE '^record( \.[a-z0-9]+)* \.js( |$)' "$CAPS_SRC"

# ---------------------------------------------------------------------------
# Mutation scenarios — each one must be caught. These are the mutation tests
# for scenario 1, kept in the suite rather than run once by hand.
# ---------------------------------------------------------------------------

# mutate <name> <sed-expression> <expected-substring-in-failure>
mutate_and_expect_failure() {
	local name="$1" sed_expr="$2" needle="$3"
	SCENARIOS=$((SCENARIOS + 1))
	echo
	echo "scenario $SCENARIOS: $name"
	local mutant="$WORK_DIR/caps-$SCENARIOS"
	sed "$sed_expr" "$CAPS_SRC" >"$mutant"
	if cmp -s "$CAPS_SRC" "$mutant"; then
		bad "$name: the mutation did not change the file (the sed expression is stale)"
		return
	fi
	run_checker "$mutant"
	if [[ $CHECK_RC -eq 0 ]]; then
		echo "$CHECK_OUT" | sed 's/^/    /'
		bad "$name: the checker PASSED a capability file it must reject"
	else
		ok "$name: the checker exits non-zero ($CHECK_RC)"
	fi
	if grep -qF "$needle" <<<"$CHECK_OUT"; then
		ok "$name: the failure names '$needle'"
	else
		echo "$CHECK_OUT" | sed 's/^/    /'
		bad "$name: the failure does not name '$needle'"
	fi
}

mutate_and_expect_failure \
	"a bogus extension added to 'record' is rejected" \
	's/^record \./record .zzz ./' \
	'.zzz'

mutate_and_expect_failure \
	"dropping '.js' from 'record' is rejected (the LRC-1 bug itself)" \
	's/^\(record .*\) \.js /\1 /' \
	'.js'

mutate_and_expect_failure \
	"re-adding the unsupported '.styl' is rejected" \
	's/^record \./record .styl ./' \
	'.styl'

mutate_and_expect_failure \
	"restoring 'record-test .py .rb .nr' is rejected" \
	's/^record-test .*$/record-test .py .rb .nr/' \
	'.rb'

mutate_and_expect_failure \
	"declaring a 'project' marker is rejected" \
	's/^name codetracer-desktop$/name codetracer-desktop\nproject pyproject.toml/' \
	'pyproject.toml'

# ---------------------------------------------------------------------------
# Scenario 7 — the help delegate advertises the same file types.
#
# The capability file drives ROUTING; `ct-describe-commands` drives the
# launcher's help screen and path completion (spec §2.6). Before LRC-1 both
# claimed `.styl`; keeping them equal is what stops one from being fixed while
# the other rots.
# ---------------------------------------------------------------------------
SCENARIOS=$((SCENARIOS + 1))
echo
echo "scenario $SCENARIOS: the built core's ct-describe-commands agrees with the capability file"

# `ct-describe-commands`' file-types are compiled into the core from
# src/ct/launch/help_delegate.nim.  A core binary older than that file cannot
# reflect it, and comparing the two anyway produces several assertion failures
# that read like a capability-file bug when the real cause is an un-rebuilt
# binary.  Diagnose that case precisely.  This is a HARD FAILURE, not a skip:
# an out-of-date core is a genuine reason to distrust the run, and staying
# silent about it is how a real mismatch would hide.
#
# Only help_delegate.nim is compared.  The capability *resource* is read from
# disk at test time and is not compiled into the binary, so its mtime says
# nothing about staleness — if IT changed and the two now disagree, that is a
# real divergence and must reach the assertions below, not be excused here.
HELP_SRC="$ROOT_DIR/src/ct/launch/help_delegate.nim"
if [[ -f $HELP_SRC && $HELP_SRC -nt $CORE_BIN ]]; then
	echo "  ---------------------------------------------------------------"
	echo "  CORE IS STALE."
	echo "    core binary : $CORE_BIN"
	echo "    is older than the source that compiles its file-types:"
	echo "      - $HELP_SRC"
	echo "    Rebuild it with:  just build-once"
	echo "    (or point CODETRACER_CORE_BIN at a current build)"
	echo "  Scenario $SCENARIOS cannot be evaluated against a stale binary, so it"
	echo "  fails rather than comparing against output that predates the change."
	echo "  ---------------------------------------------------------------"
	bad "the core binary is stale — rebuild with 'just build-once' before trusting scenario $SCENARIOS"
	echo
	if [[ $SCENARIOS -eq 0 || $((PASSED + FAILED)) -eq 0 ]]; then
		echo "FAIL: no assertions ran — the harness itself is broken" >&2
		exit 1
	fi
	echo "scenarios: $SCENARIOS   assertions: $((PASSED + FAILED))   passed: $PASSED   failed: $FAILED"
	echo "FAILURES:$FAILURES" >&2
	exit 1
fi

DESCRIBE_OUT="$WORK_DIR/describe.txt"
if ! "$CORE_BIN" ct-describe-commands >"$DESCRIBE_OUT" 2>"$WORK_DIR/describe.err"; then
	sed -n '1,20p' "$WORK_DIR/describe.err" >&2
	die "'$CORE_BIN ct-describe-commands' failed — the help-delegate protocol
  (CodeTracer-Launcher.md §2.6) is part of what this component promises."
fi

# Sorted, space-separated extension list a capability-file command declares.
caps_exts() {
	awk -v cmd="$1" '
		{ sub(/\r$/, "") }
		/^[ \t]*#/ { next }
		{ if ($1 == cmd) { for (i = 2; i <= NF; i++) print $i } }
	' "$CAPS_SRC" | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//'
}

# Sorted, space-separated `file-types` of one ct-describe-commands block.
describe_exts() {
	awk -v cmd="$1" '
		$1 == "command" { in_block = ($2 == cmd) }
		in_block && $1 == "file-types" { for (i = 2; i <= NF; i++) print $i }
	' "$DESCRIBE_OUT" | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//'
}

for cmd in record run record-test; do
	caps_list="$(caps_exts "$cmd")"
	describe_list="$(describe_exts "$cmd")"
	assert_true "ct-describe-commands emits a 'file-types' line for '$cmd'" \
		test -n "$describe_list"
	assert_eq "'$cmd' file-types match the capability file" \
		"$caps_list" "$describe_list"
done

if grep -q '\.styl' "$DESCRIBE_OUT"; then
	bad "ct-describe-commands still advertises the unsupported '.styl'"
else
	ok "ct-describe-commands no longer advertises the unsupported '.styl'"
fi

# ---------------------------------------------------------------------------
# Zero-assertion guard + summary.
# ---------------------------------------------------------------------------
echo
if [[ $SCENARIOS -eq 0 || $((PASSED + FAILED)) -eq 0 ]]; then
	echo "FAIL: no assertions ran — the harness itself is broken" >&2
	exit 1
fi

echo "scenarios: $SCENARIOS   assertions: $((PASSED + FAILED))   passed: $PASSED   failed: $FAILED"
if [[ $FAILED -ne 0 ]]; then
	echo "FAILURES:$FAILURES" >&2
	exit 1
fi
echo "PASS"
