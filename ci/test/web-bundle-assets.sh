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
# THE THREE WASM MODULES ARE NOT IN THE REPO (~16 MB and ~4.6 MB from published
# refs in the `noir` fork; ~5.2 MB from `aztec-avm-runtime`'s
# `avm-transpiler-wasm`, which wraps Aztec's own transpiler). Point
# CT_NOIR_WASM_COMPILER, CT_NOIR_WASM_TRACER and CT_AVM_TRANSPILER_WASM at
# them. WITHOUT THEM THIS SKIPS THAT PART LOUDLY AND
# STILL CHECKS EVERYTHING ELSE — the same convention `noir-wasm-worker-e2e.sh`
# established, and for the same reason: a gate that silently passes over an
# absent input is how a deployment ships with no modules and nobody notices.
#
# Usage:  bash ci/test/web-bundle-assets.sh
# Env:    CT_NOIR_WASM_COMPILER  path to noir_wasm.wasm            (optional)
#         CT_NOIR_WASM_TRACER    path to noir_tracer_wasm.wasm     (optional)
#         CT_REPLAY_ENGINE_DIR   a wasm-pack `pkg/` holding db_backend.js
#                                and db_backend_bg.wasm             (optional)
#         CT_AVM_TRANSPILER_WASM path to avm_transpiler_wasm.wasm  (optional)
#         CT_NOIR_WASM_REF       the `noir` rev the first two came from
#         CT_AVM_TRANSPILER_REF  the rev the transpiler came from
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
#
# AND EVERY DIGESTED SPELLING OF THEM, which is what content-addressed names
# cost this loop. `rm -f "${out_dir}/assets/noir_wasm.wasm"` deletes a name no
# assembly has published since the rename landed: it succeeds, against nothing,
# and the loop reads as if it had run.
#
# The gap it leaves is precisely the bug this loop's header records, reached by
# a different route. An OPTIONAL module supplied on one run and not the next —
# `CT_NOIR_WASM_COMPILER` unset, which is the ordinary local case and the
# workflow's cache-miss path — is never placed, so the per-asset sweep inside
# Step 3a is skipped for it by `[ -f "${src}" ] || continue`, and the previous
# run's `assets/noir_wasm.<olddigest>.wasm` survives. `published_asset_rel`
# then finds EXACTLY ONE match and resolves it without complaint, so the
# browser gates grade bytes this assembly never placed. That is "required and
# present over a module it had never produced" again, wearing a digest.
#
# Removed here, before anything is placed, rather than beside the rename: this
# is the only point that sees every declared asset whether or not this run has
# one. Step 3a therefore no longer needs its own sweep.
while IFS=$'\t' read -r _id _path _mode _req _behaviour; do
	[ -n "${_path}" ] || continue
	rm -f "${out_dir}/${_path}"
	_dir="$(dirname "${out_dir}/${_path}")"
	_base="$(basename "${_path}")"
	[ -d "${_dir}" ] || continue
	find "${_dir}" -maxdepth 1 -name "${_base%.*}.*.${_base##*.}" -delete 2>/dev/null
done < <(printf '%s\n' "${manifest}")

# AND ONE PATH THE MANIFEST NO LONGER DECLARES. `web.js` was a required asset
# until NS9 merged the two Nim bundles; a tree assembled by an older revision
# of this script still has one, and the loop above stopped removing it the
# moment it left `webRuntimeAssets()`. Left in place it would be an unreferenced
# 1 MB file that no document loads and no check looks at — "an asset nothing
# can reach", which is the exact state the deploy guard exists to catch and
# which this script would otherwise have manufactured itself.
rm -f "${out_dir}/web.js"

# ---------------------------------------------------------------------------
echo "Step 2: build the renderer, which is the only Nim bundle a page loads"
echo "    It was impossible until recently: its import graph reached"
echo "    lib/electron_lib.nim, which is {.error.} under -d:ctWeb. It now also"
echo "    carries the boot sequence that used to live in a second bundle."
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
# THERE IS NO SECOND NIM BUNDLE ANY MORE, and its removal is NS9.
#
# This script used to build `src/frontend/web_main.nim` into `${out_dir}/web.js`
# and the entry document used to load it first. It was the "loop arm": it
# called `boot()`, which installs the platform. The renderer could not see what
# it installed, and the reason was structural — `installPlatform` writes a
# module-level `var` in `viewmodel/platform/platform.nim`, `nim js` gives each
# compiled program its own, and the IIFE step below (which is load-bearing, see
# its header) is precisely what guaranteed the two could never meet. So every
# `ctPlatform()` in the renderer returned the refusing `uninstalledProfile`,
# and the ~19 MB of Noir compiler step 3 places had no reachable caller.
#
# Measured on the pair this replaced, which is the shortest statement of the
# defect available:
#
#     web.js   contains installPlatform__viewmodelZplatformZplatform_u99
#     ui.js    contains no installPlatform AT ALL — the symbol was eliminated
#              as dead code, because nothing in the renderer could install one
#
# `ui_js.nim`'s web arm now calls `boot()` itself, in the same program, so the
# `installedPlatform` the renderer reads is the one `boot()` wrote.
#
# IT IS ALSO SMALLER, which is the measurement that settled the choice between
# merging and bridging:
#
#     before   ui.js 14,616,358 + web.js 1,029,682 = 15,646,040 bytes
#     after    ui.js 15,265,622                    = 15,265,622 bytes
#     delta                                          -380,418 bytes
#
# The shared runtime — the 196 functions and 85 type tables the IIFEs existed
# to keep apart — is emitted once instead of twice, and that saves more than
# the loop arm's own modules cost.
#
# `web_main.nim` still compiles and is still tested: `ci/test/web-bundle-smoke.sh`
# builds it with `-d:nodejs -d:ctWeb` and runs it under node, which drives
# §4.2's third row without a browser. It builds its OWN copy and does not read
# this directory, so nothing here needs to produce one. What changed is that no
# deployment carries it.

# -----------------------------------------------------------------------
# SCOPE THE NIM BUNDLE. It shares a page with the third-party bundle, and
# until this step it shared its GLOBAL SCOPE, which is not a style question.
#
# `nim js` emits its whole program as top-level `var`s and `function`
# declarations. Two independently compiled bundles therefore collide on
# every runtime symbol they have in common. Counted on the deployed pair:
#
#     196 top-level function names   (parseJson__pureZjson_*, nimCopy,
#                                     raiseException, chckIndx, ...)
#      85 top-level var names        (NTI* type tables, ConstSet*)
#
# `ui.js` loads second, so it redefined `web.js`'s runtime under it. The
# loop arm's `boot()` is async and continues AFTER that point, so it
# resumed into a foreign runtime and died:
#
#     field 'elems' is not accessible for type 'JsonNodeObj' using
#     'kind = JArray'   at web_browser.deploymentDescriptor
#
# This was latent, not absent, on the deployed page: `ui.js` was throwing
# during module init before it reached the declarations that clobbered the
# type tables, so the loop arm survived by being lucky about WHERE the
# renderer crashed. Fixing the renderer is what would have exposed it, and
# it reproduces exactly that way — the mutation arm in
# `ci/test/web-renderer-mounts.sh` is this, unwrapped.
#
# An IIFE is the whole fix and is applied here rather than in the compiler
# invocation because `nim js` has no option for it. `type="module"` in the
# document was measured as the alternative and is NOT usable: module code
# is strict, and `ui.js` is then a `SyntaxError` ("Identifier 'debugRepl'
# has already been declared").
#
# WHAT IT COSTS, stated because it is a real loss: `{.exportc.}` procs meant
# to be called from a devtools console (`debugCT`, `debugRepl`, `readLog`)
# are no longer reachable from the global scope in the WEB build. The
# desktop and dev-server builds are untouched — they load one Nim bundle and
# this step does not run for them.
#
# WHAT IT DID NOT FIX, AND WHAT DID. This header used to end: "the two arms
# still cannot share Nim state, so the renderer cannot see the platform,
# project store or wasm registry that `web.js` booted. That is one bundle's
# worth of work and it is NS9's, not this script's."
#
# That work is done, and it was one bundle's worth almost literally — see the
# block above `scope_bundle`'s caller. There is one Nim program now, so there
# is no cross-bundle state to share and nothing for the IIFE to protect
# against. It is kept anyway, for the narrower reason a wrapper is still worth
# having: a bundle declaring ~280 top-level names should not put them on
# `window` beside the third-party bundle's.
scope_bundle() {
	local label="$1" file="$2"
	if head -c 12 "${file}" | grep -q '^(function()'; then
		ok "${label}: already scoped"
		return
	fi
	local tmp="${cache}/$(basename "${file}").scoped"
	{
		printf '(function(){\n'
		cat "${file}"
		printf '\n})();\n'
	} >"${tmp}"
	mv "${tmp}" "${file}"
	# PARSED, not just written. A wrapper that unbalanced the file would
	# produce a bundle that is 40 bytes larger and completely dead, and
	# every size check in this script would still pass it.
	if node --check "${file}" 2>/dev/null; then
		ok "${label}: scoped in an IIFE and still parses"
	else
		bad "${label}: the IIFE wrapper left a file that does not parse"
	fi
}
scope_bundle renderer "${out_dir}/ui.js"

# The storybook harness must not reach the deployed bundle.
#
# `src/frontend/storybook_components.nim` carries test-only instrumentation —
# `storyBackendCommands()`, which hands out the commands a mounted story's
# MockBackendService recorded. It exists so a real-Chromium check
# (`ci/test/low_level_code_row_click_probe.mjs`) can assert what a click on the
# SHIPPED web render arm actually asked the backend for, which the headless
# suites cannot: they drive `renderInstructionRowMock` while the bundle renders
# `renderInstructionRowWeb`.
#
# That is a legitimate dev-harness affordance and an illegitimate thing to
# ship: it names a mock backend, and anything importing the harness for
# convenience would drag the fixtures in with it. The line to hold is not "do
# not write instrumentation" but "instrumentation does not reach users", and
# that line is only real if something checks it.
for harness_sym in "storyBackendCommands" "mountCodeTracerStory"; do
	if grep -qF "${harness_sym}" "${out_dir}/ui.js"; then
		bad "ui.js contains ${harness_sym}: the storybook harness reached the deployed bundle"
	else
		ok "ui.js does not contain ${harness_sym} (storybook harness stays out of the bundle)"
	fi
done
echo

# ---------------------------------------------------------------------------
echo "Step 2b: the third-party bundle, the theme, and the renderer's own tree"
echo "    The assets whose ABSENCE is why a correct-looking deployment painted"
echo "    nothing. \`ui.js\` reads \`monaco\` at module scope; without the webpack"
echo "    bundle it raises ReferenceError during module init and stops."
# ---------------------------------------------------------------------------
# PRODUCTION MODE, and the reason is a hard limit rather than a preference.
# `webpack.config.js` is `mode: 'development'` for the desktop, which is right
# there — it keeps the build at ~9s and the debugger useful. It emits a 48 MB
# `frontend_bundle.js`, and Cloudflare Pages refuses any file over 25 MB, so
# the development bundle CANNOT be deployed at all. Production mode is 13.1 MB
# (27 MB for the whole output tree, 247 files) and costs ~67s.
#
# The overrides are passed on the command line rather than written into
# `webpack.config.js`, so the desktop build this script does not own keeps the
# devtool decision its own header spends forty lines justifying.
if [ ! -x node_modules/.bin/webpack ]; then
	bad "node_modules/.bin/webpack is missing; the third-party bundle cannot be built"
else
	dist_dir="${cache}/third-party-dist"
	rm -rf "${dist_dir}"
	if node node_modules/.bin/webpack --mode production --devtool false \
		--output-path "${dist_dir}" >"${cache}/webpack.log" 2>&1 &&
		[ -s "${dist_dir}/frontend_bundle.js" ]; then
		# Removed WHOLE, not overwritten. Webpack names its chunks by content
		# hash, so a rebuild leaves the previous run's chunks in place and the
		# directory grows a set of files no document references — the same
		# "an asset nothing can reach" state the deploy guard exists to catch,
		# manufactured by the assembly step itself.
		rm -rf "${out_dir}/public/dist"
		mkdir -p "${out_dir}/public/dist"
		cp -R "${dist_dir}/." "${out_dir}/public/dist/"
		ok "third-party bundle built ($(wc -c <"${dist_dir}/frontend_bundle.js" | tr -d ' ') bytes)"
	else
		bad "the third-party bundle did not build"
		tail -5 "${cache}/webpack.log" | sed 's/^/      /'
	fi
fi

# THE THEME IS COMPILED, NOT COPIED. `src/frontend/styles/*.css` is generated
# from stylus by tup and is gitignored, so a checkout has the `.styl` and not
# the `.css`. A deployment step that copied would work on a developer's tree
# with a stale build directory and fail in CI, which is the worse of the two
# orders to discover it in.
if [ ! -x node_modules/.bin/stylus ]; then
	bad "node_modules/.bin/stylus is missing; the theme cannot be compiled"
else
	mkdir -p "${out_dir}/frontend/styles"
	for sheet in default_dark_theme_electron loader; do
		if node node_modules/.bin/stylus -p "src/frontend/styles/${sheet}.styl" \
			>"${out_dir}/frontend/styles/${sheet}.css" 2>"${cache}/stylus-${sheet}.log" &&
			[ -s "${out_dir}/frontend/styles/${sheet}.css" ]; then
			ok "compiled ${sheet}.css ($(wc -c <"${out_dir}/frontend/styles/${sheet}.css" | tr -d ' ') bytes)"
		else
			bad "${sheet}.styl did not compile"
			head -3 "${cache}/stylus-${sheet}.log" | sed 's/^/      /'
		fi
	done
fi

# The trees the compiled theme and the renderer resolve BY RELATIVE PATH.
# Each one was a 404 on the first assembled page, found by loading it rather
# than by reading it: the theme's `@font-face` rules reach
# `../../libs/codetracer-design-system/...`, and the welcome screen requests
# `public/resources/shared/codetracer_welcome_logo.svg`. A page that renders
# with no fonts and no logo is not a mounted product.
#
# golden-layout's CSS comes from `node_modules` because
# `src/public/third_party/golden-layout/dist` is an EMPTY directory in a
# checkout — tup populates it for the desktop build and this script cannot
# assume tup ran.
place_tree() {
	local label="$1" src="$2" dst="$3"
	if [ ! -e "${src}" ]; then
		bad "${label}: ${src} is not in the checkout"
		return
	fi
	mkdir -p "$(dirname "${dst}")"
	rm -rf "${dst}"
	cp -RL "${src}" "${dst}" 2>/dev/null || cp -R "${src}" "${dst}"
	ok "${label}: placed $(find "${dst}" -type f | wc -l | tr -d ' ') file(s)"
}
place_tree design-system libs/codetracer-design-system \
	"${out_dir}/libs/codetracer-design-system"
place_tree renderer-resources src/public/resources "${out_dir}/public/resources"
place_tree golden-layout-css node_modules/golden-layout/dist/css \
	"${out_dir}/public/third_party/golden-layout/dist/css"
mkdir -p "${out_dir}/public/third_party"
for f in font-awesome.min.css vex.css vex-theme-os.css jstree_default.css \
	nouislider.css devicon-base.css jstree.min.js; do
	if cp "src/public/third_party/${f}" "${out_dir}/public/third_party/${f}" 2>/dev/null; then
		ok "third-party: ${f}"
	else
		bad "third-party: src/public/third_party/${f} is missing"
	fi
done
place_tree bootstrap src/public/third_party/bootstrap-4.3.1-dist \
	"${out_dir}/public/third_party/bootstrap-4.3.1-dist"
echo

# ---------------------------------------------------------------------------
echo "Step 3: place the worker script and, if supplied, the wasm modules"
# ---------------------------------------------------------------------------
worker_src="src/frontend/viewmodel/host/wasm_worker_browser.js"
worker_stem="$(printf '%s\n' "${manifest}" | awk -F'\t' '$1=="wasm-worker"{print $2}')"
worker_dst="${out_dir}/${worker_stem}"
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

# THE REPLAY ENGINE. Same shape as the Noir modules and for the same reason:
# the bytes come from a build this script does not run, so it takes them from
# the environment and says loudly when they are not there. `CT_REPLAY_ENGINE_DIR`
# points at a `pkg/` directory of the shape `wasm-pack --target web` writes and
# `browser-replay/build-dist.sh` copies from — the two files are named there,
# not here, because a name spelled twice drifts once.
if [ -n "${CT_REPLAY_ENGINE_DIR:-}" ]; then
	CT_REPLAY_ENGINE_GLUE="${CT_REPLAY_ENGINE_DIR}/db_backend.js"
	CT_REPLAY_ENGINE_WASM="${CT_REPLAY_ENGINE_DIR}/db_backend_bg.wasm"
	export CT_REPLAY_ENGINE_GLUE CT_REPLAY_ENGINE_WASM
fi
# BOTH OR NEITHER, asserted rather than hoped. The glue without the wasm
# imports bytes that are not there and the wasm without the glue is 18 MB
# nothing can call into, so a half-placed engine is worse than an absent one:
# the entry document would declare a module the session then fails to
# instantiate, inside `WebAssembly.compileStreaming`, where the message names
# neither this script nor that page.
engine_placed=0
place_module CT_REPLAY_ENGINE_GLUE replay-engine-glue && engine_placed=$((engine_placed + 1))
place_module CT_REPLAY_ENGINE_WASM replay-engine && engine_placed=$((engine_placed + 1))
if [ "${engine_placed}" -eq 1 ]; then
	bad "the replay engine was half-placed: the glue and the wasm are one asset in two files and a deployment must carry both or neither"
fi
if [ "${engine_placed}" -eq 2 ]; then
	replay_worker_src="browser-replay/app/replay-worker.js"
	replay_worker_dst="${out_dir}/$(printf '%s\n' "${manifest}" | awk -F'\t' '$1=="replay-worker"{print $2}')"
	mkdir -p "$(dirname "${replay_worker_dst}")"
	if cp "${replay_worker_src}" "${replay_worker_dst}" 2>/dev/null; then
		ok "replay worker placed at ${replay_worker_dst#"${out_dir}"/}"
	else
		bad "the engine was placed and ${replay_worker_src} was not, so nothing can instantiate it"
	fi
fi
echo

# ---------------------------------------------------------------------------
echo "Step 3a: every /assets/ file is renamed to carry its own digest"
echo "    This is what makes 'immutable' TRUE rather than merely asserted."
echo "    A year-long immutable on a stable filename is a promise a deploy"
echo "    breaks every time, and Cloudflare believed it for 36 hours across"
echo "    two zones. The header is derived from these names, so the rename"
echo "    is what earns it -- nothing downstream had to be told."
# ---------------------------------------------------------------------------
if ! nim c --hints:off --warnings:off --nimcache:"${cache}/assetname" \
	-o:"${cache}/asset-name-bin" ci/test/web_asset_name.nim \
	>"${cache}/assetname.log" 2>&1; then
	bad "ci/test/web_asset_name.nim does not compile, so no name can be formed"
	grep -E 'Error:' "${cache}/assetname.log" | head -3 | sed 's/^/      /'
fi

# The digest tool, resolved once and checked, for the reason
# `verify-deployed-bytes.sh` records at length: a tool that goes missing inside
# `$(...)` manufactures empty output, and an empty digest here would produce
# `assets/wasm-worker..js` — a name that is neither the old one nor
# content-addressed, published under `immutable`.
SHA="$(command -v shasum || true)"
SHA_ARGS=(-a 256)
if [ -z "${SHA}" ]; then
	SHA="$(command -v sha256sum || true)"
	SHA_ARGS=()
fi
[ -n "${SHA}" ] || {
	echo "neither shasum nor sha256sum is on PATH; a content-addressed name cannot be formed" >&2
	exit 2
}

published_tsv="${cache}/published-assets.tsv"
: >"${published_tsv}"
asset_prefix="assets/"
hashed_count=0
asset_rows=0

# The rename is driven by the MANIFEST, so a `/assets/` row added to
# `webRuntimeAssets()` is digested without editing this step — the same
# property `staticAssetGlobClass` has on the reading side. `mode` decides which
# stream the descriptor gets the row on; `fetched` is a module a consumer
# resolves by id, anything else under `/assets/` is a script loaded by URL.
while IFS=$'\t' read -r id path mode req behaviour consumer; do
	[ -n "${id}" ] || continue
	case "${path}" in "${asset_prefix}"*) ;; *) continue ;; esac
	asset_rows=$((asset_rows + 1))
	src="${out_dir}/${path}"
	# NOT AN ERROR. An optional module that was not supplied was never placed,
	# and Step 4 is what grades presence. Silently skipping a file that IS there
	# would be the error, and that is why the count is asserted below.
	[ -f "${src}" ] || continue

	digest="$("${SHA}" "${SHA_ARGS[@]}" "${src}" | cut -d' ' -f1)"
	if [ -z "${digest}" ]; then
		bad "${id}: could not digest ${path}; refusing to publish it under any name"
		continue
	fi
	named="$("${cache}/asset-name-bin" "${path}" "${digest}")"
	if [ $? -ne 0 ] || [ -z "${named}" ]; then
		bad "${id}: web_asset_name refused to name ${path} — see its message above"
		continue
	fi
	# NO STALE SWEEP HERE. It used to live at this line and was wrong at it:
	# guarded by the `continue` above, it only ran for assets this run placed,
	# so the one case that produces a stale copy — an optional asset supplied
	# last run and not this one — was the case it could not reach. The removal
	# is in the pre-place loop near the top of this file, which sees every
	# declared asset whether or not this run has one.
	mv "${src}" "${out_dir}/${named}"
	bytes="$(wc -c <"${out_dir}/${named}" | tr -d ' ')"
	case "${mode}" in
	fetched) kind="module" ;;
	*) kind="asset" ;;
	esac
	printf '%s\t%s\t/%s\t%s\n' "${kind}" "${id}" "${named}" "${bytes}" >>"${published_tsv}"
	hashed_count=$((hashed_count + 1))
	ok "${id}: published as ${named} (${bytes} bytes)"
done < <(printf '%s\n' "${manifest}")

# NON-VACUITY, AND BY NAME. `ok: 0/0` is the shape this repository keeps
# finding: a loop whose subject list came out empty agrees with itself
# perfectly and exits 0. Two assertions, because they fail differently — the
# first catches a manifest that stopped naming `/assets/` rows at all, the
# second catches an assembly that placed the required worker and did not
# rename it. A count alone would pass if some other file made up the number.
if [ "${asset_rows}" -ge 3 ]; then
	ok "the manifest declares ${asset_rows} /assets/ row(s), so the rename loop had subjects"
else
	bad "the manifest declares only ${asset_rows} /assets/ row(s) — the rename loop is vacuous"
fi
worker_published="$(awk -F'\t' '$2=="wasm-worker"{print $3}' "${published_tsv}")"
if printf '%s' "${worker_published}" | grep -qE '/assets/wasm-worker\.[0-9a-fA-F]{6,}\.js$'; then
	ok "wasm-worker, by name, is published content-addressed at ${worker_published}"
else
	bad "wasm-worker is published at '${worker_published}', which carries no digest — /assets/* cannot be immutable"
fi
note "${hashed_count} of ${asset_rows} declared /assets/ file(s) were present and digested"
# Steps 5 and 6 grade the placed worker, and it has moved. Not re-derived at
# each use: one variable, reassigned once, where the rename happened.
[ -n "${worker_published}" ] && worker_dst="${out_dir}${worker_published}"

# THE PROPERTY THE WHOLE CHANGE EXISTS FOR, asserted on the assembly's own
# output rather than on an illustrative string: different bytes get a different
# address. Without it, `immutable` is still a promise nobody checked — a
# renaming step that hashed the FILENAME, or a constant, would satisfy every
# other assertion in this step and re-publish the same URL over new bytes.
probe_a="${cache}/deploy-probe-a"
probe_b="${cache}/deploy-probe-b"
printf 'build one\n' >"${probe_a}"
printf 'build two\n' >"${probe_b}"
name_a="$("${cache}/asset-name-bin" "${worker_stem}" \
	"$("${SHA}" "${SHA_ARGS[@]}" "${probe_a}" | cut -d' ' -f1)")"
name_b="$("${cache}/asset-name-bin" "${worker_stem}" \
	"$("${SHA}" "${SHA_ARGS[@]}" "${probe_b}" | cut -d' ' -f1)")"
if [ -n "${name_a}" ] && [ -n "${name_b}" ] && [ "${name_a}" != "${name_b}" ]; then
	ok "a change of content changes the published URL (${name_a##*/} vs ${name_b##*/})"
else
	bad "two different files were published at the same address ('${name_a}' vs '${name_b}') — a deploy would not dislodge the cached copy"
fi
# The third module is NOT from the `noir` fork — it wraps Aztec's own
# `avm-transpiler` — which is why it has its own variable and its own ref below
# rather than riding on `CT_NOIR_WASM_REF`. A deployment that placed it under
# the Noir ref would be claiming a provenance that names the wrong repository.
place_module CT_AVM_TRANSPILER_WASM avm-transpiler
echo

# ---------------------------------------------------------------------------
echo "Step 3b: render the entry document and the host configuration"
echo "    The asset nothing produced. renderRewriteConfig() emitted a target"
echo "    for every prefix and no step ever wrote the file it named -- so a"
echo "    deployment would have served the rewrites and 404'd every one."
echo "    The target has since moved from '/index.html' to '/': Cloudflare"
echo "    Pages normalises the first into a 308 redirect, which turned every"
echo "    200-rewrite into the 302-class answer Noir-Studio.md 1b.4 forbids"
echo "    and sent /noir to / before any script ran. web-renderer-mounts.sh"
echo "    arm D asserts the shipped table over this. The document also CARRIES"
echo "    the descriptor of what this assembly actually placed, measured from"
echo "    the files on disk, which is what the page reads instead of making a"
echo "    request."
# ---------------------------------------------------------------------------
origin="${CT_WEB_ORIGIN:-https://ide.codetracer.com}"

# WHICH HOSTS ARE LANGUAGE ENTRY POINTS. `<origin>=<language>`, comma
# separated; e.g. `https://noirstudio.dev=noir`. One Cloudflare Pages project
# serves any number of custom domains from ONE tree, so a second domain is a
# different meaning for `/` and not a second artifact — the descriptor carries
# the map, the page reads it out of its own DOM, and no request is made.
#
# NO DEFAULT, deliberately, and it is the same rule `origin` follows two lines
# up for a weaker reason: `platform/web_entry.nim` refuses to contain an origin
# at all because the product's host has moved twice and each move found a
# constant. An unset value here is a single-domain deployment, which is a
# correct deployment.
language_origins="${CT_WEB_LANGUAGE_ORIGINS:-}"
revision="${CT_WEB_REVISION:-$(git -C "${repo_root}" rev-parse --short HEAD 2>/dev/null || echo unknown)}"

# The provenance strings. Read from the environment because only the caller
# that BUILT the modules knows which `noir` ref they came from, and a module
# that cannot say where it came from is dropped by `registrableModules` — so
# an unset value here disables the module rather than shipping it anonymously.
noir_ref="${CT_NOIR_WASM_REF:-}"
# The transpiler's own, for the reason `place_module` gives above: it is a
# different repository and a different crate, and one variable covering both
# would make either module able to ship under the other's provenance.
avm_transpiler_ref="${CT_AVM_TRANSPILER_REF:-}"

descriptor_tsv="${cache}/descriptor-rows.tsv"
: >"${descriptor_tsv}"
declare_module() {
	local id="$1" crate="$2" origin_label="${3:-noir@codetracer ${noir_ref} }"
	# THE URL AND THE SIZE BOTH COME FROM WHAT STEP 3a ACTUALLY PUBLISHED, not
	# from the manifest path. The manifest names `assets/noir_wasm.wasm` and no
	# deployment serves that address any more; declaring it would produce a
	# document promising a module the publish directory does not contain, which
	# is the exact state `deployGuardDefects` blocks a deploy for — reached by
	# the step that writes the declaration.
	#
	# The size is still MEASURED rather than assumed, for the reason this
	# comment has always given: the document declares a number a guard can
	# compare against the bytes about to be uploaded, so a truncated copy is a
	# failed deploy rather than a broken page.
	local row
	row="$(awk -F'\t' -v i="${id}" '$1=="module" && $2==i {print}' "${published_tsv}")"
	[ -n "${row}" ] || return 0
	if [ -z "${origin_label}" ]; then
		bad "${id}: placed, but its provenance is unset, so it has no builtFrom and the page would drop it"
		return 0
	fi
	printf 'module\t%s\t%s\t%s\t%s\n' "${id}" \
		"$(printf '%s' "${row}" | cut -f3)" \
		"$(printf '%s' "${row}" | cut -f4)" \
		"${origin_label}${crate}" >>"${descriptor_tsv}"
}
noir_provenance=""
[ -n "${noir_ref}" ] && noir_provenance="noir@codetracer ${noir_ref} "
declare_module noir-compiler "compiler/wasm" "${noir_provenance}"
declare_module noir-tracer "tooling/tracer_wasm" "${noir_provenance}"

# THE THIRD MODULE IS NOT FROM THE `noir` FORK — it wraps Aztec's own
# `avm-transpiler` — so it carries its own ref and its own repository label
# rather than riding on `noir_provenance`. A deployment that placed it under
# the Noir ref would be claiming a provenance that names the wrong repository.
avm_transpiler_provenance=""
[ -n "${avm_transpiler_ref}" ] && avm_transpiler_provenance="aztec-avm-runtime@browser/vendor-aztec-nr ${avm_transpiler_ref} "
declare_module avm-transpiler "avm-transpiler-wasm" "${avm_transpiler_provenance}"

# THE ENGINE IS DECLARED, and it has to be for two independent reasons.
#
# `deployGuardDefects` treats a fetched asset present in the publish tree and
# absent from the entry document's `modules[]` as a defect, so placing it
# without declaring it would BLOCK the deploy. And `declaredModuleUrls` — the
# only function that turns an asset into something the browser can reach — is
# read straight out of the served document, because `noir-studio-signed-out.sh`
# asserts the loop-arm bundle has zero network egress sites and the descriptor
# is therefore in the DOM rather than fetched. An undeclared engine is an
# engine with no URL, which is what `ide.codetracer.com` has been serving.
#
# Its provenance is this repository's own revision, not the noir ref: the
# engine is `src/db-backend` built for wasm32, and labelling it with a `noir`
# commit would make the page name the wrong repository for the bytes.
engine_provenance=""
[ -n "${revision}" ] && engine_provenance="codetracer ${revision} "
declare_module replay-engine-glue "src/db-backend (wasm-bindgen glue)" "${engine_provenance}"
declare_module replay-engine "src/db-backend" "${engine_provenance}"

# THE WORKER SCRIPTS, WHICH USED TO NEED NO DECLARATION AT ALL.
#
# `newBrowserWasmHost(registry, "/" & wasmWorkerScriptPath, ...)` was a Nim
# constant, and a constant is a perfectly good answer for a file whose name
# never changes. A name derived from the bytes is not a constant, so the
# deployment now says where it put them and the product reads it out of the
# document — the same indirection `modules[]` already had, which is why the two
# Noir modules cost nothing to hash and these two did.
#
# No provenance clause: these are this repository's own files, `registrableModules`
# never sees them, and inventing a `builtFrom` for them would put a worker
# script in a list `wasm_worker.configure` hands to a worker as a module.
declared_assets=0
while IFS=$'\t' read -r kind id url bytes; do
	[ "${kind}" = "asset" ] || continue
	printf 'asset\t%s\t%s\t%s\n' "${id}" "${url}" "${bytes}" >>"${descriptor_tsv}"
	declared_assets=$((declared_assets + 1))
done <"${published_tsv}"
if [ "${declared_assets}" -ge 1 ]; then
	ok "the document declares ${declared_assets} published worker script(s) by URL"
else
	bad "no worker script was declared; the page would have no URL to start a Worker from and would report this deployment as shipping none"
fi

if ! nim c --hints:off --warnings:off --nimcache:"${cache}/render" \
	-o:"${cache}/render-bin" ci/test/web_deployment_render.nim \
	>"${cache}/render.log" 2>&1; then
	bad "the deployment renderer did not compile"
	grep -E 'Error:' "${cache}/render.log" | head -3 | sed 's/^/      /'
else
	if "${cache}/render-bin" "${origin}" "${revision}" "${out_dir}" \
		"${language_origins}" \
		<"${descriptor_tsv}" >"${cache}/render-out.log" 2>&1; then
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
	# THE PUBLISHED NAME, NOT THE MANIFEST NAME, for anything Step 3a renamed.
	# Left as `${out_dir}/${path}`, this loop would report every `/assets/`
	# asset as missing — and, worse, would have reported them PRESENT if a
	# previous run's undigested copies were still in the tree, which is the
	# stale-artefact false pass this script's own Step 1 header records.
	published="$(awk -F'\t' -v i="${id}" '$2==i{print $3}' "${published_tsv}")"
	if [ -n "${published}" ]; then
		target="${out_dir}${published}"
	else
		target="${out_dir}/${path}"
	fi
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
echo "Step 5b: the engine's glue is told where its wasm is, and does not guess"
echo "    THE ONE WAY CONTENT-ADDRESSING COULD BREAK THE ENGINE. The glue and"
echo "    the wasm are two files and the glue names the other one; hashing one"
echo "    without the other would 404 -- and on Pages a 404 under /assets/ is"
echo "    the entry document at 200 text/html, which fails inside"
echo "    WebAssembly.compileStreaming naming neither file."
# ---------------------------------------------------------------------------
#
# WHY IT IS SAFE HERE, MEASURED RATHER THAN ASSUMED. `wasm-pack --target web`
# emits `__wbg_init(module_or_path)`, whose DEFAULT is
# `new URL('db_backend_bg.wasm', import.meta.url)` — the glue's own directory
# and the undigested name. `browser-replay/app/worker.js` relies on exactly
# that, which is why BlockTracer's `/worker.js` and `/pkg/*` copies are NOT
# renamed and must not be.
#
# The Studio's `replay-worker.js` does not rely on it: it takes both URLs from
# the entry document's descriptor and passes the wasm one in —
# `await module.default(wasmUrl)`. That argument is what makes hashing the two
# files independently safe, and it is one edit away from not being there. So it
# is asserted, on the file that was actually placed, rather than believed.
replay_worker_published="$(awk -F'\t' '$2=="replay-worker"{print $3}' "${published_tsv}")"
if [ -n "${replay_worker_published}" ]; then
	replay_code="${cache}/replay-worker-code.js"
	grep -vE '^[[:space:]]*//' "${out_dir}${replay_worker_published}" >"${replay_code}"

	if node --check "${out_dir}${replay_worker_published}" 2>"${cache}/replay-parse.log"; then
		ok "the replay worker parses as JavaScript"
	else
		bad "the replay worker does NOT parse; a browser would fail on its first line"
		head -5 "${cache}/replay-parse.log" | sed 's/^/      /'
	fi

	# Positive control on the stripped file, so the greps below cannot pass over
	# an empty one by finding nothing in it.
	if grep -q "self.onmessage" "${replay_code}"; then
		ok "positive control: the placed replay worker installs a message handler"
	else
		bad "positive control FAILED: the placed file is not a worker; every check below is vacuous"
	fi

	# THE ARGUMENT, WHICH IS THE WHOLE OF IT.
	if grep -qE 'module\.default\([^)]+\)' "${replay_code}"; then
		ok "the replay worker passes the wasm URL to the glue rather than letting it guess"
	else
		bad "the replay worker calls the glue's init with NO url, so the glue would resolve db_backend_bg.wasm relative to itself — a name no deployment publishes"
	fi
	# And the URL it passes is the DECLARED one, by id, not a path it built.
	for needed in "replay-engine-glue" "replay-engine"; do
		if grep -qF "\"${needed}\"" "${replay_code}"; then
			ok "the replay worker resolves '${needed}' from the descriptor's moduleUrls"
		else
			bad "the replay worker never names '${needed}'; it cannot be getting its URL from the entry document"
		fi
	done
	# It must not reconstruct a path. A `new URL('...db_backend...')` here would
	# be the guessing this step exists to forbid, however it was spelled.
	if grep -qE "new URL\([^)]*db_backend" "${replay_code}"; then
		bad "the replay worker builds a db_backend URL of its own; the published name carries a digest and cannot be spelled in source"
	else
		ok "the replay worker constructs no db_backend URL of its own"
	fi
else
	note "no replay worker was placed (the engine was not supplied), so its glue contract was not checked"
fi
echo

# ---------------------------------------------------------------------------
echo "Step 6: the worker's module ids are the manifest's module ids"
echo "    A rename on one side produces 'no url declared for wasm module' in a"
echo "    browser and nothing at all before that."
# ---------------------------------------------------------------------------
if [ -f "${worker_code:-/nonexistent}" ]; then
	checked_ids=0
	while IFS=$'\t' read -r id path mode req behaviour consumer; do
		[ "${mode}" = "fetched" ] || continue
		# THE CONSUMER COLUMN, and not just `mode`. `fetched` now covers two
		# different workers: `wasm_worker_browser.js` resolves the Noir
		# modules by id from its `configure` message, and `replay-worker.js`
		# instantiates the replay engine through wasm-bindgen glue and never
		# calls `load()` at all. Checking every fetched row against this
		# worker would fail on the engine, and dropping the check to make it
		# pass would stop asserting the thing it exists for.
		[ "${consumer}" = "noir-wasm-worker" ] || continue
		checked_ids=$((checked_ids + 1))
		if grep -qF "load('${id}')" "${worker_code}"; then
			ok "the worker resolves '${id}', the id the manifest declares"
		else
			bad "the manifest declares fetched module '${id}' and the worker never loads it"
		fi
	done < <(printf '%s\n' "${manifest}")
	# NON-VACUITY. A `continue` that matched nothing would leave this loop
	# silent and green, which is what a filter added to a passing check tends
	# to become.
	if [ "${checked_ids}" -eq 0 ]; then
		bad "no fetched row named the noir-wasm-worker as its consumer, so Step 6 checked nothing"
	fi
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
