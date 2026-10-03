#!/usr/bin/env bash
# Regenerate the M-XOS-Fixture .ct trace.
#
# This script rebuilds `xos_hello.elf`, records it with
# `ct_cli record --attach=premain`, then slims the recorded `cp0.mem`
# snapshot payload down to (PIE load segments | [stack]) before writing the
# committed fixture. The slimming step keeps the .ct well under the 2 MB
# budget the M-XOS-Fixture spec sets, without dropping any of the metadata
# sidecars the `EmulatorReplaySession` constructor consumes
# (`cp0.regs`, `cp0.maps`, `cp0.fsbase`, `meta.dat`, `debug.dat`,
# `paths.dat`, `t000...`, `eventlog.*`).
#
# `--attach=premain` is required: the emulator session starts from the
# `main` boundary that path records (`cp0.regs` + `cp0.mem`). The Linux
# default, `--attach=instruction0`, records the execve-stop boundary
# (`bootelf.*`, `cp.entry.*`) instead, which the session refuses.
#
# The program runs under a scrubbed environment: the kept `[stack]` region
# holds its `envp` strings and the trace's `guest.env` the whole
# environment, so a recording made from a CI job or a developer shell would
# otherwise commit that host's variables, credentials included. The slimming
# helper refuses a recording that still carries one.
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

# 2) Record from the `main` boundary (`--attach=premain`), which writes
# the cp0.{mem,maps,regs,fsbase} members the replay session seeds the
# emulator from, under a scrubbed environment (see the header).
TMP_FULL="$(mktemp -t xos_hello_full.XXXXXX.ct)"
rm -f "$TMP_FULL"
CT_CLI_PATH="$(command -v "$CT_CLI")"
env -i PATH=/usr/bin:/bin HOME=/nonexistent LANG=C \
	"$CT_CLI_PATH" record --attach=premain --source xos_hello.c -o "$TMP_FULL" -- ./xos_hello.elf
rm -f "$TMP_FULL".bootstrap_mode "$TMP_FULL".syncrefused "$TMP_FULL".syncsites
echo "Recorded $TMP_FULL ($(stat -c%s "$TMP_FULL") bytes)"

# 3) Slim cp0.mem and write the committed fixture. The helper is
# expressed as a gated integration test so it can reuse the production
# `CtfsReader` / snapshot-payload / `write_minimal_ctfs` code without a
# separate Cargo example target. It fails, rather than writing an unslimmed
# fixture, when the recording has no cp0.mem payload or nothing to drop.
#
# The helper writes to a fresh path that must exist afterwards: a filter
# that matched no test would otherwise exit 0 and leave the old fixture.
SLIM_OUT="$(mktemp -t xos_hello_slim.XXXXXX.ct)"
rm -f "$SLIM_OUT"
cd "$DB_BACKEND_DIR"
env XOS_SLIM_SRC="$TMP_FULL" XOS_SLIM_DST="$SLIM_OUT" \
	cargo test --test xos_fixture_rebuild -- --ignored --exact slim_xos_fixture --nocapture
if [ ! -s "$SLIM_OUT" ]; then
	echo "error: the slimming helper did not write $SLIM_OUT" >&2
	exit 1
fi
mv "$SLIM_OUT" "$here/xos_hello.ct"

rm -f "$TMP_FULL"
echo "Wrote $here/xos_hello.ct ($(stat -c%s "$here/xos_hello.ct") bytes)"
