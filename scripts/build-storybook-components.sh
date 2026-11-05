#!/usr/bin/env bash
# build-storybook-components.sh -- compile the StoryBook components bundle,
# `storybook/dist/components.js`, from `src/frontend/storybook_components.nim`,
# and stamp the bundle with the time the compile STARTED.
#
# WHY THE STAMP. `tools/visual-review/storybook-freshness.mjs` decides whether
# the bundle is current by comparing its mtime with every `.nim` under
# `src/frontend`. Nim leaves an output file untouched when it would write the
# same bytes, so an edit that does not change the generated JavaScript (a
# comment, a stylesheet-only change) left the bundle older than its source. The
# guard then refused every capture that followed a build which had just
# succeeded, and named a rebuild that changed nothing. See
# codetracer-pm issues/2026-11-04-capture-storybook-refuses-a-fresh-build-as-stale.md.
#
# WHY THE START TIME AND NOT THE END. An edit made while nim is reading the
# sources is newer than the stamp, so the next check refuses it. A stamp taken
# after the compile would count that edit as built. This is the ordering the
# GPUI shim stamp uses (codetracer-pm spec/Testing/Cross-Renderer-Visual-Alignment.md).
#
# A FAILED COMPILE IS NOT STAMPED. With `set -e` the script stops before the
# `touch`, so the bundle keeps its old mtime and the guard still refuses it.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "${repo_root}"

bundle=storybook/dist/components.js
start_stamp="$(mktemp)"
trap 'rm -f -- "${start_stamp}"' EXIT

mkdir -p storybook/dist
nim \
	-d:chronicles_enabled=off \
	-d:ctRenderer \
	--path:../nim-everywhere/src \
	--hints:off \
	--out:"${bundle}" \
	js src/frontend/storybook_components.nim

# `touch -r` copies a reference file's mtime. It is the portable spelling: BSD
# touch has no GNU `-d @epoch`. When nim did rewrite the bundle its mtime is
# later than the stamp, so the stamp only ever moves the bundle back to the
# start of the compile. That can refuse a build that was fresh; it cannot accept
# one that was not.
touch -r "${start_stamp}" "${bundle}"
