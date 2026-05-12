#!/usr/bin/env bash
# Regenerate the `hello.elf` DWARF test fixture (M-DWARF-1).
#
# The fixture is intentionally checked in so `cargo test` does not need a
# C toolchain. Run this script only when `hello.c` or `hello_start.S`
# change. Determinism note: line numbers in DWARF depend on `hello.c`, so
# the test asserts on stable, well-known lines (e.g. line 27 — the
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
