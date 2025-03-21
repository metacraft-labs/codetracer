#!/usr/bin/env bash

mkdir -p "${DIST_DIR}/lib"

brew install libzip

HOMEBREW_LIB_DIR="/System/Volumes/Data/opt/homebrew/lib"

cp "${HOMEBREW_LIB_DIR}/libzip.dylib" "${DIST_DIR}/lib"

install_name_tool -add_rpath "${DIST_DIR}"/lib "${DIST_DIR}"/bin/ct
install_name_tool -change /usr/lib/libzip.dylib @rpath/libzip.dylib "${DIST_DIR}"/bin/ct
