#!/usr/bin/env bash
# =============================================================================
# check-platform-lock-pins.sh — the two committed solve files must pin the same
# source revisions.
#
# WHY THIS EXISTS
# ---------------
# `repro.lock` is the `amd64-linux` solve and `locks/arm64-macosx.lock` is the
# Apple-arm one, and `scripts/build-once.sh` binds the second with `--lock` on
# an arm64 darwin host (codetracer-pm
# spec/Architecture/Build-Outputs-And-Path-Resolution.md section 4.6).
#
# A `packages` set differs between them legitimately: that is the whole point of
# a per-platform solve. A DEPENDENCY REVISION does not. Section 4.6's own words
# are that "selecting a file does not change its platform or silently solve
# again", and nothing about `arm64-macosx` makes `isonim` a different commit. So
# when the two files name different revisions for one dependency, one of them is
# wrong, and the consequence is a macOS build compiling source that CI never
# compiles -- exiting 0, with nothing said.
#
# That is not hypothetical. Measured at `agents` `0cfb1db300`, the two locks
# disagreed about 7 of 55 dependencies, six of them with the darwin file AHEAD
# and one (`reprobuild`, 5 commits) BEHIND -- including a Reprobuild revision
# `flake.lock` does not pin, which section 4.6 explicitly requires it to match.
# Filed as codetracer-pm
# issues/2026-11-03-six-native-lock-sibling-pins-diverged-unchecked-and-the-seventh-is-caught-only-on-a-mac.md.
#
# WHY NOTHING ELSE CATCHES IT
# ---------------------------
# Every mechanism that keeps a committed lock honest is keyed on the single path
# `<project>/repro.lock`: the commit-time sibling re-pin, `repro lock refresh`,
# the pre-push gate, and the H1/H2 consistency rules that relate a lock to
# `flake.lock`. None of them has heard of a second file (reprobuild-pm
# issues/2026-11-03-codetracers-two-committed-locks-pin-different-source-revisions-because-nothing-maintains-the-second.md).
# The Electron freshness digest hashes both files, so it notices a change to
# either and cannot notice a disagreement between them.
#
# Two pins are an exception: `test-build-once-platform-lock.sh` also relates
# each lock's `reprobuild` and `reprobuild-packages` entries to `flake.lock`.
# That assertion used to be gated to an Apple-arm host for the native lock, and
# the drift above is what that gate let through; it now runs everywhere, because
# once this check holds the native pins equal to `repro.lock`'s, a native pin
# that disagrees with `flake.lock` is wrong on every host.
#
# Relating the two locks TO EACH OTHER asks whether they name the same source,
# which is the same question on every host, so the committed-lock test runs this
# check in CI's `just test` as well as `build-once.sh` running it before a
# native build. It is also the half that reaches a dependency `flake.lock` does
# not name: of the seven that had drifted, six were flake inputs -- and
# `flake.lock` agreed with `repro.lock` on all six, which is what settled that
# the native file was the one in the wrong -- while `isonim-freya` is not an
# input and could only be caught here.
#
# WHAT IT COMPARES
# ----------------
# The `name` and `revision` of every non-`self` entry of each file's `deps`
# array. The `self` entry is excluded deliberately: it records the commit its
# own lock was last refreshed on, and the two are refreshed at different times
# by design.
#
# Two empty dep sets count as agreement. A file with no `deps` line has nothing
# to compare, which is the honest reading and is also what the driver's own
# recording-stub tests write.
#
# USAGE
# -----
#   check-platform-lock-pins.sh [<native-lock>] [<canonical-lock>]
#
# Both default to this checkout's committed files. Exit 0 they agree, 1 they
# do not (every difference named), 2 a file is missing.
#
# CODETRACER_ALLOW_PLATFORM_LOCK_PIN_DRIFT=1 downgrades the refusal to a
# warning, for the case where the older dependency set is what you meant to
# build.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

native_lock="${1:-$CT_ROOT/locks/arm64-macosx.lock}"
canonical_lock="${2:-$CT_ROOT/repro.lock}"

# `<name> <revision>` per non-self `deps` entry, sorted.
#
# The whole `deps` array is one line of TOML inline tables, so `{` is the
# record separator within it; `packages` is a separate line and is not read.
# The sort is C-collated so both sides order identically whatever LC_COLLATE
# the caller has.
lock_deps() {
	grep '^deps = \[' "$1" 2>/dev/null |
		tr '{' '\n' |
		grep -v 'self = "true"' |
		sed -n 's/.*name = "\([^"]*\)".*revision = "\([^"]*\)".*/\1 \2/p' |
		LC_ALL=C sort
}

for f in "$native_lock" "$canonical_lock"; do
	if [ ! -f "$f" ]; then
		echo "check-platform-lock-pins.sh: no such lock: $f" >&2
		exit 2
	fi
done

drift="$(comm -3 \
	<(lock_deps "$canonical_lock") \
	<(lock_deps "$native_lock") |
	awk -v left="$(basename "$canonical_lock")" \
		-v right="$(basename "$native_lock")" '
		/^\t/ { sub(/^\t/, ""); print "    " right ": " $0; next }
		      { print "    " left ": " $0 }')"

if [ -z "$drift" ]; then
	exit 0
fi

{
	echo "check-platform-lock-pins.sh: the two committed solve files pin"
	echo "  different source revisions. A revision is a source fact, not a"
	echo "  platform fact, so one of these files is wrong -- and nothing in the"
	echo "  workspace maintains the native one for you."
	echo ""
	printf '%s\n' "$drift"
	echo ""
	echo "  $(basename "$canonical_lock") is the one the commit hook and the"
	echo "  pre-push gate keep current, so it is normally the right side."
	echo "  Re-solve the native file ON an arm64 darwin host:"
	# One line, so it can be copied as it stands -- and a trailing backslash
	# inside a quoted echo is what shellcheck SC1003 reads as a mis-escaped
	# quote.
	echo '    repro lock refresh . --lock locks/arm64-macosx.lock --platform=arm64-macosx'
	echo "  Build off it as it stands:"
	echo "    CODETRACER_ALLOW_PLATFORM_LOCK_PIN_DRIFT=1"
} >&2

if [ -n "${CODETRACER_ALLOW_PLATFORM_LOCK_PIN_DRIFT:-}" ]; then
	echo "check-platform-lock-pins.sh: proceeding anyway --" >&2
	echo "  CODETRACER_ALLOW_PLATFORM_LOCK_PIN_DRIFT is set." >&2
	exit 0
fi
exit 1
