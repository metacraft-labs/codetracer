# Default (developer) dev shell.
#
# Composed as `ci-base + developer-only extras`. The CI base is
# everything a CI step actually needs to build / test codetracer's
# components — kept in ./ci-base.nix so `devShells.ci` and
# `devShells.default` consume the same source of truth. The extras
# below are tools that improve a developer's interactive session but
# add nothing for an automated CI step:
#   - codex-acp + agent-toolchain (AI assistant integration)
#   - reprobuild + runquota (Reprobuild MVP — pre-commit-style hooks
#     that aren't run in CI)
#   - LSP / editor integrations (nim-langserver, rust-analyzer, …)
#   - Multi-language compilers we don't yet exercise in any CI lane
#     (lean4, fpc, gfortran, ldc, crystal, gnat, gprbuild, miden,
#     forc, sui, cargo-build-sbf — keep them here so `ct record`
#     works locally for these languages)
#   - AppImage build (appimagekit, create-dmg)
#   - tmux / vim / pstree / viddy / hexdump / delta — pure
#     interactive-session conveniences
#   - pre-commit hooks installer + Python-recorder venv setup
#     + workspace + sibling-repo detection (shellHook tail)
{
  pkgs,
  inputs,
  inputs',
  self',
  config,
}:
let
  base = import ./ci-base.nix { inherit pkgs inputs inputs' self'; };
  ourPkgs = self'.packages;
  preCommit = config.pre-commit;
  toolchainsPkgs = inputs'."codetracer-toolchains".packages;
in
with pkgs;
mkShell {
  hardeningDisable = [ "all" ];

  packages = base.packages ++ [
    # Developer convenience CLI tools.
    delta
    universal-ctags
    pstree
    viddy
    hexdump
    tmux
    vim
    unixtools.script
    dash
    lesspipe

    # Inspect built .deb packages locally during release work.
    dpkg

    # Docs build (mdbook). Not run by any CI lane today.
    mdbook

    # AI agent client — Codex's Agent Client Protocol bridge. Used
    # by nim-acp / nim-agent-harbor integrations during local
    # development. Never invoked by any CI lane; building it pulls a
    # ~25-GB Rust workspace, so it intentionally stays out of CI.
    ourPkgs.codex-acp

    # LSP / editor integrations.
    nimlsp
    nimlangserver
    rust-analyzer

    # Ruby experimental support — only `ct record`able locally.
    libyaml
    ruby
    ruby-lsp

    # Lean 4 — theorem prover + functional lang. No CI lane traces
    # Lean programs yet.
    lean4

    # tree-sitter CLI for the local parser regen step in shellHook.
    tree-sitter
  ]
  ++ pkgs.lib.optionals (!stdenv.isDarwin) [
    # BPF process monitoring (used by `just developer-setup` Phase 2).
    bpftrace
    libbpf
    bpftools

    # Extra native-language compiler coverage that is currently
    # Linux-only or marked broken in the macOS shells. Not exercised
    # by any current CI lane — kept here for `ct record` of programs
    # written in these languages.
    toolchainsPkgs.fpc
    toolchainsPkgs.gfortran
    toolchainsPkgs.ldc
    toolchainsPkgs.crystal
    toolchainsPkgs.gnat
    toolchainsPkgs.gprbuild

    # Blockchain recorder runtimes not packaged for Darwin and not
    # exercised by current CI lanes.
    ourPkgs.forc           # Sway/Fuel compiler (codetracer-fuel-recorder)
    ourPkgs.miden          # Miden compiler (codetracer-miden-recorder)
    ourPkgs.cargo-build-sbf # Solana BPF compiler (codetracer-solana-recorder)
    ourPkgs.sui            # Sui compiler (codetracer-move-recorder)

    # AppImage build (local release artifacts).
    inputs'.appimage-channel.legacyPackages.appimagekit
    appimage-run
    pax-utils
  ]
  ++ pkgs.lib.optionals stdenv.isDarwin [
    # macOS DMG build (local release artefacts).
    create-dmg
  ]
  # Pre-commit hooks (dev-only — CI runs `pre-commit run` explicitly
  # against the staged diff, it doesn't need the hook scripts staged
  # into .git/hooks).
  ++ [ preCommit.settings.package ]
  ++ preCommit.settings.enabledPackages;

  # Compose: build-critical exports from ci-base, then dev-only tail.
  shellHook = base.shellHook + ''
    # Install pre-commit hooks automatically.
    ${preCommit.installationScript}
    ln -sf ${preCommit.settings.configFile} .pre-commit-config.yaml

    export RUST_LOG=info

    # Tree-sitter-nim parser regen (local checkout — CI clones with
    # submodules: false and skips this).
    ROOT_PATH=$(git rev-parse --show-toplevel)
    if [ -d "$ROOT_PATH/libs/tree-sitter-nim" ]; then
      (cd "$ROOT_PATH/libs/tree-sitter-nim" && just generate)
    fi

    # Workspace + sibling-repo detection — used by interactive dev
    # to wire up overlays between the host checkout and adjacent
    # sibling clones. CI doesn't need this (each repo is cloned
    # separately into a known path).
    WORKSPACE_ROOT="$(cd "$ROOT_PATH/.." 2>/dev/null && pwd)"
    METACRAFT_SCRIPTS=""
    if [ -n "$WORKSPACE_ROOT" ] && [ -d "$WORKSPACE_ROOT/scripts" ]; then
      METACRAFT_SCRIPTS="$WORKSPACE_ROOT/scripts"
    fi
    if [ -z "$METACRAFT_SCRIPTS" ] && [ -n "$WORKSPACE_ROOT" ]; then
      METACRAFT_PARENT="$(cd "$WORKSPACE_ROOT/.." 2>/dev/null && pwd)"
      if [ -n "$METACRAFT_PARENT" ] && [ -d "$METACRAFT_PARENT/scripts" ]; then
        METACRAFT_SCRIPTS="$METACRAFT_PARENT/scripts"
      fi
    fi
    if [ -n "$METACRAFT_SCRIPTS" ]; then
      export METACRAFT_WORKSPACE_PRESENT=1
      export METACRAFT_WORKSPACE_SCRIPTS="$METACRAFT_SCRIPTS"
      export PATH="$METACRAFT_SCRIPTS:$PATH"
    fi

    source "$ROOT_PATH/scripts/detect-siblings.sh" "$ROOT_PATH"
    RECORDER_SRC="''${CODETRACER_PYTHON_RECORDER_SRC:-}"

    # Python recorder venv (used by `ct record` for Python tracing
    # in local dev). CI lanes that need Python recording will set up
    # their own venv as a separate step.
    RECORDER_VENV="$ROOT_PATH/.python-recorder-venv"
    PURE_RECORDER_SRC="''${CODETRACER_PYTHON_PURE_RECORDER_SRC:-}"
    if [ -n "$PURE_RECORDER_SRC" ] && [ -d "$PURE_RECORDER_SRC" ]; then
      if [ ! -d "$RECORDER_VENV" ] || ! "$RECORDER_VENV/bin/python" -c "import codetracer_pure_python_recorder" 2>/dev/null; then
        echo "Setting up Python recorder venv (first time or module needs rebuild)..."
        python3 -m venv "$RECORDER_VENV"
        "$RECORDER_VENV/bin/pip" install --quiet "$PURE_RECORDER_SRC" 2>&1 | tail -5
        if "$RECORDER_VENV/bin/python" -c "import codetracer_pure_python_recorder" 2>/dev/null; then
          echo "Python recorder installed successfully."
        else
          echo "WARNING: Failed to install codetracer_pure_python_recorder. Python tracing may not work."
        fi
      fi
      export CODETRACER_PYTHON_INTERPRETER="$RECORDER_VENV/bin/python"
      export PATH="$RECORDER_VENV/bin:$PATH"
    elif [ -n "$RECORDER_SRC" ] && [ -d "$RECORDER_SRC" ]; then
      if command -v maturin &>/dev/null; then
        if [ ! -d "$RECORDER_VENV" ] || ! "$RECORDER_VENV/bin/python" -c "import codetracer_python_recorder" 2>/dev/null; then
          echo "Setting up Python recorder venv (Rust-backed, first time or module needs rebuild)..."
          python3 -m venv "$RECORDER_VENV"
          "$RECORDER_VENV/bin/pip" install --quiet "$RECORDER_SRC" 2>&1 | tail -5
          if "$RECORDER_VENV/bin/python" -c "import codetracer_python_recorder" 2>/dev/null; then
            echo "Python recorder installed successfully."
          else
            echo "WARNING: Failed to install codetracer_python_recorder. Python tracing may not work."
          fi
        fi
        export CODETRACER_PYTHON_INTERPRETER="$RECORDER_VENV/bin/python"
        export PATH="$RECORDER_VENV/bin:$PATH"
      else
        echo "WARNING: maturin not available; skipping Rust-backed Python recorder install."
        echo "  The pure-Python recorder was not found either. Python tracing may not work."
      fi
    fi

    if [ "''${METACRAFT_WORKSPACE_PRESENT:-}" = "1" ]; then
      echo "  workspace: detected (shared scripts at $METACRAFT_WORKSPACE_SCRIPTS)"
    fi
  '';
}
