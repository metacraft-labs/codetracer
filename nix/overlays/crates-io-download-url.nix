# =============================================================================
# crates-io-download-url.nix — route nixpkgs' crate fetcher at the crates.io
# CDN instead of the crates.io API host.
#
# WHAT BROKE
# ----------
# `nix build .#backend-manager` (and with it `.#codetracer` and every job
# downstream of the app build) could not fetch a single Rust crate source.
# Every crate tarball ended in:
#
#     curl: (22) The requested URL returned error: 403
#     error: cannot download crate-<name>-<version>.tar.gz from any mirror
#
# The cause is a SERVER-SIDE POLICY CHANGE at crates.io, not a defect in this
# repository or in this machine. crates.io's API host now rejects any request
# whose User-Agent looks like `curl/*`. Measured against
# `https://crates.io/api/v1/crates/serde/1.0.219/download`:
#
#     default `curl/8.14.1`                    -> 403
#     `curl/8.14.1 Nixpkgs/25.11`              -> 403   <- what fetchurl sends
#     `codetracer-nix-fetch`                   -> 200
#     same crate from `static.crates.io`, any UA -> 200
#
# `pkgs.fetchurl` sends exactly the second one (nixpkgs' builder.sh sets
# `--user-agent "curl/$curlVersion Nixpkgs/$nixpkgsVersion"`), so every
# `importCargoLock` fetch is refused. This is not specific to a sandbox, a
# platform or a network: it breaks any machine that BUILDS from source rather
# than substituting a prebuilt closure from a binary cache. Upstream tracks it
# as https://github.com/rust-lang/crates.io/issues/13482.
#
# WHY THIS LAYER
# --------------
# Nixpkgs already fixed it, by pointing the crates.io registry's download base
# at the CDN:
#
#     -  "https://github.com/rust-lang/crates.io-index" = "https://crates.io/api/v1/crates";
#     +  "https://github.com/rust-lang/crates.io-index" = "https://static.crates.io/crates";
#
# (`pkgs/build-support/rust/import-cargo-lock.nix`). This repository cannot
# simply take that fix: `nixpkgs` here `follows` `codetracer-toolchains/nixpkgs`
# so that every CodeTracer repo links against the same glibc/libstdc++/LLDB, and
# the pin is 25.11 @ 47472570, which predates the backport. Moving the pin is
# the DURABLE fix and it belongs in `metacraft-labs/nix-codetracer-toolchains`,
# where it can be rolled out to every repo at once. See
# `codetracer-specs/Testing/Known-Test-Failures.md`.
#
# This overlay applies the identical URL substitution locally, one layer lower —
# at `fetchurl` rather than at the registry table — because `rustPlatform` in
# this nixpkgs exposes neither `importCargoLock.override` nor
# `buildRustPackage.override`, and `importCargoLock`'s public `extraRegistries`
# argument cannot be used to REPLACE the crates.io entry without also emitting a
# spurious `[source."https://github.com/rust-lang/crates.io-index"]` stanza into
# the vendor directory's `.cargo/config.toml` (that argument feeds both the
# registry table and the generated config).
#
# COST: NONE. `fetchurl` derivations are fixed-output, so changing the URL
# changes the `.drv` but NOT the output path — and Nix hashes a dependent
# derivation over a fixed-output input's OUTPUT HASH, not its `.drv` path
# (`hashDerivationModulo`). Measured on `serde-1.0.219`:
#
#     crate tarball, without overlay -> /nix/store/iqx8iic36d6awgrijym7c6zdbaynzz3v-crate-serde-1.0.219.tar.gz
#     crate tarball, with overlay    -> /nix/store/iqx8iic36d6awgrijym7c6zdbaynzz3v-crate-serde-1.0.219.tar.gz
#     cargo-vendor-dir, without      -> /nix/store/skaniljiawcp8zyaygp9vr6gik1lp60y-cargo-vendor-dir
#     cargo-vendor-dir, with         -> /nix/store/skaniljiawcp8zyaygp9vr6gik1lp60y-cargo-vendor-dir
#
# so no artefact changes identity, nothing already in a binary cache is
# invalidated, and no derivation downstream of a crate rebuilds.
#
# IT DOES NOT ROT. The rewrite is keyed on the OLD prefix and is idempotent: the
# moment the nixpkgs pin moves to a revision that already points at
# `static.crates.io`, no URL matches and this overlay becomes an exact no-op
# that can be deleted at leisure rather than a shim that has to be maintained.
# `ci/test/crates-io-download-url-test.sh` asserts the end state — that the URL
# a crate is actually fetched from is one this repository has verified serves
# nixpkgs' fetcher — so if either the overlay or a future pin stops delivering
# that, the failure is loud and names the reason.
#
# WHY `fetchurl` AND NOT SOMETHING NARROWER: `importCargoLock` takes `fetchurl`
# from the package set's own scope, so replacing it here reaches every consumer
# (`rustPlatform.importCargoLock` directly, and `buildRustPackage`'s `cargoLock`
# argument) without this file having to know nixpkgs' internal file layout. The
# `__functor` shape of `prev.fetchurl` is preserved rather than replaced with a
# bare lambda, so `fetchurl.override` and friends still exist for anything that
# reaches for them.
#
# `cargoHash`-based derivations (`fetchCargoVendor`, e.g. `codex-acp` in
# nix/packages/default.nix) are NOT affected and need no fix: they run `cargo`
# itself inside a fixed-output derivation, and cargo sends its own `cargo/1.x`
# User-Agent, which crates.io accepts.
# =============================================================================
final: prev:
let
  inherit (prev) lib;

  # The download base nixpkgs 25.11 @ 47472570 uses for the crates.io registry.
  legacyBase = "https://crates.io/api/v1/crates/";

  # The download base nixpkgs uses after the backport. The path shape is
  # unchanged -- `<base>/<name>/<version>/download` -- and the CDN serves it:
  # `https://static.crates.io/crates/serde/1.0.219/download` answers 200 with
  # 78983 bytes, byte-identical to the API host's answer, for every User-Agent
  # tried including nixpkgs' own.
  cdnBase = "https://static.crates.io/crates/";

  rewriteUrl =
    url: if lib.hasPrefix legacyBase url then cdnBase + lib.removePrefix legacyBase url else url;

  # `fetchurl` accepts either `url` or `urls`. `importCargoLock` passes `url`;
  # both are handled so this cannot become a partial fix if a caller changes.
  rewriteAttrs =
    attrs:
    attrs
    // lib.optionalAttrs (attrs ? url) { url = rewriteUrl attrs.url; }
    // lib.optionalAttrs (attrs ? urls) { urls = map rewriteUrl attrs.urls; };

  # `fetchurl` is an `lib.extendMkDerivation` result in this nixpkgs, so it
  # accepts BOTH the plain attribute set and the `finalAttrs: { ... }` fixed-
  # point form that `mkDerivation` takes. Handling only the first shape made
  # every derivation whose closure contains a `fetchurl (finalAttrs: ...)` call
  # -- `cargo` itself, via `auditable-cargo`, on the way to `backend-manager` --
  # die with `expected a set but found a function`, which is why both are
  # handled here rather than the one shape `importCargoLock` happens to use.
  rewriteArgs =
    args:
    if lib.isFunction args then (finalAttrs: rewriteAttrs (args finalAttrs)) else rewriteAttrs args;
in
{
  fetchurl = prev.fetchurl // {
    __functor = _self: args: prev.fetchurl (rewriteArgs args);
  };
}
