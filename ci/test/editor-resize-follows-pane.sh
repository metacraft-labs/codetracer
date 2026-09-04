#!/usr/bin/env bash
#
# editor-resize-follows-pane.sh — drag the pane divider, in a real browser tab,
# and require the Monaco editor to have followed it. In BOTH modes and BOTH
# directions.
#
# THE REPORT
# ----------
# Against noirstudio.dev: "Resizing the panel that holds the Monaco editor
# doesn't seem to resize the actual editor. The scrollbar stays in place. This
# is in debug mode."
#
# WHAT WAS WRONG, AND WHY DEBUG MODE ONLY
# ---------------------------------------
# `automaticLayout: true` was set at both construction sites all along, and
# Monaco never turns it off — `browser/config/editorConfiguration.js` calls
# `startObserving()` once, in the constructor, and `stopObserving()` only from
# `dispose()`. `layout(dimension)` does NOT disable it; it forwards to
# `observeContainer(dimension)` and returns. The first hypothesis for this
# report — that an explicit `layout({width, height})` pins the size and stops
# the observer — is false, and was checked against Monaco 0.54.0's own source
# in this build rather than assumed.
#
# What is fixed forever at construction is WHAT the observer watches:
# `_domElement`, the node handed to `monaco.editor.create`, which
# `getContainerDomNode()` returns. That is a different element from
# `getDomNode()`, the inner `.monaco-editor` view node that `browser/view.js`
# sizes with inline pixels.
#
# Entering Debug mode re-hosts the editor: the pane is rebuilt and the VIEW is
# carried into the new `#editorComponent-N`, leaving `_domElement` behind,
# detached and empty. A detached element's `contentRect` is 0x0 and never
# changes, so Monaco's observer went silent for the rest of that instance's
# life — still "on", watching an orphan. The only thing left holding the
# editor's size was the inline pixel width on the view node: "the pane resizes
# and the editor does not", with the scrollbar and overview ruler positioned
# from the same frozen layout info, stranded inside the pane. Edit mode is
# unaffected because it CONSTRUCTS, so its `_domElement` is the live host.
#
# THE FIX THIS GATE NOW HOLDS. `monacoEditorAdoptInto` moves the CONTAINER,
# not the view alone. The view is a child of the container, so this is a
# superset of what the proc used to do, and it carries the ResizeObserver's
# only possible subject into the live pane with it. The moved container is
# stripped of its id and classes first — it is the previous
# `#editorComponent-{id}` isonim panel and the host is the new one, so nesting
# them unaltered would duplicate an id and apply `.code-editor`'s
# `width: 31.25em` twice. Every product selector over that subtree is a
# descendant one, so the extra level changes no match.
#
# Measured on the assembled bundle, same session, same splitter (2px from the
# editor pane's left edge):
#
#            pane        editor      layoutInfo   ruler vs pane   container
#   before   396 -> 576  396 -> 396  396          182px adrift    DETACHED
#   after    396 -> 576  396 -> 576  576            2px           connected
#
# Edit mode, the control arm, was 871 -> 1051 -> 871 with the editor following
# exactly both before and after the change.
#
# THE RECORD OF FOUR FAILED FIXES THAT USED TO BE HERE HAS BEEN WITHDRAWN, and
# withdrawing it is a finding in its own right. It listed "re-hosting Monaco's
# CONTAINER instead of its view" as measured NOT to work, on the grounds that
# `replaceWithIsoNimEditorPanel` throws the container straight back out, and it
# listed a `ResizeObserver` installed from `monacoEditorAdoptInto` as never
# reached because "the renderer carries the view across itself, so the view is
# never detached". Both readings were taken with instrumentation written as a
# multi-line `{.importjs: """ ... """.}`, which — as the note now standing above
# that proc cluster in `editor.nim` records — does not execute at all while the
# emitted `ui.js` still visibly contains it. Re-measured in a real tab with a
# 50ms DOM sampler, the container and the view go detached TOGETHER at the mode
# transition and the view alone returns 170ms later, which is exactly
# `reattachMonacoIfDetached` running. Container re-hosting is not defeated by
# the renderer; it was never observed.
#
# The 5x5 that a previous change in this area left behind shares the root cause:
# before this fix a bare `layout()` meant "re-measure `_domElement`", the
# detached one, so Monaco read 0 and
# `ElementSizeObserver.measureReferenceDomElement` clamped it with
# `Math.max(5, ...)`. The floor is asserted here in the same run as the resize,
# so a fix that bought the resize back by re-introducing the clamp fails.
#
# WHAT THIS GATE ASSERTS THAT NOTHING ELSE DOES
# ---------------------------------------------
# `editor_font_survives_mode_switch.spec.ts` and
# `editor_is_writable_after_stop.spec.ts` both cross this same re-host, and both
# pass on a frozen editor: one reads the font option, the other reads
# `readOnly`. Neither ever measures a box. `ci/test/web-renderer-mounts.sh`
# measures pane proportions but never resizes anything. Nothing in the repo
# drags a divider and then looks at the editor.
#
# THE ASSERTIONS ARE INVARIANTS, NOT CONSTANTS, AND NOT DELTAS. Nothing here
# names a pixel width. Each leg requires that the drag actually moved the pane —
# either edge, since the divider may be on either side — and then that THE
# EDITOR FILLS ITS PANE: same width, same left edge, same right edge, within a
# tolerance. "The editor's width changed by as much as the pane's" was the first
# shape and it is weaker: it is satisfiable by an editor that was already wrong
# and stayed wrong by the same amount, and it cannot be evaluated at all on a
# drag of the left-hand divider, which moves the pane's origin.
#
# THE 5x5 IS COVERED IN THE SAME BREATH. Every sample is refused if the editor
# is at Monaco's `Math.max(5, ...)` floor. A fix for the resize that
# re-introduced the clamp — measured previously as "a 5x5 editor showing two
# lines inside an 880x902 pane" — fails here rather than trading one report for
# the other.
#
# Usage:  bash ci/test/editor-resize-follows-pane.sh
# Env:    CT_WEB_BUNDLE_DIR    a tree already assembled by web-bundle-assets.sh
#         CT_RESIZE_GATE_TREE  a tree to serve AS IS (skips the renderer rebuild)
#         CT_RESIZE_GATE_PORT  static server port (default 8797)
#         CT_NOIR_WASM_COMPILER / CT_NOIR_WASM_TRACER / CT_REPLAY_ENGINE_DIR
#                              inputs for the bundle assembly, when it runs

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

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
[ -z "${CT_RESIZE_GATE_TREE:-}" ] && required_tools="${required_tools} nim"
for tool in ${required_tools}; do
	command -v "${tool}" >/dev/null 2>&1 || {
		echo "editor-resize-follows-pane.sh: no '${tool}' on PATH." >&2
		echo "  remedy: run inside the dev shell (direnv exec ${repo_root} ...)" >&2
		exit 2
	}
done
if [ ! -d node_modules/playwright ] && ! node -e "require('playwright')" >/dev/null 2>&1; then
	echo "editor-resize-follows-pane.sh: node_modules/playwright is missing;" >&2
	echo "  remedy: npm install, or run inside the dev shell." >&2
	exit 2
fi

cache="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}/editor-resize"
mkdir -p "${cache}"

# ---------------------------------------------------------------------------
# The tree under test.
# ---------------------------------------------------------------------------
if [ -n "${CT_RESIZE_GATE_TREE:-}" ]; then
	tree="${CT_RESIZE_GATE_TREE}"
	echo "Serving a pre-built tree as-is: ${tree}"
else
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

	# REBUILD THE RENDERER INTO A COPY. A pre-assembled `CT_WEB_BUNDLE_DIR`
	# carries whatever `ui.js` it was built with, and the change under test is
	# entirely in the renderer — measuring the stale one would be reporting on a
	# tree nobody edited.
	served="${cache}/tree"
	if [ -e "${served}" ]; then
		chmod -R u+w "${served}" 2>/dev/null || true
		rm -rf "${served}"
	fi
	cp -R "${bundle}" "${served}"
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

	# The pane and editor boxes are CSS-driven, so a stale theme would measure
	# the wrong build.
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

echo "SUBJECT"
note "tree: ${tree}"
if [ -f "${tree}/ui.js" ]; then
	note "renderer: ui.js ($(wc -c <"${tree}/ui.js" | tr -d ' ') bytes, sha256 $(shasum -a 256 "${tree}/ui.js" | cut -c1-16))"
fi
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

port="${CT_RESIZE_GATE_PORT:-8797}"
server_pid=""
stop_server() {
	if [ -n "${server_pid}" ]; then
		kill "${server_pid}" 2>/dev/null || true
		wait "${server_pid}" 2>/dev/null || true
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
set +e
node ci/test/editor_resize_follows_pane_probe.mjs \
	"http://127.0.0.1:${port}/noir" "${cache}/report.json" \
	>"${cache}/probe.log" 2>"${cache}/probe.err"
probe_rc=$?
set -e
stop_server
if [ "${probe_rc}" -ne 0 ] || [ ! -s "${cache}/report.json" ]; then
	echo "  the probe produced no report" >&2
	head -20 "${cache}/probe.err" >&2
	exit 2
fi
echo

# ---------------------------------------------------------------------------
# Reading the report.
# ---------------------------------------------------------------------------
q() {
	## One value out of the report, by python expression over `d`.
	python3 -c "
import json
d = json.load(open('${cache}/report.json'))


def g(*path):
    cur = d
    for p in path:
        if cur is None:
            return None
        cur = cur.get(p) if isinstance(cur, dict) else None
    return cur


print($1)
"
}

# THE TOLERANCE. The pane's content box and the editor's view node are not the
# same rectangle — `.lm_content` carries padding and the container a border
# radius — so the editor is never pixel-identical to the pane. What must hold
# is that a CHANGE in one is matched by the same change in the other. 12px is
# generous against those trimmings and far tighter than the 180px drag.
TOL=12

leg_report() {
	## Print the raw geometry of one leg, so a failure says what it saw.
	local leg="$1"
	q "'pane %sw -> %sw, editor %sw -> %sw, %s x %s -> %s, container connected %s -> %s, viewLines %s -> %s, drag %s dx=%s after %s attempt(s)%s' % (
        (g('legs','${leg}','before','pane') or {}).get('w'),
        (g('legs','${leg}','after','pane') or {}).get('w'),
        (g('legs','${leg}','before','view') or {}).get('w'),
        (g('legs','${leg}','after','view') or {}).get('w'),
        (g('legs','${leg}','after') or {}).get('rightEdgeName'),
        (g('legs','${leg}','before','rightEdge') or {}).get('x'),
        (g('legs','${leg}','after','rightEdge') or {}).get('x'),
        (g('legs','${leg}','before') or {}).get('containerConnected'),
        (g('legs','${leg}','after') or {}).get('containerConnected'),
        (g('legs','${leg}','before') or {}).get('viewLines'),
        (g('legs','${leg}','after') or {}).get('viewLines'),
        (g('legs','${leg}') or {}).get('direction'),
        (g('legs','${leg}') or {}).get('dx'),
        (g('legs','${leg}') or {}).get('attempts'),
        ' REVERSED' if (g('legs','${leg}') or {}).get('reversed') else '')"
}

delta() {
	## after-minus-before for one box dimension of one leg. 'none' when absent,
	## which every check treats as a failure rather than as a zero.
	local leg="$1" node="$2" dim="$3"
	q "(lambda b, a: 'none' if (b is None or a is None or b.get('${dim}') is None or a.get('${dim}') is None) else str(a['${dim}'] - b['${dim}']))(
        g('legs','${leg}','before','${node}'), g('legs','${leg}','after','${node}'))"
}

within() {
	## |a - b| <= TOL, over two integers that may be the string 'none'.
	local a="$1" b="$2"
	python3 -c "
import sys
a, b = sys.argv[1], sys.argv[2]
if a == 'none' or b == 'none':
    print('no')
else:
    print('ok' if abs(int(a) - int(b)) <= ${TOL} else 'no')
" "${a}" "${b}"
}

fills_pane() {
	## Does the editor's box occupy its pane? Prints "ok|detail" or "no|detail".
	## Width, left edge and right edge, so a box that is the right SIZE in the
	## wrong PLACE is not accepted.
	local leg="$1" phase="$2"
	q "(lambda p, v: 'no|pane or editor not measured' if (not p or not v) else
        ('%s|editor %sx%s at x=%s..%s, pane %sx%s at x=%s..%s' % (
            'ok' if (abs(v['w'] - p['w']) <= ${TOL} and abs(v['x'] - p['x']) <= ${TOL}
                     and abs(v['right'] - p['right']) <= ${TOL}) else 'no',
            v['w'], v['h'], v['x'], v['right'], p['w'], p['h'], p['x'], p['right'])))(
        g('legs','${leg}','${phase}','pane'), g('legs','${leg}','${phase}','view'))"
}

edge_at_pane() {
	## Is the right-edge furniture at the pane's right edge?
	local leg="$1" phase="$2"
	q "(lambda p, r: 'no|no furniture measured' if (not p or not r) else
        ('%s|%s ends at x=%s, pane ends at x=%s, %spx adrift' % (
            'ok' if abs(r['right'] - p['right']) <= ${TOL} else 'no',
            (g('legs','${leg}','${phase}') or {}).get('rightEdgeName'),
            r['right'], p['right'], abs(r['right'] - p['right']))))(
        g('legs','${leg}','${phase}','pane'), g('legs','${leg}','${phase}','rightEdge'))"
}

nonzero() {
	## A pane that did not move makes its whole leg vacuous.
	local v="$1"
	python3 -c "
import sys
v = sys.argv[1]
print('no' if v == 'none' else ('ok' if abs(int(v)) > ${TOL} else 'no'))
" "${v}"
}

# ---------------------------------------------------------------------------
echo "PRECONDITIONS"
# ---------------------------------------------------------------------------
fatal="$(q "g('fatal') or ''")"
ck "$([ -z "${fatal}" ] && echo ok || echo no)" \
	"the probe ran to completion${fatal:+ — it did not: ${fatal}}"

gt0() {
	## '${1}' > 0, tolerating the string 'None' that a missing reading arrives
	## as. In python because `[ None -gt 0 ]` is a shell ERROR, not a false.
	python3 -c "
import sys
try:
    print('ok' if int(sys.argv[1]) > 0 else 'no')
except (TypeError, ValueError):
    print('no')
" "$1"
}

splitters="$(q "(g('splitters') or {}).get('column')")"
ck "$(gt0 "${splitters}")" \
	"the layout has a column splitter to drag (${splitters}) — without one this gate measures nothing"

boot_lines="$(q "(g('legs','editBoot') or {}).get('viewLines')")"
ck "$(gt0 "${boot_lines}")" \
	"the editor painted source at boot (${boot_lines} view-lines)"

boot_via="$(q "(g('legs','editBoot') or {}).get('via')")"
note "editor resolved via: ${boot_via}"
echo

# ---------------------------------------------------------------------------
# The two modes, two directions each. THE SAME ASSERTIONS BOTH TIMES — Edit is
# the control arm, and a fix that made Debug follow by breaking Edit fails here.
# ---------------------------------------------------------------------------
assert_leg() {
	local leg="$1" label="$2"

	local dpane dpanex sbname
	dpane="$(delta "${leg}" pane w)"
	dpanex="$(delta "${leg}" pane x)"
	sbname="$(q "(g('legs','${leg}','after') or {}).get('rightEdgeName')")"

	note "$(leg_report "${leg}")"

	# (a) THE INSTRUMENT. If the drag moved neither edge of the pane, nothing
	# below means anything, and this says so instead of passing.
	#
	# BOTH EDGES, because the divider a user grabs may be on either side. The
	# first shape of this compared only widths, and a drag of the LEFT divider
	# — which moves the pane's origin and its width together — was scored
	# against a right edge that had not moved at all.
	ck "$([ "$(nonzero "${dpane}")" = ok ] || [ "$(nonzero "${dpanex}")" = ok ] && echo ok || echo no)" \
		"${label}: the drag actually moved the pane (Δwidth ${dpane}px, Δx ${dpanex}px) — the gesture reached GoldenLayout"

	# (b) THE REPORT'S SUBJECT: THE EDITOR FILLS ITS PANE, AFTERWARDS.
	#
	# An invariant, not a delta. "The editor's width changed by as much as the
	# pane's" is satisfiable by an editor that was already the wrong size and
	# stayed wrong by the same amount, and it cannot be checked at all on a drag
	# that moves the pane's origin. "The editor occupies its pane" is the thing
	# the user is actually reporting the absence of, and it is true before the
	# drag as well as after, so it also catches a fix that only holds at rest.
	local fills
	fills="$(fills_pane "${leg}" after)"
	ck "$(printf '%s' "${fills}" | cut -d'|' -f1)" \
		"${label}: the editor fills its pane afterwards ($(printf '%s' "${fills}" | cut -d'|' -f2-))"

	# (c) THE SURFACE THE USER NAMED. "The scrollbar stays in place."
	#
	# Asserted as position, not movement: the right-edge furniture must sit AT
	# the pane's right edge. On the broken build the editor keeps its old width
	# while the pane grows, so the ruler ends up stranded well inside the pane —
	# which is what "stays in place" looks like from the outside. The subject is
	# refused if it has no geometry, because comparing a 0x0 element against
	# anything is comparing two zeroes.
	ck "$([ "${sbname}" != "none" ] && [ "${sbname}" != "None" ] && echo ok || echo no)" \
		"${label}: there is right-edge furniture to measure (${sbname}) — a 0x0 element is not a subject"
	local edge
	edge="$(edge_at_pane "${leg}" after)"
	ck "$(printf '%s' "${edge}" | cut -d'|' -f1)" \
		"${label}: the ${sbname} sits at the pane's right edge ($(printf '%s' "${edge}" | cut -d'|' -f2-))"

	# (d) Monaco's own idea of its size agrees with the pane. A view node
	# resized by CSS while Monaco still believed the old geometry would render
	# its scrollbar, minimap and wrapping against stale numbers.
	local dli
	dli="$(q "(lambda p, l: 'none' if (not p or not l or p.get('w') is None or l.get('w') is None) else str(l['w'] - p['w']))(
        g('legs','${leg}','after','pane'), g('legs','${leg}','after','layoutInfo'))")"
	ck "$(within "${dli}" 0)" \
		"${label}: Monaco's own layoutInfo matches the pane afterwards (off by ${dli}px)"

	# (e) THE 5x5 GUARD, on the settled sample. Monaco clamps a zero
	# measurement to `Math.max(5, ...)`, and that clamp is how a previous fix in
	# this area produced a 5x5 editor inside an 880x902 pane.
	local aw ah alines floor_ok
	aw="$(q "(g('legs','${leg}','after','view') or {}).get('w')")"
	ah="$(q "(g('legs','${leg}','after','view') or {}).get('h')")"
	alines="$(q "(g('legs','${leg}','after') or {}).get('viewLines')")"
	# Compared in python, not in `[`, because a missing measurement arrives as
	# the string 'None' and `[ None -gt 5 ]` is a shell ERROR, not a false.
	floor_ok="$(python3 -c "
import sys
w, h, n = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    print('ok' if int(w) > 5 and int(h) > 5 and int(n) > 0 else 'no')
except (TypeError, ValueError):
    print('no')
" "${aw}" "${ah}" "${alines}")"
	ck "${floor_ok}" \
		"${label}: the editor is not at Monaco's 5px floor afterwards (${aw}x${ah}, ${alines} view-lines)"

	# (f) THE EDITOR IS ACTUALLY IN THE PANE IT IS BEING COMPARED AGAINST.
	# Without this, an editor rendered somewhere else entirely could still show
	# matching deltas by coincidence.
	local inpane conn
	inpane="$(q "(g('legs','${leg}','after') or {}).get('viewInPane')")"
	conn="$(q "(g('legs','${leg}','after') or {}).get('viewConnected')")"
	ck "$([ "${inpane}" = "True" ] && [ "${conn}" = "True" ] && echo ok || echo no)" \
		"${label}: the editor is live and inside the pane it was measured against (inPane=${inpane} connected=${conn})"

	# (g) THE READING THAT CANNOT PASS WHILE THE DEFECT IS PRESENT.
	#
	# Every check above is geometry, and geometry is satisfiable by accident: an
	# editor that is the right size at rest passes (b), (d) and (e) without
	# being able to respond to anything. `automaticLayout: true` is a
	# ResizeObserver on Monaco's `_domElement` AND ON NOTHING ELSE, installed
	# once in the constructor and never re-pointed — so an editor whose
	# container is detached cannot follow its pane, whatever its current box
	# says. Measured on the pre-fix build: `False` in both debug legs while
	# three of the geometry checks in `debug/grow` were green.
	#
	# This is the check that makes a vacuous pass impossible, and it is asserted
	# in EDIT mode too, where it has always been true — a fix that repaired
	# Debug by detaching Edit's container would fail here rather than trade one
	# report for the other.
	local contconn
	contconn="$(q "(g('legs','${leg}','after') or {}).get('containerConnected')")"
	ck "$([ "${contconn}" = "True" ] && echo ok || echo no)" \
		"${label}: Monaco's container — the only element its ResizeObserver watches — is in the document (connected=${contconn})"
}

echo "EDIT MODE — the control arm, which works today and must keep working"
assert_leg editGrow "edit/grow"
assert_leg editShrink "edit/shrink"
echo

echo "DEBUG MODE — the reported case"
reached="$(q "(g('run') or {}).get('reached')")"
debug_checks=0
if [ "${reached}" = "True" ]; then
	assert_leg debugGrow "debug/grow"
	assert_leg debugShrink "debug/shrink"

	# ---------------------------------------------------------------------
	# THE SECOND ADOPT. Out to Edit, back into Debug, and the same two drags.
	#
	# The re-host is what breaks the editor, so an editor that has been
	# re-hosted TWICE is the case that separates "the geometry was reconciled
	# once, at adoption" from "the editor can follow its pane". A fix of the
	# first kind passes every check above and fails here.
	# ---------------------------------------------------------------------
	again_mode="$(q "((g('intoDebugAgain') or {}).get('state') or {}).get('mode')")"
	again_lines="$(q "((g('intoDebugAgain') or {}).get('state') or {}).get('viewLines')")"
	ck "$([ "${again_mode}" = "0" ] && [ "$(gt0 "${again_lines}")" = ok ] && echo ok || echo no)" \
		"round trip: Edit and back into Debug reached a second Debug mode with source on screen (mode=${again_mode}, ${again_lines} view-lines)"
	assert_leg debugAgainGrow "debug-again/grow"
	assert_leg debugAgainShrink "debug-again/shrink"
	debug_checks=33
else
	# NOT SILENTLY SKIPPED. A gate whose subject was absent must say so and go
	# red, or an unassembled bundle reads as a working product.
	reason="$(q "(g('run') or {}).get('reason') or 'no reason recorded'")"
	ck no "debug mode was reached at all — it was not, so the REPORTED case went unmeasured: ${reason}"
	debug_checks=1
fi
echo

# ---------------------------------------------------------------------------
# THE COUNT ITSELF, so a check skipped by an early return cannot read as a
# pass. Raise this deliberately when adding one.
# ---------------------------------------------------------------------------
EXPECTED_CHECKS=$((3 + 16 + debug_checks))
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
echo "  screenshots: ${cache}/report-debug-*.png"
exit 1
