#!/usr/bin/env bash
#
# Contract suite for scripts/test-reprobuild-catalog-coverage.sh.
#
# The guard asserts that every name in repro.nim's `uses:` list resolves
# against the `reprobuild-packages` catalog the flake pins, by reprobuild's own
# rule: catalog interface, else bundled-and-not-moved stdlib selector, else
# workspace producer (a repro.lock dep). It also asserts that flake.lock and
# repro.lock pin the catalog at the same revision.
#
# This suite drives the REAL script over throwaway fixture trees — a repo root
# (repro.nim, flake.lock, repro.lock), a reprobuild source tree carrying the two
# lists, and a catalog — through the script's CT_CATALOG_COVERAGE_* overrides.
# No mock stands in for the script or for python3; the fixtures replace only
# the three inputs the script would otherwise locate with `nix eval`, which is
# what lets this run in the lint shell in well under a second with no network.
#
# The first case after the positive control reconstructs the defect the guard
# was written for (codetracer-pm issue 2026-10-13, "the codetracer dev shell
# pins a package catalog that predates shellcheck"): a catalog holding only
# busybox, llvm, patchelf and sqlite3 — the real 9d9176bff5c5 listing — while
# the recipe uses shellcheck and reprobuild lists shellcheck as moved.
#
# As in ci/test/flake-pin-alignment-test.sh, every failure case asserts two
# things: that the RIGHT diagnostic appears, and that the WRONG one does not.
# For the extraction cases the wrong one is the "move the pin" remedy: a parser
# that rotted must never send a reader to edit a correct pin.
#
# Pure bash + python3. No real nix (one case stands in a stub `nix`; it says
# why), no git, no network.
#
# Run: bash ci/test/reprobuild-catalog-coverage-test.sh

# The diagnostics this suite asserts on quote Nim and TOML source in markdown code spans,
# so single-quoted strings full of literal backticks are the norm here, and
# shfmt -s rewrites the escaped double-quoted form into exactly that.
# shellcheck disable=SC2016
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$REPO_ROOT/scripts/test-reprobuild-catalog-coverage.sh"

[ -f "$GUARD" ] || {
	echo "FAIL: the script under test is missing: $GUARD" >&2
	exit 1
}

BASH_ABS="$(command -v bash)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

PASS=0
FAILED=0

ok() {
	PASS=$((PASS + 1))
	echo "  ok   $1"
}

bad() {
	FAILED=$((FAILED + 1))
	echo "  FAIL $1" >&2
	if [ $# -gt 1 ]; then
		printf '       %s\n' "$2" >&2
	fi
}

assert_contains() {
	case "$2" in
	*"$3"*) ok "$1" ;;
	*) bad "$1" "expected to find: $3" ;;
	esac
}

assert_absent() {
	case "$2" in
	*"$3"*) bad "$1" "expected NOT to find, but did: $3" ;;
	*) ok "$1" ;;
	esac
}

assert_rc() {
	if [ "$2" -eq "$3" ]; then
		ok "$1"
	else
		bad "$1" "rc=$2, expected $3"
	fi
}

CAT_REV=4e2fd1dcabf8ae8eac28a2d27c3160233589c1e6
OTHER_REV=9d9176bff5c5aee175efcaa5d667c9ed7b9b8043

# The remedy text that must NEVER appear when the guard did not judge a name.
PIN_REMEDY='move the `reprobuild-packages` url in flake.nix'

# write_flake_lock <path> <catalog-rev>
write_flake_lock() {
	cat >"$1" <<EOF
{
  "nodes": {
    "root": { "inputs": { "reprobuild-packages": "reprobuild-packages" } },
    "reprobuild-packages": {
      "flake": false,
      "locked": { "rev": "$2", "type": "github", "owner": "metacraft-labs", "repo": "reprobuild-packages" }
    }
  },
  "root": "root",
  "version": 7
}
EOF
}

# write_repro_lock <path> <catalog-rev> [<extra dep name>...]
# One `deps = [...]` line of flat inline tables, the shape repro.lock carries.
write_repro_lock() {
	local path="$1" rev="$2" deps="" name
	shift 2
	for name in "$@"; do
		deps="$deps{ name = \"$name\", coord_kind = \"vcs\", url = \"https://example.invalid/$name\", ref = \"agents\", revision = \"1111111111111111111111111111111111111111\", depends = \"\" }, "
	done
	deps="$deps{ name = \"reprobuild-packages\", coord_kind = \"vcs\", url = \"https://github.com/metacraft-labs/reprobuild-packages\", ref = \"agents\", revision = \"$rev\", depends = \"\" }"
	cat >"$path" <<EOF
schema = "reprobuild.solved-graph-lock.v3"

[lock]
platform = "amd64-linux"
packages = [{ name = "bash", version = "4.0.0", source = "bash", selection = "selected" }]
deps = [$deps]
EOF
}

# The recipe: names in every branch shape the real one uses, plus the comment
# forms the parser must ignore (a commented-out entry and a trailing comment
# that itself contains a quoted name).
write_recipe() {
	cat >"$1" <<'EOF'
import repro_dsl_stdlib

const Unrelated = ["not-a-use"]

package codeTracer:
  defaultToolProvisioning "nix"

  # A comment above the block: uses: "commented-above >=0"
  uses:
    "bash >=4"
    "nim >=1.6 <3.0"   # trailing: uses: "trailing-comment-name >=0"
    # "commented-out-name >=0"

    "isonim >=0"

    when defined(windows):
      "nsis >=3"

    when not defined(windows):
      "shellcheck >=0"
      "sqlite3 >=0"
    when defined(linux):
      "xdotool >=0"

  devEnv:
    activity "default"
    let s = "not-a-use-either"
EOF
}

# make_reprobuild <dir> [bundled-extra...]: the two lists, in the current
# shape and files (macros_a.nim, reprobuild_packages_catalog.nim).
make_reprobuild() {
	local dir="$1" extra="" name
	shift
	for name in "$@"; do
		extra="$extra  \"$name\",
"
	done
	local dsl="$dir/libs/repro_project_dsl/src/repro_project_dsl"
	mkdir -p "$dsl"
	cat >"$dsl/macros_a.nim" <<EOF
const BundledStdlibSelectors* = [
  "bash",
  # a comment inside the list: "commented-bundled"
  "nim",
  "nsis",
$extra  "xdotool"
  ]
  ## doc comment after the list: "doc-bundled"
EOF
	cat >"$dsl/reprobuild_packages_catalog.nim" <<'EOF'
const MovedToReprobuildPackages*: seq[string] =
  @["sqlite3", "shellcheck", "shfmt", "prek"]
  ## Names the bundled stdlib USED to define.
EOF
}

# make_catalog <dir> <name>...
make_catalog() {
	local dir="$1" name
	shift
	mkdir -p "$dir/packages/interfaces"
	for name in "$@"; do
		mkdir -p "$dir/packages/interfaces/$name"
		echo "package $name:" >"$dir/packages/interfaces/$name/repro.nim"
	done
}

# insert_after <file> <exact line> <new line>: portable (BSD and GNU sed
# disagree on `\n` in a replacement, and this suite runs on both).
insert_after() {
	local file="$1" match="$2" new="$3" line out=""
	while IFS= read -r line || [ -n "$line" ]; do
		out="$out$line
"
		if [ "$line" = "$match" ]; then
			out="$out$new
"
		fi
	done <"$file"
	printf '%s' "$out" >"$file"
}

# make_case <dir>: a fully resolving fixture. Callers then break one thing.
make_case() {
	local c="$1"
	mkdir -p "$c/repo"
	write_recipe "$c/repo/repro.nim"
	write_flake_lock "$c/repo/flake.lock" "$CAT_REV"
	write_repro_lock "$c/repo/repro.lock" "$CAT_REV" isonim
	make_reprobuild "$c/rb"
	make_catalog "$c/cat" busybox llvm patchelf shellcheck sqlite3
}

# run_case <dir> [env assignments...]
run_case() {
	local c="$1"
	shift
	env CT_CATALOG_COVERAGE_REPO_ROOT="$c/repo" \
		CT_CATALOG_COVERAGE_REPROBUILD_SRC="$c/rb" \
		CT_CATALOG_COVERAGE_CATALOG_ROOT="$c/cat" \
		"$@" bash "$GUARD" 2>&1
}

echo
echo "positive control: every name resolves, by each of the three routes"

C="$TMP/ok"
make_case "$C"
OUT="$(run_case "$C")"
RC=$?
assert_rc "a resolving recipe exits 0" "$RC" 0
assert_contains "it says so" "$OUT" "OK: all 7 uses: entries"
assert_contains "catalog route used" "$OUT" "resolved, catalog:  shellcheck, sqlite3"
assert_contains "bundled route used, all branches read" "$OUT" "resolved, bundled:  bash, nim, nsis, xdotool"
assert_contains "workspace route used" "$OUT" "resolved, workspace: isonim"
assert_absent "a commented-out entry is not read" "$OUT" "commented-out-name"
assert_absent "a trailing comment is not read" "$OUT" "trailing-comment-name"
assert_absent "a comment outside the block is not read" "$OUT" "commented-above"
assert_absent "a string outside the package is not read" "$OUT" "not-a-use"
assert_contains "both pins are reported" "$OUT" "flake.lock $CAT_REV, repro.lock $CAT_REV"

echo
echo "THE ISSUE: a catalog that predates shellcheck, which reprobuild lists as moved"

C="$TMP/issue"
make_case "$C"
rm -rf "$C/cat"
make_catalog "$C/cat" busybox llvm patchelf sqlite3 # reprobuild-packages @ 9d9176bff5c5
OUT="$(run_case "$C")"
RC=$?
assert_rc "the stale catalog exits 1" "$RC" 1
assert_contains "it names shellcheck" "$OUT" 'names `shellcheck`, which does not resolve'
assert_contains "it names the recipe line" "$OUT" 'repro.nim:20 `uses: "shellcheck >=0"`'
assert_contains "it names the branch" "$OUT" "[(not defined(windows))]"
assert_contains "it names the interface path it looked for" "$OUT" "no packages/interfaces/shellcheck/repro.nim"
assert_contains "it names the catalog it looked in" "$OUT" "looked in: $C/cat/packages/interfaces"
assert_contains "it names the pinned revision" "$OUT" "reprobuild-packages @ $CAT_REV"
assert_contains "it says why the stdlib does not cover it" "$OUT" "MovedToReprobuildPackages"
assert_contains "it gives the pin remedy" "$OUT" "$PIN_REMEDY"
assert_contains "and keeps repro.lock in step" "$OUT" "repro lock update reprobuild-packages"
assert_absent "sqlite3, which the old catalog had, is not accused" "$OUT" 'names `sqlite3`'
assert_contains "exactly one problem" "$OUT" "FAIL: 1 problem(s)"

echo
echo "a moved name fails even when the stdlib still lists a module of that name"

C="$TMP/stub"
make_case "$C"
rm -rf "$C/rb" "$C/cat"
make_reprobuild "$C/rb" shellcheck
mkdir -p "$C/rb/libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages"
echo '{.error: "moved to reprobuild-packages; drop the import and rely on uses:".}' \
	>"$C/rb/libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/shellcheck.nim"
make_catalog "$C/cat" sqlite3
OUT="$(run_case "$C")"
RC=$?
assert_rc "a moved-and-bundled name the catalog lacks exits 1" "$RC" 1
assert_contains "it is named" "$OUT" 'names `shellcheck`, which does not resolve'
assert_contains "and the stub is called a stub" "$OUT" "import stub, not a package"

echo
echo "a name nothing provides fails; a workspace producer does not"

C="$TMP/unknown"
make_case "$C"
insert_after "$C/repo/repro.nim" '    "bash >=4"' '    "no-such-tool >=0"'
OUT="$(run_case "$C")"
RC=$?
assert_rc "an unprovided name exits 1" "$RC" 1
assert_contains "it is named" "$OUT" 'names `no-such-tool`'
assert_contains "it is not called moved" "$OUT" "not one of reprobuild's BundledStdlibSelectors"
assert_contains "the recipe-side remedy is offered" "$OUT" "fix repro.nim instead"

write_repro_lock "$C/repo/repro.lock" "$CAT_REV" isonim no-such-tool
OUT="$(run_case "$C")"
RC=$?
assert_rc "the same name as a repro.lock dep exits 0" "$RC" 0
assert_contains "and resolves as a workspace producer" "$OUT" "resolved, workspace: no-such-tool, isonim"

C="$TMP/noproducer"
make_case "$C"
write_repro_lock "$C/repo/repro.lock" "$CAT_REV"
OUT="$(run_case "$C")"
RC=$?
assert_rc "a workspace name that left repro.lock exits 1" "$RC" 1
assert_contains "it is named" "$OUT" 'names `isonim`'

echo
echo "a name only one platform reaches is still checked"

C="$TMP/windows-only"
make_case "$C"
rm -rf "$C/rb"
make_reprobuild "$C/rb"
sed -i.bak 's/^  "nsis",$//' "$C/rb/libs/repro_project_dsl/src/repro_project_dsl/macros_a.nim"
OUT="$(run_case "$C")"
RC=$?
assert_rc "a Windows-only unresolved name exits 1 on any host" "$RC" 1
assert_contains "it is named with its branch" "$OUT" '"nsis >=3"` [(defined(windows))]'

echo
echo "buildDeps:, nativeBuildDeps: and runtimeDeps: are read like uses:"

# reprobuild resolves all four package-level lists by name, and its moved-name
# diagnostic fails the compile for a moved package in any of them; Nim's
# style-insensitivity means `native_build_deps:` is the same block. Each case
# moves the catalog-only `shfmt` into one of them, against a catalog without it.
for SPEC in buildDeps:buildDeps nativeBuildDeps:nativeBuildDeps \
	runtimeDeps:runtimeDeps native_build_deps:nativeBuildDeps; do
	BLOCK="${SPEC%%:*}"
	LIST="${SPEC#*:}"
	C="$TMP/block-$BLOCK"
	make_case "$C"
	# The new block goes directly before `devEnv:`, at package-body level.
	python3 - "$C/repo/repro.nim" "$BLOCK" <<'EOF'
import sys
path, block = sys.argv[1:3]
text = open(path).read()
assert text.count("  devEnv:\n") == 1
text = text.replace("  devEnv:\n", "  %s:\n    \"shfmt >=0\"\n  devEnv:\n" % block)
open(path, "w").write(text)
EOF
	OUT="$(run_case "$C")"
	RC=$?
	assert_rc "$BLOCK: a moved name the catalog lacks exits 1" "$RC" 1
	assert_contains "$BLOCK: it is named with its canonical list" "$OUT" \
		"\`$LIST: \"shfmt >=0\"\` [all platforms] names \`shfmt\`"
	make_catalog "$C/cat" shfmt
	OUT="$(run_case "$C")"
	RC=$?
	assert_rc "$BLOCK: with the catalog carrying it, exits 0" "$RC" 0
	assert_contains "$BLOCK: and it resolves from the catalog" "$OUT" "resolved, catalog:  shellcheck, sqlite3, shfmt"
done

echo
echo "the two pins of the catalog must agree"

C="$TMP/lockdrift"
make_case "$C"
write_repro_lock "$C/repo/repro.lock" "$OTHER_REV" isonim
OUT="$(run_case "$C")"
RC=$?
assert_rc "flake.lock and repro.lock disagreeing exits 1" "$RC" 1
assert_contains "it says they disagree" "$OUT" "the two pins of the catalog disagree"
assert_contains "it names flake.lock's rev" "$OUT" "rev      = $CAT_REV"
assert_contains "it names repro.lock's rev" "$OUT" "revision = $OTHER_REV"
assert_absent "no name is accused" "$OUT" "which does not resolve"

C="$TMP/locknocat"
make_case "$C"
cat >"$C/repo/repro.lock" <<'EOF'
deps = [{ name = "isonim", revision = "1111111111111111111111111111111111111111" }]
EOF
OUT="$(run_case "$C")"
RC=$?
assert_rc "repro.lock without a catalog dep exits 1" "$RC" 1
assert_contains "it says so" "$OUT" 'repro.lock has no `reprobuild-packages` dep'

echo
echo "implausible extraction fails as THAT, and never accuses the pin"

# expect_extraction <label> <case dir> <expected message>
expect_extraction() {
	local out rc
	out="$(run_case "$2")"
	rc=$?
	assert_rc "$1: exits 2" "$rc" 2
	assert_contains "$1: says what could not be read" "$out" "$3"
	assert_contains "$1: says nothing was judged" "$out" "no uses: name was judged"
	assert_absent "$1: does not give the pin remedy" "$out" "$PIN_REMEDY"
	assert_absent "$1: does not accuse a name" "$out" "which does not resolve"
	assert_absent "$1: does not claim a pass" "$out" "OK: all"
}

C="$TMP/nouses"
make_case "$C"
cat >"$C/repo/repro.nim" <<'EOF'
package codeTracer:
  defaultToolProvisioning "nix"
  devEnv:
    activity "default"
EOF
expect_extraction "zero uses: names" "$C" 'parsed ZERO names from the `uses:` block'

C="$TMP/nopackage"
make_case "$C"
sed -i.bak 's/^package codeTracer:/package somethingElse:/' "$C/repo/repro.nim"
expect_extraction "no package block" "$C" 'has no `package codeTracer:` block'

C="$TMP/oddline"
make_case "$C"
insert_after "$C/repo/repro.nim" '    "bash >=4"' '    SomeConstList'
expect_extraction "a non-literal uses: entry" "$C" '`SomeConstList` inside `uses:` is neither a string literal'

C="$TMP/nobundled"
make_case "$C"
rm "$C/rb/libs/repro_project_dsl/src/repro_project_dsl/macros_a.nim"
expect_extraction "no BundledStdlibSelectors" "$C" 'no definition of `BundledStdlibSelectors`'

C="$TMP/emptybundled"
make_case "$C"
printf 'const BundledStdlibSelectors* = [\n  # all gone\n  ]\n' \
	>"$C/rb/libs/repro_project_dsl/src/repro_project_dsl/macros_a.nim"
expect_extraction "zero bundled selectors" "$C" 'parsed ZERO names from `const BundledStdlibSelectors`'

C="$TMP/nomoved"
make_case "$C"
rm "$C/rb/libs/repro_project_dsl/src/repro_project_dsl/reprobuild_packages_catalog.nim"
expect_extraction "no MovedToReprobuildPackages" "$C" 'no definition of `MovedToReprobuildPackages`'

C="$TMP/computedmoved"
make_case "$C"
printf 'const MovedToReprobuildPackages*: seq[string] =\n  @["sqlite3"] & extraMoved\n' \
	>"$C/rb/libs/repro_project_dsl/src/repro_project_dsl/reprobuild_packages_catalog.nim"
expect_extraction "a list extended past its brackets" "$C" 'continues past its closing `]`'

C="$TMP/nonliteral"
make_case "$C"
printf 'const MovedToReprobuildPackages*: seq[string] =\n  @["sqlite3", someName]\n' \
	>"$C/rb/libs/repro_project_dsl/src/repro_project_dsl/reprobuild_packages_catalog.nim"
expect_extraction "a non-literal in a list" "$C" "contains something other than string literals"

C="$TMP/nocatalog"
make_case "$C"
rm -rf "$C/cat"
expect_extraction "catalog root missing" "$C" "the catalog root $C/cat"

C="$TMP/nointerfaces"
make_case "$C"
rm -rf "$C/cat/packages/interfaces"
mkdir -p "$C/cat/packages"
expect_extraction "catalog without packages/interfaces" "$C" "has no packages/interfaces/ entries"

C="$TMP/norbtree"
make_case "$C"
rm -rf "$C/rb/libs"
expect_extraction "not a reprobuild tree" "$C" "has no libs/repro_project_dsl/src"

C="$TMP/badflakelock"
make_case "$C"
echo '{ not json' >"$C/repo/flake.lock"
expect_extraction "an unparseable flake.lock" "$C" "cannot read $C/repo/flake.lock as a flake.lock"

C="$TMP/nolockdeps"
make_case "$C"
echo 'schema = "reprobuild.solved-graph-lock.v3"' >"$C/repo/repro.lock"
expect_extraction "repro.lock without deps" "$C" 'has no `deps = [...]` line'

echo
echo "the older reprobuild shape (v0.2.10: selector list nested in usesImportCode) is read"

C="$TMP/oldshape"
make_case "$C"
cat >"$C/rb/libs/repro_project_dsl/src/repro_project_dsl/macros_a.nim" <<'EOF'
proc usesImportCode(pkg: PackageDef; consumerSourceFile = ""): string =
  proc isBundledStdlibSelector(selector: string): bool =
    # M29 (Provisioning catalog cleanup): a comment that precedes the list.
    selector in [
      "bash",
      "nim",
      "nsis",
      "xdotool"
    ]
EOF
OUT="$(run_case "$C")"
RC=$?
assert_rc "the nested-list shape resolves" "$RC" 0
assert_contains "and its four selectors were read" "$OUT" "4 bundled selectors"

echo
echo "a missing python3 names ITSELF; a missing nix SKIPS loudly, and STRICT fails it"

C="$TMP/nopython"
make_case "$C"
mkdir -p "$TMP/emptybin"
OUT="$(PATH="$TMP/emptybin" CT_CATALOG_COVERAGE_REPO_ROOT="$C/repo" \
	CT_CATALOG_COVERAGE_REPROBUILD_SRC="$C/rb" CT_CATALOG_COVERAGE_CATALOG_ROOT="$C/cat" \
	"$BASH_ABS" "$GUARD" 2>&1)"
RC=$?
assert_rc "missing python3 exits 1" "$RC" 1
assert_contains "missing python3 is named" "$OUT" "python3 is required"
assert_contains "and says nothing was established" "$OUT" "NOTHING about the catalog pin has been established"
assert_absent "and does not give the pin remedy" "$OUT" "$PIN_REMEDY"

# python3 on PATH but no nix, and no override for the catalog: the script
# cannot locate the flake input, and must say so rather than judge anything.
PYDIR="$TMP/pyonly"
mkdir -p "$PYDIR"
ln -s "$(command -v python3)" "$PYDIR/python3"
C="$TMP/nonix"
make_case "$C"
OUT="$(PATH="$PYDIR" CT_CATALOG_COVERAGE_REPO_ROOT="$C/repo" \
	CT_CATALOG_COVERAGE_REPROBUILD_SRC="$C/rb" "$BASH_ABS" "$GUARD" 2>&1)"
RC=$?
assert_rc "no nix and no catalog override skips with exit 0" "$RC" 0
assert_contains "the skip names what is missing" "$OUT" '`nix` is not on PATH'
assert_contains "the skip names the input" "$OUT" "'reprobuild-packages' input"
assert_contains "the skip states it verified nothing" "$OUT" "was NOT verified by this run"
assert_absent "the skip does not claim a pass" "$OUT" "OK: all"
assert_absent "the skip does not report the root missing" "$OUT" "does not exist"

OUT="$(PATH="$PYDIR" CT_CATALOG_COVERAGE_STRICT=1 CT_CATALOG_COVERAGE_REPO_ROOT="$C/repo" \
	CT_CATALOG_COVERAGE_REPROBUILD_SRC="$C/rb" "$BASH_ABS" "$GUARD" 2>&1)"
RC=$?
assert_rc "STRICT=1 turns that skip into exit 1" "$RC" 1
assert_contains "STRICT=1 says why it is a failure" "$OUT" "CT_CATALOG_COVERAGE_STRICT=1"
assert_absent "and still judges nothing" "$OUT" "which does not resolve"

echo
echo "nix's own chatter on stderr does not become the input's path"

# A stand-in `nix`, and the one place this suite has one. What is under test is
# how the script SEPARATES nix's answer from what else nix prints, and a real
# nix prints that other text only when its state makes it (a cold Git cache's
# "unpacking ... into the Git cache", an unknown-setting warning, an auto-GC
# running inside the call). On a fresh CI runner all of those were on stderr,
# nix exited 0, and the guard read the whole merged text as a path. The stub
# reproduces exactly that: a warning on stderr, the path on stdout, exit 0.
C="$TMP/chattynix"
make_case "$C"
mkdir -p "$TMP/chattybin"
cat >"$TMP/chattybin/nix" <<EOF
#!$BASH_ABS
echo "warning: unknown setting 'build-provenance-tags'" >&2
echo "unpacking 'github:metacraft-labs/reprobuild-packages/$CAT_REV' into the Git cache..." >&2
printf '%s' "$C/cat"
EOF
chmod +x "$TMP/chattybin/nix"
OUT="$(PATH="$TMP/chattybin:$PATH" CT_CATALOG_COVERAGE_STRICT=1 CT_CATALOG_COVERAGE_REPO_ROOT="$C/repo" \
	CT_CATALOG_COVERAGE_REPROBUILD_SRC="$C/rb" "$BASH_ABS" "$GUARD" 2>&1)"
RC=$?
assert_rc "a located input resolves despite stderr chatter" "$RC" 0
assert_contains "and the catalog is judged" "$OUT" "OK: all"
assert_absent "and the pin is not reported unreadable" "$OUT" "could not locate"

echo
if [ "$FAILED" -ne 0 ]; then
	echo "$PASS assertion(s) passed, $FAILED FAILED" >&2
	exit 1
fi
echo "all $PASS assertions passed"
