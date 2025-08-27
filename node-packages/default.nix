# This is a minimal `default.nix` by yarn-plugin-nixify. You can customize it
# as needed, it will not be overwritten by the plugin.

{ pkgs ? import <nixpkgs> { } }:

pkgs.callPackage ./yarn-project.nix {
  # Use the pinned Electron runtime during evaluation so builds stay
  # consistent and electron-builder can reuse it.
  electron = pkgs.electron_33;
} { src = ./.; }
