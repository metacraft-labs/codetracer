#!/usr/bin/env bash

set -e

echo "==========="
echo "codetracer build: setup node deps"
echo "-----------"

# Generate tree-sitter-nim parser BEFORE yarn install
# (yarn will try to build tree-sitter-nim which needs parser.c)
TREE_SITTER_NIM_DIR="$ROOT_DIR/libs/tree-sitter-nim"
if [ -d "$TREE_SITTER_NIM_DIR" ]; then
	echo "Ensuring tree-sitter-nim parser is generated before yarn install..."
	pushd "$TREE_SITTER_NIM_DIR"

	# Generate parser if missing or outdated
	if [ ! -f "src/parser.c" ]; then
		echo "parser.c doesn't exist, generating..."
		npx tree-sitter generate
	elif [ "grammar.js" -nt "src/parser.c" ]; then
		echo "grammar.js is newer than parser.c, regenerating..."
		npx tree-sitter generate
	else
		echo "parser.c is up to date"
	fi

	popd
fi

# setup node deps
#   node modules and webpack/frontend_bundle.js
pushd "$ROOT_DIR"/node-packages
echo y | npx yarn
npx yarn add electron

pushd "$ROOT_DIR"
node_modules/.bin/webpack

rm -rf "$ROOT_DIR"/node_modules
rm -rf "$DIST_DIR"/node_modules
ln -s "$ROOT_DIR"/node-packages/node_modules "$ROOT_DIR"/node_modules
cp -r "$ROOT_DIR"/node-packages/node_modules "$DIST_DIR"/node_modules

# => now we have node_modules, and $ROOT_DIR/src/public/dist/frontend_bundle.js
# <=> $DIST_DIR/public/dist/frontend_bundle.js

popd
popd

echo "==========="
