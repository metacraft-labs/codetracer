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
