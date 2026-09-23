#!/usr/bin/env bash
#
# Install a directory's node dependencies with npm, WITHOUT letting npm rewrite
# a `yarn.lock` it does not own.
#
# THE PROBLEM
#
# `src/tests/gui` is installed by npm (every `just test-*` recipe that drives
# Playwright) and by yarn (`env.sh`'s Windows/DIY bootstrap runs
# `yarn install --frozen-lockfile` whenever a `yarn.lock` is present).  The
# tracked lockfile is `yarn.lock`; `package-lock.json` is gitignored
# repo-wide.  npm >= 7 maintains a `yarn.lock` as a secondary lockfile *if one
# already exists* — and it writes it from the tree it actually installed.
#
# That tree is PLATFORM-SPECIFIC.  `playwright` declares
# `optionalDependencies: { fsevents: 2.3.2 }`, fsevents is darwin-only, so on
# Linux npm installs no fsevents and re-serialises `yarn.lock` without its
# block.  The result is a lockfile that is dirtied by every single run:
#
#     $ npm install --no-audit --no-fund   # "up to date in 220ms"
#     $ git diff --stat -- src/tests/gui/yarn.lock
#      src/tests/gui/yarn.lock | 5 -----
#
# It is not cosmetic.  `yarn install --frozen-lockfile` on macOS needs the
# `fsevents@2.3.2` entry and fails without it, so the strip would turn the
# Windows/macOS bootstrap red while looking like noise on Linux.
#
# WHY THERE IS NO FLAG FOR THIS
#
# Measured at HEAD, in `src/tests/gui`, against a pristine `yarn.lock`:
#
#   --no-save           yarn.lock still stripped.  `save` governs package.json,
#                       not the lockfiles.
#   --no-package-lock   yarn.lock preserved, but npm then ignores BOTH
#                       lockfiles for resolution: the install floats inside the
#                       package.json semver ranges and has to re-resolve from
#                       the registry every time (~800 ms vs ~150 ms).  Trading
#                       a reproducible install for a clean worktree is the
#                       wrong trade in a test harness.
#
# npm has no option that keeps the lock-driven install and leaves yarn.lock
# alone, so the rewrite is inherent and this script absorbs it.
#
# THE RULE
#
# **npm is never authoritative for `yarn.lock` here.**  Its rewrite is a lossy
# re-serialisation of one platform's installed tree, never a considered update,
# so it is always reverted.  But it is reverted LOUDLY when npm wanted to add
# or change an entry rather than merely drop a foreign-platform optional: that
# means package.json has moved beyond the lockfile, and the fix is to
# regenerate it with the tool that owns it (`yarn install`), not to let a
# Playwright run quietly decide.
#
# Usage: ci/lib/npm-install.sh <dir> [extra npm install args...]

set -euo pipefail

if [ "$#" -lt 1 ]; then
	echo "usage: ci/lib/npm-install.sh <dir> [npm install args...]" >&2
	exit 2
fi

target_dir="$1"
shift

if [ ! -d "${target_dir}" ]; then
	echo "ci/lib/npm-install.sh: no such directory: ${target_dir}" >&2
	exit 1
fi

cd "${target_dir}"

lock="yarn.lock"
saved=""

# The restore runs on EVERY exit path, including a failed `npm install`: npm
# rewrites the lockfile before it reports the failure, so an early exit would
# leave exactly the dirt this script exists to prevent.
restore_lock() {
	local rc=$?
	if [ -n "${saved}" ] && [ -f "${saved}" ]; then
		if [ -f "${lock}" ] && ! cmp -s "${saved}" "${lock}"; then
			# Additions/changes (as opposed to pure deletions) mean npm saw a
			# dependency the lockfile does not describe.
			#
			# `diff` is run on its own rather than piped into `grep`: this file
			# sets `pipefail`, and a differing `diff` exits 1, which would make
			# the whole pipeline report failure no matter what `grep` found —
			# so the warning below never fired.  Caught by case 2 of
			# `ci/test/npm-install-yarn-lock-test.sh`.
			local diff_out
			diff_out="$(diff "${saved}" "${lock}" || true)"
			if grep -q '^>' <<<"${diff_out}"; then
				echo "" >&2
				echo "WARNING: npm wanted to ADD entries to ${target_dir}/${lock}." >&2
				echo "         That means package.json has changed and the lockfile is stale." >&2
				echo "         It has been restored (npm does not own this file); regenerate it" >&2
				echo "         with the tool that does:  cd ${target_dir} && yarn install" >&2
				echo "" >&2
			fi
			cp "${saved}" "${lock}"
		fi
		rm -f "${saved}"
	fi
	return "${rc}"
}

if [ -f "${lock}" ]; then
	saved="$(mktemp)"
	cp "${lock}" "${saved}"
	trap restore_lock EXIT
fi

npm install --no-audit --no-fund "$@"
