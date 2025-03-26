{
  pkgs,
  inputs',
  self',
}:
let
  ourPkgs = self'.packages;
  windows-rust =
    with inputs'.fenix.packages;
    with latest;
    combine [
      cargo
      rustc
      llvm-tools
      targets.x86_64-pc-windows-msvc.latest.rust-std
    ];
in
with pkgs;
mkShell {
  packages = [

    windows-rust
    cargo-xwin
    clang

  ];
}
