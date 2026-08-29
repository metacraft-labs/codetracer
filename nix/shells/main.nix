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
#     works locally for these languages). The ones that build on
#     Darwin (fpc, gfortran, ldc, crystal) are in the shared list;
#     the rest stay gated behind `!stdenv.isDarwin` with per-item
#     reasons below.
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
  base = import ./ci-base.nix {
    inherit
      pkgs
      inputs
      inputs'
      self'
      ;
  };
  ourPkgs = self'.packages;
  preCommit = config.pre-commit;
  toolchainsPkgs = inputs'."codetracer-toolchains".packages;
in
with pkgs;
mkShell {
  hardeningDisable = [ "all" ];

  packages =
    base.packages
    ++ [
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

      # Extra native-language compiler coverage. Not exercised by any
      # current CI lane — kept so `ct record` works locally for programs
      # written in these languages. These four build cleanly on
      # aarch64-darwin (verified 2026-06-22), so they live in the shared
      # list and ship in the macOS dev shell. The remaining toolchains
      # (gnat, gprbuild) and the blockchain runtimes stay gated below.
      toolchainsPkgs.fpc # Free Pascal compiler
      toolchainsPkgs.gfortran # GNU Fortran compiler
      toolchainsPkgs.ldc # LLVM-based D compiler
      toolchainsPkgs.crystal # Crystal compiler
    ]
    ++ pkgs.lib.optionals (!stdenv.isDarwin) [
      # BPF process monitoring (used by `just developer-setup` Phase 2).
      # Linux-kernel-only (eBPF): these tools target the Linux kernel BPF
      # subsystem and have no aarch64-darwin build. Revisit only if/when
      # CodeTracer grows a macOS process-monitoring backend (e.g.
      # EndpointSecurity) — there is no eBPF on Darwin to revisit toward.
      bpftrace
      libbpf
      bpftools

      # GNAT (Ada) + gprbuild stay Linux-only.
      # fails on aarch64-darwin: `error: Unsupported system:
      # aarch64-darwin` from the gnat-wrapper derivation — nixpkgs does
      # not provide a GNAT bootstrap for aarch64-darwin (gprbuild depends
      # on gnat and fails the same way). Verified against
      # codetracer-toolchains 942c995a (2026-06-22). Revisit when nixpkgs
      # ships an aarch64-darwin GNAT or codetracer-toolchains bumps to a
      # nixpkgs that does.
      toolchainsPkgs.gnat
      toolchainsPkgs.gprbuild

      # Blockchain recorder runtimes — not packaged for Darwin.
      # fails on aarch64-darwin: `error: attribute '<pkg>' missing` —
      # nix-blockchain-development's
      # `legacyPackages.aarch64-darwin.metacraft-labs` set does not define
      # forc / miden / cargo-build-sbf / sui (only the x86_64/aarch64-linux
      # sets do). Verified against nix-blockchain-development a702258d
      # (2026-06-22). Revisit when nix-blockchain-development packages
      # these for aarch64-darwin.
      ourPkgs.forc # Sway/Fuel compiler (codetracer-fuel-recorder)
      ourPkgs.miden # Miden compiler (codetracer-miden-recorder)
      ourPkgs.cargo-build-sbf # Solana BPF compiler (codetracer-solana-recorder)
      ourPkgs.sui # Sui compiler (codetracer-move-recorder)

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

    # Flake-input fallback for the codetracer-trace-format-nim source.
    #
    # detect-siblings.sh only exports CODETRACER_TRACE_FORMAT_NIM_SRC when an
    # adjacent `codetracer-trace-format-nim/src` sibling checkout exists. CI
    # lanes that enter this devShell without cloning that sibling (e.g.
    # appimage-build, which uses setup-isonim-siblings and does NOT clone it)
    # then have no way to resolve `import codetracer_trace_writer/span_stream`
    # (config.nims:67), so the nim compile of src/ct/cli/print_trace.nim fails
    # with `cannot open file: codetracer_trace_writer/span_stream`.
    #
    # Mirror the proven-good nix-sandbox package path (nix/packages/default.nix
    # exports CODETRACER_TRACE_FORMAT_NIM_SRC from the flake input) so the
    # devShell always resolves the module even without a sibling checkout.
    # This is additive: a real adjacent sibling still wins because
    # detect-siblings.sh sets the var first; only lanes without the sibling
    # reach this fallback.
    if [ -z "''${CODETRACER_TRACE_FORMAT_NIM_SRC:-}" ]; then
      export CODETRACER_TRACE_FORMAT_NIM_SRC="${inputs.codetracer-trace-format-nim}/src"
    fi

    # Take the direnv-free path in src/db-backend/build.rs.
    #
    # build.rs invokes the native-recorder C-regen script; by default it wraps
    # that in `direnv exec <recorder>` to load the recorder's Nim toolchain
    # onto PATH. On CI runners the recorder's `.envrc` is not `direnv allow`ed,
    # so that wrapper fails and build.rs panics
    # (`build_native_api.sh exited with status 1`). This devShell always puts
    # nim/nimble on PATH, which is exactly the precondition build.rs documents
    # for the direct-`bash` escape hatch (build.rs:945-948), so opt into it for
    # every devShell consumer (dev-build, appimage-build, local dev).
    export CODETRACER_DB_BACKEND_SKIP_DIRENV=1

    RECORDER_SRC="''${CODETRACER_PYTHON_RECORDER_SRC:-}"

    # ---------------------------------------------------------------------
    # Python recorder venv (used by `ct record` for Python tracing in local
    # dev). CI lanes that need Python recording set up their own venv as a
    # separate step.
    #
    # THE INTERPRETER IS NOT RESOLVED FROM PATH. It is $CODETRACER_PYTHON_CMD,
    # exported by ci-base.nix from the single pin in nix/python.nix. This line
    # used to read `python3 -m venv`, and that bare name is where the split
    # entered: `python3Packages.flake8` put nixpkgs' default interpreter
    # (3.13) on the PATH ahead of the pinned 3.12, so the venv came out 3.13
    # while `scripts/build-siblings.sh` built the recorder's extension as
    # `codetracer_python_recorder.cpython-312-*.so`. A CPython extension is
    # ABI-locked to its minor version, so the result was
    #
    #   error: Python module `codetracer_python_recorder` is not installed
    #          for interpreter: …/.python-recorder-venv/bin/python
    #
    # from `ct record`, and a red `record-python-happy-path` E2E edge.
    # ---------------------------------------------------------------------
    RECORDER_VENV="$ROOT_PATH/.python-recorder-venv"
    PURE_RECORDER_SRC="''${CODETRACER_PYTHON_PURE_RECORDER_SRC:-}"

    # A venv is only usable if it was built from the pinned interpreter. An
    # existing venv at the wrong minor version is not "already set up" — it is
    # precisely the failure this block exists to prevent — so it is rebuilt
    # rather than reused. That is what makes the fix self-healing on a tree
    # that already carries a stale 3.13 venv.
    _ct_venv_python_version() {
      [ -x "$RECORDER_VENV/bin/python" ] || return 1
      "$RECORDER_VENV/bin/python" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null
    }
    _ct_venv_matches_pin() {
      [ "$(_ct_venv_python_version)" = "''${CODETRACER_PYTHON_VERSION:-}" ]
    }

    # Failure reporting. This is deliberately NOT `exit 1`.
    #
    # This shell is entered for hundreds of tasks that never touch Python —
    # every Nim build, every Rust test, every frontend run — and it is entered
    # non-interactively by `nix develop --command`, where a hook that exits
    # takes the whole command with it. Making a Python-recorder problem fatal
    # would convert "Python tracing is unavailable" into "nothing in this repo
    # builds", which is a worse failure than the one being fixed.
    #
    # What the old code did wrong was not that it continued; it is that it
    # continued *quietly and then lied*: it printed one grey WARNING line into
    # a wall of shell-hook output and then exported
    # CODETRACER_PYTHON_INTERPRETER anyway, pointing `ct` at a venv that could
    # not serve it. So instead of exiting we do three things that a warning
    # alone does not:
    #
    #   1. print an unmissable framed banner on STDERR (stdout is parsed by
    #      callers of `nix develop --command`),
    #   2. leave CODETRACER_PYTHON_INTERPRETER UNSET and the broken venv off
    #      PATH, so `ct record x.py` falls back to the pinned interpreter that
    #      does carry a matching recorder, and any remaining failure names a
    #      real interpreter instead of a poisoned one,
    #   3. record the reason in $RECORDER_VENV/.broken, which
    #      `scripts/test-python-version-alignment.sh` reads and FAILS on — so
    #      the condition is caught by a test rather than by a human noticing
    #      a line of scrollback.
    _ct_python_recorder_broken() {
      mkdir -p "$RECORDER_VENV" 2>/dev/null || true
      printf '%s\n' "$1" > "$RECORDER_VENV/.broken" 2>/dev/null || true
      {
        echo ""
        echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "  !!  PYTHON RECORDER UNAVAILABLE IN THIS SHELL                   !!"
        echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "  !!  $1"
        echo "  !!"
        echo "  !!  \`ct record <file>.py\` will not use the sibling checkout."
        echo "  !!  CODETRACER_PYTHON_INTERPRETER has been left UNSET rather than"
        echo "  !!  pointed at a venv that cannot serve it."
        echo "  !!"
        echo "  !!  Diagnose with:  just test-python-version-alignment"
        echo "  !!  Retry with:     rm -rf $RECORDER_VENV && exit  # then re-enter"
        echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo ""
      } >&2
    }

    if [ -n "$PURE_RECORDER_SRC" ] && [ -d "$PURE_RECORDER_SRC" ]; then
      if ! _ct_venv_matches_pin \
        || ! "$RECORDER_VENV/bin/python" -c "import codetracer_pure_python_recorder" 2>/dev/null; then
        if [ -d "$RECORDER_VENV" ] && ! _ct_venv_matches_pin; then
          echo "Rebuilding Python recorder venv: it is Python $(_ct_venv_python_version), the pin is $CODETRACER_PYTHON_VERSION."
          rm -rf "$RECORDER_VENV"
        fi
        echo "Setting up Python recorder venv (first time or module needs rebuild)..."
        rm -f "$RECORDER_VENV/.broken" 2>/dev/null || true
        # --system-site-packages exposes the flake-built, ABI-matched
        # `codetracer_python_recorder` from $CODETRACER_PYTHON_CMD's own
        # environment, which is the module `src/ct/trace/record.nim` requires
        # of CODETRACER_PYTHON_INTERPRETER. Without it this venv carried only
        # the pure recorder and `ct record` refused to run.
        "$CODETRACER_PYTHON_CMD" -m venv --system-site-packages "$RECORDER_VENV"
        "$RECORDER_VENV/bin/pip" install --quiet "$PURE_RECORDER_SRC" 2>&1 | tail -5
      fi
      if "$RECORDER_VENV/bin/python" -c "import codetracer_pure_python_recorder" 2>/dev/null; then
        rm -f "$RECORDER_VENV/.broken" 2>/dev/null || true
        export CODETRACER_PYTHON_INTERPRETER="$RECORDER_VENV/bin/python"
        export PATH="$RECORDER_VENV/bin:$PATH"
      else
        _ct_python_recorder_broken "codetracer_pure_python_recorder failed to install into $RECORDER_VENV"
      fi
    elif [ -n "$RECORDER_SRC" ] && [ -d "$RECORDER_SRC" ]; then
      if command -v maturin &>/dev/null; then
        if ! _ct_venv_matches_pin \
          || ! "$RECORDER_VENV/bin/python" -c "import codetracer_python_recorder" 2>/dev/null; then
          if [ -d "$RECORDER_VENV" ] && ! _ct_venv_matches_pin; then
            echo "Rebuilding Python recorder venv: it is Python $(_ct_venv_python_version), the pin is $CODETRACER_PYTHON_VERSION."
            rm -rf "$RECORDER_VENV"
          fi
          echo "Setting up Python recorder venv (Rust-backed, first time or module needs rebuild)..."
          rm -f "$RECORDER_VENV/.broken" 2>/dev/null || true
          "$CODETRACER_PYTHON_CMD" -m venv --system-site-packages "$RECORDER_VENV"
          "$RECORDER_VENV/bin/pip" install --quiet "$RECORDER_SRC" 2>&1 | tail -5
        fi
        if "$RECORDER_VENV/bin/python" -c "import codetracer_python_recorder" 2>/dev/null; then
          rm -f "$RECORDER_VENV/.broken" 2>/dev/null || true
          export CODETRACER_PYTHON_INTERPRETER="$RECORDER_VENV/bin/python"
          export PATH="$RECORDER_VENV/bin:$PATH"
        else
          _ct_python_recorder_broken "codetracer_python_recorder failed to install into $RECORDER_VENV"
        fi
      else
        _ct_python_recorder_broken "maturin is not on PATH, so the Rust-backed recorder cannot be built from $RECORDER_SRC (and no pure-Python recorder source was found)."
      fi
    fi

    if [ "''${METACRAFT_WORKSPACE_PRESENT:-}" = "1" ]; then
      echo "  workspace: detected (shared scripts at $METACRAFT_WORKSPACE_SCRIPTS)"
    fi
  '';
}
