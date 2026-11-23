#!/usr/bin/env bash
#
# runquota-bridge-test.sh -- the heavy commands of `just test-rust` and the
# Playwright recipes behind `just test-gui` take a RunQuota lease and run at the
# granted width, instead of each assuming every core of the machine is theirs.
#
# A call site that lost its prefix still PASSES (the command just runs wider),
# so nothing but a test of the bound itself can notice. This is that test.
#
# WHAT IS REAL
#   * a private `runquotad` (3 CPU slots, its socket in a scratch directory,
#     RUNQUOTA_SOCKET + RUNQUOTA_ENDPOINT_SCOPE=private, so no other daemon is
#     touched or asked);
#   * the repository's real `justfile`, run by the real `just`, through the real
#     recipes `test-rust`, `test-e2e` and `dev-tools-test-e2e` (a copy of the
#     justfile is used only for the --mutate run);
#   * the real scripts/runquota-bridge.sh, ci/lib/codetracer-home.sh and `jq`;
#   * the real `runquota`, including its `run` adapters (nextest `-j`,
#     playwright `--workers`) and its jobserver.
#
# WHAT IS STUBBED, AND WHY (the real recipes take hours and a shared machine
# must not be asked to run them; the thing under test is which commands reach
# the bridge and what width they run at, not what a compiler does)
#   * `cargo` is a stub that stands in for cargo and for `cargo nextest`. It
#     does what the real tools do with a width: nextest runs as many parallel
#     "tests" as its `-j` says (8 when it is not told, standing in for the
#     machine's core count); cargo test/build runs 1 + the number of tokens it
#     can take from the GNU make jobserver in MAKEFLAGS (8 when there is none).
#     Each "test" is `sleep 0.2537`, an unusual duration that nothing else on a
#     host runs, so counting processes with exactly that command line counts
#     concurrent work. `cargo build --message-format=json-render-diagnostics`
#     prints the one JSON line the recipe's `jq` reads, so the recipe's `$(...)`
#     capture of the bridged command's standard output is exercised. A nextest
#     `--run-ignored ignored-only` run exits 4, the "no tests to run" status the
#     recipes tolerate, so the exit-status path through the bridge is exercised.
#   * `npx` is a stub: `npx tsc` succeeds at once (it is a type-check, not a
#     width), `npx playwright test` records its arguments and holds one
#     `sleep 0.2537`, as the real runner does for its single worker.
#   * ci/lib/npm-install.sh is a stub in the fixture tree: the real one installs
#     node packages from the network, which has nothing to do with the bridge.
#   * HOME and TMPDIR are scratch directories, so the recipes' guard over the
#     user's own CodeTracer state compares nothing of the real machine and
#     cannot be tripped by someone else using it while this runs.
# The peak is read from /proc every few milliseconds, never from a log.
#
# WHAT IT ASSERTS
#   1. static, over the real justfile: every cargo test / cargo build, cargo
#      nextest and Playwright line of the three recipes carries the matching
#      prefix, in the expected number (a deleted line cannot pass as "none
#      missing");
#   2. several sessions of all three recipes at once peak at <= the budget and
#      at > 1 (so the bound is not met by running nothing); every nextest
#      received an `-j` it did not write, every jobserver command had a
#      jobserver, and Playwright kept its own `--workers=1` untouched;
#   3. the recipe's `$(...)` captures of cargo's JSON still work through the
#      bridge, and the `ignored-only` exit status 4 and a real failing status
#      survive it;
#   4. the same sessions with RQ= (the escape hatch) exceed the budget: the
#      bound is the bridge's doing;
#   5. inside the recipe's own Linux sandbox re-execution (when the host has
#      one) the commands are still leased;
#   6. the bridge script's probes: a `runquota` without the verb is not used,
#      RQ=<prefix> replaces the prefix, no `runquota` runs the command as
#      before, and a command's standard output through the real `runquota` is
#      exactly its own;
#   7. NEGATIVE CONTROL (--mutate): the prefixes are deleted from a copy of the
#      real justfile, and the same measurement must then exceed the budget.
#      Prints "MUTATION KILLED" when it does.
#
# Usage: ci/test/runquota-bridge-test.sh [--mutate]      (or: just test-runquota-bridge [--mutate])
set -uo pipefail

MUTATE=0
[ "${1:-}" = "--mutate" ] && MUTATE=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../.." && pwd)"

BUDGET=3     # CPU slots of the private daemon
RUST_SESSIONS=3
E2E_SESSIONS=3
DEVTOOLS_SESSIONS=2
FAILED=0

pass() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; FAILED=$((FAILED + 1)); }
note() { echo "  note $*"; }
die() { echo "runquota-bridge-test: $*" >&2; exit 2; }
assert_eq() { # <what> <expected> <actual>
	if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected [$2], got [$3]"; fi
}
assert_ge() { # <what> <min> <actual>
	if [ "$3" -ge "$2" ] 2>/dev/null; then pass "$1 ($3 >= $2)"; else fail "$1: expected >= $2, got [$3]"; fi
}

for tool in runquota runquotad just jq python3; do
	command -v "${tool}" >/dev/null 2>&1 || die "${tool} is required on PATH"
done
# `runquota` must have both verbs, or every bridged call would silently run bare.
[ "$(runquota jobserver 2>&1 </dev/null | grep -c 'runquota jobserver: missing command')" -ge 1 ] ||
	die "the installed runquota has no jobserver verb"
runquota run --adapter list 2>/dev/null | grep -q '^adapters' || die "the installed runquota has no run verb"

# A Unix socket path is limited to ~100 bytes: keep the scratch directory under a short parent.
S="$(mktemp -d /tmp/rqb.XXXXXX)" || die "mktemp failed"
DAEMON_PID=""
cleanup() {
	[ -n "${RQB_KEEP:-}" ] && { echo "kept ${S}" >&2; return; }
	# Stop only the daemon this run started, after checking the pid still is it.
	if [ -n "${DAEMON_PID}" ] && ps -o args= -p "${DAEMON_PID}" 2>/dev/null | grep -q -- "--socket ${S}/rq.sock"; then
		kill "${DAEMON_PID}" 2>/dev/null
		sleep 0.3
	fi
	rm -rf "${S}"
}
trap cleanup EXIT

# --- the private daemon ------------------------------------------------------------------------
export RUNQUOTA_SOCKET="${S}/rq.sock" RUNQUOTA_ENDPOINT_SCOPE=private
runquotad --socket "${S}/rq.sock" --cpu-milli $((BUDGET * 1000)) --memory-bytes 17179869184 \
	--no-write-stats --estimate-db "${S}/est.db" --observation-db "${S}/obs.db" --log-file "${S}/rqd.log" \
	>"${S}/rqd.out" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 100); do runquota status >/dev/null 2>&1 && break; sleep 0.1; done
runquota status >/dev/null 2>&1 || die "the private runquotad did not answer: $(tail -3 "${S}/rqd.log" "${S}/rqd.out" 2>/dev/null)"

# --- the fixture tree: the real justfile and scripts, empty crate directories --------------------
make_project() { # <dir> <mutate:0|1>
	local p="$1"
	mkdir -p "${p}/scripts" "${p}/ci/lib" "${p}/src/db-backend" "${p}/src/backend-manager" "${p}/src/tests/gui"
	local d
	for d in ct-home ct-dap-client ct-data-breakpoints ct-open-beneath ct-flow-wire jsbound; do mkdir -p "${p}/libs/${d}"; done
	cp "${REPO_ROOT}/scripts/runquota-bridge.sh" "${p}/scripts/" || die "cannot copy the bridge script"
	cp "${REPO_ROOT}/ci/lib/codetracer-home.sh" "${p}/ci/lib/" || die "cannot copy codetracer-home.sh"
	printf '#!/usr/bin/env bash\nexit 0\n' >"${p}/ci/lib/npm-install.sh"
	if [ "$2" = 1 ]; then
		# Delete every prefix from the recipe bodies (the definitions have no `{{`).
		sed -E 's/\{\{(rq|rq1|rqj)\}\} //g' "${REPO_ROOT}/justfile" >"${p}/justfile"
		cmp -s "${REPO_ROOT}/justfile" "${p}/justfile" && die "the mutation changed nothing"
	else
		cp "${REPO_ROOT}/justfile" "${p}/justfile"
	fi
}

mkdir -p "${S}/bin" "${S}/home/.local/state/codetracer" "${S}/home/.config/codetracer" \
	"${S}/home/.local/share/codetracer" "${S}/home/.cache/codetracer" "${S}/tmp"
: >"${S}/fake-exe"; chmod +x "${S}/fake-exe"

cat >"${S}/bin/cargo" <<'EOF'
#!/usr/bin/env -S python3 -I
# test stub for `cargo` and `cargo nextest`; see ci/test/runquota-bridge-test.sh
import json, os, subprocess, sys
args = sys.argv[1:]
kind = "nextest" if args[:1] == ["nextest"] else (args[0] if args else "")
n, tokens = 8, []
if kind == "nextest":
    for i, a in enumerate(args):
        if a == "-j" and i + 1 < len(args):
            n = int(args[i + 1])
else:
    mf = os.environ.get("MAKEFLAGS", "")
    for w in mf.split():
        if w.startswith("--jobserver-auth=fifo:"):
            import fcntl
            fd = os.open(w.split(":", 1)[1], os.O_RDWR | os.O_NONBLOCK)
            while len(tokens) < 7:
                try:
                    t = os.read(fd, 1)
                except BlockingIOError:
                    break
                if not t:
                    break
                tokens.append(t)
            n = 1 + len(tokens)
rec = {"kind": kind, "args": args, "n": n,
       "jobserver": "--jobserver-auth=" in os.environ.get("MAKEFLAGS", ""),
       "width_env": os.environ.get("RUNQUOTA_RUN_WIDTH")}
fd = os.open(os.environ["RQB_LOG"], os.O_WRONLY | os.O_APPEND | os.O_CREAT)
os.write(fd, (json.dumps(rec) + "\n").encode())
os.close(fd)
if kind == "nextest" and "ignored-only" in args:
    sys.exit(4)              # "no tests to run", which the recipes tolerate
procs = [subprocess.Popen(["sleep", "0.2537"]) for _ in range(n)]
for p in procs:
    p.wait()
if tokens:
    for w in os.environ["MAKEFLAGS"].split():
        if w.startswith("--jobserver-auth=fifo:"):
            wfd = os.open(w.split(":", 1)[1], os.O_RDWR | os.O_NONBLOCK)
            os.write(wfd, b"".join(tokens))
if kind == "build" and any(a.startswith("--message-format=json") for a in args):
    print(json.dumps({"reason": "compiler-artifact", "executable": os.environ["RQB_FAKE_EXE"]}))
if kind == "nextest" and "--test" in args and os.environ.get("RQB_FAIL_NEXTEST") == "1":
    sys.exit(1)
EOF
cat >"${S}/bin/npx" <<'EOF'
#!/usr/bin/env -S python3 -I
# test stub for `npx`; see ci/test/runquota-bridge-test.sh
import json, os, subprocess, sys
args = sys.argv[1:]
if args[:1] != ["playwright"]:
    sys.exit(0)              # `npx tsc --noEmit` is a type-check, not a width
rec = {"kind": "playwright", "args": args, "dev_tools": os.environ.get("CODETRACER_DEV_TOOLS"),
       "width_env": os.environ.get("RUNQUOTA_RUN_WIDTH")}
fd = os.open(os.environ["RQB_LOG"], os.O_WRONLY | os.O_APPEND | os.O_CREAT)
os.write(fd, (json.dumps(rec) + "\n").encode())
os.close(fd)
subprocess.Popen(["sleep", "0.2537"]).wait()
EOF
chmod +x "${S}/bin/cargo" "${S}/bin/npx"

# --- the sampler: peak number of concurrent `sleep 0.2537` ----------------------------------------
cat >"${S}/sample.py" <<'EOF'
import os, sys, time
stop, out = sys.argv[1], sys.argv[2]
peak = 0
while not os.path.exists(stop):
    n = 0
    for p in os.listdir('/proc'):
        if p.isdigit():
            try:
                with open('/proc/%s/cmdline' % p, 'rb') as f:
                    if f.read() == b'sleep\x000.2537\x00':
                        n += 1
            except OSError:
                pass
    peak = max(peak, n)
    time.sleep(0.004)
open(out, 'w').write(str(peak))
EOF

# session_env <project> : the environment every recipe session runs in.
run_recipe() { # <project> <outfile> <recipe> [args...]
	local p="$1" out="$2"; shift 2
	( cd "${p}" && env HOME="${S}/home" TMPDIR="${S}/tmp" PATH="${S}/bin:${PATH}" \
		RQB_LOG="${S}/calls.log" RQB_FAKE_EXE="${S}/fake-exe" DISPLAY=:99 \
		CODETRACER_REPO_ROOT_PATH="${p}" \
		just --justfile "${p}/justfile" --working-directory "${p}" "$@" ) >"${out}" 2>&1
}

# measure <label> <project> : all sessions at once; sets PEAK and RC_FAILS; leaves ${S}/calls.log.
measure() {
	local label="$1" p="$2" pids=() sp i
	rm -f "${S}/stop" "${S}/peak.${label}" "${S}/calls.log"; : >"${S}/calls.log"
	python3 -I "${S}/sample.py" "${S}/stop" "${S}/peak.${label}" & sp=$!
	for i in $(seq "${RUST_SESSIONS}"); do
		CT_USER_STATE_SANDBOX=0 run_recipe "${p}" "${S}/out.${label}.rust.${i}" test-rust & pids+=($!)
	done
	for i in $(seq "${E2E_SESSIONS}"); do
		run_recipe "${p}" "${S}/out.${label}.e2e.${i}" test-e2e tests/some.spec.ts & pids+=($!)
	done
	for i in $(seq "${DEVTOOLS_SESSIONS}"); do
		run_recipe "${p}" "${S}/out.${label}.dt.${i}" dev-tools-test-e2e tests/some.spec.ts & pids+=($!)
	done
	RC_FAILS=0
	local pid; for pid in "${pids[@]}"; do wait "${pid}" || RC_FAILS=$((RC_FAILS + 1)); done
	: >"${S}/stop"; wait "${sp}"
	PEAK="$(cat "${S}/peak.${label}")"
}

if [ "${MUTATE}" = 1 ]; then
	make_project "${S}/mut" 1
	measure mutated "${S}/mut"
	echo "mutated (every prefix deleted from a copy of the real justfile): peak concurrent work = ${PEAK}, budget = ${BUDGET}, sessions failing = ${RC_FAILS}"
	if [ "${PEAK}" -gt "${BUDGET}" ]; then echo "MUTATION KILLED"; exit 0; fi
	echo "MUTATION SURVIVED: the measurement does not depend on the bridge"; exit 1
fi

# =================================================================================================
echo "== 1. every heavy line of the three recipes carries its prefix (static, real justfile) =="
recipe_body() { # <recipe> : the recipe's lines, comments and echo lines removed
	awk -v r="$1" '
		$0 ~ "^" r "( .*)?:" { on = 1; next }
		on && /^[^ \t]/ && !/^$/ { on = 0 }
		on { print }' "${REPO_ROOT}/justfile" | grep -vE '^[[:space:]]*(#|echo )'
}
body="$({ recipe_body test-rust; recipe_body test-e2e; recipe_body dev-tools-test-e2e; })"
[ -n "${body}" ] || die "could not extract the recipe bodies"
# A heavy command, wherever it sits on a line: cargo test / build, cargo nextest, npx playwright.
missing_j="$(printf '%s\n' "${body}" | grep -E 'cargo (test|build)( |$)' | grep -vE '\{\{rqj\}\} cargo (test|build)' || true)"
missing_r="$(printf '%s\n' "${body}" | grep -E 'cargo nextest run' | grep -vE '\{\{rq\}\} cargo nextest run' || true)"
missing_p="$(printf '%s\n' "${body}" | grep -E 'npx playwright test' | grep -vE '\{\{rq1\}\} npx playwright test' || true)"
assert_eq "no cargo test/build line lacks {{rqj}}" "" "${missing_j}"
assert_eq "no cargo nextest line lacks {{rq}}" "" "${missing_r}"
assert_eq "no playwright line lacks {{rq1}}" "" "${missing_p}"
assert_eq "cargo test/build sites carrying {{rqj}} (4 test crates, 2 builds)" 6 "$(printf '%s\n' "${body}" | grep -cE '\{\{rqj\}\} cargo (test|build)')"
assert_eq "cargo nextest sites carrying {{rq}}" 7 "$(printf '%s\n' "${body}" | grep -cE '\{\{rq\}\} cargo nextest run')"
assert_eq "playwright sites carrying {{rq1}}" 2 "$(printf '%s\n' "${body}" | grep -cE '\{\{rq1\}\} npx playwright test')"
assert_eq "the prefix follows VAR=value words, never precedes them" "" \
	"$(printf '%s\n' "${body}" | grep -E '\{\{rq[1j]?\}\} [A-Za-z_]+=' || true)"
assert_eq "test-gui-prebuilt and test-gui-visible each reach test-e2e, the one bridged playwright line" "1 1" \
	"$(for r in test-gui-prebuilt test-gui-visible; do recipe_body "${r}" | grep -q 'just test-e2e' && printf 1 || printf 0; done | sed 's/./& /;s/ $//')"
assert_eq "the three prefixes are defined once, naming the bridge script" 3 \
	"$(grep -cE "^(rq|rq1|rqj) := '\"' \\+ justfile_directory\\(\\) \\+ '/scripts/runquota-bridge.sh\" (run|jobserver) " "${REPO_ROOT}/justfile")"

echo "== 2. $((RUST_SESSIONS + E2E_SESSIONS + DEVTOOLS_SESSIONS)) sessions of the real recipes, one budget =="
make_project "${S}/proj" 0
measure bridged "${S}/proj"
assert_eq "every session exited 0" 0 "${RC_FAILS}"
assert_ge "more than one unit of work ran at once (not met by running nothing)" 2 "${PEAK}"
if [ "${PEAK}" -le "${BUDGET}" ]; then pass "peak concurrent work ${PEAK} <= budget ${BUDGET}"; else fail "peak concurrent work ${PEAK} exceeds budget ${BUDGET}"; fi
note "measured peak ${PEAK} of budget ${BUDGET} across $((RUST_SESSIONS + E2E_SESSIONS + DEVTOOLS_SESSIONS)) sessions"
cp "${S}/calls.log" "${S}/calls.bridged.log"
verdict="$(python3 -I - "${S}/calls.bridged.log" "${BUDGET}" "${RUST_SESSIONS}" "${E2E_SESSIONS}" "${DEVTOOLS_SESSIONS}" <<'PY'
import json, sys
log, budget, rs, es, ds = sys.argv[1], int(sys.argv[2]), *map(int, sys.argv[3:6])
rows = [json.loads(l) for l in open(log) if l.strip()]
out = []
nx_all = [r for r in rows if r["kind"] == "nextest"]
js = [r for r in rows if r["kind"] in ("test", "build")]
pw = [r for r in rows if r["kind"] == "playwright"]
out.append("calls %d %d %d" % (len(nx_all), len(js), len(pw)))
def j_of(r):
    a = r["args"]
    return int(a[a.index("-j") + 1]) if "-j" in a else None
out.append("nextest_without_j %d" % sum(1 for r in nx_all if j_of(r) is None))
out.append("nextest_j_over_budget %d" % sum(1 for r in nx_all if (j_of(r) or 0) > budget))
out.append("jobserver_missing %d" % sum(1 for r in js if not r["jobserver"]))
out.append("jobserver_over_budget %d" % sum(1 for r in js if r["n"] > budget))
out.append("pw_workers_flags %s" % sorted(set(sum(1 for a in r["args"] if a.startswith("--workers")) for r in pw)))
out.append("pw_workers_value %s" % sorted(set(a for r in pw for a in r["args"] if a.startswith("--workers"))))
out.append("pw_width_env %s" % sorted(set(str(r["width_env"]) for r in pw)))
out.append("pw_dev_tools %s" % sorted(set(str(r["dev_tools"]) for r in pw)))
out.append("quoted_filter_kept %d" % sum(1 for r in nx_all if "--test" in r["args"] and r["args"][r["args"].index("--test") + 1] == "*"))
print("\n".join(out))
PY
)"
field() { printf '%s\n' "${verdict}" | sed -n "s/^$1 //p"; }
assert_eq "calls: nextest x$((RUST_SESSIONS * 7)), cargo test/build x$((RUST_SESSIONS * 6)), playwright x$((E2E_SESSIONS + DEVTOOLS_SESSIONS))" \
	"$((RUST_SESSIONS * 7)) $((RUST_SESSIONS * 6)) $((E2E_SESSIONS + DEVTOOLS_SESSIONS))" "$(field calls)"
assert_eq "every running nextest was handed an -j by the adapter" 0 "$(field nextest_without_j)"
assert_eq "no nextest was given an -j above the budget" 0 "$(field nextest_j_over_budget)"
assert_eq "every cargo test/build ran with a jobserver" 0 "$(field jobserver_missing)"
assert_eq "no jobserver was wider than the budget" 0 "$(field jobserver_over_budget)"
assert_eq "playwright kept exactly its own --workers=1, the adapter added none" "[1]" "$(field pw_workers_flags)"
assert_eq "playwright's worker flag is untouched" "['--workers=1']" "$(field pw_workers_value)"
assert_eq "playwright ran under a lease (RUNQUOTA_RUN_WIDTH is set)" "['1']" "$(field pw_width_env)"
assert_eq "VAR=value words before the prefix reach the command (CODETRACER_DEV_TOOLS 0 and 1)" "['0', '1']" "$(field pw_dev_tools)"
assert_eq "a quoted --test '*' survives the bridge unsplit" "$((RUST_SESSIONS))" "$(field quoted_filter_kept)"

echo "== 3. captured output and exit statuses =="
# The recipe captured cargo's JSON through `$(...)` and `jq` found the executable, or it would have failed above.
no_op="$(cat "${S}"/out.bridged.rust.* | grep -c 'treating as no-op')"
assert_eq "nextest's exit 4 passed through the bridge: the recipe tolerated it ($((RUST_SESSIONS * 2)) times)" "$((RUST_SESSIONS * 2))" "${no_op}"
: >"${S}/calls.log"
RQB_FAIL_NEXTEST=1 CT_USER_STATE_SANDBOX=0 run_recipe "${S}/proj" "${S}/out.fail" test-rust; rc=$?
assert_eq "a failing nextest (exit 1) fails the recipe" 1 "$([ "${rc}" -ne 0 ] && echo 1 || echo 0)"

echo "== 4. the escape hatch and its control =="
RQ='' measure off "${S}/proj"
assert_eq "RQ= : every session still exited 0" 0 "${RC_FAILS}"
assert_ge "RQ= turns the bridge off: the same sessions then exceed the budget" $((BUDGET + 1)) "${PEAK}"
note "unbridged peak ${PEAK} (budget ${BUDGET})"

echo "== 5. the recipe's own sandbox re-execution =="
probe_out="$(cd "${S}/proj" && HOME="${S}/home" TMPDIR="${S}/tmp" bash -c '. ci/lib/codetracer-home.sh; ct_user_state_sandbox_enable && echo yes || echo no' 2>/dev/null | tail -1)"
if [ "${probe_out}" = yes ]; then
	: >"${S}/calls.log"
	run_recipe "${S}/proj" "${S}/out.sandbox" test-rust; rc=$?
	assert_eq "test-rust exited 0 inside its sandbox" 0 "${rc}"
	assert_eq "the run really was sandboxed" 1 "$(grep -c 'running in a sandbox' "${S}/out.sandbox")"
	sb="$(python3 -I - "${S}/calls.log" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
nx = [r for r in rows if r["kind"] == "nextest"]
js = [r for r in rows if r["kind"] in ("test", "build")]
print(len(nx), len(js), sum(1 for r in nx if "-j" in r["args"]), sum(1 for r in js if r["jobserver"]))
PY
)"
	assert_eq "inside the sandbox every command was still leased (nextest -j, cargo jobserver)" "7 6 7 6" "${sb}"
else
	note "SKIPPED: this host has no usable user-state sandbox (ct_user_state_sandbox_enable failed), so the recipe does not re-execute itself"
fi

echo "== 6. the bridge script's probes, and standard output through the real runquota =="
B="${REPO_ROOT}/scripts/runquota-bridge.sh"
assert_eq "x=\$(runquota run -- ...) captures only the command's output" "hi" "$(runquota run -- printf hi)"
assert_eq "x=\$(runquota jobserver -- ...) captures only the command's output" "hi" "$(runquota jobserver -- printf hi)"
assert_eq "through the bridge script: run" "hi" "$("${B}" run -- printf hi)"
assert_eq "through the bridge script: jobserver" "hi" "$("${B}" jobserver -- printf hi)"
assert_eq "with no daemon answering, the command still runs, output clean" "hi" \
	"$(RUNQUOTA_SOCKET="${S}/none.sock" "${B}" run -- printf hi 2>/dev/null)"
"${B}" run -- sh -c 'exit 4'; assert_eq "exit status 4 passes through run" 4 "$?"
"${B}" jobserver -- sh -c 'exit 7'; assert_eq "exit status 7 passes through jobserver" 7 "$?"
mkdir -p "${S}/old"; printf '#!/usr/bin/env bash\necho "usage: runquota ..."; exit 0\n' >"${S}/old/runquota"; chmod +x "${S}/old/runquota"
out="$(PATH="${S}/old:${PATH}" "${B}" run -- echo ran)"
assert_eq "a runquota without the verb is not used; the command still runs" "ran" "${out}"
PATH="${S}/old:${PATH}" "${B}" active run; assert_eq "and the bridge reports it inactive" 1 "$?"
"${B}" active run; assert_eq "the real runquota is reported active (run)" 0 "$?"
"${B}" active jobserver; assert_eq "the real runquota is reported active (jobserver)" 0 "$?"
out="$(RQ='env BRIDGED=yes' "${B}" run -- sh -c 'echo ${BRIDGED:-no}')"
assert_eq "RQ=<prefix> replaces the prefix" yes "${out}"
RQ='' "${B}" active run; assert_eq "RQ= reports inactive" 1 "$?"
out="$(PATH="$(dirname "$(command -v bash)"):$(dirname "$(command -v env)")" "${B}" run -- echo plain 2>&1)"
assert_eq "with no runquota on PATH the command runs unchanged" plain "${out}"

echo
if [ "${FAILED}" -eq 0 ]; then echo "runquota-bridge-test: all assertions passed"; exit 0; fi
echo "runquota-bridge-test: ${FAILED} assertion(s) FAILED"; exit 1
