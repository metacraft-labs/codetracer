#!/usr/bin/env bash
#
# dev-shell-python-recorder-ffi-pair-test.sh -- the dev shell's Python recorder
# links the trace writer built from the SAME trace-format pair its Rust is
# compiled from, whatever the recorder flake's own nested pins are.
#
# The trace writer's FFI has two halves: the Rust crates in
# `codetracer-trace-format` call it, and `codetracer-trace-format-nim` defines
# it. nix/shells/ci-base.nix compiles the recorder's Rust from this
# repository's root pair (`pythonRecorderSource`). The recorder flake's
# package also links a prebuilt writer archive
# (`CODETRACER_TRACE_WRITER_NIM_PREBUILT`), built from the recorder flake's OWN
# nested `codetracer-trace-format-nim` input. When the root pair moved to a
# writer that defines `trace_writer_mark_current_call_as_entry` and the nested
# pin did not, the extension failed its import check with `undefined symbol:
# trace_writer_mark_current_call_as_entry` and `nix develop` did not build
# (codetracer-pm issues/2026-11-05-codetracer-dev-shell-links-the-python-
# recorder-against-an-older-trace-writer-ffi.md).
#
# Asserted: the default dev shell builds with the recorder's nested
# `codetracer-trace-format-nim` overridden to `d6553925`, the revision the
# issue observed there -- it predates the writer commit that added that symbol
# (`d15a3d7`), while the root pair's Rust calls it. That is the split a lock
# bump which moves only the root pair produces, recreated without waiting for
# one. If the shell links the nested archive again, this build fails, and the
# test reports whether it failed for that reason. It first checks that the root
# pair still declares the symbol, and fails rather than pass vacuously if not.
#
# Runs `nix build` of the dev shell and compiles the recorder, so it is slow;
# it is not part of the in-shell test recipes.
#
#   bash ci/test/dev-shell-python-recorder-ffi-pair-test.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# The nested writer revision the issue observed, which lacks the symbol below.
readonly STALE_WRITER_REV=d655392565ee57e398bd29e755472bf14f35d871
readonly STALE_WRITER_URL="github:metacraft-labs/codetracer-trace-format-nim/$STALE_WRITER_REV"
readonly SYMBOL=trace_writer_mark_current_call_as_entry

# The override recreates the split only while the root pair's Rust declares
# SYMBOL. If a lock bump ever drops that call, a stale archive no longer
# disagrees with the Rust, and the build below would pass whichever writer the
# shell links. Refuse that instead of passing vacuously. The source is fetched
# from the root lock node exactly as the flake does (same rev and narHash).
root_trace_format="$(nix eval --impure --raw --expr "
  let
    lock = builtins.fromJSON (builtins.readFile $REPO/flake.lock);
    node = lock.nodes.\${lock.nodes.root.inputs.\"codetracer-trace-format\"};
  in (builtins.fetchTree (builtins.removeAttrs node.locked [ \"lastModified\" ])).outPath")"
if ! grep -q "fn $SYMBOL(" "$root_trace_format/codetracer_trace_writer_nim/src/lib.rs"; then
	echo "FAIL: the root codetracer-trace-format ($root_trace_format) no longer declares $SYMBOL," >&2
	echo "      so the nested writer at $STALE_WRITER_REV cannot recreate the FFI split." >&2
	echo "      Pick a symbol the root Rust declares and a nested revision that predates it." >&2
	exit 1
fi

system="$(nix eval --impure --raw --expr builtins.currentSystem)"
installable="$REPO#devShells.$system.default"
log="$SCRATCH/build.log"

echo "== nix build $installable"
echo "   with codetracer-python-recorder/codetracer-trace-format-nim at $STALE_WRITER_REV"
# `--no-write-lock-file`: the override is this test's, not the lock's.
if nix build --no-link --no-write-lock-file -L \
	--override-input codetracer-python-recorder/codetracer-trace-format-nim "$STALE_WRITER_URL" \
	"$installable" >"$log" 2>&1; then
	echo "the dev shell's Python recorder builds whatever writer the recorder flake pins"
	exit 0
fi

if grep -q "undefined symbol: $SYMBOL" "$log"; then
	echo "FAIL: the dev shell's Python recorder links the recorder flake's own writer archive:" >&2
	echo "      the extension calls $SYMBOL and the archive built at $STALE_WRITER_REV lacks it" >&2
else
	echo "FAIL: nix build of the dev shell failed for another reason than the FFI pair:" >&2
fi
tail -n 40 "$log" >&2
exit 1
