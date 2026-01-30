# copied and adapted from https://nix.dev/tutorials/first-steps/declarative-shell.html
# however, using unstable like flake.nix
let

  nixpkgs = fetchTarball "https://github.com/NixOS/nixpkgs/tarball/nixos-unstable";

  pkgs = import nixpkgs {
    config = { };
    overlays = [ ];
  };

in

pkgs.mkShellNoCC {

  packages = with pkgs; [

    xvfb-run

  ];

}
