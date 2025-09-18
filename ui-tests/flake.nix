{
  description = "Dev shell for C# Playwright UI tests";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
	  };
        };
        dotnet-full =
          with pkgs.dotnetCorePackages;
          combinePackages [
            sdk_8_0
            runtime_8_0
          ];

        deps = (
          ps:
          with ps;
          [
            rustup
            zlib
            pkg-config
            stdenv.cc
            cmake
            openssl
          ]
          ++ [ dotnet-full ]
        );

        vscode =
          (pkgs.vscode.overrideAttrs (prevAttrs: {
            nativeBuildInputs = prevAttrs.nativeBuildInputs ++ [ pkgs.makeWrapper ];
            postFixup =
              prevAttrs.postFixup
              + ''
                wrapProgram $out/bin/code \
                  --set DOTNET_ROOT "${dotnet-full}/share/dotnet" \
                  --prefix PATH : "~/.dotnet/tools"
              '';
          })).fhsWithPackages
            (ps: deps ps);

      in
      {
        devShells.default = pkgs.mkShell {
          packages = [
            vscode
            dotnet-full
            pkgs.xvfb-run
            pkgs.nodejs_22
            pkgs.playwright
            pkgs.playwright-driver.browsers
          ];
          shellHook = ''
            export PLAYWRIGHT_BROWSERS_PATH=${pkgs.playwright-driver.browsers}
            export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1

            export NIX_NODE=${pkgs.nodejs_22.outPath}/bin/node
          '';
        };
      }
    );
}

# # TODO: eventually check if node already the correct nix one?

#             dotnet build
#             rm bin/Debug/net8.0/.playwright/node/linux-x64/node && \
#               cp ${pkgs.nodejs_22.outPath}/bin/node bin/Debug/net8.0/.playwright/node/linux-x64/node
            
# TODO add similar for now to ui-tests run script