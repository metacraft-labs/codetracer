#!/usr/bin/env bash
# The IsoNim Editor instance over CodeTracer's stories.
#
#   just isonim-editor-codetracer [--port N] [--bind ADDR]
#       Build the instance and serve it (default 0.0.0.0:6106) until stopped.
#       Beyond loopback its agent sessions are disabled (the editor's agent
#       routes are unauthenticated); `--bind 127.0.0.1` keeps them.
#   just isonim-editor-codetracer --smoke
#       Build it, serve it on a free loopback port with a deterministic test
#       agent, and check it in a headless browser
#       (tools/isonim-editor/smoke.mjs): the Agent Harbor fleet-snapshot story
#       and an existing CodeTracer story render, an unknown story renders
#       nothing, the preview a reviewer comments on is pixel-for-pixel what
#       StoryBook renders for the same story at the same size, and a review
#       comment on a story reaches an agent session. It builds StoryBook
#       (`just storybook-build`) for that comparison.
#       Exits 0 when every check passes, 1 otherwise.
#
# What it builds, all under build/isonim-editor-codetracer/ (git-ignored;
# build/isonim-editor-codetracer-smoke/ for --smoke):
#   - the stories: `just build-storybook-components` writes StoryBook's story
#     files from src/frontend/stories/codetracer_stories.nim and builds the
#     components bundle both surfaces mount stories with;
#   - the editor's brief index: an editor copy of each design brief
#     (tools/stories/emit_editor_brief.nim), indexed by IsoNim's
#     brief_index_build. The Agent Harbor brief is private and lives in the
#     private design directory beside this checkout; when it is absent the
#     Agent Harbor stories simply have no brief;
#   - editor.js: src/frontend/isonim_editor_codetracer.nim with that index
#     compiled in;
#   - www/: the static tree IsoNim's editor server serves: the editor page
#     and its vendor scripts, and the CodeTracer files a preview frame loads,
#     at the paths StoryBook serves them at (storybook/.storybook/main.ts).
#
# The server is IsoNim's own (../isonim/tools/editor_server.py): one origin
# for the editor and its agent routes, whose daemon (isonim-review) runs agent
# sessions in this checkout. When the private brief is present its path is
# exported to them as CODETRACER_AGENT_HARBOR_BRIEF (AGENTS.md, "IsoNim
# Editor instance").
#
# Environment:
#   ISONIM_EDITOR_ROOT    the IsoNim checkout (default: ../isonim)
#   ISONIM_EDITOR_VENDOR  a built `isonim#editor-vendor` (default: nix build)
#   ISONIM_REVIEW_BINARY  a built isonim-review daemon (default: built in the
#                         IsoNim checkout with `repro exec -- just isonim-review-build`)
#   CODETRACER_AGENT_HARBOR_BRIEF  the private Agent Harbor brief
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace="$(dirname "$repo")"
isonim="${ISONIM_EDITOR_ROOT:-$workspace/isonim}"
port=6106
bind=0.0.0.0
smoke=0

die() {
	echo "isonim-editor-codetracer: $*" >&2
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
	--smoke) smoke=1 ;;
	--port)
		[ $# -ge 2 ] || die "--port needs a value"
		port="$2"
		shift
		;;
	--port=*) port="${1#--port=}" ;;
	--bind)
		[ $# -ge 2 ] || die "--bind needs a value"
		bind="$2"
		shift
		;;
	--bind=*) bind="${1#--bind=}" ;;
	*) die "unknown argument: $1 (expected --smoke, --port N, --bind ADDR)" ;;
	esac
	shift
done

# The smoke builds its own tree, so a smoke run never rewrites the files a
# served instance is loading.
out="$repo/build/isonim-editor-codetracer"
[ "$smoke" -eq 1 ] && out="$out-smoke"
www="$out/www"

for tool in nim node python3 just; do
	command -v "$tool" >/dev/null || die "$tool is not on PATH; run this through \`just\` in the dev shell"
done
[ -f "$isonim/src/isonim/editor/browser.nim" ] ||
	die "no IsoNim checkout at $isonim (the editor framework; a workspace sibling, or set ISONIM_EDITOR_ROOT)"
[ -f "$isonim/tools/editor_server.py" ] || die "$isonim has no tools/editor_server.py"

# The app's built stylesheets, which every preview frame links. StoryBook
# serves the same tree (storybook/.storybook/main.ts picks it the same way).
build_tree="build-debug"
[ -d "$repo/src/build-debug-repro/frontend" ] && build_tree="build-debug-repro"
[ -f "$repo/src/$build_tree/frontend/styles/default_dark_theme_electron.css" ] ||
	die "src/$build_tree/frontend has no built styles; run \`just build-once\` first"

mkdir -p "$out"

echo "==> stories and components bundle"
if [ "$smoke" -eq 1 ]; then
	# The smoke compares the editor's preview with StoryBook's render of the
	# same story, so it builds StoryBook too (which builds the bundle).
	(cd "$repo" && just storybook-build)
else
	(cd "$repo" && just build-storybook-components)
fi

echo "==> brief index"
rm -rf "$out/briefs"
mkdir -p "$out/briefs"
private_brief="${CODETRACER_AGENT_HARBOR_BRIEF:-$workspace/codetracer-pm/design/agent-harbor-front-end/brief.md}"
if [ -f "$private_brief" ]; then
	private_brief="$(cd "$(dirname "$private_brief")" && pwd)/$(basename "$private_brief")"
	(cd "$repo" && nim r --hints:off tools/stories/emit_editor_brief.nim \
		--brief:"$private_brief" --group:"Agent Harbor" \
		--id:render.agent-harbor-front-end \
		--out:"$out/briefs/render/agent-harbor-front-end.md")
	export CODETRACER_AGENT_HARBOR_BRIEF="$private_brief"
else
	echo "    (no private Agent Harbor brief at $private_brief: those stories have no brief)"
	unset CODETRACER_AGENT_HARBOR_BRIEF
fi
(cd "$isonim" && nim r --hints:off --path:src --path:../nim-everywhere/src \
	src/isonim/editor/design_review/brief_index_build.nim \
	--briefs:"$out/briefs" --json-out:"$out/brief-index.json")

echo "==> editor bundle"
(cd "$repo" && nim js -d:chronicles_enabled=off --hints:off \
	--path:"$workspace/isonim-render-serve/src" \
	-d:isonimBriefIndexJson="$out/brief-index.json" \
	--out:"$out/editor.js" src/frontend/isonim_editor_codetracer.nim)

echo "==> static tree"
vendor="${ISONIM_EDITOR_VENDOR:-}"
if [ -z "$vendor" ]; then
	# Linked into the build directory, so a garbage collection while the
	# instance is served cannot delete what its page loads.
	vendor="$(cd "$isonim" && nix build .#editor-vendor --out-link "$out/editor-vendor" --print-out-paths | tail -n 1)"
fi
for asset in tiptap.umd.js xterm.umd.js xterm.css; do
	[ -f "$vendor/$asset" ] || die "the editor vendor bundle $vendor has no $asset"
done
node_modules="$isonim/node_modules"
editor_node_assets=(fabric/dist/index.min.js paper/dist/paper-core.min.js svgo/dist/svgo.browser.js)
# IsoNim's node modules are installed here when they are absent, so a fresh
# checkout (a CI lane's) needs nothing done by hand first. Yarn with the
# frozen lockfile is IsoNim's canonical install (its Justfile's
# `build-tailwind` runs the same command); its package-lock.json is stale and
# `npm ci` fails on it.
for asset in "${editor_node_assets[@]}"; do
	if [ ! -f "$node_modules/$asset" ]; then
		command -v yarn >/dev/null || die "$node_modules/$asset is missing and yarn is not on PATH to install IsoNim's node modules"
		echo "    installing IsoNim's node modules (yarn install --frozen-lockfile in $isonim)"
		(cd "$isonim" && yarn install --frozen-lockfile)
		break
	fi
done
for asset in "${editor_node_assets[@]}"; do
	[ -f "$node_modules/$asset" ] || die "$node_modules/$asset is missing after installing IsoNim's node modules"
done
rm -rf "$www"
mkdir -p "$www/vendor" "$www/codetracer-storybook" "$www/libs"
cp "$out/editor.js" "$www/editor.js"
cp "$node_modules/fabric/dist/index.min.js" "$www/fabric.min.js"
cp "$node_modules/paper/dist/paper-core.min.js" "$www/paper-core.min.js"
cp "$node_modules/svgo/dist/svgo.browser.js" "$www/svgo.browser.js"
for asset in tiptap.umd.js xterm.umd.js xterm.css; do
	cp -L "$vendor/$asset" "$www/vendor/$asset"
done
chmod -R u+w "$www/vendor"
# IsoNim's editor page, with the vendor scripts its Spec pane (TipTap) and
# terminal (xterm) need loaded ahead of the editor bundle.
page="$isonim/src/isonim/editor/index.html"
grep -q '<script src="fabric.min.js"></script>' "$page" ||
	die "$page no longer loads fabric.min.js where this script inserts the vendor scripts"
sed 's|<title>IsoNim Editor</title>|<title>CodeTracer stories - IsoNim Editor</title>|;
     s|    <script src="fabric.min.js"></script>|    <link rel="stylesheet" href="vendor/xterm.css" />\n    <script src="vendor/xterm.umd.js"></script>\n    <script src="vendor/tiptap.umd.js"></script>\n    <script src="fabric.min.js"></script>|' \
	"$page" >"$www/index.html"
ln -s "$repo/storybook/dist/components.js" "$www/codetracer-storybook/components.js"
ln -s "$repo/storybook/stories/lib" "$www/codetracer-storybook/lib"
ln -s "$repo/src/$build_tree/frontend" "$www/frontend"
ln -s "$repo/src/$build_tree/public" "$www/public"
ln -s "$repo/libs/codetracer-design-system" "$www/libs/codetracer-design-system"

echo "==> editor daemon"
daemon="${ISONIM_REVIEW_BINARY:-}"
if [ -z "$daemon" ]; then
	(cd "$isonim" && repro exec -- just isonim-review-build)
	daemon="$isonim/build/bin/isonim-review"
fi
[ -x "$daemon" ] || die "no isonim-review daemon at $daemon"

server=(python3 "$isonim/tools/editor_server.py" --directory "$www"
	--project-root "$repo" --daemon-binary "$daemon")

if [ "$smoke" -eq 0 ]; then
	# The editor's agent routes are unauthenticated: whoever reaches the
	# server can start an agent session that runs commands in this checkout.
	# Served beyond loopback, the instance therefore gets an agent backend
	# that refuses every session; previews, the Spec pane and review comments
	# work as before. Serve on loopback (`--bind 127.0.0.1`) to use agents.
	case "$bind" in
	127.* | localhost | ::1) ;;
	*)
		no_agent="$out/no-agent.sh"
		cat >"$no_agent" <<'EOF'
#!/bin/sh
echo "Agent sessions are disabled on this editor instance: it is served beyond loopback and the editor's agent routes are unauthenticated. Serve it with --bind 127.0.0.1 to use agents." >&2
exit 1
EOF
		chmod +x "$no_agent"
		printf '[agent]\nbackend = "custom"\ncommand = "%s"\nargs = []\nprimer_enabled = false\n' "$no_agent" >"$out/no-agent.toml"
		server+=(--config "$out/no-agent.toml")
		echo "    agent sessions disabled: $bind is not a loopback address"
		;;
	esac
	echo "==> serving CodeTracer's stories on http://$bind:$port/"
	exec "${server[@]}" --port "$port" --bind "$bind"
fi

# --- smoke ------------------------------------------------------------------
# A deterministic ACP agent (IsoNim's test peer) records every prompt it is
# sent; the check asserts on what reached it. Nothing else is substituted.
smoke_dir="$out/smoke"
rm -rf "$smoke_dir"
mkdir -p "$smoke_dir"
fake_agent="${ISONIM_FAKE_ACP_AGENT:-$(dirname "$daemon")/fake-acp-agent}"
if [ ! -x "$fake_agent" ]; then
	(cd "$isonim" && nim c -d:release --hints:off -o:"$smoke_dir/fake-acp-agent" tests/helpers/fake_acp_agent.nim)
	fake_agent="$smoke_dir/fake-acp-agent"
fi
printf '[agent]\nbackend = "custom"\ncommand = "%s"\nargs = []\nprimer_enabled = false\n' "$fake_agent" >"$smoke_dir/review.toml"

FAKE_ACP_CONTENT_LOG="$smoke_dir/agent-prompts.jsonl" \
	FAKE_ACP_REPLY="CODETRACER_EDITOR_SMOKE_REPLY" \
	"${server[@]}" --port 0 --bind 127.0.0.1 --config "$smoke_dir/review.toml" \
	>"$smoke_dir/server.out" 2>"$smoke_dir/server.err" &
server_pid=$!
stop_server() {
	if kill -0 "$server_pid" 2>/dev/null; then
		kill -TERM "$server_pid" 2>/dev/null || true
		wait "$server_pid" 2>/dev/null || true
	fi
}
trap stop_server EXIT

url=""
for _ in $(seq 1 600); do
	url="$(sed -n 's|^Editor listening on \(http://[^ ]*\)/$|\1|p' "$smoke_dir/server.out" | head -n 1)"
	[ -n "$url" ] && break
	kill -0 "$server_pid" 2>/dev/null || {
		cat "$smoke_dir/server.err" >&2
		die "the editor server exited before listening"
	}
	sleep 0.5
done
[ -n "$url" ] || die "the editor server did not start listening in 300 s (log: $smoke_dir/server.err)"
url="${url/0.0.0.0/127.0.0.1}"

status=0
node "$repo/tools/isonim-editor/smoke.mjs" --url "$url" --out "$smoke_dir" \
	--stories "$repo/storybook/stories/generated/stories.json" \
	--agent-log "$smoke_dir/agent-prompts.jsonl" \
	--storybook-static "$repo/storybook/storybook-static" \
	--private-brief "${CODETRACER_AGENT_HARBOR_BRIEF:-}" || status=$?
stop_server
trap - EXIT
if [ "$status" -eq 0 ]; then
	echo "isonim-editor-codetracer: smoke PASSED (screenshots and logs in $smoke_dir)"
else
	echo "isonim-editor-codetracer: smoke FAILED (screenshots and logs in $smoke_dir)" >&2
fi
exit "$status"
