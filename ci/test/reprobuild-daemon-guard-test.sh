#!/usr/bin/env bash
#
# reprobuild-daemon-guard-test.sh -- contract suite for
# ci/verdict/reprobuild-daemon-guard.sh.
#
# WHAT IS BEING PINNED
# --------------------
# That the live `ci/reprobuild/macos-*.sh` drivers stop the repro user daemon
# both before building and on the way out -- AND, just as importantly, that the
# checker saying so is capable of reporting otherwise.
#
# The second half is the point. Two failures in this campaign's history were
# checks that could only pass: a `*.lock` sweep whose first version matched
# anywhere (and was deleting Cargo.lock/flake.lock from sibling checkouts), and
# a credential recount that 494d85395 records as "itself a no-op". So every
# case below that asserts a PASS is paired with a planted fixture that must
# produce a FAIL, and the historical case is not a hand-written mock: it is the
# real pre-fix `macos-daemon-build.sh`, read out of git.
#
# Pure bash + git over mktemp fixtures. No nix, no network, no daemon, no
# Darwin -- the checker is a static reader, so this suite runs anywhere.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$REPO_ROOT/ci/verdict/reprobuild-daemon-guard.sh"

assertions=0
failures=0

ok() {
	assertions=$((assertions + 1))
	printf '  ok   %s\n' "$1"
}

fail() {
	assertions=$((assertions + 1))
	failures=$((failures + 1))
	printf '  FAIL %s\n' "$1"
	if [ "$#" -gt 1 ]; then
		shift
		printf '         %s\n' "$@"
	fi
}

if [ ! -f "$GUARD" ]; then
	printf 'FAIL: %s is missing; nothing checks the daemon guards\n' "$GUARD"
	exit 1
fi

tmp_root="$(mktemp -d)"
cleanup() { rm -rf "$tmp_root"; }
trap cleanup EXIT

# Run the checker over a directory, capturing BOTH its output and its exit
# status into globals. Assigning and then reading `$?` would work, but only
# because the status of an assignment happens to be the status of its command
# substitution -- too subtle to rest a dozen assertions on.
rc=0
out=""
run_guard() {
	out="$(bash "$GUARD" "$1" 2>&1)"
	rc=$?
}

printf 'the reprobuild daemon-cwd guard\n'

# --- Case 1: the live tree passes ------------------------------------------
run_guard "$REPO_ROOT/ci/reprobuild"
if [ "$rc" -eq 0 ]; then
	ok "the live ci/reprobuild drivers stop the daemon before and after building"
else
	fail "the live ci/reprobuild drivers stop the daemon before and after building" \
		"$out"
fi

# --- Case 2: it examined something ------------------------------------------
# A pass over an empty set is the failure mode this campaign hit twice. The
# checker must SAY how many drivers it read, and it must be more than zero.
run_guard "$REPO_ROOT/ci/reprobuild"
examined="$(printf '%s' "$out" | sed -n 's/.*ok: \([0-9]*\) driver script.*/\1/p')"
if [ -n "$examined" ] && [ "$examined" -ge 2 ]; then
	ok "the checker reports examining $examined drivers, not an empty set"
else
	fail "the checker reports examining at least 2 drivers, not an empty set" \
		"got: $out" \
		"Both macos-smoke.sh and macos-daemon-build.sh run 'repro build'." \
		"If this number FELL, a driver stopped being discovered -- fix the glob," \
		"do not lower this bound."
fi

# --- Case 3: an empty directory is an ERROR, not a pass ---------------------
mkdir -p "$tmp_root/empty"
run_guard "$tmp_root/empty"
if [ "$rc" -eq 2 ]; then
	ok "a directory with no drivers is an error, not a silent pass"
else
	fail "a directory with no drivers is an error, not a silent pass" \
		"A checker that green-lights an empty set cannot detect the glob breaking."
fi

# --- Case 4: THE HISTORICAL DEFECT, from git, not from a mock ---------------
# ci/reprobuild/macos-daemon-build.sh as it stood before this fix: it runs
# `repro build --daemon=auto` and has no `repro daemon stop` anywhere,
# including in its trap. If the checker cannot see that, it cannot see anything.
hist="$tmp_root/historical"
mkdir -p "$hist"
if git -C "$REPO_ROOT" show origin/dev:ci/reprobuild/macos-daemon-build.sh \
	>"$hist/macos-daemon-build.sh" 2>/dev/null &&
	[ -s "$hist/macos-daemon-build.sh" ]; then

	run_guard "$hist"
	if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "no 'repro daemon stop' before"; then
		ok "the real pre-fix macos-daemon-build.sh is rejected, and says why"
	else
		fail "the real pre-fix macos-daemon-build.sh is rejected, and says why" \
			"rc=$rc" "$out" \
			"This is the defect the checker exists for. If it passes, the" \
			"checker is measuring nothing."
	fi

	if printf '%s' "$out" | grep -q "does not run 'repro daemon stop'"; then
		ok "the missing stop in the EXIT handler is reported separately"
	else
		fail "the missing stop in the EXIT handler is reported separately" \
			"$out"
	fi
else
	fail "the real pre-fix macos-daemon-build.sh could be read from origin/dev" \
		"git show origin/dev:ci/reprobuild/macos-daemon-build.sh produced nothing." \
		"Without the historical fixture this suite cannot prove the checker fails."
fi

# --- Case 5: a trap armed inside a function is rejected ---------------------
# `trap ... EXIT` armed inside a function is not armed on any path that returns
# before reaching it. macos-daemon-build.sh armed its only trap inside
# start_runquotad(), which returns EARLY whenever RUNQUOTA_SOCKET is already
# set -- so on that path the script had no exit handler at all.
inner="$tmp_root/inner-trap"
mkdir -p "$inner"
cat >"$inner/macos-x.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
repro daemon stop >/dev/null 2>&1 || true
cleanup() { repro daemon stop >/dev/null 2>&1 || true; }
start() {
	if [ -n "${ALREADY:-}" ]; then return; fi
	trap cleanup EXIT
}
start
repro build . --daemon=auto
EOF
run_guard "$inner"
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "armed inside a function"; then
	ok "a trap armed inside a function is rejected"
else
	fail "a trap armed inside a function is rejected" "$out"
fi

# --- Case 6: a second EXIT trap silently discarding the first is rejected ---
dbl="$tmp_root/double-trap"
mkdir -p "$dbl"
cat >"$dbl/macos-x.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
repro daemon stop >/dev/null 2>&1 || true
cleanup() { repro daemon stop >/dev/null 2>&1 || true; }
trap cleanup EXIT
trap 'rm -rf /tmp/x' EXIT
repro build . --daemon=auto
EOF
run_guard "$dbl"
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "REPLACES rather than"; then
	ok "a second EXIT trap, which discards the first, is rejected"
else
	fail "a second EXIT trap, which discards the first, is rejected" "$out"
fi

# --- Case 7: prose about the guard does not satisfy the guard ---------------
# The scripts under check discuss `repro daemon stop` in long comments. A
# checker that grepped without stripping comments would be satisfied by its own
# explanation -- the "detector probing the wrong artefact" defect exactly.
prose="$tmp_root/prose-only"
mkdir -p "$prose"
cat >"$prose/macos-x.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# We ought to run `repro daemon stop` here before building, and again in
# cleanup, because a stale daemon holds a deleted cwd. We do not, though.
cleanup() {
	# repro daemon stop
	rm -rf /tmp/x
}
trap cleanup EXIT
repro build . --daemon=auto
EOF
run_guard "$prose"
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "no 'repro daemon stop' before"; then
	ok "a comment mentioning the stop does not count as running it"
else
	fail "a comment mentioning the stop does not count as running it" "$out"
fi

# --- Case 8: a correctly guarded driver passes ------------------------------
# The mirror of every case above: the checker must not simply reject
# everything, or it would be green-by-refusal rather than discriminating.
good="$tmp_root/good"
mkdir -p "$good"
cat >"$good/macos-x.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
repro daemon stop >/dev/null 2>&1 || true
cleanup() {
	repro daemon stop >/dev/null 2>&1 || true
	rm -rf /tmp/x
}
trap cleanup EXIT
repro build . --daemon=auto
EOF
run_guard "$good"
if [ "$rc" -eq 0 ]; then
	ok "a correctly guarded driver passes"
else
	fail "a correctly guarded driver passes" "$out"
fi

printf '\n'
if [ "$failures" -ne 0 ]; then
	printf '%d of %d assertions failed\n' "$failures" "$assertions"
	exit 1
fi
printf 'all %d assertions passed\n' "$assertions"
