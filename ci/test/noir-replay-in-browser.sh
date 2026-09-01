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
for required in assets/noir_wasm.wasm assets/noir_tracer_wasm.wasm \
	assets/db_backend_bg.wasm assets/db_backend.js assets/replay-worker.js; do
	if [ ! -f "${bundle}/${required}" ]; then
		echo "  the assembled tree at ${bundle} ships no ${required}," >&2
		echo "  so this gate would measure a deployment that cannot replay." >&2
		echo "  Set CT_NOIR_WASM_COMPILER / CT_NOIR_WASM_TRACER /" >&2
		echo "  CT_REPLAY_ENGINE_DIR / CT_NOIR_WASM_REF and re-assemble." >&2
		exit 2
	fi
done
if ! grep -q 'replay-engine' "${bundle}/index.html"; then
	echo "  the entry document declares no replay-engine module, so the worker" >&2
	echo "  would be configured with no URL for it and the session would refuse" >&2
	echo "  before constructing anything." >&2
	exit 2
fi
engine_bytes="$(wc -c <"${bundle}/assets/db_backend_bg.wasm" | tr -d ' ')"
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

painted_chars="$(field "${control}" '.editorPaintedChars')"
no_source="$(field "${control}" '.noSourceVisible')"
# THE ACCEPTANCE. Painted, hit-tested text in the editor — not `innerText`,
# not a tab title, not a resolved location.
ck "$([ "${painted_chars}" -gt 40 ] && echo ok || echo no)" \
	"the editor PAINTED ${painted_chars} characters of source"
ck "$([ "${no_source}" = false ] && echo ok || echo no)" \
	"and the NO SOURCE view is not what the user is looking at"

errors="$(field "${control}" '.pageErrors | length')"
ck "$([ "${errors}" -eq 0 ] && echo ok || echo no)" \
	"zero uncaught page errors (${errors})"

note "replay milestones:"
jq -r '.replayLines[]' <"${control}" | sed 's/^/        /'
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
rm -f "${arm_a}/assets/db_backend_bg.wasm"
arm_a_out="${cache}/arm-a.json"
if run_probe "${arm_a}" "${arm_a_out}"; then
	a_engine="$(field "${arm_a_out}" '.engineFetched')"
	a_painted="$(field "${arm_a_out}" '.editorPaintedChars')"
	ck "$([ "${a_engine}" = false ] && echo ok || echo no)" \
		"arm A: the engine was not fetched"
	ck "$([ "${a_painted}" -le 40 ] && echo ok || echo no)" \
		"arm A: and no source was painted from a session (${a_painted} chars)"
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
rm -f "${arm_b}/assets/replay-worker.js"
arm_b_out="${cache}/arm-b.json"
if run_probe "${arm_b}" "${arm_b_out}"; then
	b_resolved="$(field "${arm_b_out}" '.resolvedCount')"
	b_painted="$(field "${arm_b_out}" '.editorPaintedChars')"
	ck "$([ "${b_resolved}" -eq 0 ] && echo ok || echo no)" \
		"arm B: the session resolved nothing (${b_resolved})"
	ck "$([ "${b_painted}" -le 40 ] && echo ok || echo no)" \
		"arm B: and no source was painted (${b_painted} chars)"
else
	ck no "arm B: the probe did not complete"
fi
echo

echo "${checks} check(s), ${failures} failure(s)"
if [ "${failures}" -eq 0 ]; then
	echo "RESULT: OK — a Run in a browser opens a debugger and paints its source"
	exit 0
fi
echo "RESULT: FAILED — ${failures} check(s)"
exit 1
