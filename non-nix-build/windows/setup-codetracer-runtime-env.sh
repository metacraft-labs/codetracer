#!/usr/bin/env bash

if [[ -z ${ROOT_DIR:-} ]]; then
	WINDOWS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	NON_NIX_BUILD_DIR=$(cd "$WINDOWS_DIR/.." && pwd)
	ROOT_DIR=$(cd "$NON_NIX_BUILD_DIR/.." && pwd)
fi

export CODETRACER_REPO_ROOT_PATH="$ROOT_DIR"
export CODETRACER_PREFIX="${CODETRACER_PREFIX:-$ROOT_DIR/src/build-debug}"
export CODETRACER_LD_LIBRARY_PATH="${CODETRACER_LD_LIBRARY_PATH:-}"
export CODETRACER_DEV_TOOLS="${CODETRACER_DEV_TOOLS:-0}"
export CODETRACER_LOG_LEVEL="${CODETRACER_LOG_LEVEL:-INFO}"
export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS="${PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS:-1}"

if [[ -z ${CODETRACER_CTAGS_EXE_PATH:-} ]]; then
	if command -v ctags >/dev/null 2>&1; then
		CODETRACER_CTAGS_EXE_PATH="$(command -v ctags)"
		export CODETRACER_CTAGS_EXE_PATH
	elif [[ -n ${LOCALAPPDATA:-} ]]; then
		local_app_data_path="$LOCALAPPDATA"
		if command -v cygpath >/dev/null 2>&1; then
			local_app_data_path=$(cygpath -u "$LOCALAPPDATA")
		fi
		for candidate in "$local_app_data_path"/Microsoft/WinGet/Packages/UniversalCtags.Ctags_*/ctags.exe; do
			if [[ -f $candidate ]]; then
				CODETRACER_CTAGS_EXE_PATH="$candidate"
				export CODETRACER_CTAGS_EXE_PATH
				break
			fi
		done
	fi
fi

# `ct host` serves static assets from `<build-debug>/public` in non-Nix mode.
# Ensure the folder exists by linking it to `src/public` when missing.
if [[ ! -e "$CODETRACER_PREFIX/public" && -d "$ROOT_DIR/src/public" ]]; then
	mkdir -p "$CODETRACER_PREFIX"
	ln -s "$ROOT_DIR/src/public" "$CODETRACER_PREFIX/public" 2>/dev/null || cp -R "$ROOT_DIR/src/public" "$CODETRACER_PREFIX/public"
fi

# `ct` runtime expects `<build-debug>/config/default_config.yaml` in non-Nix mode.
if [[ ! -e "$CODETRACER_PREFIX/config" && -d "$ROOT_DIR/src/config" ]]; then
	mkdir -p "$CODETRACER_PREFIX"
	ln -s "$ROOT_DIR/src/config" "$CODETRACER_PREFIX/config" 2>/dev/null || cp -R "$ROOT_DIR/src/config" "$CODETRACER_PREFIX/config"
fi

if [[ -d "$ROOT_DIR/src/config" ]]; then
	mkdir -p "$CODETRACER_PREFIX/config"
	for filename in default_config.yaml default_layout.json; do
		if [[ -f "$ROOT_DIR/src/config/$filename" && ! -f "$CODETRACER_PREFIX/config/$filename" ]]; then
			cp "$ROOT_DIR/src/config/$filename" "$CODETRACER_PREFIX/config/$filename"
		fi
	done
fi

if [[ -z ${CODETRACER_E2E_CT_PATH:-} ]]; then
	if [[ -f "$CODETRACER_PREFIX/bin/ct.exe" ]]; then
		export CODETRACER_E2E_CT_PATH="$CODETRACER_PREFIX/bin/ct.exe"
	elif [[ -f "$CODETRACER_PREFIX/bin/ct" ]]; then
		export CODETRACER_E2E_CT_PATH="$CODETRACER_PREFIX/bin/ct"
	fi
fi

if [[ -d "$ROOT_DIR/node_modules/.bin" ]]; then
	export PATH="$CODETRACER_PREFIX/bin:$ROOT_DIR/node_modules/.bin:$PATH"
else
	export PATH="$CODETRACER_PREFIX/bin:$PATH"
fi
