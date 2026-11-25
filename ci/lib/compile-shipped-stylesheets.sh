#!/usr/bin/env bash
#
# compile-shipped-stylesheets.sh OUT_DIR — compile every stylesheet the build
# ships into OUT_DIR, with the `stylus` on PATH, for the guards that read the
# COMPILED CSS (css-token-resolution.sh, css-has-invalidation.sh).
#
# Those guards read the output on purpose: what the browser gets is what they
# judge, and a check over the `.styl` source would have to re-implement
# Stylus' variable resolution and nesting (`&:has(...)` under a parent rule)
# to know it.
#
# The list of entry points is `StylusCssEntryPoints` in repro.nim, asked of
# css-token-resolution-guard.py (`--print-shipped`), so it is written down in
# one place. It is materialised into a file first, so a change to the recipe's
# list shape shows up as an EMPTY list -- which each guard reports as a
# failure -- rather than as a loop that silently does nothing.
#
# Nothing is written outside OUT_DIR. Prints one line per compiled sheet.

set -euo pipefail

if [[ $# -ne 1 ]]; then
	echo "usage: compile-shipped-stylesheets.sh OUT_DIR" >&2
	exit 2
fi
out_dir="$1"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../.." && pwd)"
styles_dir="${repo_root}/src/frontend/styles"

if ! command -v stylus >/dev/null 2>&1; then
	echo "compile-shipped-stylesheets: stylus is not on PATH." >&2
	echo "  Run this inside the dev shell (nix develop --command just ...)." >&2
	exit 1
fi

mkdir -p "${out_dir}"
ship_list="${out_dir}/.shipped"
python3 "${repo_root}/ci/test/css-token-resolution-guard.py" \
	--repo-root "${repo_root}" --css-dir "${out_dir}" --print-shipped >"${ship_list}"

echo "compiling $(wc -l <"${ship_list}" | tr -d ' ') shipped stylesheet(s) with stylus $(stylus --version)"
while read -r src dst; do
	[[ -n ${src} ]] || continue
	(cd "${styles_dir}" && stylus -p "${src}") >"${out_dir}/${dst}"
	printf '  %-40s -> %8s bytes\n' "${src}" "$(wc -c <"${out_dir}/${dst}" | tr -d ' ')"
done <"${ship_list}"
