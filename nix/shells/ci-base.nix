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

  # The Python interpreter, read from the repo that owns it: ../python.nix
  # forwards `codetracer-python-recorder`'s own `.python-version` declaration
  # through the flake input. Nothing in this file may name a Python version.
  pythonEnv = import ../python.nix { inherit pkgs inputs; };

  toolchainsPkgs = inputs'."codetracer-toolchains".packages;
  runquotaPkgs = inputs'.runquota.packages;
  reprobuildPkgs = inputs'.reprobuild.packages;

  # The recorder's Cargo.toml uses ../../codetracer-trace-format path
  # dependencies. Materialise all three locked repositories in that exact
  # relative layout; using the recorder's inner source directory by itself
  # makes Cargo escape the Nix build directory and look under /.
  pythonRecorderSource = pkgs.runCommand "codetracer-python-recorder-layout" { } ''
    mkdir -p "$out/codetracer-python-recorder"
    cp -R \
      ${inputs."codetracer-python-recorder"}/codetracer-python-recorder \
      "$out/codetracer-python-recorder/codetracer-python-recorder"
    cp -R ${inputs.codetracer-trace-format} "$out/codetracer-trace-format"
    cp -R ${inputs.codetracer-trace-format-nim} "$out/codetracer-trace-format-nim"
  '';

  # Built by the recorder repo for the interpreter IT declares. This used to
  # be `mkCodetracerPackages pkgs pkgs.python312` — this repo asserting a
  # version at the repo that owns the ABI, which is the inversion that let the
  # two drift. `mkCodetracerPackagesDefault` takes no interpreter argument, so
  # there is nothing here left to disagree with.
  upstreamPythonRecorderPkg = pythonEnv.recorderPackages.codetracer-python-recorder;
  pythonRecorderPkg = upstreamPythonRecorderPkg.overrideAttrs (old: {
    src = pythonRecorderSource;
    sourceRoot = "codetracer-python-recorder-layout/codetracer-python-recorder/codetracer-python-recorder";
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ ourPkgs.nim-codetracer ];
    propagatedBuildInputs = (old.propagatedBuildInputs or [ ]) ++ [ pythonEnv.pythonPackages.black ];

    # writer_nim normally asks nimble to fetch these dependencies. Nix builds
    # are network-isolated, so use the exact nim-stew gitlink revision pinned
    # in flake.lock; its stew directory also supplies the compatible results
    # module used by trace-format-nim.
    CODETRACER_TRACE_FORMAT_NIM_SKIP_NIMBLE_INSTALL = "1";
    CODETRACER_TRACE_FORMAT_NIM_EXTRA_PATHS = "${inputs.nim-stew}/stew:${inputs.nim-stew}";
  });
  pythonWithRecorder = pythonEnv.package.withPackages (ps: [
    ps.black
    pythonRecorderPkg
  ]);

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

    # direnv is a hard build dependency, not a developer convenience:
    # src/db-backend/build.rs shells out to `direnv exec <recorder-root>
    # bash ct_emulator/build_native_api.sh` to materialise the generated
    # C sources before the Rust build, and scripts/build-siblings.sh
    # builds every sibling repo through `direnv exec` so each one gets
    # its own flake's toolchain. The lint-rust CI job also runs
    # `nix develop ... -c direnv allow <recorder>`.
    #
    # It was never declared here, so those calls only ever worked by
    # accident, when the self-hosted runner happened to leak a direnv
    # from its ambient PATH. Once that stopped, lint-rust died with
    # `direnv: not found` / exit 127 (observed in run 30726348404, where
    # `Setup dev env` had otherwise succeeded in every job) — and because
    # test-non-gui and every build job used to declare `needs: lint-rust`,
    # that single missing binary silently skipped the entire test suite.
    direnv

    # jq parses the `needs` payload in ci/verdict/required-jobs.sh. That
    # gate runs on a stock GitHub-hosted runner (where jq is preinstalled)
    # precisely so it does not depend on this shell — but `ci/lint/bash.sh`
    # lints ci/**/*.sh from in here, and anyone reproducing a CI script
    # locally does so from in here too. Declaring it keeps this shell able
    # to run the repo's own CI scripts, which is the whole point of the
    # exercise that added direnv above.
    jq

    # C/C++ + linkers used by tup, nim's gcc backend, and Rust crates
    # with native dependencies. CMake/Ninja/GTest/Catch2 are exercised by
    # `just test-ct-providers`' real C/C++ provider fixtures.
    gcc
    clang
    binutils
    cmake
    ninja
    pkg-config
    gtest.dev
    catch2_3

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
    #
    # These MUST come from `pythonEnv.pythonPackages`, not from
    # `pkgs.python3Packages`. A `buildPythonPackage` propagates the
    # interpreter it was built for, so the `pkgs.python3Packages` forms put
    # nixpkgs' DEFAULT python (3.13 on the current pin) into this shell —
    # and, sitting above `pythonWithRecorder` in this list, ahead of the
    # pinned 3.12 in the PATH search. `main.nix`'s venv setup then picked it
    # up, producing a 3.13 venv that could not load the recorder's
    # `cpython-312` extension. See ../python.nix.
    pythonEnv.pythonPackages.flake8
    pythonEnv.pythonPackages.distutils
    pythonWithRecorder
    shellcheck

    # Attic cache push + GitHub CLI + AWS artifact upload — used by
    # several CI steps (attic push at the end of a successful nix
    # build, gh for dispatch/observe, awscli2 for artifact storage).
    attic-client
    gh
    awscli2

    # Cloudflare Pages deploy. `wrangler pages deploy` publishes the
    # browser-replay bundle (browser-replay/dist) to the `web-codetracer`
    # Pages project on merges to `cloud` — see
    # .github/workflows/deploy-web-codetracer.yml. We do NOT preinstall
    # node/npx on the eph-* runners; wrangler is pinned by flake.lock and
    # every deploy command runs inside `nix develop .#ci`, mirroring the
    # proven metacraft-labs/web-site pattern. (nixpkgs pin: wrangler 4.x.)
    wrangler

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
    #
    # `fuse` (FUSE 2) is deliberately NOT here: it ships `fusermount`, and
    # nothing in this repo spawns it. tup links `libfuse3.so.4`.
    #
    # `fuse3` IS here, and the reason is worth stating precisely, because a
    # plausible-sounding argument for dropping it is wrong. nixpkgs patches
    # libfuse to try the absolute path `/run/wrappers/bin/fusermount3` — a
    # NixOS `security.wrappers` setuid binary that a devShell cannot
    # provide — and that much is true. But that is only the FIRST of two
    # attempts. `fusermount_posix_spawn` in libfuse 3.17.4 then falls back
    # to `posix_spawnp("fusermount3", …)`: a BARE name, no slash, so PATH
    # *is* searched and the store copy below *is* consulted (verified by
    # disassembly — the two call sites load `.rodata` 0x2bde1
    # "/run/wrappers/bin/fusermount3" and 0x2bdf3 "fusermount3" — and under
    # strace, which shows the PATH copy being execve'd). tup's own literal
    # has the same shape: nixpkgs' `fusermount-setuid.patch` is headed
    # "Tup needs a setuid fusermount which may be outside $PATH" and does
    # `access("/run/wrappers/bin/fusermount3", X_OK) == 0 ? absolute : bare`.
    #
    # So this entry is not inert. What it cannot do is make the helper
    # setuid, which is what unprivileged FUSE mounting ultimately needs:
    # on a host without the setuid wrapper it upgrades
    #
    #   posix_spawn(p)() for fusermount3 failed: No such file or directory
    #   tup error: Timed out waiting for the FUSE file-system to be ready.
    #   tup error: Unable to mount FUSE on .tup/mnt
    #
    # (run 30726348404, `cross-process-linux`) into a permission error that
    # names the real requirement — the honest failure, and a strictly better
    # one. It does not by itself grant the mount.
    #
    # The remaining gap is a host capability, not a package: the system must
    # provide the setuid wrapper (`programs.fuse` /
    # `security.wrappers.fusermount3` on NixOS, the distribution's `fuse3`
    # elsewhere) and a container must be given /dev/fuse. Neither is
    # expressible here; both belong to whoever owns the `eph-linux-x64`
    # runner image. `scripts/require-fuse-mount-helper.sh`, called by
    # `scripts/build-once.sh`, checks for them and reports what is missing
    # by name instead of letting it surface three layers down.
    tup
    fuse3

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

    # C/C++ provider fixtures build real GoogleTest/Catch2/CTest projects.
    # Keep their toolchain independent from the user's profile so `just
    # test-ct-providers` works the same in `devShells.default` and
    # `devShells.ci`.
    export CT_TEST_CC="${clang}/bin/clang"
    export CT_TEST_CXX="${clang}/bin/clang++"
    export CMAKE_PREFIX_PATH="${gtest.dev}:${catch2_3}''${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"

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

    # Materialized Python origin-DAP tests must not depend on a runner-global
    # Python or an adjacent checkout. This absolute interpreter contains the
    # Rust-backed recorder built from the flake-locked input above.
    export CODETRACER_PYTHON_CMD="${pythonWithRecorder}/bin/python3"

    # The declared interpreter — `codetracer-python-recorder`'s own
    # `.python-version`, reached through ../python.nix — published so that
    # shell code never has to resolve `python3` from PATH (which is how
    # `.python-recorder-venv` came to be built with a different minor version
    # than the recorder's compiled extension) and never has to restate the
    # version as a literal. The recorder's own dev shell exports the same three
    # names, so a script that reads them works in either.
    #
    #   CODETRACER_PYTHON_VERSION  "3.12"       — derived from package.version
    #   CODETRACER_PYTHON_ABI_TAG  "cpython-312" — the tag a compiled
    #                                              extension module must carry
    #
    # `nix/shells/main.nix` builds the venv from CODETRACER_PYTHON_CMD, and
    # `scripts/test-python-version-alignment.sh` compares the venv, the
    # recorder's built `.so` and the recorder's `requires-python` against
    # these. Both read them; neither hardcodes a version.
    export CODETRACER_PYTHON_VERSION="${pythonEnv.version}"
    export CODETRACER_PYTHON_ABI_TAG="${pythonEnv.abiTag}"

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
