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
                config.pre-commit.devShell
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
