#!/usr/bin/env bash
set -euo pipefail

# setup-dev-env authenticates ordinary Git and Nix fetches, but Cargo's
# default libgit2 transport does not consume that credential. The visual replay
# workflow therefore selects Cargo's Git CLI transport and installs a
# process-only HTTP Authorization header scoped to the exact lldb-sys URL.
# Validate both the security contract and a real locked fetch before any build
# or test starts.
if [[ ${GITHUB_ACTIONS:-} != "true" ]]; then
	exit 0
fi

LLDB_SYS_URL="https://github.com/metacraft-labs/lldb-sys.rs.git"

redact_cargo_fetch_output() {
	sed -E \
		-e 's#(https://x-access-token:)[^@[:space:]]+(@github\.com)#\1[REDACTED]\2#g' \
		-e 's#([Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*[Bb][Aa][Ss][Ii][Cc][[:space:]]+)[A-Za-z0-9+/=]+#\1[REDACTED]#g'
}

fail_auth_contract() {
	local invariant="${1:-unknown}"
	echo "Visual replay CI private Cargo authentication invariant failed: ${invariant}." >&2
	exit 1
}

if [[ ${CARGO_NET_GIT_FETCH_WITH_CLI:-} != "true" ]]; then
	echo "Visual replay CI requires Cargo git-fetch-with-cli." >&2
	exit 1
fi

if [[ ${GIT_TERMINAL_PROMPT:-} != "0" || ${GIT_ASKPASS:-} != "/bin/false" ||
	${SSH_ASKPASS:-} != "/bin/false" ]]; then
	fail_auth_contract "interactive-credential-blocking"
fi
if [[ ${GIT_CONFIG_GLOBAL:-} != "/dev/null" ||
	${GIT_CONFIG_SYSTEM:-} != "/dev/null" ]]; then
	fail_auth_contract "config-file-isolation"
fi
if [[ -n ${GIT_CONFIG_PARAMETERS:-} || -n ${GIT_CONFIG_NOSYSTEM:-} ||
	-n ${GIT_ALLOW_PROTOCOL:-} ]]; then
	fail_auth_contract "ambient-git-config-channel"
fi
if [[ ${GIT_CONFIG_COUNT:-} != "6" ]]; then
	fail_auth_contract "inline-config-count"
fi

cargo_auth_key="${GIT_CONFIG_KEY_0:-}"
cargo_auth_header="${GIT_CONFIG_VALUE_0:-}"
cargo_auth_prefix="AUTHORIZATION: basic "
if [[ $cargo_auth_key != "http.${LLDB_SYS_URL}.extraHeader" ]]; then
	fail_auth_contract "auth-header-url-scope"
fi
if [[ $cargo_auth_header != "$cargo_auth_prefix"* ||
	$cargo_auth_header == "$cargo_auth_prefix" ||
	${cargo_auth_header#"$cargo_auth_prefix"} =~ [^A-Za-z0-9+/=] ]]; then
	fail_auth_contract "auth-header-shape"
fi
if [[ ${GIT_CONFIG_KEY_1:-} != "credential.helper" ||
	-n ${GIT_CONFIG_VALUE_1:-} ]]; then
	fail_auth_contract "credential-helper-blocking"
fi
if [[ ${GIT_CONFIG_KEY_2:-} != "http.followRedirects" ||
	${GIT_CONFIG_VALUE_2:-} != "false" ]]; then
	fail_auth_contract "redirect-blocking"
fi
if [[ ${GIT_CONFIG_KEY_3:-} != "protocol.allow" ||
	${GIT_CONFIG_VALUE_3:-} != "never" ||
	${GIT_CONFIG_KEY_4:-} != "protocol.https.allow" ||
	${GIT_CONFIG_VALUE_4:-} != "always" ]]; then
	fail_auth_contract "transport-allowlist"
fi
if [[ ${GIT_CONFIG_KEY_5:-} != "http.sslVerify" ||
	${GIT_CONFIG_VALUE_5:-} != "true" ]]; then
	fail_auth_contract "tls-verification"
fi

for git_env_name in "${!GIT_CONFIG_KEY_@}" "${!GIT_CONFIG_VALUE_@}"; do
	if [[ $git_env_name =~ ^GIT_CONFIG_(KEY|VALUE)_[0-9]+$ ]]; then
		case "$git_env_name" in
		GIT_CONFIG_KEY_0 | GIT_CONFIG_VALUE_0 | \
			GIT_CONFIG_KEY_1 | GIT_CONFIG_VALUE_1 | \
			GIT_CONFIG_KEY_2 | GIT_CONFIG_VALUE_2 | \
			GIT_CONFIG_KEY_3 | GIT_CONFIG_VALUE_3 | \
			GIT_CONFIG_KEY_4 | GIT_CONFIG_VALUE_4 | \
			GIT_CONFIG_KEY_5 | GIT_CONFIG_VALUE_5) ;;
		*) fail_auth_contract "unexpected-inline-config-slot" ;;
		esac
	fi
done
unset git_env_name

if [[ -n ${CODETRACER_VISUAL_REPLAY_GITHUB_TOKEN:-} ]]; then
	echo "Raw visual replay CI token must not enter the gate environment." >&2
	exit 1
fi

# Ask Git itself which URL receives the header. This catches subtle widening of
# the config key without printing the credential. The sibling and lookalike
# URLs must not inherit lldb-sys authentication.
if [[ $(git config --get-urlmatch http.extraHeader "$LLDB_SYS_URL") != "$cargo_auth_header" ]]; then
	fail_auth_contract "effective-auth-header"
fi
for unauthenticated_url in \
	"https://github.com/metacraft-labs/" \
	"https://github.com/metacraft-labs/codetracer.git" \
	"https://github.com/metacraft-labs/lldb-sys.rs.git-lookalike"; do
	if git config --get-urlmatch http.extraHeader "$unauthenticated_url" >/dev/null 2>&1; then
		fail_auth_contract "auth-header-url-boundary"
	fi
done
unset unauthenticated_url

# Git's URL matching intentionally applies a URL-specific header to request
# paths below that URL (for example /info/refs). Redirects are disabled above;
# this check documents and enforces the suffix needed by smart HTTP without
# pretending that the setting applies to one literal request URI only.
if [[ $(git config --get-urlmatch http.extraHeader \
	"${LLDB_SYS_URL}/info/refs") != "$cargo_auth_header" ]]; then
	fail_auth_contract "smart-http-path-scope"
fi

# Exercise the transport boundary with a fresh sentinel credential and a fake
# remote helper. GIT_TRACE records Git's child command, while the helper records
# its actual argv. Neither the raw nor encoded sentinel may be persisted. This
# directly guards against returning to a token-bearing URL rewrite.
(
	probe_dir="$(mktemp -d)"
	trap 'rm -rf "$probe_dir"' EXIT
	mkdir -p "$probe_dir/home" "$probe_dir/config"
	cat >"$probe_dir/home/.gitconfig" <<'HOSTILE_GLOBAL_CONFIG'
[url "https://global-rewrite-must-not-apply.invalid/"]
	insteadOf = https://github.com/
HOSTILE_GLOBAL_CONFIG

	probe_remote="$probe_dir/git-remote-https"
	cat >"$probe_remote" <<'PROBE_REMOTE'
#!/usr/bin/env bash
set -euo pipefail
: "${VISUAL_REPLAY_AUTH_PROBE_ARGV:?}"
printf '%s\0' "$0" "$@" >"$VISUAL_REPLAY_AUTH_PROBE_ARGV"
exit 97
PROBE_REMOTE
	chmod +x "$probe_remote"

	sentinel="ct-cargo-auth-$RANDOM-$RANDOM-$$"
	sentinel_basic="$(printf 'x-access-token:%s' "$sentinel" | base64 | tr -d '\r\n')"
	probe_header="AUTHORIZATION: basic ${sentinel_basic}"
	probe_trace="$probe_dir/git.trace"
	probe_stdout="$probe_dir/git.stdout"
	probe_argv="$probe_dir/git-remote-https.argv"

	set +e
	HOME="$probe_dir/home" \
		XDG_CONFIG_HOME="$probe_dir/config" \
		GIT_EXEC_PATH="$probe_dir" \
		GIT_TRACE=1 \
		GIT_TERMINAL_PROMPT=0 \
		GIT_ASKPASS=/bin/false \
		SSH_ASKPASS=/bin/false \
		GIT_CONFIG_GLOBAL=/dev/null \
		GIT_CONFIG_SYSTEM=/dev/null \
		GIT_CONFIG_COUNT=6 \
		GIT_CONFIG_KEY_0="http.${LLDB_SYS_URL}.extraHeader" \
		GIT_CONFIG_VALUE_0="$probe_header" \
		GIT_CONFIG_KEY_1="credential.helper" \
		GIT_CONFIG_VALUE_1="" \
		GIT_CONFIG_KEY_2="http.followRedirects" \
		GIT_CONFIG_VALUE_2="false" \
		GIT_CONFIG_KEY_3="protocol.allow" \
		GIT_CONFIG_VALUE_3="never" \
		GIT_CONFIG_KEY_4="protocol.https.allow" \
		GIT_CONFIG_VALUE_4="always" \
		GIT_CONFIG_KEY_5="http.sslVerify" \
		GIT_CONFIG_VALUE_5="true" \
		VISUAL_REPLAY_AUTH_PROBE_ARGV="$probe_argv" \
		git ls-remote "$LLDB_SYS_URL" HEAD >"$probe_stdout" 2>"$probe_trace"
	probe_status=$?
	set -e

	if ((probe_status == 0)) || [[ ! -s $probe_argv ]] ||
		! grep -aFq "$LLDB_SYS_URL" "$probe_argv" ||
		grep -aFq "global-rewrite-must-not-apply.invalid" "$probe_argv"; then
		fail_auth_contract "credential-free-remote-argv"
	fi
	if grep -R -aFq -- "$sentinel" "$probe_dir" ||
		grep -R -aFq -- "$sentinel_basic" "$probe_dir"; then
		fail_auth_contract "credential-artifact-leak"
	fi

	redacted_probe="$(
		printf 'fatal: AUTHORIZATION: basic %s\n' "$sentinel_basic" |
			redact_cargo_fetch_output
	)"
	if [[ $redacted_probe == *"$sentinel"* || $redacted_probe == *"$sentinel_basic"* ||
		$redacted_probe != *"[REDACTED]"* ]]; then
		fail_auth_contract "failure-output-redaction"
	fi
)

native_backend_repo="${1:-}"
if [[ ! -f $native_backend_repo/Cargo.lock || ! -f $native_backend_repo/Cargo.toml ]]; then
	echo "Visual replay CI cannot find the native-backend Cargo workspace." >&2
	exit 1
fi

locked_lldb_source="$(
	sed -n 's|^source = "git+\(https://github\.com/metacraft-labs/lldb-sys\.rs\.git#[0-9a-f]\{40\}\)"$|\1|p' \
		"$native_backend_repo/Cargo.lock"
)"
locked_git_source_count="$(grep -c '^source = "git+' "$native_backend_repo/Cargo.lock" || true)"
manifest_lldb_source_count="$(
	grep -Ec '^[[:space:]]*lldb-sys[[:space:]]*=[[:space:]]*\{[[:space:]]*git[[:space:]]*=[[:space:]]*"https://github\.com/metacraft-labs/lldb-sys\.rs\.git"[[:space:]]*\}[[:space:]]*$' \
		"$native_backend_repo/Cargo.toml" || true
)"
if [[ $locked_git_source_count != "1" || $manifest_lldb_source_count != "1" ||
	-z $locked_lldb_source || $locked_lldb_source == *$'\n'* ]]; then
	fail_auth_contract "locked-git-source-boundary"
fi
unset locked_git_source_count locked_lldb_source manifest_lldb_source_count

if [[ ${CODETRACER_VISUAL_REPLAY_CLEAN_CARGO_HOME:-} != "true" ||
	-z ${CARGO_HOME:-} || ! -d $CARGO_HOME ]]; then
	echo "Visual replay CI requires an isolated Cargo home." >&2
	exit 1
fi
if [[ -d $CARGO_HOME/git/db ]] &&
	find "$CARGO_HOME/git/db" -mindepth 1 -print -quit | grep -q .; then
	echo "Visual replay CI Cargo home already contains a Git dependency cache." >&2
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
		redact_cargo_fetch_output >&2
	echo "Visual replay CI could not prefetch the native-backend Cargo graph." >&2
	exit 1
fi
unset cargo_fetch_output cargo_auth_header cargo_auth_key cargo_auth_prefix native_backend_repo
unset LLDB_SYS_URL
