#!/usr/bin/env bash
# =============================================================================
# require-runtime-assets.sh — fail, BY NAME, when a build produces a `ct` that
# cannot start.
#
# WHY THIS EXISTS
# ---------------
# `ct` reads its bundled defaults out of `<prefix>/config/` at runtime, where
# `<prefix>` is the directory above `bin/ct` — `codetracerPrefix` /`configDir`
# in `src/common/config.nim`. On a pristine user profile `loadConfig` COPIES
# `configDir/default_config.yaml` into the user's config directory before doing
# anything else, so a missing file there is not a degraded mode. It is:
#
#     Error: Unhandled exception
#       src/ct/cli/build.nim build
#       src/common/config.nim(159) loadConfig
#       .../std/private/osfiles.nim(241) copyFile
#     Unhandled No such file or directory
#     Additional info: <prefix>/config/default_config.yaml
#
# For as long as the tup branch existed, nothing published those two files into
# the variant tree. `src/Tupfile` asserted they arrived "via the variant source
# mirror" — the mirror reproduces the source DIRECTORY tree and copies no
# files, so `build-debug/config/` was created empty on every clean build and
# `tup` exited 0. Every downstream consumer had quietly grown its own `cp`
# (non-nix-build/windows/setup-codetracer-runtime-env.{ps1,sh},
# scripts/docs/deep-review-capture-lib.sh, and at least one milestone log in
# codetracer-specs). `src/config/Tupfile` is the fix; THIS script is what makes
# the next regression loud, at the end of the build, instead of in a stack
# trace on a user's first run.
#
# WHAT IT CHECKS
# --------------
# For every asset in the startup closure:
#   * the source of truth exists under `src/config/` and is non-empty;
#   * the built tree has it at `<out-root>/<config-dir>/<name>`, resolving
#     symlinks (tup's `!tup_preserve` publishes symlinks into the variant, and
#     that is a correct publication);
#   * it is non-empty; and
#   * it is byte-identical to the source.
#
# The asset NAMES ARE NOT HARDCODED HERE. They are read out of
# `src/common/config.nim` — the same `let` bindings the runtime uses — so a
# rename cannot leave this guard checking names nothing reads any more. A
# `config.nim` this script cannot parse is a hard failure with a named
# diagnostic, never a silent pass: a guard that quietly finds nothing to check
# is the exact failure mode it was written to end.
#
# Usage:
#   scripts/require-runtime-assets.sh <out-root> [--source-root DIR]
#
# `--source-root` exists so ci/test/require-runtime-assets-test.sh can drive
# the checks against synthetic trees. It is not used by the build.
#
# Lane: called at the end of scripts/build-once.sh on BOTH branches (tup and
#       reprobuild). Self-test: ci/test/require-runtime-assets-test.sh, run
#       from ci/lint/bash.sh.
# =============================================================================
set -euo pipefail

out_root=""
source_root=""

while [ $# -gt 0 ]; do
	case "$1" in
	--source-root)
		if [ $# -lt 2 ]; then
			echo "require-runtime-assets.sh: --source-root needs a directory" >&2
			exit 2
		fi
		source_root="$2"
		shift 2
		;;
	--source-root=*)
		source_root="${1#--source-root=}"
		shift
		;;
	-h | --help)
		sed -n '2,60p' "${BASH_SOURCE[0]}"
		exit 0
		;;
	-*)
		echo "require-runtime-assets.sh: unknown option: $1" >&2
		exit 2
		;;
	*)
		if [ -n "$out_root" ]; then
			echo "require-runtime-assets.sh: unexpected extra argument: $1" >&2
			exit 2
		fi
		out_root="$1"
		shift
		;;
	esac
done

if [ -z "$out_root" ]; then
	echo "require-runtime-assets.sh: no output root given" >&2
	echo "usage: scripts/require-runtime-assets.sh <out-root> [--source-root DIR]" >&2
	exit 2
fi

if [ -z "$source_root" ]; then
	source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

if [ ! -d "$source_root" ]; then
	echo "require-runtime-assets.sh: no such source root: $source_root" >&2
	exit 2
fi

config_nim="$source_root/src/common/config.nim"
asset_source_dir="$source_root/src/config"

# -----------------------------------------------------------------------------
# Read the contract out of the runtime's own source.
# -----------------------------------------------------------------------------
if [ ! -f "$config_nim" ]; then
	{
		echo "require-runtime-assets.sh: cannot read the runtime asset contract."
		echo "  expected: $config_nim"
		echo "  This script derives the required asset names from that file rather"
		echo "  than repeating them. Without it the check would pass vacuously, so"
		echo "  it fails instead."
	} >&2
	exit 1
fi

# `let configDir* = codetracerPrefix / "config"` -> the subdirectory name.
config_subdir="$(
	sed -n 's/^[[:space:]]*let[[:space:]]\{1,\}configDir\*\{0,1\}[[:space:]]*=[[:space:]]*codetracerPrefix[[:space:]]*\/[[:space:]]*"\([^"]*\)".*$/\1/p' \
		"$config_nim" | head -n 1
)"

# `let defaultConfigPath* = "default_config.yaml"` and its layout twin.
read_string_let() {
	sed -n "s/^[[:space:]]*let[[:space:]]\{1,\}$1\*\{0,1\}[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*$/\1/p" \
		"$config_nim" | head -n 1
}

default_config_name="$(read_string_let defaultConfigPath)"
default_layout_name="$(read_string_let defaultLayoutPath)"

missing_contract=""
[ -n "$config_subdir" ] || missing_contract="${missing_contract} configDir"
[ -n "$default_config_name" ] || missing_contract="${missing_contract} defaultConfigPath"
[ -n "$default_layout_name" ] || missing_contract="${missing_contract} defaultLayoutPath"

if [ -n "$missing_contract" ]; then
	{
		echo "require-runtime-assets.sh: could not read the runtime asset contract from"
		echo "  $config_nim"
		echo "  unparsed binding(s):${missing_contract}"
		echo
		echo "This script reads the asset names from the runtime's own source so a"
		echo "rename cannot leave it checking names nothing loads. If those bindings"
		echo "moved or changed shape, update the three \`sed\` expressions here in the"
		echo "same change. Failing is deliberate: a guard that silently finds nothing"
		echo "to check is worse than no guard."
	} >&2
	exit 1
fi

# -----------------------------------------------------------------------------
# Hashing, portably (Linux: sha256sum; macOS: shasum -a 256).
# -----------------------------------------------------------------------------
if command -v sha256sum >/dev/null 2>&1; then
	hash_of() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
	hash_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
	echo "require-runtime-assets.sh: neither sha256sum nor shasum is available" >&2
	exit 1
fi

# -----------------------------------------------------------------------------
# The checks.
# -----------------------------------------------------------------------------
failures=""
failure_count=0

fail() {
	failure_count=$((failure_count + 1))
	failures="${failures}  * $1"$'\n'
	shift
	while [ $# -gt 0 ]; do
		failures="${failures}      $1"$'\n'
		shift
	done
}

check_asset() {
	local name="$1"
	local src="$asset_source_dir/$name"
	local built="$out_root/$config_subdir/$name"

	if [ ! -f "$src" ]; then
		fail "$name" \
			"source of truth:  $src  -- DOES NOT EXIST" \
			"effect: there is nothing to publish; \`ct\` has no bundled default." \
			"fix:    restore the file, or -- if the asset really is gone -- remove" \
			"        its binding from src/common/config.nim, which is where this" \
			"        check reads the required names from."
		return
	fi
	if [ ! -s "$src" ]; then
		fail "$name" \
			"source of truth:  $src  -- IS EMPTY" \
			"effect: publishing it would still leave \`ct\` without a usable default."
		return
	fi

	if [ ! -e "$built" ]; then
		local how="DOES NOT EXIST"
		if [ -L "$built" ]; then
			how="IS A DANGLING SYMLINK (-> $(readlink "$built"))"
		fi
		fail "$name" \
			"built tree:  $built  -- $how" \
			"effect: \`ct\` dies on a pristine profile with an uncaught OSError from" \
			"        loadConfig (src/common/config.nim), naming this exact path." \
			"fix:    src/config/Tupfile publishes it on the tup branch and repro.nim" \
			"        (targets config-default-config-yaml / config-default-layout-json)" \
			"        on the reprobuild branch. One of them has stopped running."
		return
	fi
	if [ ! -f "$built" ]; then
		fail "$name" \
			"built tree:  $built  -- EXISTS BUT IS NOT A REGULAR FILE" \
			"effect: \`ct\` cannot read it; loadConfig fails the same way."
		return
	fi
	if [ ! -s "$built" ]; then
		fail "$name" \
			"built tree:  $built  -- IS EMPTY" \
			"effect: loadConfig parses an empty document and \`ct\` starts with no" \
			"        key bindings or defaults at all."
		return
	fi

	local src_hash built_hash
	src_hash="$(hash_of "$src")"
	built_hash="$(hash_of "$built")"
	if [ "$src_hash" != "$built_hash" ]; then
		fail "$name" \
			"built tree:  $built  -- CONTENT DIFFERS FROM SOURCE" \
			"source $src_hash  $src" \
			"built  $built_hash  $built" \
			"effect: the shipped default is a stale copy of a file that has since" \
			"        changed, so \`ct\` runs with defaults nobody reviewed." \
			"fix:    the publication rule is not re-running on change."
	fi
}

if [ ! -d "$out_root" ]; then
	{
		echo "require-runtime-assets.sh: the build output root does not exist:"
		echo "  $out_root"
		echo "Nothing was built, or the wrong tree was named."
	} >&2
	exit 1
fi

check_asset "$default_config_name"
check_asset "$default_layout_name"

if [ "$failure_count" -eq 0 ]; then
	echo "require-runtime-assets.sh: ok -- $out_root/$config_subdir/ carries" \
		"$default_config_name and $default_layout_name, both matching src/config/."
	exit 0
fi

{
	echo "The build did not publish ${failure_count} runtime asset(s) \`ct\` needs to start."
	echo
	echo "output root: $out_root"
	echo "config dir:  $out_root/$config_subdir  (from configDir in src/common/config.nim)"
	echo
	printf '%s' "$failures"
	cat <<'EOF'
`ct` reads these out of <prefix>/config/ where <prefix> is the directory above
bin/ct. On a machine with no ~/.config/codetracer/.config.yaml yet, loadConfig
COPIES default_config.yaml there before doing anything else, so a missing file
is an uncaught OSError on first run -- not a fallback.

The build exiting 0 with these absent is the defect this check exists to catch.
EOF
} >&2
exit 1
