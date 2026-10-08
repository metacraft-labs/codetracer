#!/usr/bin/env bash
# monarch-languages-fresh.sh — the committed Monarch definitions the terminal
# tokenises with are what the pinned `monaco-editor` exports.
#
# `scripts/monarch-languages.mjs` turns Monaco's own language definitions
# (`node_modules/monaco-editor/esm/vs/basic-languages/*`, the version the
# desktop's editor links through `src/public/third_party/monaco-editor`) into
# `src/frontend/tui/app/syntax/monarch_languages.json`, which the terminal's
# highlighter compiles in (PLAT-47 B4). The JSON is committed, so it goes stale
# when `monaco-editor` moves or when someone edits it by hand — and then the
# terminal colours source with rules the desktop no longer uses. This gate
# regenerates it into a scratch file and diffs it against the tree.
#
# Needs `node` and the installed `node_modules` (the desktop build's own
# prerequisite); a missing one is a failure naming the remedy, not a skip.
#
# Usage: ci/test/monarch-languages-fresh.sh            (from the repo root)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

committed=src/frontend/tui/app/syntax/monarch_languages.json
if ! command -v node >/dev/null 2>&1; then
	echo "FAIL: monarch-languages-fresh needs node on PATH (the dev shell provides it)" >&2
	exit 1
fi
if [ ! -f node_modules/monaco-editor/package.json ]; then
	echo "FAIL: node_modules/monaco-editor is missing — run the desktop's install (yarn/npm) first" >&2
	exit 1
fi
scratch="$(mktemp)"
trap 'rm -f "$scratch"' EXIT
node scripts/monarch-languages.mjs "$scratch"
if ! cmp -s "$scratch" "$committed"; then
	echo "FAIL: $committed is not what scripts/monarch-languages.mjs generates" >&2
	echo "      from node_modules/monaco-editor $(node -p "require('./node_modules/monaco-editor/package.json').version")." >&2
	echo "      Regenerate it: node scripts/monarch-languages.mjs $committed" >&2
	exit 1
fi
echo "OK: $committed matches monaco-editor's definitions"
