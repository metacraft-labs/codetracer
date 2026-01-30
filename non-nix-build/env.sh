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

if [ ! -f "$ROOT_DIR"/ct_paths.json ]; then
  echo "{\"PYTHONPATH\": \"\",\"LD_LIBRARY_PATH\":\"\"}" > "$ROOT_DIR"/ct_paths.json
fi

export PATH=$DEPS_DIR/nim/bin:$ROOT_DIR/node_modules/.bin:$BIN_DIR:$CARGO_HOME/bin:$ROOT_DIR/src/build-debug/bin:$PATH
export NIM1=$DEPS_DIR/nim/bin/nim

if [ "$os" == "mac" ]; then
  brew install sqlite3 ruby node universal-ctags go capnp
fi

./install_rust.sh
./install_nargo.sh
./install_wazero.sh
./install_nim_osx.sh
./install_ct_remote.sh

if [[ "$platform" == "mac" ]]; then
  DEFAULT_DIST_DIR=$NON_NIX_BUILD_DIR/CodeTracer.app/Contents/MacOS
else
  DEFAULT_DIST_DIR=$NON_NIX_BUILD_DIR/dist
fi

: "${DIST_DIR:=$DEFAULT_DIST_DIR}"

pushd "$ROOT_DIR"
  [ ! -d node_modules ] && ln -s node-packages/node_modules ./
popd

mkdir -p ../src/links
pushd ../src/links
  [ ! -f codetracer-pure-ruby-recorder ]     && ln -sf "$NON_NIX_BUILD_DIR/../libs/codetracer-ruby-recorder/gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder" codetracer-pure-ruby-recorder
  # [ ! -f recorder.rb ]  && ln -sf "$NON_NIX_BUILD_DIR/../libs/codetracer-ruby-recorder/src/recorder.rb" recorder.rb
  [ ! -f trace.py ]     && ln -sf "$NON_NIX_BUILD_DIR/../libs/codetracer-python-recorder/src/trace.py" trace.py

  [ ! -f bash ]         && ln -sf "$(readlink -f "$(which bash)")" bash
  [ ! -f node ]         && ln -sf "$(readlink -f "$(which node)")" node
  [ ! -f ruby ]         && ln -sf "$(brew --prefix ruby)"/bin/ruby ruby
  [ ! -f nargo ]        && ln -sf "$(readlink -f "$(which nargo)")" nargo
  [ ! -f electron ]     && ln -sf "$(readlink -f "$(which electron)")" electron
  [ ! -f ct-remote ]    && ln -sf "$BIN_DIR/ct-remote" ct-remote
popd
