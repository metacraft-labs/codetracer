# The `bin/` of the `codetracer` Nix package, built by the package's OWN
# buildPhase and postFixup (CTC-3i) — for `ci/test/nix-package-ct-test-run.sh`.
#
# Why a slice and not `nix build .#codetracer`: the package also pulls in the
# whole `runtime-deps` closure (recorders, db-backend, Electron, …), which takes
# long to build and fails for reasons unrelated to `ct` itself. The slice keeps
# the parts that decide whether `ct test run` works from an install: the
# evaluated buildPhase that compiles `ct` (refc) and `ct-test` (ORC), the same
# `bin/` layout, and the same `wrapProgram` wrapper around `ct`. Only the
# `ls -al` diagnostics are dropped, and every reference to `runtime-deps` is
# kept as a string but not as a build input (it is the baked-in
# `CODETRACER_PREFIX`, which `ct test run` does not read).
#
# The asserts are on the EVALUATED derivation, not on the recipe's text: the
# package must compile `ct-test` with `--mm:orc` and install it to `$out/bin`.
{
  repo,
  system ? builtins.currentSystem,
}:
let
  flake = builtins.getFlake "git+file://${repo}?submodules=1";
  pkg = flake.packages.${system}.codetracer;
  lib = flake.inputs.nixpkgs.lib;
  heavy = p: lib.hasInfix "runtime-deps" p;
  dropHeavy =
    s:
    let
      ctx = lib.filterAttrs (p: _: !(heavy p)) (builtins.getContext s);
    in
    builtins.appendContext (builtins.unsafeDiscardStringContext s) ctx;
  keepLine = l: !(lib.hasPrefix "ls -al" (lib.trim l));
in
assert lib.assertMsg (lib.hasInfix "--out:ct-test c ./src/ct_test/ct_test.nim" pkg.buildPhase)
  "the codetracer package does not compile ct-test";
assert lib.assertMsg (lib.hasInfix "--mm:orc" pkg.buildPhase)
  "the codetracer package does not compile anything with --mm:orc";
assert lib.assertMsg (lib.hasInfix "cp ./ct-test $out/bin" pkg.installPhase)
  "the codetracer package does not install ct-test into $out/bin";
assert lib.assertMsg (lib.hasInfix "/bin/io-mon $out/bin/" pkg.installPhase)
  "the codetracer package does not install the io-mon CLI into $out/bin";
assert lib.assertMsg (lib.hasInfix "/lib/librepro_monitor_shim.* $out/lib/" pkg.installPhase)
  "the codetracer package does not install the io-mon shim into $out/lib";
pkg.overrideAttrs (old: {
  name = "codetracer-bin-slice";
  nativeBuildInputs = builtins.filter (d: !(heavy (d.name or ""))) old.nativeBuildInputs;
  buildPhase = dropHeavy (
    lib.concatStringsSep "\n" (builtins.filter keepLine (lib.splitString "\n" pkg.buildPhase))
  );
  # The package's `bin/` and `lib/` as its installPhase lays them out: `ct`
  # and `ct-test` side by side, and the io-mon monitor `ct-test` captures its
  # read set with -- the CLI in `bin/`, the shim in `lib/` (`db-backend-record`
  # and `ct-remote` play no part here).
  installPhase = ''
    mkdir -p $out/bin $out/lib
    cp ./ct $out/bin
    cp ./ct-test $out/bin
    cp ${pkg.ctIoMon}/bin/io-mon $out/bin/
    cp ${pkg.ctIoMon}/lib/librepro_monitor_shim.* $out/lib/
  '';
  postFixup = dropHeavy old.postFixup;
})
