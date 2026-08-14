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
# 1. Every `siblings:` entry names an explicit ref.
#
# Deliberately a small, explicit scanner rather than a YAML library: this must
# run on a stock runner with bash and nothing else, in the same spirit as
# ci/test/windows-runner-bootstrap-test.sh.
#
# A `siblings: |` block is a YAML literal scalar; its entries are the lines
# indented deeper than the key, up to the first line that is not.
# ---------------------------------------------------------------------------
echo "siblings: entries pin an explicit ref"

sibling_blocks=0
bad_entries=()
entry_count=0
# Per-block record of which repos each `siblings:` block provisions, used by
# the matched-pair assertion further down. One space-delimited entry per block.
declare -a BLOCK_REPOS=()
declare -a BLOCK_WHERE=()

for wf in "${SIBLING_SOURCE_FILES[@]}"; do
	wf_name="${wf##*/}"
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
				*=*)
					# An expression-valued ref must not be able to evaluate to
					# the empty string; `name=` is the lock fallback.
					ref="${stripped#*=}"
					case "$ref" in
					'')
						bad_entries+=("$wf_name:$line_no: '$stripped' (empty ref falls back to the workspace lock)")
						;;
					*"$ACTIONS_EXPR_OPEN"*)
						case "$ref" in
						*'||'*) ;;
						*)
							bad_entries+=("$wf_name:$line_no: '$stripped' (expression ref with no || fallback evaluates to empty on push)")
							;;
						esac
						;;
					esac
					;;
				*)
					bad_entries+=("$wf_name:$line_no: '$stripped' (bare name resolves through the workspace lock)")
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
	ok "all $entry_count sibling entries across $sibling_blocks blocks pin an explicit ref"
else
	fail "all sibling entries pin an explicit ref" \
		"each entry below resolves through a workspace lock in" \
		"metacraft-labs/metacraft-manifests, which has published nothing for this" \
		"repo since 2026-08-02; the step fails with 'No workspace lock for codetracer'" \
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

if [ "$build_sites" -gt 0 ]; then
	ok "the workflows still run the non-nix build ($build_sites call sites)"
else
	fail "the workflows still run the non-nix build" \
		"no './non-nix-build/build.sh' step was found -- either the macOS lane was" \
		"removed or the scanner no longer matches it, and this check is vacuous"
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
		if [ "$seen_jobs_key" -eq 1 ]; then
			case "$line" in
			'   '*) ;;
			'  '[a-zA-Z0-9_-]*':')
				flush_mint_step
				scope="${line#  }"
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
readonly EXPECTED_ASSERTIONS=15
if [ "$assertions" -ne "$EXPECTED_ASSERTIONS" ]; then
	printf 'FAIL: ran %d assertions, expected %d\n' "$assertions" "$EXPECTED_ASSERTIONS"
	failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
	printf '%d of %d assertions failed\n' "$failures" "$assertions"
	exit 1
fi
printf 'all %d assertions passed\n' "$assertions"
