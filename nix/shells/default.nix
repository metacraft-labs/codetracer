{...}: {
  perSystem = {
    pkgs,
    self',
    inputs',
    ...
  }: {
    devShells = {
      default = import ./main.nix {inherit pkgs self' inputs';};
      ci = import ./ci.nix {inherit pkgs self';};
    };
  };
}
