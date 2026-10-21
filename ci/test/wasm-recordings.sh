#!/usr/bin/env bash
# Resolve the common decoder before recording any fixture. The individual
# verifiers remain standalone entry points and honor this explicit selection.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
WORKSPACE_ROOT="$(cd .. && pwd -P)"
missing=()
# shellcheck source=ci/lib/recording-dump.sh
source ci/lib/recording-dump.sh
resolve_ct_print
if [ "${#missing[@]}" -ne 0 ]; then
	printf '[verify] %s\n' "${missing[@]}" >&2
	exit 75
fi
export CODETRACER_CT_PRINT="$CT_PRINT"
for fixture in wasm-memory-calldata wasm-nan-payloads wasm-parity-corpus; do
	echo "=== $fixture ==="
	"./src/db-backend/tests/fixtures/$fixture/verify.sh"
done
echo '=== all WebAssembly boundary-recording checks passed ==='
