#!/usr/bin/env bash

set -e

WANTED_NIM_VERSION=v2.2.8

if command -v nim &>/dev/null; then
	echo "Nim is already installed"
	exit 0
else
	echo nim is missing! installing...
fi

: "${DEPS_DIR:=$PWD/deps}"
cd "$DEPS_DIR"

rm -rf csources_v2/
rm -rf nim/

git clone https://github.com/nim-lang/csources_v2
pushd csources_v2
make -j 8
popd

git clone https://github.com/nim-lang/nim
mv csources_v2/bin/nim nim/bin

pushd nim
git checkout $WANTED_NIM_VERSION
bin/nim c koch.nim
./koch boot -d:release
# Compile nimsuggest alongside Nim — needed by `just test-nimsuggest`
# which validates that the CodeTracer LSP module can be loaded.
bin/nim c -d:release -o:bin/nimsuggest nimsuggest/nimsuggest.nim
popd
