#!/usr/bin/env bash
# ci/test/scenario-lane-provision.sh <native|hcr> — what the desktop scenario
# lane's native, BEAM, visual-replay and HCR scenarios record and replay with,
# provisioned for the test-ui-tests nixos leg (.github/workflows/codetracer.yml).
# Each piece is built in its own repository's dev shell, from the siblings the
# job cloned at their pins; scripts/detect-siblings.sh (codetracer's
# shellHook) then finds them. Run from the codetracer checkout.
#
#   native  ct-native-replay and rr in codetracer-native-backend's
#           target/debug (`just ensure-ct-native-replay`); the BEAM recorder
#           in its target/debug, with elixir and erl from ITS dev shell
#           appended to $GITHUB_PATH (codetracer's dev shell has neither);
#           the gl_scene visual recording at
#           test-logs/tui-fixtures/visual-gl-scene, made by ct-mcr in
#           codetracer-visual-replay's shell (EGL/GLES2, Mesa). ct-mcr,
#           ct_gfx_player and the JS recorder are built by earlier steps.
#   hcr     what the hcr-flame stage opens: ../codetracer-flame-demo with
#           its patchable GDExtension and imported project, the coordinator
#           driver at its artifacts/h3-driver/hcr_patch_driver (built from
#           ../reprobuild), and a patchable Godot under
#           ../codetracer-engine-godot/bin (metacraft-labs/codetracer-godot,
#           branch codetracer, at HCR_ENGINE_REV; the workflow caches the
#           binary, and it is built only when absent: an 18-minute scons
#           build at -j8).
set -euo pipefail
ws="$(cd .. && pwd)"

native() {
	nix develop .#devShells.x86_64-linux.default --command just ensure-ct-native-replay
	test -x "$ws/codetracer-native-backend/target/debug/ct-native-replay"
	# shellcheck disable=SC2016 # expanded by the inner bash, in the recorder's shell
	(cd "$ws/codetracer-beam-recorder" && nix develop --no-write-lock-file --command bash -c '
		set -euo pipefail
		cargo build --locked
		(cd rebar3_codetracer && rebar3 compile)
		dirname "$(command -v elixir)" >>"$GITHUB_PATH"
		dirname "$(command -v erl)" >>"$GITHUB_PATH"')
	nix develop "$ws/codetracer-visual-replay" --no-write-lock-file --command \
		bash scripts/record-visual-replay-fixture.sh
	test -f test-logs/tui-fixtures/visual-gl-scene/gfx_stream/gfx_frames.idx
}

hcr() {
	local rev="${HCR_ENGINE_REV:?the codetracer-godot revision}"
	local engine="$ws/codetracer-engine-godot"
	local bin="$engine/bin/godot.linuxbsd.template_debug.x86_64.hcrgpu"
	if [ "$(git -C "$engine" rev-parse HEAD 2>/dev/null || true)" != "$rev" ]; then
		mkdir -p "$engine"
		git -C "$engine" init -q
		git -C "$engine" fetch -q --depth 1 https://github.com/metacraft-labs/codetracer-godot "$rev"
		git -C "$engine" checkout -q --force FETCH_HEAD
	fi
	(cd "$ws/reprobuild" && nix develop --no-write-lock-file --command bash -c '
		set -euo pipefail
		nim c -d:release --hints:off --warnings:off --outdir:../codetracer-flame-demo/artifacts/h3-driver scripts/hcr_patch_driver.nim
		nim c -d:release --hints:off --warnings:off --outdir:build/bin scripts/hcr_patchable_profile.nim')
	if [ ! -x "$bin" ]; then
		(cd "$engine" && JOBS=8 VULKAN=yes EXTRA_SUFFIX=hcrgpu REPROBUILD_DIR="$ws/reprobuild" \
			scripts/build-hcr-patchable-linux.sh)
	fi
	# shellcheck disable=SC2016 # expanded by the inner bash, in the flame demo's shell
	(cd "$ws/codetracer-flame-demo" && git submodule update --init --depth 1 third_party/godot-cpp &&
		nix develop --no-write-lock-file --command bash -c '
			set -euo pipefail
			cmake -S gdextension -B gdextension/build-hcr -DCMAKE_BUILD_TYPE=RelWithDebInfo \
				-DGODOTCPP_TARGET=template_debug -DGODOTCPP_BUILD_PROFILE="$PWD/gdextension/build_profile.json" \
				-DFLAME_HCR_PATCHABLE=ON -DFLAME_HCR_PROFILE_TOOL="$PWD/../reprobuild/build/bin/hcr_patchable_profile"
			cmake --build gdextension/build-hcr -j 8
			just import')
	test -x "$bin"
	test -x "$ws/codetracer-flame-demo/artifacts/h3-driver/hcr_patch_driver"
	test -f "$ws/codetracer-flame-demo/bin/libflamefield.macos.template_debug.so"
	test -d "$ws/codetracer-flame-demo/.godot"
}

case "${1:-}" in
native | hcr) "$1" ;;
*)
	sed -n '2,22p' "$0" >&2
	exit 64
	;;
esac
