#!/usr/bin/env bash

set -e

echo '###############################################################################'
echo 'Running ui e2e playwright tests'
echo '###############################################################################'

# TODO: maybe pass the result from the build stage as artifact to this job?
./ci/build/dev.sh

pushd ui-tests
nix develop --command ./ci.sh
popd
