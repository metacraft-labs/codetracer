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
wrangler_pid=""
cleanup() {
	[ -n "${wrangler_pid}" ] && kill "${wrangler_pid}" 2>/dev/null
	[ -n "${origin_pid}" ] && kill "${origin_pid}" 2>/dev/null
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

# --------------------------------------------------------------------------
# A stub platform origin. It echoes which path it was asked for and sets a
# cacheable header plus a Set-Cookie, so the middleware's two header duties —
# deleting the upstream's caching headers, and rebuilding Set-Cookie rather
# than folding it — are observable rather than assumed.
# --------------------------------------------------------------------------
python3 - "${work}/origin.port" <<'PY' &
import http.server, socketserver, sys, threading

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = ("ORIGIN-SENTINEL " + self.path).encode()
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
        self.wfile.write(body)
    def log_message(self, *a): pass

with socketserver.TCPServer(("127.0.0.1", 0), H) as httpd:
    open(sys.argv[1], "w").write(str(httpd.server_address[1]))
    httpd.serve_forever()
PY
origin_pid=$!

for _ in $(seq 1 50); do
	[ -s "${work}/origin.port" ] && break
	sleep 0.1
done
origin_port="$(cat "${work}/origin.port" 2>/dev/null || true)"
if [ -z "${origin_port}" ]; then
	bad "the stub origin started"
	echo "CHECKS: $((pass + fail))"
	exit 1
fi
ok "the stub origin started on ${origin_port}"

echo
echo "Step 2: serve it with the pinned wrangler, from the CWD the deploy uses"
front_port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
(
	cd "${work}" || exit 1
	wrangler pages dev dist \
		--port "${front_port}" --ip 127.0.0.1 \
		--binding "PLATFORM_ORIGIN=http://127.0.0.1:${origin_port}" \
		>"${work}/wrangler.log" 2>&1
) &
wrangler_pid=$!

ready=0
for _ in $(seq 1 120); do
	if curl -sS -o /dev/null "http://127.0.0.1:${front_port}/" 2>/dev/null; then
		ready=1
		break
	fi
	sleep 0.5
done
if [ "${ready}" -ne 1 ]; then
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
echo "CHECKS: $((pass + fail))"
echo "$((pass + fail)) check(s): ${pass} OK, ${fail} FAILED"
[ "${fail}" -eq 0 ]
