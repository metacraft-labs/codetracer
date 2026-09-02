#!/usr/bin/env bash
#
# menu-and-context-menu-in-browser.sh — the main menu opens a submenu a user can
# actually click, without the bar flickering, and a right-click in the editor
# produces exactly one menu.  In a real tab, against an assembled bundle.
#
# WHAT THIS ASSERTS THAT NOTHING ELSE DOES
# ----------------------------------------
# Three defects were reported against the deployed `ide.codetracer.com` on
# 2026-09-02 and all three passed every existing check:
#
#   1. "when I move my mouse over the menu, it flickers, briefly displaying the
#      content below it";
#   2. "the sub-menus are not displayed — not by a click, not by a mouse over";
#   3. "when I right click in the editor area I see both the browser menu and
#      the CodeTracer menu".
#
# (1) and (2) are ONE cause: commit 09bc09b7 replaced `#menu-main`'s hand-written
# surface with `dropdown-surface()`, which brought two behaviours the element
# cannot take — `overflow: hidden`, which clips the absolutely-positioned
# submenus laid out BESIDE it, and a reveal animation that replays from
# `opacity: 0` every time `ui/menu.nim` rebuilds the shell, which it does on
# every hovered-row change.  Neither is visible to a markup assertion: the
# submenu is in the DOM, with the right rows, at the right coordinates, and its
# HTML is correct.  It is clipped out of existence.
#
# So the two menu checks here are a HIT TEST and an OPACITY SAMPLE, never
# presence or markup:
#
#   * the submenu's first row is hit-tested at its own painted centre with
#     `elementFromPoint`, and the result is walked UP to the submenu.
#     `submenu.contains(hit)` would pass vacuously the moment the hit lands on
#     `document.body`, which is exactly what the defect produces;
#   * the menu's computed `opacity` is sampled on every animation frame across a
#     pointer sweep and the MINIMUM is asserted.  A screenshot before and after
#     the sweep shows a perfectly good menu both times; the flicker lives
#     between the frames.
#
# (3) cannot be counted directly, and this gate says so rather than pretending:
# the native context menu is browser chrome, outside the document, and is
# suppressed under automation in every engine.  What decides whether it is drawn
# IS observable — `defaultPrevented` on the `contextmenu` event, read by a
# document-level bubble listener that runs after every surface handler.  That,
# plus a count of our own visible menu surfaces, is "exactly one menu".
#
# Usage:  bash ci/test/menu-and-context-menu-in-browser.sh
# Env:    CT_WEB_BUNDLE_DIR   a tree already assembled by web-bundle-assets.sh
#         CT_MENU_GATE_TREE   serve this tree as-is instead of rebuilding
#                             (used by the mutation arms)
# Exit:   0 all assertions held, 1 otherwise, 2 could not run.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

cache="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}/menu-context-menu"
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
# `nim` only when this gate is going to build the renderer itself; an arm that
# supplies its own tree does not need a compiler on PATH.
[ -z "${CT_MENU_GATE_TREE:-}" ] && required_tools="${required_tools} nim"
for tool in ${required_tools}; do
	command -v "${tool}" >/dev/null 2>&1 || {
		echo "menu-and-context-menu-in-browser.sh: no '${tool}' on PATH." >&2
		echo "  remedy: run inside the dev shell (direnv exec ${repo_root} ...)" >&2
		exit 2
	}
done
if [ ! -d node_modules/playwright ] && ! node -e "require('playwright')" >/dev/null 2>&1; then
	# Same precondition, and the same remedy, as `ci/test/web-renderer-mounts.sh`:
	# the dev shell provides `node_modules/playwright` at the repo root, which is
	# what `ci/test/menu_and_context_menu_probe.mjs` resolves against.
	echo "menu-and-context-menu-in-browser.sh: node_modules/playwright is missing;" >&2
	echo "  run inside the dev shell (direnv exec ${repo_root} ...)" >&2
	exit 2
fi

echo "=== one menu on right-click, and a submenu you can click ==="
echo

# ---------------------------------------------------------------------------
# The tree
# ---------------------------------------------------------------------------
tree="${CT_MENU_GATE_TREE:-}"
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

# BOTH HALVES OF THE SUBJECT ARE REBUILT FROM SOURCE, because a pre-assembled
# `CT_WEB_BUNDLE_DIR` carries whatever `ui.js` and `.css` it was built with, and
# a gate that measured those would be reporting on a tree nobody edited.  That is
# the "verify the instrument" trap, and it bites hardest here: the menu half is
# entirely a stylesheet defect and the context-menu half is entirely a renderer
# one, so a stale copy of either half silently passes over its own defect.
#
# `CT_MENU_GATE_TREE` opts out on purpose — it names a tree the caller has
# already prepared, which is how the mutation arms serve a mutated build.
if [ -z "${CT_MENU_GATE_TREE:-}" ]; then
	# Into a COPY, so a caller's `CT_WEB_BUNDLE_DIR` is never written through.
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
	# The assembled tree wraps `ui.js` in an IIFE.  Reproduce it, or the renderer
	# redefines globals and the page dies before mounting.
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

port="${CT_MENU_GATE_PORT:-8794}"
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
node ci/test/menu_and_context_menu_probe.mjs "http://127.0.0.1:${port}/noir" \
	--shots "${cache}" >"${cache}/report.json" 2>"${cache}/probe.err"
probe_rc=$?
stop_server
if [ "${probe_rc}" -ne 0 ] || [ ! -s "${cache}/report.json" ]; then
	echo "  the probe produced no report" >&2
	head -20 "${cache}/probe.err" >&2
	exit 2
fi
echo

q() { python3 -c "
import json,sys
d=json.load(open('${cache}/report.json'))
for k in sys.argv[1:]:
    if d is None: break
    d = d.get(k) if isinstance(d,dict) else None
print(json.dumps(d))
" "$@"; }

# The same walk, but a string comes back as ITS TEXT rather than as a JSON
# string literal.  `q` is right for numbers, booleans and `null`, and wrong for
# anything compared against a name — `"GUTTER_LINE_DECORATIONS"` with the
# quotes is not equal to `GUTTER_LINE_DECORATIONS` without them, and a check
# written with the wrong one of the two is red for a reason that has nothing to
# do with the product.
qraw() { python3 -c "
import json,sys
d=json.load(open('${cache}/report.json'))
for k in sys.argv[1:]:
    if d is None: break
    d = d.get(k) if isinstance(d,dict) else None
print(d if isinstance(d,str) else json.dumps(d))
" "$@"; }

# ---------------------------------------------------------------------------
# NON-VACUITY FIRST.  Every assertion below is about something a user sees, so
# if the product did not mount there is nothing to be right about.
# ---------------------------------------------------------------------------
if [ "$(q mounted navigationMenu)" = "true" ] && [ "$(q mounted monaco)" = "true" ]; then
	ck ok "[mount] the caption bar and an editor are on the page"
else
	ck fail "[mount] the product did not mount; nothing below measures anything"
	echo
	echo "RESULT: FAILED — the subject never came up"
	exit 1
fi

root_items="$(q menu rootItems)"
if [ "$(python3 -c "import json;print(len(json.loads('''${root_items}''')))")" -ge 1 ]; then
	ck ok "[menu] the menu opens: rows = ${root_items}"
else
	ck fail "[menu] the menu opened no rows, so the submenu checks have no subject"
fi

# ---------------------------------------------------------------------------
# THE SUBMENU — hit-tested, by BOTH gestures.
# ---------------------------------------------------------------------------
if [ "$(q menu hover submenuInDom)" = "true" ] && [ "$(q menu hover rows)" != "0" ]; then
	ck ok "[submenu] hovering a folder builds a submenu with $(q menu hover rows) rows"
else
	ck fail "[submenu] hovering a folder built no submenu"
fi

if [ "$(q menu hover rowIsHitTestable)" = "true" ]; then
	ck ok "[submenu/hover] its first row is hit-testable at its painted centre" \
		"$(q menu hover rowCentre) -> $(q menu hover hitElement)"
else
	ck fail "[submenu/hover] elementFromPoint at the row's own centre reaches" \
		"$(q menu hover hitElement), not the submenu — the rows are painted-over" \
		"or clipped away"
fi

if [ "$(q menu click rowIsHitTestable)" = "true" ]; then
	ck ok "[submenu/click] the same holds when the folder is CLICKED"
else
	ck fail "[submenu/click] clicking the folder leaves the rows unreachable" \
		"($(q menu click hitElement))"
fi

# `q` returns JSON, so the string is quoted — comparing against a bare `hidden`
# would be true for every value there is, which is how this check passed over
# the very defect it names on its first run.
if [ "$(q menu hover menuMainOverflow)" != '"hidden"' ]; then
	ck ok "[submenu/mechanism] #menu-main does not clip its children" \
		"(overflow: $(q menu hover menuMainOverflow))"
else
	ck fail "[submenu/mechanism] #menu-main is overflow:hidden, which deletes the" \
		"submenus laid out beside it"
fi

# ---------------------------------------------------------------------------
# THE MIXIN'S PRECONDITION, asked of every dropdown surface on screen rather
# than of the one that was reported.  `dropdown-surface()` clips every
# descendant, so any caller that acquires an absolutely-positioned child laid
# out beside it has this defect — and would pass every markup assertion while
# the child rendered perfectly and invisibly.
#
# NOT ANSWERABLE FROM THE STYLESHEET: a static pass over the compiled CSS
# reports zero escaping children even for `#menu-main`, because
# `.menu-nested-elements` is a sibling RULE and a child only in the DOM.
# ---------------------------------------------------------------------------
with_abs="$(q menu clipCheck withAbsoluteChildren)"
if [ "${with_abs:-0}" -ge 1 ]; then
	ck ok "[clip/instrument] $(q menu clipCheck containersExamined) dropdown surface(s)" \
		"examined, ${with_abs} of them actually holding an absolutely-positioned" \
		"child — so 'nothing escaped' is not a statement about an empty set"
else
	ck fail "[clip/instrument] no dropdown surface on screen held an" \
		"absolutely-positioned child, so the escape check below measures nothing"
fi

escapes="$(q menu clipCheck escapes)"
if [ "$(python3 -c "import json;print(len(json.loads('''${escapes}''')))")" = "0" ]; then
	ck ok "[clip] no dropdown surface clips an absolutely-positioned child"
else
	ck fail "[clip] a dropdown surface clips a child that paints outside it:" \
		"${escapes}"
fi

# ---------------------------------------------------------------------------
# THE FLICKER — measured between the frames, not in a screenshot.
# ---------------------------------------------------------------------------
samples="$(q menu sweep opacitySamples)"
if [ "${samples:-0}" -ge 10 ]; then
	ck ok "[flicker/instrument] the sweep sampled the menu's opacity ${samples} times," \
		"so a minimum of 1 is a measurement rather than an empty loop"
else
	ck fail "[flicker/instrument] only ${samples} opacity samples — the sweep did not run"
fi

min_op="$(q menu sweep minMenuOpacity)"
if python3 -c "import sys;sys.exit(0 if float('${min_op}') >= 0.999 else 1)"; then
	ck ok "[flicker] the menu never became transparent across" \
		"$(q menu sweep transitions) pointer transitions (min opacity ${min_op})"
else
	ck fail "[flicker] the menu dropped to opacity ${min_op} during a pointer sweep —" \
		"that is the reported 'briefly displaying the content below it'"
fi

reveals="$(q menu sweep revealAnimations)"
if [ "${reveals}" = "0" ]; then
	ck ok "[flicker/mechanism] no ct-dropdown-reveal replayed during the sweep"
else
	ck fail "[flicker/mechanism] the reveal animation replayed ${reveals} time(s)" \
		"across $(q menu sweep transitions) transitions"
fi

# ---------------------------------------------------------------------------
# THE CONTEXT MENU — exactly one, counted.
# ---------------------------------------------------------------------------
text_prevented="$(q context text events)"
prevented=$(python3 -c "
import json
ev=json.loads('''${text_prevented}''') or []
print('true' if ev and all(e['defaultPrevented'] for e in ev) else 'false')")
surfaces="$(q context text visibleMenuSurfaces)"

if [ "${prevented}" = "true" ]; then
	ck ok "[ctx/text] the native contextmenu event is defaultPrevented, so the" \
		"browser draws no menu of its own"
else
	ck fail "[ctx/text] the contextmenu event was NOT defaultPrevented — the browser" \
		"will draw its menu on top of ours, which is the reported defect"
fi

if [ "${surfaces}" = "1" ]; then
	ck ok "[ctx/text] exactly ONE menu surface is visible in the document"
else
	ck fail "[ctx/text] ${surfaces} visible menu surface(s), expected exactly 1"
fi

gut_ev="$(q context gutter events)"
gut_prevented=$(python3 -c "
import json
ev=json.loads('''${gut_ev}''') or []
print('true' if ev and all(e['defaultPrevented'] for e in ev) else 'false')")
if [ "${gut_prevented}" = "true" ]; then
	ck ok "[ctx/gutter] the gutter suppresses the native menu too"
else
	ck fail "[ctx/gutter] a right-click on the gutter leaves the native menu to open"
fi

# THE SHIFT BYPASS.  What is asserted is that OUR handler stands down — that is
# the half this code owns and the half that is easy to break.  Whether the
# browser then draws its own menu is chrome, outside the document, and is
# stated in the report rather than asserted here.
shift_ev="$(q context textShift events)"
shift_ok=$(python3 -c "
import json
ev=json.loads('''${shift_ev}''') or []
print('true' if ev and all(e['shiftKey'] and not e['defaultPrevented'] for e in ev) else 'false')")
if [ "${shift_ok}" = "true" ] && [ "$(q context textShift ourMenuVisible)" = "false" ]; then
	ck ok "[ctx/shift] with Shift held we show no menu and suppress nothing, so the" \
		"browser's own menu is the only one that can appear"
else
	ck fail "[ctx/shift] Shift+right-click still showed our menu" \
		"(visible=$(q context textShift ourMenuVisible)) or suppressed the default"
fi

# ---------------------------------------------------------------------------
# THE HINT ROW — present AND inert.  Presence alone would pass over a row that
# had quietly become a dead command, which is the failure it exists to avoid.
# ---------------------------------------------------------------------------
if [ "$(q context text hint text)" != "null" ] &&
	[ "$(q context text hint count)" = "1" ]; then
	ck ok "[hint] exactly one hint row, reading $(q context text hint text)"
else
	ck fail "[hint] expected exactly one hint row; count=$(q context text hint count)"
fi

if [ "$(q context text hint painted)" = "true" ]; then
	ck ok "[hint] it is painted ($(q context text hint rect)), so 'inert' is not" \
		"passing by the row being invisible"
else
	ck fail "[hint] the hint row has no painted area"
fi

if [ "$(q context text hint focusable)" = "false" ] &&
	[ "$(q context text hint hasTabIndexAttr)" = "false" ] &&
	[ "$(q context text hint pointerEvents)" = '"none"' ] &&
	[ "$(q context text hint hitTargetIsHint)" = "false" ] &&
	[ "$(q context text hint isDeclaredMenuItem)" = "false" ]; then
	ck ok "[hint] and it is INERT: not focusable, no tabindex, pointer-events:none," \
		"not the hit target at its own centre, and not a declared menu item"
else
	ck fail "[hint] the hint row is not inert:" \
		"focusable=$(q context text hint focusable)" \
		"tabindex=$(q context text hint hasTabIndexAttr)" \
		"pointerEvents=$(q context text hint pointerEvents)" \
		"hitTargetIsHint=$(q context text hint hitTargetIsHint)" \
		"isMenuItem=$(q context text hint isDeclaredMenuItem)"
fi

# ---------------------------------------------------------------------------
# THE GUTTER — one lane, one owner, and the ABSENCE of the second effect.
#
# Reported as "clicking the gutter to place a breakpoint also collapses the
# function".  It does not reproduce on either the deployed build or `cloud`:
# `.gutter` subtracts `--ct-gutter-folding-lane` from its own width, so Monaco's
# chevron is never underneath us.  A test that checked each control WORKS would
# have passed on the defect exactly as reported, so both directions here are
# assertions about what must NOT also happen.
#
# The lanes are asserted too, because a third control is being added to this
# strip: each lane must own the hit test at its own centre, and no two may
# overlap.  They did — the breakpoint and tracepoint markers had independently
# tuned right offsets that put the tracepoint over the breakpoint's centre.
# ---------------------------------------------------------------------------
if [ "$(q gutter geom line)" != "null" ]; then
	ck ok "[gutter] a foldable line is on screen (line $(q gutter geom line)), so the" \
		"two gestures below have a subject"
else
	ck fail "[gutter] no foldable line found; the gutter checks measure nothing"
fi

unowned="$(python3 -c "
import json
z = json.loads('''$(q gutter geom zones)''') or {}
print(','.join(n for n, v in z.items() if not v['ownedBySelf']) or 'none')
print(len(z))
")"
unowned_names="$(printf '%s\n' "${unowned}" | head -1)"
zone_count="$(printf '%s\n' "${unowned}" | tail -1)"
if [ "${zone_count:-0}" -ge 3 ] && [ "${unowned_names}" = "none" ]; then
	ck ok "[gutter/lanes] all ${zone_count} lanes own the hit test at their own centre"
else
	ck fail "[gutter/lanes] ${zone_count} lane(s) found; these do not own their own" \
		"centre: ${unowned_names} — $(q gutter geom zones)"
fi

overlaps="$(q gutter geom overlaps)"
if [ "$(python3 -c "import json;print(len(json.loads('''${overlaps}''')))")" = "0" ]; then
	ck ok "[gutter/lanes] no two lanes overlap horizontally"
else
	ck fail "[gutter/lanes] lanes overlap: ${overlaps}"
fi

if [ "$(q gutter geom lineNumberClipped)" = "false" ]; then
	ck ok "[gutter/lanes] and the line number still fits its lane after the marker" \
		"lane was widened to separate the markers"
else
	ck fail "[gutter/lanes] the line number is clipped by its lane"
fi

if [ "$(q gutter clickGutter breakpointChanged)" = "true" ] &&
	[ "$(q gutter clickGutter folded)" = "false" ]; then
	ck ok "[gutter/click] a gutter click toggles the breakpoint and does NOT fold"
else
	ck fail "[gutter/click] breakpointChanged=$(q gutter clickGutter breakpointChanged)" \
		"folded=$(q gutter clickGutter folded) — expected a breakpoint and no fold"
fi

if [ "$(q gutter clickChevron folded)" = "true" ] &&
	[ "$(q gutter clickChevron breakpointChanged)" = "false" ]; then
	ck ok "[gutter/fold] the dedicated folding control folds and does NOT touch" \
		"breakpoints"
else
	ck fail "[gutter/fold] folded=$(q gutter clickChevron folded)" \
		"breakpointChanged=$(q gutter clickChevron breakpointChanged)"
fi

# ---------------------------------------------------------------------------
# MONACO'S OWN VERDICT ON THE SAME TWO PRESSES.
#
# The two checks above measure what each click DID.  These measure what Monaco
# thought each click WAS, and they are here because the previous investigation
# of this report concluded "does not reproduce" while recording nothing from
# Monaco at all — so it could say the fold did not happen but not why it could
# not.  `editor.onMouseDown` reports a `MouseTargetType`, and the answer turns
# out to be sharper than "the boxes do not overlap":
#
#   gutter click    NO Monaco mouse target whatsoever
#   chevron click   exactly one, GUTTER_LINE_DECORATIONS
#
# The first is the mechanism.  Every node `ui/trace.editorLineNumber` emits
# carries `onmousedown='event.stopPropagation()'`, so a press on our markup
# never reaches Monaco's mouse handling — there is no folding contribution that
# could act on it, whatever the geometry.  The second says the chevron is in a
# DIFFERENT band by Monaco's own reckoning: `GUTTER_LINE_DECORATIONS` and not
# `GUTTER_LINE_NUMBERS`, which is the band our gutter is painted into.
#
# ASSERTED AS THE NAMES AND THE COUNT, not as a boolean.  A press that reached
# Monaco as GUTTER_LINE_NUMBERS would mean the `stopPropagation` guards had
# been dropped — the state measured in `editorLineNumber`'s own doc block,
# where Monaco selects the line and the breakpoint is never toggled at all.
hooked_n="$(q monacoHook hooked)"
case "${hooked_n}" in
[1-9]*)
	ck ok "[gutter/monaco] ${hooked_n} editor(s) hooked, so the two target-type" \
		"readings below are measurements and not empty defaults"
	;;
*)
	ck fail "[gutter/monaco] no editor could be hooked (hooked=${hooked_n}," \
		"error: $(qraw monacoHook error)) — the target-type checks measure nothing"
	;;
esac

gut_targets="$(qraw gutter clickGutter monacoTargetNames)"
gut_target_n="$(python3 -c "
import json
print(len(json.loads('''$(q gutter clickGutter monacoTargets)''') or []))
" 2>/dev/null || echo "?")"
if [ "${gut_target_n}" = "0" ]; then
	ck ok "[gutter/monaco] a gutter click reaches Monaco as NO mouse target at all" \
		"(${gut_target_n} recorded) — the stopPropagation guards keep our markup" \
		"out of Monaco's mouse handling, which is why no folding contribution can" \
		"act on it"
else
	ck fail "[gutter/monaco] a gutter click reached Monaco as ${gut_target_n} target(s):" \
		"${gut_targets} — expected none. The stopPropagation guards on the custom" \
		"gutter markup have been lost, and Monaco now selects the line on press."
fi

chev_targets="$(qraw gutter clickChevron monacoTargetNames)"
if [ "${chev_targets}" = "GUTTER_LINE_DECORATIONS" ]; then
	ck ok "[gutter/monaco] and the chevron reaches Monaco as ${chev_targets}, a" \
		"different band from the GUTTER_LINE_NUMBERS our gutter is painted into"
else
	ck fail "[gutter/monaco] the chevron reached Monaco as '${chev_targets}';" \
		"expected exactly GUTTER_LINE_DECORATIONS. Anything else means the folding" \
		"control and our gutter are being resolved into the same band."
fi

# ---------------------------------------------------------------------------
# THE COUNT ITSELF, so a check skipped by an early `return` cannot read as a
# pass.  Raise this deliberately when adding one.
# ---------------------------------------------------------------------------
EXPECTED_CHECKS=27
echo
if [ "${checks}" -ne "${EXPECTED_CHECKS}" ]; then
	echo "RESULT: FAILED — ${checks} check(s) ran, ${EXPECTED_CHECKS} expected."
	echo "  A check that did not run is not a check that passed."
	exit 1
fi

if [ "${failures}" -eq 0 ]; then
	echo "RESULT: OK — ${checks} check(s), 0 failure(s)"
	exit 0
fi
echo "RESULT: FAILED — ${checks} check(s), ${failures} failure(s)"
echo "  report:      ${cache}/report.json"
echo "  screenshots: ${cache}/menu-hover.png, ${cache}/ctx-text.png"
exit 1
