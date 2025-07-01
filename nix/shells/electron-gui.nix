{
  pkgs,
  inputs',
  self',
}: let
  ourPkgs = self'.packages;
in
  with pkgs;
    mkShell {
      packages =
        [
          # Node.js ecosystem
          nodejs-18_x
          corepack
          yarn
          nodePackages.webpack-cli

          # Electron
          electron_33

          # Build systems
          tup

          # Development tools
          just
          git

          # Basic utilities
          coreutils
          gnugrep
          gawk
          ripgrep

          # Build tools that may be needed for native node modules
          gcc
          binutils
          python3

          # For UI development and debugging
          vim
          delta
          tree-sitter

          # TODO: use eventually if more stable, instead of
          # a lot of the shellHook logic
          # ourPkgs.staticDeps
          ourPkgs.upstream-nim-codetracer

          # useful for lsp/editor support
          nimlsp
          nimlangserver

          # Our custom node modules
          ourPkgs.node-modules-derivation
        ]
        ++ pkgs.lib.optionals (!stdenv.isDarwin) [
          # Linux-specific GUI dependencies
          xorg.xhost # For X11 forwarding if needed
        ];

      shellHook = ''
        echo "⚡ Electron GUI development environment"
        echo "Working directory: gui/"
        echo ""
        echo "Available commands:"
        echo "  just --list           # Show available just recipes"
        echo "  yarn install          # Install dependencies"
        echo "  yarn start            # Start development server"
        echo "  yarn build            # Build for production"
        echo "  electron .            # Run electron app"
        echo "  just build            # Build frontend files (without Rust components)"
        echo ""

        # Set up Node.js environment
        export NIX_NODE_PATH="${ourPkgs.node-modules-derivation}/bin/node_modules"
        export NODE_PATH="$NODE_PATH:$NIX_NODE_PATH"

        # Get root path for symlinking node_modules
        ROOT_PATH=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

        # Symlink node_modules for development (like in main shell)
        if [ -n "$ROOT_PATH" ]; then
          rm -rf $ROOT_PATH/node_modules
          ln -s $NIX_NODE_PATH $ROOT_PATH/node_modules
          export PATH=$PATH:$ROOT_PATH/node_modules/.bin/
        fi

        # Electron development settings
        export CODETRACER_OPEN_DEV_TOOLS=1
        export CODETRACER_LOG_LEVEL=INFO

        # Update WITHOUT_DB_BACKEND in tup.config
        "$ROOT_PATH/scripts/update-tup-config" src/build-debug/tup.config WITHOUT_DB_BACKEND 1
      '';
    }
