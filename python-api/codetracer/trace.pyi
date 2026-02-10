"""Type stubs for codetracer.trace -- Trace navigation and inspection API."""

from pathlib import Path
from typing import Optional, Union

from codetracer.connection import DaemonConnection
from codetracer.types import (
    Call,
    Event,
    Flow,
    Frame,
    Location,
    Loop,
    Process,
    Variable,
)

def open_trace(
    path: Union[str, Path],
    *,
    daemon_socket: Optional[Union[str, Path]] = ...,
) -> Trace:
    """Open a recorded trace for inspection."""
    ...

class Trace:
    """Handle for a single recorded program execution."""

    def __init__(
        self,
        path: Union[str, Path],
        connection: DaemonConnection,
        language: str = ...,
        source_files: Optional[list[str]] = ...,
        total_events: int = ...,
        initial_location: Optional[dict] = ...,  # type: ignore[type-arg]
        backend_id: int = ...,
    ) -> None: ...

    # --- Properties ---

    @property
    def location(self) -> Location: ...

    @property
    def ticks(self) -> int: ...

    @property
    def source_files(self) -> list[str]: ...

    @property
    def total_events(self) -> int: ...

    @property
    def language(self) -> str: ...

    # --- Navigation ---

    def step_over(self) -> Location:
        """Step to the next line (over function calls)."""
        ...

    def step_in(self) -> Location:
        """Step into the next function call."""
        ...

    def step_out(self) -> Location:
        """Step out of the current function."""
        ...

    def step_back(self) -> Location:
        """Step backwards one line."""
        ...

    def reverse_step_in(self) -> Location:
        """Reverse step into."""
        ...

    def reverse_step_out(self) -> Location:
        """Reverse step out."""
        ...

    def continue_forward(self) -> Location:
        """Continue forward until breakpoint or end of trace."""
        ...

    def continue_reverse(self) -> Location:
        """Continue reverse until breakpoint or start of trace."""
        ...

    def goto_ticks(self, ticks: int) -> Location:
        """Jump to a specific execution point by ticks."""
        ...

    # --- Inspection ---

    def current_location(self) -> Location:
        """Return the source location at the current execution point."""
        ...

    def locals(self, depth: int = ..., count_budget: int = ...) -> list[Variable]:
        """Return the local variables at the current execution point."""
        ...

    def evaluate(self, expression: str) -> str:
        """Evaluate an expression in the current scope."""
        ...

    def stack_trace(self) -> list[Frame]:
        """Return the full call stack at the current execution point."""
        ...

    def current_frame(self) -> Frame:
        """Return the topmost call frame at the current execution point."""
        ...

    def backtrace(self) -> list[Frame]:
        """Return the full call stack (alias for stack_trace)."""
        ...

    # --- Breakpoints and Watchpoints ---

    def add_breakpoint(self, path: str, line: int) -> int:
        """Set a breakpoint at the given source location."""
        ...

    def remove_breakpoint(self, bp_id: int) -> None:
        """Remove a previously set breakpoint by its ID."""
        ...

    def add_watchpoint(self, expression: str) -> int:
        """Set a watchpoint that triggers when the expression changes."""
        ...

    def remove_watchpoint(self, wp_id: int) -> None:
        """Remove a previously set watchpoint by its ID."""
        ...

    # --- Flow / structure ---

    def flow(self, path: str, line: int, mode: str = ...) -> Flow:
        """Return flow/omniscience data for a code location."""
        ...

    def loops(self) -> list[Loop]:
        """Return all detected loops in the trace."""
        ...

    # --- Call trace ---

    def calltrace(
        self, start: int = ..., count: int = ..., depth: int = ...
    ) -> list[Call]:
        """Return a section of the call trace."""
        ...

    def search_calltrace(self, query: str, limit: int = ...) -> list[Call]:
        """Search the call trace for functions matching *query*."""
        ...

    def calls(self, function_name: Optional[str] = ...) -> list[Call]:
        """Return recorded function calls."""
        ...

    # --- Events ---

    def events(
        self,
        start: int = ...,
        count: int = ...,
        type_filter: Optional[str] = ...,
        search: Optional[str] = ...,
    ) -> list[Event]:
        """Return recorded trace events."""
        ...

    def terminal_output(
        self, start_line: int = ..., end_line: int = ...
    ) -> str:
        """Return the recorded terminal (stdout) output."""
        ...

    # --- Multi-process ---

    def processes(self) -> list[Process]:
        """List processes in the trace."""
        ...

    def select_process(self, process_id: int) -> None:
        """Switch to a different process in a multi-process trace."""
        ...

    # --- Source ---

    def read_source(self, path: str) -> str:
        """Read the content of a source file from the trace."""
        ...

    def process_info(self) -> Process:
        """Return metadata about the recorded process."""
        ...

    # --- Lifecycle ---

    def close(self) -> None:
        """Release resources associated with this trace."""
        ...

    def __enter__(self) -> Trace: ...
    def __exit__(self, *args: object) -> None: ...
