#!/usr/bin/env bash
# Resolve the CLI override without changing its meaning when passing it to
# child tools. Browser fixtures also need the package tree beside that CLI.
js_recorder_cli() {
	printf '%s\n' "${CODETRACER_JS_RECORDER_PATH:-$1/codetracer-js-recorder/packages/cli/dist/index.js}"
}

js_recorder_root() {
	local cli
	cli="$(js_recorder_cli "$1")"
	case "$cli" in
	*/packages/cli/dist/index.js) dirname "$(dirname "$(dirname "$(dirname "$cli")")")" ;;
	*)
		echo "CODETRACER_JS_RECORDER_PATH must name the CLI file <repo>/packages/cli/dist/index.js: $cli" >&2
		return 1
		;;
	esac
}
