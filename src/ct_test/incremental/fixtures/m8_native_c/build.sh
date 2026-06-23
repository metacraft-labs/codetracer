#!/usr/bin/env bash
# Build helper for the M8 native fixture.
#
# Usage: build.sh <source.c> <output-binary>
#
# Compiles a C source with symbols and -O0 (predictable, per-function machine
# code) using the dev shell's C compiler. The caller passes a SPECIFIC source
# file and output path so the M8 tests can build the pristine fixture, build an
# EDITED copy (executed-function change, unexecuted-function change), all in a
# temp dir, without committing the binary.
#
# Flags rationale (same as the M7 fixture):
#   -O0  : no optimisation — each C function maps to a stable, separate block of
#          machine code (no inlining/merging) so per-function precision holds.
#   -g   : emit symbols (DWARF) so nm/otool can find each function.
#   -fno-stack-protector / -fno-asynchronous-unwind-tables : trim incidental
#          codegen so the per-function bytes are the function's own logic.
set -euo pipefail

src="${1:?source file required}"
out="${2:?output binary path required}"

# CC may be set by the dev shell; default to cc on PATH.
cc="${CC:-cc}"

"$cc" -O0 -g -fno-stack-protector -fno-asynchronous-unwind-tables \
  -o "$out" "$src"
