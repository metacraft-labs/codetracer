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
if [[ $cargo_auth_header != "$cargo_auth_prefix"* ||
	$cargo_auth_header == "$cargo_auth_prefix" ||
	${cargo_auth_header#"$cargo_auth_prefix"} =~ [^A-Za-z0-9+/=] ]]; then
	fail_auth_contract "auth-header-shape"
fi
# The base64 credential itself, with the header field name and the auth scheme
# stripped off. Everything downstream that asks "is this the lldb-sys secret?"
# must ask it of THIS, never of the assembled header string: RFC 9110 §5.1
# makes field names case-insensitive, RFC 7617 §2 makes the `basic` scheme
# token case-insensitive, and RFC 9110 §5.5 lets optional whitespace surround
# the field value. `authorization: basic <token>`,
# `AUTHORIZATION: Basic <token>` and `AUTHORIZATION:  basic  <token>` are all
# wire-equivalent to the line below and all leak exactly the same secret, so a
# byte-equality test against the assembled header would wave three of the four
# spellings straight through.
cargo_auth_credential="${cargo_auth_header#"$cargo_auth_prefix"}"
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
# The invariant is that *the lldb-sys credential* does not widen to any other
# URL. It is checked twice, because the two readings answer different
# questions and only both together say what is needed.
#
# Why this is no longer "no header matches at all". That is what it used to
# assert, and it was falsified by something entirely legitimate:
# `actions/checkout` defaults to `persist-credentials: true` and writes
#
#     [http "https://github.com/"]
#         extraheader = AUTHORIZATION: basic <the run's own GITHUB_TOKEN>
#
# into the checkout's `.git/config`. `git config --get-urlmatch` reads the
# repository config too, and `https://github.com/` is a prefix of every URL
# below, so all three matched and the gate failed `auth-header-url-boundary`
# while the property it exists to protect was intact — the lldb-sys URL still
# resolved to the lldb-sys header, and nothing else did.
#
# EVIDENCE, CORRECTED (2026-08-14). 57ef307d4 cited three runs here —
# 30726348404, 31180327493, 31385899773 — and said the gate failed this way on
# "every run". Only the first is real:
#
#   30726348404  2026-08-02  failed in `Run visual replay regression gate`,
#                            log: "Visual replay CI private Cargo
#                            authentication invariant failed:
#                            auth-header-url-boundary."   <- genuine
#   31180327493  2026-08-07  failed in `Setup dev env`    <- never reached here
#   31385899773  2026-08-10  failed in `Setup dev env`    <- never reached here
#
# The latter two are the workspace-lock outage (see the header of
# `.github/workflows/codetracer.yml`); they died before this script ran and
# cannot evidence anything about it. The same three run IDs appear in
# codetracer.yml for the *Windows* git/bash defect, where all three genuinely
# do show the failure — that citation is sound, and is the likely source this
# one was copied from.
#
# So the relaxation rests on ONE observed failure plus a mechanism that is
# verifiable from first principles (the persisted header prefix-matches every
# URL). That is not nothing, but it is not what was claimed, and a security
# check should not be loosened on a count of runs nobody re-read.
#
# RE-EXAMINE THIS. As of 2026-08-14 the gate's checkout sets
# `persist-credentials: false`, so the ambient header this relaxation exists to
# tolerate is no longer written by the one step known to write it. Reading (1)
# below may now be satisfiable in the real environment again, which would make
# the stronger "no header matches at all" form achievable. It has deliberately
# NOT been re-tightened in the same change: a persistent self-hosted GPU runner
# can carry ambient Git configuration from sources other than actions/checkout,
# and with the runner pool saturated that could not be observed here. Re-tighten
# only against a green run that proves it, not against this comment.
#
# Independently of the citation count: asserting "no header at all" was also
# always stronger than the contract and was never wholly in the gate's power to
# guarantee — ambient config belongs to the environment, not to this script.
git_isolated_dir="$(mktemp -d)"
if git -C "$git_isolated_dir" rev-parse --git-dir >/dev/null 2>&1; then
	# TMPDIR inside a work tree would silently reintroduce repository config
	# and make reading (1) below vacuous in the other direction. Covered by
	# the `probe-isolation` case in this script's test.
	rm -rf "$git_isolated_dir"
	fail_auth_contract "auth-boundary-probe-isolation"
fi
for unauthenticated_url in \
	"https://github.com/metacraft-labs/" \
	"https://github.com/metacraft-labs/codetracer.git" \
	"https://github.com/metacraft-labs/lldb-sys.rs.git-lookalike"; do
	# (1) Against only the configuration this gate installs — globals are
	#     /dev/null and the probe runs outside any work tree, so the inline
	#     GIT_CONFIG_* slots are the whole config stack — nothing may match.
	#     This is the original invariant, now measured against the config the
	#     gate actually controls. It asks Git's own URL matcher rather than
	#     comparing key strings, so it catches a widened `GIT_CONFIG_KEY_0`
	#     (say `https://github.com/metacraft-labs/`) even when the literal
	#     key check below has not run yet — which is why that check now sits
	#     *after* this loop rather than before it. Ordered the other way the
	#     literal check subsumed this one entirely and nothing could ever
	#     reach here. Covered by the `auth-key-wide` case in the test.
	if git -C "$git_isolated_dir" config --get-urlmatch http.extraHeader \
		"$unauthenticated_url" >/dev/null 2>&1; then
		rm -rf "$git_isolated_dir"
		fail_auth_contract "auth-header-url-boundary"
	fi
	# (2) In the real environment, where the checkout's own credential is
	#     present: whatever header applies to these URLs, it must not carry
	#     the lldb-sys credential. This is the leak that matters, and it
	#     stays detectable no matter what else is configured.
	#
	#     The test is on the credential, not on the header string. An earlier
	#     formulation compared the whole matched header with `==` against
	#     `AUTHORIZATION: basic <token>`, which let the very same token
	#     through as `authorization: basic <token>`, `AUTHORIZATION: Basic
	#     <token>`, `AUTHORIZATION: basic <token>  ` or `AUTHORIZATION:
	#     basic  <token>` — four wire-valid spellings of one leak. Any header
	#     that contains the secret is a leak regardless of how it is spelled,
	#     so containment of the credential is both the correct test and a
	#     strictly stronger one than equality of the header.
	effective_header="$(git config --get-urlmatch http.extraHeader \
		"$unauthenticated_url" 2>/dev/null || true)"
	if [[ $effective_header == *"$cargo_auth_credential"* ]]; then
		rm -rf "$git_isolated_dir"
		fail_auth_contract "auth-header-credential-leak"
	fi
done
unset unauthenticated_url effective_header
rm -rf "$git_isolated_dir"
unset git_isolated_dir

# The literal key. Git's matcher above answers "does this credential reach a
# URL it must not"; this answers the narrower syntactic question "is the key
# spelled exactly as this gate installs it". They are not redundant: Git
# normalises URLs before matching, so `http.https://github.com:443/...` is
# semantically identical to the correct key and passes every probe above while
# still being a key nothing in this repository writes. A rewritten key is worth
# failing on even when it happens to be harmless today.
if [[ $cargo_auth_key != "http.${LLDB_SYS_URL}.extraHeader" ]]; then
	fail_auth_contract "auth-header-url-scope"
fi

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
unset cargo_fetch_output cargo_auth_header cargo_auth_credential cargo_auth_key
unset cargo_auth_prefix native_backend_repo
unset LLDB_SYS_URL
