#!/usr/bin/env bash
# default-layout-fresh.sh — the committed desktop default layout is what the
# shared default arrangement generates (PLAT-45 deliverable 7).
#
# `src/config/default_layout.json` is no longer authored. It is the GoldenLayout
# translation of `headless_app/layout_model.sharedBundledLayout()` — the tree
# every mode's default is derived from — written by
# `src/frontend/headless_app/generate_default_layout.nim` through
# `desktop_panes.layoutNodeToGoldenConfig`. It stays committed because the
# desktop embeds it (`staticRead` in `index/config.nim` and `ui/layout.nim`) and
# every build variant publishes it into `<prefix>/config/`.
#
# PLAT-47: a SECOND generated file,
# `src/frontend/headless_app/shared_default_layout.generated.json`, is the
# desktop's DEBUG-mode default (the bundled tree through the desktop's own
# per-mode derivation) read back into the shared vocabulary — the arrangement
# the terminal and the GPUI window open with. It goes stale the same two ways
# (a hand edit, or a change to the bundled tree / the per-mode tables that was
# not regenerated) and is checked by the same run.
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

# A NODE program (PLAT-47): the second output is the desktop's debug-mode
# default, derived by the desktop's own JavaScript
# (`index/mode_default_layout.modeDefaultLayout`), so the generator runs it
# rather than re-implementing it.
nim js -d:nodejs --hints:off --warnings:off --verbosity:0 \
  --nimcache:"$scratch/nimcache" -o:"$scratch/generate_default_layout.js" \
  src/frontend/headless_app/generate_default_layout.nim >"$scratch/build.log" 2>&1 || {
    echo "FAIL: the default-layout generator does not build:" >&2
    tail -20 "$scratch/build.log" >&2
    exit 1
  }

if ! node "$scratch/generate_default_layout.js" --check=.; then
  mkdir -p "$scratch/out/src/config" "$scratch/out/src/frontend/headless_app"
  node "$scratch/generate_default_layout.js" --out="$scratch/out"
  for f in src/config/default_layout.json \
           src/frontend/headless_app/shared_default_layout.generated.json; do
    diff -u "$f" "$scratch/out/$f" | head -40 >&2 || true
  done
  echo "remedy: just generate-default-layout" >&2
  exit 1
fi
