#!/usr/bin/env bash
#
# Top-level orchestrator: regenerate every Value Origin Tracking
# fixture across all languages.
#
# Mirrors the pattern of
# `src/db-backend/tests/fixtures/regenerate-stylus-fixture.sh`:
# - Idempotent: re-runs cleanly without manual cleanup.
# - One entrypoint per concern: each language's per-language
#   `regenerate.sh` (under origin/<lang>/regenerate.sh) drives its own
#   scenarios; this top-level script just orchestrates them.
# - Writes recordings through the TestCache wrapper from
#   `codetracer-native-backend/tests/common/cache.rs` per spec §3 of the
#   M0 deliverables ("testing posture: real recordings, no mocks,
#   cached artefacts"). See "TestCache integration" below.
#
# Usage:
#     src/db-backend/tests/fixtures/origin/regenerate-fixtures.sh
#     # or, to run just one language:
#     src/db-backend/tests/fixtures/origin/regenerate-fixtures.sh python rust
#
# Environment knobs:
#   CACHE_DIR     — content-addressed local cache root (default
#                   ${TMPDIR:-/tmp}/codetracer/origin-fixture-cache). If
#                   the TestCache wrapper is available (see
#                   integration notes below), it owns this dir.
#   OUT_DIR_BASE  — base output directory for per-scenario recordings
#                   (default: each scenario's own ./trace/).
#
# ---------------------------------------------------------------
# TestCache integration
# ---------------------------------------------------------------
# The M0 deliverable text mandates writing through the TestCache
# wrapper at `codetracer-native-backend/tests/common/cache.rs`. That
# crate lives in a sibling repo and is Rust-only — it cannot be
# `source`d from a bash script. The intended integration is:
#
#   1. A small Rust binary in
#      `codetracer-native-backend/src/bin/origin-fixture-cache.rs`
#      (TODO: M0b) exposes `get-or-build` / `replay-with-cache`
#      subcommands callable from this script.
#   2. Until that binary lands, this script falls back to a
#      content-addressed local cache stub: each scenario's recorded
#      trace is keyed by SHA-256 of the source program, and a
#      successful recording is mirrored to
#      $CACHE_DIR/<sha256>/<lang>/<scenario>/. Subsequent runs that
#      see a cache hit symlink the cached trace into the scenario's
#      ./trace/ directory instead of re-recording.
#
# The stub keeps the script runnable in M0 without leaving the
# TestCache requirement silently skipped. The fallback is wrapped
# behind explicit `# TODO(M0-TestCache):` markers so the follow-up
# work is greppable.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

LANGUAGES_ALL=(python ruby javascript c rust nim go cairo stylus sway solana aiken leo circom noir)

if (($# > 0)); then
	LANGUAGES=("$@")
else
	LANGUAGES=("${LANGUAGES_ALL[@]}")
fi

CACHE_DIR="${CACHE_DIR:-${TMPDIR:-/tmp}/codetracer/origin-fixture-cache}"
mkdir -p "$CACHE_DIR"

# TODO(M0-TestCache): replace the local SHA-256 cache stub below with a
# real TestCache invocation once the Rust shim binary at
# `codetracer-native-backend/src/bin/origin-fixture-cache` exists.
TESTCACHE_BIN="${TESTCACHE_BIN:-origin-fixture-cache}"
if command -v "$TESTCACHE_BIN" >/dev/null 2>&1; then
	HAVE_TESTCACHE=1
	echo "[regenerate-fixtures] TestCache wrapper available: $TESTCACHE_BIN"
else
	HAVE_TESTCACHE=0
	echo "[regenerate-fixtures] TestCache wrapper NOT FOUND ($TESTCACHE_BIN) — using local SHA-256 cache stub at $CACHE_DIR"
	echo "[regenerate-fixtures]   (this is the M0 fallback; see header comment for the follow-up plan)"
fi

# Local SHA-256 fingerprint helper — used by the stub fallback so the
# script is still idempotent without the real TestCache.
fingerprint_dir() {
	local dir="$1"
	# Hash every regular file in the dir (sorted by relative path) so
	# the result is stable across runs.
	(cd "$dir" && find . -type f ! -path './trace/*' ! -path './build/*' -print0 |
		LC_ALL=C sort -z |
		xargs -0 sha256sum) |
		sha256sum |
		awk '{print $1}'
}

run_scenario_via_cache() {
	# Args: <lang> <scenario>
	local lang="$1"
	local scenario="$2"
	local script="$HERE/$lang/$scenario/regenerate.sh"

	if [[ ! -x $script ]]; then
		echo "    SKIP $lang/$scenario — regenerate.sh not executable" >&2
		return 1
	fi

	if ((HAVE_TESTCACHE == 1)); then
		# TODO(M0-TestCache): switch to `origin-fixture-cache get-or-build`
		# form once the binary lands. For now even with the binary present
		# we forward to the per-scenario script and let the binary handle
		# cache key derivation itself.
		(cd "$HERE/$lang/$scenario" && "$TESTCACHE_BIN" get-or-build -- "$script")
		return $?
	fi

	# Fallback: SHA-256 cache stub.
	local sha
	sha="$(fingerprint_dir "$HERE/$lang/$scenario")"
	local cache_path="$CACHE_DIR/$sha/$lang/$scenario"
	if [[ -d $cache_path ]]; then
		echo "    cache HIT $lang/$scenario ($sha) — relinking into ./trace"
		rm -rf "$HERE/$lang/$scenario/trace"
		ln -s "$cache_path" "$HERE/$lang/$scenario/trace"
		return 0
	fi
	echo "    cache MISS $lang/$scenario ($sha) — recording fresh"
	if ! (cd "$HERE/$lang/$scenario" && "$script"); then
		return 1
	fi
	# Mirror the produced trace into the cache so the next run hits.
	if [[ -d "$HERE/$lang/$scenario/trace" ]]; then
		mkdir -p "$(dirname "$cache_path")"
		cp -a "$HERE/$lang/$scenario/trace" "$cache_path"
	fi
	return 0
}

SCENARIOS=(
	simple_trivial_chain
	computational_origin
	parameter_pass
	return_capture
	destructuring_or_index
)

overall_failures=0
for lang in "${LANGUAGES[@]}"; do
	echo "=== $lang ==="
	if [[ ! -d "$HERE/$lang" ]]; then
		echo "    SKIP: language directory missing" >&2
		overall_failures=$((overall_failures + 1))
		continue
	fi
	for sc in "${SCENARIOS[@]}"; do
		if [[ ! -d "$HERE/$lang/$sc" ]]; then
			echo "    SKIP $lang/$sc — scenario directory missing" >&2
			overall_failures=$((overall_failures + 1))
			continue
		fi
		if ! run_scenario_via_cache "$lang" "$sc"; then
			echo "    FAIL $lang/$sc" >&2
			overall_failures=$((overall_failures + 1))
		fi
	done
done

# user-patterns is special — not per-language. Regenerate it on every
# run (it's the smallest scenario; cache stub still applies).
if [[ -d "$HERE/user-patterns" ]]; then
	echo "=== user-patterns ==="
	if [[ -x "$HERE/user-patterns/regenerate.sh" ]]; then
		(cd "$HERE/user-patterns" && ./regenerate.sh) || {
			echo "    FAIL user-patterns" >&2
			overall_failures=$((overall_failures + 1))
		}
	fi
fi

if ((overall_failures > 0)); then
	echo ""
	echo "regenerate-fixtures: $overall_failures scenario(s) failed." >&2
	echo "(M0 does NOT require these recordings to succeed — the script's existence" >&2
	echo " and the correct CLI invocations are the M0 deliverable; later milestones" >&2
	echo " wire in the recorders end-to-end.)" >&2
	exit "$overall_failures"
fi

echo ""
echo "regenerate-fixtures: all scenarios processed."
