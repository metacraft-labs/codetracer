#!/usr/bin/env bash
#
# shellcheck disable=SC2016
#
# FILE-LEVEL, and for one reason: every `[OK]` / `[FAILED]` message in here
# quotes a header or a header value in backticks, as prose. `shfmt -s` rewrites
# escaped-backtick double quotes into single quotes, and shellcheck then reads
# the backticks as a substitution that will not expand. The two hooks disagree
# about every one of those sentences; `web-bundle-assets.sh` carries the same
# disable for the same one-line reason.
#
# THE FRONT DOOR'S LOGIC, PROVED LOCALLY — WD4, and the half a deploy gate
# cannot give you quickly.
#
# ## What this proves and what it explicitly does not
#
# `local-development-parity.md` §4 is the governing policy and it is blunt about
# the split: *"Local proves the middleware logic; only a real edge environment
# proves the cache. Shipping on a green local run here is the specific mistake
# this section exists to prevent."*
#
# So this file proves the LOGIC — the fork, the allow-list, the headers, the
# fail-closed branch — against the real generated function under the real
# pinned wrangler. It does **not** prove, and nothing here establishes, that an
# authenticated render can never be served from a shared cache to an anonymous
# visitor. There is no shared cache in this loop. That property is gated on the
# deploy, in the `An authenticated render never enters the shared cache` step of
# `.github/workflows/deploy-web-codetracer.yml`, against `ide.codetracer.com`.
#
# ## Why it runs wrangler rather than importing the module
#
# Because the two things most likely to be wrong are not the JavaScript. They
# are (1) whether wrangler FINDS the function at all — the placement trap that
# answers every signed-in request with the static page, 200, no error anywhere —
# and (2) whether `context.next()` reaches the static asset. Importing
# `onRequest` into node would stub both and prove neither.
#
# The function is GENERATED here by the same `web_deployment_render.nim` the
# deploy uses, from the same `deploymentContract`, so a prefix added to
# `web_entry.classifyPath` is exercised here without anybody editing this file.
#
# Usage:  bash ci/test/web-front-door-local.sh
# Needs:  the `.#ci` dev shell (wrangler) and `python3`. No stack, no network.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# `|| exit` and not a bare `cd`: this script runs under `set -uo pipefail`
# WITHOUT `-e`, so a failed `cd` would carry on and render into the wrong tree.
cd "${repo_root}" || exit 1

pass=0
fail=0
ok() {
	pass=$((pass + 1))
	echo "  [OK] $1"
}
bad() {
	fail=$((fail + 1))
	echo "  [FAILED] $1"
}

work="$(mktemp -d "${TMPDIR:-/tmp}/ct-front-door-XXXXXX")"
origin_pid=""
origin_b_pid=""
wrangler_pid=""
cleanup() {
	[ -n "${wrangler_pid}" ] && kill "${wrangler_pid}" 2>/dev/null
	[ -n "${origin_pid}" ] && kill "${origin_pid}" 2>/dev/null
	[ -n "${origin_b_pid}" ] && kill "${origin_b_pid}" 2>/dev/null
	rm -rf "${work}" 2>/dev/null
	return 0
}
trap cleanup EXIT

# --------------------------------------------------------------------------
# The staged publish directory, and the function BESIDE it rather than in it.
#
# This is the placement the deploy uses and the one this product's workflow
# needs: wrangler resolves Functions from `./functions` relative to its CWD, so
# the layout below mirrors `cd "$RUNNER_TEMP"` + `wrangler pages deploy
# "$staged"`. Putting the function inside `dist/` is the shimmed case, and the
# first case asserts we are not in it.
# --------------------------------------------------------------------------
mkdir -p "${work}/dist" "${work}/functions"

echo "Step 1: generate the front door from the deployment contract"
cache="${work}/nimcache"
if ! nim c --hints:off --warnings:off --nimcache:"${cache}" \
	-o:"${work}/render-bin" ci/test/web_deployment_render.nim \
	>"${work}/render.log" 2>&1; then
	bad "the deployment renderer compiled"
	grep -E 'Error:' "${work}/render.log" | head -3 | sed 's/^/      /'
	echo "CHECKS: $((pass + fail))"
	exit 1
fi
ok "the deployment renderer compiled"

# The renderer reads a descriptor on stdin; an empty one is enough, because the
# front door's input is the CONTRACT's rewrite rules and not the asset list.
if "${work}/render-bin" "https://ide.codetracer.com" \
	"0000000000000000000000000000000000000000" \
	"${work}/dist" "" "${work}" </dev/null >"${work}/render-out.log" 2>&1; then
	ok "it rendered"
else
	bad "it rendered"
	sed 's/^/      /' "${work}/render-out.log" | head -5
fi

# THE SENTINEL GOES IN AFTER THE RENDER, and the first version of this file got
# that wrong in a way worth keeping: it wrote the marker first, and
# `renderEntryDocument` then overwrote `dist/index.html` with the product's real
# entry document. Both anonymous cases "failed" while the front door was
# behaving perfectly — the test was asserting on a file the renderer owns.
printf '<!-- STATIC-BUNDLE-SENTINEL -->\n' >>"${work}/dist/index.html"

if [ -f "${work}/functions/_middleware.js" ]; then
	ok "the front door is at functions/_middleware.js, BESIDE the publish dir"
else
	bad "the front door is at functions/_middleware.js"
	echo "CHECKS: $((pass + fail))"
	exit 1
fi
if [ -e "${work}/dist/functions" ]; then
	bad "there is no functions/ INSIDE the publish directory"
else
	ok "there is no functions/ INSIDE the publish directory"
fi

# THE DEFAULT PLATFORM ORIGIN, as generated. The deploy publishes the file as
# rendered, so the literal the renderer baked in is the origin production uses
# whenever no PLATFORM_ORIGIN variable is set.
if grep -q '^const DEFAULT_PLATFORM_ORIGIN = "https://api.codetracer.com";$' \
	"${work}/functions/_middleware.js"; then
	ok "the generated default platform origin is https://api.codetracer.com"
else
	bad "the generated default platform origin is https://api.codetracer.com"
	grep -n 'DEFAULT_PLATFORM_ORIGIN =' "${work}/functions/_middleware.js" |
		sed 's/^/      /'
fi

# --------------------------------------------------------------------------
# Two stub platform origins, A and B. Each echoes its own name, the method,
# the path with its query, and the request body, and sets a cacheable header
# plus a Set-Cookie, so the middleware's two header duties — deleting the
# upstream's caching headers, and rebuilding Set-Cookie rather than folding it
# — are observable rather than assumed.
#
# Two, because "which origin answered" is the whole question for the default
# and the override: A is bound as PLATFORM_ORIGIN, B is written into the
# function as its default (the one edit this script makes to the generated
# file — the real default is api.codetracer.com, asserted above, and this test
# makes no network calls).
# --------------------------------------------------------------------------
start_origin() {
	python3 - "$1" "$2" <<'PY' &
import http.server, socketserver, sys, threading

NAME = sys.argv[2]

class H(http.server.BaseHTTPRequestHandler):
    def answer(self):
        length = int(self.headers.get("Content-Length") or 0)
        sent = self.rfile.read(length).decode() if length else ""
        body = ("ORIGIN-SENTINEL " + NAME + " " + self.command + " " +
                self.path + " body=" + sent).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        # Deliberately CACHEABLE and deliberately two cookies: the middleware
        # must delete the first and must not fold the second pair into one.
        self.send_header("Cache-Control", "public, max-age=600")
        self.send_header("Expires", "Wed, 09 Jun 2027 10:18:14 GMT")
        self.send_header("Set-Cookie", "a=1; Expires=Wed, 09 Jun 2027 10:18:14 GMT")
        self.send_header("Set-Cookie", "b=2")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
    do_GET = do_POST = do_PUT = do_HEAD = answer
    def log_message(self, *a): pass

with socketserver.TCPServer(("127.0.0.1", 0), H) as httpd:
    open(sys.argv[1], "w").write(str(httpd.server_address[1]))
    httpd.serve_forever()
PY
}

start_origin "${work}/origin.port" A
origin_pid=$!
start_origin "${work}/origin-b.port" B
origin_b_pid=$!

for _ in $(seq 1 50); do
	[ -s "${work}/origin.port" ] && [ -s "${work}/origin-b.port" ] && break
	sleep 0.1
done
origin_port="$(cat "${work}/origin.port" 2>/dev/null || true)"
origin_b_port="$(cat "${work}/origin-b.port" 2>/dev/null || true)"
if [ -z "${origin_port}" ] || [ -z "${origin_b_port}" ]; then
	bad "the stub origins started"
	echo "CHECKS: $((pass + fail))"
	exit 1
fi
ok "the stub origins started (A on ${origin_port}, B on ${origin_b_port})"

sed -i "s|^const DEFAULT_PLATFORM_ORIGIN = .*|const DEFAULT_PLATFORM_ORIGIN = \"http://127.0.0.1:${origin_b_port}\";|" \
	"${work}/functions/_middleware.js"

echo
echo "Step 2: serve it with the pinned wrangler, from the CWD the deploy uses"
# start_wrangler LOG [--binding NAME=VALUE ...] — serve the staged bundle on a
# fresh port, from the CWD the deploy uses, and wait until it answers. Sets
# `front_port` and `wrangler_pid`; a previous instance is stopped first.
start_wrangler() {
	local log="$1"
	shift
	if [ -n "${wrangler_pid}" ]; then
		kill "${wrangler_pid}" 2>/dev/null
		wait "${wrangler_pid}" 2>/dev/null
		wrangler_pid=""
	fi
	front_port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
	(
		cd "${work}" || exit 1
		exec wrangler pages dev dist \
			--port "${front_port}" --ip 127.0.0.1 "$@" \
			>"${log}" 2>&1
	) &
	wrangler_pid=$!
	local _
	for _ in $(seq 1 120); do
		if curl -sS -o /dev/null "http://127.0.0.1:${front_port}/" 2>/dev/null; then
			return 0
		fi
		sleep 0.5
	done
	return 1
}

if ! start_wrangler "${work}/wrangler.log" \
	--binding "PLATFORM_ORIGIN=http://127.0.0.1:${origin_port}"; then
	bad "wrangler served the bundle"
	tail -20 "${work}/wrangler.log" | sed 's/^/      /'
	echo "CHECKS: $((pass + fail))"
	exit 1
fi
ok "wrangler served the bundle"

# THE PLACEMENT ASSERTION, and it is the reason this file runs wrangler at all.
# A misplaced Functions directory does not fail: wrangler logs
# `No Functions. Shimming...`, serves the static page for every request, and
# nothing errors.
if grep -qi 'No Functions' "${work}/wrangler.log"; then
	bad "wrangler FOUND the function (it logged 'No Functions' and shimmed)"
else
	ok "wrangler found the function (no 'No Functions. Shimming' in its log)"
fi

echo
echo "Step 3: the fork"
anon="$(curl -sS -D - "http://127.0.0.1:${front_port}/" 2>/dev/null | tr -d '\r')"
if printf '%s' "${anon}" | grep -q 'STATIC-BUNDLE-SENTINEL'; then
	ok "an anonymous / is answered by the STATIC bundle"
else
	bad "an anonymous / is answered by the STATIC bundle"
fi

auth="$(curl -sS -D - -H 'Cookie: session_id=local-probe' \
	"http://127.0.0.1:${front_port}/" 2>/dev/null | tr -d '\r')"
if printf '%s' "${auth}" | grep -q 'ORIGIN-SENTINEL'; then
	ok "a / carrying a session cookie is answered by the ORIGIN"
else
	bad "a / carrying a session cookie is answered by the ORIGIN"
fi

# THE BUG THAT WAS PAID FOR IN THE OTHER REPO: a substring test over the whole
# Cookie header also matches a cookie whose name merely ENDS with the one being
# looked for, which would put the front door into its authenticated branch for a
# visitor who has never signed in.
decoy="$(curl -sS -D - -H 'Cookie: other_session_id=x' \
	"http://127.0.0.1:${front_port}/" 2>/dev/null | tr -d '\r')"
if printf '%s' "${decoy}" | grep -q 'STATIC-BUNDLE-SENTINEL'; then
	ok '`other_session_id=x` does NOT flip the fork'
else
	bad '`other_session_id=x` does NOT flip the fork — the cookie is matched by substring'
fi

echo
echo "Step 4: the headers on an authenticated render"
if printf '%s' "${auth}" | grep -qi 'cache-control: *private, *no-store'; then
	ok 'it carries `private, no-store`'
else
	bad 'it carries `private, no-store`'
fi
if printf '%s' "${auth}" | grep -qi '^vary:.*cookie'; then
	ok "it varies on Cookie"
else
	bad "it varies on Cookie"
fi
# The upstream's own caching headers are DELETED, not merely overridden:
# `Cache-Control` is not the only header that can admit a response to a cache.
if printf '%s' "${auth}" | grep -qi '^expires:'; then
	bad "the upstream's \`Expires\` is deleted"
else
	ok "the upstream's \`Expires\` is deleted"
fi
# `new Headers(other)` folds repeated names, and a folded Set-Cookie is one a
# browser cannot split back apart — a sign-in through the front door would end
# with no session.
set_cookies="$(printf '%s' "${auth}" | grep -ci '^set-cookie:' || true)"
if [ "${set_cookies}" -eq 2 ]; then
	ok "two Set-Cookie headers survive as two (not folded into one)"
else
	bad "two Set-Cookie headers survive as two — got ${set_cookies}"
fi

echo
echo "Step 5: the dynamic allow-list, read from the contract"
# Taken from the generated file rather than written here: a list in this script
# would be the second implementation of "which prefixes exist" that WD4 exists
# to prevent.
first_prefix="$(
	python3 - "${work}/functions/_middleware.js" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
block = re.search(r'const DYNAMIC_PREFIXES = \[(.*?)\];', src, re.S)
names = re.findall(r'"([^"]+)"', block.group(1)) if block else []
print(names[0] if names else "")
PY
)"
if [ -n "${first_prefix}" ]; then
	ok "the generated function declares dynamic prefixes (first: ${first_prefix})"
	dyn="$(curl -sS "http://127.0.0.1:${front_port}${first_prefix}/probe" 2>/dev/null || true)"
	if printf '%s' "${dyn}" | grep -q 'ORIGIN-SENTINEL'; then
		ok "a path under ${first_prefix} reaches the ORIGIN even with no cookie"
	else
		bad "a path under ${first_prefix} reaches the ORIGIN even with no cookie"
	fi
else
	bad "the generated function declares dynamic prefixes"
	bad "a path under the first prefix reaches the ORIGIN"
fi

echo
echo "Step 6: the service's own surfaces and the share link, with no cookie"
front="http://127.0.0.1:${front_port}"
share_id="01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb"

# expect_origin LABEL PATH [curl args...] — the request reaches origin A and is
# marked as forwarded.
expect_origin() {
	local label="$1" path="$2"
	shift 2
	local got
	got="$(curl -sS -D - "$@" "${front}${path}" 2>/dev/null | tr -d '\r')"
	if printf '%s' "${got}" | grep -q "ORIGIN-SENTINEL A " &&
		printf '%s' "${got}" | grep -qi '^x-codetracer-front-door: *origin$'; then
		ok "${label} reaches the platform, marked \`X-CodeTracer-Front-Door: origin\`"
	else
		bad "${label} reaches the platform, marked \`X-CodeTracer-Front-Door: origin\`"
		printf '%s\n' "${got}" | head -12 | sed 's/^/      /'
	fi
	last_response="${got}"
}

# expect_static LABEL PATH — the request never leaves the static bundle.
expect_static() {
	local label="$1" path="$2" got
	got="$(curl -sS -D - "${front}${path}" 2>/dev/null | tr -d '\r')"
	if printf '%s' "${got}" | grep -q 'ORIGIN-SENTINEL' ||
		printf '%s' "${got}" | grep -qi '^x-codetracer-front-door:'; then
		bad "${label} stays static"
		printf '%s\n' "${got}" | head -8 | sed 's/^/      /'
	else
		ok "${label} stays static"
	fi
}

last_response=""
expect_origin "GET /api/v1/x" "/api/v1/x"
# `_headers` ends in a `/*` rule that would make this response publicly
# cacheable. It must not apply to a forwarded response: exactly one
# Cache-Control, and it is the front door's.
cc_lines="$(printf '%s' "${last_response}" | grep -ci '^cache-control:' || true)"
if [ "${cc_lines}" -eq 1 ] &&
	printf '%s' "${last_response}" | grep -qi '^cache-control: *private, *no-store'; then
	ok 'the static `_headers` rules do not reach a forwarded API response'
else
	bad "the static \`_headers\` rules do not reach a forwarded API response (${cc_lines} Cache-Control line(s))"
fi
expect_origin "GET /api/v1 (the prefix itself)" "/api/v1"
expect_origin "GET /auth/desktop" "/auth/desktop?desktop-port=4242"
if printf '%s' "${last_response}" | grep -q 'GET /auth/desktop?desktop-port=4242 '; then
	ok "the query string is forwarded unchanged"
else
	bad "the query string is forwarded unchanged"
fi
expect_origin "a share-link landing page" "/acme/${share_id}/download"
expect_origin "a share-link landing page with a trailing slash" "/acme/${share_id}/download/"
expect_origin "POST /api/v1/tenants/t/traces/upload-url" \
	"/api/v1/tenants/t/traces/upload-url?probe=1" \
	-X POST -H 'Content-Type: application/json' --data '{"recordingId":"r-1"}'
if printf '%s' "${last_response}" |
	grep -qF 'POST /api/v1/tenants/t/traces/upload-url?probe=1 body={"recordingId":"r-1"}'; then
	ok "the method, query and body of a POST are forwarded"
else
	bad "the method, query and body of a POST are forwarded"
fi

expect_static "a three-segment path whose middle is not a UUID" "/acme/not-a-uuid/download"
expect_static "a share-link shape with an extra segment" "/acme/${share_id}/download/more"
expect_static "/api/v2/x (not the forwarded API version)" "/api/v2/x"
expect_static "/authority (a prefix match is a whole segment)" "/authority"
expect_static "an anonymous / (still the static bundle)" "/"

echo
echo "Step 7: the platform origin — the override, an empty override, and the default"
# Step 6 ran with PLATFORM_ORIGIN bound to A while the function's default is
# B, so every `ORIGIN-SENTINEL A` above is the override winning.
ok "a non-empty PLATFORM_ORIGIN overrides the default (step 6 reached A, not B)"

# expect_origin_named LABEL NAME — `/api/v1/x` is answered by origin NAME.
expect_origin_named() {
	local label="$1" name="$2" got
	got="$(curl -sS "http://127.0.0.1:${front_port}/api/v1/x" 2>/dev/null || true)"
	if printf '%s' "${got}" | grep -q "ORIGIN-SENTINEL ${name} "; then
		ok "${label}"
	else
		bad "${label} — got: $(printf '%s' "${got}" | head -c 200)"
	fi
}

if start_wrangler "${work}/wrangler-default.log"; then
	expect_origin_named "with no PLATFORM_ORIGIN, the generated default answers" B
else
	bad "wrangler started with no PLATFORM_ORIGIN"
	tail -10 "${work}/wrangler-default.log" | sed 's/^/      /'
fi

if start_wrangler "${work}/wrangler-empty.log" --binding "PLATFORM_ORIGIN="; then
	expect_origin_named "an EMPTY PLATFORM_ORIGIN is ignored, not used" B
else
	bad "wrangler started with an empty PLATFORM_ORIGIN"
	tail -10 "${work}/wrangler-empty.log" | sed 's/^/      /'
fi

echo
echo "CHECKS: $((pass + fail))"
echo "$((pass + fail)) check(s): ${pass} OK, ${fail} FAILED"
[ "${fail}" -eq 0 ]
