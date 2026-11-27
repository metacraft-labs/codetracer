#!/usr/bin/env bash
# The workflow text this suite matches carries literal `${{ ... }}` and `${VAR}`
# expressions, which must NOT expand here.
# shellcheck disable=SC2016
# =============================================================================
# Contract: codetracer-image-diff's downstream lane -- the reusable workflow
# .github/workflows/image-diff-downstream.yml, its driver
# ci/test/image-diff-consumers.sh, and the caller
# codetracer-image-diff/.github/workflows/downstream.yml -- agree, test the
# library at the caller's commit, take codetracer only at a 40-hex revision,
# and refuse to pass on nothing.
#
# Same shape as ci/test/php-recorder-downstream-workflow-test.sh, for the same
# reason: none of this is reachable by a YAML linter, and the workflow runs
# only from the library's CI. So the plan step's script is EXTRACTED FROM THE
# YAML and RUN under the caller's `github.repository` with good and bad
# revisions, and the "refuse a codetracer revision that predates this lane"
# step is run against a fixture checkout missing each script the lane runs.
#
# What is asserted:
#   1. the plan step is found, interpolates no `${{ }}` into its body, accepts
#      codetracer-image-diff with a 40-hex revision, and refuses another
#      caller, a branch, a short sha, an upper-case sha and an empty revision;
#   2. the primary checkout is `${{ github.sha }}`, and the driver runs with
#      `--expect-image-diff-rev` set to it;
#   3. `codetracer-revision` is the only input and is required; the caller
#      passes exactly it, with `secrets: inherit` (checked when the
#      ../codetracer-image-diff checkout carries the caller, said so when not);
#   4. every repo-relative script the lane runs (the driver, and what the
#      driver runs) is in the refusal step's list, and the refusal step fails,
#      by name, on a checkout missing any of them or the recipe;
#   5. the DRIVER, run on fixture trees (no dev shell needed: it refuses before
#      it looks for one), refuses a missing library, a checkout at another
#      commit, a non-40-hex expected commit, and a tree where no module
#      imports image_diff, each with a zero TEST-COUNTS line; and `--list`
#      selects a module that imports image_diff and not one that does not;
#   6. MUTATIONS of copies of the real workflow, each of which must be
#      rejected, plus a positive control on the unmutated copy.
#
# No mocks: the inputs are this repository's own files, temporary copies of
# them and throwaway git repositories made here.
# Run: bash ci/test/image-diff-downstream-workflow-test.sh
# Lane: stock bash, awk, grep, sed, git; no Nix, no network.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
REUSABLE="$REPO_ROOT/.github/workflows/image-diff-downstream.yml"
DRIVER="$REPO_ROOT/ci/test/image-diff-consumers.sh"
CALLER="${IMAGE_DIFF_DOWNSTREAM_CALLER:-$REPO_ROOT/../codetracer-image-diff/.github/workflows/downstream.yml}"
SHA=0123456789abcdef0123456789abcdef01234567

pass=0 failn=0
ok() {
	pass=$((pass + 1))
	echo "  ok   $1"
}
fail() {
	failn=$((failn + 1))
	echo "  FAIL $1"
	shift
	for l in "$@"; do echo "       $l"; done
}
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

strip_cr() { tr -d '\r' <"$1"; }

# step_script NAME FILE -> that step's `run: |` body, dedented.
step_script() {
	strip_cr "$2" | awk -v want="      - name: $1" '
		$0 == want { in_step=1; next }
		in_step && /^      - name: / { in_step=0 }
		in_step && /^        run: \|[[:space:]]*$/ { in_run=1; next }
		in_run && /^          / { sub(/^          /, ""); print; next }
		in_run && /^[[:space:]]*$/ { print ""; next }
		in_run { in_run=0; in_step=0 }
	'
}

# wf_inputs FILE -> `name<TAB>required` per workflow_call input.
wf_inputs() {
	strip_cr "$1" | awk '
		/^on:[[:space:]]*$/            { in_on=1; next }
		in_on && /^  workflow_call:/   { in_wc=1; next }
		in_wc && /^    inputs:/        { in_inputs=1; next }
		in_wc && /^    secrets:/       { in_inputs=0; next }
		in_inputs && /^[^ ]/           { in_inputs=0; in_wc=0; in_on=0 }
		in_inputs && /^    [^ ]/       { in_inputs=0 }
		in_inputs && /^      [a-zA-Z0-9_-]+:[[:space:]]*$/ {
			if (name != "") { print name "\t" (req ? "true" : "false") }
			name=$1; sub(/:$/, "", name); req=0; next
		}
		in_inputs && /^        required:[[:space:]]*true/ { req=1; next }
		END { if (name != "") print name "\t" (req ? "true" : "false") }
	'
}

# caller_with FILE -> `key: value` lines of the `with:` of the job that uses
# image-diff-downstream.yml.
caller_with() {
	strip_cr "$1" | awk '
		/^[[:space:]]*uses:[[:space:]]*.*codetracer\/\.github\/workflows\/image-diff-downstream\.yml/ { seen=1; next }
		seen && /^    with:[[:space:]]*$/ { in_with=1; next }
		in_with && /^      [a-zA-Z0-9_-]+:/ { sub(/^      /, ""); print; next }
		in_with && /^[[:space:]]*(#.*)?$/ { next }
		in_with { in_with=0; seen=0 }
	'
}

# checkout_ref FILE -> the `ref:` of the primary checkout step.
checkout_ref() {
	strip_cr "$1" | awk '
		/^      - name: Checkout the library under test/ { s=1; next }
		s && /^      - name: / { s=0 }
		s && /^          ref:[[:space:]]*/ { r=$0; sub(/^          ref:[[:space:]]*/, "", r); print r; exit }
	'
}

# run_plan FILE REPOSITORY REVISION -> "<rc>|<outputs>"
run_plan() {
	local script="$TMP/plan.sh" ws="$TMP/runner/$2/$2" out rc
	step_script "Plan the workspace layout" "$1" >"$script"
	mkdir -p "$ws"
	: >"$TMP/out" && : >"$TMP/summary"
	out="$(cd "$ws" && GITHUB_REPOSITORY="metacraft-labs/$2" GITHUB_WORKSPACE="$ws" \
		GITHUB_OUTPUT="$TMP/out" GITHUB_STEP_SUMMARY="$TMP/summary" \
		CT_REV="$3" SELF_SHA="$SHA" bash "$script" 2>&1)" && rc=0 || rc=$?
	printf '%s|%s\n%s' "$rc" "$(cat "$TMP/out")" "$out"
}

# plan_violations FILE -> one line per broken plan-step property; empty = good.
plan_violations() {
	local f="$1" r
	[ -n "$(step_script "Plan the workspace layout" "$f")" ] || {
		echo "no 'Plan the workspace layout' run: block"
		return
	}
	if grep -q '\${{' <<<"$(step_script "Plan the workspace layout" "$f")"; then
		echo "the plan step's script interpolates \${{ }} (inputs must come through env:)"
	fi
	r="$(run_plan "$f" codetracer-image-diff "$SHA")"
	case "$r" in
	"0|"*)
		grep -qx "ct-rev=$SHA" <<<"$r" || echo "accepted a 40-hex revision but emitted no ct-rev=$SHA"
		grep -qE '^ct-dir=.*/codetracer$' <<<"$r" || echo "ct-dir is not the codetracer sibling"
		grep -qE "^(0\|)?self=codetracer-image-diff$" <<<"$r" || echo "self is not codetracer-image-diff"
		;;
	*) echo "refused codetracer-image-diff with a 40-hex revision: $(head -3 <<<"$r" | tr '\n' ' ')" ;;
	esac
	for bad in dev agents "${SHA:0:12}" "${SHA^^}" "" "refs/heads/dev"; do
		r="$(run_plan "$f" codetracer-image-diff "$bad")"
		case "$r" in "0|"*) echo "accepted codetracer-revision '$bad'" ;; esac
	done
	r="$(run_plan "$f" codetracer-php-recorder "$SHA")"
	case "$r" in "0|"*) echo "accepted a caller that is not codetracer-image-diff" ;; esac
}

# The repo-relative scripts the lane runs from the codetracer checkout:
# `${CT_DIR}/<path>.sh` in the workflow, the driver the recipe runs, and the
# scripts THAT runs (`bash ci/....sh` in this tree's copy of it).
run_scripts() {
	strip_cr "$1" | grep -oE '"\$\{CT_DIR\}/(ci|scripts)/[A-Za-z0-9_./-]+\.sh"' | sed 's/^"${CT_DIR}\///; s/"$//'
	echo ci/test/image-diff-consumers.sh
	grep -oE '^[^#]*bash (ci|scripts)/[A-Za-z0-9_./-]+\.sh' "$DRIVER" | grep -oE '(ci|scripts)/[A-Za-z0-9_./-]+\.sh'
}
refusal_list() {
	step_script "Refuse a codetracer revision that predates this lane" "$1" |
		grep -oE '(ci|scripts)/[A-Za-z0-9_./-]+\.sh' | sort -u
}

# coverage_violations FILE -> a script the lane runs that the refusal misses.
coverage_violations() {
	local s
	while read -r s; do
		[ -n "$s" ] || continue
		grep -qxF "$s" <<<"$(refusal_list "$1")" || echo "the lane runs $s but the refusal step does not check it"
	done < <(run_scripts "$1" | sort -u)
}

# run_refusal FILE MISSING -> rc of the refusal step on a fixture checkout
# that lacks MISSING (a path, or `recipe` for the just recipe).
run_refusal() {
	local ct="$TMP/refuse/codetracer" s
	rm -rf "$TMP/refuse"
	mkdir -p "$ct"
	git init -q "$ct"
	git -C "$ct" -c user.email=t@t -c user.name=t commit -q --allow-empty -m fixture
	for s in $(refusal_list "$1"); do
		mkdir -p "$ct/$(dirname "$s")"
		: >"$ct/$s"
	done
	printf 'test-image-diff-consumers *args:\n  bash ci/test/image-diff-consumers.sh {{args}}\n' >"$ct/justfile"
	case "$2" in
	"") ;;
	recipe) : >"$ct/justfile" ;;
	*) rm -f "$ct/$2" ;;
	esac
	step_script "Refuse a codetracer revision that predates this lane" "$1" >"$TMP/refuse.sh"
	CT_DIR="$ct" bash "$TMP/refuse.sh" >"$TMP/refuse.out" 2>&1
}

# static_violations FILE -> the remaining one-line properties.
static_violations() {
	local f="$1" ins
	[ "$(checkout_ref "$f")" = '${{ github.sha }}' ] || echo "the primary checkout is '$(checkout_ref "$f")', not \${{ github.sha }}"
	ins="$(wf_inputs "$f")"
	[ "$ins" = "codetracer-revision	true" ] || echo "workflow_call inputs are '$(tr '\n\t' '; ' <<<"$ins")', not exactly a required codetracer-revision"
	grep -qF 'just test-image-diff-consumers --expect-image-diff-rev "${SELF_SHA}"' <<<"$(strip_cr "$f")" ||
		echo 'no step runs just test-image-diff-consumers --expect-image-diff-rev "${SELF_SHA}"'
	[ "$(grep -c 'SELF_SHA: ${{ github.sha }}' <<<"$(strip_cr "$f")")" -ge 2 ] ||
		echo "SELF_SHA is not github.sha in both the plan and the run step"
	if grep -qE '^\s+[A-Za-z0-9_.-]+=[0-9a-f]{40}' <<<"$(strip_cr "$f")"; then
		echo "the workflow writes a sibling revision of its own"
	fi
	if grep -qE '(clone-repo|ref:[[:space:]]*(dev|main|stable|agents)[[:space:]]*$|refs/heads/)' <<<"$(strip_cr "$f")"; then
		echo "the workflow clones something at a branch"
	fi
	grep -qE '^    timeout-minutes: [0-9]+' <<<"$(strip_cr "$f")" || echo "the job has no timeout-minutes"
	grep -qE '^    runs-on: \[self-hosted, linux, x64\]' <<<"$(strip_cr "$f")" || echo "the job does not run on [self-hosted, linux, x64]"
}

all_violations() {
	plan_violations "$1"
	coverage_violations "$1"
	static_violations "$1"
	local s
	for s in $(refusal_list "$1") recipe; do
		if run_refusal "$1" "$s"; then echo "the refusal step accepted a checkout without $s"; fi
	done
	run_refusal "$1" "" || echo "the refusal step refused a complete checkout: $(cat "$TMP/refuse.out")"
}

echo "== the reusable workflow"
[ -f "$REUSABLE" ] || {
	fail "$REUSABLE exists"
	exit 1
}
v="$(all_violations "$REUSABLE")"
if [ -z "$v" ]; then ok "plan, checkout pin, inputs, refusal coverage and the driver call hold"; else fail "the reusable workflow" "${v//$'\n'/$'\n'       }"; fi
if [ "$(run_scripts "$REUSABLE" | sort -u | grep -c .)" -ge 2 ]; then
	ok "anti-vacuity: the scanner finds the scripts the lane runs ($(run_scripts "$REUSABLE" | sort -u | paste -sd' ' -))"
else
	fail "anti-vacuity: the scanner finds the scripts the lane runs"
fi

echo "== the caller"
if [ -f "$CALLER" ]; then
	w="$(caller_with "$CALLER")"
	if [[ $w =~ ^codetracer-revision:\ \$\{\{\ needs\.[a-z0-9_-]+\.outputs\.[a-z0-9_-]+\ \}\}$ ]]; then
		ok "the caller passes exactly codetracer-revision, from a resolve job's output"
	else
		fail "the caller passes exactly codetracer-revision from a resolve job's output" "with: $w"
	fi
	if grep -qE '^[[:space:]]*secrets:[[:space:]]*inherit[[:space:]]*$' <<<"$(strip_cr "$CALLER")"; then
		ok "the caller inherits secrets"
	else
		fail "the caller passes secrets: inherit"
	fi
else
	echo "  note no caller at $CALLER (codetracer-image-diff is not checked out beside this repo, or predates its lane); its half is checked by that repo's tests/test_downstream_lane.sh"
fi

echo "== the driver refuses, before it needs a dev shell"
# A fixture workspace: a codetracer tree holding a copy of the driver and one
# module that imports image_diff, and a library checkout beside it.
fx="$TMP/fx"
mk_fixture() { # $1 = module source line (`import image_diff` or other)
	rm -rf "$fx"
	mkdir -p "$fx/codetracer/ci/test" "$fx/codetracer/tools" "$fx/codetracer-image-diff/src" "$fx/codetracer-image-diff/vendor/flip"
	cp "$DRIVER" "$fx/codetracer/ci/test/image-diff-consumers.sh"
	printf '%s\n' "$1" >"$fx/codetracer/tools/uses_flip.nim"
	printf 'import std/os\n' >"$fx/codetracer/tools/unrelated.nim"
	git -C "$fx/codetracer" init -q
	git -C "$fx/codetracer" add -A
	git -C "$fx/codetracer" -c user.email=t@t -c user.name=t commit -q -m fixture
	: >"$fx/codetracer-image-diff/src/image_diff.nim"
	: >"$fx/codetracer-image-diff/src/flip_wrapper.cpp"
	: >"$fx/codetracer-image-diff/vendor/flip/FLIP.h"
	git -C "$fx/codetracer-image-diff" init -q
	git -C "$fx/codetracer-image-diff" add -A
	git -C "$fx/codetracer-image-diff" -c user.email=t@t -c user.name=t commit -q -m lib
}
drive() { bash "$fx/codetracer/ci/test/image-diff-consumers.sh" "$@" >"$TMP/drv.out" 2>&1; }
refused_with_zero_counts() { ! drive "$@" && grep -qx 'TEST-COUNTS: executed=0 passed=0 failed=0 skipped=0' "$TMP/drv.out"; }

mk_fixture 'import image_diff'
lib_head="$(git -C "$fx/codetracer-image-diff" rev-parse HEAD)"
if drive --list "--expect-image-diff-rev" "$lib_head" && grep -qx '  tools/uses_flip.nim' "$TMP/drv.out" && ! grep -q unrelated "$TMP/drv.out"; then
	ok "POSITIVE CONTROL: --list selects the module that imports image_diff, and only it"
else
	fail "--list selects the module that imports image_diff, and only it" "$(cat "$TMP/drv.out")"
fi
mk_fixture 'import std/[os, strutils], image_diff  # a list'
if drive --list && grep -qx '  tools/uses_flip.nim' "$TMP/drv.out"; then
	ok "an import list naming image_diff is selected"
else
	fail "an import list naming image_diff is selected" "$(cat "$TMP/drv.out")"
fi
mk_fixture '# import image_diff (a comment, not an import)'
if refused_with_zero_counts --list && grep -q 'no tracked Nim module imports image_diff' "$TMP/drv.out"; then
	ok "a tree where no module imports image_diff is refused, not passed"
else
	fail "a tree where no module imports image_diff is refused" "$(cat "$TMP/drv.out")"
fi
mk_fixture 'import image_diff'
if refused_with_zero_counts --list --expect-image-diff-rev "$SHA"; then
	ok "a library checkout at another commit than --expect-image-diff-rev is refused"
else
	fail "a library checkout at another commit is refused" "$(cat "$TMP/drv.out")"
fi
for bad in dev "${lib_head:0:12}" "${lib_head^^}"; do
	if refused_with_zero_counts --list --expect-image-diff-rev "$bad"; then
		ok "--expect-image-diff-rev '$bad' is refused"
	else
		fail "--expect-image-diff-rev '$bad' is refused" "$(cat "$TMP/drv.out")"
	fi
done
rm -f "$fx/codetracer-image-diff/src/flip_wrapper.cpp"
if refused_with_zero_counts --list; then ok "a library checkout without src/flip_wrapper.cpp is refused"; else fail "a library checkout without src/flip_wrapper.cpp is refused" "$(cat "$TMP/drv.out")"; fi
rm -rf "$fx/codetracer-image-diff"
if refused_with_zero_counts --list; then ok "a missing library checkout is refused"; else fail "a missing library checkout is refused" "$(cat "$TMP/drv.out")"; fi
if [ -f "$REPO_ROOT/../codetracer-image-diff/src/image_diff.nim" ]; then
	if bash "$DRIVER" --list >"$TMP/real.out" 2>&1 && grep -qx '  tools/story-parity/story_diff.nim' "$TMP/real.out"; then
		ok "this tree's selection includes tools/story-parity/story_diff.nim"
	else
		fail "this tree's selection includes tools/story-parity/story_diff.nim" "$(cat "$TMP/real.out")"
	fi
else
	echo "  note ../codetracer-image-diff is not checked out; this tree's own selection was not listed"
fi

echo "== mutations (each must be rejected)"
mutate() { # NAME SED-EXPR
	local m="$TMP/mut.yml"
	sed -E "$2" "$REUSABLE" >"$m"
	if cmp -s "$m" "$REUSABLE"; then
		fail "mutation '$1' changed nothing (the mutation is stale)"
		return
	fi
	if [ -n "$(all_violations "$m")" ]; then ok "rejected: $1"; else fail "NOT rejected: $1"; fi
}
mutate "the revision check accepts a branch" 's/if ! \[\[ "\$\{CT_REV\}" =~ \^\[0-9a-f\]\{40\}\$ \]\]; then/if false; then/'
mutate "any caller is accepted" 's/if \[ "\$\{SELF\}" != codetracer-image-diff \]; then/if false; then/'
mutate "the plan interpolates the input" 's/echo "codetracer revision:          \$\{CT_REV\}"/echo "codetracer revision: ${{ inputs.codetracer-revision }}"/'
mutate "the primary checkout follows a branch" 's/^          ref: \$\{\{ github.sha \}\}/          ref: dev/'
mutate "the refusal forgets the driver" 's|for script in ci/test/image-diff-consumers.sh |for script in |'
mutate "the refusal forgets a script the driver runs" 's| ci/test/plat37-parity.sh; do|; do|'
mutate "the refusal forgets the recipe" "s/if ! grep -q '\\^test-image-diff-consumers'/if false \\&\\& grep -q 'x'/"
mutate "the driver is not held to the checked-out commit" 's/ --expect-image-diff-rev "\$\{SELF_SHA\}"//'
mutate "a second, optional input appears" 's/^    secrets:$/      codetracer-ref:\n        required: false\n        type: string\n    secrets:/'
mutate "the job loses its timeout" '/^    timeout-minutes: /d'
mutate "codetracer is cloned at a branch" 's/fetch -q --depth 1 origin "\$\{CT_REV\}"/fetch -q --depth 1 origin refs\/heads\/dev/'
cp "$REUSABLE" "$TMP/control.yml"
if [ -z "$(all_violations "$TMP/control.yml")" ]; then ok "POSITIVE CONTROL: the unmutated copy passes"; else fail "POSITIVE CONTROL: the unmutated copy passes"; fi

echo
if [ "$failn" -eq 0 ]; then
	echo "image-diff-downstream-workflow-test: $pass assertions passed"
else
	echo "image-diff-downstream-workflow-test: $failn of $((pass + failn)) assertions FAILED"
	exit 1
fi
