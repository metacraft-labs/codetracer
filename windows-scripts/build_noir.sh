#!/usr/bin/env bash

pushd "${GIT_ROOT}"/windows-scripts/noir || exit

# TODO: Don't hardcode target
cargo-xwin build --release --cross-compiler clang --target x86_64-pc-windows-msvc

popd || exit

# TODO: Don't hardcode target
cp "${GIT_ROOT}"/windows-scripts/noir/target/x86_64-pc-windows-msvc/release/nargo.exe "${APP_DIR}"/bin
