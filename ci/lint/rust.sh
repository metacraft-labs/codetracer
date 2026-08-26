#!/usr/bin/env bash
#
# Rust lint stage.
#
# Every check runs through ci/lib/lint-steps.sh so that one run reports all of
# them; see that file for why. The concrete cost here was the ordinary one: a
# warning in db-backend meant nobody learned whether backend-manager's clippy
# pass or the tui build were also broken until the first one was fixed.
#
# Ordering: the dap_types generator check is seconds and needs only node, so it
# goes first; the cargo passes are minutes each.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

# The pre-commit shellcheck hook runs without -x, so it cannot follow the
# source and reports SC1091; the source= directive above still tells the -x
# runs (ci/lint/bash.sh) where the library lives.
# shellcheck source=ci/lib/lint-steps.sh disable=SC1091
source ci/lib/lint-steps.sh

# ---------------------------------------------------------------------------
# src/db-backend/src/dap_types.rs is generated from schema/. Regenerate it and
# diff against what is committed.
#
# The generator writes over the committed file, so this step keeps a copy and
# puts it back afterwards, whatever the outcome. Without that, a failing run
# leaves a regenerated dap_types.rs in the working tree and every later step —
# and every later job on the same runner — compiles something other than what
# is in git.
# ---------------------------------------------------------------------------
check_dap_types() {
	local generated="src/db-backend/src/dap_types.rs"
	local committed="committed_dap_types.rs"
	local rc=0

	cp "${generated}" "${committed}" || return 1

	node schema/schema.js >/dev/null || rc=$? # rewrites ${generated}

	if [ "${rc}" -eq 0 ] && ! diff "${generated}" "${committed}"; then
		echo "committed dap_types.rs different from auto-generated version!" >&2
		rc=1
	fi

	# Put the committed file back on every path out of here. A plain EXIT trap
	# will not do it: the trap fires when the step's subshell exits, by which
	# time these locals are gone, and `set -u` then kills the restore itself.
	cp -f "${committed}" "${generated}"

	if [ "${rc}" -eq 0 ]; then
		echo "OK for autogeneration of dap_types.rs"
	fi
	return "${rc}"
}

check_db_backend_build() {
	set -e
	cd src/db-backend
	# Treat warnings as errors here.
	env RUSTFLAGS="-D warnings" cargo check --release --bin replay-server
	env RUSTFLAGS="-D warnings" cargo check --release --bin virtualization-layers
	env RUSTFLAGS="-D warnings" cargo check --release --bin schema-generator
	# TODO: check how to fix it in CI : cargo clippy -- -D warnings
}

check_backend_manager_build() {
	set -e
	cd src/backend-manager
	env RUSTFLAGS="-D warnings" cargo check --release
}

check_backend_manager_clippy() {
	set -e
	cd src/backend-manager
	cargo clippy -- -D warnings
}

check_tui_build() {
	set -e
	cd src/tui
	cargo build
}

lint_step "db-backend: dap_types.rs matches the generator" check_dap_types
lint_step "db-backend: cargo check (warnings are errors)" check_db_backend_build
lint_step "backend-manager: cargo check (warnings are errors)" check_backend_manager_build
lint_step "backend-manager: cargo clippy (warnings are errors)" check_backend_manager_clippy
lint_step "tui: cargo build" check_tui_build

lint_summary
