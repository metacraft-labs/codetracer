{
  pkgs,
  inputs',
  self',
}: let
  ourPkgs = self'.packages;
in
  with pkgs;
    mkShell {
      packages = [
        # Rust toolchain
        cargo
        rustfmt
        clippy
        rust-analyzer

        # Database tools
        sqlite

        # Development tools
        just
        git

        # Basic utilities
        coreutils
        gnugrep
        gawk
        ripgrep

        # Build dependencies that Rust projects might need
        gcc
        binutils
        openssl
        pcre
        glib
        libelf

        # For inspecting and debugging
        pstree
        hexdump
        tree-sitter

        # Useful for development
        vim
        delta
      ];

      shellHook = ''
        echo "🦀 Rust backend development environment"
        echo "Working directory: db-backend/"
        echo ""
        echo "Available commands:"
        echo "  just --list    # Show available just recipes"
        echo "  cargo build    # Build the Rust project"
        echo "  cargo test     # Run tests"
        echo "  cargo clippy   # Run linter"
        echo ""

        # Set up minimal environment variables for Rust development
        export CT_LD_LIBRARY_PATH="${sqlite.out}/lib/:${pcre.out}/lib:${glib.out}/lib:${openssl.out}/lib:${gcc.cc.lib}/lib"
        export RUST_LOG=info
      '';
    }
