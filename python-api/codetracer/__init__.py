"""CodeTracer Trace Query API.

Navigate, inspect, and analyze recorded program executions.
"""
from codetracer.trace import Trace, open_trace
from codetracer.types import (
    DictAccessMixin,
    Location,
    Variable,
    Frame,
    FlowStep,
    Flow,
    Loop,
    Call,
    Event,
    Process,
    ValueTrace,
    ValueTraceStep,
)
from codetracer.exceptions import (
    TraceError,
    TraceNotFoundError,
    NavigationError,
    ExpressionError,
)
from codetracer.origin import (
    OriginChain,
    OriginHop,
    OperandSnapshot,
    FrameTransition,
    Terminator,
    OriginMetrics,
    OriginKind,
    TerminatorKind,
    FrameTransitionKind,
)

__version__ = "0.1.0"
__all__ = [
    "Trace",
    "open_trace",
    "DictAccessMixin",
    "Location",
    "Variable",
    "Frame",
    "FlowStep",
    "Flow",
    "ValueTrace",
    "ValueTraceStep",
    "Loop",
    "Call",
    "Event",
    "Process",
    "TraceError",
    "TraceNotFoundError",
    "NavigationError",
    "ExpressionError",
    # Value Origin Tracking (M8)
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
