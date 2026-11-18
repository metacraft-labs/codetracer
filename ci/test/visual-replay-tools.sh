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

# ct-native-replay first, BEFORE the private-cargo Git policy below, and with
# codetracer-native-backend's submodules checked out. The sibling is cloned
# without them, so `nix develop '.?submodules=1'` tried to fetch libs/rr and
# libs/delve from the empty submodule paths over file://, which the policy
# (`protocol.allow=never`, https only) refused: "transport 'file' not allowed",
# TUI shard 6 of run 44081496736. With them checked out Nix reads them in
# place, and the policy has nothing to refuse. libs/rr is private, so they are
# cloned with the job's credentials, which the policy would drop. The private
# lldb-sys dependency is fetched with the git CLI and answered by the job's
# credential helper. ci/test/native-backend-submodules-test.sh holds the order.
native_replay="${backend}/target/debug/ct-native-replay"
if [ ! -x "${native_replay}" ]; then
	git -C "${backend}" submodule update --init --recursive
	(cd "${backend}" && CARGO_NET_GIT_FETCH_WITH_CLI=true nix develop '.?submodules=1' --command cargo build --bin ct-native-replay)
fi

# shellcheck source=ci/test/visual-replay-private-cargo-env.sh
source "${root}/ci/test/visual-replay-private-cargo-env.sh"

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
