#!/usr/bin/env bash
# Produce a recording from the current tree, once per build, and print
# where it landed.
#
# # Why this exists
#
# Recordings used to be committed. Every one of them was made by the
# *current* pipeline, so the arrangement had the shape of a golden test
# without the property that makes a golden test worth having: an
# artefact produced by today's recorder and replayed by today's replayer
# proves the two agree with each other, and keeps proving it after the
# recorder changes underneath it. That is not a check, it is a cache
# with an assertion attached. It has already cost this campaign six
# weeks — four `TestRecorderGolden*` files went red the day a sibling
# repo changed the wire format, and were read as stale fixtures rather
# than as the signal they were.
#
# A committed recording is only evidence when it was made by a version
# that no longer exists. Exactly one recording in this workspace meets
# that bar (`codetracer-wasm-recorder`'s `legacy-encoding.ct`, made by a
# `ct-instrument` that predates the current boundary-value encoding) and
# it stays committed. Everything else is produced here, from the tree the
# test is about to exercise.
#
# # The contract
#
#     materialize-recording.sh <fixture-id>
#
# prints one line — the absolute path of a directory holding the
# recordings — and exits 0. Anything else is a failure with a diagnostic
# on stderr. There is no exit status that means "skip": a caller that
# cannot record must say so itself, visibly, or fail.
#
# # Once per build, not once per test
#
# The pipelines are expensive (build WASM -> instrument -> bundle ->
# recording daemon + recorded server -> drive headless Chromium; ~40 s
# for the three-recording fixture). Output is cached under
# `target/test-recordings/`, which `.gitignore` already covers, and the
# whole production runs under `flock` so the five Rust tests in one
# binary, a Playwright worker and a Nim ViewModel test can all ask at
# once and exactly one of them records.
#
# # The cache key is the point
#
# The key is a digest of everything that can change what gets recorded:
# the fixture's own tracked sources, the recorder and instrumenter
# binaries *by content*, the browser recorder's shipped JavaScript, and
# the compiler and runtime versions. Change `ct-instrument`, or
# `session-manager`, or one line of the demo, and the key moves and the
# recording is made again. That is the entire reason this file exists —
# a cache that could survive a recorder change would reintroduce the bug
# it was written to remove. Binaries are hashed rather than stat'ed
# because a rebuild that produces identical bytes should legitimately
# hit the cache, and a rebuild that produces different bytes must not.
#
# The fixture's whole tracked file set goes in, including its README, so
# editing prose costs one re-recording. That is deliberate: the error is
# one-sided. Over-invalidating costs 40 seconds; under-invalidating cost
# this campaign six weeks, and a curated list of "files that really
# matter" is exactly the artefact that goes out of date silently.
#
# # Overriding
#
# `CT_RECORDINGS_DIR=<dir>` skips production entirely and uses `<dir>`
# as the cache root, for the one case that is legitimate: a CI job that
# recorded in an earlier stage and passes the artefact down. It is an
# explicit, visible, configured decision, which is the only acceptable
# form of "do not record here".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
readonly REPO_ROOT
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd -P)"
readonly WORKSPACE_ROOT
FIXTURES_ROOT="$REPO_ROOT/src/db-backend/tests/fixtures"
readonly FIXTURES_ROOT

die() {
	echo "materialize-recording: $*" >&2
	exit 1
}

usage() {
	cat >&2 <<'USAGE'
usage: materialize-recording.sh <fixture-id>

  cross-process-three-trace  frontend.ct + frontend-wasm.ct + backend.ct + session.toml
  wasm-memory-calldata       ledger-settle.ct + the module it was recorded against
  wasm-nan-payloads          nan-payloads.ct + the module it was recorded against
  wasm-parity-corpus         four recordings + the four modules they were recorded against

Prints the absolute path of a directory holding the recordings.
USAGE
	exit 2
}

FIXTURE="${1:-}"
[ -n "$FIXTURE" ] || usage

case "$FIXTURE" in
cross-process-three-trace)
	FIXTURE_DIR="$FIXTURES_ROOT/cross_process/account-balance-with-wasm"
	# The three-tier demo is the only fixture with a JavaScript tier, so
	# it is the only one whose recording depends on the JS recorder.
	NEEDS_JS_RECORDER=1
	;;
wasm-memory-calldata | wasm-nan-payloads | wasm-parity-corpus)
	FIXTURE_DIR="$FIXTURES_ROOT/$FIXTURE"
	NEEDS_JS_RECORDER=0
	;;
*)
	echo "materialize-recording: unknown fixture '$FIXTURE'" >&2
	usage
	;;
esac
readonly FIXTURE FIXTURE_DIR NEEDS_JS_RECORDER
[ -d "$FIXTURE_DIR" ] || die "fixture directory is missing: $FIXTURE_DIR"

REGENERATE="$FIXTURE_DIR/regenerate.sh"
readonly REGENERATE
[ -x "$REGENERATE" ] || die "fixture regenerator is missing or not executable: $REGENERATE"

# ---------------------------------------------------------------------------
# Digests.
#
# `sha256sum` over sorted content, never over mtimes: a rebuild that
# lands on identical bytes should hit the cache, and only a change in
# what a tool would actually *do* should miss it.
# ---------------------------------------------------------------------------
sha_of_stdin() { sha256sum | cut -d' ' -f1; }

# Digest of a file, or of a directory tree (paths + contents, so a
# rename is a change).
digest_path() {
	local target="$1"
	if [ -f "$target" ]; then
		sha256sum <"$target" | cut -d' ' -f1
		return
	fi
	if [ -d "$target" ]; then
		(
			cd "$target"
			find . -type f -print0 |
				LC_ALL=C sort -z |
				xargs -0 -r sha256sum |
				sha_of_stdin
		)
		return
	fi
	die "cannot digest a path that does not exist: $target"
}

# Digest of the fixture's own inputs. `git ls-files` is the right
# enumeration because it excludes build output by construction; the
# `find` fallback keeps this working in an exported tree with no `.git`.
digest_fixture_sources() {
	if git -C "$FIXTURE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
		(
			cd "$FIXTURE_DIR"
			git ls-files -z |
				LC_ALL=C sort -z |
				xargs -0 -r sha256sum |
				sha_of_stdin
		)
		return
	fi
	(
		cd "$FIXTURE_DIR"
		find . -type f \
			-not -path './*/target/*' \
			-not -path './*/build/*' \
			-not -path './*/node_modules/*' \
			-not -name '*.ct' \
			-print0 |
			LC_ALL=C sort -z |
			xargs -0 -r sha256sum |
			sha_of_stdin
	)
}

# ---------------------------------------------------------------------------
# Tool resolution.
#
# Resolved here rather than left to `regenerate.sh` so the binary that
# is *hashed into the key* is provably the binary that will *run*: they
# are exported, and `regenerate.sh` honours the same variables.
# ---------------------------------------------------------------------------
missing=()

resolve_ct_instrument() {
	local instrumenter="${CODETRACER_WASM_INSTRUMENTER_PATH:-$WORKSPACE_ROOT/codetracer-wasm-instrumenter}"
	local candidate
	if [ -n "${CT_INSTRUMENT_BIN:-}" ] && [ -x "${CT_INSTRUMENT_BIN}" ]; then
		printf '%s\n' "$CT_INSTRUMENT_BIN"
		return 0
	fi
	for candidate in \
		"$instrumenter/target/release/ct-instrument" \
		"$instrumenter/target/debug/ct-instrument"; do
		if [ -x "$candidate" ]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	if command -v ct-instrument >/dev/null 2>&1; then
		command -v ct-instrument
		return 0
	fi
	return 1
}

resolve_record_web() {
	local candidate
	if [ -n "${CODETRACER_RECORD_WEB_BIN:-}" ] && [ -x "${CODETRACER_RECORD_WEB_BIN}" ]; then
		printf '%s\n' "$CODETRACER_RECORD_WEB_BIN"
		return 0
	fi
	for candidate in \
		"$REPO_ROOT/src/backend-manager/target/release/session-manager" \
		"$REPO_ROOT/src/backend-manager/target/debug/session-manager" \
		"$REPO_ROOT/src/build-debug/bin/session-manager"; do
		if [ -x "$candidate" ]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	return 1
}

INSTRUMENTER_ROOT="${CODETRACER_WASM_INSTRUMENTER_PATH:-$WORKSPACE_ROOT/codetracer-wasm-instrumenter}"
readonly INSTRUMENTER_ROOT
JS_RECORDER_ROOT="${CODETRACER_JS_RECORDER_PATH:-$WORKSPACE_ROOT/codetracer-js-recorder}"
readonly JS_RECORDER_ROOT

CT_INSTRUMENT_BIN="$(resolve_ct_instrument || true)"
[ -n "$CT_INSTRUMENT_BIN" ] ||
	missing+=("- ct-instrument not found (cargo build --release -p ct-instrument-cli in $INSTRUMENTER_ROOT)")

RECORD_WEB_BIN="$(resolve_record_web || true)"
[ -n "$RECORD_WEB_BIN" ] ||
	missing+=("- session-manager not built (cargo build in $REPO_ROOT/src/backend-manager)")

[ -d "$INSTRUMENTER_ROOT/recorder-runtime" ] ||
	missing+=("- the instrumenter's recorder-runtime/ is not present at $INSTRUMENTER_ROOT")

if [ "$NEEDS_JS_RECORDER" -eq 1 ]; then
	[ -f "$JS_RECORDER_ROOT/packages/cli/dist/index.js" ] ||
		missing+=("- codetracer-js-recorder is not built ($JS_RECORDER_ROOT/packages/cli/dist/index.js; run 'just build' there)")
fi

command -v cargo >/dev/null 2>&1 || missing+=("- cargo not on PATH (the Rust toolchain builds the WASM tier)")
command -v node >/dev/null 2>&1 || missing+=("- node not on PATH")
if command -v rustc >/dev/null 2>&1; then
	grep -qx 'wasm32-unknown-unknown' <<<"$(rustc --print target-list 2>/dev/null)" ||
		missing+=("- rustc cannot target wasm32-unknown-unknown (rustup target add wasm32-unknown-unknown)")
else
	missing+=("- rustc not on PATH")
fi

if [ ${#missing[@]} -gt 0 ]; then
	{
		echo "materialize-recording: cannot record '$FIXTURE' — missing prerequisites:"
		printf '    %s\n' "${missing[@]}"
		echo
		echo "These recordings are produced from the current tree, not committed, so"
		echo "there is nothing to fall back to and no result that would mean anything."
		echo "Install the above, or set CT_RECORDINGS_DIR to a directory holding"
		echo "recordings produced by an earlier stage."
	} >&2
	exit 1
fi

export CT_INSTRUMENT_BIN
export CODETRACER_RECORD_WEB_BIN="$RECORD_WEB_BIN"
export CODETRACER_WASM_INSTRUMENTER_PATH="$INSTRUMENTER_ROOT"
export CODETRACER_JS_RECORDER_PATH="$JS_RECORDER_ROOT"

# ---------------------------------------------------------------------------
# The key.
# ---------------------------------------------------------------------------
key_inputs() {
	printf 'fixture\t%s\n' "$FIXTURE"
	printf 'sources\t%s\n' "$(digest_fixture_sources)"
	printf 'materializer\t%s\n' "$(digest_path "${BASH_SOURCE[0]}")"
	printf 'ct-instrument\t%s\n' "$(digest_path "$CT_INSTRUMENT_BIN")"
	printf 'record-web\t%s\n' "$(digest_path "$RECORD_WEB_BIN")"
	# The runtime the instrumented module loads in the browser is source,
	# not a binary, and changing it changes what the page records.
	printf 'recorder-runtime\t%s\n' "$(digest_path "$INSTRUMENTER_ROOT/recorder-runtime")"
	if [ "$NEEDS_JS_RECORDER" -eq 1 ]; then
		# Both `dist/` and `src/`, because the demo consumes both.
		#
		# The backend tier runs `packages/cli/dist/index.js` and resolves
		# its siblings through their `main` fields, so `dist/` is the input
		# there. The browser tier does not: the demo's `vite.config.js`
		# aliases `@codetracer/runtime-browser` straight at
		# `packages/runtime-browser/src/index.ts` — deliberately, so the
		# page exercises the working tree rather than a stale build — and
		# Vite compiles that TypeScript itself.
		#
		# Hashing only `dist/` was measured to be wrong: editing
		# `runtime-browser/src/index.ts` changed what the browser recorded
		# while leaving the key exactly where it was, so the suite would
		# have been served a recording made by the previous source. That is
		# the staleness this script exists to remove, so both trees go in.
		# Over-invalidating costs one re-recording; the other direction
		# costs the whole point.
		local js_digest
		js_digest="$(
			cd "$JS_RECORDER_ROOT/packages"
			find . \( -path '*/dist/*' -o -path '*/src/*' \) -type f -print0 |
				LC_ALL=C sort -z |
				xargs -0 -r sha256sum |
				sha_of_stdin
		)"
		printf 'js-recorder\t%s\n' "$js_digest"
	fi
	printf 'rustc\t%s\n' "$(rustc -vV | tr '\n' ' ')"
	printf 'node\t%s\n' "$(node --version)"
}

CACHE_ROOT="${CT_RECORDINGS_DIR:-$REPO_ROOT/target/test-recordings}"
readonly CACHE_ROOT

if [ -n "${CT_RECORDINGS_DIR:-}" ]; then
	# Explicitly configured hand-off: use what is there, verify it is
	# actually there, and never record.
	provided="$CACHE_ROOT/$FIXTURE"
	[ -f "$provided/.complete" ] ||
		die "CT_RECORDINGS_DIR is set but $provided holds no completed recording for '$FIXTURE'"
	printf '%s\n' "$provided"
	exit 0
fi

# Captured once: the same text is hashed into the key and recorded in
# `.complete`, so a cache directory always states exactly what it was
# made from.
KEY_INPUTS="$(key_inputs)"
readonly KEY_INPUTS
KEY="$(printf '%s\n' "$KEY_INPUTS" | sha_of_stdin | cut -c1-32)"
readonly KEY
OUT_DIR="$CACHE_ROOT/$FIXTURE/$KEY"
readonly OUT_DIR

if [ -f "$OUT_DIR/.complete" ]; then
	printf '%s\n' "$OUT_DIR"
	exit 0
fi

mkdir -p "$CACHE_ROOT/$FIXTURE"

# ---------------------------------------------------------------------------
# Produce, under a lock.
#
# One lock per fixture rather than per key: two different keys still
# contend for the same TCP ports and the same in-tree build directories,
# so serialising on the fixture is what actually prevents the collision.
# ---------------------------------------------------------------------------
LOCK="$CACHE_ROOT/$FIXTURE/.lock"
exec 9>"$LOCK"
if command -v flock >/dev/null 2>&1; then
	# Recording takes ~40 s; a wait far longer than that distinguishes
	# "queued behind a peer" from "the peer wedged", and the latter
	# should fail rather than hang a CI job forever.
	flock -w 1800 9 || die "timed out waiting for another process to finish recording '$FIXTURE'"
fi

# The winner of the lock may have produced it while we waited.
if [ -f "$OUT_DIR/.complete" ]; then
	printf '%s\n' "$OUT_DIR"
	exit 0
fi

STAGING="$OUT_DIR.staging.$$"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cleanup_staging() { rm -rf "$STAGING"; }
trap cleanup_staging EXIT

# Nested cargo: the caller is very often `cargo test`, whose environment
# would otherwise redirect the fixture's own `cargo build` into the
# caller's target directory and apply the caller's `RUSTFLAGS` to a
# wasm32 build. Both produce failures that look like fixture bugs.
#
# `LD_LIBRARY_PATH` is deliberately left alone: the dev shell sets it for
# Chromium and the recorder binaries, and clearing it breaks the browser
# stage rather than protecting it.
unset CARGO_TARGET_DIR RUSTFLAGS CARGO_ENCODED_RUSTFLAGS CARGO_MAKEFLAGS \
	CARGO_BUILD_TARGET CARGO_BUILD_RUSTFLAGS RUSTDOCFLAGS

# Ports. The pipelines run a recording daemon, a static/preview server
# and (for the three-tier demo) the recorded backend, and every one of
# them has a hard-coded default that something else on a developer's box
# is entitled to be holding — 8080 in particular. A test suite that
# fails because an unrelated service owns a port has told the reader
# nothing, so ask the kernel for ports it says are free instead of
# hoping. A caller who set them explicitly keeps them.
allocate_ports() {
	node -e '
const net = require("net");
const want = Number(process.argv[1]);
const servers = [];
const ports = [];
const step = () => {
  if (ports.length === want) {
    console.log(ports.join(" "));
    for (const s of servers) s.close();
    return;
  }
  const s = net.createServer();
  s.listen(0, "127.0.0.1", () => { servers.push(s); ports.push(s.address().port); step(); });
};
step();
' "$1"
}

# Held open only until `listen()` has reported them, so there is a window
# in which another process could take one. `regenerate.sh` still checks
# each port before it binds and fails loudly if it lost the race, which
# is the honest outcome: retrying silently is how a suite starts hiding
# the fact that its environment is contended.
read -r port_a port_b port_c <<<"$(allocate_ports 3)"
[ -n "$port_c" ] || die "could not allocate free TCP ports for the recording pipeline"
: "${DEMO_BACKEND_PORT:=$port_a}"
: "${DEMO_PREVIEW_PORT:=$port_b}"
: "${DEMO_RECORD_WEB_PORT:=$port_c}"
: "${CORPUS_PREVIEW_PORT:=$port_b}"
: "${CORPUS_RECORD_WEB_PORT:=$port_c}"
export DEMO_BACKEND_PORT DEMO_PREVIEW_PORT DEMO_RECORD_WEB_PORT \
	CORPUS_PREVIEW_PORT CORPUS_RECORD_WEB_PORT

echo "[materialize] recording '$FIXTURE' from the current tree (key ${KEY:0:12})" >&2

# `9>&-` closes the lock descriptor in the child, and it is load-bearing.
#
# `flock(2)` holds the lock on the *open file description*, which is
# released only when every descriptor referring to it is closed. Bash sets
# `FD_CLOEXEC` only on descriptors it allocates internally (>= 10), so an
# explicit `exec 9>` fd is inherited across both fork and exec — down
# through `regenerate.sh`, through `setsid`, and into the `record-web`
# daemon itself. A daemon that outlived its run would then hold this
# fixture's lock for as long as it lived, and every later
# `materialize-recording.sh <fixture>` — from `cargo test`, from a
# Playwright worker, from `just demo-cross-tracer` — would block for the
# full 1800 s and then fail blaming "another process", with no way to see
# that the culprit was an orphan. Closing it here keeps the lock's lifetime
# tied to this script, which is the only process that should ever hold it.
set +e
CT_RECORDING_OUT_DIR="$STAGING" "$REGENERATE" >&2 9>&-
regenerate_status=$?
set -e

case "$regenerate_status" in
0) ;;
75)
	die "regenerating '$FIXTURE' reported missing prerequisites (exit 75); see the list above"
	;;
*)
	die "regenerating '$FIXTURE' failed (exit $regenerate_status)"
	;;
esac

# `.complete` is written last and is what every reader gates on, so an
# interrupted run leaves a directory that is ignored rather than a
# partial recording that looks whole.
{
	printf 'key\t%s\n' "$KEY"
	printf 'recorded_at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf '%s\n' "$KEY_INPUTS"
} >"$STAGING/.complete"

rm -rf "$OUT_DIR"
mv "$STAGING" "$OUT_DIR"
trap - EXIT

# `regenerate.sh` reported the staging path it was handed; say where the
# recordings actually ended up, so a reader can go and look at them.
echo "[materialize] '$FIXTURE' recorded to $OUT_DIR" >&2

printf '%s\n' "$OUT_DIR"
