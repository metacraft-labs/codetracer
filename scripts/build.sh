#!/usr/bin/env bash
set -euo pipefail

# (alexander) we still need to run direnv reload here, so
# think if we ned this here
# Make sure all submodules are up to date
# git submodule sync
# git submodule update --init --recursive

# Build CodeTracer once, so we can run the user-setup command
# TODO: alexander think more about this command
# cd src
# tup build-debug
# build-debug/codetracer user-setup

# Start building continuously
cd src
"${TUP:-tup}" build-debug
"${TUP:-tup}" monitor -a
cd ../

# start webpack
node_modules/.bin/webpack --watch --progress & # building frontend_bundle.js

# Start the JavaScript and CSS hot-reloading server
# TODO browser-sync is currently missing
# node build-debug/browsersync_serv.js &
