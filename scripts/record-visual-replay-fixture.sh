#!/usr/bin/env bash
# record-visual-replay-fixture.sh [OUT_DIR] — the visual recording the Visual
# Replay suites on the terminal and in the GPUI window (and the desktop's
# capture) open.
#
# THE GRAPHICS are a REAL recording of the native test programs'
# `gl/gl_scene.c`: 60 frames of a 256x256 framebuffer, four solid quads per
# frame (one draw call each), every quad's colour a function of (frame,
# quadrant) — so a frame, a draw call and a pixel's history can each be checked
# against the program's own formula. It is recorded by `ct-mcr` and its gfx
# stream extracted the way the desktop extracts it before starting the player
# (`ct-mcr extract-gfx --ctfs-visual-streams`), into OUT_DIR/gfx_stream.
#
# It is ONE recording, made as the desktop's gate makes its own
# (`src/tests/gui/lib/real-visual-trace.ts`): `--interpose`, the only attach on
# Linux that captures GL. The debug server refuses that attach (it has no stage0
# boundary to replay from), so every front-end opens this recording with its
# Visual Replay panes and no debugging session, the desktop and the native hosts
# alike. Graphics capture through the in-process recorder is stage 8 of the
# premain unification (codetracer-specs
# spec/Planned-Work/premain-unification-scoping-2026-10.md); see codetracer-pm
# issue 2026-11-04-no-pinned-recorder-produces-a-replayable-gl-recording-on-linux.
#
# Needs, and FAILS naming the missing one rather than leaving a stale fixture:
#   * ct-mcr — `CODETRACER_CT_MCR_CMD`, else the sibling's
#     `codetracer-native-recorder/ct_cli/ct_cli` (`just ensure-ct-mcr`);
#   * a C compiler with EGL and GLES2 (the codetracer-visual-replay dev shell
#     provides them: `nix develop ../codetracer-visual-replay`);
#   * software GL for the recording (Mesa llvmpipe: `EGL_PLATFORM=surfaceless`,
#     set below).
#
# OUT_DIR defaults to `test-logs/tui-fixtures/visual-gl-scene`, where the
# suites look first (after `CODETRACER_VISUAL_REPLAY_FIXTURE`).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
workspace="$(dirname "$repo_root")"
out="${1:-$repo_root/test-logs/tui-fixtures/visual-gl-scene}"
programs="${NATIVE_TEST_PROGRAMS_REPO:-$workspace/codetracer-native-test-programs}"
source_file="$programs/gl/gl_scene.c"

mcr="${CODETRACER_CT_MCR_CMD:-$workspace/codetracer-native-recorder/ct_cli/ct_cli}"
if [ ! -x "$mcr" ]; then
	echo "record-visual-replay-fixture: ct-mcr not found at $mcr" >&2
	echo "  build it with \`just ensure-ct-mcr\`, or set CODETRACER_CT_MCR_CMD" >&2
	exit 1
fi
if [ ! -f "$source_file" ]; then
	echo "record-visual-replay-fixture: $source_file is missing" >&2
	echo "  check out codetracer-native-test-programs beside codetracer," >&2
	echo "  or set NATIVE_TEST_PROGRAMS_REPO" >&2
	exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/ct-visual-fixture.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# EVERY ct / ct-mcr / recording step below runs with scratch per-user state:
# the recorder writes caches (`$XDG_CACHE_HOME/codetracer/sync-families`) and
# `ct` its trace index, and neither belongs in the user's real profile.
export CODETRACER_HOME="$work/home/ct"
export XDG_CACHE_HOME="$work/home/cache" XDG_CONFIG_HOME="$work/home/config"
export XDG_DATA_HOME="$work/home/data" XDG_STATE_HOME="$work/home/state"
mkdir -p "$CODETRACER_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" \
	"$XDG_DATA_HOME" "$XDG_STATE_HOME"
if ! cc -O1 -o "$work/gl_scene" "$source_file" -lEGL -lGLESv2 -lm; then
	echo "record-visual-replay-fixture: gl_scene did not build: a C compiler" >&2
	echo "  with EGL and GLES2 is needed (\`nix develop ../codetracer-visual-replay\`)" >&2
	exit 1
fi

rm -rf "$out"
mkdir -p "$out" "$work/frames"
# Software GL for the RECORDED PROGRAM ONLY (Mesa llvmpipe, no display):
# exported in a subshell around the record step, which hands its
# environment to the program, so the extraction and everything after it run
# without them. `ct-mcr record` has no per-program environment option, and
# wrapping the program in `env` would record `env` instead.
(
	export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"
	export EGL_PLATFORM="${EGL_PLATFORM:-surfaceless}"
	export LP_NUM_THREADS="${LP_NUM_THREADS:-1}"
	exec "$mcr" record --interpose \
		--checkpoint-interval "${CT_VISUAL_FIXTURE_CHECKPOINT_MS:-250}" \
		-o "$out/trace.ct" -- "$work/gl_scene" "$work/frames/gl_scene"
)
# Writes `gfx_stream/` and, beside it, the `gfx_stream.ctfs` the player reads.
"$mcr" extract-gfx --ctfs-visual-streams -o "$out/gfx_stream" "$out/trace.ct"

for artifact in gfx_stream/gfx_commands.dat gfx_stream/gfx_bulkdata.dat \
	gfx_stream/gfx_commands.idx gfx_stream/gfx_frames.idx gfx_stream.ctfs; do
	if [ ! -f "$out/$artifact" ]; then
		echo "record-visual-replay-fixture: the extraction wrote no $artifact" >&2
		exit 1
	fi
done
echo "record-visual-replay-fixture: $out"
