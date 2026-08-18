#!/usr/bin/env bash
# shellcheck disable=SC2016
# The diagnostics below quote identifiers, module names and shell commands in
# backticks for the reader.  They are prose, not command substitutions, so the
# single quotes are deliberate and SC2016 does not apply.
set -euo pipefail

# CodeTracer dev build (`just build`) — a full `just build-once`, then the
# watchers that keep it up to date.
#
# ## Why this script delegates instead of reimplementing
#
# `just build` and `just build-once` used to be two independent transcriptions
# of the same build, and they drifted (issue #599): `build.sh` had no FUSE
# preflight, no second tup pass, no `post-build-setcap.sh`, hardcoded the
# `build-debug` variant where `build-once.sh` honoured `CODETRACER_CONFIG`,
# and — the actual regression — ran `webpack --watch` BEFORE tup rather than
# after it.
#
# That last one is the interesting failure. `src/public/Tupfile:38` is
#
#     : foreach dist/* |> !tup_preserve |> %f
#
# i.e. tup globs webpack's OUTPUT directory. Starting `webpack --watch` first
# means the glob is evaluated against a directory webpack is concurrently
# writing into, from inside tup's FUSE sandbox. On a fresh tree `dist/` is
# empty at parse time and `frontend_bundle.js` never reaches the variant tree;
# on a warm tree webpack rewrites the bundle mid-pass. Two different,
# nondeterministic failures from one ordering bug. `build-once.sh` has always
# had this right: tup, then webpack in the FOREGROUND, then tup again —
# "webpack may have created some new files that tup will discover".
#
# So the rule this script now follows is: `build-once.sh` performs the entire
# build, to completion, before any watcher starts. Everything `build-once.sh`
# gains — preflights, extra passes, setcap, new configuration — `just build`
# gains for free, and neither can drift from the other again.
#
# ## Background processes started here, and only after the build
#
#   * tup monitor -a   — incremental rebuilds on legacy tup hosts. Started
#                        before the writers below so it does not miss their
#                        first events.
#   * webpack --watch  — frontend_bundle.js (third-party bundle)
#   * livereload       — file-tree watcher + LiveReload-protocol WebSocket
#                        server on port 35729, watching the resolved output
#                        tree. `src/frontend/hmr_runtime.nim:70` connects to
#                        ws://localhost:35729/livereload.
#   * repro watch      — incremental rebuilds on reprobuild hosts; runs in the
#                        FOREGROUND as the second `build-once.sh` invocation.
#
# Every one of them is registered with `ct_start_watcher` and torn down by the
# single `cleanup` trap installed below, which is armed BEFORE the first of
# them exists. The previous version installed its trap after the `tup` calls,
# so a failing tup under `set -e` orphaned `webpack --watch`; and the
# reprobuild branch `exec`ed away, discarding the trap entirely. Orphans
# compound: a leaked livereload holds port 35729 so the next run gets
# EADDRINUSE, and accumulated webpack instances exhaust the inotify watch
# budget `tup monitor -a` needs.

# Job control off (the default for non-interactive shells, asserted here
# because `ct_start_watcher` depends on it): with job control ON, `cmd &`
# would put the child in its own process group, which makes `setsid` fork and
# breaks the pid → process-group correspondence cleanup relies on.
set +m

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# `build-once.sh` and the Tupfiles are written against the repo root as CWD.
cd "$REPO_ROOT"

# Diagnostic/test override only. The renderer hardcodes 35729
# (src/frontend/hmr_runtime.nim:70), so moving the port disables HMR in the
# running binary — it exists to let a preflight failure be investigated, and
# to let the build-alignment harness run against a busy machine.
ct_livereload_port="${CODETRACER_LIVERELOAD_PORT:-35729}"

# ---------------------------------------------------------------------------
# Teardown. Installed before anything can leak, and idempotent so the EXIT
# trap after an INT does not double-signal.
# ---------------------------------------------------------------------------
ct_watcher_pids=()
ct_build_env_file=""
ct_cleanup_done=""

# Signal a watcher and everything it spawned. Children first, so a supervisor
# process cannot respawn a worker we already killed.
ct_kill_tree() {
	local pid="$1" sig="$2" child
	if command -v pgrep >/dev/null 2>&1; then
		for child in $(pgrep -P "$pid" 2>/dev/null || true); do
			ct_kill_tree "$child" "$sig"
		done
	fi
	# The negative pid names the process GROUP, which is what `setsid` gave
	# each watcher; the plain pid is the fallback for hosts without setsid
	# (macOS ships none). Never our own group — that would take `just`, and
	# a developer's shell, down with it.
	kill -s "$sig" -- "-$pid" 2>/dev/null ||
		kill -s "$sig" "$pid" 2>/dev/null ||
		true
}

cleanup() {
	if [ -n "$ct_cleanup_done" ]; then
		return 0
	fi
	ct_cleanup_done=1

	local pid
	for pid in ${ct_watcher_pids[@]+"${ct_watcher_pids[@]}"}; do
		[ -n "$pid" ] || continue
		ct_kill_tree "$pid" TERM
	done
	if [ ${#ct_watcher_pids[@]} -gt 0 ]; then
		# Node's SIGTERM handlers need a moment to close their watchers and
		# release the LiveReload port; without the pause the next `just build`
		# can still hit EADDRINUSE.
		sleep 0.5 2>/dev/null || true
		for pid in ${ct_watcher_pids[@]+"${ct_watcher_pids[@]}"}; do
			[ -n "$pid" ] || continue
			ct_kill_tree "$pid" KILL
		done
	fi

	if [ -n "$ct_build_env_file" ]; then
		rm -f "$ct_build_env_file"
	fi
}

# `tup monitor -a` is deliberately NOT torn down: it daemonises itself and is
# shared state for the checkout (a subsequent `tup upd` expects it), so it
# outlives any single `just build`, exactly as it did before.
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM HUP

# ---------------------------------------------------------------------------
# Preflight: the LiveReload port.
#
# A leaked daemon from an earlier run makes `livereload` exit with a bare
# EADDRINUSE stack trace, interleaved with webpack's progress output, several
# seconds after the build appears to have succeeded. Name it here instead.
# ---------------------------------------------------------------------------
ct_port_in_use() {
	# bash's /dev/tcp virtual device: a successful connect means something is
	# accepting. No lsof/ss/netstat dependency, and no false positive from a
	# lingering TIME_WAIT socket, which refuses connections. The subshell
	# closes the descriptor on exit.
	if (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; then
		return 0
	fi
	return 1
}

if ct_port_in_use "$ct_livereload_port"; then
	{
		echo "Cannot start the dev build: TCP port $ct_livereload_port is already in use."
		echo
		echo "That port is the LiveReload/HMR WebSocket endpoint this script is about"
		echo "to bind (src/frontend/hmr_runtime.nim connects to"
		echo "ws://localhost:35729/livereload). Almost always the holder is a"
		echo 'livereload daemon leaked by an earlier `just build` that was killed'
		echo "rather than asked to exit."
		echo
		echo "Find it:"
		echo "    lsof -nP -iTCP:$ct_livereload_port -sTCP:LISTEN"
		echo "    ss -ltnp \"sport = :$ct_livereload_port\""
		echo
		echo "Then stop it:"
		echo "    pkill -f 'node_modules/.bin/livereload'"
		echo
		echo "If the port is legitimately taken by something else, run this build"
		echo "against another port with CODETRACER_LIVERELOAD_PORT=<port> — but note"
		echo "the renderer's endpoint is compiled in, so HMR will not connect."
	} >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Phase 1 — the full build, to completion, with no watcher running.
#
# CODETRACER_BUILD_ENV_FILE asks build-once.sh to publish the build identity it
# resolved (host branch, config, tup variant, output root) so the watchers
# below target the same tree instead of re-deriving it. See the contract in
# scripts/build-once.sh.
# ---------------------------------------------------------------------------
ct_build_env_file="$(mktemp "${TMPDIR:-/tmp}/codetracer-build-env.XXXXXX")"
export CODETRACER_BUILD_ENV_FILE="$ct_build_env_file"

bash "$SCRIPT_DIR/build-once.sh"

if [ ! -s "$ct_build_env_file" ]; then
	echo "Error: scripts/build-once.sh did not publish a build environment to $ct_build_env_file." >&2
	echo '       `just build` reads the resolved variant and output root from there;' >&2
	echo "       see the ct_publish_build_env contract in scripts/build-once.sh." >&2
	exit 1
fi
# shellcheck source=/dev/null
. "$ct_build_env_file"

: "${CT_BUILD_HOST?build environment is missing CT_BUILD_HOST}"
: "${CT_BUILD_OUT_ROOT?build environment is missing CT_BUILD_OUT_ROOT}"

# ---------------------------------------------------------------------------
# Phase 2 — watchers.
# ---------------------------------------------------------------------------
ct_setsid="$(command -v setsid || true)"

# Start a watcher in its own process group (where the platform allows it) and
# record it for cleanup. Its own group is what lets `cleanup` signal the whole
# subtree — webpack forks workers, chokidar can spawn helpers — without
# signalling this script's group, i.e. `just` and the developer's shell.
ct_start_watcher() {
	if [ -n "$ct_setsid" ]; then
		"$ct_setsid" "$@" &
	else
		"$@" &
	fi
	ct_watcher_pids+=("$!")
}

if [ -z "$CT_BUILD_HOST" ]; then
	# Legacy tup host. `tup monitor -a` daemonises; start it before the
	# writers below so it does not miss their first events.
	cd src
	"${TUP:-tup}" monitor -a
	cd ..
fi

# Webpack keeps bundling the third-party JS deps in watch mode. This is
# unrelated to the Nim renderer's HMR, but frontend_bundle.js is an asset the
# renderer also loads. It runs only AFTER build-once.sh has finished — see the
# header: tup globs this process's output directory.
ct_start_watcher node_modules/.bin/webpack --watch --progress

# LiveReload daemon over the resolved output tree. `--wait 200` smooths
# multi-pass rebuilds, which can write the same file twice in quick
# succession.
ct_start_watcher node_modules/.bin/livereload \
	"$CT_BUILD_OUT_ROOT" \
	--port "$ct_livereload_port" \
	--wait 200 \
	--usepolling false

cat <<HMR_BANNER

==============================================================
  CodeTracer dev build complete — HMR-enabled binary ready.

  Run with:  $CT_BUILD_OUT_ROOT/bin/ct

  HMR is on by default. Edits to anything under
  $CT_BUILD_OUT_ROOT/ (build outputs, Stylus-rebuilt CSS,
  vendored third-party JS/CSS, …) trigger in-place reloads in
  every connected ct window. To disable for a launch:
  CT_HMR=0 $CT_BUILD_OUT_ROOT/bin/ct.
==============================================================
HMR_BANNER

if [ -n "$CT_BUILD_HOST" ]; then
	# Reprobuild host: the incremental rebuilder is `repro watch`, which is
	# build-once.sh invoked a second time with a different reprobuild
	# subcommand. A plain call, NOT `exec` — `exec` would replace this shell
	# and discard the cleanup trap, orphaning webpack and livereload.
	export CODETRACER_REPROBUILD_COMMAND="watch"
	bash "$SCRIPT_DIR/build-once.sh"
else
	# Legacy tup host: `tup monitor -a` already daemonised, so the only
	# foreground work left is to keep this shell (and therefore the cleanup
	# trap) alive for as long as the watchers run.
	wait
fi
