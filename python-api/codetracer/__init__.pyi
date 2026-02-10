"""Type stubs for the codetracer package."""

from codetracer.trace import Trace as Trace, open_trace as open_trace
from codetracer.types import (
    Call as Call,
    Event as Event,
    Flow as Flow,
    FlowStep as FlowStep,
    Frame as Frame,
    Location as Location,
    Loop as Loop,
    Process as Process,
    Variable as Variable,
)
from codetracer.exceptions import (
    ExpressionError as ExpressionError,
    NavigationError as NavigationError,
    TraceError as TraceError,
    TraceNotFoundError as TraceNotFoundError,
)

__version__: str
__all__: list[str]
