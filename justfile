build:
  #!/usr/bin/env bash

  # (alexander) we still need to run direnv reload here, so
  # think if we ned this here
  # Make sure all submodules are up to date
  # git submodule sync
  # git submodule update --init --recursive

  # Build CodeTracer once, so we can run the user-setup command
  # TODO: alexander think more about this command
  # cd src
  # tup build-debug
  # build-debug/codetracer user-setup

  # Start building continuously
  cd src
  tup build-debug
  tup monitor -a
  cd ../

  # start webpack
  node_modules/.bin/webpack --watch --progress & # building frontend_bundle.js

  # Start the JavaScript and CSS hot-reloading server
  # TODO browser-sync is currently missing
  # node build-debug/browsersync_serv.js &

build-once:
  #!/usr/bin/env bash

  # We have to make the dist directory here, because it's missing on a fresh check out
  # It will be created by the webpack command below, but we have an a chicken and egg
  # problem because the Tupfiles refer to it.
  mkdir public/dist

  cd src
  tup build-debug
  cd ..

  # Build frontend_bundle.js in the dist folder
  node_modules/.bin/webpack --progress

  # We need to execute another tup run because webpack may have created some new files
  # that tup will discover
  cd src
  tup build-debug

build-docs:
  #!/usr/bin/env bash
  cd docs/book/
  mdbook build

build-ui-js output:
  nim1 \
    -d:chronicles_enabled=off \
    -d:ctRenderer \
    -d:ctInExtension \
    --debugInfo:on \
    --lineDir:on \
    --hotCodeReloading:on \
    --out:{{output}} \
    js src/frontend/ui_js.nim

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

tester := "src/build-debug/bin/tester"

test-ui headless="0":
  #!/usr/bin/env bash
  set -e

  if [[ "{{headless}}" == "0" ]]; then
    {{tester}} ui
  else
    xvfb-run {{tester}} ui
  fi

# Run all Rust tests (db-backend unit + integration, backend-manager).
test-rust:
  #!/usr/bin/env bash
  set -e
  pushd src/db-backend
  # Unit tests (inside the binary)
  cargo test --release --bin db-backend
  cargo test --release --bin db-backend -- --ignored
  # Integration tests (tests/*.rs): DAP protocol, flow tests, etc.
  # Flow tests that need ct-rr-support/rr skip automatically when unavailable.
  cargo test --release --test '*'
  popd
  pushd src/backend-manager
  cargo test --release
  popd

# Run all non-GUI tests.
test:
  #!/usr/bin/env bash
  set -e
  just test-rust
  just test-frontend-js
  just test-python-recorder
  just test-nimsuggest
  if [ "${CODETRACER_RR_BACKEND_PRESENT:-}" = "1" ]; then
    echo "codetracer-rr-backend detected — running cross-repo tests..."
    just cross-test
  else
    echo "CODETRACER_RR_BACKEND_PRESENT not set — skipping cross-repo tests"
  fi

# Build the C# UI tests
build-csharp-ui:
  #!/usr/bin/env bash
  set -e
  cd ui-tests
  ./dotnet_build.sh

# Run C# UI tests
#
# display: controls how the graphical display is handled
#   "default"  - use the current display, showing the Electron window
#   "xvfb"     - use xvfb-run for a headless X11 server (used in CI)
#   "xephyr"   - use Xephyr to show the virtual X11 server window
#   "headless" - run with headless Electron (no X11 server needed)
#
# Additional arguments are forwarded to `dotnet run`, e.g.:
#   just test-csharp-ui xvfb --suite stable-tests --mode Electron
test-csharp-ui display="default" *args:
  #!/usr/bin/env bash
  set -e
  cd ui-tests
  ./dotnet_build.sh
  case "{{display}}" in
    xvfb)
      xvfb-run --auto-servernum --server-args="-screen 0 1920x1080x24" \
        dotnet run -- {{args}}
      ;;
    xephyr)
      DISPLAY_NUM=99
      while [ -e "/tmp/.X${DISPLAY_NUM}-lock" ]; do
        DISPLAY_NUM=$((DISPLAY_NUM + 1))
      done
      Xephyr ":${DISPLAY_NUM}" -screen 1920x1080 &
      XEPHYR_PID=$!
      trap "kill $XEPHYR_PID 2>/dev/null || true" EXIT
      sleep 1
      DISPLAY=":${DISPLAY_NUM}" dotnet run -- {{args}}
      ;;
    headless)
      UITESTS_ELECTRON_HEADLESS=true dotnet run -- {{args}}
      ;;
    default)
      dotnet run -- {{args}}
      ;;
    *)
      echo "Error: Unknown display mode '{{display}}'."
      echo "Valid modes: default, xvfb, xephyr, headless"
      exit 1
      ;;
  esac

# Run stable Electron UI tests with xvfb.
# Matches what CI runs. For local visible display, use: just test-csharp-ui default
# Run stable Electron UI tests with xvfb.
# Matches what CI runs. For local visible display, use: just test-csharp-ui default
ui-tests:
  #!/usr/bin/env bash
  set -e
  export CODETRACER_ELECTRON_ARGS="${CODETRACER_ELECTRON_ARGS:---no-sandbox --no-zygote --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage}"
  just test-csharp-ui xvfb --mode Electron --suite stable-tests --retries 2

# Run all language smoke tests (requires ct record + compilers on PATH).
# This records fresh traces for each language, so it needs ct-rr-support and
# the full compiler toolchain available in the nix shell.
test-all-language-smoke:
  #!/usr/bin/env bash
  set -e
  export CODETRACER_ELECTRON_ARGS="${CODETRACER_ELECTRON_ARGS:---no-sandbox --no-zygote --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage}"
  just test-csharp-ui xvfb --mode Electron --suite all-language-smoke --retries 2

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
    env CODETRACER_VALID_TEST_TRACE_DIR={{trace_dir}} cargo test test_valid_trace
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
  cd ${CODETRACER_REPO_ROOT_PATH}/tsc-ui-tests && \
    env CODETRACER_DEV_TOOLS=0 npx playwright test --reporter=list --workers=1 \
      {{args}}

dev-tools-test-e2e *args:
  cd ${CODETRACER_REPO_ROOT_PATH}/tsc-ui-tests && \
    env CODETRACER_DEV_TOOLS=1 npx playwright test --reporter=list --workers=1 \
      {{args}}

# ====
# Python recorder tests

test-python-recorder:
  ./ci/test/python-recorder-smoke.sh

# ====
# Nim flow/omniscience integration tests
# Tests the db-backend's ability to resolve Nim global variables using mangled names
#
# Uses scripts/with-nim-* wrappers which can be chained with other language wrappers:
#   scripts/with-nim-1.6 scripts/with-rust-1.80 cargo test ...

# Test with Nim 1.6.x (uses ROT13 mangling)
test-nim-flow-1_6:
  #!/usr/bin/env bash
  set -e
  echo "Testing Nim flow integration with Nim 1.6..."
  ./scripts/with-nim-1.6 nim --version
  cd src/db-backend
  ../../scripts/with-nim-1.6 cargo test test_nim_flow -- --nocapture
  echo "Nim 1.6 flow test passed!"

# Test with Nim 2.0.x (uses direct mangling, no ROT13)
test-nim-flow-2_0:
  #!/usr/bin/env bash
  set -e
  echo "Testing Nim flow integration with Nim 2.0..."
  ./scripts/with-nim-2.0 nim --version
  cd src/db-backend
  ../../scripts/with-nim-2.0 cargo test test_nim_flow -- --nocapture
  echo "Nim 2.0 flow test passed!"

# Test with Nim 2.2.x (uses direct mangling, no ROT13)
test-nim-flow-2_2:
  #!/usr/bin/env bash
  set -e
  echo "Testing Nim flow integration with Nim 2.2..."
  ./scripts/with-nim-2.2 nim --version
  cd src/db-backend
  ../../scripts/with-nim-2.2 cargo test test_nim_flow -- --nocapture
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
  cargo test test_rust_flow -- --nocapture
  echo "Rust flow test passed!"

# Test with Rust stable (via nix)
test-rust-flow-stable:
  #!/usr/bin/env bash
  set -e
  echo "Testing Rust flow integration with Rust stable..."
  ./scripts/with-rust-stable rustc --version
  cd src/db-backend
  ../../scripts/with-rust-stable cargo test test_rust_flow -- --nocapture
  echo "Rust stable flow test passed!"

# Test with Rust nightly (via nix)
test-rust-flow-nightly:
  #!/usr/bin/env bash
  set -e
  echo "Testing Rust flow integration with Rust nightly..."
  ./scripts/with-rust-nightly rustc --version
  cd src/db-backend
  ../../scripts/with-rust-nightly cargo test test_rust_flow -- --nocapture
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
  cd src/db-backend && cargo test test_python_flow -- --nocapture
  echo "Python flow test passed!"

# Ruby flow/omniscience integration test (DB-based, no rr required)
test-ruby-flow:
  #!/usr/bin/env bash
  set -e
  echo "Running Ruby flow integration test..."
  cd src/db-backend && cargo test test_ruby_flow -- --nocapture
  echo "Ruby flow test passed!"

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

# ====
# Per-language smoke test targets
# Run individual language UI smoke tests via Electron + xvfb

test-cpp-smoke:
  just test-csharp-ui xvfb --mode Electron --suite cpp-smoke

test-pascal-smoke:
  just test-csharp-ui xvfb --mode Electron --suite pascal-smoke

test-fortran-smoke:
  just test-csharp-ui xvfb --mode Electron --suite fortran-smoke

test-d-smoke:
  just test-csharp-ui xvfb --mode Electron --suite d-smoke

test-crystal-smoke:
  just test-csharp-ui xvfb --mode Electron --suite crystal-smoke

test-lean-smoke:
  just test-csharp-ui xvfb --mode Electron --suite lean-smoke

test-ada-smoke:
  just test-csharp-ui xvfb --mode Electron --suite ada-smoke

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
