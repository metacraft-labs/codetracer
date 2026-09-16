{
  pkgs,
  rustPkgs ? null,
}:
let
  # Anything inside a committed `.ct` container directory: the payload
  # a recorder wrote, plus the source snapshot it copied alongside.
  recordedTraceArtifacts = "\\.ct/";
in
{
  # Exclude third-party and generated files from all hooks
  excludes = [
    "^src/public/third_party/"
    "^node-packages/"
    "^libs/" # Git submodules
    "^src/db-backend/Cargo\\.lock$"
    "\\.min\\.js$"
    "\\.min\\.css$"

    # A VENDORED COPY, and byte-identity IS the contract.
    #
    # tools/check-test-assertions.sh is a byte-for-byte copy of
    # codetracer-specs/tools/check-test-assertions.sh (37e193050 explains why
    # it is copied rather than referenced: ci/lint/bash.sh is deliberately the
    # lane that needs no siblings and no network). The copy is only safe
    # because ci/test/test-assertion-baseline.sh compares the two by sha256
    # whenever both repos are on disk, so it cannot drift silently -- and the
    # editable original, the one with a self-test, lives in the other repo.
    #
    # shfmt would reformat 77 lines of it on the first commit that touches its
    # mode, breaking that sha256 against an upstream nobody had changed and
    # turning the drift check into noise about whitespace. Formatting hooks
    # must not have opinions about a file this repository does not own.
    "^tools/check-test-assertions\\.sh$"

    # A CANONICAL BODY WITH SEVEN PASTED COPIES, and byte-identity IS the
    # contract -- the same reason as the entry above, arrived at from the
    # opposite direction: that file is owned elsewhere, this one is owned here
    # but duplicated into YAML.
    #
    # ci/runner/sweep-readonly-leftovers.sh keeps its body between
    # `# --- BEGIN INLINE BODY` / `# --- END INLINE BODY` markers, and that body
    # is pasted verbatim into SEVEN `run:` blocks in
    # .github/workflows/codetracer.yml (jobs: reprobuild-macos-smoke,
    # origin-dap-macos, origin-dap-macos-nightly, dmg-build, dmg-lib-check,
    # test-non-gui, test-ui-tests). It cannot simply be invoked instead: the
    # sweep runs BEFORE actions/checkout, when the file is not yet on the
    # runner's disk. ci/test/readonly-leftovers-sweep-test.sh is what stops the
    # seven copies drifting -- it de-indents each `run:` block and compares it
    # to the canonical body with exact string equality (`found[name] != body`),
    # so every byte of leading whitespace is contractual.
    #
    # WHY IT IS SAFE TODAY. This exclusion, and only this exclusion.
    #
    # An earlier note here said the file was safe because "shfmt reads
    # .editorconfig, whose `[*]` stanza says space/2, so shfmt currently
    # rewrites NOTHING here (`shfmt -l` does not list it)". That is wrong in a
    # way worth spelling out, because the mistake is easy to repeat: `shfmt -l`
    # DOES leave this file alone, but the hook does not run `shfmt -l`. It runs
    # `shfmt -w -l -ln auto -s`, and shfmt consults .editorconfig only when it
    # is given NO formatting flags -- `-ln` and `-s` each suppress it on their
    # own. So the hook formats at shfmt's built-in default of `-i 0`, i.e.
    # TABS, and `shfmt -l -ln auto -s` on this file lists it and wants to
    # rewrite 84 lines. Reproduce with shfmt 3.12.0, the pinned version:
    #
    #     shfmt -l ci/runner/sweep-readonly-leftovers.sh                 # quiet
    #     shfmt -l -ln auto -s ci/runner/sweep-readonly-leftovers.sh     # lists it
    #
    # The consequence is the opposite of what that note predicted. Adding
    # `[*.sh] indent_style = tab` to .editorconfig is NOT the edit that breaks
    # the seven copies -- it is a no-op for this hook, which never reads the
    # file. (It has since been added, for the separate reason documented
    # there.) The edit that breaks them is deleting the exclusion below.
    #
    # The repo-wide hazard runs the other way. Because .editorconfig is
    # suppressed, its `[*]` = space/2 has never applied to shell scripts, and
    # 305 of 366 tracked *.sh files are tab-indented in disagreement with it.
    # Anything that makes shfmt start reading .editorconfig -- dropping `-s`,
    # dropping `-ln auto`, or an upstream git-hooks.nix bump that rewrites this
    # entry -- would have reformatted 306 files in one commit. The `[*.sh]`
    # stanza in .editorconfig now pins the tab default explicitly, which takes
    # that from 306 files to none.
    #
    # Nor could that be "resolved" by tabbing both sides: YAML block scalars
    # cannot use tabs for indentation at all. Do not fix a future breakage here
    # by relaxing the equality in readonly-leftovers-sweep-test.sh -- that
    # equality is the only thing holding the seven copies together.
    "^ci/runner/sweep-readonly-leftovers\\.sh$"
  ];

  hooks = {
    # Rust hooks — these always operate on `src/db-backend/Cargo.toml`
    # regardless of which nested .pre-commit-config.yaml symlink prek
    # is processing.  Without the cd-to-repo-root prefix, prek invokes
    # the hooks from each nested directory's cwd (e.g. src/db-backend
    # itself), and `--manifest-path src/db-backend/Cargo.toml` then
    # resolves to a nonexistent `src/db-backend/src/db-backend/Cargo.toml`,
    # surfacing as "Failed to run hook ... No such file or directory".
    # Wrapping in bash + `git rev-parse --show-toplevel` makes cwd
    # canonical before cargo runs.  Cargo itself comes from the Nix
    # dev shell PATH (fenix-combined toolchain in nix/shells/main.nix).
    clippy = {
      enable = true;
      name = "clippy";
      entry = "bash -c 'cd \"$(git rev-parse --show-toplevel)\" && cargo clippy --manifest-path src/db-backend/Cargo.toml --all-targets -- -D warnings'";
      language = "system";
      files = "\\.rs$";
      pass_filenames = false;
    };
    cargo-check = {
      enable = true;
      name = "cargo-check";
      entry = "bash -c 'cd \"$(git rev-parse --show-toplevel)\" && cargo check --manifest-path src/db-backend/Cargo.toml --all-targets'";
      language = "system";
      files = "\\.rs$";
      pass_filenames = false;
    };
    rustfmt = {
      enable = true;
      name = "rustfmt";
      entry = "bash -c 'cd \"$(git rev-parse --show-toplevel)\" && cargo fmt --manifest-path src/db-backend/Cargo.toml -- --check'";
      language = "system";
      files = "\\.rs$";
      pass_filenames = false;
    };

    # Shell hooks.
    #
    # THESE TWO DISAGREE WITH EACH OTHER ON REAL FILES, AND ONLY ONE OF THEM
    # RUNS IN CI. shellcheck is enforced by ci/lint/bash.sh (`shellcheck
    # ci/**/*.sh` and the per-directory steps below it). shfmt is NOT invoked
    # anywhere in ci/ or .github/ -- pre-commit is its only enforcement, and
    # pre-commit only ever sees the files a commit touches. So an unformatted
    # script can sit on dev indefinitely: as of 37fe0a75, 34 of the 366 tracked
    # *.sh files are listed by `shfmt -l -ln auto -s`.
    #
    # That matters because of how the two tools interact. `-s` rewrites an
    # escaped double-quoted string into a single-quoted one:
    #
    #     echo "a \`b\` c"   ->   echo 'a `b` c'
    #
    # and if the string also contains a `$`, shellcheck then reports SC2016
    # ("expressions don't expand in single quotes"). shellcheck exits 1 on a
    # note, so CI fails. Of the 34 files above, 9 are clean under shellcheck
    # today and acquire SC2016 the moment shfmt formats them:
    #
    #     ci/test/backend-manager-check-phase-test.sh    ci/test/web-bundle-assets.sh
    #     ci/test/grep-q-pipefail-gate.sh                ci/verdict/workspace-lock-freshness-test.sh
    #     ci/test/shell-gate-coverage.sh                 scripts/build-desktop-component.sh
    #     ci/test/shell-gate-coverage-test.sh            scripts/require-runtime-assets.sh
    #     scripts/test-python-version-alignment.sh
    #
    # Each is a trap for whoever next edits one: pre-commit's `shfmt -w`
    # reformats the file they touched, and CI then fails on an SC2016 they did
    # not write, in a line they did not change. The fix is per-file and is
    # already the established pattern here -- accept shfmt's form and add an
    # explicit `# shellcheck disable=SC2016` with a sentence saying why, as
    # ci/test/nimsuggest-check.sh, ci/test/windows-install-root-test.sh,
    # ci/test/stale-artefact-guards-test.sh and ci/test/vm-js-lane-test.sh all
    # do. Do NOT resolve it by widening an exclusion or lowering shellcheck's
    # severity; the nine are listed here so the work can be done file by file,
    # in the change that touches each file anyway, rather than as one
    # unreviewable whitespace commit.
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
    #
    # Committed recordings are recorder *output*, not source, and must
    # stay byte-for-byte what the recorder wrote — that is the whole
    # basis on which a fixture recording can be trusted as evidence.
    # Whitespace hooks would silently edit them: `end-of-file-fixer`
    # appends a newline the writer did not emit, so a regenerated
    # recording never matches the committed one; and
    # `trim-trailing-whitespace` would corrupt any trace carrying a
    # recorded string value that ends in a space.
    trim-trailing-whitespace = {
      enable = true;
      excludes = [ recordedTraceArtifacts ];
    };
    end-of-file-fixer = {
      enable = true;
      excludes = [ recordedTraceArtifacts ];
    };
    check-yaml.enable = true;
    check-added-large-files = {
      enable = true;
      excludes = [ "^storybook/package-lock\\.json$" ];
    };

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
