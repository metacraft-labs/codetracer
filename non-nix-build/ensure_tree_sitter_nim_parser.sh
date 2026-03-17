#!/usr/bin/env bash

set -euo pipefail

# Allow callers to override ROOT_DIR, but derive a safe default when unset.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
: "${ROOT_DIR:=$(cd "$SCRIPT_DIR/.." && pwd)}"

TREE_SITTER_NIM_DIR="${ROOT_DIR}/libs/tree-sitter-nim"
GRAMMAR_JS="$TREE_SITTER_NIM_DIR/grammar.js"

if [[ ! -d $TREE_SITTER_NIM_DIR ]]; then
	echo "Skipping tree-sitter-nim parser check: $TREE_SITTER_NIM_DIR does not exist"
	exit 0
fi

if [[ ! -f $GRAMMAR_JS ]]; then
	echo "Missing grammar file: $GRAMMAR_JS" >&2
	exit 1
fi

pushd "$TREE_SITTER_NIM_DIR" >/dev/null

LOCAL_TREE_SITTER_CLI="./node_modules/.bin/tree-sitter"
TREE_SITTER_CLI_CMD=""
TREE_SITTER_CLI_VERSION_RAW="$(sed -n 's/.*"tree-sitter-cli":[[:space:]]*"\([^"]*\)".*/\1/p' package.json | head -n1 || true)"
TREE_SITTER_CLI_VERSION_CLEAN="${TREE_SITTER_CLI_VERSION_RAW#^}"
TREE_SITTER_CLI_VERSION_CLEAN="${TREE_SITTER_CLI_VERSION_CLEAN#~}"
TREE_SITTER_CLI_PACKAGE_SPEC="${TREE_SITTER_NIM_FALLBACK_CLI_PACKAGE_SPEC:-tree-sitter-cli@${TREE_SITTER_CLI_VERSION_CLEAN:-0.25.10}}"
TREE_SITTER_CLI_CACHE_DIR="${ROOT_DIR}/.tools/tree-sitter-cli-cache"

if [[ -x $LOCAL_TREE_SITTER_CLI ]]; then
	TREE_SITTER_CLI_CMD="$LOCAL_TREE_SITTER_CLI"
else
	# 1. Check for a system-installed tree-sitter (e.g. from brew or nix).
	#    This avoids the chicken-and-egg problem where npm ci triggers
	#    node-gyp which needs parser.c before we can generate it.
	if command -v tree-sitter &>/dev/null; then
		echo "tree-sitter-nim: using system tree-sitter CLI: $(command -v tree-sitter)"
		TREE_SITTER_CLI_CMD="tree-sitter"
	# 2. Try lockfile install, but only when parser.c already exists.
	#    When parser.c is missing, npm ci triggers node-gyp which fails
	#    because it needs parser.c (chicken-and-egg).  Even with
	#    --ignore-scripts, npm ci creates a broken node_modules/tree-sitter-cli/
	#    directory that interferes with the isolated CLI cache fallback.
	elif [[ -f "package-lock.json" && -f "src/parser.c" ]]; then
		echo "tree-sitter-nim: local CLI missing; attempting lockfile install with npm ci..."
		if npm ci --no-audit --fund=false; then
			if [[ -x $LOCAL_TREE_SITTER_CLI ]]; then
				TREE_SITTER_CLI_CMD="$LOCAL_TREE_SITTER_CLI"
			else
				echo "tree-sitter-nim: npm ci completed but local CLI is still missing." >&2
			fi
		else
			echo "tree-sitter-nim: npm ci failed; falling back to isolated CLI path." >&2
		fi
	else
		echo "tree-sitter-nim: skipping npm ci (parser.c missing or no lockfile); using CLI fallback."
	fi
fi

if [[ -z $TREE_SITTER_CLI_CMD ]]; then
	# Install only tree-sitter-cli in an isolated cache so parser generation does not depend
	# on compiling this grammar package's native Node addon dependencies.
	mkdir -p "$TREE_SITTER_CLI_CACHE_DIR"
	pushd "$TREE_SITTER_CLI_CACHE_DIR" >/dev/null
	if [[ ! -f "package.json" ]]; then
		printf '{\n  "name": "tree-sitter-cli-cache",\n  "private": true\n}\n' >package.json
	fi
	echo "tree-sitter-nim: installing isolated CLI package '$TREE_SITTER_CLI_PACKAGE_SPEC'..."
	npm install --no-save --no-audit --fund=false "$TREE_SITTER_CLI_PACKAGE_SPEC"
	popd >/dev/null
	TREE_SITTER_CLI_CMD="$TREE_SITTER_CLI_CACHE_DIR/node_modules/.bin/tree-sitter"
	if [[ ! -x $TREE_SITTER_CLI_CMD ]]; then
		echo "tree-sitter-nim: isolated CLI install did not produce '$TREE_SITTER_CLI_CMD'." >&2
		exit 1
	fi
fi

echo "tree-sitter-nim: using CLI '$TREE_SITTER_CLI_CMD'"

if [[ ! -f "src/parser.c" ]]; then
	echo "tree-sitter-nim: src/parser.c is missing, generating..."
	"$TREE_SITTER_CLI_CMD" generate
elif [[ "grammar.js" -nt "src/parser.c" ]]; then
	echo "tree-sitter-nim: grammar.js is newer than src/parser.c, regenerating..."
	"$TREE_SITTER_CLI_CMD" generate
else
	echo "tree-sitter-nim: src/parser.c is up to date"
fi

popd >/dev/null
