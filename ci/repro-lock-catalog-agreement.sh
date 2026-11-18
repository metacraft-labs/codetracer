#!/usr/bin/env bash
# repro-lock-catalog-agreement.sh — every lock in repro.lock's closure pins the
# same reprobuild-packages catalog as repro.lock itself.
#
#   ci/repro-lock-catalog-agreement.sh [<root repro.lock>] [<siblings root>]
#
# reprobuild compiles a solve's recipes against ONE package catalog, and it
# refuses a compile that would resolve catalog interfaces from two ("this
# compile would resolve reprobuild-packages interfaces from two catalogs"). So
# a sibling whose own repro.lock pins another reprobuild-packages revision than
# the root breaks every refresh of the root, and every platform re-solve. It
# did: the root pinned 2c58192a while runquota's lock pinned 15ceea67, and the
# arm64-macosx re-solve died on it.
#
# Reads <siblings root>/<name>/repro.lock for each member of the root entry's
# `depends` that is checked out there; a member that is not checked out is
# skipped (its absence is another check's business). Exits 1 naming every
# sibling whose catalog differs. bash builtins only, like the build-input
# selector: it runs where the siblings were just cloned.
set -euo pipefail

root_lock="${1:-repro.lock}"
siblings_root="${2:-..}"
[ -f "$root_lock" ] || {
	echo "repro-lock-catalog-agreement: no lock at $root_lock" >&2
	exit 2
}

catalog_rev() { # $1 = lock path -> the reprobuild-packages revision it pins, or ''
	local text
	text="$(<"$1")"
	local entry='name = "reprobuild-packages", coord_kind = "vcs", url = "[^"]*", revision = "([0-9a-f]{40})"'
	if [[ $text =~ $entry ]]; then
		echo "${BASH_REMATCH[1]}"
	fi
}

root_text="$(<"$root_lock")"
root_node='(self = "true"|path = "\.")[^}]*depends = "([^"]*)"'
[[ $root_text =~ $root_node ]] || {
	echo "repro-lock-catalog-agreement: $root_lock declares no develop set" >&2
	exit 2
}
IFS=',' read -r -a members <<<"${BASH_REMATCH[2]}"
want="$(catalog_rev "$root_lock")"
if [ -z "$want" ]; then
	echo "repro-lock-catalog-agreement: $root_lock pins no reprobuild-packages; nothing to agree with"
	exit 0
fi

# The catalog's package names, from the cloned reprobuild-packages beside the
# siblings. A sibling whose recipe uses one of them while its lock pins no
# catalog resolves it from an unpinned checkout, and reprobuild counts that as
# a second catalog too (io-mon's `patchelf`, against the root's pinned one).
catalog_names=()
for interface in "$siblings_root"/reprobuild-packages/packages/interfaces/*/; do
	[ -d "$interface" ] || continue
	interface="${interface%/}"
	catalog_names+=("${interface##*/}")
done

uses_catalog_package() { # $1 = recipe path -> prints the first catalog package it uses
	local recipe name
	recipe="$(<"$1")"
	for name in "${catalog_names[@]}"; do
		if [[ $recipe == *"\"$name\""* || $recipe == *"\"$name "* ]]; then
			echo "$name"
			return 0
		fi
	done
	return 1
}

checked=0
mismatches=()
for member in "${members[@]}"; do
	sibling_lock="$siblings_root/$member/repro.lock"
	[ -f "$sibling_lock" ] || continue
	got="$(catalog_rev "$sibling_lock")"
	if [ -z "$got" ]; then
		sibling_recipe="$siblings_root/$member/repro.nim"
		if [ -f "$sibling_recipe" ] && used="$(uses_catalog_package "$sibling_recipe")"; then
			mismatches+=("$member uses the catalog package '$used' but its lock pins no reprobuild-packages; $root_lock pins $want")
		fi
		continue
	fi
	checked=$((checked + 1))
	if [ "$got" != "$want" ]; then
		mismatches+=("$member pins reprobuild-packages $got, $root_lock pins $want")
	fi
done

if [ "${#mismatches[@]}" -gt 0 ]; then
	echo "repro-lock-catalog-agreement: ${#mismatches[@]} lock(s) in the closure disagree with the root's package catalog:" >&2
	printf '  %s\n' "${mismatches[@]}" >&2
	echo "  Move the older side forward: refresh that sibling's lock onto the root's catalog, or the root onto the sibling's." >&2
	exit 1
fi
echo "repro-lock-catalog-agreement: $checked sibling lock(s) pin reprobuild-packages ${want:0:12}, as the root does"
