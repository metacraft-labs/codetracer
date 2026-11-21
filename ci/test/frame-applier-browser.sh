#!/usr/bin/env bash
#
# frame-applier-browser.sh — IsoNim's frame renderer and frame applier, the
# boundary a WebAssembly ViewModel core draws through, in real browsers.
#
# Builds `src/frontend/viewmodel/tests/e2e/frame_applier/frame_events_core.nim`
# twice — `nim js`, and wasm32 through Emscripten for the web
# (`-sENVIRONMENT=web`, the browser front-end's setting) — and runs
# `browser.mjs` against both in Playwright's Chromium and Firefox. The test
# performs every event the shipped panes listen for and reads the document.
#
#   CT_FRAME_APPLIER_ENGINES   engines to run (default "chromium firefox")
#   CT_FRAME_APPLIER_OUT       build directory (default test-logs/frame-applier)
#
# Exit 0 when every engine passed both builds, 1 when a build or a check
# failed, 2 when a tool is missing — a failure, never a skip.

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

src_dir="src/frontend/viewmodel/tests/e2e/frame_applier"
out="${CT_FRAME_APPLIER_OUT:-${repo_root}/test-logs/frame-applier}"
isonim_src="${ISONIM_SRC:-${repo_root}/../isonim/src}"
applier="${isonim_src}/isonim/web/frame_applier.js"
if [ ! -f "${applier}" ]; then
	echo "ERROR: ${applier} is missing; IsoNim is too old or not beside this checkout." >&2
	exit 2
fi
cache_root="$(ct_nim_cache_root "${repo_root}")/frame-applier"
rm -rf "${out}"
mkdir -p "${out}"

nim_common=(--hints:off --warnings:off --path:src/frontend/viewmodel)

echo "--- building the nim js core ---"
if ! nim js "${nim_common[@]}" --nimcache:"${cache_root}/js" \
	-o:"${out}/core_js.raw.js" "${src_dir}/frame_events_core.nim"; then
	echo "  FAIL: the nim js core did not build"
	exit 1
fi
{
	echo "(function(){"
	cat "${out}/core_js.raw.js"
	echo "})();"
} >"${out}/core_js.js"

echo "--- building the wasm32 core ---"
exports="_main,_feMount,_feReadCrossings,_feOps,_feReset,_feManifest,_feFrameBase,_feFrameLen,_feDispatch"
if ! nim c "${nim_common[@]}" \
	--cpu:wasm32 --os:linux -d:emscripten \
	--cc:clang --clang.exe:emcc --clang.linkerexe:emcc \
	--mm:orc --threads:off \
	--passL:-sALLOW_MEMORY_GROWTH=1 \
	--passL:-sEXIT_RUNTIME=0 \
	--passL:-sMODULARIZE=1 \
	--passL:-sEXPORT_NAME=feModule \
	--passL:-sENVIRONMENT=web \
	--passL:"-sEXPORTED_FUNCTIONS=${exports}" \
	--passL:-sEXPORTED_RUNTIME_METHODS=cwrap,HEAPU8 \
	--nimcache:"${cache_root}/wasm" \
	-o:"${out}/core_wasm.js" "${src_dir}/frame_events_core.nim"; then
	echo "  FAIL: the wasm32 core did not build"
	exit 1
fi

cp "${applier}" "${src_dir}/page.html" "${src_dir}/host.js" "${out}/"

failures=0
for engine in ${CT_FRAME_APPLIER_ENGINES:-chromium firefox}; do
	echo "--- ${engine} ---"
	CT_REPO="${repo_root}" node "${src_dir}/browser.mjs" "${out}" "${engine}"
	rc=$?
	if [ "${rc}" -eq 2 ]; then
		exit 2
	elif [ "${rc}" -ne 0 ]; then
		failures=$((failures + 1))
	fi
done

if [ "${failures}" -ne 0 ]; then
	echo "frame-applier-browser: ${failures} engine(s) failed"
	exit 1
fi
echo "frame-applier-browser: ok"
