#!/usr/bin/env bash
# A shell sample.
set -euo pipefail

readonly OUT="${1:-/tmp/out}"
count=0
names=("alpha" 'beta' gamma)

log() {
  local level="$1"; shift
  echo "[$level] $*" >&2
}

for name in "${names[@]}"; do
  if [[ "$name" == a* ]]; then
    count=$((count + 1))
  elif [ -z "$name" ]; then
    continue
  fi
done

case "$count" in
  0) log INFO "none" ;;
  *) log INFO "found $count" ;;
esac

while read -r line; do
  printf '%s\n' "$line"
done < <(ls -1 "$OUT" 2>/dev/null)

cat <<EOT > "$OUT/summary.txt"
count=$count
EOT
export COUNT=$count
exit 0
