#!/usr/bin/env bash
# generated-c-desktop.sh — the REAL Electron front-end's View › View Generated
# C Source and View › View Disassembly (Generated-Code-Listing.md §13.4):
# `src/tests/gui/tests/low-level-code/generated-c-source.spec.ts`, on
#
#   (a) a recording `ct record` makes of the example recording's program
#       (`src/db-backend/test-programs/nim/nim_flow_test.nim`) with a STOCK
#       Nim compiler, whose C carries `#line` directives:
#       `GENC_STOCK_NIM=<its nim>` (any Nim that is not CodeTracer's fork).
#       Without it that case is skipped, saying so. The committed
#       `codetracer-example-recordings/nim/flow_test` itself cannot be opened
#       by the desktop: it predates the `.ct` container every trace import
#       requires.
#   (b) a recording `ct record` makes of a Nim program (CodeTracer's Nim, the
#       C and its source maps kept in the recording's `nimcache/`). Needs the
#       fork on PATH (the dev shell's `nim`) and `ct-mcr` (`CODETRACER_CT_MCR_CMD`,
#       or the codetracer-native-recorder sibling's `ct_cli/ct_cli`).
#   (c) Edit mode on a small Nim project (the fork on PATH compiles it).
#
# The prefix is this checkout's desktop JavaScript
# (`scripts/plat45-desktop-prefix.sh`); without a DISPLAY an Xvfb is started.
# Needs `ct-native-replay` (CT_NATIVE_REPLAY_PATH, or the
# codetracer-native-backend sibling's debug build), which replays them.
#
# An `LD_PRELOAD` shim in the caller's environment (an agent harness's
# command tracer, say) is dropped: preloaded into the recorder, it makes a
# recording that does not replay.
set -euo pipefail

if [ -n "${LD_PRELOAD:-}" ]; then
	exec env -u LD_PRELOAD bash "$0" "$@"
fi

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

mkdir -p test-logs
work="$(mktemp -d "$repo/test-logs/generated-c-desktop.XXXXXX")"
trap 'rm -rf "$work"' EXIT

native_replay="${CT_NATIVE_REPLAY_PATH:-${CODETRACER_CT_NATIVE_REPLAY_CMD:-$repo/../codetracer-native-backend/target/debug/ct-native-replay}}"
if [ ! -x "$native_replay" ]; then
	echo "ct-native-replay not found at $native_replay (just ensure-ct-native-replay, or set CT_NATIVE_REPLAY_PATH)" >&2
	exit 1
fi
export CODETRACER_CT_NATIVE_REPLAY_CMD="$native_replay" CT_NATIVE_REPLAY_PATH="$native_replay"
export CODETRACER_RR_BACKEND_PRESENT=1
native_replay_dir="$(dirname "$native_replay")"
export PATH="$native_replay_dir:$PATH"

# (b): `ct record` compiles with the `nim` it finds, and records with ct-mcr.
# The sibling's existing build is used AS IS: named through a link outside the
# sibling, which the GUI fixture takes as given (`lib/sibling-provisioning.ts`
# `ensureCtMcr`) rather than rebuilding the sibling first. Set
# CODETRACER_CT_MCR_CMD yourself to choose another, or unset it and remove
# the link to have the fixture build it.
if [ -z "${CODETRACER_CT_MCR_CMD:-}" ] && [ -x "$repo/../codetracer-native-recorder/ct_cli/ct_cli" ]; then
	mkdir -p "$work/bin"
	ln -s "$(readlink -f "$repo/../codetracer-native-recorder/ct_cli/ct_cli")" "$work/bin/ct-mcr"
	export CODETRACER_CT_MCR_CMD="$work/bin/ct-mcr"
fi
if fork_nim="$(command -v nim)"; then
	export CODETRACER_NIM_EXE_PATH="${CODETRACER_NIM_EXE_PATH:-$fork_nim}"
fi

# (a): the spec records with `GENC_STOCK_NIM` itself.
export GENC_STOCK_NIM="${GENC_STOCK_NIM:-}"

# `PLAT60_DESKTOP_PREFIX` given: that prefix's desktop (another checkout's,
# for a control run of these specs against a desktop without the change).
if [ -z "${PLAT60_DESKTOP_PREFIX:-}" ]; then
	bash scripts/plat45-desktop-prefix.sh "$work/prefix" src/config/default_layout.json
	export PLAT60_DESKTOP_PREFIX="$work/prefix"
fi
export CODETRACER_ELECTRON_ARGS="${CODETRACER_ELECTRON_ARGS:---no-sandbox --no-zygote --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage}"

run_spec() {
	just test-e2e tests/low-level-code/generated-c-source.spec.ts "$@"
}

case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN* | *_NT* | Darwin)
	run_spec "$@"
	;;
*)
	if [ -n "${DISPLAY:-}" ]; then
		run_spec "$@"
	else
		display_num=99
		while [ -e "/tmp/.X${display_num}-lock" ]; do
			display_num=$((display_num + 1))
		done
		Xvfb ":${display_num}" -screen 0 2560x1440x24 -dpi 96 -nolisten tcp &
		xvfb_pid=$!
		trap 'kill $xvfb_pid 2>/dev/null || true; rm -rf "$work"' EXIT
		sleep 1
		export DISPLAY=":${display_num}"
		run_spec "$@"
	fi
	;;
esac
