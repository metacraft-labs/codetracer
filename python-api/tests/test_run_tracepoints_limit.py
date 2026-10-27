"""``Trace.run_tracepoints`` takes an explicit limit.

Viewport-Driven-Loading, Decided Q4: a sweep's results are bounded by the
caller, so a script that wants every hit of a long recording says so
(``limit=None``). These tests pin what the method SENDS to the daemon.

WHY A FAKE CONNECTION: the property under test is the request the method
writes (``ct/py-run-tracepoints`` and its ``limit``) and the refusal of a
call without one, neither of which needs a daemon or a recording; the
daemon's handling of ``limit`` is covered by the backend-manager's tests.
"""

from __future__ import annotations

import pytest

from codetracer.trace import Trace


class FakeConnection:
    """Records each request and answers a successful, empty sweep."""

    def __init__(self) -> None:
        self.sent: list[tuple[str, dict]] = []

    def send_request(self, command: str, arguments: dict) -> dict:
        self.sent.append((command, arguments))
        return {"success": True, "body": {"results": [], "errors": {}}}


def make_trace() -> tuple[Trace, FakeConnection]:
    connection = FakeConnection()
    return Trace("/rec", connection), connection  # type: ignore[arg-type]


def test_a_call_without_a_limit_is_refused():
    trace, connection = make_trace()
    with pytest.raises(TypeError, match="explicit limit"):
        trace.run_tracepoints()
    assert connection.sent == []


def test_the_limit_is_sent():
    trace, connection = make_trace()
    trace.run_tracepoints(limit=25)
    assert connection.sent == [
        ("ct/py-run-tracepoints", {"tracePath": "/rec", "limit": 25})
    ]


def test_none_asks_for_every_hit():
    trace, connection = make_trace()
    trace.run_tracepoints(limit=None)
    assert connection.sent[0][1]["limit"] == -1


def test_the_older_stop_after_still_bounds_the_sweep():
    trace, connection = make_trace()
    trace.run_tracepoints(stop_after=7)
    trace.run_tracepoints(stop_after=-1)
    assert [args["limit"] for _, args in connection.sent] == [7, -1]


@pytest.mark.parametrize("bad", [-3, 1.5, True, "10"])
def test_a_bad_limit_is_refused(bad):
    trace, connection = make_trace()
    with pytest.raises(ValueError):
        trace.run_tracepoints(limit=bad)
    assert connection.sent == []
