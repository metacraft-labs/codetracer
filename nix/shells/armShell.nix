{
  pkgs,
  inputs,
  inputs',
  self',
}:
let
  ourPkgs = self'.packages;
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

    gcc
    binutils

    electron_33

    # node and build tools
    nodejs-18_x
    nodePackages.webpack-cli
    corepack

    # ourPkgs.chromedriver-102

    ourPkgs.noir

    # yarn
    inputs.nixpkgs.legacyPackages.aarch64-linux.yarn
    yarn2nix

    gnugrep
    gawk
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

    cargo
    rustfmt
    # ourPkgs.codetracer-rust-wrapped
    clippy

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
    # curl

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
    ruby

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

    # ui-test dependencies
    playwright-driver.browsers
    playwright
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

  ];

  # ldLibraryPaths = "${sqlite.out}/lib/:${pcre.out}/lib:${glib.out}/lib";

  shellHook = ''
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


    # ===========================================================================
    # Sibling repo detection (unified script)
    # ===========================================================================
    source "$ROOT_PATH/scripts/detect-siblings.sh" "$ROOT_PATH"

    # ui-test shell hooks
    export PLAYWRIGHT_BROWSERS_PATH=${pkgs.playwright-driver.browsers}
    export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true

    # workaround to reuse devshell node_modules for tup build
    # make sure it's always updated
    rm -rf $ROOT_PATH/node_modules
    ln -s $NIX_NODE_PATH $ROOT_PATH/node_modules

    export CODETRACER_PREFIX=$ROOT_PATH/src/build-debug
    export CODETRACER_REPO_ROOT_PATH=$ROOT_PATH
    export PATH=$PATH:$PWD/src/build-debug/bin
    export PATH=$PATH:$ROOT_PATH/node_modules/.bin/
    export CODETRACER_DEV_TOOLS=1
    export CODETRACER_LOG_LEVEL=INFO

    figlet "Welcome to CodeTracer"
  '';
}
