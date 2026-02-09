"""Exception hierarchy for the CodeTracer Trace Query API.

All CodeTracer-specific exceptions inherit from :class:`TraceError` so that
callers can catch a single base class when they do not care about the
specific failure mode.
"""


class TraceError(Exception):
    """Base exception for all CodeTracer trace operations."""


class TraceNotFoundError(TraceError):
    """Raised when the requested trace does not exist or cannot be opened."""


class NavigationError(TraceError):
    """Raised when a navigation operation is invalid.

    Examples include stepping past the end of the trace, seeking to an
    invalid step index, or requesting a frame that does not exist.
    """


class ExpressionError(TraceError):
    """Raised when an expression cannot be evaluated in the current context.

    This may happen because the expression references variables that are
    not in scope, contains syntax errors, or the backend reports an
    evaluation failure.
    """


class TimeoutError(TraceError):
    """Raised when a backend operation exceeds the configured timeout.

    This is distinct from the built-in :class:`builtins.TimeoutError` to
    allow callers to distinguish CodeTracer timeouts from OS-level ones.
    """
