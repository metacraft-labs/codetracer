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

      rubyPkg = pkgs.ruby_3_3;
    in
    {
      packages = rec {
        upstream-nim-codetracer = pkgs.buildPackages.nim1.overrideAttrs (_: {
          postInstallPhase = ''
            mv $out/nim $out/upstream-nim
          '';
        });

        noir = inputs.noir.packages.${system}.default;

        wazero = inputs.wazero.packages.${system}.default;

        cargo-stylus =
          inputs.nix-blockchain-development.outputs.legacyPackages.${system}.metacraft-labs.cargo-stylus;

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
            upstream-nim-codetracer

            # sourcemap-and-macros-nim-codetracer
          ];
          postBuild = ''
            echo links to staticDeps added
          '';
        };

        appimageDeps = pkgs.runCommand "codetracer-appimage-deps" {
          nativeBuildInputs = [
            pkgs.bashInteractive
            pkgs.coreutils
            pkgs.findutils
            pkgs.gnugrep
            pkgs.pax-utils
            pkgs.file
            pkgs.patchelf
          ];
        } ''
          set -euo pipefail
          shopt -s nullglob

          mkdir -p "$out/bin" "$out/lib" "$out/ruby"

          cp -R ${rubyPkg}/. "$out/ruby"
          chmod -R u+w "$out/ruby"

          copy_libs() {
            for lib in "$@"; do
              cp -n -L "$lib" "$out/lib/" || true
            done
          }

          copy_bins() {
            while [ "$#" -gt 0 ]; do
              cp -L "$1" "$out/bin/"
              shift
            done
          }

          copy_libs \
            ${sqlite.out}/lib/libsqlite3.so* \
            ${pcre.out}/lib/libpcre.so* \
            ${libzip.out}/lib/libzip.so* \
            ${openssl.out}/lib/libssl.so* \
            ${openssl.out}/lib/libcrypto.so* \
            ${libuv.out}/lib/libuv.so*

          copy_bins \
            ${cargo-stylus}/bin/cargo-stylus \
            ${wazero}/bin/wazero \
            ${noir}/bin/nargo \
            ${pkgs.universal-ctags}/bin/ctags \
            ${pkgs.curl}/bin/curl \
            ${pkgs.nodejs_20}/bin/node

          collect_transitive_libs() {
            local binary
            for binary in "$@"; do
              lddtree -l "$binary" | grep /nix | grep -v glibc | while read -r dep; do
                [ -f "$dep" ] || continue
                cp -n -L "$dep" "$out/lib/" || true
              done
            done
          }

          collect_transitive_libs \
            ${cargo-stylus}/bin/cargo-stylus \
            ${wazero}/bin/wazero \
            ${noir}/bin/nargo \
            ${pkgs.universal-ctags}/bin/ctags \
            ${pkgs.curl}/bin/curl \
            ${pkgs.nodejs_20}/bin/node \
            ${rubyPkg}/bin/ruby

          chmod +x "$out/bin"/*

          INTERPRETER_PATH="${
            if pkgs.stdenv.hostPlatform.system == "aarch64-linux"
            then "/lib/ld-linux-aarch64.so.1"
            else "/lib64/ld-linux-x86-64.so.2"
          }"

          patch_binary() {
            local bin=$1
            if file "$bin" | grep -q 'ELF'; then
              patchelf --remove-rpath "$bin" || true
              patchelf --set-interpreter "''${INTERPRETER_PATH}" "$bin"
              patchelf --set-rpath '$ORIGIN/../lib' "$bin"
            fi
          }

          for bin in "$out/bin"/*; do
            [ -f "$bin" ] || continue
            patch_binary "$bin" || true
          done

          patch_binary "$out/ruby/bin/ruby" || true
        '';

        nimBuildInputs = [
          pkgs.gcc
          pkgs.sqlite
          pkgs.pcre
          pkgs.libzip
          pkgs.openssl
          pkgs.libuv
        ];

        nimBuildSetup = ''
          export HOME=$TMPDIR/home
          mkdir -p "$HOME"
          mkdir -p nimcache
        '';

        mkNimBinary =
          {
            name,
            outName,
            cmd,
          }:
          stdenv.mkDerivation {
            inherit src name;

            nativeBuildInputs = [
              upstream-nim-codetracer
            ];

            buildInputs = nimBuildInputs;

            buildPhase = ''
              ${nimBuildSetup}
              ${cmd}
            '';

            installPhase = ''
              mkdir -p $out/bin
              install -m 0755 ${outName} $out/bin/${outName}
            '';
          };

        mkNimJs =
          {
            name,
            outName,
            cmd,
          }:
          stdenv.mkDerivation {
            inherit src name;

            nativeBuildInputs = [
              upstream-nim-codetracer
            ];

            buildInputs = nimBuildInputs;

            buildPhase = ''
              ${nimBuildSetup}
              ${cmd}
            '';

            installPhase = ''
              mkdir -p $out
              install -m 0644 ${outName} $out/${outName}
            '';
          };

        appimageCtUnwrapped =
          mkNimBinary {
            name = "codetracer-appimage-ct-unwrapped";
            outName = "ct_unwrapped";
            cmd = ''
              ${upstream-nim-codetracer.out}/bin/nim -d:release \
                --d:asyncBackend=asyncdispatch \
                --dynlibOverride:std -d:staticStd \
                --gc:refc --hints:on --warnings:off \
                --dynlibOverride:"sqlite3" \
                --dynlibOverride:"pcre" \
                --dynlibOverride:"libzip" \
                --dynlibOverride:"libcrypto" \
                --dynlibOverride:"libssl" \
                --passL:"-Wl,-Bstatic -lsqlite3 -Wl,-Bdynamic" \
                --passL:"${appimageDeps}/lib/libpcre.so.1" \
                --passL:"${appimageDeps}/lib/libzip.so.5" \
                --passL:"${appimageDeps}/lib/libcrypto.so" \
                --passL:"${appimageDeps}/lib/libcrypto.so.3" \
                --passL:"${appimageDeps}/lib/libssl.so" \
                --boundChecks:on \
                -d:useOpenssl3 \
                -d:ssl \
                -d:chronicles_sinks=json -d:chronicles_line_numbers=true \
                -d:chronicles_timestamps=UnixTime \
                -d:ctTest -d:testing --hint"[XDeclaredButNotUsed]":off \
                -d:builtWithNix \
                -d:ctEntrypoint \
                -d:linksPathConst=.. \
                -d:libcPath=libc \
                -d:pathToNodeModules=../node_modules \
                --nimcache:nimcache \
                --out:ct_unwrapped c ./src/ct/codetracer.nim
            '';
          };

        appimageDbBackendRecord =
          mkNimBinary {
            name = "codetracer-appimage-db-backend-record";
            outName = "db-backend-record";
            cmd = ''
              ${upstream-nim-codetracer.out}/bin/nim \
                -d:release -d:asyncBackend=asyncdispatch \
                --gc:refc --hints:off --warnings:off \
                --debugInfo --lineDir:on \
                --boundChecks:on --stacktrace:on --linetrace:on \
                -d:chronicles_sinks=json -d:chronicles_line_numbers=true \
                -d:chronicles_timestamps=UnixTime \
                -d:ssl \
                -d:ctTest -d:testing --hint"[XDeclaredButNotUsed]":off \
                -d:linksPathConst=.. \
                -d:libcPath=libc \
                -d:builtWithNix \
                -d:ctEntrypoint \
                --dynlibOverride:"libsqlite3" \
                --dynlibOverride:"sqlite3" \
                --dynlibOverride:"pcre" \
                --dynlibOverride:"libzip" \
                --passL:"-Wl,-Bstatic -lsqlite3 -Wl,-Bdynamic" \
                --passL:"${appimageDeps}/lib/libpcre.so.1" \
                --passL:"${appimageDeps}/lib/libzip.so.5" \
                --nimcache:nimcache \
                --out:db-backend-record c ./src/ct/db_backend_record.nim
            '';
          };

        appimageIndexJs =
          mkNimJs {
            name = "codetracer-appimage-index-js";
            outName = "index.js";
            cmd = ''
              ${upstream-nim-codetracer.out}/bin/nim \
                --hints:on --warnings:off --sourcemap:on \
                -d:ctIndex -d:chronicles_sinks=json \
                -d:nodejs --out:index.js js src/frontend/index.nim
            '';
          };

        appimageServerIndexJs =
          mkNimJs {
            name = "codetracer-appimage-server-index-js";
            outName = "server_index.js";
            cmd = ''
              ${upstream-nim-codetracer.out}/bin/nim \
                --hints:on --warnings:off --sourcemap:on \
                -d:ctIndex -d:server -d:chronicles_sinks=json \
                -d:nodejs --out:server_index.js js src/frontend/index.nim
            '';
          };

        appimageUiJs =
          mkNimJs {
            name = "codetracer-appimage-ui-js";
            outName = "ui.js";
            cmd = ''
              ${upstream-nim-codetracer.out}/bin/nim \
                --hints:off --warnings:off \
                -d:chronicles_enabled=off  \
                -d:ctRenderer \
                --out:ui.js js src/frontend/ui_js.nim
            '';
          };

        appimageSubwindowJs =
          mkNimJs {
            name = "codetracer-appimage-subwindow-js";
            outName = "subwindow.js";
            cmd = ''
              ${upstream-nim-codetracer.out}/bin/nim \
                --hints:off --warnings:off \
                -d:chronicles_enabled=off  \
                -d:ctRenderer \
                --out:subwindow.js js src/frontend/subwindow.nim
            '';
          };

        appimageCss = pkgs.runCommand "codetracer-appimage-css" {
          nativeBuildInputs = [
            pkgs.coreutils
            pkgs.nodejs_20
            node-modules-derivation
          ];
        } ''
          set -eu

          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"

          mkdir -p "$out/frontend/styles"

          cd ${src}/src/frontend/styles

          stylus="${node-modules-derivation.out}/bin/node_modules/.bin/stylus"

          for style in \
            default_white_theme.styl \
            default_dark_theme_electron.styl \
            loader.styl \
            subwindow.styl
          do
            ${pkgs.nodejs_20}/bin/node "$stylus" -o "$out/frontend/styles" "$style"
          done
        '';

        appimagePayload = pkgs.runCommand "codetracer-appimage-payload" {
          nativeBuildInputs = [
            pkgs.bashInteractive
            pkgs.coreutils
            pkgs.file
            pkgs.gnused
            pkgs.patchelf
          ];
        } ''
          set -euo pipefail

          mkdir -p "$out"
          cp -R ${appimageDeps}/. "$out/"
          chmod -R u+w "$out"
          mkdir -p "$out/bin"
          mkdir -p "$out/src"
          mkdir -p "$out/views"

          cp -Lr ${appimageCss}/frontend "$out/"
          cp -Lr ${src}/libs/codetracer-ruby-recorder "$out/codetracer-ruby-recorder"

          cp -L ${src}/src/helpers.js "$out/helpers.js"
          cp -L ${src}/src/helpers.js "$out/src/helpers.js"

          cp -L ${src}/src/frontend/index.html "$out/index.html"
          cp -L ${src}/src/frontend/index.html "$out/src/index.html"

          cp -L ${src}/src/frontend/subwindow.html "$out/subwindow.html"
          cp -L ${src}/src/frontend/subwindow.html "$out/src/subwindow.html"

          cp -L ${src}/views/server_index.ejs "$out/views/server_index.ejs"

          cp -R ${src}/src/config "$out/config"
          chmod -R u+w "$out/config"
          sed -i 's/skipInstall.*/skipInstall: false/' "$out/config/default_config.yaml"

          cp -R ${src}/resources "$out/resources"
          cp -L ${src}/resources/codetracer.desktop "$out/codetracer.desktop"

          INTERPRETER_PATH="${
            if pkgs.stdenv.hostPlatform.system == "aarch64-linux"
            then "/lib/ld-linux-aarch64.so.1"
            else "/lib64/ld-linux-x86-64.so.2"
          }"

          patch_binary() {
            local bin=$1
            if file "$bin" | grep -q 'ELF'; then
              patchelf --remove-rpath "$bin" || true
              patchelf --set-interpreter "''${INTERPRETER_PATH}" "$bin"
              patchelf --set-rpath '$ORIGIN/../lib' "$bin"
            fi
          }

          install_bin() {
            local src=$1
            local dest=$2
            cp -L "$src" "$out/bin/$(basename "$dest")"
            chmod +x "$out/bin/$(basename "$dest")"
            patch_binary "$out/bin/$(basename "$dest")" || true
          }

          install_bin ${db-backend}/bin/db-backend db-backend
          install_bin ${backend-manager}/bin/backend-manager backend-manager
          install_bin ${appimageCtUnwrapped}/bin/ct_unwrapped ct_unwrapped
          install_bin ${appimageDbBackendRecord}/bin/db-backend-record db-backend-record

          cp -L ${appimageIndexJs}/index.js "$out/index.js"
          cp -L ${appimageIndexJs}/index.js "$out/src/index.js"

          cp -L ${appimageServerIndexJs}/server_index.js "$out/server_index.js"
          cp -L ${appimageServerIndexJs}/server_index.js "$out/src/server_index.js"

          cp -L ${appimageUiJs}/ui.js "$out/ui.js"
          cp -L ${appimageUiJs}/ui.js "$out/src/ui.js"

          cp -L ${appimageSubwindowJs}/subwindow.js "$out/subwindow.js"
          cp -L ${appimageSubwindowJs}/subwindow.js "$out/src/subwindow.js"

          cat <<'EOF' > "$out/bin/ct"
#!/usr/bin/env bash

HERE=''${HERE:-$(dirname "$(readlink -f "$0")")}

# TODO: This includes references to x86_64. What about aarch64?

exec "''${HERE}/bin/ct_unwrapped" "$@"
EOF
          chmod +x "$out/bin/ct"

          cat <<'EOF' > "$out/bin/ruby"
#!/usr/bin/env bash

HERE="''${HERE:-..}"

# TODO: This includes references to x86_64. What about aarch64?
export RUBYLIB="''${HERE}/ruby/lib/ruby/3.3.0:''${HERE}/ruby/lib/ruby/3.3.0/x86_64-linux:''${RUBYLIB}"

"''${HERE}/ruby/bin/ruby" "$@"

EOF
          chmod +x "$out/bin/ruby"

          cat <<'EOF' > "$out/AppRun"
#!/usr/bin/env bash

export HERE=$(dirname "$(readlink -f "$0")")

# TODO: This includes references to x86_64. What about aarch64?
export LINKS_PATH_DIR=''${HERE}
export PATH="''${HERE}/bin:''${PATH}"
export CODETRACER_RUBY_RECORDER_PATH="''${HERE}/codetracer-ruby-recorder/gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder"

exec ''${HERE}/bin/ct "$@"
EOF
          chmod +x "$out/AppRun"

          SRC_ICONSET_DIR="${src}/resources/Icon.iconset"
          for SIZE in 16 32 128 256 512; do
            XSIZE="''${SIZE}x''${SIZE}"
            DST_PATH="$out/usr/share/icons/hicolor/''${XSIZE}/apps/"
            DOUBLE_SIZE_DST_PATH="$out/usr/share/icons/hicolor/''${XSIZE}@2/apps/"
            mkdir -p "$DST_PATH" "$DOUBLE_SIZE_DST_PATH"
            cp "''${SRC_ICONSET_DIR}/icon_''${XSIZE}.png" "''${DST_PATH}/codetracer.png"
            cp "''${SRC_ICONSET_DIR}/icon_''${XSIZE}@2x.png" "''${DOUBLE_SIZE_DST_PATH}/codetracer.png"
          done

          cp "''${SRC_ICONSET_DIR}/icon_256x256.png" "$out/codetracer.png"

          patch_binary "$out/bin/ct_unwrapped" || true
          patch_binary "$out/bin/db-backend-record" || true
          patch_binary "$out/ruby/bin/ruby" || true
        '';

        indexJavascript = stdenv.mkDerivation {
          name = "index.js";
          pname = "index.js";

          inherit src;

          nativeBuildInputs = [
            upstream-nim-codetracer
          ];

          buildPhase = ''
            ${upstream-nim-codetracer.out}/bin/nim \
              --warnings:off --sourcemap:on \
              -d:ctIndex -d:chronicles_sinks=json \
              -d:nodejs --out:./index.js js src/frontend/index.nim

            ${upstream-nim-codetracer.out}/bin/nim \
              --warnings:off --sourcemap:on \
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
            upstream-nim-codetracer
          ];

          buildPhase = ''

            ${upstream-nim-codetracer}/bin/nim \
                --hints:off --warnings:off \
                -d:chronicles_enabled=off  \
                -d:ctRenderer \
                --hotCodeReloading:on \
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
            upstream-nim-codetracer
          ];

          buildPhase = ''
            ${upstream-nim-codetracer.out}/bin/nim \
              --hints:off --warnings:off \
              -d:chronicles_enabled=off  \
              -d:ctRenderer \
              --hotCodeReloading:on \
              --out:./ui.js js src/frontend/ui_js.nim
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp ./ui.js $out/bin/
          '';
        };

        db-backend = pkgs.rustPlatform.buildRustPackage {
          name = "db-backend";
          pname = "db-backend";

          src = ../../src/db-backend;

          nativeBuildInputs = [ pkgs.capnproto ];

          cargoLock = {
            lockFile = ../../src/db-backend/Cargo.lock;
          };

          checkFlags = [
            # skipping because it records traces with outside processes
            # and seems more complex to support in the derivation env for now
            "--skip=tracepoint_interpreter::tests::array_indexing"
            # skipping because it records traces with outside processes
            # and seems more complex to support in the derivation env for now
            "--skip=tracepoint_interpreter::tests::log_array"
            # os no file or directory error in nix build: not sure why
            "--skip=backend_dap_server"
          ];
        };

        backend-manager = pkgs.rustPlatform.buildRustPackage {
          name = "backend-manager";
          pname = "backend-manager";

          src = ../../src/backend-manager;

          cargoLock = {
            lockFile = ../../src/backend-manager/Cargo.lock;
          };
        };

        console = stdenv.mkDerivation {
          name = "console";

          inherit src;

          nativeBuildInputs = [
            upstream-nim-codetracer
          ];

          buildPhase = ''
            ${upstream-nim-codetracer.out}/bin/nim \
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

        # TODO: like this or as a flake input?
        ruby-recorder-pure = stdenv.mkDerivation rec {
          name = "ruby-recorder-pure";
          pname = name;

          inherit src;

          buildPhase = ''

            mkdir -p $out/bin

            cp -Lr \
            ./libs/codetracer-ruby-recorder/gems/codetracer-pure-ruby-recorder/bin/codetracer-pure-ruby-recorder \
            $out/bin

          '';
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
            codetracer-electron
            node-modules-derivation
            stdenv.cc
            pkgs.electron
            pkgs.ruby
            indexJavascript
            uiJavascript
            upstream-nim-codetracer
            noir
            wazero
            ruby-recorder-pure
            pkgs.universal-ctags
          ] ++ staticDeps.paths;

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

            # Nim
            cp -L ${upstream-nim-codetracer.out}/bin/nim $out/bin/upstream-nim

            ln -sf ${codetracer-electron.out}/src/helpers.js $out/src/helpers.js

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
            ];
            buildInputs = oldAttrs.buildInputs ++ [
              yarn-python3
              pkgs.typescript
            ];

            installPhase =
              oldAttrs.installPhase
              + ''
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
            upstream-nim-codetracer
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
            # pkgs.zip
          ];

          buildPhase = ''
            ls -al ${pkgs.sqlite.out}/lib/
            ls -al ${staticDeps.outPath}/bin
            echo ${runtimeDeps.outPath}/bin
            ls -al ${runtimeDeps.outPath}/bin

            ${upstream-nim-codetracer.out}/bin/nim \
              -d:debug -d:asyncBackend=asyncdispatch \
              --gc:refc --hints:off --warnings:off \
              --debugInfo --lineDir:on \
              --boundChecks:on --stacktrace:on --linetrace:on \
              -d:chronicles_sinks=json -d:chronicles_line_numbers=true \
              -d:chronicles_timestamps=UnixTime \
              -d:ssl \
              -d:ctTest -d:testing --hint[XDeclaredButNotUsed]:off \
              -d:linksPathConst=${runtimeDeps.outPath}/ \
              -d:libcPath=${pkgs.glibc.out} \
              -d:builtWithNix \
              -d:ctEntrypoint \
              -d:pathToNodeModules=${node-modules-derivation.outPath}/bin/node_modules \
              --passL:${pkgs.sqlite.out}/lib/libsqlite3.so.0 \
              --nimcache:nimcache \
              --out:ct c ./src/ct/codetracer.nim

            ${upstream-nim-codetracer.out}/bin/nim \
              -d:debug -d:asyncBackend=asyncdispatch \
              --gc:refc --hints:off --warnings:off \
              --debugInfo --lineDir:on \
              --boundChecks:on --stacktrace:on --linetrace:on \
              -d:chronicles_sinks=json -d:chronicles_line_numbers=true \
              -d:chronicles_timestamps=UnixTime \
              -d:ssl \
              -d:ctTest -d:testing --hint[XDeclaredButNotUsed]:off \
              -d:linksPathConst=${runtimeDeps.outPath}/ \
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

            cp -r src/frontend/index.html $out/
            cp -r src/frontend/subwindow.html $out/

          '';

          meta.mainProgram = "ct";

          postFixup = ''
            wrapProgram $out/bin/ct \
              --prefix PATH : ${pkgs.lib.makeBinPath [ cargo-stylus ]}
          '';

        };

        codetracer-dependency-paths = pkgs.writeTextFile {
          name = "all-paths.json";
          text = builtins.toJSON { };
        };

        default = codetracer;
      };
    };
}
