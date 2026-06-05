"""Value Origin Tracking — Python data model + renderers.

This module mirrors the wire types defined in
``src/db-backend/src/task.rs`` (see spec §4.1 — *OriginChain*,
*OriginHop*, *OperandSnapshot*, *Terminator*, *FrameTransition*).

The :class:`OriginChain` returned by :meth:`Trace.value_origin` is a
read-only Python representation of the JSON body the backend produces
for ``ct/originChain``.  It exposes:

- A typed dataclass surface (every wire field becomes a typed attribute).
- :meth:`OriginChain.to_markdown` — fenced markdown report suitable for
  pasting into a GitHub issue or chat message.
- :meth:`OriginChain.to_text` — ASCII chain layout matching spec
  §3.2 (expanded hop chain), used by ``ct trace origin --format text``.
- :meth:`OriginChain.from_wire` — parse the daemon's JSON response.

The renderers are intentionally pure functions: they take no I/O, do not
touch the network, and produce deterministic output so they can be
unit-tested without a recorder in scope.
"""

from __future__ import annotations

import enum
import os
from dataclasses import dataclass, field
from typing import Any, Iterable, Optional

from codetracer.types import Location


# ---------------------------------------------------------------------------
# Enums — closed type-space carried by every chain.
# ---------------------------------------------------------------------------


class OriginKind(str, enum.Enum):
    """Per-hop classification — mirrors ``db_backend::task::OriginKind``."""

    TRIVIAL_COPY = "trivialCopy"
    FIELD_ACCESS = "fieldAccess"
    INDEX_ACCESS = "indexAccess"
    COMPUTATIONAL = "computational"
    FUNCTION_CALL = "functionCall"
    LITERAL = "literal"
    RETURN_CAPTURE = "returnCapture"
    FUNCTION_RETURN = "functionReturn"
    PARAMETER_PASS = "parameterPass"
    CROSS_THREAD_COPY = "crossThreadCopy"
    UNKNOWN = "unknown"

    @classmethod
    def _missing_(cls, value: object) -> "OriginKind":  # type: ignore[override]
        # Wire values arrive lower-case camelCase from the backend; in
        # rare cases a recorder may emit PascalCase or snake_case. Accept
        # any casing rather than failing to parse the chain.
        if isinstance(value, str):
            normalized = value[:1].lower() + value[1:]
            for member in cls:
                if member.value == normalized:
                    return member
        return cls.UNKNOWN


class TerminatorKind(str, enum.Enum):
    """Why the backward search stopped — mirrors ``db_backend::task::TerminatorKind``."""

    LITERAL = "literal"
    COMPUTATIONAL = "computational"
    PARAMETER_AT_RECORD_START = "parameterAtRecordStart"
    READ_FROM_EXTERNAL = "readFromExternal"
    RECORDING_START = "recordingStart"
    UNKNOWN_SOURCE = "unknownSource"
    UNKNOWN_VARIABLE = "unknownVariable"
    DEPTH_LIMIT = "depthLimit"
    OUT_OF_BUDGET = "outOfBudget"

    @classmethod
    def _missing_(cls, value: object) -> "TerminatorKind":  # type: ignore[override]
        if isinstance(value, str):
            normalized = value[:1].lower() + value[1:]
            for member in cls:
                if member.value == normalized:
                    return member
        return cls.UNKNOWN_SOURCE


class FrameTransitionKind(str, enum.Enum):
    """Whether a hop crosses *into* a callee or *out of* one."""

    PARAMETER_PASS = "parameterPass"
    RETURN_CAPTURE = "returnCapture"

    @classmethod
    def _missing_(cls, value: object) -> "FrameTransitionKind":  # type: ignore[override]
        if isinstance(value, str):
            normalized = value[:1].lower() + value[1:]
            for member in cls:
                if member.value == normalized:
                    return member
        return cls.PARAMETER_PASS


# ---------------------------------------------------------------------------
# Leaf dataclasses
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class OperandSnapshot:
    """One operand value sampled at a Computational hop.

    Mirrors ``db_backend::task::OperandSnapshot``.  ``value`` is rendered
    by :meth:`Trace._value_str`-equivalent logic at parse time so callers
    don't have to know about the wire's nested ``ValueRecordWithType``
    envelope.
    """

    name: str
    value: str
    source_step: int

    @classmethod
    def from_wire(cls, data: dict) -> "OperandSnapshot":
        return cls(
            name=data.get("name", ""),
            value=_render_value_record(data.get("value")),
            source_step=int(data.get("sourceStep", 0)),
        )


@dataclass(frozen=True)
class FrameTransition:
    """Per-hop frame-transition descriptor."""

    kind: FrameTransitionKind
    from_function: str
    to_function: str
    call_key: int

    @classmethod
    def from_wire(cls, data: dict) -> "FrameTransition":
        return cls(
            kind=FrameTransitionKind(data.get("kind", "parameterPass")),
            from_function=data.get("fromFunction", ""),
            to_function=data.get("toFunction", ""),
            call_key=int(data.get("callKey", 0)),
        )


@dataclass(frozen=True)
class OriginHop:
    """One hop in a value-origin chain — mirrors ``db_backend::task::OriginHop``."""

    kind: OriginKind
    target_expr: str
    source_expr: str
    source_variable: Optional[str]
    location: Location
    source_text: str
    step_id: int
    frame_transition: Optional[FrameTransition]
    operand_snapshots: tuple[OperandSnapshot, ...]
    truncated_operands: bool
    confidence: float

    @classmethod
    def from_wire(cls, data: dict) -> "OriginHop":
        loc = data.get("location") or {}
        return cls(
            kind=OriginKind(data.get("kind", "unknown")),
            target_expr=data.get("targetExpr", ""),
            source_expr=data.get("sourceExpr", ""),
            source_variable=data.get("sourceVariable"),
            location=Location(
                path=loc.get("path", ""),
                line=int(loc.get("line", 0)),
                column=int(loc.get("column", 0) or 0),
            ),
            source_text=data.get("sourceText", ""),
            step_id=int(data.get("stepId", 0)),
            frame_transition=(
                FrameTransition.from_wire(data["frameTransition"])
                if data.get("frameTransition")
                else None
            ),
            operand_snapshots=tuple(
                OperandSnapshot.from_wire(o)
                for o in (data.get("operandSnapshots") or [])
            ),
            truncated_operands=bool(data.get("truncatedOperands", False)),
            confidence=float(data.get("confidence", 0.0)),
        )


@dataclass(frozen=True)
class Terminator:
    """Closed terminator descriptor surfaced in ``OriginChain.terminator``."""

    kind: TerminatorKind
    terminator_expr: str
    terminator_function: Optional[str]
    source_line: Optional[str]

    @classmethod
    def from_wire(cls, data: dict) -> "Terminator":
        return cls(
            kind=TerminatorKind(data.get("kind", "unknownSource")),
            terminator_expr=data.get("expression", ""),
            terminator_function=data.get("function"),
            source_line=data.get("sourceLine"),
        )


@dataclass(frozen=True)
class OriginMetrics:
    """Per-chain budget metrics."""

    steps_scanned: int = 0
    elapsed_ms: int = 0
    classifier_hits: int = 0

    @classmethod
    def from_wire(cls, data: Optional[dict]) -> "OriginMetrics":
        if not data:
            return cls()
        return cls(
            steps_scanned=int(data.get("stepsScanned", 0)),
            elapsed_ms=int(data.get("elapsedMs", 0)),
            classifier_hits=int(data.get("classifierHits", 0)),
        )


# ---------------------------------------------------------------------------
# OriginChain — the top-level object
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class OriginChain:
    """The full origin chain returned by ``ct/originChain``.

    See spec §4.1 for the wire-side type definition.  Instances are
    immutable; iterate over :attr:`hops` to walk the chain.
    """

    query_variable: str
    query_step_id: int
    hops: tuple[OriginHop, ...]
    terminator: Terminator
    truncated: bool
    continuation_token: Optional[str]
    metrics: OriginMetrics
    confidence: float = 0.0

    # ----- Parsing --------------------------------------------------

    @classmethod
    def from_wire(cls, data: dict) -> "OriginChain":
        """Parse a JSON dict (the DAP response ``body``) into a chain.

        The wire shape is camelCase and matches the rendering of
        ``db_backend::task::OriginChain``.  Missing fields fall back to
        sensible defaults so this method accepts both fully-populated
        responses and stub fixtures used in unit tests.
        """
        hops_raw = data.get("hops") or []
        return cls(
            query_variable=data.get("queryVariable", ""),
            query_step_id=int(data.get("queryStepId", 0)),
            hops=tuple(OriginHop.from_wire(h) for h in hops_raw),
            terminator=Terminator.from_wire(data.get("terminator") or {}),
            truncated=bool(data.get("truncated", False)),
            continuation_token=data.get("continuationToken"),
            metrics=OriginMetrics.from_wire(data.get("metrics")),
            confidence=float(data.get("confidence", 0.0)),
        )

    # ----- Convenience accessors -----------------------------------

    @property
    def hop_count(self) -> int:
        return len(self.hops)

    def __iter__(self) -> Iterable[OriginHop]:  # type: ignore[override]
        return iter(self.hops)

    def __len__(self) -> int:
        return len(self.hops)

    def __getitem__(self, index: int) -> OriginHop:
        return self.hops[index]

    # ----- Renderers -----------------------------------------------

    def to_text(self) -> str:
        """Render the chain in the ASCII layout from spec §3.2.

        Newest hop first; each hop emits two lines (location + source
        text); the terminator is the final row.  This is what the CLI
        produces when invoked with ``--format text``.
        """
        return _render_text(self)

    def to_markdown(self) -> str:
        """Render the chain as a GitHub-friendly markdown report."""
        return _render_markdown(self)


# ---------------------------------------------------------------------------
# Renderers — shared by the Python CLI and the standalone library callers.
# Their Rust twins live in ``src/backend-manager/src/origin_renderer.rs``.
# ---------------------------------------------------------------------------

# Glyphs deliberately use plain ASCII so the text renderer is friendly to
# narrow terminal width and downstream copy-paste into GitHub issues.
_ORIGIN_GLYPHS = {
    OriginKind.TRIVIAL_COPY: "=",
    OriginKind.FIELD_ACCESS: ".",
    OriginKind.INDEX_ACCESS: "[]",
    OriginKind.COMPUTATIONAL: "*",
    OriginKind.FUNCTION_CALL: "()",
    OriginKind.LITERAL: "L",
    OriginKind.RETURN_CAPTURE: "<-",
    OriginKind.FUNCTION_RETURN: "<<",
    OriginKind.PARAMETER_PASS: "->",
    OriginKind.CROSS_THREAD_COPY: "~",
    OriginKind.UNKNOWN: "?",
}

_TERMINATOR_GLYPHS = {
    TerminatorKind.COMPUTATIONAL: "(o)",
    TerminatorKind.LITERAL: "[lit]",
    TerminatorKind.PARAMETER_AT_RECORD_START: "[param]",
    TerminatorKind.READ_FROM_EXTERNAL: "[io]",
    TerminatorKind.RECORDING_START: "[start]",
    TerminatorKind.UNKNOWN_SOURCE: "[?src]",
    TerminatorKind.UNKNOWN_VARIABLE: "[?var]",
    TerminatorKind.DEPTH_LIMIT: "[depth]",
    TerminatorKind.OUT_OF_BUDGET: "[budget]",
}

_FRAME_TRANSITION_GLYPHS = {
    FrameTransitionKind.PARAMETER_PASS: "[>]",
    FrameTransitionKind.RETURN_CAPTURE: "[<]",
}


def _basename(path: str) -> str:
    """Return ``os.path.basename`` while tolerating empty strings."""
    if not path:
        return ""
    return os.path.basename(path)


def _format_location(loc: Location) -> str:
    base = _basename(loc.path)
    if not base:
        return f"<unknown>:{loc.line}"
    return f"{base}:{loc.line}"


def _render_text(chain: OriginChain) -> str:
    """ASCII chain layout — newest hop first, terminator at the bottom.

    Mirrors spec §3.2.2.  Lines kept under ~80 chars so they survive
    being copied into GitHub issue bodies and chat messages.
    """
    out: list[str] = []
    out.append(
        f"Origin chain for {chain.query_variable!r} @ step={chain.query_step_id}"
    )
    out.append(
        f"  hops={chain.hop_count} terminator={chain.terminator.kind.value} "
        f"truncated={'yes' if chain.truncated else 'no'}"
    )
    out.append("")
    for idx, hop in enumerate(chain.hops):
        glyph = _ORIGIN_GLYPHS.get(hop.kind, "?")
        location = _format_location(hop.location)
        frame = ""
        if hop.frame_transition is not None:
            frame = (
                "  " + _FRAME_TRANSITION_GLYPHS[hop.frame_transition.kind]
                + f" {hop.frame_transition.from_function} -> "
                + f"{hop.frame_transition.to_function}"
            )
        out.append(f"  {idx}. [{glyph}] {location}{frame}")
        source_text = hop.source_text.strip() or f"{hop.target_expr} = {hop.source_expr}"
        out.append(f"     {source_text}")
        if hop.kind == OriginKind.COMPUTATIONAL and hop.operand_snapshots:
            for operand in hop.operand_snapshots:
                out.append(f"       - {operand.name} = {operand.value}")
            if hop.truncated_operands:
                out.append("       - (more operands hidden)")
    # Terminator row.
    term_glyph = _TERMINATOR_GLYPHS.get(chain.terminator.kind, "[?]")
    out.append(
        f"  {term_glyph} {chain.terminator.terminator_expr or chain.terminator.kind.value}"
    )
    if chain.terminator.terminator_function:
        out.append(f"      @ {chain.terminator.terminator_function}")
    return "\n".join(out)


def _render_markdown(chain: OriginChain) -> str:
    """GitHub-issue-friendly markdown report."""
    lines: list[str] = []
    lines.append(
        f"### Origin chain — `{chain.query_variable}` @ step `{chain.query_step_id}`"
    )
    lines.append("")
    lines.append(
        f"- **Terminator:** `{chain.terminator.kind.value}` — "
        f"`{chain.terminator.terminator_expr or ''}`"
    )
    if chain.terminator.terminator_function:
        lines.append(
            f"- **Terminator function:** `{chain.terminator.terminator_function}`"
        )
    lines.append(f"- **Hops:** {chain.hop_count}")
    lines.append(f"- **Truncated:** {'yes' if chain.truncated else 'no'}")
    if chain.continuation_token:
        lines.append(f"- **Continuation token:** `{chain.continuation_token}`")
    lines.append("")
    if chain.hops:
        lines.append("| # | Kind | Location | Source | Confidence |")
        lines.append("| - | ---- | -------- | ------ | ---------- |")
        for idx, hop in enumerate(chain.hops):
            source = (hop.source_text.strip() or f"{hop.target_expr} = {hop.source_expr}").replace(
                "|", "\\|"
            )
            location = _format_location(hop.location).replace("|", "\\|")
            lines.append(
                f"| {idx} | `{hop.kind.value}` | `{location}` | `{source}` | "
                f"{hop.confidence:.2f} |"
            )
    # Operand details per Computational hop.
    computational_hops = [
        (idx, hop)
        for idx, hop in enumerate(chain.hops)
        if hop.kind == OriginKind.COMPUTATIONAL and hop.operand_snapshots
    ]
    if computational_hops:
        lines.append("")
        lines.append("#### Operand snapshots")
        for idx, hop in computational_hops:
            lines.append("")
            lines.append(f"Hop {idx} — `{hop.source_text.strip() or hop.source_expr}`:")
            for operand in hop.operand_snapshots:
                lines.append(f"- `{operand.name}` = `{operand.value}` (step {operand.source_step})")
            if hop.truncated_operands:
                lines.append("- *(more operands hidden)*")
    return "\n".join(lines)


def _render_value_record(value: Any) -> str:
    """Convert a backend ``ValueRecordWithType`` JSON envelope into a string.

    The wire shape from the materialized DB backend nests typed payloads
    in fields keyed by the value's discriminator (``i`` for ints,
    ``text`` for strings, etc.).  Mirrors the algorithm used by the
    daemon's ``python_bridge::extract_value_str`` helper so the operand
    strings the Python API surfaces line up 1-for-1 with the strings the
    standalone MCP tool surfaces.
    """
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if not isinstance(value, dict):
        return str(value)

    kind = value.get("kind")
    field_map = {
        7: "i",   # Int
        8: "f",   # Float
        9: "text",  # String
        10: "cText",  # CString
        11: "c",  # Char
        16: "r",  # Raw
    }
    if isinstance(kind, int) and kind in field_map:
        raw = value.get(field_map[kind])
        if raw is not None:
            return str(raw)
    if kind == 12:  # Bool
        return "true" if value.get("b") else "false"

    # Fallback: try the common scalar fields in order.
    for field_name in ("i", "f", "text", "r"):
        candidate = value.get(field_name)
        if isinstance(candidate, str) and candidate:
            return candidate

    # Last resort: dump the JSON so the operand snapshot still reads.
    import json

    return json.dumps(value, sort_keys=True)


__all__ = [
    "OriginChain",
    "OriginHop",
    "OperandSnapshot",
    "FrameTransition",
    "Terminator",
    "OriginMetrics",
    "OriginKind",
    "TerminatorKind",
    "FrameTransitionKind",
]
