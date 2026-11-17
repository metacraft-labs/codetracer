#!/usr/bin/env bash
# Shared by ci/deploy/build-nix-and-push-to-attic.sh (the cache-push workflow)
# and ci/deploy/push-built-closure.sh (the jobs that push what they just
# built). Source it; it defines functions only.

# attic push, retried: the server answers a large upload with a transient
# InternalServerError now and then (cache-push 43982407247, on
# codetracer-electron), and one such answer failed the whole job.
# ATTIC_RETRY_SLEEP scales the back-off (seconds per attempt, default 30).
attic_push() {
	local attempt
	for attempt in 1 2 3; do
		if ${ATTIC_CMD:-attic} push "$ATTIC_CACHE" "$@"; then
			return 0
		fi
		echo "== attic push failed (attempt ${attempt} of 3)" >&2
		[ "$attempt" = 3 ] || sleep $((attempt * ${ATTIC_RETRY_SLEEP:-30}))
	done
	return 1
}

# The realised paths #codetracer was BUILT from, not only what it runs with: a
# build-time-only input (Noir among them) is outside the runtime closure, so a
# cold runner built it from source -- Noir alone for 1h36m (run 43935388749's
# nixos leg). One path per line; attic skips what cache.nixos.org serves.
codetracer_build_closure() {
	local ct_drv
	ct_drv="$(nix path-info --derivation '.?submodules=1#codetracer')" || return 1
	nix-store -qR --include-outputs "${ct_drv}" | grep -v '\.drv$' |
		while read -r p; do [ -e "${p}" ] && printf '%s\n' "${p}"; done
}

# The flake's locked inputs present in the store, one per line. A cold runner
# fetched them one by one from GitHub, codeberg and releases.nixos.org: 11 of
# the 29 minutes its provisioning took (run 43935388749, GPUI shard 2).
# flake-input-paths.py names them from flake.lock's NAR hashes (`nix flake
# archive` refuses the whole flake on one unlocked node).
flake_input_store_paths() {
	python3 ci/deploy/flake-input-paths.py --existing flake.lock
}
