#!/usr/bin/env bash
#
# frame-renderer-suite.sh — IsoNim's frame renderer suite on the three
# backends CodeTracer builds a ViewModel core for: C, `nim js` and wasm32.
#
# The renderer is the boundary a WebAssembly core draws through, and its
# same-value elision keeps a shadow whose invalidation is easy to get wrong
# in only one backend (the `nim js` arm writes the frame from inline
# JavaScript; the others from a `seq[byte]`). So the one suite
# (`../isonim/tests/test_frame_renderer.nim`) runs on all three, and the
# script requires every backend to pass and to run the same number of cases.
#
# Exit 0 when all three pass with equal counts, 1 on a failure, 2 when a tool
# is missing — a failure, never a skip.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=ci/lib/nim-cache-root.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "${repo_root}/ci/lib/nim-cache-root.sh"
cd "${repo_root}" || exit 2

for tool in nim emcc node; do
	if ! command -v "${tool}" >/dev/null 2>&1; then
		echo "ERROR: ${tool} is not on PATH; run inside this repo's dev shell." >&2
		exit 2
	fi
done

isonim_src="${ISONIM_SRC:-${repo_root}/../isonim/src}"
suite="${isonim_src}/../tests/test_frame_renderer.nim"
if [ ! -f "${suite}" ]; then
	echo "ERROR: ${suite} is missing; IsoNim is too old or not beside this checkout." >&2
	exit 2
fi
out="${CT_FRAME_RENDERER_OUT:-${repo_root}/test-logs/frame-renderer-suite}"
cache_root="$(ct_nim_cache_root "${repo_root}")/frame-renderer-suite"
rm -rf "${out}"
mkdir -p "${out}"
common=(--hints:off --warnings:off --path:"${isonim_src}" -d:nimUnittestColor:off)

failures=0
declare -A counts
run_backend() {
	local name="$1"
	shift
	local log="${out}/${name}.log"
	"$@" >"${log}" 2>&1
	local rc=$?
	local ok failed
	ok="$(grep -c '^\s*\[OK\]' "${log}" || true)"
	failed="$(grep -c '^\s*\[FAILED\]' "${log}" || true)"
	counts["${name}"]="${ok}"
	if [ "${rc}" -ne 0 ] || [ "${failed}" -ne 0 ] || [ "${ok}" -eq 0 ]; then
		# The failed cases by name first, so the first FAIL line says which.
		grep -E '^\s*\[FAILED\]' "${log}" | sed 's/^\s*\[FAILED\]\s*/  FAIL: '"${name}"': /' | head -20
		echo "  FAIL: ${name}: ${failed} failed, ${ok} passed (exit ${rc})"
		failures=$((failures + 1))
	else
		echo "  ok: ${name}: ${ok} passed"
	fi
}

echo "--- C ---"
if nim c "${common[@]}" --nimcache:"${cache_root}/c" -o:"${out}/suite_c" "${suite}" >"${out}/build-c.log" 2>&1; then
	run_backend c "${out}/suite_c"
else
	echo "  FAIL: c: the suite did not build"; tail -20 "${out}/build-c.log"; failures=$((failures + 1))
fi

echo "--- nim js ---"
if nim js "${common[@]}" -d:nodejs --nimcache:"${cache_root}/js" -o:"${out}/suite_js.js" "${suite}" >"${out}/build-js.log" 2>&1; then
	run_backend js node "${out}/suite_js.js"
else
	echo "  FAIL: js: the suite did not build"; tail -20 "${out}/build-js.log"; failures=$((failures + 1))
fi

echo "--- wasm32 ---"
if nim c "${common[@]}" --cpu:wasm32 --os:linux -d:emscripten \
	--cc:clang --clang.exe:emcc --clang.linkerexe:emcc \
	--mm:orc --threads:off \
	--passL:-sSTACK_SIZE=8388608 --passL:-sALLOW_MEMORY_GROWTH=1 \
	--passL:-sEXIT_RUNTIME=1 --passL:-sENVIRONMENT=node \
	--nimcache:"${cache_root}/wasm" -o:"${out}/suite_wasm.js" "${suite}" >"${out}/build-wasm.log" 2>&1; then
	run_backend wasm node "${out}/suite_wasm.js"
else
	echo "  FAIL: wasm: the suite did not build"; tail -20 "${out}/build-wasm.log"; failures=$((failures + 1))
fi

if [ "${failures}" -eq 0 ]; then
	if [ "${counts[c]}" != "${counts[js]}" ] || [ "${counts[c]}" != "${counts[wasm]}" ]; then
		echo "  FAIL: the backends ran different case counts: c=${counts[c]} js=${counts[js]} wasm=${counts[wasm]}"
		failures=1
	fi
fi
if [ "${failures}" -ne 0 ]; then
	echo "frame-renderer-suite: FAILED"
	exit 1
fi
echo "frame-renderer-suite: ok (${counts[c]} cases on each of c, js, wasm32)"
