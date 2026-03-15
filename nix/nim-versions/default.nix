# Multiple Nim compiler versions
#
# Usage in flake.nix:
#   nimVersions = import ./nix/nim-versions { inherit pkgs; };
#   # Then use nimVersions.nim-1_6, nimVersions.nim-2_0, etc.
#
# Or add to shell packages:
#   packages = [ nimVersions.nim-1_6 nimVersions.nim-2_2 ];

{ pkgs }:

let
  # Nim versions and their corresponding hashes
  # To add a new version:
  #   nix-prefetch-url https://nim-lang.org/download/nim-X.Y.Z.tar.xz
  #   nix hash convert --hash-algo sha256 --to sri <hash>
  versions = {
    "1.6.20" = "sha256-/+0EdQTR/K9hDw3Xzz4Ce+kaKSsMnFEWFQTC87mE/7k=";
    "2.0.14" = "sha256-1CC5VYMylLeGHj+2UCHawm0cGcUoxNbhOczTeeLBWkM=";
    "2.2.6" = "sha256-ZXsOPV3veIFI0qh/phI/p1Wy2SytMe9g/SYeRReFUos=";
  };

  # Build Nim for a specific version.
  #
  # When nixpkgs already ships the same major.minor (e.g. nixpkgs has 2.2.4
  # and we want 2.2.x), use nim-unwrapped directly. Overriding the point
  # release causes patch-application failures because nixpkgs patches
  # (NIM_CONFIG_DIR, nixbuild, etc.) are version-specific and may not apply
  # to a different point release's source tree.
  #
  # For a different major.minor (e.g. requesting 1.6.x when nixpkgs has 2.2.x),
  # we must override and drop the patches entirely.
  mkNim =
    version: hash:
    let
      nixpkgsNimVersion = pkgs.lib.versions.majorMinor pkgs.nim-unwrapped.version;
      targetMajorMinor = pkgs.lib.versions.majorMinor version;
      sameMajorMinor = nixpkgsNimVersion == targetMajorMinor;
    in
    if sameMajorMinor then
      # Reuse nixpkgs' nim-unwrapped (with its working patches) rather than
      # risking patch conflicts from a different point release.
      pkgs.nim-unwrapped
    else
      pkgs.nim-unwrapped.overrideAttrs (old: {
        inherit version;
        pname = "nim";
        src = pkgs.fetchurl {
          url = "https://nim-lang.org/download/nim-${version}.tar.xz";
          inherit hash;
        };
        patches = [ ];
      });

in
{
  nim-1_6 = mkNim "1.6.20" versions."1.6.20";
  nim-2_0 = mkNim "2.0.14" versions."2.0.14";
  nim-2_2 = mkNim "2.2.6" versions."2.2.6";

  # Convenient aliases
  nim1 = mkNim "1.6.20" versions."1.6.20";
  nim2 = mkNim "2.2.6" versions."2.2.6";

  # nim-devel: built from the third_party/nim-lang checkout (upstream devel branch).
  # TODO: Uncomment when building Nim from source in nix is validated.
  # Building Nim from source requires csources bootstrap which may need
  # additional nix packaging work.
  # nim-devel = pkgs.nim-unwrapped.overrideAttrs (old: {
  #   version = "devel";
  #   pname = "nim-devel";
  #   src = ../../third_party/nim-lang;
  #   patches = [];
  # });

  # For programmatic access
  inherit versions mkNim;
}
