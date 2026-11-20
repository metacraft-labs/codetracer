#!/usr/bin/env bash
#
# visual-replay-build-sibling-preflight-test.sh — the build-sibling preflight
# refuses, BY NAME, a workspace whose io-mon declares its command line with
# clispec and that carries no nim-cli-spec, or one older than that io-mon
# imports from, and accepts one whose io-mon does not need it.
#
# From io-mon efe6dc5 on, cmd/io_mon_snoop.nim imports `io_mon/cli`, which
# imports nim-cli-spec's `clispec` (and, from 8b8faa8, `io_mon/cli_description`,
# which imports `clispec/splice`); io-mon's `config.nims` resolves it through `CLI_SPEC_SRC`,
# by default `../nim-cli-spec/src`. A lane that builds the `io-mon` binary from
# such a checkout without the library, or with one that predates a module it
# imports, dies late on `cannot open file: clispec` (reprobuild-pm issue
# 2026-11-19-codetracer-io-mon-builds-need-nim-cli-spec-from-io-mon-efe6dc5).
#
# Runs the real preflight against scratch workspaces holding empty files at the
# paths it lists. bash and coreutils only; well under a second.
#
# Run: bash ci/test/visual-replay-build-sibling-preflight-test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFLIGHT="$REPO_ROOT/ci/test/visual-replay-build-sibling-preflight.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

unset CLI_SPEC_SRC

# The paths the preflight lists unconditionally, read from the script itself so
# this suite cannot drift from it.
mapfile -t LISTED < <(sed -n 's/^\t"\([^"]*\)"$/\1/p' "$PREFLIGHT")
if [[ ${#LISTED[@]} -lt 5 ]]; then
	echo "FAIL: read only ${#LISTED[@]} required paths out of $PREFLIGHT; its list changed shape" >&2
	exit 2
fi

failures=0
ok() { echo "ok: $1"; }
fail() {
	echo "FAIL: $1" >&2
	shift
	for line in "$@"; do echo "      $line" >&2; done
	failures=$((failures + 1))
}

# A workspace holding every listed path. `$2` is the io-mon generation:
# `clispec` writes the two CLI modules with the imports io-mon's carry from
# 8b8faa8 on; `before` writes an io-mon with no command-line module, whose
# other modules mention clispec only in prose.
make_workspace() {
	local workspace="$1" generation="$2" path
	for path in "${LISTED[@]}"; do
		mkdir -p "$workspace/$(dirname "$path")"
		: >"$workspace/$path"
	done
	mkdir -p "$workspace/io-mon/src/io_mon"
	printf '%s\n' '## The command line is not clispec yet.' 'import std/os' \
		>"$workspace/io-mon/src/io_mon/fs_snoop.nim"
	if [[ $generation == clispec ]]; then
		printf '%s\n' 'import std/[options, os]' 'import clispec' 'import ./cli_description' \
			>"$workspace/io-mon/src/io_mon/cli.nim"
		printf '%s\n' 'import clispec/splice' \
			>"$workspace/io-mon/src/io_mon/cli_description.nim"
	fi
}

# A clispec source at `$1`: the umbrella, and `splice` unless `$2` is `old`
# (nim-cli-spec before cc2eb8f, merged as fcd5b309, has no `clispec/splice`).
make_cli_spec() {
	mkdir -p "$1/clispec"
	: >"$1/clispec.nim"
	if [[ ${2:-} != old ]]; then
		: >"$1/clispec/splice.nim"
	fi
}

run_preflight() {
	local rc=0
	OUT="$(bash "$PREFLIGHT" "$1" 2>&1)" || rc=$?
	RC=$rc
}

make_workspace "$TEST_ROOT/before" before
run_preflight "$TEST_ROOT/before"
if [[ $RC -eq 0 ]]; then
	ok "an io-mon that imports no clispec module needs no nim-cli-spec"
else
	fail "an io-mon that imports no clispec module needs no nim-cli-spec" "exit $RC: $OUT"
fi

make_workspace "$TEST_ROOT/missing" clispec
run_preflight "$TEST_ROOT/missing"
if [[ $RC -eq 1 && $OUT == *"../nim-cli-spec/src/clispec.nim"* ]]; then
	ok "an io-mon whose CLI imports clispec is refused without nim-cli-spec, by name"
else
	fail "an io-mon whose CLI imports clispec is refused without nim-cli-spec, by name" "exit $RC: $OUT"
fi

make_workspace "$TEST_ROOT/sibling" clispec
make_cli_spec "$TEST_ROOT/sibling/nim-cli-spec/src"
run_preflight "$TEST_ROOT/sibling"
if [[ $RC -eq 0 ]]; then
	ok "the nim-cli-spec sibling satisfies it"
else
	fail "the nim-cli-spec sibling satisfies it" "exit $RC: $OUT"
fi

# A nim-cli-spec older than the io-mon beside it: the umbrella is there, a
# module io-mon imports is not. This is the pair a workspace lock holds when
# io-mon moves to 8b8faa8 or later and nim-cli-spec stays behind.
make_workspace "$TEST_ROOT/stale" clispec
make_cli_spec "$TEST_ROOT/stale/nim-cli-spec/src" old
run_preflight "$TEST_ROOT/stale"
if [[ $RC -eq 1 && $OUT == *"../nim-cli-spec/src/clispec/splice.nim"* ]]; then
	ok "a nim-cli-spec without a module io-mon imports is refused, naming the module"
else
	fail "a nim-cli-spec without a module io-mon imports is refused, naming the module" "exit $RC: $OUT"
fi

# An empty checkout (the directory without the module) is not the library.
make_workspace "$TEST_ROOT/empty" clispec
mkdir -p "$TEST_ROOT/empty/nim-cli-spec/src"
run_preflight "$TEST_ROOT/empty"
if [[ $RC -eq 1 && $OUT == *"../nim-cli-spec/src/clispec.nim"* ]]; then
	ok "a nim-cli-spec directory without clispec.nim is refused"
else
	fail "a nim-cli-spec directory without clispec.nim is refused" "exit $RC: $OUT"
fi

# CLI_SPEC_SRC replaces the sibling, as it does in io-mon's config.nims: a set
# variable is the only place the compile looks.
make_workspace "$TEST_ROOT/override" clispec
make_cli_spec "$TEST_ROOT/elsewhere/src"
export CLI_SPEC_SRC="$TEST_ROOT/elsewhere/src"
run_preflight "$TEST_ROOT/override"
if [[ $RC -eq 0 ]]; then
	ok "CLI_SPEC_SRC naming a clispec source satisfies it"
else
	fail "CLI_SPEC_SRC naming a clispec source satisfies it" "exit $RC: $OUT"
fi
export CLI_SPEC_SRC="$TEST_ROOT/no-such-dir"
run_preflight "$TEST_ROOT/sibling"
if [[ $RC -eq 1 && $OUT == *"$TEST_ROOT/no-such-dir"*"/clispec.nim"* ]]; then
	ok "CLI_SPEC_SRC naming nothing is refused even beside a good sibling"
else
	fail "CLI_SPEC_SRC naming nothing is refused even beside a good sibling" "exit $RC: $OUT"
fi
# Set and empty is still set: io-mon's getEnv returns the empty value, not the
# sibling default.
export CLI_SPEC_SRC=""
run_preflight "$TEST_ROOT/sibling"
if [[ $RC -eq 1 && $OUT == *"CLI_SPEC_SRC"*"/clispec.nim"* ]]; then
	ok "an empty CLI_SPEC_SRC is refused even beside a good sibling"
else
	fail "an empty CLI_SPEC_SRC is refused even beside a good sibling" "exit $RC: $OUT"
fi
unset CLI_SPEC_SRC

# The unconditional list still refuses by name.
make_workspace "$TEST_ROOT/no-gset" before
rm "$TEST_ROOT/no-gset/nim-shm-gset/src/shm_gset/transport.nim"
run_preflight "$TEST_ROOT/no-gset"
if [[ $RC -eq 1 && $OUT == *"../nim-shm-gset/src/shm_gset/transport.nim"* ]]; then
	ok "a listed sibling source that is absent is still refused by name"
else
	fail "a listed sibling source that is absent is still refused by name" "exit $RC: $OUT"
fi

if [[ $failures -ne 0 ]]; then
	echo "FAIL: $failures case(s) failed" >&2
	exit 1
fi
echo "ok: visual replay build-sibling preflight"
