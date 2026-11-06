# Evaluate only the pinned hook module, not CodeTracer's unrelated toolchains.
# The checker is real; a local config keeps this suite about hook installation.
{
  upgraded ? false,
  addGcRoot ? true,
}:
let
  flake = builtins.getFlake (toString ../..);
  pkgs = flake.inputs.nixpkgs.legacyPackages.${builtins.currentSystem};
  checked = flake.inputs.git-hooks-nix.lib.${builtins.currentSystem}.run {
    src = ../..;
    inherit addGcRoot;
    # Different real configuration bytes, without changing checker scope for
    # any fixture file, model a shell entered at a newer flake configuration.
    excludes = pkgs.lib.optional upgraded "^__not_a_fixture_file__$";
    hooks.trim-trailing-whitespace = {
      enable = true;
      stages = [
        "pre-commit"
        "pre-push"
      ];
    };
  };
  preCommit = {
    settings = checked.config;
    inherit (checked.config) installationScript;
  };
  repro = flake.inputs.reprobuild.packages.${builtins.currentSystem}.reprobuild;
in
pkgs.writeShellScript "codetracer-git-hooks-fixture" ''
  # Match production shellHook: no errexit in the calling shell.
  set -uo pipefail
  if [ "''${1:-}" = --repro-bin ]; then
    printf '%s\n' ${repro}/bin/repro
    exit 0
  fi
  if [ "''${1:-}" = --config-file ]; then
    printf '%s\n' ${preCommit.settings.configFile}
    exit 0
  fi
  if [ "''${1:-}" = --relative-native ]; then
    ${pkgs.lib.getExe preCommit.settings.package} install --config .pre-commit-config.yaml --hook-type pre-commit --hook-type pre-push
    exit $?
  fi
  ROOT_PATH=$(git rev-parse --show-toplevel)
  ${import ../../nix/git-hooks.nix {
    inherit preCommit repro;
    inherit (pkgs) lib writeShellScript;
  }}
  if [ "''${1:-}" = --audit-config ]; then
    git config --get ct.test
  fi
  echo 'CodeTracer hook setup completed'

''
