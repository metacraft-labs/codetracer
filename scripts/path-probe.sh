#!/usr/bin/env bash
# NOT-A-CI-GATE: a diagnostic, not a check.
#
# It prints SHELL, PATH, TUP, TUP_DIR and `command -v tup`, and asserts
# none of them. A person reads its output while debugging a build.
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
