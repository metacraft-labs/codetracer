#!/usr/bin/env bash
# Exercise the real GPUI freshness functions with a tiny real Nim program.
# No compiler or digest is mocked: the fixture uses the production entry path,
# compile arguments, dependency scanner and stamp writer. A second PATH entry
# (a symlink to the same compiler by default) tests the conservative compiler
# identity contract even when both compilers generate identical dependencies.
# Set BF_TEST_OTHER_NIM to a second installed Nim to also exercise a genuinely
# different standard-library closure, as when leaving the project's dev shell.
# Run inside the dev shell: bash ci/test/build-freshness-test.sh
# Each compiler selection is intentionally confined to its subshell; later
# cases must restore the original build environment without another rebuild.
# shellcheck disable=SC2030,SC2031
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=ci/lib/build-freshness.sh disable=SC1091
source "$root/ci/lib/build-freshness.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export CODETRACER_HOME="$work/home"
fixture="$work/fixture"
builder="$(command -v nim)" || {
	echo 'FAIL: nim is required' >&2
	exit 1
}
mkdir -p "$fixture/src/frontend/gpui" "$fixture/src/tests/visual" "$fixture/build/bin" "$work/other-bin"
cat >"$fixture/$BF_GPUI_ENTRY" <<'NIM'
import std/strutils
echo "freshness".toUpperAscii()
NIM
printf '{}\n' >"$fixture/src/tests/visual/scenarios.json"
ln -s "${BF_TEST_OTHER_NIM:-$builder}" "$work/other-bin/nim"
original_path="$PATH"
# Use the same command lookup for compilation and stamping as the real recipe.
args=()
while IFS= read -r arg; do args+=("$arg"); done < <(bf_gpui_nim_args)
compile_fixture() {
	(cd "$fixture" && nim c --hints:off --parallelBuild:2 "${args[@]}" \
		--nimcache:"$work/compile-cache" -o:"$fixture/$BF_GPUI_BIN" "$BF_GPUI_ENTRY")
}
compile_fixture
unset BF_BUILDER
bf_gpui_write_stamp "$fixture"
echo "fixture binary: $fixture/$BF_GPUI_BIN"
echo "built by: $builder"
echo "checked by: $work/other-bin/nim -> ${BF_TEST_OTHER_NIM:-$builder}"
bf_gpui_assert_fresh "$fixture"

fail() {
	echo "FAIL: $*" >&2
	cat "$work/output" >&2
	exit 1
}
# Both callers must refuse before regenerating the closure. The sentinel also
# catches a guard added after the expensive probe, or only to one caller.
for route in assert digest; do
	printf 'untouched\n' >"$fixture/build/nimcache/codetracer-gpui-deps/sentinel"
	if (
		export PATH="$work/other-bin:$original_path"
		if [ "$route" = assert ]; then
			bf_gpui_assert_fresh "$fixture"
		else
			# The capture lane keeps this digest for its provenance manifest.
			bf_gpui_input_digest "$fixture" "$fixture/$BF_GPUI_STAMP"
		fi
	) >"$work/output" 2>&1; then
		fail "$route accepted a different compiler"
	fi
	grep -F 'compiler differs from the one recorded in the stamp' "$work/output" >/dev/null || fail "$route misdiagnosed compiler mismatch"
	grep -F "$builder" "$work/output" >/dev/null || fail "$route omitted the recorded compiler"
	grep -F "$work/other-bin/nim" "$work/output" >/dev/null || fail "$route omitted the resolved compiler"
	grep -F 're-run inside the dev shell' "$work/output" >/dev/null || fail "$route omitted the shell remedy"
	if grep -E 'STALE|Rebuild' "$work/output" >/dev/null; then fail "$route prescribed a rebuild for compiler mismatch"; fi
	[ -f "$fixture/build/nimcache/codetracer-gpui-deps/sentinel" ] || fail "$route recomputed incomparable inputs"
	echo "PASS: $route refuses a different compiler before scanning inputs"
done
# Restoring the build environment clears the refusal, without rebuilding.
bf_gpui_assert_fresh "$fixture"
# Missing tooling is an environment refusal as well, without touching inputs.
if (
	export PATH="$work/no-tools"
	bf_gpui_assert_fresh "$fixture"
) >"$work/output" 2>&1; then fail 'accepted missing nim'; fi
grep -F 'nim is not on PATH' "$work/output" >/dev/null || fail 'lost missing-compiler diagnosis'
grep -F 'Run inside the dev shell' "$work/output" >/dev/null || fail 'lost missing-compiler shell remedy'
echo 'PASS: missing nim names the environment prerequisite'
# Old or incomplete provenance cannot establish which closure to compare.
cp "$fixture/$BF_GPUI_STAMP" "$work/stamp"
sed '/^built_by=/d' "$work/stamp" >"$fixture/$BF_GPUI_STAMP"
if bf_gpui_assert_fresh "$fixture" >"$work/output" 2>&1; then fail 'accepted missing compiler provenance'; fi
grep -F 'records no compiler identity' "$work/output" >/dev/null || fail 'lost missing-provenance diagnosis'
grep -F 'Rebuild and stamp inside the dev shell' "$work/output" >/dev/null || fail 'lost missing-provenance remedy'
cp "$work/stamp" "$fixture/$BF_GPUI_STAMP"
echo 'PASS: missing compiler provenance requires a new stamped build'
# A source change under the SAME compiler must still demand a rebuild.
printf '\necho "changed"\n' >>"$fixture/$BF_GPUI_ENTRY"
if bf_gpui_assert_fresh "$fixture" >"$work/output" 2>&1; then fail 'accepted changed source'; fi
grep -F 'built from different sources' "$work/output" >/dev/null || fail 'lost stale-source diagnosis'
grep -F 'Rebuild' "$work/output" >/dev/null || fail 'lost stale-source rebuild remedy'
echo 'PASS: a source change still requires rebuilding'
# The compiler check must not affect stamp writing after an actual rebuild.
compile_fixture
bf_gpui_write_stamp "$fixture"
bf_gpui_assert_fresh "$fixture"
printf 'replaced\n' >>"$fixture/$BF_GPUI_BIN"
if bf_gpui_assert_fresh "$fixture" >"$work/output" 2>&1; then fail 'accepted a replaced binary'; fi
grep -F 'stamp does not describe the artefact' "$work/output" >/dev/null || fail 'lost replaced-binary diagnosis'
echo 'PASS: a replaced binary is refused'
# A real rebuild with a deliberately changed compiler must replace the old
# provenance. Checking the previous stamp in the writer would prevent upgrades.
(
	export PATH="$work/other-bin:$original_path"
	compile_fixture
	bf_gpui_write_stamp "$fixture"
	bf_gpui_assert_fresh "$fixture"
)
echo 'PASS: an intentional compiler upgrade can build and stamp new provenance'
