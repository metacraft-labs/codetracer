#!/usr/bin/env bash
# Every script and recipe that starts its own Xvfb starts its clients only
# once the server answers (scripts/lib/own-xvfb.sh), and fails naming Xvfb
# when it never does.
#
# They used to pick a display, start Xvfb, sleep one second and start
# Playwright, so on a loaded host the clients could start before the server
# accepted connections and fail with "Missing X server".
#
# Two parts:
#
# A. Behaviour, through one real caller. plat68-desktop-keys.sh runs, with no
#    DISPLAY, from a copy of this repository's layout that carries the real
#    scripts/lib/own-xvfb.sh. Three stand-ins replace what is not under test,
#    each because the real thing needs a built desktop variant and minutes:
#    `scripts/plat45-desktop-prefix.sh` (an empty prefix), `stylus` (writes
#    nothing) and `npx` (the Playwright run: it probes the display with
#    `xdotool getdisplaygeometry`, the X request the specs' Electron makes
#    first, and fails as Playwright does when nothing answers). `Xvfb` on PATH
#    is the REAL Xvfb behind a wrapper that can delay its start — the loaded
#    host made reproducible — or stand in for a server that dies or never
#    comes up. Asserted:
#      1. a real Xvfb that takes 3 s to start: the specs run once the display
#         answers, the script succeeds, and the Xvfb is gone afterwards;
#      2. an Xvfb that exits at once: the script fails at once, not when the
#         default 60 s bound passes, naming Xvfb, with the server's own
#         output, and never starts the specs;
#      3. an Xvfb that never answers: with CODETRACER_XVFB_WAIT_SECONDS=3 the
#         script fails naming Xvfb within that bound, never starts the specs,
#         and kills the server;
#      4. a CODETRACER_XVFB_WAIT_SECONDS that is not a number is refused by
#         name before any server starts;
#      5. a bound with a leading zero (`08`) is read as decimal seconds.
#
# B. Coverage. No tracked shell script, `ci/` file, justfile recipe, or
#    Python/TypeScript/JavaScript/Nim/Ruby source launches Xvfb except through
#    scripts/lib/own-xvfb.sh, so every caller has part A's behaviour. The one
#    exemption is the single launch in `ctdr_start_xvfb` in
#    scripts/docs/deep-review-capture-lib.sh: its caller chooses the display
#    (CODETRACER_BOOK_SCREENSHOT_DISPLAY), which `-displayfd` cannot honour,
#    and it already waits, bounded, for that display to answer. Planted
#    copies of the old pattern and of the other launch forms prove the gate
#    reddens; a planted lookup, message, comment and xvfb-run prove it does
#    not redden on what is not a launch.
#
# Linux only: elsewhere no script starts an Xvfb. Needs Xvfb and xdotool,
# which the dev shell provides:
#
#   repro exec . -- bash scripts/test-own-xvfb.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() {
	echo "FAIL: $*" >&2
	exit 1
}

[ "$(uname -s)" = Linux ] ||
	fail "this test covers the Xvfb start, which the scripts do on Linux only"
real_xvfb="$(command -v Xvfb)" || fail "no Xvfb on PATH — run inside the dev shell"
real_xdotool="$(command -v xdotool)" || fail "no xdotool on PATH — run inside the dev shell"

WORK="$(mktemp -d)"
cleanup() {
	# A server a failed case left behind is killed here, never someone else's:
	# the wrapper records the pid it became.
	if [ -f "$WORK/xvfb.pid" ]; then
		kill "$(cat "$WORK/xvfb.pid")" 2>/dev/null || true
	fi
	rm -rf "$WORK"
}
trap cleanup EXIT

CT="$WORK/codetracer"
mkdir -p "$CT/scripts" "$CT/src/config" "$CT/src/tests/gui" \
	"$CT/node_modules/.bin" "$WORK/bin" "$WORK/built/styles" "$WORK/fixtures/calc-0"
mkdir -p "$CT/scripts/lib"
cp "$REPO/scripts/plat68-desktop-keys.sh" "$CT/scripts/"
cp "$REPO/scripts/lib/own-xvfb.sh" "$CT/scripts/lib/"
cat >"$CT/scripts/plat45-desktop-prefix.sh" <<SH
mkdir -p "\$1"
ln -s "$WORK/built" "\$1/frontend"
SH
printf '#!/bin/sh\nexit 0\n' >"$CT/node_modules/.bin/stylus"
chmod +x "$CT/node_modules/.bin/stylus"

# The Playwright stand-in: did a display answer when the specs started?
cat >"$WORK/bin/npx" <<SH
#!/usr/bin/env bash
echo "\${DISPLAY:-}" >"$WORK/specs-started"
"$real_xdotool" getdisplaygeometry >/dev/null 2>&1 || {
	echo "Missing X server or \\\$DISPLAY" >&2
	exit 1
}
SH
# The Xvfb wrapper. XVFB_MODE: delay (start the real server after
# XVFB_DELAY s), die (exit at once) or hang (never answer). It execs, so the
# pid the script holds is the server's. A hang lasts 60 s, not forever: a
# script that ignored its bound then sees the server exit, and fails the 15 s
# check below instead of hanging the test.
cat >"$WORK/bin/Xvfb" <<SH
#!/usr/bin/env bash
echo \$\$ >"$WORK/xvfb.pid"
case "\$XVFB_MODE" in
delay) sleep "\$XVFB_DELAY"; exec "$real_xvfb" "\$@" ;;
die) echo "stand-in Xvfb: cannot open the display" >&2; exit 1 ;;
hang) exec sleep 60 ;;
esac
SH
chmod +x "$WORK/bin/npx" "$WORK/bin/Xvfb"

# run_case <mode> [VAR=value...] — runs the script, leaving its exit status in
# `status` and its stderr in $WORK/stderr.
run_case() {
	local mode="$1"
	shift
	rm -f "$WORK/specs-started" "$WORK/xvfb.pid"
	status=0
	env -u DISPLAY -u CODETRACER_XVFB_WAIT_SECONDS PATH="$WORK/bin:$PATH" XVFB_MODE="$mode" \
		PLAT68_FIXTURES_DIR="$WORK/fixtures" "$@" \
		bash "$CT/scripts/plat68-desktop-keys.sh" >"$WORK/stdout" 2>"$WORK/stderr" ||
		status=$?
}

# A server is gone once its pid is gone, or is a zombie (state Z in
# /proc/<pid>/stat, proc(5)) its new parent has not reaped yet: `kill -0`
# succeeds on a zombie, which has nonetheless stopped serving.
assert_server_gone() {
	local pid state
	pid="$(cat "$WORK/xvfb.pid")"
	for _ in $(seq 50); do
		kill -0 "$pid" 2>/dev/null || return 0
		state="$(sed -n "s/^[0-9]* (.*) \([A-Za-z]\) .*/\1/p" "/proc/$pid/stat" 2>/dev/null || true)"
		[ "$state" != Z ] || return 0
		sleep 0.1
	done
	fail "$1: the Xvfb (pid $pid) outlived the script"
}

# 1. A slow but working server.
run_case delay XVFB_DELAY=3
[ -f "$WORK/specs-started" ] || fail "slow Xvfb: the specs never started: $(cat "$WORK/stderr")"
[ "$status" -eq 0 ] ||
	fail "slow Xvfb: the specs started before the display answered (exit $status): $(cat "$WORK/stderr")"
assert_server_gone "slow Xvfb"

# 2. A server that dies: the script notices at once, not when the default
# 60 s bound passes.
started=$SECONDS
run_case die
took=$((SECONDS - started))
[ "$status" -ne 0 ] || fail "dead Xvfb: the script succeeded"
[ ! -f "$WORK/specs-started" ] || fail "dead Xvfb: the specs started without a display"
grep -q "Xvfb" "$WORK/stderr" || fail "dead Xvfb: the failure does not name Xvfb: $(cat "$WORK/stderr")"
grep -q "cannot open the display" "$WORK/stderr" ||
	fail "dead Xvfb: the failure does not carry the server's output: $(cat "$WORK/stderr")"
[ "$took" -le 15 ] ||
	fail "dead Xvfb: the script took ${took}s to notice the server had exited"

# 3. A server that never answers.
started=$SECONDS
run_case hang CODETRACER_XVFB_WAIT_SECONDS=3
took=$((SECONDS - started))
[ "$status" -ne 0 ] || fail "silent Xvfb: the script succeeded"
[ ! -f "$WORK/specs-started" ] || fail "silent Xvfb: the specs started without a display"
grep -q "Xvfb" "$WORK/stderr" || fail "silent Xvfb: the failure does not name Xvfb: $(cat "$WORK/stderr")"
[ "$took" -le 15 ] || fail "silent Xvfb: the script took ${took}s against a 3s bound"
assert_server_gone "silent Xvfb"

# 4. A bound that is not a number.
run_case delay XVFB_DELAY=0 CODETRACER_XVFB_WAIT_SECONDS=soon
[ "$status" -ne 0 ] || fail "bad bound: the script succeeded"
[ ! -f "$WORK/specs-started" ] || fail "bad bound: the specs started"
[ ! -f "$WORK/xvfb.pid" ] || fail "bad bound: a server was started before the bound was checked"
grep -q "CODETRACER_XVFB_WAIT_SECONDS" "$WORK/stderr" ||
	fail "bad bound: the refusal does not name CODETRACER_XVFB_WAIT_SECONDS: $(cat "$WORK/stderr")"

# 5. A bound with a leading zero is a decimal number of seconds, not an
# octal one bash arithmetic refuses ("value too great for base").
started=$SECONDS
run_case hang CODETRACER_XVFB_WAIT_SECONDS=08
took=$((SECONDS - started))
[ "$status" -ne 0 ] || fail "bound 08: the script succeeded"
[ ! -f "$WORK/specs-started" ] || fail "bound 08: the specs started without a display"
grep -q "did not answer within 8s" "$WORK/stderr" ||
	fail "bound 08: the failure is not the 8 s bound passing: $(cat "$WORK/stderr")"
[ "$took" -le 20 ] || fail "bound 08: the script took ${took}s against an 8s bound"
assert_server_gone "bound 08"

# B. No launch of Xvfb outside the helper.
#
# In shell (tracked *.sh, *.bash, the justfile and ci/) a launch is Xvfb in
# command position — after a line start, blank, `;`, `&`, `|` or `(`,
# optionally behind exec/nohup/setsid/command — followed by an argument
# (`Xvfb :99 …`, `Xvfb "…"`, `Xvfb '…'`, `Xvfb -…`, `Xvfb +…`, `Xvfb $…`),
# a line continuation or `&`; or, at the start of a line, a variable whose
# name holds "xvfb" used as the command with such an argument
# (`"$xvfb_bin" :99 …`). A comment, a message, a lookup (`command -v Xvfb`)
# or `xvfb-run`, which waits for its server itself, is not a launch.
# In the other languages that spawn processes here (Python, TypeScript,
# JavaScript, Nim, Ruby) a launch is "Xvfb" as a quoted argv element:
# `Popen(["Xvfb", …`, `spawn("Xvfb", […`, `startProcess("Xvfb", …`.
shell_launches() {
	{
		grep -HnE '(^|[[:space:];&|(])((exec|nohup|setsid|command)[[:space:]]+)*Xvfb([[:space:]]+(-|\+|"|'"'"'|:|\$|\\$)|[[:space:]]*&([^&]|$))' "$@"
		# xvfb-run waits for its server itself, so a variable naming it is
		# not a launch.
		grep -HnE '^[[:space:]]*((exec|nohup|setsid|command)[[:space:]]+)*"?\$\{?[A-Za-z_]*[Xx][Vv][Ff][Bb][A-Za-z_]*\}?"?[[:space:]]+(-|\+|"|:|\$)' "$@" |
			grep -viE '\$\{?[A-Za-z_]*xvfb_?run'
	} | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' || true
}
argv_launches() {
	grep -HnE "[\"']Xvfb[\"'][[:space:]]*[,)]" "$@" |
		grep -vE '^[^:]*:[0-9]+:[[:space:]]*(#|//)' || true
}
# Planted copies of the old pattern, and of the forms a narrower gate missed,
# prove each matcher reddens; a planted lookup and message prove it does not
# redden on what is not a launch.
plant_dir="$WORK/planted"
mkdir -p "$plant_dir"
# shellcheck disable=SC2016 # the planted text is literal shell
printf '%s\n' 'Xvfb ":${display_num}" -screen 0 1920x1080x24 -nolisten tcp &' >"$plant_dir/old.sh"
printf '%s\n' 'exec Xvfb :99 -screen 0 1920x1080x24' >"$plant_dir/exec.sh"
printf '%s\n' 'cd /tmp && Xvfb :99 &' >"$plant_dir/after-and.sh"
# shellcheck disable=SC1003 # a backslash at the end of the planted line
printf '%s\n' 'nohup Xvfb \' '  :99 -screen 0 1920x1080x24 &' >"$plant_dir/continued.sh"
# shellcheck disable=SC2016 # the planted text is literal shell
printf '%s\n' '	"$xvfb_bin" ":$n" -screen 0 1920x1080x24 &' >"$plant_dir/indirect.sh"
printf '%s\n' 'xvfb = subprocess.Popen(["Xvfb", f":{n}", "-screen", "0"])' >"$plant_dir/spawn.py"
printf '%s\n' "spawn('Xvfb', [':99'])" >"$plant_dir/spawn.ts"
for planted in "$plant_dir"/*.sh; do
	[ -n "$(shell_launches "$planted")" ] || fail "gate: the planted launch in $(basename "$planted") was not found"
done
for planted in "$plant_dir"/*.py "$plant_dir"/*.ts; do
	[ -n "$(argv_launches "$planted")" ] || fail "gate: the planted launch in $(basename "$planted") was not found"
done
# shellcheck disable=SC2016 # the planted text is literal shell
printf '%s\n' 'command -v Xvfb >/dev/null' 'echo "Starting Xvfb..."' '# Xvfb :99 &' \
	'"${xvfb_run}" -a electron .' 'xvfb-run -a -s "-screen 0 1920x1080x24" cmd' >"$plant_dir/benign.bash"
[ -z "$(shell_launches "$plant_dir/benign.bash")" ] ||
	fail "gate: a lookup, a message, a comment or xvfb-run read as a launch: $(shell_launches "$plant_dir/benign.bash")"

exempt=scripts/docs/deep-review-capture-lib.sh
mapfile -t shell_files < <(cd "$REPO" && git ls-files -- '*.sh' '*.bash' justfile 'ci/*' |
	grep -vxE "scripts/lib/own-xvfb\.sh|scripts/test-own-xvfb\.sh|${exempt//./\\.}")
mapfile -t argv_files < <(cd "$REPO" && git ls-files -- '*.py' '*.ts' '*.js' '*.mjs' '*.cjs' '*.nim' '*.rb')
offenders="$(cd "$REPO" && shell_launches "${shell_files[@]}" && argv_launches "${argv_files[@]}")"
[ -z "$offenders" ] ||
	fail "these launch Xvfb without scripts/lib/own-xvfb.sh, so their clients can start before it answers:
$offenders"
# The exemption covers the one launch in ctdr_start_xvfb, not the file: a
# second launch there is an offender too.
exempt_launches="$(cd "$REPO" && shell_launches "$exempt" | grep -cv ':[[:space:]]*ctdr_require_cmd ' || true)"
[ "$exempt_launches" -eq 1 ] ||
	fail "$exempt should launch Xvfb once (ctdr_start_xvfb), found $exempt_launches:
$(cd "$REPO" && shell_launches "$exempt")"

echo "PASS: every own Xvfb is started through scripts/lib/own-xvfb.sh, which waits for it to answer and names it when it never does"
