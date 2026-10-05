#!/usr/bin/env bash
# plat45-capture-electron.sh — PLAT-45: capture the arrangement the REAL
# Electron front-end opens the `calc` recording with, on its FIRST-RUN path, for
# two prefixes:
#
#   generated — `config/default_layout.json` is the committed, GENERATED file
#               (checked fresh first): the desktop's default as shipped;
#   scratch   — `config/default_layout.json` comes from a SCRATCH BUILD of the
#               generator in which `sharedDefaultLayout()` has one edit (the
#               right column's two stacks swapped), so the desktop's default
#               is shown to follow the shared tree rather than a file.
#
# Each prefix is the built variant's own tree (symlinked) with THIS checkout's
# desktop JavaScript and a `config/` of its own (`scripts/plat45-desktop-prefix.sh`);
# `CODETRACER_PREFIX` points the launched `ct` at it. The Playwright
# spec `tests/visual/plat45-default-arrangement-capture.spec.ts` writes
# `src/tests/visual/answers/plat45-default-arrangement.electron.json`, which
# `src/frontend/tui/tests/test_plat45_three_media.nim` reads.
#
# Needs: a built frontend (`just build-once`), the Python recorder (the dev
# shell's interpreter carries it; the specs record `test-programs/calc`
# themselves) and Xvfb, which it starts when no display is set. Run through
# `just plat45-capture-electron`; CI runs it in the `viewmodel-tests` job.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

# INSIDE THE CHECKOUT, not under /tmp: the prefix carries real (not symlinked)
# `index.js` / `ui.js`, and Node resolves their `require`s by walking up from
# where the FILE is — so a prefix outside the checkout finds no `node_modules`
# and the window comes up blank. `test-logs/` is ignored by git.
mkdir -p test-logs
work="$(mktemp -d "$repo/test-logs/plat45-capture.XXXXXX")"
trap 'rm -rf "$work"' EXIT

echo "== the committed default is what the shared tree generates"
bash ci/test/default-layout-fresh.sh

echo "== a prefix running THIS checkout's desktop JavaScript and its generated default"
bash scripts/plat45-desktop-prefix.sh "$work/generated" src/config/default_layout.json

echo "== a scratch build of the generator, with the shared tree edited"
scratch_src="$work/scratch-src/src/frontend"
mkdir -p "$scratch_src"
cp -r src/frontend/headless_app "$scratch_src/"
ln -s "$repo/src/frontend/index" "$scratch_src/index"
ln -s "$repo/src/common" "$work/scratch-src/src/common"
ln -s "$repo/src/config" "$work/scratch-src/src/config"
python3 - "$scratch_src/headless_app/layout_model.nim" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
# PLAT-47: the edit is to the BUNDLED tree the desktop derives every mode's
# default from, in a region the Debug-mode default keeps (the right column the
# PLAT-45 version swapped is re-homed away in Debug mode): the state and
# call-trace stacks change places.
old = """        stack([pane(paneState), pane(paneScratchpad)], weight = 50.0),
        stack([pane(paneCalltrace), pane(paneAgentActivity)], weight = 50.0)],"""
new = """        stack([pane(paneCalltrace), pane(paneAgentActivity)], weight = 50.0),
        stack([pane(paneState), pane(paneScratchpad)], weight = 50.0)],"""
if s.count(old) != 1:
    sys.exit("the scratch edit's anchor is not in sharedBundledLayout() exactly once")
open(p, "w").write(s.replace(old, new))
PY
# A node program (PLAT-47): the generator runs the desktop's own per-mode
# derivation, and writes both generated files under a scratch root.
mkdir -p "$work/scratch-root/src/config" "$work/scratch-root/src/frontend/headless_app"
nim js -d:nodejs --hints:off --warnings:off --nimcache:"$work/nimcache" \
	-o:"$work/generate_scratch.js" \
	"$scratch_src/headless_app/generate_default_layout.nim" >"$work/build.log" 2>&1 || {
	cat "$work/build.log" >&2
	exit 1
}
node "$work/generate_scratch.js" --out="$work/scratch-root"
cp "$work/scratch-root/src/config/default_layout.json" "$work/scratch-default_layout.json"
if cmp -s "$work/scratch-default_layout.json" src/config/default_layout.json; then
	echo "FAIL: the scratch edit did not change the generated default" >&2
	exit 1
fi
# The same prefix, with the scratch build's default in its `config/`.
cp -a "$work/generated" "$work/scratch"
cp "$work/scratch-default_layout.json" "$work/scratch/config/default_layout.json"

export PLAT45_PREFIX_GENERATED="$work/generated"
export PLAT45_DESKTOP_PREFIX="$work/generated"
export PLAT45_PREFIX_SCRATCH="$work/scratch"
export CODETRACER_ELECTRON_ARGS="${CODETRACER_ELECTRON_ARGS:---no-sandbox --no-zygote --disable-gpu --disable-gpu-compositing --disable-dev-shm-usage}"

run_spec() {
	just test-e2e tests/visual/plat45-default-arrangement-capture.spec.ts \
		tests/layout/plat45-desktop-remembers-own.spec.ts "$@"
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
