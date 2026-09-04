#!/usr/bin/env bash
#
# renderer-browser-build.sh — the renderer, built for a browser, on both arms.
#
# WHY THIS EXISTS
# ---------------
# Three Noir Studio milestones wait on one fact: that the renderer can be built
# for the web, so a bundle can carry it. Until now nothing in CI compiled the
# renderer AT ALL — not on the web arm, not on the Electron arm it ships on.
# `ci/lib/test-lane-files.sh` recorded that gap honestly in the
# `host-instantiations` lane ("What DOES compile it is the tup product build...
# at package time rather than on push") after an attempt to close it failed:
# the JS lane family passes `-d:nodejs` to everything, and under `-d:nodejs`
# the renderer does not compile, because it is a BROWSER module and node is not
# a browser.
#
# THE GAP WAS NOT THEORETICAL. Commit 333ec709 dropped `ui/ui_imports.nim`'s
# blanket re-export of `electron_lib` after auditing its 14 exported symbols
# for uses "anywhere under `ui/`". `src/frontend/ui_js.nim` — the renderer
# entry point — is not under `ui/`, and it read `inElectron` from that
# re-export. The renderer stopped compiling, `dev` shipped it that way, and
# every suite stayed green. That is this repository's signature defect
# (`host/web_browser.nim`, unparseable on `dev` for days, same week, one
# directory over) reproduced exactly.
#
# So: `renderer-electron` and `renderer-web` are lanes on a third backend,
# `js-browser` — `nim js` with no `-d:nodejs`, compile-only by construction.
# This script is the lane's PROPERTY gate: the lanes prove the renderer
# compiles, and this proves the two arms are actually different builds and that
# the web one links no Electron.
#
# WHICH LANE COMPILES WHAT — verified below in step 4 rather than asserted,
# because a lane that silently skips its subject is worse than no lane:
#
#   ui_js.nim (renderer entry)  renderer-electron AND renderer-web
#   renderer.nim                both, transitively (marker __renderer_)
#   ui/menu.nim                 both, transitively (marker __uiZmenu_)
#   lib/electron_presence.nim   both, transitively (marker ...presence_)
#   subwindow.nim               renderer-electron only (Electron-only module)
#   ui/panel_transfer.nim       renderer-electron only (capMultiWindow absent
#                               on web; its own {.error.} says so)
#   ui/agentic_worktree_test_hooks.nim
#                               renderer-electron only (capProcessArbitrary-
#                               Programs absent on web)
#
# TWO TRAPS THIS SCRIPT IS WRITTEN AGAINST, both of which have bitten this
# campaign:
#
#   * "Equal digests over two empty traces are as green as a real match."
#     Here the analogue is two bundles that both contain no `child_process`
#     because both are truncated, or a grep that finds nothing because it is
#     looking at nothing. Every negative check below is preceded by a positive
#     control on the SAME file, and every bundle is size-checked, so "found
#     nothing" cannot mean "looked at nothing".
#   * A marker must be a SYMBOL the compiler emits, never a source string
#     literal. `web-bundle-smoke.sh` learned this the expensive way: it grepped
#     for a `const`'s text, which Nim's JS backend does not guarantee to
#     preserve, and went red against a perfectly good bundle. The markers here
#     are Nim's own module-mangled names (`__ui95js_`, `__uiZmenu_`, ...),
#     which the backend must emit for the module to exist at all.
#
# Usage:  bash ci/test/renderer-browser-build.sh
# Env:    ISONIM_SRC        isonim source tree (else the ../isonim sibling)
#         CT_NIM_CACHE_ROOT nimcache root (default /tmp/ct-nim-cache)

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

# shellcheck source=ci/lib/test-lane-files.sh
# shellcheck disable=SC1091 # resolved at runtime from $repo_root
source "${repo_root}/ci/lib/test-lane-files.sh"

cache_root="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}"
checks=0
failures=0

note() { printf '  %s\n' "$*"; }
ok() {
	checks=$((checks + 1))
	printf '  [OK]     %s\n' "$*"
}
bad() {
	checks=$((checks + 1))
	failures=$((failures + 1))
	printf '  [FAILED] %s\n' "$*"
	shift $#
}

echo "=== renderer browser build (NS2/NS3: the renderer, for a browser) ==="
echo

# ---------------------------------------------------------------------------
# Step 0: the toolchain and the one generated prerequisite.
#
# These are EXIT 2, not failures: an absent toolchain is not a red gate, it is
# a gate that did not run, and conflating the two is how a suite comes to
# "pass" on a machine that compiled nothing.
# ---------------------------------------------------------------------------
command -v nim >/dev/null 2>&1 || {
	echo "nim is not on PATH" >&2
	echo "  remedy: run inside the dev shell (direnv exec ${repo_root} ...)" >&2
	exit 2
}

isonim_root=""
if [ -n "${ISONIM_SRC:-}" ]; then
	isonim_root="$(cd "${ISONIM_SRC}/.." 2>/dev/null && pwd || true)"
fi
for candidate in "${repo_root}/../isonim" "${repo_root}/../../isonim"; do
	[ -n "${isonim_root}" ] && break
	[ -d "${candidate}" ] && isonim_root="$(cd "${candidate}" && pwd)"
done

# `ui_js.nim` reaches `isonim/dsl/tailwind`, which `staticRead`s this file at
# COMPILE time. Nim cannot catch a failing `staticRead`, so without it the
# renderer build dies several minutes in with an error naming neither this gate
# nor the file's purpose (`scripts/build-once.sh` carries the same warning).
# Checking it here costs nothing and turns that into one sentence.
tailwind_json="${isonim_root:-/nonexistent}/build/tailwind-styles.json"
if [ ! -f "${tailwind_json}" ]; then
	echo "isonim's build/tailwind-styles.json is missing: ${tailwind_json}" >&2
	echo "  remedy: bash scripts/build-tailwind.sh   (or, for a compile-only" >&2
	echo "          check, seed a placeholder: mkdir -p \"\$(dirname \"${tailwind_json}\")\"" >&2
	echo "          && echo '{}' > \"${tailwind_json}\" — which is what" >&2
	echo "          .github/actions/setup-isonim-siblings does in CI)" >&2
	exit 2
fi
note "isonim: ${isonim_root}"
echo

# ---------------------------------------------------------------------------
echo "Step 1: the lanes are wired to a browser backend, not the node one"
echo "    This is the property that makes the renderer compilable at all, and"
echo "    it is the one an editor is most likely to undo by 'tidying' the"
echo "    backend list. Step 2 proves it is load-bearing against the compiler."
# ---------------------------------------------------------------------------
for lane in renderer-electron renderer-web; do
	if grep -qx "${lane}" <<<"$(test_lane_ids)"; then
		ok "${lane} is a registered lane id"
	else
		bad "${lane} is NOT in test_lane_ids — nothing would ever run it"
	fi

	backend="$(test_lane_backend "${lane}")"
	if [ "${backend}" = "js-browser" ]; then
		ok "${lane} uses the js-browser backend"
	else
		bad "${lane} uses backend '${backend}', not js-browser"
	fi

	flags="$(test_lane_extra_flags "${lane}")"
	if [[ "${flags}" != *"-d:nodejs"* ]]; then
		ok "${lane} does not pass -d:nodejs"
	else
		bad "${lane} passes -d:nodejs, under which the renderer cannot compile"
	fi

	if [[ "${flags}" == *"-d:ctRenderer"* ]]; then
		ok "${lane} passes -d:ctRenderer (the product's own renderer define)"
	else
		bad "${lane} does not pass -d:ctRenderer; this would compile a different product"
	fi
done

# The two arms must differ by exactly the define the switch reads. Both
# directions, because a lane pair that passed -d:ctWeb to BOTH would compile
# the web arm twice and report the Electron arm green without building it.
if [[ "$(test_lane_extra_flags renderer-web)" == *"-d:ctWeb"* ]]; then
	ok "renderer-web passes -d:ctWeb"
else
	bad "renderer-web does not pass -d:ctWeb — it would be a second Electron build"
fi
if [[ "$(test_lane_extra_flags renderer-electron)" != *"-d:ctWeb"* ]]; then
	ok "renderer-electron does NOT pass -d:ctWeb, so the Electron arm has a gate"
else
	bad "renderer-electron passes -d:ctWeb; the Electron arm would have no gate"
fi

# The subject itself. A lane whose file list lost the entry point would still
# exit 0 over its remaining files.
if grep -qx "src/frontend/ui_js.nim" <<<"$(test_lane_files renderer-web)"; then
	ok "renderer-web's file list names the renderer entry point"
else
	bad "renderer-web does not list src/frontend/ui_js.nim — the lane has no subject"
fi
if grep -qx "src/frontend/ui_js.nim" <<<"$(test_lane_files renderer-electron)"; then
	ok "renderer-electron's file list names the renderer entry point"
else
	bad "renderer-electron does not list src/frontend/ui_js.nim"
fi
echo

# ---------------------------------------------------------------------------
echo "Step 2: -d:nodejs really is fatal here, measured against the toolchain"
echo "    The js-browser backend exists ONLY because of this. Asserting it in a"
echo "    comment would let the reason rot; vm-js-lane-test.sh makes the"
echo "    mirror-image claim for the node lanes the same way."
# ---------------------------------------------------------------------------
nodejs_probe_cache="${cache_root}/renderer-nodejs-probe"
mkdir -p "${nodejs_probe_cache}"
nodejs_out="$(nim js -d:nodejs -d:chronicles_enabled=off -d:ctRenderer \
	--hints:off --warnings:off --nimcache:"${nodejs_probe_cache}" \
	-o:"${nodejs_probe_cache}/ui.js" src/frontend/ui_js.nim 2>&1)"
nodejs_rc=$?
if [ "${nodejs_rc}" -ne 0 ]; then
	ok "the renderer does NOT compile with -d:nodejs (exit ${nodejs_rc}), so the backend split is load-bearing"
	if grep -q "createElementNS" <<<"${nodejs_out}"; then
		ok "and it fails for the recorded reason: kdom's createElementNS is absent under -d:nodejs"
	else
		# Not a failure. The claim under test is "this configuration does not
		# build"; the specific missing symbol is Nim's business and may move.
		note "NOTE: it failed for a different reason than the recorded createElementNS:"
		printf '%s\n' "${nodejs_out}" | grep -E 'Error:' | head -2 | sed 's/^/        /'
	fi
else
	bad "the renderer COMPILED with -d:nodejs — if kdom gained a node arm, fold these lanes back into the js backend and delete js-browser"
fi
echo

# ---------------------------------------------------------------------------
echo "Step 3: both arms build"
# ---------------------------------------------------------------------------
declare -A bundle
build_arm() {
	local lane="$1" out_cache
	out_cache="${cache_root}/${lane}-gate"
	mkdir -p "${out_cache}"
	local flags
	read -r -a flags <<<"$(test_lane_extra_flags "${lane}")"
	local log
	log="$(nim js --hints:off --warnings:off "${flags[@]}" \
		--nimcache:"${out_cache}" -o:"${out_cache}/ui.js" \
		src/frontend/ui_js.nim 2>&1)"
	local rc=$?
	if [ "${rc}" -ne 0 ] || [ ! -f "${out_cache}/ui.js" ]; then
		bad "${lane}: the renderer did not build"
		printf '%s\n' "${log}" | grep -E 'Error:' | head -3 | sed 's/^/      /'
		return 1
	fi
	bundle["${lane}"]="${out_cache}/ui.js"
	ok "${lane}: built ($(wc -c <"${out_cache}/ui.js" | tr -d ' ') bytes)"
	return 0
}
build_arm renderer-electron
build_arm renderer-web
electron_js="${bundle[renderer-electron]:-}"
web_js="${bundle[renderer-web]:-}"
if [ -z "${electron_js}" ] || [ -z "${web_js}" ]; then
	echo
	echo "RESULT: FAILED — an arm did not build; the property checks below cannot run"
	exit 1
fi
echo

# ---------------------------------------------------------------------------
echo "Step 4: positive control — each bundle really contains the renderer"
echo "    Nim mangles a module's name into every symbol it emits, so these"
echo "    markers cannot survive the module being dropped from the graph. This"
echo "    is what stops the negative checks in step 6 passing over a bundle"
echo "    that simply does not contain the code they are looking for."
# ---------------------------------------------------------------------------
# NON-TRIVIALITY FIRST. A truncated or empty bundle satisfies every "contains
# no Electron" assertion below perfectly, which is the same worthlessness as
# equal digests over two empty traces.
for arm in "renderer-electron:${electron_js}" "renderer-web:${web_js}"; do
	lane="${arm%%:*}"
	f="${arm#*:}"
	size="$(wc -c <"${f}" | tr -d ' ')"
	if [ "${size}" -gt 1000000 ]; then
		ok "${lane}: bundle is non-trivial (${size} bytes > 1 MB)"
	else
		bad "${lane}: bundle is only ${size} bytes — too small to be the renderer; every check below would be vacuous"
	fi

	# The three modules people mean by "the renderer". `renderer.nim` and
	# `ui/menu.nim` are here because they are the two the lane does NOT name —
	# they are compiled transitively, and "transitively" is a claim that has to
	# be checked. `menu.nim` in particular does not compile standalone (an
	# import-cycle artefact, see the lane's file list), so this marker is the
	# only evidence that the lane type-checks it.
	for marker in __ui95js_:ui_js.nim __renderer_:renderer.nim \
		__uiZmenu_:ui/menu.nim __libZelectron95presence_:lib/electron_presence.nim; do
		sym="${marker%%:*}"
		mod="${marker#*:}"
		if grep -qa "${sym}" "${f}"; then
			ok "${lane}: ${mod} is compiled into the bundle"
		else
			bad "${lane}: ${mod} is ABSENT from the bundle — this lane does not actually compile it"
		fi
	done
done
echo

# ---------------------------------------------------------------------------
echo "Step 5: the two arms are different builds"
echo "    Without this the pair could be two identical Electron builds, both"
echo "    green, and the -d:ctWeb switch would be decoration."
# ---------------------------------------------------------------------------
# Each of these is a module the web arm excludes BY ITS OWN {.error.} guard.
# The Electron count is the positive control for the web count: if it were also
# zero, the web zero would mean the marker is wrong, not that the module is
# absent.
for marker in __uiZpanel95transfer_:ui/panel_transfer.nim \
	__uiZagentic95worktree95test95hooks_:ui/agentic_worktree_test_hooks.nim; do
	sym="${marker%%:*}"
	mod="${marker#*:}"
	e_hits="$(grep -ac "${sym}" "${electron_js}")"
	w_hits="$(grep -ac "${sym}" "${web_js}")"
	if [ "${e_hits}" -gt 0 ]; then
		ok "control: ${mod} IS in the Electron bundle (${e_hits} hits), so the marker works"
	else
		bad "control FAILED: ${mod} is in neither bundle — the marker is wrong and the web check below is vacuous"
	fi
	if [ "${w_hits}" -eq 0 ]; then
		ok "${mod} is absent from the web bundle, as its {.error.} guard requires"
	else
		bad "${mod} leaked into the web bundle (${w_hits} hits)"
	fi
done
echo

# ---------------------------------------------------------------------------
echo "Step 6: the web bundle links no Electron host bindings"
# ---------------------------------------------------------------------------
e_cp="$(grep -ac child_process "${electron_js}")"
w_cp="$(grep -ac child_process "${web_js}")"
if [ "${e_cp}" -gt 0 ]; then
	ok "control: the Electron bundle mentions child_process (${e_cp}), so this grep sees real content"
else
	bad "control FAILED: child_process is in neither bundle — the check below proves nothing"
fi
if [ "${w_cp}" -eq 0 ]; then
	ok "the web bundle does not mention child_process"
else
	bad "the web bundle mentions child_process ${w_cp} time(s) — something pulled a node-hosted module in"
fi

# ---------------------------------------------------------------------------
# THE LOAD-TIME PROPERTY, which is the one that decides whether a browser can
# carry this bundle at all.
#
# `web-bundle-smoke.sh` asserts ZERO `require(` for `web_main.nim`, and that is
# right for a module whose every host reach is already behind the facade. The
# renderer is not there yet and this gate does not pretend otherwise. What it
# asserts instead is the property that actually matters for delivery:
#
#   NO `require(` RUNS AT MODULE SCOPE.
#
# Nim's JS backend emits module-initialisation code at the top level of the
# file and everything else inside a `function`, so a `require(` at indentation
# zero is one that executes the instant the browser evaluates the bundle — and
# a browser has no `require`, so the whole renderer would die before its first
# line. A `require(` inside a function is a call-time hazard on a code path the
# web build may never take. Those are different severities and this gate keeps
# them apart rather than collapsing both into one number.
# ---------------------------------------------------------------------------
toplevel_requires="$(grep -an '^require(\|^[^ 	].*require(' "${web_js}" |
	grep -c 'require(' || true)"
if [ "${toplevel_requires}" -eq 0 ]; then
	ok "no require() at module scope in the web bundle — a browser can load it"
else
	bad "${toplevel_requires} require() call(s) run at module scope; the bundle would throw before its first line"
	grep -an '^[^ 	].*require(' "${web_js}" | head -3 | cut -c1-140 | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------
# THE DECLARED RESIDUAL. Four call-time `require(` sites remain in the web
# bundle, in three modules, and they are listed rather than tolerated silently:
# a budget that is a number and a name cannot grow by one without this going
# red, which is what `renderer-host-reach-budget.sh` does for the same class of
# debt one layer up.
#
#   lsp_controller.nim   nodePath() / an fs read — the LSP client's own file
#                        access. The web's answer is the project store, and
#                        that is NS-LSP work, not this milestone's.
#   lsp_router.nim       nodeFs() — same.
#   ui/flow.nim          require("tippy.js") — a tooltip library loaded through
#                        node resolution rather than bundled. Cosmetic, and the
#                        smallest of the four.
#
# All four are inside procs, so they cost nothing until a web build reaches
# them; the assertion above is what guarantees that.
# ---------------------------------------------------------------------------
declared_unguarded=4
actual_unguarded="$(python3 - "${web_js}" <<'PY'
import re, sys
s = open(sys.argv[1], encoding='utf8', errors='replace').read()
n = 0
for m in re.finditer(r'require\(', s):
    # A site is GUARDED when `typeof require` appears in the same expression
    # just before it -- the `(typeof require === 'function') && require(...)`
    # shape the surviving front-end call sites are written in.
    if 'typeof require' not in s[max(0, m.start() - 120):m.start()]:
        n += 1
print(n)
PY
)"
if [ "${actual_unguarded}" = "${declared_unguarded}" ]; then
	ok "the web bundle's unguarded require() budget is unchanged (${actual_unguarded}); see the list above"
else
	bad "the web bundle has ${actual_unguarded} unguarded require() site(s), not the declared ${declared_unguarded} — a host reach was added or removed; update the list above and say which"
fi

# The counter-check: a bundle in which NOTHING is guarded would also satisfy a
# budget of 4 if four sites happened to exist. Assert the guarded ones are
# really there, so the classifier is known to be working on this file.
guarded="$(python3 - "${web_js}" <<'PY'
import re, sys
s = open(sys.argv[1], encoding='utf8', errors='replace').read()
print(sum(1 for m in re.finditer(r'require\(', s)
          if 'typeof require' in s[max(0, m.start() - 120):m.start()]))
PY
)"
if [ "${guarded}" -gt 0 ]; then
	ok "control: ${guarded} require() site(s) ARE classified as guarded, so the classifier distinguishes the two"
else
	bad "control FAILED: the classifier found no guarded sites at all; the budget above is measuring one category, not two"
fi
echo

# ---------------------------------------------------------------------------
echo "${checks} check(s), ${failures} failure(s)"
if [ "${checks}" -eq 0 ]; then
	echo "RESULT: FAILED — the gate asserted nothing at all"
	exit 1
fi
if [ "${failures}" -eq 0 ]; then
	echo "RESULT: OK — the renderer builds for a browser on both arms, and the web arm links no Electron"
	exit 0
fi
echo "RESULT: FAILED — ${failures} check(s)"
exit 1
