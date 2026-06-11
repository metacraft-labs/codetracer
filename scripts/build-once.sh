#!/usr/bin/env bash
set -euo pipefail

# Generate isonim's build/tailwind-styles.json before any frontend Nim
# compile. ``src/frontend/ui_js.nim`` transitively imports
# ``isonim/dsl/tailwind``, which ``staticRead``s that file at Nim compile
# time — a missing file is an uncatchable compile error
# (see isonim/src/isonim/dsl/tailwind.nim), so the ``frontend-ui-js``
# build action fails without it. Regenerate it each run (cheap) from the
# isonim sibling using its own ``build-tailwind`` recipe.
isonim_root=""
for candidate in ../isonim ../../isonim; do
	if [ -f "$candidate/tools/tailwind-extract.mjs" ]; then
		isonim_root="$(cd "$candidate" && pwd)"
		break
	fi
done
if [ -n "$isonim_root" ]; then
	if command -v just >/dev/null 2>&1; then
		(cd "$isonim_root" && just build-tailwind) || true
	else
		(cd "$isonim_root" &&
			{ [ -d node_modules ] || yarn install --frozen-lockfile; } &&
			node tools/tailwind-extract.mjs) || true
	fi
fi

# Reprobuild branch: macOS (Darwin) uses Nix tool provisioning; Windows
# (MINGW* / MSYS* via Git Bash) uses PATH provisioning since the codetracer
# DIY toolchain bootstrap (`. env.ps1`) has already populated PATH with
# every tool the codetracer `uses:` clause references on its Windows
# branch. On both, the codetracer recipe lives in `reprobuild.nim` and is
# built end-to-end via the local `repro` binary.
case "$(uname -s)" in
	Darwin) ct_reprobuild_host="darwin" ;;
	MINGW*|MSYS*|CYGWIN*) ct_reprobuild_host="windows" ;;
	*) ct_reprobuild_host="" ;;
esac

if [ -n "$ct_reprobuild_host" ]; then
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
	if [ "$ct_reprobuild_host" = "darwin" ] && [ ! -e node_modules ] &&
		command -v nix >/dev/null 2>&1; then
		node_modules_drv="$(nix build --no-link --print-out-paths .#node-modules-derivation 2>/dev/null || true)"
		if [ -n "$node_modules_drv" ] && [ -d "$node_modules_drv/bin/node_modules" ]; then
			ln -s "$node_modules_drv/bin/node_modules" node_modules
		fi
	fi

	if [ "$ct_reprobuild_host" = "darwin" ] && command -v nix >/dev/null 2>&1; then
		# clingo is Reprobuild's ASP solver: repro_solver dlopen()s
		# ``libclingo.dylib`` by leaf name at runtime (see
		# ``libs/repro_solver/src/repro_solver/clingo_bindings.nim``), and
		# that dlopen also happens inside the ``extract_runner`` helper that
		# ``repro`` compiles and spawns to load the project interface. Neither
		# ``repro`` nor that helper links clingo, so the shared library must be
		# discoverable via ``DYLD_LIBRARY_PATH`` for both the parent and its
		# children. Provision it alongside the other native libs below; clingo
		# is a single-output derivation so it has no ``.out`` attribute.
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
					export DYLD_LIBRARY_PATH="$root/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
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
	# post-build-setcap.sh is Linux-only (BPF capabilities via setcap);
	# on macOS the script no-ops, on Windows there's no Linux setcap
	# concept so skip it entirely.
	if [ "$ct_reprobuild_host" = "darwin" ]; then
		scripts/post-build-setcap.sh src/build-debug/bin/ct
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
