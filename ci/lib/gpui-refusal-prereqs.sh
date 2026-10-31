#!/usr/bin/env bash
# NOT-A-CI-GATE: a prerequisite BUILDER, not a check — it builds the
# featureless shim and entry point that `src/frontend/gpui/tests/
# test_gpui_window_refusal.nim` (lane `gpui-shell`) then asserts against, and
# that suite runs it and fails by name when it cannot. It asserts nothing
# itself.
#
# The refusal suite needs a featureless shim even when the rest of gpui-shell
# uses a windowed one. Build both the shim and the production entry point in
# this checkout's own directory, without changing either shared build output.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo"
gpui_src="${ISONIM_GPUI_SRC:-$repo/../isonim-gpui/src}"
gpui_root="$(cd "$gpui_src/.." && pwd)"
out="$repo/build/gpui-refusal"
program=codetracer-gpui
case "$(uname -s)" in
Darwin) library=libgpui_nim_shim.dylib ;;
MINGW* | MSYS* | CYGWIN*)
	library=gpui_nim_shim.dll
	program=codetracer-gpui.exe
	;;
*) library=libgpui_nim_shim.so ;;
esac
mkdir -p "$out"
# The sibling owns the Rust toolchain and platform dependencies. In particular,
# building its Cargo package in the consumer's shell would use a different SDK.
repro exec "$gpui_root" -- cargo build --locked \
	--manifest-path "$gpui_root/rust/Cargo.toml" --package gpui-nim-shim \
	--no-default-features --target-dir "$out/shim" --jobs 2
shim="$out/shim/debug/$library"
if [ ! -f "$shim" ]; then
	echo "FAIL: featureless shim build produced no $shim" >&2
	exit 1
fi
# Use the shipped build's flags and source entry point, with only its output,
# cache and explicit shim binding changed. Always recompile so edits to the
# application or any dependency cannot be hidden by an old prerequisite.
# shellcheck source=ci/lib/build-freshness.sh disable=SC1091
source ci/lib/build-freshness.sh
gpui_args=()
while IFS= read -r arg; do gpui_args+=("$arg"); done < <(bf_gpui_nim_args)
nim c --hints:off "${gpui_args[@]}" --parallelBuild:2 \
	--path:"$gpui_root/src" "-d:gpuiShimPath=$shim" \
	--nimcache:"$out/nimcache" -o:"$out/$program" \
	src/frontend/gpui/main.nim
