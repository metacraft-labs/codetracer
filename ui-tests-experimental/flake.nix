{
  description = "Dev shell for experimental C# Playwright UI console app";

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
            permittedInsecurePackages = [
              "openssl-1.1.1w" # for openssl_1_1
            ];
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
            openssl.dev
            pkg-config
            stdenv.cc
            cmake
            # openssl_3
            openssl_1_1
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
            pkgs.nodejs_22
            pkgs.playwright
            pkgs.playwright-driver.browsers
          ];
          shellHook = ''
            export PLAYWRIGHT_BROWSERS_PATH=${pkgs.playwright-driver.browsers}
            export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1
          '';
        };
      }
    );
}
