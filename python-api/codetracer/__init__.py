"""CodeTracer Trace Query API.

Navigate, inspect, and analyze recorded program executions.
"""
from codetracer.trace import Trace, open_trace
from codetracer.types import (
    Location,
    Variable,
    Frame,
    FlowStep,
    Flow,
    Loop,
    Call,
    Event,
    Process,
)
from codetracer.exceptions import (
    TraceError,
    TraceNotFoundError,
    NavigationError,
    ExpressionError,
)

__version__ = "0.1.0"
__all__ = [
    "Trace",
    "open_trace",
    "Location",
    "Variable",
    "Frame",
    "FlowStep",
    "Flow",
    "Loop",
    "Call",
    "Event",
    "Process",
    "TraceError",
    "TraceNotFoundError",
    "NavigationError",
    "ExpressionError",
]
