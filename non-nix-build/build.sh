#!/usr/bin/env bash

set -e

NON_NIX_BUILD_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd $NON_NIX_BUILD_DIR

source env.sh

echo "platform: ${platform}; os: ${os}"

mkdir -p "$BIN_DIR" "$DEPS_DIR"

# passing platform and os as args, not env var, to make it easier
# to pass in nix-shell without modifying env
case $platform in
  'linux')
    # TODO install main deps: electron/etc
    ./install_rust.sh
    ./build_in_simple_env.sh "$platform" "$os"
    ;;
  'mac')
    ./build_in_simple_env.sh "$platform" "$os"
    ./build_mac_app.sh
    echo Successfully built non-nix-build/CodeTracer.app
    ;;
   *)
    echo "unsupported platform"
    exit 1
    ;;
esac
