#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

SENTINEL="ct-private-cargo-preflight-test-$$"
SENTINEL_BASIC="$(printf 'x-access-token:%s' "$SENTINEL" | base64 | tr -d '\r\n')"
LLDB_SYS_URL="https://github.com/metacraft-labs/lldb-sys.rs.git"

# `prepare_two_slot_environment` restores this. Cases that need the preflight's
# isolated boundary probe to land somewhere specific override TMPDIR, and the
# override must not leak into the next case.
ORIGINAL_TMPDIR="${TMPDIR:-}"

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
	if [[ -n $ORIGINAL_TMPDIR ]]; then
		export TMPDIR="$ORIGINAL_TMPDIR"
	else
		unset TMPDIR
	fi
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

	# Cases that must run from inside a particular checkout set
	# NEGATIVE_CASE_CWD; cases that build a repository carrying a credential
	# set NEGATIVE_CASE_CLEANUP so the end-of-run sentinel sweep keeps
	# meaning "nothing retained the credential" rather than "no test wrote
	# one". Both are reset here so one case cannot bleed into the next.
	NEGATIVE_CASE_CWD="$PWD"
	NEGATIVE_CASE_CLEANUP=""

	# These assignments mutate variables that
	# ``visual-replay-private-cargo-env.sh`` (sourced just above) has
	# already exported, so the child ``git`` sees them; shellcheck cannot
	# follow that across the source boundary and reads them as unused.
	# shellcheck disable=SC2034
	case "$case_name" in
	prompt) GIT_TERMINAL_PROMPT=1 ;;
	global-config) GIT_CONFIG_GLOBAL="$TEST_ROOT/hostile.gitconfig" ;;
	count) GIT_CONFIG_COUNT=5 ;;
	auth-key)
		# Git normalises away the default port before matching, so this key
		# is semantically identical to the correct one: it grants the header
		# to the lldb-sys URL and to nothing else, and therefore passes the
		# `effective-auth-header` check and both boundary readings. Only the
		# literal key comparison can catch it. Using a *harmless* rewrite
		# here is deliberate — it pins that check as an independent contract
		# rather than as a shadow of the boundary probe.
		GIT_CONFIG_KEY_0="http.https://github.com:443/metacraft-labs/lldb-sys.rs.git.extraHeader"
		;;
	auth-key-wide)
		# A genuinely widened key: `https://github.com/metacraft-labs/` is a
		# prefix of the first probe URL, so Git hands the lldb-sys header to
		# a URL that is not lldb-sys. This is reading (1) of the boundary
		# check — the isolated probe over the gate's own inline config —
		# and it is the case that reddens if that reading is deleted.
		GIT_CONFIG_KEY_0="http.https://github.com/metacraft-labs/.extraHeader"
		;;
	probe-isolation)
		# The boundary probe's reading (1) is only meaningful while its
		# working directory is outside every work tree. `mktemp -d` honours
		# TMPDIR, so a runner whose temp directory sits inside a checkout
		# would silently give the probe that checkout's repository config
		# back and make the reading vacuous. Reproduce exactly that: a real
		# repository, carrying the real `actions/checkout` credential, with
		# TMPDIR pointing inside it.
		local isolation_repo="$TEST_ROOT/probe-isolation-checkout"
		make_checkout_like_repo "$isolation_repo" \
			"AUTHORIZATION: basic ${AMBIENT_BASIC}"
		mkdir -p "$isolation_repo/runner-temp"
		export TMPDIR="$isolation_repo/runner-temp"
		NEGATIVE_CASE_CLEANUP="$isolation_repo"
		;;
	leak-lowercase-field | leak-uppercase-scheme | leak-trailing-space | \
		leak-doubled-space)
		# One leaked credential, four wire-valid spellings. RFC 9110 §5.1
		# makes the field name case-insensitive, RFC 7617 §2 makes the
		# `basic` scheme token case-insensitive, and RFC 9110 §5.5 allows
		# optional whitespace around the field value — so every one of these
		# hands the *same* lldb-sys secret to `https://github.com/`, and a
		# `==` comparison against `AUTHORIZATION: basic <token>` waves three
		# of the four through. Git preserves the spelling verbatim
		# (values with edge whitespace are written quoted), so what
		# `--get-urlmatch` returns here is what the wire would carry.
		local leak_repo="$TEST_ROOT/leak-checkout-$case_name"
		local leaked_header
		case "$case_name" in
		leak-lowercase-field) leaked_header="authorization: basic ${SENTINEL_BASIC}" ;;
		leak-uppercase-scheme) leaked_header="AUTHORIZATION: Basic ${SENTINEL_BASIC}" ;;
		leak-trailing-space) leaked_header="AUTHORIZATION: basic ${SENTINEL_BASIC}   " ;;
		leak-doubled-space) leaked_header="AUTHORIZATION:  basic  ${SENTINEL_BASIC}" ;;
		esac
		make_checkout_like_repo "$leak_repo" "$leaked_header"
		NEGATIVE_CASE_CWD="$leak_repo"
		NEGATIVE_CASE_CLEANUP="$leak_repo"
		;;
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
		cd "$NEGATIVE_CASE_CWD" &&
			CARGO_CALL_LOG="$TEST_ROOT/cargo-negative-$case_name.args" \
				PATH="$TEST_ROOT/bin:$PATH" \
				bash "$REPO_ROOT/ci/test/visual-replay-private-cargo-preflight.sh" \
				"$workspace" 2>&1
	)"
	status=$?
	set -e
	if [[ -n $NEGATIVE_CASE_CLEANUP ]]; then
		rm -rf "$NEGATIVE_CASE_CLEANUP"
	fi
	if ((status == 0)) || [[ $output != *"$expected_invariant"* ]]; then
		echo "Private Cargo preflight negative case failed: $case_name" >&2
		printf '%s\n' "$output" >&2
		exit 1
	fi
	# No diagnostic may echo the credential it is complaining about.
	if [[ $output == *"$SENTINEL_BASIC"* || $output == *"$SENTINEL"* ]]; then
		echo "Private Cargo preflight echoed the credential while reporting" >&2
		echo "negative case: $case_name" >&2
		exit 1
	fi
}

# ---------------------------------------------------------------------------
# The ambient checkout credential.
#
# `actions/checkout` defaults to `persist-credentials: true` and writes
#
#     [http "https://github.com/"]
#         extraheader = AUTHORIZATION: basic <the run's own GITHUB_TOKEN>
#
# into the checkout's `.git/config`. `git config --get-urlmatch` consults the
# repository config, and `https://github.com/` is a prefix of every URL the
# boundary check probes, so the old "no header may match at all" formulation
# failed while the property it protects was intact. (One run is on record for
# this gate — 30726348404; see the corrected evidence note in
# `visual-replay-private-cargo-preflight.sh`, which retracts a wider claim.)
#
# The gate's own checkout now sets `persist-credentials: false`, so it should no
# longer produce this header itself. These cases are kept regardless: a
# persistent self-hosted runner can carry ambient Git configuration from other
# sources, and the preflight must stay correct when it does.
#
# Neither of these is a mock: each builds a real git repository and writes the
# real configuration actions/checkout writes, then runs the preflight as a
# subprocess with that repository as its working directory — exactly how CI
# invokes it.
# ---------------------------------------------------------------------------
AMBIENT_BASIC="$(printf 'x-access-token:%s' "ambient-checkout-token-$$" | base64 | tr -d '\r\n')"

make_checkout_like_repo() {
	# $1 = directory, $2 = the extraHeader value actions/checkout persisted.
	local dir="$1" header="$2"
	mkdir -p "$dir"
	git -C "$dir" init -q .
	git -C "$dir" config "http.https://github.com/.extraheader" "$header"
}

run_ambient_credential_positive_case() {
	# The reproduction: an unrelated, legitimate credential scoped to
	# https://github.com/ must not fail the gate.
	local workspace="$TEST_ROOT/workspace/ambient-ok"
	local repo="$TEST_ROOT/ambient-ok-checkout"
	write_valid_workspace "$workspace"
	prepare_two_slot_environment "$TEST_ROOT/cargo-ambient-ok"
	# shellcheck disable=SC1091
	source "$REPO_ROOT/ci/test/visual-replay-private-cargo-env.sh" >/dev/null
	make_checkout_like_repo "$repo" "AUTHORIZATION: basic ${AMBIENT_BASIC}"

	(
		cd "$repo" &&
			CARGO_CALL_LOG="$TEST_ROOT/cargo-ambient-ok.args" \
				PATH="$TEST_ROOT/bin:$PATH" \
				bash "$REPO_ROOT/ci/test/visual-replay-private-cargo-preflight.sh" \
				"$workspace"
	) || {
		echo "Private Cargo preflight rejected a checkout carrying its own" >&2
		echo "actions/checkout credential; that is not a leak of the lldb-sys" >&2
		echo "header and must not fail the gate." >&2
		exit 1
	}
}

run_ambient_credential_leak_case() {
	# The leak that matters: the lldb-sys header itself, applied to a broader
	# URL by the repository config, must be caught.
	local workspace="$TEST_ROOT/workspace/ambient-leak"
	local repo="$TEST_ROOT/ambient-leak-checkout"
	local output status
	write_valid_workspace "$workspace"
	prepare_two_slot_environment "$TEST_ROOT/cargo-ambient-leak"
	# shellcheck disable=SC1091
	source "$REPO_ROOT/ci/test/visual-replay-private-cargo-env.sh" >/dev/null
	make_checkout_like_repo "$repo" "$GIT_CONFIG_VALUE_0"

	set +e
	output="$(
		cd "$repo" &&
			CARGO_CALL_LOG="$TEST_ROOT/cargo-ambient-leak.args" \
				PATH="$TEST_ROOT/bin:$PATH" \
				bash "$REPO_ROOT/ci/test/visual-replay-private-cargo-preflight.sh" \
				"$workspace" 2>&1
	)"
	status=$?
	set -e
	if ((status == 0)) || [[ $output != *"auth-header-credential-leak"* ]]; then
		echo "Private Cargo preflight did not catch the lldb-sys credential" >&2
		echo "being applied to https://github.com/ by the repository config." >&2
		printf '%s\n' "$output" >&2
		exit 1
	fi
	# The failure must not print the credential it is complaining about.
	if [[ $output == *"$SENTINEL_BASIC"* || $output == *"$SENTINEL"* ]]; then
		echo "Private Cargo preflight echoed the credential in its diagnostic." >&2
		exit 1
	fi
	# This fixture had to write the sentinel header into a git config on
	# purpose — that IS the leak being reproduced. Remove it here so the
	# end-of-run sweep below keeps its meaning: "nothing the preflight
	# touched retained the credential", rather than "no test ever wrote it".
	rm -rf "$repo"
}

run_positive_case
run_ambient_credential_positive_case
run_ambient_credential_leak_case
run_negative_case prompt "interactive-credential-blocking"
run_negative_case global-config "config-file-isolation"
run_negative_case count "inline-config-count"
run_negative_case auth-key "auth-header-url-scope"
run_negative_case auth-key-wide "auth-header-url-boundary"
run_negative_case probe-isolation "auth-boundary-probe-isolation"
# The same leaked lldb-sys credential, spelled four wire-valid ways. Each of
# these passed the gate while the boundary check compared whole header strings
# with `==`.
run_negative_case leak-lowercase-field "auth-header-credential-leak"
run_negative_case leak-uppercase-scheme "auth-header-credential-leak"
run_negative_case leak-trailing-space "auth-header-credential-leak"
run_negative_case leak-doubled-space "auth-header-credential-leak"
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
