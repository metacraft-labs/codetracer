#!/usr/bin/env bash
#
# Every top-level function in a Nim-emitted JS bundle must have a unique
# name.
#
# WHY THIS EXISTS
#
# A single JS bundle is one script scope, so two top-level `function foo`
# declarations are not an error -- the LAST one silently wins and every
# caller of the first gets the second one's body.  Nim's JS backend can
# emit exactly that.  Under `--hotCodeReloading`, `jsgen.mangleName` names
# routines with `idOrSig` (compiler/sighashes.nim) instead of
# `mangleProcNameExt`: a hash of the routine's OWN signature plus a
# counter taken from `m.sigConflicts`, which lives on `BModule` and is
# therefore PER MODULE.  `mangleName` caches into `s.loc.snippet`, so each
# symbol is mangled once, against whichever module jsgen happened to be
# generating at that moment.
#
# An anonymous `proc()` closure inside a generic is the trap: its type
# never mentions the generic parameter, so every instantiation hashes
# identically.  When two modules each instantiate that generic from
# MODULE-LEVEL code, each is emitted during its own module's pass, each
# counter starts at zero, and both emit the same name.  (When everything
# is reached from one entry module's call graph the counter is shared and
# advances, which is why this does not reproduce in a small program.)
#
# That is how the editor stopped mounting: `createMemo[CapabilityRung]`
# ran another module's `createMemo[T]` body and copied an enum using a
# seven-field tuple's type descriptor, so `nimCopy` read an absent field
# as `undefined` and threw `undefined.slice(0)`.  See `repro.nim`, where
# `hotCodeReloadingOnValue` is off for the renderer bundles.
#
# WHY IT COUNTS NAMES RATHER THAN WAITING FOR A SYMPTOM
#
# Duplicate names alone are NOT sufficient for a fault.  If the colliding
# bodies happen to be equivalent, the wrong one wins and everything still
# works -- the corruption is latent until the bodies differ, which for
# `nimCopy` means until a hard-coded type descriptor differs.  "No crash"
# therefore does not mean "no collision", so this guard counts the names.

set -euo pipefail

ROOT_DIR=$(git rev-parse --show-toplevel)
cd "${ROOT_DIR}"

# Nim's JS backend stamps every generated frame with `framePtr`.  It is the
# discriminator rather than "has top-level functions", because third-party
# webpack output does too -- `public/dist/ts.worker.js` alone has 267 of
# them and is none of our business.
NIM_BUNDLE_MARKER='framePtr'

# Bundles that must exist and must be checked.  Without this list a
# detection bug -- a renamed build directory, a marker that stopped being
# emitted -- would find zero bundles, report zero duplicates, and look
# exactly like a clean tree.
#
# Scanning a full build tree demands the full set.  A caller pointing at
# some other directory (an assembled web bundle, a single artefact under
# test) only gets `ui.js` demanded, because the rest legitimately are not
# there -- but SOMETHING is still demanded, so the check can never pass by
# finding nothing.
build_dirs=()
for candidate in "$@"; do
	[ -n "${candidate}" ] && build_dirs+=("${candidate}")
done

if [ ${#build_dirs[@]} -eq 0 ]; then
	REQUIRED_BUNDLES="ui.js subwindow.js index.js server_index.js"
	for candidate in src/build-debug-repro src/build-debug; do
		[ -d "${candidate}" ] && build_dirs+=("${candidate}")
	done
else
	REQUIRED_BUNDLES="ui.js"
fi

if [ ${#build_dirs[@]} -eq 0 ]; then
	echo "FAIL: no build directory found (looked for src/build-debug-repro," >&2
	echo "      src/build-debug).  Build first, or pass one as an argument." >&2
	exit 1
fi

echo "Checking JS bundle name uniqueness in: ${build_dirs[*]}"

checked=0
failed=0
checked_names=""

while IFS= read -r bundle; do
	[ -n "${bundle}" ] || continue
	grep -q "${NIM_BUNDLE_MARKER}" "${bundle}" 2>/dev/null || continue

	# Both halves of a Nim proc are top-level: the `foo` dispatch wrapper
	# and the `fooIMLP` body.  Count declarations, not call sites.
	total=$(grep -c '^function [A-Za-z0-9_$]*(' "${bundle}" || true)
	total=${total:-0}

	if [ "${total}" -eq 0 ]; then
		# The marker said Nim emitted this, but the declaration pattern
		# matched nothing.  That is a broken instrument, not a clean
		# bundle, and it must fail loudly rather than score zero.
		echo "  FAIL ${bundle}: marker present but 0 top-level functions matched" >&2
		echo "       (the declaration pattern no longer matches Nim's output)" >&2
		failed=$((failed + 1))
		continue
	fi

	dups=$(grep -o '^function [A-Za-z0-9_$]*(' "${bundle}" | sort | uniq -d || true)
	dup_count=$(printf '%s' "${dups}" | grep -c . || true)
	dup_count=${dup_count:-0}

	checked=$((checked + 1))
	checked_names="${checked_names} $(basename "${bundle}")"

	if [ "${dup_count}" -ne 0 ]; then
		echo "  FAIL ${bundle}: ${dup_count} duplicated top-level function name(s) of ${total}" >&2
		printf '%s\n' "${dups}" | head -20 | sed 's/^/         /' >&2
		failed=$((failed + 1))
	else
		echo "  ok   ${bundle}: ${total} top-level functions, all unique"
	fi
done < <(find "${build_dirs[@]}" -type f -name '*.js' \
	-not -path '*/third_party/*' \
	-not -path '*/node_modules/*' \
	-not -path '*/public/dist/*' | sort)

if [ "${checked}" -eq 0 ]; then
	echo "FAIL: found no Nim-emitted bundles to check." >&2
	echo "      Either the build directory is empty or the '${NIM_BUNDLE_MARKER}'" >&2
	echo "      marker is gone.  A guard that checks nothing passes everything." >&2
	exit 1
fi

for required in ${REQUIRED_BUNDLES}; do
	case "${checked_names} " in
	*" ${required} "*) ;;
	*)
		echo "FAIL: expected bundle '${required}' was never checked." >&2
		echo "      It was not found, or it no longer carries the Nim marker." >&2
		failed=$((failed + 1))
		;;
	esac
done

if [ "${failed}" -ne 0 ]; then
	echo "" >&2
	echo "${failed} failure(s).  A duplicated name means one definition silently" >&2
	echo "replaced another and its callers now run the wrong body.  If this" >&2
	echo "started after a build change, check for '--hotCodeReloading' being" >&2
	echo "re-enabled on a JS bundle. TWO places set it, and repro.nim is only" >&2
	echo "one of them: repro.nim's hotCodeReloadingOnValue, and the justfile's" >&2
	echo "build-ui-js / build-ui-js-hmr recipes, which pass" >&2
	echo "--hotCodeReloading:on while compiling src/frontend/ui_js.nim." >&2
	exit 1
fi

echo "PASS: ${checked} Nim bundle(s) checked, no duplicated top-level function names."
