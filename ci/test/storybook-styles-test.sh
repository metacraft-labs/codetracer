#!/usr/bin/env bash
#
# storybook-styles-test.sh -- `just storybook-build` serves the stylesheets as
# they are in the tree, not whatever the last `just build-once` left in
# `src/build-debug-repro/frontend/styles/`.
#
# codetracer-pm issues/2026-11-24-storybook-build-renders-stale-css-from-build-debug-repro-after-a-stylesheet-edit.md:
# the StoryBook copies `src/build-debug-repro/frontend` into its static tree,
# and no recipe on the StoryBook path compiled the styles into it, so a
# StoryBook built after an edit under `src/frontend/styles/` drew the CSS from
# before the edit.
#
# HOW THE STALE STATE IS MADE. Editing a tracked `.styl` from a test would
# race every other user of the checkout, so the test makes the build tree's
# CSS disagree with the sources from the other side, which is the same
# condition: it removes one compiled stylesheet and overwrites the others with
# a marker, exactly what a build tree from before a stylesheet edit looks like
# to the StoryBook (compiled CSS that is not what the sources compile to).
# Those files are git-ignored build outputs; the recipe under test rewrites
# them.
#
# WHAT IS COMPARED. After `just storybook-build`, every shipped stylesheet in
# `storybook/storybook-static/frontend/styles/` must equal, byte for byte, what
# `stylus` compiles from `src/frontend/styles/` now
# (ci/lib/compile-shipped-stylesheets.sh, the entry-point list in repro.nim).
# Nothing is mocked: the real recipe, the real build, the real StoryBook build
# and the real compiler.
#
# Needs the dev shell (`stylus`, `nim`, `node`, `repro`). Writes
# `src/build-debug-repro/frontend/styles/`, `storybook/dist/` and
# `storybook/storybook-static/`, as `just storybook-build` does.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT

fail() {
	echo "FAIL $*" >&2
	exit 1
}

# 1. What the sources compile to now.
bash ci/lib/compile-shipped-stylesheets.sh "${work}/expected"
mapfile -t shipped < <(awk 'NF == 2 { print $2 }' "${work}/expected/.shipped")
[[ ${#shipped[@]} -gt 0 ]] || fail "no shipped stylesheet listed in repro.nim"

# 2. A build tree whose CSS is not what the sources compile to.
styles="src/build-debug-repro/frontend/styles"
mkdir -p "${styles}"
for css in "${shipped[@]}"; do
	chmod u+w "${styles}/${css}" 2>/dev/null || true
	printf '/* stale: written by ci/test/storybook-styles-test.sh */\n' >"${styles}/${css}"
done
rm -f -- "${styles:?}/${shipped[0]}"
echo "made ${styles} stale: removed ${shipped[0]}, overwrote ${#shipped[@]} - 1 others"

# 3. The recipe under test.
just storybook-build

# 4. The StoryBook serves what the sources compile to.
served="storybook/storybook-static/frontend/styles"
bad=0
for css in "${shipped[@]}"; do
	if [[ ! -f "${served}/${css}" ]]; then
		echo "FAIL ${served}/${css} is missing" >&2
		bad=1
	elif ! cmp -s "${work}/expected/${css}" "${served}/${css}"; then
		echo "FAIL ${served}/${css} is not what stylus compiles from src/frontend/styles now" >&2
		echo "     served: $(head -c 120 "${served}/${css}" | tr '\n' ' ')" >&2
		bad=1
	else
		echo "ok   ${served}/${css} matches the sources ($(wc -c <"${served}/${css}" | tr -d ' ') bytes)"
	fi
done
[[ ${bad} -eq 0 ]] || fail "storybook-build served stylesheets that are not the tree's"
echo "PASS storybook-build serves the stylesheets as they are in the tree"
