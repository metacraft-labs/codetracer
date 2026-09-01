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
#   * A CHECK ON THE INSTRUMENT ITSELF (arm I, and it runs first). The text
#     assertion reads `innerText`, which is the RENDERED text, so it is a
#     statement about the browser as much as about the page. This gate's first
#     run in CI blocked a deploy over a bundle that was correct — the runner's
#     nix shell shipped Chromium with no fonts, it drew zero glyphs, and 46
#     mounted elements reported 0 characters of text. Arm I measures a plain
#     two-line fixture through the same server and probe, so that failure now
#     names the environment instead of the product.
#
# WHAT THIS GATE ITSELF MISSED, and arms D, R, S, V and O are the correction
# -------------------------------------------------------------------------
# On 2026-09-01 `https://ide.codetracer.com/noir` opened the WELCOME SCREEN
# rather than the Noir template. This gate was green throughout, and it could
# not have been anything else: every arm above loaded `/`, and a build that
# resolves the entry URL and a build that ignores it produce byte-identical
# DOMs at `/`. The gate asserted the product, thoroughly, at one address.
#
# The defect had two independent halves, and each has an arm now:
#
#   * THE CLIENT HALF. `platform/web_entry.classifyPath` classified `/noir`
#     correctly, `resolveEntry` implemented all six of §1b.3's steps, and
#     `host/web_browser.currentEntryRequest` read the location — and
#     `currentEntryRequest` had ZERO CALLERS. `ui_js.nim` mounted the welcome
#     screen unconditionally. Arm R loads `/noir` on the same bundle and
#     asserts the template; arm S stubs the location read to a constant `/`
#     and shows arm R going red, which is the shipped state reconstructed.
#
#   * THE CDN HALF. `renderRewriteConfig` targeted `/index.html`, and
#     Cloudflare Pages answers that with `308 -> /`. So the language was
#     destroyed before any script ran, and no client fix could have survived
#     it. Arm D asserts the shipped `_redirects` targets nothing the host will
#     normalise.
#
#   * A THIRD HALF FOUND WHILE FIXING THE OTHER TWO, and it is why arm V
#     exists. The first template surface mounted into `#isonim-app`, which the
#     entry document places before `#root-container` — so
#     `#session-container-0` painted over the whole panel. Measured at the
#     time: 1 filesystem panel, 7 entries, the right labels, `rgb(243,243,243)`
#     on `rgb(27,27,27)`, real geometry, `innerText` unchanged — and a
#     uniformly dark screenshot. Every DOM assertion in arm R was green over a
#     page showing the user nothing. `innerText` cannot catch it, because the
#     text was rendered and then covered, so arm R now hit-tests each row with
#     `elementFromPoint` and arm V paints over the page to show that check
#     works. Arm V's own first version was wrong in an instructive way — see
#     its comment.
#
#   * AND THE SAME CLASS OF DEFECT ONE AXIS OVER, which arm O forecloses.
#     `noirstudio.dev` is to be the Noir entry point the way
#     `ide.codetracer.com/noir` is: one Pages project, one tree, two custom
#     domains, and `/` meaning different things on each because the page reads
#     its own origin out of the deployment descriptor. Every arm above loads
#     ONE host, so a change that quietly made the second domain land on the
#     generic root would survive all of them — which is exactly how `/noir`
#     survived. Arm O loads the same directory through a mapped hostname AND
#     through the loopback address, and asserts the two show different
#     surfaces.
#
# VERIFIED TO REDDEN, each against the assertion written for it:
#   * arm S, in-gate: reddens arm R's mount, tree and renderer-line checks and
#     leaves `/` untouched.
#   * arm V, in-gate: reddens arm R's VISIBILITY check alone and leaves the
#     mount green — the pair that distinguishes "not there" from "covered".
#   * restoring `/index.html` as the target in a copied bundle: 1 red, and it
#     is arm D's target check.
#   * arm O's own twin, in-gate: the SAME bundle on an undeclared origin must
#     still open the welcome screen, so the arm is a claim about the origin and
#     not about a build that started mounting the template everywhere.
#   * the two status-line assertions: verified by a bundle that keeps the
#     diagnostic in the page AND removes the `#menu` that happens to cover it.
#     Exactly those two go red, 37 still run, and the control's painted count
#     moves 328 -> 672 — so the paint measurement tracks reality rather than
#     reporting a constant. Note the un-hiding ALONE is not enough: `#menu` and
#     the welcome overlay both occlude the line, which is precisely why its
#     invisibility was luck and not design.
#   * arm O's equivalence check: verified discriminating rather than constant —
#     over the same run's reports, the two ways into the template hash equal
#     (6083830ff511b7d8) while the template and the welcome screen hash
#     differently (6083830ff511b7d8 vs dfeb0dfd1ddd095b). A comparator that
#     could not tell those apart would assert nothing.
#   * deleting `_redirects` from a copied bundle: 8 red, led by arm D's
#     "ships no _redirects" and arm R's non-vacuity guard — which is the guard
#     doing its job, since `/noir` then 404s and every count is 0.
#
# THE INSTRUMENT WAS OVERCOUNTING, AND THE OVERCOUNT WAS THE DIAGNOSTIC
# ---------------------------------------------------------------------
# This gate asserted `visibleTextLength > 200` — `innerText` — as its "there
# is a product on this page" check. `innerText` is defined over RENDERED text
# but not over VISIBLE text: it counts glyphs that are laid out and then
# painted over. Measured on the deployed `/noir`, 2026-09-01:
#
#     innerText            425 characters
#     readable by a user    46 characters   (the six template file names)
#     the other 379         `#codetracer-boot`, sitting under `#menu`
#
# So the check was satisfied almost entirely by a developer log line nobody
# can see, and a page that rendered nothing else would have passed it. The
# boot line was never hidden; it was merely LUCKY, occluded by an element that
# happens to come later in the document.
#
# Both halves are fixed. The renderer now hides both status lines once a
# surface mounts, and the probe measures `paintedText` — every text node
# boxed with a Range and hit-tested at its centre. A Range is required rather
# than an element walk, and the first attempt proved it: an element-level walk
# skipped the tree's labels (their anchors also contain an icon element) and
# reported ZERO painted characters for a page whose six labels are plainly
# legible. That would have been read as a product defect. It was a measurement
# defect.
#
# THE TWO HOSTS ARE ONE SCREEN, AND ARM O NOW ASSERTS IT
# ------------------------------------------------------
# A user reported `noirstudio.dev` and `ide.codetracer.com/noir` showing
# different content. Measured, they were identical: 42 visible elements with
# the same tags, ids, classes, rects and paint status, and pixel-identical
# screenshots (same SHA-256). The real cause was in the USER'S BROWSER — a
# cached 308 from the CDN defect, which no deployment can revoke; see
# `platform/web_deployment.entryDocumentAddress`.
#
# The report was still right to make, because the property was UNASSERTED.
# `hostLanguage` is a live input to the render dispatch, and nothing stopped
# the two paths diverging. `renderedTree` is now a comparable value and arm O
# asserts the digests match.
#
# NON-VACUITY. Every DOM assertion is guarded by `domRootPresent` being
# reported first: a probe that failed to reach the page produces an empty
# object, and "no `.welcome-screen-root` found" over nothing would otherwise be
# indistinguishable from a blank product. Trap 4, the empty haystack. Arm I is
# the same principle applied one level up, to the measuring device.
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
#
# IT APPLIES THE BUNDLE'S OWN `_redirects`, and that is not a convenience.
#
# A bare `SimpleHTTPRequestHandler` 404s `/noir`, because the bundle contains
# no file of that name — the deployment's §1b.4 rewrite is what makes the
# address reach the application. A route arm served without it would measure
# THIS SERVER and report the product as broken at a URL the CDN serves fine.
#
# The rules are read from `${dir}/_redirects`, which `renderRewriteConfig`
# generated from `rewritePrefixes()`. So the harness routes by the same table
# the CDN is given, and a prefix added to the product reaches this server
# without anybody editing it — the property the generated file exists for. A
# hand-written list of paths here would be the second implementation of "which
# prefixes exist" that `web_entry.classifyPath`'s header warns about.
#
# Only `200` rows are honoured. A `30x` row is deliberately NOT followed: the
# whole defect this arm exists for was a rewrite that a host turned into a
# redirect, and a harness that quietly followed redirects could not see it.
cat >"${cache}/serve.py" <<'PY'
import http.server, os, socketserver, sys

directory = sys.argv[1]


def load_rewrites(root):
    """[(prefix, is_splat, target)] from the generated _redirects, 200 rows only."""
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
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=directory, **kw)

    def translate_rewrite(self, path):
        request = path.split('?', 1)[0].split('#', 1)[0]
        # A real file always wins, exactly as it does on the host: the rewrite
        # table must never shadow `/ui.js` or `/assets/...`.
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
            # `/` is the entry document's canonical address — see
            # `web_deployment.entryDocumentAddress`. Serve its bytes at the
            # REQUESTED url, with no redirect, which is what `200` means.
            self.path = target
        return super().send_head()

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
# Serve a directory and probe it. Split out of `run_arm` so the INSTRUMENT arm
# below can measure a two-line fixture through the same server, the same
# browser and the same probe as the product — a self-check that reads a
# different instrument than the one it is vouching for would vouch for nothing.
# ---------------------------------------------------------------------------
probe_dir() {
	# `probe_dir <label> <dir> [url-path]`. The path defaults to `/`, which is
	# every existing arm's subject and the ONLY address this gate ever loaded —
	# the reason a router that ignored the URL passed it for weeks.
	# `probe_dir <label> <dir> [url-path] [map-host]`. The path defaults to
	# `/`; `map-host` loads the same server through a foreign hostname, which
	# is how the two-domain routing is measured — see the probe's own comment.
	local label="$1" dir="$2" url_path="${3:-/}" map_host="${4:-}"
	if ! start_server "${dir}"; then
		echo "  the static server did not start" >&2
		return 2
	fi
	local url="http://127.0.0.1:${port}${url_path}"
	local host_map=""
	if [ -n "${map_host}" ]; then
		# Composed HERE and not by the caller, because the port is only known
		# once the OS has handed it out.
		host_map="MAP ${map_host} 127.0.0.1:${port}"
		url="http://${map_host}${url_path}"
	fi
	local shot=""
	if [ -n "${CT_PROBE_SCREENSHOT_DIR:-}" ]; then
		mkdir -p "${CT_PROBE_SCREENSHOT_DIR}"
		shot="${CT_PROBE_SCREENSHOT_DIR}/${label}.png"
	fi
	CT_PROBE_SCREENSHOT="${shot}" CT_PROBE_HOST_MAP="${host_map}" \
		node ci/test/web_renderer_probe.mjs "${url}" \
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

# ---------------------------------------------------------------------------
# One arm: copy, mutate, serve, probe, print the JSON to a file.
# ---------------------------------------------------------------------------
run_arm() {
	local label="$1" mutate="$2" url_path="${3:-/}" map_host="${4:-}"
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
	probe_dir "${label}" "${arm_dir}" "${url_path}" "${map_host}"
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

# The painted-text pair, and the rendered-tree digest. Separate readers because
# `json` collapses a list to its length, which is right for counting elements
# and wrong for comparing two trees or quoting what a user can read.
painted_len() {
	python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print((d.get("dom", {}).get("paintedText") or {}).get("painted", -1))
' "${cache}/$1.json" 2>/dev/null
}
painted_shown() {
	python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(" ".join((d.get("dom", {}).get("paintedText") or {}).get("shown", [])))
' "${cache}/$1.json" 2>/dev/null
}
tree_digest() {
	python3 -c '
import hashlib, json, sys
d = json.load(open(sys.argv[1]))
rows = d.get("dom", {}).get("renderedTree") or []
print(hashlib.sha256("\n".join(rows).encode()).hexdigest() if rows else "EMPTY")
' "${cache}/$1.json" 2>/dev/null
}

# Everything the probe collected and no assertion reads. Printed only when an
# arm has already failed, because the previous version of this gate discarded
# it: the run that blocked a deploy said `only 0 characters of text are on
# screen` and nothing else, and the two facts that would have named the cause
# in the log — that no request had 404'd, and that the DOM's own text was
# present — were both sitting in the report it had just parsed.
dump_arm() {
	local label="$1"
	printf '      --- what the probe saw on arm %s ---\n' "${label}"
	python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
dom = d.get("dom", {})
print("      title:            %r" % dom.get("title"))
print("      loadError:        %r" % d.get("loadError"))
print("      failedRequests:   %s" % (d.get("failedRequests") or "none"))
print("      pageErrors:       %s" % (d.get("pageErrors") or "none"))
print("      domTextLength:    %s (textContent: the DOM)" % dom.get("domTextLength"))
print("      visibleTextLength:%s (innerText: what is DRAWN)" % dom.get("visibleTextLength"))
print("      visibleText:      %r" % (dom.get("visibleText") or "")[:400])
' "${cache}/${label}.json" 2>/dev/null ||
		printf '      (the report could not be read)\n'
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

# Arm S — THE DEFECT THIS ROUTE ARM EXISTS FOR, reconstructed exactly.
#
# `https://ide.codetracer.com/noir` opened the welcome screen, because
# `ui_js.nim`'s web arm mounted one surface at every address and never asked
# what URL the visitor arrived on. `platform/web_entry.classifyPath`,
# `resolveEntry` and `host/web_browser.currentEntryRequest` were all present,
# all correct and all tested; `currentEntryRequest` had ZERO callers.
#
# This mutation puts the renderer back in that state with one substitution:
# the location read becomes a constant `/`. Everything else — the classifier,
# the template, the mount — is untouched and still runs, which is what makes
# the arm specific. A router that is consulted but wrong would fail
# differently, and an arm that deleted the whole entry layer would redden
# every assertion and prove nothing about any of them.
#
# `String(window.location.pathname || '/')` is `ui/web_entry_surface.nim`'s
# `jsEntryPath` importjs body, emitted verbatim by the Nim JS backend. Note
# that grepping for a Nim STRING LITERAL here would find nothing — the backend
# emits those as char-code arrays — but an `importjs` pattern is emitted as
# source, which is why this mutation can be a text substitution at all.
mutate_route_blind() {
	local dir="$1"
	grep -q "String(window.location.pathname || '/')" "${dir}/ui.js" || return 1
	python3 - "${dir}/ui.js" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read()
needle = "String(window.location.pathname || '/')"
assert s.count(needle) == 1, s.count(needle)
open(p, 'w').write(s.replace(needle, "String('/')"))
PY2
}

# Arm E — THE HOST ANSWERS `tab-load` SYNCHRONOUSLY, and the editor is blank.
#
# Measured, not invented: this is the state the first working version of the
# in-page host was in for one build. `utils.asyncSend` calls `ipc.send` from
# INSIDE its promise executor and registers `asyncSendCache[id][argId]` on the
# line AFTER the promise is constructed, so a responder that replies before
# returning resolves the future too early and the resolve wrapper's
# `jsdelete data.asyncSendCache[id][argId]` throws
# `TypeError: Cannot convert undefined or null to object`.
#
# What that produced is precisely the failure this gate's new checks exist to
# separate: the topbar, the layout and the file tree were all correct and the
# EDITOR PANE WAS ABSENT, because `openNewEditorView` never got past its await
# and so never built one. So this arm must redden the editor checks and leave
# the tree and topbar checks green — anything else and the pair is not
# isolating the pane from the page.
#
# The substitution is one line, and `deferHostReply` exists as a named helper
# in `ui_js.newWebIpc` so that it can be. An inline `setTimeout(fn, 0)` would
# need a needle that also matches the renderer's several hundred other timers.
mutate_sync_host_reply() {
	local dir="$1"
	local needle="var deferHostReply = function (fn) { setTimeout(fn, 0); };"
	grep -qF "${needle}" "${dir}/ui.js" || return 1
	python3 - "${dir}/ui.js" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read()
needle = "var deferHostReply = function (fn) { setTimeout(fn, 0); };"
assert s.count(needle) == 1, s.count(needle)
open(p, 'w').write(s.replace(
    needle, "var deferHostReply = function (fn) { fn(); };"))
PY2
}

# Arm T — THE TOPBAR'S CONTAINER IS NOT IN THE DOCUMENT.
#
# The twin of arm B one element over. Arm B removes the container the SURFACE
# mounts into and shows that nothing mounts; this removes the container the
# CHROME mounts into and must leave the surface alone — the layout, the tree
# and the editor all still there, and only the topbar assertion red.
#
# It is a document mutation rather than a bundle one because that is what the
# defect would be: `#menu` comes from the entry document that
# `platform/web_deployment.renderEntryDocument` generates, and a skeleton that
# drifted from `src/frontend/index.html` is exactly how the web arm would lose
# a piece of chrome the desktop keeps. §1a.1 names that hazard directly — "two
# divergent documents would be the first place that stops being true".
mutate_no_menu() {
	local dir="$1"
	grep -q 'id="menu"' "${dir}/index.html" || return 1
	python3 - "${dir}/index.html" <<'PY2'
import re, sys
p = sys.argv[1]
s = open(p).read()
out = re.sub(r'<div[^>]*id="menu"[^>]*>.*?</div>', '', s, count=1, flags=re.S)
if out == s:
    out = re.sub(r'<div[^>]*id="menu"[^>]*/?>', '', s, count=1)
assert out != s
open(p, 'w').write(out)
PY2
}

# Arm V — THE SURFACE IS MOUNTED AND A USER CANNOT SEE IT.
#
# Not hypothetical: it is what the first version of the template surface did.
# It mounted into `#isonim-app`, which the entry document places BEFORE
# `#root-container`, so `#session-container-0` painted over the whole panel.
# Everything measured correct — 1 panel, 7 entries, the right labels, light
# text on a dark background, real geometry, `innerText` unchanged at 422
# characters — and the screenshot was uniformly dark.
#
# THE MUTATION IS AN OVERLAY RATHER THAN THE ORIGINAL MISTAKE, and the reason
# is worth recording because the first attempt was wrong. Moving the mount
# target back is not available to a shell: the id travels as a Nim string
# literal and the JS backend emits those as char-code arrays, so there is no
# text in `ui.js` to substitute (the same property that makes arm S possible
# only because ITS subject is an `importjs` body, which IS emitted as source).
#
# The obvious substitute — making `#session-container-0` a fixed opaque box —
# was tried and does NOT work, which the arm caught by going red at 6 of 7
# rows instead of 0: the surface mounts INTO `#main`, a descendant of that
# container, so covering it moves the panel with it rather than over it.
#
# So the mutation adds an opaque element after everything, which is the
# GENERAL form of the defect — a correct, mounted, correctly-coloured surface
# that the user cannot see — and it is what arm R's visibility assertion
# claims to detect. It must take the rows to ZERO while leaving the panel
# mounted; anything else and the pair is not isolating paint from presence.
mutate_covered_surface() {
	local dir="$1"
	grep -q '</div>' "${dir}/index.html" || return 1
	python3 - "${dir}/index.html" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read()
marker = '<script src="/public/dist/frontend_bundle.js" defer></script>'
assert s.count(marker) == 1
overlay = ('<div id="ct-occlusion-arm" style="position:fixed;inset:0;'
           'background:#1e1e1e;z-index:2147483647"></div>\n')
open(p, 'w').write(s.replace(marker, overlay + marker))
PY2
}

# Arm O — CONFIGURE THE BUNDLE AS A TWO-DOMAIN DEPLOYMENT.
#
# `noirstudio.dev` is meant to be the Noir entry point the way
# `ide.codetracer.com/noir` is: one Pages project, ONE tree, two custom
# domains, and the visitor staying on the domain they typed. Nothing about the
# artifact differs — what differs is what `/` means, and that is one entry in
# the deployment descriptor the page reads out of its own DOM.
#
# So this is not a mutation in the "break it" sense: it is the deploy-time
# argument `CT_WEB_LANGUAGE_ORIGINS` supplies, applied to an already-assembled
# bundle. The gate cannot re-run the assembly with a different origin (the
# bundle is the subject, and CI hands it one), so it edits the one declaration
# the assembly would have written.
#
# `noirstudio.test` rather than the real domain, and `.test` rather than `.dev`
# deliberately: RFC 6761 reserves `.test` for exactly this, and a gate that
# named the production hostname would be one DNS mistake away from measuring
# the internet instead of the bundle.
language_host="noirstudio.test"
configure_language_host() {
	local dir="$1"
	grep -q 'id="codetracer-deployment"' "${dir}/index.html" || return 1
	CT_LANGUAGE_HOST="${language_host}" python3 - "${dir}/index.html" <<'PY2'
import json, os, re, sys
p = sys.argv[1]
s = open(p).read()
host = "http://" + os.environ["CT_LANGUAGE_HOST"]
m = re.search(r'(<script type="application/json" id="codetracer-deployment">)'
              r'(.*?)(</script>)', s, re.S)
assert m, "no deployment descriptor in the entry document"
# The document escapes `<`, `>` and `&` so its own metadata cannot truncate the
# script element. Undo, edit, redo — the same transform `jsonStringForHtml`
# applies, because writing raw JSON back would leave a document the renderer
# reads differently from this arm.
raw = m.group(2).replace('\\u003c', '<').replace('\\u003e', '>').replace('\\u0026', '&')
d = json.loads(raw)
d.setdefault("languageOrigins", []).append({"origin": host, "language": "noir"})
out = json.dumps(d, separators=(",", ":"))
out = out.replace('<', '\\u003c').replace('>', '\\u003e').replace('&', '\\u0026')
open(p, 'w').write(s[:m.start(2)] + out + s[m.end(2):])
PY2
}

# ---------------------------------------------------------------------------
echo "Arm I: THE INSTRUMENT — can this browser draw a letter at all?"
echo '    Before the product is measured, the measurement is. `innerText` is'
echo "    defined over RENDERED text, so a browser with no font reports an"
echo "    empty page for correct markup — and this gate would blame the"
echo "    product for its own runner."
# ---------------------------------------------------------------------------
#
# THIS ARM IS THE REASON THE GATE IS TRUSTWORTHY AT ALL, and it exists because
# the gate was wrong once in exactly this way. On 2026-08-31 it blocked a
# deploy with `only 0 characters of text are on screen` over a bundle whose DOM
# was byte-for-byte the one that renders correctly on a developer's machine:
# 2337 bytes of markup, 46 elements, `.welcome-screen-root` mounted, five start
# options, both panels, no page errors, both arms reporting `ok`. The runner's
# Chromium came from `playwright-driver.browsers` in a nix shell that provided
# no fonts and no fontconfig, so it laid out every string with zero glyphs.
#
# Traps doc 4, the empty haystack, one level up: a negative result over an
# instrument that cannot produce a positive one is not evidence. So the
# instrument gets a control (text renders) and a mutation (the same
# measurement returns 0 when the text is genuinely gone), and if the control
# fails this script says so about the ENVIRONMENT and does not pretend to have
# measured a product.
#
# VERIFIED TO REDDEN. Serving the `yes` fixture with `visibility: hidden` on
# its one element reproduces a browser that cannot draw: `domTextLength` stays
# 47 and `visibleTextLength` goes to 0 — the CI signature exactly. The run
# reddened THIS assertion, printed the pair, took the early exit, and reached
# `expect_count 2` without a count mismatch. That is the whole failure path,
# and it is the one that had never executed.
instrument_dir="${cache}/instrument"
rm -rf "${instrument_dir}"
mkdir -p "${instrument_dir}/yes" "${instrument_dir}/no"
# Deliberately plain: no webfont, no stylesheet, the default font stack. If
# this does not render, nothing the product ships could have.
cat >"${instrument_dir}/yes/index.html" <<'HTML'
<!DOCTYPE html><meta charset="utf-8"><title>instrument</title>
<div id="dom-root">the instrument can draw letters in this browser</div>
HTML
cat >"${instrument_dir}/no/index.html" <<'HTML'
<!DOCTYPE html><meta charset="utf-8"><title>instrument</title>
<div id="dom-root"></div>
HTML

instrument_ok=1
if ! probe_dir instrument-yes "${instrument_dir}/yes"; then
	ck fail "the instrument arm could not be measured"
	instrument_ok=0
else
	i_text="$(json instrument-yes dom.visibleTextLength)"
	if [ "${i_text:-0}" -ge 40 ] 2>/dev/null; then
		ck ok "this browser renders text: ${i_text} characters off a plain page"
	else
		ck fail "this browser rendered ${i_text} characters of a 47-character page — it has no usable font, and every text check below would be measuring the RUNNER"
		dump_arm instrument-yes
		note "FIX THE ENVIRONMENT, NOT THE ASSERTION. nix/shells/ci-base.nix"
		note "exports FONTCONFIG_FILE for exactly this; a shell without it gives"
		note "Chromium no font to shape with."
		instrument_ok=0
	fi
fi
if ! probe_dir instrument-no "${instrument_dir}/no"; then
	ck fail "the instrument's mutation arm could not be measured"
else
	i_blank="$(json instrument-no dom.visibleTextLength)"
	if [ "${i_blank}" = "0" ]; then
		ck ok "and it reports 0 for a page with no text, so the measurement is not a constant"
	else
		ck fail "the instrument reported ${i_blank} characters for an empty page; this measurement cannot distinguish a blank product from a rendered one"
	fi
fi
if [ "${instrument_ok}" -eq 0 ]; then
	echo
	echo "RESULT: FAILED — the instrument is broken, so no verdict about the" >&2
	echo "        product was reached. This is NOT 'the page is blank'." >&2
	expect_count 2
	exit 1
fi
echo

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
c_painted="$(painted_len control)"
if [ "${c_painted:-0}" -gt 200 ] 2>/dev/null; then
	ck ok "${c_painted} characters of text are PAINTED (of ${c_text} laid out)"
else
	ck fail "only ${c_painted} characters are painted (innerText claims ${c_text}) — the difference is text a user cannot see"
	# Arm I has already established that this browser CAN draw letters, so
	# this is the product. Print what the probe saw anyway: the difference
	# between `domTextLength` and `visibleTextLength` says whether the markup
	# is there and hidden, or not there at all.
	dump_arm control
fi

# THE DIAGNOSTICS ARE NOT PART OF THE PRODUCT, and this is where that becomes
# an assertion rather than an intention.
#
# `visibleTextLength` — `innerText` — counts text that is laid out and then
# painted over. On the deployed `/noir`, 2026-09-01: 425 characters by that
# measure, 46 readable, and the other 379 were the boot diagnostic sitting
# under `#menu`. The check above USED to read that number, so "there is a
# product on this page" was satisfied almost entirely by a developer log line
# nobody can see. A page rendering nothing else would have passed it.
#
# Two things changed. The renderer hides both status lines once a surface
# mounts, and this asserts it — so the diagnostic cannot come back as the
# thing keeping the text assertion green.
case "$(painted_shown control)" in
*"codetracer-web-boot"* | *"codetracer-web-renderer"*)
	ck fail "a status line is PAINTED on a page that mounted: '$(painted_shown control)' — the diagnostics must leave the document once the product is on it, or the text assertion above is measuring them" ;;
*)
	ck ok "no status line is painted once the product mounted, so the text count above is the product's own" ;;
esac

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
echo "Arm D: THE HOSTING CONTRACT — no rewrite targets a path the host will"
echo "       normalise into a redirect"
# ---------------------------------------------------------------------------
#
# §1b.4, the one clause it states in bold: the entry document is "served **200
# rather than 302**". `renderRewriteConfig` emitted `/index.html` as every
# rule's target, and Cloudflare Pages answers `/index.html` with a 308 to `/`
# — its automatic clean-URL normalisation, the same one that turns
# `/replay-demo.html` into `/replay-demo`. So every rule that actually matched
# became a redirect, and `https://ide.codetracer.com/noir` moved the address
# bar to `/` before a single script ran. Measured on the live deployment,
# 2026-09-01; see `web_deployment.entryDocumentAddress`.
#
# This reads the SHIPPED file rather than the Nim value, because the Nim value
# is asserted by `test_platform_web.nim` and the two failures are different:
# a wrong constant is caught there, a bundle assembled from a stale renderer is
# caught here.
redirects_file="${bundle}/_redirects"
if [ ! -s "${redirects_file}" ]; then
	ck fail "the bundle ships no _redirects, so §1b.4's rewrite table is absent entirely"
	ck fail "and there is therefore nothing to check its targets against"
else
	rw_total="$(awk '$3 == "200" { n++ } END { print n + 0 }' "${redirects_file}")"
	rw_bad="$(awk '$3 == "200" && $2 ~ /index\.html$/ { n++ } END { print n + 0 }' "${redirects_file}")"
	# NON-VACUITY: a file with no 200 rows would make the "none are bad" check
	# below true for the emptiest possible reason. `rewritePrefixes()` yields
	# five prefixes and two rows each.
	# Six prefixes, two rows each: `/noir`, `/new`, `/s`, `/p`, `/projects`,
	# `/collab/join`. `/new` is the clean-start address on a host whose root is
	# already the language (`noirstudio.dev/new`), and it is in the same file
	# because one tree serves every domain the project has.
	if [ "${rw_total}" = "12" ]; then
		ck ok "the shipped _redirects carries ${rw_total} 200-rewrites, so the target check has a subject"
	else
		ck fail "the shipped _redirects carries ${rw_total} 200-rewrites, not the 12 rewritePrefixes() implies"
	fi
	if [ "${rw_bad}" = "0" ]; then
		ck ok "none of them targets /index.html, so the host has nothing left to normalise into a 308"
	else
		ck fail "${rw_bad} rewrite(s) target /index.html — Cloudflare Pages answers that with a 308 to /, which is the redirect §1b.4 forbids and the defect that shipped"
		grep -n 'index\.html' "${redirects_file}" | sed 's/^/      /'
	fi
fi
echo

# ---------------------------------------------------------------------------
echo "Arm R: THE ROUTE — /noir opens the bundled Noir template, not the"
echo "       welcome screen"
# ---------------------------------------------------------------------------
#
# THE ASSERTION THAT WOULD HAVE CAUGHT THIS, and the reason the gate above did
# not: every arm before this one loads `/`. A build that resolves the entry and
# a build that ignores it produce byte-identical DOMs at `/`, so no number of
# assertions over that one address can tell them apart. The subject here is a
# DIFFERENT URL on the SAME bundle.
#
# It pairs with the control arm rather than replacing it: `/` must still be the
# welcome screen (rule 0 — the language-neutral root names no language, so
# there is no template to select) and `/noir` must not be. Either assertion
# alone is satisfiable by a product that mounts one thing everywhere.
if ! run_arm route "" "/noir"; then
	ck fail "arm R could not be measured"
	ck fail "arm R could not be measured (second half)"
	ck fail "arm R could not be measured (third half)"
	ck fail "arm R could not be measured (fourth half)"
	ck fail "arm R could not be measured (fifth half)"
	ck fail "arm R could not be measured (sixth half)"
else
	r_present="$(json route dom.domRootPresent)"
	r_welcome="$(json route dom.welcomeScreenRoots)"
	r_fs="$(json route dom.filesystemPanels)"
	r_entries="$(json route dom.filesystemEntries)"
	r_errs="$(json route pageErrors)"
	r_renderer="$(json route rendererLine)"
	r_labels="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(" ".join(d.get("dom", {}).get("entryLabels") or []))
' "${cache}/route.json" 2>/dev/null)"

	# NON-VACUITY, same rule as the control arm: `welcomeScreenRoots == 0` over
	# a page the probe never reached is indistinguishable from a correct route.
	if [ "${r_present}" = "True" ]; then
		ck ok "arm R: /noir served the application document, so the checks below have a subject"
	else
		ck fail "arm R: /noir produced no #dom-root — the rewrite did not reach the SPA and every check below would be vacuous"
		dump_arm route
	fi

	# THE BUG REPORT, as one assertion. "I am taken immediately to the Welcome
	# Screen of CodeTracer instead of the intended Noir template project."
	if [ "${r_welcome}" = "0" ] && [ "${r_fs}" = "1" ]; then
		ck ok "arm R: /noir mounted the project's filesystem panel and NO welcome screen"
	else
		ck fail "arm R: /noir mounted ${r_welcome} welcome screen(s) and ${r_fs} filesystem panel(s) — the reported defect is ${r_welcome} and 0"
		dump_arm route
	fi

	# ...and that what mounted is THE TEMPLATE, not merely a panel of the right
	# shape. `noir_template.noirHelloWorld` is the only source of these names.
	case "${r_labels}" in
	*"main.nr"*)
		case "${r_labels}" in
		*"Nargo.toml"*)
			ck ok "arm R: the tree is the Noir template — ${r_entries} entries: ${r_labels}" ;;
		*)
			ck fail "arm R: the tree has no Nargo.toml; a Noir project without one is not one (labels: ${r_labels})" ;;
		esac ;;
	*)
		ck fail "arm R: the tree has no main.nr (labels: '${r_labels}') — a filesystem panel mounted, but not over the template" ;;
	esac

	# THE PRODUCT'S OWN ACCOUNT OF THE ROUTE. The DOM says what mounted; this
	# says what the product THOUGHT it was doing, and a disagreement between
	# the two is a different bug from either being wrong alone.
	#
	# `surface=edit-mode`, and the word is the assertion. It used to be
	# `surface=noir-template`, which named a web-only surface that drew a
	# filesystem panel and nothing else. `ui/web_entry_surface` now delivers
	# `CODETRACER::no-trace` — the message `ct edit <path>` and the welcome
	# screen's "open recent folder" both send — so what mounts is CodeTracer in
	# Edit mode. A gate still accepting the old word would accept a build that
	# went back to the parallel path.
	case "${r_renderer}" in
	*"surface=edit-mode"*"entry=efBare/evTemplate"*"language=noir"*)
		ck ok "arm R: the renderer reported the route it took: ${r_renderer#*: }" ;;
	*)
		ck fail "arm R: the renderer line does not report edit mode on the noir route (line: '${r_renderer}')" ;;
	esac

	# THE ASSERTION THE OTHERS COULD NOT MAKE. Every check above this one was
	# green over a page that painted nothing: the panel was mounted, correct,
	# light-on-dark and covered by `#session-container-0`. `innerText` did not
	# move, because the text WAS rendered — it was occluded. So this reads a
	# hit test, and it is the only field here that a covering element changes.
	r_visible="$(json route dom.entryLabelsVisible)"
	if [ "${r_visible}" = "${r_entries}" ] && [ "${r_entries:-0}" -ge 5 ] 2>/dev/null; then
		ck ok "arm R: all ${r_visible} tree rows hit-test to themselves, so a user can see the project and not just the DOM"
	else
		ck fail "arm R: ${r_visible} of ${r_entries} tree rows are visible — the surface is mounted and something is painted over it, which is the state a DOM-only check calls a pass"
		dump_arm route
	fi

	# WHAT A USER CAN ACTUALLY READ ON THIS ROUTE, and it must be the project.
	# The count is small on purpose — six file names is 46 characters — so the
	# assertion is on the CONTENT rather than on a threshold a diagnostic could
	# meet. `innerText` here is 425; the gap is the hidden status lines, which
	# is exactly why this reads `paintedText` instead.
	r_painted="$(painted_len route)"
	r_shown="$(painted_shown route)"
	case "${r_shown}" in
	*"codetracer-web-boot"* | *"codetracer-web-renderer"*)
		ck fail "arm R: a status line is painted on /noir ('${r_shown}') — the route's readable text is a diagnostic, not the project" ;;
	*"main.nr"*)
		ck ok "arm R: the ${r_painted} characters a user can read on /noir are the project's own files: ${r_shown}" ;;
	*)
		ck fail "arm R: the painted text on /noir is '${r_shown}' (${r_painted} chars) — the project's file names are not what a user reads" ;;
	esac

	# -----------------------------------------------------------------------
	# THE FIRST SCREEN IS EDIT MODE, and the four checks below are what
	# separates that claim from "a filesystem panel mounted".
	#
	# Noir-Studio.md §1a: "The first screen is CodeTracer in Edit mode on a
	# working multi-file project — Filesystem, Editor, Test Results,
	# Constraints — not a landing page". What shipped before this was the
	# Filesystem alone, in no layout, with no topbar: 46 readable characters.
	# Every assertion above was green over it, because every one of them was
	# about the file tree.
	#
	# TEST RESULTS AND CONSTRAINTS ARE NOT ASSERTED, and that is deliberate
	# rather than an omission the count hides. `Content` has no member for
	# either on any platform — §1a calls them "new panes this campaign
	# contributes" — so a check for them here would be a check for something
	# no build of CodeTracer contains, and the honest place to add it is the
	# milestone that adds the panes.
	# -----------------------------------------------------------------------
	r_stacks="$(json route dom.glStacks)"
	if [ "${r_stacks:-0}" -ge 2 ] 2>/dev/null; then
		ck ok "arm R: /noir opened a GoldenLayout with ${r_stacks} stacks, so this is the product's layout and not a single panel in a div"
	else
		ck fail "arm R: /noir shows ${r_stacks:-0} GoldenLayout stack(s) — edit mode puts the Filesystem and the Editor in separate stacks, so fewer than two means the layout did not load"
		dump_arm route
	fi

	# The EDITOR PANE, named by the file it holds. `chooseInitialEditPath`
	# scores the project's filenames and `src/main.nr` must win it: `+20` for
	# a preferred extension, `+20` for being called `main`, `+10` for sitting
	# under `/src/`. A tab called anything else means the heuristic did not
	# run — which is exactly what a non-empty `startOptions.name` causes, and
	# what made `Nargo.toml` the first tab until it was fixed.
	r_tabs="$(json route dom.glTabTitles)"
	r_tabtext="$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["dom"].get("glTabTitles") or []))' "${cache}/route.json")"
	case "${r_tabtext}" in
	*"main.nr"*)
		ck ok "arm R: the editor pane is open on the template's entry file — ${r_tabs} tabs: ${r_tabtext}" ;;
	*)
		ck fail "arm R: no editor tab names main.nr (tabs: '${r_tabtext}') — edit mode opened the layout but not the project's entry file" ;;
	esac

	# ...AND THE SOURCE IS ON THE SCREEN. The pair with the check above is the
	# point: a tab title is drawn by GoldenLayout and would still be there over
	# an editor that never received its file. This reads Monaco's own painted
	# `.view-line`s, hit-tested, and looks for a line only this template has.
	#
	# It is also the answer to the one risk that was unmeasured when this work
	# started — whether Monaco can load in a statically hosted tab at all.
	r_lines="$(json route dom.editorLinesVisible)"
	r_linetext="$(python3 -c 'import json,sys; print(" ".join((json.load(open(sys.argv[1]))["dom"].get("editorLinesVisible") or [])))' "${cache}/route.json")"
	case "${r_linetext}" in
	*"fn main"*)
		ck ok "arm R: Monaco painted ${r_lines} lines of the template's own source, including its fn main" ;;
	*)
		ck fail "arm R: the editor shows ${r_lines} painted line(s) and none of them is the template's fn main — the pane mounted without its file (text: '${r_linetext:0:160}')" ;;
	esac

	# THE TOPBAR. §1a.2: "The topbar is almost unchanged... it already carries
	# the debugger controls, the omnibar, the tabs". Counted as PAINTED
	# descendants rather than as `#menu` existing, because `#menu` is in the
	# entry document's skeleton either way — an existence check would have been
	# green throughout the week this page rendered nothing.
	r_topbar="$(json route dom.topbarPainted)"
	if [ "${r_topbar:-0}" -ge 10 ] 2>/dev/null; then
		ck ok "arm R: the topbar is painted — ${r_topbar} visible elements, so the debugger controls and the omnibar are on screen"
	else
		ck fail "arm R: the topbar has ${r_topbar:-0} painted element(s) — the renderer did not draw the menu, so the first screen is a layout with no chrome"
		dump_arm route
	fi

	if [ "${r_errs}" = "0" ]; then
		ck ok "arm R: no uncaught page errors on the template route"
	else
		ck fail "arm R: ${r_errs} uncaught page error(s) on /noir:"
		python3 -c 'import json,sys; [print("      "+e) for e in json.load(open(sys.argv[1]))["pageErrors"]]' \
			"${cache}/route.json"
	fi
fi
echo

echo "Arm S: MUTATION — the renderer stops reading the URL"
echo "    The defect exactly: the entry layer exists, is correct, and is not"
echo "    consulted. Expect arm R's mount assertion RED, / unchanged."
if ! run_arm route-blind mutate_route_blind "/noir"; then
	ck fail "arm S could not be measured"
	ck fail "arm S could not be measured (second half)"
else
	s_welcome="$(json route-blind dom.welcomeScreenRoots)"
	s_fs="$(json route-blind dom.filesystemPanels)"
	s_renderer="$(json route-blind rendererLine)"
	if [ "${s_welcome}" = "1" ] && [ "${s_fs}" = "0" ]; then
		ck ok "arm S: /noir falls back to the welcome screen when the location is not read, so arm R's mount assertion can fail"
	else
		ck fail "arm S: /noir still mounted ${s_fs} filesystem panel(s) and ${s_welcome} welcome screen(s) with the URL read stubbed out — arm R's assertion cannot detect a blind router, so it proves nothing"
	fi
	# The twin. The mutation must break the ROUTE and not the renderer: a
	# product that stopped mounting anything would also satisfy the check
	# above's first half while being consistent with almost any bug.
	case "${s_renderer}" in
	*"codetracer-web-renderer: ok"*)
		ck ok "arm S: the renderer still mounted a surface, so this arm isolates the routing and not the mount" ;;
	*)
		ck fail "arm S: the renderer stopped mounting altogether (line: '${s_renderer}'); the arm does not isolate the route" ;;
	esac
fi
echo

echo "Arm V: MUTATION — the template surface is mounted and painted over"
echo "    The state a DOM-only check calls a pass. Expect the VISIBILITY"
echo "    assertion RED and the mount assertion GREEN."
if ! run_arm covered mutate_covered_surface "/noir"; then
	ck fail "arm V could not be measured"
	ck fail "arm V could not be measured (second half)"
else
	v_entries="$(json covered dom.filesystemEntries)"
	v_visible="$(json covered dom.entryLabelsVisible)"
	v_panels="$(json covered dom.filesystemPanels)"
	if [ "${v_visible}" = "0" ] && [ "${v_entries:-0}" -ge 5 ] 2>/dev/null; then
		ck ok "arm V: ${v_entries} rows are in the DOM and 0 are visible, so arm R's visibility assertion can fail"
	else
		ck fail "arm V: ${v_visible} of ${v_entries} rows still hit-test as visible under a covering element — arm R's visibility check cannot detect occlusion and proves nothing"
	fi
	# The twin: the mutation must change VISIBILITY and nothing else, or the
	# assertion it vouches for is not the one it reddened.
	if [ "${v_panels}" = "1" ]; then
		ck ok "arm V: the panel is still mounted, so this arm isolates painting from mounting" ;
	else
		ck fail "arm V: the panel stopped mounting (${v_panels}); the arm does not isolate occlusion"
	fi
fi
echo

# ---------------------------------------------------------------------------
echo "Arm O: THE SECOND DOMAIN — / on a language host is the Noir entry point"
echo "    Same tree, same bundle, different origin. noirstudio.dev is meant to"
echo "    mean what ide.codetracer.com/noir means, without a redirect and"
echo "    without the visitor leaving the domain they typed."
# ---------------------------------------------------------------------------
#
# THE VARIABLE IS THE ORIGIN AND NOTHING ELSE. The arm serves ONE directory and
# probes it twice: once through `http://noirstudio.test/` and once through
# `http://127.0.0.1:<port>/`. Identical bytes, identical path, two surfaces —
# which is the whole claim, and neither probe alone can make it. A check that
# only loaded the language host would pass for a build that had simply started
# mounting the template everywhere, which is the same class of defect as the
# one that shipped, inverted.
if ! run_arm language-host configure_language_host "/" "${language_host}"; then
	ck fail "arm O could not be measured"
	ck fail "arm O could not be measured (second half)"
	ck fail "arm O could not be measured (third half)"
	ck fail "arm O could not be measured (fourth half)"
else
	o_origin="$(json language-host dom.origin)"
	o_welcome="$(json language-host dom.welcomeScreenRoots)"
	o_fs="$(json language-host dom.filesystemPanels)"
	o_entries="$(json language-host dom.filesystemEntries)"
	o_visible="$(json language-host dom.entryLabelsVisible)"
	o_renderer="$(json language-host rendererLine)"

	# NON-VACUITY, and it is specific to this arm: a `--host-resolver-rules`
	# that silently failed to apply would leave the page on `127.0.0.1`, where
	# the welcome screen is CORRECT — so the arm would fail while saying
	# nothing true about the product. The origin is asserted before the surface.
	if [ "${o_origin}" = "http://${language_host}" ]; then
		ck ok "arm O: the page is on ${o_origin}, so this arm measured the second domain"
	else
		ck fail "arm O: the page reports origin '${o_origin}', not http://${language_host} — the host mapping did not apply and the surface check below would be about the wrong host"
	fi

	if [ "${o_welcome}" = "0" ] && [ "${o_fs}" = "1" ] && \
	   [ "${o_visible}" = "${o_entries}" ] && [ "${o_entries:-0}" -ge 5 ] 2>/dev/null; then
		ck ok "arm O: / on the language host opened the template — ${o_visible} visible rows, no welcome screen"
	else
		ck fail "arm O: / on the language host gave ${o_welcome} welcome screen(s), ${o_fs} panel(s), ${o_visible}/${o_entries} visible rows"
		dump_arm language-host
	fi

	case "${o_renderer}" in
	*"surface=edit-mode"*"host=noir"*)
		ck ok "arm O: the renderer named the host language it routed by: ${o_renderer#*: }" ;;
	*)
		ck fail "arm O: the renderer line does not report a noir host (line: '${o_renderer}')" ;;
	esac

	# THE TWIN, and the reason this arm is a claim about the ORIGIN. The same
	# directory, the same server, an undeclared host: `/` must be the
	# language-neutral root again. Rule 0 — a host that is not declared owns no
	# language, and the product must not have started defaulting to Noir.
	if ! probe_dir language-host-neutral "${arm_dir}" "/"; then
		ck fail "arm O: the undeclared-origin twin could not be measured"
	else
		n_welcome="$(json language-host-neutral dom.welcomeScreenRoots)"
		n_fs="$(json language-host-neutral dom.filesystemPanels)"
		if [ "${n_welcome}" = "1" ] && [ "${n_fs}" = "0" ]; then
			ck ok "arm O: the SAME bundle on an undeclared origin still opens the welcome screen, so the routing follows the host and not the build"
		else
			ck fail "arm O: the same bundle on an undeclared origin gave ${n_welcome} welcome screen(s) and ${n_fs} panel(s) — / has started meaning noir everywhere, which is rule 0's failure"
		fi
	fi

	# ------------------------------------------------------------------
	# EQUIVALENCE. `noirstudio.dev/` and `ide.codetracer.com/noir` are the
	# same screen reached two ways, and that is now asserted rather than
	# assumed.
	#
	# A user reported the two hosts showing different content. Measured, they
	# were identical — 42 elements, same rects, same paint status,
	# pixel-identical screenshots — and the real cause was a cached 308 in
	# their browser from the CDN defect (see `entryDocumentAddress`). But the
	# report was reasonable and the property was UNASSERTED: nothing stopped
	# the two paths diverging, and `hostLanguage` is a live input to the
	# render dispatch.
	#
	# `renderedTree` is every visible element's tag, id, class, integer rect
	# and paint status in document order. Two hosts agreeing on its digest
	# agree on layout, stacking and content. The origin is deliberately not in
	# it — that is the one thing that must differ.
	if ! probe_dir language-host-path "${arm_dir}" "/noir" "${language_host}"; then
		ck fail "arm O: the equivalence twin could not be measured"
	else
		d_root="$(tree_digest language-host)"
		d_path="$(tree_digest language-host-path)"
		if [ "${d_root}" = "EMPTY" ] || [ "${d_path}" = "EMPTY" ]; then
			ck fail "arm O: one of the two renderings produced no tree (root=${d_root} path=${d_path}) — the comparison below would be vacuous"
		elif [ "${d_root}" = "${d_path}" ]; then
			ck ok "arm O: / on the language host and /noir render an IDENTICAL tree (${d_root:0:16}), so the two ways in are one screen"
		else
			ck fail "arm O: / on the language host and /noir render DIFFERENT trees (${d_root:0:16} vs ${d_path:0:16}) — the same project reached two ways must look the same"
			python3 -c '
import json, sys
a = json.load(open(sys.argv[1]))["dom"]["renderedTree"]
b = json.load(open(sys.argv[2]))["dom"]["renderedTree"]
sa, sb = set(a), set(b)
for row in sorted(sa - sb)[:6]: print("      only on /:     " + row)
for row in sorted(sb - sa)[:6]: print("      only on /noir: " + row)
' "${cache}/language-host.json" "${cache}/language-host-path.json"
		fi
	fi
fi
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
# 37 assertions, written from a run. See traps doc 4c: the count is what turns
# "all green" into "all of them ran". 35 over the product, plus the two that
# vouch for the instrument doing the measuring.
#
# The sixteen added for the entry route are the ones this gate was missing: it
# loaded `/` and only `/`, so a renderer that never read the URL passed every
# assertion in it while `https://ide.codetracer.com/noir` opened the welcome
# screen. Two of the nine (arm D) are about the hosting contract rather than
# the DOM, because the same defect had a CDN half: a 200-rewrite whose target
# the host answered with a 308.
echo "Arm E: MUTATION — the in-page host answers tab-load synchronously"
echo "    The measured state of one build: layout, topbar and tree correct,"
echo "    editor pane absent. Expect arm R's EDITOR checks RED, the rest GREEN."
if ! run_arm sync-reply mutate_sync_host_reply "/noir"; then
	ck fail "arm E could not be measured"
	ck fail "arm E could not be measured (second half)"
else
	e_lines="$(python3 -c 'import json,sys; print(" ".join((json.load(open(sys.argv[1]))["dom"].get("editorLinesVisible") or [])))' "${cache}/sync-reply.json")"
	e_entries="$(json sync-reply dom.entryLabelsVisible)"
	e_topbar="$(json sync-reply dom.topbarPainted)"
	case "${e_lines}" in
	*"fn main"*)
		ck fail "arm E: the editor still paints the template's source with the host replying synchronously — arm R's source assertion cannot detect the early-resolve defect, so it proves nothing" ;;
	*)
		ck ok "arm E: the editor pane loses its source when the host replies synchronously, so arm R's source assertion can fail" ;;
	esac
	# The twin. A mutation that took the whole page down would satisfy the
	# check above while being consistent with almost any bug; what makes this
	# arm about the EDITOR is that everything else survives it.
	if [ "${e_entries:-0}" -ge 5 ] 2>/dev/null && [ "${e_topbar:-0}" -ge 10 ] 2>/dev/null; then
		ck ok "arm E: the tree (${e_entries} rows) and the topbar (${e_topbar} elements) are untouched, so this arm isolates the editor from the page"
	else
		ck fail "arm E: the mutation also took out the tree (${e_entries} rows) or the topbar (${e_topbar} elements) — it is not isolating the editor pane"
	fi
fi
echo

echo "Arm T: MUTATION — the topbar's container is stripped from the document"
echo "    The twin of arm B, one element over. Expect arm R's TOPBAR check"
echo "    RED and the layout, tree and editor checks GREEN."
if ! run_arm no-menu mutate_no_menu "/noir"; then
	ck fail "arm T could not be measured"
	ck fail "arm T could not be measured (second half)"
else
	t_topbar="$(json no-menu dom.topbarPainted)"
	t_lines="$(python3 -c 'import json,sys; print(" ".join((json.load(open(sys.argv[1]))["dom"].get("editorLinesVisible") or [])))' "${cache}/no-menu.json")"
	t_entries="$(json no-menu dom.entryLabelsVisible)"
	if [ "${t_topbar:-0}" -lt 10 ] 2>/dev/null; then
		ck ok "arm T: the topbar paints ${t_topbar:-0} element(s) without its container, so arm R's topbar assertion can fail"
	else
		ck fail "arm T: the topbar still paints ${t_topbar} element(s) with #menu removed — arm R's topbar assertion is not reading the topbar"
	fi
	case "${t_lines}" in
	*"fn main"*)
		if [ "${t_entries:-0}" -ge 5 ] 2>/dev/null; then
			ck ok "arm T: the editor still shows the template's source and the tree still has ${t_entries} rows, so this arm isolates the chrome from the panes"
		else
			ck fail "arm T: removing #menu also emptied the file tree (${t_entries} rows) — it is not isolating the chrome"
		fi ;;
	*)
		ck fail "arm T: removing #menu also took the editor's source off the screen — it is not isolating the chrome" ;;
	esac
fi
echo

expect_count 45
echo "${checks} check(s), ${failures} failure(s)"
if [ "${failures}" -eq 0 ]; then
	echo "RESULT: OK — the bundle mounts a product, and each check was shown to be able to fail"
	exit 0
fi
echo "RESULT: FAILED — ${failures} check(s)"
exit 1
