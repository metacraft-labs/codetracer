#!/usr/bin/env bash

set -e

NON_NIX_BUILD_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$NON_NIX_BUILD_DIR"

export ROOT_DIR=$NON_NIX_BUILD_DIR/..

OS_AND_SYSTEM=$(uname -a)

platform='unknown_platform'
os='unknown os'

if [[ $OS_AND_SYSTEM == *"NixOS"* ]]; then
	platform='nixos'
	os='linux'
elif [[ $OS_AND_SYSTEM == *"fedora"* ]]; then
	platform='fedora'
	os='linux'
elif [[ $OS_AND_SYSTEM == "Linux"* ]]; then
	platform='linux'
	os='linux'
elif [[ $OS_AND_SYSTEM == "Darwin"* ]]; then
	platform='mac'
	os='mac'
fi

export platform
export os

: "${BIN_DIR:="$NON_NIX_BUILD_DIR"/bin}"
: "${DEPS_DIR:="$NON_NIX_BUILD_DIR"/deps}"

echo "BIN_DIR" "${BIN_DIR}"
echo "DEPS_DIR" "${DEPS_DIR}"

mkdir -p "$BIN_DIR"
mkdir -p "$DEPS_DIR"

export BIN_DIR
export DEPS_DIR
export DIST_DIR

export RUSTUP_HOME=$DEPS_DIR/rustup
export CARGO_HOME=$DEPS_DIR/cargo

# Active build output dir. The non-Nix path defaults to the reprobuild build
# (src/build-<config>-repro) except on Linux, where the legacy tup build
# (src/build-<config>) is the default. CODETRACER_CONFIG (debug|release)
# selects the configuration. CODETRACER_PREFIX is intentionally not set: ct
# self-resolves its prefix from its own location (paths.nim getAppDir
# fallback), so a binary run from any build dir uses that dir's assets; the
# GUI test fixtures set CODETRACER_PREFIX explicitly where a renderer needs it.
# See codetracer-specs Architecture/Build-Outputs-And-Path-Resolution.md.
_ct_config="${CODETRACER_CONFIG:-debug}"
case "$(uname -s)" in
Linux) _ct_build_dir="$ROOT_DIR/src/build-${_ct_config}" ;;
*) _ct_build_dir="$ROOT_DIR/src/build-${_ct_config}-repro" ;;
esac
export CODETRACER_BUILD_DIR="${CODETRACER_BUILD_DIR:-$_ct_build_dir}"
export CODETRACER_LD_LIBRARY_PATH="${CODETRACER_LD_LIBRARY_PATH:-}"

export PATH=$DEPS_DIR/nim/bin:$ROOT_DIR/node_modules/.bin:$BIN_DIR:$CARGO_HOME/bin:$CODETRACER_BUILD_DIR/bin:$PATH
export NIM1=$DEPS_DIR/nim/bin/nim

if [ "$os" == "mac" ]; then
	brew install sqlite3 ruby universal-ctags go capnp tree-sitter-cli
fi

./install_rust.sh
./install_node.sh
./install_nargo.sh
./build_trace_writer_ffi.sh
./install_wazero.sh
./install_nim_osx.sh
./install_ct_remote.sh

if [[ $platform == "mac" ]]; then
	DEFAULT_DIST_DIR=$NON_NIX_BUILD_DIR/CodeTracer.app/Contents/MacOS
else
	DEFAULT_DIST_DIR=$NON_NIX_BUILD_DIR/dist
fi

: "${DIST_DIR:=$DEFAULT_DIST_DIR}"

pushd "$ROOT_DIR"
[ ! -d node_modules ] && ln -s node-packages/node_modules ./
popd
