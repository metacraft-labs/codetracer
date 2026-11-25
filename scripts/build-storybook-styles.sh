#!/usr/bin/env bash
# build-storybook-styles.sh -- compile the stylesheets StoryBook serves.
#
# StoryBook draws CodeTracer's components with the app's own CSS:
# `storybook/.storybook/main.ts` mounts `src/build-debug-repro/frontend` as
# `/frontend`, and `appStyles.js` links the stylesheets `src/frontend/index.html`
# names from there (`frontend/styles/*.css`). Those files are outputs of the
# `frontend-styles` target in `repro.nim` (one `stylus-<name>` edge per entry
# point in `StylusCssEntryPoints`, plus the `default_dark_theme.css` copy).
#
# WHY THIS EXISTS. `just storybook-build` rebuilt the components bundle and the
# static tree but compiled no stylesheet: only `just build-once` (or a hand
# `stylus` run) wrote them. A StoryBook built after an edit under
# `src/frontend/styles/` therefore drew the CSS from before the edit, and
# nothing reported it -- a visual review rendered a control at 62x24 px from
# the old CSS where the edited stylesheet gives 32x18 px. See codetracer-pm
# issues/2026-11-24-storybook-build-renders-stale-css-from-build-debug-repro-after-a-stylesheet-edit.md
# and spec/Testing/Cross-Renderer-Visual-Alignment.md "Storybook stylesheets".
#
# WHY THROUGH THE BUILD AND NOT `stylus` HERE. The stylus edges are the one
# definition of how these files are compiled (which compiler, which entry
# points, which output names) and they are cached: a StoryBook build after no
# stylesheet change costs a cache check, not five compiles. Compiling them a
# second way here would give the tree two writers that can disagree.
#
# CODETRACER_REPROBUILD_PARTIAL=1 tells build-once.sh that this build makes
# no `ct`, so its checks on `bin/ct` are not run over a tree that has none.
#
# The output tree is fixed to `debug` because `main.ts` reads
# `src/build-debug-repro`, whatever `CODETRACER_CONFIG` the caller has set.
#
# THE STAMP. After a successful build this sets
# `src/build-debug-repro/frontend-styles.compiled` to the time the build
# STARTED. `tools/visual-review/storybook-freshness.mjs` refuses a corpus whose
# compiled stylesheets are older than a `.styl` source, and it reads them as
# compiled at the later of that stamp and the oldest `.css`: the stylus edges
# are cached, so a build that has nothing to recompile leaves every `.css` with
# its old mtime, and without the stamp the guard would refuse it. The start
# time, not the end, so that an edit made while the build reads the sources is
# still newer than the stamp; the same ordering as
# `scripts/build-storybook-components.sh`. A failed build is not stamped
# (`set -e` stops before the `touch`). The stamp sits beside `frontend/`, not
# in it, so `storybook build` does not copy it into the corpus.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "${repo_root}"

styles_stamp=src/build-debug-repro/frontend-styles.compiled
start_stamp="$(mktemp)"
trap 'rm -f -- "${start_stamp}"' EXIT

CODETRACER_CONFIG=debug \
	CODETRACER_REPROBUILD_COMMAND=build \
	CODETRACER_REPROBUILD_PARTIAL=1 \
	CODETRACER_REPROBUILD_TARGET=".#frontend-styles" \
	bash scripts/build-once.sh

# `touch -r` copies the reference's mtime: the portable spelling (BSD touch has
# no GNU `-d @epoch`).
touch -r "${start_stamp}" "${styles_stamp}"
