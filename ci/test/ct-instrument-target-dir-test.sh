#!/usr/bin/env bash
# =============================================================================
# Contract: `ct-instrument` is found where cargo put it, whatever
# CARGO_TARGET_DIR the environment carries.
#
# # Why this file exists
#
# test-non-gui builds `ct-instrument` in the codetracer-wasm-instrumenter
# sibling, and the db-backend suites then reach it through
# `scripts/materialize-recording.sh`, which records the
# `cross-process-three-trace` fixture with it. The self-hosted runners export a
# runner-wide CARGO_TARGET_DIR (infra `services/github-runners/default.nix`),
# so cargo put the binary THERE, and both the build step's own existence check
# and the materializer looked only in `<sibling>/target/`:
#
#   Finished `release` profile [optimized] target(s) in 1m 30s
#   ##[error]cargo build reported success but target/release/ct-instrument is
#   missing; scripts/materialize-recording.sh cannot produce the cross-process
#   recording.
#
# (codetracer-pm issues/2026-10-22-test-non-gui-ct-instrument-build-ignores-
# the-runners-cargo-target-dir.md). Two halves, one per place that went wrong:
#
#   1. The workflow step that builds the binary pins CARGO_TARGET_DIR to the
#      sibling's own `target/` on its `cargo build`, so the path it then checks
#      is the path cargo wrote. The same lane already pins it for the native
#      backend and the Ruby recorder builds.
#   2. `scripts/materialize-recording.sh` finds a binary that a build under a
#      foreign CARGO_TARGET_DIR left in that directory, and still prefers the
#      sibling's own `target/` when both exist.
#
# # The one stand-in, and why it is not a mock of anything under test
#
# Half 2 runs the REAL materializer against a scratch instrumenter directory.
# The `ct-instrument` it is offered is a placeholder file: the materializer only
# checks that the binary is executable before it reaches its prerequisite gate,
# and the run is deliberately stopped AT that gate by a PATH without cargo,
# rustc or node, so nothing is ever executed or recorded. What is observed is
# the materializer's own verdict on stderr: whether `ct-instrument` is among the
# missing prerequisites it lists. A real `cargo build` of the instrumenter would
# test the same lookup at the cost of a minutes-long Rust build per run.
#
# Run: bash ci/test/ct-instrument-target-dir-test.sh [workflow]
# Lane: a step of the `ci-contract-suites` job in codetracer.yml (stock
#       ubuntu-latest: bash and coreutils -- no Nix, no dev shell).
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly REPO_ROOT
WORKFLOW="${1:-$REPO_ROOT/.github/workflows/codetracer.yml}"
readonly WORKFLOW
readonly MATERIALIZER="$REPO_ROOT/scripts/materialize-recording.sh"
readonly BUILD_STEP_NAME='Build ct-instrument (codetracer-wasm-instrumenter sibling)'

assertions=0
failures=0
ok() {
	assertions=$((assertions + 1))
	printf '  ok   %s\n' "$1"
}
fail() {
	assertions=$((assertions + 1))
	failures=$((failures + 1))
	printf '  FAIL %s\n' "$1"
	if [ "$#" -gt 1 ]; then
		shift
		printf '         %s\n' "$@"
	fi
}

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# ---------------------------------------------------------------------------
# 1. The build step pins where cargo writes.
# ---------------------------------------------------------------------------
echo "the ct-instrument build step pins its target directory"

# The step's body: from its `- name:` line to the next step or job, with
# backslash-continued lines joined so an assignment written on the line before
# `cargo build` is read as part of the same command. Only lines that RUN cargo
# count: the step's own error message names "cargo build" in an echo.
step_body="$(
	awk -v want="      - name: $BUILD_STEP_NAME" '
		$0 == want { inside = 1; next }
		inside && (/^      - / || /^  [A-Za-z0-9_-]+:/) { exit }
		inside && sub(/\\$/, "") { pending = pending $0 " "; next }
		inside { print pending $0; pending = "" }
	' "$WORKFLOW"
)"
cargo_lines=()
while IFS= read -r line; do
	cargo_lines+=("$line")
done < <(grep -E 'cargo build' <<<"$step_body" | grep -vE '^[[:space:]]*echo[[:space:]]' || true)

if [ "${#cargo_lines[@]}" -eq 0 ]; then
	fail "the step '$BUILD_STEP_NAME' runs cargo build" \
		"no 'cargo build' found in that step of $WORKFLOW; the assertions below" \
		"would describe nothing. If the step was renamed, retarget BUILD_STEP_NAME."
else
	ok "the step '$BUILD_STEP_NAME' runs cargo build (${#cargo_lines[@]})"
fi

unpinned=()
for line in "${cargo_lines[@]+"${cargo_lines[@]}"}"; do
	# `$PWD/target` after the step's `cd` into the sibling: the directory the
	# step's own existence check reads. The needles are the workflow's text,
	# so `$PWD` must stay unexpanded here.
	# shellcheck disable=SC2016
	[[ $line == *'CARGO_TARGET_DIR="$PWD/target"'* || $line == *'CARGO_TARGET_DIR="${PWD}/target"'* ]] ||
		unpinned+=("$line")
done
# shellcheck disable=SC2016 # the assertion names the literal text `$PWD/target`
if [ "${#cargo_lines[@]}" -gt 0 ] && [ "${#unpinned[@]}" -eq 0 ]; then
	ok 'every cargo build in it sets CARGO_TARGET_DIR="$PWD/target"'
else
	fail 'every cargo build in it sets CARGO_TARGET_DIR="$PWD/target"' \
		"the self-hosted runners export a runner-wide CARGO_TARGET_DIR, so without" \
		"the pin cargo writes the binary there and the step's own check of" \
		"target/release/ct-instrument fails after a successful build" \
		"${unpinned[@]+"${unpinned[@]}"}"
fi

# ---------------------------------------------------------------------------
# 2. The materializer finds the binary under a foreign CARGO_TARGET_DIR.
# ---------------------------------------------------------------------------
echo
echo "scripts/materialize-recording.sh finds ct-instrument where cargo put it"

# A PATH with the coreutils the materializer runs before its gate, and without
# cargo, rustc, node or a ct-instrument: the gate is then certain to stop the
# run, so this never records anything.
minimal_bin="$SCRATCH/bin"
mkdir -p "$minimal_bin"
for tool in bash dirname mkdir rm cat sort cut tr; do
	tool_path="$(command -v "$tool")" || {
		echo "ct-instrument-target-dir-test: '$tool' is not on PATH" >&2
		exit 2
	}
	ln -s "$tool_path" "$minimal_bin/$tool"
done

# An instrumenter checkout with the runtime directory the materializer also
# requires, and nothing in its own target/.
instrumenter="$SCRATCH/codetracer-wasm-instrumenter"
mkdir -p "$instrumenter/recorder-runtime"

place_binary() { # $1 = directory that gets release/ct-instrument
	mkdir -p "$1/release"
	printf '#!/bin/sh\nexit 97\n' >"$1/release/ct-instrument"
	chmod +x "$1/release/ct-instrument"
}

# Runs the materializer for a fixture with no JavaScript tier; prints its
# stderr. Extra `NAME=value` arguments go into its environment.
run_materializer() {
	{
		env -i HOME="$SCRATCH" PATH="$minimal_bin" \
			CODETRACER_WASM_INSTRUMENTER_PATH="$instrumenter" "$@" \
			bash "$MATERIALIZER" wasm-memory-calldata >/dev/null
	} 2>&1
}

# Positive control: with nothing built anywhere, the materializer must report
# ct-instrument missing. Without this, "not reported missing" below could mean
# the gate is no longer checked at all.
control_out="$(run_materializer)"
if grep -q 'ct-instrument not found' <<<"$control_out"; then
	ok "control: with no binary anywhere, the materializer reports ct-instrument missing"
else
	fail "control: with no binary anywhere, the materializer reports ct-instrument missing" \
		"its output was:" "$control_out"
fi

# The reported case: built with a foreign, absolute CARGO_TARGET_DIR.
runner_cargo="$SCRATCH/runner-cargo"
place_binary "$runner_cargo"
foreign_out="$(run_materializer CARGO_TARGET_DIR="$runner_cargo")"
if grep -q 'cargo not on PATH' <<<"$foreign_out" &&
	! grep -q 'ct-instrument not found' <<<"$foreign_out"; then
	ok "a binary under a foreign CARGO_TARGET_DIR is found"
else
	fail "a binary under a foreign CARGO_TARGET_DIR is found" \
		"CARGO_TARGET_DIR=$runner_cargo holds release/ct-instrument, which is where" \
		"cargo puts it on the self-hosted runners; the materializer's output was:" \
		"$foreign_out"
fi

# A relative CARGO_TARGET_DIR is relative to where cargo ran: the instrumenter.
place_binary "$instrumenter/relative-target"
relative_out="$(run_materializer CARGO_TARGET_DIR=relative-target)"
if grep -q 'cargo not on PATH' <<<"$relative_out" &&
	! grep -q 'ct-instrument not found' <<<"$relative_out"; then
	ok "a relative CARGO_TARGET_DIR is read from the instrumenter root"
else
	fail "a relative CARGO_TARGET_DIR is read from the instrumenter root" \
		"the materializer's output was:" "$relative_out"
fi

# The sibling's own target/ still wins when both hold a binary: a runner-wide
# directory is shared by every job on the runner and may hold a binary an
# earlier job built from another revision. The materializer does not print the
# binary it chose before its gate, so the lookup function is extracted from the
# script verbatim and evaluated on its own.
resolver="$(awk '/^resolve_ct_instrument\(\) \{/,/^}/' "$MATERIALIZER")"
if [ -z "$resolver" ]; then
	fail "the sibling's own target/ is preferred over CARGO_TARGET_DIR" \
		"resolve_ct_instrument() was not found in $MATERIALIZER"
else
	place_binary "$instrumenter/target"
	chosen="$(
		env -i PATH="$minimal_bin" CARGO_TARGET_DIR="$runner_cargo" \
			CODETRACER_WASM_INSTRUMENTER_PATH="$instrumenter" WORKSPACE_ROOT="$SCRATCH" \
			bash -c "$resolver"$'\n''resolve_ct_instrument'
	)"
	if [ "$chosen" = "$instrumenter/target/release/ct-instrument" ]; then
		ok "the sibling's own target/ is preferred over CARGO_TARGET_DIR"
	else
		fail "the sibling's own target/ is preferred over CARGO_TARGET_DIR" \
			"expected $instrumenter/target/release/ct-instrument, got '${chosen:-<nothing>}'"
	fi
fi

echo
readonly EXPECTED_ASSERTIONS=6
if [ "$assertions" -ne "$EXPECTED_ASSERTIONS" ]; then
	printf 'FAIL: ran %d assertions, expected %d\n' "$assertions" "$EXPECTED_ASSERTIONS"
	failures=$((failures + 1))
fi
if [ "$failures" -ne 0 ]; then
	printf '%d of %d assertions failed\n' "$failures" "$assertions"
	exit 1
fi
printf 'all %d assertions passed\n' "$assertions"
