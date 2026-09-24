build:
  bash scripts/build.sh

build-once:
  bash scripts/build-once.sh

# Install the commit/push checks nix/pre-commit.nix declares on a host WITHOUT
# the Nix dev shell -- native Windows is the case it exists for. The Nix shell
# installs its own leg on entry; this one runs the same hooks through the
# pre-commit framework from PATH. env.ps1 calls it; see the script's header.
install-portable-git-hooks:
  bash ci/dev/install-portable-git-hooks.sh

# Which of those checks this host can actually run, hook by hook, and the
# command that installs whatever is missing. A missing tool fails the commit
# that needs it; this says so before the commit does.
portable-pre-commit-doctor:
  python3 ci/dev/portable-pre-commit.py doctor

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

# Assert that every `flake.lock` node whose repository is checked out beside
# this one records the `lastModified` that its own `rev` actually carries. A
# node whose timestamp names one commit and whose `rev` names another is
# refused outright by nix ("mismatch in field 'lastModified'") — but only when
# nix FETCHES the input, which a warm store and a sibling-path override both
# avoid. So a hand-edited pin passes locally, passes on warm runners, and kills
# a cold one before anything has evaluated. Reads the lock and runs `git show`
# against the siblings already on disk: no network, no nix, half a second.
# Skips LOUDLY (never silently passes) when no sibling holds any locked
# revision; CT_FLAKE_LOCK_NODE_DATES_STRICT=1 makes that a failure. It does NOT
# cover the nodes with no sibling checkout — that is
# ci/test/flake-lock-metadata-test.sh, which needs the network and runs in CI.
# See the header of scripts/test-flake-lock-node-dates.sh.
test-flake-lock-node-dates:
  bash scripts/test-flake-lock-node-dates.sh

# Assert the GUI harness's `npm install` leaves `src/tests/gui/yarn.lock` alone.
# npm >= 7 keeps an existing yarn.lock "up to date" by rewriting it from the
# tree it installed, and on Linux that tree has no `fsevents` (playwright's
# darwin-only optional), so every GUI run deleted the block and dirtied a
# tracked file — which `yarn install --frozen-lockfile`, the Windows/DIY
# bootstrap in env.sh, then cannot satisfy on macOS. `ci/lib/npm-install.sh`
# wraps the install and reverts the rewrite; this guard drives it with a stub
# npm so each rewrite shape (pure deletion, addition, failing install) is
# stated rather than left to whichever platform happens to run it. No network.
test-npm-install-yarn-lock:
  bash ci/test/npm-install-yarn-lock-test.sh

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

# Assemble the `codetracer-tui` component bundle the same launcher fronts:
#   <out-root>/codetracer-tui@<ver>/{capabilities, bin/codetracer-tui}
# The TUI half of the recipe above, and deliberately its twin: `capabilities`
# is copied byte-for-byte from `packaging/codetracer-tui.caps`, and both the
# directory name and the binary filename come from that file's `name` / `bin`
# lines.  Requires an already-built front-end (`just build-tui`); a missing one
# is a loud failure.  Output defaults to the gitignored
# `build-tui-component/`.  Point the launcher at the SAME out-root as the
# desktop bundle to get a components tree that serves both — that is the
# arrangement `src/tests/launcher/test_launcher_routes_tui.nim` routes over.
# See scripts/build-tui-component.sh and
# codetracer-specs/Front-Ends/CodeTracer-TUI.milestones.org CTUI-12.
build-tui-component *args:
  bash scripts/build-tui-component.sh {{args}}

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

# NO `--hotCodeReloading:on`, AND THAT IS NOT AN OMISSION.
#
# `repro.nim` dropped the flag from the product's `ui.js` at 092588b8 and says
# why at length; this is the SECOND place that set it, and it set it while
# compiling the same `src/frontend/ui_js.nim`. Under the flag `jsgen.mangleName`
# names a routine with `idOrSig` — a hash of the routine's own signature plus a
# MODULE-LOCAL collision counter — instead of `mangleProcNameExt`, so two
# modules can and do emit top-level functions with identical names. A JS bundle
# is one script scope: the LAST declaration wins and every caller of the first
# silently runs the second one's body. That is what stopped the renderer's
# editor from ever mounting.
#
# MEASURED ON THIS RECIPE'S OWN OUTPUT, not inherited from that commit:
#
#   --hotCodeReloading:on   17312 top-level functions, 112 DUPLICATED names
#   without it               8656 top-level functions, 0 duplicated names
#
# It bought nothing for either: no Nim file in this tree, in isonim or in
# nim-everywhere reads `defined(hotCodeReloading)`. CodeTracer's hot reload is
# the LiveReload transport gated on `-d:ctHmr` (see `build-ui-js-hmr` below),
# which is untouched by this. `ci/test/js-bundle-name-uniqueness.sh` is the
# standing guard on the class; `ci/test/renderer-extension-build.sh` asserts
# this particular bundle is duplicate-free and that the flag has not come back.
build-ui-js output:
  nim \
    -d:chronicles_enabled=off \
    -d:ctRenderer \
    -d:ctInExtension \
    --debugInfo:on \
    --lineDir:on \
    --out:{{output}} \
    js src/frontend/ui_js.nim

# HMR-enabled renderer build. Adds `-d:ctHmr` (which transitively
# activates `-d:isonimHmr`) so {.uiComponent.} pragmas register slots
# and `mountUiHot` boundaries listen for swaps. The runtime gate is
# the env var CT_HMR=1 — without it the transport stays uninstalled
# even in this binary, so this output can be the everyday dev binary.
# CT_HMR_BUNDLE optionally overrides the bundle file the FS watcher
# observes; the default is `src/build-debug/public/ui.js`.
#
# `--hotCodeReloading:on` is absent here for the reason spelled out over
# `build-ui-js` above, and the two flags are unrelated despite both being about
# reloading: Nim's `--hotCodeReloading` is a CODEGEN mode nothing in this tree,
# isonim or nim-everywhere reads, and its only observable effect here was 112
# duplicated top-level function names. `-d:ctHmr` / `-d:isonimHmr` are what
# make this the HMR build, and they are still here.
build-ui-js-hmr output:
  nim \
    -d:chronicles_enabled=off \
    -d:ctRenderer \
    -d:ctInExtension \
    -d:ctHmr \
    -d:isonimHmr \
    --debugInfo:on \
    --lineDir:on \
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

  # Platform precondition is loudly UNSUPPORTED (exit 2) outside macOS arm64:
  # a non-macOS (or non-arm64) CI run must fail loudly naming the supported host.
  if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "UNSUPPORTED: test-reprobuild-hcr-mcr-dap requires macOS arm64 (got $(uname -s) $(uname -m)); covered by macOS arm64 CI on aarch64-darwin." >&2
    exit 2
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

  repro_bin="$(command -v repro || true)"
  if [ -z "${REPRO_MONITOR_SHIM_LIB:-}" ]; then
    if [ -n "$repro_bin" ] && [ -f "$(dirname "$repro_bin")/../lib/librepro_monitor_shim.dylib" ]; then
      export REPRO_MONITOR_SHIM_LIB="$(cd "$(dirname "$repro_bin")/../lib" && pwd)/librepro_monitor_shim.dylib"
    elif [ -f "$reprobuild_root/build/lib/librepro_monitor_shim.dylib" ]; then
      export REPRO_MONITOR_SHIM_LIB="$reprobuild_root/build/lib/librepro_monitor_shim.dylib"
    fi
  fi
  if [ -z "${REPRO_PUBLIC_CLI_PATH:-}" ] && [ -n "$repro_bin" ]; then
    export REPRO_PUBLIC_CLI_PATH="$repro_bin"
  fi


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

  # Platform precondition is loudly UNSUPPORTED (exit 2) outside macOS arm64.
  if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "UNSUPPORTED: test-reprobuild-hcr-in-codetracer requires macOS arm64 direct HCR (got $(uname -s) $(uname -m)); covered by macOS arm64 CI on aarch64-darwin." >&2
    exit 2
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
#
# THE WARM-CHECKOUT GUARD ASKED THE WRONG QUESTION and the body now lives in
# `scripts/storybook-deps.sh`, which explains why and can be executed against a
# synthetic tree by `ci/test/stale-artefact-guards-test.sh`. In short: `[ -x
# node_modules/.bin/storybook ]` is existence, and what this needs is that the
# installed tree matches `package-lock.json` -- so a lockfile change was never
# installed on any machine that had run this once.
storybook-deps:
  bash scripts/storybook-deps.sh

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

    if [ -d "$target" ] && [ -n "$(find "$target" -name '*storybook*.spec.ts' -print -quit)" ]; then
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
#
# EVERY LANE RUNS, AND THE AGGREGATE FAILS IF ANY OF THEM DID.
#
# This body used to be `set -e` plus a straight sequence of `just <lane>`
# calls, which meant the FIRST failing lane aborted it and the remaining six
# never ran at all.  This is the `test-non-gui` CI job (ci/test/non-gui.sh
# execs `just test` inside the dev shell), so the cost of that was one full
# round trip of CI — nix dev-shell startup included — per broken lane, and no
# point at which anyone could see how much was actually broken.
#
# ci/lib/run-just-lanes.sh runs them all and then names every failure.  It does
# not weaken any lane: each still runs the same recipe, each exit status is
# still load-bearing, and `just test` still exits non-zero if any lane failed.
test:
  #!/usr/bin/env bash
  set -uo pipefail
  # A genuine capability gate, not a hidden failure: the cross-repo tests need
  # a checkout of codetracer-native-backend, and ci/test/non-gui.sh explicitly
  # sets CODETRACER_RR_BACKEND_PATH= so they do not run in this CI job.  When
  # the path IS set the lane joins the list below, so it aggregates exactly
  # like every other lane — it cannot be silently skipped once chosen, and its
  # failure fails `just test`.
  if [ -n "${CODETRACER_RR_BACKEND_PATH:-}" ]; then
    echo "codetracer-native-backend detected — cross-repo tests included"
    set -- cross-test
  else
    echo "CODETRACER_RR_BACKEND_PATH not set — skipping cross-repo tests"
    set --
  fi
  # THE SEVEN LANE NAMES ARE LITERAL ARGUMENTS ON THIS INVOCATION, and that is
  # load-bearing beyond style.  They used to be built up in a bash array, which
  # made them invisible to `ci/test/shell-gate-coverage.sh`: its walk reaches a
  # recipe only through a name it can SEE, and an array element is not one.
  # `scripts/test-build-alignment.sh` and `ci/test/sibling-backend-path-test.sh`
  # were reachable through nothing else, so converting this recipe off a
  # dependency list orphaned them (merge a4681be7, job 102285037564).  Both were
  # still RUNNING the whole time — the walk had gone blind, not the coverage —
  # but a reachability guard that cannot see a live edge is exactly the defect
  # this recipe's own aggregate exists to prevent.  Keep them literal here.
  bash ci/lib/run-just-lanes.sh test \
    test-build-alignment \
    test-flake-pin-alignment \
    test-flake-lock-node-dates \
    test-npm-install-yarn-lock \
    test-python-version-alignment \
    test-sibling-backend-path \
    test-agent-api-contract \
    test-rust \
    test-nimsuggest \
    "$@"

# Run all GUI tests headlessly against an already-built CodeTracer binary.
test-gui-prebuilt *args:
  #!/usr/bin/env bash
  set -e
  export CODETRACER_ELECTRON_ARGS="${CODETRACER_ELECTRON_ARGS:---no-sandbox --no-zygote --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage}"

  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*|*_NT*|Darwin)
      # Windows and macOS: no Xvfb needed; Electron uses the native display
      # server (Win32 / Cocoa).  There is no Xvfb in the macOS dev shell at
      # all, and Chromium on Darwin ignores $DISPLAY, so the branch below
      # would have started nothing and then exported a $DISPLAY pointing at
      # an X server that does not exist.  `test-e2e` exempts Darwin from its
      # $DISPLAY precondition for the same reason; this keeps the two in step.
      just test-e2e {{args}}
      ;;
    *)
      # Linux: start a persistent Xvfb so Playwright/Electron tests have a display.
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

# Assert the Event Log is static across a jump, and that a jump moves only the
# dimming boundary. Reported as "the event log completely disappears after some
# jumps through the call trace"; the contract it checks is
# `GUI/Core-Panes/Event-Log-Pane.md` § "What a move changes, and what it does
# not". Runs against an already-built binary — pair it with `build-once` (or
# use `test-gui`) if the frontend has changed.
#
# Kept as its own recipe because the two assertions are cheap, they fail for
# distinct reasons (a rebuilt row set vs. a mis-placed dimming boundary), and
# the row-identity assertion is the one that catches ANY future silent rebuild
# of the pane, not just the vanish that prompted it.
test-event-log-static *args:
  just test-gui-prebuilt tests/event-log/event_log_is_static_across_jumps.spec.ts {{args}}

# H6 (Home-Demo-Screencast) — CODETRACER LAUNCHES THE FLAME UNDER HCR.
#
# `The-Flame-Demo-Spec.md` §2.5: the demo launches the flame client under
# CodeTracer, and attaching to one that is already running is out of scope. The
# order is transport-specific: Linux starts its Unix-socket coordinator before
# the dial-out target; Windows starts its target first, then connects the
# coordinator to the agent's PID-keyed named pipe. This gate drives the
# product's own Build-menu entry through that order: session ready, then three
# edits TYPED into the panel reshape the flame the product started.
#
# The provenance half is asserted against the KERNEL, not against the product's
# own account of itself: procfs on Linux or Win32_Process CIM on Windows says
# the target's parent is the Electron main process, which is itself a descendant
# of the test process and is not the test process. That is what makes the gate
# able to refuse a run in which a harness started the target — which is exactly
# what the `harness-launches` arm does.
#
# Needs the flame demo's prerequisites (`just gdext-hcr` and a session-capable
# `hcr_patch_driver` in `artifacts/h5-driver/`); it FAILS by name rather than
# skipping if one is missing. Runs on Linux and Windows.
test-hcr-launch-under-hcr *args:
  just test-gui-prebuilt tests/hcr-live-edit/flame_launch_under_hcr.spec.ts {{args}}

# The same gate's SIX ARMS, followed by the discrimination matrix.
#
# Each arm removes one thing and must produce one named outcome; the matrix then
# requires that no arm's expectation is satisfied by any other arm's run. "All
# arms red" is not that check — H5 shipped two arms that went red for reasons
# neither claimed, and one that passed with its subject absent.
test-hcr-launch-arms *args:
  bash scripts/hcr6-launch-arms.sh {{args}}

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

# The BROWSER-ONLY stylesheet guards — every surface whose PAINTING has been
# reported broken by a user, in seconds.
#
# None of these needs Electron, a recorded trace, a language recorder or a
# display: each lays a surface's own markup out in a plain Playwright page
# carrying the COMPILED theme stylesheet and measures what the user would see.
#
#   footer-visibility-css-guard  — is every required footer region THERE, and on screen
#   footer-contrast-guard        — is the footer READABLE against its background
#   build-panel-contrast-guard   — is the BUILD output panel readable, in both themes
#
# The first two are complements, and each was written after a regression the
# other could not see: the footer shipped tabs-only three times (b27da3947,
# 51a3e820e, 00fd68b7f) with the colours fine, and shipped every readout at
# 1.22:1 — the user-agent default black on #1b1b1b — with the geometry fine.
#
# WHY THE RECIPE IS NO LONGER CALLED `test-status-bar-guards`. The build panel
# then shipped the SAME defect on a different surface — `.build-output-line`
# and the idle header at 1.42:1 on the web and 1.05:1 under Electron's
# Bootstrap, again because nothing in the ancestry ever declared a `color` —
# and it was found the same way the first two were, by a user looking at the
# screen. Three reports of one shape is a class of defect, not three
# coincidences, and the recipe that catches it should be named for the
# question rather than for the first place it was asked. Adding a surface here
# is now cheaper than writing a new recipe, which is the point.
#
# Deliberately NOT routed through `test-e2e`: that recipe demands $DISPLAY on
# Linux, starts Xvfb via `test-gui-prebuilt`, and builds storybook, none of
# which these need. It is also not given `build-once` as a prereq, so it
# stays usable as a fast local loop — the cost is that it reads whatever
# `src/build-debug/frontend/styles` currently holds, so RUN `just build-once`
# FIRST after editing any `.styl` or you are grading the previous build. CI
# gets this right by construction: it runs after the package is built.
#
# ITS STATIC SIBLING IS `just test-css-token-resolution`, and the two ask
# different questions of the same stylesheets. These three ask whether a
# resolved colour is READABLE, which needs a rendered page. That one asks
# whether the value resolved AT ALL — Stylus emits an unknown identifier
# verbatim, so `color: colors-ui-text-accent` compiles clean and the browser
# drops it. That is a static property of the compiled CSS, so it needs no
# browser and no build: it compiles the stylesheets itself and is therefore
# free of the "grading the previous build" hazard above.
test-css-contrast-guards *args:
  #!/usr/bin/env bash
  set -e
  bash ci/lib/npm-install.sh src/tests/gui
  cd src/tests/gui && \
    npx playwright test tests/status-bar/footer-visibility-css-guard.spec.ts \
                        tests/status-bar/footer-contrast-guard.spec.ts \
                        tests/build/build-panel-contrast-guard.spec.ts {{args}}

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

# Verify the DECODED-TRACE reasoning of the gate above, which the gate itself
# can only exercise after a launcher, a built core, a recorder and `ct-print`
# are all in place.  The trace-shape discrimination, the empty-recording guard,
# the `functions`/`event_type` lookups, the recorded-payload search and the
# `noext` routing key are pure functions of a `ct-print` document, so this
# drives them -- the shipped functions, extracted from the shipped files --
# against codetracer-trace-format-nim's own REAL `ct-print --full` goldens for
# both trace families.  It is what pins the two facts the shape-aware guard
# exists for: `ct-print` reports a correct native MCR recording as
# `counts.steps: 0` / `counts.calls: 0` (so the v4 predicate rejects it) and as
# `counts.io_events: 0` (so a native predicate must NOT require that key).  It
# also re-validates every recorder contract fixture checked out beside this
# repo, so a schema change cannot silently invalidate a green edge's fixture.
# Twelve internal mutations plus a positive control.  Needs the
# codetracer-trace-format-nim sibling; a missing one is a hard failure.
# Stock bash: no Nix, no dev shell, no network.
# See ci/test/launcher-recorder-decode-test.sh.
test-launcher-recorder-decode:
  bash ci/test/launcher-recorder-decode-test.sh

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
  nim c -r --hints:off --warnings:off -d:ssl -d:useOpenssl3 --mm:refc --nimcache:"$(ci/lib/nim-cache-root.sh)/bpf_monitor_test" src/ct/ci/bpf_monitor_test.nim

# BPF integration tests — requires a capabilities-aware bpftrace binary
# and the bpftrace-collection.bt script from the codetracer-ci sibling repo.
# Skips gracefully if prerequisites are not met.
# Run `just developer-setup` first to set up bpftrace capabilities.
#
# NOTE: bpftrace 0.24.x has a hardcoded geteuid()==0 check, so these tests
# require either passwordless sudo or a patched bpftrace build. They will
# skip with a diagnostic message when the prerequisite is not met.
test-bpf-integration:
  nim c -r --hints:off --warnings:off -d:ssl -d:useOpenssl3 --mm:refc --nimcache:"$(ci/lib/nim-cache-root.sh)/bpf_integration_test" src/ct/ci/bpf_integration_test.nim

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
    --nimcache:"$(ci/lib/nim-cache-root.sh)/bpf_monitor_native_test" \
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
    --nimcache:"$(ci/lib/nim-cache-root.sh)/bpf_native_integration_test" \
    src/ct/ci/bpf_native_integration_test.nim
  LD_LIBRARY_PATH="${CT_LD_LIBRARY_PATH:-${CODETRACER_LD_LIBRARY_PATH:-}}" \
    src/ct/ci/bpf_native_integration_test

# Run all BPF-related tests (unit + native + integration).
#
# This was a DEPENDENCY LIST — `test-bpf: test-bpf-monitor test-bpf-native
# test-bpf-native-integration test-bpf-integration` — and `just` aborts the
# whole invocation at the first dependency that exits non-zero, so three of the
# four lanes went unreported whenever the first one broke.  That is not a
# `set -e` artefact and no shell flag fixes it; the only fix is to stop
# expressing the aggregate as a dependency list.  The four lanes still run in
# the same order (they share the built `ct` binary and the BPF programs), each
# still fails on its own terms, and `just test-bpf` still exits non-zero if any
# of them did — it now names all of them rather than only the first.
test-bpf:
  #!/usr/bin/env bash
  set -uo pipefail
  bash ci/lib/run-just-lanes.sh test-bpf \
    test-bpf-monitor \
    test-bpf-native \
    test-bpf-native-integration \
    test-bpf-integration

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
  shortcut_presets_test="$(mktemp "${TMPDIR:-/tmp}/codetracer-shortcut-presets-test.XXXXXX.js")"
  shortcut_dialog_test="$(mktemp "${TMPDIR:-/tmp}/codetracer-shortcut-dialog-test.XXXXXX.js")"
  debug_toolbar_tooltips_test="$(mktemp "${TMPDIR:-/tmp}/codetracer-debug-toolbar-tooltips-test.XXXXXX.js")"
  component_registry_binding_test="$(mktemp "${TMPDIR:-/tmp}/codetracer-component-registry-binding-test.XXXXXX.js")"
  stop_command_test="$(mktemp "${TMPDIR:-/tmp}/codetracer-stop-command-test.XXXXXX.js")"
  run_to_cursor_test="$(mktemp "${TMPDIR:-/tmp}/codetracer-run-to-cursor-test.XXXXXX.js")"
  html_sinks_probe="$(mktemp "${TMPDIR:-/tmp}/codetracer-html-sinks-probe.XXXXXX.js")"
  dap_refusal_test="$(mktemp "${TMPDIR:-/tmp}/codetracer-dap-refusal-test.XXXXXX.js")"
  trap 'rm -f "$frontend_lang_test" "$scratchpad_dispatch_test" "$target_axes_js_test" "$ipc_registry_test" "$shortcut_bindings_test" "$shortcut_presets_test" "$shortcut_dialog_test" "$debug_toolbar_tooltips_test" "$component_registry_binding_test" "$stop_command_test" "$run_to_cursor_test" "$html_sinks_probe" "$dap_refusal_test"' EXIT
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

  # The preset tables, and the dialog that lists what they resolved to. Same
  # lane and same invocation as the suite above: all three read the SHIPPED
  # `default_config.yaml` through `defaultRendererConfig`, which is a `nim js`
  # target only.
  nim -d:nodejs -d:chronicles_enabled=off -d:ctRenderer -d:ctInExtension \
    --out:"$shortcut_presets_test" js src/frontend/tests/shortcut_presets_test.nim
  node -e 'globalThis.window = globalThis; require(process.argv[1])' "$shortcut_presets_test"

  nim -d:nodejs -d:chronicles_enabled=off -d:ctRenderer -d:ctInExtension \
    --out:"$shortcut_dialog_test" js src/frontend/tests/shortcut_dialog_test.nim
  node -e 'globalThis.window = globalThis; require(process.argv[1])' "$shortcut_dialog_test"
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
  # Every component `registerComponent` is handed must come out bound to its
  # `Data`, including one whose (content, id) slot is already taken -- the
  # singleton factories all build id 0 and publish into `data.ui.<panel>`
  # BEFORE registering, so a rejected duplicate is still what the app renders.
  # Unbound, its first `self.data.<field>` is `null.sessions` in the generated
  # JS: the "statusBaseModel dereferences null: reading 'sessions'" crash.
  # Same `window` alias as the scratchpad suite, same `types.nim` reason.
  echo "Running component registry binding tests..."
  nim -d:nodejs -d:chronicles_enabled=off -d:ctRenderer -d:ctInExtension \
    --out:"$component_registry_binding_test" js src/frontend/tests/component_registry_binding_test.nim
  node -e 'globalThis.window = globalThis; require(process.argv[1])' "$component_registry_binding_test"
  echo ""
  # *Stop* leaves Debug mode for Edit mode. `renderer.nim`'s `stopAction` was
  # `discard` from the initial open-source commit while `SHIFT+F5` dispatched
  # to it, and nothing could see that: no runnable lane can import
  # `renderer.nim` (`nim js` on it pulls the Karax/Monaco tree), so the two
  # renderer lanes compile-check it and an empty body compiles fine. The
  # behaviour therefore lives in the leaf `ui/stop_command.nim`, which this
  # runs.
  echo "Running Stop command tests..."
  nim -d:nodejs -d:chronicles_enabled=off -d:ctRenderer -d:ctInExtension \
    --out:"$stop_command_test" js src/frontend/tests/stop_command_test.nim
  node -e 'globalThis.window = globalThis; require(process.argv[1])' "$stop_command_test"
  echo ""
  # *Run to Cursor* is `ct/source-line-jump` with `behaviour = ForwardJump`,
  # and the enum crosses the wire as its ORDINAL. This is the Nim half of that
  # coupling; the Rust half is
  # `the_wire_form_of_jump_behaviour_is_the_nim_ordinal` in `dap_handler.rs`.
  echo "Running Run to Cursor wire tests..."
  nim -d:nodejs -d:chronicles_enabled=off -d:ctRenderer -d:ctInExtension \
    --out:"$run_to_cursor_test" js src/frontend/tests/run_to_cursor_test.nim
  node -e 'globalThis.window = globalThis; require(process.argv[1])' "$run_to_cursor_test"
  echo ""
  # A REQUEST THE BACKEND REFUSES MUST BECOME TEXT THE USER CAN READ, and it
  # must not read like a timeout. Asserted on the RENDERED TEXT of the real
  # status shell, driving the real `sendCtRequest` and
  # `resolvePendingDapResponse` over the frame `handle_message_browser`
  # builds.
  #
  # NOTE THE ABSENT `-d:ctInExtension`, which every other suite in this recipe
  # passes. The code under test is dap.nim's `when not defined(ctInExtension)`
  # arm: the continuation table that correlates a response to the request that
  # is waiting on it. Under `-d:ctInExtension` that table does not exist —
  # VS Code's debug client does the correlation — so compiling this with the
  # flag would silently test the wrong arm.
  echo "Running DAP refusal surfacing tests..."
  nim -d:nodejs -d:chronicles_enabled=off -d:ctRenderer \
    --out:"$dap_refusal_test" js src/frontend/tests/dap_refusal_surfaces_test.nim
  node -e 'globalThis.window = globalThis; require(process.argv[1])' "$dap_refusal_test"
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
  echo ""
  # Renderer modules RUN over jsdom (the `renderer-dom` lane): the web
  # renderer's `ct/load-locals` answers matched to the requests that produced
  # them, one request per stop, through the real response fan-out.
  echo "Running renderer-dom lane..."
  just test-renderer-dom
  echo ""
  echo "Running main-process lane..."
  just test-main-process

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
  bash "${CODETRACER_REPO_ROOT_PATH}/ci/lib/npm-install.sh" "${CODETRACER_REPO_ROOT_PATH}/src/tests/gui"
  cd "${CODETRACER_REPO_ROOT_PATH}/src/tests/gui" && \
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

# Rust flow tests — STABLE ONLY, despite the `-all` name.
#
# Unlike `test-nim-flow-all` above, which really does invoke all three of its
# per-version recipes, this invokes only `test-rust-flow-stable`.
# `test-rust-flow` (ambient toolchain) and `test-rust-flow-nightly` exist and
# are not run here; why they were left out is not recorded anywhere I could
# find, so do not read this as a statement that they are unsupported.
test-rust-flow-all:
  #!/usr/bin/env bash
  set -e
  echo "========================================"
  echo "Testing Rust flow with Rust stable only"
  echo "========================================"
  echo ""
  just test-rust-flow-stable
  echo ""
  echo "========================================"
  echo "Rust stable flow test passed!"
  echo "(test-rust-flow and test-rust-flow-nightly were NOT run)"
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
  bash ci/lib/npm-install.sh src/tests/gui
  cd src/tests/gui && \
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
# DEFERRED, AND SAY SO: TEN OF THE 13 RECIPES NAMED BELOW ARE IN NO PIPELINE
# YET.
# ---------------------------------------------------------------------------
# "Picked up by its lane" is NOT the same as "runs in CI", and for ten of the
# thirteen the second is currently false: no workflow, no entry in
# ci/verdict/required-jobs.txt, and no aggregate recipe invokes them.
#
# TWO MOVED OUT OF THIS LIST ON 2026-09-20 (PLAT-33): `test-vm-collab-units`
# and `test-vm-collab-integration` are named by the `viewmodel-tests` job in
# .github/workflows/codetracer.yml, each under `if: ${{ !cancelled() }}`, and
# both are green.  See the correction below about the reasons this paragraph
# used to give for their being red — not one of the three was right, which is
# the lesson rather than the repair: a lane nobody runs is a lane whose
# FAILURE REASONS also go stale.
#
# The remaining exception is `test-lane-coverage` — `ci/lint/nim.sh` runs its script
# (`ci/test/test-lane-coverage.sh`) as part of the `lint-nim` job, and
# `lint-nim` IS listed in ci/verdict/required-jobs.txt.  That is repeated in
# the promotable list further down; both statements are meant to agree.
#
# For HOW MUCH of the tree the deferral leaves dark, count it rather than
# trusting a number written here — the figures that used to stand in this
# paragraph (76 dark of 220 resolved, 144 reachable) were all stale against
# the very command they cited.  Run:
#
#   source ci/lib/test-lane-files.sh && test_lane_all_files | wc -l
#
# for every file the lane library resolves.  The reachable share is whatever
# the lanes behind `just test-vm`, `test-cli-record`, `test-ct-trace-units`,
# `test-mcr-enrichment-units`, `test-m16-release-gate`, `test-ct-providers`,
# `test-visual-replay-gate`, `test-vm-recorder-gated` and
# `test-no-sidecar-manifests` resolve to; the rest are in lanes no pipeline
# runs.  A reader who assumed otherwise would be repeating this campaign's own
# mistake one level up, so it is written down here rather than left to be
# discovered.
#
# WHY it is deferred: six of these lanes are red for reasons that are not
# theirs to fix, and wiring a red lane into a required job breaks every build
# for everybody:
#
#   test-frontend-units          cross_process_origin_vm_test needs an
#                                uncommitted rr/MCR cross-process recording
#   (test-vm-collab-units)       FIXED, PLAT-33.  The drift was real and the
#                                FIGURE was not: 32 unclassified and 0 stale,
#                                not "30 unclassified, 1 stale".  Eighteen of
#                                the thirty-two were `SourceVM`, which had
#                                never had a registry row at all.
#   (test-vm-collab-integration) FIXED, PLAT-33 — and NOT for the reason this
#                                list gave.  `libgpui_nim_shim.so` was built;
#                                all four of `test_collab_m8_cross_frontend`'s
#                                cases died in a repo-root probe looking for a
#                                `nim.cfg` this repository does not have.  A
#                                second red nobody had recorded at all cost
#                                `test_collab_webrtc` two of four cases: it
#                                searched $PATH for Chromium while the dev
#                                shell's sits under $PLAYWRIGHT_BROWSERS_PATH,
#                                where FOUR ci/test/*.sh gates already look
#                                (and twelve non-shell files besides; the
#                                figure read "five" until it was counted).
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

# PLAT-2's verification gate, and the contract suite that proves it can say no.
# Both are pure bash (the contract suite additionally uses `nim check` for the
# purity arm, and says NOT RUN by name if `nim` is absent), and both are wired
# into `ci/lint/nim.sh`; this recipe exists so a developer can run them without
# the whole lint stage.
test-value-presentation-boundary:
  #!/usr/bin/env bash
  set -euo pipefail
  bash ci/test/value-presentation-boundary-test.sh
  bash ci/test/value-presentation-boundary.sh

# PLAT-6's layer rule, enforced: the DECISION half of each declared
# decide/perform pair under `src/frontend/tui/` does no I/O — no effectful
# import, no `host/` import, no I/O call site.  Pure bash, about a second, and
# it carries its own positive controls (a real `app/` module that DOES import
# `std/os`, and the two performers that DO make the calls), so a scanner that
# had stopped matching reddens rather than reporting a clean sweep.  Wired into
# `ci/lint/nim.sh`; this recipe is for running it alone.
test-tui-layer-split-boundary:
  bash ci/test/tui-layer-split-boundary.sh

# PLAT-7's plugin boundary: a declared plugin cannot reach a raw `isonim`
# reactive primitive, so Extensibility-Model.md §5.3's synchronous-effect budget
# is enforcement rather than advice.  `codetracer_plugin.nim` filters the ten
# denied names out of the facade with `export … except`, which stops the
# unqualified spelling at compile time; this gate stops the module-qualified one
# that `except` cannot filter, and the direct import of
# `isonim/core/{computation,owner}` or of the wider `codetracer_embed`.  Its
# positive controls run through the rule's own predicates.  Wired into
# `ci/lint/nim.sh`; this recipe runs the guard and its contract suite alone.
test-plugin-reactive-boundary:
  #!/usr/bin/env bash
  set -euo pipefail
  bash ci/test/plugin-reactive-boundary-test.sh
  bash ci/test/plugin-reactive-boundary.sh

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

# THE THIRD BACKEND (PLAT-17).  The same Tier-1 ViewModel suites compiled to
# wasm32 through Emscripten and run under node.
#
# Architecture/Uniform-WASM-Core.md §2.1.3: the ViewModel suites are
# backend-agnostic — `MockBackendService` and `withFakeTime` — so the
# verification for a WASM core is not new test-writing, it is running the
# EXISTING suites on a third backend and requiring the same results.  §2.1.4
# says what "the same" means, and it is not "green": the same case count and
# the same assertion count as native, with every suite that cannot run named
# with a platform reason.
#
# `just test-vm-unit-wasm-parity` is what ENFORCES that, by running this lane
# and `test-vm-unit` and comparing them file by file.  This recipe on its own
# only says the lane is green, and green is the weaker claim.
#
# Needs the dev shell: `emcc` and `node`.  The runner FAILS rather than skips
# when either is missing — see the note there for why a skippable wasm lane is
# the `vm-js` defect wearing a toolchain check.
test-vm-unit-wasm: vm-test-prereqs
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-vm-unit-wasm.log) 2>&1
  bash ci/lib/run-nim-test-lane.sh vm-unit-wasm

# PLAT-17's verification gate, made mechanical.
#
# Runs `vm-unit` and `vm-unit-wasm` and asserts THREE things the individual
# lanes cannot:
#
#   1. every file both lanes run reports the SAME case count and the SAME
#      declared assertion count.  An EQUALITY, never "at least" and never
#      "both green" — a count that quietly shrinks is this milestone's
#      characteristic defect and an inequality cannot see it;
#   2. the set of files native runs and wasm does not is EXACTLY the six
#      documented in ci/lib/test-lane-files.sh.  A seventh file that stops
#      building reddens by name; a listed file that starts building reddens
#      too, so the list cannot outlive its reason;
#   3. neither lane ran zero files, which is the vacuous-pass guard one level
#      up from the runner's own.
test-vm-unit-wasm-parity: vm-test-prereqs
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-vm-unit-wasm-parity.log) 2>&1
  bash ci/test/vm-unit-wasm-parity.sh

# The contract suite for the two recipes above, in the shape
# ci/test/vm-js-lane-test.sh established for the JS lane and for the same
# reason: a lane that reports results it cannot observe is worse than no lane.
test-vm-unit-wasm-lane-contract:
  #!/usr/bin/env bash
  set -euo pipefail
  bash ci/test/vm-unit-wasm-lane-test.sh

# PLAT-17 deliverable 2: the ViewModel core's footprint under `--mm:orc` on a
# linear-memory target, measured BEFORE any UI is attached, beside the same
# graph's footprint on native.
#
# The numbers are for a reader; what is GRADED is a property — after every
# session is released and ORC has collected, live bytes must be below the
# peak.  On a graph that is cyclic by construction, that is the statement
# that ORC's cycle collector runs at all under wasm32, and a build succeeding
# does not establish it.
test-wasm-footprint:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-wasm-footprint.log) 2>&1
  bash ci/test/wasm-footprint.sh

# PLAT-17's fourth verification signal: a fake-timer chain runs at native
# speed under WASM, which is what says the clock and the dispatcher are inside
# the module rather than deferring to a host loop.
#
# The instrument is a RATIO — simulated ms per wall ms — because the failure
# it exists to catch is a change of MECHANISM and not of speed: a chain that
# reaches a host timer scores about 1, a chain that does not scores four
# orders of magnitude more.
test-wasm-fake-timer:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-wasm-fake-timer.log) 2>&1
  bash ci/test/wasm-fake-timer-speed.sh

# PLAT-18's rejection criterion, re-measured under BOTH optimisation levels.
#
# Separate from `test-wasm-fake-timer` above rather than folded into it: that
# script is one of the six entries in `run-plat17-wasm-mutations.py`'s
# `TOUCHED`, so editing it invalidates eighteen recorded control digests and
# obliges a re-run of every arm graded against it. This is a second consumer
# of the same probe.
#
# Uniform-WASM-Core.md §5 makes "a fake-timer suite runs materially slower
# under WASM" a reason to REJECT adoption, and PLAT-17's own bound 5 says
# every figure it published is a DEBUG build. A rejection criterion evaluated
# only under a build the product does not ship is not evaluated.
test-plat18-fake-timer:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-plat18-fake-timer.log) 2>&1
  bash ci/test/plat18-fake-timer-builds.sh

# PLAT-18 deliverable 2: the vertical slice — the variables pane with the
# 600-member fixture, driven by PLAT-17's core, in a REAL Electron renderer
# against a REAL document.
#
# Three arms in one process, interleaved: the current `nim js` build with
# `WebRenderer`, the same core over a serialised boundary, and the wasm core
# over the same boundary. The middle one is the control that tells "wasm is
# slower" apart from "a serialised boundary is slower".
#
# Needs a display. `xvfb-run` satisfies it and the script uses it when
# `$DISPLAY` is unset; with neither it FAILS (exit 2) rather than skipping,
# for the reason `ci/lib/run-nim-test-lane.sh`'s wasm branch gives.
test-plat18-slice:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-plat18-slice.log) 2>&1
  bash ci/test/plat18-electron-slice.sh

# PLAT-18's fifth §5 criterion: the developer loop. One suite, compiled and run
# on all three backends, interleaved, with the cache cleared per arm — which is
# what a developer's edit does.
#
# TWO NUMBERS COME OUT AND THEY ARE DIFFERENT KINDS OF THING: a loose
# REGRESSION GATE that fails the step, and §5's criterion, REPORTED. A decision
# criterion wired into CI reddens every day and trains the next person to
# re-run it.
test-plat18-dev-loop:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-plat18-dev-loop.log) 2>&1
  bash ci/test/plat18-dev-loop.sh

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

# Stylus emits an identifier it cannot resolve VERBATIM instead of failing, so
# `color: colors-ui-text-accent` compiles clean, reaches the browser as an
# invalid value, is dropped, and the element inherits whatever is behind it.
# The page renders — it is merely the wrong colour — and nothing reports it.
#
# Three shipped defects in this repo have had exactly that cause: buttons that
# painted blank, the FiraCode rules rendering in a serif face, and the build
# output panel where two text tiers had no colour and painted at 1.05:1. All
# three were found by a person looking at the screen. This is the check that
# was missing, and `components/ns9_panes.styl` already asks for it in prose.
#
# It compiles the stylesheets the Tupfile ships and reads the OUTPUT: the
# failure mode IS source and output disagreeing silently, so a source-level
# check could only re-implement Stylus and would be wrong exactly where it
# matters. Needs `stylus`, so it runs in the dev shell; ~30s.
test-css-token-resolution:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-css-token-resolution.log) 2>&1
  bash ci/test/css-token-resolution.sh

# The guard above, shown failing. Eleven arms: five defects it must report,
# four legal constructs it must not, and the two instrument checks that stop
# an empty stylesheet or an unreadable Tupfile scoring as a pass. Hermetic
# and sub-second — synthetic fixtures in a scratch directory, nothing in the
# worktree is touched — except the last arm, which runs the real pipeline
# over the real tree and needs `stylus` (it skips without it).
test-css-token-resolution-contract:
  bash ci/test/css-token-resolution-test.sh

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

# ct-test's incremental engine: seventeen suites, none of which was reachable
# by any recipe or CI script when this lane was written. The count is not
# maintained by hand -- `ci/lib/test-lane-files.sh` discovers them -- and it has
# only ever moved UPWARD: fourteen when written, sixteen under
# `src/ct_test/incremental/` today, plus `src/ct_test/incremental_cli_test.nim`
# one level up, which `ci/test/test-lane-coverage.sh` caught running in no lane
# at all.
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
# file is an uncatchable Nim error minutes in. `just vm-test-prereqs` generates
# it (it runs `scripts/build-tailwind.sh`; there is no `build-tailwind`
# recipe); CI seeds a `{}` placeholder in
# `.github/actions/setup-isonim-siblings`.
test-renderer-browser:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-renderer-browser.log) 2>&1
  bash ci/lib/run-nim-test-lane.sh renderer-electron
  bash ci/lib/run-nim-test-lane.sh renderer-web
  bash ci/test/renderer-browser-build.sh

# Renderer modules RUN, not only compiled: the `renderer-dom` lane builds its
# suites for the browser target (the only target `ui/state.nim` compiles for)
# and runs them under node over jsdom (`src/frontend/tests/jsdom-run.mjs`).
# `locals_answer_identity_test.nim` drives the web renderer's `ct/load-locals`
# senders through the real response fan-out and asserts one request per stop,
# in the stopped-in file's language, and that every answer is judged against
# the stop its own request was sent at.
#
# NEEDS the checkout's `node_modules/jsdom`, which the dev shell links from the
# Nix-built node modules on entry; the runner fails (rather than skipping) when
# it is absent. Same tailwind prerequisite as `test-renderer-browser`.
test-renderer-dom:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-renderer-dom.log) 2>&1
  bash ci/lib/run-nim-test-lane.sh renderer-dom

# The Electron MAIN process's modules RUN under node: the `main-process` lane
# builds its suites with the `server_index.js` defines (`-d:ctIndex
# -d:server`, which load `electron_vars` without Electron).
# `dap_session_routing_test.nim` drives the main process's DAP router with two
# sessions whose requests share a `seq` and asserts each answer reaches the
# session that asked.
test-main-process:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-main-process.log) 2>&1
  bash ci/lib/run-nim-test-lane.sh main-process

# THE BUILD A DEVELOPER TYPES, which is not one of the two above.
#
# `test-renderer-browser` compiles the two SHIPPED arms. `just build-ui-js` and
# `just build-ui-js-hmr` compile a third configuration — `-d:ctInExtension` plus
# `--hotCodeReloading:on` — and nothing ran them, so `cloud` carried a renderer
# that could not be built by the HMR/dev loop or by the VS Code extension while
# every suite stayed green. Two independent faults were sitting in it:
#
#   * `ui/trace.nim(1088)` internal error: symbol has no generated name:
#     gutterTestLines — an `{.exportc.}` routine near the top of the module is
#     code-generated by `nim js` AT THE LINE IT IS WRITTEN, together with
#     everything it reaches, and it reached a `var` declared 800 lines further
#     down that had therefore not been named yet. See the note in `trace.nim`
#     just above `calcTraceWidth`, which carries a nine-line reproducer.
#   * `ui_js.nim(1791)` undeclared identifier: resolvePendingDapResponse — M49
#     added the proc to dap.nim's non-extension arm only.
#
# Neither is exotic and neither needed a running product to catch: both are
# compile errors, and this recipe takes about ten seconds. It ASSERTS THE
# ARTEFACT — size, that node parses it, and four symbols that disappear under
# the wrong configuration — rather than the recipe's exit status, and it also
# re-reads `justfile` so a red gate cannot be made green by deleting the
# defines. `ci/test/renderer-extension-build.sh` says why for each check.
test-renderer-extension-build:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-renderer-extension-build.log) 2>&1
  bash ci/test/renderer-extension-build.sh

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

# A CLICK ON A LOW LEVEL CODE ROW, ON THE RENDER ARM THE BUNDLE SHIPS.
#
# `isonim_low_level_code_view.nim` has TWO row renderers.  The headless suites
# drive `renderInstructionRowMock`, which binds `onclick = handler`; the web
# bundle renders `renderInstructionRowWeb`, which binds through
# `isonim_dom.addEventListener`.  A suite that only exercises the Mock arm can
# be entirely green against a binding no user ever touches, which is the
# divergent-arms hazard this repo has already shipped once.
#
# `ci/test/low_level_code_row_click_probe.mjs` closes that gap in real
# Chromium: it clicks the row's CENTRE through a real hit test and asserts what
# the click asked the backend for — the command, the path, and the LINE, which
# is chosen so a payload of 43 can only come from the row actually clicked (row
# 1 is line 42 and the active row is a third offset).
#
# WHY THIS RECIPE EXISTS AND WHY IT DEPENDS ON THE STORYBOOK BUNDLE. The probe
# was named in a comment in `ci/test/web-bundle-assets.sh` — present tense,
# about a probe nothing ran — and recorded dark in
# `ci/test/shell-gate-coverage.known-dark.txt` for exactly that reason. It was
# never BLOCKED: it needs `storybook/dist/components.js` and a Playwright
# Chromium, both of which this repo's dev shell already has, and it needed the
# two lines nobody had written.  `build-storybook-components` is its only
# precondition, so it is a dependency rather than a sentence in a comment.
#
# NO SKIP ARMS, DELIBERATELY. Every input is built from source in the same
# invocation; there is no optional asset whose absence could make an assertion
# unmeasurable, so all ten checks are load-bearing on every run. The probe's own
# staleness gate refuses a `components.js` built from different source (it
# compares the command string `low_level_code_vm.nim` currently sends against
# the bundle's bytes) and exits 2 rather than reporting on a tree nobody edited.
#
# Seconds, not minutes: the `nim js` is ~2s warm and the browser leg ~5s.
test-low-level-code-row-click: build-storybook-components
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-low-level-code-row-click.log) 2>&1
  node ci/test/low_level_code_row_click_probe.mjs

# ONE LAYOUT PER MODE, AND IT SURVIVES A RELOAD.
#
# `ci/test/mode_layout_probe.mjs` measures eleven legs of rendered geometry
# through a real tab — three round trips between the modes, a splitter drag
# followed by a reload, and a deliberately corrupted layout store — and writes
# a JSON report. It has no verdict of its own: it exits 0 whether it measured
# everything or timed out on its first selector, and its header says as much
# ("Reports facts. The shell counts assertions"). Until
# `ci/test/mode-layout-in-browser.sh` there was no shell, so the probe was
# named in two comments and recorded dark among the three gates nothing
# referenced.
#
# WHAT IT ASSERTS THAT `mode_layout_test.nim` CANNOT. That test exercises the
# layout MODEL, and every assertion in it can hold of a product whose workspace
# looks wrong: a layout config is not a workspace. Nothing in this gate reads a
# config — every check is over a `getBoundingClientRect()` or over the tab
# strip the panes are actually in, because a pane exiled at zero width
# satisfies a presence check exactly as a working one does.
#
# ONE ARM SKIPS HERE, LOUDLY AND COUNTED SEPARATELY. Without a replay engine
# and a Noir toolchain — both OPTIONAL bundle assets this recipe does not build
# — debug mode reaches no session and opens no source file, so the debug-mode
# editor has nothing to measure. The gate reads that from the product (the edit
# legs carry a source tab, the debug legs carry none) and skips rather than
# reddening; a permanently red lane stops being read.
#
# Reuses an assembled bundle when CT_WEB_BUNDLE_DIR is set; assembles one
# otherwise (~80s), then ~20s in the browser.
test-mode-layout-in-browser:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-mode-layout-in-browser.log) 2>&1
  bash ci/test/mode-layout-in-browser.sh

# A TEST ROW OFFERS TWO ACTIONS AND ONLY ONE OF THEM RE-RUNS.
#
# The TESTS pane's per-row `⟳` and `⏵`, driven in a real browser. The
# assertion that carries the feature is not "the pane has buttons" — that
# cannot fail for its own reason — but that the three gestures move the
# recording's identity DIFFERENTLY: `⟳` changes it and does not navigate, `⏵`
# leaves it alone and opens a debugger, `⇧⏵` changes it and opens one. A
# harness that could not tell the middle case from the other two would certify
# the re-run-every-time implementation the user explicitly ruled out.
#
# Two witnesses per gesture, produced by different code at different moments:
# the recording's id, and the moment it was recorded. Both are published on
# the row (`data-ct-recording-id`, `data-ct-recorded-at`) and on the host's own
# log lines, so an id that is stable for the wrong reason — minted from the
# selector, say — is caught by the clock rather than certified.
#
# It also hit-tests the controls, which is how it found them being covered
# after a run by the BUILD overlay's click-to-dismiss backdrop.
#
# Assembles a bundle when CT_WEB_BUNDLE_DIR is unset.
test-tests-pane-row-controls:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-tests-pane-row-controls.log) 2>&1
  bash ci/test/tests-pane-row-controls.sh

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

# THE PERMITTED-SHADOW TABLE IS THE SAME ON BOTH SIDES.
#
# `shortcut_bindings_test.nim` fails on any chord `hardBindShadowedActions`
# reports that `PERMITTED_HARD_BIND_SHADOWS` does not carry. That constant is a
# copy of a table in `codetracer-specs`, so widening it by one row would make
# the rule permit exactly the shadow it exists to catch, and every test over it
# would go on passing. This compares the two texts.
#
# SKIPS LOUDLY when `codetracer-specs` is not a sibling -- no CI lane provisions
# it today -- and `CT_SPECS_REQUIRED=1` turns that skip into a failure, which is
# the one variable between this recipe and being enforcing in a lane that does.
# Both instrument arms plant an extra row, one per side, so a run that compared
# nothing cannot report agreement.
test-shortcut-shadow-spec-agreement:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-shortcut-shadow-spec-agreement.log) 2>&1
  bash ci/test/shortcut-shadow-spec-agreement.sh

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

# THE EDITOR'S CONTEXT MENU IS THE MODE'S — the CONTENT, entry by entry.
#
# Beside the recipe above deliberately, and reading the same assembled bundle.
# That gate asserts exactly ONE menu appears on a right-click and that its hint
# row is inert; every one of its checks passes on a menu whose entire content is
# replay commands offered in Edit mode, because it never reads an entry name.
# This one names each entry and says present or absent, per mode.
#
# Reuses an assembled bundle when CT_WEB_BUNDLE_DIR is set; assembles one
# otherwise.
test-editor-context-menu-modes:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-editor-context-menu-modes.log) 2>&1
  bash ci/test/editor-context-menu-modes.sh

# THE EDITOR FOLLOWS ITS PANE WHEN THE PANE IS RESIZED — both modes, both
# directions, across two entries into Debug mode, by dragging the divider with
# the mouse.
#
# The third gate over the same re-host as the two above, and it exists because
# neither of them can see this failure: one reads the font option, the other
# reads menu entries, and both pass on an editor frozen at the size debug mode
# left it. Reported against noirstudio.dev as "resizing the panel that holds the
# Monaco editor doesn't seem to resize the actual editor, the scrollbar stays in
# place, this is in debug mode".
#
# THE CHECK THAT CANNOT PASS WHILE THE DEFECT IS PRESENT is that Monaco's
# CONTAINER — `getContainerDomNode()`, the one element `automaticLayout`'s
# ResizeObserver watches and the only one it will ever watch — is still in the
# document. The geometry checks alone are not enough, and this gate has the
# measurement to prove it: on the pre-fix tree the two `debug/shrink` legs
# returned the pane to the width the editor was frozen at, so "the editor fills
# its pane" and "layoutInfo matches" both went GREEN on a completely broken
# product. The container reading went red in all four debug legs.
#
# It also keeps the 5x5 covered: Monaco clamps a zero measurement with
# `Math.max(5, ...)`, and a 5x5 editor inside an 880x902 pane is what an earlier
# change in this area left behind. Both are asserted in the same run so neither
# can be fixed by breaking the other.
#
# Reuses an assembled bundle when CT_WEB_BUNDLE_DIR is set; assembles one
# otherwise. CT_RESIZE_GATE_TREE serves an already-built tree as-is, which is
# what the control run above was measured with.
test-editor-resize-follows-pane:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-editor-resize-follows-pane.log) 2>&1
  bash ci/test/editor-resize-follows-pane.sh

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

# The `/noir/demo` template: that it is NOT the starter, that its eight tests
# pass, and that the bug it exists to demonstrate is still reachable.
#
# Arms D/T/R/F/S need only `nargo` and `nim`. Arms A and W additionally need
# the wasm modules and skip loudly without them, moving the expected assertion
# count with them so a skip cannot read as a pass:
#
#   CT_NOIR_WASM_COMPILER=/tmp/noir-wasm-out/noir_wasm.wasm \
#   CT_NOIR_WASM_TRACER=/tmp/noir-wasm-out/noir_tracer_wasm.wasm \
#     just test-noir-demo
test-noir-demo:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-noir-demo.log) 2>&1
  bash ci/test/noir-demo-template.sh

# The `/noir/demo` path as a VISITOR gets it: the page paints, Run opens a
# replay session, and the calltrace shows exactly three `one_pass` frames.
#
# Needs an assembled bundle CARRYING THE REPLAY ENGINE, or it refuses rather
# than reporting the demo broken for a reason about the bundle:
#
#   CT_REPLAY_ENGINE_DIR=browser-replay/dist/pkg \
#   CT_NOIR_WASM_COMPILER=... CT_NOIR_WASM_TRACER=... \
#     just test-noir-demo-browser
#
# Pass CT_WEB_BUNDLE_DIR to reuse a tree instead of assembling one.
test-noir-demo-browser:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-noir-demo-browser.log) 2>&1
  bash ci/test/noir-demo-in-browser.sh

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
# A typed watch expression, in a real browser, showing a correct value --
# and an unanswerable one showing a stated reason.
#
# The State pane's headless suites drive the MockRenderer, and the tab strip
# that makes the Watches tab reachable existed only there: `stWatches` could
# be selected from `vm.selectTab` and from no gesture in any shipping
# product. So this gate clicks the product's own tab button and types into
# its own input, and its first mutation arm removes the strip to show the
# assertion fails against the panel that shipped.
#
# Needs Chromium and stylus from the dev shell; it EXITS 2 rather than
# passing when either is absent. Pass a path to write a screenshot.
test-watch-expressions-in-browser *args:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-watch-expressions-in-browser.log) 2>&1
  bash ci/test/watch-expressions-in-browser.sh {{args}}

# A recorded value reaches the State pane and is shown as the value it is.
#
# The sibling of `test-watch-expressions-in-browser`, over the same captured
# `ct/load-locals` body and with the same three dependencies. Where that gate
# asks whether the pane's tabs and inputs are REACHABLE, this one asks what
# the pane SAYS a value is, and whether it ever asked for one.
#
# Needs Chromium and stylus from the dev shell; it EXITS 2 rather than
# passing when either is absent. Pass a path to write a screenshot.
test-state-values-in-browser *args:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-state-values-in-browser.log) 2>&1
  bash ci/test/state-values-in-browser.sh {{args}}

test-noir-replay-in-browser:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-noir-replay-in-browser.log) 2>&1
  bash ci/test/noir-replay-in-browser.sh

# EDIT -> RUN -> REPLAY -> STOP -> EDIT, three times, and the MODE is the
# subject rather than the two modes.
#
# `test-noir-replay-in-browser` above drives the same journey and is not this:
# its whole forward-direction evidence is that `#next-image` exists, and its
# verdict string smuggles the mode claim into a parenthetical over that one
# boolean. Nothing there records what the topbar was BEFORE the Run, so its
# return-leg checks are graded against an unrecorded baseline — a product that
# never entered Debug mode satisfies "no debugger pane is still mounted"
# trivially. This gate reads the surface the product itself declares
# (`data-topbar-surface`) at every leg, through one reader.
#
# It also presses the control a user can SEE. `renderer.stopAction` was
# `discard` and no Stop button existed, so the return leg was reachable only by
# `ctrl+f5` — which is what the sibling gate drives, and why the defect
# survived it.
#
# Three round trips because `Mode-Transitions.md` §6 asks for at least three:
# "the failure mode is a slot that is right once and empty afterwards".
#
# Needs the two Noir modules AND the replay engine: set CT_NOIR_WASM_COMPILER /
# CT_NOIR_WASM_TRACER / CT_NOIR_WASM_REF / CT_REPLAY_ENGINE_DIR, or
# CT_WEB_BUNDLE_DIR at a tree that already has them. It EXITS 2 rather than
# passing when they are absent.
test-noir-mode-roundtrip:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-noir-mode-roundtrip.log) 2>&1
  bash ci/test/noir-mode-roundtrip.sh

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

# A call-trace jump puts its target line on screen, and a click in the file
# tree opens its file — both in DEBUG mode, both with a clean console.
#
# The gestures all work in Edit mode and failed after a Run, because entering
# Debug mode rebuilds the layout and left `EditorViewComponent.layoutItem`
# pointing at an item the new tree does not contain; `showTab` then activated
# through that cached `.parent` and threw `componentItem is not a child of this
# stack` inside an async proc, where it surfaced only as an unhandled
# rejection.  Measured on the pre-fix tree: 0/8 jumps followed, with the active
# editor's Monaco node DISCONNECTED — while its caret sat on the target line,
# which is why the console and the pane's height are both part of the verdict.
#
# Needs the replay engine AND the Noir modules: set CT_REPLAY_ENGINE_DIR (or
# CT_REPLAY_ENGINE_GLUE / CT_REPLAY_ENGINE_WASM) and CT_NOIR_WASM_COMPILER /
# CT_NOIR_WASM_TRACER, or CT_WEB_BUNDLE_DIR at a tree that already carries
# them.  Without a session there is no Debug mode and the gate refuses rather
# than passing over an empty list.
test-jump-follow:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-jump-follow.log) 2>&1
  bash ci/test/jump-follow-in-browser.sh

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
  cache="$(ci/lib/nim-cache-root.sh)"
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


# ===========================================================================
# CodeTracer TUI (codetracer-specs/Front-Ends/CodeTracer-TUI.milestones.org)
# ===========================================================================
#
# The terminal front-end lives at src/frontend/tui/, IN THIS REPO, and the
# reason is a fact about the Embed SDK rather than a preference: the facade
# deliberately withholds `backend/stdio_backend` and `viewmodel/
# headless_session` — the only modules that spawn a local `replay-server` for a
# `.ct` folder — so a front-end in its own repository could not open a local
# trace through the sanctioned surface at all.  It is therefore split into
# `app/` (a declared SDK consumer) and `host/` (the one exempt directory), and
# `src/frontend/tui/main.nim` wires the two.
#
# There is deliberately NO second flake, Justfile, .nimble or AGENTS.md: this
# repo has all of them, and duplicating them was the largest wasted motion in
# the campaign's first draft.

# Everything the TUI needs before a single Nim file will link.
#
# All three were established by compiling rather than by reading, and each
# fails a long way from its cause without this recipe:
#
#   1. `isonim` vendors Facebook Yoga as a git submodule that a fresh
#      workspace does not initialise.  Absent, the first Nim file that touches
#      layout dies with `cannot find: .../yoga/yoga/YGConfig.cpp`.
#   2. Linking needs a tree-sitter grammar archive, built here from the ten
#      grammars this repo already vendors under `libs/` — `tree-sitter-nim`
#      does not ship `src/parser.c`, it is generated.
#   3. The link line carries `-ltree-sitter`, whose runtime this repo's dev
#      shell puts on neither the linker's search path nor LD_LIBRARY_PATH.
#
# IDEMPOTENT AND TIMESTAMP-GUARDED, because CI capacity is short and these
# submodules are large: git is invoked only for a submodule that is actually
# empty, and the archive is rebuilt only when a grammar source is newer than
# it.  A warm runner does no work.  Note what is NOT here: `--recursive` over
# all of `libs/`, which would fetch every vendored dependency in the repo to
# link ten grammars.
tui-prereqs:
  #!/usr/bin/env bash
  set -euo pipefail

  # 1. isonim's Yoga submodule.  Checked by the file the compiler names when it
  #    is missing, not by `dirExists`: an uninitialised submodule IS a
  #    directory, so its presence proves nothing.
  if [ -d ../isonim ]; then
    if [ ! -f ../isonim/src/isonim/layout/yoga/yoga/YGConfig.cpp ]; then
      echo "[tui-prereqs] initialising isonim's Yoga submodule"
      git -C ../isonim submodule update --init src/isonim/layout/yoga
    fi
  else
    echo "[tui-prereqs] ../isonim is not checked out; the TUI cannot build without it" >&2
    exit 1
  fi

  # 2. The grammar submodules the TUI links — exactly those, read from
  #    .gitmodules so this recipe and scripts/build-tui-grammars.sh cannot
  #    disagree about the set.
  missing=()
  while read -r path; do
    [ -n "${path}" ] || continue
    if [ ! -f "${path}/src/grammar.json" ] && [ ! -f "${path}/src/parser.c" ]; then
      missing+=("${path}")
    fi
  done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.path$' |
             awk '{print $2}' | grep '^libs/tree-sitter-')
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "[tui-prereqs] initialising ${#missing[@]} grammar submodule(s): ${missing[*]}"
    git submodule update --init "${missing[@]}"
  fi

  # 3. The archive, the generated parser, and the tree-sitter runtime.
  bash scripts/build-tui-grammars.sh

# Build the TUI binary.
#
# `--mm:orc -d:release` is the configuration CodeTracer-TUI.md §5.4 specifies,
# and CTUI-0 asks for it to be VERIFIED rather than assumed — the first draft's
# risk note about ORC was written without either configuration having been run.
# The test lane compiles the same code under the default debug flags, so both
# arms of that check exist and are exercised by different recipes.
build-tui: tui-prereqs
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p build/bin test-logs
  # The linker flags resolved by tui-prereqs.  Read rather than recomputed, so
  # the binary and the test lane link against the same runtime.
  read -r -a ts_flags < <(sed 's/^/--passL:/; s/ / --passL:/g' \
    build/grammars/tui-link-flags.txt)
  # WHICH GRAMMAR ARCHIVE THE LINKER IS HANDED, said explicitly.
  #
  # `isonim_tui/syntax/treesitter_ffi.nim` emits an archive path as `{.passl.}`,
  # and its default is an absolute path inside the isonim-tui checkout — a fact
  # about that sibling's build tree rather than about this binary.  Upstream now
  # reads it from `isonimTuiGrammarArchive {.strdefine.}`, so this names OUR
  # ten-grammar archive and the sibling path is never consulted.  Without the
  # define the link silently falls back to whatever sits at the baked path,
  # which `just grammars` in isonim-tui will happily replace with a TWO-grammar
  # archive; `test_tui_build_prerequisites.nim` asserts the member count at both
  # paths so that substitution cannot pass unnoticed.
  nim c --hints:off \
    --mm:orc -d:release \
    --path:src/frontend/viewmodel \
    "-d:isonimTuiGrammarArchive=${PWD}/build/grammars/libcodetracer_tui_grammars.a" \
    "${ts_flags[@]}" \
    --nimcache:build/nimcache/codetracer-tui \
    -o:build/bin/codetracer-tui \
    src/frontend/tui/main.nim
  echo "built build/bin/codetracer-tui ($(wc -c <build/bin/codetracer-tui) bytes)"

# Tier 1: the TUI suites that need no terminal.
#
# Fast, headless, and self-referential by construction — the in-process harness
# both emits the ANSI and validates the screen it derived from that emission,
# which is exactly why `test-tui-real-terminal` below exists and why CTUI-2
# makes cross-tier equivalence the campaign's third milestone rather than its
# last.
#
# CTUI-1 put `test_fixture_corpus.nim` in this lane, and it is the one suite
# here that is NOT self-contained: it opens real recorded traces through a real
# `replay-server`, and records them from `test-programs/` on a cold cache. So
# this lane needs `src/build-debug/bin/replay-server` (or $REPLAY_SERVER_BIN)
# and, until `test-logs/tui-fixtures/` is warm, `src/build-debug/bin/ct` plus
# the recorders the fixtures name. Missing ones are reported as counted
# `MISSING-PREREQ SKIP:` lines and an all-skipped run FAILS — see that file's
# header. The first run on a workspace therefore costs a few recordings; every
# run after it hits the content-addressed cache.
test-tui: tui-prereqs
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-tui.log) 2>&1
  bash ci/lib/run-nim-test-lane.sh tui

# Tier 2: the TUI suites that spawn the real binary in a real pty.
#
# Depends on `build-tui` because that is what the child process IS: TermAssert
# spawns `build/bin/codetracer-tui` and parses its byte stream with libvterm.
# A missing binary is reported by the suite, by name, with the recipe that
# builds it — never skipped.
test-tui-real-terminal: build-tui
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-tui-real-terminal.log) 2>&1
  bash ci/lib/run-nim-test-lane.sh tui-real-terminal

# PLAT-1: `--ui` front-end selection, end to end
# (codetracer-specs/CLI/ct/ui-selection.md).
#
# FOUR REAL ARTEFACTS, and the recipe names the two it can build. The lane
# drives `codetracer-launcher/out/launcher` -> `src/build-debug/bin/ct` ->
# `build/bin/codetracer-tui` on a real recording, and separately starts a real
# `ct host` server (which spawns `node server_index.js`) twice, once by each
# spelling, and compares the served bytes.
#
# `build-tui` and `build-once` are dependencies because the suites ASSERT those
# binaries exist rather than skipping when they do not (docs/tui-testing.md
# rule 1), so a lane that did not build them would be red for a reason that is
# not a defect. The LAUNCHER is deliberately NOT built here: it lives in a
# sibling repository, PLAT-1's own first test is that this repository has not
# changed it, and a recipe that rebuilt it would be the one thing able to
# invalidate that claim. The suite names `cd ../codetracer-launcher && just
# build` when it is missing.
# PLAT-20: build the GPUI front-end component.
#
# NO GRAMMAR PREREQUISITE and no `tui-prereqs`, deliberately: this binary links
# no terminal renderer and no tree-sitter archive, which is the shell/leaf split
# being true of the BUILD rather than only of the source. It does need
# `isonim-gpui`'s Rust shim at RUN time — `isonim_gpui/bindings.nim` dlopens
# `libgpui_nim_shim.so` and falls back to a bare soname — so the recipe says so
# rather than producing a binary that dies on its first call.
#
# `--mm:orc -d:release` matches `build-tui`, for the same reason CTUI-0 gives
# there: the shipped configuration is the one that should be built by the
# build recipe, and the test lane compiles the same code under debug flags, so
# both arms exist and are exercised by different recipes.
build-gpui:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p build/bin test-logs
  shim_dir="$(cd .. 2>/dev/null && pwd)/isonim-gpui/rust/target/debug"
  if [ ! -e "${shim_dir}/libgpui_nim_shim.so" ] && \
     [ ! -e "${shim_dir}/libgpui_nim_shim.dylib" ]; then
    echo "WARNING: isonim-gpui's Rust shim is not built at ${shim_dir}." >&2
    echo "  codetracer-gpui will compile, and will fail at run time when it" >&2
    echo "  dlopens the shim. Build it with:" >&2
    echo "    cd ../isonim-gpui && just rust-build" >&2
  fi
  nim c --hints:off \
    --mm:orc -d:release \
    --path:src/frontend/viewmodel \
    --nimcache:build/nimcache/codetracer-gpui \
    -o:build/bin/codetracer-gpui \
    src/frontend/gpui/main.nim
  echo "built build/bin/codetracer-gpui ($(wc -c <build/bin/codetracer-gpui) bytes)"

# PLAT-20: the GPUI shell's own suites — the dock projection against gpui-kit's
# committed fixtures, and the shell/leaf split through the real isonim-gpui
# shim.
#
# The two CROSS-front-end suites are in the `tui` lane, because comparing the
# two projections needs both and only that lane links `isonim_tui`. This is
# noted here rather than only in `ci/lib/test-lane-files.sh` so somebody
# running `just test-gpui-shell` to check PLAT-20 knows it is half the story.
test-gpui-shell:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-gpui-shell.log) 2>&1
  bash ci/lib/run-nim-test-lane.sh gpui-shell

# ─── PLAT-35: cross-renderer visual alignment ───────────────────────────────
#
# "The GPUI front-end looks like the Electron one", as a check that can fail.
# THREE recipes, because the three things they do fail for different reasons
# and one must not mask another.
#
#   plat35-capture-electron   drives the REAL Electron front-end under Xvfb
#                             through the shared scenario definition, writes a
#                             PNG per named view and the eight layout answers
#                             per scenario, and asserts the tier-1 determinism
#                             canary WITHIN that renderer.
#   plat35-answer-independence  the §30a source scan: neither producer may read
#                             the other's medium, and the shared vocabulary may
#                             hold no reader at all. Carries its own positive
#                             control, so an absence grep that has stopped
#                             matching cannot pass.
#   test-plat35-visual-alignment  the GATE: §3's oracle table parsed at run
#                             time, the two-direction set equality with the
#                             cardinality on both sides, and eight questions
#                             times six scenarios compared as values.
#
# THE ORDER MATTERS AND IS NOT ENFORCED HERE ON PURPOSE. The Nim gate reads the
# Electron arm's recorded answers and FAILS BY NAME when they are absent,
# naming the capture recipe — rather than skipping, and rather than this recipe
# silently re-capturing. A gate that regenerates its own input is a gate that
# can never be stale and can never be wrong.

# Capture the Electron front-end's named views and layout answers.
# Needs a built frontend (`just build-once`) and a recorded `calc` fixture
# (`just test-tui` once).
#
# ITS OWN Xvfb, AT `-dpi 96`, AND THAT IS THE WHOLE REASON THIS RECIPE DOES NOT
# DELEGATE TO `test-gui-prebuilt`.
#
# Measured 2026-09-21. `test-gui-prebuilt` starts `Xvfb :N -screen 0
# 1920x1080x24` with no `-dpi`, the X server then reports about 100.5 dpi, and
# Chromium derives a device scale factor of 1.046875 from it. A screenshot is
# in DEVICE pixels, so a 1440x900 CSS viewport lands on disk as 1508x943 and
# the default 1837x1034 window lands as 1923x1082 — which is exactly the size
# all six committed captures had, including the three declared 1440x900.
#
# At `-dpi 96` the factor is exactly 1, the window's content size, the page's
# CSS viewport and the PNG's IHDR all carry the same two numbers, and the
# capture can assert them against the scenario's declared viewport instead of
# against nothing. The spec asserts `devicePixelRatio == 1` and names this
# recipe when it does not hold, so running the lane the other way fails rather
# than quietly writing 1.046875x images again.
#
# AND A 2560x1440 SCREEN, WHICH IS LARGER THAN THE LARGEST DECLARED VIEWPORT.
# Measured 2026-09-21, by the new assertion catching it on its first run: on a
# 1920x1080 screen a window asked for a 1920x1080 CONTENT area gets a
# 1919x1079 CSS viewport — the screen has to hold the window's frame as well as
# its content, so the widest viewport in the matrix cannot equal the widest
# screen. The three `wide` scenarios failed by name with
# `Expected "1920x1080" / Received "1919x1079"`, which is the assertion doing
# the job the declaration could not: the same three had been silently captured
# at 1923x1082 for the whole milestone.
#
# The screen is therefore sized from the matrix rather than from the host, with
# headroom. A viewport added to `scenarios.json` that does not fit here will
# fail the same way, by name, in the same place.
plat35-capture-electron *args:
  #!/usr/bin/env bash
  set -euo pipefail
  export CODETRACER_ELECTRON_ARGS="${CODETRACER_ELECTRON_ARGS:---no-sandbox --no-zygote --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage}"
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*|*_NT*|Darwin)
      just test-e2e tests/visual/visual-alignment-capture.spec.ts {{args}}
      ;;
    *)
      DISPLAY_NUM=99
      while [ -e "/tmp/.X${DISPLAY_NUM}-lock" ]; do
        DISPLAY_NUM=$((DISPLAY_NUM + 1))
      done
      Xvfb ":${DISPLAY_NUM}" -screen 0 2560x1440x24 -dpi 96 -nolisten tcp &
      XVFB_PID=$!
      trap "kill $XVFB_PID 2>/dev/null || true" EXIT
      sleep 1
      export DISPLAY=":${DISPLAY_NUM}"
      just test-e2e tests/visual/visual-alignment-capture.spec.ts {{args}}
      ;;
  esac

# The §30a arm: the two answer producers are independent readers.
plat35-answer-independence:
  bash ci/test/plat35-answer-independence.sh

# The gate. Runs the GPUI arm live (real recording, real replay-server, real
# shadow tree) and compares it against the recorded Electron arm.
test-plat35-visual-alignment:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-plat35-visual-alignment.log) 2>&1
  bash ci/test/plat35-answer-independence.sh
  bash ci/test/editor-model-case-floor.sh PLAT-35

# ─── PLAT-37: a window that opens, and a frame a human can look at ──────────
#
# THREE RECIPES, AND THE SPLIT IS THE CAPABILITY LINE.
#
#   plat37-capture   needs a COMPOSITOR. It opens real windows on headless
#                    sway, reads the pixels back with `grim`, runs the four
#                    compositor configurations and writes `build/plat37/`.
#                    It asserts almost nothing.
#   plat37-measure   needs the FRAMES (and GuiAssert). It turns the capture
#                    into `src/tests/visual/plat37-measurements.json`, which
#                    is committed — the same arrangement as PLAT-35's
#                    recorded Electron answers, and for the same reason.
#   plat37-case-floor  needs NEITHER. It is the gate, and it runs anywhere,
#                    which is what lets `editor-model-case-floors` carry it.
#
# The shims are NOT built here. `cargo build --features gpui-backend` run from
# this repo's dev shell fails to LINK — `rust-lld: error: unable to find
# library -lxcb / -lxkbcommon / -lxkbcommon-x11`, measured 2026-09-22 —
# because those are declared in `isonim-gpui`'s own `flake.nix`. A cross-repo
# build belongs to the repo that owns it:
#
#     cd ../isonim-gpui && nix develop --command just plat37-shims
plat37-capture *args:
  bash ci/test/plat37-window-frame.sh {{args}}

plat37-measure:
  #!/usr/bin/env bash
  set -euo pipefail
  # The same two paths the `gpui-shell` lane carries, read from the one place
  # that answers that question rather than transcribed here (§30).
  # shellcheck source=/dev/null
  . ci/lib/test-lane-files.sh
  # shellcheck disable=SC2046,SC2086  # the flag string must word-split
  nim c -r --hints:off $(test_lane_extra_flags gpui-shell) \
    --nimcache:build/nimcache/plat37-measure \
    -o:build/plat37/plat37-measure \
    ci/test/plat37_measure.nim

# The rejected threshold candidates, as a runnable sweep (§36b). It adds NO
# gate of its own on purpose: asserting that the losers ARE vacuous would pin
# a property of the corpus nothing depends on.
plat37-threshold-probe:
  #!/usr/bin/env bash
  set -euo pipefail
  # shellcheck source=/dev/null
  . ci/lib/test-lane-files.sh
  # shellcheck disable=SC2046,SC2086
  nim c -r --hints:off $(test_lane_extra_flags gpui-shell) \
    --nimcache:build/nimcache/plat37-threshold-probe \
    -o:build/plat37/plat37-threshold-probe \
    ci/test/plat37_threshold_probe.nim

plat37-case-floor:
  bash ci/test/editor-model-case-floor.sh PLAT-37

# PLAT-38 — A REAL KEY, through the compositor's own `wl_seat`, into a focused
# `codetracer-gpui` window, read back from the RUST-SIDE element store.
#
# It needs the WINDOWED shim, which is built by the sibling that owns it —
# linking it needs `-lxcb`, `-lxkbcommon` and `-lxkbcommon-x11`, declared in
# `isonim-gpui`'s `flake.nix` and not in this repo's shell:
#
#     cd ../isonim-gpui && nix develop --command just plat37-shims
#
# The lane REFUSES if that shim is absent rather than running the featureless
# one, because a featureless run opens no window, receives no key, and reports
# an empty arrival list that looks exactly like a delivery failure.
plat38-capture *args:
  bash ci/test/plat38-keystroke.sh {{args}}

plat38-case-floor:
  bash ci/test/editor-model-case-floor.sh PLAT-38

# PLAT-39 — the unprivileged oracle: pixels to domain models.
#
# The whole point of this milestone is that it needs NOTHING from the
# application: no compositor, no shim, no renderer, no running binary. It reads
# committed PNGs captured from both front-ends and reconstructs the same three
# declared model types out of them. If any recipe below ever grows a dependency
# on a live process, the independence it exists to demonstrate is already gone.
plat39-case-floor:
  bash ci/test/editor-model-case-floor.sh PLAT-39

# LAW-R4: the vision producer imports nothing from viewmodel/ or the page
# objects, asserted with a DERIVED subject set and both polarities controlled.
plat39-oracle-independence:
  bash ci/test/plat39-oracle-independence.sh

# Prints what the oracle reads out of every pinned frame, next to nothing. A
# human can put this beside the screenshots. NOT-A-CI-GATE: it prints; it does
# not assert. The assertions are in `test_screen_oracle.nim`.
plat39-probe:
  #!/usr/bin/env bash
  set -euo pipefail
  nim c -r --hints:off --warnings:off --path:../GuiAssert/src \
    --nimcache:nimcache/plat39probe -o:build/plat39_probe \
    src/tests/visual/screen_oracle/plat39_probe.nim

# PLAT-39 — regenerate the committed readings record from the captured corpus.
#
# Run this after a recapture. The record is what lets the PORTABLE half of this
# milestone assert in CI, where the capture step is wired into no workflow and
# the frames therefore never exist. It refuses to write from an absent corpus:
# every reading would be `urFrameMissing` wearing the shape of an answer.
plat39-record:
  #!/usr/bin/env bash
  set -euo pipefail
  nim c -r --hints:off --warnings:off --path:../GuiAssert/src \
    --nimcache:nimcache/plat39rec -o:build/plat39_record \
    src/tests/visual/screen_oracle/plat39_record.nim

# PLAT-39 — the PORTABLE gate. Asserts the recorded readings against the
# committed DOM-derived answers, and reads NO images: no GuiAssert, no ffmpeg,
# no tesseract. This is the one that runs in CI.
#
# It is strictly weaker than `plat39-case-floor` and does not replace it: it
# cannot notice that the reader stopped working, because nothing here executes
# the reader. What it does catch is a recorded pixel-derived value disagreeing
# with a DOM-derived one, and those two share no code.
plat39-record-gate:
  nim c -r --hints:off --warnings:off --nimcache:nimcache/plat39recgate \
    -o:build/test_plat39_record \
    src/tests/visual/screen_oracle/test_plat39_record.nim

# PLAT-42 — record the GPUI editor's debugger surfaces from the SHIPPED binary.
# Headless (`--report-plan`), but needs `just build-gpui`, the isonim-gpui shim
# and the calc recording — none of which CI has — so the measurement is taken
# here and committed, and `plat42-case-floor` asserts the record anywhere.
plat42-surfaces-record:
  python3 ci/test/plat42_surfaces_record.py

plat42-case-floor:
  bash ci/test/editor-model-case-floor.sh PLAT-42

# PLAT-42 — the frame budget measured in a real window (reported with the host
# load, never asserted against a constant), and the four surfaces framed in
# real windows with their pixel twins. Both need a compositor and a binary
# built against the windowed shim (see each script's header).
plat42-frame-budget:
  bash ci/test/plat42-frame-budget.sh

plat42-frames-record:
  python3 ci/test/plat42_frames_record.py

plat42-surfaces-window:
  bash ci/test/plat42-surfaces-window.sh

plat42-window-record:
  #!/usr/bin/env bash
  set -euo pipefail
  nim c -r --hints:off --warnings:off --path:../GuiAssert/src \
    --nimcache:nimcache/plat42win -o:build/plat42_window_record \
    src/tests/visual/screen_oracle/plat42_window_record.nim

# PLAT-43 — the keymap selector's counted floor (Tier 1), and its pty half
# against the shipped binary.
plat43-case-floor:
  bash ci/test/editor-model-case-floor.sh PLAT-43

# PLAT-44 — the GPUI editing arm: the counted floor (portable suites), and the
# window lane (a real keystroke through a real compositor changes the file).
plat44-case-floor:
  bash ci/test/editor-model-case-floor.sh PLAT-44

plat44-edit-window:
  bash ci/test/plat44-edit-window.sh

# Read the window run's frames through PLAT-39's pixel reader and commit the
# record `test_plat44_edit_window.nim` asserts over. Needs `tesseract`.
plat44-window-record:
  #!/usr/bin/env bash
  set -euo pipefail
  nim c -r --hints:off --warnings:off --path:../GuiAssert/src \
    --nimcache:nimcache/plat44rec -o:build/plat44_window_record \
    src/tests/visual/screen_oracle/plat44_window_record.nim

# PLAT-44 — PLAT-34's sequences typed into a REAL window. Three steps: the
# plan (the keys each reachable sequence takes, from the same translation the
# headless suite uses), the window run (one sway, one window per sequence,
# `wtype` typing, the file and the exit caret recorded, plus a negative twin),
# and the committed record `test_plat44_sequences_window.nim` asserts over.
plat44-sequences-plan:
  nim c -r --hints:off --warnings:off --path:src/frontend/viewmodel \
    --nimcache:nimcache/plat44plan -o:build/plat44_sequences_plan \
    ci/test/plat44_sequences_plan.nim

plat44-sequences-window:
  bash ci/test/plat44-sequences-window.sh

plat44-sequences-record:
  python3 ci/test/plat44_sequences_window_record.py

# PLAT-40 — every pane producer has a caller a USER can reach.
#
# *A unit test is a production caller as far as a coverage tool is concerned,
# and is not one as far as a user is concerned.* This gate is `grep` for the
# call site run against the shipped tree, which is the only instrument that
# finds the campaign's signature defect — the mechanism works and nothing feeds
# it. It needs no toolchain and no build, so it costs nothing to run often.
plat40-production-callers:
  bash ci/test/plat40-production-callers.sh

# PLAT-40 — DIFF-9: the call trace, event log and breakpoint list, read OFF
# THE SCREEN of the native window and of the desktop. Three recipes, split on
# the capability line exactly as PLAT-37's are:
#
#   plat40-capture-window    needs a COMPOSITOR and the windowed binary
#                            (CODETRACER_PLAT40_BIN, built with
#                            -d:gpuiShimPath): `ci/test/plat40-panes-window.sh`.
#   plat40-capture-electron  needs Xvfb and the built desktop app.
#   plat40-record            needs the frames and GuiAssert; writes the
#                            committed `src/tests/visual/plat40-readings.json`.
#
# The gate itself (`test_plat40_producers.nim`, in the `tui` lane) asserts over
# the record and runs everywhere.
plat40-capture-window:
  bash ci/test/plat40-panes-window.sh

plat40-capture-electron *args:
  #!/usr/bin/env bash
  set -euo pipefail
  export CODETRACER_ELECTRON_ARGS="${CODETRACER_ELECTRON_ARGS:---no-sandbox --no-zygote --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage}"
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*|*_NT*|Darwin)
      just test-e2e tests/visual/plat40-panes-capture.spec.ts {{args}}
      ;;
    *)
      # A screen LARGER than the 1920x1080 window, as PLAT-35's capture uses:
      # on a 1920x1080 screen the window's content area lands at 1920x1081
      # and the capture refuses it.
      DISPLAY_NUM=99
      while [ -e "/tmp/.X${DISPLAY_NUM}-lock" ]; do
        DISPLAY_NUM=$((DISPLAY_NUM + 1))
      done
      Xvfb ":${DISPLAY_NUM}" -screen 0 2560x1440x24 -dpi 96 -nolisten tcp &
      XVFB_PID=$!
      trap "kill $XVFB_PID 2>/dev/null || true" EXIT
      sleep 1
      export DISPLAY=":${DISPLAY_NUM}"
      just test-e2e tests/visual/plat40-panes-capture.spec.ts {{args}}
      ;;
  esac

plat40-record:
  nim c -r --hints:off --warnings:off --path:../GuiAssert/src \
    --nimcache:nimcache/plat40rec -o:build/plat40_record \
    src/tests/visual/screen_oracle/plat40_record.nim

# PLAT-41 — the thirteen panes, both front-ends, from RUNS: the native window
# (its plan's per-pane census, and a frame of the eight newly expressed panes
# for PLAT-39's reader) and the desktop's DOM census at the same stop. Split
# on the capability line as PLAT-40's recipes are; the gate
# (`test_plat41_parity.nim`, in the `tui` lane) asserts the committed record.
plat41-capture-window:
  bash ci/test/plat41-panes-window.sh

plat41-capture-electron *args:
  #!/usr/bin/env bash
  set -euo pipefail
  export CODETRACER_ELECTRON_ARGS="${CODETRACER_ELECTRON_ARGS:---no-sandbox --no-zygote --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage}"
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*|*_NT*|Darwin)
      just test-e2e tests/visual/plat41-parity-capture.spec.ts {{args}}
      ;;
    *)
      DISPLAY_NUM=99
      while [ -e "/tmp/.X${DISPLAY_NUM}-lock" ]; do
        DISPLAY_NUM=$((DISPLAY_NUM + 1))
      done
      Xvfb ":${DISPLAY_NUM}" -screen 0 2560x1440x24 -dpi 96 -nolisten tcp &
      XVFB_PID=$!
      trap "kill $XVFB_PID 2>/dev/null || true" EXIT
      sleep 1
      export DISPLAY=":${DISPLAY_NUM}"
      just test-e2e tests/visual/plat41-parity-capture.spec.ts {{args}}
      ;;
  esac

plat41-record:
  nim c -r --hints:off --warnings:off --path:../GuiAssert/src \
    --nimcache:nimcache/plat41rec -o:build/plat41_record \
    src/tests/visual/screen_oracle/plat41_record.nim

# The rejected change-fraction thresholds, as a runnable sweep (§36b). It adds
# NO gate of its own on purpose: asserting that the losers ARE vacuous would
# pin a property of the corpus nothing depends on, and would make a future
# improvement to the capture fail a check about roads not taken.
plat38-threshold-probe:
  #!/usr/bin/env bash
  set -euo pipefail
  if [ ! -f build/plat38/vision-before.ppm ] || [ ! -f build/plat38/vision-after.ppm ]; then
    echo "PLAT-38: no captured frames in build/plat38/. Run \`just plat38-capture\` first."
    echo "This probe re-takes a MEASUREMENT; it cannot invent the frames."
    exit 1
  fi
  for t in 0.0001 0.001 0.002 0.01 0.05; do
    python3 - build/plat38/vision-before.ppm build/plat38/vision-after.ppm \
      build/plat38/vision-blank.ppm "$t" <<'PY'
  import sys
  sys.path.insert(0, "ci/test")
  from plat38_frames import read_ppm, changed_fraction
  b, a, z, t = read_ppm(sys.argv[1]), read_ppm(sys.argv[2]), read_ppm(sys.argv[3]), float(sys.argv[4])
  ch = changed_fraction(b[2], a[2])
  bl = changed_fraction(z[2], z[2])
  print("threshold %-8s key-change %.6f %-8s blank %.6f %s" % (
      t, ch, "PASS" if ch > t else "VACUOUS", bl, "PASS" if bl < t else "FAILS-CONTROL"))
  PY
  done

test-ui-selection: build-once build-tui
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p test-logs
  exec > >(tee test-logs/test-ui-selection.log) 2>&1
  bash ci/lib/run-nim-test-lane.sh ui-selection


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
  cache="$(ci/lib/nim-cache-root.sh)/vm-native-$name"
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
    cache="$(ci/lib/nim-cache-root.sh)/vm-gated-$name"
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
  bash "${CODETRACER_REPO_ROOT_PATH}/ci/lib/npm-install.sh" "${CODETRACER_REPO_ROOT_PATH}/src/tests/gui" && \
    cd "${CODETRACER_REPO_ROOT_PATH}/src/tests/gui" && \
    npx playwright test --workers=1 \
      tests/agentic-coding/agentic-agentfs-optional.spec.ts

developer-setup *flags:
  bash scripts/developer-setup.sh {{flags}}

# Capture automated animations for the README in animated WebP format (for review).
# The results will be placed in test-results/readme-animations-review/
capture-readme-animations-review:
  bash scripts/docs/capture-readme-animations.sh

# ─── CodeTracer TUI benchmarks (CTUI-14) ────────────────────────────────────
#
# `metacraft-dev-guidelines/policies/continuous-benchmarking.md` §1: "every
# benchmark must be runnable with a single `just` command", `just bench` for the
# full suite and `just bench --quick` for the abbreviated CI run. §2 and §3: the
# run writes `bench-results/benchmark_results.json` in github-action-benchmark
# format and a self-contained `bench-results/report.html`.
#
# BUILT WITH `-d:release`, and that is a decision rather than a default.  The
# fuzzy-palette gate is the reason: CTUI-10 measured it at 3.88 ms idle and
# 7.13 ms under 2x oversubscription against an 8 ms gate ON A DEBUG BUILD, with
# 7 of 9 runs over.  A performance figure taken from a build nobody ships is a
# figure a gate cannot be set from.
#
# Depends on `build-tui` because four of the metrics are properties of the
# SHIPPED PROCESS — cold start, time to a usable debugger, resident set and
# idle CPU — and are measured by spawning it in a real pty.  The other four are
# properties of the render path and run in process against a real recording,
# opened through a real `replay-server`; there is no mock in the suite.
#
# The human-readable summary goes to STDERR (policy §1) and every figure carries
# the host's load average, because a benchmark number without one cannot be
# compared with another.
build-tui-benchmarks: tui-prereqs build-tui
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p build/bin build/nimcache
  link_flags=""
  if [ -r build/grammars/tui-link-flags.txt ]; then
    link_flags=$(sed 's/^/--passL:/; s/ / --passL:/g' \
      build/grammars/tui-link-flags.txt)
  fi
  nim c -d:release --path:src/frontend/viewmodel ${link_flags} \
    "-d:isonimTuiGrammarArchive=${PWD}/build/grammars/libcodetracer_tui_grammars.a" \
    --nimcache:build/nimcache/tui-benchmarks \
    -o:build/bin/tui-benchmarks \
    src/frontend/tui/benchmarks/tui_benchmarks.nim
  echo "built build/bin/tui-benchmarks"

bench *args: build-tui-benchmarks
  ./build/bin/tui-benchmarks {{args}}

# PLAT-24 — the text-store measurement that decided what an editable source
# document is stored in (Editor-ViewModel.md §4).
#
# `-d:release` is FORCED rather than optional, and the recipe says why:
# Verification-Harness-Traps.md §28b — a timing quotes its build, and a figure
# taken at a different optimisation level or under a different memory manager
# is a figure about a different program. The binary prints the build it was
# compiled with beside every number, so the two cannot come apart.
#
# It runs BOTH candidate stores in one process, interleaved round by round, and
# prints both ratios against the same gate: a gate whose losing arm is never
# executed is a gate nobody has seen fail. Corpus manifests land in
# `test-logs/plat24/`.
#
#   just bench-text-store                       # 1K, 40K, 200K, two takes
#   just bench-text-store --sizes=1000 --takes=1 --rounds=5      # quick
#   just bench-text-store --grapheme-only --sizes=200000         # §4.5 alone,
#       retaken against the eighteen-document Unicode corpus, with the ASCII arm
#       and the cluster-dense arm sampled by ONE function and measured in the
#       SAME round. See Editor-ViewModel.md §4.5a.
bench-text-store *args:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p build/bin build/nimcache test-logs/plat24
  nim c -d:release --hints:off \
    --nimcache:build/nimcache/text-store-bench \
    -o:build/bin/text-store-bench \
    src/frontend/viewmodel/benchmarks/text_store_bench.nim
  ./build/bin/text-store-bench {{args}} 2>&1 | tee test-logs/plat24/bench.log

# PLAT-24's COUNTED TARGET, gated.
#
# Editor-Model-Conformance-Suite.md §10.1 puts two numbers in two units in two
# homes: the assertion count lives in each suite as `const ExpectedAssertions`
# and is asserted by the suite against its own runtime tally, and the CASE FLOOR
# lives in the milestone on a `FLOOR: <n> cases` line. This gate is the second
# half — it reads that line out of the sibling `codetracer-specs` checkout at run
# time (never transcribed), fails BY NAME when the checkout is absent rather than
# skipping, and requires every named suite to contribute at least one `[OK]`.
#
# It gates PLAT-24 and nothing else, deliberately: a generic lane mechanism would
# change every lane's pass condition at once, and §10.1 assigns that elsewhere.
plat24-case-floor:
  bash ci/test/editor-model-case-floor.sh PLAT-24

# PLAT-25's COUNTED TARGET, gated by the SAME script.
#
# The gate also runs §7.1's two-way count over §3.1's `LAW-A*` table: ten ids
# published, ten ids run, both directions, cardinality asserted, and a killer
# cell that is empty or an em dash fails — because "an arm with no stated
# killer is not admitted".
plat25-case-floor:
  bash ci/test/editor-model-case-floor.sh PLAT-25

# PLAT-26's COUNTED TARGET, gated by the SAME script.
#
# The law-table oracle is PARAMETERISED rather than copied: PLAT-26 needs the
# same §7.1 two-way count over §3.2's `LAW-S*` table — six ids published, six
# ids run, both directions, cardinality asserted, and a killer cell that is
# empty or an em dash fails. A second script would have been a second parser
# and a second place for the grammar to drift.
plat26-case-floor:
  bash ci/test/editor-model-case-floor.sh PLAT-26

# PLAT-27's, PLAT-28's and PLAT-29's COUNTED TARGETS, gated by the SAME script.
#
# THESE THREE WERE MISSING UNTIL 2026-09-18 and the gap is worth naming rather
# than quietly filling: `ci/test/editor-model-case-floor.sh` grew table entries
# for PLAT-27 and PLAT-28 when those milestones landed, and neither added the
# recipe that runs it. A gate with an entry and no caller is a gate nobody runs,
# which is the campaign's own recurring defect arriving through a `just` target
# instead of through an assertion. PLAT-29 adds all three.
plat27-case-floor:
  bash ci/test/editor-model-case-floor.sh PLAT-27

plat28-case-floor:
  bash ci/test/editor-model-case-floor.sh PLAT-28

plat29-case-floor:
  bash ci/test/editor-model-case-floor.sh PLAT-29

# PLAT-30's COUNTED TARGET: 621 cases over the vocabulary's two suites. The
# same script, the same `FLOOR:` parser, one more table entry — and a recipe in
# the same commit as the entry, which is the gap the comment above records
# PLAT-29 closing for three milestones at once.
plat30-case-floor:
  bash ci/test/editor-model-case-floor.sh PLAT-30

# PLAT-34's COUNTED TARGET: 58 cases over `DIFF-1`'s two halves.
#
# The second of its two suites is NATIVE-ONLY and needs the `tui` lane's link
# flags — it paints the terminal's editor into a real `StyledGrid` and renders
# the GPUI editor into the real Rust shadow tree, so it links `isonim_tui` AND
# `isonim_gpui`. The gate reads those flags out of `ci/lib/test-lane-files.sh`
# rather than carrying a second copy of them; see its table entry.
plat34-case-floor:
  bash ci/test/editor-model-case-floor.sh PLAT-34

# EVERY COUNTED TARGET IN THE CAMPAIGN, AND THIS IS THE RECIPE A LANE CALLS.
#
# WHAT WAS WRONG, MEASURED RATHER THAN ASSERTED
# ---------------------------------------------
# `ci/test/shell-gate-coverage.sh` has been reporting
# `ci/test/editor-model-case-floor.sh` as an UNRECORDED DARK GATE — reachable
# from no workflow lane, no recipe a lane calls, and no other reachable script.
# The seven recipes above are all of the second kind: a person types them. So
# every `FLOOR:` line published in `CodeTracer-Platform.milestones.org` for
# PLAT-24 … PLAT-30, and every `LAW-*` two-way count this script performs for
# five of them, proved nothing in CI — for six milestones, since PLAT-24.
#
# That is this campaign's signature defect (work goes into a gate, the gate goes
# into the tree, nothing runs it), found in the mechanism built to catch it, by
# the guard built to catch THAT. The guard was right and was being read as
# noise.
#
# THE COST, BECAUSE "IT ADDS RUNTIME WHILE CAPACITY IS SHORT" IS A REAL
# ARGUMENT AND HAS TO BE ANSWERED WITH A NUMBER
# ---------------------------------------------------------------------
# Measured 2026-09-19 on one host, `~/.cache/nim/test_editor_*_d` deleted first
# so every suite is a cold compile, all seven milestones in one pass:
#
#     PLAT-24 11s   PLAT-25  7s   PLAT-26 20s   PLAT-27 18s
#     PLAT-28  8s   PLAT-29 14s   PLAT-30  9s        TOTAL 92s
#
# Ninety-two seconds of gate, cold, for fourteen suites; `1m51s` measured
# through THIS recipe end to end, which is the number CI actually pays and
# includes `just`'s own start-up per invocation. It is not free — these suites
# also compile in `vm-unit`, so this is a second compile of most of them — but
# "prohibitive" it is not, and the runtime was the whole of the case for leaving
# six milestones' floors unenforced. A cost argument that has not been measured
# is an estimate, and this one was off by the margin between two minutes and a
# reason. The recipe-level figure is the one quoted in the workflow step, because
# quoting the smaller of two measurements you have taken is the same defect one
# size down.
#
# WHY ONE RECIPE AND NOT SEVEN STEPS. `shell-gate-coverage.sh` walks from
# workflow roots through recipes to scripts, so ONE recipe a lane calls is what
# turns the script on; seven steps would be seven places for the next milestone
# to be forgotten. The milestone ids are LITERAL here for the same reason the
# `test` recipe keeps its lane names literal — the walk reaches a name it can
# SEE, and a shell array element is not one.
#
# IT IS ALSO TWO-SIDED ABOUT ITSELF: the count of milestones it ran is asserted
# against the count of entries in the script's own table, so a milestone added
# to the script and not to this list fails here rather than passing silently —
# which is the same defect one level up.
editor-model-case-floors:
  #!/usr/bin/env bash
  set -uo pipefail
  failed=0
  ran=0
  deferred=0
  # MILESTONES WHOSE FLOOR NEEDS AN ARTEFACT THIS REPOSITORY DOES NOT CARRY.
  #
  # PLAT-39's suite reads the six frames under `src/tests/visual/captures/`,
  # which are GITIGNORED by PLAT-35's decision — a committed frame would pin
  # whichever run produced it, and five of six frames differ between runs. The
  # capture step that writes them (`plat35-capture-electron`, via `test-e2e`)
  # is NOT wired into any workflow, so in CI the frames are never produced at
  # all. Running PLAT-39 unconditionally here would fail every CI run for a
  # missing prerequisite rather than for a missing case.
  #
  # THIS IS A DECLARED DEFERRAL, NOT A SKIP, and the difference is the three
  # rules below:
  #   1. only a milestone on this list may defer — anything else that cannot
  #      run is a failure;
  #   2. a deferral is PRINTED, with the reason and the remedy;
  #   3. deferrals are COUNTED, and the two-way count against the script's
  #      table includes them, so a milestone cannot vanish by deferring.
  # A milestone that deferred while its prerequisite was PRESENT would be a
  # silent pass, so presence is tested rather than assumed.
  # PLAT-39's floor counts the LIVE, pixel-reading suite. Its portable half
  # (`plat39-record-gate`) asserts the committed record and runs everywhere,
  # including CI — so the milestone is not unasserted when this defers, it is
  # asserted more weakly, which the deferral message says.
  corpus_dependent() { case "$1" in PLAT-39) return 0 ;; *) return 1 ;; esac; }
  corpus_present() { [ -d src/tests/visual/captures/electron ] && \
    [ "$(find src/tests/visual/captures/electron -name '*.png' | wc -l)" -ge 6 ]; }
  for m in PLAT-24 PLAT-25 PLAT-26 PLAT-27 PLAT-28 PLAT-29 PLAT-30 PLAT-31 PLAT-32 PLAT-33 PLAT-34 PLAT-35 PLAT-36 PLAT-37 PLAT-38 PLAT-39 PLAT-40 PLAT-41 PLAT-42 PLAT-43 PLAT-44; do
    echo "=== ${m} ==="
    if corpus_dependent "${m}" && ! corpus_present; then
      echo "DEFERRED: ${m}'s floor reads src/tests/visual/captures/electron/,"
      echo "          which is gitignored and absent here. This is declared, not"
      echo "          silent: it is counted below and the milestone is named."
      echo "          The PORTABLE half still runs: just plat39-record-gate"
      echo "          Remedy for the pixel half: just plat35-capture-electron"
      deferred=$((deferred + 1))
      continue
    fi
    if bash ci/test/editor-model-case-floor.sh "${m}"; then
      ran=$((ran + 1))
    else
      echo "FAIL: ${m}'s counted target did not hold"
      failed=$((failed + 1))
    fi
  done
  # The script's own table is the oracle for this list. `grep` for the `case`
  # labels rather than for the usage comment, because a comment is prose.
  known="$(grep -cE '^PLAT-[0-9]+\)$' ci/test/editor-model-case-floor.sh)"
  echo "milestones gated: $((ran + failed)); deferred: ${deferred}; entries in the gate's table: ${known}"
  if [ "$((ran + failed + deferred))" -ne "${known}" ]; then
    echo "FAIL: this recipe accounts for $((ran + failed + deferred)) milestones and"
    echo "      ci/test/editor-model-case-floor.sh has a table entry for ${known}."
    echo "      A milestone with an entry and no caller is the exact defect this"
    echo "      recipe exists to have stopped."
    exit 1
  fi
  # THE THIRD EQUALITY: every milestone that PUBLISHES a floor has an entry in
  # the gate's table, and every entry is a published floor. The count above
  # catches a milestone added to one of the recipe and the table; it cannot
  # catch one added to NEITHER — PLAT-36's `FLOOR:` line sat unread for a
  # whole milestone that way. So the set of `FLOOR: <n> cases` lines in the
  # milestone file, keyed by the `** PLAT-<n>:` heading above each, is
  # compared with the table's `case` labels, both directions. An empty
  # published set is a refusal: a parse that found nothing would satisfy the
  # comparison (§4).
  spec="$(sed -n 's/^SPEC_REL="\(.*\)"$/\1/p' ci/test/editor-model-case-floor.sh)"
  if [ ! -f "${spec}" ]; then
    echo "FAIL: the milestone file the gate reads (${spec:-<unset>}) is absent"
    exit 1
  fi
  published="$(awk '/^\*\* PLAT-[0-9]+:/ { h = $2; sub(/:$/, "", h) }
                    /^[ \t]*FLOOR: [0-9]+ cases/ { print h }' "${spec}" | sort -u)"
  tabled="$(grep -oE '^PLAT-[0-9]+\)$' ci/test/editor-model-case-floor.sh | tr -d ')' | sort -u)"
  if [ -z "${published}" ]; then
    echo "FAIL: no \`FLOOR: <n> cases\` line was found in ${spec}"
    exit 1
  fi
  unGated="$(comm -23 <(echo "${published}") <(echo "${tabled}") | tr '\n' ' ')"
  unPublished="$(comm -13 <(echo "${published}") <(echo "${tabled}") | tr '\n' ' ')"
  echo "floors published: $(echo "${published}" | wc -l); entries in the gate's table: $(echo "${tabled}" | wc -l)"
  if [ -n "${unGated// /}" ] || [ -n "${unPublished// /}" ]; then
    [ -n "${unGated// /}" ] && echo "FAIL: a published floor with no gate entry: ${unGated}"
    [ -n "${unPublished// /}" ] && echo "FAIL: a gate entry with no published floor: ${unPublished}"
    exit 1
  fi
  if [ "${failed}" -ne 0 ]; then
    echo "FAIL: ${failed} milestone(s) below their published floor"
    exit 1
  fi
  if [ "${deferred}" -ne 0 ]; then
    echo "OK: ${ran} milestones meet the floors published in codetracer-specs;"
    echo "    ${deferred} deferred for a named, absent prerequisite (see above)."
  else
    echo "OK: ${ran} milestones meet the floors published in codetracer-specs."
  fi

# PLAT-29's VERIFICATION GATE: the editor model's transitive import closure
# contains no async, no I/O, no process, no socket and no clock.
#
# Also run by `ci/lint/nim.sh`, beside the two other consumers of the same
# import extractor. This recipe exists so a developer can run it alone, in the
# second or so it takes, rather than through a twenty-step lint.
test-editor-import-closure:
  bash ci/test/editor-import-closure.sh

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
         ( ( cd "$sibling" && nix develop '.?submodules=1' --command true >/dev/null 2>&1 ) || \
           ( cd "$sibling" && nix develop '.' --command true >/dev/null 2>&1 ) ); then
        # Preferred path (CI + clean dev checkouts): build inside the
        # sibling's own Nix dev shell so its pinned LLVM/LLDB toolchain is
        # used and its shellHook runs. This is exactly the backend's own CI
        # invocation (``nix develop .?submodules=1 --command just build``).
        # ``cd "$sibling"`` + local ``.`` flake ref honours the dirty
        # working tree; the ``nix develop ... true`` guard above confirms
        # the devShell actually evaluates before we commit to this branch
        # (the sibling's ``path:libs/...`` flake inputs can fail to lock
        # under a dirty workspace checkout). ``unset`` clears the C/C++
        # compiler env leaking from the codetracer shell so the sibling
        # toolchain owns it.
        #
        # LLVM_CONFIG / LLDB_LIB_PATH / LLDB_ADDITIONAL_INCLUDE_DIRS are
        # deliberately NOT unset here, and they used to be. Measured in the
        # sibling's shell rather than assumed:
        #
        #   * LLVM_CONFIG and LLDB_LIB_PATH are exported UNCONDITIONALLY by
        #     the sibling's shellHook (its nix/shells/main.nix), so by the
        #     time this bash runs the hook has already replaced whatever
        #     leaked in -- entering the shell with both set to ``/bogus``
        #     yields the two nixpkgs store paths. Unsetting them therefore
        #     discards the sibling's OWN values, never the leaked ones.
        #   * LLDB_ADDITIONAL_INCLUDE_DIRS is not exported by that hook at
        #     all; only the sibling's macOS-only ``build-mcr`` recipe
        #     derives it, and only when it is empty. Unsetting it here can
        #     at best cost that recipe an extra ``nix build``.
        #
        # And the premise the old unset rested on does not hold either: the
        # codetracer dev shell sets none of the three (it sets CC/CXX), so
        # there was nothing of ours to clear.
        #
        # Dropping the sibling's LLDB paths was harmless on macOS, where
        # ``backend_target`` is ``build-mcr`` and that recipe re-provisions
        # each var via ``nix build`` when unset. On Linux ``backend_target``
        # is ``build`` -- a bare ``cargo build`` with no provisioning -- so
        # lldb-sys's build script failed with "unable to locate shared
        # library of liblldb" and ``just test-mcr-dap-flow`` could never
        # reach the flow tests.
        backend_flake_ref='.?submodules=1'
        if ! ( cd "$sibling" && nix develop "$backend_flake_ref" --command true >/dev/null 2>&1 ); then
            backend_flake_ref='.'
        fi
        ( cd "$sibling" && nix develop "$backend_flake_ref" --command bash -lc \
            "unset CXXFLAGS CC CXX; just $backend_target" )
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
