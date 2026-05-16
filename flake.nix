{
  description = "Code Tracer";

  nixConfig = {
    extra-substituters = [ "https://metacraft-labs-codetracer.cachix.org" ];
    extra-trusted-public-keys = [
      "metacraft-labs-codetracer.cachix.org-1:6p7pd81m6sIh59yr88yGPU9TFYJZkIrFZoFBWj/y4aE="
    ];
  };

  inputs = {
    # Multi-language toolchain management.
    # All CodeTracer repos share the same nixpkgs pin via this flake to ensure
    # ABI compatibility (same glibc, libstdc++, LLDB, etc.) across dev shells.
    # See: codetracer-specs/Working-with-the-CodeTracer-Repos.md
    codetracer-toolchains.url = "github:metacraft-labs/nix-codetracer-toolchains";

    # Use the toolchains flake's nixpkgs pin. This ensures binaries built in
    # this shell are link-compatible with binaries from sibling repos that also
    # follow the same pin (e.g. codetracer-native-backend).
    nixpkgs.follows = "codetracer-toolchains/nixpkgs";
    nixpkgs-unstable.follows = "nixpkgs";

    appimage-channel.url = "github:NixOS/nixpkgs/nixos-24.11";

    flake-utils.url = "github:numtide/flake-utils";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    noir = {
      url = "github:metacraft-labs/noir?ref=codetracer-temp";
      inputs.nixpkgs.follows = "nixpkgs";
      flake = true;
    };

    wazero = {
      url = "github:metacraft-labs/codetracer-wasm-recorder?ref=wasm-tracing";
      inputs.nixpkgs.follows = "nixpkgs";
      flake = true;
    };

    nix-blockchain-development = {
      url = "github:metacraft-labs/nix-blockchain-development";
      inputs.nixpkgs.follows = "nixpkgs";
      flake = true;
    };

    # TODO: Remove this temporary Sui-only input after nix-blockchain-development
    # is updated and cached with the latest metacraft-labs/nixos-modules graph.
    # The intended composition is that all Metacraft repos share the same
    # nixos-modules input, and each repo gets nixpkgs / nixpkgs-unstable through
    # that nixos-modules flake rather than overriding nixpkgs independently.
    # Once nix-blockchain-development follows that pattern, Sui should come from
    # the regular nix-blockchain-development input.
    nix-blockchain-development-sui = {
      url = "github:metacraft-labs/nix-blockchain-development";
      inputs.nixos-modules.follows = "nix-blockchain-development/nixos-modules";
      flake = true;
    };

    codetracer-ruby-recorder = {
      url = "github:metacraft-labs/codetracer-ruby-recorder";
      inputs.nixpkgs.follows = "nixpkgs";
      flake = true;
    };

    codetracer-python-recorder = {
      url = "github:metacraft-labs/codetracer-python-recorder";
      inputs.nixpkgs.follows = "nixpkgs";
      flake = true;
    };

    codetracer-js-recorder = {
      url = "github:metacraft-labs/codetracer-js-recorder";
      inputs.nixpkgs.follows = "nixpkgs";
      flake = true;
    };

    codetracer-shell-recorders = {
      url = "github:metacraft-labs/codetracer-shell-recorders";
      inputs.nixpkgs.follows = "nixpkgs";
      flake = true;
    };

    # Non-flake input: the trace-format Rust workspace.  At runtime in the
    # workspace dev shell, `.envrc` overrides this with `--override-input
    # codetracer-trace-format path:../codetracer-trace-format` so changes
    # in the sibling checkout are picked up immediately.  In CI / fresh
    # nix builds without a sibling, the input fetches from GitHub.
    #
    # See codetracer-specs/Working-with-the-CodeTracer-Repos.md for the
    # sibling-detection mechanism.
    codetracer-trace-format = {
      url = "github:metacraft-labs/codetracer-trace-format/main";
      flake = false;
    };

    # Non-flake input: the metacraft-labs/langserver fork (a.k.a. nim-langserver),
    # branch `codetracer`.  Carries patches on top of upstream nim-lang/langserver
    # that the CodeTracer GUI depends on — currently `nim/traceExpandMacro`
    # (M11) and `nim/traceStaticBlock` (CTFS-M-StaticBlockTrace) LSP commands.
    # The overlay in `perSystem` substitutes nixpkgs' `nimlangserver` src with
    # this revision, so a stock `nix develop` ships our patched binary.
    #
    # `.envrc` can override with `--override-input nim-langserver path:../nim-langserver`
    # to consume a local sibling checkout during development.
    nim-langserver = {
      url = "github:metacraft-labs/langserver?ref=codetracer";
      flake = false;
    };

    # Pre-commit hooks
    git-hooks-nix.url = "github:cachix/git-hooks.nix";
  };

  # outputs = {
  #   nixpkgs,
  #   flake-utils,
  # }: let
  #   system = "x86_64-linux";
  #   pkgs = import nixpkgs {
  #     inherit system;
  #     overlays = [(import ./overlay.nix)];

  #     config = {
  #       permittedInsecurePackages = [
  #         "electron-13.6.9"
  #       ];
  #       # allowUnfree = true;
  #     };
  #   };
  #   # node2nixOutput = import ./src { inherit pkgs   system; };
  #   # nodeDeps = node2nixOutput.nodeDependencies;
  # in {
  #   # pkgs.overlays = [ (import ./overlay.nix) ];
  #   devShell."${system}" = import ./shell.nix {inherit pkgs;};
  # };

  outputs =
    inputs@{
      nixpkgs,
      nixpkgs-unstable,
      flake-parts,
      fenix,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      imports = [
        ./nix/shells
        ./nix/packages
        inputs.git-hooks-nix.flakeModule
      ];

      # NixOS module for CodeTracer with BPF process monitoring.
      # Usage in configuration.nix:
      #   imports = [ codetracer.nixosModules.default ];
      #   programs.codetracer.enable = true;
      #   users.users.myuser.extraGroups = [ "codetracer-bpf" ];
      flake.nixosModules.default = ./nix/packages/codetracer-appimage/nixos-module.nix;

      # NixOS module for developer builds: passwordless setcap on the ct binary.
      # Usage in your NixOS configuration (e.g. ~/dotfiles):
      #   imports = [ codetracer.nixosModules.developer-bpf ];
      #   programs.codetracer.developer-bpf = {
      #     enable = true;
      #     user = "myuser";
      #     repoPath = "/home/myuser/metacraft/codetracer";
      #   };
      flake.nixosModules.developer-bpf = ./nix/modules/developer-bpf.nix;

      perSystem =
        { system, config, ... }:
        {
          _module.args.pkgs = import nixpkgs {
            inherit system;
            config = {
              # tup is currently considered broken by Nix, but this is not true
              # TODO: this is already fixed in nixpkgs/unstable, so it may become
              #       unnecessary after a future `flake update`
              allowBroken = true;
              permittedInsecurePackages = [
                "electron-24.8.6"
              ];
            };
            overlays = [
              # Substitute nixpkgs' upstream `nimlangserver` source with our
              # metacraft-labs/langserver fork (branch `codetracer`), so the
              # binary in the dev shell carries the `nim/traceExpandMacro`
              # and `nim/traceStaticBlock` LSP commands the CodeTracer GUI
              # depends on.
              #
              # Nixpkgs' `nimlangserver` derivation computes
              # `meta = final.src.meta // { ... }` inside the
              # `buildNimPackage` fix-point — so a raw flake-input path
              # (which lacks a `.meta` attribute, unlike the
              # `fetchFromGitHub` output it replaces) breaks the inner
              # evaluation BEFORE `overrideAttrs` has a chance to fix up
              # the final meta.  We therefore decorate the source with an
              # empty `meta` via the `//` operator so the inner lookup
              # succeeds; the final meta is overridden a second time at the
              # outer derivation level (where `overrideAttrs` does run).
              (_final: prev: {
                nimlangserver = prev.nimlangserver.overrideAttrs (old: {
                  version = "${prev.nimlangserver.version}-metacraft-codetracer";
                  src = inputs.nim-langserver // {
                    meta = { };
                  };
                  meta = (old.meta or { }) // {
                    description = "Nim language server (metacraft-labs/langserver, branch codetracer)";
                    homepage = "https://github.com/metacraft-labs/langserver";
                  };
                });
              })
            ];
          };

          _module.args.unstablePkgs = import nixpkgs-unstable {
            inherit system;
            config = {
              permittedInsecurePackages = [
                "electron-24.8.6"
              ];
            };
          };

          # Pre-commit hooks configuration
          pre-commit.settings = import ./nix/pre-commit.nix {
            pkgs = import nixpkgs { inherit system; };
            rustPkgs = config.packages;
          };

          # Disable pre-commit checks during nix flake check because the Rust
          # hooks need git submodules which aren't available in the Nix sandbox.
          # The hooks still work in the dev shell and during actual git commits.
          pre-commit.check.enable = false;
        };
    };
}
