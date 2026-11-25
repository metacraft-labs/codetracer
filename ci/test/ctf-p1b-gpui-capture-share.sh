#!/usr/bin/env bash
# ctf-p1b-gpui-capture-share.sh <shard>/<shards> — which share of CTF-P1b's
# GPUI story captures one GPUI CI shard takes: prints `<i>/<n>` (the
# `CTF_P1B_SHARD` of `just ctf-p1b-gpui-captures-shard`) or `none`.
#
# The whole set (every Agent Harbor story, both themes, each size, and each
# playback story at each named moment) is about 1,400 windows at about 8 s
# each: three hours, which shard 1 could never finish inside its job's bound
# on top of its own window lanes (codetracer-specs issues/2026-11-24-gpui-
# window-captures-shard-1-runs-out-of-its-150-minute-bound-in-the-ctf-p1b-
# step.md). So the set is dealt over every shard but the first two: shard 1
# carries the GPUI window captures and PLAT-35's arm, shard 2 the terminal
# front-end in real emulators. The `ctf-p1b-gpui-layout` job judges the union
# of the shares' frames.
#
# One place says which shard takes which share, so the workflow and
# `ci/test/ctf-p1b-gpui-capture-shards-test.sh` (which holds the shares to
# covering the set once, each within its step's bound) read the same answer.
set -euo pipefail
readonly Reserved=2 # shards 1 and 2 carry other lanes
spec="${1:-}"
if ! [[ ${spec} =~ ^([0-9]+)/([0-9]+)$ ]]; then
	echo "usage: $0 <shard>/<shards>" >&2
	exit 2
fi
shard="${BASH_REMATCH[1]}"
shards="${BASH_REMATCH[2]}"
if [ "${shard}" -lt 1 ] || [ "${shard}" -gt "${shards}" ]; then
	echo "ctf-p1b-gpui-capture-share: shard ${spec} is out of range" >&2
	exit 2
fi
if [ "${shards}" -le "${Reserved}" ]; then
	echo "ctf-p1b-gpui-capture-share: ${shards} shards leave none for the captures" >&2
	exit 2
fi
if [ "${shard}" -le "${Reserved}" ]; then
	echo none
else
	echo "$((shard - Reserved))/$((shards - Reserved))"
fi
