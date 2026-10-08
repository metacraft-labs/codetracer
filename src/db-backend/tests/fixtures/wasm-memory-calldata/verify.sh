#!/usr/bin/env bash
# Host-supplied-state demo — replay checks.
#
# Runs entirely against the **committed** recording; it neither records
# nor rebuilds anything, so it is safe to run at any time and is what the
# milestone's verification entries are backed by.
#
# Four checks, and the last two are the ones that matter:
#
#   1. the recording carries its host state in the consumer's schema —
#      §3.3 initial state and one §3.4 mutation per call — as the
#      `wasm-host-state` records `ct-print` shows in its event stream;
#   2. replaying the ORIGINAL module against the recording succeeds and
#      materialises a trace with real steps;
#   3/4. **withholding §3.3** (emptying the memory's `data`) and
#      **withholding §3.4** (dropping the mutations) each make the replay
#      fail with a divergence — proving the module genuinely depends on the
#      host-supplied bytes, and that a fixture built on a stateless module
#      could not distinguish a working implementation from none. Editing a
#      recording means editing its boundary log, and only
#      `codetracer-wasm-recorder` reads those, so these two run there
#      (`TestTheMemoryCalldataRecordingDependsOnItsHostState`, under its
#      `crossrepo` tag) against the recording made here.
#
# Exit codes:
#   0   every check passed
#   75  (EX_TEMPFAIL) wazero or ct-print is not built; nothing was checked
#   1   a check failed
set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CODETRACER_ROOT="$(cd "$FIXTURE_DIR/../../../../.." && pwd -P)"
WORKSPACE_ROOT="$(cd "$CODETRACER_ROOT/.." && pwd -P)"
WASM_RECORDER="${CODETRACER_WASM_RECORDER_PATH:-$WORKSPACE_ROOT/codetracer-wasm-recorder}"

missing=()
# shellcheck source=ci/lib/recording-dump.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "$CODETRACER_ROOT/ci/lib/recording-dump.sh"
resolve_ct_print
if [ ${#missing[@]} -gt 0 ]; then
	printf '[verify] %s\n' "${missing[@]}" >&2
	exit 75
fi

WAZERO_BIN="${CODETRACER_WAZERO_BIN:-}"
if [ -z "$WAZERO_BIN" ]; then
	for candidate in \
		"$WORKSPACE_ROOT/codetracer-wasm-recorder/wazero" \
		"$WORKSPACE_ROOT/codetracer-wasm-recorder/wazero-snapshots"; do
		[ -x "$candidate" ] && WAZERO_BIN="$candidate" && break
	done
fi
if [ -z "$WAZERO_BIN" ]; then
	echo "[verify] wazero is not built (just build in codetracer-wasm-recorder)" >&2
	exit 75
fi
# `node` and `strings` are as much a prerequisite as wazero. Without this
# a missing `node` surfaced as "the host-state records are malformed", which names the
# wrong thing entirely.
for tool in node strings; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "[verify] $tool is not on PATH; run this inside the dev shell" >&2
		exit 75
	}
done
# The recording and the module it describes are produced together from
# this tree, not committed. The recorded host state holds the absolute
# address `rust-lld` gave `LEDGER`, so the two are one artefact; the
# materialiser keeps them one artefact by making them in the same run,
# and re-makes them whenever the instrumenter or the browser recorder
# changes. Replaying a stored recording against a stored module would
# have gone on succeeding after either of those moved.
MATERIALIZED="$("$CODETRACER_ROOT/scripts/materialize-recording.sh" wasm-memory-calldata)"
RECORDING="$MATERIALIZED/ledger-settle.ct"
MODULE="$MATERIALIZED/module/ledger_settle.wasm"

for required in "$RECORDING" "$MODULE"; do
	if [ ! -e "$required" ]; then
		echo "[verify] the recording pipeline produced no $required" >&2
		exit 1
	fi
done

echo "[verify] wazero:    $WAZERO_BIN"
echo "[verify] recording: $RECORDING"
echo

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
	echo "[verify] FAILED: $1" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# 1 — the host state is in the consumer's schema
# ---------------------------------------------------------------------------
echo "[verify] 1/4 host-state records"
DUMP="$WORK/recording.json"
recording_full_json "$RECORDING" >"$DUMP" || fail "ct-print cannot read the recording"
node - "$DUMP" <<'NODE' || fail "the host-state records are malformed"
const fs = require("node:fs");
const dump = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const docs = dump.events
  .filter((e) => e.kind === "io" && typeof e.metadata === "string" && e.metadata.includes("wasm-host-state"))
  .map((e) => JSON.parse(e.metadata))
  .filter((d) => d.boundary_id === "wasm-host-state");
const problems = [];
for (const d of docs) if (d.version !== 1) problems.push(`version is ${d.version}, expected 1`);
const initials = docs.filter((d) => d.record === "initial");
if (initials.length !== 1) problems.push(`expected 1 initial-state record, got ${initials.length}`);
const mems = initials[0]?.initial?.memories ?? [];
if (mems.length !== 1) problems.push(`expected 1 imported memory, got ${mems.length}`);
const mem = mems[0] ?? {};
if (mem.module !== "env" || mem.name !== "memory") {
  problems.push(`memory is ${mem.module}.${mem.name}, expected env.memory`);
}
if (!(mem.minPages >= 2)) problems.push(`minPages is ${mem.minPages}`);
if (!(mem.data?.length >= 1)) problems.push("the memory carries no §3.3 regions");
// Every recorded region must decode, and the whole record must stay small:
// this is a diff of what the host supplied, not a memory image.
let bytes = 0;
for (const region of mem.data ?? []) {
  bytes += Buffer.from(region.bytesB64, "base64").length;
}
if (bytes > 4096) problems.push(`§3.3 payload is ${bytes} bytes; expected a diff, not an image`);
const muts = docs.filter((d) => d.record === "mutation").map((d) => d.mutation);
if (muts.length !== 3) problems.push(`expected 3 §3.4 mutations, got ${muts.length}`);
const anchors = muts.map((m) => m.afterCrossing);
// crossings: 0=settle, 1=fetch_fee_bps, 2=settle, 3=fetch_fee_bps, ...
if (JSON.stringify(anchors) !== JSON.stringify([1, 3, 5])) {
  problems.push(`mutations are anchored to ${JSON.stringify(anchors)}, expected [1,3,5]`);
}
for (const m of muts) {
  if ((m.memoryWrites ?? []).length !== 1) {
    problems.push(`mutation at ${m.afterCrossing} has ${m.memoryWrites?.length} writes`);
  }
}
if (problems.length > 0) {
  console.error(problems.map((p) => `  - ${p}`).join("\n"));
  process.exit(1);
}
console.log(
  `[verify]     ok: §3.3 ${mem.data.length} region(s) / ${bytes} byte(s), ` +
    `§3.4 ${muts.length} mutation(s) at ${JSON.stringify(anchors)}`,
);
NODE

# ---------------------------------------------------------------------------
# 2 — the recording replays
# ---------------------------------------------------------------------------
echo "[verify] 2/4 replaying the original module against the recording"
if ! "$WAZERO_BIN" run --boundary-log "$RECORDING" --out-dir "$WORK/replay" \
	"$MODULE" >"$WORK/replay.log" 2>&1; then
	cat "$WORK/replay.log" >&2
	fail "the replay of a complete recording must succeed"
fi
cat "$WORK/replay.log"
if ! grep -q "replayed 3 exported call(s) and 3 imported call(s)" "$WORK/replay.log"; then
	fail "the replay did not drive all three calls and their host lookups"
fi

# What the materialised trace must actually contain.
#
# The trace is a CTFS container, and this script has no CTFS reader — but
# it does not need one to answer the question that matters, which is
# whether the trace has *content* rather than only scaffolding. Its string
# pool carries the source path, the frames the browser never saw
# (`fee_for` is a private helper: no boundary crossing mentions it), the
# local variable names DWARF recovered, and the values. A replay that
# produced no stepping would carry none of them.
#
# That check is not decoration. The M38 review found a snapshot test that
# passed against an *empty* trace, because its fixture module carried no
# DWARF; "the replay materialised a trace" is worth nothing on its own.
# A container was produced at all. Stated separately from the string
# needles because it is the precondition they silently depend on: `strings`
# over a glob that matches nothing exits 0 with empty output, so a missing
# container would make every `grep -qF` below fail with a message blaming
# the trace's contents rather than its absence.
#
# Note the shape: the replay writes ONE CTFS container, `<program>.ct`, not
# a directory of `steps.dat` / `types.dat` files. An earlier revision of
# this script asserted on `find -name steps.dat`, which never matches and
# so never fired — the exact "a check that cannot fail" trap the M38 review
# found and that the comment below is about.
echo "[verify]     trace content:"
CONTAINER="$(find "$WORK/replay" -name '*.ct' -size +4k | head -n 1)"
[ -n "$CONTAINER" ] ||
	fail "the replay produced no CTFS container in $WORK/replay"
echo "[verify]       container: $(basename "$CONTAINER") ($(wc -c <"$CONTAINER") bytes)"
STRINGS="$WORK/replay-strings.txt"
strings -n 4 "$WORK/replay"/*.ct >"$STRINGS"
for needle in \
	"wasm-memory-calldata/wasm-src/lib.rs" \
	"settle" \
	"fee_for" \
	"account_id" \
	"principal" \
	"fee_bps"; do
	grep -qF -- "$needle" "$STRINGS" ||
		fail "the materialised trace does not mention '$needle'; the replay produced no stepping"
	echo "[verify]       found $needle"
done

# The values, too. This is where the replayer does the work rather than
# this script: spec §3.1/§6 make it compare every exported return value
# against the recording and abort with a `DivergenceError` on a mismatch.
# So "the replay above succeeded" already means "the re-executed module
# produced exactly the values the browser observed" — provided the
# recording really carries the browser's numbers, which is what is checked
# here. (The container's value streams are compressed, so grepping it for
# a decimal would be matching noise.)
node - "$DUMP" "$FIXTURE_DIR/expected-totals.json" <<'NODE' || fail "the recording does not carry the browser's return values"
const fs = require("node:fs");
const dump = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const expected = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));

const recorded = [];
for (const e of dump.events) {
  for (const v of e.vars ?? []) {
    if (v.varname === "settle:ret0") {
      const val = v.value;
      recorded.push(Number(val.i ?? val.r ?? val.f));
    }
  }
}
if (JSON.stringify(recorded) !== JSON.stringify(expected)) {
  console.error(
    `  - the recording's settle:ret0 values are ${JSON.stringify(recorded)}, ` +
      `but the page observed ${JSON.stringify(expected)}`,
  );
  process.exit(1);
}
console.log(
  `[verify]     ok: the recording carries the page's totals ${expected.join(", ")}, ` +
    "and the replay reproduced every one of them (spec §6 aborts on a mismatch)",
);
NODE

# ---------------------------------------------------------------------------
# 3 / 4 — withholding either record must DIVERGE, not produce a plausible
#         trace. Done by `codetracer-wasm-recorder`, which owns the only
#         boundary-log decoder, against the recording made above; see the
#         header.
# ---------------------------------------------------------------------------
echo "[verify] 3/4 + 4/4 withholding the §3.3 initial state and the §3.4 host mutations"
if command -v repro >/dev/null 2>&1; then
	run_in_recorder_env() { repro exec "$WASM_RECORDER" -- "$@"; }
else
	run_in_recorder_env() { (cd "$WASM_RECORDER" && nix develop --command "$@"); }
fi
# shellcheck disable=SC2016 # "$1" is expanded by the inner shell
if ! run_in_recorder_env env \
	CT_PRODUCED_RECORDING_WASM_MEMORY_CALLDATA="$MATERIALIZED" \
	bash -c 'cd "$1" && go test -count=1 -tags crossrepo ./internal/boundarylog/ \
		-run TestTheMemoryCalldataRecordingDependsOnItsHostState -v' _ "$WASM_RECORDER" \
	>"$WORK/withhold.log" 2>&1; then
	cat "$WORK/withhold.log" >&2
	fail "withholding the host state did not make the replay diverge"
fi
grep -E -- '--- (PASS|FAIL)' "$WORK/withhold.log" | sed 's/^/[verify]     /'

echo
echo "[verify] all checks passed."
