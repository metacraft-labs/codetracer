let
  pkgs = import <nixpkgs> {};
in
  pkgs.mkShell {
    buildInputs = with pkgs; [
      bash
      mdbook
      mdbook-alerts     
    ];
    nativeBuildInputs = with pkgs; [
      bash
      mdbook
      mdbook-alerts
    ];
  }