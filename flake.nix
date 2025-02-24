{
  description = "Code Tracer";

  nixConfig = {
    extra-substituters = ["https://metacraft-labs-codetracer.cachix.org"];
    extra-trusted-public-keys = ["metacraft-labs-codetracer.cachix.org-1:6p7pd81m6sIh59yr88yGPU9TFYJZkIrFZoFBWj/y4aE="];
  };

  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixos-unstable;
    nixpkgs-unstable.url = github:NixOS/nixpkgs/nixos-unstable;

    appimage-channel.url = "github:NixOS/nixpkgs/nixos-24.11";

    flake-utils.url = github:numtide/flake-utils;

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    noir = {
      url = "github:blocksense-network/noir?ref=blocksense";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
      flake = true;
    };
  };

  # outputs = {
  #   nixpkgs,
  #   flake-utils,
  # }: let
  #   system = "x86_64-linux";
  #   pkgs = import nixpkgs {
  #     inherit system;
  #     overlays = [(import ./overlay.nix)];

  #     config = {
  #       permittedInsecurePackages = [
  #         "electron-13.6.9"
  #       ];
  #       # allowUnfree = true;
  #     };
  #   };
  #   # node2nixOutput = import ./src { inherit pkgs   system; };
  #   # nodeDeps = node2nixOutput.nodeDependencies;
  # in {
  #   # pkgs.overlays = [ (import ./overlay.nix) ];
  #   devShell."${system}" = import ./shell.nix {inherit pkgs;};
  # };

  outputs = inputs @ {
    nixpkgs,
    nixpkgs-unstable,
    flake-parts,
    fenix,
    ...
  }:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
      imports = [
        ./nix/shells
        ./nix/packages
      ];

      perSystem = {system, ...}: {
        _module.args.pkgs = import nixpkgs {
          inherit system;
          config = {
            # tup is currently considered broken by Nix, but this is not true
            # TODO: this is already fixed in nixpkgs/unstable, so it may become
            #       unnecessary after a future `flake update`
            allowBroken = true;
            permittedInsecurePackages = [
              "electron-24.8.6"
            ];
          };
        };

        _module.args.unstablePkgs = import nixpkgs-unstable {
          inherit system;
          config = {
            permittedInsecurePackages = [
              "electron-24.8.6"
            ];
          };
        };
      };
    };
}
