#!/usr/bin/env bash
#
# noir-mode-roundtrip.sh — EDIT -> RUN -> REPLAY -> STOP -> EDIT, three times,
# in a real browser tab against the assembled publish tree.
#
# WHAT THIS ASSERTS THAT NOTHING ELSE DOES
# ----------------------------------------
# `ci/test/noir-build-in-browser.sh` proves a Build gesture reaches the Noir
# compiler.  `ci/test/noir-replay-in-browser.sh` proves a Run produces a trace
# a session can step through, and that an edit survives a `ctrl+f5` return.
# `ci/test/noir-edit-persists.sh` proves typing survives a reload.
#
# All three can be true of a product whose MODE never changes, and the mode is
# what the user asked about.  This gate's subject is the TRANSITION:
#
#   * the topbar surface the product itself declares, read at every leg
#     (`data-topbar-surface`, emitted by both panel roots for exactly this);
#   * the debugger panes, which `Mode-Transitions.md` §7 makes "the primary
#     signal" of which mode a window is in;
#   * the raw Monaco `readOnly` option per editor;
#
# taken through ONE reader before the Run, during the replay, and after the
# return, so the three are comparable values rather than three questions.
#
# WHY THE FORWARD LEG NEEDED ITS OWN GATE.  `noir-replay-in-browser.sh`'s whole
# forward-direction evidence is `!!document.querySelector('#next-image')`, and
# its verdict string smuggles the mode claim into a parenthetical over that one
# boolean — "the debugger's step control is mounted (Run leaves edit mode)".
# Nothing there records what the topbar was BEFORE the Run, so the return-leg
# checks are measured against an unrecorded baseline: a product that never
# entered Debug mode satisfies "no debugger pane is still mounted" trivially.
# Here the baseline is recorded first and asserted.
#
# WHY IT DRIVES THE STOP BUTTON.  `GUI/Debugging-Features/Debugger-Controls.md`
# makes Stop the reverse of Run — "it returns the workspace to Edit mode" — and
# requires it to be reachable by "a toolbar button, a menu entry and a chord".
# All three routes arrived at `renderer.stopAction`, which was `discard`, and
# the button did not exist at all.  So the return leg was reachable only by
# `ctrl+f5`, a chord with no button and no menu entry — which is what the
# sibling gate drives, and why the defect survived it.  This gate presses the
# control a user can SEE.
#
# WHY THREE ROUND TRIPS.  `Mode-Transitions.md` §6: "Edit -> Debug -> Edit ->
# Debug -> ... is unbounded, and the nth transition behaves exactly as the
# first", and "the check needs at least three, because the failure mode is a
# slot that is right once and empty afterwards".
#
# EVERY CLICK IS A REAL POINTER CLICK AT A HIT-TESTED COORDINATE, never
# `el.click()`.  And no assertion here reads `className.includes('disabled')`:
# that is the one fact that cannot tell a live control from a dead one.  The
# controls are PRESSED and the consequence is observed.
#
# Usage:  bash ci/test/noir-mode-roundtrip.sh
# Env:    CT_WEB_BUNDLE_DIR       a tree already assembled by web-bundle-assets.sh
#         CT_REPLAY_ENGINE_DIR    a wasm-pack `pkg/`, when a bundle is assembled here
#         CT_NOIR_WASM_COMPILER   likewise
#         CT_NOIR_WASM_TRACER     likewise
#         CT_NOIR_WASM_REF        provenance; without it the page drops the modules
#         CT_MODE_TRIPS           round trips to drive (default 3)
# Exit:   0 all assertions held, 1 otherwise, 2 could not run.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)"
cd "${repo_root}" || exit 2

# shellcheck source=ci/lib/published-asset.sh
# shellcheck disable=SC1091 # resolved at runtime from $repo_root
source "${repo_root}/ci/lib/published-asset.sh"

trips="${CT_MODE_TRIPS:-3}"

checks=0
failures=0

ck() {
	# ck ok|no MESSAGE
	checks=$((checks + 1))
	if [ "$1" = ok ]; then
		printf '  [OK]     %s\n' "$2"
	else
		printf '  [FAILED] %s\n' "$2"
		failures=$((failures + 1))
	fi
}

note() { printf '      %s\n' "$*"; }

expect_count() {
	## AN ASSERTION THAT DID NOT RUN IS NOT AN ASSERTION THAT PASSED.
	##
	## Taken from `noir-edit-persists.sh`, and named here because the sibling
	## `noir-replay-in-browser.sh` is the one gate of the family WITHOUT it:
	## its arms collapse two checks into one on "the probe did not complete",
	## so its printed total drifts between 22 and 25 and nothing notices.
	local want="$1"
	if [ "${checks}" -ne "${want}" ]; then
		printf '\nRESULT: FAILED — %d assertion(s) ran, %d were written.\n' \
			"${checks}" "${want}"
		printf 'An assertion that did not run is not an assertion that passed.\n'
		exit 1
	fi
}

# ---------------------------------------------------------------------------
# Preconditions — `exit 2`, never a green pass.
# ---------------------------------------------------------------------------
for tool in node python3 jq; do
	command -v "${tool}" >/dev/null 2>&1 || {
		echo "noir-mode-roundtrip.sh: ${tool} is not on PATH." >&2
		exit 2
	}
done
node -e "require('playwright')" >/dev/null 2>&1 || {
	echo "noir-mode-roundtrip.sh: playwright is not installed." >&2
	echo "  remedy: npm install, inside the dev shell" >&2
	exit 2
}

cache="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}/mode-roundtrip"
mkdir -p "${cache}" || exit 2

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

# THE PRECONDITION, CHECKED RATHER THAN ASSUMED. A tree with no compiler and
# no engine would make every arm here vacuously green in the most misleading
# way available: the Run would refuse, the mode would never change, and a
# careless "we are still in edit mode at the end" would pass.
resolved_assets=0
for required in assets/noir_wasm.wasm assets/noir_tracer_wasm.wasm \
	assets/db_backend_bg.wasm assets/db_backend.js assets/replay-worker.js; do
	if ! rel="$(published_asset_rel "${bundle}" "${required}")"; then
		echo "  the assembled tree at ${bundle} ships no ${required}," >&2
		echo "  under that name or a content-addressed one, so a Run could not" >&2
		echo "  reach a replay and this gate would measure nothing." >&2
		echo "  Set CT_NOIR_WASM_COMPILER / CT_NOIR_WASM_TRACER /" >&2
		echo "  CT_REPLAY_ENGINE_DIR / CT_NOIR_WASM_REF and re-assemble." >&2
		exit 2
	fi
	resolved_assets=$((resolved_assets + 1))
	case "${required}" in
	assets/db_backend_bg.wasm) engine_rel="${rel}" ;;
	assets/noir_wasm.wasm) compiler_rel="${rel}" ;;
	esac
done
if [ "${resolved_assets}" -ne 5 ]; then
	echo "  resolved ${resolved_assets} of 5 required assets — the precondition" >&2
	echo "  loop did not run over its subjects" >&2
	exit 2
fi
grep -q 'replay-engine' "${bundle}/index.html" || {
	echo "  the entry document declares no replay-engine module" >&2
	exit 2
}
grep -q 'noir-compiler' "${bundle}/index.html" || {
	echo "  the entry document declares no noir-compiler module" >&2
	exit 2
}

# NAME THE ARTEFACT THIS RUN MEASURED. A verdict that does not say what it was
# measured against is a verdict about nothing in particular.
renderer_rel="$(published_asset_rel "${bundle}" ui.js 2>/dev/null || echo '')"
echo "SUBJECT"
note "bundle:   ${bundle}"
note "engine:   ${engine_rel} ($(wc -c <"${bundle}/${engine_rel}" | tr -d ' ') bytes)"
note "compiler: ${compiler_rel} ($(wc -c <"${bundle}/${compiler_rel}" | tr -d ' ') bytes)"
if [ -n "${renderer_rel}" ]; then
	note "renderer: ${renderer_rel} ($(wc -c <"${bundle}/${renderer_rel}" | tr -d ' ') bytes, sha256 $(shasum -a 256 "${bundle}/${renderer_rel}" | cut -c1-16))"
fi
note "trips:    ${trips}"
echo

# ---------------------------------------------------------------------------
# The static server. `.wasm` as `application/wasm` is load-bearing:
# `WebAssembly.compileStreaming` requires it.
# ---------------------------------------------------------------------------
cp ci/test/noir_build_serve.py "${cache}/serve.py" 2>/dev/null || cat >"${cache}/serve.py" <<'PY'
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
    extensions_map['.js'] = 'text/javascript'

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
[ -s "${cache}/serve.py" ] || {
	echo "  no static server script was written; this gate would serve nothing" >&2
	exit 2
}

server_pid=""
port=""

start_server() {
	local dir="$1"
	rm -f "${cache}/port"
	python3 "${cache}/serve.py" "${dir}" >"${cache}/port" 2>"${cache}/server.log" &
	server_pid=$!
	local waited=0
	while [ ! -s "${cache}/port" ] && [ "${waited}" -lt 150 ]; do
		sleep 0.1
		waited=$((waited + 1))
	done
	port="$(head -1 "${cache}/port" 2>/dev/null | tr -d '[:space:]')"
	[ -n "${port}" ]
}

stop_server() {
	[ -n "${server_pid}" ] && kill "${server_pid}" 2>/dev/null
	wait "${server_pid}" 2>/dev/null
	server_pid=""
}
trap stop_server EXIT

run_probe() {
	local dir="$1" out="$2"
	start_server "${dir}" || {
		echo "  the static server did not start" >&2
		return 1
	}
	# Never trust the exit code; the caller reads the JSON, and a run that
	# produced none is reported as such.
	# THE CAP HAS TO CLEAR THE WORST CASE THE PROBE CAN LEGITIMATELY TAKE.
	# One run now carries the control trips AND the mutation arm, so the cap
	# covers the 420s cold-compile wait once, plus a warm trip per remaining
	# control trip, plus the arm's warm trip, plus the 20s return waits and the
	# settles between them. A cap tuned to the warm case would kill a healthy
	# run whose first compile was slow and report it as "produced no JSON" — a
	# could-not-run dressed as a failure.
	timeout 2400 node ci/test/noir_mode_roundtrip_probe.mjs \
		"http://127.0.0.1:${port}/noir" 60000 "${trips}" 3 \
		>"${out}" 2>"${out}.err"
	stop_server
	[ -s "${out}" ] && jq -e . "${out}" >/dev/null 2>&1
}

field() { jq -r "$2" <"$1"; }

leg() {
	## Read one field out of one leg — and say MISSING when the leg is absent.
	##
	## NOT a bare `first | .field`. jq answers `null | .debugPanesPresent |
	## length` with 0, so a leg the probe never recorded would arrive here as a
	## clean zero and satisfy `-eq 0` — "no debugger pane is mounted" would pass
	## because the SNAPSHOT was missing, not because the panes were. That is the
	## did-not-run/failed conflation this gate is required not to have, and it
	## would land on the side that reads as success.
	##
	## `MISSING` is not a number and not `true`, so every comparison below
	## fails with it, and it prints itself into the verdict line.
	local out
	out="$(jq -r --arg l "$2" \
		"([.legs[] | select(.leg == \$l)] | first) as \$g |
		 if \$g == null then \"MISSING\" else (\$g | $3) end" <"$1" 2>/dev/null)"
	[ -n "${out}" ] && [ "${out}" != "null" ] && printf '%s' "${out}" || printf 'MISSING'
}

num() {
	## A numeric reading, or -1 when it was not a number. Keeps `[ x -gt 0 ]`
	## from erroring out of the script on a MISSING and taking the tally with it.
	case "$1" in
	'' | *[!0-9]*) printf '%s' -1 ;;
	*) printf '%s' "$1" ;;
	esac
}

# ---------------------------------------------------------------------------
echo "THE CONTROL — ${trips} round trips through the mode switch"
# ---------------------------------------------------------------------------
control="${cache}/control.json"
if ! run_probe "${bundle}" "${control}"; then
	echo "  the probe produced no readable JSON; see ${control}.err" >&2
	tail -20 "${control}.err" >&2
	exit 2
fi

fatal="$(field "${control}" '.fatal')"
[ -z "${fatal}" ] || note "fatal: ${fatal}"

mounted="$(field "${control}" '.mounted')"
ck "$([ "${mounted}" = true ] && echo ok || echo no)" "the renderer mounted"

# --- Leg 0: the EDIT baseline. Recorded, not assumed. --------------------
e_surface="$(leg "${control}" edit-initial '.topbarSurface')"
e_buttons="$(leg "${control}" edit-initial '.buttonIds | join(",")')"
e_count="$(leg "${control}" edit-initial '.editToolbarButtonCount')"
e_panes="$(num "$(leg "${control}" edit-initial '.debugPanesPresent | length')")"
e_editable="$(leg "${control}" edit-initial '.anyEditable')"
e_hasapi="$(leg "${control}" edit-initial '.hasGetEditors')"
e_children="$(leg "${control}" edit-initial '.hostChildren | join(",")')"

note "edit baseline surface=${e_surface} buttons=[${e_buttons}] data-button-count=${e_count}"
note "edit baseline host children: ${e_children}"

# THE INSTRUMENT FIRST. Without `getEditors` the read-only questions below
# cannot be asked at all, and "no editable editor" would be indistinguishable
# from "no way to ask" — the false-negative shape that once had a probe
# reporting an unmounted toolbar that was on screen the whole time.
ck "$([ "${e_hasapi}" = true ] && echo ok || echo no)" \
	"monaco.editor.getEditors exists, so the read-only readings below mean something"
ck "$([ "${e_surface}" = "edit-commands" ] && echo ok || echo no)" \
	"the tab starts on the EDIT topbar (data-topbar-surface=${e_surface})"
ck "$([ "${e_panes}" -eq 0 ] && echo ok || echo no)" \
	"and no debugger pane is mounted in edit mode (${e_panes})"
ck "$([ "${e_editable}" = true ] && echo ok || echo no)" \
	"and an editor is writable"

# EMT-D12: Build and Run are PRESENT in Edit mode.
e_run="$(leg "${control}" edit-initial '.runButtonPresent')"
e_stop="$(leg "${control}" edit-initial '.stopButtonPresent')"
ck "$([ "${e_run}" = true ] && echo ok || echo no)" \
	"the edit toolbar carries Run (#run-image) — there is a gesture to measure"
# The negative half of the baseline. Without it, "Stop appeared in replay
# mode" is satisfied by a Stop that was always there.
ck "$([ "${e_stop}" = false ] && echo ok || echo no)" \
	"and NOT Stop — a session has to exist before it can be left"

marker_reached="$(field "${control}" '.markerReachedModel')"
ck "$([ "${marker_reached}" = true ] && echo ok || echo no)" \
	"the user's edit reached the editor's model before any Run (so the round-trip checks below are not comparing two absences)"

# --- Per-trip: the transition, both ways. -------------------------------
trip=1
while [ "${trip}" -le "${trips}" ]; do
	r_reached="$(leg "${control}" "trip-${trip}-run-wait" '.reached')"
	r_waited="$(leg "${control}" "trip-${trip}-run-wait" '.waitedMs')"
	# `clicked` AND `clickEventFired`, because the first alone is the false
	# positive that hid this gate's real failure for three runs: it says only
	# that `page.mouse.click` did not throw. A browser produces NO click event
	# when `mousedown` and `mouseup` land on different nodes, which is what a
	# topbar re-mount does to a gesture aimed at it.
	r_clicked="$(leg "${control}" "trip-${trip}-run-gesture" '(.gesture.clicked and .gesture.clickEventFired)')"
	r_reaches="$(leg "${control}" "trip-${trip}-run-gesture" '.gesture.reaches')"
	r_top="$(leg "${control}" "trip-${trip}-run-gesture" '.gesture.topAtPoint')"

	d_surface="$(leg "${control}" "trip-${trip}-replay" '.topbarSurface')"
	d_panes="$(leg "${control}" "trip-${trip}-replay" '.debugPanesPresent | join(",")')"
	d_panecount="$(num "$(leg "${control}" "trip-${trip}-replay" '.debugPanesPresent | length')")"
	d_ro="$(leg "${control}" "trip-${trip}-replay" '.allReadOnly')"
	d_stop="$(leg "${control}" "trip-${trip}-replay" '.stopButtonPresent')"
	d_step="$(leg "${control}" "trip-${trip}-replay" '.stepButtonPresent')"
	d_build="$(leg "${control}" "trip-${trip}-replay" '.buildButtonPresent')"
	d_carets="$(num "$(leg "${control}" "trip-${trip}-step" '.caretPositions | length')")"

	s_before="$(leg "${control}" "trip-${trip}-stop-gesture" '.surfaceBefore')"
	s_clicked="$(leg "${control}" "trip-${trip}-stop-gesture" '(.gesture.clicked and .gesture.clickEventFired)')"
	s_reaches="$(leg "${control}" "trip-${trip}-stop-gesture" '.gesture.reaches')"
	s_top="$(leg "${control}" "trip-${trip}-stop-gesture" '.gesture.topAtPoint')"
	b_reached="$(leg "${control}" "trip-${trip}-stop-wait" '.reached')"
	b_waited="$(leg "${control}" "trip-${trip}-stop-wait" '.waitedMs')"

	f_surface="$(leg "${control}" "trip-${trip}-edit" '.topbarSurface')"
	f_panes="$(num "$(leg "${control}" "trip-${trip}-edit" '.debugPanesPresent | length')")"
	f_editable="$(leg "${control}" "trip-${trip}-edit" '.anyEditable')"
	f_run="$(leg "${control}" "trip-${trip}-edit" '.runButtonPresent')"
	m_present="$(jq -r --argjson t "${trip}" \
		'[.markerPresentPerLeg[] | select(.trip == $t)] | first | .present' <"${control}")"

	echo
	echo "  trip ${trip}"
	note "Run pressed at a point that reaches it: ${r_reaches} (top element there: ${r_top})"
	note "replay surface=${d_surface} panes=[${d_panes}] after ${r_waited}ms"
	note "Stop pressed at a point that reaches it: ${s_reaches} (top element there: ${s_top})"
	note "returned surface=${f_surface} after ${b_waited}ms"

	# FORWARD: edit -> replay.
	ck "$([ "${r_clicked}" = true ] && echo ok || echo no)" \
		"trip ${trip}: the Run button took a real pointer click at a hit-tested point AND the browser produced a click event"
	ck "$([ "${r_reached}" = true ] && echo ok || echo no)" \
		"trip ${trip}: and the topbar became the DEBUGGER surface (${d_surface}) — the mode changed, ${r_waited}ms"
	ck "$([ "${d_panecount}" -gt 0 ] && echo ok || echo no)" \
		"trip ${trip}: and the debugger panes are mounted (${d_panecount}: ${d_panes}) — the LAYOUT changed, not only the toolbar"
	ck "$([ "${d_ro}" = true ] && echo ok || echo no)" \
		"trip ${trip}: and every editor went read-only — a replay is not editable"
	# EMT-D12: Build and Run are ABSENT in Debug mode, not merely disabled.
	ck "$([ "${d_build}" = false ] && echo ok || echo no)" \
		"trip ${trip}: and Build is GONE from the topbar (EMT-D12: rebuilding under a live replay invalidates its trace)"
	ck "$([ "${d_step}" = true ] && echo ok || echo no)" \
		"trip ${trip}: and the stepping controls are there"
	ck "$([ "${d_carets}" -gt 1 ] && echo ok || echo no)" \
		"trip ${trip}: stepping moved the painted caret through ${d_carets} position(s) — a live session, not a painted one"

	# THE CONTROL THIS CAMPAIGN ADDED.
	ck "$([ "${d_stop}" = true ] && echo ok || echo no)" \
		"trip ${trip}: and STOP is on the topbar — the way out is visible, not only bound to a chord"

	# RETURN: replay -> edit, by the button.
	ck "$([ "${s_clicked}" = true ] && echo ok || echo no)" \
		"trip ${trip}: Stop took a real pointer click at a hit-tested point AND the browser produced a click event"
	# A TRANSITION ASSERTION NAMES THE SURFACE IT CAME FROM.
	#
	# `b_reached` alone is a false pass with a convincing shape, and this gate
	# printed it on its own first run: on a trip whose Run never entered Debug
	# mode the tab is still on `edit-commands`, the wait returns `reached: true`
	# on its first poll, and the line read "pressing Stop MOVED the mode ...
	# 0ms" — a return that never left, scored as a working return. So the
	# BEFORE surface is asserted too, and a return only counts when the tab was
	# actually in the debugger to begin with.
	ck "$([ "${s_before}" = "debugger-controls" ] && [ "${b_reached}" = true ] &&
		echo ok || echo no)" \
		"trip ${trip}: and the topbar went ${s_before} -> ${f_surface} — pressing Stop MOVED the mode, ${b_waited}ms"
	ck "$([ "${f_panes}" -eq 0 ] && echo ok || echo no)" \
		"trip ${trip}: and no debugger pane is still mounted (${f_panes}) — the edit layout came back"
	ck "$([ "${f_editable}" = true ] && echo ok || echo no)" \
		"trip ${trip}: and the editors are writable again — switchToEdit ran, not just the mode flag"
	ck "$([ "${f_run}" = true ] && echo ok || echo no)" \
		"trip ${trip}: and Run is back on the topbar, so the next trip has a gesture"
	ck "$([ "${m_present}" = true ] && echo ok || echo no)" \
		"trip ${trip}: and the user's edit is STILL THERE"

	trip=$((trip + 1))
done

echo
errors="$(field "${control}" '.pageErrors | length')"
if [ "${errors}" -ne 0 ]; then
	note "page errors:"
	jq -r '.pageErrors[] | "        " + .' <"${control}" | head -8
fi
ck "$([ "${errors}" -eq 0 ] && echo ok || echo no)" \
	"zero uncaught page errors across ${trips} round trips and the mutation arm (${errors})"

gesture_errors="$(field "${control}" '.gestureErrors | length')"
if [ "${gesture_errors}" -ne 0 ]; then
	note "gesture errors:"
	jq -r '.gestureErrors[] | "        " + (.what // "?") + ": " + (.error // "?")' \
		<"${control}" | head -8
fi

# ---------------------------------------------------------------------------
# MUTATION ARM — prove the transition assertions CAN fail.
#
# A check that cannot fail is worse than no check, because it certifies the
# defect.  The arm re-creates the product as it was before this campaign: a
# Stop that is present, hit-testable, and whose click reaches nothing.
#
# THE ARM RUNS IN THE CONTROL'S OWN TAB, and that is the whole reason it can
# be shown to work.  It used to be a copy of the bundle with a `<script>`
# injected into `index.html`, driven by a SECOND browser launch — and a second
# launch pays the cold Noir/wasm compile again.  Measured on this gate's own
# runs, that arm's single trip never got past the compile wall, so all three
# of its checks reported "the arm did not complete" and the redness the arm
# exists to demonstrate was never demonstrated at all.  The proof was owed and
# unpaid: the return assertions had never been observed to fail.
#
# Driven from inside the probe, after the control trips, the arm is WARM by
# construction — same tab, same worker, same compiled modules — and it is a
# strictly smaller mutation, because nothing on disk differs between control
# and arm.  The only variable is the Stop button's click handler.
#
# The shape is otherwise unchanged, and it is the one `noir-replay-in-browser
# .sh`'s arm C uses: mutate, VERIFY THE MUTATION LANDED, assert the arm broke
# only its target, then assert the named check went red.
# ---------------------------------------------------------------------------
echo
echo "MUTATION ARM — a Stop that does nothing, which is what shipped"
echo "    Reddens the RETURN assertions and only those. 'Pressing Stop moved"
echo "    the mode' is a claim about a product that could fail to, and until"
echo "    this campaign it did: renderer.stopAction was \`discard\`."

arm_installed="$(field "${control}" '.armInstalled')"
arm_swallowed="$(num "$(field "${control}" '.armSwallowedClicks')")"
a_run_reached="$(leg "${control}" 'arm-run-wait' '.reached')"
a_stop_clicked="$(leg "${control}" 'arm-stop-gesture' '.gesture.clicked')"
a_back="$(leg "${control}" 'arm-stop-wait' '.reached')"
a_surface="$(leg "${control}" 'arm-edit' '.topbarSurface')"

note "arm instrument installed=${arm_installed}, clicks it swallowed=${arm_swallowed}"

# THE MUTATION LANDED, CHECKED RATHER THAN ASSUMED. An instrument that never
# attached produces the same red return as a Stop that never reached its
# handler, and only one of those is evidence about the assertion.
ck "$([ "${arm_installed}" = true ] && [ "${arm_swallowed}" -ge 1 ] &&
	echo ok || echo no)" \
	"arm: the instrument attached and swallowed the Stop click (${arm_swallowed}) — the arm mutated its target"
# THE ARM BREAKS ONE THING. If the Run leg or the click itself broke too, the
# red below would not be evidence that the return assertion works — it would be
# evidence that the arm broke the probe.
ck "$([ "${a_run_reached}" = true ] && echo ok || echo no)" \
	"arm: the FORWARD leg still worked (the arm breaks the RETURN, not the Run)"
ck "$([ "${a_stop_clicked}" = true ] && echo ok || echo no)" \
	"arm: the Stop button was still pressed (the arm kills the handler, not the button)"
ck "$([ "${a_back}" = false ] && echo ok || echo no)" \
	"arm: and the mode did NOT return to edit (surface stayed ${a_surface}) — 'pressing Stop moved the mode' can fail"

# ---------------------------------------------------------------------------
echo
echo "${checks} check(s), ${failures} failure(s)"
# 8 baseline + 14 per trip + 1 page-errors + 4 arm
expect_count $((8 + 14 * trips + 1 + 4))
if [ "${failures}" -eq 0 ]; then
	echo "RESULT: OK — Run enters the debugger, Stop comes back, ${trips} times, and the edit survives"
	exit 0
fi
echo "RESULT: FAILED — ${failures} check(s)"
exit 1
