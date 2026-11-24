#!/usr/bin/env bash
#
# css-token-resolution.sh — CI entry point for the unresolved-style-variable
# guard.
#
# Stylus emits an unknown identifier verbatim instead of failing, so
# `color: colors-ui-text-accent` compiles cleanly, reaches the browser as an
# invalid value, is dropped, and the element inherits whatever is behind it.
# The page renders; it is merely the wrong colour. Three shipped defects in
# this repo have had exactly that cause and all three were found by a person
# looking at the screen.
#
# THIS SCRIPT COMPILES BEFORE IT CHECKS, ON PURPOSE.
# The defect IS source and compiled output disagreeing silently, so the guard
# has to read the output. It compiles each entry point the build ships,
# using the same `stylus` binary the build uses, into a scratch directory, and
# hands that directory to the checker. Nothing is written into the worktree.
#
# The list of entry points is read from `StylusCssEntryPoints` in repro.nim by the
# checker, not written down twice — a theme added to the build is covered the
# day it is added.
#
# Both arms enforce: an unresolved design token and an unresolved legacy
# SCREAMING_CASE palette variable each fail the run.
#
# Env:
#   CT_CSS_TOKEN_JSON        write the findings as JSON to this path

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../.." && pwd)"

if ! command -v stylus >/dev/null 2>&1; then
	echo "css-token-resolution: stylus is not on PATH." >&2
	echo "  Run this inside the dev shell: nix develop --command just test-css-token-resolution" >&2
	exit 1
fi

out_dir="$(mktemp -d "${TMPDIR:-/tmp}/ct-css-token.XXXXXX")"
trap 'rm -rf "${out_dir}"' EXIT

# The entry points the build ships (`StylusCssEntryPoints` in repro.nim),
# compiled by the helper the other compiled-CSS guards share; it asks the
# checker below for the list, so the two cannot disagree.
printf 'css-token-resolution: '
bash "${repo_root}/ci/lib/compile-shipped-stylesheets.sh" "${out_dir}"

args=()
if [[ -n ${CT_CSS_TOKEN_JSON:-} ]]; then
	args+=(--json "${CT_CSS_TOKEN_JSON}")
fi

# Not `exec`: the EXIT trap that removes the scratch directory has to run.
status=0
python3 "${here}/css-token-resolution-guard.py" \
	--repo-root "${repo_root}" \
	--css-dir "${out_dir}" \
	"${args[@]+"${args[@]}"}" || status=$?
exit "${status}"
