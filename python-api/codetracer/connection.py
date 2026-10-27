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


# ---------------------------------------------------------------------------
# Where the daemon listens
# ---------------------------------------------------------------------------
#
# The daemon (``session-manager``, ``src/backend-manager``) resolves its socket
# in ONE function, ``DaemonConfig::daemon_paths`` (``src/backend-manager/src/
# config.rs``), fed by ``DaemonConfig::load`` and ``Paths::default``
# (``src/backend-manager/src/paths.rs``) and ``ct_home::tmp_dir``
# (``libs/ct-home/src/lib.rs``).  This module cannot call it, so
# :func:`default_daemon_socket_path` mirrors it step for step.  A change to
# the Rust precedence must be made here too; backend-manager's
# ``python_daemon_socket_agreement_test`` starts the real daemon under each
# override and fails when the two disagree.

#: The socket the daemon itself handed to this process.  The daemon sets it
#: for the Python process that runs an ``exec_script`` / ``ct trace query``
#: script (``script_executor.rs``); the MCP server reads it the same way.
_ENV_HANDED_SOCKET = "CODETRACER_DAEMON_SOCK"
#: ``config.rs`` ``ENV_SOCKET``: overrides the socket for daemon and clients.
_ENV_SOCKET = "CODETRACER_DAEMON_SOCKET"
#: ``config.rs`` ``ENV_CONFIG``: an alternative daemon config file.
_ENV_CONFIG = "CODETRACER_DAEMON_CONFIG"
#: ``paths.rs``: the Electron main process's per-run tmp directory.
_ENV_TMP_PATH = "CODETRACER_TMP_PATH"
#: ``ct_home::CODETRACER_HOME_ENV``: relocates every per-user location.
_ENV_HOME = "CODETRACER_HOME"

#: The characters Rust's ``str::trim`` removes (``char::is_whitespace``, the
#: Unicode ``White_Space`` property).  ``str.strip()`` with no argument uses
#: ``str.isspace``, which also strips U+001C..U+001F, so the config parser
#: names the set explicitly.
#: https://doc.rust-lang.org/std/primitive.char.html#method.is_whitespace
_RUST_WHITESPACE = (
    "\t\n\x0b\x0c\r \x85\xa0\u1680\u2000\u2001\u2002\u2003\u2004\u2005"
    "\u2006\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000"
)


def _env_var(name: str) -> Optional[str]:
    """``std::env::var(name).ok()``: the value when set and valid Unicode.

    An empty value counts as set, as it does in Rust.  On POSIX, Python
    decodes undecodable environment bytes to lone surrogates
    (``surrogateescape``); Rust's ``env::var`` refuses such a value, which
    the call sites mirrored here treat as unset.
    """
    value = os.environ.get(name)
    if value is None or any("\udc80" <= c <= "\udcff" for c in value):
        return None
    return value


def _codetracer_home() -> Optional[Path]:
    """``ct_home::codetracer_home``: ``$CODETRACER_HOME`` made absolute.

    Unset or empty is ``None``; a relative value is resolved against the
    current directory.
    """
    raw = os.environ.get(_ENV_HOME)
    if not raw:
        return None
    path = Path(raw)
    return path if path.is_absolute() else Path.cwd() / path


def _rust_temp_dir() -> Path:
    """``std::env::temp_dir()``.

    On Unix it is ``$TMPDIR`` when set (even empty), else ``/tmp``.  On
    Windows it is ``GetTempPath2W``: ``%TMP%``, ``%TEMP%``, ``%USERPROFILE%``,
    then the Windows directory.
    https://doc.rust-lang.org/std/env/fn.temp_dir.html
    """
    if sys.platform == "win32":
        for name in ("TMP", "TEMP", "USERPROFILE"):
            value = os.environ.get(name)
            if value:
                return Path(value)
        return Path(os.environ.get("SystemRoot", r"C:\Windows"))
    tmpdir = os.environ.get("TMPDIR")
    return Path(tmpdir) if tmpdir is not None else Path("/tmp")


def _codetracer_tmp_dir() -> Path:
    """``Paths::default().tmp_path``: where the socket goes without an override.

    ``$CODETRACER_TMP_PATH``, else ``ct_home::tmp_dir()``:
    ``$CODETRACER_HOME/tmp``, else (macOS)
    ``$HOME/Library/Caches/com.codetracer.CodeTracer``, else
    ``<temp dir>/codetracer``.
    """
    tmp_path = _env_var(_ENV_TMP_PATH)
    if tmp_path is not None:
        return Path(tmp_path)
    home = _codetracer_home()
    if home is not None:
        return home / "tmp"
    if sys.platform == "darwin":
        user_home = _env_var("HOME")
        return Path(user_home if user_home is not None else "/") / (
            "Library/Caches/com.codetracer.CodeTracer"
        )
    return _rust_temp_dir() / "codetracer"


def _daemon_config_path() -> Optional[Path]:
    """The daemon config file ``DaemonConfig::load`` reads, if any.

    ``$CODETRACER_DAEMON_CONFIG``, else ``default_config_path()``:
    ``$CODETRACER_HOME/config/daemon.conf``, else
    ``$HOME/.codetracer/daemon.conf``.
    """
    explicit = _env_var(_ENV_CONFIG)
    if explicit is not None:
        return Path(explicit)
    home = _codetracer_home()
    if home is not None:
        return home / "config" / "daemon.conf"
    user_home = _env_var("HOME")
    if user_home is not None:
        return Path(user_home) / ".codetracer" / "daemon.conf"
    return None


def _configured_socket_path() -> Optional[str]:
    """``socket_path`` from the daemon config file, as ``config.rs`` parses it.

    ``KEY = VALUE`` lines, ``#`` comments, keys and values trimmed, a later
    key overriding an earlier one (``parse_config_file``).  A file that is
    missing, unreadable or not UTF-8 is ignored, as the daemon ignores it.
    """
    path = _daemon_config_path()
    if path is None:
        return None
    try:
        # `Path::exists` is false for a path it cannot stat; so is this.
        if not path.exists():
            return None
        contents = path.read_bytes().decode("utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    socket_path: Optional[str] = None
    # `str::lines` splits on "\n" only (a trailing "\r" is trimmed below);
    # `str.splitlines` would also split on "\x0b", "\x1c", "\u2028", ...
    for line in contents.split("\n"):
        trimmed = line.strip(_RUST_WHITESPACE)
        if not trimmed or trimmed.startswith("#") or "=" not in trimmed:
            continue
        key, value = trimmed.split("=", 1)
        if key.strip(_RUST_WHITESPACE) == "socket_path":
            socket_path = value.strip(_RUST_WHITESPACE)
    return socket_path


def default_daemon_socket_path() -> Path:
    """Return the socket of the daemon this process should talk to.

    In order:

    1. ``$CODETRACER_DAEMON_SOCK``: the socket the daemon handed to this
       process (it sets it for the scripts it runs).  Nothing is guessed.
    2. Otherwise the daemon's own resolution (``DaemonConfig::daemon_paths``
       in ``src/backend-manager/src/config.rs``), mirrored exactly:
       ``$CODETRACER_DAEMON_SOCKET``; else ``socket_path`` in the daemon
       config file (``$CODETRACER_DAEMON_CONFIG``, else
       ``$CODETRACER_HOME/config/daemon.conf``, else
       ``~/.codetracer/daemon.conf``); else ``daemon.sock`` (``daemon.port``
       on Windows) in ``$CODETRACER_TMP_PATH``, else in
       ``$CODETRACER_HOME/tmp``, else in the per-OS default
       (``~/Library/Caches/com.codetracer.CodeTracer`` on macOS,
       ``$TMPDIR/codetracer`` -- ``/tmp/codetracer`` without ``TMPDIR`` --
       elsewhere).

    Returns:
        A :class:`Path` pointing to the expected daemon socket file.
    """
    handed = _env_var(_ENV_HANDED_SOCKET)
    if handed is not None:
        return Path(handed)
    override = _env_var(_ENV_SOCKET)
    if override is None:
        override = _configured_socket_path()
    if override is not None:
        return Path(override)
    name = "daemon.port" if sys.platform == "win32" else "daemon.sock"
    return _codetracer_tmp_dir() / name


class DaemonConnection:
    """A connection to the CodeTracer backend-manager daemon.

    Uses Unix domain sockets with Content-Length framed JSON messages
    (the DAP wire format).

    Parameters:
        socket_path: Path to the daemon's Unix socket.  When *None*, the
            path returned by :func:`default_daemon_socket_path`
            (the one the daemon itself resolves) is used.
        host_source_reads: Whether the trace sessions this connection opens
            may read a recording's listed sources from the replay host.  The
            daemon keeps one session per trace AND setting, so every request
            that names a trace (``tracePath``) carries the setting as
            ``hostSourceReads``.  Off by default: the backend then reads
            source text only from the recording's own copies.
    """

    def __init__(
        self,
        socket_path: Optional[Union[str, Path]] = None,
        host_source_reads: bool = False,
    ) -> None:
        if socket_path is None:
            self._socket_path = default_daemon_socket_path()
        else:
            self._socket_path = Path(socket_path)
        self._host_source_reads = bool(host_source_reads)
        self._sock: Optional[socket.socket] = None
        self._buffer = b""
        self._seq_counter = 0

    @property
    def host_source_reads(self) -> bool:
        """Whether this connection's trace sessions may read host sources."""
        return self._host_source_reads

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
            if "tracePath" in arguments:
                # The session a trace request names is the trace and this
                # connection's host-read setting.  Only requests the daemon
                # answers itself carry ``tracePath``; requests it forwards to
                # a backend do not get the field, as some backend argument
                # schemas refuse unknown fields.
                arguments = {
                    **arguments,
                    "hostSourceReads": self._host_source_reads,
                }
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
