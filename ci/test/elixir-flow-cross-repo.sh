#!/usr/bin/env bash
# NOT-A-CI-GATE: a deprecated compatibility shim for out-of-tree callers; the
# gate is ci/test/beam-flow-cross-repo.sh, which beam-flow.yml runs directly.
#
# This marker was added on 2026-09-04, when `shell-gate-coverage.sh` stopped
# reading a `paths:` trigger filter as a wire. Two `paths:` entries in
# beam-flow.yml were the ONLY references to this file in the repository, and
# they made it look covered; what they actually do is decide whether the
# workflow starts when this file changes. It has no in-tree caller and is not
# meant to have one — it exists so that a CI hook in another repository that
# still spells the pre-rename name keeps working during the migration window.
#
# WHEN THE MIGRATION WINDOW CLOSES, DELETE THIS FILE rather than this marker.
#
# DEPRECATED: thin shim that delegates to beam-flow-cross-repo.sh.
#
# Kept during the BEAM rename migration window so any out-of-tree CI hooks
# that invoke `elixir-flow-cross-repo.sh` keep working. New callers should
# use `ci/test/beam-flow-cross-repo.sh` directly.
#
# Translates the legacy `verify_elixir_flow_zero_test_guard` subcommand to the
# BEAM-prefixed `verify_beam_flow_zero_test_guard`.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
case "${1:-}" in
verify_elixir_flow_zero_test_guard)
	exec "$SCRIPT_DIR/beam-flow-cross-repo.sh" verify_beam_flow_zero_test_guard
	;;
*)
	exec "$SCRIPT_DIR/beam-flow-cross-repo.sh" "$@"
	;;
esac
