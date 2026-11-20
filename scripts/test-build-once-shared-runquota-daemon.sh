#!/usr/bin/env bash
# Two concurrent build-once.sh runs share one RunQuota daemon (Linux leg).
#
# build-once.sh must not start a RunQuota daemon of its own. A private daemon
# per invocation gives every build a whole budget of its own: two concurrent
# builds then admit twice what the machine has. The script has to leave the
# endpoint to the host, so that concurrent builds draw on ONE budget.
#
# What runs here is the REAL scripts/build-once.sh, twice at once, against
# ONE daemon that the test starts and treats as the host's daemon. Nothing
# else is the real thing, and the reasons are specific:
#
#   * The build target is a stand-in `repro`, passed through REPROBUILD_BIN
#     (the script's explicit "use this binary" choice). A real codetracer
#     build compiles the whole application, takes tens of minutes and fills
#     the shared host's quota, and it would measure the compiler, not the
#     endpoint. The script's own handling of the endpoint, which is the
#     subject, runs unchanged before it calls `repro`.
#   * The stand-in plays the one part of `repro` that matters: it connects to
#     the endpoint `repro` would find. `repro` takes RUNQUOTA_SOCKET when it is
#     set and otherwise adopts the host's daemon (the endpoint discovery of the
#     RunQuota protocol); the stand-in does the same, reading the host's
#     endpoint from TEST_HOST_SOCKET in place of the host rendezvous path that
#     only a provisioned host has. It then takes a real lease with the real
#     `runquota acquire` and holds it for a moment, so the daemon has real
#     leases to report.
#   * The daemon is a private `runquotad` on a socket in a `mktemp -d`, with its
#     own state files. It stands in for the host's daemon; the real one is never
#     touched.
#
# Assertions, each from a separate observation:
#   1. while both builds hold their lease, the host daemon reports TWO running
#      leases from two distinct sessions (`runquota leases --json`), and its
#      budget accounts for both (`runquota status --json`);
#   2. exactly one `runquotad` exists for the whole run: the one the test
#      started, counted from /proc, not from what build-once.sh says;
#   3. both builds were pointed at the host's socket, not at one of their own;
#   4. with RUNQUOTA_SOCKET set, that explicit endpoint is used unchanged.
#
# Falsifying mutation (performed once on the Linux host): restoring the private
# daemon start in build-once.sh makes each run start a `runquotad` of its own
# and export that socket, so the host's daemon holds no lease at all and the
# test fails at assertion 1 ("reports 0 running leases, expected 2").
#
# `runquota` and `runquotad` are required, not optional: a missing one FAILS the
# test. They come from RUNQUOTA_BIN_DIR, the sibling runquota checkout's
# build/bin, or PATH, in that order.
#
# macOS: not covered here. build-once.sh takes the same code path there, but
# this leg has only been run on Linux.
#
#   bash scripts/test-build-once-shared-runquota-daemon.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
host_pid=""
cleanup() {
	# Stop only the daemon this script started, and only if the PID still
	# names a runquotad under this script's own directory: never by name.
	if [ -n "$host_pid" ] && [ -r "/proc/$host_pid/cmdline" ] &&
		tr '\0' ' ' <"/proc/$host_pid/cmdline" | grep -qF -- "$work/"; then
		kill "$host_pid" 2>/dev/null || true
		wait "$host_pid" 2>/dev/null || true
	fi
	rm -rf "${work:?}"
}
# The lease holders in the stand-in end on their own once $work is gone (or
# after a minute), so an aborted run leaves nothing behind to be killed.
trap cleanup EXIT
fail() {
	echo "FAIL: $*" >&2
	exit 1
}

[ "$(uname -s)" = Linux ] || fail "this is the Linux leg; /proc is used to count daemons"

# Locate the RunQuota binaries.
rq_dir=""
for candidate in "${RUNQUOTA_BIN_DIR:-}" "$root/../runquota/build/bin"; do
	if [ -n "$candidate" ] && [ -x "$candidate/runquota" ] && [ -x "$candidate/runquotad" ]; then
		rq_dir="$(cd "$candidate" && pwd)"
		break
	fi
done
if [ -z "$rq_dir" ]; then
	rq_cli="$(command -v runquota || true)"
	rq_daemon="$(command -v runquotad || true)"
	[ -n "$rq_cli" ] && [ -n "$rq_daemon" ] ||
		fail "runquota and runquotad are required (set RUNQUOTA_BIN_DIR, build ../runquota, or put them on PATH)"
	rq_dir="$work/rqbin"
	mkdir -p "$rq_dir"
	ln -s "$rq_cli" "$rq_dir/runquota"
	ln -s "$rq_daemon" "$rq_dir/runquotad"
fi
echo "using runquota from $rq_dir ($("$rq_dir/runquota" --version | head -n 1))"

# The scratch codetracer: the real script, with the helpers it calls stubbed
# (none of them is the subject), as test-build-once-repro-selection.sh does.
ct="$work/codetracer"
mkdir -p "$ct/scripts" "$ct/ci/lib" "$ct/locks" "$work/bin" "$work/tmp"
cp "$root/scripts/build-once.sh" "$ct/scripts/"
printf 'linux lock\n' >"$ct/repro.lock"
# build-once.sh insists on an absolute tool-path manifest for the build; its
# content is not the subject (the stand-in `repro` never reads it).
printf '{}\n' >"$work/tool-paths.json"
for helper in require-siblings build-tailwind post-build-setcap require-runtime-assets; do
	printf '#!/usr/bin/env bash\nexit 0\n' >"$ct/scripts/$helper.sh"
done
# The freshness stamp the script writes after a build is not the subject.
printf 'bf_electron_write_stamp() { return 0; }\n' >"$ct/ci/lib/build-freshness.sh"
for tool in nim tup nix xcrun; do
	printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/$tool"
done
chmod +x "$ct/scripts/"*.sh "$work/bin/"*

# The stand-in `repro`. It records the endpoint it used and takes a lease.
cat >"$work/bin/repro" <<'TOOL'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = --version ]; then echo 'repro stand-in'; exit 0; fi
# repro's discovery: an explicit endpoint wins, otherwise the host's.
endpoint="${RUNQUOTA_SOCKET:-$TEST_HOST_SOCKET}"
printf '%s\n' "$endpoint" >"$TEST_WORK/endpoint.$TEST_RUN"
export RUNQUOTA_SOCKET="$endpoint"
"$TEST_RQ_DIR/runquota" acquire --cpu 1000 --mem 1048576 --label "build-once-$TEST_RUN" \
	-- bash -c ': >"$TEST_WORK/holding.$TEST_RUN"; for _ in $(seq 1 1200); do [ -d "$TEST_WORK" ] && [ ! -e "$TEST_WORK/release" ] || break; sleep 0.05; done'
TOOL
chmod +x "$work/bin/repro"

# The host's daemon, on a private socket in a directory of its own (the
# rendezvous directory must be owned by the user and not group- or
# world-writable).
host_dir="$work/host"
mkdir -m 700 "$host_dir"
host_sock="$host_dir/runquotad.sock"
"$rq_dir/runquotad" --socket "$host_sock" \
	--host-config "$host_dir/host.toml" --host-identity-file "$host_dir/host-id" \
	--estimate-db "$host_dir/estimates.sqlite" --no-write-stats \
	--ambient-sample-interval-millis 0 --memory-pressure-source unavailable \
	--cpu-milli 8000 --memory-bytes 17179869184 >"$host_dir/daemon.log" 2>&1 &
host_pid="$!"
for _ in $(seq 1 200); do
	grep -q "runquotad listening" "$host_dir/daemon.log" 2>/dev/null && break
	kill -0 "$host_pid" 2>/dev/null || {
		cat "$host_dir/daemon.log" >&2
		fail "the stand-in host daemon exited before it listened"
	}
	sleep 0.05
done
grep -q "runquotad listening" "$host_dir/daemon.log" || fail "the stand-in host daemon never listened"

rq() { RUNQUOTA_SOCKET="$host_sock" "$rq_dir/runquota" "$@"; }

# Count the runquotad processes that belong to this run: any whose command
# line names a path under $work (the host's, or a private one a script put in
# TMPDIR, which is $work/tmp).
count_daemons() {
	local n=0 f
	for f in /proc/[0-9]*/cmdline; do
		[ -r "$f" ] || continue
		tr '\0' '\n' <"$f" 2>/dev/null | head -n 1 | grep -q '/runquotad$' || continue
		tr '\0' ' ' <"$f" 2>/dev/null | grep -qF -- "$work/" && n=$((n + 1))
	done
	echo "$n"
}

# Start build-once.sh as run $1 (extra env as further arguments), in the
# background, with RUNQUOTA_SOCKET unset unless an argument sets it.
start_build() {
	local run="$1"
	shift
	(cd "$ct" && env -u RUNQUOTA_SOCKET PATH="$work/bin:$PATH" TMPDIR="$work/tmp" \
		TEST_WORK="$work" TEST_RUN="$run" TEST_HOST_SOCKET="$host_sock" TEST_RQ_DIR="$rq_dir" \
		REPROBUILD_BIN="$work/bin/repro" CODETRACER_REPROBUILD_LINUX=1 \
		CODETRACER_SKIP_SIBLING_CHECK=1 CODETRACER_TRACE_FORMAT_NIM_TOOL_PATHS="$work/tool-paths.json" "$@" \
		bash "$ct/scripts/build-once.sh") >"$work/log.$run" 2>&1 &
	build_pids+=("$!")
}
wait_for() { # wait_for <what> <command...>
	local what="$1" _
	shift
	for _ in $(seq 1 400); do
		"$@" 2>/dev/null && return 0
		sleep 0.05
	done
	for f in "$work"/log.*; do
		echo "--- $f" >&2
		cat "$f" >&2
	done
	fail "timed out waiting for $what"
}
finish_builds() {
	local pid
	: >"$work/release"
	for pid in "${build_pids[@]}"; do
		wait "$pid" || {
			for f in "$work"/log.*; do
				echo "--- $f" >&2
				cat "$f" >&2
			done
			fail "a build-once.sh run exited non-zero"
		}
	done
	build_pids=()
	rm -f "${work:?}/release"
}

# 1-3. Two concurrent runs, no RUNQUOTA_SOCKET.
build_pids=()
start_build a
start_build b
wait_for "both builds to hold a lease" test -e "$work/holding.a" -a -e "$work/holding.b"

leases_json="$(rq leases --json)"
# `grep -o` exits 1 on no match, which pipefail would turn into a silent abort.
running="$(printf '%s' "$leases_json" | { grep -o '"state":"running"' || true; } | wc -l)"
sessions="$(printf '%s' "$leases_json" | { grep -o '"session_id":[0-9]*' || true; } | sort -u | wc -l)"
[ "$running" = 2 ] || fail "the host daemon reports $running running leases, expected 2: $leases_json"
[ "$sessions" = 2 ] || fail "the two leases are from $sessions sessions, expected 2: $leases_json"
status_json="$(rq status --json)"
printf '%s' "$status_json" | grep -q '"active_leases":2' ||
	fail "the host daemon's status does not account for both leases: $status_json"
echo "PASS: both builds hold a lease from the host daemon's one budget ($running running leases, $sessions sessions)"

daemons="$(count_daemons)"
[ "$daemons" = 1 ] || fail "found $daemons runquotad processes for this run, expected exactly 1 (the host's)"
echo "PASS: one daemon in all"

for run in a b; do
	[ "$(cat "$work/endpoint.$run")" = "$host_sock" ] ||
		fail "build $run used the endpoint '$(cat "$work/endpoint.$run")', not the host's $host_sock"
done
echo "PASS: both builds were pointed at the host's endpoint"
finish_builds

# 4. An explicit RUNQUOTA_SOCKET is honoured unchanged.
explicit="$work/explicit.sock"
start_build c RUNQUOTA_SOCKET="$explicit"
wait_for "the explicit-endpoint build to reach the stand-in" test -e "$work/endpoint.c"
[ "$(cat "$work/endpoint.c")" = "$explicit" ] ||
	fail "RUNQUOTA_SOCKET was not honoured: the build used '$(cat "$work/endpoint.c")'"
[ "$(count_daemons)" = 1 ] || fail "an explicit endpoint made build-once.sh start a daemon"
# Nothing listens on the explicit socket, so the stand-in's acquire cannot
# lease; that is irrelevant here. Release and let the run end either way.
: >"$work/release"
for pid in "${build_pids[@]}"; do wait "$pid" || true; done
echo "PASS: an explicit RUNQUOTA_SOCKET is used as given, and starts nothing"

echo "ALL PASS: two concurrent build-once.sh runs share the host's one daemon"
