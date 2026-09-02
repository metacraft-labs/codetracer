#!/usr/bin/env bash
#
# noir-replay-in-browser.sh — a Run, then a DEBUGGER over the trace it made.
# In a real tab, against the assembled publish tree.
#
# WHAT THIS ASSERTS THAT NOTHING ELSE DOES
# ----------------------------------------
# `ci/test/noir-build-in-browser.sh` proves a gesture reaches ~19 MB of Noir
# compiler and that a result is painted. It stops where the trace is produced.
# `ci/test/web-bundle-assets.sh` proves the engine's two files are placed and
# declared. `viewmodel/tests/unit/test_replay_engine_{vfs,boot}.nim` prove the
# `MemoryTrace` becomes the right files and that the handshake is ordered.
#
# All of that can be true of a tab that never opens a debugger, and it was.
# This gate's subject is the thing after the trace: the session steps, the
# positions resolve, and the SOURCE OF THE LINE BEING EXECUTED IS ON SCREEN.
#
# THE TWO FALSE PASSES, and they are why every headline number here is a
# NUMBER rather than a boolean:
#
#   1. A TRACE THAT LOADS AND REPORTS SUCCESS CARRYING ZERO STEPS. An artifact
#      compiled without debug instrumentation traces to one event and no
#      steps; both wasm modules answer `ok` and the engine accepts the
#      `trace.json`. So `stepCount` and the number of DISTINCT positions the
#      session visited are both asserted.
#   2. A SESSION THAT "RESOLVES" POSITIONS THAT ARE ALL `missingPath`. In a
#      browser every recorded path is that case unless the trace's own source
#      reaches the engine's VFS under the recorded key. So `resolvedCount` and
#      `missingPathCount` are asserted against each other, and the editor's
#      PAINTED text is asserted separately from both — a session can resolve
#      every position and still show a user nothing.
#
# PAINTED TEXT, NEVER `innerText`. `web-renderer-mounts.sh` records what that
# distinction cost: its "there is a product on this page" check was satisfied
# almost entirely by a 379-character developer diagnostic at (0,0) under the
# topbar that no user could see. Every line counted here is hit-tested.
#
# Usage:  bash ci/test/noir-replay-in-browser.sh
# Env:    CT_WEB_BUNDLE_DIR       a tree already assembled by web-bundle-assets.sh
#         CT_REPLAY_ENGINE_DIR    a wasm-pack `pkg/`, when a bundle is assembled here
#         CT_NOIR_WASM_COMPILER   likewise
#         CT_NOIR_WASM_TRACER     likewise
#         CT_NOIR_WASM_REF        provenance; without it the page drops the modules
# Exit:   0 all assertions held, 1 otherwise, 2 could not run.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)"
cd "${repo_root}" || exit 2

# shellcheck source=ci/lib/published-asset.sh
# shellcheck disable=SC1091 # resolved at runtime from $repo_root
source "${repo_root}/ci/lib/published-asset.sh"

remove_published() {
	## Delete a bundle's copy of an asset, and REFUSE if there was none.
	##
	## The whole value of a deletion-based mutation arm is that the file was
	## there and now is not. `rm -f` cannot tell those apart, so an arm built on
	## it goes on "passing" — silently mutating nothing — the moment the name it
	## deletes stops matching. That is precisely what content-addressed
	## filenames did to arms A and B.
	local tree="$1" stem="$2" rel
	if ! rel="$(published_asset_rel "${tree}" "${stem}")"; then
		echo "  cannot mutate: ${tree} has no ${stem} to remove, so this arm would measure an unmutated tree" >&2
		return 1
	fi
	rm -f "${tree}/${rel}"
	if [ -e "${tree}/${rel}" ]; then
		echo "  cannot mutate: ${tree}/${rel} survived its own removal" >&2
		return 1
	fi
	note "mutated ${tree##*/}: removed ${rel}"
}

cache="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}/noir-replay-in-browser"
rm -rf "${cache}"
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

for tool in node python3 jq; do
	command -v "${tool}" >/dev/null 2>&1 || {
		echo "noir-replay-in-browser.sh: no '${tool}' on PATH." >&2
		echo "  remedy: run inside the dev shell (direnv exec ${repo_root} ...)" >&2
		exit 2
	}
done
node -e "require('playwright')" >/dev/null 2>&1 || {
	echo "noir-replay-in-browser.sh: playwright is not installed." >&2
	echo "  remedy: npm install, inside the dev shell" >&2
	exit 2
}

echo "=== a Run in a browser opens a debugger over the trace it made ==="
echo

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

# THE PRECONDITIONS, CHECKED RATHER THAN ASSUMED. Each of these absent makes
# every arm below vacuously green in the most misleading way available: the
# page refuses by name, the pane paints the refusal, and a careless assertion
# on "the session reported something" passes.
#
# RESOLVED BY STEM, NOT BY LITERAL PATH. Every file below is published as
# `<name>.<digest>.<ext>`, so the literal names this loop used to hold are in
# no bundle: it would have aborted on the first one with a message blaming an
# unset environment variable, on a tree that was perfectly assembled.
# `published_asset_rel` refuses loudly when it finds zero — or two, which is a
# previous assembly's copy still in the tree — so a name that stops resolving
# stays an abort rather than becoming an empty string.
# A plain variable for the one path read later, not an associative array: this
# needs bash 4 and `verify-deployed-bytes.sh` next door is explicitly the
# harness a human runs by hand after a cache purge, where `/bin/bash` on macOS
# is still 3.2. One lookup does not need a map.
engine_wasm_rel=""
resolved_assets=0
for required in assets/noir_wasm.wasm assets/noir_tracer_wasm.wasm \
	assets/db_backend_bg.wasm assets/db_backend.js assets/replay-worker.js; do
	if ! rel="$(published_asset_rel "${bundle}" "${required}")"; then
		echo "  the assembled tree at ${bundle} ships no ${required}," >&2
		echo "  under that name or a content-addressed one," >&2
		echo "  so this gate would measure a deployment that cannot replay." >&2
		echo "  Set CT_NOIR_WASM_COMPILER / CT_NOIR_WASM_TRACER /" >&2
		echo "  CT_REPLAY_ENGINE_DIR / CT_NOIR_WASM_REF and re-assemble." >&2
		exit 2
	fi
	if [ "${required}" = "assets/db_backend_bg.wasm" ]; then
		engine_wasm_rel="${rel}"
	fi
	resolved_assets=$((resolved_assets + 1))
	note "resolved ${required} -> ${rel}"
done
# The count, asserted, because the loop above is what makes every arm below
# non-vacuous and an empty `for` list would have skipped it in silence.
if [ "${resolved_assets}" -ne 5 ]; then
	echo "  resolved ${resolved_assets} of 5 required assets — the precondition loop did not run over its subjects" >&2
	exit 2
fi
if ! grep -q 'replay-engine' "${bundle}/index.html"; then
	echo "  the entry document declares no replay-engine module, so the worker" >&2
	echo "  would be configured with no URL for it and the session would refuse" >&2
	echo "  before constructing anything." >&2
	exit 2
fi
engine_bytes="$(wc -c <"${bundle}/${engine_wasm_rel}" | tr -d ' ')"
note "bundle: ${bundle}"
note "engine: ${engine_bytes} bytes, declared in the entry document"
echo

# The static server, `.wasm` as `application/wasm`. The content type is
# load-bearing and not a detail of this harness: `WebAssembly.compileStreaming`
# REQUIRES it, and Cloudflare Pages was measured answering an absent `.wasm`
# path with the entry document at HTTP 200 and `text/html`.
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
	node ci/test/noir_replay_probe.mjs "http://127.0.0.1:${port}/noir" \
		60000 6 >"${out}" 2>"${out}.err"
	local rc=$?
	stop_server
	return ${rc}
}

field() { jq -r "$2" <"$1"; }

# ---------------------------------------------------------------------------
echo "The control: a Run, then a session over the trace it produced"
# ---------------------------------------------------------------------------
control="${cache}/control.json"
if ! run_probe "${bundle}" "${control}"; then
	echo "  the probe did not complete; see ${control}.err" >&2
	tail -20 "${control}.err" >&2
	exit 2
fi

mounted="$(field "${control}" '.mounted')"
load_error="$(field "${control}" '.loadError')"
[ "${load_error}" = "" ] || note "loadError: ${load_error}"
ck "$([ "${mounted}" = true ] && echo ok || echo no)" \
	"the renderer mounted"

engine_fetched="$(field "${control}" '.engineFetched')"
ck "$([ "${engine_fetched}" = true ] && echo ok || echo no)" \
	"the tab FETCHED the replay engine (db_backend_bg.wasm over the wire)"

vfs_writes="$(field "${control}" '.vfsWrites | length')"
source_views="$(field "${control}" '.sourceViewsWritten')"
# AT LEAST FOUR: `trace.json`, `trace_metadata.json`, and both spellings of at
# least one source file. Asserted as a count because a boot that wrote the
# trace and forgot the source reaches `ready` just as happily and then resolves
# every position to `missingPath`.
ck "$([ "${vfs_writes}" -ge 4 ] && echo ok || echo no)" \
	"the trace AND its source were written into the engine's VFS (${vfs_writes} writes)"
ck "$([ "${source_views}" -ge 1 ] && echo ok || echo no)" \
	"the trace carried ${source_views} embedded source view(s)"

step_count="$(field "${control}" '.stepCount')"
ck "$([ "${step_count}" -gt 1 ] && echo ok || echo no)" \
	"the trace carries ${step_count} steps — not the one-event-zero-steps trace both modules call ok"

distinct="$(field "${control}" '.distinctLines | length')"
resolved="$(field "${control}" '.resolvedCount')"
missing="$(field "${control}" '.missingPathCount')"
ck "$([ "${resolved}" -gt 0 ] && echo ok || echo no)" \
	"the session resolved ${resolved} position(s)"
# THE SECOND FALSE PASS, as an assertion rather than a note: a session that
# "resolves" while every position is missingPath reads as success everywhere
# else in this file.
ck "$([ "${missing}" -eq 0 ] && echo ok || echo no)" \
	"and NONE of them was missingPath (${missing})"
ck "$([ "${distinct}" -gt 1 ] && echo ok || echo no)" \
	"stepping advanced through ${distinct} distinct position(s)"

# AND THE CARET MOVED IN THE EDITOR THE USER IS LOOKING AT. `editor.nim:675`
# gives the current step's line the Monaco class `on`, so this reads the
# highlight itself rather than the engine's opinion of where it is. "A step
# control exists" and "stepping moves the caret in the painted editor" are
# different claims, and only the second is a debugger — a session can advance
# its position and leave the editor on line 1 forever.
step_button="$(field "${control}" '.stepButtonPresent')"
carets="$(field "${control}" '.caretPositions | length')"
wait_ms="$(field "${control}" '.stepButtonWaitMs')"
ck "$([ "${step_button}" = true ] && echo ok || echo no)" \
	"the debugger's step control is mounted (Run leaves edit mode), after ${wait_ms}ms"
ck "$([ "${carets}" -gt 1 ] && echo ok || echo no)" \
	"and stepping moved the painted caret through ${carets} position(s)"

painted_chars="$(field "${control}" '.editorPaintedChars')"
raw_lines="$(field "${control}" '.editorRawLineCount')"
editors="$(field "${control}" '.editorWidgetCount')"
no_source="$(field "${control}" '.noSourceVisible')"
# THE ZERO, MADE LEGIBLE. `editorPaintedChars: 0` is equally consistent with
# "no editor on this layout" and "an editor behind the BUILD pane", and those
# need opposite fixes. Reported before the assertion so a failure names which
# one it is instead of leaving the next reader to guess.
before_dismiss="$(field "${control}" '.editorPaintedCharsBeforeDismiss')"
note "editor widgets: ${editors}, raw .view-line elements: ${raw_lines}, painted chars: ${before_dismiss} before dismissing the BUILD overlay, ${painted_chars} after"
# THE ACCEPTANCE. Painted, hit-tested text in the editor — not `innerText`,
# not a tab title, not a resolved location.
ck "$([ "${painted_chars}" -gt 40 ] && echo ok || echo no)" \
	"the editor PAINTED ${painted_chars} characters of source, after the user dismisses the BUILD overlay their own Run opened"
ck "$([ "${no_source}" = false ] && echo ok || echo no)" \
	"and the NO SOURCE view is not what the user is looking at"

# THE REMAINING RED, NAMED (2026-09-02).
#
# Six traps inside `db_backend_bg.wasm`, one per step, on the
# `ct/load-locals` that follows each `next`. The panic message, once the probe
# stopped truncating `console.error` at 500 characters:
#
#   panicked at src/c_compat.rs:214:5:
#   internal error: entered unreachable code:
#   Running in wasm mode. Should not be calling `vsprintf`
#
# So it is NOT the clock hazard `wall_clock.rs` warns about, which was the
# obvious guess and names this very request ("`ct/load-locals` via
# `WallClockDeadline`") among three paths that died that way. It is the wasm
# C-compat layer: something on the locals path reaches C code that formats a
# string, and `vsprintf` is a deliberate `unreachable!()` stub in the wasm
# build. A panic there compiles to `unreachable`, which is why it presents as
# a trap rather than an error response.
#
# MEASURED FIRST, so the next reader does not re-derive it. Driving the NATIVE
# `replay-server` over DAP with the same launch/next/ct-load-locals sequence:
#
#   * absolute-path trace (spike shape), lang 0..20 swept  -> success, no panic
#   * browser-shaped trace (relative paths, workdir = the
#     trace folder, no source on disk)                     -> success, no panic
#
# Neither the locals logic, nor the `lang` argument, nor the shape of what we
# hand it. Wasm-specific, and now with a file and a line.
errors="$(field "${control}" '.pageErrors | length')"
ck "$([ "${errors}" -eq 0 ] && echo ok || echo no)" \
	"zero uncaught page errors (${errors})"

# ---------------------------------------------------------------------------
# THE ROUND TRIP: edit, Run, step, return — and the edit is still there.
#
# Everything above proves the MIDDLE of that sentence. `web_entry_surface`'s
# `noirStudioDebugLayout` states the whole of it — "Full surface, returnable —
# Run leaves edit mode for the normal CodeTracer debugging layout, and an
# explicit action comes back with the project as it was" — and calls itself
# "the first half".
#
# THE RETURN HALF WAS UNASSERTABLE UNTIL NOW, and not for want of trying: with
# no persistence, "comes back with the project as it was" was satisfied by
# nothing being changeable. A project that cannot be edited trivially returns
# unchanged, and every check of it would have passed against a product that
# threw the user's work away, because there was no work to throw. Edit
# persistence is what gives the claim content, which is why this assertion
# lands with it and not before.
#
# FOUR CLAIMS, because the round trip has four places to break and three of
# them read as success from the others' point of view:
#   1. the edit reached the model at all (otherwise everything below is
#      vacuous — "the marker survived" is trivially true of a marker that was
#      never typed, and `editStillPresentAfterReturn` would be comparing two
#      absences);
#   2. the return GESTURE was delivered (a chord swallowed by Monaco leaves
#      the tab in debug mode, which is not the product refusing to return);
#   3. the tab is genuinely back in edit mode — writable editors AND no
#      debugger-only pane still mounted, because `data.ui.mode` flipping is
#      not the same as the layout coming back;
#   4. and the edit is still there.
edit_reached="$(field "${control}" '.editReachedModel')"
return_sent="$(field "${control}" '.returnGestureSent')"
returned="$(field "${control}" '.returnedToEditMode')"
editable="$(field "${control}" '.editorEditableAfterReturn')"
survived="$(field "${control}" '.editStillPresentAfterReturn')"
rt_error="$(field "${control}" '.roundTripError')"
marker="$(field "${control}" '.editMarker')"
[ "${rt_error}" = "" ] || note "round-trip error: ${rt_error}"
note "round trip marker: ${marker}"
# THE INPUTS TO THE MODE VERDICT, printed before the assertions that read them.
# `editorEditableAfterReturn: false` beside `editorWidgetCount: 1` is equally
# consistent with "the editor came back read-only" and "`getEditors` is not a
# function in this Monaco build, so the probe measured nothing" -- and those
# need opposite fixes. `hasGetEditors` is what separates them.
note "mode after return: $(jq -c '.modeStateAfterReturn' <"${control}")"

ck "$([ "${edit_reached}" = true ] && echo ok || echo no)" \
	"the user's edit reached the editor's model before Run (so the checks below are not comparing two absences)"
ck "$([ "${return_sent}" = true ] && echo ok || echo no)" \
	"the return gesture (ctrl+f5) was delivered"
ck "$([ "${editable}" = true ] && echo ok || echo no)" \
	"the editors are writable again — switchToEdit ran, not just the mode flag"
ck "$([ "${returned}" = true ] && echo ok || echo no)" \
	"and the edit layout came back: no debugger-only pane is still mounted"
# THE SENTENCE ITSELF.
ck "$([ "${survived}" = true ] && echo ok || echo no)" \
	"edit, Run, step, return — and the edit is STILL THERE"

note "replay milestones:"
jq -r '.replayLines[]' <"${control}" | sed 's/^/        /'
note "engine requests:"
jq -r '.engineRequests[] | "        \(.status) \(.contentType) \(.bytes) \(.url)"' <"${control}"
note "why lines were not counted (first 4):"
jq -r '.editorRejected[0:4][]' <"${control}" | sed 's/^/        /'
note "painted (first 6):"
jq -r '.editorPaintedLines[0:6][]' <"${control}" | sed 's/^/        /'
echo

# ---------------------------------------------------------------------------
echo "Mutation arm A: the engine's wasm is not served"
echo "    Reddens the FETCH assertion. A deployment that declares an engine"
echo "    and serves a 404 must not read as a session that simply had no"
echo "    trace to open."
# ---------------------------------------------------------------------------
arm_a="${cache}/arm-a"
rm -rf "${arm_a}"
cp -RL "${bundle}" "${arm_a}" 2>/dev/null
chmod -R u+w "${arm_a}"
# THE FILE I DELETE MUST HAVE EXISTED. `rm -f` on a path that is not there
# succeeds silently, so once the published name carried a digest this arm
# copied the bundle, deleted nothing, and ran the probe against a PRISTINE
# tree — reddening "the engine was not fetched" against a working product,
# and, had the assertion ever been loosened, going green while mutating
# nothing. `mutate` in wasm-worker-session.sh has this guard; this arm did not.
remove_published "${arm_a}" assets/db_backend_bg.wasm || exit 2
arm_a_out="${cache}/arm-a.json"
if run_probe "${arm_a}" "${arm_a_out}"; then
	a_engine="$(field "${arm_a_out}" '.engineFetched')"
	a_carets="$(field "${arm_a_out}" '.caretPositions | length')"
	ck "$([ "${a_engine}" = false ] && echo ok || echo no)" \
		"arm A: the engine was not fetched"
	# NOT "no source was painted". The editor paints the bundled template
	# through `installTemplateHost` whether or not a replay session ever
	# opens, so that assertion was passing only because the CONTROL painted
	# nothing either — a vacuous arm that became visible the moment the
	# control went green. The caret is the discriminating signal: it moves
	# only when a live engine answers a step.
	ck "$([ "${a_carets}" -le 1 ] && echo ok || echo no)" \
		"arm A: and the caret never moved (${a_carets} position(s))"
	note "arm A engine requests:"
	jq -r '.engineRequests[] | "        \(.status) \(.contentType) \(.bytes) \(.url)"' <"${arm_a_out}"
	note "arm A milestones:"
	jq -r '.replayLines[]' <"${arm_a_out}" | sed 's/^/        /'
else
	ck no "arm A: the probe did not complete"
fi
echo

# ---------------------------------------------------------------------------
echo "Mutation arm B: the replay worker script is not served"
echo "    Reddens the SESSION assertion by a different route: the engine's"
echo "    bytes are there and nothing can construct a worker to hold them."
# ---------------------------------------------------------------------------
arm_b="${cache}/arm-b"
rm -rf "${arm_b}"
cp -RL "${bundle}" "${arm_b}" 2>/dev/null
chmod -R u+w "${arm_b}"
remove_published "${arm_b}" assets/replay-worker.js || exit 2
arm_b_out="${cache}/arm-b.json"
if run_probe "${arm_b}" "${arm_b_out}"; then
	b_resolved="$(field "${arm_b_out}" '.resolvedCount')"
	b_carets="$(field "${arm_b_out}" '.caretPositions | length')"
	ck "$([ "${b_resolved}" -eq 0 ] && echo ok || echo no)" \
		"arm B: the session resolved nothing (${b_resolved})"
	# Same correction as arm A, and for the same reason.
	ck "$([ "${b_carets}" -le 1 ] && echo ok || echo no)" \
		"arm B: and the caret never moved (${b_carets} position(s))"
else
	ck no "arm B: the probe did not complete"
fi
echo

# ---------------------------------------------------------------------------
echo "Mutation arm C: the return throws the user's work away"
echo "    Reddens the ROUND TRIP assertion, and only that one. 'The edit is"
echo "    still there' is a claim about a product that could have discarded"
echo "    it — switchToEdit clears every mapped component — so the assertion"
echo "    has to be shown failing against a return that does."
# ---------------------------------------------------------------------------
arm_c="${cache}/arm-c"
rm -rf "${arm_c}"
cp -RL "${bundle}" "${arm_c}" 2>/dev/null
chmod -R u+w "${arm_c}"
[ -s "${arm_c}/index.html" ] || {
	echo "  arm C: no index.html to instrument" >&2
	exit 2
}
python3 - "${arm_c}/index.html" <<'PY'
import sys
path = sys.argv[1]
html = open(path).read()
# Capture phase, so it runs whatever the product binds afterwards. The timer
# lets the product's own ctrl+f5 handling finish first: the arm simulates a
# RETURN THAT LOSES THE EDIT, not a keystroke that never arrives.
inject = """<script>
/* ARM C INSTRUMENT — a return that discards the user's edit. */
window.addEventListener('keydown', function (e) {
  if (e.ctrlKey && (e.key === 'F5' || e.keyCode === 116)) {
    setTimeout(function () {
      var ms = (window.monaco && window.monaco.editor
                && window.monaco.editor.getModels()) || [];
      ms.forEach(function (m) { try { m.setValue(''); } catch (err) {} });
    }, 400);
  }
}, true);
</script>"""
if '</body>' in html:
    html = html.replace('</body>', inject + '</body>', 1)
else:
    html += inject
open(path, 'w').write(html)
PY
# THE INSTRUMENT MUST BE IN THE FILE. The same lesson `remove_published`
# records one arm up: a mutation that silently did nothing runs the probe
# against a pristine tree and grades the control a second time.
grep -q 'ARM C INSTRUMENT' "${arm_c}/index.html" || {
	echo "  arm C: the instrument was not injected — this arm would grade the control" >&2
	exit 2
}
arm_c_out="${cache}/arm-c.json"
if run_probe "${arm_c}" "${arm_c_out}"; then
	c_reached="$(field "${arm_c_out}" '.editReachedModel')"
	c_sent="$(field "${arm_c_out}" '.returnGestureSent')"
	c_survived="$(field "${arm_c_out}" '.editStillPresentAfterReturn')"
	# THE ARM BREAKS ONE THING. If the typing or the gesture broke too, the
	# red below would not be evidence that the round-trip assertion works —
	# it would be evidence that the arm broke the probe.
	ck "$([ "${c_reached}" = true ] && echo ok || echo no)" \
		"arm C: the edit still reached the model (the arm breaks the RETURN, not the typing)"
	ck "$([ "${c_sent}" = true ] && echo ok || echo no)" \
		"arm C: the return gesture was still delivered"
	ck "$([ "${c_survived}" = false ] && echo ok || echo no)" \
		"arm C: reddens 'the edit is STILL THERE' — that assertion can fail"
else
	ck no "arm C: the probe did not complete"
fi
echo

echo "${checks} check(s), ${failures} failure(s)"
if [ "${failures}" -eq 0 ]; then
	echo "RESULT: OK — a Run in a browser opens a debugger and paints its source"
	exit 0
fi
echo "RESULT: FAILED — ${failures} check(s)"
exit 1
