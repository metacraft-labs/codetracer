#!/usr/bin/env bash
#
# jump-follow-in-browser.sh — a call-trace jump puts the target line on screen,
# and a click in the file tree opens its file, in Debug mode, with a clean
# console.
#
# THE REPORTS
# -----------
# Against the deployed `noirstudio.dev`, entered through `/noir/demo` after
# running the tests:
#
#   * "I tried jumping through the call trace, but my impression is that the
#     editor was not always following the position of the caret/cursor after
#     the jump."
#   * "I'm still unable to reliably open files. Some clicks in the file tree
#     work, others don't."
#   * "The clicks in the file tree that don't work also don't close an active
#     right click menu, so they must be ignored somehow."
#
# and the console the user captured:
#
#   Uncaught Error: componentItem is not a child of this stack
#     at Zr.setActiveComponentItem / at Zr.setActiveContentItem
#     at showTab__utils_u12684 / at openTab__utils_u12836
#     at openTab__uiZfilesystem_u1834 / at openFile__...filesystem95vm_u793
#
# THE DISCRIMINATOR THIS PINS
# ---------------------------
# The failure is MODE-DEPENDENT, not jump-dependent. Every one of these
# gestures works in Edit mode and fails after a Run, because entering Debug
# mode rebuilds the layout (one layout per mode) and leaves
# `EditorViewComponent.layoutItem` pointing at an item the new tree does not
# contain. `showTab` then activates through that cached `.parent`.
#
# So the gate runs the SAME gestures twice — once before the Run and once
# after — and the Debug-mode pass is the one that fails on the pre-fix tree.
# A gate that only exercised Edit mode passes on a completely broken product,
# which is exactly what a first version of this probe did.
#
# WHAT IS ASSERTED, AND WHY IT IS NOT VACUOUS
# -------------------------------------------
# "The editor followed" is FOUR readings taken together, after a settle:
#
#   1. Monaco's caret is on the line the app itself reports for the move
#      (read from `data.services.debugger.location`, never a hardcoded line,
#      which would rot with the demo template);
#   2. that line is inside one of `getVisibleRanges()`;
#   3. the active tab is the target file;
#   4. THE EDITOR IS ACTUALLY ON SCREEN — `getDomNode()` connected, height
#      >= 100px.
#
# (4) is not padding. On the pre-fix tree the failed activation leaves the
# editor's DOM node DISCONNECTED, and Monaco then reports a single-line
# "visible" range like [[14,14]] with the caret on the target — so (1) and (2)
# both hold for a pane the user cannot see at all. Measured: 8/8 jumps
# satisfied (1)+(2) while `getDomNode().isConnected` was false. Without the
# height reading this gate would have passed on the reported defect.
#
# NOT A GREP OVER `ui.js`: Nim's JS backend emits some literals as char-code
# arrays. Every reading comes from the live DOM and from Monaco's own API.
#
# THE CONSOLE IS PART OF THE ASSERTION. `showTab` is reached from an async
# proc, so the throw surfaces as an unhandled promise REJECTION — not an
# `error` event — which is how this survived two rounds of user reports with
# nothing visible. The probe installs an `unhandledrejection` listener before
# any app code runs, and this gate fails on a non-zero count.
#
# Usage:  bash ci/test/jump-follow-in-browser.sh
# Env:    CT_WEB_BUNDLE_DIR   reuse an assembled tree instead of building one
#         CT_NOIR_WASM_COMPILER / CT_NOIR_WASM_TRACER
#         CT_REPLAY_ENGINE_GLUE / CT_REPLAY_ENGINE_WASM (or CT_REPLAY_ENGINE_DIR)
#         CT_JF_MOUNT_MS / CT_JF_RUN_MS
# Exit:   0 all assertions held, 1 otherwise, 2 could not run.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=ci/lib/nim-cache-root.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "${repo_root}/ci/lib/nim-cache-root.sh"
cd "${repo_root}" || exit 2

cache="$(ct_nim_cache_root "${repo_root}")/jump-follow"
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
		echo "  [FAIL]   $*"
		failures=$((failures + 1))
	fi
}
note() { printf '  %s\n' "$*"; }
die_unstarted() {
	echo "SKIP: $*" >&2
	exit 2
}

echo "=== a jump lands on screen, and a tree click opens its file (Debug mode) ==="
echo

# ---------------------------------------------------------------------------
# The bundle
# ---------------------------------------------------------------------------
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

# THE PRECONDITIONS, CHECKED RATHER THAN ASSUMED. Without the replay engine
# there is no session, so there is no Debug mode, no call trace and no jump —
# and every assertion below would be a statement about an empty list.
shopt -s nullglob
engine=("${bundle}"/assets/db_backend_bg*.wasm)
compiler=("${bundle}"/assets/noir_wasm*.wasm)
shopt -u nullglob
[ ${#engine[@]} -gt 0 ] || die_unstarted \
	"${bundle} ships no assets/db_backend_bg*.wasm, so no replay session can start. Set CT_REPLAY_ENGINE_DIR / CT_REPLAY_ENGINE_{GLUE,WASM} and re-assemble."
[ ${#compiler[@]} -gt 0 ] || die_unstarted \
	"${bundle} ships no assets/noir_wasm*.wasm, so the demo cannot be built or run. Set CT_NOIR_WASM_COMPILER / CT_NOIR_WASM_TRACER and re-assemble."

note "bundle:  ${bundle}"
note "ui.js:   $(wc -c <"${bundle}/ui.js" | tr -d ' ') bytes"
echo

# ---------------------------------------------------------------------------
# A server that honours the bundle's own `_redirects`, so `/noir/demo` resolves
# the way the CDN resolves it rather than 404ing and reporting the product
# broken at a URL that works in production.
# ---------------------------------------------------------------------------
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
# shellcheck disable=SC2329  # invoked by the EXIT trap, not by name
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
if ! node ci/test/jump_follow_probe.mjs "http://127.0.0.1:${port}" \
	"${CT_JF_MOUNT_MS:-14000}" "${CT_JF_RUN_MS:-60000}" \
	>"${cache}/probe.json" 2>"${cache}/probe.err"; then
	echo "  the probe did not run; see ${cache}/probe.err" >&2
	tail -20 "${cache}/probe.err" >&2
	exit 2
fi
[ -s "${cache}/probe.json" ] || die_unstarted "the probe produced no report"

q() { python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(eval(sys.argv[2], {"d": d, "sum": sum, "len": len, "any": any, "all": all}))
' "${cache}/probe.json" "$1"; }

echo "Readings"
note "mounted:            $(q 'd["mounted"]')"
note "mode after Run:     $(q 'd["topbarAfterRun"]')"
note "file rows:          $(q '[c["row"] for c in d["treeClicks"]]')"
note "jumps measured:     $(q 'len(d["jumps"])')"
echo

# THE SESSION MUST EXIST. Every assertion after this is about Debug mode, so a
# run that never reached it must refuse rather than report zero failures over
# an empty list — the vacuous pass this gate is built to avoid.
[ "$(q 'd["mounted"]')" = "True" ] || die_unstarted "the renderer never mounted"
[ "$(q 'd["topbarAfterRun"]')" = "debugger-controls" ] ||
	die_unstarted "the Run did not reach Debug mode (topbar: $(q 'd["topbarAfterRun"]')); there is no call trace to jump through"
[ "$(q 'len(d["jumps"])')" -ge 4 ] ||
	die_unstarted "only $(q 'len(d["jumps"])') jumps were measured; the call trace did not populate"

echo "Assertions"

# --- the jump follows -------------------------------------------------------
followed="$(q 'sum(1 for j in d["jumps"] if j["followed"])')"
total="$(q 'len(d["jumps"])')"
if [ "${followed}" = "${total}" ]; then
	ck ok "[jump-follow] every one of ${total} jumps put its target line on screen with the caret on it"
else
	ck fail "[jump-follow] only ${followed}/${total} jumps followed; first failure: $(q '[ (j["frame"], j["reported"], {"caretLine": j["caretAfter"] and j["caretAfter"]["line"], "onScreen": j["editorOnScreen"], "domHeight": j["caretAfter"] and j["caretAfter"]["domHeight"], "activeTab": j["caretAfter"] and j["caretAfter"]["activeKey"]}) for j in d["jumps"] if not j["followed"]][0]')"
fi

# --- the editor is on screen, stated separately -----------------------------
# Split from the check above so "the caret is right but the pane is invisible"
# — the exact pre-fix state — cannot hide inside a single composite verdict.
onscreen="$(q 'sum(1 for j in d["jumps"] if j["editorOnScreen"])')"
if [ "${onscreen}" = "${total}" ]; then
	ck ok "[jump-onscreen] the active editor was connected and >=100px tall after all ${total} jumps"
else
	ck fail "[jump-onscreen] the active editor was off-screen or detached after $((total - onscreen))/${total} jumps (domHeight -1 means getDomNode().isConnected was false)"
fi

# --- a cross-file jump was actually exercised -------------------------------
# NON-VACUITY. Same-file jumps pass trivially once the pane works, so a sample
# that never crossed files would prove nothing about the reported defect.
cross="$(q 'sum(1 for j in d["jumps"] if j["crossFile"])')"
if [ "${cross}" -ge 1 ]; then
	ck ok "[jump-crossfile] ${cross} of the measured jumps crossed into another file"
else
	ck fail "[jump-crossfile] no measured jump crossed files, so this run says nothing about the reported case"
fi

# --- the file tree, in Debug mode -------------------------------------------
# THE CLAIM IS THE USER'S: click a file in the tree, and that file is what the
# editor shows. Read off `data.services.editor.active`, so activating a tab
# that is already open and opening a fresh one both count — they are the same
# thing to the person clicking.
#
# This replaced "the list of open tab titles changed", which could not express
# that claim in either direction and needed a `<= 1` threshold to limp: the
# probe clicks every row once in Edit mode before it reaches Debug mode, so the
# tabs it then clicks are already open and a WORKING click adds no title. The
# threshold's own comment said rows were "excluded by name rather than by
# fudging the verdict" while the code excluded nothing and fudged by count, so
# one extra already-open tab read as a defect and one dead row read as fine.
#
# NON-VACUITY: a run that clicked nothing would satisfy "no bad clicks", so the
# number of rows actually measured is part of the assertion.
measured="$(q 'len(d.get("treeClicksDebugMode", []))')"
badclicks="$(q 'sum(1 for c in d.get("treeClicksDebugMode", []) if c.get("bucket","").startswith("C"))')"
missed="$(q 'sum(1 for c in d.get("treeClicksDebugMode", []) if c.get("bucket","")[:1] in ("A","B"))')"
if [ "${measured}" -lt 4 ]; then
	ck fail "[tree-debug] only ${measured} file row(s) were clicked in Debug mode; this run cannot speak to the report"
elif [ "${missed}" -gt 0 ]; then
	ck fail "[tree-debug] ${missed} of ${measured} clicks never reached their row: $(q '[(c["row"], c["bucket"], c.get("elementFromPointBefore")) for c in d.get("treeClicksDebugMode", []) if c.get("bucket","")[:1] in ("A","B")]')"
elif [ "${badclicks}" -gt 0 ]; then
	ck fail "[tree-debug] ${badclicks} of ${measured} clicks reached the row and did NOT make their file active: $(q '[(c["row"], c.get("activeBefore"), c.get("activeAfter")) for c in d.get("treeClicksDebugMode", []) if c.get("bucket","").startswith("C")]')"
else
	ck ok "[tree-debug] all ${measured} file-tree clicks made their file the active editor in Debug mode"
fi

# --- the console ------------------------------------------------------------
# The closing evidence. An unhandled rejection is how this defect stayed
# invisible between two user reports.
rej="$(q 'sum(len(c.get("rejections", [])) for c in d.get("treeClicksDebugMode", [])) + sum(len(j["burst"].get("rejections", [])) for j in d["jumps"]) + sum(len(r["reopen"].get("rejections", [])) for r in d.get("closeReopenDebugMode", []))')"
if [ "${rej}" = "0" ]; then
	ck ok "[console] no unhandled rejection across the Debug-mode clicks and jumps"
else
	ck fail "[console] ${rej} unhandled rejection(s); first: $(q '([c["rejections"][0] for c in d.get("treeClicksDebugMode", []) if c.get("rejections")] + [j["burst"]["rejections"][0] for j in d["jumps"] if j["burst"].get("rejections")])[0][:200]')"
fi

echo
# ---------------------------------------------------------------------------
# REPORTED, NOT ASSERTED: the State pane's re-render burst.
#
# The user also reported "very rapid re-rendering of the state panel ... the
# whole UI felt less responsive", and it is a SEPARATE defect with its own
# cause (a 20 Hz `InternalLastCompleteMove` replay armed per newly opened
# editor, fanned out unbatched, into a `state_vm` effect that has no
# `lastTicks` latch). It is measured here because this is the run that can see
# it, and NOT asserted here because this gate must not start failing for a
# defect it does not fix — and because these counts only became observable once
# the panes render at all.
# ---------------------------------------------------------------------------
echo "State pane re-render burst (reported, not asserted)"
q 'chr(10).join("  %-24s %4d mutations over %5d ms" % (p["frame"][:24], p["mutations"], p["spanMs"]) for p in d["storm"]["perJump"])'
note "total long-task time: $(q 'd["storm"]["totalLongTaskMs"]') ms"

echo
echo "${checks} check(s), ${failures} failure(s)"
if [ "${failures}" -eq 0 ]; then
	echo "RESULT: OK — a jump lands on screen and a tree click opens its file"
	exit 0
fi
echo "RESULT: FAILED — ${failures} check(s)"
exit 1
