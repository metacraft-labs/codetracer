#!/usr/bin/env bash

# build_for_extension.sh <media_dir> <replay_server_path>
#
# The CodeTracer VS Code extension's Nim and Rust artefacts, built from this
# checkout (Shared-DOM-Front-Ends D5):
#
#   <media_dir>/vscode_panel.js  the panel webviews' bundle: one panel over a
#                                mirror of the host's session
#   <media_dir>/vscode_host.js   the extension host's sessions (CommonJS)
#   <media_dir>/ct_vscode.js     the extension host's middleware (commands
#                                that ask the replay directly)
#   <replay_server_path>         the replay backend (`replay-server`)
#
# Nothing else: the panels do not load the renderer, so the desktop build
# (`just build-once`) is not part of the extension's. The extension compiles
# the theme from `src/frontend/styles/` itself.
set -e

media_dir="$1"
mkdir -p "${media_dir}"

just build-vscode-panel "${media_dir}/vscode_panel.js"
just build-vscode-host "${media_dir}/vscode_host.js"
just build-vscode-middleware "${media_dir}/ct_vscode.js"

cd ./src/db-backend
cargo build
cd ../..
cp ./src/db-backend/target/debug/replay-server "$2"
