#!/usr/bin/env bash
# =============================================================================
# Contract: every `eph-win-x64` job provisions git + Git Bash before it needs
# them.
#
# # Why this file exists
#
# The Windows lane was migrated (CIP-5 Wave 4) from the GitHub-hosted
# `windows-latest` image onto the self-hosted, garm-provisioned `eph-win-x64`
# class. Only the `runs-on:` label moved; the jobs kept assuming the hosted
# image's contract, and `eph-win-x64` does not honour it: it ships neither
# `git` nor `bash` on PATH.
#
# That single missing pair took out three of the four Windows jobs, in three
# places that look unrelated if you read them one at a time:
#
#   windows-bootstrap-smoke   "Validate env.sh syntax"  -> bash: command not found
#   windows-named-pipe-tests  "Install Rust toolchain"  -> bash: command not found
#   windows-rust-components   "Checkout"                -> Input 'submodules' not
#                             supported when falling back to the GitHub REST API
#
# Reproduced identically in runs 30726348404, 31180327493 and 31385899773.
#
# The repo already had the cure — `ci/ensure-git-for-checkout.ps1`, which finds
# or provisions a pinned, digest-verified PortableGit and puts both `cmd/`
# (git.exe) and `bin/` (bash.exe) on GITHUB_PATH. It was wired into exactly one
# job. Its step is the only Windows step that passed throughout the outage.
#
# So the defect is not in the script; it is that four jobs did not run it. That
# is precisely the kind of thing that rots back in silently when a job is added
# or a step is reordered, and it cannot be caught by running the lane — there is
# no Windows host in most development loops, and the lane had no signal for
# months. Hence a static contract, checked on Linux.
#
# # What is asserted
#
#   1. The bootstrap script exists and provisions bash, not just git. (A
#      MinGit-shaped script would satisfy `checkout` and still leave every
#      `shell: bash` step dead.)
#   2. Every job with `runs-on: eph-win-x64` has the bootstrap as its FIRST
#      step. Not merely present: first, counting UNNAMED steps too --
#      `- uses: actions/checkout@v5` with no `name:` is a step, and letting
#      one precede the bootstrap is exactly the regression this file exists
#      to stop. `windows-rust-components` needs git *for* its checkout, and
#      the two smoke jobs need bash in the step right after theirs, so
#      anywhere later is not soon enough.
#   3. The bootstrap step runs under PowerShell. It is the step that puts
#      `bash.exe` on PATH, so it is the one step in the job that cannot use
#      `shell: bash` -- and `shell: bash` here fails in precisely the way the
#      lane was already failing, which would make this suite's green
#      meaningless.
#   4. Each bootstrap step takes its revision from `github.sha` and pins it to
#      an immutable 40-hex value. `github.ref_name` also satisfies a
#      "something is interpolated" reading and is a mutable branch name, so
#      the source of the revision is asserted, not just its shape.
#   5. Each bootstrap step fetches from this repository's own raw.
#      githubusercontent path and from NO other host. The step runs before the
#      checkout exists, so it necessarily fetches over the network and then
#      executes what it downloads; a redirected origin is remote code
#      execution on the runner.
#   6. The set of eph-win-x64 jobs is non-empty (a rename of the runner class
#      must not turn this suite into a vacuous pass).
#   7. Every Windows job that reaches `setup-dev-env` -- directly or through a
#      local composite action -- asks it for a flavor that can exist on
#      Windows. The `nix` flavor cannot: it installs Nix through
#      `DeterminateSystems/nix-installer-action`, which has no Windows platform
#      mapping. `origin-dap-windows` died that way 56 times, in the wrapper
#      action `setup-db-backend-siblings`, which hard-coded `env-flavor: nix`
#      for all six of its callers -- four of them Linux/macOS. Section 4 has
#      its own header with the details.
#   8. The bootstrap turns Windows long-path support on in git's SYSTEM
#      configuration, and verifies it by reading the value back. Section 5 has
#      its own header with the details.
#
# # No mocks
#
# The workflow file itself is the input. Nothing is stubbed, generated or
# reconstructed: the parse runs over `.github/workflows/codetracer.yml` as
# committed, which is the artefact GitHub executes.
#
# Run: bash ci/test/windows-runner-bootstrap-test.sh
# Lane: a step of the `ci-verdict` job (stock ubuntu-latest, bash only -- no
#       Nix, no dev shell), alongside the verdict gate's own self-test.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly REPO_ROOT
WORKFLOW="${1:-$REPO_ROOT/.github/workflows/codetracer.yml}"
readonly WORKFLOW
# Local composite actions a job can reach `setup-dev-env` through. Section 4
# follows that indirection: the flavor a Windows job ends up with is not
# necessarily written in the workflow.
ACTIONS_DIR="${2:-$REPO_ROOT/.github/actions}"
readonly ACTIONS_DIR
BOOTSTRAP_SCRIPT="$REPO_ROOT/ci/ensure-git-for-checkout.ps1"
readonly BOOTSTRAP_SCRIPT

# The exact display name every eph-win-x64 job must open with.
readonly BOOTSTRAP_STEP_NAME="Ensure Git and Git Bash are on PATH"
readonly WINDOWS_RUNNER_LABEL="eph-win-x64"
# Every runner label that lands a job on Windows. `eph-win-x64` is the only one
# in use today; the rest are the labels a Windows job could plausibly be moved
# to (the hosted images the lane came from, and the arm64 class the header note
# says to revisit). Section 4's contract is about the OS, not about one class,
# and must not be escapable by relabelling.
readonly WINDOWS_RUNNER_LABELS="eph-win-x64 eph-win-arm64 windows-latest windows-2025 windows-2022 windows-2019 windows-11-arm"
# The action that materialises a job's dev environment, and the flavor of it
# that cannot exist on Windows.
readonly SETUP_DEV_ENV_USES="metacraft-labs/metacraft-github-actions/setup-dev-env@"
readonly NIX_FLAVOR="nix"
# The flavors `setup-dev-env` accepts, minus `nix`. Anything outside this set
# fails the action's own `Validate env-flavor` step on the runner; asserting it
# here means a typo is a red test rather than a red job.
readonly NON_NIX_FLAVORS="windows-diy reprobuild"
# How many places a Windows job reaches `setup-dev-env` from. Today: four --
# `windows-rust-components` and `windows-headless-test` use it directly, and
# `origin-dap-windows` plus `origin-dap-windows-nightly` reach it through
# `.github/actions/setup-db-backend-siblings`. A floor rather than an equality
# so adding a Windows job is not a test edit, but dropping below it means the
# scanner (or the workflow) changed shape and this contract must be RETARGETED,
# not deleted: with zero sites found, every per-site assertion below vanishes
# and the suite passes while asserting nothing.
readonly MIN_WINDOWS_DEV_ENV_SITES=4
# The only origin the bootstrap may be fetched from. Everything under this
# prefix is this repository at a pinned commit; anything else is somebody
# else's code running on the runner before the checkout has even happened.
readonly BOOTSTRAP_URL_PREFIX="https://raw.githubusercontent.com/metacraft-labs/codetracer/"
# The revision must come from the commit under test. `github.ref_name` is a
# mutable branch name and would still look like "an expression is used here".
# The `${{ }}` below is GitHub Actions' own syntax, quoted verbatim because
# this is the exact text the workflow must contain.
# shellcheck disable=SC2016
readonly BOOTSTRAP_REVISION_BINDING='CODETRACER_GIT_BOOTSTRAP_REVISION: ${{ github.sha }}'

# --- Section 5's needles ----------------------------------------------------
# The function that owns the system-scoped opt-in, and the two `git config`
# argument vectors it must run, quoted as PowerShell source. Asserting the
# DECLARATION FORM rather than the bare word `longpaths` is deliberate: the
# word already appears in this script's own comments and in the job-scoped
# environment channel, so a bare grep is green before the fix exists.
readonly LONGPATHS_FUNCTION="Enable-CodeTracerGitSystemLongPaths"
readonly LONGPATHS_SET_FORM='@("config", "--system", "--replace-all", "core.longpaths", "true")'
readonly LONGPATHS_GET_FORM='@("config", "--system", "--get", "core.longpaths")'
# The comparison that turns the read-back into a gate. `-cne` is PowerShell's
# case-sensitive inequality; git writes the canonical lowercase `true`.
readonly LONGPATHS_READBACK_GUARD='-cne "true"'
# The entry point the opt-in must run from, the CALL it must make there, and
# the statement that call must precede: whatever else changes, the
# configuration has to be in force before the step returns, because the next
# step is the checkout it exists to unblock.
#
# The call is matched, not the function's NAME. The name also appears in the
# entry point's parameter block, as the default of the injection seam, and it
# appears there ABOVE the return -- so a name match is satisfied by an entry
# point that declares the seam and never uses it, and by one that invokes it
# after returning. Both of those mutations survived exactly that reading.
readonly BOOTSTRAP_ENTRY_FUNCTION="Ensure-CodeTracerGitForCheckout"
# `$EnableSystemLongPaths` and `$git` are PowerShell variables quoted verbatim.
# shellcheck disable=SC2016
readonly BOOTSTRAP_ENTRY_INVOCATION='& $EnableSystemLongPaths $git.Path'
readonly BOOTSTRAP_ENTRY_SEAM_DEFAULT="Enable-CodeTracerGitSystemLongPaths -GitPath"
readonly BOOTSTRAP_ENTRY_RETURN='return [PSCustomObject]@{'
# Floors for the two scans section 5 performs. Both exist so that a stripper or
# an extractor that stopped matching FAILS here instead of reporting "no
# violations" over an empty input. The script is ~400 lines; 200 is a floor,
# not a measurement, so ordinary edits never touch it.
readonly MIN_BOOTSTRAP_CODE_LINES=200
readonly MIN_LONGPATHS_FUNCTION_LINES=8

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
# 1. The bootstrap script itself.
# ---------------------------------------------------------------------------
echo "bootstrap script"

if [ -f "$BOOTSTRAP_SCRIPT" ]; then
	ok "ci/ensure-git-for-checkout.ps1 exists"
else
	fail "ci/ensure-git-for-checkout.ps1 exists" \
		"the workflow fetches this path at the run's own commit SHA;" \
		"if it is gone or moved, every eph-win-x64 job fails at its very first step"
fi

if grep -q 'bash\.exe' "$BOOTSTRAP_SCRIPT" 2>/dev/null; then
	ok "the bootstrap provisions Git Bash, not only git"
else
	fail "the bootstrap provisions Git Bash, not only git" \
		"a git-only bootstrap (MinGit) satisfies actions/checkout and still leaves" \
		"every 'shell: bash' step dying with 'bash: command not found'"
fi

# ---------------------------------------------------------------------------
# 2. Parse the workflow's job -> (runs-on, first step name) mapping.
#
# Deliberately a small, explicit scanner rather than a YAML library: this must
# run on a stock runner with bash and nothing else, in the same spirit as
# ci/verdict/required-jobs.sh. It treats any key at exactly two spaces of
# indent as a job -- note it does NOT anchor that to the `jobs:` block, so
# top-level `on:` keys such as `push:` match too; they are harmless because
# they carry no `runs-on:`. Job-level keys sit at four; a step is a six-space
# list item under `steps:`, and its own keys sit at eight.
#
# WHAT THIS SCANNER DOES NOT CATCH: a step that deliberately forges the
# bootstrap's display name. `- uses: actions/checkout@v4` carrying
# `name: Ensure Git and Git Bash are on PATH` is accepted as the first step,
# because the check compares names. It is a guard against ROT -- an unnamed or
# differently-named step drifting in front of the bootstrap, which is how this
# actually goes wrong -- not against an author working around it. Closing that
# would mean asserting on the step's body, the way the WSL-stub contract below
# already does.
#
# Two things this scanner must get right, because both were once wrong:
#
#   * A step is ANY six-space list item, not only `- name: ...`. Reading only
#     named steps made "the first step" mean "the first NAMED step", so an
#     unnamed `- uses: actions/checkout@v5` could be slipped in front of the
#     bootstrap with every assertion still passing.
#   * Six-space list items are only steps while we are inside `steps:`. A
#     job's `needs:` block is also a list of six-space items, and counting one
#     of those as the first step would break every job that has one.
# ---------------------------------------------------------------------------
echo
echo "eph-win-x64 jobs"

declare -a windows_jobs=()
declare -A job_first_step=()
declare -A job_bootstrap_body=()
# Jobs carrying a step that deletes the System32 WSL `bash.exe` launcher stub,
# keyed by job -> that step's body. Recognised by BEHAVIOUR, not by step name,
# so renaming the step cannot drop it out of the contract.
declare -a wsl_stub_jobs=()
declare -A job_wsl_stub_body=()
# Every job whose `runs-on:` names a Windows runner, by ANY of the labels in
# WINDOWS_RUNNER_LABELS -- not just the one class the lane happens to use
# today. Section 4 below walks this set; a job moved to `eph-win-arm64` or
# back onto a hosted `windows-*` image must not fall out of the dev-env
# contract just because the label changed.
declare -a windows_runner_jobs=()
# job -> its steps, each step's list-item text and body concatenated and
# separated by a record separator (\x1e). Section 4 needs the `uses:` of every
# step, which the two contracts above never had to look at.
declare -A job_step_blobs=()

current_job=""
current_runs_on=""
in_steps=""
seen_any_step=""
seen_first_step=""
step_index=0
current_step_name=""
current_step_item=""
current_step_body=""

trim_trailing() {
	local value="$1"
	printf '%s' "${value%"${value##*[![:space:]]}"}"
}

# Close the step that was open, filing its body under the contracts that care
# about it.
flush_step() {
	[ "$step_index" -gt 0 ] || return 0
	if [ "$current_step_name" = "$BOOTSTRAP_STEP_NAME" ]; then
		job_bootstrap_body["$current_job"]+="$current_step_body"
	fi
	if [[ $current_step_body == *'System32\bash.exe'* ]]; then
		job_wsl_stub_body["$current_job"]+="$current_step_body"
	fi
	# Section 4 reads `uses:`, which for an unnamed step lives in the list-item
	# text rather than in the body, so both halves go into the blob.
	job_step_blobs["$current_job"]+="$current_step_item"$'\n'"$current_step_body"$'\x1e'
	current_step_item=""
	current_step_body=""
}

# Record a step boundary: remember the first step of the job whatever it is
# called.
begin_step() {
	local name="$1"
	local item="${2:-}"
	flush_step
	step_index=$((step_index + 1))
	current_step_name="$name"
	current_step_item="$item"
	if [ -z "$seen_any_step" ]; then
		seen_any_step="yes"
		seen_first_step="$name"
	fi
}

# Is this `runs-on:` value a Windows runner? Matched against the label list
# rather than against one hard-coded class, so retiring or adding a Windows
# runner class cannot silently empty section 4's job set.
is_windows_runs_on() {
	local value="$1"
	local label token
	# `runs-on:` is either a scalar label or a flow sequence of labels
	# (`[self-hosted, gpu]`); both forms must be classified, or a Windows job
	# escapes this contract by being written the other way round.
	value="${value//[\[\],]/ }"
	for label in $WINDOWS_RUNNER_LABELS; do
		for token in $value; do
			[ "$token" = "$label" ] && return 0
		done
	done
	return 1
}

flush_job() {
	flush_step
	if [ -n "$current_job" ] && [ "$current_runs_on" = "$WINDOWS_RUNNER_LABEL" ]; then
		windows_jobs+=("$current_job")
		job_first_step["$current_job"]="$seen_first_step"
		if [ -n "${job_wsl_stub_body[$current_job]:-}" ]; then
			wsl_stub_jobs+=("$current_job")
		fi
	fi
	if [ -n "$current_job" ] && is_windows_runs_on "$current_runs_on"; then
		windows_runner_jobs+=("$current_job")
	fi
	step_index=0
	current_step_name=""
	current_step_item=""
	current_step_body=""
}

while IFS= read -r line; do
	# A new job key: exactly two spaces, an identifier, a colon, nothing else.
	if [[ $line =~ ^\ \ ([A-Za-z0-9_-]+):[[:space:]]*$ ]]; then
		flush_job
		current_job="${BASH_REMATCH[1]}"
		current_runs_on=""
		in_steps=""
		seen_any_step=""
		seen_first_step=""
		continue
	fi
	[ -n "$current_job" ] || continue

	# A job-level key (four spaces). `steps:` opens the step list; every other
	# job-level key closes it, so `needs:`/`strategy:` list items are never
	# mistaken for steps.
	if [[ $line =~ ^\ \ \ \ ([A-Za-z0-9_-]+):[[:space:]]*([^#]*) ]]; then
		job_key="${BASH_REMATCH[1]}"
		job_value="$(trim_trailing "${BASH_REMATCH[2]}")"
		flush_step
		step_index=0
		current_step_name=""
		if [ "$job_key" = "steps" ]; then
			in_steps="yes"
		else
			in_steps=""
		fi
		if [ "$job_key" = "runs-on" ]; then
			current_runs_on="$job_value"
		fi
		continue
	fi

	[ -n "$in_steps" ] || continue

	# A step: any six-space list item.
	if [[ $line =~ ^\ \ \ \ \ \ -\ (.*)$ ]]; then
		step_item="$(trim_trailing "${BASH_REMATCH[1]}")"
		if [[ $step_item =~ ^name:[[:space:]]+(.*)$ ]]; then
			begin_step "$(trim_trailing "${BASH_REMATCH[1]}")" "$step_item"
		else
			# An unnamed step. Keep the item text so the failure message can
			# point at the thing that was inserted.
			begin_step "<unnamed step #$((step_index + 1)): - $step_item>" "$step_item"
		fi
		continue
	fi

	# `name:` as a step KEY (eight spaces) rather than as the list item, e.g.
	# `- uses: ...` followed by `name: ...`. Attribute it to the step that is
	# open, so such a step is reported by its real name rather than as
	# unnamed. This does NOT stop a step from claiming the bootstrap's name --
	# see the note at the top: the first-step check is a rot guard, not an
	# adversarial one. Unambiguous at this indent: `with:`/`env:` bodies and
	# `run: |` blocks in this workflow are indented further.
	if [[ $line =~ ^\ \ \ \ \ \ \ \ name:[[:space:]]+(.*)$ ]]; then
		current_step_name="$(trim_trailing "${BASH_REMATCH[1]}")"
		if [ "$step_index" -eq 1 ]; then
			seen_first_step="$current_step_name"
		fi
		continue
	fi

	current_step_body+="$line"$'\n'
done <"$WORKFLOW"
flush_job

if [ "${#windows_jobs[@]}" -gt 0 ]; then
	ok "the workflow still declares ${WINDOWS_RUNNER_LABEL} jobs (${#windows_jobs[@]} of them)"
else
	fail "the workflow still declares ${WINDOWS_RUNNER_LABEL} jobs" \
		"either the runner class was renamed -- in which case this contract must be" \
		"retargeted, not deleted -- or the parser above no longer matches the file." \
		"Passing with zero jobs would assert nothing."
fi

for job in "${windows_jobs[@]}"; do
	first="${job_first_step[$job]:-}"
	if [ "$first" = "$BOOTSTRAP_STEP_NAME" ]; then
		ok "$job opens with \"$BOOTSTRAP_STEP_NAME\""
	else
		fail "$job opens with \"$BOOTSTRAP_STEP_NAME\"" \
			"its first step is \"${first:-<none>}\"." \
			"git must be on PATH before actions/checkout (submodules need a real git)" \
			"and bash before the first 'shell: bash' step, so later is not soon enough."
	fi

	body="${job_bootstrap_body[$job]:-}"

	# The step that provisions bash cannot itself be a bash step. `shell:
	# bash` here fails with the very error the bootstrap exists to prevent --
	# and it fails before running, so the rest of this file's assertions would
	# still hold while the lane stayed dead.
	if [[ $body == *'shell: powershell'* || $body == *'shell: pwsh'* ]]; then
		ok "$job's bootstrap runs under PowerShell"
	else
		fail "$job's bootstrap runs under PowerShell" \
			"this is the step that puts bash.exe on PATH, so it is the one step in" \
			"the job that must not be 'shell: bash' -- on eph-win-x64 that dies with" \
			"'bash: command not found' before it can provision anything."
	fi

	if [[ $body == *'^[0-9a-f]{40}$'* ]]; then
		ok "$job's bootstrap requires an immutable 40-hex revision"
	else
		fail "$job's bootstrap requires an immutable 40-hex revision" \
			"the script is fetched over the network before any checkout exists;" \
			"a mutable ref would let the bootstrap drift from the commit under test."
	fi

	# ...and the revision must be the commit under test. A 40-hex *shape*
	# check alone is satisfied by any expression, including `github.ref_name`,
	# which is a mutable branch name.
	if [[ $body == *"$BOOTSTRAP_REVISION_BINDING"* ]]; then
		ok "$job's bootstrap takes its revision from github.sha"
	else
		fail "$job's bootstrap takes its revision from github.sha" \
			"expected the literal '$BOOTSTRAP_REVISION_BINDING'." \
			"github.ref_name and friends are mutable: the runner would execute" \
			"whatever that branch points at when the step happens to run, not the" \
			"commit this workflow is testing."
	fi

	if [[ $body == *'ci/ensure-git-for-checkout.ps1'* ]]; then
		ok "$job's bootstrap fetches ci/ensure-git-for-checkout.ps1"
	else
		fail "$job's bootstrap fetches ci/ensure-git-for-checkout.ps1" \
			"the step name promises git+bash; it must actually run the script that" \
			"provides them."
	fi

	# Every URL in the step must be this repository's raw path. The step
	# downloads a script and immediately executes it, with no checkout to
	# compare against, so a redirected origin is arbitrary code on the runner.
	bootstrap_urls=()
	while IFS= read -r url; do
		[ -n "$url" ] && bootstrap_urls+=("$url")
	done < <(printf '%s' "$body" | grep -oE "https?://[^\"'[:space:]]+" || true)
	foreign_url=""
	for url in "${bootstrap_urls[@]+"${bootstrap_urls[@]}"}"; do
		case "$url" in
		"$BOOTSTRAP_URL_PREFIX"*) ;;
		*) foreign_url="$url" ;;
		esac
	done
	if [ "${#bootstrap_urls[@]}" -gt 0 ] && [ -z "$foreign_url" ]; then
		ok "$job's bootstrap fetches only from $BOOTSTRAP_URL_PREFIX"
	else
		fail "$job's bootstrap fetches only from $BOOTSTRAP_URL_PREFIX" \
			"${foreign_url:+it also fetches $foreign_url.}" \
			"${foreign_url:-it fetches nothing over https, so it cannot be running the" \
			"bootstrap at all.}" \
			"This step downloads a script and executes it before any checkout exists;" \
			"there is nothing to validate it against, so the origin is the contract."
	fi
done

# ---------------------------------------------------------------------------
# 3. The steps that delete the System32 WSL `bash.exe` launcher stub.
#
# There are two of them (`origin-dap-windows-nightly` and
# `windows-rust-components`) and they do the same job: clear the WSL stub so
# `CreateProcessW`'s System32-first lookup falls through to Git for Windows'
# bash, then make sure `bash` really resolves before the `shell: bash` steps
# below. One of the two was hardened and the other was not, and nothing
# noticed, because nothing was checking. This does.
#
# Matched on behaviour rather than on step name so a rename cannot drop a copy
# out of the contract.
# ---------------------------------------------------------------------------
echo
echo "System32 WSL bash-stub steps"

if [ "${#wsl_stub_jobs[@]}" -gt 0 ]; then
	ok "the workflow still has eph-win-x64 steps that clear the WSL bash stub (${#wsl_stub_jobs[@]})"
else
	fail "the workflow still has eph-win-x64 steps that clear the WSL bash stub" \
		"none were found. Either they were removed -- in which case this contract" \
		"must be retargeted, not deleted -- or the scanner no longer matches." \
		"Passing with zero of them would assert nothing."
fi

# The single-quoted needles inside this loop are PowerShell source quoted
# verbatim; `$env:` and `$gitForWindowsBin` are PowerShell variables and must
# not be expanded by this shell.
# shellcheck disable=SC2016
for job in "${wsl_stub_jobs[@]+"${wsl_stub_jobs[@]}"}"; do
	body="${job_wsl_stub_body[$job]:-}"

	# `C:\Program Files\Git\bin` is the GitHub-hosted windows-latest layout.
	# On eph-win-x64 it does not exist and PortableGit is provisioned under
	# RUNNER_TEMP instead. Appending a non-existent directory to GITHUB_PATH
	# succeeds silently, which is what made the original breakage surface
	# several steps away as `bash: command not found`.
	if [[ $body == *'Add-Content -Path $env:GITHUB_PATH -Value "C:\Program Files\Git\bin"'* ]]; then
		fail "$job appends C:\\Program Files\\Git\\bin only if it exists" \
			"it appends the literal path unconditionally. That directory is absent on" \
			"eph-win-x64; the append then succeeds and silently supplies nothing, and" \
			"the failure reappears as 'bash: command not found' in a later step."
	elif [[ $body == *'Test-Path -LiteralPath $gitForWindowsBin -PathType Container'* &&
		$body == *'Add-Content -Path $env:GITHUB_PATH -Value $gitForWindowsBin'* ]]; then
		ok "$job appends C:\\Program Files\\Git\\bin only if it exists"
	else
		fail "$job appends C:\\Program Files\\Git\\bin only if it exists" \
			'expected the directory to be bound to $gitForWindowsBin, tested with' \
			"Test-Path -PathType Container, and appended to GITHUB_PATH only inside" \
			"that test."
	fi

	# ...and having done whatever it can, the step must prove the result.
	if [[ $body == *'Get-Command bash'* && $body == *'throw "No bash on PATH.'* ]]; then
		ok "$job fails loudly if bash still does not resolve"
	else
		fail "$job fails loudly if bash still does not resolve" \
			"every step below this one is 'shell: bash'. Without an explicit check," \
			"a missing bash is reported as whatever that step was trying to do --" \
			"a build or test failure -- rather than as a missing tool."
	fi
done

# ---------------------------------------------------------------------------
# 4. The dev-env flavor every Windows job asks `setup-dev-env` for.
#
# `setup-dev-env` takes an `env-flavor`, and the `nix` one installs Nix through
# `DeterminateSystems/nix-installer-action`. That installer has no Windows
# platform mapping, so on any Windows runner the step dies with
#
#     ArchOs (X64-Windows) doesn't map to a supported Nix platform
#
# ...before the job reaches a single one of its own steps. `origin-dap-windows`
# failed that way 56 times: its "Setup db-backend siblings" step is a thin
# wrapper over `setup-dev-env`, and the wrapper hard-coded `env-flavor: nix`
# for all six of its callers, four of which are Linux/macOS.
#
# The flavor is not a style choice on Windows -- `nix` cannot work there. The
# two flavors that can are `windows-diy` (source the repo's `env.ps1`) and
# `reprobuild`. What a Windows job needs OUT of the action is the cross-repo
# sibling clones, which every flavor performs before it branches on flavor at
# all.
#
# What is asserted:
#
#   a. Every step of a Windows job that reaches `setup-dev-env` -- directly, or
#      through a local composite under `.github/actions/` -- resolves to a
#      concrete flavor. An empty one is not benign: the composite's input has
#      no default, so a caller that forgets it passes the empty string and the
#      action's `Validate env-flavor` step fails the job.
#   b. That flavor is not `nix`, and is one the action accepts.
#   c. The set of such steps is at least MIN_WINDOWS_DEV_ENV_SITES, reached
#      both directly and through a composite. A parser that stopped matching --
#      the local-composite indirection is the fragile half -- would otherwise
#      report "no violations" in exactly the same words as a clean tree.
#
# A local composite that a Windows job references but that does not exist is a
# failure here too: it is the same "the indirection was renamed and nothing
# noticed" defect, seen from the other side.
# ---------------------------------------------------------------------------
echo
echo "Windows jobs' dev-env flavor"

# Strip full-line comments before looking for keys: a `uses:` or `env-flavor:`
# inside a step's explanatory comment is prose, not configuration.
uncommented() {
	printf '%s' "$1" | grep -vE '^[[:space:]]*#' || true
}

# The `uses:` of a step blob, whether it arrived as `- uses: x` or as a
# `uses: x` key under `- name: ...`.
blob_uses() {
	uncommented "$1" |
		grep -oE '(^|[[:space:]-])uses:[[:space:]]*[^[:space:]]+' |
		head -1 |
		sed -E 's/.*uses:[[:space:]]*//'
}

# The `env-flavor:` a blob passes in its `with:` block, verbatim (it may be a
# `${{ inputs.* }}` expression when read out of a composite).
blob_env_flavor() {
	uncommented "$1" |
		grep -oE '^[[:space:]]*env-flavor:[[:space:]]*.*$' |
		head -1 |
		sed -E 's/^[[:space:]]*env-flavor:[[:space:]]*//; s/[[:space:]]+$//'
}

# The `env-flavor:` a composite action passes to `setup-dev-env`, verbatim.
# Scoped to the lines AFTER the `uses:` that names the action: the composite
# also DECLARES an `env-flavor:` input, and reading that declaration instead
# would report every caller as passing the empty string.
composite_env_flavor() {
	awk -v needle="$SETUP_DEV_ENV_USES" '
		/^[[:space:]]*#/ { next }
		index($0, needle) { seen = 1; next }
		seen && /^[[:space:]]*env-flavor:[[:space:]]*/ {
			sub(/^[[:space:]]*env-flavor:[[:space:]]*/, "")
			sub(/[[:space:]]+$/, "")
			print
			exit
		}
	' "$1"
}

# The `default:` of one input of a composite action file, empty when the input
# declares none.
composite_input_default() {
	awk -v want="$2" '
		$0 ~ "^  " want ":[[:space:]]*$" { inblock = 1; next }
		inblock && /^  [A-Za-z0-9_-]+:/ { inblock = 0 }
		inblock && /^[[:space:]]*default:[[:space:]]*/ {
			sub(/^[[:space:]]*default:[[:space:]]*/, "")
			gsub(/^"|"$|^'"'"'|'"'"'$/, "")
			print
			exit
		}
	' "$1"
}

declare -a dev_env_sites=()
declare -a dev_env_sites_direct=()
declare -a dev_env_sites_via_composite=()
declare -A site_flavor=()
declare -A site_detail=()

for job in "${windows_runner_jobs[@]+"${windows_runner_jobs[@]}"}"; do
	while IFS= read -r -d $'\x1e' blob; do
		uses="$(blob_uses "$blob")"
		[ -n "$uses" ] || continue

		site=""
		flavor=""
		detail=""
		case "$uses" in
		*"$SETUP_DEV_ENV_USES"*)
			site="$job (direct)"
			flavor="$(blob_env_flavor "$blob")"
			detail="step passes env-flavor: ${flavor:-<none>}"
			dev_env_sites_direct+=("$site")
			;;
		./.github/actions/*)
			composite_name="${uses#./.github/actions/}"
			composite_file="$ACTIONS_DIR/$composite_name/action.yml"
			if [ ! -f "$composite_file" ]; then
				site="$job (via $composite_name)"
				detail="no action.yml at ${composite_file#"$REPO_ROOT/"}"
				dev_env_sites+=("$site")
				dev_env_sites_via_composite+=("$site")
				site_flavor["$site"]=""
				site_detail["$site"]="$detail"
				continue
			fi
			grep -q "$SETUP_DEV_ENV_USES" "$composite_file" || continue
			site="$job (via $composite_name)"
			composite_flavor="$(composite_env_flavor "$composite_file")"
			if [[ $composite_flavor =~ \$\{\{[[:space:]]*inputs\.([A-Za-z0-9_-]+)[[:space:]]*\}\} ]]; then
				# The composite forwards one of its own inputs: the flavor is
				# whatever the CALLING job passed, or the input's default.
				input_name="${BASH_REMATCH[1]}"
				flavor="$(blob_env_flavor "$blob")"
				if [ -n "$flavor" ]; then
					detail="job passes $input_name: $flavor to $composite_name"
				else
					flavor="$(composite_input_default "$composite_file" "$input_name")"
					detail="job passes no $input_name; composite default is ${flavor:-<none>}"
				fi
			else
				flavor="$composite_flavor"
				detail="$composite_name hard-codes env-flavor: ${flavor:-<none>}"
			fi
			dev_env_sites_via_composite+=("$site")
			;;
		*)
			continue
			;;
		esac

		dev_env_sites+=("$site")
		site_flavor["$site"]="$flavor"
		site_detail["$site"]="$detail"
	done <<<"${job_step_blobs[$job]:-}"
done

if [ "${#dev_env_sites[@]}" -ge "$MIN_WINDOWS_DEV_ENV_SITES" ]; then
	ok "Windows jobs reach setup-dev-env from ${#dev_env_sites[@]} places (>= $MIN_WINDOWS_DEV_ENV_SITES)"
else
	fail "Windows jobs reach setup-dev-env from at least $MIN_WINDOWS_DEV_ENV_SITES places" \
		"found ${#dev_env_sites[@]}. Either a Windows job stopped provisioning its" \
		"siblings through setup-dev-env -- in which case this contract must be" \
		"retargeted, not deleted -- or the scanner no longer matches the file." \
		"Every per-site assertion below is generated from this set, so a short" \
		"one reports 'no violations' while checking nothing."
fi

# The scanner reads `runs-on:` literally, so a job whose runner comes from a
# build matrix (`runs-on: ${{ matrix.runner }}`) is classified by neither
# branch of `is_windows_runs_on`. Today every matrix leg is Linux or macOS. If
# a Windows leg is ever added, this contract must learn to follow the matrix
# rather than quietly stop covering it -- which is what this assertion says out
# loud.
matrix_windows_legs=""
for label in $WINDOWS_RUNNER_LABELS; do
	# Matrix legs are written both as a bare `runner:` key under an `include:`
	# entry and as the first key of one (`- runner: ...`); match either.
	if grep -qE "^[[:space:]]*(-[[:space:]]+)?runner:[[:space:]]*$label([[:space:]]|#|$)" "$WORKFLOW"; then
		matrix_windows_legs="$matrix_windows_legs $label"
	fi
done
if [ -z "$matrix_windows_legs" ]; then
	ok "no build-matrix leg selects a Windows runner behind an expression"
else
	fail "no build-matrix leg selects a Windows runner behind an expression" \
		"found matrix runner value(s):$matrix_windows_legs." \
		"A job with 'runs-on: \${{ matrix.runner }}' is classified by neither" \
		"branch of is_windows_runs_on, so its flavor goes unchecked. Teach the" \
		"scanner to expand the matrix before adding a Windows leg."
fi

if [ "${#dev_env_sites_direct[@]}" -gt 0 ]; then
	ok "at least one Windows job names setup-dev-env directly (${#dev_env_sites_direct[@]})"
else
	fail "at least one Windows job names setup-dev-env directly" \
		"none found, though windows-rust-components and windows-headless-test do." \
		"The direct-use branch of the scanner above has stopped matching."
fi

if [ "${#dev_env_sites_via_composite[@]}" -gt 0 ]; then
	ok "at least one Windows job reaches setup-dev-env through a local composite (${#dev_env_sites_via_composite[@]})"
else
	fail "at least one Windows job reaches setup-dev-env through a local composite" \
		"none found, though origin-dap-windows and origin-dap-windows-nightly reach" \
		"it through .github/actions/setup-db-backend-siblings. THIS is the half that" \
		"hid the outage: the flavor those jobs get is not written in the workflow," \
		"so a scanner that only reads workflow steps sees a clean file."
fi

for site in "${dev_env_sites[@]+"${dev_env_sites[@]}"}"; do
	flavor="${site_flavor[$site]:-}"
	detail="${site_detail[$site]:-}"

	if [ -n "$flavor" ]; then
		ok "$site resolves an env-flavor ($detail)"
	else
		fail "$site resolves an env-flavor" \
			"$detail." \
			"setup-dev-env's own 'Validate env-flavor' step rejects an empty value," \
			"so this fails the job on the runner -- after minutes of checkout."
	fi

	flavor_ok=""
	for candidate in $NON_NIX_FLAVORS; do
		[ "$flavor" = "$candidate" ] && flavor_ok="yes"
	done
	if [ -n "$flavor_ok" ]; then
		ok "$site asks for a Windows-capable flavor ($flavor)"
	elif [ "$flavor" = "$NIX_FLAVOR" ]; then
		fail "$site asks for a Windows-capable flavor" \
			"it asks for '$NIX_FLAVOR' ($detail)." \
			"The nix flavor installs Nix via DeterminateSystems/nix-installer-action," \
			"which has no Windows mapping: the step dies with 'ArchOs (X64-Windows)" \
			"doesn't map to a supported Nix platform' before the job runs anything of" \
			"its own. Use one of: $NON_NIX_FLAVORS."
	else
		fail "$site asks for a Windows-capable flavor" \
			"it asks for '${flavor:-<none>}' ($detail), which setup-dev-env does not" \
			"accept. Use one of: $NON_NIX_FLAVORS."
	fi
done

# ---------------------------------------------------------------------------
# 5. The SYSTEM-scoped Windows long-path opt-in inside the bootstrap.
#
# Git for Windows refuses any path longer than MAX_PATH (260 characters) with
#
#     error: unable to create file <path>: Filename too long
#
# unless `core.longpaths` is true. That opt-in is GIT'S OWN and is not the
# machine-wide `LongPathsEnabled` registry policy: Git for Windows gates its
# `\\?\` path expansion on this configuration key and fails in exactly the way
# above even on a host where the OS policy is already on. The registry policy
# is for every OTHER tool; this key is for git.
#
# codetracer's `.gitmodules` nests submodules that themselves recurse, under a
# workspace that already starts at `C:\actions-runner\_work\codetracer\
# codetracer\`, so the depth is not marginal -- `submodules: recursive` lands
# past 260 characters, and the eph-win-x64 jobs failed with
#
#     submodule update failed ... Filename too long
#
# The bootstrap already exports the same setting through the numbered
# `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n` environment
# channel (`Add-CodeTracerGitLongPathEnvironment`), and that is NOT what this
# section is about. The two channels cover different processes and neither is
# redundant:
#
#   * the environment channel is process state. It reaches git processes that
#     are launched with it intact, which is every git a `run:` step of this job
#     spawns.
#   * the system configuration is a FILE. Every git process on the machine
#     reads it, whatever environment it was handed and whoever its parent is.
#
# `actions/checkout` is a node action with its own git invocation, not a child
# of the bootstrap, and the submodule processes underneath it are two more
# levels removed again. The system scope is the channel that does not depend on
# any of that plumbing surviving.
#
# What is asserted, against the committed script rather than against a mock:
#
#   a. The two `git config` argument vectors are present in CODE (comments
#      stripped), in the `--system` scope, with the value `true`.
#   b. The value is READ BACK and the script fails when it is not `true`. A
#      `git config` that exits 0 without persisting -- an unwritable system
#      config, a scope the runner's account cannot reach -- would otherwise
#      leave the job to fail minutes later, in the checkout, with the original
#      "Filename too long".
#   c. Neither the write nor the read-back is swallowed: no `SilentlyContinue`
#      anywhere in that function.
#   d. The opt-in runs from the bootstrap's entry point, before it returns --
#      i.e. inside the step that precedes `actions/checkout` (section 2 pins
#      that the bootstrap step is the job's first). Ordering is the whole
#      point: configuration installed after the checkout configures nothing
#      that the checkout needed.
#   e. Every eph-win-x64 job actually runs this script, counted rather than
#      assumed.
#
# NOT PROVEN HERE: that git accepts the write on a real eph-win-x64 runner.
# `--system` writes into the git installation's own config, and whether the
# runner account may do so is a property of that host. The read-back is the
# part of that question this repository can answer, and it answers it at the
# earliest step of the job rather than in the middle of a checkout.
# ---------------------------------------------------------------------------
echo
echo "system-scoped long-path opt-in"

# Full-line comments are prose, not configuration -- the same rule section 4
# already applies to `uses:`. The floor asserted immediately below is what
# makes a stripper that matched everything (or nothing) a FAILURE rather than a
# vacuous pass.
bootstrap_code="$(grep -vE '^[[:space:]]*(#.*)?$' "$BOOTSTRAP_SCRIPT" 2>/dev/null || true)"
bootstrap_code_lines="$(printf '%s\n' "$bootstrap_code" | grep -c . || true)"
if [ "$bootstrap_code_lines" -ge "$MIN_BOOTSTRAP_CODE_LINES" ]; then
	ok "the bootstrap exposes $bootstrap_code_lines lines of code to scan (>= $MIN_BOOTSTRAP_CODE_LINES)"
else
	fail "the bootstrap exposes at least $MIN_BOOTSTRAP_CODE_LINES lines of code to scan" \
		"found $bootstrap_code_lines. Either the script was gutted, or the" \
		"comment stripper above stopped matching -- and every assertion in this" \
		"section reads from that same stripped text, so a short scan reports" \
		"'not found' for reasons that have nothing to do with the contract."
fi

# How many lines of CODE mention the system scope at all. Two are required (the
# write and the read-back); asserting the count before asserting the forms
# means a fix that collapsed to a single unverified write is visible as such.
system_scope_lines="$(printf '%s\n' "$bootstrap_code" | grep -cF -- '"--system"' || true)"
if [ "$system_scope_lines" -ge 2 ]; then
	ok "the bootstrap configures git's --system scope on $system_scope_lines lines of code"
else
	fail "the bootstrap configures git's --system scope on at least 2 lines of code" \
		"found $system_scope_lines. The opt-in has to be written AND read back," \
		"and both halves name the scope. Anything less is either missing or" \
		"unverified. Note that a --local or --global opt-in does not help: the" \
		"deep paths are inside submodules, and a submodule is its own repository" \
		"with its own config, cloned by a process that never reads the" \
		"superproject's."
fi

if grep -qF -- "$LONGPATHS_SET_FORM" <<<"$bootstrap_code"; then
	ok "the bootstrap enables core.longpaths in the system scope"
else
	fail "the bootstrap enables core.longpaths in the system scope" \
		"expected the literal argument vector" \
		"  $LONGPATHS_SET_FORM" \
		"in code (not in a comment). Without core.longpaths, git refuses paths" \
		"over 260 characters with 'Filename too long' regardless of the" \
		"LongPathsEnabled OS policy, and actions/checkout's recursive submodule" \
		"update is where codetracer crosses that line."
fi

if grep -qF -- "$LONGPATHS_GET_FORM" <<<"$bootstrap_code"; then
	ok "the bootstrap reads the system core.longpaths value back"
else
	fail "the bootstrap reads the system core.longpaths value back" \
		"expected the literal argument vector" \
		"  $LONGPATHS_GET_FORM" \
		"in code (not in a comment). A write that is not read back can report" \
		"success and persist nothing; the job then dies minutes later inside the" \
		"checkout, with the original error and no hint of the cause."
fi

# The function that owns both halves, extracted so the remaining assertions are
# scoped to it rather than to the file. `^}` closes it: this script indents
# every nested block.
ps_function_body() { # <file> <function-name>
	awk -v name="$2" '
		$0 ~ "^function " name " \\{" { inside = 1; next }
		inside && /^\}/ { inside = 0; next }
		inside { print }
	' "$1"
}

longpaths_body="$(ps_function_body "$BOOTSTRAP_SCRIPT" "$LONGPATHS_FUNCTION")"
longpaths_body_lines="$(printf '%s\n' "$longpaths_body" | grep -c . || true)"
if [ "$longpaths_body_lines" -ge "$MIN_LONGPATHS_FUNCTION_LINES" ]; then
	ok "$LONGPATHS_FUNCTION has a $longpaths_body_lines-line body to inspect (>= $MIN_LONGPATHS_FUNCTION_LINES)"
else
	fail "$LONGPATHS_FUNCTION has at least $MIN_LONGPATHS_FUNCTION_LINES lines of body to inspect" \
		"found $longpaths_body_lines. Either the function is gone or renamed --" \
		"in which case this contract must be retargeted, not deleted -- or the" \
		"extractor above no longer matches. The two assertions below read from" \
		"this body, so an empty one would report a missing guard that is in fact" \
		"present, or (worse, after a needle edit) find nothing to complain about."
fi

if grep -qF -- "$LONGPATHS_READBACK_GUARD" <<<"$longpaths_body" &&
	grep -q 'throw' <<<"$longpaths_body"; then
	ok "$LONGPATHS_FUNCTION fails the step when the read-back is not 'true'"
else
	fail "$LONGPATHS_FUNCTION fails the step when the read-back is not 'true'" \
		"expected the read-back to be compared with '$LONGPATHS_READBACK_GUARD' and" \
		"a 'throw' to follow. Reading the value and then ignoring it is the same" \
		"as not reading it: the step goes green and the checkout still fails."
fi

if grep -q 'SilentlyContinue' <<<"$longpaths_body"; then
	fail "$LONGPATHS_FUNCTION does not swallow a failed configuration write" \
		"it contains 'SilentlyContinue'. This step exists to fail loudly at the" \
		"top of the job instead of quietly at the checkout; suppressing the error" \
		"restores exactly the failure mode it was added to remove."
else
	ok "$LONGPATHS_FUNCTION does not swallow a failed configuration write"
fi

# Ordering. The opt-in has to be installed by the entry point, before it hands
# control back -- the very next step is the checkout.
entry_body="$(ps_function_body "$BOOTSTRAP_SCRIPT" "$BOOTSTRAP_ENTRY_FUNCTION")"
line_of() { # <text> <fixed-needle> -> 1-based line, or 0
	local found
	found="$(printf '%s\n' "$1" | grep -nF -- "$2" | head -1 | cut -d: -f1)"
	printf '%s' "${found:-0}"
}
entry_enable_line="$(line_of "$entry_body" "$BOOTSTRAP_ENTRY_INVOCATION")"
entry_return_line="$(line_of "$entry_body" "$BOOTSTRAP_ENTRY_RETURN")"
if [ "$entry_enable_line" -gt 0 ] &&
	[ "$entry_return_line" -gt 0 ] &&
	[ "$entry_enable_line" -lt "$entry_return_line" ]; then
	ok "$BOOTSTRAP_ENTRY_FUNCTION runs the opt-in before it returns"
else
	fail "$BOOTSTRAP_ENTRY_FUNCTION runs the opt-in before it returns" \
		"'$BOOTSTRAP_ENTRY_INVOCATION' is at line ${entry_enable_line} of the entry" \
		"point's body and its 'return' is at line ${entry_return_line} (0 means not" \
		"found). A seam that is declared but never invoked configures nothing, and" \
		"one invoked after the return runs never. Either way actions/checkout -- the" \
		"very next step -- gets the git it would have got without this script."
fi

# ...and that seam has to lead to the real function. Its default is what runs
# when nothing is injected, which is every case except the tests.
if grep -qF -- "$BOOTSTRAP_ENTRY_SEAM_DEFAULT" <<<"$entry_body"; then
	ok "$BOOTSTRAP_ENTRY_FUNCTION's opt-in seam defaults to $LONGPATHS_FUNCTION"
else
	fail "$BOOTSTRAP_ENTRY_FUNCTION's opt-in seam defaults to $LONGPATHS_FUNCTION" \
		"expected '$BOOTSTRAP_ENTRY_SEAM_DEFAULT' in the entry point's parameter" \
		"block. The injection seam exists so the tests can observe the call; if its" \
		"default no longer reaches the function, the tests keep passing on an" \
		"injected stub while the real runner configures nothing."
fi

# ...and the jobs that need it must actually be running this script. Counted,
# not assumed: section 2's per-job assertions are generated from the same set,
# so if that set were ever empty they would all vanish silently.
bootstrap_running_jobs=0
for job in "${windows_jobs[@]+"${windows_jobs[@]}"}"; do
	case "${job_bootstrap_body[$job]:-}" in
	*"ci/ensure-git-for-checkout.ps1"*) bootstrap_running_jobs=$((bootstrap_running_jobs + 1)) ;;
	esac
done
if [ "$bootstrap_running_jobs" -gt 0 ] &&
	[ "$bootstrap_running_jobs" -eq "${#windows_jobs[@]}" ]; then
	ok "all ${#windows_jobs[@]} ${WINDOWS_RUNNER_LABEL} jobs run the bootstrap that installs the opt-in"
else
	fail "all ${WINDOWS_RUNNER_LABEL} jobs run the bootstrap that installs the opt-in" \
		"$bootstrap_running_jobs of ${#windows_jobs[@]} do." \
		"A job that skips the bootstrap gets neither git, nor bash, nor the" \
		"long-path opt-in -- and a zero here would mean this whole section is" \
		"asserting things about a script nothing runs."
fi

# ---------------------------------------------------------------------------
# Every eph-win-x64 job must BOUND itself.
#
# Omitting `timeout-minutes` does not mean "no limit", it means GitHub's
# DEFAULT limit of 360 minutes, and this lane has already paid that in full.
# In run 33880354195 (2026-09-04) `windows-rust-components` sat in `Setup dev
# env` from 14:37:32 to 20:05:35 and `origin-DAP (materialized Python,
# Windows)` sat in `Setup db-backend siblings` from 14:20:59 to 20:05:50.
# Neither failed; both were terminated by that default six hours in, having
# produced no verdict -- and because this workflow's concurrency group is
# per-branch, they held `Codetracer CI-dev` `in_progress` for the whole window
# and starved every later push to `dev` behind a job that was never going to
# report.
#
# So the assertion is not "a timeout exists" but "a timeout exists AND is
# genuinely lower than the default it replaces". A job that sets 360 has
# written the failure mode down rather than fixed it, and is failed here by
# name.
# ---------------------------------------------------------------------------
echo
echo "${WINDOWS_RUNNER_LABEL} jobs bound their own runtime"

readonly GITHUB_DEFAULT_JOB_TIMEOUT_MINUTES=360

job_timeout_minutes() {
	awk -v want="$1" '
		/^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
			name = $1
			sub(/:$/, "", name)
			in_job = (name == want)
			next
		}
		in_job && /^    timeout-minutes:[[:space:]]*[0-9]+[[:space:]]*$/ {
			print $2
			exit
		}
	' "$WORKFLOW"
}

for job in "${windows_jobs[@]+"${windows_jobs[@]}"}"; do
	timeout_value="$(job_timeout_minutes "$job")"
	if [ -z "$timeout_value" ]; then
		fail "$job declares timeout-minutes" 			"without it the job inherits GitHub's ${GITHUB_DEFAULT_JOB_TIMEOUT_MINUTES}-minute default," 			"which is the six hours this job already spent holding the branch's" 			"concurrency group in run 33880354195 without ever reporting."
	elif [ "$timeout_value" -ge "$GITHUB_DEFAULT_JOB_TIMEOUT_MINUTES" ]; then
		fail "$job bounds itself below GitHub's default" 			"timeout-minutes: $timeout_value is not lower than the" 			"${GITHUB_DEFAULT_JOB_TIMEOUT_MINUTES}-minute default it is supposed to replace," 			"so this job can still starve the concurrency group for six hours."
	else
		ok "$job bounds itself (timeout-minutes: $timeout_value)"
	fi
done

# ---------------------------------------------------------------------------
# Self-accounting: a contract that is deleted or short-circuited must not leave
# this script reporting success on fewer checks than it claims. Four fixed
# assertions (script exists, script provisions bash, job set non-empty, WSL
# stub-step set non-empty), SEVEN per Windows job (six bootstrap/WSL contracts
# plus the timeout-minutes bound), two per WSL stub step, four
# fixed dev-env-flavor assertions (site count, no matrix-hidden Windows leg,
# one direct, one via composite), two per dev-env site, and ten fixed
# long-path assertions (code-line floor, system-scope line count, the write
# form, the read-back form, the function-body floor, the read-back guard, no
# suppression, ordering inside the entry point, the seam's default, and the
# jobs that run the bootstrap).
# ---------------------------------------------------------------------------
echo
expected_assertions=$((4 + 7 * ${#windows_jobs[@]} + 2 * ${#wsl_stub_jobs[@]} + \
	4 + 2 * ${#dev_env_sites[@]} + 10))
if [ "$assertions" -ne "$expected_assertions" ]; then
	printf 'FAIL: ran %d assertions, expected %d\n' "$assertions" "$expected_assertions"
	failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
	printf '%d of %d assertions failed\n' "$failures" "$assertions"
	exit 1
fi
printf 'all %d assertions passed\n' "$assertions"
