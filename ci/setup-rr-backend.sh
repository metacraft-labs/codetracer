#!/usr/bin/env bash
set -euo pipefail

# Clone and build codetracer-rr-backend for CI.
#
# Resolves the rr-backend ref from (in order):
#   1. $RR_BACKEND_REF env var (explicit override)
#   2. .github/sibling-pins.json (sibling-pins lock)
#   3. .github/rr-backend-pin.txt (legacy pin file)
#   4. "main" (fallback)
#
# Requires GH_TOKEN to be set for cloning the private repo.
# Exports CODETRACER_RR_BACKEND_PRESENT=1 and updated PATH/LD_LIBRARY_PATH
# to GITHUB_ENV / GITHUB_PATH for subsequent CI steps.

# Save the repo root (all paths relative to this)
REPO_ROOT="$(pwd)"
CLONE_DIR="${CLONE_DIR:-target/rr-backend-clone}"

resolve_ref() {
	# 1. Explicit override
	if [[ -n ${RR_BACKEND_REF:-} ]]; then
		echo "$RR_BACKEND_REF"
		return
	fi

	# 2. sibling-pins.json (parse with grep/sed — no python3 needed)
	if [[ -f .github/sibling-pins.json ]]; then
		local pin
		pin=$(grep '"codetracer-rr-backend"' .github/sibling-pins.json |
			sed 's/.*: *"\([^"]*\)".*/\1/' |
			tr -d '[:space:]') || true
		if [[ -n $pin ]]; then
			echo "$pin"
			return
		fi
	fi

	# 3. Legacy pin file
	if [[ -f .github/rr-backend-pin.txt ]]; then
		local ref
		ref=$(head -1 .github/rr-backend-pin.txt | tr -d '[:space:]')
		if [[ -n $ref ]]; then
			echo "$ref"
			return
		fi
	fi

	# 4. Fallback
	echo "main"
}

clone_rr_backend() {
	local ref="$1"
	echo "Cloning codetracer-rr-backend at ref: $ref"

	if [[ -z ${GH_TOKEN:-} ]]; then
		echo "Error: GH_TOKEN must be set to clone the private rr-backend repo" >&2
		exit 1
	fi

	# Rewrite all GitHub URL styles to authenticated HTTPS.
	git config --global url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "git@github.com:"
	git config --global url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "ssh://git@github.com/"
	git config --global url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "https://github.com/"

	git clone \
		"https://x-access-token:${GH_TOKEN}@github.com/metacraft-labs/codetracer-rr-backend.git" \
		"$CLONE_DIR"

	(
		cd "$CLONE_DIR"
		git checkout "$ref"

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

		# Rewrite .gitmodules SSH URLs to HTTPS so nix's internal git fetcher
		# can resolve submodules when evaluating the flake with submodules=1
		sed -i 's|git@github.com:|https://github.com/|g' .gitmodules
		sed -i 's|ssh://git@github.com/|https://github.com/|g' .gitmodules
		# Stage and commit the rewrite so nix sees it in the git tree
		git add .gitmodules
		git -c user.name="CI" -c user.email="ci@local" commit --no-gpg-sign -m "CI: rewrite submodule URLs to HTTPS"
	)
}

build_rr_support() {
	echo "Building ct-rr-support via nix build..."

	nix build \
		"${CLONE_DIR}?submodules=1#codetracer-rr-support" \
		--override-input rr-soft "path:${CLONE_DIR}/libs/rr" \
		--override-input delve-patched "path:${CLONE_DIR}/libs/delve" \
		--out-link "${CLONE_DIR}/result" \
		--print-build-logs ||
		{
			echo "nix build failed, falling back to cargo build via nix develop..." >&2
			nix develop "./${CLONE_DIR}" --command \
				bash -c "cd '${CLONE_DIR}' && cargo build"
		}

	# Verify the binary exists
	local binary=""
	if [[ -x "${CLONE_DIR}/result/bin/ct-rr-support" ]]; then
		binary="${CLONE_DIR}/result/bin/ct-rr-support"
	elif [[ -x "${CLONE_DIR}/target/debug/ct-rr-support" ]]; then
		binary="${CLONE_DIR}/target/debug/ct-rr-support"
	fi

	if [[ -z $binary ]]; then
		echo "Error: ct-rr-support binary not found after build" >&2
		exit 1
	fi

	echo "ct-rr-support binary: $binary"
}

resolve_runtime_deps() {
	echo "Resolving rr-backend runtime dependencies..."

	# Use markers to extract paths cleanly (nix develop may print banners)
	local raw
	# shellcheck disable=SC2016
	raw="$(nix develop "./${CLONE_DIR}" --command bash -c \
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
	if [[ -x "${CLONE_DIR}/result/bin/ct-rr-support" ]]; then
		ct_rr_support="$(cd "${CLONE_DIR}/result/bin" && pwd)/ct-rr-support"
	elif [[ -x "${CLONE_DIR}/target/debug/ct-rr-support" ]]; then
		ct_rr_support="$(cd "${CLONE_DIR}/target/debug" && pwd)/ct-rr-support"
	fi

	if [[ -n ${GITHUB_ENV:-} ]]; then
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
	echo "  ct-rr-support: $ct_rr_support"
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
