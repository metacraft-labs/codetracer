"""Trace navigation and inspection API.

The :class:`Trace` class is the primary entry point for interacting with a
recorded program execution.  Use :func:`open_trace` as a convenient
constructor.

.. note::

   All query methods in this module are stubs that raise
   ``NotImplementedError``.  They will be implemented in milestone M3 when
   the daemon protocol is finalized.
"""

from __future__ import annotations

from pathlib import Path
from typing import Optional, Union

from codetracer.connection import DaemonConnection
from codetracer.types import Call, Event, Flow, Frame, FlowStep, Location, Loop, Process, Variable


def open_trace(
    path: Union[str, Path],
    *,
    daemon_socket: Optional[Union[str, Path]] = None,
) -> "Trace":
    """Open a recorded trace for inspection.

    Parameters:
        path: Filesystem path to the trace directory or file.
        daemon_socket: Optional explicit path to the daemon's Unix socket.
            When *None*, the default well-known path is used.

    Returns:
        A :class:`Trace` instance connected to the backend daemon.

    Raises:
        TraceNotFoundError: If *path* does not exist or is not a valid trace.
    """
    raise NotImplementedError("Will be implemented in M3")


class Trace:
    """Handle for a single recorded program execution.

    Instances are normally created via :func:`open_trace` rather than by
    calling the constructor directly.

    Parameters:
        path: Filesystem path to the trace.
        connection: An established :class:`DaemonConnection` to the backend.
    """

    def __init__(self, path: Union[str, Path], connection: DaemonConnection) -> None:
        self._path = Path(path)
        self._connection = connection

    # -- Navigation --------------------------------------------------------

    def step_forward(self) -> FlowStep:
        """Advance one execution step forward.

        Returns:
            The :class:`FlowStep` at the new position.

        Raises:
            NavigationError: If the trace is already at the last step.
        """
        raise NotImplementedError("Will be implemented in M3")

    def step_backward(self) -> FlowStep:
        """Move one execution step backward.

        Returns:
            The :class:`FlowStep` at the new position.

        Raises:
            NavigationError: If the trace is already at the first step.
        """
        raise NotImplementedError("Will be implemented in M3")

    def seek(self, step_index: int) -> FlowStep:
        """Jump to an absolute step index in the trace.

        Parameters:
            step_index: Zero-based global step index.

        Returns:
            The :class:`FlowStep` at *step_index*.

        Raises:
            NavigationError: If *step_index* is out of range.
        """
        raise NotImplementedError("Will be implemented in M3")

    # -- Inspection --------------------------------------------------------

    def current_location(self) -> Location:
        """Return the source location at the current execution point."""
        raise NotImplementedError("Will be implemented in M3")

    def current_frame(self) -> Frame:
        """Return the topmost call frame at the current execution point."""
        raise NotImplementedError("Will be implemented in M3")

    def backtrace(self) -> list[Frame]:
        """Return the full call stack at the current execution point."""
        raise NotImplementedError("Will be implemented in M3")

    def evaluate(self, expression: str) -> Variable:
        """Evaluate *expression* in the current scope.

        Parameters:
            expression: A source-language expression string.

        Returns:
            A :class:`Variable` containing the result.

        Raises:
            ExpressionError: If evaluation fails.
        """
        raise NotImplementedError("Will be implemented in M3")

    # -- Flow / structure ---------------------------------------------------

    def flow(self, *, start: Optional[int] = None, end: Optional[int] = None) -> Flow:
        """Return a slice of the execution flow.

        Parameters:
            start: First step index (inclusive). Defaults to the beginning.
            end:   Last step index (exclusive). Defaults to the end.

        Returns:
            A :class:`Flow` covering the requested range.
        """
        raise NotImplementedError("Will be implemented in M3")

    def loops(self) -> list[Loop]:
        """Return all detected loops in the trace."""
        raise NotImplementedError("Will be implemented in M3")

    def calls(self, function_name: Optional[str] = None) -> list[Call]:
        """Return recorded function calls.

        Parameters:
            function_name: If given, filter calls to this function.

        Returns:
            A list of :class:`Call` instances.
        """
        raise NotImplementedError("Will be implemented in M3")

    def events(self, kind: Optional[str] = None) -> list[Event]:
        """Return recorded trace events.

        Parameters:
            kind: If given, filter events to this kind.

        Returns:
            A list of :class:`Event` instances.
        """
        raise NotImplementedError("Will be implemented in M3")

    def process_info(self) -> Process:
        """Return metadata about the recorded process."""
        raise NotImplementedError("Will be implemented in M3")

    # -- Lifecycle ----------------------------------------------------------

    def close(self) -> None:
        """Release resources associated with this trace."""
        raise NotImplementedError("Will be implemented in M3")
