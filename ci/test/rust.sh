#!/usr/bin/env bash

set -e

echo '###############################################################################'
echo 'Checking db-backend'
echo '###############################################################################'

pushd src/db-backend

# test all: including ignored by default
# the ignored ones are just a bit slow
# so we don't run them by default
cargo test --release --bin db-backend # test non-ignored
cargo test --release --bin db-backend -- --ignored # test ignored

popd


echo '###############################################################################'
echo 'Checking backend-manager'
echo '###############################################################################'

pushd src/backend-manager

cargo test --release

popd
