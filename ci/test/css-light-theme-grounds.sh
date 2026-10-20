#!/usr/bin/env bash
#
# css-light-theme-grounds.sh — the desktop's light theme paints its panels and
# its editor's ground from the design system's LIGHT palette.
#
# It compiles the two Electron stylesheets the Tupfile ships
# (`default_dark_theme_electron.styl`, `default_white_theme_electron.styl`)
# with the same `stylus` the build uses, into a scratch directory, and hands
# them to `css-light-theme-grounds.py`, whose header says what it asserts and
# why. Static: no browser, no display, no build; a few seconds.
#
# It sits beside `css-token-resolution.sh` and runs in the same lane, for the
# same reason: the defect it guards against is a property of the COMPILED
# stylesheet (both themes compiled clean while the light one carried the dark
# surfaces), so the output is what it reads.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../.." && pwd)"
styles_dir="${repo_root}/src/frontend/styles"

if ! command -v stylus >/dev/null 2>&1; then
	echo "css-light-theme-grounds: stylus is not on PATH." >&2
	echo "  Run this inside the dev shell: nix develop --command just test-css-light-theme-grounds" >&2
	exit 1
fi

out_dir="$(mktemp -d "${TMPDIR:-/tmp}/ct-css-light.XXXXXX")"
trap 'rm -rf "${out_dir}"' EXIT

for theme in dark white; do
	(cd "${styles_dir}" && stylus -p "default_${theme}_theme_electron.styl") \
		>"${out_dir}/default_${theme}_theme_electron.css"
done

# Not `exec`: the EXIT trap that removes the scratch directory has to run.
status=0
python3 "${here}/css-light-theme-grounds.py" \
	--repo-root "${repo_root}" \
	--dark "${out_dir}/default_dark_theme_electron.css" \
	--light "${out_dir}/default_white_theme_electron.css" || status=$?
exit "${status}"
