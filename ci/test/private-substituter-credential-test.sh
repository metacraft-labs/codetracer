#!/usr/bin/env bash
# =============================================================================
# Contract suite: a step handed a private substituter is handed a credential
# for it.
#
# # What this guards
#
# `ci/test/private-substituter-credential.py` is the scanner; its header states
# the property and the defect. This suite is what stops the scanner rotting
# into a vacuous pass, which is the failure mode that matters here: a scanner
# that matches nothing prints exactly what a clean repository prints.
#
# # How it is tested
#
# Step 0 runs the scanner against the committed tree and pins three counts, so
# a scanner that stopped matching fails HERE rather than reporting OK.
#
# Every other step copies `.github/` and the register into a scratch root,
# applies ONE mutation, and asserts the scanner rejects it for the stated
# reason. The mutator refuses to continue if the text it was told to replace is
# not present -- a mutation that silently applied to nothing would make its arm
# a tautology, which is the same defect one level up.
#
# Each mutation is a thing a future edit could plausibly do:
#   1. drop the `attic-token` line from a caller           -> anonymous cache
#   2. take the credential from `vars.` instead of `secrets.`
#   3. spell it `secrets.` INSIDE a composite action       -> empty string
#   4. declare the composite's input but stop forwarding it
#   5. lose the register entirely
#   6. leave a stale register entry behind
#   7. rename the input so the scanner matches nothing     -> caught by the floor
#
# # No mocks
#
# The input is `.github/` as committed, copied byte-for-byte. The scanner under
# test is the shipped one, invoked exactly as `ci/lint/bash.sh` invokes it.
#
# Run: bash ci/test/private-substituter-credential-test.sh
# Lane: a step of `lint-bash` (python3 + PyYAML, no nix, no network).
# =============================================================================
# The mutation arms below carry GitHub Actions `${{ ... }}` expressions as
# LITERAL text: they are the bytes the workflow files contain, and the whole
# point is that the shell must not touch them. Single quotes are exactly
# right there, so SC2016 is noise in this file rather than a finding.
# shellcheck disable=SC2016
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly REPO_ROOT
SCANNER="$REPO_ROOT/ci/test/private-substituter-credential.py"
readonly SCANNER
REGISTER_REL="ci/test/private-substituter-credential.known-dark.txt"
readonly REGISTER_REL

# The counts Step 0 pins. They are floors, not equalities, for the two that
# should only ever grow with the repository -- and an equality for the dark
# register, because that one is the thing that must shrink to zero and must
# never grow quietly.
readonly MIN_SCANNED=40
readonly MIN_CREDENTIALED=13
readonly EXPECT_DARK_CONSUMERS=3

assertions=0
failures=0

pass() {
	assertions=$((assertions + 1))
	echo "  [OK] $1"
}

fail() {
	assertions=$((assertions + 1))
	failures=$((failures + 1))
	echo "  [FAIL] $1"
}

WORK="$(mktemp -d)"
readonly WORK
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

if ! command -v python3 >/dev/null 2>&1; then
	echo "python3 is not on PATH; this suite cannot run." >&2
	exit 3
fi
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
	echo "PyYAML is not available; this suite cannot run." >&2
	exit 3
fi

# ---------------------------------------------------------------------------
# make_tree <name> -> echoes a scratch REPO_ROOT carrying a copy of the inputs
# ---------------------------------------------------------------------------
make_tree() {
	local root="$WORK/$1"
	mkdir -p "$root/ci/test"
	cp -r "$REPO_ROOT/.github" "$root/.github"
	cp "$REPO_ROOT/$REGISTER_REL" "$root/$REGISTER_REL"
	echo "$root"
}

# ---------------------------------------------------------------------------
# mutate <file> <from> <to>
#
# Refuses if <from> is absent, and refuses if the file did not change. Either
# would leave the arm asserting nothing.
# ---------------------------------------------------------------------------
mutate() {
	local file="$1" from="$2" to="$3" before after
	if [ ! -f "$file" ]; then
		echo "MUTATOR: $file does not exist" >&2
		exit 3
	fi
	before="$(sha256sum "$file" | cut -d' ' -f1)"
	MUT_FROM="$from" MUT_TO="$to" python3 - "$file" <<-'PY'
		import os, sys
		path = sys.argv[1]
		src = os.environ["MUT_FROM"]
		dst = os.environ["MUT_TO"]
		with open(path, encoding="utf-8", newline="") as fh:
		    text = fh.read()
		if src not in text:
		    sys.stderr.write("MUTATOR: text to replace is absent from " + path + "\n")
		    sys.exit(3)
		with open(path, "w", encoding="utf-8", newline="") as fh:
		    fh.write(text.replace(src, dst))
	PY
	local rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "MUTATOR: refused to mutate $file" >&2
		exit 3
	fi
	after="$(sha256sum "$file" | cut -d' ' -f1)"
	if [ "$before" = "$after" ]; then
		echo "MUTATOR: $file is unchanged after the mutation" >&2
		exit 3
	fi
}

# ---------------------------------------------------------------------------
# run_scanner <root> -> writes output to $SCAN_OUT, returns the exit code
# ---------------------------------------------------------------------------
SCAN_OUT="$WORK/scan.out"
run_scanner() {
	python3 "$SCANNER" "$1" >"$SCAN_OUT" 2>&1
	return $?
}

expect_reject() { # <label> <root> <grep pattern>
	local label="$1" root="$2" pattern="$3" rc
	run_scanner "$root"
	rc=$?
	if [ "$rc" -ne 1 ]; then
		fail "$label: expected exit 1, got $rc"
		sed 's/^/        /' "$SCAN_OUT"
		return
	fi
	pass "$label: rejected (exit 1)"
	if grep -F -e "$pattern" "$SCAN_OUT" >/dev/null; then
		pass "$label: names the reason ($pattern)"
	else
		fail "$label: did not name the reason ($pattern)"
		sed 's/^/        /' "$SCAN_OUT"
	fi
}

echo "== Step 0: the committed tree passes, and the scan is not empty =="
run_scanner "$REPO_ROOT"
rc=$?
if [ "$rc" -eq 0 ]; then
	pass "the committed tree satisfies the contract"
else
	fail "the committed tree does NOT satisfy the contract (exit $rc)"
	sed 's/^/        /' "$SCAN_OUT"
fi

scanned="$(sed -n 's/^steps handing out a private substituter: //p' "$SCAN_OUT")"
credentialed="$(sed -n 's/^ *credentialed (credential-capable consumer + attic-token): //p' "$SCAN_OUT")"
dark="$(sed -n 's/^ *credential-incapable consumers (registered): //p' "$SCAN_OUT")"

if [ -n "$scanned" ] && [ "$scanned" -ge "$MIN_SCANNED" ]; then
	pass "the scan found $scanned steps naming a private substituter (floor $MIN_SCANNED)"
else
	fail "the scan found '${scanned:-<nothing>}' steps; floor is $MIN_SCANNED. A scanner that matches nothing reports the same thing a clean repository does."
fi

if [ -n "$credentialed" ] && [ "$credentialed" -ge "$MIN_CREDENTIALED" ]; then
	pass "$credentialed of them are credentialed (floor $MIN_CREDENTIALED)"
else
	fail "only '${credentialed:-<nothing>}' steps are credentialed; floor is $MIN_CREDENTIALED"
fi

if [ "$dark" = "$EXPECT_DARK_CONSUMERS" ]; then
	pass "$dark credential-incapable consumers, which is the registered number"
else
	fail "credential-incapable consumers is '${dark:-<nothing>}', expected exactly $EXPECT_DARK_CONSUMERS. Update $REGISTER_REL and this constant together, and say why in the commit."
fi

echo "== Step 1: a caller that drops attic-token is rejected =="
root="$(make_tree drop-token)"
mutate "$root/.github/workflows/launcher-recorder-e2e.yml" \
	'          attic-token: ${{ secrets.ATTIC_TOKEN }}
' ''
expect_reject "drop-token" "$root" "launcher-recorder-e2e.yml"
expect_reject "drop-token" "$root" 'passes no `attic-token`'

echo "== Step 2: a credential taken from vars. is rejected =="
root="$(make_tree vars-token)"
mutate "$root/.github/workflows/launcher-recorder-e2e.yml" \
	'attic-token: ${{ secrets.ATTIC_TOKEN }}' \
	'attic-token: ${{ vars.ATTIC_TOKEN }}'
expect_reject "vars-token" "$root" 'does not come from `secrets.`'

echo "== Step 3: secrets. inside a composite action is rejected =="
root="$(make_tree secrets-in-action)"
mutate "$root/.github/actions/setup-db-backend-siblings/action.yml" \
	'attic-token: ${{ inputs.attic-token }}' \
	'attic-token: ${{ secrets.ATTIC_TOKEN }}'
expect_reject "secrets-in-action" "$root" 'has no `secrets`'

echo "== Step 4: a composite that declares the input but stops forwarding it =="
root="$(make_tree no-forward)"
mutate "$root/.github/actions/setup-db-backend-siblings/action.yml" \
	'        attic-token: ${{ inputs.attic-token }}
' ''
# The action stops being credential-capable, so its CALLER's step becomes a
# consumer nothing can credential -- and that consumer is not in the register.
expect_reject "no-forward" "$root" "setup-db-backend-siblings"
expect_reject "no-forward" "$root" "not credential-capable"

echo "== Step 5: losing the register is rejected =="
root="$(make_tree no-register)"
rm -f "$root/$REGISTER_REL"
expect_reject "no-register" "$root" "devops-modules/.github/setup-nix"
expect_reject "no-register" "$root" "is not named in"

echo "== Step 6: a stale register entry is rejected =="
root="$(make_tree stale-register)"
printf '\nmetacraft-labs/no-such-repo/.github/setup-nix\n' >>"$root/$REGISTER_REL"
expect_reject "stale-register" "$root" "Remove the stale entry"

echo "== Step 7: a scanner that matches nothing is caught by the floor =="
root="$(make_tree renamed-input)"
for wf in "$root"/.github/workflows/*.yml "$root"/.github/actions/*/action.yml; do
	[ -f "$wf" ] || continue
	python3 - "$wf" <<-'PY'
		import sys
		path = sys.argv[1]
		with open(path, encoding="utf-8", newline="") as fh:
		    text = fh.read()
		with open(path, "w", encoding="utf-8", newline="") as fh:
		    fh.write(text.replace("substituters:", "substituters-renamed:"))
	PY
done
run_scanner "$root"
renamed_scanned="$(sed -n 's/^steps handing out a private substituter: //p' "$SCAN_OUT")"
if [ "$renamed_scanned" = "0" ]; then
	pass "renaming the input makes the scan empty, which is what the Step 0 floor exists to catch"
else
	fail "expected an empty scan after the rename, got '${renamed_scanned:-<nothing>}'"
fi
if [ -n "$renamed_scanned" ] && [ "$renamed_scanned" -lt "$MIN_SCANNED" ]; then
	pass "and $renamed_scanned is below the floor of $MIN_SCANNED, so Step 0 would fail"
else
	fail "the empty scan is not below the Step 0 floor; the floor is not load-bearing"
fi

echo "== Step 8: the mutator refuses a mutation that would apply to nothing =="
root="$(make_tree mutator-control)"
if (mutate "$root/.github/workflows/launcher-recorder-e2e.yml" \
	'a string that is not in this file anywhere at all' 'x') >/dev/null 2>&1; then
	fail "the mutator accepted a replacement whose source text is absent"
else
	pass "the mutator refuses a replacement whose source text is absent"
fi

echo
echo "assertions: $assertions, failures: $failures"
[ "$failures" -eq 0 ] || exit 1
echo "OK"
