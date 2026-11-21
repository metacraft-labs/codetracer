#!/usr/bin/env bash
#
# user-state-sandbox-runquota-test.sh — contract suite for the RunQuota
# endpoint inside the user-state sandbox (ci/lib/codetracer-home.sh, "THE
# RUNQUOTA ENDPOINT INSIDE THE SANDBOX").
#
# WHY THIS EXISTS
# ---------------
# The sandbox maps only the caller's uid and gid, so the provisioned RunQuota
# endpoint directory (`/run/runquota`, owned by the `runquota` account) read as
# owned by 65534 inside it, RunQuota refused it as "a rendezvous point another
# user controls", and every `repro exec` a sandboxed entry point started failed
# (codetracer-specs issue
# `2026-11-15-user-state-sandbox-hides-the-runquota-endpoint-owner-so-repro-exec-is-refused.md`).
# The library now forwards the endpoint through a private relay it starts
# outside the sandbox, after RunQuota itself has accepted the endpoint there.
# This suite runs the real library, the real `runquotad`, `runquota` and
# `repro`, and pins:
#
#   1. the fixture reproduces the defect: inside the sandbox, the endpoint
#      itself is refused with RunQuota's foreign-owner message, while outside
#      the same client succeeds;
#   2. `repro exec` and a `runquota` lease succeed inside the stage sandbox,
#      and the daemon outside really granted them (its grant count rose);
#   3. the same through the per-run sandbox a test lane uses;
#   4. an endpoint RunQuota refuses outside (a wrong owner, a wrong mode) is
#      not forwarded, and keeps its refusal inside; so is one that cannot be
#      checked or relayed because `runquota` or `python3` is missing;
#   5. a daemon restarted in the verified directory is reached; a swapped
#      directory, and a socket of the wrong type, owner or mode, are refused
#      per connection;
#   6. no relay process and no relay directory outlive the run, also when the
#      shell that started the relay is killed with SIGKILL.
#
# THE FIXTURE, AND WHY IT IS NOT THE REAL ONE
# -------------------------------------------
# The faithful fixture is a daemon running as a second account. A CI runner or
# an agent session often runs inside a user namespace that maps ONE id
# (`/proc/self/uid_map` = `1004 1004 1` on the host this was written on), with
# NoNewPrivs set, so `newuidmap` fails and no file of a second uid can be
# owned or created. So the suite re-runs itself in a user namespace T
# (`unshare --user --map-root-user --mount`), where the daemon account is T's
# uid 0: the endpoint directory is owned by 0 with the shared policy's mode
# 0750, and `runquotad` runs with RUNQUOTA_ENDPOINT_OWNER_UID=0 and
# RUNQUOTA_ENDPOINT_GROUP=0 (RunQuota accepts a numeric gid).
#
# The caller must be a uid OTHER than the daemon's, and with one real id the
# only way is the uid the sandbox maps it to: the suite SHADOWS `id` with a
# shell function in the scripts it runs, so `ct_user_state_sandbox_enable`
# computes CT_USS_UID=1004. The sandbox then maps T's 0 to 1004, and inside it
# the endpoint directory reads as owned by 1004, not the configured 0: the
# same `trustForeignOwner` refusal the issue shows (another number, the same
# rule).
#
# THE SHADOW COSTS ONE COMPENSATION. A RunQuota client declares its uid in its
# Hello and the daemon refuses one that disagrees with the connection's peer
# credentials. In a real sandbox the two agree by construction: the sandboxed
# command runs as the caller's own uid, and the relay, which is what the
# daemon sees, runs as the caller. Here the client runs as 1004 while the
# daemon sees the relay as T's 0, so a client that reaches the daemon through
# the relay runs in one more user namespace that maps it back to 0. Only those
# clients: a client on the direct endpoint is refused by the trust check before
# any Hello, and that refusal is the defect the fixture must keep. The suite
# once showed that the compensation removed nothing but this artefact:
# unmapped, the relayed client got exactly that refusal. RunQuota since
# 6d739bdc serves such a client, excusing its foreign-namespace uid, so the
# control below now requires it to be served.
#
# THE MISSING-TOOL ARMS SHADOW ONE MORE THING. To show that the library does
# not forward an endpoint it cannot have RunQuota check (no `runquota`) or
# cannot relay (no `python3`), the prelude's `command` hides the tool named in
# CT_USS_RQ_HIDE from `command -v`, in the library's shell only. Removing the
# tool from PATH instead would remove it from the probe as well, which then
# could not show that the sandboxed client meets RunQuota's refusal.
#
# Nothing else is faked: the daemon, the clients, the overlays and the relay
# are the real ones. `HOME` is a scratch home, as in
# ci/test/lane-user-state-guard-test.sh, and `CODETRACER_HOME` a scratch
# directory of its own.
#
# `repro exec` runs in a one-line fixture project rather than in this
# checkout, whose dev env takes minutes to activate. Its first activation still
# compiles the project's provider (about a minute); the later ones reuse it.
# XDG_CACHE_HOME stays the caller's, so repro's own caches are not rebuilt.
#
# HOST REQUIREMENTS. Linux only (the sandbox exists only there; elsewhere the
# suite says so and exits 0). On Linux a missing tool or a host without
# unprivileged user namespaces is a FAILURE, by name: a suite that skipped
# would be green over a property it never checked.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# The library under test; the variable exists so the same suite can be run
# against another revision of it (the unfixed one, to see case 2 fail).
lib="${CT_USS_RQ_LIBRARY:-${repo_root}/ci/lib/codetracer-home.sh}"

if [ "$(uname -s)" != Linux ]; then
	echo "user-state-sandbox-runquota-test: n/a: the user-state sandbox exists only on Linux"
	exit 0
fi

if [ -z "${_CT_USS_RQ_IN_T:-}" ]; then
	missing=""
	for tool in unshare runquotad runquota repro python3 stat timeout; do
		command -v "${tool}" >/dev/null 2>&1 || missing="${missing} ${tool}"
	done
	if [ -n "${missing}" ]; then
		echo "user-state-sandbox-runquota-test: FAIL: missing on PATH:${missing} (run it in the dev shell)" >&2
		exit 1
	fi
	if ! unshare --user --map-root-user --mount true 2>/dev/null; then
		echo "user-state-sandbox-runquota-test: FAIL: this host refuses unprivileged user namespaces, so neither the fixture nor the sandbox can run" >&2
		exit 1
	fi
	exec unshare --user --map-root-user --mount \
		env _CT_USS_RQ_IN_T=1 _CT_USS_RQ_CACHE="${XDG_CACHE_HOME:-${HOME}/.cache}" \
		bash "${BASH_SOURCE[0]}" "$@"
fi

# --- inside T: the "host" --------------------------------------------------
# Under /tmp, not TMPDIR: a Unix socket path is limited to 108 bytes.
scratch="$(mktemp -d /tmp/ct-uss-rq-test.XXXXXX)"
daemon_pid=""
cleanup() {
	[ -z "${daemon_pid}" ] || kill "${daemon_pid}" 2>/dev/null
	[ -z "${daemon_pid}" ] || wait "${daemon_pid}" 2>/dev/null
	chmod -R u+rwx "${scratch}" 2>/dev/null
	rm -rf "${scratch}"
}
trap cleanup EXIT

passes=0
failures=0
t_pass() {
	passes=$((passes + 1))
	echo "  ok   $1"
}
t_fail() {
	failures=$((failures + 1))
	echo "  FAIL $1" >&2
}
show() { sed 's/^/       /' "$1" >&2; }

endpoint_dir="${scratch}/rq"
endpoint="${endpoint_dir}/runquotad.sock"
# The scratch home carries the four directories the sandbox guards, so it has
# something to overlay. They belong to the fixture, not to CodeTracer: nothing
# here resolves CodeTracer state. Whatever the suite starts that does resolve
# it lands in its own scratch CODETRACER_HOME (exported below), which outranks
# HOME, rather than in the caller's.
mkdir -p "${scratch}/tmp" "${scratch}/project" "${scratch}/codetracer-home" \
	"${scratch}/home/.local/state/codetracer" "${scratch}/home/.local/share/codetracer" \
	"${scratch}/home/.config/codetracer" "${scratch}/home/.cache/codetracer"
: >"${scratch}/codetracer-home/.codetracer-test-home"
mkdir -m 0750 "${endpoint_dir}"
printf 'import repro_project_dsl\npackage fixture:\n  defaultToolProvisioning "path"\n  devEnv:\n    setEnv "CT_USS_RQ_FIXTURE", "1"\n' \
	>"${scratch}/project/repro.nim"

# Every client in this suite, inside and outside, resolves the fixture's
# endpoint under the fixture's policy, and nothing of the caller's RunQuota
# setup leaks in.
unset RUNQUOTA_ENDPOINT_SCOPE RUNQUOTA_USER_ENDPOINT_DIR CT_USS_STAGE CT_USS_STAGE_COVERED
export RUNQUOTA_SOCKET="${endpoint}" RUNQUOTA_ENDPOINT_OWNER_UID=0 RUNQUOTA_ENDPOINT_GROUP=0
export HOME="${scratch}/home" TMPDIR="${scratch}/tmp" XDG_CACHE_HOME="${_CT_USS_RQ_CACHE}"
export CODETRACER_HOME="${scratch}/codetracer-home"
export REPRO_DAEMON=off

start_daemon() {
	runquotad --socket "${endpoint}" --idle-exit-after 900 --no-write-stats \
		>>"${scratch}/daemon.log" 2>&1 &
	daemon_pid=$!
	for _ in $(seq 1 100); do
		[ -S "${endpoint}" ] && runquota status >/dev/null 2>&1 && return 0
		sleep 0.05
	done
	echo "user-state-sandbox-runquota-test: FAIL: the fixture runquotad never answered at ${endpoint}" >&2
	show "${scratch}/daemon.log"
	exit 1
}
stop_daemon() {
	kill "${daemon_pid}" 2>/dev/null
	wait "${daemon_pid}" 2>/dev/null
	daemon_pid=""
}
granted() { runquota status 2>/dev/null | sed -n 's/^total_granted: //p'; }

# What every script below starts with: the shadowed `id` (see the header) and
# the library under test.
cat >"${scratch}/prelude.sh" <<PRELUDE
command() {
	if [ "\${1:-}" = -v ] && [ -n "\${CT_USS_RQ_HIDE:-}" ] &&
		[ "\${2:-}" = "\${CT_USS_RQ_HIDE}" ]; then
		return 1
	fi
	builtin command "\$@"
}
id() {
	case "\${1:-}" in
	-u) echo 1004 ;;
	*) command id "\$@" ;;
	esac
}
# shellcheck disable=SC1091
source "${lib}"
PRELUDE

# The inner half every stage below runs: who it is, what the endpoint looks
# like, the endpoint itself (no relay), then `repro exec` and a lease through
# whatever the sandbox gave it. Each result goes to its own file.
cat >"${scratch}/probe.sh" <<'PROBE'
r="${TMPDIR}/probe"
mkdir -p "${r}"
command id -u >"${r}/uid"
stat -c '%u' -- "${CT_USS_RQ_ENDPOINT_DIR}" >"${r}/endpoint-owner"
printf '%s\n' "${RUNQUOTA_SOCKET:-}" >"${r}/socket"
env -u RUNQUOTA_ENDPOINT_SCOPE RUNQUOTA_SOCKET="${CT_USS_RQ_ENDPOINT}" \
	runquota status >"${r}/direct.err" 2>&1
echo $? >"${r}/direct.rc"
# THE ONE COMPENSATION (see the header): a client that reaches the daemon
# through the relay declares its uid in its Hello, and the daemon refuses one
# that disagrees with the peer credentials it sees. In a real sandbox the two
# agree by construction; here the shadowed `id` made them differ, so such a
# client runs mapped back to the uid the daemon sees. A client on the direct
# endpoint never gets that far (the trust check refuses it first, which is
# the defect) and is never mapped.
relayed=""
[ "${RUNQUOTA_ENDPOINT_SCOPE:-}" = private ] && relayed=1
client() {
	if [ -n "${relayed}" ]; then
		unshare --user --map-user=0 --map-group=0 -- "$@"
	else
		"$@"
	fi
}
if [ -n "${relayed}" ]; then
	# Unmapped, the relayed client is answered BY THE DAEMON, with that
	# refusal and nothing else: the relay reached it, and the client's own
	# trust checks of the relay's endpoint passed.
	runquota status >"${r}/unmapped.err" 2>&1
	echo $? >"${r}/unmapped.rc"
fi
if [ -n "${CT_USS_RQ_WAIT:-}" ]; then
	: >"${TMPDIR}/inner-ready"
	for _ in $(seq 1 600); do
		[ -e "${TMPDIR}/inner-go" ] && break
		sleep 0.05
	done
fi
client runquota status >"${r}/status.err" 2>&1
echo $? >"${r}/status.rc"
# `runquota acquire` runs its command even when no daemon admits it, so its
# status says nothing; the daemon's grant count, read outside, does.
client runquota acquire --cpu 1 --mem 1048576 --label ct-uss-relay-probe -- true \
	>"${r}/lease.out" 2>"${r}/lease.err"
echo $? >"${r}/lease.rc"
if [ -n "${CT_USS_RQ_EXEC:-}" ]; then
	client repro exec "${CT_USS_RQ_PROJECT}" -- sh -c 'echo "fixture=${CT_USS_RQ_FIXTURE:-}"' \
		>"${r}/exec.out" 2>"${r}/exec.err"
	echo $? >"${r}/exec.rc"
fi
PROBE
export CT_USS_RQ_ENDPOINT="${endpoint}" CT_USS_RQ_ENDPOINT_DIR="${endpoint_dir}" \
	CT_USS_RQ_PROJECT="${scratch}/project"

# A stage-shaped entry point: re-run itself in the stage sandbox, then probe.
cat >"${scratch}/stage.sh" <<STAGE
set -uo pipefail
source "${scratch}/prelude.sh"
ct_user_state_stage_sandbox rq-stage bash "${scratch}/stage.sh"
bash "${scratch}/probe.sh"
STAGE

# A lane-shaped one: the per-run sandbox, the way run-nim-test-lane.sh drives
# it, ending WITHOUT ct_user_state_sandbox_stop, so the relay has to end with
# the shell on its own.
cat >"${scratch}/lane.sh" <<LANE
set -uo pipefail
source "${scratch}/prelude.sh"
if ! ct_user_state_sandbox_enable; then echo "lane: no sandbox"; exit 2; fi
echo "lane: each file runs in a sandbox"
ct_user_state_sandbox_prefix "\${TMPDIR}/layers"
"\${ct_uss_cmd[@]}" bash "${scratch}/probe.sh"
ct_user_state_sandbox_findings "\${TMPDIR}/layers"
LANE

# `$1` stage|lane; sets `rc`, output in ${scratch}/out.
run_entry() {
	rm -rf "${scratch}/tmp/probe" "${scratch}/tmp/inner-ready" "${scratch}/tmp/inner-go"
	bash "${scratch}/$1.sh" >"${scratch}/out" 2>&1
	rc=$?
}
probe() { cat "${scratch}/tmp/probe/$1" 2>/dev/null; }

relay_dirs_left() { (cd "${scratch}/tmp" && for e in ct-uss-rq.*; do [ -e "$e" ] && printf ' %s' "$e"; done); }
relay_procs_left() {
	local p cmdline
	for p in /proc/[0-9]*; do
		cmdline="$(tr '\0' ' ' 2>/dev/null <"${p}/cmdline")" || continue
		case "${cmdline}" in
		*"ct-uss-runquota-relay "*" ${endpoint} ${scratch}/tmp/ct-uss-rq."*) printf ' %s' "${p#/proc/}" ;;
		esac
	done
}
# Case 6, after every run: nothing of the relay is left.
check_no_relay_left() {
	local dirs procs
	dirs="$(relay_dirs_left)"
	procs="$(relay_procs_left)"
	if [ -z "${dirs}" ] && [ -z "${procs}" ]; then
		t_pass "$1: no relay process or relay directory is left"
	else
		t_fail "$1: the relay outlived the run (directories:${dirs:- none}; processes:${procs:- none})"
	fi
}

echo "user-state-sandbox-runquota-test (library: ${lib}):"
start_daemon

# 1. The fixture reproduces the defect. Outside the sandbox (in T) both
#    clients succeed; inside it, the endpoint itself is refused for its
#    owner. Checked in the stage run below, from the probe's direct client.
if runquota status >/dev/null 2>"${scratch}/outside.err" &&
	repro exec "${scratch}/project" -- true >"${scratch}/outside-exec.out" 2>&1; then
	t_pass "fixture: outside the sandbox runquota and repro exec reach the endpoint"
else
	t_fail "fixture: outside the sandbox runquota and repro exec reach the endpoint"
	show "${scratch}/outside.err"
	show "${scratch}/outside-exec.out"
fi

# 2. The stage sandbox.
before="$(granted)"
CT_USS_RQ_EXEC=1 run_entry stage
after="$(granted)"
if grep -q "rq-stage: running in a sandbox" "${scratch}/out"; then
	t_pass "stage: the sandbox comes up with the shadowed id"
else
	t_fail "stage: the sandbox comes up with the shadowed id (it did not, so nothing below was tested)"
	show "${scratch}/out"
fi
if [ "$(probe uid)" = 1004 ] && [ "$(probe endpoint-owner)" = 1004 ] &&
	[ "$(probe direct.rc)" != 0 ] &&
	grep -q "refusing a path owned by uid 1004 .*configured daemon owner uid 0" "${scratch}/tmp/probe/direct.err"; then
	t_pass "fixture: inside the sandbox the endpoint reads as uid 1004 and RunQuota refuses it for its owner"
else
	t_fail "fixture: inside the sandbox the endpoint reads as uid 1004 and RunQuota refuses it (uid=$(probe uid) owner=$(probe endpoint-owner) rc=$(probe direct.rc))"
	show "${scratch}/tmp/probe/direct.err"
	show "${scratch}/out"
fi
if [ "$(probe exec.rc)" = 0 ] && grep -q '^fixture=1$' "${scratch}/tmp/probe/exec.out"; then
	t_pass "stage: repro exec succeeds inside the sandbox"
else
	t_fail "stage: repro exec succeeds inside the sandbox (rc=$(probe exec.rc))"
	show "${scratch}/tmp/probe/exec.err"
	show "${scratch}/out"
fi
if [ "$(probe status.rc)" = 0 ] && [ "$(probe lease.rc)" = 0 ] &&
	[ -n "${before}" ] && [ "${after}" -ge $((before + 1)) ] &&
	grep -q "forwarding the RunQuota endpoint ${endpoint}" "${scratch}/out"; then
	t_pass "stage: a lease taken inside the sandbox is granted by the daemon outside, through the relay"
else
	t_fail "stage: a lease taken inside the sandbox is granted by the daemon outside (status rc=$(probe status.rc), granted ${before} -> ${after})"
	show "${scratch}/tmp/probe/status.err"
	show "${scratch}/tmp/probe/lease.err"
fi
case "$(probe socket)" in
"${scratch}/tmp/ct-uss-rq."*/rq.sock) t_pass "stage: the sandboxed command was given the relay's private socket" ;;
*) t_fail "stage: the sandboxed command was given the relay's private socket (RUNQUOTA_SOCKET=$(probe socket))" ;;
esac
# The compensation's control: unmapped, the relayed client gets as far as the
# daemon, so the answer is the daemon's own. What the pinned RunQuota
# (aad94ad) specifies for it is SERVED: 6d739bdc ("serve clients that run in
# other namespaces") excuses the declared uid of a client that reports a user
# namespace other than the daemon's, and only that check. Its owner stays the
# peer credential, and the declared uid is deliberately not recorded or
# logged, so there is no excuse line to look for. The status it serves is the
# evidence, together with the absence of the old refusal, "client declared uid
# 1004 but its peer credentials say uid 0". That refusal is now a regression
# and fails here, as does a client-side endpoint refusal or no answer. Run
# 44864106832's nixos leg was served (rc=0, "sessions: 0 / leases: 0").
unmapped_rc="$(probe unmapped.rc)"
if [ "$unmapped_rc" = 0 ] && grep -q '^sessions: ' "${scratch}/tmp/probe/unmapped.err" &&
	! grep -q "client declared uid" "${scratch}/tmp/probe/unmapped.err"; then
	t_pass "stage: unmapped, the relayed client is served by the daemon itself, its foreign-namespace uid excused"
else
	t_fail "stage: unmapped, the relayed client is answered by the daemon itself (rc=$(probe unmapped.rc))"
	show "${scratch}/tmp/probe/unmapped.err"
fi
check_no_relay_left stage

# 3. The per-run sandbox, as a lane drives it.
before="$(granted)"
CT_USS_RQ_EXEC=1 run_entry lane
after="$(granted)"
if [ "${rc}" = 0 ] && grep -q "lane: each file runs in a sandbox" "${scratch}/out" &&
	[ "$(probe exec.rc)" = 0 ] && [ "$(probe status.rc)" = 0 ] &&
	[ -n "${before}" ] && [ "${after}" -ge $((before + 1)) ]; then
	t_pass "lane: repro exec and a lease succeed in the per-run sandbox"
else
	t_fail "lane: repro exec and a lease succeed in the per-run sandbox (rc=${rc}, exec=$(probe exec.rc), status=$(probe status.rc), granted ${before} -> ${after})"
	show "${scratch}/out"
	show "${scratch}/tmp/probe/exec.err"
	show "${scratch}/tmp/probe/status.err"
fi
# The lane script does not stop its relay; it ends with the shell.
sleep 1
check_no_relay_left "lane (relay ended with its shell)"

# 4. Untrusted endpoints keep their refusal: RunQuota refuses them outside, so
#    nothing is forwarded and the sandboxed client meets the same refusal.
#    `$1` names the arm, `$2` is RunQuota's refusal, as it must read inside;
#    the caller has made the endpoint untrusted.
untrusted_arm() {
	local outside=1 before after
	runquota status >/dev/null 2>&1 && outside=0
	before="$(RUNQUOTA_ENDPOINT_OWNER_UID=0 granted)"
	run_entry stage
	after="$(RUNQUOTA_ENDPOINT_OWNER_UID=0 granted)"
	if [ "${outside}" = 1 ] && [ "$(probe status.rc)" != 0 ] &&
		grep -q "runquota endpoint directory ${endpoint_dir}: refusing" "${scratch}/tmp/probe/status.err" &&
		grep -q -- "not forwarding the RunQuota endpoint ${endpoint}: RunQuota refuses it outside the sandbox too: .*$2" "${scratch}/out" &&
		[ "$(probe socket)" = "${endpoint}" ] && [ -z "$(relay_dirs_left)" ] &&
		[ "${before}" = "${after}" ]; then
		t_pass "untrusted ($1): not forwarded, and refused inside as outside"
	else
		t_fail "untrusted ($1): not forwarded, and refused inside as outside (outside refused=${outside}, status rc=$(probe status.rc), socket=$(probe socket), granted ${before} -> ${after})"
		show "${scratch}/tmp/probe/status.err"
		show "${scratch}/out"
	fi
}
RUNQUOTA_ENDPOINT_OWNER_UID=7 untrusted_arm "configured owner is another uid" \
	"configured daemon owner uid 7"
chmod 0755 "${endpoint_dir}"
untrusted_arm "endpoint directory mode 0755" "refusing mode 0755"
chmod 0750 "${endpoint_dir}"

# 4b. A trusted endpoint the library cannot have RunQuota check, or cannot
#     relay, is not forwarded either: the run keeps the refusal it had before,
#     and one line says which tool is missing. `$1` is the hidden tool, `$2`
#     the line's words.
missing_tool_arm() {
	local before after
	before="$(granted)"
	CT_USS_RQ_HIDE="$1" run_entry stage
	after="$(granted)"
	if grep -q "rq-stage: running in a sandbox" "${scratch}/out" &&
		grep -q -- "not forwarding the RunQuota endpoint ${endpoint}: $2" "${scratch}/out" &&
		[ "$(probe socket)" = "${endpoint}" ] && [ "$(probe status.rc)" != 0 ] &&
		grep -q "refusing a path owned by uid 1004 .*configured daemon owner uid 0" "${scratch}/tmp/probe/status.err" &&
		[ -z "$(relay_dirs_left)" ] && [ -z "$(relay_procs_left)" ] &&
		[ -n "${before}" ] && [ "${before}" = "${after}" ]; then
		t_pass "missing ${1}: not forwarded, and refused inside as before"
	else
		t_fail "missing ${1}: not forwarded, and refused inside as before (status rc=$(probe status.rc), socket=$(probe socket), granted ${before} -> ${after})"
		show "${scratch}/tmp/probe/status.err"
		show "${scratch}/out"
	fi
}
# shellcheck disable=SC2016 # literal backticks in the library's message
missing_tool_arm runquota 'no `runquota` on PATH to verify it'
missing_tool_arm python3 'no python3 on PATH for the relay'

# 5. The endpoint changes while a sandboxed command is running (it waits
#    after the relay is up; the change is made outside, then it connects).
#    The relay holds the DIRECTORY RunQuota verified, not the socket's inode:
#    a daemon restarted in that directory is reached, as it would be outside;
#    a swapped directory, and a socket of the wrong type, owner or mode in
#    the verified one, are refused per connection, naming why.
reset_endpoint() {
	umount "${endpoint}" 2>/dev/null
	stop_daemon
	rm -rf "${endpoint_dir}" "${endpoint_dir}.old"
	mkdir -m 0750 "${endpoint_dir}"
	start_daemon
}
# `$1` names the arm, `$2` is the change (shell code), `$3` is `accepted` or
# the reason the relay must give for refusing.
endpoint_change_arm() {
	rm -rf "${scratch}/tmp/probe" "${scratch}/tmp/inner-ready" "${scratch}/tmp/inner-go"
	CT_USS_RQ_WAIT=1 bash "${scratch}/stage.sh" >"${scratch}/out" 2>&1 &
	local stage=$!
	for _ in $(seq 1 400); do
		[ -e "${scratch}/tmp/inner-ready" ] && break
		sleep 0.05
	done
	eval "$2"
	: >"${scratch}/tmp/inner-go"
	wait "${stage}"
	if [ "$3" = accepted ]; then
		if [ "$(probe status.rc)" = 0 ] && ! grep -q "refusing a connection" "${scratch}/out"; then
			t_pass "endpoint change ($1): the connection is accepted"
		else
			t_fail "endpoint change ($1): the connection is accepted (status rc=$(probe status.rc))"
			show "${scratch}/tmp/probe/status.err"
			show "${scratch}/out"
		fi
	elif [ "$(probe status.rc)" != 0 ] &&
		grep -q -- "refusing a connection: the RunQuota endpoint ${endpoint} changed since RunQuota verified it (.*$3" "${scratch}/out"; then
		t_pass "endpoint change ($1): the connection is refused, naming why"
	else
		t_fail "endpoint change ($1): the connection is refused with '$3' (status rc=$(probe status.rc))"
		show "${scratch}/out"
	fi
	reset_endpoint
}
# A socket another account owns, for the wrong-owner arm: with one real id
# this suite cannot create one, so an existing one is bind-mounted over the
# endpoint (T has its own mount namespace). Any socket whose owner reads as
# someone other than T's 0 will do.
foreign_socket=""
for candidate in /nix/var/nix/daemon-socket/socket /run/dbus/system_bus_socket /var/run/dbus/system_bus_socket; do
	if [ -S "${candidate}" ] && [ "$(stat -c %u -- "${candidate}")" != 0 ]; then
		foreign_socket="${candidate}"
		break
	fi
done
# shellcheck disable=SC2016 # expanded by endpoint_change_arm's eval
endpoint_change_arm "the daemon restarted, a new socket in the same directory" \
	'stop_daemon; rm -f "${endpoint}"; start_daemon' accepted
# shellcheck disable=SC2016
endpoint_change_arm "the directory swapped for an identical new one" \
	'stop_daemon; mv "${endpoint_dir}" "${endpoint_dir}.old"; mkdir -m 0750 "${endpoint_dir}"; start_daemon' \
	"its directory ${endpoint_dir} was replaced or changed"
# shellcheck disable=SC2016
endpoint_change_arm "a regular file in place of the socket" \
	'stop_daemon; rm -f "${endpoint}"; : >"${endpoint}"' "is not a socket"
# shellcheck disable=SC2016
endpoint_change_arm "the socket's mode widened to 0666" \
	'chmod 0666 "${endpoint}"' "has mode 666, not the 660"
if [ -n "${foreign_socket}" ]; then
	# shellcheck disable=SC2016
	endpoint_change_arm "a socket of another owner (${foreign_socket})" \
		'mount --bind "${foreign_socket}" "${endpoint}"' "is owned by $(stat -c %u:%g -- "${foreign_socket}"), not by the directory owner 0:0"
else
	t_fail "endpoint change (a socket of another owner): no socket owned by another account on this host to bind over the endpoint"
fi
check_no_relay_left "endpoint changes"

# 6. SIGKILL the shell that started the relay, while the sandboxed command
#    waits: the relay ends and removes its directory anyway.
rm -rf "${scratch}/tmp/probe" "${scratch}/tmp/inner-ready" "${scratch}/tmp/inner-go"
CT_USS_RQ_WAIT=1 bash "${scratch}/stage.sh" >"${scratch}/out" 2>&1 &
stage_pid=$!
for _ in $(seq 1 400); do
	[ -e "${scratch}/tmp/inner-ready" ] && break
	sleep 0.05
done
relay_before="$(relay_procs_left)"
kill -KILL "${stage_pid}"
wait "${stage_pid}" 2>/dev/null
for _ in $(seq 1 60); do
	[ -z "$(relay_procs_left)$(relay_dirs_left)" ] && break
	sleep 0.05
done
if [ -n "${relay_before}" ] && [ -z "$(relay_procs_left)" ] && [ -z "$(relay_dirs_left)" ]; then
	t_pass "kill -9: the relay ends with the shell that started it and removes its directory"
else
	t_fail "kill -9: the relay ends with the shell that started it (relay before:${relay_before:- none}; left:$(relay_procs_left)$(relay_dirs_left))"
fi
# Let the orphaned sandboxed command finish.
: >"${scratch}/tmp/inner-go"
for _ in $(seq 1 100); do
	[ -e "${scratch}/tmp/probe/lease.rc" ] && break
	sleep 0.05
done

echo "user-state-sandbox-runquota-test: ${passes} passed, ${failures} failed"
[ "${failures}" -eq 0 ] && [ "${passes}" -eq 21 ]
