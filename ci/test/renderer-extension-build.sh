#!/usr/bin/env bash
#
# renderer-extension-build.sh — the DEVELOPER renderer build produces a bundle.
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
		ok "${recipe}: found the recipe in justfile ($(printf '%s\n' "${body}" | grep -c . ) non-blank lines)"
	else
		bad "${recipe}: NOT FOUND in justfile — this gate has no subject"
		continue
	fi
	for flag in "-d:ctInExtension" "src/frontend/ui_js.nim"; do
		if printf '%s\n' "${body}" | grep -qF -- "${flag}"; then
			ok "${recipe}: still passes ${flag}"
		else
			bad "${recipe}: no longer passes ${flag} — either restore it, or delete this gate and say why the configuration stopped existing"
		fi
	done
	# The negative. `--hotCodeReloading:on` compiles fine and then emits 112
	# duplicated top-level function names into this bundle; the recipe comment
	# above `build-ui-js` carries the measurement. Caught here as well as by the
	# duplicate count in step 2, because the count says WHAT is wrong and this
	# says WHY.
	if printf '%s\n' "${body}" | grep -qF -- "--hotCodeReloading:on"; then
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
#   makeTracepointComponentForExtension  `{.exportc.}` in ui/trace.nim, and the
#                                        very routine whose eager code
#                                        generation used to abort this build.
#                                        Absent without -d:ctInExtension.
#   newDapVsCodeApi                      `{.exportc.}` in dap.nim's extension
#                                        arm. Absent without -d:ctInExtension.
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
	makeTracepointComponentForExtension
	newDapVsCodeApi
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
echo "${checks} check(s), ${failures} failure(s)"
if [ "${checks}" -eq 0 ]; then
	echo "RESULT: FAILED — the gate asserted nothing at all"
	exit 1
fi
if [ "${failures}" -eq 0 ]; then
	echo "RESULT: OK — the developer renderer build produces a real bundle on both recipes"
	exit 0
fi
echo "RESULT: FAILED — ${failures} check(s)"
exit 1
