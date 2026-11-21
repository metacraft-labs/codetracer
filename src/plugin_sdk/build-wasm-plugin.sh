#!/usr/bin/env bash
# build-wasm-plugin.sh — builds a CodeTracer plugin package's `plugin.wasm`
# from its Nim source, with the wasm32 toolchain the WebAssembly ViewModel
# core is built with (Nim through Emscripten's clang, --mm:orc, no threads):
# the module `ct-plugin-host` loads, one file for every platform.
#
#   build-wasm-plugin.sh <plugin.nim> <out.wasm> [extra nim flags...]
#
# `STANDALONE_WASM` with no entry point: the module imports only what the host
# offers (the `ct` imports and a handful of WASI calls), and exports
# `ct_plugin_init`, `ct_plugin_alloc`, `ct_plugin_frame` and `ct_plugin_idle`,
# which `codetracer_plugin_sdk` defines on wasm32. Needs emcc (the codetracer
# dev shell).
set -euo pipefail
[ $# -ge 2 ] || { echo "usage: build-wasm-plugin.sh <plugin.nim> <out.wasm> [nim flags...]" >&2; exit 2; }
src="$1"; out="$2"; shift 2
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "${here}/../.." && pwd)"
cache="${CT_WASM_PLUGIN_NIMCACHE:-$(dirname "${out}")/nimcache-$(basename "${out}" .wasm)}"
mkdir -p "$(dirname "${out}")"
nim c --hints:off --warnings:off \
	--cpu:wasm32 --os:linux -d:emscripten \
	--cc:clang --clang.exe:emcc --clang.linkerexe:emcc \
	--mm:orc --threads:off --noMain:on --app:lib -d:release \
	--passL:-sSTANDALONE_WASM --passL:--no-entry \
	--passL:-sALLOW_MEMORY_GROWTH=1 --passL:-sINITIAL_MEMORY=4194304 \
	--passL:-sSTACK_SIZE=1048576 \
	--path:"${here}" --path:"${repo}/src/frontend/viewmodel" \
	"$@" --nimcache:"${cache}" -o:"${out}" "${src}"
echo "built ${out} ($(wc -c <"${out}" | tr -d ' ') bytes)"
