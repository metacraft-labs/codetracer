#!/usr/bin/env bash
#
# python-recorder-follows-trace-format-pair-test.sh -- the `codetracer-python-
# recorder` flake input follows this repository's trace-format pair, as the
# ruby and js recorder inputs do, so the recorder never links a Rust crate and
# a Nim archive taken from different revisions.
#
# The recorder's flake declares its own `codetracer-trace-format` and
# `codetracer-trace-format-nim` inputs and locks them. Unless codetracer's
# `flake.nix` makes those names `follows` its root inputs, the recorder is
# built against its own pins, which can predate the trace-writer FFI the root
# pair's Rust calls. At the lock this test was written against, the recorder's
# `codetracer-trace-format-nim` resolved to `5802203c` while the root resolved
# to `d282be4`, and its `codetracer-trace-format` to `8794892b` against `1f360fa`.
#
# Asserted, in the lock and in `flake.nix`:
#   1. The `codetracer-python-recorder` node takes each of the two names from
#      the root, as a `follows` path (`["<name>"]`), not as its own node. A
#      follows is the structural fact: two equal pins would pass a revision
#      comparison by coincidence, and a later lock bump would then split them.
#   2. `flake.nix`'s `codetracer-python-recorder` input declares both
#      `follows`, so the next relock keeps them.
#   3. The recorder's own flake exposes both names: the lock records the input
#      names the recorder declares, and the test refuses to pass if either is
#      missing from that node.
#
# No `nix` invocation: this reads the lock and the flake source, so it runs in
# seconds and needs `jq` only. The build-level check, that the dev shell links
# the writer it was compiled against, is ci/test/dev-shell-python-recorder-
# ffi-pair-test.sh.
#
#   bash ci/test/python-recorder-follows-trace-format-pair-test.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly INPUT=codetracer-python-recorder
readonly NAMES=(codetracer-trace-format codetracer-trace-format-nim)

if ! command -v jq >/dev/null 2>&1; then
	echo "FAIL: jq is required to read $REPO/flake.lock" >&2
	exit 1
fi

lock="$REPO/flake.lock"
flake="$REPO/flake.nix"
failures=0

# The lock node that the root's `$INPUT` input names.
recorder_node="$(jq -r --arg i "$INPUT" '.nodes.root.inputs[$i] // empty' "$lock")"
if [ -z "$recorder_node" ]; then
	echo "FAIL: the root of flake.lock has no '$INPUT' input" >&2
	exit 1
fi

for name in "${NAMES[@]}"; do
	# What the recorder node takes `$name` from: a string names its own node,
	# an array is a follows path from the root.
	target="$(jq -c --arg n "$recorder_node" --arg i "$name" '.nodes[$n].inputs[$i] // "absent"' "$lock")"
	root_node="$(jq -r --arg i "$name" '.nodes.root.inputs[$i] // empty' "$lock")"
	root_rev="$(jq -r --arg i "$name" '.nodes[.nodes.root.inputs[$i]].locked.rev // "none"' "$lock")"

	case "$target" in
	'"absent"')
		echo "FAIL: $INPUT does not declare '$name' at all in flake.lock" >&2
		failures=$((failures + 1))
		;;
	'["'"$name"'"]')
		echo "ok:   $INPUT/$name follows the root '$name' ($root_rev)"
		;;
	*)
		own_rev="$(jq -r --arg n "$recorder_node" --arg i "$name" '.nodes[$n].inputs[$i] as $t | .nodes[$t].locked.rev // "none"' "$lock")"
		echo "FAIL: $INPUT/$name is its own node, locked at $own_rev," >&2
		echo "      while the root '$name' (${root_node}) is locked at $root_rev" >&2
		echo "      Add to the $INPUT input in flake.nix: inputs.$name.follows = \"$name\";" >&2
		failures=$((failures + 1))
		;;
	esac
done

# The declaration in flake.nix: the block from `$INPUT = {` to its closing
# `};`, which holds no nested braces in this repository.
block="$(awk -v key="$INPUT" '
	$0 ~ "^    " key " = \\{" { inside = 1 }
	inside { print }
	inside && /^    };/ { exit }
' "$flake")"
if [ -z "$block" ]; then
	echo "FAIL: flake.nix has no '$INPUT = {' input block" >&2
	exit 1
fi
for name in "${NAMES[@]}"; do
	if grep -qF "inputs.$name.follows = \"$name\";" <<<"$block"; then
		echo "ok:   flake.nix declares $INPUT inputs.$name.follows"
	else
		echo "FAIL: flake.nix's $INPUT input does not declare inputs.$name.follows = \"$name\"" >&2
		failures=$((failures + 1))
	fi
done

if [ "$failures" -ne 0 ]; then
	echo "FAIL: $failures check(s) failed; the recorder can link a writer from a different pair" >&2
	exit 1
fi
echo "the $INPUT input follows the codetracer trace-format pair"
