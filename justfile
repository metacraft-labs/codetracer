build:
  bash scripts/build.sh

build-once:
  bash scripts/build-once.sh

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

build-app-image:
  ./appimage-scripts/build_appimage.sh


# Run all Rust tests (db-backend unit + integration, backend-manager).
test-rust:
  #!/usr/bin/env bash
  set -e
  pushd src/db-backend
  # Unit tests (inside the binary)
  cargo nextest run --release --bin replay-server
  cargo nextest run --release --bin replay-server --run-ignored ignored-only
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

# Run all GUI tests headlessly (TypeScript Playwright e2e suite).
# On Linux, uses a virtual display (Xvfb) — same as CI.
# On Windows, no virtual display is needed; Electron runs natively.
# For visible windows on your desktop, use `just test-gui-visible` instead.
test-gui *args:
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

# Run GUI tests with windows visible on the current desktop session.
# On Linux, requires a running display server ($DISPLAY must be set).
# On Windows, always works (no $DISPLAY needed).
test-gui-visible *args:
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

cachix-push-nix-package:
  cachix push metacraft-labs-codetracer $(nix build --print-out-paths ".?submodules=1#codetracer")

cachix-push-devshell:
  cachix push metacraft-labs-codetracer $(nix build --print-out-paths .#devShells.x86_64-linux.default)

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
# Skip patterns:
#   integration/real_backend_test  — requires stdio_backend (native process spawning)
#   integration/language_smoke_test — requires headless_session + ct binary
#   multi-replay/multi_session_test — requires headless_session
#   noir-space-ship/noir_space_ship_test — requires headless_session

# Compile and run all ViewModel headless tests with the native (C) backend.
test-vm-native:
  #!/usr/bin/env bash
  set -e
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
test-vm-js:
  #!/usr/bin/env bash
  set -e
  echo "=== ViewModel tests (JS backend) ==="
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

developer-setup *flags:
  bash scripts/developer-setup.sh {{flags}}

# Capture automated animations for the README in animated WebP format (for review).
# The results will be placed in test-results/readme-animations-review/
capture-readme-animations-review:
  bash scripts/docs/capture-readme-animations.sh
