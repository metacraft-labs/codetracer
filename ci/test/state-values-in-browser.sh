#!/usr/bin/env bash
#
# state-values-in-browser.sh — a recorded value reaches the State pane, in a
# real browser, and is shown as the value it is.
#
# WHAT THIS ASSERTS THAT NOTHING ELSE DOES
# ----------------------------------------
# `watch_expressions_dap_test.rs` proves the backend answers `ct/load-locals`
# correctly. `watch-expressions-in-browser.sh` proves the State pane's tabs
# and inputs are reachable by gesture. Between the two there is a gap the
# size of this gate, and two defects lived in it.
#
# 1. THE PANE HAD THE WRONG RENDERER. `text_representation.nim` defines two
#    renderings of a recorded `Value`: `textRepr`, the value's own — which
#    `ui/value.nim:789` feeds to the Editor, Call Trace, Flow and Trace —
#    and `text`/`$value`, a multi-line dump ABOUT a value. `state.nim`'s
#    `valueDisplayText` was `$v`, so the State pane painted the dump.
#
#    Neither existing gate could see it. `watch_expressions_browser_probe`
#    builds its rows by HAND out of the wire's JSON, so it painted the
#    refusal's `msg` correctly while the product painted the word "Error"
#    (`text()` has no `of Error` branch and falls through to `$value.kind`).
#    Twenty-four green checks over a string the product does not produce.
#    This probe calls `ui/state.nim:localsToStoreRows` — the product's own
#    mapping — for exactly that reason.
#
# 2. THE PANE NEVER ASKED. `StateVM`'s auto-load effect runs at
#    construction, in `configureMiddleware`, before `openSession` has made a
#    worker. It marks `"load-locals"` pending and sends into a channel with
#    no peer. When the worker arrives and the first move re-fires the
#    effect, the request is byte-identical (`rrTicks` is 0 at every position
#    on a db-backend trace) and `isDuplicate` skips the send. The entry is
#    released 30 seconds later by the DAP timeout — after the moment it was
#    needed. `RequestTracker.clear` existed with zero call sites.
#
# WHAT IT MEASURES, AND WHAT IT REFUSES TO
# ----------------------------------------
# The rendered value, read RAW from `.value-expanded-text`; and whether a
# `ct/load-locals` command reached the backend. Never a count of DOM
# mutations or repaints — `493ad8e4a` records why those cannot separate
# correct work from redundant work. "Zero commands reached the backend after
# the worker arrived" is not a matter of degree.
#
# WHAT IT DOES NOT COVER, said plainly: there is no engine on this page. The
# transport half is `watch_expressions_dap_test.rs`'s. Pane B models the
# void at the STORE boundary — a `send` that is recorded and never answered,
# which is what a dropped frame produces — because the store boundary is
# where the ordering defect lives.
#
# PAINTED TEXT, NEVER `innerText` ALONE. Every row counted below is
# hit-tested with `elementFromPoint` at its own start.
#
# Usage:  bash ci/test/state-values-in-browser.sh [screenshot.png]
# Exit:   0 all assertions held, 1 otherwise, 2 could not run.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)"
cd "${repo_root}" || exit 2

shot="${1:-}"
cache="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}/state-values-in-browser"
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
		echo "state-values-in-browser.sh: no '${tool}' on PATH." >&2
		echo "  remedy: run inside the dev shell (direnv exec ${repo_root} ...)" >&2
		exit 2
	}
done

echo "=== a recorded value, in a browser, shown as the value it is ==="
echo

# ---------------------------------------------------------------------------
# Build the probe.
# ---------------------------------------------------------------------------
# THE SHIPPED WEB ARM'S DEFINES, which `ci/lib/test-lane-files.sh:304` gives
# the `renderer-web` lane verbatim. The missing `-d:ctRenderer` is not
# cosmetic: without it `src/common/paths.nim` reaches `require("os")` at
# MODULE SCOPE and the page dies before the pane mounts.
build_probe() {
	local out="$1"
	shift
	nim js -d:ctWeb -d:ctRenderer -d:chronicles_enabled=off \
		"$@" \
		--hints:off --warnings:off --path:src --path:src/frontend/viewmodel \
		-o:"${out}/probe.js" ci/test/state_values_browser_probe.nim \
		>"${out}/build.log" 2>&1
	[ -s "${out}/probe.js" ]
}

if ! build_probe "${cache}"; then
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

cp ci/test/state-values-probe/index.html "${cache}/index.html"
cp ci/test/state-values-probe/run.mjs "${cache}/run.mjs"

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

# `python3` rather than `jq`: this gate reads nested arrays and jq is not
# guaranteed on every machine that has node and python.
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
		def rowval(rows, name):
		    return next((r["value"] for r in rows if r["name"] == name), None) or ""
		try:
		    print(eval(expr, {"d": d, "rowval": rowval}))
		except Exception:
		    print("")
	PY
}

# ---------------------------------------------------------------------------
echo "The control: the product's own mapping, the product's own pane"
# ---------------------------------------------------------------------------
control="${cache}/control.out"
if ! run_probe "${cache}" "${control}" "${shot}"; then
	echo "  the probe did not complete; see ${control}" >&2
	tail -25 "${control}" >&2
	exit 2
fi

ck "$([ "$(q "${control}" 'd["panelAMounted"]')" = True ] && echo ok || echo no)" \
	"pane A mounted in a browser"
ck "$([ "$(q "${control}" 'd["panelBMounted"]')" = True ] && echo ok || echo no)" \
	"pane B mounted in a browser"

# ---------------------------------------------------------------------------
echo
echo "  Part 1 — a structured value is shown as the value it is"
# ---------------------------------------------------------------------------
#
# THE HEADLINE. `asteroid_masses` is a recorded `Seq` of four `Int`s. The
# value renderer writes it `@[100, 2000, 200, 14]`; the string renderer
# writes a four-line dump whose lines are those same four numbers. So the
# assertions are about the WHOLE string, not about which digits appear in
# it — every digit appears in both.
seq_val="$(q "${control}" 'rowval(d["localsRows"], "asteroid_masses")')"
note "asteroid_masses value cell: ${seq_val}"
ck "$([ "$(q "${control}" '"100" in rowval(d["localsRows"], "asteroid_masses") and "2000" in rowval(d["localsRows"], "asteroid_masses")')" = True ] && echo ok || echo no)" \
	"the recorded sequence's elements are painted"
ck "$([ "$(q "${control}" '"Sequence(" in rowval(d["localsRows"], "asteroid_masses")')" = False ] && echo ok || echo no)" \
	"and NOT as the string renderer's \"Sequence(...)\" dump"
ck "$([ "$(q "${control}" '"\n" in rowval(d["localsRows"], "asteroid_masses")')" = False ] && echo ok || echo no)" \
	"and the value cell is ONE LINE, not a multi-line block"

# A RECORD, asserted on its own. It fails for a different reason than the
# sequence does: `text()` reads `value.members`, which the wire does not
# populate, so `$v` raises and its `try` returns the literal "<error>".
rec_val="$(q "${control}" 'rowval(d["localsRows"], "landing_point")')"
note "landing_point value cell: ${rec_val}"
ck "$([ "$(q "${control}" '"3" in rowval(d["localsRows"], "landing_point") and "7" in rowval(d["localsRows"], "landing_point")')" = True ] && echo ok || echo no)" \
	"the recorded record's fields are painted"
ck "$([ "$(q "${control}" 'rowval(d["localsRows"], "landing_point") == "<error>"')" = False ] && echo ok || echo no)" \
	'and the record is not the literal string "<error>"'

# THE ATOMS ARE UNCHANGED, which is what makes the fix safe. `textRepr` and
# `$v` are character-for-character identical for Int/Float/Bool/String/Char,
# and a change that broke them would be the blank-row regression the pane
# was last repaired for.
ck "$([ "$(q "${control}" 'rowval(d["localsRows"], "initial_shield") == "10000"')" = True ] && echo ok || echo no)" \
	"an atom local is untouched: initial_shield is exactly 10000"

# THE REFUSAL. An `Error` value whose `msg` IS the explanation. `text()` has
# no `of Error` branch and painted the bare word "Error".
ck "$([ "$(q "${control}" 'd["watchesTabClicked"]')" = True ] && echo ok || echo no)" \
	"the Watches tab opens by gesture"
refusal="$(q "${control}" 'rowval(d["watchRows"], "initial_shield + 1")')"
note "initial_shield + 1 value cell: ${refusal}"
ck "$([ "$(q "${control}" 'rowval(d["watchRows"], "initial_shield + 1") != "Error"')" = True ] && echo ok || echo no)" \
	'a refused watch is not the bare word "Error"'
ck "$([ "$(q "${control}" '"cannot evaluate" in rowval(d["watchRows"], "initial_shield + 1")')" = True ] && echo ok || echo no)" \
	"and carries the reason the BACKEND gave"
ck "$([ "$(q "${control}" '"only holds the values that were actually recorded" in rowval(d["watchRows"], "initial_shield + 1")')" = True ] && echo ok || echo no)" \
	"and the reason says why a RECORDING cannot answer it"

# ---------------------------------------------------------------------------
echo
echo "  Part 2 — the pane asks once there is somebody to ask"
# ---------------------------------------------------------------------------
note "timeline:"
python3 - "${control}" <<-'PY'
	import json, sys
	blob = ""
	for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
	    if line.startswith("PROBE_JSON="):
	        blob = line[len("PROBE_JSON="):]
	if blob:
	    for step in (json.loads(blob).get("ordering") or {}).get("timeline", []):
	        print("        " + step)
PY

# T0 — the key IS set before the worker exists. This is not the defect, it
# is the precondition, and asserting it keeps the arm below honest: if the
# boot request stopped happening, part 2 would go green for a reason that
# has nothing to do with the fix.
ck "$([ "$(q "${control}" 'd["ordering"]["sentAtBoot"]')" = "1" ] && echo ok || echo no)" \
	"T0: the ViewModel's construction issues one ct/load-locals, before any worker"
ck "$([ "$(q "${control}" 'd["ordering"]["pendingAfterBoot"]')" = True ] && echo ok || echo no)" \
	'T0: and marks "load-locals" pending — the key is set into a void'

# T1 — the worker arrives and the stranded key is released.
ck "$([ "$(q "${control}" 'd["ordering"]["pendingAfterWorker"]')" = False ] && echo ok || echo no)" \
	"T1: once a backend is reachable the stranded key is gone"

# T2 — THE HEADLINE: the request is ISSUED. Not "a signal fired", not "the
# pane repainted" — a command reached the backend.
ck "$([ "$(q "${control}" 'd["ordering"]["sentAfterMove"]')" != "0" ] && echo ok || echo no)" \
	"T2: the first move at rrTicks=0 ISSUES a ct/load-locals (reached the backend: $(q "${control}" 'd["ordering"]["sentAfterMove"]'))"

# AND THE READER SEES SOMETHING. The request being issued is the mechanism;
# rows on screen is the point.
ck "$([ "$(q "${control}" 'len(d["orderingRows"]) > 0')" = True ] && echo ok || echo no)" \
	"T2: and pane B paints rows ($(q "${control}" 'len(d["orderingRows"])'))"
ck "$([ "$(q "${control}" 'rowval(d["orderingRows"], "asteroid_masses") != ""')" = True ] && echo ok || echo no)" \
	"T2: including the recorded sequence"
ck "$([ "$(q "${control}" 'd["loadingVisibleB"]')" = False ] && echo ok || echo no)" \
	'T2: and pane B is not still saying "Loading..."'

errs="$(q "${control}" 'len(d["pageErrors"])')"
ck "$([ "${errs}" = "0" ] && echo ok || echo no)" \
	"zero uncaught page errors (${errs})"

note "rows rejected by the hit test: A=$(q "${control}" 'd["localsRejected"]') B=$(q "${control}" 'd["orderingRejected"]')"
note "painted characters: $(q "${control}" 'd["paintedChars"]')"
[ -n "${shot}" ] && note "screenshot: ${shot}"
echo

# ---------------------------------------------------------------------------
echo 'Mutation arm V: the value cell is filled by the STRING renderer (pre-fix)'
echo "    Reddens every Part 1 assertion and nothing in Part 2. This is"
echo "    what the product painted: a four-line dump for a sequence, the"
echo '    literal "<error>" for a record, and "Error" for a refusal.'
# ---------------------------------------------------------------------------
arm_v="${cache}/arm-v"
mkdir -p "${arm_v}"
cp "${cache}/index.html" "${cache}/run.mjs" "${cache}/codetracer.css" "${arm_v}/" 2>/dev/null
ln -sfn "${nm}" "${arm_v}/node_modules"
# COMPILED FROM THE PROBE WHERE IT LIVES, with the arm selected by a `-d:`
# define. Copying the probe elsewhere breaks its relative imports, which
# would make this arm report a build failure instead of a product reading.
if build_probe "${arm_v}" -d:ValueArm:legacy; then
	arm_v_out="${cache}/arm-v.out"
	if run_probe "${arm_v}" "${arm_v_out}"; then
		note "arm V asteroid_masses: $(q "${arm_v_out}" 'repr(rowval(d["localsRows"], "asteroid_masses"))')"
		note "arm V landing_point:   $(q "${arm_v_out}" 'repr(rowval(d["localsRows"], "landing_point"))')"
		note "arm V initial_shield + 1: $(q "${arm_v_out}" 'repr(rowval(d["watchRows"], "initial_shield + 1"))')"
		ck "$([ "$(q "${arm_v_out}" '"Sequence(" in rowval(d["localsRows"], "asteroid_masses")')" = True ] && echo ok || echo no)" \
			'arm V: the sequence IS the "Sequence(...)" dump'
		ck "$([ "$(q "${arm_v_out}" '"\n" in rowval(d["localsRows"], "asteroid_masses")')" = True ] && echo ok || echo no)" \
			"arm V: and it is multi-line"
		ck "$([ "$(q "${arm_v_out}" 'rowval(d["localsRows"], "landing_point") == "<error>"')" = True ] && echo ok || echo no)" \
			'arm V: the record paints the literal "<error>"'
		ck "$([ "$(q "${arm_v_out}" 'rowval(d["watchRows"], "initial_shield + 1") == "Error"')" = True ] && echo ok || echo no)" \
			'arm V: the refusal paints the bare word "Error", losing the reason'
		# THE ARM BREAKS ONE THING. If the atoms broke too, the reds above
		# would be evidence that the arm broke the probe rather than that
		# the assertions work.
		ck "$([ "$(q "${arm_v_out}" 'rowval(d["localsRows"], "initial_shield") == "10000"')" = True ] && echo ok || echo no)" \
			"arm V: the atoms are still correct (the arm changes COMPOUNDS, not the pane)"
		ck "$([ "$(q "${arm_v_out}" 'd["ordering"]["sentAfterMove"]')" != "0" ] && echo ok || echo no)" \
			"arm V: and Part 2 is unaffected (the two defects are independent)"
	else
		ck no "arm V: the probe did not complete"
	fi
else
	echo "  arm V: the probe did not rebuild; see ${arm_v}/build.log" >&2
	tail -10 "${arm_v}/build.log" >&2
	ck no "arm V: could not build"
fi
echo

# ---------------------------------------------------------------------------
echo "Mutation arm O: nothing clears the tracker when the worker arrives"
echo "    Reddens every Part 2 assertion and nothing in Part 1. This is the"
echo "    state the product shipped in: RequestTracker.clear existed and"
echo "    had zero call sites, so the boot key outlived the worker."
# ---------------------------------------------------------------------------
arm_o="${cache}/arm-o"
mkdir -p "${arm_o}"
cp "${cache}/index.html" "${cache}/run.mjs" "${cache}/codetracer.css" "${arm_o}/" 2>/dev/null
ln -sfn "${nm}" "${arm_o}/node_modules"
if build_probe "${arm_o}" -d:OrderingArm:no-hook; then
	arm_o_out="${cache}/arm-o.out"
	if run_probe "${arm_o}" "${arm_o_out}"; then
		note "arm O timeline:"
		python3 - "${arm_o_out}" <<-'PY'
			import json, sys
			blob = ""
			for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
			    if line.startswith("PROBE_JSON="):
			        blob = line[len("PROBE_JSON="):]
			if blob:
			    for step in (json.loads(blob).get("ordering") or {}).get("timeline", []):
			        print("        " + step)
		PY
		ck "$([ "$(q "${arm_o_out}" 'd["ordering"]["pendingAfterWorker"]')" = True ] && echo ok || echo no)" \
			"arm O: the stranded key survives the worker's arrival"
		ck "$([ "$(q "${arm_o_out}" 'd["ordering"]["sentAfterMove"]')" = "0" ] && echo ok || echo no)" \
			"arm O: and the first move ISSUES NOTHING — the pane never asks"
		ck "$([ "$(q "${arm_o_out}" 'len(d["orderingRows"])')" = "0" ] && echo ok || echo no)" \
			"arm O: so pane B paints no rows at all"
		ck "$([ "$(q "${arm_o_out}" 'd["loadingVisibleB"]')" = True ] && echo ok || echo no)" \
			'arm O: and sits on "Loading...", waiting for an answer nobody was asked for'
		# THE ARM BREAKS ONE THING.
		ck "$([ "$(q "${arm_o_out}" 'd["ordering"]["sentAtBoot"]')" = "1" ] && echo ok || echo no)" \
			"arm O: the boot request still happens (the arm removes the CLEAR, not the ask)"
		ck "$([ "$(q "${arm_o_out}" '"Sequence(" in rowval(d["localsRows"], "asteroid_masses")')" = False ] && echo ok || echo no)" \
			"arm O: and Part 1 is unaffected (the two defects are independent)"
	else
		ck no "arm O: the probe did not complete"
	fi
else
	echo "  arm O: the probe did not rebuild; see ${arm_o}/build.log" >&2
	tail -10 "${arm_o}/build.log" >&2
	ck no "arm O: could not build"
fi
echo

echo "${checks} check(s), ${failures} failure(s)"
if [ "${failures}" -eq 0 ]; then
	echo "RESULT: OK — a recorded value is shown as the value it is, and the pane asks for it"
	exit 0
fi
echo "RESULT: FAILED — ${failures} check(s)"
exit 1
