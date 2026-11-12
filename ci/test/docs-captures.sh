#!/usr/bin/env bash
# ci/test/docs-captures.sh [--check] — the documentation's captures, made by
# the scenarios that assert them (Capture-Pipeline.md; user-documentation.md
# §3.5: "No image is captured by a human. Each is produced by a named
# scenario").
#
# A page of docs/book-isonim/content cites a capture by scenario and capture
# name, never by a path:
#
#   <!-- capture scenario=docs/terminal-trace-macro capture=the-macro-traced-in-a-new-tab -->
#   ```text
#   …the capture's text…
#   ```
#   <!-- /capture -->
#
# This script runs every cited scenario DETERMINISTICALLY on the terminal
# (DemoVideoScript `--deterministic`: virtual time, every capture taken twice
# and required byte-identical, the declared volatile regions masked), resolves
# each citation with `dvs capture-path`, and writes the capture between the
# markers. The volatile region a terminal capture of CodeTracer has is the
# status line (the replay's absolute path and tick): it is pinned.
#
# With --check it changes nothing and fails, with a diff, when a page's
# capture is not what the scenario produces now — a capture that changed
# without its scenario changing is a build failure, as a golden is.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}"
check=0
[ "${1:-}" = "--check" ] && check=1
build="$(mktemp -d)"
trap 'rm -rf "${build}"' EXIT
pages=docs/book-isonim/content
mapfile -t cites < <(grep -rhoE '<!-- capture scenario=[^ ]+ capture=[^ ]+ -->' "${pages}" | sort -u)
[ "${#cites[@]}" -gt 0 ] || {
	echo "docs-captures: no page cites a capture"
	exit 1
}
declare -A ran=()
status=0
for cite in "${cites[@]}"; do
	scenario="$(sed -E 's/.*scenario=([^ ]+).*/\1/' <<<"${cite}")"
	capture="$(sed -E 's/.*capture=([^ ]+) .*/\1/' <<<"${cite}")"
	if [ -z "${ran[${scenario}]:-}" ]; then
		bash ci/test/scenarios.sh run terminal "src/tests/scenarios/${scenario}.yaml" \
			--deterministic --pin status-line --record always --build "${build}" >"${build}/run.log" 2>&1 || {
			cat "${build}/run.log"
			echo "docs-captures: ${scenario} failed; its captures are not trustworthy" >&2
			exit 1
		}
		ran[${scenario}]=1
	fi
	file="$(build/bin/dvs capture-path "scenario=${scenario}" "capture=${capture}" \
		--backend termassert --build "${build}" | grep '\.txt$' | head -1)"
	[ -n "${file}" ] && [ -f "${file}" ] || {
		echo "docs-captures: ${scenario} has no capture '${capture}'" >&2
		exit 1
	}
	for page in $(grep -rlF "${cite}" "${pages}"); do
		python3 - "${page}" "${cite}" "${file}" "${check}" <<'EOF' || status=1
import sys, difflib
page, cite, capfile, check = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
text = open(page).read()
cap = open(capfile).read().rstrip("\n")
start = text.index(cite) + len(cite)
end = text.index("<!-- /capture -->", start)
block = "\n```text\n" + cap + "\n```\n"
if text[start:end] == block:
    sys.exit(0)
if check:
    print(f"docs-captures: {page}: the capture '{cite}' differs from what its scenario produces now:")
    sys.stdout.writelines(difflib.unified_diff(text[start:end].splitlines(True), block.splitlines(True),
                                               "page", "scenario"))
    sys.exit(1)
open(page, "w").write(text[:start] + block + text[end:])
print(f"docs-captures: {page}: wrote '{cite}'")
EOF
	done
done
exit "${status}"
