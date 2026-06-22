#!/usr/bin/env bash
set -euo pipefail

# Clone and build codetracer-native-backend (formerly codetracer-rr-backend) for CI.
#
# Resolves the rr-backend ref from (in order):
#   1. $RR_BACKEND_REF env var (explicit manual override)
#   2. The repo-workspaces workspace lock, via scripts/resolve-sibling-rev.sh
#      (the single approved source of sibling revisions). In CI, the lock is
#      addressed by $CT_MANIFEST_DIR + $CT_LOCK_SHA; locally the resolver
#      auto-discovers .repo/manifests and walks from HEAD. A missing lock
#      fails loudly — there is no "main" fallback.
#
# Requires GH_TOKEN to be set for cloning the private repo.
# Exports CODETRACER_RR_BACKEND_PRESENT=1 and updated PATH/LD_LIBRARY_PATH
# to GITHUB_ENV / GITHUB_PATH for subsequent CI steps.

# Save the repo root (all paths relative to this)
REPO_ROOT="$(pwd)"
# Clone as a sibling directory so that path deps in rr-backend's Cargo.toml
# (../codetracer/libs/ct-dap-client) resolve correctly.
CLONE_DIR="${CLONE_DIR:-$(pwd)/../codetracer-native-backend}"

# Resolve a sibling repo's workspace-locked revision via the single approved
# resolver. In CI, $CT_MANIFEST_DIR + $CT_LOCK_SHA address the shallow manifest
# checkout; locally, both are unset and the resolver auto-discovers
# .repo/manifests and walks from HEAD.
resolve_sibling_rev() { # $1 = sibling repo name
	local args=(--repo codetracer --sibling "$1")
	[ -n "${CT_MANIFEST_DIR:-}" ] && args+=(--manifest-dir "$CT_MANIFEST_DIR")
	[ -n "${CT_LOCK_SHA:-}" ] && args+=(--sha "$CT_LOCK_SHA" --no-walk)
	"$REPO_ROOT/scripts/resolve-sibling-rev.sh" "${args[@]}"
}

resolve_ref() {
	# Explicit manual override (dispatch-style), if set.
	if [[ -n ${RR_BACKEND_REF:-} ]]; then
		echo "$RR_BACKEND_REF"
		return
	fi

	# Otherwise resolve from the workspace lock (fails loudly if unlocked).
	resolve_sibling_rev codetracer-native-backend
}

clone_rr_backend() {
	local ref="$1"
	echo "Cloning codetracer-native-backend at ref: $ref"

	if [[ -z ${GH_TOKEN:-} ]]; then
		echo "Error: GH_TOKEN must be set to clone the private native-backend repo" >&2
		exit 1
	fi

	# Clean up any previous clone (self-hosted runners reuse workspaces)
	rm -rf "$CLONE_DIR"

	# Rewrite all GitHub URL styles to authenticated HTTPS.
	git config --global --replace-all url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "git@github.com:" || true
	git config --global --replace-all url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "ssh://git@github.com/" || true
	git config --global --replace-all url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "https://github.com/" || true

	git clone \
		"https://x-access-token:${GH_TOKEN}@github.com/metacraft-labs/codetracer-native-backend.git" \
		"$CLONE_DIR"

	(
		cd "$CLONE_DIR"
		git checkout "$ref" || {
			echo "Warning: ref '$ref' not found, falling back to main" >&2
			git checkout main
		}

		# Initialize submodules and explicitly rewrite their URLs
		git submodule init
		for url in $(git config --get-regexp '^submodule\..*\.url$' | grep -E 'git@github\.com:|https://github\.com/' | cut -d' ' -f1); do
			old_url=$(git config --get "$url")
			new_url=$(echo "$old_url" |
				sed "s|git@github.com:|https://x-access-token:${GH_TOKEN}@github.com/|" |
				sed "s|https://github.com/|https://x-access-token:${GH_TOKEN}@github.com/|")
			echo "Rewriting submodule URL: $url"
			git config "$url" "$new_url"
		done
		git submodule update --recursive
	)
}

build_rr_support() {
	echo "Building ct-native-replay via nix build..."

	nix build \
		"${CLONE_DIR}?submodules=1#ct-native-replay" \
		--override-input rr-soft "path:${CLONE_DIR}/libs/rr" \
		--override-input delve-patched "path:${CLONE_DIR}/libs/delve" \
		--out-link "${CLONE_DIR}/result" \
		--print-build-logs ||
		{
			echo "nix build failed, falling back to cargo build via nix develop..." >&2
			nix develop "${CLONE_DIR}" --command \
				bash -c "cd '${CLONE_DIR}' && cargo build"
		}

	# Verify the binary exists
	local binary=""
	if [[ -x "${CLONE_DIR}/result/bin/ct-native-replay" ]]; then
		binary="${CLONE_DIR}/result/bin/ct-native-replay"
	elif [[ -x "${CLONE_DIR}/target/debug/ct-native-replay" ]]; then
		binary="${CLONE_DIR}/target/debug/ct-native-replay"
	elif [[ -x "${CLONE_DIR}/result/bin/ct-rr-support" ]]; then
		binary="${CLONE_DIR}/result/bin/ct-rr-support" # legacy fallback
	elif [[ -x "${CLONE_DIR}/target/debug/ct-rr-support" ]]; then
		binary="${CLONE_DIR}/target/debug/ct-rr-support" # legacy fallback
	fi

	if [[ -z $binary ]]; then
		echo "Error: ct-native-replay binary not found after build" >&2
		exit 1
	fi

	echo "ct-native-replay binary: $binary"
}

resolve_runtime_deps() {
	echo "Resolving rr-backend runtime dependencies..."

	# Use markers to extract paths cleanly (nix develop may print banners)
	local raw
	# shellcheck disable=SC2016
	raw="$(nix develop "${CLONE_DIR}" --command bash -c \
		'echo "___LD_PATH_START___"; echo "$LD_LIBRARY_PATH"; echo "___LD_PATH_END___";
         echo "___PATH_START___"; echo "$PATH"; echo "___PATH_END___"')"

	RR_LD="$(echo "$raw" | sed -n '/___LD_PATH_START___/{n;p;}')"
	RR_PATH="$(echo "$raw" | sed -n '/___PATH_START___/{n;p;}')"

	echo "Resolved LD_LIBRARY_PATH (first 200 chars): ${RR_LD:0:200}..."
	echo "Resolved PATH (first 200 chars): ${RR_PATH:0:200}..."

	# Create symlinks for rr, dlv, gdb that the codetracer nix shell expects
	# at $PRJ_ROOT/target/debug/ (normally created by rr-backend shellHook)
	local target_debug="${REPO_ROOT}/target/debug"
	mkdir -p "$target_debug"

	for tool in rr dlv gdb; do
		local tool_path
		tool_path=$(PATH="$RR_PATH" command -v "$tool" 2>/dev/null) || true
		if [[ -n $tool_path ]]; then
			ln -sf "$tool_path" "$target_debug/$tool"
			echo "Linked $tool -> $tool_path"
		else
			echo "Warning: $tool not found in rr-backend environment" >&2
		fi
	done
}

export_to_github_env() {
	local ct_rr_support=""
	if [[ -x "${CLONE_DIR}/result/bin/ct-native-replay" ]]; then
		ct_rr_support="$(cd "${CLONE_DIR}/result/bin" && pwd)/ct-native-replay"
	elif [[ -x "${CLONE_DIR}/target/debug/ct-native-replay" ]]; then
		ct_rr_support="$(cd "${CLONE_DIR}/target/debug" && pwd)/ct-native-replay"
	elif [[ -x "${CLONE_DIR}/result/bin/ct-rr-support" ]]; then
		ct_rr_support="$(cd "${CLONE_DIR}/result/bin" && pwd)/ct-rr-support" # legacy
	elif [[ -x "${CLONE_DIR}/target/debug/ct-rr-support" ]]; then
		ct_rr_support="$(cd "${CLONE_DIR}/target/debug" && pwd)/ct-rr-support" # legacy
	fi

	if [[ -n ${GITHUB_ENV:-} ]]; then
		echo "CODETRACER_RR_BACKEND_PATH=${CLONE_DIR}" >>"$GITHUB_ENV"
		echo "CODETRACER_RR_BACKEND_PRESENT=1" >>"$GITHUB_ENV"
		if [[ -n ${RR_LD:-} ]]; then
			echo "LD_LIBRARY_PATH=${RR_LD}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" >>"$GITHUB_ENV"
		fi
	fi

	if [[ -n ${GITHUB_PATH:-} ]]; then
		local bin_dir
		bin_dir=$(dirname "$ct_rr_support")
		echo "$bin_dir" >>"$GITHUB_PATH"
		# Also add the target/debug dir for rr, dlv, gdb symlinks
		echo "${REPO_ROOT}/target/debug" >>"$GITHUB_PATH"
	fi

	echo ""
	echo "=== rr-backend setup complete ==="
	echo "  ct-native-replay: $ct_rr_support"
	echo "  CODETRACER_RR_BACKEND_PRESENT=1"
}

main() {
	local ref
	ref=$(resolve_ref)
	echo "Using rr-backend ref: $ref"

	clone_rr_backend "$ref"
	build_rr_support
	resolve_runtime_deps
	export_to_github_env
}

main "$@"
