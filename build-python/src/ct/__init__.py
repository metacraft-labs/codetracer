"""Public interface for accessing the packaged command-line executables.

The package distributes platform-specific binaries and exposes helpers that
resolve the correct artifact at runtime. It currently ships the ``ct``,
``db-backend-record``, and ``ct-remote`` tools.
"""

from __future__ import annotations

from .runtime import (
    BINARY_NAME,
    BinaryNotFoundError,
    DB_BACKEND_RECORD_BINARY_NAME,
    CT_REMOTE_BINARY_NAME,
    get_executable_path,
    run_binary,
)

__all__ = [
    "BINARY_NAME",
    "BinaryNotFoundError",
    "DB_BACKEND_RECORD_BINARY_NAME",
    "CT_REMOTE_BINARY_NAME",
    "get_executable_path",
    "run_binary",
]

__version__ = "25.9.2"
