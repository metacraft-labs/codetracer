#!/usr/bin/env bash
# visual-replay-tools.sh <env-file> — provide what opening a visual recording
# needs, built from the sibling checkouts the way `visual-replay-gate.sh` builds
# them: `ct-native-replay` and a test licence, `ct_gfx_player`, and `ct-mcr`.
# Writes the variables that name them to <env-file>, for the caller to source. A
# missing sibling or a failed build fails by name; nothing is skipped.
set -euo pipefail

env_file="${1:?usage: visual-replay-tools.sh <env-file>}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WS="$(dirname "${root}")"
visual="${CODETRACER_VISUAL_REPLAY_REPO_PATH:-${WS}/codetracer-visual-replay}"
backend="${CODETRACER_NATIVE_BACKEND_REPO_PATH:-${WS}/codetracer-native-backend}"
recorder="${NATIVE_RECORDER_REPO:-${WS}/codetracer-native-recorder}"
for sibling in "${visual}" "${backend}" "${recorder}"; do
	[ -d "${sibling}" ] || {
		echo "visual-replay-tools: no sibling checkout at ${sibling}" >&2
		exit 1
	}
done

# shellcheck source=ci/test/visual-replay-private-cargo-env.sh
source "${root}/ci/test/visual-replay-private-cargo-env.sh"

native_replay="${backend}/target/debug/ct-native-replay"
[ -x "${native_replay}" ] ||
	(cd "${backend}" && nix develop '.?submodules=1' --command cargo build --bin ct-native-replay)

license_dir="$(dirname "${env_file}")/visual-replay-license"
mkdir -p "${license_dir}"
"${native_replay}" license generate-visual-replay-test-license \
	--license-file "${license_dir}/visual-replay-test.license.dat" \
	--env-file "${license_dir}/visual-replay-test.env"

(cd "${visual}" && CODETRACER_NATIVE_REPLAY="${native_replay}" nix develop --command bash -c \
	'nimble build && ./scripts/install-native-replay-companion.sh && just build-ct-mcr')

{
	cat "${license_dir}/visual-replay-test.env"
	echo "export CODETRACER_LICENSE_FILE CODETRACER_DEV_LICENSE_VERIFYING_KEY_BASE64"
	echo "export CODETRACER_CT_GFX_PLAYER_CMD='${visual}/ct_gfx_player'"
	echo "export CODETRACER_CT_NATIVE_REPLAY_CMD='${native_replay}'"
	echo "export CODETRACER_CT_MCR_CMD='${recorder}/ct_cli/ct_cli'"
	echo "export CODETRACER_CT_GFX_PLAYER_BACKEND=software"
	echo "export CODETRACER_NATIVE_REPLAY='${native_replay}'"
} >"${env_file}"
