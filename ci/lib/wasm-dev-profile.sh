# shellcheck shell=bash
#
# wasm-dev-profile.sh — the fast developer profile for wasm32 Nim builds.
#
# Source it, call `ct_wasm_dev_profile <object-cache-dir>`, and then build
# with the flags in `CT_WASM_CC_FLAGS`:
#
#   nim c --cpu:wasm32 … "${CT_WASM_CC_FLAGS[@]}" …
#
# It sets CT_WASM_CLANG and CT_WASM_CFLAGS for `ci/lib/wasm-cc.sh`, which
# compiles each C file with Emscripten's clang directly instead of through
# the `emcc` Python driver, and CT_WASM_OBJ_CACHE, a directory of compiled
# objects shared by every build that uses it. Linking still goes through
# `emcc`. See `wasm-cc.sh` for why each part is safe and what it saves.
#
# `emcc --cflags` and `em-config` are each one Python start-up, paid here
# once per lane rather than once per C file.
#
# Set CT_WASM_CC=emcc to build through `emcc` throughout instead — the
# profile's control, which `ci/test/wasm-dev-profile-test.sh` compares it
# against. An empty object-cache argument turns the cache off and keeps the
# direct compile.
#
# Returns non-zero, with a message, when Emscripten cannot answer; the caller
# decides whether that is fatal.

ct_wasm_dev_profile() {
	local obj_cache="${1:-}"
	# CT_WASM_CC_FLAGS is this function's result, read by the caller.
	# shellcheck disable=SC2034
	CT_WASM_CC_FLAGS=(--cc:clang --clang.exe:emcc --clang.linkerexe:emcc)
	if [ "${CT_WASM_CC:-}" = "emcc" ]; then
		return 0
	fi
	local llvm_root
	if ! llvm_root="$(em-config LLVM_ROOT 2>/dev/null)" || [ ! -x "${llvm_root}/clang" ]; then
		echo "wasm-dev-profile: em-config LLVM_ROOT did not name a clang; building through emcc" >&2
		return 1
	fi
	if ! CT_WASM_CFLAGS="$(emcc --cflags 2>/dev/null)" || [ -z "${CT_WASM_CFLAGS}" ]; then
		echo "wasm-dev-profile: emcc --cflags failed; building through emcc" >&2
		unset CT_WASM_CFLAGS
		return 1
	fi
	export CT_WASM_CLANG="${llvm_root}/clang"
	export CT_WASM_CFLAGS
	if [ -n "${obj_cache}" ]; then
		mkdir -p "${obj_cache}"
		export CT_WASM_OBJ_CACHE="${obj_cache}"
	else
		unset CT_WASM_OBJ_CACHE
	fi
	local here
	here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	# shellcheck disable=SC2034
	CT_WASM_CC_FLAGS=(--cc:clang --clang.exe:"${here}/wasm-cc.sh" --clang.linkerexe:emcc)
}
