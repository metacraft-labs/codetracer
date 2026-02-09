"""Data types for the CodeTracer Trace Query API.

These dataclasses represent the core entities that a recorded program
execution exposes: source locations, variables, call frames, control-flow
steps, and high-level constructs such as loops and function calls.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Optional


@dataclass(frozen=True)
class Location:
    """A source-code location (file, line, optional column)."""

    file: str
    line: int
    column: Optional[int] = None

    def __str__(self) -> str:
        if self.column is not None:
            return f"{self.file}:{self.line}:{self.column}"
        return f"{self.file}:{self.line}"


@dataclass(frozen=True)
class Variable:
    """A captured variable value at a specific point in execution.

    Attributes:
        name:  The variable's identifier in the source program.
        value: The string representation of the variable's value.
        type_name: The type of the variable (language-specific, may be None).
    """

    name: str
    value: str
    type_name: Optional[str] = None


@dataclass(frozen=True)
class Frame:
    """A single call-frame on the execution stack.

    Attributes:
        function_name: The name of the function/method.
        location:      Where in the source this frame is executing.
        variables:     Variables visible in this frame's scope.
    """

    function_name: str
    location: Location
    variables: list[Variable] = field(default_factory=list)


@dataclass(frozen=True)
class FlowStep:
    """One step in an execution flow (a single executed source line).

    Attributes:
        location:  The source location of this step.
        variables: Variables captured at this step.
        step_index: The global step index in the trace.
    """

    location: Location
    variables: list[Variable] = field(default_factory=list)
    step_index: Optional[int] = None


@dataclass(frozen=True)
class Flow:
    """An execution flow: a contiguous sequence of executed steps.

    Attributes:
        steps: Ordered list of flow steps.
    """

    steps: list[FlowStep] = field(default_factory=list)


@dataclass(frozen=True)
class Loop:
    """A detected loop in the execution trace.

    Attributes:
        location:       Source location of the loop header.
        iteration_count: How many iterations were recorded.
        body_steps:     Steps that make up one representative iteration.
    """

    location: Location
    iteration_count: int = 0
    body_steps: list[FlowStep] = field(default_factory=list)


@dataclass(frozen=True)
class Call:
    """A recorded function/method call.

    Attributes:
        function_name: The callee's name.
        location:      Source location of the call site.
        arguments:     Captured argument values.
        return_value:  The return value (None if the call has not returned yet).
    """

    function_name: str
    location: Location
    arguments: list[Variable] = field(default_factory=list)
    return_value: Optional[Variable] = None


@dataclass(frozen=True)
class Event:
    """A trace event (e.g. breakpoint hit, exception, signal).

    Attributes:
        kind:     A short string classifying the event (e.g. "breakpoint").
        message:  Human-readable description.
        location: Where in the source the event occurred.
        data:     Arbitrary event-specific payload.
    """

    kind: str
    message: str
    location: Optional[Location] = None
    data: Optional[dict[str, Any]] = None


@dataclass(frozen=True)
class Process:
    """Metadata about the recorded process.

    Attributes:
        pid:        The process ID of the recorded execution.
        executable: Path to the executable that was recorded.
        arguments:  Command-line arguments passed to the executable.
        exit_code:  Exit code of the process (None if still running or unknown).
    """

    pid: int
    executable: str
    arguments: list[str] = field(default_factory=list)
    exit_code: Optional[int] = None
