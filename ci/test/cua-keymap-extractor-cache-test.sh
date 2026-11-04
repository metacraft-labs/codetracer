#!/usr/bin/env bash
#
# cua-keymap-extractor-cache-test.sh — contract suite for WHERE
# ci/test/cua-keymap-extractor.sh caches the VS Code sources it fetches.
#
# WHY THIS EXISTS
# ---------------
# The extractor fetches VS Code 1.105.0's sources once and keeps them in a
# cache. On 2026-11-02 the `lint-nim` stage ran it and the sources landed in a
# developer's real `~/.cache/codetracer/vscode-484fdf69`: the cache was
# `${XDG_CACHE_HOME:-$HOME/.cache}/codetracer/…` and ignored `CODETRACER_HOME`,
# the variable every test lane sets so that nothing it runs touches the
# developer's profile (codetracer-pm spec/Architecture/Per-User-State-
# Locations.md). The rule is now, first hit wins:
#
#   1. `$CT_VSCODE_SRC_CACHE`                    (names the location)
#   2. `$CODETRACER_HOME/cache/vscode-484fdf69`  (CodeTracer's cache area)
#   3. `$XDG_CACHE_HOME/codetracer/vscode-484fdf69`
#   4. `$HOME/.cache/codetracer/vscode-484fdf69`
#
# and `ct_home_isolation_test`'s sweep C2 pins that the script names
# `CODETRACER_HOME` at all. This suite pins the ORDER and the LAYOUT by running
# the real script, which the sweep cannot.
#
# HERMETIC. The script's inputs (monaco's ESM, CUA-Keymap.md) are empty
# fixture paths, and `curl` on PATH is a stub that fails, so the script reaches
# the fetch, names the cache it chose and creates it, and stops there: no
# network, no python3 run. `HOME` is a scratch decoy that must stay empty
# whenever `CODETRACER_HOME` is set.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/cua-cache-test.XXXXXX")"
trap 'rm -rf "${scratch}"' EXIT

passes=0
failures=0
t_pass() {
	passes=$((passes + 1))
	echo "  ok   $1"
}
t_fail() {
	failures=$((failures + 1))
	echo "  FAIL $1" >&2
}

mkdir -p "${scratch}/monaco" "${scratch}/specs/spec/GUI" "${scratch}/bin"
: >"${scratch}/specs/spec/GUI/CUA-Keymap.md"
printf '#!/usr/bin/env bash\nexit 22\n' >"${scratch}/bin/curl"
chmod +x "${scratch}/bin/curl"

Want=vscode-484fdf69

# run_extractor VAR=value... — the script with only the named location
# variables set; prints the directory it said it fetches into.
run_extractor() {
	rm -rf "${scratch:?}/home"
	mkdir -p "${scratch}/home"
	(
		cd "${repo_root}" || exit 2
		env -u CT_VSCODE_DIR -u CT_VSCODE_SRC_CACHE -u CODETRACER_HOME \
			-u XDG_CACHE_HOME HOME="${scratch}/home" \
			CT_MONACO_DIR="${scratch}/monaco" CT_SPECS_DIR="${scratch}/specs" \
			PATH="${scratch}/bin:${PATH}" "$@" \
			bash ci/test/cua-keymap-extractor.sh
	) >"${scratch}/out" 2>&1
	sed -n 's/^cua-keymap-extractor: fetching VS Code [0-9a-f]* sources into //p' "${scratch}/out"
}

home_is_empty() {
	[ -z "$(find "${scratch}/home" -mindepth 1 -print -quit)" ]
}

echo "cua-keymap-extractor-cache-test:"

# 1. CODETRACER_HOME set: its cache area, and HOME untouched — even with
#    XDG_CACHE_HOME set, which CODETRACER_HOME outranks.
got="$(run_extractor CODETRACER_HOME="${scratch}/ct-home" XDG_CACHE_HOME="${scratch}/xdg")"
if [ "${got}" = "${scratch}/ct-home/cache/${Want}" ] && [ -d "${got}" ] && home_is_empty &&
	[ ! -e "${scratch}/xdg" ]; then
	t_pass "CODETRACER_HOME set: \$CODETRACER_HOME/cache/${Want}, nothing under HOME or XDG_CACHE_HOME"
else
	t_fail "CODETRACER_HOME set: \$CODETRACER_HOME/cache/${Want} (got '${got}')"
	sed 's/^/       /' "${scratch}/out" >&2
fi
rm -rf "${scratch}/ct-home" "${scratch}/xdg"

# 2. CT_VSCODE_SRC_CACHE names the location and wins over CODETRACER_HOME.
got="$(run_extractor CT_VSCODE_SRC_CACHE="${scratch}/explicit" CODETRACER_HOME="${scratch}/ct-home")"
if [ "${got}" = "${scratch}/explicit" ] && home_is_empty; then
	t_pass "CT_VSCODE_SRC_CACHE wins over CODETRACER_HOME"
else
	t_fail "CT_VSCODE_SRC_CACHE wins over CODETRACER_HOME (got '${got}')"
fi
rm -rf "${scratch}/explicit" "${scratch}/ct-home"

# 3-4. Unset: exactly the historical locations.
got="$(run_extractor XDG_CACHE_HOME="${scratch}/xdg")"
if [ "${got}" = "${scratch}/xdg/codetracer/${Want}" ]; then
	t_pass "CODETRACER_HOME unset: \$XDG_CACHE_HOME/codetracer/${Want}, as before"
else
	t_fail "CODETRACER_HOME unset: \$XDG_CACHE_HOME/codetracer/${Want} (got '${got}')"
fi
rm -rf "${scratch}/xdg"
got="$(run_extractor CODETRACER_HOME= XDG_CACHE_HOME=)"
if [ "${got}" = "${scratch}/home/.cache/codetracer/${Want}" ]; then
	t_pass "both unset (or empty): \$HOME/.cache/codetracer/${Want}, as before"
else
	t_fail "both unset (or empty): \$HOME/.cache/codetracer/${Want} (got '${got}')"
fi

# Anti-vacuity: every arm above read the line it matched from the script's own
# output, so a script that stopped printing it fails every arm by name.
echo "cua-keymap-extractor-cache-test: ${passes} passed, ${failures} failed"
[ "${failures}" -eq 0 ] && [ "${passes}" -eq 4 ]
