#!/usr/bin/env bash
set -euo pipefail

# We have to make the dist directory here, because it's missing on a fresh check out
# It will be created by the webpack command below, but we have an a chicken and egg
# problem because the Tupfiles refer to it.
mkdir -p src/public/dist

cd src
"${TUP:-tup}" build-debug
cd ..

# Build frontend_bundle.js in the dist folder
node_modules/.bin/webpack --progress

# We need to execute another tup run because webpack may have created some new files
# that tup will discover
cd src
"${TUP:-tup}" build-debug
