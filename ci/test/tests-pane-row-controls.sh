#!/usr/bin/env bash
#
# tests-pane-row-controls.sh — the TESTS pane must offer, per row, TWO
# different actions, and one of them must not re-run anything.
#
# WHAT IS ASSERTED, AND WHY IT IS ASSERTED THIS WAY
# -------------------------------------------------
# The user's request: "The tests results panel should offer a way to re-run a
# specific test and to enter an existing recording (this is not necessarily a
# re-run)." The parenthesis is the requirement, and it is the reason this file
# is not a check that the pane has buttons.
#
# Every arm below names ONE control and ONE fact. "The TESTS pane has buttons"
# cannot fail for its own reason; "pressing ⏵ left the recording id unchanged"
# can fail for exactly one.
#
# THE INSTRUMENT IS A REAL BROWSER, AND THE DISCRIMINATOR IS AN ID.
# `ci/test/tests_pane_row_controls_probe.mjs` reads `data-ct-recording-id` off
# each row before and after each gesture. The three gestures must move it
# differently:
#
#     ⟳  refresh       id CHANGES,   no debugger opens
#     ⏵  open          id UNCHANGED, a debugger opens
#     ⇧⏵ refresh+open  id CHANGES,   a debugger opens
#
# AND THE RECORDING'S CLOCK MOVES WITH ITS ID, asserted separately. `recordedAt`
# is published beside the id — on the row as `data-ct-recorded-at`, and on both
# host log lines as `recordedAt=` — because a single string carrying the whole
# claim is the trap. The id is minted per retention; the time is read off the
# clock at the same instant; they are produced by different code at different
# moments. An implementation that re-ran the test but derived the id from the
# SELECTOR would leave every id arm green and is caught only by the clock.
#
# A harness that could not tell the middle row from the other two would certify
# an implementation that re-ran the test every time — which is the one thing
# the user said this feature is not.
#
# AND A SECOND INSTRUMENT, deliberately unlike the first. `web_noir_build`
# logs `test-recording-retained` when a recording is MADE and
# `test-recording-entered` when one is REPLAYED. Those deltas are counted per
# gesture. One instrument is a rendered attribute derived through the view
# model; the other is a console line emitted at the moment of retention. Two
# instruments agreeing by accident is not available to them, which is what
# Verification-Harness-Traps.md asks for when a single number carries a claim.
#
# DO NOT GREP `ui.js`. Nim's JS backend emits some string literals as bare
# char-code arrays, so a bundle that contains a feature can fail a text search
# and one that does not can pass a loose one. Everything here queries the DOM.
#
# Usage:  bash ci/test/tests-pane-row-controls.sh
# Env:    CT_WEB_BUNDLE_DIR   a bundle assembled by ci/test/web-bundle-assets.sh
#                             Assembled here if unset, which is what lets this
#                             run as a `just` recipe and a workflow step; set
#                             it to point the same script at a control tree.
#         CT_SHOT_DIR         where the probe writes its screenshots
#         CT_PROBE_SETTLE_MS  how long to wait for the renderer to mount

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=ci/lib/nim-cache-root.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "${repo_root}/ci/lib/nim-cache-root.sh"
cd "${repo_root}" || exit 2

bundle="${CT_WEB_BUNDLE_DIR:-}"
shot_dir="${CT_SHOT_DIR:-${repo_root}/test-logs/tests-pane-row-controls}"
settle="${CT_PROBE_SETTLE_MS:-12000}"

checks=0
failures=0
ck_ok() {
	checks=$((checks + 1))
	printf '  [OK]      %s\n' "$*"
}
ck_fail() {
	checks=$((checks + 1))
	failures=$((failures + 1))
	printf '  [FAILED]  %s\n' "$*"
}
ck() {
	# ck <condition-as-exit-status> <message>
	if [ "$1" = "0" ]; then ck_ok "$2"; else ck_fail "$2"; fi
}
skipped=0
ck_skip() {
	# NOT COUNTED AS A CHECK, and printed loudly.
	#
	# A skip that is tallied with the passes is how a gate reports a green it
	# did not earn. These lines say what was not measured and why, and the
	# summary repeats the count so a reader cannot mistake a half-run gate for
	# a whole one.
	skipped=$((skipped + 1))
	printf '  [SKIPPED] %s\n' "$*"
}

echo "=== the TESTS pane's two per-row controls ==="
echo

command -v node >/dev/null 2>&1 || {
	echo "node is not on PATH; run inside the dev shell" >&2
	exit 2
}

mkdir -p "${shot_dir}"
cache="$(ct_nim_cache_root "${repo_root}")/tests-pane-row-controls"
mkdir -p "${cache}"

# THE BUNDLE UNDER TEST, assembled here when none was handed in.
#
# This used to `exit 2` without `CT_WEB_BUNDLE_DIR`, and that is why the gate
# landed dark: a script that cannot run without an env var nobody sets is not
# reachable from a `just` recipe or a workflow step, and it spent its first day
# on `shell-gate-coverage.known-dark.txt` for exactly that. `web-renderer-
# mounts.sh` established the convention — reuse a bundle when given one, build
# one otherwise — and it is the convention that makes a gate wireable.
if [ -z "${bundle}" ]; then
	bundle="${cache}/bundle"
	echo "Assembling a bundle (CT_WEB_BUNDLE_DIR unset)..."
	if ! CT_WEB_BUNDLE_DIR="${bundle}" bash ci/test/web-bundle-assets.sh \
		>"${cache}/assemble.log" 2>&1; then
		echo "  the bundle did not assemble; see ${cache}/assemble.log" >&2
		tail -20 "${cache}/assemble.log" >&2
		exit 1
	fi
	echo "  assembled at ${bundle}"
fi
if [ ! -s "${bundle}/index.html" ]; then
	echo "no index.html in ${bundle}; nothing to load" >&2
	exit 1
fi

# The same loopback server `web-renderer-mounts.sh` uses, and for its reasons:
# port 0 so two arms cannot race, and the bundle's own `_redirects` applied so
# `/noir` reaches the application rather than a 404 this harness invented.
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
# shellcheck disable=SC2329  # invoked indirectly, by the EXIT trap below
stop_server() {
	if [ -n "${server_pid}" ] && kill -0 "${server_pid}" 2>/dev/null; then
		kill "${server_pid}" 2>/dev/null
		wait "${server_pid}" 2>/dev/null
	fi
}
trap stop_server EXIT

port_file="${cache}/port"
: >"${port_file}"
python3 "${cache}/serve.py" "${bundle}" >"${port_file}" 2>/dev/null &
server_pid=$!
for _ in $(seq 1 50); do
	port="$(head -n1 "${port_file}" 2>/dev/null || true)"
	[ -n "${port}" ] && break
	sleep 0.2
done
[ -n "${port:-}" ] || {
	echo "the static server did not report a port" >&2
	exit 2
}

report="${cache}/report.json"
echo "  serving ${bundle} at http://127.0.0.1:${port}/noir"
echo "  screenshots -> ${shot_dir}"
echo

node ci/test/tests_pane_row_controls_probe.mjs \
	"http://127.0.0.1:${port}/noir" "${shot_dir}" "${settle}" >"${report}" 2>"${cache}/probe.err"
probe_status=$?

if [ "${probe_status}" -ne 0 ] || [ ! -s "${report}" ]; then
	echo "  the probe did not produce a report:" >&2
	tail -n 40 "${cache}/probe.err" >&2
	exit 2
fi

# One helper, so every arm reads the report the same way and a typo in a JSON
# path shows up as an empty string rather than as a silently green check.
j() { node -e '
const r = require(process.argv[1]);
const step = (n) => (r.steps || []).find((s) => s.name === n) || {};
const v = eval(process.argv[2]);
process.stdout.write(v === undefined || v === null ? "" : String(v));
' "${report}" "$1"; }

fatal="$(j 'r.fatal || ""')"
if [ -n "${fatal}" ]; then
	echo "  the probe raised: ${fatal}" >&2
fi

# --- 0. THE INSTRUMENT ITSELF -----------------------------------------------
# Trap 4, the empty haystack: a probe that found no rows would answer "no
# button was disabled" and "no id changed" to every question below, and every
# one of them would be green. So the row count is asserted FIRST and the rest
# is only meaningful after it.
tabs_found="$(j 'step("tests-tab").found')"
ck "$([ "${tabs_found}" = "true" ] && echo 0 || echo 1)" \
	"the TESTS tab is reachable (captions: $(j 'JSON.stringify(step("tests-tab").captions||[])'))"

initial_rows="$(j '(step("initial").rows||[]).length')"
ck "$([ "${initial_rows:-0}" -gt 0 ] && echo 0 || echo 1)" \
	"the pane lists ${initial_rows:-0} test row(s), so the checks below have something to measure"

# ERRORS UP TO THE FIRST NAVIGATION ARE THIS PANE'S. See the probe: everything
# before the first ⏵ is mounting, painting, recording and modifier tracking;
# everything after is the replay-entry path this feature calls and does not own.
pane_errors="$(j '(r.pageErrorsBeforeNavigation||r.pageErrors||[]).length')"
ck "$([ "${pane_errors:-0}" -eq 0 ] && echo 0 || echo 1)" \
	"the pane raised ${pane_errors:-0} uncaught error(s) before any navigation: $(j 'JSON.stringify((r.pageErrorsBeforeNavigation||r.pageErrors||[]).slice(0,3))')"

# --- 1. BOTH CONTROLS EXIST, PER ROW, AND ARE VISIBLE -----------------------
# Named separately. A build that added one of the two passes neither of these
# by accident, which is the point of not writing "the row has controls".
with_refresh="$(j '(step("initial").rows||[]).filter((x)=>x.refresh&&x.refresh.present).length')"
ck "$([ "${with_refresh:-0}" = "${initial_rows:-0}" ] && [ "${initial_rows:-0}" -gt 0 ] && echo 0 || echo 1)" \
	"every row carries a REFRESH control (⟳): ${with_refresh:-0}/${initial_rows:-0}"

with_open="$(j '(step("initial").rows||[]).filter((x)=>x.open&&x.open.present).length')"
ck "$([ "${with_open:-0}" = "${initial_rows:-0}" ] && [ "${initial_rows:-0}" -gt 0 ] && echo 0 || echo 1)" \
	"every row carries an OPEN control (⏵): ${with_open:-0}/${initial_rows:-0}"

# PAINTED, not merely present. A zero-sized control is unreachable and looks
# identical in the DOM to one a user can click.
visible="$(j '(step("initial").rows||[]).filter((x)=>x.refresh&&x.open&&x.refresh.box.w>0&&x.refresh.box.h>0&&x.open.box.w>0&&x.open.box.h>0).length')"
ck "$([ "${visible:-0}" = "${initial_rows:-0}" ] && [ "${initial_rows:-0}" -gt 0 ] && echo 0 || echo 1)" \
	"both controls have a non-zero box on every row: ${visible:-0}/${initial_rows:-0}"

# --- 2. THE LABELS ARE HONEST BEFORE ANY RECORDING EXISTS -------------------
# A row with no recording must NOT be offered "open the recording". This is the
# one place a correct implementation could still lie.
honest="$(j '(step("initial").rows||[]).filter((x)=>x.open&&x.open.openMode==="record-and-open"&&!/^Open the recording/.test(x.open.title)).length')"
ck "$([ "${honest:-0}" = "${initial_rows:-0}" ] && [ "${initial_rows:-0}" -gt 0 ] && echo 0 || echo 1)" \
	"with no recording, ⏵ is labelled record-and-open and never 'Open the recording': ${honest:-0}/${initial_rows:-0}"

# --- 3. SHIFT IS DISCOVERABLE WITHOUT PRESSING SHIFT ------------------------
# The whole answer to "a modifier nobody can see". Asserted on the UNSHIFTED
# tooltip of a row that HAS a recording, further down; here on the collapse.
collapsed="$(j '(step("shift-with-no-recording").rows||[]).filter((x)=>x.open&&x.open.openMode==="record-and-open"&&!/shift-armed/.test(x.open.className)).length')"
shift_rows="$(j '(step("shift-with-no-recording").rows||[]).length')"
ck "$([ -n "${shift_rows}" ] && [ "${collapsed:-0}" = "${shift_rows:-0}" ] && [ "${shift_rows:-0}" -gt 0 ] && echo 0 || echo 1)" \
	"holding Shift over a never-recorded row changes nothing and does not claim to: ${collapsed:-0}/${shift_rows:-0}"

# --- 3b. CAN THIS DEPLOYMENT RECORD AT ALL? ---------------------------------
#
# The Noir compiler, tracer and replay engine are OPTIONAL bundle assets. A
# bundle assembled without them cannot run a test, cannot make a recording, and
# therefore cannot move the id or the clock that every arm below compares. Those
# arms would all redden, and NOT because a control is wrong.
#
# `web-bundle-assets.sh` set the convention for exactly these assets — skip that
# part loudly and still check everything else — and the reason is in
# `shell-gate-coverage.known-dark.txt`: a red that is always red stops being
# read. Everything above this line is real and was measured on this bundle.
#
# THE ABSENCE IS ITSELF ASSERTED, so this branch is not a way of measuring
# nothing. A deployment that cannot record must say so ON THE CONTROL, and a
# disabled control that explains itself is a requirement of §9.1.1 rather than a
# consolation prize. This is the only configuration in which that can be checked
# against the real product, so it is checked here rather than skipped too.
can_record="$(j 'step("deployment").canRecord')"
run_absence="$(j 'step("deployment").refreshTitle')"
if [ "${can_record}" != "true" ]; then
	refresh_disabled="$(j 'step("deployment").refreshDisabled')"
	ck "$([ "${refresh_disabled}" = "true" ] && echo 0 || echo 1)" \
		"this deployment cannot run tests, and ⟳ is disabled rather than dead: disabled=${refresh_disabled}"
	ck "$([ -n "${run_absence}" ] && echo 0 || echo 1)" \
		"…and it states its own reason rather than rendering inert: \"${run_absence}\""

	open_absence="$(j 'step("deployment").openTitle')"
	case "${open_absence}" in
	*"no recording"*)
		ck_ok "…and ⏵ names BOTH absences — the deployment's and the row's: \"${open_absence}\""
		;;
	*)
		ck_fail "⏵ does not tell the reader its row has no recording either: \"${open_absence}\""
		;;
	esac

	echo
	ck_skip "the ⟳ / ⏵ / ⇧⏵ recording arms: this bundle carries no Noir compiler,"
	ck_skip "  so no recording can be made and the id/clock discriminator has"
	ck_skip "  nothing to move. Set CT_NOIR_WASM_COMPILER, CT_NOIR_WASM_TRACER"
	ck_skip "  and CT_REPLAY_ENGINE_DIR when assembling the bundle to measure them."
	echo
	echo "  ${checks} check(s), ${failures} failure(s), ${skipped} skipped"
	[ "${failures}" -eq 0 ] || exit 1
	exit 0
fi

# --- 4. ⟳ REFRESH: a recording is made, and NOTHING navigates ---------------
refresh_retained="$(j 'step("after-refresh").retainedDelta')"
ck "$([ "${refresh_retained:-0}" -ge 1 ] && echo 0 || echo 1)" \
	"⟳ produced ${refresh_retained:-0} new recording(s) (test-recording-retained)"

refresh_ids="$(j '(step("after-refresh").rows||[]).filter((x)=>x.recordingId).length')"
ck "$([ "${refresh_ids:-0}" -ge 1 ] && echo 0 || echo 1)" \
	"⟳ left ${refresh_ids:-0} row(s) carrying a recording id, so ⏵ has something to enter"

refresh_nav="$(j 'step("after-refresh").debuggerOpened')"
ck "$([ "${refresh_nav}" = "false" ] && echo 0 || echo 1)" \
	"⟳ did NOT navigate into the debugger (debuggerOpened=${refresh_nav}) — refresh is not enter"

refresh_entered="$(j 'step("after-refresh").enteredDelta')"
ck "$([ "${refresh_entered:-0}" -eq 0 ] && echo 0 || echo 1)" \
	"⟳ replayed nothing (test-recording-entered delta ${refresh_entered:-0})"

# --- 4a. THE CONTROL MUST BE REACHABLE BY A POINTER -------------------------
# A box and a class say the control was PAINTED. This says it can be REACHED,
# which is the campaign's commonest defect and the one a screenshot cannot show.
reachable="$(j 'step("reachability").reachableAfterDismiss')"
ck "$([ "${reachable}" = "true" ] && echo 0 || echo 1)" \
	"⏵ hit-tests to itself, so a pointer at its centre reaches the control and not something over it"

# AND THE OBSTRUCTION IS RECORDED RATHER THAN WORKED AROUND SILENTLY.
#
# The BUILD panel slides in over the layout when a run produces output and
# brings a full-viewport click-to-dismiss backdrop with it. That belongs to the
# auto-hide overlay, not to this pane — but it lands on this feature's natural
# gesture, because ⟳ then ⏵ is exactly the sequence whose second click the
# backdrop absorbs. Printed as a NOTE rather than counted as a failure of this
# pane, and deliberately not deleted: a harness that quietly clicked through it
# would leave nobody knowing.
covered="$(j 'step("reachability").coveredImmediatelyAfterRefresh')"
if [ "${covered}" = "true" ]; then
	echo "  [NOTE]    immediately after ⟳ the control is covered by $(j 'JSON.stringify((step("reachability").coveredBy||[])[0])')"
	echo "            — the BUILD overlay's click-to-dismiss backdrop. One click"
	echo "            dismisses it and the control is reachable again (asserted"
	echo "            above). This belongs to the auto-hide overlay's layer, not"
	echo "            to this pane, and is reported so it is not lost."
fi

# --- 5. THE UNSHIFTED TOOLTIP NAMES THE MODIFIER ----------------------------
names_shift="$(j '(step("open-click").armed||{}).title||""')"
case "${names_shift}" in
*"Hold Shift"*) ck_ok "the unshifted ⏵ tooltip names the modifier: \"${names_shift}\"" ;;
*) ck_fail "the unshifted ⏵ tooltip does not mention Shift, so the combined action is unreachable by anyone who does not already know it: \"${names_shift}\"" ;;
esac

case "${names_shift}" in
"Open the recording of "*) ck_ok "…and it says it opens the recording, naming it" ;;
*) ck_fail "the ⏵ tooltip over an existing recording does not say it opens one: \"${names_shift}\"" ;;
esac

# --- 6. ⏵ OPEN: THE RECORDING IS ENTERED AND NOTHING IS RE-RUN --------------
# THE ASSERTION THIS WHOLE FILE EXISTS FOR.
id_before="$(j 'step("after-open").idBefore')"
entered_id="$(j 'step("after-open").enteredRecordingId')"
entered_existing="$(j 'step("after-open").enteredTheExistingRecording')"
ck "$([ "${entered_existing}" = "true" ] && echo 0 || echo 1)" \
	"⏵ entered the EXISTING recording: the row carried '${id_before}' and the host opened '${entered_id}' — a different id would mean the test was silently re-run"

# AND THE ROW'S OWN ATTRIBUTE AGREES, where the row survives to be read.
# Entering a recording is a mode switch and the pane is re-mounted by it, so
# this arm is written to be satisfied by "unchanged" or by "the row is gone" —
# and is NOT the load-bearing one. The arm above is, precisely because the
# host's line survives what the row does not.
id_after="$(j 'step("after-open").idAfter')"
unchanged="$(j 'step("after-open").recordingIdUnchanged')"
ck "$([ "${unchanged}" = "true" ] && echo 0 || echo 1)" \
	"…and the row never pointed at a different recording afterwards (now: '${id_after}')"

# AND THE CLOCK SAYS THE SAME THING, for a reason the id cannot cover.
#
# The id is minted per retention in `web_noir_build`; the time is read off the
# clock at the same instant. They are produced by different code at different
# moments, so an implementation that re-ran the test but derived the id from
# the SELECTOR — a plausible way to mint ids, and one that would leave every
# id arm above green — moves the clock and is caught only here. One string
# carrying the whole claim is the trap Verification-Harness-Traps.md names.
entered_at="$(j 'step("after-open").enteredRecordedAt')"
at_before="$(j 'step("after-open").atBefore')"
same_moment="$(j 'step("after-open").enteredTheRecordingMadeAtTheSameMoment')"
ck "$([ "${same_moment}" = "true" ] && echo 0 || echo 1)" \
	"⏵ entered the recording made at the SAME MOMENT: the row carried '${at_before}' and the host opened one recorded at '${entered_at}' — a different time would mean a new execution behind an unchanged id"

at_unchanged="$(j 'step("after-open").recordedAtUnchanged')"
ck "$([ "${at_unchanged}" = "true" ] && echo 0 || echo 1)" \
	"…and the row's own recordedAt never moved either, where the row survived to be read"

open_retained="$(j 'step("after-open").retainedDelta')"
ck "$([ "${open_retained:-1}" -eq 0 ] && echo 0 || echo 1)" \
	"⏵ made NO new recording (test-recording-retained delta ${open_retained}) — the independent instrument agrees with the id"

open_entered="$(j 'step("after-open").enteredDelta')"
ck "$([ "${open_entered:-0}" -ge 1 ] && echo 0 || echo 1)" \
	"⏵ replayed a recording (test-recording-entered delta ${open_entered:-0}) — it did something, rather than nothing"

# AND IT LANDED. Two claims, and the reason they are separate: "the replay host
# took the request" is about the CONTROL, and "the debugger came up" is about
# the BUNDLE. A deployment that publishes no replay engine satisfies the first
# and not the second, and reporting that as a failure of `⏵` would send someone
# to fix a control that did its whole job.
open_nav="$(j 'step("after-open").debuggerOpened')"
engine_said="$(j 'JSON.stringify((r.replayLog||[]).slice(-2))')"
ck "$([ "${open_nav}" = "true" ] && echo 0 || echo 1)" \
	"⏵ landed in the debugger (debuggerOpened=${open_nav}); the replay host last said ${engine_said}"

# --- 7. ⇧⏵ REFRESH AND OPEN: a NEW recording, and it is landed in -----------
armed_class="$(j '(step("shift-open-click").armed||{}).className||""')"
case "${armed_class}" in
*shift-armed*) ck_ok "with Shift held over the button, ⏵ paints itself armed (class: ${armed_class})" ;;
*) ck_fail "⏵ does not change its appearance while Shift is held (class: '${armed_class}') — the modifier is invisible" ;;
esac

armed_title="$(j '(step("shift-open-click").armed||{}).title||""')"
case "${armed_title}" in
"Record "*"again and open"*) ck_ok "…and its tooltip, read WHILE the key was down and the pointer already on it, describes the combined action: \"${armed_title}\"" ;;
*) ck_fail "the ⏵ tooltip did not follow the modifier — it reads \"${armed_title}\", which is what a title computed at mouseover leaves behind" ;;
esac

armed_mode="$(j '(step("shift-open-click").armed||{}).openMode||""')"
ck "$([ "${armed_mode}" = "refresh-and-open" ] && echo 0 || echo 1)" \
	"…and the mode it will dispatch is '${armed_mode}' (expected refresh-and-open), so the promise and the action are one decision"

shift_changed="$(j 'step("after-shift-open").recordingIdChanged')"
shift_before="$(j 'step("after-shift-open").idBefore')"
shift_new="$(j 'step("after-shift-open").newestRetained')"
ck "$([ "${shift_changed}" = "true" ] && echo 0 || echo 1)" \
	"⇧⏵ produced a NEW recording: '${shift_before}' -> '${shift_new}' — the exact mirror of the arm above, where the id had to stay the same"

# AND IT WAS RE-MADE, NOT RENAMED. The mirror of the open arm's clock check:
# there both witnesses had to hold still, here both must move. An id that
# changed while the clock did not would be a new name over the same execution.
shift_at_changed="$(j 'step("after-shift-open").recordedAtChanged')"
shift_at_before="$(j 'step("after-shift-open").atBefore')"
shift_at_new="$(j 'step("after-shift-open").newestRetainedAt')"
ck "$([ "${shift_at_changed}" = "true" ] && echo 0 || echo 1)" \
	"⇧⏵ recorded at a NEW MOMENT: '${shift_at_before}' -> '${shift_at_new}' — an id that moved while the clock stood still would be a rename, not a re-run"

# AND IT WENT THROUGH THE RECORDING PATH, NOT THE REPLAY-THE-OLD-ONE PATH.
#
# `test-recording-entered` is emitted ONLY by `openRetainedTestRecording` — the
# proc that dispatches nothing. The shifted gesture must reach the debugger
# without that line, because it gets there by recording and then opening what
# it recorded. A delta of 1 here would mean Shift had quietly fallen back to
# opening the recording that was already there, which is the plain gesture
# wearing the shifted label.
shift_entered="$(j 'step("after-shift-open").enteredDelta')"
ck "$([ "${shift_entered:-1}" -eq 0 ] && echo 0 || echo 1)" \
	"⇧⏵ did not fall back to replaying the old recording (test-recording-entered delta ${shift_entered}) — it reached the debugger by recording"

shift_retained="$(j 'step("after-shift-open").retainedDelta')"
ck "$([ "${shift_retained:-0}" -ge 1 ] && echo 0 || echo 1)" \
	"⇧⏵ recorded (test-recording-retained delta ${shift_retained:-0}) — the mirror image of ⏵, which recorded nothing"

shift_nav="$(j 'step("after-shift-open").debuggerOpened')"
ck "$([ "${shift_nav}" = "true" ] && echo 0 || echo 1)" \
	"⇧⏵ landed in the debugger (debuggerOpened=${shift_nav})"

echo
shots="$(j '(r.shots||[]).length')"
echo "  ${shots:-0} screenshot(s) in ${shot_dir}"
echo "  report: ${report}"
echo
echo "${checks} check(s), ${failures} failure(s), ${skipped} skipped"
if [ "${failures}" -eq 0 ]; then
	echo "RESULT: OK — the pane offers two actions, and only one of them re-runs"
	exit 0
fi
echo "RESULT: FAILED"
exit 1
