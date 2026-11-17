#!/usr/bin/env bash
# Push what this job just built to the Attic cache, best effort.
#
#   push-built-closure.sh [--codetracer] [--gcroots DIR] [--flake-inputs]
#
#   --codetracer     #codetracer's output and the realised paths it was built
#                    from (codetracer_build_closure)
#   --gcroots DIR    the closure of every GC root in DIR: the job's realised dev
#                    shells (provision-repro-lock-siblings roots them in
#                    $CT_GCROOT_DIR)
#   --flake-inputs   the flake's locked inputs present in the store
#
# WHY. cache-push.yml pushes after every push to dev or agents, but a cold push
# takes hours and GitHub keeps one pending run, so when the lock moves faster
# than a push finishes the cache lags a lock bump. Run 44048043714's nixos leg
# built Noir, db-backend, backend-manager and codetracer from source (122
# minutes) because no push had finished on the lock 64a81f1844c moved to. A job
# that has just built the closure pushes it itself, so the next run finds it.
#
# NEVER FAILS THE JOB. Every failure is reported and the script exits 0:
#   * it pushes only from the branches the cache is filled from, dev and agents
#     (GITHUB_REF_NAME; CT_CACHE_PUSH_REFS overrides the list), so a pull
#     request or a feature branch never writes to the shared cache;
#   * it needs ATTIC_ENDPOINT, ATTIC_CACHE and ATTIC_TOKEN, and skips without;
#   * each push is retried (attic_push), and the whole run is bounded by
#     CT_CACHE_PUSH_BUDGET seconds (900): no push starts after it and a
#     running one is stopped at it (`timeout`), so the job's own time limit
#     is never what ends it. Given CT_JOB_STARTED_AT (epoch seconds) and
#     CT_JOB_TIMEOUT_MINUTES, the budget is also capped at what the job's limit
#     leaves, less CT_JOB_RESERVE seconds (600) for its post-steps, so a push
#     never runs a job into its limit (which would cancel it).
# Uses `attic` from PATH, else attic-client from this flake's nixpkgs.
# ci/test/push-built-closure-test.sh drives it with a fake attic and nix.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 0

say() { echo "push-built-closure: $*" >&2; }

refs="${CT_CACHE_PUSH_REFS:-dev agents}"
case " ${refs} " in
*" ${GITHUB_REF_NAME:-} "*) ;;
*)
	say "not pushing from '${GITHUB_REF_NAME:-}' (the cache is filled from: ${refs})"
	exit 0
	;;
esac
for v in ATTIC_ENDPOINT ATTIC_CACHE ATTIC_TOKEN; do
	if [ -z "${!v:-}" ]; then
		say "not pushing: ${v} is not set"
		exit 0
	fi
done

# shellcheck source=ci/deploy/attic-push-lib.sh
. ci/deploy/attic-push-lib.sh

if command -v attic >/dev/null 2>&1; then
	attic_base=attic
else
	attic_base="nix shell --inputs-from . nixpkgs#attic-client -c attic"
fi
ATTIC_CMD="$attic_base"
export ATTIC_CMD
# shellcheck disable=SC2086 # ATTIC_CMD is a command line
if ! $ATTIC_CMD login --set-default codetracer-ci "$ATTIC_ENDPOINT" "$ATTIC_TOKEN" >/dev/null; then
	say "attic login failed; not pushing"
	exit 0
fi

budget="${CT_CACHE_PUSH_BUDGET:-900}"
start="$(date +%s)"
if [ -n "${CT_JOB_STARTED_AT:-}" ] && [ -n "${CT_JOB_TIMEOUT_MINUTES:-}" ]; then
	left=$((CT_JOB_TIMEOUT_MINUTES * 60 - (start - CT_JOB_STARTED_AT) - ${CT_JOB_RESERVE:-600}))
	[ "$left" -ge "$budget" ] || budget="$left"
	if [ "$budget" -le 0 ]; then
		say "the job has no time left for a push (limit ${CT_JOB_TIMEOUT_MINUTES} min); not pushing"
		exit 0
	fi
fi
failed=0

push_set() {
	local what="$1"
	shift
	local left=$((budget - ($(date +%s) - start)))
	if [ "$left" -le 0 ]; then
		say "budget of ${budget}s spent; not pushing ${what}"
		failed=1
		return 0
	fi
	ATTIC_CMD="timeout ${left} ${attic_base}"
	if [ "$#" -eq 0 ]; then
		say "nothing to push for ${what}"
		return 0
	fi
	say "pushing ${what}: $# path(s)"
	if ! attic_push "$@"; then
		say "pushing ${what} failed"
		failed=1
	fi
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--codetracer)
		mapfile -t paths < <(nix build --no-link --print-out-paths '.?submodules=1#codetracer' 2>/dev/null)
		mapfile -t -O "${#paths[@]}" paths < <(codetracer_build_closure)
		push_set "#codetracer and its build closure" "${paths[@]}"
		;;
	--gcroots)
		dir="${2:-}"
		shift
		mapfile -t roots < <(find "${dir}" -maxdepth 1 -type l 2>/dev/null | sort)
		if [ "${#roots[@]}" -eq 0 ]; then
			say "no GC roots in '${dir}'"
		else
			mapfile -t paths < <(nix-store -qR "${roots[@]}" 2>/dev/null | sort -u)
			push_set "the dev shells rooted in ${dir}" "${paths[@]}"
		fi
		;;
	--flake-inputs)
		mapfile -t paths < <(flake_input_store_paths)
		push_set "the flake's inputs" "${paths[@]}"
		;;
	*)
		say "unknown argument '$1'"
		failed=1
		;;
	esac
	shift
done

if [ "$failed" = 1 ]; then
	say "done, with failures (this job does not fail for them; the next cache push fills the gap)"
else
	say "done in $(($(date +%s) - start))s"
fi
exit 0
