#!/usr/bin/env bash
# ci/test/memory-sampler-test.sh -- the TUI and GPUI shards record what holds
# their memory, so an OOM kill at the runner's cap names its culprit.
#
# Holds that ci/lib/memory-sampler.sh writes timestamped samples with the
# job's memory use and its top processes by RSS, keeps going until killed, and
# that tui-tests.yml and gpui-window-captures.yml start it right after their
# checkout (before any provisioning or build) and upload its log, per shard,
# when the job fails or is cancelled.
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

echo "the sampler"
# A process with a recognisable name and a known resident size. Every process
# is listed (MEMORY_SAMPLER_TOP), so the check does not depend on what else the
# host runs.
python3 -c 'import time; b = bytearray(64 * 1024 * 1024); time.sleep(8)' &
hog=$!
MEMORY_SAMPLER_TOP=100000 timeout 4.5 bash ci/lib/memory-sampler.sh "$work/samples.log" 1 || true
kill "$hog" 2>/dev/null || true
wait "$hog" 2>/dev/null || true
n="$(grep -c '^=== ' "$work/samples.log" || true)"
check "it samples every interval until killed (${n} samples in 4.5 s)" "${n} samples in 4.5 s at 1 s" test "$n" -ge 2
check "each sample states the memory in use" "no memory total: $(head -1 "$work/samples.log")" \
	grep -qE '^=== [0-9T:Z-]+ (cgroup|host used) [0-9]+ MiB' "$work/samples.log"
check "and names processes with their RSS" "no process lines" \
	grep -qE '^ *[0-9]+ +[0-9]+ +[0-9]+ +[0-9]+ ' "$work/samples.log"
check "a 64 MiB process shows up in it" "the 64 MiB process is missing from the samples" \
	grep -q "bytearray(64" "$work/samples.log"

echo "the shard jobs run it"
for f in .github/workflows/tui-tests.yml .github/workflows/gpui-window-captures.yml; do
	steps="$(grep -n '^      - name: ' "$f")"
	co="$(grep -m1 ': *- name: Checkout$' <<<"$steps" | cut -d: -f1)"
	next="$(awk -F: -v co="$co" '$1 > co { print; exit }' <<<"$steps")"
	check "$f starts the sampler right after its checkout" "$f: the step after Checkout is '${next#*- name: }'" \
		grep -q 'Sample memory in the background$' <<<"$next"
	check "$f runs ci/lib/memory-sampler.sh in the background" "$f does not start the sampler" \
		grep -qE 'nohup bash ci/lib/memory-sampler.sh .*&$' "$f"
	up="$(sed -n '/- name: Upload the memory samples$/,/retention-days/p' "$f")"
	# shellcheck disable=SC2016 # the workflow expression, literally
	on_failure='if: \${{ failure() || cancelled() }}'
	check "$f uploads the samples when the job fails or is cancelled" "$f: no upload on failure" \
		grep -q "$on_failure" <<<"$up"
	check "$f names the artifact per shard" "$f: the artifact name is not per shard" \
		grep -qE 'name: memory-samples-[a-z]+-\$\{\{ matrix.shard \}\}' <<<"$up"
done

echo
if [ "$failures" -gt 0 ]; then
	echo "$failures failure(s)"
	exit 1
fi
echo "all checks passed"
