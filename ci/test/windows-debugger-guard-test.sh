#!/usr/bin/env bash
# ci/test/windows-debugger-guard-test.sh -- with Assert-NonInteractiveDebugger
# applied, nothing can open the PowerShell debugger, so a step ends on its
# error instead of waiting on a "[DBG]" prompt that nothing will answer.
#
# The runner cancels a step with Ctrl+C, then Ctrl+Break, and pwsh enters
# its debugger on Ctrl+Break (origin-DAP Windows, run 44940608244, job
# 136956922171). Wait-Debugger is the same entry point a test can call
# portably. Stdin is held open, as on a runner, so an unguarded break BLOCKS.
# The unguarded case is the control: it must still block, or this test proves
# nothing.
set -euo pipefail
cd "$(dirname "$0")/../.."
pwsh="$(command -v pwsh || true)"
if [ -z "$pwsh" ] && command -v nix >/dev/null 2>&1; then
	# The Linux lint shell carries no PowerShell; take this flake's nixpkgs one.
	pwsh="$(nix build --no-link --print-out-paths --inputs-from . nixpkgs#powershell 2>/dev/null | head -n1)/bin/pwsh"
	[ -x "$pwsh" ] || pwsh=""
fi
if [ -z "$pwsh" ]; then
	echo "windows-debugger-guard-test: FAIL: no pwsh on PATH and none from nixpkgs" >&2
	exit 1
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# The function, extracted from the real file, so a change to it is what runs.
awk '/^function Assert-NonInteractiveDebugger \{/{f=1} f{print} f&&/^\}/{exit}' \
	non-nix-build/windows/toolchain-utils.ps1 >"$work/guard.ps1"
grep -q 'SetDebugMode' "$work/guard.ps1" || {
	echo "windows-debugger-guard-test: FAIL: Assert-NonInteractiveDebugger was not extracted" >&2
	exit 1
}
cat >"$work/step.ps1" <<'PS'
param([switch]$Guard)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/guard.ps1"
if ($Guard) { $null = Assert-NonInteractiveDebugger }
Wait-Debugger
throw "the step's real error"
PS
run() { # $1 = extra argument; prints the exit status
	local rc=0
	# Stdin held open by sleep, as a runner's is; timeout bounds a block.
	sleep 60 | timeout 20 "$pwsh" -command ". '$work/step.ps1' $1" >"$work/out" 2>&1 || rc=$?
	echo "$rc"
}
failures=0
rc="$(run "")"
if [ "$rc" = 124 ] && grep -q 'DBG' "$work/out"; then
	echo "  ok   control: unguarded, the break opens a [DBG] prompt and the step blocks"
else
	echo "  FAIL control: unguarded, expected a blocked [DBG] prompt (timeout 124), got rc=$rc"
	failures=$((failures + 1))
fi
rc="$(run "-Guard")"
# Guarded, the break request is itself an error (the debugger is disabled),
# so under ErrorActionPreference=Stop the step ends there, non-zero.
if [ "$rc" != 0 ] && [ "$rc" != 124 ] && ! grep -q 'DBG' "$work/out"; then
	echo "  ok   guarded: no prompt, and the step fails at once, non-zero (rc=$rc)"
else
	echo "  FAIL guarded: expected an immediate non-zero exit and no prompt, got rc=$rc"
	sed 's/^/       /' "$work/out" | head -5
	failures=$((failures + 1))
fi
[ "$failures" -eq 0 ] && echo "windows-debugger-guard-test: ok" || exit 1
