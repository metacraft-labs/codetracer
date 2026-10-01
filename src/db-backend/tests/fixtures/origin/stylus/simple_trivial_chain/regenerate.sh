#!/usr/bin/env bash
#
# Re-capture `evm_trace.json`, the host-interaction record the
# stylus/simple_trivial_chain origin test replays.
#
# The capture is what the Stylus recording pipeline (`ct arb record`,
# src/ct/stylus/record.nim) takes from the chain: the contract is deployed
# to an Arbitrum Nitro dev node, `compute()` is called in a transaction, and
# `cargo stylus trace` asks the node for that transaction's
# `debug_traceTransaction` with the `stylusTracer`, which lists every hostio
# the contract made with its arguments and results. The test then rebuilds
# the contract's debug wasm and replays it under `wazero run -stylus`, which
# answers each hostio from this file.
#
# Re-run it when `src/lib.rs`, `Cargo.toml` or the stylus-sdk version
# changes: the replay fails loudly if the contract's hostio sequence no
# longer matches the capture.
#
# Prerequisites (all in `nix develop .#ci` except the node):
#   - a Nitro dev node at $STYLUS_RPC (default http://localhost:8547), e.g.
#       git clone https://github.com/OffchainLabs/nitro-devnode.git
#       cd nitro-devnode && ./run-dev-node.sh      # needs docker and cast
#   - cargo-stylus, cast (Foundry), jq
#   - a Rust toolchain with the wasm32-unknown-unknown target
#
# Usage:
#     ./regenerate.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RPC="${STYLUS_RPC:-http://localhost:8547}"
# The pre-funded account of the Nitro dev node.
PRIVATE_KEY="${STYLUS_PRIVATE_KEY:-0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659}"

for tool in cargo cargo-stylus cast jq rustc; do
	command -v "$tool" >/dev/null || {
		echo "regenerate.sh: '$tool' is not on PATH" >&2
		exit 1
	}
done
if ! cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
	echo "regenerate.sh: no Nitro dev node answers at $RPC (see the prerequisites above)" >&2
	exit 1
fi

strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# Deploy from a scratch copy: cargo-stylus insists on a rust-toolchain.toml
# naming an exact version, and its build output must not land in the tree.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -r "$HERE/." "$WORK/"
rm -f "$WORK/evm_trace.json"
RUSTC_VERSION="$(rustc --version | awk '{print $2}')"
printf '[toolchain]\nchannel = "%s"\ntargets = ["wasm32-unknown-unknown"]\n' "$RUSTC_VERSION" >"$WORK/rust-toolchain.toml"

cd "$WORK"
DEPLOY_OUT="$(cargo stylus deploy --endpoint="$RPC" --private-key="$PRIVATE_KEY" --no-verify 2>&1 | strip_ansi)"
ADDRESS="$(printf '%s\n' "$DEPLOY_OUT" | sed -n 's/.*deployed code at address: *\(0x[0-9a-fA-F]\{40\}\).*/\1/p' | head -n1)"
if [ -z "$ADDRESS" ]; then
	printf '%s\n' "$DEPLOY_OUT" >&2
	echo "regenerate.sh: cargo stylus deploy reported no contract address" >&2
	exit 1
fi
echo "contract deployed at $ADDRESS"

TX="$(cast send --json --rpc-url "$RPC" --private-key "$PRIVATE_KEY" "$ADDRESS" "compute()" | jq -r '.transactionHash')"
echo "compute() transaction $TX"

cargo stylus trace --endpoint="$RPC" --use-native-tracer --tx "$TX" >"$WORK/raw_trace.json"

# One hostio per line, so a re-capture diffs readably.
{
	echo "["
	jq -c -S '.[]' "$WORK/raw_trace.json" | sed '$!s/$/,/; s/^/  /'
	echo "]"
} >"$HERE/evm_trace.json"
echo "wrote $HERE/evm_trace.json ($(jq length "$HERE/evm_trace.json") hostio events)"
