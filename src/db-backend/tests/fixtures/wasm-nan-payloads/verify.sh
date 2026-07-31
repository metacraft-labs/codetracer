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
command -v zstd >/dev/null 2>&1 || missing+=("- zstd not on PATH (expands the pinned module)")

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

[ -d "$FIXTURE_DIR/nan-payloads.ct" ] ||
	missing+=("- nan-payloads.ct is absent (run ./regenerate.sh)")
[ -f "$FIXTURE_DIR/module/nan_payloads.wasm.zst" ] ||
	missing+=("- module/nan_payloads.wasm.zst is absent (run ./regenerate.sh)")

if [ ${#missing[@]} -gt 0 ]; then
	echo "[verify] missing prerequisites:"
	printf '    %s\n' "${missing[@]}"
	exit 75
fi

# ---------------------------------------------------------------------------
# 1/2 — the recording carries the exact bit patterns.
# ---------------------------------------------------------------------------
echo "[verify] 1/2 checking the recorded bit patterns"
# Every f32/f64 boundary value the fixture produces, each crossing twice
# (once as an `observe_*` import argument, once as the export's result).
expected_bits=(
	"f32:0x7f800001"         # f32 signalling NaN
	"f32:0x80000000"         # f32 negative zero
	"f64:0x7ff80000deadbeef" # f64 payload-carrying quiet NaN
	"f64:0x8000000000000000" # f64 negative zero, computed by -0.0 * 1.0
)
failed=0
for want in "${expected_bits[@]}"; do
	# Two occurrences each: the import argument and the export result.
	count="$(grep -o -- "$want" "$FIXTURE_DIR/nan-payloads.ct/trace.json" | wc -l)"
	if [ "$count" -lt 2 ]; then
		echo "[verify] MISSING: $want appears $count time(s), expected 2" >&2
		failed=1
	else
		echo "[verify]     ok: $want x$count"
	fi
done
# A NaN that reached JSON as `null` is the pre-M52 loss; it must not be
# in a recording made by the current producer.
if grep -q '"f":"null"' "$FIXTURE_DIR/nan-payloads.ct/trace.json"; then
	echo '[verify] the recording contains a NaN lost to JSON ("f":"null")' >&2
	echo "[verify] it was made by a pre-M52 producer; re-run ./regenerate.sh" >&2
	failed=1
fi
[ "$failed" -eq 0 ] || exit 1

# ---------------------------------------------------------------------------
# 2/2 — the replay agrees with it.
# ---------------------------------------------------------------------------
echo "[verify] 2/2 replaying against the original module"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
zstd -d -q -f -o "$WORK/nan_payloads.wasm" "$FIXTURE_DIR/module/nan_payloads.wasm.zst"

if ! "$WAZERO_BIN" run \
	--boundary-log="$FIXTURE_DIR/nan-payloads.ct" \
	--out-dir="$WORK/traces" \
	"$WORK/nan_payloads.wasm" >"$WORK/stdout" 2>"$WORK/stderr"; then
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
