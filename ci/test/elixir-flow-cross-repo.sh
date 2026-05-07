#!/usr/bin/env bash
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
