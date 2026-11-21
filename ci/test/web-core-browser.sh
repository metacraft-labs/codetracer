#!/usr/bin/env bash
#
# web-core-browser.sh — the browser front-end's WebAssembly ViewModel core
# (`src/frontend/web_core/web_core.nim`) on a real recording, served by a real
# replay-server, in Chromium and Firefox.
#
# Builds the core for wasm32 (Emscripten, `-sENVIRONMENT=web`) and with
# `nim js`, both `-d:ctWasmCore`, assembles the page with IsoNim's frame
# applier and `web_core_host.js`, and runs `web-core-browser/browser.mjs`,
# which opens the recording, steps it and compares the two cores' documents.
#
#   REPLAY_SERVER_BIN          the engine (required)
#   CT_WEB_CORE_RECORDING      the recording folder (required)
#   CT_WEB_CORE_ENGINES        engines to run (default "chromium firefox")
#   CT_WEB_CORE_STEPS          steps per run (default 4)
#   CT_WEB_CORE_RELEASE=1      build both cores -d:release
#   CT_WEB_CORE_OUT            build directory (default test-logs/web-core)
#
# Exit 0 when every engine passed, 1 when a build or a check failed, 2 when a
# prerequisite is missing — a failure, never a skip.

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
replay_server="${REPLAY_SERVER_BIN:-}"
recording="${CT_WEB_CORE_RECORDING:-}"
if [ -z "${replay_server}" ] || [ ! -x "${replay_server}" ]; then
	echo "ERROR: REPLAY_SERVER_BIN must name a replay-server binary (got '${replay_server}')." >&2
	exit 2
fi
if [ -z "${recording}" ] || [ ! -d "${recording}" ]; then
	echo "ERROR: CT_WEB_CORE_RECORDING must name a recording folder (got '${recording}')." >&2
	exit 2
fi

isonim_src="${ISONIM_SRC:-${repo_root}/../isonim/src}"
applier="${isonim_src}/isonim/web/frame_applier.js"
if [ ! -f "${applier}" ]; then
	echo "ERROR: ${applier} is missing; IsoNim is too old or not beside this checkout." >&2
	exit 2
fi

out="${CT_WEB_CORE_OUT:-${repo_root}/test-logs/web-core}"
build_label=debug
opt_flags=()
if [ "${CT_WEB_CORE_RELEASE:-0}" = "1" ]; then
	opt_flags=(-d:release)
	build_label=release
fi
cache_root="$(ct_nim_cache_root "${repo_root}")/web-core-${build_label}"
rm -rf "${out}"
mkdir -p "${out}"
entry="src/frontend/web_core/web_core.nim"
nim_common=(--hints:off --warnings:off --path:src/frontend/viewmodel -d:ctWasmCore -d:chronicles_enabled=off)

echo "--- building the wasm32 core (${build_label}) ---"
exports="_main,_ctwBoot,_ctwPump,_ctwDeliver,_ctwOpenFolder,_ctwPhase,_ctwFailure,_ctwStep,_ctwStepping,_ctwPosition,_ctwReadCrossings,_ctwSetViewport,_ctwMounted,_ctwPending"
exports="${exports},_isonimFrameBase,_isonimFrameLen,_isonimFrameOps,_isonimFrameReset,_isonimFrameManifest,_isonimFrameDispatch,_isonimFrameForget"
if ! nim c "${nim_common[@]}" "${opt_flags[@]}" \
	--cpu:wasm32 --os:linux -d:emscripten \
	--cc:clang --clang.exe:emcc --clang.linkerexe:emcc \
	--mm:orc --threads:off \
	--passL:-sSTACK_SIZE=8388608 \
	--passL:-sALLOW_MEMORY_GROWTH=1 \
	--passL:-sEXIT_RUNTIME=0 \
	--passL:-sMODULARIZE=1 \
	--passL:-sEXPORT_NAME=ctwModule \
	--passL:-sENVIRONMENT=web \
	--passL:"--js-library=${repo_root}/src/frontend/web_core/web_core_library.js" \
	--passL:"-sEXPORTED_FUNCTIONS=${exports}" \
	--passL:-sEXPORTED_RUNTIME_METHODS=cwrap,HEAPU8 \
	--nimcache:"${cache_root}/wasm" \
	-o:"${out}/core_wasm.js" "${entry}"; then
	echo "  FAIL: the wasm32 core did not build"
	exit 1
fi

echo "--- building the nim js core (${build_label}) ---"
if ! nim js "${nim_common[@]}" "${opt_flags[@]}" --nimcache:"${cache_root}/js" \
	-o:"${out}/core_js.raw.js" "${entry}"; then
	echo "  FAIL: the nim js core did not build"
	exit 1
fi
{
	echo "(function(){"
	cat "${out}/core_js.raw.js"
	echo "})();"
} >"${out}/core_js.js"

cp "${applier}" src/frontend/web_core/web_core_host.js ci/test/web-core-browser/page.html "${out}/"
echo "WEB-CORE-ARTIFACT build=${build_label}" \
	"wasm_bytes=$(wc -c <"${out}/core_wasm.wasm" | tr -d ' ')" \
	"wasm_glue_bytes=$(wc -c <"${out}/core_wasm.js" | tr -d ' ')" \
	"js_bytes=$(wc -c <"${out}/core_js.raw.js" | tr -d ' ')" \
	"wasm_gz=$(gzip -9 -c "${out}/core_wasm.wasm" | wc -c | tr -d ' ')" \
	"js_gz=$(gzip -9 -c "${out}/core_js.raw.js" | wc -c | tr -d ' ')"

failures=0
for engine in ${CT_WEB_CORE_ENGINES:-chromium firefox}; do
	echo "--- ${engine} ---"
	CT_REPO="${repo_root}" node ci/test/web-core-browser/browser.mjs "${out}" "${engine}" \
		"${replay_server}" "${recording}" "${CT_WEB_CORE_STEPS:-4}"
	rc=$?
	if [ "${rc}" -eq 2 ]; then
		exit 2
	elif [ "${rc}" -ne 0 ]; then
		failures=$((failures + 1))
	fi
done
if [ "${failures}" -ne 0 ]; then
	echo "web-core-browser: ${failures} engine(s) failed"
	exit 1
fi
echo "web-core-browser: ok"
