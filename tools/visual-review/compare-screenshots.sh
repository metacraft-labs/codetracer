#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  tools/visual-review/compare-screenshots.sh reference.png current.png output-prefix

Writes:
  <output-prefix>-reference-normalized.png
  <output-prefix>-current-normalized.png
  <output-prefix>-diff.png
  <output-prefix>-metrics.txt
EOF
}

if [[ $# -ne 3 ]]; then
  usage
  exit 2
fi

reference="$1"
current="$2"
prefix="$3"

if [[ ! -f "$reference" ]]; then
  echo "Missing reference image: $reference" >&2
  exit 2
fi

if [[ ! -f "$current" ]]; then
  echo "Missing current image: $current" >&2
  exit 2
fi

mkdir -p "$(dirname "$prefix")"

current_size="$(magick identify -format '%wx%h' "$current")"
ref_norm="${prefix}-reference-normalized.png"
cur_norm="${prefix}-current-normalized.png"
diff_png="${prefix}-diff.png"
metrics="${prefix}-metrics.txt"

magick "$reference" -resize "${current_size}!" "$ref_norm"
magick "$current" -resize "${current_size}!" "$cur_norm"
magick "$ref_norm" "$cur_norm" -compose difference -composite -auto-level "$diff_png"

{
  echo "reference: $reference"
  echo "current: $current"
  echo "normalized-size: $current_size"
  echo -n "rmse: "
  magick compare -metric RMSE "$ref_norm" "$cur_norm" null: 2>&1 || true
  echo
  echo -n "mae: "
  magick compare -metric MAE "$ref_norm" "$cur_norm" null: 2>&1 || true
  echo
  echo -n "pae: "
  magick compare -metric PAE "$ref_norm" "$cur_norm" null: 2>&1 || true
  echo
} > "$metrics"

cat "$metrics"
