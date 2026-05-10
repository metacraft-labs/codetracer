#!/usr/bin/env bash
set -euo pipefail

# CodeTracer dev build — sets up everything required for hot module
# reloading and watches sources for incremental rebuilds.
#
# Background processes started here:
#   * tup monitor -a   — incremental rebuilds (Nim → ui.js, Stylus → .css,
#                        TypeScript, Rust, etc.)
#   * webpack --watch  — frontend_bundle.js (third-party bundle)
#
# The hot-module-reload mechanism itself lives inside the running ct
# binary's renderer:
#   * Compile time: Tup's !nim_js rule passes -d:ctHmr -d:isonimHmr,
#     so {.uiComponent.} pragmas register slots and mountUiHot
#     boundaries listen for swaps. See src/Tuprules.tup.
#   * Runtime gate: the env var CT_HMR=1. With this set, the renderer
#     installs Node fs.watch transports (one for ui.js, one per
#     codetracer-managed stylesheet) at startup. Without it, the dev
#     binary runs as if HMR were absent.
#
# To use HMR after `just build` returns:
#   CT_HMR=1 src/build-debug/bin/ct
#
# Edit a panel's source or .styl file. tup monitor rebuilds the
# affected output. fs.watch in the renderer fires; the JS bundle is
# reloaded via cache-busted <script> tag (and {.uiComponent.} slot
# rewrites cascade through mountUiHot effects), and CSS link tags get
# their href swapped to a cache-busted URL.

# Initial build, then start the file-watching monitor that drives all
# incremental rebuilds. `tup monitor -a` daemonises itself.
cd src
"${TUP:-tup}" build-debug
"${TUP:-tup}" monitor -a
cd ../

# Webpack continues to bundle the third-party JS deps in watch mode;
# this is unrelated to the Nim renderer's HMR but is required for
# the frontend_bundle.js asset that the renderer also loads.
node_modules/.bin/webpack --watch --progress &

cat <<'HMR_BANNER'

==============================================================
  CodeTracer dev build complete — HMR-enabled binary ready.

  Run with:  CT_HMR=1 src/build-debug/bin/ct

  Edits to .nim panel sources and .styl theme files trigger
  in-place reloads in the running ct window. Without CT_HMR=1
  the binary behaves like a non-HMR build (zero runtime cost).
==============================================================
HMR_BANNER
