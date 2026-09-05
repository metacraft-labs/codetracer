#!/usr/bin/env bash
#
# constraints-listing-browser.sh — the CONSTRAINTS pane, in a real browser,
# painting a real compiler's ACIR listing.
#
# WHY THIS EXISTS
# ---------------
# The pane counted for its whole first life: `reportFromAcirListing` parsed the
# compiler's printed opcodes and kept only how many rows it had seen. Every
# headless suite over it asserted a NUMBER, so every one of them was satisfied
# by a pane that showed a user three integers where they had asked to read
# their circuit. A count in a ViewModel is not a listing on a screen.
#
# So this builds the WEB arm (`nim js`, browser target, NOT -d:nodejs), mounts
# it in Chromium, and reads the PAINTED rows — hit-tested, because a row with a
# zero-height box is not one a user can read. Same argument and same shape as
# `low-level-code-browser.sh` beside it, which this is modelled on.
#
# THE INSTRUMENT IS CONTROLLED FIRST. `run.mjs` draws a plain sentence and
# exits 3 if it cannot see it; see the comment there for the deploy this rule
# was bought with.
#
# NETWORK: none. The page is `file://`, the fixture is compiled in.
#
# Usage:  bash ci/test/constraints-listing-browser.sh [screenshot.png]
# Env:    CT_CHROME  path to a Chromium binary (default: from
#                    PLAYWRIGHT_BROWSERS_PATH)
set -uo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=ci/lib/nim-cache-root.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "${repo_root}/ci/lib/nim-cache-root.sh"
cd "${repo_root}" || exit 2

shot="${1:-}"
cache="$(ct_nim_cache_root "${repo_root}")/constraints-listing-browser"
rm -rf "${cache}"
mkdir -p "${cache}"

checks=0
failures=0
ck() {
	checks=$((checks + 1))
	if [ "$1" = "ok" ]; then
		printf '  [OK]      %s\n' "$2"
	else
		failures=$((failures + 1))
		printf '  [FAILED]  %s\n' "$2"
	fi
}

echo "=== the CONSTRAINTS pane paints a real circuit's generated code ==="

# NEVER TRUST AN EXIT CODE: `nim js` exits 0 while writing no artifact, so the
# output is named explicitly and tested for.
nim js -d:ctWeb --hints:off --warnings:off \
	--nimcache:"${cache}/nimcache" -o:"${cache}/probe.js" \
	ci/test/constraints_listing_browser_probe.nim >"${cache}/build.log" 2>&1
if [ ! -s "${cache}/probe.js" ]; then
	echo "  the probe did not build; see ${cache}/build.log" >&2
	tail -20 "${cache}/build.log" >&2
	exit 1
fi
echo "  built ${cache}/probe.js ($(wc -c <"${cache}/probe.js" | tr -d ' ') bytes," \
	"sha256 $(shasum -a 256 "${cache}/probe.js" | awk '{print $1}'))"

# THE REAL STYLESHEET, not a hand-written one. The listing's readability is a
# property of `components/ns9_panes.styl`, so a probe styled by anything else
# would be reporting on a pane that does not ship.
stylus="$(command -v stylus || true)"
[ -n "${stylus}" ] || stylus="$(node -e 'console.log(require.resolve("stylus/bin/stylus"))' 2>/dev/null || true)"
if [ -z "${stylus}" ]; then
	echo "  stylus is not available; run inside the dev shell (LOUD SKIP, not a pass)" >&2
	exit 2
fi
"${stylus}" --include src/frontend/styles --include src/frontend/styles/generated \
	<src/frontend/styles/codetracer.styl >"${cache}/codetracer.css" 2>"${cache}/styl.log"
if [ ! -s "${cache}/codetracer.css" ]; then
	echo "  the stylesheet did not compile; see ${cache}/styl.log" >&2
	exit 1
fi

cp ci/test/constraints-listing-probe/index.html "${cache}/index.html"
cp ci/test/constraints-listing-probe/run.mjs "${cache}/run.mjs"

if [ -z "${CT_CHROME:-}" ]; then
	# TWO SEPARATE FINDS, and `find -L`: see `low-level-code-browser.sh` for the
	# two ways this lookup once produced a skip that described the search
	# rather than the machine.
	CT_CHROME="$(find -L "${PLAYWRIGHT_BROWSERS_PATH:-/nonexistent}" \
		-path '*/Chromium.app/Contents/MacOS/Chromium' -type f 2>/dev/null | head -1)"
	if [ -z "${CT_CHROME}" ]; then
		CT_CHROME="$(find -L "${PLAYWRIGHT_BROWSERS_PATH:-/nonexistent}" \
			-name 'chrome' -type f 2>/dev/null | head -1)"
	fi
fi
if [ -z "${CT_CHROME}" ] || [ ! -x "${CT_CHROME}" ]; then
	echo "  no Chromium found; run inside the dev shell (LOUD SKIP, not a pass)" >&2
	exit 2
fi
export CT_CHROME

# ESM IGNORES NODE_PATH: `import ... from 'playwright'` resolves by walking
# `node_modules` upward from the importing FILE. Link the tree beside the
# runner, which is the only thing ESM resolution looks at.
nm="$(node -e 'console.log(require.resolve("playwright").replace(/\/playwright\/index.js$/,""))' 2>/dev/null)"
if [ -z "${nm}" ] || [ ! -d "${nm}" ]; then
	echo "  playwright is not resolvable; run inside the dev shell (LOUD SKIP)" >&2
	exit 2
fi
ln -sfn "${nm}" "${cache}/node_modules"

node "${cache}/run.mjs" "file://${cache}/index.html" "${shot}" >"${cache}/probe.out" 2>&1
rc=$?
cat "${cache}/probe.out"
if [ "${rc}" = "3" ]; then
	echo "  the BROWSER cannot draw text; this says nothing about the product" >&2
	exit 2
fi

# ONE object, from a marked line — the runner prints the same JSON twice and a
# "first { to last }" read would span both and parse neither.
grep '^PROBE_JSON=' "${cache}/probe.out" | tail -1 | cut -d= -f2- >"${cache}/probe.json"
if [ ! -s "${cache}/probe.json" ]; then
	echo "  the probe printed no PROBE_JSON line; the browser run did not complete" >&2
	exit 1
fi
j() { python3 -c "import json;print(json.load(open('${cache}/probe.json')).get('$1'))"; }

if [ "$(j paneMounted)" = "True" ]; then ck ok "the pane mounted in a real browser"; else ck no "the pane mounted in a real browser"; fi

# THE ASSERTION THIS GATE EXISTS FOR. Not "the pane has rows" — 34 laid-out
# opcode rows, which is every opcode of both currencies: 17 ACIR and 17
# unconstrained. A pane that counted and did not list satisfies every other
# check in this file and fails this one.
if [ "$(j opcodeRowsLaidOut)" = "34" ]; then ck ok "34 opcode rows PAINTED — the whole listing, both currencies"; else ck no "34 opcode rows painted (got $(j opcodeRowsLaidOut) laid out of $(j opcodeRows) in the DOM)"; fi

# THE COUNTS ARE STILL THERE. The listing was added beside them, not instead
# of them, and this is what would catch a later change that traded one for the
# other.
headings="$(python3 -c "import json;print('|'.join(json.load(open('${cache}/probe.json'))['functionHeadings']))")"
if [ "${headings}" = "func 0 acir 17|directive_invert unconstrained 9|directive_integer_quotient unconstrained 8" ]; then
	ck ok "the three counted headings survive above their opcodes"
else
	ck no "function headings are '${headings}'"
fi
if [ "$(j headline)" = "17 ACIR opcodes, 17 unconstrained" ]; then ck ok "the headline still carries both totals"; else ck no "headline is '$(j headline)'"; fi

# THE COMPILER'S OWN TEXT, not a summary of it.
first="$(j firstRowText)"
case "${first}" in
*"BRILLIG CALL func: 0, predicate: 1, inputs: [w0 - w1], outputs: [w2]"*)
	ck ok "row 0 is the compiler's own opcode text, verbatim"
	;;
*) ck no "row 0 reads '${first}'" ;;
esac

# The listing is wider than the pane and SCROLLS rather than clipping: the
# field constants in this circuit are 60+ digits, and a clipped opcode is a
# wrong opcode.
sw="$(j listingScrollWidth)"
cw="$(j listingClientWidth)"
if [ "${sw:-0}" -gt "${cw:-0}" ]; then ck ok "the listing scrolls (${sw}px of content in a ${cw}px pane) instead of clipping"; else ck no "the listing does not scroll: ${sw}px content, ${cw}px pane"; fi

# A `nargo info` report has totals and no rows, and SAYS SO rather than
# rendering a blank listing body.
if [ "$(j countsOpcodeRows)" = "0" ]; then ck ok "a nargo-info report draws no opcode rows"; else ck no "a nargo-info report drew $(j countsOpcodeRows) opcode rows"; fi
case "$(j countsNotice)" in
*"totals, not the generated code"*) ck ok "and captions itself as totals rather than generated code" ;;
*) ck no "the totals caption reads '$(j countsNotice)'" ;;
esac

# THE DEGRADATION PATH. A successful build on an engine that prints no listing
# must KEEP the counts. It used to replace the whole pane with "unavailable",
# which is what every build on the current deploy pin did.
if [ "$(j degradedRows)" = "3" ]; then ck ok "a build with no listing KEEPS its three counts"; else ck no "a build with no listing left $(j degradedRows) count rows"; fi
if [ "$(j degradedHeadline)" = "17 ACIR opcodes, 17 unconstrained" ]; then ck ok "and keeps its headline instead of saying 'unavailable'"; else ck no "degraded headline is '$(j degradedHeadline)'"; fi
case "$(j degradedNotice)" in
*"does not print a constraint listing"*) ck ok "and states why the generated code is missing" ;;
*) ck no "the degraded caption reads '$(j degradedNotice)'" ;;
esac

if [ "$(j pageErrors)" = "[]" ]; then ck ok "no page errors"; else ck no "no page errors: $(j pageErrors)"; fi
pc="$(j paintedChars)"
if [ "${pc:-0}" -gt 800 ]; then ck ok "${pc} characters painted"; else ck no "only ${pc} characters painted"; fi

echo
echo "checks: ${checks}, failures: ${failures}"
[ "${failures}" = "0" ] || exit 1
