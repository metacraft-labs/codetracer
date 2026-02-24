#!/usr/bin/env bash
set -eu

echo "=== path-probe.sh ==="
echo "shell: ${SHELL:-<unset>}"
echo "pwd: $(pwd)"
echo "PATH=$PATH"
echo "TUP=${TUP:-<unset>}"
echo "TUP_DIR=${TUP_DIR:-<unset>}"
echo -n "command -v tup: "
if command -v tup >/dev/null 2>&1; then
	command -v tup
else
	echo "<missing>"
fi
