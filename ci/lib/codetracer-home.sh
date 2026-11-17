#!/usr/bin/env bash
#
# codetracer-home.sh — give a test lane (and everything it starts) a scratch
# `CODETRACER_HOME`.
#
# `CODETRACER_HOME` is the one variable every CodeTracer path resolver honours
# for EVERY per-user location — the trace index, recordings, config, state,
# caches and the tmp/socket directory — in Nim (`src/common/ct_home.nim`) and
# Rust (`libs/ct-home`), on every OS. Children inherit it, so a `cargo test`
# whose tests spawn `replay-server`, `ct-native-replay` or `ct` keeps all of
# them out of the developer's own profile. See codetracer-specs
# `spec/Architecture/Per-User-State-Locations.md`.
#
# Usage (source it, then call):
#   source ci/lib/codetracer-home.sh
#   ct_export_scratch_codetracer_home <label>
#   trap '_ct_rc=$?; ct_remove_scratch_codetracer_home <label>; ct_user_state_guard_exit <label> "$_ct_rc"' EXIT
#
# A caller that already exported a SCRATCH `CODETRACER_HOME` (inside the temp
# directory, or marked with a `.codetracer-test-home` file — the rule every
# test program applies) keeps it, so a lane started by another lane shares its root. The
# directory it CREATES is named in `ct_scratch_home_created` (empty when an
# inherited one was kept), so a lane removes only what it made:
# `ct_remove_scratch_codetracer_home`, below, from the EXIT trap.
#
# The export also STARTS the user-state guard below, and the trap's last
# command checks it: a lane whose tests all passed but which wrote the
# developer's real state (a resolver that ignores `CODETRACER_HOME`) fails.
#
# Deliberately NOT a `.cargo/config.toml` `[env]` entry: that would apply to a
# developer's own `cargo run` of `replay-server` too, and quietly move their
# real state into a temporary directory.

# shellcheck disable=SC2034 # ct_scratch_home_created is read by the caller's EXIT trap
ct_export_scratch_codetracer_home() {
	local label="${1:-lane}"
	# Before anything runs under the new home, so the "before" snapshot is the
	# developer's state as the lane found it.
	ct_user_state_guard_start
	local tmp="${TMPDIR:-/tmp}"
	tmp="${tmp%/}"
	ct_scratch_home_created=""
	case "${CODETRACER_HOME:-}" in
	"") ;;
	"${tmp}"/*)
		export CODETRACER_HOME
		return 0
		;;
	*)
		if [ -f "${CODETRACER_HOME}/.codetracer-test-home" ]; then
			export CODETRACER_HOME
			return 0
		fi
		;;
	esac
	ct_scratch_home_created="$(mktemp -d "${tmp}/ct-home-${label}.XXXXXX")" || return 1
	# The line that matters: ct_home_isolation_test pins it verbatim.
	export CODETRACER_HOME="${ct_scratch_home_created}"
}

# REMOVING THE HOME: every entry point that exports a scratch home removes the
# one it made from its EXIT trap, by calling this. Until 2026-11-11 the two
# Windows lanes (ci/test/windows-headless-tests.sh,
# ci/test/windows-rust-components-tests.sh) left theirs in place on purpose,
# because a Windows process still holding a file in it would have made a plain
# `rm -rf` fail the run, so every run left a `ct-home-<label>.*` in the
# runner's temp directory for good; on a persistent self-hosted runner that
# only grows. This one never fails the caller: it retries for a few seconds
# (the process holding the file is usually exiting) and then says what it
# could not remove. `CT_KEEP_SCRATCH_HOME=1` keeps the home for debugging
# (what a recording, a replay or the GUI left there) and says where it is.
# ci/test/lane-user-state-guard-test.sh fails an entry point that exports a
# home and does not call this, and drives all three outcomes.
ct_remove_scratch_codetracer_home() {
	local label="${1:-lane}" d="${ct_scratch_home_created:-}" _
	[ -n "${d}" ] && [ -e "${d}" ] || return 0
	if [ "${CT_KEEP_SCRATCH_HOME:-}" = 1 ]; then
		echo "${label}: CT_KEEP_SCRATCH_HOME=1: kept the scratch CODETRACER_HOME ${d}" >&2
		return 0
	fi
	for _ in 1 2 3 4 5; do
		# `|| :`: the caller's trap may run under `set -e`, and a failed
		# removal must not end it before the guard has been checked.
		rm -rf "${d}" 2>/dev/null || :
		[ -e "${d}" ] || return 0
		sleep 1
	done
	echo "WARNING: ${label}: could not remove the scratch CODETRACER_HOME ${d}" \
		"(a process may still hold a file in it); remove it by hand" >&2
	return 0
}

# THE USER-STATE GUARD: read the developer's own CodeTracer state before a
# test lane and after it, and fail the lane when anything there changed.
#
# `CODETRACER_HOME` (the function above, src/common/ct_home.nim, libs/ct-home)
# keeps every resolver that honours it out of the developer's
# profile. This is the check that catches a resolver that does NOT honour it —
# in this repository, in a sibling's binary a test spawns, or in a CI script —
# by looking at the real directories instead of trusting the variable:
#
#   ~/.local/state/codetracer   every file, by checksum
#   ~/.config/codetracer        every file, by checksum
#   ~/.local/share/codetracer   the trace index (`trace_index.db*`) by
#                               checksum; every other entry (a recording can be
#                               gigabytes) by NAME
#   ~/.cache/codetracer         every file, by NAME: a cache entry that
#                               appears or disappears is the damage that
#                               matters, and its bytes are re-fetchable
#
# Only files are compared, never listings or directory times, which move
# without any file changing. A file that APPEARED, whose bytes CHANGED, or that
# DISAPPEARED fails the check: a deletion is damage too.
#
# WHY ~/.cache/codetracer IS HERE. On 2026-11-02 two lanes wrote it while
# every lane already ran under a scratch `CODETRACER_HOME`: `ct-mcr record`
# (codetracer-native-recorder) put eleven library-family lists into
# `~/.cache/codetracer/sync-families`, from the `test-rust` lane, and
# `ci/test/cua-keymap-extractor.sh` put the VS Code 1.105.0 sources into
# `~/.cache/codetracer/vscode-484fdf69`, from `ci/lint/nim.sh`. This guard
# covered neither the directory nor those two entry points, so both went
# unreported until a developer found the files.
#
# The directories are the DEFAULT, home-relative locations, read from `HOME` as
# it is when the guard starts. That is where an unisolated resolver writes on
# a developer's machine and on a CI runner alike; a lane that has already
# redirected `HOME` guards that home instead, which is the same check.
#
# Someone else changing CodeTracer state on this machine while a lane runs
# (using CodeTracer, clearing stale state by hand) trips it as well. The
# message says so; the remedy is to rerun on a quiet host.
#
# Usage (source this file, then):
#   ct_user_state_guard_start                  # take the "before" snapshot
#   ... run the lane ...
#   ct_user_state_guard_check <label>          # 0 unchanged, 1 changed (reported)
#
# or, in a script that ends through an EXIT trap, as the trap's LAST command
# (it keeps the script's own exit status when the guard passes):
#   trap '_ct_rc=$?; <cleanup>; ct_user_state_guard_exit <label> "$_ct_rc"' EXIT
#
# `ct_export_scratch_codetracer_home` starts the guard, so every entry point
# that exports a scratch home only has to check it.
# ci/test/lane-user-state-guard-test.sh holds both halves to account, and fails
# if an entry point exports a scratch home without checking the guard.

ct_user_state_guard_dirs() {
	# The four guarded directories, one per line, in a fixed order.
	local home="${_ct_usg_home:-${HOME:-/nonexistent}}"
	printf '%s\n' "${home}/.local/state/codetracer" "${home}/.config/codetracer" \
		"${home}/.local/share/codetracer" "${home}/.cache/codetracer"
}

ct_user_state_guard_dirs_text() {
	# The directories as one comma-separated phrase, for messages.
	local out="" d
	while IFS= read -r d; do
		out="${out:+${out}, }${d}"
	done < <(ct_user_state_guard_dirs)
	printf '%s' "${out}"
}

ct_user_state_snapshot() {
	# One line per file: `<cksum> <size> <path>`, or `- - <path>` for a file
	# compared by name only; sorted by path within each directory. `cksum`
	# rather than a GNU-only tool: this also runs on macOS.
	#
	# A directory the per-run sandbox below covers is left out: no test can
	# write it, and reading it would only report the OTHER processes on the
	# host that wrote it meanwhile.
	local state config data cache
	{
		read -r state
		read -r config
		read -r data
		read -r cache
	} < <(ct_user_state_guard_dirs)
	ct_user_state_sandbox_covers "${state}" && state=""
	ct_user_state_sandbox_covers "${config}" && config=""
	ct_user_state_sandbox_covers "${data}" && data=""
	ct_user_state_sandbox_covers "${cache}" && cache=""
	local _dir
	for _dir in "${state}" "${config}"; do
		if [ -n "${_dir}" ] && [ -d "${_dir}" ]; then
			find "${_dir}" -type f -print0 2>/dev/null | sort -z |
				xargs -0 -r cksum 2>/dev/null
		fi
	done
	if [ -n "${data}" ] && [ -d "${data}" ]; then
		find "${data}" -maxdepth 1 -type f -name 'trace_index.db*' \
			-print0 2>/dev/null | sort -z | xargs -0 -r cksum 2>/dev/null
		find "${data}" -mindepth 1 -maxdepth 1 ! -name 'trace_index.db*' \
			-print 2>/dev/null | sort | sed 's/^/- - /'
	fi
	if [ -n "${cache}" ] && [ -d "${cache}" ]; then
		find "${cache}" -type f -print 2>/dev/null | sort | sed 's/^/- - /'
	fi
}

# THE PER-RUN SANDBOX (Linux): run a test where it can READ the user's state
# but every write lands in a private copy-on-write layer.
#
# The snapshot comparison above reads directories every process on the host
# shares. A test file is blamed for whatever changed there while it ran, so a
# `ct-mcr record` started by another checkout's tests (or by hand) on the same
# host failed whichever file happened to be running: on 2026-11-04 two GPUI
# suites that never start a recorder were reported for library-family lists
# another process wrote to `~/.cache/codetracer/sync-families`. CI runs lanes
# side by side on one runner too, so the comparison could not say which lane
# wrote.
#
# So each run gets its own mount namespace with an overlay on every guarded
# directory: the real directory is the read-only lower layer, a scratch
# directory is the upper one. The test sees the user's real files; what it
# creates, rewrites or deletes lands in ITS upper layer and never reaches the
# real directory; and the finding is read from that layer, which no other
# process can touch. The run keeps the user's uid (a second user namespace
# maps it back), so the nix daemon, rr and file ownership behave as outside.
#
# A guarded directory that does not exist yet is covered through its parent
# (an overlay needs an existing mount point), and only its `codetracer`
# entry is read back. One with no parent either, and every directory on a
# host without unprivileged user namespaces or overlayfs (macOS; a kernel or
# AppArmor policy that refuses them), stays with the snapshot comparison.
# `ct_user_state_sandbox_enable` proves the mechanism on a scratch tree before
# it is trusted, so a host where it silently does nothing is never taken for
# one where it works.
#
# It then mounts each REAL directory a run will mount, the same way, because
# the scratch tree cannot stand in for them. In the sandbox's new user
# namespace every mount inherited from the host is locked, and the kernel
# refuses a lower layer that has a locked mount beneath it ("overlayfs: failed
# to clone lowerpath"; `mount` itself says only "wrong fs type, bad option").
# A missing `~/.local/state/codetracer` puts the overlay on `~/.local/state`,
# and a host that bind-mounts anything under it (agent-harbor mounts its own
# directories under `~/.config`, `~/.cache` and `~/.local/share`) then failed
# every file of a lane before it ran, as "DID NOT RUN (exit 32)", on
# nixos-ci-bare-004 (codetracer-specs issue
# `2026-11-15-user-state-sandbox-probe-passes-on-tmp-and-every-lane-file-fails-to-mount-on-zfs-home.md`).
# A directory whose overlay is refused stays with the snapshot comparison
# instead, named in one line; the others stay sandboxed.

_ct_uss_enabled=""
_ct_uss_guarded=()
_ct_uss_mounts=()
_ct_uss_subs=()
_ct_uss_layer=()

# THE RUNQUOTA ENDPOINT INSIDE THE SANDBOX (Linux): forwarded through a private
# relay that the caller owns, started OUTSIDE the sandbox.
#
# The sandbox maps only the caller's own uid and gid, so every file another
# account owns reads as the overflow id (65534) inside it. The provisioned
# RunQuota endpoint, `/run/runquota`, belongs to the `runquota` account, and
# RunQuota refuses a rendezvous directory whose owner is not the configured
# daemon owner: inside the sandbox it cannot tell the real `runquota` account
# from any other unmapped user, so every `repro exec` a sandboxed entry point
# started was refused (codetracer-specs issue
# `2026-11-15-user-state-sandbox-hides-the-runquota-endpoint-owner-so-repro-exec-is-refused.md`).
# Relaxing that check, or starting a per-user daemon instead, is ruled out by
# reprobuild-specs `spec/RunQuota-Host-Configuration.md`, "Explicit private
# endpoint policy (POSIX)": an untrusted host endpoint keeps its refusal.
#
# So the trust decision is made where the owner IS visible, outside, and by
# RunQuota itself rather than by a copy of its rules here:
#
#   1. The endpoint is resolved as `runquota_ipc.defaultEndpoint` resolves it
#      on POSIX: `RUNQUOTA_SOCKET`, else `/run/runquota/runquotad.sock`
#      (`hostWideEndpointDir / endpointSocketName`). Nothing is done when it
#      does not exist, or when it and its directory are the caller's own uid
#      and gid: then they read the same inside, and the sandbox behaves as it
#      always did.
#   2. The endpoint's DIRECTORY is PINNED (device, inode, owner, group, mode),
#      with the socket's owner, group and mode beside it; `runquota status` is
#      run against the endpoint from outside, and both are read again; any
#      change in between forwards nothing. (The pin cannot prove which inode
#      RunQuota inspected meanwhile: swapping another directory in and back
#      needs write access to the parent and a directory the daemon account
#      owns to swap in, and RunQuota's own inspect-then-connect has the same
#      window under a writable parent.) A refusal, an endpoint that
#      does not answer, or no `runquota` on PATH means NO relay; the sandboxed
#      run then meets the same refusal it would meet outside, and one line
#      here says why.
#   3. The relay (below) listens in a fresh `mktemp -d` directory, mode 0700,
#      socket 0600, both the caller's: exactly the private policy's endpoint.
#      For each connection it checks the directory against the pin (any change
#      refuses that connection) and connects through a descriptor of the pinned
#      directory, so a directory swapped in after the check is never the one
#      used.
#
#      THE DIRECTORY IS THE TRUST ANCHOR, NOT THE SOCKET'S INODE. RunQuota
#      accepted a directory owned by the configured daemon account and not
#      writable by group or others, so only that account (or root) can put a
#      socket in it. A daemon that restarts binds a NEW socket there, and the
#      run must go on reaching it, as it would outside; pinning the socket's
#      inode refused every connection after a restart. What is checked of the
#      socket, through the directory descriptor and without following a link,
#      is what tells the daemon's socket from something else in its place: it
#      is a socket, it has the directory's owner and group, and it has the mode
#      it had when RunQuota verified it.
#   4. The sandboxed command gets `RUNQUOTA_SOCKET=<relay socket>` and
#      `RUNQUOTA_ENDPOINT_SCOPE=private`, the policy's "the caller runs its own
#      endpoint at RUNQUOTA_SOCKET" case. The daemon sees the relay's peer
#      credentials, which are the caller's own, so per-user attribution is
#      unchanged.
#
# The relay is python3 (stdlib only, `-I -S`), because every shell these entry
# points run in carries it, and a byte pump with half-close, a per-connection
# `lstat` and a connect through a directory descriptor is not expressible in
# bash; socat would need its own pin hook and is not in every shell. It lives
# only as long as the shell that started it: `ct_user_state_sandbox_stop` ends
# it, and if that shell dies first the kernel's parent-death signal does
# (PR_SET_PDEATHSIG, with a parent poll as the fallback). Either way it removes
# its directory on the way out.

_ct_uss_relay_pid=""
_ct_uss_relay_owner=""
_ct_uss_relay_dir=""
_ct_uss_relay_env=()

# shellcheck disable=SC2016 # python source, not shell
_ct_uss_relay_program='import os, signal, socket, stat, sys, threading
name, parent, endpoint, relay_dir, dir_pin, sock_mode = sys.argv[1:7]
parent = int(parent)
directory, base = os.path.split(endpoint)
listen_path = os.path.join(relay_dir, "rq.sock")

def say(text):
    try:
        sys.stderr.write(name + ": " + text + "\n")
        sys.stderr.flush()
    except OSError:
        pass

def finish(*_):
    for path in (listen_path, listen_path + ".tmp"):
        try:
            os.unlink(path)
        except OSError:
            pass
    try:
        os.rmdir(relay_dir)
    except OSError:
        pass
    os._exit(0)

for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGPIPE):
    signal.signal(sig, finish)
try:
    import ctypes
    ctypes.CDLL(None).prctl(1, int(signal.SIGTERM), 0, 0, 0)  # PR_SET_PDEATHSIG
except Exception:
    pass  # the parent poll in the accept loop still ends the relay
if os.getppid() != parent:
    finish()

def pin(st):
    # The same fields, in the same form, as `stat -c "%d %i %u %g %f"`.
    return "%d %d %d %d %x" % (st.st_dev, st.st_ino, st.st_uid, st.st_gid, st.st_mode)

try:
    dir_fd = os.open(directory, os.O_PATH | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
except OSError as error:
    say("cannot open the endpoint directory %s: %s" % (directory, error))
    finish()
via = "/proc/self/fd/%d/%s" % (dir_fd, base)

dir_uid, dir_gid = (int(field) for field in dir_pin.split()[2:4])

def changed():
    # Empty when the endpoint is still in the directory RunQuota verified,
    # and its socket is one only the owner of the directory could have put there.
    try:
        if pin(os.fstat(dir_fd)) != dir_pin or pin(os.lstat(directory)) != dir_pin:
            return "its directory %s was replaced or changed" % directory
    except OSError as error:
        return "its directory %s can no longer be inspected (%s)" % (directory, error)
    try:
        st = os.stat(base, dir_fd=dir_fd, follow_symlinks=False)
    except OSError as error:
        return "its socket %s cannot be inspected (%s)" % (endpoint, error)
    if not stat.S_ISSOCK(st.st_mode):
        return "its socket %s is not a socket" % endpoint
    if (st.st_uid, st.st_gid) != (dir_uid, dir_gid):
        return "its socket %s is owned by %d:%d, not by the directory owner %d:%d" % (
            endpoint, st.st_uid, st.st_gid, dir_uid, dir_gid)
    if "%x" % st.st_mode != sock_mode:
        return "its socket %s has mode %o, not the %o it had when RunQuota verified it" % (
            endpoint, stat.S_IMODE(st.st_mode), stat.S_IMODE(int(sock_mode, 16)))
    return ""

why = changed()
if why:
    say("the RunQuota endpoint changed before the relay started (%s); not relaying" % why)
    finish()

def pump(source, sink):
    try:
        while True:
            data = source.recv(65536)
            if not data:
                break
            sink.sendall(data)
    except OSError:
        pass
    try:
        sink.shutdown(socket.SHUT_WR)
    except OSError:
        pass

def serve(client):
    try:
        why = changed()
        if why:
            say("refusing a connection: the RunQuota endpoint %s changed since "
                "RunQuota verified it (%s)" % (endpoint, why))
            return
        upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            upstream.connect(via)
        except OSError as error:
            upstream.close()
            say("cannot reach the RunQuota endpoint %s: %s" % (endpoint, error))
            return
        back = threading.Thread(target=pump, args=(upstream, client), daemon=True)
        back.start()
        pump(client, upstream)
        back.join()
        upstream.close()
    finally:
        client.close()

os.umask(0o077)
listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
listener.bind(listen_path + ".tmp")
os.chmod(listen_path + ".tmp", 0o600)
listener.listen(64)
# Published under its final name only once it is listening and 0600.
os.rename(listen_path + ".tmp", listen_path)
listener.settimeout(0.5)
while True:
    if os.getppid() != parent:
        finish()
    try:
        client, _ = listener.accept()
    except socket.timeout:
        continue
    except OSError:
        continue
    client.settimeout(None)
    threading.Thread(target=serve, args=(client,), daemon=True).start()
'

_ct_uss_pin() {
	# The identity a relay is held to: device, inode, owner, group and raw
	# mode of `$1`, not following a symbolic link.
	stat -c '%d %i %u %g %f' -- "$1" 2>/dev/null
}

ct_user_state_sandbox_stop() {
	# End this shell's relay (see above) and remove its directory. A subshell
	# that inherited the variables forgets them and leaves its parent's relay
	# alone.
	if [ -n "${_ct_uss_relay_pid}" ] && [ "${_ct_uss_relay_owner}" = "${BASHPID}" ]; then
		kill -TERM "${_ct_uss_relay_pid}" 2>/dev/null || :
		for _ in $(seq 1 40); do
			kill -0 "${_ct_uss_relay_pid}" 2>/dev/null || break
			sleep 0.05
		done
		kill -KILL "${_ct_uss_relay_pid}" 2>/dev/null || :
		wait "${_ct_uss_relay_pid}" 2>/dev/null || :
		[ -z "${_ct_uss_relay_dir}" ] || rm -rf "${_ct_uss_relay_dir}"
	fi
	_ct_uss_relay_pid=""
	_ct_uss_relay_owner=""
	_ct_uss_relay_dir=""
	_ct_uss_relay_env=()
}

_ct_uss_relay_start() {
	# Steps 1-3 above, for caller uid `$1` and gid `$2`. Sets
	# `_ct_uss_relay_env` to the assignments the sandboxed command gets, or
	# leaves it empty when nothing is forwarded. Always returns 0: a relay
	# that is not started leaves the run exactly as it was without one.
	local uid="$1" gid="$2" note="user-state sandbox"
	ct_user_state_sandbox_stop
	local endpoint="${RUNQUOTA_SOCKET:-/run/runquota/runquotad.sock}"
	case "${endpoint}" in
	/*) ;;
	*) return 0 ;; # repro and runquota refuse it themselves, by name
	esac
	[ -S "${endpoint}" ] || return 0
	local directory="${endpoint%/*}"
	[ -n "${directory}" ] || directory=/
	local dir_pin sock_pin sock_mode
	dir_pin="$(_ct_uss_pin "${directory}")" || return 0
	sock_pin="$(_ct_uss_pin "${endpoint}")" || return 0
	# `<dev> <ino> <uid> <gid> <mode>`: owned by the caller in both, as the
	# caller's own daemon's endpoint is, reads the same inside.
	local d_uid d_gid s_uid s_gid
	read -r _ _ d_uid d_gid _ <<<"${dir_pin}"
	read -r _ _ s_uid s_gid _ <<<"${sock_pin}"
	if [ "${d_uid}:${d_gid}:${s_uid}:${s_gid}" = "${uid}:${gid}:${uid}:${gid}" ]; then
		return 0
	fi
	if ! command -v runquota >/dev/null 2>&1; then
		echo "${note}: not forwarding the RunQuota endpoint ${endpoint}: no \`runquota\` on PATH to verify it" >&2
		return 0
	fi
	if ! command -v python3 >/dev/null 2>&1; then
		echo "${note}: not forwarding the RunQuota endpoint ${endpoint}: no python3 on PATH for the relay" >&2
		return 0
	fi
	local refusal
	if ! refusal="$(timeout 20 runquota status 2>&1)"; then
		echo "${note}: not forwarding the RunQuota endpoint ${endpoint}: RunQuota refuses it outside the sandbox too: $(printf '%s' "${refusal}" | tr '\n' ' ')" >&2
		return 0
	fi
	# The directory exactly; the socket by owner, group and mode only, the
	# fields the relay holds it to (a daemon that restarted meanwhile is fine).
	# `|| now=""`: a socket that vanished meanwhile is a change, and under a
	# caller's `set -e` a failed substitution must not end the caller instead.
	local now
	now="$(_ct_uss_pin "${endpoint}")" || now=""
	if [ "$(_ct_uss_pin "${directory}")" != "${dir_pin}" ] ||
		[ "${now#* * }" != "${sock_pin#* * }" ]; then
		echo "${note}: not forwarding the RunQuota endpoint ${endpoint}: it changed while RunQuota verified it" >&2
		return 0
	fi
	# Every connection requires the socket to carry the directory's owner and
	# group (only the directory's owner can have put it there); one that does
	# not now would be refused on every connection, so it is not relayed.
	if [ "${d_uid}:${d_gid}" != "${s_uid}:${s_gid}" ]; then
		echo "${note}: not forwarding the RunQuota endpoint ${endpoint}: its socket is owned by ${s_uid}:${s_gid}, not by the directory owner ${d_uid}:${d_gid}" >&2
		return 0
	fi
	read -r _ _ _ _ sock_mode <<<"${sock_pin}"
	# A socket path is limited to 108 bytes, so a long TMPDIR gives way to
	# /tmp; the private policy only needs the directory to be the caller's,
	# mode 0700, outside the host rendezvous directory.
	local base="${TMPDIR:-/tmp}"
	base="${base%/}"
	[ "${#base}" -le 80 ] || base=/tmp
	_ct_uss_relay_dir="$(mktemp -d "${base}/ct-uss-rq.XXXXXX")" || {
		_ct_uss_relay_dir=""
		echo "${note}: not forwarding the RunQuota endpoint ${endpoint}: cannot create a relay directory under ${base}" >&2
		return 0
	}
	chmod 0700 "${_ct_uss_relay_dir}"
	# Read here: in the arguments of a background command `BASHPID` would be
	# expanded in the forked child, i.e. it would be the relay's own pid.
	_ct_uss_relay_owner="${BASHPID}"
	python3 -I -S -c "${_ct_uss_relay_program}" ct-uss-runquota-relay "${_ct_uss_relay_owner}" \
		"${endpoint}" "${_ct_uss_relay_dir}" "${dir_pin}" "${sock_mode}" </dev/null >/dev/null &
	_ct_uss_relay_pid=$!
	for _ in $(seq 1 100); do
		[ -S "${_ct_uss_relay_dir}/rq.sock" ] && break
		kill -0 "${_ct_uss_relay_pid}" 2>/dev/null || break
		sleep 0.05
	done
	# Owned by this process's own effective uid, which the sandbox maps to the
	# uid its command runs as, so inside it reads as the caller's own.
	if [ ! -S "${_ct_uss_relay_dir}/rq.sock" ] ||
		[ "$(stat -c '%u %a' -- "${_ct_uss_relay_dir}")" != "${EUID} 700" ] ||
		[ "$(stat -c '%u %a' -- "${_ct_uss_relay_dir}/rq.sock")" != "${EUID} 600" ]; then
		echo "${note}: not forwarding the RunQuota endpoint ${endpoint}: the relay did not come up as a private endpoint in ${_ct_uss_relay_dir}" >&2
		ct_user_state_sandbox_stop
		return 0
	fi
	_ct_uss_relay_env=("RUNQUOTA_SOCKET=${_ct_uss_relay_dir}/rq.sock" RUNQUOTA_ENDPOINT_SCOPE=private)
	echo "${note}: forwarding the RunQuota endpoint ${endpoint}, verified by RunQuota outside the sandbox, through the private relay ${_ct_uss_relay_dir}/rq.sock" >&2
}

ct_user_state_sandbox_covers() {
	# 0 when the sandbox covers guarded directory `$1`: this shell's own, or
	# the stage sandbox this shell runs inside (`ct_user_state_stage_sandbox`,
	# which names its directories in CT_USS_STAGE_COVERED, one per line).
	local d
	if [ -n "${CT_USS_STAGE_COVERED:-}" ]; then
		while IFS= read -r d; do
			[ "${d}" = "$1" ] && return 0
		done <<<"${CT_USS_STAGE_COVERED}"
	fi
	[ -n "${_ct_uss_enabled}" ] || return 1
	for d in "${_ct_uss_guarded[@]}"; do
		[ "${d}" = "$1" ] && return 0
	done
	return 1
}

# The namespace entry, as one `bash -c` program: mount each overlay given as
# `<lower> <upper> <work>` triples up to `--`, then re-enter as the caller's
# own uid and gid and exec the command.
# shellcheck disable=SC2016 # expanded by the inner shell, not here
_ct_uss_entry='set -e
while [ "$1" != -- ]; do
	mount -t overlay overlay -o "lowerdir=$1,upperdir=$2,workdir=$3" "$1"
	shift 3
done
shift
exec unshare --user --map-user="${CT_USS_UID}" --map-group="${CT_USS_GID}" -- "$@"'

# The probe of the real mount points, as one `bash -c` program: mount each
# overlay given as `<lower> <upper> <work>` triples, in order and in one
# namespace, as `_ct_uss_entry` will, and print each lower layer the kernel
# refused, one per line. Nothing runs over the mounts and they go with the
# namespace.
# shellcheck disable=SC2016 # expanded by the inner shell, not here
_ct_uss_probe_mounts='while [ $# -ge 3 ]; do
	mount -t overlay overlay -o "lowerdir=$1,upperdir=$2,workdir=$3" "$1" 2>/dev/null ||
		printf "%s\n" "$1"
	shift 3
done'

_ct_uss_mounts_beneath() {
	# The mount points strictly beneath directory `$1`, one per line, from
	# this process's mount table (octal escapes such as `\040` decoded). Only
	# for the message that names a refused directory.
	local dir
	dir="$(cd -P -- "$1" 2>/dev/null && pwd)" || return 0
	local mp
	while read -r _ _ _ _ mp _; do
		mp="$(printf '%b' "${mp}")"
		case "${mp}" in
		"${dir}"/*) printf '%s\n' "${mp}" ;;
		esac
	done </proc/self/mountinfo 2>/dev/null | sort -u
}

ct_user_state_sandbox_enable() {
	# Decide, once per lane, whether runs are sandboxed. Opt out with
	# CT_USER_STATE_SANDBOX=0. Returns 0 when the sandbox is on.
	ct_user_state_sandbox_stop
	_ct_uss_enabled=""
	_ct_uss_guarded=()
	_ct_uss_mounts=()
	_ct_uss_subs=()
	[ "${CT_USER_STATE_SANDBOX:-1}" != 0 ] || return 1
	[ "$(uname -s)" = Linux ] || return 1
	command -v unshare >/dev/null 2>&1 || return 1
	local probe
	probe="$(mktemp -d "${TMPDIR:-/tmp}/ct-uss-probe.XXXXXX")" || return 1
	mkdir -p "${probe}/lower" "${probe}/up/0" "${probe}/work/0"
	echo user >"${probe}/lower/kept"
	local uid gid
	uid="$(id -u)"
	gid="$(id -g)"
	# The probe is the real thing: read a file through the overlay, write
	# one, and report the uid it ran as. It works only when the write reached
	# the upper layer, not the lower one, and the uid is the caller's.
	local seen
	# shellcheck disable=SC2016 # $1 is the probe program's own argument
	seen="$(CT_USS_UID="${uid}" CT_USS_GID="${gid}" unshare --user \
		--map-root-user --mount bash -c "${_ct_uss_entry}" ct-user-state-sandbox \
		"${probe}/lower" "${probe}/up/0" "${probe}/work/0" -- \
		sh -c 'cat "$1/kept" && echo x >"$1/new" && id -u' sh "${probe}/lower" \
		2>/dev/null)" || seen=""
	local ok=""
	if [ "${seen}" = "user
${uid}" ] && [ -f "${probe}/up/0/new" ] && [ ! -e "${probe}/lower/new" ]; then
		ok=1
	fi
	if [ -z "${ok}" ]; then
		chmod -R u+rwx "${probe}" 2>/dev/null
		rm -rf "${probe}"
		return 1
	fi
	# Where each guarded directory would be mounted: itself, or its parent
	# when it does not exist yet.
	local d parent guarded=() mounts=() subs=()
	while IFS= read -r d; do
		parent="$(dirname "${d}")"
		if [ -d "${d}" ]; then
			guarded+=("${d}")
			mounts+=("${d}")
			subs+=("")
		elif [ -d "${parent}" ]; then
			guarded+=("${d}")
			mounts+=("${parent}")
			subs+=("$(basename "${d}")")
		fi
	done < <(ct_user_state_guard_dirs)
	# Each distinct mount point once, in first-use order, as
	# `ct_user_state_sandbox_prefix` mounts them.
	local i k seen_mount targets=() args=()
	for i in "${!mounts[@]}"; do
		seen_mount=""
		for k in "${targets[@]}"; do
			[ "${k}" = "${mounts[$i]}" ] && seen_mount=1 && break
		done
		[ -n "${seen_mount}" ] && continue
		k="${#targets[@]}"
		targets+=("${mounts[$i]}")
		mkdir -p "${probe}/real-up/${k}" "${probe}/real-work/${k}"
		args+=("${mounts[$i]}" "${probe}/real-up/${k}" "${probe}/real-work/${k}")
	done
	local refused=""
	if [ "${#args[@]}" -gt 0 ]; then
		refused="$(unshare --user --map-root-user --mount bash -c \
			"${_ct_uss_probe_mounts}" ct-user-state-sandbox-probe "${args[@]}" \
			2>/dev/null)" || refused="$(printf '%s\n' "${targets[@]}")"
	fi
	chmod -R u+rwx "${probe}" 2>/dev/null
	rm -rf "${probe}"
	local target is_refused left beneath mp n
	for target in "${targets[@]}"; do
		is_refused=""
		while IFS= read -r k; do
			[ "${k}" = "${target}" ] && is_refused=1
		done <<<"${refused}"
		[ -n "${is_refused}" ] || continue
		left=""
		for i in "${!mounts[@]}"; do
			[ "${mounts[$i]}" = "${target}" ] && left="${left:+${left}, }${guarded[$i]}"
		done
		# The first three, and how many more: a host can have many.
		beneath=""
		n=0
		while IFS= read -r mp; do
			n=$((n + 1))
			[ "${n}" -le 3 ] && beneath="${beneath:+${beneath}, }${mp}"
		done < <(_ct_uss_mounts_beneath "${target}")
		[ "${n}" -le 3 ] || beneath="${beneath} and $((n - 3)) more"
		if [ -n "${beneath}" ]; then
			beneath="it has mounts beneath it, which the sandbox's user namespace locks: ${beneath}"
		else
			beneath="the kernel log says why"
		fi
		echo "user-state sandbox: overlayfs refuses ${target} as a lower layer here (${beneath}), so ${left} is compared around each run instead" >&2
	done
	for i in "${!mounts[@]}"; do
		is_refused=""
		while IFS= read -r k; do
			[ "${k}" = "${mounts[$i]}" ] && is_refused=1
		done <<<"${refused}"
		[ -z "${is_refused}" ] || continue
		_ct_uss_guarded+=("${guarded[$i]}")
		_ct_uss_mounts+=("${mounts[$i]}")
		_ct_uss_subs+=("${subs[$i]}")
	done
	# Nothing left to cover: no sandbox, and every directory is compared.
	[ "${#_ct_uss_guarded[@]}" -gt 0 ] || return 1
	export CT_USS_UID="${uid}" CT_USS_GID="${gid}"
	_ct_uss_enabled=1
	# Once per lane, like the probe: every run of this shell's sandbox reaches
	# the host's RunQuota through the same relay.
	_ct_uss_relay_start "${uid}" "${gid}"
}

ct_user_state_sandbox_prefix() {
	# Set `ct_uss_cmd` to the command prefix that runs a program in a fresh
	# sandbox whose layers live under directory `$1`; empty when the sandbox
	# is off, so `${ct_uss_cmd[@]+"${ct_uss_cmd[@]}"} prog` degrades to
	# running `prog`. Two guarded directories under one parent share that
	# parent's overlay (`_ct_uss_layer` maps each to its layer).
	ct_uss_cmd=()
	_ct_uss_layer=()
	[ -n "${_ct_uss_enabled}" ] || return 0
	local root="$1" i k found args=() layers=()
	for i in "${!_ct_uss_mounts[@]}"; do
		found=""
		for k in "${!layers[@]}"; do
			if [ "${layers[$k]}" = "${_ct_uss_mounts[$i]}" ]; then
				found="${k}"
				break
			fi
		done
		if [ -z "${found}" ]; then
			found="${#layers[@]}"
			layers+=("${_ct_uss_mounts[$i]}")
			mkdir -p "${root}/up/${found}" "${root}/work/${found}"
			args+=("${_ct_uss_mounts[$i]}" "${root}/up/${found}" "${root}/work/${found}")
		fi
		_ct_uss_layer+=("${found}")
	done
	# The RunQuota relay's endpoint, when `ct_user_state_sandbox_enable`
	# started one, is the one the sandboxed command reaches.
	ct_uss_cmd=(${_ct_uss_relay_env[@]+env "${_ct_uss_relay_env[@]}"}
		unshare --user --map-root-user --mount bash -c "${_ct_uss_entry}"
		ct-user-state-sandbox ${args[@]+"${args[@]}"} --)
}

ct_user_state_sandbox_findings() {
	# Print what a run left in the upper layers under `$1` as the real paths
	# it would have changed, one `wrote <path>` or `removed <path>` per line,
	# compared the way the snapshot compares each directory: state and config
	# by content, the trace index by content and share's other entries by
	# top-level name, the cache by name. Then remove the layers.
	local root="$1" i dir upper rel real top
	[ -n "${_ct_uss_enabled}" ] || return 0
	for i in "${!_ct_uss_guarded[@]}"; do
		dir="${_ct_uss_guarded[$i]}"
		upper="${root}/up/${_ct_uss_layer[$i]}"
		[ -n "${_ct_uss_subs[$i]}" ] && upper="${upper}/${_ct_uss_subs[$i]}"
		[ -d "${upper}" ] || continue
		while IFS= read -r -d '' rel; do
			rel="${rel#"${upper}"}"
			real="${dir}${rel}"
			top="${rel#/}"
			top="${top%%/*}"
			case "${dir}" in
			*/.local/share/codetracer)
				case "${top}" in
				trace_index.db*) ;;
				*)
					# By top-level name: a new or deleted recording, not
					# what changed inside an existing one.
					if [ -c "${upper}${rel}" ] && [ "/${top}" = "${rel}" ]; then
						echo "removed ${real}"
					elif [ ! -e "${dir}/${top}" ]; then
						echo "wrote ${dir}/${top}"
					fi
					continue
					;;
				esac
				;;
			*/.cache/codetracer)
				# By name: an entry rewritten in place is not a finding.
				if [ -f "${upper}${rel}" ] && [ -e "${real}" ]; then
					continue
				fi
				;;
			esac
			if [ -c "${upper}${rel}" ]; then
				# An overlay whiteout: the run deleted the real entry.
				echo "removed ${real}"
			elif [ -f "${real}" ] && cmp -s "${real}" "${upper}${rel}"; then
				# A copy-up of a file opened for writing and left unchanged.
				continue
			else
				echo "wrote ${real}"
			fi
		done < <(find "${upper}" -mindepth 1 \( -type f -o -type c \) -print0 2>/dev/null | sort -z)
	done | sort -u
	chmod -R u+rwx "${root}" 2>/dev/null
	rm -rf "${root}"
}

# THE STAGE SANDBOX: the same overlay around a whole entry point instead of one
# test file.
#
# A lint stage is not split into files the way a lane is, so it compared the
# user's directories once, around everything it ran, and a writer elsewhere on
# the host failed it: on 2026-11-05 `ci/lint/nim.sh` on nixos-ci-bare-003
# reported ten `~/.cache/codetracer/{sync-families,go-sync-families}` entries
# while an strace of every process the stage started showed none of them
# writing there. Another checkout's `ct-mcr record` tests had.
#
# Called near the top of an entry point as
#   ct_user_state_stage_sandbox <label> bash "$0" "$@"
# it runs that command (the entry point again) in one sandbox and exits with
# its status, or with 1 when the sandbox caught a write to the user's state,
# named. The inner run sees CT_USS_STAGE set, so the call returns 1 there and
# the entry point goes on as before; CT_USS_STAGE_COVERED tells its snapshot
# guard which directories the sandbox covers, so that guard still checks only
# what the sandbox cannot. It returns 1 without running anything on a host
# with no sandbox, and there the entry point's own comparison is the guard.
ct_user_state_stage_sandbox() {
	local label="$1"
	shift
	[ -z "${CT_USS_STAGE:-}" ] || return 1
	ct_user_state_sandbox_enable || return 1
	local root rc found covered
	root="$(mktemp -d "${TMPDIR:-/tmp}/ct-uss-${label}.XXXXXX")" || return 1
	ct_user_state_sandbox_prefix "${root}"
	covered="$(printf '%s\n' "${_ct_uss_guarded[@]}")"
	echo "${label}: running in a sandbox over the user's CodeTracer state ($(ct_user_state_guard_dirs_text))"
	CT_USS_STAGE="${label}" CT_USS_STAGE_COVERED="${covered}" \
		"${ct_uss_cmd[@]}" "$@" && rc=0 || rc=$?
	ct_user_state_sandbox_stop
	found="$(ct_user_state_sandbox_findings "${root}")"
	if [ -n "${found}" ]; then
		{
			echo "ERROR: ${label} WROTE the user's own CodeTracer state" \
				"($(ct_user_state_guard_dirs_text)). It ran in a sandbox, so these" \
				"changes were this stage's own (or a binary it spawned) and were" \
				"kept out of the real directories:"
			printf '%s\n' "${found}" | sed 's/^/    /'
		} >&2
		exit 1
	fi
	echo "${label}: the sandbox caught no write to the user's CodeTracer state"
	exit "${rc}"
}

ct_user_state_guard_start() {
	# Pin the home the guard reads, so a lane that later points HOME at a
	# scratch directory still has its real one compared.
	_ct_usg_home="${HOME:-/nonexistent}"
	_ct_usg_before="$(ct_user_state_snapshot)"
	_ct_usg_started=1
}

ct_user_state_guard_check() {
	# Compare against the snapshot `ct_user_state_guard_start` took. Prints
	# what changed, naming `<label>`, and returns 1; returns 0 when nothing
	# did. Refuses (returns 2) when the guard was never started: a check with
	# nothing to compare against would pass by construction.
	local label="${1:-lane}"
	if [ -z "${_ct_usg_started:-}" ]; then
		echo "ERROR: ${label}: the user-state guard was checked but never started" \
			"(call ct_user_state_guard_start before the lane runs)" >&2
		return 2
	fi
	local after written removed where
	after="$(ct_user_state_snapshot)"
	[ "${after}" = "${_ct_usg_before}" ] && return 0
	where="$(ct_user_state_guard_dirs_text)"
	# Lines only AFTER has: files created, or rewritten (new checksum).
	written="$(comm -13 <(printf '%s\n' "${_ct_usg_before}" | sort) \
		<(printf '%s\n' "${after}" | sort) | sed '/^$/d')"
	# Paths BEFORE had and AFTER does not: files removed.
	removed="$(comm -23 \
		<(printf '%s\n' "${_ct_usg_before}" | awk 'NF {print $3}' | sort) \
		<(printf '%s\n' "${after}" | awk 'NF {print $3}' | sort) |
		sed '/^$/d')"
	if [ -n "${removed}" ]; then
		echo "ERROR: ${label}: these files LEFT the user's own CodeTracer" \
			"state (${where}) during the run — a test (or a binary it spawned)" \
			"deleted real per-user state. (If CodeTracer state was cleared on" \
			"this machine during the run, that is the other possible cause.)" >&2
		printf '%s\n' "${removed}" | sed 's/^/    /' >&2
	fi
	if [ -n "${written}" ]; then
		echo "ERROR: ${label} WROTE the user's own CodeTracer state" \
			"(${where}) — a test (or a binary it spawned) created or rewrote" \
			"real per-user state. (If CodeTracer was used on this machine" \
			"during the run, that is the other possible cause.)" >&2
		printf '%s\n' "${written}" | sed 's/^/    /' >&2
	fi
	[ -z "${written}" ] && [ -z "${removed}" ]
}

ct_user_state_guard_exit() {
	# For the last command of an EXIT trap: exit with the script's own status
	# `<status>` when the guard passes, with 1 when it fails (a lane that
	# passed every test and wrote the user's state is a failed lane).
	local label="${1:-lane}" status="${2:-0}"
	if ! ct_user_state_guard_check "${label}"; then
		exit 1
	fi
	exit "${status}"
}
