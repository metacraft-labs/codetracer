#!/usr/bin/env bash
#
# css-url-resolution.sh — CI entry point for the url() resolution guard
# (css-url-resolution-guard.py, whose header says how a url is resolved and
# why a missing file is a defect).
#
# Runs the guard's planted fixtures first, so a guard that has lost the ability
# to report fails before its verdict on the real stylesheets is read; then
# compiles the shipped stylesheets into a scratch directory
# (ci/lib/compile-shipped-stylesheets.sh) and checks every url() in the output
# against the files the build ships. Nothing is written into the worktree.
# Needs `stylus` (the dev shell) and the design-system submodule checked out,
# since the theme fonts are read from it.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../.." && pwd)"

python3 "${here}/css-url-resolution-guard.py" --self-test

out_dir="$(mktemp -d "${TMPDIR:-/tmp}/ct-css-url.XXXXXX")"
trap 'rm -rf "${out_dir}"' EXIT

printf 'css-url-resolution: '
bash "${repo_root}/ci/lib/compile-shipped-stylesheets.sh" "${out_dir}"

# Not `exec`: the EXIT trap that removes the scratch directory has to run.
status=0
python3 "${here}/css-url-resolution-guard.py" --repo-root "${repo_root}" --css-dir "${out_dir}" || status=$?
exit "${status}"
