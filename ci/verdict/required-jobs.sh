#!/usr/bin/env bash
#
# required-jobs.sh — assert that CI actually RAN the jobs it claims to gate on.
#
# WHY THIS EXISTS
# ---------------
# A workflow that fails at *setup* looks nothing like a workflow that fails a
# *test*, and GitHub renders the difference almost invisibly: when an upstream
# job fails, every dependent job is reported `skipped`, and `skipped` is not
# `failure`. The run still goes red, so the branch looks "known broken", while
# the thing that actually went missing — the test suite — leaves no trace at
# all in the UI.
#
# That is exactly how codetracer lost its test coverage. `lint-rust` began
# failing before it linted anything, for either of two independent reasons:
#
#   * `Setup dev env` itself failed — "No repo-workspaces workspace lock for
#     codetracer" — when the pushed commit had no published lock; or
#   * setup succeeded and the very next step died at `direnv: not found`
#     (exit 127), because `direnv` was never declared in the dev shell.
#
# Either way `lint-rust` ended in `failure`, and because `test-non-gui`,
# `nix-build`, `dev-build`, `appimage-build` and `dmg-build` all declared
# `needs: [lint-bash, lint-nim, lint-nix, lint-rust]`, the entire non-GUI
# test suite was `skipped`. On `dev`, `test-non-gui` last actually executed
# on 2026-06-25; every `dev` run after that skipped it. Nobody noticed for
# six weeks, because the run was red either way.
#
# Note that fixing only one of the two causes would not have brought the
# tests back — the two runs pinned in testdata/ differ in exactly that
# respect and produced identical verdicts. That is the case for a gate that
# checks execution directly instead of inferring it from a run's colour.
#
# This gate makes the two cases say different things, loudly:
#
#   * a required job that RAN and FAILED  -> "tests ran and reported failures"
#   * a required job that DID NOT RUN     -> "CI DID NOT RUN THE TESTS"
#
# Both are non-zero. This script never turns a failure into a pass; its only
# job is to stop "no tests ran" from masquerading as ordinary redness.
#
# It also cross-checks the required-jobs manifest against the jobs actually
# present in the payload, so deleting or renaming a gated job out of the
# workflow is itself reported as lost coverage rather than silently accepted.
#
# DESIGN CONSTRAINT
# -----------------
# This gate must not share the failure mode it is watching for. It therefore
# runs on a stock GitHub-hosted runner with nothing but `actions/checkout`,
# `bash` and `jq` — no Nix, no dev shell, no `setup-dev-env`, no workspace
# lock, no cross-repo siblings. If it needed any of those, the very outage it
# exists to report would take it down with everything else.
#
# USAGE
#   required-jobs.sh --needs-json <file|-> [--manifest <file>]
#
#   --needs-json FILE  JSON produced by `toJSON(needs)` in the workflow, or
#                      `-` to read stdin. Shape: {"<job-id>":{"result":"..."}}
#   --manifest FILE    newline-separated required job ids ('#' comments and
#                      blank lines ignored). Default: required-jobs.txt next
#                      to this script.
#
# EXIT CODES
#   0  every required job executed and succeeded
#   1  every required job executed; at least one reported failure
#   2  at least one required job DID NOT RUN (skipped / cancelled / absent)
#   3  usage or environment error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NEEDS_JSON=""
MANIFEST="${SCRIPT_DIR}/required-jobs.txt"

while [[ $# -gt 0 ]]; do
	case "$1" in
	--needs-json)
		NEEDS_JSON="${2:-}"
		shift 2
		;;
	--manifest)
		MANIFEST="${2:-}"
		shift 2
		;;
	-h | --help)
		grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		echo "required-jobs: unknown argument: $1" >&2
		exit 3
		;;
	esac
done

if [[ -z ${NEEDS_JSON} ]]; then
	echo "required-jobs: --needs-json is required (file path or '-')" >&2
	exit 3
fi

if ! command -v jq >/dev/null 2>&1; then
	# Deliberately fatal rather than degraded: a verdict gate that cannot
	# read its input must not report success.
	echo "required-jobs: jq not found on PATH; cannot evaluate the needs payload" >&2
	exit 3
fi

if [[ ! -f ${MANIFEST} ]]; then
	echo "required-jobs: manifest not found: ${MANIFEST}" >&2
	exit 3
fi

payload=""
if [[ ${NEEDS_JSON} == "-" ]]; then
	payload="$(cat)"
else
	if [[ ! -f ${NEEDS_JSON} ]]; then
		echo "required-jobs: needs payload not found: ${NEEDS_JSON}" >&2
		exit 3
	fi
	payload="$(cat "${NEEDS_JSON}")"
fi

if ! printf '%s' "${payload}" | jq -e 'type == "object"' >/dev/null 2>&1; then
	echo "required-jobs: needs payload is not a JSON object" >&2
	exit 3
fi

# Every value must itself be an object, so `.[$j].result` below is always a
# well-defined lookup. Without this, a payload of the shape
# {"test-non-gui": "success"} makes jq abort mid-loop ("Cannot index string")
# and `set -e` kills the script with jq's own exit code — non-zero, but with
# no diagnostic and an exit status this script never documented. A verdict
# gate should fail in exactly the ways it says it fails.
if ! printf '%s' "${payload}" | jq -e 'all(.[]; type == "object")' >/dev/null 2>&1; then
	echo "required-jobs: needs payload has entries that are not objects;" >&2
	echo "  expected {\"<job-id>\": {\"result\": \"...\"}, ...}" >&2
	exit 3
fi

# Read the manifest, stripping comments and blanks.
required=()
while IFS= read -r line || [[ -n ${line} ]]; do
	line="${line%%#*}"
	# shellcheck disable=SC2001 # parameter expansion cannot trim both ends here
	line="$(echo "${line}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
	[[ -z ${line} ]] && continue
	required+=("${line}")
done <"${MANIFEST}"

if [[ ${#required[@]} -eq 0 ]]; then
	echo "required-jobs: manifest ${MANIFEST} lists no jobs; refusing to pass vacuously" >&2
	exit 3
fi

executed=()
failed=()
did_not_run=()
absent=()

for job in "${required[@]}"; do
	result="$(printf '%s' "${payload}" | jq -r --arg j "${job}" '.[$j].result // "__absent__"')"
	case "${result}" in
	success)
		executed+=("${job}")
		;;
	failure)
		executed+=("${job}")
		failed+=("${job}")
		;;
	__absent__)
		# The job is gated in the manifest but is not in the payload at
		# all: it was removed from the workflow, renamed, or dropped
		# from this gate's `needs:` list. That is lost coverage.
		did_not_run+=("${job}")
		absent+=("${job}")
		;;
	*)
		# skipped, cancelled, or anything GitHub adds later.
		did_not_run+=("${job}=${result}")
		;;
	esac
done

emit() {
	echo "$@"
	# The step summary is a nice-to-have rendering surface, never the
	# verdict. If appending to it fails (unset, unwritable, disk full),
	# that must not change what this script concludes: under `set -e` an
	# unguarded append would abort the script *before* the exit-2 branch
	# below and downgrade "CI DID NOT RUN THE TESTS" into a generic
	# exit 1, silencing the one signal this gate exists to raise.
	if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
		echo "$@" >>"${GITHUB_STEP_SUMMARY}" 2>/dev/null || true
	fi
}

emit "required-jobs summary: expected=${#required[@]} executed=${#executed[@]} did-not-run=${#did_not_run[@]} failed=${#failed[@]}"

if [[ ${#did_not_run[@]} -gt 0 ]]; then
	emit ""
	emit "=============================================================="
	emit "  CI DID NOT RUN THE TESTS"
	emit "=============================================================="
	emit ""
	emit "The following required jobs never executed. This is NOT a test"
	emit "failure — it means this commit has NO test coverage at all for"
	emit "the areas these jobs gate, and the red run below tells you"
	emit "nothing about whether the code works."
	emit ""
	for entry in "${did_not_run[@]}"; do
		emit "  - ${entry}"
	done
	if [[ ${#absent[@]} -gt 0 ]]; then
		emit ""
		emit "Of those, these are absent from the needs payload entirely —"
		emit "they were renamed or removed from the workflow, or dropped"
		emit "from this gate's 'needs:' list, without updating the manifest"
		emit "at ${MANIFEST}:"
		for entry in "${absent[@]}"; do
			emit "  - ${entry}"
		done
	fi
	emit ""
	emit "Most common cause: an upstream job died before doing any work —"
	emit "'Setup dev env' failing for want of a repo-workspaces workspace"
	emit "lock on the pushed commit, or a tool missing from the dev shell —"
	emit "so every dependent job was reported 'skipped'. A job stuck in the"
	emit "queue because no runner carries its 'runs-on' label lands here"
	emit "too, as 'cancelled' after GitHub's 24-hour ceiling."
	emit "Fix the setup failure — do not treat this run as a known-red"
	emit "test failure."
	exit 2
fi

if [[ ${#failed[@]} -gt 0 ]]; then
	emit ""
	emit "All ${#required[@]} required jobs executed; ${#failed[@]} reported failures:"
	for entry in "${failed[@]}"; do
		emit "  - ${entry}"
	done
	emit ""
	emit "Tests ran and reported failures. This is ordinary CI redness:"
	emit "read the failing job logs above."
	exit 1
fi

emit ""
emit "All ${#required[@]} required jobs executed and succeeded."
exit 0
