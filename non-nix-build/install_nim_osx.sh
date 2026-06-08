#!/usr/bin/env bash

set -e

# Track the rest of the codebase (nix devshell + Windows toolchain
# pin in non-nix-build/windows/toolchain-versions.env): Nim 2.2.
# libs/NimYAML 2.x and the codetracer Nim sources use 2.0 features
# (default field initialisers in object types) that 1.6.x cannot
# parse.  Tested with 2.2.8; nim-2.2 csources live in csources_v3.
WANTED_NIM_VERSION=v2.2.8

if command -v nim &>/dev/null; then
	echo "Nim is already installed"
	exit 0
else
	echo nim is missing! installing...
fi

: "${DEPS_DIR:=$PWD/deps}"
cd "$DEPS_DIR"

# based on https://forum.nim-lang.org/t/10373#69081: from Araq

rm -rf csources_v3/
rm -rf nim/

git clone https://github.com/nim-lang/csources_v3
pushd csources_v3
make -j 8
popd

git clone https://github.com/nim-lang/nim
mv csources_v3/bin/nim nim/bin

pushd nim
git checkout $WANTED_NIM_VERSION
bin/nim c koch.nim
./koch boot -d:release
# Compile nimsuggest alongside Nim — needed by `just test-nimsuggest`
# which validates that the CodeTracer LSP module can be loaded.
bin/nim c -d:release -o:bin/nimsuggest nimsuggest/nimsuggest.nim
popd
