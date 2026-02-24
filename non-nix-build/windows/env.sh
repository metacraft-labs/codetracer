#!/usr/bin/env bash

WINDOWS_ENV_WAS_SOURCED=0
if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
	WINDOWS_ENV_WAS_SOURCED=1
	WINDOWS_ENV_PREVIOUS_SHELLOPTS=$(set +o)
	trap 'eval "$WINDOWS_ENV_PREVIOUS_SHELLOPTS"; unset WINDOWS_ENV_PREVIOUS_SHELLOPTS WINDOWS_ENV_WAS_SOURCED; trap - RETURN' RETURN
fi

set -uo pipefail
if [[ $WINDOWS_ENV_WAS_SOURCED -eq 0 ]]; then
	set -e
fi

WINDOWS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NON_NIX_BUILD_DIR=$(cd "$WINDOWS_DIR/.." && pwd)
ROOT_DIR=$(cd "$NON_NIX_BUILD_DIR/.." && pwd)

# shellcheck disable=SC1091
source "$WINDOWS_DIR/toolchain-versions.env"
WINDBG_REQUIRED_MIN_VERSION="${WINDBG_MIN_VERSION:-1.2601.12001.0}"
TTD_REQUIRED_MIN_VERSION="${TTD_MIN_VERSION:-1.11.584.0}"

if [[ -z ${WINDOWS_DIY_INSTALL_ROOT:-} ]]; then
	if [[ -n ${LOCALAPPDATA:-} ]]; then
		if command -v cygpath >/dev/null 2>&1; then
			windows_diy_local_app_data=$(cygpath -u "$LOCALAPPDATA")
		else
			windows_diy_local_app_data="$LOCALAPPDATA"
		fi
	else
		windows_diy_local_app_data="$HOME/AppData/Local"
	fi
	WINDOWS_DIY_INSTALL_ROOT="$windows_diy_local_app_data/codetracer/windows-diy"
fi
export WINDOWS_DIY_INSTALL_ROOT
#
# Nim bootstrap source selection:
# - auto (default): prefer source build; on x64 fallback to pinned prebuilt on failure, on non-x64 fail after source attempt
# - source: require source build
# - prebuilt: force pinned prebuilt ZIP (x64 only)
: "${NIM_WINDOWS_SOURCE_MODE:=auto}"
: "${NIM_WINDOWS_SOURCE_REPO:="$NIM_SOURCE_REPO"}"
: "${NIM_WINDOWS_SOURCE_REF:="$NIM_SOURCE_REF"}"
: "${NIM_WINDOWS_CSOURCES_REPO:="$NIM_CSOURCES_REPO"}"
: "${NIM_WINDOWS_CSOURCES_REF:="$NIM_CSOURCES_REF"}"
export NIM_WINDOWS_SOURCE_MODE
export NIM_WINDOWS_SOURCE_REPO
export NIM_WINDOWS_SOURCE_REF
export NIM_WINDOWS_CSOURCES_REPO
export NIM_WINDOWS_CSOURCES_REF
#
# Cap'n Proto bootstrap source selection:
# - auto (default): use pinned prebuilt on x64; use source build on non-x64
# - source: require source build
# - prebuilt: force pinned prebuilt ZIP (x64 only)
: "${CAPNP_WINDOWS_SOURCE_MODE:=auto}"
: "${CAPNP_WINDOWS_SOURCE_REPO:="$CAPNP_SOURCE_REPO"}"
: "${CAPNP_WINDOWS_SOURCE_REF:="$CAPNP_SOURCE_REF"}"
export CAPNP_WINDOWS_SOURCE_MODE
export CAPNP_WINDOWS_SOURCE_REPO
export CAPNP_WINDOWS_SOURCE_REF
#
# Tup bootstrap source selection:
# - prebuilt (default): use pinned official prebuilt Windows zip
# - auto: prefer pinned prebuilt zip, then fallback to source build if prebuilt bootstrap fails
# - source: require source build
# - prebuilt: require prebuilt install (uses pinned defaults unless explicit URL/SHA overrides are set)
: "${TUP_WINDOWS_SOURCE_MODE:=prebuilt}"
: "${TUP_WINDOWS_SOURCE_REPO:="$TUP_SOURCE_REPO"}"
: "${TUP_WINDOWS_SOURCE_REF:="$TUP_SOURCE_REF"}"
: "${TUP_WINDOWS_SOURCE_BUILD_COMMAND:="$TUP_SOURCE_BUILD_COMMAND"}"
: "${TUP_WINDOWS_PREBUILT_VERSION:="$TUP_PREBUILT_VERSION"}"
: "${TUP_WINDOWS_PREBUILT_URL:="$TUP_PREBUILT_URL"}"
: "${TUP_WINDOWS_PREBUILT_SHA256:="$TUP_PREBUILT_SHA256"}"
: "${TUP_WINDOWS_MSYS2_BASE_VERSION:="$TUP_MSYS2_BASE_VERSION"}"
: "${TUP_WINDOWS_MSYS2_PACKAGES:="$TUP_MSYS2_PACKAGES"}"
export TUP_WINDOWS_SOURCE_MODE
export TUP_WINDOWS_SOURCE_REPO
export TUP_WINDOWS_SOURCE_REF
export TUP_WINDOWS_SOURCE_BUILD_COMMAND
export TUP_WINDOWS_PREBUILT_VERSION
export TUP_WINDOWS_PREBUILT_URL
export TUP_WINDOWS_PREBUILT_SHA256
export TUP_WINDOWS_MSYS2_BASE_VERSION
export TUP_WINDOWS_MSYS2_PACKAGES
#
# ct-remote bootstrap source selection:
# - auto (default): on x64 prefer local codetracer-ci source then fallback to pinned download;
#   on arm64 require local source and do not fallback to pinned x64 download
# - local: require local codetracer-ci source
# - download: always use pinned download (x64 only)
: "${CT_REMOTE_WINDOWS_SOURCE_MODE:=auto}"
: "${CT_REMOTE_WINDOWS_SOURCE_REPO:="$ROOT_DIR/../codetracer-ci"}"
export CT_REMOTE_WINDOWS_SOURCE_MODE
export CT_REMOTE_WINDOWS_SOURCE_REPO

export RUSTUP_HOME="$WINDOWS_DIY_INSTALL_ROOT/rustup"
export CARGO_HOME="$WINDOWS_DIY_INSTALL_ROOT/cargo"

to_windows_path() {
	if command -v cygpath >/dev/null 2>&1; then
		cygpath -w "$1"
	else
		echo "$1"
	fi
}

resolve_powershell_executable() {
	if command -v pwsh >/dev/null 2>&1; then
		echo "pwsh"
		return
	fi
	if command -v powershell.exe >/dev/null 2>&1; then
		echo "powershell.exe"
		return
	fi
	echo "PowerShell executable not found. Install PowerShell 7 (pwsh) or provide powershell.exe." >&2
	return 1
}

resolve_ttd_exe() {
	local candidates=()
	if [[ -n ${WINDOWS_DIY_TTD_EXE:-} ]]; then
		candidates+=("$WINDOWS_DIY_TTD_EXE")
	fi

	if [[ -n ${WINDOWS_DIY_TTD_DIR:-} ]]; then
		candidates+=("$WINDOWS_DIY_TTD_DIR/TTD.exe")
	fi

	local cmd_path=""
	cmd_path=$(command -v ttd.exe 2>/dev/null || true)
	if [[ -n $cmd_path ]]; then
		candidates+=("$cmd_path")
	fi
	cmd_path=$(command -v ttd 2>/dev/null || true)
	if [[ -n $cmd_path ]]; then
		candidates+=("$cmd_path")
	fi

	if [[ -n ${LOCALAPPDATA:-} ]]; then
		if command -v cygpath >/dev/null 2>&1; then
			candidates+=("$(cygpath -u "$LOCALAPPDATA")/Microsoft/WindowsApps/ttd.exe")
		fi
		candidates+=("$LOCALAPPDATA/Microsoft/WindowsApps/ttd.exe")
	fi
	if [[ -n ${USERPROFILE:-} ]]; then
		if command -v cygpath >/dev/null 2>&1; then
			candidates+=("$(cygpath -u "$USERPROFILE")/AppData/Local/Microsoft/WindowsApps/ttd.exe")
		fi
		candidates+=("$USERPROFILE/AppData/Local/Microsoft/WindowsApps/ttd.exe")
	fi
	candidates+=("$HOME/AppData/Local/Microsoft/WindowsApps/ttd.exe")

	local candidate
	for candidate in "${candidates[@]}"; do
		[[ -z $candidate ]] && continue
		if [[ -f $candidate ]]; then
			echo "$candidate"
			return 0
		fi
	done

	return 1
}

version_gte() {
	local actual=$1
	local required=$2
	if [[ $actual == "$required" ]]; then
		return 0
	fi
	local first
	first=$(printf '%s\n%s\n' "$actual" "$required" | sort -V | head -n1)
	[[ $first == "$required" ]]
}

load_ttd_runtime_metadata() {
	local metadata
	# shellcheck disable=SC2016 # Single quotes are intentional: this is a PowerShell script, not a bash expansion.
	metadata=$("$POWERSHELL_EXE" -NoProfile -Command '$ErrorActionPreference="SilentlyContinue"; $ttd=Get-AppxPackage -Name "Microsoft.TimeTravelDebugging" | Sort-Object Version -Descending | Select-Object -First 1; $windbg=Get-AppxPackage -Name "Microsoft.WinDbg" | Sort-Object Version -Descending | Select-Object -First 1; if ($null -ne $ttd) { "TTD_VERSION=$($ttd.Version)"; "TTD_INSTALL_LOCATION=$($ttd.InstallLocation)" }; if ($null -ne $windbg) { "WINDBG_VERSION=$($windbg.Version)"; "WINDBG_INSTALL_LOCATION=$($windbg.InstallLocation)" }' | tr -d '\r')
	local line
	while IFS= read -r line; do
		[[ -z $line ]] && continue
		local key=${line%%=*}
		local value=${line#*=}
		case "$key" in
		TTD_VERSION) WINDOWS_DIY_TTD_VERSION="$value" ;;
		TTD_INSTALL_LOCATION)
			if command -v cygpath >/dev/null 2>&1; then
				WINDOWS_DIY_TTD_DIR=$(cygpath -u "$value" 2>/dev/null || echo "$value")
			else
				WINDOWS_DIY_TTD_DIR="$value"
			fi
			;;
		WINDBG_VERSION) WINDOWS_DIY_WINDBG_VERSION="$value" ;;
		WINDBG_INSTALL_LOCATION)
			if command -v cygpath >/dev/null 2>&1; then
				WINDOWS_DIY_WINDBG_DIR=$(cygpath -u "$value" 2>/dev/null || echo "$value")
			else
				WINDOWS_DIY_WINDBG_DIR="$value"
			fi
			;;
		esac
	done <<<"$metadata"
}

POWERSHELL_EXE=$(resolve_powershell_executable)
ORIGINAL_BASH_PATH=$PATH

from_windows_path_list_to_unix() {
	local windows_path_list=$1
	local converted=()
	local entry
	IFS=';' read -r -a entries <<<"$windows_path_list"
	for entry in "${entries[@]}"; do
		if [[ -z $entry ]]; then
			continue
		fi
		if command -v cygpath >/dev/null 2>&1; then
			local unix_path
			unix_path=$(cygpath -u "$entry" 2>/dev/null || true)
			if [[ -n $unix_path ]]; then
				converted+=("$unix_path")
			fi
		fi
	done
	local joined=""
	local path_entry
	for path_entry in "${converted[@]}"; do
		if [[ -z $joined ]]; then
			joined="$path_entry"
		else
			joined="$joined:$path_entry"
		fi
	done
	echo "$joined"
}

import_msvc_env() {
	local export_blob
	export_blob=$("$POWERSHELL_EXE" -NoProfile -ExecutionPolicy Bypass -File "$(to_windows_path "$WINDOWS_DIR/export-msvc-env.ps1")" | tr -d '\r')

	if [[ -z $export_blob ]]; then
		return
	fi

	local line
	local pending_msvc_bin_unix=""
	local pending_msvc_linker=""
	while IFS= read -r line; do
		[[ -z $line ]] && continue
		local key=${line%%=*}
		local value=${line#*=}
		case "$key" in
		PATH | Path)
			local converted_path
			converted_path=$(from_windows_path_list_to_unix "$value")
			if [[ -n $converted_path ]]; then
				export PATH="$converted_path:$ORIGINAL_BASH_PATH"
			fi
			;;
		MSVC_BIN_DIR)
			pending_msvc_bin_unix=$(cygpath -u "$value" 2>/dev/null || true)
			pending_msvc_linker="$value\\link.exe"
			;;
		INCLUDE | LIB | LIBPATH | VCToolsInstallDir | VCINSTALLDIR | WindowsSdkDir | WindowsSDKVersion | UCRTVersion | UniversalCRTSdkDir)
			export "$key=$value"
			;;
		esac
	done <<<"$export_blob"

	if [[ -n $pending_msvc_bin_unix ]]; then
		export PATH="$pending_msvc_bin_unix:$PATH"
	fi
	if [[ -n $pending_msvc_linker ]]; then
		export CARGO_TARGET_AARCH64_PC_WINDOWS_MSVC_LINKER="$pending_msvc_linker"
		export CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER="$pending_msvc_linker"
		export CC=cl
		export CXX=cl
	fi
}

WINDOWS_ARCH=$("$POWERSHELL_EXE" -NoProfile -Command "(Get-CimInstance Win32_ComputerSystem).SystemType" | tr -d '\r' | tr '[:upper:]' '[:lower:]')
case "$WINDOWS_ARCH" in
*arm64*) NODE_ARCH="arm64" ;;
*x64* | *x86_64*) NODE_ARCH="x64" ;;
*)
	echo "Unsupported Windows architecture: $WINDOWS_ARCH" >&2
	return 1
	;;
esac

if [[ -z ${CT_REMOTE_WINDOWS_SOURCE_RID:-} ]]; then
	case "$NODE_ARCH" in
	arm64) CT_REMOTE_WINDOWS_SOURCE_RID="win-arm64" ;;
	x64) CT_REMOTE_WINDOWS_SOURCE_RID="win-x64" ;;
	*)
		echo "Unsupported ct-remote source RID architecture mapping: $NODE_ARCH" >&2
		return 1
		;;
	esac
fi
export CT_REMOTE_WINDOWS_SOURCE_RID

NODE_DIR="$WINDOWS_DIY_INSTALL_ROOT/node/$NODE_VERSION/node-v$NODE_VERSION-win-$NODE_ARCH"
UV_DIR="$WINDOWS_DIY_INSTALL_ROOT/uv/$UV_VERSION"
resolve_dotnet_root() {
	local candidates=()
	if [[ -n ${WINDOWS_DIY_DOTNET_ROOT:-} ]]; then
		candidates+=("$WINDOWS_DIY_DOTNET_ROOT")
	fi
	candidates+=("$WINDOWS_DIY_INSTALL_ROOT/dotnet/$DOTNET_SDK_VERSION")
	candidates+=("/c/Program Files/dotnet")
	candidates+=("/mnt/c/Program Files/dotnet")

	local candidate
	for candidate in "${candidates[@]}"; do
		[[ -z $candidate ]] && continue
		if [[ -f "$candidate/dotnet.exe" ]]; then
			echo "$candidate"
			return 0
		fi
	done

	return 1
}
if ! DOTNET_ROOT=$(resolve_dotnet_root); then
	echo "ERROR: Could not find dotnet.exe. Install pinned SDK $DOTNET_SDK_VERSION (for example: winget install --id Microsoft.DotNet.SDK.9 --exact --source winget) or set WINDOWS_DIY_DOTNET_ROOT." >&2
	if [[ $WINDOWS_ENV_WAS_SOURCED -eq 1 ]]; then
		return 1
	fi
	exit 1
fi
export DOTNET_ROOT
WINDOWS_DIY_TTD_VERSION="${WINDOWS_DIY_TTD_VERSION:-}"
WINDOWS_DIY_TTD_DIR="${WINDOWS_DIY_TTD_DIR:-}"
WINDOWS_DIY_TTD_REPLAY_DLL="${WINDOWS_DIY_TTD_REPLAY_DLL:-}"
WINDOWS_DIY_TTD_REPLAY_CPU_DLL="${WINDOWS_DIY_TTD_REPLAY_CPU_DLL:-}"
WINDOWS_DIY_WINDBG_VERSION="${WINDOWS_DIY_WINDBG_VERSION:-}"
WINDOWS_DIY_WINDBG_DIR="${WINDOWS_DIY_WINDBG_DIR:-}"
load_ttd_runtime_metadata
resolve_windbg_debug_tool() {
	local file_name=$1
	local candidates=()
	local arch=${PROCESSOR_ARCHITECTURE:-}
	case "${arch,,}" in
	amd64) candidates+=("amd64" "x64" "arm64" "x86") ;;
	arm64) candidates+=("arm64" "amd64" "x64" "x86") ;;
	x86) candidates+=("x86" "amd64" "x64" "arm64") ;;
	*) candidates+=("arm64" "amd64" "x64" "x86") ;;
	esac

	if [[ -n ${WINDOWS_DIY_WINDBG_DIR:-} ]]; then
		local sub
		for sub in "${candidates[@]}"; do
			local candidate="$WINDOWS_DIY_WINDBG_DIR/$sub/$file_name"
			if [[ -f $candidate ]]; then
				echo "$candidate"
				return 0
			fi
		done
	fi
	return 1
}

resolve_system32_debug_tool() {
	local file_name=$1
	local system_root=${SystemRoot:-C:/Windows}
	local candidate="$system_root/System32/$file_name"
	if [[ -f $candidate ]]; then
		echo "$candidate"
		return 0
	fi
	return 1
}

if [[ -n ${WINDOWS_DIY_TTD_DIR:-} ]]; then
	ttd_replay_candidate="$WINDOWS_DIY_TTD_DIR/TTDReplay.dll"
	ttd_replay_cpu_candidate="$WINDOWS_DIY_TTD_DIR/TTDReplayCPU.dll"
	if [[ -f $ttd_replay_candidate ]]; then
		WINDOWS_DIY_TTD_REPLAY_DLL="$ttd_replay_candidate"
	fi
	if [[ -f $ttd_replay_cpu_candidate ]]; then
		WINDOWS_DIY_TTD_REPLAY_CPU_DLL="$ttd_replay_cpu_candidate"
	fi
fi
if TTD_EXE_PATH=$(resolve_ttd_exe); then
	export WINDOWS_DIY_TTD_EXE="$TTD_EXE_PATH"
else
	unset WINDOWS_DIY_TTD_EXE
fi
export WINDOWS_DIY_TTD_VERSION
export WINDOWS_DIY_TTD_DIR
export WINDOWS_DIY_TTD_REPLAY_DLL
export WINDOWS_DIY_TTD_REPLAY_CPU_DLL
export WINDOWS_DIY_WINDBG_VERSION
export WINDOWS_DIY_WINDBG_DIR
WINDOWS_DIY_CDB_EXE="${WINDOWS_DIY_CDB_EXE:-}"
WINDOWS_DIY_DBGENG_DLL="${WINDOWS_DIY_DBGENG_DLL:-}"
WINDOWS_DIY_DBGMODEL_DLL="${WINDOWS_DIY_DBGMODEL_DLL:-}"
WINDOWS_DIY_DBGHELP_DLL="${WINDOWS_DIY_DBGHELP_DLL:-}"
if WINDOWS_DIY_CDB_EXE=$(resolve_windbg_debug_tool "cdb.exe"); then :; fi
if WINDOWS_DIY_DBGENG_DLL=$(resolve_windbg_debug_tool "dbgeng.dll"); then :; fi
if WINDOWS_DIY_DBGMODEL_DLL=$(resolve_windbg_debug_tool "dbgmodel.dll"); then :; fi
if WINDOWS_DIY_DBGHELP_DLL=$(resolve_windbg_debug_tool "dbghelp.dll"); then :; fi
if system32_dbgeng=$(resolve_system32_debug_tool "dbgeng.dll"); then WINDOWS_DIY_DBGENG_DLL="$system32_dbgeng"; fi
if system32_dbgmodel=$(resolve_system32_debug_tool "dbgmodel.dll"); then WINDOWS_DIY_DBGMODEL_DLL="$system32_dbgmodel"; fi
if system32_dbghelp=$(resolve_system32_debug_tool "dbghelp.dll"); then WINDOWS_DIY_DBGHELP_DLL="$system32_dbghelp"; fi
export WINDOWS_DIY_CDB_EXE
export WINDOWS_DIY_DBGENG_DLL
export WINDOWS_DIY_DBGMODEL_DLL
export WINDOWS_DIY_DBGHELP_DLL
export TTD_MIN_VERSION="$TTD_REQUIRED_MIN_VERSION"
export WINDBG_MIN_VERSION="$WINDBG_REQUIRED_MIN_VERSION"
if [[ ${WINDOWS_DIY_ENSURE_TTD:-1} == "1" ]]; then
	if [[ -z ${WINDOWS_DIY_TTD_EXE:-} ]]; then
		echo "ERROR: Microsoft Time Travel Debugging is not available. Install with: winget install --id Microsoft.TimeTravelDebugging --exact --source winget" >&2
		if [[ $WINDOWS_ENV_WAS_SOURCED -eq 1 ]]; then
			return 1
		fi
		exit 1
	fi
	if [[ -z ${WINDOWS_DIY_TTD_VERSION:-} ]]; then
		echo "ERROR: Could not determine Microsoft.TimeTravelDebugging version via Get-AppxPackage." >&2
		if [[ $WINDOWS_ENV_WAS_SOURCED -eq 1 ]]; then
			return 1
		fi
		exit 1
	fi
	if [[ -z ${WINDOWS_DIY_TTD_REPLAY_DLL:-} ]]; then
		echo "ERROR: TTDReplay.dll was not found under WINDOWS_DIY_TTD_DIR='${WINDOWS_DIY_TTD_DIR:-<unset>}'." >&2
		if [[ $WINDOWS_ENV_WAS_SOURCED -eq 1 ]]; then
			return 1
		fi
		exit 1
	fi
	if ! version_gte "$WINDOWS_DIY_TTD_VERSION" "$TTD_REQUIRED_MIN_VERSION"; then
		echo "ERROR: Microsoft.TimeTravelDebugging version '$WINDOWS_DIY_TTD_VERSION' is below required '$TTD_REQUIRED_MIN_VERSION'. Upgrade with: winget install --id Microsoft.TimeTravelDebugging --exact --source winget" >&2
		if [[ $WINDOWS_ENV_WAS_SOURCED -eq 1 ]]; then
			return 1
		fi
		exit 1
	fi
	if [[ -z ${WINDOWS_DIY_WINDBG_VERSION:-} ]]; then
		echo "ERROR: Could not determine Microsoft.WinDbg version via Get-AppxPackage. Install with: winget install --id Microsoft.WinDbg --exact --source winget" >&2
		if [[ $WINDOWS_ENV_WAS_SOURCED -eq 1 ]]; then
			return 1
		fi
		exit 1
	fi
	if ! version_gte "$WINDOWS_DIY_WINDBG_VERSION" "$WINDBG_REQUIRED_MIN_VERSION"; then
		echo "ERROR: Microsoft.WinDbg version '$WINDOWS_DIY_WINDBG_VERSION' is below required '$WINDBG_REQUIRED_MIN_VERSION'. Upgrade with: winget install --id Microsoft.WinDbg --exact --source winget" >&2
		if [[ $WINDOWS_ENV_WAS_SOURCED -eq 1 ]]; then
			return 1
		fi
		exit 1
	fi
fi
if [[ ${WINDOWS_DIY_ENSURE_DOTNET:-1} == "1" ]]; then
	dotnet_sdks=$("$DOTNET_ROOT/dotnet.exe" --list-sdks 2>/dev/null | tr -d '\r' || true)
	if ! printf '%s\n' "$dotnet_sdks" | grep -Eq "^${DOTNET_SDK_VERSION//./\\.}[[:space:]]"; then
		allow_feature_rollforward="${WINDOWS_DIY_DOTNET_ROLL_FORWARD_FEATURE:-1}"
		effective_dotnet_sdk=""
		if [[ $allow_feature_rollforward == "1" || $allow_feature_rollforward == "true" || $allow_feature_rollforward == "yes" || $allow_feature_rollforward == "on" ]]; then
			pinned_major_minor=$(printf '%s' "$DOTNET_SDK_VERSION" | sed -E 's/^([0-9]+\.[0-9]+)\..*/\1/')
			effective_dotnet_sdk=$(printf '%s\n' "$dotnet_sdks" | awk '{print $1}' | grep -E "^${pinned_major_minor//./\\.}\.[0-9]+$" | sort -V | tail -n1 || true)
			if [[ -n $effective_dotnet_sdk ]]; then
				export DOTNET_SDK_VERSION_EFFECTIVE="$effective_dotnet_sdk"
				echo "WARNING: Pinned .NET SDK $DOTNET_SDK_VERSION not found; using feature-band roll-forward '$DOTNET_SDK_VERSION_EFFECTIVE' from '$DOTNET_ROOT/dotnet.exe'." >&2
			fi
		fi

		if [[ -z ${DOTNET_SDK_VERSION_EFFECTIVE:-} ]]; then
			echo "ERROR: Pinned .NET SDK $DOTNET_SDK_VERSION is not installed under '$DOTNET_ROOT'. Install it with: winget install --id Microsoft.DotNet.SDK.9 --exact --source winget" >&2
			if [[ $WINDOWS_ENV_WAS_SOURCED -eq 1 ]]; then
				return 1
			fi
			exit 1
		fi
	else
		export DOTNET_SDK_VERSION_EFFECTIVE="$DOTNET_SDK_VERSION"
	fi
fi
NODE_PACKAGES_BIN="$ROOT_DIR/node-packages/node_modules/.bin"
NIM_VERSION_ROOT="$WINDOWS_DIY_INSTALL_ROOT/nim/$NIM_VERSION"
NIM_RELATIVE_PATH_FILE="$NIM_VERSION_ROOT/nim.install.relative-path"
if [[ -f $NIM_RELATIVE_PATH_FILE ]]; then
	NIM_RELATIVE_PATH=$(tr -d '\r\n' <"$NIM_RELATIVE_PATH_FILE")
	NIM_DIR="$WINDOWS_DIY_INSTALL_ROOT/$NIM_RELATIVE_PATH"
elif [[ -d "$NIM_VERSION_ROOT/prebuilt/nim-$NIM_VERSION" ]]; then
	NIM_DIR="$NIM_VERSION_ROOT/prebuilt/nim-$NIM_VERSION"
else
	# Backward compatibility for older layouts used before source/prebuilt mode split.
	NIM_DIR="$NIM_VERSION_ROOT/nim-$NIM_VERSION"
fi
NIM1="$NIM_DIR/bin/nim.exe"
NIM1_WINDOWS=$(to_windows_path "$NIM1")
NIM_SHIMS_DIR="$WINDOWS_DIY_INSTALL_ROOT/shims"
NIM_LEGACY_PREBUILT_BIN_DIR="$NIM_VERSION_ROOT/prebuilt/nim-$NIM_VERSION/bin"
CT_REMOTE_DIR="$WINDOWS_DIY_INSTALL_ROOT/ct-remote/$CT_REMOTE_VERSION"
CAPNP_VERSION_ROOT="$WINDOWS_DIY_INSTALL_ROOT/capnp/$CAPNP_VERSION"
resolve_capnp_dir() {
	local capnp_relative_path_file="$CAPNP_VERSION_ROOT/capnp.install.relative-path"
	if [[ -f $capnp_relative_path_file ]]; then
		local capnp_relative_path
		capnp_relative_path=$(tr -d '\r\n' <"$capnp_relative_path_file")
		echo "$WINDOWS_DIY_INSTALL_ROOT/$capnp_relative_path"
		return
	fi
	if [[ -d "$CAPNP_VERSION_ROOT/prebuilt/capnproto-tools-win32-$CAPNP_VERSION" ]]; then
		echo "$CAPNP_VERSION_ROOT/prebuilt/capnproto-tools-win32-$CAPNP_VERSION"
		return
	fi
	# Backward compatibility for older layouts used before source/prebuilt mode split.
	echo "$CAPNP_VERSION_ROOT/capnproto-tools-win32-$CAPNP_VERSION"
}

CAPNP_DIR=$(resolve_capnp_dir)
if [[ -d "$CAPNP_DIR/bin" ]]; then
	CAPNP_BIN_DIR="$CAPNP_DIR/bin"
else
	CAPNP_BIN_DIR="$CAPNP_DIR"
fi
TUP_ROOT="$WINDOWS_DIY_INSTALL_ROOT/tup"
resolve_tup_dir() {
	local tup_relative_path_file="$TUP_ROOT/tup.install.relative-path"
	if [[ -f $tup_relative_path_file ]]; then
		local tup_relative_path
		tup_relative_path=$(tr -d '\r\n' <"$tup_relative_path_file")
		echo "$WINDOWS_DIY_INSTALL_ROOT/$tup_relative_path"
		return
	fi
	# Backward compatibility fallback for direct installs.
	if [[ -d "$TUP_ROOT/current" ]]; then
		echo "$TUP_ROOT/current"
		return
	fi
	echo "$TUP_ROOT"
}

TUP_DIR=$(resolve_tup_dir)
TUP="$TUP_DIR/tup.exe"
TUP_MSYS2_MINGW_BIN="$WINDOWS_DIY_INSTALL_ROOT/tup/msys2/$TUP_WINDOWS_MSYS2_BASE_VERSION/msys64/mingw64/bin"
NARGO_ROOT="$WINDOWS_DIY_INSTALL_ROOT/nargo"
resolve_nargo_dir() {
	local nargo_relative_path_file="$NARGO_ROOT/nargo.install.relative-path"
	if [[ -f $nargo_relative_path_file ]]; then
		local nargo_relative_path
		nargo_relative_path=$(tr -d '\r\n' <"$nargo_relative_path_file")
		echo "$WINDOWS_DIY_INSTALL_ROOT/$nargo_relative_path"
		return
	fi
	echo ""
}
NARGO_DIR=$(resolve_nargo_dir)

ensure_node_tooling() {
	local stylus_cmd="$NODE_PACKAGES_BIN/stylus.cmd"
	local webpack_cmd="$NODE_PACKAGES_BIN/webpack.cmd"
	local node_modules_dir="$ROOT_DIR/node-packages/node_modules"

	if [[ -f $stylus_cmd && -f $webpack_cmd ]]; then
		return
	fi

	if [[ ${WINDOWS_DIY_SETUP_NODE_DEPS:-1} != "1" ]]; then
		echo "WARNING: Node deps are missing (stylus/webpack). Set WINDOWS_DIY_SETUP_NODE_DEPS=1 or run 'cd node-packages && npx yarn install'." >&2
		return
	fi

	echo "Windows DIY: Node deps missing, running yarn install in node-packages..." >&2
	pushd "$ROOT_DIR/node-packages" >/dev/null
	if [[ -f yarn.lock ]]; then
		npx yarn install --frozen-lockfile
	else
		npx yarn install
	fi
	popd >/dev/null

	if [[ -d $node_modules_dir && ! -e "$ROOT_DIR/node_modules" ]]; then
		ln -s "$node_modules_dir" "$ROOT_DIR/node_modules" 2>/dev/null || true
	fi

	if [[ ! -f $stylus_cmd ]]; then
		echo "ERROR: stylus.cmd is still missing after node dependency setup. Expected at '$stylus_cmd'." >&2
		return 1
	fi
}

if [[ ${WINDOWS_DIY_SYNC:-1} == "1" ]]; then
	"$POWERSHELL_EXE" -NoProfile -ExecutionPolicy Bypass -File "$(to_windows_path "$WINDOWS_DIR/bootstrap-windows-diy.ps1")" -InstallRoot "$(to_windows_path "$WINDOWS_DIY_INSTALL_ROOT")"
	CAPNP_DIR=$(resolve_capnp_dir)
	TUP_DIR=$(resolve_tup_dir)
	TUP="$TUP_DIR/tup.exe"
	NARGO_DIR=$(resolve_nargo_dir)
fi

if ! ensure_node_tooling; then
	if [[ $WINDOWS_ENV_WAS_SOURCED -eq 1 ]]; then
		return 1
	fi
	exit 1
fi

import_msvc_env
export CT_NIM_CC_FLAGS="--cc:gcc"

mkdir -p "$NIM_SHIMS_DIR"
cat >"$NIM_SHIMS_DIR/nim.cmd" <<EOF
@echo off
setlocal
set "NIM_EXE=$NIM1_WINDOWS"
set "CT_CPU_FLAG="
set "CT_CC_FLAG=%CT_NIM_CC_FLAGS%"
if "%CT_CC_FLAG%"=="" set "CT_CC_FLAG=--cc:gcc"
if /I "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "CT_CPU_FLAG=--cpu:arm64"
"%NIM_EXE%" %CT_CC_FLAG% %CT_CPU_FLAG% %*
exit /b %ERRORLEVEL%
EOF

create_bash_exe_shim() {
	local shim_name=$1
	local exe_path=$2
	if [[ ! -f $exe_path ]]; then
		return
	fi
	cat >"$NIM_SHIMS_DIR/$shim_name" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "$exe_path" "\$@"
EOF
	chmod +x "$NIM_SHIMS_DIR/$shim_name"
}

create_bash_exe_shim "tup" "$TUP"
create_bash_exe_shim "dotnet" "$DOTNET_ROOT/dotnet.exe"
create_bash_exe_shim "node" "$NODE_DIR/node.exe"
create_bash_exe_shim "npm" "$NODE_DIR/npm.exe"
create_bash_exe_shim "npx" "$NODE_DIR/npx.exe"
create_bash_exe_shim "uv" "$UV_DIR/uv.exe"
create_bash_exe_shim "capnp" "$CAPNP_BIN_DIR/capnp.exe"
create_bash_exe_shim "capnpc-c++" "$CAPNP_BIN_DIR/capnpc-c++.exe"
create_bash_exe_shim "nargo" "$NARGO_DIR/nargo.exe"
create_bash_exe_shim "nim" "$NIM1"
create_bash_exe_shim "ct-remote" "$CT_REMOTE_DIR/ct-remote.exe"
create_bash_exe_shim "cargo" "$CARGO_HOME/bin/cargo.exe"
create_bash_exe_shim "rustc" "$CARGO_HOME/bin/rustc.exe"
create_bash_exe_shim "rustup" "$CARGO_HOME/bin/rustup.exe"
if [[ -n ${WINDOWS_DIY_TTD_EXE:-} ]]; then
	create_bash_exe_shim "ttd" "$WINDOWS_DIY_TTD_EXE"
fi
if [[ -n ${WINDOWS_DIY_CDB_EXE:-} ]]; then
	create_bash_exe_shim "cdb" "$WINDOWS_DIY_CDB_EXE"
fi

path_prefix=()
if [[ -d $TUP_MSYS2_MINGW_BIN ]]; then
	path_prefix+=("$TUP_MSYS2_MINGW_BIN")
fi
if [[ -n ${WINDOWS_DIY_TTD_EXE:-} ]]; then
	path_prefix+=("$(dirname "$WINDOWS_DIY_TTD_EXE")")
fi
if [[ -n ${WINDOWS_DIY_CDB_EXE:-} ]]; then
	path_prefix+=("$(dirname "$WINDOWS_DIY_CDB_EXE")")
fi
if [[ -n ${WINDOWS_DIY_DBGENG_DLL:-} ]]; then
	path_prefix+=("$(dirname "$WINDOWS_DIY_DBGENG_DLL")")
fi
path_prefix+=("$DOTNET_ROOT" "$NODE_PACKAGES_BIN" "$NIM_SHIMS_DIR" "$CARGO_HOME/bin" "$NODE_DIR" "$UV_DIR")
if [[ -d $NIM_LEGACY_PREBUILT_BIN_DIR ]]; then
	path_prefix+=("$NIM_LEGACY_PREBUILT_BIN_DIR")
fi
path_prefix+=("$NIM_DIR/bin" "$CT_REMOTE_DIR" "$CAPNP_BIN_DIR" "$CAPNP_DIR" "$TUP_DIR" "$NARGO_DIR")

joined_path=""
for entry in "${path_prefix[@]}"; do
	if [[ -z $entry ]]; then
		continue
	fi
	if [[ -z $joined_path ]]; then
		joined_path="$entry"
	else
		joined_path="$joined_path:$entry"
	fi
done
export PATH="$joined_path:$PATH"
export NIM1
export CAPNP_DIR
export TUP
export TUP_DIR
export NARGO_DIR

# Shared runtime env expected by ct/ct_wrapper and ui-tests launcher.
# shellcheck source=non-nix-build/windows/setup-codetracer-runtime-env.sh
source "$WINDOWS_DIR/setup-codetracer-runtime-env.sh"

# Ensure tree-sitter-nim parser.c exists before local Windows builds that depend on it.
# Set WINDOWS_DIY_ENSURE_TREE_SITTER_NIM_PARSER=0 to skip this check.
if [[ ${WINDOWS_DIY_ENSURE_TREE_SITTER_NIM_PARSER:-1} == "1" ]]; then
	bash "$NON_NIX_BUILD_DIR/ensure_tree_sitter_nim_parser.sh"
fi

echo "WINDOWS_DIY_INSTALL_ROOT=$WINDOWS_DIY_INSTALL_ROOT"
echo "RUSTUP_HOME=$RUSTUP_HOME"
echo "CARGO_HOME=$CARGO_HOME"
echo "NODE_DIR=$NODE_DIR"
echo "UV_DIR=$UV_DIR"
echo "DOTNET_SDK_VERSION=$DOTNET_SDK_VERSION"
echo "DOTNET_ROOT=$DOTNET_ROOT"
echo "WINDBG_MIN_VERSION=$WINDBG_MIN_VERSION"
echo "WINDOWS_DIY_WINDBG_VERSION=${WINDOWS_DIY_WINDBG_VERSION:-}"
echo "WINDOWS_DIY_WINDBG_DIR=${WINDOWS_DIY_WINDBG_DIR:-}"
echo "TTD_MIN_VERSION=$TTD_MIN_VERSION"
echo "WINDOWS_DIY_TTD_VERSION=${WINDOWS_DIY_TTD_VERSION:-}"
echo "WINDOWS_DIY_TTD_DIR=${WINDOWS_DIY_TTD_DIR:-}"
echo "WINDOWS_DIY_TTD_REPLAY_DLL=${WINDOWS_DIY_TTD_REPLAY_DLL:-}"
echo "WINDOWS_DIY_TTD_REPLAY_CPU_DLL=${WINDOWS_DIY_TTD_REPLAY_CPU_DLL:-}"
echo "WINDOWS_DIY_CDB_EXE=${WINDOWS_DIY_CDB_EXE:-}"
echo "WINDOWS_DIY_DBGENG_DLL=${WINDOWS_DIY_DBGENG_DLL:-}"
echo "WINDOWS_DIY_DBGMODEL_DLL=${WINDOWS_DIY_DBGMODEL_DLL:-}"
echo "WINDOWS_DIY_DBGHELP_DLL=${WINDOWS_DIY_DBGHELP_DLL:-}"
echo "NIM_DIR=$NIM_DIR"
echo "NIM1=$NIM1"
echo "NIM_WINDOWS_SOURCE_MODE=$NIM_WINDOWS_SOURCE_MODE"
echo "NIM_WINDOWS_SOURCE_REPO=$NIM_WINDOWS_SOURCE_REPO"
echo "NIM_WINDOWS_SOURCE_REF=$NIM_WINDOWS_SOURCE_REF"
echo "NIM_WINDOWS_CSOURCES_REPO=$NIM_WINDOWS_CSOURCES_REPO"
echo "NIM_WINDOWS_CSOURCES_REF=$NIM_WINDOWS_CSOURCES_REF"
echo "CT_NIM_CC_FLAGS=$CT_NIM_CC_FLAGS"
echo "CT_REMOTE_DIR=$CT_REMOTE_DIR"
echo "CT_REMOTE_WINDOWS_SOURCE_MODE=$CT_REMOTE_WINDOWS_SOURCE_MODE"
echo "CT_REMOTE_WINDOWS_SOURCE_REPO=$CT_REMOTE_WINDOWS_SOURCE_REPO"
echo "CT_REMOTE_WINDOWS_SOURCE_RID=$CT_REMOTE_WINDOWS_SOURCE_RID"
echo "CAPNP_WINDOWS_SOURCE_MODE=$CAPNP_WINDOWS_SOURCE_MODE"
echo "CAPNP_WINDOWS_SOURCE_REPO=$CAPNP_WINDOWS_SOURCE_REPO"
echo "CAPNP_WINDOWS_SOURCE_REF=$CAPNP_WINDOWS_SOURCE_REF"
echo "CAPNP_DIR=$CAPNP_DIR"
echo "TUP_WINDOWS_SOURCE_MODE=$TUP_WINDOWS_SOURCE_MODE"
echo "TUP_WINDOWS_SOURCE_REPO=$TUP_WINDOWS_SOURCE_REPO"
echo "TUP_WINDOWS_SOURCE_REF=$TUP_WINDOWS_SOURCE_REF"
echo "TUP_WINDOWS_SOURCE_BUILD_COMMAND=$TUP_WINDOWS_SOURCE_BUILD_COMMAND"
echo "TUP_WINDOWS_PREBUILT_VERSION=$TUP_WINDOWS_PREBUILT_VERSION"
echo "TUP_WINDOWS_PREBUILT_URL=$TUP_WINDOWS_PREBUILT_URL"
echo "TUP_WINDOWS_PREBUILT_SHA256=$TUP_WINDOWS_PREBUILT_SHA256"
echo "TUP_WINDOWS_MSYS2_BASE_VERSION=$TUP_WINDOWS_MSYS2_BASE_VERSION"
echo "TUP_WINDOWS_MSYS2_PACKAGES=$TUP_WINDOWS_MSYS2_PACKAGES"
echo "TUP_DIR=$TUP_DIR"
echo "TUP=$TUP"
echo "NARGO_DIR=$NARGO_DIR"
echo "CODETRACER_REPO_ROOT_PATH=$CODETRACER_REPO_ROOT_PATH"
echo "NIX_CODETRACER_EXE_DIR=$NIX_CODETRACER_EXE_DIR"
echo "LINKS_PATH_DIR=$LINKS_PATH_DIR"
echo "CODETRACER_E2E_CT_PATH=${CODETRACER_E2E_CT_PATH:-}"
echo "CODETRACER_CT_PATHS=$CODETRACER_CT_PATHS"
echo "WINDOWS_DIY_TTD_EXE=${WINDOWS_DIY_TTD_EXE:-}"
