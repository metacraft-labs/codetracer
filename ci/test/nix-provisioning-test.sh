#!/usr/bin/env bash
# =============================================================================
# Contract: a job that runs `nix` installs Nix first.
#
# # The defect
#
# `push-gpg-public-key` and `push-install-script` go straight from
# `actions/checkout` to
#
#     nix develop .#devShells.x86_64-linux.default --command aws ... s3 cp ...
#
# with no Nix-provisioning step in between. Every other nix job in this
# repository has one -- `./.github/actions/setup-nix`, or a `setup-dev-env`
# with `env-flavor: nix`, or one of the composites that wraps it. Those two do
# not, so they use whatever `nix` the runner image happens to have, configured
# however the image happens to configure it. On `eph-linux-x64` that
# configuration does not enable the experimental features `nix develop` needs:
#
#     error: experimental Nix feature 'nix-command' is disabled;
#     add '--extra-experimental-features nix-command' to enable it
#     ##[error]Process completed with exit code 1.
#
# Both jobs have failed this way in every one of the last twelve completed
# `dev` runs. It reads as a runner defect and is not one: `setup-nix` writes
# the experimental-features line (along with the Attic substituter and its
# public key), and these two jobs never call it.
#
# The fix is one step each. This contract is what stops the next
# nix-using job from being written without it -- the omission is invisible in
# review precisely because `nix develop` looks self-contained.
#
# # What is asserted
#
#   1. Every workflow job that invokes `nix` in a `run:` step has a
#      Nix-provisioning step earlier in the SAME job.
#   2. The scanner still finds the jobs it scans for (an exact count), so a
#      rewording that stops it matching is a failure rather than a vacuous pass.
#
# # Scope
#
# `run:` steps only, and only `nix` as the first word of a command. A composite
# action that runs nix is provisioned by its caller, which assertion 1 covers
# from the caller's side.
#
# # No mocks
#
# `.github/workflows/*.yml` as committed is the input.
#
# Run: bash ci/test/nix-provisioning-test.sh
# Lane: a step of `lint-bash` (pure bash, no nix, no network).
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly REPO_ROOT
WORKFLOW_DIR="${1:-$REPO_ROOT/.github/workflows}"
readonly WORKFLOW_DIR

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

echo "every job that runs nix installs Nix first"

# The step spellings that leave a configured Nix behind. `setup-nix` is the
# direct one; `setup-dev-env` installs Nix when its `env-flavor` is `nix`, and
# the two local composites are thin wrappers over it. `nix-installer-action` is
# what all of them ultimately call, named here so a job that calls it directly
# is not reported.
is_provisioning_step() { # $1 = a stripped YAML line
	case "$1" in
	*'.github/actions/setup-nix'*) return 0 ;;
	# What `.github/actions/setup-nix` wraps, and the OTHER upstream action
	# beside it: `push-tag` and `create-release` call `install-nix@main`
	# directly. Leaving this spelling out made the scanner report
	# `create-release` as unprovisioned when it was not -- a false positive
	# that nearly had a redundant second Install Nix step committed to it.
	*'nixos-modules/.github/setup-nix'*) return 0 ;;
	*'nixos-modules/.github/install-nix'*) return 0 ;;
	# The same two actions under the repository's CURRENT name. nixos-modules
	# was renamed devops-modules, and `create-release` and `push-tag` now call
	# `devops-modules/.github/install-nix@dev` -- a spelling the entries above
	# do not match, so the scanner reported `create-release` as unprovisioned
	# when its Install Nix step is right there. That is the same false positive
	# described above, reintroduced by the rename rather than by a new job.
	# The old spellings stay: GitHub redirects a renamed repository, so a step
	# still naming nixos-modules is still genuinely provisioned.
	*'devops-modules/.github/setup-nix'*) return 0 ;;
	*'devops-modules/.github/install-nix'*) return 0 ;;
	# Release jobs use the shared action's scoped Git authentication as well
	# as its Nix installation and configuration.
	*'metacraft-github-actions/setup-nix'*) return 0 ;;
	*'metacraft-github-actions/setup-dev-env'*) return 0 ;;
	*'.github/actions/setup-db-backend-siblings'*) return 0 ;;
	*'DeterminateSystems/nix-installer-action'*) return 0 ;;
	esac
	return 1
}

# The other direction: a composite action of this repo's that CONSUMES Nix
# without any `run: nix ...` line a workflow scanner can see.
#
# `.github/actions/provision-repro-lock-siblings` is the case that matters.
# It clones the lock-pinned dependency siblings by running `repro develop
# --all` inside `nix develop .#ci`, because `repro` comes from this repo's own
# dev shell (nix/shells/ci-base.nix). Its predecessor, `setup-isonim-siblings`,
# was listed as a PROVISIONER above, which was wrong in both directions: it
# installed no Nix, and after the switch the successor needs Nix installed
# BEFORE it rather than after. Naming it here is what makes "provision Nix
# first" cover the step, so a future edit that hoists it back above `Install
# Nix` fails this suite instead of failing in CI with "nix: command not found".
is_nix_consuming_step() { # $1 = a stripped YAML line
	case "$1" in
	*'.github/actions/provision-repro-lock-siblings'*) return 0 ;;
	esac
	return 1
}

nix_jobs=()
unprovisioned=()

for wf in "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml; do
	[ -f "$wf" ] || continue
	wf_name="${wf##*/}"
	job=""
	provisioned=0
	job_reported=""
	line_no=0
	while IFS= read -r line || [ -n "$line" ]; do
		line_no=$((line_no + 1))
		stripped="${line#"${line%%[![:space:]]*}"}"
		# YAML comments quote both `nix develop ...` and the action names
		# below all over this repository. Prose provisions nothing and
		# invokes nothing.
		case "$stripped" in '#'*) continue ;; esac

		# Job boundaries are two-space-indented keys under `jobs:`; anything
		# deeper belongs to the job above.
		case "$line" in
		'  '[a-zA-Z0-9_-]*':'*)
			case "$line" in
			'   '*) ;;
			*)
				job="${line#  }"
				job="${job%%:*}"
				provisioned=0
				job_reported=""
				;;
			esac
			;;
		esac

		if is_provisioning_step "$stripped"; then
			provisioned=1
			continue
		fi

		# A step that reaches Nix through a composite action of this repo's
		# rather than through a `run:` line. Recorded exactly like a `nix
		# develop` invocation below, which is what it performs.
		if is_nix_consuming_step "$stripped"; then
			case " ${nix_jobs[*]-} " in
			*" $wf_name:$job "*) ;;
			*) nix_jobs+=("$wf_name:$job") ;;
			esac
			if [ "$provisioned" -eq 0 ] && [ "$job_reported" != "$job" ]; then
				job_reported="$job"
				unprovisioned+=("$wf_name:$line_no: job '$job' reaches nix through a composite action with no Nix-provisioning step before it")
			fi
			continue
		fi

		# A `nix` invocation: `nix` as the first word, either as the whole of
		# a `run:` value or as a line of a `run: |` block.
		case "$stripped" in
		'run: nix '* | 'nix '*)
			# Only the subcommands that need the experimental features.
			case "$stripped" in
			*'nix develop'* | *'nix build'* | *'nix eval'* | *'nix run'* | *'nix shell'* | *'nix flake'* | *'nix profile'*) ;;
			*) continue ;;
			esac
			case " ${nix_jobs[*]-} " in
			*" $wf_name:$job "*) ;;
			*) nix_jobs+=("$wf_name:$job") ;;
			esac
			if [ "$provisioned" -eq 0 ] && [ "$job_reported" != "$job" ]; then
				job_reported="$job"
				unprovisioned+=("$wf_name:$line_no: job '$job' runs nix with no Nix-provisioning step before it")
			fi
			;;
		esac
	done <"$wf"
done

# The number of jobs this scanner is expected to classify as nix-using. Exact,
# in the same spirit as EXPECTED_BUILD_SITES in
# ci/test/sibling-provisioning-test.sh: "no unprovisioned job was found" is
# also true of a scanner that has stopped finding jobs at all.
# 30 -> 31: dev-build gained a multi-line `nix develop ... -c direnv allow`
# step (its native-recorder setup). Its pre-existing build step spelled nix as
# a single-line quoted `- run: "nix develop ..."`, which this scanner does not
# match, so dev-build only now classifies as nix-using. It provisions Nix
# (Install Nix + setup-db-backend-siblings), so the "provisions first" rule holds.
#
# 31 -> 32: `is_nix_consuming_step` adds `lint-nim`, and it is worth saying why
# rather than just bumping the number. Like dev-build's, lint-nim's only nix
# invocation is the quoted one-line form
#
#     - run: "nix develop .#devShells.x86_64-linux.default -c ./ci/lint/nim.sh"
#
# which the `run: nix ` / `nix ` prefix match below does not see: the stripped
# line starts with `- run: "nix`. So the job ran nix and this suite had never
# classified it. `is_nix_consuming_step` reaches it through the composite
# action it now calls, which is how the omission surfaced at all -- the same
# way it reached dev-build, which the direnv step above has since caught by
# its multi-line spelling. The scanner's blind spot to `- run: "..."` is real
# and unfixed; converting it is separate work, and this count is the record
# that it exists.
#
# 32 -> 33: `deploy-get.yml:deploy`, which arrived on this branch with the
# get.codetracer.com installer site when `stable` was merged back into `dev`.
# It is a genuinely new job, not a scanner change: the control run of this
# suite against pristine `origin/dev` classifies 32 and passes both
# assertions, and the merged tree's `found:` list differs from it by exactly
# this one entry. The job invokes `nix develop .#ci --command wrangler pages
# deploy` and provisions Nix first via `./.github/actions/setup-nix`
# immediately after its checkout, so the "provisions first" rule -- the
# assertion that carries the actual invariant -- passed on the merged tree
# before this number was touched. The count is being reconciled to the code,
# not the other way round.
#
# 33 -> 35: release.yml's `linux` and `publish` jobs. Each runs
# ./.github/actions/setup-nix right after its checkout.
#
# 35 -> 39: four codetracer.yml jobs added since, each a new job rather than a
# scanner change (the scanner run over `56afb78d9`'s workflows classifies 35;
# today's list differs by exactly these four, plus cross-repo-tests.yml's
# `shell-recorder-tests` renamed to `recorder-tests` by `4eb8a4b42`, which nets
# to zero). Each provisions Nix before its first `nix` command:
#   - `gpui-window-captures` (`7fbb8d483`): setup-db-backend-siblings, env-flavor nix;
#   - `dev-shell-hygiene` (`2fc6c5764`): ./.github/actions/setup-nix;
#   - `ct-test-certificates` (`3aed1d7cd`): ./.github/actions/setup-nix;
#   - `wasm-recordings` (`76a99d802`): setup-dev-env.
#
# 39 -> 40: sibling-cargo-locks.yml's `sibling-cargo-locks` job (the sibling
# Cargo.lock guard on every branch changes land on, `agents` included). It
# provisions Nix through setup-dev-env, env-flavor nix, before its first `nix`.
#
# 40 -> 41: codetracer.yml's `tui-tests`, the job that runs `just test-tui` and
# `just test-tui-real-terminal` (codetracer-pm issues/2026-11-01-no-ci-lane-
# calls-the-test-tui-recipes.md). A new job, not a scanner change: the found
# list differs from the previous one by exactly this entry. It provisions Nix
# through setup-db-backend-siblings, env-flavor nix, before its first `nix`, as
# `gpui-window-captures` does.
#
# 41 -> 42: codetracer.yml's `isonim-editor-smoke`, the job that runs
# `scripts/isonim-editor-codetracer.sh --smoke` (codetracer-pm issues/2026-11-04-
# shell-gate-coverage-red-on-two-new-scripts.md). A new job, provisioning Nix
# through setup-db-backend-siblings, env-flavor nix, as `tui-tests` does.
#
# 42 -> 43: cache-push.yml's `push-to-attic`, the build-only job that pushes the
# CI dev shell's closure on every push to dev/agents (replacing codetracer.yml's
# never-run push-to-attic). It installs Nix through setup-nix before `nix`.
# tui-tests and gpui-window-captures moved to tui-tests.yml and
# gpui-window-captures.yml the same day; the count does not change for that.
#
# 43 -> 44: ct-build.yml's `ct-build`, which runs build-once and isonim-gpui's
# windowed shim once per run for the TUI and GPUI shards. It provisions Nix
# through setup-db-backend-siblings, env-flavor nix, as those jobs do.
#
# 44 -> 45: visual-replay-tools.yml's `visual-replay-tools`, which builds
# ct-native-replay, ct_gfx_player and ct-mcr once per run for GPUI shard 1 and
# the TUI player shard. It provisions Nix the same way as ct-build.
#
# 45 -> 48: zgui.yml's `linux` and `macos` (67d4140e2a2, the zgui front-end's
# lane) and plugin-transport-darwin.yml's `plugin-transport-darwin`
# (d959a95c0a5). Each installs Nix through ./.github/actions/setup-nix before
# its first `nix`.
#
# 48 -> 49: screen-oracle.yml's `screen-oracle` (e2a37617f76), the PLAT-39
# screen oracle moved out of viewmodel-tests into a job of its own.
#
# 49 -> 50: scenario-inventory.yml's `scenario-inventory`, the scenario
# inventory and linter on pushes to dev/stable and pull requests. It
# installs Nix through ./.github/actions/setup-nix before its `nix shell` for
# Nim and Node.
#
# 50 -> 52: plugin-host-wasm.yml's `linux` and `darwin` (d11479e6b85), which
# build ct-plugin-host and run the WASM plugin packages under it. Each
# installs Nix through ./.github/actions/setup-nix before its first `nix`.
#
# 52 -> 53: codetracer.yml's `viewmodel-tests-wasm`, the second half of
# `viewmodel-tests` split off so each fits its time limit. It installs Nix
# with the same step as the job it came from.
#
# 53 -> 54: darwin-lock-resolve.yml's `resolve` (eafa5b227), which re-solves
# the Apple Silicon lock on a macOS runner. It installs Nix through
# ./.github/actions/setup-nix before its first `nix`.
#
# 54 -> 55: codetracer.yml's `viewmodel-tests-wasm-parity`, PLAT-17's parity
# gate split off `viewmodel-tests-wasm`, which it ran out of time in. It
# installs Nix with the same step as the job it came from.
#
# 55 -> 56: gpui-window-captures.yml's `ctf-p1b-gpui-layout`, which judges
# the GPUI shards' shares of CTF-P1b's story captures together (codetracer-
# specs issues/2026-11-24-gpui-window-captures-shard-1-runs-out-of-its-150-
# minute-bound-in-the-ctf-p1b-step.md). It provisions Nix through
# setup-db-backend-siblings, env-flavor nix, as screen-oracle does.
#
# 56 -> 57: wasm-panes.yml's `wasm-panes`, which builds the renderer's
# WebAssembly panes on Linux on every `agents` and `dev` push and on pull
# requests. It installs Nix through ./.github/actions/setup-nix.
#
# 57 -> 58: zgui.yml's `story-parity` (74cdfab01cf), the story-parity harness
# moved out of the zgui lane so it fits a budget of its own. It runs the
# harness in this repository's dev shell and installs Nix through
# ./.github/actions/setup-nix first.
#
# 58 -> 59: php-recorder-downstream.yml's `php-recorder-downstream`, the
# reusable workflow codetracer-php-recorder calls to run CodeTracer's PHP
# consumers against a recorder change. It installs Nix through
# metacraft-github-actions/setup-dev-env (env-flavor nix) before its first
# `nix`, as launcher-recorder-e2e does.
#
# 59 -> 60: image-diff-downstream.yml's `image-diff-downstream`, the reusable
# workflow codetracer-image-diff calls to run CodeTracer's consumers of the
# FLIP library against a library change. It installs Nix through
# metacraft-github-actions/setup-dev-env (env-flavor nix) before its first
# `nix`, as php-recorder-downstream does.
#
# 60 -> 61: gpui-shell.yml's `gpui-shell`, the `gpui-shell` lane and PLAT-35's
# headless capture, called from codetracer.yml and gpui-shell-agents.yml. It
# provisions Nix through setup-db-backend-siblings, env-flavor nix, as the
# GPUI window shards do.
readonly EXPECTED_NIX_JOBS=61

if [ "${#nix_jobs[@]}" -eq "$EXPECTED_NIX_JOBS" ]; then
	ok "the scanner still classifies the nix-using jobs (${#nix_jobs[@]})"
else
	fail "the scanner still classifies the nix-using jobs" \
		"expected $EXPECTED_NIX_JOBS nix-using job(s), found ${#nix_jobs[@]}." \
		"If a job was added or removed, confirm the new one provisions Nix and update" \
		"EXPECTED_NIX_JOBS. If neither, this scanner has stopped matching what it scans." \
		"found: ${nix_jobs[*]-<none>}"
fi

if [ "${#unprovisioned[@]}" -eq 0 ]; then
	ok "every nix-using job provisions Nix first"
else
	fail "every nix-using job provisions Nix first" \
		"Without it the job uses whatever nix the runner image ships, configured" \
		"however that image configures it -- on eph-linux-x64 that means" \
		"\"error: experimental Nix feature 'nix-command' is disabled\"." \
		"${unprovisioned[@]}"
fi

echo
readonly EXPECTED_ASSERTIONS=2
if [ "$assertions" -ne "$EXPECTED_ASSERTIONS" ]; then
	printf 'FAIL: ran %d assertions, expected %d\n' "$assertions" "$EXPECTED_ASSERTIONS"
	failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
	printf '%d of %d assertions failed\n' "$failures" "$assertions"
	exit 1
fi
printf 'all %d assertions passed\n' "$assertions"
