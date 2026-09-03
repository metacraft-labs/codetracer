{ inputs, ... }:
{
  perSystem =
    {
      system,
      pkgs,
      ...
    }:
    let
      inherit (pkgs) stdenv;

      src = ../../.;

      # Nim and other toolchains from the shared codetracer-toolchains flake.
      toolchainsPkgs = inputs."codetracer-toolchains".packages.${system};

      # Import multiple Rust versions via fenix
      rustVersions = import ../rust-versions {
        inherit pkgs;
        fenix = inputs.fenix;
      };

      # The Python interpreter, forwarded from `codetracer-python-recorder`'s
      # own `.python-version` through ../python.nix — the same file
      # `nix/shells/ci-base.nix` reads, so the package set and the dev shells
      # cannot pick different interpreters, and neither can pick one the
      # recorder does not build for.
      pythonEnv = import ../python.nix { inherit pkgs inputs; };

      # The sibling checkouts a workspace reaches through codetracer's
      # ``nim.cfg`` ``path:"../isonim/src"`` directives, named ONCE. The staging
      # commands and the ``--path:`` flags below are both derived from this
      # list, so the set that gets copied and the set that gets made importable
      # cannot drift apart -- and the flake-input attribute name is the
      # directory name, which is what makes deriving both possible.
      isonimSiblings = [
        "isonim"
        "isonim-tui"
        "isonim-gpui"
        "nim-everywhere"
        "nim-termctl"
        "nim-pty"
        "nim-acp"
        "nim-agent-harbor"
        "nim-agents"
      ];

      # Stage those sources in a writable sibling layout that mirrors
      # ``../isonim`` etc.  The flake inputs come from /nix/store and are
      # read-only, but ``isonim/dsl/tailwind.nim`` does
      # ``staticRead("<isonim-root>/build/tailwind-styles.json")``; the JS-target
      # branch tries to fall back to ``"{}"`` on failure but ``staticRead``
      # raises a compile-time Error that ``try/except`` cannot catch, so we seed
      # an empty ``build/tailwind-styles.json`` next to the staged isonim
      # sources before invoking nim.  The fallback ``{}`` lookup map is enough
      # for the codetracer UI -- there are no Tailwind utility classes consumed
      # through this code path; the real CSS comes from
      # codetracer/src/public/styles.
      prepareIsonimSiblings = ''
        export ISONIM_STAGE="$NIX_BUILD_TOP/isonim-stage"
        mkdir -p "$ISONIM_STAGE"
      ''
      + pkgs.lib.concatMapStrings (name: ''
        cp -a ${inputs.${name}} "$ISONIM_STAGE/${name}"
      '') isonimSiblings
      + ''
        chmod -R u+w "$ISONIM_STAGE"
        mkdir -p "$ISONIM_STAGE/isonim/build"
        [ -f "$ISONIM_STAGE/isonim/build/tailwind-styles.json" ] || \
          echo '{}' > "$ISONIM_STAGE/isonim/build/tailwind-styles.json"
      '';

      # The ``--path:`` flags that make those staged sources importable, as one
      # space-separated string a call site can drop in front of its own flags.
      #
      # This list used to be written out per derivation, four times -- and the
      # FIFTH site, the ``codetracer`` derivation that compiles ``ct`` itself,
      # did not have it at all. That is what `nix build
      # '.?submodules=1#codetracer'` died on:
      #
      #   src/ct/review_session.nim(270, 10) Error: cannot open file: nim_everywhere
      #
      # ``review_session.nim``'s ``when not defined(js)`` branch imports
      # ``nim_everywhere`` and ``nim_agents``. In a workspace those resolve
      # through ``nim.cfg``; inside the sandbox they resolve through these flags
      # and nothing else. Every derivation that compiles Nim from this tree
      # needs them, so there is one copy now.
      isonimNimPaths = pkgs.lib.concatMapStringsSep " " (
        name: ''--path:"$ISONIM_STAGE/${name}/src"''
      ) isonimSiblings;
    in
    {
      packages = rec {
        # Nim versions for testing with different compilers
        inherit (toolchainsPkgs) nim-1_6 nim-2_0 nim-2_2;

        # Rust versions for testing with different compilers
        inherit (rustVersions)
          rust-stable
          rust-nightly
          rust-1_75
          rust-1_80
          ;

        # nim2 (Nim 2.2.x) is used for building CodeTracer itself.
        # Provides both 'nim' and 'nim2' binaries.
        # Wraps all Nim tools with NIM_CONFIG_PATH so they can find the
        # stdlib in the nix store (nim-unwrapped alone doesn't set this).
        nim-codetracer = toolchainsPkgs.nim-2_2.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.makeWrapper ];
          postInstall = (old.postInstall or "") + ''
            ln -sf $out/nim/bin/nim $out/bin/nim2
            for tool in nim nim2 nimsuggest nimgrep nimpretty testament nim_dbg; do
              [ -f "$out/bin/$tool" ] || [ -L "$out/bin/$tool" ] && wrapProgram $out/bin/$tool --set NIM_CONFIG_PATH $out/nim/config
            done
          '';
        });

        # Keep backward compat alias for anything that still references this
        upstream-nim-codetracer = nim-codetracer;

        # `nargo` and friends, built HERE from the `noir` source input rather
        # than taken from a `packages.default` that input exports.
        #
        # WHY THIS IS PACKAGED LOCALLY.  The `noir` input used to be
        # `flake = true` and this line used to read
        # `inputs.noir.packages.${system}.default`. That was not an
        # implementation detail: 50 of the 63 refs on `metacraft-labs/noir`
        # carry a `flake.nix` and all 50 are the 2023-24 legacy lineage that
        # `codetracer-temp` is the newest of, while the modern `codetracer`
        # line — the one whose tracer emits the `.ct` CTFS container
        # `db_backend_record.nim` accepts as its only materialized-trace
        # bundle — has none. So "the input must be a flake" and "the input
        # must be a branch that produces a usable trace" were in direct
        # contradiction, and the flake requirement was winning: `ct record` on
        # Noir was pinned to a tracer writing the retired trace.json sidecar
        # triplet.
        #
        # The two ways out were to port `flake.nix`/`noir.nix`/`shell.nix`
        # forward onto `codetracer`, or to stop needing a flake. This is the
        # second. It was chosen on cost, and the cost is asymmetric:
        #
        #   * Forward-porting is not a copy. `codetracer-temp`'s `noir.nix` is
        #     a `buildRustPackage` whose `cargoLock.outputHashes` name
        #     `plonky2`, `plonky2_u32` and `runtime_tracing` — a dependency set
        #     that does not exist on `codetracer`, which uses
        #     `codetracer_trace_types` instead. Every line of it would be
        #     rewritten. It would also have to grow, inside the noir fork, the
        #     Nim-FFI provisioning that `codetracer_trace_writer_nim`'s
        #     build.rs needs (`CODETRACER_TRACE_FORMAT_NIM_DIR`, the nimble
        #     skip, the `stew`/`results` paths) — machinery THIS repository
        #     already has, for its own `db-backend` derivation further down
        #     this file. And it would add permanent Nix carry to a fork whose
        #     stated strategy (`tooling/tracer/CARRY-VS-UPSTREAM.md`) is to
        #     shrink its delta against upstream toward zero.
        #
        #   * Packaging locally costs this attribute and nothing else. It is
        #     the house pattern: sixteen inputs in `flake.nix` are already
        #     `flake = false`, and `trace-writer-ffi` below already builds a
        #     Rust package from one of them the same way.
        #
        # The trade is real and is stated rather than hidden: this repository
        # now owns noir's build recipe, so a change to noir's build (a new
        # native dependency, a new required env var) lands here as a break
        # instead of arriving pre-solved from the fork. That is the price of
        # the fork not carrying Nix, and it is a price this repository is
        # already paying sixteen times over.
        #
        # ## MEASURED, and every figure names the binary that produced it
        #
        # `nix build .#packages.aarch64-darwin.noir` on 2026-09-03 produced
        # `/nix/store/0yki0k9gzfqg0js2wprmisrfr87sriqi-Noir`, whose `bin/nargo`
        # self-reports `nargo version = 1.0.0-beta.26` (against the previous
        # pin's `beta.2`). Six binaries: `nargo`, `acvm`, `noir-inspector`,
        # `noir-profiler` — the four the flake-supplied package installed — plus
        # `noir-execute` and `noir-ssa`. Everything below was run from that
        # absolute path, NOT from a dev shell, because `detect-siblings.sh`
        # prepends `../noir/target/release` to PATH and a figure from a sibling
        # working copy is attributable to no revision this commit names.
        #
        #   * `nargo trace --out-dir` on the bundled template writes ONE file,
        #     `hello_noir.ct`. That is the whole point of the move: the
        #     previous pin's `store_trace` wrote `trace.json` +
        #     `trace_metadata.json` + `trace_paths.json`, and
        #     `db_backend_record.nim` reads none of the three. Noir recording
        #     through `ct record` was broken and is not any more.
        #
        #   * `nargo info --json` on the same template reports
        #     `main: 17 opcodes`, `directive_invert: 9`,
        #     `directive_integer_quotient: 8`. Those are exactly the numbers
        #     `src/common/noir_constraints.nim` records for the WASM module and
        #     that `test_noir_live_constraints.nim` asserts. The two engines
        #     said 15 and 17 before this move; they now both say 17. Two
        #     engines disagreeing about one circuit was a defect, and it is the
        #     one this move closes.
        #
        #   * The template compiles and its five tests pass with `§` and an em
        #     dash in a comment. `codetracer-temp` refused that
        #     ("Invalid comment character: only ASCII is currently supported",
        #     `noirc_frontend/src/lexer/errors.rs`); upstream removed the check
        #     in `93bb72f8` "feat!: allow UTF-8 in comments (#12699)", which
        #     `codetracer` contains and `codetracer-temp` does not. The
        #     ASCII-only restriction on the bundled template is retirable.
        noir = pkgs.rustPlatform.buildRustPackage {
          pname = "noir";
          # Kept as `Noir` so the store path keeps the name the previous
          # (flake-supplied) package produced; nothing should be matching on
          # it, but a rename is a change nobody asked for.
          name = "Noir";
          version = "unstable";

          src = inputs.noir;

          cargoLock = {
            lockFile = "${inputs.noir}/Cargo.lock";
            # One entry per git-sourced package in noir's `Cargo.lock`.
            # Packages that share a repository share a hash, because the hash
            # is of the fetched tree, not of the package.
            #
            # `codetracer_trace_types` and `codetracer_trace_writer_nim` are
            # git dependencies in noir's workspace (they used to be
            # `../codetracer-trace-format` PATH dependencies, which a flake
            # input cannot supply at all — that conversion is what made this
            # package possible). `clap-markdown` and `sancov` are upstream
            # noir's own git dependencies and have nothing to do with
            # CodeTracer.
            outputHashes = {
              "codetracer_trace_types-0.19.0" = "sha256-wyP96ovIqARw1uFlc0m8i4tJR8121pI0nxqclGnVERU=";
              "codetracer_trace_writer_nim-0.1.0" = "sha256-wyP96ovIqARw1uFlc0m8i4tJR8121pI0nxqclGnVERU=";
              "clap-markdown-0.1.3" = "sha256-2vG7x+7T7FrymDvbsR35l4pVzgixxq9paXYNeKenrkQ=";
              "sancov-0.1.0" = "sha256-D2q3Xtq64fYKIL0W1bXntyIIXsk6015c0fDHVlam/n4=";
              "sancov-sys-0.1.0" = "sha256-D2q3Xtq64fYKIL0W1bXntyIIXsk6015c0fDHVlam/n4=";
            };
          };

          nativeBuildInputs = [
            # `codetracer_trace_writer_nim`'s build.rs compiles a Nim static
            # library and links it. `nargo_cli` turns that crate on via
            # `noir_tracer/nim-writer`, so nim is a BUILD input here, not an
            # optional extra.
            nim-codetracer
            pkgs.gcc
          ];

          # RUSTC_BOOTSTRAP: noir's crates use nightly-only features under a
          # stable toolchain; upstream's own packaging sets this too.
          RUSTC_BOOTSTRAP = 1;
          # nargo stamps these into `nargo --version`. The source arrives here
          # as a Nix store path with no `.git`, so there is nothing truthful to
          # read; say so rather than let the build script guess.
          GIT_COMMIT = "false";
          GIT_DIRTY = "false";

          # `codetracer_trace_writer_nim`'s build.rs defaults to looking for
          # the `codetracer-trace-format-nim` repository as a SIBLING of the
          # trace-format checkout. Inside a cargo *git* checkout there is no
          # such sibling, and inside the Nix sandbox there is no sibling of
          # anything — so point it at the flake input explicitly. This is the
          # one consumer obligation noir's path-to-git conversion created, and
          # it is discharged here.
          CODETRACER_TRACE_FORMAT_NIM_DIR = inputs.codetracer-trace-format-nim;
          # ...and the same two knobs db-backend uses below: `nimble install`
          # needs network access the sandbox does not have, and
          # `requires "results" / "stew"` has to resolve without a nimble
          # package store.
          CODETRACER_TRACE_FORMAT_NIM_SKIP_NIMBLE_INSTALL = "1";
          CODETRACER_TRACE_FORMAT_NIM_EXTRA_PATHS = "${inputs.nim-stew}/stew:${inputs.nim-stew}";

          # WHAT GETS BUILT is noir's workspace `default-members` — the six CLI
          # crates `nargo_cli`, `acvm_cli`, `artifact_cli`, `ssa_cli`,
          # `profiler`, `inspector` — because that is what a bare
          # `cargo build --release` at the workspace root selects, and there is
          # deliberately no `cargoBuildFlags` narrowing it. The previous
          # (flake-supplied) package installed four binaries — `nargo`, `acvm`,
          # `noir-inspector`, `noir-profiler` — and this is a superset of them,
          # so nothing that resolved before stops resolving. Everything else in
          # the workspace (`compiler/wasm`, `tooling/tracer_wasm`, the fuzzers)
          # stays unbuilt: `ci/deploy/noir-wasm.pin` builds the wasm halves from
          # a different revision for a different consumer.

          # noir's test suite drives `nargo` against `test_programs/` and wants
          # a writable cargo home and a network; it is not what this
          # derivation is for.
          doCheck = false;
        };

        wazero = inputs.wazero.packages.${system}.default;

        cargo-stylus =
          inputs.nix-blockchain-development.outputs.legacyPackages.${system}.metacraft-labs.cargo-stylus;

        circom = inputs.nix-blockchain-development.outputs.legacyPackages.${system}.metacraft-labs.circom;

        forc = inputs.nix-blockchain-development.outputs.legacyPackages.${system}.metacraft-labs.forc;

        miden = inputs.nix-blockchain-development.outputs.legacyPackages.${system}.metacraft-labs.miden;

        cargo-build-sbf =
          inputs.nix-blockchain-development.outputs.legacyPackages.${system}.metacraft-labs.cargo-build-sbf;

        # TODO: Point this back at `nix-blockchain-development` when all composed
        # Metacraft flakes share nixos-modules and inherit nixpkgs through it.
        sui = inputs.nix-blockchain-development-sui.outputs.legacyPackages.${system}.metacraft-labs.sui;

        codex-acp =
          let
            # Pick a recent nightly (post-1.88) so dependencies like `home`
            # accept the compiler version and we can still opt into unstable
            # `File::lock` support.
            nightly = inputs.fenix.packages.${system}.default;
            nightlyPlatform = pkgs.makeRustPlatform {
              inherit (nightly) cargo rustc;
            };
          in
          nightlyPlatform.buildRustPackage rec {
            pname = "codex-acp";
            version = "0.7.4";

            src = pkgs.fetchFromGitHub {
              owner = "zed-industries";
              repo = "codex-acp";
              rev = "v${version}";
              hash = "sha256-QGK4CkcH3eaOsjBwCoUSIYglFQ7pw0KtIfJAR9tTpbI=";
              sha256 = "";
            };

            cargoHash = "sha256-Cojr5+ZZTpnOYA0QJ622UFlMhiEbdkkxvnVQqkFxBEI=";

            nativeBuildInputs = [ pkgs.pkg-config ];
            buildInputs = [ pkgs.openssl ];

            doCheck = false;

            # Allow unstable APIs (File::lock) even though this is a nightly
            # build; some crates also gate on minimum rustc versions.
            RUSTC_BOOTSTRAP = "1";

            meta = with pkgs.lib; {
              description = "An ACP-compatible coding agent powered by Codex";
              homepage = "https://github.com/zed-industries/codex-acp";
              changelog = "https://github.com/zed-industries/codex-acp/releases/tag/v${version}";
              license = licenses.asl20;
              maintainers = with maintainers; [ ];
              platforms = platforms.unix;
              sourceProvenance = with sourceTypes; [ fromSource ];
              mainProgram = "codex-acp";
            };
          };

        # curl = pkgs.curl;
        inherit (pkgs) curl;

        inherit (pkgs)
          sqlite
          pcre
          libzip
          openssl
          libuv
          ;

        chromedriver-102 = pkgs.chromedriver.overrideAttrs (_: {
          version = "102.0.5005.27";
          src = builtins.fetchurl {
            url = "https://chromedriver.storage.googleapis.com/102.0.5005.27/chromedriver_linux64.zip";
            sha256 = "sha256:1978xwj9kf8nihgakmnzgibizq6wp74qp2d2fxgrsgggjy1clmbv";
          };

          # this was added by Peter and it's needed
          # in nix channel 23.11
          # for now we're on 22.11, so commented out
          # temporarily:
          # Older version of chromedriver are placed at the root of the zip file,
          # but newer versions are placed in a directory that includes the
          # platform suffix. This is a workaround for that. It should be removed
          # when upgrading to 115.0.5790.98 or newer version. See:
          # https://github.com/NixOS/nixpkgs/commit/f61f5a8a40f7722f38a798c08040cbd3d807e8d4
          buildPhase = ''
            if [ -f chromedriver ]; then
              mkdir -p chromedriver-linux64
              mv chromedriver chromedriver-linux64/
            fi
          '';
        });

        # shellLinksDeps = pkgs.symlinkJoin {
        #   name = "shellLinksDeps";

        #   inherit src;

        #   # unpackPhase = ''
        #   #   echo "ENTERING UNPACK PHASE"
        #   #   cp -Lr ${src}/* .
        #   # '';

        #   paths = [
        #     pkgs.which
        #     pkgs.bash
        #     pkgs.go
        #     pkgs.nodejs-18_x
        #     pkgs.zip
        #     pkgs.unzip
        #     pkgs.curl
        #     pkgs.unixtools.script
        #     pkgs.diffutils
        #     pkgs.gcc
        #     pkgs.ruby
        #     pkgs.python3
        #     pkgs.gdb.outPath
        #     pkgs.electron_19

        #     # pkgs.electron == pkgs.electron.out == pkgs.electron.outPath

        #     chromedriver-102
        #     codetracer-rust
        #     upstream-nim-codetracer
        #     rr-codetracer.outPath
        #     treeSitterLibrary

        #     # ./libs
        #   ];
        # };

        staticDeps = pkgs.symlinkJoin {
          name = "staticDeps";
          paths = [
            pkgs.which

            # pkgs.nodejs-18_x
            pkgs.nodejs_20
            pkgs.nodePackages.npm
            pkgs.nodePackages.webpack-cli
            pkgs.bashInteractive
            pkgs.zip
            pkgs.unzip
            pkgs.curl
            pkgs.tree

            pkgs.gcc # gcc, g++
            pkgs.rustup
            # pkgs.rustc
            # pkgs.go
            nim-codetracer

            # sourcemap-and-macros-nim-codetracer
          ];
          postBuild = ''
            echo links to staticDeps added
          '';
        };

        indexJavascript = stdenv.mkDerivation {
          name = "index.js";
          pname = "index.js";

          inherit src;

          nativeBuildInputs = [
            nim-codetracer
          ];

          # See uiJavascript comment about isonim staging — the
          # frontend ``index.nim`` and ``server_index.nim`` transitively
          # import ``isonim`` modules through middleware/hmr_runtime.
          buildPhase = prepareIsonimSiblings + ''
            ${nim-codetracer.out}/bin/nim2 \
              --warnings:off --sourcemap:on \
              ${isonimNimPaths} \
              -d:ctIndex -d:chronicles_sinks=json \
              -d:nodejs --out:./index.js js src/frontend/index.nim

            ${nim-codetracer.out}/bin/nim2 \
              --warnings:off --sourcemap:on \
              ${isonimNimPaths} \
              -d:ctIndex -d:server -d:chronicles_sinks=json \
              -d:nodejs --out:./server_index.js js src/frontend/index.nim
          '';

          installPhase = ''
            mkdir -p $out/bin

            cp ./server_index.js $out/bin/
            cp ./index.js $out/bin/
          '';
        };

        subwindowJavascript = stdenv.mkDerivation {
          name = "subwindow.js";
          pname = "subwindow.js";

          inherit src;

          nativeBuildInputs = [
            nim-codetracer
          ];

          # See uiJavascript comment about isonim staging.
          buildPhase = prepareIsonimSiblings + ''

            ${nim-codetracer}/bin/nim2 \
                --hints:off --warnings:off \
                ${isonimNimPaths} \
                -d:chronicles_enabled=off  \
                -d:ctRenderer \
                --out:./subwindow.js js src/frontend/subwindow.nim

          '';

          installPhase = ''
            mkdir -p $out/bin

            cp ./subwindow.js $out/bin/
          '';
        };

        uiJavascript = stdenv.mkDerivation {
          name = "ui.js";

          inherit src;

          nativeBuildInputs = [
            nim-codetracer
          ];

          # ``nim.cfg`` adds ``path:"../isonim/src"`` etc. so dev-shell
          # builds pick up the sibling checkouts.  Inside the Nix
          # sandbox there is no ``../isonim`` for nim to find; stage
          # the flake inputs into a writable sibling layout (see
          # ``prepareIsonimSiblings`` above) and pass the staged paths
          # to nim with ``--path:`` so the same imports resolve here.
          buildPhase = prepareIsonimSiblings + ''
            ${nim-codetracer.out}/bin/nim2 \
              --hints:off --warnings:off \
              ${isonimNimPaths} \
              -d:chronicles_enabled=off  \
              -d:ctRenderer \
              --out:./ui.js js src/frontend/ui_js.nim
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp ./ui.js $out/bin/
          '';
        };

        db-backend =
          let
            fullSrc = ../../.;
          in
          pkgs.stdenv.mkDerivation {
            name = "db-backend";
            pname = "db-backend";

            src = fullSrc;

            nativeBuildInputs = [
              pkgs.capnproto
              pkgs.nodejs_20
              pkgs.tree-sitter
              pkgs.rustc
              pkgs.cargo
              pkgs.rustPlatform.cargoSetupHook
              # nim is needed because db-backend's build.rs shells out to
              # codetracer-native-recorder/ct_emulator/build_native_api.sh,
              # which runs ``nim c`` to generate native C files.  Outside
              # the sandbox direnv loads the recorder's flake env; here we
              # provide nim directly.
              nim-codetracer
              pkgs.gcc
            ];

            buildInputs = [ ];

            nativeCheckInputs = [
              pkgs.python3
              pkgs.ruby
              noir
            ];

            # ``CODETRACER_DB_BACKEND_SKIP_DIRENV=1`` makes
            # ``src/db-backend/build.rs::regenerate_c`` call ``bash``
            # directly instead of ``direnv exec``.
            #
            # ``CODETRACER_TRACE_FORMAT_NIM_SKIP_NIMBLE_INSTALL=1`` makes
            # ``codetracer_trace_writer_nim/build.rs`` skip the
            # ``nimble install`` step, which needs network access.
            #
            # ``CT_EMULATOR_EXTRA_NIM_PATHS`` and
            # ``CODETRACER_TRACE_FORMAT_NIM_EXTRA_PATHS`` inject
            # sibling-libs paths into the ``nim c`` invocations so
            # ``requires "results" / "stew"`` resolve without a nimble
            # pkg store.
            CODETRACER_DB_BACKEND_SKIP_DIRENV = "1";
            CODETRACER_TRACE_FORMAT_NIM_SKIP_NIMBLE_INSTALL = "1";

            postUnpack = ''
              # Generate tree-sitter-nim parser
              if [ ! -f $sourceRoot/libs/tree-sitter-nim/src/parser.c ]; then
                echo "Generating tree-sitter-nim parser..."
                (cd $sourceRoot/libs/tree-sitter-nim && tree-sitter generate)
              fi

              # Materialize codetracer-trace-format as a sibling of $sourceRoot
              # so the cargo path deps in src/db-backend/Cargo.toml resolve.
              # Outside the Nix sandbox the workspace .envrc provides a real
              # checkout; inside the sandbox only the flake input is available.
              cp -r ${inputs.codetracer-trace-format} $sourceRoot/../codetracer-trace-format
              chmod -R u+w $sourceRoot/../codetracer-trace-format

              # ``codetracer_trace_writer_nim``'s build.rs (inside the
              # trace-format workspace) reads the Nim FFI entry point
              # from ``../codetracer-trace-format-nim``; ``src/db-backend/build.rs``
              # also canonicalises ``../../../codetracer-native-recorder``
              # to locate Nim ct_emulator sources.  Seed both from the
              # flake inputs.
              cp -r ${inputs.codetracer-trace-format-nim} $sourceRoot/../codetracer-trace-format-nim
              chmod -R u+w $sourceRoot/../codetracer-trace-format-nim
              cp -r ${inputs.codetracer-native-recorder} $sourceRoot/../codetracer-native-recorder
              chmod -R u+w $sourceRoot/../codetracer-native-recorder

              # Copy Cargo.lock to root for cargoSetupHook
              cp $sourceRoot/src/db-backend/Cargo.lock $sourceRoot/Cargo.lock
            '';

            preBuild = ''
              # Inject the codetracer/libs Nim package directories so
              # ``results`` and ``stew`` resolve when
              # build_native_api.sh (ct_emulator) and writer_nim's
              # build.rs (trace-format) run ``nim c``; ``$PWD`` is the
              # unpacked codetracer source at this point.
              if [ -d "$PWD/libs/nim-stew/stew" ]; then
                # Use ``libs/nim-stew/stew`` only -- it ships the
                # newer ``results.nim`` with proper ``Result[void,
                # E]`` support that trace-format-nim and ct_emulator
                # rely on (the older standalone libs/nim-result
                # mishandles ``?`` on void results so we
                # deliberately leave it off the path).  The stew
                # path also provides ``stew/byteutils``, ``stew/io2``
                # and the other modules the trace-format-nim sources
                # transitively pull in.
                NIM_PATHS_LIB="$PWD/libs/nim-stew/stew:$PWD/libs/nim-stew"
                export CT_EMULATOR_EXTRA_NIM_PATHS="$NIM_PATHS_LIB"
                export CODETRACER_TRACE_FORMAT_NIM_EXTRA_PATHS="$NIM_PATHS_LIB"
              fi
              cd src/db-backend
            '';

            buildPhase = ''
              runHook preBuild
              cargo build --release --offline
              runHook postBuild
            '';

            installPhase = ''
              mkdir -p $out/bin $out/lib
              cp target/release/replay-server $out/bin/
              cp target/release/virtualization-layers $out/bin/
              cp target/release/schema-generator $out/bin/

              # ``cargo:rustc-link-arg=-Wl,-rpath,<out_dir>/...`` in
              # ``src/db-backend/build.rs`` embeds the sandbox
              # ``/build/...`` path into the binary's RPATH so it
              # could dlopen ``libmcr_emulator.so`` at runtime from the
              # cargo target dir.  Nix's fixupPhase then rejects the
              # binary because /build/ is not allowed in store paths.
              #
              # Copy the .so into ``$out/lib`` and rewrite the RPATH so
              # the runtime lookup uses an ``$ORIGIN/../lib`` reference
              # instead of the sandbox path.
              find target/release/build -name 'libmcr_emulator.so' -exec cp {} $out/lib/ \;
              for bin in replay-server virtualization-layers schema-generator; do
                ${pkgs.patchelf}/bin/patchelf \
                  --set-rpath '$ORIGIN/../lib' \
                  "$out/bin/$bin"
              done
            '';

            doCheck = true;
            checkPhase = ''
              # nargo needs a writable HOME for its git-dependencies cache lock
              export HOME=$(mktemp -d)
              # Run only the in-crate unit tests (``--lib --bins``), not
              # the cross-language end-to-end integration tests under
              # ``tests/*_flow_*.rs``.  Those exercise sibling-language
              # recorders (codetracer-ruby-recorder,
              # codetracer-shell-recorders, codetracer-js-recorder,
              # codetracer-beam-recorder, codetracer-flow-recorder for
              # noir) through the DAP wire protocol; they require both
              # the recorder binaries AND a matching language runtime
              # (ruby/bash/zsh/node/elixir/erlang/nargo).  The
              # codetracer-only Nix derivation has neither -- the
              # Cross-Repo Integration Tests workflow exercises the same
              # code paths with the recorders + runtimes actually
              # installed.  ``--bins`` keeps the in-binary unit tests
              # (e.g. the noir_executor handshake fixtures) in scope so
              # nothing besides cross-repo plumbing gets dropped here.
              cargo test --release --offline --lib --bins -- \
                --skip tracepoint_interpreter::tests::array_indexing \
                --skip tracepoint_interpreter::tests::log_array \
                --skip backend_dap_server
            '';

            cargoDeps = pkgs.rustPlatform.importCargoLock {
              lockFile = ../../src/db-backend/Cargo.lock;
            };
          };

        backend-manager = pkgs.rustPlatform.buildRustPackage {
          name = "backend-manager";
          pname = "backend-manager";

          # NOTE: the source of this derivation is the CRATE, not the
          # repository. That is deliberate (nothing else in the tree is a
          # build input of ``session-manager``) but it means the sandbox has
          # no ``scripts/``, no sibling repos, no browser and no network --
          # see ``checkPhase`` below.
          src = ../../src/backend-manager;

          cargoLock = {
            lockFile = ../../src/backend-manager/Cargo.lock;
          };

          doCheck = true;
          checkPhase = ''
            runHook preCheck

            # ``buildRustPackage`` runs the crate's whole test suite here,
            # and since 2026-08-01 one of those tests cannot run in a build
            # sandbox at all:
            #
            #   browser_stream_host::tests::
            #     verify_reframing_a_real_browser_recording_reproduces_it_byte_for_byte
            #
            # It reads a *real* browser recording, and that recording is
            # deliberately not committed -- commit 5dc395c1 replaced the
            # committed fixtures with ``scripts/materialize-recording.sh``,
            # which records the three-tier demo from the tree under test:
            # build the WASM tier, instrument it with
            # ``codetracer-wasm-instrumenter``, bundle it, run the JS tier
            # through ``codetracer-js-recorder``, and drive headless
            # Chromium. The rationale for producing rather than committing
            # is sound and is not in question; the consequence is that the
            # test needs the repository, two sibling checkouts, a cargo
            # wasm32 target, node and a browser.
            #
            # This sandbox has none of them and cannot be given them: it is
            # network-isolated by construction and its source is the crate.
            # Until this phase was written the failure showed up as
            #
            #   could not run /scripts/materialize-recording.sh:
            #     No such file or directory (os error 2)
            #
            # -- the test's repo-root walk (``CARGO_MANIFEST_DIR/../..``)
            # landing on ``/`` -- which took out ``backend-manager.drv`` and
            # with it every job that builds the app: nix-build, dev-build,
            # appimage-build, dmg-build, test-ui-tests, test-ui-tests-rr.
            # Reproduced locally with ``nix build .#backend-manager`` and in
            # CI runs 30726348404 / 31385899773.
            #
            # The test is NOT weakened and NOT skipped: it keeps every
            # assertion, and it keeps running under ``test-non-gui``
            # (``just test`` -> ``just test-rust`` -> ``cargo nextest run
            # --release`` inside the checkout), which is a REQUIRED job in
            # ci/verdict/required-jobs.txt. What changes is only that a
            # *packaging* derivation stops pretending to be a lane that can
            # host it. This mirrors the ``db-backend`` derivation above,
            # which excludes its cross-language flow tests for the same
            # reason and points at the job that does run them.
            #
            # ``--target`` is not optional here. ``cargoBuildHook`` builds
            # with ``--target ${pkgs.stdenv.targetPlatform.rust.rustcTarget}``
            # (nixpkgs' cargo-build-hook.sh passes ``--target @rustcTarget@``),
            # which puts its artefacts under ``target/<triple>/release``. A
            # bare ``cargo test --release`` here uses ``target/release``
            # instead, shares nothing with the build that just finished, and
            # recompiles the entire crate graph a second time -- 86 crates
            # rather than 9 -- in every one of the six jobs that depend on
            # this derivation. Passing the same triple makes the check phase
            # reuse the build phase's output, which is what an unoverridden
            # ``cargoCheckHook`` would have done.
            #
            # The reason to fix it is those 77 redundant compiles: CPU, disk
            # and cache pressure across six jobs. It is NOT wall-clock -- A/B
            # on one machine measured 3m08s against 2m50s, an 18s saving,
            # because the dependency compiles parallelise and the critical
            # path is linking the test binary either way.
            cargoTargetTriple=${pkgs.stdenv.targetPlatform.rust.rustcTarget}

            # ---------------------------------------------------------------
            # Second exclusion: the WHOLE test target
            # ``tests/real_recording_integration.rs``.
            #
            # The one above drops a single test. This one drops a target,
            # because every one of its 75 non-ignored tests fails here for the
            # same structural reason, and none of them can be fixed by
            # anything this derivation is allowed to do.
            #
            # That file's tests each need a REAL recording pipeline --
            # ``replay-server``, ``ct-native-replay``, ``rr``, ``nargo`` or the
            # native Ruby recorder -- and its prerequisite gate
            # (``enforce_prereq_present``) makes a missing prerequisite a hard
            # PANIC rather than a skip. That policy is correct and is not
            # weakened here: it was adopted because the previous default
            # reported ``75 passed`` in 0.33s having touched no trace at all,
            # and, in its own words, "reporting that as a pass would be a lie
            # about coverage".
            #
            # A nix build sandbox is network-isolated and its source is the
            # CRATE, so it has no sibling checkouts, no ``rr``, no recorded
            # session and no ``CODETRACER_RR_BACKEND_PATH``. The prerequisites
            # are not merely absent, they are unprovidable. Observed in CI run
            # 32995542998 (job nix-build):
            #
            #   MISSING PREREQUISITE: CODETRACER_RR_BACKEND_PATH is not set
            #   test result: FAILED. 4 passed; 75 failed; 7 ignored
            #   error: test failed, to rerun pass `--test real_recording_integration`
            #
            # -- which took out ``backend-manager.drv`` and with it nix-build,
            # test-ui-tests, test-ui-tests-rr, dev-build, the appimage/dmg
            # builds and push-to-attic, i.e. everything downstream of the app
            # build.
            #
            # The honest accounting, which the commit message and PR repeat
            # rather than bury here: excluding this target from THIS lane
            # loses no coverage this lane ever had (it had none -- the tests
            # only ever panicked here). It does NOT give the target a working
            # home, because it has none. ``test-non-gui`` runs it
            # (``ci/test/non-gui.sh`` -> ``just test`` -> ``just test-rust`` ->
            # ``cargo nextest run --release`` in this crate), but that script
            # deliberately runs it with ``CODETRACER_RR_BACKEND_PATH=``
            # ``CODETRACER_RR_BACKEND_PRESENT=0`` so cross-repo tests stay out
            # of that lane -- which trips the very same gate. And
            # ``test-ui-tests-rr``, the one job that sets
            # ``CODETRACER_RR_BACKEND_PATH`` to a real path, runs only ``just
            # test-gui`` and never enters this crate. Giving these 48 rr tests
            # a lane that can actually satisfy them is a separate change to
            # CI, tracked separately; it is not something this derivation can
            # do, and pretending otherwise by leaving the target here only
            # converts "no coverage" into "no builds".
            #
            # One real cost, stated rather than buried: of that target's 86
            # tests, 4 need no prerequisites and DID pass here -- the gate's
            # own unit tests (prereq_gate_hard_fails_by_default,
            # prereq_gate_downgrades_only_under_the_documented_opt_out,
            # allow_missing_resolution_is_hard_failure_by_default) and the
            # source-scanning meta test
            # every_skip_site_is_routed_through_the_prerequisite_gate. Dropping
            # the target drops those 4 from this lane too. They are tests of
            # the test file's own policy rather than of the product, and
            # keeping only them would mean naming 82 tests to skip -- a list
            # that goes stale the first time anyone adds a test. Splitting them
            # into their own target would be the real fix, but they call
            # private helpers in this file and each tests/*.rs is its own
            # crate, so that is a test-file refactor and not a packaging
            # change.
            excludedTarget=real_recording_integration
            if [ ! -f "tests/$excludedTarget.rs" ]; then
              echo "ERROR: tests/$excludedTarget.rs does not exist." >&2
              echo "The target exclusion below would silently filter nothing. If the" >&2
              echo "target was renamed, rename it here; if it was deleted, delete this" >&2
              echo "exclusion and let the target selection fall back to plain" >&2
              echo "'cargo test'." >&2
              exit 1
            fi

            # The KEPT targets are DISCOVERED, never enumerated. Writing out
            # ``--test dive_in_url_fetch_test --test mcp_origin_test ...`` would
            # mean a newly added ``tests/<name>.rs`` silently never runs here,
            # which is the same class of quiet coverage loss the accounting
            # guard below exists to prevent. Globbing keeps new targets opted
            # IN by default; only the one named above is opted out.
            #
            # ``--bins`` and not ``--lib``: this crate is binary-only (no
            # ``[lib]``, no ``src/lib.rs``), its unit tests live in
            # ``src/main.rs``, and ``cargo test --lib`` would error out with
            # "no library targets found".
            cargoTestTargets="--bins"
            for testFile in tests/*.rs; do
              testTarget=$(basename "$testFile" .rs)
              if [ "$testTarget" = "$excludedTarget" ]; then
                continue
              fi
              cargoTestTargets="$cargoTestTargets --test $testTarget"
            done

            # Two guards keep the single-test exclusion honest -- it must stay
            # exactly one test wide, and it must never become a no-op.
            # ``$cargoTestTargets`` is deliberately unquoted: it is a list of
            # arguments, not one argument.
            # shellcheck disable=SC2086
            listing=$(cargo test --release --offline --target "$cargoTargetTriple" \
              $cargoTestTargets -- --list)
            listed=$(printf '%s\n' "$listing" | grep -c ': test$')

            excluded=browser_stream_host::tests::verify_reframing_a_real_browser_recording_reproduces_it_byte_for_byte
            if ! printf '%s\n' "$listing" | grep -qx "$excluded: test"; then
              echo "ERROR: $excluded is not in this crate's test list." >&2
              echo "The exclusion below would silently filter nothing. If the test was" >&2
              echo "renamed, rename it here; if it was deleted, delete this phase." >&2
              exit 1
            fi

            # shellcheck disable=SC2086
            output=$(cargo test --release --offline --target "$cargoTargetTriple" \
              $cargoTestTargets -- --skip "$excluded" 2>&1) || {
              printf '%s\n' "$output"
              exit 1
            }
            printf '%s\n' "$output"

            # The excluded TARGET must really be gone from the run. Without
            # this, a future ``cargo test`` that ignores ``--test`` selection,
            # or a stray re-addition, would put the 75 unsatisfiable tests back
            # in this lane and the accounting guard below would not notice --
            # it counts only targets that reported ``test result: ok.``, and a
            # panicking target reports FAILED.
            if printf '%s\n' "$output" | grep -q "Running tests/$excludedTarget.rs"; then
              echo "ERROR: tests/$excludedTarget.rs ran in this lane after all." >&2
              echo "It cannot pass in a build sandbox; see the comment above." >&2
              exit 1
            fi

            # The accounting guard below compares the run against the LISTING
            # OF THE SAME SELECTION, so it is structurally blind to a target
            # dropping out of that selection: both sides shrink together and
            # stay consistent with each other. Before target selection existed
            # this could not happen -- a bare ``cargo test`` always ran
            # everything, so the listing was the whole truth -- but selecting
            # targets is exactly what reopens it, and it is the one way this
            # exclusion could still grow quietly. So check the selection
            # against the crate's files on disk, which is the only source of
            # truth this sandbox has. (Verified by mutation M5 in
            # ci/test/backend-manager-check-phase-test.sh, which narrows the
            # discovery glob and which the accounting guard alone does NOT
            # catch.)
            targetsOnDisk=$(ls tests/*.rs | wc -l)
            keptOnDisk=$((targetsOnDisk - 1))
            keptRan=$(printf '%s\n' "$output" | grep -c 'Running tests/')
            if [ "$keptRan" -ne "$keptOnDisk" ]; then
              echo "ERROR: ran $keptRan integration-test targets, expected $keptOnDisk" >&2
              echo "(= all $targetsOnDisk tests/*.rs, minus $excludedTarget)." >&2
              echo "A test target dropped out of the selection. Coverage in this" >&2
              echo "lane must not shrink quietly." >&2
              exit 1
            fi
            if ! printf '%s\n' "$output" | grep -q 'Running unittests'; then
              echo "ERROR: the crate's own unit tests did not run." >&2
              echo "'--bins' dropped out of the target selection. Coverage in this" >&2
              echo "lane must not shrink quietly." >&2
              exit 1
            fi

            # ``--list`` counts ``#[ignore]``d tests too, so account for them
            # explicitly rather than letting them look like lost coverage.
            accounted=$(printf '%s\n' "$output" |
              sed -n 's/^test result: ok\. \([0-9]*\) passed; [0-9]* failed; \([0-9]*\) ignored.*/\1 \2/p' |
              awk '{ total += $1 + $2 } END { print total + 0 }')
            if [ "$accounted" -ne "$((listed - 1))" ]; then
              echo "ERROR: accounted for $accounted tests, expected $((listed - 1))" >&2
              echo "(= $listed listed, minus the one that needs a repository)." >&2
              echo "The exclusion has grown, or tests stopped reporting. Coverage in" >&2
              echo "this lane must not shrink quietly." >&2
              exit 1
            fi

            runHook postCheck
          '';
        };

        ctRemote = stdenv.mkDerivation rec {
          pname = "ct-remote";
          version = "83d7053";

          src = pkgs.fetchurl {
            url = "https://downloads.codetracer.com/DesktopClient.App/DesktopClient.App-linux-x64-${version}.tar.gz";
            sha256 = "sha256-qRja6e+uaM+vfYPXnHIa2L7xTeQvuTqoBIHGP7bexnY=";
          };

          dontUnpack = true;
          nativeBuildInputs = [
            pkgs.gnutar
            pkgs.patchelf
          ];

          installPhase = ''
            mkdir -p $out/bin
            tar -xzf $src
            mv DesktopClient.App $out/bin/ct-remote
            chmod +x $out/bin/ct-remote
            patchelf \
              --set-interpreter ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 \
              --set-rpath ${pkgs.lib.makeLibraryPath [ pkgs.glibc ]} \
              $out/bin/ct-remote
          '';

          meta = {
            description = "Prebuilt ct-remote client binary distributed with Codetracer";
            platforms = [ "x86_64-linux" ];
            mainProgram = "ct-remote";
          };
        };

        console = stdenv.mkDerivation {
          name = "console";

          inherit src;

          nativeBuildInputs = [
            nim-codetracer
          ];

          buildPhase = ''
            ${nim-codetracer.out}/bin/nim2 \
              -d:ctRepl --debugInfo --lineDir:on --threads:on \
              --hints:off --warnings:off \
              -d:chronicles_enabled=off \
              -d:chronicles_sinks=codetracer_output[notimestamps,file] \
              -d:chronicles_line_numbers=true \
              --nimcache:nimcache \
              --out:./console c src/repl/repl.nim
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp ./console $out/bin/
          '';
        };

        # because of `/nix/store/-dispatcher/bin/dispatcher`
        # `/nix/store/<hash2>-task_process/bin/task_process`
        # ..
        # we do symlinkJoin to get
        # `/nix/store/<hash3>-runtime-deps/bin/:
        #  dispatcher
        #  task_process
        #  ..
        # ```

        # Pure-Ruby recorder package. Uses flake input source when available,
        # falls back to submodule path for backward compatibility.
        ruby-recorder-pure =
          let
            rubyRecorderSrc = inputs.codetracer-ruby-recorder;
          in
          stdenv.mkDerivation rec {
            name = "ruby-recorder-pure";
            pname = name;

            src = rubyRecorderSrc;

            dontInstall = true;

            buildPhase = ''

              # Preserve the gems/ path component so that the recorder's
              # self-ignore filter ('gems/') works correctly.  Without this,
              # TracePoint callbacks fire for kernel_patches.rb inside the
              # recorder itself, causing a ~100x slowdown.
              #
              # The entry script uses File.expand_path('../lib', __dir__) to
              # find its lib directory, so bin/ and lib/ must stay as siblings.
              mkdir -p $out/gems/bin $out/gems/lib

              cp -Lr \
              ./gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder \
              $out/gems/bin/

              cp -Lr \
              ./gems/codetracer-pure-ruby-recorder/lib/* \
              $out/gems/lib/

              # Create top-level bin/ symlink so runtimeDeps symlinkJoin picks it up
              mkdir -p $out/bin
              ln -s $out/gems/bin/codetracer-pure-ruby-recorder $out/bin/codetracer-pure-ruby-recorder

            '';
          };

        # Built from the codetracer-ruby-recorder flake input, using our pkgs.ruby
        # to ensure ABI compatibility (the native .so must match the Ruby that loads it).
        ruby-recorder-native = inputs.codetracer-ruby-recorder.lib.mkRubyRecorderPackage pkgs pkgs.ruby;

        # C FFI static library + header for codetracer_trace_writer.
        # Allows Go (cgo) and other C-compatible languages to produce traces
        # using the Rust trace format crates.
        #
        # The trace-format source lives in a git submodule whose content isn't
        # available during `nix flake check`.  We fetch it via a dedicated flake
        # input (codetracer-trace-format) so nix can resolve src and Cargo.lock
        # at evaluation time.
        trace-writer-ffi = pkgs.rustPlatform.buildRustPackage {
          name = "trace-writer-ffi";
          pname = "trace-writer-ffi";

          src = inputs.codetracer-trace-format;

          nativeBuildInputs = [
            pkgs.capnproto
          ];

          buildPhase = ''
            cargo build --release -p codetracer_trace_writer_ffi --offline
          '';

          doCheck = false;

          installPhase = ''
            mkdir -p $out/lib $out/include
            cp target/release/libcodetracer_trace_writer_ffi.a $out/lib/
            cp target/release/libcodetracer_trace_writer_ffi.so $out/lib/ || true
            cp target/release/libcodetracer_trace_writer_ffi.dylib $out/lib/ || true
            if [ -f codetracer_trace_writer_ffi/codetracer_trace_writer.h ]; then
              cp codetracer_trace_writer_ffi/codetracer_trace_writer.h $out/include/
            fi
          '';

          cargoLock = {
            lockFile = "${inputs.codetracer-trace-format}/Cargo.lock";
          };
        };

        resources-derivation = stdenv.mkDerivation rec {
          name = "resources-derivation";
          pname = name;

          inherit src;

          buildPhase = ''

            mkdir -p $out/resources

            echo "RESOURCES derivation"
            ls -la
            cp -Lr ./resources/* $out/resources

          '';

        };

        runtimeDeps = pkgs.symlinkJoin {
          name = "runtime-deps";

          paths = [
            cargo-stylus
            resources-derivation
            db-backend
            backend-manager
            ctRemote
            codetracer-electron
            node-modules-derivation
            stdenv.cc
            pkgs.electron
            pkgs.ruby
            indexJavascript
            uiJavascript
            noir
            wazero
            ruby-recorder-native
            pkgs.universal-ctags
          ]
          ++ staticDeps.paths;

          postBuild = ''

            mkdir -p $out/src

            # Copy over electron entrypoint files
            cp -L ${indexJavascript}/bin/index.js $out/src/
            cp -L ${indexJavascript}/bin/server_index.js $out/src/

            cp -L ${subwindowJavascript}/bin/subwindow.js $out/src/

            # Link system and native JS dependencies
            ln -sf ${node-modules-derivation.out}/bin/node_modules $out/node_modules

            # index.html file
            cp -L ${codetracer-electron.out}/src/frontend/index.html $out/

            # subwindow.html file
            cp -L ${codetracer-electron.out}/src/frontend/subwindow.html $out/

            # Ruby
            # cp -Lr ${ruby-recorder-pure.out}/bin/codetracer-pure-ruby-recorder \
            # $out/bin/

            ln -sf ${codetracer-electron.out}/src/helpers.js $out/src/helpers.js

            # The Karax-compiled renderer (ui.js) and CSS are loaded relative
            # to CODETRACER_PREFIX by the Electron renderer process via index.html.
            # ui.js uses require('./helpers') so helpers.js must also be at the root.
            cp -L ${uiJavascript}/bin/ui.js $out/
            cp -L ${codetracer-electron}/src/helpers.js $out/helpers.js
            # index.html references frontend/styles/ but codetracer-electron
            # installs CSS to styles/ — create the expected path.
            mkdir -p $out/frontend/styles
            cp -Lr ${codetracer-electron}/styles/* $out/frontend/styles/

          '';

          postInstallPhase = ''
            echo "runtimeDeps ", $out;
          '';
        };

        # node-gyp (lzma-native) needs setuptools + distutils, which stopped
        # being bundled with CPython in 3.12. The interpreter itself is NOT
        # chosen here — it comes from ../python.nix, which forwards the
        # recorder repo's declaration. (The commented-out `pkgs.python311`
        # line that used to sit above this was a stale fourth opinion about
        # the version and is gone with it.)
        yarn-python3 = pythonEnv.package.withPackages (p: [
          p.setuptools
          p.distutils
        ]);

        darwin-lzma-native-sed = pkgs.writeShellScriptBin "sed" ''
          if [ "$1" = "-i" ] && [ "''${2-}" = "" ]; then
            shift 2
            exec ${pkgs.gnused}/bin/sed -i "$@"
          fi

          exec ${pkgs.gnused}/bin/sed "$@"
        '';

        darwin-lzma-native-cxx = pkgs.writeShellScriptBin "clang++" ''
          dir=$PWD
          while [ "$dir" != "/" ]; do
            header="$dir/node_modules/node-addon-api/napi.h"
            if [ -f "$header" ]; then
              ${pkgs.gnused}/bin/sed -i \
                's/static const napi_typedarray_type unknown_array_type = static_cast<napi_typedarray_type>(-1);/static const napi_typedarray_type unknown_array_type = napi_int8_array;/' \
                "$header"
              break
            fi
            dir=$(dirname "$dir")
          done

          exec ${stdenv.cc}/bin/c++ "$@"
        '';

        darwin-lzma-native-clang = pkgs.runCommand "darwin-lzma-native-clang" { } ''
          mkdir -p $out/bin
          ln -s ${darwin-lzma-native-cxx}/bin/clang++ $out/bin/clang++
          ln -s ${darwin-lzma-native-cxx}/bin/clang++ $out/bin/c++
        '';

        node-modules-derivation =
          let
            project =
              pkgs.callPackage ../../node-packages/yarn-project.nix
                {
                  nodejs = pkgs.nodejs_20;
                }
                {
                  src = ../../node-packages;
                };
          in
          project.overrideAttrs (oldAttrs: {
            name = "node-modules-derivation";
            pname = "node-modules-derivation";

            nativeBuildInputs = [
              pkgs.typescript
              yarn-python3
            ]
            ++ pkgs.lib.optionals stdenv.isDarwin [
              darwin-lzma-native-sed
              darwin-lzma-native-clang
              pkgs.darwin.cctools
            ];
            buildInputs = oldAttrs.buildInputs ++ [
              yarn-python3
              pkgs.typescript
            ];

            installPhase = oldAttrs.installPhase + ''
              ls -al $out
              # mkdir -p $out/bin

              ln -sf $out/libexec/$name/node_modules $out/bin/node_modules

              echo "after"

              ls -al $out
            '';
          });

        codetracer-electron = stdenv.mkDerivation {
          name = "codetracer-electron";
          pname = "codetracer-electron";

          inherit src;

          nativeBuildInputs = [
            # pkgs.nodejs-18_x
            pkgs.nodejs_20
            node-modules-derivation
          ];

          buildPhase = ''
            echo "Transpiling native helpers"
            ln -sf ${node-modules-derivation.out}/bin/node_modules node_modules

            stylus=${node-modules-derivation.out}/bin/node_modules/.bin/stylus
            webpack=${node-modules-derivation.out}/bin/node_modules/.bin/webpack

            echo "Compiling typescript: helper.ts"
            ${pkgs.typescript}/bin/tsc src/helpers.ts

            echo "Transpiling .styl into .css files using stylus"
            # `renderer.nim`'s `loadTheme` resolves a theme to
            # `frontend/styles/{name}_theme_electron.css`, so these two names are
            # the contract — the `_electron` suffix is not decoration.
            #
            # `default_white_theme.styl` was being built in the light theme's
            # place, and it is a palette: `@import "defaults"` and a list of
            # colour variables, with no `@import "codetracer"` and therefore no
            # rules.  It compiled to a 0-byte file, every time, silently.
            #
            # What shipped was a deployment with exactly one stylesheet in it.
            # Asking for any other theme fetched a path that does not exist,
            # which the static host answers with the SPA's index.html under
            # `content-type: text/html` and `X-Content-Type-Options: nosniff`, so
            # the browser refuses it as a stylesheet and the window renders
            # unstyled. Confirmed against noirstudio.dev: `default_white`,
            # `default_black` and `mac_classic` all returned `text/html`.
            #
            # `default_white_theme_electron.styl` is the entry point that pairs
            # the white palette with `codetracer.styl`; it compiles to 330 KB.
            node $stylus src/frontend/styles/default_white_theme_electron.styl
            node $stylus src/frontend/styles/default_dark_theme_electron.styl
            node $stylus src/frontend/styles/loader.styl
            node $stylus src/frontend/styles/subwindow.styl

            echo "Packaging frontend using webpack"
            node $webpack
          '';

          installPhase = ''
            mkdir -p $out/src/
            mv src/helpers.js $out/src/
            cp src/public/dist/frontend_bundle.js $out/src
            # ``src/db-backend/test-programs/{erlang,elixir}`` etc. are
            # workspace-relative symlinks to sibling repos (e.g.
            # ``../../../../codetracer-beam-recorder/test-programs/erlang``).
            # Inside the nix sandbox those targets don't exist and
            # ``cp -L`` (follow symlinks) aborts with ``cannot stat``.
            # Strip dangling symlinks from the source tree before the
            # bulk copy so the package builds without those siblings.
            # The runtime path resolves sibling sources directly from
            # the dev shell, so dropping them from the packaged output
            # is harmless for the distribution path.
            find src -xtype l -delete 2>/dev/null || true
            cp -Lr src/* $out/src/

            mkdir -p $out/public/
            cp -Lr src/public/* $out/public

            # golden-layout: Copyright (c) 2016 deepstream.io (MIT License)
            # https://github.com/golden-layout/golden-layout/blob/master/LICENSE
            # rm -rf $out/public/third_party/golden-layout
            # mkdir -p $out/public/third_party/golden-layout/
            # mkdir -p $out/public/third_party/golden-layout/dist/css
            # cp -r src/public/third_party/golden-layout/dist/css/* $out/public/third_party/golden-layout/dist/css/
            # mkdir -p $out/public/third_party/golden-layout/dist/img
            # cp -r src/public/third_party/golden-layout/dist/img/* $out/public/third_party/golden-layout/dist/img/

            # file-icons-js: Copyright (c) 2020 Xuanbo (MIT License)
            # https://github.com/exuanbo/file-icons-js?tab=MIT-1-ov-file#readme
            # rm -rf $out/public/third_party/@exuanbo
            # mkdir -p $out/public/third_party/@exuanbo/file-icons-js/
            # cp src/public/third_party/@exuanbo/file-icons-js/LICENSE $out/public/third_party/@exuanbo/file-icons-js/LICENSE
            # mkdir -p $out/public/third_party/@exuanbo/file-icons-js/dist/css
            # cp -r src/public/third_party/@exuanbo/file-icons-js/dist/css/* $out/public/third_party/@exuanbo/file-icons-js/dist/css/

            mkdir -p $out/styles
            mv src/frontend/styles/*.css $out/styles/

            mkdir -p $out/views
            mv views/* $out/views/

            mkdir -p $out/config
            mv src/config/* $out/config/
          '';
        };

        # node-modules-derivation = stdenv.mkDerivation {
        #   name = "node-modules-derivation";
        #   pname = "node-modules-derivation";

        #   inherit src;

        #   nativeBuildInputs = [codetracer-electron];

        # };

        # codetracer-electron = let
        #   yarnDeps = pkgs.mkYarnModules {
        #     pname = "codetracer-electron-modules";
        #     version = "unstable-7";
        #     packageJSON = "${root}/package.json";
        #     yarnLock = "${root}/yarn.lock";
        #   };

        #   node-19-headers = builtins.fetchurl {
        #     url = "https://www.electronjs.org/headers/v19.0.0/node-v19.0.0-headers.tar.gz";
        #     sha256 = "sha256:13f45mjflhw23h0vlxjb43f3vmhy2xn1c9c5z6axlbia0hmc20s5";
        #   };
        # in
        #   stdenv.mkDerivation {
        #     pname = "codetracer-electron";
        #     version = "unstable-7";
        #     inherit src;

        #     nativeBuildInputs = with pkgs; [
        #       python3
        #       nodejs
        #       electron_19
        #     ];

        #     npm_config_tarball = "${node-19-headers}";
        #     GYP_TARBALL = "${node-19-headers}";

        #     buildPhase = ''
        #       cp ${root}/package.json ./
        #       echo "outPath ", ${yarnDeps.outPath}
        #       ls -al ${yarnDeps.out}/
        #     '';

        #     installPhase = ''
        #       mkdir -p $out/src
        #       chmod +r -R $out/src
        #       # cp -r ./deps ./node_modules ./package.json $out
        #       cp ./package.json $out/src/
        #     '';
        #   };

        # native build inputs: e.g. gcc upstream-nim
        # build : runtime inputs: e.g. gcc, rustc others
        # move from shell.nix some deps
        # temporary: shell.nix: get codetracer's deps and put them here
        # TODO: eventually try to reuse tup commands
        codetracer = stdenv.mkDerivation rec {
          name = "codetracer";

          inherit src;

          nativeBuildInputs = with pkgs; [
            nim-codetracer
            staticDeps
            runtimeDeps
            node-modules-derivation
            makeWrapper
          ];
          buildInputs = [
            cargo-stylus
            pkgs.rustc
            pkgs.sqlite
            pkgs.libzip
            pkgs.openssl
            pkgs.libuv
            pkgs.libbpf
            pkgs.elfutils
            pkgs.zstd
            # pkgs.zip
          ];

          buildPhase = prepareIsonimSiblings + ''
            ls -al ${pkgs.sqlite.out}/lib/
            ls -al ${staticDeps.outPath}/bin
            echo ${runtimeDeps.outPath}/bin
            ls -al ${runtimeDeps.outPath}/bin

            # Ensure the C compiler can find libbpf headers for BPF backend modules
            export C_INCLUDE_PATH="${pkgs.libbpf}/include''${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
            export LIBRARY_PATH="${pkgs.libbpf.out}/lib:${pkgs.elfutils.out}/lib''${LIBRARY_PATH:+:$LIBRARY_PATH}"

            # `ct` is compiled with -d:ctTest and therefore imports the
            # incremental test runner.  In a normal workspace these are sibling
            # repos reached through src/ct_test/nim.cfg; in the Nix sandbox the
            # flake inputs are the only available source layout.
            export RUNQUOTA_SRC="${inputs.runquota}"
            export CODETRACER_TRACE_FORMAT_NIM_SRC="${inputs.codetracer-trace-format-nim}/src"
            export CODETRACER_RESULTS_SRC="$PWD/libs/nim-stew/stew"
            export IO_MON_SRC="${inputs.io-mon}/src"
            export NIM_STACKABLE_HOOKS_SRC="${inputs.nim-stackable-hooks}/src"

            ${nim-codetracer.out}/bin/nim2 \
              ${isonimNimPaths} \
              -d:debug -d:asyncBackend=asyncdispatch \
              --mm:refc --hints:off --warnings:off \
              --debugInfo --lineDir:on \
              --boundChecks:on --stacktrace:on --linetrace:on \
              -d:chronicles_sinks=json -d:chronicles_line_numbers=true \
              -d:chronicles_timestamps=UnixTime \
              -d:ssl \
              -d:ctTest -d:testing --hint[XDeclaredButNotUsed]:off \
              -d:codetracerPrefixConst=${runtimeDeps.outPath}/ \
              -d:libcPath=${pkgs.glibc.out} \
              -d:builtWithNix \
              -d:ctEntrypoint \
              -d:pathToNodeModules=${node-modules-derivation.outPath}/bin/node_modules \
              --passL:${pkgs.sqlite.out}/lib/libsqlite3.so.0 \
              --nimcache:nimcache \
              --out:ct c ./src/ct/codetracer.nim

            ${nim-codetracer.out}/bin/nim2 \
              ${isonimNimPaths} \
              -d:debug -d:asyncBackend=asyncdispatch \
              --mm:refc --hints:off --warnings:off \
              --debugInfo --lineDir:on \
              --boundChecks:on --stacktrace:on --linetrace:on \
              -d:chronicles_sinks=json -d:chronicles_line_numbers=true \
              -d:chronicles_timestamps=UnixTime \
              -d:ssl \
              -d:ctTest -d:testing --hint[XDeclaredButNotUsed]:off \
              -d:codetracerPrefixConst=${runtimeDeps.outPath}/ \
              -d:libcPath=${pkgs.glibc.out} \
              -d:builtWithNix \
              -d:ctEntrypoint \
              --passL:${pkgs.sqlite.out}/lib/libsqlite3.so.0 \
              --passL:${pkgs.openssl.out}/lib/libssl.so \
              --passL:${pkgs.openssl.out}/lib/libcrypto.so \
              --nimcache:nimcache \
              --out:db-backend-record c ./src/ct/db_backend_record.nim
          '';

          installPhase = ''

            mkdir -p $out/bin
            mkdir -p $out/lib
            mkdir -p $out/src
            mkdir -p $out/share/codetracer
            mkdir -p $out/tools
            mkdir -p $out/views
            mkdir -p $out/public
            mkdir -p $out/config
            mkdir -p $out/frontend/styles


            cp ./ct $out/bin/

            # Codetracer web
            cp -L ${codetracer-electron}/views/server_index.ejs $out/views
            cp -L ${indexJavascript}/bin/server_index.js $out/server_index.js
            cp -L ${indexJavascript}/bin/index.js $out/index.js
            cp -L ${indexJavascript}/bin/index.js $out/src/index.js

            cp -L ${codetracer-electron}/src/helpers.js $out/

            # UI static resources
            cp -Lr ${codetracer-electron}/src/public/* $out/public/
            # tree ${codetracer-electron}/src/public/third_party/golden-layout
            # tree $out/public/third_party/golden-layout/

            cp -Lr ${codetracer-electron}/src/frontend/styles/* $out/frontend/styles/

            # Config files
            cp -Lr ${codetracer-electron}/src/config/* $out/config

            # The UI itself
            cp -Lr ${uiJavascript}/bin/ui.js $out/

            cp -L ${subwindowJavascript}/bin/subwindow.js $out/src/
            cp -L ${subwindowJavascript}/bin/subwindow.js $out/

            cp $out/ui.js $out/public
            cp -L ${codetracer-electron}/src/helpers.ts $out/

            # Link system and native JS dependencies
            ln -sf ${node-modules-derivation}/bin/node_modules $out/node_modules
            # makes it easier for codetracer.nim: just pass `codetracerExeDir`
            #   for now to electron as folder: TODO maybe it's ok to just pass
            #   `codetracerExeDir / "src"` ? node_module/others?
            cp -L ${codetracer-electron}/src/helpers.js $out/src/helpers.js
            # ln -sf ${codetracer-electron}/src/public/ $out/public

            cp ./ct $out/bin
            cp ./db-backend-record $out/bin
            cp -L ${ctRemote}/bin/ct-remote $out/bin/

            cp -r src/frontend/index.html $out/
            cp -r src/frontend/subwindow.html $out/

          '';

          meta.mainProgram = "ct";

          postFixup = ''
            wrapProgram $out/bin/ct \
              --prefix PATH : $out/bin:${pkgs.lib.makeBinPath [ cargo-stylus ]} \
              --prefix LD_LIBRARY_PATH : ${
                pkgs.lib.makeLibraryPath [
                  pkgs.openssl
                  pkgs.sqlite
                  pkgs.pcre
                  pkgs.glib
                  pkgs.libzip
                  stdenv.cc.cc.lib
                ]
              } \
              --set CODETRACER_PREFIX ${runtimeDeps.outPath}
          '';

        };

        codetracer-dependency-paths = pkgs.writeTextFile {
          name = "all-paths.json";
          text = builtins.toJSON { };
        };

        # AppImage-based package for end-user distribution.
        # Wraps the pre-built AppImage with desktop integration and bundles
        # a copy of bpftrace for capabilities-based process monitoring.
        # Build with: nix build .#codetracer-appimage
        #
        # For NixOS systems, use the companion module at
        # nix/packages/codetracer-appimage/nixos-module.nix to configure
        # security.wrappers for bpftrace capabilities.
        codetracer-appimage =
          let
            appimageChannelPkgs = inputs.appimage-channel.legacyPackages.${system};
          in
          appimageChannelPkgs.callPackage ./codetracer-appimage { };

        default = codetracer;
      };
    };
}
