#!/usr/bin/env bash
# =============================================================================
# Record -> replay smoke against a PACKAGED CodeTracer artifact.
#
# Why this matters
#   The AppImage / DMG lib-checks only ran `ct --version`, which loads the
#   binary but never records or replays anything. A whole class of packaging
#   regressions -- a bundled recorder (nargo / wazero / db-backend-record)
#   that was left out, mis-RPATH'd, or can't find its siblings -- passes
#   `--version` and only shows up the first time someone actually records.
#   This script closes that gap by recording a tiny program with the SHIPPED
#   bytes and reading the recording back.
#
#   Noir is the language used on purpose: its whole toolchain (`nargo` +
#   `wazero` + `db-backend-record`) is bundled INSIDE the artifact (see
#   appimage-scripts/build_appimage.sh), so this runs with nothing installed
#   in the host/container -- unlike Python/Ruby, whose recorders are an
#   explicit out-of-artifact install (install-on-distributions.sh).
#
#   NOT A GATE. Callers run this as an informational step: a failure here is
#   allowed to ship in an internal release and be fixed by a follow-up. The
#   script still exits non-zero on failure so the signal is visible in logs.
#
# Usage
#   CT="./CodeTracer.AppImage --appimage-extract-and-run" \
#     bash scripts/test-packaged-record-replay.sh
#   CT="/path/to/CodeTracer.app/Contents/MacOS/bin/ct" \
#     bash scripts/test-packaged-record-replay.sh
#
#   CT is the command that invokes `ct`, word-split (so it may carry flags
#   like AppImage's --appimage-extract-and-run). Defaults to `ct` on PATH.
# =============================================================================

set -uo pipefail

CT="${CT:-ct}"

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

PROJ="$WORK/ct_smoke"
TRACE="$WORK/trace"
mkdir -p "$PROJ/src" "$TRACE"

# A minimal, self-contained Noir package. A small loop gives the tracer more
# than one step to record, so the read-back below is exercising real recorded
# execution rather than an empty trace.
cat >"$PROJ/Nargo.toml" <<'EOF'
[package]
name = "ct_smoke"
type = "bin"
authors = [""]

[dependencies]
EOF

cat >"$PROJ/Prover.toml" <<'EOF'
x = "0"
y = "1"
EOF

cat >"$PROJ/src/main.nr" <<'EOF'
fn main(x: Field, y: pub Field) {
    let mut acc = x;
    for _ in 0..3 {
        acc = acc + y;
    }
    assert(acc != x);
}
EOF

echo "[record-replay-smoke] ct = $CT"
echo "[record-replay-smoke] recording a Noir package with the packaged artifact"

# shellcheck disable=SC2086
if ! $CT record --output-folder "$TRACE" "$PROJ/src/main.nr"; then
	echo "[record-replay-smoke] FAIL: 'ct record' exited non-zero on the packaged artifact" >&2
	exit 1
fi

# The recorder must have produced trace bytes. `ct record -o DIR` writes the
# recording under DIR; a directory that exists but is empty means record
# reported success without materializing a trace.
if [ ! -d "$TRACE" ] || [ -z "$(ls -A "$TRACE" 2>/dev/null)" ]; then
	echo "[record-replay-smoke] FAIL: no trace was written to $TRACE" >&2
	exit 1
fi
echo "[record-replay-smoke] recorded trace:"
ls -la "$TRACE" || true

# Replay/read the recording back with the SAME packaged binary. `ct print`
# decodes the recorded execution non-interactively -- it drives the shipped
# trace reader over the shipped recorder's output, which is the packaged
# replay data path end to end.
echo "[record-replay-smoke] reading the recording back (ct print)"
# shellcheck disable=SC2086
if ! $CT print "$TRACE"; then
	echo "[record-replay-smoke] FAIL: 'ct print' could not decode the just-recorded trace" >&2
	exit 1
fi

echo "[record-replay-smoke] OK: record -> replay round-trip succeeded on the packaged artifact"
