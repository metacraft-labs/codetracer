#!/usr/bin/env bash

# Contract tests for scripts/test-origin-dap.sh. The execution tests use a
# fake cargo program so selector, manifest and SKIPPED-sentinel behaviour are
# validated without building db-backend twice. The real gate subsequently
# runs the Rust policy target and the materialized suites.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
readonly REPO_ROOT
readonly GATE="$REPO_ROOT/scripts/test-origin-dap.sh"

fail() {
	echo "origin-DAP shell contract test failed: $*" >&2
	exit 1
}

expect_plan() {
	local selector="$1" expected="$2" actual
	actual="$(CT_TEST_LANGS="$selector" CT_ORIGIN_DAP_REQUIRED=0 "$GATE" --plan)"
	[ "$actual" = "$expected" ] ||
		fail "selector '$selector' planned '$actual'; expected '$expected'"
}

expect_rejected() {
	local selector="$1" fragment="$2" output status
	set +e
	output="$(CT_TEST_LANGS="$selector" CT_ORIGIN_DAP_REQUIRED=0 "$GATE" --plan 2>&1)"
	status=$?
	set -e
	[ "$status" -ne 0 ] || fail "selector '$selector' unexpectedly succeeded"
	printf '%s\n' "$output" | grep -Fq "$fragment" ||
		fail "selector '$selector' did not report '$fragment': $output"
}

expected_all=$'origin_python_dap_test\norigin_ruby_dap_test\norigin_javascript_dap_test'
actual_unset="$(
	unset CT_TEST_LANGS
	export CT_ORIGIN_DAP_REQUIRED=0
	"$GATE" --plan
)"
[ "$actual_unset" = "$expected_all" ] || fail "unset selector did not route all documented suites"

expect_plan "all" "$expected_all"
expect_plan " PY, python,py " "origin_python_dap_test"
expect_plan "Ruby,rb,RUBY" "origin_ruby_dap_test"
expect_plan "javascript,JS,node" "origin_javascript_dap_test"
expect_plan "py, rb, node, python" "$expected_all"

expect_rejected "" "explicitly empty"
expect_rejected "   " "explicitly empty"
expect_rejected "rust" "unknown CT_TEST_LANGS selector 'rust'"
expect_rejected "python,rust" "unknown CT_TEST_LANGS selector 'rust'"
expect_rejected ",python" "empty selector token"
expect_rejected "python,,ruby" "empty selector token"
expect_rejected "python," "empty selector token"
expect_rejected "python, ,ruby" "empty selector token"
expect_rejected "all,python" "cannot be mixed"

required_python_plan="$(CT_TEST_LANGS=python CT_ORIGIN_DAP_REQUIRED=1 "$GATE" --plan)"
[ "$required_python_plan" = "origin_python_dap_test" ] ||
	fail "required mode did not accept the documented Python-only route"

set +e
required_route_error="$(CT_TEST_LANGS=ruby CT_ORIGIN_DAP_REQUIRED=1 "$GATE" --plan 2>&1)"
required_route_status=$?
set -e
[ "$required_route_status" -ne 0 ] || fail "required mode accepted a non-Python route"
printf '%s\n' "$required_route_error" | grep -Fq "strict Python-only" ||
	fail "required non-Python route reported the wrong error"

# Keep the active Windows workflow aligned with the same router contract. A
# stale `python,rust` selector used to pass through as a warning and silently
# omitted Rust, while the job names still claimed TTD and MCP/CLI coverage.
workflow_job() {
	local job="$1"
	awk -v job="$job" '
    $0 == "  " job ":" { active = 1; print; next }
    active && $0 ~ /^  [A-Za-z0-9_-]+:$/ { exit }
    active { print }
  ' "$REPO_ROOT/.github/workflows/codetracer.yml"
}

workflow_step() {
	local step="$1"
	awk -v step="$step" '
    $0 == "      - name: " step { active = 1; print; next }
    active && $0 ~ /^      - name: / { exit }
    active { print }
  '
}

windows_per_pr="$(workflow_job origin-dap-windows)"
windows_nightly="$(workflow_job origin-dap-windows-nightly)"

# The eph-win-x64 image provides Windows PowerShell but not PowerShell Core.
# Every PowerShell step in the required job must therefore use the compatible
# GitHub Actions shell name; retaining even one `pwsh` step only moves the same
# command-not-found failure later in the job.
if printf '%s\n' "$windows_per_pr" | grep -Fq 'shell: pwsh'; then
	fail "Windows per-PR origin-DAP job must not require unavailable PowerShell Core"
fi
[ "$(printf '%s\n' "$windows_per_pr" | grep -c 'shell: powershell$')" -eq 8 ] ||
	fail "Windows per-PR origin-DAP job must run all eight PowerShell steps with Windows PowerShell"

[ "$(printf '%s\n' "$windows_per_pr" | grep -c 'CT_TEST_LANGS: python$')" -eq 1 ] ||
	fail "Windows per-PR origin-DAP job must select Python exactly once"
[ "$(printf '%s\n' "$windows_per_pr" | grep -c 'CT_ORIGIN_DAP_REQUIRED: "1"$')" -eq 1 ] ||
	fail "Windows per-PR origin-DAP job must enable required mode exactly once"
[ "$(printf '%s\n' "$windows_nightly" | grep -c 'CT_TEST_LANGS: all$')" -eq 1 ] ||
	fail "Windows nightly origin-DAP job must use the documented routed 'all' selector"

if printf '%s\n%s\n' "$windows_per_pr" "$windows_nightly" |
	grep -Eiq 'python[[:space:]]*\+[[:space:]]*rust|python,rust|full matrix|all languages|MCP/CLI smoke'; then
	fail "Windows origin-DAP jobs retain a rejected selector or a false coverage claim"
fi
if printf '%s\n' "$windows_per_pr" | grep -Eiq 'choco(latey)?([.]exe)?([[:space:]]|$)'; then
	fail "Windows per-PR origin-DAP job must not depend on Chocolatey"
fi

# actions/checkout cannot honor recursive submodules through its REST fallback.
# Keep the self-hosted Windows job's discovery-first Git bootstrap ahead of
# checkout, while preserving the authenticated recursive checkout contract.
token_line="$(printf '%s\n' "$windows_per_pr" | grep -nFx -- '      - name: Generate CI token' | cut -d: -f1)"
git_bootstrap_line="$(printf '%s\n' "$windows_per_pr" | grep -nFx -- '      - name: Ensure Git supports recursive checkout' | cut -d: -f1)"
checkout_line="$(printf '%s\n' "$windows_per_pr" | grep -nFx -- '      - name: Checkout' | cut -d: -f1)"
toolchain_line="$(printf '%s\n' "$windows_per_pr" | grep -nFx -- '      - name: Provision verified origin-DAP toolchain' | cut -d: -f1)"
recorder_install_line="$(printf '%s\n' "$windows_per_pr" | grep -nFx -- '      - name: Install and verify locked Rust-backed Python recorder' | cut -d: -f1)"
required_gate_line="$(printf '%s\n' "$windows_per_pr" | grep -nFx -- '      - name: Run required materialized Python origin-DAP gate' | cut -d: -f1)"
[ -n "$token_line" ] && [ -n "$git_bootstrap_line" ] && [ -n "$checkout_line" ] &&
	[ -n "$toolchain_line" ] && [ -n "$recorder_install_line" ] && [ -n "$required_gate_line" ] ||
	fail "Windows per-PR job is missing bootstrap, checkout, toolchain, recorder, or gate steps"
[ "$git_bootstrap_line" -lt "$token_line" ] && [ "$token_line" -lt "$checkout_line" ] ||
	fail "Windows Git bootstrap must run before credentials are minted and checkout begins"
[ "$checkout_line" -lt "$toolchain_line" ] &&
	[ "$toolchain_line" -lt "$recorder_install_line" ] &&
	[ "$recorder_install_line" -lt "$required_gate_line" ] ||
	fail "Windows verified toolchain must precede recorder installation and the strict gate"

git_bootstrap="$(printf '%s\n' "$windows_per_pr" | workflow_step 'Ensure Git supports recursive checkout')"
checkout_step="$(printf '%s\n' "$windows_per_pr" | workflow_step 'Checkout')"
toolchain_step="$(
	printf '%s\n' "$windows_per_pr" |
		workflow_step 'Provision verified origin-DAP toolchain'
)"
bootstrap_contract_step="$(
	printf '%s\n' "$windows_per_pr" |
		workflow_step 'Verify Windows bootstrap and private recorder authentication contracts'
)"
required_gate_step="$(printf '%s\n' "$windows_per_pr" | workflow_step 'Run required materialized Python origin-DAP gate')"

# The repository is unavailable before checkout, so retrieve the reviewed
# helper from the exact immutable workflow revision. The helper itself owns
# discovery, pinned provisioning, version verification and PATH propagation;
# the workflow must call that same file, not retain an untested inline clone.
# shellcheck disable=SC2016 # Match the literal GitHub Actions expression.
printf '%s\n' "$git_bootstrap" |
	grep -Fq 'CODETRACER_GIT_BOOTSTRAP_REVISION: ${{ github.sha }}' ||
	fail "Windows Git bootstrap must be tied to the immutable workflow revision"
printf '%s\n' "$git_bootstrap" | grep -Fq "'^[0-9a-f]{40}$'" ||
	fail "Windows Git bootstrap must validate the immutable revision"
printf '%s\n' "$git_bootstrap" |
	grep -Fq 'https://raw.githubusercontent.com/metacraft-labs/codetracer/' ||
	fail "Windows Git bootstrap must retrieve only the CodeTracer helper"
# shellcheck disable=SC2016 # Match literal inline PowerShell.
printf '%s\n' "$git_bootstrap" |
	grep -Fq '"$revision/ci/ensure-git-for-checkout.ps1"' ||
	fail "Windows Git bootstrap helper URL must contain the validated revision"
printf '%s\n' "$git_bootstrap" | grep -Fq '/ci/ensure-git-for-checkout.ps1' ||
	fail "Windows Git bootstrap must retrieve the tested helper path"
# shellcheck disable=SC2016 # Match literal inline PowerShell.
printf '%s\n' "$git_bootstrap" | grep -Fq '& $bootstrapScript' ||
	fail "Windows Git bootstrap must invoke the downloaded tested helper"
printf '%s\n' "$git_bootstrap" | grep -Fq 'Invoke-WebRequest' ||
	fail "Windows Git bootstrap must retrieve the helper before checkout"
# The app token is reserved for authenticated checkout and later private
# recorder fetches. The public immutable helper fetch must not receive it.
if printf '%s\n' "$git_bootstrap" |
	grep -Eq 'app-token\.outputs\.token|SIBLING_TOKEN|[Aa]uthorization|[Hh]eader'; then
	fail "Windows Git bootstrap must not receive or transmit repository credentials"
fi
# shellcheck disable=SC2016 # Match literal inline PowerShell.
printf '%s\n' "$git_bootstrap" |
	grep -Fq 'Remove-Item -LiteralPath $bootstrapScript' ||
	fail "Windows Git bootstrap must clean the downloaded helper"
if printf '%s\n' "$git_bootstrap" | grep -Fq 'choco.exe'; then
	fail "Windows Git bootstrap must not require an absent package manager"
fi

[ -f "$REPO_ROOT/ci/ensure-git-for-checkout.ps1" ] ||
	fail "Windows Git bootstrap helper is missing"
[ -f "$REPO_ROOT/ci/test/ensure-git-for-checkout.ps1" ] ||
	fail "Windows Git bootstrap behavioral test is missing"
grep -Fq 'v2.55.0.windows.3/PortableGit-2.55.0.3-64-bit.7z.exe' \
	"$REPO_ROOT/ci/ensure-git-for-checkout.ps1" ||
	fail "Windows Git bootstrap must pin the reviewed official PortableGit asset"
grep -Fq 'ab00566336b5472120f9a52d34f2e79c5406535792acb0548001ffd0bd090e5d' \
	"$REPO_ROOT/ci/ensure-git-for-checkout.ps1" ||
	fail "Windows Git bootstrap must pin the reviewed PortableGit SHA256"
grep -Fq '"GIT_CONFIG_KEY_0=core.longpaths"' \
	"$REPO_ROOT/ci/ensure-git-for-checkout.ps1" ||
	fail "Windows Git bootstrap must propagate long-path support to recursive checkout"
grep -Fq '"GIT_CONFIG_PARAMETERS="' \
	"$REPO_ROOT/ci/ensure-git-for-checkout.ps1" ||
	fail "Windows Git bootstrap must neutralize inherited inline Git configuration"
printf '%s\n' "$bootstrap_contract_step" |
	grep -Fq './ci/test/ensure-git-for-checkout.ps1' ||
	fail "Windows job must run the Git bootstrap behavioral contract"

# Post-checkout compiler/build-tool provisioning uses only reviewed official
# immutable assets. The helper owns exact digest, layout and version checks,
# transactional activation, PATH propagation and rollback; the workflow calls
# it once and runs its hermetic behavioral contract before the real gate.
[ -f "$REPO_ROOT/ci/ensure-origin-dap-windows-toolchain.ps1" ] ||
	fail "Windows origin-DAP toolchain helper is missing"
[ -f "$REPO_ROOT/ci/test/ensure-origin-dap-windows-toolchain.ps1" ] ||
	fail "Windows origin-DAP toolchain behavioral test is missing"
[ "$(printf '%s\n' "$toolchain_step" | grep -c 'run: ./ci/ensure-origin-dap-windows-toolchain.ps1$')" -eq 1 ] ||
	fail "Windows job must invoke the reviewed origin-DAP toolchain helper exactly once"
[ "$(printf '%s\n' "$toolchain_step" | grep -c 'shell: powershell$')" -eq 1 ] ||
	fail "Windows toolchain provisioning must remain Windows PowerShell 5.1 compatible"
printf '%s\n' "$bootstrap_contract_step" |
	grep -Fq './ci/test/ensure-origin-dap-windows-toolchain.ps1' ||
	fail "Windows job must run the origin-DAP toolchain behavioral contract"
grep -Fq 'JUST_WIN_X64_SHA256=f0acf3f8ccbcf360b481baae9cae4c921774c89d5d932012481d3e0bda78ab39' \
	"$REPO_ROOT/non-nix-build/windows/toolchain-versions.env" ||
	fail "Windows pins must contain the reviewed official Just SHA256"
grep -Fq 'NIMBLE_VERSION=0.20.1' \
	"$REPO_ROOT/non-nix-build/windows/toolchain-versions.env" ||
	fail "Windows pins must contain the nimble version bundled with Nim 2.2.8"
for reviewed_digest in \
	2c503361f8bf26fa9e7caccb6db04d6b271d5f0ad3da0616cf40e9a51335c89c \
	11fe2415a64a791b899cc78e2eeacdde93b5f122f2fabc447db36d38002bfb8c \
	f0acf3f8ccbcf360b481baae9cae4c921774c89d5d932012481d3e0bda78ab39; do
	grep -Fq "$reviewed_digest" "$REPO_ROOT/non-nix-build/windows/toolchain-versions.env" ||
		fail "Windows pins omitted reviewed digest $reviewed_digest"
done
for required_companion in capnpc-c++.exe capnpc-capnp.exe nimble.exe; do
	grep -Fq "Name = \"$required_companion\"" \
		"$REPO_ROOT/ci/ensure-origin-dap-windows-toolchain.ps1" ||
		fail "Windows origin-DAP toolchain omitted $required_companion"
done

[ "$(printf '%s\n' "$checkout_step" | grep -c 'submodules: recursive$')" -eq 1 ] ||
	fail "Windows checkout must retain recursive submodules"
[ "$(printf '%s\n' "$checkout_step" | grep -c "token: \${{ steps.app-token.outputs.token }}$")" -eq 1 ] ||
	fail "Windows checkout must retain the generated CI token"
printf '%s\n' "$required_gate_step" | grep -Fq 'run: just test-origin-dap' ||
	fail "Windows required gate must still run the strict origin-DAP router"
[ "$(printf '%s\n' "$required_gate_step" | grep -c 'shell: bash$')" -eq 1 ] ||
	fail "Windows required gate must still run under Git Bash"
if printf '%s\n' "$required_gate_step" | grep -Eq 'continue-on-error:|CT_ORIGIN_DAP_REQUIRED: "0"'; then
	fail "Windows required origin-DAP gate must not tolerate failure or skips"
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codetracer-origin-dap-self-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
fake_cargo="$tmp_dir/fake-cargo"
cat >"$fake_cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 3 ] && [ "$1" = "test" ] && [ "$2" = "--test" ] \
  && [ "$3" = "origin_dap_gate_test" ]; then
  echo "test result: ok. 4 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out"
  exit 0
fi

if [ "$#" -eq 5 ] && [ "$1" = "test" ] && [ "$2" = "--test" ] \
  && [ "$3" = "origin_python_dap_test" ] && [ "$4" = "--" ] \
  && [ "$5" = "--list" ]; then
  cat <<'LIST'
test_origin_python_simple_trivial_chain: test
test_origin_python_computational_origin: test
test_origin_python_parameter_pass: test
test_origin_python_return_capture: test
test_origin_python_destructuring_or_index: test
test_origin_python_augmented_assignment: test
test_origin_python_walrus_in_condition: test

7 tests, 0 benchmarks
LIST
  exit 0
fi

if [ "$#" -eq 5 ] && [ "$1" = "test" ] && [ "$2" = "--test" ] \
  && [ "$3" = "origin_python_dap_test" ] && [ "$4" = "--" ] \
  && [ "$5" = "--nocapture" ]; then
  if [ "${FAKE_ORIGIN_DAP_SKIP:-0}" = "1" ]; then
    echo "SKIPPED: python/fake: recorder unavailable"
  fi
  echo "test result: ok. 7 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s"
  exit 0
fi

echo "unexpected fake cargo arguments: $*" >&2
exit 64
EOF
chmod +x "$fake_cargo"

required_success="$(
	CT_TEST_LANGS=python \
		CT_ORIGIN_DAP_REQUIRED=1 \
		ORIGIN_DAP_SKIP_GATE_SELF_TESTS=1 \
		ORIGIN_DAP_CARGO_BIN="$fake_cargo" \
		"$GATE" 2>&1
)"
printf '%s\n' "$required_success" |
	grep -Fq "origin-DAP required summary: expected=7 executed=7 skipped=0" ||
	fail "required success did not emit the exact completion summary"

set +e
required_skip="$(
	CT_TEST_LANGS=python \
		CT_ORIGIN_DAP_REQUIRED=1 \
		FAKE_ORIGIN_DAP_SKIP=1 \
		ORIGIN_DAP_SKIP_GATE_SELF_TESTS=1 \
		ORIGIN_DAP_CARGO_BIN="$fake_cargo" \
		"$GATE" 2>&1
)"
required_skip_status=$?
set -e
[ "$required_skip_status" -ne 0 ] || fail "required mode accepted a SKIPPED sentinel"
printf '%s\n' "$required_skip" | grep -Fq "emitted a SKIPPED sentinel" ||
	fail "required skip reported the wrong failure"
if printf '%s\n' "$required_skip" |
	grep -Fq "origin-DAP required summary: expected=7 executed=7 skipped=0"; then
	fail "required skip emitted the successful completion summary"
fi

optional_skip="$(
	CT_TEST_LANGS=python \
		CT_ORIGIN_DAP_REQUIRED=0 \
		FAKE_ORIGIN_DAP_SKIP=1 \
		ORIGIN_DAP_SKIP_GATE_SELF_TESTS=1 \
		ORIGIN_DAP_CARGO_BIN="$fake_cargo" \
		"$GATE" 2>&1
)"
printf '%s\n' "$optional_skip" | grep -Fq "Selected Value Origin Tracking DAP suites passed." ||
	fail "developer-optional mode no longer accepts an intentional skip"

# The real required gate invokes this contract test while
# CT_ORIGIN_DAP_REQUIRED=1 is ambient. Re-run this script once under that
# exact environment to prevent optional selector cases from accidentally
# inheriting required mode again. The child sentinel prevents recursion.
if [ "${ORIGIN_DAP_AMBIENT_REQUIRED_CHILD:-0}" != "1" ]; then
	ambient_required_self_test="$(
		CT_ORIGIN_DAP_REQUIRED=1 \
			ORIGIN_DAP_AMBIENT_REQUIRED_CHILD=1 \
			bash "$REPO_ROOT/ci/test/origin-dap-gate.sh" 2>&1
	)" || fail "shell contract self-test failed under ambient required mode"
	printf '%s\n' "$ambient_required_self_test" |
		grep -Fq "origin-DAP shell contract tests passed" ||
		fail "ambient-required shell contract self-test omitted its success marker"
fi

echo "origin-DAP shell contract tests passed"
