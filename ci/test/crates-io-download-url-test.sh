#!/usr/bin/env bash
# =============================================================================
# crates-io-download-url-test.sh — contract suite for
# nix/overlays/crates-io-download-url.nix.
#
# WHY THIS EXISTS
# ---------------
# crates.io's API host now answers 403 to every request whose User-Agent looks
# like `curl/*`, and `pkgs.fetchurl` sends exactly that
# (`curl/<ver> Nixpkgs/<ver>`). Every crate source `importCargoLock` fetches was
# therefore refused, and `nix build .#backend-manager` -- and with it
# `.#codetracer`, nix-build, dev-build, appimage-build, dmg-build,
# test-ui-tests and test-ui-tests-rr -- could not get past its first dependency:
#
#     curl: (22) The requested URL returned error: 403
#     error: cannot download crate-<name>-<version>.tar.gz from any mirror
#
# The overlay routes those fetches at `static.crates.io` instead, which is the
# same substitution nixpkgs made upstream and which this repository's pin
# predates. See that file for the measurement and for who owns the durable fix.
#
# WHAT IT TESTS AGAINST
# ---------------------
# Not a copy of the overlay -- the REAL derivations, instantiated from the real
# flake with `nix derivation show -r`, so this suite cannot drift from what nix
# actually fetches. Instantiation only: no crate is downloaded, no rustc runs.
#
# WHAT IT ASSERTS, AND WHY EACH ONE
# ---------------------------------
#   1. The overlay is WIRED IN. A file nobody imports fixes nothing, and that
#      failure is invisible to every other check here.
#   2. Nothing in either Rust package's VENDOR DIRECTORY fetches from the host
#      that 403s. This is the assertion that fails before the fix and passes
#      after.
#   3. ...and the number of crates fetched from the CDN is EXACTLY the number of
#      crates.io packages that package's own `Cargo.lock` names. A bare "no
#      legacy URLs" is also true of a vendor directory with no crates in it, and
#      that is precisely how a fix rots into a green tick. Counting against the
#      lock file makes the assertion impossible to satisfy vacuously and makes a
#      PARTIAL rewrite -- some crates moved, some not -- fail rather than pass.
#   4. The rewrite preserved fixed-output IDENTITY: the crate derivation's
#      `name` and `outputHash` are unchanged, so its store path is unchanged and
#      nothing already built or cached is invalidated. A rewrite that also
#      touched either would silently orphan every cached crate.
#   5. Non-crates.io URLs are untouched, byte for byte. The overlay replaces the
#      package set's `fetchurl`; if it rewrote anything else the blast radius
#      would be the whole tree rather than the 454 crate tarballs these two
#      packages vendor.
#   6. LIVE: the URL the build will actually use answers 200 to nixpkgs' own
#      User-Agent. (2)-(5) prove we ask a different host; only this proves that
#      host answers. It is the one assertion that can notice the CDN adopting
#      the same policy.
#
# WHAT IT DELIBERATELY DOES NOT ASSERT
# ------------------------------------
# That NO derivation anywhere in `.?submodules=1#codetracer`'s build closure
# uses the old URL. Measured: 957 still do, and they are not this repository's to fix -- they
# are crate fetches belonging to package sets that sibling flakes (`noir`,
# `wazero`, `nix-blockchain-development-sui`, ...) `import` themselves, which no
# overlay declared here can reach. They are also all substitutable from
# cache.nixos.org, so they only bite a machine forced to build them from source.
# Asserting zero-in-the-closure would therefore be a red test this repository
# cannot turn green, and the thing that actually fixes it -- moving the shared
# nixpkgs pin in `metacraft-labs/nix-codetracer-toolchains` -- fixes it for
# every repo at once. Recorded in codetracer-specs/Testing/Known-Test-Failures.md.
#
# Run: bash ci/test/crates-io-download-url-test.sh
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

OVERLAY=nix/overlays/crates-io-download-url.nix
LEGACY_PREFIX="https://crates.io/api/v1/crates/"
CDN_PREFIX="https://static.crates.io/crates/"

# A crate that both Rust packages depend on, with the checksum its own
# Cargo.lock records. Assertion 4 is anchored on it.
PROBE_CRATE=serde
PROBE_VERSION=1.0.219
PROBE_CHECKSUM=5f0e2c6ed6606019b4e29e69dbaba95b11854410e5347d525002456dbbb786b6

PASS=0
FAIL=0

pass() {
	PASS=$((PASS + 1))
	printf '  ok    %s\n' "$1"
}

fail() {
	FAIL=$((FAIL + 1))
	printf '  FAIL  %s\n' "$1" >&2
	if [ -n "${2:-}" ]; then
		printf '        %s\n' "$2" >&2
	fi
}

# -----------------------------------------------------------------------------
# Skip loudly, never silently -- and never at all in CI.
#
# Same discipline as ci/test/backend-manager-check-phase-test.sh: on a developer
# machine without nix, skipping is right, because the alternative is a failure
# that says nothing about the change being made. In CI it is the opposite --
# lint-bash runs this file inside `nix develop`, so nix is present by
# construction, and a "skip" there would turn a broken lane into a green tick on
# a check that verified nothing.
# -----------------------------------------------------------------------------
in_ci() { [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; }

bail_or_skip() { # reason
	if in_ci; then
		cat >&2 <<-EOF
			ERROR: ci/test/crates-io-download-url-test.sh cannot run.
			Reason: $1
			This is a hard failure in CI, where this suite runs inside a dev
			shell that provides everything it needs. Skipping here would report
			a green tick for a check that verified nothing.
		EOF
		exit 1
	fi
	printf 'SKIPPED: %s\n' "$1"
	printf '(this is a hard failure in CI; it is a skip only off a CI runner)\n'
	exit 0
}

command -v nix >/dev/null 2>&1 || bail_or_skip "nix is not on PATH"

SYSTEM=$(nix eval --raw --impure --expr 'builtins.currentSystem' 2>/dev/null)
[ -n "$SYSTEM" ] || bail_or_skip "could not determine the current nix system"

echo "crates.io download-URL contract (system: $SYSTEM)"

# -----------------------------------------------------------------------------
# 1. The overlay is imported by flake.nix.
# -----------------------------------------------------------------------------
if [ ! -f "$OVERLAY" ]; then
	fail "the overlay exists" "$OVERLAY is missing"
elif grep -q "nix/overlays/crates-io-download-url.nix" flake.nix; then
	pass "the overlay is imported by flake.nix"
else
	fail "the overlay is imported by flake.nix" \
		"flake.nix does not import $OVERLAY, so it fixes nothing"
fi

# -----------------------------------------------------------------------------
# 2/3. Instantiate the VENDOR DIRECTORY of each package that vendors crates
# through `importCargoLock`, and read every URL it fetches.
#
# `.cargoDeps` and not the package itself: that attribute IS the vendor
# directory, so its closure is exactly the crate tarballs and nothing else. The
# package's own closure additionally drags in every build tool in nixpkgs, whose
# crate fetches belong to package sets this flake does not construct -- see
# "WHAT IT DELIBERATELY DOES NOT ASSERT" above.
#
# `db-backend` builds `cargoDeps` with `rustPlatform.importCargoLock` directly;
# `backend-manager` reaches the same code through `buildRustPackage`'s
# `cargoLock` argument. Both shapes are covered on purpose: the overlay works by
# replacing `fetchurl` in the package set, and a change that reached only one of
# the two entry points would leave the other 403ing.
# -----------------------------------------------------------------------------
vendor_urls() { # attr -> every url/urls value in the vendor dir's closure
	nix derivation show -r ".#packages.$SYSTEM.$1.cargoDeps" 2>/dev/null |
		grep -oE '"https://[^"]+"' |
		tr -d '"' |
		sort -u
}

lock_crate_count() { # lockfile -> how many crates.io packages it names
	grep -c 'source = "registry+https://github.com/rust-lang/crates.io-index"' "$1"
}

for pkg in backend-manager db-backend; do
	lock="src/$pkg/Cargo.lock"
	if [ ! -f "$lock" ]; then
		fail "$pkg: its Cargo.lock is where this suite expects it" "$lock does not exist"
		continue
	fi
	expected=$(lock_crate_count "$lock")

	urls=$(vendor_urls "$pkg")
	if [ -z "$urls" ]; then
		fail "$pkg: its vendor directory instantiates" \
			"nix derivation show -r .#packages.$SYSTEM.$pkg.cargoDeps produced no URLs at all"
		continue
	fi

	legacy=$(printf '%s\n' "$urls" | grep -c "^$LEGACY_PREFIX")
	cdn=$(printf '%s\n' "$urls" | grep -c "^$CDN_PREFIX")

	if [ "$legacy" -eq 0 ]; then
		pass "$pkg: no crate is fetched from the crates.io API host"
	else
		fail "$pkg: no crate is fetched from the crates.io API host" \
			"$legacy crate(s) still fetch from $LEGACY_PREFIX, which answers 403 to fetchurl's User-Agent"
	fi

	# The accounting guard. "No legacy URLs" is also true of a vendor directory
	# with no crates in it, and true of one where half the crates moved. Both are
	# how a fix rots into a green tick, so compare against the lock file -- the
	# only statement of how many crates there are supposed to be.
	if [ "$cdn" -eq "$expected" ]; then
		pass "$pkg: all $cdn crates come from the CDN (= $lock's crates.io entries)"
	else
		fail "$pkg: all crates come from the CDN" \
			"$cdn crate(s) under $CDN_PREFIX, but $lock names $expected crates.io packages"
	fi
done

# -----------------------------------------------------------------------------
# 4. Fixed-output identity is untouched.
#
# `fetchurl` derivations are fixed-output, so the store path is a function of
# `name` and `outputHash` and NOT of the URL. That is the whole reason this fix
# costs nothing: no artefact changes identity and nothing cached is invalidated.
# It stops being true the moment someone edits the overlay to also touch `name`
# or the hash, and that damage is silent -- the build still succeeds, it just
# re-downloads and re-builds the world. So assert it rather than trust it.
# -----------------------------------------------------------------------------
probe_drv_json=$(nix derivation show -r ".#packages.$SYSTEM.backend-manager.cargoDeps" 2>/dev/null |
	tr ',' '\n' |
	grep -E "crate-$PROBE_CRATE-$PROBE_VERSION|$PROBE_CHECKSUM" |
	sort -u)

if grep -q "$PROBE_CHECKSUM" <<<"$probe_drv_json"; then
	pass "crate-$PROBE_CRATE-$PROBE_VERSION keeps the outputHash its Cargo.lock records"
else
	fail "crate-$PROBE_CRATE-$PROBE_VERSION keeps the outputHash its Cargo.lock records" \
		"the rewrite changed the fixed-output hash: every cached crate would be orphaned"
fi

if grep -q "crate-$PROBE_CRATE-$PROBE_VERSION" <<<"$probe_drv_json"; then
	pass "crate-$PROBE_CRATE-$PROBE_VERSION keeps its derivation name"
else
	fail "crate-$PROBE_CRATE-$PROBE_VERSION keeps its derivation name" \
		"the rewrite changed the derivation name, so its store path changed too"
fi

# -----------------------------------------------------------------------------
# 5. Nothing that is not a crates.io API URL is touched.
#
# The overlay replaces the package set's `fetchurl`. If its match were broader
# than the one prefix, the blast radius would be every fetch in the tree rather
# than the 143 crate tarballs it is meant to be. Compare one representative
# non-crate fetch derivation with and without the overlay: identical `.drv`
# paths means the overlay is provably inert for it.
# -----------------------------------------------------------------------------
NIXPKGS_REV=$(nix eval --raw --impure \
	--expr "(builtins.fromJSON (builtins.readFile $REPO_ROOT/flake.lock)).nodes.nixpkgs.locked.rev" 2>/dev/null)

if [ -z "$NIXPKGS_REV" ]; then
	fail "flake.lock names a locked nixpkgs revision" \
		"could not read .nodes.nixpkgs.locked.rev, so the inertness check cannot run"
else
	inert_expr() { # withOverlay(true|false) -> drvPath of a non-crates fetch
		nix eval --raw --impure --expr "
      let
        nixpkgs = builtins.getFlake \"github:NixOS/nixpkgs/$NIXPKGS_REV\";
        pkgs = import nixpkgs {
          system = \"$SYSTEM\";
        };
        pkgsWith = import nixpkgs {
          system = \"$SYSTEM\";
          overlays = [ (import $REPO_ROOT/$OVERLAY) ];
        };
        chosen = if $1 then pkgsWith else pkgs;
      in
      (chosen.fetchurl {
        name = \"crates-io-overlay-inertness-probe\";
        url = \"https://example.invalid/not-a-crate.tar.gz\";
        sha256 = \"0000000000000000000000000000000000000000000000000000000000000000\";
      }).drvPath
    " 2>/dev/null
	}
	without=$(inert_expr false)
	with=$(inert_expr true)
	if [ -z "$without" ] || [ -z "$with" ]; then
		fail "the overlay is inert for non-crates.io URLs" \
			"could not instantiate the probe (without='$without' with='$with')"
	elif [ "$without" = "$with" ]; then
		pass "the overlay is inert for non-crates.io URLs (identical .drv)"
	else
		fail "the overlay is inert for non-crates.io URLs" \
			"a non-crate fetch changed .drv: $without -> $with"
	fi
fi

# -----------------------------------------------------------------------------
# 6. LIVE: the host we now ask actually answers nixpkgs' fetcher.
#
# Everything above proves we ask a different host. Only this proves that host
# says yes -- with the exact User-Agent `pkgs.fetchurl` sends, which is the
# thing crates.io's API host rejects. It is deliberately forward-looking: it
# asserts the URL the build WILL use works, not that the old one is still
# broken, so it stays true if crates.io ever relaxes the policy.
#
# The control request runs first, so "the network is down" cannot be reported as
# "the CDN refused us".
# -----------------------------------------------------------------------------
if ! command -v curl >/dev/null 2>&1; then
	fail "the CDN serves nixpkgs' fetcher" "curl is not on PATH"
else
	CURL_VER=$(curl --version 2>/dev/null | head -1 | awk '{print $2}')
	NIX_UA="curl/${CURL_VER:-8.14.1} Nixpkgs/25.11"
	probe_url="${CDN_PREFIX}${PROBE_CRATE}/${PROBE_VERSION}/download"

	control=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
		https://cache.nixos.org/nix-cache-info 2>/dev/null)
	if [ "$control" != "200" ]; then
		bail_or_skip "no network (control request to cache.nixos.org returned '$control')"
	fi

	code=$(curl -sSL -o /dev/null -w '%{http_code}' --max-time 30 \
		-A "$NIX_UA" "$probe_url" 2>/dev/null)
	if [ "$code" = "200" ]; then
		pass "the CDN serves nixpkgs' fetcher UA ($probe_url -> 200)"
	else
		fail "the CDN serves nixpkgs' fetcher UA" \
			"$probe_url returned $code for User-Agent '$NIX_UA'. If this is 403, the CDN has adopted the API host's policy and this fix no longer works."
	fi
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
