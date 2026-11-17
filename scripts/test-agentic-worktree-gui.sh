#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
# The metacraft workspace keeps agent-harbor under ah/ (the directory that
# selects the agent-harbor identity); a flat sibling checkout still works.
ah_default="$repo_root/../ah/agent-harbor"
[ -d "$ah_default" ] || ah_default="$repo_root/../agent-harbor"
ah_root="${AGENT_HARBOR_REPO:-$ah_default}"
scenario="${AGENT_HARBOR_M7_SCENARIO:-$ah_root/tests/scenarios/e2e/codetracer_m7_worktree_feature.yaml}"
artifact_root="${CODETRACER_M7_ARTIFACT_ROOT:-$repo_root/test-results/agentic-worktree-runner}"
log_dir="$artifact_root/agent-harbor"
stdout_log="$log_dir/server.stdout"
stderr_log="$log_dir/server.stderr"
mock_agent_binary="$ah_root/target/debug/mock-agent"

mkdir -p "$log_dir"

if [ ! -d "$ah_root" ]; then
	echo "Error: Agent Harbor repo not found at $ah_root" >&2
	echo "Set AGENT_HARBOR_REPO to the checked-out agent-harbor repository." >&2
	exit 2
fi

if [ ! -f "$scenario" ]; then
	echo "Error: Agent Harbor M7 scenario not found at $scenario" >&2
	exit 2
fi

isonim_root="${ISONIM_REPO:-$repo_root/../isonim}"
if [ ! -d "$isonim_root" ]; then
	echo "Error: IsoNim repo not found at $isonim_root" >&2
	echo "Set ISONIM_REPO to the checked-out isonim repository." >&2
	exit 2
fi

if ! command -v cargo >/dev/null 2>&1; then
	echo "Error: cargo is required to launch the real Agent Harbor M7 REST harness." >&2
	exit 2
fi

if [ ! -f "$isonim_root/build/tailwind-styles.json" ]; then
	(
		cd "$isonim_root"
		if [ ! -d node_modules ]; then
			npm install --legacy-peer-deps --no-package-lock
		fi
		node tools/tailwind-extract.mjs
	)
fi

rm -f "$repo_root/src/build-debug/ui.js" \
	"$repo_root/src/build-debug/public/ui.js"
just build-once

: >"$stdout_log"
: >"$stderr_log"

# The server runs every session through `ah` (`branch create`, `agent record`),
# and a system `ah` from another release makes each command exit -1 with no
# output. Build the checkout's own `ah` beside the mock agent and hand it to the
# server through AH_BIN and PATH; an AH_BIN the caller set is kept. It also
# gets its own AH_HOME: that `ah` opens $AH_HOME's database, and the user's
# default one may be migrated past it by a newer `ah` ("migration ... was
# previously applied but is missing in the resolved migrations").
# shellcheck disable=SC2016
build_and_serve='set -e
cargo build -p mock-agent
cargo build -p ah-cli --bin ah
t="${CARGO_TARGET_DIR:-$PWD/target}/debug"
export AH_BIN="${AH_BIN:-$t/ah}" PATH="$t:$PATH" AH_HOME="${AH_HOME:-$(mktemp -d)}"
exec cargo run -p acp-client-runs-scenario --bin codetracer_m7_rest_server -- "$1" "$2"'

(
	cd "$ah_root"
	if [ "${AGENT_HARBOR_M7_SKIP_NIX:-}" != "1" ] && command -v nix >/dev/null 2>&1 && [ -f flake.nix ]; then
		nix develop --command bash -lc "$build_and_serve" bash "$scenario" "$log_dir"
	else
		bash -c "$build_and_serve" bash "$scenario" "$log_dir"
	fi
) >"$stdout_log" 2>"$stderr_log" &
server_pid=$!

cleanup() {
	if command -v pgrep >/dev/null 2>&1; then
		while read -r child_pid; do
			[ -n "$child_pid" ] || continue
			kill "$child_pid" >/dev/null 2>&1 || true
		done < <(pgrep -P "$server_pid" || true)
	fi

	if kill -0 "$server_pid" >/dev/null 2>&1; then
		kill -INT "$server_pid" >/dev/null 2>&1 || true
		for _ in $(seq 1 20); do
			if ! kill -0 "$server_pid" >/dev/null 2>&1; then
				return
			fi
			sleep 0.1
		done
		kill "$server_pid" >/dev/null 2>&1 || true
	fi
}
trap cleanup EXIT

base_url=""
for _ in $(seq 1 "${AGENT_HARBOR_M7_STARTUP_POLLS:-7200}"); do
	if ! kill -0 "$server_pid" >/dev/null 2>&1; then
		echo "Error: Agent Harbor M7 REST harness exited before publishing a base URL." >&2
		echo "stdout: $stdout_log" >&2
		echo "stderr: $stderr_log" >&2
		exit 1
	fi
	if grep -q '^AGENT_HARBOR_M7_BASE_URL=' "$stdout_log"; then
		base_url="$(grep '^AGENT_HARBOR_M7_BASE_URL=' "$stdout_log" | tail -n 1 | cut -d= -f2-)"
		break
	fi
	sleep 0.2
done

if [ -z "$base_url" ]; then
	echo "Error: Agent Harbor M7 REST harness did not publish AGENT_HARBOR_M7_BASE_URL." >&2
	echo "stdout: $stdout_log" >&2
	echo "stderr: $stderr_log" >&2
	exit 1
fi

export AGENT_HARBOR_M7_BASE_URL="$base_url"
export AGENT_HARBOR_M7_SCENARIO="$scenario"
export AGENT_HARBOR_M7_MOCK_AGENT_BINARY="$mock_agent_binary"
export AGENT_HARBOR_LOG_PATH="$stderr_log"
export CODETRACER_ELECTRON_ARGS="${CODETRACER_ELECTRON_ARGS:---no-sandbox --no-zygote --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage}"

case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN* | *_NT*)
	just test-e2e tests/agentic-coding/agentic-worktree.spec.ts
	;;
*)
	# Started through the shared helper, which waits for the display to
	# answer instead of sleeping (scripts/lib/own-xvfb.sh).
	. "$repo_root/scripts/lib/own-xvfb.sh"
	trap 'cleanup; own_xvfb_stop' EXIT
	own_xvfb_start -screen 0 1920x1080x24 -nolisten tcp || exit 1

	just test-e2e tests/agentic-coding/agentic-worktree.spec.ts
	;;
esac
