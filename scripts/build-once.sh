#!/usr/bin/env bash
set -euo pipefail

# Generate isonim's build/tailwind-styles.json before any frontend Nim
# compile. ``src/frontend/ui_js.nim`` transitively imports
# ``isonim/dsl/tailwind``, which ``staticRead``s that file at Nim compile
# time — a missing file is an uncatchable compile error
# (see isonim/src/isonim/dsl/tailwind.nim), so the ``frontend-ui-js``
# build action fails without it. ``build-tailwind.sh`` regenerates it each
# run (cheap), driving the extract over BOTH isonim's and CodeTracer's own
# ``.nim`` sources so frontend-only utility classes are not silently
# dropped. Failures must propagate — the uncatchable staticRead otherwise
# resurfaces as an opaque Nim compile error several minutes later.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/build-tailwind.sh"

# Reprobuild branch: macOS (Darwin) and Linux both use Nix tool
# provisioning (the codetracer dev shell provisions every `uses:` tool
# into /nix/store, picked up via the cakNix adapter); Windows (MINGW* /
# MSYS* via Git Bash) uses Scoop/PATH provisioning since the codetracer
# DIY toolchain bootstrap (`. env.ps1`) has already populated PATH with
# every tool the codetracer `uses:` clause references on its Windows
# branch. On all three, the codetracer recipe lives in `reprobuild.nim`
# and is built end-to-end via the local `repro` binary.
case "$(uname -s)" in
Darwin) ct_reprobuild_host="darwin" ;;
Linux)
	# Reprobuild is the default build driver on macOS, but on Linux it is
	# still experimental: keep `just build-once` on the legacy tup path by
	# default while we gain more experience with reprobuild here. Developers
	# can opt in per-invocation with CODETRACER_REPROBUILD_LINUX=1. Windows
	# keeps the reprobuild branch because it has no tup fallback in this
	# script.
	if [ -n "${CODETRACER_REPROBUILD_LINUX:-}" ]; then
		ct_reprobuild_host="linux"
	else
		ct_reprobuild_host=""
	fi
	;;
MINGW* | MSYS* | CYGWIN*) ct_reprobuild_host="windows" ;;
*) ct_reprobuild_host="" ;;
esac

if [ -n "$ct_reprobuild_host" ]; then
	# Build configuration (debug/release), selected by CODETRACER_CONFIG
	# (default: debug). It picks the reprobuild output tree
	# (`src/build-<config>-repro` on all platforms — the `-repro` suffix keeps
	# it out of tup's `src/build-debug` variant dir) and threads the
	# `buildType` reprobuild variant to the recipe so the value participates in
	# the graph cache key (see reprobuild-specs/Standard-Configurations.md and
	# `buildDebugRoot()` in reprobuild.nim, the source of truth). `--release`
	# on a `repro` with the standard-config shorthands is equivalent to
	# `REPRO_VARIANTS=buildType=release`; we set the env directly so this works
	# with any `repro` binary.
	ct_config="${CODETRACER_CONFIG:-debug}"
	ct_repro_out_root="src/build-${ct_config}-repro"
	if [ -z "${REPRO_VARIANTS:-}" ]; then
		export REPRO_VARIANTS="buildType=${ct_config}"
	elif ! printf '%s' "$REPRO_VARIANTS" | grep -q "buildType="; then
		export REPRO_VARIANTS="${REPRO_VARIANTS},buildType=${ct_config}"
	fi

	repro_bin="${REPROBUILD_BIN:-}"
	reprobuild_root="${CODETRACER_REPROBUILD_REPO_PATH:-}"

	if [ -z "$reprobuild_root" ]; then
		for candidate in ../reprobuild ../../reprobuild; do
			if [ -d "$candidate/libs/repro_cli_support" ]; then
				reprobuild_root="$(cd "$candidate" && pwd)"
				break
			fi
		done
	fi

	if [ -z "$reprobuild_root" ] && [ -n "${REPROBUILD_SOURCE_ROOT:-}" ] &&
		[[ $REPROBUILD_SOURCE_ROOT != /nix/store/* ]]; then
		reprobuild_root="$REPROBUILD_SOURCE_ROOT"
	fi

	if [ -z "$repro_bin" ]; then
		repro_bin="$(command -v repro || true)"
	fi

	# On Windows, `repro` ships as `repro.exe`; the `repro` (no extension)
	# alias may not exist depending on how the sibling reprobuild was
	# built. Probe both filenames under the sibling's `build/bin/`.
	if [ -z "$repro_bin" ] && [ -n "$reprobuild_root" ]; then
		for cand in "$reprobuild_root/build/bin/repro.exe" "$reprobuild_root/build/bin/repro"; do
			if [ -x "$cand" ]; then
				repro_bin="$cand"
				break
			fi
		done
	fi

	if [ -z "$repro_bin" ]; then
		echo "Error: repro is required for codetracer reprobuild builds on $ct_reprobuild_host." >&2
		echo "Set REPROBUILD_BIN or CODETRACER_REPROBUILD_REPO_PATH, or put repro on PATH." >&2
		exit 127
	fi

	if [ -n "$reprobuild_root" ]; then
		export REPROBUILD_SOURCE_ROOT="$reprobuild_root"
		export CODETRACER_REPROBUILD_REPO_PATH="${CODETRACER_REPROBUILD_REPO_PATH:-$reprobuild_root}"
	fi

	# Point the fs-snoop process monitor at the shim library that ships
	# next to the repro binary. repro normally finds librepro_monitor_shim
	# via getAppDir()/../lib, but the daemon-hosted build runs through a
	# relocated `repro-daemon` copy under ~/.local/state/repro/daemon/, whose
	# appDir has no sibling lib/ — so without an explicit path every monitored
	# action aborts with "cannot find librepro_monitor_shim". The daemon
	# inherits this env var from `repro build`, and the fs-snoop resolver
	# honours REPRO_MONITOR_SHIM_LIB ahead of the appDir probes (see
	# reprobuild libs/repro_monitor_depfile/.../fs_snoop.nim). Only set it
	# when we can actually locate the co-located shim and the caller hasn't
	# pinned one already.
	if [ -z "${REPRO_MONITOR_SHIM_LIB:-}" ]; then
		case "$ct_reprobuild_host" in
		darwin) ct_shim_name="librepro_monitor_shim.dylib" ;;
		windows) ct_shim_name="librepro_monitor_shim.dll" ;;
		*) ct_shim_name="librepro_monitor_shim.so" ;;
		esac
		ct_repro_bin_dir="$(cd "$(dirname "$repro_bin")" && pwd)"
		for ct_shim_candidate in \
			"$ct_repro_bin_dir/../lib/$ct_shim_name" \
			"$ct_repro_bin_dir/$ct_shim_name"; do
			if [ -f "$ct_shim_candidate" ]; then
				# Declare and assign separately so the command substitution's
				# exit status is not masked by ``export`` (shellcheck SC2155).
				ct_shim_dir="$(cd "$(dirname "$ct_shim_candidate")" && pwd)"
				ct_shim_abs="$ct_shim_dir/$(basename "$ct_shim_candidate")"
				export REPRO_MONITOR_SHIM_LIB="$ct_shim_abs"
				break
			fi
		done
	fi

	# The codetracer reprobuild build is nix-provisioned, so mirror the
	# pure-nix package build (nix/packages/default.nix) for the db-backend
	# cargo crate's build scripts instead of letting them re-enter a nested
	# ``direnv exec`` / ``nix develop``:
	#   * CODETRACER_DB_BACKEND_SKIP_DIRENV=1 makes
	#     src/db-backend/build.rs::regenerate_c invoke ``bash`` directly. The
	#     default POSIX path spawns ``direnv exec <native-recorder> bash
	#     build_native_api.sh``, which re-enters a full ``nix develop`` of the
	#     native-recorder flake *inside* the fs-snoop sandbox — minutes-long
	#     on first run and fragile under process monitoring.
	#   * CODETRACER_TRACE_FORMAT_NIM_SKIP_NIMBLE_INSTALL=1 keeps
	#     codetracer_trace_writer_nim's build.rs from running a network
	#     ``nimble install``.
	#   * CT_EMULATOR_EXTRA_NIM_PATHS / CODETRACER_TRACE_FORMAT_NIM_EXTRA_PATHS
	#     inject codetracer's vendored ``stew`` tree (which ships the newer
	#     results.nim those scripts rely on) so their ``nim c`` resolves
	#     ``results`` / ``stew`` without a nimble package store.
	# Windows skips direnv unconditionally in build.rs and sets up Nim via
	# env.ps1, so leave that branch untouched.
	if [ "$ct_reprobuild_host" != "windows" ]; then
		export CODETRACER_DB_BACKEND_SKIP_DIRENV="${CODETRACER_DB_BACKEND_SKIP_DIRENV:-1}"
		export CODETRACER_TRACE_FORMAT_NIM_SKIP_NIMBLE_INSTALL="${CODETRACER_TRACE_FORMAT_NIM_SKIP_NIMBLE_INSTALL:-1}"
		if [ -z "${CT_EMULATOR_EXTRA_NIM_PATHS:-}" ] && [ -d "$PWD/libs/nim-stew/stew" ]; then
			ct_nim_paths_lib="$PWD/libs/nim-stew/stew:$PWD/libs/nim-stew"
			export CT_EMULATOR_EXTRA_NIM_PATHS="$ct_nim_paths_lib"
			export CODETRACER_TRACE_FORMAT_NIM_EXTRA_PATHS="${CODETRACER_TRACE_FORMAT_NIM_EXTRA_PATHS:-$ct_nim_paths_lib}"
		fi
	fi

	runquotad_pid=""
	if [ -z "${RUNQUOTA_SOCKET:-}" ]; then
		runquotad_bin="${RUNQUOTAD_BIN:-}"
		if [ -z "$runquotad_bin" ]; then
			# Windows ships `runquotad.exe`; macOS / Linux ship a bare
			# `runquotad`. Search both filenames.
			runquotad_candidates=(
				"../runquota/build/bin/runquotad.exe"
				"../../runquota/build/bin/runquotad.exe"
				"../runquota/build/bin/runquotad"
				"../../runquota/build/bin/runquotad"
			)
			for candidate in "${runquotad_candidates[@]}"; do
				if [ -x "$candidate" ]; then
					runquotad_bin="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"
					break
				fi
			done
		fi
		if [ -z "$runquotad_bin" ]; then
			runquotad_bin="$(command -v runquotad || true)"
		fi
		if [ -z "$runquotad_bin" ]; then
			echo "Error: runquotad is required for Reprobuild builds with RunQuota." >&2
			echo "Build ../runquota or set RUNQUOTAD_BIN/RUNQUOTA_SOCKET." >&2
			exit 127
		fi

		mkdir -p .repro/runquota
		runquota_socket="${TMPDIR:-/tmp}/codetracer-reprobuild-$$.sock"
		runquota_log=".repro/runquota/runquotad.log"
		rm -f "$runquota_socket"
		"$runquotad_bin" \
			--socket "$runquota_socket" \
			--cpu-milli "${CODETRACER_RUNQUOTA_CPU_MILLI:-8000}" \
			--memory-bytes "${CODETRACER_RUNQUOTA_MEMORY_BYTES:-17179869184}" \
			--pool console=1 \
			>"$runquota_log" 2>&1 &
		runquotad_pid="$!"
		trap 'if [ -n "$runquotad_pid" ]; then kill "$runquotad_pid" 2>/dev/null || true; wait "$runquotad_pid" 2>/dev/null || true; fi' EXIT
		for _ in {1..300}; do
			if grep -q "runquotad listening" "$runquota_log" 2>/dev/null; then
				export RUNQUOTA_SOCKET="$runquota_socket"
				break
			fi
			if ! kill -0 "$runquotad_pid" 2>/dev/null; then
				echo "Error: runquotad exited before becoming ready. See $runquota_log" >&2
				exit 1
			fi
			sleep 0.05
		done
		if [ -z "${RUNQUOTA_SOCKET:-}" ]; then
			echo "Error: runquotad did not become ready. See $runquota_log" >&2
			exit 1
		fi
	fi

	# macOS-only: pick up the system SDK path so cargo's cc-rs and the
	# Nim compiler can resolve `<sys/...>` includes when invoked outside
	# the `nix develop` shell.
	if [ "$ct_reprobuild_host" = "darwin" ] && [ -z "${SDKROOT:-}" ]; then
		sdkroot="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
		if [ -n "$sdkroot" ]; then
			export SDKROOT="$sdkroot"
		fi
	fi

	# macOS / Linux Nix path: realize node_modules via the flake when the
	# tree hasn't run `yarn install` yet. Windows installs node_modules via
	# env.ps1's `Ensure-NodeTooling`, so this fallback is a no-op there.
	if { [ "$ct_reprobuild_host" = "darwin" ] || [ "$ct_reprobuild_host" = "linux" ]; } &&
		[ ! -e node_modules ] && command -v nix >/dev/null 2>&1; then
		node_modules_drv="$(nix build --no-link --print-out-paths .#node-modules-derivation 2>/dev/null || true)"
		if [ -n "$node_modules_drv" ] && [ -d "$node_modules_drv/bin/node_modules" ]; then
			ln -s "$node_modules_drv/bin/node_modules" node_modules
		fi
	fi

	if { [ "$ct_reprobuild_host" = "darwin" ] || [ "$ct_reprobuild_host" = "linux" ]; } &&
		command -v nix >/dev/null 2>&1; then
		# clingo is Reprobuild's ASP solver: repro_solver dlopen()s
		# ``libclingo.{dylib,so}`` by leaf name at runtime (see
		# ``libs/repro_solver/src/repro_solver/clingo_bindings.nim``), and
		# that dlopen also happens inside the ``extract_runner`` helper that
		# ``repro`` compiles and spawns to load the project interface. Neither
		# ``repro`` nor that helper links clingo, so the shared library must be
		# discoverable via the platform run-time loader path (``DYLD_LIBRARY_PATH``
		# on macOS, ``LD_LIBRARY_PATH`` on Linux) for both the parent and its
		# children. The same paths also feed ``LIBRARY_PATH`` so the codetracer
		# native binaries' ``-lssl/-lcrypto/-lsqlite3/-lpcre/-lzip`` link step
		# resolves outside a full ``nix develop`` shell. clingo is a
		# single-output derivation so it has no ``.out`` attribute.
		#
		# Windows provisions clingo.dll via `non-nix-build/windows/
		# ensure-clingo.ps1` (downloads the conda-forge bundle), and env.ps1
		# puts its bin dir on PATH so the Win32 loader resolves it.
		native_lib_roots="$(nix build --no-link --print-out-paths \
			nixpkgs#openssl.out nixpkgs#sqlite.out nixpkgs#pcre.out nixpkgs#libzip.out \
			nixpkgs#clingo \
			2>/dev/null || true)"
		if [ -n "$native_lib_roots" ]; then
			while IFS= read -r root; do
				if [ -d "$root/lib" ]; then
					export LIBRARY_PATH="$root/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
					if [ "$ct_reprobuild_host" = "darwin" ]; then
						export DYLD_LIBRARY_PATH="$root/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
					else
						export LD_LIBRARY_PATH="$root/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
					fi
				fi
				if [ -d "$root/include" ]; then
					export C_INCLUDE_PATH="$root/include${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
				fi
			done <<<"$native_lib_roots"
		fi
	fi

	# Default tool-provisioning differs by host: macOS uses Nix
	# (cakNix adapter pulls every `uses:` entry from /nix/store);
	# Windows uses Scoop — the reprobuild stdlib package files at
	# libs/repro_dsl_stdlib/packages/<tool>.nim carry per-tool
	# `scoopApp(bucket = "main", app = "...", preferredVersion =
	# ">=...")` entries that drive a real `scoop install bucket/app`
	# for every uses: selector that isn't already on disk.
	case "$ct_reprobuild_host" in
	darwin) ct_tool_provisioning_default="nix" ;;
	windows) ct_tool_provisioning_default="scoop" ;;
	*) ct_tool_provisioning_default="nix" ;;
	esac

	"$repro_bin" build "${CODETRACER_REPROBUILD_TARGET:-.}" \
		--tool-provisioning="${CODETRACER_REPROBUILD_TOOL_PROVISIONING:-$ct_tool_provisioning_default}" \
		--progress="${CODETRACER_REPROBUILD_PROGRESS:-bar-line}" \
		--diagnostics="${CODETRACER_REPROBUILD_DIAGNOSTICS:-.repro/build/reprobuild/build-diagnostics.log}" \
		--log="${CODETRACER_REPROBUILD_LOG:-quiet}"
	# post-build-setcap.sh re-applies BPF capabilities (cap_bpf +
	# cap_perfmon + cap_dac_read_search) to the freshly built ct binary
	# via the codetracer-setcap helper — the same post-build step the
	# legacy Tup path runs below. It is Linux-only functionality, but the
	# script self-guards (no-ops when codetracer-setcap is absent or
	# passwordless sudo is unavailable), so it is safe to call on macOS
	# too. Windows has no Linux setcap concept, so skip it there.
	if [ "$ct_reprobuild_host" = "linux" ] || [ "$ct_reprobuild_host" = "darwin" ]; then
		scripts/post-build-setcap.sh "$ct_repro_out_root/bin/ct"
	fi
	exit 0
fi

# We have to make the dist directory here, because it's missing on a fresh check out
# It will be created by the webpack command below, but we have an a chicken and egg
# problem because the Tupfiles refer to it.
mkdir -p src/public/dist

cd src
"${TUP:-tup}" build-debug
cd ..

# Build frontend_bundle.js in the dist folder
node_modules/.bin/webpack --progress

# We need to execute another tup run because webpack may have created some new files
# that tup will discover
cd src
"${TUP:-tup}" build-debug
cd ..

# Re-apply BPF capabilities on the ct binary. Tup's FUSE sandbox prevents
# sudo from running during the build, so we do this as a post-build step.
# Silently skips if codetracer-setcap is not installed.
scripts/post-build-setcap.sh src/build-debug/bin/ct
