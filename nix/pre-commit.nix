{
  pkgs,
  rustPkgs ? null,
}:
{
  # Exclude third-party and generated files from all hooks
  excludes = [
    "^src/public/third_party/"
    "^node-packages/"
    "^libs/" # Git submodules
    "^src/db-backend/Cargo\\.lock$"
    "\\.min\\.js$"
    "\\.min\\.css$"
  ];

  hooks = {
    # Rust hooks (run from src/db-backend directory)
    # Use cargo from PATH (set up by nix shell with rustup override)
    clippy = {
      enable = true;
      name = "clippy";
      entry = "cargo clippy --manifest-path src/db-backend/Cargo.toml --all-targets -- -D warnings";
      language = "system";
      files = "\\.rs$";
      pass_filenames = false;
    };
    cargo-check = {
      enable = true;
      name = "cargo-check";
      entry = "cargo check --manifest-path src/db-backend/Cargo.toml --all-targets";
      language = "system";
      files = "\\.rs$";
      pass_filenames = false;
    };
    rustfmt = {
      enable = true;
      name = "rustfmt";
      entry = "cargo fmt --manifest-path src/db-backend/Cargo.toml -- --check";
      language = "system";
      files = "\\.rs$";
      pass_filenames = false;
    };

    # Shell hooks
    shellcheck.enable = true;
    shfmt.enable = true;

    # Nix formatter
    nixfmt-rfc-style.enable = true;

    # TOML formatter
    taplo.enable = true;

    # Spell checker for markdown
    cspell = {
      enable = true;
      name = "cspell (cached)";
      entry = "cspell --no-progress --cache --no-must-find-files --config .cspell.json";
      language = "system";
      pass_filenames = true;
      files = "\\.(md)$";
      extraPackages = [ pkgs.nodePackages.cspell ];
    };

    # Markdown linter
    markdownlint-fix = {
      enable = true;
      name = "markdownlint-cli2 (fix)";
      entry = "markdownlint-cli2 --fix";
      language = "system";
      pass_filenames = true;
      files = "\\.md$";
      excludes = [
        "AGENTS\\.md$" # Agent instruction files
        "^tasks\\.md$"
        "^docs/" # Many legacy docs with formatting issues
        "^src/db-backend/" # db-backend internal docs
        "^examples/" # Example project READMEs with varied formatting
        "^test-programs/" # Test program READMEs
        "^tsc-ui-tests/" # TypeScript UI tests
        "^build-python/" # Python build docs
        "^src/tracer/" # Tracer docs
        "^CHANGELOG\\.md$" # Auto-generated changelog
        "^CONTRIBUTING\\.md$"
        "^SUPPORT\\.md$"
        "^SECURITY\\.md$"
        "^README\\.md$" # Main README with complex formatting
        "^CODE_OF_CONDUCT\\.md$"
        "^release_checklist\\.md$"
        "^PLAN_OPEN_DIR\\.md$" # Large planning document
        "^ct-dap\\.md$" # DAP protocol doc
        "^0\\d{3}-.*\\.md$" # RFC-style docs (e.g. 0007-ct-host-...)
        "-implementation-plan\\.md$" # Implementation plan docs
        "-status\\.md$" # Status docs
      ];
      extraPackages = [ pkgs.markdownlint-cli2 ];
    };

    # General hooks
    trim-trailing-whitespace.enable = true;
    end-of-file-fixer.enable = true;
    check-yaml.enable = true;
    check-added-large-files.enable = true;

    check-merge-conflict = {
      enable = true;
      name = "check merge conflict markers";
      # Match exact conflict markers (7 chars), not RST-style headings like ==================
      entry = ''
        bash -c 'set -e; rc=0; for f in "$@"; do [ -f "$f" ] || continue; if grep -En "^(<{7}|={7}|>{7})( |$)" "$f" >/dev/null 2>&1; then echo "Merge conflict markers in $f"; rc=1; fi; done; exit $rc' --
      '';
      language = "system";
      pass_filenames = true;
      types = [ "text" ];
    };

    # Custom hook: Ensure submodule URLs use HTTPS (required for Nix access-tokens)
    check-submodule-https-urls = {
      enable = true;
      name = "check submodule URLs are HTTPS";
      entry = ''
        bash -c '
          set -e
          GITMODULES=".gitmodules"
          if [ ! -f "$GITMODULES" ]; then
            exit 0
          fi
          non_https_urls=$(grep -E "^\s*url\s*=" "$GITMODULES" | grep -vE "(https://|\.\.\/)" || true)
          if [ -n "$non_https_urls" ]; then
            echo "ERROR: Non-HTTPS submodule URLs detected in .gitmodules"
            echo ""
            echo "The following URLs must be changed to HTTPS:"
            echo "$non_https_urls"
            echo ""
            echo "SSH URLs (git@github.com:) do not work with Nix access-tokens authentication."
            echo "Please use HTTPS URLs instead (https://github.com/...)."
            exit 1
          fi
          exit 0
        '
      '';
      language = "system";
      files = "^\\.gitmodules$";
      pass_filenames = false;
    };
  };
}
