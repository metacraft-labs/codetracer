#!/usr/bin/env bash
# Regenerate the native DWARF test fixtures.
#
# The fixtures are intentionally checked in so `cargo test` does not need a
# C toolchain. Run this script only when their C/assembly sources change.
# Determinism note: line numbers in DWARF depend on the source, so
# the tests assert on stable, well-known lines (e.g. line 24 — the
# `int sum = a + b;` line inside `add`).
#
# Usage:
#     cd src/db-backend/tests/fixtures/dwarf
#     ./rebuild.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

gcc -O0 -g \
	-no-pie -nostdlib -static \
	-Wl,-e,_start \
	-o hello.elf hello.c hello_start.S

echo "Built $(realpath hello.elf) — $(stat -c%s hello.elf) bytes"
file hello.elf || true

# Keep the optimized inline case separate: its addresses and instructions
# intentionally differ from the O0 fixture's stable stepping constants.
gcc -O2 -g -fdebug-prefix-map="$PWD"=. \
	-no-pie -nostdlib -static -Wl,-e,outer \
	-o inline.elf inline.c
