#!/usr/bin/env bash
# record-calc-fixture.sh — record the terminal lanes' `calc` fixture into
# `test-logs/tui-fixtures/` through their own fixture provider, when this
# checkout has none yet (a CI job that runs no terminal lane first). A no-op
# when it is already recorded. The capture recipes that open `calc` call it.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"
if ls -d test-logs/tui-fixtures/calc-* >/dev/null 2>&1; then
	exit 0
fi
mkdir -p test-logs
work="$(mktemp -d "$repo/test-logs/record-calc.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cat >"$work/record_calc.nim" <<'NIM'
import fixtures/fixture_provider
let r = resolveFixture("calc")
if r.outcome != foRecorded:
  quit("could not record the calc fixture: " & r.detail, 1)
echo r.tracePath
NIM
nim c -r --hints:off --warnings:off --path:"$repo/src/frontend/tui/tests" \
	--nimcache:"$work/nc" -o:"$work/record_calc" "$work/record_calc.nim"
