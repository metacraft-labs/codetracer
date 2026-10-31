#!/usr/bin/env bash
# =============================================================================
# Runner filesystem lifecycle ownership contract.
#
# Persistent-runner mounts, work-directory permissions and pre-checkout repair
# belong to the host runner configuration. Repository workflow copies run
# before checkout and therefore cannot be updated through normal source uptake;
# they also cannot establish ownership of the host state they mutate.
#
# This is a source-shape gate because the forbidden implementation is YAML.
# The mutations below are justified positive controls for the parser: they
# inject renamed permission and FUSE cleanup into copies of the real workflow
# and require the same predicate used on the real files to reject both.
#
# Run: bash ci/test/runner-lifecycle-ownership-test.sh
# Lane: bash lint; stock bash + grep + python3, no Nix or network.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly REPO_ROOT
readonly LAUNCHER_WORKFLOW="$REPO_ROOT/.github/workflows/launcher-recorder-e2e.yml"
readonly RETIRED_HELPER="$REPO_ROOT/ci/runner/sweep""-readonly-leftovers.sh"
shopt -s nullglob
WORKFLOWS=("$REPO_ROOT"/.github/workflows/*.yml "$REPO_ROOT"/.github/workflows/*.yaml)
readonly WORKFLOWS

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

# One predicate for the rule and both mutation controls. Signatures include
# implementation primitives so renaming the historical steps or log prefix
# does not evade the boundary. They deliberately exclude the separate,
# anchored stale-git-lock sweep, whose product semantics are not this issue.
find_product_lifecycle_implementation() {
	# shellcheck disable=SC2016  # literal workflow source signatures
	grep -nHE \
		'Sweep read-only leftovers from the persistent work directory|Unmount stale FUSE mounts left in the persistent work directory|ro-sweep:|fuse-sweep:|ro_count=|MCL_GITHUB_RUNNER_MOUNTS_FILE|/proc/self/mounts|fusermount3|chmod -R u\+w "?\$\{?(root|RUNNER_WORKSPACE)|ACTIONS_RUNNER_HOOK_JOB_|github-runner-lifecycle-cleanup' \
		"$@" || true
}

printf 'runner filesystem lifecycle is host-owned\n'

if [ "${#WORKFLOWS[@]}" -eq 0 ]; then
	fail "the ownership scan has workflow inputs" \
		"no .github/workflows/*.yml or *.yaml files were found"
else
	ok "the ownership scan covers all ${#WORKFLOWS[@]} workflow file(s)"
fi

real_hits="$(find_product_lifecycle_implementation "${WORKFLOWS[@]}")"
if [ -z "$real_hits" ]; then
	ok "product workflows carry no runner filesystem lifecycle implementation"
else
	fail "product workflows carry no runner filesystem lifecycle implementation" "$real_hits"
fi

if [ ! -e "$RETIRED_HELPER" ]; then
	ok "the obsolete pre-checkout canonical copy is absent"
else
	fail "the obsolete pre-checkout canonical copy is absent" \
		"$RETIRED_HELPER remains even though no checked-out job can invoke it before checkout"
fi

checkout_count="$(grep -cE '^[[:space:]]+uses: actions/checkout@' "$LAUNCHER_WORKFLOW" || true)"
if [ "$checkout_count" -ge 1 ]; then
	ok "the launcher product gate retains its checkout ($checkout_count checkout step(s))"
else
	fail "the launcher product gate retains its checkout" \
		"removing lifecycle work must not remove the gate's repository checkout"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
permission_mutant="$tmp/permission.yml"
mount_mutant="$tmp/mount.yml"
python3 - "$LAUNCHER_WORKFLOW" "$permission_mutant" "$mount_mutant" <<'PY'
import sys

source, permission_destination, mount_destination = sys.argv[1:]
text = open(source, encoding="utf-8").read()
needle = "      - name: Checkout the triggering repository (the workspace root)"
if needle not in text:
    raise SystemExit("launcher workflow has no checkout to mutate")

# One signature each, so that a mutant is caught by the primitive itself and not
# by a variable name a rename would drop.
permission = """      - name: Prepare the directory
        run: |
          chmod -R u+w "$RUNNER_WORKSPACE"
"""
mount = """      - name: Release build resources
        run: |
          fusermount3 -u -z "$RUNNER_WORKSPACE/src/.tup/mnt"
"""
open(permission_destination, "w", encoding="utf-8").write(text.replace(needle, permission + needle, 1))
open(mount_destination, "w", encoding="utf-8").write(text.replace(needle, mount + needle, 1))
PY

permission_hits="$(find_product_lifecycle_implementation "$permission_mutant")"
if [ -n "$permission_hits" ]; then
	ok "the predicate rejects renamed recursive permission cleanup"
else
	fail "the predicate rejects renamed recursive permission cleanup" \
		"the mutation survived, so a renamed copy evades the ownership rule"
fi

mount_hits="$(find_product_lifecycle_implementation "$mount_mutant")"
if [ -n "$mount_hits" ]; then
	ok "the predicate rejects renamed FUSE lifecycle cleanup"
else
	fail "the predicate rejects renamed FUSE lifecycle cleanup" \
		"the mutation survived, so a renamed copy evades the ownership rule"
fi

printf '\nsummary: %d assertion(s), %d failure(s)\n' "$assertions" "$failures"
if [ "$failures" -ne 0 ]; then
	exit 1
fi
printf 'runner lifecycle ownership tests passed\n'
