# shellcheck shell=bash
#
# newest-build.sh — choose the NEWEST build among candidate profiles, not the
# first one that happens to exist.
#
# WHY THIS EXISTS
# ---------------
# Five fixture regenerators carry the same two resolvers, copy-pasted:
#
#     for candidate in \
#         "$WASM_INSTRUMENTER/target/release/ct-instrument" \
#         "$WASM_INSTRUMENTER/target/debug/ct-instrument"; do
#         [ -x "$candidate" ] && CT_INSTRUMENT_BIN="$candidate" && break
#     done
#
# and the same shape again for `session-manager`, which has three candidates
# because it can also come from `src/build-debug/bin`. The files:
#
#   src/db-backend/tests/fixtures/wasm-memory-calldata/regenerate.sh
#   src/db-backend/tests/fixtures/wasm-parity-corpus/regenerate.sh
#   src/db-backend/tests/fixtures/wasm-nan-payloads/regenerate.sh
#   src/db-backend/tests/fixtures/cross_process/account-balance-with-wasm/regenerate.sh
#   src/db-backend/tests/fixtures/cross_process/account-balance-with-wasm/stream-snapshots-demo.sh
#
# `break` on the first executable candidate makes the CHOICE by existence.
# "Prefer release" is a sensible preference between two CURRENT builds; applied
# to whatever is lying on disk it is a preference for whichever is older,
# because `target/release` and `target/debug` are separate directories and
# neither build removes the other. A release binary from an arbitrarily old
# revision outranks a debug one built ten minutes ago.
#
# WHAT IT COSTS HERE, which is worse than the usual stale-artefact story: these
# scripts do not run the binary and check a result, they REGENERATE COMMITTED
# FIXTURES with it. The output is a `.tar.zst` or a trace directory that gets
# committed and then serves as ground truth for parity assertions. A stale
# `ct-instrument` does not fail — it writes a fixture in last month's format,
# which is then the thing every future test agrees with.
#
# `scripts/run-cross-repo-tests.sh` already fixed exactly this for
# `ct-native-replay` (see its `find_binary_in_repo`, and the contracts for it in
# `ci/test/stale-artefact-guards-test.sh`). This is that fix, extracted, so the
# sixth copy of the regenerator inherits it instead of inheriting the defect.
#
# WHAT IT DOES NOT ANSWER
# -----------------------
# Whether the winner is newer than its own SOURCES. That is a separate question
# with a separate answer — `run-cross-repo-tests.sh` asks it in
# `require_fresh_native_replay`. This function only stops the choice BETWEEN
# candidates from being made by existence. Keeping the two apart is deliberate:
# a resolver that also enforced freshness would have to know where each
# binary's sources live, and it does not.
#
# Usage:
#   source ci/lib/newest-build.sh
#   bin="$(newest_executable \
#       "$repo/target/release/tool" \
#       "$repo/target/debug/tool")" || bin=""

# Print the newest executable among the arguments; return 1 if none is
# executable. Pass candidates in PREFERENCE order: `-nt` is false for equal
# mtimes, so the earlier argument still wins a tie between two builds of the
# same revision, which is what "prefer release" was always meant to mean.
#
# Returns non-zero rather than printing empty, so that a caller using
# `... || bin=""` is making that choice out loud. Callers here collect a
# human-readable `missing+=(...)` line and report every absent prerequisite at
# once, which is why this does not exit on its own.
newest_executable() {
	local best="" candidate
	for candidate in "$@"; do
		[ -x "${candidate}" ] || continue
		if [ -z "${best}" ] || [ "${candidate}" -nt "${best}" ]; then
			best="${candidate}"
		fi
	done
	[ -n "${best}" ] || return 1
	printf '%s' "${best}"
}
