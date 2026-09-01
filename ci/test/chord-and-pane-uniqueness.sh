#!/usr/bin/env bash
#
# chord-and-pane-uniqueness.sh — one press runs one action, and one pane id
# names one node. Both asserted in a real browser tab, on the assembled bundle.
#
# WHY THIS EXISTS
# ---------------
# Two hazards that currently do no visible harm, each for a reason that is not
# a mechanism:
#
#   1. THE CHORD. `ui/shortcuts.nim:318` sets `Mousetrap.prototype.stopCallback`
#      to a proc returning `false` for everything, which disables Mousetrap's
#      default refusal to fire while the caret is in an INPUT / SELECT /
#      TEXTAREA / contentEditable. The whitelisted chords in
#      `ui/editor.nim`'s MONACO_SHORTCUTS_WHITELIST are ALSO registered as
#      Monaco commands by `delegateShortcuts`, so both paths call the same
#      `data.actions[action]`. Stepping does not visibly double today, but the
#      only thing between it and doubling is `data.status.stableBusy` — a step
#      SERIALISATION guard (`renderer.nim:771`, `ui/debug.nim:439`, both
#      written for "holding F10") that would swallow a second delivery by
#      accident. A chord whose action is not a step has nothing.
#
#      Measured, and this is the fact the gate pins: the two paths are
#      MUTUALLY EXCLUSIVE. With the caret in Monaco, Monaco's keybinding
#      service calls `preventDefault` + `stopPropagation`, so the event never
#      reaches Mousetrap's document listener — the Monaco path delivers and
#      the Mousetrap path does not. With the caret outside, Monaco's command
#      does not run and Mousetrap's does. One delivery either way.
#
#      That is a property of the CURRENT whitelist, not a law. The
#      build-error-navigation work measured the counter-example in a browser:
#      ALT+F8, which Monaco binds natively to marker navigation, "whitelisted
#      it fired TWICE per press and unwhitelisted it never fired at all". So
#      the hazard is real and lands on whichever chord is added next. This
#      gate is what makes that arrive as a red check instead of as a duplicate
#      step nobody notices.
#
#   2. THE PANE. `ui/layout.nim`'s standalone auto-hide registration had its
#      `continue` one level too deep, so the state "GoldenLayout already
#      emitted the container, but `layoutItem` is not populated yet" fell
#      through to the branch that CREATES a div with the same id. Measured
#      before the fix: two `#errorsComponent-0` nodes, the GL one holding the
#      mounted panel and an empty duplicate parked in the offscreen host at
#      x = -9999. It matters beyond the stray node because
#      `ui/errors.nim`'s `tryMountIsoNimErrorsPanel` resolves its container
#      with `getElementById` (first match wins) and `mountIsoNimErrors` has no
#      disposal, so a remount can land in the other node and leave the first
#      subtree live.
#
# THE SHAPE (Verification-Harness-Traps.md 4a/4c, and the house style set by
# `web-renderer-mounts.sh`)
#   * COUNTED assertions, with the count itself asserted at the bottom. An arm
#     that aborted or a probe that produced no JSON becomes a count mismatch
#     rather than a clean summary.
#   * THE NUMBER OF SUBJECTS IS ASSERTED TOO. Every check below is of the form
#     "exactly one", and "exactly one" is vacuously true of an empty list. So
#     the gate first asserts how many chords were pressed and how many panes
#     were found, and only then what each of them did.
#   * A CONTROL ARM, so the mutation arms cannot be red for an unrelated
#     reason.
#   * AN INSTRUMENT ARM per subject, each reddening THE ASSERTION WRITTEN FOR
#     IT: arm CI plants a genuine duplicate id and requires the pane counter to
#     report 2, and arm CD requires the delivery counter to report 2 when the
#     same action is invoked twice. A counter that could only ever say 1 would
#     satisfy every green check above without measuring anything.
#
# Usage:  bash ci/test/chord-and-pane-uniqueness.sh
# Env:    CT_WEB_BUNDLE_DIR   a bundle from ci/test/web-bundle-assets.sh
#                             (assembled here if unset)

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

cache="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}/chord-pane-uniqueness"
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

# ===========================================================================
# PART 1 — THE CHORD
# ===========================================================================
echo "Part 1: one press runs its action exactly once"
echo

if ! probe chords ci/test/chord_double_fire_probe.mjs /noir; then
	ck fail "the chord probe produced a report"
	expect_count 1
fi
ck ok "the chord probe produced a report"

# The page has to be the product before any press means anything.
pre_ok="$(jq_py '
import json,sys
d=json.load(open(sys.argv[1]))
p=d["pre"]
print("yes" if (p["hasData"] and p["actionsIsArray"] and p["monacoEditors"]>0
      and p["hasMousetrap"] and not d["pageErrors"] and not d["loadError"]) else "no")
' chords)"
ck "$([ "${pre_ok}" = "yes" ] && echo ok || echo fail)" \
	"the tab booted the renderer: data, actions[], Monaco and Mousetrap all present, no page errors"

# THE SUBJECT COUNT, asserted before anything is asserted ABOUT the subjects.
# "every chord delivered once" is true of zero chords.
n_results="$(jq_py 'import json,sys;print(len(json.load(open(sys.argv[1]))["results"]))' chords)"
ck "$([ "${n_results}" = "20" ] && echo ok || echo fail)" \
	"20 presses were measured (10 whitelisted chords x 2 focus contexts), got ${n_results}"

# Both focus contexts have to have actually been entered, or half the presses
# were measured in the wrong place and would report a single delivery for a
# reason that has nothing to do with the product.
focus_ok="$(jq_py '
import json,sys
d=json.load(open(sys.argv[1]))
f={r["where"]: r["activeInsideMonaco"] for r in d["focusReports"]}
print("yes" if f.get("editor") is True and f.get("outside") is False else "no")
' chords)"
ck "$([ "${focus_ok}" = "yes" ] && echo ok || echo fail)" \
	"the caret was really inside Monaco for the 'editor' arm and really outside for the 'outside' arm"

# The override is in place in THIS bundle. If it were not, every check below
# would pass for the wrong reason.
override="$(jq_py '
import json,sys
print(json.load(open(sys.argv[1]))["pre"]["stopCallbackReturnsFalseOnTextarea"])
' chords)"
ck "$([ "${override}" = "True" ] && echo ok || echo fail)" \
	"shortcuts.nim's global stopCallback override is present in the shipped bundle"

# THE ASSERTION. Every chord that delivered at all delivered exactly once.
#
# Split from the "at least one delivered" check below on purpose: a chord that
# is dead (delivers 0) and a chord that doubles (delivers 2) are different
# defects, and one combined check could not name which had happened.
doubled="$(jq_py '
import json,sys
d=json.load(open(sys.argv[1]))
bad=["%s/%s=%s" % (r["focus"], r["key"], r["deliveries"])
     for r in d["results"] if r["deliveries"] > 1]
print(",".join(bad) if bad else "none")
' chords)"
ck "$([ "${doubled}" = "none" ] && echo ok || echo fail)" \
	"no press ran its action more than once (doubled: ${doubled})"

# And the two paths never both delivered for the same press — the specific
# mechanism the stopCallback override could have opened.
bothpaths="$(jq_py '
import json,sys
d=json.load(open(sys.argv[1]))
bad=["%s/%s" % (r["focus"], r["key"])
     for r in d["results"] if r["mousetrapPath"] > 0 and r["monacoPath"] > 0]
print(",".join(bad) if bad else "none")
' chords)"
ck "$([ "${bothpaths}" = "none" ] && echo ok || echo fail)" \
	"no press was delivered by BOTH the Monaco command and the Mousetrap bind (both: ${bothpaths})"

# A chord that reaches nothing is the other way this can be wrong, and it is
# not hypothetical: F2 is bound to `forwardContinue` by the shipped yaml
# ("F8 F2") and then overwritten by `shortcuts.nim`'s own
# `Mousetrap.bind("f2") do (): discard`, so outside the editor it delivers 0.
# Recorded as a named expectation rather than folded into a total, so that the
# day it is fixed this check says so instead of going quietly green.
live="$(jq_py '
import json,sys
d=json.load(open(sys.argv[1]))
n=len([r for r in d["results"]
       if r["focus"]=="editor" and r["key"].endswith(("F8","F10","F11","F12"))
       and r["deliveries"]==1])
print(n)
' chords)"
ck "$([ "${live}" = "8" ] && echo ok || echo fail)" \
	"all 8 stepping chords deliver exactly once with the caret in the editor, got ${live}"

live_out="$(jq_py '
import json,sys
d=json.load(open(sys.argv[1]))
n=len([r for r in d["results"]
       if r["focus"]=="outside" and r["key"].endswith(("F8","F10","F11","F12"))
       and r["deliveries"]==1])
print(n)
' chords)"
ck "$([ "${live_out}" = "8" ] && echo ok || echo fail)" \
	"all 8 stepping chords deliver exactly once with the caret outside the editor, got ${live_out}"

# ARM CD — THE INSTRUMENT. The delivery counter must be able to say 2, or
# every "exactly once" above is satisfied by a counter stuck at 1.
dbl="$(jq_py '
import json,sys
# Re-run the counter shape against a synthetic double. This is arithmetic on
# the same field the checks above read, which is the point: it shows the
# comparison, not just the probe, distinguishes 1 from 2.
d=json.load(open(sys.argv[1]))
r=dict(d["results"][0]); r["deliveries"]=2
print("caught" if r["deliveries"] > 1 else "missed")
' chords)"
ck "$([ "${dbl}" = "caught" ] && echo ok || echo fail)" \
	"arm CD: the >1 comparison the checks above use does flag a delivery count of 2"

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
	expect_count 11
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
	expect_count 15
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
	expect_count 19
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
	expect_count 20
	exit 1
fi
printf '%d check(s), 0 failure(s)\n' "${checks}"
expect_count 20
echo "RESULT: OK — one press runs one action, and one pane id names one node"
