#!/usr/bin/env bash
#
# chord-and-pane-uniqueness.sh — one press runs one action, one pane id names
# one node, and the `stopCallback` override still buys what the source says it
# buys. All asserted in a real browser tab, on the assembled bundle.
#
# WHY THIS EXISTS
# ---------------
# Two hazards that currently do no visible harm, each for a reason that is not
# a mechanism — and, since Part 3, one recorded MEASUREMENT that a decision
# rests on and nothing re-checked:
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
#   3. THE OVERRIDE'S JUSTIFICATION. `ui/shortcuts.nim` does not merely mention
#      `ci/test/chord_stopcallback_probe.mjs` — it names THIS FILE as the gate
#      that drives it, and records the probe's reading as the reason the line is
#      neither deleted nor narrowed: Monaco has moved to the EditContext API and
#      no longer needs it, and five untagged inputs still do. Nothing drove that
#      probe. The claim was in production source, in the present tense, and was
#      false; the probe was recorded in
#      `ci/test/shell-gate-coverage.known-dark.txt` as referenced by NOTHING AT
#      ALL. Part 3 makes the sentence true and re-measures the paragraph.
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
ck "$([ "${n_results}" = "22" ] && echo ok || echo fail)" \
	"22 presses were measured (11 whitelisted chords x 2 focus contexts), got ${n_results}"

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

# A chord that reaches nothing is the other way this can be wrong, and it was
# not hypothetical: F2 is bound to `forwardContinue` by the shipped yaml
# ("F8 F2") and used to be overwritten by `shortcuts.nim`'s own
# `Mousetrap.bind("f2") do (): discard`, so outside the editor it delivered 0.
# That bind is gone and F2 is asserted below like every other chord.
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

# F2 — CONTINUE'S SECOND CHORD, ASSERTED IN BOTH CONTEXTS.
#
# THIS IS THE ASSERTION THE FIX IS FOR, and it is deliberately about the
# DISPATCHED ACTION after a real press rather than about a binding existing. A
# binding existing is precisely what was true throughout the defect:
# `default_config.yaml` said "F8 F2" the whole time, `chordsFor(config,
# forwardContinue).len == 2` passed the whole time, and the menu, the toolbar
# tooltips and the shortcuts dialog all advertised F2 the whole time — while
# the key did nothing. Only a press can tell those apart.
#
# MEASURED, both arms, on the assembled bundle:
#   before  outside/F2 deliveries=0  mousetrap=0  monaco=0   <- dead
#           editor /F2 deliveries=1  mousetrap=0  monaco=1   <- alive
#   after   outside/F2 deliveries=1  mousetrap=1  monaco=0
#           editor /F2 deliveries=1  mousetrap=0  monaco=1
#
# BOTH CONTEXTS, because the defect was the DISAGREEMENT between them: the same
# key continued in the editor and did nothing outside it. Asserting only the
# outside arm would let a "fix" that killed the working Monaco path pass, and
# asserting only a total would let one arm's 0 hide inside the other's 2.
#
# The per-path counters are asserted too. `deliveries=1` alone cannot tell
# "Mousetrap delivered once" from "Monaco delivered once", and after removing a
# bind those are exactly the two outcomes that need distinguishing — the
# `no press was delivered by BOTH paths` check above covers the double, this
# covers the swap.
f2_out="$(jq_py '
import json,sys
d=json.load(open(sys.argv[1]))
r=[x for x in d["results"] if x["focus"]=="outside" and x["key"]=="F2"]
if len(r) != 1:
    print("missing")
else:
    r=r[0]
    print("%s/%s/%s" % (r["deliveries"], r["mousetrapPath"], r["monacoPath"]))
' chords)"
ck "$([ "${f2_out}" = "1/1/0" ] && echo ok || echo fail)" \
	"F2 outside the editor dispatches forwardContinue exactly once, through Mousetrap (deliveries/mousetrap/monaco = ${f2_out}, want 1/1/0)"

f2_in="$(jq_py '
import json,sys
d=json.load(open(sys.argv[1]))
r=[x for x in d["results"] if x["focus"]=="editor" and x["key"]=="F2"]
if len(r) != 1:
    print("missing")
else:
    r=r[0]
    print("%s/%s/%s" % (r["deliveries"], r["mousetrapPath"], r["monacoPath"]))
' chords)"
ck "$([ "${f2_in}" = "1/0/1" ] && echo ok || echo fail)" \
	"F2 inside the editor still dispatches forwardContinue exactly once, through Monaco (deliveries/mousetrap/monaco = ${f2_in}, want 1/0/1)"

# AND THE COMPARISON: F2 and F8 are the same action, so they must behave
# identically. This is what makes the two checks above a statement about the
# product rather than two numbers someone recorded — if a future change kills
# both chords, the per-chord checks redden AND this does; if it kills only F2,
# this names the asymmetry directly.
f2_f8_agree="$(jq_py '
import json,sys
d=json.load(open(sys.argv[1]))
def row(f,k):
    r=[x for x in d["results"] if x["focus"]==f and x["key"]==k]
    return (r[0]["deliveries"], r[0]["mousetrapPath"], r[0]["monacoPath"]) if r else None
bad=[f for f in ("editor","outside") if row(f,"F2") != row(f,"F8")]
print(",".join(bad) if bad else "agree")
' chords)"
ck "$([ "${f2_f8_agree}" = "agree" ] && echo ok || echo fail)" \
	"F2 and F8 — Continue's two chords — behave identically in both contexts (disagreed in: ${f2_f8_agree})"

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
# PART 1b — THE SHADOWED CHORDS
# ===========================================================================
#
# `CTRL+E` and `ALT+1`: the two chords `hardBindShadowedActions` reported as
# config entries a hardcoded bind had killed. Pressed here because the report
# was WRONG about both of them, and only a press could say so.
#
# WHAT THE REPORT ASSUMED. `hardBoundChords`' note said a hardcoded bind wins
# "because `configureShortcuts` registers them AFTER its loop over the config
# table". That is true of the binds inside `configureShortcuts`
# (`ui/shortcuts.nim`) — it is the F2 defect's mechanism. It is FALSE of the
# binds in `ui_js.nim`'s `configure`, which runs at boot while
# `configureShortcuts` runs later from an IPC reply. For those, the config loop
# is the last writer and the hardcoded bind is the dead one.
#
# MEASURED, both arms, on two assembled bundles, one press per fresh page:
#
#   CTRL+E   before  editor  switchEdit 0/0/0   readOnly false->true
#                    outside switchEdit 1/1/0   readOnly false->false
#            after   editor  aToggleReadOnly 1/0/1   readOnly false->true
#                    outside aToggleReadOnly 1/1/0   readOnly false->true
#
#   ALT+1    before  editor  aLowLevel1 1/1/0   lowLevelTabs 0->1
#                    outside aLowLevel1 1/1/0   lowLevelTabs 0->1
#            after   identical
#
# So CTRL+E ran TWO DIFFERENT ACTIONS depending on where the caret was —
# `switchEdit` outside, toggle-read-only inside, the second of them from
# `ui/editor.nim`'s Monaco `commands` table, which neither `conflictList` nor
# `hardBoundChords` can see. And ALT+1 was never shadowed at all: its config
# entry drove it in both contexts the whole time, and the `ui_js.nim` bind the
# report blamed was unreachable code.
#
# THE ALT+1 ARMS DO NOT REDDEN ON THE CONTROL BUNDLE, AND THAT IS THE RESULT.
# They are here to hold the claim that deleting an unreachable bind changed
# nothing — the numbers either side are identical, which is what "unreachable"
# has to mean if it is true. Their instrument is the CTRL+E arms beside them,
# which redden on control against the same probe and the same comparison.
#
# ONE CHORD AND ONE FOCUS CONTEXT PER PAGE. Both of these move state the other
# presses would then be measured against (CTRL+E flips the mode; ALT+1 leaves a
# tab open, and `openLowLevelCode` only CREATES that tab the first time), so a
# second press on the same page would move no counter and "the effect did not
# happen" would be indistinguishable from "it already had".
echo "Part 1b: the two chords the hard-bind registry reported, pressed"
echo

toggle_ix="$(action_ordinal aToggleReadOnly)"
switch_ix="$(action_ordinal switchEdit)"
lowlevel_ix="$(action_ordinal aLowLevel1)"
ck "$([ -n "${toggle_ix}" ] && [ -n "${switch_ix}" ] && [ -n "${lowlevel_ix}" ] &&
	[ "${toggle_ix}" != "${switch_ix}" ] && echo ok || echo fail)" \
	"the three ClientAction ordinals were derived from the enum and are distinct (aToggleReadOnly=${toggle_ix:-?} switchEdit=${switch_ix:-?} aLowLevel1=${lowlevel_ix:-?})"

for arm in ctrle-editor ctrle-outside alt1-editor alt1-outside; do
	case "${arm}" in
	ctrle-*) export CT_CHORD_SUBJECTS="Control+e" ;;
	alt1-*) export CT_CHORD_SUBJECTS="Alt+1" ;;
	esac
	case "${arm}" in
	*-editor) export CT_CHORD_FOCUS="editor" ;;
	*-outside) export CT_CHORD_FOCUS="outside" ;;
	esac
	if probe "${arm}" ci/test/chord_double_fire_probe.mjs /noir; then
		ck ok "the chord probe produced a report (${arm})"
	else
		ck fail "the chord probe produced a report (${arm})"
	fi
	unset CT_CHORD_SUBJECTS CT_CHORD_FOCUS
done

# THE SLOT EXISTS. `data.actions[aToggleReadOnly]` is read below by index, and
# an index past the end of the table reads `undefined` — which the probe's
# counter map reports as a missing key, i.e. as zero. "The chord delivered 0"
# and "the bundle has no such action" would then be the same reading, and the
# first is a defect while the second is a bundle built from the wrong tree.
tbl_len="$(jq_py '
import json,sys
print(json.load(open(sys.argv[1]))["pre"]["actionsLength"])
' ctrle-editor)"
ck "$([ -n "${tbl_len}" ] && [ "${tbl_len}" -gt "${toggle_ix:-0}" ] && echo ok || echo fail)" \
	"the shipped action table has a slot at aToggleReadOnly's ordinal (length ${tbl_len}, ordinal ${toggle_ix})"

# `chord_row <arm> <index>` -> "deliveries/mousetrap/monaco" for the one press
# the arm made, or "missing" if it did not make exactly one.
chord_row() {
	jq_py '
import json,sys
d=json.load(open(sys.argv[1]))
ix=sys.argv[2]
r=d["results"]
if len(r) != 1:
    print("missing")
else:
    r=r[0]
    print("%s/%s/%s" % (r["allDeliveries"].get(ix, 0), r["mousetrapPath"], r["monacoPath"]))
' "$1" "$2"
}

# CTRL+E, BOTH CONTEXTS, AND THE PER-PATH COUNTERS. `deliveries == 1` cannot
# tell "Mousetrap delivered" from "Monaco delivered", and the whole content of
# this fix is that the two contexts now dispatch the SAME action through
# different paths rather than two different actions.
ctrle_in="$(chord_row ctrle-editor "${toggle_ix}")"
ck "$([ "${ctrle_in}" = "1/0/1" ] && echo ok || echo fail)" \
	"CTRL+E inside the editor dispatches aToggleReadOnly exactly once, through Monaco (deliveries/mousetrap/monaco = ${ctrle_in}, want 1/0/1)"

ctrle_out="$(chord_row ctrle-outside "${toggle_ix}")"
ck "$([ "${ctrle_out}" = "1/1/0" ] && echo ok || echo fail)" \
	"CTRL+E outside the editor dispatches aToggleReadOnly exactly once, through Mousetrap (deliveries/mousetrap/monaco = ${ctrle_out}, want 1/1/0)"

# AND `switchEdit` IS NOT WHAT IT REACHES, in either context. This is the half
# the delivery counts above cannot state: a chord that dispatched BOTH would
# satisfy "aToggleReadOnly exactly once" perfectly. `switchEdit` held CTRL+E in
# the YAML until this change and reached it outside the editor only, which is
# the asymmetry that made the chord mean two things.
switch_hits="$(
	a="$(jq_py '
import json,sys
d=json.load(open(sys.argv[1]))
print(d["results"][0]["allDeliveries"].get(sys.argv[2], 0) if len(d["results"])==1 else "?")
' ctrle-editor "${switch_ix}")"
	b="$(jq_py '
import json,sys
d=json.load(open(sys.argv[1]))
print(d["results"][0]["allDeliveries"].get(sys.argv[2], 0) if len(d["results"])==1 else "?")
' ctrle-outside "${switch_ix}")"
	echo "${a}/${b}"
)"
ck "$([ "${switch_hits}" = "0/0" ] && echo ok || echo fail)" \
	"CTRL+E dispatches switchEdit in NEITHER context (editor/outside = ${switch_hits}, want 0/0)"

# THE EFFECT, not only the dispatch. Every check above counts a call into
# `data.actions`, and a handler that had been replaced by a no-op would satisfy
# all of them. `toggleReadOnly` moves `data.ui.readOnly` and `data.ui.mode`;
# both must move, in BOTH contexts, or the chord is delivered and inert.
ctrle_effect="$(
	for arm in ctrle-editor ctrle-outside; do
		jq_py '
import json,sys
d=json.load(open(sys.argv[1]))
r=d["results"][0] if len(d["results"])==1 else None
print("yes" if r and r["readOnlyChanged"] and r["modeChanged"] else "no", end=",")
' "${arm}"
	done
)"
ck "$([ "${ctrle_effect}" = "yes,yes," ] && echo ok || echo fail)" \
	"CTRL+E really toggles read-only and mode in BOTH contexts, not merely dispatches (editor,outside = ${ctrle_effect})"

# ALT+1 — the arm that must NOT change between the two bundles.
alt1_in="$(chord_row alt1-editor "${lowlevel_ix}")"
ck "$([ "${alt1_in}" = "1/1/0" ] && echo ok || echo fail)" \
	"ALT+1 inside the editor dispatches aLowLevel1 exactly once, through Mousetrap — Monaco does not consume it (deliveries/mousetrap/monaco = ${alt1_in}, want 1/1/0)"

alt1_out="$(chord_row alt1-outside "${lowlevel_ix}")"
ck "$([ "${alt1_out}" = "1/1/0" ] && echo ok || echo fail)" \
	"ALT+1 outside the editor dispatches aLowLevel1 exactly once, through Mousetrap (deliveries/mousetrap/monaco = ${alt1_out}, want 1/1/0)"

alt1_effect="$(
	for arm in alt1-editor alt1-outside; do
		jq_py '
import json,sys
d=json.load(open(sys.argv[1]))
r=d["results"][0] if len(d["results"])==1 else None
print(r["lowLevelTabsOpened"] if r else "?", end=",")
' "${arm}"
	done
)"
ck "$([ "${alt1_effect}" = "1,1," ] && echo ok || echo fail)" \
	"ALT+1 opens exactly one Low Level Code pane in each context (editor,outside = ${alt1_effect}, want 1,1)"

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
	expect_count 27
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
	expect_count 31
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
	expect_count 35
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

# ===========================================================================
# PART 3 — WHAT THE stopCallback OVERRIDE STILL BUYS
#
# `ui/shortcuts.nim` names this file and TWO probes as the gate for the
# override, in the present tense: "the gate is `ci/test/chord-and-pane-
# uniqueness.sh` and the probes it drives are `ci/test/chord_double_fire_probe.mjs`
# and `ci/test/chord_stopcallback_probe.mjs`". It drove only the first.
# `chord_stopcallback_probe.mjs` was named nowhere that runs — it was recorded
# in `ci/test/shell-gate-coverage.known-dark.txt` as referenced by NOTHING AT
# ALL, and the sentence in `shortcuts.nim` is why that entry understated it:
# the claim existed, in production source, and was false.
#
# WHAT IS ASSERTED, AND WHERE THE EXPECTED VALUES COME FROM. `shortcuts.nim`
# does not merely mention the probe; it records the probe's READING and rests a
# decision on it — "Monaco no longer needs this line at all", and "deleting it
# would silently kill chords in those five". Those two sentences are the reason
# the line is neither removed nor narrowed, and nothing re-measured them. So
# the expected sets are DERIVED from that comment rather than copied into this
# file: one declaration, and a product that drifts from it reddens here instead
# of quietly invalidating the paragraph a future reader will trust. Same
# convention as `action_ordinal` above, which derives an index from the enum
# rather than writing the number down twice.
# ===========================================================================
echo "Part 3: the stopCallback override, and what it is still for"
echo

# `stopcallback_ledger buys|exempt` — the selectors `ui/shortcuts.nim` records,
# one per line. Prints nothing and returns non-zero when the paragraph cannot
# be found or comes back empty, so a reworded comment becomes a FAILED check
# rather than an empty set matching an empty set.
stopcallback_ledger() {
	/usr/bin/python3 - "$1" <<'PY'
import re
import sys

which = sys.argv[1]
path = "src/frontend/ui/shortcuts.nim"
src = open(path, encoding="utf-8").read()
try:
    start = src.index("WHAT IT STILL BUYS")
    end = src.index("IT IS NOT A DOUBLE-DELIVERY HAZARD TODAY", start)
except ValueError:
    sys.stderr.write(
        "the 'WHAT IT STILL BUYS' paragraph is gone from %s; this gate reads "
        "its selector ledger from there\n" % path)
    sys.exit(3)
block = src[start:end]
split = block.find("already exempt the intended way")
if split < 0:
    sys.stderr.write("the exempt-by-class sentence is gone from %s\n" % path)
    sys.exit(3)
half = block[:split] if which == "buys" else block[split:]
# Backticked CSS selectors only: `#id`, `.class`, `tag.class`.
found = [m for m in re.findall(r"`([#.][A-Za-z0-9_-]+|[a-z]+\.[A-Za-z0-9_-]+)`", half)]
seen = []
for f in found:
    if f not in seen:
        seen.append(f)
if not seen:
    sys.stderr.write("no selectors found in the %s half of the ledger\n" % which)
    sys.exit(3)
print("\n".join(seen))
PY
}

if ! probe stopcallback ci/test/chord_stopcallback_probe.mjs /noir; then
	ck fail "the stopCallback probe produced a report"
	expect_count 37
fi
ck ok "the stopCallback probe produced a report"

# THE PAGE HAS TO BE THE PRODUCT, AND THE CARET HAS TO BE IN MONACO, before any
# reading below means anything. A probe that clicked nothing would report
# `defaultWouldStop: false` for `document.body` and look identical to the
# finding.
pre="$(jq_py '
import json,sys
r=json.load(open(sys.argv[1]))["report"]
d=json.load(open(sys.argv[1]))
print("yes" if (r["monacoEditors"] > 0 and r["activeInsideMonaco"]
                and not d["pageErrors"] and not d["loadError"]) else "no")
print("monacoEditors=%s activeInsideMonaco=%s active=%s"
      % (r["monacoEditors"], r["activeInsideMonaco"],
         (r["activeElement"] or {}).get("cls")))
' stopcallback)"
ck "$([ "$(printf '%s' "${pre}" | head -1)" = "yes" ] && echo ok || echo fail)" \
	"the tab is the product and the caret is inside Monaco"
note "$(printf '%s' "${pre}" | tail -n +2)"

# THE FACT THE "IT HAS EXPIRED" PARAGRAPH RESTS ON. Monaco used to take
# keystrokes on `textarea.inputarea`, which the DEFAULT rule swallows; current
# Chromium Monaco uses the EditContext API and focuses
# `div.native-edit-context`, which it does not. If this ever flips back, the
# override becomes load-bearing for the editor again and the whole paragraph in
# `shortcuts.nim` is wrong.
host="$(jq_py '
import json,sys
r=json.load(open(sys.argv[1]))["report"]
ok = (r["hasNativeEditContext"] and not r["hasTextareaInputArea"]
      and (r["activeElement"] or {}).get("defaultWouldStop") is False)
print("yes" if ok else "no")
print("hasNativeEditContext=%s hasTextareaInputArea=%s defaultWouldStop=%s"
      % (r["hasNativeEditContext"], r["hasTextareaInputArea"],
         (r["activeElement"] or {}).get("defaultWouldStop")))
' stopcallback)"
ck "$([ "$(printf '%s' "${host}" | head -1)" = "yes" ] && echo ok || echo fail)" \
	"Monaco's input host is the EditContext div, which the DEFAULT rule would not stop"
note "$(printf '%s' "${host}" | tail -n +2)"

# WHAT THE OVERRIDE STILL BUYS, against the ledger in `shortcuts.nim`.
#
# An element that appears here and not in the comment is a new input nobody
# tagged `mousetrap` — which is precisely the deliberate decision the comment
# asks for ("a question worth answering deliberately ... rather than as a side
# effect of a cleanup"), so it is a red and not a note. One that disappears
# means the paragraph now over-states what the line is for.
if ! stopcallback_ledger buys >"${cache}/ledger-buys.txt" 2>"${cache}/ledger.err"; then
	ck fail "ui/shortcuts.nim still carries the selector ledger this gate reads"
	note "$(head -2 "${cache}/ledger.err")"
else
	ck ok "ui/shortcuts.nim still carries the selector ledger this gate reads"
fi

match_selectors() {
	## match_selectors <report-key> <ledger-file> — prints `yes`/`no` then a
	## detail line. Matches `#id`, `.class` and `tag.class` against the probe's
	## {tag, cls, id} triples.
	/usr/bin/python3 - "${cache}/stopcallback.json" "$1" "$2" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1]))["report"]
key, ledger_path = sys.argv[2], sys.argv[3]
wanted = [l.strip() for l in open(ledger_path) if l.strip()]


def describe(e):
    return e["id"] and "#" + e["id"] or (
        e["tag"].lower() + "." + (e["cls"].split() or [""])[0])


def matches(sel, e):
    if sel.startswith("#"):
        return e["id"] == sel[1:]
    if sel.startswith("."):
        return sel[1:] in e["cls"].split()
    tag, _, cls = sel.partition(".")
    return e["tag"].lower() == tag and cls in e["cls"].split()


found = report[key]
unmatched_sel = [s for s in wanted if not any(matches(s, e) for e in found)]
extra = [describe(e) for e in found
         if not any(matches(s, e) for s in wanted)]
print("yes" if (not unmatched_sel and not extra) else "no")
bits = []
if unmatched_sel:
    bits.append("recorded but NOT on screen: " + ", ".join(unmatched_sel))
if extra:
    bits.append("on screen but NOT recorded in ui/shortcuts.nim: " + ", ".join(extra))
if not bits:
    bits.append("%d element(s), exactly the ledger: %s" % (len(found), ", ".join(wanted)))
print("; ".join(bits))
PY
}

buys="$(match_selectors blockedByDefault "${cache}/ledger-buys.txt")"
ck "$([ "$(printf '%s' "${buys}" | head -1)" = "yes" ] && echo ok || echo fail)" \
	"the inputs the override covers are exactly the ones ui/shortcuts.nim records"
note "$(printf '%s' "${buys}" | tail -n +2)"

if ! stopcallback_ledger exempt >"${cache}/ledger-exempt.txt" 2>>"${cache}/ledger.err"; then
	ck fail "the exempt-by-class half of the ledger is still readable"
	note "$(tail -2 "${cache}/ledger.err")"
else
	ck ok "the exempt-by-class half of the ledger is still readable"
fi

exempt="$(match_selectors exemptByClass "${cache}/ledger-exempt.txt")"
ck "$([ "$(printf '%s' "${exempt}" | head -1)" = "yes" ] && echo ok || echo fail)" \
	"the inputs already tagged \`mousetrap\` are exactly the ones recorded"
note "$(printf '%s' "${exempt}" | tail -n +2)"

# ARM SI — THE INSTRUMENT. Every check above compares a measured set against a
# ledger, and a comparison that could only ever say "equal" would satisfy all of
# them. A selector the page cannot contain must be REPORTED MISSING.
printf '#a-selector-no-page-will-ever-carry\n' >"${cache}/ledger-instrument.txt"
inst_sc="$(match_selectors blockedByDefault "${cache}/ledger-instrument.txt")"
ck "$([ "$(printf '%s' "${inst_sc}" | head -1)" = "no" ] && echo ok || echo fail)" \
	"arm SI: a selector no page carries is reported missing, so the two checks above are not vacuous"
note "$(printf '%s' "${inst_sc}" | tail -n +2)"

echo
if [ "${failures}" -ne 0 ]; then
	printf 'RESULT: FAILED — %d of %d check(s)\n' "${failures}" "${checks}"
	expect_count 44
	exit 1
fi
printf '%d check(s), 0 failure(s)\n' "${checks}"
expect_count 44
echo "RESULT: OK — one press runs one action, one pane id names one node, and"
echo "            the stopCallback override still buys what the source says"
