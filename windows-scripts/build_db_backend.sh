#!/usr/bin/env bash

pushd "${GIT_ROOT}"/src/db-backend || exit

# TODO: Don't hardcode target
cargo-xwin build --release --cross-compiler clang --target x86_64-pc-windows-msvc

popd || exit

# TODO: Don't hardcode target
cp "${GIT_ROOT}"/src/db-backend/target/x86_64-pc-windows-msvc/release "${APP_DIR}"/bin
