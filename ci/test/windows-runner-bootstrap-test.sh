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
#      step. Not merely present: first. `windows-rust-components` needs git
#      *for* its checkout, and the two smoke jobs need bash in the step right
#      after theirs, so anywhere later is not soon enough.
#   3. Each bootstrap step pins an immutable 40-hex revision and fetches the
#      script from this repository's own `ci/` path -- the step runs before the
#      checkout exists, so it necessarily fetches over the network, and it must
#      not be able to fetch a mutable ref.
#   4. The set of eph-win-x64 jobs is non-empty (a rename of the runner class
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
# ci/verdict/required-jobs.sh. Jobs are keys at exactly two spaces of indent
# under `jobs:`; a step's `- name:` sits at six spaces under `steps:`.
# ---------------------------------------------------------------------------
echo
echo "eph-win-x64 jobs"

declare -a windows_jobs=()
declare -A job_first_step=()
declare -A job_bootstrap_body=()

current_job=""
current_runs_on=""
seen_first_step=""
in_bootstrap_step=""

flush_job() {
	if [ -n "$current_job" ] && [ "$current_runs_on" = "$WINDOWS_RUNNER_LABEL" ]; then
		windows_jobs+=("$current_job")
		job_first_step["$current_job"]="$seen_first_step"
	fi
}

while IFS= read -r line; do
	# A new job key: exactly two spaces, an identifier, a colon, nothing else.
	if [[ $line =~ ^\ \ ([A-Za-z0-9_-]+):[[:space:]]*$ ]]; then
		flush_job
		current_job="${BASH_REMATCH[1]}"
		current_runs_on=""
		seen_first_step=""
		in_bootstrap_step=""
		continue
	fi
	[ -n "$current_job" ] || continue

	# `runs-on:` for the job (four spaces). Strip any trailing comment.
	if [[ $line =~ ^\ \ \ \ runs-on:[[:space:]]*([^#]*) ]]; then
		current_runs_on="${BASH_REMATCH[1]}"
		# Trim trailing whitespace.
		current_runs_on="${current_runs_on%"${current_runs_on##*[![:space:]]}"}"
		continue
	fi

	# A step's name (six spaces, list item).
	if [[ $line =~ ^\ \ \ \ \ \ -\ name:[[:space:]]+(.*)$ ]]; then
		step_name="${BASH_REMATCH[1]}"
		step_name="${step_name%"${step_name##*[![:space:]]}"}"
		if [ -z "$seen_first_step" ]; then
			seen_first_step="$step_name"
		fi
		if [ "$step_name" = "$BOOTSTRAP_STEP_NAME" ]; then
			in_bootstrap_step="yes"
		else
			in_bootstrap_step=""
		fi
		continue
	fi

	# Any other step boundary ends the bootstrap step's body.
	if [[ $line =~ ^\ \ \ \ \ \ -\  ]]; then
		in_bootstrap_step=""
		continue
	fi

	if [ -n "$in_bootstrap_step" ]; then
		job_bootstrap_body["$current_job"]+="$line"$'\n'
	fi
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
	if [[ $body == *'^[0-9a-f]{40}$'* ]]; then
		ok "$job's bootstrap requires an immutable 40-hex revision"
	else
		fail "$job's bootstrap requires an immutable 40-hex revision" \
			"the script is fetched over the network before any checkout exists;" \
			"a mutable ref would let the bootstrap drift from the commit under test."
	fi
	if [[ $body == *'ci/ensure-git-for-checkout.ps1'* ]]; then
		ok "$job's bootstrap fetches ci/ensure-git-for-checkout.ps1"
	else
		fail "$job's bootstrap fetches ci/ensure-git-for-checkout.ps1" \
			"the step name promises git+bash; it must actually run the script that" \
			"provides them."
	fi
done

# ---------------------------------------------------------------------------
# Self-accounting: a contract that is deleted or short-circuited must not leave
# this script reporting success on fewer checks than it claims. Three fixed
# assertions (script exists, script provisions bash, job set non-empty) plus
# three per Windows job.
# ---------------------------------------------------------------------------
echo
expected_assertions=$((3 + 3 * ${#windows_jobs[@]}))
if [ "$assertions" -ne "$expected_assertions" ]; then
	printf 'FAIL: ran %d assertions, expected %d\n' "$assertions" "$expected_assertions"
	failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
	printf '%d of %d assertions failed\n' "$failures" "$assertions"
	exit 1
fi
printf 'all %d assertions passed\n' "$assertions"
