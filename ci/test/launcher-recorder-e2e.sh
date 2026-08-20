#!/usr/bin/env bash
# =============================================================================
# Launcher <-> recorder end-to-end compatibility driver.
#
#   ci/test/launcher-recorder-e2e.sh <recorder-repo> <lang> [<sample-file>]
#
# WHAT THIS TESTS
#   The whole real runtime path of `ct record`, across three repositories, with
#   no component of it stubbed:
#
#       ct record sample.py
#         (1) codetracer-launcher   routes `.py` from the codetracer-desktop
#                                   capability file alone, then execv()s the
#                                   component's bin/codetracer
#           (2) codetracer-desktop  (this repo's core `ct`) detects the
#                                   language and dispatches the recorder
#                                   (src/ct/trace/recorder_dispatch.nim)
#             (3) codetracer-<lang>-recorder  runs the program, writes a CTFS
#                                   trace
#               (4) codetracer-trace-format-nim `ct-print` decodes it (oracle)
#
#   Hop (1) is the part nothing else covers: ci/test/ct-providers.sh already
#   drives the core `ct` directly, so it proves (2)+(3) but never exercises the
#   launcher's router.  This driver's entry point is ALWAYS the launcher
#   binary.
#
# DESIGN DOC
#   codetracer-specs/Testing/Launcher-Recorder-Compatibility-Tests.md
#     §5.2 recorder discovery, §5.3 the nine driver steps, §5.4 the trace
#     validation oracle, §5.5 no vacuous passes, §5.6 the per-recorder contract
#     fixture, §5.7 the mocking policy.
#   Milestone LRC-2 in
#   codetracer-specs/Testing/Launcher-Recorder-Compatibility-Tests.milestones.org
#
# THE NINE STEPS (design §5.3), and where each one is below
#   1. build the launcher                  -> step_build_launcher
#   2. resolve the built desktop core      -> step_resolve_core
#   3. build the recorder                  -> step_build_recorder
#   4. stage the codetracer-desktop bundle -> step_stage_component
#   5. export discovery environment        -> step_export_discovery
#   6. run the LAUNCHER: ct record <sample>-> scenario_record
#   7. assert exit 0 + non-empty trace +
#      the trace validates via `ct-print`  -> scenario_record
#   8. negative case: unhandled extension  -> scenario_negative_routing
#   9. zero-test guard                     -> the summary block at the bottom
#
# SCENARIOS AND ASSERTIONS
#   Every scenario, every expected function, every expected stdout line and
#   every expected exit code is READ FROM the recorder repo's own contract
#   fixture, `<recorder-repo>/cross-repo/launcher-compat.yml` (design §5.6).
#   Nothing about a particular recorder is hardcoded here, so the same driver
#   serves every edge.
#
#   The flip side of that is that an OMITTED fixture key would silently switch
#   an assertion off, so `validate_fixture` below rejects an incomplete fixture
#   before anything is built — including a `record` scenario that does not
#   assert ${CODETRACER_COMPONENT_DIR}, which is this gate's only proof of hop
#   1.  The four scenario kinds are:
#
#     record            Route `<command> <sample>.<ext>` through the launcher,
#                       require exit 0, require the declared trace artifact,
#                       decode it with `ct-print` and assert on the DECODED
#                       shape: at least `min-events` events, no zero-count
#                       stream, every declared function present, and every
#                       declared stdout substring present in the recorded
#                       program's captured output.  Each declared recorder flag
#                       is then checked by its observable effect — see
#                       check_recorder_flag() for why not by argv scraping.
#     negative-routing  Route an extension the desktop component does not
#                       declare.  The launcher must exit non-zero and say so;
#                       a silent success here would mean the router matched
#                       something it should not have (design §5.3 step 8).  The
#                       driver also asserts the scenario's declared extension is
#                       well-formed and really is absent from the shipped
#                       capability file, so the negative case cannot quietly
#                       stop being negative.
#     launcher-version  `ct --version` answered by the launcher itself, in the
#                       shape Recorder-CLI-Conventions.md §7 and the packaging
#                       smoke workflows expect.
#     isolation         Re-run the happy-path command with an EMPTY components
#                       root.  It must fail.  This is the driver's own control
#                       against the worst vacuous pass available to it -- some
#                       other `ct` on PATH producing the trace -- because it
#                       proves the recording depended on the bundle we staged.
#
# WHY THE RECORDED PROGRAM PRINTS CODETRACER_COMPONENT_DIR
#   `CODETRACER_COMPONENT_DIR` is exported by the launcher immediately before
#   it execv()s the component (codetracer-launcher/src/launcher.nim), and by
#   nothing else on this path.  The sample program prints it, so finding it in
#   the DECODED trace is positive evidence that this recording travelled
#   launcher -> core -> recorder.  Asserting only "a trace appeared" could not
#   distinguish that from the core having been run directly.
#
# MOCKING POLICY
#   (metacraft-dev-guidelines/policies/documentation-conventions.md,
#    "Mocking Policy in Integration Tests"; design §5.7)
#   Nothing behavioural is mocked.  Real launcher binary, real desktop core,
#   real recorder, real CTFS trace, real `ct-print` decode.  The ONE synthesised
#   artifact is the staged component TREE under `CODETRACER_COMPONENTS_ROOT` --
#   a `<name>@<version>/{bin,capabilities}` directory produced by
#   `scripts/build-desktop-component.sh` (LRC-0) from the real core binary and
#   the real, byte-for-byte `resources/codetracer-desktop-capabilities`.  That
#   tree is test SCAFFOLDING standing in for an installed component layout, not
#   a mock of any component's behaviour: every byte the launcher reads out of it
#   is a byte the product ships.  A hand-written capability file would defeat
#   the whole test, and this driver never writes one.
#
# NO SKIPS (design §5.5)
#   Every prerequisite is a hard failure with a remedy, never a skip: a missing
#   recorder sibling, a missing launcher checkout, an unbuilt core, a missing
#   `ct-print`, a missing or unparseable contract fixture.  The only escape
#   hatch is `<PREFIX>_ALLOW_MISSING=1` (below), which exists for local
#   iteration and must never be set in a required gate.
#
# Usage:
#   just test-launcher-recorder-e2e
#   bash ci/test/launcher-recorder-e2e.sh codetracer-python-recorder python
#   bash ci/test/launcher-recorder-e2e.sh codetracer-python-recorder python \
#        cross-repo/samples/launcher_compat_sample.py
#
# Environment:
#   LAUNCHER_RECORDER_E2E_ALLOW_MISSING=1
#       Treat a missing/failed recorder BUILD as a warning instead of a hard
#       error, and downgrade the "recorder sibling not checked out" error.  The
#       contract fixture itself is still required either way -- without it there
#       are no scenarios and the run would be vacuous by construction.
#       LOCAL ITERATION ONLY -- never in a required CI gate (design §5.5).
#   LAUNCHER_RECORDER_E2E_SKIP_BUILDS=1
#       Do not rebuild the launcher or the recorder; use what is already built.
#       The artifacts must still exist, or the run fails.
#   LAUNCHER_RECORDER_E2E_KEEP=1
#       Keep the temporary work directory and print its path.
#   CODETRACER_LAUNCHER_PATH   codetracer-launcher checkout (default: sibling)
#   CODETRACER_LAUNCHER_BIN    prebuilt launcher binary (skips step 1's build)
#   CODETRACER_CORE_BIN        built desktop core (default: probes build dirs)
#   CODETRACER_E2E_CT_PATH     same, shared with the other ci/test scripts
#   CODETRACER_CT_PRINT        `ct-print` binary from codetracer-trace-format-nim
#                              (default: ../codetracer-trace-format-nim/ct-print)
# =============================================================================

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WS_ROOT="$(cd "$ROOT_DIR/.." && pwd)"
PRODUCER="$ROOT_DIR/scripts/build-desktop-component.sh"
BUILD_SIBLINGS="$ROOT_DIR/scripts/build-siblings.sh"
DETECT_SIBLINGS="$ROOT_DIR/scripts/detect-siblings.sh"
FIXTURE_SCHEMA="launcher-compat/v1"

PASSED=0
FAILED=0
SCENARIOS=0
EXECUTED_IDS=""
FAILURES=""

# ---------------------------------------------------------------------------
# Assertion helpers (same shape as ci/test/desktop-component-bundle.sh).
# ---------------------------------------------------------------------------
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

assert_contains() {
	# assert_contains <description> <needle> <file>
	local desc="$1" needle="$2" file="$3"
	if grep -qF -- "$needle" "$file"; then
		ok "$desc"
	else
		bad "$desc (substring not found: '$needle')"
	fi
}

die() {
	echo "error: $*" >&2
	exit 1
}

note() { echo "  ..   $*"; }

# ---------------------------------------------------------------------------
# Minimal YAML reader.
#
# `flatten_fixture` rewrites the strict YAML subset documented in
# launcher-compat.yml into `dotted.path=value` / `dotted.path[]=value` lines,
# which the rest of the script queries with grep.  awk keeps this dependency
# free: NixOS CI runners have no python3 on PATH (see
# codetracer-specs/Testing/Cross-Repo-CI-Integration.md, "NixOS Runner
# Gotchas"), and a YAML library would be a new toolchain requirement on every
# participating repo.
# ---------------------------------------------------------------------------
flatten_fixture() {
	awk '
		function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
		function unq(s) {
			if (s ~ /^".*"$/) return substr(s, 2, length(s) - 2)
			if (s ~ /^'"'"'.*'"'"'$/) return substr(s, 2, length(s) - 2)
			return s
		}
		BEGIN { depth = 0; indents[0] = -1; paths[0] = "" }
		{
			line = $0
			sub(/\r$/, "", line)
			if (line ~ /^[ \t]*$/) next
			if (line ~ /^[ \t]*#/) next
			if (line ~ /\t/) { print "PARSE-ERROR: tab in line " NR > "/dev/stderr"; exit 3 }
			match(line, /^ */); ind = RLENGTH
			rest = substr(line, ind + 1)
			while (depth > 0 && indents[depth] >= ind) depth--
			parent = paths[depth]

			if (rest ~ /^- /) {
				item = trim(substr(rest, 3))
				if (item ~ /^[A-Za-z0-9_.-]+:( |$)/) {
					key = item; sub(/:.*$/, "", key)
					val = item; sub(/^[A-Za-z0-9_.-]+:[ ]?/, "", val); val = trim(val)
					idx = counter[parent]++
					np = (parent == "" ? idx : parent "." idx)
					depth++; indents[depth] = ind; paths[depth] = np
					if (val != "") printf "%s.%s=%s\n", np, key, unq(val)
					else { depth++; indents[depth] = ind + 2; paths[depth] = np "." key }
				} else {
					printf "%s[]=%s\n", parent, unq(item)
				}
				next
			}

			if (rest ~ /^[A-Za-z0-9_.-]+:/) {
				key = rest; sub(/:.*$/, "", key)
				val = rest; sub(/^[A-Za-z0-9_.-]+:[ ]?/, "", val); val = trim(val)
				np = (parent == "" ? key : parent "." key)
				if (val != "") printf "%s=%s\n", np, unq(val)
				else { depth++; indents[depth] = ind; paths[depth] = np }
				next
			}

			print "PARSE-ERROR: unrecognised line " NR ": " line > "/dev/stderr"
			exit 3
		}
	' "$1"
}

# Escape a dotted query key for use as a grep BRE anchor.
fx_key_re() { printf '%s' "$1" | sed 's/[][\.^$*+?(){}|]/\\&/g'; }

fx_get() {
	# fx_get <dotted.key> -> the scalar, or "" when absent
	grep -m1 "^$(fx_key_re "$1")=" "$FLAT" 2>/dev/null | sed "s/^[^=]*=//"
}

fx_list() {
	# fx_list <dotted.key> -> one item per line
	grep "^$(fx_key_re "$1")\[\]=" "$FLAT" 2>/dev/null | sed "s/^[^=]*\[\]=//"
}

fx_require() {
	local value
	value="$(fx_get "$1")"
	[[ -n $value ]] || die "contract fixture $FIXTURE has no '$1'
  Every field the driver reads is documented in that file's header.
  A fixture the driver cannot read is a hard failure, never a skip."
	printf '%s' "$value"
}

fx_scenario_indices() {
	grep -o '^scenarios\.[0-9]\+\.id=' "$FLAT" 2>/dev/null |
		sed 's/^scenarios\.//; s/\.id=$//'
}

# ---------------------------------------------------------------------------
# Fixture completeness (design §5.5 "no vacuous passes", §5.6).
#
# Every expectation this driver asserts is READ FROM the fixture, which means a
# fixture that simply omits a key silently switches that assertion off: the run
# still reports PASS, having checked less.  That is the vacuous pass §5.5
# forbids, and it is invisible in the output.  LRC-4 adds four more fixtures on
# this schema, so the guard belongs here rather than in review.
#
# A `record` scenario must therefore declare, at minimum:
#   * a trace glob, and a NUMERIC event floor (a trace can exist, decode
#     cleanly, and describe nothing);
#   * at least one expected function;
#   * at least one expected recorded stdout line, and among them one naming
#     ${CODETRACER_COMPONENT_DIR} -- the only assertion that distinguishes
#     "the LAUNCHER recorded this" from "something recorded this", because the
#     launcher is the only process on this path that exports that variable and
#     the driver expands it to a bundle it staged in a fresh temporary
#     directory.  Without it the gate degrades to what ci/test/ct-providers.sh
#     already covers;
#   * at least one `recorder-flag`, which §5.6 requires the fixture to declare;
#   * `recorder.default-out-dir`, which the `--out-dir` check needs in order to
#     prove the recorder did NOT fall back to its own default location.
# ---------------------------------------------------------------------------
fixture_error() {
	die "contract fixture $FIXTURE: $1
  The driver reads every expectation from this file, so an omitted key would
  silently turn an assertion off and let the gate report PASS having checked
  less (design §5.5).  Declare it rather than relying on the driver."
}

validate_fixture() {
	local idx s id kind floor kinds=""
	for idx in "${SCENARIO_IDX[@]}"; do
		s="scenarios.$idx"
		id="$(fx_get "$s.id")"
		kind="$(fx_get "$s.kind")"
		[[ -n $id ]] || fixture_error "scenario $idx declares no 'id'"
		[[ -n $kind ]] || fixture_error "scenario '$id' declares no 'kind'"
		kinds="$kinds $kind"
		[[ $kind == "record" ]] || continue

		[[ -n $(fx_get "$s.expect.trace-glob") ]] ||
			fixture_error "record scenario '$id' declares no 'expect.trace-glob'"
		floor="$(fx_get "$s.expect.min-events")"
		[[ $floor =~ ^[0-9]+$ ]] ||
			fixture_error "record scenario '$id' declares 'expect.min-events' as '$floor', which is not a plain integer.
  Note this YAML subset does NOT strip inline comments: 'min-events: 20 # floor'
  is the value '20 # floor'."
		[[ -n $(fx_list "$s.expect.function") ]] ||
			fixture_error "record scenario '$id' declares no 'expect.function' -- the decode would be unchecked"
		[[ -n $(fx_list "$s.expect.stdout-contains") ]] ||
			fixture_error "record scenario '$id' declares no 'expect.stdout-contains' -- the recorded program's output would be unchecked"
		# shellcheck disable=SC2016
		# Single quotes are the point: the fixture stores the placeholder
		# `${CODETRACER_COMPONENT_DIR}` literally and the driver expands it
		# later, per scenario, to the bundle it staged.
		fx_list "$s.expect.stdout-contains" | grep -qF '${CODETRACER_COMPONENT_DIR}' ||
			fixture_error "record scenario '$id' has no 'expect.stdout-contains' entry naming \${CODETRACER_COMPONENT_DIR}.
  That entry is this gate's ONLY proof of hop 1: the launcher exports
  CODETRACER_COMPONENT_DIR immediately before execv()ing the component and
  nothing else on the path sets it, so finding the staged bundle's path inside
  the decoded trace is what separates 'recorded through the launcher' from
  'recorded somehow'.  Have the sample program print it."
		[[ -n $(fx_list "$s.recorder-flag") ]] ||
			fixture_error "record scenario '$id' declares no 'recorder-flag'.
  Design §5.6 requires the fixture to declare the expected recorder invocation
  flags; the driver checks each one by its observable effect."
		[[ -n $FX_DEFAULT_OUT_DIR ]] ||
			fixture_error "'recorder.default-out-dir' is required once a record scenario declares a recorder flag.
  The --out-dir check proves the flag was passed by showing the recorder did
  NOT write to its own default location, so it has to know that location."
	done

	# Every edge owes the same four scenarios: design §7's (a) happy path,
	# (b) `ct --version` shape and (c) negative routing, plus the `isolation`
	# control that proves the recording depended on the bundle we staged.  A
	# fixture could otherwise declare only the happy path and still satisfy the
	# "all declared scenarios ran" guard while dropping every hop-1 control.
	local want
	for want in record negative-routing launcher-version isolation; do
		[[ " $kinds " == *" $want "* ]] ||
			fixture_error "no scenario of kind '$want' is declared.
  Every edge needs all four (design §7 (a)/(b)/(c) plus the isolation control);
  a fixture that omits one drops a hop-1 check while still reporting PASS."
	done
}

# ---------------------------------------------------------------------------
# `nix build --print-out-paths` writes its result to a stream that command
# substitution does not always capture on this class of host, so route it
# through a file.  Same "materialise a nixpkgs tool on demand" idiom as
# scripts/detect-siblings.sh uses for lldb / pcre / glibc.
# ---------------------------------------------------------------------------
nix_out_path() {
	local attr="$1" out
	command -v nix >/dev/null 2>&1 || return 1
	out="$WORK_DIR/nix-out.txt"
	nix build --no-link --print-out-paths "$attr" >"$out" 2>/dev/null || return 1
	grep -m1 '^/nix/store/' "$out" 2>/dev/null || return 1
}

# ---------------------------------------------------------------------------
# Arguments.
# ---------------------------------------------------------------------------
if [[ $# -lt 2 || $# -gt 3 ]]; then
	sed -n '/^# Usage:/,/^# ===/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//' >&2
	exit 2
fi
RECORDER_REPO="$1"
LANG_KEY="$2"
SAMPLE_OVERRIDE="${3:-}"

ALLOW_MISSING="${LAUNCHER_RECORDER_E2E_ALLOW_MISSING:-0}"
SKIP_BUILDS="${LAUNCHER_RECORDER_E2E_SKIP_BUILDS:-0}"

WORK_DIR="$(mktemp -d -t ct-launcher-recorder-e2e-XXXXXX)"
cleanup() {
	if [[ ${LAUNCHER_RECORDER_E2E_KEEP:-0} == "1" ]]; then
		echo "work dir kept at: $WORK_DIR"
	else
		rm -rf "$WORK_DIR"
	fi
}
trap cleanup EXIT

echo "launcher <-> recorder end-to-end test"
echo "  repo:     $ROOT_DIR"
echo "  recorder: $RECORDER_REPO  (lang: $LANG_KEY)"
echo "  work dir: $WORK_DIR"
echo

# ---------------------------------------------------------------------------
# Contract fixture (design §5.6).  Read FIRST, because it decides what the
# rest of the run does -- a driver that ignored it would be worthless.
# ---------------------------------------------------------------------------
RECORDER_DIR="$WS_ROOT/$RECORDER_REPO"
if [[ ! -d $RECORDER_DIR ]]; then
	echo "error: the recorder sibling '$RECORDER_REPO' is not checked out at $RECORDER_DIR" >&2
	echo "  Clone it next to this repo.  A missing recorder is a HARD FAILURE:" >&2
	echo "  the recording contract cannot be tested without the recorder, and a" >&2
	echo "  skipped edge is exactly the vacuous pass this gate exists to prevent." >&2
	if [[ $ALLOW_MISSING != "1" ]]; then
		echo "  (set LAUNCHER_RECORDER_E2E_ALLOW_MISSING=1 for LOCAL iteration only)" >&2
		exit 1
	fi
	echo "  continuing because LAUNCHER_RECORDER_E2E_ALLOW_MISSING=1" >&2
fi
RECORDER_DIR="$(cd "$RECORDER_DIR" && pwd)"

FIXTURE="$RECORDER_DIR/cross-repo/launcher-compat.yml"
[[ -f $FIXTURE ]] || die "contract fixture not found: $FIXTURE
  Every recorder that participates in this gate carries one (design §5.6).
  Without it the driver has no scenarios to run and would pass vacuously."

FLAT="$WORK_DIR/fixture.flat"
flatten_fixture "$FIXTURE" >"$FLAT" || die "could not parse $FIXTURE"
[[ -s $FLAT ]] || die "$FIXTURE parsed to nothing"

FX_SCHEMA="$(fx_get schema)"
[[ $FX_SCHEMA == "$FIXTURE_SCHEMA" ]] ||
	die "$FIXTURE declares schema '$FX_SCHEMA'; this driver implements '$FIXTURE_SCHEMA'"

FX_REPO="$(fx_require recorder.repo)"
FX_LANG="$(fx_require recorder.lang)"
FX_BINARY="$(fx_require recorder.binary)"
FX_VERSION_PREFIX="$(fx_get recorder.version-prefix)"
FX_DEFAULT_OUT_DIR="$(fx_get recorder.default-out-dir)"
FX_SIBLING_KEY="$(fx_require build.sibling-key)"
FX_ARTIFACT="$(fx_require build.artifact)"
FX_DISCOVERY="$(fx_require discovery.method)"

[[ $FX_REPO == "$RECORDER_REPO" ]] ||
	die "$FIXTURE declares recorder.repo '$FX_REPO' but the driver was asked for '$RECORDER_REPO'"
[[ $FX_LANG == "$LANG_KEY" ]] ||
	die "$FIXTURE declares recorder.lang '$FX_LANG' but the driver was asked for '$LANG_KEY'"

mapfile -t SCENARIO_IDX < <(fx_scenario_indices)
DECLARED_SCENARIOS=${#SCENARIO_IDX[@]}
[[ $DECLARED_SCENARIOS -gt 0 ]] ||
	die "$FIXTURE declares no scenarios -- there would be nothing to run (design §5.5)"
validate_fixture

echo "contract fixture: $FIXTURE"
echo "  schema:    $FX_SCHEMA"
echo "  binary:    $FX_BINARY"
echo "  scenarios: $DECLARED_SCENARIOS"
echo

# ---------------------------------------------------------------------------
# Step 1 -- build the launcher, with its OWN build.sh.
# ---------------------------------------------------------------------------
step_build_launcher() {
	LAUNCHER_REPO="${CODETRACER_LAUNCHER_PATH:-}"
	if [[ -z $LAUNCHER_REPO ]]; then
		for candidate in "$WS_ROOT/codetracer-launcher" "$WS_ROOT/../codetracer-launcher"; do
			if [[ -f "$candidate/build.sh" ]]; then
				LAUNCHER_REPO="$(cd "$candidate" && pwd)"
				break
			fi
		done
	fi
	[[ -n $LAUNCHER_REPO && -f "$LAUNCHER_REPO/build.sh" ]] ||
		die "the codetracer-launcher sibling checkout is missing (need build.sh).
  Clone it next to this repo, or set CODETRACER_LAUNCHER_PATH.
  Hop 1 of this test IS the launcher; without it there is nothing to test."

	if [[ -n ${CODETRACER_LAUNCHER_BIN:-} ]]; then
		LAUNCHER_BIN="$CODETRACER_LAUNCHER_BIN"
		note "using prebuilt launcher: $LAUNCHER_BIN"
	else
		LAUNCHER_BIN="$LAUNCHER_REPO/out/launcher"
		if [[ $SKIP_BUILDS == "1" ]]; then
			note "LAUNCHER_RECORDER_E2E_SKIP_BUILDS=1: not rebuilding the launcher"
		else
			# The launcher links a fully static musl binary.  Its build.sh probes
			# for musl-gcc, then a /nix/store musl wrapper, then zig; on a dev
			# shell that has none of them it silently falls back to `cc` and the
			# link fails on -ldl/-lc.  Materialise zig on demand -- the same
			# nix-build-a-tool idiom scripts/detect-siblings.sh uses for lldb and
			# pcre -- so the build.sh probe succeeds instead of half-failing.
			if ! command -v zig >/dev/null 2>&1 &&
				! command -v musl-gcc >/dev/null 2>&1 &&
				! command -v x86_64-linux-musl-gcc >/dev/null 2>&1; then
				local zig_out
				zig_out="$(nix_out_path nixpkgs#zig || true)"
				if [[ -n ${zig_out:-} && -x "$zig_out/bin/zig" ]]; then
					export PATH="$zig_out/bin:$PATH"
					note "materialised zig for the launcher's musl link: $zig_out"
				fi
			fi
			echo "step 1: building the launcher ($LAUNCHER_REPO/build.sh)"
			if ! (cd "$LAUNCHER_REPO" && ./build.sh) >"$WORK_DIR/launcher-build.log" 2>&1; then
				sed -n '1,60p' "$WORK_DIR/launcher-build.log" >&2
				die "codetracer-launcher/build.sh failed (log: $WORK_DIR/launcher-build.log).
  It needs a musl toolchain or zig on PATH; neither was found and could not be
  materialised from nixpkgs.  This is a hard failure: a launcher that did not
  build cannot be the entry point of the test."
			fi
			tail -n 3 "$WORK_DIR/launcher-build.log" | sed 's/^/  | /'
		fi
	fi

	[[ -x $LAUNCHER_BIN ]] ||
		die "no launcher binary at $LAUNCHER_BIN (build it with $LAUNCHER_REPO/build.sh)"
	LAUNCHER_BIN="$(cd "$(dirname "$LAUNCHER_BIN")" && pwd)/$(basename "$LAUNCHER_BIN")"
	echo "  launcher: $LAUNCHER_BIN"
}

# ---------------------------------------------------------------------------
# Step 2 -- resolve the built desktop core.
#
# DEVIATION FROM THE DESIGN, recorded deliberately.  Design §5.3 step 2 says
# "build the desktop core".  This driver RESOLVES an already-built core and
# fails loudly (with the build command) when there is none, instead of running
# `just build-once` itself.  Two reasons: a full core build takes tens of
# minutes and would make the gate's failure modes unreadable (a core build
# break would surface as a launcher/recorder incompatibility), and it is the
# same policy ci/test/desktop-component-bundle.sh already established for the
# LRC-0 bundle producer.  CI builds the core in a separate, visible step.
# ---------------------------------------------------------------------------
step_resolve_core() {
	CORE_BIN="${CODETRACER_CORE_BIN:-${CODETRACER_E2E_CT_PATH:-}}"
	if [[ -z $CORE_BIN ]]; then
		for candidate in \
			"${CODETRACER_BUILD_DIR:-$ROOT_DIR/src/build-debug}/bin/ct" \
			"$ROOT_DIR/src/build-debug/bin/ct" \
			"$ROOT_DIR/src/build-debug-repro/bin/ct" \
			"$ROOT_DIR/src/build-release/bin/ct" \
			"$ROOT_DIR/src/build-release-repro/bin/ct"; do
			if [[ -x $candidate ]]; then
				CORE_BIN="$candidate"
				break
			fi
		done
	fi
	[[ -n $CORE_BIN && -x $CORE_BIN ]] ||
		die "the CodeTracer core binary has not been built.
  Build it with:  just build-once
  Or set CODETRACER_CORE_BIN to a prebuilt binary.
  Deliberately NOT a skip: hop 2 of this test is the real desktop core."
	CORE_BIN="$(cd "$(dirname "$CORE_BIN")" && pwd)/$(basename "$CORE_BIN")"
	echo "step 2: desktop core: $CORE_BIN"
}

# ---------------------------------------------------------------------------
# Step 3 -- build the recorder, through scripts/build-siblings.sh.
#
# build-siblings.sh owns the per-repo build command and runs it under
# `direnv exec <repo>` so the recorder's own flake pins its toolchain
# (codetracer-specs/Working-with-the-CodeTracer-Repos.md, Part 2).  The driver
# does not re-derive that here; it only asserts the declared artifact exists
# afterwards.
# ---------------------------------------------------------------------------
step_build_recorder() {
	echo "step 3: building the recorder ($FX_SIBLING_KEY)"
	local artifact="$RECORDER_DIR/$FX_ARTIFACT"
	if [[ $SKIP_BUILDS == "1" ]]; then
		note "LAUNCHER_RECORDER_E2E_SKIP_BUILDS=1: not rebuilding the recorder"
	elif [[ ! -d $RECORDER_DIR ]]; then
		note "recorder sibling absent; skipped by LAUNCHER_RECORDER_E2E_ALLOW_MISSING=1"
	else
		if ! bash "$BUILD_SIBLINGS" --only "$FX_SIBLING_KEY" >"$WORK_DIR/recorder-build.log" 2>&1; then
			sed -n '1,80p' "$WORK_DIR/recorder-build.log" >&2
			if [[ $ALLOW_MISSING != "1" ]]; then
				die "building the recorder sibling '$FX_SIBLING_KEY' failed
  (log: $WORK_DIR/recorder-build.log).
  A recorder that does not build cannot be tested; this is a hard failure."
			fi
			echo "  WARNING: recorder build failed; continuing because ALLOW_MISSING=1" >&2
		fi
		grep -E '^\s+(PASS|SKIP|FAIL|MISSING)' "$WORK_DIR/recorder-build.log" | sed 's/^/  | /' || true
	fi

	if [[ ! -e $artifact ]]; then
		if [[ $ALLOW_MISSING != "1" ]]; then
			die "the recorder build produced no '$FX_ARTIFACT' under $RECORDER_DIR.
  That path comes from the recorder's own contract fixture (build.artifact).
  Deliberately NOT a skip -- see design §5.5."
		fi
		echo "  WARNING: recorder artifact missing; continuing because ALLOW_MISSING=1" >&2
	fi
	echo "  recorder artifact: $artifact"
}

# ---------------------------------------------------------------------------
# Step 4 -- stage the codetracer-desktop component bundle (design §5.1 / LRC-0).
#
# `scripts/build-desktop-component.sh --print-path` is the SAME producer users
# get from `just build-desktop-component`; the capability file inside the
# bundle is a byte-for-byte copy of resources/codetracer-desktop-capabilities.
# The driver never writes a capability file of its own (design §5.1
# "Normative"), and asserts the byte-identity below so a future change to the
# producer cannot quietly turn this into a fixture test.
# ---------------------------------------------------------------------------
step_stage_component() {
	echo "step 4: staging the codetracer-desktop component bundle"
	COMPONENTS_ROOT="$WORK_DIR/components"
	BUNDLE="$("$PRODUCER" --out-root "$COMPONENTS_ROOT" --core-bin "$CORE_BIN" --print-path)" ||
		die "scripts/build-desktop-component.sh failed"
	[[ -d $BUNDLE ]] || die "producer reported $BUNDLE but it does not exist"
	echo "  bundle: $BUNDLE"

	local caps_src="$ROOT_DIR/resources/codetracer-desktop-capabilities"
	assert_true "staged capabilities is byte-identical to the shipped resource" \
		cmp -s "$caps_src" "$BUNDLE/capabilities"
	assert_true "staged bundle carries an executable component binary" \
		test -x "$BUNDLE/bin/$(awk '$1=="bin"{print $2; exit}' "$caps_src")"
}

# ---------------------------------------------------------------------------
# Step 5 -- discovery environment (design §5.2).
#
#   * CODETRACER_COMPONENTS_ROOT isolates the launcher onto the staged bundle
#     and suppresses the real user/system/distro levels
#     (codetracer-launcher/src/launcher.nim `collectLevels`).
#   * scripts/detect-siblings.sh is the repo's single source of truth for how a
#     workspace makes recorders and helper libraries visible to the core.  It is
#     SOURCED rather than re-implemented, so the E2E and `ct-providers.sh` can
#     never disagree about the discovery contract.
#   * `discovery.method` from the contract fixture covers the remainder.  The
#     python recorder is resolved by the core through a plain PATH search
#     (`findTool("codetracer-python-recorder")`, src/common/paths.nim), and its
#     built console script lives in the repo's venv, so the fixture asks for
#     that directory to be prepended.  The assertion afterwards is what matters:
#     the resolved binary must live INSIDE the recorder checkout, so the gate
#     cannot silently pass against a packaged recorder from the dev shell.
# ---------------------------------------------------------------------------
step_export_discovery() {
	echo "step 5: exporting discovery environment"
	export CODETRACER_COMPONENTS_ROOT="$COMPONENTS_ROOT"

	# shellcheck source=/dev/null
	DETECT_SIBLINGS_QUIET=1 source "$DETECT_SIBLINGS" "$ROOT_DIR" ||
		die "scripts/detect-siblings.sh failed"

	case "$FX_DISCOVERY" in
	path-prepend)
		local rel dir
		rel="$(fx_require discovery.path-prepend)"
		dir="$RECORDER_DIR/$rel"
		[[ -d $dir ]] || die "discovery.path-prepend '$rel' does not exist under $RECORDER_DIR"
		export PATH="$dir:$PATH"
		;;
	detect-siblings)
		note "discovery handled entirely by scripts/detect-siblings.sh"
		;;
	*)
		die "unknown discovery.method '$FX_DISCOVERY' in $FIXTURE"
		;;
	esac

	RESOLVED_RECORDER="$(command -v "$FX_BINARY" 2>/dev/null || true)"
	if [[ -z $RESOLVED_RECORDER ]]; then
		[[ $ALLOW_MISSING == "1" ]] ||
			die "'$FX_BINARY' is not on PATH after discovery setup.
  The desktop core resolves the recorder by name; without it the recording
  cannot happen.  Deliberately NOT a skip."
	else
		echo "  recorder on PATH: $RESOLVED_RECORDER"
		case "$RESOLVED_RECORDER" in
		"$RECORDER_DIR"/*)
			ok "the recorder on PATH is the one built from $RECORDER_REPO"
			;;
		*)
			bad "the recorder on PATH ($RESOLVED_RECORDER) is NOT inside $RECORDER_DIR — the sibling under test is not the one being exercised"
			;;
		esac
		if [[ -n $FX_VERSION_PREFIX ]]; then
			local vout
			vout="$("$RESOLVED_RECORDER" --version 2>&1 | head -n1)"
			echo "  recorder --version: $vout"
			case "$vout" in
			"$FX_VERSION_PREFIX"*)
				ok "recorder --version matches the declared prefix (Recorder-CLI-Conventions.md §7)"
				;;
			*)
				bad "recorder --version '$vout' does not start with '$FX_VERSION_PREFIX'"
				;;
			esac
		fi
	fi
}

# ---------------------------------------------------------------------------
# The trace-validation oracle (design §5.4): codetracer-trace-format-nim's
# `ct-print`.  Assertions are made on the DECODED trace, never on raw bytes,
# so the gate survives benign format-internal changes while still catching an
# empty or broken trace.
# ---------------------------------------------------------------------------
resolve_ct_print() {
	CT_PRINT="${CODETRACER_CT_PRINT:-}"
	if [[ -z $CT_PRINT ]]; then
		for candidate in \
			"$WS_ROOT/codetracer-trace-format-nim/ct-print" \
			"$WS_ROOT/../codetracer-trace-format-nim/ct-print"; do
			if [[ -x $candidate ]]; then
				CT_PRINT="$candidate"
				break
			fi
		done
	fi
	if [[ -z $CT_PRINT ]]; then
		CT_PRINT="$(command -v ct-print 2>/dev/null || true)"
	fi
	[[ -n $CT_PRINT && -x $CT_PRINT ]] ||
		die "the trace decoder 'ct-print' was not found.
  It is the validation oracle for this gate (design §5.4) and ships with the
  codetracer-trace-format-nim sibling:
      bash scripts/build-siblings.sh --only codetracer-trace-format-nim/ct-print
      # or, in that repo:  just build-ct-print
  Or set CODETRACER_CT_PRINT.  Deliberately NOT a skip: without a decode this
  test could only assert that some bytes appeared."
	CT_PRINT="$(cd "$(dirname "$CT_PRINT")" && pwd)/$(basename "$CT_PRINT")"
	echo "  trace oracle: $CT_PRINT"
}

# ---------------------------------------------------------------------------
# Scenario runners.
# ---------------------------------------------------------------------------
begin_scenario() {
	SCENARIOS=$((SCENARIOS + 1))
	EXECUTED_IDS="$EXECUTED_IDS $1"
	echo
	echo "scenario $SCENARIOS: $1 ($2)"
}

# The scenario names the extension it is ABOUT (`extension: .py`) separately
# from the sample file, so the two can be checked against each other.  Without
# this, renaming a sample to a different extension would quietly change which
# routing rule the scenario exercises while the fixture still claimed the old
# one.
assert_declared_extension() {
	local id="$1" declared="$2" sample="$3"
	[[ -n $declared ]] || {
		bad "$id: the fixture declares no 'extension' — the routing key under test would be unstated"
		return
	}
	assert_eq "$id: the sample's extension is the declared routing key" \
		"$declared" ".${sample##*.}"
}

is_well_formed_extension() { [[ $1 =~ ^\.[A-Za-z0-9_]+$ ]]; }

# True when the shipped capability file declares the extension for NO command.
extension_undeclared() {
	local esc="${1//./\\.}"
	! grep -qE "(^|[[:space:]])$esc([[:space:]]|\$)" \
		"$ROOT_DIR/resources/codetracer-desktop-capabilities"
}

scenario_record() {
	local s="$1" id="$2"
	local cmd sample rel_sample trace_dir stdout_f stderr_f rc
	TRACE_FILE=""
	cmd="$(fx_get "$s.command")"
	rel_sample="${SAMPLE_OVERRIDE:-$(fx_get "$s.sample")}"
	sample="$RECORDER_DIR/$rel_sample"
	[[ -f $sample ]] || {
		bad "$id: sample program not found: $sample"
		return
	}
	assert_declared_extension "$id" "$(fx_get "$s.extension")" "$sample"

	trace_dir="$WORK_DIR/trace-$id"
	mkdir -p "$trace_dir"
	stdout_f="$WORK_DIR/$id.out"
	stderr_f="$WORK_DIR/$id.err"

	# Run from a scratch cwd, never from the repo.  A recorder that is NOT told
	# where to write falls back to a default directory relative to its cwd
	# (`recorder.default-out-dir` in the fixture; for the python recorder that
	# is `./trace-out` -- see its `resolve_out_dir`), so an isolated cwd is
	# what makes "the core really passed --out-dir" observable: see
	# check_recorder_flag below.
	RUN_CWD="$WORK_DIR/cwd-$id"
	mkdir -p "$RUN_CWD"

	# argv ORDER MATTERS: the launcher takes the routing extension from argv[2]
	# only (codetracer-launcher/src/launcher.nim, "Extract extension from
	# argv[2]"), so the program must be the first argument after the
	# subcommand.  Putting `-o` first would make the launcher see `-o` as the
	# routing token and refuse to route at all.
	echo "  \$ $(basename "$LAUNCHER_BIN") $cmd $rel_sample -o $trace_dir"
	(cd "$RUN_CWD" && "$LAUNCHER_BIN" "$cmd" "$sample" -o "$trace_dir") \
		>"$stdout_f" 2>"$stderr_f"
	rc=$?
	sed 's/^/  | /' "$stdout_f" | tail -n 12
	if [[ -s $stderr_f ]]; then sed 's/^/  ! /' "$stderr_f" | tail -n 12; fi

	local want_rc
	want_rc="$(fx_get "$s.expect.exit-code")"
	assert_eq "$id: launcher exited $want_rc" "$want_rc" "$rc"
	if [[ $rc -ne 0 ]]; then
		bad "$id: recording failed, remaining assertions cannot be evaluated"
		return
	fi

	# --- the declared trace artifact exists -------------------------------
	local glob matches
	glob="$(fx_get "$s.expect.trace-glob")"
	shopt -s nullglob
	# shellcheck disable=SC2206  # deliberate glob expansion of a fixture value
	matches=($trace_dir/$glob)
	shopt -u nullglob
	if [[ ${#matches[@]} -eq 0 ]]; then
		bad "$id: no trace artifact matching '$glob' under $trace_dir"
		echo "       contents: $(find "$trace_dir" -mindepth 1 -maxdepth 1 -exec basename {} \; 2>/dev/null | tr '\n' ' ')"
		return
	fi
	ok "$id: produced $(basename "${matches[0]}") (matching '$glob')"
	TRACE_FILE="${matches[0]}"
	assert_true "$id: the trace artifact is non-empty" test -s "$TRACE_FILE"

	# --- decode with ct-print (design §5.4) -------------------------------
	local events_f full_f meta_f
	events_f="$WORK_DIR/$id.json-events"
	full_f="$WORK_DIR/$id.full"
	meta_f="$WORK_DIR/$id.meta"

	if "$CT_PRINT" --json-events "$TRACE_FILE" >"$events_f" 2>"$WORK_DIR/$id.json-events.err"; then
		ok "$id: ct-print --json-events decoded the trace"
	else
		sed -n '1,20p' "$WORK_DIR/$id.json-events.err" >&2
		bad "$id: ct-print --json-events failed to decode the trace"
		return
	fi
	assert_true "$id: --json-events output is non-empty" test -s "$events_f"

	if "$CT_PRINT" --full "$TRACE_FILE" >"$full_f" 2>"$WORK_DIR/$id.full.err"; then
		ok "$id: ct-print --full decoded the trace"
	else
		sed -n '1,20p' "$WORK_DIR/$id.full.err" >&2
		bad "$id: ct-print --full failed to decode the trace"
		return
	fi
	"$CT_PRINT" --meta-json "$TRACE_FILE" >"$meta_f" 2>/dev/null || true

	# --- no vacuous pass: the decode must contain real events -------------
	local event_count
	event_count="$(grep -c '"kind"' "$full_f")"
	echo "  decoded events: $event_count"
	local min_events
	min_events="$(fx_get "$s.expect.min-events")"
	if [[ -n $min_events ]]; then
		if [[ $event_count -ge $min_events ]]; then
			ok "$id: decoded $event_count events (>= $min_events declared)"
		else
			bad "$id: decoded only $event_count events, fixture requires >= $min_events"
		fi
	fi
	# The literal "0 events"/"0 steps" emptiness the design calls out (§5.5):
	# a trace file can exist, decode cleanly, and still describe nothing.
	if grep -qE '"(steps|calls|events)"[[:space:]]*:[[:space:]]*0([,}]|$)' "$full_f" "$meta_f"; then
		bad "$id: the decoded trace reports a zero count -- an empty recording"
	else
		ok "$id: the decoded trace reports no zero-count stream"
	fi

	# --- the sample program's known functions -----------------------------
	local fn found=0
	while IFS= read -r fn; do
		[[ -n $fn ]] || continue
		found=1
		assert_contains "$id: decoded trace contains function '$fn'" "\"$fn\"" "$full_f"
	done < <(fx_list "$s.expect.function")
	[[ $found -eq 1 ]] ||
		bad "$id: the fixture declares no expected functions -- the decode would be unchecked"

	# --- the sample program's stdout, AS RECORDED -------------------------
	#
	# Read out of the trace, not off the driver's console: that is what proves
	# the recorder captured the run rather than merely having been started.
	local needle expanded
	while IFS= read -r needle; do
		[[ -n $needle ]] || continue
		expanded="${needle//\$\{CODETRACER_COMPONENT_DIR\}/$BUNDLE}"
		if grep -qF -- "$expanded" "$full_f"; then
			ok "$id: recorded stdout contains '$expanded'"
		else
			# The decoder emits IO payloads base64-encoded as well as decoded
			# text; try the base64 form before failing, so an encoding change
			# does not read as a missing recording.
			local b64
			b64="$(printf '%s' "$expanded" | base64 -w0 2>/dev/null || printf '%s' "$expanded" | base64 | tr -d '\n')"
			if [[ -n $b64 ]] && grep -qF -- "$b64" "$full_f"; then
				ok "$id: recorded stdout contains '$expanded' (base64 payload)"
			else
				bad "$id: recorded stdout is missing '$expanded'"
			fi
		fi
	done < <(fx_list "$s.expect.stdout-contains")

	# --- the recorder invocation flags (Recorder-CLI-Conventions.md §3) ----
	local flag
	while IFS= read -r flag; do
		[[ -n $flag ]] || continue
		check_recorder_flag "$id" "$flag" "$trace_dir"
	done < <(fx_list "$s.recorder-flag")
}

# ---------------------------------------------------------------------------
# Recorder-invocation flags, checked by their OBSERVABLE EFFECT.
#
# CTFS metadata records the recorded PROGRAM's argv, not the recorder's own
# (verified with `ct-print --meta-json`: `args` is the program's, `recorder` is
# empty), and nothing else on this path reports the child argv.  Reading it
# would require wrapping the recorder in a logging shim -- a synthesised
# behavioural stand-in the mocking policy (§5.7) does not allow here, and one
# that would prove only that the shim saw the flag.
#
# So each declared flag is checked by the thing it is FOR.  The table is
# deliberately closed: a flag with no entry is a hard failure, so LRC-4 adding
# a recorder with a different flag has to state what that flag's observable
# effect is instead of getting a free green assertion.
#
# RESIDUAL LIMITATION, stated rather than papered over: an observable-effect
# check proves the OUTCOME the flag exists for, not the literal spelling on the
# child's command line.  It cannot tell `--out-dir` from its documented `-o`
# alias, nor from a recorder's `CODETRACER_<LANG>_RECORDER_OUT_DIR` environment
# fallback.  That is the price of §5.7 (no behavioural stand-ins) and it is why
# the fixture's flag list is a declaration of intent backed by an effect check,
# not an argv assertion.  Closing it would need either a product change (the
# core logging the invocation it spawns) or a shim; both are out of scope here.
# ---------------------------------------------------------------------------
check_recorder_flag() {
	local id="$1" flag="$2" trace_dir="$3"
	case "$flag" in
	--out-dir | --trace-dir | -o)
		# Without it the recorder writes to its own default location relative
		# to the cwd it inherits from `ct` -- `recorder.default-out-dir` in the
		# fixture, because that default is per-recorder (the python recorder
		# uses `./trace-out`; Recorder-CLI-Conventions.md §3 documents
		# `./ct-traces/` as the convention, and the two do not agree today).
		# We ran from an empty scratch cwd, so "the trace is under the
		# directory we asked for AND the recorder's default location stayed
		# empty" is exactly the flag's contract.
		if [[ -n ${TRACE_FILE:-} && $TRACE_FILE == "$trace_dir"/* ]]; then
			ok "$id: '$flag' honoured — the trace landed in the requested directory"
		else
			bad "$id: '$flag' was not honoured — trace at '${TRACE_FILE:-<none>}', expected under $trace_dir"
		fi
		assert_true "$id: '$flag' was passed — the recorder's default location './$FX_DEFAULT_OUT_DIR' stayed empty" \
			test ! -e "$RUN_CWD/$FX_DEFAULT_OUT_DIR"
		;;
	*)
		bad "$id: no observable check is defined for recorder flag '$flag' — add one to check_recorder_flag() rather than asserting nothing"
		;;
	esac
}

scenario_negative_routing() {
	local s="$1" id="$2"
	local cmd rel_sample sample stdout_f stderr_f rc
	cmd="$(fx_get "$s.command")"
	rel_sample="$(fx_get "$s.sample")"
	sample="$RECORDER_DIR/$rel_sample"
	[[ -f $sample ]] || {
		bad "$id: negative sample not found: $sample"
		return
	}
	assert_declared_extension "$id" "$(fx_get "$s.extension")" "$sample"
	# Design §5.3 step 8 is about an extension the desktop component does not
	# DECLARE, not about a dot-less argument (that is a separate, pre-existing
	# routing gap owned by LRC-4, and testing it here would assert a known bug
	# instead of the capability contract).  Assert the scenario really is the
	# former: a well-formed extension that the shipped capability file does not
	# list.
	local neg_ext
	neg_ext="$(fx_get "$s.extension")"
	assert_true "$id: the negative case names a well-formed extension (not a dot-less argument)" \
		is_well_formed_extension "$neg_ext"
	assert_true "$id: '$neg_ext' is genuinely undeclared by the shipped capability file" \
		extension_undeclared "$neg_ext"

	stdout_f="$WORK_DIR/$id.out"
	stderr_f="$WORK_DIR/$id.err"
	local run_cwd="$WORK_DIR/cwd-$id"
	mkdir -p "$run_cwd"
	echo "  \$ $(basename "$LAUNCHER_BIN") $cmd $rel_sample"
	(cd "$run_cwd" && "$LAUNCHER_BIN" "$cmd" "$sample") >"$stdout_f" 2>"$stderr_f"
	rc=$?
	sed 's/^/  ! /' "$stderr_f" | tail -n 6

	assert_true "$id: the launcher refused to route an undeclared extension (exit $rc != 0)" \
		test "$rc" -ne 0
	local needle
	while IFS= read -r needle; do
		[[ -n $needle ]] || continue
		assert_contains "$id: diagnostic mentions '$needle'" "$needle" "$stderr_f"
	done < <(fx_list "$s.expect.stderr-contains")
	assert_true "$id: nothing was recorded as a side effect" \
		test -z "$(find "$run_cwd" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)"
}

scenario_launcher_version() {
	local s="$1" id="$2"
	local stdout_f rc re
	stdout_f="$WORK_DIR/$id.out"
	"$LAUNCHER_BIN" --version >"$stdout_f" 2>&1
	rc=$?
	sed 's/^/  | /' "$stdout_f"
	assert_eq "$id: ct --version exited 0" "0" "$rc"
	re="$(fx_get "$s.expect.stdout-matches")"
	if [[ -n $re ]]; then
		if grep -qE -- "$re" "$stdout_f"; then
			ok "$id: ct --version matches /$re/"
		else
			bad "$id: ct --version does not match /$re/"
		fi
	fi
	# The launcher answers --version itself and never execs the component, so
	# this must NOT be the core's confutils banner.  Asserting the difference
	# is what makes it evidence that $LAUNCHER_BIN really is the launcher.
	if grep -q "CodeTracer version:" "$stdout_f"; then
		bad "$id: --version printed the CORE's banner -- \$LAUNCHER_BIN is not the launcher"
	else
		ok "$id: --version came from the launcher, not from the desktop core"
	fi
}

scenario_isolation() {
	local s="$1" id="$2"
	local cmd rel_sample sample stdout_f stderr_f rc empty_root
	cmd="$(fx_get "$s.command")"
	rel_sample="${SAMPLE_OVERRIDE:-$(fx_get "$s.sample")}"
	sample="$RECORDER_DIR/$rel_sample"
	assert_declared_extension "$id" "$(fx_get "$s.extension")" "$sample"
	empty_root="$WORK_DIR/empty-components"
	mkdir -p "$empty_root"
	stdout_f="$WORK_DIR/$id.out"
	stderr_f="$WORK_DIR/$id.err"

	echo "  \$ CODETRACER_COMPONENTS_ROOT=<empty> $(basename "$LAUNCHER_BIN") $cmd $rel_sample"
	CODETRACER_COMPONENTS_ROOT="$empty_root" \
		"$LAUNCHER_BIN" "$cmd" "$sample" -o "$WORK_DIR/trace-$id" \
		>"$stdout_f" 2>"$stderr_f"
	rc=$?
	sed 's/^/  ! /' "$stderr_f" | tail -n 6
	assert_true "$id: routing fails when the staged bundle is removed (exit $rc != 0)" \
		test "$rc" -ne 0
	local needle
	while IFS= read -r needle; do
		[[ -n $needle ]] || continue
		assert_contains "$id: diagnostic mentions '$needle'" "$needle" "$stderr_f"
	done < <(fx_list "$s.expect.stderr-contains")
	assert_true "$id: no trace directory was produced without a component" \
		test ! -d "$WORK_DIR/trace-$id"
}

# ---------------------------------------------------------------------------
# Run.
# ---------------------------------------------------------------------------
step_build_launcher
step_resolve_core
step_build_recorder
step_stage_component
step_export_discovery
resolve_ct_print

for idx in "${SCENARIO_IDX[@]}"; do
	s="scenarios.$idx"
	id="$(fx_get "$s.id")"
	kind="$(fx_get "$s.kind")"
	begin_scenario "$id" "$kind"
	case "$kind" in
	record) scenario_record "$s" "$id" ;;
	negative-routing) scenario_negative_routing "$s" "$id" ;;
	launcher-version) scenario_launcher_version "$s" "$id" ;;
	isolation) scenario_isolation "$s" "$id" ;;
	*) bad "$id: unknown scenario kind '$kind' in $FIXTURE" ;;
	esac
done

# ---------------------------------------------------------------------------
# Step 9 -- zero-test guard (design §5.5,
# Cross-Repo-CI-Integration.md "Zero-Test Guard").
#
# Three separate ways this run could have proved nothing, each fatal:
#   * no scenario ran at all;
#   * fewer scenarios ran than the fixture declares (one was silently dropped);
#   * scenarios ran but made no assertions.
# ---------------------------------------------------------------------------
echo
if [[ $SCENARIOS -eq 0 ]]; then
	echo "FAIL: no scenario ran -- the gate would have passed vacuously" >&2
	exit 1
fi
if [[ $SCENARIOS -ne $DECLARED_SCENARIOS ]]; then
	echo "FAIL: $FIXTURE declares $DECLARED_SCENARIOS scenarios but $SCENARIOS ran" >&2
	echo "  ran:$EXECUTED_IDS" >&2
	exit 1
fi
if [[ $((PASSED + FAILED)) -eq 0 ]]; then
	echo "FAIL: no assertions ran -- the harness itself is broken" >&2
	exit 1
fi

echo "scenarios: $SCENARIOS   assertions: $((PASSED + FAILED))   passed: $PASSED   failed: $FAILED"
if [[ $FAILED -ne 0 ]]; then
	echo "FAILURES:$FAILURES" >&2
	exit 1
fi
echo "PASS"
