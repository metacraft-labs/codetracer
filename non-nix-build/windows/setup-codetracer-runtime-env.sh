#!/usr/bin/env bash

if [[ -z ${ROOT_DIR:-} ]]; then
	WINDOWS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	NON_NIX_BUILD_DIR=$(cd "$WINDOWS_DIR/.." && pwd)
	ROOT_DIR=$(cd "$NON_NIX_BUILD_DIR/.." && pwd)
fi

# ---------------------------------------------------------------------------
# Add managed tool directories and shims to PATH for bash/SSH sessions.
# env.ps1 creates bash shims in $INSTALL_ROOT/shims but that directory is not
# on PATH by default in non-PowerShell shells.  We also add the native tool
# bin directories as a fallback in case shims haven't been (re-)generated yet.
# ---------------------------------------------------------------------------
INSTALL_ROOT="${WINDOWS_DIY_INSTALL_ROOT:-D:/metacraft-dev-deps}"
# Convert Windows drive-letter paths (D:/...) to MSYS2/Git-Bash form (/d/...)
# so that `which` and other POSIX tools resolve executables correctly.
if [[ "$INSTALL_ROOT" =~ ^([A-Za-z]):/(.*) ]]; then
	_drive="${BASH_REMATCH[1],,}"
	INSTALL_ROOT="/$_drive/${BASH_REMATCH[2]}"
	unset _drive
fi

# Source toolchain version pins so paths stay in sync with env.ps1.
_tc_file="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/toolchain-versions.env"
if [[ -f "$_tc_file" ]]; then
	# shellcheck disable=SC1090
	set -a; source "$_tc_file"; set +a
fi

# Shims directory (created by env.ps1) — first-class, highest priority.
SHIMS_DIR="$INSTALL_ROOT/shims"

# Build a list of tool bin directories that should be on PATH.
# Order matters: later entries are prepended first, so they appear earlier
# on PATH. GCC must come AFTER GNAT so GCC's gcc/gdb take priority over
# GNAT's (WinLibs GDB is newer and compatible with MCR's debugserver).
_tool_dirs=()

# GNAT provides gnatmake (added first = lower priority than GCC)
_gnat_ver="${GNAT_VERSION:-${GCC_VERSION:-}}"
[[ -n "$_gnat_ver" && -d "$INSTALL_ROOT/gnat/$_gnat_ver/bin" ]] && \
	_tool_dirs+=("$INSTALL_ROOT/gnat/$_gnat_ver/bin")

# Standalone GCC (higher priority — its gcc/g++/gdb should override GNAT's)
[[ -n "${GCC_VERSION:-}" && -d "$INSTALL_ROOT/gcc/$GCC_VERSION/bin" ]] && \
	_tool_dirs+=("$INSTALL_ROOT/gcc/$GCC_VERSION/bin")

# LDC (D compiler)
if [[ -n "${LDC_VERSION:-}" ]]; then
	for _ldc_cand in \
		"$INSTALL_ROOT/ldc/$LDC_VERSION/ldc2-$LDC_VERSION-windows-x64/bin" \
		"$INSTALL_ROOT/ldc/$LDC_VERSION/ldc2-$LDC_VERSION-windows-aarch64/bin"; do
		[[ -d "$_ldc_cand" ]] && { _tool_dirs+=("$_ldc_cand"); break; }
	done
fi

# Nim
if [[ -n "${NIM_VERSION:-}" ]]; then
	for _nim_cand in \
		"$INSTALL_ROOT/nim/$NIM_VERSION/prebuilt/nim-$NIM_VERSION/bin" \
		"$INSTALL_ROOT/nim/$NIM_VERSION/nim-$NIM_VERSION/bin"; do
		[[ -d "$_nim_cand" ]] && { _tool_dirs+=("$_nim_cand"); break; }
	done
fi

# Go
[[ -n "${GO_VERSION:-}" && -d "$INSTALL_ROOT/go/$GO_VERSION/go/bin" ]] && \
	_tool_dirs+=("$INSTALL_ROOT/go/$GO_VERSION/go/bin")

# V-lang
[[ -n "${VLANG_VERSION:-}" && -d "$INSTALL_ROOT/vlang/$VLANG_VERSION/v" ]] && \
	_tool_dirs+=("$INSTALL_ROOT/vlang/$VLANG_VERSION/v")

# Free Pascal
[[ -n "${FPC_VERSION:-}" && -d "$INSTALL_ROOT/fpc/$FPC_VERSION/bin/x86_64-win64" ]] && \
	_tool_dirs+=("$INSTALL_ROOT/fpc/$FPC_VERSION/bin/x86_64-win64")

# LLVM (provides clang, lldb, llvm-config)
if [[ -n "${LLVM_VERSION:-}" ]]; then
	for _llvm_cand in \
		"$INSTALL_ROOT/llvm/$LLVM_VERSION/LLVM-$LLVM_VERSION-x86_64-pc-windows-msvc/bin" \
		"$INSTALL_ROOT/llvm/$LLVM_VERSION/LLVM-$LLVM_VERSION-aarch64-pc-windows-msvc/bin"; do
		[[ -d "$_llvm_cand" ]] && { _tool_dirs+=("$_llvm_cand"); break; }
	done
fi

# Export LLVM_CONFIG and LLDB_LIB_PATH for lldb-sys crate build.rs
if [[ -n "${LLVM_VERSION:-}" ]]; then
	for _llvm_dir in \
		"$INSTALL_ROOT/llvm/$LLVM_VERSION/LLVM-$LLVM_VERSION-x86_64-pc-windows-msvc" \
		"$INSTALL_ROOT/llvm/$LLVM_VERSION/LLVM-$LLVM_VERSION-aarch64-pc-windows-msvc"; do
		if [[ -f "$_llvm_dir/bin/llvm-config.exe" ]]; then
			export LLVM_CONFIG="$_llvm_dir/bin/llvm-config.exe"
			export LLDB_LIB_PATH="$_llvm_dir/lib"
			break
		fi
	done
fi

# Prepend shims first, then tool dirs (shims take precedence).
for _d in "${_tool_dirs[@]}"; do
	case ":$PATH:" in
		*":$_d:"*) ;;
		*) export PATH="$_d:$PATH" ;;
	esac
done
if [[ -d "$SHIMS_DIR" ]]; then
	case ":$PATH:" in
		*":$SHIMS_DIR:"*) ;;
		*) export PATH="$SHIMS_DIR:$PATH" ;;
	esac
fi

unset _tc_file _gnat_ver _ldc_cand _nim_cand _tool_dirs _d SHIMS_DIR
# ---------------------------------------------------------------------------

export CODETRACER_REPO_ROOT_PATH="$ROOT_DIR"
export CODETRACER_PREFIX="${CODETRACER_PREFIX:-${CODETRACER_BUILD_DIR:-$ROOT_DIR/src/build-debug}}"
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
# `ct` runtime expects `<build-debug>/config/default_config.yaml` in non-Nix mode.
#
# On Windows with tup, CODETRACER_PREFIX points to the tup variant directory
# (src/build-debug) which must ONLY contain tup.config before `tup build-debug`
# runs. Skip creating config/public here if tup.config exists and the directory
# doesn't yet have the tup-generated output (no bin/ dir yet). After tup builds,
# these will be populated by the build system or can be set up separately.
_should_setup_prefix_dirs=1
if [[ -f "$CODETRACER_PREFIX/tup.config" && ! -d "$CODETRACER_PREFIX/bin" ]]; then
	_should_setup_prefix_dirs=0
fi

if [[ $_should_setup_prefix_dirs -eq 1 ]]; then
	# Ensure the folder exists by linking it to `src/public` when missing.
	if [[ ! -e "$CODETRACER_PREFIX/public" && -d "$ROOT_DIR/src/public" ]]; then
		mkdir -p "$CODETRACER_PREFIX"
		ln -s "$ROOT_DIR/src/public" "$CODETRACER_PREFIX/public" 2>/dev/null || cp -R "$ROOT_DIR/src/public" "$CODETRACER_PREFIX/public"
	fi

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
fi
unset _should_setup_prefix_dirs

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
