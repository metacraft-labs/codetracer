"""``Trace.run_tracepoints`` takes an explicit limit.

Viewport-Driven-Loading, Decided Q4: a sweep's results are bounded by the
caller, so a script that wants every hit of a long recording says so
(``limit=None``). These tests pin what the method SENDS to the daemon, and
that a refused sweep raises with the daemon's reason.

WHY A FAKE CONNECTION: the property under test is the request the method
writes (``ct/py-run-tracepoints`` and its ``limit``), the refusal of a
call without one, and what the method does with a refusal answer, none of
which needs a daemon or a recording; the daemon's handling of ``limit``, and
its passing on of a replay server's refusal as that answer, are covered by
the backend-manager's tests.
"""

from __future__ import annotations

import pytest

from codetracer.exceptions import TraceError
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


class RefusingConnection:
    """Answers the sweep as the daemon answers a refused one."""

    def __init__(self, message: str) -> None:
        self.message = message

    def send_request(self, command: str, arguments: dict) -> dict:
        return {
            "type": "response",
            "command": command,
            "success": False,
            "message": self.message,
        }


def test_a_refused_sweep_raises_with_the_daemons_reason():
    # The daemon answers a sweep the replay server refused with
    # ``success: false`` and the reason (it used to answer nothing, and the
    # call waited for ever); the method must surface that reason rather
    # than return an empty result list.
    reason = "ct/run-tracepoints failed: no trace is loaded"
    trace = Trace("/rec", RefusingConnection(reason))  # type: ignore[arg-type]
    with pytest.raises(TraceError, match="no trace is loaded"):
        trace.run_tracepoints(limit=10)
