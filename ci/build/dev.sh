#!/usr/bin/env bash

set -e

echo '###############################################################################'
echo "Build:"
echo '###############################################################################'

node_modules/.bin/webpack

pushd src

# Initialize the tup database if it doesn't exist (e.g. fresh CI checkout).
if [ ! -d .tup ]; then
	tup init
fi

tup build-debug

popd
