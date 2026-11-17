#!/usr/bin/env bash
# ci/test/push-built-closure-test.sh -- a job pushes what it built to the cache,
# only from dev and agents, and never fails for it.
#
# Drives ci/deploy/push-built-closure.sh with a fake `attic`, `nix` and
# `nix-store` on PATH, and reads the workflows for where it runs. It holds that:
#   * on agents it logs in and pushes the GC-rooted shells' closure, #codetracer
#     with its build closure, and the flake's inputs;
#   * on a feature branch, a pull request's merge ref, or without the Attic
#     secrets it pushes nothing;
#   * a push that keeps failing is retried three times and the script still
#     exits 0, as does a failed login;
#   * with CT_JOB_STARTED_AT and CT_JOB_TIMEOUT_MINUTES it pushes only within
#     what the job's limit leaves;
#   * GPUI shard 1 (at its end), test-ui-tests' nixos leg and test-ui-tests-rr
#     (after their build) run it, gated on dev/agents, with continue-on-error
#     and their own timeout-minutes;
#   * no job that another job `needs` pushes -- ct-build in particular, which
#     every GPUI and TUI shard waits for.
set -euo pipefail
cd "$(dirname "$0")/../.."
failures=0
fail() {
	echo "  FAIL $*"
	failures=$((failures + 1))
}
ok() { echo "  ok   $*"; }
check() {
	local good="$1" bad="$2"
	shift 2
	if "$@"; then ok "$good"; else fail "$bad"; fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/roots" "$work/store"
for p in shell-a shell-b ct-out noir; do : >"$work/store/$p"; done
ln -s "$work/store/shell-a" "$work/roots/codetracer-ci"

# attic: logs its argv; fails `push` while $work/attic-fail exists, `login`
# while $work/login-fail exists.
cat >"$work/bin/attic" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$work/attic.log"
[ "\$1" = push ] && [ -e "$work/attic-fail" ] && exit 1
[ "\$1" = login ] && [ -e "$work/login-fail" ] && exit 1
exit 0
EOF
cat >"$work/bin/nix" <<EOF
#!/usr/bin/env bash
case "\$*" in
"build --no-link --print-out-paths .?submodules=1#codetracer") echo "$work/store/ct-out" ;;
"path-info --derivation .?submodules=1#codetracer") echo "/nix/store/x-codetracer.drv" ;;
*) exit 1 ;;
esac
EOF
cat >"$work/bin/nix-store" <<EOF
#!/usr/bin/env bash
case "\$*" in
"-qR --include-outputs /nix/store/x-codetracer.drv") printf '%s\n' /nix/store/x-codetracer.drv "$work/store/noir" ;;
"-qR $work/roots/codetracer-ci") printf '%s\n' "$work/store/shell-a" "$work/store/shell-b" ;;
*) exit 1 ;;
esac
EOF
cat >"$work/bin/python3" <<EOF
#!/usr/bin/env bash
[ "\$1" = ci/deploy/flake-input-paths.py ] && { echo /nix/store/input-src; exit 0; }
exec "$(command -v python3)" "\$@"
EOF
chmod +x "$work/bin/"*

run() {
	rm -f "$work/attic.log"
	env PATH="$work/bin:$PATH" ATTIC_ENDPOINT=https://cache.example ATTIC_CACHE=c ATTIC_TOKEN=t \
		ATTIC_RETRY_SLEEP=0 "$@" bash ci/deploy/push-built-closure.sh \
		--gcroots "$work/roots" --codetracer --flake-inputs >"$work/out.log" 2>&1
}
pushes() {
	[ -f "$work/attic.log" ] || {
		echo 0
		return
	}
	grep -c '^push ' "$work/attic.log" || true
}
: >"$work/out.log"

echo "on agents it pushes what the job built"
check "exits 0" "exited non-zero: $(cat "$work/out.log")" run GITHUB_REF_NAME=agents
check "logs in" "no attic login" grep -q '^login --set-default codetracer-ci https://cache.example t' "$work/attic.log"
check "pushes the rooted shells' closure" "shells not pushed: $(cat "$work/attic.log")" \
	grep -q "^push c $work/store/shell-a $work/store/shell-b\$" "$work/attic.log"
check "pushes #codetracer with its realised build closure" "codetracer not pushed: $(cat "$work/attic.log")" \
	grep -q "^push c $work/store/ct-out $work/store/noir\$" "$work/attic.log"
check "pushes the flake's inputs" "inputs not pushed" grep -q '^push c /nix/store/input-src$' "$work/attic.log"
run GITHUB_REF_NAME=dev
check "on dev too" "dev pushed $(pushes) set(s)" test "$(pushes)" = 3

echo "elsewhere it pushes nothing"
for ref in feature/x 1234/merge ""; do
	run GITHUB_REF_NAME="$ref"
	check "'${ref}': nothing pushed, exit 0" "'${ref}' pushed $(pushes) set(s)" test "$(pushes)" = 0
done
rm -f "$work/attic.log"
env PATH="$work/bin:$PATH" GITHUB_REF_NAME=agents ATTIC_ENDPOINT=x ATTIC_CACHE=c \
	bash ci/deploy/push-built-closure.sh --flake-inputs >"$work/out.log" 2>&1
check "without ATTIC_TOKEN: nothing pushed" "pushed without a token" test ! -e "$work/attic.log"

echo "a failure never fails the job"
touch "$work/attic-fail"
check "exits 0 when every push fails" "exited non-zero when pushes failed" run GITHUB_REF_NAME=agents
check "each push was tried three times" "expected 9 push attempts, saw $(pushes)" test "$(pushes)" = 9
check "and says so" "no failure report: $(cat "$work/out.log")" grep -q "with failures" "$work/out.log"
rm -f "$work/attic-fail"
touch "$work/login-fail"
check "exits 0 when login fails" "exited non-zero on a failed login" run GITHUB_REF_NAME=agents
check "and pushes nothing" "pushed after a failed login" test "$(pushes)" = 0
rm -f "$work/login-fail"
check "a spent budget stops further pushes, exit 0" "budget not honoured" \
	run GITHUB_REF_NAME=agents CT_CACHE_PUSH_BUDGET=0
check "nothing pushed with a zero budget" "pushed $(pushes) set(s) with a zero budget" test "$(pushes)" = 0

echo "a job near its limit does not push"
check "exits 0 with no time left in the job" "exited non-zero" \
	run GITHUB_REF_NAME=agents CT_JOB_TIMEOUT_MINUTES=90 CT_JOB_STARTED_AT="$(($(date +%s) - 85 * 60))"
check "and pushes nothing" "pushed $(pushes) set(s) with 5 minutes left" test "$(pushes)" = 0
check "with time left it pushes" "pushed $(pushes) set(s) with the job's limit far off" \
	run GITHUB_REF_NAME=agents CT_JOB_TIMEOUT_MINUTES=90 CT_JOB_STARTED_AT="$(date +%s)"
test "$(pushes)" = 3 || fail "expected 3 pushes with time left, saw $(pushes)"

echo "the jobs that build run it, gated, best effort and off the shards' path"
# step_block FILE LINE: the step starting at LINE, up to the next step.
step_block() {
	{
		cat "$1"
		echo "      - name: end"
	} | sed -n "${2},\$p" | sed -n '1p;2,/^      - name:/p' | sed '$d'
}
# job_timeout FILE LINE: the timeout-minutes of the job holding LINE.
job_timeout() {
	head -n "$2" "$1" | grep -E '^    timeout-minutes: [0-9]+' | tail -1 | grep -oE '[0-9]+$'
}
for spec in \
	".github/workflows/gpui-window-captures.yml|Push the dev shells this shard realised to the cache|1" \
	".github/workflows/codetracer.yml|Push the build to the cache|2"; do
	IFS='|' read -r f name want <<<"$spec"
	n="$(grep -c "name: ${name}\$" "$f")"
	check "$f has ${want} '${name}' step(s)" "$f has ${n}" test "$n" = "$want"
	while read -r line; do
		block="$(step_block "$f" "$line")"
		check "  line ${line}: gated on dev/agents" "line ${line}: not gated on dev and agents" \
			grep -q "github.ref_name == 'dev' || github.ref_name == 'agents'" <<<"$block"
		check "  line ${line}: continue-on-error" "line ${line}: a push failure would fail the job" \
			grep -q "continue-on-error: true" <<<"$block"
		check "  line ${line}: runs push-built-closure.sh" "line ${line}: does not run the script" \
			grep -q "ci/deploy/push-built-closure.sh" <<<"$block"
		t="$(job_timeout "$f" "$line")"
		check "  line ${line}: CT_JOB_TIMEOUT_MINUTES is the job's ${t}" \
			"line ${line}: CT_JOB_TIMEOUT_MINUTES differs from the job's timeout-minutes (${t})" \
			grep -q "CT_JOB_TIMEOUT_MINUTES: ${t}\$" <<<"$block"
	done < <(grep -n "name: ${name}\$" "$f" | cut -d: -f1)
done
check "the GPUI push runs on one shard only" "the GPUI push is not limited to one shard" \
	grep -q "matrix.shard == 1 &&" <(step_block .github/workflows/gpui-window-captures.yml \
		"$(grep -n 'name: Push the dev shells this shard realised to the cache$' .github/workflows/gpui-window-captures.yml | cut -d: -f1)")

# Nothing a job `needs` may push: a needed job holds its dependants until it
# ends, so a push there would sit on their critical path (ct-build's did, in
# front of every GPUI and TUI shard).
needed="$(grep -hoE '^    needs: *(\[[^]]*\]|[A-Za-z0-9_-]+)' .github/workflows/*.yml |
	sed -E 's/^    needs: *//; s/[][,]/ /g' | tr ' ' '\n' | grep -v '^$' | sort -u)"
pushing=""
for wf in .github/workflows/*.yml; do
	# jobs in this file that run the push, directly or through a called workflow
	while read -r job; do
		[ -n "$job" ] && pushing="${pushing} ${job}"
	done < <(awk -v wf="$wf" '
		/^  [A-Za-z0-9_-]+:[[:space:]]*$/ { job = $1; sub(":", "", job) }
		/push-built-closure\.sh/ && job != "" { print job }
		/^    uses: \.\/\.github\/workflows\// && job != "" {
			f = $2; sub("^\\./", "", f)
			while ((getline l < f) > 0) if (l ~ /push-built-closure\.sh/) { print job; break }
			close(f)
		}' "$wf" | sort -u)
done
bad=""
for j in $pushing; do
	if grep -qx "$j" <<<"$needed"; then bad="${bad} ${j}"; fi
done
[ -n "$pushing" ] || fail "found no job that pushes: the needs check proves nothing"
check "no job another job needs runs a push (pushing:${pushing})" \
	"needed by another job yet pushes:${bad}" test -z "$bad"
check "ct-build in particular does not push" "ct-build.yml runs the push" \
	test "$(grep -c push-built-closure.sh .github/workflows/ct-build.yml)" = 0

echo
if [ "$failures" -gt 0 ]; then
	echo "$failures failure(s)"
	exit 1
fi
echo "all checks passed"
