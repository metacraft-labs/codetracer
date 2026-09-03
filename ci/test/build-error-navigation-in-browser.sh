#!/usr/bin/env bash
#
# build-error-navigation-in-browser.sh — a failed build, a keystroke, and a
# caret that lands on the error. In a real tab, against the assembled tree.
#
# WHAT THIS ASSERTS THAT NOTHING ELSE DOES
# ----------------------------------------
# `noir-build-in-browser.sh` proves a Build reaches the compiler and paints a
# verdict. Everything after that was scaffolding that had never run:
#
#   * `aGotoNextError` / `aGotoPreviousError` were `ClientAction` members with
#     commented-out menu entries (`ui_js.nim:849-850`) and `nil` in the handler
#     array — live enum members nothing could reach.
#   * `renderer.jumpLocation` had zero callers of any kind.
#   * The PROBLEMS pane's row click called `ErrorsVM.jumpToProblem`, which sent
#     `ct/jump-location` — one of nine commands `backend/dap_dialect.md` §7
#     records as having NO engine implementation. Clicking a build error was a
#     silent no-op, and the tests that covered it asserted the command was
#     ENQUEUED on a mock backend.
#   * The BUILD pane's own header documents `click→jumpToLocation` on its
#     diagnostic rows; the handler was deleted in commit 20e24939 and the
#     `build-clickable` class and its `cursor: pointer` were left behind.
#     `real-compiler-errors.spec.ts` asserts that class BY NAME, which passes
#     over an affordance that does nothing.
#
# So this gate refuses to measure calls. Its subject is where the CARET ENDS
# UP, read out of Monaco with `getPosition()`, and what a user can SEE.
#
# THE SHAPE
# ---------
#   * COUNTED assertions, with the count itself asserted, so a guard that
#     returned early stops being a silent pass.
#   * PAINTED TEXT, hit-tested at its own left edge, never `innerText` alone.
#     The first run of this gate found the PROBLEMS pane parked at x = -9999
#     inside a dismissed auto-hide overlay while its rows carried perfectly
#     correct diagnostics — a pane that passed every model-level assertion and
#     that no user could read.
#   * The caret is compared against THE POSITION THE PANE ITSELF PAINTS, not a
#     hardcoded line:col. A constant would rot when the bundled template moved
#     a line, and would then be "fixed" to whatever the code does — the
#     check-that-requires-the-current-behaviour trap. Non-vacuity is kept
#     separately: the caret must also have MOVED, and the reported position
#     must be a real one.
#   * A DELIBERATELY BROKEN PROGRAM, built by patching the bundled template and
#     rebuilding the renderer. The template is compiled into the bundle and
#     `nim js` emits string literals as byte arrays, so patching `ui.js` would
#     be a no-op that looked like an edit.
#
# Usage:  bash ci/test/build-error-navigation-in-browser.sh
# Env:    CT_WEB_BUNDLE_DIR       a tree already assembled by web-bundle-assets.sh
#         CT_NOIR_WASM_COMPILER   used only when a bundle must be assembled here
#         CT_NOIR_WASM_TRACER     likewise
#         CT_NOIR_WASM_REF        provenance; without it the page drops the modules
# Exit:   0 all assertions held, 1 otherwise, 2 could not run.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)"
cd "${repo_root}" || exit 2

# shellcheck source=ci/lib/published-asset.sh
# shellcheck disable=SC1091 # resolved at runtime from $repo_root
source "${repo_root}/ci/lib/published-asset.sh"

cache="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}/build-error-nav"
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

for tool in node python3 perl; do
	command -v "${tool}" >/dev/null 2>&1 || {
		echo "build-error-navigation-in-browser.sh: no '${tool}' on PATH." >&2
		echo "  remedy: run inside the dev shell (direnv exec ${repo_root} ...)" >&2
		exit 2
	}
done
node -e "require('playwright')" >/dev/null 2>&1 || {
	echo "build-error-navigation-in-browser.sh: playwright is not installed." >&2
	exit 2
}

echo "=== a failed build, a keystroke, and a caret on the error ==="
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

# THE PRECONDITION, CHECKED RATHER THAN ASSUMED. Without a compiler in the
# tree the page refuses by name, the pane paints the refusal, there are no
# diagnostics, and every navigation assertion below would be a statement about
# an empty list — which is exactly the vacuous pass this gate exists to avoid.
# RESOLVED BY STEM; see `noir-build-in-browser.sh` for the same correction.
# The resolved path is not needed here — only whether the tree ships one at all,
# under its plain name or a content-addressed one — so the answer is discarded
# rather than bound to a variable nothing reads.
if ! published_asset "${bundle}" assets/noir_wasm.wasm >/dev/null; then
	echo "  the assembled tree at ${bundle} ships no assets/noir_wasm.wasm," >&2
	echo "  under that name or a content-addressed one," >&2
	echo "  so no build can fail with real diagnostics and this gate would" >&2
	echo "  measure nothing. Set CT_NOIR_WASM_COMPILER / CT_NOIR_WASM_TRACER /" >&2
	echo "  CT_NOIR_WASM_REF and re-assemble." >&2
	exit 2
fi
note "bundle:   ${bundle}"
echo

# ---------------------------------------------------------------------------
# THE BROKEN PROGRAM.
#
# `src/utils.nr`'s `assert_in_range` is given a return type its body does not
# produce, and an unused expression result is added so the build carries a
# WARNING as well as an ERROR. The warning is not decoration: navigation is
# specified to range over errors only (EMT-D22.1), and a fixture with no
# warnings could not tell a correct implementation from one that navigates
# everything.
# ---------------------------------------------------------------------------
template_src="src/frontend/viewmodel/platform/noir_template.nim"
cp "${template_src}" "${cache}/noir_template.orig"
perl -0pi -e 's/pub fn assert_in_range\(value: Field\) \{/pub fn assert_in_range(value: Field) -> u8 {\n    let _unused = value + value;/' \
	"${template_src}"
if cmp -s "${template_src}" "${cache}/noir_template.orig"; then
	cp "${cache}/noir_template.orig" "${template_src}"
	echo "  the patch changed NOTHING — its premise has moved and this gate" >&2
	echo "  would be measuring a program that still compiles." >&2
	exit 2
fi

echo "Building a renderer whose bundled template does not compile..."
rebuilt=1
if ! nim js --hints:off --warnings:off -d:chronicles_enabled=off \
	-d:ctRenderer -d:ctWeb --nimcache:"${cache}/nimcache" \
	-o:"${cache}/broken-ui.js" src/frontend/ui_js.nim \
	>"${cache}/build.log" 2>&1; then
	rebuilt=0
fi
cp "${cache}/noir_template.orig" "${template_src}"
if [ "${rebuilt}" -ne 1 ]; then
	echo "  the mutated renderer did not build; see ${cache}/build.log" >&2
	grep -E 'Error:' "${cache}/build.log" | head -3 | sed 's/^/      /' >&2
	exit 2
fi

broken="${cache}/broken"
if [ -e "${broken}" ]; then
	chmod -R u+w "${broken}" 2>/dev/null
	rm -rf "${broken}"
fi
cp -R "${bundle}" "${broken}"
chmod -R u+w "${broken}"
# The assembled tree wraps `ui.js` in an IIFE. Reproduce it, or the renderer
# redefines globals and the page dies before mounting.
{
	printf '(function () {\n'
	cat "${cache}/broken-ui.js"
	printf '\n})();\n'
} >"${broken}/ui.js"

# RECOMPILE THE THEME INTO THE BROKEN TREE.
#
# The bundle carries a `.css` compiled by `web-bundle-assets.sh` at assembly
# time, so a change to a `.styl` after that is invisible to the page — and a
# mutation arm that edits a stylesheet would score a false KILL-less pass while
# the browser rendered the old rules. Recompiling here makes the stylesheet part
# of what this gate actually measures.
if [ -x node_modules/.bin/stylus ]; then
	if node node_modules/.bin/stylus -p src/frontend/styles/default_dark_theme_electron.styl \
		>"${cache}/theme.css" 2>"${cache}/stylus.log" && [ -s "${cache}/theme.css" ]; then
		cp "${cache}/theme.css" "${broken}/frontend/styles/default_dark_theme_electron.css"
	else
		echo "  the theme did not compile; see ${cache}/stylus.log" >&2
		exit 2
	fi
else
	echo "  node_modules/.bin/stylus is missing, so the theme cannot be recompiled" >&2
	echo "  and a stylesheet change would be invisible to the page." >&2
	exit 2
fi

# ---------------------------------------------------------------------------
# A static server that serves `.wasm` as `application/wasm`, applying the
# bundle's own `_redirects` so `/noir` resolves the way the CDN resolves it.
# Same reasoning as `noir-build-in-browser.sh`, which this borrows from.
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

port=8793
server_pid=""
start_server() {
	python3 "${cache}/serve.py" "$1" "${port}" >"${cache}/server.log" 2>&1 &
	server_pid=$!
	for _ in $(seq 1 40); do
		if curl -s -o /dev/null "http://127.0.0.1:${port}/noir"; then
			return 0
		fi
		sleep 0.25
	done
	return 1
}
stop_server() {
	if [ -n "${server_pid}" ]; then
		kill "${server_pid}" 2>/dev/null
		wait "${server_pid}" 2>/dev/null
		server_pid=""
	fi
}
trap stop_server EXIT

if ! start_server "${broken}"; then
	echo "  the static server did not start" >&2
	exit 2
fi

echo "Driving a browser..."
node ci/test/build_error_nav_probe.mjs "http://127.0.0.1:${port}/noir" \
	>"${cache}/nav.json" 2>"${cache}/nav.err"
probe_rc=$?
stop_server
if [ "${probe_rc}" -ne 0 ] || [ ! -s "${cache}/nav.json" ]; then
	echo "  the probe produced no report" >&2
	head -20 "${cache}/nav.err" >&2
	exit 2
fi
echo

q() { python3 ci/test/build_error_nav_query.py "${cache}/nav.json" "$@"; }

# ---------------------------------------------------------------------------
# NON-VACUITY FIRST.
# ---------------------------------------------------------------------------
if [ "$(q mounted)" = "True" ]; then
	ck ok "[mount] the renderer mounted, so the gestures below had a product to act on"
else
	ck fail "[mount] the renderer did not mount; nothing below measures anything"
	echo
	echo "RESULT: FAILED — the subject never came up"
	exit 1
fi

painted_rows="$(q count problemRows)"
error_rows="$(q count-errors)"
warning_rows="$(q count-warnings)"

if [ "${painted_rows:-0}" -ge 1 ]; then
	ck ok "[rows] the PROBLEMS pane PAINTS ${painted_rows} row(s), hit-tested at their own left edge"
	q dump-rows
else
	ck fail "[rows] the PROBLEMS pane painted NO row a user could see ($(q count problemRowsRejected) rejected)"
	q dump-rejected
fi

# BOTH SEVERITIES, because navigation is specified to range over errors only
# and a fixture with no warnings cannot tell that apart from ranging over
# everything.
if [ "${error_rows:-0}" -ge 1 ]; then
	ck ok "[errors] ${error_rows} of them are errors, so there is something to navigate to"
else
	ck fail "[errors] no painted row carries severity error; navigation has an empty range"
fi
if [ "${warning_rows:-0}" -ge 1 ]; then
	ck ok "[warnings] and ${warning_rows} are warnings, so 'errors only' is a claim this fixture can falsify"
else
	ck fail "[warnings] no painted warning row; 'navigation skips warnings' would pass vacuously"
fi

# THE DIAGNOSTIC CARRIES A REAL POSITION. A row with `col = -1`, or a path that
# never resolves, is the specific corrupted-row false pass this area has
# already produced once.
if [ "$(q first-error-has-position)" = "True" ]; then
	ck ok "[position] the first error row paints a file, a line and a column: $(q first-error-location)"
else
	ck fail "[position] the first error row does not paint a usable file:line:col — $(q first-error-location)"
fi

# ---------------------------------------------------------------------------
# THE KEYSTROKE.
# ---------------------------------------------------------------------------
if [ "$(q caret-moved)" = "True" ]; then
	ck ok "[caret-moved] CTRL+ALT+N MOVED the caret: $(q caret-before) -> $(q caret-after)"
else
	ck fail "[caret-moved] the caret did not move; it is still at $(q caret-after)"
fi

if [ "$(q caret-matches-diagnostic)" = "True" ]; then
	ck ok "[caret-col] and it landed on the line AND COLUMN the pane itself reports for that error"
else
	ck fail "[caret-col] the caret is at $(q caret-after) but the pane reports $(q first-error-location)"
fi

# NAVIGATION SKIPPED THE WARNINGS (EMT-D22.1). A separate claim from the one
# above, and the fixture is built so it can fail: the FIRST painted row is a
# warning, so a navigator that ignored severity would land on a real file at a
# real line and only this check would see it.
if [ "$(q first-row-is-warning)" = "True" ]; then
	ck ok "[first-row-warning] the first painted row is a warning, so 'errors only' is falsifiable here"
else
	ck fail "[first-row-warning] the first painted row is not a warning; the skip check below is weakened"
fi
skip_verdict="$(q skipped-the-warnings)"
if [ "${skip_verdict}" = "True" ]; then
	ck ok "[skip-warnings] and the caret is on none of the ${warning_rows} warning rows — navigation skipped them"
elif [ "${skip_verdict}" = "Vacuous" ]; then
	# NOT "the caret landed on a warning". With no warning rows there is
	# nothing to skip, and reporting a specific failure for a check that could
	# not run is how a broken instrument gets read as a broken product.
	ck fail "[skip-warnings] could not be measured: no warning rows were painted"
else
	ck fail "[skip-warnings] the caret landed on a WARNING; navigation is not filtering to errors"
fi

# EXACTLY ONE ROW IS SELECTED, asserted before the appearance check so that
# check cannot pass over a list where nothing (or everything) is selected.
if [ "$(q selected-row-count)" = "1" ]; then
	ck ok "[selected-one] exactly one painted row is marked selected"
else
	ck fail "[selected-one] $(q selected-row-count) painted rows are marked selected, expected 1"
fi

# AND IT LOOKS DIFFERENT. Found the hard way: the view had always been able to
# add `problems-row-selected` and no stylesheet defined it, so the selection
# existed in the DOM and nowhere on the screen.
selvis="$(q selection-is-visible)"
if [ "${selvis}" = "True" ]; then
	ck ok "[selected-visible] and it is PAINTED differently from the unselected rows"
elif [ "${selvis}" = "Vacuous" ]; then
	ck fail "[selected-visible] could not be measured: no selected row to compare"
else
	ck fail "[selected-visible] the selected row paints identically to the others — the highlight is invisible"
fi

if [ "$(q opened-right-file)" = "True" ]; then
	ck ok "[opened-file] in the file the diagnostic names, opened as its own editor"
else
	ck fail "[opened-file] the caret is in $(q caret-uri), which is not the diagnostic's file"
fi

if [ "$(q editorFocusedAfterNext)" = "True" ]; then
	ck ok "[focus] the EDITOR holds focus afterwards — the point of going to an error is to fix it"
else
	ck fail "[focus] the editor does not hold focus after navigating (active: $(q activeElementAfterNext))"
fi

# THE KEYSTROKE WAS ISSUED WITH THE CARET IN THE EDITOR, which is the only
# place anybody presses "next error" from, and is where a chord Monaco claims
# would be swallowed. Measured: ALT+F8 — the spec's proposal — is bound by
# Monaco's own marker navigation and never reached the action at all.
if [ "$(q caret-before-was-editor)" = "True" ]; then
	ck ok "[from-editor] and the chord was pressed WITH the caret already in the editor, not from the chrome"
else
	ck fail "[from-editor] the caret was not in the editor before the keystroke; the hard case was not exercised"
fi

# ---------------------------------------------------------------------------
# THE ANNOUNCEMENT.
# ---------------------------------------------------------------------------
if [ -n "$(q statusAfterNext)" ]; then
	ck ok "[announce] the pane announces what navigation did: \"$(q statusAfterNext)\""
else
	ck fail "[announce] the pane announced nothing; a silent wrap makes a short list feel infinite"
fi

if [ "$(q wrap-announced)" = "True" ]; then
	ck ok "[wrap] and a wrap is announced BY NAME rather than silently: \"$(q statusAfterWrap)\""
else
	ck fail "[wrap] no wrap announcement was ever painted (last: \"$(q statusAfterWrap)\")"
fi

# ---------------------------------------------------------------------------
# THE MENU.
# ---------------------------------------------------------------------------
if [ "$(q menuOpenedBuild)" = "True" ]; then
	ck ok "[menu-open] the Build menu opens, so the two assertions below are about a real menu"
else
	ck fail "[menu-open] the Build folder never opened; the menu assertions below measure nothing"
	q dump-menu
fi

# THE CONTROL ROW, asserted first so the comparison below cannot be vacuous.
control_row="Rebuild/Re-record file"
if [ "$(q menu-has-control "${control_row}")" = "True" ]; then
	ck ok "[menu-control] the Build menu carries \"${control_row}\", the control these rows are compared against"
else
	ck fail "[menu-control] the control row \"${control_row}\" is absent; the occlusion comparison below measures nothing"
fi

# THE CONTROL CARRIES NO CHORD, which is what makes "the chord is displayed" a
# claim about this feature rather than about the menu rendering anything at all.
# `aReRecord` has no `bindings:` entry, so `loadShortcut` returns "" for it — if
# this ever started showing a chord, the assertions below would stop
# distinguishing a bound action from an unbound one.
if [ -z "$(q menu-item-shortcut "${control_row}")" ]; then
	ck ok "[menu-control-nochord] and it shows NO chord, so a painted chord below is not just menu furniture"
else
	ck fail "[menu-control-nochord] the control row unexpectedly shows \"$(q menu-item-shortcut "${control_row}")\""
fi

for pair in "Go to Next Error:CTRL+ALT+N" "Go to Previous Error:CTRL+ALT+P"; do
	label="${pair%%:*}"
	chord="${pair##*:}"
	if [ "$(q menu-item-shortcut "${label}")" = "${chord}" ]; then
		ck ok "[menu-chord:${label}] the menu paints \"${label}\" with its chord ${chord} beside it"
	else
		ck fail "[menu-chord:${label}] \"${label}\" shows \"$(q menu-item-shortcut "${label}")\", expected ${chord}"
	fi
	if [ "$(q menu-item-geometry "${label}")" = "True" ]; then
		ck ok "[menu-geom:${label}] and that row has real on-screen geometry, not a -9999 parking slot"
	else
		ck fail "[menu-geom:${label}] \"${label}\" has no usable geometry"
	fi
	if [ "$(q menu-occlusion-matches-control "${label}" "${control_row}")" = "True" ]; then
		ck ok "[menu-occlusion:${label}] and it is exactly as unoccluded as \"${control_row}\""
	else
		ck fail "[menu-occlusion:${label}] \"${label}\" is occluded differently from the control row — that IS this feature's bug"
	fi
done

# THE MENU'S OWN Z-ORDER, reported rather than asserted, because it is a
# pre-existing defect this feature neither caused nor fixed: with a pane
# revealed, `#auto-hide-backdrop` and the filesystem tree both render above the
# in-page menu, so no menu row survives a hit test. Named here so it is visible
# in this gate's output instead of quietly weakening the two checks above.
note "observation: menu rows are occluded by the auto-hide backdrop / file tree"
note "             (pre-existing; affects \"${control_row}\" identically)"

# ---------------------------------------------------------------------------
# NO UNCAUGHT ERRORS WHILE DOING ANY OF IT.
# ---------------------------------------------------------------------------
page_errors="$(q count pageErrors)"
if [ "${page_errors:-0}" -eq 0 ]; then
	ck ok "[no-page-errors] and the page raised no uncaught error throughout"
else
	ck fail "[no-page-errors] the page raised ${page_errors} uncaught error(s)"
	q dump-page-errors
fi

echo
echo "${checks} check(s), ${failures} failure(s)"
if [ "${failures}" -eq 0 ]; then
	echo "RESULT: OK — a failed build, a keystroke, and a caret on the error"
	exit 0
fi
echo "RESULT: FAILED"
exit 1
