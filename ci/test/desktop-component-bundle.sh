#!/usr/bin/env bash
# =============================================================================
# Automated verification of the `codetracer-desktop` component-bundle producer.
#
# WHAT THIS TESTS
#   `scripts/build-desktop-component.sh` assembles the component bundle the
#   `ct` launcher fronts:
#
#       <out-root>/codetracer-desktop@<ver>/
#           capabilities
#           bin/codetracer
#
#   This test runs that producer for real and asserts the bundle satisfies
#   every property the launcher actually depends on:
#
#     1. The layout is exactly what the launcher discovers — a
#        `<name>@<version>` directory holding `capabilities` and `bin/`,
#        with nothing else in it
#        (codetracer-launcher/src/launcher.nim `collectLevels` /
#         `scanLevelForCommand`, CodeTracer-Launcher.md §2.2).
#     2. `capabilities` is BYTE-IDENTICAL to the checked-in resource
#        `resources/codetracer-desktop-capabilities` (sha256 + `cmp`). The
#        launcher's contract is with the file the product ships, so a
#        producer that rewrites, templates or "fixes up" the file would
#        invalidate every downstream routing test.
#     3. The `bin` line inside that capability file names exactly the file
#        that was produced under `bin/`, AND that name is the one the
#        launcher spec fixes (`codetracer-desktop` / `codetracer`,
#        CodeTracer-Launcher.md §2.2/§2.3). Both halves are needed: the
#        first is derived from the resource, so on its own a rename of the
#        resource would move the expectation with it and stay green.
#     4. `bin/codetracer` is executable and its `--version` reports the same
#        version that appears in the `@<ver>` directory name.
#     5. The capability file parses and routes under the LAUNCHER'S OWN
#        parser — `ci/test/desktop_component_caps_check.nim` is compiled
#        against `codetracer-launcher/src/caps.nim` from the sibling
#        checkout, not against a copy of the grammar kept here.
#     6. The producer is idempotent, supports a real-copy publish mode, and
#        fails loudly (non-zero, with a remedy) when the core binary is
#        missing rather than emitting a half-formed bundle.
#
# DESIGN DOC
#   codetracer-specs/Testing/Launcher-Recorder-Compatibility-Tests.md §5.1,
#   deliverable D1 — milestone LRC-0 in
#   codetracer-specs/Testing/Launcher-Recorder-Compatibility-Tests.milestones.org.
#
# MOCKING POLICY
#   (metacraft-dev-guidelines/policies/documentation-conventions.md,
#    "Mocking Policy in Integration Tests")
#   This test mocks NOTHING. It runs the real producer script against the
#   real built CodeTracer core and the real checked-in capability file, and
#   validates the result with the real launcher parser source. There are no
#   stubs, no fixture capability strings, no fake binaries and no simulated
#   filesystem. The only synthesised thing is the temporary output root the
#   bundle is written into, which is the producer's ordinary `--out-root`
#   argument and not a stand-in for any component's behaviour.
#
# NO SKIPS
#   Every prerequisite is a hard failure with a remedy. In particular a
#   missing core binary (`just build-once`) and a missing
#   `codetracer-launcher` sibling checkout both fail the run; neither is
#   treated as an optional skip.
#
# Usage:
#   ci/test/desktop-component-bundle.sh
#
# Environment:
#   CODETRACER_CORE_BIN         override the built core binary to bundle
#   CODETRACER_E2E_CT_PATH      same, shared with the other ci/test scripts
#   CODETRACER_BUILD_DIR        build tree to probe (default src/build-debug)
#   CODETRACER_LAUNCHER_PATH    override the codetracer-launcher checkout
# =============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PRODUCER="$ROOT_DIR/scripts/build-desktop-component.sh"
CAPS_SRC="$ROOT_DIR/resources/codetracer-desktop-capabilities"
CAPS_CHECKER="$ROOT_DIR/ci/test/desktop_component_caps_check.nim"

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
	# assert_true <description> <command...>
	local desc="$1"
	shift
	if "$@"; then ok "$desc"; else bad "$desc"; fi
}

assert_eq() {
	# assert_eq <description> <expected> <actual>
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

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

# Sorted, space-separated listing of a directory's direct children (including
# dotfiles), so a whole directory's contents can be compared with one assert.
children_of() {
	local dir="$1"
	local entry
	local names=()
	shopt -s nullglob dotglob
	for entry in "$dir"/*; do
		names+=("${entry##*/}")
	done
	shopt -u nullglob dotglob
	if [[ ${#names[@]} -eq 0 ]]; then
		return 0
	fi
	printf '%s\n' "${names[@]}" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'
}

is_regular_file() {
	# A real file, not a symlink.
	[[ -f $1 && ! -L $1 ]]
}

dir_absent_or_empty() {
	[[ ! -d $1 || -z $(children_of "$1") ]]
}

# ---------------------------------------------------------------------------
# Prerequisites — all hard failures.
# ---------------------------------------------------------------------------
[[ -f $PRODUCER ]] || die "producer script not found: $PRODUCER"
[[ -f $CAPS_SRC ]] || die "capability resource not found: $CAPS_SRC"
[[ -f $CAPS_CHECKER ]] || die "capability checker not found: $CAPS_CHECKER"

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
  (This is deliberately NOT a skip: LRC-0's whole point is that the bundle
   carries the real built core.)"
fi
CORE_BIN="$(cd "$(dirname "$CORE_BIN")" && pwd)/$(basename "$CORE_BIN")"

LAUNCHER_REPO="${CODETRACER_LAUNCHER_PATH:-}"
if [[ -z $LAUNCHER_REPO ]]; then
	for candidate in \
		"$ROOT_DIR/../codetracer-launcher" \
		"$ROOT_DIR/../../codetracer-launcher"; do
		if [[ -f "$candidate/src/caps.nim" ]]; then
			LAUNCHER_REPO="$(cd "$candidate" && pwd)"
			break
		fi
	done
fi
if [[ -z $LAUNCHER_REPO || ! -f "$LAUNCHER_REPO/src/caps.nim" ]]; then
	die "the codetracer-launcher sibling checkout is missing (need src/caps.nim).
  Clone it next to this repo, or set CODETRACER_LAUNCHER_PATH.
  The capability file must be validated by the launcher's real parser; a
  local re-implementation would not prove compatibility."
fi

command -v nim >/dev/null 2>&1 ||
	die "nim not found on PATH — run this from the codetracer dev shell (direnv exec . ...)"

WORK_DIR="$(mktemp -d -t ct-desktop-component-XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "codetracer-desktop component bundle test"
echo "  repo:     $ROOT_DIR"
echo "  core:     $CORE_BIN"
echo "  launcher: $LAUNCHER_REPO"
echo

# ---------------------------------------------------------------------------
# Values read straight out of the checked-in capability file, so the test
# never hardcodes what the producer is supposed to derive.
# ---------------------------------------------------------------------------
caps_token() {
	awk -v kw="$1" '
		{ sub(/\r$/, "") }
		/^[ \t]*#/ { next }
		{ if ($1 == kw && NF >= 2) { print $2; exit } }
	' "$CAPS_SRC"
}
EXPECTED_NAME="$(caps_token name)"
EXPECTED_BIN="$(caps_token bin)"
[[ -n $EXPECTED_NAME ]] || die "$CAPS_SRC has no 'name' line"
[[ -n $EXPECTED_BIN ]] || die "$CAPS_SRC has no 'bin' line"
CAPS_SRC_SHA="$(sha256_of "$CAPS_SRC")"

# ---------------------------------------------------------------------------
# Scenario 1 — default (symlink) publish into a fresh out-root.
# ---------------------------------------------------------------------------
SCENARIOS=$((SCENARIOS + 1))
echo "scenario 1: produce the bundle (default publish mode)"

# Anchor the two names the rest of this file derives everything else from.
#
# Every other assertion below compares the producer's output against
# `$EXPECTED_NAME` / `$EXPECTED_BIN`, which are read out of the capability
# file itself — that is what makes the "bin line and filename agree"
# invariant structural. But it also means that renaming those lines in the
# resource would rename the bundle and the binary *and* the expectations in
# lockstep, and the whole suite would stay green while the product shipped a
# component the launcher's installed layout no longer names.
#
# `codetracer-desktop` and `codetracer` are not free choices. They are the
# literal names in CodeTracer-Launcher.md §2.2 (`codetracer-desktop@25.11.1/`)
# and §2.3; in the launcher's own test fixtures for the installed layout
# (codetracer-launcher/tests/test_launcher_install_m3.py builds
# `codetracer-desktop@26.01.1` with a `bin codetracer` capability file, and
# test_launcher_help_delegate_m5.py stages the same component name); and in
# this milestone's deliverable text (design §5.1 D1,
# `<out>/codetracer-desktop@<ver>/bin/codetracer`). Pin them here so a rename
# has to be a deliberate, reviewed change on both sides of the contract.
assert_eq "capability resource declares the spec's component name" \
	"codetracer-desktop" "$EXPECTED_NAME"
assert_eq "capability resource declares the spec's bin name" \
	"codetracer" "$EXPECTED_BIN"

OUT_ROOT="$WORK_DIR/root"
BUNDLE="$("$PRODUCER" --out-root "$OUT_ROOT" --print-path)" ||
	die "producer failed (exit $?)"

assert_true "producer created the bundle directory" test -d "$BUNDLE"
assert_eq "bundle lives directly under the out-root" "$OUT_ROOT" "$(dirname "$BUNDLE")"

BUNDLE_BASENAME="$(basename "$BUNDLE")"
BUNDLE_NAME="${BUNDLE_BASENAME%@*}"
BUNDLE_VERSION="${BUNDLE_BASENAME##*@}"

assert_eq "component directory uses the capability file's 'name'" \
	"$EXPECTED_NAME" "$BUNDLE_NAME"
assert_true "component directory carries an '@<version>' suffix" \
	grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' <<<"$BUNDLE_VERSION"

# --- layout the launcher walks ---------------------------------------------
assert_eq "bundle contains exactly 'bin' and 'capabilities'" \
	"bin capabilities" "$(children_of "$BUNDLE")"
assert_true "'capabilities' is a regular file" test -f "$BUNDLE/capabilities"
assert_true "'bin' is a directory" test -d "$BUNDLE/bin"
assert_eq "'bin' holds exactly the declared binary" \
	"$EXPECTED_BIN$EXE_SUFFIX" "$(children_of "$BUNDLE/bin")"

# --- capabilities is byte-identical to the checked-in resource -------------
BUNDLE_CAPS_SHA="$(sha256_of "$BUNDLE/capabilities")"
assert_eq "capabilities sha256 matches resources/codetracer-desktop-capabilities" \
	"$CAPS_SRC_SHA" "$BUNDLE_CAPS_SHA"
assert_true "capabilities is byte-for-byte identical (cmp)" \
	cmp -s "$CAPS_SRC" "$BUNDLE/capabilities"

# --- the 'bin' line and the produced filename agree ------------------------
BUNDLE_BIN="$BUNDLE/bin/$EXPECTED_BIN$EXE_SUFFIX"
BUNDLE_BIN_ACTUAL="$BUNDLE/bin/$(children_of "$BUNDLE/bin")"
assert_eq "the capability file's 'bin' line names the produced file" \
	"$(basename "$BUNDLE_BIN")" "$(basename "$BUNDLE_BIN_ACTUAL")"
assert_true "the produced binary is executable" test -x "$BUNDLE_BIN"
assert_true "the produced binary resolves to an existing file (not a dangling link)" \
	test -f "$(readlink -f "$BUNDLE_BIN")"
# Contents, not the symlink target: `--link` publishes a symlink on POSIX but
# MSYS/Git-Bash materialises `ln -s` as a copy, and either way the contract is
# that reading `bin/<name>` yields the built core.
assert_true "the produced binary is byte-identical to the built core" \
	cmp -s "$CORE_BIN" "$BUNDLE_BIN"

# --- the bundled binary runs and agrees with the bundle version ------------
#
# NOTE on the version-string shape. The milestone text speaks of the bundled
# binary reporting `ct <version>`. The `^ct [0-9]+\.[0-9]+` regex used by the
# packaging smoke workflows is a property of the LAUNCHER binary, which
# answers `--version` itself from a built-in string and never consults the
# component (codetracer-launcher/src/launcher.nim, `isBuiltin` case 1 ->
# `okOut(sCtVersion)`). The desktop core prints confutils' banner,
# `CodeTracer version: <ver>`. Asserting a `^ct ` prefix here would assert
# something the product does not do, so this test asserts the property that
# actually matters for the bundle: the binary runs, and the version it
# reports is exactly the version in the `@<ver>` directory name.
VERSION_OUT="$("$BUNDLE_BIN" --version 2>&1)" || bad "bundled binary '--version' exited non-zero"
echo "  (--version output: ${VERSION_OUT%%$'\n'*})"
REPORTED_VERSION="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$VERSION_OUT" | head -n1 || true)"
assert_true "bundled binary '--version' reports a dotted version" \
	test -n "$REPORTED_VERSION"
assert_eq "reported version matches the bundle's '@<version>'" \
	"$REPORTED_VERSION" "$BUNDLE_VERSION"

# --- the capability file parses under the launcher's own parser ------------
echo "  running the launcher-parser conformance check"
CAPS_CHECK_BIN="$WORK_DIR/desktop_component_caps_check"
if nim c --hints:off --warnings:off --nimcache:"$WORK_DIR/nimcache" \
	--path:"$LAUNCHER_REPO/src" --out:"$CAPS_CHECK_BIN" \
	"$CAPS_CHECKER" >"$WORK_DIR/caps-check-build.log" 2>&1; then
	ok "capability checker compiles against codetracer-launcher/src/caps.nim"
	if "$CAPS_CHECK_BIN" "$BUNDLE/capabilities" "$EXPECTED_BIN"; then
		ok "capabilities parses and routes under the launcher's parser"
	else
		bad "capabilities failed the launcher-parser conformance check"
	fi
else
	sed -n '1,60p' "$WORK_DIR/caps-check-build.log" >&2
	bad "capability checker failed to compile against codetracer-launcher/src/caps.nim"
fi

# ---------------------------------------------------------------------------
# Scenario 2 — idempotency.
# ---------------------------------------------------------------------------
SCENARIOS=$((SCENARIOS + 1))
echo
echo "scenario 2: re-running the producer is idempotent"

BUNDLE2="$("$PRODUCER" --out-root "$OUT_ROOT" --print-path)" ||
	die "producer failed on the second run (exit $?)"
assert_eq "second run targets the same bundle path" "$BUNDLE" "$BUNDLE2"
assert_eq "second run leaves the same top-level entries" \
	"bin capabilities" "$(children_of "$BUNDLE")"
assert_eq "second run leaves capabilities byte-identical" \
	"$CAPS_SRC_SHA" "$(sha256_of "$BUNDLE/capabilities")"
assert_true "second run leaves an executable binary" test -x "$BUNDLE_BIN"
assert_eq "out-root gained no extra bundles" \
	"$BUNDLE_BASENAME" "$(children_of "$OUT_ROOT")"

# ---------------------------------------------------------------------------
# Scenario 3 — `--copy` produces a self-contained binary file.
# ---------------------------------------------------------------------------
SCENARIOS=$((SCENARIOS + 1))
echo
echo "scenario 3: --copy publishes a real file"

COPY_ROOT="$WORK_DIR/copy-root"
COPY_BUNDLE="$("$PRODUCER" --out-root "$COPY_ROOT" --copy --print-path)" ||
	die "producer --copy failed (exit $?)"
COPY_BIN="$COPY_BUNDLE/bin/$EXPECTED_BIN$EXE_SUFFIX"

assert_true "--copy produced a regular file (not a symlink)" \
	is_regular_file "$COPY_BIN"
assert_true "--copy binary is byte-identical to the built core" \
	cmp -s "$CORE_BIN" "$COPY_BIN"
assert_true "--copy binary is executable" test -x "$COPY_BIN"
assert_eq "--copy capabilities is still byte-identical" \
	"$CAPS_SRC_SHA" "$(sha256_of "$COPY_BUNDLE/capabilities")"

# ---------------------------------------------------------------------------
# Scenario 4 — a missing core binary is a loud failure, never a silent bundle.
# ---------------------------------------------------------------------------
SCENARIOS=$((SCENARIOS + 1))
echo
echo "scenario 4: a missing core binary fails loudly"

MISSING_ROOT="$WORK_DIR/missing-root"
set +e
MISSING_OUT="$("$PRODUCER" --out-root "$MISSING_ROOT" \
	--core-bin "$WORK_DIR/definitely-not-built/ct" 2>&1)"
MISSING_RC=$?
set -e
assert_true "producer exits non-zero when the core binary is absent" \
	test "$MISSING_RC" -ne 0
assert_true "producer explains how to build the core" \
	grep -q "just build-once" <<<"$MISSING_OUT"
assert_true "producer wrote no bundle for the failed run" \
	dir_absent_or_empty "$MISSING_ROOT"

# ---------------------------------------------------------------------------
# Scenario 5 — the default out-root is gitignored.
# ---------------------------------------------------------------------------
SCENARIOS=$((SCENARIOS + 1))
echo
echo "scenario 5: the default output root is gitignored"

DEFAULT_OUT_ROOT_NAME="build-desktop-component"
assert_true "'$DEFAULT_OUT_ROOT_NAME/' is ignored by .gitignore" \
	git -C "$ROOT_DIR" check-ignore -q "$DEFAULT_OUT_ROOT_NAME/"

# ---------------------------------------------------------------------------
# Zero-test guard + summary.
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
