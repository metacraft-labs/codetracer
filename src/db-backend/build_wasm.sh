#!/usr/bin/env bash
set -euo pipefail

# your sysroot layout: wasm-sysroot/{include,lib,...}
SYSROOT="$(pwd)/wasm-sysroot"

echo "SYSROOT: ${SYSROOT}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RECORDER_ROOT="$WORKSPACE_ROOT/codetracer-native-recorder"
EMULATOR_DIR="$RECORDER_ROOT/ct_emulator"
EMULATOR_WASM_BUILD_SCRIPT="$EMULATOR_DIR/build_wasm_api.sh"

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
  echo "error: could not locate llvm-ar; install it or run \`rustup component add llvm-tools\`" >&2
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
  MINGW*|MSYS*|CYGWIN*|*_NT*)
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
  echo "error: missing executable emulator WASM build script: $EMULATOR_WASM_BUILD_SCRIPT" >&2
  exit 1
fi

echo "Regenerating emulator WASM C inputs"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|*_NT*)
    bash "$EMULATOR_WASM_BUILD_SCRIPT"
    ;;
  *)
    direnv exec "$RECORDER_ROOT" bash "$EMULATOR_WASM_BUILD_SCRIPT"
    ;;
esac

# build (just your crate, or the specific package)
cargo build --target wasm32-unknown-unknown --release --no-default-features --features browser-transport

wasm-pack build --target web --release -d ./wasm-testing/pkg -- --no-default-features --features browser-transport
