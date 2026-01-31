#!/usr/bin/env bash

set -e

WANTED_NIM_VERSION=v1.6.20

if command -v nim &>/dev/null; then
	echo "Nim is already installed"
	exit 0
else
	echo nim is missing! installing...
fi

: "${DEPS_DIR:=$PWD/deps}"
cd "$DEPS_DIR"

# based on https://forum.nim-lang.org/t/10373#69081: from Araq:
# but for v1

rm -rf csources_v1/
rm -rf nim/

git clone https://github.com/nim-lang/csources_v1
pushd csources_v1
make -j 8
popd

git clone https://github.com/nim-lang/nim
mv csources_v1/bin/nim nim/bin

pushd nim
git checkout $WANTED_NIM_VERSION
bin/nim c koch.nim
./koch boot -d:release
popd
