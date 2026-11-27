#!/usr/bin/env bash
# build-storybook-components.sh -- compile the StoryBook components bundle,
# `storybook/dist/components.js`, from `src/frontend/storybook_components.nim`,
# and record the time the compile STARTED in a stamp beside it,
# `storybook/dist/components.js.compiled`.
#
# WHY THE STAMP. `tools/visual-review/storybook-freshness.mjs` decides whether
# the bundle is current by comparing when it was compiled with every `.nim`
# under `src/frontend`. Nim leaves an output file untouched when it would write
# the same bytes, so an edit that does not change the generated JavaScript (a
# comment, a stylesheet-only change) left the bundle older than its source. The
# guard then refused every capture that followed a build which had just
# succeeded, and named a rebuild that changed nothing. See
# codetracer-pm issues/2026-11-04-capture-storybook-refuses-a-fresh-build-as-stale.md.
# The guard reads the later of the bundle's mtime and the stamp's
# (`componentsCompiledAt`).
#
# WHY A STAMP BESIDE THE BUNDLE, NOT THE BUNDLE'S OWN MTIME. `storybook-static`
# copies the bundle, and the same guard refuses a corpus older than anything in
# `storybook/dist`. Moving an unchanged bundle's mtime forward would make every
# recompile that changed nothing (the low-level-code gate recompiles the bundle)
# leave the corpus older than an identical bundle. So the bundle's mtime moves
# only when nim rewrites it, and the stamp says when it was last compiled. The
# stamp itself is no source of `storybook-static`.
#
# WHY THE START TIME AND NOT THE END. An edit made while nim is reading the
# sources is newer than the stamp, so the next check refuses it. A stamp taken
# after the compile would count that edit as built. For the same reason a bundle
# nim did rewrite is moved back to the start of the compile: its write time is
# later than the start. This is the ordering the GPUI shim stamp uses
# (codetracer-pm spec/Testing/Cross-Renderer-Visual-Alignment.md).
#
# THE INPUT RECORD. The bundle compiles in more than `src/frontend`: modules
# from the sibling checkouts on the search path, files embedded with
# `staticRead` (the Agent Harbor fixture set among them) and the Nim
# configuration. After a successful compile this writes what the compile read
# to `storybook/dist/components.js.inputs.json`: the compiler's own module list
# (`--genScript:on` writes `<nimcache>/storybook_components.deps`; the JS
# backend keeps nothing else in its nimcache, so a private temporary one is
# used), and the fixture files the compile embedded, which
# `storybook_components.nim` writes out when `-d:storybookFixtureInputsOut` is
# set. `tools/visual-review/record-storybook-inputs.mjs` adds each sibling
# checkout's HEAD and dirty flag and a digest of the fixture set, and the guard
# refuses a bundle whose recorded inputs have changed, or that has no record.
# See `INPUTS_RECORD` in `tools/visual-review/storybook-freshness.mjs`. The
# record is written before the stamp, so a recording that fails leaves the
# compile unstamped.
#
# A FAILED COMPILE IS NOT STAMPED. With `set -e` the script stops before the
# `touch`, so the stamp keeps its old mtime and the guard still refuses it.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "${repo_root}"

bundle=storybook/dist/components.js
compiled_stamp="${bundle}.compiled"
inputs_record="${bundle}.inputs.json"
start_stamp="$(mktemp)"
inputs_dir="$(mktemp -d)"
trap 'rm -rf -- "${start_stamp}" "${inputs_dir}"' EXIT
# `nim js` does not create its nimcache directory before writing the `.deps`.
mkdir -p "${inputs_dir}/nimcache"

mkdir -p storybook/dist
nim \
	-d:chronicles_enabled=off \
	-d:ctRenderer \
	--path:../nim-everywhere/src \
	--hints:off \
	--genScript:on \
	--nimcache:"${inputs_dir}/nimcache" \
	-d:storybookFixtureInputsOut="${inputs_dir}/fixture-inputs.json" \
	--out:"${bundle}" \
	js src/frontend/storybook_components.nim

node tools/visual-review/record-storybook-inputs.mjs \
	"${repo_root}" \
	"${repo_root}/src/frontend/storybook_components.nim" \
	"${inputs_dir}/nimcache/storybook_components.deps" \
	"${inputs_dir}/fixture-inputs.json" \
	"${inputs_record}"

# `touch -r` copies a reference file's mtime. It is the portable spelling: BSD
# touch has no GNU `-d @epoch`. Only a bundle nim rewrote is newer than the
# start, and that one is moved back to it; an unchanged bundle keeps its mtime.
# That can refuse a build that was fresh; it cannot accept one that was not.
if [[ ${bundle} -nt ${start_stamp} ]]; then
	touch -r "${start_stamp}" "${bundle}"
fi
touch -r "${start_stamp}" "${compiled_stamp}"
