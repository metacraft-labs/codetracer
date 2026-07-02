# Shared base for `devShells.ci` and `devShells.default`. Returns an
# attrset `{ packages, shellHook }` containing everything CI needs to
# build `ct`, link the db-backend Rust crate, run cargo / Playwright
# tests, and exercise the recorders covered by today's CI lanes.
#
# `main.nix` consumes this attrset and adds developer-only extras
# (codex-acp, the agent-toolchain, LSPs, AppImage tooling, the
# Reprobuild + Python-recorder venv setup, etc.). Keep dev-only items
# OUT of this file — they bloat CI runner disk + wall time without
# any test ever exercising them.
{
  pkgs,
  inputs,
  inputs',
  self',
}:
let
  ourPkgs = self'.packages;
  toolchainsPkgs = inputs'."codetracer-toolchains".packages;
  runquotaPkgs = inputs'.runquota.packages;
  reprobuildPkgs = inputs'.reprobuild.packages;

  # Rust toolchain matches main.nix exactly: native build + wasm32-{
  # unknown-unknown, unknown-emscripten, wasip1 } targets needed by
  # ct, db-backend, the browser replay bundle and the MCR emulator
  # test programs.
  fenixPkgs = inputs.fenix.packages.${pkgs.system};
  rustToolchain = fenixPkgs.combine [
    fenixPkgs.stable.cargo
    fenixPkgs.stable.clippy
    fenixPkgs.stable.rust-src
    fenixPkgs.stable.rustc
    fenixPkgs.stable.rustfmt
    fenixPkgs.targets.wasm32-unknown-unknown.stable.rust-std
    fenixPkgs.targets.wasm32-unknown-emscripten.stable.rust-std
    fenixPkgs.targets.wasm32-wasip1.stable.rust-std
    fenixPkgs.targets.x86_64-unknown-linux-gnu.stable.rust-std
  ];
in
with pkgs;
{
  packages = [
    # Source control + scripting basics every step touches.
    git
    coreutils
    gnugrep
    gawk
    wget
    ripgrep
    killall
    bashInteractive
    which
    procps

    # C/C++ + linkers used by tup, nim's gcc backend, and Rust crates
    # with native dependencies.
    gcc
    binutils
    pkg-config

    # Rust toolchain (see `rustToolchain` above) + nextest runner.
    rustToolchain
    cargo-nextest

    # Wasm toolchain: emscripten for wasm32-unknown-emscripten, llvm /
    # binaryen / wasm-pack for the browser-replay bundle.
    emscripten
    binaryen
    wasm-pack
    llvm
    llvmPackages_21.clang-unwrapped

    # Capnp serialisation (db-backend FFI + recorder writers).
    capnproto

    # Nim 2.2.x — primary compiler. `nimble` resolves Nim FFI deps
    # for codetracer_trace_writer_nim's build.rs.
    ourPkgs.nim-codetracer
    nimble

    # Build runner (Linux only — `mkOptionals` below).
    just

    # Frontend: webpack bundle + Electron host + Yarn package mgmt.
    nodejs_22
    nodePackages.webpack-cli
    corepack
    yarn
    yarn2nix
    electron

    # Runtime libraries that get -l'd by Nim / Rust crates at link
    # time inside the tup sandbox.
    sqlite
    pcre
    glib
    libelf
    openssl
    libzip
    zstd
    curl

    # Linting / Python build-deps used by both lint lanes and the
    # node-module install step (lzma-native needs distutils on
    # Linux/ARM).
    python3Packages.flake8
    python3Packages.distutils
    shellcheck

    # Attic cache push + GitHub CLI + AWS artifact upload — used by
    # several CI steps (attic push at the end of a successful nix
    # build, gh for dispatch/observe, awscli2 for artifact storage).
    attic-client
    gh
    awscli2

    # Playwright (M5 lane + codetracer's own TS e2e suite).
    playwright-driver.browsers
    playwright

    # Recorders whose runtime compiler IS exercised today by the
    # CI lanes that ship in this repo. Add new ones here as they
    # come online; keep the dev-only lang compilers in main.nix.
    ourPkgs.noir # codetracer-noir-recorder runtime
    ourPkgs.circom # codetracer-circom-recorder runtime
    ourPkgs.cargo-stylus # M28 (Stylus three-way parity)
    foundry # M28: cast / forge / anvil

    # Reprobuild MVP CLI — `just build-once`'s scripts/build-once.sh
    # invokes `repro` on Linux as a hard requirement. Sibling/public
    # flakes expose the same binaries developers run locally, so the
    # ci and default shells materialise identical reprobuild closures.
    runquotaPkgs.runquota
    reprobuildPkgs.reprobuild
    toolchainsPkgs.go-default # Go programs in record/replay tests
  ]
  ++ pkgs.lib.optionals (!stdenv.isDarwin) [
    # Tup is Linux-only (FUSE-based sandboxing). On Darwin we fall
    # back to a different build path that doesn't need tup.
    tup
    fuse

    # ctRemote is the codetracer remote replay helper used by some
    # CI lanes' integration tests. Not currently packaged for
    # Darwin shells.
    ourPkgs.ctRemote

    # glibc_multi resolves -m32 builds that Nim's csources still
    # produces in some configurations.
    glibc_multi

    # Headless display stack for Playwright / WDIO / Xephyr-based
    # multi-window e2e tests.
    xvfb-run
    xorg.xorgserver
    xdotool
  ];

  # Build-critical environment exports only. Developer convenience
  # (pre-commit install, Python-recorder venv setup, workspace +
  # sibling-repo detection, reprobuild ASP solver paths) lives in
  # main.nix's shellHook.
  shellHook = ''
    # Wasm target sysroot used by build_wasm.sh + db-backend.
    export CPPFLAGS_wasm32_unknown_unknown="--target=wasm32 --sysroot=$(pwd)/src/db-backend/wasm-sysroot -isystem $(pwd)/src/db-backend/wasm-sysroot/include"
    export CFLAGS_wasm32_unknown_unknown="-I$(pwd)/src/db-backend/wasm-sysroot/include -DNDEBUG -Wbad-function-cast -Wcast-function-type -fno-builtin"

    ROOT_PATH=$(git rev-parse --show-toplevel)

    # CT_LD_LIBRARY_PATH is consumed at runtime by `ct` itself
    # (passed through to child processes). gcc.cc.lib is needed by
    # better-sqlite3 (Node native module) which depends on a recent
    # libstdc++.so. zstd is required for the trace writer.
    export CT_LD_LIBRARY_PATH="${sqlite.out}/lib/:${pcre.out}/lib:${glib.out}/lib:${openssl.out}/lib:${gcc.cc.lib}/lib:${libzip.out}/lib:${zstd.out}/lib";
    export CODETRACER_LD_LIBRARY_PATH="$CT_LD_LIBRARY_PATH"

    # LIBRARY_PATH = compile-time -L search path. Set so tup-sandboxed
    # linker steps resolve -lssl / -lcrypto / -lsqlite3 / -lpcre /
    # -lzip / -lzstd when Nim uses --dynlibOverride + --passL (tup
    # strips NIX_LDFLAGS).
    export LIBRARY_PATH="${openssl.out}/lib:${sqlite.out}/lib:${pcre.out}/lib:${libzip.out}/lib:${zlib.out}/lib:${zstd.out}/lib${
      pkgs.lib.optionalString (!stdenv.isDarwin) ":${libbpf.out}/lib:${elfutils.out}/lib"
    }''${LIBRARY_PATH:+:$LIBRARY_PATH}";

    # C_INCLUDE_PATH so Nim's direct gcc invocations see
    # #include <bpf/libbpf.h> when tup sandboxes the build.
    ${pkgs.lib.optionalString (!stdenv.isDarwin) ''
      export C_INCLUDE_PATH="${libbpf}/include''${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}";
    ''}

    # Frontend node_modules: bundled via Nix so tup picks them up
    # deterministically. The symlink is recreated every shell entry
    # so a stale local one never wins.
    export NIX_NODE_PATH="${ourPkgs.node-modules-derivation}/bin/node_modules"
    export NODE_PATH="$NODE_PATH:$NIX_NODE_PATH"
    rm -rf $ROOT_PATH/node_modules
    ln -s $NIX_NODE_PATH $ROOT_PATH/node_modules

    # Playwright (M5 + codetracer's own TS e2e).
    export PLAYWRIGHT_BROWSERS_PATH=${pkgs.playwright-driver.browsers}
    export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true

    # Active build output directory. Linux defaults to the tup build
    # (src/build-<config>); macOS/Windows default to the reprobuild build
    # (src/build-<config>-repro). CODETRACER_CONFIG (debug|release) selects
    # the configuration. We deliberately do NOT export CODETRACER_PREFIX: ct
    # and its sibling/test binaries resolve their prefix self-relatively from
    # their own location (paths.nim's getAppDir().parentDir fallback when
    # CODETRACER_PREFIX is unset), so a binary run from any build output dir
    # uses that dir's assets. CODETRACER_PREFIX stays an explicit override for
    # packaged installs. See codetracer-specs Architecture/
    # Build-Outputs-And-Path-Resolution.md.
    _ct_config="''${CODETRACER_CONFIG:-debug}"
    case "$(uname -s)" in
      Darwin) _ct_build_dir="$ROOT_PATH/src/build-''${_ct_config}-repro" ;;
      *)      _ct_build_dir="$ROOT_PATH/src/build-''${_ct_config}" ;;
    esac
    export CODETRACER_BUILD_DIR="''${CODETRACER_BUILD_DIR:-$_ct_build_dir}"
    export CODETRACER_REPO_ROOT_PATH=$ROOT_PATH

    export PATH=$CODETRACER_BUILD_DIR/bin:$PATH
    export PATH=$ROOT_PATH/node_modules/.bin/:$PATH
    export CODETRACER_DEV_TOOLS=0
    export CODETRACER_LOG_LEVEL=INFO

    # Reprobuild expects to compile the project provider + interface
    # extractor against the SAME source the `repro` binary itself was
    # built from. The flake input already follows the local sibling
    # via the `.envrc` override. `scripts/build-once.sh` calls `repro`
    # which reads these.
    export REPROBUILD_SOURCE_ROOT=${inputs.reprobuild}
    export REPROBUILD_USE_SYSTEM_HASH_LIBS=1
    export BLAKE3_PREFIX=${pkgs.libblake3}
    export RUNQUOTA_SRC=${inputs.runquota}
    export XXHASH_PREFIX=${pkgs.xxHash}

    # repro's ASP solver dlopen()s libclingo by leaf name; ensure
    # the platform loader can find it. Match the flake-pinned clingo
    # so the ABI lines up with repro itself.
    ${pkgs.lib.optionalString stdenv.isDarwin ''
      export DYLD_LIBRARY_PATH="${pkgs.clingo}/lib''${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
    ''}
    ${pkgs.lib.optionalString stdenv.isLinux ''
      export LD_LIBRARY_PATH="${pkgs.clingo}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    ''}
  '';
}
