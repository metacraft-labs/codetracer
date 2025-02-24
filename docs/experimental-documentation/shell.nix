let
  pkgs = import <nixpkgs> {};
in
  pkgs.mkShell {
    buildInputs = with pkgs; [
      bash
      terser
      pandoc
      parallel
    ];
    nativeBuildInputs = with pkgs; [
      bash
      terser
      pandoc
      parallel
    ];
  }