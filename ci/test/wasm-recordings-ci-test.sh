#!/usr/bin/env bash
# Source-shape contract for the real fixture lane. No tools are mocked: the
# fixture entry point separately exercises fresh recordings and replay controls.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
workflow="${1:-.github/workflows/codetracer.yml}"
job() { sed -n "/^  $1:/,/^  [a-zA-Z0-9_-]*:/p" "$workflow" | sed '$d'; }
lane="$(job wasm-recordings)"
fail() {
	echo "wasm-recordings-ci: $*" >&2
	exit 1
}
[[ -n $lane ]] || fail 'missing wasm-recordings job'
grep -Fq 'uses: metacraft-labs/metacraft-github-actions/setup-dev-env@dev' <<<"$lane" || fail 'missing lock-pinned setup action'
grep -Eq "^[[:space:]]+codetracer-trace-format[[:space:]]*$" <<<"$lane" || fail 'missing lock-pinned Rust trace writer'
for sibling in codetracer-wasm-recorder codetracer-wasm-instrumenter codetracer-trace-format-nim; do
	grep -Eq "^[[:space:]]+${sibling}[[:space:]]*$" <<<"$lane" || fail "$sibling must resolve from the committed lock"
	# Check the command in the same step as its working directory: merely naming
	# the producer does not build it, and another producer's build is no substitute.
	awk -v directory="../$sibling" '
    /^      - / { selected = 0 }
    $1 == "working-directory:" { selected = ($2 == directory) }
    selected && $0 == "        run: nix develop . --command just build" { found = 1 }
    END { exit !found }
  ' <<<"$lane" || fail "$sibling must be built in its own development environment"
done
for command in \
	'        run: nix develop .#ci --command cargo build --locked --manifest-path src/backend-manager/Cargo.toml' \
	'        run: nix develop .#ci --command just verify-wasm-recordings'; do
	grep -Fxq -- "$command" <<<"$lane" || fail "missing required command: $command"
done
if grep -Eq 'continue-on-error:|if:|\|\|[[:space:]]*(true|:)' <<<"$lane"; then
	fail 'the required fixture lane must not suppress failures or skip steps'
fi
grep -Eq '^      - wasm-recordings$' <<<"$(job ci-verdict)" || fail 'ci-verdict must require the fixture lane'
grep -Fxq '  bash ci/test/wasm-recordings.sh' justfile || fail 'fixture recipe must execute the fixture entry point'
for fixture in wasm-memory-calldata wasm-nan-payloads wasm-parity-corpus; do
	grep -qF "$fixture" ci/test/wasm-recordings.sh || fail "fixture entry point omits $fixture"
done
echo 'wasm-recordings-ci: OK'
