#!/usr/bin/env bash
#
# web-renderer-mounts.sh — the product mounts, asserted on a DOM.
#
# WHAT THIS IS FOR
# ----------------
# On 2026-08-31 `https://ide.codetracer.com/` served a boot diagnostic and
# nothing else. `#dom-root` was empty; the only text on the page was
#
#     codetracer-web-boot: ok condition=scPersistenceDenied platform=pkWeb ...
#
# Every gate was green, and every gate was right. `web-bundle-assets.sh` proved
# the renderer built and was placed. `web_deploy_guard.nim` proved the document
# and the published files agreed. The deploy workflow proved the served bytes
# were the uploaded bytes and that the page carried its descriptor. The smoke
# test proved the loop arm booted and contained zero `require(`.
#
# None of them is *a user sees an editor*. Verification-Harness-Traps.md, trap
# 2: "A chain of `success: true` is not a result — assert what the thing
# produced." This gate is the missing assertion, and its subject is the DOM.
#
# WHAT IT WOULD HAVE CAUGHT, precisely. `ui.js` threw
# `ReferenceError: monaco is not defined` during module initialisation, because
# the generated entry document shipped none of the third-party bundle the
# renderer is loaded beside on the desktop. It died about a quarter of the way
# through its own top-level code and mounted nothing. That is mutation arm A
# below, and it reddens `mounted` while leaving `boot` green — the exact
# signature of the state that shipped.
#
# THE SHAPE, from traps doc 4a and 4c
# -----------------------------------
#   * COUNTED assertions. `ck` tallies; `expect_count` fails if the tally
#     misses the number written at the bottom. A guard that returned early, a
#     loop that skipped an arm, or a probe that produced no JSON stops being a
#     silent pass and becomes a count mismatch. "This should be the default for
#     a new harness, not one harness's flourish."
#   * A CONTROL ARM. The unmutated bundle must go green, so the mutation arms
#     below cannot be red for an unrelated reason. A negative assertion with no
#     positive twin has nothing to fail.
#   * A MUTATION ARM PER CASE, each one verified to redden THE ASSERTION
#     WRITTEN FOR IT and named in the output. An arm that reddens some other
#     check has not shown that this check works.
#
# NON-VACUITY. Every DOM assertion is guarded by `domRootPresent` being
# reported first: a probe that failed to reach the page produces an empty
# object, and "no `.welcome-screen-root` found" over nothing would otherwise be
# indistinguishable from a blank product. Trap 4, the empty haystack.
#
# NETWORK. The server here is a loopback static server over a directory this
# script assembled; nothing is fetched from outside the machine. It does not
# touch `ci/test/noir-studio-signed-out.sh`'s claim, which is about the
# PRODUCT's egress sites and is measured on the bundles, not on a harness.
#
# Usage:  bash ci/test/web-renderer-mounts.sh
# Env:    CT_WEB_BUNDLE_DIR   a bundle already assembled by
#                             web-bundle-assets.sh. Assembled here if unset.
#         CT_PROBE_SCREENSHOT_DIR  write one PNG per arm (debugging aid)

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

cache="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}/web-renderer-mounts"
mkdir -p "${cache}"

checks=0
failures=0
ck() {
	# One assertion. `ck <ok|fail> <sentence>`; the tally is the point.
	checks=$((checks + 1))
	if [ "$1" = "ok" ]; then
		printf '  [OK]      %s\n' "$2"
	else
		failures=$((failures + 1))
		printf '  [FAILED]  %s\n' "$2"
	fi
}
note() { printf '  %s\n' "$*"; }

expect_count() {
	# Traps doc 4c. The number below is written from a run, and it is what
	# turns "every assertion passed" into "every assertion RAN". An arm that
	# aborted, a probe that produced no JSON, a `continue` that skipped a case
	# — all of them land here rather than in a clean summary.
	local want="$1"
	if [ "${checks}" -ne "${want}" ]; then
		printf '\nRESULT: FAILED — %d assertion(s) ran, %d were written.\n' \
			"${checks}" "${want}"
		printf 'An assertion that did not run is not an assertion that passed.\n'
		exit 1
	fi
}

echo "=== the web bundle mounts a product (NS: the page was blank) ==="
echo

command -v node >/dev/null 2>&1 || {
	echo "node is not on PATH; run inside the dev shell" >&2
	exit 2
}
if [ ! -d node_modules/playwright ]; then
	echo "node_modules/playwright is missing; run inside the dev shell" >&2
	exit 2
fi

# ---------------------------------------------------------------------------
# The bundle under test.
# ---------------------------------------------------------------------------
bundle="${CT_WEB_BUNDLE_DIR:-}"
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
echo

# ---------------------------------------------------------------------------
# A loopback static server over a copy of the bundle, so an arm can mutate its
# tree without touching the original.
# ---------------------------------------------------------------------------
server_pid=""
arm_dir=""
stop_server() {
	if [ -n "${server_pid}" ] && kill -0 "${server_pid}" 2>/dev/null; then
		kill "${server_pid}" 2>/dev/null
		wait "${server_pid}" 2>/dev/null
	fi
	server_pid=""
}
trap 'stop_server; [ -n "${arm_dir}" ] && rm -rf "${arm_dir}"' EXIT

port=0

# The server, in one place so every arm is served identically. Port 0 lets the
# OS pick and the process prints what it got: a fixed port makes two arms race
# each other on a busy runner, and produces a red arm that says nothing about
# the product.
cat >"${cache}/serve.py" <<'PY'
import http.server, socketserver, sys

directory = sys.argv[1]


class Quiet(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=directory, **kw)

    def log_message(self, *a):
        pass


socketserver.TCPServer.allow_reuse_address = True
httpd = socketserver.TCPServer(("127.0.0.1", 0), Quiet)
print(httpd.server_address[1], flush=True)
httpd.serve_forever()
PY

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

# ---------------------------------------------------------------------------
# One arm: copy, mutate, serve, probe, print the JSON to a file.
# ---------------------------------------------------------------------------
run_arm() {
	local label="$1" mutate="$2"
	arm_dir="${cache}/arm-${label}"
	[ -d "${arm_dir}" ] && chmod -R u+w "${arm_dir}" 2>/dev/null
	rm -rf "${arm_dir}"
	# A REAL COPY, and `cp -al` is specifically wrong here. Hard links were the
	# first version — the bundle is ~55 MB and four arms looked like 220 MB of
	# pointless I/O — and they silently destroyed the subject: every mutation
	# below rewrites a file IN PLACE, which writes through the shared inode
	# into `${bundle}` itself. The next run's CONTROL arm then measured an
	# already-mutated bundle and reported the product as broken.
	#
	# It was caught by the control arm going red, which is what a control arm
	# is for; a harness without one would have reported the mutation arms'
	# verdicts over a corrupted tree and called them evidence.
	cp -a "${bundle}" "${arm_dir}"
	# The bundle carries trees copied out of `node_modules`, which is a
	# read-only nix store path — `cp -a` preserves those modes and the arm then
	# cannot be mutated OR cleaned up. Found by a mutation arm failing to
	# delete its own subject, which is the good way to find it.
	chmod -R u+w "${arm_dir}" 2>/dev/null
	if [ -n "${mutate}" ]; then
		# A mutation that silently did nothing would leave the arm identical to
		# the control and its "the check went red" claim unearned, so every
		# mutation function returns non-zero when its subject was not there.
		if ! "${mutate}" "${arm_dir}"; then
			echo "  the mutation '${mutate}' found nothing to mutate" >&2
			return 2
		fi
	fi
	if ! start_server "${arm_dir}"; then
		echo "  the static server did not start" >&2
		return 2
	fi
	local shot=""
	if [ -n "${CT_PROBE_SCREENSHOT_DIR:-}" ]; then
		mkdir -p "${CT_PROBE_SCREENSHOT_DIR}"
		shot="${CT_PROBE_SCREENSHOT_DIR}/${label}.png"
	fi
	CT_PROBE_SCREENSHOT="${shot}" \
		node ci/test/web_renderer_probe.mjs "http://127.0.0.1:${port}/" \
		>"${cache}/${label}.json" 2>"${cache}/${label}.err"
	local rc=$?
	stop_server
	if [ "${rc}" -ne 0 ] || [ ! -s "${cache}/${label}.json" ]; then
		echo "  the probe did not produce a report for arm '${label}'" >&2
		head -5 "${cache}/${label}.err" >&2
		return 2
	fi
	return 0
}

# Read one field out of an arm's report. `json` is the only reader, so a
# malformed report is one failure rather than eight.
json() {
	python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    d = d.get(key) if isinstance(d, dict) else None
    if d is None:
        print("")
        sys.exit(0)
print(d if not isinstance(d, list) else len(d))
' "${cache}/$1.json" "$2"
}

# ---------------------------------------------------------------------------
# THE MUTATIONS. Each is the real defect, applied to a real bundle.
# ---------------------------------------------------------------------------

# Arm A — the defect that shipped, exactly. Delete the third-party bundle and
# the renderer throws `ReferenceError: monaco is not defined` at
# `ui/agent_activity.nim:46` during module init.
mutate_no_third_party() {
	local dir="$1"
	[ -f "${dir}/public/dist/frontend_bundle.js" ] || return 1
	rm -f "${dir}/public/dist/frontend_bundle.js"
}

# Arm B — the document half of the same defect. `#dom-root` used to be an empty
# div and the renderer's container did not exist in the page at all; the
# renderer then has nowhere to paint and must SAY so rather than report a
# mount.
mutate_no_container() {
	local dir="$1"
	grep -q 'id="welcomeScreen"' "${dir}/index.html" || return 1
	python3 - "${dir}/index.html" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
open(p, 'w').write(s.replace('<div id="welcomeScreen"></div>', ''))
PY
}

# Arm C — the collision. Unwrap the two Nim bundles so they share a global
# scope again, which is how the deployed pair was built. `ui.js` then redefines
# 196 of `web.js`'s functions and 85 of its type tables under it, and the loop
# arm's async `boot()` resumes into a foreign runtime.
#
# This arm exists because the collision was INVISIBLE while the renderer was
# broken: `ui.js` died before it reached the declarations that clobber the
# type tables, so fixing the renderer is what exposes it. A check that only
# ran against the shipped state would have gone green over it.
mutate_unscoped() {
	local dir="$1"
	head -c 12 "${dir}/ui.js" | grep -q '^(function()' || return 1
	python3 - "${dir}/ui.js" "${dir}/web.js" <<'PY'
import sys
for p in sys.argv[1:]:
    s = open(p).read()
    assert s.startswith('(function(){\n'), p
    open(p, 'w').write(s[len('(function(){\n'):].rsplit('\n})();\n', 1)[0])
PY
}

# ---------------------------------------------------------------------------
echo "Arm: CONTROL — the bundle as assembled"
# ---------------------------------------------------------------------------
if ! run_arm control ""; then
	echo "RESULT: FAILED — the control arm could not be measured, so nothing" >&2
	echo "        below would mean anything." >&2
	exit 1
fi

c_present="$(json control dom.domRootPresent)"
c_html="$(json control dom.domRootHtmlLength)"
c_elems="$(json control dom.domRootElementCount)"
c_welcome="$(json control dom.welcomeScreenRoots)"
c_opts="$(json control dom.startOptions)"
c_panels="$(json control dom.recentPanels)"
c_text="$(json control dom.visibleTextLength)"
c_errs="$(json control pageErrors)"
c_boot="$(json control bootLine)"
c_renderer="$(json control rendererLine)"

# NON-VACUITY FIRST. Everything after this reads `#dom-root`; if the probe
# never found it, the rest are assertions about nothing.
if [ "${c_present}" = "True" ]; then
	ck ok "the probe reached a document that has #dom-root, so the checks below have a subject"
else
	ck fail "the probe found no #dom-root — every DOM check below would be vacuous"
fi

# THE ARTEFACT. Not "the file was served"; markup a user would see.
if [ "${c_html:-0}" -gt 500 ] 2>/dev/null; then
	ck ok "#dom-root carries ${c_html} bytes of markup"
else
	ck fail "#dom-root carries ${c_html} bytes of markup — the page is blank"
fi
if [ "${c_elems:-0}" -gt 20 ] 2>/dev/null; then
	ck ok "#dom-root contains ${c_elems} elements"
else
	ck fail "#dom-root contains ${c_elems} elements — nothing mounted into it"
fi

# THE PRODUCT, by its own class names. `.welcome-screen-root` is emitted by
# `viewmodel/views/isonim_welcome_screen_view.nim`, so this reads the
# RENDERER's output and not index.html's skeleton — an id-based check would be
# satisfied by the empty container the document ships.
if [ "${c_welcome}" = "1" ]; then
	ck ok "the renderer's own .welcome-screen-root is mounted, exactly once"
else
	ck fail "found ${c_welcome} .welcome-screen-root elements; the renderer did not mount its surface"
fi
if [ "${c_opts:-0}" -ge 5 ] 2>/dev/null; then
	ck ok "${c_opts} start options are rendered, so the surface is interactive and not a shell"
else
	ck fail "only ${c_opts} start options rendered"
fi
if [ "${c_panels:-0}" -ge 2 ] 2>/dev/null; then
	ck ok "both recent-work panels rendered"
else
	ck fail "only ${c_panels} recent-work panel(s) rendered"
fi
if [ "${c_text:-0}" -gt 200 ] 2>/dev/null; then
	ck ok "${c_text} characters of text are on screen"
else
	ck fail "only ${c_text} characters of text are on screen"
fi

# NO UNCAUGHT ERRORS. The defect was an exception nothing was listening for.
if [ "${c_errs}" = "0" ]; then
	ck ok "no uncaught page errors"
else
	ck fail "${c_errs} uncaught page error(s):"
	python3 -c 'import json,sys; [print("      "+e) for e in json.load(open(sys.argv[1]))["pageErrors"]]' \
		"${cache}/control.json"
fi

# BOTH ARMS REPORTED. The renderer line is new; the boot line is the
# regression guard for the global-scope collision, which only becomes
# observable once the renderer runs to completion.
case "${c_renderer}" in
*"codetracer-web-renderer: ok"*)
	ck ok "the renderer arm reported a mount: ${c_renderer#*: }" ;;
*)
	ck fail "the renderer arm did not report a mount (line: '${c_renderer}')" ;;
esac
case "${c_boot}" in
*"codetracer-web-boot: ok"*)
	ck ok "the loop arm still booted alongside the renderer" ;;
*)
	ck fail "the loop arm did not boot (line: '${c_boot}')" ;;
esac
echo

# ---------------------------------------------------------------------------
# THE MUTATION ARMS. For each: the named assertion must go RED, and the arm
# must not be red for some unrelated reason — so the check that is expected to
# survive is asserted too.
# ---------------------------------------------------------------------------
echo "Arm A: MUTATION — the third-party bundle is not published"
echo "    This is the defect that shipped. Expect: 'mounted' RED, 'booted' GREEN."
if ! run_arm no-third-party mutate_no_third_party; then
	ck fail "arm A could not be measured"
	ck fail "arm A could not be measured (second half)"
else
	a_welcome="$(json no-third-party dom.welcomeScreenRoots)"
	a_boot="$(json no-third-party bootLine)"
	if [ "${a_welcome}" = "0" ]; then
		ck ok "arm A: the mount assertion goes red without the third-party bundle"
	else
		ck fail "arm A: ${a_welcome} .welcome-screen-root still mounted — the control's mount check cannot fail, so it proves nothing"
	fi
	case "${a_boot}" in
	*"codetracer-web-boot: ok"*)
		ck ok "arm A: the loop arm still booted, so this arm is red for the renderer and not for everything" ;;
	*)
		ck fail "arm A: the loop arm also stopped booting; the arm does not isolate the renderer" ;;
	esac
fi
echo

echo "Arm B: MUTATION — the renderer's container is stripped from the document"
echo "    Expect: 'mounted' RED, and the renderer SAYS it refused."
if ! run_arm no-container mutate_no_container; then
	ck fail "arm B could not be measured"
	ck fail "arm B could not be measured (second half)"
else
	b_welcome="$(json no-container dom.welcomeScreenRoots)"
	b_renderer="$(json no-container rendererLine)"
	if [ "${b_welcome}" = "0" ]; then
		ck ok "arm B: nothing mounts when the container is absent"
	else
		ck fail "arm B: ${b_welcome} .welcome-screen-root mounted with no container"
	fi
	case "${b_renderer}" in
	*"refused"*)
		ck ok "arm B: the renderer reported a refusal rather than a silent blank page" ;;
	*)
		ck fail "arm B: the renderer said '${b_renderer}' — a blank page with no explanation is the failure this gate exists for" ;;
	esac
fi
echo

echo "Arm C: MUTATION — the two Nim bundles share a global scope"
echo "    Expect: 'booted' RED (ui.js clobbers web.js's runtime)."
if ! run_arm unscoped mutate_unscoped; then
	ck fail "arm C could not be measured"
	ck fail "arm C could not be measured (second half)"
else
	c2_boot="$(json unscoped bootLine)"
	c2_welcome="$(json unscoped dom.welcomeScreenRoots)"
	case "${c2_boot}" in
	*"codetracer-web-boot: ok"*)
		ck fail "arm C: the loop arm booted even unscoped, so the control's boot check does not detect the collision" ;;
	*)
		ck ok "arm C: the loop arm breaks when the bundles are unscoped, so the control's boot check is real" ;;
	esac
	# The twin, and the reason this arm is not just "something went wrong".
	# The collision runs one way: `ui.js` loads second and redefines `web.js`'s
	# runtime, so the RENDERER is unharmed and only the loop arm's async
	# continuation lands in a foreign one. An arm that broke both would be
	# consistent with almost any bug; an arm that breaks exactly one names the
	# mechanism.
	if [ "${c2_welcome}" = "1" ]; then
		ck ok "arm C: the renderer still mounted, so the collision is one-directional as described"
	else
		ck fail "arm C: the renderer also stopped mounting (${c2_welcome} roots); the arm does not isolate the collision"
	fi
fi
echo

# ---------------------------------------------------------------------------
# 16 assertions, written from a run. See traps doc 4c: the count is what turns
# "all green" into "all of them ran".
expect_count 16
echo "${checks} check(s), ${failures} failure(s)"
if [ "${failures}" -eq 0 ]; then
	echo "RESULT: OK — the bundle mounts a product, and each check was shown to be able to fail"
	exit 0
fi
echo "RESULT: FAILED — ${failures} check(s)"
exit 1
