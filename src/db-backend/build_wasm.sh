#!/usr/bin/env bash
set -euo pipefail

# your sysroot layout: wasm-sysroot/{include,lib,...}
SYSROOT="$(pwd)/wasm-sysroot"

echo "SYSROOT: ${SYSROOT}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# EVERY PATH THIS SCRIPT NEEDS AFTER THE SOURCE BELOW IS RESOLVED HERE, BEFORE
# IT, UNDER A `CT_`-PREFIXED NAME. `ct_emulator/export_build_env.sh` lives in
# ANOTHER REPOSITORY (codetracer-native-recorder) and assigns, at top level,
# both `SCRIPT_DIR` (its line 7) and `RECORDER_ROOT` (its line 8) — so after
# `source "$PRIVATE_BUILD_ENV"` those two names in THIS shell describe the
# recorder, not this repo.
#
# MEASURED, the first time this bit: the stamping step at the end of this
# script resolved `$SCRIPT_DIR/../../ci/lib/...` to
# `/Users/zahary/m/dev/ci/lib/...` — one directory above BOTH repositories —
# and the build finished 0 with the stamp silently unwritten (295f36835).
#
# `RECORDER_ROOT` was the SECOND one and it SURVIVED that fix, because its two
# uses (the diagnostic below and the `direnv exec` that follows) happen to
# receive an equal value today: the sibling is checked out at exactly
# `<workspace>/codetracer-native-recorder`, so `$SCRIPT_DIR/..` inside the
# sourced file names the same directory this script had already computed. That
# is a coincidence of layout, not a property — `direnv exec` on it is one
# symlinked or relocated checkout away from loading another repository's
# `.envrc`, and no test anywhere would have noticed.
#
# THIS SIDE IS THE ONLY SIDE THAT CAN BE FIXED. The sourced file is in another
# repository's change control; it is free to start assigning `WORKSPACE_ROOT`
# or `SYSROOT` tomorrow and nothing here would say so. Arm B of
# `ci/test/sourced-var-collision-gate.sh` therefore refuses any generic name
# USED after a source that leaves this repository, which is what keeps the
# names below prefixed once this comment has been forgotten.
CT_REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CT_WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CT_RECORDER_ROOT="$CT_WORKSPACE_ROOT/codetracer-native-recorder"
CT_EMULATOR_DIR="$CT_RECORDER_ROOT/ct_emulator"
PRIVATE_BUILD_ENV="$CT_EMULATOR_DIR/export_build_env.sh"

if [ -f "$PRIVATE_BUILD_ENV" ]; then
	# shellcheck source=/dev/null
	source "$PRIVATE_BUILD_ENV"
	EMULATOR_WASM_BUILD_SCRIPT="$CT_MCR_EMULATOR_WASM_BUILD_SCRIPT"
else
	EMULATOR_WASM_BUILD_SCRIPT="$CT_EMULATOR_DIR/build_wasm_api.sh"
fi

# make sure we use LLVM tools for wasm C/AR
export CC_wasm32_unknown_unknown=clang

# `AR_wasm32_unknown_unknown` must point at an LLVM archiver that can
# create wasm-object archives. On most platforms a bare `llvm-ar` on
# PATH is fine, but the Windows DIY toolchain ships clang without a
# co-located `llvm-ar`; rustup's `llvm-tools` component provides one
# under the toolchain sysroot. Discover a working archiver rather than
# assuming `llvm-ar` resolves.
if [ -z "${AR_wasm32_unknown_unknown:-}" ]; then
	if command -v llvm-ar >/dev/null 2>&1; then
		AR_wasm32_unknown_unknown="$(command -v llvm-ar)"
	elif command -v rustc >/dev/null 2>&1; then
		rust_sysroot="$(rustc --print sysroot)"
		for host in x86_64-pc-windows-msvc x86_64-unknown-linux-gnu \
			aarch64-apple-darwin x86_64-apple-darwin aarch64-pc-windows-msvc; do
			candidate="$rust_sysroot/lib/rustlib/$host/bin/llvm-ar"
			for c in "$candidate" "$candidate.exe"; do
				if [ -x "$c" ]; then
					AR_wasm32_unknown_unknown="$c"
					break 2
				fi
			done
		done
	fi
fi
if [ -z "${AR_wasm32_unknown_unknown:-}" ]; then
	# shellcheck disable=SC2016
	echo 'error: could not locate llvm-ar; install it or run `rustup component add llvm-tools`' >&2
	exit 1
fi
export AR_wasm32_unknown_unknown
echo "AR_wasm32_unknown_unknown: ${AR_wasm32_unknown_unknown}"

# Build-script crates (proc-macro2, serde, getrandom, ...) compile for the
# *host* target, so on Windows their final link step needs MSVC's
# `link.exe`. Under MSYS2/Git-bash, `/usr/bin/link` (GNU coreutils)
# shadows it and the link fails with "extra operand". Pin the host MSVC
# linker explicitly when one is known so the build is independent of
# bash's PATH ordering.
case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN* | *_NT*)
	if [ -n "${WINDOWS_DIY_CL_EXE:-}" ]; then
		msvc_bin="$(dirname "${WINDOWS_DIY_CL_EXE}")"
		msvc_link="${msvc_bin}/link.exe"
		if [ -x "$msvc_link" ]; then
			export CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER="$msvc_link"
			export CARGO_TARGET_AARCH64_PC_WINDOWS_MSVC_LINKER="$msvc_link"
			echo "host MSVC linker: ${msvc_link}"
		fi
	fi
	;;
esac

if [ "${CODETRACER_WASM_BUILD_CLEAN:-1}" != "0" ]; then
	cargo clean
else
	echo "Skipping cargo clean because CODETRACER_WASM_BUILD_CLEAN=0"
fi

if [ ! -x "$EMULATOR_WASM_BUILD_SCRIPT" ]; then
	echo "error: missing private emulator WASM build script: $EMULATOR_WASM_BUILD_SCRIPT" >&2
	echo "       browser MCR emulator replay requires sibling repo: $CT_RECORDER_ROOT" >&2
	exit 1
fi

echo "Regenerating emulator WASM C inputs"
case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN* | *_NT*)
	bash "$EMULATOR_WASM_BUILD_SCRIPT"
	;;
*)
	direnv exec "$CT_RECORDER_ROOT" bash "$EMULATOR_WASM_BUILD_SCRIPT"
	;;
esac

# build (just your crate, or the specific package)
cargo build --target wasm32-unknown-unknown --release --no-default-features --features browser-transport

wasm-pack build --target web --release -d ./wasm-testing/pkg -- --no-default-features --features browser-transport

# Record WHICH SOURCES this engine was built from, next to the engine itself.
#
# `wasm-testing/pkg/` is gitignored, so it survives branch switches, rebases
# and worktree copies with nothing to mark it stale. Gates that read it used to
# check only that a .wasm existed and was over a megabyte; measured on
# 2026-09-06, that let `ci/test/worker-backend-wasm-e2e.sh` report 19 passed /
# 0 failed while driving an engine built six days and 42 db-backend commits
# earlier. The stamp is what lets a reader tell the difference.
#
# Not an mtime: see the header of ci/lib/wasm-engine-freshness.sh for why the
# obvious mtime check is the one that cannot be cleared by its own remedy.
# shellcheck source=ci/lib/wasm-engine-freshness.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "$CT_REPO_ROOT/ci/lib/wasm-engine-freshness.sh"
wasm_engine_write_stamp "$CT_REPO_ROOT"
