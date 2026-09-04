#!/usr/bin/env bash
#
# watch-expressions-in-browser.sh — a user types a watch expression into the
# State pane, in a real browser, and sees a correct value.
#
# WHAT THIS ASSERTS THAT NOTHING ELSE DOES
# ----------------------------------------
# `src/db-backend/tests/watch_expressions_dap_test.rs` proves the backend
# answers `ct/load-locals` with one row per watch expression, values and
# refusals both, over the real request path. It stops at the wire.
# `test_five_panes_drive_headlessly` proves the Watches tab renders whatever
# the store holds. Both drive code no user touches.
#
# All of that was true of a product in which the Watches tab COULD NOT BE
# OPENED: the tab strip existed only in the MockRenderer that the headless
# view tests render, and the WebRenderer panel — the one browsers run —
# had no tab strip at all. `stWatches` was reachable from `vm.selectTab`
# and from no gesture anywhere.
#
# So this gate's subject is the gesture: CLICK the Watches tab, TYPE into
# the watch box, press Enter, and read what painted.
#
# WHAT IT DOES NOT COVER, said plainly: there is no engine on this page. The
# transport half is `watch_expressions_dap_test.rs`'s, and the fixture this
# page renders is that suite's own captured response body, so the two cannot
# drift apart silently.
#
# PAINTED TEXT, NEVER `innerText` ALONE. Every row counted below is
# hit-tested with `elementFromPoint` at its own start — `web-renderer-
# mounts.sh` records what that distinction cost the last time it was skipped.
#
# Usage:  bash ci/test/watch-expressions-in-browser.sh [screenshot.png]
# Exit:   0 all assertions held, 1 otherwise, 2 could not run.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)"
cd "${repo_root}" || exit 2

shot="${1:-}"
cache="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}/watch-expressions-in-browser"
rm -rf "${cache}"
mkdir -p "${cache}"

checks=0
failures=0

ck() {
	local verdict="$1"
	shift
	checks=$((checks + 1))
	if [ "${verdict}" = ok ]; then
		echo "  [OK]     $*"
	else
		echo "  [FAILED] $*"
		failures=$((failures + 1))
	fi
}
note() { echo "      $*"; }

for tool in node python3; do
	command -v "${tool}" >/dev/null 2>&1 || {
		echo "watch-expressions-in-browser.sh: no '${tool}' on PATH." >&2
		echo "  remedy: run inside the dev shell (direnv exec ${repo_root} ...)" >&2
		exit 2
	}
done

echo "=== a typed watch expression, in a browser ==="
echo

# ---------------------------------------------------------------------------
# Build the probe.
# ---------------------------------------------------------------------------
build_probe() {
	local out="$1" src="$2"
	# THE SHIPPED WEB ARM'S DEFINES, not just `-d:ctWeb`. `ci/lib/test-lane-
	# files.sh` gives `renderer-web` exactly these three, and the missing
	# `-d:ctRenderer` is not cosmetic: without it `src/common/paths.nim`
	# reaches `require("os")` at MODULE SCOPE and the page dies with
	# "require is not defined" before the pane mounts — measured.
	nim js -d:ctWeb -d:ctRenderer -d:chronicles_enabled=off \
		--hints:off --warnings:off --path:src --path:src/frontend/viewmodel \
		-o:"${out}/probe.js" "${src}" >"${out}/build.log" 2>&1
	[ -s "${out}/probe.js" ]
}

if ! build_probe "${cache}" ci/test/watch_expressions_browser_probe.nim; then
	echo "  the probe did not build; see ${cache}/build.log" >&2
	tail -20 "${cache}/build.log" >&2
	exit 2
fi
note "built ${cache}/probe.js ($(wc -c <"${cache}/probe.js" | tr -d ' ') bytes)"

# THE REAL STYLESHEET, not a hand-written one. The pane's readability is a
# property of the shipped styles, so a probe styled by anything else would be
# reporting on a pane that does not ship.
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
	exit 2
fi

cp ci/test/watch-expressions-probe/index.html "${cache}/index.html"
cp ci/test/watch-expressions-probe/run.mjs "${cache}/run.mjs"

if [ -z "${CT_CHROME:-}" ]; then
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
# `node_modules` upward from the importing FILE.
nm="$(node -e 'console.log(require.resolve("playwright").replace(/\/playwright\/index.js$/,""))' 2>/dev/null)"
if [ -z "${nm}" ] || [ ! -d "${nm}" ]; then
	echo "  playwright is not resolvable; run inside the dev shell (LOUD SKIP)" >&2
	exit 2
fi
ln -sfn "${nm}" "${cache}/node_modules"

run_probe() {
	local dir="$1" out="$2" png="${3:-}"
	node "${dir}/run.mjs" "file://${dir}/index.html" "${png}" >"${out}" 2>&1
	grep -q '^PROBE_JSON=' "${out}"
}

# `python3` rather than `jq`: this gate needs to read nested arrays and jq is
# not guaranteed on every machine that has node and python.
q() {
	python3 - "$1" "$2" <<-'PY'
		import json, sys
		blob = ""
		for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
		    if line.startswith("PROBE_JSON="):
		        blob = line[len("PROBE_JSON="):]
		if not blob:
		    print(""); raise SystemExit(0)
		d = json.loads(blob)
		expr = sys.argv[2]
		try:
		    print(eval(expr, {"d": d, "rowtext": lambda rows, name: next((r["text"] for r in rows if r["name"] == name), "")}))
		except Exception as e:
		    print("")
	PY
}

# ---------------------------------------------------------------------------
echo "The control: the State pane, in a browser, driven by gestures"
# ---------------------------------------------------------------------------
control="${cache}/control.out"
if ! run_probe "${cache}" "${control}" "${shot}"; then
	echo "  the probe did not complete; see ${control}" >&2
	tail -25 "${control}" >&2
	exit 2
fi

note "summary line: $(q "${control}" 'd["summary"]')"

ck "$([ "$(q "${control}" 'd["paneMounted"]')" = True ] && echo ok || echo no)" \
	"the State pane mounted in a browser"

# THE TAB STRIP, asserted on its own and FIRST. It was absent from the web
# renderer entirely; without this every assertion below fails for one reason
# and the report cannot say which layer broke.
ck "$([ -n "$(q "${control}" 'd["tabsBefore"]["watchesTab"]')" ] &&
	[ "$(q "${control}" 'd["tabsBefore"]["watchesTab"]')" != None ] && echo ok || echo no)" \
	"the Watches TAB BUTTON exists in the WebRenderer panel (it existed only in the Mock one)"
ck "$([ "$(q "${control}" 'd["watchInputPresent"]')" = True ] && echo ok || echo no)" \
	"the watch input is present as #watch-0"

# The pane opens on Locals and holds the recorded locals.
ck "$([ "$(q "${control}" 'rowtext(d["localsRows"], "initial_shield")')" != "" ] && echo ok || echo no)" \
	"the Locals tab paints the recorded local initial_shield"
ck "$([ "$(q "${control}" '"10000" in rowtext(d["localsRows"], "initial_shield")')" = True ] && echo ok || echo no)" \
	"and its value is the recorded 10000"
# A WATCH ROW MUST NOT BE IN THE LOCALS TAB. The two lists arrive in one
# response and a host that forgot to split them would show watches here.
ck "$([ "$(q "${control}" 'rowtext(d["localsRows"], "asteroid_masses[1]")')" = "" ] && echo ok || echo no)" \
	"and a watch answer is NOT among the locals"

# ---- the gesture ----------------------------------------------------------
ck "$([ "$(q "${control}" '"active" in (d["tabsAfterClick"]["watchesTab"] or "")')" = True ] && echo ok || echo no)" \
	"clicking the Watches tab button selects it"

# THE HEADLINE: a named expression, a known value.
#
# `asteroid_masses[1]` is 2000 while `[0]` is 100 and the recorded sequence
# contains both, so a pane that showed the container, the wrong element, or
# the locals list cannot satisfy this.
watch_1="$(q "${control}" 'rowtext(d["watchRows"], "asteroid_masses[1]")')"
note "asteroid_masses[1] row: ${watch_1}"
ck "$([ "${watch_1}" != "" ] && echo ok || echo no)" \
	"the Watches tab paints a row for asteroid_masses[1]"
ck "$([ "$(q "${control}" '"2000" in rowtext(d["watchRows"], "asteroid_masses[1]")')" = True ] && echo ok || echo no)" \
	"and its value is 2000 — the element, from the recording"
ck "$([ "$(q "${control}" '"100," in rowtext(d["watchRows"], "asteroid_masses[1]")')" = False ] && echo ok || echo no)" \
	"and it is that ELEMENT, not the sequence containing it"

# THE REFUSAL PATH, with its own assertion. A pane whose two states are "a
# value" and "nothing" is the defect this whole change exists to remove.
refusal="$(q "${control}" 'rowtext(d["watchRows"], "initial_shield + 1")')"
note "initial_shield + 1 row: ${refusal}"
ck "$([ "${refusal}" != "" ] && echo ok || echo no)" \
	"an unanswerable watch is a ROW, not an absence"
ck "$([ "$(q "${control}" '"cannot evaluate" in rowtext(d["watchRows"], "initial_shield + 1")')" = True ] && echo ok || echo no)" \
	"and it carries a stated reason"
ck "$([ "$(q "${control}" '"only holds the values that were actually recorded" in rowtext(d["watchRows"], "initial_shield + 1")')" = True ] && echo ok || echo no)" \
	"and the reason says why a RECORDING cannot answer it"

# ---- typing ---------------------------------------------------------------
ck "$([ "$(q "${control}" 'd["inputClearedAfterSubmit"]')" = True ] && echo ok || echo no)" \
	"submitting the form clears the input (the gesture was accepted)"
ck "$([ "$(q "${control}" '"3" in rowtext(d["rowsAfterTyping"], "landing_point.x")')" = True ] && echo ok || echo no)" \
	"a TYPED expression landing_point.x shows its recorded value 3"
ck "$([ "$(q "${control}" '"cannot evaluate" in rowtext(d["rowsAfterRefusal"], "not_recorded_here")')" = True ] && echo ok || echo no)" \
	"a TYPED expression the recording cannot answer shows a reason, not a blank tab"

ck "$([ "$(q "${control}" 'd["loadingVisible"]')" = False ] && echo ok || echo no)" \
	'the pane is not still saying "Loading..." over the rows it has painted'

errs="$(q "${control}" 'len(d["pageErrors"])')"
ck "$([ "${errs}" = "0" ] && echo ok || echo no)" \
	"zero uncaught page errors (${errs})"

note "rows rejected by the hit test (rows with no laid-out element at all): $(q "${control}" 'd["watchRejected"]')"
note "painted characters: $(q "${control}" 'd["paintedChars"]')"
[ -n "${shot}" ] && note "screenshot: ${shot}"
echo

# ---------------------------------------------------------------------------
echo "Mutation arm A: the WebRenderer has no tab strip (the pre-fix panel)"
echo "    Reddens the TAB assertion and, through it, everything the user"
echo "    could only reach by clicking that tab. This is the state the"
echo "    product shipped in: the Watches tab existed and no gesture opened it."
# ---------------------------------------------------------------------------
arm_a="${cache}/arm-a"
mkdir -p "${arm_a}"
cp -R "${cache}/index.html" "${cache}/run.mjs" "${cache}/codetracer.css" "${arm_a}/" 2>/dev/null
ln -sfn "${nm}" "${arm_a}/node_modules"
# Remove the tab strip from the mounted panel, in the page, so the arm
# reproduces the pre-fix WebRenderer without editing the Nim source.
python3 - "${arm_a}/index.html" <<'PY'
import sys
path = sys.argv[1]
html = open(path).read()
inject = """<script>
/* ARM A INSTRUMENT — the pre-fix WebRenderer panel, which had no tab strip. */
new MutationObserver(function () {
  document.querySelectorAll('#ct-state-pane .state-tabs').forEach(function (el) {
    el.remove();
  });
}).observe(document.documentElement, { childList: true, subtree: true });
</script>"""
html = html.replace('<script src="./probe.js">', inject + '<script src="./probe.js">', 1)
open(path, 'w').write(html)
PY
grep -q 'ARM A INSTRUMENT' "${arm_a}/index.html" || {
	echo "  arm A: the instrument was not injected — this arm would grade the control" >&2
	exit 2
}
cp "${cache}/probe.js" "${arm_a}/probe.js"
arm_a_out="${cache}/arm-a.out"
if run_probe "${arm_a}" "${arm_a_out}"; then
	a_tab="$(q "${arm_a_out}" 'd["tabsBefore"]["watchesTab"]')"
	ck "$({ [ "${a_tab}" = "None" ] || [ "${a_tab}" = "" ]; } && echo ok || echo no)" \
		"arm A: with no tab strip the Watches tab button is absent (was: ${a_tab})"
	# AND THE GESTURE FAILS, which is the user-visible consequence: with no
	# button there is nothing to click, so the Watches tab cannot be opened.
	ck "$([ "$(q "${arm_a_out}" 'd["watchesTabClicked"]')" = False ] && echo ok || echo no)" \
		"arm A: and the Watches tab CANNOT BE OPENED by a gesture — the shipped defect"
	# THE ARM BREAKS ONE THING. The watch input is a sibling of the strip, so
	# if it vanished too the red above would be evidence that the arm broke the
	# probe rather than that the assertion works.
	ck "$([ "$(q "${arm_a_out}" 'd["watchInputPresent"]')" = True ] && echo ok || echo no)" \
		"arm A: the watch input is still there (the arm removes the STRIP, not the pane)"
else
	ck no "arm A: the probe did not complete"
fi
echo

# ---------------------------------------------------------------------------
echo "Mutation arm B: the response carries no watch rows (the pre-fix backend)"
echo "    Reddens the VALUE and REFUSAL assertions. This is what"
echo "    Db::load_locals answered while it dropped watchExpressions"
echo "    with a warn!: the locals, correct, and nothing else."
# ---------------------------------------------------------------------------
arm_b="${cache}/arm-b"
mkdir -p "${arm_b}"
cp "${cache}/index.html" "${cache}/run.mjs" "${cache}/codetracer.css" "${arm_b}/" 2>/dev/null
ln -sfn "${nm}" "${arm_b}/node_modules"
# Rebuild the probe against a fixture with every watch row stripped — the
# pre-fix backend's answer, byte for byte minus the rows it never produced.
arm_b_fixture="${cache}/arm-b-fixture"
mkdir -p "${arm_b_fixture}/watch-expressions-probe"
python3 - ci/test/watch-expressions-probe/backend-response.json \
	"${arm_b_fixture}/watch-expressions-probe/backend-response.json" <<'PY'
import json, sys
body = json.load(open(sys.argv[1]))
before = len(body["locals"])
body["locals"] = [r for r in body["locals"] if not r.get("value", {}).get("isWatch")]
after = len(body["locals"])
if before == after:
    raise SystemExit("arm B: the fixture had no watch rows to remove — this arm would grade the control")
json.dump(body, open(sys.argv[2], "w"), indent=2)
print(f"      arm B: removed {before - after} watch row(s) from the fixture")
PY
[ -s "${arm_b_fixture}/watch-expressions-probe/backend-response.json" ] || exit 2
# COMPILED FROM THE PROBE WHERE IT LIVES, with the fixture redirected by a
# `-d:` define. Copying the probe elsewhere breaks its relative imports
# (`cannot open file: isonim/core/signals`), which would make this arm report
# a build failure instead of a product reading.
if nim js -d:ctWeb -d:ctRenderer -d:chronicles_enabled=off \
	-d:WatchFixturePath:"${arm_b_fixture}/watch-expressions-probe/backend-response.json" \
	--hints:off --warnings:off --path:src --path:src/frontend/viewmodel \
	-o:"${arm_b}/probe.js" ci/test/watch_expressions_browser_probe.nim \
	>"${cache}/arm-b-build.log" 2>&1 &&
	[ -s "${arm_b}/probe.js" ]; then
	arm_b_out="${cache}/arm-b.out"
	if run_probe "${arm_b}" "${arm_b_out}"; then
		ck "$([ "$(q "${arm_b_out}" 'rowtext(d["watchRows"], "asteroid_masses[1]")')" = "" ] && echo ok || echo no)" \
			"arm B: no watch value is painted"
		ck "$([ "$(q "${arm_b_out}" 'rowtext(d["watchRows"], "initial_shield + 1")')" = "" ] && echo ok || echo no)" \
			"arm B: no refusal is painted either — a watch simply vanishes"
		# The arm must leave the LOCALS intact, or its red says only that the
		# fixture broke.
		ck "$([ "$(q "${arm_b_out}" '"10000" in rowtext(d["localsRows"], "initial_shield")')" = True ] && echo ok || echo no)" \
			"arm B: the locals are still correct (the arm removes WATCHES, not the response)"
	else
		ck no "arm B: the probe did not complete"
	fi
else
	echo "  arm B: the probe did not rebuild; see ${cache}/arm-b-build.log" >&2
	tail -10 "${cache}/arm-b-build.log" >&2
	ck no "arm B: could not build"
fi
echo

echo "${checks} check(s), ${failures} failure(s)"
if [ "${failures}" -eq 0 ]; then
	echo "RESULT: OK — a typed watch expression shows a correct value, and an unanswerable one says why"
	exit 0
fi
echo "RESULT: FAILED — ${failures} check(s)"
exit 1
