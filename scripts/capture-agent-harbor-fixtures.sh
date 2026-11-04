#!/usr/bin/env bash
# Refresh the Agent Harbor fixture sets and prove they are where they belong.
#
#   just capture-agent-harbor-fixtures [--only fleet,plans,diffs,tests,scenarios]
#                                      [--out <dir>] [--sources <file>]
#                                      [--workspace <dir>]
#   just check-agent-harbor-fixtures   [--fixtures <dir>]... [--public-root <dir>]...
#
# 1. tools/agent-harbor-fixtures/capture.mjs captures every part of the
#    PRIVATE set (a read-only snapshot of the Agent Harbor server the local
#    `ah` CLI is configured with, campaign plans, branch diffs, `ct test` runs
#    with a trace, and agents driven by scenario files on Agent Harbor's mock
#    server and mock agent) and writes them, scrubbed, to the private design
#    directory beside this checkout. What it captures, and which Agent Harbor
#    binaries it runs, is named by that directory's capture-sources.json.
# 2. tools/agent-harbor-fixtures/synthesize.mjs rewrites the SYNTHETIC set in
#    ../nim-agents-isonim-viewmodels/fixtures/agent-harbor: invented data in
#    the same shapes, the only set a public repository commits.
# 3. scrub-check.mjs fails if a fixture carries a credential, a prompt or an
#    infrastructure identifier (comparing against the raw prompt strings the
#    capture kept OUTSIDE every repository), or if any public repository's
#    tree carries a credential, a private fixture, a private design document,
#    a session id of the private snapshot, or an excerpt of a private fixture
#    (edited, reflowed or reindented ones too). Without the private set the
#    excerpt part is skipped, and the check says so loudly.
# 4. scrub-check.mjs --self-test plants a credential, a prompt, private
#    fixtures and edited excerpts of them, and requires the check to fail on
#    each: its vacuity guard.
#
# Prerequisites for a capture: `ct` built in this checkout (`just build-once`)
# and the Agent Harbor mock server and mock agent built in their checkout's
# dev shell (capture-sources.json gives the commands). The script never builds
# them itself: building another repository is that repository's own process.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if command -v node >/dev/null 2>&1; then
	node_cmd=(node)
else
	node_cmd=(nix shell nixpkgs#nodejs --command node)
fi

raw_dir="${AH_FIXTURE_RAW_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/codetracer-agent-harbor-capture-$(id -u)}"

mode="${1:-capture}"
shift || true

check_args=()
capture_args=()
while [ "$#" -gt 0 ]; do
	case "$1" in
	--out)
		capture_args+=(--out "$2")
		check_args+=(--fixtures "$2")
		shift 2
		;;
	--fixtures | --public-root)
		check_args+=("$1" "$2")
		shift 2
		;;
	*)
		capture_args+=("$1")
		shift
		;;
	esac
done

case "$mode" in
capture)
	"${node_cmd[@]}" tools/agent-harbor-fixtures/capture.mjs --raw "$raw_dir" "${capture_args[@]}"
	"${node_cmd[@]}" tools/agent-harbor-fixtures/synthesize.mjs
	;;
check) ;;
*)
	echo "capture-agent-harbor-fixtures.sh: unknown mode '$mode' (capture or check)" >&2
	exit 2
	;;
esac

raw_args=()
if [ -f "$raw_dir/private-strings.json" ]; then
	raw_args=(--raw "$raw_dir")
fi
"${node_cmd[@]}" tools/agent-harbor-fixtures/scrub-check.mjs "${check_args[@]}" "${raw_args[@]}"
"${node_cmd[@]}" tools/agent-harbor-fixtures/scrub-check.mjs --self-test
