#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

cache_root="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}"
mkdir -p "$cache_root"

echo "Running M16 release gate"
nim c -r --hints:off --warnings:off \
	--nimcache:"$cache_root/m16-release-gate" \
	-o:"$cache_root/m16-release-gate-bin" \
	src/ct_test/release_gate_test.nim

echo "Compiling ct-test CLI"
nim c --hints:off --warnings:off \
	--nimcache:"$cache_root/m16-ct-test-cli" \
	-o:"$cache_root/ct-test" \
	src/ct_test/ct_test.nim

run_nim_test() {
	local file="$1"
	local name
	name="$(basename "$file" .nim)"
	echo "Running $file"
	nim c -r --hints:off --warnings:off \
		--nimcache:"$cache_root/m16-${name}" \
		-o:"$cache_root/m16-${name}-bin" \
		"$file"
}

echo "Running representative ct-test fixture providers"
run_nim_test src/ct_test/contracts_test.nim
run_nim_test src/ct_test/discovery_test.nim
run_nim_test src/ct_test/run_store_test.nim
# Guards `ct-test test run` against the worker-heap hand-off regression that
# made it dump core at high thread counts *after* printing a valid summary.
#
# Run with glibc's retired-thread-stack cache disabled, scoped to this one
# invocation. That regression writes into a dead thread's TLS at *every* thread
# count; only whether the page is still mapped decides whether the process dies,
# and glibc's default 40 MiB cache keeps 20 of Nim's 2 MiB thread stacks mapped.
# Left at the default, this guard silently depends on three unrelated numbers
# holding still — glibc's cache size, Nim's ThreadStackSize, and the suite's unit
# count staying above 21 (it runs min(threads, units) workers). Move any one of
# them and the guard stops guarding while still reporting success. With the cache
# gone the illegal write is fatal at the very first worker instead.
#
# That makes this gate deliberately stricter than production: an unmapped stack
# can only expose a latent use-after-free, never invent one, so a failure seen
# only here is a real bug in the code under test, not a gate artifact.
#
# The suite still makes its own unamplified 32-worker run, and that is what
# proves the shipping configuration safe; the tunable is an amplifier on top of
# it, not a replacement for it. Not exported script-wide on purpose: it is
# glibc-only (a silent no-op on musl and macOS) and disabling the cache slows
# down every thread-creating process.
GLIBC_TUNABLES=glibc.pthread.stack_cache_size=0 \
	run_nim_test src/ct_test/run_orchestration_test.nim
run_nim_test src/ct_test/nim_unittest_provider_test.nim
run_nim_test src/ct_test/python_providers_test.nim
run_nim_test src/ct_test/rust_libtest_provider_test.nim
run_nim_test src/ct_test/playwright_provider_test.nim

echo "Running M14/M15 trace-open and editor ViewModel smoke tests"
run_nim_test src/frontend/viewmodel/tests/unit/test_test_explorer_vm.nim
run_nim_test src/frontend/viewmodel/tests/unit/test_editor_test_controls_m4.nim

if [[ ${CT_M16_HEAVY:-0} == "1" ]]; then
	echo "Running heavy/toolchain-dependent M16 trace artifact smoke tests"
	run_nim_test src/ct_test/m13_smart_contract_harnesses_test.nim
	run_nim_test src/tests/gui/tests/integration/language_smoke_test.nim
else
	echo "Skipping heavy M16 checks; set CT_M16_HEAVY=1 to run recorder/toolchain-dependent trace artifact smoke tests"
fi
