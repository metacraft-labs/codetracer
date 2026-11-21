#!/usr/bin/env bash
# ci/test/job-lifetime-test.sh -- the CI's background helpers end with the job
# that started them (ci/lib/job-lifetime.sh).
#
# A copy of bash named Runner.Worker stands in for the job's worker and starts
# ci/lib/memory-sampler.sh under it, as a job step does with `nohup ... &`.
#   * while the fake worker lives, the sampler keeps sampling;
#   * once it exits, the sampler stops within an interval or two;
#   * with no worker ancestor, CT_HELPER_MAX_SECONDS still ends it.
# Run by ci/lint/bash.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."
root="$PWD"
failures=0
fail() {
	echo "  FAIL $*"
	failures=$((failures + 1))
}
ok() { echo "  ok   $*"; }

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/job-lifetime.XXXXXX")"
cleanup() {
	[ -s "$work/sampler.pid" ] && kill "$(cat "$work/sampler.pid")" 2>/dev/null
	[ -s "$work/sampler2.pid" ] && kill "$(cat "$work/sampler2.pid")" 2>/dev/null
	rm -rf "$work"
}
trap cleanup EXIT
cp "$(command -v bash)" "$work/Runner.Worker"

# The fake worker starts the sampler, then lives until its stop file appears.
# shellcheck disable=SC2016 # the script expands its own positional parameters
"$work/Runner.Worker" -c '
	nohup bash "$1/ci/lib/memory-sampler.sh" "$2/samples.log" 1 >/dev/null 2>&1 &
	echo $! >"$2/sampler.pid"
	while [ ! -e "$2/stop" ]; do sleep 0.2; done
' worker "$root" "$work" &
worker=$!
for _ in $(seq 1 50); do [ -s "$work/sampler.pid" ] && break; sleep 0.1; done
sampler="$(cat "$work/sampler.pid")"

sleep 3
if kill -0 "$sampler" 2>/dev/null && [ "$(grep -c '^===' "$work/samples.log" 2>/dev/null || echo 0)" -ge 2 ]; then
	ok "while the job's Runner.Worker lives, the sampler keeps sampling"
else
	fail "the sampler stopped (or never sampled) while its Runner.Worker was alive"
fi

touch "$work/stop"
wait "$worker" 2>/dev/null || true
for _ in $(seq 1 40); do kill -0 "$sampler" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$sampler" 2>/dev/null; then
	fail "the sampler outlived its Runner.Worker by more than 4 s (pid $sampler)"
else
	ok "once the Runner.Worker is gone, the sampler ends"
fi

# No worker ancestor: only the age bound applies, and it is honoured.
CT_HELPER_MAX_SECONDS=2 nohup bash ci/lib/memory-sampler.sh "$work/samples2.log" 1 >/dev/null 2>&1 &
echo $! >"$work/sampler2.pid"
for _ in $(seq 1 60); do kill -0 "$(cat "$work/sampler2.pid")" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$(cat "$work/sampler2.pid")" 2>/dev/null; then
	fail "with no Runner.Worker, CT_HELPER_MAX_SECONDS=2 did not end the sampler"
else
	ok "with no Runner.Worker ancestor, the age bound ends it"
fi

echo
if [ "$failures" -gt 0 ]; then
	echo "$failures failure(s)"
	exit 1
fi
echo "all checks passed"
