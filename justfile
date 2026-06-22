build:
  bash scripts/build.sh

build-once:
  bash scripts/build-once.sh

# Build all sibling-recorder binaries that the GUI tests reach for.
# Idempotent — already-built artefacts short-circuit, so this is cheap on
# warm checkouts.  Pass `--force` to rebuild everything; `--check` to just
# report status without building.  See scripts/build-siblings.sh.
build-siblings *args:
  bash scripts/build-siblings.sh {{args}}

# Smoke-test the built AppImage on multiple Linux distros via Docker.
# Catches glibc/libgcc/libstdc++ symbol-version regressions and missing
# runtime libs that the on-NixOS build can't surface.  Pass the AppImage
# path as the first arg; defaults to ./CodeTracer.AppImage at the repo
# root (which is where `appimage-scripts/build_appimage.sh` writes it).
# See scripts/test-appimage-cross-distro.sh for distro list + tuning.
test-appimage-cross-distro APPIMAGE="./CodeTracer.AppImage" *args:
  bash scripts/test-appimage-cross-distro.sh {{args}} {{APPIMAGE}}

build-docs:
  #!/usr/bin/env bash
  cd docs/book/
  mdbook build

capture-docs-visual-screenshots:
  bash scripts/docs/capture-visual-recording-screenshots.sh

capture-docs-visual-page:
  #!/usr/bin/env bash
  set -euo pipefail
  just capture-docs-visual-screenshots
  just build-docs
  cd src/tests/gui
  node ../../../scripts/docs/capture-book-page-screenshot.mjs

build-ui-js output:
  nim \
    -d:chronicles_enabled=off \
    -d:ctRenderer \
    -d:ctInExtension \
    --debugInfo:on \
    --lineDir:on \
    --hotCodeReloading:on \
    --out:{{output}} \
    js src/frontend/ui_js.nim

# HMR-enabled renderer build. Adds `-d:ctHmr` (which transitively
# activates `-d:isonimHmr`) so {.uiComponent.} pragmas register slots
# and `mountUiHot` boundaries listen for swaps. The runtime gate is
# the env var CT_HMR=1 — without it the transport stays uninstalled
# even in this binary, so this output can be the everyday dev binary.
# CT_HMR_BUNDLE optionally overrides the bundle file the FS watcher
# observes; the default is `src/build-debug/public/ui.js`.
build-ui-js-hmr output:
  nim \
    -d:chronicles_enabled=off \
    -d:ctRenderer \
    -d:ctInExtension \
    -d:ctHmr \
    -d:isonimHmr \
    --debugInfo:on \
    --lineDir:on \
    --hotCodeReloading:on \
    --out:{{output}} \
    js src/frontend/ui_js.nim

# Build the HMR integration fixture: a tiny standalone page that
# mounts two parametric panels via the same {.uiComponent.} +
# mountUiHot pattern production panels use. Used by the
# test-hmr-fixture target.
build-hmr-fixture:
  nim \
    -d:chronicles_enabled=off \
    -d:ctHmr \
    -d:isonimHmr \
    --path:src \
    --hints:off \
    --out:src/tests/hmr_fixture/main.js \
    js src/tests/hmr_fixture/main.nim

# Run the HMR fixture's Playwright spec. Verifies that the codetracer
# integration pattern (parametric pragma + mountUiHot wrapper)
# preserves Panel A's identity / focus / signal state across a swap of
# Panel B's slot, and contains failed swaps without touching Panel A.
# Uses the Playwright install in src/tests/gui/node_modules — the
# fixture has no node_modules of its own.
test-hmr-fixture: build-hmr-fixture
  cd src/tests/gui && ./node_modules/.bin/playwright test --config ../hmr_fixture/playwright.config.ts

test-reprobuild-macos-smoke:
  ./ci/reprobuild/macos-smoke.sh

test-reprobuild-linux-smoke:
  ./ci/reprobuild/linux-smoke.sh

# Drives the vm-harness Hyper-V backend through a fresh
# install -> verify -> uninstall cycle against the produced
# CodeTracer-Setup.exe. Requires a Windows host with Hyper-V enabled
# and a `repro-m69-hyperv` VM carrying a `base-clean` snapshot;
# vm-harness's HyperVBackend skips with a clear message when those
# preconditions are not met. The recipe (re)builds the installer
# first via reprobuild's `windows-installer` target, then exports
# the path through VMH_INSTALLER_HOST_PATH so the test picks it up.
test-windows-installer:
  #!/usr/bin/env bash
  set -euo pipefail
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) echo "Error: test-windows-installer requires a Windows host." >&2; exit 2 ;;
  esac

  vm_harness_root="${VM_HARNESS_ROOT:-../vm-harness}"
  if [ ! -d "$vm_harness_root/src/vm_harness" ]; then
    echo "Error: vm-harness sibling not found at $vm_harness_root." >&2
    echo "Set VM_HARNESS_ROOT or clone metacraft-labs/vm-harness alongside codetracer." >&2
    exit 2
  fi
  vm_harness_root="$(cd "$vm_harness_root" && pwd)"

  bash scripts/build-once.sh
  : "${REPROBUILD_BIN:=../reprobuild/build/bin/repro.exe}"
  "${REPROBUILD_BIN}" build windows-installer \
    --tool-provisioning="${CODETRACER_REPROBUILD_TOOL_PROVISIONING:-scoop}" \
    --log="${CODETRACER_REPROBUILD_LOG:-quiet}"

  installer="$(pwd)/non-nix-build/CodeTracer-Setup.exe"
  if [ ! -f "$installer" ]; then
    echo "Error: $installer was not produced." >&2
    exit 1
  fi

  cd "$vm_harness_root"
  VMH_INSTALLER_HOST_PATH="$installer" \
    nim r --hints:off --warnings:off --verbosity:0 \
      tests/e2e/t_vm_harness_hyperv_windows_installer_smoke.nim

test-reprobuild-hcr-mcr-dap: ensure-ct-mcr ensure-ct-native-replay
  #!/usr/bin/env bash
  set -euo pipefail

  # Platform precondition is an honest SKIP, not a hard error: a non-macOS
  # (or non-arm64) CI run must skip cleanly rather than fail the job.
  if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "SKIP: test-reprobuild-hcr-mcr-dap requires macOS arm64 ($(uname -s) $(uname -m))." >&2
    exit 0
  fi

  if ! command -v repro >/dev/null 2>&1; then
    echo "SKIP: repro not on PATH (run inside the CodeTracer Nix dev shell)." >&2
    exit 0
  fi

  repo_root="$(git rev-parse --show-toplevel)"
  lock_backup=""

  resolve_sibling_repo() {
    local repo_name="$1"
    local override_var="$2"
    local sibling_var="$3"
    local override_value="${!override_var:-}"
    local sibling_value="${!sibling_var:-}"

    if [ -n "$override_value" ]; then
      printf '%s\n' "$override_value"
      return 0
    fi
    if [ -n "$sibling_value" ]; then
      printf '%s\n' "$sibling_value"
      return 0
    fi
    if [ -d "$repo_root/../$repo_name" ]; then
      (cd "$repo_root/../$repo_name" && pwd)
      return 0
    fi
    if [ -d "$repo_root/../../$repo_name" ]; then
      (cd "$repo_root/../../$repo_name" && pwd)
      return 0
    fi

    printf '%s\n' "$repo_root/../$repo_name"
  }

  # --- Reprobuild source tree ---
  # Detection order: explicit override -> non-store REPROBUILD_SOURCE_ROOT ->
  # ../reprobuild sibling. Honest-SKIP (not exit 1) when none carries the
  # repro_hcr_agent library — e.g. the sibling is not checked out.
  reprobuild_sibling_root="$(resolve_sibling_repo reprobuild CODETRACER_REPROBUILD_REPO_PATH CT_REPROBUILD_SIBLING)"
  reprobuild_root="${CODETRACER_REPROBUILD_REPO_PATH:-}"
  if [ -z "$reprobuild_root" ] && [ -n "${REPROBUILD_SOURCE_ROOT:-}" ] && [[ "$REPROBUILD_SOURCE_ROOT" != /nix/store/* ]]; then
    reprobuild_root="$REPROBUILD_SOURCE_ROOT"
  fi
  if [ -z "$reprobuild_root" ] && [ -d "$reprobuild_sibling_root/libs/repro_hcr_agent" ]; then
    reprobuild_root="$reprobuild_sibling_root"
  fi
  if [ -z "$reprobuild_root" ]; then
    reprobuild_root="${REPROBUILD_SOURCE_ROOT:-$reprobuild_sibling_root}"
  fi
  if [ ! -d "$reprobuild_root/libs/repro_hcr_agent" ]; then
    echo "SKIP: reprobuild sibling not detected (set CT_REPROBUILD_SIBLING / CODETRACER_REPROBUILD_REPO_PATH or check it out at \$METACRAFT_ROOT/reprobuild; looked at $reprobuild_root)." >&2
    exit 0
  fi
  export REPROBUILD_SOURCE_ROOT="$reprobuild_root"
  export CODETRACER_REPROBUILD_REPO_PATH="${CODETRACER_REPROBUILD_REPO_PATH:-$reprobuild_root}"

  # --- ct-native-replay (codetracer-native-backend sibling) ---
  # Built on demand by the ensure-ct-native-replay prerequisite. Honest-SKIP
  # when the sibling is absent.
  native_backend="$(resolve_sibling_repo codetracer-native-backend CODETRACER_NATIVE_BACKEND_REPO_PATH CT_CODETRACER_NATIVE_BACKEND_SIBLING)"
  if [ ! -d "$native_backend" ]; then
    echo "SKIP: codetracer-native-backend sibling not detected (set CT_CODETRACER_NATIVE_BACKEND_SIBLING / CODETRACER_NATIVE_BACKEND_REPO_PATH or check it out at \$METACRAFT_ROOT/codetracer-native-backend)." >&2
    exit 0
  fi
  native_replay="$native_backend/target/debug/ct-native-replay"
  if [ ! -x "$native_replay" ]; then
    echo "SKIP: ct-native-replay not built at $native_replay (ensure-ct-native-replay could not produce it)." >&2
    exit 0
  fi
  if [ -z "${LLDB_LIB_PATH:-}" ]; then
    lldb_out="$(nix build --no-link --print-out-paths nixpkgs#lldb)"
    export LLDB_LIB_PATH="$lldb_out/lib"
  fi

  # --- ct-mcr (codetracer-native-recorder sibling) ---
  # Built on demand by the ensure-ct-mcr prerequisite. Honest-SKIP when the
  # sibling or its built binary is absent.
  native_recorder="$(resolve_sibling_repo codetracer-native-recorder CODETRACER_NATIVE_RECORDER_REPO_PATH CT_CODETRACER_NATIVE_RECORDER_SIBLING)"
  if [ ! -d "$native_recorder" ]; then
    echo "SKIP: codetracer-native-recorder sibling not detected (set CT_CODETRACER_NATIVE_RECORDER_SIBLING / CODETRACER_NATIVE_RECORDER_REPO_PATH or check it out at \$METACRAFT_ROOT/codetracer-native-recorder)." >&2
    exit 0
  fi
  ct_mcr=""
  for cand in "$native_recorder/ct_cli/ct_cli-debug" "$native_recorder/ct_cli/ct_cli"; do
    if [ -x "$cand" ]; then ct_mcr="$cand"; break; fi
  done
  if [ -z "$ct_mcr" ]; then
    echo "SKIP: ct-mcr not built under $native_recorder/ct_cli (ensure-ct-mcr could not produce it)." >&2
    exit 0
  fi

  mcr_path_dir="$(mktemp -d "${TMPDIR:-/tmp}/codetracer-m3-ct-mcr.XXXXXX")"
  cleanup() {
    rm -rf "$mcr_path_dir"
    if [ -n "$lock_backup" ] && [ -f "$lock_backup" ]; then
      cp "$lock_backup" "$repo_root/src/db-backend/Cargo.lock"
      rm -f "$lock_backup"
    fi
  }
  trap cleanup EXIT
  ln -sf "$ct_mcr" "$mcr_path_dir/ct-mcr"

  export CT_NATIVE_REPLAY_PATH="$native_replay"
  export CT_NATIVE_REPLAY_BIN="$native_replay"
  export CODETRACER_CT_NATIVE_REPLAY_CMD="$native_replay"
  export CODETRACER_CT_MCR_CMD="$ct_mcr"
  export PATH="$mcr_path_dir:$native_backend/target/debug:$PATH"
  export DYLD_LIBRARY_PATH="$LLDB_LIB_PATH${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"

  cd src/db-backend
  lock_backup="$(mktemp "${TMPDIR:-/tmp}/codetracer-m3-cargo-lock.XXXXXX")"
  cp Cargo.lock "$lock_backup"
  cargo test --offline --no-default-features --features io-transport,syntax-highlight \
    --test reprobuild_hcr_mcr_dap_test -- --nocapture

test-reprobuild-hcr-in-codetracer: ensure-ct-mcr ensure-ct-native-replay
  #!/usr/bin/env bash
  set -euo pipefail

  # Platform precondition is an honest SKIP, not a hard error.
  if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "SKIP: test-reprobuild-hcr-in-codetracer requires macOS arm64 direct HCR ($(uname -s) $(uname -m))." >&2
    exit 0
  fi

  if ! command -v repro >/dev/null 2>&1; then
    echo "SKIP: repro not on PATH (run inside the CodeTracer Nix dev shell)." >&2
    exit 0
  fi

  repo_root="$(git rev-parse --show-toplevel)"

  resolve_sibling_repo() {
    local repo_name="$1"
    local override_var="$2"
    local sibling_var="$3"
    local override_value="${!override_var:-}"
    local sibling_value="${!sibling_var:-}"

    if [ -n "$override_value" ]; then
      printf '%s\n' "$override_value"
      return 0
    fi
    if [ -n "$sibling_value" ]; then
      printf '%s\n' "$sibling_value"
      return 0
    fi
    if [ -d "$repo_root/../$repo_name" ]; then
      (cd "$repo_root/../$repo_name" && pwd)
      return 0
    fi
    if [ -d "$repo_root/../../$repo_name" ]; then
      (cd "$repo_root/../../$repo_name" && pwd)
      return 0
    fi

    printf '%s\n' "$repo_root/../$repo_name"
  }

  # --- Reprobuild source tree --- honest-SKIP when absent (not exit 1).
  reprobuild_root="${CODETRACER_REPROBUILD_REPO_PATH:-}"
  if [ -z "$reprobuild_root" ] && [ -n "${REPROBUILD_SOURCE_ROOT:-}" ] && [[ "$REPROBUILD_SOURCE_ROOT" != /nix/store/* ]]; then
    reprobuild_root="$REPROBUILD_SOURCE_ROOT"
  fi
  if [ -z "$reprobuild_root" ]; then
    reprobuild_root="$(resolve_sibling_repo reprobuild CODETRACER_REPROBUILD_REPO_PATH CT_REPROBUILD_SIBLING)"
  fi
  if [ ! -d "$reprobuild_root/libs/repro_hcr_agent" ]; then
    echo "SKIP: reprobuild sibling not detected (set CT_REPROBUILD_SIBLING / CODETRACER_REPROBUILD_REPO_PATH or check it out at \$METACRAFT_ROOT/reprobuild; looked at $reprobuild_root)." >&2
    exit 0
  fi
  export REPROBUILD_SOURCE_ROOT="$reprobuild_root"
  export CODETRACER_REPROBUILD_REPO_PATH="${CODETRACER_REPROBUILD_REPO_PATH:-$reprobuild_root}"

  # --- ct-native-replay (built on demand by ensure-ct-native-replay) ---
  native_backend="$(resolve_sibling_repo codetracer-native-backend CODETRACER_NATIVE_BACKEND_REPO_PATH CT_CODETRACER_NATIVE_BACKEND_SIBLING)"
  if [ ! -d "$native_backend" ]; then
    echo "SKIP: codetracer-native-backend sibling not detected (set CT_CODETRACER_NATIVE_BACKEND_SIBLING / CODETRACER_NATIVE_BACKEND_REPO_PATH or check it out at \$METACRAFT_ROOT/codetracer-native-backend)." >&2
    exit 0
  fi
  if [ "$(uname -s)" = "Darwin" ] && [ -z "${CT_NATIVE_REPLAY_PATH:-}" ] && [ -z "${CT_NATIVE_REPLAY_BIN:-}" ] && [ -z "${CODETRACER_CT_NATIVE_REPLAY_CMD:-}" ] && [ -x "$native_backend/target/debug/ct-native-replay" ]; then
    (cd "$native_backend" && just sign-macos-binary)
  fi
  if [ -z "${CT_NATIVE_REPLAY_PATH:-}" ] && [ -z "${CT_NATIVE_REPLAY_BIN:-}" ] && [ -z "${CODETRACER_CT_NATIVE_REPLAY_CMD:-}" ] && [ -x "$native_backend/target/debug/ct-native-replay" ]; then
    export CT_NATIVE_REPLAY_PATH="$native_backend/target/debug/ct-native-replay"
    export CT_NATIVE_REPLAY_BIN="$CT_NATIVE_REPLAY_PATH"
    export CODETRACER_CT_NATIVE_REPLAY_CMD="$CT_NATIVE_REPLAY_PATH"
  fi

  # --- ct-mcr (built on demand by ensure-ct-mcr) ---
  native_recorder="$(resolve_sibling_repo codetracer-native-recorder CODETRACER_NATIVE_RECORDER_REPO_PATH CT_CODETRACER_NATIVE_RECORDER_SIBLING)"
  if [ ! -d "$native_recorder" ]; then
    echo "SKIP: codetracer-native-recorder sibling not detected (set CT_CODETRACER_NATIVE_RECORDER_SIBLING / CODETRACER_NATIVE_RECORDER_REPO_PATH or check it out at \$METACRAFT_ROOT/codetracer-native-recorder)." >&2
    exit 0
  fi
  if [ -z "${CODETRACER_CT_MCR_CMD:-}" ] && [ "$(uname -s)" = "Darwin" ] && [ -x "$native_recorder/ct_cli/ct_cli-debug" ]; then
    export CODETRACER_CT_MCR_CMD="$native_recorder/ct_cli/ct_cli-debug"
  fi
  if [ -z "${CODETRACER_CT_MCR_CMD:-}" ] && [ -x "$native_recorder/ct_cli/ct_cli" ]; then
    export CODETRACER_CT_MCR_CMD="$native_recorder/ct_cli/ct_cli"
  fi
  if [ -z "${LLDB_LIB_PATH:-}" ]; then
    for candidate in /nix/store/*lldb*/lib; do
      if [ -e "$candidate/liblldb.dylib" ]; then
        export LLDB_LIB_PATH="$candidate"
        break
      fi
    done
  fi
  if [ -n "${LLDB_LIB_PATH:-}" ]; then
    export DYLD_LIBRARY_PATH="$LLDB_LIB_PATH${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
  fi

  # Build the ct binary on demand only once all preconditions are satisfied,
  # so a platform/sibling SKIP above exits cleanly without an expensive build.
  just build-once

  ct_bin="$repo_root/src/build-debug/bin/ct"
  if [ ! -x "$ct_bin" ]; then
    echo "Error: CodeTracer build did not produce executable ct at $ct_bin" >&2
    exit 1
  fi
  export PATH="$repo_root/src/build-debug/bin:$PATH"

  cd src/db-backend
  cargo test --offline --no-default-features --features io-transport,syntax-highlight \
    --test reprobuild_hcr_in_codetracer_test -- --nocapture

# End-to-end HMR test against the actual ct binary. Requires
# `just build` (or `just build-once`) to have produced the
# HMR-enabled renderer at src/build-debug/bin/ct. Tests:
#   - JS-bundle hot reload by directly mutating ui.js
#   - CSS LiveReload by directly mutating loader.css
#   - No full-page navigation across a JS reload
#
# Uses an Xvfb display under Linux/macOS, the native display under
# Windows — same scheme the broader test-gui recipe uses.
test-hmr-e2e:
  #!/usr/bin/env bash
  set -e
  export CODETRACER_ELECTRON_ARGS="${CODETRACER_ELECTRON_ARGS:---no-sandbox --no-zygote --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage}"

  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*|*_NT*)
      cd src/tests/gui && ./node_modules/.bin/playwright test tests/hmr/hmr_views_and_styles.spec.ts
      ;;
    *)
      DISPLAY_NUM=99
      while [ -e "/tmp/.X${DISPLAY_NUM}-lock" ]; do
        DISPLAY_NUM=$((DISPLAY_NUM + 1))
      done
      Xvfb ":${DISPLAY_NUM}" -screen 0 1920x1080x24 -nolisten tcp &
      XVFB_PID=$!
      trap "kill $XVFB_PID 2>/dev/null || true" EXIT
      sleep 1
      export DISPLAY=":${DISPLAY_NUM}"
      cd src/tests/gui && ./node_modules/.bin/playwright test tests/hmr/hmr_views_and_styles.spec.ts
      ;;
  esac

build-storybook-components:
  mkdir -p storybook/dist
  nim \
    -d:chronicles_enabled=off \
    -d:ctRenderer \
    --path:../nim-everywhere/src \
    --hints:off \
    --out:storybook/dist/components.js \
    js src/frontend/storybook_components.nim

storybook: build-storybook-components
  cd storybook && npm run storybook

storybook-build: build-storybook-components
  chmod -R u+w storybook/storybook-static 2>/dev/null || true
  rm -rf storybook/storybook-static
  cd storybook && npm run build-storybook

storybook-check-styles:
  cd storybook && npm run check-styles

ensure-storybook-static *args:
  #!/usr/bin/env bash
  set -euo pipefail
  set -- {{args}}

  needs_storybook=0
  if [ "$#" -eq 0 ]; then
    needs_storybook=1
  fi

  for arg in "$@"; do
    case "$arg" in
      *storybook*)
        needs_storybook=1
        ;;
    esac

    target=""
    if [ -e "$arg" ]; then
      target="$arg"
    elif [ -e "src/tests/gui/$arg" ]; then
      target="src/tests/gui/$arg"
    fi

    if [ -d "$target" ] && find "$target" -name '*storybook*.spec.ts' -print -quit | grep -q .; then
      needs_storybook=1
    fi
  done

  if [ "$needs_storybook" -eq 1 ]; then
    just storybook-build
  fi

serve-docs hostname="localhost" port="3000":
  #!/usr/bin/env bash
  cd docs/book/
  mdbook serve --hostname {{hostname}} --port {{port}}

build-deb-package file_sizes_report="false":
  #!/usr/bin/env bash
  # https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-bundle.html
  # TODO: We should pin the revison of the bundlers repo by adding it to our
  #       development flake.
  nix bundle --bundler github:NixOS/bundlers#toDEB --print-build-logs ".?submodules=1#codetracer"

  # TODO Can we change this and use in the command above?
  # `nix bundle` doesn't seem to have parameters controlling this and right now
  # it selects these names by default. The appearance of the version number in
  # the filename is particularly problematic because it means that this script
  # will be broken after each upgrade.
  OUT_DIR=deb-single-codetracer-bin-codetracer/
  DEB_PACKAGE_NAME=codetracer-bin-codetracer_1.0_amd64.deb

  if [[ "{{file_sizes_report}}" == "true" ]]; then
    REPORT_FILE="codetracer-deb-file-sizes-report.txt"
    echo Generating file sizes report...
    dpkg -c $OUT_DIR/$DEB_PACKAGE_NAME > "$REPORT_FILE"
    echo $REPORT_FILE written!
    echo You can load the produced file in Excel/LibreOffice by treating it as a fixed-width CSV file.
  fi

build-nix-app-image:
  #!/usr/bin/env bash
  # https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-bundle.html
  # TODO: We should pin the revison of the bundlers repo by adding it to our
  #       development flake.
  nix bundle --bundler github:ralismark/nix-appimage --print-build-logs ".?submodules=1#codetracer"

build-macos-app:
  bash non-nix-build/build.sh

build-dmg:
  CODETRACER_REPROBUILD_TARGET=.#dmg bash scripts/build-once.sh

build-app-image:
  ./appimage-scripts/build_appimage.sh


# Run all Rust tests (db-backend unit + integration, backend-manager).
test-rust:
  #!/usr/bin/env bash
  set -e
  pushd src/db-backend
  # Unit tests (inside the binary)
  cargo nextest run --release --bin replay-server
  # Run ignored unit tests separately.  When the binary happens to
  # have no #[ignore]'d tests at all, nextest exits with code 4
  # ("no tests to run") which we don't want to surface as a failure
  # of the whole ``just test`` invocation.  Tolerate that specific
  # exit code while still failing on any real test failure.
  cargo nextest run --release --bin replay-server --run-ignored ignored-only || \
    if [ "$?" = "4" ]; then \
      echo "  (no ignored tests in replay-server; treating as no-op)"; \
    else \
      exit "$?"; \
    fi
  # Integration tests (tests/*.rs): DAP protocol, flow tests, etc.
  # Flow tests that need ct-rr-support/rr skip automatically when unavailable.
  # Shell/JS flow tests require sibling repos (codetracer-shell-recorders, etc.)
  # and are run separately in cross-repo CI jobs.
  cargo nextest run --release --test '*' \
    -E 'not test(~bash_flow_integration) and not test(~zsh_flow_integration) and not test(~javascript_flow_integration)'
  popd
  pushd src/backend-manager
  cargo nextest run --release
  popd

# Run all non-GUI tests.
# test-frontend-js needs npm-installed jsdom (available after tup build, not in bare nix shell).
# test-python-recorder needs a built ct binary.
# Both are skipped here; they run in their own CI steps or via dev builds.
test:
  #!/usr/bin/env bash
  set -e
  just test-rust
  just test-nimsuggest
  if [ -n "${CODETRACER_RR_BACKEND_PATH:-}" ]; then
    echo "codetracer-rr-backend detected — running cross-repo tests..."
    just cross-test
  else
    echo "CODETRACER_RR_BACKEND_PATH not set — skipping cross-repo tests"
  fi

# Run all GUI tests headlessly against an already-built CodeTracer binary.
test-gui-prebuilt *args:
  #!/usr/bin/env bash
  set -e
  export CODETRACER_ELECTRON_ARGS="${CODETRACER_ELECTRON_ARGS:---no-sandbox --no-zygote --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage}"

  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*|*_NT*)
      # Windows: no Xvfb needed; Electron uses the native display.
      just test-e2e {{args}}
      ;;
    *)
      # Linux/macOS: start a persistent Xvfb so Playwright/Electron tests have a display.
      DISPLAY_NUM=99
      while [ -e "/tmp/.X${DISPLAY_NUM}-lock" ]; do
        DISPLAY_NUM=$((DISPLAY_NUM + 1))
      done
      Xvfb ":${DISPLAY_NUM}" -screen 0 1920x1080x24 -nolisten tcp &
      XVFB_PID=$!
      trap "kill $XVFB_PID 2>/dev/null || true" EXIT
      sleep 1
      export DISPLAY=":${DISPLAY_NUM}"

      just test-e2e {{args}}
      ;;
  esac

# Run all GUI tests headlessly (TypeScript Playwright e2e suite).
# On Linux, uses a virtual display (Xvfb) — same as CI.
# On Windows, no virtual display is needed; Electron runs natively.
# For visible windows on your desktop, use `just test-gui-visible` instead.
#
# `build-once` runs as a prereq so the rebuilt frontend + replay-server are
# fresh before tests launch — without this, db-backend / Nim frontend / Tup
# changes that haven't been compiled silently produce stale-binary test
# failures (see task #317 + the May 19→20 staleness incident that produced
# the "ct-mcr binary not found" Cluster B failure).
test-gui *args: build-once build-siblings
  just test-gui-prebuilt {{args}}

# Run GUI tests with windows visible on the current desktop session.
# On Linux, requires a running display server ($DISPLAY must be set).
# On Windows, always works (no $DISPLAY needed).
# `build-once` is a prereq for the same reason as `test-gui` (task #317).
test-gui-visible *args: build-once build-siblings
  #!/usr/bin/env bash
  set -e
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*|*_NT*)
      # Windows: no DISPLAY check needed.
      ;;
    *)
      if [ -z "${DISPLAY:-}" ]; then
        echo "Error: \$DISPLAY is not set. Run this from a desktop session." >&2
        exit 1
      fi
      ;;
  esac
  just test-e2e {{args}}

# Run the MCR visual replay regression gate used by CI.
test-visual-replay-gate:
  bash ci/test/visual-replay-gate.sh

# Run the M16 ct-test provider matrix and release-gate checks.
test-m16-release-gate:
  bash ci/test/m16-release-gate.sh

# Run the cross-language ct-test provider suites (C/C++ GoogleTest/Catch2/CTest,
# M11 native, M12 fallback, JavaScript, Ruby) plus the framework gate tests.
# First builds the native/js/ruby recorder siblings in their own pinned dev
# shells (`direnv exec <repo> just build`, via scripts/build-siblings.sh) so the
# recording tests run against real recorders — a missing/failed required sibling
# fails loudly rather than skipping. Set CT_PROVIDERS_SKIP_SIBLINGS=1 to reuse
# already-built recorders. Run from inside the dev shell (it provides nim plus
# the gtest/catch2/cmake/ninja toolchain and CMAKE_PREFIX_PATH / CT_TEST_C{C,XX}
# the C/C++ providers need). See ci/test/ct-providers.sh.
test-ct-providers:
  bash ci/test/ct-providers.sh

make-quick-mr name message:
  # EXPECTS changes to be manually added with `git add`
  # before running!
  git checkout -b {{name}} || true # ok if already existing
  git commit -m "{{message}}"
  git push -u origin {{name}} -o merge_request.create -o merge_request.target=master
  # if we decide to use glab
  # https://docs.gitlab.com/ee/integration/glab/
  # glab mr create -t "{{message}}" --description "" --web

findtmp:
  #!/usr/bin/env bash
  if [ "$(uname)" = "Darwin" ]; then
    echo "$HOME/Library/Caches/com.codetracer.CodeTracer"
  else
    # Works on both Linux (/tmp) and Windows (uses $TEMP/$TMP env vars)
    echo "${TEMP:-${TMP:-${TEMPDIR:-${TMPDIR:-/tmp}}}}/codetracer"
  fi

clean-logs:
  #!/usr/bin/env bash
  TTMP=$(just findtmp) ; \
  rm -rf $TTMP/

archive-logs pid_or_current_or_last:
  #!/usr/bin/env bash
  TTMP=$(just findtmp) ; \
  export pid=$(just pid {{pid_or_current_or_last}}) ; \
  zip -r codetracer-logs-{{pid_or_current_or_last}}.zip $TTMP/run-${pid}

log-file pid_or_current_or_last kind process="default" instance_index="0":
  #!/usr/bin/env bash
  # first argument can be either `current`, `last` or a pid number
  # `kind` can be one of
  #   task_process, scripts, index, rr_gdb_raw or dispatcher
  if [[ "{{kind}}" == "dispatcher" ]]; then \
    export ext="log"; \
  elif [[ "{{kind}}" == "task_process" ]]; then \
    export ext="log"; \
  elif [[ "{{kind}}" == "scripts" ]]; then \
    export ext="log"; \
  elif [[ "{{kind}}" == "index" ]]; then \
    export ext="log"; \
  elif [[ "{{kind}}" == "frontend" ]]; then \
    export ext="log"; \
  elif [[ "{{kind}}" == "virtualization" ]]; then \
    export ext="log"; \
  elif [[ "{{kind}}" == "db-backend" ]]; then \
    export ext="log"; \
  else \
    export ext="txt"; \
  fi; \
  if [[ "{{process}}" == "default" ]]; then \
    export actual_process={{kind}}; \
  else \
    export actual_process={{process}}; \
  fi; \
  export pid=$(just pid {{pid_or_current_or_last}}); \
  TTMP=$(just findtmp) ; \
  if [[ "{{kind}}" == "workers" ]]; then \
    echo "$TTMP/run-${pid}/processes.txt"; \
  else \
    echo "$TTMP/run-${pid}/{{kind}}_${actual_process}_{{instance_index}}.${ext}"; \
  fi;

# expected `run_name_or_last` as `run-<run-pid>` or `last`
log name="ct-rr-support" worker_kind="stable" index="0" codetracer_tmp_dir="" run_name_or_last="last":
  #!/usr/bin/env bash
  if [ "{{codetracer_tmp_dir}}" == "" ]; then
    tmpdir=$(just findtmp)
  else
    tmpdir={{codetracer_tmp_dir}}
  fi

  cat $tmpdir/{{run_name_or_last}}/{{name}}-{{worker_kind}}-{{index}}.log

# expected `run_name_or_last` as `run-<run-pid>` or `last`
log-db-backend codetracer_tmp_dir="" run_name_or_last="last":
  #!/usr/bin/env bash
  if [ "{{codetracer_tmp_dir}}" == "" ]; then
    tmpdir=$(just findtmp)
  else
    tmpdir={{codetracer_tmp_dir}}
  fi

  cat $tmpdir/{{run_name_or_last}}/db-backend.log

# old version in vim:
#
# log pid_or_current_or_last kind process="default" instance_index="0":
#   export log_file_path=$(just log-file {{pid_or_current_or_last}} {{kind}} {{process}} {{instance_index}}); \
#   vim \
#     -c ":term ++open cat ${log_file_path}" \
#     -c "wincmd j" -c "q"
#   # (move to non-terminal pane down and close it)

tail pid_or_current_or_last kind process="default" instance_index="0":
  export log_file_path=$(just log-file {{pid_or_current_or_last}} {{kind}} {{process}} {{instance_index}}); \
  tail -f ${log_file_path}

build-nix:
  nix build --print-build-logs '.?submodules=1#codetracer' --show-trace --keep-failed

attic-push-nix-package:
  attic push ${ATTIC_CACHE:?} $(nix build --print-out-paths ".?submodules=1#codetracer")

attic-push-devshell:
  attic push ${ATTIC_CACHE:?} $(nix build --print-out-paths .#devShells.x86_64-linux.default)

reset-db:
  rm -rf ~/.local/share/codetracer/trace_index.db

clear-local-traces:
  rm -rf ~/.local/share/codetracer

pid pid_or_current_or_last:
  #!/usr/bin/env bash
  # argument can be either `current`, `last` or a pid number
  if [[ "{{pid_or_current_or_last}}" == "current" ]]; then \
    echo $(ps aux | grep src/build-debug/codetracer | head -n 1 | awk '{print $2}') ; \
  elif [[ "{{pid_or_current_or_last}}" == "last" ]]; then \
    TTMP=$(just findtmp) ; \
    echo $(cat $TTMP/last-start-pid) ; \
  else \
    echo {{pid_or_current_or_last}} ; \
  fi

log-task pid_or_current_or_last task-id:
  # argument can be either `current`, `last` or a pid number
  export pid=$(just pid {{pid_or_current_or_last}}) ; \
  python3 src/tools/log_task.py ${pid} {{task-id}}

log-event pid_or_current_or_last event-id:
  #!/usr/bin/env bash
  # argument can be either `current`, `last` or a pid number
  export pid=$(just pid {{pid_or_current_or_last}}) ; \
  TTMP=$(just findtmp) ; \
  cat $TTMP/run-${pid}/events/{{event-id}}.json

log-result pid_or_current_or_last task-id:
  #!/usr/bin/env bash
  # argument can be either `current`, `last` or a pid number
  export pid=$(just pid {{pid_or_current_or_last}}) ; \
  TTMP=$(just findtmp) ; \
  cat $TTMP/run-${pid}/results/{{task-id}}.json

log-args pid_or_current_or_last task-id:
  #!/usr/bin/env bash
  # argument can be either `current`, `last` or a pid number
  export pid=$(just pid {{pid_or_current_or_last}}) ; \
  TTMP=$(just findtmp) ; \
  cat $TTMP/run-${pid}/args/{{task-id}}.json


# " (artiffical comment to fix syntax highlighting)

test-valid-trace trace_dir:
  cd src/db-backend && \
    env CODETRACER_VALID_TEST_TRACE_DIR={{trace_dir}} cargo nextest run test_valid_trace
# no need to cd back: i assume and manual use shows
# just probably runs this in a subshell(or at least it doesn't seem to affect
# our callsite)

stop:
  killall -9 virtualization-layers db-backend node .electron-wrapped || true
  killall -9 electron || true
  killall -9 backend-manager || true
  killall -9 ct-rr-support || true

reset-config:
  rm --force  ~/.config/codetracer/.config.yaml && \
    mkdir -p ~/.config/codetracer/ && \
    cp -r src/config/default_config.yaml ~/.config/codetracer/.config.yaml

reset-layout:
  rm --force  ~/.config/codetracer/default_layout.json && \
    mkdir -p ~/.config/codetracer/ && \
    cp -r src/config/default_layout.json ~/.config/codetracer/default_layout.json

# originally by Pavel/Dimo in ci.sh
test-nimsuggest:
  #!/usr/bin/env bash
  if echo quit | nimsuggest --v4 src/lsp.nim; then
    echo "OK: nimsuggest starts without an error for src/lsp.nim"
  else
    echo "ERROR: nimsuggest NOT WORKING for src/lsp.nim"
    echo "  suggestion: often this is because of adding chronicles log statements"
    echo "    with distinct types, or maybe object containing distinct types"
    echo "      like \`debug \"message\", taskId\`"
    echo "    or other kinds of problems with args"
    echo "    --"
    echo "    changing to \`taskId=taskId.string\` seems to be a workaround"
    echo "    if it's an object, changing to \`obj=obj.repr\` seems to maybe help"
    exit 1
  fi

# BPF monitor unit tests — exercises JSON parsing, timestamp conversion,
# and event accumulation without needing bpftrace or root access.
test-bpf-monitor:
  nim c -r --hints:off --warnings:off -d:ssl -d:useOpenssl3 --mm:refc --nimcache:/tmp/ct-nim-cache/bpf_monitor_test src/ct/ci/bpf_monitor_test.nim

# BPF integration tests — requires a capabilities-aware bpftrace binary
# and the bpftrace-collection.bt script from the codetracer-ci sibling repo.
# Skips gracefully if prerequisites are not met.
# Run `just developer-setup` first to set up bpftrace capabilities.
#
# NOTE: bpftrace 0.24.x has a hardcoded geteuid()==0 check, so these tests
# require either passwordless sudo or a patched bpftrace build. They will
# skip with a diagnostic message when the prerequisite is not met.
test-bpf-integration:
  nim c -r --hints:off --warnings:off -d:ssl -d:useOpenssl3 --mm:refc --nimcache:/tmp/ct-nim-cache/bpf_integration_test src/ct/ci/bpf_integration_test.nim

# Grant BPF capabilities to the ct binary after (re)compilation.
# Requires the sudoers rule installed by `just developer-setup`.
# Silently skips if the sudoers rule is not present or if not on Linux.
setcap-bpf:
  #!/usr/bin/env bash
  set -euo pipefail
  if [ "$(uname)" != "Linux" ]; then
    exit 0
  fi
  CT_BIN="$(pwd)/src/build-debug/bin/ct"
  if [ ! -f "$CT_BIN" ]; then
    exit 0
  fi
  # codetracer-setcap is a single-purpose helper installed by the NixOS
  # developer-bpf module. It runs setcap with hardcoded caps on the ct binary.
  if ! command -v codetracer-setcap &>/dev/null; then
    echo "Note: codetracer-setcap not found — run 'just developer-setup' or import the NixOS module." >&2
    exit 0
  fi
  # sudo -n = non-interactive (fails immediately if password is needed).
  # Resolve to the full Nix store path — sudo matches the sudoers rule
  # against the real path, not the /run/current-system/sw/bin symlink.
  SETCAP_REAL="$(readlink -f "$(command -v codetracer-setcap)")"
  if sudo -n "$SETCAP_REAL" 2>/dev/null; then
    echo "BPF capabilities set on $CT_BIN"
  else
    echo "Note: passwordless setcap not available — run 'just developer-setup' to enable." >&2
  fi

# Build BPF programs from C source to .bpf.o ELF objects.
# Requires clang and libbpf headers (both available in the Nix dev shell).
build-bpf-programs:
  #!/usr/bin/env bash
  set -euo pipefail
  LIBBPF_PATH=$(nix build nixpkgs#libbpf --no-link --print-out-paths 2>/dev/null)
  mkdir -p src/build-debug/share
  clang -target bpf -D__TARGET_ARCH_x86 \
    -I src/bpf-monitor -I "$LIBBPF_PATH/include" \
    -O2 -g \
    -c src/bpf-monitor/monitor.bpf.c \
    -o src/build-debug/share/monitor.bpf.o
  echo "Built src/build-debug/share/monitor.bpf.o"

# Native BPF monitor unit tests — exercises ring buffer event processing,
# struct layout verification, and environment deduplication without BPF.
test-bpf-native:
  #!/usr/bin/env bash
  set -euo pipefail
  LIBBPF_PATH=$(nix build nixpkgs#libbpf --no-link --print-out-paths 2>/dev/null)
  nim c -r --hints:off --warnings:off -d:ssl -d:useOpenssl3 --mm:refc \
    --passC:"-I$LIBBPF_PATH/include" \
    --passL:"-L$LIBBPF_PATH/lib" --passL:"-lbpf" --passL:"-lelf" --passL:"-lz" \
    --nimcache:/tmp/ct-nim-cache/bpf_monitor_native_test \
    src/ct/ci/bpf_monitor_native_test.nim

# Native BPF E2E integration tests — drives the ct binary with
# --monitor-processes and verifies that BPF monitoring starts, captures
# process events, and reports them to a mock CI backend.
# Requires: build-once + build-bpf-programs + developer-setup.
# The test binary does NOT need BPF caps — it spawns the ct binary which
# already has them from the tup build rule or `just setcap-bpf`.
test-bpf-native-integration:
  #!/usr/bin/env bash
  set -euo pipefail
  nim c --hints:off --warnings:off --mm:refc \
    --nimcache:/tmp/ct-nim-cache/bpf_native_integration_test \
    src/ct/ci/bpf_native_integration_test.nim
  LD_LIBRARY_PATH="${CT_LD_LIBRARY_PATH:-${CODETRACER_LD_LIBRARY_PATH:-}}" \
    src/ct/ci/bpf_native_integration_test

# Run all BPF-related tests (unit + native + integration).
test-bpf: test-bpf-monitor test-bpf-native test-bpf-native-integration test-bpf-integration

# ===========================
# trace folder helpers

trace-folder program_pattern:
  ct trace-metadata --program={{program_pattern}} | jq --raw-output .outputFolder # no quotes around string, important for tree

trace-folder-for-id trace_id:
  ct trace-metadata --id={{trace_id}} | jq --raw-output .outputFolder # no quotes around string, important for tree

tree-trace-folder program_pattern:
  tree $(just trace-folder {{program_pattern}})

tree-trace-folder-for-id trace_id:
  tree $(just trace-folder-for-id {{trace_id}})

ls-trace-folder program_pattern:
  ls -alh $(just trace-folder {{program_pattern}})

ls-trace-folder-for-id trace_id:
  ls -alh $(just trace-folder-for-id {{trace_id}})

# we can't have a `just cd..` command, as just recipes seem to run as child processes,
# so they can't change the current directory
# https://github.com/casey/just/issues/1261#issuecomment-1177155928

# end of trace folder helpers
# ===========================

# ====
# e2e helpers

test-frontend-js:
  #!/usr/bin/env bash
  set -e
  echo "Running Nim language definition tests..."
  node src/frontend/tests/nimLanguage.test.mjs
  echo ""
  echo "Running Nim tokenizer pattern tests..."
  node src/frontend/tests/nimTokenizer.test.mjs
  echo ""
  echo "Running Nim Monarch grammar compilation tests..."
  node src/frontend/tests/nimMonarchDirect.test.mjs
  echo ""
  echo "Running Nim Monaco integration tests (real tokenizer)..."
  node --experimental-loader ./src/frontend/tests/css-loader.mjs src/frontend/tests/nimMonacoTokenizer.test.mjs 2>&1 | grep -v "ExperimentalWarning"

test-e2e *args:
  #!/usr/bin/env bash
  set -e
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*|*_NT*|Darwin)
      # Windows and macOS: no DISPLAY needed.
      ;;
    *)
      if [ -z "${DISPLAY:-}" ]; then
        echo "Error: \$DISPLAY is not set. Electron tests require a display server." >&2
        echo "Use 'just test-gui' to run under Xvfb, or 'just test-gui-visible' from a desktop session." >&2
        exit 1
      fi
      ;;
  esac
  just ensure-storybook-static {{args}}
  cd "${CODETRACER_REPO_ROOT_PATH}/src/tests/gui" && \
    npm install --no-audit --no-fund && \
    env CODETRACER_DEV_TOOLS=0 npx playwright test --workers=1 \
      {{args}}

dev-tools-test-e2e *args:
  cd ${CODETRACER_REPO_ROOT_PATH}/src/tests/gui && \
    env CODETRACER_DEV_TOOLS=1 npx playwright test --workers=1 \
      {{args}}

# Show accumulated test timing statistics.
test-stats *args:
  cd "${CODETRACER_REPO_ROOT_PATH}/src/tests/gui" && \
    node scripts/analyze-stats.mjs {{args}}

# Delete all accumulated test stats.
test-stats-reset:
  rm -rf "${CODETRACER_REPO_ROOT_PATH}/src/tests/gui/test-stats"

# ====
# Python recorder tests

test-python-recorder:
  ./ci/test/python-recorder-smoke.sh

# Run CLI record smoke tests for all supported languages.
# Exercises the full `ct record` code path (language detection → recorder
# dispatch → trace import) to catch PATH, format, and dispatch regressions.
# Pass language names to test a subset: just test-record-smoke ruby python
test-record-smoke *args:
  ./ci/test/cli-record-smoke.sh {{args}}

# ====
# Nim flow/omniscience integration tests
# Tests the db-backend's ability to resolve Nim global variables using mangled names
#
# Uses scripts/with-nim-* wrappers which can be chained with other language wrappers:
#   scripts/with-nim-1.6 scripts/with-rust-1.80 cargo nextest run ...

# Test with Nim 1.6.x (uses ROT13 mangling)
test-nim-flow-1_6:
  #!/usr/bin/env bash
  set -e
  echo "Testing Nim flow integration with Nim 1.6..."
  ./scripts/with-nim-1.6 nim --version
  cd src/db-backend
  ../../scripts/with-nim-1.6 cargo nextest run --no-capture test_nim_flow
  echo "Nim 1.6 flow test passed!"

# Test with Nim 2.0.x (uses direct mangling, no ROT13)
test-nim-flow-2_0:
  #!/usr/bin/env bash
  set -e
  echo "Testing Nim flow integration with Nim 2.0..."
  ./scripts/with-nim-2.0 nim --version
  cd src/db-backend
  ../../scripts/with-nim-2.0 cargo nextest run --no-capture test_nim_flow
  echo "Nim 2.0 flow test passed!"

# Test with Nim 2.2.x (uses direct mangling, no ROT13)
test-nim-flow-2_2:
  #!/usr/bin/env bash
  set -e
  echo "Testing Nim flow integration with Nim 2.2..."
  ./scripts/with-nim-2.2 nim --version
  cd src/db-backend
  ../../scripts/with-nim-2.2 cargo nextest run --no-capture test_nim_flow
  echo "Nim 2.2 flow test passed!"

# Test with all Nim versions
test-nim-flow-all:
  #!/usr/bin/env bash
  set -e
  echo "========================================"
  echo "Testing Nim flow with all Nim versions"
  echo "========================================"
  echo ""
  just test-nim-flow-1_6
  echo ""
  echo "----------------------------------------"
  echo ""
  just test-nim-flow-2_0
  echo ""
  echo "----------------------------------------"
  echo ""
  just test-nim-flow-2_2
  echo ""
  echo "========================================"
  echo "All Nim flow tests passed!"
  echo "========================================"

# ====
# Rust flow/omniscience integration tests
# Tests the db-backend's ability to load Rust local variables
#
# Note: db-backend requires Rust edition 2024 support, so older Rust versions
# won't work. Use scripts/with-rust-* wrappers which can be chained with other
# language wrappers for future multi-language testing.

# Test with current Rust (from environment)
test-rust-flow:
  #!/usr/bin/env bash
  set -e
  echo "Testing Rust flow integration..."
  rustc --version
  cd src/db-backend
  cargo nextest run --no-capture test_rust_flow
  echo "Rust flow test passed!"

# Test with Rust stable (via nix)
test-rust-flow-stable:
  #!/usr/bin/env bash
  set -e
  echo "Testing Rust flow integration with Rust stable..."
  ./scripts/with-rust-stable rustc --version
  cd src/db-backend
  ../../scripts/with-rust-stable cargo nextest run --no-capture test_rust_flow
  echo "Rust stable flow test passed!"

# Test with Rust nightly (via nix)
test-rust-flow-nightly:
  #!/usr/bin/env bash
  set -e
  echo "Testing Rust flow integration with Rust nightly..."
  ./scripts/with-rust-nightly rustc --version
  cd src/db-backend
  ../../scripts/with-rust-nightly cargo nextest run --no-capture test_rust_flow
  echo "Rust nightly flow test passed!"

# Test with all supported Rust versions
test-rust-flow-all:
  #!/usr/bin/env bash
  set -e
  echo "========================================"
  echo "Testing Rust flow with supported versions"
  echo "========================================"
  echo ""
  just test-rust-flow-stable
  echo ""
  echo "========================================"
  echo "All Rust flow tests passed!"
  echo "========================================"

# ====
# Python flow/omniscience integration test (DB-based, no rr required)
test-python-flow:
  #!/usr/bin/env bash
  set -e
  echo "Running Python flow integration test..."
  cd src/db-backend && cargo nextest run --no-capture test_python_flow
  echo "Python flow test passed!"

# Ruby flow/omniscience integration test (DB-based, no rr required)
test-ruby-flow:
  #!/usr/bin/env bash
  set -e
  echo "Running Ruby flow integration test..."
  cd src/db-backend && cargo nextest run --no-capture test_ruby_flow
  echo "Ruby flow test passed!"

# Value Origin Tracking per-language headless DAP tests on materialized
# traces (M3 of the Value Origin Tracking milestones).
#
# Each language's test file drives the real recorder against the M0
# fixture programs and asserts the per-hop chain shape against the
# per-fixture ANSWERS.md.
#
# The CT_TEST_LANGS environment variable filters which language test
# files are exercised. Accepts a comma-separated allowlist (case
# insensitive); unset or "all" runs every language.
#
# Examples:
#   CT_TEST_LANGS=python  just test-origin-dap
#   CT_TEST_LANGS=python,ruby just test-origin-dap
#   CT_TEST_LANGS=all just test-origin-dap   # same as unset
#
# Tests skip cleanly when the per-language recorder isn't on PATH; M3
# CI runs against an image with every recorder present.
test-origin-dap:
  #!/usr/bin/env bash
  set -euo pipefail
  echo "Running Value Origin Tracking per-language DAP tests..."
  langs="${CT_TEST_LANGS:-all}"
  langs_lower="$(echo "$langs" | tr '[:upper:]' '[:lower:]')"
  want_python=0; want_ruby=0; want_javascript=0
  if [ "$langs_lower" = "all" ] || [ -z "$langs_lower" ]; then
    want_python=1; want_ruby=1; want_javascript=1
  else
    IFS=',' read -ra parts <<< "$langs_lower"
    for p in "${parts[@]}"; do
      case "$(echo "$p" | xargs)" in
        python|py)            want_python=1 ;;
        ruby|rb)              want_ruby=1 ;;
        javascript|js|node)   want_javascript=1 ;;
        "")                   ;;
        *) echo "WARNING: ignoring unknown CT_TEST_LANGS value '$p'" ;;
      esac
    done
  fi
  cd src/db-backend
  selected=()
  [ "$want_python" -eq 1 ]     && selected+=(--test origin_python_dap_test)
  [ "$want_ruby" -eq 1 ]       && selected+=(--test origin_ruby_dap_test)
  [ "$want_javascript" -eq 1 ] && selected+=(--test origin_javascript_dap_test)
  if [ ${#selected[@]} -eq 0 ]; then
    echo "No origin-DAP language test files selected by CT_TEST_LANGS='$langs'; nothing to do."
    exit 0
  fi
  echo "Running: cargo test ${selected[*]}"
  cargo test "${selected[@]}" -- --nocapture
  echo "Value Origin Tracking DAP tests passed!"

# M29 cross-process value-origin envelope, per
# `GUI/Test-Scenarios/Cross-Process-Origin-E2E-Test-Design.md` §6 — the
# canonical entrypoint consumed by CI for the cross-process matrix.
#
# Runs the 2-trace DAP suite (Fixture A — Python aiohttp + JS frontend,
# Modes 1 / 3 + parity + terminator regressions), the 3-trace JS ↔ WASM ↔
# backend chain landed under TCT-M3 / TCT-M5 batches 4-5-6
# (`account-balance-with-wasm/` fixture), the 3-trace `ct/listProcesses`
# event regression, and the gated Playwright specs
# `cross-tracer-three-recording.spec.ts` +
# `event-log-correlation-markers-three-trace.spec.ts` when present.
#
# The recipe runs the fixture's `regenerate.sh` first so the three `.ct`
# containers + `session.toml` are materialised. `regenerate.sh` honest-skips
# with exit 75 when its prereqs (wasm-pack, rustup wasm32 target, codetracer
# CLI, codetracer_python_recorder, browser_stream_receiver, Playwright) are
# missing — in that case the cargo tests themselves skip cleanly via
# `first_missing_trace_container` (see `cross_process_origin_test.rs`). Any
# other regenerator failure is logged as a warning and does not abort the
# envelope, mirroring the per-language origin-DAP skip discipline.
test-cross-process:
  #!/usr/bin/env bash
  set -euo pipefail
  echo "=== M29 cross-process value-origin envelope ==="

  fixture_dir="src/db-backend/tests/fixtures/cross_process/account-balance-with-wasm"
  regenerate_script="$fixture_dir/regenerate.sh"
  fixture_ready=1
  for ct in frontend.ct frontend-wasm.ct backend.ct session.toml; do
    if [ ! -e "$fixture_dir/$ct" ]; then
      fixture_ready=0
      break
    fi
  done

  if [ "$fixture_ready" -eq 0 ]; then
    if [ -x "$regenerate_script" ]; then
      echo "[cross-process] Three-trace fixture not materialised; running regenerate.sh"
      set +e
      bash "$regenerate_script"
      rc=$?
      set -e
      if [ "$rc" -eq 0 ]; then
        echo "[cross-process] regenerate.sh completed."
      elif [ "$rc" -eq 75 ]; then
        echo "[cross-process] WARNING: regenerate.sh honest-skipped (prereqs absent, exit 75)."
        echo "[cross-process] 3-trace cargo tests will self-skip via the missing-container guard."
      else
        echo "[cross-process] WARNING: regenerate.sh exited with $rc; continuing anyway."
        echo "[cross-process] 3-trace cargo tests will self-skip via the missing-container guard."
      fi
    else
      echo "[cross-process] WARNING: regenerate script not executable at $regenerate_script; skipping fixture refresh."
    fi
  else
    echo "[cross-process] Three-trace fixture already materialised; skipping regenerate.sh."
  fi

  pushd src/db-backend >/dev/null

  echo
  echo "[cross-process] Stage 1/3 — 2-trace cross-process DAP suite"
  cargo test --test cross_process_origin_test -- --nocapture \
    test_origin_cross_process_fixture_a_python_aiohttp_mode1 \
    test_origin_cross_process_fixture_a_python_aiohttp_mode3 \
    test_parity_origin_cross_process_fixture_a_python_aiohttp \
    test_origin_cross_process_serialisation_aware_json_collapses_to_trivial_copy \
    test_origin_cross_process_ambiguous_correlation_terminates_cleanly \
    test_origin_cross_process_missing_correlation_terminates_cleanly

  echo
  echo "[cross-process] Stage 2/3 — 3-trace JS ↔ WASM ↔ backend DAP chain"
  cargo test --test cross_process_origin_test -- --nocapture \
    test_origin_three_trace_chain_balance_to_frontend_expression
  cargo test --test dap_server_list_processes_event_test -- --nocapture \
    dap_server_emits_list_processes_for_three_trace_wasm_fixture

  popd >/dev/null

  echo
  echo "[cross-process] Stage 3/3 — Playwright specs (gated, TCT-M5)"
  # The specs skip cleanly via `threeTraceFixtureSkipReason()` when the
  # .ct containers are absent (mirror of the cargo-side
  # `first_missing_trace_container` guard); they still need a display.
  selected_specs=()
  for spec in \
    src/tests/gui/tests/value-origin/cross-tracer-three-recording.spec.ts \
    src/tests/gui/tests/value-origin/event-log-correlation-markers-three-trace.spec.ts; do
    if [ -f "$spec" ]; then
      selected_specs+=("$spec")
    else
      echo "[cross-process] gated spec not present, skipping: $spec"
    fi
  done
  if [ "${#selected_specs[@]}" -eq 0 ]; then
    echo "[cross-process] No 3-trace Playwright specs present yet (TCT-M5 pending)."
  else
    # `test-gui-prebuilt` auto-spawns Xvfb on Linux + uses the native
    # display on macOS/Windows. It assumes the frontend is already
    # built — CI jobs that drive this envelope ensure `build-once` ran.
    case "$(uname -s)" in
      MINGW*|MSYS*|CYGWIN*|*_NT*|Darwin)
        just test-e2e "${selected_specs[@]}" ;;
      *)
        if [ -n "${DISPLAY:-}" ]; then
          just test-e2e "${selected_specs[@]}"
        elif command -v Xvfb >/dev/null 2>&1; then
          just test-gui-prebuilt "${selected_specs[@]}"
        else
          echo "[cross-process] WARNING: no DISPLAY and no Xvfb; skipping Playwright stage."
        fi
        ;;
    esac
  fi

  echo
  echo "=== M29 cross-process value-origin envelope passed ==="

# M29 — one-command demo launcher for the three-trace
# `account-balance-with-wasm` cross-tracer fixture.
#
# This recipe materialises the fixture if absent (delegating to
# `regenerate.sh`, which is honestly gated on wasm-pack + the wasm32
# rustup target + codetracer-python-recorder + codetracer-js-recorder
# + browser_stream_receiver + Playwright) and then hands the
# `session.toml` manifest to `ct replay -t` so the GUI opens the
# three-trace session for manual chain-walking. Mirrors the
# `test-cross-process` envelope's prereq probe but skips the cargo
# / Playwright stages — the goal here is interactive inspection,
# not regression coverage.
#
# Doc page: docs/book/src/usage_guide/cross-tracer-demo.md.
demo-cross-tracer:
  #!/usr/bin/env bash
  set -euo pipefail
  echo "=== M29 cross-tracer demo — account-balance-with-wasm ==="

  fixture_dir="src/db-backend/tests/fixtures/cross_process/account-balance-with-wasm"
  regenerate_script="$fixture_dir/regenerate.sh"
  template="$fixture_dir/session.toml.template"
  session="$fixture_dir/session.toml"

  fixture_ready=1
  for ct in frontend.ct frontend-wasm.ct backend.ct; do
    if [ ! -e "$fixture_dir/$ct" ]; then
      fixture_ready=0
      break
    fi
  done

  if [ "$fixture_ready" -eq 0 ]; then
    if [ ! -x "$regenerate_script" ]; then
      echo "ERROR: regenerate script missing or not executable: $regenerate_script" >&2
      exit 1
    fi
    echo "[demo] Three-trace fixture not materialised; invoking regenerate.sh"
    set +e
    bash "$regenerate_script"
    rc=$?
    set -e
    if [ "$rc" -eq 75 ]; then
      {
        echo "ERROR: cross-tracer demo prerequisites are missing."
        echo
        echo "To materialise the three-trace fixture you need ALL of:"
        echo "  - wasm-pack + 'rustup target add wasm32-unknown-unknown'"
        echo "  - codetracer Python recorder ('codetracer_python_recorder'"
        echo "    importable from python3; ships with the dev shell)"
        echo "  - codetracer-js-recorder host ('browser_stream_receiver' on"
        echo "    PATH; produced by 'just build-once' or the dev shell)"
        echo "  - Playwright ('npm install playwright' in the fixture's"
        echo "    frontend/ dir)"
        echo
        echo "Re-run 'just demo-cross-tracer' once the gaps above are filled."
        echo "The regenerator's stderr above lists each missing dependency"
        echo "individually."
      } >&2
      exit 1
    elif [ "$rc" -ne 0 ]; then
      echo "ERROR: regenerate.sh exited with status $rc; cannot launch demo." >&2
      exit "$rc"
    fi
  else
    echo "[demo] Three-trace fixture already materialised; skipping regenerate.sh."
  fi

  # Step 4 of the task: ensure session.toml carries real UUIDv7s, even
  # if regenerate.sh's stamp step was bypassed by a partial fixture
  # refresh. When session.toml is missing or still contains the
  # double-curly placeholders from the template we re-stamp it using
  # the same generator regenerate.sh uses (`ct uuid7`, falling back
  # to python3's uuid module).
  needs_stamp=0
  if [ ! -f "$session" ]; then
    needs_stamp=1
  elif grep -qE '\{\{[^}]+\}\}' "$session"; then
    needs_stamp=1
  fi
  if [ "$needs_stamp" -eq 1 ]; then
    if [ ! -f "$template" ]; then
      echo "ERROR: session.toml.template missing at $template" >&2
      exit 1
    fi
    gen_uuid7() {
      if ct uuid7 2>/dev/null; then
        return 0
      fi
      python3 -c 'import uuid; print(uuid.uuid4())'
    }
    fe_js_id=$(gen_uuid7)
    fe_wasm_id=$(gen_uuid7)
    be_id=$(gen_uuid7)
    placeholder_fe_js='{'"{"'frontend_js_recording_id}'"}"
    placeholder_fe_wasm='{'"{"'frontend_wasm_recording_id}'"}"
    placeholder_be='{'"{"'backend_recording_id}'"}"
    sed \
      -e "s|$placeholder_fe_js|$fe_js_id|" \
      -e "s|$placeholder_fe_wasm|$fe_wasm_id|" \
      -e "s|$placeholder_be|$be_id|" \
      "$template" >"$session"
    echo "[demo] Stamped fresh recording-ids into $session"
  fi

  echo "[demo] Launching CodeTracer GUI with session manifest: $session"
  exec ct replay -t "$session"

# Elixir materialized trace DAP flow integration test (DB-based, no rr required).
# Uses CODETRACER_BEAM_RECORDER_PATH for explicit sibling discovery
# (legacy CODETRACER_ELIXIR_RECORDER_PATH still honored during the BEAM rename
# migration window).
test-elixir-flow:
  #!/usr/bin/env bash
  set -euo pipefail
  echo "Running Elixir materialized trace DAP flow integration test..."
  ./ci/test/beam-flow-cross-repo.sh e2e_cross_repo_ci_elixir_flow
  echo "Elixir flow test passed!"

# Erlang materialized trace DAP flow integration test (DB-based, no rr required).
# Uses the same codetracer-beam-recorder binary as the Elixir test.
test-erlang-flow:
  #!/usr/bin/env bash
  set -euo pipefail
  echo "Running Erlang materialized trace DAP flow integration test..."
  ./ci/test/beam-flow-cross-repo.sh e2e_cross_repo_ci_erlang_flow
  echo "Erlang flow test passed!"

# Combined BEAM (Elixir + Erlang) DAP flow integration test umbrella.
# Runs both language flows against the canonical fixtures from the
# codetracer-beam-recorder sibling and asserts the zero-test guard.
test-beam-flow:
  #!/usr/bin/env bash
  set -euo pipefail
  echo "Running BEAM materialized trace DAP flow integration tests..."
  ./ci/test/beam-flow-cross-repo.sh e2e_cross_repo_ci_beam_flow
  ./ci/test/beam-flow-cross-repo.sh verify_beam_flow_zero_test_guard
  echo "BEAM flow tests passed!"

# Noir flow/omniscience integration test (DB-based, no rr required)
test-noir-flow:
  #!/usr/bin/env bash
  set -e
  echo "Running Noir flow integration test..."
  cd src/db-backend && cargo nextest run --no-capture --run-ignored all test_noir_flow
  echo "Noir flow test passed!"

# WASM client-side replay test — verifies the browser-only replay path.
# The WASM pkg must be pre-built (run `cd src/db-backend && bash build_wasm.sh`).
# Uses Playwright to drive a real browser that fetches trace files from a dumb
# HTTP server and runs the DAP protocol entirely in a WebWorker via WASM.
test-wasm-replay *args:
  #!/usr/bin/env bash
  set -e
  WASM_PKG="src/db-backend/wasm-testing/pkg/db_backend.js"
  if [ ! -f "$WASM_PKG" ]; then
    echo "WASM package not found. Building..."
    cd src/db-backend && bash build_wasm.sh
    cd ../..
  fi
  echo "Running WASM client-side replay tests..."
  cd src/tests/gui && \
    npm install --no-audit --no-fund && \
    npx playwright test tests/wasm-replay/ {{args}}

# WASM flow/omniscience integration test (DB-based, no rr required)
# Requires: wazero on PATH, wasm32-wasip1 Rust target installed
test-wasm-flow:
  #!/usr/bin/env bash
  set -e
  echo "Running WASM flow integration test..."
  cd src/db-backend && cargo nextest run --no-capture test_wasm_flow
  echo "WASM flow test passed!"

# Stylus flow/omniscience integration test (requires Arbitrum devnode)
# Prerequisites: devnode at localhost:8547, cargo-stylus, cast (Foundry), wazero
test-stylus-flow:
  #!/usr/bin/env bash
  set -e
  echo "Running Stylus flow integration test..."
  echo "NOTE: Requires Arbitrum devnode running at localhost:8547"
  cd src/db-backend && cargo nextest run --no-capture --run-ignored all test_stylus_flow_integration
  echo "Stylus flow test passed!"

# Solidity/EVM flow/omniscience integration test (DB-based, no rr required)
# Prerequisites: codetracer-evm-recorder binary, solc (Solidity compiler), anvil (Foundry)
# Set CODETRACER_EVM_RECORDER_PATH to override the binary path.
test-solidity-flow:
  #!/usr/bin/env bash
  set -e
  echo "Running Solidity/EVM flow integration test..."

  # Build the evm-recorder if the binary doesn't exist
  EVM_RECORDER="${CODETRACER_EVM_RECORDER_PATH:-../codetracer-evm-recorder/target/debug/codetracer-evm-recorder}"
  if [ ! -f "$EVM_RECORDER" ]; then
    echo "Building codetracer-evm-recorder..."
    direnv exec ../codetracer-evm-recorder cargo build --manifest-path ../codetracer-evm-recorder/Cargo.toml
  fi
  export CODETRACER_EVM_RECORDER_PATH="$(realpath "$EVM_RECORDER")"

  # Use the evm-recorder's dev shell for solc/anvil
  direnv exec ../codetracer-evm-recorder \
    cargo nextest run --no-capture --run-ignored all \
      --manifest-path src/db-backend/Cargo.toml \
      test_solidity_flow solidity_flow_dap
  echo "Solidity flow test passed!"

# Miden/MASM flow/omniscience integration test (DB-based, no rr required)
# Prerequisites: codetracer-miden-recorder binary
# Set CODETRACER_MIDEN_RECORDER_PATH to override the binary path.
test-masm-flow:
  #!/usr/bin/env bash
  set -e
  echo "Running Miden/MASM flow integration test..."
  MIDEN_RECORDER="${CODETRACER_MIDEN_RECORDER_PATH:-../codetracer-miden-recorder/target/debug/codetracer-miden-recorder}"
  if [ -f "$MIDEN_RECORDER" ]; then
    export CODETRACER_MIDEN_RECORDER_PATH="$(realpath "$MIDEN_RECORDER")"
  fi
  cd src/db-backend && cargo nextest run --no-capture --run-ignored all masm_flow_dap
  echo "MASM flow test passed!"

# Sway/FuelVM flow/omniscience integration test (DB-based, no rr required)
# Prerequisites: codetracer-fuel-recorder binary, forc (Fuel compiler)
# Set CODETRACER_FUEL_RECORDER_PATH to override the binary path.
test-sway-flow:
  #!/usr/bin/env bash
  set -e
  echo "Running Sway/FuelVM flow integration test..."
  FUEL_RECORDER="${CODETRACER_FUEL_RECORDER_PATH:-../codetracer-fuel-recorder/target/debug/codetracer-fuel-recorder}"
  if [ -f "$FUEL_RECORDER" ]; then
    export CODETRACER_FUEL_RECORDER_PATH="$(realpath "$FUEL_RECORDER")"
  fi
  cd src/db-backend && cargo nextest run --no-capture --run-ignored all sway_flow_dap
  echo "Sway flow test passed!"

# Move/Sui flow/omniscience integration test (DB-based, no rr required)
# Prerequisites: codetracer-move-recorder binary
# Set CODETRACER_MOVE_RECORDER_PATH to override the binary path.
test-move-flow:
  #!/usr/bin/env bash
  set -e
  echo "Running Move/Sui flow integration test..."
  MOVE_RECORDER="${CODETRACER_MOVE_RECORDER_PATH:-../codetracer-move-recorder/target/debug/codetracer-move-recorder}"
  if [ -f "$MOVE_RECORDER" ]; then
    export CODETRACER_MOVE_RECORDER_PATH="$(realpath "$MOVE_RECORDER")"
  fi
  cd src/db-backend && cargo nextest run --no-capture --run-ignored all move_flow_dap
  echo "Move flow test passed!"

# Solana/SBF flow/omniscience integration test (DB-based, no rr required)
# Prerequisites: codetracer-solana-recorder binary
# Set CODETRACER_SOLANA_RECORDER_PATH to override the binary path.
test-solana-flow:
  #!/usr/bin/env bash
  set -e
  echo "Running Solana/SBF flow integration test..."
  SOLANA_RECORDER="${CODETRACER_SOLANA_RECORDER_PATH:-../codetracer-solana-recorder/target/debug/codetracer-solana-recorder}"
  if [ -f "$SOLANA_RECORDER" ]; then
    export CODETRACER_SOLANA_RECORDER_PATH="$(realpath "$SOLANA_RECORDER")"
  fi
  cd src/db-backend && cargo nextest run --no-capture --run-ignored all solana_flow_dap
  echo "Solana flow test passed!"

# PolkaVM flow/omniscience integration test (DB-based, no rr required)
# Prerequisites: codetracer-polkavm-recorder binary
# Set CODETRACER_POLKAVM_RECORDER_PATH to override the binary path.
test-polkavm-flow:
  #!/usr/bin/env bash
  set -e
  echo "Running PolkaVM flow integration test..."
  POLKAVM_RECORDER="${CODETRACER_POLKAVM_RECORDER_PATH:-../codetracer-polkavm-recorder/target/debug/codetracer-polkavm-recorder}"
  if [ -f "$POLKAVM_RECORDER" ]; then
    export CODETRACER_POLKAVM_RECORDER_PATH="$(realpath "$POLKAVM_RECORDER")"
  fi
  cd src/db-backend && cargo nextest run --no-capture --run-ignored all polkavm_flow_dap
  echo "PolkaVM flow test passed!"

# Cairo/StarkNet flow/omniscience integration test (DB-based, no rr required)
# Prerequisites: codetracer-cairo-recorder binary
# Set CODETRACER_CAIRO_RECORDER_PATH to override the binary path.
test-cairo-flow:
  #!/usr/bin/env bash
  set -e
  echo "Running Cairo flow integration test..."
  CAIRO_RECORDER="${CODETRACER_CAIRO_RECORDER_PATH:-../codetracer-cairo-recorder/target/debug/codetracer-cairo-recorder}"
  if [ -f "$CAIRO_RECORDER" ]; then
    export CODETRACER_CAIRO_RECORDER_PATH="$(realpath "$CAIRO_RECORDER")"
  fi
  cd src/db-backend && cargo nextest run --no-capture --run-ignored all cairo_flow_dap
  echo "Cairo flow test passed!"

# Circom flow/omniscience integration test (DB-based, no rr required)
# Prerequisites: codetracer-circom-recorder binary, circom compiler
# Set CODETRACER_CIRCOM_RECORDER_PATH to override the binary path.
test-circom-flow:
  #!/usr/bin/env bash
  set -e
  echo "Running Circom flow integration test..."
  CIRCOM_RECORDER="${CODETRACER_CIRCOM_RECORDER_PATH:-../codetracer-circom-recorder/target/debug/codetracer-circom-recorder}"
  if [ -f "$CIRCOM_RECORDER" ]; then
    export CODETRACER_CIRCOM_RECORDER_PATH="$(realpath "$CIRCOM_RECORDER")"
  fi
  cd src/db-backend && cargo nextest run --no-capture --run-ignored all circom_flow_dap
  echo "Circom flow test passed!"

# Leo/Aleo flow/omniscience integration test (DB-based, no rr required)
# Prerequisites: codetracer-leo-recorder binary, leo compiler
# Set CODETRACER_LEO_RECORDER_PATH to override the binary path.
test-leo-flow:
  #!/usr/bin/env bash
  set -e
  echo "Running Leo flow integration test..."
  LEO_RECORDER="${CODETRACER_LEO_RECORDER_PATH:-../codetracer-leo-recorder/target/debug/codetracer-leo-recorder}"
  if [ -f "$LEO_RECORDER" ]; then
    export CODETRACER_LEO_RECORDER_PATH="$(realpath "$LEO_RECORDER")"
  fi
  cd src/db-backend && cargo nextest run --no-capture --run-ignored all leo_flow_dap
  echo "Leo flow test passed!"

# Reproduces the WDIO leo-deep ``can search the calltrace for compute``
# failure (``DAP request timeout``) against a locally-recorded leo
# trace.  Mirrors the WDIO sequence (set breakpoint -> continue ->
# load flow -> search calltrace).
#
# Set CODETRACER_LEO_RECORDER_PATH to override the binary path.
test-leo-search-calltrace:
  #!/usr/bin/env bash
  set -e
  echo "Running Leo searchCalltrace integration test..."
  LEO_RECORDER="${CODETRACER_LEO_RECORDER_PATH:-../codetracer-leo-recorder/target/debug/codetracer-leo-recorder}"
  if [ -f "$LEO_RECORDER" ]; then
    export CODETRACER_LEO_RECORDER_PATH="$(realpath "$LEO_RECORDER")"
  fi
  cd src/db-backend && cargo nextest run --no-capture --run-ignored all leo_search_calltrace
  echo "Leo searchCalltrace test passed!"

# Tolk/TON flow/omniscience integration test (DB-based, no rr required)
# Prerequisites: codetracer-ton-recorder binary
# Set CODETRACER_TON_RECORDER_PATH to override the binary path.
test-tolk-flow:
  #!/usr/bin/env bash
  set -e
  echo "Running Tolk/TON flow integration test..."
  TOLK_RECORDER="${CODETRACER_TON_RECORDER_PATH:-../codetracer-ton-recorder/target/debug/codetracer-ton-recorder}"
  if [ -f "$TOLK_RECORDER" ]; then
    export CODETRACER_TON_RECORDER_PATH="$(realpath "$TOLK_RECORDER")"
  fi
  cd src/db-backend && cargo nextest run --no-capture --run-ignored all tolk_flow_dap
  echo "Tolk flow test passed!"

# Aiken/Cardano flow/omniscience integration test (DB-based, no rr required)
# Prerequisites: codetracer-cardano-recorder binary
# Set CODETRACER_AIKEN_RECORDER_PATH to override the binary path.
test-aiken-flow:
  #!/usr/bin/env bash
  set -e
  echo "Running Aiken/Cardano flow integration test..."
  AIKEN_RECORDER="${CODETRACER_AIKEN_RECORDER_PATH:-../codetracer-cardano-recorder/target/debug/codetracer-cardano-recorder}"
  if [ -f "$AIKEN_RECORDER" ]; then
    export CODETRACER_AIKEN_RECORDER_PATH="$(realpath "$AIKEN_RECORDER")"
  fi
  cd src/db-backend && cargo nextest run --no-capture --run-ignored all aiken_flow_dap
  echo "Aiken flow test passed!"

# Cadence/Flow flow/omniscience integration test (DB-based, no rr required)
# Prerequisites: codetracer-flow-recorder binary, cadence-trace-helper Go binary
# Set CODETRACER_CADENCE_RECORDER_PATH to override the binary path.
test-cadence-flow:
  #!/usr/bin/env bash
  set -e
  echo "Running Cadence/Flow flow integration test..."
  CADENCE_RECORDER="${CODETRACER_CADENCE_RECORDER_PATH:-../codetracer-flow-recorder/target/debug/codetracer-flow-recorder}"
  if [ -f "$CADENCE_RECORDER" ]; then
    export CODETRACER_CADENCE_RECORDER_PATH="$(realpath "$CADENCE_RECORDER")"
  fi
  cd src/db-backend && cargo nextest run --no-capture --run-ignored all cadence_flow_dap
  echo "Cadence flow test passed!"

# Full Stylus integration test: recording + trace content verification (requires Arbitrum devnode)
# This runs Tier 1 (recording) and Tier 2 (trace analysis) together.
# Set STYLUS_FIXTURE_OUTPUT_DIR to export the trace for VS Code extension UI tests.
test-stylus-flow-full:
  #!/usr/bin/env bash
  set -e
  echo "Running Stylus full integration test (recording + trace analysis)..."
  echo "NOTE: Requires Arbitrum devnode running at localhost:8547"
  cd src/db-backend && cargo nextest run --no-capture --run-ignored all test_stylus_trace_analysis
  echo "Stylus full integration test passed!"

# Noir real-recording integration tests (backend-manager, requires nargo + db-backend)
test-noir-real-recordings:
  #!/usr/bin/env bash
  set -e
  echo "Running Noir real-recording integration tests..."
  cd src/backend-manager && cargo nextest run --no-capture --run-ignored all test_real_noir
  echo "Noir real-recording tests passed!"

# ====
# All flow/omniscience integration tests for all languages and versions

test-flow-all:
  #!/usr/bin/env bash
  set -e
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║ Running all flow integration tests for all languages       ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo ""
  just test-nim-flow-all
  echo ""
  just test-rust-flow-all
  echo ""
  just test-python-flow
  echo ""
  just test-ruby-flow
  echo ""
  just test-noir-flow
  echo ""
  just test-wasm-flow
  echo ""
  just test-masm-flow
  echo ""
  just test-sway-flow
  echo ""
  just test-move-flow
  echo ""
  just test-solana-flow
  echo ""
  just test-polkavm-flow
  echo ""
  just test-cairo-flow
  echo ""
  just test-circom-flow
  echo ""
  just test-leo-flow
  echo ""
  just test-tolk-flow
  echo ""
  just test-aiken-flow
  echo ""
  just test-cadence-flow
  echo ""
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║ All flow integration tests passed!                         ║"
  echo "╚════════════════════════════════════════════════════════════╝"

# ====
# Cross-repo integration tests (requires codetracer-rr-backend)
# These tests build/find ct-rr-support from the rr-backend repo and run
# the flow integration tests against it.

cross-test:
  bash scripts/run-cross-repo-tests.sh all

cross-test-nim-flow:
  bash scripts/run-cross-repo-tests.sh nim-flow

cross-test-rust-flow:
  bash scripts/run-cross-repo-tests.sh rust-flow

cross-test-go-flow:
  bash scripts/run-cross-repo-tests.sh go-flow

show-rr-backend-pin:
  @cat .github/rr-backend-pin.txt 2>/dev/null || echo "main (default)"

update-rr-backend-pin ref="":
  #!/usr/bin/env bash
  PIN_FILE=".github/rr-backend-pin.txt"
  OLD_REF="$(cat "$PIN_FILE" 2>/dev/null || echo "main")"
  OLD_REF="$(echo "$OLD_REF" | tr -d '[:space:]')"
  NEW_REF="{{ref}}"
  if [[ -z "$NEW_REF" ]]; then
    echo "Usage: just update-rr-backend-pin <git-ref>"
    echo "Current pin: $OLD_REF"
    exit 1
  fi
  echo "$NEW_REF" > "$PIN_FILE"
  echo "Updated rr-backend pin: $OLD_REF -> $NEW_REF"

sync-design-tokens:
    rm -rf ./src/frontend/styles/generated
    mkdir -p ./src/frontend/styles/generated
    bash scripts/tokens-to-styl.sh \
      ./libs/codetracer-design-system \
      ./src/frontend/styles/generated

# One-time developer machine setup. Configures the local environment for
# iterative development of CodeTracer, including BPF script development.
#
# Sets up:
# - ct on PATH and .desktop file (non-privileged)
# - BPF capabilities on a local bpftrace copy so you can run and iterate
#   on BPF collection scripts without sudo
#
# On NixOS, BPF capabilities are managed by security.wrappers (see
# nix/packages/codetracer-appimage/nixos-module.nix). This target detects
# NixOS and skips the manual setcap step accordingly.
#
# Pass --without-bpf to skip BPF setup:
#   just developer-setup --without-bpf
# ====
# ViewModel headless tests (Nim)
#
# These tests exercise the ViewModel layer (signals, stores, VMs) without
# a browser or Electron.  They run with both the native (C) and JavaScript
# backends to catch platform-specific bugs like JS serialization issues.
#
# Skip patterns (both backends):
#   integration/real_backend_test  — requires stdio_backend (native process spawning)
#   integration/language_smoke_test — requires headless_session + ct binary
#   multi-replay/multi_session_test — requires headless_session
#   noir-space-ship/noir_space_ship_test — requires headless_session
#
# JS-backend-only skip:
#   agentic-coding/*  — these tests import std/osproc (native process
#     spawning) which cannot compile under `nim js` (osproc exports
#     quoteShell, unavailable on the JS target). They run on the native
#     backend only; the native lane covers them.
#
# `vm-test-prereqs` runs as a prerequisite so isonim's
# build/tailwind-styles.json exists before any test compile — views and
# session-chrome tests transitively `staticRead` it at Nim compile time
# (see isonim/src/isonim/dsl/tailwind.nim), an uncatchable error if the
# file is missing. This is the same tailwind-extract step that the heavier
# `build-once` runs first, factored out so the lightweight ViewModel test
# lanes don't pull in the full reprobuild frontend build. CI logs are
# captured under test-logs/ for the Full Log Preservation policy
# (ci-workflow-standards.md).

# Generate isonim's build/tailwind-styles.json (compile-time staticRead
# dependency of the ViewModel tests' isonim imports). Idempotent; cheap.
vm-test-prereqs:
  #!/usr/bin/env bash
  set -euo pipefail
  # Same tailwind-extract step build-once runs first, factored into a
  # shared script so the style map scans CodeTracer's frontend .nim
  # sources (not just isonim's recognized files).
  bash scripts/build-tailwind.sh

# Compile and run all ViewModel headless tests with the native (C) backend.
test-vm-native: vm-test-prereqs
  #!/usr/bin/env bash
  set -e
  mkdir -p test-logs
  exec > >(tee test-logs/test-vm-native.log) 2>&1
  echo "=== ViewModel tests (native backend) ==="
  failed=0
  passed=0
  for f in $(find src/tests/gui/tests -name '*_test.nim' \
    ! -name 'vm_test_helpers.nim' \
    ! -path '*/integration/real_backend_test.nim' \
    ! -path '*/integration/language_smoke_test.nim' \
    ! -path '*/multi-replay/*' \
    ! -path '*/noir-space-ship/*' \
    | sort); do
    name=$(basename "$f" .nim)
    cache="/tmp/ct-nim-cache/vm-native-$name"
    echo -n "  $f ... "
    output=$(nim c -r --hints:off \
      --path:src/frontend/viewmodel \
      --nimcache:"$cache" \
      -o:"$cache/$name" \
      "$f" 2>&1) || true
    oks=$(echo "$output" | grep -c '\[OK\]' || true)
    fails=$(echo "$output" | grep -c '\[FAILED\]' || true)
    if [ "$oks" -eq 0 ] && [ "$fails" -eq 0 ]; then
      echo "COMPILE ERROR"
      echo "$output" | grep 'Error:' | head -2 | sed 's/^/    /'
      failed=$((failed + 1))
    elif [ "$fails" -gt 0 ]; then
      echo "PARTIAL ($oks OK, $fails FAILED)"
      echo "$output" | grep '\[FAILED\]' | sed 's/^/    /'
      failed=$((failed + 1))
    else
      echo "OK ($oks tests)"
      passed=$((passed + 1))
    fi
  done
  echo ""
  echo "Native: $passed passed, $failed failed"
  [ "$failed" -eq 0 ]

# Compile and run JS-compatible ViewModel headless tests via nim js + node.
# Skips tests that require native process spawning (stdio_backend, headless_session).
test-vm-js: vm-test-prereqs
  #!/usr/bin/env bash
  set -e
  mkdir -p test-logs
  exec > >(tee test-logs/test-vm-js.log) 2>&1
  echo "=== ViewModel tests (JS backend) ==="
  failed=0
  passed=0
  for f in $(find src/tests/gui/tests -name '*_test.nim' \
    ! -name 'vm_test_helpers.nim' \
    ! -path '*/integration/real_backend_test.nim' \
    ! -path '*/integration/language_smoke_test.nim' \
    ! -path '*/multi-replay/*' \
    ! -path '*/noir-space-ship/*' \
    ! -path '*/agentic-coding/*' \
    | sort); do
    name=$(basename "$f" .nim)
    cache="/tmp/ct-nim-cache/vm-js-$name"
    echo -n "  $f ... "
    if ! nim js --hints:off \
      --path:src/frontend/viewmodel \
      --nimcache:"$cache" \
      -o:"$cache/$name.js" \
      "$f" >/dev/null 2>&1; then
      echo "COMPILE ERROR"
      nim js --hints:off \
        --path:src/frontend/viewmodel \
        --nimcache:"$cache" \
        -o:"$cache/$name.js" \
        "$f" 2>&1 | grep 'Error:' | head -2 | sed 's/^/    /'
      failed=$((failed + 1))
      continue
    fi
    output=$(node "$cache/$name.js" 2>&1)
    exitcode=$?
    oks=$(echo "$output" | grep -c '\[OK\]' || true)
    fails=$(echo "$output" | grep -c '\[FAILED\]' || true)
    if [ "$fails" -gt 0 ] || [ "$exitcode" -ne 0 ]; then
      echo "PARTIAL ($oks OK, $fails FAILED)"
      echo "$output" | grep '\[FAILED\]' | head -5 | sed 's/^/    /'
      failed=$((failed + 1))
    else
      echo "OK ($oks tests)"
      passed=$((passed + 1))
    fi
  done
  echo ""
  echo "JS: $passed passed, $failed failed"
  [ "$failed" -eq 0 ]

# Run ViewModel headless tests on both native and JS backends.
test-vm: test-vm-native test-vm-js

# Compile + run the recorder-gated ViewModel headless tests that live under
# src/frontend/viewmodel/tests/unit/ (the column-aware / formatted-view /
# statement-step suites).  These are NOT covered by `test-vm` above, which
# only globs src/tests/gui/tests/*_test.nim — these files are named
# test_*_vm.nim and sit in the viewmodel unit dir, so without this recipe they
# never ran in CI at all.
#
# Each of these tests drives a real recorder (the JS recorder for the core M1
# column-breakpoint / formatted-view / statement-step cases) plus the same-repo
# replay-server, then asserts column/value flow end-to-end.  They route a
# missing recorder sibling through recorder_gate's uniform
# `MISSING-RECORDER SKIP:` marker rather than failing.  To make them actually
# RUN (instead of silently skipping) this recipe first builds the JS recorder
# sibling via scripts/build-siblings.sh (the canonical `direnv exec <repo> just
# build` path) and ensures replay-server is built, then guards against the
# vacuous all-skipped outcome so a missing recorder can't masquerade as a pass.
test-vm-recorder-gated: vm-test-prereqs
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-vm-recorder-gated.log) 2>&1
  echo "=== Recorder-gated ViewModel tests (JS recorder + replay-server) ==="

  # Build the JS recorder sibling so CODETRACER_JS_RECORDER_PATH resolves and
  # the JS-gated tests run for real.  build-siblings.sh reports its own
  # per-repo PASS/SKIP/FAIL and exits non-zero on a build failure.
  bash scripts/build-siblings.sh --only codetracer-js-recorder

  # replay-server is a same-repo cargo artefact the tests fail loudly without.
  if [ ! -x src/db-backend/target/debug/replay-server ] \
     && [ ! -x src/db-backend/target/release/replay-server ] \
     && [ ! -x src/build-debug/bin/replay-server ]; then
    echo "Building replay-server (db-backend) ..."
    (cd src/db-backend && cargo build --bin replay-server)
  fi

  # Discover the sibling recorders / tools the tests look up by env var.
  source scripts/detect-siblings.sh

  failed=0
  passed=0
  skipped=0
  for f in $(find src/frontend/viewmodel/tests/unit \
      -name 'test_column_*_vm.nim' \
      -o -name 'test_formatted_view_step_*_vm.nim' \
      -o -name 'test_statement_step_*_vm.nim' | sort); do
    name=$(basename "$f" .nim)
    cache="/tmp/ct-nim-cache/vm-gated-$name"
    echo -n "  $f ... "
    output=$(nim c -r --hints:off \
      --path:src/frontend/viewmodel \
      --nimcache:"$cache" \
      -o:"$cache/$name" \
      "$f" 2>&1) || true
    oks=$(echo "$output" | grep -c '\[OK\]' || true)
    fails=$(echo "$output" | grep -c '\[FAILED\]' || true)
    skips=$(echo "$output" | grep -c 'MISSING-RECORDER SKIP:' || true)
    if [ "$fails" -gt 0 ]; then
      echo "FAILED ($oks OK, $fails FAILED)"
      echo "$output" | grep '\[FAILED\]' | sed 's/^/    /'
      failed=$((failed + 1))
    elif [ "$skips" -gt 0 ]; then
      echo "SKIPPED (missing recorder)"
      echo "$output" | grep 'MISSING-RECORDER SKIP:' | head -1 | sed 's/^/    /'
      skipped=$((skipped + 1))
    elif [ "$oks" -eq 0 ]; then
      echo "COMPILE ERROR / no tests ran"
      echo "$output" | grep 'Error:' | head -2 | sed 's/^/    /'
      failed=$((failed + 1))
    else
      echo "OK ($oks tests)"
      passed=$((passed + 1))
    fi
  done

  echo ""
  echo "Recorder-gated VM: $passed passed, $skipped skipped, $failed failed"
  # Zero-test guard (Cross-Repo-CI-Integration.md "Zero-Test Guard"): when CI
  # builds the JS recorder sibling, these tests MUST run — an all-skipped /
  # all-empty outcome means the recorder wasn't actually wired in, which is a
  # silent cross-repo coverage gap, so fail it.
  if [ "$failed" -gt 0 ]; then
    exit 1
  fi
  if [ "$passed" -eq 0 ]; then
    echo "ERROR: no recorder-gated ViewModel test ran (all skipped/empty)." >&2
    echo "  The JS recorder sibling was expected to be built — see" >&2
    echo "  codetracer-specs/Testing/Cross-Repo-CI-Integration.md (Zero-Test Guard)." >&2
    exit 1
  fi

# Run the headless agentic CodeTracer matrix. This invokes Agent Harbor's
# existing CodeTracer contract E2E tests for the real REST/scenario side, then
# runs the CodeTracer service/ViewModel/DeepReview headless matrix.
test-codetracer-agentic-headless-matrix:
  bash scripts/test-codetracer-agentic-headless.sh matrix

# Run the agentic headless matrix plus adjacent DAP, backend-manager,
# ViewModel, and collaboration regression coverage.
test-codetracer-agentic-regression-gate:
  bash scripts/test-codetracer-agentic-headless.sh regression

# Run the focused GUI E2E tests for the worktree-isolated agentic workflow.
test-e2e-agentic-worktree:
  bash scripts/test-agentic-worktree-gui.sh

# Optional AgentFS/snapshot-daemon agentic E2E contract. This target does not
# start privileged daemons; without explicit CODETRACER_AGENTFS_E2E=1 and an
# already-running AgentFS/Agent Harbor setup, the Playwright test records a
# precise runtime skip.
test-e2e-agentic-agentfs-optional:
  cd "${CODETRACER_REPO_ROOT_PATH}/src/tests/gui" && \
    npm install --no-audit --no-fund && \
    npx playwright test --workers=1 \
      tests/agentic-coding/agentic-agentfs-optional.spec.ts

developer-setup *flags:
  bash scripts/developer-setup.sh {{flags}}

# Capture automated animations for the README in animated WebP format (for review).
# The results will be placed in test-results/readme-animations-review/
capture-readme-animations-review:
  bash scripts/docs/capture-readme-animations.sh

# Performance + E2E Coverage campaign benchmarks (P2 / P3 / P4).
#
# Each target builds + drives the `ct-bench` CLI from
# `src/codetracer-bench/`. The full bench runs against real recorders
# on PATH; when a recorder is missing the bench skips it narrowly and
# reports the missing dependency in the trailing log.
#
# Output lands in `src/codetracer-bench/target/codetracer-bench/<bench>/`.

# P2 — omniscient-DB on-disk size per language.
bench-omniscient-db-size *args:
  cd src/codetracer-bench && cargo run --release --bin ct-bench -- omniscient-db-size {{args}}

# P3 — slice generation speed + concurrent processing speedup.
bench-slice-prep-speed *args:
  cd src/codetracer-bench && cargo run --release --bin ct-bench -- slice-prep-speed {{args}}

# P4 — GUI-feature latency matrix.
bench-gui-ops *args:
  cd src/codetracer-bench && cargo run --release --bin ct-bench -- gui-ops {{args}}

# ─── cross-repo sibling builds ──────────────────────────────────────────────
# Per metacraft-dev-guidelines/policies/cross-repo-builds.md: consumer
# recipes invoke ensure-* prerequisites which build sibling artefacts on
# demand via the sibling's own ``just`` target. Three-way fallback —
# reprobuild → direnv → DIY — keeps Nix/Windows/cached environments on
# the same code path. ``CT_<NAME>_SIBLING`` env vars are set by
# codetracer/.envrc (Nix) or metacraft/env.ps1 (Windows DIY).

# Build ct-mcr (= ct_cli.exe on Windows) from the sibling
# codetracer-native-recorder checkout.
ensure-ct-mcr:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "${CT_CODETRACER_NATIVE_RECORDER_SIBLING:-}" ]; then
        echo "SKIP: codetracer-native-recorder sibling not detected (set CT_CODETRACER_NATIVE_RECORDER_SIBLING or check it out at \$METACRAFT_ROOT/codetracer-native-recorder)" >&2
        exit 0
    fi
    sibling="$CT_CODETRACER_NATIVE_RECORDER_SIBLING"
    if command -v repro >/dev/null 2>&1; then
        # ``repro build`` operates on the project at the current working
        # directory (the CLI has no ``--cwd`` flag); cd into the sibling
        # first so the recorder's ``ct-mcr`` target resolves there.
        # ``--tool-provisioning=nix`` is required: reprobuild refuses an
        # implicit PATH fallback for ``uses`` declarations and the Nix-based
        # sibling resolves its toolchain through its flake.
        ( cd "$sibling" && repro build --tool-provisioning=nix ct-mcr )
    elif [ "${OS:-}" = "Windows_NT" ]; then
        # Windows DIY: no Nix dev shell, invoke the sibling's
        # Windows-specific build target directly. env.ps1 has already
        # populated nim + MSVC into the current shell, so the sibling's
        # nimble/MSBuild calls can run in-place. Check this branch
        # BEFORE direnv: direnv on Windows DIY would try to enter the
        # sibling's Nix dev shell, which isn't viable.
        cd "$sibling" && just build-ct-mcr-windows
    elif command -v direnv >/dev/null 2>&1 && [ -f "$sibling/.envrc" ]; then
        direnv allow "$sibling"
        direnv exec "$sibling" just -f "$sibling/Justfile" build-ct-mcr
    else
        cd "$sibling" && just build-ct-mcr
    fi

# Build ct-native-replay from the sibling codetracer-native-backend
# checkout.
#
# Unlike ``ensure-ct-mcr``, this recipe does NOT route through
# ``repro build``: codetracer-native-backend is a plain cargo project
# with no reprobuild project file, so ``repro build ct-native-replay``
# fails with "build target module not found: ct-native-replay.nim".
# Per cross-repo-builds.md, build the sibling via ITS OWN canonical
# ``just`` target instead.
#
# Target selection (the backend's justfile defines these):
#   * macOS  -> ``build-mcr``  (provisions LLVM_CONFIG / LLDB_LIB_PATH
#               from nix, runs ``cargo build``, then ``fix-lldb-rpath``
#               + ``sign-macos-binary`` so ct-native-replay can load
#               liblldb via @rpath and spawn dyld-interposed tools).
#   * Linux  -> ``build``      (plain ``cargo build``; lldb-sys links
#               against the nix liblldb directly, no rpath rewrite or
#               codesign needed).
# Both land the binary at ``$sibling/target/debug/ct-native-replay``.
#
# The Nix build runs through ``nix develop '.?submodules=1'`` rather than
# ``direnv exec`` -- mirroring ``build-once`` above for ct-mcr. The
# backend's ``flake.nix`` shellHook is what creates the runtime
# ``target/debug/liblldb.dylib`` symlink and exports
# ``CT_NATIVE_REPLAY_RPATH`` (baked into the binary by ``build.rs`` so
# ``@rpath/liblldb.dylib`` resolves at run time). ``direnv exec`` on the
# sibling can silently fall back to a hookless environment when the
# sibling's flake-override plugin or path inputs are out of sync, which
# yields a binary with no liblldb RPATH that aborts when a child
# ct-native-replay process is spawned. ``nix develop`` evaluates the
# devShell directly and always runs the shellHook.
ensure-ct-native-replay:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "${CT_CODETRACER_NATIVE_BACKEND_SIBLING:-}" ]; then
        echo "SKIP: codetracer-native-backend sibling not detected (set CT_CODETRACER_NATIVE_BACKEND_SIBLING or check it out at \$METACRAFT_ROOT/codetracer-native-backend)" >&2
        exit 0
    fi
    sibling="$CT_CODETRACER_NATIVE_BACKEND_SIBLING"
    # Pick the backend just target that produces a working
    # ct-native-replay on this platform (see recipe header).
    case "$(uname -s)" in
        Darwin) backend_target=build-mcr ;;
        *)      backend_target=build ;;
    esac
    # On macOS the liblldb runtime wiring (the ``target/debug/liblldb.dylib``
    # symlink + the ``CT_NATIVE_REPLAY_RPATH`` that build.rs bakes into the
    # binary so a *child* ct-native-replay can load liblldb under SIP) is
    # normally done by the backend's flake shellHook. We provision it here
    # too so the build is correct even when the sibling's dev shell is
    # entered hookless (e.g. its workspace flake.lock can't evaluate under
    # a dirty checkout). MCR's GDB-RSP client needs Apple's Xcode LLDB at
    # run time, with the Nix liblldb dir kept on RPATH for the compile-time
    # symbols. This mirrors codetracer-native-backend/nix/shells/main.nix.
    if [ "$(uname -s)" = "Darwin" ]; then
        mkdir -p "$sibling/target/debug"
        apple_lldb="/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Versions/A/LLDB"
        if [ -f "$apple_lldb" ]; then
            ln -sf "$apple_lldb" "$sibling/target/debug/liblldb.dylib"
        elif [ -n "${LLDB_LIB_PATH:-}" ] && [ -e "${LLDB_LIB_PATH%/}/liblldb.dylib" ]; then
            ln -sf "${LLDB_LIB_PATH%/}/liblldb.dylib" "$sibling/target/debug/liblldb.dylib"
        fi
        nix_lldb_dir="${LLDB_LIB_PATH:-}"
        if [ -z "$nix_lldb_dir" ] && command -v nix >/dev/null 2>&1; then
            nix_lldb_dir="$(nix build --no-link --print-out-paths nixpkgs#lldb 2>/dev/null)/lib" || nix_lldb_dir=""
        fi
        export CT_NATIVE_REPLAY_RPATH="$sibling/target/debug/:${nix_lldb_dir:+$nix_lldb_dir}"
    fi
    if [ "${OS:-}" = "Windows_NT" ]; then
        # Windows DIY: short-circuit before nix (see ensure-ct-mcr for
        # rationale). cargo must be on PATH (rustup-init or equivalent)
        # for this branch to succeed; env.ps1 does NOT provision rust
        # today. The recipe still wires correctly; a missing cargo
        # surfaces a clear "command not found" rather than a silent skip.
        cd "$sibling" && just build
    elif command -v nix >/dev/null 2>&1 && [ -f "$sibling/flake.nix" ] && \
         ( cd "$sibling" && nix develop '.?submodules=1' --command true >/dev/null 2>&1 ); then
        # Preferred path (CI + clean dev checkouts): build inside the
        # sibling's own Nix dev shell so its pinned LLVM/LLDB toolchain is
        # used and its shellHook runs. This is exactly the backend's own CI
        # invocation (``nix develop .?submodules=1 --command just build``).
        # ``cd "$sibling"`` + local ``.`` flake ref honours the dirty
        # working tree; the ``nix develop ... true`` guard above confirms
        # the devShell actually evaluates before we commit to this branch
        # (the sibling's ``path:libs/...`` flake inputs can fail to lock
        # under a dirty workspace checkout). ``unset`` clears LLDB/CXX env
        # leaking from the codetracer shell so the sibling hook owns it.
        ( cd "$sibling" && nix develop '.?submodules=1' --command bash -lc \
            "unset LLVM_CONFIG LLDB_LIB_PATH LLDB_ADDITIONAL_INCLUDE_DIRS CXXFLAGS CC CXX; just $backend_target" )
    elif command -v just >/dev/null 2>&1; then
        # Fallback: the sibling dev shell could not be evaluated, but we are
        # already inside the codetracer Nix dev shell which provides cargo +
        # LLVM/LLDB. ``build-mcr`` itself provisions LLVM_CONFIG/LLDB_LIB_PATH
        # via ``nix build`` when unset, and the macOS block above has already
        # set CT_NATIVE_REPLAY_RPATH + the liblldb symlink so the resulting
        # binary is runtime-loadable. (On Linux ``build`` links liblldb
        # directly; no extra wiring needed.)
        ( cd "$sibling" && just "$backend_target" )
    else
        cd "$sibling" && cargo build --bin ct-native-replay
    fi

# Run the DAP-flow integration tests (Ada / C / C++ / D / Fortran / Go /
# Pascal / Nim / Rust) under
# ``src/db-backend/tests/*_mcr_streaming_flow_test.rs``.
#
# The ``ensure-*`` prerequisites build the sibling binaries; this recipe
# then makes them discoverable to the Rust tests:
#   * ``test_harness::is_mcr_available()`` requires ``ct-mcr`` ON PATH
#     (it ignores CODETRACER_CT_MCR_CMD), so we symlink the recorder's
#     ct_cli as ``ct-mcr`` into a scratch dir prepended to PATH.
#   * ``test_harness::find_ct_rr_support()`` honours CT_NATIVE_REPLAY_PATH
#     first, then PATH, then ``../../codetracer-native-backend/target/
#     debug``; we export the explicit path so the right binary is used.
# Tests whose language compiler is absent honest-SKIP (``SKIPPED:`` line)
# rather than failing.
test-mcr-dap-flow: ensure-ct-mcr ensure-ct-native-replay
    #!/usr/bin/env bash
    set -euo pipefail
    # Resolve the sibling binaries built by the ensure-* prerequisites.
    if [ -n "${CT_CODETRACER_NATIVE_BACKEND_SIBLING:-}" ]; then
        native_backend="$CT_CODETRACER_NATIVE_BACKEND_SIBLING"
    else
        native_backend="$(cd "$(git rev-parse --show-toplevel)/../codetracer-native-backend" 2>/dev/null && pwd || true)"
    fi
    if [ -n "${CT_CODETRACER_NATIVE_RECORDER_SIBLING:-}" ]; then
        native_recorder="$CT_CODETRACER_NATIVE_RECORDER_SIBLING"
    else
        native_recorder="$(cd "$(git rev-parse --show-toplevel)/../codetracer-native-recorder" 2>/dev/null && pwd || true)"
    fi

    replay="${native_backend:-}/target/debug/ct-native-replay${EXE_SUFFIX:-}"
    # Prefer the debug-symbol ct_cli build on macOS (ct_cli-debug); fall
    # back to the plain ct_cli on Linux / Windows.
    ct_mcr=""
    for cand in "${native_recorder:-}/ct_cli/ct_cli-debug" "${native_recorder:-}/ct_cli/ct_cli"; do
        if [ -x "$cand" ]; then ct_mcr="$cand"; break; fi
    done

    # If a sibling binary is genuinely absent (ensure-* SKIP'd), the Rust
    # tests detect the missing tool and emit SKIPPED lines themselves; we
    # still run cargo so that signal is visible (per cross-repo-builds.md).
    extra_path=""
    if [ -n "$ct_mcr" ]; then
        mcr_dir="$(mktemp -d "${TMPDIR:-/tmp}/ct-mcr-path.XXXXXX")"
        ln -sf "$ct_mcr" "$mcr_dir/ct-mcr"
        extra_path="$mcr_dir:"
        export CODETRACER_CT_MCR_CMD="$ct_mcr"
    fi
    if [ -x "$replay" ]; then
        export CT_NATIVE_REPLAY_PATH="$replay"
        export CT_NATIVE_REPLAY_BIN="$replay"
        export CODETRACER_CT_NATIVE_REPLAY_CMD="$replay"
        extra_path="$extra_path${native_backend}/target/debug:"
    fi
    export PATH="${extra_path}${PATH}"

    cd src/db-backend && cargo test --test '*_mcr_streaming_flow_test'
