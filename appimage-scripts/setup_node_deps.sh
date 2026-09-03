#!/usr/bin/env bash

# depends on env `$ROOT_PATH` and `$CODETRACER_PREFIX`
# and node

# WHAT CHANGED HERE, AND WHY THE ORDER MATTERS
#
# This script used to run `yarn` and then copy `node_modules` into the AppDir
# verbatim, which meant the DEVELOPMENT tree shipped to users. Measured on
# CodeTracer-latest-amd64.AppImage as published (built 2026-08-30), not
# inferred from package.json: the artefact's node_modules held 1101 top-level
# packages, 56,062 files and 662.2 MB uncompressed, of which 550 packages,
# 25,636 files and 287.4 MB — 43% of the bytes — were outside the production
# dependency closure. eslint, prettier, typescript, webpack, vite, jsdom,
# wdio-electron-service, @electron/packager and their transitive closures, on
# every user's disk.
#
# It is not only bulk. 142 open Dependabot alerts stand against
# node-packages/yarn.lock, over 35 distinct packages; 58 of them — 2 critical,
# 26 high, 21 medium, 9 low — are on 15 packages in the dev-only half. Code
# with no runtime purpose, contributing exposure anyway.
#
# The prune is `yarn workspaces focus --production --all`, and it has to happen
# BETWEEN the webpack run and the copy:
#
#   yarn            full tree — webpack, stylus and the loaders are devDependencies
#   webpack         builds src/public/dist/frontend_bundle.js, needs them
#   focus --prod    drops them again
#   cp              stages what is left
#
# The old order copied BEFORE building, which is why the copy could not simply
# be moved.
#
# ONE THING THE PRUNE ALMOST BROKE, and the rule that follows from it.
#
# `js-yaml` was declared under `devDependencies` while
# `src/frontend/lib/misc_lib.nim` does `require("js-yaml")` — so it is loaded
# by the shipped `index.js` bundle at startup. Pruning on the declaration alone
# would have DELETED A RUNTIME DEPENDENCY out of the artefact, and the failure
# would have surfaced on a user's machine, not here.
#
# THE RULE, because the next person will not think to do this:
#
#   THE PRODUCTION CLOSURE MUST BE CHECKED AGAINST THE `require()` LITERALS IN
#   THE BUILT BUNDLES, NOT AGAINST package.json. The dependency FIELD a package
#   sits in is a claim; what the bundle loads is the fact, and this repository
#   had one that disagreed.
#
# How it was found, so it can be repeated: extract every `require("<literal>")`
# from the shipped bundles (index.js, server_index.js, ui.js), reduce each to a
# package name, and diff that set against the production closure. There were 17
# distinct names. Sixteen were declared runtime dependencies, Node builtins, or
# `electron` itself (which the Electron main process resolves, not
# node_modules). The seventeenth was js-yaml, and it is now in `dependencies`,
# where it belongs.
#
# ci/test/electron-supply-chain.sh names any future offender BY NAME rather
# than letting it reach a user as a startup crash — but it compares the
# artefact against the closure, so a package that is mis-declared AND absent
# from the bundles' require() literals is still only caught by redoing the diff
# above.

set -e

echo "==========="
echo "codetracer build: setup node deps"
echo "==========="

# setup node deps
#   node modules and webpack/frontend_bundle.js
pushd "${ROOT_PATH}/node-packages"

echo y | npx yarn

popd

pushd "${ROOT_PATH}/"

node-packages/node_modules/.bin/webpack

popd

# Drop the build-only half of the tree before it is staged. `--all` is required
# because `workspaces focus` addresses workspaces, and this project is a single
# root workspace.
pushd "${ROOT_PATH}/node-packages"

before="$(find node_modules -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
echo y | npx yarn workspaces focus --production --all
after="$(find node_modules -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
echo "node_modules pruned to production: ${before} -> ${after} top-level entries"

popd

cp -Lr "${ROOT_PATH}/node-packages/node_modules" "${APP_DIR}/"

rm -rf "${ROOT_PATH}/node-packages/node_modules"

# => now we have node_modules, and $ROOT_PATH/src/public/dist/frontend_bundle.js
# <=> $CODETRACER_PREFIX/public/dist/frontend_bundle.js

echo "==========="
