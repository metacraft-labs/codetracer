#!/usr/bin/env bash
# =============================================================================
# Contract: one sibling that fails to build fails `build-siblings.sh` by
# default, and under `--keep-going` (or BUILD_SIBLINGS_KEEP_GOING=1) is named
# without failing the run, and leaves no stale artifact behind.
#
#   bash ci/test/build-siblings-keep-going-test.sh
#
# WHY THIS FILE EXISTS
#   codetracer-flow-recorder's committed Cargo.lock stopped matching its path
#   dependency on codetracer-trace-format, so its `cargo build --locked`
#   failed. `just test-gui` runs this script first and failed with it, so every
#   codetracer-observability-e2e recipe that runs one Playwright spec through
#   `just test-gui` failed on a recorder that spec never uses (codetracer-pm
#   issues/2026-11-07-flow-recorder-cargo-lock-breaks-codetracer-sibling-
#   build.md). A caller that runs a subset of the suite, and whose specs fail
#   by name when a sibling they need is absent, must be able to say so. The
#   whole-suite run (CI's `just test-gui`) keeps failing on any sibling.
#
# WHAT IT DOES
#   Copies the real `scripts/build-siblings.sh` into a scratch workspace that
#   holds two sibling git checkouts, each with a real `justfile`:
#     codetracer-flow-recorder   `build-release` fails with cargo's --locked
#                                refusal, and an artifact from an earlier
#                                build is already in place;
#     codetracer-cairo-recorder  `build-release` writes its artifact.
#   It runs `--force --only -recorder --skip cadence` (the two recorder
#   entries, not the flow repo's Go helper) three times and requires:
#     1. by default: exit 1, flow named FAIL, cairo PASS, and a closing line
#        naming the failed sibling;
#     2. with `--keep-going`: exit 0, flow named FAIL with its log tail, cairo
#        PASS, a closing line naming the failed sibling, and flow's earlier
#        artifact removed, so no consumer runs a binary the failed build did
#        not produce;
#     3. with BUILD_SIBLINGS_KEEP_GOING=1 and no flag: exit 0 as in 2. The
#        variable is how a caller of `just test-gui`, which passes no
#        arguments to this script, opts in.
#   Needs `just`, `git`, and the toolchain lookup's `nim`, `nimble` and
#   `pkg-config` with libzstd, as codetracer's dev shell provides. No network,
#   no Nix, a few seconds.
#
# Mocks: one. `repro` is replaced by a stub that runs its command in the
#   caller's environment (`repro exec <dir> -- <cmd>` -> `<cmd>`). The script
#   enters each sibling's own dev shell through `repro exec`, and the scratch
#   siblings have no flake to enter; what this file checks is how the script
#   treats the outcome of each build, not how the environment is activated.
#   The builds themselves run for real, through the real `just`.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/build-siblings.sh"

failures=0
pass() { echo "  ok   $*"; }
fail() {
	echo "  FAIL $*" >&2
	failures=$((failures + 1))
}

for tool in just git nim nimble pkg-config; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "FAIL: '$tool' is not on PATH; run this test inside codetracer's dev shell (just test-build-siblings-keep-going)" >&2
		exit 1
	fi
done

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

WS="$SCRATCH/ws"
mkdir -p "$WS/codetracer/scripts" "$SCRATCH/bin"
cp "$SCRIPT" "$WS/codetracer/scripts/build-siblings.sh"

cat >"$SCRATCH/bin/repro" <<'EOF'
#!/usr/bin/env bash
# repro exec <dir> -- <cmd...>  ->  <cmd...>
[ "${1:-}" = exec ] || { echo "repro stub: only 'exec' is supported" >&2; exit 2; }
shift 2
[ "${1:-}" = -- ] && shift
exec "$@"
EOF
chmod +x "$SCRATCH/bin/repro"

# make_sibling <name> <build-release recipe body>
make_sibling() {
	local dir="$WS/$1"
	mkdir -p "$dir"
	printf 'build-release:\n%s\n' "$2" >"$dir/justfile"
	if ! {
		git -C "$dir" init -q &&
			git -C "$dir" add justfile &&
			git -C "$dir" -c user.name=t -c user.email=t@t commit -qm init
	}; then
		echo "FAIL: cannot create the scratch sibling $1" >&2
		exit 1
	fi
}

make_sibling codetracer-flow-recorder \
	"  @echo 'error: the lock file Cargo.lock needs to be updated but --locked was passed to prevent this' >&2; exit 101"
make_sibling codetracer-cairo-recorder \
	"  mkdir -p target/release && printf '#!/bin/sh\n' >target/release/codetracer-cairo-recorder && chmod +x target/release/codetracer-cairo-recorder"

FLOW_ARTIFACT="$WS/codetracer-flow-recorder/target/release/codetracer-flow-recorder"
plant_stale_flow_artifact() {
	mkdir -p "$(dirname "$FLOW_ARTIFACT")" && printf 'stale\n' >"$FLOW_ARTIFACT"
}

# run_script <out> [env assignments...] -- [script args...]
run_script() {
	local out="$1"
	shift
	local -a envs=()
	while [ "$1" != -- ]; do
		envs+=("$1")
		shift
	done
	shift
	env PATH="$SCRATCH/bin:$PATH" BUILD_SIBLINGS_KEEP_GOING= "${envs[@]}" \
		bash "$WS/codetracer/scripts/build-siblings.sh" \
		--force --only -recorder --skip cadence "$@" >"$out" 2>&1
}

summary_has() { # <out> <state> <key>
	# A here-string, not a pipe: under pipefail a `grep -q` that matches early
	# can SIGPIPE `sed` and report the match as a failure
	# (ci/test/grep-q-pipefail-gate.sh).
	grep -Eq "^  $2 +$3 " <<<"$(sed -n '/^==== build-siblings summary ====$/,$p' "$1")"
}

# check_keep_going <label> <out> <rc>
check_keep_going() {
	local label="$1" out="$2" rc="$3"
	if [ "$rc" -eq 0 ]; then
		pass "$label: exit 0 although a sibling failed"
	else
		fail "$label: expected exit 0, got $rc: $(tail -n 5 "$out" | tr '\n' ' ')"
	fi
	if summary_has "$out" FAIL codetracer-flow-recorder; then
		pass "$label: the failed sibling is named FAIL in the summary"
	else
		fail "$label: the summary does not name codetracer-flow-recorder as FAIL: $(cat "$out")"
	fi
	if summary_has "$out" PASS codetracer-cairo-recorder; then
		pass "$label: the other sibling still built"
	else
		fail "$label: codetracer-cairo-recorder is not PASS in the summary: $(cat "$out")"
	fi
	if grep -q 'needs to be updated but --locked was passed' "$out"; then
		pass "$label: the failed build's own error reaches the output"
	else
		fail "$label: the failed build's log tail is not in the output"
	fi
	if grep -Eq '^build-siblings\.sh: 1 sibling\(s\) failed to build: codetracer-flow-recorder; continuing' "$out"; then
		pass "$label: a closing line names the failed sibling and says the run continues"
	else
		fail "$label: no closing line names the failed sibling: $(tail -n 3 "$out" | tr '\n' ' ')"
	fi
	if [ ! -e "$FLOW_ARTIFACT" ]; then
		pass "$label: the failed sibling's earlier artifact was removed"
	else
		fail "$label: $FLOW_ARTIFACT survived a failed build; a consumer would run a binary the build did not produce"
	fi
}

echo "== build-siblings: a failed sibling fails the run by default"
plant_stale_flow_artifact
out="$SCRATCH/strict.out"
run_script "$out" -- && rc=0 || rc=$?
if [ "$rc" -eq 1 ]; then
	pass "default: exit 1"
else
	fail "default: expected exit 1, got $rc: $(tail -n 5 "$out" | tr '\n' ' ')"
fi
if summary_has "$out" FAIL codetracer-flow-recorder && summary_has "$out" PASS codetracer-cairo-recorder; then
	pass "default: flow FAIL, cairo PASS"
else
	fail "default: unexpected summary: $(cat "$out")"
fi
if grep -Eq '^build-siblings\.sh: 1 sibling\(s\) failed to build: codetracer-flow-recorder$' "$out"; then
	pass "default: a closing line names the failed sibling, without claiming to continue"
else
	fail "default: no closing line names the failed sibling: $(tail -n 3 "$out" | tr '\n' ' ')"
fi

echo "== build-siblings --keep-going"
plant_stale_flow_artifact
out="$SCRATCH/flag.out"
run_script "$out" -- --keep-going && rc=0 || rc=$?
check_keep_going "--keep-going" "$out" "$rc"

echo "== BUILD_SIBLINGS_KEEP_GOING=1"
plant_stale_flow_artifact
out="$SCRATCH/env.out"
run_script "$out" BUILD_SIBLINGS_KEEP_GOING=1 -- && rc=0 || rc=$?
check_keep_going "BUILD_SIBLINGS_KEEP_GOING=1" "$out" "$rc"

echo
if [ "$failures" -ne 0 ]; then
	echo "build-siblings keep-going: $failures check(s) failed" >&2
	exit 1
fi
echo "build-siblings keep-going: all checks passed"
