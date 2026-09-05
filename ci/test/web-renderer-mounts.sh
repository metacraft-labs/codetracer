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
#         CT_PROBE_SCREENSHOT_DIR  per arm, write what the browser SAW (one
#                             PNG) and what it REPORTED (the probe's JSON, and
#                             its stderr when it wrote any).
#
#                             BOTH, because a screenshot cannot distinguish a
#                             live control from a dead one — the check that a
#                             run button is disabled reads a class name and a
#                             title, and a picture of a ▶ is identical either
#                             way. An arm that failed on the DOM and shipped
#                             only pixels is undiagnosable by construction:
#                             the artefact preserves the one form of evidence
#                             that is blind to the defect and drops the form
#                             that is not.

# The arm mutators below are dispatched BY NAME: each is handed to `run_arm`,
# which invokes it. shellcheck cannot see through that indirection and reports
# every one of them as dead code.
# shellcheck disable=SC2329

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=ci/lib/nim-cache-root.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "${repo_root}/ci/lib/nim-cache-root.sh"
cd "${repo_root}" || exit 2

cache="$(ct_nim_cache_root "${repo_root}")/web-renderer-mounts"
mkdir -p "${cache}"

# The ACIR opcode count the template ships, READ FROM THE TEMPLATE.
#
# DERIVED BECAUSE A TYPED COPY GOES STALE ON SOMEONE ELSE'S WATCH. Three arms
# below assert on this number, and each was a separate literal `17` — a fourth,
# fifth and sixth copy of a constant that had already gone stale once. They
# were right only by luck of when they were written, which is the strongest
# argument for the assertion and the weakest for the literal.
#
# TWO MEASURED LINKS, NOT ONE REMEMBERED NUMBER:
# `ci/test/noir-template-toolchain.sh` checks this constant against the engine
# that ships, and these arms check that the PANE shows this constant. Neither
# link is a literal anyone has to remember.
acir_expected="$(python3 -c '
import re, sys
m = re.search(r"\"opcodes\"\s*:\s*(\d+)", open(sys.argv[1]).read())
if not m:
    sys.stderr.write("no \"opcodes\" count found in noir_template.nim\n")
    raise SystemExit(1)
print(m.group(1))
' src/frontend/viewmodel/platform/noir_template.nim)" || {
	echo "could not read the shipped ACIR opcode count from noir_template.nim" >&2
	exit 2
}

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
	# `probe_click_run` is a caller-set shell variable rather than an exported
	# env var, so exactly the arm that wants it gets it. The click MUTATES the
	# page — it clears the previous verdicts and moves the pane out of "not run
	# yet" — so an arm that measured the pane after one would be measuring a
	# different subject than every other arm.
	CT_PROBE_SCREENSHOT="${shot}" CT_PROBE_HOST_MAP="${host_map}" \
		CT_PROBE_CLICK_RUN="${probe_click_run:-}" \
		CT_PROBE_CLICK_GUTTER_RUN="${probe_click_gutter_run:-}" \
		node ci/test/web_renderer_probe.mjs "${url}" \
		>"${cache}/${label}.json" 2>"${cache}/${label}.err"
	local rc=$?
	stop_server
	# EXPORT BEFORE JUDGING, so an arm that failed exports the report that
	# says why. Placed ahead of the `rc` check on purpose: the runs whose
	# evidence is worth keeping are exactly the ones about to return non-zero.
	if [ -n "${CT_PROBE_SCREENSHOT_DIR:-}" ]; then
		[ -s "${cache}/${label}.json" ] &&
			cp "${cache}/${label}.json" "${CT_PROBE_SCREENSHOT_DIR}/${label}.json"
		[ -s "${cache}/${label}.err" ] &&
			cp "${cache}/${label}.err" "${CT_PROBE_SCREENSHOT_DIR}/${label}.stderr.txt"
	fi
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
jsonraw() {
	# The value at a dotted path, verbatim (a list stays a list). `json` above
	# reduces a list to its LENGTH, which is what most arms want and what the
	# NS9 pane checks must not have — "five rows" and "five rows naming the
	# project's own tests" are different assertions.
	python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    d = d.get(key) if isinstance(d, dict) else None
    if d is None:
        print("")
        sys.exit(0)
print(json.dumps(d))
' "${cache}/$1.json" "$2"
}
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
#
# BOOLEANS COME BACK AS `true`/`false`, NOT AS PYTHON'S `True`/`False`, and
# that spelling is the whole of this note. Until it was fixed this printed
# `repr` — so a caller had to compare against `"True"`, which every caller but
# one did. The one that did not was the newest check in the file:
#
#     r_rundisabled="$(json route dom.testRunButton.disabled)"
#     if [ "${r_rundisabled}" = "false" ]; then ...
#
# `False` never equals `false`, so that check reported the Noir template's run
# control DEAD on every run since it landed, and blocked the deploy. The
# button was live the whole time: the probe's own report in
# `pre-publish-mount-observations` said `"disabled": false` beside a title of
# "Run the tests (nargo test)", which is the ENABLED title — the two agreed,
# and only the reader disagreed with both.
#
# The lesson is not "spell it True". A gate that reports a defect the product
# does not have costs exactly what a missed defect costs, and it cost a day
# here plus a false report to the pane's owner. So the reader now speaks the
# JSON the probe wrote, and a caller writing the obvious `"false"` is right.
json() {
	python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    d = d.get(key) if isinstance(d, dict) else None
    if d is None:
        print("")
        sys.exit(0)
if isinstance(d, list):
    print(len(d))
elif d is True:
    print("true")
elif d is False:
    print("false")
else:
    print(d)
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

# Arm C — THE PLATFORM DOES NOT REACH THE RENDERER, which is the defect NS9
# removed and the one this arm now reconstructs.
#
# ## What this arm used to be, and why it had to change
#
# It used to unwrap the IIFEs around the two deployed Nim bundles so they
# shared a global scope again: `ui.js` then redefined 196 of `web.js`'s
# functions and 85 of its type tables, and the loop arm's async `boot()`
# resumed into a foreign runtime. That arm cannot be run any more, because
# there is no longer a second bundle to collide with — `ui_js.nim` boots and
# renders in one program. Left in place it would have been a check that cannot
# fail, which is worse than no check: `mutate_unscoped` would have died on a
# missing `web.js`, and the gate would have reported "arm C could not be
# measured" forever while looking like coverage.
#
# ## What it is now
#
# The same INVARIANT, mutated at its real seam. The invariant the merge buys is
# "the platform the renderer sees is the one `boot()` installed", and the
# single point where that is established is `installPlatform` — one function,
# which writes the module-level `var installedPlatform` in
# `viewmodel/platform/platform.nim` that `ctPlatform()` then reads.
#
# Neutering its BODY puts the product back in the exact pre-NS9 state: `boot()`
# still runs, still requests persistence, still opens the store, still reads
# the descriptor and still builds a `WebPlatform` — and the renderer's
# `ctPlatform()` still answers `uninstalledProfile`, because nothing wrote the
# var. That is precisely what two separately compiled bundles produced, now
# reproduced inside one.
#
# ## Why it is found by structure and not by name
#
# `nim js` mangles top-level procs as `<name>__<module path>_<n>` and emits
# string literals as char-code arrays, so grepping this bundle for a Nim
# identifier's SOURCE spelling finds nothing while the code is present. The
# emitted FUNCTION DECLARATION is structural and survives, so that is what is
# matched. The regex is anchored on the module path as well as the name, so it
# cannot drift onto `installFrontendPlatform` or a same-named proc elsewhere.
#
# The body is replaced by brace-matching rather than by a line substitution
# because the Nim backend's output is not line-oriented and a `sed` here would
# either miss or truncate the file.
mutate_no_platform_install() {
	local dir="$1"
	python3 - "${dir}/ui.js" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
# THE MODULE PATH IS NOT SPELLED, and that is a repair rather than a
# loosening. Nim's JS backend mangles a symbol's module path, and WHETHER it
# rot13s that path varies between compilers: the pinned toolchain emits
# `installPlatform__viewmodelZplatformZplatform_u99`, a `nim 2.2.4` from a
# user profile emits `installPlatform__ivrjzbqryZcyngsbezZcyngsbez_u99` for
# the identical source. This arm spelled the first, so on the second compiler
# it found nothing, exited 1, and reported "arm C could not be measured" —
# an INSTRUMENT failure reported in the same words a product failure would
# get. Verified against a renderer built at 5334f7aa, before the change this
# was noticed during: zero occurrences of the old needle, one of the new.
#
# Matching the leading `installPlatform__` and no more is safe rather than
# vague: there is exactly ONE such symbol in the bundle (the platform module
# has one `installPlatform`), so the superset has one member, and the
# `sys.exit(1)` below still refuses to let the arm pass over a bundle it
# could not cut.
# `[A-Za-z0-9_]+`, with the underscore. The mangled tail carries one
# (`..._u99`); the old pattern got away with `[A-Za-z0-9]+` only because the
# literal module path it spelled ended at the underscore before it.
m = re.search(r'function (installPlatform__[A-Za-z0-9_]+)\(([^)]*)\)\s*\{', s)
if not m:
    sys.exit(1)                      # the needle is gone; the arm must not
                                     # silently pass over a bundle it cannot cut
depth, i = 1, m.end()
while i < len(s) and depth:
    if s[i] == '{': depth += 1
    elif s[i] == '}': depth -= 1
    i += 1
if depth:
    sys.exit(1)
# The signature is preserved and the body emptied, so every CALLER still runs
# and only the effect is gone. Removing the function outright would raise a
# ReferenceError inside boot() and take the whole boot down, which would redden
# the arm for the wrong reason.
open(p, 'w').write(s[:m.end()] + '\n' + s[i - 1:])
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
# `String(window.location.pathname || '/')` is
# `host/web_browser.jsLocationPath`'s importjs body, emitted verbatim by the
# Nim JS backend. Note that grepping for a Nim STRING LITERAL here would find
# nothing — the backend emits those as char-code arrays — but an `importjs`
# pattern is emitted as source, which is why this mutation can be a text
# substitution at all.
#
# THE `count == 1` ASSERTION BELOW IS LOAD-BEARING, and it earned that in this
# milestone. It used to be `ui/web_entry_surface.nim`'s own `jsEntryPath` that
# matched — a byte-identical copy of the host module's, which existed because
# `web.js` and `ui.js` were separately compiled programs with no way to share
# a value. Merging them into one bundle put both copies in one file, this
# assertion tripped, and the duplication was removed rather than the assertion
# relaxed. `web_entry_surface.currentRendererEntryRequest` now calls
# `web_browser.currentEntryRequest`, so there is one reader of the location in
# the program and this arm blinds all of it.
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

# Arm F — THE COMPILED-IN CONFIG FIXTURE STOPS PARSING.
#
# `config.defaultRendererConfig` `staticRead`s `src/config/default_config.yaml`
# and runs it through a parser written for that file's shape. Both have the
# same silent failure: a `Config` with an empty `shortcutMap` is NON-NIL, so it
# dereferences cleanly in `ui/menu.nim`, `ui/shortcuts.nim` and
# `ui/editor.nim`, and the product mounts, paints, and answers no key. Every
# other assertion in this gate stays green over it — which is exactly why the
# count travels on the renderer line.
#
# The mutation renames the fixture's `bindings:` section header, so the parser
# files every chord under a section `defaultRendererConfig` ignores. Nothing
# else changes: the theme, the flow settings and the layout all still parse, so
# an arm that reddened the mount would be reddening something other than the
# keyboard.
#
# The needle is the fixture's own text. `staticRead` puts it in `ui.js` as a
# JS string literal with `\x0A` escapes, which is why it can be substituted at
# all — and it is one line of the file rather than a Nim identifier, so it
# cannot collide with the enum member of the same name the backend also emits.
mutate_unparsed_bindings() {
	local dir="$1"
	local needle='\x0Abindings:\x0A'
	grep -qF "${needle}" "${dir}/ui.js" || return 1
	python3 - "${dir}/ui.js" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read()
needle = '\\x0Abindings:\\x0A'
assert s.count(needle) == 1, s.count(needle)
open(p, 'w').write(s.replace(needle, '\\x0Abindingz:\\x0A'))
PY2
}

# Arm N — THE CONSTRAINT COUNTS THE BUNDLE SHIPS ARE WRONG.
#
# The web build cannot run `nargo` — there is no subprocess in a tab, and the
# wasm module has no `info` export — so the counts travel with the sources they
# describe (`platform/noir_template.noirTemplateNargoInfoJson`). That is a
# packaging choice, not an impossibility: the ACIR total CAN be computed in the
# browser over the existing ABI, and `ci/test/noir-template-acir-count.mjs`
# does exactly that. See that constant's docstring before concluding the number
# is expensive to produce.
#
# `ci/test/noir-template-toolchain.sh` is what checks it, in the web-deploy
# lane only (`deploy-web-codetracer.yml`) — NOT on every CI run — and it
# compares the ACIR total alone.
#
# THIS arm is the other half of that: it perturbs the shipped constant and
# requires the PANE to disagree. Without it, arm R's opcode-count check
# could be satisfied by a pane that renders the number literally — which is
# the placeholder this campaign was told not to build. The number must come
# from the constant, through `common/noir_constraints.parseNargoInfoJson`, to
# the DOM.
#
# Everything else must stay green: the tests still list, the four panes are
# still there, the proportions are unchanged. A mutation that moved any of
# those would not be isolating the counts.
mutate_wrong_constraint_counts() {
	local dir="$1"
	local needle='\"name\":\"main\",\"opcodes\":17'
	grep -qF "${needle}" "${dir}/ui.js" || return 1
	python3 - "${dir}/ui.js" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read()
needle = '\\"name\\":\\"main\\",\\"opcodes\\":17'
assert needle in s, 'needle absent'
open(p, 'w').write(s.replace(needle, needle.replace(':17', ':99')))
PY2
}

# Arm W — THE LAYOUT NO LONGER LEAVES THE EDITOR ANY ROOM.
#
# `openNewLayoutContainer` gives the editor's container the percentage the
# top-level row does not account for, because GoldenLayout's own `addChild`
# assigns `(1 / n) * 100` and scales the siblings to fit
# (`golden-layout/dist/esm/ts/items/row-or-column.js:103-117`) — measured as
# 29.3 / 33.0 / 36.6 where the layout declares 20 / 55 / 25.
#
# Over-subscribing the row (20 + 55 + 75 = 150) makes `unclaimedTopLevelPercent`
# answer `0`, which is its "the layout has no opinion" value, and the editor is
# created with no size again. So this arm restores GoldenLayout's default
# behaviour EXACTLY, which is the state arm R's proportion check exists to
# detect — and it leaves every pane, every row and every count untouched, which
# is what makes it a check on the geometry alone.
mutate_oversubscribed_layout() {
	local dir="$1"
	grep -q '25%' "${dir}/ui.js" || return 1
	python3 - "${dir}/ui.js" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read()
# Both `ui/layout.nim` and `ui/web_entry_surface.nim` `staticRead` the same
# `default_layout.json`, so the string appears twice in one bundle and both
# copies must move together — the surface reads one and the fallback the other.
needle = '\\"size\\": \\"25%\\"'
assert s.count(needle) >= 1, s.count(needle)
open(p, 'w').write(s.replace(needle, '\\"size\\": \\"75%\\"'))
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
# Arm P — THE DEPLOYMENT DELIVERS NO WASM WORKER SCRIPT.
#
# The negative control for the four checks that PRESS the run control. Without
# it those four are the same unearned claim the check they replaced was making:
# "the button worked" is only a measurement if there is a state in which this
# harness would say it did not.
#
# THE FIRST VERSION OF THIS ARM DELETED `assets/noir_wasm*.wasm` AND FAILED,
# which is what a negative control is for. Removing the compiler module does
# NOT stop the dispatch: the worker is started optimistically and only then
# discovers it has nothing to load, so `nbpTest-started` was reported and arm
# R's run-start assertion would not have gone red. (It also showed the pane
# still stating no reason a run cannot start with the module absent — a
# separate observation about `noirTestRunAbsence`, and not what this arm is
# for.) The worker SCRIPT is a step earlier in the same path: with it missing
# `wasm_registry` cannot start anything, so the dispatch is refused, which is
# the state that reddens the checks.
#
# It splits the four checks apart, which a cruder mutation would not: the
# control stays painted and stays CLICKABLE here, so arm R's press check holds
# while its run-start, verdict and pane-moved checks go red. That is the seam
# that matters — the defect being guarded against is a control that takes a
# click and runs nothing.
mutate_no_wasm_worker() {
	local dir="$1"
	local before after
	before="$(find "${dir}/assets" -maxdepth 1 -name 'wasm-worker*.js' 2>/dev/null | wc -l | tr -d ' ')"
	# A mutation that found nothing to mutate must not report success: the arm
	# would then measure an UNMUTATED bundle and call its verdict evidence.
	[ "${before}" -gt 0 ] || return 1
	find "${dir}/assets" -maxdepth 1 -name 'wasm-worker*.js' -delete
	after="$(find "${dir}/assets" -maxdepth 1 -name 'wasm-worker*.js' 2>/dev/null | wc -l | tr -d ' ')"
	[ "${after}" = "0" ]
}

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
# shellcheck disable=SC2016 # prose about `innerText`, not an expansion
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
c_title="$(json control dom.title)"

# NON-VACUITY FIRST. Everything after this reads `#dom-root`; if the probe
# never found it, the rest are assertions about nothing.
if [ "${c_present}" = "true" ]; then
	ck ok "the probe reached a document that has #dom-root, so the checks below have a subject"
else
	ck fail "the probe found no #dom-root — every DOM check below would be vacuous"
fi

# WHAT A BOOKMARK OF THIS PAGE WOULD BE CALLED.
#
# The gate had no assertion about the product's own name, and the entry
# document shipped one literal `<title>` — `CodeTracer &mdash; Noir Studio` —
# for every address the deployment serves. So the language-neutral root called
# itself Noir Studio, `/noir` called itself CodeTracer, and every bookmark
# taken anywhere carried both names at once. Nothing here could see it: a
# title is not markup inside `#dom-root` and no check read it.
#
# It is asserted on the RENDERED title rather than on the served document,
# because the served document cannot be right — one file answers three
# addresses. `ui_js.startWebRenderer` resolves the entry and sets
# `document.title` from `web_entry.productNameFor`, and this is that value.
# Arm R makes the same assertion for `/noir` and arm O for the language host;
# the three together are the whole claim, and arm S — which stubs the location
# read to a constant `/` — is what shows arm R's able to fail.
if [ "${c_title}" = "CodeTracer" ]; then
	ck ok "the language-neutral root calls itself CodeTracer, so a bookmark of it is filed under the right product"
else
	ck fail "the language-neutral root's title is '${c_title}', not 'CodeTracer'"
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
	ck fail "a status line is PAINTED on a page that mounted: '$(painted_shown control)' — the diagnostics must leave the document once the product is on it, or the text assertion above is measuring them"
	;;
*)
	ck ok "no status line is painted once the product mounted, so the text count above is the product's own"
	;;
esac

# NO UNCAUGHT ERRORS. The defect was an exception nothing was listening for.
if [ "${c_errs}" = "0" ]; then
	ck ok "no uncaught page errors"
else
	ck fail "${c_errs} uncaught page error(s):"
	python3 -c 'import json,sys; [print("      "+e) for e in json.load(open(sys.argv[1]))["pageErrors"]]' \
		"${cache}/control.json"
fi

# BOTH LINES REPORTED. They come from ONE program now — `ui_js.nim`'s web arm
# boots and then renders — where they used to come from two bundles that could
# not see each other. That is why the third and fourth checks below can exist.
case "${c_renderer}" in
*"codetracer-web-renderer: ok"*)
	ck ok "the renderer arm reported a mount: ${c_renderer#*: }"
	;;
*)
	ck fail "the renderer arm did not report a mount (line: '${c_renderer}')"
	;;
esac
case "${c_boot}" in
*"codetracer-web-boot: ok"*)
	ck ok "the boot sequence completed in the renderer's own program"
	;;
*)
	ck fail "the boot sequence did not complete (line: '${c_boot}')"
	;;
esac

# ---------------------------------------------------------------------------
# THE REACH — NS9, and the assertion this whole gate previously could not make.
#
# `ci/test/web-bundle-assets.sh` used to say, in its own header: "the two arms
# still cannot share Nim state, so the renderer cannot see the platform,
# project store or wasm registry that `web.js` booted." Everything above this
# block was true while that was also true — the page mounted, painted, routed
# and answered keys, and a Build button would still have found
# `uninstalledProfile`, because `installPlatform` writes a module-level `var`
# and `nim js` gives each compiled program its own.
#
# The renderer line now carries `platform=` and `run=`, and BOTH ARE READ FROM
# `ctPlatform()` BY THE CODE THAT MOUNTS PANES — `web_boot.describeRunningPlatform`
# is compiled into the renderer's program and called from `startWebRenderer`.
# So `platform=pkWeb` here is the renderer answering about itself, not the boot
# arm answering about the boot arm.
#
# Matched on `platform=pkWeb` as a substring of a console line, which is a
# structural match on emitted output and not on a Nim identifier — `nim js`
# emits string literals as char-code arrays, so grepping the BUNDLE for this
# text would find nothing while the code is present. The console line is the
# runtime value, and that is what is read here.
case "${c_renderer}" in
*"platform=pkWeb"*)
	ck ok "the renderer's own ctPlatform() is the booted web platform"
	;;
*)
	ck fail "the renderer's ctPlatform() is not the web platform (line: '${c_renderer}') — this is the NS9 defect: a mounted, painting product whose platform is uninstalledProfile"
	;;
esac

# AND IT AGREES WITH THE BOOT LINE, which is the check that makes the one above
# more than a spelling. `run=` is the WASM REGISTRY read through the renderer's
# platform: `web_platform.newWebPlatform` subtracts `capProcessSpawn` when
# `bridge.wasm.registry.modules.len == 0` ("the profile follows the registry").
# `toolchain=` on the boot line is the other half — what the DEPLOYMENT
# delivered, measured from the bytes on disk by the assembly step.
#
# The two disagreeing is precisely the state that shipped: a descriptor naming
# two Noir modules beside a renderer holding `uninstalledProfile`, so
# `toolchain=nargo:compile+trace` and `run=false` on the same page. Asserting
# AGREEMENT rather than `run=true` is deliberate — most builds of this gate
# ship no wasm modules (`CT_NOIR_WASM_COMPILER` unset), and a check demanding
# `run=true` would either fail on every such run or be quietly skipped, which
# is how a check stops being one. This form runs on EVERY build and is exactly
# as strong in both directions.
c_toolchain="none"
case "${c_boot}" in
*"toolchain=(none)"*) c_toolchain="none" ;;
*"toolchain="*) c_toolchain="some" ;;
esac
c_run="unknown"
case "${c_renderer}" in
*"run=true"*) c_run="some" ;;
*"run=false"*) c_run="none" ;;
esac
if [ "${c_run}" = "unknown" ]; then
	ck fail "the renderer line carries no run= clause (line: '${c_renderer}'); the deployment/registry agreement cannot be measured"
elif [ "${c_toolchain}" = "${c_run}" ]; then
	ck ok "what the deployment delivered and what the renderer can run agree (toolchain=${c_toolchain}, run=${c_run})"
else
	ck fail "the deployment delivered toolchain=${c_toolchain} but the renderer reports run=${c_run} — the compiler is on the origin and unreachable from the code that would call it"
fi
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
# THE ONLY ARM THAT PRESSES ANYTHING. See `probe_dir`: the click is last in the
# probe, after every measurement and after the screenshot, so the facts the
# checks below read are the untouched pane; `runClick` alone describes what
# happened afterwards.
probe_click_run=1
if ! run_arm route "" "/noir"; then
	probe_click_run=""
	ck fail "arm R could not be measured"
	ck fail "arm R could not be measured (second half)"
	ck fail "arm R could not be measured (third half)"
	ck fail "arm R could not be measured (fourth half)"
	ck fail "arm R could not be measured (fifth half)"
	ck fail "arm R could not be measured (sixth half)"
	ck fail "arm R could not be measured (status bar present)"
	ck fail "arm R could not be measured (status bar unobscured)"
	ck fail "arm R could not be measured (the run control was never pressed)"
	ck fail "arm R could not be measured (the gutter's four bands)"
	ck fail "arm R could not be measured (the VCS band's height)"
	ck fail "arm R could not be measured (the gutter bands' disjointness)"
	ck fail "arm R could not be measured (TESTS is a reachable tab of the FILES panel)"
else
	# Reset in BOTH branches: every arm after this one measures a pane nobody
	# touched, and a leaked `1` would silently start running tests in them.
	probe_click_run=""
	r_present="$(json route dom.domRootPresent)"
	r_welcome="$(json route dom.welcomeScreenRoots)"
	r_fs="$(json route dom.filesystemPanels)"
	r_entries="$(json route dom.filesystemEntries)"
	r_errs="$(json route pageErrors)"
	r_renderer="$(json route rendererLine)"
	r_title="$(json route dom.title)"
	r_labels="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(" ".join(d.get("dom", {}).get("entryLabels") or []))
' "${cache}/route.json" 2>/dev/null)"

	# NON-VACUITY, same rule as the control arm: `welcomeScreenRoots == 0` over
	# a page the probe never reached is indistinguishable from a correct route.
	if [ "${r_present}" = "true" ]; then
		ck ok "arm R: /noir served the application document, so the checks below have a subject"
	else
		ck fail "arm R: /noir produced no #dom-root — the rewrite did not reach the SPA and every check below would be vacuous"
		dump_arm route
	fi

	# AND IT CALLS ITSELF THE RIGHT PRODUCT. `/noir` is Noir Studio, so the
	# title a bookmark keeps must be Noir Studio and not the name of the
	# desktop product it shares a renderer with. This is the address half of
	# the control arm's check; arm O below is the host half.
	#
	# Arm S is its mutation twin at no extra cost: it stubs the location read
	# to a constant `/`, which makes `productNameFor` answer the neutral name
	# here, so this check reddens on exactly the build that made the route
	# defect ship.
	if [ "${r_title}" = "Noir Studio" ]; then
		ck ok "arm R: /noir calls itself Noir Studio, so a bookmark of it is not filed under CodeTracer"
	else
		ck fail "arm R: /noir's title is '${r_title}', not 'Noir Studio'"
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
			ck ok "arm R: the tree is the Noir template — ${r_entries} entries: ${r_labels}"
			;;
		*)
			ck fail "arm R: the tree has no Nargo.toml; a Noir project without one is not one (labels: ${r_labels})"
			;;
		esac
		;;
	*)
		ck fail "arm R: the tree has no main.nr (labels: '${r_labels}') — a filesystem panel mounted, but not over the template"
		;;
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
		ck ok "arm R: the renderer reported the route it took: ${r_renderer#*: }"
		;;
	*)
		ck fail "arm R: the renderer line does not report edit mode on the noir route (line: '${r_renderer}')"
		;;
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

	# -----------------------------------------------------------------------
	# NOTHING COVERS THE STATUS BAR — a STANDING guard, and the only check in
	# this suite that watches the bottom of the screen.
	#
	# It is here because a surface took that space and nobody noticed until a
	# user did: the storage-durability notice was painted into a bespoke
	# `<div id="codetracer-durability">` at `position:fixed; bottom:0;
	# z-index:2147483646`, sitting on `#status` on every first visit. That
	# instance is fixed — the sentence goes through `ui/status.nim`'s
	# notification stack, which is anchored at `bottom:38px` and stacks ABOVE
	# the bar — but nothing in the suite would have caught it, and nothing
	# would catch the next one.
	#
	# `status-bar/footer-visibility-css-guard.spec.ts` says so itself, in its
	# "WHERE IT STOPS" section: asking for a box catches every regression that
	# changes LAYOUT and none that changes only PAINTING, an occluded footer
	# keeps a full-size box, `readyOnEntryTest` passes over it, and "that
	# family is currently unguarded by anything in the suite". This is the
	# guard for that family, on the web arm, where a browser is already open.
	#
	# ARM V VOUCHES FOR IT. The overlay that arm already installs is
	# full-viewport, so it covers this too; if this check could not go red
	# there it would be measuring nothing.
	# -----------------------------------------------------------------------
	r_bar_found="$(json route dom.statusBar.found)"
	r_bar_clear="$(json route dom.statusBar.unobscured)"
	r_bar_points="$(json route dom.statusBar.points)"
	r_bar_by="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(", ".join((d.get("dom", {}).get("statusBar") or {}).get("coveredBy") or []) or "(nothing)")
' "${cache}/route.json" 2>/dev/null)"
	# NON-VACUITY FIRST. `unobscured` over a page with no status bar would be
	# an absence reported as a pass, which is this gate's founding defect.
	if [ "${r_bar_found}" = "true" ] && [ "${r_bar_points}" = "3" ]; then
		ck ok "arm R: the status bar is in the document and all three probe points across it are testable"
	else
		ck fail "arm R: no testable status bar (found=${r_bar_found}, points=${r_bar_points}) — the occlusion check below would be vacuous"
		dump_arm route
	fi
	if [ "${r_bar_clear}" = "true" ]; then
		ck ok "arm R: nothing is painted over the status bar"
	else
		ck fail "arm R: the status bar is covered by ${r_bar_by} — a surface has taken the bottom of the screen, which is the defect the durability banner shipped"
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
		ck fail "arm R: a status line is painted on /noir ('${r_shown}') — the route's readable text is a diagnostic, not the project"
		;;
	*"main.nr"*)
		ck ok "arm R: the ${r_painted} characters a user can read on /noir are the project's own files: ${r_shown}"
		;;
	*)
		ck fail "arm R: the painted text on /noir is '${r_shown}' (${r_painted} chars) — the project's file names are not what a user reads"
		;;
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
		ck ok "arm R: the editor pane is open on the template's entry file — ${r_tabs} tabs: ${r_tabtext}"
		;;
	*)
		ck fail "arm R: no editor tab names main.nr (tabs: '${r_tabtext}') — edit mode opened the layout but not the project's entry file"
		;;
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
		ck ok "arm R: Monaco painted ${r_lines} lines of the template's own source, including its fn main"
		;;
	*)
		ck fail "arm R: the editor shows ${r_lines} painted line(s) and none of them is the template's fn main — the pane mounted without its file (text: '${r_linetext:0:160}')"
		;;
	esac

	# THE TOPBAR. §1a.2: "The topbar is almost unchanged... it already carries
	# the debugger controls, the omnibar, the tabs". Counted as PAINTED
	# descendants rather than as `#menu` existing, because `#menu` is in the
	# entry document's skeleton either way — an existence check would have been
	# green throughout the week this page rendered nothing.
	# THE KEYBOARD, which no DOM assertion above can see. A `Config` whose
	# `bindings:` section did not parse is non-nil and empty, and produces a
	# product that mounts, paints and answers no key. `default_config.yaml`
	# binds ~60 chords; the floor is set well below that so a binding added or
	# removed does not fail this, while a fixture that stopped parsing does.
	r_shortcuts="$(printf '%s' "${r_renderer}" | sed -n 's/.*shortcuts=\([0-9-]*\).*/\1/p')"
	if [ "${r_shortcuts:-0}" -ge 40 ] 2>/dev/null; then
		ck ok "arm R: the compiled-in config bound ${r_shortcuts} key chords, so the shortcut map edit mode was given is populated"
	else
		ck fail "arm R: the renderer reports ${r_shortcuts:-none} bound key chords — the bundled default_config.yaml did not parse, and the product has a keyboard that answers nothing"
	fi

	r_topbar="$(json route dom.topbarPainted)"
	if [ "${r_topbar:-0}" -ge 10 ] 2>/dev/null; then
		ck ok "arm R: the topbar is painted — ${r_topbar} visible elements, so the debugger controls and the omnibar are on screen"
	else
		ck fail "arm R: the topbar has ${r_topbar:-0} painted element(s) — the renderer did not draw the menu, so the first screen is a layout with no chrome"
		dump_arm route
	fi

	# -----------------------------------------------------------------------
	# NS9's OTHER TWO PANES. §1a: "Filesystem, Editor, Tests, Constraints —
	# not a landing page". The first two were asserted above; these two did not
	# exist on any platform until this campaign, and the whole point of building
	# them as `Content` members is that a desktop user running Noir tests gets
	# them too. What a browser can check is that they are here, that their data
	# is the producer's own, and that the four sit where the picture puts them.
	#
	# THE CAPTION IS `TESTS`, NOT "TEST RESULTS". The pane moved into the FILES
	# stack, where the strip is shared three ways and two words would be
	# truncated, and `ui/layout.convertTabTitle` gives it the shorter caption
	# the same way it gives `Filesystem` the caption `FILES`. Matched as a whole
	# word. `r_tabtext` is the titles joined by a SPACE, so the subject is
	# padded and the pattern carries its own spaces — otherwise a future tab
	# whose caption merely CONTAINS the letters would satisfy this, which is
	# how a pane-presence check quietly stops being one.
	# -----------------------------------------------------------------------
	case " ${r_tabtext} " in
	*" TESTS "*)
		case "${r_tabtext}" in
		*"CONSTRAINTS"*)
			ck ok "arm R: all four of §1a's panes are on the first screen — ${r_tabtext}"
			;;
		*)
			ck fail "arm R: no CONSTRAINTS pane in the layout (tabs: '${r_tabtext}')"
			;;
		esac
		;;
	*)
		ck fail "arm R: no TESTS pane in the layout (tabs: '${r_tabtext}')"
		;;
	esac

	# THE TESTS ARE THE PROJECT'S OWN, named by the runner's selectors. The
	# parser that produced them is the one `ct test`'s Noir provider uses, and
	# `ci/test/noir-template-toolchain.sh` compares its selectors against a
	# real `nargo test` run — so this check is about DELIVERY to the pane,
	# and that one is about correctness of the names.
	r_testnames="$(python3 -c '
import json, sys
rows = json.load(open(sys.argv[1]))["dom"].get("testRows") or []
print(" ".join(r["name"] for r in rows))
' "${cache}/route.json")"
	r_testcount="$(json route dom.testRows)"
	if [ "${r_testcount:-0}" -eq 5 ] 2>/dev/null; then
		ck ok "arm R: Test Results lists the template's 5 tests: ${r_testnames}"
	else
		ck fail "arm R: Test Results lists ${r_testcount:-0} test(s), and the bundled template has 5 (names: '${r_testnames}')"
	fi
	case "${r_testnames}" in
	*"test_main"*"test_in_range_accepts_small_values"*)
		ck ok "arm R: the rows are the project's own tests, from src/main.nr through src/utils.nr"
		;;
	*)
		ck fail "arm R: the rows do not name the template's tests ('${r_testnames}') — the pane mounted over something else"
		;;
	esac

	# ...AND THE PANE OFFERS TO RUN THEM.
	#
	# THIS CHECK WAS THE OTHER WAY ROUND and its inversion is the point. It
	# used to require the absence line to be LONGER THAN 80 CHARACTERS, because
	# on the web "these cannot be run here" was the permanent and correct
	# answer: no `nargo` in a tab, and a wasm worker dispatching only `compile`
	# and `trace`. Both clauses are now false — `noir_wasm.wasm` exports
	# `nv_test_vfs` and the worker routes `test` to it — so a pane still
	# carrying that paragraph would be asserting an absence that has been
	# filled, which teaches a visitor the product is less capable than it is.
	#
	# So the absence must be EMPTY, and the ▶ must be present AND enabled. Both
	# halves are needed: a painted-but-disabled button and a working one look
	# identical in a screenshot, and the disabled one is the dead affordance the
	# paragraph existed to avoid.
	r_absence="$(json route dom.testAbsenceLength)"
	r_testhead="$(jsonraw route dom.testHeadline)"
	r_runbtn="$(jsonraw route dom.testRunButton.text)"
	r_rundisabled="$(json route dom.testRunButton.disabled)"
	if [ "${r_absence:-1}" = "0" ]; then
		ck ok "arm R: Test Results states no reason a run cannot start, because there is none; headline ${r_testhead}"
	else
		ck fail "arm R: Test Results still carries a ${r_absence}-character absence line — prose asserting an absence that has been filled"
		jsonraw route dom.testAbsence 2>/dev/null | head -3 | sed 's/^/      /'
	fi
	if [ "${r_runbtn}" != "null" ] && [ -n "${r_runbtn}" ]; then
		ck ok "arm R: Test Results paints a run control (${r_runbtn})"
	else
		ck fail "arm R: Test Results paints no run control — five rows and no way to run them"
	fi
	# AND THE ASSERTION IS THE PRESS, NOT THE CLASS.
	#
	# This check used to read `dom.testRunButton.disabled`, which is
	# `className.includes('disabled')` — and that is precisely the fact that
	# cannot distinguish the two cases it was written to distinguish. A control
	# that is painted, not styled dead, correctly titled and WIRED TO NOTHING
	# scores identically to a working one. It is the screenshot's own blindness
	# one abstraction up, inside the check meant to cure it.
	#
	# It also spent its whole life red for a reason that had nothing to do with
	# the product: `json` returned Python's `False` and this line compared it to
	# `"false"`. The button was live throughout; only the reader disagreed. See
	# `json`'s header. A gate that reports a defect the product does not have
	# costs what a missed defect costs.
	#
	# So the class is still read — it is reported below as context — and the
	# verdict now comes from pressing the thing and watching for the run.
	r_clicked="$(json route runClick.clicked)"
	r_clickerr="$(json route runClick.clickError)"
	r_started="$(json route runClick.startedLine)"
	r_refused="$(json route runClick.refusedLine)"
	r_headbefore="$(json route runClick.headlineBefore)"
	r_headafter="$(json route runClick.headlineAfter)"
	r_results="$(json route runClick.resultsLine)"
	if [ "${r_clicked}" = "true" ]; then
		ck ok "arm R: the run control took a real pointer click at its own hit point (class was '${r_rundisabled}'=disabled)"
	else
		ck fail "arm R: the run control could not be clicked — '${r_clickerr}'. Painted, and out of a user's reach"
	fi
	if [ -n "${r_started}" ]; then
		ck ok "arm R: THE CLICK STARTED A RUN — ${r_started}"
	else
		ck fail "arm R: the click started nothing. Refusal line: '${r_refused:-none}'; headline went '${r_headbefore}' -> '${r_headafter}'. A control that looks live and runs nothing is the dead affordance in its worst form, because the pane also states no reason"
		jsonraw route runClick.newConsole 2>/dev/null | head -3 | sed 's/^/      /'
	fi
	# ...AND THE RUN REACHED ITS VERDICTS. `nbpTest-started` proves the worker
	# accepted the dispatch; only this proves `nv_test_vfs` ran the suite and
	# the pane was told. The template ships 5 tests and one of them is a
	# `should_fail`, so `tests=5` is also the count assertion — a run that
	# discovered nothing and said ok would otherwise read as a pass.
	case "${r_results}" in
	*"ok=true"*"tests=5"*)
		ck ok "arm R: and the run reached its verdicts — ${r_results}"
		;;
	*)
		ck fail "arm R: the run started but no 5-test verdict reached the pane — '${r_results:-none}'"
		;;
	esac
	# The pane a user is left looking at is not the one they started from. This
	# is the same event seen from the DOM rather than the console, and it is
	# what makes the two above a product claim rather than a logging claim.
	if [ -n "${r_headafter}" ] && [ "${r_headafter}" != "${r_headbefore}" ]; then
		ck ok "arm R: and the pane moved with it — headline '${r_headbefore}' -> '${r_headafter}'"
	else
		ck fail "arm R: the pane still reads '${r_headafter}' after the run — the user is shown nothing happened"
	fi

	# AND THE EDITOR'S GUTTER CARRIES ONE PER TEST.
	#
	# THE LINES, NOT THE COUNT. `src/main.nr` declares two tests — line 13
	# `#[test]` and line 18 `#[test(should_fail)]` — and the second is exactly
	# what the text scan this replaced could not see: it matched
	# `lineStr.strip() == "#[test]"` exactly, so the attribute forms got no
	# control at all. `13` alone would be the defect; `13 18` is the fix, and a
	# bare count of 2 would not tell them apart from any other pair.
	r_runslots="$(python3 -c '
import json, sys
print(" ".join(json.load(open(sys.argv[1]))["dom"].get("gutterRunSlots") or []))
' "${cache}/route.json")"
	if [ "${r_runslots}" = "13 18" ]; then
		ck ok "arm R: the gutter carries a run control on both of main.nr's tests, including the \`#[test(should_fail)]\` a text scan cannot see (lines ${r_runslots})"
	else
		ck fail "arm R: the gutter's run controls are on lines '${r_runslots}', expected '13 18'"
	fi

	# AND IT DOES NOT SIT ON THE BREAKPOINT. Two controls answering one point is
	# the failure the marker lanes were separated to prevent; a third control
	# overlapping either of them would reintroduce it, and a click meant to run
	# a test would set a breakpoint instead. Asserted as GEOMETRY, because class
	# names being different says nothing about where the boxes are.
	r_overlap="$(python3 -c '
import json, sys
boxes = json.load(open(sys.argv[1]))["dom"].get("gutterRunSlotBoxes") or []
bad = [b for b in boxes if b.get("overlapsMarker")]
zero = [b for b in boxes if not b.get("width")]
print(len(boxes), len(bad), len(zero))
' "${cache}/route.json")"
	# shellcheck disable=SC2086 # deliberate word splitting of the overlap list
	set -- ${r_overlap}
	if [ "${1:-0}" -gt 0 ] && [ "${2:-1}" -eq 0 ] && [ "${3:-1}" -eq 0 ]; then
		ck ok "arm R: each run control has a hit area of its own (${1} measured, none overlapping the breakpoint, none zero-width)"
	else
		ck fail "arm R: ${1:-0} run control(s) measured, ${2:-?} overlapping the breakpoint marker and ${3:-?} with no width — a control a click cannot reach, or one that steals the breakpoint's"
	fi

	# AND THE STRIP HOLDS ALL FOUR CONCERNS AT ONCE.
	#
	# The gutter carries breakpoints/tracepoints, VCS change indicators, line
	# numbers and the run-test control, and the fourth of those had nowhere to
	# be. `.diff-line` — the slot the VCS indicator was supposed to occupy —
	# measured 73 x 0 px on `cloud` 402c1d35: a box spanning the ENTIRE gutter,
	# lying across the line number by 29px, the breakpoint by 9px and the
	# tracepoint by 10px simultaneously, with no height and therefore nothing
	# drawn and nothing to click.
	#
	# It did no visible harm, which is exactly why nothing caught it. A
	# zero-height box paints no pixels, so every screenshot was right and every
	# check that asked whether a control WORKED was right, and the strip still
	# had no room for a change indicator.
	#
	# THE NUMBERS ARE PRINTED, PASS OR FAIL. `viewmodel/viewmodels/
	# editor_gutter_lanes.nim` declares this band order and its unit suite
	# asserts the arithmetic; this reads back where the boxes LANDED. Neither
	# half is evidence on its own — the declaration cannot see a stylesheet and
	# the stylesheet cannot see the declaration — and a band map reported as a
	# boolean would be readable against neither.
	r_bands="$(python3 -c '
import json, sys
b = json.load(open(sys.argv[1]))["dom"].get("gutterBands") or {}
bands = b.get("bands") or {}
print(" ".join(
    "%s[%s,%s]h%s" % (n, v["left"], v["right"], v["height"]) if v else n + "=absent"
    for n, v in bands.items()))
' "${cache}/route.json")"
	r_bandstate="$(python3 -c '
import json, sys
b = json.load(open(sys.argv[1]))["dom"].get("gutterBands") or {}
bands = b.get("bands") or {}
vcs = bands.get("vcs")
# Every band that must be a real, hittable box on every line. The pointer band
# is NOT in this list: its occupants are the current-line arrow (one line at a
# time) and the run-test control (hover-only), so on an ordinary row it
# correctly has no box.
need = ["lineNumber", "vcs", "breakpoint", "tracepoint"]
missing = [n for n in need if not bands.get(n) or not bands[n]["width"] or not bands[n]["height"]]
unowned = [n for n in need if bands.get(n) and not bands[n]["ownsHitArea"]]
print(len(b.get("overlaps") or []))
print(",".join(missing) or "none")
print(",".join(unowned) or "none")
print(",".join(b.get("order") or []))
print(json.dumps(b.get("overlaps") or []))
print((vcs or {}).get("height", 0))
' "${cache}/route.json")"
	r_band_overlaps="$(printf '%s\n' "${r_bandstate}" | sed -n 1p)"
	r_band_missing="$(printf '%s\n' "${r_bandstate}" | sed -n 2p)"
	r_band_unowned="$(printf '%s\n' "${r_bandstate}" | sed -n 3p)"
	r_band_order="$(printf '%s\n' "${r_bandstate}" | sed -n 4p)"
	r_band_overlap_list="$(printf '%s\n' "${r_bandstate}" | sed -n 5p)"
	r_vcs_height="$(printf '%s\n' "${r_bandstate}" | sed -n 6p)"

	if [ "${r_band_missing}" = "none" ]; then
		ck ok "arm R: all four of the gutter's reserved concerns have a real box — ${r_bands}"
	else
		ck fail "arm R: these gutter bands have no box a pointer can reach: ${r_band_missing} — ${r_bands}"
	fi

	# THE VCS BAND SPECIFICALLY, and its HEIGHT, because that is the field the
	# defect lived in. Width alone was never wrong: `.diff-line` was 73px wide.
	if [ "${r_vcs_height:-0}" -gt 0 ]; then
		ck ok "arm R: the VCS change band is ${r_vcs_height}px tall, so the strip has somewhere to draw a per-line change indicator"
	else
		ck fail "arm R: the VCS change band is ${r_vcs_height}px tall — it is a slot in name only and the gutter has no room for a VCS indicator"
	fi

	if [ "${r_band_overlaps}" = "0" ] && [ "${r_band_unowned}" = "none" ]; then
		ck ok "arm R: and no two of them share a pixel, each owning the hit test at its own centre — left to right: ${r_band_order}"
	else
		ck fail "arm R: gutter bands overlap (${r_band_overlap_list}) or do not own their own centre (${r_band_unowned}) — ${r_bands}"
	fi

	# CONSTRAINTS SHOWS A MEASURED NUMBER. 17 is the ACIR total the SHIPPING
	# wasm compiler computes for this template — NOT the flake `nargo`'s answer,
	# which differs for these same sources; that disagreement is why the gate
	# was moved onto the shipping engine. `ci/test/noir-template-toolchain.sh`
	# recompiles with that module and fails if the bundle's copy has drifted, so
	# the number written here is pinned by a measurement rather than by taste.
	r_constraints="$(python3 -c '
import json, sys
rows = json.load(open(sys.argv[1]))["dom"].get("constraintRows") or []
print(" ".join(r["name"] + "=" + r["count"] + "(" + r["kind"] + ")" for r in rows))
' "${cache}/route.json")"
	case "${r_constraints}" in
	*"main=${acir_expected}(acir)"*)
		ck ok "arm R: Constraints shows the measured ACIR opcode count: ${r_constraints}"
		;;
	*)
		ck fail "arm R: Constraints does not show main=${acir_expected}(acir) — rows were '${r_constraints}'"
		;;
	esac
	r_prov="$(jsonraw route dom.constraintProvenance)"
	case "${r_prov}" in
	*"compiler this page runs"*)
		ck ok "arm R: the counts name the compiler that produced them, so a reader can judge them: ${r_prov}"
		;;
	*)
		ck fail "arm R: the constraint counts do not name the compiler that produced them (${r_prov}) — a number a user cannot judge"
		;;
	esac

	# §1a's PROPORTIONS. Not decoration: the same layout produced 29/33/37
	# before `openNewLayoutContainer` stopped letting GoldenLayout's `addChild`
	# split the row evenly, and a file tree as wide as the editor is a
	# different product from the one the picture draws. The tolerance is ±4
	# points, which is wider than sub-pixel noise and far narrower than the
	# even split this exists to catch.
	#
	# THE THIRD COLUMN IS NOW CONSTRAINTS, AND THIS WAS RESTATED DELIBERATELY.
	# §1a used to draw TEST RESULTS as the right-hand column; TESTS is now a tab
	# of the FILES stack, so a nested pane's box is 0 whenever it is not the
	# active tab and reading it here would assert nothing about the layout. The
	# check did not become weaker: it still reads three measured boxes against
	# three declared numbers with the same tolerance, and the pane that left the
	# row is asserted separately and more strictly below — a tab has to be in
	# the strip AND have a box, which "present" never required.
	#
	# What must NOT happen to this check is that it stops naming three
	# proportions. A gate that measures two is one an even split passes.
	r_wfs="$(python3 -c '
import json, sys
w = json.load(open(sys.argv[1]))["dom"].get("paneWidths") or {}
print(w.get("filesystem", -1), w.get("editor", -1), w.get("constraints", -1))
' "${cache}/route.json")"
	if python3 -c '
import sys
fs, ed, cs = (float(x) for x in sys.argv[1].split())
ok = abs(fs - 20) <= 4 and abs(ed - 55) <= 4 and abs(cs - 25) <= 4
sys.exit(0 if ok else 1)
' "${r_wfs}"; then
		ck ok "arm R: the panes sit at §1a's proportions — filesystem/editor/constraints ${r_wfs} against 20/55/25"
	else
		ck fail "arm R: the panes are at ${r_wfs} and §1a draws 20/55/25 for filesystem/editor/constraints — GoldenLayout split the row evenly instead of honouring the layout's declaration"
	fi

	# AND THE PANE THAT LEFT THE ROW IS STILL REACHABLE.
	#
	# §1a draws TESTS as a tab of the panel that holds FILES and VCS. "Nested"
	# is a claim about a tab STRIP, so it is read off one: the tab must be in
	# the FILES strip, must have a box of its own, and must not be in the
	# overflow dropdown — which is `display: none` here, behind an opener
	# `stackCreated` removes, so a tab in it is present to every element count
	# and reachable by nobody. That last clause is why this is not a
	# `querySelector` check.
	r_tests_ok="$(python3 -c '
import json, sys
t = json.load(open(sys.argv[1]))["dom"].get("testsTab") or {}
if not t.get("present"):
    print("absent titles=" + ",".join(t.get("titlesSeen") or []))
    raise SystemExit(1)
box = t.get("box") or {}
sibs = t.get("siblings") or []
exiled = t.get("exiled") or []
print("box=%sx%s strip=%s exiled=%s" % (box.get("w"), box.get("h"), "|".join(sibs), ",".join(exiled) or "none"))
ok = (box.get("w") or 0) > 0 and (box.get("h") or 0) > 0 \
     and "FILES" in sibs and "TESTS" not in exiled
raise SystemExit(0 if ok else 1)
' "${cache}/route.json")" && r_tests_rc=0 || r_tests_rc=$?
	if [ "${r_tests_rc}" = "0" ]; then
		ck ok "arm R: TESTS is a reachable tab of the panel that holds FILES — ${r_tests_ok}"
	else
		ck fail "arm R: TESTS is not a reachable tab of the FILES panel (${r_tests_ok}) — §1a draws it there, and a tab with no box or one in the hidden overflow list is present rather than reachable"
	fi

	# AND WHAT IT COSTS TO RUN THE TESTS, recorded as a number.
	#
	# Not an assertion — the arrangement is a product decision and this gate is
	# not the place to relitigate it. But the cost of nesting a pane that
	# carries a control is exactly one extra gesture, and a number in the gate's
	# output is how that stays visible to whoever next changes either.
	r_gestures="$(json route runClick.gesturesToRun)"
	note "arm R: reaching a started test run from the mounted workspace took ${r_gestures} pointer action(s)"

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
		ck ok "arm S: the renderer still mounted a surface, so this arm isolates the routing and not the mount"
		;;
	*)
		ck fail "arm S: the renderer stopped mounting altogether (line: '${s_renderer}'); the arm does not isolate the route"
		;;
	esac
fi
echo

echo "Arm V: MUTATION — the template surface is mounted and painted over"
echo "    The state a DOM-only check calls a pass. Expect the VISIBILITY"
echo "    assertion RED and the mount assertion GREEN."
if ! run_arm covered mutate_covered_surface "/noir"; then
	ck fail "arm V could not be measured"
	ck fail "arm V could not be measured (second half)"
	ck fail "arm V could not be measured (status bar half)"
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
		ck ok "arm V: the panel is still mounted, so this arm isolates painting from mounting"
	else
		ck fail "arm V: the panel stopped mounting (${v_panels}); the arm does not isolate occlusion"
	fi

	# ...AND IT VOUCHES FOR THE STATUS-BAR GUARD TOO. The overlay is
	# full-viewport, so it covers `#status` exactly as the durability banner
	# did. If arm R's occlusion check could not go red here it would be a
	# check that cannot distinguish a clear footer from a covered one.
	#
	# `found` must stay true: an arm that made the bar VANISH would redden the
	# same assertion for the wrong reason, and would vouch for nothing.
	v_bar_found="$(json covered dom.statusBar.found)"
	v_bar_clear="$(json covered dom.statusBar.unobscured)"
	if [ "${v_bar_found}" = "true" ] && [ "${v_bar_clear}" = "false" ]; then
		ck ok "arm V: the status bar is still in the document and reads as COVERED, so arm R's occlusion guard can fail"
	else
		ck fail "arm V: status bar found=${v_bar_found} unobscured=${v_bar_clear} under a full-viewport overlay — arm R's occlusion guard cannot detect occlusion and proves nothing"
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
	ck fail "arm O could not be measured (the title half)"
else
	o_origin="$(json language-host dom.origin)"
	o_welcome="$(json language-host dom.welcomeScreenRoots)"
	o_fs="$(json language-host dom.filesystemPanels)"
	o_entries="$(json language-host dom.filesystemEntries)"
	o_visible="$(json language-host dom.entryLabelsVisible)"
	o_renderer="$(json language-host rendererLine)"
	o_title="$(json language-host dom.title)"

	# NON-VACUITY, and it is specific to this arm: a `--host-resolver-rules`
	# that silently failed to apply would leave the page on `127.0.0.1`, where
	# the welcome screen is CORRECT — so the arm would fail while saying
	# nothing true about the product. The origin is asserted before the surface.
	if [ "${o_origin}" = "http://${language_host}" ]; then
		ck ok "arm O: the page is on ${o_origin}, so this arm measured the second domain"
	else
		ck fail "arm O: the page reports origin '${o_origin}', not http://${language_host} — the host mapping did not apply and the surface check below would be about the wrong host"
	fi

	# THE HOST HALF of the naming claim. `noirstudio.dev/` has no `/noir` in
	# it — the language comes from the ORIGIN — so a build that read the path
	# and not the descriptor would pass arm R and fail here.
	if [ "${o_title}" = "Noir Studio" ]; then
		ck ok "arm O: / on the language host calls itself Noir Studio, so the name follows the origin and not only the path"
	else
		ck fail "arm O: / on the language host has title '${o_title}', not 'Noir Studio'"
	fi

	if [ "${o_welcome}" = "0" ] && [ "${o_fs}" = "1" ] &&
		[ "${o_visible}" = "${o_entries}" ] && [ "${o_entries:-0}" -ge 5 ] 2>/dev/null; then
		ck ok "arm O: / on the language host opened the template — ${o_visible} visible rows, no welcome screen"
	else
		ck fail "arm O: / on the language host gave ${o_welcome} welcome screen(s), ${o_fs} panel(s), ${o_visible}/${o_entries} visible rows"
		dump_arm language-host
	fi

	case "${o_renderer}" in
	*"surface=edit-mode"*"host=noir"*)
		ck ok "arm O: the renderer named the host language it routed by: ${o_renderer#*: }"
		;;
	*)
		ck fail "arm O: the renderer line does not report a noir host (line: '${o_renderer}')"
		;;
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
		ck ok "arm A: the loop arm still booted, so this arm is red for the renderer and not for everything"
		;;
	*)
		ck fail "arm A: the loop arm also stopped booting; the arm does not isolate the renderer"
		;;
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
		ck ok "arm B: the renderer reported a refusal rather than a silent blank page"
		;;
	*)
		ck fail "arm B: the renderer said '${b_renderer}' — a blank page with no explanation is the failure this gate exists for"
		;;
	esac
fi
echo

echo "Arm C: MUTATION — installPlatform's body is emptied, so boot() runs and"
echo "    installs nothing. Expect: the REACH check RED, the mount GREEN."
if ! run_arm no-platform mutate_no_platform_install; then
	# `run_arm` returns non-zero when the mutation function does, and
	# `mutate_no_platform_install` exits 1 when its needle is absent. That is
	# deliberate: a mutation that cannot find what it mutates must fail the
	# gate, not pass it. The predecessor of this arm would have started
	# reporting exactly this the day the second bundle was removed.
	ck fail "arm C could not be measured"
	ck fail "arm C could not be measured (second half)"
else
	c2_renderer="$(json no-platform rendererLine)"
	c2_welcome="$(json no-platform dom.welcomeScreenRoots)"
	# THE ARM'S OWN ASSERTION, and the twin of the control's reach check. If
	# this stayed green, `platform=pkWeb` in the control would be measuring
	# something other than the install — a constant, or the boot arm's answer
	# leaking in — and the reach check would prove nothing.
	case "${c2_renderer}" in
	*"platform=pkWeb"*)
		ck fail "arm C: the renderer still reports pkWeb with installPlatform neutered, so the control's reach check does not detect a platform that never reached the renderer"
		;;
	*)
		ck ok "arm C: the renderer falls back to uninstalledProfile when nothing installs a platform, so the control's reach check is real (line: '${c2_renderer}')"
		;;
	esac
	# The twin, and the reason this arm names a mechanism rather than reporting
	# that something broke. The platform reach and the mount are independent:
	# `startWebRenderer` mounts through the in-page IPC host and the entry
	# layer, neither of which consults `ctPlatform()`. So the correct signature
	# of THIS defect is a page that looks completely healthy — it paints,
	# routes and answers keys — and cannot compile. An arm that also took the
	# mount down would be consistent with almost any bug, and would not
	# distinguish this one from arm A or arm B.
	#
	# It is also the historically accurate signature: this is what
	# ide.codetracer.com served, and why every check was green over it.
	if [ "${c2_welcome}" = "1" ]; then
		ck ok "arm C: the renderer still mounted, so the arm isolates the platform reach from the mount"
	else
		ck fail "arm C: the renderer also stopped mounting (${c2_welcome} roots); the arm does not isolate the platform reach"
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
		ck fail "arm E: the editor still paints the template's source with the host replying synchronously — arm R's source assertion cannot detect the early-resolve defect, so it proves nothing"
		;;
	*)
		ck ok "arm E: the editor pane loses its source when the host replies synchronously, so arm R's source assertion can fail"
		;;
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
		fi
		;;
	*)
		ck fail "arm T: removing #menu also took the editor's source off the screen — it is not isolating the chrome"
		;;
	esac
fi
echo

echo "Arm F: MUTATION — the compiled-in config fixture stops parsing"
echo "    A non-nil Config with an empty shortcut map: the page still mounts"
echo "    and paints. Expect arm R's SHORTCUT check RED, everything else GREEN."
if ! run_arm no-bindings mutate_unparsed_bindings "/noir"; then
	ck fail "arm F could not be measured"
	ck fail "arm F could not be measured (second half)"
else
	f_renderer="$(json no-bindings rendererLine)"
	f_shortcuts="$(printf '%s' "${f_renderer}" | sed -n 's/.*shortcuts=\([0-9-]*\).*/\1/p')"
	f_entries="$(json no-bindings dom.entryLabelsVisible)"
	f_lines="$(python3 -c 'import json,sys; print(" ".join((json.load(open(sys.argv[1]))["dom"].get("editorLinesVisible") or [])))' "${cache}/no-bindings.json")"
	if [ "${f_shortcuts:-0}" -lt 40 ] 2>/dev/null; then
		ck ok "arm F: the shortcut count falls to ${f_shortcuts:-none} when the fixture's bindings section is renamed, so arm R's shortcut assertion can fail"
	else
		ck fail "arm F: the renderer still reports ${f_shortcuts} bound chords with the fixture's bindings section renamed — arm R's shortcut assertion is not reading the parse"
	fi
	# The twin, and it is the point of the arm: an empty shortcut map is
	# INVISIBLE. The page must still mount and paint exactly as before, which
	# is what makes the count on the renderer line the only witness there is.
	case "${f_lines}" in
	*"fn main"*)
		if [ "${f_entries:-0}" -ge 5 ] 2>/dev/null; then
			ck ok "arm F: the page still mounts and paints (${f_entries} tree rows, the editor's source on screen) with no keyboard at all — which is why this defect needs a reported count and not a DOM check"
		else
			ck fail "arm F: the mutation also emptied the file tree (${f_entries} rows) — it is breaking more than the bindings parse"
		fi
		;;
	*)
		ck fail "arm F: the mutation also took the editor's source off the screen — it is breaking more than the bindings parse"
		;;
	esac
fi
echo

echo "Arm N: MUTATION — the shipped constraint counts are perturbed"
echo "    Expect arm R's CONSTRAINT check RED; tests, panes and proportions"
echo "    green. Without this, a hard-coded 17 would pass."
if ! run_arm bad-counts mutate_wrong_constraint_counts "/noir"; then
	ck fail "arm N could not be measured"
	ck fail "arm N could not be measured (second half)"
else
	n_rows="$(python3 -c '
import json, sys
rows = json.load(open(sys.argv[1]))["dom"].get("constraintRows") or []
print(" ".join(r["name"] + "=" + r["count"] for r in rows))
' "${cache}/bad-counts.json")"
	n_tests="$(json bad-counts dom.testRows)"
	case "${n_rows}" in
	*"main=${acir_expected}"*)
		ck fail "arm N: the pane still shows main=${acir_expected} with the shipped constant perturbed — the number is not coming from the bundle, so arm R's check proves nothing"
		;;
	*"main=99"*)
		ck ok "arm N: the pane follows the shipped constant (${n_rows}), so arm R's count assertion reads real data and can fail"
		;;
	*)
		ck fail "arm N: the constraints pane shows '${n_rows}' — the mutation broke more than the count"
		;;
	esac
	if [ "${n_tests:-0}" -eq 5 ] 2>/dev/null; then
		ck ok "arm N: Test Results still lists 5 tests, so this arm isolates the constraint counts from the rest of the first screen"
	else
		ck fail "arm N: Test Results lists ${n_tests:-0} test(s) — the mutation is not isolating the counts"
	fi
fi
echo

echo "Arm W: MUTATION — the layout over-subscribes its own row"
echo "    GoldenLayout's default even split, restored. Expect arm R's"
echo "    PROPORTION check RED and every pane's content green."
if ! run_arm wide-layout mutate_oversubscribed_layout "/noir"; then
	ck fail "arm W could not be measured"
	ck fail "arm W could not be measured (second half)"
else
	w_widths="$(python3 -c '
import json, sys
w = json.load(open(sys.argv[1]))["dom"].get("paneWidths") or {}
print(w.get("filesystem", -1), w.get("editor", -1), w.get("testResults", -1))
' "${cache}/wide-layout.json")"
	if python3 -c '
import sys
fs, ed, tr = (float(x) for x in sys.argv[1].split())
sys.exit(0 if abs(ed - 55) > 4 else 1)
' "${w_widths}"; then
		ck ok "arm W: the editor loses its declared width when the row is over-subscribed (${w_widths}), so arm R's proportion assertion can fail"
	else
		ck fail "arm W: the panes are still at ${w_widths} — arm R's proportion check is not reading the layout's declaration"
	fi
	# The twin: geometry only. Every pane must still hold exactly what it held.
	w_tests="$(json wide-layout dom.testRows)"
	w_counts="$(python3 -c '
import json, sys
rows = json.load(open(sys.argv[1]))["dom"].get("constraintRows") or []
print(" ".join(r["name"] + "=" + r["count"] for r in rows))
' "${cache}/wide-layout.json")"
	case "${w_counts}" in
	*"main=${acir_expected}"*)
		if [ "${w_tests:-0}" -eq 5 ] 2>/dev/null; then
			ck ok "arm W: all four panes still hold their own content (5 tests, ${w_counts}), so this arm isolates geometry from data"
		else
			ck fail "arm W: Test Results lost its rows (${w_tests:-0}) — the arm is not isolating geometry"
		fi
		;;
	*)
		ck fail "arm W: the constraint counts changed too (${w_counts}) — the arm is not isolating geometry"
		;;
	esac
fi
echo

# ---------------------------------------------------------------------------
echo "Arm P: MUTATION — the deployment delivers no wasm worker script"
echo "    The negative control for the PRESS. Expect arm R's run-start,"
echo "    verdict and pane-moved checks RED, and its press check GREEN:"
echo "    the control is still painted and still takes a click."
probe_click_run=1
if ! run_arm no-worker mutate_no_wasm_worker "/noir"; then
	probe_click_run=""
	ck fail "arm P could not be measured"
	ck fail "arm P could not be measured (second half)"
	ck fail "arm P could not be measured (third half)"
else
	probe_click_run=""
	p_runbtn="$(jsonraw no-worker dom.testRunButton.text)"
	p_clicked="$(json no-worker runClick.clicked)"
	p_started="$(json no-worker runClick.startedLine)"
	p_results="$(json no-worker runClick.resultsLine)"
	p_headbefore="$(json no-worker runClick.headlineBefore)"
	p_headafter="$(json no-worker runClick.headlineAfter)"
	if [ "${p_clicked}" = "true" ] && [ "${p_runbtn}" != "null" ] && [ -n "${p_runbtn}" ]; then
		ck ok "arm P: the control is still painted (${p_runbtn}) and still takes a real click, so arm R's press check is not what this arm reddens"
	else
		ck fail "arm P: the control was not painted or not clickable (painted=${p_runbtn}, clicked=${p_clicked}) — the arm is not isolating the RUN from the CONTROL"
	fi
	if [ -z "${p_started}" ]; then
		ck ok "arm P: and the click started no run, so arm R's run-start assertion can fail"
	else
		ck fail "arm P: a run started with no worker script to start it ('${p_started}') — arm R's run-start assertion proves nothing"
	fi
	# THIS CHECK ASSERTED THE DEFECT `12c6ff48` FIXED, and went red the moment
	# the fix landed. It required the headline to be UNCHANGED after a run that
	# could not start — and "a pane positively asserting the tests have not run,
	# one gesture after a run of them failed" is that commit's own description
	# of what it was correcting. Measured on `cloud` 6d60d54f with no local
	# change at all: 74 checks, this one failure, `'5 tests, not run yet' ->
	# 'run failed, no tests ran'`.
	#
	# So it is inverted rather than deleted. The arm's job is to be arm R's
	# negative control, and the half that still does that work is the VERDICT:
	# no `test-results ok=true` line reaches the pane, which is what arm R's
	# verdict assertion needs in order to be falsifiable.
	#
	# WHAT THIS ARM NO LONGER CONTROLS, said out loud rather than quietly
	# dropped: arm R's "the pane moved" assertion. Both a successful run and a
	# failed one now move the headline, deliberately, so this arm cannot show
	# that assertion failing. It is the weaker half of arm R's pair — a headline
	# that changed says something happened, the verdict line says WHAT — and the
	# stronger half is still controlled here.
	if [ -z "${p_results}" ] && [ "${p_headafter}" != "${p_headbefore}" ]; then
		ck ok "arm P: no verdict reached the pane, so arm R's verdict assertion can fail — and the pane SAYS SO rather than standing still: '${p_headbefore}' -> '${p_headafter}'"
	elif [ -z "${p_results}" ]; then
		ck fail "arm P: no verdict reached the pane, but the headline stayed '${p_headafter}' — a pane asserting the tests have not run, one gesture after a run of them failed"
	else
		ck fail "arm P: the pane reported a verdict ('${p_results}') with no worker to produce one — arm R's verdict assertion proves nothing"
	fi
fi
echo

# ---------------------------------------------------------------------------
echo "Arm G: the EDITOR'S OWN run-test control, pressed"
echo "    The report, verbatim: \"I tried to interact with the 'Run test'"
echo "    feature ... it just hanged in the browser without the ability to run"
echo "    the actual test.\" Arm R presses the TEST RESULTS pane's control and"
echo "    says nothing about this one — a different element, on a different"
echo "    surface, through a different hook."
# ---------------------------------------------------------------------------
# WHY THIS IS ITS OWN ARM AND NOT THREE MORE CHECKS IN ARM R.
#
# Arm R's press MUTATES the page: it clears the previous verdicts and moves the
# pane out of "not run yet". A second press measured after it would be pressing
# a control whose starting state the first press had already changed, and
# "5 tests, not run yet" -> "1 passed" is the transition that says this control
# did something. So the arm loads `/noir` again, untouched, and presses only
# the gutter.
#
# THE FOUR THINGS IT SEPARATES, because the reported defect satisfies the first
# two of them and fails the last two:
#
#   1. the control has a hit area of its own, disjoint from the breakpoint's;
#   2. the press was taken;
#   3. a run STARTED — the console line no amount of rendering can produce;
#   4. and the control STOPPED. The shipped bug was a control that span
#      forever over a message no host answered, so "it started spinning" is
#      the defect and not the fix.
probe_click_gutter_run=1
if ! run_arm gutter-run "" "/noir"; then
	probe_click_gutter_run=""
	ck fail "arm G could not be measured"
	ck fail "arm G could not be measured (second half)"
	ck fail "arm G could not be measured (third half)"
	ck fail "arm G could not be measured (fourth half)"
	ck fail "arm G could not be measured (deadline attribution)"
else
	probe_click_gutter_run=""
	g_slot="$(python3 -c '
import json, sys
s = (json.load(open(sys.argv[1])).get("gutterRunClick") or {}).get("slot")
if not s:
    print("absent"); raise SystemExit
print("line=%s box=[%s,%s]x%s ownsHitArea=%s overlapsBreakpoint=%s hit=%s" % (
    s["line"], s["left"], s["right"], s["height"], s["ownsHitArea"],
    s["overlapsBreakpoint"], s["hitElement"]))
' "${cache}/gutter-run.json")"
	g_ok="$(python3 -c '
import json, sys
s = (json.load(open(sys.argv[1])).get("gutterRunClick") or {}).get("slot")
print("yes" if s and s["ownsHitArea"] and not s["overlapsBreakpoint"]
      and s["width"] and s["height"] else "no")
' "${cache}/gutter-run.json")"
	g_clicked="$(json gutter-run gutterRunClick.clicked)"
	g_started="$(json gutter-run gutterRunClick.startedLine)"
	g_refused="$(json gutter-run gutterRunClick.refusedLine)"
	g_results="$(json gutter-run gutterRunClick.resultsLine)"
	g_running="$(json gutter-run gutterRunClick.runningAfterClick)"
	g_settled="$(json gutter-run gutterRunClick.runningAfterSettle)"
	g_settlems="$(json gutter-run gutterRunClick.settleWaitMs)"
	g_budget="$(json gutter-run gutterRunClick.settleBudgetMs)"
	g_total="$(json gutter-run gutterRunClick.totalMsFromClick)"
	g_pdl="$(json gutter-run gutterRunClick.productDeadlineMs)"
	g_before="$(json gutter-run gutterRunClick.beforeProductDeadline)"
	g_notice="$(json gutter-run gutterRunClick.timeoutNotice)"
	g_tail="$(python3 -c '
import json, sys
g = json.load(open(sys.argv[1])).get("gutterRunClick") or {}
print(" | ".join(l.replace("log: codetracer-noir-build: ", "")
                 for l in (g.get("consoleAtSettle") or [])) or "none")
' "${cache}/gutter-run.json")"
	g_headbefore="$(json gutter-run gutterRunClick.headlineBefore)"
	g_headafter="$(json gutter-run gutterRunClick.headlineAfter)"

	if [ "${g_ok}" = "yes" ]; then
		ck ok "arm G: the run control has a hit area of its own and it is not the breakpoint's — ${g_slot}"
	else
		ck fail "arm G: the run control is unreachable or shares the breakpoint's hit area — ${g_slot}"
	fi

	if [ "${g_clicked}" = "true" ] && [ -n "${g_started}" ]; then
		ck ok "arm G: pressing it STARTED a run — ${g_started}"
	else
		ck fail "arm G: the press started no run (clicked=${g_clicked}, refusal='${g_refused}') — this is the reported defect: a control that takes the click and reaches no runner"
	fi

	# THE VERDICT, and it must name a passing test. `startNoirTestRecording`
	# dispatches `nargo test --exact <selector>`, so ONE test is asked for and
	# one verdict is expected — which is what distinguishes this control from
	# the pane's ▶ (five) rather than merely repeating it.
	case "${g_results}" in
	*"ok=true passed=1 failed=0"*)
		ck ok "arm G: and the run reached a verdict for the one test it selected — ${g_results}"
		;;
	*)
		ck fail "arm G: no single-test verdict reached the pane — '${g_results:-none}'"
		;;
	esac

	# AND IT STOPPED. Both halves, because either alone is consistent with the
	# defect: a control that never span was never wired, and one that span and
	# stayed spinning is the bug exactly as reported.
	#
	# THE SECOND HALF IS WAITED FOR, NOT SAMPLED ON A TIMER, and the difference
	# blocked a production deploy. This check used to read the slot count 1.5s
	# after the `test-results` line and call that "after the run settled". It is
	# not: for THIS control the verdict is not the end of the run. The intent is
	# `nriTestRecord`, so `web_noir_build.onExit` goes on to dispatch
	# `nbpTestRecord` and then `nbpTrace`, and `noirTestRunSettled` — the thing
	# that stops the slot — is only reached after those. Deploy run 33697961922
	# caught the arm mid-chain and the last line it recorded said so:
	# `nbpTestRecord-started starts=2`. The slot was spinning because the run
	# was running. The product was right and the check was racing it.
	#
	# The probe now polls until the slot clears, with a budget under the
	# product's own two-minute deadline so a genuinely hung run cannot be
	# cleared by that deadline and pass this check for the wrong reason. The
	# ELAPSED TIME is printed because a settle that took 200ms and one that took
	# 45s are different facts and this check should not hide which it saw.
	if [ "${g_running}" -ge 1 ] 2>/dev/null && [ "${g_settled}" = "0" ]; then
		ck ok "arm G: the control showed a running state (${g_running} slot) and CLEARED it when the run actually settled, ${g_settlems}ms after the verdict — headline '${g_headbefore}' -> '${g_headafter}'"
	else
		ck fail "arm G: running slots at the press=${g_running}, still ${g_settled} after waiting ${g_settlems}ms of a ${g_budget}ms budget — expected at least one and then none. Console tail: ${g_tail}"
	fi

	# AND THE SLOT WAS CLEARED BY THE RUN, NOT BY THE PRODUCT GIVING UP ON IT.
	#
	# `runTestFromGutter` arms a `setTimeout` at the click for
	# `editorTestRunFrames * 300` = 120000ms (`ui/editor.nim:2164`, used at
	# :2321). When it fires it calls `restoreTestButton`, which clears the slot,
	# and shows "The test run did not answer within two minutes…". So a cleared
	# slot has TWO causes and the check above cannot tell them apart.
	#
	# It can be reached: the waits ahead of that poll are 30000 for the start,
	# 180000 for the exit and 10000 for the verdict, so a run that hung for 150s
	# arrives at the poll with the slot already tidied and reads as a clean
	# settle. That is a false PASS in the gate that guards the deploy, and it is
	# invisible in a green run — the worse of the two failure modes this arm has
	# had, because the racy one at least went red.
	#
	# Two independent readings, because either alone can be argued with: the
	# elapsed time from the CLICK against the product's own constant, and the
	# absence of the notification the product paints when that constant fires.
	if [ "${g_before}" = "true" ] && [ -z "${g_notice}" ]; then
		ck ok "arm G: and it was the RUN that cleared it, not the two-minute deadline — sampled ${g_total}ms after the click against a ${g_pdl}ms product deadline, with no timeout notice on screen"
	else
		ck fail "arm G: the slot was sampled ${g_total}ms after the click against a ${g_pdl}ms product deadline (beforeDeadline=${g_before}), notice='${g_notice}' — a cleared slot here is the product giving up, not a settle, and the check above would have passed on it"
	fi
fi
echo

# ---------------------------------------------------------------------------
echo "Arm Q: MUTATION — the same press with no wasm worker script"
echo "    Arm G's negative control. Expect its press check GREEN and its"
echo "    run-start and verdict checks RED: the control is still painted and"
echo "    still takes a click, and there is nothing behind it to run."
# ---------------------------------------------------------------------------
probe_click_gutter_run=1
if ! run_arm gutter-run-no-worker mutate_no_wasm_worker "/noir"; then
	probe_click_gutter_run=""
	ck fail "arm Q could not be measured"
	ck fail "arm Q could not be measured (second half)"
	ck fail "arm Q could not be measured (the slot's running state)"
else
	probe_click_gutter_run=""
	q_clicked="$(json gutter-run-no-worker gutterRunClick.clicked)"
	q_present="$(python3 -c '
import json, sys
s = (json.load(open(sys.argv[1])).get("gutterRunClick") or {}).get("slot")
print("yes" if s and s["width"] and s["height"] else "no")
' "${cache}/gutter-run-no-worker.json")"
	q_started="$(json gutter-run-no-worker gutterRunClick.startedLine)"
	q_results="$(json gutter-run-no-worker gutterRunClick.resultsLine)"
	q_settled="$(json gutter-run-no-worker gutterRunClick.runningAfterSettle)"
	q_refused="$(json gutter-run-no-worker gutterRunClick.refusedLine)"
	q_settlems="$(json gutter-run-no-worker gutterRunClick.settleWaitMs)"
	q_budget="$(json gutter-run-no-worker gutterRunClick.settleBudgetMs)"
	if [ "${q_present}" = "yes" ] && [ "${q_clicked}" = "true" ]; then
		ck ok "arm Q: the control is still painted and still takes a real click, so arm G's press check is not what this arm reddens"
	else
		ck fail "arm Q: the control was not painted or not clickable (painted=${q_present}, clicked=${q_clicked}) — the arm does not isolate the RUN from the CONTROL"
	fi
	if [ -z "${q_started}" ]; then
		ck ok "arm Q: and the press started no run and reached no verdict ('${q_results:-none}'), so arm G's run-start and verdict assertions can fail"
	else
		ck fail "arm Q: a run started with no worker script to start it ('${q_started}') — arm G's run-start assertion proves nothing"
	fi

	# AND THE SLOT STOPPED ANYWAY, which is the half this arm found rather than
	# confirmed. The refusal here is SYNCHRONOUS — the console line is
	#
	#     codetracer-noir-build: nbpTest-refused starts=0 reason=pkCancelled
	#
	# and it is emitted inside the hook, before the press has finished being
	# handled. `runTestFromGutter` used to arm its spinner on the line AFTER
	# that hook returned, so the settle swept an empty list and the slot span
	# for the full two-minute deadline over a run refused at the click. That is
	# the reported "it just hanged in the browser", reachable on any deployment
	# whose worker script is missing.
	#
	# Measured here at ~30s after the press, which is well inside that deadline:
	# before the fix this read 1, and the only thing that would have cleared it
	# is a timeout no user waits through.
	if [ "${q_settled}" = "0" ]; then
		ck ok "arm Q: and the control did NOT stay spinning over the refusal — it cleared in ${q_settlems}ms, against a ${q_budget}ms budget that is itself well inside the product's two-minute deadline"
	else
		ck fail "arm Q: ${q_settled} slot(s) still spinning after ${q_settlems}ms, over a run refused synchronously ('${q_refused}') — the control is showing a run that is not happening, which is the reported defect"
	fi
fi
echo

# 59 -> 61. NS9 added two to the CONTROL arm — the renderer's own
# `ctPlatform()` is the booted web platform, and what the deployment delivered
# agrees with what the renderer can run. Arm C's two are unchanged in number
# and changed in subject: it used to unwrap two Nim bundles into a shared
# global scope, and there is only one bundle now, so it neuters
# `installPlatform` instead and reddens the first of the two new checks.
#
# Raised in the same commit that adds them, so the additions are RECORDED. A
# count that tracked the tally automatically would let an assertion be deleted
# without anything noticing, which is the whole reason this line exists.
# 66, and the two new ones are the ▶'s presence and its enabled state. The
# absence check that used to be here was inverted rather than added to — it
# still costs one assertion, it now requires the opposite thing.
#
# 68 -> 71. The ▶'s "enabled state" check above turned out to assert a CLASS
# NAME, which is the one fact that cannot tell a live control from a dead one;
# it is now four checks that press the control and watch for the run — it took
# the click, the click started a run, the run reached its verdicts, and the
# pane moved. Three of the four are facts no amount of rendering can produce.
#
# 71 -> 74. Arm P is those four checks' negative control: it deletes the
# compiler module the deployment is supposed to carry and requires the press to
# go through while the RUN does not. Without it "the button worked" would be
# the same unearned claim the class check was making.
#
# 74 -> 83, and the nine are three subjects.
#
#   * THREE in arm R for the gutter's BAND MAP. The strip carries four
#     concerns — breakpoints/tracepoints, VCS change indicators, line numbers
#     and the run-test control — and the VCS one had a slot measuring 73 x 0
#     px that lay across the other three at once. It painted nothing, so every
#     screenshot agreed with it and every check that asked whether a control
#     worked was satisfied by it.
#
#   * FOUR in arm G, which presses the EDITOR'S run control rather than the
#     pane's. The two are different elements on different surfaces through
#     different hooks, and only one of them was ever pressed by anything here
#     — while the one that was not is the one the bug report is about.
#
#   * THREE in arm Q, arm G's negative control. Without it "the gutter control
#     ran the test" would rest on a press whose failure mode nothing had
#     reconstructed — and its third check found a live defect rather than
#     confirming an absence: a dispatch refused SYNCHRONOUSLY left the slot
#     spinning for the full two-minute deadline, because `runTestFromGutter`
#     armed the spinner on the line after the hook that had already settled.
# 86 -> 89, and the three are one subject: WHAT THE PRODUCT CALLS ITSELF.
#
# The entry document carried one literal `<title>` for the three addresses the
# deployment serves, so `ide.codetracer.com/` called itself Noir Studio and
# `noirstudio.dev` and `/noir` both led with CodeTracer. Every bookmark taken
# anywhere on the deployment carried the wrong product name, and this gate —
# which asserts the DOM thoroughly — had no check that could see a title at
# all. One per address: the neutral root (control), the path (arm R) and the
# origin (arm O), because a build can get any one of the three right while
# reading the wrong input for the other two.
expect_count 89
echo "${checks} check(s), ${failures} failure(s)"
if [ "${failures}" -eq 0 ]; then
	echo "RESULT: OK — the bundle mounts a product, and each check was shown to be able to fail"
	exit 0
fi
echo "RESULT: FAILED — ${failures} check(s)"
exit 1
