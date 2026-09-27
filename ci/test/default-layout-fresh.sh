#!/usr/bin/env bash
# default-layout-fresh.sh — the committed desktop default layout is what the
# shared default arrangement generates (PLAT-45 deliverable 7).
#
# `src/config/default_layout.json` is no longer authored. It is the GoldenLayout
# translation of `headless_app/layout_model.sharedDefaultLayout()` — the one
# arrangement every front-end opens with — written by
# `src/frontend/headless_app/generate_default_layout.nim` through
# `desktop_panes.layoutNodeToGoldenConfig`. It stays committed because the
# desktop embeds it (`staticRead` in `index/config.nim` and `ui/layout.nim`) and
# every build variant publishes it into `<prefix>/config/`.
#
# A committed generated file goes stale in two ways, and this gate catches
# both by regenerating and comparing byte for byte:
#   * someone edits the JSON by hand (the desktop's default then differs from
#     the terminal's and GPUI's, which is exactly the three-defaults state
#     PLAT-45 removed);
#   * someone edits `sharedDefaultLayout()` and does not regenerate (the
#     terminal and GPUI move, the desktop does not).
#
# Usage: ci/test/default-layout-fresh.sh      (from anywhere, inside the dev shell)
# Remedy: just generate-default-layout
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

nim c --hints:off --warnings:off --verbosity:0 \
  --nimcache:"$scratch/nimcache" -o:"$scratch/generate_default_layout" \
  src/frontend/headless_app/generate_default_layout.nim >"$scratch/build.log" 2>&1 || {
    echo "FAIL: the default-layout generator does not build:" >&2
    tail -20 "$scratch/build.log" >&2
    exit 1
  }

if ! "$scratch/generate_default_layout" --check=src/config/default_layout.json; then
  "$scratch/generate_default_layout" --out="$scratch/generated.json"
  diff -u src/config/default_layout.json "$scratch/generated.json" | head -40 >&2 || true
  echo "remedy: just generate-default-layout" >&2
  exit 1
fi
