#!/usr/bin/env bash
#
# web-core-build.sh <out-dir> [js] — build the browser front-end's WebAssembly
# ViewModel core and its host files into <out-dir>.
#
#   core_wasm.js, core_wasm.wasm   src/frontend/web_core/web_core.nim, wasm32
#   decorations.js                 web_core_decorations.nim, nim js, the host's
#                                  DOM decoration
#   frame_applier.js               IsoNim's applier
#   web_core_host.js               the core's host
#   web_core_panels.js             the renderer's pane host (-d:ctWasmPanes)
#   core_js.js (with "js")         the same core with nim js, for comparison
#
# CT_WEB_CORE_RELEASE=1 builds -d:release. Used by ci/test/web-core-browser.sh
# and by `just build-wasm-panes`. Exit 1 on a failed build, 2 on a missing tool.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=ci/lib/nim-cache-root.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "${repo_root}/ci/lib/nim-cache-root.sh"
cd "${repo_root}" || exit 2

out="${1:?usage: web-core-build.sh <out-dir> [js]}"
with_js="${2:-}"
for tool in nim emcc; do
	command -v "${tool}" >/dev/null 2>&1 || {
		echo "ERROR: ${tool} is not on PATH; run inside this repo's dev shell." >&2
		exit 2
	}
done
isonim_src="${ISONIM_SRC:-${repo_root}/../isonim/src}"
applier="${isonim_src}/isonim/web/frame_applier.js"
[ -f "${applier}" ] || {
	echo "ERROR: ${applier} is missing; IsoNim is too old or not beside this checkout." >&2
	exit 2
}
build_label=debug
opt_flags=()
if [ "${CT_WEB_CORE_RELEASE:-0}" = "1" ]; then
	opt_flags=(-d:release)
	build_label=release
fi
cache_root="$(ct_nim_cache_root "${repo_root}")/web-core-${build_label}"
mkdir -p "${out}"
entry="src/frontend/web_core/web_core.nim"
nim_common=(--hints:off --warnings:off --path:src/frontend/viewmodel -d:ctWasmCore -d:chronicles_enabled=off)

iife() { {
	echo "(function(){"
	cat "$1"
	echo "})();"
} >"$2"; }

echo "--- building the wasm32 core (${build_label}) ---"
exports="_main,_ctwBoot,_ctwPump,_ctwDeliver,_ctwOpenFolder,_ctwAttach,_ctwMountPane,_ctwPress,_ctwMenu,_ctwMenuChoose,_ctwMeasured,_ctwExpire,_ctwPhase,_ctwFailure,_ctwStep,_ctwStepping,_ctwPosition"
exports="${exports},_ctwReadCrossings,_ctwSetViewport,_ctwMounted,_ctwPending"
exports="${exports},_ctwFullValueOf,_ctwEventLogMetrics,_ctwEventLogSearch,_ctwEventLogTotal,_ctwEventLogCurrent,_ctwEventLogRowPx,_ctwShellMirror,_ctwCalltraceMeasured"
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

if [ "${with_js}" = "js" ]; then
	echo "--- building the nim js core (${build_label}) ---"
	if ! nim js "${nim_common[@]}" "${opt_flags[@]}" --nimcache:"${cache_root}/js" \
		-o:"${out}/core_js.raw.js" "${entry}"; then
		echo "  FAIL: the nim js core did not build"
		exit 1
	fi
	iife "${out}/core_js.raw.js" "${out}/core_js.js"
fi

echo "--- building the host's decoration bundle (${build_label}) ---"
if ! nim js "${nim_common[@]}" "${opt_flags[@]}" --nimcache:"${cache_root}/decorations" \
	-o:"${out}/decorations.raw.js" src/frontend/web_core/web_core_decorations.nim; then
	echo "  FAIL: the decoration bundle did not build"
	exit 1
fi
iife "${out}/decorations.raw.js" "${out}/decorations.js"

cp "${applier}" src/frontend/web_core/web_core_host.js src/frontend/web_core/web_core_panels.js "${out}/"
echo "WEB-CORE-ARTIFACT build=${build_label}" \
	"wasm_bytes=$(wc -c <"${out}/core_wasm.wasm" | tr -d ' ')" \
	"wasm_glue_bytes=$(wc -c <"${out}/core_wasm.js" | tr -d ' ')" \
	"wasm_gz=$(gzip -9 -c "${out}/core_wasm.wasm" | wc -c | tr -d ' ')" \
	${with_js:+"js_bytes=$(wc -c <"${out}/core_js.raw.js" | tr -d ' ')"} \
	${with_js:+"js_gz=$(gzip -9 -c "${out}/core_js.raw.js" | wc -c | tr -d ' ')"}
