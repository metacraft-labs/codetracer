#!/usr/bin/env bash
# WASM cross-modality parity corpus (M45) — check the committed recordings.
#
# Replays every corpus recording against its ORIGINAL, uninstrumented
# module with `wazero run --boundary-log` and asserts, per module:
#
#   1. the replay does not diverge, and reports the exported-call count
#      the page really made;
#   2. the materialised trace carries DWARF-driven detail the recording
#      does not — a private helper no boundary crossing mentions, which
#      only offline re-execution can recover (spec §6);
#   3. for `vault_apply`, that the recording carries its spec §3.3 / §3.4
#      state in BOTH carriers: the `boundary_state.json` sidecar and the
#      in-stream `wasm-host-state` records M44b added.
#
# The parity property itself — trace A from the recording equals trace B
# from a direct wazero run — is asserted in
# `codetracer-wasm-recorder/cmd/wazero/parity_corpus_test.go`, because it
# needs to drive wazero's Go API for the second leg. This script checks
# what can be checked from a shell: that the committed artefacts still
# replay and still carry what they are here to carry.
#
# Rebuilds nothing.
#
# Exit codes:
#   0   every recording replays and carries what it should
#   75  (EX_TEMPFAIL) a prerequisite is missing; nothing was checked
#   1   a check failed
set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CODETRACER_ROOT="$(cd "$FIXTURE_DIR/../../../../.." && pwd -P)"
WORKSPACE_ROOT="$(cd "$CODETRACER_ROOT/.." && pwd -P)"
cd "$FIXTURE_DIR"

WASM_RECORDER="${CODETRACER_WASM_RECORDER_PATH:-$WORKSPACE_ROOT/codetracer-wasm-recorder}"

missing=()
command -v zstd >/dev/null 2>&1 || missing+=("- zstd not on PATH (expands the pinned modules)")

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

# module : recording : exported calls : a private helper only re-execution recovers
CASES=(
	"loop_digest:loop-digest:6:rotate"
	"pair_stats:pair-stats:5:window_mean"
	"vault_apply:vault-apply:3:charge_for"
	"tick_ledger:tick-ledger:24:tail_checksum"
)

for entry in "${CASES[@]}"; do
	IFS=':' read -r name program _calls _helper <<<"$entry"
	[ -d "$FIXTURE_DIR/modules/$name/$program.ct" ] ||
		missing+=("- modules/$name/$program.ct is absent (run ./regenerate.sh)")
	[ -f "$FIXTURE_DIR/modules/$name/module/$name.wasm.zst" ] ||
		missing+=("- modules/$name/module/$name.wasm.zst is absent (run ./regenerate.sh)")
done

if [ ${#missing[@]} -gt 0 ]; then
	echo "[verify] missing prerequisites:"
	printf '    %s\n' "${missing[@]}"
	exit 75
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failed=0

for entry in "${CASES[@]}"; do
	IFS=':' read -r name program calls helper <<<"$entry"
	dir="$FIXTURE_DIR/modules/$name"
	echo "[verify] === $name ==="

	zstd -d -q -f -o "$WORK/$name.wasm" "$dir/module/$name.wasm.zst"

	if ! "$WAZERO_BIN" run \
		--boundary-log="$dir/$program.ct" \
		--out-dir="$WORK/$name-trace" \
		"$WORK/$name.wasm" >"$WORK/$name.out" 2>"$WORK/$name.err"; then
		echo "[verify]     FAIL: the replay diverged:" >&2
		cat "$WORK/$name.err" >&2
		failed=1
		continue
	fi
	if ! grep -q "replayed $calls exported call(s)" "$WORK/$name.out"; then
		echo "[verify]     FAIL: expected $calls exported calls; got:" >&2
		cat "$WORK/$name.out" >&2
		failed=1
		continue
	fi
	echo "[verify]     ok: replayed $calls exported call(s)"

	# The load-bearing assertion. `$helper` is a private function that no
	# boundary crossing mentions, so it can only have reached the trace by
	# the offline re-execution walking the module's interior. Asserting on
	# an export's name would prove nothing — the recording already carries
	# it.
	container="$(find "$WORK/$name-trace" -maxdepth 1 -name '*.ct' | head -n 1)"
	if [ -z "$container" ]; then
		echo "[verify]     FAIL: the replay produced no CTFS container" >&2
		failed=1
		continue
	fi
	if ! grep -qa "$helper" "$container"; then
		echo "[verify]     FAIL: the trace does not name the private helper '$helper';" >&2
		echo "[verify]           the module's DWARF is gone or stepping is off" >&2
		failed=1
		continue
	fi
	echo "[verify]     ok: the trace names the private helper '$helper'"

	if [ "$name" = "vault_apply" ]; then
		if [ ! -f "$dir/$program.ct/boundary_state.json" ]; then
			echo "[verify]     FAIL: no boundary_state.json (spec §3.3/§3.4 sidecar)" >&2
			failed=1
			continue
		fi
		echo "[verify]     ok: the spec §3.3/§3.4 sidecar is present"
		# M44b: the same state also rides in the event stream, which is
		# the only carrier a streaming consumer can use.
		if ! grep -q 'wasm-host-state' "$dir/$program.ct/trace.json"; then
			echo "[verify]     FAIL: trace.json carries no in-stream host-state record." >&2
			echo "[verify]           It was made by a pre-M44b producer; re-run ./regenerate.sh" >&2
			failed=1
			continue
		fi
		echo "[verify]     ok: the same state rides in the event stream (M44b)"
	fi
done

[ "$failed" -eq 0 ] || exit 1

echo
echo "[verify] OK — every corpus recording replays and carries DWARF-driven detail"
