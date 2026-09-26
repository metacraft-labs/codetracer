#!/usr/bin/env bash
# =============================================================================
# Contract: the launcher <-> recorder E2E workflow and its seven callers agree,
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
#      cannot escape the checks below; the known twelve are a floor.
#   4. For each derived combination: the planner emits the sibling set that
#      combination's caller declares -- the three fixed repos minus the trigger,
#      plus any `extra-siblings:` the caller passes -- the triggering repo is
#      NOT among them, no entry carries `=<ref>`, and `ct-dir` points at the
#      codetracer checkout.  The extras are held to every one of those
#      invariants separately, because they reach `clone-siblings` by the same
#      route and an entry naming the trigger would `rm -rf` the primary
#      checkout just as readily.
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
	grep -qE '^[[:space:]]*secrets:[[:space:]]*inherit[[:space:]]*$' <<<"$(strip_cr "$1")"
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

# caller_extra_siblings FILE -> the value of `extra-siblings:` in this caller's
# `with:`, or empty.  DERIVED for the same reason `caller_recorders` is: the
# planner's sibling count depends on it, so transcribing it here would let a
# caller add an extra sibling that this suite never simulates and never checks
# against the clone-list.
caller_extra_siblings() {
	strip_cr "$1" | awk '
		/^[[:space:]]*extra-siblings:[[:space:]]+[^ ]+[[:space:]]*$/ {
			if ($2 !~ /\$\{\{/) print $2
		}
	' | sort -u | tr '\n' ' ' | sed 's/ *$//'
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
# The seven callers, discovered once.  The in-repo one is mandatory; the six
# remote ones are read from their sibling checkouts, and a sibling that is
# present but carries no caller is a failure rather than a silent pass.
#
# codetracer-beam-recorder joined this list on 2026-09-18, when LRC-4's beam
# sub-deliverable wired the beam edge into all three trigger directions.  Before
# that its caller existed but was never read here, so nothing checked that it
# passed a declared input set or that its planner emitted a sane sibling list.
#
# codetracer-native-recorder joined on 2026-09-19 with LRC-4's native edge.  It
# is the first caller to pass `extra-siblings:` (codetracer-native-backend,
# which builds the `ct-native-replay` the desktop core actually spawns), so it
# is also the case that proves the planner carries an extra sibling through
# every invariant the fixed four go through.
#
# Each entry is `<file>|<label>|<github.repository short name>`.
# ---------------------------------------------------------------------------
declare -a CALLER_FILES=("$DESKTOP_EDGE")
declare -a CALLER_LABELS=("codetracer/launcher-recorder-e2e-desktop-edge.yml")
declare -a CALLER_REPOS=("codetracer")
declare -a CALLER_ABSENT=()
for sib in codetracer-launcher codetracer-python-recorder codetracer-ruby-recorder codetracer-js-recorder codetracer-beam-recorder codetracer-native-recorder; do
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
if grep -qF 'SELF_SHA: '"$EXPR_OPEN"' github.sha }}' <<<"$env_block" &&
	grep -qF 'RECORDER_REPO: '"$EXPR_OPEN"' inputs.recorder-repo }}' <<<"$env_block"; then
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

run_plan() { # $1 = owner/repo, $2 = recorder repo, $3 = extra siblings (optional)
	local repo_full="$1" recorder="$2" extras="${3:-}"
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
			EXTRA_SIBLINGS="${extras// /$'\n'}" \
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
	local label="$1" short="$2" want="${3:-3}" count sib
	if [ "$_plan_rc" -ne 0 ]; then
		echo "$label: planner exited $_plan_rc: $_plan_out"
		return
	fi
	count="$(printf '%s\n' "$_plan_siblings" | grep -c '[^[:space:]]')"
	if [ "$count" -ne "$want" ]; then
		echo "$label: emitted $count sibling(s), expected $want: $(printf '%s' "$_plan_siblings" | tr '\n' ' ')"
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
	# Any `extra-siblings:` the caller declares travels with every case it
	# contributes, so the planner is simulated with exactly what CI will pass
	# it and the resulting sibling list is checked against the clone-list.
	extras="$(caller_extra_siblings "$f")"
	while IFS= read -r rec; do
		[ -z "$rec" ] && continue
		CALLER_CASES+=("metacraft-labs/${CALLER_REPOS[$i]}|$rec|$extras")
	done <<<"$recs"
done

# Anti-vacuity for the derivation itself: the twelve combinations this gate is
# known to span are a FLOOR.  If the matrix parser regresses, the loop below
# would run over a short list and every assertion in it would be weaker without
# saying so.
KNOWN_FLOOR=(
	"metacraft-labs/codetracer|codetracer-python-recorder"
	"metacraft-labs/codetracer|codetracer-ruby-recorder"
	"metacraft-labs/codetracer|codetracer-js-recorder"
	"metacraft-labs/codetracer|codetracer-beam-recorder"
	"metacraft-labs/codetracer-launcher|codetracer-python-recorder"
	"metacraft-labs/codetracer-launcher|codetracer-ruby-recorder"
	"metacraft-labs/codetracer-launcher|codetracer-js-recorder"
	"metacraft-labs/codetracer-launcher|codetracer-beam-recorder"
	"metacraft-labs/codetracer-python-recorder|codetracer-python-recorder"
	"metacraft-labs/codetracer-ruby-recorder|codetracer-ruby-recorder"
	"metacraft-labs/codetracer-js-recorder|codetracer-js-recorder"
	"metacraft-labs/codetracer-beam-recorder|codetracer-beam-recorder"
)
floor_reachable=0
for want in "${KNOWN_FLOOR[@]}"; do
	caller_short="${want%%|*}"
	caller_short="${caller_short##*/}"
	# A caller whose repo is not checked out beside this one cannot contribute.
	# That is the normal case in the `ci-verdict` lane, which checks out
	# `codetracer` alone; the five remote callers are reported as unchecked
	# rather than silently dropped.
	skip=0
	for absent in ${CALLER_ABSENT[@]+"${CALLER_ABSENT[@]}"}; do
		[ "$absent" = "$caller_short" ] && skip=1
	done
	[ "$skip" -eq 1 ] && continue
	floor_reachable=$((floor_reachable + 1))
	found=0
	for have in ${CALLER_CASES[@]+"${CALLER_CASES[@]}"}; do
		# A case is `<caller>|<recorder>|<extras>`; the floor names the first
		# two fields, because whether an edge needs extra siblings is the
		# caller's business and not part of "this combination is reachable".
		[ "${have%|*}" = "$want" ] && found=1
	done
	[ "$found" -eq 1 ] || derive_bad+=("the known combination '$want' was not derived from the caller workflows; the matrix parser regressed or a caller lost a row")
done

if [ "${#derive_bad[@]}" -eq 0 ] && [ "${#CALLER_CASES[@]}" -ge 1 ]; then
	ok "derived ${#CALLER_CASES[@]} (caller x recorder) combination(s) from the callers' own matrices, covering all $floor_reachable of the known twelve that are reachable here"
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
	case_rest="${case_spec#*|}"
	recorder="${case_rest%%|*}"
	extras="${case_rest#*|}"
	[ "$extras" = "$recorder" ] && extras=""
	short="${repo_full##*/}"
	run_plan "$repo_full" "$recorder" "$extras"
	# Three from the four fixed repos minus the trigger, plus whatever the
	# caller declared as extra siblings.  Counted from the caller's own file,
	# so an extra that is added without being cloned -- or cloned without being
	# declared -- shows up as a violation rather than as a new normal.
	want_count=3
	for _e in $extras; do want_count=$((want_count + 1)); done
	label="$short + $recorder${extras:+ (+$extras)}"

	while IFS= read -r v; do
		[ -n "$v" ] && plan_bad+=("$v")
	done < <(plan_case_violations "$label" "$short" "$want_count")

	while IFS= read -r sib; do
		[ -z "$sib" ] && continue
		EMITTED_SIBLINGS="$EMITTED_SIBLINGS $sib"
	done <<<"$_plan_siblings"
done

if [ "${#plan_bad[@]}" -eq 0 ]; then
	ok "all ${#CALLER_CASES[@]} caller/recorder combinations emit the sibling set their caller declares, none of them the trigger"
else
	fail "all caller/recorder combinations emit the sibling set their caller declares, none of them the trigger" \
		"${plan_bad[@]}"
fi

# `extra-siblings` carries the SAME invariants as the fixed four, and each one
# is checked here rather than trusted.  An extra sibling reaches
# `clone-siblings` exactly as any other entry does, so an entry naming the
# triggering repo would `rm -rf` the primary checkout, an entry carrying
# `=<ref>` would pin a branch tip instead of the workspace lock, and a
# duplicate of a fixed name would be cloned twice.
extras_bad=()
run_plan "metacraft-labs/codetracer-native-recorder" "codetracer-native-recorder" "codetracer-native-backend"
if [ "$_plan_rc" -ne 0 ]; then
	extras_bad+=("a valid extra sibling was refused: $_plan_out")
elif ! grep -qx 'codetracer-native-backend' <<<"$_plan_siblings"; then
	extras_bad+=("the extra sibling was not emitted: $(printf '%s' "$_plan_siblings" | tr '\n' ' ')")
fi
run_plan "metacraft-labs/codetracer-native-recorder" "codetracer-native-recorder" "codetracer-native-recorder"
if [ "$_plan_rc" -eq 0 ] || ! grep -q 'IS the triggering repo' <<<"$_plan_out"; then
	extras_bad+=("an extra sibling naming the TRIGGERING repo was not refused (clone-siblings would rm -rf the primary checkout)")
fi
run_plan "metacraft-labs/codetracer-native-recorder" "codetracer-native-recorder" "codetracer-native-backend=dev"
if [ "$_plan_rc" -eq 0 ] || ! grep -q "carries an explicit" <<<"$_plan_out"; then
	extras_bad+=("an extra sibling carrying '=<ref>' was not refused; its revision must come from the workspace lock")
fi
run_plan "metacraft-labs/codetracer-native-recorder" "codetracer-native-recorder" "codetracer-launcher"
if [ "$_plan_rc" -eq 0 ] || ! grep -q "already one of this gate" <<<"$_plan_out"; then
	extras_bad+=("an extra sibling duplicating one of the four fixed repos was not refused")
fi
if [ "${#extras_bad[@]}" -eq 0 ]; then
	ok "an extra sibling is emitted, and is held to every invariant the fixed four are"
else
	fail "an extra sibling is emitted, and is held to every invariant the fixed four are" \
		"${extras_bad[@]}"
fi

run_plan "metacraft-labs/codetracer-beam-recorder" "codetracer-python-recorder"
if [ "$_plan_rc" -ne 0 ] && grep -q 'is neither codetracer' <<<"$_plan_out"; then
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
		if ! grep -qx -- "$name" <<<"$declared"; then
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
		if ! grep -qx -- "$name" <<<"$passed"; then
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
	grep -qx -- "$sib" <<<"$clone_entries" || uncovered+=("$sib")
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
		if ! grep -q '^ *siblings:' <<<"$(strip_cr "$f" | sed -n "${n},$((n + 40))p")"; then
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
# 9b. "Allow direnv in the freshly cloned siblings" MUST NOT BLAME direnv FOR A
#     SHELL THAT NEVER BUILT.
#
# `nix develop <shell> --command <probe>` exits non-zero for two unrelated
# reasons: the shell did not BUILD, or it built and the probe failed. This step
# used to funnel both into one message, "direnv is not on PATH in the codetracer
# ci dev shell".
#
# Run 33021054045 is what that costs. The `ci` shell failed to build (reprobuild
# would not compile against the runquota revision the flake pinned) and the gate
# announced a missing direnv -- while `Error: undeclared identifier:
# 'ExtensionCellWire'` sat in the log directly above. The message was false, not
# just unhelpful: direnv is declared in nix/shells/ci-base.nix, as the step's own
# comment says.
#
# So the step's script is EXECUTED here against a stub `nix`, once per failure
# mode, and each must be named for what it is. Asserting this by grepping the
# YAML for two `echo`s would pass on wiring that never reaches the second one.
# ---------------------------------------------------------------------------
echo
echo "the direnv step distinguishes a shell that will not build from a missing direnv"

# extract_step_script NAME FILE -> that step's `run: |` block, dedented.
# Same scanner as extract_plan_script, parameterised by step name.
extract_step_script() {
	strip_cr "$2" | awk -v want="      - name: $1" '
		$0 == want { in_step=1; next }
		in_step && /^      - name: / { in_step=0 }
		in_step && /^        run: \|[[:space:]]*$/ { in_run=1; next }
		in_run && /^          / { sub(/^          /, ""); print; next }
		in_run && /^[[:space:]]*$/ { print ""; next }
		in_run { in_run=0; in_step=0 }
	'
}

DV="$TMP/direnv-step"
mkdir -p "$DV/bin" "$DV/ws/codetracer" \
	"$DV/ws/codetracer-launcher" \
	"$DV/ws/codetracer-ruby-recorder" \
	"$DV/ws/codetracer-trace-format-nim"
# Two siblings carry a .envrc, one does not -- the step must handle both.
: >"$DV/ws/codetracer-launcher/.envrc"
: >"$DV/ws/codetracer-ruby-recorder/.envrc"

DIRENV_STEP="$DV/step.sh"
extract_step_script "Allow direnv in the freshly cloned siblings" "$REUSABLE" >"$DIRENV_STEP"

# A stub `nix` whose behaviour is chosen by $NIX_STUB_MODE, so the step's own
# control flow -- not a re-implementation of it -- decides what is reported.
cat >"$DV/bin/nix" <<'STUB'
#!/usr/bin/env bash
# Recognise the two shapes the step issues:
#   nix develop '.?submodules=1#ci' --command true
#   nix develop '.?submodules=1#ci' --command bash -c 'command -v direnv'
#   nix develop '.?submodules=1#ci' --command direnv allow <dir>
probe=""
for a in "$@"; do probe="$probe $a"; done
case "$NIX_STUB_MODE" in
	shell-fails)
		echo "error: Cannot build '/nix/store/deadbeef-nix-shell-env.drv'." >&2
		echo "       Reason: 1 dependency failed." >&2
		exit 1
		;;
	no-direnv)
		case "$probe" in
			*"command -v direnv"*) exit 1 ;;
			*) exit 0 ;;
		esac
		;;
	ok)
		case "$probe" in
			*"command -v direnv"*) echo "/nix/store/stub/bin/direnv"; exit 0 ;;
			*" direnv allow "*) echo "STUB-ALLOW:${probe##* }"; exit 0 ;;
			*) exit 0 ;;
		esac
		;;
esac
exit 0
STUB
chmod +x "$DV/bin/nix"

# run_direnv_step MODE -> "<exit>|<combined output>"
run_direnv_step() {
	local out rc
	out="$(
		cd "$DV/ws/codetracer" &&
			PATH="$DV/bin:$PATH" NIX_STUB_MODE="$1" \
				CT_DIR="$DV/ws/codetracer" RECORDER_REPO="codetracer-ruby-recorder" \
				bash "$DIRENV_STEP" 2>&1
	)"
	rc=$?
	printf '%s|%s' "$rc" "$out"
}

dv_out="$(run_direnv_step shell-fails)"
if [ "${dv_out%%|*}" != 0 ] &&
	grep -q 'FAILED TO BUILD' <<<"$dv_out" &&
	! grep -q 'direnv is not on PATH' <<<"$dv_out"; then
	ok "a ci shell that will not build is reported as a shell build failure, not a missing direnv"
else
	fail "a ci shell that will not build is reported as a shell build failure, not a missing direnv" \
		"got: ${dv_out}"
fi

dv_out="$(run_direnv_step no-direnv)"
if [ "${dv_out%%|*}" != 0 ] &&
	grep -q 'direnv is not on PATH inside it' <<<"$dv_out" &&
	! grep -q 'FAILED TO BUILD' <<<"$dv_out"; then
	ok "a shell that builds but lacks direnv is reported as a missing direnv"
else
	fail "a shell that builds but lacks direnv is reported as a missing direnv" \
		"got: ${dv_out}"
fi

dv_out="$(run_direnv_step ok)"
if [ "${dv_out%%|*}" = 0 ] &&
	grep -q 'direnv allow: .*/codetracer-launcher' <<<"$dv_out" &&
	grep -q 'direnv allow: .*/codetracer-ruby-recorder' <<<"$dv_out" &&
	grep -q 'no .envrc in .*/codetracer-trace-format-nim' <<<"$dv_out"; then
	ok "a healthy shell allows every sibling that has a .envrc and says so for the one that does not"
else
	fail "a healthy shell allows every sibling that has a .envrc and says so for the one that does not" \
		"got: ${dv_out}"
fi

# ---------------------------------------------------------------------------
# The workspace-shape step names a codetracer too old for this workflow.
#
# This workflow is resolved at `@dev` by every remote caller, but the codetracer
# checkout it drives comes from the workspace lock. So a step that starts
# running a new repo script breaks every edge whose lock pins an older
# codetracer -- in that step, after the ten-minute core build, as exit 127.
# Python run 35503672483 and js run 35503680304 both died that way on
# `ci/test/launcher-recorder-decode-test.sh` (added in e705fbad5, 2026-09-19;
# their locks pinned codetracer from 2026-09-09 / -10).
#
# Two properties, both checked against the committed YAML:
#   a. every repo-relative `bash <path>.sh` a step runs is in the shape step's
#      `for script in ...` list -- DERIVED from the YAML, so a new step cannot
#      escape it; and a copy with ANY one entry removed must be REJECTED;
#   b. the shape step, EXECUTED against a workspace whose codetracer lacks any
#      one listed script, fails naming that script and the lock, and passes
#      once every one is there.
# ---------------------------------------------------------------------------
echo
echo "the workspace-shape step checks every repo script a later step runs"

# shape_listed_scripts FILE -> the shape step's `for script in ...` entries.
shape_listed_scripts() {
	extract_step_script "Check the workspace has the shape the driver expects" "$1" |
		sed -n 's/^[[:space:]]*for script in \(.*\); do[[:space:]]*$/\1/p' |
		tr ' ' '\n' | grep -v '^$' | sort -u
}

# check_shape_covers_scripts FILE -> prints one line per uncovered script;
# exit 0 iff every repo-relative `bash <path>.sh` run by a step (comments
# excluded) is listed by the shape step, and at least one such script was
# found. The driver is exempt: the shape step checks it by name, above the list.
check_shape_covers_scripts() {
	local file="$1" run_scripts listed s rc=0
	listed="$(shape_listed_scripts "$file")"
	run_scripts="$(strip_cr "$file" | grep -v '^[[:space:]]*#' |
		grep -oE '(^|[[:space:]])bash [A-Za-z0-9_][A-Za-z0-9_./-]*\.sh' |
		sed 's/^[[:space:]]*bash //' | sort -u)"
	if [ -z "$run_scripts" ]; then
		echo "no repo-relative 'bash <path>.sh' invocation found in $file -- the derivation is vacuous"
		return 1
	fi
	for s in $run_scripts; do
		[ "$s" = ci/test/launcher-recorder-e2e.sh ] && continue
		if ! grep -qxF "$s" <<<"$listed"; then
			echo "$s is run by a step but not checked by the workspace-shape step"
			rc=1
		fi
	done
	return "$rc"
}

SHAPE_LISTED="$(shape_listed_scripts "$REUSABLE")"
if cov_out="$(check_shape_covers_scripts "$REUSABLE")"; then
	ok "every repo script a step runs is checked by the workspace-shape step"
else
	fail "every repo script a step runs is checked by the workspace-shape step" "$cov_out"
fi

# Mutation: drop each entry in turn from the shape step's list; the check must
# notice every time. Run through the same function, on copies of the real file.
SHAPE_MUT="$TMP/shape-mutant.yml"
mut_out=""
for s in $SHAPE_LISTED; do
	awk -v drop="$s" '
		/^          for script in .*; do[[:space:]]*$/ {
			line = $0; sub(/; do[[:space:]]*$/, "", line)
			n = split(line, w, " "); out = ""
			for (i = 1; i <= n; i++) if (w[i] != drop) out = out (out == "" ? "          " : " ") w[i]
			print out "; do"; next
		}
		{ print }' "$REUSABLE" >"$SHAPE_MUT"
	if cmp -s "$REUSABLE" "$SHAPE_MUT"; then
		mut_out="${mut_out}the mutation dropping $s was not applied; "
	elif check_shape_covers_scripts "$SHAPE_MUT" >/dev/null; then
		mut_out="${mut_out}SURVIVED: $s was removed from the shape step and the check still passed; "
	fi
done
if [ -z "$SHAPE_LISTED" ]; then
	fail "a shape step that stops checking any script a later step runs is rejected" \
		"the shape step lists no scripts at all"
elif [ -n "$mut_out" ]; then
	fail "a shape step that stops checking any script a later step runs is rejected" "$mut_out"
else
	ok "a shape step that stops checking any script a later step runs is rejected"
fi

# Execute the step. A workspace laid out correctly in every way except the
# script in question, so the only thing that can fail is the new check.
SH="$TMP/shape-step"
mkdir -p "$SH/ws/codetracer/ci/test" "$SH/ws/codetracer-launcher" \
	"$SH/ws/codetracer-ruby-recorder/cross-repo" "$SH/ws/codetracer-trace-format-nim"
: >"$SH/ws/codetracer/ci/test/launcher-recorder-e2e.sh"
: >"$SH/ws/codetracer-ruby-recorder/cross-repo/launcher-compat.yml"
SHAPE_STEP="$SH/step.sh"
extract_step_script "Check the workspace has the shape the driver expects" "$REUSABLE" >"$SHAPE_STEP"

run_shape_step() {
	local out rc
	out="$(CT_DIR="$SH/ws/codetracer" RECORDER_REPO="codetracer-ruby-recorder" \
		GITHUB_REPOSITORY="metacraft-labs/codetracer-ruby-recorder" \
		bash "$SHAPE_STEP" 2>&1)"
	rc=$?
	printf '%s|%s' "$rc" "$out"
}

# place_all_but SCRIPT -> every listed script present except SCRIPT.
place_all_but() {
	local s
	for s in $SHAPE_LISTED; do
		rm -f "$SH/ws/codetracer/$s"
		if [ "$s" != "$1" ]; then
			mkdir -p "$(dirname "$SH/ws/codetracer/$s")"
			: >"$SH/ws/codetracer/$s"
		fi
	done
}

miss_out=""
for s in $SHAPE_LISTED; do
	place_all_but "$s"
	sh_out="$(run_shape_step)"
	if ! { [ "${sh_out%%|*}" != 0 ] &&
		grep -qF "predates ${s}" <<<"$sh_out" &&
		grep -q "repro workspace lock --trigger-repo=codetracer-ruby-recorder" <<<"$sh_out"; }; then
		miss_out="${miss_out}without ${s}: ${sh_out}"$'\n'
	fi
done
if [ -z "$SHAPE_LISTED" ] || [ -n "$miss_out" ]; then
	fail "a lock-pinned codetracer lacking any listed script fails the shape step, naming the script and the lock" \
		"got: ${miss_out:-the shape step lists no scripts}"
else
	ok "a lock-pinned codetracer lacking any listed script fails the shape step, naming the script and the lock"
fi

place_all_but ""
sh_out="$(run_shape_step)"
ok_out=""
for s in $SHAPE_LISTED; do
	grep -qF "OK   $SH/ws/codetracer/${s}" <<<"$sh_out" || ok_out="${ok_out} ${s}"
done
if [ "${sh_out%%|*}" = 0 ] && [ -n "$SHAPE_LISTED" ] && [ -z "$ok_out" ]; then
	ok "the shape step passes once the codetracer checkout carries every listed script"
else
	fail "the shape step passes once the codetracer checkout carries every listed script" \
		"not reported OK:${ok_out}; got: ${sh_out}"
fi

# ---------------------------------------------------------------------------
# 9c. THE CORE BUILD'S WORKSPACE: complete, pinned, and on flake.lock's revs.
#
# `Build the codetracer-desktop core` runs `just build-once`, whose tup build
# reads every build sibling by RELATIVE PATH. The planner's repos are the
# corners of the edge under test, not that workspace; the rest comes from the
# literal block of `Setup dev env + clone the remaining siblings`. That block
# went incomplete once already: the 2026-09-18 editor work made ui.js import
# `isonim_tui/text/width`, nothing provisioned ../isonim-tui, and every arm of
# every edge died in the core build (desktop run 35974652142; recorder runs
# 35985937174 native, 35985941156 js). Its SHA pins had also drifted from
# flake.lock -- isonim by 82 commits -- although the block says in so many
# words that they are one pin spelled in two places.
#
#   a. PINNED: the block's names are exactly CORE_SIBLINGS_EXPECTED, so any
#      change to the set is a deliberate edit of this file too.
#   b. COMPLETE: every row of scripts/require-siblings.sh's REQUIRED table (the
#      preflight `just build-once` runs first) is provisioned on every derived
#      edge -- by the trigger's own checkout, the planner, or the block -- and a
#      copy of the workflow with any one block-only required entry removed is
#      REJECTED. The required set is read from the preflight, not restated.
#   c. NO REF DRIFT: every `<name>=<value>` in the block is a 40-hex commit SHA
#      (never a branch: not reproducible), and every one whose name is a
#      flake.lock root input equals that input's `locked.rev`. The flake inputs
#      compared must include CORE_FLAKE_PINNED_FLOOR, so a parser that finds
#      nothing cannot pass. Mutants: a drifted SHA, and a `=dev` entry.
#
# ci/test/build-once-workspace-test.sh covers (b) for every build-once job in
# the repo; it is repeated here per derived EDGE, next to (a) and (c), because
# this is the file that owns this workflow's sibling wiring.
# ---------------------------------------------------------------------------
echo
echo "the core build's sibling block is complete, pinned, and on flake.lock's revs"

readonly CORE_STEP="Setup dev env + clone the remaining siblings"
readonly PREFLIGHT="$REPO_ROOT/scripts/require-siblings.sh"
readonly FLAKE_LOCK="$REPO_ROOT/flake.lock"

# (a) The block, by name. Revisions are deliberately NOT restated here: the
# flake-input ones are compared with flake.lock in (c), so bumping flake.lock
# and the block together needs no edit of this file.
readonly CORE_SIBLINGS_EXPECTED="codetracer-native-recorder
codetracer-trace-format
codetracer-trace-format-nim
io-mon
isonim
isonim-tui
nim-acp
nim-agent-harbor
nim-agents
nim-everywhere
nim-shm-gset
nim-shm-queue
nim-stackable-hooks
runquota"

# The flake inputs (c) must have compared, at least.
readonly CORE_FLAKE_PINNED_FLOOR="isonim isonim-tui runquota"

# core_sibling_entries FILE -> the literal entries (`name` or `name=ref`) of the
# core step's `siblings:` block, one per line; the planner's `${{ }}` line and
# `#` comments are dropped, the way clone-siblings drops them.
core_sibling_entries() {
	strip_cr "$1" | awk -v want="      - name: $CORE_STEP" '
		$0 == want { in_step = 1; next }
		in_step && /^      - name: / { exit }
		in_step && /^          siblings: \|[[:space:]]*$/ { in_blk = 1; next }
		in_blk && /^            / {
			line = $0
			sub(/#.*/, "", line)
			n = split(line, t, /[ \t]+/)
			for (i = 1; i <= n; i++) {
				if (t[i] == "" || index(t[i], "{{") || index(t[i], "}}") || t[i] ~ /^steps\./) continue
				print t[i]
			}
			next
		}
		in_blk && /^[[:space:]]*$/ { next }
		in_blk { exit }
	'
}

# drop_core_entry FILE NAME -> FILE with NAME's line removed from the block.
drop_core_entry() {
	strip_cr "$1" | awk -v want="      - name: $CORE_STEP" -v drop="$2" '
		$0 == want { in_step = 1 }
		in_step && /^          siblings: \|[[:space:]]*$/ { in_blk = 1; print; next }
		in_blk && /^            / {
			tok = $0; sub(/^[ \t]+/, "", tok); sub(/[ \t].*$/, "", tok)
			if (tok == drop || index(tok, drop "=") == 1) next
			print; next
		}
		in_blk && !/^[[:space:]]*$/ { in_blk = 0; in_step = 0 }
		{ print }
	'
}

# set_core_ref FILE NAME REF -> FILE with the block's NAME entry set to NAME=REF.
set_core_ref() {
	strip_cr "$1" | awk -v want="      - name: $CORE_STEP" -v name="$2" -v ref="$3" '
		$0 == want { in_step = 1 }
		in_step && /^          siblings: \|[[:space:]]*$/ { in_blk = 1; print; next }
		in_blk && /^            / {
			tok = $0; sub(/^[ \t]+/, "", tok); sub(/[ \t].*$/, "", tok)
			if (tok == name || index(tok, name "=") == 1) { print "            " name "=" ref; next }
			print; next
		}
		in_blk && !/^[[:space:]]*$/ { in_blk = 0; in_step = 0 }
		{ print }
	'
}

# The required table, parsed out of the preflight exactly as
# ci/test/build-once-workspace-test.sh parses it: `name|probe|overrides|reason`
# rows inside `required_siblings=( ... )`, the name up to the first `|`.
REQUIRED_NAMES="$(awk '
	/^required_siblings=\(/ { inblock = 1; next }
	inblock && /^\)/        { inblock = 0 }
	inblock {
		line = $0
		sub(/^[ \t]*/, "", line)
		if (line ~ /^#/ || line == "") next
		sub(/^["'\'']/, "", line)
		split(line, parts, "|")
		if (parts[1] != "") print parts[1]
	}
' "$PREFLIGHT" 2>/dev/null)"
readonly REQUIRED_NAMES

# What every derived edge has WITHOUT the block: its own checkout (the trigger),
# the planner's three, and any extra-siblings its caller passes. Computed once
# by running the real planner, so the mutation loop below is cheap.
declare -a CORE_EDGE_LABELS=()
declare -a CORE_EDGE_HAVE=()
for case_spec in ${CALLER_CASES[@]+"${CALLER_CASES[@]}"}; do
	repo_full="${case_spec%%|*}"
	case_rest="${case_spec#*|}"
	recorder="${case_rest%%|*}"
	extras="${case_rest#*|}"
	[ "$extras" = "$recorder" ] && extras=""
	run_plan "$repo_full" "$recorder" "$extras"
	CORE_EDGE_LABELS+=("${repo_full##*/} + $recorder")
	CORE_EDGE_HAVE+=("${repo_full##*/}"$'\n'"$_plan_siblings")
done

# core_workspace_violations FILE -> one line per (edge, required sibling) the
# edge would not have; exit 0 iff there are none AND something was checked.
core_workspace_violations() {
	local file="$1" names i req rc=0
	names="$(core_sibling_entries "$file" | sed 's/=.*//')"
	if [ -z "$REQUIRED_NAMES" ] || [ "${#CORE_EDGE_HAVE[@]}" -eq 0 ]; then
		echo "nothing to check: $(printf '%s' "$REQUIRED_NAMES" | grep -c .) required sibling(s), ${#CORE_EDGE_HAVE[@]} edge(s)"
		return 1
	fi
	# Membership by pattern match, not grep: this runs once per edge x required
	# name x mutation, and a fork per test costs minutes on a Windows runner.
	for i in "${!CORE_EDGE_HAVE[@]}"; do
		for req in $REQUIRED_NAMES; do
			if [[ $'\n'"${CORE_EDGE_HAVE[$i]}"$'\n'"$names"$'\n' != *$'\n'"$req"$'\n'* ]]; then
				echo "${CORE_EDGE_LABELS[$i]}: '$req' is REQUIRED by scripts/require-siblings.sh but neither the planner nor the '$CORE_STEP' block provisions it -- just build-once refuses to start"
				rc=1
			fi
		done
	done
	return "$rc"
}

# flake_lock_revs NAME... -> `name rev` per NAME that is a flake.lock ROOT
# input, looked up root.inputs[name] -> node (node keys can carry a `_N`
# suffix, so reading nodes[name] can land on another repo's node). A parse or
# tooling failure is reported as that, never as a statement about a pin.
flake_lock_revs() {
	python3 - "$FLAKE_LOCK" "$@" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
    nodes = data["nodes"]
    root = nodes[data["root"]]["inputs"]
except Exception as exc:  # noqa: BLE001 - reported verbatim
    print("PARSE-ERROR %s" % exc)
    raise SystemExit(0)
for name in sys.argv[2:]:
    key = root.get(name)
    if key is None:
        continue
    if isinstance(key, list):
        key = key[0]
    print("%s %s" % (name, nodes.get(key, {}).get("locked", {}).get("rev", "")))
PY
}

# core_ref_violations FILE -> one line per `=<ref>` entry that is not a 40-hex
# SHA, or that is a flake input whose SHA differs from flake.lock; exit 0 iff
# none AND every name in CORE_FLAKE_PINNED_FLOOR was compared.
core_ref_violations() {
	local file="$1" entries e name ref revs compared="" want rc=0 lock_rev
	local -a pinned_names=()
	entries="$(core_sibling_entries "$file")"
	mapfile -t pinned_names < <(printf '%s\n' "$entries" | grep '=' | sed 's/=.*//')
	revs="$(flake_lock_revs ${pinned_names[@]+"${pinned_names[@]}"})" || {
		echo "could not run python3 over $FLAKE_LOCK -- a tooling failure, not a statement about any pin"
		return 1
	}
	if grep -q '^PARSE-ERROR' <<<"$revs"; then
		echo "flake.lock did not parse ($revs) -- a tooling failure, not a statement about any pin"
		return 1
	fi
	while IFS= read -r e; do
		case "$e" in *=*) ;; *) continue ;; esac
		name="${e%%=*}"
		ref="${e#*=}"
		if ! [[ $ref =~ ^[0-9a-f]{40}$ ]]; then
			echo "'$e' does not pin a 40-hex commit SHA; a branch or tag is a different tree on every re-run"
			rc=1
			continue
		fi
		lock_rev="$(awk -v n="$name" '$1 == n { print $2 }' <<<"$revs")"
		[ -n "$lock_rev" ] || continue # not a flake input (the io-mon family)
		compared="$compared $name"
		if [ "$ref" != "$lock_rev" ]; then
			echo "'$name' is pinned to $ref here but flake.lock pins $lock_rev; the tup driver reads this checkout and the nix driver reads flake.lock, so they would compile different trees"
			rc=1
		fi
	done <<<"$entries"
	for want in $CORE_FLAKE_PINNED_FLOOR; do
		case " $compared " in
		*" $want "*) ;;
		*)
			echo "'$want' was not compared with flake.lock (compared:${compared:- nothing}); it is missing from the block, lost its SHA, or is no longer a flake input"
			rc=1
			;;
		esac
	done
	return "$rc"
}

# (a)
core_names="$(core_sibling_entries "$REUSABLE" | sed 's/=.*//' | sort)"
if [ "$core_names" = "$CORE_SIBLINGS_EXPECTED" ]; then
	ok "the core step's sibling block is exactly the pinned set ($(printf '%s' "$core_names" | grep -c .) names)"
else
	fail "the core step's sibling block is exactly the pinned set" \
		"expected: $(printf '%s' "$CORE_SIBLINGS_EXPECTED" | tr '\n' ' ')" \
		"got:      $(printf '%s' "$core_names" | tr '\n' ' ')" \
		"If the change is intended, update CORE_SIBLINGS_EXPECTED in this file with it."
fi

# (b)
if cw_out="$(core_workspace_violations "$REUSABLE")"; then
	ok "every required sibling ($(printf '%s' "$REQUIRED_NAMES" | grep -c .) in scripts/require-siblings.sh) is provisioned on all ${#CORE_EDGE_HAVE[@]} derived edge(s)"
else
	mapfile -t cw_lines <<<"$cw_out"
	fail "every required sibling in scripts/require-siblings.sh is provisioned on every derived edge" "${cw_lines[@]}"
fi

CORE_MUT="$TMP/core-mutant.yml"
cw_mut=""
cw_tried=0
core_block_names=$'\n'"$(core_sibling_entries "$REUSABLE" | sed 's/=.*//')"$'\n'
for req in $REQUIRED_NAMES; do
	# Only entries the BLOCK alone provides: one the planner also emits on every
	# edge (codetracer-trace-format-nim) can be dropped from the block safely.
	[[ $core_block_names == *$'\n'"$req"$'\n'* ]] || continue
	drop_core_entry "$REUSABLE" "$req" >"$CORE_MUT"
	if cmp -s <(strip_cr "$REUSABLE") "$CORE_MUT"; then
		cw_mut="${cw_mut}the mutation dropping $req changed nothing; "
		continue
	fi
	all_have=1
	for i in "${!CORE_EDGE_HAVE[@]}"; do
		[[ $'\n'"${CORE_EDGE_HAVE[$i]}"$'\n' == *$'\n'"$req"$'\n'* ]] || all_have=0
	done
	[ "$all_have" -eq 1 ] && continue
	cw_tried=$((cw_tried + 1))
	if m_out="$(core_workspace_violations "$CORE_MUT")"; then
		cw_mut="${cw_mut}SURVIVED: '$req' was dropped from the block and the check still passed; "
	elif ! grep -qF "'$req' is REQUIRED" <<<"$m_out"; then
		cw_mut="${cw_mut}dropping '$req' failed the check without naming it: $m_out; "
	fi
done
if [ "$cw_tried" -ge 2 ] && [ -z "$cw_mut" ]; then
	ok "a block missing any one of the $cw_tried required siblings only it provides is rejected, by name"
else
	fail "a block missing any one of the required siblings only it provides is rejected, by name" \
		"${cw_mut:-only $cw_tried mutation(s) could be built -- the block or the required table did not parse}"
fi

# (c)
if cr_out="$(core_ref_violations "$REUSABLE")"; then
	ok "every pinned entry is a 40-hex SHA, and $CORE_FLAKE_PINNED_FLOOR equal flake.lock's revs"
else
	mapfile -t cr_lines <<<"$cr_out"
	fail "every pinned entry is a 40-hex SHA, and the flake inputs equal flake.lock's revs" "${cr_lines[@]}"
fi

cr_mut=""
set_core_ref "$REUSABLE" isonim-tui 0000000000000000000000000000000000000001 >"$CORE_MUT"
if ! grep -q 'isonim-tui=0000000000000000000000000000000000000001' "$CORE_MUT"; then
	cr_mut="${cr_mut}the drifted-SHA mutation was not applied; "
elif m_out="$(core_ref_violations "$CORE_MUT")" || ! grep -qF "'isonim-tui' is pinned to" <<<"$m_out"; then
	cr_mut="${cr_mut}SURVIVED: isonim-tui pinned away from flake.lock (got: ${m_out:-<nothing>}); "
fi
set_core_ref "$REUSABLE" io-mon dev >"$CORE_MUT"
if ! grep -q '^            io-mon=dev$' "$CORE_MUT"; then
	cr_mut="${cr_mut}the branch-ref mutation was not applied; "
elif m_out="$(core_ref_violations "$CORE_MUT")" || ! grep -qF "'io-mon=dev' does not pin a 40-hex" <<<"$m_out"; then
	cr_mut="${cr_mut}SURVIVED: io-mon=dev (got: ${m_out:-<nothing>}); "
fi
if [ -z "$cr_mut" ]; then
	ok "a block pinning a flake input away from flake.lock, or any entry to a branch, is rejected"
else
	fail "a block pinning a flake input away from flake.lock, or any entry to a branch, is rejected" "$cr_mut"
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
if ! grep -q '^launcher-ref' <<<"$(wf_inputs "$MUT/m5-reusable.yml")"; then
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
	grep -q 'IS IN ITS OWN SIBLING LIST' <<<"$m9_out" ||
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

# M11 -- a further recorder added to a fan-out matrix without being added to
# the clone-list.  The pre-review version of this file transcribed the nine
# combinations, so this mutation passed unnoticed; the derivation is what makes
# it fail.
#
# THE MUTANT MUST BE A RECORDER THE CLONE-LIST DOES NOT DECLARE, and that is a
# PRECONDITION, not a constant.  This mutation used to add
# `codetracer-beam-recorder`, and on 2026-09-10 the beam edge was wired and that
# name was declared in `.github/sibling-repos` -- whereupon M11 asserted nothing
# at all and reported SURVIVED against an unchanged, correct checker.  So the
# name is now CHOSEN at run time from the recorder repos this org has that the
# clone-list does not carry, and the choice failing is itself a failure.  A day
# when every candidate is declared is a day this mutation cannot be built, and
# it must say so rather than pass.
m11_victim=""
for cand in codetracer-native-recorder codetracer-php-recorder codetracer-wasm-recorder; do
	grep -qx -- "$cand" <<<"$clone_entries" || {
		m11_victim="$cand"
		break
	}
done
if [ -z "$m11_victim" ]; then
	mut_bad+=("M11 could not be built: every candidate recorder is already declared in the clone-list, so this mutation asserts nothing. Pick a name the clone-list does not carry.")
else
	awk -v victim="$m11_victim" '
		/^          - recorder: codetracer-js-recorder$/ && !done {
			print "          - recorder: " victim
			print "            lang: m11"
			done=1
		}
		{ print }
	' "$MUT/caller.yml" >"$MUT/m11-caller.yml"
	m11_recs="$(caller_recorders "$MUT/m11-caller.yml")"
	if ! grep -qx -- "$m11_victim" <<<"$m11_recs"; then
		mut_bad+=("M11 was not applied (the added matrix row is not derived as a recorder)")
	else
		m11_uncovered=0
		while IFS= read -r rec; do
			[ -z "$rec" ] && continue
			grep -qx -- "$rec" <<<"$clone_entries" || m11_uncovered=1
		done <<<"$m11_recs"
		[ "$m11_uncovered" -eq 1 ] ||
			mut_bad+=("M11 SURVIVED: a recorder added to a fan-out matrix but absent from the clone-list was not detected")
	fi
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
	grep -q 'carries an explicit ref' <<<"$m13_out" ||
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
readonly EXPECTED_ASSERTIONS=28
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
