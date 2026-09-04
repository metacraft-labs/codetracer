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
# THE DEBUG HALF IS NOT MEASURED HERE, and the gate says so out loud rather
# than passing over it. Measured on this bundle: switching `/noir` to Debug
# mode through `data.functions.switchToDebug` leaves the workspace with NO
# editor pane and no filesystem tree — `[id^=editorComponent-]` count 0, and
# `monaco.editor.getEditors()[0].getDomNode().isConnected === false` — so there
# is nothing in Debug mode to right-click. That is a separate defect about the
# mode transition, not about this menu, and it is reported by the
# `[debug/subject]` check below. The Debug half of the menu is asserted on the
# desktop instead, where a Run produces a real session with source on screen:
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
mute="$(py "
import json
d = json.load(open('${cache}/report.json'))
rows = ((d.get('legs') or {}).get('edit') or {}).get('menu', {}).get('entries') or []
bad = [r['name'] for r in rows if r.get('disabled') and not r.get('sublabel')]
print(','.join(bad) if bad else 'none')
print(sum(1 for r in rows if r.get('disabled')))
")"
mute_names="$(printf '%s\n' "${mute}" | head -1)"
disabled_n="$(printf '%s\n' "${mute}" | tail -1)"
if [ "${mute_names}" = "none" ]; then
	ck ok "[edit/reasons] every disabled row carries a reason" \
		"(${disabled_n} disabled row(s) on this leg)"
else
	ck fail "[edit/reasons] disabled with no reason: ${mute_names} —" \
		"'an action whose absence cannot be explained is one whose absence was a guess'"
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
# THE DEBUG HALF — reported, and its absence named.
# ---------------------------------------------------------------------------
debug_opened="$(py "
import json
d = json.load(open('${cache}/report.json'))
leg = (d.get('legs') or {}).get('debug') or {}
print('yes' if leg.get('opened') else 'no:' + str(leg.get('reason')))")"
if [ "${debug_opened}" = "yes" ]; then
	debug_names="$(names_of debug | paste -sd, -)"
	ck ok "[debug/subject] the Debug-mode menu opened: ${debug_names}"
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
	# It is a NOTE and not a failure because the cause is not this menu. It is a
	# mode-transition defect: switching `/noir` to Debug mode leaves the
	# workspace with no editor pane and no filesystem tree, so there is nothing
	# to right-click. A red gate here would be a gate failing for a reason that
	# is not its own, and would be attributed to whoever touched the menu next.
	debug_checks=0
	debug_unmeasured=1
	echo
	echo "  NOTE: THE DEBUG HALF WAS NOT MEASURED ON THIS SURFACE."
	note "${debug_opened}"
	note "Switching /noir to Debug mode leaves the workspace with no editor pane"
	note "and no filesystem tree — [id^=editorComponent-] count 0, and the"
	note "surviving Monaco instance's DOM node is disconnected. That is a defect"
	note "in the mode transition, not in this menu, and it is why the eight"
	note "per-entry Debug checks below have no subject:"
	note "  present: Jump to line, Run to Cursor, Jump backward to line, Copy"
	note "  absent:  Cut, Paste, Replace"
	note "The Debug half is asserted on the desktop instead, where a Run produces"
	note "a real session with source on screen:"
	note "  src/tests/gui/tests/editor/editor_context_menu_is_mode_dependent.spec.ts"
	echo
fi

# ---------------------------------------------------------------------------
# THE COUNT ITSELF, so a check skipped by an early `return` cannot read as a
# pass. Raise this deliberately when adding one.
# ---------------------------------------------------------------------------
EXPECTED_CHECKS=$((25 + debug_checks))
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
