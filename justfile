build:
  bash scripts/build.sh

build-once:
  bash scripts/build-once.sh

# Assert that `just build` is `just build-once` plus watchers, and nothing
# else. Executes BOTH scripts under a PATH of recording stubs (tup, webpack,
# livereload, repro, runquotad, nix, uname) and compares the resulting command
# traces: same host branch, same tup variant, same steps in the same order,
# and — the assertion that catches issue #599 — no webpack invocation ordered
# before the first tup/repro invocation. Builds nothing, needs no toolchain,
# runs in seconds. See the header of scripts/test-build-alignment.sh.
test-build-alignment:
  bash scripts/test-build-alignment.sh

# Assert this repo's `runquota` flake pin equals the `runquota-src` revision
# its pinned `reprobuild` locks. `inputs.runquota-src.follows = "runquota"`
# means reprobuild is COMPILED against whatever that input resolves to, so
# drift in either direction breaks `nix develop` with an `undeclared
# identifier` inside reprobuild's own sources, minutes in and attributed to
# the wrong repo. Reads two flake.lock files; no toolchain, under a second.
# Skips LOUDLY (never silently passes) when the sibling reprobuild checkout it
# must read is absent; CT_FLAKE_PIN_ALIGNMENT_STRICT=1 makes that a failure.
# See the header of scripts/test-flake-pin-alignment.sh.
test-flake-pin-alignment:
  bash scripts/test-flake-pin-alignment.sh

# Assert that every place a Python version can be observed still agrees with
# the one place it is CHOSEN (nix/python.nix): the dev shell's exports and its
# first `python3` on PATH, `.python-recorder-venv`'s interpreter, the ABI tag
# of the recorder sibling's compiled extension, and the `requires-python`
# windows the recorder declares. A CPython extension is ABI-locked to its
# minor version, so a disagreement here is not a style problem — it is
# `ct record x.py` refusing to run and the `record-python-happy-path` E2E edge
# going red. Every figure it compares is derived from an artifact or from the
# pin; nothing is restated as a literal, so bumping nix/python.nix keeps this
# green while choosing a version anywhere else does not. Reads files and runs
# interpreters; no build, seconds. Conditions it cannot observe (no venv, an
# unbuilt sibling) are printed as `n/a` and counted separately — never as
# passes. See the header of scripts/test-python-version-alignment.sh.
test-python-version-alignment:
  bash scripts/test-python-version-alignment.sh

# Assert that detect-siblings.sh can actually satisfy the prerequisite the
# RR-based backend-manager integration tests demand. Those 48 tests gate on
# CODETRACER_RR_BACKEND_PATH and tell the operator to run detect-siblings.sh
# when it is unset; that instruction was false for as long as both the script
# and the repro dev shell keyed the variable on a sibling directory named
# `codetracer-rr-backend`, which is not a repository that exists. Hermetic and
# fast (no build, no network) -- the real-checkout leg skips loudly when the
# sibling is absent, as in the non-gui lane.
test-sibling-backend-path:
  bash ci/test/sibling-backend-path-test.sh

# Assert that the built output tree carries the assets `ct` reads on startup
# (`<prefix>/config/default_config.yaml` and `default_layout.json`). A tup
# build exits 0 when a runtime asset is simply never published -- there is no
# rule to fail -- which is how `src/build-debug/config/` stayed empty across
# every clean build while `ct` died on first run with an uncaught OSError.
# `scripts/build-once.sh` runs this at the end of both build branches; the
# recipe exists so it can be run against an existing tree on its own.
# Defaults to the debug tup variant; pass another output root to override.
require-runtime-assets OUT_ROOT="src/build-debug":
  bash scripts/require-runtime-assets.sh {{OUT_ROOT}}

# The contract suite for that guard -- synthetic trees, no toolchain, ~1s.
# Also runs in the `lint-bash` job (ci/lint/bash.sh).
test-runtime-assets-guard:
  bash ci/test/require-runtime-assets-test.sh

# Build all sibling-recorder binaries that the GUI tests reach for.
# Idempotent — already-built artefacts short-circuit, so this is cheap on
# warm checkouts.  Pass `--force` to rebuild everything; `--check` to just
# report status without building.  See scripts/build-siblings.sh.
build-siblings *args:
  bash scripts/build-siblings.sh {{args}}

# Assemble the `codetracer-desktop` component bundle the `ct` launcher fronts:
#   <out-root>/codetracer-desktop@<ver>/{capabilities, bin/codetracer}
# `capabilities` is copied byte-for-byte from
# `resources/codetracer-desktop-capabilities`, and both the directory name and
# the binary filename are derived from that file's `name` / `bin` lines so they
# can never drift apart.  Requires an already-built core (`just build-once`);
# a missing core is a loud failure, not a no-op.  Output defaults to the
# gitignored `build-desktop-component/`, which is exactly the path to hand the
# launcher as CODETRACER_COMPONENTS_ROOT.  Pass `--out-root DIR`, `--copy`
# (real file instead of a symlink to the build tree) or `--help`.
# See scripts/build-desktop-component.sh and
# codetracer-specs/Testing/Launcher-Recorder-Compatibility-Tests.md §5.1.
build-desktop-component *args:
  bash scripts/build-desktop-component.sh {{args}}

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

# Regenerate the isonim book's checked-in screenshots.
#
# `docs/book-isonim/static/img/visual_recordings/*.png` were placeholders with
# a PLACEHOLDERS.txt admitting the capture step was never wired: the capture
# script existed but only ever wrote into the OLD mdBook's generated/ tree,
# which is not checked in and which the new book does not read. The images the
# published book actually serves were therefore the only ones nothing could
# reproduce.
#
# The script already takes its destination from the environment, so wiring is
# a matter of pointing it at the new book rather than new capture code.
#
# It needs a built `ct_gfx_player` (codetracer-visual-replay) and a built
# `ct_cli` (codetracer-native-recorder), and it FAILS with a named remedy and
# a non-zero status when either is missing -- it does not quietly leave the
# stale images in place.
capture-book-assets:
  #!/usr/bin/env bash
  set -euo pipefail
  CODETRACER_BOOK_SCREENSHOT_DIR="$(pwd)/docs/book-isonim/static/img/visual_recordings" \
    bash scripts/docs/capture-visual-recording-screenshots.sh

# Regenerate the DeepReview screenshots the book serves from
# `/assets/img/deep_review/`. Same discipline as `capture-book-assets`: it
# records a real Noir program, collects a real review dataset and photographs
# the real `ct review` window, and fails with a named remedy rather than
# leaving stale images in place. Needs nargo, Xvfb, xdotool and ImageMagick.
capture-deep-review-assets:
  #!/usr/bin/env bash
  set -euo pipefail
  CODETRACER_BOOK_SCREENSHOT_DIR="$(pwd)/docs/book-isonim/static/img/deep_review" \
    bash scripts/docs/capture-deep-review-screenshots.sh

# Capture the DeepReview design-review matrix (UD-0): every named view, at
# every named viewport size, in both themes.
#
# NOT the same thing as `capture-deep-review-assets` above, which produces two
# frozen images for the book from a fixture the book's prose quotes line for
# line. This produces a re-capturable matrix over a much richer corpus, for the
# visual-design-iteration loop. They share their machinery -- preflight, the
# stale-build refusal, recording, dataset collection, Xvfb -- in
# `scripts/docs/deep-review-capture-lib.sh`, and nothing else.
#
# Targeted re-capture is the common case and needs no recipe:
#   bash tools/visual-review/capture-deepreview-views.sh --view diff-flow-values --size wide --theme dark
capture-deepreview-design-views:
  bash tools/visual-review/capture-deepreview-views.sh

# The contract suite for that harness: the matrix covers what the campaign
# changes, the brief has an expected-elements block per view, and targeting
# neither re-records nor deletes the other views' captures. Never launches
# Electron; `ci/lint/bash.sh` runs it too.
test-deepreview-design-harness:
  bash tools/visual-review/deepreview-harness-test.sh

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

test-reprobuild-macos-daemon-build:
  bash ci/reprobuild/macos-daemon-build.sh

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

  ct_bin="${CODETRACER_BUILD_DIR:-$repo_root/src/build-debug}/bin/ct"
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

# Install `storybook/node_modules` from the committed lockfile.
#
# Every `npm run` under `storybook/` resolves its binary from that directory's
# `node_modules/.bin`, and NOTHING in this repo ever created it: the recipes
# below jumped straight to `npm run build-storybook`, which fails with
# `storybook: command not found`. Because `just test-e2e` with no arguments
# routes through `ensure-storybook-static` -> `storybook-build`, that missing
# directory made the bare entry point unrunnable, and every `*storybook*.spec.ts`
# a permanent red that no one could act on. `npm ci` from the committed
# `package-lock.json` takes ~17s and is idempotent, so the guard below is a
# no-op on a warm checkout.
storybook-deps:
  #!/usr/bin/env bash
  set -euo pipefail
  cd storybook
  if [ -x node_modules/.bin/storybook ]; then
    exit 0
  fi
  npm ci --no-audit --no-fund
  # `npm ci` exits 0 on a lockfile that installs nothing useful, so assert the
  # binary the `npm run` scripts below actually invoke.
  test -x node_modules/.bin/storybook

storybook: build-storybook-components storybook-deps
  cd storybook && npm run storybook

storybook-build: build-storybook-components storybook-deps
  chmod -R u+w storybook/storybook-static 2>/dev/null || true
  rm -rf storybook/storybook-static
  cd storybook && npm run build-storybook
  # tup/webpack/storybook all exit 0 on an empty output tree; assert the
  # artefact `ensure-storybook-static` promises its callers.
  test -f storybook/storybook-static/index.html

storybook-check-styles: storybook-deps
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

# Live docs.codetracer.com dev server (hot reload) — the isonim-docs book in
# docs/book-isonim. Runnable from the repo root: it enters that book's dev
# shell (the isonim-docs framework flake, which brings nim/node/just) and runs
# its dev-docs recipe. See docs/book-isonim/README.md. Default: http://127.0.0.1:8000
dev-docs port='8000' host='127.0.0.1':
  #!/usr/bin/env bash
  set -euo pipefail
  cd docs/book-isonim
  # Prefer the live sibling isonim checkout (as docs/book-isonim/.envrc does),
  # else fall back to the pinned github input in isonim-docs/flake.lock.
  overrides=()
  [[ -d ../../../isonim ]] && overrides+=(--override-input isonim path:../../../isonim)
  exec nix develop path:../../../isonim-docs "${overrides[@]}" -c just dev-docs {{port}} {{host}}

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
  # Flow tests that need ct-native-replay/rr skip automatically when unavailable.
  # Shell/JS flow tests require sibling repos (codetracer-shell-recorders, etc.)
  # and are run separately in cross-repo CI jobs.
  cargo nextest run --release --test '*' \
    -E 'not test(~bash_flow_integration) and not test(~zsh_flow_integration) and not test(~javascript_flow_integration)'
  popd
  pushd src/backend-manager
  cargo nextest run --release
  cargo nextest run --release --run-ignored ignored-only || \
    if [ "$?" = "4" ]; then \
      echo "  (no ignored tests in backend-manager; treating as no-op)"; \
    else \
      exit "$?"; \
    fi
  popd

# Exercise `ct print` end to end against the built `ct` binary.
#
# Covers the JSONL span-manifest path and, since RS-M2, the CTFS span-stream
# path: `ct print` reads a recording's HTTP requests out of the container's
# `spans.dat` and only falls back to a `session_manifest.jsonl` /
# `codetracer_spans.jsonl` sidecar when the container has no stream.
#
# The script FAILS when `src/build-debug/bin/ct` has not been built, so run
# `just build-once` first.  It is deliberately not safe to run in a bare dev
# shell: exiting 0 on a missing binary made "ct print is untested" and
# "ct print works" indistinguishable.  Set CT_PRINT_ALLOW_MISSING=1 to skip it
# locally before a build; it is never set in a CI gate.
test-ct-print:
  #!/usr/bin/env bash
  set -e
  ./tests/test_ct_print.sh

# Run all non-GUI tests.
# test-frontend-js needs npm-installed jsdom (available after tup build, not in bare nix shell).
# test-python-recorder needs a built ct binary.
# Both are skipped here; they run in their own CI steps or via dev builds.
test:
  #!/usr/bin/env bash
  set -e
  just test-build-alignment
  just test-flake-pin-alignment
  just test-python-version-alignment
  just test-sibling-backend-path
  just test-agent-api-contract
  just test-rust
  just test-nimsuggest
  if [ -n "${CODETRACER_RR_BACKEND_PATH:-}" ]; then
    echo "codetracer-native-backend detected — running cross-repo tests..."
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
# CI runs this script in the required `ct-test-release-gate` job
# (.github/workflows/codetracer.yml); it needs no recorder siblings.
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
# CI runs this script in the required `ct-test-providers` job
# (.github/workflows/codetracer.yml), which checks the recorder siblings out
# via setup-dev-env first.
test-ct-providers:
  bash ci/test/ct-providers.sh

# Verify the `codetracer-desktop` component-bundle producer
# (`just build-desktop-component`) against the launcher's real contract:
# the bundle layout the launcher discovers, a byte-identical `capabilities`
# copy, agreement between the capability file's `bin` line and the produced
# filename, an executable core whose reported version matches the bundle's
# `@<ver>`, and a parse of the capability file through the launcher's OWN
# parser (`codetracer-launcher/src/caps.nim`, compiled from the sibling
# checkout).  Needs a built core (`just build-once`), the codetracer-launcher
# sibling, and `nim` on PATH — each missing prerequisite fails loudly rather
# than skipping.  See ci/test/desktop-component-bundle.sh.
test-desktop-component:
  bash ci/test/desktop-component-bundle.sh

# Verify that `resources/codetracer-desktop-capabilities` declares exactly the
# file extensions the core can actually record.  The expected set is recomputed
# from the production tables themselves
# (`src/ct/utilities/language_detection.nim`'s LANGS +
# `src/ct/trace/recorder_dispatch.nim`) by a checker compiled against them, so
# it cannot drift; both directions are enforced (nothing declared that the core
# cannot record, nothing recordable left undeclared — the `.js` routing bug).
# Five mutation scenarios prove the check has teeth, and the built core's
# `ct-describe-commands` file-types are compared against the same lists.  Needs
# `nim` on PATH and a built core (`just build-once`); a missing -- or stale --
# prerequisite fails loudly with a named remedy rather than skipping.
# See ci/test/desktop-capabilities-dispatch.sh.
test-desktop-capabilities:
  bash ci/test/desktop-capabilities-dispatch.sh

# End-to-end launcher <-> recorder compatibility gate: `ct record sample.py`
# driven through the REAL `ct` launcher binary, which routes from the
# codetracer-desktop capability file into the real desktop core, which
# dispatches the real recorder, whose CTFS trace is decoded and asserted with
# `ct-print` from codetracer-trace-format-nim.  This is the only gate that
# covers hop 1 (the launcher's router); `just test-ct-providers` drives the
# core directly and never sees it.  Scenarios, samples and expected trace
# shape all come from the recorder repo's own contract fixture
# (<recorder>/cross-repo/launcher-compat.yml), so a recorder that changes its
# CLI or handled extensions has to update that file in the same change.
# Needs the codetracer-launcher and recorder siblings, a built core
# (`just build-once`) and `ct-print`; every missing prerequisite fails loudly
# rather than skipping.  See ci/test/launcher-recorder-e2e.sh.
test-launcher-recorder-e2e recorder="codetracer-python-recorder" lang="python":
  bash ci/test/launcher-recorder-e2e.sh {{recorder}} {{lang}}

# Verify the CI WIRING of the gate above, which no linter covers: `actionlint`
# does not check a caller's `with:`/`secrets:` against a reusable workflow's
# declared `inputs:`, so a misspelled key that also leaves a required input
# unpassed lints clean and fails at run time.  This EXTRACTS the reusable
# workflow's "Plan the workspace layout" script from the YAML and RUNS it under
# each caller's `github.repository`, proving the triggering repo is never
# listed as its own sibling (`clone-siblings` would `rm -rf` the primary
# checkout), that every sibling entry is bare so its revision comes from the
# per-commit workspace lock, and that `.github/sibling-repos` declares every
# name the workflow can emit, and that the primary `actions/checkout` still
# pins the repo under test to the caller's `github.sha` expression -- since
# LRC-6 dropped the `*-ref` inputs, that one line IS the repo-under-test
# guarantee.  Thirteen mutations of real wiring, each of which must be
# rejected, plus a positive control, keep the checker itself honest.
# Stock bash: no Nix, no dev shell, no network.
# See ci/test/launcher-recorder-e2e-workflow-test.sh.
test-launcher-recorder-e2e-wiring:
  bash ci/test/launcher-recorder-e2e-workflow-test.sh

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
log name="ct-native-replay" worker_kind="stable" index="0" codetracer_tmp_dir="" run_name_or_last="last":
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
  killall -9 ct-native-replay || true

reset-config:
  rm --force  ~/.config/codetracer/.config.yaml && \
    mkdir -p ~/.config/codetracer/ && \
    cp -r src/config/default_config.yaml ~/.config/codetracer/.config.yaml

# Clear every persisted layout artifact and reseed the bundled default.
#
# The auto-hide strip is a SECOND persisted file (#608 gave it a real handler
# and a restore path), and `default_layout.json.broken` is the quarantined copy
# a failed repair leaves behind.  Both must be cleared here — a `reset-layout`
# that leaves a stale auto-hide state behind would restore panels the reseeded
# layout knows nothing about, which is the class of inconsistency #608 was
# reported for in the first place.
reset-layout:
  rm --force  ~/.config/codetracer/default_layout.json \
              ~/.config/codetracer/default_edit_layout.json \
              ~/.config/codetracer/default_layout.json.broken \
              ~/.config/codetracer/default_edit_layout.json.broken \
              ~/.config/codetracer/auto_hide_state.json && \
    mkdir -p ~/.config/codetracer/ && \
    cp -r src/config/default_layout.json ~/.config/codetracer/default_layout.json

# Cross-repo API contract: the `nim-agents` / `nim-acp` surface `ct` is built
# against. Compiles the exact calls `src/ct/review_session.nim` makes, so a
# sibling checkout at a revision that predates them fails in seconds with a
# named remedy, instead of as a type mismatch fifteen minutes into a full `ct`
# build that blames the caller. See the module header for why it asserts
# signatures rather than behaviour.
test-agent-api-contract:
  nim c -r --hints:off src/ct/agent_session_api_contract_test.nim

# originally by Pavel/Dimo in ci.sh; the check itself now lives in
# ci/test/nimsuggest-check.sh so `just test` and ci/lint/nim.sh share one
# implementation and one diagnosis.
#
# That script distinguishes the two things this check can mean. It fails (1)
# only when nimsuggest works on a file CodeTracer did not write but not on
# src/lsp.nim — the chronicles/distinct-type regression this check has always
# been for. When nimsuggest is broken for the whole project it returns 78, and
# this recipe reports that loudly and exits 0, because a known upstream crash
# must not stop `just test` from running everything after it. ci/lint/nim.sh
# reads the same 78 and records the step as QUARANTINED.
test-nimsuggest:
  #!/usr/bin/env bash
  rc=0
  ./ci/test/nimsuggest-check.sh || rc=$?
  if [ "$rc" -eq 78 ]; then
    echo
    echo "note: the nimsuggest check is QUARANTINED (upstream crash, see above)."
    echo "      It is not failing 'just test'. It re-arms itself automatically."
    exit 0
  fi
  exit "$rc"

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
  CT_BIN="${CODETRACER_BUILD_DIR:-$(pwd)/src/build-debug}/bin/ct"
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
  frontend_lang_test="$(mktemp "${TMPDIR:-/tmp}/codetracer-frontend-lang-test.XXXXXX.js")"
  scratchpad_dispatch_test="$(mktemp "${TMPDIR:-/tmp}/codetracer-scratchpad-add-dispatch-test.XXXXXX.js")"
  target_axes_js_test="$(mktemp "${TMPDIR:-/tmp}/codetracer-target-axes-js-test.XXXXXX.js")"
  ipc_registry_test="$(mktemp "${TMPDIR:-/tmp}/codetracer-ipc-registry-test.XXXXXX.js")"
  shortcut_bindings_test="$(mktemp "${TMPDIR:-/tmp}/codetracer-shortcut-bindings-test.XXXXXX.js")"
  debug_toolbar_tooltips_test="$(mktemp "${TMPDIR:-/tmp}/codetracer-debug-toolbar-tooltips-test.XXXXXX.js")"
  html_sinks_probe="$(mktemp "${TMPDIR:-/tmp}/codetracer-html-sinks-probe.XXXXXX.js")"
  trap 'rm -f "$frontend_lang_test" "$scratchpad_dispatch_test" "$target_axes_js_test" "$ipc_registry_test" "$shortcut_bindings_test" "$debug_toolbar_tooltips_test" "$html_sinks_probe"' EXIT
  echo "Running frontend language mapping tests..."
  nim -d:nodejs -d:chronicles_enabled=off -d:ctRenderer -d:ctInExtension \
    --out:"$frontend_lang_test" js src/frontend/tests/frontend_lang_test.nim
  node "$frontend_lang_test"
  echo ""
  # The JS half of the four-axis domain types' placement requirement.  The
  # native half is `src/tests/cli/target_axes_test.nim`, in `test-cli-record`.
  # Both are required: `src/common/target_axes.nim` and
  # `src/common/target_assessment.nim` exist to be reachable from EVERY front
  # end, so a build that only succeeds on one backend has not delivered the
  # property.  Compiling is itself part of the assertion -- a stray `std/jsffi`
  # or `os` dependency fails here and nowhere else.
  echo "Running four-axis domain type tests (JS backend)..."
  nim -d:nodejs -d:chronicles_enabled=off -d:ctRenderer -d:ctInExtension \
    --out:"$target_axes_js_test" js src/frontend/tests/target_axes_js_test.nim
  node "$target_axes_js_test"
  echo ""
  echo "Running scratchpad add-to-scratchpad dispatch tests..."
  nim -d:nodejs -d:chronicles_enabled=off -d:ctRenderer -d:ctInExtension \
    --out:"$scratchpad_dispatch_test" js src/frontend/tests/scratchpad_add_dispatch_test.nim
  # `types.nim` installs a `window.data` debugging hook at import time; node
  # has no `window`, so alias it to the global object before loading the
  # bundle.  Nothing else in this test needs a DOM.
  node -e 'globalThis.window = globalThis; require(process.argv[1])' "$scratchpad_dispatch_test"
  echo ""
  # `src/frontend/tests/ipc_registry_test.nim` imports `std/jsffi`, so the C
  # backend refuses it outright ("Module jsFFI is designed to be used with the
  # JavaScript backend").  It ran in no lane at all until this line existed —
  # two real cases over the socket-rebinding path that could not fail a build.
  # The shipped shortcut table binds what it names, and nothing landed in
  # `conflictList` -- where `initShortcutMap` silently DROPS a second claim on
  # a chord, producing an action with no keyboard and a menu item with no hint
  # beside it.  Needs the same `window` alias as the scratchpad suite, for the
  # same `types.nim` reason.
  echo "Running shipped shortcut binding tests..."
  nim -d:nodejs -d:chronicles_enabled=off -d:ctRenderer -d:ctInExtension \
    --out:"$shortcut_bindings_test" js src/frontend/tests/shortcut_bindings_test.nim
  node -e 'globalThis.window = globalThis; require(process.argv[1])' "$shortcut_bindings_test"
  echo ""
  # The same property one level up, for the debug toolbar: its tooltips must
  # NAME the bound chord rather than restate it.  They used to carry it as a
  # string literal ("Next (F10)"), which the IsoNim DSL paints once and never
  # updates -- correct by coincidence, and free to start lying the moment
  # anyone rebound a key.  Asserts all 13 controls resolve to a chord in the
  # SHIPPED table, and that rebinding one changes the rendered answer.  Same
  # `window` alias, same `types.nim` reason.
  echo "Running debug toolbar tooltip chord tests..."
  nim -d:nodejs -d:chronicles_enabled=off -d:ctRenderer -d:ctInExtension \
    --out:"$debug_toolbar_tooltips_test" js src/frontend/tests/debug_toolbar_tooltips_test.nim
  node -e 'globalThis.window = globalThis; require(process.argv[1])' "$debug_toolbar_tooltips_test"
  echo ""
  echo "Running IPC registry rebind tests..."
  nim -d:nodejs -d:chronicles_enabled=off -d:ctRenderer -d:ctInExtension \
    --out:"$ipc_registry_test" js src/frontend/tests/ipc_registry_test.nim
  node "$ipc_registry_test"
  echo ""
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
  # `--no-warnings` and NOT `| grep -v ExperimentalWarning`: a pipeline's exit
  # status is the LAST command's, so the old form reported grep's rc and a
  # failing test could not fail this lane.  The flag drops the same line and
  # keeps node's rc, which `set -e` above then honours.
  node --no-warnings --experimental-loader ./src/frontend/tests/css-loader.mjs src/frontend/tests/nimMonacoTokenizer.test.mjs
  echo ""
  # Does trace content reach monaco-editor 0.54.0's bundled DOMPurify 3.1.7?
  # The file itself is the answer; this line is what keeps it answered.
  echo "Running Monaco markdown sanitizer reachability tests..."
  node --no-warnings --experimental-loader ./src/frontend/tests/css-loader.mjs src/frontend/tests/monacoMarkdownSanitizer.test.mjs
  echo ""
  # The renderer's three non-Monaco `innerHTML` sinks: a workspace path in the
  # file-conflict dialog, a context-menu label, and a recorded program's own
  # output through ansi_up.  The probe is compiled WITHOUT `-d:nodejs` on
  # purpose -- with it, karax's `kdom` binds to an in-memory DOM emulation and
  # a test of what `innerHTML` does would be a test of the emulation.  Without
  # it the code reaches for browser globals, which the `.mjs` supplies from
  # jsdom, so the parser under test is a real one.
  echo "Running renderer HTML sink tests..."
  nim -d:chronicles_enabled=off -d:ctRenderer \
    --out:"$html_sinks_probe" js src/frontend/tests/html_sinks_probe.nim
  node --no-warnings src/frontend/tests/htmlSinks.test.mjs "$html_sinks_probe"

# Run the Playwright suite. Args are forwarded to `npx playwright test`.
#
# QUOTING: `{{args}}` interpolates the arguments *unquoted*, so a
# multi-word value is re-split by the shell here. This does NOT fail
# loudly — Playwright treats the stray words as additional FILE filters,
# collects every spec they match, and then dies inside some unrelated
# spec's module-level setup (a missing recorder, an unbuilt sibling).
# The error names a file you never asked for, so it looks like a broken
# tree rather than a mis-parsed filter.
#
#   WRONG:  just test-e2e tests/foo.spec.ts -g "welcome open folder"
#           -> `-g welcome` plus file filters `open`, `folder`
#   RIGHT:  just test-e2e tests/foo.spec.ts -g handoff
#           (a single-token regex; `.` matches a space if you need one)
#
# For anything that must contain a space, call Playwright directly:
#   cd src/tests/gui && npx playwright test <file> -g "two words"
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

# Compile + run the `ct record` CLI dispatch tests under src/tests/cli/.
#
# These are NOT ViewModel tests, so `test-vm-native`'s
# `find src/tests/gui/tests` glob does not reach them — this recipe is their
# runner, and `src/ct_test/release_gate.nim`'s `CliRecordGateTests` is the
# registry that says they must exist and must not be skip-disabled.  Both are
# needed: a test named only in the gate array runs nowhere, and a test only
# reachable by a glob has nothing asserting it still exists.
#
# The three files split by what they need:
#   record_dispatch_test.nim          — pure table, no toolchain, always runs.
#   record_missing_recorder_test.nim  — drives the built `ct` with the
#                                       recorders removed from its
#                                       environment; needs `just build-once`.
#   record_dispatch_e2e_test.nim      — records real programs with the real
#                                       recorder siblings; skips a language
#                                       whose sibling is unusable, but has a
#                                       zero-test guard so an all-skipped run
#                                       fails rather than passing vacuously.
test-cli-record: vm-test-prereqs
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-cli-record.log) 2>&1
  # Discover the sibling recorders the e2e test records with, the same way
  # test-vm-recorder-gated does.  Everything after this — which files, which
  # flags, how a run is classified — is ci/lib/run-nim-test-lane.sh, so this
  # recipe cannot drift away from the other lanes' reporting the way six
  # hand-copied loops did.
  source scripts/detect-siblings.sh
  bash ci/lib/run-nim-test-lane.sh cli-record

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
# The CT_TEST_LANGS environment variable filters which routed language test
# files are exercised. Accepts a comma-separated allowlist (case insensitive)
# of python/py, ruby/rb, and javascript/js/node. Unset or "all" runs those
# three suites. Explicitly empty values, empty tokens, unknown tokens and
# mixing "all" with another selector are errors.
#
# Examples:
#   CT_TEST_LANGS=python  just test-origin-dap
#   CT_TEST_LANGS=python,ruby just test-origin-dap
#   CT_TEST_LANGS=all just test-origin-dap   # same as unset
#
# Developer runs retain the suites' explicit optional-recorder skips. CI sets
# CT_ORIGIN_DAP_REQUIRED=1 for the Python-only per-PR gate; in that mode every
# Python prerequisite or query skip is a failure, and the gate proves that the
# exact seven named Python scenarios executed without a SKIPPED sentinel.
test-origin-dap:
  #!/usr/bin/env bash
  exec ./scripts/test-origin-dap.sh

# The WebAssembly boundary-recording checks: record each demo from this
# tree and replay it.
#
# These three fixtures — the imported-memory calldata demo (spec §3.3/§3.4),
# the NaN-payload demo, and the four-module parity corpus — each
# ship a `verify.sh` that was reachable only by knowing it existed. Nothing
# ran them, which is how one of them came to pass vacuously: its negative
# control edited the host state in the `boundary_state.json` sidecar only,
# and once the recorder started carrying the same state in the event stream
# too the replayer began refusing the edited recording outright instead of
# diverging. The control kept printing `ok` about a code path it had
# stopped reaching. A committed recording is what let that sit — it
# predated the in-stream carrier, so the edit still produced the old shape.
#
# Each script now records from the current tree (~40 s per fixture, cached
# by `scripts/materialize-recording.sh` and re-recorded when any recorder
# binary changes) and fails loudly rather than skipping.
#
# Needs the wazero replayer built (`just build` in codetracer-wasm-recorder).
verify-wasm-recordings:
  #!/usr/bin/env bash
  set -euo pipefail
  for fixture in wasm-memory-calldata wasm-nan-payloads wasm-parity-corpus; do
    echo "=== $fixture ==="
    ./src/db-backend/tests/fixtures/$fixture/verify.sh
  done
  echo "=== all WebAssembly boundary-recording checks passed ==="

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
# The three recordings are PRODUCED by the gate from the tree under test
# (`scripts/materialize-recording.sh`), not committed: a container written by
# today's recorder and replayed by today's replayer keeps passing after the
# recorder changes underneath it, which is the failure this suite exists to
# catch. The required gate fails closed when the pipeline cannot run, when a
# produced payload is incomplete, or when either Playwright spec, the built
# frontend or a display provider is absent. It validates exact Rust and
# Playwright manifests/counts and rejects every skip sentinel; missing coverage
# can never produce a successful CI result.
test-cross-process:
  #!/usr/bin/env bash
  exec ./scripts/test-cross-process.sh

# M29 — one-command demo launcher for the three-trace
# `account-balance-with-wasm` cross-tracer fixture.
#
# This recipe records the demo (through `scripts/materialize-recording.sh`,
# which is honestly gated on the wasm32 rustup target + ct-instrument +
# codetracer-js-recorder + session-manager + Playwright, and caches the
# result keyed on all of them) and then hands the `session.toml` manifest
# to `ct replay -t` so the GUI opens the three-trace session for manual
# chain-walking. Same production as the `test-cross-process` envelope,
# without the cargo / Playwright stages — the goal here is interactive
# inspection, not regression coverage.
#
# Doc page: docs/book/src/usage_guide/cross-tracer-demo.md.
demo-cross-tracer:
  #!/usr/bin/env bash
  set -euo pipefail
  echo "=== M29 cross-tracer demo — account-balance-with-wasm ==="

  # The recordings are produced, not committed. `materialize-recording.sh`
  # runs the five-stage pipeline the first time and serves its cache
  # afterwards, and re-runs it whenever the demo's sources or any of the
  # recorder binaries change — so what the GUI opens is always a recording
  # of the tree you are standing in.
  echo "[demo] Recording the three-tier demo from this tree (cached after the first run)"
  recordings="$(./scripts/materialize-recording.sh cross-process-three-trace)"
  session="$recordings/session.toml"
  [ -f "$session" ] || { echo "ERROR: no session manifest at $session" >&2; exit 1; }

  echo "[demo] Launching CodeTracer GUI with session manifest: $session"
  exec ct replay -t "$session"

# RS-M4 — one-command "watch HTTP requests arrive in CodeTracer".
#
# ############################################################################
# # THE SPANS ARE SYNTHESISED.  THE PANEL PATH IS REAL.                      #
# ############################################################################
#
# No language recorder emits `span_type: "web-request"` records yet — per
# language emission is RS-M5..RS-M9 (Python, Ruby, PHP, Elixir, JS), every one
# of which depends on RS-M4.  So this recipe cannot record a real server; it
# produces the container with the CANONICAL Nim writer instead
# (`codetracer-trace-format-nim`'s multi_stream_writer + span_stream, the same
# writer the recorders link and the same path
# `src/db-backend/tests/fixtures/span_stream/gen_span_fixtures.nim` uses).
#
# EVERYTHING DOWNSTREAM OF THE CONTAINER IS PRODUCTION CODE: `ct replay` opens
# it, the db-backend's Rust span reader decodes spans.dat/spans.idx, meta.dat
# bit 13 gates it, `ct/load-request-spans-since` tails it, and the Request
# Panel's ViewModel merges the deltas and renders the rows.
#
# RS-M5+ replaces the synthetic producer with a real server under its
# language's recorder and adds `just demo-request-panel <that lang>`.  Nothing
# else in this recipe changes: only who writes the span records.
#
# LANG selects the producer:
#
#   synthetic — the RS-M4 producer described above (no server, real container).
#   python    — RS-M5: a REAL Flask app served over real HTTP by a real recorded
#               process, whose middleware writes the span records itself.  The
#               container production lives in the sibling
#               `codetracer-python-recorder` repo (only it can record Python);
#               this recipe delegates to its
#               `just demo-request-panel-python` and then opens the result.
#   ruby      — RS-M6: the same, with a REAL Sinatra app and the Rack
#               middleware, produced by the sibling `codetracer-ruby-recorder`
#               repo's `just demo-request-panel-ruby`.
#   php       — RS-M7: a REAL `php -S` worker, one continuous recording whose
#               timeline is partitioned by the requests it served.
#   elixir    — RS-M8: a REAL Cowboy listener serving a real `Plug.Router`,
#               where each request is its own BEAM process and so its own
#               container thread.
#   js        — RS-M9: a REAL Express app on a real `http.Server`, where every
#               request is a slice of ONE event loop.  CODETRACER_DEMO_SCHEDULE
#               picks `sequential` (the default) or `concurrent`, which
#               interleaves the handlers so their step ranges overlap.
#   native    — RS-M10: a REAL nginx recorded by `ct-mcr`, where NOTHING in the
#               recorded program knows what a request is.  There is no
#               middleware seam in nginx and the recorder records syscalls, so
#               the spans are DISCOVERED afterwards from the recording's own
#               `recv` / `writev` payloads and appended to the container.
#
# Each language milestone adds its own value the same way.  See the "Trying it" section of
# codetracer-specs/GUI/Core-Panes/Request-Panel.md.
demo-request-panel LANG="synthetic":
  #!/usr/bin/env bash
  set -euo pipefail
  echo "=== Request Panel demo — {{LANG}} ==="

  if [ "{{LANG}}" = "python" ]; then
    # RS-M5.  The recorder sibling records the demo app into $CODETRACER_DEMO_DIR
    # and prints the spans it wrote; the GUI half stays here so every language
    # opens the session exactly the same way.
    demo_dir="${CODETRACER_DEMO_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/codetracer/demos/request-panel-python}"
    recorder_repo="${CODETRACER_PYTHON_RECORDER_DIR:-$(pwd)/../codetracer-python-recorder}"
    if [ ! -f "$recorder_repo/Justfile" ]; then
      {
        echo "ERROR: no codetracer-python-recorder checkout at $recorder_repo."
        echo "The Python demo records a real Flask app with that recorder, so the"
        echo "sibling repo has to be present (override with"
        echo "CODETRACER_PYTHON_RECORDER_DIR=/path/to/codetracer-python-recorder)."
      } >&2
      exit 1
    fi
    echo "[demo] recording the Flask demo app with the Python recorder"
    # Its own dev shell: the recorder needs its Rust/maturin toolchain and its
    # uv environment, neither of which is in codetracer's shell.
    # CODETRACER_DEMO_RECORD_ONLY keeps the sibling recipe from opening its own
    # GUI: `ct` is on PATH inside this shell, and two replays of one session is
    # not what the demo promises.
    (
      cd "$recorder_repo"
      CODETRACER_DEMO_DIR="$demo_dir" CODETRACER_DEMO_RECORD_ONLY=1 \
        direnv exec . just demo-request-panel-python flask
    )
    # `ct print -f http` reads spans.dat through the Nim reader, so a failure to
    # render in the GUI stays distinguishable from a failure to record.
    ct print -f http "$demo_dir" || true
    echo "[demo] launching the GUI; the REQUESTS panel docks itself once the"
    echo "[demo] first delta arrives (bottom edge strip if you close it)."
    exec ct replay -t "$demo_dir"
  fi

  if [ "{{LANG}}" = "ruby" ]; then
    # RS-M6.  Same shape as the Python arm above: the recorder sibling records
    # the demo app into $CODETRACER_DEMO_DIR and prints the spans it wrote; the
    # GUI half stays here so every language opens the session the same way.
    demo_dir="${CODETRACER_DEMO_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/codetracer/demos/request-panel-ruby}"
    recorder_repo="${CODETRACER_RUBY_RECORDER_DIR:-$(pwd)/../codetracer-ruby-recorder}"
    if [ ! -f "$recorder_repo/Justfile" ]; then
      {
        echo "ERROR: no codetracer-ruby-recorder checkout at $recorder_repo."
        echo "The Ruby demo records a real Sinatra app with that recorder, so the"
        echo "sibling repo has to be present (override with"
        echo "CODETRACER_RUBY_RECORDER_DIR=/path/to/codetracer-ruby-recorder)."
      } >&2
      exit 1
    fi
    echo "[demo] recording the Sinatra demo app with the Ruby recorder"
    # Its own dev shell: the recorder needs its Rust toolchain and a Ruby with
    # Sinatra and Rails, none of which is in codetracer's shell.
    # CODETRACER_DEMO_RECORD_ONLY keeps the sibling recipe from opening its own
    # GUI: `ct` is on PATH inside this shell, and two replays of one session is
    # not what the demo promises.
    (
      cd "$recorder_repo"
      CODETRACER_DEMO_DIR="$demo_dir" CODETRACER_DEMO_RECORD_ONLY=1 \
        direnv exec . just demo-request-panel-ruby sinatra
    )
    # `ct print -f http` reads spans.dat through the Nim reader, so a failure to
    # render in the GUI stays distinguishable from a failure to record.
    ct print -f http "$demo_dir" || true
    echo "[demo] launching the GUI; the REQUESTS panel docks itself once the"
    echo "[demo] first delta arrives (bottom edge strip if you close it)."
    exec ct replay -t "$demo_dir"
  fi

  if [ "{{LANG}}" = "php" ]; then
    # RS-M7.  Same shape as the Python and Ruby arms: the recorder sibling
    # records the demo app into $CODETRACER_DEMO_DIR and prints the spans it
    # wrote; the GUI half stays here so every language opens the session the
    # same way.
    demo_dir="${CODETRACER_DEMO_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/codetracer/demos/request-panel-php}"
    recorder_repo="${CODETRACER_PHP_RECORDER_DIR:-$(pwd)/../codetracer-php-recorder}"
    if [ ! -f "$recorder_repo/Justfile" ]; then
      {
        echo "ERROR: no codetracer-php-recorder checkout at $recorder_repo."
        echo "The PHP demo records a real \`php -S\` server with that recorder, so"
        echo "the sibling repo has to be present (override with"
        echo "CODETRACER_PHP_RECORDER_DIR=/path/to/codetracer-php-recorder)."
      } >&2
      exit 1
    fi
    echo "[demo] recording the PHP demo app with the PHP recorder"
    # Its own dev shell: the recorder needs php with development headers and
    # phpize to build its C extension, neither of which is in codetracer's shell.
    # CODETRACER_DEMO_RECORD_ONLY keeps the sibling recipe from opening its own
    # GUI: `ct` is on PATH inside this shell, and two replays of one session is
    # not what the demo promises.
    (
      cd "$recorder_repo"
      CODETRACER_DEMO_DIR="$demo_dir" CODETRACER_DEMO_RECORD_ONLY=1 \
        direnv exec . just demo-request-panel-php builtin
    )
    # A PHP worker owns its recording, so the container lives under
    # $demo_dir/worker_<pid>/; the recipe leaves the path it used in a marker
    # file rather than making this side guess the worker's pid.
    worker_dir="$(cat "$demo_dir/.worker_dir")"
    # `ct print -f http` reads spans.dat through the Nim reader, so a failure to
    # render in the GUI stays distinguishable from a failure to record.
    ct print -f http "$worker_dir" || true
    echo "[demo] launching the GUI; the REQUESTS panel docks itself once the"
    echo "[demo] first delta arrives (bottom edge strip if you close it)."
    exec ct replay -t "$worker_dir"
  fi

  if [ "{{LANG}}" = "elixir" ]; then
    # RS-M8.  Same shape as the Python, Ruby and PHP arms: the recorder sibling
    # records the demo app into $CODETRACER_DEMO_DIR and prints the spans it
    # wrote; the GUI half stays here so every language opens the session the
    # same way.
    demo_dir="${CODETRACER_DEMO_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/codetracer/demos/request-panel-elixir}"
    recorder_repo="${CODETRACER_BEAM_RECORDER_DIR:-$(pwd)/../codetracer-beam-recorder}"
    framework="${CODETRACER_DEMO_FRAMEWORK:-plug}"
    if [ ! -f "$recorder_repo/Justfile" ]; then
      {
        echo "ERROR: no codetracer-beam-recorder checkout at $recorder_repo."
        echo "The Elixir demo records a real Cowboy listener with that recorder,"
        echo "so the sibling repo has to be present (override with"
        echo "CODETRACER_BEAM_RECORDER_DIR=/path/to/codetracer-beam-recorder)."
      } >&2
      exit 1
    fi
    echo "[demo] recording the Elixir demo app with the BEAM recorder ($framework)"
    # Its own dev shell: the recorder needs erlang, elixir, rebar3 and a cargo
    # toolchain, none of which are in codetracer's shell.
    # CODETRACER_DEMO_RECORD_ONLY keeps the sibling recipe from opening its own
    # GUI: `ct` is on PATH inside this shell, and two replays of one session is
    # not what the demo promises.
    (
      cd "$recorder_repo"
      CODETRACER_DEMO_DIR="$demo_dir" CODETRACER_DEMO_RECORD_ONLY=1 \
        direnv exec . just demo-request-panel-elixir "$framework"
    )
    # `ct print -f http` reads spans.dat through the Nim reader, so a failure to
    # render in the GUI stays distinguishable from a failure to record.
    ct print -f http "$demo_dir" || true
    echo "[demo] launching the GUI; the REQUESTS panel docks itself once the"
    echo "[demo] first delta arrives (bottom edge strip if you close it)."
    exec ct replay -t "$demo_dir"
  fi

  if [ "{{LANG}}" = "js" ]; then
    # RS-M9.  Same shape as the Python, Ruby, PHP and Elixir arms: the recorder
    # sibling records the demo app into $CODETRACER_DEMO_DIR and prints the
    # spans it wrote; the GUI half stays here so every language opens the
    # session the same way.
    demo_dir="${CODETRACER_DEMO_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/codetracer/demos/request-panel-js}"
    recorder_repo="${CODETRACER_JS_RECORDER_DIR:-$(pwd)/../codetracer-js-recorder}"
    schedule="${CODETRACER_DEMO_SCHEDULE:-sequential}"
    if [ ! -f "$recorder_repo/Justfile" ]; then
      {
        echo "ERROR: no codetracer-js-recorder checkout at $recorder_repo."
        echo "The JS demo records a real Express server with that recorder, so"
        echo "the sibling repo has to be present (override with"
        echo "CODETRACER_JS_RECORDER_DIR=/path/to/codetracer-js-recorder)."
      } >&2
      exit 1
    fi
    echo "[demo] recording the Express demo app with the JS recorder ($schedule)"
    # Its own dev shell: the recorder needs node, npm and a cargo toolchain to
    # build its napi-rs addon, none of which is in codetracer's shell.
    # CODETRACER_DEMO_RECORD_ONLY keeps the sibling recipe from opening its own
    # GUI: `ct` is on PATH inside this shell, and two replays of one session is
    # not what the demo promises.
    (
      cd "$recorder_repo"
      CODETRACER_DEMO_DIR="$demo_dir" CODETRACER_DEMO_RECORD_ONLY=1 \
        direnv exec . just demo-request-panel-js "$schedule"
    )
    # The recorder writes `<out>/trace-<n>/`; the recipe leaves the path it
    # used in a marker file rather than making this side guess the handle.
    trace_dir="$(cat "$demo_dir/.trace_dir")"
    # `ct print -f http` reads spans.dat through the Nim reader, so a failure to
    # render in the GUI stays distinguishable from a failure to record.
    ct print -f http "$trace_dir" || true
    echo "[demo] launching the GUI; the REQUESTS panel docks itself once the"
    echo "[demo] first delta arrives (bottom edge strip if you close it)."
    exec ct replay -t "$trace_dir"
  fi

  if [ "{{LANG}}" = "native" ]; then
    # RS-M10.  Same shape as the arms above, with one difference that is the
    # whole point of the milestone: the recorder sibling does not instrument
    # the server at all.  It records a real nginx with `ct-mcr`, then reads
    # that container's own OS events back and writes the request spans it
    # discovers into the same container.
    demo_dir="${CODETRACER_DEMO_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/codetracer/demos/request-panel-native}"
    recorder_repo="${CODETRACER_NATIVE_RECORDER_DIR:-$(pwd)/../codetracer-native-recorder}"
    if [ ! -f "$recorder_repo/Justfile" ]; then
      {
        echo "ERROR: no codetracer-native-recorder checkout at $recorder_repo."
        echo "The native demo records a real nginx with ct-mcr, so the sibling"
        echo "repo has to be present (override with"
        echo "CODETRACER_NATIVE_RECORDER_DIR=/path/to/codetracer-native-recorder)."
      } >&2
      exit 1
    fi
    echo "[demo] recording nginx with ct-mcr"
    # Its own dev shell: the recorder needs its Nim/Rust toolchain and ships
    # the nginx the recording runs, neither of which is in codetracer's shell.
    (
      cd "$recorder_repo"
      CODETRACER_DEMO_DIR="$demo_dir" direnv exec . just demo-request-panel-native
    )
    # ct-mcr writes ONE container per recording; the recipe leaves the path it
    # used in a marker file rather than making this side guess the name.
    trace_file="$(cat "$demo_dir/.trace_file")"
    # `ct print -f http` reads spans.dat through the Nim reader, so a failure to
    # render in the GUI stays distinguishable from a failure to record.
    ct print -f http "$trace_file" || true
    echo "[demo] launching the GUI; the REQUESTS panel docks itself once the"
    echo "[demo] first delta arrives (bottom edge strip if you close it)."
    # `-t` names the trace DIRECTORY, which `importTrace` then searches for the
    # `.ct` container — the same thing every other arm above passes.  Handing it
    # the container file instead fails in `importTrace` with "no `.ct` CTFS
    # container found in <file>" before the GUI is ever reached.  `ct print`
    # above is the one that takes the container path itself.
    exec ct replay -t "$demo_dir"
  fi

  if [ "{{LANG}}" != "synthetic" ]; then
    {
      echo "ERROR: no recorder emits web-request spans for '{{LANG}}' yet."
      echo
      echo "Today:  just demo-request-panel synthetic"
      echo "        just demo-request-panel python"
      echo "        just demo-request-panel ruby"
      echo "        just demo-request-panel php"
      echo "        just demo-request-panel elixir      # CODETRACER_DEMO_FRAMEWORK=plug|phoenix"
      echo "        just demo-request-panel js          # CODETRACER_DEMO_SCHEDULE=sequential|concurrent"
      echo "        just demo-request-panel native      # nginx under ct-mcr; spans are DISCOVERED"
    } >&2
    exit 1
  fi

  demo_dir="${CODETRACER_DEMO_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/codetracer/demos/request-panel}"
  work="${TMPDIR:-/tmp}/ct-demo-request-panel"
  mkdir -p "$work"

  if ! command -v nim >/dev/null 2>&1; then
    {
      echo "ERROR: no 'nim' on PATH.  The demo container is written by the"
      echo "canonical Nim writer, so this recipe needs the dev shell:"
      echo "  direnv exec . just demo-request-panel {{LANG}}"
    } >&2
    exit 1
  fi

  echo "[demo] compiling the container producer (canonical Nim writer)"
  nim c -d:release --hints:off --warnings:off \
    --out:"$work/demo_request_session" \
    src/tools/demo_request_session.nim

  echo "[demo] producing the demo container in $demo_dir"
  rm -rf "$demo_dir"
  container=$("$work/demo_request_session" "$demo_dir")
  echo "[demo] wrote $container"

  # Show what the panel is about to display, straight out of the container,
  # so a failure to render in the GUI is distinguishable from a failure to
  # record.  `ct print -f http` reads spans.dat through the Nim reader.
  ct print -f http "$demo_dir" || true

  echo "[demo] launching the GUI; the REQUESTS panel docks itself once the"
  echo "[demo] first delta arrives (bottom edge strip if you close it)."
  exec ct replay -t "$demo_dir"

# RS-M4 — the same demo, but the container GROWS while the GUI watches it, so
# rows appear live and one request is seen in flight before it settles.
#
# The in-flight row is a real observation, not a figure of speech.  One stage
# (`--through=6 --open-only`) stops INSIDE request 6: its open span record is
# published, its completion is not.  That stage has to exist as its own step,
# because a stage that published the open record and its completion together
# would be one atomic rename, and the backend applies `resolve_spans` WITHIN a
# delta — the panel would only ever see the settled row.  With the extra step
# the panel shows request 6 greyed and status-less for one interval, then
# settles it.
#
# Read the header of `demo-request-panel` first: the spans are synthesised the
# same way here.  One extra caveat is specific to this recipe:
# `MultiStreamTraceWriter` builds its container IN MEMORY and serialises at
# close (see `flushSpans`' own docs in
# codetracer-trace-format-nim/src/codetracer_trace_writer/multi_stream_writer.nim),
# so the grower rewrites the whole image and renames it into place rather than
# appending to a live file.  Every stage nonetheless re-seals its earlier chunks
# to the SAME bytes — seal points and record contents are both derived from the
# request index, never from the stage count — so each stage's span stream is a
# strict CHUNK PREFIX of the next, which is exactly what the backend's
# chunk-count cursor requires.  The whole reader half is therefore genuinely
# exercised: held reader, per-poll delta, `reset` only on the first poll,
# client-side last-record-wins across deltas.  True in-place append needs the
# writer built on `createCtfsStreaming(path)`; that is a writer change, not a
# panel change.
#
# Both properties are asserted headlessly by
# src/tests/gui/tests/request-panel/demo_recipe_vm_test.nim, over the same stage
# sequence the loop below walks.
demo-request-panel-live LANG="synthetic" INTERVAL="2":
  #!/usr/bin/env bash
  set -euo pipefail
  echo "=== RS-M4 Request Panel demo (live session) — {{LANG}} ==="

  if [ "{{LANG}}" != "synthetic" ]; then
    echo "ERROR: only 'synthetic' exists today; see just demo-request-panel." >&2
    exit 1
  fi

  demo_dir="${CODETRACER_DEMO_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/codetracer/demos/request-panel-live}"
  work="${TMPDIR:-/tmp}/ct-demo-request-panel"
  mkdir -p "$work"

  if ! command -v nim >/dev/null 2>&1; then
    echo "ERROR: no 'nim' on PATH; run under 'direnv exec .'." >&2
    exit 1
  fi

  echo "[demo] compiling the container producer"
  nim c -d:release --hints:off --warnings:off \
    --out:"$work/demo_request_session" \
    src/tools/demo_request_session.nim

  echo "[demo] seeding the session with its first request"
  rm -rf "$demo_dir"
  "$work/demo_request_session" "$demo_dir" --through=1 >/dev/null

  # Grow the session in the background while the GUI tails it.  The GUI polls
  # `ct/load-request-spans-since` every 500 ms, so a 2 s stage interval makes
  # each new row visibly arrive on its own.
  #
  # The `--open-only` element is the in-flight step: it adds request 6's open
  # record and nothing else, so the panel renders it as in flight until the next
  # stage — one interval later — appends the completion.
  stages=(
    "--through=2"
    "--through=3"
    "--through=4"
    "--through=5"
    "--through=6 --open-only"
    "--through=6"
    "--through=7"
    "--through=8"
  )
  (
    for stage in "${stages[@]}"; do
      sleep "{{INTERVAL}}"
      # Unquoted on purpose: an element may carry two flags.
      "$work/demo_request_session" "$demo_dir" $stage >/dev/null
      echo "[demo] session grew: $stage"
    done
    echo "[demo] session complete (8 requests)"
  ) &

  # `ct replay` execv()s into Electron on POSIX, so this shell is replaced and
  # never reaches a `wait`.  The grower is already a detached child and keeps
  # feeding the container; it exits on its own after the eighth stage.
  echo "[demo] launching the GUI — watch rows appear in the REQUESTS panel"
  exec ct replay -t "$demo_dir"

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
# Cross-repo integration tests (requires codetracer-native-backend)
# These tests build/find ct-native-replay from the native-backend repo and run
# the flow integration tests against it.

cross-test:
  bash scripts/run-cross-repo-tests.sh all

cross-test-nim-flow:
  bash scripts/run-cross-repo-tests.sh nim-flow

cross-test-rust-flow:
  bash scripts/run-cross-repo-tests.sh rust-flow

cross-test-go-flow:
  bash scripts/run-cross-repo-tests.sh go-flow

# Note: cross-repo sibling revisions are no longer pinned in repo-local files.
# They are resolved from the repo-workspaces workspace lock via
# scripts/resolve-sibling-rev.sh (see
# codetracer-specs/Testing/Cross-Repo-CI-Integration.md). To test against a
# specific sibling revision, set the RR_BACKEND_REF override or use the
# workflow_dispatch inputs.

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
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-vm-native.log) 2>&1
  # Which files this lane runs, and which flags they need, is
  # ci/lib/test-lane-files.sh; how a run is compiled, executed and classified
  # is ci/lib/run-nim-test-lane.sh.  Both details used to live inline here, in
  # a loop that five other recipes had each copied and then drifted from.
  #
  # Two behaviours that were hard-won and now live in the runner, so every lane
  # gets them:
  #
  #   * Compile and run are SEPARATE steps.  As one `nim c -r` they were not:
  #     `welcome_screen_vm_test` compiles perfectly and then dies at process
  #     start with `could not load: libsqlite3.so(|.0)` because it dlopen's
  #     sqlite through db_connector.  The old reporting called that a "COMPILE
  #     ERROR" and printed only lines matching `Error:` — which that diagnostic
  #     does not match, so the one line naming the missing library was thrown
  #     away and all anybody saw was `execution of an external program failed`.
  #
  #   * The RUN inherits CT_LD_LIBRARY_PATH (the dev shell's
  #     sqlite/pcre/glib/openssl/zstd set); the COMPILE does not, so those
  #     libraries never get in front of the Nim compiler's own loader path.
  bash ci/lib/run-nim-test-lane.sh vm-native

# Compile and run JS-compatible ViewModel headless tests via nim js + node.
# Skips tests that require native process spawning (stdio_backend, headless_session).
# Also skips request-panel/demo_recipe_vm_test.nim (RS-M4),
# request-panel/python_request_panel_vm_test.nim (RS-M5),
# request-panel/ruby_request_panel_vm_test.nim (RS-M6),
# request-panel/php_request_panel_vm_test.nim (RS-M7),
# request-panel/elixir_request_panel_vm_test.nim (RS-M8),
# request-panel/js_request_panel_vm_test.nim (RS-M9),
# request-panel/native_request_panel_vm_test.nim (RS-M10),
# request-panel/remote_request_panel_vm_test.nim (RS-M11) and
# request-panel/request_span_conformance_test.nim (RS-M12, which reads all six
# of those containers at once): the first writes a
# real `.ct` container with the canonical Nim writer, the next six read one
# recorded by the Python, Ruby, PHP, BEAM and JS recorders and by `ct-mcr`,
# and all seven link zstd through a C FFI that has no `nim js` equivalent.
# RS-M11's is excluded for a different reason: it replays a delta capture and
# the span-stream ground truth from disk, and `std/os` file reads are not
# available on the `nim js` backend.
# They run in test-vm-native and are registered in release_gate.nim's
# CoreViewModelGateTests.
test-vm-js: vm-test-prereqs
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-vm-js.log) 2>&1
  # Same runner as the native lane; ci/lib/test-lane-files.sh derives this
  # lane's file set FROM the native lane's, minus what cannot compile or run
  # under `nim js`, so the two can no longer disagree about the shared part.
  #
  # `-d:nodejs` is applied by the runner and is load-bearing, not decoration.
  # Nim auto-defines `nodejs` only for `nim js -r`; this lane compiles and runs
  # as separate steps, so without the explicit define
  # `std/exitprocs.setProgramResult` is undeclared, `std/unittest` substitutes
  # a no-op, and node exits 0 even when a test fails.  The compiler says so:
  #
  #     unittest.nim: Warning: setProgramResult not available on platform,
  #       unittest will not give failing exit code on test failure
  #
  # and the old `>/dev/null 2>&1` on the compile threw that warning away.
  bash ci/lib/run-nim-test-lane.sh vm-js

# Run ViewModel headless tests on both native and JS backends.
test-vm: test-vm-native test-vm-js

# ====
# Lanes converted from hand-maintained path lists to DISCOVERY.
#
# Everything below shares one runner (ci/lib/run-nim-test-lane.sh) and one file
# selector (ci/lib/test-lane-files.sh).  That split is the point: a lane is now
# DATA — "this directory, this pattern, these flags" — so a new test file in a
# covered directory is picked up by its lane with nobody editing anything, and
# `just test-lane-coverage` fails BY NAME on any test-shaped file that still
# matches no lane.
#
# Before this existed, 61 test-shaped `.nim` files carrying real `suite`/`test`
# blocks ran in no lane at all, including all five `src/common/*_test.nim` —
# among them `trace_index_test.nim`, the M-REC-8 recording-id identity suite
# the artifact store's id decision rests on — and every
# `src/ct_test/incremental/test_*.nim`.  `src/ct/utilities/zip_test.nim` had
# rotted into a file that did not even parse, which is what happens to code
# nothing compiles.
#
# ---------------------------------------------------------------------------
# DEFERRED, AND SAY SO: NONE OF THE 13 RECIPES BELOW IS IN A PIPELINE YET.
# ---------------------------------------------------------------------------
# "Picked up by its lane" is NOT the same as "runs in CI", and for these
# thirteen the second is currently false.  No workflow, no entry in
# ci/verdict/required-jobs.txt, and no aggregate recipe invokes any of them —
# 76 of the 220 files the lane library resolves are in lanes no pipeline runs
# (`test_lane_all_files | wc -l` for the 220; the reachable 144 are the lanes
# behind `just test-vm`, `test-cli-record`, `test-ct-trace-units`,
# `test-mcr-enrichment-units`, `test-m16-release-gate`, `test-ct-providers`,
# `test-visual-replay-gate`, `test-vm-recorder-gated` and
# `test-no-sidecar-manifests`).  A reader who assumed otherwise would be repeating this
# campaign's own mistake one level up, so it is written down here rather than
# left to be discovered.
#
# WHY it is deferred: six of these lanes are red for reasons that are not
# theirs to fix, and wiring a red lane into a required job breaks every build
# for everybody:
#
#   test-frontend-units          cross_process_origin_vm_test needs an
#                                uncommitted rr/MCR cross-process recording
#   test-vm-collab-units         the collab signal registry has drifted from
#                                the ViewModels (30 unclassified, 1 stale) —
#                                a real, pre-existing red
#   test-vm-collab-integration   test_collab_m8_cross_frontend needs
#                                libgpui_nim_shim.so
#   test-ct-test-incremental     test_io_mon_readfiles_materialized asserts an
#                                insertion order the impl returns sorted
#   test-vm-gui-headless         noir_space_ship_test: recorded traces come
#                                back "unrecognized format"; real_backend_test
#                                needs the Python recorder installed
#   test-ct-test-incremental-e2e needs a buildable Python recorder sibling
#
# `test-online-sharing-compile` was the seventh until AS-2
# (Sharing/Artifact-Store.milestones.org) brought `online_sharing_test.nim`'s
# call sites up to date; it is green now, and the three signatures it had
# rotted against were the same three defects AS-2 closed (a `uploadTrace` that
# never returned, a `fileId` holding two namespaces, and a `downloadKey`
# nothing assigned).  Its lane still never RUNS the file — a live round-trip
# against the production sharing service must not — only compiles it.
#
# The five that are GREEN today and could be promoted as-is:
#   test-common-units  test-ct-cli-units  test-book-isonim
#   test-online-sharing-compile
#   test-lane-coverage (already runs, via ci/lint/nim.sh)
#
# `test-vm-unit` LEFT that list on 2026-09-01, and `test-vm-unit-js` with it,
# because Edit-Mode-Toolbar.md's three specifying suites landed ahead of the
# implementation they specify.  `viewmodel/viewmodels/edit_mode_toolbar.nim`
# has since landed and 24 of those 27 checks went green.  **Both lanes are
# still red, on 3 checks, and both are still NOT promotable** — the count is
# down, the reason has changed, and neither is zero:
#
#   src/frontend/viewmodel/tests/unit/test_edit_mode_toolbar_languages.nim
#       17 OK, 0 FAILED   <- green; its ledger row was deleted
#   src/frontend/viewmodel/tests/unit/test_edit_mode_toolbar_model.nim
#       16 OK, 1 FAILED
#   src/frontend/viewmodel/tests/unit/test_noir_build_diagnostics.nim
#       4 OK, 2 FAILED
#
# All three remaining reds are DEFECTIVE ASSERTIONS, not missing product code,
# and each is diagnosed at the line and in the ledger row.  Two require a
# per-line pure function to know a severity and a message that `nargo` puts on
# the line ABOVE it; the third asserts `declared.build.command != "cargo"`
# against a fixture whose every task runs `cargo`.  The behaviour all three are
# about IS asserted and green elsewhere in the same files.
#
# They were left failing rather than relaxed to fit.  Correcting an assertion
# is a decision for whoever owns the suite, and a lane made green by softening
# the check that caught something is worth less than a red one.
#
# Rows, evidence and the retirement condition:
# codetracer-specs/Testing/Known-Test-Failures.md, "Specifying suites".
# Mutation arms: src/frontend/viewmodel/tests/unit/run-edit-mode-toolbar-mutations.py
# (17/18 arms remain; M9 retired with the expired starting-state check it
#  killed.  17/17 killed, each by its own named check, on both backends.)
#
# DO NOT make these lanes green by deleting or skipping a suite.  If one is in
# your way, the answer is in the ledger row, and `release_gate.nim` will fail
# the m16 lane if you try — all three are registered in CoreViewModelGateTests
# for precisely that reason.
# (`test-lanes` is the thirteenth recipe; it prints lane contents and runs
#  nothing, so it is neither red nor promotable.)
#
# What IS closed regardless of the above: the guard.  `test-lane-coverage`
# runs in the `lint-nim` job, so a NEW dark file is caught on every push even
# while these lanes wait for a pipeline.  The deferral is about running the
# 61 rescued files in CI, not about the class staying closed.

# The guard that closes the class: every test-shaped Nim file must be run by a
# lane or declare, in itself, that it is not a test of this repo.  Pure bash +
# git, no toolchain, runs in about a second — it is wired into `ci/lint/nim.sh`
# so the answer arrives in the lint stage rather than after a build.
test-lane-coverage:
  bash ci/test/test-lane-coverage.sh

# Print what each lane runs, without running anything.  Useful when deciding
# where a new test file belongs.
test-lanes:
  #!/usr/bin/env bash
  set -euo pipefail
  source ci/lib/test-lane-files.sh
  while read -r lane; do
    printf '%s — %s\n' "$lane" "$(test_lane_description "$lane")"
    test_lane_files "$lane" | sed 's/^/    /'
  done < <(test_lane_ids)

# src/common unit suites.  ALL FIVE ran in no lane until this recipe existed,
# `trace_index_test.nim` — the M-REC-8 recording-id identity suite — among them.
test-common-units:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-common-units.log) 2>&1
  bash ci/lib/run-nim-test-lane.sh common-units

# The `ct` CLI's unit suites outside src/ct/trace: the three
# src/ct/launch/*_test.nim, src/ct/test_sourcemap.nim and
# src/ct/utilities/zip_test.nim.  Needs `--mm:refc` because src/ct/sourcemap.nim
# calls `GC_disable`, which does not exist under ORC.
test-ct-cli-units:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-ct-cli-units.log) 2>&1
  bash ci/lib/run-nim-test-lane.sh ct-cli-units

# src/frontend/tests suites that compile with the C backend.  Six of the eight
# files in that directory ran nowhere; the other two are `just test-frontend-js`.
test-frontend-units:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-frontend-units.log) 2>&1
  # `idle_timeout_integration_test.nim` launches the real `ct host` (node +
  # server_index.js) and finds it through `codetracerExeDir`, which resolves
  # from CODETRACER_PREFIX outside the `ct` entrypoint.  Without this the
  # lookup lands in the nimcache directory the test binary happens to sit in,
  # server_index.js is not there, and the suite reports six failures rather
  # than the skip it intends -- `std/unittest`'s `skip()` MARKS a case but does
  # not leave its body, so each guarded test ran on anyway.  Pointing at the
  # build tree makes all seven cases run for real.
  export CODETRACER_PREFIX="${CODETRACER_PREFIX:-$PWD/src/build-debug}"
  bash ci/lib/run-nim-test-lane.sh frontend-native-units

# ViewModel unit suites under src/frontend/viewmodel/tests/unit that are
# neither recorder-gated nor collab.  Discovery: anything added to that
# directory lands here without an edit.
test-vm-unit: vm-test-prereqs
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-vm-unit.log) 2>&1
  bash ci/lib/run-nim-test-lane.sh vm-unit

# The same Tier-1 ViewModel suites under `nim js` + node.
#
# Front-End-Architecture.md §6 asks for the pyramid "run on both the C and JS
# backends", and `test-vm-unit` is a C lane while `test-vm-js` reaches only
# `src/tests/gui/tests` — so until this recipe existed every suite under
# `viewmodel/tests/unit` ran on one backend of the two, including the Embed
# SDK's own conformance suite.  That is not a rounding error for a web
# debugger: the first run of this lane found `DebuggerSession.launch`
# reporting `dspReady` for a launch the backend had refused, because
# `async_compat.onComplete` queues callbacks on JS and runs them inline on
# native.  ci/lib/test-lane-files.sh carries the file-by-file reasoning.
test-vm-unit-js: vm-test-prereqs
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-vm-unit-js.log) 2>&1
  bash ci/lib/run-nim-test-lane.sh vm-unit-js

# NS1's compile-time gate: no module of the ViewModel, view, store or platform
# layer may reach the host except through the platform facade.
#
# This is a BUILD property, not a value, so it cannot be a Nim suite: the
# assertion is that certain source does not compile.  ci/test/hostfree-build.sh
# compiles all 119 modules of the surface with the host poisoned, then plants a
# `readFile` and a `startProcess` into a real front-end module and requires each
# to be rejected — and, crucially, requires the same two plants to COMPILE under
# the normal build, without which the first two scenarios would score green
# while the gate did no work at all.
#
# Runtime is dominated by scenario 1's 119 compiles (~15 min).  It is a separate
# recipe rather than a lint step for that reason: ci/lint/nim.sh is the
# sub-second-answers stage, and burying a quarter-hour compile in it is how a
# lint stage stops being run.
#
# NS1 host-free build gate: front-end code cannot reach the host except through the platform facade.
test-hostfree:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-hostfree.log) 2>&1
  bash ci/test/hostfree-build.sh

# The thirteen `test_collab_*.nim` suites, split by what they need.  The unit
# half is pure Nim and cheap; the integration/soak half opens real localhost
# sockets and links the GPUI shim, so it is a separate recipe rather than a
# subset of a lane that is supposed to stay fast.
test-vm-collab-units: vm-test-prereqs
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-vm-collab-units.log) 2>&1
  bash ci/lib/run-nim-test-lane.sh vm-collab-units

test-vm-collab-integration: vm-test-prereqs
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-vm-collab-integration.log) 2>&1
  bash ci/lib/run-nim-test-lane.sh vm-collab-integration

# ct-test's incremental engine: fourteen suites under src/ct_test/incremental,
# none of which was reachable by any recipe or CI script.
test-ct-test-incremental:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-ct-test-incremental.log) 2>&1
  bash ci/lib/run-nim-test-lane.sh ct-test-incremental

# The live-recorder counterpart of the lane above: records with a real Python
# recorder sibling, so it is gated behind having one built.
test-ct-test-incremental-e2e:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-ct-test-incremental-e2e.log) 2>&1
  source scripts/detect-siblings.sh
  bash ci/lib/run-nim-test-lane.sh ct-test-incremental-e2e

# `ct test`'s test-certificate producer and verifier, plus the walker over the
# vendor-neutral conformance vectors.  The walker needs the
# `test-certificates-spec` sibling repo (or CT_TEST_CERTIFICATE_VECTORS
# pointing at its `vectors` directory) and FAILS rather than skipping without
# it — a conformance suite that quietly passes when it found nothing to check
# is worse than no suite.
test-ct-test-certificates:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-ct-test-certificates.log) 2>&1
  bash ci/lib/run-nim-test-lane.sh ct-test-certificates

# GUI ViewModel suites that spawn a real backend process (`headless_session` /
# `stdio_backend`).  `test-vm-native` and `test-vm-js` both exclude them; until
# this recipe existed those exclusions pointed at nothing, so three of the four
# files ran nowhere at all.
test-vm-gui-headless: vm-test-prereqs
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-vm-gui-headless.log) 2>&1
  bash ci/lib/run-nim-test-lane.sh vm-gui-headless

# `src/ct/online_sharing/online_sharing_test.nim` performs a live
# upload/download/delete round-trip against the production sharing service, so
# it must never RUN in CI.  It is still compiled, because "never run" is how it
# rotted: at the time this lane was written it did not compile at all
# (`findTraceForArgs` matched no current signature, and `extractInfoFromKey` no
# longer existed).  A compile is the weakest check that would have caught that,
# and it costs seconds.
#
# The lane is GREEN as of AS-2, which brought the call sites up to date.  That
# is the payoff of compiling something nothing runs: the three signatures it
# had rotted against were three recorded defects, and updating the file was how
# they were noticed as closed rather than merely different.
test-online-sharing-compile:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-online-sharing-compile.log) 2>&1
  bash ci/lib/run-nim-test-lane.sh online-sharing-live --compile-only

# The platform facade's two host instantiations, compiled on the backend they
# ship on — Noir-Studio.milestones.org NS2, the first half of
# `test_one_codebase_two_platforms` ("CI fails if either build breaks").
#
# THE HOLE THIS FILLS was measured, not predicted.  `host/web_browser.nim` and
# `host/desktop_electron.nim` are `{.error.}` on the C backend, so `test-vm-unit`
# cannot compile them; and no suite in `test-vm-unit-js` imports either, because
# `platform/web_platform.nim` was deliberately built to reach no browser API and
# therefore needs neither in order to be tested.  Both properties are correct on
# their own and together they left the two most platform-specific modules in the
# product compiled by NOTHING.
#
# `web_browser.nim` then landed on `dev` at ed9d6021 in a state that does not
# compile at all — a doc comment after an object constructor's closing paren,
# `Error: invalid indentation` — and the whole suite stayed green.  This lane
# fails on exactly that, by file and line.
#
# Compile-only, for the same reason `test-online-sharing-compile` is: one module
# needs a browser and the other needs Electron, so neither can run in CI.  The
# weakest check that would have caught the defect costs seconds.
#
# It does NOT yet satisfy `test_one_codebase_two_platforms` in full.  That test
# also asks that a pane added to one platform appear in the other, which needs a
# web BUNDLE — an entry point that calls `boot()` — and there is still none.
# This is the "either build breaks" half, and it is the half that was on fire.
test-host-instantiations:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-host-instantiations.log) 2>&1
  bash ci/lib/run-nim-test-lane.sh host-instantiations --compile-only

# THE RENDERER, COMPILED BY CI AT LAST — both arms.
#
# The lane note in `host-instantiations` above recorded, honestly, that nothing
# in CI compiled `renderer.nim`: the JS lane family passes `-d:nodejs`, under
# which the renderer does not build at all (`kdom`'s `createElementNS` is a
# browser binding and node is not a browser), so forcing it in would have gated
# it in a configuration nothing ships. The only thing compiling the renderer
# was the tup product build, at package time.
#
# THAT GAP COST A WORKING RENDERER ON `dev`. Commit 333ec709 removed
# `ui/ui_imports.nim`'s blanket re-export of `electron_lib` after auditing its
# exported symbols for uses "anywhere under `ui/`" — and `src/frontend/
# ui_js.nim`, the renderer ENTRY POINT, is not under `ui/`. It read
# `inElectron` from that re-export, stopped compiling, and no suite could see
# it. Same shape as `web_browser.nim`, same week.
#
# The fix is a third backend rather than an exception: `js-browser` is `nim js`
# with no `-d:nodejs`, compile-only by construction. See `test_lane_backend` in
# ci/lib/test-lane-files.sh, and `ci/test/renderer-browser-build.sh` for the
# property gate that proves the two arms are genuinely different builds.
#
# NEEDS isonim's `build/tailwind-styles.json`: `ui_js.nim` reaches
# `isonim/dsl/tailwind`, which `staticRead`s it at compile time, and a missing
# file is an uncatchable Nim error minutes in. `just build-tailwind` generates
# it; CI seeds a `{}` placeholder in `.github/actions/setup-isonim-siblings`.
test-renderer-browser:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-renderer-browser.log) 2>&1
  bash ci/lib/run-nim-test-lane.sh renderer-electron
  bash ci/lib/run-nim-test-lane.sh renderer-web
  bash ci/test/renderer-browser-build.sh

# THE BUNDLE CARRIES THE RENDERER, THE WORKER AND THE MODULES — NS3's residual.
#
# `test-web-bundle` builds and boots the web INSTANTIATION. This assembles the
# whole deployment: the renderer (newly possible), the entry point, the browser
# wasm worker script, and the two Noir wasm modules when they are supplied.
#
# NS3 was never short of a loader. `host/web_browser.nim` has the registry, the
# transport and `newBrowserWasmHost(registry, scriptUrl)`, all tested, and says
# in its own doc comment that nothing calls them because "the worker script ...
# is not in the bundle". The gap was DELIVERY, and this is the step that closes
# it.
#
# The two modules are ~16 MB and ~4.6 MB and are not in the repo. Set
# CT_NOIR_WASM_COMPILER and CT_NOIR_WASM_TRACER to include them; without them
# the gate SKIPS those two loudly, prints the deployment consequence the
# manifest declares for each, and still checks everything else.
test-web-bundle-assets:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-web-bundle-assets.log) 2>&1
  bash ci/test/web-bundle-assets.sh

# THE PAGE PAINTS — the assertion whose absence let a blank product reach
# production with every check green.
#
# `test-web-bundle-assets` above proves the bundle CARRIES the renderer.  That
# is not the same claim as the renderer RUNNING, and the difference was a week
# of `ide.codetracer.com` serving a boot diagnostic and an empty `#dom-root`.
# This loads the assembled bundle in a real headless browser and asserts the
# DOM: the renderer's own `.welcome-screen-root`, its start options, its
# panels, and zero uncaught page errors.
#
# It runs three mutation arms beside the control, each verified to redden the
# assertion written for it — including the exact defect that shipped (publish
# the bundle without the third-party bundle and the renderer dies on
# `ReferenceError: monaco is not defined`).
#
# Reuses an assembled bundle when CT_WEB_BUNDLE_DIR is set; assembles one
# otherwise.
# THE KNOWN-FAILURE LEDGER FAILS IN BOTH DIRECTIONS.
#
# `ci/lib/known-test-failures.tsv` lets a lane stay green over a red that has
# been triaged and registered. A mechanism that can only ever suppress is
# indistinguishable from one that suppresses everything, so this drives
# `ci/lib/known_failures.py` over fixtures and asserts the exit code in each
# direction: a registered red is excused, a registered test that has started
# PASSING reddens the lane by name, and a registered test failing for an
# UNREGISTERED reason is not absorbed.
#
# That last arm is the trap this closes: an entry keyed on a test's identity
# alone swallows any failure of that test, which is how a sibling repo's ledger
# went on green-lighting a journey that had started throwing on its first line.
#
# Pure shell and python, no build: seconds, not minutes.
test-known-failures:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-known-failures.log) 2>&1
  bash ci/test/known-failures-gate.sh

test-web-renderer-mounts:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-web-renderer-mounts.log) 2>&1
  bash ci/test/web-renderer-mounts.sh

# ONE PRESS RUNS ONE ACTION, AND ONE PANE ID NAMES ONE NODE.
#
# Two latent defects that did no visible harm by luck rather than by design.
#
# The pane half is a fixed bug with a mutation proof: `ui/layout.nim`'s
# standalone auto-hide registration had its `continue` one level too deep, so a
# layout that already gave GoldenLayout a container for the pane fell through
# and built a SECOND div with the same id — measured as two
# `#errorsComponent-0` nodes, the GL one holding the mounted panel and an empty
# duplicate parked offscreen at x = -9999.
#
# The chord half is a hazard rather than a present bug, and the gate is what
# keeps it that way. Every entry of `ui/editor.nim`'s
# MONACO_SHORTCUTS_WHITELIST is registered BOTH as a Monaco command and as a
# Mousetrap bind onto the same `data.actions` slot, and
# `ui/shortcuts.nim`'s global `stopCallback` override removes Mousetrap's
# reason to stand down. They do not both fire today only because Monaco
# `stopPropagation`s — which is a property of the chords currently on the list,
# not a mechanism. ALT+F8, which Monaco binds natively, was measured firing
# twice per press when whitelisted.
#
# Reuses an assembled bundle when CT_WEB_BUNDLE_DIR is set; assembles one
# otherwise.
test-chord-and-pane-uniqueness:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-chord-and-pane-uniqueness.log) 2>&1
  bash ci/test/chord-and-pane-uniqueness.sh

# ONE BUNDLE, ONE DEFINITION PER NAME.
#
# A JS bundle is a single script scope, so two top-level `function foo`
# declarations are not an error: the LAST one wins and every caller of the
# first silently runs the second one's body. Two separate defects in this
# repo were exactly that, and neither announced itself:
#
#   - `--hotCodeReloading` made jsgen name routines with a per-module
#     counter, so a generic's anonymous `proc()` closures collided across
#     modules and `createMemo[CapabilityRung]` ran another module's body,
#     copying an enum through a tuple's type descriptor. The editor stopped
#     mounting. See `repro.nim`.
#   - Two `{.exportc.}` procs were both named `debugRepl`, so
#     `services/debugger_service.debugRepl` was unreachable behind
#     `renderer.debugRepl` in every build. It threw nothing; it just never
#     ran.
#
# Duplicate names alone are not sufficient for a fault — if the colliding
# bodies happen to agree, the wrong one wins and nothing looks wrong. So
# this counts names rather than waiting for a symptom, and it asserts the
# count was taken: a bundle with zero matched functions, or an expected
# bundle that was never checked, is a FAILURE and not a clean tree.
#
# Needs a built tree; pass a directory to check somewhere else.
test-js-bundle-name-uniqueness *args:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-js-bundle-name-uniqueness.log) 2>&1
  bash ci/test/js-bundle-name-uniqueness.sh {{args}}

# A SUBMENU YOU CAN CLICK, A BAR THAT DOES NOT FLICKER, AND ONE MENU ON RIGHT-CLICK.
#
# Three defects reported by one user against the deployed `ide.codetracer.com`
# on 2026-09-02, none of which any existing check could have caught, because
# every one of them is invisible to a markup or model assertion.
#
# The submenus were IN THE DOM, with the right rows, at the right coordinates —
# and clipped out of existence by the `overflow: hidden` that `dropdown-surface()`
# carried onto `#menu-main` at 09bc09b7.  Measured on the deployed revision:
# `#menu-main` at x = 10..180, `#menu-nested-elements-1` at x = 181..356 with
# nine rows, `elementFromPoint` at the centre of the first returning
# `section.lm_tabs`.  The same mixin's reveal animation replayed from
# `opacity: 0` on every rebuild of the shell — ten reveals across five pointer
# transitions — which is the flicker, and `opacity: 0` is literally the reported
# "briefly displaying the content below it".
#
# So this gate refuses to assert presence or markup.  Its subjects are a HIT
# TEST (`elementFromPoint` at the row's own painted centre, walked UP to the
# submenu, because `contains()` passes vacuously on `document.body`) and an
# OPACITY SAMPLE taken every animation frame, because a screenshot before and
# after the sweep shows a perfectly good menu both times and the flicker lives
# between the frames.
#
# The context-menu half asserts `defaultPrevented` read by a document-level
# bubble listener.  The native menu is browser chrome, outside the document, and
# is suppressed under automation in every engine, so it cannot be counted — this
# is the observable that decides whether it is drawn, and the gate says so
# rather than pretending to count two menus.
#
# It also carries a STANDING check on the mixin's precondition, asked of every
# dropdown surface on screen rather than of the one that was reported: does any
# of them clip an absolutely-positioned child?  That question cannot be asked of
# the stylesheet — a static pass over the compiled CSS reports zero escaping
# children even for `#menu-main`, because `.menu-nested-elements` is a sibling
# RULE and a child only in the DOM.
#
# Counted assertions with the count asserted, and five mutation arms each
# verified to redden exactly its own check and nothing else.  Builds its own
# `ui.js` and stylesheet into a copy of the bundle: a gate that measured a
# pre-assembled tree would be reporting on code nobody edited.
#
# Reuses an assembled bundle when CT_WEB_BUNDLE_DIR is set; assembles one
# otherwise.
test-menu-and-context-menu:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-menu-and-context-menu.log) 2>&1
  bash ci/test/menu-and-context-menu-in-browser.sh

# THE SECOND BUILD — Noir-Studio.milestones.org NS2's largest unfinished item,
# which said in its own words: "no CI recipe produces a web bundle, so
# `test_one_codebase_two_platforms` is unasserted, and nothing calls the web
# instantiation's boot()".  This is that recipe, and `src/frontend/web_main.nim`
# is the entry point that calls it.
#
# Three things are checked, and the middle one is the reason the other two are
# worth anything:
#
#   1. the bundle BUILDS with `nim js`;
#   2. it links NO host bindings — zero `require(`, no `child_process`, no
#      `ipcRenderer`.  `web_main.nim` deliberately does not import
#      `platform_host`, because that module imports `host/desktop_electron` on
#      the JS backend; measured, importing and using it puts 43 `require(`
#      calls into the bundle, so this check fails on the real regression rather
#      than in principle;
#   3. it BOOTS.  Under node there is no OPFS, so the run takes §4.2's third
#      row — the in-memory volume — and the gate asserts that the session
#      announces the coming loss before editing is possible, which is the
#      product requirement rather than merely "it didn't crash".
#
# It does NOT satisfy `test_one_codebase_two_platforms` in full: that test also
# wants a pane added to one platform to appear in the other, and rendering panes
# means the renderer, which is still Electron-coupled through `platform_host`.
# This is the build half.
test-web-bundle:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-web-bundle.log) 2>&1
  bash ci/test/web-bundle-smoke.sh

# NS1's residual 1 as a ratchet: how many places in the renderer region still
# reach node or Electron directly, per module, against a checked-in budget.
#
# THE SCRIPT IS THE COUNTING RULE, which is the point of it.  The rule used to
# live in prose in the milestone file, and a looser grep over the same region
# returns nearly half again as many hits — `require("tippy.js")`,
# `require("js-yaml")` and an already-guarded `globalThis.process`, none of
# which is host access.  Someone re-deriving the number from a plausible grep
# chases modules that are already fine.  Now the rule runs, and the milestone
# file points here instead of restating it.
#
# It fails in BOTH directions: up, because a new host call in a migrated module
# is a regression; and down, because a migration whose budget was not lowered
# is work that has not been recorded and can be silently re-grown.
# NS3's loop across the worker boundary, compared BY DIGEST against the same
# loop run directly.  A Noir package held only as an in-memory path->source map
# is compiled by `noir_wasm.wasm` and traced by `noir_tracer_wasm.wasm`, twice:
# once in-process, once through `worker_threads` and the JSON protocol
# `platform/wasm_worker.nim` speaks.  The two traces must hash the same.
#
# TWO ASSERTIONS, because the digest alone is not enough and that is measured
# rather than argued: compiling without instrumentation yields a trace of ONE
# event and ZERO steps, and the digests STILL MATCH, because both paths agree
# on nothing.  So the trace is also asserted non-trivial, and the two catch
# different failures -- drop one event in the worker and the digest fails while
# the non-trivial check passes.
#
# SKIPS LOUDLY without the modules; the two .wasm files are 16 MB and 4.6 MB
# and are not in the repo.  Set CT_NOIR_WASM_COMPILER and CT_NOIR_WASM_TRACER.
test-noir-wasm-worker:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-noir-wasm-worker.log) 2>&1
  bash ci/test/noir-wasm-worker-e2e.sh

# The bundled Noir template, against the REAL toolchain -- and, when the wasm
# compiler is available, the browser's test runner against the real `nargo`.
#
# HAD NO RECIPE AND NO WORKFLOW until now, despite six production comments
# citing it as the gate that keeps the template honest -- a citation of a check
# nobody runs reads, in review, exactly like a check.
#
# Needs `nargo` and `nim` on PATH (the dev shell has both). Arm V additionally
# needs CT_NOIR_WASM_COMPILER and skips loudly without it, moving the expected
# assertion count with it so a skip cannot be mistaken for a pass:
#
#   CT_NOIR_WASM_COMPILER=/tmp/noir-wasm-out/noir_wasm.wasm just test-noir-template
test-noir-template:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-noir-template.log) 2>&1
  bash ci/test/noir-template-toolchain.sh

# A wasm-worker SESSION, alive in a real tab over the assembled publish tree.
#
# The e2e above drives the node twin and the twin is one-shot: it proves the
# compile/trace path and says nothing about a job that stays alive. This gate
# is the other half -- a session that opens, refuses a transaction against a
# contract it does not know, ACCEPTS the same transaction after a separate
# round trip registered it, and is then closed with the worker still running.
#
# 48 counted assertions with the count itself asserted, a control arm, a
# backpressure variant, an instrument arm that doubles as the proof that a
# dead worker reaches its runs, and three mutation arms that each redden the
# assertion written for them.  Assembles a bundle itself when
# CT_WEB_BUNDLE_DIR is unset.
test-wasm-worker-session:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-wasm-worker-session.log) 2>&1
  bash ci/test/wasm-worker-session.sh

# Every check in the Noir Build/Run path, killed on purpose, one at a time.
#
# `test_noir_build_marshalling.nim`, `test_noir_build_producer.nim` and
# `test_wasm_worker.nim` are green.  Green over what?  Each arm below breaks
# ONE line of the product and requires a NAMED test case to go red -- not "the
# suite failed", a specific case by title, so a break caught only by some other
# check is reported as a MISS.
#
# It also guards the trap the last campaign hit: an arm whose PREMISE has moved
# patches nothing, the suite passes, and the arm reports "could not be
# measured" forever while looking like coverage.  A no-op patch is a HARD
# FAILURE here, not a skip.
test-noir-build-mutations:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-noir-build-mutations.log) 2>&1
  bash ci/test/noir-build-mutations.sh

# A Build in a real browser that fetches the compiler, compiles, and PAINTS its
# result -- against the assembled publish tree.
#
# The state this replaces was green everywhere and had never fetched either
# wasm module: instrumenting `Worker.postMessage` before page scripts ran and
# exercising every Build-shaped gesture produced one `configure` message, ZERO
# `start` messages and ZERO `.wasm` requests.  So this gate's subject is the
# GESTURE, and its numbers are those three.
#
# Needs the two modules.  Assemble a bundle with CT_NOIR_WASM_COMPILER /
# CT_NOIR_WASM_TRACER / CT_NOIR_WASM_REF set and point CT_WEB_BUNDLE_DIR at it,
# or let this recipe assemble one from the same variables.  Without a compiler
# in the tree it EXITS 2 rather than passing: a gate with nothing to reach
# measures nothing.
test-noir-build-in-browser:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-noir-build-in-browser.log) 2>&1
  bash ci/test/noir-build-in-browser.sh

# EDIT, RUN, STEP, RETURN — AND THE EDIT IS STILL THERE.
#
# The Run/step half has been assertable for a while; the two ends only became
# so when edit persistence landed, because until then "comes back with the
# project as it was" was satisfied by nothing being changeable. This recipe
# exists because the script did not have one: `ci/test/noir-replay-in-browser.sh`
# and `ci/test/noir-edit-persists.sh` were both reachable only by typing their
# paths, which is the same coverage shape as a gate that never runs.
#
# Needs the two Noir modules, like `test-noir-build-in-browser`: set
# CT_NOIR_WASM_COMPILER / CT_NOIR_WASM_TRACER, or CT_WEB_BUNDLE_DIR at a tree
# that already has them. It EXITS 2 rather than passing when they are absent.
test-noir-replay-in-browser:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-noir-replay-in-browser.log) 2>&1
  bash ci/test/noir-replay-in-browser.sh

# The studio keeps what you type, across a reload that destroys every JS value.
#
# The persistence half on its own: 16 counted assertions with three reddening
# arms. `test-noir-replay-in-browser` is what asserts the same edit survives the
# Run/return round trip; this is what asserts it survives the browser.
test-noir-edit-persists:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-noir-edit-persists.log) 2>&1
  bash ci/test/noir-edit-persists.sh

# A failed build, a keystroke, and a caret that lands on the error. In a real
# browser tab, against the assembled publish tree.
#
# `test-noir-build-in-browser` ends where this begins: it proves a Build
# reaches the compiler and paints a verdict, and says nothing about what
# happens next.  What happened next was nothing at all.  `aGotoNextError` and
# `aGotoPreviousError` were live `ClientAction` members with commented-out menu
# entries and `nil` handlers; `renderer.jumpLocation` had zero callers; the
# PROBLEMS pane's row click dispatched `ct/jump-location`, a command with no
# engine implementation anywhere in the repo; and the BUILD pane's rows carried
# a `build-clickable` class, a `cursor: pointer` and a documented
# `click->jumpToLocation` whose handler was deleted in commit 20e24939.  All of
# it green.
#
# So this gate's subject is WHERE THE CARET ENDS UP, read out of Monaco with
# `getPosition()`, compared against the line and column the PROBLEMS pane
# itself paints — not against a hardcoded constant that would have to be
# "fixed" to whatever the code does.  Rows are hit-tested at their own left
# edge: the first run found the pane parked at x = -9999 inside a dismissed
# auto-hide overlay with perfectly correct diagnostics in it.
#
# Needs the two wasm modules, exactly as the recipe above does, and EXITS 2
# without them rather than passing.
test-build-error-navigation:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-build-error-navigation.log) 2>&1
  bash ci/test/build-error-navigation-in-browser.sh

# Every check in the build-error navigation gate, killed on purpose, one at a
# time.
#
# Twenty-four green checks are worth nothing until each has been shown to go
# red for its OWN reason — a kill by some other check is reported as a MISS,
# because it means the check written for that behaviour does not cover it.  The
# five arms drop the diagnostic's column on the way to the caret, silence the
# wrap announcement, remove the chord from `default_config.yaml` (the exact
# silently-unbound failure this feature was built to avoid), stop revealing the
# pane, and stop filtering navigation to errors.
#
# Each arm asserts the patched file actually CHANGED first: a patch that
# matches nothing leaves the gate green and would report coverage forever.
#
# Slow — every arm rebuilds the renderer and drives a browser.  Point
# CT_WEB_BUNDLE_DIR at an assembled tree or each arm reassembles one.
test-build-error-nav-mutations:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-build-error-nav-mutations.log) 2>&1
  bash ci/test/build-error-nav-mutations.sh

test-renderer-host-budget:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-renderer-host-budget.log) 2>&1
  bash ci/test/renderer-host-reach-budget.sh

# NS2's SECOND half — "a pane added to one platform appears in the other".
#
# The first half ("CI fails if either build breaks") has been covered since
# `test-host-instantiations` and `test-web-bundle`.  This is the other one, and
# it was unassertable until the renderer built for a browser: you cannot compare
# two pane sets with only one bundle.
#
# `renderer-browser-build.sh` already checks the NEGATIVE half — that
# `panel_transfer` and `agentic_worktree_test_hooks` are absent from the web
# bundle, by name.  Nothing checked the panes that are supposed to be on BOTH,
# which is what the milestone actually claims.
#
# The registry is `makeComponent`'s arms, read from `src/frontend/utils.nim`;
# presence is measured in the two BUILT bundles, because a pane whose arm exists
# but whose module left the web import graph is exactly the failure this is for;
# and the kinds are a checked-in budget that fails in both directions.  Three
# independent sources, so no assertion compares a list against itself.
test-renderer-pane-parity:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-renderer-pane-parity.log) 2>&1
  bash ci/test/renderer-pane-parity.sh

# ID1's identity layer: the mutation proof, the WebCrypto seam executed under
# Node, and the assertion that no environment variable can turn verification
# off.
#
# The unit suites themselves run in `vm-unit` and `vm-unit-js` by the directory
# glob; these three are the evidence around them. M17 needs BOTH backends — it
# asserts green on C and red on JS — so do not set CT_IDENTITY_ARMS here.
test-identity:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-identity.log) 2>&1
  bash ci/test/identity-no-escape-hatch.sh
  bash ci/test/identity-desktop-no-credential.sh
  bash ci/test/identity-desktop-no-credential-test.sh
  bash ci/test/identity-webcrypto.sh
  bash ci/test/identity-token-mutation.sh

# NS7a's first verification: the development loop has no network surface, so
# there is no request for a token to ride on. Runs the gate through its own
# build path FIRST (no bundle variables set, so it compiles both arms exactly
# as CI would), then hands those artifacts to the mutation proof rather than
# rebuilding them twelve times.
test-noir-studio-signed-out:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-noir-studio-signed-out.log) 2>&1
  bash ci/test/noir-studio-signed-out.sh
  cache="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}"
  CT_WEB_ENTRY_BUNDLE="${cache}/nsso-loop/web.js" \
  CT_RENDERER_WEB_BUNDLE="${cache}/nsso-renderer/ui.js" \
    bash ci/test/noir-studio-signed-out-test.sh

# The docs/book-isonim SSG suites.
#
# THE EXPLICIT ANSWER to "are these CI or hand-run?": CI, via this recipe, when
# the isonim-docs sibling is present — and a LOUD SKIP when it is not.  They
# were neither before: `docs/book-isonim/Justfile` has a `test` recipe that
# nothing in this repo, and nothing in any workflow, ever invoked, so ten
# suites with 63 cases sat in a state where "hand-run gate" and "never run"
# were indistinguishable.  The book cannot build without ../../../isonim-docs
# (its nimble requires it), which is why this cannot be an unconditional lane;
# saying so out loud, and failing rather than silently passing when the sibling
# is missing but CT_BOOK_ISONIM_REQUIRED=1, is what makes the answer explicit.
test-book-isonim:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-book-isonim.log) 2>&1
  echo "=== docs/book-isonim SSG suites ==="
  if [ ! -d "../isonim-docs" ]; then
    echo "MISSING-SIBLING SKIP: ../isonim-docs is not checked out."
    echo "  docs/book-isonim is built on the isonim-docs SSG framework and its"
    echo "  nimble requires ../../../isonim-docs, so neither the book nor its"
    echo "  tests can compile without it."
    if [ "${CT_BOOK_ISONIM_REQUIRED:-0}" = "1" ]; then
      echo "ERROR: CT_BOOK_ISONIM_REQUIRED=1 but the sibling is absent." >&2
      exit 1
    fi
    exit 0
  fi
  # The book's own Justfile stays the source of truth for HOW to build and run
  # the suites (`build` first, then the ten files, in that order because four
  # of them read the built public/ tree). This recipe exists to make sure
  # SOMETHING invokes it.
  #
  # The codetracer dev shell already provides a `nim` that compiles the book,
  # so the plain invocation is tried first. The `nix develop` fallback is for
  # a bare shell; it is second, not first, because the framework flake resolves
  # sibling inputs by hash and a workspace whose siblings are ahead of that pin
  # fails to evaluate at all — which would turn a green suite into an
  # infrastructure error.
  if just --justfile docs/book-isonim/Justfile \
       --working-directory docs/book-isonim test; then
    exit 0
  fi
  echo "ambient toolchain could not run the book suites; retrying in the framework dev shell" >&2
  nix develop path:../isonim-docs -c just \
    --justfile docs/book-isonim/Justfile \
    --working-directory docs/book-isonim test


# RS-M12: assert no recorder writes a sidecar manifest any more.
#
# `src/tests/gui/tests/request-panel/no_sidecar_manifests_test.nim` runs each
# recorder sibling's own `record-request-panel-fixture` recipe — the same real
# recording run that produced the checked-in fixtures — into a scratch
# directory, with `CODETRACER_SPAN_MANIFEST` deliberately SET, and requires
# that no `session_manifest.jsonl` / `codetracer_spans.jsonl` appears anywhere
# the run could have written one.  Setting the retired opt-in is what makes it
# a proof that the write path is GONE rather than a snapshot of today's
# defaults.
#
# It is excluded from `test-vm-native` / `test-vm-js` because it needs six
# recorder toolchains, which is exactly what the checked-in fixtures exist to
# spare that lane.  A sibling that is not checked out is reported through the
# same `MISSING-RECORDER SKIP:` marker `test-vm-recorder-gated` uses, and the
# test's own zero-test guard fails an all-skipped run so a sibling-less
# environment cannot masquerade as a pass.
test-no-sidecar-manifests: vm-test-prereqs
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-no-sidecar-manifests.log) 2>&1
  echo "=== RS-M12 sidecar retirement (real recording per language) ==="
  f=src/tests/gui/tests/request-panel/no_sidecar_manifests_test.nim
  name=$(basename "$f" .nim)
  cache="/tmp/ct-nim-cache/vm-native-$name"
  nim c -r --hints:off \
    --path:src/frontend/viewmodel \
    --nimcache:"$cache" \
    -o:"$cache/$name" \
    "$f"

# Compile + run the `ct` CLI's trace-layer unit suites
# (src/ct/trace/*_test.nim).
#
# These are Nim `unittest` suites over the recording-folder shape
# detector, the session-manifest open path, CTFS source materialization,
# path handling and `ct host`'s idle-timeout parser.  They were invoked
# by nothing: `test-vm` globs only src/tests/gui/tests, and
# `test-vm-recorder-gated` only src/frontend/viewmodel/tests/unit, so
# every file under src/ct/trace was a test that never ran.  They are
# pure-Nim, need no recorder sibling and no display, so they belong in
# their own cheap lane rather than gated behind either of those.
test-ct-trace-units:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-ct-trace-units.log) 2>&1
  bash ci/lib/run-nim-test-lane.sh ct-trace-units

# Compile + run the `ct upload` MCR-enrichment unit suites
# (src/ct/online_sharing).
#
# DISCOVERED, not enumerated.  This recipe used to carry a four-name list and a
# comment explaining that the list was deliberate ("Every OTHER `*_test.nim`
# there must be listed below; if you add one, add it here, because a name list
# silently omits what it forgets").  The comment was right about the mechanism
# and wrong about the remedy: the milestone that wrote it added
# `upload_wire_format_test.nim` by name and missed `collab_invite_url_test.nim`
# sitting in the same directory — while asserting there was "one other
# `*_test.nim` file in that directory" when there were two.
#
# So the rule is inverted now.  ci/lib/test-lane-files.sh globs the directory
# and rejects exactly one file by name: `online_sharing_test.nim`, a live
# upload/download/delete round-trip against the sharing service, which has its
# own compile-only lane (`just test-online-sharing-compile`).  A new suite in
# this directory runs on the next CI run without anyone editing anything, and
# ci/test/test-lane-coverage.sh fails by name if one ever slips out again.
#
# The lane's files need `-d:ssl -d:useOpenssl3` because `api_client.nim` pulls
# in `std/net`'s `newContext`; none of them opens a TLS connection.  Those
# flags live with the lane definition, not here.
test-mcr-enrichment-units:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-mcr-enrichment-units.log) 2>&1
  bash ci/lib/run-nim-test-lane.sh mcr-enrichment-units

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
  # Shared classifier: exit status before the [OK]/[FAILED] tally.
  source ci/lib/test-lane-report.sh
  # The file SET comes from the lane definition, not from a second copy of the
  # selection rule kept here.  It used to be an inline `find` for
  # `test_column_*_vm.nim` / `test_formatted_view_step_*_vm.nim` /
  # `test_statement_step_*_vm.nim`, and when ci/lib/test-lane-files.sh moved
  # `vm-recorder-gated` to selecting by its `recorder_gate` IMPORT, this loop
  # went on globbing names — so `test_js_subdir_trace_vm.nim`, which had just
  # been subtracted from `vm-unit` for depending on a recorder, was run by no
  # recipe at all.  ci/test/test-lane-coverage.sh could not see it, because
  # that guard reads lane DEFINITIONS and the definition did claim the file.
  # A lane whose recipe and whose definition disagree is a lane that reports
  # on a set nobody chose.
  source ci/lib/test-lane-files.sh

  failed=0
  passed=0
  skipped=0
  for f in $(test_lane_files vm-recorder-gated); do
    name=$(basename "$f" .nim)
    cache="/tmp/ct-nim-cache/vm-gated-$name"
    echo -n "  $f ... "
    output=$(nim c -r --hints:off \
      --path:src/frontend/viewmodel \
      --nimcache:"$cache" \
      -o:"$cache/$name" \
      "$f" 2>&1) && rc=0 || rc=$?
    oks=$(echo "$output" | grep -c '\[OK\]' || true)
    fails=$(echo "$output" | grep -c '\[FAILED\]' || true)
    skips=$(echo "$output" | grep -c 'MISSING-RECORDER SKIP:' || true)
    verdict=$(classify_test_run "$rc" "$oks" "$fails")
    if [ "$verdict" = "crashed" ]; then
      # First, ahead of every count and even ahead of the skip branch: a
      # signalled death makes the counts a prefix of the run, and a missing
      # recorder never kills a process with a signal.
      test_run_headline "$verdict" "$rc" "$oks" "$fails"
      echo "$output" | tail -30 | sed 's/^/    /'
      failed=$((failed + 1))
    elif [ "$fails" -gt 0 ]; then
      echo "FAILED ($oks OK, $fails FAILED, exit $rc)"
      echo "$output" | grep '\[FAILED\]' | sed 's/^/    /'
      failed=$((failed + 1))
    elif [ "$skips" -gt 0 ]; then
      echo "SKIPPED (missing recorder)"
      echo "$output" | grep 'MISSING-RECORDER SKIP:' | head -1 | sed 's/^/    /'
      skipped=$((skipped + 1))
    elif [ "$rc" -ne 0 ] && [ "$oks" -gt 0 ]; then
      # Green cases over a red process.  See `classify_test_run` in
      # ci/lib/test-lane-report.sh for the two ways that happens; both are
      # silent unless the exit code is read.  Ordered after the skip branch so
      # a recorder-gated skip is unaffected — the signalled-death case is
      # handled ahead of everything, at the top of this chain.
      echo "FAILED WITHOUT A [FAILED] LINE (exit $rc, $oks OK)"
      echo "$output" | tail -30 | sed 's/^/    /'
      failed=$((failed + 1))
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

# Native MCR/RR omniscient-prep timing.
bench-native-omniscient-timing *args:
  cd src/codetracer-bench && cargo run --release --bin ct-bench -- native-omniscient-timing {{args}}

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
#   * ``test_harness::find_ct_native_replay()`` honours CT_NATIVE_REPLAY_PATH
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
