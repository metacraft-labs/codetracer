#!/usr/bin/env bash
# debug_history_context_menu_chromium_test.nim embeds the compiled theme at
# compile time, so the file it names decides whether the renderer-chromium lane
# compiles on a host at all. The build output's location differs per platform
# (src/build-debug on Linux, src/build-debug-repro on macOS) and the dev shell
# names it in CODETRACER_BUILD_DIR, so the suite has to read the theme from
# there. A fixed path passes on the platform it was written on and fails to
# compile on the others, which is why this runs the real compiler rather than
# searching the source.
#
# The fixture build directory is the one stand-in here. It isolates the result
# from whether, and for which platform, this checkout has a real build, and its
# sentinel selector proves which file was embedded. The compiler, its flags and
# the suite are the real ones.
#
# Usage: bash ci/test/chromium-theme-build-dir-test.sh (needs the dev shell's nim)
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}"
# shellcheck source=ci/lib/test-lane-files.sh
# shellcheck disable=SC1091 # resolved at runtime from $root
source "${root}/ci/lib/test-lane-files.sh"

suite=src/frontend/tests/debug_history_context_menu_chromium_test.nim
theme=frontend/styles/default_dark_theme_electron.css
sentinel=ct-theme-build-dir-sentinel
read -r -a lane_flags <<<"$(test_lane_extra_flags renderer-chromium)"

# macOS's TMPDIR ends in a slash. Nim normalises the path it reports, so the
# doubled separator would hide the directory from the check below.
tmp_root="${TMPDIR:-/tmp}"
work="$(mktemp -d "${tmp_root%/}/ct-chromium-theme.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

compile_with_build_dir() {
	CODETRACER_BUILD_DIR="$1" nim js --hints:off --warnings:off \
		"${lane_flags[@]}" --nimcache:"${work}/nimcache" \
		-o:"${work}/suite.js" "${suite}"
}

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	[ -z "${2:-}" ] || printf '%s\n' "$2" >&2
	exit 1
}

# The stylesheet the build directory holds is the one embedded.
mkdir -p "${work}/staged/$(dirname "${theme}")"
printf '.%s { color: red }\n' "${sentinel}" >"${work}/staged/${theme}"
if ! out="$(compile_with_build_dir "${work}/staged" 2>&1)"; then
	fail "the suite does not compile from a staged CODETRACER_BUILD_DIR" "${out}"
fi
# `nim js` writes a Nim string as an array of byte values and a cstring as a
# quoted literal, so accept either spelling of the sentinel.
node -e '
	const js = require("fs").readFileSync(process.argv[1], "latin1");
	const text = process.argv[2];
	const bytes = Array.from(Buffer.from(text)).join(",");
	process.exit(js.includes(text) || js.replace(/\s/g, "").includes(bytes) ? 0 : 1);
' "${work}/suite.js" "${sentinel}" ||
	fail "the compiled suite does not carry the stylesheet from CODETRACER_BUILD_DIR"
echo "OK: the theme is read from CODETRACER_BUILD_DIR"

# A build directory without the theme is a compile error naming that directory.
# A fallback to another tree would embed a stylesheet nobody asked for.
mkdir -p "${work}/unbuilt"
if out="$(compile_with_build_dir "${work}/unbuilt" 2>&1)"; then
	fail "the suite compiled from a build directory that has no theme"
fi
case "${out}" in
*"cannot open file: ${work}/unbuilt/${theme}"*) ;;
*) fail "the compile error does not name the missing theme" "${out}" ;;
esac
echo "OK: a build directory without the theme fails naming it"
