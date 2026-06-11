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
