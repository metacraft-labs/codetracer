# CI dev shell.
#
# This is the shell every CI step uses to build / test codetracer's
# own components (the `ct` binary, the db-backend Rust crate, the
# frontend webpack bundle, the recorders covered by current lanes).
# Downstream test code that lives in *other* repos (the VS Code
# extension's WDIO suite, the agent-harbor MCP probe scripts, etc.)
# should be invoked via `direnv exec <repo>` against ITS OWN flake's
# `devShells.ci`, not against this one.
#
# All package + shellHook content lives in ./ci-base.nix so the
# `devShells.default` (main.nix) can compose cleanly on top.
{
  pkgs,
  inputs,
  inputs',
  self',
}:
let
  base = import ./ci-base.nix {
    inherit
      pkgs
      inputs
      inputs'
      self'
      ;
  };
in
pkgs.mkShell {
  hardeningDisable = [ "all" ];
  packages = base.packages;
  shellHook = base.shellHook;
}
