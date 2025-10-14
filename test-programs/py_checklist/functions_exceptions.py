"""Function-call mechanics, decorators, and exception handling probes."""

from __future__ import annotations

import functools
import warnings
from typing import Any, Callable, Dict, List


def demo_1_call_signatures() -> None:
    """Exercise positional-only, keyword-only, varargs, and kwargs.

    Complex APIs frequently mix these features. We report the total
    contribution to highlight how each argument path is interpreted.
    """

    def signature(a: int, /, b: int, *c: int, d: int = 0, **k: int) -> int:
        return a + b + d + len(c) + len(k)

    result = signature(1, 2, 3, 4, d=5, x=6, y=7)
    print("1. signature:", result)


def demo_2_mutable_default() -> None:
    """Show why mutating default arguments is dangerous."""

    def append(item: int, bucket: List[int] = []) -> List[int]:
        bucket.append(item)  # same list reused across calls.
        return bucket

    first = append(1)
    second = append(2)  # demonstrates mutation leak.
    print("2. mutable-default:", first, second)


def demo_3_docstrings_annotations() -> None:
    """Docstrings and annotations retain runtime metadata."""

    def stringify(x: int) -> str:
        """Return str of x."""
        return str(x)

    has_doc = bool(stringify.__doc__)
    annotation_ok = stringify.__annotations__["x"] is int
    status = "ok" if has_doc and annotation_ok else "missing"
    print("3. doc+annotations:", status, has_doc, annotation_ok)


def demo_4_closures() -> None:
    """Closures with `nonlocal` and module-level globals."""

    counter = 0

    def make_inc() -> Callable[[], int]:
        x = 0

        def inc() -> int:
            nonlocal x
            x += 1
            return x

        return inc

    inc = make_inc()
    v1, v2 = inc(), inc()

    def bump(global_dict: Dict[str, int]) -> int:
        global_dict["counter"] += 1
        return global_dict["counter"]

    global_state = {"counter": counter}
    bumped = bump(global_state)
    print("4. closures:", v1, v2, bumped)


def demo_5_decorators() -> None:
    """Trace and tag decorators similar to instrumentation wrappers."""

    def trace(fn: Callable[..., Any]) -> Callable[..., Any]:
        def wrap(*args: Any, **kwargs: Any) -> Any:
            print(f"trace: {fn.__name__} args={args} kwargs={kwargs}")
            return fn(*args, **kwargs)

        return wrap

    def tag(prefix: str) -> Callable[[Callable[..., Any]], Callable[..., Any]]:
        def deco(fn: Callable[..., Any]) -> Callable[..., Any]:
            def wrap(*args: Any, **kwargs: Any) -> Any:
                print(f"{prefix}: {fn.__name__}")
                return fn(*args, **kwargs)

            return wrap

        return deco

    @trace
    @tag("DBG")
    def add(a: int, b: int = 0) -> int:
        return a + b

    class Toolbox:
        @staticmethod
        def static() -> str:
            return "static"  # utility helpers that ignore instance state.

        @classmethod
        def class_name(cls) -> str:
            return cls.__name__  # commonly used for alternative constructors.

    partial_hex = functools.partial(int, base=16)
    print(
        "5. decorators:",
        add(2, b=3),
        Toolbox.static(),
        Toolbox.class_name(),
        partial_hex("FF"),
    )


def demo_6_lru_cache() -> None:
    """Demonstrate recursion with functools.lru_cache."""

    @functools.lru_cache
    def fib(n: int) -> int:
        return n if n < 2 else fib(n - 1) + fib(n - 2)

    print("6. lru-cache:", fib(8))


def demo_7_exceptions() -> None:
    """Structured exception handling, raise from, warnings, ExceptionGroup."""

    class WrappedError(Exception):
        pass

    try:
        try:
            1 / 0
        except ZeroDivisionError as exc:
            raise WrappedError("wrapped") from exc
    except WrappedError as err:
        cause = type(err.__cause__).__name__
    else:
        cause = "no-exception"
    finally:
        cleanup = "finally-ran"

    warnings.warn("7b. warning via warnings.warn", RuntimeWarning)

    def boom() -> None:
        raise ExceptionGroup("many", [ValueError("v"), TypeError("t")])

    values: List[str] = []
    types: List[str] = []
    try:
        boom()
    except* ValueError as group:
        values = [repr(exc) for exc in group.exceptions]
    except* TypeError as group:
        types = [repr(exc) for exc in group.exceptions]

    print(
        "7. exceptions:",
        cause,
        cleanup,
        values,
        types,
    )


def run_all() -> None:
    """Execute demos for this module."""
    demo_1_call_signatures()
    demo_2_mutable_default()
    demo_3_docstrings_annotations()
    demo_4_closures()
    demo_5_decorators()
    demo_6_lru_cache()
    demo_7_exceptions()


if __name__ == "__main__":
    run_all()
