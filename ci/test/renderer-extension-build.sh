#!/usr/bin/env bash
#
# renderer-extension-build.sh — the DEVELOPER renderer build produces a bundle,
# and the VS Code extension's two bundles are what they claim to be.
#
# SINCE HSF-X2 (Shared-DOM-Front-Ends D5) THE EXTENSION DOES NOT LOAD THE
# RENDERER. Its panels are `entries/vscode_panel.nim` (one panel's view over a
# mirror of the host's session) and its host is `entries/vscode_host.nim`; the
# `-d:ctInExtension` arm of `ui_js` and of `ui/*.nim` is gone. Step 1 now
# asserts the developer recipes do NOT pass that define, and step 3 builds the
# extension's bundles and asserts the panel bundle carries none of the
# renderer: no `ui_js`, no `Data`, no Monaco, no jQuery.
#
# The history below is why the developer recipes are gated at all.
#
# WHY THIS EXISTS
# ---------------
# `ci/test/renderer-browser-build.sh` closed the hole where nothing in CI
# compiled the renderer. It compiles two arms — `renderer-electron` and
# `renderer-web` — and those are the SHIPPED configurations. It does not
# compile the configuration a developer types, and `just build-ui-js` sat
# broken on the `cloud` mainline with every suite green, for exactly the reason
# that note gives for the shipped arms: nothing ran it.
#
# `just build-ui-js` differs from the shipped arms by two things, and each one
# had already broken it:
#
#   -d:ctInExtension        the VS Code extension arm. `ci/lib/test-lane-
#                           files.sh` says of `renderer-electron` that this
#                           define is "deliberately NOT" in the lane because it
#                           "is currently broken for an unrelated reason" — an
#                           honest note that then went unactioned, so the arm
#                           stayed broken twice over:
#
#                             ui/trace.nim(1088, 6) Error: internal error:
#                               symbol has no generated name: gutterTestLines
#                             ui_js.nim(1791, 3) Error: undeclared identifier:
#                               'resolvePendingDapResponse'
#
#   --hotCodeReloading:on   the flag these two recipes used to pass, and the
#                           reason this gate also asserts a NEGATIVE. It was
#                           never what broke the compile — the flag matrix
#                           below built cleanly with it and failed without it —
#                           but once the build worked, its output carried 112
#                           DUPLICATED top-level function names, the same class
#                           that stopped the renderer's editor from mounting
#                           (092588b8, `ci/test/js-bundle-name-uniqueness.sh`).
#                           It is gone from both recipes and step 1 keeps it
#                           gone.
#
#                             -d:ctRenderer                          14.7 MB
#                             -d:ctRenderer --hotCodeReloading:on    18.4 MB
#                             -d:ctRenderer --debugInfo --lineDir    21.2 MB
#                             -d:ctRenderer -d:ctInExtension         NO ARTEFACT
#
# NOT A NEW BACKEND, and that is the difference from the note at the top of
# `renderer-browser-build.sh`. `js-browser` had to exist because the JS lane
# family passes `-d:nodejs`, under which the renderer cannot compile at all.
# This build is `nim js` with no `-d:nodejs` — the same backend — differing
# only in defines. A third backend would have been ceremony; a second gate on
# the same backend is the honest shape.
#
# WHAT THIS GATE ASSERTS, and why not "the recipe exited 0"
# --------------------------------------------------------
# This campaign has found roughly a dozen checks that passed by not running.
# An exit status is the weakest possible evidence here, so every claim below is
# made against the BYTES the recipe produced:
#
#   * the output path is created fresh in a mktemp dir, so a stale artefact
#     from a previous run cannot be mistaken for this run's;
#   * the file must EXIST and be over 1 MB — a truncated or empty bundle
#     satisfies every grep below vacuously, which is the same worthlessness as
#     two equal digests over two empty traces;
#   * `node --check` must parse it, so "20 MB of something" is not enough;
#   * five SYMBOLS must be present, each of which disappears if the wrong
#     configuration was built (see the marker table below);
#   * every top-level function name in it must be UNIQUE, counted here rather
#     than left to `js-bundle-name-uniqueness.sh` — that gate walks bundles
#     that already exist on disk, and these two are built to a temporary path
#     by a recipe a developer runs, so nothing else ever sees them.
#
# AND THE RECIPES THEMSELVES ARE CHECKED, because the cheapest way to make a
# build gate green is to delete the flags that make the build hard. Step 1 reads
# `justfile` and fails if a recipe stops passing `-d:ctInExtension`, stops
# naming `src/frontend/ui_js.nim`, or STARTS passing `--hotCodeReloading:on`
# again. Without the first two, someone could "fix" a red gate by turning it
# into a gate over the shipped configuration `renderer-browser-build.sh`
# already covers; without the third, the duplicate-name check below would go
# red with no explanation of what put the names there.
#
# Usage:  bash ci/test/renderer-extension-build.sh
# Env:    ISONIM_SRC  isonim source tree (else the ../isonim sibling)

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

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
}

echo "=== renderer extension/HMR build (the configuration a developer types) ==="
echo

# ---------------------------------------------------------------------------
# Step 0: prerequisites. EXIT 2, not a failure — an absent toolchain is a gate
# that did not run, and conflating that with a red gate is how a suite comes to
# "pass" on a machine that compiled nothing. Same rule as
# `renderer-browser-build.sh` step 0.
# ---------------------------------------------------------------------------
for tool in nim just node; do
	command -v "${tool}" >/dev/null 2>&1 || {
		echo "${tool} is not on PATH" >&2
		echo "  remedy: run inside the dev shell (direnv exec ${repo_root} ...)" >&2
		exit 2
	}
done

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
# build dies with an error naming neither this gate nor the file's purpose.
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

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/ct-renderer-ext.XXXXXX")"
trap 'rm -rf "${work_dir}"' EXIT

# ---------------------------------------------------------------------------
echo "Step 1: the recipes still build the configuration this gate is for"
echo "    A build gate is trivially made green by deleting the flags that make"
echo "    the build hard. These read justfile and fail if that happens."
# ---------------------------------------------------------------------------
recipe_body() {
	# The lines of a just recipe: from its `name ...:` header to the next line
	# that begins in column 0. Recipe bodies are indented, so this is exact.
	awk -v want="$1" '
		$0 ~ "^" want "( |:)" { inside = 1; next }
		inside && /^[^ \t]/    { inside = 0 }
		inside                  { print }
	' justfile
}

for recipe in build-ui-js build-ui-js-hmr; do
	body="$(recipe_body "${recipe}")"
	# The parse is asserted before anything is asserted ABOUT it: a recipe that
	# was renamed away yields an empty body, and every `grep -q` below would
	# then report a clean absence rather than a missing subject.
	if [ -n "${body}" ]; then
		ok "${recipe}: found the recipe in justfile ($(printf '%s\n' "${body}" | grep -c .) non-blank lines)"
	else
		bad "${recipe}: NOT FOUND in justfile — this gate has no subject"
		continue
	fi
	if grep -qF -- "src/frontend/ui_js.nim" <<<"${body}"; then
		ok "${recipe}: still compiles src/frontend/ui_js.nim"
	else
		bad "${recipe}: no longer compiles src/frontend/ui_js.nim — this gate has no subject"
	fi
	# The extension arm is gone (HSF-X2): the define now selects nothing in
	# `ui_js`, and a recipe passing it builds a configuration no one ships.
	if grep -qF -- "-d:ctInExtension" <<<"${body}"; then
		bad "${recipe}: passes -d:ctInExtension — the extension no longer loads the renderer (vscode_panel / vscode_host instead)"
	else
		ok "${recipe}: does not pass -d:ctInExtension"
	fi
	# The negative. `--hotCodeReloading:on` compiles fine and then emits 112
	# duplicated top-level function names into this bundle; the recipe comment
	# above `build-ui-js` carries the measurement. Caught here as well as by the
	# duplicate count in step 2, because the count says WHAT is wrong and this
	# says WHY.
	if grep -qF -- "--hotCodeReloading:on" <<<"${body}"; then
		bad "${recipe}: passes --hotCodeReloading:on again — it makes jsgen name routines with idOrSig and collide across modules; see the note above build-ui-js in justfile"
	else
		ok "${recipe}: does not pass --hotCodeReloading:on"
	fi
done
echo

# ---------------------------------------------------------------------------
echo "Step 2: each recipe produces a bundle, and the bundle is real"
# ---------------------------------------------------------------------------
# THE MARKER TABLE. Each is a symbol Nim must emit for the named thing to be in
# the bundle, and each vanishes under a DIFFERENT wrong build — which is what
# makes them evidence rather than decoration:
#
#   lastAgentPrompt                      a field of the renderer's `Data`; the
#                                        positive control for step 3, which
#                                        asserts the panel bundle lacks it.
#   resolvePendingDapResponse            called unconditionally by ui_js.nim's
#                                        onDapReceiveResponse; the identifier
#                                        that was undeclared in this arm.
#   __ui95js_                            Nim's module-mangled suffix for
#   __uiZtrace_                          `ui_js.nim` and `ui/trace.nim` — the
#                                        entry point and the module the codegen
#                                        fault was in. These are the markers
#                                        `renderer-browser-build.sh` uses, and
#                                        they are usable HERE ONLY BECAUSE
#                                        `--hotCodeReloading:on` is gone: under
#                                        that flag `mangleName` uses `idOrSig`
#                                        and emits no module-name suffix at
#                                        all, so all three would silently match
#                                        nothing. If step 1's negative ever
#                                        goes red, expect these to follow.
#
# `{.exportc.}` names survive verbatim; the rest are Nim-mangled prefixes.
markers=(
	lastAgentPrompt
	resolvePendingDapResponse
	__ui95js_
	__uiZtrace_
)

check_bundle() {
	local recipe="$1" out="$2"

	# Fresh path in a fresh directory: a stale artefact cannot be read as this
	# run's output, and "the recipe wrote nothing" cannot look like success.
	rm -f "${out}"
	local log rc
	log="$("${JUST:-just}" "${recipe}" "${out}" 2>&1)"
	rc=$?

	if [ ! -f "${out}" ]; then
		bad "${recipe}: NO ARTEFACT (recipe exit ${rc})"
		printf '%s\n' "${log}" | grep -E 'Error:' | head -3 | sed 's/^/      /'
		return 1
	fi
	# The exit status is reported, not trusted: it is checked here only so a
	# recipe that somehow left a file behind while failing is still red.
	if [ "${rc}" -ne 0 ]; then
		bad "${recipe}: wrote ${out} but exited ${rc}"
		printf '%s\n' "${log}" | grep -E 'Error:' | head -3 | sed 's/^/      /'
		return 1
	fi

	local size
	size="$(wc -c <"${out}" | tr -d ' ')"
	if [ "${size}" -gt 1000000 ]; then
		ok "${recipe}: artefact is non-trivial (${size} bytes > 1 MB)"
	else
		bad "${recipe}: artefact is only ${size} bytes — too small to be the renderer; every check below would be vacuous"
		return 1
	fi

	# Size alone does not mean the bytes are a program. A bundle truncated
	# mid-function is megabytes of unparseable text.
	if node --check "${out}" >/dev/null 2>&1; then
		ok "${recipe}: node parses the artefact as JavaScript"
	else
		bad "${recipe}: node --check REJECTED the artefact — it is not a loadable script"
	fi

	local marker
	for marker in "${markers[@]}"; do
		if grep -qa "${marker}" "${out}"; then
			ok "${recipe}: carries ${marker}"
		else
			bad "${recipe}: ${marker} is ABSENT — this is not the configuration the gate is for"
		fi
	done

	# ONE BUNDLE, ONE DEFINITION PER NAME — the same claim
	# `ci/test/js-bundle-name-uniqueness.sh` makes, made here because that gate
	# walks bundles on disk and these two are built to a temp path. Two
	# top-level `function foo` declarations are not a JS error: the last wins
	# and every caller of the first runs the second one's body, silently, until
	# the bodies differ. Counting names does not wait for a symptom.
	local total dups
	total="$(grep -c '^function [A-Za-z0-9_$]*(' "${out}")"
	# The count is asserted before it is used, so a pattern that matches
	# nothing cannot report zero duplicates and look like a clean bundle.
	if [ "${total}" -gt 1000 ]; then
		ok "${recipe}: ${total} top-level functions found, so the pattern matches this bundle"
	else
		bad "${recipe}: only ${total} top-level function(s) matched — the pattern is wrong and the duplicate count below would be vacuous"
	fi
	dups="$(grep -o '^function [A-Za-z0-9_$]*(' "${out}" | sort | uniq -d | grep -c . || true)"
	if [ "${dups}" -eq 0 ]; then
		ok "${recipe}: every top-level function name is unique"
	else
		bad "${recipe}: ${dups} duplicated top-level function name(s) of ${total} — one definition is silently replacing another; check for --hotCodeReloading being re-enabled (justfile) or a second {.exportc.} of the same name"
		grep -o '^function [A-Za-z0-9_$]*(' "${out}" | sort | uniq -d | head -5 | sed 's/^/      /'
	fi
	return 0
}

check_bundle build-ui-js "${work_dir}/ui.js"
echo
check_bundle build-ui-js-hmr "${work_dir}/ui-hmr.js"
echo

# ---------------------------------------------------------------------------
echo "Step 3: the VS Code extension's bundles (vscode_panel.js, vscode_host.js, ct_vscode.js)"
echo "    A panel webview loads vscode_panel.js alone: one panel's view over a"
echo "    mirror of the host's session. The renderer must not be in it."
# ---------------------------------------------------------------------------
check_extension_bundle() {
	local recipe="$1" out="$2" log rc size
	rm -f "${out}"
	log="$("${JUST:-just}" "${recipe}" "${out}" 2>&1)"
	rc=$?
	if [ ! -f "${out}" ] || [ "${rc}" -ne 0 ]; then
		bad "${recipe}: NO ARTEFACT (recipe exit ${rc})"
		printf '%s\n' "${log}" | grep -E 'Error:' | head -3 | sed 's/^/      /'
		return 1
	fi
	size="$(wc -c <"${out}" | tr -d ' ')"
	# Real bundles are megabytes; the floor only refuses an empty file, which
	# would satisfy every absence below vacuously.
	if [ "${size}" -gt 100000 ]; then
		ok "${recipe}: artefact is non-trivial (${size} bytes)"
	else
		bad "${recipe}: artefact is only ${size} bytes — every absence below would be vacuous"
		return 1
	fi
	if node --check "${out}" >/dev/null 2>&1; then
		ok "${recipe}: node parses the artefact as JavaScript"
	else
		bad "${recipe}: node --check REJECTED the artefact"
	fi
	return 0
}

# What must NOT be in the panel bundle, each by a name only it emits:
#   ui_js / types.nim   the renderer's entry module and its `Data` (Nim names
#                       a module's routines with its path: `__ui95js_`, and
#                       `types.nim`'s with `__types_`… under `frontend/`)
#   lastAgentPrompt     fields of the renderer's `Data`, so its type info
#   traceMonacoEditors
#   monaco / jquery     the editor and DOM libraries the renderer drives
if check_extension_bundle build-vscode-panel "${work_dir}/vscode_panel.js"; then
	panel="${work_dir}/vscode_panel.js"
	for absent in "ui_js.nim" "frontend/renderer.nim" "frontend/types.nim" "__ui95js_"; do
		if grep -qaF -- "${absent}" "${panel}"; then
			bad "vscode_panel.js: carries ${absent} — the renderer leaked into the panel bundle"
		else
			ok "vscode_panel.js: does not carry ${absent}"
		fi
	done
	for absent in monaco jquery jQuery; do
		if grep -qaw -- "${absent}" "${panel}"; then
			bad "vscode_panel.js: mentions ${absent} — a renderer library leaked into the panel bundle"
		else
			ok "vscode_panel.js: does not mention ${absent}"
		fi
	done
	# `Data`'s type info is numbered (`NTI<digits>`), so it is found by two of
	# its fields, which no other type declares; both are in `ui.js` (measured).
	if grep -qawE 'lastAgentPrompt|traceMonacoEditors' "${panel}"; then
		bad "vscode_panel.js: carries the renderer's Data type (lastAgentPrompt / traceMonacoEditors)"
	else
		ok "vscode_panel.js: does not carry the renderer's Data type"
	fi
	# And it IS the panel: the entry's own module and the mirror it builds.
	for present in "vscode_panel.nim" "mirror_session.nim"; do
		if grep -qaF -- "${present}" "${panel}"; then
			ok "vscode_panel.js: carries ${present}"
		else
			bad "vscode_panel.js: ${present} is ABSENT — this is not the panel bundle"
		fi
	done
fi
echo

if check_extension_bundle build-vscode-host "${work_dir}/vscode_host.js"; then
	host="${work_dir}/vscode_host.js"
	# The host is loaded with `require` by the extension; what it exports is
	# what `src/sessionHost.ts` calls.
	exports="$(node -e 'const m = require(process.argv[1]); console.log(Object.keys(m).sort().join(" "))' "${host}" 2>&1)"
	for name in ctHostCreate ctHostOpenSession ctHostDeliverEvent ctHostAttachWebview ctHostDeliverFromWebview ctHostDispose; do
		if grep -qw -- "${name}" <<<"${exports}"; then
			ok "vscode_host.js: exports ${name}"
		else
			bad "vscode_host.js: does not export ${name} (exports: ${exports})"
		fi
	done
	if grep -qaF -- "ui_js.nim" "${host}"; then
		bad "vscode_host.js: carries ui_js.nim — the host runs the session, not the renderer"
	else
		ok "vscode_host.js: does not carry ui_js.nim"
	fi
fi
echo

# The extension host's middleware runs in Node: loading it must not reach for
# `window` (codetracer-pm issue 2026-10-04-extension-central-node-bootstrap-…:
# the UI graph behind `ui/status` registered browser hooks at import).
if check_extension_bundle build-vscode-middleware "${work_dir}/ct_vscode.js"; then
	loaded="$(node -e 'const m = require(process.argv[1]); console.log(Object.keys(m).sort().join(" "))' "${work_dir}/ct_vscode.js" 2>&1)"
	if grep -qw -- "newDapVsCodeApi" <<<"${loaded}"; then
		ok "ct_vscode.js: loads under node and exports newDapVsCodeApi"
	else
		bad "ct_vscode.js: does not load under node: $(printf '%s\n' "${loaded}" | grep -m1 -E 'Error' || printf '%s' "${loaded}" | tail -c 200)"
	fi
fi
echo

# ---------------------------------------------------------------------------
echo "${checks} check(s), ${failures} failure(s)"
if [ "${checks}" -eq 0 ]; then
	echo "RESULT: FAILED — the gate asserted nothing at all"
	exit 1
fi
if [ "${failures}" -eq 0 ]; then
	echo "RESULT: OK — the developer renderer recipes and the VS Code extension bundles are what they claim to be"
	exit 0
fi
echo "RESULT: FAILED — ${failures} check(s)"
exit 1
