#!/usr/bin/env bash
# Cross-Process Origin E2E — Fixture A regenerator skeleton.
#
# Per the M29 deferred-deliverables list, the full recorder-driven
# regeneration path (Vite plugin + browser recorder + per-language
# recorder + session.toml stamping) is honestly deferred until the
# recorder fixture infrastructure described in the E2E design doc
# §3.4 lands. This script documents the intended interface so the
# follow-on milestone has a fixed target to drive.
set -euo pipefail

echo "[regenerate] M29 Fixture A — Account Balance"
echo
echo "DEFERRED: this regenerator depends on the recorder fixture"
echo "infrastructure described in the Cross-Process Origin E2E Test"
echo "Design doc §3.4 (browser recorder + per-language recorder +"
echo "TestCache wrapper). It is shipped as a skeleton in M29 and is"
echo "expected to be fleshed out by the recorder-infrastructure"
echo "follow-on; see the M29 PROPERTIES status for the explicit"
echo "defer note."
exit 75 # EX_TEMPFAIL — script is honestly skipped, not failing
