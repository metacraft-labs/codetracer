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

# --- Case 3: THE HISTORICAL DEFECT, from git, not from a mock --------------
hist="$tmp_root/prefix-codetracer.yml"
if git -C "$REPO_ROOT" show origin/dev:.github/workflows/codetracer.yml >"$hist" 2>/dev/null &&
	[ -s "$hist" ]; then

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
		if printf '%s' "$out" | grep -qF "$want"; then
			ok "the pre-fix report names: $want"
		else
			fail "the pre-fix report names: $want" "$out"
		fi
	done

	# --- Case 4: and does NOT name the job that builds via the Justfile ----
	# `viewmodel-tests` was broken in the checker, not in the workflow. It
	# builds the JS recorder through `just test-vm-recorder-gated` ->
	# `scripts/build-siblings.sh --only codetracer-js-recorder`.
	if printf '%s' "$out" | grep -qF "job 'viewmodel-tests'"; then
		fail "viewmodel-tests is NOT reported: it builds via a Justfile recipe" \
			"Following 'just <target>' into the Justfile is what distinguishes" \
			"a real gap from a build the checker merely could not see." \
			"$out"
	else
		ok "viewmodel-tests is not reported: its Justfile route is followed"
	fi
else
	fail "the real pre-fix workflow could be read from origin/dev" \
		"Without the historical fixture this suite cannot prove the checker fails."
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
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF "clones codetracer-ruby-recorder but never builds it"; then
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
printf 'all %d assertions passed\n' "$assertions"
