#!/usr/bin/env bash
# The workflow text this suite matches carries literal `${{ ... }}` and `${VAR}`
# expressions, which must NOT expand here.
# shellcheck disable=SC2016
# =============================================================================
# Contract: the PHP recorder's downstream lane -- the reusable workflow
# .github/workflows/php-recorder-downstream.yml and its caller,
# codetracer-php-recorder/.github/workflows/cross-repo-tests.yml -- agree, test
# the recorder at the caller's commit, take codetracer only at a 40-hex
# revision, and pin no sibling of their own.
#
# Same shape as ci/test/launcher-recorder-e2e-workflow-test.sh, for the same
# reason: none of this is reachable by a YAML linter. `actionlint` does not
# check a caller's `with:` against a reusable workflow's `inputs:`, and the
# plan step's refusals only show on a self-hosted runner. So the plan step's
# script is EXTRACTED FROM THE YAML and RUN under the caller's
# `github.repository` with good and bad revisions, and the "refuse a
# codetracer revision that predates this lane" step is run against a fixture
# checkout missing each script a later step runs.
#
# What is asserted:
#   1. the plan step is found, interpolates no `${{ }}` into its body, accepts
#      codetracer-php-recorder with a 40-hex revision, and refuses another
#      caller, a branch, a short sha, an upper-case sha and an empty revision;
#   2. the primary checkout is `${{ github.sha }}`;
#   3. `codetracer-revision` is the only input and is required; the caller
#      passes exactly it, from its resolve job, with `secrets: inherit`
#      (checked when the ../codetracer-php-recorder checkout is present, and
#      said so when it is not);
#   4. every repo-relative script a later step runs from the codetracer
#      checkout is in the refusal step's list, and the refusal step fails,
#      by name, on a checkout missing any of them;
#   5. no sibling is cloned at a revision the workflow writes itself, and the
#      calling repo is excluded from provisioning;
#   6. MUTATIONS of copies of the real file, each of which must be rejected,
#      plus a positive control on the unmutated copy.
#
# Run: bash ci/test/php-recorder-downstream-workflow-test.sh
# Lane: stock bash, awk, grep, sed, git; no Nix, no network.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
REUSABLE="$REPO_ROOT/.github/workflows/php-recorder-downstream.yml"
CALLER="${PHP_RECORDER_DOWNSTREAM_CALLER:-$REPO_ROOT/../codetracer-php-recorder/.github/workflows/cross-repo-tests.yml}"
SHA=0123456789abcdef0123456789abcdef01234567

pass=0 failn=0
ok() { pass=$((pass + 1)); echo "  ok   $1"; }
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
# php-recorder-downstream.yml.
caller_with() {
	strip_cr "$1" | awk '
		/^[[:space:]]*uses:[[:space:]]*.*php-recorder-downstream\.yml/ { seen=1; next }
		seen && /^    with:[[:space:]]*$/ { in_with=1; next }
		in_with && /^      [a-zA-Z0-9_-]+:/ { sub(/^      /, ""); print; next }
		in_with && /^[[:space:]]*(#.*)?$/ { next }
		in_with { in_with=0; seen=0 }
	'
}

# checkout_ref FILE -> the `ref:` of the primary checkout step.
checkout_ref() {
	strip_cr "$1" | awk '
		/^      - name: Checkout the recorder under test/ { s=1; next }
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
	[ -n "$(step_script "Plan the workspace layout" "$f")" ] || { echo "no 'Plan the workspace layout' run: block"; return; }
	if grep -q '\${{' <<<"$(step_script "Plan the workspace layout" "$f")"; then
		echo "the plan step's script interpolates \${{ }} (inputs must come through env:)"
	fi
	r="$(run_plan "$f" codetracer-php-recorder "$SHA")"
	case "$r" in
	"0|"*) grep -qx "ct-rev=$SHA" <<<"$r" || echo "accepted a 40-hex revision but emitted no ct-rev=$SHA"
		grep -qE '^ct-dir=.*/codetracer$' <<<"$r" || echo "ct-dir is not the codetracer sibling"
		for s in codetracer-trace-format codetracer-trace-format-nim codetracer-native-recorder; do
			grep -qx "$s" <<<"$r" || echo "planned siblings lack $s"
		done
		if grep -qE '^[A-Za-z0-9_.-]+=[0-9a-f]{7,}' <<<"$(sed -n '/^siblings<</,/_EOF$/p' <<<"$r")"; then
			echo "a planned sibling carries a revision"
		fi
		if grep -qx 'codetracer-php-recorder' <<<"$(sed -n '/^siblings<</,/_EOF$/p' <<<"$r")"; then
			echo "the calling repo is planned as its own sibling"
		fi ;;
	*) echo "refused codetracer-php-recorder with a 40-hex revision: $(head -3 <<<"$r" | tr '\n' ' ')" ;;
	esac
	for bad in dev agents "${SHA:0:12}" "${SHA^^}" "" "refs/heads/dev"; do
		r="$(run_plan "$f" codetracer-php-recorder "$bad")"
		case "$r" in "0|"*) echo "accepted codetracer-revision '$bad'" ;; esac
	done
	r="$(run_plan "$f" codetracer-ruby-recorder "$SHA")"
	case "$r" in "0|"*) echo "accepted a caller that is not codetracer-php-recorder" ;; esac
}

# The repo-relative scripts later steps run from the codetracer checkout:
# `${CT_DIR}/<path>.sh`, the driver the recipe runs, and the scripts THAT runs
# (`"$REPO_ROOT/<path>.sh"` in this tree's copy of it).
DRIVER="$REPO_ROOT/ci/test/php-recorder-consumers.sh"
run_scripts() {
	strip_cr "$1" | grep -oE '"\$\{CT_DIR\}/(ci|scripts)/[A-Za-z0-9_./-]+\.sh"' | sed 's/^"${CT_DIR}\///; s/"$//'
	echo ci/test/php-recorder-consumers.sh
	grep -oE '"\$REPO_ROOT/(ci|scripts)/[A-Za-z0-9_./-]+\.sh"' "$DRIVER" | sed 's/^"$REPO_ROOT\///; s/"$//'
}
refusal_list() {
	step_script "Refuse a codetracer revision that predates this lane" "$1" |
		grep -oE '(ci|scripts)/[A-Za-z0-9_./-]+\.sh' | sort -u
}

# coverage_violations FILE -> a later step's script that the refusal misses.
coverage_violations() {
	local s
	while read -r s; do
		[ -n "$s" ] || continue
		grep -qxF "$s" <<<"$(refusal_list "$1")" || echo "a step runs $s but the refusal step does not check it"
	done < <(run_scripts "$1" | sort -u)
}

# run_refusal FILE MISSING -> rc of the refusal step on a fixture checkout
# that lacks MISSING (a path, or `recipe` for the just recipe).
run_refusal() {
	local ct="$TMP/refuse/codetracer" s
	rm -rf "$TMP/refuse"
	mkdir -p "$ct/.github/actions/provision-repro-lock-siblings"
	git init -q "$ct"
	git -C "$ct" -c user.email=t@t -c user.name=t commit -q --allow-empty -m fixture
	for s in $(refusal_list "$1"); do mkdir -p "$ct/$(dirname "$s")"; : >"$ct/$s"; done
	printf 'test-php-recorder-consumers:\n  bash ci/test/php-recorder-consumers.sh\n' >"$ct/justfile"
	printf 'inputs:\n  codetracer-dir:\n' >"$ct/.github/actions/provision-repro-lock-siblings/action.yml"
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
	grep -q 'exclude: ${{ steps.plan.outputs.self }}' <<<"$(strip_cr "$f")" || echo "the calling repo is not excluded from provisioning"
	grep -q -- '--self "${SELF}"' <<<"$(strip_cr "$f")" || echo "the resolver is not told which repo is the caller"
	if grep -qE '^\s+[A-Za-z0-9_.-]+=[0-9a-f]{40}' <<<"$(strip_cr "$f")"; then
		echo "the workflow writes a sibling revision of its own"
	fi
	if grep -qE '(clone-repo|ref:[[:space:]]*(dev|main|stable|agents)[[:space:]]*$)' <<<"$(strip_cr "$f")"; then
		echo "the workflow clones a sibling at a branch"
	fi
	grep -q "just test-php-recorder-consumers" <<<"$(strip_cr "$f")" || echo "no step runs just test-php-recorder-consumers"
	grep -qE '^    timeout-minutes: [0-9]+' <<<"$(strip_cr "$f")" || echo "the job has no timeout-minutes"
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
[ -f "$REUSABLE" ] || { fail "$REUSABLE exists"; exit 1; }
v="$(all_violations "$REUSABLE")"
if [ -z "$v" ]; then ok "plan, checkout pin, inputs, refusal coverage and provisioning hold"; else fail "the reusable workflow" "${v//$'\n'/$'\n'       }"; fi
if [ "$(run_scripts "$REUSABLE" | sort -u | grep -c .)" -ge 5 ]; then
	ok "anti-vacuity: the step scanner finds the scripts later steps run ($(run_scripts "$REUSABLE" | sort -u | paste -sd' ' -))"
else
	fail "anti-vacuity: the step scanner finds the scripts later steps run"
fi

echo "== the caller"
if [ -f "$CALLER" ]; then
	w="$(caller_with "$CALLER")"
	if [ "$w" = 'codetracer-revision: ${{ needs.resolve.outputs.rev }}' ]; then
		ok "the caller passes exactly codetracer-revision, from its resolve job"
	else
		fail "the caller passes exactly codetracer-revision from its resolve job" "with: $w"
	fi
	if grep -qE '^[[:space:]]*secrets:[[:space:]]*inherit[[:space:]]*$' <<<"$(strip_cr "$CALLER")"; then
		ok "the caller inherits secrets"
	else
		fail "the caller passes secrets: inherit"
	fi
	if grep -qE 'uses:[[:space:]]*metacraft-labs/codetracer/\.github/workflows/php-recorder-downstream\.yml@' <<<"$(strip_cr "$CALLER")"; then
		ok "the caller calls metacraft-labs/codetracer's php-recorder-downstream.yml"
	else
		fail "the caller calls the reusable workflow"
	fi
else
	echo "  note no caller at $CALLER (codetracer-php-recorder is not checked out beside this repo); its half is checked by that repo's tests/test_downstream_lane.sh"
fi

echo "== ci/prefetch-ci-flake-inputs.sh, EXECUTED with a stub nix"
# The prefetch step's whole body is this script, and nothing else in CI runs
# it before a real job does, so its contract is held here: the nixpkgs repro
# provisions tools from is read out of the locked reprobuild input and fetched
# FIRST; each DIR:SHELL is evaluated in its own checkout, spelled as `nix
# develop` spells it; a checkout without flake.nix is skipped; an evaluation
# that fails stops the script, naming it. The planted revisions are not real
# ones, so a script that restated a revision would fail.
PREFETCH="$REPO_ROOT/ci/prefetch-ci-flake-inputs.sh"
PF="$TMP/prefetch"
mkdir -p "$PF/bin" "$PF/ws/codetracer" "$PF/ws/rec" "$PF/ws/noflake" \
	"$PF/rbsrc/libs/repro_dsl_stdlib/src/repro_dsl_stdlib"
: >"$PF/ws/codetracer/flake.nix"
: >"$PF/ws/rec/flake.nix"
PF_RB=1111111111111111111111111111111111111111
PF_NP=2222222222222222222222222222222222222222
printf '%s\n' '{"nodes": {"root": {"inputs": {"reprobuild": "reprobuild"}},' \
	'  "reprobuild": {"locked": {"type": "github", "owner": "metacraft-labs",' \
	"    \"repo\": \"reprobuild\", \"rev\": \"$PF_RB\", \"narHash\": \"sha256-rb+rb/rb=\"}}}," \
	' "root": "root", "version": 7}' >"$PF/ws/codetracer/flake.lock"
printf '%s\n' 'const' "  CanonicalNixpkgsRev* = \"$PF_NP\"" \
	'  CanonicalNixpkgsNarHash* = "sha256-np+np/np="' \
	>"$PF/rbsrc/libs/repro_dsl_stdlib/src/repro_dsl_stdlib/nixpkgs_pin.nim"
cat >"$PF/bin/nix" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s\n' "$(pwd -P)" "$*" >>"$NIX_LOG"
case "$*" in
	*"--expr builtins.currentSystem"*) printf 'x86_64-linux'; exit 0 ;;
	"flake prefetch --json "*) printf '{"storePath": "%s"}\n' "$RB_SRC"; exit 0 ;;
	"flake prefetch "*) exit 0 ;;
esac
if [ -n "${NIX_FAIL_IN:-}" ] && [ "$(pwd -P)" = "$NIX_FAIL_IN" ]; then
	echo "error: HTTP error 401" >&2
	exit 1
fi
printf '/nix/store/00000000000000000000000000000000-stub.drv'
STUB
chmod +x "$PF/bin/nix"
PFW="$(cd "$PF/ws" && pwd -P)"
run_prefetch() { # [FAIL_IN] -> rc; log in $PF/nix.log, output in $PF/out
	: >"$PF/nix.log"
	PATH="$PF/bin:$PATH" NIX_LOG="$PF/nix.log" RB_SRC="$PF/rbsrc" NIX_FAIL_IN="${1:-}" \
		bash "$PREFETCH" --ct-dir "$PFW/codetracer" "$PFW/codetracer:ci" \
		"$PFW/noflake:default" "$PFW/rec:default" >"$PF/out" 2>&1
}
if run_prefetch; then
	pf_bad=""
	np_ref="github:NixOS/nixpkgs/$PF_NP?narHash=sha256-np%2Bnp%2Fnp%3D"
	grep -qxF "flake prefetch --json github:metacraft-labs/reprobuild/$PF_RB?narHash=sha256-rb%2Brb%2Frb%3D" <<<"$(cut -d'|' -f2- "$PF/nix.log")" ||
		pf_bad="$pf_bad; reprobuild input not fetched at its locked ref"
	np_line="$(grep -nF "|flake prefetch $np_ref" "$PF/nix.log" | head -1 | cut -d: -f1)"
	ev_line="$(grep -nF "|eval --raw --no-write-lock-file" "$PF/nix.log" | head -1 | cut -d: -f1)"
	{ [ -n "$np_line" ] && [ -n "$ev_line" ] && [ "$np_line" -lt "$ev_line" ]; } ||
		pf_bad="$pf_bad; provisioning nixpkgs $np_ref not fetched before the first evaluation"
	for want in codetracer:ci rec:default; do
		grep -qxF "$PFW/${want%%:*}|eval --raw --no-write-lock-file .?submodules=1#devShells.x86_64-linux.${want##*:}.drvPath" "$PF/nix.log" ||
			pf_bad="$pf_bad; $want not evaluated in its checkout"
	done
	grep -q "^$PFW/noflake|" "$PF/nix.log" && pf_bad="$pf_bad; a checkout without flake.nix was evaluated"
	if [ -z "$pf_bad" ]; then ok "it fetches the provisioning nixpkgs first, then evaluates each shell in its checkout, skipping one without flake.nix"; else fail "the prefetch script's fetch order and coverage" "${pf_bad#; }" "nix calls: $(tr '\n' ';' <"$PF/nix.log")"; fi
else
	fail "the prefetch script succeeds against a complete fixture" "$(cat "$PF/out")"
fi
if run_prefetch "$PFW/codetracer"; then
	fail "a failed evaluation stops the prefetch script" "it exited 0"
elif grep -q "::error::could not evaluate devShells.x86_64-linux.ci of $PFW/codetracer" "$PF/out" &&
	! grep -q "^$PFW/rec|" "$PF/nix.log"; then
	ok "a failed evaluation stops the prefetch script, naming the shell and checkout"
else
	fail "a failed evaluation stops the prefetch script, naming the shell and checkout" "$(cat "$PF/out")"
fi
printf 'const\n  SomethingElse* = "x"\n' >"$PF/rbsrc/libs/repro_dsl_stdlib/src/repro_dsl_stdlib/nixpkgs_pin.nim"
if ! run_prefetch && grep -q "::error::could not read CanonicalNixpkgsRev" "$PF/out" && ! grep -q "|eval --raw" "$PF/nix.log"; then
	ok "a pin file that no longer reads is an error, before anything is evaluated"
else
	fail "a pin file that no longer reads is an error, before anything is evaluated" "$(cat "$PF/out")"
fi
if bash "$PREFETCH" --ct-dir >/dev/null 2>&1 || bash "$PREFETCH" --ct-dir "$PFW/codetracer" bogus >/dev/null 2>&1; then
	fail "the prefetch script refuses a malformed command line"
else
	ok "the prefetch script refuses a malformed command line"
fi

echo "== mutations (each must be rejected)"
mutate() { # NAME SED-EXPR
	local m="$TMP/mut.yml"
	sed -E "$2" "$REUSABLE" >"$m"
	if cmp -s "$m" "$REUSABLE"; then fail "mutation '$1' changed nothing (the mutation is stale)"; return; fi
	if [ -n "$(all_violations "$m")" ]; then ok "rejected: $1"; else fail "NOT rejected: $1"; fi
}
mutate "the revision check accepts a branch" 's/if ! \[\[ "\$\{CT_REV\}" =~ \^\[0-9a-f\]\{40\}\$ \]\]; then/if false; then/'
mutate "any caller is accepted" 's/if \[ "\$\{SELF\}" != codetracer-php-recorder \]; then/if false; then/'
mutate "the plan interpolates the input" 's/echo "codetracer revision:         \$\{CT_REV\}"/echo "codetracer revision: ${{ inputs.codetracer-revision }}"/'
mutate "the primary checkout follows a branch" 's/^          ref: \$\{\{ github.sha \}\}/          ref: dev/'
mutate "the refusal forgets the driver" 's|for script in ci/test/php-recorder-consumers.sh |for script in |'
mutate "the refusal forgets a script the driver runs" 's| ci/test/build-recorder-siblings.sh \\$| \\|'
mutate "the refusal forgets the resolver" 's| ci/launcher-recorder-e2e-resolve-siblings.sh \\| \\|'
mutate "the calling repo is not excluded" 's/exclude: \$\{\{ steps.plan.outputs.self \}\}/exclude: ""/'
mutate "a sibling is pinned in the workflow" 's/^            echo "codetracer-native-recorder"$/            echo "codetracer-native-recorder=1111111111111111111111111111111111111111"/'
mutate "a second, optional input appears" 's/^    secrets:$/      codetracer-ref:\n        required: false\n        type: string\n    secrets:/'
mutate "the job loses its timeout" '/^    timeout-minutes: /d'
cp "$REUSABLE" "$TMP/control.yml"
if [ -z "$(all_violations "$TMP/control.yml")" ]; then ok "POSITIVE CONTROL: the unmutated copy passes"; else fail "POSITIVE CONTROL: the unmutated copy passes"; fi

echo
if [ "$failn" -eq 0 ]; then
	echo "php-recorder-downstream-workflow-test: $pass assertions passed"
else
	echo "php-recorder-downstream-workflow-test: $failn of $((pass + failn)) assertions FAILED"
	exit 1
fi
