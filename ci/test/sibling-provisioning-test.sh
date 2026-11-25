#!/usr/bin/env bash
# =============================================================================
# Contract: no CI job's sibling checkout depends on a published workspace lock,
# and the macOS non-nix build leg provisions the sibling its build script reads.
#
# # Why this file exists
#
# `metacraft-github-actions/setup-dev-env` clones cross-repo siblings through
# its `clone-siblings` sub-action. Each entry of its `siblings:` input is
# either
#
#     name          -> resolve the revision from a WORKSPACE LOCK
#     name=ref      -> clone `ref` directly
#
# The lock is a per-commit snapshot published to
# `metacraft-labs/metacraft-manifests@latest` by the workspace tooling's
# pre-push hook. Publication for this repo stopped on 2026-08-02 -- the last
# entry is `locks/dev/codetracer/784c9bda....xml`. `clone-siblings` probes the
# pushed commit and its parent only (it passes `--no-walk` to the resolver), so
# `dev` survived exactly one more commit and then broke:
#
#   8d587343 (parent 784c9bda)   last green `Setup dev env`   2026-08-02
#   3583cd6b (parent 8d587343)   first red one, run 30951549711, 2026-08-04
#
#     ##[error]No workspace lock for codetracer (candidates: <sha> <parent>).
#     Neither a repo-workspaces locks/<project>/codetracer/<sha>.xml nor a
#     reprobuild locks/<project>/codetracer/<sha>.toml exists in
#     metacraft-labs/metacraft-manifests@latest.
#
# Six jobs -- lint-rust, test-non-gui, test-ui-tests (both legs),
# test-ui-tests-rr, visual-replay-regression-gate, ct-test-providers -- died in
# their first real step for eight days, and the nine jobs that `needs:` them
# were reported `skipped`, which is the "the tests never ran" state that
# `ci/verdict/required-jobs.sh` exists to name out loud.
#
# A bare entry is not a syntax error and not a lint failure; it is a live
# dependency on a repository this one does not control. This contract makes
# adding one a test failure instead of an outage.
#
# The second half of the file covers the same class of defect reached from the
# other direction. `test-non-gui`'s macOS leg runs `./non-nix-build/build.sh`,
# which (via `env.sh` -> `build_trace_writer_ffi.sh`) needs a
# codetracer-trace-format checkout at `../codetracer-trace-format`. That was an
# in-repo submodule until e901eb6c8 (2026-05-12) made it a sibling repo, and
# this leg's `Setup dev env` -- the step that clones siblings -- carries
# `if: matrix.platform == 'nixos'`, so the macOS leg never got one:
#
#     ERROR: codetracer-trace-format checkout not found at
#     .../non-nix-build/../../codetracer-trace-format.
#
# Independent of the lock outage above, and invisible for months because the
# leg is `continue-on-error: ${{ matrix.platform == 'macos' }}`. Note this leg
# was ALREADY failing at `Build (non-nix)` before e901eb6c8 -- the last green
# run of it anywhere is 24457842335 (main, 2026-04-15) and it has never been
# green on `dev` at all -- so clearing the missing sibling may expose an older
# failure underneath rather than turning the leg green. This contract is about
# the sibling, not about the leg's overall health.
#
# # What is asserted
#
#   1. Every `siblings:` entry in every workflow carries an explicit `=ref`.
#   2. An entry whose ref is a `${{ }}` expression supplies a non-empty
#      fallback. `name=${{ github.event.inputs.foo }}` on a push evaluates to a
#      trailing `=`, which `clone-siblings` documents as "fall back to the
#      lock" -- the bare-entry failure wearing a costume.
#   3. The `siblings:` block set is non-empty (a rename of the input must not
#      turn this suite into a vacuous pass).
#
#      Scope is `.github/workflows/*.yml` AND `.github/actions/*/action.yml`.
#      The composite actions matter as much as the workflows and are easier to
#      forget: `.github/actions/setup-db-backend-siblings/action.yml` carries
#      its own `siblings:` block, is used by six jobs, and kept every one of
#      them failing after the workflows themselves had been fixed -- this
#      suite's first version only walked the workflow directory and waved it
#      straight through.
#   3b. Any `siblings:` block that provisions `codetracer-trace-format` also
#      provisions `codetracer-trace-format-nim`. They are the two halves of one
#      FFI boundary and are only ever correct together; the dependency is
#      invisible from either repo's own manifest, so it keeps being missed.
#      See the assertion's own comment for the two failure modes already paid
#      for (absent half -> build.rs error; stale half -> link error).
#   3c. A private sibling (UNLOCKED_SIBLINGS: repro.lock is public and cannot
#      pin it) has one home for its revision -- flake.lock for a flake input,
#      ci/toolchain.pin's PRIVATE_SIBLING_<NAME> otherwise -- and every copy a
#      workflow writes (a `siblings:` or `extra-siblings:` literal, a
#      `|| '<sha>'` fallback, a branch ref, an `RR_BACKEND_REF:` literal)
#      equals it. Step 1e; falsified by its own one-character controls.
#   4. Every workflow step that runs `./non-nix-build/build.sh` is preceded, in
#      its own job, by a step that provisions `codetracer-trace-format`.
#   5. Every workflow step that runs `ci/setup-rr-backend.sh` sets
#      `RR_BACKEND_REF`. That script's other route to a revision is the same
#      workspace lock, reached through `scripts/resolve-sibling-rev.sh`, which
#      locates the locks/ tree by walking up for `.repro/manifests` or
#      `.repo/manifests` -- neither of which exists in a CI checkout. Without
#      the override the step exits 3 with "cannot locate the manifest repo
#      locks/ tree", one step after `Setup dev env` was made to survive.
#   6. The CREDENTIAL half of the same contract: which token those sibling
#      clones authenticate with, and how many of them a job mints. See the
#      section header further down for the full rationale -- in brief, one
#      installation token per job, minted with the per-repo app-id and
#      private-key secrets (or inputs.private-key inside a composite), org-scoped
#      by `owner:` and never narrowed by `repositories:`, and every consuming
#      step naming a mint step that exists in its own job.
#   6b. A checkout that pulls `submodules:` passes a `token:`. A submodule
#      checkout is a clone of OTHER repositories and `libs/tree-sitter-nim` is
#      private, so an untokened one is a private clone with no credential --
#      which is why `mcr-dap-flow` failed at `Checkout codetracer` on a fresh
#      runner and passed on a warm one.
#
# # No mocks
#
# The workflow files themselves are the input. The private-key controls mutate
# isolated copies of real inputs and call the same scanner; no action or service
# is mocked. The main parse runs over the committed files GitHub executes.
#
# Run: bash ci/test/sibling-provisioning-test.sh
# Lane: a step of the `ci-contract-suites` job in codetracer.yml (stock
#       ubuntu-latest: bash, coreutils, git and jq -- no Nix, no dev shell).
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly REPO_ROOT
WORKFLOW_DIR="${1:-$REPO_ROOT/.github/workflows}"
readonly WORKFLOW_DIR
ACTIONS_DIR="${2:-$REPO_ROOT/.github/actions}"
readonly ACTIONS_DIR

# Every file that may declare a `siblings:` block: the workflows, plus each
# composite action. A composite is a workflow step by another name and the
# action input it passes is the same one.
declare -a SIBLING_SOURCE_FILES=()
for _wf in "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml; do
	[ -f "$_wf" ] && SIBLING_SOURCE_FILES+=("$_wf")
done
for _act in "$ACTIONS_DIR"/*/action.yml "$ACTIONS_DIR"/*/action.yaml; do
	[ -f "$_act" ] && SIBLING_SOURCE_FILES+=("$_act")
done
unset _wf _act

# GitHub Actions' own expression syntax, quoted verbatim -- this is the literal
# text a sibling ref must not contain without a `||` fallback beside it.
# shellcheck disable=SC2016
readonly ACTIONS_EXPR_OPEN='${{'

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

# ---------------------------------------------------------------------------
# 1. Every `siblings:` entry resolves to a REPRODUCIBLE revision.
#
# Deliberately a small, explicit scanner rather than a YAML library: this must
# run on a stock runner with bash and nothing else, in the same spirit as
# ci/test/windows-runner-bootstrap-test.sh.
#
# A `siblings: |` block is a YAML literal scalar; its entries are the lines
# indented deeper than the key, up to the first line that is not.
#
# ## What "reproducible" means here, and why this assertion inverted
#
# `clone-siblings` accepts four shapes of entry, and they are not equally
# trustworthy:
#
#     name                    -> the WORKSPACE LOCK for the commit under test
#     name=<40-hex>           -> an immutable commit SHA
#     name=${{ ... }}         -> a workflow_dispatch / repository_dispatch knob
#     name=<branch-or-tag>    -> whatever that ref points at AT CLONE TIME
#
# The first two answer "what revision of sibling X does THIS commit use?" the
# same way on every re-run, forever. The last one does not: it is a branch tip,
# so re-running last month's build clones this month's sibling. `clone-siblings`
# says so itself, emitting a `::warning::` per non-SHA override that the build
# "is therefore not reproducible".
#
# This assertion used to demand the OPPOSITE -- an explicit `=ref` on every
# entry -- and that was right at the time: lock publication for this repo had
# stopped on 2026-08-02 (see the file header), so a bare entry was a live
# dependency on a lock that did not exist and the job died in its first step.
# Pinning each sibling to `dev` was the tourniquet.
#
# Publication is working again, so the tourniquet is now the wound: a mandatory
# `=dev` is a mandatory unreproducible build. The contract is therefore stated
# the way it should always have been -- a bare entry is the GOOD shape -- with a
# shrink-only ceiling on the branch-tip entries that have not been converted
# yet, so the population can only go down.
# ---------------------------------------------------------------------------
echo "siblings: entries pin a reproducible revision"

# Branch-tip entries still outstanding elsewhere in this repo, as a CEILING.
# `<=`, never `==`: converting more of them must not fail the suite, and adding
# one must. Lower this number as blocks are converted; there is no legitimate
# reason to raise it.
#
# 67 -> 53 in one pass, in two steps and for two different reasons:
#
#   67 -> 62  `provision-repro-lock-siblings` replaced the five `=dev` entries
#             for the IsoNim family with `repro develop`, which supplies exact
#             SHAs from repro.lock. Converted by deletion, not by pinning.
#
#   62 -> 56  io-mon, nim-shm-queue and nim-shm-gset are flake INPUTS of this
#             repo, so a rev for each already exists in flake.lock and is what
#             the `ci` dev shell and reprobuild compile against. Their sibling
#             checkouts said `=dev`, which is a different thing that merely
#             usually agrees -- one pin spelled in two places, with nothing
#             keeping the two spellings equal. They now name the flake.lock
#             rev, so the checkout and the shell are the same revision by
#             construction.
#
# nim-stackable-hooks was DELIBERATELY NOT CONVERTED, and the reason is a
# defect worth someone's attention: flake.lock locks that one repo at TWO
# DIFFERENT revisions --
#
#     node nim-stackable-hooks       171980881be3910fde4e320d5a2a503e7fd00045
#     node nim-stackable-hooks-src   41ab1b987aba67e8bcc34a5945ac33e17b6418ed
#
# -- so "the rev flake.lock pins" is not a well-defined thing to pin the
# sibling checkout to, and choosing either would be a guess dressed as a
# reproducibility improvement. It stays `=dev`, exactly as it was before, until
# the two nodes are reconciled. (io-mon also has two nodes, `io-mon` and
# `io-mon-src`, but they agree, so it converts without ambiguity.)
#
# The ceiling had been exceeded (67 > 59) on `dev` for some time without ever
# being reported, because this suite ran inside `ci-verdict` behind steps that
# aborted first, and no `Codetracer CI` run on `dev` reached it.
#
# 53 -> 30: the twenty-three `codetracer-trace-format=dev` /
# `codetracer-trace-format-nim=dev` entries across eleven `siblings:` blocks
# now name the commit `flake.lock` locks each input at. Same conversion, same
# reason, as the io-mon / nim-shm pair above -- these two are flake INPUTS of
# this repo, so a rev for each already existed and `=dev` was the same pin
# spelled a second way with nothing keeping the two spellings equal. Here the
# two spellings had actually diverged: trace-format's `dev` tip is 051a298
# (2026-09-30) and its `/agents` input rev is 3fada0b, and every API
# `src/db-backend/src/ctfs_trace_reader` has called since 2026-10-03 landed in
# between. Every job that cloned the sibling at `dev` and ran cargo against
# src/db-backend failed to compile -- recorder-tests and rr-backend-tests in
# cross-repo-tests.yml, lint-rust and visual-replay-regression-gate in
# codetracer.yml, on `dev` as well as on `agents`.
#
# The agreement between those spellings is now asserted below rather than
# merely intended, so a flake.lock bump that leaves a workflow behind is a
# failure here instead of a compile error two jobs later.
#
# 30 -> 15: the nine `codetracer-native-recorder=dev` entries (seven blocks in
# codetracer.yml, cross-repo-tests.yml, setup-db-backend-siblings) and the
# `|| 'dev'` fallback in mcr-dap-flow.yml now name the commit flake.lock locks,
# for the trace-format reason: flake.lock locks a recorder commit that is not
# on its `dev` (a18db9bd5, 2026-10-09), and the codetracer-native-backend these
# lanes build passes `ct-mcr replay-worker --parent-pid`, which only that
# commit's ct-mcr accepts. The count had already fallen to 24 unnoticed, since
# a ceiling reports only an increase.
#
# 15 -> 14: test-ui-tests no longer lists `nim-stackable-hooks=dev`.
# provision-repro-lock-siblings now clones it at the revision repro.lock pins.
# Converted by deletion.
#
# 14 -> 11 (2026-11-17): codetracer.yml's two `nim-stackable-hooks=dev` entries
# and its `codetracer-js-recorder=dev` name the commits both locks lock
# (073193067, 1df4100fb), now that flake.nix follows those repositories'
# `agents` branches.
#
# 11 -> 10 (2026-11-18): the visual-replay gate's
# `codetracer-visual-replay-fixtures=dev` is gone. Nothing the gate runs reads
# that checkout (ci/test/visual-replay-gate.sh, and the seven
# codetracer-visual-replay tests it runs, never name it; only that repo's
# `regen-golden` recipes and golden-image tests do, and the gate runs neither),
# so it was a clone with no consumer, not a pin to convert. Converted by
# deletion, together with its declaration in the test lock.
#
# 10 -> 9 (2026-11-22): the visual-replay gate's
# `codetracer-native-test-programs=dev` names ci/toolchain.pin's
# PRIVATE_SIBLING_CODETRACER_NATIVE_TEST_PROGRAMS instead (1e: a private
# sibling with a home is not cloned at a branch).
readonly BRANCH_TIP_CEILING=9

# Classify one sibling entry's ref text. Factored out of the scanner so it can
# be exercised directly by the self-test below: a detector that silently stops
# firing is exactly how "nothing forbidden was found" becomes a vacuous pass.
classify_ref() { # $1 = the text after the first '=' ('' for a bare entry)
	local ref="$1"
	case "$ref" in
	'') printf 'empty\n' ;;
	*"$ACTIONS_EXPR_OPEN"*) printf 'expr\n' ;;
	*)
		if [ "${#ref}" -eq 40 ] && [ -z "${ref//[0-9a-f]/}" ]; then
			printf 'sha\n'
		else
			printf 'branch\n'
		fi
		;;
	esac
}

# The literal an expression ref falls back to: `${{ x || '<sha>' }}` -> <sha>.
# Only a quoted literal after the last `||` counts; anything else (another
# expression, no fallback) prints nothing.
expr_fallback() { # $1 = the ref text
	sed -nE "s/^.*\|\|[[:space:]]*'([^']*)'[[:space:]]*\}\}[[:space:]]*$/\1/p" <<<"$1"
}

sibling_blocks=0
bad_entries=()
entry_count=0
branch_tip_entries=()
# Every `name=<40-hex>` entry seen, as `<file>:<line>:<name>=<sha>`, for the
# flake.lock-agreement assertion (1d) and the private-sibling one (1e) below.
# An expression ref's quoted 40-hex `|| '<sha>'` fallback is recorded here too:
# it is the revision every push and schedule run clones, so it is as much a
# copy of the pin as a literal is (cross-repo-tests.yml and mcr-dap-flow.yml
# name codetracer-native-backend that way).
sha_entries=()
# Every branch-ref entry, literal or an expression's `|| '<branch>'` fallback,
# as `<file>:<line>:<name>=<ref>`, for 1e: a private sibling whose revision
# has a home must not be cloned at a branch instead.
branch_entries=()
# Per-block record of which repos each `siblings:` block provisions, used by
# the matched-pair assertion further down. One space-delimited entry per block.
declare -a BLOCK_REPOS=()
declare -a BLOCK_WHERE=()

for wf in "${SIBLING_SOURCE_FILES[@]}"; do
	# Every composite action's file is called `action.yml`, so the bare
	# basename cannot tell two of them apart -- and this suite now makes
	# per-block assertions. Carry the action's directory for those.
	case "$wf" in
	"$ACTIONS_DIR"/*) wf_name="${wf#"$ACTIONS_DIR"/}" ;;
	*) wf_name="${wf##*/}" ;;
	esac
	in_block=0
	key_indent=0
	line_no=0
	block_repos=""
	while IFS= read -r line || [ -n "$line" ]; do
		line_no=$((line_no + 1))
		stripped="${line#"${line%%[![:space:]]*}"}"
		indent=$((${#line} - ${#stripped}))

		if [ "$in_block" -eq 1 ]; then
			if [ -z "$stripped" ] || [ "$indent" -le "$key_indent" ]; then
				in_block=0
				BLOCK_REPOS+=("$block_repos")
				block_repos=""
			else
				# `clone-siblings` strips a `#` comment from each line before
				# tokenising ("Both accept '#' comments and whitespace/newline
				# separation" -- clone-siblings/action.yml). Model that here, or
				# this scanner rejects a configuration the action accepts.
				stripped="${stripped%%#*}"
				stripped="${stripped%"${stripped##*[![:space:]]}"}"
				[ -z "$stripped" ] && continue
				block_repos="$block_repos ${stripped%%=*}"
				entry_count=$((entry_count + 1))
				case "$stripped" in
				*=*) ref="${stripped#*=}" ;;
				*) ref="" ;;
				esac
				# A bare entry and a `name=` entry both resolve through the
				# workspace lock (`clone-siblings`: "a trailing `=` falls back
				# to the lock"), so they are the same shape and are classified
				# together. Only their spelling differs.
				case "$stripped" in
				*=*) kind="$(classify_ref "$ref")" ;;
				*) kind=bare ;;
				esac
				case "$kind" in
				bare | empty) ;;
				sha) sha_entries+=("$wf_name:$line_no:$stripped") ;;
				expr)
					# An expression-valued ref must supply a fallback. Without
					# one it evaluates to the empty string on a push, which is
					# the lock path -- fine when that was the intent, and a
					# silent surprise when the author meant to pin something.
					case "$ref" in
					*'||'*)
						# A branch fallback (`|| 'dev'`) is recorded for 1e
						# only; the branch-tip ceiling counts literal entries.
						fallback="$(expr_fallback "$ref")"
						case "$(classify_ref "$fallback")" in
						sha) sha_entries+=("$wf_name:$line_no:${stripped%%=*}=$fallback") ;;
						branch) branch_entries+=("$wf_name:$line_no:${stripped%%=*}=$fallback") ;;
						esac
						;;
					*)
						bad_entries+=("$wf_name:$line_no: '$stripped' (expression ref with no || fallback evaluates to empty on push)")
						;;
					esac
					;;
				branch)
					branch_tip_entries+=("$wf_name:$line_no: '$stripped'")
					branch_entries+=("$wf_name:$line_no:$stripped")
					;;
				esac
				continue
			fi
		fi

		case "$stripped" in
		'siblings: |'*)
			in_block=1
			key_indent=$indent
			block_repos=""
			BLOCK_WHERE+=("$wf_name:$line_no")
			sibling_blocks=$((sibling_blocks + 1))
			;;
		esac
	done <"$wf"
	# A block that runs to EOF never hits the dedent that closes it.
	if [ "$in_block" -eq 1 ]; then
		BLOCK_REPOS+=("$block_repos")
	fi
done

if [ "${#bad_entries[@]}" -eq 0 ]; then
	ok "all $entry_count sibling entries across $sibling_blocks blocks name a usable ref"
else
	fail "all sibling entries name a usable ref" \
		"${bad_entries[@]}"
fi

if [ "$sibling_blocks" -gt 0 ]; then
	ok "the workflows still declare cross-repo siblings ($sibling_blocks blocks)"
else
	fail "the workflows still declare cross-repo siblings" \
		"no 'siblings: |' block was found -- either the input was renamed or the" \
		"scanner no longer matches it, and this suite is passing vacuously"
fi

# ---------------------------------------------------------------------------
# 1a. ANTI-VACUITY: the branch-tip detector fires.
#
# Every assertion below this point reports a defect by NOT finding something.
# That is the shape that has twice produced a vacuous green in this area (a
# scan whose glob was broken reported the forbidden pattern absent), so the
# classifier is exercised directly against known inputs first. If it stops
# recognising a branch tip, this fails here rather than passing everywhere.
# ---------------------------------------------------------------------------
echo
echo "the sibling-ref classifier still fires"

classifier_bad=()
check_classify() { # $1 = ref text, $2 = expected class
	local got
	got="$(classify_ref "$1")"
	[ "$got" = "$2" ] || classifier_bad+=("classify_ref '$1' = '$got', expected '$2'")
}
check_classify 'dev' branch
check_classify 'main' branch
check_classify 'release/1.2' branch
# One hex digit short of a commit SHA is a ref name, not a revision.
check_classify '0123456789abcdef0123456789abcdef0123456' branch
check_classify '0123456789abcdef0123456789abcdef01234567' sha
check_classify '' empty
check_classify "$ACTIONS_EXPR_OPEN inputs.isonim_ref }}" expr

if [ "${#classifier_bad[@]}" -eq 0 ]; then
	ok "classify_ref separates branch tips from commit SHAs, expressions and the lock"
else
	fail "classify_ref separates branch tips from commit SHAs, expressions and the lock" \
		"the detector the assertions below depend on is broken, so they prove nothing" \
		"${classifier_bad[@]}"
fi

# ---------------------------------------------------------------------------
# 1b. The from-source DEPENDENCY siblings come from this repo's OWN lock.
#
# isonim and the four nim-* libraries codetracer compiles against are not
# provisioned through `clone-siblings` at all any more, and the reason is the
# distinction the rest of this file is built on, taken one step further.
#
# `clone-siblings` resolves a bare name against the per-commit WORKSPACE lock
# in metacraft-labs/metacraft-manifests. A workspace lock is a snapshot (a
# `locks/<project>/<repo>/<sha>.toml` record; the repo-workspaces `repo
# manifest -r` XML records were retired and erased on 2026-09-29) of the repo
# SET a developer had checked out when they pushed --
# a convenience for standing a workspace up, and deliberately a superset of
# what any one build needs. It is not this repo's statement of what this repo
# depends on, and treating it as one cost this repo two outages:
#
#   * four of the nine names the old `.github/actions/setup-isonim-siblings`
#     carried -- isonim-tui, isonim-gpui, nim-termctl, nim-pty -- belong to the
#     `isonim` workspace project, not the `codetracer` one. Nothing here
#     declares them, so no codetracer commit could pin them; the entries failed
#     resolution and took out every job that reached the action. They appeared
#     in a codetracer lock at all only when the pusher's workspace happened to
#     also carry the isonim project.
#
#   * the fix for that -- `=dev` on all nine -- silently un-pinned the four the
#     lock WAS pinning, and made the other five branch tips.
#
# `repro.lock` is committed in this repo, next to the source it describes. It
# names the dependency set (the develop set) and a 40-hex revision for each,
# and `.github/actions/provision-repro-lock-siblings` clones its build-input
# members -- the ones the lock also lists as solved packages -- with
# `repro develop --all --only=<them>`. No manifest repo, no publication lag, no
# branch tip.
#
# What is asserted here is that the arrangement stays that way: the action
# still runs the lock-driven command (anti-vacuity -- everything below is
# meaningless if it was renamed or rewritten) and takes its `--only=` set from
# the lock through `ci/repro-lock-build-input-siblings.sh`, it hand-writes no
# sibling list of its own, the lock still declares the dependency set and its
# build-input subset, the clone is given the job's credential through the
# channel reprobuild reads, and every member of that set carries an immutable
# revision.
# ---------------------------------------------------------------------------
echo
echo "the from-source dependency siblings resolve from this repo's repro.lock"

readonly LOCK_ACTION="$ACTIONS_DIR/provision-repro-lock-siblings/action.yml"
readonly REPRO_LOCK="$REPO_ROOT/repro.lock"
# The dependency set is DERIVED, not pinned here. It used to be a 61-name list
# re-taken from repro.lock by hand (last on 2026-11-14), compared against the
# `codetracer` node's `depends`. Two things retired that:
#
#   * reprobuild 5a1326957 takes a repo's dependencies only from its
#     `repro.nim` `uses:` and records the lock as a GRAPH: the root's `depends`
#     lists the DIRECT dependencies, and the `deps` entries hold the whole
#     transitive set the recipes derive. The develop set is therefore every
#     `deps` entry other than codetracer's own.
#   * The owner rule is that `repro.nim` is the one declaration and the lock
#     holds exactly what it derives. A second hand-kept list here was a second
#     declaration, and on 2026-11-15 it disagreed with the lock in 48 places.
#
# So the assertions below check the lock against `repro.nim` and against what
# the workflows check out, with no list of names of their own:
#
#   1. the develop set is exactly the closure of the root's direct `depends`
#      over the `deps` graph (nothing dangling, nothing orphaned), each direct
#      member is declared in `repro.nim` (a `uses:` entry, or the `../<name>/`
#      source import that brings in `reprobuild-packages`), and every sibling a
#      workflow checks out BY BARE NAME -- resolved against this lock -- is a
#      member;
#   2. `provision-repro-lock-siblings` clones the whole declared set: the
#      owner's decision (2026-11-16, "clone all"). Every `uses:` sibling is now
#      a solved package, so the lock no longer separates Nim build inputs from
#      test-lane siblings, and the selector returns every develop-set member
#      that is a solved package -- computed here independently;
#   3. every member carries a 40-hex revision.
#
# The test lanes' siblings are not in this set: ci/test/siblings/repro.lock
# pins them, and the TEST LOCK assertions further down check that lock.
readonly BUILD_INPUT_SELECTOR="$REPO_ROOT/ci/repro-lock-build-input-siblings.sh"

# Anti-vacuity first: the action must exist and must still invoke the command
# whose behaviour every assertion below describes.
lock_action_defects=()
if [ ! -f "$LOCK_ACTION" ]; then
	lock_action_defects+=("$LOCK_ACTION does not exist")
else
	grep -q 'repro develop --all' "$LOCK_ACTION" ||
		lock_action_defects+=("it does not run 'repro develop --all'")
	# --reset: the self-hosted runners reuse their work tree, so a sibling left
	# at some other revision by an earlier job would otherwise make `develop
	# --all` REFUSE rather than reconcile, and the job would fail on a stale
	# checkout it did not create.
	grep -q -- '--reset' "$LOCK_ACTION" ||
		lock_action_defects+=("it does not pass --reset, so a drifted sibling refuses instead of reconciling")
	# --into: names the `../<name>` adjacency config.nims resolves, rather than
	# leaving the placement root to be inferred.
	grep -q -- '--into=' "$LOCK_ACTION" ||
		lock_action_defects+=("it does not pass --into=, so the sibling placement root is implicit")
	# --only=<build inputs>: the develop set also names the test-lane
	# siblings, which no Nim build compiles and `clone-siblings` provisions
	# where a lane needs them. The subset comes from the lock, through the
	# selector script, not from a list written into the action.
	grep -q -- '--only=' "$LOCK_ACTION" ||
		lock_action_defects+=("it does not pass --only=, so it clones the whole develop set, private test-lane siblings included")
	grep -q 'ci/repro-lock-build-input-siblings.sh' "$LOCK_ACTION" ||
		lock_action_defects+=("it does not take its --only= set from ci/repro-lock-build-input-siblings.sh")
fi

if [ "${#lock_action_defects[@]}" -eq 0 ]; then
	ok "provision-repro-lock-siblings still runs 'repro develop --all --only=<build inputs> --reset --into='"
else
	fail "provision-repro-lock-siblings still runs 'repro develop --all --only=<build inputs> --reset --into='" \
		"the assertions below describe what that command does; without it they" \
		"describe nothing" \
		"${lock_action_defects[@]}"
fi

# It must contribute no sibling NAMES of its own -- the whole point is that the
# set comes from the lock. A `siblings:` block here would be a second answer to
# "which repos?", and a hard-coded revision would be a second answer to "which
# revision?".
lock_action_handwritten=()
if [ -f "$LOCK_ACTION" ]; then
	if grep -q 'siblings: |' "$LOCK_ACTION"; then
		lock_action_handwritten+=("it declares a 'siblings: |' block")
	fi
	# A 40-hex string in the RUNS section would be a pin this action chose
	# rather than one the lock supplies. (The description may quote SHAs as
	# prose; only the executable half is scanned.) A step key that is exactly
	# `uses: <action>@<40-hex>` is skipped: the commit an ACTION is pinned to
	# (the shared git-auth action below) is not a sibling revision, and is
	# required to be 40-hex. Only that whole-line shape is skipped, so a
	# revision anywhere in a script body, or after anything else on a `uses:`
	# line, is still caught.
	# Here-string, not a pipe: `grep -q` exits on its first match, `sed` then
	# takes SIGPIPE, and under `set -o pipefail` a SUCCESSFUL MATCH is reported
	# as failure. See ci/test/grep-q-pipefail-gate.sh.
	if grep -Eq '\b[0-9a-f]{40}\b' <<<"$(sed -n '/^runs:/,$p' "$LOCK_ACTION" |
		grep -Ev '^[[:space:]]*(- )?uses: [A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}[[:space:]]*$')"; then
		lock_action_handwritten+=("its runs: section contains a hard-coded 40-hex revision")
	fi
fi

if [ "${#lock_action_handwritten[@]}" -eq 0 ]; then
	ok "it hand-writes neither a sibling set nor a revision"
else
	fail "it hand-writes neither a sibling set nor a revision" \
		"the dependency set and its revisions come from repro.lock; anything" \
		"named here is a second source of truth for the same question" \
		"${lock_action_handwritten[@]}"
fi

# The lock itself. `deps` entries open `{ name = "<n>", ` followed by
# `self = "true", ` (codetracer's own, v3), `path = "<p>", ` (v2) or directly
# `coord_kind`; codetracer's entry is the one marked self (or at path ".").
lock_root_depends=""
lock_develop_set=""
declare -A lock_edges=()
if [ -f "$REPRO_LOCK" ]; then
	lock_root_depends="$(grep -o 'name = "codetracer", \(self = "true"\|path = "\."\)[^}]*depends = "[^"]*"' "$REPRO_LOCK" |
		sed 's/.*depends = "//; s/"$//' | head -n 1)"
	while IFS=$'\t' read -r dep_name dep_depends; do
		lock_edges["$dep_name"]="$dep_depends"
		lock_develop_set="${lock_develop_set:+$lock_develop_set,}$dep_name"
	done < <(grep -o '{ name = "[^"]*", \(path = "[^"]*", \)\?coord_kind = [^}]*' "$REPRO_LOCK" |
		grep -v '^{ name = "codetracer", path = "\.", ' |
		sed -n 's/^{ name = "\([^"]*\)", .*depends = "\([^"]*\)".*/\1\t\2/p')
fi

# Compared as SETS (sorted, duplicates kept so a repeated name still differs):
# `repro lock` does not keep the order of `depends` stable across refreshes.
sorted_dep_set() { tr ',' '\n' <<<"$1" | sed '/^$/d' | LC_ALL=C sort; }

# 1a. The develop set is the closure of the root's direct dependencies.
closure=""
pending="$lock_root_depends"
declare -A seen=()
while [ -n "$pending" ]; do
	IFS=',' read -r -a _frontier <<<"$pending"
	pending=""
	for dep in "${_frontier[@]}"; do
		[ -n "$dep" ] && [ -z "${seen[$dep]:-}" ] || continue
		seen["$dep"]=1
		closure="${closure:+$closure,}$dep"
		pending="${pending:+$pending,}${lock_edges[$dep]:-}"
	done
done
unset seen
if [ -n "$lock_root_depends" ] &&
	[ "$(sorted_dep_set "$closure")" = "$(sorted_dep_set "$lock_develop_set")" ]; then
	ok "repro.lock's develop set is the closure of codetracer's direct dependencies ($(sorted_dep_set "$lock_develop_set" | wc -l) siblings)"
else
	fail "repro.lock's develop set is the closure of codetracer's direct dependencies" \
		"every \`deps\` entry must be reached from the root's \`depends\`, and every" \
		"name an edge reaches must have its own entry; anything else is a lock" \
		"'repro lock refresh' did not write" \
		"reached but no entry:   $(comm -23 <(sorted_dep_set "$closure") <(sorted_dep_set "$lock_develop_set") | paste -sd, -)" \
		"entry but not reached:  $(comm -13 <(sorted_dep_set "$closure") <(sorted_dep_set "$lock_develop_set") | paste -sd, -)" \
		"root depends: ${lock_root_depends:-<none>}"
fi

# 1b. Each direct dependency is declared in repro.nim, the one declaration.
undeclared_direct=()
IFS=',' read -r -a _direct <<<"$lock_root_depends"
for dep in "${_direct[@]}"; do
	[ -n "$dep" ] || continue
	grep -Eq "^[[:space:]]*\"$dep [^\"]*\"|import \"\.\./$dep/" "$REPO_ROOT/repro.nim" ||
		undeclared_direct+=("$dep")
done
if [ -n "$lock_root_depends" ] && [ "${#undeclared_direct[@]}" -eq 0 ]; then
	ok "every direct dependency in repro.lock is declared in repro.nim (${#_direct[@]})"
else
	fail "every direct dependency in repro.lock is declared in repro.nim" \
		"repro.lock records what repro.nim derives; a direct dependency repro.nim" \
		"does not name is a pin nothing declares" \
		"root depends: ${lock_root_depends:-<none>}" \
		"not in repro.nim: ${undeclared_direct[*]-}"
fi

# Repositories a workflow clones that the public repro.lock deliberately does
# not pin, each with the reason. repro.lock and repro.nim are public, so a
# private repository can be neither declared nor pinned there; a lane that
# needs one provisions it itself. An entry whose repo the lock DOES pin is a
# failure (checked below), so this list cannot go stale. A bare entry of one of
# these names in a workflow's `siblings:` block resolves against the public
# lock and cannot be cloned, so it is a failure (checked with the bare names
# below): the lane must give it an explicit `=<ref>`.
declare -A UNLOCKED_SIBLINGS=(
	["codetracer-native-recorder"]="private"
	["codetracer-native-backend"]="private"
	["codetracer-visual-replay"]="private"
	["codetracer-launcher"]="private"
	["codetracer-native-test-programs"]="private"
	["codetracer-snapshot-codecs"]="private"
	["isonim-zgui"]="private; the zgui lane clones it at ci/toolchain.pin's PRIVATE_SIBLING_ISONIM_ZGUI"
	["codetracer-private-recordings"]="private; the desktop and Firefox scenario lanes clone it at ci/toolchain.pin's PRIVATE_SIBLING_CODETRACER_PRIVATE_RECORDINGS"
	["codetracer-evm-recorder"]="public, but its tools/source_inputs.nim collides with another recorder's in the provider nimcache, so repro.nim cannot declare it"
)
unlocked_now_pinned=()
for _name in "${!UNLOCKED_SIBLINGS[@]}"; do
	[[ ",$lock_develop_set," == *",$_name,"* ]] &&
		unlocked_now_pinned+=("'$_name' is in repro.lock now; remove it from UNLOCKED_SIBLINGS")
done
if [ "${#unlocked_now_pinned[@]}" -eq 0 ]; then
	ok "no sibling listed as deliberately unlocked is pinned by repro.lock (${#UNLOCKED_SIBLINGS[@]})"
else
	fail "no sibling listed as deliberately unlocked is pinned by repro.lock" "${unlocked_now_pinned[@]}"
fi

# 1c. Every sibling a workflow checks out by BARE name is resolved against
# this lock (`clone-siblings`: a bare or trailing-`=` entry falls back to the
# lock), so each must be a member. `siblings:` blocks are scanned above;
# `extra-siblings:` blocks feed the same `siblings:` input of
# setup-db-backend-siblings. `test-siblings:` names resolve against the test
# lock instead, and are checked with it below.
bare_names=()
while IFS= read -r bare; do
	[ -n "$bare" ] && bare_names+=("$bare")
done < <(
	for wf in "${SIBLING_SOURCE_FILES[@]}"; do
		awk '
			/^[[:space:]]*(siblings|extra-siblings): *\|/ { match($0, /^[[:space:]]*/); key = RLENGTH; inb = 1; next }
			inb {
				if ($0 ~ /^[[:space:]]*$/) { inb = 0; next }
				match($0, /^[[:space:]]*/); if (RLENGTH <= key) { inb = 0; next }
				line = $0; sub(/#.*/, "", line); gsub(/[[:space:]]/, "", line)
				if (line == "" || line ~ /\$\{\{/) next
				if (line !~ /=/ || line ~ /=$/) { sub(/=$/, "", line); print line }
			}' "$wf"
	done | LC_ALL=C sort -u
)
unlocked_bare=()
private_bare=()
for bare in "${bare_names[@]}"; do
	if [ -n "${UNLOCKED_SIBLINGS[$bare]:-}" ]; then
		private_bare+=("$bare")
		continue
	fi
	[[ ",$lock_develop_set," == *",$bare,"* ]] || unlocked_bare+=("$bare")
done
# A bare entry of a name the public lock deliberately does not pin cannot be
# cloned: clone-siblings resolves it against this lock and finds nothing. That
# was "an open consequence" until bbf7dbed4a6 dropped the private siblings from
# the lock with three bare entries still in the workflows (codetracer-launcher
# in tui-tests.yml, codetracer-visual-replay in mcr-dap-flow.yml,
# codetracer-native-recorder in launcher-recorder-e2e.yml), and run
# 44612896066's TUI shards all failed on "pins no revision for these
# sibling(s): codetracer-launcher". Each such entry must carry `=<rev>`.
if [ "${#private_bare[@]}" -eq 0 ]; then
	ok "no workflow names a sibling the public lock cannot pin bare (${#UNLOCKED_SIBLINGS[@]} such siblings)"
else
	fail "no workflow names a sibling the public lock cannot pin bare" \
		"these are in UNLOCKED_SIBLINGS, so repro.lock never pins them and a" \
		"bare entry clones nothing; give each an explicit '<name>=<rev>'" \
		"(flake.lock's revision, or ci/toolchain.pin's PRIVATE_SIBLING_* one):" \
		"${private_bare[*]}"
fi
if [ "${#bare_names[@]}" -gt 0 ] && [ "${#unlocked_bare[@]}" -eq 0 ]; then
	ok "every sibling the workflows check out by bare name is in repro.lock (${#bare_names[@]})"
else
	fail "every sibling the workflows check out by bare name is in repro.lock" \
		"clone-siblings resolves a bare name against this lock, so a name it does" \
		"not pin fails the clone; declare it in repro.nim 'uses:' and relock" \
		"found ${#bare_names[@]} bare name(s)" \
		"not in repro.lock: ${unlocked_bare[*]-}"
fi

# 2. ... and provision-repro-lock-siblings clones all of it: every member that
# is a solved package, computed here without the selector.
expected_build_inputs=()
IFS=',' read -r -a _members <<<"$lock_develop_set"
for dep in "${_members[@]}"; do
	grep -Eq "\\{ name = \"$dep\", version = \"[^\"]*\", source = \"$dep\"" "$REPRO_LOCK" &&
		expected_build_inputs+=("$dep")
done
if [ -x "$BUILD_INPUT_SELECTOR" ]; then
	actual_build_inputs="$("$BUILD_INPUT_SELECTOR" "$REPRO_LOCK" 2>&1)" || true
else
	actual_build_inputs="<$BUILD_INPUT_SELECTOR is missing or not executable>"
fi
expected_joined="$(
	IFS=','
	echo "${expected_build_inputs[*]}"
)"
if [ "${#expected_build_inputs[@]}" -gt 0 ] &&
	[ "$(sorted_dep_set "$actual_build_inputs")" = "$(sorted_dep_set "$expected_joined")" ]; then
	ok "provision-repro-lock-siblings clones every solved sibling in repro.lock (${#expected_build_inputs[@]})"
else
	fail "provision-repro-lock-siblings clones every solved sibling in repro.lock" \
		"this is what every job using the action checks out next to codetracer" \
		"expected: $expected_joined" \
		"actual:   $actual_build_inputs"
fi

# The same build-input set must survive v3's removal of all dependency paths.
path_free_lock="$(mktemp)"
sed -e 's/solved-graph-lock.v2/solved-graph-lock.v3/' \
	-e 's/path = "\.", /self = "true", /g' \
	-e 's/path = "[^" ]*", //g' "$REPRO_LOCK" >"$path_free_lock"
path_free_inputs="$("$BUILD_INPUT_SELECTOR" "$path_free_lock" 2>&1)" || true
rm -f "$path_free_lock"
if [ "$path_free_inputs" = "$actual_build_inputs" ]; then
	ok "path-free v3 locks select the same build-input siblings"
else
	fail "path-free v3 locks select the same build-input siblings" \
		"expected: $actual_build_inputs" "actual: $path_free_inputs"
fi

# THE TEST LOCK. The siblings the test lanes run against and no build compiles
# -- the scenario runner, its backends and the terminal harness -- are pinned
# by ci/test/siblings/repro.lock, a project of its own nested here, and not by
# repro.lock. repro.lock is refreshed from repro.nim on every push, and
# repro.nim names only what the product is built from, so each refresh dropped
# them, and each time every scenario job stopped at "'--only=DemoVideoScript'
# names no repo in this workspace's lock set" (codetracer-pm issue
# 2026-11-15-repro-lock-refreshes-drop-the-scenario-lanes-test-siblings).
readonly TEST_LOCK="$REPO_ROOT/ci/test/siblings/repro.lock"
# The scenario siblings, and the repositories a workflow clones at an explicit
# ref that repro.nim does not declare (2026-11-17).
readonly TEST_LOCK_DECLARED_DEPS='DemoVideoScript,DemoVideoScript-TermAssert,DemoVideoScript-GuiAssert,DemoVideoScript-Playwright,GuiAssert,TermAssert,TermAssertClient,nim-libvterm,nim-pty,codetracer-cairo-recorder,codetracer-cardano-recorder,codetracer-circom-recorder,codetracer-flow-recorder,codetracer-fuel-recorder,codetracer-leo-recorder,codetracer-miden-recorder,codetracer-move-recorder,codetracer-php-recorder,codetracer-polkavm-recorder,codetracer-solana-recorder,codetracer-ton-recorder,codetracer-flame-demo,codetracer-pm,test-certificates-spec,codetracer-example-recordings'
# The members that are ONLY test siblings. They must not come back into
# repro.lock: two locks pinning one repository is two answers to "which
# revision?", and the product lock's answer is the one a refresh deletes.
readonly TEST_ONLY_SIBLINGS='DemoVideoScript,DemoVideoScript-TermAssert,DemoVideoScript-GuiAssert,DemoVideoScript-Playwright,GuiAssert'

# lock_rev <lock> <name> -> the revision the lock's deps entry records, or ''.
lock_rev() {
	grep -o "name = \"$2\", \\(self = \"true\", \\)\\?coord_kind = \"vcs\", url = \"[^\"]*\", revision = \"[0-9a-f]*\"" "$1" 2>/dev/null |
		sed 's/.*revision = "//; s/"$//' | head -n 1
}

# The test lock's closure: every entry it pins. Its root entry's `depends`
# names only the direct dependencies (reprobuild 0.2.25 records the graph), and
# DemoVideoScript, GuiAssert and the terminal harness arrive through the
# backends.
if [ -f "$TEST_LOCK" ]; then
	test_lock_deps="$(grep -o '{ name = "[^"]*", coord_kind = "vcs"' "$TEST_LOCK" |
		sed 's/{ name = "//; s/".*//' | paste -sd, -)"
else
	test_lock_deps="<$TEST_LOCK not found>"
fi
if [ "$(sorted_dep_set "$test_lock_deps")" = "$(sorted_dep_set "$TEST_LOCK_DECLARED_DEPS")" ]; then
	ok "the test lock declares the test siblings ($test_lock_deps)"
else
	fail "the test lock declares the test siblings" \
		"ci/test/siblings/repro.lock is what provision-repro-lock-siblings clones" \
		"every test-siblings name from" \
		"missing from the test lock: $(comm -23 <(sorted_dep_set "$TEST_LOCK_DECLARED_DEPS") <(sorted_dep_set "$test_lock_deps") | paste -sd, -)" \
		"not declared here:          $(comm -13 <(sorted_dep_set "$TEST_LOCK_DECLARED_DEPS") <(sorted_dep_set "$test_lock_deps") | paste -sd, -)"
fi

test_lock_defects=()
IFS=',' read -r -a _test_declared <<<"$TEST_LOCK_DECLARED_DEPS"
for name in "${_test_declared[@]}"; do
	rev="$(lock_rev "$TEST_LOCK" "$name")"
	if ! [[ $rev =~ ^[0-9a-f]{40}$ ]]; then
		test_lock_defects+=("$name: the test lock records no 40-hex revision ('$rev')")
		continue
	fi
	# A repository both locks pin must be one commit: nim-pty is a build input
	# of ct AND what TermAssert drives, and the TUI lanes compile both halves
	# against the one ../nim-pty checkout.
	product_rev="$(lock_rev "$REPRO_LOCK" "$name")"
	if [ -n "$product_rev" ] && [ "$product_rev" != "$rev" ]; then
		test_lock_defects+=("$name: the test lock pins $rev, repro.lock pins $product_rev")
	fi
done
IFS=',' read -r -a _test_only <<<"$TEST_ONLY_SIBLINGS"
for name in "${_test_only[@]}"; do
	if [ -n "$(lock_rev "$REPRO_LOCK" "$name")" ]; then
		test_lock_defects+=("$name is pinned by repro.lock too; it belongs to the test lock only")
	fi
done
if [ "${#test_lock_defects[@]}" -eq 0 ]; then
	ok "every test sibling has one 40-hex pin, and the two locks agree where both pin a repo"
else
	fail "every test sibling has one 40-hex pin, and the two locks agree where both pin a repo" \
		"${test_lock_defects[@]}"
fi

# The action clones test-siblings from the test lock: `repro develop` reads the
# lock of the project it runs in, so it has to run in ci/test/siblings.
if [ -f "$LOCK_ACTION" ] && grep -q 'cd ci/test/siblings && exec repro develop --all --only=' "$LOCK_ACTION"; then
	ok "provision-repro-lock-siblings clones test-siblings from the test lock"
else
	fail "provision-repro-lock-siblings clones test-siblings from the test lock" \
		"its test-siblings must be resolved by 'repro develop' run in ci/test/siblings;" \
		"from the codetracer root they resolve against repro.lock, which does not pin them"
fi

# Every name a job passes as test-siblings is one the test lock pins; anything
# else stops that job at "names no repo in this workspace's lock set".
test_sibling_defects=()
while IFS= read -r hit; do
	file="${hit%%:*}"
	rest="${hit#*:}"
	line="${rest%%:*}"
	value="$(sed 's/.*test-siblings:[[:space:]]*//; s/[[:space:]]*$//' <<<"${rest#*:}")"
	IFS=',' read -r -a _named <<<"$value"
	for name in "${_named[@]}"; do
		if ! grep -qx -- "$name" <(sorted_dep_set "$test_lock_deps"); then
			test_sibling_defects+=("${file##*/}:$line: '$name' is not in the test lock")
		fi
	done
done < <(grep -n -H -E '^[[:space:]]+test-siblings:[[:space:]]*[A-Za-z]' "$WORKFLOW_DIR"/*.yml 2>/dev/null)
if [ "${#test_sibling_defects[@]}" -eq 0 ]; then
	ok "every test-siblings name is one the test lock pins"
else
	fail "every test-siblings name is one the test lock pins" "${test_sibling_defects[@]}"
fi

# EVERY REPO A WORKFLOW CLONES IS DECLARED BY A LOCK. A sibling that no lock
# declares is one `repro lock refresh` is free to drop, or never had, and each
# such drop surfaced only when a job died on it. So every clone in the
# workflows and the composite actions is matched against the two locks' develop
# sets: a BARE `siblings:` / `extra-siblings:` entry is resolved by
# `clone-siblings` against repro.lock, so repro.lock must declare it; an entry
# with an explicit `=<ref>`, and a `clone-repo` / `checkout` of a
# `metacraft-labs/<repo>`, must be declared by one of the two (a ref chosen in a
# workflow is still a dependency some repro.nim owns). `test-siblings` names are
# checked against the test lock above.
cloned_repos() {
	local f label
	for f in "$WORKFLOW_DIR"/*.yml "$ACTIONS_DIR"/*/action.yml; do
		[ -f "$f" ] || continue
		label="${f#"$REPO_ROOT"/}"
		awk -v F="$label" '
			/^[ \t]+(siblings|extra-siblings): \|[ \t]*$/ { inblock = 1; next }
			inblock {
				if ($0 ~ /^[ \t]*$/ || $0 ~ /^[ \t]*#/ || index($0, "${{") > 0) next
				if ($0 ~ /^[ \t]+[A-Za-z0-9_.-]+(=[^ \t]+)?[ \t]*(#.*)?$/) {
					entry = $1
					kind = (index(entry, "=") > 0) ? "ref" : "bare"
					sub(/=.*/, "", entry)
					print F ":" NR " " kind " " entry
					next
				}
				inblock = 0
			}
			/^[ \t]+repo(sitory)?:[ \t]*metacraft-labs\/[A-Za-z0-9_.-]+[ \t]*$/ {
				name = $2
				sub(/^metacraft-labs\//, "", name)
				print F ":" NR " clone " name
			}
		' "$f"
	done
}

# The repos a workflow clones that neither lock declares, each with the reason.
# Keep it short: an entry leaves as soon as its repo can be declared, and an
# entry whose repo a lock does declare is itself a failure, so the list cannot
# go stale.
declare -A CLONED_BUT_UNDECLARED=(
)

root_set="$(sorted_dep_set "$lock_develop_set")"
test_set="$(sorted_dep_set "$test_lock_deps")"
undeclared_clones=()
for name in "${!CLONED_BUT_UNDECLARED[@]}"; do
	if grep -qx -- "$name" <<<"$root_set" || grep -qx -- "$name" <<<"$test_set"; then
		undeclared_clones+=("'$name' is declared by a lock now; remove it from CLONED_BUT_UNDECLARED")
	fi
done
cloned_count=0
while read -r where kind name; do
	[ -n "$name" ] || continue
	[ "$name" = codetracer ] && continue
	cloned_count=$((cloned_count + 1))
	in_root=0
	in_test=0
	grep -qx -- "$name" <<<"$root_set" && in_root=1
	grep -qx -- "$name" <<<"$test_set" && in_test=1
	if [ "$kind" = bare ]; then
		if [ "$in_root" -eq 0 ] && [ -z "${UNLOCKED_SIBLINGS[$name]:-}" ]; then
			if [ "$in_test" -eq 1 ]; then
				undeclared_clones+=("$where: '$name' is a bare entry, which clone-siblings resolves against repro.lock, but only the test lock declares it; pass it as provision-repro-lock-siblings' test-siblings")
			else
				undeclared_clones+=("$where: '$name' (bare) is declared by neither repro.lock nor the test lock")
			fi
		fi
	elif [ "$in_root" -eq 0 ] && [ "$in_test" -eq 0 ] && [ -z "${CLONED_BUT_UNDECLARED[$name]:-}" ] &&
		[ -z "${UNLOCKED_SIBLINGS[$name]:-}" ]; then
		undeclared_clones+=("$where: '$name' ($kind) is declared by neither repro.lock nor the test lock")
	fi
done < <(cloned_repos)
if [ "$cloned_count" -eq 0 ]; then
	fail "every repo a workflow clones is declared by repro.lock or the test lock" \
		"no clone was found at all, so this checked nothing"
elif [ "${#undeclared_clones[@]}" -eq 0 ]; then
	ok "every repo a workflow clones is declared by repro.lock or the test lock ($cloned_count clones)"
else
	fail "every repo a workflow clones is declared by repro.lock or the test lock" \
		"declare a test-only sibling in ci/test/siblings/repro.nim, a product one in" \
		"repro.nim, and refresh that lock" \
		"${undeclared_clones[@]}"
fi

# ONE PACKAGE CATALOG. ci/repro-lock-catalog-agreement.sh fails when a sibling's
# own repro.lock pins another reprobuild-packages revision than repro.lock;
# reprobuild refuses to compile a solve against two catalogs, which is how the
# arm64-macosx re-solve died (root 2c58192a, runquota 15ceea67). It must run
# after the clone, and it must tell agreement from disagreement.
readonly CATALOG_CHECK="$REPO_ROOT/ci/repro-lock-catalog-agreement.sh"
catalog_fixture="$(mktemp -d)"
cat_rev_a=1111111111111111111111111111111111111111
cat_rev_b=2222222222222222222222222222222222222222
cat_entry() { printf '{ name = "reprobuild-packages", coord_kind = "vcs", url = "https://github.com/metacraft-labs/reprobuild-packages", revision = "%s", integrity = "git-sha1:%s", version = "", visibility = "public", participation = "", depends = "", tags = "" }' "$1" "$1"; }
mkdir -p "$catalog_fixture/root" "$catalog_fixture/alpha" "$catalog_fixture/beta"
printf 'deps = [{ name = "root", self = "true", coord_kind = "vcs", url = "", revision = "", integrity = "", version = "", visibility = "public", participation = "", depends = "alpha,beta,reprobuild-packages", tags = "" }, %s]\n' "$(cat_entry $cat_rev_a)" >"$catalog_fixture/root/repro.lock"
printf 'deps = [%s]\n' "$(cat_entry $cat_rev_a)" >"$catalog_fixture/alpha/repro.lock"
printf 'deps = [%s]\n' "$(cat_entry $cat_rev_a)" >"$catalog_fixture/beta/repro.lock"
catalog_agree_rc=0
bash "$CATALOG_CHECK" "$catalog_fixture/root/repro.lock" "$catalog_fixture" >/dev/null 2>&1 || catalog_agree_rc=$?
printf 'deps = [%s]\n' "$(cat_entry $cat_rev_b)" >"$catalog_fixture/beta/repro.lock"
catalog_disagree_rc=0
catalog_disagree_out="$(bash "$CATALOG_CHECK" "$catalog_fixture/root/repro.lock" "$catalog_fixture" 2>&1)" || catalog_disagree_rc=$?
# A sibling whose recipe uses a catalog package while its lock pins no catalog
# resolves that package from an unpinned checkout: a second catalog too.
printf 'deps = [%s]\n' "$(cat_entry $cat_rev_a)" >"$catalog_fixture/beta/repro.lock"
mkdir -p "$catalog_fixture/reprobuild-packages/packages/interfaces/patchelf" "$catalog_fixture/gamma"
printf 'package gamma:\n  uses:\n    "patchelf"\n' >"$catalog_fixture/gamma/repro.nim"
printf 'deps = []\n' >"$catalog_fixture/gamma/repro.lock"
sed -i 's/depends = "alpha,beta,reprobuild-packages"/depends = "alpha,beta,gamma,reprobuild-packages"/' "$catalog_fixture/root/repro.lock"
catalog_unpinned_rc=0
catalog_unpinned_out="$(bash "$CATALOG_CHECK" "$catalog_fixture/root/repro.lock" "$catalog_fixture" 2>&1)" || catalog_unpinned_rc=$?
rm -rf "$catalog_fixture"
catalog_defects=()
[ "$catalog_unpinned_rc" -eq 1 ] || catalog_defects+=("it accepts a sibling that uses a catalog package with no catalog pin (rc $catalog_unpinned_rc)")
grep -q "gamma uses the catalog package 'patchelf'" <<<"$catalog_unpinned_out" || catalog_defects+=("its refusal of an unpinned catalog user does not name it")
[ "$catalog_agree_rc" -eq 0 ] || catalog_defects+=("it rejects siblings that pin the root's catalog (rc $catalog_agree_rc)")
[ "$catalog_disagree_rc" -eq 1 ] || catalog_defects+=("it accepts a sibling that pins another catalog (rc $catalog_disagree_rc)")
grep -q 'beta pins reprobuild-packages' <<<"$catalog_disagree_out" || catalog_defects+=("its refusal does not name the sibling")
grep -q 'bash ci/repro-lock-catalog-agreement.sh repro.lock \.\.' "$LOCK_ACTION" || catalog_defects+=("provision-repro-lock-siblings does not run it on the cloned siblings")
if [ "${#catalog_defects[@]}" -eq 0 ]; then
	ok "every cloned sibling's lock must pin repro.lock's package catalog, and the check tells the cases apart"
else
	fail "every cloned sibling's lock must pin repro.lock's package catalog, and the check tells the cases apart" "${catalog_defects[@]}"
fi

# The scenario jobs upload a failed run with DemoVideoScript's own action. It
# is the runner's code, so it is pinned to the runner's revision.
dvs_pin="$(lock_rev "$TEST_LOCK" DemoVideoScript)"
upload_defects=()
while IFS= read -r hit; do
	sha="${hit##*@}"
	sha="${sha%%[[:space:]]*}"
	if [ "$sha" != "$dvs_pin" ]; then
		upload_defects+=("${hit%%:*}: upload-failed-runs@$sha, the test lock pins DemoVideoScript at $dvs_pin")
	fi
done < <(grep -n -H -o 'metacraft-labs/DemoVideoScript/.github/actions/upload-failed-runs@[0-9a-f]*' "$WORKFLOW_DIR"/*.yml 2>/dev/null |
	sed 's|^\([^:]*/\)\{0,1\}||')
if [ "${#upload_defects[@]}" -eq 0 ]; then
	ok "upload-failed-runs is pinned to the DemoVideoScript revision the test lock pins"
else
	fail "upload-failed-runs is pinned to the DemoVideoScript revision the test lock pins" "${upload_defects[@]}"
fi

# The selector runs in a raw `shell: bash` step BEFORE the dev shell, and on
# the nix-darwin runners that PATH has no `grep` and no `sed`: written with
# them, the selector died there with `grep: command not found` (codetracer-pm
# issues/2026-10-22-provision-repro-lock-siblings-runs-grep-and-sed-outside-
# the-dev-shell-on-darwin.md). So it is run again with a PATH holding nothing
# but bash -- once with the lock named, once relying on its default lock path
# -- and must give the same answer. A run on a host that does have grep and
# sed cannot see this; the stripped PATH is what makes the check portable.
minimal_path_dir="$(mktemp -d)"
ln -s "$(command -v bash)" "$minimal_path_dir/bash"
minimal_path_named="$(env -i PATH="$minimal_path_dir" "$minimal_path_dir/bash" \
	"$BUILD_INPUT_SELECTOR" "$REPRO_LOCK" 2>&1)" || true
minimal_path_default="$(env -i PATH="$minimal_path_dir" "$minimal_path_dir/bash" \
	"$BUILD_INPUT_SELECTOR" 2>&1)" || true
rm -rf "$minimal_path_dir"
if [ "$minimal_path_named" = "$actual_build_inputs" ] &&
	[ "$minimal_path_default" = "$actual_build_inputs" ]; then
	ok "the build-input selector needs nothing but bash (the pre-dev-shell PATH on nix-darwin)"
else
	fail "the build-input selector needs nothing but bash (the pre-dev-shell PATH on nix-darwin)" \
		"provision-repro-lock-siblings runs it before 'nix develop', where a" \
		"nix-darwin runner has no grep or sed" \
		"expected:              $actual_build_inputs" \
		"actual (lock named):   $minimal_path_named" \
		"actual (default lock): $minimal_path_default"
fi

# The clone is given a LIVE credential, through the channel reprobuild reads.
# `codetracer-image-diff` is a private build input (`repro.nim` uses it), and
# most of the others are private too. The action used to clone with no
# credential at all, on the premise that every build input was public. That
# premise was "checked" by reading each input's `visibility` from repro.lock
# -- a field that names a reprobuild configuration TIER, not whether GitHub
# serves the repository anonymously, and that says "public" for every entry in
# this lock, private ones included. The clone then died in CI with
#
#   fatal: could not read Username for 'https://github.com': terminal prompts disabled
#
# (codetracer-pm issues/2026-10-31-provision-repro-lock-siblings-cannot-clone-
# private-codetracer-image-diff.md).
#
# Passing a token is not enough on its own. The job already carries one as
# numbered git configuration (`GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_n` /
# `GIT_CONFIG_VALUE_n`, exported by setup-nix's configure-git-auth.sh), and
# plain `git ls-remote` authenticates with it -- but reprobuild scrubs numbered
# configuration from the git commands it runs for another repository, so
# `repro develop` never sees it. The supported channel is a GIT_CONFIG_GLOBAL
# file, which `metacraft-github-actions/git-auth` writes privately for the
# duration of one command. Copying that logic into this repo is forbidden by
# policy.
#
# And the token has to still be VALID when git uses it. An installation token
# expires one hour after it is minted, whoever holds it. The first fix handed
# the action the job's `ci_token`, minted in the job's first step, and ran the
# clone as `nix develop .#ci --command repro develop ...` inside git-auth -- so
# the dev shell was realised INSIDE the credential window, after the token had
# already been ticking for the whole of the job's setup. The release build
# realises that shell cold: in job 126333283602 the token was minted at
# 01:53:17, the shell was realised from 01:57 to 02:43, and at 02:56:33 the
# step reported that every clone and every reset of an already-cloned sibling
# had failed with the same "could not read Username" line, because GitHub
# answers an expired token as if there were none. lint-nim in the same run minted at 02:14, finished at 02:34, and
# passed (codetracer-pm issues/2026-11-04-release-build-provisioning-clones-
# private-siblings-without-a-credential.md). Nothing about the step said that
# the credential had expired rather than been missing.
#
# So the action now orders its own steps so that no unbounded work can sit
# between a token's mint and its use, whatever the caller did before:
#
#   * it declares required `app-id` and `private-key` inputs and NO `gh-token`
#     input -- a caller-minted token is exactly the stale one;
#   * it realises the `.#ci` dev shell in a step of its own, BEFORE it mints;
#   * it mints the clone's token with `actions/create-github-app-token`,
#     org-scoped, and the very next step is the clone;
#   * that clone runs inside a step that `uses:` the shared git-auth action,
#     pinned to a 40-hex commit (it handles the job's credential, so it
#     changes only by an edit here), given the action's own mint output, and
#     nothing in the action falls back to numbered git configuration;
#   * every workflow step that uses the action passes the per-repo App
#     secrets and no `gh-token:`.
#
# The ordering check fails on the tree that had the defect: the action took
# `gh-token`, minted nothing, and realised the shell inside git-auth.
readonly GIT_AUTH_ACTION_RE='^metacraft-labs/metacraft-github-actions/git-auth@[0-9a-f]{40}$'
# shellcheck disable=SC2016
readonly LOCK_ACTION_APP_ID='app-id: ${{ inputs.app-id }}'
# shellcheck disable=SC2016
readonly LOCK_ACTION_PRIVATE_KEY='private-key: ${{ inputs.private-key }}'
# shellcheck disable=SC2016
readonly CALLER_APP_ID='app-id: ${{ secrets.CI_TOKEN_PROVIDER_APP_ID }}'
# shellcheck disable=SC2016
readonly CALLER_PRIVATE_KEY='private-key: ${{ secrets.CI_TOKEN_PROVIDER_PRIVATE_KEY }}'

lock_action_input_defects=()
if [ -f "$LOCK_ACTION" ]; then
	# The inputs block: from `inputs:` to the next top-level key.
	lock_action_inputs="$(sed -n '/^inputs:/,/^[a-z]/p' "$LOCK_ACTION")"
	for input in app-id private-key; do
		decl="$(sed -n "/^  $input:/,/^  [a-z]/p" <<<"$lock_action_inputs")"
		if [ -z "$decl" ]; then
			lock_action_input_defects+=("it declares no '$input' input")
		elif ! grep -Eq '^    required: true[[:space:]]*$' <<<"$decl"; then
			lock_action_input_defects+=("its '$input' input is not 'required: true'")
		fi
	done
	if grep -Eq '^  gh-token:' <<<"$lock_action_inputs"; then
		lock_action_input_defects+=("it declares a 'gh-token' input: a token the caller minted has already aged by the caller's setup, and expires inside a cold dev-shell realisation")
	fi
else
	lock_action_input_defects+=("$LOCK_ACTION does not exist")
fi
if [ "${#lock_action_input_defects[@]}" -eq 0 ]; then
	ok "provision-repro-lock-siblings takes required app-id and private-key inputs and no gh-token"
else
	fail "provision-repro-lock-siblings takes required app-id and private-key inputs and no gh-token" \
		"the action mints the clone's token itself, after the dev shell is" \
		"realised, so a caller can only hand it the App's credentials" \
		"${lock_action_input_defects[@]}"
fi

# Walk the runs: section step by step. A step starts at `    - ` (four spaces,
# the composite's step indent); its keys sit at six and its `with:` keys at
# eight. Each step is recorded by its position, so the ordering checks below
# compare indices rather than line numbers.
declare -a ls_uses=() ls_id=() ls_token=() ls_develops=() ls_realises=() ls_mint_ok=()
numbered_lines=()
if [ -f "$LOCK_ACTION" ]; then
	in_runs=0
	lock_line_no=0
	cur=-1
	mint_app_id=0
	mint_private_key=0
	mint_owner=0
	close_lock_step() {
		[ "$cur" -ge 0 ] || return 0
		if [ "$mint_app_id" = 1 ] && [ "$mint_private_key" = 1 ] && [ "$mint_owner" = 1 ]; then
			ls_mint_ok[cur]=1
		fi
	}
	while IFS= read -r line || [ -n "$line" ]; do
		lock_line_no=$((lock_line_no + 1))
		case "$line" in
		'runs:'*) in_runs=1 ;;
		esac
		[ "$in_runs" -eq 1 ] || continue
		stripped="${line#"${line%%[![:space:]]*}"}"
		case "$stripped" in
		'#'*) continue ;;
		esac
		case "$line" in
		'    - '*)
			close_lock_step
			cur=$((cur + 1))
			ls_uses[cur]=""
			ls_id[cur]=""
			ls_token[cur]=""
			ls_develops[cur]=0
			ls_realises[cur]=0
			ls_mint_ok[cur]=0
			mint_app_id=0
			mint_private_key=0
			mint_owner=0
			;;
		esac
		[ "$cur" -ge 0 ] || continue
		stripped="${stripped#- }"
		case "$stripped" in
		'uses: '*) ls_uses[cur]="${stripped#uses: }" ;;
		'id: '*) ls_id[cur]="${stripped#id: }" ;;
		'gh-token: '*) ls_token[cur]="${stripped#gh-token: }" ;;
		"$LOCK_ACTION_APP_ID") mint_app_id=1 ;;
		"$LOCK_ACTION_PRIVATE_KEY") mint_private_key=1 ;;
		'owner: metacraft-labs') mint_owner=1 ;;
		esac
		case "$stripped" in
		*'repro develop --all'*) ls_develops[cur]=$((ls_develops[cur] + 1)) ;;
		esac
		case "$stripped" in
		*'nix develop .#ci --command true'* | *'nix develop .#ci --profile '*' --command true'*) ls_realises[cur]=1 ;;
		esac
		case "$stripped" in
		*GIT_CONFIG_COUNT* | *GIT_CONFIG_KEY_* | *GIT_CONFIG_VALUE_* | *GIT_CONFIG_PARAMETERS*)
			numbered_lines+=("line $lock_line_no: $stripped")
			;;
		esac
	done <"$LOCK_ACTION"
	close_lock_step
	unset -f close_lock_step
fi
lock_step_count=${#ls_uses[@]}

# Locate the three steps the ordering is about. More than one of any of them
# is itself a defect: a second clone or mint would have its own window.
develop_step=-1 mint_step=-1 realise_step=-1
lock_order_defects=()
for ((i = 0; i < lock_step_count; i++)); do
	if [ "${ls_develops[i]}" -gt 0 ]; then
		[ "$develop_step" -lt 0 ] || lock_order_defects+=("more than one step runs 'repro develop --all' (steps $develop_step and $i)")
		develop_step=$i
	fi
	case "${ls_uses[i]}" in
	actions/create-github-app-token@*)
		[ "$mint_step" -lt 0 ] || lock_order_defects+=("more than one step mints a token (steps $mint_step and $i)")
		mint_step=$i
		;;
	esac
	if [ "${ls_realises[i]}" = 1 ] && [ -z "${ls_uses[i]}" ]; then
		[ "$realise_step" -ge 0 ] || realise_step=$i
	fi
done

# The clone's credential: the shared git-auth action, given the action's own
# mint output.
lock_action_auth_defects=()
# Every distinct git-auth pin a `repro develop` step uses; checked below
# against the metacraft-github-actions sibling.
git_auth_pins=()
if [ ! -f "$LOCK_ACTION" ]; then
	lock_action_auth_defects+=("$LOCK_ACTION does not exist")
elif [ "$develop_step" -lt 0 ]; then
	lock_action_auth_defects+=("no step runs 'repro develop --all', so there is nothing to check")
else
	develop_uses="${ls_uses[develop_step]}"
	if [ -z "$develop_uses" ]; then
		lock_action_auth_defects+=("'repro develop' runs in a raw run: step, not through metacraft-github-actions/git-auth")
	elif ! [[ $develop_uses =~ $GIT_AUTH_ACTION_RE ]]; then
		lock_action_auth_defects+=("'repro develop' runs through '$develop_uses', not metacraft-github-actions/git-auth pinned to a 40-hex commit")
	else
		git_auth_pins+=("${develop_uses##*@}")
	fi
	if [ "$mint_step" -lt 0 ]; then
		lock_action_auth_defects+=("the action mints no token of its own; the clone is given '${ls_token[develop_step]:-nothing}'")
	elif [ -z "${ls_id[mint_step]}" ]; then
		lock_action_auth_defects+=("the action's mint step has no id:, so nothing can name its token")
	else
		# shellcheck disable=SC2016
		expected_token='${{ steps.'"${ls_id[mint_step]}"'.outputs.token }}'
		[ "${ls_token[develop_step]}" = "$expected_token" ] ||
			lock_action_auth_defects+=("the git-auth step is given 'gh-token: ${ls_token[develop_step]:-<none>}', not the action's own '$expected_token'")
		[ "${ls_mint_ok[mint_step]}" = 1 ] ||
			lock_action_auth_defects+=("the mint step does not mint from '$LOCK_ACTION_APP_ID' and '$LOCK_ACTION_PRIVATE_KEY' with 'owner: metacraft-labs'")
	fi
fi
for numbered in ${numbered_lines[@]+"${numbered_lines[@]}"}; do
	lock_action_auth_defects+=("it handles numbered git configuration, which reprobuild scrubs: $numbered")
done
lock_action_auth_defects+=(${lock_order_defects[@]+"${lock_order_defects[@]}"})
if [ "${#lock_action_auth_defects[@]}" -eq 0 ]; then
	ok "its clone runs through the pinned metacraft-github-actions/git-auth action with the token it mints"
else
	fail "its clone runs through the pinned metacraft-github-actions/git-auth action with the token it mints" \
		"reprobuild scrubs the job's numbered GIT_CONFIG_* credential, so a" \
		"private build input clones only when the token reaches it as a private" \
		"GIT_CONFIG_GLOBAL file, which the shared git-auth action writes" \
		"${lock_action_auth_defects[@]}"
fi

# The token is still valid when git uses it: the dev shell is realised before
# the mint, and the clone is the very next step after it. `nix develop .#ci`
# inside the clone step then only enters a shell that already exists.
lock_window_defects=()
if [ "$develop_step" -lt 0 ] || [ "$mint_step" -lt 0 ]; then
	lock_window_defects+=("the action has no mint step and clone step to order (mint: step $mint_step, clone: step $develop_step); a token handed in by the caller was minted before this action realised the dev shell, and a cold realisation outlives its one-hour lifetime")
else
	if [ "$realise_step" -lt 0 ]; then
		lock_window_defects+=("no raw step realises the dev shell ('nix develop .#ci --command true'), so the clone step realises it inside the credential window")
	elif [ "$realise_step" -gt "$mint_step" ]; then
		lock_window_defects+=("the dev shell is realised in step $realise_step, after the mint in step $mint_step")
	fi
	[ "$develop_step" -eq $((mint_step + 1)) ] ||
		lock_window_defects+=("the clone (step $develop_step) does not immediately follow the mint (step $mint_step)")
fi
if [ "${#lock_window_defects[@]}" -eq 0 ]; then
	ok "nothing that can outlast the token runs between its mint and the clone"
else
	fail "nothing that can outlast the token runs between its mint and the clone" \
		"an installation token expires an hour after its mint, and GitHub answers" \
		"an expired one exactly as it answers none: 'could not read Username'" \
		"${lock_window_defects[@]}"
fi

# A 40-hex pin is only well formed. A placeholder (the implementation of this
# check pinned 0000...0000 until the shared action was committed) or a commit
# that was never pushed passes the shape check above and fails every job at
# "Set up job", when GitHub cannot download the action. So each pin must name a
# commit of the metacraft-github-actions sibling -- a member of repro.lock's
# develop set, checked out beside this repo -- that carries
# git-auth/action.yml. A missing sibling or an unfetched commit is a failure
# with its remedy, not a skip: the check is no weaker for being offline.
#
# The sibling is a workspace checkout when this runs inside a repro workspace,
# and CI's guard job clones it beside the checkout. A standalone clone has
# neither, so the check provisions a throwaway clone of the public repo for
# itself (CODETRACER_GIT_AUTH_SIBLING names a different checkout). Only when
# that clone cannot be made does the check fail, naming the prerequisite.
GIT_AUTH_SIBLING="${CODETRACER_GIT_AUTH_SIBLING:-$REPO_ROOT/../metacraft-github-actions}"
GIT_AUTH_REMOTE="https://github.com/metacraft-labs/metacraft-github-actions"
git_auth_pin_defects=()
if [ "${#git_auth_pins[@]}" -gt 0 ] && ! git -C "$GIT_AUTH_SIBLING" rev-parse --git-dir >/dev/null 2>&1; then
	git_auth_tmp="$(mktemp -d)"
	if git clone --quiet --filter=blob:none --no-checkout "$GIT_AUTH_REMOTE" "$git_auth_tmp/metacraft-github-actions" >/dev/null 2>&1; then
		GIT_AUTH_SIBLING="$git_auth_tmp/metacraft-github-actions"
	else
		git_auth_pin_defects+=("prerequisite missing: no metacraft-github-actions checkout at $GIT_AUTH_SIBLING, and cloning $GIT_AUTH_REMOTE failed; check it out beside codetracer, or point CODETRACER_GIT_AUTH_SIBLING at a checkout")
	fi
fi
if [ "${#git_auth_pin_defects[@]}" -gt 0 ]; then
	:
elif [ "${#git_auth_pins[@]}" -eq 0 ]; then
	git_auth_pin_defects+=("no git-auth pin was found to check (see the assertion above)")
else
	for pin in "${git_auth_pins[@]}"; do
		if ! git -C "$GIT_AUTH_SIBLING" cat-file -e "${pin}^{commit}" 2>/dev/null; then
			git_auth_pin_defects+=("git-auth@$pin is not a commit of $GIT_AUTH_SIBLING (if it was pushed, run: git -C $GIT_AUTH_SIBLING fetch origin)")
		elif ! git -C "$GIT_AUTH_SIBLING" cat-file -e "${pin}:git-auth/action.yml" 2>/dev/null; then
			git_auth_pin_defects+=("git-auth@$pin has no git-auth/action.yml")
		fi
	done
fi
[ -n "${git_auth_tmp:-}" ] && rm -rf "$git_auth_tmp"
if [ "${#git_auth_pin_defects[@]}" -eq 0 ]; then
	ok "its git-auth pin names a metacraft-github-actions commit that carries the action"
else
	fail "its git-auth pin names a metacraft-github-actions commit that carries the action" \
		"GitHub downloads the pinned action before the job's first step, so a pin" \
		"to a commit that does not exist fails every job that uses this action" \
		"${git_auth_pin_defects[@]}"
fi

# Every caller hands the action the App's credentials and no token of its own.
# Callers are workflow steps with `uses:
# ./.github/actions/provision-repro-lock-siblings`; the step ends at the next
# line indented no deeper than its `- ` marker.
lock_callers=0
lock_bad_callers=()
record_lock_caller() {
	[ "$caller_app_id" -eq 1 ] && [ "$caller_private_key" -eq 1 ] ||
		lock_bad_callers+=("$wf_name:$caller_line: does not pass '$CALLER_APP_ID' and '$CALLER_PRIVATE_KEY'")
	[ "$caller_gh_token" -eq 0 ] ||
		lock_bad_callers+=("$wf_name:$caller_line: still passes 'gh-token:', which the action no longer takes")
}
for wf in "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml; do
	[ -f "$wf" ] || continue
	wf_name="${wf##*/}"
	in_caller=0
	caller_line=0
	caller_app_id=0
	caller_private_key=0
	caller_gh_token=0
	caller_indent=0
	line_no=0
	while IFS= read -r line || [ -n "$line" ]; do
		line_no=$((line_no + 1))
		stripped="${line#"${line%%[![:space:]]*}"}"
		indent=$((${#line} - ${#stripped}))
		if [ "$in_caller" -eq 1 ] && [ -n "$stripped" ]; then
			case "$stripped" in
			'#'*) ;;
			*)
				if [ "$indent" -lt "$caller_indent" ] ||
					{ [ "$indent" -eq $((caller_indent - 2)) ] && [ "${stripped:0:2}" = '- ' ]; }; then
					record_lock_caller
					in_caller=0
				fi
				;;
			esac
		fi
		if [ "$in_caller" -eq 1 ]; then
			case "$stripped" in
			"$CALLER_APP_ID") caller_app_id=1 ;;
			"$CALLER_PRIVATE_KEY") caller_private_key=1 ;;
			'gh-token:'*) caller_gh_token=1 ;;
			esac
		fi
		case "$stripped" in
		'uses: ./.github/actions/provision-repro-lock-siblings' | '- uses: ./.github/actions/provision-repro-lock-siblings')
			lock_callers=$((lock_callers + 1))
			in_caller=1
			caller_line="$line_no"
			caller_app_id=0
			caller_private_key=0
			caller_gh_token=0
			# The step's keys sit where `uses:` does, even when it is the
			# step's first key and carries the `- ` marker.
			caller_indent="$indent"
			[ "${stripped:0:2}" = '- ' ] && caller_indent=$((indent + 2))
			;;
		esac
	done <"$wf"
	[ "$in_caller" -eq 0 ] || record_lock_caller
done
unset -f record_lock_caller
if [ "$lock_callers" -gt 0 ] && [ "${#lock_bad_callers[@]}" -eq 0 ]; then
	ok "all $lock_callers callers of provision-repro-lock-siblings pass the App's credentials"
else
	fail "every caller of provision-repro-lock-siblings passes the App's credentials" \
		"a composite action cannot read secrets, so the App id and key reach the" \
		"action's own mint step only as inputs; an empty one fails that mint" \
		"found $lock_callers caller(s)" \
		"${lock_bad_callers[@]+"${lock_bad_callers[@]}"}"
fi

# ... and each of them at an IMMUTABLE revision. A branch name here would be
# the same defect the ceiling above exists to prevent, arriving through the
# other lock.
unpinned_deps=()
if [ -f "$REPRO_LOCK" ]; then
	IFS=',' read -r -a _declared <<<"$lock_develop_set"
	for dep in "${_declared[@]}"; do
		rev="$(grep -o "name = \"$dep\"[^}]*revision = \"[^\"]*\"" "$REPRO_LOCK" |
			sed 's/.*revision = "//; s/"$//' | head -n 1)"
		if [ "${#rev}" -ne 40 ] || [ -n "${rev//[0-9a-f]/}" ]; then
			unpinned_deps+=("$dep -> '${rev:-<no revision record>}' is not a 40-hex commit SHA")
		fi
	done
fi

if [ "${#unpinned_deps[@]}" -eq 0 ]; then
	ok "every declared dependency carries a 40-hex commit SHA"
else
	fail "every declared dependency carries a 40-hex commit SHA" \
		"a dependency without an exact revision makes the build depend on when" \
		"it ran, which is the defect this whole file exists to prevent" \
		"${unpinned_deps[@]}"
fi

# ---------------------------------------------------------------------------
# 1c. Branch-tip entries elsewhere are capped, and the cap only goes down.
#
# The other `siblings:` blocks in this repo still carry `=dev` overrides from
# the lock outage. Converting them is separate work; what must not happen
# meanwhile is a NEW one appearing, which is what this ceiling prevents.
# ---------------------------------------------------------------------------
if [ "${#branch_tip_entries[@]}" -le "$BRANCH_TIP_CEILING" ]; then
	ok "branch-tip sibling entries are within the ceiling (${#branch_tip_entries[@]} <= $BRANCH_TIP_CEILING)"
else
	fail "branch-tip sibling entries are within the ceiling" \
		"${#branch_tip_entries[@]} entries pin a mutable branch tip; the ceiling is" \
		"$BRANCH_TIP_CEILING. A sibling revision must come from the workspace lock or be" \
		"an explicit 40-hex commit SHA. This ceiling is lowered as blocks are" \
		"converted and is never raised." \
		"${branch_tip_entries[@]}"
fi

# ---------------------------------------------------------------------------
# 1d. A SHA pin for a flake INPUT must be the revision flake.lock locks.
#
# Converting `name=dev` to `name=<sha>` buys reproducibility and nothing else.
# It does NOT by itself make the cloned sibling the same revision the Nix lane
# and reprobuild compile against -- that is still one pin spelled in two
# places, and the second spelling can now be wrong in a way `=dev` could not
# be: silently, forever, rather than only on the days the branch had moved.
#
# That is not hypothetical. The twenty-three trace-format entries converted
# above were `=dev` while `flake.nix` declared the same two inputs at
# `/agents`, and when the two spellings diverged on 2026-10-02 every job that
# clones the sibling and runs cargo against `src/db-backend` stopped
# compiling, with no gate in this file noticing: the `=dev` entries were
# counted against a ceiling, which says nothing about WHICH commit `dev` is.
#
# So the agreement is asserted, per entry and counted, for every sibling that
# is a root flake input and is named by SHA in a `siblings:` block. It was
# first scoped to the two trace-format halves, and the other inputs drifted
# with nothing noticing: on 2026-10-24 six workflow lines named
# codetracer-native-backend at a859cfb9 while flake.lock locked 742cc6d0,
# and io-mon's entries trailed its flake.lock rev the same way.
# The isonim family joined on 2026-10-27: deploy-web-codetracer.yml names its
# nine members by SHA so the web renderer compiles against them, and they
# trailed flake.lock twice in a week -- the first time the cloud deploy of
# dev 05f2247b46 stopped at "renderer: did not build" (`firstElementChild`
# missing from isonim 45673bba), and three days later four of the nine had
# moved again with nothing here noticing.
# `reprobuild-packages` stays out: deploy-web-codetracer.yml pins a catalog
# revision its flake input does not track yet, deliberately and documented.
# nim-stackable-hooks stays out until its two flake.lock nodes agree (see the
# ceiling note above); its entries are `=dev` anyway.
# ---------------------------------------------------------------------------
readonly FLAKE_PINNED_SIBLINGS='codetracer-trace-format codetracer-trace-format-nim codetracer-native-recorder codetracer-native-backend codetracer-visual-replay io-mon isonim isonim-tui isonim-gpui nim-everywhere nim-termctl nim-pty nim-acp nim-agent-harbor nim-agents reprobuild'

# jq, not python3: jq is on every runner this suite is meant to run on -- the
# stock ubuntu-latest of `ci-contract-suites` and the self-hosted NixOS and
# nix-darwin runners alike -- while python3 is absent from the persistent NixOS
# runners and from a bare NixOS host. Where python3 was missing this printed
# nothing, and the vacuity arm below then reported "found 0 entries", which
# reads as a workflow defect and is a missing interpreter.
#
# An input declared with `follows` is locked as a PATH of input names walked
# from the root (`["reprobuild", "runquota-src"]`), not as a node key, so it is
# walked one input at a time as Nix resolves it -- reading its first element as
# the node would answer with another repository's rev. Same rule as
# `flake_lock_revs` in ci/test/launcher-recorder-e2e-workflow-test.sh.
# https://nix.dev/manual/nix/latest/command-ref/new-cli/nix3-flake.html#lock-files
flake_rev() { # $1 = root input name -> its locked.rev, or '' when absent
	jq -r --arg name "$1" '
		. as $lock
		| def node_of($ref):
			if ($ref | type) == "string" then $ref
			else reduce $ref[] as $input ($lock.root;
				node_of($lock.nodes[.].inputs[$input]))
			end;
		($lock.nodes[$lock.root].inputs[$name] // empty) as $ref
		| $lock.nodes[node_of($ref)].locked.rev // empty
	' "$REPO_ROOT/flake.lock" 2>/dev/null
}

flake_pin_mismatches=()
flake_pin_checked=0
for name in $FLAKE_PINNED_SIBLINGS; do
	want="$(flake_rev "$name")"
	if [ "${#want}" -ne 40 ] || [ -n "${want//[0-9a-f]/}" ]; then
		flake_pin_mismatches+=("flake.lock has no 40-hex locked.rev for root input '$name' ('${want:-<none>}'); this is a parse/declaration failure, not a statement about any workflow")
		continue
	fi
	for rec in "${sha_entries[@]}"; do
		entry="${rec##*:}"
		[ "${entry%%=*}" = "$name" ] || continue
		flake_pin_checked=$((flake_pin_checked + 1))
		[ "${entry#*=}" = "$want" ] || flake_pin_mismatches+=("${rec%:*}: ${entry} but flake.lock locks $name at $want")
	done
done

# The vacuity arm. Nothing above forces these two to appear in any
# `siblings:` block, so "no mismatches" is also what a run that found no
# entries at all reports. A conversion that is silently reverted to `=dev`
# must redden here, not go quiet: every block that provisions them is one
# that compiles src/db-backend against them.
if [ "$flake_pin_checked" -eq 0 ]; then
	fail "the flake-pinned siblings are named by SHA somewhere" \
		"found 0 '<name>=<40-hex>' entries for: $FLAKE_PINNED_SIBLINGS" \
		"so the agreement assertion below quantifies over an empty set. If these" \
		"blocks went back to a branch ref, the branch-tip ceiling is the only thing" \
		"still looking at them, and it does not check WHICH commit the branch is."
elif [ "${#flake_pin_mismatches[@]}" -eq 0 ]; then
	ok "all $flake_pin_checked SHA-pinned flake-input sibling entries equal their flake.lock locked.rev"
else
	fail "every SHA-pinned flake-input sibling equals its flake.lock locked.rev" \
		"the sibling checkout and the Nix lane would compile different revisions;" \
		"'bash scripts/sibling-pins.sh --all' prints the lines for every sibling it declares" \
		"${flake_pin_mismatches[@]}"
fi

# ---------------------------------------------------------------------------
# 1e. A private sibling's revision has ONE home, and every copy equals it.
#
# repro.lock is public, so it cannot pin the siblings in UNLOCKED_SIBLINGS
# (bbf7dbed4a6), and 1c makes a lane name each of them with an explicit
# `=<rev>`. That moved the revision out of one lock and into hand-kept copies:
# at d11479e6b8 it was written in flake.lock, in ci/toolchain.pin's
# PRIVATE_SIBLING_* lines and in eighteen workflow literals, and the copies
# agreed only because a chore (c79359560f) had moved them together by hand. 1c
# checks that an entry carries a revision, not which one. The next move
# proved it: 932a8b8aaf re-pinned codetracer-native-backend in flake.lock at
# 9fcfc0a and the workflows kept cloning 1c8efb8, five literal lines and two
# `|| '<sha>'` fallbacks (codetracer-pm issue
# 2026-11-22-private-sibling-revisions-are-hand-kept-copies-nothing-checks-agree).
#
# So each such sibling has exactly one home:
#
#   * a root flake input        -> flake.lock's locked.rev, and ci/toolchain.pin
#     (native-backend,             must not carry a second copy of it (1d says
#      native-recorder,            the same of the `siblings:` SHA entries of
#      visual-replay)              FLAKE_PINNED_SIBLINGS);
#   * anything else             -> ci/toolchain.pin's PRIVATE_SIBLING_<NAME>
#                                  (upper case, '-' -> '_'), which every
#                                  `<name>=<40-hex>` entry, literal or
#                                  `|| '<sha>'` fallback, must equal.
#
# A branch ref (`=dev`) for a sibling with a home is a copy that follows a
# different fact and fails too, and a PRIVATE_SIBLING_* line that names no
# UNLOCKED_SIBLINGS member is a home with no tenant. A workflow that reads the
# pin through an expression (tui-tests.yml's `steps.private_pins` output)
# carries no copy, so there is nothing to compare.
#
# private_sibling_pin_mismatches is a function so the falsifying controls
# below can run it over a mutated copy of the real entries.
# ---------------------------------------------------------------------------
readonly TOOLCHAIN_PIN="$REPO_ROOT/ci/toolchain.pin"

private_pin_key() { # $1 = sibling name -> its ci/toolchain.pin key
	local key="${1//-/_}"
	printf 'PRIVATE_SIBLING_%s\n' "${key^^}"
}

# $1 = a ci/toolchain.pin; $2.. = `<file>:<line>:<name>=<ref>` records.
# Prints one line per disagreement; prints nothing when every copy agrees.
private_sibling_pin_mismatches() {
	local pin_file="$1" rec entry name ref key want where
	shift
	if [ ! -r "$pin_file" ]; then
		printf 'cannot read %s\n' "$pin_file"
		return 0
	fi
	local -A pin_rev=()
	while IFS='=' read -r key want; do
		# Two lines for one key are two homes: the workflows that read the
		# pin with `sed -n` get both, and zgui.yml's loop keeps the last.
		[ -z "${pin_rev[$key]+set}" ] ||
			printf 'ci/toolchain.pin: %s appears more than once (%s and %s)\n' "$key" "${pin_rev[$key]}" "$want"
		pin_rev[$key]="$want"
	done < <(grep -E '^PRIVATE_SIBLING_[A-Z0-9_]+=' "$pin_file")

	local -A is_flake_home=()
	for name in "${!UNLOCKED_SIBLINGS[@]}"; do
		key="$(private_pin_key "$name")"
		want="$(flake_rev "$name")"
		if [ -n "$want" ]; then
			is_flake_home[$name]="$want"
			[ -z "${pin_rev[$key]+set}" ] ||
				printf 'ci/toolchain.pin: %s=%s is a second copy of a revision flake.lock locks (%s); delete the line\n' "$key" "${pin_rev[$key]}" "$name"
		fi
	done
	for key in "${!pin_rev[@]}"; do
		want="${pin_rev[$key]}"
		if [ "${#want}" -ne 40 ] || [ -n "${want//[0-9a-f]/}" ]; then
			printf 'ci/toolchain.pin: %s=%s is not a 40-hex commit\n' "$key" "$want"
		fi
		local tenant=""
		for name in "${!UNLOCKED_SIBLINGS[@]}"; do
			[ "$(private_pin_key "$name")" = "$key" ] && tenant="$name"
		done
		[ -n "$tenant" ] ||
			printf 'ci/toolchain.pin: %s names no sibling in UNLOCKED_SIBLINGS\n' "$key"
	done

	for rec in "$@"; do
		entry="${rec#*:}"
		entry="${entry#*:}"
		name="${entry%%=*}"
		ref="${entry#*=}"
		[ -n "${UNLOCKED_SIBLINGS[$name]:-}" ] || continue
		where="${rec%%:*}:$(cut -d: -f2 <<<"$rec")"
		want="${is_flake_home[$name]:-}"
		if [ -n "$want" ]; then
			# 1d says the same of a `siblings:` SHA entry; this also covers
			# branch refs and the `extra-siblings:` blocks 1d does not scan.
			[ "$ref" = "$want" ] ||
				printf '%s: %s, but flake.lock locks %s at %s\n' "$where" "$entry" "$name" "$want"
			continue
		fi
		key="$(private_pin_key "$name")"
		want="${pin_rev[$key]:-}"
		if [ -z "$want" ]; then
			printf '%s: %s, but ci/toolchain.pin has no %s line to be its home\n' "$where" "$entry" "$key"
		elif [ "$ref" != "$want" ]; then
			printf '%s: %s, but ci/toolchain.pin has %s=%s\n' "$where" "$entry" "$key" "$want"
		fi
	done
}

# The `extra-siblings:` blocks feed setup-db-backend-siblings' `siblings:`
# input (1c), but the scanner above reads only `siblings:` blocks, so collect
# their pinned entries here: codetracer.yml's test-ui-tests job names
# codetracer-native-test-programs in one.
extra_sibling_records=()
while IFS= read -r rec; do
	[ -n "$rec" ] || continue
	entry="${rec#*:}"
	entry="${entry#*:}"
	ref="${entry#*=}"
	case "$(classify_ref "$ref")" in
	sha | branch) extra_sibling_records+=("$rec") ;;
	expr)
		fallback="$(expr_fallback "$ref")"
		case "$(classify_ref "$fallback")" in
		sha | branch) extra_sibling_records+=("${rec%%=*}=$fallback") ;;
		esac
		;;
	esac
done < <(
	for wf in "${SIBLING_SOURCE_FILES[@]}"; do
		case "$wf" in
		"$ACTIONS_DIR"/*) wf_name="${wf#"$ACTIONS_DIR"/}" ;;
		*) wf_name="${wf##*/}" ;;
		esac
		awk -v wf="$wf_name" '
			/^[[:space:]]*extra-siblings: *\|/ { match($0, /^[[:space:]]*/); key = RLENGTH; inb = 1; next }
			inb {
				if ($0 ~ /^[[:space:]]*$/) { inb = 0; next }
				match($0, /^[[:space:]]*/); if (RLENGTH <= key) { inb = 0; next }
				line = $0; sub(/#.*/, "", line); gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
				if (line ~ /=./) print wf ":" NR ":" line
			}' "$wf"
	done
)
private_pin_records=("${sha_entries[@]}" "${branch_entries[@]}" "${extra_sibling_records[@]}")
private_pin_checked=0
for rec in "${private_pin_records[@]}"; do
	entry="${rec#*:}"
	entry="${entry#*:}"
	name="${entry%%=*}"
	[ -n "${UNLOCKED_SIBLINGS[$name]:-}" ] && [ -z "$(flake_rev "$name")" ] &&
		private_pin_checked=$((private_pin_checked + 1))
done
mapfile -t private_pin_mismatch_lines < <(private_sibling_pin_mismatches "$TOOLCHAIN_PIN" "${private_pin_records[@]}")

# Falsifying controls. Take the location of a real workflow entry of a
# ci/toolchain.pin-homed sibling and give it the home's revision changed by one
# character: that must be reported with its file, line and both revisions. The
# same entry at `=dev` must be reported too, and at the home's own revision it
# must not be. Built from the home rather than from the entry, so a real
# mismatch in that entry cannot mask or fake the control. Without these, a
# parse that silently found no ci/toolchain.pin homes reads as agreement.
private_pin_control_failures=()
control_rec=""
control_want=""
for rec in "${private_pin_records[@]}"; do
	entry="${rec#*:}"
	entry="${entry#*:}"
	name="${entry%%=*}"
	if [ -n "${UNLOCKED_SIBLINGS[$name]:-}" ] && [ -z "$(flake_rev "$name")" ]; then
		control_want="$(sed -n "s/^$(private_pin_key "$name")=//p" "$TOOLCHAIN_PIN" | head -n 1)"
		if [ "${#control_want}" -eq 40 ]; then
			control_rec="${rec%%=*}"
			break
		fi
	fi
done
if [ -z "$control_rec" ]; then
	private_pin_control_failures+=("no workflow names a sibling that has a ci/toolchain.pin PRIVATE_SIBLING_* home, so the controls have nothing to mutate")
else
	case "${control_want:0:1}" in 0) control_flip=1 ;; *) control_flip=0 ;; esac
	control_moved="${control_flip}${control_want:1}"
	control_where="${control_rec%%:*}:$(cut -d: -f2 <<<"$control_rec")"
	control_out="$(private_sibling_pin_mismatches "$TOOLCHAIN_PIN" "$control_rec=$control_moved")"
	[[ $control_out == *"$control_where: "*"$control_moved"*"$control_want"* ]] ||
		private_pin_control_failures+=("control: '${control_rec#*:*:}=$control_moved' at $control_where was not reported with its location and both revisions (got: ${control_out:-<nothing>})")
	control_out="$(private_sibling_pin_mismatches "$TOOLCHAIN_PIN" "$control_rec=dev")"
	[[ $control_out == *"$control_where: "* ]] ||
		private_pin_control_failures+=("control: '${control_rec#*:*:}=dev' at $control_where was not reported (got: ${control_out:-<nothing>})")
	control_out="$(private_sibling_pin_mismatches "$TOOLCHAIN_PIN" "$control_rec=$control_want" | grep -F "$control_where: " || true)"
	[ -z "$control_out" ] ||
		private_pin_control_failures+=("control: the home's own revision at $control_where was reported: $control_out")
fi

if [ "${#private_pin_control_failures[@]}" -eq 0 ] && [ "${#private_pin_mismatch_lines[@]}" -eq 0 ]; then
	ok "every private sibling's revision has one home and all $private_pin_checked ci/toolchain.pin-homed workflow copies equal it"
else
	fail "every private sibling's revision has one home and every workflow copy equals it" \
		"a lane that clones a private sibling at a revision other than its home builds" \
		"against a different tree than the lane beside it; set each entry to the home's" \
		"revision (flake.lock for a flake input, ci/toolchain.pin's PRIVATE_SIBLING_* otherwise)" \
		"${private_pin_mismatch_lines[@]}" "${private_pin_control_failures[@]}"
fi

# ---------------------------------------------------------------------------
# 1b. MATCHED PAIR: codetracer-trace-format implies codetracer-trace-format-nim.
#
# These two repos are the two halves of one FFI boundary and are only ever
# correct together:
#
#   codetracer-trace-format/codetracer_trace_writer_nim/src/lib.rs      caller
#   codetracer-trace-format-nim/src/codetracer_trace_writer_ffi.nim     provider
#
# The dependency is not visible from a repo's own manifest, which is why it
# keeps being missed. Anything that path-depends on the
# `codetracer_trace_writer_nim` crate -- codetracer-shell-recorders'
# `crates/ct-shell-trace-writer`, codetracer-beam-recorder, codetracer's own
# db-backend -- drags in a build.rs that resolves the Nim entry point as a
# SIBLING OF codetracer-trace-format and hard-errors when it is absent:
#
#   Nim FFI entry point not found at
#   .../codetracer-trace-format-nim/src/codetracer_trace_writer_ffi.nim
#   -- is the codetracer-trace-format-nim repo checked out as a sibling?
#
# So provisioning the Rust half alone is never right. Two forms of the same
# defect have now been paid for:
#
#   * the Nim half ABSENT      -> the build.rs error above
#                                 (run 31719867246, job 94513828226)
#   * the Nim half STALE       -> a link error against the older provider,
#                                 `undefined reference to ct_reader_event_metadata`
#                                 (fixed in 32a9de3c7 by overriding both)
#
# This is also the general lesson of the lock outage: a per-commit workspace
# lock bought COORDINATION across repos, not merely a pinned SHA. Pinning each
# sibling independently to `dev` keeps them current and silently discards that
# coordination. For independent siblings that is invisible; for a matched pair
# it is a build failure. Where coordination is required it now has to be stated
# explicitly -- and this assertion is where "explicitly" is enforced.
# ---------------------------------------------------------------------------
unpaired=()
for _i in "${!BLOCK_REPOS[@]}"; do
	_repos=" ${BLOCK_REPOS[$_i]} "
	case "$_repos" in
	*" codetracer-trace-format "*)
		case "$_repos" in
		*" codetracer-trace-format-nim "*) ;;
		*)
			unpaired+=("${BLOCK_WHERE[$_i]}: provisions codetracer-trace-format without codetracer-trace-format-nim")
			;;
		esac
		;;
	esac
done
unset _i _repos

if [ "${#unpaired[@]}" -eq 0 ]; then
	ok "every block provisioning codetracer-trace-format also provisions its -nim half"
else
	fail "every block provisioning codetracer-trace-format also provisions its -nim half" \
		"the two repos are one FFI boundary; the Rust half alone fails in build.rs with" \
		"'Nim FFI entry point not found ... is the codetracer-trace-format-nim repo" \
		"checked out as a sibling?'" \
		"${unpaired[@]}"
fi

# ---------------------------------------------------------------------------
# 1c. MATCHED PAIR: io-mon implies nim-shm-gset.
#
# The same defect class as 1b, found by asking the question 1b answers for one
# pair of every other provisioned sibling.
#
#   io-mon/src/io_mon.nim
#     -> io_mon/writer     imports `shm_gset/transport`
#     -> io_mon/fs_snoop   imports `shm_gset` and `shm_gset/transport`
#
# `shm_gset` is the grow-only shared-memory set backing io-mon's Linux
# dependency-capture channel. As with the trace-format pair, the dependency is
# invisible from either manifest: io-mon resolves it as a plain sibling through
# its `config.nims` `SHM_GSET_SRC` default (`../nim-shm-gset/src`), and
# codetracer's repo-root `config.nims` mirrors that with
#
#     addPathIfDir(workspaceRoot / "nim-shm-gset" / "src")
#
# `addPathIfDir` is SILENT when the directory is absent. So an io-mon-only
# `siblings:` block provisions successfully, and the omission surfaces much
# later, in the `ct` compile, as
#
#     cannot open file: shm_gset/transport
#
# with nothing pointing back at the sibling list. Note the sibling clone WINS
# over the `IO_MON_SRC` flake input here -- Nim searches `--path` entries
# newest-first and the repo-root config adds the workspace sibling after it --
# so pinning `io-mon=dev` is exactly what makes the newer `shm_gset` import
# reachable, and exactly what makes the missing sibling fatal. Currency without
# coordination again.
#
# NOT YET OBSERVED IN CI. Both jobs that provision io-mon
# (`visual-replay-regression-gate`, `ct-test-providers`) have been dying earlier
# than the `ct` compile for the whole period this was reachable, so this is a
# static finding, not a reproduction. It is asserted anyway; the mechanism is
# the one already paid for twice in 1b.
# ---------------------------------------------------------------------------
unpaired=()
for _i in "${!BLOCK_REPOS[@]}"; do
	_repos=" ${BLOCK_REPOS[$_i]} "
	case "$_repos" in
	*" io-mon "*)
		case "$_repos" in
		*" nim-shm-gset "*) ;;
		*)
			unpaired+=("${BLOCK_WHERE[$_i]}: provisions io-mon without nim-shm-gset")
			;;
		esac
		;;
	esac
done
unset _i _repos

if [ "${#unpaired[@]}" -eq 0 ]; then
	ok "every block provisioning io-mon also provisions nim-shm-gset"
else
	fail "every block provisioning io-mon also provisions nim-shm-gset" \
		"io_mon's writer/fs_snoop import shm_gset; the repo-root config.nims adds the" \
		"sibling with addPathIfDir, which is silent when absent, so the omission only" \
		"surfaces later as 'cannot open file: shm_gset/transport' from the ct compile" \
		"${unpaired[@]}"
fi

# ---------------------------------------------------------------------------
# 1d. NO SECOND SIBLING-CLONING IMPLEMENTATION.
#
# Everything above reads `siblings:` blocks, so everything above is blind to a
# composite action that clones siblings some OTHER way. That is not a
# hypothetical either: `.github/actions/setup-isonim-siblings` spent months
# cloning nine repos with nine `clone-repo@main` steps at a hard-coded
# `ref: dev`, used by seven jobs in codetracer.yml plus
# request-panel-sidecar-retirement.yml. Every assertion in this file passed the
# whole time, because there was no `siblings:` block to inspect. The nine repos
# were pinned to a branch TIP -- whatever it pointed at the minute the job ran
# -- while every document said this repo's CI builds pinned revisions.
#
# The shared action states the rule directly (metacraft-github-actions/
# clone-siblings/action.yml, "NO SECOND SIBLING-CLONING ACTION"): a per-project
# action must not answer "what revision of sibling repo X does this commit
# use?" itself; it must delegate to something that reads a LOCK. `clone-repo`
# is the primitive those mechanisms are built out of; a composite action
# reaching for it directly is that action taking over revision selection.
#
# There are two delegations that satisfy the rule, and they answer for
# different sibling sets:
#
#   clone-siblings / setup-dev-env  -> the per-commit WORKSPACE lock in
#                                      metacraft-manifests (the db-backend
#                                      siblings, the recorder siblings)
#   repro develop --all             -> this repo's committed `repro.lock`
#                                      (the from-source dependency siblings;
#                                      see 1b)
#
# Both are locks. Neither is a name-and-branch typed into a composite action,
# which is the only thing this assertion forbids.
#
# Scope is composite actions only. A workflow step may still clone one specific
# repo for one specific purpose -- that is a checkout, not a sibling set -- and
# narrowing those is a separate question from this one.
#
# The anti-vacuity half matters more than usual here: "no file matched
# clone-repo" is also what a renamed action directory, a moved primitive or a
# broken glob looks like. So the same scan must find the approved delegation it
# expects to see.
# ---------------------------------------------------------------------------
echo "no composite action clones cross-repo siblings itself"

declare -a COMPOSITE_ACTIONS=()
for _act in "$ACTIONS_DIR"/*/action.yml "$ACTIONS_DIR"/*/action.yaml; do
	[ -f "$_act" ] && COMPOSITE_ACTIONS+=("$_act")
done
unset _act

bespoke_cloners=()
delegating_actions=0
for act in "${COMPOSITE_ACTIONS[@]}"; do
	act_name="${act%/*}"
	act_name="${act_name##*/}"
	clone_repo_uses=0
	delegates=0
	line_no=0
	while IFS= read -r line || [ -n "$line" ]; do
		line_no=$((line_no + 1))
		stripped="${line#"${line%%[![:space:]]*}"}"
		case "$stripped" in
		'#'*) continue ;;
		esac
		case "$stripped" in
		*'clone-repo@'*)
			clone_repo_uses=$((clone_repo_uses + 1))
			bespoke_cloners+=("$act_name/action.yml:$line_no: $stripped")
			;;
		*'clone-siblings@'* | *'setup-dev-env@'* | *'repro develop --all'*)
			delegates=$((delegates + 1))
			;;
		esac
	done <"$act"
	[ "$delegates" -gt 0 ] && delegating_actions=$((delegating_actions + 1))
	unset clone_repo_uses
done

if [ "${#bespoke_cloners[@]}" -eq 0 ]; then
	ok "none of the ${#COMPOSITE_ACTIONS[@]} composite actions uses clone-repo directly"
else
	fail "no composite action clones cross-repo siblings itself" \
		"each line below selects a sibling revision outside the one approved" \
		"mechanism, so no lock, no ::warning:: and no audit can see it; delegate" \
		"to clone-siblings/setup-dev-env with a 'siblings:' list (see" \
		".github/actions/setup-db-backend-siblings), or to 'repro develop --all'" \
		"against this repo's committed repro.lock (see" \
		".github/actions/provision-repro-lock-siblings)" \
		"${bespoke_cloners[@]}"
fi

if [ "$delegating_actions" -ge 2 ]; then
	ok "$delegating_actions composite actions provision siblings through a lock"
else
	fail "composite actions provision siblings through a lock" \
		"only $delegating_actions of ${#COMPOSITE_ACTIONS[@]} composite actions name" \
		"clone-siblings, setup-dev-env or 'repro develop --all' -- either sibling" \
		"provisioning moved somewhere this scanner cannot see, or the actions" \
		"directory was restructured and the assertion above is now vacuous"
fi

# ---------------------------------------------------------------------------
# 2. Every `./non-nix-build/build.sh` invocation has codetracer-trace-format
#    provisioned earlier in its own job.
#
# Job boundaries are two-space-indented keys under `jobs:`; anything deeper
# belongs to the job above it.
# ---------------------------------------------------------------------------
echo
echo "non-nix build legs provision codetracer-trace-format"

build_sites=0
missing_sites=()

for wf in "${SIBLING_SOURCE_FILES[@]}"; do
	wf_name="${wf##*/}"
	job=""
	seen_trace_format=0
	line_no=0
	while IFS= read -r line || [ -n "$line" ]; do
		line_no=$((line_no + 1))
		stripped_line="${line#"${line%%[![:space:]]*}"}"
		case "$line" in
		'  '[a-zA-Z0-9_-]*':'*)
			case "$line" in
			'   '*) ;;
			*)
				job="${line#  }"
				job="${job%%:*}"
				seen_trace_format=0
				;;
			esac
			;;
		esac
		case "$line" in
		*'metacraft-labs/codetracer-trace-format'* | *'codetracer-trace-format='*)
			seen_trace_format=1
			;;
		esac
		# Only real invocations, not the many comment lines that name the
		# script; a comment mentioning it must not create a phantom call site.
		case "$stripped_line" in
		'run: ./non-nix-build/build.sh'* | './non-nix-build/build.sh'*)
			build_sites=$((build_sites + 1))
			if [ "$seen_trace_format" -eq 0 ]; then
				missing_sites+=("$wf_name:$line_no: job '$job' runs ./non-nix-build/build.sh with no codetracer-trace-format checkout before it")
			fi
			;;
		esac
	done <"$wf"
done

# How many `./non-nix-build/build.sh` call sites this workflow is EXPECTED to
# have. The Homebrew-native macOS legs were migrated into the nix dev shell on
# eph-macos-arm64 (6fee21a17), so the answer is now zero and the pairing
# contract below has nothing left to pair.
#
# This is asserted as an exact count rather than dropped, because the check it
# guards -- "the scanner still matches the thing it scans for" -- is still
# worth having in both directions. Requiring `> 0` reported the retirement as a
# failure on every run. Deleting the check outright would mean a re-introduced
# non-nix leg silently reinstates the original defect (a build.sh with no
# codetracer-trace-format sibling, which fails with "checkout not found"). An
# exact count keeps that loud: bring the lane back and this fails until the
# number is updated, which is precisely the moment someone must confirm the
# pairing contract below still holds.
EXPECTED_BUILD_SITES=0

if [ "$build_sites" -eq "$EXPECTED_BUILD_SITES" ]; then
	if [ "$build_sites" -eq 0 ]; then
		ok "the non-nix build lane is retired, as recorded (0 call sites)"
	else
		ok "the workflows still run the non-nix build ($build_sites call sites)"
	fi
else
	fail "the non-nix build call sites match what this contract expects" \
		"expected $EXPECTED_BUILD_SITES './non-nix-build/build.sh' step(s), found $build_sites." \
		"If a non-nix leg was (re)introduced, confirm it provisions" \
		"codetracer-trace-format first -- see the pairing contract below -- and then" \
		"update EXPECTED_BUILD_SITES. If a leg was removed, update the count." \
		"If neither is true, this scanner has stopped matching the steps it scans."
fi

if [ "${#missing_sites[@]}" -eq 0 ]; then
	ok "every non-nix build leg provisions codetracer-trace-format first"
else
	fail "every non-nix build leg provisions codetracer-trace-format first" \
		"build.sh -> env.sh -> build_trace_writer_ffi.sh reads the repo root's" \
		"../codetracer-trace-format and exits 1 with" \
		"'ERROR: codetracer-trace-format checkout not found at ...' when it is absent" \
		"${missing_sites[@]}"
fi

# ---------------------------------------------------------------------------
# 2b. Every job that runs cargo against `src/db-backend` provisions
#     codetracer-native-recorder.
#
# `src/db-backend/build.rs` resolves the Nim MCR emulator as a SIBLING of the
# codetracer checkout and PANICS when it is absent -- it is not an optional
# feature, because `src/lib.rs` exports `emulator_ffi`, `emulator_origin`,
# `emulator_session` and `data_watch` unconditionally:
#
#   thread 'main' panicked at build.rs:170:5:
#   db-backend requires the sibling `codetracer-native-recorder` checkout,
#   and it was not found.
#     workspace sibling: .../src/db-backend/../../../codetracer-native-recorder/ct_emulator
#
# Observed in run 32995543471, job `shell-recorder-tests`, step "Run
# shell-recorder integration tests", after twenty minutes of tree-sitter
# compilation -- the panic is the LAST thing cargo reaches, so the job burns a
# full build before reporting a defect that is visible in the workflow file.
#
# The sibling list of `cross-repo-tests.yml`'s `rr-backend-tests` job names
# codetracer-native-recorder; `shell-recorder-tests`, added later and reasoning
# only about the shell recorders' own path dependencies, did not -- yet it runs
# `cargo test` from inside `src/db-backend`, so it compiles the same build.rs.
# `.github/actions/setup-db-backend-siblings/action.yml` exists precisely to
# stop this being re-derived per job, and a job that hand-rolls the list
# instead has to get it right by hand.
#
# This is the same shape as assertion 2: a call site, and the provisioning that
# must precede it IN THE SAME JOB. Comment lines are skipped, so a job that
# merely NAMES the recorder in prose (this one has several such comments) does
# not thereby satisfy the contract.
# ---------------------------------------------------------------------------
echo
echo "db-backend cargo legs provision codetracer-native-recorder"

# The call site this scanner is known to match, named explicitly. If the
# detector regresses -- a step is reworded, the scanner stops matching -- this
# anchor turns "nothing forbidden was found" into a FAILURE instead of a
# vacuous pass. Two vacuous greens have already been paid for in this file.
readonly DB_BACKEND_ANCHOR='cross-repo-tests.yml:recorder-tests'

# A job satisfies this contract by naming the composite instead of the repo --
# which is the shape this contract WANTS, and also a way to launder the defect
# past it. If `setup-db-backend-siblings` ever stops provisioning
# codetracer-native-recorder, every caller silently stops provisioning it too,
# and a scanner that accepted `uses:` on faith would keep saying "ok". So the
# delegation is only honoured while the delegate actually does the work. The
# per-block repo lists collected by assertion 1 are the evidence.
readonly DB_BACKEND_COMPOSITE='setup-db-backend-siblings/action.yml'
composite_provisions_recorder=0
for _i in "${!BLOCK_WHERE[@]}"; do
	case "${BLOCK_WHERE[$_i]}" in
	"$DB_BACKEND_COMPOSITE":*)
		case " ${BLOCK_REPOS[$_i]} " in
		*" codetracer-native-recorder "*) composite_provisions_recorder=1 ;;
		esac
		;;
	esac
done
unset _i

if [ "$composite_provisions_recorder" -eq 1 ]; then
	ok "$DB_BACKEND_COMPOSITE provisions codetracer-native-recorder"
else
	fail "$DB_BACKEND_COMPOSITE provisions codetracer-native-recorder" \
		"Every job that delegates its db-backend siblings to this composite is" \
		"credited with provisioning the recorder BECAUSE this block names it. With the" \
		"entry gone, that credit is a fiction and the assertion below would pass while" \
		"every one of those jobs panicked in build.rs."
fi

db_backend_sites=()
db_backend_missing=()

for wf in "${SIBLING_SOURCE_FILES[@]}"; do
	case "$wf" in
	"$ACTIONS_DIR"/*) wf_name="${wf#"$ACTIONS_DIR"/}" ;;
	*) wf_name="${wf##*/}" ;;
	esac
	job=""
	seen_recorder=0
	line_no=0
	while IFS= read -r line || [ -n "$line" ]; do
		line_no=$((line_no + 1))
		stripped_line="${line#"${line%%[![:space:]]*}"}"
		# Job boundaries are two-space-indented keys under `jobs:`; anything
		# deeper belongs to the job above it. (Composite actions have no
		# `jobs:` at all, so `job` stays empty and the whole file is one
		# scope -- which is correct: a composite IS one step sequence.)
		case "$line" in
		'  '[a-zA-Z0-9_-]*':'*)
			case "$line" in
			'   '*) ;;
			*)
				job="${line#  }"
				job="${job%%:*}"
				seen_recorder=0
				;;
			esac
			;;
		esac
		# A YAML comment naming the repo is prose, not provisioning. Skipping
		# these is what keeps this assertion from being satisfied by the very
		# comments that explain the failure it guards against.
		case "$stripped_line" in
		'#'*) ;;
		*)
			case "$stripped_line" in
			'codetracer-native-recorder='* | 'codetracer-native-recorder')
				seen_recorder=1
				;;
			*'setup-db-backend-siblings'*)
				# The composite provisions the three db-backend siblings --
				# but only credit the caller while it demonstrably still
				# names the recorder (checked above).
				[ "$composite_provisions_recorder" -eq 1 ] && seen_recorder=1
				;;
			esac
			;;
		esac
		# A quoted YAML sequence item is a `paths:` filter, not a command --
		# `.github/workflows/cross-repo-tests.yml` lists
		# `- 'scripts/run-cross-repo-tests.sh'` among its triggers. Matching
		# those would attribute a call site to the `on:`/`push:` pseudo-jobs.
		case "$stripped_line" in
		"- '"* | '- "'*) continue ;;
		esac
		# The cargo invocations that compile `src/db-backend/build.rs`: a `run:`
		# step that `cd`s in, an out-of-tree invocation naming the manifest, and
		# the cross-repo driver, whose `run_db_backend_test` does
		# `cd "$REPO_ROOT/src/db-backend"; cargo test` (scripts/
		# run-cross-repo-tests.sh:446), and `just test-recorder-siblings`, whose
		# recipe does the same.
		case "$stripped_line" in
		'cd src/db-backend' | 'cd src/db-backend '* | "cd 'src/db-backend'"* | \
			*'--manifest-path src/db-backend'* | *'--manifest-path=src/db-backend'* | \
			*'run-cross-repo-tests.sh'* | *'just test-recorder-siblings'*)
			db_backend_sites+=("$wf_name:$job")
			if [ "$seen_recorder" -eq 0 ]; then
				db_backend_missing+=("$wf_name:$line_no: job '$job' builds src/db-backend with no codetracer-native-recorder sibling before it")
			fi
			;;
		esac
	done <"$wf"
done

_anchor_found=0
for _s in "${db_backend_sites[@]}"; do
	[ "$_s" = "$DB_BACKEND_ANCHOR" ] && _anchor_found=1
done
unset _s

if [ "$_anchor_found" -eq 1 ]; then
	ok "the db-backend cargo scanner still matches its anchor (${#db_backend_sites[@]} call site(s))"
else
	fail "the db-backend cargo scanner still matches its anchor" \
		"expected to find a db-backend cargo call site at '$DB_BACKEND_ANCHOR'," \
		"and did not. Either that job was removed -- in which case move the anchor to" \
		"another real call site -- or this scanner has stopped matching the steps it" \
		"scans, which would make the assertion below a vacuous pass." \
		"found: ${db_backend_sites[*]:-<none>}"
fi
unset _anchor_found

if [ "${#db_backend_missing[@]}" -eq 0 ]; then
	ok "every db-backend cargo leg provisions codetracer-native-recorder first"
else
	fail "every db-backend cargo leg provisions codetracer-native-recorder first" \
		"src/db-backend/build.rs panics at build.rs:170 with 'db-backend requires the" \
		"sibling codetracer-native-recorder checkout, and it was not found' -- after the" \
		"whole tree-sitter dependency tree has been compiled." \
		"${db_backend_missing[@]}"
fi

# ---------------------------------------------------------------------------
# 2b. Every job that runs `ci/test/non-gui.sh` provisions codetracer-js-recorder.
#
# `ci/test/non-gui.sh` runs `just test` -> `just test-rust` -> `cargo nextest
# run --release --test '*'`. That `-E` filter excludes only
# `javascript_flow_integration`, so FIVE JavaScript tests execute on this lane:
#
#   javascript_flow_dap_test::javascript_flow_dap_variables_and_values
#   javascript_flow_dap_test::test_js_locals_all_statements
#   javascript_hcr_ctfs_integration::test_javascript_hcr_ctfs_integration
#   javascript_locals_dap_test::test_js_load_locals_is_point_in_time_not_a_frame_union
#   javascript_locals_dap_test::test_js_locals_live_recording_has_values_on_every_step
#
# Every one of them resolves the recorder through `find_js_recorder()`
# (`src/db-backend/tests/test_harness/mod.rs:2469`), whose last resort is the
# SIBLING path `../../../codetracer-js-recorder/packages/cli/dist/index.js`.
# With the sibling absent it answers None and the HCR test takes its loud-skip
# path instead of asserting.
#
# `origin_javascript_dap_test`'s four tests resolve it the same way and also run
# on this lane; their guard is a bare `return`, so without the sibling they pass
# while asserting nothing. Nine tests depend on this provisioning, not five.
#
# WHY THIS IS ASSERTED RATHER THAN LEFT TO REVIEW: no CI lane built this
# recorder at all. `test-non-gui` provisioned trace-format, trace-format-nim,
# python-, ruby- and beam-recorder and not this one; `windows-rust-components`
# runs a bare `cargo test` with the JS suites `--skip`ped outright. A defect
# affecting EVERY multi-file JavaScript trace survived roughly two months
# behind that gap and was found only because one developer happened to have
# the sibling built locally. Removing the entry again must be a red lane, not
# a quiet return to skipping.
#
# Note this checks PROVISIONING only. The clone alone is not enough --
# `packages/cli/dist/` is produced, never committed -- which is why the job
# also carries a build step that hard-fails on a missing `dist/index.js`. That
# half is enforced by `ci/verdict/recorder-clone-implies-build.py`.
# ---------------------------------------------------------------------------
echo
echo "non-gui legs provision codetracer-js-recorder"

# Named explicitly so a scanner that stops matching turns into a FAILURE
# rather than a vacuous "nothing forbidden was found".
readonly NON_GUI_ANCHOR='codetracer.yml:test-non-gui'

non_gui_sites=()
non_gui_missing=()

for wf in "${SIBLING_SOURCE_FILES[@]}"; do
	case "$wf" in
	"$ACTIONS_DIR"/*) wf_name="${wf#"$ACTIONS_DIR"/}" ;;
	*) wf_name="${wf##*/}" ;;
	esac
	job=""
	seen_js_recorder=0
	line_no=0
	while IFS= read -r line || [ -n "$line" ]; do
		line_no=$((line_no + 1))
		stripped_line="${line#"${line%%[![:space:]]*}"}"
		case "$line" in
		'  '[a-zA-Z0-9_-]*':'*)
			case "$line" in
			'   '*) ;;
			*)
				job="${line#  }"
				job="${job%%:*}"
				seen_js_recorder=0
				;;
			esac
			;;
		esac
		# A YAML comment naming the repo is prose, not provisioning -- and the
		# steps this guards carry long ones. Skipping comments is also what
		# keeps the CALL-SITE match below from firing on a comment that
		# merely mentions ci/test/non-gui.sh, of which this job has several.
		case "$stripped_line" in
		'#'*) continue ;;
		esac
		# Both approved provisioning spellings: a `siblings:` list entry, and
		# a `clone-repo` step's `repo:` (which is what this job uses -- the
		# `siblings:` branch-tip ceiling is never raised, so a new `=dev`
		# entry there is not available).
		case "$stripped_line" in
		'codetracer-js-recorder='* | 'codetracer-js-recorder' | \
			'repo:'*'codetracer-js-recorder' | 'repo:'*'codetracer-js-recorder '*)
			seen_js_recorder=1
			;;
		esac
		# `paths:` filter entries are quoted sequence items, not commands.
		case "$stripped_line" in
		"- '"* | '- "'*) continue ;;
		esac
		case "$stripped_line" in
		*'ci/test/non-gui.sh'*)
			non_gui_sites+=("$wf_name:$job")
			if [ "$seen_js_recorder" -eq 0 ]; then
				non_gui_missing+=("$wf_name:$line_no: job '$job' runs ci/test/non-gui.sh with no codetracer-js-recorder sibling provisioned before it")
			fi
			;;
		esac
	done <"$wf"
done

_anchor_found=0
for _s in "${non_gui_sites[@]}"; do
	[ "$_s" = "$NON_GUI_ANCHOR" ] && _anchor_found=1
done
unset _s

if [ "$_anchor_found" -eq 1 ]; then
	ok "the non-gui scanner still matches its anchor (${#non_gui_sites[@]} call site(s))"
else
	fail "the non-gui scanner still matches its anchor" \
		"expected to find a ci/test/non-gui.sh call site at '$NON_GUI_ANCHOR', and did" \
		"not. Either that job was removed -- in which case move the anchor to another" \
		"real call site -- or this scanner has stopped matching, which would make the" \
		"assertion below a vacuous pass." \
		"found: ${non_gui_sites[*]:-<none>}"
fi
unset _anchor_found

if [ "${#non_gui_missing[@]}" -eq 0 ]; then
	ok "every ci/test/non-gui.sh leg provisions codetracer-js-recorder first"
else
	fail "every ci/test/non-gui.sh leg provisions codetracer-js-recorder first" \
		"without it find_js_recorder() returns None and the five JavaScript db-backend" \
		"tests on this lane skip or panic instead of asserting -- the gap that hid a" \
		"defect in every multi-file JavaScript trace for two months." \
		"${non_gui_missing[@]}"
fi

# ---------------------------------------------------------------------------
# 3. Every `ci/setup-rr-backend.sh` step overrides the ref explicitly, and a
#    literal override equals flake.lock's codetracer-native-backend revision.
# ---------------------------------------------------------------------------
echo
echo "rr-backend setup overrides the ref explicitly"

rr_sites=0
rr_missing=()

for wf in "${SIBLING_SOURCE_FILES[@]}"; do
	wf_name="${wf##*/}"
	step_has_override=0
	line_no=0
	while IFS= read -r line || [ -n "$line" ]; do
		line_no=$((line_no + 1))
		stripped_line="${line#"${line%%[![:space:]]*}"}"
		case "$stripped_line" in
		'- name: '* | '- uses: '* | '- run: '*)
			# A new step: the override must be declared inside the step that
			# runs the script, so reset at every step boundary.
			step_has_override=0
			;;
		esac
		case "$stripped_line" in
		'RR_BACKEND_REF:'*)
			# An empty value is the unset case wearing a costume.
			rr_ref="${stripped_line#RR_BACKEND_REF:}"
			rr_ref="${rr_ref#"${rr_ref%%[![:space:]]*}"}"
			[ -n "$rr_ref" ] && step_has_override=1
			# The override is one more copy of codetracer-native-backend's
			# revision, whose home is flake.lock (1e): a literal must equal it.
			# It trailed flake.lock's 9fcfc0a at 1c8efb8 after 932a8b8aaf
			# with nothing noticing. An expression supplies no copy here.
			case "$(classify_ref "$rr_ref")" in
			sha | branch)
				rr_want="$(flake_rev codetracer-native-backend)"
				[ "$rr_ref" = "$rr_want" ] ||
					rr_missing+=("$wf_name:$line_no: RR_BACKEND_REF: $rr_ref, but flake.lock locks codetracer-native-backend at ${rr_want:-<none>}")
				;;
			esac
			;;
		esac
		case "$stripped_line" in
		*'ci/setup-rr-backend.sh'*)
			case "$stripped_line" in
			'#'*) ;;
			*)
				rr_sites=$((rr_sites + 1))
				if [ "$step_has_override" -eq 0 ]; then
					rr_missing+=("$wf_name:$line_no: runs ci/setup-rr-backend.sh without RR_BACKEND_REF")
				fi
				;;
			esac
			;;
		esac
	done <"$wf"
done

if [ "${#rr_missing[@]}" -eq 0 ]; then
	ok "all $rr_sites ci/setup-rr-backend.sh call sites set RR_BACKEND_REF, at flake.lock's codetracer-native-backend revision"
else
	fail "all ci/setup-rr-backend.sh call sites set RR_BACKEND_REF, at flake.lock's codetracer-native-backend revision" \
		"without it the script resolves the revision from the workspace lock via" \
		"scripts/resolve-sibling-rev.sh, which exits 3 with 'cannot locate the" \
		"manifest repo locks/ tree' on a runner -- there is no .repro/manifests there;" \
		"a literal other than flake.lock's revision builds a different native-backend" \
		"than the Nix lane and the siblings: entries" \
		"${rr_missing[@]}"
fi

# ---------------------------------------------------------------------------
# 4. CREDENTIAL CONTRACT: one installation token per job, minted from the
#    per-repo secret, org-scoped, and named explicitly by every consumer.
#    Every mint must supply private-key from secrets.CI_TOKEN_PROVIDER_PRIVATE_KEY
#    in a workflow, or inputs.private-key in a composite action.
#
# The three sections above check WHICH siblings a job provisions and at WHAT
# ref. This one checks WITH WHAT CREDENTIAL, because the same clone fails just
# as hard on a token that was never minted as on a ref that does not resolve --
# and it fails less legibly.
#
# `metacraft-dev-guidelines/policies/ci-workflow-standards.md` lists the two
# shapes below under "Forbidden patterns". Both were live in this repo and
# neither was catchable by any test:
#
#   * `${{ vars.CI_TOKEN_PROVIDER_APP_ID }}` in 17 mint steps (14 in
#     codetracer.yml, plus beam-flow.yml, mcr-dap-flow.yml and
#     request-panel-sidecar-retirement.yml).
#   * two mint steps in one job -- a `ci_token` and an `app-token` -- in 8
#     jobs, whose outputs were then used interchangeably from step to step.
#
# # Why the `vars.` form worked here, and why that is the problem
#
# `CI_TOKEN_PROVIDER_APP_ID` exists BOTH as a metacraft-labs ORGANIZATION
# VARIABLE with visibility `all` and as a per-repo SECRET on this repo. On the
# organization's Free plan, an org-level variable is readable from PUBLIC
# member repos only; private repos need Team/Enterprise for it to resolve. So
# `vars.CI_TOKEN_PROVIDER_APP_ID` evaluates to the App ID in codetracer purely
# because codetracer is public, and the moment this repo -- or any private repo
# the job body is copied into -- reads it, the expression evaluates to the
# EMPTY STRING. GitHub Actions does not error on an undefined `vars.` lookup
# and does not enforce an action's `required: true` inputs, so nothing upstream
# of the action notices.
#
# What happens next differs by action major, and it is worth writing down
# because the policy text describes it as minting "nothing" silently, which is
# not what either version does:
#
#   @v1  dist/main.cjs guards the input itself --
#        `if (!appId) throw new Error("Input required and not supplied: app-id")`
#        at module top level, outside the promise chain. The step fails with
#        that message.
#   @v2  that guard was REMOVED in favour of `required: true` in action.yml
#        (which the runner does not enforce). The empty value reaches
#        @octokit/auth-app, which throws
#        `[@octokit/auth-app] appId option is required`; the action's
#        `.catch()` turns it into `core.setFailed(...)`.
#
# Either way the job fails loudly at the mint step -- but it fails pointing at
# a library internal rather than at "this repo cannot read org variables", and
# every step downstream that was going to clone a sibling never runs. The
# per-repo secret form has no such dependency on repo visibility at all, which
# is the whole reason the policy names it.
#
# # Why `@v1` is not merely cosmetic
#
# Checked against the published action rather than assumed: v1 and v2 are
# IDENTICAL on the three axes that would actually matter to us -- `owner`
# semantics, the `repositories:` default ("defaults to current repository if
# owner is unset", the same sentence in both action.yml files), and token
# lifetime (fixed at one hour by GitHub's installation-token API; both majors
# revoke in their post step by default). Both even run on `node20`. The real
# v2 breaking change was the removal of the deprecated `app_id` / `private_key`
# / `skip_token_revoke` aliases. So `@v1` is not a security difference; it is a
# stale pin -- v1's last release is v1.12.0 (2025-03-27) and v2 and v3 have
# shipped since -- and, more to the point here, a SECOND shape for one thing.
# This contract therefore does not hard-code "v2": it requires that every mint
# step in the repo agrees on one ref, and that the ref is not the abandoned v1.
#
# # The assertion that makes a half-finished consolidation impossible
#
# `${{ steps.does-not-exist.outputs.token }}` is not an error in GitHub
# Actions. It evaluates to the empty string, and `actions/checkout` with an
# empty `token:` silently falls back to the workflow's own credentials -- which
# work for this public repo and fail for every private sibling. Renaming or
# deleting a mint step while leaving one consumer behind is therefore invisible
# in review, invisible in the YAML linter, and invisible in CI until a private
# clone 404s. The reachability check below is what closes that.
# ---------------------------------------------------------------------------
echo
echo "cross-repo credential: one org-scoped installation token per job"

readonly MINT_ACTION='actions/create-github-app-token@'
# The literal expression text a mint step must NOT use for its app id, and the
# legacy long-lived PAT that the App token replaced. Both are named verbatim in
# the policy's "Forbidden patterns" list.
# shellcheck disable=SC2016
readonly FORBIDDEN_APP_ID_EXPR='${{ vars.CI_TOKEN_PROVIDER_APP_ID }}'
readonly LEGACY_PAT='GH_READ_METACRAFT_PRIVATE_REPOS'
# v1 is the abandoned major. Kept as a named constant so the failure message
# and the check cannot drift apart.
readonly ABANDONED_MINT_REF='v1'

mint_steps=0
mint_refs=""
mint_bad_app_id=()
mint_bad_private_key=()
mint_bad_scope=()
write_mint_steps=0
mint_duplicate=()
legacy_pat_refs=()
unresolved_consumers=()
consumer_count=0
submodule_checkouts=0
untokened_submodule_checkouts=()

# Per-scope record of the mint step ids declared in it. A "scope" is a job in a
# workflow, or the whole file for a composite action (which has no jobs but can
# still declare steps and consume their outputs).
declare -A SCOPE_MINT_IDS=()
# Steps that run ./.github/actions/refresh-github-token, by job: its `token`
# output is a fresh mint of the same App token, so a later step may name it.
# Kept apart from SCOPE_MINT_IDS so a refresh is never a "second mint".
declare -A SCOPE_REFRESH_IDS=()
# Parallel list of "scope<TAB>id<TAB>where" consumer records, validated after
# each file is fully read -- a consumer may legally precede its mint in the
# file even though it cannot precede it at runtime.
declare -a CONSUMER_RECORDS=()

# flush_mint_step: record the mint step whose body has just ended.
flush_mint_step() {
	[ "$in_mint" -eq 1 ] || return 0
	in_mint=0
	mint_steps=$((mint_steps + 1))

	case " $mint_refs " in
	*" $mint_ref "*) ;;
	*) mint_refs="$mint_refs $mint_ref" ;;
	esac

	if [ "$mint_app_id_forbidden" -eq 1 ]; then
		mint_bad_app_id+=("$wf_name:$mint_line: job '$scope' mints with $FORBIDDEN_APP_ID_EXPR")
	fi
	if [ "$mint_private_key" -eq 0 ] || [ "$mint_private_key_invalid" -eq 1 ]; then
		mint_bad_private_key+=("$wf_name:$mint_line: job '$scope' must mint with '$expected_private_key'")
	fi
	if [ "$mint_owner" -eq 0 ]; then
		mint_bad_scope+=("$wf_name:$mint_line: job '$scope' mints without 'owner: metacraft-labs'")
	fi
	# The org-wide shape is for READ tokens, the ones that clone siblings: the
	# installation is org-scoped, so leaving `repositories:` out is what lets a
	# new sibling need no workflow edit. A token that asks for a WRITE
	# permission is the opposite case. Left org-wide it could write to every
	# repository the App is installed on, so it must name the repositories it
	# writes to -- release.yml's dispatch to metacraft-desktop-packages, with
	# `permission-contents: write`, is the shape. Each kind is held to its own
	# rule; neither is waved through.
	if [ "$mint_write" -eq 1 ]; then
		write_mint_steps=$((write_mint_steps + 1))
		if [ "$mint_repositories" -eq 0 ]; then
			mint_bad_scope+=("$wf_name:$mint_line: job '$scope' mints a WRITE token ($mint_write_permission) for the whole installation; name its target with 'repositories:'")
		fi
	elif [ "$mint_repositories" -eq 1 ]; then
		mint_bad_scope+=("$wf_name:$mint_line: job '$scope' narrows a read token with 'repositories:'")
	fi

	local key="$wf_name|$scope"
	local already="${SCOPE_MINT_IDS[$key]-}"
	if [ -n "$already" ]; then
		mint_duplicate+=("$wf_name:$mint_line: job '$scope' mints a second token (already mints:${already})")
	fi
	SCOPE_MINT_IDS[$key]="${already} ${mint_step_id}"
}

# flush_checkout_step: record the actions/checkout step whose body has just
# ended. A checkout that pulls submodules is a CLONE OF OTHER REPOSITORIES,
# not just of this one, and this repo's `libs/tree-sitter-nim` submodule is
# private -- so an untokened `submodules: recursive` is a private clone with no
# credential. It does not fail deterministically, which is what makes it worth
# a contract: a runner whose work tree already holds the submodule succeeds,
# and a fresh one dies with
#
#   fatal: repository 'https://github.com/metacraft-labs/tree-sitter-nim.git/'
#     not found
#
# after which every remaining step in the job is reported `skipped`.
flush_checkout_step() {
	[ "$in_checkout" -eq 1 ] || return 0
	in_checkout=0
	case "$checkout_submodules" in
	'' | 'false' | "'false'" | '"false"' | '0') return 0 ;;
	esac
	submodule_checkouts=$((submodule_checkouts + 1))
	[ "$checkout_token" -eq 1 ] && return 0
	untokened_submodule_checkouts+=("$wf_name:$checkout_line: job '$scope' checks out 'submodules: $checkout_submodules' with no token:")
}

scan_credential_file() {
	local wf="$1"
	local expected_private_key="$CALLER_PRIVATE_KEY" key_line
	wf_name="${wf##*/}"
	# Every composite action is called `action.yml`, so the basename alone
	# would make all of them one file: a mint in one composite would count as
	# a second mint of another, and a consumer in one would resolve against
	# another's mint step. Name a composite by its directory as well.
	case "$wf_name" in
	action.yml | action.yaml)
		expected_private_key="$LOCK_ACTION_PRIVATE_KEY"
		wf_dir="${wf%/*}"
		wf_name="${wf_dir##*/}/$wf_name"
		;;
	esac
	scope="(file scope)"
	seen_jobs_key=0
	line_no=0
	in_mint=0
	mint_ref=""
	mint_step_id=""
	mint_line=0
	mint_app_id_forbidden=0
	mint_private_key=0
	mint_private_key_invalid=0
	mint_with_indent=-1
	mint_owner=0
	mint_repositories=0
	mint_write=0
	mint_write_permission=""
	cur_step_id=""
	in_checkout=0
	checkout_line=0
	checkout_submodules=""
	checkout_token=0

	while IFS= read -r line || [ -n "$line" ]; do
		line_no=$((line_no + 1))
		stripped="${line#"${line%%[![:space:]]*}"}"

		# A commented-out expression is documentation, not wiring; matching it
		# would invent consumers and mint steps that GitHub never sees.
		case "$stripped" in
		'#'*) continue ;;
		esac

		case "$line" in
		'jobs:'*) seen_jobs_key=1 ;;
		esac

		# Job header: `  <id>:` at exactly two spaces, after the `jobs:` key.
		# A trailing comment is stripped first. Without that, `  foo:  # note`
		# would not match, the scope would stay on the PREVIOUS job, and a
		# consumer in `foo` could resolve against a mint step in its
		# predecessor -- the reachability check silently weakened by a comment.
		header="${line%%#*}"
		header="${header%"${header##*[![:space:]]}"}"
		if [ "$seen_jobs_key" -eq 1 ]; then
			case "$header" in
			'   '*) ;;
			'  '[a-zA-Z0-9_-]*':')
				flush_mint_step
				flush_checkout_step
				scope="${header#  }"
				scope="${scope%:}"
				cur_step_id=""
				;;
			esac
		fi

		# Step boundary. `id:` may appear either before or after the `uses:`
		# line inside the same step -- in this repo it precedes it -- so the
		# step id is tracked separately and attached when the step is flushed.
		case "$stripped" in
		'- name: '* | '- uses: '* | '- run: '* | '- id: '* | '- if: '* | '- with:'*)
			flush_mint_step
			flush_checkout_step
			cur_step_id=""
			;;
		esac
		case "$stripped" in
		'id: '* | '- id: '*)
			cur_step_id="${stripped#- }"
			cur_step_id="${cur_step_id#id: }"
			;;
		esac

		case "$stripped" in
		'uses: ./.github/actions/refresh-github-token' | '- uses: ./.github/actions/refresh-github-token')
			[ -n "$cur_step_id" ] && SCOPE_REFRESH_IDS["$wf_name|$scope"]+=" $cur_step_id"
			;;
		esac

		case "$stripped" in
		'uses: actions/checkout@'* | '- uses: actions/checkout@'*)
			in_checkout=1
			checkout_line="$line_no"
			checkout_submodules=""
			checkout_token=0
			;;
		esac

		if [ "$in_checkout" -eq 1 ]; then
			case "$stripped" in
			'submodules:'*)
				checkout_submodules="${stripped#submodules:}"
				checkout_submodules="${checkout_submodules#"${checkout_submodules%%[![:space:]]*}"}"
				;;
			'token:'*) checkout_token=1 ;;
			esac
		fi

		case "$stripped" in
		*"$MINT_ACTION"*)
			in_mint=1
			mint_line="$line_no"
			mint_ref="${stripped##*"$MINT_ACTION"}"
			mint_step_id="$cur_step_id"
			mint_app_id_forbidden=0
			mint_private_key=0
			mint_private_key_invalid=0
			mint_with_indent=-1
			mint_owner=0
			mint_repositories=0
			mint_write=0
			mint_write_permission=""
			;;
		esac

		if [ "$in_mint" -eq 1 ]; then
			indent=$((${#line} - ${#stripped}))
			if [ -n "$stripped" ] && [ "$indent" -le "$mint_with_indent" ]; then
				mint_with_indent=-1
			fi
			case "$stripped" in
			'with:') mint_with_indent=$indent ;;
			'private-key:'*)
				# Only action inputs count; env/run text cannot provide a key.
				[ "$mint_with_indent" -ge 0 ] || continue
				# Compare the entire input, not a substring: a different key or
				# a literal containing the right expression is still not the
				# per-repo credential. Comments do not supply an input.
				key_line="${stripped#private-key:}"
				key_line="${key_line%%#*}"
				key_line="${key_line#"${key_line%%[![:space:]]*}"}"
				key_line="${key_line%"${key_line##*[![:space:]]}"}"
				# YAML permits the expression to be quoted or unquoted.
				case "$key_line" in
				"'"*"'" | '"'*'"') key_line="${key_line:1:${#key_line}-2}" ;;
				esac
				if [ "$key_line" = "${expected_private_key#private-key: }" ]; then
					mint_private_key=1
				else
					mint_private_key_invalid=1
				fi
				;;
			'app-id:'*)
				case "$stripped" in
				*"$FORBIDDEN_APP_ID_EXPR"*) mint_app_id_forbidden=1 ;;
				esac
				;;
			'owner: metacraft-labs') mint_owner=1 ;;
			'repositories:'*) mint_repositories=1 ;;
			# `permission-<name>: write` (actions/create-github-app-token@v2's
			# per-permission inputs). Any one of them makes it a write token.
			'permission-'*': write'*)
				mint_write=1
				mint_write_permission="${stripped%%:*}: write"
				;;
			esac
			# The mint step id may still be arriving (`uses:` first, `id:`
			# second); keep it current until the step is flushed.
			[ -n "$cur_step_id" ] && mint_step_id="$cur_step_id"
		fi

		# Consumers. Every `steps.<id>.outputs.token` reference names the step
		# it expects to have minted; record it with its scope for the
		# reachability check below.
		case "$stripped" in
		*'steps.'*'.outputs.token'*)
			rest="$stripped"
			while :; do
				case "$rest" in
				*'steps.'*'.outputs.token'*) ;;
				*) break ;;
				esac
				rest="${rest#*steps.}"
				ref_id="${rest%%.outputs.token*}"
				# Only a bare step id can precede `.outputs.token`; anything
				# with a space or brace in it is a different expression that
				# merely contains the substring.
				case "$ref_id" in
				*[!a-zA-Z0-9_-]*) ;;
				'') ;;
				*)
					consumer_count=$((consumer_count + 1))
					CONSUMER_RECORDS+=("$wf_name|$scope	$ref_id	$wf_name:$line_no")
					;;
				esac
			done
			;;
		esac

		case "$stripped" in
		*"$LEGACY_PAT"*)
			legacy_pat_refs+=("$wf_name:$line_no: $stripped")
			;;
		esac
	done <"$wf"
	flush_mint_step
	flush_checkout_step
}

for wf in "${SIBLING_SOURCE_FILES[@]}"; do
	scan_credential_file "$wf"
done

for record in ${CONSUMER_RECORDS+"${CONSUMER_RECORDS[@]}"}; do
	key="${record%%	*}"
	tail_="${record#*	}"
	ref_id="${tail_%%	*}"
	where="${tail_#*	}"
	declared="${SCOPE_MINT_IDS[$key]-}${SCOPE_REFRESH_IDS[$key]-}"
	case " $declared " in
	*" $ref_id "*) ;;
	*)
		unresolved_consumers+=("$where: '\${{ steps.$ref_id.outputs.token }}' names no mint step in job '${key#*|}' (declared:${declared:- none})")
		;;
	esac
done

if [ "$mint_steps" -gt 0 ]; then
	ok "the workflows still mint installation tokens ($mint_steps mint steps, $consumer_count consuming references)"
else
	fail "the workflows still mint installation tokens" \
		"no '$MINT_ACTION' step was found -- either cross-repo auth was reworked or" \
		"this scanner no longer matches it, and every check below is vacuous"
fi

if [ "${#mint_bad_private_key[@]}" -eq 0 ]; then
	ok "every mint step reads the private key from the per-repo secret or composite input"
else
	fail "every mint step reads the private key from the per-repo secret or composite input" \
		"${mint_bad_private_key[@]}"
fi

if [ "${#mint_bad_app_id[@]}" -eq 0 ]; then
	ok "every mint step reads the app id from the per-repo secret"
else
	fail "every mint step reads the app id from the per-repo secret" \
		"an org variable is readable from PUBLIC member repos only on this plan, so this" \
		"form resolves here and evaluates to the empty string in any private repo the job" \
		"body is copied into; the mint step then dies inside @octokit/auth-app" \
		"${mint_bad_app_id[@]}"
fi

if [ "${#legacy_pat_refs[@]}" -eq 0 ]; then
	ok "no workflow reads the retired $LEGACY_PAT PAT"
else
	fail "no workflow reads the retired $LEGACY_PAT PAT" \
		"it is a long-lived org-wide token superseded by the per-job App installation" \
		"token; the policy lists it as a forbidden pattern to migrate out of" \
		"${legacy_pat_refs[@]}"
fi

mint_ref_list="${mint_refs# }"
mint_ref_count=0
for _ref in $mint_ref_list; do
	mint_ref_count=$((mint_ref_count + 1))
done
unset _ref
if [ "$mint_ref_count" -le 1 ]; then
	ok "all mint steps agree on one action ref (${mint_ref_list:-none})"
else
	fail "all mint steps agree on one action ref" \
		"two majors of the same action in one repo is how a job ends up with two mint" \
		"steps that look deliberate; pick one and use it everywhere" \
		"refs in use: $mint_ref_list"
fi

case " $mint_ref_list " in
*" $ABANDONED_MINT_REF "*)
	fail "no mint step pins the abandoned $ABANDONED_MINT_REF major" \
		"v1's last release is v1.12.0 (2025-03-27); v2 and v3 have shipped since." \
		"It is behaviourally equivalent for our usage -- same owner semantics, same" \
		"repositories: default, same one-hour token -- so this is a staleness check," \
		"not a security one, and it exists to keep exactly one shape in the tree"
	;;
*)
	ok "no mint step pins the abandoned $ABANDONED_MINT_REF major"
	;;
esac

if [ "${#mint_duplicate[@]}" -eq 0 ]; then
	ok "no job mints more than one installation token"
else
	fail "no job mints more than one installation token" \
		"two tokens for one purpose double the credential surface of the job and make it" \
		"ambiguous which one a given step is actually using; mint once and reference it" \
		"${mint_duplicate[@]}"
fi

if [ "${#mint_bad_scope[@]}" -eq 0 ]; then
	ok "every mint step is scoped by construction: read tokens org-wide, the $write_mint_steps write token(s) narrowed to their target"
else
	fail "every mint step is scoped by construction: read tokens org-wide, write tokens narrowed to their target" \
		"the App installation is org-scoped, so 'owner: metacraft-labs' with no" \
		"'repositories:' is what makes a READ credential need no rotation as siblings" \
		"are added; narrowing one turns every new sibling into a workflow edit. A" \
		"WRITE credential is the reverse: org-wide it can write everywhere the App" \
		"is installed, so it must name the repositories it writes to" \
		"${mint_bad_scope[@]}"
fi

if [ "${#untokened_submodule_checkouts[@]}" -eq 0 ]; then
	ok "all $submodule_checkouts submodule checkouts authenticate with a minted token"
else
	fail "all submodule checkouts authenticate with a minted token" \
		"a checkout that pulls submodules clones OTHER repositories, and" \
		"libs/tree-sitter-nim is private; with no token: it clones with whatever" \
		"credential the runner happens to carry, so it succeeds on a runner that" \
		"already has the submodule and dies with 'repository ... not found' on a fresh" \
		"one, taking every later step down as 'skipped'" \
		"${untokened_submodule_checkouts[@]}"
fi

if [ "${#unresolved_consumers[@]}" -eq 0 ]; then
	ok "every token reference names a mint step in its own job"
else
	fail "every token reference names a mint step in its own job" \
		"GitHub Actions does not error on an unknown step output: the expression" \
		"evaluates to the empty string, and actions/checkout with an empty token: falls" \
		"back to the workflow's own credentials, which work for this public repo and" \
		"fail for every private sibling" \
		"${unresolved_consumers[@]}"
fi

# The controls mutate copies of the shipped inputs, then call the SAME scanner
# as the contract above. Exact, unique anchors make source drift fail loudly.
private_key_control() (
	local source="$1" prefix="$2" original="$3" replacement="$4" want="$5"
	local text needle rest fixture
	text="$(<"$source")"
	needle="$prefix$original"
	rest="${text#*"$needle"}"
	if [ "$rest" = "$text" ] || [[ $rest == *"$needle"* ]]; then
		printf 'mutation anchor is absent or ambiguous: %s\n' "$source"
		return 1
	fi
	fixture="$(mktemp -d)" || return 1
	trap 'rm -rf "$fixture"' EXIT
	# Preserve action.yml: that filename identifies a composite to the scanner.
	if [ "${6:-0}" -eq 1 ]; then
		# No step boundary follows: the scanner must also flush at EOF.
		text="${text%%"$needle"*}$prefix$replacement"
	else
		text="${text/"$needle"/"$prefix$replacement"}"
	fi
	printf '%s\n' "$text" >"$fixture/${source##*/}"
	mint_bad_private_key=()
	scan_credential_file "$fixture/${source##*/}"
	if [ "${#mint_bad_private_key[@]}" -ne "$want" ]; then
		printf 'expected %s private-key defect(s), got %s\n' "$want" "${#mint_bad_private_key[@]}"
		printf '%s\n' "${mint_bad_private_key[@]}"
		return 1
	fi
)

# Include the real mint's id and input block: neighbouring caller inputs must
# neither supply a mutation anchor nor satisfy a missing key on the mint.
# shellcheck disable=SC2016
workflow_key_prefix=$'id: ci_token\n        uses: actions/create-github-app-token@v2\n        with:\n          app-id: ${{ secrets.CI_TOKEN_PROVIDER_APP_ID }}\n          '
# shellcheck disable=SC2016
write_key_prefix=$'id: packages_token\n        uses: actions/create-github-app-token@v2\n        with:\n          app-id: ${{ secrets.CI_TOKEN_PROVIDER_APP_ID }}\n          '
# shellcheck disable=SC2016
action_key_prefix=$'id: token\n      uses: actions/create-github-app-token@v2\n      with:\n        app-id: ${{ inputs.app-id }}\n        '
key_control_defects=()
for kind in workflow composite later-mint; do
	case "$kind" in
	workflow)
		source="$WORKFLOW_DIR/release.yml"
		prefix="$workflow_key_prefix"
		original="$CALLER_PRIVATE_KEY"
		;;
	later-mint)
		source="$WORKFLOW_DIR/release.yml"
		prefix="$write_key_prefix"
		original="$CALLER_PRIVATE_KEY"
		;;
	composite)
		source="$ACTIONS_DIR/refresh-github-token/action.yml"
		prefix="$action_key_prefix"
		original="$LOCK_ACTION_PRIVATE_KEY"
		;;
	esac
	for mutation in valid quoted valid-eof missing missing-eof commented vars literal wrong-context empty suffix misplaced; do
		want=1
		at_eof=0
		# GitHub expressions are literal YAML input, not shell substitutions.
		# shellcheck disable=SC2016
		case "$mutation" in
		valid)
			replacement="$original"
			want=0
			;;
		quoted)
			replacement="private-key: \"${original#private-key: }\" # YAML comment"
			want=0
			;;
		valid-eof)
			replacement="$original"
			want=0
			at_eof=1
			;;
		missing | missing-eof)
			replacement=''
			[ "$mutation" = missing-eof ] && at_eof=1
			;;
		commented) replacement="# $original" ;;
		vars) replacement='private-key: ${{ vars.CI_TOKEN_PROVIDER_PRIVATE_KEY }}' ;;
		literal) replacement='private-key: unavailable' ;;
		empty) replacement='private-key:' ;;
		suffix) replacement="$original-suffix" ;;
		misplaced)
			case "$kind" in
			composite) replacement=$'owner: metacraft-labs\n      env:\n        '"$original" ;;
			*) replacement=$'owner: metacraft-labs\n        env:\n          '"$original" ;;
			esac
			;;
		wrong-context)
			case "$kind" in
			composite) replacement="$CALLER_PRIVATE_KEY" ;;
			*) replacement="$LOCK_ACTION_PRIVATE_KEY" ;;
			esac
			;;
		esac
		if ! detail="$(private_key_control "$source" "$prefix" "$original" "$replacement" "$want" "$at_eof")"; then
			key_control_defects+=("$kind/$mutation: $detail")
		fi
	done
done
if [ "${#key_control_defects[@]}" -eq 0 ]; then
	ok "the private-key scanner accepts real workflows and composites and rejects missing or wrong-source keys in each mint"
else
	fail "the private-key scanner accepts real workflows and composites and rejects missing or wrong-source keys in each mint" "${key_control_defects[@]}"
fi

# ---------------------------------------------------------------------------
# 5. A step that runs BEFORE the dev shell uses only the tools its runner has.
#
# Provisioning happens before `nix develop`, so it runs on the runner's own
# PATH, and that PATH is not a stock Linux userland:
#
#   * nix-darwin runners (`aarch64-darwin`): the nix profile built from infra's
#     runner `extraPackages` (coreutils-full, git, curl, jq, gh, gnupg, openssh,
#     direnv). No grep, no sed, no awk, no python3. `provision-repro-lock-
#     siblings` died there with `grep: command not found` (codetracer-pm
#     issues/2026-10-22-provision-repro-lock-siblings-runs-grep-and-sed-
#     outside-the-dev-shell-on-darwin.md).
#   * self-hosted NixOS runners (`[self-hosted, linux, …]`): the same profile
#     plus systemd's default service PATH, which does bring the GNU userland
#     but NO python3 and NO perl. The GPUI window-captures lane read the
#     isonim-gpui pin with python3 there and has never got past that step
#     (issues/2026-10-22-gpui-window-captures-lane-reads-the-isonim-gpui-pin-
#     with-python3-the-runner-lacks.md).
#
# jq is on both, and is what such a step reads JSON with.
#
# WHAT COUNTS AS "BEFORE THE DEV SHELL". A `run:` step whose `shell:` is not a
# `nix develop` wrapper, read line by line until the first line that enters an
# environment (`nix develop`, `nix shell`, `nix run`, `nix-shell`,
# `repro exec`); from there on a line may be running inside it, and is not
# judged. So a banned tool AFTER an environment is entered in the same step is
# not caught -- a known blind spot, kept because the alternative is parsing
# shell quoting. A local composite action is judged by the runners of the jobs
# that use it. Windows steps and GitHub-hosted runners are not judged here: the
# hosted images carry all of these tools, and the Windows images have their
# own contract in ci/test/windows-runner-bootstrap-test.sh.
# ---------------------------------------------------------------------------
echo
echo "steps that run before the dev shell use only their runner's tools"

readonly DARWIN_MISSING_TOOLS="grep sed awk python3 perl"
readonly NIXOS_MISSING_TOOLS="python3 perl"

# runs-on value(s) -> darwin | nixos | '' (not judged here)
runner_class_of() {
	local value="${1//[\[\],]/ }" token
	for token in $value; do
		case "$token" in *darwin* | macos*) echo darwin && return 0 ;; esac
	done
	for token in $value; do
		case "$token" in windows | eph-win-* | windows-*) return 0 ;; esac
	done
	for token in $value; do
		[ "$token" = self-hosted ] && echo nixos && return 0
	done
	return 0
}

# Does $1 (one line of shell) invoke tool $2 as a command? Command position
# only: after start of line, a pipe, `;`, `&`, `(`, `$(` or a backtick, so a
# word in an echo'd sentence or a path such as `ci/foo-grep.sh` is not a hit.
invokes_tool() {
	[[ " $1" =~ (^|[[:space:]\;\&\|\(\`]|\$\()$2([[:space:]]|$) ]]
}

raw_steps_judged=0
raw_tool_violations=()
declare -A ACTION_RUNNER_CLASSES=()
declare -A JOB_RUNNER_VALUES=()

# Judge one finished step: $1 = where it is (`<dir>/<file>`), $2 = runner
# classes, $3 = its shell: value, then "lineno<TAB>text" records of its run: body.
judge_step() {
	local where="$1" classes="$2" shell="$3"
	shift 3
	[ "$#" -gt 0 ] || return 0
	case "$shell" in *'nix develop'* | *pwsh* | *powershell* | *cmd*) return 0 ;; esac
	local class tools rec text lineno tool entered
	for class in $classes; do
		case "$class" in
		darwin) tools="$DARWIN_MISSING_TOOLS" ;;
		nixos) tools="$NIXOS_MISSING_TOOLS" ;;
		*) continue ;;
		esac
		raw_steps_judged=$((raw_steps_judged + 1))
		entered=0
		for rec in "$@"; do
			lineno="${rec%%	*}"
			text="${rec#*	}"
			case "$text" in '#'*) continue ;; esac
			case "$text" in
			*'nix develop'* | *'nix shell'* | *'nix run'* | *'nix-shell'* | *'repro exec'*) entered=1 ;;
			esac
			[ "$entered" -eq 0 ] || break
			for tool in $tools; do
				if invokes_tool "$text" "$tool"; then
					raw_tool_violations+=("$where:$lineno [$class runner] runs '$tool' before the dev shell: $text")
				fi
			done
		done
	done
}

# Walk one YAML file's steps. $2 = the runner classes to judge every step by
# (a composite action), or '' to take them from each job's `runs-on:` and
# matrix `runner:` values (a workflow).
scan_raw_steps() {
	local file="$1" forced="$2"
	# `<dir>/<file>` names the step in a report, so a composite action is
	# named by its directory rather than as one of many `action.yml`s.
	local where="${file%/*}"
	where="${where##*/}/${file##*/}"
	local line line_no=0 job="" indent item_indent=-1 in_run=0 run_indent=0
	local step_shell="" classes="" text next_job next_indent
	local -a body=()

	# Pass 1, workflows only: each job's runner values, and which local
	# composite actions it uses (so an action is judged by its callers).
	if [ -z "$forced" ]; then
		while IFS= read -r line; do
			if [[ $line =~ ^\ \ ([A-Za-z0-9_-]+):[[:space:]]*(#.*)?$ ]]; then
				job="${BASH_REMATCH[1]}"
			elif [[ $line =~ ^[[:space:]]+(-[[:space:]]+)?(runs-on|runner):[[:space:]]*([^#]*) ]]; then
				JOB_RUNNER_VALUES["$file|$job"]+=" ${BASH_REMATCH[3]}"
			fi
		done <"$file"
		job=""
		while IFS= read -r line; do
			if [[ $line =~ ^\ \ ([A-Za-z0-9_-]+):[[:space:]]*(#.*)?$ ]]; then
				job="${BASH_REMATCH[1]}"
			elif [[ $line =~ uses:[[:space:]]*\./\.github/actions/([A-Za-z0-9_-]+) ]]; then
				ACTION_RUNNER_CLASSES["${BASH_REMATCH[1]}"]+=" $(runner_class_of "${JOB_RUNNER_VALUES["$file|$job"]:-}")"
			fi
		done <"$file"
		job=""
	fi

	while IFS= read -r line || [ -n "$line" ]; do
		line_no=$((line_no + 1))
		indent="${line%%[![:space:]]*}"
		# Inside a block `run: |` body: everything indented past the key.
		if [ "$in_run" -eq 1 ]; then
			if [ -z "${line//[[:space:]]/}" ] || [ "${#indent}" -gt "$run_indent" ]; then
				text="${line#"$indent"}"
				[ -n "$text" ] && body+=("$line_no	$text")
				continue
			fi
			in_run=0
		fi
		if [ -z "$forced" ] && [[ $line =~ ^\ \ ([A-Za-z0-9_-]+):[[:space:]]*(#.*)?$ ]]; then
			# Read the match first: judge_step runs regexes of its own.
			next_job="${BASH_REMATCH[1]}"
			judge_step "$where" "$classes" "$step_shell" "${body[@]+"${body[@]}"}"
			body=()
			step_shell=""
			item_indent=-1
			job="$next_job"
			classes="$(runner_class_of "${JOB_RUNNER_VALUES["$file|$job"]:-}")"
			continue
		fi
		[ -n "$forced" ] && classes="$forced"
		# A list item at or left of the current step's indent starts a new step
		# (or ends the list); either way the open step is finished.
		if [[ $line =~ ^([[:space:]]*)-[[:space:]] ]] && { [ "$item_indent" -lt 0 ] || [ "${#BASH_REMATCH[1]}" -le "$item_indent" ]; }; then
			next_indent="${#BASH_REMATCH[1]}"
			judge_step "$where" "$classes" "$step_shell" "${body[@]+"${body[@]}"}"
			body=()
			step_shell=""
			item_indent="$next_indent"
		fi
		if [[ $line =~ ^([[:space:]]*)(-[[:space:]]+)?shell:[[:space:]]*(.*)$ ]]; then
			step_shell="${BASH_REMATCH[3]}"
		elif [[ $line =~ ^([[:space:]]*)(-[[:space:]]+)?run:[[:space:]]*(.*)$ ]]; then
			run_indent=$((${#BASH_REMATCH[1]} + ${#BASH_REMATCH[2]}))
			case "${BASH_REMATCH[3]}" in
			'|'* | '>'*) in_run=1 ;;
			*) body+=("$line_no	${BASH_REMATCH[3]}") ;;
			esac
		fi
	done <"$file"
	judge_step "$where" "$classes" "$step_shell" "${body[@]+"${body[@]}"}"
}

for wf in "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml; do
	[ -f "$wf" ] && scan_raw_steps "$wf" ""
done
for act_dir in "$ACTIONS_DIR"/*/; do
	act_name="${act_dir%/}"
	act_name="${act_name##*/}"
	act_classes="${ACTION_RUNNER_CLASSES[$act_name]:-}"
	[ -n "${act_classes// /}" ] || continue
	for act in "$act_dir"action.yml "$act_dir"action.yaml; do
		[ -f "$act" ] && scan_raw_steps "$act" "$(tr ' ' '\n' <<<"$act_classes" | sort -u | tr '\n' ' ')"
	done
done
unset wf act act_dir act_name act_classes

# Anti-vacuity: a scanner that stopped recognising steps (or runners) would
# report "no violations" over nothing. Dozens of raw steps run on these two
# runner classes today.
if [ "$raw_steps_judged" -ge 20 ] && [ "${#raw_tool_violations[@]}" -eq 0 ]; then
	ok "no step uses a tool its runner lacks before the dev shell ($raw_steps_judged raw steps judged)"
else
	fail "no step uses a tool its runner lacks before the dev shell" \
		"judged $raw_steps_judged raw steps (a floor of 20 keeps the scan honest)." \
		"Read the value with a tool the runner declares (jq for JSON, bash" \
		"builtins for text), or move the step into 'nix develop .#ci'." \
		"${raw_tool_violations[@]+"${raw_tool_violations[@]}"}"
fi

# ---------------------------------------------------------------------------
# 6. The lane that runs this suite runs every suite, whatever fails first.
#
# `ci-contract-suites` (codetracer.yml) is a list of steps, one per contract
# suite, and GitHub skips every later step once one fails. From 2026-09-20 the
# Windows-runner suite, its first, failed on every run, and THIS suite, its
# third, went unread behind it while its expectations drifted from repro.lock
# (codetracer-pm issues/2026-10-22-ci-contract-suites-recognise-windows-jobs-
# by-a-retired-runner-label.md). Each step after the checkout therefore carries
# exactly RUN_ALL_IF, and the checkout carries `id: checkout` so the condition
# names a step that exists. A step added without it would quietly restore the
# old behaviour for every suite after it, so it is checked rather than hoped
# for.
# ---------------------------------------------------------------------------
echo
echo "the ci-contract-suites lane runs every suite"

readonly CONTRACT_LANE_WORKFLOW="$WORKFLOW_DIR/codetracer.yml"
readonly CONTRACT_LANE_JOB="ci-contract-suites"
# The expression is GitHub Actions' own syntax, quoted verbatim.
# shellcheck disable=SC2016
readonly RUN_ALL_IF='if: ${{ !cancelled() && steps.checkout.outcome == '"'success'"' }}'
# The lane runs seventeen suites today; a floor keeps a scanner that stopped
# finding steps from reporting "no violations" over none.
readonly MIN_CONTRACT_LANE_STEPS=10

lane_steps=0
lane_defects=()
lane_checkout_id=""
in_lane=0
lane_closed=0
step_name=""
step_has_if=0
step_is_checkout=0

flush_lane_step() {
	[ -n "$step_name" ] || return 0
	lane_steps=$((lane_steps + 1))
	if [ "$lane_steps" -eq 1 ]; then
		[ "$step_is_checkout" -eq 1 ] ||
			lane_defects+=("its first step '$step_name' is not the actions/checkout step the condition depends on")
	elif [ "$step_has_if" -eq 0 ]; then
		lane_defects+=("step '$step_name' does not carry '$RUN_ALL_IF'")
	fi
}

while IFS= read -r line || [ -n "$line" ]; do
	if [[ $line =~ ^\ \ ([A-Za-z0-9_-]+):[[:space:]]*(#.*)?$ ]]; then
		if [ "$in_lane" -eq 1 ]; then
			flush_lane_step
			lane_closed=1
			break
		fi
		[ "${BASH_REMATCH[1]}" = "$CONTRACT_LANE_JOB" ] && in_lane=1
		continue
	fi
	[ "$in_lane" -eq 1 ] || continue
	if [[ $line =~ ^\ \ \ \ \ \ -\ (.*)$ ]]; then
		flush_lane_step
		step_name="${BASH_REMATCH[1]#name: }"
		step_has_if=0
		step_is_checkout=0
		continue
	fi
	[ -n "$step_name" ] || continue
	case "$line" in
	"        $RUN_ALL_IF") step_has_if=1 ;;
	'        uses: actions/checkout@'*) step_is_checkout=1 ;;
	'        id: '*)
		[ "$lane_steps" -eq 0 ] && lane_checkout_id="${line#        id: }"
		;;
	esac
done <"$CONTRACT_LANE_WORKFLOW"
# ---------------------------------------------------------------------------
# 1f. The launcher <-> recorder E2E gate provisions from codetracer's locks.
#
# The gate runs in other repositories too (recorders, the launcher), with
# codetracer checked out beside them at the codetracer revision under test.
# Its siblings come from THAT commit's repro.lock, test lock and private homes:
# provision-repro-lock-siblings (codetracer-dir, exclude) clones the build
# inputs, ci/launcher-recorder-e2e-resolve-siblings.sh gives each private
# corner its one-home revision and fails a planned sibling no lock pins, and
# the workflow restates no revision. The focused suite holds the details and
# its negative controls; this file, the repository's sibling-provisioning
# gate, requires that it passes.
# ---------------------------------------------------------------------------
if lrc_out="$(bash "$REPO_ROOT/ci/test/launcher-recorder-e2e-provisioning-test.sh" 2>&1)"; then
	ok "the launcher-recorder E2E gate provisions every sibling from codetracer's locks and homes ($(tail -n 1 <<<"$lrc_out"))"
else
	fail "the launcher-recorder E2E gate provisions every sibling from codetracer's locks and homes" \
		"$(grep -E 'FAIL|^ {7}' <<<"$lrc_out" | head -20)"
fi

# The lane as the last job of the file: its last step ends at end of file.
if [ "$in_lane" -eq 1 ] && [ "$lane_closed" -eq 0 ]; then
	flush_lane_step
fi

[ "$lane_checkout_id" = checkout ] ||
	lane_defects+=("its checkout step's id is '${lane_checkout_id:-<none>}', not 'checkout', so steps.checkout.outcome names nothing")

if [ "$lane_steps" -ge "$MIN_CONTRACT_LANE_STEPS" ] && [ "${#lane_defects[@]}" -eq 0 ]; then
	ok "every step after the checkout in $CONTRACT_LANE_JOB runs even when an earlier suite failed ($((lane_steps - 1)) suites)"
else
	fail "every step after the checkout in $CONTRACT_LANE_JOB runs even when an earlier suite failed" \
		"found $lane_steps step(s) (a floor of $MIN_CONTRACT_LANE_STEPS keeps the scan honest)." \
		"Without the condition GitHub skips every suite after the first red one," \
		"and their verdicts go unread." \
		"${lane_defects[@]+"${lane_defects[@]}"}"
fi

# ---------------------------------------------------------------------------
# Self-accounting: a contract that is deleted or short-circuited must not leave
# this script reporting success on fewer checks than it claims.
# ---------------------------------------------------------------------------
echo
# 23 -> 26: assertion 2b ("db-backend cargo legs provision
# codetracer-native-recorder") contributes the composite-integrity check, the
# scanner-anchor check, and the contract itself.
# 26 -> 27: assertion 1b was rewritten when the IsoNim-family siblings moved
# from the workspace lock to this repo's own `repro.lock`. It used to make
# three checks about a `siblings:` block that no longer exists; it now makes
# four about the lock and the action that reads it (the action still runs the
# command, it hand-writes no set or revision, the lock declares the set, and
# every member is pinned to a 40-hex SHA).
# 27 -> 29: assertion 2c ("non-gui legs provision codetracer-js-recorder")
# contributes the scanner-anchor check and the contract itself.
# 29 -> 30: assertion 1b adds the build-input subset of the develop set (the
# lock's develop set grew to name the test-lane siblings, and the action
# clones only the members the build compiles from source).
# 30 -> 31: assertion 1d ("every SHA-pinned flake-input sibling equals its
# flake.lock locked.rev"), added with the trace-format conversion. It reports
# exactly once, either as the agreement or as the vacuity refusal, so this
# number grows by one and not by two.
# 32 -> 34 (2026-10-22): every build input is public, and section 6 (the
# ci-contract-suites lane runs every suite).
# 34 -> 35: the build-input selector runs on a bash-only PATH.
# 35 -> 36: section 5, raw steps use only their runner's tools.
# 36 -> 38 (2026-11-02): "every build-input sibling is public" is gone. It read
# the lock's `visibility` field, a reprobuild tier that says "public" for
# private repositories too, and passed while the private codetracer-image-diff
# clone failed. Three assertions replace it: the action declares a required
# gh-token input, its clone runs through the pinned shared git-auth action with
# that token, and every caller passes a minted token.
# 38 -> 39: the git-auth pin names a sibling commit that carries the action.
# 39 -> 40 (2026-11-04): the action mints the clone's token itself. "declares
# a required gh-token input" became "takes app-id and private-key and no
# gh-token", the git-auth check now wants the action's own mint output, and a
# new check orders the steps so that the dev shell is realised before the mint
# and the clone follows it directly. The release build's caller-minted token
# expired inside a cold realisation of that shell.
# 40 -> 42: every mint supplies the private key from its owning context, and
# mutation controls prove that missing or wrong-source inputs are rejected.
# 42 -> 47 (2026-11-16): the test lock, ci/test/siblings/repro.lock. It declares
# the test siblings; each has one 40-hex pin and agrees with repro.lock where
# both pin a repo; the action clones test-siblings from it; every
# test-siblings name is in it; upload-failed-runs follows its DemoVideoScript.
# 47 -> 49 (2026-11-17): the fixed develop-set list is replaced by checks
# derived from repro.lock and repro.nim. "repro.lock declares the dependency
# set CI provisions" became three: the develop set is the closure of the
# root's direct dependencies, each direct dependency is declared in repro.nim,
# and every bare-name workflow sibling is in the lock. The build-input
# assertion now expects every solved sibling ("clone all").
# 49 -> 51 (2026-11-17): every repo a workflow clones is declared by a lock,
# and every cloned sibling's lock pins repro.lock's package catalog.
# 51 -> 52 (2026-11-18): no sibling listed as deliberately unlocked (private, or
# not declarable) is pinned by the public repro.lock.
# 52 -> 53 (2026-11-20): no workflow names such a sibling bare (run 44612896066).
# 53 -> 54 (2026-11-22): every copy of a private sibling's revision equals its
# one home, flake.lock or ci/toolchain.pin (1e).
# 54 -> 55 (2026-11-24): the launcher-recorder E2E gate provisions from
# codetracer's locks and private homes (1f).
readonly EXPECTED_ASSERTIONS=55
if [ "$assertions" -ne "$EXPECTED_ASSERTIONS" ]; then
	printf 'FAIL: ran %d assertions, expected %d\n' "$assertions" "$EXPECTED_ASSERTIONS"
	failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
	printf '%d of %d assertions failed\n' "$failures" "$assertions"
	exit 1
fi
printf 'all %d assertions passed\n' "$assertions"
