"""Low-level connection to the CodeTracer backend daemon.

:class:`DaemonConnection` manages a Unix-domain socket connection and the
DAP-like message framing used by the backend-manager daemon.

.. note::

   This module is a skeleton.  The actual socket I/O will be implemented
   in milestone M3.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Optional, Union


def default_daemon_socket_path() -> Path:
    """Return the platform-specific well-known daemon socket path.

    On macOS the path lives under ``~/Library/Caches/com.codetracer.CodeTracer/``.
    On Linux (and other POSIX systems) it is ``/tmp/codetracer/daemon.sock``.

    Returns:
        A :class:`Path` pointing to the expected daemon socket file.
    """
    if sys.platform == "darwin":
        home = os.environ.get("HOME", "/")
        return Path(home) / "Library" / "Caches" / "com.codetracer.CodeTracer" / "daemon.sock"
    # Linux and other POSIX systems use /tmp.
    return Path("/tmp/codetracer/daemon.sock")


class DaemonConnection:
    """A connection to the CodeTracer backend-manager daemon.

    Parameters:
        socket_path: Path to the daemon's Unix socket.  When *None*, the
            default well-known path returned by
            :func:`default_daemon_socket_path` is used.
    """

    def __init__(self, socket_path: Optional[Union[str, Path]] = None) -> None:
        if socket_path is None:
            self._socket_path = default_daemon_socket_path()
        else:
            self._socket_path = Path(socket_path)

    @property
    def socket_path(self) -> Path:
        """The filesystem path of the daemon socket this connection targets."""
        return self._socket_path

    def connect(self) -> None:
        """Establish the socket connection to the daemon.

        Raises:
            TraceError: If the daemon is not reachable.
        """
        raise NotImplementedError("Will be implemented in M3")

    def send(self, message: dict) -> None:
        """Send a DAP-framed JSON message to the daemon.

        Parameters:
            message: A JSON-serialisable dictionary.
        """
        raise NotImplementedError("Will be implemented in M3")

    def receive(self) -> dict:
        """Block until a complete DAP message arrives and return it.

        Returns:
            The decoded JSON message as a dictionary.
        """
        raise NotImplementedError("Will be implemented in M3")

    def close(self) -> None:
        """Close the socket connection."""
        raise NotImplementedError("Will be implemented in M3")
