#!/usr/bin/env bash
#
# cua-keymap-extractor.sh — PLAT-68's gate that the CUA base keymap is VS
# Code's: every row CUA-Keymap.md cites from VS Code re-extracts from VS Code
# 1.105.0, and every VS Code default the extraction finds is either taken (§3,
# §4) or declined with a reason (§6).
#
# The checking is `tools/cua-keymap-extractor.py`'s (see its header for what
# is red). This script only supplies its three inputs, each pinned:
#
#   * monaco-editor 0.54.0's ESM — `node_modules/monaco-editor/esm/vs`, the
#     package this repository already bundles, or `$CT_MONACO_DIR`;
#   * the VS Code sources at 484fdf69 (1.105.0) — fetched once as GitHub's
#     source archive for that commit into `$CT_VSCODE_SRC_CACHE` (default
#     `$XDG_CACHE_HOME/codetracer/vscode-484fdf69`), `src/vs/**/*.ts` only, or
#     `$CT_VSCODE_DIR` when a checkout is already at hand;
#   * CUA-Keymap.md from the specification checkout
#     (`$CT_SPECS_DIR`, else `../codetracer-specs`).
#
# A MISSING INPUT IS RED, NEVER A SKIP: a gate that passes when it could not
# look is the false green this campaign keeps finding (Verification-Harness-
# Traps §1). The extractor itself refuses inputs that are not at the pinned
# versions.
#
# Run from the repository root.

set -euo pipefail

COMMIT=484fdf69b8509c1c9370d913b32e9f6d3a68cc99

monaco="${CT_MONACO_DIR:-node_modules/monaco-editor/esm/vs}"
specs="${CT_SPECS_DIR:-../codetracer-specs}"
spec="$specs/spec/GUI/CUA-Keymap.md"

if [ ! -d "$monaco" ]; then
	echo "cua-keymap-extractor: no monaco-editor ESM at '$monaco'" \
		"(set CT_MONACO_DIR, or install node_modules)" >&2
	exit 1
fi
if [ ! -f "$spec" ]; then
	echo "cua-keymap-extractor: no CUA-Keymap.md at '$spec'" \
		"(set CT_SPECS_DIR to a codetracer-specs checkout)" >&2
	exit 1
fi

vscode="${CT_VSCODE_DIR:-}"
if [ -z "$vscode" ]; then
	cache="${CT_VSCODE_SRC_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/codetracer/vscode-${COMMIT:0:8}}"
	vscode="$cache/vscode-$COMMIT"
	if [ ! -f "$vscode/package.json" ]; then
		mkdir -p "$cache"
		echo "cua-keymap-extractor: fetching VS Code $COMMIT sources into $cache"
		curl -fsSL "https://codeload.github.com/microsoft/vscode/tar.gz/$COMMIT" |
			tar -xz -C "$cache" --wildcards "*/src/vs/*.ts" "*/package.json"
	fi
fi

exec python3 tools/cua-keymap-extractor.py \
	--monaco "$monaco" --vscode "$vscode" --spec "$spec"
