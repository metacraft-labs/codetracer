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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIN_DIR="${SCRIPT_DIR}/electron"
DEST="${APP_DIR}/electron"

declared="$(node -p "require('${PIN_DIR}/package.json').dependencies.electron")"

echo "==========="
echo "codetracer build: install electron"
echo "  declared pin: ${declared}  (${PIN_DIR#"${SCRIPT_DIR%/*}"/}/package.json)"
echo "==========="

mkdir -p "${DEST}" "${APP_DIR}/bin"

cp "${PIN_DIR}/package.json" "${PIN_DIR}/package-lock.json" "${DEST}/"

# `npm ci` refuses to run when the lock disagrees with the manifest, which is
# the property being bought here: the AppDir cannot be built from a pin that
# was edited without regenerating the lock.
npm ci --omit=dev --prefix "${DEST}"

resolved="$(node -p "require('${DEST}/node_modules/electron/package.json').version")"
echo "electron: declared=${declared} resolved=${resolved}"

if [ "${resolved}" != "${declared}" ]; then
	echo "ERROR: npm resolved electron ${resolved}, but the pin declares ${declared}." >&2
	echo "       ${PIN_DIR}/package-lock.json is not the lock that produced this tree." >&2
	exit 1
fi

# The binary download is a postinstall hook, and a hook that does not run is
# exactly how the 2026-08-30 artefact lost its runtime. Ask for it directly
# when it is missing rather than assuming npm ran it.
if [ ! -f "${DEST}/node_modules/electron/dist/electron" ]; then
	echo "electron: dist/ absent after 'npm ci'; running the binary installer directly"
	(cd "${DEST}/node_modules/electron" && node install.js)
fi

if [ ! -f "${DEST}/node_modules/electron/dist/electron" ]; then
	echo "ERROR: the Electron runtime was not downloaded." >&2
	echo "       ${DEST}/node_modules/electron/dist/electron does not exist, so the" >&2
	echo "       AppImage's bin/electron wrapper would exec a path that is not there" >&2
	echo "       and the GUI would not start. This is the defect that shipped in" >&2
	echo "       CodeTracer-latest-amd64.AppImage built 2026-08-30." >&2
	echo "" >&2
	echo "       Check network access to the Electron release assets, and whether" >&2
	echo "       ELECTRON_SKIP_BINARY_DOWNLOAD or npm's ignore-scripts is set in" >&2
	echo "       this shell. ELECTRON_MIRROR selects an alternate download host." >&2
	exit 1
fi

dist_files="$(find "${DEST}/node_modules/electron/dist" -type f | wc -l | tr -d ' ')"
echo "electron: runtime present, ${dist_files} file(s) under dist/"

cat <<'EOF' >"${APP_DIR}/bin/electron"
#!/usr/bin/env bash

ELECTRON_DIR=${HERE:-..}/electron/node_modules/electron/dist

export LD_LIBRARY_PATH="${HERE}/ruby/lib:${HERE}/lib:/usr/lib/:/usr/lib64/:/usr/lib/x86_64-linux-gnu/:${LD_LIBRARY_PATH}"

"${ELECTRON_DIR}"/electron --no-sandbox "$@"
EOF

chmod +x "${APP_DIR}/bin/electron"
