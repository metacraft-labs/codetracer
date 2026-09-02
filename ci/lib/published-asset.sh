# shellcheck shell=bash
#
# published-asset.sh — find a bundle's copy of an asset whose name carries a
# content digest.
#
# WHY THIS EXISTS
# ---------------
# `ci/test/web-bundle-assets.sh` publishes `assets/wasm-worker.js` as
# `assets/wasm-worker.<16 hex>.js`, so that `immutable` is true of the URL. Six
# files got that treatment and every gate that knew one of them by name stopped
# being able to find it. Counted before the change, across four scripts and one
# Nim harness: two hard aborts, four mutation arms whose `rm -f` and `sed`
# became silent no-ops, and three predicates that answered "no" forever while
# the product was working.
#
# The tempting fix — write the hashed name into each gate — is the defect
# again with an extra step, because the digest changes with the bytes. So no
# gate spells a published name. They ask for one by its MANIFEST path and get
# the file that is actually there.
#
# WHY IT REFUSES RATHER THAN RETURNS EMPTY
# ----------------------------------------
# A resolver that answers "" for a missing file turns every caller into a
# potential silent pass: `rm -f ""` succeeds, `shasum ""` prints nothing, and
# `ckeq "" ""` — measured in `wasm-worker-session.sh` — compares two empty
# strings and reports that the served worker is byte-identical to the published
# one. Every function here fails loudly and returns non-zero, and callers are
# expected to treat that as fatal.
#
# Two matches is also a failure, and not a pedantic one: it means a previous
# assembly's copy is still in the tree under a different digest, and picking
# either would grade a file this run did not produce. That is the same stale
# artefact that made `web-bundle-assets.sh` report "required and present" over
# a module it had never placed.
#
# Usage:
#   source ci/lib/published-asset.sh
#   worker="$(published_asset "${bundle}" assets/wasm-worker.js)" || exit 1
#   url="/$(published_asset_rel "${bundle}" assets/wasm-worker.js)" || exit 1

# published_asset_rel BUNDLE STEM
#   Print the bundle-relative path of the published file whose name is STEM
#   with a digest inserted before its extension — or STEM itself, if the bundle
#   still holds an undigested copy. Exactly one match is required.
published_asset_rel() {
	local bundle="$1" stem="$2"
	local dir base ext prefix
	dir="$(dirname "${stem}")"
	base="$(basename "${stem}")"
	ext="${base##*.}"
	prefix="${base%.*}"

	local matches=() candidate
	# The undigested name first, so a bundle assembled by an older revision of
	# the assembly step still resolves rather than reporting nothing.
	if [ -f "${bundle}/${stem}" ]; then
		matches+=("${stem}")
	fi
	# NO `nullglob`, deliberately. An unmatched glob expands to the literal
	# pattern in bash, and `[ -f ]` rejects it — so the guard that is needed
	# anyway is the whole answer, and setting a shell option means restoring it,
	# which means a caller's glob behaviour depends on whether this function
	# returned through its success path.
	for candidate in "${bundle}/${dir}/${prefix}".*."${ext}"; do
		[ -f "${candidate}" ] || continue
		matches+=("${candidate#"${bundle}"/}")
	done

	if [ "${#matches[@]}" -eq 1 ]; then
		printf '%s\n' "${matches[0]}"
		return 0
	fi
	if [ "${#matches[@]}" -eq 0 ]; then
		echo "published-asset: ${bundle} holds no copy of ${stem}, digested or not" >&2
		return 1
	fi
	echo "published-asset: ${bundle} holds ${#matches[@]} copies of ${stem} — a previous assembly's file is still in the tree and grading either one would grade bytes this run did not produce:" >&2
	printf '  %s\n' "${matches[@]}" >&2
	return 1
}

# published_asset BUNDLE STEM — the same, as an absolute path.
published_asset() {
	local rel
	rel="$(published_asset_rel "$1" "$2")" || return 1
	printf '%s\n' "$1/${rel}"
}

# published_asset_url BUNDLE STEM — the same, as the URL a browser requests.
published_asset_url() {
	local rel
	rel="$(published_asset_rel "$1" "$2")" || return 1
	printf '/%s\n' "${rel}"
}
