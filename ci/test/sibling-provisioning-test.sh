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
#      installation token per job, minted from the per-repo SECRET, org-scoped
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
# The workflow files themselves are the input. Nothing is stubbed, generated or
# reconstructed: the parse runs over `.github/workflows/*.yml` as committed,
# which is the artefact GitHub executes.
#
# Run: bash ci/test/sibling-provisioning-test.sh
# Lane: a step of the `ci-verdict` job (stock ubuntu-latest, bash only -- no
#       Nix, no dev shell), alongside the verdict gate's own self-test.
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
readonly BRANCH_TIP_CEILING=56

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

sibling_blocks=0
bad_entries=()
entry_count=0
branch_tip_entries=()
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
				sha) ;;
				expr)
					# An expression-valued ref must supply a fallback. Without
					# one it evaluates to the empty string on a push, which is
					# the lock path -- fine when that was the intent, and a
					# silent surprise when the author meant to pin something.
					case "$ref" in
					*'||'*) ;;
					*)
						bad_entries+=("$wf_name:$line_no: '$stripped' (expression ref with no || fallback evaluates to empty on push)")
						;;
					esac
					;;
				branch)
					branch_tip_entries+=("$wf_name:$line_no: '$stripped'")
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
# in metacraft-labs/metacraft-manifests. A workspace lock is a `repo manifest
# -r` snapshot of the repo SET a developer had checked out when they pushed --
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
# names the dependency set and a 40-hex revision for each, and
# `.github/actions/provision-repro-lock-siblings` clones exactly that with
# `repro develop --all`. No manifest repo, no publication lag, no branch tip.
#
# What is asserted here is that the arrangement stays that way: the action
# still runs the lock-driven command (anti-vacuity -- everything below is
# meaningless if it was renamed or rewritten), it hand-writes no sibling list
# of its own, the lock still declares the dependency set, and every member of
# that set carries an immutable revision.
# ---------------------------------------------------------------------------
echo
echo "the from-source dependency siblings resolve from this repo's repro.lock"

readonly LOCK_ACTION="$ACTIONS_DIR/provision-repro-lock-siblings/action.yml"
readonly REPRO_LOCK="$REPO_ROOT/repro.lock"
# The dependency set `repro.lock`'s `codetracer` node declares, in the order it
# declares them. Pinned here so that a repo silently added to or dropped from
# the lock is a failure rather than a quiet change of what CI provisions.
readonly LOCK_DECLARED_DEPS='isonim,nim-acp,nim-agent-harbor,nim-agents,nim-everywhere'

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
fi

if [ "${#lock_action_defects[@]}" -eq 0 ]; then
	ok "provision-repro-lock-siblings still runs 'repro develop --all --reset --into='"
else
	fail "provision-repro-lock-siblings still runs 'repro develop --all --reset --into='" \
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
	# prose; only the executable half is scanned.)
	# Here-string, not a pipe: `grep -q` exits on its first match, `sed` then
	# takes SIGPIPE, and under `set -o pipefail` a SUCCESSFUL MATCH is reported
	# as failure. See ci/test/grep-q-pipefail-gate.sh.
	if grep -Eq '\b[0-9a-f]{40}\b' <<<"$(sed -n '/^runs:/,$p' "$LOCK_ACTION")"; then
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

# The lock itself: the `codetracer` node's `depends` field is the declaration
# `repro develop --all` resolves.
if [ -f "$REPRO_LOCK" ]; then
	actual_deps="$(grep -o 'name = "codetracer", path = "\."[^}]*depends = "[^"]*"' "$REPRO_LOCK" |
		sed 's/.*depends = "//; s/"$//' | head -n 1)"
else
	actual_deps="<repro.lock not found>"
fi

if [ "$actual_deps" = "$LOCK_DECLARED_DEPS" ]; then
	ok "repro.lock declares the dependency set CI provisions ($actual_deps)"
else
	fail "repro.lock declares the dependency set CI provisions" \
		"this is what 'repro develop --all' clones, so a change here is a change" \
		"to what every job in this repo builds against" \
		"expected: $LOCK_DECLARED_DEPS" \
		"actual:   $actual_deps"
fi

# ... and each of them at an IMMUTABLE revision. A branch name here would be
# the same defect the ceiling above exists to prevent, arriving through the
# other lock.
unpinned_deps=()
if [ -f "$REPRO_LOCK" ]; then
	IFS=',' read -r -a _declared <<<"$LOCK_DECLARED_DEPS"
	for dep in "${_declared[@]}"; do
		rev="$(grep -o "name = \"$dep\", path = \"[^\"]*\"[^}]*revision = \"[^\"]*\"" "$REPRO_LOCK" |
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
readonly DB_BACKEND_ANCHOR='cross-repo-tests.yml:shell-recorder-tests'

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
		# run-cross-repo-tests.sh:446).
		case "$stripped_line" in
		'cd src/db-backend' | 'cd src/db-backend '* | "cd 'src/db-backend'"* | \
			*'--manifest-path src/db-backend'* | *'--manifest-path=src/db-backend'* | \
			*'run-cross-repo-tests.sh'*)
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
# 3. Every `ci/setup-rr-backend.sh` step overrides the ref explicitly.
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
	ok "all $rr_sites ci/setup-rr-backend.sh call sites set RR_BACKEND_REF"
else
	fail "all ci/setup-rr-backend.sh call sites set RR_BACKEND_REF" \
		"without it the script resolves the revision from the workspace lock via" \
		"scripts/resolve-sibling-rev.sh, which exits 3 with 'cannot locate the" \
		"manifest repo locks/ tree' on a runner -- there is no .repro/manifests there" \
		"${rr_missing[@]}"
fi

# ---------------------------------------------------------------------------
# 4. CREDENTIAL CONTRACT: one installation token per job, minted from the
#    per-repo secret, org-scoped, and named explicitly by every consumer.
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
mint_bad_scope=()
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
	if [ "$mint_owner" -eq 0 ]; then
		mint_bad_scope+=("$wf_name:$mint_line: job '$scope' mints without 'owner: metacraft-labs'")
	fi
	if [ "$mint_repositories" -eq 1 ]; then
		mint_bad_scope+=("$wf_name:$mint_line: job '$scope' narrows the installation with 'repositories:'")
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

for wf in "${SIBLING_SOURCE_FILES[@]}"; do
	wf_name="${wf##*/}"
	scope="(file scope)"
	seen_jobs_key=0
	line_no=0
	in_mint=0
	mint_ref=""
	mint_step_id=""
	mint_line=0
	mint_app_id_forbidden=0
	mint_owner=0
	mint_repositories=0
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
			mint_owner=0
			mint_repositories=0
			;;
		esac

		if [ "$in_mint" -eq 1 ]; then
			case "$stripped" in
			'app-id:'*)
				case "$stripped" in
				*"$FORBIDDEN_APP_ID_EXPR"*) mint_app_id_forbidden=1 ;;
				esac
				;;
			'owner: metacraft-labs') mint_owner=1 ;;
			'repositories:'*) mint_repositories=1 ;;
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
done

for record in ${CONSUMER_RECORDS+"${CONSUMER_RECORDS[@]}"}; do
	key="${record%%	*}"
	tail_="${record#*	}"
	ref_id="${tail_%%	*}"
	where="${tail_#*	}"
	declared="${SCOPE_MINT_IDS[$key]-}"
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
	ok "every mint step is org-scoped by construction (owner set, no repositories:)"
else
	fail "every mint step is org-scoped by construction (owner set, no repositories:)" \
		"the App installation is org-scoped, so 'owner: metacraft-labs' with no" \
		"'repositories:' is what makes the credential need no rotation as siblings are" \
		"added; narrowing it turns every new sibling into a workflow edit" \
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
readonly EXPECTED_ASSERTIONS=27
if [ "$assertions" -ne "$EXPECTED_ASSERTIONS" ]; then
	printf 'FAIL: ran %d assertions, expected %d\n' "$assertions" "$EXPECTED_ASSERTIONS"
	failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
	printf '%d of %d assertions failed\n' "$failures" "$assertions"
	exit 1
fi
printf 'all %d assertions passed\n' "$assertions"
