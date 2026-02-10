"""Type stubs for codetracer.exceptions -- exception hierarchy."""

class TraceError(Exception):
    """Base exception for all CodeTracer trace operations."""
    ...

class TraceNotFoundError(TraceError):
    """Raised when the requested trace does not exist or cannot be opened."""
    ...

class NavigationError(TraceError):
    """Raised when a navigation operation is invalid."""
    ...

class ExpressionError(TraceError):
    """Raised when an expression cannot be evaluated in the current context."""
    ...

class TimeoutError(TraceError):
    """Raised when a backend operation exceeds the configured timeout."""
    ...
