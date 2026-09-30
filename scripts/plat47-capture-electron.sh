#!/usr/bin/env bash
# plat47-capture-electron.sh — PLAT-47: capture what the REAL Electron front-end
# shows on the terminal lanes' `calc` recording, for every property the
# terminal and GPUI front-ends must now equal: the first-run (Debug-mode)
# arrangement, the editor's colours as the eye sees them, the focused panel's
# outline, the Files pane's entries and the calltrace pane's calls.
#
# The prefix runs THIS checkout's desktop JavaScript
# (`scripts/plat45-desktop-prefix.sh`), so the first run it shows is the
# derivation this checkout ships. The spec
# (`src/tests/gui/tests/visual/plat47-desktop-parity-capture.spec.ts`) writes
# `src/tests/visual/answers/plat47-desktop-parity.electron.json`, which
# `src/frontend/tui/tests/real_terminal/test_plat47_desktop_parity.nim` and
# `src/frontend/gpui/tests/test_plat47_gpui_parity.nim` read. The second spec
# (`plat47-monaco-lexers-capture.spec.ts`) writes what the desktop's Monaco
# tokenizers make of one sample file per language
# (`plat47-monaco-lexers.electron.json`), which
# `src/frontend/tui/tests/test_plat47_monaco_lexers.nim` reads. The third
# (`plat47-vcs-capture.spec.ts`) opens the desktop on the repository
# `scripts/plat47-vcs-fixture.sh` builds and writes its VCS panel's rows
# (`plat47-vcs.electron.json`), which the terminal's and GPUI's VCS suites read.
# The fourth (`plat47-editor-languages-capture.spec.ts`) opens every lexer
# sample in the desktop's EDITOR and records the Monaco language it chose
# (`plat47-editor-languages.electron.json`), read by
# `src/frontend/tui/tests/test_plat47_monaco_lexers.nim`.
#
# Needs: a built frontend (`just build-once`), the `calc` recording under
# `test-logs/tui-fixtures/` (`just test-tui` records it) and Xvfb, which it
# starts when no display is set. Run through `just plat47-capture-electron`.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

# Inside the checkout, for the reason `plat45-capture-electron.sh` gives: the
# prefix's real `index.js` / `ui.js` resolve `node_modules` by walking up.
mkdir -p test-logs
work="$(mktemp -d "$repo/test-logs/plat47-capture.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# THE RECORDING the terminal's suites read, recorded by the terminal lanes'
# own fixture provider when this host has not recorded it yet (a CI job that
# runs no terminal lane first) — so both front-ends open one recording.
if ! ls -d test-logs/tui-fixtures/calc-* >/dev/null 2>&1; then
  cat >"$work/record_calc.nim" <<'NIM'
import fixtures/fixture_provider
let r = resolveFixture("calc")
if r.outcome != foRecorded:
  quit("PLAT-47: could not record the calc fixture: " & r.detail, 1)
echo r.tracePath
NIM
  nim c -r --hints:off --warnings:off --path:src/frontend/tui/tests \
    --nimcache:"$work/nc-record" -o:"$work/record_calc" "$work/record_calc.nim"
fi

bash scripts/plat45-desktop-prefix.sh "$work/prefix" src/config/default_layout.json
export PLAT47_DESKTOP_PREFIX="$work/prefix"
export CODETRACER_ELECTRON_ARGS="${CODETRACER_ELECTRON_ARGS:---no-sandbox --no-zygote --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage}"

run_spec() {
  just test-e2e tests/visual/plat47-desktop-parity-capture.spec.ts \
    tests/visual/plat47-monaco-lexers-capture.spec.ts \
    tests/visual/plat47-vcs-capture.spec.ts \
    tests/visual/plat47-editor-languages-capture.spec.ts "$@"
}

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|*_NT*|Darwin)
    run_spec "$@"
    ;;
  *)
    if [ -n "${DISPLAY:-}" ]; then
      run_spec "$@"
    else
      display_num=99
      while [ -e "/tmp/.X${display_num}-lock" ]; do
        display_num=$((display_num + 1))
      done
      Xvfb ":${display_num}" -screen 0 2560x1440x24 -dpi 96 -nolisten tcp &
      xvfb_pid=$!
      trap 'kill $xvfb_pid 2>/dev/null || true; rm -rf "$work"' EXIT
      sleep 1
      export DISPLAY=":${display_num}"
      run_spec "$@"
    fi
    ;;
esac
