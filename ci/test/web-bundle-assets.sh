#!/usr/bin/env bash
#
# web-bundle-assets.sh — assemble a web bundle and check it carries everything.
#
# WHY THIS EXISTS
# ---------------
# `ci/test/web-bundle-smoke.sh` builds `web_main.nim` and boots it, and its own
# header disclaims the rest: "`test_one_codebase_two_platforms` also asks that
# a pane added to one platform appear in the other. That needs the renderer".
# The renderer now builds for the web (`ci/test/renderer-browser-build.sh`), so
# the remaining question is DELIVERY: does a bundle actually carry the
# renderer, the worker script, and the two Noir wasm modules?
#
# NS3's residual is exactly that, and `host/web_browser.nim` states it in the
# code rather than in a plan. `newBrowserWasmHost(registry, scriptUrl)` is
# written and tested and nothing calls it, because "the worker script that
# instantiates the Noir modules and drives their `nv_*` / `ct_*` ABIs is not in
# the bundle". A sibling established that NS3 had moved from *nothing loads a
# module* to *nothing delivers one*. This gate is about the delivering.
#
# THE MANIFEST IS NOT IN THIS FILE, and that is the point. `webRuntimeAssets()`
# in `platform/web_deployment.nim` is the single declaration; it is compiled on
# both backends and asserted by `viewmodel/tests/unit/test_platform_web.nim`
# (which pins the delivery MODE of each asset, that every optional one states
# what its absence costs, and that no two claim the same path). This script
# reads it through `web_runtime_assets_manifest.nim` and places what it names.
# A hand-written list here would be the third copy and would drift from the
# other two — the shape `web_deployment.nim`'s header already records once.
#
# WHAT IS AND IS NOT CLAIMED. This assembles a bundle and checks its contents.
# It does not run the renderer in a browser, and it does not claim the Noir
# toolchain works in a tab — `ci/test/noir-wasm-worker-e2e.sh` is what compares
# a real trace out of the worker protocol against an in-process run, and this
# gate deliberately does not restate its result. What is new here is that the
# files that protocol needs are now placed where a tab can fetch them.
#
# THE TWO WASM MODULES ARE NOT IN THE REPO (~16 MB and ~4.6 MB, built from
# published refs in the `noir` fork). Point CT_NOIR_WASM_COMPILER and
# CT_NOIR_WASM_TRACER at them. WITHOUT THEM THIS SKIPS THAT PART LOUDLY AND
# STILL CHECKS EVERYTHING ELSE — the same convention `noir-wasm-worker-e2e.sh`
# established, and for the same reason: a gate that silently passes over an
# absent input is how a deployment ships with no modules and nobody notices.
#
# Usage:  bash ci/test/web-bundle-assets.sh
# Env:    CT_NOIR_WASM_COMPILER  path to noir_wasm.wasm            (optional)
#         CT_NOIR_WASM_TRACER    path to noir_tracer_wasm.wasm     (optional)
#         CT_WEB_BUNDLE_DIR      output dir (default src/build-debug/web)
#         ISONIM_SRC             isonim source tree

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

out_dir="${CT_WEB_BUNDLE_DIR:-${repo_root}/src/build-debug/web}"
cache="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}/web-bundle-assets"

checks=0
failures=0
skips=0
note() { printf '  %s\n' "$*"; }
ok() {
	checks=$((checks + 1))
	printf '  [OK]      %s\n' "$*"
}
bad() {
	checks=$((checks + 1))
	failures=$((failures + 1))
	printf '  [FAILED]  %s\n' "$*"
}
skip() {
	skips=$((skips + 1))
	printf '  [SKIPPED] %s\n' "$*"
}

echo "=== web bundle assets (NS3: nothing DELIVERS a module) ==="
echo

command -v nim >/dev/null 2>&1 || {
	echo "nim is not on PATH; run inside the dev shell" >&2
	exit 2
}

mkdir -p "${out_dir}" "${out_dir}/assets" "${cache}"

# ---------------------------------------------------------------------------
echo "Step 1: read the manifest from the product, not from this script"
# ---------------------------------------------------------------------------
if ! nim c --hints:off --warnings:off --nimcache:"${cache}/manifest" \
	-o:"${cache}/manifest-bin" ci/test/web_runtime_assets_manifest.nim >"${cache}/manifest.log" 2>&1; then
	echo "  the manifest program did not compile:" >&2
	grep -E 'Error:' "${cache}/manifest.log" | head -3 | sed 's/^/      /' >&2
	exit 1
fi
manifest="$("${cache}/manifest-bin")"
asset_count="$(printf '%s\n' "${manifest}" | grep -c .)"

# NON-VACUITY FIRST. An empty manifest satisfies every "each declared asset is
# present" loop below perfectly, and would read as a clean pass over a bundle
# containing nothing. This is the same trap as equal digests over two empty
# traces, and it is checked before anything reads the list.
if [ "${asset_count}" -ge 3 ]; then
	ok "the manifest declares ${asset_count} assets, so the loops below have subjects"
else
	bad "the manifest declares only ${asset_count} asset(s) — every per-asset check below would be vacuous"
	echo "RESULT: FAILED"
	exit 1
fi
printf '%s\n' "${manifest}" | while IFS=$'\t' read -r id path mode req _; do
	note "manifest: ${id}  ->  ${path}  (${mode}, ${req})"
done
echo

# EVERY DECLARED ASSET IS REMOVED BEFORE ANYTHING IS PLACED, and this is not
# tidiness — a gate without it reports on the union of this run and every run
# before it.
#
# Found by mutation, not by review: marking an absent wasm module `required`
# should fail step 4, and it did not, because a PREVIOUS run of this script had
# left a copy of that module in the output directory. The check read "required
# and present" over a file this assembly never produced. That is the same
# silent-success shape as a lane that skips its subject: the number is right
# and it is measuring the wrong thing.
#
# Only the paths the manifest declares are removed. The output directory is
# shared with `web-bundle-smoke.sh`, so a blanket `rm -rf` here would delete
# another gate's artefacts.
while IFS=$'\t' read -r _id _path _mode _req _behaviour; do
	[ -n "${_path}" ] || continue
	rm -f "${out_dir}/${_path}"
done < <(printf '%s\n' "${manifest}")

# ---------------------------------------------------------------------------
echo "Step 2: build the two bundled entry points"
echo "    The renderer is the one that was impossible until now: its import"
echo "    graph reached lib/electron_lib.nim, which is {.error.} under -d:ctWeb."
# ---------------------------------------------------------------------------
build() {
	local label="$1" target="$2" out="$3"
	shift 3
	local log
	log="$(nim js --hints:off --warnings:off "$@" \
		--nimcache:"${cache}/${label}" -o:"${out}" "${target}" 2>&1)"
	if [ $? -ne 0 ] || [ ! -f "${out}" ]; then
		bad "${label}: did not build"
		printf '%s\n' "${log}" | grep -E 'Error:' | head -3 | sed 's/^/      /'
		return 1
	fi
	ok "${label}: built ($(wc -c <"${out}" | tr -d ' ') bytes)"
	return 0
}
build renderer src/frontend/ui_js.nim "${out_dir}/ui.js" \
	-d:chronicles_enabled=off -d:ctRenderer -d:ctWeb
# NO `-d:nodejs`, and that is a correction rather than a tidy-up. This script
# assembles the bundle that gets DEPLOYED, and `-d:nodejs` selects Nim's node
# arm — the same define `ci/test/renderer-browser-build.sh` proves the renderer
# cannot even compile under, and which `web-bundle-smoke.sh` passes for the one
# legitimate reason that it then runs the result under `node`. Assembling the
# shipped bundle with it meant the file uploaded to a CDN was a node build that
# happened to contain no `require(`. The renderer arm beside it has always been
# `js-browser`; this makes the pair agree.
build web-entry src/frontend/web_main.nim "${out_dir}/web.js" \
	-d:ctWeb --path:src/frontend/viewmodel
echo

# ---------------------------------------------------------------------------
echo "Step 3: place the worker script and, if supplied, the wasm modules"
# ---------------------------------------------------------------------------
worker_src="src/frontend/viewmodel/host/wasm_worker_browser.js"
worker_dst="${out_dir}/$(printf '%s\n' "${manifest}" | awk -F'\t' '$1=="wasm-worker"{print $2}')"
mkdir -p "$(dirname "${worker_dst}")"
if cp "${worker_src}" "${worker_dst}" 2>/dev/null; then
	ok "worker script placed at ${worker_dst#"${out_dir}"/}"
else
	bad "could not place the worker script from ${worker_src}"
fi

place_module() {
	local var="$1" id="$2"
	local src="${!var:-}"
	local dst
	dst="${out_dir}/$(printf '%s\n' "${manifest}" | awk -F'\t' -v i="${id}" '$1==i{print $2}')"
	if [ -z "${src}" ]; then
		# The absence sentence is READ FROM THE MANIFEST rather than written
		# here, so a skip cannot claim a degradation the product does not
		# declare.
		local behaviour
		behaviour="$(printf '%s\n' "${manifest}" | awk -F'\t' -v i="${id}" '$1==i{print $5}')"
		skip "${id}: ${var} is not set. Declared consequence: ${behaviour}"
		return 1
	fi
	if [ ! -f "${src}" ]; then
		bad "${id}: ${var} points at ${src}, which does not exist"
		return 1
	fi
	mkdir -p "$(dirname "${dst}")"
	cp "${src}" "${dst}"
	ok "${id}: placed $(wc -c <"${dst}" | tr -d ' ') bytes at ${dst#"${out_dir}"/}"
	return 0
}
place_module CT_NOIR_WASM_COMPILER noir-compiler
place_module CT_NOIR_WASM_TRACER noir-tracer
echo

# ---------------------------------------------------------------------------
echo "Step 3b: render the entry document and the host configuration"
echo "    The asset nothing produced. renderRewriteConfig() has always emitted"
echo "    '/index.html' as the target of every prefix, and no step ever made"
echo "    such a file -- so a deployment would have served the rewrites and"
echo "    404'd every one of them. The document also CARRIES the descriptor of"
echo "    what this assembly actually placed, measured from the files on disk,"
echo "    which is what the page reads instead of making a request."
# ---------------------------------------------------------------------------
origin="${CT_WEB_ORIGIN:-https://ide.codetracer.com}"
revision="${CT_WEB_REVISION:-$(git -C "${repo_root}" rev-parse --short HEAD 2>/dev/null || echo unknown)}"

# The provenance strings. Read from the environment because only the caller
# that BUILT the modules knows which `noir` ref they came from, and a module
# that cannot say where it came from is dropped by `registrableModules` — so
# an unset value here disables the module rather than shipping it anonymously.
noir_ref="${CT_NOIR_WASM_REF:-}"

modules_tsv="${cache}/declared-modules.tsv"
: >"${modules_tsv}"
declare_module() {
	local id="$1" crate="$2"
	local path
	path="$(printf '%s\n' "${manifest}" | awk -F'\t' -v i="${id}" '$1==i{print $2}')"
	local file="${out_dir}/${path}"
	# MEASURED FROM THE FILE, never from the variable that was supposed to
	# produce it. This is the "verify the artifact, not the workflow" rule at
	# its smallest: the document declares a size a guard can compare against
	# the bytes about to be uploaded, so a truncated copy is a failed deploy
	# rather than a broken page.
	[ -f "${file}" ] || return 0
	if [ -z "${noir_ref}" ]; then
		bad "${id}: placed, but CT_NOIR_WASM_REF is unset, so it has no provenance and the page would drop it"
		return 0
	fi
	printf '%s\t/%s\t%s\t%s\n' "${id}" "${path}" \
		"$(wc -c <"${file}" | tr -d ' ')" \
		"noir@codetracer ${noir_ref} ${crate}" >>"${modules_tsv}"
}
declare_module noir-compiler "compiler/wasm"
declare_module noir-tracer "tooling/tracer_wasm"

if ! nim c --hints:off --warnings:off --nimcache:"${cache}/render" \
	-o:"${cache}/render-bin" ci/test/web_deployment_render.nim \
	>"${cache}/render.log" 2>&1; then
	bad "the deployment renderer did not compile"
	grep -E 'Error:' "${cache}/render.log" | head -3 | sed 's/^/      /'
else
	if "${cache}/render-bin" "${origin}" "${revision}" "${out_dir}" \
		<"${modules_tsv}" >"${cache}/render-out.log" 2>&1; then
		ok "rendered index.html, _headers and _redirects for ${origin} @ ${revision}"
		sed 's/^/      /' "${cache}/render-out.log"
	else
		bad "the deployment renderer failed"
		sed 's/^/      /' "${cache}/render-out.log"
	fi
fi
echo

# ---------------------------------------------------------------------------
echo "Step 4: every REQUIRED asset is present and non-trivial"
echo "    Size matters as much as presence: a zero-byte ui.js satisfies"
echo "    'the bundle carries the renderer' and carries nothing."
# ---------------------------------------------------------------------------
while IFS=$'\t' read -r id path mode req behaviour; do
	[ -n "${id}" ] || continue
	target="${out_dir}/${path}"
	if [ "${req}" = "required" ]; then
		if [ ! -f "${target}" ]; then
			bad "${id}: REQUIRED and absent from the bundle (${path})"
			continue
		fi
		size="$(wc -c <"${target}" | tr -d ' ')"
		# 1 KB is far below any real value here (the renderer is ~13 MB, the
		# worker ~7 KB) and far above a truncated or empty file.
		if [ "${size}" -gt 1024 ]; then
			ok "${id}: present, ${size} bytes"
		else
			bad "${id}: present but only ${size} bytes — truncated or empty"
		fi
	else
		if [ -f "${target}" ]; then
			ok "${id}: optional and present, $(wc -c <"${target}" | tr -d ' ') bytes"
		else
			# NOT a failure, and not silence either: the manifest's own
			# sentence is what a user would read.
			note "${id}: optional and absent — ${behaviour}"
		fi
	fi
done < <(printf '%s\n' "${manifest}")
echo

# ---------------------------------------------------------------------------
echo "Step 5: the placed worker speaks the protocol wasm_worker.nim defines"
echo "    A file of the right NAME at the right PATH is what a copy step"
echo "    guarantees. That it is the worker, and not some other script, is a"
echo "    different claim and needs a different check."
# ---------------------------------------------------------------------------
if [ -f "${worker_dst}" ]; then
	# EVERY GREP IN THIS STEP READS THE CODE, NOT THE PROSE.
	#
	# `ci/test/renderer-host-reach-budget.sh` learned this and wrote it down:
	# "Comment lines are dropped BEFORE counting: this file's own prose quotes
	# `require('fs')` several times, and a rule that counted its own
	# documentation would grow every time someone explained it." The worker
	# script is the same case in both directions — it explains how it differs
	# from the node twin, naming `parentPort` and `readFileSync`, which made
	# the forbidden-token checks below fail on a perfectly good file; and a
	# positive check satisfied by a token that appears ONLY in a comment would
	# be worse, because it would pass over a worker that had lost the call.
	#
	# So the comments come out once, here, and every assertion reads the
	# result. Whole-line `//` comments only: a trailing comment cannot
	# introduce a forbidden token without the line also containing code.
	worker_code="${cache}/worker-code.js"
	grep -vE '^[[:space:]]*//' "${worker_dst}" >"${worker_code}"

	# IT PARSES. This is the first thing asserted about it and it is the whole
	# reason this repository keeps finding the same defect: `host/web_browser
	# .nim` reached `dev` unparseable and sat there for days because three
	# individually correct decisions left it compiled by nothing, and the
	# renderer entry point did the same this week. A hand-written `.js` file is
	# the easiest possible instance — no lane compiles JavaScript — so a
	# syntax error in the worker would otherwise be found by a user's browser.
	#
	# Every grep below is satisfied by a file that happens to CONTAIN the right
	# words, whether or not it is a program. `node --check` is what makes them
	# checks about a worker rather than about a text file.
	if node --check "${worker_dst}" 2>"${cache}/worker-parse.log"; then
		ok "the worker script parses as JavaScript"
	else
		bad "the worker script does NOT parse; a browser would fail on its first line"
		head -5 "${cache}/worker-parse.log" | sed 's/^/      /'
	fi

	# Positive control on the STRIPPED file first, so the greps below cannot
	# pass over an empty or wrong file by finding nothing in it — and so a
	# stripping bug that emptied the file is caught here rather than read as
	# nineteen clean passes.
	if grep -q "self.onmessage" "${worker_code}"; then
		ok "positive control: the placed file installs a worker message handler"
	else
		bad "positive control FAILED: the placed file is not a worker script; every check below is vacuous"
	fi

	# The four message kinds the Nim side's `deliver` parses. `wasm_worker.nim`
	# resolves a run ONLY on `exit` or `failed`, so a worker that could not
	# emit those would leave every run unsettled — the "chain of agreements"
	# failure its header names.
	for kind in "'configure'" "'start'" "kind: 'exit'" "kind: 'failed'" "kind: 'output'"; do
		if grep -qF "${kind}" "${worker_code}"; then
			ok "the worker handles/emits ${kind}"
		else
			bad "the worker never mentions ${kind}; wasm_worker.nim's protocol needs it"
		fi
	done

	# The bare C ABIs. These are the entry points the published modules export;
	# a worker that lost one would fail at run time in a browser and nowhere
	# earlier.
	for sym in nv_compile_vfs nv_alloc ct_trace ct_alloc ct_result_is_error; do
		if grep -qF "${sym}" "${worker_code}"; then
			ok "the worker drives ${sym}"
		else
			bad "the worker does not reference ${sym}"
		fi
	done

	# It must not be the NODE twin. `ci/test/noir-wasm-worker/worker.mjs` is
	# the same protocol over `node:worker_threads` and `readFileSync`, and
	# copying THAT into a web bundle would produce a worker that throws on its
	# first line in a browser — while satisfying every check above.
	for forbidden in "node:worker_threads" "node:fs" "parentPort" "readFileSync"; do
		if grep -qF "${forbidden}" "${worker_code}"; then
			bad "the placed worker uses ${forbidden}; that is the node twin, not the browser one"
		else
			ok "the worker does not use ${forbidden}"
		fi
	done

	# And it must fetch, because that is the delivery decision the manifest
	# records for the two modules.
	if grep -qF "fetch(" "${worker_code}"; then
		ok "the worker fetches its modules rather than embedding them"
	else
		bad "the worker never calls fetch(); the manifest declares the modules 'fetched'"
	fi
else
	bad "no worker script was placed, so the protocol checks cannot run"
fi
echo

# ---------------------------------------------------------------------------
echo "Step 6: the worker's module ids are the manifest's module ids"
echo "    A rename on one side produces 'no url declared for wasm module' in a"
echo "    browser and nothing at all before that."
# ---------------------------------------------------------------------------
if [ -f "${worker_code:-/nonexistent}" ]; then
	while IFS=$'\t' read -r id path mode req behaviour; do
		[ "${mode}" = "fetched" ] || continue
		if grep -qF "load('${id}')" "${worker_code}"; then
			ok "the worker resolves '${id}', the id the manifest declares"
		else
			bad "the manifest declares fetched module '${id}' and the worker never loads it"
		fi
	done < <(printf '%s\n' "${manifest}")
fi
echo

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
echo "Step 7: the deploy guard runs on the tree this script just assembled"
echo "    Not because a local bundle is about to be published, but because"
echo "    otherwise NOTHING COMPILES web_deploy_guard.nim except the deploy"
echo "    workflow -- and a Nim file no lane compiles is this repository's"
echo "    signature defect: host/web_browser.nim sat unparseable on dev for"
echo "    days, and the renderer entry point did the same this week. A guard"
echo "    that is only built at deploy time fails FOR THE FIRST TIME during a"
echo "    deploy, which is the worst possible moment to discover it."
echo
echo "    It also means every push exercises the guard against a real,"
echo "    correct publish directory -- so the 'a legitimate bundle is"
echo "    rejected' failure mode is caught here rather than by whoever is"
echo "    deploying."
# ---------------------------------------------------------------------------
if ! nim c --hints:off --warnings:off --nimcache:"${cache}/guard" \
	-o:"${cache}/guard-bin" ci/test/web_deploy_guard.nim \
	>"${cache}/guard-build.log" 2>&1; then
	bad "ci/test/web_deploy_guard.nim does not compile"
	grep -E 'Error:' "${cache}/guard-build.log" | head -3 | sed 's/^/      /'
else
	ok "the deploy guard compiles"
	if "${cache}/guard-bin" "${out_dir}" >"${cache}/guard-run.log" 2>&1; then
		ok "and it accepts the bundle this script assembled"
		sed 's/^/      /' "${cache}/guard-run.log"
	else
		bad "the deploy guard REJECTS the bundle this script just assembled"
		sed 's/^/      /' "${cache}/guard-run.log"
	fi
fi
echo

# ---------------------------------------------------------------------------
echo "${checks} check(s), ${failures} failure(s), ${skips} skipped"
if [ "${checks}" -eq 0 ]; then
	echo "RESULT: FAILED — the gate asserted nothing"
	exit 1
fi
if [ "${skips}" -gt 0 ]; then
	echo "NOTE: ${skips} wasm module(s) were not supplied, so their PLACEMENT is"
	echo "      unproven here. Everything else — the renderer, the entry point and"
	echo "      the worker script — was assembled and checked."
fi
if [ "${failures}" -eq 0 ]; then
	echo "RESULT: OK — the bundle carries the renderer, the entry point and the worker"
	exit 0
fi
echo "RESULT: FAILED — ${failures} check(s)"
exit 1
