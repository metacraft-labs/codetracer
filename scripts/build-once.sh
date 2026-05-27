#!/usr/bin/env bash
set -euo pipefail

if [ "$(uname -s)" = "Darwin" ]; then
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

	if [ -z "$repro_bin" ] && [ -n "$reprobuild_root" ] &&
		[ -x "$reprobuild_root/build/bin/repro" ]; then
		repro_bin="$reprobuild_root/build/bin/repro"
	fi

	if [ -z "$repro_bin" ]; then
		echo "Error: repro is required for macOS builds." >&2
		echo "Set REPROBUILD_BIN or CODETRACER_REPROBUILD_REPO_PATH, or put repro on PATH." >&2
		exit 127
	fi

	if [ -n "$reprobuild_root" ]; then
		export REPROBUILD_SOURCE_ROOT="$reprobuild_root"
		export CODETRACER_REPROBUILD_REPO_PATH="${CODETRACER_REPROBUILD_REPO_PATH:-$reprobuild_root}"
	fi

	runquotad_pid=""
	if [ -z "${RUNQUOTA_SOCKET:-}" ]; then
		runquotad_bin="${RUNQUOTAD_BIN:-}"
		if [ -z "$runquotad_bin" ]; then
			for candidate in ../runquota/build/bin/runquotad ../../runquota/build/bin/runquotad; do
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

	if [ -z "${SDKROOT:-}" ]; then
		sdkroot="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
		if [ -n "$sdkroot" ]; then
			export SDKROOT="$sdkroot"
		fi
	fi

	if [ ! -e node_modules ] && command -v nix >/dev/null 2>&1; then
		node_modules_drv="$(nix build --no-link --print-out-paths .#node-modules-derivation 2>/dev/null || true)"
		if [ -n "$node_modules_drv" ] && [ -d "$node_modules_drv/bin/node_modules" ]; then
			ln -s "$node_modules_drv/bin/node_modules" node_modules
		fi
	fi

	if command -v nix >/dev/null 2>&1; then
		native_lib_roots="$(nix build --no-link --print-out-paths \
			nixpkgs#openssl.out nixpkgs#sqlite.out nixpkgs#pcre.out nixpkgs#libzip.out \
			2>/dev/null || true)"
		if [ -n "$native_lib_roots" ]; then
			while IFS= read -r root; do
				if [ -d "$root/lib" ]; then
					export LIBRARY_PATH="$root/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
					export DYLD_LIBRARY_PATH="$root/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
				fi
				if [ -d "$root/include" ]; then
					export C_INCLUDE_PATH="$root/include${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
				fi
			done <<<"$native_lib_roots"
		fi
	fi

	"$repro_bin" build "${CODETRACER_REPROBUILD_TARGET:-.}" \
		--tool-provisioning="${CODETRACER_REPROBUILD_TOOL_PROVISIONING:-nix}" \
		--progress="${CODETRACER_REPROBUILD_PROGRESS:-bar-line}" \
		--diagnostics="${CODETRACER_REPROBUILD_DIAGNOSTICS:-.repro/build/reprobuild/build-diagnostics.log}" \
		--log="${CODETRACER_REPROBUILD_LOG:-quiet}"
	scripts/post-build-setcap.sh src/build-debug/bin/ct
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
