#!/usr/bin/env bash
# M38c end-to-end check — snapshots and slices derived DURING a browser run.
#
# `codetracer-specs/Recording-Backends/WASM-Replay-Snapshots-And-Slices.md`
# §2 says snapshots are derived "continuously, during recording, not as a
# separate pass afterwards … When the page stops, the snapshots are
# already there." This script is the check that the claim now holds for a
# real browser session with a real recorder on the other end of the tee:
#
#   1. builds and instruments the WASM tier exactly as `regenerate.sh` does;
#   2. starts `record-web` with `--snapshot-consumer`, so every recording's
#      `trace.json` bytes are teed into a spawned
#      `wazero-snapshots run --boundary-stream - --slice-dir …`;
#   3. drives a page once in headless Chromium;
#   4. reports, with sub-millisecond timestamps, when each slice container
#      was sealed relative to the moment the recording stopped being
#      produced.
#
# Not every slice is guaranteed to be early, and the check does not ask for
# it: a slice is sealed when the *next* quiescent point opens, so a slice
# whose successor point the consumer has not replayed yet is sealed late
# simply because the consumer is behind. Observed range on this workload is
# five to eight of eight, load-dependent; since M38d gave the producers a
# time-based flush the observed figure is eight of eight, each sealed one
# call-gap (2s) after the last. The property under test is that slices are
# sealed during the run at all — that snapshots are derived from a stream
# rather than from a finished file.
#
# Nothing here writes a committed file. The page is built and served from a
# scratch copy, and the recordings land in a scratch directory — producing
# the committed `.ct`s is `regenerate.sh`'s job, and the two must stay
# separate so this check cannot perturb what the tests gate on. (The one
# thing it does write inside the fixture directory is `wasm-src/target/`,
# from the `cargo build` in step 1, exactly as `regenerate.sh` does; it is
# in `.gitignore`.)
#
# # Why the page is a variant of the fixture's
#
# One reason, and it is a property of the committed page rather than a
# convenience: **it calls into WebAssembly exactly once.** One exported
# call is one quiescent point, and a slice can only be *sealed* when the
# next one opens — so that workload has no intermediate slice to time, no
# matter how promptly the consumer works. The scratch copy calls
# `compute_balance` several times, spaced apart. That patch is applied to
# the copy and verified to have applied; the committed `app.js` is
# read-only here.
#
# **The recorders' flush policy is no longer patched** (M38d). It used to
# be: both browser producers buffered 256 events before their first flush
# with no time bound, and the demo's WASM recording is ~85 records, so a
# default-configured page shipped the *entire* recording in one batch at
# `stop()` — after which nothing downstream could seal a slice "while the
# page is still running", however incrementally the daemon wrote and
# however promptly the consumer replayed. This script therefore patched
# `flushThreshold: 1` into its scratch `bootstrap.js`, which was fine for a
# demonstration and wrong as a default (one WebSocket frame per event).
#
# Both producers now flush on a *time* bound as well as a count bound —
# `DEFAULT_FLUSH_INTERVAL_MS`, 50ms since the batch's first event — so a
# short page's records reach the daemon as it produces them without any
# configuration at all. That is what makes this check a check on the
# **shipped defaults**: `bootstrap.js` is copied unmodified, and if the
# defaults regress to count-only this script fails rather than quietly
# measuring a page it had reconfigured.
#
# # Why the comparison point is `trace.json`'s mtime
#
# The page finalises both recordings itself, by calling `stopRecording()`
# in its own `finally` block, well before Chromium is torn down. The last
# write to `trace.json` is the `]` that closes its array, so that file's
# mtime *is* the instant the recording stopped being produced. A slice
# sealed before it was sealed while the page was still recording — the
# property §2 asks for, and the one that was unreachable before
# `trace.json` was written incrementally, because the file did not exist
# until the session ended.
#
# `--stream-done-marker` is **not** the reference point, and must not be:
# the daemon closes the tee's pipe and waits for the consumer to exit
# before creating the marker, so the marker postdates the consumer's last
# slice by construction and measuring against it would make this check
# unfalsifiable. It is used only to know the recording finished at all.
#
# Exit codes:
#   0   at least one slice was sealed before the recording finished
#   75  (EX_TEMPFAIL) a prerequisite is missing; nothing ran
#   1   a stage ran and failed, or every slice landed only at the end
set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CODETRACER_ROOT="$(cd "$FIXTURE_DIR/../../../../../.." && pwd -P)"
# shellcheck source=ci/lib/newest-build.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "$CODETRACER_ROOT/ci/lib/newest-build.sh"
WORKSPACE_ROOT="$(cd "$CODETRACER_ROOT/.." && pwd -P)"

JS_RECORDER="${CODETRACER_JS_RECORDER_PATH:-$WORKSPACE_ROOT/codetracer-js-recorder}"
WASM_INSTRUMENTER="${CODETRACER_WASM_INSTRUMENTER_PATH:-$WORKSPACE_ROOT/codetracer-wasm-instrumenter}"
WASM_RECORDER="${CODETRACER_WASM_RECORDER_PATH:-$WORKSPACE_ROOT/codetracer-wasm-recorder}"
# `vite.config.js` resolves the recorder runtimes from these when set,
# which is what lets the page be built from a scratch directory instead of
# its fixed depth under the workspace root.
export CODETRACER_JS_RECORDER_PATH="$JS_RECORDER"
export CODETRACER_WASM_INSTRUMENTER_PATH="$WASM_INSTRUMENTER"

BACKEND_PORT="${DEMO_BACKEND_PORT:-8080}"
PREVIEW_PORT="${DEMO_PREVIEW_PORT:-4173}"
RECORD_WEB_PORT="${DEMO_RECORD_WEB_PORT:-9230}"
# Exported calls the scratch page makes, and the gap between them. The gap
# is what makes the producer dribble rather than arrive in one frame; a
# page that does all its work in one microtask is a legitimate workload
# but not one in which any consumer could be observed keeping up.
#
# The gap has to exceed the consumer's per-call replay cost, which for the
# instrumented debug module here is a few hundred milliseconds plus a
# roughly one-second instantiation. Measured: at 200ms the consumer never
# catches up and *no* slice is sealed during the run; at 2s it seals five
# of eight. Lower it and this check will honestly fail rather than quietly
# measure something else.
WASM_CALLS="${DEMO_WASM_CALLS:-8}"
CALL_GAP_MS="${DEMO_CALL_GAP_MS:-2000}"
# One slice per quiescent point, so every call yields a container to time.
SLICE_EVERY="${DEMO_SLICE_EVERY:-1}"

echo "[stream-demo] M38c: snapshots during a browser run"

# ---------------------------------------------------------------------------
# Prerequisites, collected in full so one run names everything missing.
# ---------------------------------------------------------------------------
missing=()
require_bin() {
	command -v "$1" >/dev/null 2>&1 || missing+=("- $1 not on PATH ($2)")
}
require_bin cargo "the Rust toolchain builds the WASM tier"
require_bin node "runs the Vite build and the page driver"
require_bin npx "ships with Node.js"

if ! grep -qx 'wasm32-unknown-unknown' <<<"$(rustc --print target-list 2>/dev/null)"; then
	missing+=("- rustc cannot target wasm32-unknown-unknown (rustup target add wasm32-unknown-unknown)")
fi

CT_INSTRUMENT_BIN="${CT_INSTRUMENT_BIN:-}"
if [ -z "$CT_INSTRUMENT_BIN" ]; then
	CT_INSTRUMENT_BIN="$(newest_executable \
		"$WASM_INSTRUMENTER/target/release/ct-instrument" \
		"$WASM_INSTRUMENTER/target/debug/ct-instrument")" \
		|| CT_INSTRUMENT_BIN=""
fi
[ -n "$CT_INSTRUMENT_BIN" ] ||
	missing+=("- ct-instrument not found (cargo build --release -p ct-instrument-cli in $WASM_INSTRUMENTER)")

RECORD_WEB_BIN="${CODETRACER_RECORD_WEB_BIN:-}"
if [ -z "$RECORD_WEB_BIN" ]; then
	RECORD_WEB_BIN="$(newest_executable \
		"$CODETRACER_ROOT/src/backend-manager/target/release/session-manager" \
		"$CODETRACER_ROOT/src/backend-manager/target/debug/session-manager" \
		"$CODETRACER_ROOT/src/build-debug/bin/session-manager")" \
		|| RECORD_WEB_BIN=""
fi
[ -n "$RECORD_WEB_BIN" ] ||
	missing+=("- session-manager not built (cargo build in $CODETRACER_ROOT/src/backend-manager)")

# The snapshot half of the recorder is behind the `ctsnapshots` build tag,
# so the plain `wazero` binary will not do: it refuses --slice-dir.
WAZERO_SNAPSHOTS_BIN="${CODETRACER_WAZERO_SNAPSHOTS_BIN:-$WASM_RECORDER/wazero-snapshots}"
[ -x "$WAZERO_SNAPSHOTS_BIN" ] ||
	missing+=("- wazero-snapshots not built (just build-snapshots in $WASM_RECORDER)")

[ -d "$FIXTURE_DIR/frontend/node_modules" ] ||
	missing+=("- the demo page's dependencies are not installed (npm install in $FIXTURE_DIR/frontend)")

if ! node -e 'require.resolve("playwright")' >/dev/null 2>&1 &&
	! (cd "$FIXTURE_DIR/frontend" && node -e 'require.resolve("playwright")') >/dev/null 2>&1; then
	missing+=("- playwright not installed (npm install in $FIXTURE_DIR/frontend)")
fi

if [ ${#missing[@]} -gt 0 ]; then
	echo "[stream-demo] missing prerequisites:"
	printf '    %s\n' "${missing[@]}"
	exit 75
fi

SCRATCH="$(mktemp -d)"
PAGE="$SCRATCH/page"
RECORD_WEB_OUT="$SCRATCH/recordings"
SLICE_ROOT="$SCRATCH/slices"
mkdir -p "$PAGE" "$RECORD_WEB_OUT" "$SLICE_ROOT"
echo "[stream-demo] scratch: $SCRATCH"

cleanup_pids=()

# Drop an already-reaped pid, so the exit trap cannot later signal a
# *recycled* process group that happens to have been given the same number.
forget_pid() {
	local target="$1" pid
	local kept=()
	for pid in "${cleanup_pids[@]:-}"; do
		[ -n "$pid" ] || continue
		[ "$pid" = "$target" ] || kept+=("$pid")
	done
	cleanup_pids=("${kept[@]:-}")
}

cleanup() {
	for pid in "${cleanup_pids[@]:-}"; do
		[ -n "$pid" ] || continue
		# Kill the process group: the JS recorder execs the server under a
		# generated runner, so signalling only the pid we spawned leaves the
		# recorded server holding its port.
		kill -- "-$pid" >/dev/null 2>&1 || kill "$pid" >/dev/null 2>&1 || true
	done
	cleanup_pids=()
}

# Everything started below is `setsid`-detached — deliberately, so the
# recorded server does not receive signals aimed at this script's process
# group — which also means nothing else in the system will ever reap it.
# This trap is the only reaper, and it is worth being explicit about when
# it runs. This daemon additionally owns a `--snapshot-consumer` child per
# recording, so an unreaped host leaks a replayer alongside it.
#
# Naming INT/TERM/HUP is deliberate but is *not* what fixes the orphaned
# daemons: bash already runs an `EXIT` trap when the shell dies on an
# untrapped SIGTERM, including while blocked in a foreground command. That
# was measured, not assumed. The explicit traps buy independence from that
# subtlety and a 128+signo exit status.
#
# The real gap is SIGKILL, where no trap can run, which is why `record-web`
# also stands itself down after an idle period (`--idle-timeout`, default
# 10 minutes).
on_signal() {
	trap - EXIT
	cleanup
	exit "$1"
}
trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP

wait_for_port() {
	local port="$1" label="$2"
	for _ in $(seq 1 100); do
		if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
			exec 3<&- 3>&-
			return 0
		fi
		sleep 0.2
	done
	echo "[stream-demo] $label never bound 127.0.0.1:$port" >&2
	return 1
}

if (exec 3<>"/dev/tcp/127.0.0.1/$BACKEND_PORT") 2>/dev/null; then
	exec 3<&- 3>&-
	echo "[stream-demo] 127.0.0.1:$BACKEND_PORT is already in use (set DEMO_BACKEND_PORT)." >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# 1/5 — build and instrument the WASM tier, into the scratch page.
# ---------------------------------------------------------------------------
echo "[stream-demo] 1/5 building wasm-src -> wasm32-unknown-unknown"
(cd "$FIXTURE_DIR/wasm-src" && cargo build --target wasm32-unknown-unknown)
ORIGINAL_WASM="$FIXTURE_DIR/wasm-src/target/wasm32-unknown-unknown/debug/balance_calc.wasm"
[ -f "$ORIGINAL_WASM" ] || {
	echo "[stream-demo] cargo did not produce $ORIGINAL_WASM" >&2
	exit 1
}
"$CT_INSTRUMENT_BIN" "$ORIGINAL_WASM" \
	--output "$PAGE/balance_calc.wasm" \
	--manifest "$PAGE/balance_calc.wasm.manifest.json" \
	--source-path "wasm-src/lib.rs"

# ---------------------------------------------------------------------------
# 2/5 — the scratch page: the fixture's, with more spaced-out WASM calls.
# ---------------------------------------------------------------------------
echo "[stream-demo] 2/5 preparing the scratch page ($WASM_CALLS calls, ${CALL_GAP_MS}ms apart)"
for f in app.js bootstrap.js index.html vite.config.js package.json drive.mjs; do
	cp "$FIXTURE_DIR/frontend/$f" "$PAGE/$f"
done
# Symlinked rather than copied: it is tens of megabytes and read-only here.
ln -s "$FIXTURE_DIR/frontend/node_modules" "$PAGE/node_modules"

ORIGINAL_CALL='  const result = wasm.compute_balance(userId, amount);'
grep -qF "$ORIGINAL_CALL" "$PAGE/app.js" || {
	echo "[stream-demo] app.js no longer contains the line this script patches:" >&2
	echo "[stream-demo]     $ORIGINAL_CALL" >&2
	echo "[stream-demo] Update the patch below to match, rather than letting the" >&2
	echo "[stream-demo] check silently measure the one-call workload again." >&2
	exit 1
}
python3 - "$PAGE/app.js" "$WASM_CALLS" "$CALL_GAP_MS" <<'PATCH'
import sys

path, calls, gap = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
original = "  const result = wasm.compute_balance(userId, amount);"
patched = "\n".join([
    "  // Patched by stream-snapshots-demo.sh: several exported calls, spaced",
    "  // apart, so the recording has intermediate quiescent points and the",
    "  // consumer can be observed sealing slices while the page still runs.",
    "  let result = 0;",
    f"  for (let call = 0; call < {calls}; call++) {{",
    "    result = wasm.compute_balance(userId + call, amount);",
    f"    await new Promise((resume) => setTimeout(resume, {gap}));",
    "  }",
])
source = open(path).read()
assert source.count(original) == 1, "expected exactly one call site to patch"
open(path, "w").write(source.replace(original, patched))
PATCH

# `bootstrap.js` is copied UNMODIFIED, and that is the point of this check
# since M38d: the recorders' shipped defaults are what has to make a short
# page stream. Guard it, so a future edit that re-introduces a flush knob
# here is noticed rather than silently making the verdict about a
# reconfigured page.
if grep -qE 'flush(Threshold|IntervalMs)' "$PAGE/bootstrap.js"; then
	echo "[stream-demo] the scratch bootstrap.js configures the flush policy:" >&2
	grep -nE 'flush(Threshold|IntervalMs)' "$PAGE/bootstrap.js" >&2
	echo "[stream-demo] This check exists to prove the DEFAULTS stream. If the page" >&2
	echo "[stream-demo] needs a flush override to pass, the defaults have regressed" >&2
	echo "[stream-demo] and that is the thing to fix." >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# 3/5 — the consumer dispatcher.
#
# `--snapshot-consumer` is spawned once per *recording*, and this page
# produces two: the JavaScript tier and the WASM tier. Only the second is
# a WASM boundary log, so the dispatcher routes on the `.ct` name and
# drains the other. The daemon deliberately knows nothing about wazero —
# it owes a consumer the byte stream on stdin and nothing else — which is
# why a shell dispatcher is the whole integration.
# ---------------------------------------------------------------------------
echo "[stream-demo] 3/5 writing the consumer dispatcher"
DISPATCH="$SCRATCH/consume.sh"
cat >"$DISPATCH" <<EOF
#!/usr/bin/env bash
set -uo pipefail
trace_dir="\$1"
if [ "\$(basename "\$trace_dir")" != "frontend-wasm.ct" ]; then
	# Not a WASM recording; drain it so the daemon never blocks on the pipe.
	exec cat >/dev/null
fi
exec "$WAZERO_SNAPSHOTS_BIN" run \\
	--boundary-log "\$trace_dir" \\
	--boundary-stream - \\
	--slice-dir "$SLICE_ROOT" \\
	--slice-every "$SLICE_EVERY" \\
	"$ORIGINAL_WASM" >"$SCRATCH/consumer.out" 2>"$SCRATCH/consumer.err"
EOF
chmod +x "$DISPATCH"

echo "[stream-demo]     building the browser bundle"
(
	cd "$PAGE"
	DEMO_BACKEND_PORT="$BACKEND_PORT" DEMO_RECORD_WEB_PORT="$RECORD_WEB_PORT" npx vite build
)

# ---------------------------------------------------------------------------
# 4/5 — start the daemon with the tee, and the recorded backend.
# ---------------------------------------------------------------------------
echo "[stream-demo] 4/5 starting record-web with --snapshot-consumer"
setsid "$RECORD_WEB_BIN" record-web \
	--bind "127.0.0.1:$RECORD_WEB_PORT" \
	--out-dir "$RECORD_WEB_OUT" \
	--workdir "$PAGE" \
	--stream-done-marker .complete \
	--snapshot-consumer "$DISPATCH" --snapshot-consumer '{trace_dir}' \
	>"$SCRATCH/record-web.log" 2>&1 &
RECORD_WEB_PID=$!
cleanup_pids+=("$RECORD_WEB_PID")
wait_for_port "$RECORD_WEB_PORT" "record-web" || exit 1

BACKEND_OUT="$SCRATCH/backend"
mkdir -p "$BACKEND_OUT"
setsid env DEMO_BACKEND_PORT="$BACKEND_PORT" node "$JS_RECORDER/packages/cli/dist/index.js" record \
	--out-dir "$BACKEND_OUT" \
	"$FIXTURE_DIR/backend/server.js" >"$SCRATCH/backend.log" 2>&1 &
BACKEND_PID=$!
cleanup_pids+=("$BACKEND_PID")
wait_for_port "$BACKEND_PORT" "the backend" || exit 1

# ---------------------------------------------------------------------------
# 5/5 — drive the page, then read the timeline off the filesystem.
# ---------------------------------------------------------------------------
echo "[stream-demo] 5/5 driving the page in headless Chromium"
(cd "$PAGE" && DEMO_PREVIEW_PORT="$PREVIEW_PORT" DEMO_BACKEND_PORT="$BACKEND_PORT" node ./drive.mjs)
wait "$BACKEND_PID" 2>/dev/null || true
forget_pid "$BACKEND_PID"
kill -INT "$RECORD_WEB_PID" >/dev/null 2>&1 || true
wait "$RECORD_WEB_PID" 2>/dev/null || true
forget_pid "$RECORD_WEB_PID"

echo
echo "[stream-demo] consumer stdout:"
sed 's/^/    /' "$SCRATCH/consumer.out" 2>/dev/null || true
if [ -s "$SCRATCH/consumer.err" ]; then
	echo "[stream-demo] consumer stderr:"
	sed 's/^/    /' "$SCRATCH/consumer.err"
fi

MARKER="$RECORD_WEB_OUT/frontend-wasm.ct/.complete"
RECORDING="$RECORD_WEB_OUT/frontend-wasm.ct/trace.json"
if [ ! -f "$MARKER" ]; then
	echo "[stream-demo] the WASM recording never finished (no $MARKER)" >&2
	sed 's/^/    /' "$SCRATCH/record-web.log" >&2
	exit 1
fi
# `%.Y` is the nanosecond-resolution mtime; plain `%Y` truncates to the
# second, which is coarser than the whole run and would report every
# delta as zero.
#
# The reference is `trace.json`'s mtime — the `]` that closed its array —
# and deliberately not the marker's; see the header. The marker's own
# offset is reported so the difference between the two is visible rather
# than something a reader has to know.
recording_at="$(stat -c %.Y "$RECORDING")"
marker_at="$(stat -c %.Y "$MARKER")"
marker_delta="$(awk -v a="$marker_at" -v b="$recording_at" 'BEGIN{printf "%+.3f", a-b}')"

mapfile -t slices < <(find "$SLICE_ROOT" -maxdepth 1 -name '*.ct' -print | sort)
if [ ${#slices[@]} -eq 0 ]; then
	echo "[stream-demo] no slice containers were produced" >&2
	sed 's/^/    /' "$SCRATCH/consumer.err" >&2 2>/dev/null || true
	exit 1
fi

echo
echo "[stream-demo] t=0 is the moment the recording stopped being produced"
echo "[stream-demo] (trace.json's array closed). For reference, the stream-done"
echo "[stream-demo] marker landed at t=${marker_delta}s — it waits for the consumer to"
echo "[stream-demo] exit, which is why it is not the reference point."
echo "[stream-demo] slice containers, by the time they were sealed:"
early=0
for slice in "${slices[@]}"; do
	sealed_at="$(stat -c %.Y "$slice")"
	delta="$(awk -v a="$sealed_at" -v b="$recording_at" 'BEGIN{printf "%+.3f", a-b}')"
	verdict='AFTER  the recording finished'
	case "$delta" in
	-*)
		verdict='BEFORE the recording finished'
		early=$((early + 1))
		;;
	esac
	printf '    %-28s t=%8ss  %s\n' "$(basename "$slice")" "$delta" "$verdict"
done

echo
if [ "$early" -eq 0 ]; then
	echo "[stream-demo] FAIL: every slice was sealed at or after the moment the" >&2
	echo "[stream-demo]       recording stopped being produced, so nothing was derived" >&2
	echo "[stream-demo]       during the browser run." >&2
	exit 1
fi
echo "[stream-demo] PASS: $early of ${#slices[@]} slice container(s) were sealed while the"
echo "[stream-demo]       browser was still recording — spec §2's timeline holds in"
echo "[stream-demo]       production, not only in the consumer's own tests."
