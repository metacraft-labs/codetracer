#!/usr/bin/env bash
# Copy the built WASM module to the app directory for nginx serving.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_SRC="$REPO_ROOT/src/db-backend/wasm-testing/pkg"
PKG_DST="$SCRIPT_DIR/app/pkg"

# The repository's one spelling of "this artefact must be current with respect
# to its sources"; see the library's own header for why a deploy script shares
# a file with the doc captures.
# Read by the library; every diagnostic is prefixed with it.
# shellcheck disable=SC2034
CTDR_LABEL="deploy-wasm"
# shellcheck source=scripts/docs/deep-review-capture-lib.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/docs/deep-review-capture-lib.sh"

# THE MESSAGE NAMED THE CONDITION THE GUARD COULD NOT DETECT.
#
# `[ ! -d "$PKG_SRC" ]` -> "Run: cd src/db-backend && bash build_wasm.sh".
# A directory is there once the wasm has been built once, and nothing ever
# removes it, so from the second build onwards this test is satisfied by
# history rather than by the module on disk. `build_wasm.sh` takes minutes and
# needs an llvm-ar and a wasm sysroot, which is exactly the kind of step people
# skip when a directory is already sitting there.
#
# What happens next is a DEPLOY: the two files are copied into the directory
# nginx serves, so the browser-replay app then runs an out-of-date db-backend
# against current traces, and nothing in the page says which module it got. The
# failure mode is a replay bug that reproduces only on the deployment.
#
# Sources are the db-backend crate the module is compiled from, from
# `git ls-files` so that `target/`, `wasm-sysroot/` and `pkg/` itself are not in
# the list. The whole repository would be the wrong list here: a README edit is
# not a reason to spend minutes rebuilding a wasm module, and a guard that asks
# for that is a guard that gets commented out.
if [ ! -d "$PKG_SRC" ]; then
	echo "ERROR: WASM package not found at $PKG_SRC"
	echo "Run: cd src/db-backend && bash build_wasm.sh"
	exit 1
fi

WASM_SOURCES=(
	'src/db-backend/src/*.rs'
	'src/db-backend/build.rs'
	'src/db-backend/Cargo.toml'
	'src/db-backend/Cargo.lock'
	'src/db-backend/build_wasm.sh'
)

# BOTH halves are checked, not just one. `wasm-bindgen` writes the glue and the
# module separately, and a run that died between them leaves a `pkg/` whose
# `.js` is current and whose `.wasm` is a build old — the deploy would then ship
# a loader calling into exports the module does not have.
for artefact in db_backend.js db_backend_bg.wasm; do
	if [ ! -f "$PKG_SRC/$artefact" ]; then
		echo "ERROR: $PKG_SRC/$artefact is missing from the WASM package"
		echo "Run: cd src/db-backend && bash build_wasm.sh"
		exit 1
	fi
	ctdr_require_tracked_sources_not_newer "WASM build" "$artefact" \
		"$PKG_SRC/$artefact" \
		"This script deploys that file into the directory nginx serves, so browser-replay would run an out-of-date db-backend and nothing in the page would say so. Rebuild with: cd src/db-backend && bash build_wasm.sh" \
		"$REPO_ROOT" "${WASM_SOURCES[@]}"
done

mkdir -p "$PKG_DST"
cp "$PKG_SRC/db_backend.js" "$PKG_DST/"
cp "$PKG_SRC/db_backend_bg.wasm" "$PKG_DST/"
echo "Deployed WASM to $PKG_DST"
ls -la "$PKG_DST"
