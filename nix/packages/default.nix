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

        noir = inputs.noir.packages.${system}.default;

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
              --path:"$ISONIM_STAGE/isonim/src" \
              --path:"$ISONIM_STAGE/isonim-tui/src" \
              --path:"$ISONIM_STAGE/isonim-gpui/src" \
              --path:"$ISONIM_STAGE/nim-everywhere/src" \
              --path:"$ISONIM_STAGE/nim-termctl/src" \
              --path:"$ISONIM_STAGE/nim-pty/src" \
              -d:ctIndex -d:chronicles_sinks=json \
              -d:nodejs --out:./index.js js src/frontend/index.nim

            ${nim-codetracer.out}/bin/nim2 \
              --warnings:off --sourcemap:on \
              --path:"$ISONIM_STAGE/isonim/src" \
              --path:"$ISONIM_STAGE/isonim-tui/src" \
              --path:"$ISONIM_STAGE/isonim-gpui/src" \
              --path:"$ISONIM_STAGE/nim-everywhere/src" \
              --path:"$ISONIM_STAGE/nim-termctl/src" \
              --path:"$ISONIM_STAGE/nim-pty/src" \
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
                --path:"$ISONIM_STAGE/isonim/src" \
                --path:"$ISONIM_STAGE/isonim-tui/src" \
                --path:"$ISONIM_STAGE/isonim-gpui/src" \
                --path:"$ISONIM_STAGE/nim-everywhere/src" \
                --path:"$ISONIM_STAGE/nim-termctl/src" \
                --path:"$ISONIM_STAGE/nim-pty/src" \
                -d:chronicles_enabled=off  \
                -d:ctRenderer \
                --out:./subwindow.js js src/frontend/subwindow.nim

          '';

          installPhase = ''
            mkdir -p $out/bin

            cp ./subwindow.js $out/bin/
          '';
        };

        # Stage isonim sources in a writable sibling layout that
        # mirrors ``../isonim`` etc. as expected by codetracer's
        # ``nim.cfg`` path directives.  The flake inputs come from
        # /nix/store and are read-only, but ``isonim/dsl/tailwind.nim``
        # does ``staticRead("<isonim-root>/build/tailwind-styles.json")``;
        # the JS-target branch tries to fall back to ``"{}"`` on
        # failure but ``staticRead`` raises a compile-time Error that
        # ``try/except`` cannot catch, so we have to seed an empty
        # ``build/tailwind-styles.json`` next to the staged isonim
        # sources before invoking nim.  The fallback ``{}`` lookup map
        # is enough for the codetracer UI — there are no Tailwind
        # utility classes consumed through this code path; the real
        # CSS comes from codetracer/src/public/styles.
        prepareIsonimSiblings = ''
          export ISONIM_STAGE="$NIX_BUILD_TOP/isonim-stage"
          mkdir -p "$ISONIM_STAGE"
          cp -a ${inputs.isonim} "$ISONIM_STAGE/isonim"
          cp -a ${inputs.isonim-tui} "$ISONIM_STAGE/isonim-tui"
          cp -a ${inputs.isonim-gpui} "$ISONIM_STAGE/isonim-gpui"
          cp -a ${inputs.nim-everywhere} "$ISONIM_STAGE/nim-everywhere"
          cp -a ${inputs.nim-termctl} "$ISONIM_STAGE/nim-termctl"
          cp -a ${inputs.nim-pty} "$ISONIM_STAGE/nim-pty"
          chmod -R u+w "$ISONIM_STAGE"
          mkdir -p "$ISONIM_STAGE/isonim/build"
          [ -f "$ISONIM_STAGE/isonim/build/tailwind-styles.json" ] || \
            echo '{}' > "$ISONIM_STAGE/isonim/build/tailwind-styles.json"
        '';

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
              --path:"$ISONIM_STAGE/isonim/src" \
              --path:"$ISONIM_STAGE/isonim-tui/src" \
              --path:"$ISONIM_STAGE/isonim-gpui/src" \
              --path:"$ISONIM_STAGE/nim-everywhere/src" \
              --path:"$ISONIM_STAGE/nim-termctl/src" \
              --path:"$ISONIM_STAGE/nim-pty/src" \
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
            ];

            buildInputs = [ ];

            nativeCheckInputs = [
              pkgs.python3
              pkgs.ruby
              noir
            ];

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
              cd src/db-backend
            '';

            buildPhase = ''
              runHook preBuild
              cargo build --release --offline
              runHook postBuild
            '';

            installPhase = ''
              mkdir -p $out/bin
              cp target/release/replay-server $out/bin/
              cp target/release/virtualization-layers $out/bin/
              cp target/release/schema-generator $out/bin/
            '';

            doCheck = true;
            checkPhase = ''
              # nargo needs a writable HOME for its git-dependencies cache lock
              export HOME=$(mktemp -d)
              cargo test --release --offline -- \
                --skip tracepoint_interpreter::tests::array_indexing \
                --skip tracepoint_interpreter::tests::log_array \
                --skip backend_dap_server \
                --skip ruby_flow_integration \
                --skip bash_flow_integration \
                --skip zsh_flow_integration \
                --skip javascript_flow_integration
            '';

            cargoDeps = pkgs.rustPlatform.importCargoLock {
              lockFile = ../../src/db-backend/Cargo.lock;
            };
          };

        backend-manager = pkgs.rustPlatform.buildRustPackage {
          name = "backend-manager";
          pname = "backend-manager";

          src = ../../src/backend-manager;

          cargoLock = {
            lockFile = ../../src/backend-manager/Cargo.lock;
          };
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

        # yarn-python3 = pkgs.python311;

        # those are needed for python312 and later probably
        yarn-python3 = pkgs.python312.withPackages (p: [
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
            node $stylus src/frontend/styles/default_white_theme.styl
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
            # pkgs.zip
          ];

          buildPhase = ''
            ls -al ${pkgs.sqlite.out}/lib/
            ls -al ${staticDeps.outPath}/bin
            echo ${runtimeDeps.outPath}/bin
            ls -al ${runtimeDeps.outPath}/bin

            # Ensure the C compiler can find libbpf headers for BPF backend modules
            export C_INCLUDE_PATH="${pkgs.libbpf}/include''${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
            export LIBRARY_PATH="${pkgs.libbpf.out}/lib:${pkgs.elfutils.out}/lib''${LIBRARY_PATH:+:$LIBRARY_PATH}"

            ${nim-codetracer.out}/bin/nim2 \
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
