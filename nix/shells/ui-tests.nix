{
  pkgs,
}:
let
  dotnet-full = pkgs.dotnetCorePackages.combinePackages [
    pkgs.dotnetCorePackages.sdk_8_0
    pkgs.dotnetCorePackages.runtime_8_0
  ];
in
with pkgs;
mkShell {
  packages = [
    dotnet-full
    xvfb-run
    nodejs_22
    playwright
    playwright-driver.browsers
    just
    xorg.xorgserver # provides Xephyr for visible virtual X11
  ];

  shellHook = ''
    export PLAYWRIGHT_BROWSERS_PATH=${pkgs.playwright-driver.browsers}
    export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1

    # used in ui-tests/dotnet_build.sh
    export NIX_NODE=${pkgs.nodejs_22.outPath}/bin/node

    # Runtime library path for the ct binary which uses dlopen for openssl, sqlite, etc.
    export LD_LIBRARY_PATH="${pkgs.openssl.out}/lib:${pkgs.sqlite.out}/lib:${pkgs.pcre.out}/lib:${pkgs.glib.out}/lib:${pkgs.gcc.cc.lib}/lib:${pkgs.libzip.out}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  '';
}
