#!/usr/bin/env bash
# ci/test/scenario-lane-provision.sh <beam|rr|ruby|instrument|hcr|recorders>... —
# what the scenario lanes' BEAM, rr, Ruby, cross-process, HCR and blockchain
# scenarios record and replay with,
# provisioned for a leg of the scenario-lanes job
# (.github/workflows/scenario-lanes.yml). Each piece is built in its own
# repository's dev shell, from the siblings the job cloned at their pins;
# scripts/detect-siblings.sh (codetracer's shellHook) then finds them. Run from
# the codetracer checkout. What the job does not build here: `ct` and
# replay-server (build-once's src/build-debug-repro, restored from the
# ct-build job, where the stages and the Playwright binding look first), and
# ct-native-replay, ct_gfx_player and ct-mcr (restored from the
# visual-replay-tools job, or built by ci/test/visual-replay-tools.sh).
#
#   beam    the BEAM recorder in its target/debug, with elixir and erl from
#           ITS dev shell appended to $GITHUB_PATH (codetracer's dev shell
#           has neither). The gl_scene visual recording is not made here: it
#           is committed, in the examples/recordings submodule the checkout
#           brings, and this only checks that it is there.
#   rr      rr, gdb and dlv, which ct-native-replay runs for an rr recording
#           (it looks for rr beside itself, then on PATH): from
#           codetracer-native-backend's dev shell, as ci/setup-rr-backend.sh
#           takes them, their directories appended to $GITHUB_PATH. Without
#           them every rr recording ended "Os { code: 2, kind: NotFound }"
#           (run 45822112077).
#   ruby    the Ruby recorder's native extension (`just build-extension` in
#           its shell), which scripts/detect-siblings.sh then finds.
#   instrument  ct-instrument (`cargo build --release -p ct-instrument-cli` in
#           codetracer-wasm-instrumenter), which scripts/materialize-recording.sh
#           needs for the cross-process recording.
#   hcr     what the hcr-flame stage opens: ../codetracer-flame-demo with
#           its patchable GDExtension and imported project, the coordinator
#           driver at its artifacts/h3-driver/hcr_patch_driver (built from
#           ../reprobuild), and a patchable Godot under
#           ../codetracer-engine-godot/bin (metacraft-labs/codetracer-godot,
#           branch codetracer, at HCR_ENGINE_REV; the workflow caches the
#           binary, and it is built only when absent: an 18-minute scons
#           build at -j8).
#   recorders  the Solana, PolkaVM and EVM recorders the lane's Solana,
#           PolkaVM and Solidity scenarios record with (only those named in
#           $SCENARIO_LANE_RECORDERS, comma-separated, when it is set: the ones
#           ci/test/scenario-lane-needs.sh finds in the leg's shard), cloned at the test
#           lock's pins (ci/test/siblings/repro.lock, the job's test-siblings)
#           and built each in its own dev shell with its own `just build` (a
#           debug `cargo build`). Not through build-recorder-siblings.sh: that
#           enters the recorders' shells by direnv and runs their `just
#           prepare-ci` first, whose check that the Nim sibling is at the
#           recorder's declared revision belongs to the recorder's own CI and
#           failed here (run 45576175587: "Nim checkout differs from owning
#           declared revision"); the lane needs only the binary. `ct record`
#           finds a recorder on PATH or through its
#           CODETRACER_<NAME>_RECORDER_PATH (src/common/paths.nim); the
#           variables are appended to $GITHUB_ENV for the lane's step. The
#           lane's cargo-build-sbf, solc and anvil come from codetracer's dev
#           shell, which the lane step runs in.
set -euo pipefail
ws="$(cd .. && pwd)"

beam() {
	# shellcheck disable=SC2016 # expanded by the inner bash, in the recorder's shell
	(cd "$ws/codetracer-beam-recorder" && nix develop --no-write-lock-file --command bash -c '
		set -euo pipefail
		cargo build --locked
		(cd rebar3_codetracer && rebar3 compile)
		dirname "$(command -v elixir)" >>"$GITHUB_PATH"
		dirname "$(command -v erl)" >>"$GITHUB_PATH"')
	test -f examples/recordings/mcr/linux-x86_64/visual-gl-scene/gfx_stream/gfx_frames.idx
}

provide_rr() {
	local dirs
	# shellcheck disable=SC2016 # expanded by the inner bash, in the backend's shell
	dirs="$(nix develop "$ws/codetracer-native-backend" --no-write-lock-file --command bash -c '
		for tool in rr gdb dlv; do
			p="$(command -v "$tool" || true)"
			[ -z "$p" ] || dirname "$p"
		done' | sort -u)"
	[ -n "$dirs" ] || {
		echo "scenario-lane-provision: codetracer-native-backend's dev shell has no rr" >&2
		exit 1
	}
	printf '%s\n' "$dirs" >>"${GITHUB_PATH:-/dev/stdout}"
	# shellcheck disable=SC2086 # one directory per line, no spaces
	PATH="$(printf '%s:' $dirs)$PATH" type -P rr
}

provide_ruby() {
	local ext
	# shellcheck disable=SC2016 # expanded by the inner bash, in the recorder's shell
	nix develop "$ws/codetracer-ruby-recorder" --no-write-lock-file --command bash -c 'cd "$1" && just build-extension' build "$ws/codetracer-ruby-recorder"
	ext="$(find "$ws/codetracer-ruby-recorder/gems/codetracer-ruby-recorder/ext/native_tracer/target/release" \
		-maxdepth 1 -name '*codetracer_ruby_recorder*.so' 2>/dev/null | head -n 1)"
	[ -n "$ext" ] || {
		echo "scenario-lane-provision: just build-extension made no Ruby extension" >&2
		exit 1
	}
	echo "ruby recorder extension: $ext"
}

provide_instrument() {
	# shellcheck disable=SC2016 # expanded by the inner bash, in the instrumenter's shell
	env -u CARGO_TARGET_DIR CARGO_NET_GIT_FETCH_WITH_CLI=true \
		nix develop "$ws/codetracer-wasm-instrumenter" --no-write-lock-file --command bash -c 'cd "$1" && cargo build --release -p ct-instrument-cli' build "$ws/codetracer-wasm-instrumenter"
	test -x "$ws/codetracer-wasm-instrumenter/target/release/ct-instrument"
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
	# Inside the engine's dev shell: the script enters it for scons, but then
	# runs its patchable-shape check with a bare `python3`, which a NixOS
	# runner does not have ("python3: command not found" after a 19-minute
	# build, which also kept the binary out of the cache).
	if [ ! -x "$bin" ]; then
		(cd "$engine" && JOBS=8 VULKAN=yes EXTRA_SUFFIX=hcrgpu REPROBUILD_DIR="$ws/reprobuild" \
			nix develop --no-write-lock-file --command scripts/build-hcr-patchable-linux.sh)
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

recorders() {
	local repos=() name repo bin
	IFS=, read -r -a names <<<"${SCENARIO_LANE_RECORDERS-solana,polkavm,evm}"
	for name in "${names[@]}"; do
		[ -n "$name" ] && repos+=("codetracer-$name-recorder")
	done
	[ "${#repos[@]}" -gt 0 ] || echo "scenario-lane-provision: no blockchain recorder for this shard"
	for repo in "${repos[@]}"; do
		echo "=== $repo"
		# CARGO_TARGET_DIR cleared, so the binary lands in the repo's target/.
		# The shell is entered by its flake's path from here, not from the
		# recorder's root: a recorder's shellHook installs its git hooks when
		# entered from its root, and the EVM recorder's installer refuses the
		# runner git's own pre-push.sample and with it the shell ("hook
		# installer failed; refusing to enter the dev shell", run 45822112077).
		# A CI build needs no git hooks. Every recorder's `just build` is a plain
		# `cargo build`; the Flow recorder's shell has no `just` (exit 127, run
		# 45959049981), so cargo is run directly there.
		# shellcheck disable=SC2016 # expanded by the inner bash, in the recorder's shell
		env -u CARGO_TARGET_DIR CARGO_NET_GIT_FETCH_WITH_CLI=true \
			nix develop "$ws/$repo" --no-write-lock-file --command bash -c 'cd "$1" && if command -v just >/dev/null; then just build; else cargo build --locked; fi' build "$ws/$repo"
		bin="$ws/$repo/target/debug/$repo"
		test -x "$bin"
		name="${repo#codetracer-}"
		name="${name%-recorder}"
		echo "CODETRACER_${name^^}_RECORDER_PATH=$bin" >>"${GITHUB_ENV:-/dev/stdout}"
	done
}

[ "$#" -gt 0 ] || set -- ""
for mode in "$@"; do
	case "$mode" in
	beam | hcr | recorders) "$mode" ;;
	rr | ruby | instrument) "provide_$mode" ;;
	*)
		sed -n '2,55p' "$0" >&2
		exit 64
		;;
	esac
done
