#!/usr/bin/env bash
# story-parity.sh -- the story-parity harness: the same declared story, drawn
# by every renderer at the same size, compared pixel by pixel with the DOM
# arm (CodeTracer's own Electron).
#
#   just story-parity [--arms dom,zgui] [--sizes 1600x1000,1100x760,1920x1080,1600x1000@2]
#                     [--stories <file>] [--out <dir>] [--check] [--update-floors]
#
# A story is `<kind>/<surface>/<fixture>[|<title>]`, one per line of the
# stories file (default tools/story-parity/stories.txt); `#` starts a comment.
# For every story and size:
#   - the DOM arm (tools/story-parity/capture-dom.mjs) draws it in Electron
#     under the app's stylesheets, through StoryBook's own `renderSurface`,
#     and writes the panes' rectangles;
#   - each other arm draws it with its own renderer: zgui through
#     `codetracer-zgui-story` (src/frontend/zgui/story_host.nim);
#   - tools/story-parity/story_diff.nim compares each arm's PNG with the DOM
#     arm's: differing pixels overall and per pane, how far off, FLIP mean.
# Everything lands in <out> (default build/story-parity): the PNGs, a heat
# map per comparison, one JSON per comparison and report.json / report.md.
#
# --check holds the result to src/tests/visual/story-parity-floors.json: for
# every arm, story and size there, the differing pixels may not exceed the
# floor. A floor only falls: --update-floors writes the new, lower counts
# (and refuses to raise one). Exit 0 when every comparison is within its
# floor, 1 otherwise, 2 when the harness itself could not run.
#
# Needs the dev shell and isonim-zgui beside this checkout. It builds the
# app's stylesheets and public resources into src/build-debug-repro itself
# (STORY_PARITY_BUILD_TREE names a tree built elsewhere instead).
# On Linux without a display it starts its own Xvfb, and zgui draws with
# Mesa's software Vulkan driver.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace="$(dirname "$repo")"
cd "$repo"

arms="dom,zgui"
sizes="1600x1000,1100x760,1920x1080,1600x1000@2"
stories="$repo/tools/story-parity/stories.txt"
out="$repo/build/story-parity"
floors="$repo/src/tests/visual/story-parity-floors.json"
check=0
update=0
while [ $# -gt 0 ]; do
	case "$1" in
	--arms)
		arms="$2"
		shift
		;;
	--sizes)
		sizes="$2"
		shift
		;;
	--stories)
		stories="$2"
		shift
		;;
	--out)
		out="$2"
		shift
		;;
	--check) check=1 ;;
	--update-floors) update=1 ;;
	*)
		echo "story-parity: unknown argument $1" >&2
		exit 2
		;;
	esac
	shift
done

die() {
	echo "story-parity: $*" >&2
	exit 2
}
build_tree="${STORY_PARITY_BUILD_TREE:-$repo/src/build-debug-repro}"
if [ -z "${STORY_PARITY_BUILD_TREE:-}" ] && [ "${STORY_PARITY_SKIP_STYLES:-0}" != 1 ]; then
	# The app's stylesheets and the public resources they reference (fonts,
	# icons), built from this checkout through repro.nim's targets, so a
	# harness run after a `.styl` edit draws the edited CSS in both arms.
	echo "==> the app's stylesheets and public resources"
	for target in frontend-styles frontend-public-resources; do
		CODETRACER_CONFIG=debug CODETRACER_REPROBUILD_COMMAND=build \
			CODETRACER_REPROBUILD_PARTIAL=1 CODETRACER_REPROBUILD_TARGET=".#$target" \
			bash scripts/build-once.sh
	done
fi
[ -f "$build_tree/frontend/styles/default_dark_theme_electron.css" ] ||
	die "$build_tree has no built styles"
mkdir -p "$out/bin" "$out/www"

# --- the tools --------------------------------------------------------------
echo "==> story_diff"
nim c --hints:off -d:release --path:"$workspace/codetracer-image-diff/src" \
	--nimcache:"$out/nimcache/story_diff" -o:"$out/bin/story_diff" \
	tools/story-parity/story_diff.nim

if [[ ",$arms," == *",dom,"* ]]; then
	echo "==> the DOM arm's static tree"
	[ -f storybook/dist/components.js ] && [ "${STORY_PARITY_REUSE_COMPONENTS:-0}" = 1 ] ||
		just build-storybook-components
	www="$out/www"
	rm -rf "$www"
	mkdir -p "$www/codetracer-storybook" "$www/libs"
	ln -s "$repo/storybook/dist/components.js" "$www/codetracer-storybook/components.js"
	ln -s "$repo/storybook/stories/lib" "$www/codetracer-storybook/lib"
	ln -s "$build_tree/frontend" "$www/frontend"
	ln -s "$build_tree/public" "$www/public"
	ln -s "$repo/libs/codetracer-design-system" "$www/libs/codetracer-design-system"
fi

if [[ ",$arms," == *",zgui,"* ]]; then
	echo "==> codetracer-zgui-story"
	zgui_rust="$workspace/isonim-zgui/rust"
	[ -f "$zgui_rust/Cargo.toml" ] || die "isonim-zgui is not checked out beside this repository"
	# The same flags `just build-zgui` builds the shim with, so a tree that
	# lane already built is reused rather than rebuilt.
	if [ -n "${CODETRACER_GPUI_RUNTIME_LIB_PATH:-}" ]; then
		export RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-Wl,-rpath,${CODETRACER_GPUI_RUNTIME_LIB_PATH}"
	fi
	(cd "$zgui_rust" && cargo build --release --locked)
	target="${CARGO_TARGET_DIR:-$zgui_rust/target}"
	shim="$target/release/libzgui_nim_shim.so"
	[ -e "$shim" ] || shim="$target/release/libzgui_nim_shim.dylib"
	nim c --hints:off --mm:orc -d:release --path:src/frontend/viewmodel \
		-d:zguiShimPath="$shim" --nimcache:"$out/nimcache/zgui-story" \
		-o:"$out/bin/codetracer-zgui-story" src/frontend/zgui/story_host.nim
	# The shim links the windowing and font libraries the dev shell's GPUI
	# runtime set provides (`just build-zgui` bakes them in as an rpath).
	shim_dir="$(dirname "$shim")"
	export LD_LIBRARY_PATH="$shim_dir${CODETRACER_GPUI_RUNTIME_LIB_PATH:+:$CODETRACER_GPUI_RUNTIME_LIB_PATH}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	if [ "$(uname -s)" = Linux ] && [ -z "${VK_ICD_FILENAMES:-}" ]; then
		IFS=: read -r -a dirs <<<"${CODETRACER_GPUI_RUNTIME_LIB_PATH:-}:/run/opengl-driver/lib"
		for d in "${dirs[@]}"; do
			icd="${d%/lib}/share/vulkan/icd.d/lvp_icd.$(uname -m).json"
			if [ -f "$icd" ]; then
				export VK_ICD_FILENAMES="$icd"
				break
			fi
		done
		export ZGUI_BACKENDS="${ZGUI_BACKENDS:-vulkan}"
	fi
fi

if [ "$(uname -s)" = Linux ] && [ -z "${DISPLAY:-}" ] && [[ ",$arms," == *",dom,"* ]]; then
	. "$repo/scripts/lib/own-xvfb.sh"
	trap 'own_xvfb_stop' EXIT
	own_xvfb_start -screen 0 4000x2400x24 -dpi 96 -nolisten tcp || die "Xvfb did not start"
fi

# --- the captures -----------------------------------------------------------
results="$out/results.jsonl"
: >"$results"
failed=0
IFS=, read -r -a size_list <<<"$sizes"
IFS=, read -r -a arm_list <<<"$arms"
while IFS= read -r line || [ -n "$line" ]; do
	line="${line%%#*}"
	line="${line%"${line##*[![:space:]]}"}"
	[ -n "$line" ] || continue
	story="${line%%|*}"
	title=""
	[[ $line == *"|"* ]] && title="${line#*|}"
	slug="$(echo "$story" | tr '/' '_')"
	for size in "${size_list[@]}"; do
		dims="${size%@*}"
		scale=1
		[[ $size == *@* ]] && scale="${size#*@}"
		w="${dims%x*}"
		h="${dims#*x}"
		dir="$out/$slug/$size"
		mkdir -p "$dir"
		echo "==> $story at $size"
		if ! node tools/story-parity/capture-dom.mjs --www "$out/www" --story "$story" \
			--title "$title" --width "$w" --height "$h" --scale "$scale" \
			--out "$dir/dom.png" --regions "$dir/regions.json" >"$dir/dom.log" 2>&1; then
			echo "   the DOM arm failed (log: $dir/dom.log)" >&2
			cat "$dir/dom.log" >&2
			failed=1
			continue
		fi
		for arm in "${arm_list[@]}"; do
			[ "$arm" = dom ] && continue
			case "$arm" in
			zgui)
				# No ZGUI_TEXT_AA override: on a display that states no subpixel
				# layout zgui now draws grayscale text by default, as Chromium does.
				"$out/bin/codetracer-zgui-story" --story="$story" --title="$title" \
					--width="$w" --height="$h" --scale="$scale" \
					--build-root="$build_tree" --out="$dir/zgui.png" >"$dir/zgui.log" 2>&1 || {
					echo "   the zgui arm failed (log: $dir/zgui.log)" >&2
					cat "$dir/zgui.log" >&2
					failed=1
					continue
				}
				;;
			*) die "no arm $arm" ;;
			esac
			"$out/bin/story_diff" "$dir/dom.png" "$dir/$arm.png" --regions="$dir/regions.json" \
				--json="$dir/$arm.diff.json" --heat="$dir/$arm.heat.png" | sed 's/^/   /' || true
			node -e '
				const [file, arm, story, size] = process.argv.slice(1);
				const d = JSON.parse(require("fs").readFileSync(file, "utf8"));
				console.log(JSON.stringify({ arm, story, size, ...d }));
			' "$dir/$arm.diff.json" "$arm" "$story" "$size" >>"$results"
		done
	done
done <"$stories"

# --- the report and the floors ---------------------------------------------
report_flags=()
[ "$check" = 1 ] && report_flags+=(--check)
[ "$update" = 1 ] && report_flags+=(--update)
node "$repo/tools/story-parity/report.mjs" --results "$results" --out "$out" \
	--floors "$floors" "${report_flags[@]}" || failed=1
exit "$failed"
