"""Console entry points for invoking the packaged binaries."""

from __future__ import annotations

import sys

from .runtime import DB_BACKEND_RECORD_BINARY_NAME, run_binary


def main(argv: list[str] | None = None) -> int:
    """Execute the packaged binary passing through any CLI arguments."""

    args = argv if argv is not None else sys.argv[1:]
    result = run_binary(args, check=False)
    return int(result.returncode)


def db_backend_record_main(argv: list[str] | None = None) -> int:
    """Execute the packaged ``db-backend-record`` helper with CLI arguments."""

    args = argv if argv is not None else sys.argv[1:]
    result = run_binary(args, check=False, binary_name=DB_BACKEND_RECORD_BINARY_NAME)
    return int(result.returncode)


if __name__ == "__main__":  # pragma: no cover - CLI passthrough only
    sys.exit(main())
