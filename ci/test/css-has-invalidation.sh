#!/usr/bin/env bash
#
# css-has-invalidation.sh — CI entry point for the `:has()` invalidation guard
# (css-has-invalidation-guard.py, whose header says what it refuses and why).
#
# Runs the guard's planted fixtures first, so a guard that has lost the ability
# to report fails before its verdict on the real stylesheets is read; then
# compiles the shipped stylesheets into a scratch directory
# (ci/lib/compile-shipped-stylesheets.sh) and checks the output. Nothing is
# written into the worktree. Needs `stylus` (the dev shell).

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../.." && pwd)"

python3 "${here}/css-has-invalidation-guard.py" --self-test

out_dir="$(mktemp -d "${TMPDIR:-/tmp}/ct-css-has.XXXXXX")"
trap 'rm -rf "${out_dir}"' EXIT

printf 'css-has-invalidation: '
bash "${repo_root}/ci/lib/compile-shipped-stylesheets.sh" "${out_dir}"

# Not `exec`: the EXIT trap that removes the scratch directory has to run.
status=0
python3 "${here}/css-has-invalidation-guard.py" --css-dir "${out_dir}" || status=$?
exit "${status}"
