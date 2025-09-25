#!/usr/bin/env bash

set -e

echo '###############################################################################'
echo 'Running ui e2e playwright tests'
echo '###############################################################################'

# TODO: maybe pass the result from the build stage as artifact to this job?
# TODO: tup generate seems problematic with variants: we need to fix/change the resulting dirs to work correctly
# ./ci/build/dev.sh

./ci/build/nix.sh

CODETRACER_E2E_CT_PATH="$(pwd)/result/bin/ct"
export CODETRACER_E2E_CT_PATH

pushd ui-tests
nix develop --command ./ci.sh
popd
