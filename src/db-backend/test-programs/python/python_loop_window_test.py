#!/usr/bin/env python3
"""Loop-window flow test program.

Driven by `tests/flow_loop_iteration_window_test.rs`, which asserts the exact
line numbers below. Do NOT reflow this file without updating that test:
line 11 = `def accumulate`, 12/13 = before the loop, 14 = loop header,
15/16 = loop body (15 is the breakpoint target), 17/18 = after the loop.
"""


def accumulate(n):
    total = 0
    label = "start"
    for i in range(n):
        doubled = i * 2
        total += doubled
    label = "done"
    return total


def main():
    result = accumulate(10)
    print(f"result={result}", flush=True)


main()
