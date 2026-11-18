#!/usr/bin/env bash
#
# dev-shell-rust-unwinds-test.sh -- a Rust crate built with plain `cargo test`
# in this repository's dev shell, OUTSIDE this checkout, unwinds its panics.
#
# On macOS rustc links through `cc`, and in the dev shell `cc` is nixpkgs'
# gcc-wrapper. GCC's Darwin driver passes `-no_compact_unwind`, the test binary
# gets no `__TEXT,__unwind_info`, and every unwinding panic aborts with
# `fatal runtime error: failed to initiate panic, error 5`: a passing
# `#[should_panic]` or `catch_unwind` test fails, and a failing assertion
# prints nothing. The repository's `.cargo/config.toml` routes cargo to clang,
# but cargo reads it only for invocations under this checkout, so crates
# anywhere else -- sibling repositories, and the scratch projects the
# rust-libtest provider tests create under the temp directory -- still aborted
# (codetracer-pm issues/2026-11-01-darwin-dev-shell-cargo-tests-abort-on-any-
# unwinding-panic.md). The shell now exports
# CARGO_TARGET_<triple>_LINKER on Darwin (nix/shells/ci-base.nix).
#
# Asserted, for the default and the `ci` dev shell, from a scratch crate under
# the temp directory (so no `.cargo/config.toml` of this repository applies):
#   * `cargo test` passes a `#[should_panic]` test and a `catch_unwind` test;
#   * a deliberately failing assertion is REPORTED (exit 101) with its message
#     and the values it compared, and the runtime never fails to start the
#     panic.
# Negative control, on Darwin while the shell's `cc` is GCC: the same crate
# linked with `cc` (the linker variable overridden back to rustc's default)
# aborts with "failed to initiate panic". That shows the probe detects the
# defect in this shell, so its green above is the fix's and not an accident of
# the host.
#
# Runs `nix develop`, so it is slow; it is not part of the in-shell test
# recipes. On Linux the assertions hold without the fix, and the test guards
# that they keep holding.
#
#   bash ci/test/dev-shell-rust-unwinds-test.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
fail() {
	echo "FAIL: $*" >&2
	exit 1
}

case "$SCRATCH" in
"$REPO"/*) fail "the scratch crate must live outside $REPO, or the repository's .cargo/config.toml applies" ;;
esac

MARKER="UNWIND-PROBE"
crate="$SCRATCH/unwind-probe"
mkdir -p "$crate/src"
cat >"$crate/Cargo.toml" <<'EOF'
[package]
name = "unwind-probe"
version = "0.1.0"
edition = "2021"

[dependencies]
EOF
cat >"$crate/src/lib.rs" <<EOF
#[test]
#[should_panic(expected = "boom")]
fn should_panic_unwinds() {
    panic!("boom");
}

#[test]
fn catch_unwind_catches() {
    assert!(std::panic::catch_unwind(|| panic!("caught")).is_err());
}

#[test]
#[ignore = "fails by design; run with --ignored by dev-shell-rust-unwinds-test.sh"]
fn deliberately_failing_assertion() {
    let measured = 41_u32;
    let expected = 42_u32;
    assert_eq!(measured, expected, "$MARKER measured={measured} expected={expected}");
}
EOF

# Runs `cargo test <args>` for the scratch crate inside dev shell <attr> ("" is
# the default one), entered from the crate's directory. Prints the combined
# output and then a final line `exit=<status>`. Extra environment for cargo
# comes from $CARGO_ENV ("NAME=value"). The single quotes are deliberate: the
# script expands inside the shell.
#
# `nix develop`'s own stderr (evaluation warnings, the shellHook's sibling
# report) is kept out of the output the assertions read, but it is not thrown
# away: when the shell never reached cargo, there is no `exit=` line, and the
# tail of that stderr is printed instead, so the FAIL names the real cause. The
# function itself always succeeds, so a failed `nix develop` cannot end the
# script under `set -e` before it says why.
# shellcheck disable=SC2016
run_cargo_test() {
	local attr="$1"
	shift
	local err="$SCRATCH/nix-develop-${attr:-default}${CARGO_ENV:+-control}.err"
	local out
	out="$(cd "$crate" && nix develop "$REPO${attr:+#$attr}" --no-write-lock-file -c bash -c '
		target_dir="$1"; cargo_env="$2"; shift 2
		set +e
		env ${cargo_env:+"$cargo_env"} CARGO_TARGET_DIR="$target_dir" \
			cargo test --offline --quiet "$@" 2>&1
		echo "exit=$?"
	' _ "$SCRATCH/target-${attr:-default}${CARGO_ENV:+-control}" "${CARGO_ENV:-}" "$@" 2>"$err")" || true
	printf '%s\n' "$out"
	if ! grep -q '^exit=' <<<"$out"; then
		echo "(nix develop never reached cargo; its stderr ends:)"
		tail -n 20 "$err"
	fi
}

# The status `run_cargo_test` printed last.
status_of() { sed -n 's/^exit=//p' <<<"$1" | tail -n 1; }

for attr in "" ci; do
	name="${attr:-default}"

	out="$(CARGO_ENV='' run_cargo_test "$attr")"
	[ "$(status_of "$out")" = 0 ] ||
		fail "[$name] cargo test of a crate outside the checkout failed:"$'\n'"$out"
	if grep -q 'failed to initiate panic' <<<"$out"; then
		fail "[$name] the runtime could not start a panic:"$'\n'"$out"
	fi
	# Positive control: both tests really ran, so exit 0 is their verdict.
	grep -q '2 passed' <<<"$out" ||
		fail "[$name] expected both unwinding tests to pass; got:"$'\n'"$out"

	out="$(CARGO_ENV='' run_cargo_test "$attr" -- --ignored)"
	[ "$(status_of "$out")" = 101 ] ||
		fail "[$name] the failing assertion must be reported (exit 101), not abort:"$'\n'"$out"
	if grep -q 'failed to initiate panic' <<<"$out"; then
		fail "[$name] the failing assertion aborted the runtime:"$'\n'"$out"
	fi
	grep -q "$MARKER measured=41 expected=42" <<<"$out" ||
		fail "[$name] the failing assertion's message and values did not reach the output:"$'\n'"$out"
	echo "ok: [$name] a crate outside the checkout unwinds its panics"
done

# Negative control. Only meaningful where the shell's `cc` is the GCC driver
# that drops the unwind index; elsewhere there is nothing to control for.
# An empty probe must fail, not fall through to the skip below: that would
# drop the control silently on exactly the host it exists for.
# shellcheck disable=SC2016
control_facts="$(cd "$crate" && nix develop "$REPO" --no-write-lock-file -c bash -c '
	printf "%s|%s\n" "$(rustc -vV | sed -n "s/^host: //p")" "$(cc --version 2>&1 | head -n 1)"
' 2>"$SCRATCH/nix-develop-probe.err")" || true
host="${control_facts%%|*}"
cc_banner="${control_facts#*|}"
[ -n "$host" ] && [ -n "$cc_banner" ] ||
	fail "control: could not read rustc's host and cc's banner in the dev shell (got '$control_facts'); nix develop's stderr ends:"$'\n'"$(tail -n 20 "$SCRATCH/nix-develop-probe.err")"
if [ "$(uname -s)" = Darwin ] && grep -qi 'gcc' <<<"$cc_banner"; then
	var="CARGO_TARGET_$(tr 'a-z-' 'A-Z_' <<<"$host")_LINKER"
	out="$(CARGO_ENV="$var=cc" run_cargo_test "")"
	grep -q 'failed to initiate panic' <<<"$out" ||
		fail "control: linked with cc ($cc_banner), the crate was expected to abort; got:"$'\n'"$out"
	echo "ok: control -- linked with the shell's cc ($cc_banner) the same crate aborts"
else
	echo "skip: control -- needs Darwin with a GCC cc (host $host, cc: $cc_banner)"
fi

echo "PASS: dev-shell Rust builds unwind their panics"
