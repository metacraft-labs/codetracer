#!/usr/bin/env bash
# =============================================================================
# desktop-bundle-self-contained.sh — assert that NOTHING inside a shipped
# desktop bundle resolves outside it.
#
# ## The defect this exists to close, measured on the published artefact
#
# `CodeTracer-latest-arm64.dmg` was downloaded from downloads.codetracer.com on
# 2026-09-03 (63,356,720 bytes, built 2026-08-30), mounted with `hdiutil`, and
# every symlink in the `.app` was enumerated. There are eight. SEVEN OF THEM DO
# NOT RESOLVE ON A USER'S MAC:
#
#   Contents/MacOS/node_modules
#     -> /nix/store/dfpgz4fsfayxmin7vr285rha5siz43ar-node-modules-derivation/bin/node_modules
#   Contents/MacOS/public/third_party/@exuanbo   -> ../../../../node_modules/@exuanbo
#   Contents/MacOS/public/third_party/mousetrap  -> ../../../../node_modules/mousetrap
#   Contents/MacOS/public/third_party/vex-js     -> ../../../../node_modules/vex-js
#   Contents/MacOS/public/third_party/xterm      -> ../../../../node_modules/xterm
#   Contents/MacOS/public/third_party/golden-layout/dist
#                                                -> ../../../../../node_modules/golden-layout/dist
#   Contents/MacOS/public/third_party/monaco-editor/min
#                                                -> ../../../../../node_modules/monaco-editor/min
#
# The first is an ABSOLUTE PATH INTO THE BUILD MACHINE'S NIX STORE. `repro.nim`
# staged it with `cp -a node_modules`, and in a Nix dev shell `node_modules` is
# itself a store symlink (`nix/shells/ci-base.nix` and `scripts/build-once.sh`
# both create it that way), so `cp -a` copied the LINK. The whole dependency
# tree — and with it monaco-editor, xterm, golden-layout, the entire renderer's
# third-party assets — is absent from the artefact users download. The `.app`
# holds 566 regular files.
#
# The other six escape the bundle no matter whose machine it is: their
# `../../../..` counts levels from the BUILD TREE to the repository root, and
# the same count from `Contents/MacOS/public/third_party` lands on
# `CodeTracer.app` itself, which has no `node_modules`.
#
# ## Why CI could not see it
#
# `dmg-build` and `dmg-lib-check` (.github/workflows/codetracer.yml) both run on
# `aarch64-darwin` — the SAME self-hosted host. The store path in that symlink
# exists there. `dmg-lib-check`'s `ct --version` runs a native binary that never
# touches node_modules, and the record->replay smoke is `continue-on-error`. So
# a bundle that cannot resolve a single JavaScript dependency on a user's Mac
# passed every release check. A guard for this has to assert about PATHS INSIDE
# THE ARTEFACT, not about whether something ran on the builder.
#
# ## What this checks
#
#   static half (no arguments)
#     - the staging scripts exist and are tracked
#     - no desktop staging step copies `node_modules` without dereferencing it
#
#   artefact half (<bundle-dir>)
#     - EVERY symlink resolves to a path inside the bundle
#     - no symlink target mentions /nix/store
#     - the bundle's `node_modules` is a real directory, not a link
#     - the `bin/electron` launcher's exec target exists inside the bundle
#     - the bundle's file count and byte size, as VALUES
#
# ## What this does NOT claim
#
# It does not claim the application launches, and it says nothing about which
# Electron version is bundled or what else ships beside it —
# `ci/test/electron-supply-chain.sh` owns that question and takes the same
# `.app` directory as its argument. This one answers exactly: "can every path in
# this bundle be resolved by someone who has only this bundle?"
#
# ## Usage
#
#   ci/test/desktop-bundle-self-contained.sh                  # static half only
#   ci/test/desktop-bundle-self-contained.sh <bundle-dir>     # + artefact half
#
# <bundle-dir> is a macOS `CodeTracer.app`, a staged Windows `CodeTracer-win`
# tree, or an extracted AppDir. Every check runs; the exit status is decided at
# the end from all of them, so one run tells a reader every answer rather than
# only the first failure.
# =============================================================================

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT="$(pwd)"

BUNDLE="${1:-}"

STAGER="scripts/stage-desktop-node-modules.py"

failures=0
checks=0

report() {
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

indent() {
	local line
	while IFS= read -r line; do
		printf '  %s\n' "${line}"
	done <<<"$1"
}

# -----------------------------------------------------------------------------
# 1. The stager exists and is tracked.
#
# Tracked, not merely present: `ci/test/electron-supply-chain.sh` learned this
# the expensive way when `.gitignore` swallowed the Electron lockfile and every
# check still passed against a file only the author's disk had.
# -----------------------------------------------------------------------------
banner "the staging script"

if [ ! -f "${STAGER}" ]; then
	report FAILED "${STAGER} exists"
elif git -C "${REPO_ROOT}" rev-parse --git-dir >/dev/null 2>&1 &&
	! git -C "${REPO_ROOT}" ls-files --error-unmatch "${STAGER}" >/dev/null 2>&1; then
	report FAILED "${STAGER} exists but is NOT tracked by git"
else
	report PASSED "${STAGER} exists and is tracked"
fi

# -----------------------------------------------------------------------------
# 2. No desktop staging step may copy node_modules WITHOUT dereferencing.
#
# The two lines this names are the two that produced the defect above:
#
#   repro.nim  "cp -a node_modules \"$MACOS/node_modules\""
#   repro.nim  fs.cpSync('node_modules', ..., {recursive:true,dereference:false})
#
# `cp -a` implies `-d` (preserve links), so it copies a symlinked node_modules
# as a symlink; node's `dereference:false` does the same on the Windows path.
# Both are spelled out by pattern rather than by line number so a reappearance
# anywhere in the recipe is caught.
# -----------------------------------------------------------------------------
banner "no link-preserving node_modules copies in the desktop staging"

# Scoped to lines that mention node_modules. `dereference:false` is CORRECT for
# the `src/public/dist` mirror at repro.nim:945 — that tree has no symlinks and
# a blanket ban would have flagged it, which is how a guard trains people to
# ignore it.
# Nim comments are dropped: the fix for this defect DOCUMENTS the line it
# replaced ("`cp -a node_modules` used to sit here"), and a guard that cannot
# tell prose from code fails on its own explanation. Same exclusion
# `ci/test/electron-supply-chain.sh` makes for `echo`'d diagnostics.
offenders="$(grep -n 'node_modules' repro.nim 2>/dev/null |
	grep -vE '^[0-9]+:[[:space:]]*#' |
	grep -E '(cp[[:space:]]+-[a-zA-Z]*a[a-zA-Z]*[[:space:]]+node_modules)|(dereference[[:space:]]*:[[:space:]]*false)' || true)"

if [ -n "${offenders}" ]; then
	indent "${offenders}"
	report FAILED "repro.nim stages node_modules without dereferencing (see lines above)"
else
	echo "  none"
	report PASSED "repro.nim stages node_modules with the contents, not the link"
fi

# -----------------------------------------------------------------------------
# 3. Artefact half.
# -----------------------------------------------------------------------------
if [ -z "${BUNDLE}" ]; then
	banner "artefact"
	echo "  no bundle path given; artefact checks SKIPPED"
	echo "  (run '$0 <bundle-dir>' to measure a build)"
else
	if [ ! -d "${BUNDLE}" ]; then
		banner "artefact"
		report FAILED "bundle directory exists (${BUNDLE})"
	else
		ROOT="$(cd "${BUNDLE}" && pwd -P)"

		banner "symlinks in ${ROOT}"

		# One python pass rather than a `find -type l` loop, because the
		# question is not "is this link broken here" but "does this link
		# resolve WITHIN THE BUNDLE" — and on the build machine a
		# /nix/store link is not broken, which is the entire reason this
		# defect shipped. Resolution is done textually against the bundle
		# root so the answer does not depend on what the running host
		# happens to have.
		link_report="$(python3 - "${ROOT}" <<'PY'
import os
import sys

root = os.path.realpath(sys.argv[1])
total = 0
escaping = []
dangling = []
store = []

for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
    for name in list(dirnames) + list(filenames):
        path = os.path.join(dirpath, name)
        if not os.path.islink(path):
            continue
        total += 1
        target = os.readlink(path)
        shown = os.path.relpath(path, root)
        if "/nix/store" in target:
            store.append((shown, target))
        resolved = os.path.normpath(
            target if os.path.isabs(target)
            else os.path.join(os.path.dirname(path), target)
        )
        if resolved != root and not resolved.startswith(root + os.sep):
            escaping.append((shown, target))
        elif not os.path.exists(path):
            dangling.append((shown, target))

print(f"symlinks          : {total}")
print(f"escaping bundle   : {len(escaping)}")
print(f"targeting /nix/store : {len(store)}")
print(f"dangling inside   : {len(dangling)}")
for label, rows in (("ESCAPES", escaping), ("NIX STORE", store), ("DANGLING", dangling)):
    for shown, target in rows:
        print(f"    ! [{label}] {shown} -> {target}")

sys.exit(1 if (escaping or store or dangling) else 0)
PY
)"
		link_rc=$?
		indent "${link_report}"
		if [ "${link_rc}" -eq 0 ]; then
			report PASSED "every symlink in the bundle resolves inside it"
		else
			report FAILED "the bundle contains symlinks that do not resolve inside it"
		fi

		# ---------------------------------------------------------------------
		# node_modules must be REAL. A relative symlink to a sibling directory
		# inside the bundle passes the check above, and the macOS bundle
		# legitimately has one (`Contents/node_modules -> MacOS/node_modules`),
		# so the payload itself is named directly.
		# ---------------------------------------------------------------------
		banner "the bundle's node_modules"

		nm=""
		for candidate in "${ROOT}/Contents/MacOS/node_modules" "${ROOT}/node_modules"; do
			if [ -e "${candidate}" ]; then
				nm="${candidate}"
				break
			fi
		done

		if [ -z "${nm}" ]; then
			echo "  no node_modules under the bundle root or Contents/MacOS"
			report FAILED "the bundle carries a node_modules"
		else
			echo "  path: ${nm#"${ROOT}"/}"
			if [ -L "${nm}" ]; then
				echo "  it is a SYMLINK -> $(readlink "${nm}")"
				report FAILED "the bundle's node_modules is a symlink, not the tree"
			else
				count="$(find "${nm}" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
				echo "  top-level entries: ${count}"
				report PASSED "the bundle's node_modules is a real directory (${count} entries)"
			fi
		fi

		# ---------------------------------------------------------------------
		# Every directory in the bundle must be owner-writable.
		#
		# THE THIRD SELF-HOSTED CHECKOUT FAILURE MODE, gated where it is
		# created. `non-nix-build/CodeTracer.app` is gitignored, so on the
		# PERSISTENT m3 runners it survives into whatever job lands there next,
		# and a 0555 directory is one that `git clean -ffdx` cannot empty —
		# POSIX unlink needs write on the PARENT DIRECTORY, not on the file.
		# Run 33734457928 / job 100581650873 / runner m3-mcl-003: 31,307
		# "failed to remove … Permission denied", every one of them under
		# `Contents/MacOS/node_modules`, then checkout gave up, tried to delete
		# the whole checkout, and died with
		# `EACCES … unlink '…/node_modules/abbrev/LICENSE'`.
		#
		# The mode came from the SOURCE: `shutil.copytree` preserves it, and in
		# a Nix dev shell the source is /nix/store, which is 0555/0444.
		# `scripts/stage-desktop-node-modules.py` now restores owner-write and
		# prints its own before/after counts; this is the independent check on
		# the finished artefact, because the stager is not the only thing that
		# copies into this bundle (`cp -a` of the build tree and
		# `scripts/stage-electron-runtime.sh` also do).
		#
		# DIRECTORIES, not files: 0444 files are ordinary and harmless — git's
		# own pack/idx files are 0444 by design — and counting them would bury
		# the signal. The count is printed either way, so a reader can tell a
		# clean bundle from an unmeasured one.
		# ---------------------------------------------------------------------
		banner "owner-writability of the bundle's directories"

		perm_report="$(python3 - "${ROOT}" <<'PY'
import os
import sys

root = sys.argv[1]
dirs = 0
unwritable = []
ro_files = 0
for dirpath, _dirnames, filenames in os.walk(root, followlinks=False):
    dirs += 1
    try:
        if not os.lstat(dirpath).st_mode & 0o200:
            unwritable.append(os.path.relpath(dirpath, root))
    except OSError:
        pass
    for name in filenames:
        path = os.path.join(dirpath, name)
        if os.path.islink(path):
            continue
        try:
            if not os.lstat(path).st_mode & 0o200:
                ro_files += 1
        except OSError:
            pass

print(f"directories       : {dirs}")
print(f"not owner-writable: {len(unwritable)}")
print(f"read-only files   : {ro_files}  (informational; files do not block unlink)")
for shown in unwritable[:20]:
    print(f"    ! [UNWRITABLE DIR] {shown}")
if len(unwritable) > 20:
    print(f"    ... and {len(unwritable) - 20} more")

sys.exit(1 if unwritable else 0)
PY
)"
		perm_rc=$?
		indent "${perm_report}"
		if [ "${perm_rc}" -eq 0 ]; then
			report PASSED "every directory in the bundle is owner-writable"
		else
			report FAILED "the bundle has directories the owner cannot write (the next checkout on a persistent runner will fail to clean them)"
		fi

		# ---------------------------------------------------------------------
		# The Electron launcher must exec something that is here.
		#
		# A dereferenced, pruned node_modules removes every dangling SYMLINK and
		# still leaves the GUI unable to start if the runtime it execs is
		# absent — which is the state the published bundle is in for a second,
		# independent reason: the Nix `node-modules-derivation` contains no
		# `electron` package at all (880 top-level entries, none of them
		# `electron`), so `bin/electron` execs a path that has never existed on
		# any machine. A gate that only counted symlinks would call that clean.
		# ---------------------------------------------------------------------
		banner "the Electron launcher's exec target"

		launcher=""
		for candidate in "${ROOT}/Contents/MacOS/bin/electron" "${ROOT}/bin/electron"; do
			if [ -f "${candidate}" ]; then
				launcher="${candidate}"
				break
			fi
		done

		if [ -z "${launcher}" ]; then
			echo "  no bin/electron launcher in this bundle"
			report FAILED "the bundle carries a bin/electron launcher"
		else
			echo "  launcher: ${launcher#"${ROOT}"/}"
			# The exec line is the last path-looking token the script runs. Both
			# the macOS wrapper (resources/electron) and the Linux one
			# (written by appimage-scripts/install_electron.sh) name their
			# runtime relative to the launcher's own directory.
			execline="$(grep -oE '[^ "]*node_modules/electron/dist[^ "]*' "${launcher}" | head -n1)"
			if [ -z "${execline}" ]; then
				execline="$(grep -oE '[^ "]*electron/dist[^ "]*' "${launcher}" | head -n1)"
			fi
			echo "  exec target: ${execline:-<not recognised>}"
			if [ -z "${execline}" ]; then
				report FAILED "cannot read an Electron runtime path out of the launcher"
			else
				# Resolved TEXTUALLY. `cd`-ing into the path silently falls back
				# to the working directory when an intermediate component is
				# absent, and the absent case is the one being measured — the
				# first version of this check reported `/Electron` for a target
				# that should have read `.../Contents/MacOS/Electron`.
				resolved="$(python3 -c '
import os, sys
base, rel = sys.argv[1], sys.argv[2]
print(os.path.normpath(os.path.join(os.path.dirname(base), rel)))
' "${launcher}" "${execline}")"
				echo "  resolves to: ${resolved#"${ROOT}"/}"
				if [ ! -e "${resolved}" ]; then
					echo "  ABSENT"
					report FAILED "the Electron launcher execs a path that is not in the bundle"
				elif [ "${resolved#"${ROOT}"/}" = "${resolved}" ]; then
					echo "  OUTSIDE THE BUNDLE"
					report FAILED "the Electron launcher execs a path outside the bundle"
				else
					report PASSED "the Electron launcher's exec target exists in the bundle"
				fi
			fi
		fi

		# ---------------------------------------------------------------------
		# Values, so a reader can see the trade this bundle made.
		# ---------------------------------------------------------------------
		banner "bundle size"
		# NOT `find … | xargs wc -c | tail -1`: xargs splits a 32,000-file
		# bundle across several `wc` invocations and `tail -1` then reports the
		# LAST BATCH's subtotal as the whole. That undercounted this bundle by
		# 25% while looking entirely plausible, which is the failure mode a
		# measurement is supposed to be immune to.
		python3 - "${ROOT}" <<'PY'
import os
import sys

root = sys.argv[1]
files = 0
total = 0
for dirpath, _dirnames, filenames in os.walk(root, followlinks=False):
    for name in filenames:
        path = os.path.join(dirpath, name)
        if os.path.islink(path):
            continue
        try:
            total += os.lstat(path).st_size
            files += 1
        except OSError:
            pass
print(f"  regular files: {files}")
print(f"  bytes        : {total}  ({total / 1e6:.1f} MB)")
PY
	fi
fi

banner "summary"
echo "  checks: ${checks}"
echo "  failed: ${failures}"

if [ "${failures}" -gt 0 ]; then
	echo
	echo "RESULT: FAILED (${failures}/${checks})"
	echo "SCOPE: whether every path inside the desktop bundle resolves inside it."
	echo "       This is NOT a claim that the application launches, and NOT a"
	echo "       statement about which Electron version is bundled."
	exit 1
fi

echo
echo "RESULT: PASSED (${checks}/${checks})"
echo "SCOPE: whether every path inside the desktop bundle resolves inside it."
echo "       This is NOT a claim that the application launches, and NOT a"
echo "       statement about which Electron version is bundled."
