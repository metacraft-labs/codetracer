# Multiple Rust compiler versions via fenix
#
# Usage in flake.nix:
#   rustVersions = import ./nix/rust-versions { inherit pkgs fenix; };
#   # Then use rustVersions.rust-stable, rustVersions.rust-nightly, etc.
#
# Or add to shell packages:
#   packages = [ rustVersions.rust-stable rustVersions.rust-1_75 ];

{ pkgs, fenix }:

let
  # Fenix provides toolchains for different channels
  fenixPkgs = fenix.packages.${pkgs.system};

  # Create a complete toolchain from a fenix channel
  mkRustToolchain = channel: channel.withComponents [
    "cargo"
    "clippy"
    "rust-src"
    "rustc"
    "rustfmt"
  ];

  # Specific versions we want to support for testing
  # These are selected to cover a range of Rust versions
  specificVersions = {
    # Older stable versions for compatibility testing
    "1.75.0" = fenixPkgs.toolchainOf {
      channel = "1.75.0";
      sha256 = "sha256-SXRtAuO4IqNOQq+nLbrsDFbVk+3aVA8NNpSZsKlVH/8=";
    };
    "1.80.0" = fenixPkgs.toolchainOf {
      channel = "1.80.0";
      sha256 = "sha256-6eN/GKzjVSjEhGO9FhWObkRFaE1Jf+uqMSdQnb8lcB4=";
    };
  };

in {
  # Current stable channel
  rust-stable = mkRustToolchain fenixPkgs.stable;

  # Nightly channel
  rust-nightly = mkRustToolchain fenixPkgs.latest;

  # Specific versions for reproducible testing
  rust-1_75 = mkRustToolchain specificVersions."1.75.0";
  rust-1_80 = mkRustToolchain specificVersions."1.80.0";

  # Convenient aliases
  stable = mkRustToolchain fenixPkgs.stable;
  nightly = mkRustToolchain fenixPkgs.latest;

  # For programmatic access
  inherit specificVersions mkRustToolchain;
}
