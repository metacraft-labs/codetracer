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
#   7. The one package this repository consumes from a FOREIGN flake's package
#      set -- `metacraft-labs.cargo-stylus`, which `nix/shells/ci-base.nix` puts
#      in the `ci` dev shell -- fetches no crate from the host that 403s, and
#      the reach mechanism that gets it there costs nothing: its store path is
#      the one the un-overridden attribute produces. An overlay declared here
#      cannot reach that package set, so this assertion covers a mechanism the
#      other six structurally cannot.
#
# WHAT IT DELIBERATELY DOES NOT ASSERT
# ------------------------------------
# That NO derivation anywhere in `.?submodules=1#codetracer`'s build closure
# uses the old URL. Measured: 957 still do, and they are not this repository's to fix -- they
# are crate fetches belonging to package sets that sibling flakes (`noir`,
# `wazero`, `nix-blockchain-development-sui`, ...) `import` themselves, which no
# overlay declared here can reach.
#
#   CORRECTION (2026-09-14). The sentence that used to follow -- "They are also
#   all substitutable from cache.nixos.org, so they only bite a machine forced
#   to build them from source" -- was WRONG about the half of them that matters,
#   and CI is what proved it. It holds for stock nixpkgs build tools. It does
#   NOT hold for metacraft-labs' OWN packages, which cache.nixos.org has never
#   heard of: `metacraft-labs.cargo-stylus` is in the `ci` dev shell, its
#   `nix-blockchain-development` package set carries NO overlay, and its 546
#   crate fetches all went to the host that 403s. Two LRC edges died there in
#   `nix develop '.?submodules=1#ci'` -- runs 34834104633 (js,
#   `crate-alloy-core-1.3.1`) and 34834129051 (ruby, `crate-alloy-eip2930-0.2.1`)
#   -- on a runner whose private Attic substituter answered 401, which is
#   exactly the "forced to build from source" case. Assertion 7 below now covers
#   `cargo-stylus` directly; `nix/packages/default.nix` says how it is reached
#   and why an overlay could not reach it.
#
# The general statement is otherwise unchanged: asserting zero-in-the-closure
# would be a red test this repository cannot turn green, and the thing that
# actually fixes it -- moving the shared nixpkgs pin in
# `metacraft-labs/nix-codetracer-toolchains` -- fixes it for every repo at once.
# Recorded in codetracer-specs/Testing/Known-Test-Failures.md.
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

# -----------------------------------------------------------------------------
# 7. The FOREIGN package set: `metacraft-labs.cargo-stylus`.
#
# Everything above covers packages this flake builds from its own `pkgs`, which
# the overlay reaches by construction. This one it does not: `cargo-stylus`
# comes from `nix-blockchain-development`, whose `flake.nix` builds its package
# set from a bare `import nixpkgs { config.allowUnfree = true; }` with no
# overlays at all. `nixpkgs.follows` shares the input, not the overlays, so its
# `fetchurl` is nixpkgs' unpatched one -- and `nix/packages/default.nix` reaches
# it with `.override { inherit pkgs; }` instead. See that file for the three
# narrower mechanisms that were measured and found inert.
#
# Two assertions, and the second is the one that keeps the reach honest:
#
#   a. no crate in its vendor directory comes from the host that 403s, and the
#      number that come from the CDN equals the number of crate tarball
#      derivations in that closure. As in (3), a bare "no legacy URLs" is also
#      true of an empty vendor directory and of a half-rewritten one.
#   b. the store path is the one the UN-OVERRIDDEN attribute produces. The
#      override re-instantiates a package from a different package set, which is
#      exactly the shape of change that silently orphans a cached closure --
#      here it does not, because the only difference is inside fixed-output
#      crate fetches and `hashDerivationModulo` looks through those. If a future
#      nixpkgs/config divergence makes it stop being true, this fails loudly
#      rather than quietly rebuilding cargo-stylus on every runner.
#
# It is also the assertion that notices `cargo-stylus/default.nix` changing its
# argument from `{ pkgs, ... }` to ordinary `callPackage` arguments: the
# `.override` would become a silent no-op, and (a) would go red.
# -----------------------------------------------------------------------------
stylus_deps_drv=$(nix eval --raw ".#packages.$SYSTEM.cargo-stylus.cargoDeps.drvPath" 2>/dev/null)
if [ -z "$stylus_deps_drv" ]; then
	fail "cargo-stylus: its vendor directory instantiates" \
		"nix eval .#packages.$SYSTEM.cargo-stylus.cargoDeps.drvPath produced nothing"
else
	stylus_json=$(nix derivation show -r "$stylus_deps_drv" 2>/dev/null)
	s_legacy=$(printf '%s' "$stylus_json" | grep -oE "\"${LEGACY_PREFIX}[^\"]+\"" | sort -u | grep -c .)
	s_cdn=$(printf '%s' "$stylus_json" | grep -oE "\"${CDN_PREFIX}[^\"]+\"" | sort -u | grep -c .)
	# Match a crate-tarball derivation by its store NAME, with the /nix/store/
	# prefix OPTIONAL. `nix derivation show` stopped emitting that prefix on its
	# keys and input references (Nix 2.32 prints `<hash>-crate-x.tar.gz.drv`), so
	# a pattern that required it counted ZERO crates against 545 CDN URLs and
	# failed the "every crate from the CDN" check while every crate WAS from the
	# CDN. Anchoring on the 32-char store hash keeps it from matching anything
	# that is not a store path, and the `.tar.gz.drv` tail still excludes a crate
	# merely NAMED like one (`proc-macro-crate-3.3.0.drv` is a build, not a
	# tarball). Works on either output format.
	s_crates=$(printf '%s' "$stylus_json" | grep -oE '"(/nix/store/)?[a-z0-9]{32}-crate-[^"]*\.tar\.gz\.drv"' | sed 's|"/nix/store/|"|' | sort -u | grep -c .)

	if [ "$s_legacy" -eq 0 ]; then
		pass "cargo-stylus: no crate is fetched from the crates.io API host"
	else
		fail "cargo-stylus: no crate is fetched from the crates.io API host" \
			"$s_legacy crate(s) still fetch from $LEGACY_PREFIX; this is what killed the ci dev shell in runs 34834104633 and 34834129051"
	fi

	if [ "$s_crates" -gt 0 ] && [ "$s_cdn" -eq "$s_crates" ]; then
		pass "cargo-stylus: all $s_cdn crate tarballs come from the CDN (= every crate derivation in the closure)"
	else
		fail "cargo-stylus: all crate tarballs come from the CDN" \
			"$s_cdn CDN URL(s) against $s_crates crate derivation(s) in the vendor closure"
	fi
fi

stylus_ours=$(nix eval --raw ".#packages.$SYSTEM.cargo-stylus.outPath" 2>/dev/null)
stylus_theirs=$(nix eval --raw --impure --expr \
	"(builtins.getFlake (toString $REPO_ROOT)).inputs.nix-blockchain-development.legacyPackages.\"$SYSTEM\".metacraft-labs.cargo-stylus.outPath" 2>/dev/null)
if [ -z "$stylus_ours" ] || [ -z "$stylus_theirs" ]; then
	fail "cargo-stylus: the reach mechanism costs nothing" \
		"could not instantiate both sides (ours='$stylus_ours' theirs='$stylus_theirs')"
elif [ "$stylus_ours" = "$stylus_theirs" ]; then
	pass "cargo-stylus: the reach mechanism costs nothing (identical store path)"
else
	fail "cargo-stylus: the reach mechanism costs nothing" \
		"the override changed the store path: $stylus_theirs -> $stylus_ours. Every consumer would rebuild and nothing cached would substitute."
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
