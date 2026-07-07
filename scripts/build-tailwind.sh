#!/usr/bin/env bash
# Generate isonim's build/tailwind-styles.json covering BOTH isonim's own
# source and CodeTracer's frontend.
#
# Why this exists: Tailwind v4 auto-detects content from the project root
# but only for recognized file types — it never scans `.nim` files (see the
# `--content` note in isonim/tools/tailwind-extract.mjs). isonim's own
# `just build-tailwind` runs the extract with no `--content`, so it captures
# only isonim's recognized files and MISSES every Tailwind utility class
# used from a `.nim` file in either repo. Because `expandTailwindClasses`
# silently skips classes it doesn't find, a frontend-only class would
# produce zero CSS with no warning. CodeTracer's frontend
# (`src/frontend/ui_js.nim` → `isonim/dsl/ui`/`isonim/dsl/tailwind`) is the
# primary consumer, so the extract must be driven from here with explicit
# `--content` globs for both trees.
#
# The output lands in isonim/build/tailwind-styles.json (the tool's default
# out-dir), which is exactly where `isonim/dsl/tailwind` `staticRead`s it at
# Nim compile time, so no `-d:tailwindStylesPathOverride` is needed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

isonim_root=""
for candidate in "$CT_ROOT/../isonim" "$CT_ROOT/../../isonim"; do
	if [ -f "$candidate/tools/tailwind-extract.mjs" ]; then
		isonim_root="$(cd "$candidate" && pwd)"
		break
	fi
done

if [ -z "$isonim_root" ]; then
	echo "Error: isonim sibling not found (expected ../isonim)." >&2
	exit 1
fi

# isonim's node_modules provides the tailwindcss CLI the extract shells out
# to; the generated input CSS resolves `@import "tailwindcss"` against it.
if [ ! -d "$isonim_root/node_modules" ]; then
	(cd "$isonim_root" && npx yarn install --frozen-lockfile)
fi

# Pass the two source trees as directory `@source` roots (absolute, so they
# are emitted verbatim regardless of the tool's cwd). Tailwind v4's
# directory scan walks each tree the same way its default project-root
# auto-detection does — which DOES pick up class names in `.nim` files
# (e.g. isonim's own `flex-grow`/`flex-shrink` live only in `.nim`). A bare
# `**/*.nim` glob would miss them, so scan the directories instead:
#   * isonim's tree (reproduces isonim's own `build-tailwind` coverage), and
#   * CodeTracer's frontend (the classes this build actually adds).
(cd "$isonim_root" && node tools/tailwind-extract.mjs \
	--content "$isonim_root/src" \
	--content "$CT_ROOT/src/frontend")
