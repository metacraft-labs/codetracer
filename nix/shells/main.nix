{
  pkgs,
  inputs,
  inputs',
  self',
  config,
}:
let
  ourPkgs = self'.packages;
  preCommit = config.pre-commit;

  # Import toolchains from the codetracer-toolchains flake for multi-language support.
  # These provide compilers needed by `ct record` → `ct-native-replay build` for new languages.
  toolchainsPkgs = inputs'."codetracer-toolchains".packages;
  runquotaPkgs = inputs'.runquota.packages;
  reprobuildPkgs = inputs'.reprobuild.packages;

  # Rust toolchain managed by Nix (via fenix), not rustup.  Replaces the
  # earlier `rustup` package + `rustup override set 1.89` shellHook that
  # required a writable ~/.rustup directory and broke when that state
  # file became corrupt.  The combined toolchain bundles cargo, clippy,
  # rust-src, rustc, rustfmt plus the rust-std for the four targets the
  # codetracer crates compile against:
  #   - x86_64-unknown-linux-gnu       — native build of ct, db-backend.
  #   - wasm32-unknown-unknown         — browser-replay wasm bundle built
  #                                       by src/db-backend/build_wasm.sh
  #                                       (used by `just test-wasm-replay`).
  #   - wasm32-unknown-emscripten      — legacy db-backend wasm path.
  #   - wasm32-wasip1                  — flow/omniscience test target the
  #                                       MCR emulator uses for `just
  #                                       test-wasm-flow` (and the
  #                                       wasm_example program).
  # Mirrors the `rustWithWasm` pattern used by
  # codetracer-browser-extension and codetracer-ci.
  fenixPkgs = inputs.fenix.packages.${pkgs.system};
  rustToolchain = fenixPkgs.combine [
    fenixPkgs.stable.cargo
    fenixPkgs.stable.clippy
    fenixPkgs.stable.rust-src
    fenixPkgs.stable.rustc
    fenixPkgs.stable.rustfmt
    fenixPkgs.stable.rust-analyzer
    fenixPkgs.targets.wasm32-unknown-unknown.stable.rust-std
    fenixPkgs.targets.wasm32-unknown-emscripten.stable.rust-std
    fenixPkgs.targets.wasm32-wasip1.stable.rust-std
    fenixPkgs.targets.x86_64-unknown-linux-gnu.stable.rust-std
  ];
in
with pkgs;
mkShell {
  # inputsFrom = [ pkgs.codetracer ]; TODO: useful for tup

  # TODO: Add comment explaining why this is needed
  hardeningDisable = [ "all" ];

  # TODO
  # linuxPackages = [
  #   strace
  #   # testing UI
  #   xvfb-run
  # ];

  packages = [
    delta

    # general dependencies
    git

    binaryen
    llvmPackages_21.clang-unwrapped
    # clang
    llvm

    wasm-pack

    gcc
    binutils
    pkg-config

    electron

    # node and build tools
    nodejs_22
    nodePackages.webpack-cli
    corepack

    # ourPkgs.chromedriver-102

    ourPkgs.noir

    capnproto

    # stylus
    ourPkgs.cargo-stylus
    foundry # provides cast, forge, anvil (needed for Stylus and Solidity)

    # blockchain recorder runtime dependencies
    ourPkgs.circom # Circom compiler (needed by codetracer-circom-recorder)

    # codex acp agent client
    ourPkgs.codex-acp

    # Reprobuild MVP tooling. These come from the sibling/public flakes so the
    # CodeTracer shell exposes the same binaries used by Reprobuild's own tests.
    runquotaPkgs.runquota
    reprobuildPkgs.reprobuild

    yarn
    yarn2nix

    gnugrep
    gawk
    wget
    coreutils
    killall
    ripgrep
    universal-ctags

    # Make alternative
    # https://github.com/casey/just
    just

    # Test runner
    cargo-nextest

    # Rust toolchain (managed by Nix/fenix — see `rustToolchain` in the
    # let-block above).  Bundles cargo/clippy/rustc/rustfmt/rust-analyzer/
    # rust-src + rust-std for native, wasm32-unknown-unknown, and
    # wasm32-unknown-emscripten targets.
    rustToolchain
    emscripten
    capnproto
    # ourPkgs.codetracer-rust-wrapped

    # For inspecting our deb packages
    dpkg

    sqlite
    pcre
    glib
    libelf
    # clang
    # curl
    openssl
    which
    unixtools.script
    bashInteractive
    # ovh-ttyrec
    dash
    lesspipe
    unixtools.killall
    # zip
    # unzip
    libzip
    # zstd: required at link time by codetracer_trace_writer_nim (transitive
    # dep of tup-built recorder crates). The trace writer uses libzstd directly
    # via -lzstd; without zstd in the dev shell the tup-sandboxed linker fails
    # with `ld: cannot find -lzstd`.
    zstd
    curl

    # for pgrep at least

    # development
    pstree
    # watch-like tool with history/time travel support
    viddy
    # a tool to help with binary files
    hexdump

    # docs
    mdbook

    # github CLI
    gh

    # Attic support
    attic-client

    # ruby experimental support
    libyaml
    ruby
    ruby-lsp

    # ============================================
    # Compilers for new language support (ct record)
    # Using toolchains from codetracer-toolchains
    # ============================================

    # Go (needed by ct-native-replay build for Go programs)
    toolchainsPkgs.go-default

    # Lean 4 - theorem prover and functional programming language
    lean4

    # testing shell
    tmux
    vim

    # mac build

    tree-sitter

    # TODO: use eventually if more stable, instead of
    # a lot of the shellHook logic
    # ourPkgs.staticDeps

    # Nim 2.2.x — the primary compiler (provides nim and nim2)
    ourPkgs.nim-codetracer
    # nimble is required at build time by codetracer_trace_writer_nim's
    # build.rs to resolve the Nim FFI library's `.nimble` deps before
    # `nim c` runs.
    nimble

    # TODO: uncomment when nim-devel builds from source work in nix
    # ourPkgs.nim-devel

    # useful for lsp/editor support
    nimlsp
    nimlangserver
    rust-analyzer

    # ci deps
    python3Packages.flake8
    shellcheck
    awscli2

    # This dependency is needed only while compiling the `lzma-native`
    # node.js module, and only when building an AppImage on Linux/ARM.
    # (i.e. during the `yarn install` step).
    # TODO: This is quite curious. We should investigate how the AppImage
    # build environment is different from the regular one.
    python3Packages.distutils

    # Playwright / display dependencies (used by TS e2e tests)
    playwright-driver.browsers
    playwright

    # runtime_tracing build dependency
    capnproto
  ]
  ++ pkgs.lib.optionals (!stdenv.isDarwin) [
    ourPkgs.ctRemote

    glibc_multi

    # Tup depends on Linux/FUSE support and does not currently build on Darwin.
    tup
    fuse

    # for pgrep at least
    procps

    # Playwright / display dependencies (used by TS e2e tests)
    xvfb-run
    xorg.xorgserver # provides Xephyr for visible virtual X11
    xdotool # cross-window mouse/keyboard automation for multi-window e2e tests

    # BPF process monitoring (used by `just developer-setup` Phase 2)
    bpftrace
    libbpf # Userspace BPF library (loading, maps, ring buffers) for native BPF backend
    bpftools # bpftool for generating vmlinux.h and inspecting BPF objects

    # Extra native-language compiler coverage that is currently Linux-only or
    # marked broken in the macOS shells.
    toolchainsPkgs.fpc
    toolchainsPkgs.gfortran
    toolchainsPkgs.ldc
    toolchainsPkgs.crystal
    toolchainsPkgs.gnat
    toolchainsPkgs.gprbuild

    # Blockchain recorder tools not currently packaged for the Darwin shells.
    ourPkgs.forc # Sway/Fuel compiler (needed by codetracer-fuel-recorder)
    ourPkgs.miden # Miden compiler (needed by codetracer-miden-recorder)
    ourPkgs.cargo-build-sbf # Solana BPF compiler (needed by codetracer-solana-recorder)
    ourPkgs.sui # Sui compiler (needed by codetracer-move-recorder)

    # Building AppImage
    inputs'.appimage-channel.legacyPackages.appimagekit
    appimage-run
    pax-utils
  ]
  ++ pkgs.lib.optionals stdenv.isDarwin [
    # Building AppImage
    create-dmg
  ]
  # Pre-commit hooks
  ++ [ preCommit.settings.package ]
  ++ preCommit.settings.enabledPackages;

  # ldLibraryPaths = "${sqlite.out}/lib/:${pcre.out}/lib:${glib.out}/lib";

  shellHook = ''
    # Install pre-commit hooks automatically
    ${preCommit.installationScript}

    # Symlink the generated config
    ln -sf ${preCommit.settings.configFile} .pre-commit-config.yaml

    # Rust toolchain + wasm targets are provided directly by Nix/fenix
    # (see `rustToolchain` in the let-block).  The previous setup ran
    # `rustup override set 1.89` and three `rustup target add` lines
    # here, which required a writable ~/.rustup directory and silently
    # broke on hosts where that state file got corrupted.

    export CPPFLAGS_wasm32_unknown_unknown="--target=wasm32 --sysroot=$(pwd)/src/db-backend/wasm-sysroot -isystem $(pwd)/src/db-backend/wasm-sysroot/include"
    export CFLAGS_wasm32_unknown_unknown="-I$(pwd)/src/db-backend/wasm-sysroot/include -DNDEBUG -Wbad-function-cast -Wcast-function-type -fno-builtin"

    # copied from https://github.com/NixOS/nix/issues/8034#issuecomment-2046069655
    ROOT_PATH=$(git rev-parse --show-toplevel)

    # copied case for libstdc++.so (needed by better-sqlite3) from
    # https://discourse.nixos.org/t/what-package-provides-libstdc-so-6/18707/4:
    # gcc.cc.lib ..
    export CT_LD_LIBRARY_PATH="${sqlite.out}/lib/:${pcre.out}/lib:${glib.out}/lib:${openssl.out}/lib:${gcc.cc.lib}/lib:${libzip.out}/lib:${zstd.out}/lib";
    export CODETRACER_LD_LIBRARY_PATH="$CT_LD_LIBRARY_PATH"

    # LIBRARY_PATH is the standard gcc/ld compile-time library search path
    # (distinct from LD_LIBRARY_PATH which is for runtime). This ensures that
    # -lssl, -lcrypto, -lsqlite3, -lpcre, -lzip, -lzstd resolve during linking
    # when Nim uses --dynlibOverride + --passL instead of runtime dlopen (see
    # src/Tuprules.tup DYNLIB_OVERRIDE_FLAGS). This is particularly important
    # for tup builds, which sanitize the environment and strip the Nix
    # wrapper's NIX_LDFLAGS variable.
    #
    # zstd is required because codetracer_trace_writer_nim (a transitive dep
    # of tup-built recorder crates) links against libzstd via its build.rs
    # (`cargo:rustc-link-lib=dylib=zstd`). Without zstd on LIBRARY_PATH the
    # tup sandbox link step fails with `ld: cannot find -lzstd`.
    export LIBRARY_PATH="${openssl.out}/lib:${sqlite.out}/lib:${pcre.out}/lib:${libzip.out}/lib:${zlib.out}/lib:${zstd.out}/lib${
      pkgs.lib.optionalString (!stdenv.isDarwin) ":${libbpf.out}/lib:${elfutils.out}/lib"
    }''${LIBRARY_PATH:+:$LIBRARY_PATH}";

    # C_INCLUDE_PATH is the standard gcc/cc header search path. Nim invokes
    # gcc directly (not through Nix's cc-wrapper), so NIX_CFLAGS_COMPILE
    # -isystem flags are invisible. We export libbpf's include path
    # explicitly so that #include <bpf/libbpf.h> resolves during tup builds.
    ${pkgs.lib.optionalString (!stdenv.isDarwin) ''
      export C_INCLUDE_PATH="${libbpf}/include''${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}";
    ''}

    export RUST_LOG=info

    # NODE MODULES
    export NIX_NODE_PATH="${ourPkgs.node-modules-derivation}/bin/node_modules"
    export NODE_PATH="$NODE_PATH:$NIX_NODE_PATH"

    # =========
    # (copied from original commit that comments it out):
    #
    # fix: don't set LD_LIBRARY_PATH in shell, but only for needed ops
    #
    # in https://discourse.nixos.org/t/what-package-provides-libstdc-so-6/18707/5
    # and from our xp this seems true even if i didn't think
    # it's important: setting things like this can break other software
    # e.g. nix wasn't working because of clash between itc GLIBC version
    # and some from those LD_LIBRARY_PATH
    #
    # so we pass it in tester explicitly where needed
    # and this already happens in `ct`: however this breaks for now
    # `codetracer`, but not sure what to do there: maybe pass it as well?
    # (however it itself needs the sqlite path)

    # export LD_LIBRARY_PATH = $CT_LD_LIBRARY_PATH

    # ====

    # Playwright/e2e test environment
    export PLAYWRIGHT_BROWSERS_PATH=${pkgs.playwright-driver.browsers}
    export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true

    # workaround to reuse devshell node_modules for tup build
    # make sure it's always updated
    rm -rf $ROOT_PATH/node_modules
    ln -s $NIX_NODE_PATH $ROOT_PATH/node_modules

    export CODETRACER_PREFIX=$ROOT_PATH/src/build-debug
    export CODETRACER_REPO_ROOT_PATH=$ROOT_PATH
    export REPROBUILD_SOURCE_ROOT=${inputs.reprobuild}
    export REPROBUILD_USE_SYSTEM_HASH_LIBS=1
    export BLAKE3_PREFIX=${pkgs.libblake3}
    export RUNQUOTA_SRC=${inputs.runquota}
    export XXHASH_PREFIX=${pkgs.xxHash}
    export PATH=$ROOT_PATH/src/build-debug/bin:$PATH
    export PATH=$ROOT_PATH/node_modules/.bin/:$PATH
    export CODETRACER_DEV_TOOLS=0
    export CODETRACER_LOG_LEVEL=INFO

    # Ensure tree-sitter-nim parser is generated (cached - only regenerates if needed)
    if [ -d "$ROOT_PATH/libs/tree-sitter-nim" ]; then
      (cd "$ROOT_PATH/libs/tree-sitter-nim" && just generate)
    fi

    # ===========================================================================
    # Workspace tools detection
    # ===========================================================================
    # Detect shared metacraft scripts by walking up from the repo root.
    # Supports both direct nesting (metacraft/codetracer/) and workspace
    # nesting (metacraft/codetracer-main/codetracer/).
    WORKSPACE_ROOT="$(cd "$ROOT_PATH/.." 2>/dev/null && pwd)"
    METACRAFT_SCRIPTS=""

    # Check parent (workspace dir or metacraft root)
    if [ -n "$WORKSPACE_ROOT" ] && [ -d "$WORKSPACE_ROOT/scripts" ]; then
      METACRAFT_SCRIPTS="$WORKSPACE_ROOT/scripts"
    fi
    # Check grandparent (metacraft root when inside a workspace dir)
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

    # ===========================================================================
    # Sibling repo detection (unified script)
    # ===========================================================================
    source "$ROOT_PATH/scripts/detect-siblings.sh" "$ROOT_PATH"

    # Alias for Python venv setup below: detect-siblings.sh exports
    # CODETRACER_PYTHON_RECORDER_SRC when the sibling is found.
    RECORDER_SRC="''${CODETRACER_PYTHON_RECORDER_SRC:-}"

    # ==== Python recorder venv setup ====
    # Install the pure-Python recorder into a venv so that `ct record` can
    # use it for Python tracing. We use the pure-Python package (no Rust /
    # maturin dependency) to avoid requiring maturin in the dev shell.
    # The venv is cached in .python-recorder-venv/ and re-created only when
    # the module becomes un-importable (e.g. after source changes).
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
      # Fallback: try the Rust-backed recorder (requires maturin).
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

    # Print workspace tools summary
    if [ "''${METACRAFT_WORKSPACE_PRESENT:-}" = "1" ]; then
      echo "  workspace: detected (shared scripts at $METACRAFT_WORKSPACE_SCRIPTS)"
    fi

    # Sibling summary is printed by detect-siblings.sh above.
  '';
}
