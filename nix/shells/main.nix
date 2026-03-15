{
  pkgs,
  inputs',
  self',
  config,
}:
let
  ourPkgs = self'.packages;
  preCommit = config.pre-commit;

  # Import toolchains from the codetracer-toolchains flake for multi-language support.
  # These provide compilers needed by `ct record` → `ct-rr-support build` for new languages.
  toolchainsPkgs = inputs'."codetracer-toolchains".packages;
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
    # Print a welcome banner for the shell
    figlet
    delta

    # general dependencies
    git

    binaryen
    llvmPackages_21.clang-unwrapped
    # clang
    llvm
    glibc_multi

    wasm-pack

    gcc
    binutils

    electron

    # node and build tools
    nodejs_22
    nodePackages.webpack-cli
    corepack

    # ourPkgs.chromedriver-102

    ourPkgs.noir
    ourPkgs.ctRemote

    capnproto

    # stylus
    ourPkgs.cargo-stylus

    # codex acp agent client
    ourPkgs.codex-acp

    yarn
    yarn2nix

    gnugrep
    gawk
    wget
    coreutils
    killall
    ripgrep
    universal-ctags

    # Tup builds
    fuse
    tup

    # Make alternative
    # https://github.com/casey/just
    just

    rust-analyzer
    rustup
    rustfmt
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
    curl

    # for pgrep at least
    procps

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

    # cachix support
    cachix

    # ruby experimental support
    libyaml
    ruby
    ruby-lsp

    # ============================================
    # Compilers for new language support (ct record)
    # Using toolchains from codetracer-toolchains
    # ============================================

    # Go (needed by ct-rr-support build for Go programs)
    toolchainsPkgs.go-default

    # Pascal
    toolchainsPkgs.fpc

    # Fortran
    toolchainsPkgs.gfortran

    # D language (includes ldmd2)
    toolchainsPkgs.ldc

    # Crystal
    toolchainsPkgs.crystal

    # Lean 4 - theorem prover and functional programming language
    lean4

    # Ada
    toolchainsPkgs.gnat
    toolchainsPkgs.gprbuild

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

    # Legacy Nim 1.6 for transition period (provides nim1)
    ourPkgs.nim1-legacy

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
    xvfb-run
    xorg.xorgserver # provides Xephyr for visible virtual X11

    # runtime_tracing build dependency
    capnproto
  ]
  ++ pkgs.lib.optionals (!stdenv.isDarwin) [
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

    rustup override set 1.89
    rustup target add wasm32-unknown-unknown
    rustup target add wasm32-unknown-emscripten
    rustup target add x86_64-unknown-linux-gnu


    export CPPFLAGS_wasm32_unknown_unknown="--target=wasm32 --sysroot=$(pwd)/src/db-backend/wasm-sysroot -isystem $(pwd)/src/db-backend/wasm-sysroot/include"
    export CFLAGS_wasm32_unknown_unknown="-I$(pwd)/src/db-backend/wasm-sysroot/include -DNDEBUG -Wbad-function-cast -Wcast-function-type -fno-builtin"

    # copied from https://github.com/NixOS/nix/issues/8034#issuecomment-2046069655
    ROOT_PATH=$(git rev-parse --show-toplevel)

    # copied case for libstdc++.so (needed by better-sqlite3) from
    # https://discourse.nixos.org/t/what-package-provides-libstdc-so-6/18707/4:
    # gcc.cc.lib ..
    export CT_LD_LIBRARY_PATH="${sqlite.out}/lib/:${pcre.out}/lib:${glib.out}/lib:${openssl.out}/lib:${gcc.cc.lib}/lib:${libzip.out}/lib";
    export CODETRACER_LD_LIBRARY_PATH="$CT_LD_LIBRARY_PATH"

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
    export PATH=$ROOT_PATH/src/build-debug/bin:$PATH
    export PATH=$ROOT_PATH/node_modules/.bin/:$PATH
    export CODETRACER_DEV_TOOLS=0
    export CODETRACER_LOG_LEVEL=INFO

    # Ensure tree-sitter-nim parser is generated (cached - only regenerates if needed)
    if [ -d "$ROOT_PATH/libs/tree-sitter-nim" ]; then
      (cd "$ROOT_PATH/libs/tree-sitter-nim" && just generate)
    fi

    # ===========================================================================
    # Sibling repo detection (unified script)
    # ===========================================================================
    source "$ROOT_PATH/scripts/detect-siblings.sh" "$ROOT_PATH"

    # Alias for Python venv setup below: detect-siblings.sh exports
    # CODETRACER_PYTHON_RECORDER_SRC when the sibling is found.
    RECORDER_SRC="''${CODETRACER_PYTHON_RECORDER_SRC:-}"

    # ==== Python recorder venv setup ====
    # Build the Rust-backed codetracer_python_recorder module into a venv
    # so that `ct record` can use it for Python tracing. This is only done
    # once (cached in .python-recorder-venv/) and re-triggered if the module
    # becomes un-importable (e.g. after Rust source changes).
    RECORDER_VENV="$ROOT_PATH/.python-recorder-venv"
    if [ -n "$RECORDER_SRC" ] && [ -d "$RECORDER_SRC" ]; then
      if [ ! -d "$RECORDER_VENV" ] || ! "$RECORDER_VENV/bin/python" -c "import codetracer_python_recorder" 2>/dev/null; then
        echo "Setting up Python recorder venv (first time or module needs rebuild)..."
        python3 -m venv "$RECORDER_VENV"
        "$RECORDER_VENV/bin/pip" install --quiet "$RECORDER_SRC" 2>&1 | tail -5
        if "$RECORDER_VENV/bin/python" -c "import codetracer_python_recorder" 2>/dev/null; then
          echo "Python recorder installed successfully."
        else
          echo "WARNING: Failed to install codetracer_python_recorder. Python tracing may not work."
        fi
      fi
      export CODETRACER_PYTHON_INTERPRETER="$RECORDER_VENV/bin/python"
    fi

    figlet "Welcome to CodeTracer"
    # Sibling summary is printed by detect-siblings.sh above.
  '';
}
