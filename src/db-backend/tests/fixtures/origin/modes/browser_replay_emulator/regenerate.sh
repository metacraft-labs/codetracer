#!/usr/bin/env bash
#
# Regenerate the modes/browser_replay_emulator benchmark fixture.
#
# The emulator-mode benchmark replays an existing MCR fixture inside
# the WASM emulator stack — see MODES.md for the workload-selection
# discussion. This script is a placeholder until M22/M23 ship the
# referenced fixture catalogue; until then it SKIPs cleanly so the
# top-level benchmark orchestrator can fan over every modes/* entry
# without failing the run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

echo "SKIPPED: modes/browser_replay_emulator awaits M22/M23 browser-replay fixture catalogue" >&2
exit 2
