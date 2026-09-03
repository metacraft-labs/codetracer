#!/usr/bin/env bash
#
# stage-electron-runtime.sh — put THE pinned Electron runtime at a path, on
# every platform, from one lockfile.
#
# WHY THIS IS ITS OWN SCRIPT
#
# `appimage-scripts/install_electron.sh` fixed the Linux half of a defect whose
# other half is still shipping: the AppImage now installs Electron 44.1.1 from a
# committed `npm` lockfile and refuses to build without the runtime. The macOS
# bundle installs NOTHING. Measured on the published artefact, not argued from
# the source:
#
#   * `CodeTracer-latest-arm64.dmg` (downloaded 2026-09-03, built 2026-08-30)
#     stages `node_modules` as a symlink into the build machine's Nix store.
#   * The store path it names — which exists on the builder, which is why this
#     was never noticed — holds 880 top-level entries: `electron-debug`,
#     `electron-rebuild`, `wdio-electron-service`, and NO `electron`.
#   * `node-packages/package.json` and `node-packages/yarn.lock` declare no
#     `electron` at all, so no yarn install anywhere could have produced one.
#   * `Contents/MacOS/bin/electron` (a copy of `resources/electron`) execs
#     `../node_modules/electron/dist/Electron.app/Contents/MacOS/Electron`.
#
# That path has never existed on any machine. The macOS GUI cannot start, for
# the same reason the 2026-08-30 AppImage's could not, by a different route.
#
# So the pin has one reader per platform and they must be the SAME pin.
# `appimage-scripts/electron/package.json` is it; this script is the one thing
# that turns it into bytes on disk, and `install_electron.sh` now calls it
# rather than carrying a second copy of the same `npm ci`.
#
# WHY THE VERSION MATTERS MORE THAN IT USUALLY WOULD
#
# Both of CodeTracer's `BrowserWindow`s are constructed with
# `nodeIntegration: true` and `contextIsolation: false`
# (src/frontend/index/window.nim:67-71, src/frontend/index/install.nim:32-36),
# and the Linux wrapper adds `--no-sandbox`. Those three together mean a
# renderer-reachable Chromium bug is a DIRECT Node RCE rather than a sandboxed
# one. No CVE is enumerated here, deliberately — a list of identifiers nobody
# has shown to be reachable in this application reads as evidence and is not.
# The argument is the configuration, which is measurable and is in the tree.
#
# Usage:
#   scripts/stage-electron-runtime.sh <dest-electron-package-dir>
#
# e.g.  scripts/stage-electron-runtime.sh "$MACOS/node_modules/electron"
#       scripts/stage-electron-runtime.sh "$APP_DIR/electron/node_modules/electron"
#
# The destination is the `electron` PACKAGE directory, not a node_modules root:
# `npm ci` runs in a scratch tree and only the finished package is moved into
# place, so a destination that already holds a staged dependency closure (the
# macOS bundle does) is never handed to npm to manage.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN_DIR="${REPO_ROOT}/appimage-scripts/electron"

DEST="${1:-}"
if [ -z "${DEST}" ]; then
	echo "usage: $0 <dest-electron-package-dir>" >&2
	exit 2
fi

declared="$(node -p "require('${PIN_DIR}/package.json').dependencies.electron")"

echo "==========="
echo "codetracer build: stage the Electron runtime"
echo "  pin        : ${PIN_DIR#"${REPO_ROOT}"/}/package.json"
echo "  declared   : ${declared}"
echo "  destination: ${DEST}"
echo "==========="

scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT

cp "${PIN_DIR}/package.json" "${PIN_DIR}/package-lock.json" "${scratch}/"

# `npm ci` refuses to run when the lock disagrees with the manifest, which is
# the property being bought: the bundle cannot be built from a pin that was
# edited without regenerating the lock.
npm ci --omit=dev --prefix "${scratch}"

pkg="${scratch}/node_modules/electron"
resolved="$(node -p "require('${pkg}/package.json').version")"
echo "electron: declared=${declared} resolved=${resolved}"

if [ "${resolved}" != "${declared}" ]; then
	echo "ERROR: npm resolved electron ${resolved}, but the pin declares ${declared}." >&2
	echo "       ${PIN_DIR}/package-lock.json is not the lock that produced this tree." >&2
	exit 1
fi

# The binary download is a postinstall hook, and Electron REMOVED that hook in
# 42.0.0 — which is exactly how the 2026-08-30 AppImage lost its runtime while
# every build stayed green. Ask for it directly rather than assuming npm ran it.
case "$(uname -s)" in
Darwin) runtime="${pkg}/dist/Electron.app/Contents/MacOS/Electron" ;;
MINGW* | MSYS* | CYGWIN* | Windows_NT) runtime="${pkg}/dist/electron.exe" ;;
*) runtime="${pkg}/dist/electron" ;;
esac

if [ ! -e "${runtime}" ]; then
	echo "electron: ${runtime#"${pkg}"/} absent after 'npm ci'; running the binary installer directly"
	(cd "${pkg}" && node install.js)
fi

if [ ! -e "${runtime}" ]; then
	echo "ERROR: the Electron runtime was not downloaded." >&2
	echo "       ${runtime} does not exist, so the bundle's bin/electron wrapper" >&2
	echo "       would exec a path that is not there and the GUI would not start." >&2
	echo "       This is the defect that shipped in CodeTracer-latest-amd64.AppImage" >&2
	echo "       built 2026-08-30, and that is still shipping in the macOS dmg." >&2
	echo "" >&2
	echo "       Check network access to the Electron release assets, and whether" >&2
	echo "       ELECTRON_SKIP_BINARY_DOWNLOAD or npm's ignore-scripts is set in" >&2
	echo "       this shell. ELECTRON_MIRROR selects an alternate download host." >&2
	exit 1
fi

dist_files="$(find "${pkg}/dist" -type f | wc -l | tr -d ' ')"
dist_bytes="$(find "${pkg}/dist" -type f -print0 | xargs -0 wc -c 2>/dev/null | tail -n1 | awk '{print $1}')"
echo "electron: runtime present, ${dist_files} file(s), ${dist_bytes:-0} bytes under dist/"

mkdir -p "$(dirname "${DEST}")"
rm -rf "${DEST}"
mv "${pkg}" "${DEST}"

echo "electron: staged ${resolved} at ${DEST}"
