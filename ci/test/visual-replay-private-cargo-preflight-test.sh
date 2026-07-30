#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

SENTINEL="ct-private-cargo-preflight-test-$$"
SENTINEL_BASIC="$(printf 'x-access-token:%s' "$SENTINEL" | base64 | tr -d '\r\n')"
LLDB_SYS_URL="https://github.com/metacraft-labs/lldb-sys.rs.git"

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/workspace"
cat >"$TEST_ROOT/bin/cargo" <<'FAKE_CARGO'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"${CARGO_CALL_LOG:?}"
FAKE_CARGO
chmod +x "$TEST_ROOT/bin/cargo"

write_valid_workspace() {
	local workspace="$1"
	mkdir -p "$workspace"
	cat >"$workspace/Cargo.toml" <<'CARGO_TOML'
[package]
name = "private-cargo-preflight-fixture"
version = "0.1.0"
edition = "2021"

[patch.crates-io]
lldb-sys = { git = "https://github.com/metacraft-labs/lldb-sys.rs.git" }
CARGO_TOML
	cat >"$workspace/Cargo.lock" <<'CARGO_LOCK'
version = 4

[[package]]
name = "lldb-sys"
version = "0.0.31"
source = "git+https://github.com/metacraft-labs/lldb-sys.rs.git#0123456789abcdef0123456789abcdef01234567"
CARGO_LOCK
}

prepare_two_slot_environment() {
	local cargo_home="$1"
	mkdir -p "$cargo_home"
	unset GIT_CONFIG_PARAMETERS GIT_CONFIG_NOSYSTEM GIT_ALLOW_PROTOCOL
	unset GIT_CONFIG_KEY_00 GIT_CONFIG_VALUE_00
	unset GIT_CONFIG_KEY_2 GIT_CONFIG_VALUE_2
	unset GIT_CONFIG_KEY_3 GIT_CONFIG_VALUE_3
	unset GIT_CONFIG_KEY_4 GIT_CONFIG_VALUE_4
	unset GIT_CONFIG_KEY_5 GIT_CONFIG_VALUE_5
	unset GIT_CONFIG_KEY_17 GIT_CONFIG_VALUE_17
	unset GIT_CONFIG_KEY_999999999999999999999999999999
	unset GIT_CONFIG_VALUE_999999999999999999999999999999
	export GITHUB_ACTIONS=true
	export CARGO_NET_GIT_FETCH_WITH_CLI=true
	export CARGO_HOME="$cargo_home"
	export CODETRACER_VISUAL_REPLAY_CLEAN_CARGO_HOME=true
	export GIT_TERMINAL_PROMPT=0
	export GIT_ASKPASS=/bin/false
	export SSH_ASKPASS=/bin/false
	export GIT_CONFIG_GLOBAL=/dev/null
	export GIT_CONFIG_SYSTEM=/dev/null
	export GIT_CONFIG_COUNT=2
	export GIT_CONFIG_KEY_0="http.${LLDB_SYS_URL}.extraHeader"
	export GIT_CONFIG_VALUE_0="AUTHORIZATION: basic ${SENTINEL_BASIC}"
	export GIT_CONFIG_KEY_1="credential.helper"
	export GIT_CONFIG_VALUE_1=""
	unset CODETRACER_VISUAL_REPLAY_GITHUB_TOKEN
}

run_positive_case() {
	local workspace="$TEST_ROOT/workspace/positive"
	local cargo_home="$TEST_ROOT/cargo-positive"
	local output
	write_valid_workspace "$workspace"
	prepare_two_slot_environment "$cargo_home"

	# These model process-scoped runner state that must not survive the Nix
	# boundary normalizer. In particular, a stale high numbered slot must
	# never become live if GIT_CONFIG_COUNT grows.
	export GIT_CONFIG_KEY_17="url.https://hostile.invalid/.insteadOf"
	export GIT_CONFIG_VALUE_17="https://github.com/"
	export GIT_CONFIG_KEY_00="protocol.ext.allow"
	export GIT_CONFIG_VALUE_00="always"
	export GIT_CONFIG_KEY_999999999999999999999999999999="protocol.file.allow"
	export GIT_CONFIG_VALUE_999999999999999999999999999999="always"
	export GIT_CONFIG_PARAMETERS="credential.helper=hostile-helper"
	export GIT_ALLOW_PROTOCOL="ext:file:https"

	# shellcheck disable=SC1091
	source "$REPO_ROOT/ci/test/visual-replay-private-cargo-env.sh" \
		>"$TEST_ROOT/positive-normalization.log"
	output="$(<"$TEST_ROOT/positive-normalization.log")"
	[[ $output == *"ambient-config-channel"* ]]
	[[ $output == *"extra-inline-config-slot"* ]]
	[[ -z ${GIT_CONFIG_KEY_17:-} && -z ${GIT_CONFIG_VALUE_17:-} ]]
	[[ -z ${GIT_CONFIG_KEY_00:-} && -z ${GIT_CONFIG_VALUE_00:-} ]]
	[[ -z ${GIT_CONFIG_KEY_999999999999999999999999999999:-} ]]
	[[ -z ${GIT_CONFIG_VALUE_999999999999999999999999999999:-} ]]
	[[ -z ${GIT_CONFIG_PARAMETERS:-} && -z ${GIT_ALLOW_PROTOCOL:-} ]]

	export CARGO_CALL_LOG="$TEST_ROOT/cargo-positive.args"
	PATH="$TEST_ROOT/bin:$PATH" \
		bash "$REPO_ROOT/ci/test/visual-replay-private-cargo-preflight.sh" \
		"$workspace"
	grep -Fxq "fetch --locked --manifest-path $workspace/Cargo.toml" \
		"$CARGO_CALL_LOG"
}

run_negative_case() {
	local case_name="$1"
	local expected_invariant="$2"
	local workspace="$TEST_ROOT/workspace/negative-$case_name"
	local cargo_home="$TEST_ROOT/cargo-negative-$case_name"
	local output status
	write_valid_workspace "$workspace"
	prepare_two_slot_environment "$cargo_home"
	# shellcheck disable=SC1091
	source "$REPO_ROOT/ci/test/visual-replay-private-cargo-env.sh" >/dev/null

	case "$case_name" in
	prompt) GIT_TERMINAL_PROMPT=1 ;;
	global-config) GIT_CONFIG_GLOBAL="$TEST_ROOT/hostile.gitconfig" ;;
	count) GIT_CONFIG_COUNT=5 ;;
	auth-key) GIT_CONFIG_KEY_0="http.https://github.com/.extraHeader" ;;
	header-shape) GIT_CONFIG_VALUE_0="AUTHORIZATION: basic bad value" ;;
	helper) GIT_CONFIG_VALUE_1="hostile-helper" ;;
	redirect) GIT_CONFIG_VALUE_2=true ;;
	protocol) GIT_CONFIG_VALUE_3=always ;;
	tls) GIT_CONFIG_VALUE_5=false ;;
	parameters) export GIT_CONFIG_PARAMETERS="credential.helper=hostile-helper" ;;
	extra-slot)
		export GIT_CONFIG_KEY_17="protocol.ext.allow"
		export GIT_CONFIG_VALUE_17="always"
		;;
	extra-padded)
		export GIT_CONFIG_KEY_00="protocol.ext.allow"
		export GIT_CONFIG_VALUE_00="always"
		;;
	extra-huge)
		export GIT_CONFIG_KEY_999999999999999999999999999999="protocol.file.allow"
		export GIT_CONFIG_VALUE_999999999999999999999999999999="always"
		;;
	raw-token) export CODETRACER_VISUAL_REPLAY_GITHUB_TOKEN="$SENTINEL" ;;
	lock-boundary)
		cat >>"$workspace/Cargo.lock" <<'SECOND_GIT_SOURCE'

[[package]]
name = "unexpected-git-source"
version = "1.0.0"
source = "git+https://example.invalid/unexpected.git#0123456789abcdef0123456789abcdef01234567"
SECOND_GIT_SOURCE
		;;
	*)
		echo "Unknown negative case: $case_name" >&2
		exit 1
		;;
	esac
	set +e
	output="$(
		CARGO_CALL_LOG="$TEST_ROOT/cargo-negative-$case_name.args" \
			PATH="$TEST_ROOT/bin:$PATH" \
			bash "$REPO_ROOT/ci/test/visual-replay-private-cargo-preflight.sh" \
			"$workspace" 2>&1
	)"
	status=$?
	set -e
	if ((status == 0)) || [[ $output != *"$expected_invariant"* ]]; then
		echo "Private Cargo preflight negative case failed: $case_name" >&2
		printf '%s\n' "$output" >&2
		exit 1
	fi
}

run_positive_case
run_negative_case prompt "interactive-credential-blocking"
run_negative_case global-config "config-file-isolation"
run_negative_case count "inline-config-count"
run_negative_case auth-key "auth-header-url-scope"
run_negative_case header-shape "auth-header-shape"
run_negative_case helper "credential-helper-blocking"
run_negative_case redirect "redirect-blocking"
run_negative_case protocol "transport-allowlist"
run_negative_case tls "tls-verification"
run_negative_case parameters "ambient-git-config-channel"
run_negative_case extra-slot "unexpected-inline-config-slot"
run_negative_case extra-padded "unexpected-inline-config-slot"
run_negative_case extra-huge "unexpected-inline-config-slot"
run_negative_case raw-token "Raw visual replay CI token"
run_negative_case lock-boundary "locked-git-source-boundary"

if grep -R -aFq -- "$SENTINEL" "$TEST_ROOT" ||
	grep -R -aFq -- "$SENTINEL_BASIC" "$TEST_ROOT"; then
	echo "Private Cargo preflight test persisted a sentinel credential." >&2
	exit 1
fi

echo "Visual replay private Cargo preflight tests passed."
