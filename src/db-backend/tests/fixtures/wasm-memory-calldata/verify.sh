#!/usr/bin/env bash
# Host-supplied-state demo — replay checks.
#
# Runs entirely against the **committed** recording; it neither records
# nor rebuilds anything, so it is safe to run at any time and is what the
# milestone's verification entries are backed by.
#
# Four checks, and the last two are the ones that matter:
#
#   1. the recording carries a `boundary_state.json` in the consumer's
#      schema, with §3.3 initial state and one §3.4 mutation per call;
#   2. replaying the ORIGINAL module against the recording succeeds and
#      materialises a trace with real steps;
#   3. **withholding §3.3** (emptying the memory's `data`) makes the
#      replay fail with a divergence — proving the module genuinely
#      depends on the host-supplied bytes, and that a fixture built on a
#      stateless module could not distinguish a working implementation
#      from none;
#   4. **withholding §3.4** (dropping the mutations) makes the replay
#      fail with a divergence, likewise.
#
# Exit codes:
#   0   every check passed
#   75  (EX_TEMPFAIL) wazero is not built; nothing was checked
#   1   a check failed
set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CODETRACER_ROOT="$(cd "$FIXTURE_DIR/../../../../.." && pwd -P)"
WORKSPACE_ROOT="$(cd "$CODETRACER_ROOT/.." && pwd -P)"

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
# a missing `node` surfaced as "the sidecar is malformed", which names the
# wrong thing entirely.
for tool in node strings; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "[verify] $tool is not on PATH; run this inside the dev shell" >&2
		exit 75
	}
done
# The recording and the module it describes are produced together from
# this tree, not committed. `boundary_state.json` records the absolute
# address `rust-lld` gave `LEDGER`, so the two are one artefact; the
# materialiser keeps them one artefact by making them in the same run,
# and re-makes them whenever the instrumenter or the browser recorder
# changes. Replaying a stored recording against a stored module would
# have gone on succeeding after either of those moved.
MATERIALIZED="$("$CODETRACER_ROOT/scripts/materialize-recording.sh" wasm-memory-calldata)"
RECORDING="$MATERIALIZED/ledger-settle.ct"
MODULE="$MATERIALIZED/module/ledger_settle.wasm"

for required in "$RECORDING/trace.json" "$RECORDING/boundary_state.json" "$MODULE"; do
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
# 1 — the sidecar is in the consumer's schema
# ---------------------------------------------------------------------------
echo "[verify] 1/4 boundary_state.json shape"
node - "$RECORDING/boundary_state.json" <<'NODE' || fail "the sidecar is malformed"
const fs = require("node:fs");
const doc = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const problems = [];
if (doc.version !== 1) problems.push(`version is ${doc.version}, expected 1`);
const mems = doc.initial?.memories ?? [];
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
const muts = doc.mutations ?? [];
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
node - "$RECORDING/trace.json" "$FIXTURE_DIR/expected-totals.json" <<'NODE' || fail "the recording does not carry the browser's return values"
const fs = require("node:fs");
const events = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const expected = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));

// `VariableName` records are positional: a `Value`'s `variable_id` indexes
// them in registration order.
const names = [];
const recorded = [];
for (const ev of events) {
  if (ev.VariableName !== undefined) names.push(ev.VariableName);
  if (ev.Value !== undefined && names[ev.Value.variable_id] === "settle:ret0") {
    const v = ev.Value.value;
    recorded.push(Number(v.i ?? v.r ?? v.f));
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
#         trace. The recording is copied and edited; the produced one is
#         never touched.
#
# The host state rides in TWO carriers, and withholding it means
# withholding it from both:
#
#   * `boundary_state.json`, the sidecar; and
#   * the `wasm-host-state` events in `trace.json`, added when the browser
#     recorder learned to carry host state in the event stream, which is
#     the only carrier a *streaming* consumer can read.
#
# Editing only the sidecar makes the two disagree, and the replayer
# refuses that outright (spec §8: the sidecar is a rendering of the
# stream, so a difference means the producer wrote two descriptions of one
# program) — a refusal, not a divergence, so the check below would be
# proving something else entirely.
#
# This is exactly what a committed recording hid. The recording predated
# the in-stream carrier, so it had only a sidecar to edit and the control
# went on reporting `ok` while quietly no longer exercising the divergence
# path it names. It surfaced the first time the recording was produced
# from the current tree instead of read back.
# ---------------------------------------------------------------------------
withhold() {
	local label="$1" filter="$2" dest="$WORK/$3"
	cp -R "$RECORDING" "$dest"
	node -e "
const fs = require('node:fs');
const filter = ($filter);

// The sidecar.
const sidecarPath = process.argv[1];
const sidecar = JSON.parse(fs.readFileSync(sidecarPath, 'utf8'));
filter(sidecar);
fs.writeFileSync(sidecarPath, JSON.stringify(sidecar));

// The same state as it rides in the event stream, one record per
// fragment: an \`initial\` record carrying the sidecar's \`initial\`
// object, and one \`mutation\` record per entry of its \`mutations\`
// array. The sidecar filter is applied to a reconstructed view of each
// fragment and the result read back, so a filter written against the
// sidecar cannot silently no-op here.
const streamPath = process.argv[2];
const records = JSON.parse(fs.readFileSync(streamPath, 'utf8'));
const kept = [];
let touched = 0;
for (const record of records) {
  const meta = record?.Event?.metadata;
  if (typeof meta !== 'string' || !meta.includes('wasm-host-state')) {
    kept.push(record);
    continue;
  }
  const doc = JSON.parse(meta);
  if (doc.boundary_id !== 'wasm-host-state') {
    kept.push(record);
    continue;
  }
  touched += 1;
  if (doc.record === 'initial') {
    const view = { initial: doc.initial, mutations: [] };
    filter(view);
    doc.initial = view.initial;
    record.Event.metadata = JSON.stringify(doc);
    kept.push(record);
  } else if (doc.record === 'mutation') {
    const view = { initial: { memories: [], globals: [], tables: [] }, mutations: [doc.mutation] };
    filter(view);
    // A filter that emptied the mutation list withholds the record
    // entirely — a \`mutation\` event with no mutation in it is not a
    // shape the producer can emit, and feeding the replayer one would
    // test its parser rather than its divergence check.
    if (view.mutations.length === 1) {
      doc.mutation = view.mutations[0];
      record.Event.metadata = JSON.stringify(doc);
      kept.push(record);
    }
  } else {
    kept.push(record);
  }
}
if (touched === 0) {
  // Not a soft warning: a recording with no in-stream host state at all
  // is one the current producer did not make, and the control below
  // would then be exercising a carrier the product no longer uses alone.
  console.error('[verify] the recording carries no wasm-host-state records; ' +
    'the producer stopped writing the in-stream carrier, or this reader no ' +
    'longer recognises it');
  process.exit(1);
}
fs.writeFileSync(streamPath, JSON.stringify(kept));
" "$dest/boundary_state.json" "$dest/trace.json"
	local out="$WORK/$3.log"
	if "$WAZERO_BIN" run --boundary-log "$dest" --out-dir "$WORK/$3-out" \
		"$MODULE" >"$out" 2>&1; then
		echo "----- replay output -----" >&2
		cat "$out" >&2
		fail "$label: the replay SUCCEEDED without the record. The module does not
       actually depend on it, so this fixture cannot tell a working
       implementation from none."
	fi
	if ! grep -q "diverged from the recording" "$out"; then
		echo "----- replay output -----" >&2
		cat "$out" >&2
		fail "$label: the replay failed, but not with a divergence. A divergence is
       the spec §6 hard failure that says an input is missing; any other
       error means the check is proving something else."
	fi
	echo "[verify]     ok: $(grep -m1 'diverged from the recording' "$out")"
	grep -m2 -E '^  (recorded|actual):' "$out" | sed 's/^/[verify]     /'
	# Spec §6: a diverged replay must write no trace, because one would
	# describe an execution that never happened and would be
	# indistinguishable on disk from a faithful one. Checked by walking the
	# output directory, which the successful replay above has just been
	# shown to fill — so this cannot pass by looking for the wrong thing.
	if [ -e "$WORK/$3-out" ] && [ -n "$(find "$WORK/$3-out" -type f)" ]; then
		find "$WORK/$3-out" -type f >&2
		fail "$label: a diverged replay left files behind"
	fi
	echo "[verify]     ok: no trace was written"
}

echo "[verify] 3/4 withholding the §3.3 initial state"
withhold "§3.3 withheld" \
	"(d) => { for (const m of d.initial.memories) m.data = []; }" \
	"no-initial"

echo "[verify] 4/4 withholding the §3.4 host mutations"
withhold "§3.4 withheld" \
	"(d) => { d.mutations = []; }" \
	"no-mutations"

echo
echo "[verify] all checks passed."
