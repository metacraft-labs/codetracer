#!/usr/bin/env bash
# =============================================================================
# electron-supply-chain.sh — say WHICH ELECTRON SHIPPED, and WHAT ELSE CAME
# WITH IT, from the artefact rather than from a declaration.
#
# ## The two defects this exists to close
#
# Both were measured on `CodeTracer-latest-amd64.AppImage` as published to
# downloads.codetracer.com (built 2026-08-30), not inferred from manifests.
#
#   1. THE FLOATING RUNTIME. `appimage-scripts/install_electron.sh` ran
#      `npm install electron` with NO VERSION and no lockfile, so the Electron
#      bundled into every AppImage was whatever `latest` happened to be on the
#      build machine at build time. The published artefact carried 44.0.0
#      (published 2026-08-25); four days later `latest` was 44.1.1, so two
#      rebuilds of the SAME COMMIT ship two different Chromiums. Nothing in the
#      tree recorded which one a release contained — the only manifest naming a
#      version was one npm generated inside the artefact, saying `^44.0.0`.
#
#      A declared range is not the measurement. `^44.0.0` is compatible with
#      44.0.0 and with 44.9.9; only the RESOLVED version answers "what did the
#      user get". This script reads the resolved version out of the artefact.
#
#   2. THE DEV TREE. `appimage-scripts/setup_node_deps.sh` ran a full `yarn`
#      and then `cp -Lr node_modules` into the AppDir, so the shipped
#      `node_modules` was the DEVELOPMENT tree: 1101 top-level packages,
#      56,062 files, 662.2 MB uncompressed, of which 550 packages, 25,636
#      files and 287.4 MB — 43% of the bytes — were outside the production
#      dependency closure. eslint, prettier, webpack, vite, jsdom, typescript,
#      wdio-electron-service, @electron/packager and their transitive
#      closures, all in users' hands.
#
#      That is not only bulk. 142 open Dependabot alerts stand against
#      `node-packages/yarn.lock`, over 35 distinct packages. 58 of those
#      alerts — 2 critical, 26 high, 21 medium, 9 low — are on 15 packages in
#      the dev-only half: code that had no reason to be on a user's disk at
#      all.
#
# ## Why the prune check is not "grep for devDependencies"
#
# The 28 names that are `devDependencies` and not also runtime dependencies are
# the roots, not the set. What ships is their TRANSITIVE CLOSURE, 550 packages,
# and a check that looked only at the roots would report 28 and call the other
# 522 clean.
#
# So this computes the PRODUCTION closure — `dependencies` of the workspace,
# walked through `yarn.lock` — and reports everything in the artefact that is
# outside it, by name.
#
# It also matters in the other direction, and that is what the measurement
# found first: `js-yaml` was declared under `devDependencies` while
# `src/frontend/lib/misc_lib.nim` does `require("js-yaml")`, so it is loaded by
# the shipped `index.js` bundle. Pruning on the declaration alone would have
# removed a package the product loads at startup. It has since been moved to
# `dependencies`, where it belongs; the guard is written so that the next such
# mis-declaration shows up as a NAMED offender rather than as a crash on a
# user's machine.
#
# ## What this does NOT claim
#
# It does not claim the Electron in the artefact is free of vulnerabilities,
# and it does not claim the app launches. It reports whether the Electron
# RUNTIME (the Chromium/`dist` payload) is present at all, because the
# published AppImage measured above contained the npm `electron` STUB — 481
# files, 13.3 MB of JavaScript, `install.js` and `cli.js` — and no `dist/`, no
# `icudtl.dat`, no `*.pak`, no `libffmpeg`. The wrapper at `bin/electron`
# pointed into that absent directory. That is reported as a value here and
# refused by `install_electron.sh` at build time.
#
# ## The security reading, stated once so it is not restated wrongly
#
# UNTIL 2026-09-03, NO CHROMIUM SHIPPED IN EITHER PUBLISHED DESKTOP ARTEFACT,
# so there was no stale-Chromium exposure from them — the exposure was a
# non-functional GUI. The premise this work started from ("Electron is two
# majors behind") was INVERTED: 44.0.0 was the newest major at the time the
# AppImage was built, and the macOS dmg's `bin/electron` execed a path that had
# never existed on any machine (the Nix node_modules derivation it went through
# holds 880 packages and no `electron`).
#
# THAT CHANGES NOW THAT A REAL RUNTIME SHIPS. Both artefacts carry Electron
# 44.1.1, from this one pin. Staying current stops being cosmetic because of
# three properties that are in the tree and measurable: both BrowserWindows run
# `nodeIntegration: true` and `contextIsolation: false`
# (src/frontend/index/window.nim:67-71, src/frontend/index/install.nim:32-36),
# and the Linux wrapper passes `--no-sandbox`. Together they mean a
# renderer-reachable Chromium bug is a DIRECT Node RCE rather than a sandboxed
# one. Those three are the argument; they are also the cheapest thing to fix if
# anyone wants the version to matter less.
#
# 44.1.1 IS THE RIGHT TARGET, checked rather than assumed. From
# releases.electronjs.org on 2026-09-03: 44.1.1 is the newest STABLE release
# (2026-09-01), and Electron supports the latest three stable majors, so the
# supported set is 44, 43, 42. Major 41 left the window on 2026-08-25.
#
# THE NIX PATH IS STILL OUTSIDE THAT WINDOW, and cannot be brought inside it by
# a version bump alone. `nix/packages/default.nix` (runtimeDeps, which
# `nix build .#codetracer` ships) and `nix/shells/ci-base.nix` (the dev shell)
# both use the bare `pkgs.electron` alias. Measured by `nix eval` over
# `attrNames`:
#
#   this flake's pinned nixpkgs (687f05a9):  electron = 41.3.0, max electron_41
#   nixpkgs-unstable HEAD (f0e996ff, today): electron = 43.4.1, max electron_43
#
# So NIXPKGS DOES NOT PACKAGE ELECTRON 44 AT ALL. A nixpkgs bump gets the Nix
# path to 43.4.1 — inside the support window, still not the version the
# artefacts ship — and that pin is shared org-wide through
# `nix-codetracer-toolchains`, so it is not this repository's to move. Reaching
# 44 from Nix means an overlay carrying our own per-platform binary hashes,
# i.e. a hand-maintained hash table of exactly the kind that already bites this
# repo (node-packages/yarn-project.nix). Neither is free; both are decisions,
# and they are recorded here so the next reader does not re-derive them.
#
# NO CVE IS ENUMERATED HERE, deliberately. A list of identifiers nobody has
# shown to be reachable in this application's threat model reads as evidence
# and is not. The measured claims — the support window, the three absent
# mitigations, and what each path actually resolves to — carry the argument
# without it.
#
# ## Usage
#
#   ci/test/electron-supply-chain.sh                 # static half only
#   ci/test/electron-supply-chain.sh <artefact-dir>  # + artefact half
#
# <artefact-dir> is a staged AppDir (`squashfs-root`), an extracted AppImage,
# or a macOS `CodeTracer.app`. `appimage-scripts/build_appimage.sh` invokes it
# on the AppDir immediately before `appimagetool` packs it, which is the only
# moment the tree exists.
#
# Every check runs; the exit status is decided at the end from all of them, so
# one run tells a reader every answer rather than only the first failure.
# =============================================================================

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$(pwd)"

ARTEFACT="${1:-}"

PIN_MANIFEST="appimage-scripts/electron/package.json"
PIN_LOCK="appimage-scripts/electron/package-lock.json"
NODE_MANIFEST="node-packages/package.json"
NODE_LOCK="node-packages/yarn.lock"

failures=0
checks=0

report() {
	# report <PASSED|FAILED> <name>
	checks=$((checks + 1))
	if [ "$1" = "FAILED" ]; then
		failures=$((failures + 1))
	fi
	printf '%s: %s\n' "$1" "$2"
}

banner() {
	echo
	echo "--- $1"
}

# Indent a captured block for the log. A read loop rather than `sed 's/^/  /'`
# so the lint lane's default-severity shellcheck stays clean (SC2001).
indent() {
	local line
	while IFS= read -r line; do
		printf '  %s\n' "${line}"
	done <<<"$1"
}

# -----------------------------------------------------------------------------
# 1. The declared pin must be an EXACT version.
#
# A range here would put the guard back where it started: `^44.0.0` would let
# the resolved version move without the declaration changing, and the drift
# check below would compare a version against a range and pass on anything.
# -----------------------------------------------------------------------------
banner "declared Electron pin"

declared=""
if [ ! -f "${PIN_MANIFEST}" ]; then
	report FAILED "pin manifest exists (${PIN_MANIFEST})"
else
	declared="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("dependencies", {}).get("electron", ""))
' "${PIN_MANIFEST}")"
	echo "  ${PIN_MANIFEST}: electron = ${declared:-<absent>}"
	if [ -z "${declared}" ]; then
		report FAILED "pin manifest declares electron"
	elif ! printf '%s' "${declared}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'; then
		report FAILED "declared Electron version is EXACT (got '${declared}', which is a range)"
	else
		report PASSED "declared Electron version is EXACT (${declared})"
	fi
fi

# -----------------------------------------------------------------------------
# 2. The lockfile must RESOLVE to that exact version.
#
# This is the half that can be checked without a build: `npm ci` installs what
# the lock says, so the lock is the resolved version for every future build of
# this commit.
# -----------------------------------------------------------------------------
banner "locked Electron resolution"

locked=""
if [ ! -f "${PIN_LOCK}" ]; then
	report FAILED "pin lockfile exists (${PIN_LOCK})"
else
	locked="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("packages", {}).get("node_modules/electron", {}).get("version", ""))
' "${PIN_LOCK}")"
	echo "  ${PIN_LOCK}: node_modules/electron -> ${locked:-<absent>}"
	if [ "${locked}" = "${declared}" ] && [ -n "${locked}" ]; then
		report PASSED "lock resolves electron to the declared pin (${locked})"
	else
		report FAILED "lock resolves electron to '${locked}', declared is '${declared}'"
	fi

	# A pin that exists only on the build machine is not a pin. `.gitignore`
	# carries a blanket `package-lock.json` rule (this project uses yarn), and
	# it silently swallowed this file on the first attempt to commit it: the
	# lock was on disk, every check above passed, and a fresh clone had no pin
	# at all. Existence is not the question; TRACKED is.
	if git -C "${REPO_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
		if git -C "${REPO_ROOT}" ls-files --error-unmatch "${PIN_LOCK}" >/dev/null 2>&1; then
			report PASSED "the pin lockfile is tracked by git"
		else
			report FAILED "${PIN_LOCK} exists but is NOT tracked by git (check .gitignore)"
		fi
	fi
fi

# -----------------------------------------------------------------------------
# 3. No build script may install Electron without naming a version.
#
# The original defect was one line — `npm install electron` — so the guard says
# that line specifically, wherever it reappears.
# -----------------------------------------------------------------------------
banner "no unversioned Electron installs in build scripts"

# The trailing filters drop three things that are not build steps:
#   * comment lines;
#   * diagnostic text — `npm install electron` inside an `echo` that TELLS a
#     developer what to run is prose, and non-nix-build/build_mac_app.sh
#     legitimately contains one;
#   * this guard's own contract suite, which PLANTS the unversioned line as a
#     mutation fixture. Excluded by name rather than by pattern so that a real
#     regression anywhere else in ci/test/ is still caught.
unversioned="$(grep -rnE '(npm[[:space:]]+(install|i|add)|yarn[[:space:]]+add)([[:space:]]+--?[^[:space:]]+)*[[:space:]]+electron([[:space:]]|$)' \
	--include='*.sh' --include='*.ps1' --include='justfile' --include='*.yml' --include='*.yaml' \
	appimage-scripts ci scripts non-nix-build .github justfile 2>/dev/null |
	grep -vE ':[[:space:]]*#' |
	grep -vE '(echo|printf)[[:space:]]' |
	grep -vF 'ci/test/electron-supply-chain-test.sh:' || true)"

if [ -n "${unversioned}" ]; then
	indent "${unversioned}"
	report FAILED "build scripts install electron without a version (see lines above)"
else
	echo "  none"
	report PASSED "no build script installs electron without a version"
fi

# -----------------------------------------------------------------------------
# 4. Artefact half.
# -----------------------------------------------------------------------------
if [ -z "${ARTEFACT}" ]; then
	banner "artefact"
	echo "  no artefact path given; artefact checks SKIPPED"
	echo "  (run '$0 <appdir>' to measure a build; build_appimage.sh does this)"
else
	if [ ! -d "${ARTEFACT}" ]; then
		banner "artefact"
		report FAILED "artefact directory exists (${ARTEFACT})"
	else
		ART="$(cd "${ARTEFACT}" && pwd)"

		# A macOS bundle keeps the payload one level down.
		if [ -d "${ART}/Contents/MacOS" ]; then
			ART="${ART}/Contents/MacOS"
		fi

		banner "artefact Electron runtime: ${ART}"

		# `install_electron.sh` stages the runtime under electron/; the nix and
		# macOS paths put it in node_modules/. Look in both and say which.
		art_electron_pkg=""
		for candidate in \
			"${ART}/electron/node_modules/electron/package.json" \
			"${ART}/node_modules/electron/package.json"; do
			if [ -f "${candidate}" ]; then
				art_electron_pkg="${candidate}"
				break
			fi
		done

		if [ -z "${art_electron_pkg}" ]; then
			echo "  no electron package found under electron/ or node_modules/"
			report FAILED "artefact contains an electron package"
		else
			resolved="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1])).get("version", ""))
' "${art_electron_pkg}")"
			echo "  package:  ${art_electron_pkg#"${ART}"/}"
			echo "  resolved: ${resolved:-<absent>}"
			echo "  declared: ${declared:-<absent>}"
			if [ -n "${resolved}" ] && [ "${resolved}" = "${declared}" ]; then
				report PASSED "artefact Electron is the declared pin (${resolved})"
			else
				report FAILED "artefact Electron is '${resolved}', declared pin is '${declared}'"
			fi

			# Is the RUNTIME there, or only the npm stub? The published
			# 2026-08-30 AppImage had only the stub.
			dist_dir="$(dirname "${art_electron_pkg}")/dist"
			runtime_files=0
			if [ -d "${dist_dir}" ]; then
				runtime_files="$(find "${dist_dir}" -type f 2>/dev/null | wc -l | tr -d ' ')"
			fi
			echo "  dist/:    ${runtime_files} file(s)"
			if [ "${runtime_files}" -gt 0 ]; then
				report PASSED "artefact contains an Electron runtime (${runtime_files} files under dist/)"
			else
				report FAILED "artefact contains the npm electron STUB and no runtime (dist/ is absent or empty)"
			fi
		fi

		# ---------------------------------------------------------------------
		# The dependency set actually present, against the production closure.
		# ---------------------------------------------------------------------
		banner "artefact node_modules against the production closure"

		art_nm=""
		if [ -d "${ART}/node_modules" ]; then
			art_nm="${ART}/node_modules"
		fi

		if [ -z "${art_nm}" ]; then
			echo "  no node_modules in the artefact"
			report FAILED "artefact contains node_modules"
		else
			# A symlink here is its own defect: the macOS .app ships
			# node_modules as an ABSOLUTE symlink into the build machine's
			# /nix/store, which dangles on any machine without that path.
			if [ -L "${art_nm}" ]; then
				echo "  NOTE: node_modules is a symlink -> $(readlink "${art_nm}")"
			fi

			prune_out="$(python3 "${REPO_ROOT}/ci/test/electron-supply-chain-closure.py" \
				"${REPO_ROOT}/${NODE_MANIFEST}" \
				"${REPO_ROOT}/${NODE_LOCK}" \
				"${art_nm}" 2>&1)"
			prune_rc=$?
			indent "${prune_out}"
			if [ "${prune_rc}" -eq 0 ]; then
				report PASSED "artefact node_modules is the production closure"
			else
				report FAILED "artefact node_modules carries packages outside the production closure"
			fi
		fi
	fi
fi

banner "summary"
echo "  checks: ${checks}"
echo "  failed: ${failures}"

if [ "${failures}" -gt 0 ]; then
	echo
	echo "RESULT: FAILED (${failures}/${checks})"
	echo "SCOPE: the Electron version bundled into the desktop artefact, and the"
	echo "       dependency set shipped beside it. This is NOT a vulnerability"
	echo "       scan and NOT a claim that the application launches."
	exit 1
fi

echo
echo "RESULT: PASSED (${checks}/${checks})"
echo "SCOPE: the Electron version bundled into the desktop artefact, and the"
echo "       dependency set shipped beside it. This is NOT a vulnerability"
echo "       scan and NOT a claim that the application launches."
