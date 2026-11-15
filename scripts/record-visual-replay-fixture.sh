#!/usr/bin/env bash
# record-visual-replay-fixture.sh [OUT_DIR] — RE-RECORDS the visual recording
# the Visual Replay suites on the terminal and in the GPUI window (and the
# desktop's capture) open. The suites do not run this: they open the recording
# committed in codetracer-example-recordings
# (`examples/recordings/mcr/linux-x86_64/visual-gl-scene`, pinned by this
# checkout's gitlink), the same on every host and in CI. Run it to replace that
# recording, commit the result there, move the gitlink, and re-capture the
# answers made from it (`just plat59-capture-electron`).
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
# OUT_DIR defaults to the committed location in the submodule's checkout.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
workspace="$(dirname "$repo_root")"
out="${1:-$repo_root/examples/recordings/mcr/linux-x86_64/visual-gl-scene}"
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
export CODETRACER_HOME="$work/scratch/ct"
export XDG_CACHE_HOME="$work/scratch/cache" XDG_CONFIG_HOME="$work/scratch/config"
export XDG_DATA_HOME="$work/scratch/data" XDG_STATE_HOME="$work/scratch/state"
mkdir -p "$CODETRACER_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" \
	"$XDG_DATA_HOME" "$XDG_STATE_HOME"
if ! cc -O1 -o "$work/gl_scene" "$source_file" -lEGL -lGLESv2 -lm; then
	echo "record-visual-replay-fixture: gl_scene did not build: a C compiler" >&2
	echo "  with EGL and GLES2 is needed (\`nix develop ../codetracer-visual-replay\`)" >&2
	exit 1
fi

rm -rf "$out"
mkdir -p "$out" "$work/frames"
# THE RECORDED PROGRAM GETS A SCRUBBED ENVIRONMENT. A recording captures the
# environment of the process it records, and this one is committed (the
# fixture is pinned by codetracer through the `examples/recordings`
# submodule), so it must carry nothing of the shell that made it: no tokens,
# no home directory, nothing that differs between hosts. `env -i` starts
# ct-mcr, which hands its environment to the program, from only what is
# listed here. `ct-mcr record` has no per-program environment option, and
# wrapping the program in `env` would record `env` instead.
#
# Software GL (Mesa llvmpipe, no display): `LIBGL_ALWAYS_SOFTWARE`,
# `EGL_PLATFORM=surfaceless`, one llvmpipe thread, and Mesa's libglvnd
# vendor file, not whichever EGL vendor libglvnd tries first: on a host with
# an NVIDIA driver, NVIDIA's vendor library is first and cannot initialise a
# surfaceless display under the recorder (eglInitialize EGL_NOT_INITIALIZED,
# measured with codetracer-native-recorder 63dd179), so the program exits 1
# and the recording has no graphics. The dev shell names its own Mesa's
# (`CODETRACER_MESA_EGL_VENDOR`), which matches the Mesa on its library path.
vendor="${__EGL_VENDOR_LIBRARY_FILENAMES:-${CODETRACER_MESA_EGL_VENDOR:-}}"
if [ -z "$vendor" ]; then
	for candidate in /run/opengl-driver/share/glvnd/egl_vendor.d/50_mesa.json \
		/usr/share/glvnd/egl_vendor.d/50_mesa.json; do
		if [ -f "$candidate" ]; then
			vendor="$candidate"
			break
		fi
	done
fi
mkdir -p "$work/scratch/tmp"
recording_env=(
	HOME="$work/scratch"
	PATH="$(dirname "$mcr"):/usr/bin:/bin"
	TMPDIR="$work/scratch/tmp"
	CODETRACER_HOME="$CODETRACER_HOME"
	XDG_CACHE_HOME="$XDG_CACHE_HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME"
	XDG_DATA_HOME="$XDG_DATA_HOME" XDG_STATE_HOME="$XDG_STATE_HOME"
	LIBGL_ALWAYS_SOFTWARE=1 EGL_PLATFORM=surfaceless LP_NUM_THREADS=1
)
if [ -n "$vendor" ]; then
	recording_env+=(__EGL_VENDOR_LIBRARY_FILENAMES="$vendor")
fi
# The dev shell's library path (Mesa, libglvnd), which the vendor file's
# libEGL_mesa resolves through; any entry under the home directory is left
# out, so no account name is recorded.
if [ -n "${LD_LIBRARY_PATH:-}" ]; then
	library_path=""
	IFS=: read -r -a library_dirs <<<"$LD_LIBRARY_PATH"
	for dir in "${library_dirs[@]}"; do
		case "$dir" in "" | "$HOME" | "$HOME"/*) continue ;; esac
		library_path="${library_path:+$library_path:}$dir"
	done
	if [ -n "$library_path" ]; then
		recording_env+=(LD_LIBRARY_PATH="$library_path")
	fi
fi
# ct-mcr in turn keeps only an allowlisted environment for the program
# (codetracer-native-recorder 0da6c8eb7); the graphics variables are named
# here so a recorder whose allowlist lacks them still passes them on.
keep_env=()
for name in LIBGL_ALWAYS_SOFTWARE EGL_PLATFORM LP_NUM_THREADS \
	__EGL_VENDOR_LIBRARY_FILENAMES; do
	keep_env+=(--keep-env "$name")
done
env -i "${recording_env[@]}" "$mcr" record --interpose "${keep_env[@]}" \
	--checkpoint-interval "${CT_VISUAL_FIXTURE_CHECKPOINT_MS:-250}" \
	-o "$out/trace.ct" -- "$work/gl_scene" "$work/frames/gl_scene"
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
