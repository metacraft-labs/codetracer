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
# has to read the output. It compiles each entry point the Tupfile ships,
# using the same `stylus` binary the build uses, into a scratch directory, and
# hands that directory to the checker. Nothing is written into the worktree.
#
# The list of entry points is read from src/frontend/styles/Tupfile by the
# checker, not written down twice — a theme added to the build is covered the
# day it is added.
#
# Env:
#   CT_CSS_TOKEN_JSON        write the findings as JSON to this path
#   CT_CSS_TOKEN_ENFORCE_LEGACY=1
#                            fail on any SCREAMING_CASE leak instead of
#                            honouring the ratchet ceilings in
#                            ci/test/css-token-resolution-legacy.baseline

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../.." && pwd)"
styles_dir="${repo_root}/src/frontend/styles"

if ! command -v stylus >/dev/null 2>&1; then
	echo "css-token-resolution: stylus is not on PATH." >&2
	echo "  Run this inside the dev shell: nix develop --command just test-css-token-resolution" >&2
	exit 1
fi

out_dir="$(mktemp -d "${TMPDIR:-/tmp}/ct-css-token.XXXXXX")"
trap 'rm -rf "${out_dir}"' EXIT

# Same rule the Tupfile's !stylus macro applies, over the same entry points.
# The entry list is materialised into a file first, so a change to the
# Tupfile's rule syntax shows up as an EMPTY list — which the checker reports
# as a failure — rather than as a loop that silently does nothing.
ship_list="${out_dir}/.shipped"
sed -n 's/^:[[:space:]]*\([^[:space:]]*\.styl\)[[:space:]]*|>[[:space:]]*!stylus[[:space:]]*|>[[:space:]]*\([^[:space:]]*\.css\)[[:space:]]*$/\1 \2/p' \
	"${styles_dir}/Tupfile" >"${ship_list}"

echo "css-token-resolution: compiling $(wc -l <"${ship_list}" | tr -d ' ') shipped stylesheet(s) with stylus $(stylus --version)"
while read -r src dst; do
	[[ -n ${src} ]] || continue
	(cd "${styles_dir}" && stylus -p "${src}") >"${out_dir}/${dst}"
	printf '  %-40s -> %8s bytes\n' "${src}" "$(wc -c <"${out_dir}/${dst}" | tr -d ' ')"
done <"${ship_list}"

args=()
if [[ -n ${CT_CSS_TOKEN_JSON:-} ]]; then
	args+=(--json "${CT_CSS_TOKEN_JSON}")
fi
if [[ ${CT_CSS_TOKEN_ENFORCE_LEGACY:-0} == "1" ]]; then
	args+=(--enforce-legacy)
fi

# Not `exec`: the EXIT trap that removes the scratch directory has to run.
status=0
python3 "${here}/css-token-resolution-guard.py" \
	--repo-root "${repo_root}" \
	--css-dir "${out_dir}" \
	"${args[@]+"${args[@]}"}" || status=$?
exit "${status}"
