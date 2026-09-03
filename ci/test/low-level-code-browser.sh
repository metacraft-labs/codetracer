#!/usr/bin/env bash
#
# low-level-code-browser.sh — the Low Level Code pane, in a real browser,
# painting a real compiler's output.
#
# WHY THIS EXISTS
# ---------------
# `GUI/Debugging-Features/Generated-Code-Listing.md` §0a.2 records a capability
# that was present, correct, tested and unreachable: the anchoring model had 336
# counted assertions behind it and the view read none of it. The headless suite
# `test_low_level_code_view_anchors` covers the MOCK renderer. The Web renderer
# is a separate code path in the same file, and a mock-only suite is green over
# a surface nobody sees — Verification-Harness-Traps.md trap 3.
#
# So this builds the WEB arm (`nim js`, browser target, NOT `-d:nodejs`), mounts
# it in Chromium, and reads the painted DOM.
#
# THE INSTRUMENT IS CONTROLLED FIRST, and that is not ceremony. On 2026-08-31
# the sibling gate `web-renderer-mounts.sh` blocked a deploy reporting "0
# characters on screen" over a DOM that renders correctly, because its nix
# Chromium had no fonts and laid out every string with zero glyphs. A zero from
# an instrument that cannot produce a non-zero is not evidence. `run.mjs`
# therefore draws a plain sentence and exits 3 if it cannot see it.
#
# NETWORK: none. The page is `file://`, the fixture is compiled in.
#
# Usage:  bash ci/test/low-level-code-browser.sh
# Env:    CT_CHROME  path to a Chromium binary (default: from
#                    PLAYWRIGHT_BROWSERS_PATH)
set -uo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

cache="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}/low-level-code-browser"
rm -rf "${cache}"; mkdir -p "${cache}"

checks=0; failures=0
ck() {
	checks=$((checks + 1))
	if [ "$1" = "ok" ]; then printf '  [OK]      %s\n' "$2"
	else failures=$((failures + 1)); printf '  [FAILED]  %s\n' "$2"; fi
}

echo "=== the Low Level Code pane paints a real circuit ==="

# NEVER TRUST AN EXIT CODE: `nim js` exits 0 while writing no artifact, so the
# output is named explicitly and tested for.
nim js -d:ctWeb --hints:off --warnings:off \
	--nimcache:"${cache}/nimcache" -o:"${cache}/probe.js" \
	ci/test/low_level_code_browser_probe.nim >"${cache}/build.log" 2>&1
if [ ! -s "${cache}/probe.js" ]; then
	echo "  the probe did not build; see ${cache}/build.log" >&2
	tail -20 "${cache}/build.log" >&2
	exit 1
fi
echo "  built ${cache}/probe.js ($(wc -c <"${cache}/probe.js" | tr -d ' ') bytes,"\
     "sha256 $(shasum -a 256 "${cache}/probe.js" | awk '{print $1}'))"

cp ci/test/low-level-code-probe/index.html "${cache}/index.html"
cp ci/test/low-level-code-probe/run.mjs "${cache}/run.mjs"

if [ -z "${CT_CHROME:-}" ]; then
	# TWO SEPARATE FINDS, not one with `-o`. A single expression made the
	# `-maxdepth` of the second branch bind after the `-o`, matched nothing, and
	# the script reported "no Chromium" beside a Chromium that was right there —
	# a SKIP produced by the search, not by the environment.
	# `find -L`, because the nix browsers directory is a tree of SYMLINKS into
	# the store and an unfollowed find walks none of it — the second way this
	# lookup produced a skip that described the search rather than the machine.
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
# ESM IGNORES NODE_PATH. `import { chromium } from 'playwright'` resolves by
# walking `node_modules` upward from the importing FILE, so pointing an env var
# at the nix module tree does nothing — the run fails with ERR_MODULE_NOT_FOUND
# even though `require.resolve` finds the package. Link the tree beside the
# runner instead, which is the only thing ESM resolution looks at.
nm="$(node -e 'console.log(require.resolve("playwright").replace(/\/playwright\/index.js$/,""))' 2>/dev/null)"
if [ -z "${nm}" ] || [ ! -d "${nm}" ]; then
	echo "  playwright is not resolvable; run inside the dev shell (LOUD SKIP)" >&2
	exit 2
fi
ln -sfn "${nm}" "${cache}/node_modules"

node "${cache}/run.mjs" "file://${cache}/index.html" >"${cache}/probe.json" 2>&1
rc=$?
cat "${cache}/probe.json"
if [ "${rc}" = "3" ]; then
	echo "  the BROWSER cannot draw text; this says nothing about the product" >&2
	exit 2
fi

# ONE object, from a marked line. Reading "first { to last }" spanned BOTH
# JSON blocks the runner prints and parsed neither — six failures beside a
# perfectly good measurement, which is a harness defect wearing a product
# defect's clothes.
grep '^PROBE_JSON=' "${cache}/probe.json" | tail -1 | cut -d= -f2- >"${cache}/probe.one.json"
if [ ! -s "${cache}/probe.one.json" ]; then
	echo "  the probe printed no PROBE_JSON line; the browser run did not complete" >&2
	exit 1
fi
j() { python3 -c "import json;print(json.load(open('${cache}/probe.one.json')).get('$1'))"; }

if [ "$(j paneMounted)" = "True" ]; then ck ok "the pane mounted in a real browser"; else ck no "the pane mounted in a real browser"; fi
if [ "$(j rowCount)" = "17" ]; then ck ok "17 rows — one per ACIR opcode, agreeing with nargo info"; else ck no "17 rows (got $(j rowCount))"; fi
if [ "$(j countColumns)" = "0" ]; then ck ok "no count column for cpNone — a 0 would read as 'never ran'"; else ck no "no count column for cpNone"; fi
tally="$(python3 -c "import json;t=json.load(open('${cache}/probe.one.json'))['fidelityTally'];print(','.join(f'{k}={v}' for k,v in sorted(t.items())))")"
# THE ASSERTION THIS GATE EXISTS FOR. Not "a badge is present" — the exact
# split the model computes: rows 0-1 exact (main.nr:9), rows 2-16 merged
# (main.nr:10 inlined into utils.nr:7). A view that stamped one rung on every
# row would satisfy an existence check and have lost all the information.
if [ "${tally}" = "exact=2,merged=15" ]; then ck ok "fidelity on screen is exact=2, merged=15 — the model's own answer"; else ck no "fidelity tally is ${tally}, expected exact=2,merged=15"; fi
if [ "$(j syncText)" = "sync on" ]; then ck ok "the sync toggle draws its default-on state"; else ck no "the sync toggle draws its default-on state"; fi
if [ "$(j pageErrors)" = "[]" ]; then ck ok "no page errors"; else ck no "no page errors: $(j pageErrors)"; fi
pc="$(j paintedChars)"
if [ "${pc:-0}" -gt 200 ]; then ck ok "${pc} characters painted"; else ck no "only ${pc} characters painted"; fi

echo
echo "checks: ${checks}, failures: ${failures}"
[ "${failures}" = "0" ] || exit 1
