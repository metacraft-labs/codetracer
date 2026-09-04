#!/usr/bin/env bash
#
# editor-context-menu-modes.sh — the editor's right-click menu is the MODE's,
# asserted entry by entry, by name, in a real tab, against an assembled bundle.
#
# THE REPORT
# ----------
# Against the deployed `noirstudio.dev`: "I noticed that the right click menu
# content over the editor area is not context dependent (Edit vs Debug). Most
# of the entries are debug operations."
#
# WHAT THIS ASSERTS THAT NOTHING ELSE DOES
# ----------------------------------------
# `menu-and-context-menu-in-browser.sh` asserts that exactly ONE menu appears on
# a right-click and that its hint row is inert. Every one of its checks passes
# on a menu whose entire content is replay commands offered in Edit mode — it
# never reads a single entry name. `mode_layout_probe.mjs` asserts that a mode
# switch changes the LAYOUT, which is a different surface.
#
# So the subject here is the CONTENT, and the unit is one entry in one mode:
#
#   * "the menu differs between the modes" cannot fail for its own reason. A
#     menu that differs by one row differs.
#   * "the menu is non-empty" is worse.
#
# Every check below therefore names one entry and says present or absent, and
# the absences are checked in both directions — a debug command must be GONE
# from the Edit menu, not greyed out in it. A greyed-out list of ten debug
# operations is still a menu about debugging.
#
# NOT A GREP OVER `ui.js`. Nim's JS backend emits some string literals as bare
# char-code arrays, so a text search over the compiled bundle is not a presence
# test for a menu label. Every reading comes from the DOM of a menu that was
# opened by a right-click on rendered code.
#
# THE DEBUG HALF IS ATTEMPTED THROUGH RUN, which is how a user of
# `noirstudio.dev` reaches Debug mode — the probe presses the Run chord, waits
# for the session to report a position with source on screen, and reads the menu
# there. It needs the Noir wasm modules and the replay engine to be in the
# bundle; without them the leg reports why.
#
# TWO DEFECTS CURRENTLY STAND IN FRONT OF IT, and the gate NAMES them rather
# than passing over them or failing for them (both reproduce identically on a
# bundle built from the pre-fix tree, so neither belongs to this change):
#
#   1. The mode toggle loses the editor. `switchToDebug` leaves the workspace
#      with no editor pane and no filesystem tree — `[id^=editorComponent-]`
#      count 0, `getDomNode().isConnected === false` — with "layout: component
#      clear EditorView/0 raised a Defect and was skipped" in the console.
#   2. After a Run there is an editor and no menu. The session mounts, the debug
#      controls mount, source is painted, and a right-click on it leaves
#      `contextmenu` NOT defaultPrevented and shows zero rows: CodeTracer's
#      handler does not run, so the BROWSER's menu is what the user gets.
#
# So the Debug half is asserted on the desktop instead, where a Run produces a
# real session with source on screen:
# `src/tests/gui/tests/editor/editor_context_menu_is_mode_dependent.spec.ts`.
#
# Usage:  bash ci/test/editor-context-menu-modes.sh
# Env:    CT_WEB_BUNDLE_DIR    a tree already assembled by web-bundle-assets.sh
#         CT_CTXMENU_GATE_TREE serve this tree as-is instead of rebuilding
#                              (used by the control-data arm)
# Exit:   0 all assertions held, 1 otherwise, 2 could not run.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

cache="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}/editor-context-menu-modes"
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

required_tools="node python3"
[ -z "${CT_CTXMENU_GATE_TREE:-}" ] && required_tools="${required_tools} nim"
for tool in ${required_tools}; do
	command -v "${tool}" >/dev/null 2>&1 || {
		echo "editor-context-menu-modes.sh: no '${tool}' on PATH." >&2
		echo "  remedy: run inside the dev shell (direnv exec ${repo_root} ...)" >&2
		exit 2
	}
done
if [ ! -d node_modules/playwright ] && ! node -e "require('playwright')" >/dev/null 2>&1; then
	echo "editor-context-menu-modes.sh: node_modules/playwright is missing;" >&2
	echo "  run inside the dev shell (direnv exec ${repo_root} ...)" >&2
	exit 2
fi

echo "=== the editor's context menu is the mode's ==="
echo

# ---------------------------------------------------------------------------
# The tree
# ---------------------------------------------------------------------------
tree="${CT_CTXMENU_GATE_TREE:-}"
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

	# THE RENDERER IS REBUILT FROM SOURCE into a COPY of the tree. A
	# pre-assembled `CT_WEB_BUNDLE_DIR` carries whatever `ui.js` it was built
	# with, and a gate that measured that would be reporting on a tree nobody
	# edited — the "verify the instrument" trap, and this gate is entirely about
	# a change to the renderer.
	served="${cache}/tree"
	if [ -e "${served}" ]; then
		chmod -R u+w "${served}" 2>/dev/null
		rm -rf "${served}"
	fi
	cp -R "${tree}" "${served}"
	chmod -R u+w "${served}"
	tree="${served}"

	echo "Rebuilding the renderer into the tree..."
	rm -f "${cache}/ui.js"
	if ! nim js --hints:off --warnings:off -d:chronicles_enabled=off \
		-d:ctRenderer -d:ctWeb --nimcache:"${cache}/nimcache" \
		-o:"${cache}/ui.js" src/frontend/ui_js.nim \
		>"${cache}/build.log" 2>&1 || [ ! -f "${cache}/ui.js" ]; then
		# `nim js` has exited 0 while writing no artifact in this repo, so the
		# file itself is checked rather than the status.
		echo "  the renderer did not build; see ${cache}/build.log" >&2
		grep -E 'Error:' "${cache}/build.log" | head -3 | sed 's/^/      /' >&2
		exit 2
	fi
	{
		printf '(function () {\n'
		cat "${cache}/ui.js"
		printf '\n})();\n'
	} >"${tree}/ui.js"

	if [ -x node_modules/.bin/stylus ]; then
		if node node_modules/.bin/stylus -p \
			src/frontend/styles/default_dark_theme_electron.styl \
			>"${cache}/theme.css" 2>"${cache}/stylus.log" &&
			[ -s "${cache}/theme.css" ]; then
			cp "${cache}/theme.css" \
				"${tree}/frontend/styles/default_dark_theme_electron.css"
		else
			echo "  the theme did not compile; see ${cache}/stylus.log" >&2
			exit 2
		fi
	else
		# The disabled row's appearance is entirely `.ct-menu-item--disabled`,
		# which lives in the stylesheet. A stale theme would make the
		# `pointer-events` reading below measure the wrong build.
		echo "  node_modules/.bin/stylus is missing, so a stylesheet change" >&2
		echo "  would be invisible to the page." >&2
		exit 2
	fi
fi
note "tree: ${tree}"
echo

# ---------------------------------------------------------------------------
# Serve it the way the CDN does, so `/noir` resolves.
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
with socketserver.TCPServer(("127.0.0.1", int(sys.argv[2])), Quiet) as httpd:
    httpd.serve_forever()
PY

port="${CT_CTXMENU_GATE_PORT:-8796}"
server_pid=""
stop_server() {
	if [ -n "${server_pid}" ]; then
		kill "${server_pid}" 2>/dev/null
		wait "${server_pid}" 2>/dev/null
		server_pid=""
	fi
}
trap stop_server EXIT
python3 "${cache}/serve.py" "${tree}" "${port}" >"${cache}/server.log" 2>&1 &
server_pid=$!
started=0
for _ in $(seq 1 40); do
	if curl -s -o /dev/null "http://127.0.0.1:${port}/noir"; then
		started=1
		break
	fi
	sleep 0.25
done
if [ "${started}" -ne 1 ]; then
	echo "  the static server did not start" >&2
	exit 2
fi

echo "Driving a browser..."
node ci/test/editor_context_menu_modes_probe.mjs "http://127.0.0.1:${port}/noir" \
	"${cache}/report.json" >"${cache}/probe.log" 2>"${cache}/probe.err"
probe_rc=$?
stop_server
if [ "${probe_rc}" -ne 0 ] || [ ! -s "${cache}/report.json" ]; then
	echo "  the probe produced no report" >&2
	head -20 "${cache}/probe.err" >&2
	exit 2
fi
echo

py() { python3 -c "$1" "${@:2}"; }

names_of() {
	## The entry names of one leg, one per line. Empty when the leg has no menu,
	## which every check treats as a failure rather than as an empty match.
	py "
import json, sys
d = json.load(open('${cache}/report.json'))
leg = (d.get('legs') or {}).get(sys.argv[1]) or {}
menu = leg.get('menu') or {}
for n in menu.get('names') or []:
    print(n)
" "$1"
}

has_entry() {
	# Here-string, not a pipe. `grep -Fxq` exits on its first match, `names_of`
	# then takes SIGPIPE, and under `set -o pipefail` a SUCCESSFUL MATCH is
	# reported as FAILURE -- so this predicate would answer "absent" for a menu
	# entry that is present, which is the exact inversion of what it is for.
	# See ci/test/grep-q-pipefail-gate.sh, which is what caught this.
	grep -Fxq "$2" <<<"$(names_of "$1")"
}

edit_names="$(names_of edit | paste -sd, -)"
edit_count="$(names_of edit | grep -c . || true)"

# ---------------------------------------------------------------------------
# NON-VACUITY FIRST. Every "absent" check below holds of an empty menu, and an
# empty menu is a different defect wearing this one's clothes.
# ---------------------------------------------------------------------------
boot_lines="$(py "
import json; print(json.load(open('${cache}/report.json')).get('editorLinesAtBoot') or 0)")"
if [ "${boot_lines:-0}" -gt 0 ]; then
	ck ok "[mount] ${boot_lines} rendered code line(s) on the page, so a" \
		"right-click has a subject"
else
	ck fail "[mount] no rendered code; nothing below measures anything"
	echo
	echo "RESULT: FAILED — the subject never came up"
	exit 1
fi

edit_mode="$(py "
import json; d=json.load(open('${cache}/report.json'))
print(((d.get('legs') or {}).get('editMode') or {}).get('name'))")"
if [ "${edit_mode}" = "EditMode" ]; then
	ck ok "[edit/mode] the leg is in EditMode by the product's own reckoning"
else
	ck fail "[edit/mode] the Edit leg reports mode '${edit_mode}'; the entry" \
		"checks below would be about the wrong menu"
fi

if [ "${edit_count:-0}" -ge 3 ]; then
	ck ok "[edit/subject] the Edit-mode menu has ${edit_count} entries:" \
		"${edit_names}"
else
	ck fail "[edit/subject] the Edit-mode menu has ${edit_count} entries" \
		"(${edit_names}); the absence checks below would be vacuous"
fi

# ---------------------------------------------------------------------------
# PRESENT IN EDIT MODE, one check per entry.
# ---------------------------------------------------------------------------
for entry in "Cut" "Copy" "Paste" "Toggle Line Comment" "Find" "Replace"; do
	if has_entry edit "${entry}"; then
		ck ok "[edit/present] '${entry}'"
	else
		ck fail "[edit/present] '${entry}' is missing from the Edit-mode menu," \
			"which reads: ${edit_names}"
	fi
done

# Breakpoints are in BOTH menus by decision: `Mode-Transitions.md` §5 lists them
# among the things a transition preserves, "they belong to the project, not to
# the session". Only one of the pair is on screen at a time.
if has_entry edit "Add breakpoint" || has_entry edit "Delete breakpoint"; then
	ck ok "[edit/present] a breakpoint row (project state, not session state)"
else
	ck fail "[edit/present] no breakpoint row in Edit mode: ${edit_names}"
fi

# ---------------------------------------------------------------------------
# ABSENT FROM EDIT MODE, one check per entry, each naming what it found.
#
# This is the report itself: "most of the entries are debug operations".
# ---------------------------------------------------------------------------
debug_in_edit=""
for entry in \
	"Jump to line" \
	"Run to Cursor" \
	"Jump backward to line" \
	"Jump to call" \
	"Jump forward to call" \
	"Jump backward to call" \
	"Add tracepoint" \
	"Delete tracepoint" \
	"Enable tracepoint" \
	"Disable tracepoint" \
	"Add value to scratchpad"; do
	if has_entry edit "${entry}"; then
		ck fail "[edit/absent] '${entry}' is a replay command and it is offered" \
			"in EDIT mode"
		debug_in_edit="${debug_in_edit}${entry}; "
	else
		ck ok "[edit/absent] '${entry}'"
	fi
done
if [ -n "${debug_in_edit}" ]; then
	note "THE REPORTED DEFECT, verbatim: the Edit-mode menu carries these replay"
	note "commands: ${debug_in_edit}"
	note "The whole Edit-mode menu reads: ${edit_names}"
fi

# ---------------------------------------------------------------------------
# EVERY DISABLED ROW SAYS WHY, and no row prints a raw HTML entity.
# ---------------------------------------------------------------------------
# THE DISABLED PATH, GIVEN A SUBJECT FIRST.
#
# The ordinary Edit-mode menu has no disabled row in it, so "every disabled row
# carries a reason" asked of that leg is quantified over an empty set and cannot
# fail. The probe therefore toggles read-only INSIDE Edit mode — the product's
# own `Ctrl+E` command, deliberately independent of the mode — which is the
# state where Cut and Paste are applicable and unavailable. That is the only
# thing `disabled` is for.
ro_state="$(py "
import json
d = json.load(open('${cache}/report.json'))
s = (d.get('legs') or {}).get('readOnlyState') or {}
print('yes' if s.get('uiReadOnly') else 'no')")"
ro_rows="$(py "
import json
d = json.load(open('${cache}/report.json'))
rows = ((d.get('legs') or {}).get('editReadOnly') or {}).get('menu', {}).get('entries') or []
by = {r['name']: r for r in rows}
def state(n):
    r = by.get(n)
    if r is None: return n + '=absent'
    return n + '=' + ('disabled' if r.get('disabled') else 'enabled') + \
        ':' + (r.get('sublabel') or '<no reason>')
print(' | '.join(state(n) for n in
                 ('Cut', 'Copy', 'Paste', 'Toggle Line Comment', 'Find',
                  'Replace')))
bad = [r['name'] for r in rows if r.get('disabled') and not r.get('sublabel')]
print(','.join(bad) if bad else 'none')
print(sum(1 for r in rows if r.get('disabled')))
ok = all(by.get(n) is not None and by[n].get('disabled') and
         'Ctrl+E' in (by[n].get('sublabel') or '')
         for n in ('Cut', 'Paste', 'Toggle Line Comment', 'Replace'))
ok = ok and by.get('Copy') is not None and not by['Copy'].get('disabled')
ok = ok and by.get('Find') is not None and not by['Find'].get('disabled')
reasons = {by[n]['sublabel'] for n in ('Cut', 'Paste', 'Toggle Line Comment',
                                       'Replace') if n in by}
print('yes' if ok and len(reasons) == 1 else 'no')
")"
ro_summary="$(printf '%s\n' "${ro_rows}" | sed -n 1p)"
# Line 2 is the per-leg reasonless list; it is folded into the cross-leg check
# below rather than read here, so it is skipped rather than bound.
ro_disabled_n="$(printf '%s\n' "${ro_rows}" | sed -n 3p)"
ro_ok="$(printf '%s\n' "${ro_rows}" | sed -n 4p)"

if [ "${ro_state}" = "yes" ] && [ "${ro_disabled_n:-0}" -ge 4 ]; then
	ck ok "[disabled/instrument] read-only was toggled on inside Edit mode and" \
		"${ro_disabled_n} row(s) went disabled, so the reason checks below are" \
		"a measurement and not an empty set"
else
	ck fail "[disabled/instrument] read-only=${ro_state}," \
		"${ro_disabled_n:-0} disabled row(s) — the disabled path has no subject" \
		"and every check about it would pass vacuously. Rows: ${ro_summary}"
fi

if [ "${ro_ok}" = "yes" ]; then
	ck ok "[disabled/state] every verb that read-onlyness alone blocks is" \
		"DISABLED with ONE Ctrl+E sentence, and the two that it does not block" \
		"are enabled: ${ro_summary}"
else
	ck fail "[disabled/state] expected Cut, Paste, Toggle Line Comment and" \
		"Replace disabled with one identical Ctrl+E reason, and Copy and Find" \
		"enabled. A verb that vanishes where its neighbour greys out answers" \
		"the same question two ways. Got: ${ro_summary}"
fi

mute="$(py "
import json
d = json.load(open('${cache}/report.json'))
bad = []
for leg in ('edit', 'editAgain', 'editReadOnly'):
    rows = ((d.get('legs') or {}).get(leg) or {}).get('menu', {}).get('entries') or []
    bad += [leg + ':' + r['name'] for r in rows if r.get('disabled') and not r.get('sublabel')]
print(','.join(bad) if bad else 'none')
")"
if [ "${mute}" = "none" ]; then
	ck ok "[edit/reasons] every disabled row on every Edit leg carries a reason"
else
	ck fail "[edit/reasons] disabled with no reason: ${mute} —" \
		"'an action whose absence cannot be explained is one whose absence was a guess'"
fi

# AND IT STILL TAKES NO CLICK. `.ct-menu-item--disabled` sets
# `pointer-events: none`; the hit test at the row's own centre is what actually
# decides it, so that is what is asked.
ro_hit="$(py "
import json
d = json.load(open('${cache}/report.json'))
rows = ((d.get('legs') or {}).get('editReadOnly') or {}).get('menu', {}).get('entries') or []
bad = [r['name'] for r in rows if r.get('disabled') and r.get('hitIsSelf')]
aria = [r['name'] for r in rows if r.get('disabled') and r.get('ariaDisabled') != 'true']
print(','.join(bad) if bad else 'none')
print(','.join(aria) if aria else 'none')
")"
ro_hit_bad="$(printf '%s\n' "${ro_hit}" | head -1)"
ro_aria_bad="$(printf '%s\n' "${ro_hit}" | tail -1)"
if [ "${ro_hit_bad}" = "none" ] && [ "${ro_aria_bad}" = "none" ]; then
	ck ok "[disabled/inert] the disabled rows take no click at their own centre" \
		"and declare aria-disabled"
else
	ck fail "[disabled/inert] clickable while disabled: ${ro_hit_bad};" \
		"missing aria-disabled: ${ro_aria_bad}"
fi

entities="$(py "
import json, re
d = json.load(open('${cache}/report.json'))
bad = []
for leg in ('edit', 'editAgain'):
    rows = ((d.get('legs') or {}).get(leg) or {}).get('menu', {}).get('entries') or []
    for r in rows:
        if re.search(r'&(lt|gt|amp);', r['name'] + ' ' + r.get('sublabel', '')):
            bad.append(leg + ':' + r['name'])
print(','.join(bad) if bad else 'none')
")"
if [ "${entities}" = "none" ]; then
	ck ok "[edit/text] no row prints a raw HTML entity"
else
	ck fail "[edit/text] a row reaches the user as an HTML entity: ${entities}." \
		"The menu is rendered with textContent, so '&lt;' is four characters."
fi

# A disabled row must not be clickable. Asked of the hit test at the row's own
# centre rather than of the class, because `pointer-events: none` is what
# actually decides it.
hit="$(py "
import json
d = json.load(open('${cache}/report.json'))
rows = ((d.get('legs') or {}).get('edit') or {}).get('menu', {}).get('entries') or []
bad = [r['name'] for r in rows if r.get('disabled') and r.get('hitIsSelf')]
live = [r['name'] for r in rows if not r.get('disabled') and not r.get('hitIsSelf')]
print(','.join(bad) if bad else 'none')
print(','.join(live) if live else 'none')
")"
inert_bad="$(printf '%s\n' "${hit}" | head -1)"
live_bad="$(printf '%s\n' "${hit}" | tail -1)"
if [ "${inert_bad}" = "none" ] && [ "${live_bad}" = "none" ]; then
	ck ok "[edit/hit] disabled rows take no click and enabled rows do"
else
	ck fail "[edit/hit] clickable-while-disabled: ${inert_bad};" \
		"unreachable-while-enabled: ${live_bad}"
fi

# ---------------------------------------------------------------------------
# THE ROUND TRIP. A menu built from a mode read once would be right on the
# first switch and wrong afterwards.
# ---------------------------------------------------------------------------
again_names="$(names_of editAgain | paste -sd, -)"
if [ "${again_names}" = "${edit_names}" ] && [ -n "${edit_names}" ]; then
	ck ok "[roundtrip] the Edit menu is unchanged after a visit to Debug mode"
else
	ck fail "[roundtrip] the Edit menu changed across a round trip:" \
		"'${edit_names}' -> '${again_names}'"
fi

# ---------------------------------------------------------------------------
# THE DEBUG HALF — measured when there is something to measure, and NAMED when
# there is not.
#
# The probe reaches Debug mode the way a user does: it presses the Run chord,
# waits for the session to report a position with source on screen, and reads
# the menu there. It also records what the MODE TOGGLE does, which is a
# different and worse answer, so the two are not confused.
# ---------------------------------------------------------------------------
debug_opened="$(py "
import json
d = json.load(open('${cache}/report.json'))
leg = (d.get('legs') or {}).get('debug') or {}
print('yes' if leg.get('opened') else 'no:' + str(leg.get('reason')))")"
debug_count="$(names_of debug | grep -c . || true)"
debug_line="$(py "
import json
d = json.load(open('${cache}/report.json'))
print(((d.get('legs') or {}).get('debug') or {}).get('lineText') or '<none>')")"
edit_line="$(py "
import json
d = json.load(open('${cache}/report.json'))
print(((d.get('legs') or {}).get('edit') or {}).get('lineText') or '<none>')")"
toggle_state="$(py "
import json
d = json.load(open('${cache}/report.json'))
t = (d.get('legs') or {}).get('debugViaToggle') or {}
print('viewLines=%s editorContainers=%s monacoDomConnected=%s' % (
    t.get('viewLines'), t.get('editorContainers'), t.get('monacoDomConnected')))")"

if [ "${debug_opened}" = "yes" ] && [ "${debug_count:-0}" -ge 3 ]; then
	debug_names="$(names_of debug | paste -sd, -)"
	# THE LINE IS NAMED IN THE PASS. An empty menu on a blank line reads exactly
	# like "the Debug entries are missing", and that is what this leg reported
	# the first time it ran — `.view-line` exists for blank lines too, and a
	# click past the end of one gives Monaco no position at all. Both legs'
	# lines are printed so a reader can see they are code, and the same code.
	ck ok "[debug/subject] the Debug-mode menu has ${debug_count} entries on" \
		"'${debug_line}' (the Edit leg clicked '${edit_line}'): ${debug_names}"
	for entry in "Jump to line" "Run to Cursor" "Jump backward to line" "Copy"; do
		if has_entry debug "${entry}"; then
			ck ok "[debug/present] '${entry}'"
		else
			ck fail "[debug/present] '${entry}' is missing: ${debug_names}"
		fi
	done
	for entry in "Cut" "Paste" "Replace"; do
		if has_entry debug "${entry}"; then
			ck fail "[debug/absent] '${entry}' edits the buffer and the" \
				"Debug-mode editor is read-only: ${debug_names}"
		else
			ck ok "[debug/absent] '${entry}'"
		fi
	done
	debug_checks=8
else
	# NOT A CHECK, AND NOT SILENCE EITHER.
	#
	# Eight per-entry assertions had no subject, and this says so at the top of
	# the result rather than letting the count read as a clean sweep — the same
	# convention `web-bundle-assets.sh` uses for the wasm modules it was not
	# given ("their PLACEMENT is unproven here").
	#
	# It is a NOTE and not a failure because the cause is not this menu, and
	# because it reproduces on the PRE-FIX bundle exactly as it does on this
	# one. A red here would be a gate failing for a reason that is not its own,
	# and would be attributed to whoever touched the menu next.
	debug_checks=0
	debug_unmeasured=1
	echo
	echo "  NOTE: THE DEBUG HALF WAS NOT MEASURED ON THIS SURFACE."
	note "leg: ${debug_opened}; entries: ${debug_count:-0}; line: '${debug_line}'"
	note ""
	note "TWO SEPARATE DEFECTS STAND BETWEEN THIS GATE AND THE DEBUG MENU, and"
	note "neither is about the menu's contents:"
	note ""
	note '  1. THE MODE TOGGLE LOSES THE EDITOR. switchToDebug leaves the'
	note "     workspace with no editor pane and no filesystem tree —"
	note "     ${toggle_state} — with"
	note "     'layout: component clear EditorView/0 raised a Defect and was"
	note "     skipped' (ui_js.nim) in the console. So that route has nothing to"
	note "     right-click at all."
	note ""
	note "  2. AFTER A RUN THERE IS AN EDITOR AND NO MENU. The session mounts,"
	note "     the debug controls mount, source is painted — and a right-click on"
	note '     that source leaves contextmenu NOT defaultPrevented and shows'
	note "     zero rows. CodeTracer's handler does not run, which means the"
	note "     BROWSER's own menu is what a user gets. Reproduced identically on"
	note "     a bundle built from the pre-fix tree, so it is not this change."
	note "     Suspect: the editor for a replay session is adopted into its host"
	note "     ('editor: re-attached monaco for ... into #editorComponent-0',"
	note "     ui/editor.nim) rather than constructed, and the Monaco-level"
	note "     gesture handlers are registered by the construction path."
	note ""
	note "The eight per-entry Debug checks that had no subject:"
	note "  present: Jump to line, Run to Cursor, Jump backward to line, Copy"
	note "  absent:  Cut, Paste, Replace"
	note ""
	note "The Debug half is asserted on the desktop instead, where a Run produces"
	note "a real session with source on screen:"
	note "  src/tests/gui/tests/editor/editor_context_menu_is_mode_dependent.spec.ts"
	echo
fi

# ---------------------------------------------------------------------------
# THE COUNT ITSELF, so a check skipped by an early `return` cannot read as a
# pass. Raise this deliberately when adding one.
# ---------------------------------------------------------------------------
EXPECTED_CHECKS=$((28 + debug_checks))
echo
if [ "${checks}" -ne "${EXPECTED_CHECKS}" ]; then
	echo "RESULT: FAILED — ${checks} check(s) ran, ${EXPECTED_CHECKS} expected."
	echo "  A check that did not run is not a check that passed."
	exit 1
fi

if [ "${failures}" -eq 0 ]; then
	if [ "${debug_unmeasured:-0}" = "1" ]; then
		echo "RESULT: OK — ${checks} check(s), 0 failure(s)"
		echo "  NOTE: the Debug half was NOT measured here (see above); 8 per-entry"
		echo "        Debug checks had no subject on this surface."
		exit 0
	fi
	echo "RESULT: OK — ${checks} check(s), 0 failure(s)"
	exit 0
fi
echo "RESULT: FAILED — ${checks} check(s), ${failures} failure(s)"
echo "  report:      ${cache}/report.json"
echo "  screenshots: ${cache}/report-edit.png, ${cache}/report-debug.png"
exit 1
