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

# The replay backend, built into the SAME compiler-bound Cargo target base as
# the tup build of this checkout (ci/lib/tup-cargo-target.sh;
# codetracer-pm spec/Testing/UI-Cargo-Output-Ownership.md). It used to build
# into the crate's own `src/db-backend/target`, which nothing binds to a
# compiler: a toolchain change left the previous compiler's artefacts beside
# the new one's, the E0514 case the shared target produced. The helper
# refuses a base it cannot prove is this checkout's and this compiler's, and
# `--reap` (this is a build) removes this checkout's older-compiler bases.
# `cargo build` keeps its flags; only the target directory is bound.
#
# `src/db-backend/target/debug/replay-server`, which several harnesses name as
# REPLAY_SERVER_BIN, is unaffected: it is what a plain `cargo build` in
# src/db-backend produces, and this script no longer writes it as a side
# effect.
checkout="$(pwd -P)"
cargo_base="$(bash ci/lib/tup-cargo-target.sh --reap "${checkout}" | sed -n 1p)"
if [ -z "${cargo_base}" ]; then
	echo "build_for_extension.sh: no Cargo target base this checkout owns (see above)." >&2
	exit 1
fi
(cd ./src/db-backend && cargo build --target-dir "${cargo_base}/db_backend_target")
cp "${cargo_base}/db_backend_target/debug/replay-server" "$2"
# The emulator library goes beside it: the binary's only run-time search path
# is its own directory ($ORIGIN / @loader_path, src/db-backend/build.rs).
case "$(uname -s)" in
Darwin) emulator_library="libmcr_emulator.dylib" ;;
MINGW* | MSYS* | CYGWIN*) emulator_library="mcr_emulator.dll" ;;
*) emulator_library="libmcr_emulator.so" ;;
esac
cp "${cargo_base}/db_backend_target/debug/${emulator_library}" "$(dirname "$2")/${emulator_library}"
