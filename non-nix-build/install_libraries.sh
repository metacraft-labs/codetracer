#!/usr/bin/env bash

LIB_DIR="${GIT_ROOT}/non-nix-build/CodeTracer.app/Contents/Frameworks"

mkdir -p "${LIB_DIR}"

echo "DIST DIR ${DIST_DIR}" 

brew install libzip

HOMEBREW_LIB_DIR="/System/Volumes/Data/opt/homebrew/lib"

cp "${HOMEBREW_LIB_DIR}/libzip.dylib" "${LIB_DIR}"
