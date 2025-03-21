#!/usr/bin/env bash

LIB_DIR="./CodeTracer.app/Contents/Frameworks"

mkdir -p "${LIB_DIR}"

brew install libzip

HOMEBREW_LIB_DIR="/System/Volumes/Data/opt/homebrew/lib"

cp "${HOMEBREW_LIB_DIR}/libzip.dylib" "${LIB_DIR}"

install_name_tool -add_rpath "${LIB_DIR}" "${DIST_DIR}"/bin/ct
install_name_tool -change /usr/lib/libzip.dylib @rpath/libzip.dylib "${DIST_DIR}"/bin/ct
