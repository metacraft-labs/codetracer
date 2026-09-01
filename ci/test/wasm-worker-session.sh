#!/usr/bin/env bash
#
# wasm-worker-session.sh — a wasm-worker session, alive in a real tab, over
# the assembled publish tree.
#
# WHAT THIS IS FOR
# ----------------
# `wasm_worker_browser.js` could answer three questions — `configure`,
# `compile`, `trace` — and each of them posted `output` and then `exit` in the
# same turn. Nothing stayed alive. `WasmHost.start` handed back a
# `ProcessHandle` and the handle never referred to anything ongoing.
#
# That is exactly right for a compiler and fatal for what comes next. An Aztec
# development node has to persist across user actions: register a contract,
# execute a transaction against the world state that registration produced,
# seal a block containing it — three separate actions, minutes apart, over
# accumulated state. A worker whose only verbs are one-shot cannot host it.
#
# This gate is the proof that it now can. The subject is a session that opens,
# survives eight round trips, refuses a transaction against a contract it does
# not know, ACCEPTS the same transaction after a separate round trip registered
# it, and is then ended deliberately with the worker still running.
#
# WHY A BROWSER, AND WHY THE PUBLISH TREE
# ---------------------------------------
# `src/frontend/viewmodel/tests/unit/test_wasm_worker.nim` proves the protocol
# on both backends against a fake transport, and it proves things a browser
# cannot express — "this future never settled" chief among them. What no unit
# test can prove is that any of it is REACHED, and unreachable-but-correct is
# this repository's signature defect: `newBrowserWasmHost` went a milestone
# uncalled with a doc comment explaining why, and `wasm_worker_browser.js`
# handled a `configure` message from the day it was written while nothing in
# Nim ever sent one — so a deployment could serve both modules perfectly and
# still fail every run.
#
# So every part under test here is a shipping part:
#
#   * `/assets/wasm-worker.js`, byte for byte as `web-bundle-assets.sh` placed
#     it. The gate asserts the copy it serves is unmodified against the
#     original, so "the tree was quietly patched" is not available to it.
#   * `host/web_browser.newBrowserWasmWorker`, the one place a browser
#     `Worker` is constructed — the same call `newBrowserWasmHost` makes.
#   * `platform/wasm_worker.nim`, the protocol driver, unmodified.
#
# The harness page is served ALONGSIDE the tree at `/__harness/`, not inside
# it. That is deliberate: the deploy workflow asserts EXACTLY ONE Nim bundle in
# the published document in both directions, and those two arms were merged
# today and must not split again. A harness bundle dropped next to `ui.js`
# would be the shape that assertion exists to catch, even in a copy nobody
# deploys.
#
# THE COVERAGE HOLE THIS ALSO FILLS, and a correction to the record
# -----------------------------------------------------------------
# The deploy workflow's step "Prove the modules RUN before publishing them"
# runs `ci/test/noir-wasm-worker-e2e.sh`, which drives the NODE TWIN of this
# protocol. It was believed to skip on this machine for want of a built tracer
# wasm. Measured, it does not: both modules are present under
# `~/m/dev/noir/target/wasm32-unknown-unknown/release/`, the tracer built
# 2026-09-01, and the e2e runs green here with the two variables exported —
# 3 checks, digests equal, 29 events. It is run as part of this change's
# evidence rather than assumed skipped. What it does NOT cover is the session
# protocol, because it drives the twin and the twin is one-shot; that is what
# this gate is for.
#
# THE SHAPE, from Verification-Harness-Traps.md 4a and 4c
# ------------------------------------------------------
#   * COUNTED assertions, with the COUNT ITSELF asserted. `ck` tallies and
#     `expect_count` fails if the tally misses the number written at the
#     bottom. An arm that aborted, a probe that produced no JSON, a guard that
#     returned early — all of them land there rather than in a green summary.
#   * A CONTROL ARM, so the mutation arms cannot be red for an unrelated
#     reason.
#   * NON-VACUITY FIRST. Every arm guards on `reportPresent` before reading
#     anything out of the report: `jq` over `{}` answers `null` for every
#     field, and "no error was reported" is true of an empty object. Trap 4,
#     the empty haystack.
#   * A MUTATION MUST ACTUALLY MUTATE. `mutate` fails the gate if its pattern
#     matched nothing. A mutation arm whose premise has been removed by other
#     work reports "could not be measured" forever while looking like
#     coverage; one was caught doing exactly that in this repository today.
#
# VERIFIED TO REDDEN, each against the assertion written for it
# ------------------------------------------------------------
# In-gate, and re-verified on every run because each arm asserts that its own
# target went red rather than merely that something did:
#
#   * arm A (a registration is not kept): reddens `sendAcceptedAfterRegister`
#     and leaves `registerAccepted` GREEN. The pair is the point — a session
#     that forgot is not the same as a `register` that broke, and an arm that
#     reddened both would not have told them apart.
#   * arm E (the session exits in the turn it opened — the state this change
#     replaces): reddens every delivery acknowledgement and leaves
#     `readyEvent` GREEN. That is precisely the signature of the shipped
#     behaviour: the service started, said hello, and was gone.
#   * arm O (the per-session drain guard removed): reddens
#     `burstHandledInOrder` and leaves `serialCount` at 8. Ordering, not
#     delivery — a queue that loses messages is a different defect and would
#     have moved the count.
#
# Out of gate, MEASURED — both were run, and the numbers below are what they
# printed, not what they were expected to print:
#
#   * `platform/wasm_worker.deliver`'s sequence-0 arm reverted to the early
#     return it used to be: `test_wasm_worker.nim` reports
#     `[FAILED] A \`failed\` ON SEQUENCE 0 FAILS EVERY OUTSTANDING RUN —
#     compileSettled=false sessionExits=0`, and `19 passed, 1 failed`. Exactly
#     its own assertion, and nothing else. In this gate the same revert
#     reddens arm I's `sessionSignalled`.
#
#   * the two-sequence rule removed — the queue-full refusal posted as
#     `{seq: <the session>, kind: 'failed'}` instead of on the delivery's own
#     sequence, with the limit at 0 so it fires. Measured over the same
#     harness: `readyEvent=true`, `sendBeforeAck=TRUE`, `sessionStillActive`
#     FALSE, `sessionExitCode=1`. Arm V's target goes red, and the shape is
#     worse than the assertion alone suggests: the caller is told its message
#     was ACCEPTED while the session it was sent to has just been destroyed by
#     the refusal. That is why an `input` carries its own sequence.
#
# NETWORK. A loopback static server over a directory this script assembled.
# Nothing is fetched from outside the machine, and the product's own
# no-egress claim (`ci/test/noir-studio-signed-out.sh`) is untouched: it is
# about the BUNDLE's egress sites, measured on the bundle, not on a harness.
#
# Usage:  bash ci/test/wasm-worker-session.sh
# Env:    CT_WEB_BUNDLE_DIR  a tree already assembled by web-bundle-assets.sh.
#                            Assembled here if unset.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

cache="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}/wasm-worker-session"
mkdir -p "${cache}"

checks=0
failures=0
ck() {
	checks=$((checks + 1))
	if [ "$1" = "ok" ]; then
		printf '  [OK]      %s\n' "$2"
	else
		failures=$((failures + 1))
		printf '  [FAILED]  %s\n' "$2"
	fi
}
note() { printf '      %s\n' "$*"; }

# `ckeq <got> <want> <sentence>` — one assertion, comparing two strings.
#
# Written as a helper rather than `[ ... ] && ck ok || ck fail` because that
# idiom is not if-then-else: if the middle command fails the last one runs too,
# so a green assertion could report itself red. `ck` happens to always succeed,
# which makes the idiom correct here BY ACCIDENT — and an assertion helper that
# is correct by accident is the wrong thing to have forty copies of.
#
# The failure message always carries what was actually seen. A gate that says
# only which assertion failed sends the next reader back to the browser.
ckeq() {
	if [ "$1" = "$2" ]; then
		ck ok "$3"
	else
		ck fail "$3 — got $1, wanted $2"
	fi
}

expect_count() {
	local want="$1"
	if [ "${checks}" -ne "${want}" ]; then
		printf '\nRESULT: FAILED — %d assertion(s) ran, %d were written.\n' \
			"${checks}" "${want}"
		printf 'An assertion that did not run is not an assertion that passed.\n'
		exit 1
	fi
}

echo "=== a wasm worker session, alive in a real tab ==="
echo

command -v node >/dev/null 2>&1 || {
	echo "node is not on PATH" >&2
	exit 2
}
command -v python3 >/dev/null 2>&1 || {
	echo "python3 is not on PATH" >&2
	exit 2
}
command -v nim >/dev/null 2>&1 || {
	echo "nim is not on PATH" >&2
	exit 2
}
[ -d node_modules/playwright ] || {
	echo "node_modules/playwright is missing; run inside the dev shell" >&2
	exit 2
}

# ---------------------------------------------------------------------------
# The tree under test.
# ---------------------------------------------------------------------------
bundle="${CT_WEB_BUNDLE_DIR:-}"
if [ -z "${bundle}" ]; then
	bundle="${cache}/bundle"
	echo "Assembling a publish tree (CT_WEB_BUNDLE_DIR unset)..."
	if ! CT_WEB_BUNDLE_DIR="${bundle}" bash ci/test/web-bundle-assets.sh \
		>"${cache}/assemble.log" 2>&1; then
		echo "  the tree did not assemble; see ${cache}/assemble.log" >&2
		tail -20 "${cache}/assemble.log" >&2
		exit 1
	fi
fi
worker_asset="${bundle}/assets/wasm-worker.js"
if [ ! -s "${worker_asset}" ]; then
	echo "no assets/wasm-worker.js in ${bundle}; there is nothing to session" >&2
	exit 1
fi
echo "  publish tree: ${bundle}"
echo "  worker asset: $(wc -c <"${worker_asset}" | tr -d ' ') bytes"
echo

# ---------------------------------------------------------------------------
# The harness bundle. Compiled from the SHIPPING modules; see the header.
# ---------------------------------------------------------------------------
echo "Compiling the harness (nim js, over host/web_browser + platform/wasm_worker)..."
if ! nim js --hints:off --warnings:off \
	--path:src/frontend/viewmodel \
	--nimcache:"${cache}/nimcache" \
	-o:"${cache}/session_harness.js" \
	ci/test/wasm_session_harness.nim >"${cache}/harness-build.log" 2>&1; then
	echo "  the harness did not compile; see ${cache}/harness-build.log" >&2
	tail -30 "${cache}/harness-build.log" >&2
	exit 1
fi
echo "  harness: $(wc -c <"${cache}/session_harness.js" | tr -d ' ') bytes"
echo

# ---------------------------------------------------------------------------
# A loopback static server, in one place so every arm is served identically.
# Port 0 lets the OS pick: a fixed port makes two arms race on a busy runner
# and produces a red arm that says nothing about the product.
# ---------------------------------------------------------------------------
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

server_pid=""
arm_dir=""
stop_server() {
	if [ -n "${server_pid}" ] && kill -0 "${server_pid}" 2>/dev/null; then
		kill "${server_pid}" 2>/dev/null
		wait "${server_pid}" 2>/dev/null
	fi
	server_pid=""
}
trap 'stop_server; [ -n "${arm_dir}" ] && drop "${arm_dir}"' EXIT

port=0
start_server() {
	rm -f "${cache}/port"
	python3 "${cache}/serve.py" "$1" >"${cache}/port" 2>"${cache}/server.log" &
	server_pid=$!
	local waited=0
	while [ ! -s "${cache}/port" ] && [ "${waited}" -lt 150 ]; do
		sleep 0.1
		waited=$((waited + 1))
	done
	port="$(head -1 "${cache}/port" 2>/dev/null | tr -d '[:space:]')"
	[ -n "${port}" ]
}

# `stage <dir>` — a copy of the publish tree with the harness beside it.
stage() {
	local dir="$1"
	[ -d "${dir}" ] && chmod -R u+w "${dir}" 2>/dev/null
	rm -rf "${dir}"
	mkdir -p "${dir}"
	cp -RL "${bundle}/." "${dir}/" 2>/dev/null
	# The tree carries files copied out of the nix store, which are read-only,
	# and `cp -R` preserves the mode. Without this an arm cannot patch the
	# worker and the cleanup cannot remove its own directory.
	chmod -R u+w "${dir}"
	mkdir -p "${dir}/__harness"
	cp ci/test/wasm_session_harness.html "${dir}/__harness/harness.html"
	cp "${cache}/session_harness.js" "${dir}/__harness/session_harness.js"
}

drop() {
	[ -d "$1" ] && chmod -R u+w "$1" 2>/dev/null
	rm -rf "$1"
}

# `mutate <file> <needle> <replacement>` — and FAIL if the needle was absent.
#
# A mutation arm whose premise has been removed by other work reports "could
# not be measured" forever while looking like coverage. One was caught doing
# exactly that in this repository today. So a pattern that matches nothing is
# a gate failure, not a silently vacuous arm.
mutate() {
	python3 - "$1" "$2" "$3" <<'PY'
import sys
path, needle, replacement = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
if needle not in text:
    sys.stderr.write(
        "MUTATION PATTERN NOT FOUND, so this arm would have been vacuous:\n"
        "  file:   %s\n  needle: %r\n" % (path, needle))
    sys.exit(1)
open(path, 'w').write(text.replace(needle, replacement, 1))
PY
}

# `probe <label> <dir> [query]` -> ${cache}/<label>.json
probe() {
	local label="$1" dir="$2" query="${3:-}"
	if ! start_server "${dir}"; then
		echo "  the static server did not start" >&2
		return 2
	fi
	local url="http://127.0.0.1:${port}/__harness/harness.html${query}"
	node ci/test/wasm_session_probe.mjs "${url}" 15000 \
		>"${cache}/${label}.json" 2>"${cache}/${label}.err"
	local rc=$?
	stop_server
	return ${rc}
}

j() { # `j <label> <jq-filter>`
	node -e '
const fs = require("fs");
const doc = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const path = process.argv[2].split(".");
let v = doc;
for (const p of path) { v = (v === null || v === undefined) ? undefined : v[p]; }
process.stdout.write(v === undefined ? "undefined" : JSON.stringify(v));
' "${cache}/$1.json" "$2" 2>/dev/null
}

acks_all() { # `acks_all <label> <true|false>` — are all 8 acknowledgements X?
	node -e '
const fs = require("fs");
const doc = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const want = process.argv[2] === "true";
const labels = ["sendBefore","register","sendAfter","burstStall","burstSend",
                "burstStatus","seal","status"];
const r = doc.report || {};
const got = labels.map((l) => r[l + "Ack"] === true);
process.stdout.write(JSON.stringify({
  total: labels.length,
  matching: got.filter((x) => x === want).length,
}));
' "${cache}/$1.json" "$2" 2>/dev/null
}

# ===========================================================================
# ARM C — the control. The unmutated tree must be green, or every arm below
# is red for a reason that has nothing to do with what it claims to measure.
# ===========================================================================
echo "Arm C — the control: a session over the assembled tree"
arm_dir="${cache}/arm-c"
stage "${arm_dir}"

# The tree is served UNMODIFIED, and that is asserted rather than assumed:
# every arm below patches a copy, and a gate that could not tell a patched
# tree from a clean one would be measuring its own edits.
if command -v shasum >/dev/null 2>&1; then
	orig_digest="$(shasum -a 256 "${worker_asset}" | cut -d' ' -f1)"
	copy_digest="$(shasum -a 256 "${arm_dir}/assets/wasm-worker.js" | cut -d' ' -f1)"
else
	orig_digest="$(sha256sum "${worker_asset}" | cut -d' ' -f1)"
	copy_digest="$(sha256sum "${arm_dir}/assets/wasm-worker.js" | cut -d' ' -f1)"
fi
ckeq "${orig_digest}" "${copy_digest}" "the worker served is byte-identical to the one the tree published"
note "sha256 ${orig_digest:0:16}"

probe c "${arm_dir}"
present="$(j c reportPresent)"
if [ "${present}" != "true" ]; then
	# NON-VACUITY, and it aborts rather than continuing: every assertion below
	# reads the report, and over `{}` they would all compare against
	# `undefined` and report a product defect for a harness that never ran.
	ck fail "the harness produced a report (non-vacuity guard)"
	note "$(head -30 "${cache}/c.json")"
	note "$(head -10 "${cache}/c.err")"
	expect_count 0
	exit 1
fi
ck ok "the harness produced a report (non-vacuity guard)"

ckeq "$(j c settled)" "true" "the harness ran to completion (it wrote done: true)"

# THE FIELD THAT MATTERS MOST. A harness that died on its first statement
# leaves an empty report, which is indistinguishable from a session that
# opened and said nothing unless somebody is listening for the throw.
page_errors="$(j c pageErrors.length)"
if [ "${page_errors}" = "0" ]; then
	ck ok "the tab threw nothing (0 page errors)"
else
	ck fail "the tab threw nothing — ${page_errors} page error(s)"
	note "$(j c pageErrors)"
fi

worker_200="$(node -e '
const doc = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const hit = (doc.workerRequests || []).find(
  (r) => r.url.endsWith("/assets/wasm-worker.js") && r.status === 200);
process.stdout.write(hit ? "true" : "false");
' "${cache}/c.json")"
ckeq "${worker_200}" "true" "the tab fetched /assets/wasm-worker.js from the publish tree"

# --- the session exists, and says so itself -------------------------------
ckeq "$(j c report.readyEvent)" "true" "the session announced itself — a handle is not evidence, this is"

# --- THE ROUND TRIP PAIR --------------------------------------------------
ckeq "$(j c report.sendRefusedBeforeRegister)" "true" "round trip 1: a tx against an unregistered contract is REFUSED"

ckeq "$(j c report.sendRefusalNamesEmptyRegistry)" "true" "and the refusal names an EMPTY registry, so it is about state"

ckeq "$(j c report.registerAccepted)" "true" "round trip 2: the contract registers"

ckeq "$(j c report.sendAcceptedAfterRegister)" "true" "ROUND TRIP 3: THE SAME TX IS ACCEPTED — state survived the gap"

ckeq "$(j c report.queuedAfterSend)" "1" "and it landed in the session's mempool (queued=1)"

# --- ordering under a long operation --------------------------------------
ckeq "$(j c report.serialCount)" "8" "all 8 messages were handled (the count itself, not 'some were')"

ckeq "$(j c report.serialsAreFifo)" "true" "every reply carries a strictly increasing handling serial"

ckeq "$(j c report.burstHandledInOrder)" "true" "THE BURST QUEUED: 3 messages in one turn, first one stalling 180ms, handled in order"

# The completion counter, over every reply. `serial` is stamped when a handler
# starts and `finished` when it emits, so equality on all eight is the
# statement "nothing ran while any of them was awaiting" — the property the
# per-session queue exists for, and the one a start stamp alone cannot see.
ckeq "$(j c report.handledSerially)" "true" "every message started and finished with nothing interleaved"

acks="$(acks_all c true)"
ckeq "${acks}" '{"total":8,"matching":8}' "all 8 deliveries were acknowledged as accepted"

# --- the state the session accumulated ------------------------------------
ckeq "$(j c report.statusHeight)" "1" "the session's height is 1 after one seal"

ckeq "$(j c report.statusSealed)" "2" "and it sealed BOTH transactions (2), not just the last one"

ckeq "$(j c report.statusContracts)" '["Counter"]' "and it still holds the contract registered five messages ago"

# A state root, not a count. A session that accepted its transactions and one
# that threw them away report the same HEIGHT; only a fold over every accepted
# operation tells them apart, so the assertion is that it MOVED off the FNV
# offset the session started from.
root="$(j c report.statusRoot)"
if [ "${root}" != '"811c9dc5"' ] &&
	printf '%s' "${root}" | grep -Eq '^"[0-9a-f]{8}"$'; then
	ck ok "the state root moved off its seed (${root}) — the ops were folded in"
else
	ck fail "the state root moved off its seed, got ${root}"
fi

ckeq "$(j c report.sealedNumber)" "1" "the explicit seal produced block 1"

ckeq "$(j c report.sessionStillActive)" "true" "and after all of it the session is STILL RUNNING"

# --- ended deliberately ---------------------------------------------------
ckeq "$(j c report.closeAck)" "true" "close is acknowledged"

ckeq "$(j c report.sessionExitCode)" "0" "the session exited 0 — finished, not killed"

ckeq "$(j c report.sessionSignalled)" "false" "and NOT signalled, which is what distinguishes close from terminate"

ckeq "$(j c report.afterCloseRefused)" "true" "a message sent after close is refused, not silently swallowed"

ckeq "$(j c report.afterCloseKind)" '"pkNotFound"' "and refused BY NAME (pkNotFound), so a caller can branch"
echo

# ===========================================================================
# ARM T — the clock. A node produces blocks whether or not anyone is asking.
# ===========================================================================
echo "Arm T — unsolicited output on a timer"
probe t "${arm_dir}" "?tick=120"
if [ "$(j t reportPresent)" != "true" ]; then
	ck fail "arm T produced a report (non-vacuity guard)"
	ck fail "the session emitted blocks nobody asked for"
	ck fail "and their numbers increase from 1"
else
	ck ok "arm T produced a report (non-vacuity guard)"
	ticked="$(j t report.tickCausedBlocks)"
	if [ "${ticked}" != "undefined" ] && [ "${ticked}" != "0" ]; then
		ck ok "the session emitted ${ticked} block(s) nobody asked for (cause=tick)"
	else
		ck fail "the session emitted blocks nobody asked for, got ${ticked}"
	fi
	increasing="$(node -e '
const doc = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const ns = (doc.report || {}).blockNumbers || [];
let ok = ns.length > 0 && ns[0] === 1;
for (let i = 1; i < ns.length; i += 1) if (ns[i] !== ns[i - 1] + 1) ok = false;
process.stdout.write(ok ? "true" : "false");
' "${cache}/t.json")"
	ckeq "${increasing}" "true" "and their numbers increase from 1 ($(j t report.blockNumbers))"
fi
echo

# ===========================================================================
# ARM V — backpressure. Not a mutation: a VARIANT, because the property is
# what a full inbox does, and the only way to see it is to have one.
#
# With the limit at 0 every delivery is refused. The assertion that matters is
# not that they are refused — it is that the SESSION IS STILL RUNNING
# afterwards. That is the entire reason an `input` carries its own sequence:
# on this protocol a `failed` FINISHES the run it names, so a refusal riding
# the session's sequence would destroy the session it was merely declining to
# accept, and backpressure would be indistinguishable from death.
# ===========================================================================
echo "Arm V — a full inbox refuses without killing the session"
arm_v="${cache}/arm-v"
stage "${arm_v}"
if ! mutate "${arm_v}/assets/wasm-worker.js" \
	'const SESSION_QUEUE_LIMIT = 64;' \
	'const SESSION_QUEUE_LIMIT = 0;'; then
	ck fail "arm V could set the queue limit to 0"
	ck fail "every delivery is refused"
	ck fail "and refused as pkQuotaExceeded — retryable, not fatal"
	ck fail "the session opened even so"
	ck fail "AND THE SESSION IS STILL RUNNING after 8 refusals"
else
	ck ok "arm V could set the queue limit to 0"
	probe v "${arm_v}"
	if [ "$(j v reportPresent)" != "true" ]; then
		ck fail "every delivery is refused"
		ck fail "and refused as pkQuotaExceeded — retryable, not fatal"
		ck fail "the session opened even so"
		ck fail "AND THE SESSION IS STILL RUNNING after 8 refusals"
	else
		vacks="$(acks_all v false)"
		ckeq "${vacks}" '{"total":8,"matching":8}' "every delivery is refused (8 of 8)"

		ckeq "$(j v report.sendBeforeAckKind)" '"pkQuotaExceeded"' "and refused as pkQuotaExceeded — retryable, not fatal"

		ckeq "$(j v report.readyEvent)" "true" "the session opened even so"

		ckeq "$(j v report.sessionStillActive)" "true" "AND THE SESSION IS STILL RUNNING after 8 refusals"
	fi
	drop "${arm_v}"
fi
echo

# ===========================================================================
# ARM I — the instrument, and the worker's own death.
#
# Two jobs in one arm because they are the same experiment. Pointing the
# harness at a worker script that is not served makes `new Worker(...)` fire
# `onerror`; `host/web_browser.newWorkerTransport` turns that into
# `{seq: 0, kind: "failed"}` — the only notice a page ever gets that its worker
# has died. `deliver` USED TO DROP IT, because sequence 0 is never in
# `pending` and the early return took it, so every outstanding run waited for
# the life of the tab. A one-shot compile is exposed to that for seconds; a
# session for as long as the page is open, which is why this arm exists here
# and not only in the unit suite.
#
# As an instrument check it answers the question a green control arm cannot:
# can this gate go red at all, or does the probe report success over anything?
# ===========================================================================
echo "Arm I — the instrument, and a worker that dies"
probe i "${arm_dir}" "?worker=/assets/there-is-no-such-worker.js"
if [ "$(j i reportPresent)" != "true" ]; then
	ck fail "arm I produced a report (the instrument still works)"
	ck fail "no session announced itself over a worker that does not exist"
	ck fail "THE WORKER'S DEATH REACHED THE RUN (signalled), rather than being dropped"
	ck fail "and the deliveries were refused rather than left hanging"
else
	ck ok "arm I produced a report (the instrument still works)"

	ckeq "$(j i report.readyEvent)" "false" "no session announced itself over a worker that does not exist"

	ckeq "$(j i report.sessionSignalled)" "true" "THE WORKER'S DEATH REACHED THE RUN (signalled), rather than being dropped"

	iacks="$(acks_all i false)"
	ckeq "${iacks}" '{"total":8,"matching":8}' "and the deliveries were refused rather than left hanging"
fi
echo

# ===========================================================================
# MUTATION ARMS. Each names ONE assertion it must redden and one it must
# leave green: a kill by another check is a miss, and an arm that reddens
# everything has not shown that the assertion written for it works.
# ===========================================================================
echo "Arm A — a registration that is not kept"
note "target: sendAcceptedAfterRegister goes RED, registerAccepted stays GREEN"
arm_a="${cache}/arm-a"
stage "${arm_a}"
if ! mutate "${arm_a}/assets/wasm-worker.js" \
	'state.contracts.push(name);' \
	'/* MUTATED: the registration is not kept */'; then
	ck fail "arm A's mutation applied (a pattern that matched nothing is vacuous)"
	ck fail "arm A reddens sendAcceptedAfterRegister"
	ck fail "arm A leaves registerAccepted green"
else
	ck ok "arm A's mutation applied (a pattern that matched nothing is vacuous)"
	probe a "${arm_a}"
	ckeq "$(j a report.sendAcceptedAfterRegister)" "false" "arm A reddens sendAcceptedAfterRegister"
	ckeq "$(j a report.registerAccepted)" "true" "arm A leaves registerAccepted green — forgot, not broke"
	drop "${arm_a}"
fi
echo

echo "Arm E — the session exits in the turn it opened (the state this replaces)"
note "target: every acknowledgement goes RED, readyEvent stays GREEN"
arm_e="${cache}/arm-e"
stage "${arm_e}"
if ! mutate "${arm_e}/assets/wasm-worker.js" \
	'      openSession(seq, sub, request);
      return;' \
	'      openSession(seq, sub, request);
      post({ seq, kind: '"'"'exit'"'"', exitCode: 0, signalled: false });
      return;'; then
	ck fail "arm E's mutation applied (a pattern that matched nothing is vacuous)"
	ck fail "arm E reddens every delivery acknowledgement"
	ck fail "arm E leaves readyEvent green"
else
	ck ok "arm E's mutation applied (a pattern that matched nothing is vacuous)"
	probe e "${arm_e}"
	eacks="$(acks_all e false)"
	ckeq "${eacks}" '{"total":8,"matching":8}' "arm E reddens every delivery acknowledgement (8 of 8 refused)"
	ckeq "$(j e report.readyEvent)" "true" "arm E leaves readyEvent green — started, said hello, was gone"
	drop "${arm_e}"
fi
echo

echo "Arm O — the per-session drain guard removed"
note "target: burstHandledInOrder goes RED, serialCount stays 8"
arm_o="${cache}/arm-o"
stage "${arm_o}"
if ! mutate "${arm_o}/assets/wasm-worker.js" \
	'  if (session.draining) return;' \
	'  if (false) return; /* MUTATED: no per-session serialisation */'; then
	ck fail "arm O's mutation applied (a pattern that matched nothing is vacuous)"
	ck fail "arm O reddens burstHandledInOrder"
	ck fail "arm O leaves serialCount at 8"
else
	ck ok "arm O's mutation applied (a pattern that matched nothing is vacuous)"
	probe o "${arm_o}"
	ckeq "$(j o report.burstHandledInOrder)" "false" "arm O reddens burstHandledInOrder (starts $(j o report.burstStallSerial)/$(j o report.burstSendSerial)/$(j o report.burstStatusSerial), finishes $(j o report.burstStallFinished)/$(j o report.burstSendFinished)/$(j o report.burstStatusFinished))"
	ckeq "$(j o report.serialCount)" "8" "arm O leaves serialCount at 8 — ordering, not delivery"
	drop "${arm_o}"
fi
echo

# ===========================================================================
printf '%d check(s), %d failure(s)\n' "${checks}" "${failures}"
# 27 in the control arm, 3 on the clock, 5 on backpressure, 4 on the
# instrument and the worker's death, and 3 per mutation arm. Written from a
# run; the first draft had it wrong by six, which is the ratchet doing its job
# before the arms it guards had a chance to rot.
expect_count 48
if [ "${failures}" -ne 0 ]; then
	printf '\nRESULT: FAILED\n'
	exit 1
fi
printf '\nRESULT: OK — a session opened, held state across round trips, and closed\n'
