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
  # .NET SDK + runtime for C# UI tests (dotnet build)
  dotnet-full = pkgs.dotnetCorePackages.combinePackages [
    pkgs.dotnetCorePackages.sdk_8_0
    pkgs.dotnetCorePackages.runtime_8_0
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
    ourPkgs.upstream-nim-codetracer

    # Nim 1.6 for runtime/development - compatible with vendored libs and nimsuggest
    # Note: Don't add nim-2_x here - it breaks nimsuggest compatibility.
    # Use scripts/with-nim-* for multi-version testing instead.
    ourPkgs.nim-1_6

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

    # ui-test dependencies
    playwright-driver.browsers
    playwright
    dotnet-full
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

    export CODETRACER_LINKS_PATH=$PWD/src/build-debug/

    echo "{\"PYTHONPATH\": \"$CT_PYTHONPATH\",\"LD_LIBRARY_PATH\":\"$CT_LD_LIBRARY_PATH\"}" > ct_paths.json

    # export LD_LIBRARY_PATH="$NIX_LDFLAGS"

    # ==== src/links for tup

    # make sure we have the correct up to date links
    # each time for now
    rm -rf src/links;
    # TODO
    # ln -s "$ {ourPkgs TODO .shellLinksDeps.outPath}" src/links;

    mkdir -p src/links

    cd src;

    [ ! -f links/which ] && ln -s ${which.outPath}/bin/which links/which
    [ ! -f links/bash ] && ln -s ${bash.outPath}/bin/bash links/bash
    [ ! -f links/node ] && ln -s ${nodejs_22.outPath}/bin/node links/node
    [ ! -f links/cmp ] && ln -s ${diffutils.outPath}/bin/cmp links/cmp
    [ ! -f links/ruby ] && ln -s ${ruby.outPath}/bin/ruby links/ruby
    [ ! -f links/nargo ] && ln -s ${ourPkgs.noir.outPath}/bin/nargo links/nargo
    [ ! -f links/wazero ] && ln -s ${ourPkgs.wazero.outPath}/bin/wazero links/wazero
    [ ! -f links/electron ] && ln -s ${electron.outPath}/bin/electron links/electron
    [ ! -f links/ctags ] && ln -s ${universal-ctags.outPath}/bin/ctags links/ctags
    [ ! -f links/curl ] && ln -s ${curl.outPath}/bin/curl links/curl
    [ ! -f links/ct-remote ] && ln -s ${ourPkgs.ctRemote.outPath}/bin/ct-remote links/ct-remote

    # TODO: try to add an option to link to libs/upstream-nim, libs/rr
    #   for faster iteration when patching them as Zahary suggested?
    [ ! -f links/nim1 ] && ln -s ${ourPkgs.upstream-nim-codetracer.outPath}/bin/nim links/nim1
    # [ ! -f links/trace.rb ] && ln -s $ROOT_PATH/libs/codetracer-ruby-recorder/src/trace.rb links/trace.rb

    [ ! -f links/codetracer-ruby-recorder ] && ln -s \
    $ROOT_PATH/libs/codetracer-ruby-recorder/gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder \
    links/codetracer-ruby-recorder

    # [ ! -f links/ ] && ln -s $ROOT_PATH/libs/codetracer-ruby-recorder/src/trace.rb links/trace.rb

    [ ! -f links/recorder.rb ] && ln -s $ROOT_PATH/libs/codetracer-ruby-recorder/src/recorder.rb links/recorder.rb
    [ ! -f links/trace.py ] && ln -s $ROOT_PATH/libs/codetracer-python-recorder/src/trace.py links/trace.py

    cd ..;

    # ==== END of src/links for tup

    # ui-test shell hooks
    export PLAYWRIGHT_BROWSERS_PATH=${pkgs.playwright-driver.browsers}
    export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true

    # used in ui-tests/dotnet_build.sh
    export NIX_NODE=${pkgs.nodejs_22.outPath}/bin/node

    # workaround to reuse devshell node_modules for tup build
    # make sure it's always updated
    rm -rf $ROOT_PATH/node_modules
    ln -s $NIX_NODE_PATH $ROOT_PATH/node_modules

    export NIX_CODETRACER_EXE_DIR=$ROOT_PATH/src/build-debug/
    export LINKS_PATH_DIR=$ROOT_PATH/src/build-debug/
    export CODETRACER_REPO_ROOT_PATH=$ROOT_PATH
    export PATH=$ROOT_PATH/src/build-debug/bin:$PATH
    export PATH=$ROOT_PATH/node_modules/.bin/:$PATH
    export CODETRACER_DEV_TOOLS=0
    export CODETRACER_LOG_LEVEL=INFO

    # ==== Python recorder for ct record (DB-based Python tracing)
    # Build the Rust-backed codetracer_python_recorder module into a venv
    # so that `ct record` can use it for Python tracing. This is only done
    # once (cached in .python-recorder-venv/) and re-triggered if the module
    # becomes un-importable (e.g. after Rust source changes).
    RECORDER_VENV="$ROOT_PATH/.python-recorder-venv"
    RECORDER_SRC="$ROOT_PATH/libs/codetracer-python-recorder/codetracer-python-recorder"
    if [ -d "$RECORDER_SRC" ]; then
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

    # Ensure tree-sitter-nim parser is generated (cached - only regenerates if needed)
    if [ -d "$ROOT_PATH/libs/tree-sitter-nim" ]; then
      (cd "$ROOT_PATH/libs/tree-sitter-nim" && just generate)
    fi

    # --- Sibling detection ---
    # When sibling repos are checked out alongside this one and have been built,
    # add their binaries to PATH and set presence env vars that enable cross-repo
    # integration tests. See: codetracer-specs/Working-with-the-CodeTracer-Repos.md
    WORKSPACE_ROOT="$(cd "$ROOT_PATH/.." 2>/dev/null && pwd)"
    if [ -n "$WORKSPACE_ROOT" ] && [ -x "$WORKSPACE_ROOT/codetracer-rr-backend/target/debug/ct-rr-support" ]; then
      export PATH="$WORKSPACE_ROOT/codetracer-rr-backend/target/debug:$PATH"
      export CODETRACER_RR_BACKEND_PRESENT=1
    fi

    figlet "Welcome to CodeTracer"

    if [ "''${CODETRACER_RR_BACKEND_PRESENT:-}" = "1" ]; then
      echo "  sibling: codetracer-rr-backend detected (ct-rr-support available)"
    fi
  '';
}
