#!/usr/bin/env bash
# =============================================================================
# require-runtime-assets-test.sh — the contract suite for
# scripts/require-runtime-assets.sh.
#
# WHY A SUITE FOR A GUARD
# -----------------------
# The guard exists because a build step silently did nothing. A guard can fail
# the same way: read no contract, find nothing to check, and print "ok". So
# this suite drives it against synthetic trees and asserts BOTH directions —
# every kind of breakage is rejected, and a correct tree is accepted — plus the
# property that makes it non-vacuous: the asset names are read live out of
# `src/common/config.nim`, so renaming the binding there moves what the guard
# looks for (cases 8a/8b below).
#
# Pure bash. No toolchain, no build, runs in about a second.
#
# Lane: ci/lint/bash.sh
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$REPO_ROOT/scripts/require-runtime-assets.sh"

if [ ! -f "$GUARD" ]; then
	echo "require-runtime-assets-test.sh: the script under test is missing: $GUARD" >&2
	exit 1
fi

pass_count=0
fail_count=0
failures=""

note_pass() {
	pass_count=$((pass_count + 1))
	printf '  ok    %s\n' "$1"
}

note_fail() {
	local desc="$1"
	fail_count=$((fail_count + 1))
	failures="${failures}  * ${desc}"$'\n'
	shift
	while [ $# -gt 0 ]; do
		failures="${failures}      $1"$'\n'
		shift
	done
	printf '  FAIL  %s\n' "$desc"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/require-runtime-assets-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Build a synthetic source root + built tree. Echoes the case directory.
make_case() {
	local name="$1"
	local d="$WORK/$name"
	mkdir -p "$d/src/common" "$d/src/config" "$d/out/config"
	cat >"$d/src/common/config.nim" <<'NIM'
# synthetic stand-in for the real src/common/config.nim
let configPath* = ".config.yaml"
let defaultConfigPath* = "default_config.yaml"
let defaultLayoutPath* = "default_layout.json"
let configDir* = codetracerPrefix / "config"
NIM
	printf 'theme: dark\n' >"$d/src/config/default_config.yaml"
	printf '{"layout":"default"}\n' >"$d/src/config/default_layout.json"
	cp "$d/src/config/default_config.yaml" "$d/out/config/default_config.yaml"
	cp "$d/src/config/default_layout.json" "$d/out/config/default_layout.json"
	printf '%s' "$d"
}

run_guard() {
	local d="$1"
	# Invoked through `bash` rather than executed, so a checkout that lost the
	# executable bit (Git for Windows with core.fileMode=false, a `git apply`
	# of a patch produced there) fails the CHECKS rather than every case with
	# an opaque 126.
	bash "$GUARD" "$d/out" --source-root "$d" >"$d/stdout" 2>"$d/stderr"
	printf '%s' "$?"
}

# expect_exit CASE-NAME EXPECTED-RC DESCRIPTION [SUBSTRING-THAT-MUST-APPEAR]
expect() {
	local d="$1" want_rc="$2" desc="$3" needle="${4:-}"
	local got_rc
	got_rc="$(run_guard "$d")"
	if [ "$got_rc" != "$want_rc" ]; then
		note_fail "$desc" \
			"expected exit $want_rc, got $got_rc" \
			"stdout: $(tr '\n' '|' <"$d/stdout")" \
			"stderr: $(tr '\n' '|' <"$d/stderr")"
		return
	fi
	if [ -n "$needle" ]; then
		if ! grep -qF -- "$needle" "$d/stdout" "$d/stderr"; then
			note_fail "$desc" \
				"exit $got_rc was right, but the output never mentions: $needle" \
				"stdout: $(tr '\n' '|' <"$d/stdout")" \
				"stderr: $(tr '\n' '|' <"$d/stderr")"
			return
		fi
	fi
	note_pass "$desc"
}

echo "require-runtime-assets-test.sh: driving $GUARD"
echo

# --- 1. the happy path -------------------------------------------------------
d="$(make_case complete)"
expect "$d" 0 "a complete built tree is accepted" "ok --"

# --- 2/3. a missing asset is named -------------------------------------------
d="$(make_case missing-yaml)"
rm "$d/out/config/default_config.yaml"
expect "$d" 1 "a missing default_config.yaml is rejected, by name" "default_config.yaml"

d="$(make_case missing-json)"
rm "$d/out/config/default_layout.json"
expect "$d" 1 "a missing default_layout.json is rejected, by name" "default_layout.json"

# The whole directory absent is the actual clean-build symptom.
d="$(make_case empty-config-dir)"
rm -f "$d/out/config/"*
expect "$d" 1 "an EMPTY config/ directory is rejected (the clean-build symptom)" \
	"DOES NOT EXIST"

# --- 4. published but empty --------------------------------------------------
d="$(make_case zero-length)"
: >"$d/out/config/default_config.yaml"
expect "$d" 1 "a zero-length published asset is rejected" "IS EMPTY"

# --- 5. published but stale --------------------------------------------------
d="$(make_case stale)"
printf 'theme: light\n' >"$d/out/config/default_config.yaml"
expect "$d" 1 "a published asset that no longer matches its source is rejected" \
	"CONTENT DIFFERS FROM SOURCE"

# --- 6/7. symlinks --------------------------------------------------------
# tup's `!tup_preserve` publishes a SYMLINK into the variant tree, so a live
# symlink must be accepted and a dangling one must not. Both cases need real
# symlinks; an environment that quietly turns `ln -s` into a copy (Git Bash
# without MSYS=winsymlinks:nativestrict) would make case 7 pass for the wrong
# reason, so each case verifies the artifact it just created and fails BY NAME
# when the environment could not produce it. That is deliberate: silently
# dropping the two checks that cover tup's actual output shape is exactly the
# kind of hole this suite exists to prevent.
require_symlink() {
	local path="$1" desc="$2" want_dangling="$3"
	if [ ! -L "$path" ]; then
		note_fail "$desc" \
			"this environment did not create a symlink at $path" \
			"it produced: $(ls -ld "$path" 2>&1)" \
			"tup publishes runtime assets AS SYMLINKS, so this check cannot be" \
			"skipped without dropping coverage of tup's real output shape." \
			"Run this suite on a filesystem with symlink support (Linux, macOS," \
			"or Git Bash with MSYS=winsymlinks:nativestrict)."
		return 1
	fi
	if [ "$want_dangling" = "yes" ] && [ -e "$path" ]; then
		note_fail "$desc" \
			"the symlink at $path resolves, so it is not dangling" \
			"target: $(readlink "$path")"
		return 1
	fi
	return 0
}

d="$(make_case symlink)"
rm "$d/out/config/default_config.yaml"
ln -s ../../src/config/default_config.yaml "$d/out/config/default_config.yaml" 2>/dev/null || true
if require_symlink "$d/out/config/default_config.yaml" \
	"a symlink into the source tree is accepted (tup !tup_preserve)" no; then
	expect "$d" 0 "a symlink into the source tree is accepted (tup !tup_preserve)" "ok --"
fi

d="$(make_case dangling)"
rm "$d/out/config/default_config.yaml"
: >"$d/src/config/soon-gone.yaml"
ln -s ../../src/config/soon-gone.yaml "$d/out/config/default_config.yaml" 2>/dev/null || true
rm -f "$d/src/config/soon-gone.yaml"
if require_symlink "$d/out/config/default_config.yaml" \
	"a dangling symlink is rejected and reported as dangling" yes; then
	expect "$d" 1 "a dangling symlink is rejected and reported as dangling" \
		"DANGLING SYMLINK"
fi

# --- 8. the contract is READ, not hardcoded ----------------------------------
# 8a. Rename the binding AND the files: the guard must follow the rename.
d="$(make_case renamed-followed)"
sed -i.bak 's/"default_config\.yaml"/"ct_defaults.yaml"/' "$d/src/common/config.nim"
mv "$d/src/config/default_config.yaml" "$d/src/config/ct_defaults.yaml"
mv "$d/out/config/default_config.yaml" "$d/out/config/ct_defaults.yaml"
expect "$d" 0 "a renamed asset binding is followed into the new name" "ct_defaults.yaml"

# 8b. Rename the binding but NOT the built tree: the guard must now demand the
#     new name. A hardcoded list would still be happy — this is the mutation
#     that proves the derivation is live.
d="$(make_case renamed-not-followed)"
sed -i.bak 's/"default_config\.yaml"/"ct_defaults.yaml"/' "$d/src/common/config.nim"
mv "$d/src/config/default_config.yaml" "$d/src/config/ct_defaults.yaml"
expect "$d" 1 "a renamed binding whose asset was not republished is rejected" \
	"ct_defaults.yaml"

# 8c. The config directory name is read too.
d="$(make_case renamed-configdir)"
sed -i.bak 's|codetracerPrefix / "config"|codetracerPrefix / "etc"|' "$d/src/common/config.nim"
mv "$d/out/config" "$d/out/etc"
expect "$d" 0 "the config SUBDIRECTORY name is read from configDir too" "/out/etc/"

# --- 9/10. an unreadable contract is a hard failure, never a silent pass -----
d="$(make_case no-config-nim)"
rm "$d/src/common/config.nim"
expect "$d" 1 "a missing src/common/config.nim fails loudly rather than passing" \
	"cannot read the runtime asset contract"

d="$(make_case unparseable-contract)"
cat >"$d/src/common/config.nim" <<'NIM'
# the bindings this guard reads have been restructured away
const defaults = ["default_config.yaml", "default_layout.json"]
NIM
expect "$d" 1 "an unparseable contract fails loudly, naming the bindings" \
	"unparsed binding(s)"

# --- 11/12. argument handling ------------------------------------------------
d="$(make_case no-out-root)"
rm -rf "$d/out"
expect "$d" 1 "a build output root that does not exist is rejected" \
	"build output root does not exist"

if bash "$GUARD" >/dev/null 2>&1; then
	note_fail "invoking with no arguments must fail" "it exited 0"
else
	rc=$?
	if [ "$rc" -eq 2 ]; then
		note_pass "invoking with no arguments exits 2 (usage)"
	else
		note_fail "invoking with no arguments must exit 2 (usage)" "got exit $rc"
	fi
fi

echo
if [ "$fail_count" -eq 0 ]; then
	echo "require-runtime-assets-test.sh: ${pass_count} checks passed."
	exit 0
fi

{
	echo "require-runtime-assets-test.sh: ${fail_count} of $((pass_count + fail_count)) checks failed."
	echo
	printf '%s' "$failures"
} >&2
exit 1
