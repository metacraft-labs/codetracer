"""Data types for the CodeTracer Trace Query API.

These dataclasses represent the core entities that a recorded program
execution exposes: source locations, variables, call frames, control-flow
steps, and high-level constructs such as loops and function calls.

All types support both attribute and dictionary-style access, so that
``var.name`` and ``var['name']`` are interchangeable.  Common short
aliases are also supported (e.g. ``call['function']`` resolves to
``call.function_name``, ``var['type']`` resolves to ``var.type_name``).
"""

from __future__ import annotations

import dataclasses
from dataclasses import dataclass, field
from typing import Any, Optional


class DictAccessMixin:
    """Mixin providing dict-like access to frozen dataclass fields.

    LLM agents frequently try dictionary-style access on dataclass
    instances (``call['function']``, ``var.get('type')``).  This mixin
    makes both patterns work transparently.

    Subclasses may define ``_ALIASES`` as a class-level dict mapping
    short names to the actual field names.  For example::

        _ALIASES = {'function': 'function_name'}

    allows ``call['function']`` to resolve to ``call.function_name``.
    """

    _ALIASES: dict[str, str] = {}

    def _resolve_key(self, key: str) -> str:
        """Map *key* through ``_ALIASES``, falling back to *key* itself."""
        aliases = getattr(self.__class__, "_ALIASES", {})
        return aliases.get(key, key)

    def __getitem__(self, key: str) -> Any:
        resolved = self._resolve_key(key)
        try:
            return getattr(self, resolved)
        except AttributeError:
            raise KeyError(key) from None

    def get(self, key: str, default: Any = None) -> Any:
        """Return ``self[key]`` if *key* exists, else *default*."""
        try:
            return self[key]
        except KeyError:
            return default

    def __contains__(self, key: str) -> bool:
        resolved = self._resolve_key(key)
        return hasattr(self, resolved)

    def keys(self) -> list[str]:
        """Return the list of field names (like ``dict.keys()``)."""
        return [f.name for f in dataclasses.fields(self)]

    def values(self) -> list[Any]:
        """Return the list of field values (like ``dict.values()``)."""
        return [getattr(self, f.name) for f in dataclasses.fields(self)]

    def items(self) -> list[tuple[str, Any]]:
        """Return ``(name, value)`` pairs (like ``dict.items()``)."""
        return [(f.name, getattr(self, f.name)) for f in dataclasses.fields(self)]


@dataclass(frozen=True)
class Location(DictAccessMixin):
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
class Variable(DictAccessMixin):
    """A captured variable value at a specific point in execution.

    Attributes:
        name:      The variable's identifier in the source program.
        value:     The string representation of the variable's value.
        type_name: The type of the variable (language-specific, may be None).
        children:  Nested child variables (e.g. struct fields), expanded
                   up to the requested depth limit.
    """

    # Allow ``var['type']`` as shorthand for ``var.type_name``.
    _ALIASES = {"type": "type_name"}

    name: str
    value: str
    type_name: Optional[str] = None
    children: list["Variable"] = field(default_factory=list)


@dataclass(frozen=True)
class Frame(DictAccessMixin):
    """A single call-frame on the execution stack.

    Attributes:
        function_name: The name of the function/method.
        location:      Where in the source this frame is executing.
        variables:     Variables visible in this frame's scope.
    """

    # Allow ``frame['function']`` as shorthand for ``frame.function_name``.
    _ALIASES = {"function": "function_name"}

    function_name: str
    location: Location
    variables: list[Variable] = field(default_factory=list)


@dataclass(frozen=True)
class FlowStep(DictAccessMixin):
    """One step in a value trace (a single executed source line).

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


# ValueTraceStep is the preferred name; FlowStep is retained for
# backwards compatibility.
ValueTraceStep = FlowStep


@dataclass(frozen=True)
class Flow(DictAccessMixin):
    """A value trace: a contiguous sequence of executed steps with variable values.

    Value trace (omniscience) is CodeTracer's signature feature: it shows all
    variable values across execution of a function or a specific line.

    Attributes:
        steps: Ordered list of value trace steps.
        loops: Detected loops within the value trace.
    """

    steps: list[FlowStep] = field(default_factory=list)
    loops: list["Loop"] = field(default_factory=list)


# ValueTrace is the preferred name; Flow is retained for backwards
# compatibility.
ValueTrace = Flow


@dataclass(frozen=True)
class Loop(DictAccessMixin):
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
class Call(DictAccessMixin):
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

    # Allow ``call['function']`` as shorthand for ``call.function_name``.
    _ALIASES = {"function": "function_name"}

    function_name: str
    location: Location
    arguments: list[Variable] = field(default_factory=list)
    return_value: Optional[Variable] = None
    id: int = 0
    children_count: int = 0
    depth: int = 0


@dataclass(frozen=True)
class Event(DictAccessMixin):
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
class Process(DictAccessMixin):
    """A process in a multi-process trace.

    Multi-process traces contain multiple recorded processes that can be
    individually selected and queried.  Single-process traces expose
    exactly one ``Process`` entry.

    Attributes:
        id:      Unique process identifier within the trace.
        name:    Short display name for the process (e.g. ``"main"``).
        command: The command line that was executed.
    """

    id: int
    name: str
    command: str


@dataclass(frozen=True)
class MemoryPageDiff(DictAccessMixin):
    """A single page that differs between two memory snapshots.

    Returned inside :class:`MemoryDiffResult.diffs` when
    :meth:`Trace.memory_diff` finds writable-memory differences between
    two ``evMemorySnapshot`` events captured by MCR's MW47 producer
    (``ct_interpose/src/ct_interpose/recording/memory_snapshot_windows.nim``).

    Attributes:
        page_index:     Flat-page-hash array index of the differing page.
        page_va:        Virtual address (hex string ``"0x..."``) of the
                        page in the recorded process's address space.
        region_base:    Base virtual address of the containing
                        ``VirtualQueryEx`` region.
        region_protect: Win32 ``PAGE_*`` protection bits at capture time.
        hash_recorded:  ``xxh64`` of the page bytes at snapshot A.
        hash_replayed:  ``xxh64`` of the page bytes at snapshot B.
    """

    page_index: int
    page_va: str
    region_base: str
    region_protect: int
    hash_recorded: str
    hash_replayed: str


@dataclass(frozen=True)
class MemoryDiffResult(DictAccessMixin):
    """Result of :meth:`Trace.memory_diff`.

    Reports the writable-memory pages whose page hash differs between
    two ``evMemorySnapshot`` events in the trace and — crucially for the
    cascade-peeling workflow — the GEID of the *earliest* snapshot
    between the two endpoints whose hashes diverge from snapshot A.
    Agents binary-search on ``first_divergence_event_geid`` to localise
    the precise event boundary at which the missing-capture surface
    fired.

    See also: ``feedback_mcr_divergence_is_a_bug`` (no slight divergence
    is tolerable; the diff is the diagnostic, never a normaliser).

    Attributes:
        event_a:                     GEID of snapshot A (resolved).
        event_b:                     GEID of snapshot B (resolved).
        snapshots_in_range:          Count of ``evMemorySnapshot`` events
                                     observed in ``[event_a .. event_b]``.
        pages_compared:              Number of page hashes that were
                                     paired (``min(A.pages, B.pages)``).
        differing_pages:             Total count of differing pages
                                     across the whole snapshot, even if
                                     more than ``max_diffs`` are returned.
        truncated:                   ``True`` iff ``differing_pages >
                                     len(diffs)``.
        first_divergence_event_geid: GEID of the earliest snapshot in
                                     ``(event_a, event_b]`` whose page
                                     hashes differ from snapshot A, or
                                     ``-1`` if none was found.  This is
                                     the field the binary-search bisect
                                     iterates on.
        diffs:                       Up to ``max_diffs`` differing pages.
    """

    event_a: int
    event_b: int
    snapshots_in_range: int
    pages_compared: int
    differing_pages: int
    truncated: bool
    first_divergence_event_geid: int
    diffs: list[MemoryPageDiff]
