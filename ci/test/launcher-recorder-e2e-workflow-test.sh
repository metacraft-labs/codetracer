#!/usr/bin/env bash
# =============================================================================
# Contract: the launcher <-> recorder E2E workflow and its four callers agree,
# the repo under test is pinned to the commit under test, the triggering repo is
# never listed as its own sibling, and no sibling revision is pinned by anything
# but the workspace lock.
#
# # Why this file exists
#
# Three separate defects in this gate's CI wiring have been paid for already,
# and none of them is reachable by a YAML linter:
#
#   1. THE `rm -rf` OF THE PRIMARY CHECKOUT.  The first implementation of
#      `launcher-recorder-e2e.yml` made `codetracer` the primary
#      `actions/checkout` on every edge and passed the TRIGGERING repo among
#      the `siblings:`.  The runner's workspace is `.../_work/<repo>/<repo>`,
#      `clone-siblings` clones each sibling to `$GITHUB_WORKSPACE/../<name>`,
#      and `git-auth/authenticated-clone.sh` opens with `rm -rf "$DEST"` -- so
#      on 2 of the 3 edges the job deleted its own checkout mid-run.  The
#      "Plan the workspace layout" step exists to prevent exactly that.  A grep
#      for the fix is not a test of it; this file RUNS that step's script under
#      each caller's `github.repository` and checks what it emits.
#
#   2. THE `workflow_call` CONTRACT IS UNLINTED.  `actionlint` does not check a
#      caller's `with:` against the reusable workflow's declared `inputs:`.  A
#      misspelled key that ALSO leaves a required input unpassed lints clean
#      and fails at run time, on a self-hosted runner nobody is watching.  The
#      checker below is that missing check, and mutation M3 is precisely that
#      defect.
#
#   3. UNREPRODUCIBLE SIBLING PINS.  Until milestone LRC-6 every sibling was
#      passed as `name=<branch>`, so `clone-siblings` took its override path,
#      never consulted the workspace lock, and emitted one
#      `::warning:: ... is therefore not reproducible` per entry.  The revision
#      now comes from the per-commit workspace lock
#      (metacraft-dev-guidelines/policies/ci-shared-dev-env.md section 3.2), and
#      the set of names from this repo's `.github/sibling-repos` clone-list.
#      Both halves are asserted here so the deviation cannot creep back.
#
# And one more, which is the WORST failure this gate can have and which the
# LRC-6 review found had no coverage at all:
#
#   4. THE REPO UNDER TEST NOT BEING THE COMMIT UNDER TEST.  Before LRC-6 the
#      primary checkout read a `<self>-ref` input and the planner refused an
#      empty one.  LRC-6 removed the input (correctly: in a reusable workflow
#      `github.sha` IS the caller's commit) but removed the guard with it, and
#      nothing replaced it.  A `ref:` naming a branch instead would make every
#      edge report green about code that is not under test -- the one failure
#      mode nobody would notice.  Assertion 4 below pins that line.
#
# # No mocks
#
# The workflow files as committed are the input, and the "Plan the workspace
# layout" step's script is EXTRACTED FROM THE YAML and executed -- not
# transcribed, not reimplemented.  The only synthesised things are the
# `GITHUB_*` variables GitHub would set and a temp directory laid out like a
# runner workspace, because there is no way to observe a step's outputs
# otherwise.  Every mutation in the last section is applied to a COPY of a real
# file, never to the checker's own assertions, and every mutation is checked
# THROUGH THE FUNCTION THE REAL ASSERTION USES -- an inline re-implementation of
# a rule tests the transcription, not the rule.  (LRC-6's review found three
# such transcriptions here and replaced them; see M7-M9.)
#
# # What is asserted
#
#   1. The extraction really found the planner (anti-vacuity), and its script
#      body interpolates no `${{ }}` -- otherwise what runs here is not what
#      runs in CI.
#   2. The primary `actions/checkout` pins the repo under test to
#      `${{ github.sha }}` -- the caller's commit, and the only pin left after
#      LRC-6 dropped the `*-ref` inputs.
#   3. The (caller x recorder) combinations are DERIVED from the callers' own
#      matrices rather than transcribed here, so a recorder added to a fan-out
#      cannot escape the checks below; the known nine are a floor.
#   4. For each derived combination: the planner emits exactly 3 siblings, the
#      triggering repo is NOT among them, no entry carries `=<ref>`, and
#      `ct-dir` points at the codetracer checkout.
#   5. A caller that is none of the four repos is refused.
#   6. `workflow_call` contract: every `with:` key a caller passes is a
#      declared input; every REQUIRED input is passed; secrets are inherited.
#   7. The reusable workflow declares no `*-ref` input and no caller passes
#      one (the LRC-6 migration invariant).
#   8. `.github/sibling-repos` exists, carries names only (no `=`, no
#      revisions), and declares every sibling the workflow can emit apart from
#      `codetracer` itself, which is never its own sibling.
#   9. Every `setup-dev-env` / `clone-siblings` call site in this repo passes an
#      explicit `siblings:` input, so adding the clone-list changed no existing
#      job.  The day one stops, this fails and the change is deliberate.
#  10. THE CHECKER'S OWN MUTATION TEST: thirteen mutations of real files, each of
#      which must be REJECTED, plus a positive control on the unmutated copies
#      so a checker that always fails cannot pass this section.
#
# Run: bash ci/test/launcher-recorder-e2e-workflow-test.sh
# Lane: stock bash; no Nix, no dev shell, no network.  The three remote callers
#       are read from their sibling checkouts when present; the in-repo caller
#       is always checked and its absence is a failure.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly REPO_ROOT
readonly REUSABLE="$REPO_ROOT/.github/workflows/launcher-recorder-e2e.yml"
readonly DESKTOP_EDGE="$REPO_ROOT/.github/workflows/launcher-recorder-e2e-desktop-edge.yml"
readonly CLONE_LIST="$REPO_ROOT/.github/sibling-repos"
PARENT_DIR="$(cd "$REPO_ROOT/.." && pwd -P)"
readonly PARENT_DIR

# GitHub Actions' expression opener, quoted verbatim so this file can talk
# about it without writing one.
# shellcheck disable=SC2016
readonly EXPR_OPEN='${{'

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

TMP="$(mktemp -d)"
# shellcheck disable=SC2317,SC2329  # reached through the EXIT trap below
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Parsing helpers.
#
# Deliberately a small, explicit scanner rather than a YAML library: this must
# run on a stock runner with bash and nothing else, in the same spirit as
# ci/test/sibling-provisioning-test.sh.  The structures read here are the two
# fixed shapes of a `workflow_call` contract and one step's `run:` block, both
# of which are stable and shallow.
# ---------------------------------------------------------------------------

# strip_cr FILE -> the file with any trailing CR removed, on stdout.
# `actions/checkout` on Windows honours core.autocrlf, and a stray CR would
# stick to the last token of every line and silently break every comparison.
strip_cr() { tr -d '\r' <"$1"; }

# wf_inputs FILE -> one `name<TAB>required` line per declared workflow_call
# input.  Walks `on:` -> `workflow_call:` -> `inputs:` by indentation.
wf_inputs() {
	strip_cr "$1" | awk '
		/^on:[[:space:]]*$/            { in_on=1; next }
		in_on && /^  workflow_call:/   { in_wc=1; next }
		in_wc && /^    inputs:/        { in_inputs=1; in_secrets=0; next }
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

# caller_with FILE -> one `key` per line from the `with:` block of the job that
# `uses:` the launcher-recorder-e2e reusable workflow.
caller_with() {
	strip_cr "$1" | awk '
		/^[[:space:]]*uses:[[:space:]]*.*launcher-recorder-e2e\.yml/ { seen_uses=1; next }
		seen_uses && /^    with:[[:space:]]*$/ { in_with=1; next }
		in_with && /^      [a-zA-Z0-9_-]+:/ {
			k=$1; sub(/:$/, "", k); print k; next
		}
		in_with && /^[[:space:]]*#/ { next }
		in_with && /^[[:space:]]*$/ { next }
		in_with { in_with=0 }
	'
}

# caller_secrets_inherit FILE -> exit 0 when the caller passes `secrets: inherit`.
caller_secrets_inherit() {
	strip_cr "$1" | grep -qE '^[[:space:]]*secrets:[[:space:]]*inherit[[:space:]]*$'
}

# caller_recorders FILE -> every recorder repo this caller can ask for, one per
# line.  DERIVED, not transcribed: a caller says it either through a matrix
# (`- recorder: <name>` rows, fanned out) or through a literal
# `recorder-repo: <name>` in its `with:`.  A `${{ }}` value is a matrix
# reference and is skipped -- the matrix rows themselves are the answer.
#
# This is what makes the clone-list coverage assertion track reality: before
# LRC-6's review the nine combinations were written out by hand here, so adding
# a fourth recorder to a fan-out left the new sibling unchecked and undeclared
# while this suite stayed green.
caller_recorders() {
	strip_cr "$1" | awk '
		/^[[:space:]]*-[[:space:]]+recorder:[[:space:]]+[^ ]+[[:space:]]*$/ {
			print $3; next
		}
		/^[[:space:]]*recorder-repo:[[:space:]]+[^ ]+[[:space:]]*$/ {
			if ($2 !~ /\$\{\{/) print $2
		}
	' | sort -u
}

# checkout_ref FILE -> the `ref:` of the primary `actions/checkout` step, and
# the `uses:` line it belongs to, as `<uses><TAB><ref>`.
#
# THE REPO UNDER TEST IS PINNED HERE AND NOWHERE ELSE.  Since LRC-6 there is no
# `<self>-ref` input and no planner guard over it, so this one line is the whole
# mechanism; if it ever names a branch, every edge tests the wrong commit and
# reports green.  Parsed rather than grepped so the assertion is about THIS
# step, not about the string appearing somewhere in the file.
checkout_ref() {
	strip_cr "$1" | awk '
		/^      - name: Checkout the triggering repository/ { in_step=1; next }
		in_step && /^      - name: / { in_step=0 }
		in_step && /^        uses:[[:space:]]*/ { u=$0; sub(/^        uses:[[:space:]]*/, "", u); next }
		in_step && /^          ref:[[:space:]]*/ {
			r=$0; sub(/^          ref:[[:space:]]*/, "", r)
			print u "\t" r; exit
		}
	'
}

# extract_plan_script FILE -> the "Plan the workspace layout" step's `run:`
# body, dedented, on stdout.
extract_plan_script() {
	strip_cr "$1" | awk '
		/^      - name: Plan the workspace layout[[:space:]]*$/ { in_step=1; next }
		in_step && /^      - name: / { in_step=0 }
		in_step && /^        run: \|[[:space:]]*$/ { in_run=1; next }
		in_run && /^          / { sub(/^          /, ""); print; next }
		in_run && /^[[:space:]]*$/ { print ""; next }
		in_run { in_run=0; in_step=0 }
	'
}

# plan_env_block FILE -> the `env:` mapping lines of that same step.
plan_env_block() {
	strip_cr "$1" | awk '
		/^      - name: Plan the workspace layout[[:space:]]*$/ { in_step=1; next }
		in_step && /^      - name: / { in_step=0 }
		in_step && /^        env:[[:space:]]*$/ { in_env=1; next }
		in_env && /^          [A-Z_]+:/ { print; next }
		in_env { in_env=0 }
	'
}

# ---------------------------------------------------------------------------
# The four callers, discovered once.  The in-repo one is mandatory; the three
# remote ones are read from their sibling checkouts, and a sibling that is
# present but carries no caller is a failure rather than a silent pass.
#
# Each entry is `<file>|<label>|<github.repository short name>`.
# ---------------------------------------------------------------------------
declare -a CALLER_FILES=("$DESKTOP_EDGE")
declare -a CALLER_LABELS=("codetracer/launcher-recorder-e2e-desktop-edge.yml")
declare -a CALLER_REPOS=("codetracer")
declare -a CALLER_ABSENT=()
for sib in codetracer-launcher codetracer-python-recorder codetracer-ruby-recorder codetracer-js-recorder; do
	sib_wf="$PARENT_DIR/$sib/.github/workflows/launcher-recorder-e2e.yml"
	if [ -f "$sib_wf" ]; then
		CALLER_FILES+=("$sib_wf")
		CALLER_LABELS+=("$sib/launcher-recorder-e2e.yml")
		CALLER_REPOS+=("$sib")
	elif [ -d "$PARENT_DIR/$sib" ]; then
		CALLER_FILES+=("$sib_wf")
		CALLER_LABELS+=("$sib/launcher-recorder-e2e.yml (MISSING from a checked-out sibling)")
		CALLER_REPOS+=("$sib")
	else
		CALLER_ABSENT+=("$sib")
	fi
done

# ---------------------------------------------------------------------------
# 1. The extraction found the real planner.
#
# Every assertion below runs the EXTRACTED script.  If the extraction silently
# produced nothing -- a renamed step, a reindented `run:`, an awk regression --
# then "the triggering repo is not among the siblings" would be true of an
# empty string and this whole suite would pass vacuously.  So the extraction is
# checked first, by content.
# ---------------------------------------------------------------------------
echo "the workspace planner is extractable from the workflow"

PLAN="$TMP/plan.sh"
extract_plan_script "$REUSABLE" >"$PLAN"
plan_lines="$(wc -l <"$PLAN" | tr -d ' ')"

if [ "$plan_lines" -ge 30 ] && grep -q 'SIB_NAMES' "$PLAN" && grep -q 'GITHUB_OUTPUT' "$PLAN"; then
	ok "extracted the 'Plan the workspace layout' script ($plan_lines lines, names SIB_NAMES and GITHUB_OUTPUT)"
else
	fail "extracted the 'Plan the workspace layout' script" \
		"got $plan_lines line(s); the step was renamed, the run: block reindented, or the" \
		"extractor regressed. Every simulation below would then prove nothing."
fi

# A `${{ }}` in the body would be substituted by GitHub before bash ever sees
# it, so the text executed here would differ from the text executed in CI and
# the simulation would be testing a different program.
if grep -qF "$EXPR_OPEN" "$PLAN"; then
	fail "the planner's script body interpolates no ${EXPR_OPEN} expression" \
		"an interpolated value is spliced in as shell TEXT before bash runs, so this" \
		"simulation would execute a different program than CI does. Pass it through env:." \
		"$(grep -nF "$EXPR_OPEN" "$PLAN")"
else
	ok "the planner's script body takes everything through env: (no ${EXPR_OPEN} interpolation)"
fi

# The two env entries the simulation depends on must actually be the ones CI
# supplies, or the simulation is feeding the script values it would never get.
env_block="$(plan_env_block "$REUSABLE")"
if printf '%s\n' "$env_block" | grep -qF 'SELF_SHA: '"$EXPR_OPEN"' github.sha }}' &&
	printf '%s\n' "$env_block" | grep -qF 'RECORDER_REPO: '"$EXPR_OPEN"' inputs.recorder-repo }}'; then
	ok "the planner reads github.sha and inputs.recorder-repo through env:, as simulated"
else
	fail "the planner reads github.sha and inputs.recorder-repo through env:" \
		"the simulation exports SELF_SHA and RECORDER_REPO; if the step no longer maps" \
		"them from those expressions, the simulated inputs are not CI's inputs." \
		"env: block was:" "$env_block"
fi

# ---------------------------------------------------------------------------
# 2. THE REPO UNDER TEST IS THE COMMIT UNDER TEST.
#
# This is the assertion whose absence the LRC-6 review found: the migration
# removed the four `*-ref` inputs AND the planner's empty-ref guard, leaving the
# whole repo-under-test pin in one unwatched `ref:` line.  `ref: dev` there
# lints clean, passes every other check in this file, and makes all nine jobs
# report on code that is not under test.
#
# `${{ github.sha }}` is required literally: in a reusable workflow the `github`
# context is the CALLER's (GitHub docs, "Reusing workflow configurations"), so
# this is the caller's commit -- the pushed commit on a push, the merge commit
# the checks run against on a pull_request.
# ---------------------------------------------------------------------------
# check_checkout_pin FILE LABEL -> prints one violation per line; exit 1 when
# there is at least one.  Factored out so the mutation section can point it at
# a deliberately broken copy rather than re-implement the rule.
check_checkout_pin() {
	local file="$1" label="$2" line uses ref
	line="$(checkout_ref "$file")"
	if [ -z "$line" ]; then
		echo "$label: could not find the primary checkout step's ref: -- the step was renamed or reindented, so this assertion would prove nothing"
		return 1
	fi
	uses="${line%%$'\t'*}"
	ref="${line#*$'\t'}"
	case "$uses" in
	actions/checkout@*) ;;
	*)
		echo "$label: the primary checkout step uses '$uses', not actions/checkout"
		return 1
		;;
	esac
	if [ "$ref" != "$EXPR_OPEN github.sha }}" ]; then
		echo "$label: the repo under test is checked out at '$ref', not '$EXPR_OPEN github.sha }}'. Since LRC-6 this line IS the repo-under-test pin (there is no *-ref input and no planner guard behind it); anything else makes every edge report on a commit that is not the one under test."
		return 1
	fi
	return 0
}

pin_out="$(check_checkout_pin "$REUSABLE" "launcher-recorder-e2e.yml" 2>&1)" || true
if [ -z "$pin_out" ]; then
	ok "the repo under test is pinned to ${EXPR_OPEN} github.sha }} by the primary actions/checkout"
else
	fail "the repo under test is pinned to ${EXPR_OPEN} github.sha }} by the primary actions/checkout" \
		"$pin_out"
fi

# ---------------------------------------------------------------------------
# 3/4. Run the planner as each caller, and check what it emits.
#
# `run_plan <github.repository> <recorder-repo>` lays out a temp directory the
# way a runner does -- `<parent>/<repo>/<repo>` -- and executes the extracted
# script with the GITHUB_* variables GitHub would set.
# ---------------------------------------------------------------------------

_plan_rc=0
_plan_out=""
_plan_siblings=""
_plan_self=""
_plan_ctdir=""

run_plan() { # $1 = owner/repo, $2 = recorder repo
	local repo_full="$1" recorder="$2"
	local short="${repo_full##*/}"
	local root ws out
	root="$TMP/run.$$.$RANDOM"
	ws="$root/$short/$short"
	mkdir -p "$ws"
	out="$root/output"
	: >"$out"
	_plan_out="$(
		cd "$ws" || exit 99
		GITHUB_REPOSITORY="$repo_full" \
			GITHUB_WORKSPACE="$ws" \
			GITHUB_OUTPUT="$out" \
			EDGE="simulated edge" \
			RECORDER_REPO="$recorder" \
			RECORDER_LANG="sim" \
			SELF_SHA="0123456789abcdef0123456789abcdef01234567" \
			bash "$PLAN" 2>&1
	)"
	_plan_rc=$?
	_plan_self="$(sed -n 's/^self=//p' "$out")"
	_plan_ctdir="$(sed -n 's/^ct-dir=//p' "$out")"
	_plan_siblings="$(awk '/^siblings<</{f=1;next} /_SIBLINGS_EOF$/{f=0} f' "$out")"
	rm -rf "$root"
}

# plan_case_violations LABEL SHORT -> prints one violation per line for the
# LAST run_plan result.  This is the real rule set; the mutation section drives
# the same function so that neutralising a rule here cannot go unnoticed.
plan_case_violations() {
	local label="$1" short="$2" count sib
	if [ "$_plan_rc" -ne 0 ]; then
		echo "$label: planner exited $_plan_rc: $_plan_out"
		return
	fi
	count="$(printf '%s\n' "$_plan_siblings" | grep -c '[^[:space:]]')"
	if [ "$count" -ne 3 ]; then
		echo "$label: emitted $count sibling(s), expected 3: $(printf '%s' "$_plan_siblings" | tr '\n' ' ')"
	fi
	while IFS= read -r sib; do
		[ -z "$sib" ] && continue
		if [ "$sib" = "$short" ]; then
			echo "$label: THE TRIGGERING REPO '$sib' IS IN ITS OWN SIBLING LIST -- clone-siblings would rm -rf \$GITHUB_WORKSPACE"
		fi
		case "$sib" in
		*=*) echo "$label: sibling entry '$sib' carries an explicit ref; revisions must come from the workspace lock" ;;
		esac
	done <<<"$_plan_siblings"
	if [ "$_plan_self" != "$short" ]; then
		echo "$label: self='$_plan_self', expected '$short'"
	fi
	# ct-dir is $GITHUB_WORKSPACE on the desktop edge and the sibling
	# codetracer checkout everywhere else.
	case "$short" in
	codetracer)
		case "$_plan_ctdir" in
		*/codetracer/codetracer) ;;
		*) echo "$label: ct-dir='$_plan_ctdir' is not the primary checkout" ;;
		esac
		;;
	*)
		case "$_plan_ctdir" in
		*/codetracer) ;;
		*) echo "$label: ct-dir='$_plan_ctdir' is not the sibling codetracer checkout" ;;
		esac
		;;
	esac
}

echo
echo "the planner never lists the triggering repo as its own sibling"

# The (caller, recorder) pairs, DERIVED from the callers' own matrices.  Every
# recorder a caller can fan out to becomes a case, so a row added to a fan-out
# is simulated -- and its sibling name checked against the clone-list -- without
# anyone remembering to edit this file.
CALLER_CASES=()
derive_bad=()
for i in "${!CALLER_FILES[@]}"; do
	f="${CALLER_FILES[$i]}"
	[ -f "$f" ] || continue
	recs="$(caller_recorders "$f")"
	if [ -z "$recs" ]; then
		derive_bad+=("${CALLER_LABELS[$i]}: no recorder repo could be derived from it (neither a matrix row nor a literal recorder-repo:)")
		continue
	fi
	while IFS= read -r rec; do
		[ -z "$rec" ] && continue
		CALLER_CASES+=("metacraft-labs/${CALLER_REPOS[$i]}|$rec")
	done <<<"$recs"
done

# Anti-vacuity for the derivation itself: the nine combinations this gate is
# known to span are a FLOOR.  If the matrix parser regresses, the loop below
# would run over a short list and every assertion in it would be weaker without
# saying so.
KNOWN_FLOOR=(
	"metacraft-labs/codetracer|codetracer-python-recorder"
	"metacraft-labs/codetracer|codetracer-ruby-recorder"
	"metacraft-labs/codetracer|codetracer-js-recorder"
	"metacraft-labs/codetracer-launcher|codetracer-python-recorder"
	"metacraft-labs/codetracer-launcher|codetracer-ruby-recorder"
	"metacraft-labs/codetracer-launcher|codetracer-js-recorder"
	"metacraft-labs/codetracer-python-recorder|codetracer-python-recorder"
	"metacraft-labs/codetracer-ruby-recorder|codetracer-ruby-recorder"
	"metacraft-labs/codetracer-js-recorder|codetracer-js-recorder"
)
floor_reachable=0
for want in "${KNOWN_FLOOR[@]}"; do
	caller_short="${want%%|*}"
	caller_short="${caller_short##*/}"
	# A caller whose repo is not checked out beside this one cannot contribute.
	# That is the normal case in the `ci-verdict` lane, which checks out
	# `codetracer` alone; the three remote callers are reported as unchecked
	# rather than silently dropped.
	skip=0
	for absent in ${CALLER_ABSENT[@]+"${CALLER_ABSENT[@]}"}; do
		[ "$absent" = "$caller_short" ] && skip=1
	done
	[ "$skip" -eq 1 ] && continue
	floor_reachable=$((floor_reachable + 1))
	found=0
	for have in ${CALLER_CASES[@]+"${CALLER_CASES[@]}"}; do
		[ "$have" = "$want" ] && found=1
	done
	[ "$found" -eq 1 ] || derive_bad+=("the known combination '$want' was not derived from the caller workflows; the matrix parser regressed or a caller lost a row")
done

if [ "${#derive_bad[@]}" -eq 0 ] && [ "${#CALLER_CASES[@]}" -ge 1 ]; then
	ok "derived ${#CALLER_CASES[@]} (caller x recorder) combination(s) from the callers' own matrices, covering all $floor_reachable of the known nine that are reachable here"
else
	fail "derived the (caller x recorder) combinations from the callers' own matrices" \
		"${derive_bad[@]:-no combination could be derived at all}"
fi

# Every sibling name the planner can ever emit, accumulated across the cases
# above and compared against the clone-list further down.
EMITTED_SIBLINGS=""

plan_bad=()
for case_spec in ${CALLER_CASES[@]+"${CALLER_CASES[@]}"}; do
	repo_full="${case_spec%%|*}"
	recorder="${case_spec##*|}"
	short="${repo_full##*/}"
	run_plan "$repo_full" "$recorder"
	label="$short + $recorder"

	while IFS= read -r v; do
		[ -n "$v" ] && plan_bad+=("$v")
	done < <(plan_case_violations "$label" "$short")

	while IFS= read -r sib; do
		[ -z "$sib" ] && continue
		EMITTED_SIBLINGS="$EMITTED_SIBLINGS $sib"
	done <<<"$_plan_siblings"
done

if [ "${#plan_bad[@]}" -eq 0 ]; then
	ok "all ${#CALLER_CASES[@]} caller/recorder combinations emit 3 lock-resolved siblings, none of them the trigger"
else
	fail "all caller/recorder combinations emit 3 lock-resolved siblings, none of them the trigger" \
		"${plan_bad[@]}"
fi

run_plan "metacraft-labs/codetracer-beam-recorder" "codetracer-python-recorder"
if [ "$_plan_rc" -ne 0 ] && printf '%s' "$_plan_out" | grep -q 'is neither codetracer'; then
	ok "a caller that is none of the four repos is refused, by name"
else
	fail "a caller that is none of the four repos is refused" \
		"exit $_plan_rc; output: $_plan_out" \
		"a fifth caller has no defined place in this workspace layout and must not get one by default"
fi

# ---------------------------------------------------------------------------
# 6/7. The `workflow_call` contract, which actionlint does not check.
# ---------------------------------------------------------------------------
echo
echo "every caller's with:/secrets: matches the reusable workflow's declaration"

# check_contract REUSABLE CALLER LABEL -> prints one violation per line; exit 1
# when there is at least one.  Factored out so the mutation section can point it
# at deliberately broken copies.
check_contract() {
	local reusable="$1" caller="$2" label="$3"
	local bad=0 declared required passed name
	declared="$(wf_inputs "$reusable" | cut -f1)"
	required="$(wf_inputs "$reusable" | awk -F'\t' '$2=="true"{print $1}')"
	passed="$(caller_with "$caller")"

	if [ -z "$declared" ]; then
		echo "$label: the reusable workflow declares NO workflow_call inputs -- the parse failed, so this check proves nothing"
		return 1
	fi
	if [ -z "$passed" ]; then
		echo "$label: the caller passes NO with: keys -- the parse failed, or the caller is not wired"
		return 1
	fi

	while IFS= read -r name; do
		[ -z "$name" ] && continue
		if ! printf '%s\n' "$declared" | grep -qx -- "$name"; then
			echo "$label: passes 'with: $name', which the reusable workflow does not declare"
			bad=1
		fi
		case "$name" in
		*-ref)
			echo "$label: passes '$name'; sibling revisions come from the workspace lock (ci-shared-dev-env.md section 3.2), not from a caller input"
			bad=1
			;;
		esac
	done <<<"$passed"

	while IFS= read -r name; do
		[ -z "$name" ] && continue
		if ! printf '%s\n' "$passed" | grep -qx -- "$name"; then
			echo "$label: does not pass required input '$name'"
			bad=1
		fi
	done <<<"$required"

	if ! caller_secrets_inherit "$caller"; then
		echo "$label: does not pass 'secrets: inherit'; the reusable workflow mints a token from CI_TOKEN_PROVIDER_* and cannot see the caller's secrets otherwise"
		bad=1
	fi
	return "$bad"
}

if [ ! -f "$DESKTOP_EDGE" ]; then
	fail "the in-repo desktop-edge caller exists" "$DESKTOP_EDGE not found"
fi

contract_bad=()
for i in "${!CALLER_FILES[@]}"; do
	out="$(check_contract "$REUSABLE" "${CALLER_FILES[$i]}" "${CALLER_LABELS[$i]}" 2>&1)" || true
	if [ -n "$out" ]; then
		while IFS= read -r line; do contract_bad+=("$line"); done <<<"$out"
	fi
done

if [ "${#contract_bad[@]}" -eq 0 ]; then
	ok "all ${#CALLER_FILES[@]} caller(s) pass only declared inputs, pass every required one, and inherit secrets"
else
	fail "all callers pass only declared inputs, pass every required one, and inherit secrets" \
		"${contract_bad[@]}"
fi

if [ "${#CALLER_ABSENT[@]}" -gt 0 ]; then
	printf '  note %s\n' "not checked (sibling repo not checked out beside this one): ${CALLER_ABSENT[*]}"
fi

# The migration invariant, stated on the declaration side too: a `*-ref` input
# cannot be passed if it cannot be declared.
ref_inputs="$(wf_inputs "$REUSABLE" | cut -f1 | grep -E -- '-ref$' || true)"
if [ -z "$ref_inputs" ]; then
	ok "the reusable workflow declares no '*-ref' input"
else
	fail "the reusable workflow declares no '*-ref' input" \
		"sibling revisions come from the per-commit workspace lock; an input that can override one" \
		"reintroduces the unreproducible pin LRC-6 removed:" "$ref_inputs"
fi

# ---------------------------------------------------------------------------
# 8/9. The clone-list.
# ---------------------------------------------------------------------------
echo
echo ".github/sibling-repos is a names-only clone-list that covers the gate"

# clone_list_entries FILE -> one bare entry per line, comments stripped.
clone_list_entries() {
	strip_cr "$1" 2>/dev/null | sed 's/#.*//' | tr -s '[:space:]' '\n' | grep -v '^$' || true
}

# check_clone_list FILE -> prints one violation per line; exit 1 when there is
# at least one.  Factored out so M7/M8 exercise THIS code rather than a
# transcription of it -- the LRC-6 review proved the previous inline mutation
# passed unchanged when this rule was deleted.
check_clone_list() {
	local file="$1" entries e bad=0
	entries="$(clone_list_entries "$file")"
	if [ -z "$entries" ]; then
		echo "the clone-list parsed to nothing"
		return 1
	fi
	while IFS= read -r e; do
		[ -z "$e" ] && continue
		case "$e" in
		*=*)
			echo "'$e' pins a revision; the clone-list carries names only and the revision comes from the lock"
			bad=1
			;;
		*/*)
			echo "'$e' is not a bare repo name"
			bad=1
			;;
		esac
		if [ "$e" = "codetracer" ]; then
			echo "'codetracer' lists itself; clone-siblings would clone it over \$GITHUB_WORKSPACE"
			bad=1
		fi
	done <<<"$entries"
	return "$bad"
}

if [ -f "$CLONE_LIST" ]; then
	ok "the clone-list exists at .github/sibling-repos"
else
	fail "the clone-list exists at .github/sibling-repos" \
		"metacraft-dev-guidelines/policies/ci-shared-dev-env.md section 3.2: the set of siblings" \
		"comes from the repo's blessed clone-list"
fi

clone_entries="$(clone_list_entries "$CLONE_LIST")"
clone_out="$(check_clone_list "$CLONE_LIST" 2>&1)" || true
if [ -z "$clone_out" ]; then
	ok "all $(printf '%s\n' "$clone_entries" | grep -c .) clone-list entries are bare repo names"
else
	fail "all clone-list entries are bare repo names" "$clone_out"
fi

# Every name the planner can emit must be declared, so a recorder added to a
# fan-out matrix without being added here is a failure rather than a surprise.
# The cases above are derived from the matrices, so this now tracks them.
uncovered=()
for sib in $(printf '%s' "$EMITTED_SIBLINGS" | tr ' ' '\n' | sort -u); do
	[ "$sib" = "codetracer" ] && continue
	printf '%s\n' "$clone_entries" | grep -qx -- "$sib" || uncovered+=("$sib")
done
if [ "${#uncovered[@]}" -eq 0 ] && [ -n "$EMITTED_SIBLINGS" ]; then
	ok "every sibling the workflow can emit is declared in the clone-list"
else
	fail "every sibling the workflow can emit is declared in the clone-list" \
		"${uncovered[@]:-the planner emitted nothing, so this proves nothing}"
fi

# The clone-list is read only when a call site passes no `siblings:`.  Every
# call site passes one today, which is why adding the file changed no job; that
# is a fact worth holding still.
#
# check_call_sites FILE... -> prints one `file:line` per call site that passes
# no `siblings:`.  Factored so M12 can point it at a mutated copy.
check_call_sites() {
	local hit f n bad=0
	while IFS= read -r hit; do
		[ -z "$hit" ] && continue
		f="${hit%%:*}"
		n="${hit#*:}"
		n="${n%%:*}"
		# `siblings:` may appear up to ~40 lines below the `uses:` (the
		# action takes many other inputs first).
		if ! strip_cr "$f" | sed -n "${n},$((n + 40))p" | grep -q '^ *siblings:'; then
			echo "$f:$n"
			bad=1
		fi
	done < <(grep -n 'uses: metacraft-labs/metacraft-github-actions/\(setup-dev-env\|clone-siblings\)@' "$@" 2>/dev/null |
		if [ "$#" -eq 1 ]; then sed "s|^|$1:|"; else cat; fi)
	return "$bad"
}

mapfile -t CALL_SITE_FILES < <(grep -rl 'uses: metacraft-labs/metacraft-github-actions/\(setup-dev-env\|clone-siblings\)@' \
	"$REPO_ROOT/.github/workflows" "$REPO_ROOT/.github/actions" 2>/dev/null | sort)

sibless=()
if [ "${#CALL_SITE_FILES[@]}" -eq 0 ]; then
	sibless+=("no setup-dev-env / clone-siblings call site was found at all -- the scan regressed")
else
	while IFS= read -r line; do
		[ -n "$line" ] && sibless+=("$line")
	done < <(check_call_sites "${CALL_SITE_FILES[@]}" 2>&1)
fi

n_call_sites="$(grep -rc 'uses: metacraft-labs/metacraft-github-actions/\(setup-dev-env\|clone-siblings\)@' \
	"$REPO_ROOT/.github/workflows" "$REPO_ROOT/.github/actions" 2>/dev/null |
	awk -F: '{s+=$2} END {print s+0}')"

if [ "${#sibless[@]}" -eq 0 ]; then
	ok "all $n_call_sites setup-dev-env / clone-siblings call sites pass an explicit siblings: subset"
else
	fail "every setup-dev-env / clone-siblings call site passes an explicit siblings: subset" \
		"these would silently fall back to .github/sibling-repos, cloning five repos and" \
		"requiring a workspace-lock entry for each -- make that switch deliberately:" \
		"${sibless[@]}"
fi

# ---------------------------------------------------------------------------
# 10. THE CHECKER'S OWN MUTATION TEST.
#
# Everything above reports a defect by NOT finding something, which is the
# shape that produces vacuous greens.  So the checks are run against real files
# that have been deliberately broken, and each must be REJECTED.  The positive
# control comes first: on the UNMUTATED copies the same functions must accept,
# or a checker that always fails would pass this whole section.
#
# EVERY mutation goes through the function the real assertion uses.  LRC-6's
# review mutation-tested this section itself and found three rules -- the
# clone-list's `=<ref>` and self-listing rules and the planner's
# trigger-is-its-own-sibling rule -- that could be deleted outright with the
# suite still green, because their "mutations" re-implemented the rule inline
# instead of calling it.  M7, M8 and M9 are the repaired versions.
# ---------------------------------------------------------------------------
echo
echo "the checker rejects broken wiring (mutation test)"

MUT="$TMP/mut"
mkdir -p "$MUT"
cp "$REUSABLE" "$MUT/reusable.yml"
cp "$DESKTOP_EDGE" "$MUT/caller.yml"
cp "$CLONE_LIST" "$MUT/sibling-repos"

mut_bad=()

# Positive control.
if check_contract "$MUT/reusable.yml" "$MUT/caller.yml" "control" >/dev/null 2>&1 &&
	check_clone_list "$MUT/sibling-repos" >/dev/null 2>&1 &&
	check_checkout_pin "$MUT/reusable.yml" "control" >/dev/null 2>&1; then
	ok "M0 control: the unmutated caller/workflow/clone-list set is ACCEPTED"
else
	fail "M0 control: the unmutated caller/workflow/clone-list set is ACCEPTED" \
		"the checker rejects the real files, so every rejection below proves nothing" \
		"$(check_contract "$MUT/reusable.yml" "$MUT/caller.yml" "control" 2>&1)" \
		"$(check_clone_list "$MUT/sibling-repos" 2>&1)" \
		"$(check_checkout_pin "$MUT/reusable.yml" "control" 2>&1)"
fi

# M1 -- an undeclared `with:` key.
cp "$DESKTOP_EDGE" "$MUT/m1.yml"
sed -i 's/^      recorder-lang: /      bogus-input: x\n      recorder-lang: /' "$MUT/m1.yml"
grep -q 'bogus-input' "$MUT/m1.yml" || mut_bad+=("M1 was not applied (the sed matched nothing)")
check_contract "$MUT/reusable.yml" "$MUT/m1.yml" "M1" >/dev/null 2>&1 &&
	mut_bad+=("M1 SURVIVED: an undeclared 'with:' key was accepted")

# M2 -- a required input left unpassed.
cp "$DESKTOP_EDGE" "$MUT/m2.yml"
sed -i '/^      recorder-lang: /d' "$MUT/m2.yml"
grep -q '^      recorder-lang:' "$MUT/m2.yml" && mut_bad+=("M2 was not applied")
check_contract "$MUT/reusable.yml" "$MUT/m2.yml" "M2" >/dev/null 2>&1 &&
	mut_bad+=("M2 SURVIVED: a required input was allowed to go unpassed")

# M3 -- THE defect actionlint misses: a misspelling that is simultaneously an
# unknown key and a required input left unpassed.
cp "$DESKTOP_EDGE" "$MUT/m3.yml"
sed -i 's/^      recorder-repo: /      recorder-repos: /' "$MUT/m3.yml"
grep -q '^      recorder-repos:' "$MUT/m3.yml" || mut_bad+=("M3 was not applied")
check_contract "$MUT/reusable.yml" "$MUT/m3.yml" "M3" >/dev/null 2>&1 &&
	mut_bad+=("M3 SURVIVED: a misspelled input key was accepted")

# M4 -- `secrets: inherit` dropped.
cp "$DESKTOP_EDGE" "$MUT/m4.yml"
sed -i '/^    secrets: inherit$/d' "$MUT/m4.yml"
grep -q '^    secrets: inherit$' "$MUT/m4.yml" && mut_bad+=("M4 was not applied")
check_contract "$MUT/reusable.yml" "$MUT/m4.yml" "M4" >/dev/null 2>&1 &&
	mut_bad+=("M4 SURVIVED: a caller that inherits no secrets was accepted")

# M5 -- a re-introduced `*-ref` input, declared AND passed, so it is legal by
# every other measure and only the migration invariant catches it.
awk '
	/^    secrets:$/ && !done {
		print "      launcher-ref:"
		print "        description: reintroduced"
		print "        required: false"
		print "        default: dev"
		print "        type: string"
		done=1
	}
	{ print }
' "$MUT/reusable.yml" >"$MUT/m5-reusable.yml"
cp "$DESKTOP_EDGE" "$MUT/m5.yml"
sed -i 's/^      recorder-lang: /      launcher-ref: dev\n      recorder-lang: /' "$MUT/m5.yml"
if ! wf_inputs "$MUT/m5-reusable.yml" | grep -q '^launcher-ref'; then
	mut_bad+=("M5 was not applied (the reintroduced input is not parsed as declared)")
fi
check_contract "$MUT/m5-reusable.yml" "$MUT/m5.yml" "M5" >/dev/null 2>&1 &&
	mut_bad+=("M5 SURVIVED: a re-introduced '*-ref' input was accepted")

# M6 -- the planner stops dropping the triggering repo.  Applied to the
# extracted script, then re-run through the same simulation AND the same
# `plan_case_violations` the real loop uses.
# shellcheck disable=SC2016  # the single quotes are the point: this pattern
# must match the LITERAL '${n}' / '${SELF}' text of the extracted script, not
# whatever those would expand to here.
sed 's/if \[ "${n}" != "${SELF}" \]; then/if [ "${n}" != "" ]; then/' "$PLAN" >"$MUT/m6-plan.sh"
if cmp -s "$PLAN" "$MUT/m6-plan.sh"; then
	mut_bad+=("M6 was not applied (the trigger-dropping condition no longer matches)")
else
	PLAN_SAVED="$PLAN"
	PLAN="$MUT/m6-plan.sh"
	run_plan "metacraft-labs/codetracer-launcher" "codetracer-python-recorder"
	m6_out="$(plan_case_violations "M6" "codetracer-launcher")"
	PLAN="$PLAN_SAVED"
	[ -n "$m6_out" ] ||
		mut_bad+=("M6 SURVIVED: the planner emitted its own trigger and plan_case_violations said nothing")
fi

# M7 -- a clone-list entry that pins a revision, checked THROUGH check_clone_list.
printf 'codetracer-launcher=dev\ncodetracer-trace-format-nim\n' >"$MUT/m7-sibling-repos"
check_clone_list "$MUT/m7-sibling-repos" >/dev/null 2>&1 &&
	mut_bad+=("M7 SURVIVED: a clone-list entry pinning a revision was accepted")

# M8 -- the clone-list lists `codetracer` itself, i.e. the repo whose
# $GITHUB_WORKSPACE clone-siblings would rm -rf.  Also through check_clone_list.
{
	cat "$MUT/sibling-repos"
	printf 'codetracer\n'
} >"$MUT/m8-sibling-repos"
check_clone_list "$MUT/m8-sibling-repos" >/dev/null 2>&1 &&
	mut_bad+=("M8 SURVIVED: a clone-list that lists 'codetracer' itself was accepted")

# M9 -- BOTH protections defeated at once: the planner's filter drops the wrong
# name AND its runtime guard is gone, so the trigger really does come out in the
# sibling list with a plausible count of 3.  This is the only mutation that
# reaches `plan_case_violations`'s trigger rule, which is the last line of
# defence against the `rm -rf` of the primary checkout.
# shellcheck disable=SC2016  # literal '${n}' / '${SELF}' text again
sed -e 's/if \[ "${n}" != "${SELF}" \]; then/if [ "${n}" != "codetracer-trace-format-nim" ]; then/' \
	-e 's/if \[ "${e}" = "${SELF}" \]; then/if [ "${e}" = "___never___" ]; then/' \
	"$PLAN" >"$MUT/m9-plan.sh"
if cmp -s "$PLAN" "$MUT/m9-plan.sh"; then
	mut_bad+=("M9 was not applied (neither the filter nor the runtime guard matched)")
else
	PLAN_SAVED="$PLAN"
	PLAN="$MUT/m9-plan.sh"
	run_plan "metacraft-labs/codetracer-launcher" "codetracer-python-recorder"
	m9_out="$(plan_case_violations "M9" "codetracer-launcher")"
	PLAN="$PLAN_SAVED"
	printf '%s' "$m9_out" | grep -q 'IS IN ITS OWN SIBLING LIST' ||
		mut_bad+=("M9 SURVIVED: the trigger was emitted as its own sibling and the trigger rule did not fire (got: ${m9_out:-<nothing>})")
fi

# M10 -- the repo under test stops being pinned to the commit under test.  Lints
# clean, satisfies every other assertion in this file, and would make all nine
# jobs report on the wrong code.
sed 's|^          ref: '"$EXPR_OPEN"' github.sha }}$|          ref: dev|' "$MUT/reusable.yml" >"$MUT/m10-reusable.yml"
if cmp -s "$MUT/reusable.yml" "$MUT/m10-reusable.yml"; then
	mut_bad+=("M10 was not applied (the primary checkout's ref: line no longer matches)")
else
	check_checkout_pin "$MUT/m10-reusable.yml" "M10" >/dev/null 2>&1 &&
		mut_bad+=("M10 SURVIVED: the repo under test was checked out at a branch instead of github.sha")
fi

# M11 -- a fourth recorder added to a fan-out matrix without being added to the
# clone-list.  The pre-review version of this file transcribed the nine
# combinations, so this mutation passed unnoticed; the derivation is what makes
# it fail.
awk '
	/^          - recorder: codetracer-js-recorder$/ && !done {
		print "          - recorder: codetracer-beam-recorder"
		print "            lang: beam"
		done=1
	}
	{ print }
' "$MUT/caller.yml" >"$MUT/m11-caller.yml"
m11_recs="$(caller_recorders "$MUT/m11-caller.yml")"
if ! printf '%s\n' "$m11_recs" | grep -qx 'codetracer-beam-recorder'; then
	mut_bad+=("M11 was not applied (the added matrix row is not derived as a recorder)")
else
	m11_uncovered=0
	while IFS= read -r rec; do
		[ -z "$rec" ] && continue
		printf '%s\n' "$clone_entries" | grep -qx -- "$rec" || m11_uncovered=1
	done <<<"$m11_recs"
	[ "$m11_uncovered" -eq 1 ] ||
		mut_bad+=("M11 SURVIVED: a recorder added to a fan-out matrix but absent from the clone-list was not detected")
fi

# M12 -- an unrelated call site stops passing `siblings:`, which would silently
# switch it onto the whole five-repo clone-list.  Through check_call_sites.
cp "$REPO_ROOT/.github/workflows/codetracer.yml" "$MUT/m12.yml" 2>/dev/null || true
if [ -f "$MUT/m12.yml" ]; then
	awk '
		/^ *siblings: \|$/ && !done { done=1; skip=1; next }
		skip && /^ *[a-zA-Z-]+:/ { skip=0 }
		skip && /^ *$/ { skip=0 }
		skip { next }
		{ print }
	' "$MUT/m12.yml" >"$MUT/m12-mut.yml"
	if cmp -s "$MUT/m12.yml" "$MUT/m12-mut.yml"; then
		mut_bad+=("M12 was not applied (no 'siblings: |' block found to remove)")
	else
		check_call_sites "$MUT/m12-mut.yml" >/dev/null 2>&1 &&
			mut_bad+=("M12 SURVIVED: a call site passing no siblings: was accepted")
	fi
else
	mut_bad+=("M12 could not run: .github/workflows/codetracer.yml not found")
fi

# M13 -- the planner goes back to emitting `<name>=<ref>`, i.e. the exact
# pre-LRC-6 shape, AND its runtime `=` guard is gone -- the same belt-and-braces
# defeat M9 performs for the trigger rule, and for the same reason: with the
# guard intact the step exits before the checker can see the entries, so only a
# two-part mutation reaches `plan_case_violations`'s explicit-ref rule.  Against
# the real files this shape is also caught by the clone-list coverage assertion
# (`codetracer-launcher=dev` is not a declared name), which is what made the
# rule look covered when it was not.
# shellcheck disable=SC2016  # literal '${n}' / '${e}' text again
sed -e 's/SIB_ENTRIES+=("${n}")/SIB_ENTRIES+=("${n}=dev")/' \
	-e 's/^\( *\)\*=\*)$/\1___never___)/' "$PLAN" >"$MUT/m13-plan.sh"
if cmp -s "$PLAN" "$MUT/m13-plan.sh"; then
	mut_bad+=("M13 was not applied (the sibling-append no longer matches)")
else
	PLAN_SAVED="$PLAN"
	PLAN="$MUT/m13-plan.sh"
	run_plan "metacraft-labs/codetracer" "codetracer-python-recorder"
	m13_out="$(plan_case_violations "M13" "codetracer")"
	PLAN="$PLAN_SAVED"
	printf '%s' "$m13_out" | grep -q 'carries an explicit ref' ||
		mut_bad+=("M13 SURVIVED: the planner emitted '<name>=<ref>' entries and the explicit-ref rule did not fire (got: ${m13_out:-<nothing>})")
fi

if [ "${#mut_bad[@]}" -eq 0 ]; then
	ok "M1-M13: all thirteen mutations of real wiring are rejected"
else
	fail "M1-M13: all thirteen mutations of real wiring are rejected" "${mut_bad[@]}"
fi

# ---------------------------------------------------------------------------
# Assertion count, so a scenario silently dropping out cannot leave this
# reporting success on fewer checks than it claims.
# ---------------------------------------------------------------------------
echo
readonly EXPECTED_ASSERTIONS=15
if [ "$assertions" -ne "$EXPECTED_ASSERTIONS" ]; then
	printf 'FAIL: ran %d assertions, expected %d\n' "$assertions" "$EXPECTED_ASSERTIONS"
	failures=$((failures + 1))
fi

if [ "$failures" -eq 0 ]; then
	printf '\nall %d assertions passed\n' "$assertions"
	exit 0
fi
printf '\n%d of %d assertions FAILED\n' "$failures" "$assertions"
exit 1
