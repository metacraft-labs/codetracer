#!/usr/bin/env bash
#
# chord-and-pane-uniqueness.sh — one press runs one operation, one pane id
# names one node. Asserted in a real browser tab, on the assembled bundle.
#
# WHY THIS EXISTS
# ---------------
#   1. THE KEY. The web build and the desktop used to deliver a key through
#      three registries — Mousetrap's loop over the YAML table, chords bound
#      in code after it, and the Monaco `commands` table — and they
#      disagreed: `Ctrl+E` and `Alt+E` ran two different actions depending
#      on where the caret was, `F2` was dead outside the editor, and a chord
#      whitelisted into Monaco that Monaco also binds natively (`Alt+F8`) was
#      measured firing twice per press. PLAT-68 replaced all three with ONE
#      capture-phase listener and the shared router
#      (`src/frontend/ui/key_router.nim`). Part 1 holds that replacement to
#      its promise on the shipped bundle: every press runs exactly ONE
#      operation (`window.__ctKeyTrace`, the router's own record), the SAME
#      one with the caret in Monaco and outside it, and no action slot runs
#      twice. Part 1b is the chord whose effect is a state change — `Ctrl+E`
#      toggles read-only, really (the live Monaco instances), in both focus
#      contexts, and leaves the mode alone (`Mode-Transitions.md` §4
#      requirement 4).
#
#   2. THE PANE. `ui/layout.nim`'s standalone auto-hide registration had its
#      `continue` one level too deep, so the state "GoldenLayout already
#      emitted the container, but `layoutItem` is not populated yet" fell
#      through to the branch that CREATES a div with the same id. Measured
#      before the fix: two `#errorsComponent-0` nodes, the GL one holding the
#      mounted panel and an empty duplicate parked offscreen at x = -9999.
#
# (A Part 3 measured what Mousetrap's global `stopCallback` override still
# bought; the override went with Mousetrap's binding table, and the part and
# its probe with it.)
#
# THE SHAPE (Verification-Harness-Traps.md 4a/4c)
#   * COUNTED assertions, with the count itself asserted at the bottom.
#   * THE NUMBER OF SUBJECTS IS ASSERTED before anything about them: "every
#     press ran one operation" is vacuously true of no presses.
#   * INSTRUMENT ARMS: arm CI plants a genuine duplicate id and requires the
#     pane counter to report 2; arm CD requires the delivery comparison to
#     flag a count of 2. A counter that could only say 1 would satisfy every
#     green check without measuring anything.
#
# Usage:  bash ci/test/chord-and-pane-uniqueness.sh
# Env:    CT_WEB_BUNDLE_DIR   a bundle from ci/test/web-bundle-assets.sh
#                             (assembled here if unset)

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=ci/lib/nim-cache-root.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "${repo_root}/ci/lib/nim-cache-root.sh"
cd "${repo_root}" || exit 2

cache="$(ct_nim_cache_root "${repo_root}")/chord-pane-uniqueness"
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
note() { printf '      %s\n' "$*"; }

expect_count() {
	local want="$1"
	if [ "${checks}" -ne "${want}" ]; then
		printf '\nRESULT: FAILED — %d assertion(s) ran, %d were written.\n' \
			"${checks}" "${want}"
		printf 'An assertion that did not run is not an assertion that passed.\n'
		exit 1
	fi
}

echo "=== one press, one action; one pane id, one node ==="
echo

command -v node >/dev/null 2>&1 || {
	echo "node is not on PATH; run inside the dev shell" >&2
	exit 2
}
[ -d node_modules/playwright ] || {
	echo "node_modules/playwright is missing; run inside the dev shell" >&2
	exit 2
}

# ---------------------------------------------------------------------------
# The bundle.
# ---------------------------------------------------------------------------
bundle="${CT_WEB_BUNDLE_DIR:-}"
if [ -z "${bundle}" ]; then
	bundle="${cache}/bundle"
	echo "Assembling a bundle (CT_WEB_BUNDLE_DIR unset)..."
	if ! CT_WEB_BUNDLE_DIR="${bundle}" bash ci/test/web-bundle-assets.sh \
		>"${cache}/assemble.log" 2>&1; then
		echo "  the bundle did not assemble; see ${cache}/assemble.log" >&2
		tail -20 "${cache}/assemble.log" >&2
		exit 1
	fi
fi
[ -s "${bundle}/index.html" ] || {
	echo "no index.html in ${bundle}; nothing to load" >&2
	exit 1
}
echo "  bundle: ${bundle}"
echo

# ---------------------------------------------------------------------------
# The server. Same shape as web-renderer-mounts.sh: port 0, the bundle's own
# `_redirects` applied so `/noir` reaches the application rather than a 404,
# and 30x rows deliberately NOT followed.
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
        t = self.translate_rewrite(self.path)
        if t is not None:
            self.path = t
        return super().send_head()

    def log_message(self, *a):
        pass


socketserver.TCPServer.allow_reuse_address = True
httpd = socketserver.TCPServer(("127.0.0.1", 0), Quiet)
print(httpd.server_address[1], flush=True)
httpd.serve_forever()
PY

server_pid=""
stop_server() {
	if [ -n "${server_pid}" ] && kill -0 "${server_pid}" 2>/dev/null; then
		kill "${server_pid}" 2>/dev/null
		wait "${server_pid}" 2>/dev/null
	fi
	server_pid=""
}
trap 'stop_server' EXIT

# `probe <label> <probe.mjs> <url-path>` — absolute tool paths throughout.
# `$(...)` in this tree has been observed losing `wc` and `curl` from PATH,
# manufacturing failures that look like the product's.
probe() {
	local label="$1" script="$2" url_path="${3:-/noir}"
	rm -f "${cache}/port"
	/usr/bin/python3 "${cache}/serve.py" "${bundle}" \
		>"${cache}/port" 2>"${cache}/server.log" &
	server_pid=$!
	local waited=0
	while [ ! -s "${cache}/port" ] && [ "${waited}" -lt 150 ]; do
		sleep 0.1
		waited=$((waited + 1))
	done
	local port
	port="$(head -1 "${cache}/port" 2>/dev/null | tr -d '[:space:]')"
	if [ -z "${port}" ]; then
		stop_server
		return 2
	fi
	node "${script}" "http://127.0.0.1:${port}${url_path}" 9000 \
		>"${cache}/${label}.json" 2>"${cache}/${label}.err"
	local rc=$?
	stop_server
	if [ "${rc}" -ne 0 ] || [ ! -s "${cache}/${label}.json" ]; then
		echo "  the probe produced no report for arm '${label}'" >&2
		head -5 "${cache}/${label}.err" >&2
		return 2
	fi
	return 0
}

jq_py() { /usr/bin/python3 -c "$1" "${cache}/$2.json" "${3:-}"; }

# `action_ordinal <ClientAction member>` — the array index the probe's counter
# map is keyed by, DERIVED from the enum rather than written here.
#
# `data.actions` is `array[ClientAction, ClientActionHandler]`, so the ordinal IS
# the JS index. Writing the number in this file would be a copy of a declaration
# one directory over, and the failure mode is silent: an enum member inserted in
# the middle re-points every index after it, and a check reading a stale number
# would go on passing while grading the wrong action. Prints nothing and returns
# non-zero when the member does not exist, so a rename becomes a FAILED check
# rather than an empty string compared against an empty string.
action_ordinal() {
	/usr/bin/python3 - "$1" <<'PY'
import re
import sys

want = sys.argv[1]
path = "src/common/common_types/codetracer_features/frontend.nim"
src = open(path, encoding="utf-8").read()
start = src.index("ClientAction* = enum")
end = src.index("InputShortcutMap*", start)
members = []
for line in src[start:end].splitlines()[1:]:
    s = line.strip()
    if not s or s.startswith("#"):
        continue
    m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*(,|#|$)", s)
    if m:
        members.append(m.group(1))
if want not in members:
    sys.stderr.write("no ClientAction member named %s\n" % want)
    sys.exit(3)
print(members.index(want))
PY
}

# ===========================================================================
# PART 1 — ONE PRESS, ONE OPERATION
# ===========================================================================
echo "Part 1: one press runs one operation, the same wherever the caret is"
echo

if ! probe keys ci/test/one_key_one_operation_probe.mjs /noir; then
	ck fail "the key probe produced a report"
	expect_count 1
fi
ck ok "the key probe produced a report"

pre_ok="$(jq_py '
import json,sys
d=json.load(open(sys.argv[1]))
p=d["pre"]
print("yes" if (p["hasData"] and p["actionsIsArray"] and p["monacoEditors"]>0
      and p["hasMenuVM"] and not d["pageErrors"] and not d["loadError"]) else "no")
' keys)"
ck "$([ "${pre_ok}" = "yes" ] && echo ok || echo fail)" \
	"the tab booted the renderer: data, actions[], Monaco and the menu, no page errors"

# THE SUBJECT COUNT, before anything about the subjects.
n_results="$(jq_py 'import json,sys;print(len(json.load(open(sys.argv[1]))["results"]))' keys)"
ck "$([ "${n_results}" = "14" ] && echo ok || echo fail)" \
	"14 presses were measured (7 chords x 2 focus contexts), got ${n_results}"

focus_ok="$(jq_py '
import json,sys
d=json.load(open(sys.argv[1]))
f={r["where"]: r["activeInsideMonaco"] for r in d["focusReports"]}
print("yes" if f.get("editor") is True and f.get("outside") is False else "no")
' keys)"
ck "$([ "${focus_ok}" = "yes" ] && echo ok || echo fail)" \
	"the caret was really inside Monaco for the 'editor' arm and really outside for the 'outside' arm"

# THE ASSERTION: each press ran exactly one operation.
not_one="$(jq_py '
import json,sys
d=json.load(open(sys.argv[1]))
bad=["%s/%s=%s" % (r["focus"], r["key"], r["ops"]) for r in d["results"] if len(r["ops"]) != 1]
print(",".join(bad) if bad else "none")
' keys)"
ck "$([ "${not_one}" = "none" ] && echo ok || echo fail)" \
	"every press ran exactly one operation (other than one: ${not_one})"

# …the operation its row names (CUA-Keymap.md), in BOTH focus contexts —
# the property whose failure was one key running two actions by focus.
wrong="$(jq_py '
import json,sys
d=json.load(open(sys.argv[1]))
bad=["%s/%s=%s" % (r["focus"], r["key"], r["ops"]) for r in d["results"]
     if r["ops"] != [r["expectedOp"]]]
print(",".join(bad) if bad else "none")
' keys)"
ck "$([ "${wrong}" = "none" ] && echo ok || echo fail)" \
	"each press ran its row's operation with the caret in the editor and outside it (wrong: ${wrong})"

# No action slot ran more than once for one press, and no press ran two
# actions: the double delivery and the "also ran something else" defects.
doubled="$(jq_py '
import json,sys
d=json.load(open(sys.argv[1]))
bad=["%s/%s=%s" % (r["focus"], r["key"], r["allDeliveries"]) for r in d["results"]
     if r["maxDeliveries"] > 1 or r["totalDeliveries"] > 1]
print(",".join(bad) if bad else "none")
' keys)"
ck "$([ "${doubled}" = "none" ] && echo ok || echo fail)" \
	"no press ran an action twice, or two actions (offenders: ${doubled})"

# And an operation that runs through a ClientAction REACHED it, once — the
# trace alone would be satisfied by a router that resolved and ran nothing.
# The slot is DERIVED from the enum (`action_ordinal`).
for action in aGotoNextError aGotoPreviousError build; do
	ix="$(action_ordinal "${action}")"
	reached="$(jq_py '
import json,sys
d=json.load(open(sys.argv[1]))
ix=sys.argv[2]
rs=[r for r in d["results"] if r["action"]=="'"${action}"'"]
print(",".join("%s=%s" % (r["focus"], r["allDeliveries"].get(ix, 0)) for r in rs) or "missing")
' keys "${ix}")"
	ck "$([ "${reached}" = "editor=1,outside=1" ] && echo ok || echo fail)" \
		"${action} (slot ${ix:-?}) ran exactly once from each focus context (${reached})"
done

# ARM CD — THE INSTRUMENT: the comparison above flags a count of 2.
dbl="$(jq_py '
import json,sys
d=json.load(open(sys.argv[1]))
r=dict(d["results"][0]); r["maxDeliveries"]=2
print("caught" if (r["maxDeliveries"] > 1 or r["totalDeliveries"] > 1) else "missed")
' keys)"
ck "$([ "${dbl}" = "caught" ] && echo ok || echo fail)" \
	"arm CD: the comparison the checks above use does flag a delivery count of 2"

echo

# ===========================================================================
# PART 1b — CTRL+E, A STATE CHANGE, ONE PAGE PER FOCUS CONTEXT
# ===========================================================================
#
# `Ctrl+E` used to run `switchEdit` with the caret outside the editor and
# toggle read-only inside it (the Monaco `commands` table). Each context gets
# a fresh page: the press changes the state the other would be measured
# against.
echo "Part 1b: Ctrl+E toggles read-only in both contexts, and only that"
echo

toggle_ix="$(action_ordinal aToggleReadOnly)"
switch_ix="$(action_ordinal switchEdit)"
ck "$([ -n "${toggle_ix}" ] && [ -n "${switch_ix}" ] &&
	[ "${toggle_ix}" != "${switch_ix}" ] && echo ok || echo fail)" \
	"the ClientAction ordinals were derived from the enum and are distinct (aToggleReadOnly=${toggle_ix:-?} switchEdit=${switch_ix:-?})"

for arm in ctrle-editor ctrle-outside; do
	export CT_CHORD_SUBJECTS="Control+KeyE"
	case "${arm}" in
	*-editor) export CT_CHORD_FOCUS="editor" ;;
	*-outside) export CT_CHORD_FOCUS="outside" ;;
	esac
	if probe "${arm}" ci/test/one_key_one_operation_probe.mjs /noir; then
		ck ok "the key probe produced a report (${arm})"
	else
		ck fail "the key probe produced a report (${arm})"
	fi
	unset CT_CHORD_SUBJECTS CT_CHORD_FOCUS
done

# `ops/toggle/switch` for the one press each arm made (`jq_py` forwards one
# argument, so the two slots travel as one).
ctrle_row() {
	jq_py '
import json,sys
d=json.load(open(sys.argv[1]))
r=d["results"]
if len(r) != 1:
    print("missing")
else:
    r=r[0]
    toggle, switch = sys.argv[2].split(",")
    print("%s/%s/%s" % ("|".join(r["ops"]), r["allDeliveries"].get(toggle, 0),
                        r["allDeliveries"].get(switch, 0)))
' "$1" "${toggle_ix},${switch_ix}"
}
for arm in ctrle-editor ctrle-outside; do
	row="$(ctrle_row "${arm}")"
	ck "$([ "${row}" = "editor.toggle-read-only/1/0" ] && echo ok || echo fail)" \
		"${arm}: Ctrl+E ran editor.toggle-read-only once, aToggleReadOnly once, switchEdit never (ops/toggle/switch = ${row})"
done

# THE EFFECT, not only the dispatch: the live Monaco instances moved (over a
# positive number of them), and the mode did not.
ctrle_effect="$(
	for arm in ctrle-editor ctrle-outside; do
		jq_py '
import json,sys
d=json.load(open(sys.argv[1]))
r=d["results"][0] if len(d["results"])==1 else None
print("yes" if (r and r["readOnlyChanged"] and r["monacoReadOnlyChanged"]
                and r["monacoEditorsMeasured"] > 0 and not r["modeChanged"]) else "no", end=",")
' "${arm}"
	done
)"
ck "$([ "${ctrle_effect}" = "yes,yes," ] && echo ok || echo fail)" \
	"Ctrl+E made the live Monaco editors read-only and left data.ui.mode alone, in both contexts (editor,outside = ${ctrle_effect})"

echo

# ===========================================================================
# PART 2 — THE PANE
# ===========================================================================
echo "Part 2: one pane id names exactly one node"
echo

# Arm CONTROL — the shipped default layout. GoldenLayout does not carry these
# panes, so each is created once by the standalone path and parked offscreen.
if ! probe panes-control ci/test/pane_mount_probe.mjs /noir; then
	ck fail "the pane probe produced a report (control)"
	expect_count 28
fi
ck ok "the pane probe produced a report (control)"

n_panes="$(jq_py 'import json,sys;print(len(json.load(open(sys.argv[1]))["report"]["panes"]))' panes-control)"
ck "$([ "${n_panes}" = "4" ] && echo ok || echo fail)" \
	"4 standalone auto-hide panes were measured, got ${n_panes}"

host_ok="$(jq_py '
import json,sys
r=json.load(open(sys.argv[1]))["report"]
print("yes" if r["hostPresent"] and r["hostLeft"]=="-9999px" else "no")
' panes-control)"
ck "$([ "${host_ok}" = "yes" ] && echo ok || echo fail)" \
	"the offscreen standalone host exists at left:-9999px (one parked copy is BY DESIGN)"

dupes="$(jq_py '
import json,sys
r=json.load(open(sys.argv[1]))["report"]
bad=["%s=%s" % (p["id"], p["count"]) for p in r["panes"] if p["count"]!=1]
print(",".join(bad) if bad else "none")
' panes-control)"
ck "$([ "${dupes}" = "none" ] && echo ok || echo fail)" \
	"control: every pane id names exactly one node (offenders: ${dupes})"

# Arm DOCKED — the regression. A layout saved with the pane docked gives
# GoldenLayout a container for it; `layoutItem` is populated from a different
# timer, so the loop can see the container before the item. THIS is the state
# that used to produce a duplicate. Measured before the fix: count=2 for
# `errorsComponent-0` — the GL node holding the mounted panel, plus an empty
# one at x=-9999.
export CT_PLANT_GL_CONTAINER=errorsComponent-0
if ! probe panes-docked ci/test/pane_mount_probe.mjs /noir; then
	ck fail "the pane probe produced a report (docked)"
	unset CT_PLANT_GL_CONTAINER
	expect_count 32
fi
unset CT_PLANT_GL_CONTAINER
ck ok "the pane probe produced a report (docked)"

docked_dupes="$(jq_py '
import json,sys
r=json.load(open(sys.argv[1]))["report"]
bad=["%s=%s" % (p["id"], p["count"]) for p in r["panes"] if p["count"]!=1]
print(",".join(bad) if bad else "none")
' panes-docked)"
ck "$([ "${docked_dupes}" = "none" ] && echo ok || echo fail)" \
	"docked: a GoldenLayout container for the pane does NOT produce a second node with its id (offenders: ${docked_dupes})"

# ...and the survivor is the right one: the GL node, on screen, holding the
# mounted panel — not the empty offscreen copy. A count of 1 alone would be
# satisfied by keeping the wrong one.
survivor="$(jq_py '
import json,sys
r=json.load(open(sys.argv[1]))["report"]
p=[x for x in r["panes"] if x["id"]=="errorsComponent-0"][0]
pl=p["placements"][0] if len(p["placements"])==1 else None
print("yes" if pl and not pl["inStandaloneHost"] and pl["rectX"]!=-9999
      and pl["childElements"]>0 else "no")
' panes-docked)"
ck "$([ "${survivor}" = "yes" ] && echo ok || echo fail)" \
	"docked: the surviving errorsComponent-0 is the on-screen GoldenLayout node with content, not the empty offscreen copy"

panels="$(jq_py '
import json,sys
print(json.load(open(sys.argv[1]))["report"]["problemsPanels"])
' panes-docked)"
ck "$([ "${panels}" = "1" ] && echo ok || echo fail)" \
	"docked: exactly one .problems-panel is mounted, got ${panels}"

# ARM CI — THE INSTRUMENT, and it runs against the same probe and the same
# comparison as the two green arms above. A duplicate id is planted after the
# page has settled; the counter must report 2. Without this, "count == 1"
# would be satisfied by a probe that could only ever return 1 — which is
# exactly the `ok: 0/0 published files match` failure one axis over.
export CT_PLANT_DUPLICATE_ID=errorsComponent-0
if ! probe panes-instrument ci/test/pane_mount_probe.mjs /noir; then
	ck fail "the pane probe produced a report (instrument)"
	unset CT_PLANT_DUPLICATE_ID
	expect_count 36
fi
unset CT_PLANT_DUPLICATE_ID
ck ok "the pane probe produced a report (instrument)"

inst="$(jq_py '
import json,sys
r=json.load(open(sys.argv[1]))["report"]
p=[x for x in r["panes"] if x["id"]=="errorsComponent-0"][0]
print(p["count"])
' panes-instrument)"
ck "$([ "${inst}" = "2" ] && echo ok || echo fail)" \
	"arm CI: with a duplicate id deliberately planted the counter reports 2, so the checks above are not vacuous — got ${inst}"

echo

if [ "${failures}" -ne 0 ]; then
	printf 'RESULT: FAILED — %d of %d check(s)\n' "${failures}" "${checks}"
	expect_count 27
	exit 1
fi
printf '%d check(s), 0 failure(s)\n' "${checks}"
expect_count 27
echo "RESULT: OK — one press runs one operation, one pane id names one node"
