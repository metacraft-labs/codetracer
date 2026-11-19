#!/usr/bin/env bash
# ci/test/trace-format-nim-extra-paths-test.sh -- every workflow that hands
# codetracer-trace-format-nim's Nim build codetracer's libraries puts
# libs/nim-result last.
#
# CODETRACER_TRACE_FORMAT_NIM_EXTRA_PATHS becomes --path flags, and Nim gives
# the last --path precedence. With libs/nim-stew/stew on the path and no
# libs/nim-result after it, `import results` resolves to stew's legacy copy,
# which has no `unsafeError` and a `func mapErr` that nim-fork 2.3.1 refuses
# for a closure argument. Run 44384977215's visual-replay regression gate
# failed that way while ct-build, which listed libs/nim-result, built the
# same sources. Run by ci/lint/bash.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."
failures=0
checked=0
while IFS= read -r hit; do
	checked=$((checked + 1))
	if [[ "$hit" == *'/libs/nim-result' ]]; then
		echo "  ok   ${hit%%:*}:$(cut -d: -f2 <<<"$hit") ends with libs/nim-result"
	else
		echo "  FAIL ${hit%%:*}:$(cut -d: -f2 <<<"$hit") does not end with libs/nim-result"
		failures=$((failures + 1))
	fi
done < <(grep -n -E '^\s+CODETRACER_TRACE_FORMAT_NIM_EXTRA_PATHS: ' .github/workflows/*.yml | sed -E 's/[[:space:]]+$//')
if [ "$checked" -lt 5 ]; then
	echo "  FAIL found only ${checked} setting(s); expected at least 5"
	failures=$((failures + 1))
fi
echo
if [ "$failures" -gt 0 ]; then
	echo "$failures failure(s)"
	exit 1
fi
echo "all ${checked} settings checked"
