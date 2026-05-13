#!/usr/bin/env bash
# Regenerate the M-XOS-Fixture .ct trace.
#
# This script rebuilds `xos_hello.elf`, records a full-snapshot .ct
# capture via `ct_cli record`, then slims the recorded `cp0.mem` stream
# down to (PIE load segments | [stack]) before writing the committed
# fixture. The slimming step keeps the .ct well under the 2 MB budget
# the M-XOS-Fixture spec sets, without dropping any of the metadata
# sidecars the `EmulatorReplaySession` constructor consumes
# (`cp0.regs`, `cp0.maps`, `cp0.fsbase`, `meta.dat`, `debug.dat`,
# `paths.json`, `t000...`, `event log.*`).
#
# Run from this directory:
#     cd src/db-backend/tests/fixtures/xos
#     ./rebuild.sh
#
# Requirements:
#   * gcc with DWARF support
#   * `ct_cli` from codetracer-native-recorder on PATH (or set CT_CLI=)
#   * working `cargo` in the db-backend dev shell so the slimming helper
#     compiles. The helper is invoked as an integration test gated by an
#     env var so it stays out of the default `cargo test` run.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

CT_CLI="${CT_CLI:-ct_cli}"
DB_BACKEND_DIR="$here/../../.."

# 1) Compile the test program with portable DWARF.
#
# `-fdebug-prefix-map=$(pwd)=.` rewrites DW_AT_comp_dir to `.` so the
# fixture is portable across machines. Without it the fixture would
# only ever resolve back to whichever user generated it.
gcc -O0 -g -fdebug-prefix-map="$(pwd)=." -o xos_hello.elf xos_hello.c
echo "Built xos_hello.elf ($(stat -c%s xos_hello.elf) bytes)"

# 2) Record a full-snapshot .ct. The full snapshot is required so the
# resulting trace has cp0.{mem,maps,regs,fsbase} — without those the
# replay session can't seed the emulator.
TMP_FULL="$(mktemp -t xos_hello_full.XXXXXX.ct)"
rm -f "$TMP_FULL"
"$CT_CLI" record --source xos_hello.c -o "$TMP_FULL" -- ./xos_hello.elf
echo "Recorded $TMP_FULL ($(stat -c%s "$TMP_FULL") bytes)"

# 3) Slim cp0.mem and write the committed fixture. The helper is
# expressed as a gated integration test so it can reuse the production
# `CtfsReader` / `write_minimal_ctfs` pair without a separate Cargo
# example target.
cd "$DB_BACKEND_DIR"
env XOS_SLIM_SRC="$TMP_FULL" XOS_SLIM_DST="$here/xos_hello.ct" \
	cargo test --test xos_fixture_rebuild -- --ignored slim_xos_fixture --nocapture

rm -f "$TMP_FULL"
echo "Wrote $here/xos_hello.ct ($(stat -c%s "$here/xos_hello.ct") bytes)"
