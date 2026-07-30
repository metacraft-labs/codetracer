#!/usr/bin/env bash
set -euo pipefail

# CodeTracer dev build — sets up everything required for hot module
# reloading and watches sources for incremental rebuilds.
#
# Background processes started here:
#   * repro watch      — incremental rebuilds (Nim → ui.js, Stylus → .css,
#                        TypeScript, Rust, etc.) on reprobuild hosts
#   * tup monitor -a   — incremental rebuilds on legacy tup hosts
#   * webpack --watch  — frontend_bundle.js (third-party bundle)
#   * livereload       — file-tree watcher + LiveReload-protocol
#                        WebSocket server (port 35729). Watches
#                        every file the ct binary's renderer can load.

case "$(uname -s)" in
Darwin) ct_reprobuild_host="darwin" ;;
Linux)
	if [ -n "${CODETRACER_REPROBUILD_LINUX:-}" ]; then
		ct_reprobuild_host="linux"
	else
		ct_reprobuild_host=""
	fi
	;;
MINGW* | MSYS* | CYGWIN*) ct_reprobuild_host="windows" ;;
*) ct_reprobuild_host="" ;;
esac

# Generate tailwind-styles.json
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/build-tailwind.sh"

# We have to make the dist directory here, because it's missing on a fresh check out
mkdir -p src/public/dist

# Webpack continues to bundle the third-party JS deps in watch mode;
# this is unrelated to the Nim renderer's HMR but is required for
# the frontend_bundle.js asset that the renderer also loads.
node_modules/.bin/webpack --watch --progress &
webpack_pid="$!"

if [ -n "$ct_reprobuild_host" ]; then
	ct_config="${CODETRACER_CONFIG:-debug}"
	ct_repro_out_root="src/build-${ct_config}-repro"

	# LiveReload daemon — watches the reprobuild output tree
	node_modules/.bin/livereload \
		"$ct_repro_out_root" \
		--port 35729 \
		--wait 200 \
		--usepolling false &
	livereload_pid="$!"

	# Define trap to clean up webpack and livereload background processes on exit
	trap 'if [ -n "$webpack_pid" ]; then kill "$webpack_pid" 2>/dev/null || true; fi; if [ -n "$livereload_pid" ]; then kill "$livereload_pid" 2>/dev/null || true; fi' EXIT

	cat <<HMR_BANNER

==============================================================
  CodeTracer dev build starting — HMR-enabled binary ready.

  Run with:  $ct_repro_out_root/bin/ct

  HMR is on by default. Edits to anything under
  $ct_repro_out_root/ (Reprobuild outputs, Stylus-rebuilt CSS,
  vendored third-party JS/CSS, …) trigger in-place reloads.
==============================================================
HMR_BANNER

	export CODETRACER_REPROBUILD_COMMAND="watch"
	# Run build-once.sh in watch mode (foreground)
	exec bash "$SCRIPT_DIR/build-once.sh"
else
	# Legacy Tup path
	cd src
	"${TUP:-tup}" build-debug
	"${TUP:-tup}" monitor -a
	cd ../

	# LiveReload daemon — watches the tup output tree
	node_modules/.bin/livereload \
		src/build-debug \
		--port 35729 \
		--wait 200 \
		--usepolling false &
	livereload_pid="$!"

	# Define trap to clean up webpack and livereload background processes on exit
	trap 'if [ -n "$webpack_pid" ]; then kill "$webpack_pid" 2>/dev/null || true; fi; if [ -n "$livereload_pid" ]; then kill "$livereload_pid" 2>/dev/null || true; fi' EXIT

	cat <<'HMR_BANNER'

==============================================================
  CodeTracer dev build complete — HMR-enabled binary ready.

  Run with:  src/build-debug/bin/ct

  HMR is on by default. Edits to anything under
  src/build-debug/ (Tup outputs, Stylus-rebuilt CSS, vendored
  third-party JS/CSS, …) trigger in-place reloads in every
  connected ct window. To disable for a launch:
  CT_HMR=0 src/build-debug/bin/ct.
==============================================================
HMR_BANNER

	# Wait on background processes
	wait
fi
