let
  pkgs = import <nixpkgs> { };
in
pkgs.mkShell {
  buildInputs = with pkgs; [
    bash
    mdbook
  ];
  nativeBuildInputs = with pkgs; [
    bash
    mdbook
  ];
}
