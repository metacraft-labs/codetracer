#!/usr/bin/env bash
# =============================================================================
# Contract: `build-siblings.sh` builds `nargo` from a noir checkout that has
# never been prepared — no `.codetracer-deps/` — as a fresh clone (a CI clone
# included) is.
#
#   bash ci/test/build-siblings-noir-fresh-checkout-test.sh
#
# WHY THIS FILE EXISTS
#   The noir entry ran a bare `cargo build --release --package nargo_cli`.
#   nargo links `codetracer_trace_writer_nim`, whose build script compiles the
#   Nim CTFS writer from `codetracer-trace-format-nim` sources. noir's
#   `.cargo/config.toml` points that build script at `.codetracer-deps/`, and
#   noir's justfile fills the directory with `just trace-format-nim`
#   (scripts/fetch-trace-format-nim.sh) — "needed once before building
#   `nargo`". build-siblings never ran it, so on every checkout where nobody
#   had run it by hand the summary read
#     FAIL    noir    build exited 101
#   and the log ended in the build script's panic:
#     Nim FFI entry point not found at …/noir/.codetracer-deps/
#       codetracer-trace-format-nim/src/codetracer_trace_writer_ffi.nim
#   Every GUI spec that needs the sibling nargo then ran against nothing.
#
# WHAT IT DOES
#   Against the real sibling checkout: moves any existing `.codetracer-deps/`
#   and `target/release/nargo` aside (each restored afterwards only if this
#   run did not produce a replacement), runs
#   `build-siblings.sh --force --only noir`, and requires
#     1. a PASS row for noir,
#     2. the Nim FFI entry point the build script reads, under
#        `.codetracer-deps/`, at the revision noir's fetch script pins,
#     3. a `nargo --version` that runs.
#   It needs the sibling at ../noir, Nix and the network (the fetch is noir's
#   own, from GitHub). Without the sibling it FAILS by name rather than
#   skipping: a skipped run is how this stayed invisible.
#
# Mocks: none. The real script, the real sibling, the real toolchain.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WS_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/build-siblings.sh"
SIBLING="$WS_ROOT/noir"
DEPS="$SIBLING/.codetracer-deps"
BIN="$SIBLING/target/release/nargo"
FFI="$DEPS/codetracer-trace-format-nim/src/codetracer_trace_writer_ffi.nim"

failures=0
pass() { echo "  ok   $*"; }
fail() {
	echo "  FAIL $*"
	failures=$((failures + 1))
}

echo "== build-siblings: nargo builds from a noir checkout with no .codetracer-deps/"

if [ ! -d "$SIBLING" ]; then
	fail "noir is not checked out at $SIBLING"
elif ! command -v repro >/dev/null 2>&1; then
	fail "repro is not on PATH; build-siblings builds each sibling through 'repro exec'"
else
	stash="$(mktemp -d)"
	saved_deps=""
	saved_bin=""
	restore() {
		# A passing run keeps what it built. Otherwise whatever the run left
		# (nothing, or a half-fetched `.codetracer-deps/`) gives way to what was
		# there before, so a failing run leaves the workspace as it was. No
		# stamp vouches for the restored nargo (build-siblings drops the old
		# stamp before building, and a new one records the new binary's bytes),
		# so the next build-siblings run rebuilds it rather than reusing it.
		if [ -n "$saved_deps" ] && { [ "$failures" -gt 0 ] || [ ! -e "$DEPS" ]; }; then
			rm -rf "$DEPS"
			mv "$saved_deps" "$DEPS"
		fi
		if [ -n "$saved_bin" ] && { [ "$failures" -gt 0 ] || [ ! -e "$BIN" ]; }; then
			rm -f "$BIN"
			mv "$saved_bin" "$BIN"
		fi
		rm -rf "$stash"
	}
	trap restore EXIT
	if [ -e "$DEPS" ]; then
		saved_deps="$stash/codetracer-deps"
		mv "$DEPS" "$saved_deps"
	fi
	if [ -e "$BIN" ]; then
		saved_bin="$stash/nargo"
		mv "$BIN" "$saved_bin"
	fi

	# The precondition IS the test: a run that starts with the sources or the
	# binary still in place proves nothing about a fresh checkout, so a move
	# that did not happen fails the run rather than letting the build pass.
	if [ -e "$DEPS" ] || [ -e "$BIN" ]; then
		fail "could not move $DEPS and $BIN aside; this run would not test a fresh checkout"
	else
		# A CODETRACER_TRACE_FORMAT_NIM_DIR in this environment outranks noir's
		# .cargo/config.toml, so it would hand the build script sources from
		# elsewhere and hide whether build-siblings provides them. A fresh
		# clone's build has no such variable, and neither does this one.
		out="$(env -u CODETRACER_TRACE_FORMAT_NIM_DIR bash "$SCRIPT" --force --only noir 2>&1)"
		rc=$?
		if grep -qE 'PASS +noir +built target/release/nargo' <<<"$out"; then
			pass "build-siblings reports noir built from a checkout with no .codetracer-deps/"
		else
			fail "build-siblings did not report a PASS for noir (exit $rc):"
			echo "$out" | tail -30 | sed 's/^/         /'
		fi
	fi

	# The revision noir pins, read from the script that pins it, so a bump in
	# noir does not need a matching edit here. The pattern matches the
	# script's literal `${TRACE_FORMAT_NIM_REV:-…}`, so nothing in it may expand.
	# shellcheck disable=SC2016
	want_rev="$(sed -n 's/^TRACE_FORMAT_NIM_REV="\${TRACE_FORMAT_NIM_REV:-\([0-9a-f]\{40\}\)}"$/\1/p' \
		"$SIBLING/scripts/fetch-trace-format-nim.sh")"
	got_rev="$(git -C "$DEPS/codetracer-trace-format-nim" rev-parse HEAD 2>/dev/null)"
	if [ ! -f "$FFI" ]; then
		fail "no Nim FFI entry point at $FFI after the build"
	elif [ -z "$want_rev" ]; then
		fail "cannot read TRACE_FORMAT_NIM_REV from noir's scripts/fetch-trace-format-nim.sh"
	elif [ "$got_rev" != "$want_rev" ]; then
		fail ".codetracer-deps/codetracer-trace-format-nim is at '$got_rev', noir pins $want_rev"
	else
		pass ".codetracer-deps/ holds codetracer-trace-format-nim at noir's pin ${want_rev:0:12}"
	fi

	if [ -x "$BIN" ]; then
		if run_out="$(env -i PATH=/usr/bin:/bin "$BIN" --version 2>&1)"; then
			pass "nargo --version runs: $(head -1 <<<"$run_out")"
		else
			fail "nargo --version did not run with an empty environment:"
			echo "$run_out" | head -5 | sed 's/^/         /'
		fi
	else
		fail "no executable at $BIN after the build"
	fi
fi

if [ "$failures" -gt 0 ]; then
	echo "build-siblings-noir-fresh-checkout: $failures failure(s)"
	exit 1
fi
echo "build-siblings-noir-fresh-checkout: all checks passed"
