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
BOOTSTRAP_SCRIPT="$REPO_ROOT/ci/ensure-git-for-checkout.ps1"
readonly BOOTSTRAP_SCRIPT

# The exact display name every eph-win-x64 job must open with.
readonly BOOTSTRAP_STEP_NAME="Ensure Git and Git Bash are on PATH"
readonly WINDOWS_RUNNER_LABEL="eph-win-x64"
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

current_job=""
current_runs_on=""
in_steps=""
seen_any_step=""
seen_first_step=""
step_index=0
current_step_name=""
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
	current_step_body=""
}

# Record a step boundary: remember the first step of the job whatever it is
# called.
begin_step() {
	local name="$1"
	flush_step
	step_index=$((step_index + 1))
	current_step_name="$name"
	if [ -z "$seen_any_step" ]; then
		seen_any_step="yes"
		seen_first_step="$name"
	fi
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
	step_index=0
	current_step_name=""
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
			begin_step "$(trim_trailing "${BASH_REMATCH[1]}")"
		else
			# An unnamed step. Keep the item text so the failure message can
			# point at the thing that was inserted.
			begin_step "<unnamed step #$((step_index + 1)): - $step_item>"
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
# Self-accounting: a contract that is deleted or short-circuited must not leave
# this script reporting success on fewer checks than it claims. Four fixed
# assertions (script exists, script provisions bash, job set non-empty, WSL
# stub-step set non-empty), six per Windows job, and two per WSL stub step.
# ---------------------------------------------------------------------------
echo
expected_assertions=$((4 + 6 * ${#windows_jobs[@]} + 2 * ${#wsl_stub_jobs[@]}))
if [ "$assertions" -ne "$expected_assertions" ]; then
	printf 'FAIL: ran %d assertions, expected %d\n' "$assertions" "$expected_assertions"
	failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
	printf '%d of %d assertions failed\n' "$failures" "$assertions"
	exit 1
fi
printf 'all %d assertions passed\n' "$assertions"
