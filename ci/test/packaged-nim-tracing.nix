# The `codetracer` Nix package's `ct` wrapper, applied to a stub `ct` that
# prints its environment -- for `ci/test/packaged-nim-tracing.sh --nix`.
#
# Why a stub and not `nix build .#codetracer`: the package also pulls in the
# whole `runtime-deps` closure (recorders, db-backend, Electron, ...), and what
# this test asks is only what environment the INSTALLED `ct` hands the desktop.
# The wrapper is the package's own evaluated `postFixup`, unchanged; the
# `runtime-deps` and `cargo-stylus` references stay in it as strings but are
# not built (the first is `CODETRACER_PREFIX`, the second a PATH entry; Nim
# tracing reads neither). Every other store path the wrapper names, the
# language server and the nimsuggest among them, is built.
{
  repo,
  system ? builtins.currentSystem,
}:
let
  flake = builtins.getFlake "git+file://${repo}?submodules=1";
  pkg = flake.packages.${system}.codetracer;
  pkgs = flake.inputs.nixpkgs.legacyPackages.${system};
  lib = flake.inputs.nixpkgs.lib;
  heavy = p: lib.hasInfix "runtime-deps" p || lib.hasInfix "cargo-stylus" p;
  dropHeavy =
    s:
    let
      ctx = lib.filterAttrs (p: _: !(heavy p)) (builtins.getContext s);
    in
    builtins.appendContext (builtins.unsafeDiscardStringContext s) ctx;
in
pkgs.runCommand "codetracer-ct-wrapper-env" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
  mkdir -p $out/bin
  printf '#!%s\nexec %s\n' ${pkgs.bash}/bin/bash ${pkgs.coreutils}/bin/env > $out/bin/ct
  chmod +x $out/bin/ct
  ${dropHeavy pkg.postFixup}
''
