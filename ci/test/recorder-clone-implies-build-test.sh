#!/usr/bin/env bash
#
# recorder-clone-implies-build-test.sh -- contract suite for
# ci/verdict/recorder-clone-implies-build.py.
#
# WHAT IS BEING PINNED
# --------------------
# That every job cloning a compiled recorder sibling also builds it -- and that
# the checker asserting this is both able to FAIL and able to NOT fire on a job
# that builds correctly by a route it did not first think of.
#
# The second property is the one that took work. `viewmodel-tests` clones the JS
# recorder and builds it from inside a Justfile recipe
# (`test-vm-recorder-gated` runs `scripts/build-siblings.sh --only
# codetracer-js-recorder`), not from a `run:` block. The first version of the
# checker reported that job as a violation. Relaxing the rule to permit it would
# have re-opened the hole; instead the checker follows `just <target>` into the
# Justfile, so it agrees with what CI actually executes. A false positive here
# is not a cosmetic defect -- it trains the reader to skip the check, which
# costs exactly what a missing check costs.
#
# The negative case is the real pre-fix workflow read out of `origin/dev`, not a
# mock of it, and it must name the three jobs that were genuinely broken while
# NOT naming the one that was not.
#
# Pure bash + python3 + PyYAML. No nix, no network, no siblings.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$REPO_ROOT/ci/verdict/recorder-clone-implies-build.py"

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
	printf 'FAIL: %s is missing\n' "$GUARD"
	exit 1
fi

if ! python3 -c 'import yaml' 2>/dev/null; then
	printf 'FAIL: PyYAML is not available; this suite cannot run\n'
	exit 1
fi

tmp_root="$(mktemp -d)"
cleanup() { rm -rf "$tmp_root"; }
trap cleanup EXIT

skipped=0
skip() {
	skipped=$((skipped + 1))
	printf '  skip %s\n' "$1"
	if [ "$#" -gt 1 ]; then
		shift
		printf '         %s\n' "$@"
	fi
}

# The pre-fix file is read from a PINNED commit, never from `origin/dev`.
# Two reasons, and the first is fatal: once this fix lands, `origin/dev` carries
# the FIXED file, so a case phrased as "origin/dev must be rejected" would
# silently invert into asserting that the fix is broken. Second, the lint lane
# checks out at the default fetch-depth of 1, so `origin/dev` is often not
# present as a ref at all.
#
# 9df1b076e is the commit this work was branched from; it is an ancestor of dev
# and its content is immutable.
HISTORICAL_REV="9df1b076e"

historical_available() {
	git -C "$REPO_ROOT" cat-file -e "$HISTORICAL_REV:$1" 2>/dev/null
}

rc=0
out=""
run_guard() {
	out="$(cd "$REPO_ROOT" && python3 "$GUARD" "$@" 2>&1)"
	rc=$?
}

printf 'recorder clones are followed by recorder builds\n'

# --- Case 1: the live workflow passes --------------------------------------
run_guard ".github/workflows/codetracer.yml"
if [ "$rc" -eq 0 ]; then
	ok "the live codetracer.yml builds every recorder it clones"
else
	fail "the live codetracer.yml builds every recorder it clones" "$out"
fi

# --- Case 2: it examined something -----------------------------------------
seen="$(printf '%s' "$out" | sed -n 's/.*ok: all \([0-9]*\) recorder clone.*/\1/p')"
if [ -n "$seen" ] && [ "$seen" -ge 4 ]; then
	ok "the checker reports examining $seen recorder clones, not an empty set"
else
	fail "the checker reports examining at least 4 recorder clones" \
		"got: $out" \
		"test-non-gui and test-ui-tests each clone ruby; test-ui-tests and" \
		"viewmodel-tests each clone js. If this number FELL, a clone stopped" \
		"being recognised -- fix the recogniser, do not lower this bound."
fi

# --- Case 2b: the Justfile is found BY ITS REAL NAME -----------------------
# THE DEFECT THIS PINS SHIPPED, AND IT WAS INVISIBLE ON EVERY MACHINE ANYONE
# RAN IT ON. The checker looked up `repo_root / "Justfile"`; the file is
# `justfile`. APFS is case-insensitive, so `.exists()` said yes on macOS and on
# every by-hand run, and said NO on the Linux CI runner -- where
# `parse_justfile` then returned `{}` silently, no `just` target could be
# followed, and `viewmodel-tests` was reported as a violation of a rule it does
# not break. Case 4 below already covers that job, but only against the
# HISTORICAL workflow, which is skipped in a shallow clone -- so on CI, the
# lane that would have caught this had nothing asserting it.
#
# These two cases need no history and no network, so they hold at any depth.
if [ -n "$(
	python3 - "$REPO_ROOT" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
# Case-SENSITIVE, deliberately: `.exists()` is the call that hid the defect.
names = {e.name for e in root.iterdir()}
sys.stdout.write("yes" if names & {"justfile", "Justfile", ".justfile", ".Justfile", "JUSTFILE"} else "")
PY
)" ]; then
	if grep -q "parsed 0 just recipes" <<<"$out"; then
		fail "the checker resolves this repo's justfile by its real name" \
			"A justfile is present, yet the checker parsed no recipes." \
			"On a case-insensitive filesystem a wrong-case lookup still" \
			"succeeds; that is what made this defect Linux-only." "$out"
	else
		ok "the checker resolves this repo's justfile by its real name"
	fi
else
	fail "the checker resolves this repo's justfile by its real name" \
		"No justfile in $REPO_ROOT under any spelling that just accepts."
fi

# --- Case 2c: no recipe table is a REFUSAL, not a pile of violations -------
# Without recipes, every build delegated to a `just` target becomes invisible
# and its job becomes a violation. A checker that cannot read the tree must say
# so and stop, exactly as it already does for an empty clone set -- the
# alternative is not silence, it is confident wrong answers.
norecipes="$tmp_root/norecipes"
mkdir -p "$norecipes/ci/verdict" "$norecipes/.github/workflows"
cp "$GUARD" "$norecipes/ci/verdict/"
cp "$REPO_ROOT/.github/workflows/codetracer.yml" "$norecipes/.github/workflows/"
nr_out="$(python3 "$norecipes/ci/verdict/recorder-clone-implies-build.py" \
	"$norecipes/.github/workflows/codetracer.yml" 2>&1)"
nr_rc=$?
if [ "$nr_rc" -eq 2 ] && grep -q "parsed 0 just recipes" <<<"$nr_out"; then
	ok "a tree with no justfile is refused (exit 2), not reported as violations"
else
	fail "a tree with no justfile is refused (exit 2), not reported as violations" \
		"got exit $nr_rc. A missing recipe table must not be reported as" \
		"the workflow's fault." "$nr_out"
fi

# --- Case 3: THE HISTORICAL DEFECT, from git, not from a mock --------------
hist="$tmp_root/prefix-codetracer.yml"
if historical_available .github/workflows/codetracer.yml &&
	git -C "$REPO_ROOT" show "$HISTORICAL_REV:.github/workflows/codetracer.yml" \
		>"$hist" 2>/dev/null && [ -s "$hist" ]; then

	run_guard "$hist"
	if [ "$rc" -ne 0 ]; then
		ok "the real pre-fix workflow is rejected"
	else
		fail "the real pre-fix workflow is rejected" \
			"This is the defect the checker exists for. If it passes, the" \
			"checker is measuring nothing." "$out"
	fi

	for want in "job 'test-non-gui' clones codetracer-ruby-recorder" \
		"job 'test-ui-tests' clones codetracer-ruby-recorder" \
		"job 'test-ui-tests' clones codetracer-js-recorder"; do
		if grep -qF "$want" <<<"$out"; then
			ok "the pre-fix report names: $want"
		else
			fail "the pre-fix report names: $want" "$out"
		fi
	done

	# --- Case 4: and does NOT name the job that builds via the Justfile ----
	# `viewmodel-tests` was broken in the checker, not in the workflow. It
	# builds the JS recorder through `just test-vm-recorder-gated` ->
	# `scripts/build-siblings.sh --only codetracer-js-recorder`.
	if grep -qF "job 'viewmodel-tests'" <<<"$out"; then
		fail "viewmodel-tests is NOT reported: it builds via a Justfile recipe" \
			"Following 'just <target>' into the Justfile is what distinguishes" \
			"a real gap from a build the checker merely could not see." \
			"$out"
	else
		ok "viewmodel-tests is not reported: its Justfile route is followed"
	fi
else
	# See the note on HISTORICAL_REV: shallow checkouts are the norm in the lint
	# lane. Cases 5-7 below plant the same defects synthetically and assert the
	# same messages, so failure-capability is proved without the real workflow.
	skip "the real pre-fix workflow is unavailable at $HISTORICAL_REV" \
		"(shallow clone). The planted fixtures below still prove the checker fails."
fi

# --- Case 5: a clone with no build at all is rejected ----------------------
cat >"$tmp_root/bare.yml" <<'EOF'
name: fixture
on: push
jobs:
  a-job:
    runs-on: ubuntu-latest
    steps:
      - name: Clone ruby-recorder
        uses: metacraft-labs/metacraft-github-actions/clone-repo@dev
        with:
          repo: metacraft-labs/codetracer-ruby-recorder
          ref: dev
      - name: Run the suite
        run: ./ci/test/non-gui.sh
EOF
run_guard "$tmp_root/bare.yml"
if [ "$rc" -eq 1 ] && grep -qF "clones codetracer-ruby-recorder but never builds it" <<<"$out"; then
	ok "a clone with no build anywhere in the job is rejected"
else
	fail "a clone with no build anywhere in the job is rejected" "rc=$rc" "$out"
fi

# --- Case 6: asserting the artefact is not the same as building it ---------
# A step that checks for the .bundle without producing it would leave the job
# red for the same reason, one step earlier. The markers are build COMMANDS.
cat >"$tmp_root/assert-only.yml" <<'EOF'
name: fixture
on: push
jobs:
  a-job:
    runs-on: ubuntu-latest
    steps:
      - name: Clone ruby-recorder
        uses: metacraft-labs/metacraft-github-actions/clone-repo@dev
        with:
          repo: metacraft-labs/codetracer-ruby-recorder
          ref: dev
      - name: Check the extension
        run: |
          cd ../codetracer-ruby-recorder
          test -f gems/codetracer-ruby-recorder/ext/native_tracer/target/release/codetracer_ruby_recorder.bundle
EOF
run_guard "$tmp_root/assert-only.yml"
if [ "$rc" -eq 1 ]; then
	ok "asserting the artefact does not count as building it"
else
	fail "asserting the artefact does not count as building it" "rc=$rc" "$out"
fi

# --- Case 7: a build BEFORE the clone does not count ----------------------
# The clone replaces the tree, so anything built earlier is discarded.
cat >"$tmp_root/build-first.yml" <<'EOF'
name: fixture
on: push
jobs:
  a-job:
    runs-on: ubuntu-latest
    steps:
      - name: Build it too early
        run: |
          cd ../codetracer-ruby-recorder
          just build-extension
      - name: Clone ruby-recorder
        uses: metacraft-labs/metacraft-github-actions/clone-repo@dev
        with:
          repo: metacraft-labs/codetracer-ruby-recorder
          ref: dev
EOF
run_guard "$tmp_root/build-first.yml"
if [ "$rc" -eq 1 ]; then
	ok "a build that runs before the clone does not count"
else
	fail "a build that runs before the clone does not count" "rc=$rc" "$out"
fi

# --- Case 8: a correctly built clone passes -------------------------------
cat >"$tmp_root/good.yml" <<'EOF'
name: fixture
on: push
jobs:
  a-job:
    runs-on: ubuntu-latest
    steps:
      - name: Clone ruby-recorder
        uses: metacraft-labs/metacraft-github-actions/clone-repo@dev
        with:
          repo: metacraft-labs/codetracer-ruby-recorder
          ref: dev
      - name: Build it
        run: |
          cd ../codetracer-ruby-recorder
          nix develop --command just build-extension
EOF
run_guard "$tmp_root/good.yml"
if [ "$rc" -eq 0 ]; then
	ok "a clone followed by a real build passes"
else
	fail "a clone followed by a real build passes" "rc=$rc" "$out"
fi

# --- Case 9: a workflow with no recorder clones is an ERROR ---------------
cat >"$tmp_root/nothing.yml" <<'EOF'
name: fixture
on: push
jobs:
  a-job:
    runs-on: ubuntu-latest
    steps:
      - name: Nothing to do
        run: 'true'
EOF
run_guard "$tmp_root/nothing.yml"
if [ "$rc" -eq 2 ]; then
	ok "a workflow with no recorder clones is an error, not a silent pass"
else
	fail "a workflow with no recorder clones is an error, not a silent pass" \
		"rc=$rc" "$out"
fi

printf '\n'
if [ "$failures" -ne 0 ]; then
	printf '%d of %d assertions failed\n' "$failures" "$assertions"
	exit 1
fi
if [ "$skipped" -ne 0 ]; then
	printf 'all %d assertions passed (%d skipped: no historical blob)\n' "$assertions" "$skipped"
else
	printf 'all %d assertions passed\n' "$assertions"
fi
