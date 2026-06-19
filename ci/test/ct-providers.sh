#!/usr/bin/env bash
# =============================================================================
# Cross-language ct_test provider gate.
#
# Compiles and runs the ct_test provider suites that exercise real external
# toolchains and recorders (C/C++ GoogleTest/Catch2/CTest, M11 native
# languages, M12 fallback languages, JavaScript, Ruby) plus the framework gate
# tests. This is the cross-language counterpart of ci/test/m16-release-gate.sh,
# which runs the toolchain-light provider matrix.
#
# Recorder-build policy (see
# codetracer-specs/Working-with-the-CodeTracer-Repos.md, Part 2 "Self-Contained
# Binaries with Sibling Detection"): recorders are built in their own sibling
# repos via that repo's pinned dev shell (`direnv exec <repo> just build`) and
# surfaced on PATH / via the documented env vars by scripts/detect-siblings.sh.
# This script drives those builds through scripts/build-siblings.sh, which is
# the shared `direnv exec`-based builder. A required sibling that is absent or
# whose build fails is reported loudly and (unless CT_PROVIDERS_ALLOW_MISSING=1)
# fails the gate — recorder-dependent recording tests must never be skipped
# silently.
#
# Run this from inside the codetracer dev shell (which provides nim plus the
# gtest/catch2/cmake/ninja toolchain and the CT_TEST_CC/CT_TEST_CXX +
# CMAKE_PREFIX_PATH the C/C++ providers need):
#
#   nix develop '.?submodules=1' --command bash ci/test/ct-providers.sh
#   # or, equivalently:
#   just test-ct-providers
#
# Environment:
#   CT_NIM_CACHE_ROOT          — nim nimcache root (default /tmp/ct-nim-cache).
#   CT_PROVIDERS_SKIP_SIBLINGS=1 — do not (re)build sibling recorders; run the
#                                  provider tests against whatever is already
#                                  detected. Use when the recorders are known to
#                                  be built already.
#   CT_PROVIDERS_ALLOW_MISSING=1 — treat a missing/failed required sibling
#                                  recorder build as a warning instead of a hard
#                                  error (the recording tests will then fail
#                                  loudly when they run, which is the honest
#                                  outcome — they are never skipped).
# =============================================================================

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

cache_root="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}"
mkdir -p "$cache_root"

# ---------------------------------------------------------------------------
# Step 1 — build the sibling recorders the recording tests depend on.
#
# The native (ct-mcr), JavaScript and Ruby recorders back the M11 native /
# JS node:test / Ruby CTFS recording assertions. They are built in their own
# sibling repos through scripts/build-siblings.sh (which uses `direnv exec` so
# each repo's flake pins its toolchain). build-siblings.sh prints a per-repo
# PASS/SKIP/MISSING/FAIL summary and exits non-zero if any required build
# fails.
# ---------------------------------------------------------------------------
required_siblings=(codetracer-native-recorder codetracer-js-recorder codetracer-ruby-recorder)

if [[ ${CT_PROVIDERS_SKIP_SIBLINGS:-0} == "1" ]]; then
	echo "ct-providers: skipping sibling recorder builds (CT_PROVIDERS_SKIP_SIBLINGS=1)"
else
	echo "ct-providers: building sibling recorders (native, js, ruby) via direnv exec"
	# Build only the recorders this gate needs; --only matches on the logical
	# key, so we run build-siblings.sh once per recorder to get a clear
	# per-recorder result and a precise non-zero exit on failure.
	missing_or_failed=()
	for sibling in "${required_siblings[@]}"; do
		if [ ! -d "../$sibling" ]; then
			echo "ct-providers: ERROR: required sibling '$sibling' is not checked out at ../$sibling" >&2
			missing_or_failed+=("$sibling (not checked out)")
			continue
		fi
		if ! bash scripts/build-siblings.sh --only "$sibling"; then
			missing_or_failed+=("$sibling (build failed)")
		fi
	done

	if [ ${#missing_or_failed[@]} -gt 0 ]; then
		echo "" >&2
		echo "ct-providers: the following required recorder siblings are unavailable:" >&2
		for entry in "${missing_or_failed[@]}"; do
			echo "  - $entry" >&2
		done
		echo "  The recorder-dependent recording tests below will FAIL (not skip)." >&2
		if [[ ${CT_PROVIDERS_ALLOW_MISSING:-0} != "1" ]]; then
			echo "ct-providers: aborting (set CT_PROVIDERS_ALLOW_MISSING=1 to run the tests anyway)." >&2
			exit 1
		fi
		echo "ct-providers: continuing because CT_PROVIDERS_ALLOW_MISSING=1." >&2
	fi
fi

# ---------------------------------------------------------------------------
# Step 2 — compile + run each provider suite.
#
# Mirrors m16-release-gate.sh's run_nim_test helper: `nim c -r` with a
# per-suite nimcache so reruns are incremental. The codetracer dev shell's
# config.nims / nim.cfg resolve the runquota_process import paths.
# ---------------------------------------------------------------------------
run_nim_test() {
	local file="$1"
	local name
	name="$(basename "$file" .nim)"
	echo "ct-providers: running $file"
	nim c -r --hints:off --warnings:off --threads:on \
		--nimcache:"$cache_root/ct-providers-${name}" \
		-o:"$cache_root/ct-providers-${name}-bin" \
		"$file"
}

echo "ct-providers: running cross-language provider suites"
run_nim_test src/ct_test/cpp_providers_test.nim
run_nim_test src/ct_test/m11_native_languages_test.nim
run_nim_test src/ct_test/m12_fallback_languages_test.nim
run_nim_test src/ct_test/js_providers_test.nim
run_nim_test src/ct_test/ruby_providers_test.nim

echo "ct-providers: running framework gate suites"
run_nim_test src/ct_test/contracts_test.nim
run_nim_test src/ct_test/discovery_test.nim
run_nim_test src/ct_test/release_gate_test.nim

echo "ct-providers: all provider suites passed"
