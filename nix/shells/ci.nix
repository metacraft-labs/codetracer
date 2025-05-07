{
  pkgs,
  self',
}: let
  ourPkgs = self'.packages;
in
  pkgs.mkShell {
    packages = with pkgs; [
      python3Packages.flake8
      shellcheck
      xz
      gnutar
      pkgs.gawk
    ];
  }
