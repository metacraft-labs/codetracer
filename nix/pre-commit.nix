{ pkgs }:
{
  hooks = {
    # Nix formatter
    nixfmt-rfc-style.enable = true;

    # Shell script checks
    shellcheck.enable = true;

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
