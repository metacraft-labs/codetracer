#!/usr/bin/env bash
#
# build-recorder-siblings.sh -- build the recorder siblings that the
# db-backend recorder tests record with, and prove each artefact exists.
#
# Usage: ci/test/build-recorder-siblings.sh <recorder-repo>...
#
# Each repo must already be checked out next to this one (../<repo>), as the
# CI lane's clone steps and a developer workspace both arrange. Every build
# goes through the recorder's OWN dev shell (`direnv exec <repo>`, which loads
# its flake) and its OWN `just` targets, per cross-repo-builds.md: this script
# says which recorders to build, never how a recorder is built.
#
# - `just prepare-ci` runs first when the recorder defines it. It is the
#   recorder's own CI preparation (the Cairo recorder fetches the corelib it
#   compiles against there); it reads $GITHUB_WORKSPACE as "the checkout whose
#   siblings these are", which is this repository.
# - `just build` then builds it. CARGO_TARGET_DIR is cleared for the build:
#   the db-backend tests find a recorder at <repo>/target/{debug,release}/, and
#   a runner-wide CARGO_TARGET_DIR would put the binary somewhere they never
#   look.
# - The PHP recorder's extension links the trace writer's SHARED library, which
#   is a build product of the codetracer-trace-format-nim sibling; it is built
#   first with that repo's own `nimble buildSharedLib`, in the PHP recorder's
#   shell, which provides nim and nimble for that purpose.
#
# A recorder whose build succeeds but whose artefact is missing fails here,
# naming the path, rather than later as a test that cannot find it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
export GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$REPO_ROOT}"

# The file each recorder's build must leave behind: what the test harness
# (src/db-backend/tests/test_harness/mod.rs, find_*_recorder) opens.
artefact_of() {
	case "$1" in
	codetracer-cairo-recorder) echo target/debug/codetracer-cairo-recorder ;;
	codetracer-circom-recorder) echo target/debug/codetracer-circom-recorder ;;
	codetracer-leo-recorder) echo target/debug/codetracer-leo-recorder ;;
	codetracer-cardano-recorder) echo target/debug/codetracer-cardano-recorder ;;
	codetracer-solana-recorder) echo target/debug/codetracer-solana-recorder ;;
	codetracer-fuel-recorder) echo target/debug/codetracer-fuel-recorder ;;
	codetracer-evm-recorder) echo target/debug/codetracer-evm-recorder ;;
	codetracer-flow-recorder) echo target/debug/codetracer-flow-recorder ;;
	codetracer-miden-recorder) echo target/debug/codetracer-miden-recorder ;;
	codetracer-move-recorder) echo target/debug/codetracer-move-recorder ;;
	codetracer-polkavm-recorder) echo target/debug/codetracer-polkavm-recorder ;;
	codetracer-ton-recorder) echo target/debug/codetracer-ton-recorder ;;
	codetracer-php-recorder) echo ext/modules/codetracer.so ;;
	*) return 1 ;;
	esac
}

die() {
	echo "build-recorder-siblings: $*" >&2
	exit 1
}

[ "$#" -gt 0 ] || die "name at least one recorder repo"
command -v direnv >/dev/null 2>&1 || die "direnv is not on PATH (run inside the codetracer dev shell)"

for repo in "$@"; do
	artefact="$(artefact_of "$repo")" || die "$repo: no known artefact; add it to artefact_of"
	dir="$WORKSPACE_ROOT/$repo"
	[ -f "$dir/Justfile" ] || die "$repo is not checked out at $dir"
	echo "=== $repo"
	started=$SECONDS

	direnv allow "$dir"
	if [ "$repo" = codetracer-php-recorder ]; then
		# The PHP recorder's shell carries nim + nimble for exactly this.
		nim_dir="$WORKSPACE_ROOT/codetracer-trace-format-nim"
		[ -d "$nim_dir" ] || die "$repo needs the codetracer-trace-format-nim sibling at $nim_dir"
		# shellcheck disable=SC2016 # $1 is the inner bash's argument
		direnv exec "$dir" bash -c 'cd "$1" && nimble buildSharedLib' build-shared-lib "$nim_dir"
		[ -f "$nim_dir/libcodetracer_trace_writer.so" ] ||
			die "nimble buildSharedLib succeeded but $nim_dir/libcodetracer_trace_writer.so is missing"
	fi
	if direnv exec "$dir" just --justfile "$dir/Justfile" --working-directory "$dir" --show prepare-ci >/dev/null 2>&1; then
		direnv exec "$dir" just --justfile "$dir/Justfile" --working-directory "$dir" prepare-ci
	fi
	direnv exec "$dir" env -u CARGO_TARGET_DIR \
		just --justfile "$dir/Justfile" --working-directory "$dir" build

	[ -e "$dir/$artefact" ] || die "$repo: \`just build\` succeeded but $dir/$artefact is missing"
	echo "=== $repo: $dir/$artefact ($((SECONDS - started))s)"
done
