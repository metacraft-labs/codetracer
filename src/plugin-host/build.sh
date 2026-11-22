#!/usr/bin/env bash
# build.sh — builds `ct-plugin-host`, CodeTracer's WebAssembly plugin host
# (Extensibility-Model.md §11.9): the Rust engine layer (engine/, one engine
# only) as a static library, then the Nim host linked against it.
#
#   build.sh [--engine wasmi|wasmtime] [--out DIR] [--debug]
#
# wasmi is the engine CodeTracer ships (Extensibility-Model.md §11.9.1 has the
# measurements); wasmtime stays buildable for comparison.
#
# Output: DIR/ct-plugin-host (default DIR: build/bin). Needs the codetracer
# dev shell (cargo, nim). CT_ENGINE_TARGET overrides cargo's target dir.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "${here}/../.." && pwd)"
engine="wasmi"
out="${repo}/build/bin"
profile="release"
while [ $# -gt 0 ]; do
	case "$1" in
	--engine) engine="$2"; shift 2 ;;
	--out) out="$2"; shift 2 ;;
	--debug) profile="debug"; shift ;;
	*) echo "build.sh: unknown argument: $1" >&2; exit 2 ;;
	esac
done
case "${engine}" in wasmtime | wasmi) ;; *) echo "build.sh: --engine is wasmtime or wasmi" >&2; exit 2 ;; esac
target="${CT_ENGINE_TARGET:-${here}/engine/target}/host-${engine}"
cargo_profile=()
[ "${profile}" = "release" ] && cargo_profile=(--release)
cargo build --locked "${cargo_profile[@]}" ${CARGO_BUILD_JOBS:+-j "${CARGO_BUILD_JOBS}"} \
	--manifest-path "${here}/engine/Cargo.toml" --target-dir "${target}" \
	--lib --no-default-features --features "${engine}"
lib="${target}/${profile}/libct_plugin_engine.a"
[ -f "${lib}" ] || { echo "build.sh: cargo produced no ${lib}" >&2; exit 1; }
mkdir -p "${out}"
defines=()
[ "${engine}" = "wasmtime" ] && defines+=(-d:ctPluginHostWasmtime)
nim_flags=(-d:release)
[ "${profile}" = "debug" ] && nim_flags=(--debugger:native)
nim c --hints:off --warnings:off --threads:on --mm:orc "${nim_flags[@]}" \
	"${defines[@]}" -d:ctPluginEngineLib="${lib}" \
	--path:"${repo}/src/frontend/viewmodel" \
	--nimcache:"${target}/nimcache-${profile}" \
	-o:"${out}/ct-plugin-host" "${here}/ct_plugin_host.nim"
echo "built ${out}/ct-plugin-host (${engine}, ${profile})"
