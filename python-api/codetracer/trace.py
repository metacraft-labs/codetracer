"""Trace navigation and inspection API.

The :class:`Trace` class is the primary entry point for interacting with a
recorded program execution.  Use :func:`open_trace` as a convenient
constructor.

Navigation methods (``step_over``, ``step_in``, etc.) translate into
``ct/py-navigate`` requests sent to the daemon, which in turn sends
DAP commands to the backend replay process.  The daemon handles the
multi-step DAP interaction (command -> stopped event -> stackTrace)
and returns a simplified location response.
"""

from __future__ import annotations

from pathlib import Path
from typing import Optional, Union

from codetracer.connection import DaemonConnection
from codetracer.types import (
    Call,
    Event,
    Flow,
    FlowStep,
    Frame,
    Location,
    Loop,
    Process,
    ValueTrace,
    Variable,
)
from codetracer.exceptions import (
    ExpressionError,
    NavigationError,
    TraceError,
    TraceNotFoundError,
)


def open_trace(
    path: Union[str, Path],
    *,
    daemon_socket: Optional[Union[str, Path]] = None,
) -> "Trace":
    """Open a recorded trace for inspection.

    Connects to the daemon, sends ``ct/open-trace``, and returns a
    :class:`Trace` handle with the initial execution position already
    populated.

    Parameters:
        path: Filesystem path to the trace directory or file.
        daemon_socket: Optional explicit path to the daemon's Unix socket.
            When *None*, the default well-known path is used.

    Returns:
        A :class:`Trace` instance connected to the backend daemon.

    Raises:
        TraceNotFoundError: If *path* does not exist or is not a valid trace.
        TraceError: If the daemon is not reachable or returns an error.
    """
    conn = DaemonConnection(socket_path=daemon_socket)
    conn.connect()

    # Resolve the path if it exists on disk; otherwise pass it as-is
    # (the daemon may resolve it internally).
    trace_path = str(Path(path).resolve()) if Path(path).exists() else str(path)

    response = conn.send_request("ct/open-trace", {"tracePath": trace_path})
    if not response.get("success"):
        conn.close()
        message = response.get("message", "unknown error")
        if "not found" in message.lower() or "cannot read" in message.lower():
            raise TraceNotFoundError(message)
        raise TraceError(message)

    body = response.get("body", {})
    return Trace(
        path=trace_path,
        connection=conn,
        language=body.get("language", ""),
        source_files=body.get("sourceFiles", []),
        total_events=body.get("totalEvents", 0),
        initial_location=body.get("initialLocation"),
        backend_id=body.get("backendId", 0),
    )


class Trace:
    """Handle for a single recorded program execution.

    Instances are normally created via :func:`open_trace` rather than by
    calling the constructor directly.

    The trace maintains a *current position* (file, line, column, ticks)
    that is updated by navigation methods.  The position is available
    through the :attr:`location` and :attr:`ticks` properties.

    Parameters:
        path: Filesystem path to the trace.
        connection: An established :class:`DaemonConnection` to the backend.
        language: The detected source language.
        source_files: List of source files in the trace.
        total_events: Total number of execution events.
        initial_location: Initial location from the open-trace response.
        backend_id: The backend process ID assigned by the daemon.
    """

    def __init__(
        self,
        path: Union[str, Path],
        connection: DaemonConnection,
        language: str = "",
        source_files: Optional[list[str]] = None,
        total_events: int = 0,
        initial_location: Optional[dict] = None,
        backend_id: int = 0,
    ) -> None:
        self._path = str(path)
        self._connection = connection
        self._language = language
        self._source_files = source_files or []
        self._total_events = total_events
        self._backend_id = backend_id

        # Set initial location from open-trace response.
        if initial_location:
            self._location = Location(
                path=initial_location.get("path", ""),
                line=initial_location.get("line", 0),
                column=initial_location.get("column", 0),
            )
            self._ticks = initial_location.get("ticks", 0)
        else:
            self._location = Location(path="", line=0, column=0)
            self._ticks = 0

    # --- Properties ---

    @property
    def location(self) -> Location:
        """Current execution location (path, line, column).

        Updated automatically by navigation methods such as
        :meth:`step_over`, :meth:`goto_ticks`, etc.

        Returns:
            A :class:`Location` representing the current source position.
        """
        return self._location

    @property
    def ticks(self) -> int:
        """Current execution timestamp (rr ticks).

        The ticks value is a monotonically increasing counter maintained
        by the rr replay engine.  It uniquely identifies an execution
        point and can be passed to :meth:`goto_ticks` to return to this
        position later.

        Returns:
            An integer tick value.
        """
        return self._ticks

    @property
    def source_files(self) -> list[str]:
        """Source files present in the trace.

        Returns the list of source file paths that were captured when
        the trace was recorded.  These paths can be passed to
        :meth:`read_source` to retrieve file contents.

        Returns:
            A list of file path strings.
        """
        return self._source_files

    @property
    def total_events(self) -> int:
        """Total number of events in the trace.

        Events include I/O operations (stdout/stderr), signals, and
        other observable side effects.

        Returns:
            A non-negative integer event count.
        """
        return self._total_events

    @property
    def language(self) -> str:
        """Detected source language of the traced program.

        Examples: ``"nim"``, ``"rust"``, ``"c"``, ``"go"``.

        Returns:
            A lowercase language identifier string.
        """
        return self._language

    # --- Navigation ---

    def _navigate(self, method: str, **kwargs: object) -> Location:
        """Send a navigation request to the daemon.

        Builds a ``ct/py-navigate`` request with the given method name
        and optional extra arguments (e.g., ``ticks=12345``), sends it
        to the daemon, and updates the trace's current position from
        the response.

        Parameters:
            method: The navigation method name (e.g., ``"step_over"``).
            **kwargs: Extra arguments to include in the request.

        Returns:
            The new :class:`Location` after navigation.

        Raises:
            StopIteration: If the navigation reached the end (or start)
                of the trace.
            NavigationError: If the daemon reports an error.
        """
        args: dict = {
            "tracePath": self._path,
            "method": method,
        }
        args.update(kwargs)

        response = self._connection.send_request("ct/py-navigate", args)

        if not response.get("success"):
            message = response.get("message", f"{method} failed")
            raise NavigationError(message)

        body = response.get("body", {})

        # Update location to the new position.
        self._location = Location(
            path=body.get("path", ""),
            line=body.get("line", 0),
            column=body.get("column", 0),
        )
        self._ticks = body.get("ticks", 0)

        # Check for end-of-trace boundary.
        if body.get("endOfTrace", False):
            raise StopIteration("Reached end of trace")

        return self._location

    def step_over(self) -> Location:
        """Step to the next line (over function calls).

        Returns:
            The new :class:`Location`.

        Raises:
            StopIteration: At end of trace.
        """
        return self._navigate("step_over")

    def step_in(self) -> Location:
        """Step into the next function call.

        Returns:
            The new :class:`Location`.

        Raises:
            StopIteration: At end of trace.
        """
        return self._navigate("step_in")

    def step_out(self) -> Location:
        """Step out of the current function.

        Returns:
            The new :class:`Location`.

        Raises:
            StopIteration: At end of trace.
        """
        return self._navigate("step_out")

    def step_back(self) -> Location:
        """Step backwards one line.

        Returns:
            The new :class:`Location`.

        Raises:
            StopIteration: At start of trace.
        """
        return self._navigate("step_back")

    def reverse_step_in(self) -> Location:
        """Reverse step into.

        Returns:
            The new :class:`Location`.

        Raises:
            StopIteration: At start of trace.
        """
        return self._navigate("reverse_step_in")

    def reverse_step_out(self) -> Location:
        """Reverse step out.

        Returns:
            The new :class:`Location`.

        Raises:
            StopIteration: At start of trace.
        """
        return self._navigate("reverse_step_out")

    def continue_forward(self) -> Location:
        """Continue forward until breakpoint or end of trace.

        Returns:
            The new :class:`Location`.

        Raises:
            StopIteration: At end of trace.
        """
        return self._navigate("continue_forward")

    def continue_reverse(self) -> Location:
        """Continue reverse until breakpoint or start of trace.

        Returns:
            The new :class:`Location`.

        Raises:
            StopIteration: At start of trace.
        """
        return self._navigate("continue_reverse")

    def goto_ticks(self, ticks: int) -> Location:
        """Jump to a specific execution point by ticks.

        Parameters:
            ticks: The target rr tick value.

        Returns:
            The new :class:`Location`.
        """
        return self._navigate("goto_ticks", ticks=ticks)

    # --- Inspection ---

    def current_location(self) -> Location:
        """Return the source location at the current execution point.

        Equivalent to reading the :attr:`location` property.

        Returns:
            A :class:`Location` representing the current source position.
        """
        return self._location

    def locals(self, depth: int = 3, count_budget: int = 3000) -> list[Variable]:
        """Return the local variables at the current execution point.

        Sends ``ct/py-locals`` to the daemon, which translates it to
        ``ct/load-locals`` on the backend.  Variables are returned with
        their children expanded up to *depth* levels.

        Parameters:
            depth: How many levels of nested children to expand.
                   ``1`` returns top-level variables with empty children;
                   ``3`` (the default) provides three levels of nesting.
            count_budget: Maximum total number of variable nodes to return.

        Returns:
            A list of :class:`Variable` instances.

        Raises:
            TraceError: If the daemon reports an error.
        """
        response = self._connection.send_request("ct/py-locals", {
            "tracePath": self._path,
            "depth": depth,
            "countBudget": count_budget,
        })
        if not response.get("success"):
            raise TraceError(response.get("message", "locals() failed"))
        body = response.get("body", {})
        return [self._parse_variable(v) for v in body.get("variables", [])]

    def evaluate(self, expression: str) -> str:
        """Evaluate *expression* in the current scope.

        Sends ``ct/py-evaluate`` to the daemon, which translates it to
        the DAP ``evaluate`` command on the backend.

        Parameters:
            expression: The expression to evaluate (e.g., ``"x + y"``).

        Returns:
            The string representation of the result.

        Raises:
            ExpressionError: If the expression cannot be evaluated.
        """
        response = self._connection.send_request("ct/py-evaluate", {
            "tracePath": self._path,
            "expression": expression,
        })
        if not response.get("success"):
            raise ExpressionError(
                response.get("message", f"evaluate({expression!r}) failed")
            )
        body = response.get("body", {})
        return body.get("result", "")

    def stack_trace(self) -> list[Frame]:
        """Return the full call stack at the current execution point.

        Sends ``ct/py-stack-trace`` to the daemon, which translates it to
        the DAP ``stackTrace`` command on the backend.

        Returns:
            A list of :class:`Frame` instances, ordered from innermost
            (current function) to outermost (entry point).

        Raises:
            TraceError: If the daemon reports an error.
        """
        response = self._connection.send_request("ct/py-stack-trace", {
            "tracePath": self._path,
        })
        if not response.get("success"):
            raise TraceError(response.get("message", "stack_trace() failed"))
        body = response.get("body", {})
        return [self._parse_frame(f) for f in body.get("frames", [])]

    def current_frame(self) -> Frame:
        """Return the topmost call frame at the current execution point.

        This is a convenience method equivalent to ``stack_trace()[0]``.

        Returns:
            A :class:`Frame` for the currently executing function.

        Raises:
            TraceError: If the daemon reports an error.
        """
        frames = self.stack_trace()
        if frames:
            return frames[0]
        return Frame(function_name="", location=self._location)

    def backtrace(self) -> list[Frame]:
        """Return the full call stack at the current execution point.

        Alias for :meth:`stack_trace`.

        Returns:
            A list of :class:`Frame` instances, ordered from innermost
            (current function) to outermost (entry point).

        Raises:
            TraceError: If the daemon reports an error.
        """
        return self.stack_trace()

    # --- Parse helpers ---

    @staticmethod
    def _parse_variable(data: dict) -> Variable:
        """Parse a variable dict from the daemon response into a
        :class:`Variable` instance, recursively parsing children."""
        children = [Trace._parse_variable(c) for c in data.get("children", [])]
        return Variable(
            name=data.get("name", ""),
            value=data.get("value", ""),
            type_name=data.get("type", None),
            children=children,
        )

    @staticmethod
    def _parse_frame(data: dict) -> Frame:
        """Parse a frame dict from the daemon response into a
        :class:`Frame` instance."""
        loc_data = data.get("location", {})
        location = Location(
            path=loc_data.get("path", ""),
            line=loc_data.get("line", 0),
            column=loc_data.get("column", 0),
        )
        return Frame(
            function_name=data.get("name", ""),
            location=location,
        )

    @staticmethod
    def _parse_call(data: dict) -> Call:
        """Parse a call dict from the daemon response into a
        :class:`Call` instance.

        The wire format uses ``name`` for the function name, ``location``
        for the source position, ``returnValue`` for the return value
        string, ``childrenCount`` for the number of child calls, and
        ``depth`` for the call-tree nesting level.
        """
        loc_data = data.get("location", {})
        location = Location(
            path=loc_data.get("path", ""),
            line=loc_data.get("line", 0),
            column=loc_data.get("column", 0),
        )

        return_value = None
        rv = data.get("returnValue")
        if rv is not None:
            return_value = Variable(name="return", value=str(rv))

        return Call(
            function_name=data.get("name", ""),
            location=location,
            return_value=return_value,
            id=data.get("id", 0),
            children_count=data.get("childrenCount", 0),
            depth=data.get("depth", 0),
        )

    @staticmethod
    def _parse_event(data: dict) -> Event:
        """Parse an event dict from the daemon response into an
        :class:`Event` instance.

        The wire format uses ``type`` for the event kind, ``content``
        for the raw event text, ``ticks`` for the execution timestamp,
        and ``location`` for the source position.
        """
        loc_data = data.get("location")
        location = None
        if loc_data:
            location = Location(
                path=loc_data.get("path", ""),
                line=loc_data.get("line", 0),
                column=loc_data.get("column", 0),
            )

        content = data.get("content", "")
        return Event(
            kind=data.get("type", ""),
            message=content,
            location=location,
            id=data.get("id", 0),
            ticks=data.get("ticks", 0),
            content=content,
        )

    # --- Multi-process support ---

    def processes(self) -> list[Process]:
        """List processes in the trace.

        Multi-process traces contain multiple recorded processes.
        Single-process traces return a list with exactly one entry.

        Sends ``ct/py-processes`` to the daemon, which queries the
        backend for the list of recorded processes.

        Returns:
            A list of :class:`Process` instances.

        Raises:
            TraceError: If the daemon reports an error.
        """
        response = self._connection.send_request("ct/py-processes", {
            "tracePath": self._path,
        })
        if not response.get("success"):
            raise TraceError(response.get("message", "processes() failed"))
        body = response.get("body", {})
        procs = body.get("processes", [])
        return [
            Process(
                id=p["id"],
                name=p.get("name", ""),
                command=p.get("command", ""),
            )
            for p in procs
        ]

    def select_process(self, process_id: int) -> None:
        """Switch to a different process in a multi-process trace.

        After calling this method, all subsequent navigation and query
        methods (``step_over``, ``locals``, ``evaluate``, etc.) operate
        on the selected process.

        For single-process traces this is a no-op: the only process is
        already selected.

        Sends ``ct/py-select-process`` to the daemon, which issues a
        ``ct/select-replay`` command to the backend.

        Parameters:
            process_id: The :attr:`Process.id` of the process to select.

        Raises:
            TraceError: If the daemon reports an error.
        """
        response = self._connection.send_request("ct/py-select-process", {
            "tracePath": self._path,
            "processId": process_id,
        })
        if not response.get("success"):
            raise TraceError(
                response.get("message", "select_process() failed")
            )

    # --- Breakpoints and Watchpoints ---

    def add_breakpoint(self, path: str, line: int) -> int:
        """Set a breakpoint at the given source location.

        The daemon translates this into a DAP ``setBreakpoints`` command
        containing all breakpoints for the affected file.

        Parameters:
            path: The source file path where the breakpoint should be set.
            line: The line number for the breakpoint.

        Returns:
            A positive integer breakpoint ID that can be passed to
            :meth:`remove_breakpoint` to remove this breakpoint later.

        Raises:
            TraceError: If the daemon reports an error.
        """
        response = self._connection.send_request("ct/py-add-breakpoint", {
            "tracePath": self._path,
            "path": path,
            "line": line,
        })
        if not response.get("success"):
            raise TraceError(response.get("message", "add_breakpoint() failed"))
        return response.get("body", {}).get("breakpointId", 0)

    def remove_breakpoint(self, bp_id: int) -> None:
        """Remove a previously set breakpoint by its ID.

        Parameters:
            bp_id: The breakpoint ID returned by :meth:`add_breakpoint`.

        Raises:
            TraceError: If the daemon reports an error (e.g., unknown ID).
        """
        response = self._connection.send_request("ct/py-remove-breakpoint", {
            "tracePath": self._path,
            "breakpointId": bp_id,
        })
        if not response.get("success"):
            raise TraceError(
                response.get("message", "remove_breakpoint() failed")
            )

    def add_watchpoint(self, expression: str) -> int:
        """Set a watchpoint that triggers when the expression's value changes.

        The daemon translates this into a DAP ``setDataBreakpoints``
        command.  When execution continues, it will stop at the point
        where the watched expression's value changes.

        Parameters:
            expression: The expression to watch (e.g., ``"counter"``).

        Returns:
            A positive integer watchpoint ID that can be passed to
            :meth:`remove_watchpoint`.

        Raises:
            TraceError: If the daemon reports an error.
        """
        response = self._connection.send_request("ct/py-add-watchpoint", {
            "tracePath": self._path,
            "expression": expression,
        })
        if not response.get("success"):
            raise TraceError(
                response.get("message", "add_watchpoint() failed")
            )
        return response.get("body", {}).get("watchpointId", 0)

    def remove_watchpoint(self, wp_id: int) -> None:
        """Remove a previously set watchpoint by its ID.

        Parameters:
            wp_id: The watchpoint ID returned by :meth:`add_watchpoint`.

        Raises:
            TraceError: If the daemon reports an error (e.g., unknown ID).
        """
        response = self._connection.send_request("ct/py-remove-watchpoint", {
            "tracePath": self._path,
            "watchpointId": wp_id,
        })
        if not response.get("success"):
            raise TraceError(
                response.get("message", "remove_watchpoint() failed")
            )

    # --- Tracepoints (printf debugging without recompilation) ---

    def add_tracepoint(self, path: str, line: int, expression: str) -> int:
        """Add a tracepoint that evaluates an expression each time
        execution passes through the given line.

        Tracepoints provide printf-style debugging without recompilation:
        evaluate custom expressions at any line across the entire recorded
        execution.  The expression language supports ``log(expr, ...)``,
        variables, field access, arithmetic, and conditionals.

        No evaluation happens until :meth:`run_tracepoints` is called.

        Parameters:
            path: Source file path (as stored in the trace).
            line: Line number to set the tracepoint at.
            expression: Expression to evaluate at each hit
                (e.g., ``"log(x, y)"``).

        Returns:
            A positive integer tracepoint ID that can be passed to
            :meth:`remove_tracepoint`.

        Raises:
            TraceError: If the daemon reports an error.
        """
        response = self._connection.send_request("ct/py-add-tracepoint", {
            "tracePath": self._path,
            "path": path,
            "line": line,
            "expression": expression,
        })
        if not response.get("success"):
            raise TraceError(
                response.get("message", "add_tracepoint() failed")
            )
        return response.get("body", {}).get("tracepointId", 0)

    def remove_tracepoint(self, tp_id: int) -> None:
        """Remove a previously set tracepoint by its ID.

        Parameters:
            tp_id: The tracepoint ID returned by :meth:`add_tracepoint`.

        Raises:
            TraceError: If the daemon reports an error (e.g., unknown ID).
        """
        response = self._connection.send_request("ct/py-remove-tracepoint", {
            "tracePath": self._path,
            "tracepointId": tp_id,
        })
        if not response.get("success"):
            raise TraceError(
                response.get("message", "remove_tracepoint() failed")
            )

    def run_tracepoints(self, stop_after: int = -1) -> list:
        """Execute all active tracepoints across the trace.

        Replays the entire recorded execution (or up to *stop_after*
        hits), evaluating every active tracepoint at each matching line.
        Returns a list of result dicts, one per hit.

        Parameters:
            stop_after: Maximum number of hits to collect.  ``-1`` means
                no limit (process the entire trace).

        Returns:
            A list of dicts, each with keys:

            - ``tracepointId`` (int): Which tracepoint produced this hit.
            - ``path`` (str): Source file path.
            - ``line`` (int): Line number.
            - ``ticks`` (int): Execution timestamp.
            - ``iteration`` (int): Visit index (0 for first hit, etc.).
            - ``values`` (list[dict]): Evaluated expression results,
              each ``{"name": str, "value": str}``.

        Raises:
            TraceError: If the daemon reports an error.
        """
        response = self._connection.send_request("ct/py-run-tracepoints", {
            "tracePath": self._path,
            "stopAfter": stop_after,
        })
        if not response.get("success"):
            raise TraceError(
                response.get("message", "run_tracepoints() failed")
            )
        body = response.get("body", {})
        return body.get("results", [])

    # --- Value Trace (formerly "flow") / structure ---

    def value_trace(self, path: str, line: int, mode: str = "call") -> ValueTrace:
        """Return value-trace (omniscience) data for a code location.

        Shows all variable values across execution of a function or line.
        This is CodeTracer's signature feature.

        Parameters:
            path: Source file path (relative or absolute, as stored in
                  the trace metadata).
            line: Line number to query.
            mode: ``"call"`` to see the full function call containing the
                  line, or ``"line"`` to see only the specific line's
                  executions.

        Returns:
            A :class:`ValueTrace` instance with steps and detected loops.

        Raises:
            TraceError: If the daemon reports an error.
        """
        response = self._connection.send_request("ct/py-flow", {
            "tracePath": self._path,
            "path": path,
            "line": line,
            "mode": mode,
        })
        if not response.get("success"):
            raise TraceError(response.get("message", "value_trace() failed"))

        body = response.get("body", {})

        steps = []
        for s in body.get("steps", []):
            steps.append(FlowStep(
                location=Location(path=path, line=s.get("line", 0)),
                ticks=s.get("ticks", 0),
                loop_id=s.get("loopId", 0),
                iteration=s.get("iteration", 0),
                before_values=s.get("beforeValues", {}),
                after_values=s.get("afterValues", {}),
            ))

        loops = []
        for lp in body.get("loops", []):
            loops.append(Loop(
                id=lp.get("id", 0),
                start_line=lp.get("startLine", 0),
                end_line=lp.get("endLine", 0),
                iteration_count=lp.get("iterationCount", 0),
            ))

        return ValueTrace(steps=steps, loops=loops)

    def flow(self, path: str, line: int, mode: str = "call") -> ValueTrace:
        """Return value-trace data for a code location.

        .. deprecated::
            Use :meth:`value_trace` instead.  This method is retained as
            an alias for backwards compatibility and will be removed in a
            future release.
        """
        import warnings

        warnings.warn(
            "Trace.flow() is deprecated; use Trace.value_trace() instead.",
            DeprecationWarning,
            stacklevel=2,
        )
        return self.value_trace(path, line, mode)

    def loops(self) -> list[Loop]:
        """Return all detected loops in the trace.

        .. note:: Not yet implemented -- will be available in a later milestone.

        Raises:
            NotImplementedError: Always.
        """
        raise NotImplementedError("Will be implemented in a later milestone")

    def calltrace(
        self,
        start: int = 0,
        count: int = 50,
        depth: int = 10,
    ) -> list[Call]:
        """Return a section of the call trace.

        Sends ``ct/py-calltrace`` to the daemon, which translates it to
        ``ct/load-calltrace-section`` on the backend.

        Parameters:
            start: Index of the first call to return (0-based).
            count: Maximum number of calls to return.
            depth: Maximum nesting depth to include.

        Returns:
            A list of :class:`Call` instances.

        Raises:
            TraceError: If the daemon reports an error.
        """
        response = self._connection.send_request("ct/py-calltrace", {
            "tracePath": self._path,
            "start": start,
            "count": count,
            "depth": depth,
        })
        if not response.get("success"):
            raise TraceError(response.get("message", "calltrace() failed"))
        body = response.get("body", {})
        return [self._parse_call(c) for c in body.get("calls", [])]

    def search_calltrace(
        self,
        query: str,
        limit: int = 100,
    ) -> list[Call]:
        """Search the call trace for functions matching *query*.

        Sends ``ct/py-search-calltrace`` to the daemon, which translates
        it to ``ct/search-calltrace`` on the backend.

        Parameters:
            query: Substring to search for in function names.
            limit: Maximum number of results to return.

        Returns:
            A list of matching :class:`Call` instances.

        Raises:
            TraceError: If the daemon reports an error.
        """
        response = self._connection.send_request("ct/py-search-calltrace", {
            "tracePath": self._path,
            "query": query,
            "limit": limit,
        })
        if not response.get("success"):
            raise TraceError(
                response.get("message", "search_calltrace() failed")
            )
        body = response.get("body", {})
        return [self._parse_call(c) for c in body.get("calls", [])]

    def events(
        self,
        start: int = 0,
        count: int = 100,
        type_filter: Optional[str] = None,
        search: Optional[str] = None,
    ) -> list[Event]:
        """Return recorded trace events.

        Sends ``ct/py-events`` to the daemon, which translates it to
        ``ct/event-load`` on the backend.

        Parameters:
            start: Index of the first event to return (0-based).
            count: Maximum number of events to return.
            type_filter: If provided, only return events of this type
                         (e.g. ``"stdout"``, ``"stderr"``).
            search: If provided, filter events by content matching.

        Returns:
            A list of :class:`Event` instances.

        Raises:
            TraceError: If the daemon reports an error.
        """
        args: dict = {
            "tracePath": self._path,
            "start": start,
            "count": count,
        }
        if type_filter is not None:
            args["typeFilter"] = type_filter
        if search is not None:
            args["search"] = search

        response = self._connection.send_request("ct/py-events", args)
        if not response.get("success"):
            raise TraceError(response.get("message", "events() failed"))
        body = response.get("body", {})
        return [self._parse_event(e) for e in body.get("events", [])]

    def terminal_output(
        self,
        start_line: int = 0,
        end_line: int = -1,
    ) -> str:
        """Return the recorded terminal (stdout) output.

        Sends ``ct/py-terminal`` to the daemon, which translates it to
        ``ct/load-terminal`` on the backend.

        Parameters:
            start_line: First line of output to return (0-based).
            end_line: Last line of output to return (-1 = all lines).

        Returns:
            The terminal output as a string.

        Raises:
            TraceError: If the daemon reports an error.
        """
        response = self._connection.send_request("ct/py-terminal", {
            "tracePath": self._path,
            "startLine": start_line,
            "endLine": end_line,
        })
        if not response.get("success"):
            raise TraceError(
                response.get("message", "terminal_output() failed")
            )
        return response.get("body", {}).get("output", "")

    def read_source(self, path: str) -> str:
        """Read the content of a source file from the trace.

        Sends ``ct/py-read-source`` to the daemon, which translates it
        to ``ct/read-source`` on the backend.

        Parameters:
            path: The source file path (as listed in :attr:`source_files`
                  or in a :class:`Location`).

        Returns:
            The file content as a string.

        Raises:
            TraceError: If the daemon reports an error.
        """
        response = self._connection.send_request("ct/py-read-source", {
            "tracePath": self._path,
            "path": path,
        })
        if not response.get("success"):
            raise TraceError(
                response.get("message", "read_source() failed")
            )
        return response.get("body", {}).get("content", "")

    def calls(self, function_name: Optional[str] = None) -> list[Call]:
        """Return recorded function calls.

        Convenience wrapper around :meth:`calltrace` and
        :meth:`search_calltrace`.

        Parameters:
            function_name: If provided, only return calls matching this name.

        Returns:
            A list of :class:`Call` instances.
        """
        if function_name is not None:
            return self.search_calltrace(function_name)
        return self.calltrace()

    def process_info(self) -> Process:
        """Return metadata about the recorded process.

        .. note:: Not yet implemented -- will be available in a later milestone.

        Raises:
            NotImplementedError: Always.
        """
        raise NotImplementedError("Will be implemented in a later milestone")

    # --- Lifecycle ---

    def close(self) -> None:
        """Release resources associated with this trace.

        Sends ``ct/close-trace`` to the daemon and closes the socket.
        """
        try:
            self._connection.send_request(
                "ct/close-trace", {"tracePath": self._path}
            )
        except Exception:
            pass
        self._connection.close()

    def __enter__(self) -> "Trace":
        """Enter the context manager; returns *self*.

        Enables the ``with open_trace(...) as t:`` idiom.
        """
        return self

    def __exit__(self, *args: object) -> None:
        """Exit the context manager; closes the trace via :meth:`close`."""
        self.close()
