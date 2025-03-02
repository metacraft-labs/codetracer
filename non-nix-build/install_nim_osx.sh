#!/usr/bin/env bash

set -e

cd ../libs/csources_v1 || exit
make -j 8 || exit
mv bin/nim ../nim/bin || exit
cd ../nim/ || exit

bin/nim c koch.nim || exit
./koch boot -d:release || exit

cd ../../non-nix-build || exit