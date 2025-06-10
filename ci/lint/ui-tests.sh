#!/usr/bin/env bash

set -e

###############################################################################

pushd ui-tests

type npx
npx prettier --check .
npx eslint
tsc
git clean -xfd .

popd

###############################################################################
