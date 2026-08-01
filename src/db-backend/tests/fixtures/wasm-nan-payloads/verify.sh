#!/usr/bin/env bash
# NaN-payload demo (M52) — check the committed recording.
#
# Replays `nan-payloads.ct` against the ORIGINAL, uninstrumented module
# with `wazero run --boundary-log` and asserts two things:
#
#   1. the recording carries every boundary float as its exact IEEE-754
#      bit pattern — compared as TEXT, because a decoded float cannot
#      express the difference (two NaNs with different payloads are both
#      `NaN`, and `-0.0 == +0.0`); and
#   2. the replay does not diverge.
#
# Exit codes:
#   0   the recording replays and carries the expected bits
#   75  (EX_TEMPFAIL) a prerequisite is missing; nothing was checked
#   1   a check failed
set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CODETRACER_ROOT="$(cd "$FIXTURE_DIR/../../../../.." && pwd -P)"
WORKSPACE_ROOT="$(cd "$CODETRACER_ROOT/.." && pwd -P)"
cd "$FIXTURE_DIR"

WASM_RECORDER="${CODETRACER_WASM_RECORDER_PATH:-$WORKSPACE_ROOT/codetracer-wasm-recorder}"

missing=()

WAZERO_BIN="${CODETRACER_WAZERO_BIN:-}"
if [ -z "$WAZERO_BIN" ] && [ -x "$WASM_RECORDER/wazero" ]; then
	WAZERO_BIN="$WASM_RECORDER/wazero"
fi
if [ -z "$WAZERO_BIN" ] && command -v wazero >/dev/null 2>&1; then
	WAZERO_BIN="$(command -v wazero)"
fi
if [ -z "$WAZERO_BIN" ]; then
	missing+=("- the wazero recorder is not built (just build in $WASM_RECORDER)")
fi

if [ ${#missing[@]} -gt 0 ]; then
	echo "[verify] missing prerequisites:"
	printf '    %s\n' "${missing[@]}"
	exit 75
fi

# The recording and the ORIGINAL module it is replayed against are made
# together, from this tree. That matters more here than anywhere else in
# the campaign: what §1 below checks is what the *browser producer* wrote,
# so replaying a stored recording would only ever confirm that the
# producer of the day agreed with itself.
MATERIALIZED="$("$CODETRACER_ROOT/scripts/materialize-recording.sh" wasm-nan-payloads)"
RECORDING="$MATERIALIZED/nan-payloads.ct"
MODULE="$MATERIALIZED/module/nan_payloads.wasm"
for required in "$RECORDING/trace.json" "$MODULE"; do
	[ -e "$required" ] || {
		echo "[verify] the recording pipeline produced no $required" >&2
		exit 1
	}
done

# ---------------------------------------------------------------------------
# 1/2 — the recording carries the exact bit patterns.
# ---------------------------------------------------------------------------
echo "[verify] 1/2 checking the recorded bit patterns"
# The four patterns are read from the committed `expected-bits.json`
# rather than repeated here, and that file is a **hand-reviewed oracle**:
#
#   f32:0x7f800001          f32 signalling NaN
#   f32:0x80000000          f32 negative zero
#   f64:0x7ff80000deadbeef  f64 payload-carrying quiet NaN
#   f64:0x8000000000000000  f64 negative zero, computed by -0.0 * 1.0
#
# The driver used to overwrite it from each run, which would have made
# the whole check circular — the page reports what it asked for, the file
# adopts it, the recording is compared to it, and a producer that had
# regressed would simply move all three together. It now writes
# `observed-bits.json` beside the recording instead, and the check below
# compares that against the committed statement before comparing the
# recording against it.
mapfile -t expected_bits < <(
	node -e '
const fs = require("node:fs");
for (const bits of JSON.parse(fs.readFileSync(process.argv[1], "utf8"))) console.log(bits);
' "$FIXTURE_DIR/expected-bits.json"
)
[ "${#expected_bits[@]}" -eq 4 ] || {
	echo "[verify] expected-bits.json does not list four patterns" >&2
	exit 1
}
failed=0

# What the page ASKED for, against what a reviewer said it should ask
# for. Separate from the assertions below, and prior to them: this
# catches a changed page, where those catch a changed producer.
#
# The `${...}` below are JavaScript template substitutions, not shell
# ones, so the single quotes are exactly right.
# shellcheck disable=SC2016
if ! node -e '
const fs = require("node:fs");
const want = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const got = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (JSON.stringify(want) !== JSON.stringify(got)) {
  console.error(`[verify] the page asked for ${JSON.stringify(got)},`);
  console.error(`[verify] but expected-bits.json says ${JSON.stringify(want)}`);
  process.exit(1);
}
' "$FIXTURE_DIR/expected-bits.json" "$MATERIALIZED/observed-bits.json"; then
	echo "[verify] page/app.js no longer exercises the values this fixture exists for" >&2
	exit 1
fi
echo "[verify]     ok: the page asked for the four reviewed bit patterns"
for want in "${expected_bits[@]}"; do
	# Two occurrences each: the import argument and the export result.
	count="$(grep -o -- "$want" "$RECORDING/trace.json" | wc -l)"
	if [ "$count" -lt 2 ]; then
		echo "[verify] MISSING: $want appears $count time(s), expected 2" >&2
		failed=1
	else
		echo "[verify]     ok: $want x$count"
	fi
done
# A NaN that reached JSON as `null` is the pre-M52 loss; it must not be
# in a recording made by the current producer.
if grep -q '"f":"null"' "$RECORDING/trace.json"; then
	echo '[verify] the recording contains a NaN lost to JSON ("f":"null")' >&2
	echo "[verify] the producer in this tree is pre-M52, or has regressed to it" >&2
	failed=1
fi
[ "$failed" -eq 0 ] || exit 1

# ---------------------------------------------------------------------------
# 2/2 — the replay agrees with it.
# ---------------------------------------------------------------------------
echo "[verify] 2/2 replaying against the original module"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if ! "$WAZERO_BIN" run \
	--boundary-log="$RECORDING" \
	--out-dir="$WORK/traces" \
	"$MODULE" >"$WORK/stdout" 2>"$WORK/stderr"; then
	echo "[verify] the replay diverged:" >&2
	cat "$WORK/stderr" >&2
	exit 1
fi
grep -q "replayed 5 exported call(s)" "$WORK/stdout" || {
	echo "[verify] the replay did not report the five exported calls:" >&2
	cat "$WORK/stdout" >&2
	exit 1
}

echo
echo "[verify] OK — every boundary float survived the browser path bit-exact"
