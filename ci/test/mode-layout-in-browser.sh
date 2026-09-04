#!/usr/bin/env bash
#
# mode-layout-in-browser.sh — ONE LAYOUT PER MODE, counted as assertions over
# RENDERED GEOMETRY.
#
# THE PROBE THIS DRIVES HAD NEVER RUN.
# ------------------------------------
# `ci/test/mode_layout_probe.mjs` is a measuring instrument with no verdict: it
# drives eleven legs through a real tab and writes a JSON report, and it exits
# 0 whether it measured everything or timed out on its first selector. Its own
# header says so — "Reports facts. The shell counts assertions." — and until
# this file there was no shell. It was named in two comments
# (`ci/test/editor-context-menu-modes.sh:17`,
# `ci/test/editor_context_menu_modes_probe.mjs:33`) and recorded in
# `ci/test/shell-gate-coverage.known-dark.txt` among the three gates nothing
# anywhere referenced.
#
# What was believed about it was half wrong, and the half that was right is the
# reason it is worth wiring: it DOES measure rendered `.lm_title` geometry —
# the exact quantity that went to zero in the defect it covers — at lines
# 96-116 and 338-343. The gate was real and pointed at the right thing. It had
# simply never been run.
#
# WHAT IS ASSERTED HERE THAT THE MODEL TEST CANNOT
# ------------------------------------------------
# `src/tests/gui/tests/layout/mode_layout_test.nim` exercises the layout MODEL.
# Every assertion in it can hold of a product whose workspace looks wrong,
# because a layout config is not a workspace: GoldenLayout still has to accept
# it, build the stacks, and give each pane a box on the screen. Nothing below
# reads a config. Every check is over a rectangle or over the tab strip the
# panes are actually in.
#
# THE ARM THAT IS SKIPPED, AND WHY IT IS A SKIP AND NOT A PASS
# ------------------------------------------------------------
# The Noir compiler, the tracer and the replay engine are OPTIONAL bundle
# assets (see `platform/web_deployment.nim`, and the five `[SKIPPED]` lines
# `web-bundle-assets.sh` prints without them). Without them a tab can reach the
# Noir studio and its EDIT-mode workspace, and cannot reach a replay SESSION —
# so DEBUG mode opens no source file, and the editor arm has nothing to
# measure. That is read from the product's own output: the EDIT legs carry a
# source tab in the strip (`src/main.nr`) and the DEBUG legs carry none.
#
# Measured on a bundle assembled by `web-bundle-assets.sh` with no wasm:
# `.monaco-editor` in the DEBUG legs is 1600x0 with 0 `.view-line`s. Asserting
# "the editor is never empty" there would be a permanently red lane on a
# correct product, which is the failure `shell-gate-coverage.known-dark.txt`
# exists to prevent — a red that is always red stops being read. So that arm
# reports SKIPPED, skips are counted SEPARATELY from passes, and a skip can
# never make the total look like a pass.
#
# THE SKIP BRANCH IS ITSELF CHECKED, IN BOTH DIRECTIONS. `CT_MODE_LAYOUT_REPORT`
# points this script at a report it did not produce, which is how the branch was
# verified with synthetic input rather than argued about: a report whose DEBUG
# legs carry a source tab AND a zero-height editor makes the arm RUN and FAIL
# (naming the leg and the box), and the same report with a painted editor makes
# it RUN and PASS. Both were run before this file landed.
#
# Usage:  bash ci/test/mode-layout-in-browser.sh
# Env:    CT_WEB_BUNDLE_DIR       reuse an assembled bundle instead of building
#         CT_MODE_LAYOUT_TREE     serve this tree as-is (no assembly at all)
#         CT_MODE_LAYOUT_REPORT   read this report instead of driving a browser
#         CT_MODE_LAYOUT_PORT     static server port (default 8797)

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

cache="${TMPDIR:-/tmp}/ct-mode-layout-gate.$$"
mkdir -p "${cache}"
trap 'rm -rf "${cache}"' EXIT

checks=0
failures=0
skips=0

ok() { checks=$((checks + 1)); echo "  [OK]      $*"; }
bad() { checks=$((checks + 1)); failures=$((failures + 1)); echo "  [FAILED]  $*"; }
skip() { skips=$((skips + 1)); echo "  [SKIPPED] $*"; }
note() { echo "      $*"; }
check() {
	# check <verdict> <text...> — `ok` when $1 is the string `ok`.
	local verdict="$1"
	shift
	if [ "${verdict}" = ok ]; then ok "$*"; else bad "$*"; fi
}

echo "=== one layout per mode, measured as rendered geometry ==="
echo

# ---------------------------------------------------------------------------
# The report
# ---------------------------------------------------------------------------
report="${CT_MODE_LAYOUT_REPORT:-}"

if [ -z "${report}" ]; then
	required_tools="node python3"
	if [ -z "${CT_MODE_LAYOUT_TREE:-}" ] && [ -z "${CT_WEB_BUNDLE_DIR:-}" ]; then
		required_tools="${required_tools} nim"
	fi
	for tool in ${required_tools}; do
		command -v "${tool}" >/dev/null 2>&1 || {
			echo "mode-layout-in-browser.sh: no '${tool}' on PATH." >&2
			echo "  remedy: run inside the dev shell (direnv exec ${repo_root} ...)" >&2
			exit 2
		}
	done
	if [ ! -d node_modules/playwright ] && ! node -e "require('playwright')" >/dev/null 2>&1; then
		echo "mode-layout-in-browser.sh: node_modules/playwright is missing;" >&2
		echo "  run inside the dev shell (direnv exec ${repo_root} ...)" >&2
		exit 2
	fi

	tree="${CT_MODE_LAYOUT_TREE:-}"
	if [ -z "${tree}" ]; then
		bundle="${CT_WEB_BUNDLE_DIR:-}"
		if [ -z "${bundle}" ]; then
			bundle="${cache}/bundle"
			echo "Assembling a bundle (CT_WEB_BUNDLE_DIR unset)..."
			if ! CT_WEB_BUNDLE_DIR="${bundle}" bash ci/test/web-bundle-assets.sh \
				>"${cache}/assemble.log" 2>&1; then
				echo "  the bundle did not assemble; see ${cache}/assemble.log" >&2
				tail -20 "${cache}/assemble.log" >&2
				exit 2
			fi
		fi
		tree="${bundle}"
	fi

	# The static server. Byte-identical in behaviour to the one
	# `editor-context-menu-modes.sh` uses, including the `_redirects` rewrites
	# the `/noir` route depends on: without them `/noir` is a 404 and the probe
	# waits two minutes for a workspace that was never served.
	cat >"${cache}/serve.py" <<'PY'
import http.server, os, socketserver, sys
directory = sys.argv[1]


def load_rewrites(root):
    rules = []
    path = os.path.join(root, '_redirects')
    if not os.path.exists(path):
        return rules
    for line in open(path):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        parts = line.split()
        if len(parts) != 3 or parts[2] != '200':
            continue
        pattern, target = parts[0], parts[1]
        if pattern.endswith('/*'):
            rules.append((pattern[:-2], True, target))
        else:
            rules.append((pattern, False, target))
    return rules


RULES = load_rewrites(directory)


class Quiet(http.server.SimpleHTTPRequestHandler):
    extensions_map = dict(http.server.SimpleHTTPRequestHandler.extensions_map)
    extensions_map['.wasm'] = 'application/wasm'
    extensions_map['.mjs'] = 'text/javascript'

    def __init__(self, *a, **kw):
        super().__init__(*a, directory=directory, **kw)

    def translate_rewrite(self, path):
        request = path.split('?', 1)[0].split('#', 1)[0]
        candidate = os.path.join(directory, request.lstrip('/'))
        if os.path.isfile(candidate):
            return None
        for prefix, is_splat, target in RULES:
            if is_splat:
                if request == prefix or request.startswith(prefix + '/'):
                    return target
            elif request == prefix or request == prefix + '/':
                return target
        return None

    def send_head(self):
        target = self.translate_rewrite(self.path)
        if target is not None:
            self.path = target
        return super().send_head()

    def log_message(self, *a):
        pass


socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", int(sys.argv[2])), Quiet) as httpd:
    httpd.serve_forever()
PY

	port="${CT_MODE_LAYOUT_PORT:-8801}"
	server_pid=""
	stop_server() {
		if [ -n "${server_pid}" ]; then
			kill "${server_pid}" >/dev/null 2>&1
			wait "${server_pid}" 2>/dev/null
			server_pid=""
		fi
	}
	trap 'stop_server; rm -rf "${cache}"' EXIT

	# VERIFY THE INSTRUMENT, NOT JUST THE RESULT.
	#
	# This is not defensive decoration; it is a measured failure. The first
	# end-to-end run of this gate was written against port 8797 and came back
	# fully green — over a tree it had not assembled. A concurrent
	# `editor-context-menu-modes.sh` was already serving
	# `~/.cache/ct-ctxmenu/editor-context-menu-modes/tree` on that port, the
	# bind silently lost, and `curl` answered 200 from the FOREIGN server, so
	# `started=1` and the probe drove somebody else's bundle. Every number in
	# the report was plausible and none of it was about this tree.
	#
	# So the port is refused if anything is already on it, and the tree the
	# server actually serves is identified by its own build id before a browser
	# is pointed at it. Two runners on one host is the normal case here.
	if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${port}/"; then
		echo "  port ${port} is already serving something — refusing to measure it." >&2
		echo "  Another gate's static server is the usual cause (8794/8796/8797 are taken)." >&2
		echo "  remedy: set CT_MODE_LAYOUT_PORT to a free port." >&2
		exit 2
	fi

	python3 "${cache}/serve.py" "${tree}" "${port}" >"${cache}/server.log" 2>&1 &
	server_pid=$!
	started=0
	for _ in $(seq 1 40); do
		if kill -0 "${server_pid}" 2>/dev/null &&
			curl -s -o /dev/null "http://127.0.0.1:${port}/noir"; then
			started=1
			break
		fi
		sleep 0.25
	done
	if [ "${started}" -ne 1 ]; then
		echo "  the static server did not start" >&2
		tail -5 "${cache}/server.log" >&2
		exit 2
	fi

	# The identity check. `build-id.txt` is written into every bundle by
	# `web-bundle-assets.sh`; if the bytes on the wire are not the bytes in the
	# tree this run assembled, the server answering is not this run's.
	if [ -f "${tree}/build-id.txt" ]; then
		served_id="$(curl -s --max-time 5 "http://127.0.0.1:${port}/build-id.txt")"
		if [ "${served_id}" != "$(cat "${tree}/build-id.txt")" ]; then
			echo "  the server on port ${port} is not serving ${tree}." >&2
			echo "  served build-id: ${served_id}" >&2
			echo "  expected:        $(cat "${tree}/build-id.txt")" >&2
			exit 2
		fi
	fi

	echo "Driving a browser at http://127.0.0.1:${port}/noir ..."
	report="${cache}/report.json"
	node ci/test/mode_layout_probe.mjs "http://127.0.0.1:${port}/noir" "${report}" \
		>"${cache}/probe.log" 2>"${cache}/probe.err"
	probe_rc=$?
	stop_server
	if [ "${probe_rc}" -ne 0 ] || [ ! -s "${report}" ]; then
		echo "  the probe produced no report" >&2
		head -20 "${cache}/probe.err" >&2
		exit 2
	fi
	echo
else
	command -v python3 >/dev/null 2>&1 || {
		echo "mode-layout-in-browser.sh: no 'python3' on PATH." >&2
		exit 2
	}
	if [ ! -s "${report}" ]; then
		echo "mode-layout-in-browser.sh: CT_MODE_LAYOUT_REPORT=${report} is empty or absent" >&2
		exit 2
	fi
	echo "Reading a supplied report: ${report}"
	echo
fi

py() { python3 -c "$1" "${report}" "${@:2}"; }

# `q` answers one question about the report and prints `ok`/`no` on the first
# line and any detail on the rest, so every check below is one process and one
# `check` call. A question that cannot be answered prints `no` — an
# unanswerable question is a failure, never a silent pass.
q() { py "$1" "${@:2}"; }

# ---------------------------------------------------------------------------
# §0 THE PROBE MEASURED WHAT IT CLAIMS TO HAVE MEASURED
#
# First, because every check below reads legs, and a report with no legs would
# otherwise produce a short green summary rather than a failure.
# ---------------------------------------------------------------------------
echo "§0 the probe measured all eleven legs"

read_all() {
	py '
import json, sys
r = json.load(open(sys.argv[1]))
want = ["boot", "debug", "edit", "debug-trip2", "edit-trip2", "debug-trip3",
        "edit-trip3", "after-drag", "after-reload", "after-corrupt",
        "after-corrupt-debug"]
got = [l.get("leg") for l in r.get("legs", [])]
missing = [w for w in want if w not in got]
fatal = str(r.get("fatal", ""))
if fatal:
    print("no"); print("the probe reported a fatal: " + fatal[:200]); raise SystemExit
if missing:
    print("no"); print("legs missing: " + ", ".join(missing)); raise SystemExit
bad = [l["leg"] for l in r["legs"] if l.get("readError")]
if bad:
    print("no"); print("legs that could not be read: " + ", ".join(bad)); raise SystemExit
print("ok"); print("legs: " + ", ".join(got))
'
}
out="$(read_all)"
check "$(printf '%s' "${out}" | head -1)" "the probe completed every leg and reported no fatal"
note "$(printf '%s' "${out}" | tail -n +2)"

out="$(q '
import json, sys
r = json.load(open(sys.argv[1]))
bad = [l["leg"] for l in r["legs"] if not l.get("goldenLayoutPresent")]
print("no" if bad else "ok")
print("legs with no GoldenLayout root: " + (", ".join(bad) if bad else "none"))
')"
check "$(printf '%s' "${out}" | head -1)" "every leg had a GoldenLayout root on screen"
note "$(printf '%s' "${out}" | tail -n +2)"

echo

# ---------------------------------------------------------------------------
# §1 A MODE SWITCH CHANGES THE LAYOUT
#
# The report this gate exists for: the previous mode's arrangement was carried
# across. "Changed" is asked of the TAB STRIP and the STACK COUNT, both
# rendered, rather than of the config the page was handed.
# ---------------------------------------------------------------------------
echo "§1 a mode switch changes the layout"

out="$(q '
import json, sys
r = json.load(open(sys.argv[1]))
legs = {l["leg"]: l for l in r["legs"]}
e, d = legs["edit"], legs["debug"]
et, dt = sorted(set(e["allTabTitles"])), sorted(set(d["allTabTitles"]))
if et == dt:
    print("no"); print("both modes painted the same tab strip: " + ", ".join(et))
else:
    print("ok")
    print("edit  (%d): %s" % (len(et), ", ".join(et)))
    print("debug (%d): %s" % (len(dt), ", ".join(dt)))
')"
check "$(printf '%s' "${out}" | head -1)" "the two modes do not paint the same tab strip"
note "$(printf '%s' "${out}" | sed -n '2p')"
note "$(printf '%s' "${out}" | sed -n '3p')"

out="$(q '
import json, sys
r = json.load(open(sys.argv[1]))
legs = {l["leg"]: l for l in r["legs"]}
e, d = legs["edit"]["stackCount"], legs["debug"]["stackCount"]
print("ok" if (e and d and e != d) else "no")
print("stacks: edit=%s debug=%s" % (e, d))
')"
check "$(printf '%s' "${out}" | head -1)" "the two modes build a different number of stacks"
note "$(printf '%s' "${out}" | tail -n +2)"

# The debug-only panes, by name. A switch that changed SOMETHING but did not
# bring the debugging surfaces would satisfy the two checks above.
out="$(q '
import json, sys
r = json.load(open(sys.argv[1]))
legs = {l["leg"]: l for l in r["legs"]}
d = set(legs["debug"]["allTabTitles"])
e = set(legs["edit"]["allTabTitles"])
want = ["STATE", "EVENT LOG", "TIMELINE"]
missing = [w for w in want if w not in d]
leaked = [w for w in want if w in e]
if missing:
    print("no"); print("debug mode is missing: " + ", ".join(missing))
elif leaked:
    print("no"); print("edit mode is showing debug-only panes: " + ", ".join(leaked))
else:
    print("ok"); print("STATE, EVENT LOG and TIMELINE are in debug and in neither edit leg")
')"
check "$(printf '%s' "${out}" | head -1)" "the debugging panes arrive with debug mode and do not linger in edit"
note "$(printf '%s' "${out}" | tail -n +2)"

echo

# ---------------------------------------------------------------------------
# §2 THE NESTING THE REQUEST ASKED FOR
#
# "Nested under the same pane that holds the FILES" is a question about the
# rendered header: two panes are nested together exactly when their tabs are in
# one strip.
# ---------------------------------------------------------------------------
echo "§2 the panes are nested where the request put them"

out="$(q '
import json, sys
r = json.load(open(sys.argv[1]))
legs = {l["leg"]: l for l in r["legs"]}
bad = []
for name in ("edit", "debug"):
    s = legs[name]["strips"]
    f, t = s.get("FILES", {}), s.get("TESTS", {})
    if not f.get("present"):
        bad.append("%s: no FILES tab at all" % name); continue
    if not t.get("present"):
        bad.append("%s: no TESTS tab at all" % name); continue
    if f.get("stackKey") != t.get("stackKey"):
        bad.append("%s: FILES is in [%s] and TESTS is in [%s]"
                   % (name, f.get("stackKey"), t.get("stackKey")))
print("no" if bad else "ok")
print("; ".join(bad) if bad else "TESTS shares the FILES strip in both modes")
')"
check "$(printf '%s' "${out}" | head -1)" "TESTS is a tab OF the FILES stack, in both modes"
note "$(printf '%s' "${out}" | tail -n +2)"

out="$(q '
import json, sys
r = json.load(open(sys.argv[1]))
d = {l["leg"]: l for l in r["legs"]}["debug"]["strips"]
c, e = d.get("CONSTRAINTS", {}), d.get("EVENT LOG", {})
if not c.get("present") or not e.get("present"):
    print("no"); print("debug mode is missing CONSTRAINTS or EVENT LOG entirely")
elif c.get("stackKey") != e.get("stackKey"):
    print("no")
    print("CONSTRAINTS is in [%s], EVENT LOG is in [%s]"
          % (c.get("stackKey"), e.get("stackKey")))
else:
    print("ok"); print("both are tabs of [%s]" % c.get("stackKey"))
')"
check "$(printf '%s' "${out}" | head -1)" "CONSTRAINTS is a tab OF the EVENT LOG stack in debug mode"
note "$(printf '%s' "${out}" | tail -n +2)"

# A pane GoldenLayout has parked in the overflow dropdown is in the DOM, has an
# id, and cannot be reached by a user. Every markup assertion passes on it.
out="$(q '
import json, sys
r = json.load(open(sys.argv[1]))
bad = []
for l in r["legs"]:
    for title, s in l["strips"].items():
        if s.get("present") and s.get("exiled"):
            bad.append("%s/%s -> %s" % (l["leg"], title, ", ".join(s["exiled"])))
print("no" if bad else "ok")
print("; ".join(bad[:6]) if bad else "no pane was parked in a tab-overflow dropdown in any leg")
')"
check "$(printf '%s' "${out}" | head -1)" "no pane is exiled into the tab-overflow dropdown"
note "$(printf '%s' "${out}" | tail -n +2)"

# THE STALE CAPTION. `ui/layout.convertTabTitle` renders this pane as `TESTS`.
# The probe keeps `TEST RESULTS` as a subject precisely so a reverted caption
# says so, instead of reporting an absence that reads like a missing pane.
out="$(q '
import json, sys
r = json.load(open(sys.argv[1]))
back = [l["leg"] for l in r["legs"] if l["strips"].get("TEST RESULTS", {}).get("present")]
gone = [l["leg"] for l in r["legs"] if not l["strips"].get("TESTS", {}).get("present")]
if back:
    print("no"); print("the old caption TEST RESULTS is on screen in: " + ", ".join(back))
elif gone:
    print("no"); print("no TESTS tab in: " + ", ".join(gone))
else:
    print("ok"); print("every leg captions the pane TESTS, and none says TEST RESULTS")
')"
check "$(printf '%s' "${out}" | head -1)" "the pane is captioned TESTS everywhere, and the old spelling is gone"
note "$(printf '%s' "${out}" | tail -n +2)"

echo

# ---------------------------------------------------------------------------
# §3 THREE ROUND TRIPS, BECAUSE THE FAILURE IS A SLOT THAT IS RIGHT ONCE
#
# `Mode-Transitions.md` §6: "the check needs at least three, because the
# failure mode is a slot that is right once and empty afterwards". Trip 3 is
# compared against trip 1.
# ---------------------------------------------------------------------------
echo "§3 the third round trip reproduces the first"

out="$(q '
import json, sys
r = json.load(open(sys.argv[1]))
legs = {l["leg"]: l for l in r["legs"]}
bad = []
for a, b in (("edit", "edit-trip3"), ("debug", "debug-trip3")):
    x, y = legs[a], legs[b]
    if sorted(x["allTabTitles"]) != sorted(y["allTabTitles"]):
        bad.append("%s vs %s: tab strips differ (%s | %s)"
                   % (a, b, ", ".join(x["allTabTitles"]), ", ".join(y["allTabTitles"])))
    if x["stackCount"] != y["stackCount"]:
        bad.append("%s vs %s: %s stacks then %s"
                   % (a, b, x["stackCount"], y["stackCount"]))
print("no" if bad else "ok")
print("; ".join(bad) if bad else "trip 3 painted the same strips and stack counts as trip 1")
')"
check "$(printf '%s' "${out}" | head -1)" "the third trip into each mode reproduces the first"
note "$(printf '%s' "${out}" | tail -n +2)"

out="$(q '
import json, sys
r = json.load(open(sys.argv[1]))
legs = {l["leg"]: l for l in r["legs"]}
bad = []
for name in ("edit", "edit-trip2", "edit-trip3"):
    fs = legs[name]["contentBoxes"].get("filesystem")
    if not fs or not fs.get("w") or not fs.get("h"):
        bad.append("%s: filesystem box %s" % (name, fs))
print("no" if bad else "ok")
print("; ".join(bad) if bad else
      "FILES is painted with a real box on every entry into edit mode")
')"
check "$(printf '%s' "${out}" | head -1)" "FILES keeps a non-zero box across all three entries into edit"
note "$(printf '%s' "${out}" | tail -n +2)"

echo

# ---------------------------------------------------------------------------
# §4 THE EDITOR IS NOT EMPTY — where a session exists to fill it
#
# `Mode-Transitions.md` §7 requires the editor never to be empty. The EDIT legs
# can answer for it; the DEBUG legs cannot without a replay engine, and that is
# read from the product rather than assumed. See the header.
# ---------------------------------------------------------------------------
echo "§4 the editor is painted and not empty"

out="$(q '
import json, sys
r = json.load(open(sys.argv[1]))
legs = {l["leg"]: l for l in r["legs"]}
bad = []
for name in ("boot", "edit", "edit-trip2", "edit-trip3"):
    l = legs[name]
    ed = l["contentBoxes"].get("editor")
    if not ed or not ed.get("w") or not ed.get("h"):
        bad.append("%s: .monaco-editor box %s" % (name, ed))
    elif not l.get("editorLines"):
        bad.append("%s: %sx%s editor with 0 rendered .view-line"
                   % (name, ed["w"], ed["h"]))
print("no" if bad else "ok")
print("; ".join(bad) if bad else
      "every edit-mode leg painted a non-zero editor carrying rendered lines")
')"
check "$(printf '%s' "${out}" | head -1)" "in EDIT mode the editor has a box and rendered lines"
note "$(printf '%s' "${out}" | tail -n +2)"

# THE ABSENCE SIGNAL IS THE PRODUCT'S, NOT THIS SCRIPT'S. A debug leg that
# opened a source file has a tab whose title is a path; one that reached no
# session has none, and there is nothing for `.monaco-editor` to be.
debug_source="$(q '
import json, sys
r = json.load(open(sys.argv[1]))
legs = {l["leg"]: l for l in r["legs"]}
def source_tabs(l):
    return [t for t in l["allTabTitles"] if "/" in t or t.endswith(".nr")]
have = [n for n in ("debug", "debug-trip2", "debug-trip3") if source_tabs(legs[n])]
print("yes" if len(have) == 3 else "no")
print(", ".join(sorted({t for n in ("debug","debug-trip2","debug-trip3")
                        for t in source_tabs(legs[n])})) or "none")
')"
if [ "$(printf '%s' "${debug_source}" | head -1)" = yes ]; then
	out="$(q '
import json, sys
r = json.load(open(sys.argv[1]))
legs = {l["leg"]: l for l in r["legs"]}
bad = []
for name in ("debug", "debug-trip2", "debug-trip3"):
    l = legs[name]
    ed = l["contentBoxes"].get("editor")
    if not ed or not ed.get("w") or not ed.get("h"):
        bad.append("%s: .monaco-editor box %s" % (name, ed))
    elif not l.get("editorLines"):
        bad.append("%s: %sx%s editor with 0 rendered .view-line"
                   % (name, ed["w"], ed["h"]))
print("no" if bad else "ok")
print("; ".join(bad) if bad else
      "every debug-mode leg painted a non-zero editor carrying rendered lines")
')"
	check "$(printf '%s' "${out}" | head -1)" "in DEBUG mode the editor has a box and rendered lines"
	note "$(printf '%s' "${out}" | tail -n +2)"
else
	skip "in DEBUG mode the editor has a box and rendered lines — UNMEASURED here"
	note "no debug leg opened a source file, so there is no editor to measure."
	note "This deployment carries no replay engine and no Noir toolchain (both are"
	note "OPTIONAL bundle assets; see the [SKIPPED] lines from web-bundle-assets.sh),"
	note "so debug mode reaches no session. The arm runs where those are built:"
	note "deploy-web-codetracer.yml assembles studio-bundle/ with all three."
	note "source tabs seen in the debug legs: $(printf '%s' "${debug_source}" | tail -n +2)"
fi

echo

# ---------------------------------------------------------------------------
# §5 AN ARRANGEMENT SURVIVES A RELOAD
#
# The half of the request most likely to be quietly missing: a layout that
# applies on switch and resets on reload satisfies the letter and fails the
# ask. The rearrangement is a real splitter DRAG, not a config the probe wrote,
# because a written config would prove the store works and say nothing about
# whether the product ever fills it.
# ---------------------------------------------------------------------------
echo "§5 an arrangement survives a reload"

out="$(q '
import json, sys
r = json.load(open(sys.argv[1]))
d = r["arms"].get("drag") or {}
if not d.get("ok"):
    print("no"); print("the drag did not happen: " + str(d.get("reason")))
elif not d.get("moved"):
    print("no"); print("the FILES stack did not move: before=%s after=%s"
                       % (d.get("before"), d.get("after")))
else:
    print("ok"); print("FILES stack %s -> %s" % (d.get("before"), d.get("after")))
')"
check "$(printf '%s' "${out}" | head -1)" "dragging the splitter actually resized the FILES stack"
note "$(printf '%s' "${out}" | tail -n +2)"

out="$(q '
import json, sys
r = json.load(open(sys.argv[1]))
legs = {l["leg"]: l for l in r["legs"]}
def files_w(leg):
    s = legs[leg]["strips"].get("FILES", {})
    b = s.get("stackBox") or {}
    return b.get("w")
a, b = files_w("after-drag"), files_w("after-reload")
if a is None or b is None:
    print("no"); print("no FILES stack box to compare: after-drag=%s after-reload=%s" % (a, b))
elif abs(a - b) > 8:
    print("no"); print("the drag did not survive the reload: %s -> %s" % (a, b))
else:
    print("ok"); print("FILES stack width %s survived the reload as %s" % (a, b))
')"
check "$(printf '%s' "${out}" | head -1)" "the rearrangement is still there after a reload"
note "$(printf '%s' "${out}" | tail -n +2)"

echo

# ---------------------------------------------------------------------------
# §6 A STORED LAYOUT THAT CANNOT BE READ DEGRADES TO A WORKSPACE
#
# `loadLayout` throwing on a saved layout is not hypothetical here — it is what
# left the workspace EMPTY after a Stop. The property is "degrades to a sensible
# default", and the measurement is PANES ON SCREEN, not an absence of errors.
# ---------------------------------------------------------------------------
echo "§6 a corrupt stored layout still yields a workspace"

out="$(q '
import json, sys
r = json.load(open(sys.argv[1]))
c = r["arms"].get("corruptWritten") or {}
if c.get("error"):
    print("no"); print("the probe could not write the corrupt layout: " + str(c["error"]))
elif c.get("wrote") != 2:
    print("no"); print("the corrupt layout was not written to both stores: " + str(c))
else:
    print("ok"); print("rubbish written to both CODETRACER_MODE_LAYOUT_* stores")
')"
check "$(printf '%s' "${out}" | head -1)" "the degradation arm actually corrupted the store it claims to have"
note "$(printf '%s' "${out}" | tail -n +2)"

out="$(q '
import json, sys
r = json.load(open(sys.argv[1]))
legs = {l["leg"]: l for l in r["legs"]}
bad = []
for name in ("after-corrupt", "after-corrupt-debug"):
    l = legs[name]
    present = [t for t, s in l["strips"].items() if s.get("present")]
    if not l.get("goldenLayoutPresent"):
        bad.append("%s: no GoldenLayout root" % name)
    elif len(present) < 3:
        bad.append("%s: only %d pane(s) came back: %s"
                   % (name, len(present), ", ".join(present)))
print("no" if bad else "ok")
print("; ".join(bad) if bad else
      "both post-corruption legs came back with a populated workspace")
')"
check "$(printf '%s' "${out}" | head -1)" "the workspace comes back with panes in it, not empty"
note "$(printf '%s' "${out}" | tail -n +2)"

out="$(q '
import json, sys
r = json.load(open(sys.argv[1]))
legs = {l["leg"]: l for l in r["legs"]}
a, b = legs["after-corrupt"], legs["after-corrupt-debug"]
if a["stackCount"] == b["stackCount"] and \
   sorted(a["allTabTitles"]) == sorted(b["allTabTitles"]):
    print("no")
    print("the mode switch on top of the corrupt store changed nothing: %s"
          % ", ".join(a["allTabTitles"]))
else:
    print("ok")
    print("edit %d stacks / debug %d stacks after the corruption"
          % (a["stackCount"], b["stackCount"]))
')"
check "$(printf '%s' "${out}" | head -1)" "a mode switch on top of the corrupt store still switches"
note "$(printf '%s' "${out}" | tail -n +2)"

echo

# ---------------------------------------------------------------------------
# The verdict. SKIPS ARE COUNTED SEPARATELY AND ARE NEVER PASSES.
# ---------------------------------------------------------------------------
echo "${checks} check(s), ${failures} failure(s), ${skips} skipped"
if [ "${skips}" -gt 0 ]; then
	echo "NOTE: ${skips} arm(s) were SKIPPED, not passed — this run could not"
	echo "      measure them. See the [SKIPPED] line(s) above for what is missing."
fi
if [ "${checks}" -eq 0 ]; then
	echo "RESULT: FAILED — no checks ran, which is not a pass"
	exit 1
fi
if [ "${failures}" -ne 0 ]; then
	echo "RESULT: FAILED — ${failures} check(s)"
	exit 1
fi
echo "RESULT: OK — one layout per mode, and it survives a reload"
