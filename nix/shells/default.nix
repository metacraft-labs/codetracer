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
        with-sui = import ./main.nix {
          inherit
            pkgs
            self'
            inputs'
            config
            ;
          includeSui = true;
        };
        ci = import ./ci.nix { inherit pkgs self'; };
      };
    };
}
