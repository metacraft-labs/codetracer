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

  windows-electron =
    with pkgs;
    fetchurl {
      # TODO: Don't hardcode versions and architecture
      url = "https://github.com/electron/electron/releases/download/v35.1.2/electron-v35.1.2-win32-x64.zip";
      hash = "sha256-uyCZ5jcnZkUBTFfPuHYrBY/Fcc/V5+5s6OpRIaSskwA=";
    };
in
with pkgs;
mkShell {

  hardeningDisable = [ "all" ];

  inputsFrom = [ windows-electron ];

  packages = [

    # Electron

    # Rust cross-compilation
    windows-rust
    cargo-xwin
    clang_19

    llvm

    pkgsCross.mingwW64.buildPackages.gcc

    # Nim cross-compilation
    ourPkgs.upstream-nim-codetracer

    # Node
    nodejs-18_x
    nodePackages.webpack-cli
    corepack

    # Testing
    wine
    wine64

  ];

}
