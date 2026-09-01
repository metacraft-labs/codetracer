#!/usr/bin/env bash
# =============================================================================
# Contract suite for scripts/sibling-pins.sh.
#
# The guard it covers turns `flake.lock`'s already-correct per-commit sibling
# revisions into the refs the clone lanes use, and then asserts that the tree
# the compiler read is actually at them. Its own header explains why.
#
# What THIS suite is for is the failure side, because every way this guard
# could be wrong looks exactly like it working:
#
#   * REPORTING ON NOTHING. `--verify` is a universal claim over the declared
#     siblings. Over an empty set that claim is TRUE, so an emptied list, a
#     drifted output shape, or a resolver that matched no lines would print a
#     clean pass having compared no revisions at all. Every arm below that
#     concerns a comparison is paired with an arm asserting the COUNT, and the
#     count is asserted to be non-zero — `failed -eq 0` is satisfied by a run
#     that checked nothing.
#
#   * SKIPPING WHEN THE ANSWER IS ABSENT. A sibling directory that is not
#     there is the single most likely real-world state, and "not there" must
#     be a hard failure. Read as "nothing to check", it is how an unpinned
#     build passes a pin check.
#
#   * ACCUSING THE WRONG THING. python3 missing, or an unparseable flake.lock,
#     must be reported as a tooling/parse failure. A guard that answers
#     "flake.lock does not pin <sibling>" when python3 is simply absent sends
#     the reader to edit the pin it exists to protect. Those arms therefore
#     assert both that the RIGHT diagnostic appears and that the WRONG one
#     does not.
#
#   * READING THE WRONG NODE. In flake.lock the root input name and the node
#     key are not the same string: `codetracer-trace-format` is stored under
#     `codetracer-trace-format_4`, because other inputs bring their own copy
#     and nix disambiguates with a numeric suffix. A lookup by input name
#     lands on a different repo's node or on none, and the wrong-or-empty rev
#     it returns is indistinguishable from a correct one. One arm below builds
#     exactly that shape and requires the resolver to see through it.
#
# Every mutation arm reddens ITS OWN assertion: the arm is applied, and the
# suite requires the specific diagnostic for that arm — not merely a non-zero
# exit, which another check could have produced for another reason.
#
# Pure bash + git + python3 over temporary fixtures. No network, no nix, no
# dev shell; well under a second and it writes nothing outside its own mktemp.
#
# Run: bash ci/test/sibling-pins-test.sh
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$REPO_ROOT/scripts/sibling-pins.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/deploy-web-codetracer.yml"

[ -f "$GUARD" ] || {
	echo "FAIL: the script under test is missing: $GUARD" >&2
	exit 1
}

PASS=0
FAIL=0
pass() {
	PASS=$((PASS + 1))
	printf '  ok    %s\n' "$1"
}
fail() {
	FAIL=$((FAIL + 1))
	printf '  FAIL  %s\n' "$1" >&2
	[ -n "${2:-}" ] && printf '        %s\n' "$2" >&2
	return 0
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

SIBLING_NAMES=(codetracer-native-recorder codetracer-trace-format codetracer-trace-format-nim)
EXPECTED_COUNT=${#SIBLING_NAMES[@]}

# ---------------------------------------------------------------------------
# Fixture: a throwaway "repo root" holding a copy of the guard plus a flake.lock
# we control, and three real one-commit git repos to act as siblings.
#
# The fixture flake.lock reproduces the real file's shape deliberately, INDEX
# SUFFIXES AND ALL: the trace-format node is keyed `codetracer-trace-format_4`
# and a decoy node is parked at the bare name `codetracer-trace-format` holding
# a different revision. A resolver that looks up by input name instead of
# following root.inputs finds the decoy and reports a plausible 40-hex SHA that
# is simply the wrong commit.
# ---------------------------------------------------------------------------
mkfixture() { # <dir>
	local root="$1" name sha
	mkdir -p "$root/scripts" "$root/siblings"
	cp "$GUARD" "$root/scripts/sibling-pins.sh"

	FIX_SHAS=()
	for name in "${SIBLING_NAMES[@]}"; do
		git init -q "$root/siblings/$name"
		git -C "$root/siblings/$name" -c user.email=t@t -c user.name=t \
			commit -q --allow-empty -m "$name"
		sha="$(git -C "$root/siblings/$name" rev-parse HEAD)"
		FIX_SHAS+=("$sha")
	done

	python3 - "$root/flake.lock" "${FIX_SHAS[@]}" <<'PY'
import json, sys
out, (rec, tf, tfn) = sys.argv[1], sys.argv[2:5]
decoy = "0" * 39 + "1"
nodes = {
    "root": {"inputs": {
        "codetracer-native-recorder": "codetracer-native-recorder",
        "codetracer-trace-format": "codetracer-trace-format_4",
        "codetracer-trace-format-nim": "codetracer-trace-format-nim",
    }},
    "codetracer-native-recorder": {"locked": {"rev": rec}},
    # The decoy sits at the bare name; the real node carries the index suffix.
    "codetracer-trace-format": {"locked": {"rev": decoy}},
    "codetracer-trace-format_4": {"locked": {"rev": tf}},
    "codetracer-trace-format-nim": {"locked": {"rev": tfn}},
}
with open(out, "w") as h:
    json.dump({"nodes": nodes, "root": "root", "version": 7}, h)
PY
	DECOY_REV="$(printf '0%.0s' $(seq 39))1"
}

run() { # <fixture-root> <args...> -> sets OUT, RC
	local root="$1"
	shift
	OUT="$(bash "$root/scripts/sibling-pins.sh" "$@" 2>&1)"
	RC=$?
}

echo "sibling-pins guard contract"
echo

# ===========================================================================
# Group 1 — resolution against a well-formed lock
# ===========================================================================
FIX="$TMP/good"
mkfixture "$FIX"

run "$FIX"
if [ "$RC" -eq 0 ]; then
	pass "a well-formed flake.lock resolves cleanly (exit 0)"
else
	fail "a well-formed flake.lock resolves cleanly" "exit $RC: $OUT"
fi

n="$(printf '%s\n' "$OUT" | grep -c '^[a-z-]*=[0-9a-f]\{40\}$')"
if [ "$n" -eq "$EXPECTED_COUNT" ]; then
	pass "it emits exactly $EXPECTED_COUNT pins, each a 40-hex SHA"
else
	fail "it emits exactly $EXPECTED_COUNT pins, each a 40-hex SHA" "got $n:
$OUT"
fi

# The count assertion, stated on its own so it cannot be satisfied vacuously.
if [ "$n" -gt 0 ]; then
	pass "the emitted pin count is non-zero ($n), so the checks below are not vacuous"
else
	fail "the emitted pin count is non-zero" \
		"zero pins were emitted; every universal claim over them is vacuously true"
fi

# The node-key arm: the resolver must return the REAL trace-format rev, not the
# decoy parked at the bare input name.
got_tf="$(printf '%s\n' "$OUT" | awk -F= '$1=="codetracer-trace-format"{print $2}')"
if [ "$got_tf" = "${FIX_SHAS[1]}" ]; then
	pass "it follows root.inputs to the suffixed node (codetracer-trace-format_4)"
elif [ "$got_tf" = "$DECOY_REV" ]; then
	fail "it follows root.inputs to the suffixed node" \
		"it returned the decoy node parked at the bare input name ($DECOY_REV). A lookup by input name reads a different repo's node and its rev is indistinguishable from a correct one."
else
	fail "it follows root.inputs to the suffixed node" "got '$got_tf', expected '${FIX_SHAS[1]}'"
fi

# ===========================================================================
# Group 2 — --verify against checkouts (the non-circular arm)
# ===========================================================================
run "$FIX" --verify "$FIX/siblings"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "RESULT: PASSED — all $EXPECTED_COUNT declared sibling"; then
	pass "--verify passes when all $EXPECTED_COUNT checkouts are at their pins, and says how many"
else
	fail "--verify passes when all $EXPECTED_COUNT checkouts are at their pins" "exit $RC: $OUT"
fi

# --- mutation: one sibling moved off its pin -------------------------------
MUT="$TMP/moved"
cp -R "$FIX" "$MUT"
git -C "$MUT/siblings/codetracer-trace-format" -c user.email=t@t -c user.name=t \
	commit -q --allow-empty -m "drift"
run "$MUT" --verify "$MUT/siblings"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "codetracer-trace-format: built from .* but this commit pins"; then
	pass "MUTATION a sibling moved off its pin -> reddens the revision-equality assertion"
else
	fail "MUTATION a sibling moved off its pin -> reddens the revision-equality assertion" \
		"exit $RC: $OUT"
fi

# --- mutation: a sibling checkout is absent --------------------------------
MUT="$TMP/absent"
cp -R "$FIX" "$MUT"
rm -rf "$MUT/siblings/codetracer-native-recorder"
run "$MUT" --verify "$MUT/siblings"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "codetracer-native-recorder: no checkout at"; then
	pass "MUTATION an absent sibling -> FAILS loudly; it does not read as 'nothing to check'"
else
	fail "MUTATION an absent sibling -> FAILS loudly" \
		"an absent sibling must never be a skip. exit $RC: $OUT"
fi

# --- mutation: a sibling is at its pin but dirty ---------------------------
MUT="$TMP/dirty"
cp -R "$FIX" "$MUT"
echo scratch >"$MUT/siblings/codetracer-trace-format-nim/uncommitted.txt"
run "$MUT" --verify "$MUT/siblings"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "codetracer-trace-format-nim: at the pinned commit .* uncommitted change"; then
	pass "MUTATION a dirty sibling at the right SHA -> reddens the dirtiness assertion"
else
	fail "MUTATION a dirty sibling at the right SHA -> reddens the dirtiness assertion" \
		"a dirty tree is not any commit. exit $RC: $OUT"
fi

# --- mutation: a sibling directory that is not a git checkout --------------
MUT="$TMP/nongit"
cp -R "$FIX" "$MUT"
rm -rf "$MUT/siblings/codetracer-trace-format/.git"
run "$MUT" --verify "$MUT/siblings"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "codetracer-trace-format: .* is not a git checkout"; then
	pass "MUTATION a non-git sibling directory -> reddens the revision-establishable assertion"
else
	fail "MUTATION a non-git sibling directory -> reddens the revision-establishable assertion" \
		"exit $RC: $OUT"
fi

# --- mutation: the declared sibling set is emptied (the vacuity arm) -------
# This is the arm the whole suite is built around. With no declared siblings
# every comparison above is a universal claim over an empty set, so all of them
# pass while nothing is pinned. The guard must refuse instead.
MUT="$TMP/empty"
cp -R "$FIX" "$MUT"
if ! python3 - "$MUT/scripts/sibling-pins.sh" <<'PY'; then
import re, sys
p = sys.argv[1]
s = open(p).read()
s2 = re.sub(r"SIBLINGS=\(\n(\t[a-z-]+\n)+\)", "SIBLINGS=()", s, count=1)
assert s2 != s, "the SIBLINGS array literal was not found; this arm's premise has moved"
open(p, "w").write(s2)
PY
	fail "MUTATION an emptied sibling list -> reddens the vacuity guard" \
		"the arm could not be applied: the SIBLINGS array literal has changed shape, so this arm is measuring nothing and must be repaired rather than left reporting 'could not be measured'."
else
	run "$MUT" --verify "$MUT/siblings"
	if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "resolved 0 sibling pins"; then
		pass "MUTATION an emptied sibling list -> reddens the vacuity guard, not some later check"
	else
		fail "MUTATION an emptied sibling list -> reddens the vacuity guard" \
			"with nothing declared, every comparison is vacuously true and this must be a refusal. exit $RC: $OUT"
	fi
fi

# ===========================================================================
# Group 3 — the guard must accuse the right thing when its inputs are broken
# ===========================================================================
MUT="$TMP/unparseable"
cp -R "$FIX" "$MUT"
printf 'this is not json' >"$MUT/flake.lock"
run "$MUT"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "did not parse as JSON"; then
	if printf '%s' "$OUT" | grep -q "does not pin every declared build sibling"; then
		fail "MUTATION an unparseable flake.lock -> says PARSE, not 'unpinned'" \
			"it printed the parse diagnostic and then the false accusation underneath it, which is worse than printing the false one alone: $OUT"
	else
		pass "MUTATION an unparseable flake.lock -> reddens the parse assertion, and does NOT accuse a pin"
	fi
else
	fail "MUTATION an unparseable flake.lock -> reddens the parse assertion" "exit $RC: $OUT"
fi

MUT="$TMP/norev"
cp -R "$FIX" "$MUT"
python3 - "$MUT/flake.lock" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["nodes"]["codetracer-trace-format_4"]["locked"]["rev"] = "dev"
json.dump(d, open(p, "w"))
PY
run "$MUT"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "does not pin every declared build sibling"; then
	pass "MUTATION a non-SHA locked.rev -> reddens the 40-hex assertion (a branch name is not a pin)"
else
	fail "MUTATION a non-SHA locked.rev -> reddens the 40-hex assertion" "exit $RC: $OUT"
fi

MUT="$TMP/notinput"
cp -R "$FIX" "$MUT"
python3 - "$MUT/flake.lock" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
del d["nodes"]["root"]["inputs"]["codetracer-native-recorder"]
json.dump(d, open(p, "w"))
PY
run "$MUT"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "codetracer-native-recorder not-a-root-input"; then
	pass "MUTATION a sibling dropped from flake.nix -> named explicitly, not silently unpinned"
else
	fail "MUTATION a sibling dropped from flake.nix -> named explicitly" "exit $RC: $OUT"
fi

# ===========================================================================
# Group 4 — the real repository: the deploy lane must consume the pins
# ===========================================================================
echo
if [ ! -f "$WORKFLOW" ]; then
	fail "the deploy workflow exists at $WORKFLOW" \
		"without it this group asserts nothing; repair the path rather than let the group vanish"
else
	# The guard resolves against THIS repo's real flake.lock.
	real_out="$(bash "$GUARD" 2>&1)"
	real_rc=$?
	real_n="$(printf '%s\n' "$real_out" | grep -c '^[a-z-]*=[0-9a-f]\{40\}$')"
	if [ "$real_rc" -eq 0 ] && [ "$real_n" -eq "$EXPECTED_COUNT" ]; then
		pass "this repo's own flake.lock pins all $EXPECTED_COUNT build siblings to 40-hex SHAs"
	else
		fail "this repo's own flake.lock pins all $EXPECTED_COUNT build siblings to 40-hex SHAs" \
			"exit $real_rc, $real_n pin(s):
$real_out"
	fi
	if [ "$real_n" -gt 0 ]; then
		pass "that count is non-zero ($real_n), so the workflow assertions below are not vacuous"
	else
		fail "that count is non-zero" "no pins resolved from the real flake.lock"
	fi

	# Cross-check each pin against flake.lock read a SECOND, independent way,
	# so a bug in the resolver cannot certify itself.
	mismatch=0
	checked=0
	while IFS='=' read -r name rev; do
		[ -n "$name" ] || continue
		checked=$((checked + 1))
		indep="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
key = d["nodes"][d["root"]]["inputs"][sys.argv[2]]
print(d["nodes"][key if isinstance(key, str) else key[0]]["locked"]["rev"])
' "$REPO_ROOT/flake.lock" "$name" 2>/dev/null)"
		[ "$indep" = "$rev" ] || {
			mismatch=$((mismatch + 1))
			printf '        %s: guard says %s, flake.lock says %s\n' "$name" "$rev" "$indep" >&2
		}
	done < <(printf '%s\n' "$real_out" | grep '^[a-z-]*=[0-9a-f]\{40\}$')
	if [ "$checked" -eq "$EXPECTED_COUNT" ] && [ "$mismatch" -eq 0 ]; then
		pass "all $checked pin(s) agree with flake.lock read independently"
	else
		fail "all pins agree with flake.lock read independently" \
			"cross-checked $checked (expected $EXPECTED_COUNT), $mismatch mismatch(es)"
	fi

	# The workflow must RESOLVE the pins and then CONSUME them. Both halves are
	# asserted separately, because either one alone is silently useless: a
	# resolve step whose output nothing reads pins nothing, and a reference to
	# `steps.pins.outputs.pins` with no step producing it expands to the empty
	# string — which `clone-siblings` would read as "no explicit siblings" and
	# fall back to the bare `.github/sibling-repos` list, i.e. exactly the
	# unpinned behaviour, with a green tick.
	#
	# The reference is matched on its own rather than as `siblings: <expr>`,
	# because the two branches spell the same thing differently: on `dev` the
	# input is a plain scalar, while on `cloud` it is a `|` block that also
	# carries the isonim family's explicit SHAs. Both substitute the expression
	# after YAML parsing, so both are correct; a pattern anchored to `siblings:`
	# would pass on one branch and fail on the other for no real reason.
	#
	# The patterns are single-quoted on purpose: `${{ ... }}` is GitHub Actions
	# syntax that must reach grep literally, so shellcheck's "expressions don't
	# expand" note is the intent here.
	# shellcheck disable=SC2016
	if grep -q 'run: bash scripts/sibling-pins.sh --github-output' "$WORKFLOW" &&
		grep -q '^[[:space:]]*id: pins[[:space:]]*$' "$WORKFLOW"; then
		pass "the deploy workflow has a 'pins' step that resolves the commit's pins"
	else
		fail "the deploy workflow has a 'pins' step that resolves the commit's pins" \
			"no step with 'id: pins' running 'sibling-pins.sh --github-output' in $WORKFLOW"
	fi

	# shellcheck disable=SC2016
	if grep -q '${{ steps.pins.outputs.pins }}' "$WORKFLOW"; then
		pass "the deploy workflow feeds those pins to the sibling clone step"
	else
		fail "the deploy workflow feeds those pins to the sibling clone step" \
			"nothing reads \${{ steps.pins.outputs.pins }} in $WORKFLOW, so the resolved pins go nowhere"
	fi

	# ...and must not name a branch for any of them. This is the assertion the
	# whole change exists to make true; it is stated per sibling and counted.
	branchy=0
	for name in "${SIBLING_NAMES[@]}"; do
		if grep -qE "^[[:space:]]+${name}=[A-Za-z][A-Za-z0-9._/-]*[[:space:]]*$" "$WORKFLOW"; then
			branchy=$((branchy + 1))
			printf '        %s is still named at a branch ref in %s\n' "$name" "$WORKFLOW" >&2
		fi
	done
	if [ "$branchy" -eq 0 ]; then
		pass "none of the $EXPECTED_COUNT build siblings is named at a branch ref in the deploy workflow"
	else
		fail "none of the build siblings is named at a branch ref in the deploy workflow" \
			"$branchy of $EXPECTED_COUNT still are; a branch tip is not a pin"
	fi

	# And the verification step must actually run in that lane.
	if grep -q 'sibling-pins.sh --verify' "$WORKFLOW"; then
		pass "the deploy workflow verifies the cloned siblings against the pins"
	else
		fail "the deploy workflow verifies the cloned siblings against the pins" \
			"a declaration nothing compares against the built tree is a comment, not a guarantee"
	fi
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
