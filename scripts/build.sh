#!/usr/bin/env bash
set -euo pipefail

# CodeTracer dev build — sets up everything required for hot module
# reloading and watches sources for incremental rebuilds.
#
# Background processes started here:
#   * tup monitor -a   — incremental rebuilds (Nim → ui.js, Stylus → .css,
#                        TypeScript, Rust, etc.)
#   * webpack --watch  — frontend_bundle.js (third-party bundle)
#   * livereload       — file-tree watcher + LiveReload-protocol
#                        WebSocket server (port 35729). Watches
#                        src/build-debug/ — every file the ct binary's
#                        renderer can load (built outputs, vendored
#                        third-party JS/CSS, anything else under that
#                        tree) lives there. One daemon broadcasts
#                        reload signals to every connected ct window.
#
# The hot-module-reload mechanism inside the running ct binary:
#   * Compile time: Tup's !nim_js rule passes -d:ctHmr -d:isonimHmr,
#     so {.uiComponent.} pragmas register slots and mountUiHot
#     boundaries listen for swaps. See src/Tuprules.tup.
#   * Renderer: connects as a WebSocket client to the livereload
#     daemon on ws://localhost:35729/livereload. On a `reload`
#     message it routes by file extension: .css → swap the
#     matching <link>'s href; anything else → re-evaluate the JS
#     bundle (inline-script injection using Node fs.readFileSync,
#     which sidesteps file:// + cache-bust-query unreliability).
#   * Runtime opt-out: CT_HMR=0 (or false / off) skips installing
#     the transport.
#
# After `just build` returns:
#   src/build-debug/bin/ct       # HMR active, connects to daemon
#   CT_HMR=0 src/build-debug/bin/ct   # HMR off, same binary
#
# Edit anything under src/build-debug/ — a Tup-emitted ui.js, a
# Stylus-rebuilt .css, or a hand-edited third-party asset. The
# daemon detects the change and broadcasts a reload signal to every
# connected ct window simultaneously.

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

# LiveReload daemon — one process watches the entire build-debug
# tree and fans out reload signals over WebSocket to every ct
# window. `--wait 200` delays the reload broadcast by 200ms after
# a file change, which smooths Tup's multi-pass rebuilds (it can
# write the file twice in quick succession). `--port` pins the
# WS endpoint at the canonical LiveReload port.
node_modules/.bin/livereload \
	src/build-debug \
	--port 35729 \
	--wait 200 \
	--usepolling false &

cat <<'HMR_BANNER'

==============================================================
  CodeTracer dev build complete — HMR-enabled binary ready.

  Run with:  src/build-debug/bin/ct

  HMR is on by default. Edits to anything under
  src/build-debug/ (Tup outputs, Stylus-rebuilt CSS, vendored
  third-party JS/CSS, …) trigger in-place reloads in every
  connected ct window. To disable for a launch:
  CT_HMR=0 src/build-debug/bin/ct.
==============================================================
HMR_BANNER
