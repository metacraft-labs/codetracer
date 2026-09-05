#!/usr/bin/env python3
"""calc — the small, fast, deterministic program behind CTUI-1's ``calc`` fixture.

WHY THIS PROGRAM EXISTS, AND WHY IT LOOKS LIKE THIS
---------------------------------------------------
``codetracer-specs/Front-Ends/CodeTracer-TUI.milestones.org`` (CTUI-1) asks for
a fixture that is "small, fast, deterministic; the default for stepping and
layout tests".  Every constraint in that sentence is a constraint on this file:

* **small / fast** — the fixture is recorded on demand by
  ``src/frontend/tui/tests/fixtures/fixture_provider.nim`` and the Tier-1 TUI
  lane pays for that recording the first time it runs on a workspace.  The
  whole program is a few hundred recorded steps, so the record step costs
  seconds rather than minutes.
* **deterministic** — no clock, no randomness, no environment lookups, no I/O
  other than ``print``.  A fixture whose trace differs between two recordings
  cannot be the ground truth for a stepping test.
* **stepping and layout** — it is written as a chain of *small named calls*
  (``main`` -> ``evaluate`` -> ``apply_op`` -> ``add``/``sub``/``mul``/``div``)
  rather than as one flat loop, because a calltrace pane with a single frame in
  it exercises nothing.  Every step lands in a named function with live locals.

Nothing here asserts anything.  The assertions live in
``src/frontend/tui/tests/test_fixture_corpus.nim``, which opens the recorded
trace through a real ``HeadlessDebugSession``.
"""


def add(left, right):
    """Integer addition, as its own frame so stepping has somewhere to step."""
    return left + right


def sub(left, right):
    """Integer subtraction."""
    return left - right


def mul(left, right):
    """Integer multiplication."""
    return left * right


def div(left, right):
    """Floor division.  ``//`` rather than ``/`` keeps every recorded value an
    ``int``: a float would make the printed output depend on the interpreter's
    repr, and this program's whole job is to be identical on every host."""
    return left // right


# The dispatch table is deliberately module-level and constant: the operator
# lookup is then a value the debugger can show, not a branch it has to unfold.
OPERATIONS = {
    "+": add,
    "-": sub,
    "*": mul,
    "/": div,
}


def apply_op(symbol, left, right):
    """Resolve one operator symbol and apply it.

    This frame exists so that the calltrace has a middle layer — the value
    ``left`` visibly flows main -> evaluate -> apply_op -> add, which is the
    shape a value-origin or a call-stack pane is read against.
    """
    operation = OPERATIONS[symbol]
    return operation(left, right)


def evaluate(expression):
    """Evaluate a strictly left-to-right space-separated integer expression.

    No operator precedence on purpose: precedence would need a parser, and a
    parser is a second thing that can be wrong in a file whose only job is to
    be boring.
    """
    tokens = expression.split()
    total = int(tokens[0])
    index = 1
    while index < len(tokens):
        symbol = tokens[index]
        operand = int(tokens[index + 1])
        total = apply_op(symbol, total, operand)
        index += 2
    return total


EXPRESSIONS = [
    "2 + 3",
    "10 - 4 + 1",
    "6 * 7",
    "100 / 5 - 3",
    "1 + 2 * 3 - 4 / 2",
]


def main():
    """Evaluate every expression and print the result.

    Called unconditionally at module level rather than from an
    ``if __name__ == "__main__"`` guard: recorders launch this file in several
    different ways (as a script, as a module, through a wrapper) and the guard
    is one more way for a recording to come back empty.
    """
    results = []
    for expression in EXPRESSIONS:
        value = evaluate(expression)
        results.append(value)
        print("%s = %d" % (expression, value))
    print("checksum = %d" % sum(results))
    return results


main()
