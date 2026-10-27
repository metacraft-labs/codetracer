#!/usr/bin/env bash
#
# vm-unit-js-only-suites-test.sh — the native `vm-unit` lane collects only
# suites the C backend can compile, and every JavaScript-only suite runs in
# `vm-unit-js` instead.
#
# WHY THIS EXISTS
# ---------------
# `vm-unit` compiles every `src/frontend/viewmodel/tests/unit/test_*.nim` with
# the C backend. A few suites there can only be compiled by `nim js`: they
# import a standard-library module that is a `{.fatal.}` / `{.error.}` off the
# JavaScript target (`std/asyncjs`, `std/jsffi`, `std/dom`, ...). The lane used
# to keep those out by FILENAME — one `_tlf_reject` line per suite — so the
# next such suite added to the directory ran natively by default. That is what
# happened to `test_hosted_primary_over_socket.nim` (it imports
# `std/[asyncjs, json, jsffi, options]`): `just test-vm-unit` reported
#
#     test_hosted_primary_over_socket.nim ... COMPILE ERROR
#       .../lib/js/asyncjs.nim(68, 10) Error: fatal error: Module asyncjs is
#       designed to be used with the JavaScript backend.
#
# while `vm-unit-js` only ran it because it re-added the JS-only suites by name
# too, and happened to list it. (codetracer-pm issue
# 2026-10-20-vm-unit-lane-compiles-the-js-only-hosted-primary-socket-suite-natively.)
#
# The contracts, each stated against the lane lists the runner actually uses
# (`test_lane_files`), never against a copy of their rules:
#
#   0. ORACLE — the JS-only module list below is exactly the standard-library
#      modules the active Nim toolchain refuses off the JS target. Needs `nim`; without
#      it the contract is counted as skipped, by name.
#   1. NATIVE — no file in `vm-unit` (or `vm-unit-wasm`, which recompiles
#      `vm-unit`'s files for wasm32, a C target) imports a JS-only module at
#      top level. This is the issue's failure, generically.
#   2. JS — every suite under the unit directory that imports a JS-only module
#      at top level is in `vm-unit-js`, exactly once.
#   3. POSITIVE CONTROL — in a synthetic tree, a JS-only suite in each import
#      spelling, for each module in the list, is routed to `vm-unit-js` and
#      kept out of `vm-unit` with nobody naming it. Without this, (1) and (2)
#      pass against a lib whose rule matches nothing, provided the real tree
#      happens to have no new JS-only suite. It also requires the lib's list
#      to equal the one here, which the fixtures alone cannot show.
#   4. NEGATIVE CONTROL — in the same tree, native suites that merely MENTION a
#      JS-only module (inside `when defined(js):`, in a comment, as a project
#      module path, or as a longer name) stay in `vm-unit`. Without this, (1)
#      passes against a lib that rejects everything.
#
# The synthetic tree is a temp directory, not a mock: the real lib is sourced
# and run from it, because the lib's paths are repo-relative and that is the
# only way to show it discovering files nobody listed. The JS-only parser
# below is written independently of the lib's rule (a tokenizer, not the
# lib's regular expression) so the two can disagree.
#
# Pure bash + awk; contract 0 additionally needs `nim`. It runs in the lint
# stage (`ci/lint/nim.sh`), whose shell carries `nim`.
#
# Run directly:  bash ci/test/vm-unit-js-only-suites-test.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
lib="${repo_root}/ci/lib/test-lane-files.sh"
unit_dir=src/frontend/viewmodel/tests/unit

# The standard-library modules that refuse to compile off the JS target.
# Contract 0 holds this against the toolchain.
JS_ONLY_MODULES=(asyncjs dom jsbigints jsconsole jscore jsfetch jsffi jsformdata jsheaders jsre)

TOTAL_CONTRACTS=5
checks=0
failures=0
skips=0

ok() {
	checks=$((checks + 1))
	echo "  [OK] $1"
}
bad() {
	checks=$((checks + 1))
	failures=$((failures + 1))
	echo "  [FAILED] $1"
	shift
	local line
	for line in "$@"; do printf '        %s\n' "${line}"; done
}
skip() {
	skips=$((skips + 1))
	echo "  [SKIPPED] $1"
}

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# js_only_imports FILE — print each JS-only module FILE imports at top level
# (column 0), one per line. A statement continues onto following lines while a
# `[` is open or the line ends in a comma. Within a statement, an item is
# JS-only when, after expanding `prefix/[a, b]` groups, it is a bare module
# name or `std/<name>` / `js/<name>` and the name is in JS_ONLY_MODULES. A path
# with any other directory (`../x/dom`) is a project module, not the stdlib.
js_only_imports() {
	awk -v mods="${JS_ONLY_MODULES[*]}" '
		BEGIN { n = split(mods, m, " "); for (i = 1; i <= n; i++) js[m[i]] = 1 }
		function depth(s,   o, c) { o = gsub(/\[/, "[", s); c = gsub(/\]/, "]", s); return o - c }
		function item(prefix, it,   name) {
			gsub(/^[ \t]+|[ \t]+$/, "", it)
			sub(/[ \t].*$/, "", it)          # drop "as x" / "except y"
			if (it == "") return
			name = prefix it
			if (name ~ /^(std|js)\//) name = substr(name, index(name, "/") + 1)
			else if (name ~ /\//) return
			if (name in js) print name
		}
		function stmt_items(s,   kw, head, body, rest, k, parts, i) {
			kw = s; sub(/[ \t].*$/, "", kw)
			sub(/^[a-z]+[ \t]+/, "", s)
			if (kw == "from") { sub(/[ \t].*$/, "", s); item("", s); return }
			while (s != "") {
				sub(/^[ \t,]+/, "", s)
				if (s == "") break
				k = index(s, ",")
				if (index(s, "[") > 0 && (k == 0 || index(s, "[") < k)) {
					head = substr(s, 1, index(s, "[") - 1)
					gsub(/[ \t]/, "", head)
					rest = substr(s, index(s, "[") + 1)
					body = substr(rest, 1, index(rest, "]") - 1)
					s = substr(rest, index(rest, "]") + 1)
					n = split(body, parts, ",")
					for (i = 1; i <= n; i++) item(head, parts[i])
				} else if (k > 0) {
					item("", substr(s, 1, k - 1)); s = substr(s, k + 1)
				} else {
					item("", s); s = ""
				}
			}
		}
		{
			line = $0; sub(/#.*/, "", line)
			if (open_stmt) {
				stmt = stmt " " line; d += depth(line)
				if (d > 0 || stmt ~ /,[ \t]*$/) next
				stmt_items(stmt); open_stmt = 0; next
			}
			if (line ~ /^(import|from)[ \t]/) {
				stmt = line; d = depth(line)
				if (d > 0 || stmt ~ /,[ \t]*$/) { open_stmt = 1; next }
				stmt_items(stmt)
			}
		}
		END { if (open_stmt) stmt_items(stmt) }
	' "$1" | sort -u
}

# lane_files TREE LANE — the lane's files as the lib computes them from TREE.
lane_files() {
	(
		cd "$1" || exit 2
		# shellcheck source=ci/lib/test-lane-files.sh
		source "${lib}"
		test_lane_files "$2"
	)
}

echo "=== vm-unit / vm-unit-js: JS-only suites are routed by dependency ==="

# ---------------------------------------------------------------------------
# 0. ORACLE
# ---------------------------------------------------------------------------
if command -v nim >/dev/null 2>&1; then
	# `nim dump` needs a file argument; it does not have to exist. Run from the
	# scratch directory so this repo's `config.nims` is not evaluated.
	nim_lib="$(cd "${work}" && nim dump --dump.format:json probe.nim 2>/dev/null |
		sed -n 's/.*"libpath": *"\([^"]*\)".*/\1/p' | head -1)"
	if [ -z "${nim_lib}" ] || [ ! -d "${nim_lib}" ]; then
		bad "oracle: could not resolve the Nim stdlib path from 'nim dump'"
	else
		# A module is JS-only when its `when not defined(js)` guard is followed
		# by a `{.fatal.}` or `{.error.}` pragma on the next line.
		# The awk program is single-quoted on purpose: its `$0` is awk's.
		# shellcheck disable=SC2016
		toolchain_js_only="$(find "${nim_lib}" -name '*.nim' -print0 |
			xargs -0 awk '
				FNR == 1 { guard = 0 }
				guard && /\{\.(fatal|error):/ {
					f = FILENAME; sub(/^.*\//, "", f); sub(/\.nim$/, "", f); print f; nextfile
				}
				{ guard = ($0 ~ /^when not defined\(js\)/) }
			' | sort -u)"
		missing="$(comm -23 <(printf '%s\n' "${toolchain_js_only}") \
			<(printf '%s\n' "${JS_ONLY_MODULES[@]}" | sort -u))"
		# The other direction matters as much: a name in the list that the
		# toolchain compiles natively would silently move every native suite
		# importing it out of `vm-unit`.
		extra="$(comm -13 <(printf '%s\n' "${toolchain_js_only}") \
			<(printf '%s\n' "${JS_ONLY_MODULES[@]}" | sort -u))"
		if [ -z "${toolchain_js_only}" ]; then
			bad "oracle: found no JS-only module under ${nim_lib} (the probe is broken)"
		elif [ -n "${missing}" ] || [ -n "${extra}" ]; then
			disagreements=()
			while read -r m; do
				[ -n "${m}" ] && disagreements+=("refused off JS but not listed: ${m}")
			done <<<"${missing}"
			while read -r m; do
				[ -n "${m}" ] && disagreements+=("listed but not refused off JS: ${m}")
			done <<<"${extra}"
			bad "oracle: the list here disagrees with the toolchain's JS-only modules" "${disagreements[@]}"
		else
			ok "oracle: the list is exactly the stdlib modules the toolchain refuses off JS ($(printf '%s\n' "${toolchain_js_only}" | wc -l | tr -d ' ') under ${nim_lib})"
		fi
	fi
else
	skip "oracle: nim is not on PATH, so the JS-only list is not checked against the toolchain"
fi

# ---------------------------------------------------------------------------
# 1 + 2. The real tree.
# ---------------------------------------------------------------------------
native_violations=""
for lane in vm-unit vm-unit-wasm; do
	while read -r f; do
		[ -n "${f}" ] || continue
		mods="$(js_only_imports "${repo_root}/${f}" | tr '\n' ' ')"
		if [ -n "${mods}" ]; then
			native_violations+="${lane}: ${f} imports ${mods}"$'\n'
		fi
	done < <(lane_files "${repo_root}" "${lane}")
done
if [ -z "${native_violations}" ]; then
	ok "native lanes (vm-unit, vm-unit-wasm) collect no suite that imports a JS-only module"
else
	mapfile -t lines < <(printf '%s' "${native_violations}")
	bad "native lanes collect suites the C backend cannot compile" "${lines[@]}"
fi

js_lane="$(lane_files "${repo_root}" vm-unit-js)"
js_missing=""
js_seen=0
for f in "${repo_root}/${unit_dir}"/test_*.nim; do
	[ -f "${f}" ] || continue
	[ -n "$(js_only_imports "${f}")" ] || continue
	js_seen=$((js_seen + 1))
	rel="${unit_dir}/$(basename "${f}")"
	count="$(printf '%s\n' "${js_lane}" | grep -cxF -- "${rel}")"
	if [ "${count}" != 1 ]; then
		js_missing+="${rel} (listed ${count} times)"$'\n'
	fi
done
if [ "${js_seen}" -eq 0 ]; then
	bad "JS lane: found no JS-only suite under ${unit_dir} (the parser is broken)"
elif [ -z "${js_missing}" ]; then
	ok "JS lane: all ${js_seen} JS-only suites under ${unit_dir} are in vm-unit-js exactly once"
else
	mapfile -t lines < <(printf '%s' "${js_missing}")
	bad "JS lane: JS-only suites not in vm-unit-js exactly once" "${lines[@]}"
fi

# ---------------------------------------------------------------------------
# 3 + 4. Synthetic tree.
# ---------------------------------------------------------------------------
tree="${work}/tree"
fx="${tree}/${unit_dir}"
mkdir -p "${fx}"

suite_body='import std/unittest

suite "fixture":
  test "runs":
    check true'

expected_js=()
for mod in "${JS_ONLY_MODULES[@]}"; do
	printf 'import std/%s\n%s\n' "${mod}" "${suite_body}" >"${fx}/test_fx_${mod}_std.nim"
	printf 'import std/[json, %s, options]\n%s\n' "${mod}" "${suite_body}" >"${fx}/test_fx_${mod}_group_mid.nim"
	printf 'import std/[%s]\n%s\n' "${mod}" "${suite_body}" >"${fx}/test_fx_${mod}_group_only.nim"
	printf 'import %s\n%s\n' "${mod}" "${suite_body}" >"${fx}/test_fx_${mod}_bare.nim"
	printf 'import json, std/%s as aliased\n%s\n' "${mod}" "${suite_body}" >"${fx}/test_fx_${mod}_list.nim"
	printf 'from std/%s import nothing\n%s\n' "${mod}" "${suite_body}" >"${fx}/test_fx_${mod}_from.nim"
	printf 'import std/[json, options,\n  %s, strutils]\n%s\n' "${mod}" "${suite_body}" >"${fx}/test_fx_${mod}_multiline.nim"
	for form in std group_mid group_only bare list from multiline; do
		expected_js+=("${unit_dir}/test_fx_${mod}_${form}.nim")
	done
done

# Native suites that mention a JS-only module without depending on it.
printf 'import std/[json, options]\n%s\n' "${suite_body}" >"${fx}/test_fx_native_plain.nim"
printf 'import std/json\nwhen defined(js):\n  import std/jsffi\n  import std/[asyncjs, dom]\n%s\n' \
	"${suite_body}" >"${fx}/test_fx_native_when_js.nim"
printf 'import std/json # asyncjs would not compile here\n# import std/asyncjs\n%s\n' \
	"${suite_body}" >"${fx}/test_fx_native_comment.nim"
printf 'import ../helpers/dom\nimport ../../sync/[socket_transport, jsffi]\nimport std/[json, asyncjs_shim_name]\nimport domain_model, jsffi_compat\n%s\n' \
	"${suite_body}" >"${fx}/test_fx_native_lookalike.nim"
printf 'import std/[json,\n  options]\nfrom std/strutils import dom\n%s\n' \
	"${suite_body}" >"${fx}/test_fx_native_multiline.nim"
expected_native=(
	"${unit_dir}/test_fx_native_comment.nim"
	"${unit_dir}/test_fx_native_lookalike.nim"
	"${unit_dir}/test_fx_native_multiline.nim"
	"${unit_dir}/test_fx_native_plain.nim"
	"${unit_dir}/test_fx_native_when_js.nim"
)

fx_native="$(lane_files "${tree}" vm-unit)"
fx_js="$(lane_files "${tree}" vm-unit-js)"

misrouted=()
# The fixtures below prove every module here is in the lib's list. They cannot
# see a name the lib lists and this file does not, which would drop native
# suites from `vm-unit` unnoticed, so compare the two lists outright.
lib_modules="$(
	# shellcheck source=ci/lib/test-lane-files.sh
	source "${lib}"
	printf '%s\n' "${_TLF_JS_ONLY_STDLIB_MODULES}" | tr '|' '\n' | sort -u
)"
if [ "${lib_modules}" != "$(printf '%s\n' "${JS_ONLY_MODULES[@]}" | sort -u)" ]; then
	misrouted+=("the lib's _TLF_JS_ONLY_STDLIB_MODULES differs from JS_ONLY_MODULES here: $(printf '%s' "${lib_modules}" | tr '\n' ' ')")
fi
for f in "${expected_js[@]}"; do
	in_native="$(printf '%s\n' "${fx_native}" | grep -cxF -- "${f}")"
	in_js="$(printf '%s\n' "${fx_js}" | grep -cxF -- "${f}")"
	if [ "${in_native}" != 0 ] || [ "${in_js}" != 1 ]; then
		misrouted+=("${f}: vm-unit=${in_native} vm-unit-js=${in_js} (want 0 and 1)")
	fi
done
if [ "${#misrouted[@]}" -eq 0 ]; then
	ok "positive control: ${#expected_js[@]} unlisted JS-only fixture suites are discovered into vm-unit-js and kept out of vm-unit"
else
	bad "positive control: JS-only fixture suites misrouted (${#misrouted[@]} of ${#expected_js[@]})" "${misrouted[@]}"
fi

wrongly_dropped=()
for f in "${expected_native[@]}"; do
	in_native="$(printf '%s\n' "${fx_native}" | grep -cxF -- "${f}")"
	in_js="$(printf '%s\n' "${fx_js}" | grep -cxF -- "${f}")"
	if [ "${in_native}" != 1 ] || [ "${in_js}" != 1 ]; then
		wrongly_dropped+=("${f}: vm-unit=${in_native} vm-unit-js=${in_js} (want 1 and 1)")
	fi
done
# The runner consumes the lane list one file per line; a file listed twice
# would compile and score twice.
if [ -n "$(printf '%s\n' "${fx_js}" | sort | uniq -d)" ]; then
	wrongly_dropped+=("vm-unit-js lists a file more than once")
fi
if [ "${#wrongly_dropped[@]}" -eq 0 ]; then
	ok "negative control: native fixture suites that only mention a JS-only module stay in both lanes"
else
	bad "negative control: native fixture suites misrouted" "${wrongly_dropped[@]}"
fi

echo
if [ $((checks + skips)) -ne "${TOTAL_CONTRACTS}" ]; then
	echo "vm-unit-js-only-suites: ran ${checks} + skipped ${skips}, expected ${TOTAL_CONTRACTS} contracts" >&2
	exit 1
fi
if [ "${failures}" -ne 0 ]; then
	echo "vm-unit-js-only-suites: ${failures} of ${checks} contract(s) FAILED (${skips} skipped)" >&2
	exit 1
fi
echo "vm-unit-js-only-suites: ${checks} contract(s) passed, ${skips} skipped"
