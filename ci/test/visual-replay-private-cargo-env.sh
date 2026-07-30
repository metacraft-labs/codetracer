#!/usr/bin/env bash

# This file is sourced by the visual replay gate after nix develop has
# finished running its git-hooks shell hook. It intentionally contains no
# credential material: the exact header key/value must survive shell entry and
# are validated separately by visual-replay-private-cargo-preflight.sh.
if [[ ${GITHUB_ACTIONS:-} == "true" ]]; then
	normalized_git_invariants=()
	[[ ${GIT_TERMINAL_PROMPT:-} == "0" ]] ||
		normalized_git_invariants+=("terminal-prompt")
	[[ ${GIT_ASKPASS:-} == "/bin/false" ]] ||
		normalized_git_invariants+=("git-askpass")
	[[ ${SSH_ASKPASS:-} == "/bin/false" ]] ||
		normalized_git_invariants+=("ssh-askpass")
	[[ ${GIT_CONFIG_GLOBAL:-} == "/dev/null" ]] ||
		normalized_git_invariants+=("global-config")
	[[ ${GIT_CONFIG_SYSTEM:-} == "/dev/null" ]] ||
		normalized_git_invariants+=("system-config")
	[[ ${GIT_CONFIG_COUNT:-} == "2" ]] ||
		normalized_git_invariants+=("inline-config-count")
	if [[ -n ${GIT_CONFIG_PARAMETERS:-} || -n ${GIT_CONFIG_NOSYSTEM:-} ||
		-n ${GIT_ALLOW_PROTOCOL:-} ]]; then
		normalized_git_invariants+=("ambient-config-channel")
	fi

	found_extra_inline_config=false
	for git_env_name in "${!GIT_CONFIG_KEY_@}" "${!GIT_CONFIG_VALUE_@}"; do
		if [[ $git_env_name =~ ^GIT_CONFIG_(KEY|VALUE)_[0-9]+$ ]]; then
			case "$git_env_name" in
			GIT_CONFIG_KEY_0 | GIT_CONFIG_VALUE_0 | \
				GIT_CONFIG_KEY_1 | GIT_CONFIG_VALUE_1) ;;
			*)
				unset "$git_env_name"
				if [[ $found_extra_inline_config == false ]]; then
					normalized_git_invariants+=("extra-inline-config-slot")
					found_extra_inline_config=true
				fi
				;;
			esac
		fi
	done
	unset GIT_CONFIG_PARAMETERS GIT_CONFIG_NOSYSTEM GIT_ALLOW_PROTOCOL

	export GIT_TERMINAL_PROMPT=0
	export GIT_ASKPASS=/bin/false
	export SSH_ASKPASS=/bin/false
	export GIT_CONFIG_GLOBAL=/dev/null
	export GIT_CONFIG_SYSTEM=/dev/null
	export GIT_CONFIG_COUNT=6
	export GIT_CONFIG_KEY_2="http.followRedirects"
	export GIT_CONFIG_VALUE_2="false"
	export GIT_CONFIG_KEY_3="protocol.allow"
	export GIT_CONFIG_VALUE_3="never"
	export GIT_CONFIG_KEY_4="protocol.https.allow"
	export GIT_CONFIG_VALUE_4="always"
	export GIT_CONFIG_KEY_5="http.sslVerify"
	export GIT_CONFIG_VALUE_5="true"

	if ((${#normalized_git_invariants[@]} > 0)); then
		printf 'Normalized visual replay Git invariants after Nix shell entry:'
		printf ' %s' "${normalized_git_invariants[@]}"
		printf '\n'
	fi
	unset found_extra_inline_config git_env_name normalized_git_invariants
fi
