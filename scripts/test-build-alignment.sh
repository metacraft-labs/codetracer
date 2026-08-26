#!/usr/bin/env bash
# =============================================================================
# Build-alignment harness — `just build` must be `just build-once` plus
# watchers, and nothing else.
#
# ## What this replaced, and why
#
# The previous version of this file was twelve lines that grepped both scripts
# for the identifier `ct_reprobuild_host` and passed if it appeared in each. It
# would have passed if the two `case` blocks assigned OPPOSITE values, if
# either branch body were deleted, or if the variable were never read; it never
# executed either script; and it was wired into nothing — no justfile recipe,
# no CI job, no workflow. It had never run, and it certified the one thing that
# was never broken while `just build` and `just build-once` diverged in eight
# other places (issue #599).
#
# ## How this one works
#
# Both scripts are EXECUTED, in a sandbox whose PATH and `node_modules/.bin`
# hold recording stubs for every external command they reach for — `tup`,
# `webpack`, `livereload`, `repro`, `runquotad`, `nix`, `uname`, and the
# in-repo helper scripts. Each stub appends `name<TAB>cwd<TAB>argv` to a trace
# file and exits 0. The assertions are then made against the TRACES: what ran,
# with which arguments, in which order. Nothing is asserted by grepping source,
# so a refactor that preserves behaviour keeps passing and a behaviour change
# that preserves the source text still fails.
#
# The assertion that matters most is (D): in `build.sh`'s trace, no webpack
# invocation may be ordered before the first tup/repro invocation. That is the
# #599 regression — `src/public/Tupfile:38` globs webpack's output directory,
# so starting `webpack --watch` first makes tup parse a directory another
# process is concurrently writing. Run against the code as it stood before the
# fix, (D) fails on the first scenario.
#
# This is Tier 1 of a three-tier design. Tier 2 (process hygiene: SIGINT a real
# `just build` and assert the watcher tree and port 35729 are released) is
# partly covered here by scenario `port-busy`. Tier 3 (a CI lane that runs both
# recipes for real and asserts `bin/ct` exists and is executable) is what makes
# the pair non-vacuous end to end; it needs a build host and is out of scope
# for a seconds-long local check.
#
# Run:  bash scripts/test-build-alignment.sh        (or: just test-build-alignment)
#       KEEP_SANDBOX=1 ... to leave the sandboxes and traces behind.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ct-build-alignment.XXXXXX")"

failures=0
checks=0

cleanup_work_root() {
	if [ -z "${KEEP_SANDBOX:-}" ]; then
		rm -rf "$WORK_ROOT"
	else
		echo "sandboxes kept at $WORK_ROOT" >&2
	fi
}
trap cleanup_work_root EXIT

pass() {
	checks=$((checks + 1))
	printf '    ok   %s\n' "$1"
}

fail() {
	checks=$((checks + 1))
	failures=$((failures + 1))
	printf '    FAIL %s\n' "$1"
	if [ -n "${2:-}" ]; then
		printf '%s\n' "$2" | sed 's/^/           /'
	fi
}

# ---------------------------------------------------------------------------
# Sandbox construction
# ---------------------------------------------------------------------------

# Every external command the two scripts invoke, replaced by a stub that
# records the call. `uname` and `runquotad` need behaviour beyond recording and
# are written separately below.
STUB_COMMANDS=(tup repro nix xcrun node npm npx)
# In-repo helper scripts that do real work we neither want nor need here. They
# are still exercised as CALLS: each records into the trace, so the assertions
# can require that `build.sh` reaches all of them.
STUB_HELPER_SCRIPTS=(
	build-tailwind.sh
	require-siblings.sh
	require-fuse-mount-helper.sh
	require-tup-globs.sh
	post-build-setcap.sh
)

write_recording_stub() {
	local path="$1" name="$2"
	cat >"$path" <<EOF
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' '$name' "\$PWD" "\$*" >>"\$CT_ALIGN_TRACE"
exit 0
EOF
	chmod +x "$path"
}

make_sandbox() {
	local sandbox="$1"
	mkdir -p "$sandbox/bin" "$sandbox/node_modules/.bin" "$sandbox/src/public" "$sandbox/.repro"

	# Real copies of the scripts under test, so `$0`-derived SCRIPT_DIR lands
	# inside the sandbox and the nested build-once.sh call resolves here too.
	cp -R "$REPO_ROOT/scripts" "$sandbox/scripts"

	local name
	for name in "${STUB_COMMANDS[@]}"; do
		write_recording_stub "$sandbox/bin/$name" "$name"
	done
	for name in webpack livereload; do
		write_recording_stub "$sandbox/node_modules/.bin/$name" "$name"
	done
	for name in "${STUB_HELPER_SCRIPTS[@]}"; do
		write_recording_stub "$sandbox/scripts/$name" "${name%.sh}"
	done

	# `uname -s` drives the host branch in build-once.sh; overriding it on PATH
	# is what lets one Linux machine exercise the Darwin and Windows branches.
	cat >"$sandbox/bin/uname" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' 'uname' "$PWD" "$*" >>"$CT_ALIGN_TRACE"
printf '%s\n' "$CT_ALIGN_UNAME"
EOF
	chmod +x "$sandbox/bin/uname"

	# build-once.sh waits for "runquotad listening" in the daemon's log and
	# polls `kill -0` on the pid, so this stub must announce readiness and then
	# stay alive. `exec sleep` keeps the pid the caller recorded, so the
	# caller's trap actually reaps it.
	cat >"$sandbox/bin/runquotad" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' 'runquotad' "$PWD" "$*" >>"$CT_ALIGN_TRACE"
echo "runquotad listening"
exec sleep 60
EOF
	chmod +x "$sandbox/bin/runquotad"
}

# Environment variables that leak in from the developer's dev shell and would
# otherwise steer the scripts away from the scenario under test.
SCRUBBED_VARS=(
	CODETRACER_CONFIG
	CODETRACER_REPROBUILD_LINUX
	CODETRACER_REPROBUILD_COMMAND
	CODETRACER_REPROBUILD_REPO_PATH
	CODETRACER_BUILD_ENV_FILE
	CODETRACER_SKIP_SIBLING_CHECK
	REPROBUILD_BIN
	REPROBUILD_SOURCE_ROOT
	REPRO_VARIANTS
	REPRO_MONITOR_SHIM_LIB
	RUNQUOTA_SOCKET
	RUNQUOTAD_BIN
	TUP
)

# Run one of the scripts under test inside a fresh sandbox and leave its trace
# at $2. Extra `K=V` assignments for the scenario come as trailing arguments.
run_script() {
	local script="$1" trace="$2" sandbox="$3" uname_s="$4" port="$5"
	shift 5

	make_sandbox "$sandbox"
	: >"$trace"

	local -a scrub=()
	local var
	for var in "${SCRUBBED_VARS[@]}"; do
		scrub+=(-u "$var")
	done

	(
		cd "$sandbox" || exit 1
		timeout 120 env "${scrub[@]}" \
			PATH="$sandbox/bin:$PATH" \
			CT_ALIGN_TRACE="$trace" \
			CT_ALIGN_UNAME="$uname_s" \
			CODETRACER_LIVERELOAD_PORT="$port" \
			"$@" \
			bash "$sandbox/scripts/$script"
	) >"$trace.out" 2>&1
	printf '%s' "$?"
}

# ---------------------------------------------------------------------------
# Trace helpers. Comparisons use `name<TAB>argv`; the cwd column is recorded
# for debugging but deliberately not asserted on.
# ---------------------------------------------------------------------------

# `name<TAB>argv`, with the per-run volatile tokens folded away so two runs of
# the same code compare equal. Currently just build-once.sh's runquotad socket,
# which embeds `$$`.
normalized() {
	cut -f1,3 <"$1" | sed -E 's#(codetracer-reprobuild-)[0-9]+(\.sock)#\1<pid>\2#g'
}
names() { cut -f1 <"$1"; }

# 1-based index of the first record whose command name is $2; empty if absent.
first_index() {
	names "$1" | grep -n -x -F -- "$2" 2>/dev/null | head -n1 | cut -d: -f1
}

# Every distinct `build-*` argument handed to `tup`, one per line.
tup_variants() {
	awk -F'\t' '$1 == "tup" { print $3 }' "$1" |
		tr ' ' '\n' | grep -E '^build-' | sort -u
}

count_records() {
	awk -F'\t' -v name="$2" '$1 == name { n++ } END { print n + 0 }' "$1"
}

argv_of() {
	awk -F'\t' -v name="$2" '$1 == name { print $3 }' "$1"
}

# Assert that every record of $1 appears in $2 in the same relative order.
assert_subsequence() {
	local needle_file="$1" hay_file="$2" label="$3"
	local -a hay
	mapfile -t hay < <(normalized "$hay_file")
	local i=0 line missing=""
	while IFS= read -r line; do
		local found=""
		while [ "$i" -lt "${#hay[@]}" ]; do
			if [ "${hay[$i]}" = "$line" ]; then
				found=1
				i=$((i + 1))
				break
			fi
			i=$((i + 1))
		done
		if [ -z "$found" ]; then
			missing="$line"
			break
		fi
	done < <(normalized "$needle_file")

	if [ -n "$missing" ]; then
		fail "$label" "build.sh's trace does not contain build-once.sh's record
  '$missing'
at or after the position of the records before it.

build-once.sh trace:
$(normalized "$needle_file" | sed 's/^/    /')

build.sh trace:
$(normalized "$hay_file" | sed 's/^/    /')"
	else
		pass "$label"
	fi
}

# ---------------------------------------------------------------------------
# Port helpers
# ---------------------------------------------------------------------------

port_in_use() {
	if (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; then
		return 0
	fi
	return 1
}

find_free_port() {
	local port
	for port in $(seq 42731 42799); do
		if ! port_in_use "$port"; then
			printf '%s' "$port"
			return 0
		fi
	done
	echo "test-build-alignment.sh: could not find a free TCP port in 42731-42799" >&2
	return 1
}

# ---------------------------------------------------------------------------
# One scenario: run both scripts under the same host/config and compare.
# ---------------------------------------------------------------------------
run_scenario() {
	local label="$1" uname_s="$2" expected_branch="$3" expected_out_root="$4"
	shift 4
	local -a scenario_env=("$@")

	printf '\n  scenario: %s  (uname -s = %s, expect %s branch)\n' \
		"$label" "$uname_s" "$expected_branch"

	local port
	port="$(find_free_port)" || return 1

	local once_trace="$WORK_ROOT/$label.once.trace"
	local build_trace="$WORK_ROOT/$label.build.trace"
	local once_status build_status

	once_status="$(run_script build-once.sh "$once_trace" \
		"$WORK_ROOT/$label-once" "$uname_s" "$port" "${scenario_env[@]}")"
	build_status="$(run_script build.sh "$build_trace" \
		"$WORK_ROOT/$label-build" "$uname_s" "$port" "${scenario_env[@]}")"

	if [ "$once_status" != "0" ]; then
		fail "build-once.sh exits 0" "exit status $once_status
$(sed 's/^/    /' "$once_trace.out")"
		return 0
	fi
	pass "build-once.sh exits 0"

	if [ "$build_status" != "0" ]; then
		fail "build.sh exits 0" "exit status $build_status
$(sed 's/^/    /' "$build_trace.out")"
		return 0
	fi
	pass "build.sh exits 0"

	# --- (A) both scripts select the same host branch -----------------------
	# Observed through behaviour — which build driver ran — rather than by
	# looking for a variable name, which is what the old test did.
	local once_branch="" build_branch=""
	[ -n "$(first_index "$once_trace" tup)" ] && once_branch="tup"
	[ -n "$(first_index "$once_trace" repro)" ] && once_branch="repro"
	[ -n "$(first_index "$build_trace" tup)" ] && build_branch="tup"
	[ -n "$(first_index "$build_trace" repro)" ] && build_branch="repro"

	if [ "$once_branch" = "$expected_branch" ] && [ "$build_branch" = "$expected_branch" ]; then
		pass "(A) both scripts take the '$expected_branch' branch"
	else
		fail "(A) both scripts take the '$expected_branch' branch" \
			"build-once.sh took '${once_branch:-none}', build.sh took '${build_branch:-none}'"
	fi

	# --- (B) same tup variant -----------------------------------------------
	if [ "$expected_branch" = "tup" ]; then
		local once_variants build_variants
		once_variants="$(tup_variants "$once_trace")"
		build_variants="$(tup_variants "$build_trace")"
		if [ "$once_variants" = "$build_variants" ] && [ -n "$once_variants" ]; then
			pass "(B) same tup variant(s): $(printf '%s' "$once_variants" | tr '\n' ' ')"
		else
			fail "(B) same tup variant(s)" \
				"build-once.sh: [$(printf '%s' "$once_variants" | tr '\n' ' ')]
build.sh:      [$(printf '%s' "$build_variants" | tr '\n' ' ')]"
		fi

		# The two-pass structure is load-bearing: pass 2 is what lets tup see
		# the files webpack wrote into src/public/dist.
		local once_passes build_passes
		once_passes="$(awk -F'\t' '$1 == "tup" && $3 ~ /^build-/ { n++ } END { print n + 0 }' "$once_trace")"
		build_passes="$(awk -F'\t' '$1 == "tup" && $3 ~ /^build-/ { n++ } END { print n + 0 }' "$build_trace")"
		if [ "$once_passes" = "2" ] && [ "$build_passes" = "2" ]; then
			pass "(B') both scripts run two tup variant passes"
		else
			fail "(B') both scripts run two tup variant passes" \
				"build-once.sh ran $once_passes, build.sh ran $build_passes"
		fi
	fi

	# --- (C) build.sh does everything build-once.sh does, in order ----------
	assert_subsequence "$once_trace" "$build_trace" \
		"(C) build.sh's trace contains build-once.sh's trace, in order"

	# --- (D) THE ONE. No webpack before the first build driver. -------------
	local first_driver first_webpack
	first_driver="$(first_index "$build_trace" "$expected_branch")"
	first_webpack="$(first_index "$build_trace" webpack)"
	if [ -z "$first_webpack" ]; then
		fail "(D) no webpack invocation precedes the first $expected_branch invocation" \
			"build.sh never invoked webpack at all"
	elif [ -z "$first_driver" ]; then
		fail "(D) no webpack invocation precedes the first $expected_branch invocation" \
			"build.sh never invoked $expected_branch at all"
	elif [ "$first_webpack" -gt "$first_driver" ]; then
		pass "(D) no webpack invocation precedes the first $expected_branch invocation"
	else
		fail "(D) no webpack invocation precedes the first $expected_branch invocation" \
			"webpack ran at record $first_webpack, the first $expected_branch at record $first_driver.
This is issue #599: src/public/Tupfile:38 globs webpack's output directory
(\`: foreach dist/*\`), so a watcher writing into it while tup parses produces
a missing or half-written frontend_bundle.js.

build.sh trace:
$(normalized "$build_trace" | sed 's/^/    /')"
	fi

	# --- (E) the preflights and post-steps build.sh used to skip ------------
	local step
	local -a required_steps=(require-siblings build-tailwind)
	if [ "$expected_branch" = "tup" ]; then
		required_steps+=(require-fuse-mount-helper require-tup-globs post-build-setcap)
	fi
	for step in "${required_steps[@]}"; do
		if [ -n "$(first_index "$build_trace" "$step")" ]; then
			pass "(E) build.sh runs $step"
		else
			fail "(E) build.sh runs $step" \
				"absent from build.sh's trace; build-once.sh runs it, so \`just build\` must too"
		fi
	done

	# --- (F) watchers, and they watch the resolved output tree --------------
	local livereload_argv
	livereload_argv="$(argv_of "$build_trace" livereload)"
	if [ -z "$livereload_argv" ]; then
		fail "(F) build.sh starts livereload" "no livereload record"
	elif printf '%s' "$livereload_argv" | grep -qF -- "$expected_out_root"; then
		pass "(F) livereload watches $expected_out_root"
	else
		fail "(F) livereload watches $expected_out_root" "livereload argv: $livereload_argv"
	fi

	if [ "$expected_branch" = "tup" ]; then
		if argv_of "$build_trace" tup | grep -qE '(^| )monitor( |$)'; then
			pass "(F') build.sh starts tup monitor"
		else
			fail "(F') build.sh starts tup monitor" "no 'tup monitor' record"
		fi
	else
		if argv_of "$build_trace" repro | grep -qE '(^| )watch( |$)'; then
			pass "(F') build.sh starts repro watch"
		else
			fail "(F') build.sh starts repro watch" \
				"repro argv seen: $(argv_of "$build_trace" repro | tr '\n' '|')"
		fi
	fi

	# --- (G) build-once.sh starts NO watcher --------------------------------
	# `just build-once` must return; a watch-mode flag leaking into it would
	# make CI hang rather than fail.
	if argv_of "$once_trace" webpack | grep -q -- '--watch'; then
		fail "(G) build-once.sh starts no watcher" \
			"build-once.sh invoked webpack --watch: $(argv_of "$once_trace" webpack)"
	elif [ -n "$(first_index "$once_trace" livereload)" ]; then
		fail "(G) build-once.sh starts no watcher" "build-once.sh invoked livereload"
	else
		pass "(G) build-once.sh starts no watcher"
	fi
}

# ---------------------------------------------------------------------------
# The LiveReload port preflight (Tier 2, in miniature).
# ---------------------------------------------------------------------------
run_port_busy_scenario() {
	printf '\n  scenario: port-busy  (a leaked livereload holds the HMR port)\n'

	local port
	port="$(find_free_port)" || return 1

	local holder=""
	if command -v python3 >/dev/null 2>&1; then
		# The holder must ACCEPT and close each probe, not merely listen: with
		# an unserviced backlog the kernel starts dropping SYNs rather than
		# refusing them, and the second probe — build.sh's own — then looks
		# like a closed port.
		python3 -c "
import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $port))
s.listen(64)
s.settimeout(0.5)
sys.stdout.write('ready\n')
sys.stdout.flush()
deadline = time.time() + 120
while time.time() < deadline:
    try:
        conn, _ = s.accept()
        conn.close()
    except OSError:
        pass
" >"$WORK_ROOT/holder.out" 2>&1 &
		holder="$!"
		local waited=0
		while [ "$waited" -lt 100 ] && ! port_in_use "$port"; do
			sleep 0.05
			waited=$((waited + 1))
		done
	fi

	if [ -z "$holder" ] || ! port_in_use "$port"; then
		[ -n "$holder" ] && kill "$holder" 2>/dev/null
		printf '    skip port preflight check (no python3 to hold a listening socket)\n'
		return 0
	fi

	local trace="$WORK_ROOT/port-busy.trace" status
	status="$(run_script build.sh "$trace" "$WORK_ROOT/port-busy" Linux "$port")"
	kill "$holder" 2>/dev/null
	wait "$holder" 2>/dev/null

	if [ "$status" = "0" ]; then
		fail "(H) build.sh refuses to start when the LiveReload port is taken" \
			"build.sh exited 0"
		return 0
	fi
	pass "(H) build.sh refuses to start when the LiveReload port is taken"

	if grep -q "already in use" "$trace.out" && grep -q "$port" "$trace.out"; then
		pass "(H') the diagnostic names the port"
	else
		fail "(H') the diagnostic names the port" "$(sed 's/^/    /' "$trace.out")"
	fi

	# Refusing must happen BEFORE anything is built, or the developer pays for
	# a full build to learn about a stale daemon.
	if [ ! -s "$trace" ]; then
		pass "(H'') build.sh refuses before running any build step"
	else
		fail "(H'') build.sh refuses before running any build step" \
			"$(normalized "$trace" | sed 's/^/    /')"
	fi
}

# ---------------------------------------------------------------------------

echo "Build-alignment harness: executing scripts/build.sh and scripts/build-once.sh"
echo "under recording stubs, and comparing their traces."

run_scenario linux-legacy-debug Linux tup src/build-debug
run_scenario linux-legacy-release Linux tup src/build-release CODETRACER_CONFIG=release
run_scenario linux-reprobuild Linux repro src/build-debug-repro CODETRACER_REPROBUILD_LINUX=1
run_scenario darwin Darwin repro src/build-debug-repro
run_scenario windows MINGW64_NT-10.0-22631 repro src/build-debug-repro
run_port_busy_scenario

printf '\n%d checks, %d failure(s)\n' "$checks" "$failures"
if [ "$failures" -ne 0 ]; then
	exit 1
fi
