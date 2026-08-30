#!/usr/bin/env bash
#
# noir-wasm-worker-e2e.sh — NS3's loop across the worker boundary, compared by
# digest against the same loop run directly.
#
# WHAT THIS ASSERTS, AND WHY IT IS TWO ASSERTIONS AND NOT ONE.
#
# A Noir package that exists only as an in-memory `path -> source` map is
# compiled by `noir_wasm.wasm` and traced by `noir_tracer_wasm.wasm`, twice:
# once in-process, once through `worker_threads` and the JSON protocol
# `platform/wasm_worker.nim` speaks. The two traces must hash the same.
#
# The digest alone is NOT enough, and that is measured rather than argued.
# Running the same comparison with the compiler's `program` mode instead of
# `debug` produces a trace of ONE event and ZERO steps -- and the digests
# still match, because both paths agree on nothing. So there is a second
# assertion that the trace is non-trivial, and the two catch different
# failures:
#
#   mutation                          digest check   non-trivial check
#   compile without instrumentation   PASSES         fails
#   worker drops one trace event      fails          PASSES
#
# That is the shape this campaign keeps meeting: two wasm modules reporting
# `ok` over an empty trace, a DAP server reporting `success` over a session
# with no trace open. A chain of agreements is not a result either.
#
# THE MODULES ARE NOT IN THE REPO. They are ~16 MB and ~4.6 MB, built from
# published refs in the `noir` fork (`compiler/wasm` and `tooling/tracer_wasm`,
# both on `codetracer`). Point the two variables below at them. Without them
# this SKIPS LOUDLY -- it does not pass.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)"
cd "${repo_root}" || exit 2

echo "=== noir wasm worker e2e (NS3) ==="
echo

missing=0
for var in CT_NOIR_WASM_COMPILER CT_NOIR_WASM_TRACER; do
	path="${!var:-}"
	if [ -z "${path}" ]; then
		echo "  SKIP: ${var} is not set"
		missing=1
	elif [ ! -f "${path}" ]; then
		echo "  SKIP: ${var} points at ${path}, which does not exist"
		missing=1
	fi
done

if [ "${missing}" -ne 0 ]; then
	cat <<'MSG'

  SKIPPED — and this is a skip, not a pass.

  Build the two modules from the `noir` fork's `codetracer` branch:

    cd <noir>/compiler/wasm      && cargo build --release --target wasm32-unknown-unknown
    cd <noir>/tooling/tracer_wasm && cargo build --release --no-default-features \
                                       --target wasm32-unknown-unknown

  then set CT_NOIR_WASM_COMPILER and CT_NOIR_WASM_TRACER to the resulting
  .wasm files and run this again.
MSG
	exit 0
fi

command -v node >/dev/null 2>&1 || {
	echo "node is not on PATH" >&2
	echo "  remedy: run inside the dev shell (direnv exec ${repo_root} ...)" >&2
	exit 2
}

node ci/test/noir-wasm-worker/compare.mjs
