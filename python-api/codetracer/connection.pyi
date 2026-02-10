"""Type stubs for codetracer.connection -- low-level daemon connection."""

from pathlib import Path
from typing import Optional, Union

def default_daemon_socket_path() -> Path:
    """Return the platform-specific well-known daemon socket path."""
    ...

class DaemonConnection:
    """A connection to the CodeTracer backend-manager daemon."""

    def __init__(
        self, socket_path: Optional[Union[str, Path]] = ...
    ) -> None: ...

    @property
    def socket_path(self) -> Path: ...

    def next_seq(self) -> int:
        """Return the next unique sequence number for outgoing requests."""
        ...

    def connect(self) -> None:
        """Establish the socket connection to the daemon."""
        ...

    def send(self, message: dict) -> None:  # type: ignore[type-arg]
        """Send a Content-Length framed JSON message to the daemon."""
        ...

    def receive(self) -> dict:  # type: ignore[type-arg]
        """Block until a complete Content-Length framed JSON message arrives."""
        ...

    def send_request(
        self, command: str, arguments: Optional[dict] = ...  # type: ignore[type-arg]
    ) -> dict:  # type: ignore[type-arg]
        """Send a request and wait for the matching response."""
        ...

    def close(self) -> None:
        """Close the socket connection."""
        ...
