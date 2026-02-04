{ ... }:
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
            self'
            inputs'
            config
            ;
        };
        ci = import ./ci.nix { inherit pkgs self'; };
        ui-tests = import ./ui-tests.nix { inherit pkgs; };
      };
    };
}
