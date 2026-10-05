#!/usr/bin/env bash
# plat45-desktop-prefix.sh <dir> [<default_layout.json>] — PLAT-45: assemble a
# CodeTracer PREFIX in <dir> that runs THIS checkout's desktop JavaScript.
#
# The Electron capture and the desktop remember/reset spec launch the real app
# with `CODETRACER_PREFIX=<dir>`. Everything the built variant carries is
# symlinked in unchanged, except:
#
#   * `index.js` / `src/index.js` (the main process) and `ui.js` /
#     `public/ui.js` (the renderer), compiled here from this checkout with the
#     flags `src/Tuprules.tup`'s `!nim_node_index` and `!nim_js` rules use —
#     so a desktop change (View > Reset Layout) is what runs, and the
#     `staticRead` copy of the default inside them is this checkout's;
#   * `bin/ct`, copied rather than linked (see below), so the `ct` the specs
#     launch starts THIS prefix's `src/index.js`;
#   * `config/`, holding `default_config.yaml` and the default layout given as
#     the second argument (the committed, generated one by default).
#
# Needs a built variant (`just build-once`) for everything else. <dir> must be
# INSIDE the checkout: the compiled `index.js` / `ui.js` are real files, and
# Node resolves their `require`s by walking up from where the file is.
set -euo pipefail

out="${1:?usage: plat45-desktop-prefix.sh <dir> [<default_layout.json>]}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
layout="${2:-$repo/src/config/default_layout.json}"

ct_bin="$(readlink -f "$repo/src/build-debug/bin/ct")"
base="$(dirname "$(dirname "$ct_bin")")"
[ -x "$ct_bin" ] || {
	echo "FAIL: no built ct — run 'just build-once'" >&2
	exit 1
}

# A linked worktree has empty submodule directories; the libraries are the
# main checkout's.
libs_root="$repo"
if [ ! -e "$repo/libs/nim-chronicles/chronicles.nim" ]; then
	common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)"
	libs_root="$(dirname "$common")"
fi

flags="$(
	python3 - "$repo" "$libs_root" <<'PY'
import re, sys
repo, libs_root = sys.argv[1], sys.argv[2]
text = open(repo + "/src/Tuprules.tup").read()
def var(name):
    m = re.search(r"^" + name + r"\s*=\s*\\?\n?((?:.*\\\n)*.*)$", text, re.M)
    out = []
    for line in m.group(1).split("\n"):
        line = line.strip().rstrip("\\").strip()
        out.extend(line.split())
    return out
flags = var("NIM_COMMON_FLAGS") + var("NIM_REPO_PATH_FLAGS")
flags += [f for f in var("NIM_DEBUG_FLAGS") if not f.startswith("$(")]
flags = [f.replace("$(ROOT)/libs", libs_root + "/libs").replace("$(ROOT)", repo)
         for f in flags]
print(" ".join(flags))
PY
)"

work="$out.build"
mkdir -p "$out" "$work"
# shellcheck disable=SC2086
nim $flags -d:ctIndex -d:nodejs --sourcemap:on --nimcache:"$work/nc-index" \
	--out:"$work/index.js" js "$repo/src/frontend/index.nim" >"$work/index.log" 2>&1 ||
	{
		tail -20 "$work/index.log" >&2
		exit 1
	}
# shellcheck disable=SC2086
nim $flags -d:chronicles_enabled=off -d:ctRenderer -d:ctHmr -d:isonimHmr \
	--debugInfo:on --lineDir:on --hints:off --warnings:off \
	--nimcache:"$work/nc-ui" --out:"$work/ui.js" js "$repo/src/frontend/ui_js.nim" \
	>"$work/ui.log" 2>&1 || {
	tail -20 "$work/ui.log" >&2
	exit 1
}

mirror() { # mirror <src-dir> <dst-dir> <name-to-skip>...
	local src="$1" dst="$2"
	shift 2
	mkdir -p "$dst"
	for entry in "$src"/* "$src"/.cargo; do
		[ -e "$entry" ] || continue
		local name skip=0
		name="$(basename "$entry")"
		for s in "$@"; do [ "$name" = "$s" ] && skip=1; done
		[ "$skip" = 1 ] || ln -sfn "$(readlink -f "$entry")" "$dst/$name"
	done
}
mirror "$base" "$out" config src public index.js index.js.map ui.js bin
# `bin/ct` is a real COPY, not a link: `ct` finds the Electron main script it
# starts from its OWN location (`getAppDir().parentDir / "src" / "index.js"`,
# `common/paths.nim`), and `getAppDir` resolves symlinks — a linked `ct` would
# start the build's main process against this prefix's renderer.
mirror "$base/bin" "$out/bin" ct
cp "$(readlink -f "$base/bin/ct")" "$out/bin/ct"
mirror "$base/src" "$out/src" index.js index.js.map
mirror "$base/public" "$out/public" ui.js
cp "$work/index.js" "$out/index.js"
cp "$work/index.js" "$out/src/index.js"
cp "$work/ui.js" "$out/ui.js"
cp "$work/ui.js" "$out/public/ui.js"
mkdir -p "$out/config"
cp "$repo/src/config/default_config.yaml" "$out/config/default_config.yaml"
cp "$layout" "$out/config/default_layout.json"
echo "$out"
