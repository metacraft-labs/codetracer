#!/usr/bin/env bash
# tui-real-emulators.sh — the `tui-real-emulators` lane
# (CodeTracer-TUI-Terminal-Adaptation.md §13.4): this checkout's
# `build/bin/codetracer-tui` and `build/bin/capture-terminal-persona` in REAL
# terminal emulators, read back through GuiAssert (screenshots, OCR, pixels).
#
#   1. the emulators and display tools from this checkout's pinned nixpkgs
#      (`real-emulators-tools.sh`; a package that cannot be provided becomes a
#      MISSING-PREREQ skip of the emulators that need it, never a failure);
#   2. `src/frontend/tui/tests/real_emulators/test_real_emulators.nim`,
#      compiled and run in GuiAssert's dev shell — the shell that declares the
#      headless sway, grim, the Wayland helpers, Xvfb and tesseract
#      (`GUI_ASSERT_DIR`, default ../GuiAssert), as the GPUI window captures
#      are.
#
# Results in build/real-emulators/out/<persona id>/ (persona.json,
# capabilities.json, card.png, card.txt) and build/real-emulators/out/
# measured.json — the measured rows of the spec's §3.2 table.
#
# CT_REAL_EMULATORS_ONLY=kitty,foot narrows the run; CT_REAL_EMULATORS_UPDATE_PERSONAS=1
# re-captures the committed personas (src/frontend/tui/app/tests/personas/).
# The `just test-tui-real-emulators` recipe builds the two binaries first.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WS="$(cd "${root}/.." && pwd)"
GUI_ASSERT="$(cd "${GUI_ASSERT_DIR:-${WS}/GuiAssert}" && pwd)"
lane="${CT_REAL_EMULATORS_DIR:-${root}/build/real-emulators}"
fail() {
	echo "FAIL: $*" >&2
	exit 1
}
[ -x "${root}/build/bin/codetracer-tui" ] ||
	fail "build/bin/codetracer-tui is missing: run 'just build-tui'"
[ -x "${root}/build/bin/capture-terminal-persona" ] ||
	fail "build/bin/capture-terminal-persona is missing: run 'just build-capture-terminal-persona'"
mkdir -p "${lane}"
bash "${root}/ci/test/real-emulators-tools.sh" "${lane}/tools"
log="${root}/test-logs/tui-real-emulators.log"
mkdir -p "$(dirname "${log}")"
(cd "${GUI_ASSERT}" &&
	CT_REAL_EMULATORS_DIR="${lane}" \
		CT_TUI_BIN="${root}/build/bin/codetracer-tui" \
		CT_CAPTURE_BIN="${root}/build/bin/capture-terminal-persona" \
		CT_PERSONAS_DIR="${root}/src/frontend/tui/app/tests/personas" \
		nix develop --command nim c -r --hints:off --warnings:off --path:src \
		--nimcache:"${root}/build/nimcache/test_real_emulators" \
		-o:"${root}/build/test_real_emulators" \
		"${root}/src/frontend/tui/tests/real_emulators/test_real_emulators.nim") 2>&1 |
	tee "${log}"
rc="${PIPESTATUS[0]}"
echo "tui-real-emulators: MISSING-PREREQ skips: $(grep -c 'MISSING-PREREQ SKIP:' "${log}" || true); measured rows in ${lane}/out/measured.json"
exit "${rc}"
