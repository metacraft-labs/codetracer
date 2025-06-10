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
      rust-backend = import ./rust-backend.nix {inherit pkgs self' inputs';};
      electron-gui = import ./electron-gui.nix {inherit pkgs self' inputs';};
    };
  };
}
