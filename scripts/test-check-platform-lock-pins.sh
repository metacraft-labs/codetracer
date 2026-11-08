#!/usr/bin/env bash
# =============================================================================
# test-check-platform-lock-pins.sh — the arms of
# `scripts/check-platform-lock-pins.sh`, the refusals included.
#
# A gate that cannot fail is indistinguishable from no gate, so each case below
# states the wrong behaviour it detects and the refusals are asserted as hard
# as the passes. A `check-platform-lock-pins.sh` that exited 0 unconditionally
# passes two of these seven and fails the other five.
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

# 7. The drift list names every drifted pin whatever the caller's locale.
#
#    The defect: the pins are sorted with `LC_ALL=C sort` and were once
#    compared with a plain `comm`, which collates by the caller's locale.
#    Where the two collations disagree, `comm` reads its input as unsorted and
#    pairs nothing, so the script refused the build while naming not one
#    dependency -- a refusal with no remedy in it. Fixed by `1f862273b7`
#    (`LC_ALL=C comm`), and nothing until now would notice it coming back:
#    cases 1-6 all pass with the defect present, because each drifts a single
#    pin over a name set whose two orderings happen to agree.
#
#    The exit code does NOT catch this -- the defect refuses too. What catches
#    it is that every drifted dependency is NAMED, so that is what is asserted.
#
#    The locale is found at run time rather than written in, because which
#    locales disagree with C is libc's business, not ours. Measured on
#    aarch64-darwin 2026-11-08: `en_US.UTF-8` orders these names exactly as C
#    does, so the obvious choice proves nothing here, while 29 of the host's
#    locales do differ (`nb_NO.UTF-8`, `sv_FI.UTF-8`, ...). Against a copy of
#    the script with `LC_ALL=C` removed from `comm`, `nb_NO.UTF-8` named 0 of 6
#    drifted deps where C named 6 of 6.
drift_names="$(grep '^deps = \[' "$CANONICAL" | tr '{' '\n' |
	grep -v 'self = "true"' |
	sed -n 's/.*name = "\([^"]*\)".*/\1/p')"
# Upper-case initials and embedded hyphens are where collations part company:
# C compares bytes, so every capital sorts before every lower-case letter and
# `-` before any letter, while many locales fold case and ignore punctuation.
# An array, so the splitting into arguments is explicit rather than left to
# word splitting on a string.
locale_targets=()
while IFS= read -r candidate_name; do
	[ -n "$candidate_name" ] || continue
	locale_targets+=("$candidate_name")
done < <(
	printf '%s\n' "$drift_names" | grep -E '^[A-Z]' | head -2
	printf '%s\n' "$drift_names" | grep -E '^nim-' | head -4
)

# A locale whose ordering of THESE names differs from C's. Nothing is written
# in: the names come from the committed lock, the locales from the host.
printf '%s\n' "$drift_names" | LC_ALL=C sort >"$work/names.c"
differing_locale=""
for candidate in $(locale -a 2>/dev/null | grep -E 'UTF-8$' | sort -u); do
	if ! LC_ALL="$candidate" sort "$work/names.c" 2>/dev/null |
		cmp -s - "$work/names.c"; then
		differing_locale="$candidate"
		break
	fi
done

if [ "${#locale_targets[@]}" -eq 0 ]; then
	echo "FAIL: fixture: $CANONICAL has no upper-case or nim-* dependency" >&2
	failures=$((failures + 1))
elif [ -z "$differing_locale" ]; then
	# Said out loud rather than passed quietly: on a host whose locales all
	# collate these names as C does, this case cannot fail, and a green run
	# here is not evidence that the comparison is C-collated.
	echo "SKIP: no locale on this host orders the committed lock's dependency" >&2
	echo "  names differently from C, so the cross-locale case cannot" >&2
	echo "  exercise the defect here. It is a real gate only where the two" >&2
	echo "  collations disagree -- which is where it was found." >&2
else
	python3 - "$CANONICAL" "$work/locale-drift.lock" "${locale_targets[@]}" <<'LOCALEFIXTURE'
import re, sys, pathlib
src, dst, targets = sys.argv[1], sys.argv[2], sys.argv[3:]
text = pathlib.Path(src).read_text()
line = [l for l in text.splitlines() if l.startswith("deps = [")][0]
out = line
for name in targets:
    rec = re.search(r'\{[^{}]*name = "' + re.escape(name) + r'"[^{}]*\}', out)
    if rec is None:
        raise SystemExit("fixture: no deps record for " + name)
    rev = re.search(r'revision = "([^"]*)"', rec.group(0)).group(1)
    out = out.replace(rec.group(0), rec.group(0).replace(rev, "0" * 40))
pathlib.Path(dst).write_text(text.replace(line, out))
LOCALEFIXTURE
	locale_rc=0
	locale_out="$(LC_ALL="$differing_locale" bash "$CHECK" \
		"$work/locale-drift.lock" "$CANONICAL" 2>&1)" || locale_rc=$?
	missing=""
	for name in "${locale_targets[@]}"; do
		grep -qF -- "$name" <<<"$locale_out" || missing="$missing $name"
	done
	if [ "$locale_rc" -ne 1 ]; then
		echo "FAIL: cross-locale drift under $differing_locale:" \
			"expected exit 1, got $locale_rc" >&2
		printf '%s\n' "$locale_out" | sed 's/^/    /' >&2
		failures=$((failures + 1))
	elif [ -n "$missing" ]; then
		echo "FAIL: cross-locale drift under $differing_locale:" \
			"refused without naming$missing" >&2
		printf '%s\n' "$locale_out" | sed 's/^/    /' >&2
		failures=$((failures + 1))
	else
		echo "ok: every drifted pin is named under $differing_locale" \
			"(${#locale_targets[@]} of them)"
	fi
fi

if [ "$failures" -ne 0 ]; then
	echo "" >&2
	echo "test-check-platform-lock-pins.sh: $failures case(s) failed" >&2
	exit 1
fi
echo ""
echo "test-check-platform-lock-pins.sh: all cases passed"
