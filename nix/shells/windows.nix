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

  hardeningDisable = [ "all" ];

  packages = [

    # Rust cross-compilation
    windows-rust
    cargo-xwin
    clang_19

    llvm

    pkgsCross.mingwW64.buildPackages.gcc

    # Nim cross-compilation
    ourPkgs.upstream-nim-codetracer

    # Testing
    wine
    wine64

  ];

}
