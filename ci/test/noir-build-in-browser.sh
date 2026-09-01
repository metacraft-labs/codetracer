#!/usr/bin/env bash
#
# noir-build-in-browser.sh — a Build that fetches the compiler, compiles, and
# paints a result. In a real tab, against the assembled publish tree.
#
# WHAT THIS ASSERTS THAT NOTHING ELSE DOES
# ----------------------------------------
# The deployment has served ~19 MB of working Noir compiler and tracer since
# `dev` 07926277. `ci/test/web-bundle-assets.sh` proves the modules are placed
# and that the worker script drives their ABIs. `ci/test/web_deploy_guard.nim`
# proves the document and the published bytes agree.
# `ci/test/noir-wasm-worker-e2e.sh` proves the two modules produce a real trace
# through the protocol. `ci/test/web-renderer-mounts.sh` proves the product
# mounts and that its own `ctPlatform()` reports `run=true`.
#
# All of it was true of a page that had NEVER FETCHED EITHER MODULE. Measured
# on 2026-09-01, with `Worker.postMessage` wrapped before page scripts ran and
# then Run test, the BUILD pane's ▶ and ■, a test row, F5, Ctrl+B,
# Ctrl+Shift+B and Ctrl+R all exercised:
#
#     configure messages   1
#     start messages       0
#     .wasm requests       0
#
# So this gate's subject is the GESTURE, and its three headline numbers are the
# three above. A chain of `success: true` is not a result.
#
# THE SHAPE
# ---------
#   * COUNTED assertions, with the count itself asserted. A guard that returned
#     early or an arm that was skipped stops being a silent pass.
#   * PAINTED TEXT, never `innerText`. `web-renderer-mounts.sh` records why:
#     its "there is a product on this page" check was satisfied almost
#     entirely by a 379-character developer diagnostic that sat at (0,0) under
#     the topbar and that no user could see. Every row this gate reads is
#     hit-tested at its own centre.
#   * A DELIBERATELY BROKEN PROGRAM, with severities checked BY NAME. The
#     desktop's Noir text matcher currently mis-parses `nargo`'s box-drawing
#     output into a corrupted row with every severity forced to error; this
#     path gets structured objects, so a warning must arrive as a warning and
#     be counted as one.
#   * MUTATION ARMS, each reddening the assertion written for it.
#
# Usage:  bash ci/test/noir-build-in-browser.sh
# Env:    CT_WEB_BUNDLE_DIR       a tree already assembled by web-bundle-assets.sh
#         CT_NOIR_WASM_COMPILER   used only when a bundle must be assembled here
#         CT_NOIR_WASM_TRACER     likewise
#         CT_NOIR_WASM_REF        provenance; without it the page drops the modules
# Exit:   0 all assertions held, 1 otherwise, 2 could not run.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)"
cd "${repo_root}" || exit 2

cache="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}/noir-build-in-browser"
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

for tool in node python3; do
	command -v "${tool}" >/dev/null 2>&1 || {
		echo "noir-build-in-browser.sh: no '${tool}' on PATH." >&2
		echo "  remedy: run inside the dev shell (direnv exec ${repo_root} ...)" >&2
		exit 2
	}
done
node -e "require('playwright')" >/dev/null 2>&1 || {
	echo "noir-build-in-browser.sh: playwright is not installed." >&2
	echo "  remedy: npm install, inside the dev shell" >&2
	exit 2
}

echo "=== a Build in a browser reaches the Noir compiler ==="
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

# THE PRECONDITION, CHECKED RATHER THAN ASSUMED. Everything below is about a
# compiler being fetched, and a tree that ships no compiler would make every
# arm vacuously green in the most misleading way available: the page would
# refuse by name, the pane would paint the refusal, and a careless assertion on
# "the pane has rows" would pass.
compiler="${bundle}/assets/noir_wasm.wasm"
if [ ! -f "${compiler}" ]; then
	echo "  the assembled tree at ${bundle} ships no assets/noir_wasm.wasm," >&2
	echo "  so there is no compiler for a Build to reach and this gate would" >&2
	echo "  measure nothing. Set CT_NOIR_WASM_COMPILER / CT_NOIR_WASM_TRACER /" >&2
	echo "  CT_NOIR_WASM_REF and re-assemble." >&2
	exit 2
fi
compiler_bytes="$(wc -c <"${compiler}" | tr -d ' ')"
if ! grep -q 'noir-compiler' "${bundle}/index.html"; then
	echo "  the entry document declares no noir-compiler module, so the worker" >&2
	echo "  would be configured with no URL for it and every run would die with" >&2
	echo "  'no url declared for wasm module'." >&2
	exit 2
fi
note "bundle:   ${bundle}"
note "compiler: ${compiler_bytes} bytes, declared in the entry document"
echo

# ---------------------------------------------------------------------------
# A static server that serves `.wasm` as `application/wasm`.
#
# THE CONTENT TYPE IS LOAD-BEARING and is not a detail of this harness.
# `WebAssembly.compileStreaming` REQUIRES `application/wasm`, and the worker's
# `load` classifies the response before compiling it precisely because
# Cloudflare Pages was measured answering an absent `.wasm` path with the entry
# document at HTTP 200 and `text/html`. Serving the right type here exercises
# the streaming path — the one that matters for a 16 MB module, because it
# never has to exist as one ArrayBuffer in the tab.
#
# The bundle's own `_redirects` is applied, for `web-renderer-mounts.sh`'s
# reason: a bare handler 404s `/noir`, and an arm served without the rewrite
# would measure THIS SERVER and report the product as broken at a URL the CDN
# serves fine.
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

# COPYING THE TREE IS NOT `cp -R`, and the difference is a real defect rather
# than a portability nicety. The bundle's `public/third_party/**` are copies of
# files that came out of the nix store with mode 444 inside directories with
# mode 555, so a plain `cp -R` reproduces those modes, the next `rm -rf` fails
# on them, and the arm below then serves a HALF-DELETED tree — measured, as a
# renderer that 404'd its own third-party bundle and never mounted, reported as
# "the broken program painted no error row". A mutation arm that cannot even
# load the page is not measuring the product.
copy_tree() {
	local src="$1" dst="$2"
	if [ -e "${dst}" ]; then
		chmod -R u+w "${dst}" 2>/dev/null
		rm -rf "${dst}"
	fi
	cp -R "${src}" "${dst}"
	chmod -R u+w "${dst}"
}

json() {
	# `json <label> <dotted.path>` — one field out of one report.
	python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d.get(k, {}) if isinstance(d, dict) else {}
print(json.dumps(d) if isinstance(d, (dict, list)) else d)
' "${cache}/$1.json" "$2" 2>/dev/null
}

count_matching() {
	# `count_matching <label> <field> <substring>` over a JSON array of strings.
	python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d.get(k, []) if isinstance(d, dict) else []
needle = sys.argv[3]
print(sum(1 for x in d if needle in str(x)))
' "${cache}/$1.json" "$2" "$3" 2>/dev/null
}

probe() {
	# `probe <label> <dir> <url-path> <gesture>`
	local label="$1" dir="$2" url_path="$3" gesture="$4"
	if ! start_server "${dir}"; then
		echo "  the static server did not start" >&2
		return 2
	fi
	node ci/test/noir_build_probe.mjs \
		"http://127.0.0.1:${port}${url_path}" "${gesture}" \
		>"${cache}/${label}.json" 2>"${cache}/${label}.err"
	local rc=$?
	stop_server
	if [ "${rc}" -ne 0 ] || [ ! -s "${cache}/${label}.json" ]; then
		echo "  the probe produced no report for '${label}'" >&2
		head -10 "${cache}/${label}.err" >&2
		return 2
	fi
	return 0
}

dump() {
	local label="$1"
	echo "      --- what the probe saw on '${label}' ---"
	python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for k in ("mounted", "buildPaneOpened", "buildPaneRowCount", "headerText",
          "runButtonPresent", "loadError", "gestureError"):
    print("        %-20s %s" % (k, d.get(k)))
print("        workerMessages")
for m in d.get("workerMessages", []):
    print("          " + str(m)[:160])
print("        wasmRequests")
for r in d.get("wasmRequests", []):
    print("          %s %s %s" % (r.get("status"), r.get("bytes"), r.get("url")))
print("        buildPanePainted")
for r in d.get("buildPanePainted", []):
    print("          " + str(r)[:200])
print("        buildPaneRejected (rows the hit test dropped, and why)")
for r in d.get("buildPaneRejected", []):
    print("          " + str(r)[:200])
print("        pageErrors")
for r in d.get("pageErrors", []):
    print("          " + str(r)[:200])
print("        console")
for r in d.get("consoleLines", [])[-12:]:
    print("          " + str(r)[:200])
' "${cache}/${label}.json"
}

# ---------------------------------------------------------------------------
# ARM 1 — the control. Ctrl+B on the shipped template.
# ---------------------------------------------------------------------------
echo "Arm 1: Ctrl+B on /noir compiles the bundled template"
if ! probe control "${bundle}" /noir shortcut; then
	echo "RESULT: FAILED — the control arm could not be measured" >&2
	exit 1
fi

c_mounted="$(json control mounted)"
c_pane="$(json control buildPaneOpened)"
c_rows="$(json control buildPaneRowCount)"
c_starts="$(count_matching control workerMessages '"kind":"start"')"
c_configures="$(count_matching control workerMessages '"kind":"configure"')"
c_compiles="$(count_matching control workerMessages '"compile"')"
c_wasm="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("wasmRequests",[])))' "${cache}/control.json")"
c_painted="$(count_matching control buildPanePainted 'compiled hello_noir')"
c_paintedrows="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("buildPanePainted",[])))' "${cache}/control.json")"
c_errors="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("pageErrors",[])))' "${cache}/control.json")"

# NON-VACUITY FIRST. Every assertion below reads the BUILD pane; if the surface
# never mounted, they would all be statements about an empty page.
if [ "${c_mounted}" = "True" ] || [ "${c_mounted}" = "true" ]; then
	ck ok "the renderer mounted, so the gesture below had a product to act on"
else
	ck fail "the renderer did not mount; nothing below measures the Build path"
	dump control
	echo
	echo "RESULT: FAILED — the subject never came up"
	exit 1
fi

if [ "${c_pane}" = "True" ] || [ "${c_pane}" = "true" ]; then
	ck ok "Ctrl+B opened the BUILD pane, which the default layout does not carry"
else
	ck fail "Ctrl+B did not open the BUILD pane — there is nowhere for a result to appear"
fi

# THE THREE HEADLINE NUMBERS.
if [ "${c_starts:-0}" -ge 1 ]; then
	ck ok "the worker received ${c_starts} start message(s), where the shipped state produced ZERO"
else
	ck fail "the worker received NO start message — the gesture reached no compiler"
fi

if [ "${c_configures:-0}" -eq 1 ]; then
	ck ok "and exactly one configure handshake, as before"
else
	ck fail "configure messages: ${c_configures} (expected exactly 1)"
fi

if [ "${c_compiles:-0}" -ge 1 ]; then
	ck ok "the start message carries the 'compile' subcommand the worker routes on"
else
	ck fail "no start message names 'compile'; the worker would answer 'no wasm build for subcommand'"
fi

if [ "${c_wasm:-0}" -ge 1 ]; then
	ck ok "the page fetched ${c_wasm} .wasm module(s) — the 19 MB the deployment serves is now reached"
	python3 -c '
import json,sys
for r in json.load(open(sys.argv[1])).get("wasmRequests", []):
    print("        %s %s bytes  %s" % (r.get("status"), r.get("bytes"), r.get("url")))
' "${cache}/control.json"
else
	ck fail "the page fetched NO .wasm module; the compilers were never downloaded"
fi

# AND THE RESULT IS PAINTED. Not "the pane has rows" — the compiler's own
# verdict, as text a user reads, hit-tested at its centre.
if [ "${c_painted:-0}" -ge 1 ]; then
	ck ok "the pane PAINTS the compiler's verdict: a row saying it compiled hello_noir"
else
	ck fail "no painted row reports a completed compile (${c_paintedrows} painted row(s) in total)"
fi

if [ "${c_paintedrows:-0}" -ge 1 ]; then
	ck ok "${c_paintedrows} painted row(s), so the assertion above is over a pane a user can see"
else
	ck fail "the BUILD pane painted nothing at all (container reports ${c_rows} children)"
fi

if [ "${c_errors:-0}" -eq 0 ]; then
	ck ok "and the page raised no uncaught error while doing it"
else
	ck fail "the page raised ${c_errors} uncaught error(s) during the build"
fi

dump control
echo

# ---------------------------------------------------------------------------
# ARM 2 — the ▶ button, which is the gesture the acceptance names.
# ---------------------------------------------------------------------------
echo "Arm 2: the BUILD pane's ▶ dispatches a second compile"
if ! probe button "${bundle}" /noir button; then
	ck fail "arm 2 could not be measured"
else
	b_run="$(json button runButtonPresent)"
	b_starts="$(count_matching button workerMessages '"kind":"start"')"
	b_painted="$(count_matching button buildPanePainted 'compiled hello_noir')"
	if [ "${b_run}" = "True" ] || [ "${b_run}" = "true" ]; then
		ck ok "the ▶ is present in the opened pane"
	else
		ck fail "no ▶ in the BUILD pane"
	fi
	if [ "${b_starts:-0}" -ge 2 ]; then
		ck ok "clicking ▶ posted a second start (${b_starts} in total), so the button is wired and not decorative"
	else
		ck fail "clicking ▶ produced ${b_starts} start message(s); a second compile did not happen"
	fi
	if [ "${b_painted:-0}" -ge 1 ]; then
		ck ok "and the second compile painted its result too"
	else
		ck fail "the ▶ compile painted no result"
	fi
fi
echo

# ---------------------------------------------------------------------------
# ARM 3 — a deliberately broken program, with severities checked by name.
#
# The template's `src/utils.nr` is given a return type its body does not
# produce. Measured against the real module, that is one `error` at
# `hello_noir/src/utils.nr:3:41` with two secondary labels.
#
# A SECOND EDIT MAKES THE SEVERITIES MIXED: an unused expression result is a
# `warning`, and Build compiles in `program` mode where warnings are not
# silenced. So this arm is the one that shows the browser path keeping a
# warning a warning — the property the desktop text matcher currently loses.
# ---------------------------------------------------------------------------
echo "Arm 3: a broken program produces correctly-attributed diagnostics"
broken="${cache}/broken"
copy_tree "${bundle}" "${broken}"

# The template is COMPILED INTO the bundle (`platform/noir_template.nim`'s rule
# 5: "a template shipped in the application bundle, not a stored project"), and
# `nim js` emits string literals as byte arrays — so grepping `ui.js` for the
# source text finds nothing and patching it that way would be a no-op that
# looked like an edit. The mutation therefore goes in through the DOM, on the
# same path a user's own edit would: `mountedTemplate` is what
# `installNoirBuildCommands` was given, and the probe cannot reach it.
#
# So this arm edits the SOURCE and rebuilds the renderer. It is the slow arm
# and it is the only honest one.
if [ -n "${CT_NOIR_BUILD_SKIP_BROKEN:-}" ]; then
	ck fail "arm 3 was skipped by CT_NOIR_BUILD_SKIP_BROKEN — a skip is not a pass"
else
	template_src="src/frontend/viewmodel/platform/noir_template.nim"
	cp "${template_src}" "${cache}/noir_template.orig"
	perl -0pi -e 's/pub fn assert_in_range\(value: Field\) \{/pub fn assert_in_range(value: Field) -> u8 {\n    let _unused = value + value;/' \
		"${template_src}"
	if cmp -s "${template_src}" "${cache}/noir_template.orig"; then
		cp "${cache}/noir_template.orig" "${template_src}"
		ck fail "arm 3's patch changed NOTHING — its premise has moved and it has been measuring nothing"
	else
		rebuilt=1
		if ! nim js --hints:off --warnings:off -d:chronicles_enabled=off \
			-d:ctRenderer -d:ctWeb --nimcache:"${cache}/broken-nimcache" \
			-o:"${cache}/broken-ui.js" src/frontend/ui_js.nim \
			>"${cache}/broken-build.log" 2>&1; then
			rebuilt=0
		fi
		cp "${cache}/noir_template.orig" "${template_src}"
		if [ "${rebuilt}" -ne 1 ]; then
			ck fail "arm 3's mutated renderer did not build; see ${cache}/broken-build.log"
			grep -E 'Error:' "${cache}/broken-build.log" | head -3 | sed 's/^/      /'
		else
			# The assembled tree wraps `ui.js` in an IIFE. Reproduce it, or the
			# renderer redefines globals and the page dies before mounting.
			{
				printf '(function () {\n'
				cat "${cache}/broken-ui.js"
				printf '\n})();\n'
			} >"${broken}/ui.js"
			# The deploy guard compares DECLARED sizes against the tree, and the
			# document declares `ui.js`'s. That is not this gate's subject, and
			# the page does not read it — but the entry document does carry the
			# renderer's byte count, so leave a note rather than a surprise.
			if probe brokenarm "${broken}" /noir shortcut; then
				k_errors="$(count_matching brokenarm buildPanePainted 'error:')"
				k_warnings="$(count_matching brokenarm buildPanePainted 'warning:')"
				k_file="$(count_matching brokenarm buildPanePainted '/hello_noir/src/utils.nr')"
				k_secondary="$(count_matching brokenarm buildPanePainted 'expected u8 because of return type')"
				k_success="$(count_matching brokenarm buildPanePainted 'compiled hello_noir')"
				k_problems="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("problemRowsPainted",[])))' "${cache}/brokenarm.json")"

				if [ "${k_errors:-0}" -ge 1 ]; then
					ck ok "the broken program paints ${k_errors} row(s) attributed 'error:'"
				else
					ck fail "the broken program painted no error row"
				fi
				if [ "${k_warnings:-0}" -ge 1 ]; then
					ck ok "AND ${k_warnings} row(s) attributed 'warning:' — the severities are not all forced to error"
				else
					ck fail "no row is attributed 'warning:'; a warning arrived as something else (the desktop matcher's defect)"
				fi
				if [ "${k_file:-0}" -ge 1 ]; then
					ck ok "and they are attributed to /hello_noir/src/utils.nr — the RENDERER's path, which a click can open"
				else
					ck fail "no diagnostic names /hello_noir/src/utils.nr; a jump target would open nothing"
				fi
				if [ "${k_secondary:-0}" -ge 1 ]; then
					ck ok "the frontend's secondary label survives into the pane"
				else
					ck fail "the secondary label was dropped; 'expected type u8' alone does not say where the u8 came from"
				fi
				if [ "${k_success:-0}" -eq 0 ]; then
					ck ok "and NOTHING claims the program compiled — the negative twin of arm 1"
				else
					ck fail "the pane reports a successful compile over a program that does not compile"
				fi
				if [ "${k_problems:-0}" -ge 2 ]; then
					ck ok "${k_problems} clickable diagnostic row(s), so both severities reached the Problems surface"
				else
					ck fail "only ${k_problems} clickable diagnostic row(s) (expected at least 2)"
				fi
				dump brokenarm
			else
				ck fail "arm 3 could not be measured"
			fi
		fi
	fi
fi
echo

# ---------------------------------------------------------------------------
# ARM 4 — a deployment with NO compiler refuses by name rather than hanging.
#
# The negative twin of arm 1's `.wasm` count. Without it "the page fetched a
# module" is unfalsifiable: a gate that only ever loads a complete tree cannot
# say whether the fetch happened because the product asked for it or because
# something else did.
# ---------------------------------------------------------------------------
echo "Arm 4: a tree that ships no compiler refuses BY NAME and fetches nothing"
nomodules="${cache}/nomodules"
copy_tree "${bundle}" "${nomodules}"
rm -f "${nomodules}/assets/noir_wasm.wasm" "${nomodules}/assets/noir_tracer_wasm.wasm"
# The DESCRIPTOR is what the registry is derived from, so removing the files
# alone would leave the page believing it has a toolchain and failing inside
# the worker with `not-served`. That is a different and equally real state, and
# it is arm 5's. This arm is a deployment that never had them: the document
# must stop declaring them too.
python3 - "$nomodules/index.html" <<'PY'
import re, sys
path = sys.argv[1]
doc = open(path).read()
before = doc
doc = re.sub(r'\{"id":"noir-(compiler|tracer)".*?\}', '', doc)
doc = doc.replace('"modules":[,]', '"modules":[]').replace('"modules":[,', '"modules":[')
doc = doc.replace(',,', ',').replace('[,', '[').replace(',]', ']')
if doc == before:
    sys.exit(3)
open(path, 'w').write(doc)
PY
if [ $? -eq 3 ]; then
	ck fail "arm 4's descriptor edit changed NOTHING — its premise has moved"
elif ! probe nomodules "${nomodules}" /noir shortcut; then
	ck fail "arm 4 could not be measured"
else
	n_wasm="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("wasmRequests",[])))' "${cache}/nomodules.json")"
	n_starts="$(count_matching nomodules workerMessages '"kind":"start"')"
	n_refused="$(count_matching nomodules buildPanePainted 'no wasm toolchain modules')"
	n_success="$(count_matching nomodules buildPanePainted 'compiled hello_noir')"
	n_painted="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("buildPanePainted",[])))' "${cache}/nomodules.json")"

	if [ "${n_wasm:-1}" -eq 0 ]; then
		ck ok "no .wasm was fetched, so arm 1's fetch was caused by the Build and not by the page load"
	else
		ck fail "arm 4 fetched ${n_wasm} .wasm module(s) from a tree that ships none"
	fi
	if [ "${n_starts:-1}" -eq 0 ]; then
		ck ok "and no start was posted — the refusal happens before dispatch, by name"
	else
		ck fail "arm 4 posted ${n_starts} start message(s) over an empty registry"
	fi
	if [ "${n_refused:-0}" -ge 1 ]; then
		ck ok "the pane says WHY: 'this deployment ships no wasm toolchain modules'"
	else
		ck fail "the pane painted ${n_painted} row(s), none of which explains the absence"
	fi
	if [ "${n_success:-0}" -eq 0 ]; then
		ck ok "and nothing claims a compile happened"
	else
		ck fail "arm 4 reports a compile over a deployment with no compiler"
	fi
	dump nomodules
fi
echo

# ---------------------------------------------------------------------------
# ARM 5 — the modules are DECLARED and NOT SERVED: a broken deploy.
#
# `wasm_worker_browser.js`'s `load` distinguishes three faults for a reason its
# own header gives — a missing asset and a broken feature reading identically
# cost a sibling campaign hours. This arm is `not-served`, and the property
# under test is that the sentence reaches the user rather than an exit code.
# ---------------------------------------------------------------------------
echo "Arm 5: modules declared and not served reach the user as a sentence"
notserved="${cache}/notserved"
copy_tree "${bundle}" "${notserved}"
rm -f "${notserved}/assets/noir_wasm.wasm"
if [ -f "${notserved}/assets/noir_wasm.wasm" ]; then
	ck fail "arm 5 could not remove the compiler, so its premise does not hold"
elif ! probe notserved "${notserved}" /noir shortcut; then
	ck fail "arm 5 could not be measured"
else
	s_starts="$(count_matching notserved workerMessages '"kind":"start"')"
	s_declared="$(count_matching notserved buildPanePainted 'does not serve')"
	s_success="$(count_matching notserved buildPanePainted 'compiled hello_noir')"
	s_painted="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("buildPanePainted",[])))' "${cache}/notserved.json")"

	if [ "${s_starts:-0}" -ge 1 ]; then
		ck ok "the run WAS dispatched — the registry believed the module was there, which is what a broken deploy looks like"
	else
		ck fail "no start was posted; this arm is measuring the empty-registry path, not the not-served one"
	fi
	if [ "${s_declared:-0}" -ge 1 ]; then
		ck ok "and the fault reaches the pane as prose: 'this deployment does not serve it'"
	else
		ck fail "the not-served fault did not reach the pane (${s_painted} painted row(s)); a start caller is losing the worker's message"
	fi
	if [ "${s_success:-0}" -eq 0 ]; then
		ck ok "and nothing claims a compile happened"
	else
		ck fail "arm 5 reports a compile over a module that was never served"
	fi
	dump notserved
fi
echo

# ---------------------------------------------------------------------------
# ARM 6 — RUN: compile for debugging, then TRACE.
#
# The second half of the milestone, and the one where it is easiest to
# overclaim. What a user sees at the end of Run is the BUILD pane reporting the
# trace's SHAPE — how many events, steps and calls it holds and which source
# files it covers, each a clickable row. It does NOT open a replay session:
# this deployment ships no replay engine (the db-backend wasm is absent from
# `webRuntimeAssets()` and every ViewModel logs `(stub backend)`), and the
# tracer emits a `MemoryTrace` document rather than a `.ct` container, so
# whether that engine would even accept it is an open question. Painting a
# session that is not there would be this campaign's own failure shape.
#
# TWO starts, not one, and that is the assertion that says Run is not Build:
# a compile in `debug` mode (instrumented, `force_brillig` — the only artifact
# a tracer can walk) followed by a trace of the artifact it produced.
# ---------------------------------------------------------------------------
echo "Arm 6: Ctrl+Enter compiles for debugging and then traces"
if [ ! -f "${bundle}/assets/noir_tracer_wasm.wasm" ]; then
	ck fail "this tree ships no assets/noir_tracer_wasm.wasm, so Run cannot be measured — and a skip is not a pass"
	ck fail "  (build it: cd <noir>/tooling/tracer_wasm && cargo build --release --no-default-features --target wasm32-unknown-unknown)"
	ck fail "  (then re-assemble with CT_NOIR_WASM_TRACER pointing at it)"
elif ! probe run "${bundle}" /noir run; then
	ck fail "arm 6 could not be measured"
	ck fail "arm 6: (trace start not measured)"
	ck fail "arm 6: (trace result not measured)"
else
	r_starts="$(count_matching run workerMessages '"kind":"start"')"
	r_trace="$(count_matching run workerMessages '"trace"')"
	r_compiled="$(count_matching run buildPanePainted 'compiled hello_noir')"
	r_traced="$(count_matching run buildPanePainted 'traced ')"
	r_steps="$(count_matching run buildPanePainted ' steps,')"
	r_wasm="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("wasmRequests",[])))' "${cache}/run.json")"
	r_files="$(count_matching run buildPanePainted '/hello_noir/src/main.nr')"
	r_trivial="$(count_matching run buildPanePainted 'no steps')"

	if [ "${r_starts:-0}" -ge 2 ]; then
		ck ok "Run posted ${r_starts} start messages — a compile and a trace, not one command twice"
	else
		ck fail "Run posted ${r_starts} start message(s); the trace phase never happened"
	fi
	if [ "${r_trace:-0}" -ge 1 ]; then
		ck ok "and one of them carries the 'trace' subcommand"
	else
		ck fail "no start names 'trace'; the worker would answer 'no wasm build for subcommand'"
	fi
	if [ "${r_wasm:-0}" -ge 2 ]; then
		ck ok "both wasm modules were fetched (${r_wasm}) — the tracer as well as the compiler"
		python3 -c '
import json,sys
for r in json.load(open(sys.argv[1])).get("wasmRequests", []):
    print("        %s %s bytes  %s" % (r.get("status"), r.get("bytes"), r.get("url")))
' "${cache}/run.json"
	else
		ck fail "only ${r_wasm} .wasm module(s) were fetched; the tracer was not reached"
	fi
	if [ "${r_compiled:-0}" -ge 1 ]; then
		ck ok "the pane reports the debugging compile"
	else
		ck fail "the pane reports no compile, so the trace had no artifact to walk"
	fi
	if [ "${r_traced:-0}" -ge 1 ] && [ "${r_steps:-0}" -ge 1 ]; then
		ck ok "AND it reports the trace by shape — events, steps and calls, painted"
		python3 -c '
import json,sys
for r in json.load(open(sys.argv[1])).get("buildPanePainted", []):
    print("        " + str(r)[:160])
' "${cache}/run.json"
	else
		ck fail "the pane does not report a trace with steps in it"
	fi
	if [ "${r_files:-0}" -ge 1 ]; then
		ck ok "and names the source files it covers, in the renderer's own path spelling"
	else
		ck fail "the trace's source files are not painted; there is nothing to click"
	fi
	if [ "${r_trivial:-0}" -eq 0 ]; then
		ck ok "and it is NOT the one-event-zero-steps trace both modules can answer ok over"
	else
		ck fail "the trace has no steps — an artifact compiled without instrumentation produces exactly this"
	fi
	dump run
fi
echo

# ---------------------------------------------------------------------------
# WHAT THIS GATE DOES NOT ASSERT, said here rather than left to be inferred.
#
# THE ■ IS NOT EXERCISED IN A BROWSER, and there is no arm for it, because
# there is no state to synchronise on and no window to aim at.
#
#   * The button's `disabled` class is NOT REACTIVE. `isonim_build_view`'s
#     header computes it once with `stopButtonClass(vm)`; measured over a real
#     compile it stayed `build-ctrl-btn build-stop-btn disabled` for the whole
#     run while the header text beside it updated from `▶` to
#     `build succeeded`. So "wait until the ■ is live" is a condition that
#     never becomes true — on either platform. That is a pre-existing defect in
#     the pane's view, not in this path, and it is not fixed here.
#   * The window is a compile, and a warm compile of the bundled template is
#     ~200 ms once the module is in the browser's cache. An arm aimed at it
#     would pass or fail on machine speed.
#
# An arm that clicked anyway and then asserted "the pane ended settled" was
# written, measured, and DELETED: it went green over a run nothing had
# interrupted, which is a vacuous check wearing a tick — precisely the shape
# every other arm here is built to avoid.
#
# What IS asserted, deterministically and one layer down:
# `test_noir_build_producer.nim`'s "a STOP is not a failure" drives a signalled
# `ProcessExit` through the producer and requires `npvCancelled` rather than
# `npvFaulted` — `process.nim`'s "a cancelled run establishes nothing" — and
# `ci/test/noir-build-mutations.sh` arm 16 reddens exactly that case. The
# dispatch half (`cancelBuildProc` → `process.signal(handle, sigTerminate)` →
# `WasmHost.terminate` → `worker.stopAll()`) is covered by
# `test_wasm_worker.nim`'s "terminate reports an outstanding run as KILLED".
#
# ---------------------------------------------------------------------------
echo "checks: ${checks}   failures: ${failures}"

# THE COUNT ITSELF. A guard that returned early, an arm that was skipped, or a
# `probe` that failed silently would otherwise reduce this gate to whatever ran.
expected_checks=32
if [ "${checks}" -ne "${expected_checks}" ]; then
	echo "  ${checks} assertion(s) ran; this gate declares ${expected_checks}." >&2
	echo "  An arm was skipped, or one was added without moving the number." >&2
	failures=$((failures + 1))
fi

if [ "${failures}" -eq 0 ]; then
	echo
	echo "RESULT: OK — a Build in a browser fetches the compiler, compiles, and paints its result"
	exit 0
fi
echo
echo "RESULT: FAILED — ${failures} check(s)"
exit 1
