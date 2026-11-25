#!/usr/bin/env bash
#
# wasm-panes-desktop.sh — the desktop app with the WebAssembly panes
# (-d:ctWasmPanes), in the real Electron app over a real recording.
#
# Takes a built desktop (CODETRACER_BUILD_DIR, default src/build-debug-repro),
# replaces its renderer bundle (ui.js, beside the index.html that loads it)
# with one built -d:ctWasmPanes, puts the core and its host files in
# wasm-panes/ beside it, runs
# src/tests/gui/tests/wasm-panes/wasm_panes_draw_the_panes.spec.ts, and puts
# the original ui.js back whatever happened.
#
# Exit 0 when the spec passed, 1 when it or a build failed, 2 when the desktop
# build or a tool is missing — a failure, never a skip.

set -uo pipefail
# The spec's output is shown as it runs through `tee >(cat >&2)`, not
# `tee /dev/stderr`: when stderr is a file, the latter reopens it from the
# start and overwrites everything written before, the measurements included.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

build_dir="${CODETRACER_BUILD_DIR:-${repo_root}/src/build-debug-repro}"
index="$(grep -l "src='ui.js'" "${build_dir}"/index.html "${build_dir}"/*/index.html 2>/dev/null | head -1)"
if [ -z "${index}" ]; then
	echo "ERROR: no desktop build at ${build_dir} (no index.html loading ui.js); run just build-once first." >&2
	exit 2
fi
page_dir="$(dirname "${index}")"
if [ ! -f "${page_dir}/ui.js" ]; then
	echo "ERROR: ${page_dir}/ui.js is missing." >&2
	exit 2
fi

echo "--- the current renderer's cold start and memory ---"
(cd src/tests/gui && CODETRACER_BUILD_DIR="${build_dir}" npx playwright test \
	tests/wasm-panes/wasm_panes_draw_the_panes.spec.ts -g "are measured" --reporter=line) | grep -E 'PLAT87-RENDERER|passed|failed'

backup="${page_dir}/ui.js.before-wasm-panes"
cp "${page_dir}/ui.js" "${backup}"
restore() {
	mv -f "${backup}" "${page_dir}/ui.js"
	rm -rf "${page_dir}/wasm-panes"
}
trap restore EXIT

echo "--- the renderer, -d:ctWasmPanes ---"
if ! nim -d:chronicles_enabled=off -d:ctRenderer -d:ctWasmPanes --debugInfo:on --lineDir:on \
	--hints:off --warnings:off --out:"${page_dir}/ui.js" js src/frontend/ui_js.nim; then
	echo "  FAIL: the -d:ctWasmPanes renderer did not build"
	exit 1
fi
if ! bash ci/lib/web-core-build.sh "${page_dir}/wasm-panes"; then
	echo "  FAIL: the wasm panes did not build"
	exit 1
fi

echo "--- the spec ---"
(cd src/tests/gui && CT_WASM_PANES_REQUIRED=1 CODETRACER_BUILD_DIR="${build_dir}" npx playwright test \
	tests/wasm-panes/wasm_panes_draw_the_panes.spec.ts --reporter=line) | tee >(cat >&2) | grep ' passed' >/dev/null
rc=$?
echo "--- the spec in the web build, served by ct host, in a browser ---"
# The same renderer bundle, served by `ct host` (which serves wasm-panes/
# beside ui.js) and opened in a browser: the browser front-end with the
# editor pane open, over the same recording.
(cd src/tests/gui && CODETRACER_TEST_IN_BROWSER=1 CT_WASM_PANES_REQUIRED=1 CODETRACER_BUILD_DIR="${build_dir}" npx playwright test \
	tests/wasm-panes/wasm_panes_draw_the_panes.spec.ts -g "draw Call Trace" --reporter=line) | tee >(cat >&2) | grep ' passed' >/dev/null
web_rc=$?
if [ "${rc}" -ne 0 ] || [ "${web_rc}" -ne 0 ]; then
	echo "wasm-panes-desktop: FAILED (electron ${rc}, web ${web_rc})"
	exit 1
fi
echo "wasm-panes-desktop: ok"
