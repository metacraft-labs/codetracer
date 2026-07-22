#!/usr/bin/env bash
set -euo pipefail

# setup-dev-env authenticates ordinary Git and Nix fetches, but Cargo's
# default libgit2 transport does not consume that URL-rewrite credential.
# The visual replay workflow therefore installs a process-only, exact-repo
# rewrite and selects Cargo's Git CLI transport before it enters the gate.
# Validate that contract before any build or test starts.
if [[ ${GITHUB_ACTIONS:-} != "true" ]]; then
	exit 0
fi

if [[ ${CARGO_NET_GIT_FETCH_WITH_CLI:-} != "true" ]]; then
	echo "Visual replay CI requires Cargo git-fetch-with-cli." >&2
	exit 1
fi

if [[ ${GIT_TERMINAL_PROMPT:-} != "0" || ${GIT_CONFIG_COUNT:-} != "1" ]]; then
	echo "Visual replay CI private Cargo authentication is incomplete." >&2
	exit 1
fi

cargo_auth_key="${GIT_CONFIG_KEY_0:-}"
cargo_auth_prefix="url.https://x-access-token:"
cargo_auth_suffix="@github.com/metacraft-labs/lldb-sys.rs.git.insteadOf"
if [[ $cargo_auth_key != "$cargo_auth_prefix"*"$cargo_auth_suffix" ||
	$cargo_auth_key == "$cargo_auth_prefix$cargo_auth_suffix" ||
	${GIT_CONFIG_VALUE_0:-} != "https://github.com/metacraft-labs/lldb-sys.rs.git" ]]; then
	echo "Visual replay CI Cargo authentication is not scoped to lldb-sys." >&2
	exit 1
fi

if [[ -n ${CODETRACER_VISUAL_REPLAY_GITHUB_TOKEN:-} ]]; then
	echo "Raw visual replay CI token must not enter the gate environment." >&2
	exit 1
fi

native_backend_repo="${1:-}"
if [[ ! -f $native_backend_repo/Cargo.lock || ! -f $native_backend_repo/Cargo.toml ]]; then
	echo "Visual replay CI cannot find the native-backend Cargo workspace." >&2
	exit 1
fi

# Exercise Cargo itself, not only the environment shape. This warms the same
# Cargo cache used by the later native-replay build and turns bad credentials,
# a missing private revision, or an accidental return to libgit2 into an early
# gate failure before the long CodeTracer build and GUI-test phases.
cargo_fetch_output=""
if ! cargo_fetch_output="$(
	cargo fetch --locked --manifest-path "$native_backend_repo/Cargo.toml" 2>&1
)"; then
	printf '%s\n' "$cargo_fetch_output" |
		sed -E 's#https://x-access-token:[^@[:space:]]*@github.com#https://x-access-token:[REDACTED]@github.com#g' >&2
	echo "Visual replay CI could not prefetch the native-backend Cargo graph." >&2
	exit 1
fi
unset cargo_fetch_output cargo_auth_key cargo_auth_prefix cargo_auth_suffix native_backend_repo
