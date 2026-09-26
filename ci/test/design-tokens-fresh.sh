#!/usr/bin/env bash
# design-tokens-fresh.sh — the committed design-token outputs are what the
# pinned design system generates.
#
# `scripts/tokens-to-styl.sh` turns ONE revision of codetracer-design-system
# into TWO committed outputs, in one resolver run:
#
#   * src/frontend/styles/generated/*.styl        — the desktop's stylesheets
#   * src/frontend/styles/generated/design_tokens.nim — the terminal
#     front-end's resolved token constants (Dark and Light)
#
# Both are generated files that are committed, so each can go stale in two
# ways: someone edits the output by hand (the stylus was, once: fc3a76ed5
# changed two `brand-600`s to `brand-500` while the pinned design system still
# said 600), or someone moves the submodule pin without regenerating. Either
# way the desktop and the terminal stop painting the same revision. This gate
# regenerates both from EXACTLY the pinned revision into a scratch directory
# and diffs them against the tree; any difference fails, naming the files.
#
# WHERE THE PINNED REVISION COMES FROM. The pin is the gitlink of
# `libs/codetracer-design-system` in the INDEX (so a staged pin bump is checked
# against the outputs it is staged with). The source is, in order:
#   1. the checked-out submodule, when its HEAD is the pinned commit;
#   2. a workspace sibling `../codetracer-design-system` that has the commit;
#   3. a shallow fetch of the pinned commit from the `.gitmodules` URL.
# A checkout at a DIFFERENT commit is never used: it would answer the question
# for a revision nobody pinned.
#
# Usage: ci/test/design-tokens-fresh.sh            (from the repo root)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

sub=libs/codetracer-design-system
generated=src/frontend/styles/generated

pinned="$(git ls-files -s -- "$sub" | awk '$1 == "160000" {print $2}')"
if [ -z "$pinned" ]; then
  echo "FAIL: $sub is not a submodule gitlink in the index" >&2
  exit 1
fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
src=""

if [ -e "$sub/.git" ] &&
   [ "$(git -C "$sub" rev-parse HEAD 2>/dev/null || true)" = "$pinned" ]; then
  src="$sub"
  origin="checked-out submodule"
else
  sibling="$repo_root/../codetracer-design-system"
  if [ -d "$sibling/.git" ] &&
     git -C "$sibling" cat-file -e "${pinned}^{commit}" 2>/dev/null; then
    mkdir -p "$scratch/ds"
    git -C "$sibling" archive "$pinned" | tar -x -C "$scratch/ds"
    src="$scratch/ds"
    origin="workspace sibling ../codetracer-design-system"
  else
    url="$(git config -f .gitmodules "submodule.$sub.url")"
    git init -q "$scratch/fetch"
    if git -C "$scratch/fetch" fetch -q --depth 1 "$url" "$pinned" 2>/dev/null; then
      mkdir -p "$scratch/ds"
      git -C "$scratch/fetch" archive "$pinned" | tar -x -C "$scratch/ds"
      src="$scratch/ds"
      origin="shallow fetch of $url"
    fi
  fi
fi

if [ -z "$src" ]; then
  echo "FAIL: cannot obtain codetracer-design-system at the pinned $pinned" >&2
  echo "  remedy: git submodule update --init $sub" >&2
  exit 1
fi

echo "design system: $pinned ($origin)"
bash scripts/tokens-to-styl.sh "$src" "$scratch/out" \
  --nim-out "$scratch/out/design_tokens.nim" >/dev/null

status=0
for f in "$scratch/out"/*; do
  name="$(basename "$f")"
  if [ ! -f "$generated/$name" ]; then
    echo "STALE: $generated/$name is missing (the generator produces it)" >&2
    status=1
  elif ! cmp -s "$f" "$generated/$name"; then
    echo "STALE: $generated/$name differs from what $pinned generates:" >&2
    diff -u "$generated/$name" "$f" | head -20 >&2 || true
    status=1
  fi
done
for f in "$generated"/*; do
  name="$(basename "$f")"
  if [ ! -e "$scratch/out/$name" ]; then
    echo "STALE: $generated/$name is not produced by the generator" >&2
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  echo "remedy: just sync-design-tokens (regenerates both outputs)" >&2
  exit 1
fi
count="$(ls "$scratch/out" | wc -l)"
echo "OK: $count generated files match the pinned design system"
