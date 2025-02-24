#!/usr/bin/env bash

set -e

echo '###############################################################################'
echo 'Checking db-backend'
echo '###############################################################################'

pushd src/db-backend

# threat warnings as errors here!
env RUSTFLAGS="-D warnings" cargo check --release --bin db-backend
env RUSTFLAGS="-D warnings" cargo check --release --bin virtualization-layers

cargo clippy -- -D warnings

popd


echo '###############################################################################'
echo 'Checking small-lang'
echo '###############################################################################'

pushd src/small-lang

# threat warnings as errors here!
env RUSTFLAGS="-D warnings" cargo check --release

cargo clippy -- -D warnings

popd

###############################################################################
