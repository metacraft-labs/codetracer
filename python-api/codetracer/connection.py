"""Low-level connection to the CodeTracer backend daemon.

:class:`DaemonConnection` manages a Unix-domain socket connection and the
DAP-like message framing (``Content-Length`` header + JSON body) used by the
backend-manager daemon.

The framing follows the DAP wire format:

.. code-block:: text

    Content-Length: <byte-count>\\r\\n
    \\r\\n
    <JSON body>

See: https://microsoft.github.io/debug-adapter-protocol/overview#base-protocol
"""

from __future__ import annotations

import json
import os
import socket
import sys
from pathlib import Path
from typing import Optional, Union

from codetracer.exceptions import TraceError


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

    Uses Unix domain sockets with Content-Length framed JSON messages
    (the DAP wire format).

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
        self._sock: Optional[socket.socket] = None
        self._buffer = b""
        self._seq_counter = 0

    @property
    def socket_path(self) -> Path:
        """The filesystem path of the daemon socket this connection targets."""
        return self._socket_path

    def next_seq(self) -> int:
        """Return the next unique sequence number for outgoing requests."""
        self._seq_counter += 1
        return self._seq_counter

    def connect(self) -> None:
        """Establish the socket connection to the daemon.

        If already connected, this method is a no-op.

        Raises:
            TraceError: If the daemon is not reachable.
        """
        if self._sock is not None:
            return
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self._sock.connect(str(self._socket_path))
        except (ConnectionRefusedError, FileNotFoundError) as e:
            self._sock = None
            raise TraceError(
                f"Cannot connect to daemon at {self._socket_path}: {e}"
            ) from e

    def send(self, message: dict) -> None:
        """Send a Content-Length framed JSON message to the daemon.

        Parameters:
            message: A JSON-serialisable dictionary.

        Raises:
            TraceError: If not connected.
        """
        if self._sock is None:
            raise TraceError("Not connected to daemon")
        body = json.dumps(message).encode("utf-8")
        header = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
        self._sock.sendall(header + body)

    def receive(self) -> dict:
        """Block until a complete Content-Length framed JSON message arrives.

        Returns:
            The decoded JSON message as a dictionary.

        Raises:
            TraceError: If not connected or the connection is closed
                before a complete message is received.
        """
        if self._sock is None:
            raise TraceError("Not connected to daemon")

        # Read until we find the Content-Length header.
        while True:
            # Check if we already have a complete header in the buffer.
            header_end = self._buffer.find(b"\r\n\r\n")
            if header_end >= 0:
                header = self._buffer[:header_end].decode("ascii")
                self._buffer = self._buffer[header_end + 4:]

                # Parse Content-Length from the header lines.
                content_length = None
                for line in header.split("\r\n"):
                    if line.lower().startswith("content-length:"):
                        content_length = int(line.split(":", 1)[1].strip())
                        break

                if content_length is None:
                    raise TraceError("Missing Content-Length header")

                # Read body bytes until we have enough.
                while len(self._buffer) < content_length:
                    chunk = self._sock.recv(8192)
                    if not chunk:
                        raise TraceError(
                            "Connection closed while reading message body"
                        )
                    self._buffer += chunk

                body = self._buffer[:content_length]
                self._buffer = self._buffer[content_length:]
                return json.loads(body.decode("utf-8"))

            # Need more data from the socket.
            chunk = self._sock.recv(8192)
            if not chunk:
                raise TraceError(
                    "Connection closed while reading message header"
                )
            self._buffer += chunk

    def send_request(
        self, command: str, arguments: Optional[dict] = None
    ) -> dict:
        """Send a request and wait for the matching response.

        Builds a DAP-style request message with a unique ``seq`` number,
        sends it, then reads messages until the response with the matching
        ``request_seq`` arrives.  Intermediate events or unrelated responses
        are silently discarded.

        Parameters:
            command:   The DAP command name (e.g., ``"ct/open-trace"``).
            arguments: Optional arguments dictionary.

        Returns:
            The response message dictionary.
        """
        seq = self.next_seq()
        msg: dict = {
            "type": "request",
            "command": command,
            "seq": seq,
        }
        if arguments is not None:
            msg["arguments"] = arguments
        self.send(msg)

        # Read messages until we get the response matching our seq.
        while True:
            response = self.receive()
            if (
                response.get("type") == "response"
                and response.get("request_seq") == seq
            ):
                return response
            # Otherwise it's an event or unrelated response -- skip it.

    def close(self) -> None:
        """Close the socket connection.

        Safe to call multiple times or when not connected.
        """
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None
            self._buffer = b""
