#!/usr/bin/env bash
#
# install_electron.sh — stage the Electron runtime into the AppDir at a version
# this repository chose, on a commit a reader can point at.
#
# WHAT THIS REPLACED
#
#   npm install electron --prefix "${APP_DIR}/electron"
#
# No version, no lockfile. That line put whatever npm's `latest` dist-tag
# pointed at on the build machine, at the moment of the build, into every
# AppImage published to downloads.codetracer.com. Measured on the artefact
# rather than argued from the source: `CodeTracer-latest-amd64.AppImage` built
# 2026-08-30 carried Electron 44.0.0 (published 2026-08-25); by 2026-09-03
# `latest` was 44.1.1, so the same commit rebuilt would have shipped a
# different Chromium with nothing in git recording either. The only manifest in
# the tree naming a version was one npm generated INSIDE the artefact, and it
# said `^44.0.0` — a range, which does not answer the question.
#
# The pin lives in ./electron/package.json and ./electron/package-lock.json.
# Two things follow from it being a real npm lockfile rather than a bare
# version string:
#
#   * `npm ci` installs exactly what the lock resolves, for the whole tree, not
#     just for `electron` itself.
#   * GitHub's dependency graph parses committed `package-lock.json` files, so
#     Electron is now a package the repository's Dependabot alerts can see. It
#     was invisible before — `electron` appears in no manifest and in no
#     lockfile anywhere in this repo, so of the 185 open alerts at the time of
#     writing, ZERO were about the one dependency that ships a browser engine.
#
# THE RUNTIME CHECK AT THE BOTTOM
#
# The published 2026-08-30 AppImage contained the npm `electron` STUB — 481
# files, 13.3 MB, `cli.js` + `install.js` + TypeScript definitions — and no
# `dist/` at all: no Chromium, no `icudtl.dat`, no `*.pak`, no `libffmpeg`.
# `${APP_DIR}/bin/electron`, written below, execs into that absent directory,
# so the GUI in that artefact cannot start. CI never noticed because the
# AppImage smoke tests (scripts/test-appimage-cross-distro.sh) run `--version`
# and a headless record->replay, neither of which launches Electron.
#
# So this script now (a) invokes the binary installer explicitly, the same
# workaround non-nix-build/setup_node_deps.sh already carries for the case
# where the postinstall hook does not run, and (b) REFUSES to produce an AppDir
# without a runtime. A red build is the cheaper failure.

# THE npm ci + VERIFY HALF NOW LIVES IN scripts/stage-electron-runtime.sh.
#
# Not a tidy-up: the macOS dmg ships no Electron AT ALL (its `node_modules` is a
# store symlink to a tree with 880 packages and no `electron`), and the fix for
# that has to install the SAME pin this file installs. Two copies of "npm ci the
# pin, then check the runtime landed" is how the two desktop artefacts drift
# apart again — this time silently, because both would be green. One
# implementation, two callers, one lockfile.
#
# What stays here is the part that is genuinely AppImage-specific: the
# destination layout (`${APP_DIR}/electron/node_modules/electron`, which
# `ci/test/electron-supply-chain.sh` looks for by name) and the Linux launcher
# below, with its LD_LIBRARY_PATH and its `--no-sandbox`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PIN_DIR="${SCRIPT_DIR}/electron"
DEST="${APP_DIR}/electron"

mkdir -p "${DEST}" "${APP_DIR}/bin"

# Kept beside the package so the AppDir carries the pin it was built from, not
# only the package's own generated manifest.
cp "${PIN_DIR}/package.json" "${PIN_DIR}/package-lock.json" "${DEST}/"

bash "${REPO_ROOT}/scripts/stage-electron-runtime.sh" "${DEST}/node_modules/electron"

cat <<'EOF' >"${APP_DIR}/bin/electron"
#!/usr/bin/env bash

ELECTRON_DIR=${HERE:-..}/electron/node_modules/electron/dist

export LD_LIBRARY_PATH="${HERE}/ruby/lib:${HERE}/lib:/usr/lib/:/usr/lib64/:/usr/lib/x86_64-linux-gnu/:${LD_LIBRARY_PATH}"

"${ELECTRON_DIR}"/electron --no-sandbox "$@"
EOF

chmod +x "${APP_DIR}/bin/electron"
