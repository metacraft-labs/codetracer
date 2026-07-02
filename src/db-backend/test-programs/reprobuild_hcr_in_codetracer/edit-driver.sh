#!/usr/bin/env bash
set -euo pipefail

project_dir="${1:-}"
if [ -z "$project_dir" ]; then
	echo "usage: edit-driver.sh <project-dir>" >&2
	exit 64
fi

src="$project_dir/generations/patchable_gen1.c"
dst="$project_dir/src/patchable.c"
if [ ! -f "$src" ]; then
	echo "generation 1 source not found: $src" >&2
	exit 66
fi
if [ ! -f "$dst" ]; then
	echo "generation 0 source not found: $dst" >&2
	exit 66
fi

mkdir -p "$project_dir/build"
cp "$src" "$dst"

if command -v shasum >/dev/null 2>&1; then
	shasum -a 256 "$dst" >"$project_dir/build/source-generation-1.sha256"
elif command -v sha256sum >/dev/null 2>&1; then
	sha256sum "$dst" >"$project_dir/build/source-generation-1.sha256"
else
	cksum "$dst" >"$project_dir/build/source-generation-1.cksum"
fi
