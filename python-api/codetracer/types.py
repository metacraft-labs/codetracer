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
    """A source-code location (path, line, optional column).

    Attributes:
        path:   Filesystem path to the source file.
        line:   1-based line number.
        column: 1-based column number (0 if unknown).
    """

    path: str
    line: int
    column: int = 0

    def __str__(self) -> str:
        if self.column:
            return f"{self.path}:{self.line}:{self.column}"
        return f"{self.path}:{self.line}"


@dataclass(frozen=True)
class Variable:
    """A captured variable value at a specific point in execution.

    Attributes:
        name:      The variable's identifier in the source program.
        value:     The string representation of the variable's value.
        type_name: The type of the variable (language-specific, may be None).
        children:  Nested child variables (e.g. struct fields), expanded
                   up to the requested depth limit.
    """

    name: str
    value: str
    type_name: Optional[str] = None
    children: list["Variable"] = field(default_factory=list)


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

    Each step captures the variable state before and after execution of
    the line, along with loop context (which loop iteration the step
    belongs to, if any).

    Attributes:
        location:      The source location of this step.
        ticks:         The execution timestamp (rrTicks) for this step.
        loop_id:       The loop this step belongs to (0 = not in a loop).
        iteration:     The iteration index within the loop.
        before_values: Variable values captured before executing this line.
        after_values:  Variable values captured after executing this line.
        variables:     Legacy field: variables captured at this step.
        step_index:    Legacy field: the global step index in the trace.
    """

    location: Location
    ticks: int = 0
    loop_id: int = 0
    iteration: int = 0
    before_values: dict[str, str] = field(default_factory=dict)
    after_values: dict[str, str] = field(default_factory=dict)
    variables: list[Variable] = field(default_factory=list)
    step_index: Optional[int] = None


@dataclass(frozen=True)
class Flow:
    """An execution flow: a contiguous sequence of executed steps.

    Flow (omniscience) is CodeTracer's signature feature: it shows all
    variable values across execution of a function or a specific line.

    Attributes:
        steps: Ordered list of flow steps.
        loops: Detected loops within the flow.
    """

    steps: list[FlowStep] = field(default_factory=list)
    loops: list["Loop"] = field(default_factory=list)


@dataclass(frozen=True)
class Loop:
    """A detected loop in the execution trace.

    Attributes:
        id:              Unique loop identifier within the flow response.
        location:        Source location of the loop header.
        start_line:      The first line of the loop body.
        end_line:        The last line of the loop body.
        iteration_count: How many iterations were recorded.
        body_steps:      Legacy field: steps that make up one representative iteration.
    """

    id: int = 0
    location: Location = field(default_factory=lambda: Location(path="", line=0))
    start_line: int = 0
    end_line: int = 0
    iteration_count: int = 0
    body_steps: list[FlowStep] = field(default_factory=list)


@dataclass(frozen=True)
class Call:
    """A recorded function/method call.

    Attributes:
        function_name:  The callee's name.
        location:       Source location of the call site.
        arguments:      Captured argument values.
        return_value:   The return value (None if the call has not returned yet).
        id:             Unique call identifier within the call trace.
        children_count: Number of direct child calls made by this function.
        depth:          Nesting depth in the call tree (0 = top-level).
    """

    function_name: str
    location: Location
    arguments: list[Variable] = field(default_factory=list)
    return_value: Optional[Variable] = None
    id: int = 0
    children_count: int = 0
    depth: int = 0


@dataclass(frozen=True)
class Event:
    """A trace event (e.g. stdout output, stderr output, signal).

    Attributes:
        kind:     A short string classifying the event (e.g. "stdout", "stderr").
        message:  Human-readable description.
        location: Where in the source the event occurred.
        data:     Arbitrary event-specific payload.
        id:       Unique event identifier within the trace.
        ticks:    Execution timestamp (rrTicks) when the event occurred.
        content:  Raw content of the event (e.g. the actual stdout text).
    """

    kind: str
    message: str
    location: Optional[Location] = None
    data: Optional[dict[str, Any]] = None
    id: int = 0
    ticks: int = 0
    content: str = ""


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
