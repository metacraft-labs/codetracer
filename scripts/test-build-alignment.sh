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
	require-runtime-assets.sh
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
#
# The `$$` is matched WITHOUT anchoring to what follows it. It used to be
# anchored to `.sock`, which was right when the path was
# `.../codetracer-reprobuild-<pid>.sock`. build-once.sh then moved the socket
# into a directory of its own — `.../codetracer-reprobuild-<pid>/runquota.sock`,
# because runquotad refuses a world-writable rendezvous directory — and the
# anchored expression stopped matching. Nothing failed loudly: check (C) simply
# started comparing two traces that could never be equal, and reported
# `build.sh's trace does not contain build-once.sh's record 'runquotad ...'` in
# all three reprobuild scenarios. That is three of this harness's checks dead
# for as long as the socket path has had its current shape. Leave it unanchored
# so the next relocation cannot silently do it again.
normalized() {
	cut -f1,3 <"$1" | sed -E 's#(codetracer-reprobuild-)[0-9]+#\1<pid>#g'
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

	# `${a[@]+"${a[@]}"}`, not `"${a[@]}"`. Under `set -u` bash 3.2 -- which is
	# the ONLY bash on a stock macOS, at /bin/bash -- treats the expansion of an
	# EMPTY array as an unbound variable and aborts. The scenarios that pass no
	# trailing `K=V` overrides (linux-legacy-debug, darwin, windows) therefore
	# died here with `scenario_env[@]: unbound variable` before either script
	# ran, and reported `FAIL build-once.sh exits 0` with an EMPTY exit status --
	# a message that points at the code under test rather than at this harness.
	# The scenarios that do pass an override survived, so the harness looked
	# merely half-broken. scripts/build.sh:110 already uses this exact idiom.
	once_status="$(run_script build-once.sh "$once_trace" \
		"$WORK_ROOT/$label-once" "$uname_s" "$port" \
		${scenario_env[@]+"${scenario_env[@]}"})"
	build_status="$(run_script build.sh "$build_trace" \
		"$WORK_ROOT/$label-build" "$uname_s" "$port" \
		${scenario_env[@]+"${scenario_env[@]}"})"

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
	# `require-runtime-assets` is in the base list, not the tup-only one: the
	# assets `ct` reads on startup have to be in EVERY output tree, so both
	# branches run it. (It was added when a clean tup build was found to leave
	# `src/build-debug/config/` empty and `ct` unable to start.)
	local -a required_steps=(require-siblings build-tailwind require-runtime-assets)
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
		# `no livereload record` on its own is not enough to act on, and this
		# check has failed on the macOS CI runner in all three REPRO scenarios
		# while passing in both TUP scenarios -- deterministic by branch, not
		# flaky. It has NOT been reproduced on an idle developer m4: bash 5.3,
		# 3x-oversubscribed CPU load, and a util-linux-shaped `setsid` on PATH
		# were each tried and all pass there, so the trigger is something about
		# the CI host that is not yet identified.
		#
		# build.sh backgrounds livereload (scripts/build.sh:239) and, on the
		# repro branch ONLY, then calls build-once.sh and exits WITHOUT `wait`
		# -- the tup branch ends in `wait`, which is why that branch is immune.
		# The EXIT trap's cleanup then signals the watcher pids. So the two
		# things worth seeing are which watchers DID record, and whether
		# build.sh printed an exec failure.
		#
		# The captured output is otherwise unreachable: run_script sends it to
		# "$trace.out" and the harness only prints that when the exit status is
		# NON-ZERO -- and here build.sh exits 0. That is precisely why this
		# failure has been a single unactionable line.
		fail "(F) build.sh starts livereload" "no livereload record.
commands recorded by build.sh (name<TAB>argv):
$(cut -f1,3 <"$build_trace" | sed 's/^/    /')
build.sh stdout+stderr:
$(sed 's/^/    /' "$build_trace.out" 2>/dev/null | tail -n 25)"
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
# (I) Nim flag alignment: the tup lane vs the Nix lane.
#
# ## The defect this exists to catch
#
# `src/Tuprules.tup` defines NIM_COMMON_FLAGS, and EVERY tup Nim rule carries
# it: each macro (`!nim_js`, `!nim_node`, `!nim_node_index`, `!codetracer`,
# `!codetracer_bpf`, ...) expands `$(NIM_SELECTED)`, which is
# `$(NIM_BIN) $(NIM_DEBUG_FLAGS)`, and NIM_DEBUG_FLAGS opens with
# `$(NIM_COMMON_FLAGS)`. The Nix lane compiles the SAME sources
# (`src/frontend/ui_js.nim`, `src/ct/codetracer.nim`, ...) from hand-written
# flag lists in `nix/packages/default.nix` that were never derived from
# NIM_COMMON_FLAGS and share no mechanism with it.
#
# So a flag can be added to one lane and be silently absent from the other, and
# the lanes then disagree about the dialect they are compiling. That is not
# hypothetical. `-d:nimNoLentIterators` is in NIM_COMMON_FLAGS and in NONE of
# the Nix invocations, which is why `src/frontend/ui_js.nim` compiled green
# under tup and red under Nix: the failure arrived as an ordinary Nim error
# inside a store path, naming neither the lane, nor the flag, nor the fact that
# two lanes existed. `-d:nimOldCaseObjects` is missing from every Nix
# invocation in exactly the same way and has simply not been stepped on yet.
#
# ## Why a recorded baseline and not an equality assertion
#
# The two lanes are NOT equal today, and this script cannot make them equal:
# aligning them means editing the Nix derivations, and that edit is only
# provable by BUILDING them, which takes a warm store and minutes — the same
# reason `test-flake-pin-alignment.sh` is a static check. Asserting equality
# here would therefore either fail on mainline or force a fix nobody could
# verify from this harness.
#
# What this check does instead is pin the divergence to an exact, enumerated
# baseline. Every absence below is a fact about the tree, recorded rather than
# left silent. The check fails when the real divergence differs from the record
# in EITHER direction:
#
#   * a flag newly present in one lane and absent in the other (the regression
#     this exists to catch) adds a line the baseline does not have;
#   * a divergence that gets FIXED removes a line the baseline still has, so
#     the record cannot rot into a lie about a problem that is gone;
#   * a new Nix Nim invocation added with no baseline entry shows up as an
#     unrecorded target.
#
# Diagnostic-only flags (`--hint[...]`, `--warning[...]`, `--hints:`,
# `--warnings:`) are recorded on the same footing as semantic ones. They do not
# change generated code, but excluding them by category would mean this harness
# silently decided which divergences matter, and the whole point is that it
# decides nothing and reports everything.
# ---------------------------------------------------------------------------

# The backslash-continued value of NIM_COMMON_FLAGS, one flag per line, in
# source order. Continuation is detected by testing the last CHARACTER rather
# than with a `/\\$/` regex: awk reads that as an escaped `$`, i.e. "contains a
# literal dollar", which silently matches unrelated lines such as
# `ln -sf $out/nim/bin/nim $out/bin/nim2`.
tup_common_flags() {
	awk '
		function cont(s) { return substr(s, length(s), 1) == "\\" }
		$0 == "NIM_COMMON_FLAGS=\\" { inblock = 1; next }
		inblock {
			line = $0
			c = cont(line)
			if (c) { line = substr(line, 1, length(line) - 1) }
			gsub(/^[ \t]+|[ \t]+$/, "", line)
			if (line != "") { print line }
			if (!c) { exit }
		}
	' "$REPO_ROOT/src/Tuprules.tup"
}

# Each `nim2` invocation in the Nix packages, flattened to one line.
nix_nim_invocations() {
	awk '
		function cont(s) { return substr(s, length(s), 1) == "\\" }
		index($0, "bin/nim2") && cont($0) { inblock = 1; buf = ""; next }
		inblock {
			line = $0
			c = cont(line)
			if (c) { line = substr(line, 1, length(line) - 1) }
			gsub(/^[ \t]+|[ \t]+$/, "", line)
			buf = buf " " line
			if (!c) { print buf; inblock = 0 }
		}
	' "$REPO_ROOT/nix/packages/default.nix"
}

# `<nix target> <NIM_COMMON_FLAGS entry the Nix invocation does not carry>`
nim_flag_divergence_actual() {
	local block target tok flag found
	local -a toks common
	mapfile -t common < <(tup_common_flags)
	while IFS= read -r block; do
		read -r -a toks <<<"$block"
		target=""
		for tok in "${toks[@]}"; do
			case "$tok" in
			--out:*) target="${tok#--out:}" ;;
			esac
		done
		[ -n "$target" ] || continue
		for flag in "${common[@]}"; do
			found=0
			for tok in "${toks[@]}"; do
				if [ "$tok" = "$flag" ]; then
					found=1
					break
				fi
			done
			[ "$found" -eq 0 ] && printf '%s %s\n' "$target" "$flag"
		done
	done < <(nix_nim_invocations)
}

# The recorded divergence, as measured at b9677d24. See the header above for
# what a difference from this list means and how to respond to it.
nim_flag_divergence_recorded() {
	cat <<'RECORDED'
./index.js -d:asyncBackend=asyncdispatch
./index.js -d:chronicles_line_numbers=true
./index.js -d:chronicles_timestamps=UnixTime
./index.js -d:ssl
./index.js --mm:refc
./index.js -d:nimNoLentIterators
./index.js -d:nimOldCaseObjects
./index.js --hints:off
./index.js --hint[Processing]:off
./index.js --hint[Conf]:off
./index.js --hint[CC]:off
./index.js --hint[Pattern]:off
./index.js --hint[XDeclaredButNotUsed]:off
./index.js --hint[XCannotRaiseY]:off
./index.js --warning[CaseTransition]:off
./server_index.js -d:asyncBackend=asyncdispatch
./server_index.js -d:chronicles_line_numbers=true
./server_index.js -d:chronicles_timestamps=UnixTime
./server_index.js -d:ssl
./server_index.js --mm:refc
./server_index.js -d:nimNoLentIterators
./server_index.js -d:nimOldCaseObjects
./server_index.js --hints:off
./server_index.js --hint[Processing]:off
./server_index.js --hint[Conf]:off
./server_index.js --hint[CC]:off
./server_index.js --hint[Pattern]:off
./server_index.js --hint[XDeclaredButNotUsed]:off
./server_index.js --hint[XCannotRaiseY]:off
./server_index.js --warning[CaseTransition]:off
./subwindow.js -d:asyncBackend=asyncdispatch
./subwindow.js -d:chronicles_sinks=json
./subwindow.js -d:chronicles_line_numbers=true
./subwindow.js -d:chronicles_timestamps=UnixTime
./subwindow.js -d:ssl
./subwindow.js --mm:refc
./subwindow.js -d:nimNoLentIterators
./subwindow.js -d:nimOldCaseObjects
./subwindow.js --hint[Processing]:off
./subwindow.js --hint[Conf]:off
./subwindow.js --hint[CC]:off
./subwindow.js --hint[Pattern]:off
./subwindow.js --hint[XDeclaredButNotUsed]:off
./subwindow.js --hint[XCannotRaiseY]:off
./subwindow.js --warning[CaseTransition]:off
./ui.js -d:asyncBackend=asyncdispatch
./ui.js -d:chronicles_sinks=json
./ui.js -d:chronicles_line_numbers=true
./ui.js -d:chronicles_timestamps=UnixTime
./ui.js -d:ssl
./ui.js --mm:refc
./ui.js -d:nimNoLentIterators
./ui.js -d:nimOldCaseObjects
./ui.js --hint[Processing]:off
./ui.js --hint[Conf]:off
./ui.js --hint[CC]:off
./ui.js --hint[Pattern]:off
./ui.js --hint[XDeclaredButNotUsed]:off
./ui.js --hint[XCannotRaiseY]:off
./ui.js --warning[CaseTransition]:off
./console -d:asyncBackend=asyncdispatch
./console -d:chronicles_sinks=json
./console -d:chronicles_timestamps=UnixTime
./console -d:ssl
./console --mm:refc
./console -d:nimNoLentIterators
./console -d:nimOldCaseObjects
./console --hint[Processing]:off
./console --hint[Conf]:off
./console --hint[CC]:off
./console --hint[Pattern]:off
./console --hint[XDeclaredButNotUsed]:off
./console --hint[XCannotRaiseY]:off
./console --warning[CaseTransition]:off
ct -d:nimNoLentIterators
ct -d:nimOldCaseObjects
ct --hint[Processing]:off
ct --hint[Conf]:off
ct --hint[CC]:off
ct --hint[Pattern]:off
ct --hint[XCannotRaiseY]:off
ct --warning[CaseTransition]:off
db-backend-record -d:nimNoLentIterators
db-backend-record -d:nimOldCaseObjects
db-backend-record --hint[Processing]:off
db-backend-record --hint[Conf]:off
db-backend-record --hint[CC]:off
db-backend-record --hint[Pattern]:off
db-backend-record --hint[XCannotRaiseY]:off
db-backend-record --warning[CaseTransition]:off
RECORDED
}

run_nim_flag_alignment_check() {
	printf '\n  scenario: nim-flag-alignment (tup NIM_COMMON_FLAGS vs nix/packages/default.nix)\n'

	local common_count invocation_count
	common_count="$(tup_common_flags | grep -c .)"
	invocation_count="$(nix_nim_invocations | grep -c .)"

	# A parser that silently matches nothing would make every assertion below
	# vacuously true, so establish that both sides were actually read.
	if [ "$common_count" -gt 0 ]; then
		pass "(I) NIM_COMMON_FLAGS parsed from src/Tuprules.tup ($common_count flags)"
	else
		fail "(I) NIM_COMMON_FLAGS parsed from src/Tuprules.tup" \
			"parsed 0 flags -- the assignment moved or changed shape"
		return 0
	fi

	if [ "$invocation_count" -gt 0 ]; then
		pass "(I') nim invocations parsed from nix/packages/default.nix ($invocation_count)"
	else
		fail "(I') nim invocations parsed from nix/packages/default.nix" \
			"parsed 0 invocations -- the buildPhase shape changed"
		return 0
	fi

	local actual recorded delta
	actual="$(nim_flag_divergence_actual | sort)"
	recorded="$(nim_flag_divergence_recorded | sort)"

	if [ "$actual" = "$recorded" ]; then
		pass "(I'') tup/nix Nim flag divergence matches the recorded baseline"
	else
		delta="$(diff <(printf '%s\n' "$recorded") <(printf '%s\n' "$actual") |
			sed -n 's/^< /  no longer diverging (fix the baseline): /p;s/^> /  NEW divergence: /p')"
		fail "(I'') tup/nix Nim flag divergence matches the recorded baseline" "$delta"
	fi

	# Called out by name because it is the one that has already cost a debugging
	# session, and because a baseline is easy to regenerate without reading it.
	#
	# Matched against the captured string rather than through `| grep -q`: this
	# file runs under `set -o pipefail`, and `grep -q` closes the pipe as soon as
	# it matches, so the producer dies of SIGPIPE and the PIPELINE reports 141 --
	# a successful match reads as false, and the note silently never prints.
	case "$actual" in
	*'-d:nimNoLentIterators'*)
		printf '    note %s\n' \
			"-d:nimNoLentIterators is still absent from every nix Nim invocation (blocker (2))"
		;;
	esac
}

# ---------------------------------------------------------------------------
# (J) The io-mon sibling probe must name a module this repo actually imports.
# ---------------------------------------------------------------------------
#
# `scripts/require-siblings.sh`'s advisory tier exists to name, BEFORE any
# compile, the module that would otherwise fail to resolve. That only works if
# the probe tracks the import. It did not.
#
# The entry probed the `io_mon` umbrella (`src/io_mon.nim`), while every io-mon
# import in this repo is `io_mon/depfile` -- and io_mon_capture.nim:83 states
# outright that it must NOT import the umbrella. `src/io_mon.nim` has existed
# in io-mon forever, so an io-mon pinned before `depfile` landed (cfd2514,
# 2026-08-27) satisfied the probe, the advisory tier printed nothing, and the
# build died ~2000 lines later with `cannot open file: io_mon/depfile`. That is
# exactly how the published workspace lock for codetracer 0039436d -- which
# pins io-mon 8b6d0b9b (2026-07-31) -- shipped a tree that cannot build `ct`.
#
# So: derive the io-mon module set from the source, and require the probe to be
# one of them. A probe naming a module nothing imports cannot warn about the
# module that does.
run_sibling_probe_alignment_check() {
	local probe imported_modules

	# The probe column of the single `io-mon|...` table row. The surrounding
	# lines are comments, which cannot match the leading-quote anchor.
	probe="$(sed -n "s/^[[:space:]]*'io-mon|\([^|]*\)|.*/\1/p" \
		"$REPO_ROOT/scripts/require-siblings.sh")"

	# Every `io_mon/<module>` reached from this repo, rendered as the
	# repo-relative path shape the probe column uses.
	imported_modules="$(grep -rhoE '\bimport[[:space:]]+io_mon/[A-Za-z0-9_]+' \
		--include='*.nim' "$REPO_ROOT/src" 2>/dev/null |
		sed -E 's#.*import[[:space:]]+io_mon/#src/io_mon/#; s#$#.nim#' |
		LC_ALL=C sort -u)"

	if [ -z "$imported_modules" ]; then
		fail "(J) io-mon probe names a module this repo imports" \
			"no 'import io_mon/<module>' found under src/ -- nothing to align against"
		return
	fi

	# Membership by `case`, NOT `printf | grep -qxF`: this file runs under
	# `set -o pipefail`, and `grep -q` closes the pipe on its first match, so
	# the producer dies of SIGPIPE and the pipeline reports 141 -- a successful
	# match would read as a failure. Same trap the (I'') note above documents.
	case $'\n'"$imported_modules"$'\n' in
	*$'\n'"$probe"$'\n'*)
		pass "(J) require-siblings.sh probes an io-mon module this repo imports ($probe)"
		;;
	*)
		fail "(J) require-siblings.sh probes an io-mon module this repo imports" \
			"$(printf 'probe:    %s\nimported: %s' "$probe" \
				"$(printf '%s' "$imported_modules" | tr '\n' ' ')")"
		;;
	esac
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
run_nim_flag_alignment_check
run_sibling_probe_alignment_check

printf '\n%d checks, %d failure(s)\n' "$checks" "$failures"
if [ "$failures" -ne 0 ]; then
	exit 1
fi
