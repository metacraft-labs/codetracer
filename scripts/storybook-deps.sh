#!/usr/bin/env bash
# Installs `storybook/node_modules` from the committed lockfile. Not a check on
# the product, but not marked as not-a-CI-gate either: its lockfile-digest
# refusal IS exercised from CI by `ci/test/stale-artefact-guards-test.sh`, and
# `shell-gate-coverage.sh` fails a file that is both reachable and declared
# unwired.
#
# Every `npm run` under `storybook/` resolves its binary from that directory's
# `node_modules/.bin`, and nothing in this repo ever created it: the recipes
# jumped straight to `npm run build-storybook`, which fails with `storybook:
# command not found`. Because `just test-e2e` with no arguments routes through
# `ensure-storybook-static` -> `storybook-build`, that missing directory made the
# bare entry point unrunnable, and every `*storybook*.spec.ts` a permanent red
# that no one could act on.
#
# THE WARM-CHECKOUT GUARD USED TO ASK THE WRONG QUESTION.
#
# `[ -x node_modules/.bin/storybook ]` is existence, and what this needs is that
# the installed tree matches `package-lock.json`. A lockfile change — a bumped
# storybook major, a security patch, a dependency added for a new story — was
# therefore NEVER installed on any machine that had run this once, and the
# storybook built afterwards was built from the previous dependency set with
# nothing saying so. `npm ci` is idempotent and takes ~17s, so the fix is to key
# the skip on the lockfile's own digest.
#
# It is a script rather than a `just` recipe body so that
# `ci/test/stale-artefact-guards-test.sh` can execute it against a synthetic
# tree with a stubbed `npm` and prove the skip actually stops skipping when the
# lockfile moves. A recipe body can only be read, not run.
#
# Usage: scripts/storybook-deps.sh [storybook-dir]
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STOREBOOK_DIR="${1:-${SCRIPT_DIR}/../storybook}"
cd "${STOREBOOK_DIR}"

# The stamp lives inside node_modules so that deleting the tree also deletes the
# claim that it was installed.
STAMP="node_modules/.package-lock-digest"
WANT="$(sha256sum package-lock.json | cut -d' ' -f1)"

if [ -x node_modules/.bin/storybook ] && [ -f "${STAMP}" ] && [ "$(cat "${STAMP}")" = "${WANT}" ]; then
	echo "storybook-deps: node_modules matches package-lock.json (${WANT})"
	exit 0
fi

if [ -f "${STAMP}" ]; then
	echo "storybook-deps: package-lock.json has changed since the last install ($(cat "${STAMP}") -> ${WANT}); reinstalling." >&2
fi

npm ci --no-audit --no-fund

# `npm ci` exits 0 on a lockfile that installs nothing useful, so assert the
# binary the `npm run` scripts actually invoke.
test -x node_modules/.bin/storybook

# Written last, so an interrupted install is re-run rather than trusted.
printf '%s\n' "${WANT}" >"${STAMP}"
