#!/usr/bin/env bash
# =============================================================================
# The Windows tree-sitter contribution repro.nim imports targets the interface
# of the tree-sitter package that the pinned reprobuild's stdlib declares.
#
# ## The defect this exists to catch
#
# reprobuild-packages carries two contributions for the one stdlib
# `tree-sitter` package, each pinned to one interface fingerprint:
#
#   packages/contributions/tree-sitter             the CLI-only interface
#                                                  (615a1cf7...)
#   packages/contributions/tree-sitter-generation  the interface with the typed
#                                                  `generate` operation
#                                                  (882b1e92...)
#
# The stdlib gained `generate` in reprobuild 3fcce13ee (first tagged v0.2.19),
# so every reprobuild this repository has pinned since computes 882b1e92. But
# repro.nim kept importing the CLI-only contribution, under
# `when defined(windows)`, so only Windows extracted it, and every Windows dev
# env stopped with
#
#   provisioning contribution interface mismatch for package "tree-sitter"
#   from "github:metacraft-labs/reprobuild-packages": expected 615a1cf7...,
#   active 882b1e92...
#
# The fingerprint is not platform-dependent; Linux computes 882b1e92 too. It
# never imports the contribution, so no Linux job could see the mismatch.
#
# ## The rule, read from the pinned trees
#
# The catalog's own rule (its README, and `ExpectedSourceTreeSitterFingerprint`
# in tests/tree_sitter_contribution_support.nim): the stdlib interface has the
# `generate` operation exactly when `subcmd "generate"` is declared in
# `libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/tree_sitter.nim`. Then
# repro.nim must import `tree-sitter-generation`; otherwise `tree-sitter`. The
# imported module's `interfaceFingerprint` must also be the fingerprint the
# catalog's support file names for that interface, so a catalog that re-pins
# either module is checked too.
#
# A static check, like scripts/test-reprobuild-catalog-coverage.sh: computing
# the fingerprint needs the recipe compiled for Windows, and this reads text
# from the two pinned trees on any host.
#
# ## Inputs
#
#   CT_TS_CONTRIBUTION_REPO_ROOT       the codetracer checkout (default: this one)
#   CT_TS_CONTRIBUTION_REPROBUILD_SRC  reprobuild source tree (default: the
#                                      flake's `reprobuild` input, via nix)
#   CT_TS_CONTRIBUTION_CATALOG_ROOT    reprobuild-packages tree (default: the
#                                      flake's `reprobuild-packages` input)
#   CT_TS_CONTRIBUTION_STRICT=1        a skip (no nix to locate an input) fails
#
#   bash ci/test/repro-tree-sitter-contribution-matches-stdlib.sh
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
REPO_ROOT="${CT_TS_CONTRIBUTION_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
STRICT="${CT_TS_CONTRIBUTION_STRICT:-0}"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

skip() {
	if [ "$STRICT" = "1" ]; then
		echo "FAIL (CT_TS_CONTRIBUTION_STRICT=1): $*" >&2
		exit 1
	fi
	echo "SKIP: $*" >&2
	echo "SKIP: the tree-sitter contribution pin was NOT verified by this run." >&2
	exit 0
}

flake_input_path() {
	local input="$1" out rc err
	command -v nix >/dev/null 2>&1 ||
		skip "\`nix\` is not on PATH, so the flake's '$input' input cannot be located."
	case "$REPO_ROOT" in
	*'"'* | *"\\"* | *'$'*) fail "repo root '$REPO_ROOT' contains a character this script will not splice into a Nix expression." ;;
	esac
	err="$(mktemp)"
	out="$(nix eval --raw --impure --expr \
		"(builtins.getFlake \"$REPO_ROOT\").inputs.\"$input\".outPath" 2>"$err")"
	rc=$?
	if [ "$rc" -ne 0 ] || [ ! -d "$out" ]; then
		local diag
		diag="$(cat "$err")"
		rm -f "$err"
		fail "could not locate the flake's '$input' input (nix eval exited $rc):
$diag"
	fi
	rm -f "$err"
	printf '%s\n' "$out"
}

REPROBUILD_SRC="${CT_TS_CONTRIBUTION_REPROBUILD_SRC:-}"
if [ -z "$REPROBUILD_SRC" ]; then
	REPROBUILD_SRC="$(flake_input_path reprobuild)" || exit 1
	[ -n "$REPROBUILD_SRC" ] || exit 0
fi
CATALOG_ROOT="${CT_TS_CONTRIBUTION_CATALOG_ROOT:-}"
if [ -z "$CATALOG_ROOT" ]; then
	CATALOG_ROOT="$(flake_input_path reprobuild-packages)" || exit 1
	[ -n "$CATALOG_ROOT" ] || exit 0
fi

recipe="$REPO_ROOT/repro.nim"
stdlib="$REPROBUILD_SRC/libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/tree_sitter.nim"
support="$CATALOG_ROOT/tests/tree_sitter_contribution_support.nim"
for f in "$recipe" "$stdlib" "$support"; do
	[ -f "$f" ] || fail "$f does not exist; nothing was judged."
done

# The contributions repro.nim imports, in any `when` branch.
imports="$(grep -oE '^[[:space:]]*import[[:space:]]+"\.\./reprobuild-packages/packages/contributions/tree-sitter[a-z-]*/repro"' "$recipe" |
	sed -E 's#.*/contributions/([a-z-]+)/repro"#\1#')"
count="$(printf '%s\n' "$imports" | grep -c . || true)"
[ "$count" -eq 1 ] ||
	fail "repro.nim should import exactly one tree-sitter contribution from reprobuild-packages; found $count: ${imports:-none}"

if grep -qE '^[[:space:]]*subcmd[[:space:]]+"generate"' "$stdlib"; then
	want="tree-sitter-generation"
	const="GeneratingTreeSitterFingerprint"
	# shellcheck disable=SC2016 # literal backticks: a markdown code span
	interface='the interface with the typed `generate` operation'
else
	want="tree-sitter"
	const="LegacyTreeSitterFingerprint"
	interface="the CLI-only interface"
fi
[ "$imports" = "$want" ] ||
	fail "repro.nim imports reprobuild-packages/packages/contributions/$imports, but the pinned reprobuild's stdlib declares $interface ($stdlib), which only contributions/$want targets. Windows extraction refuses the other with \"provisioning contribution interface mismatch for package \\\"tree-sitter\\\"\". Import contributions/$want instead."

module="$CATALOG_ROOT/packages/contributions/$want/repro.nim"
[ -f "$module" ] || fail "$module does not exist."
pinned="$(grep -oE '^[[:space:]]*interfaceFingerprint[[:space:]]+"[0-9a-f]{64}"' "$module" | grep -oE '[0-9a-f]{64}')"
expected="$(grep -oE "^const $const\\* = \"[0-9a-f]{64}\"" "$support" | grep -oE '[0-9a-f]{64}')"
[ -n "$pinned" ] || fail "$module pins no interfaceFingerprint this script can read."
[ -n "$expected" ] || fail "$support defines no $const this script can read."
[ "$pinned" = "$expected" ] ||
	fail "contributions/$want pins interface $pinned, but the catalog names $expected for $interface ($support)."

echo "ok: repro.nim imports contributions/$want, pinned to $pinned, the interface the pinned stdlib declares"
