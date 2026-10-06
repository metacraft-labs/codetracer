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
      # The developer-only recorder environment constructor below requires
      # maturin for the declared Rust-backed source branch.
      maturin

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

      # (The tree-sitter CLI moved to ci-base.nix's package list alongside the
      # parser regen it serves. Leaving it here would have kept it out of
      # `devShells.ci`, where the regen now runs.)

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
    # Every path below is anchored to ROOT_PATH, which ci-base's hook (composed
    # above) sets to the top level of the CodeTracer checkout the shell was
    # entered from, and to "" when the current directory is not inside one. A
    # dev shell can be entered from any subdirectory, and a relative path then
    # resolves against THAT directory rather than the checkout. For
    # `.pre-commit-config.yaml` the failure is indirect and hard to read: a
    # nested copy makes prek run the Rust hooks with the nested directory as
    # cwd, so `--manifest-path src/db-backend/Cargo.toml` resolves to
    # `src/db-backend/src/db-backend/Cargo.toml` and surfaces as "No such file
    # or directory" on a path that reads as correct. The hooks in
    # nix/pre-commit.nix each `cd` to the toplevel to survive that.
    #
    # With ROOT_PATH empty the repository setup below (hook installation, the
    # config link, sibling detection, the Python recorder venv) is skipped:
    # entered from another repository the shell writes nothing there.
    # ci/test/dev-shell-writes-nothing-elsewhere-test.sh

    # Install pre-commit hooks automatically -- but NOT from a linked worktree
    # that would be reinstalling on another checkout's behalf.
    #
    # git-hooks.nix's installationScript writes `core.hooksPath` with `git config
    # --local`, which IS NOT PER-WORKTREE here, and it first `pre-commit
    # uninstall`s nine hook types and blanks that key before reinstalling. Run
    # from a worktree it therefore tears down and rebuilds the hooks every OTHER
    # worktree is relying on, mid-flight. The decision and its full rationale
    # live in the script below so they can be tested directly; it prints its
    # reason on stderr either way, and never writes to the repository.
    if [ -n "$ROOT_PATH" ] && bash "$ROOT_PATH/ci/dev/should-install-git-hooks.sh"; then
      ${preCommit.installationScript}
    fi

    # The installer above ends by writing the RELATIVE `core.hooksPath=.git/hooks`
    # into the config every worktree shares; in a linked worktree that path names
    # nothing, so git silently runs no hooks there. `anchor` repairs that value
    # and runs on every entry, from any checkout, so a value an earlier entry
    # left behind is healed too. `check` then reports, loudly, any relative
    # value `anchor` could not attribute; it does not stop the shell opening.
    if [ -n "$ROOT_PATH" ]; then
      bash "$ROOT_PATH/ci/dev/git-hooks-path.sh" anchor || true
      bash "$ROOT_PATH/ci/dev/git-hooks-path.sh" check || true
    fi

    # The config symlink is per-worktree and mutates nothing shared, so it is
    # created unconditionally -- including on the skip path above, where the
    # installer never runs. Without it the shared hooks fire in a worktree that
    # has no `.pre-commit-config.yaml` and abort with "No .pre-commit-config.yaml
    # file was found", which is exactly what a worktree entering this shell used
    # to get.
    if [ -n "$ROOT_PATH" ]; then
      ln -sf ${preCommit.settings.configFile} "$ROOT_PATH/.pre-commit-config.yaml"
    fi

    export RUST_LOG=info

    # (The tree-sitter-nim parser regen used to sit here, guarded by "local
    # checkout — CI clones with submodules: false and skips this". That
    # premise was false: `launcher-recorder-e2e.yml` checks this repo out WITH
    # submodules and builds it in `devShells.ci`, which composes ci-base's
    # shellHook and never ran this dev-only tail -- so every arm of that gate
    # died on the missing `src/parser.c`. It now lives in ci-base.nix's
    # shellHook, which BOTH shells compose, and calls the shared
    # `non-nix-build/ensure_tree_sitter_nim_parser.sh` rather than
    # `just generate`.)

    # Workspace + sibling-repo detection — used by interactive dev
    # to wire up overlays between the host checkout and adjacent
    # sibling clones. CI doesn't need this (each repo is cloned
    # separately into a known path).
    WORKSPACE_ROOT=""
    if [ -n "$ROOT_PATH" ]; then
      WORKSPACE_ROOT="$(cd "$ROOT_PATH/.." 2>/dev/null && pwd)"
    fi
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

    if [ -n "$ROOT_PATH" ]; then
      source "$ROOT_PATH/scripts/detect-siblings.sh" "$ROOT_PATH"
    fi

    # Flake-input fallback for the codetracer-trace-format-nim source.
    #
    # detect-siblings.sh only exports CODETRACER_TRACE_FORMAT_NIM_SRC when an
    # adjacent `codetracer-trace-format-nim/src` sibling checkout exists. CI
    # lanes that enter this devShell without cloning that sibling (e.g.
    # appimage-build, which uses provision-repro-lock-siblings and does NOT
    # clone it)
    # then have no way to resolve `import codetracer_trace_writer/span_stream`
    # (config.nims:67), so the nim compile of src/ct/cli/print_trace.nim fails
    # with `cannot open file: codetracer_trace_writer/span_stream`.
    #
    # Mirror the proven-good nix-sandbox package path (nix/packages/default.nix
    # exports these SRC vars from the flake inputs) so the devShell always
    # resolves the modules even without sibling checkouts. This is additive: a
    # real adjacent sibling still wins because detect-siblings.sh /
    # config.nims's workspaceRoot lookups take precedence; only lanes without
    # the siblings reach these fallbacks.
    #
    # The set here matches nix/packages/default.nix:1300-1303 (minus RUNQUOTA_SRC,
    # already exported by ci-base.nix, and CODETRACER_RESULTS_SRC, resolved from
    # the libs/nim-stew submodule by config.nims:29). Beyond print_trace.nim's
    # `codetracer_trace_writer/span_stream`, the `-d:ctTest` build compiles
    # src/ct_test/incremental, which imports `io_mon/depfile` (needs io-mon) and
    # the stackable-hooks propagation helpers.
    if [ -z "''${CODETRACER_TRACE_FORMAT_NIM_SRC:-}" ]; then
      export CODETRACER_TRACE_FORMAT_NIM_SRC="${inputs.codetracer-trace-format-nim}/src"
    fi
    if [ -z "''${IO_MON_SRC:-}" ]; then
      export IO_MON_SRC="${inputs.io-mon}/src"
    fi
    if [ -z "''${NIM_STACKABLE_HOOKS_SRC:-}" ]; then
      export NIM_STACKABLE_HOOKS_SRC="${inputs.nim-stackable-hooks}/src"
    fi

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

    # Compare the complete declared interpreter/module principal. A stale
    # managed environment is retained in an owned quarantine, never deleted.
    _ct_python_recorder_broken() {
      unset CODETRACER_PYTHON_INTERPRETER
      {
        echo ""
        echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "  !!  PYTHON RECORDER UNAVAILABLE IN THIS SHELL                   !!"
        echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "  !!  $1"
        echo "  !!  CODETRACER_PYTHON_INTERPRETER has been left UNSET."
        echo "  !!  Diagnose with: just test-python-version-alignment"
        echo "  !!  Retained attempt receipts: $ROOT_PATH/.repro/python-recorder-venv-*"
        echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
      } >&2
    }

    unset CODETRACER_PYTHON_INTERPRETER
    # A previous shell may have left this managed environment on PATH.
    # Remove every exact entry before verification; success adds it back.
    _ct_remaining_path="$PATH"
    _ct_verified_path=""
    _ct_path_entry_added=0
    while :; do
      _ct_path_entry="''${_ct_remaining_path%%:*}"
      if [ "$_ct_path_entry" != "$RECORDER_VENV/bin" ]; then
        if [ "$_ct_path_entry_added" = 1 ]; then
          _ct_verified_path="$_ct_verified_path:$_ct_path_entry"
        else
          _ct_verified_path="$_ct_path_entry"
          _ct_path_entry_added=1
        fi
      fi
      case "$_ct_remaining_path" in
        *:*) _ct_remaining_path="''${_ct_remaining_path#*:}" ;;
        *) break ;;
      esac
    done
    export PATH="$_ct_verified_path"
    _ct_recorder_branch=""
    _ct_recorder_source=""
    if [ -z "$ROOT_PATH" ]; then
      : # Not inside a CodeTracer checkout: no venv is created.
    elif [ -n "$PURE_RECORDER_SRC" ] && [ -d "$PURE_RECORDER_SRC" ]; then
      _ct_recorder_branch="pure"
      _ct_recorder_source="$PURE_RECORDER_SRC"
    elif [ -n "$RECORDER_SRC" ] && [ -d "$RECORDER_SRC" ]; then
      if command -v maturin &>/dev/null; then
        _ct_recorder_branch="rust"
        _ct_recorder_source="$RECORDER_SRC"
      else
        _ct_python_recorder_broken "maturin is not on PATH, so the Rust-backed recorder cannot be built from $RECORDER_SRC (and no pure-Python recorder source was found)."
      fi
    fi
    if [ -n "$_ct_recorder_branch" ]; then
      if _ct_recorder_interpreter=$("$CODETRACER_PYTHON_CMD" \
        "$ROOT_PATH/scripts/manage_python_recorder_venv.py" \
        "$ROOT_PATH" "$CODETRACER_PYTHON_CMD" \
        "$_ct_recorder_branch" "$_ct_recorder_source"); then
        export CODETRACER_PYTHON_INTERPRETER="$_ct_recorder_interpreter"
        export PATH="$RECORDER_VENV/bin:$PATH"
      else
        _ct_python_recorder_broken "The declared recorder environment could not be verified or reconciled; inspect its retained attempt receipt."
      fi
    fi

    if [ "''${METACRAFT_WORKSPACE_PRESENT:-}" = "1" ]; then
      echo "  workspace: detected (shared scripts at $METACRAFT_WORKSPACE_SCRIPTS)"
    fi
  '';
}
