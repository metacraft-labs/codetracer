#!/usr/bin/env bash
# =============================================================================
# test-check-platform-lock-pins.sh — the arms of
# `scripts/check-platform-lock-pins.sh`, the refusals included.
#
# A gate that cannot fail is indistinguishable from no gate, so each case below
# states the wrong behaviour it detects and the refusals are asserted as hard
# as the passes. A `check-platform-lock-pins.sh` that exited 0 unconditionally
# passes two of these six and fails the other four.
#
# The fixtures are built by rewriting THIS checkout's committed `repro.lock`,
# so the parsing under test meets the real file shape -- one `deps = [...]`
# line of inline tables with a `self = "true"` entry among them -- rather than
# a hand-written miniature that could drift from it.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK="$SCRIPT_DIR/check-platform-lock-pins.sh"
CANONICAL="$CT_ROOT/repro.lock"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

# Assert an exit code, and optionally that the output names a given string.
#   $1 case  $2 expected rc  $3 expected substring ("" = any)  $4.. argv
expect() {
	local name="$1" want_rc="$2" want_text="$3"
	shift 3
	local out rc=0
	out="$(bash "$CHECK" "$@" 2>&1)" || rc=$?
	if [ "$rc" -ne "$want_rc" ]; then
		echo "FAIL: $name: expected exit $want_rc, got $rc" >&2
		printf '%s\n' "$out" | sed 's/^/    /' >&2
		failures=$((failures + 1))
		return
	fi
	if [ -n "$want_text" ] && ! grep -qF -- "$want_text" <<<"$out"; then
		echo "FAIL: $name: exit $rc was right but the output never says" >&2
		echo "  '$want_text'" >&2
		printf '%s\n' "$out" | sed 's/^/    /' >&2
		failures=$((failures + 1))
		return
	fi
	echo "ok: $name"
}

# A revision that is really in the committed lock, and a sibling to move it on.
drift_sibling="isonim-gpui"
drift_rev="$(grep '^deps = \[' "$CANONICAL" | tr '{' '\n' |
	sed -n "s/.*name = \"$drift_sibling\".*revision = \"\([^\"]*\)\".*/\1/p" |
	head -1)"
if [ -z "$drift_rev" ]; then
	echo "FAIL: fixture: $CANONICAL has no $drift_sibling dependency to move" >&2
	exit 1
fi

# 1. Identical files agree.
#    Detects a gate that refuses everything, which would make the per-platform
#    lock unusable and is invisible to a refusal-only suite.
cp "$CANONICAL" "$work/identical.lock"
expect "identical deps agree" 0 "" "$work/identical.lock" "$CANONICAL"

# 2. A different `packages` line and `platform` is NOT drift.
#    This is the whole point of a per-platform solve; a gate that compared the
#    files, or their digests, would refuse every legitimate native lock.
sed -e 's/^platform = "amd64-linux"/platform = "arm64-macosx"/' \
	-e 's/^packages = \[.*$/packages = [{ name = "clang", version = "99.0.0", source = "clang", selection = "selected" }]/' \
	"$CANONICAL" >"$work/other-platform.lock"
expect "a different platform and package set is not drift" 0 "" \
	"$work/other-platform.lock" "$CANONICAL"

# 3. One moved dependency revision IS drift, and is named.
#    The case the gate exists for.
sed "s/$drift_rev/0000000000000000000000000000000000000000/g" \
	"$CANONICAL" >"$work/moved-pin.lock"
expect "a moved dependency revision refuses, naming the sibling" 1 \
	"$drift_sibling" "$work/moved-pin.lock" "$CANONICAL"

# 4. ...and the escape hatch is an escape hatch, not a second default.
out_rc=0
CODETRACER_ALLOW_PLATFORM_LOCK_PIN_DRIFT=1 \
	bash "$CHECK" "$work/moved-pin.lock" "$CANONICAL" >/dev/null 2>&1 || out_rc=$?
if [ "$out_rc" -ne 0 ]; then
	echo "FAIL: the escape hatch did not let a drifted pair through" >&2
	failures=$((failures + 1))
else
	echo "ok: CODETRACER_ALLOW_PLATFORM_LOCK_PIN_DRIFT lets it through"
fi

# 5. A DIFFERENT `self` revision is not drift.
#    Each lock records the commit it was itself refreshed on, and the two are
#    refreshed at different times by design. A gate that compared the `self`
#    entry would refuse every honest pair, so this is the case that keeps the
#    exclusion from being quietly dropped.
self_rev="$(grep '^deps = \[' "$CANONICAL" | tr '{' '\n' |
	grep 'self = "true"' | sed -n 's/.*revision = "\([^"]*\)".*/\1/p' | head -1)"
if [ -z "$self_rev" ]; then
	echo "FAIL: fixture: $CANONICAL has no self entry" >&2
	failures=$((failures + 1))
else
	python3 - "$CANONICAL" "$work/other-self.lock" "$self_rev" <<'PY'
import sys
src, dst, self_rev = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src).read()
out = []
for line in text.splitlines(keepends=True):
    if line.startswith("deps = ["):
        # Rewrite the revision of the self record only, leaving every other
        # occurrence of that sha (integrity fields included) alone elsewhere.
        parts = line.split("{")
        parts = [
            p.replace(self_rev, "1" * 40) if 'self = "true"' in p else p
            for p in parts
        ]
        line = "{".join(parts)
    out.append(line)
open(dst, "w").write("".join(out))
PY
	expect "a different self revision is not drift" 0 "" \
		"$work/other-self.lock" "$CANONICAL"
fi

# 6. A missing file is a usage error, not agreement.
#    Detects a gate that reads an absent lock as an empty dep set.
expect "a missing lock is a usage error" 2 "no such lock" \
	"$work/nope.lock" "$CANONICAL"

if [ "$failures" -ne 0 ]; then
	echo "" >&2
	echo "test-check-platform-lock-pins.sh: $failures case(s) failed" >&2
	exit 1
fi
echo ""
echo "test-check-platform-lock-pins.sh: all cases passed"
