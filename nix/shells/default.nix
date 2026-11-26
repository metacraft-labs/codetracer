{ inputs, ... }:
{
  perSystem =
    {
      pkgs,
      self',
      inputs',
      config,
      ...
    }:
    {
      devShells = {
        # Run the existing configured hooks without the full development SDK.
        pre-commit =
          let
            nativeBackendEnv = import ../backend-native-env.nix {
              inherit pkgs inputs;
              nimCompiler = self'.packages.nim-codetracer;
            };
          in
          pkgs.mkShell (
            {
              # Preserve the configured hook tools before backend compiler inputs.
              inputsFrom = [
                # The hook tools only, NOT git-hooks.nix's own shellHook:
                # mkShell concatenates the shellHook of every inputsFrom
                # entry, and that one is the upstream installationScript. Run
                # on entry, it moved the shared Reprobuild dispatchers for
                # pre-commit and pre-push to `.legacy` and took their slots
                # with relative-config pre-commit shims, so the main
                # checkout's publication gate stopped running (2026-11-26).
                # Hooks are installed only by devShells.default, through
                # nix/git-hooks.nix, which keeps the dispatchers.
                # ci/test/pre-commit-shell-keeps-dispatchers-test.sh.
                (config.pre-commit.devShell.overrideAttrs (_: {
                  shellHook = "";
                }))
                # A complete backend derivation also contributes its test-only
                # inputs (including Noir). Hooks need the shared compiler inputs,
                # not a build of every recorder used by backend runtime tests.
                (pkgs.mkShell { inherit (nativeBackendEnv) nativeBuildInputs; })
              ];
              shellHook = nativeBackendEnv.shellHook;
            }
            // nativeBackendEnv.environment
          );
        default = import ./main.nix {
          inherit
            pkgs
            inputs
            self'
            inputs'
            config
            ;
        };
        ci = import ./ci.nix {
          inherit
            pkgs
            inputs
            self'
            inputs'
            ;
        };
        # `pkgs` ONLY, and the narrowness is the whole feature — see the header
        # of ./lint.nix. Passing `self'` or `inputs'` here would force the
        # evaluation this shell exists to avoid, and it would do so silently.
        lint = import ./lint.nix { inherit pkgs; };
      };
    };
}
