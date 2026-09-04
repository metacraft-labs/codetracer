#!/usr/bin/env bash
# The `/noir/demo` demo path, in a real tab, asserted on what a visitor sees.
#
# `noir-demo-template.sh` is the other half and neither replaces the other. It
# proves the demo's SOURCES are right and that its bug is reachable under
# `nargo`; it says nothing about whether a person can find the bug in the
# product, which is what the demo is for.
#
# THAT GAP IS NOT THEORETICAL. Two defects sat in it while every source-level
# check was green:
#
#   * `renderer.loadTheme` composed a RELATIVE stylesheet href. A relative
#     reference resolves against the document's directory; `/noir` has none, so
#     it worked, and at the two-segment `/noir/demo` it resolved back into the
#     SPA rewrite. The browser parsed `index.html` as CSS and the whole
#     application painted with ZERO rules — a complete DOM, a correct file
#     tree, and nothing legible.
#   * `noir_build_producer.onOutput` accumulated the trace with `.add`, which
#     `nim js` compiles to `push.apply`. Traces over ~100 KB threw `RangeError`
#     and Run reported "the tracer did not produce a trace" — a FALSE cause,
#     over a trace that was fine. The starter's 38 KB trace was under the
#     threshold; the demo's 462 KB one was not.
#
# A route check, a mount check and a compile check are all satisfied by both of
# those. So the arms below count CSS rules, and they read panes.
#
# ARM C IS THE ONE TO KEEP if this file is ever cut down. The demo's thesis is
# that the pass count is something the calltrace SHOWS rather than a loop bound
# a reader must evaluate in their head — `sort::ascending` calls a named
# function once per pass for exactly that reason. Three visible `one_pass`
# frames is that thesis as an assertion, and nothing else in the repository
# checks it.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

cache="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}/noir-demo-in-browser"
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
note() { printf '  %s\n' "$*"; }

expect_count() {
	local want="$1"
	if [ "${checks}" -ne "${want}" ]; then
		printf '\nRESULT: FAILED — %d assertion(s) ran, %d were written.\n' \
			"${checks}" "${want}"
		printf 'An assertion that did not run is not an assertion that passed.\n'
		exit 1
	fi
}

die_unstarted() {
	printf '\nRESULT: FAILED — 0 assertion(s) ran; the suite never started.\n'
	printf 'An assertion that did not run is not an assertion that passed.\n'
	printf '%s\n' "$1" >&2
	exit 1
}

echo "=== /noir/demo, driven in a browser ==="
echo

command -v node >/dev/null 2>&1 || die_unstarted "node is not on PATH."
command -v python3 >/dev/null 2>&1 || die_unstarted "python3 is not on PATH."

# ---------------------------------------------------------------------------
# The bundle
# ---------------------------------------------------------------------------
bundle="${CT_WEB_BUNDLE_DIR:-}"
if [ -z "${bundle}" ]; then
	bundle="${cache}/bundle"
	echo "Assembling a bundle (CT_WEB_BUNDLE_DIR unset)..."
	if ! CT_WEB_BUNDLE_DIR="${bundle}" bash ci/test/web-bundle-assets.sh \
		>"${cache}/assemble.log" 2>&1; then
		die_unstarted "the bundle did not assemble; see ${cache}/assemble.log"
	fi
fi
[ -f "${bundle}/index.html" ] || die_unstarted "no index.html in ${bundle}"

# WHICH BUILD IS UNDER TEST, printed. `/ui.js` sits at a stable URL under a
# long max-age, so "I loaded the page" does not say which renderer answered.
# The digest below is of the file this run is about to serve, and the probe
# fetches from that same tree over a loopback server with no cache in front of
# it.
ui_bytes="$(wc -c <"${bundle}/ui.js" | tr -d ' ')"
ui_digest="$(shasum -a 256 "${bundle}/ui.js" | cut -c1-16)"
note "bundle:  ${bundle}"
note "ui.js:   ${ui_bytes} bytes, sha256 ${ui_digest}"

# THE REPLAY ENGINE IS A PRECONDITION, checked rather than assumed. Without it
# Run falls back to painting counted rows, every pane below is empty, and this
# gate would report the demo broken when the deployment simply shipped no
# engine. That is a different sentence and it must not be confused with this
# one.
if ! ls "${bundle}"/assets/db_backend_bg*.wasm >/dev/null 2>&1; then
	die_unstarted "the bundle carries no replay engine (assets/db_backend_bg*.wasm);
set CT_REPLAY_ENGINE_DIR to a wasm-pack pkg/ and re-assemble. Without it Run
cannot open a session and every pane assertion below would fail for a reason
that is about the BUNDLE and not about the demo."
fi

# ---------------------------------------------------------------------------
# A server that honours the bundle's own `_redirects`
# ---------------------------------------------------------------------------
# A bare handler 404s `/noir/demo`, and a run served without the rewrite would
# measure THIS SERVER and report the product broken at a URL the CDN serves.
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
httpd = socketserver.TCPServer(("127.0.0.1", 0), Quiet)
print(httpd.server_address[1], flush=True)
httpd.serve_forever()
PY

server_pid=""
# shellcheck disable=SC2329  # invoked by the EXIT trap below, not by name
cleanup() { [ -n "${server_pid}" ] && kill "${server_pid}" 2>/dev/null; }
trap cleanup EXIT

rm -f "${cache}/port"
python3 "${cache}/serve.py" "${bundle}" >"${cache}/port" 2>"${cache}/server.log" &
server_pid=$!
waited=0
while [ ! -s "${cache}/port" ] && [ "${waited}" -lt 150 ]; do
	sleep 0.1
	waited=$((waited + 1))
done
port="$(head -1 "${cache}/port" 2>/dev/null | tr -d '[:space:]')"
[ -n "${port}" ] || die_unstarted "the static server did not start; see ${cache}/server.log"
note "serving: http://127.0.0.1:${port}"
echo

# ---------------------------------------------------------------------------
# Drive it
# ---------------------------------------------------------------------------
if ! node ci/test/noir_demo_path_probe.mjs "http://127.0.0.1:${port}" \
	>"${cache}/probe.json" 2>"${cache}/probe.err"; then
	echo "  the probe did not complete:" >&2
	tail -12 "${cache}/probe.err" | sed 's/^/      /' >&2
	die_unstarted "the browser probe failed; no pane was read."
fi

q() { python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
cur = doc
for key in sys.argv[2].split("."):
    if cur is None: break
    cur = cur.get(key) if isinstance(cur, dict) else None
print("" if cur is None else cur)' "${cache}/probe.json" "$1"; }

# --- arm A: the page is legible -------------------------------------------
echo "--- arm A: the page a visitor actually gets ---"
css_rules="$(q cssRules)"
note "stylesheet rules on /noir/demo: ${css_rules}"
if [ "${css_rules:-0}" -gt 500 ]; then
	ck ok "the application paints with CSS (${css_rules} rules), so the panes are where they belong"
else
	ck fail "only ${css_rules} CSS rules on /noir/demo — the theme href regressed to a relative path"
	note "themeHref: $(q themeHref)"
fi

# --- arm B: the demo route serves the demo, in a browser -------------------
echo
echo "--- arm B: /noir/demo is not /noir ---"
if [ "$(q demoMounted.oracle)" = "True" ] && [ "$(q demoMounted.sort)" = "True" ] &&
	[ "$(q demoMounted.hello)" = "False" ]; then
	ck ok "/noir/demo mounts oracle_settlement (sort.nr present, hello_noir absent)"
else
	ck fail "/noir/demo did not mount the demo: oracle=$(q demoMounted.oracle) sort=$(q demoMounted.sort) hello=$(q demoMounted.hello)"
fi
if [ "$(q starterMounted.hello)" = "True" ] && [ "$(q starterMounted.oracle)" = "False" ]; then
	ck ok "/noir still mounts hello_noir, so the demo did not replace the starter"
else
	ck fail "/noir is wrong: hello=$(q starterMounted.hello) oracle=$(q starterMounted.oracle)"
fi
constraints="$(q constraintsText)"
case "${constraints}" in
*478*) ck ok "the Constraints pane reports the DEMO's 478 ACIR opcodes" ;;
*17*) ck fail "the Constraints pane reports 17 — the starter's count over the demo's circuit" ;;
*) ck fail "the Constraints pane reported no recognisable count: ${constraints:0:120}" ;;
esac

# --- arm C: Run, and the three frames the demo is about --------------------
echo
echo "--- arm C: Run, and what the calltrace shows ---"
surface="$(q topbarSurface)"
if [ "${surface}" = "debugger-controls" ]; then
	ck ok "Run leaves edit mode for the debugging surface"
else
	ck fail "after Run the topbar surface is '${surface}', not 'debugger-controls'"
	note "build pane said: $(q buildText)"
fi
build_text="$(q buildText)"
case "${build_text}" in
*"did not produce a trace"*)
	ck fail "Run reported 'the tracer did not produce a trace' — the large-trace append regressed"
	;;
*"opening a replay session"*)
	ck ok "the Build pane reports a trace and a replay session over it"
	;;
*)
	ck fail "the Build pane did not report a replay session: ${build_text:0:160}"
	;;
esac

frames="$(q onePassFrames)"
note "one_pass frames in the calltrace: ${frames}"
if [ "${frames}" = "3" ]; then
	ck ok "the calltrace shows exactly THREE one_pass frames — the pass count, as frames"
else
	ck fail "the calltrace shows ${frames} one_pass frames, not 3; the demo's thesis is not visible"
	note "calltrace: $(q calltraceText | cut -c1-200)"
fi
# NON-VACUITY for the count above: a pane that failed to render would report 0
# and a pane that rendered the WRONG program would too, so require the frames
# the demo's call structure puts around them.
calltrace="$(q calltraceText)"
if [[ ${calltrace} == *"median_of"* && ${calltrace} == *"ascending"* && ${calltrace} == *"settle"* ]]; then
	ck ok "and they sit under settle -> median_of -> ascending, so the pane rendered THIS program"
else
	ck fail "the calltrace does not show the demo's call structure: ${calltrace:0:200}"
fi

# --- arm D: the event log carries the wrong answer -------------------------
echo
echo "--- arm D: the event log ---"
if [ "$(q eventLog.freshCount)" = "True" ] && [ "$(q eventLog.wrongPrice)" = "True" ] &&
	[ "$(q eventLog.assertion)" = "True" ]; then
	ck ok "the event log carries 'fresh reports: 6', the wrong price 242990, and the refusal"
else
	ck fail "the event log is incomplete: fresh=$(q eventLog.freshCount) price=$(q eventLog.wrongPrice) assert=$(q eventLog.assertion)"
	note "text: $(q eventLog.text | cut -c1-200)"
fi

# --- arm E: the flow view shows WHERE it went wrong ------------------------
echo
echo "--- arm E: the flow view over the third pass ---"
if [ "$(q clickedThirdFrame)" = "True" ]; then
	ck ok "the third one_pass frame is clickable"
else
	ck fail "the third one_pass frame could not be clicked"
fi
hits="$(q flow.hitLines)"
if [ "${hits:-0}" -gt 0 ]; then
	ck ok "the flow view marks executed lines (${hits} of them), so per-line values are painted"
else
	ck fail "no line-flow-hit markers — the flow view painted nothing"
fi
# The third pass RETURNING the outlier at index 3 — the slot `median_of` reads.
# This is step 7 of the path in Noir-Studio.md §1b.7: the moment a visitor SEES
# the bug happen rather than being told about it.
#
# IT IS NOT A BUG DETECTOR, stated here because the label reads like one. A
# mutation applying the one-line repair leaves this arm GREEN, and that is
# correct: passes 1 to 3 are identical whatever `SETTLE_PASSES` is, and the
# repair adds three passes AFTER this one rather than changing it. The arms
# that discriminate are C's frame count and D's settled price, and both were
# measured reddening under exactly that mutation — 6 frames instead of 3, and
# `settled price: 243180` with no refusal.
if [ "$(q flow.showsOutlierAtMedian)" = "True" ]; then
	ck ok "and the third pass returns 242990 at index 3 — the outlier reaching the median slot"
else
	ck fail "the flow view does not show the outlier reaching the median slot"
	note "rows: $(q flow.sample | cut -c1-260)"
fi

# --- arm F: a reload keeps the tabs, and the tabs keep their files ---------
#
# Reported as "initially the editor has all files already opened as tab, but the
# tabs are not populated; I need to close the tabs and re-open the files". The
# edit layout is persisted (`CODETRACER_MODE_LAYOUT_EDIT`) and restored on the
# next load, so the restored config names an `editorComponent` per open tab —
# containers that `createUIComponents` built components for and that nothing
# asked a source for. Measured on the deployed `4e9cff5ae`: five tabs in the
# strip, `hasMonaco === false` on every one.
#
# ASSERTED ON NAMED FILES, and on the file the arm itself opened, so this cannot
# pass because some other tab happens to hold text, and it does not encode the
# template's file LIST — a demo that gains a README still has to satisfy it.
restored_check() { python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
tabs = doc.get("restoredTabs") or {}
name, marker = sys.argv[2], sys.argv[3]
hit = [v for k, v in tabs.items() if k.endswith("/" + name)]
if not hit:
    print("MISSING"); raise SystemExit
v = hit[0]
if not v.get("hasMonaco"):
    print("NO_EDITOR"); raise SystemExit
if not v.get("len"):
    print("EMPTY"); raise SystemExit
if marker not in (v.get("text") or ""):
    print("WRONG_CONTENT"); raise SystemExit
if (v.get("rendered") or 0) <= 0:
    print("NOT_RENDERED"); raise SystemExit
print("OK %d" % v["len"])' "${cache}/probe.json" "$1" "$2"; }

echo
echo "--- arm F: a reload keeps the tabs, and the tabs keep their files ---"
note "tabs after the reload: $(q restoredTabTitles | cut -c1-200)"
while IFS='|' read -r f marker; do
	[ -n "${f}" ] || continue
	verdict="$(restored_check "${f}" "${marker}")"
	case "${verdict}" in
	OK*)
		ck ok "after a reload ${f}'s restored tab holds its file (${verdict#OK } chars), with no close/re-open"
		;;
	MISSING)
		ck fail "after a reload there is no editor entry for ${f} at all — the tab the arm opened did not come back"
		;;
	NO_EDITOR)
		ck fail "after a reload ${f} has a tab and NO editor — the restored pane was never populated"
		;;
	EMPTY)
		ck fail "after a reload ${f}'s editor holds zero characters"
		;;
	WRONG_CONTENT)
		ck fail "after a reload ${f}'s editor does not hold ${f} — expected to find '${marker}'"
		;;
	NOT_RENDERED)
		ck fail "after a reload ${f}'s model has content but the editor painted nothing"
		;;
	*)
		ck fail "the restored-tab probe reported '${verdict}' for ${f}"
		;;
	esac
done <<-'FILES'
	config.nr|Parameters of the ETH/USD feed
	sort.nr|bubble passes
FILES

reload_errors="$(q restoredPageErrors)"
if [ -z "${reload_errors}" ] || [ "${reload_errors}" = "[]" ]; then
	ck ok "and the reload itself threw nothing — no 'editor <name> exists' out of the restored layout"
else
	ck fail "uncaught page errors on the reload: ${reload_errors:0:300}"
fi

errors="$(q pageErrors)"
echo
if [ -z "${errors}" ] || [ "${errors}" = "[]" ]; then
	ck ok "no uncaught page errors during the whole path"
else
	ck fail "uncaught page errors: ${errors:0:300}"
fi

echo
expect_count 16
if [ "${failures}" -eq 0 ]; then
	printf 'RESULT: PASSED — %d assertion(s) over ui.js %s.\n' "${checks}" "${ui_digest}"
	exit 0
fi
printf 'RESULT: FAILED — %d of %d assertion(s) over ui.js %s.\n' \
	"${failures}" "${checks}" "${ui_digest}"
note "probe output: ${cache}/probe.json"
exit 1
